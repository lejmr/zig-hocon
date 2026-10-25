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
const Tokenizer = @import("Tokenizer.zig").Tokenizer;
const Diagnostics = @import("Diagnostics.zig");
const table = @import("table.zig");
const Value = @import("Value.zig").Value;

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
/// On failure `ctx.fail` gets the position of the part that failed.
pub fn fromNode(gpa: std.mem.Allocator, node: Node, ctx: Value.Context) Error!Key {
    return switch (node.kind) {
        .value => .{ .value = (unquote(gpa, node.value) catch |err| {
            ctx.fail(node.pos);
            return err;
        }).text },
        .concat => blk: {
            var nodesToJoin: std.ArrayList([]const u8) = .empty;
            defer nodesToJoin.deinit(gpa);

            for (node.children) |n| {
                // Only values are supported
                if (n.kind != .value) {
                    ctx.fail(n.pos);
                    return Error.MalformedKey;
                }
                // Handle delimiters rightly - if multiline - leave as is otherwise trim
                const ut = unquote(gpa, n.value) catch |err| {
                    ctx.fail(n.pos);
                    return err;
                };
                try nodesToJoin.append(gpa, ut.text);
            }
            break :blk .{
                .value = try mem.concat(
                    gpa,
                    u8,
                    try nodesToJoin.toOwnedSlice(gpa),
                ),
            };
        },
        else => {
            ctx.fail(node.pos);
            return Error.UnsupportedNodeKind;
        },
    };
}

pub fn eql(a: Key, b: Key) bool {
    return std.mem.eql(u8, a.value, b.value);
}

/// Cuts a path expression into its elements: a key before `=`, the inside of a
/// `${…}` and a path passed as text all come through here, so `a."b.c"` means
/// the same thing in all three. `path` is what `parseText` left: a `.value` or
/// a `.concat` of parts, quotes still on.
///
/// A dot inside an unquoted part ends an element, a dot inside a quoted part is
/// a character, and the boundary between two parts means nothing — so `a"b".c`
/// has two elements, the first made of two parts. An element of one part comes
/// back as that part, of several as a `.concat`, ready for `fromNode`.
///
/// An element with nothing in it is `MalformedKey` (java's BadPath): `.a`,
/// `a..b`, `a.`. Written as `""` it is an element like any other. On failure
/// `err_offset` is where: the dot next to the empty element, or the quoted
/// part with a bad escape.
pub fn split(gpa: std.mem.Allocator, path: Node, err_offset: *?usize) Error![]Node {
    const one = [_]Node{path};
    const parts = switch (path.kind) {
        .value => &one,
        .concat => path.children,
        else => {
            err_offset.* = path.pos;
            return Error.UnsupportedNodeKind;
        },
    };

    // One element more than there are dots outside quotes; counted first so
    // the result is one allocation of the right size.
    var dots: usize = 0;
    for (parts) |part| {
        if (!mem.startsWith(u8, part.value, "\"")) dots += mem.countScalar(u8, part.value, '.');
    }
    const elements = try gpa.alloc(Node, dots + 1);
    var count: usize = 0;
    // The pieces of the element being read: scratch, on the stack while a path
    // has few parts. An element has at most one piece of every part.
    var scratch = std.heap.stackFallback(8 * @sizeOf(Node), gpa);
    const tmp = scratch.get();
    var current: std.ArrayList(Node) = try .initCapacity(tmp, parts.len);
    defer current.deinit(tmp);
    // Where the last dot was, for a path that ends in one.
    var last_dot: usize = path.pos;

    for (parts) |part| {
        // Only text: `a ${b}` never gets this far, this is a second lock.
        if (part.kind != .value) {
            err_offset.* = part.pos;
            return Error.MalformedKey;
        }
        // The tokenizer starts every quoted string with `"` and no unquoted
        // one, so the first byte says which it is.
        if (mem.startsWith(u8, part.value, "\"")) {
            // The escapes are checked here although `fromNode` unquotes again:
            // a key is split while the file is read, so its bad escape is the
            // first error rather than one found after the whole file. The text
            // is not kept, so it goes into an arena that is gone right after.
            var check: std.heap.ArenaAllocator = .init(gpa);
            defer check.deinit();
            _ = unquote(check.allocator(), part.value) catch |err| {
                err_offset.* = part.pos;
                return err;
            };
            try current.append(tmp, part);
            continue;
        }

        var it = mem.splitScalar(u8, part.value, '.');
        const head = it.first();
        if (head.len > 0) try current.append(tmp, .{ .kind = .value, .value = head, .children = &.{}, .pos = part.pos });
        while (it.next()) |seq| {
            // `seq` is a slice of `part.value`, so its distance from the start is
            // its distance from `part.pos` — and the dot sits right before it.
            const seq_pos = part.pos + (seq.ptr - part.value.ptr);
            last_dot = seq_pos - 1;
            // `.a`, `a..b`: no element before this dot.
            if (current.items.len == 0) {
                err_offset.* = last_dot;
                return Error.MalformedKey;
            }
            elements[count] = try takeElement(gpa, &current);
            count += 1;
            if (seq.len > 0) try current.append(tmp, .{ .kind = .value, .value = seq, .children = &.{}, .pos = seq_pos });
        }
    }
    // `a.`: no element after the last dot.
    if (current.items.len == 0) {
        err_offset.* = last_dot;
        return Error.MalformedKey;
    }
    elements[count] = try takeElement(gpa, &current);
    return elements;
}

