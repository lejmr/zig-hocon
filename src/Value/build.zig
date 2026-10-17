//! A node of the tree turned into a value. The tree says what was written;
//! a value is what it means, as far as that is known without the whole
//! document: concatenations joined, a key written again merged, an include
//! read in. A `${…}` stays a `Ref` until `Resolver` has the whole document.

const std = @import("std");

// For the tests.
const testing = std.testing;
const Ast = @import("../Ast.zig");
const Node = Ast.Node;
const Tokenizer = @import("../Tokenizer.zig");
const Key = @import("../Key.zig");
const Include = @import("../Include.zig");
const table = @import("../table.zig");
const Value = @import("../Value.zig").Value;
const Error = @import("../Value.zig").Error;
const Scalar = @import("../Value.zig").Scalar;
const Member = @import("../Value.zig").Member;
const Ref = @import("../Value.zig").Ref;
const Part = Value.Part;
const Pos = Value.Pos;
const merge = @import("merge.zig");

/// One file that went into the document, for an error to point into.
pub const File = struct {
    /// As it was named: the path the parse was given, the include's path or
    /// URL. Empty for a slice.
    path: []const u8,
    source: []const u8,
};

/// Every file of one document, the main one first, and the first error found
/// in any of them. All of them share it through `Context`.
pub const Files = struct {
    list: std.ArrayList(File) = .empty,
    failed: ?Pos = null,

    /// Called where the parse or the build of `file` gave up, `offset` being
    /// where in it. An included file that failed has said so already, and the
    /// files around it leave that be: written once, where the error starts.
    pub fn fail(self: *Files, file: u16, offset: ?usize) void {
        if (self.failed != null) return;
        const at = offset orelse return;
        self.failed = .{ .file = file, .offset = at };
    }
};

/// One step of the way down from a file's root, kept on the stack while the
/// value below it is built: an include needs the whole way as a path.
pub const Frame = struct { parent: ?*const Frame, key: Key };

/// What building a value needs to know about the file it comes from, so an
/// `include` has somewhere to look. The default is a document read from a
/// slice: there is no file system behind it, and an include is an error.
pub const Context = struct {
    /// Null when the document came from a slice.
    io: ?std.Io = null,
    /// The directory of the file being built; a plain include name is found there.
    dir: []const u8 = "",
    /// The files being built right now, outermost first, as normalised paths.
    /// Including one of them again would never end.
    stack: []const []const u8 = &.{},
    /// The URL of the file being built, when it came from one: a plain include
    /// name is then a URL on the same server, not a path.
    base_url: ?[]const u8 = null,
    /// How long a fetch may take (see `ParseOptions`).
    http_timeout: std.Io.Duration = Include.default_http_timeout,
    /// Where this file's keys sit in the whole document; every substitution in
    /// it is tried with this in front first (see `Ref`).
    scope: []const Key = &.{},
    /// The keys from this file's root down to the object being built.
    frame: ?*const Frame = null,
    /// The files of the document, and this one's index among them.
    files: ?*Files = null,
    file: u16 = 0,

    /// Where building this file gave up, for the diagnostics. The first error
    /// of the document is the one kept (`Files.fail`). Nothing to tell when
    /// the tree was built by hand, without files.
    pub fn fail(ctx: Context, offset: usize) void {
        const files = ctx.files orelse return;
        files.fail(ctx.file, offset);
    }
};

