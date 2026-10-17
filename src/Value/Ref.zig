//! A reference. From an included file, `path` is the path as written with the
//! include's scope in front, and `scope_len` says how much of it that is: the
//! path is looked up as it stands, and when that finds nothing, again without
//! the scope, from the document root.

const std = @import("std");
const Value = @import("../Value.zig").Value;
const Error = @import("../Value.zig").Error;
const Key = @import("../Key.zig");

// For the tests.
const testing = std.testing;
const Ast = @import("../Ast.zig");
const Node = Ast.Node;
const Tokenizer = @import("../Tokenizer.zig");
const table = @import("../table.zig");
const build = @import("build.zig").build;
const v = @import("build.zig").v;
const n = @import("build.zig").n;

const Ref = @This();

path: []const Key,
/// The marks a `${…}` can carry, and whether `+=` made it, packed into
/// one byte so Ref stays 24 bytes.
flags: packed struct(u8) {
    /// `${?…}`: nothing behind it removes what it is part of.
    optional: bool,
    /// `${X[]}`: from the environment, `X_0`, `X_1`, … as a list.
    list: bool = false,
    /// Made by `a += b` and looking up `a` itself, so it can be written
    /// as `+=` again.
    append: bool = false,
    _: u5 = 0,
},
/// A u8, so that `file` fits too: Ref stays 24 bytes and Value 32. More keys
/// than that above an include are refused where the scope is made.
scope_len: u8 = 0,
/// Where its `${` is, for the resolver's errors: the file it was written in
/// and the offset there. A u32 like the byte offsets in std.zig.Ast: a usize
/// would make every Value 8 bytes bigger.
file: u16,
pos: u32,

/// Where its `${` is, as a place in the document.
pub fn at(self: Ref) Value.Pos {
    return .{ .file = self.file, .offset = self.pos };
}

/// The same ref, looking up `path` from the document root: the one of its
/// two paths that is left once the include's scope is no longer there.
/// Without the scope, a ref of `+=` no longer looks up its own field.
pub fn from(self: Ref, path: []const Key) Ref {
    var copy = self;
    copy.path = path;
    copy.scope_len = 0;
    if (path.len != self.path.len) copy.flags.append = false;
    return copy;
}

