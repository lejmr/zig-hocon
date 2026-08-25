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
        .value => .{ .value = try unquote(gpa, node.value) },
        .concat => blk: {
            var nodesToJoin: std.ArrayList([]const u8) = .empty;
            defer nodesToJoin.deinit(gpa);

            for (node.children) |n| {
                // Only values are supported
                if (n.kind != .value) return Error.MalformedKey;
                // Handle delimiters rightly - if multiline - leave as is otherwise trim
                try nodesToJoin.append(gpa, try unquote(gpa, n.value));
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

// Hocon uses JSON deserialization of strings hence to be compatible with other reference (java and pyhocon)
// we need to implement the same logic, but in zig way which doesn't know anything about UTF-8.
fn unquote(gpa: mem.Allocator, in: []const u8) Error![]const u8 {
    if (in.len >= 6 and mem.startsWith(u8, in, "\"\"\"") and mem.endsWith(u8, in, "\"\"\"")) {
        // Escapes stay literal inside a triple-quoted string.
        return in[3 .. in.len - 3];
    }
    const body = if (in.len >= 2 and in[0] == '"' and in[in.len - 1] == '"')
        in[1 .. in.len - 1]
    else
        in; // unquoted text arrives as it was written

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        if (body[i] != '\\') {
            try out.append(gpa, body[i]);
            continue;
        }
        // A backslash with nothing after it is an escape that never finished.
        if (i + 1 >= body.len) return Error.InvalidEscape;
        i += 1;
        try out.append(gpa, switch (body[i]) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'b' => 0x08,
            'f' => 0x0C,
            '"', '\\', '/' => body[i],
            // 'u' => ... TODO
            else => return Error.InvalidEscape,
        });
    }
    return out.toOwnedSlice(gpa);
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

// java ✓ · pyhocon ⚠️ · spec ✓ — each row is the key java ends up with:
//
//   'a = 1'    -> {"a":1}      '"a" = 1'   -> {"a":1}     '"" = 1'  -> {"":1}
//   '1 = x'    -> {"1":"x"}    'true = x'  -> {"true":"x"}
//   'a b = 1'  -> {"a b":1}    '"""a""" = 1' -> {"a":1}
//
// pyhocon rejects the mixed forms (see tools/oracle/README.md); java takes them.
//
// The point of the group: `a` and `"a"` must come out identical. Quotes are how
// a character gets into a key, not part of the key. A number or a keyword is
// ordinary text here, and interior whitespace belongs to the name.
test "key.quoting is syntax, not identity" {
    try expectKey("a", v("a"));
    try expectKey("a", v("\"a\""));
    try expectKey("", v("\"\""));
    try expectKey("1", v("1"));
    try expectKey("true", v("true"));
    try expectKey("a b", v("a b"));
    try expectKey("a", v("\"\"\"a\"\"\""));
}

// java ✓ · pyhocon ⚠️ · spec ✓ — adjacent parts concatenate on the key side
// exactly as they do in a value, whitespace parts included:
//
//   'a "b" c = 1'  -> {"a b c":1}      the gap parts are real characters
//   'a"b" = 1'     -> {"ab":1}         no gap, nothing added
//   '"a""b" = 1'   -> {"ab":1}
test "key.concat joins its parts" {
    var spaced = [_]Node{ v("a"), v(" "), v("\"b\""), v(" "), v("c") };
    try expectKey("a b c", .{ .kind = .concat, .value = "", .children = &spaced });

    var glued = [_]Node{ v("a"), v("\"b\"") };
    try expectKey("ab", .{ .kind = .concat, .value = "", .children = &glued });
}

// java ✓ · pyhocon ✓ · spec ✓ — escapes are processed in a quoted key exactly
// as in a quoted value, and left alone in a triple-quoted one:
//
//   '"a\nb" = 1'      -> {"a\nb":1}     a newline
//   '"a\"b" = 1'      -> {"a\"b":1}
//   '"""a\nb""" = 1'  -> {"a\\nb":1}    a backslash and an n
//
// This pair is why the tree carries the raw slice this far: the delimiter is
// the only thing saying which of the two it is.
test "key.escapes follow the delimiter" {
    try expectKey("a\nb", v("\"a\\nb\""));
    try expectKey("a\tb", v("\"a\\tb\""));
    try expectKey("a\"b", v("\"a\\\"b\""));
    try expectKey("a\\nb", v("\"\"\"a\\nb\"\"\""));
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

test "key.eql ignores how it was written" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const plain = try fromNode(gpa, v("a"));
    const quoted = try fromNode(gpa, v("\"a\""));
    try testing.expect(plain.eql(quoted));
    try testing.expect(!plain.eql(try fromNode(gpa, v("b"))));
}

// java ✓ · pyhocon ✓ · spec ✓ — a quote that arrived as content has to survive,
// and that only works if the delimiter comes off by its known width rather than
// by trimming whatever quotes happen to sit at the edges:
//
//   '"\"a\"" = 1'    -> {"\"a\"":1}    the key is  "a"  , quotes included
//   '"a\"" = 1'      -> {"a\"":1}
//   '""""a"""" = 1'  -> {"\"a\"":1}    the tokenizer ends a multiline string at
//                                      the LAST triple quote, so the extra pair
//                                      is content
//
// Trimming instead of slicing loses them, and the first row then collides with
// the plain key `a` — the identity confusion this whole type exists to prevent.
// It also leaves a lone `\` at the end, which the escape loop reads past.
test "key.a quote can be content" {
    try expectKey("\"a\"", v("\"\\\"a\\\"\""));
    try expectKey("a\"", v("\"a\\\"\""));
    try expectKey("\"a\"", v("\"\"\"\"a\"\"\"\""));
}
