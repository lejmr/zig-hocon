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