/// The path is cut by `Key.split`, the splitter a key before `=` goes
/// through, so a malformed one fails the same way and at the same place:
/// the dot next to the empty element. A bad escape is at its quoted part.
pub fn fromNode(gpa: std.mem.Allocator, node: Node, ctx: Value.Context) Error!Ref {
    var err_offset: ?usize = null;
    const elements = Key.split(gpa, node.children[0], &err_offset) catch |err| {
        if (err_offset) |offset| ctx.fail(offset);
        return err;
    };

    const path = try gpa.alloc(Key, ctx.scope.len + elements.len);
    @memcpy(path[0..ctx.scope.len], ctx.scope);
    for (path[ctx.scope.len..], elements) |*key, element| key.* = try Key.fromNode(gpa, element, ctx);

    return .{
        .path = path,
        .flags = .{
            .optional = if (node.kind == .subst_optional) true else false,
            .list = std.mem.eql(u8, node.value, "[]"),
        },
        .scope_len = @intCast(ctx.scope.len),
        .file = ctx.file,
        .pos = @intCast(node.pos),
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "value.a substitution becomes a ref, optional and all" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var path = [_]Node{v("a.b")};
    const req = try build(gpa, n(.subst, &path));
    try testing.expect(!req.ref.flags.optional);
    try testing.expectEqual(@as(usize, 2), req.ref.path.len);
    try testing.expectEqualStrings("a", req.ref.path[0].value);
    try testing.expectEqualStrings("b", req.ref.path[1].value);

    const opt = try build(gpa, n(.subst_optional, &path));
    try testing.expect(opt.ref.flags.optional);
}
// The size of a `Value` is a cost paid for every scalar of every document, and
// the depth a chain of substitutions can reach before the stack runs out. A ref
// carries its place (a u16 file, a u32 offset) and the include scope (a u8)
// in what its path and flag leave of 24 bytes.
test "value.a ref's place and scope fit in the padding" {
    try testing.expectEqual(32, @sizeOf(Value));
    try testing.expectEqual(24, @sizeOf(Ref));
}
// java ✓ · pyhocon ✓ · spec ✓ — a dot inside quotes is a character of one key,
// a dot outside them separates two. The oracle answers by resolving, since only
// a matching key proves how the path was cut:
//
//   'x { "y.z" = 1 }, a = ${x."y.z"}'  -> {"a":1}    two elements: x, y.z
//   'x { y = { z = 1 } }, a = ${x.y.z}'-> {"a":1}    three: x, y, z
//   '"a.b" = 1, r = ${"a.b"}'          -> {"r":1}    one: a.b
//
// Which is why the split has to run on the text as written and unquote each
// piece afterwards. Unquoting first throws away the only thing that says which
// dot was which, and no later pass can recover it. The parser leaves the two
// spellings distinguishable for exactly this reason: `${x."y.z"}` arrives as a
// concat of `x.` and `"y.z"`, `${x.y.z}` as one text part.
test "ref.a quoted dot is a character, not a separator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var plain = [_]Node{v("x.y")};
    const p = try build(gpa, n(.subst, &plain));
    try testing.expectEqual(@as(usize, 2), p.ref.path.len);
    try testing.expectEqualStrings("x", p.ref.path[0].value);
    try testing.expectEqualStrings("y", p.ref.path[1].value);

    var parts = [_]Node{ v("x."), v("\"y.z\"") };
    var quoted_tail = [_]Node{n(.concat, &parts)};
    const q = try build(gpa, n(.subst, &quoted_tail));
    try testing.expectEqual(@as(usize, 2), q.ref.path.len);
    try testing.expectEqualStrings("x", q.ref.path[0].value);
    try testing.expectEqualStrings("y.z", q.ref.path[1].value);

    var whole = [_]Node{v("\"a.b\"")};
    const w = try build(gpa, n(.subst, &whole));
    try testing.expectEqual(@as(usize, 1), w.ref.path.len);
    try testing.expectEqualStrings("a.b", w.ref.path[0].value);

    var single = [_]Node{v("x")};
    const one = try build(gpa, n(.subst, &single));
    try testing.expectEqual(@as(usize, 1), one.ref.path.len);
    try testing.expectEqualStrings("x", one.ref.path[0].value);

    // A segment stays open across the part boundary, so a part beginning with a
    // dot closes the one before it rather than adding an empty one of its own.
    // Every path below resolves in java against a config holding exactly the
    // key it names, which is what proves where the cuts fell:
    //
    //   'a { "b.c" { d = 1 } }, r = ${a."b.c".d}'    -> {"r":1}   three elements
    //   'a { b = 1 }, r = ${"a"."b"}'                -> {"r":1}   two, the dot alone
    //   '"a.b" { c = 1 }, r = ${"""a.b""".c}'          -> {"r":1}   two, triple-quoted
    //   'a { "" { b = 1 } }, r = ${a."".b}'          -> {"r":1}   an empty one is legal
    var p1 = [_]Node{ v("a."), v("\"b.c\""), v(".d") };
    var p2 = [_]Node{ v("\"a\""), v("."), v("\"b\"") };
    var p3 = [_]Node{ v("\"\"\"a.b\"\"\""), v(".c") };
    var p4 = [_]Node{ v("a."), v("\"\""), v(".b") };
    // and with no dot between them the parts are one element, not two:
    //   'ab = 1, r = ${a"b"}'  -> {"r":1}
    var p5 = [_]Node{ v("a"), v("\"b\"") };
    const want = [_][]const []const u8{
        &.{ "a", "b.c", "d" },
        &.{ "a", "b" },
        &.{ "a.b", "c" },
        &.{ "a", "", "b" },
        &.{"ab"},
    };
    for ([_][]Node{ &p1, &p2, &p3, &p4, &p5 }, want, 0..) |path_parts, expected, i| {
        errdefer std.debug.print("failed on path {d}\n", .{i});
        var child = [_]Node{n(.concat, path_parts)};
        const r = try build(gpa, n(.subst, &child));
        try testing.expectEqual(expected.len, r.ref.path.len);
        for (expected, r.ref.path) |e, got| try testing.expectEqualStrings(e, got.value);
    }
}
// java ✓ · pyhocon ⚠️ · spec ✓ — the empty element java calls BadPath, on a path
// inside `${…}`. Quotes make the same difference they make on the key side: an
// empty element is legal only when it is written as `""`.
//
//   'a = ${.b}'      -> ERROR BadPath      'a = ${"b".}'  -> ERROR BadPath
//   'a = ${b.}'      -> ERROR BadPath      'a = ${."b"}'  -> ERROR BadPath
//   'a = ${b..c}'    -> ERROR BadPath
//   'a = ${"".b}'    -> {"a":${"".b}}      'a = ${b.""}'  -> {"a":${b.""}}
//
// The two legal ones resolve in java against exactly the key they name:
// 'resolve:"" { b = 1 }\na = ${"".b}' -> {"":{"b":1},"a":1}. pyhocon cannot
// parse a quoted path element at all, so it is not comparable here.
//
// The parser still lets these through (its own `substitution` table says so),
// so the ref is where they have to stop: `Key.split`, the splitter keys go
// through, knows an element came out empty without quotes to say so.
test "ref.an unquoted empty element is a BadPath" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var b1 = [_]Node{v(".b")};
    var b2 = [_]Node{v("b.")};
    var b3 = [_]Node{v("b..c")};
    var b4 = [_]Node{ v("\"b\""), v(".") };
    var b5 = [_]Node{ v("."), v("\"b\"") };
    for ([_][]Node{ &b1, &b2, &b3, &b4, &b5 }, 0..) |path_parts, i| {
        errdefer std.debug.print("failed on bad path {d}\n", .{i});
        var child = [_]Node{n(.concat, path_parts)};
        try testing.expectError(Error.MalformedKey, build(gpa, n(.subst, &child)));
    }

    // Written as `""`, the empty element is an element like any other.
    var ok1 = [_]Node{ v("\"\""), v(".b") };
    var ok2 = [_]Node{ v("b."), v("\"\"") };
    const want = [_][]const []const u8{ &.{ "", "b" }, &.{ "b", "" } };
    for ([_][]Node{ &ok1, &ok2 }, want, 0..) |path_parts, expected, i| {
        errdefer std.debug.print("failed on legal path {d}\n", .{i});
        var child = [_]Node{n(.concat, path_parts)};
        const r = try build(gpa, n(.subst, &child));
        try testing.expectEqual(expected.len, r.ref.path.len);
        for (expected, r.ref.path) |e, got| try testing.expectEqualStrings(e, got.value);
    }
}
