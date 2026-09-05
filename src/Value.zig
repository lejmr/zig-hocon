//! Value holder for received data

const std = @import("std");
const testing = std.testing;
const Key = @import("Key.zig");
const Ast = @import("Ast.zig");
const Node = Ast.Node;
const unqoute = @import("utils/unqoute.zig");

pub const Error = error{
    UnsupportedNodeKind,
    InvalidAssignment,
    MixedTypes,
    UnsupportedConcatenation,
    UnsupportedValueType,
} || Key.Error || unqoute.Error;

pub const Value = union(enum) {
    scalar: Scalar,
    array: []Value,
    object: []Member,
    ref: Ref,

    // For right updates of already stored data, but not yet resolved
    pending: []Value,

    /// Turns one node of the tree into a value. Dispatch only: `.value` is a
    /// scalar, `.block` an object, `.array` a list, `.subst`/`.subst_optional`
    /// a ref. Anything else never stands where a value stands.
    pub fn fromNode(gpa: std.mem.Allocator, node: Node) Error!Value {
        return switch (node.kind) {
            .value => .{ .scalar = try Scalar.fromNode(gpa, node) },
            .block, .root => blk: {
                var members: std.ArrayList(Member) = .empty;
                for (node.children) |assignment| {
                    if (assignment.kind != .assignment) return Error.UnsupportedNodeKind;
                    if (assignment.children.len < 2) return Error.InvalidAssignment;
                    const member = try Member.fromNode(gpa, assignment);
                    try members.append(gpa, member);
                }
                break :blk .{ .object = try members.toOwnedSlice(gpa) };
            },
            .array => blk: {
                var members: std.ArrayList(Value) = .empty;
                for (node.children) |object| {
                    const val = try Value.fromNode(gpa, object);
                    try members.append(gpa, val);
                }
                break :blk .{ .array = try members.toOwnedSlice(gpa) };
            },
            .subst, .subst_optional => .{ .ref = try Ref.fromNode(gpa, node) },
            .concat => {
                var values: std.ArrayList(Value) = .empty;
                var buffer: ?Value = null;

                for (node.children) |ch| {
                    // Update buffer value from right
                    const val = try Value.fromNode(gpa, ch);
                    const tag = std.meta.activeTag(val);

                    if (buffer) |*ebuffer| {
                        if (ebuffer.* == .ref and val.isGap()) {
                            try values.append(gpa, ebuffer.*);
                            buffer = val;
                            continue;
                        }

                        if (tag == .ref) {
                            try values.append(gpa, ebuffer.*);
                            buffer = val;
                            continue;
                        }
                        try ebuffer.update(gpa, val);
                    } else {
                        buffer = val;
                    }
                }

                if (buffer) |b| try values.append(gpa, b);
                if (values.items.len == 0) return Error.UnsupportedConcatenation;
                if (values.items.len > 1) return .{ .pending = try values.toOwnedSlice(gpa) };
                return values.items[0];
            },
            else => Error.UnsupportedNodeKind,
        };
    }

    fn update(self: *Value, gpa: std.mem.Allocator, other: Value) Error!void {
        const tag_self = std.meta.activeTag(self.*);
        const tag_other = std.meta.activeTag(other);

        // There are cases when different tags can be handled..
        if (tag_self != tag_other) {
            if ((tag_self == .array or tag_self == .object) and other.isGap()) return;
            // this is how to destroy nicely the empty space!
            if ((tag_other == .array or tag_other == .object) and self.isGap()) {
                self.* = other;
                return;
            }
            return Error.UnsupportedConcatenation;
        }
        switch (tag_other) {
            .array => {
                const merged = try std.mem.concat(gpa, Value, &.{ self.array, other.array });
                self.array = merged;
            },
            .scalar => {
                self.scalar = .{
                    .value = try std.mem.concat(gpa, u8, &.{ self.scalar.value, other.scalar.value }),
                    .quoted = true,
                };
            },
            .object => {
                const merged = try std.mem.concat(gpa, Member, &.{ self.object, other.object });
                self.object = merged;
            },
            else => return Error.UnsupportedConcatenation,
        }
    }

    fn isGap(self: Value) bool {
        return self == .scalar and !self.scalar.quoted and
            std.mem.trim(u8, self.scalar.value, " \t").len == 0;
    }
};

