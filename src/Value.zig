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
                // A braced root `{a = 1}` is `root(block(...))`: the block is the document.
                if (node.kind == .root and node.children.len == 1 and node.children[0].kind == .block)
                    return Value.fromNode(gpa, node.children[0]);

                var members_map: std.StringArrayHashMapUnmanaged(Value) = .empty;
                defer members_map.deinit(gpa);

                for (node.children) |assignment| {
                    if (assignment.kind != .assignment) return Error.UnsupportedNodeKind;
                    if (assignment.children.len < 2) return Error.InvalidAssignment;
                    const member = try Member.fromNode(gpa, assignment);
                    if (members_map.getPtr(member.key.value)) |current_v| {
                        if (current_v.* == .object and member.value == .object) {
                            try current_v.update(gpa, member.value);
                        } else {
                            current_v.* = member.value;
                        }
                    } else {
                        try members_map.put(gpa, member.key.value, member.value);
                    }
                }
                var members: std.ArrayList(Member) = .empty;
                for (members_map.keys(), members_map.values()) |k, val| {
                    try members.append(gpa, .{ .key = .{ .value = k }, .value = val });
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
                        if (ebuffer.* == .ref or tag == .ref) {
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
                // Convert self block to hasmap
                var map: std.StringArrayHashMapUnmanaged(Value) = .empty;
                defer map.deinit(gpa);
                for (self.object) |m| {
                    if (map.getPtr(m.key.value)) |current_v| {
                        if (current_v.* == .object and m.value == .object) {
                            try current_v.update(gpa, m.value);
                        } else {
                            current_v.* = m.value;
                        }
                    } else {
                        try map.put(gpa, m.key.value, m.value);
                    }
                }

                // Update self about other
                for (other.object) |oo| {
                    if (map.getPtr(oo.key.value)) |current_v| {
                        if (current_v.* == .object and oo.value == .object) {
                            try current_v.update(gpa, oo.value);
                        } else {
                            current_v.* = oo.value;
                        }
                    } else {
                        try map.put(gpa, oo.key.value, oo.value);
                    }
                }

                // Convert to list of Members
                var merged: std.ArrayList(Member) = .empty;
                for (map.keys(), map.values()) |k, val| {
                    try merged.append(gpa, .{ .key = .{ .value = k }, .value = val });
                }
                self.object = try merged.toOwnedSlice(gpa);
            },
            else => return Error.UnsupportedConcatenation,
        }
    }

    /// Found by `std.json.Stringify` on its own, the way `std.json.Value` is:
    /// `std.json.Stringify.value(v, .{}, writer)` then prints the tree as JSON.
    ///
    /// A scalar is text here, and JSON wants a type. Quoted is always a string;
    /// unquoted `true`/`false`/`null` are themselves, unquoted text that is a
    /// JSON number is a number printed as written, and anything else a string.
    /// A `.ref` or `.pending` cannot be printed before resolving.
    pub fn jsonStringify(self: Value, jw: anytype) !void {
        switch (self) {
            .scalar => |s| {
                if (s.quoted) return jw.write(s.value);
                if (std.mem.eql(u8, s.value, "true")) return jw.write(true);
                if (std.mem.eql(u8, s.value, "false")) return jw.write(false);
                if (std.mem.eql(u8, s.value, "null")) return jw.write(null);
                // Printed as written, not parsed and re-rendered: 1e5 stays 1e5.
                if (isJsonNumber(s.value)) return jw.print("{s}", .{s.value});
                return jw.write(s.value);
            },
            // `jw.write` on a Value comes back here: the recursion is std's.
            .array => |items| try jw.write(items),
            .object => |members| {
                try jw.beginObject();
                for (members) |m| {
                    try jw.objectField(m.key.value);
                    try jw.write(m.value);
                }
                try jw.endObject();
            },
            // Stringify allows no error of its own, so an unresolved tree is refused
            // earlier, by `parseFromSlice(Value, …)`. Only a hand-built Value gets here.
            .ref, .pending => return error.WriteFailed,
        }
    }

    /// No `.ref` or `.pending` anywhere below: nothing left for resolving to do.
    pub fn isResolved(self: Value) bool {
        return switch (self) {
            .scalar => true,
            .array => |items| for (items) |item| {
                if (!item.isResolved()) break false;
            } else true,
            .object => |members| for (members) |m| {
                if (!m.value.isResolved()) break false;
            } else true,
            .ref, .pending => false,
        };
    }

    /// JSON's number grammar, all of the text or nothing:
    /// `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`
    /// So `.5`, `1.`, `01` and `1 2` are not numbers.
    fn isJsonNumber(text: []const u8) bool {
        var i: usize = 0;
        if (i < text.len and text[i] == '-') i += 1;

        // Integer part: a lone 0, or a non-zero digit and any digits after it.
        if (i >= text.len or !std.ascii.isDigit(text[i])) return false;
        if (text[i] == '0') i += 1 else i = skipDigits(text, i);

        if (i < text.len and text[i] == '.') {
            const start = i + 1;
            i = skipDigits(text, start);
            if (i == start) return false;
        }

        if (i < text.len and (text[i] == 'e' or text[i] == 'E')) {
            i += 1;
            if (i < text.len and (text[i] == '+' or text[i] == '-')) i += 1;
            const start = i;
            i = skipDigits(text, start);
            if (i == start) return false;
        }

        return i == text.len;
    }

    fn skipDigits(text: []const u8, from: usize) usize {
        var i = from;
        while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
        return i;
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

        // Lets prepare key: one part, or the `concat` of parts one element can be
        const key_node = node.children[0];
        if (key_node.kind != .value and key_node.kind != .concat) return Error.UnsupportedNodeKind;

        // Loads load the Value
        const val = try Value.fromNode(gpa, node.children[1]);
        return .{
            .key = try Key.fromNode(gpa, key_node),
            .value = val,
        };
    }

    pub fn update(self: *Member, gpa: std.mem.Allocator, other: Member) Error!void {
        if (self.value == .object and other.value == .object) {
            try self.value.update(gpa, other.value);
        } else {
            self.value.* = other.value;
        }
    }
};
const Ref = struct {
    path: []const Key,
    optional: bool,

    pub fn fromNode(gpa: std.mem.Allocator, node: Node) Error!Ref {
        var single = [_]Node{node.children[0]};
        const parts: []const Node = switch (node.children[0].kind) {
            .value => &single,
            .concat => node.children[0].children,
            else => return Error.UnsupportedNodeKind,
        };

        var key_list: std.ArrayList(Key) = .empty;
        var current: std.ArrayList(u8) = .empty;
        defer current.deinit(gpa);
        var written = false;

        for (parts) |part| {
            if (part.kind != .value) return Error.MalformedKey;
            const ut = try unqoute.unquote(gpa, part.value);
            if (ut.quoted) {
                try current.appendSlice(gpa, ut.text);
                written = true;
                continue;
            }

            var it = std.mem.splitScalar(u8, ut.text, '.');
            try current.appendSlice(gpa, it.first());
            while (it.next()) |x| {
                if (current.items.len == 0 and !written) return Error.MalformedKey;
                try key_list.append(gpa, .{ .value = try gpa.dupe(u8, current.items) });
                current.clearRetainingCapacity();
                written = false;
                try current.appendSlice(gpa, x);
            }
        }
        if (current.items.len == 0 and !written) return Error.MalformedKey;
        try key_list.append(gpa, .{ .value = try gpa.dupe(u8, current.items) });

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

// java ✓ · pyhocon ✓ · spec ✓ — a key written twice inside one block is one
// member, and the rule under it is the merge rule, not the concatenation one:
//
//   'a = {b=1, b=2}'          -> {"a":{"b":2}}
//   'a = {b=1, c=2, b=3}'     -> {"a":{"b":3,"c":2}}     b keeps its place
//   'a = {b={x=1}, b={y=2}}'  -> {"a":{"b":{"x":1,"y":2}}}
//   'a = {b=[1], b=[2]}'      -> {"a":{"b":[2]}}         not [1,2]
//   'a = {b={x=1}, b=2}'      -> {"a":{"b":2}}
//
// Two lists written next to each other join; the same two arriving under one
// key do not. That is the whole difference between the two operations, and it
// is why this cannot be `update`.
test "value.a key written twice in one block is one member" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var d1 = [_]Node{ v("b"), v("1") };
    var d2 = [_]Node{ v("b"), v("2") };
    var dup = [_]Node{ n(.assignment, &d1), n(.assignment, &d2) };
    const one = try Value.fromNode(gpa, n(.block, &dup));
    try testing.expectEqual(@as(usize, 1), one.object.len);
    try testing.expectEqualStrings("b", one.object[0].key.value);
    try testing.expectEqualStrings("2", one.object[0].value.scalar.value);

    // the surviving member keeps the position of the first spelling
    var o1 = [_]Node{ v("b"), v("1") };
    var o2 = [_]Node{ v("c"), v("2") };
    var o3 = [_]Node{ v("b"), v("3") };
    var ordered = [_]Node{ n(.assignment, &o1), n(.assignment, &o2), n(.assignment, &o3) };
    const ord = try Value.fromNode(gpa, n(.block, &ordered));
    try testing.expectEqual(@as(usize, 2), ord.object.len);
    try testing.expectEqualStrings("b", ord.object[0].key.value);
    try testing.expectEqualStrings("3", ord.object[0].value.scalar.value);
    try testing.expectEqualStrings("c", ord.object[1].key.value);

    // both sides an object: down one level
    var ix = [_]Node{ v("x"), v("1") };
    var iy = [_]Node{ v("y"), v("2") };
    var bx = [_]Node{n(.assignment, &ix)};
    var by = [_]Node{n(.assignment, &iy)};
    var n1 = [_]Node{ v("b"), n(.block, &bx) };
    var n2 = [_]Node{ v("b"), n(.block, &by) };
    var nested = [_]Node{ n(.assignment, &n1), n(.assignment, &n2) };
    const deep = try Value.fromNode(gpa, n(.block, &nested));
    try testing.expectEqual(@as(usize, 1), deep.object.len);
    try testing.expectEqual(@as(usize, 2), deep.object[0].value.object.len);
    try testing.expectEqualStrings("x", deep.object[0].value.object[0].key.value);
    try testing.expectEqualStrings("y", deep.object[0].value.object[1].key.value);

    // anything else: the right one wins outright, lists included
    var e1 = [_]Node{v("1")};
    var e2 = [_]Node{v("2")};
    var l1 = [_]Node{ v("b"), n(.array, &e1) };
    var l2 = [_]Node{ v("b"), n(.array, &e2) };
    var lists = [_]Node{ n(.assignment, &l1), n(.assignment, &l2) };
    const won = try Value.fromNode(gpa, n(.block, &lists));
    try testing.expectEqual(@as(usize, 1), won.object.len);
    try testing.expectEqual(@as(usize, 1), won.object[0].value.array.len);
    try testing.expectEqualStrings("2", won.object[0].value.array[0].scalar.value);
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
    const p = try Value.fromNode(gpa, n(.subst, &plain));
    try testing.expectEqual(@as(usize, 2), p.ref.path.len);
    try testing.expectEqualStrings("x", p.ref.path[0].value);
    try testing.expectEqualStrings("y", p.ref.path[1].value);

    var parts = [_]Node{ v("x."), v("\"y.z\"") };
    var quoted_tail = [_]Node{n(.concat, &parts)};
    const q = try Value.fromNode(gpa, n(.subst, &quoted_tail));
    try testing.expectEqual(@as(usize, 2), q.ref.path.len);
    try testing.expectEqualStrings("x", q.ref.path[0].value);
    try testing.expectEqualStrings("y.z", q.ref.path[1].value);

    var whole = [_]Node{v("\"a.b\"")};
    const w = try Value.fromNode(gpa, n(.subst, &whole));
    try testing.expectEqual(@as(usize, 1), w.ref.path.len);
    try testing.expectEqualStrings("a.b", w.ref.path[0].value);

    var single = [_]Node{v("x")};
    const one = try Value.fromNode(gpa, n(.subst, &single));
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
        const r = try Value.fromNode(gpa, n(.subst, &child));
        try testing.expectEqual(expected.len, r.ref.path.len);
        for (expected, r.ref.path) |e, got| try testing.expectEqualStrings(e, got.value);
    }
}