/// The parts gathered for one element as one node, `current` left empty. A
/// `.concat` gets its own copy of them from `gpa`: `current` is scratch.
fn takeElement(gpa: std.mem.Allocator, current: *std.ArrayList(Node)) Error!Node {
    defer current.clearRetainingCapacity();
    if (current.items.len == 1) return current.items[0];
    return .{ .kind = .concat, .children = try gpa.dupe(Node, current.items), .pos = current.items[0].pos };
}

/// A path written as plain text, `a."b.c".d`, as the keys it names: what
/// `hocon get` and a lookup by name start from. It is read the way the inside
/// of `${…}` is — tokenizer, `parseText`, `split`, `fromNode` — so quoting,
/// empty elements and whitespace follow the same rules, and whitespace around
/// the whole path is not part of it. Anything that is not text is an error,
/// a comment included: `a # b` is no path.
///
/// The keys point into a copy of `text` and into what unquoting made, all of
/// it from `gpa`, so pass an arena. On failure `diagnostics`, when given, gets
/// the error and where in `text` it is, like a parse that failed on a slice.
pub fn parsePath(gpa: std.mem.Allocator, text: []const u8, diagnostics: ?*Diagnostics) Ast.Parser.Error![]Key {
    if (diagnostics) |diag| diag.* = .{};
    var err_offset: ?usize = null;
    return keysOf(gpa, text, &err_offset) catch |err| {
        if (diagnostics) |diag| {
            diag.* = .{ .err = err };
            // An OutOfMemory has no place, and no memory to copy one with either.
            if (err != error.OutOfMemory) if (err_offset) |offset| {
                diag.location = Diagnostics.locate("", text, offset).dupe(gpa) catch null;
            };
        }
        return err;
    };
}

fn keysOf(gpa: std.mem.Allocator, text: []const u8, err_offset: *?usize) Ast.Parser.Error![]Key {
    var parser: Ast.Parser = .{ .gpa = gpa, .t = .{ .t = Tokenizer.init(try gpa.dupeZ(u8, text)) } };
    const path = parser.parsePath() catch |err| {
        err_offset.* = parser.err_offset;
        return err;
    };
    const elements = try split(gpa, path, err_offset);
    const keys = try gpa.alloc(Key, elements.len);
    // `split` has checked every part, so all `fromNode` can still run out of is
    // memory, which has no place: no file to report it to.
    for (keys, elements) |*key, element| key.* = try fromNode(gpa, element, .{});
    return keys;
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

/// `fromNode` for a hand-built node, whose positions mean nothing.
fn build(gpa: std.mem.Allocator, node: Node) Error!Key {
    return fromNode(gpa, node, .{});
}

fn expectKey(want: []const u8, node: Node) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const key = try build(arena.allocator(), node);
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
    try testing.expectError(Error.MalformedKey, build(arena.allocator(), node));
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
        try testing.expectError(Error.UnsupportedNodeKind, build(arena.allocator(), node));
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

    const plain = try build(gpa, v("a"));
    try testing.expect(plain.eql(try build(gpa, v("\"a\""))));
    try testing.expect(plain.eql(try build(gpa, v("\"\"\"a\"\"\""))));
    try testing.expect(!plain.eql(try build(gpa, v("b"))));
}