// PLace holder for any string or number
const Scalar = struct {
    value: []const u8,
    quoted: bool,

    pub fn fromNode(gpa: std.mem.Allocator, node: Node) Error!Scalar {
        const ut = try unqoute.unquote(gpa, node.value);
        return .{ .value = ut.text, .quoted = ut.quoted };
    }
};
const Member = struct {
    key: Key,
    value: Value,

    /// From an `.assignment`: `children[0]` is the key, `children[1]` the value.
    pub fn fromNode(gpa: std.mem.Allocator, node: Node) Error!Member {
        // Member can only by assignment type
        if (node.kind != .assignment and node.children.len >= 2) return Error.UnsupportedNodeKind;

        // Lets prepare key
        const key_node = node.children[0];
        if (key_node.kind != .value) return Error.UnsupportedNodeKind;

        // Loads load the Value
        const val = try Value.fromNode(gpa, node.children[1]);

        // Prep value
        // var values_to_splice: std.ArrayList(Node) = .empty;
        // var values_pending: std.ArrayList(Node) = .empty;

        // for (node.children[1..node.children.len]) |ch| {
        //     const val = try Value.fromNode(gpa, ch);
        //     if (values_to_splice.items.len > 0) {
        //         const last_val = values_to_splice.items[values_to_splice.items.len];
        //         const last_val_tag = std.meta.activeTag(last_val);
        //         const cur_val_tag = std.meta.activeTag(val);

        //         // Branching conditions
        //         const collecting_pending = values_pending.items.len > 0;
        //         values_pending.items.len > 0;
        //         const different_tags = last_val_tag == cur_val_tag;
        //         const is_there_ref = cur_val_tag == .ref or last_val_tag == .ref;

        //         if (collecting_pending) {
        //             try values_pending.append(gpa, ch);
        //             continue;
        //         }

        //         if (different_tags) {
        //             if (is_there_ref) {
        //                 try values_pending.append(gpa, ch);
        //                 continue;
        //             }
        //             return Error.UnsupportedConcatenation;
        //         }
        //     }
        //     // Append if tags are same
        //     values_to_splice.append(gpa, ch);
        // }

        // const primary_item = values_to_splice.items[0];
        // const main_type = std.meta.activeTag(val);

        return .{
            .key = try Key.fromNode(gpa, key_node),
            .value = val,
        };
    }
};
const Ref = struct {
    path: []const Key,
    optional: bool,

    /// The child holds the path as it was written; split it on `.` here so
    /// `resolve` never parses. A quoted dot has no answer yet.
    pub fn fromNode(gpa: std.mem.Allocator, node: Node) Error!Ref {
        const key = try Key.fromNode(gpa, node.children[0]);
        var key_list: std.ArrayList(Key) = .empty;
        var it = std.mem.splitAny(u8, key.value, ".");
        while (it.next()) |x| {
            const part_key = try Key.fromNode(gpa, .{
                .kind = .value,
                .value = x,
                .children = &[0]Node{},
            });
            try key_list.append(gpa, part_key);
        }

        return .{
            .path = try key_list.toOwnedSlice(gpa),
            .optional = if (node.kind == .subst_optional) true else false,
        };
    }
};
// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn v(text: []const u8) Node {
    return .{ .kind = .value, .value = text, .children = &.{} };
}

fn n(kind: Node.NodeKind, children: []Node) Node {
    return .{ .kind = kind, .value = "", .children = children };
}

test "value.a scalar keeps its text and remembers the quotes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const plain = try Value.fromNode(gpa, v("1"));
    try testing.expectEqualStrings("1", plain.scalar.value);
    try testing.expect(!plain.scalar.quoted);

    const quoted = try Value.fromNode(gpa, v("\"1\""));
    try testing.expectEqualStrings("1", quoted.scalar.value);
    try testing.expect(quoted.scalar.quoted);
}