/// Turns one node of the tree into a value. Dispatch only: `.value` is a
/// scalar, `.block` an object, `.array` a list, `.subst`/`.subst_optional`
/// a ref. Anything else never stands where a value stands. `ctx` says which
/// file the node comes from, so an `include` in a block can be followed; `.{}`
/// when there is none.
///
/// On failure `ctx.fail` gets the position of the node that failed, where the
/// error starts: `try` only passes it on. An error inside an included file
/// has been placed there already, and the include's place does not replace it.
pub fn fromNode(gpa: std.mem.Allocator, node: Node, ctx: Context) Error!Value {
    return switch (node.kind) {
        .value => .{ .scalar = try Scalar.fromNode(gpa, node, ctx) },
        .block, .root => blk: {
            // A braced root `{a = 1}` is `root(block(...))`: the block is the
            // document. So is the array of `[1, 2]`, which has no braces around it.
            if (node.kind == .root and node.children.len == 1 and
                (node.children[0].kind == .block or node.children[0].kind == .array))
                return Value.fromNode(gpa, node.children[0], ctx);

            var members: std.ArrayList(Member) = .empty;
            defer members.deinit(gpa);

            for (node.children) |assignment| {
                // An include stands where its members would: they come in at
                // this point, under the rules of any other duplicate key.
                if (assignment.kind == .include) {
                    // A missing file, a cycle, a bad name: the include is the
                    // place.
                    const included = Include.load(gpa, assignment, ctx) catch |err| {
                        ctx.fail(assignment.pos);
                        return err;
                    };
                    try members.appendSlice(gpa, included.object);
                    continue;
                }
                if (assignment.kind != .assignment and assignment.kind != .append) {
                    ctx.fail(assignment.pos);
                    return Error.UnsupportedNodeKind;
                }
                try members.append(gpa, try Member.fromNode(gpa, assignment, ctx));
            }
            break :blk .{ .object = try merge.mergeMembers(gpa, members.items) };
        },
        .array => blk: {
            var members: std.ArrayList(Value) = .empty;
            for (node.children) |object| {
                const val = try Value.fromNode(gpa, object, ctx);
                try members.append(gpa, val);
            }
            break :blk .{ .array = try members.toOwnedSlice(gpa) };
        },
        .subst, .subst_optional => .{ .ref = try Ref.fromNode(gpa, node, ctx) },
        .concat => {
            var values: std.ArrayList(Part) = .empty;
            var buffer: ?Value = null;
            // Where the buffer starts. Not at a gap: in ` tea` it is the `t`.
            var buffer_pos: usize = node.pos;

            for (node.children) |ch| {
                // Update buffer value from right
                const val = try Value.fromNode(gpa, ch, ctx);
                const tag = std.meta.activeTag(val);

                if (buffer) |*ebuffer| {
                    // A list and an object join once the object is resolved:
                    // a field of it can be a stack, which no list holds. An
                    // object right after a list joins the list, not the
                    // object: `[0] {"0" : 1, x : 2} {y : 3}` is `[0, 1] {y : 3}`.
                    const after_list = values.items.len > 0 and values.items[values.items.len - 1].value == .array;
                    const list_and_object = (ebuffer.* == .array and tag == .object) or
                        (ebuffer.* == .object and (tag == .array or (tag == .object and after_list)));
                    // Next to a list an object is one only with a numeric
                    // key, and whether it has one is known now.
                    const object = if (tag == .object) val else ebuffer.*;
                    if (list_and_object and try merge.numbered(gpa, object.object) == null) {
                        ctx.fail(ch.pos);
                        return Error.UnsupportedConcatenation;
                    }
                    if (ebuffer.* == .ref or tag == .ref or list_and_object) {
                        try values.append(gpa, .{ .value = ebuffer.*, .pos = .{ .file = ctx.file, .offset = buffer_pos } });
                        buffer = val;
                        buffer_pos = ch.pos;
                        continue;
                    }

                    if (ebuffer.isGap()) buffer_pos = ch.pos;
                    // The part that does not fit onto what came before it.
                    ebuffer.update(gpa, val) catch |err| {
                        ctx.fail(ch.pos);
                        return err;
                    };
                } else {
                    buffer = val;
                    buffer_pos = ch.pos;
                }
            }

            if (buffer) |b| try values.append(gpa, .{ .value = b, .pos = .{ .file = ctx.file, .offset = buffer_pos } });
            if (values.items.len == 0) {
                ctx.fail(node.pos);
                return Error.UnsupportedConcatenation;
            }
            if (values.items.len > 1) return .{ .pending = try values.toOwnedSlice(gpa) };
            return values.items[0].value;
        },
        else => {
            ctx.fail(node.pos);
            return Error.UnsupportedNodeKind;
        },
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

pub fn v(text: []const u8) Node {
    return .{ .kind = .value, .value = text, .children = &.{} };
}
pub fn n(kind: Node.NodeKind, children: []Node) Node {
    return .{ .kind = kind, .value = "", .children = children };
}
/// `Value.fromNode` for a tree with no file behind it.
pub fn build(gpa: std.mem.Allocator, node: Node) Error!Value {
    return Value.fromNode(gpa, node, .{});
}
test "value.an object holds its members in written order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var m1 = [_]Node{ v("x"), v("1") };
    var m2 = [_]Node{ v("y"), v("2") };
    var members = [_]Node{ n(.assignment, &m1), n(.assignment, &m2) };

    const obj = try build(gpa, n(.block, &members));
    try testing.expectEqual(@as(usize, 2), obj.object.len);
    try testing.expectEqualStrings("x", obj.object[0].key.value);
    try testing.expectEqualStrings("2", obj.object[1].value.scalar.value);
}
test "value.an array holds anything, nested included" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var inner = [_]Node{v("2")};
    var elems = [_]Node{ v("1"), n(.array, &inner) };

    const arr = try build(gpa, n(.array, &elems));
    try testing.expectEqual(@as(usize, 2), arr.array.len);
    try testing.expectEqualStrings("1", arr.array[0].scalar.value);
    try testing.expectEqualStrings("2", arr.array[1].array[0].scalar.value);
}
// The root of a document is an object like any other: its children are members,
// so it converts exactly as a `.block` does. Java says the same by rejecting a
// document whose root is a list, `[1,2]`, as WrongType rather than as syntax.
test "value.the root converts like a block" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var m1 = [_]Node{ v("x"), v("1") };
    var members = [_]Node{n(.assignment, &m1)};

    const doc = try build(gpa, n(.root, &members));
    try testing.expectEqual(@as(usize, 1), doc.object.len);
    try testing.expectEqualStrings("x", doc.object[0].key.value);
}
// An include is a member of a block, handled where the block is built, so one
// standing where a value stands is a phase that ran out of order. A bare
// assignment is a member, not a value, and `Member.fromNode` is the one that takes it.
test "value.an include or a bare assignment is not a value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var child = [_]Node{v("x")};
    for ([_]Node.NodeKind{ .include, .assignment }) |kind| {
        try testing.expectError(Error.UnsupportedNodeKind, build(gpa, n(kind, &child)));
    }
}
// java ✓ · pyhocon ✓ · spec ✓ — lists written next to each other are one
// list, and the gap between them is a separator rather than a character:
//
//   'a = [1] [2]'      -> {"a":[1,2]}
//   'a = [1] [2] [3]'  -> {"a":[1,2,3]}
//   'a = [1,2] []'     -> {"a":[1,2]}     an empty part adds nothing
//
// The join is flat and stays on the surface: elements are carried over as they
// are, never looked into. Two lists of lists give a list of two lists, and two
// one-element lists holding the *same* key give two members, not one.
//
//   'a = [[1]] [[2]]'        -> {"a":[[1],[2]]}
//   'a = [{x=1}] [{x=2}]'    -> {"a":[{"x":1},{"x":2}]}
//
// That is the whole difference from an object: a key is an identity, a position
// is not, so merging descends and this never does.
test "value.lists concatenate flatly at load" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var a1 = [_]Node{v("1")};
    var a2 = [_]Node{v("2")};
    var a3 = [_]Node{v("3")};

    var pair = [_]Node{ n(.array, &a1), v(" "), n(.array, &a2) };
    const two = try build(gpa, n(.concat, &pair));
    try testing.expectEqual(@as(usize, 2), two.array.len);
    try testing.expectEqualStrings("1", two.array[0].scalar.value);
    try testing.expectEqualStrings("2", two.array[1].scalar.value);

    var triple = [_]Node{ n(.array, &a1), v(" "), n(.array, &a2), v(" "), n(.array, &a3) };
    const three = try build(gpa, n(.concat, &triple));
    try testing.expectEqual(@as(usize, 3), three.array.len);
    try testing.expectEqualStrings("3", three.array[2].scalar.value);

    var empty = [_]Node{};
    var with_empty = [_]Node{ n(.array, &a1), v(" "), n(.array, &empty) };
    const kept = try build(gpa, n(.concat, &with_empty));
    try testing.expectEqual(@as(usize, 1), kept.array.len);

    var outer1 = [_]Node{n(.array, &a1)};
    var outer2 = [_]Node{n(.array, &a2)};
    var nested = [_]Node{ n(.array, &outer1), v(" "), n(.array, &outer2) };
    const deep = try build(gpa, n(.concat, &nested));
    try testing.expectEqual(@as(usize, 2), deep.array.len);
    try testing.expectEqualStrings("1", deep.array[0].array[0].scalar.value);
    try testing.expectEqualStrings("2", deep.array[1].array[0].scalar.value);
}
// java ✓ · pyhocon ⚠️ · spec ✓ — a substitution cannot be joined into, so it
// stands as a part of its own and the lists around it stay apart. What it does
// *not* do is stop the joining: the run on each side of it is still one list.
//
//   'a = [1] ${x} [2]'          -> {"a":[1]${x}[2]}       three parts
//   'a = [1] [2] ${x} [3] [4]'  -> {"a":[1,2]${x}[3,4]}   three parts, not five
//
// Which is what makes the order matter and why the parts are a list rather than
// a set — resolve drops the middle one in place:
//
//   'x = [9], a = [1] [2] ${x} [3] [4]'  -> {"a":[1,2,9,3,4]}
//
// (pyhocon cannot print an unresolved substitution, so it is only comparable
// once resolved.)
test "value.a ref parts the lists around it without stopping them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var a1 = [_]Node{v("1")};
    var a2 = [_]Node{v("2")};
    var a3 = [_]Node{v("3")};
    var a4 = [_]Node{v("4")};
    var path = [_]Node{v("x")};
    const subst = n(.subst, &path);

    var single = [_]Node{ n(.array, &a1), v(" "), subst, v(" "), n(.array, &a2) };
    const p = try build(gpa, n(.concat, &single));
    try testing.expectEqual(@as(usize, 3), p.pending.len);
    try testing.expect(p.pending[0].value == .array);
    try testing.expect(p.pending[1].value == .ref);
    try testing.expect(p.pending[2].value == .array);
    try testing.expectEqual(@as(usize, 1), p.pending[0].value.array.len);
    try testing.expectEqualStrings("2", p.pending[2].value.array[0].scalar.value);

    var runs = [_]Node{
        n(.array, &a1), v(" "), n(.array, &a2), v(" "),
        subst,          v(" "), n(.array, &a3), v(" "),
        n(.array, &a4),
    };
    const q = try build(gpa, n(.concat, &runs));
    try testing.expectEqual(@as(usize, 3), q.pending.len);
    try testing.expectEqual(@as(usize, 2), q.pending[0].value.array.len);
    try testing.expectEqualStrings("1", q.pending[0].value.array[0].scalar.value);
    try testing.expectEqualStrings("2", q.pending[0].value.array[1].scalar.value);
    try testing.expect(q.pending[1].value == .ref);
    try testing.expectEqual(@as(usize, 2), q.pending[2].value.array.len);
    try testing.expectEqualStrings("3", q.pending[2].value.array[0].scalar.value);
    try testing.expectEqualStrings("4", q.pending[2].value.array[1].scalar.value);
}
// java ✓ · pyhocon ✓ · spec ✓ — text parts join with their gaps as characters:
//
//   'a = grumpy "wombat"' -> {"a":"grumpy wombat"}
//   'a = 1 " x"'          -> {"a":"1  x"}          gap plus a quoted space
//
// A text join only arises when a quoted part is involved — adjacent unquoted
// text is one slice already and never reaches a `.concat` — so the result is
// always quoted: '1 " x"' has stopped being a number.
test "value.text parts join, gaps and all" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var texts = [_]Node{ v("grumpy"), v(" "), v("\"wombat\"") };
    const text = try build(gpa, n(.concat, &texts));
    try testing.expectEqualStrings("grumpy wombat", text.scalar.value);
    try testing.expect(text.scalar.quoted);

    var spaced = [_]Node{ v("1"), v(" "), v("\" x\"") };
    const joined = try build(gpa, n(.concat, &spaced));
    try testing.expectEqualStrings("1  x", joined.scalar.value);
    try testing.expect(joined.scalar.quoted);
}
// java ✓ · pyhocon ⚠️ · spec ✓ — nothing has to stand between a substitution
// and the part next to it. Written with no gap they are still two parts, and
// the ref still cannot be joined into:
//
//   'a = ${x}"c"'    -> ${x}"c"        two parts, no gap to carry
//   'a = "c"${x}'    -> "c"${x}
//   'a = ${x}[1]'    -> ${x}[1]
//   'a = ${x}{b=1}'  -> ${x}{"b":1}
//
// Which resolve then joins with nothing added — 'x = 1' gives "1c", not "1 c",
// so the gap is never invented on the way out either.
//
// (pyhocon cannot print an unresolved substitution, so it is only comparable
// once resolved.)
test "value.a ref needs no gap to stand apart" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var px = [_]Node{v("x")};
    const sx = n(.subst, &px);
    var elems = [_]Node{v("1")};
    var m = [_]Node{ v("b"), v("1") };
    var assigns = [_]Node{n(.assignment, &m)};

    var after = [_]Node{ sx, v("\"c\"") };
    const a = try build(gpa, n(.concat, &after));
    try testing.expectEqual(@as(usize, 2), a.pending.len);
    try testing.expect(a.pending[0].value == .ref);
    try testing.expectEqualStrings("c", a.pending[1].value.scalar.value);

    var before = [_]Node{ v("\"c\""), sx };
    const b = try build(gpa, n(.concat, &before));
    try testing.expectEqual(@as(usize, 2), b.pending.len);
    try testing.expectEqualStrings("c", b.pending[0].value.scalar.value);
    try testing.expect(b.pending[1].value == .ref);

    var with_list = [_]Node{ sx, n(.array, &elems) };
    const l = try build(gpa, n(.concat, &with_list));
    try testing.expectEqual(@as(usize, 2), l.pending.len);
    try testing.expect(l.pending[0].value == .ref);
    try testing.expect(l.pending[1].value == .array);

    var with_block = [_]Node{ sx, n(.block, &assigns) };
    const o = try build(gpa, n(.concat, &with_block));
    try testing.expectEqual(@as(usize, 2), o.pending.len);
    try testing.expect(o.pending[0].value == .ref);
    try testing.expect(o.pending[1].value == .object);
}
// The parser never builds one — a `.concat` exists because there were parts to
// hold — but `fromNode` reads `values.items[0]` to decide what it is looking
// at, and on an empty list that is a read past the end rather than an error.
// A node arriving from anywhere but `parseValue` has to come back as an error.
test "value.an empty concatenation is an error, not an index out of range" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var none = [_]Node{};
    try testing.expectError(
        Error.UnsupportedConcatenation,
        build(gpa, n(.concat, &none)),
    );
}
// java ✓ · pyhocon ✓ · spec ✓ — 'Cannot concatenate object or list with a
// non-object-or-list' comes out of java at *parse* time; 'a = 1 [2]' never
// gets as far as resolve. The gap between the parts does not soften the pair:
// in '{b=1} "s"' the object stands against the string, the space belongs to
// neither. A list next to an object without a numeric key is here too: no key
// can make it a list.
test "value.mixing containers with anything else fails at load" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var elems = [_]Node{v("2")};
    var m = [_]Node{ v("b"), v("1") };
    var assigns = [_]Node{n(.assignment, &m)};
    const array = n(.array, &elems);
    const block = n(.block, &assigns);

    var path = [_]Node{v("x")};
    const subst = n(.subst, &path);

    var scalar_array = [_]Node{ v("1"), v(" "), array };
    var array_block = [_]Node{ array, v(" "), block };
    var block_scalar = [_]Node{ block, v(" "), v("\"s\"") };
    // 'a = "1" [2] ${x}' — the ref defers nothing here, the pair before it is
    // already adjacent and already wrong.
    var before_ref = [_]Node{ v("\"1\""), v(" "), array, v(" "), subst };
    for ([_][]Node{ &scalar_array, &array_block, &block_scalar, &before_ref }) |parts| {
        try testing.expectError(
            Error.UnsupportedConcatenation,
            build(gpa, n(.concat, parts)),
        );
    }
}
// java ✓ · pyhocon ⚠️ · spec ✓ — a gap is a part like any other and follows
// the same rules, so what happens to it falls out of its neighbours. Java
// prints the unresolved forms, which is the shape this has to load as:
//
//   'a = ${x} ${y}'    -> ${x}" "${y}     alone: nothing to join it to
//   'a = ${x} "c"'     -> ${x}" c"        joined into the scalar on its right
//   'a = "c" ${x}'     -> "c "${x}        and into the one on its left
//   'a = [1] ${x}'     -> [1]${x}         gone: a list has no use for it
//   'a = ${x} {b=1}'   -> ${x}{"b":1}     nor an object
//
// So it survives only where a text join is still possible, and its width
// survives with it — 'a = ${x}   ${y}' resolves to "1   2" against x=1, y=2,
// which nothing downstream could reconstruct once the gap is dropped.
//
// (pyhocon cannot print an unresolved substitution, so it is only comparable
// once resolved.)
test "value.a gap lives or dies by its neighbours" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var px = [_]Node{v("x")};
    var py = [_]Node{v("y")};
    const sx = n(.subst, &px);
    const sy = n(.subst, &py);

    // between two refs it has nowhere to go, so it stands alone
    var alone = [_]Node{ sx, v(" "), sy };
    const a = try build(gpa, n(.concat, &alone));
    try testing.expectEqual(@as(usize, 3), a.pending.len);
    try testing.expect(a.pending[0].value == .ref);
    try testing.expectEqualStrings(" ", a.pending[1].value.scalar.value);
    try testing.expect(a.pending[2].value == .ref);

    // next to text it is a character of that text, from either side
    var right = [_]Node{ sx, v(" "), v("\"c\"") };
    const r = try build(gpa, n(.concat, &right));
    try testing.expectEqual(@as(usize, 2), r.pending.len);
    try testing.expect(r.pending[0].value == .ref);
    try testing.expectEqualStrings(" c", r.pending[1].value.scalar.value);

    var left = [_]Node{ v("\"c\""), v(" "), sx };
    const l = try build(gpa, n(.concat, &left));
    try testing.expectEqual(@as(usize, 2), l.pending.len);
    try testing.expectEqualStrings("c ", l.pending[0].value.scalar.value);
    try testing.expect(l.pending[1].value == .ref);

    // next to a container it is a separator and disappears
    var elems = [_]Node{v("1")};
    var with_list = [_]Node{ n(.array, &elems), v(" "), sx };
    const wl = try build(gpa, n(.concat, &with_list));
    try testing.expectEqual(@as(usize, 2), wl.pending.len);
    try testing.expect(wl.pending[0].value == .array);
    try testing.expect(wl.pending[1].value == .ref);

    var m = [_]Node{ v("b"), v("1") };
    var assigns = [_]Node{n(.assignment, &m)};
    var with_block = [_]Node{ sx, v(" "), n(.block, &assigns) };
    const wb = try build(gpa, n(.concat, &with_block));
    try testing.expectEqual(@as(usize, 2), wb.pending.len);
    try testing.expect(wb.pending[0].value == .ref);
    try testing.expect(wb.pending[1].value == .object);
}
// java ✓ · pyhocon ⚠️ · spec ✓ — a pending value is not only a thing a member
// holds; it is a value, so it stands wherever one may:
//
//   'a = [${x}]'            -> {"a":[${x}]}          a ref as an element
//   'a = [ ${x} [1] ]'      -> {"a":[${x}[1]]}       a pending as an element
//   'a = { b = ${x} [1] }'  -> {"a":{"b":${x}[1]}}   and as a member value
//
// Nothing collapses on the way out: the list keeps one element and the object
// one member, each holding the unresolved thing whole.
//
// (pyhocon cannot print an unresolved substitution, so it is only comparable
// once resolved.)
test "value.a ref or a pending stands inside a container too" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var px = [_]Node{v("x")};
    const sx = n(.subst, &px);
    var e1 = [_]Node{v("1")};

    var elems = [_]Node{sx};
    const arr = try build(gpa, n(.array, &elems));
    try testing.expectEqual(@as(usize, 1), arr.array.len);
    try testing.expect(arr.array[0] == .ref);

    var inner = [_]Node{ sx, v(" "), n(.array, &e1) };
    var wrapped = [_]Node{n(.concat, &inner)};
    const nested = try build(gpa, n(.array, &wrapped));
    try testing.expectEqual(@as(usize, 1), nested.array.len);
    try testing.expectEqual(@as(usize, 2), nested.array[0].pending.len);
    try testing.expect(nested.array[0].pending[0].value == .ref);
    try testing.expect(nested.array[0].pending[1].value == .array);

    var member = [_]Node{ v("b"), n(.concat, &inner) };
    var members = [_]Node{n(.assignment, &member)};
    const obj = try build(gpa, n(.block, &members));
    try testing.expectEqual(@as(usize, 1), obj.object.len);
    try testing.expectEqualStrings("b", obj.object[0].key.value);
    try testing.expectEqual(@as(usize, 2), obj.object[0].value.pending.len);
    try testing.expect(obj.object[0].value.pending[0].value == .ref);
}
// java ✓ · pyhocon ⚠️ · spec ✓ — `${?x}` parts a concatenation exactly as
// `${x}` does; the difference is what resolution does with it, so the flag has
// to survive the load:
//
//   'a = ${?x} [1]'            -> {"a":${?x}[1]}
//   'resolve: a = ${?x} "y"'   -> {"a":" y"}     missing: contributes nothing,
//                                                but the gap beside it stays
//   'resolve: a = 1 ${?x} 2'   -> {"a":"1  2"}   both gaps survive
//   'resolve: a = ${?x}, b=1'  -> {"b":1}        alone: the member goes too
//
// That last line is why this is its own kind rather than a flag on the value:
// an unresolved optional removes the member it belongs to, which nothing but
// the member itself can do.
test "value.an optional substitution parts a concatenation like any ref" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var px = [_]Node{v("x")};
    var e1 = [_]Node{v("1")};
    var parts = [_]Node{ n(.subst_optional, &px), v(" "), n(.array, &e1) };
    const p = try build(gpa, n(.concat, &parts));
    try testing.expectEqual(@as(usize, 2), p.pending.len);
    try testing.expect(p.pending[0].value == .ref);
    try testing.expect(p.pending[0].value.ref.flags.optional);
    try testing.expect(p.pending[1].value == .array);

    // and between two texts the gap is still a part of its own
    var texts = [_]Node{ v("1"), v(" "), n(.subst_optional, &px), v(" "), v("2") };
    const t = try build(gpa, n(.concat, &texts));
    try testing.expectEqual(@as(usize, 3), t.pending.len);
    try testing.expectEqualStrings("1 ", t.pending[0].value.scalar.value);
    try testing.expect(t.pending[1].value.ref.flags.optional);
    try testing.expectEqualStrings(" 2", t.pending[2].value.scalar.value);
}
// java ✓ · pyhocon ✓ · spec ✓ — an empty *quoted* string is a value, not a
// gap, and the gap beside it is still a character:
//
//   'a = "" [1]'  -> WrongType     the same as '"x" [1]'
//   'a = [1] ""'  -> WrongType
//   'a = "" "x"'  -> {"a":" x"}    the gap between them survives
//
// Which is the whole reason `isGap` asks about the delimiter rather than only
// trimming: `[1] " " [2]` is an error where `[1]   [2]` is [1,2].
test "value.an empty quoted string is a value, not a gap" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var e1 = [_]Node{v("1")};
    var after = [_]Node{ v("\"\""), v(" "), n(.array, &e1) };
    var before = [_]Node{ n(.array, &e1), v(" "), v("\"\"") };
    var spaced = [_]Node{ n(.array, &e1), v(" "), v("\" \""), v(" "), n(.array, &e1) };
    for ([_][]Node{ &after, &before, &spaced }) |parts| {
        try testing.expectError(
            Error.UnsupportedConcatenation,
            build(gpa, n(.concat, parts)),
        );
    }

    var texts = [_]Node{ v("\"\""), v(" "), v("\"x\"") };
    const t = try build(gpa, n(.concat, &texts));
    try testing.expectEqualStrings(" x", t.scalar.value);
}
// java ✓ · pyhocon ✓ · spec ✓ — an empty container is a part like any other
// and contributes nothing:
//
//   'a = [] [1]'       -> {"a":[1]}
//   'a = {} {b=1}'     -> {"a":{"b":1}}
//   'a = {b=1} {}'     -> {"a":{"b":1}}
//   'a = {} {}'        -> {"a":{}}
//   'a = {} [1]'       -> WrongType      no numeric key to make it a list
test "value.an empty container joins without adding anything" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var none = [_]Node{};
    var e1 = [_]Node{v("1")};
    var m = [_]Node{ v("b"), v("1") };
    var assigns = [_]Node{n(.assignment, &m)};

    var lists = [_]Node{ n(.array, &none), v(" "), n(.array, &e1) };
    const l = try build(gpa, n(.concat, &lists));
    try testing.expectEqual(@as(usize, 1), l.array.len);

    var left_empty = [_]Node{ n(.block, &none), v(" "), n(.block, &assigns) };
    const le = try build(gpa, n(.concat, &left_empty));
    try testing.expectEqual(@as(usize, 1), le.object.len);
    try testing.expectEqualStrings("b", le.object[0].key.value);

    var right_empty = [_]Node{ n(.block, &assigns), v(" "), n(.block, &none) };
    const re = try build(gpa, n(.concat, &right_empty));
    try testing.expectEqual(@as(usize, 1), re.object.len);

    var both = [_]Node{ n(.block, &none), v(" "), n(.block, &none) };
    const b = try build(gpa, n(.concat, &both));
    try testing.expectEqual(@as(usize, 0), b.object.len);

    var crossed = [_]Node{ n(.block, &none), v(" "), n(.array, &e1) };
    try testing.expectError(
        Error.UnsupportedConcatenation,
        build(gpa, n(.concat, &crossed)),
    );
}
// java ✓ · pyhocon ✓ · spec ✓ — a triple-quoted part joins like any other, and
// what is inside it stays as it was written:
//
//   'a = """a""" "b"'     -> {"a":"a b"}
//   'a = """a\nb""" "c"'  -> {"a":"a\nb c"}   a real newline, not a backslash
//   'a = x """y"""'       -> {"a":"x y"}
//
// The escapes were already decided by the delimiter when the part was read, so
// the join is a plain append — anything cleverer here would process them twice.
test "value.a multi-line part joins without reprocessing it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var simple = [_]Node{ v("\"\"\"a\"\"\""), v(" "), v("\"b\"") };
    const s1 = try build(gpa, n(.concat, &simple));
    try testing.expectEqualStrings("a b", s1.scalar.value);
    try testing.expect(s1.scalar.quoted);

    // inside """ a backslash-n is those two characters; the quoted part beside
    // it turns its own into a newline, and both survive the join as they are
    var mixed = [_]Node{ v("\"\"\"a\\nb\"\"\""), v(" "), v("\"c\\nd\"") };
    const s2 = try build(gpa, n(.concat, &mixed));
    try testing.expectEqualStrings("a\\nb c\nd", s2.scalar.value);

    var leading = [_]Node{ v("x"), v(" "), v("\"\"\"y\"\"\"") };
    const s3 = try build(gpa, n(.concat, &leading));
    try testing.expectEqualStrings("x y", s3.scalar.value);
}
