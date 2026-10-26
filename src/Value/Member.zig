//! One `key = value` of an object.

const std = @import("std");
const Value = @import("../Value.zig").Value;
const Error = @import("../Value.zig").Error;
const Ref = @import("../Value.zig").Ref;
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

const Member = @This();

key: Key,
value: Value,
/// The key was set to an object over a non-object (`a = null`, `a { z = 3 }`),
/// so its value lost all it overrode (spec L1418), and merged onto an earlier
/// value of the key, from a file it is included into or an object it merges
/// with, it replaces that too.
hides: bool = false,

/// From an `.assignment` or an `.append`: `children[0]` is the key,
/// `children[1]` the value.
pub fn fromNode(gpa: std.mem.Allocator, node: Node, ctx: Value.Context) Error!Member {
    // Member can only by assignment type, with a key and a value
    if ((node.kind != .assignment and node.kind != .append) or node.children.len < 2) {
        ctx.fail(node.pos);
        return Error.UnsupportedNodeKind;
    }

    // Lets prepare key: one part, or the `concat` of parts one element can be
    const key_node = node.children[0];
    if (key_node.kind != .value and key_node.kind != .concat) {
        ctx.fail(key_node.pos);
        return Error.UnsupportedNodeKind;
    }

    const key = try Key.fromNode(gpa, key_node, ctx);
    // Below this key, an include knows where it is.
    const frame: Value.Frame = .{ .parent = ctx.frame, .key = key };
    var inner = ctx;
    inner.frame = &frame;
    // `a += b` puts b in a list, so a way down inside b starts at that
    // element, as in any list (`Value.Frame`).
    const element: Value.Frame = .{ .parent = &frame, .key = .{ .value = "" }, .element = true };
    if (node.kind == .append) {
        inner.frame = &element;
        inner.elements = ctx.elements + 1;
    }
    const value = try Value.fromNode(gpa, node.children[1], inner);
    if (node.kind != .append) return .{ .key = key, .value = value };

    // `a += b` is `a = ${?a} [b]`, where `a` is the field's whole path: the
    // include's scope, then the keys from the file's root down to this one;
    // in a list element, the keys from the element down (`Value.wayDown`).
    const way = try Value.wayDown(gpa, ctx, &frame);
    const self_ref: Ref = .{
        .path = try std.mem.concat(gpa, Key, &.{ way.scope, way.keys }),
        .flags = .{ .optional = true, .append = true, .anchor = way.anchor },
        .scope_len = @intCast(way.scope.len),
        .file = ctx.file,
        .pos = @intCast(node.pos),
    };
    const parts = try gpa.dupe(Value.Part, &.{
        .{ .value = .{ .ref = self_ref }, .pos = self_ref.at() },
        .{ .value = .{ .array = try gpa.dupe(Value, &.{value}) }, .pos = .{ .file = ctx.file, .offset = node.children[1].pos } },
    });
    return .{ .key = key, .value = .{ .pending = parts } };
}

pub fn update(self: *Member, gpa: std.mem.Allocator, other: Member) Error!void {
    if (self.value == .object and other.value == .object) {
        try self.value.update(gpa, other.value);
    } else {
        self.value.* = other.value;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// An assignment is a key and a value. One without both is a tree the parser
// never builds, refused rather than read past its end.
test "value.an assignment without a value is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var key_only = [_]Node{v("a")};
    var members = [_]Node{n(.assignment, &key_only)};
    try testing.expectError(Error.UnsupportedNodeKind, build(gpa, n(.block, &members)));
    var empty = [_]Node{n(.assignment, &.{})};
    try testing.expectError(Error.UnsupportedNodeKind, build(gpa, n(.block, &empty)));
}
// `a.b += 1` loads as `b = ${?a.b} [1]` under `a`: the ref carries the whole
// path down to the member, the include's scope in front, so it can be told
// apart from a plain `${?b}` and looked up from the root.
test "value.+= is an optional self-reference and a one-element list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var inner = [_]Node{ v("b"), v("1") };
    var appends = [_]Node{n(.append, &inner)};
    var outer = [_]Node{ v("a"), n(.block, &appends) };
    var members = [_]Node{n(.assignment, &outer)};
    const scope = [_]Key{.{ .value = "inc" }};
    const o = try Value.fromNode(gpa, n(.block, &members), .{ .scope = &scope });

    const parts = o.object[0].value.object[0].value.pending;
    try testing.expectEqual(@as(usize, 2), parts.len);
    const r = parts[0].value.ref;
    try testing.expect(r.flags.optional);
    try testing.expectEqual(@as(u16, 1), r.scope_len);
    try testing.expectEqual(@as(usize, 3), r.path.len);
    for ([_][]const u8{ "inc", "a", "b" }, r.path) |want, got| try testing.expectEqualStrings(want, got.value);
    try testing.expectEqualStrings("1", parts[1].value.array[0].scalar.value);
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
    const o = try build(gpa, n(.block, &members));
    try testing.expectEqual(@as(usize, 2), o.object.len);
    try testing.expectEqualStrings("ab", o.object[0].key.value);
    try testing.expectEqualStrings("a b", o.object[1].key.value);
    try testing.expectEqualStrings("c", o.object[1].value.scalar.value);
}