test "value.an object holds its members in written order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var m1 = [_]Node{ v("x"), v("1") };
    var m2 = [_]Node{ v("y"), v("2") };
    var members = [_]Node{ n(.assignment, &m1), n(.assignment, &m2) };

    const obj = try Value.fromNode(gpa, n(.block, &members));
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

    const arr = try Value.fromNode(gpa, n(.array, &elems));
    try testing.expectEqual(@as(usize, 2), arr.array.len);
    try testing.expectEqualStrings("1", arr.array[0].scalar.value);
    try testing.expectEqualStrings("2", arr.array[1].array[0].scalar.value);
}

test "value.a substitution becomes a ref, optional and all" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var path = [_]Node{v("a.b")};
    const req = try Value.fromNode(gpa, n(.subst, &path));
    try testing.expect(!req.ref.optional);
    try testing.expectEqual(@as(usize, 2), req.ref.path.len);
    try testing.expectEqualStrings("a", req.ref.path[0].value);
    try testing.expectEqualStrings("b", req.ref.path[1].value);

    const opt = try Value.fromNode(gpa, n(.subst_optional, &path));
    try testing.expect(opt.ref.optional);
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

    const doc = try Value.fromNode(gpa, n(.root, &members));
    try testing.expectEqual(@as(usize, 1), doc.object.len);
    try testing.expectEqualStrings("x", doc.object[0].key.value);
}

// An include is spliced into the tree before the graph is built, so one reaching
// here is a phase that ran out of order. A bare assignment is a member, not a
// value, and `Member.fromNode` is the one that takes it.
test "value.an include or a bare assignment is not a value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var child = [_]Node{v("x")};
    for ([_]Node.NodeKind{ .include, .assignment }) |kind| {
        try testing.expectError(Error.UnsupportedNodeKind, Value.fromNode(gpa, n(kind, &child)));
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
    const two = try Value.fromNode(gpa, n(.concat, &pair));
    try testing.expectEqual(@as(usize, 2), two.array.len);
    try testing.expectEqualStrings("1", two.array[0].scalar.value);
    try testing.expectEqualStrings("2", two.array[1].scalar.value);

    var triple = [_]Node{ n(.array, &a1), v(" "), n(.array, &a2), v(" "), n(.array, &a3) };
    const three = try Value.fromNode(gpa, n(.concat, &triple));
    try testing.expectEqual(@as(usize, 3), three.array.len);
    try testing.expectEqualStrings("3", three.array[2].scalar.value);

    var empty = [_]Node{};
    var with_empty = [_]Node{ n(.array, &a1), v(" "), n(.array, &empty) };
    const kept = try Value.fromNode(gpa, n(.concat, &with_empty));
    try testing.expectEqual(@as(usize, 1), kept.array.len);

    var outer1 = [_]Node{n(.array, &a1)};
    var outer2 = [_]Node{n(.array, &a2)};
    var nested = [_]Node{ n(.array, &outer1), v(" "), n(.array, &outer2) };
    const deep = try Value.fromNode(gpa, n(.concat, &nested));
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
    const p = try Value.fromNode(gpa, n(.concat, &single));
    try testing.expectEqual(@as(usize, 3), p.pending.len);
    try testing.expect(p.pending[0] == .array);
    try testing.expect(p.pending[1] == .ref);
    try testing.expect(p.pending[2] == .array);
    try testing.expectEqual(@as(usize, 1), p.pending[0].array.len);
    try testing.expectEqualStrings("2", p.pending[2].array[0].scalar.value);

    var runs = [_]Node{
        n(.array, &a1), v(" "), n(.array, &a2), v(" "),
        subst,          v(" "), n(.array, &a3), v(" "),
        n(.array, &a4),
    };
    const q = try Value.fromNode(gpa, n(.concat, &runs));
    try testing.expectEqual(@as(usize, 3), q.pending.len);
    try testing.expectEqual(@as(usize, 2), q.pending[0].array.len);
    try testing.expectEqualStrings("1", q.pending[0].array[0].scalar.value);
    try testing.expectEqualStrings("2", q.pending[0].array[1].scalar.value);
    try testing.expect(q.pending[1] == .ref);
    try testing.expectEqual(@as(usize, 2), q.pending[2].array.len);
    try testing.expectEqualStrings("3", q.pending[2].array[0].scalar.value);
    try testing.expectEqualStrings("4", q.pending[2].array[1].scalar.value);
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
    const text = try Value.fromNode(gpa, n(.concat, &texts));
    try testing.expectEqualStrings("grumpy wombat", text.scalar.value);
    try testing.expect(text.scalar.quoted);

    var spaced = [_]Node{ v("1"), v(" "), v("\" x\"") };
    const joined = try Value.fromNode(gpa, n(.concat, &spaced));
    try testing.expectEqualStrings("1  x", joined.scalar.value);
    try testing.expect(joined.scalar.quoted);
}