/// A text part at `pos`, for the `split` tests, where positions are the point.
fn vAt(text: []const u8, pos: usize) Node {
    return .{ .kind = .value, .value = text, .children = &.{}, .pos = pos };
}

/// `a@10 concat(a@0 "b"@1)`: every element `split` gave, with where it starts.
fn dumpElements(gpa: std.mem.Allocator, elements: []const Node) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    for (elements, 0..) |element, i| {
        if (i > 0) try out.writer.writeByte(' ');
        if (element.kind == .value) {
            try out.writer.print("{s}@{d}", .{ element.value, element.pos });
            continue;
        }
        try out.writer.writeAll("concat(");
        for (element.children, 0..) |part, j| {
            if (j > 0) try out.writer.writeByte(' ');
            try out.writer.print("{s}@{d}", .{ part.value, part.pos });
        }
        try out.writer.writeByte(')');
    }
    return out.toOwnedSlice();
}

fn expectSplit(want: []const u8, path: Node) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var err_offset: ?usize = null;
    try testing.expectEqualStrings(want, try dumpElements(gpa, try split(gpa, path, &err_offset)));
}

fn expectSplitError(want: Error, offset: usize, path: Node) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var err_offset: ?usize = null;
    try testing.expectError(want, split(arena.allocator(), path, &err_offset));
    try testing.expectEqual(offset, err_offset.?);
}

// What the suite table below cannot see from the keys alone: an element of one
// part is that part, of several a `.concat`, and every piece cut out of an
// unquoted part knows where in the file it starts — `"c"` in `.c` is at 5, not
// at the 4 of its part. The quoted dot is not counted as a dot.
test "split.one part is an element as it is, several are a concat, pieces keep their place" {
    try expectSplit("a@10 b@12 c@14", vAt("a.b.c", 10));
    try expectSplit("\"a.b\"@3", vAt("\"a.b\"", 3));

    var glued = [_]Node{ vAt("a", 0), vAt("\"b\"", 1), vAt(".c", 4) };
    try expectSplit("concat(a@0 \"b\"@1) c@5", .{ .kind = .concat, .value = "", .children = &glued });

    var quoted_empty = [_]Node{ vAt("a.", 0), vAt("\"\"", 2) };
    try expectSplit("a@0 \"\"@2", .{ .kind = .concat, .value = "", .children = &quoted_empty });
}

// Every error and the place it points at. The parser never hands `split` the
// last two, so they are a second lock on the same door.
test "split.every error and where it is" {
    try expectSplitError(Error.MalformedKey, 2, vAt("a..b", 0));
    try expectSplitError(Error.MalformedKey, 0, vAt(".a", 0));

    var trailing = [_]Node{ vAt("a", 0), vAt(".", 1) };
    try expectSplitError(Error.MalformedKey, 1, .{ .kind = .concat, .value = "", .children = &trailing });

    var bad_escape = [_]Node{ vAt("a.", 0), vAt("\"\\q\"", 2) };
    try expectSplitError(Error.InvalidEscape, 2, .{ .kind = .concat, .value = "", .children = &bad_escape });

    var path = [_]Node{v("b")};
    var with_subst = [_]Node{ vAt("a", 0), .{ .kind = .subst, .value = "", .children = &path, .pos = 1 } };
    try expectSplitError(Error.MalformedKey, 1, .{ .kind = .concat, .value = "", .children = &with_subst });

    var child = [_]Node{v("x")};
    try expectSplitError(Error.UnsupportedNodeKind, 7, .{ .kind = .block, .value = "", .children = &child, .pos = 7 });
}