// java ✓ · pyhocon ⚠️ · spec ✓ — an element made of several parts is one key
// at load, the way `Key.fromNode` already joins it:
//
//   'a"b" = 1'    -> {"ab":1}       '"a" b = c'  -> {"a b":"c"}
//
// Such keys reach here routinely now that the parser splits `a"b".c` into
// elements, so a `concat` key node is a member like any other. pyhocon rejects
// the mixed spelling (see tools/oracle/README.md).
test "value.a key made of several parts is one member" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var glued = [_]Node{ v("a"), v("\"b\"") };
    var m1 = [_]Node{ n(.concat, &glued), v("1") };
    var spaced = [_]Node{ v("\"a\""), v(" "), v("b") };
    var m2 = [_]Node{ n(.concat, &spaced), v("c") };
    var members = [_]Node{ n(.assignment, &m1), n(.assignment, &m2) };
    const o = try Value.fromNode(gpa, n(.block, &members));
    try testing.expectEqual(@as(usize, 2), o.object.len);
    try testing.expectEqualStrings("ab", o.object[0].key.value);
    try testing.expectEqualStrings("a b", o.object[1].key.value);
    try testing.expectEqualStrings("c", o.object[1].value.scalar.value);
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
// so the ref is where they have to stop: the same splitter that cuts the path
// is the one that knows an element came out empty without quotes to say so.
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
        try testing.expectError(Error.MalformedKey, Value.fromNode(gpa, n(.subst, &child)));
    }

    // Written as `""`, the empty element is an element like any other.
    var ok1 = [_]Node{ v("\"\""), v(".b") };
    var ok2 = [_]Node{ v("b."), v("\"\"") };
    const want = [_][]const []const u8{ &.{ "", "b" }, &.{ "b", "" } };
    for ([_][]Node{ &ok1, &ok2 }, want, 0..) |path_parts, expected, i| {
        errdefer std.debug.print("failed on legal path {d}\n", .{i});
        var child = [_]Node{n(.concat, path_parts)};
        const r = try Value.fromNode(gpa, n(.subst, &child));
        try testing.expectEqual(expected.len, r.ref.path.len);
        for (expected, r.ref.path) |e, got| try testing.expectEqualStrings(e, got.value);
    }
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
    const arr = try Value.fromNode(gpa, n(.array, &elems));
    try testing.expectEqual(@as(usize, 1), arr.array.len);
    try testing.expect(arr.array[0] == .ref);

    var inner = [_]Node{ sx, v(" "), n(.array, &e1) };
    var wrapped = [_]Node{n(.concat, &inner)};
    const nested = try Value.fromNode(gpa, n(.array, &wrapped));
    try testing.expectEqual(@as(usize, 1), nested.array.len);
    try testing.expectEqual(@as(usize, 2), nested.array[0].pending.len);
    try testing.expect(nested.array[0].pending[0] == .ref);
    try testing.expect(nested.array[0].pending[1] == .array);

    var member = [_]Node{ v("b"), n(.concat, &inner) };
    var members = [_]Node{n(.assignment, &member)};
    const obj = try Value.fromNode(gpa, n(.block, &members));
    try testing.expectEqual(@as(usize, 1), obj.object.len);
    try testing.expectEqualStrings("b", obj.object[0].key.value);
    try testing.expectEqual(@as(usize, 2), obj.object[0].value.pending.len);
    try testing.expect(obj.object[0].value.pending[0] == .ref);
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
    const p = try Value.fromNode(gpa, n(.concat, &parts));
    try testing.expectEqual(@as(usize, 2), p.pending.len);
    try testing.expect(p.pending[0] == .ref);
    try testing.expect(p.pending[0].ref.optional);
    try testing.expect(p.pending[1] == .array);

    // and between two texts the gap is still a part of its own
    var texts = [_]Node{ v("1"), v(" "), n(.subst_optional, &px), v(" "), v("2") };
    const t = try Value.fromNode(gpa, n(.concat, &texts));
    try testing.expectEqual(@as(usize, 3), t.pending.len);
    try testing.expectEqualStrings("1 ", t.pending[0].scalar.value);
    try testing.expect(t.pending[1].ref.optional);
    try testing.expectEqualStrings(" 2", t.pending[2].scalar.value);
}