// java ✓ · pyhocon ✓ · spec ✓ — the last kind, and the only one that goes
// deeper than the surface: objects merge by key, and a key held by both sides
// merges again if both hold an object, otherwise the right one wins.
//
//   'a = {x=1} {y=2}'            -> {"a":{"x":1,"y":2}}
//   'a = {b=1, c=2} {c=3, d=4}'  -> {"a":{"b":1,"c":3,"d":4}}   c keeps its place
//   'a = {b={c=1}} {b={d=2}}'    -> {"a":{"b":{"c":1,"d":2}}}
//   'a = {b=[1]} {b=[2]}'        -> {"a":{"b":[2]}}             not [1,2]
//
// That last one is the difference from a concatenation worth keeping in view:
// two lists written next to each other join, the same two lists arriving under
// one key do not.
test "value.objects merge by key, recursively" {
    if (true) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var m1 = [_]Node{ v("x"), v("1") };
    var m2 = [_]Node{ v("y"), v("2") };
    var b1 = [_]Node{n(.assignment, &m1)};
    var b2 = [_]Node{n(.assignment, &m2)};
    var objs = [_]Node{ n(.block, &b1), v(" "), n(.block, &b2) };
    const obj = try Value.fromNode(gpa, n(.concat, &objs));
    try testing.expectEqual(@as(usize, 2), obj.object.len);
    try testing.expectEqualStrings("x", obj.object[0].key.value);
    try testing.expectEqualStrings("y", obj.object[1].key.value);

    // a shared key keeps its position and takes the right-hand value
    var l1 = [_]Node{ v("b"), v("1") };
    var l2 = [_]Node{ v("c"), v("2") };
    var r1 = [_]Node{ v("c"), v("3") };
    var r2 = [_]Node{ v("d"), v("4") };
    var left = [_]Node{ n(.assignment, &l1), n(.assignment, &l2) };
    var right = [_]Node{ n(.assignment, &r1), n(.assignment, &r2) };
    var overlap = [_]Node{ n(.block, &left), v(" "), n(.block, &right) };
    const o = try Value.fromNode(gpa, n(.concat, &overlap));
    try testing.expectEqual(@as(usize, 3), o.object.len);
    try testing.expectEqualStrings("b", o.object[0].key.value);
    try testing.expectEqualStrings("c", o.object[1].key.value);
    try testing.expectEqualStrings("3", o.object[1].value.scalar.value);
    try testing.expectEqualStrings("d", o.object[2].key.value);

    // both sides an object under the same key: down one level
    var deep_l = [_]Node{ v("c"), v("1") };
    var deep_r = [_]Node{ v("d"), v("2") };
    var inner_l = [_]Node{n(.assignment, &deep_l)};
    var inner_r = [_]Node{n(.assignment, &deep_r)};
    var outer_l = [_]Node{ v("b"), n(.block, &inner_l) };
    var outer_r = [_]Node{ v("b"), n(.block, &inner_r) };
    var wrap_l = [_]Node{n(.assignment, &outer_l)};
    var wrap_r = [_]Node{n(.assignment, &outer_r)};
    var nested = [_]Node{ n(.block, &wrap_l), v(" "), n(.block, &wrap_r) };
    const d = try Value.fromNode(gpa, n(.concat, &nested));
    try testing.expectEqual(@as(usize, 1), d.object.len);
    try testing.expectEqual(@as(usize, 2), d.object[0].value.object.len);
    try testing.expectEqualStrings("c", d.object[0].value.object[0].key.value);
    try testing.expectEqualStrings("d", d.object[0].value.object[1].key.value);

    // anything but two objects: the right one wins outright, no joining
    var list_l = [_]Node{v("1")};
    var list_r = [_]Node{v("2")};
    var kl = [_]Node{ v("b"), n(.array, &list_l) };
    var kr = [_]Node{ v("b"), n(.array, &list_r) };
    var wl = [_]Node{n(.assignment, &kl)};
    var wr = [_]Node{n(.assignment, &kr)};
    var lists = [_]Node{ n(.block, &wl), v(" "), n(.block, &wr) };
    const w = try Value.fromNode(gpa, n(.concat, &lists));
    try testing.expectEqual(@as(usize, 1), w.object.len);
    try testing.expectEqual(@as(usize, 1), w.object[0].value.array.len);
    try testing.expectEqualStrings("2", w.object[0].value.array[0].scalar.value);
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
    const a = try Value.fromNode(gpa, n(.concat, &after));
    try testing.expectEqual(@as(usize, 2), a.pending.len);
    try testing.expect(a.pending[0] == .ref);
    try testing.expectEqualStrings("c", a.pending[1].scalar.value);

    var before = [_]Node{ v("\"c\""), sx };
    const b = try Value.fromNode(gpa, n(.concat, &before));
    try testing.expectEqual(@as(usize, 2), b.pending.len);
    try testing.expectEqualStrings("c", b.pending[0].scalar.value);
    try testing.expect(b.pending[1] == .ref);

    var with_list = [_]Node{ sx, n(.array, &elems) };
    const l = try Value.fromNode(gpa, n(.concat, &with_list));
    try testing.expectEqual(@as(usize, 2), l.pending.len);
    try testing.expect(l.pending[0] == .ref);
    try testing.expect(l.pending[1] == .array);

    var with_block = [_]Node{ sx, n(.block, &assigns) };
    const o = try Value.fromNode(gpa, n(.concat, &with_block));
    try testing.expectEqual(@as(usize, 2), o.pending.len);
    try testing.expect(o.pending[0] == .ref);
    try testing.expect(o.pending[1] == .object);
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
        Value.fromNode(gpa, n(.concat, &none)),
    );
}