// More parts than the 8 the scratch holds on the stack, so it spills into
// `gpa`: with the testing allocator a scratch that is not freed is a leak, and
// a `.concat` that kept pointing into it reads freed memory.
test "split.a path longer than the stack scratch" {
    const gpa = testing.allocator;

    var parts: [21]Node = undefined;
    for (parts[0..20], 0..) |*part, i| part.* = vAt("\"q\"", i * 3);
    parts[20] = vAt(".end", 60);

    var err_offset: ?usize = null;
    const elements = try split(gpa, .{ .kind = .concat, .value = "", .children = &parts }, &err_offset);
    defer gpa.free(elements);
    defer gpa.free(elements[0].children);

    try testing.expectEqual(2, elements.len);
    try testing.expectEqual(20, elements[0].children.len);
    for (elements[0].children, 0..) |part, i| {
        try testing.expectEqualStrings("\"q\"", part.value);
        try testing.expectEqual(i * 3, part.pos);
    }
    try testing.expectEqualStrings("end", elements[1].value);
}

// Every path of conformance/suite/path-expressions/, cut three ways: as a key
// (`<path> = 1`), as a substitution (`x = ${<path>}`) and as text (`parsePath`).
// All three go through `split`, so all three must give the same keys, or fail
// with the same error at the same place in the path. 019 is 010's `a..b` in a
// substitution, so it is the 010 row here.
//
// java ✓ · pyhocon ⚠️ · spec ✓ — java (1.4.9) agrees on every row three ways:
// `resolve:<path> = 1\nx = ${<path>}` gives x = 1 or BadPath, and
// ConfigUtil.splitPath gives these keys or BadPath. pyhocon:
//
//   key, substitution  rejects a quoted part in a key (002, 005, 009, 018) and
//                      drops an empty element (010, 011, 012: {"a":{"b":1}})
//   text, parse_key    keeps the quotes ('"a.b"'), drops an empty element,
//                      splits `foo"10.0"` at the quoted dot, takes `a.${x}`
test "split.every suite path is the same keys as a key, a substitution and text" {
    const cases = [_]table.Case{
        .ok("\"a.b\"", "[a.b]"), // 001
        .ok("foo.bar.\"hello.world\"", "[foo] [bar] [hello.world]"), // 002
        .ok("10.0foo", "[10] [0foo]"), // 003
        .ok("foo10.0", "[foo10] [0]"), // 004
        .ok("foo\"10.0\"", "[foo10.0]"), // 005
        .ok("1.2.3", "[1] [2] [3]"), // 006
        .ok("x", "[x]"), // 008
        .ok("a.\"\".b", "[a] [] [b]"), // 009
        .ok("a..b", "MalformedKey at 2"), // 010, 019
        .ok(".a.b", "MalformedKey at 0"), // 011
        .ok("a.b.", "MalformedKey at 3"), // 012
        .ok("foo.bar", "[foo] [bar]"), // 015
        .ok("1.10", "[1] [10]"), // 016
        .ok("a b.c", "[a b] [c]"), // 017
        .ok("foo.\"bar.baz\"", "[foo] [bar.baz]"), // 018
        .ok("-.33", "[-] [33]"), // 020
        .ok("\"b.c\"", "[b.c]"), // 021
        .ok("true", "[true]"), // 022
        .ok("a.${x}", "UnexpectedToken at 2"), // 023
    };
    try table.expectAll(&cases, .{ .dump = asKey });
    try table.expectAll(&cases, .{ .dump = asSubstitution });
    try table.expectAll(&cases, .{ .dump = asText });
}

// java ⚠️ (rejects `1e+5.5` as a key and a substitution) · pyhocon ⚠️ splits
// `1e+5.5` at the dot · spec ✓ — `+` stands only in the exponent of the number
// JSON reads at the start, so `1e+5.5` is that number then `.5`, the path
// `1e+5`, `5`, and a `+` after the number fails, cut three ways alike. Until
// 2026-10-25 `1e+5.5` failed too.
test "split.a + after the number fails as a key, a substitution and text" {
    const cases = [_]table.Case{
        .ok("1e+5", "[1e+5]"),
        .ok("1e+5.5", "[1e+5] [5]"),
        .ok("1e+5e+5", "BadNumber at 0"),
        // after a letter it is no sign at all
        .ok("a.1e+5.x", "UnexpectedToken at 4"),
    };
    try table.expectAll(&cases, .{ .dump = asKey });
    try table.expectAll(&cases, .{ .dump = asSubstitution });
    try table.expectAll(&cases, .{ .dump = asText });
}