// java ✓ · pyhocon ✓ · spec ✓ — `null`, `true` and a number are unquoted text
// and nothing more until type conversion, so they join and fail like any other:
//
//   'a = null'      -> {"a":null}       kept as written
//   'a = null "x"'  -> {"a":"null x"}   joins as text
//   'a = 1.5e10'    -> {"a":15000000000}  java converts, this layer does not
//   'a = [1] null'  -> WrongType        a list and a non-list, as ever
//
// Reading a type out of the text belongs to evaluation; giving one to it here
// would mean `a = "null"` and `a = null` stopped being distinguishable, which
// is the whole reason a scalar carries its delimiter as a flag.
test "value.null, booleans and numbers are text at this layer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    for ([_][]const u8{ "null", "true", "false", "1.5e10" }) |word| {
        errdefer std.debug.print("failed on {s}\n", .{word});
        const val = try Value.fromNode(gpa, v(word));
        try testing.expectEqualStrings(word, val.scalar.value);
        try testing.expect(!val.scalar.quoted);
    }

    var joined = [_]Node{ v("null"), v(" "), v("\"x\"") };
    const j = try Value.fromNode(gpa, n(.concat, &joined));
    try testing.expectEqualStrings("null x", j.scalar.value);

    var e1 = [_]Node{v("1")};
    var mixed = [_]Node{ n(.array, &e1), v(" "), v("null") };
    try testing.expectError(
        Error.UnsupportedConcatenation,
        Value.fromNode(gpa, n(.concat, &mixed)),
    );
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
            Value.fromNode(gpa, n(.concat, parts)),
        );
    }

    var texts = [_]Node{ v("\"\""), v(" "), v("\"x\"") };
    const t = try Value.fromNode(gpa, n(.concat, &texts));
    try testing.expectEqualStrings(" x", t.scalar.value);
}

