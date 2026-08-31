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
} || Key.Error || unqoute.Error;

pub const Value = union(enum) {
    scalar: Scalar,
    array: []Value,
    object: []Member,
    ref: Ref,

    // For right updates of already stored data, but not yet resolved
    pending: struct { parts: []Value, join: enum { set, merge } },

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
                var want: ?std.meta.Tag(Value) = null;

                for (node.children) |ch| {
                    // Skip empty strings
                    if (ch.kind == .value) {
                        const trimmed = std.mem.trim(u8, ch.value, " \t");
                        if (trimmed.len == 0) continue;
                    }
                    // Here are on bare nodes
                    const val = try Value.fromNode(gpa, ch);

                    // Keep same type or explode
                    const tag = std.meta.activeTag(val);
                    if (tag != .ref) {
                        if (want == null) want = tag;
                        if (want.? != tag) return Error.UnsupportedConcatenation;
                    }
                    try values.append(gpa, val);
                }

                // Concat Value objects
                const w = want orelse return Error.UnsupportedConcatenation;
                return switch (w) {
                    .array => {
                        var concated: std.ArrayList(Value) = .empty;
                        for (values.items) |vi| {
                            for (vi.array) |pv| {
                                try concated.append(gpa, pv);
                            }
                        }
                        return .{ .array = try concated.toOwnedSlice(gpa) };
                    },
                    else => return Error.UnsupportedConcatenation,
                };
            },
            else => Error.UnsupportedNodeKind,
        };
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

// java ✓ · pyhocon ✓ · spec ✓ — a concatenation of one kind is finished the
// moment it is loaded, no resolve involved:
//
//   'a = [1] [2]'         -> {"a":[1,2]}           flat, never a list of lists
//   'a = {x=1} {y=2}'     -> {"a":{"x":1,"y":2}}
//   'a = grumpy "wombat"' -> "grumpy wombat"       gaps are characters here
//   'a = 1 " x"'          -> "1  x"                gap + quoted leading space
//
// A text join can only arise when a quoted part is involved (adjacent unquoted
// text is one slice already), so the joined scalar is quoted: '1 " x"' can
// never be a number again.
test "value.parts of one kind join at load" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var a1 = [_]Node{v("1")};
    var a2 = [_]Node{v("2")};
    var arrs = [_]Node{ n(.array, &a1), v(" "), n(.array, &a2) };
    const arr = try Value.fromNode(gpa, n(.concat, &arrs));
    try testing.expectEqual(@as(usize, 2), arr.array.len);
    try testing.expectEqualStrings("1", arr.array[0].scalar.value);
    try testing.expectEqualStrings("2", arr.array[1].scalar.value);

    // var m1 = [_]Node{ v("x"), v("1") };
    // var m2 = [_]Node{ v("y"), v("2") };
    // var b1 = [_]Node{n(.assignment, &m1)};
    // var b2 = [_]Node{n(.assignment, &m2)};
    // var objs = [_]Node{ n(.block, &b1), v(" "), n(.block, &b2) };
    // const obj = try Value.fromNode(gpa, n(.concat, &objs));
    // try testing.expectEqual(@as(usize, 2), obj.object.len);
    // try testing.expectEqualStrings("x", obj.object[0].key.value);
    // try testing.expectEqualStrings("y", obj.object[1].key.value);

    // var texts = [_]Node{ v("grumpy"), v(" "), v("\"wombat\"") };
    // const text = try Value.fromNode(gpa, n(.concat, &texts));
    // try testing.expectEqualStrings("grumpy wombat", text.scalar.value);
    // try testing.expect(text.scalar.quoted);

    // var spaced = [_]Node{ v("1"), v(" "), v("\" x\"") };
    // const joined = try Value.fromNode(gpa, n(.concat, &spaced));
    // try testing.expectEqualStrings("1  x", joined.scalar.value);
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

    var scalar_array = [_]Node{ v("1"), v(" "), array };
    var array_block = [_]Node{ array, v(" "), block };
    var block_scalar = [_]Node{ block, v(" "), v("\"s\"") };
    for ([_][]Node{ &scalar_array, &array_block, &block_scalar }) |parts| {
        try testing.expectError(
            Error.UnsupportedConcatenation,
            Value.fromNode(gpa, n(.concat, parts)),
        );
    }
}

// java ✓ · pyhocon ⚠️ · spec ✓ — a substitution's type is unknown until
// resolve, so no check crosses one: '"1" ${x} [2]' loads fine, and only
// resolving 'x = 9' turns it into WrongType. What *is* checked at load are
// adjacent concrete parts: '"1" [2] ${x}' fails even with the ref stood right
// there. (pyhocon cannot print an unresolved substitution, so only the error
// half is comparable.)
//
// The pending parts keep the written order — 'x = [7]' resolves the middle to
// [1,7,2] — and the gaps next to containers are gone by then: pending is what
// resolve consumes, and resolve gets meaning, not syntax.
test "value.a ref between parts defers the type check" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var a1 = [_]Node{v("1")};
    var a2 = [_]Node{v("2")};
    var path = [_]Node{v("x")};
    const subst = n(.subst, &path);

    var deferred = [_]Node{ n(.array, &a1), v(" "), subst, v(" "), n(.array, &a2) };
    const p = try Value.fromNode(gpa, n(.concat, &deferred));
    try testing.expectEqual(@as(usize, 3), p.pending.parts.len);
    try testing.expect(p.pending.parts[0] == .array);
    try testing.expect(p.pending.parts[1] == .ref);
    try testing.expect(p.pending.parts[2] == .array);
    try testing.expectEqualStrings("1", p.pending.parts[0].array[0].scalar.value);
    try testing.expectEqualStrings("2", p.pending.parts[2].array[0].scalar.value);

    var adjacent = [_]Node{ v("\"1\""), v(" "), n(.array, &a2), v(" "), subst };
    try testing.expectError(
        Error.UnsupportedConcatenation,
        Value.fromNode(gpa, n(.concat, &adjacent)),
    );
}

// java ✓ · pyhocon ⚠️ · spec ✓ — 'a = ${x} ${y}' prints back from java as
// ${x}" "${y}: both sides may yet turn out to be strings, so the gap has to
// survive into resolve as a part of its own. Next to a container it cannot
// mean anything and does not (see the test above).
test "value.the gap between two refs is a part in waiting" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var px = [_]Node{v("x")};
    var py = [_]Node{v("y")};
    var parts = [_]Node{ n(.subst, &px), v(" "), n(.subst, &py) };
    const p = try Value.fromNode(gpa, n(.concat, &parts));
    try testing.expectEqual(@as(usize, 3), p.pending.parts.len);
    try testing.expect(p.pending.parts[0] == .ref);
    try testing.expectEqualStrings(" ", p.pending.parts[1].scalar.value);
    try testing.expect(p.pending.parts[2] == .ref);
}