// java ✓ · pyhocon ✓ · spec ✓ — 'Cannot concatenate object or list with a
// non-object-or-list' comes out of java at *parse* time; 'a = 1 [2]' never
// gets as far as resolve. The gap between the parts does not soften the pair:
// in '{b=1} "s"' the object stands against the string, the space belongs to
// neither.
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
            Value.fromNode(gpa, n(.concat, parts)),
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
    const a = try Value.fromNode(gpa, n(.concat, &alone));
    try testing.expectEqual(@as(usize, 3), a.pending.len);
    try testing.expect(a.pending[0] == .ref);
    try testing.expectEqualStrings(" ", a.pending[1].scalar.value);
    try testing.expect(a.pending[2] == .ref);

    // next to text it is a character of that text, from either side
    var right = [_]Node{ sx, v(" "), v("\"c\"") };
    const r = try Value.fromNode(gpa, n(.concat, &right));
    try testing.expectEqual(@as(usize, 2), r.pending.len);
    try testing.expect(r.pending[0] == .ref);
    try testing.expectEqualStrings(" c", r.pending[1].scalar.value);

    var left = [_]Node{ v("\"c\""), v(" "), sx };
    const l = try Value.fromNode(gpa, n(.concat, &left));
    try testing.expectEqual(@as(usize, 2), l.pending.len);
    try testing.expectEqualStrings("c ", l.pending[0].scalar.value);
    try testing.expect(l.pending[1] == .ref);

    // next to a container it is a separator and disappears
    var elems = [_]Node{v("1")};
    var with_list = [_]Node{ n(.array, &elems), v(" "), sx };
    const wl = try Value.fromNode(gpa, n(.concat, &with_list));
    try testing.expectEqual(@as(usize, 2), wl.pending.len);
    try testing.expect(wl.pending[0] == .array);
    try testing.expect(wl.pending[1] == .ref);

    var m = [_]Node{ v("b"), v("1") };
    var assigns = [_]Node{n(.assignment, &m)};
    var with_block = [_]Node{ sx, v(" "), n(.block, &assigns) };
    const wb = try Value.fromNode(gpa, n(.concat, &with_block));
    try testing.expectEqual(@as(usize, 2), wb.pending.len);
    try testing.expect(wb.pending[0] == .ref);
    try testing.expect(wb.pending[1] == .object);
}