// java ✓ · pyhocon ✓ · spec ✓ — an empty container is a part like any other
// and contributes nothing:
//
//   'a = [] [1]'       -> {"a":[1]}
//   'a = {} {b=1}'     -> {"a":{"b":1}}
//   'a = {b=1} {}'     -> {"a":{"b":1}}
//   'a = {} {}'        -> {"a":{}}
//   'a = {} [1]'       -> WrongType      empty or not, a kind is a kind
test "value.an empty container joins without adding anything" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var none = [_]Node{};
    var e1 = [_]Node{v("1")};
    var m = [_]Node{ v("b"), v("1") };
    var assigns = [_]Node{n(.assignment, &m)};

    var lists = [_]Node{ n(.array, &none), v(" "), n(.array, &e1) };
    const l = try Value.fromNode(gpa, n(.concat, &lists));
    try testing.expectEqual(@as(usize, 1), l.array.len);

    var left_empty = [_]Node{ n(.block, &none), v(" "), n(.block, &assigns) };
    const le = try Value.fromNode(gpa, n(.concat, &left_empty));
    try testing.expectEqual(@as(usize, 1), le.object.len);
    try testing.expectEqualStrings("b", le.object[0].key.value);

    var right_empty = [_]Node{ n(.block, &assigns), v(" "), n(.block, &none) };
    const re = try Value.fromNode(gpa, n(.concat, &right_empty));
    try testing.expectEqual(@as(usize, 1), re.object.len);

    var both = [_]Node{ n(.block, &none), v(" "), n(.block, &none) };
    const b = try Value.fromNode(gpa, n(.concat, &both));
    try testing.expectEqual(@as(usize, 0), b.object.len);

    var crossed = [_]Node{ n(.block, &none), v(" "), n(.array, &e1) };
    try testing.expectError(
        Error.UnsupportedConcatenation,
        Value.fromNode(gpa, n(.concat, &crossed)),
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
    const s1 = try Value.fromNode(gpa, n(.concat, &simple));
    try testing.expectEqualStrings("a b", s1.scalar.value);
    try testing.expect(s1.scalar.quoted);

    // inside """ a backslash-n is those two characters; the quoted part beside
    // it turns its own into a newline, and both survive the join as they are
    var mixed = [_]Node{ v("\"\"\"a\\nb\"\"\""), v(" "), v("\"c\\nd\"") };
    const s2 = try Value.fromNode(gpa, n(.concat, &mixed));
    try testing.expectEqualStrings("a\\nb c\nd", s2.scalar.value);

    var leading = [_]Node{ v("x"), v(" "), v("\"\"\"y\"\"\"") };
    const s3 = try Value.fromNode(gpa, n(.concat, &leading));
    try testing.expectEqualStrings("x y", s3.scalar.value);
}

