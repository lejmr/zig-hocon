//! Value holder for received data

const std = @import("std");
const testing = std.testing;
const Key = @import("Key.zig");
const Ast = @import("Ast.zig");
const Node = Ast.Node;

pub const Error = error{UnsupportedNodeKind} || Key.Error;

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
        _ = gpa;
        _ = node;
        @panic("TODO");
    }
};

// PLace holder for any string or number
const Scalar = struct {
    value: []const u8,
    quoted: bool,

    /// `quoted` has to be read off the raw slice before the quotes come off:
    /// afterwards `a = "1"` and `a = 1` are the same text.
    pub fn fromNode(gpa: std.mem.Allocator, node: Node) Error!Scalar {
        _ = gpa;
        _ = node;
        @panic("TODO");
    }
};
const Member = struct {
    key: Key,
    value: Value,

    /// From an `.assignment`: `children[0]` is the key, `children[1]` the value.
    pub fn fromNode(gpa: std.mem.Allocator, node: Node) Error!Member {
        _ = gpa;
        _ = node;
        @panic("TODO");
    }
};
const Ref = struct {
    path: []const Key,
    optional: bool,

    /// The child holds the path as it was written; split it on `.` here so
    /// `resolve` never parses. A quoted dot has no answer yet.
    pub fn fromNode(gpa: std.mem.Allocator, node: Node) Error!Ref {
        _ = gpa;
        _ = node;
        @panic("TODO");
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
