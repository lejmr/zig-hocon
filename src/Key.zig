//! One element of a path, cleaned up: no quotes, escapes applied.
//!
//! A type rather than a `[]const u8` because three places produce one and all
//! three have to agree on what "cleaned up" means: a key before `=`, an element
//! inside `${…}`, and whatever a caller passes to `get("a.b")`. When two of them
//! disagree, `a` and `"a"` stop being the same key, and in a debugger the two
//! look identical.
const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const unquote = @import("utils/unqoute.zig").unquote;
const Ast = @import("Ast.zig");
const Node = Ast.Node;

pub const Key = @This();
value: []const u8,

pub const Error = error{
    UnsupportedNodeKind,
    MalformedKey,
    InvalidEscape,
} || std.mem.Allocator.Error;

/// Builds one path element out of what `parseText` left in the tree: a `.value`
/// with the verbatim source slice, or a `.concat` of such parts, which join as
/// they would in a value — so `a "b" c` is the single key `a b c`. Quotes come
/// off and escapes are applied, which is what makes `a` and `"a"` equal here.
/// The text is allocated from `gpa`; pass the arena that owns the document.
pub fn fromNode(gpa: std.mem.Allocator, node: Node) Error!Key {
    return switch (node.kind) {
        .value => .{ .value = (try unquote(gpa, node.value)).text },
        .concat => blk: {
            var nodesToJoin: std.ArrayList([]const u8) = .empty;
            defer nodesToJoin.deinit(gpa);

            for (node.children) |n| {
                // Only values are supported
                if (n.kind != .value) return Error.MalformedKey;
                // Handle delimiters rightly - if multiline - leave as is otherwise trim
                try nodesToJoin.append(gpa, (try unquote(gpa, n.value)).text);
            }
            break :blk .{
                .value = try mem.concat(
                    gpa,
                    u8,
                    try nodesToJoin.toOwnedSlice(gpa),
                ),
            };
        },
        else => Error.UnsupportedNodeKind,
    };
}

pub fn eql(a: Key, b: Key) bool {
    return std.mem.eql(u8, a.value, b.value);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// A text part as `parseText` emits it: the verbatim source slice, quotes and
/// all. Building nodes by hand rather than parsing keeps these tests about
/// `Key` alone.
fn v(text: []const u8) Node {
    return .{ .kind = .value, .value = text, .children = &.{} };
}

fn expectKey(want: []const u8, node: Node) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const key = try fromNode(arena.allocator(), node);
    try testing.expectEqualStrings(want, key.value);
}

// java ✓ · pyhocon ⚠️ · spec ✓ — adjacent parts concatenate on the key side
// exactly as they do in a value, whitespace parts included:
//
//   'a "b" c = 1'  -> {"a b c":1}      the gap parts are real characters
//   'a"b" = 1'     -> {"ab":1}         no gap, nothing added
//   '"a""b" = 1'   -> {"ab":1}
//
// pyhocon rejects the mixed forms (see tools/oracle/README.md); java takes them.
test "key.concat joins its parts" {
    var spaced = [_]Node{ v("a"), v(" "), v("\"b\""), v(" "), v("c") };
    try expectKey("a b c", .{ .kind = .concat, .value = "", .children = &spaced });

    var glued = [_]Node{ v("a"), v("\"b\"") };
    try expectKey("ab", .{ .kind = .concat, .value = "", .children = &glued });
}

// A `.concat` may only hold text parts. `a ${b} = 1` is a parse error already,
// so this is a second lock on the same door — one that comes back as an error
// rather than as a key with a substitution silently dropped out of it.
test "key.concat takes text parts and nothing else" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var path = [_]Node{v("b")};
    var parts = [_]Node{ v("a"), .{ .kind = .subst, .value = "", .children = &path } };
    const node: Node = .{ .kind = .concat, .value = "", .children = &parts };
    try testing.expectError(Error.MalformedKey, fromNode(arena.allocator(), node));
}

// The parser rejects these already, so this is a second lock on the same door.
// If a container ever reaches here it must come back as an error rather than as
// a key made of nothing.
test "key.a block, an array or a substitution is not a key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var child = [_]Node{v("x")};

    for ([_]Node.NodeKind{ .block, .array, .subst, .subst_optional }) |kind| {
        errdefer std.debug.print("failed on {s}\n", .{@tagName(kind)});
        const node: Node = .{ .kind = kind, .value = "", .children = &child };
        try testing.expectError(Error.UnsupportedNodeKind, fromNode(arena.allocator(), node));
    }
}

// java ✓ · pyhocon ✓ · spec ✓ — the whole reason this is a type and not a
// `[]const u8`: how a key was written must not survive into its identity.
//
//   'a = 1, "a" = 2'  -> {"a":2}   one key, the second wins
//
// What `a` and `"a"` share is the text `unquote` hands back; the delimiter is
// where the difference stops.
test "key.eql ignores how it was written" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const plain = try fromNode(gpa, v("a"));
    try testing.expect(plain.eql(try fromNode(gpa, v("\"a\""))));
    try testing.expect(plain.eql(try fromNode(gpa, v("\"\"\"a\"\"\""))));
    try testing.expect(!plain.eql(try fromNode(gpa, v("b"))));
}