// java ✓ · pyhocon ⚠️ · spec ✓ — whitespace around a path given as text is not
// part of it, newlines included (spec: 0x0A and 0x0D are whitespace), so a line
// read with its ending still works. Whitespace inside belongs to the element it
// touches. A newline inside the path ends it, and what follows is extra.
//
//   ConfigUtil.splitPath("a.b\n")   -> [a, b]
//   ConfigUtil.splitPath(" a .b ")  -> [a , b]
//   ConfigUtil.splitPath("a.\nb")   -> BadPath
//
// pyhocon's parse_key keeps every byte: 'a.b\n' -> ['a', 'b\n'].
test "parsePath.whitespace and newlines around the path are not part of it" {
    try table.expectAll(&.{
        .ok("a.b\n", "[a] [b]"),
        .ok("\na.b", "[a] [b]"),
        .ok("a.b\r\n", "[a] [b]"),
        .ok("\n\n a.b \n\n", "[a] [b]"),
        .ok(" a .b ", "[a ] [b]"),
        .ok("a.\nb", "UnexpectedToken at 3"),
    }, .{ .dump = asText });
}

/// The keys of `<path> = 1`, from the root down to the `1`.
fn asKey(gpa: std.mem.Allocator, path: [:0]const u8) anyerror![]u8 {
    var at: usize = 0;
    var value = built(gpa, try std.fmt.allocPrintSentinel(gpa, "{s} = 1", .{path}, 0), &at) catch |err| return failure(gpa, err, at, 0);
    var keys: std.ArrayList(Key) = .empty;
    while (value == .object) : (value = value.object[0].value) try keys.append(gpa, value.object[0].key);
    return show(gpa, keys.items);
}

/// The path of the ref in `x = ${<path>}`.
fn asSubstitution(gpa: std.mem.Allocator, path: [:0]const u8) anyerror![]u8 {
    var at: usize = 0;
    const value = built(gpa, try std.fmt.allocPrintSentinel(gpa, "x = ${{{s}}}", .{path}, 0), &at) catch |err| return failure(gpa, err, at, "x = ${".len);
    return show(gpa, value.object[0].value.ref.path);
}

fn asText(gpa: std.mem.Allocator, path: [:0]const u8) anyerror![]u8 {
    var diag: Diagnostics = .{};
    const keys = parsePath(gpa, path, &diag) catch |err| return failure(gpa, err, diag.location.?.offset, 0);
    return show(gpa, keys);
}

/// `source` parsed and built, unresolved: the keys as `split` and `fromNode`
/// left them. On failure `at` is where in `source`.
fn built(gpa: std.mem.Allocator, source: [:0]const u8, at: *usize) !Value {
    var files: Value.Files = .{};
    var parser: Ast.Parser = .{ .gpa = gpa, .t = .{ .t = Tokenizer.init(source) } };
    const ast = parser.parse() catch |err| {
        at.* = parser.err_offset.?;
        return err;
    };
    return Value.fromNode(gpa, ast, .{ .files = &files }) catch |err| {
        at.* = files.failed.?.offset;
        return err;
    };
}

/// The error and where it is in the path, `before` being how much of the
/// source stands in front of the path. Signed: an error at the `${` comes out
/// negative rather than as an overflow.
fn failure(gpa: std.mem.Allocator, err: anyerror, at: usize, before: usize) ![]u8 {
    return std.fmt.allocPrint(gpa, "{t} at {d}", .{ err, @as(isize, @intCast(at)) - @as(isize, @intCast(before)) });
}

/// `[a] [b.c] []`: every key in brackets, so an empty one shows.
fn show(gpa: std.mem.Allocator, keys: []const Key) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    for (keys, 0..) |key, i| {
        if (i > 0) try out.writer.writeByte(' ');
        try out.writer.print("[{s}]", .{key.value});
    }
    return out.toOwnedSlice();
}