// java ✓ · pyhocon ✓ · spec ✓ — the remaining shapes, each a one-liner:
//
//   'a = [1]\t[2]'          -> {"a":[1,2]}          a tab separates too
//   'a = {b=1}\t{c=2}'      -> {"a":{"b":1,"c":2}}
//   'a = {a=1} {b=2} {a=3}'  -> {"a":{"a":3,"b":2}}  a key met twice, not adjacent
test "value.tabs separate, and a key can be met more than twice" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var e1 = [_]Node{v("1")};
    var e2 = [_]Node{v("2")};
    var tabbed = [_]Node{ n(.array, &e1), v("\t"), n(.array, &e2) };
    const t = try Value.fromNode(gpa, n(.concat, &tabbed));
    try testing.expectEqual(@as(usize, 2), t.array.len);

    var k1 = [_]Node{ v("a"), v("1") };
    var k2 = [_]Node{ v("b"), v("2") };
    var k3 = [_]Node{ v("a"), v("3") };
    var b1 = [_]Node{n(.assignment, &k1)};
    var b2 = [_]Node{n(.assignment, &k2)};
    var b3 = [_]Node{n(.assignment, &k3)};
    var three = [_]Node{ n(.block, &b1), v(" "), n(.block, &b2), v(" "), n(.block, &b3) };
    const o = try Value.fromNode(gpa, n(.concat, &three));
    try testing.expectEqual(@as(usize, 2), o.object.len);
    try testing.expectEqualStrings("a", o.object[0].key.value);
    try testing.expectEqualStrings("3", o.object[0].value.scalar.value);
    try testing.expectEqualStrings("b", o.object[1].key.value);
}
