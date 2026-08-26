const std = @import("std");
const mem = std.mem;

pub const Error = error{
    InvalidEscape,
} || mem.Allocator.Error;

pub const UnquotedText = struct {
    text: []const u8,
    quoted: bool,
};

/// Takes the delimiter off and applies escapes, and says which delimiter it was:
/// once the text is out, `a = "1"` and `a = 1` both read `1`, and only the flag
/// tells them apart. A HOCON quoted string is a JSON string by definition, so
/// `std.json` does that half — `\u`, surrogate pairs and all.
pub fn unquote(gpa: mem.Allocator, in: []const u8) Error!UnquotedText {
    if (in.len >= 6 and mem.startsWith(u8, in, "\"\"\"") and mem.endsWith(u8, in, "\"\"\"")) {
        // Escapes stay literal inside a triple-quoted string.
        return .{ .text = in[3 .. in.len - 3], .quoted = true };
    }
    if (in.len >= 2 and in[0] == '"' and in[in.len - 1] == '"') {
        return .{
            .text = std.json.parseFromSliceLeaky([]const u8, gpa, in, .{}) catch |err| switch (err) {
                // Without this, a failed allocation would report a bad escape.
                error.OutOfMemory => return error.OutOfMemory,
                else => return Error.InvalidEscape,
            },
            .quoted = true,
        };
    }
    return .{ .text = in, .quoted = false }; // unquoted text arrives as it was written
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectText(want: []const u8, want_quoted: bool, in: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    errdefer std.debug.print("failed on {s}\n", .{in});
    const got = try unquote(arena.allocator(), in);
    try testing.expectEqualStrings(want, got.text);
    try testing.expectEqual(want_quoted, got.quoted);
}

// java ✓ · pyhocon ✓ · spec ✓ — the delimiter comes off and is remembered:
//
//   'a = 1'    -> {"a":1}       a number
//   'a = "1"'  -> {"a":"1"}     a string that looks like one
//
// Both sides of that pair carry the text `1`, so the text alone cannot tell
// them apart — which is why `quoted` travels with it. On the key side the flag
// is dropped on purpose, because `a` and `"a"` are the same key.
test "unquote.the delimiter comes off and is remembered" {
    try expectText("a", false, "a");
    try expectText("a", true, "\"a\"");
    try expectText("a", true, "\"\"\"a\"\"\"");
    try expectText("", true, "\"\"");
    try expectText("1", false, "1");
    try expectText("1", true, "\"1\"");
    try expectText("true", false, "true");
    try expectText("a b", false, "a b");
}

// java ✓ · pyhocon ✓ · spec ✓ — escapes are processed inside a quoted string
// and left alone inside a triple-quoted one:
//
//   'a = "x\ny"'      -> {"a":"x\ny"}      a newline
//   'a = """x\ny"""'  -> {"a":"x\\ny"}     a backslash and an n
//
// This pair is why the tree carries the raw slice this far: the delimiter is
// the only thing saying which of the two it is.
test "unquote.escapes follow the delimiter" {
    try expectText("a\nb", true, "\"a\\nb\"");
    try expectText("a\tb", true, "\"a\\tb\"");
    try expectText("a\rb", true, "\"a\\rb\"");
    try expectText("a/b", true, "\"a\\/b\"");
    try expectText("a\\b", true, "\"a\\\\b\"");
    try expectText("a\"b", true, "\"a\\\"b\"");
    try expectText("a\\nb", true, "\"\"\"a\\nb\"\"\"");
}

// java ✓ · pyhocon ✓ · spec ✓ — a quote that arrived as content has to survive,
// and that only works if the delimiter comes off by its known width rather than
// by trimming whatever quotes happen to sit at the edges:
//
//   'a = "\"x\""'   -> {"a":"\"x\""}   the value is  "x"  , quotes included
//   'a = """"x""""' -> {"a":"\"x\""}   the tokenizer ends a multiline string at
//                                      the LAST triple quote, so the extra pair
//                                      is content
//
// Trimming instead of slicing loses them, and on the key side `"\"a\""` would
// then collide with the plain key `a`. It also leaves a lone `\` at the end,
// which the escape loop reads past.
test "unquote.a quote can be content" {
    try expectText("\"a\"", true, "\"\\\"a\\\"\"");
    try expectText("a\"", true, "\"a\\\"\"");
    try expectText("\"a\"", true, "\"\"\"\"a\"\"\"\"");
}

// java ✓ · pyhocon ✓ · spec ✓ — the escapes JSON defines and no others. Java
// throws on both rows below at parse time; the tokenizer here hands the string
// through verbatim, so this is where they are caught.
//
//   'a = "\z"'  -> ConfigException  backslash-z is not an escape
//   'a = "x\"'  -> ConfigException  an escape that never finished
test "unquote.an escape that is not one is an error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    try testing.expectError(Error.InvalidEscape, unquote(gpa, "\"a\\zb\""));
    try testing.expectError(Error.InvalidEscape, unquote(gpa, "\"a\\\""));
}

// java ✓ · pyhocon ⚠️ · spec ✓ — `std.json` does the decoding, and this is
// what it has to come out as. Each row is what java prints:
//
//   'a = "\u0041"'         -> {"a":"A"}        ascii, one byte out
//   'a = "\u00e9"'         -> {"a":"é"}        two bytes of UTF-8 out
//   'a = "\ud83d\ude00"'   -> {"a":"😀"}       a surrogate PAIR, four bytes out
//   'a = """\u0041"""'     -> {"a":"\\u0041"}  literal, like every other escape
//   'a = "\uZZZZ"'         -> ConfigException  "Malformed hex digits"
//   'a = "\u00"'           -> ConfigException  "expecting 4 hex digits"
//
// The escape counts UTF-16 code units, the output is UTF-8, and those two only
// line up below U+0800 — so a decoder that reads four hex digits and writes
// them straight out is right on the first row and wrong on the next two. A high
// surrogate has to wait for its low one and the pair becomes a single code
// point; `std.unicode.utf8Encode` does the writing.
//
// pyhocon diverges on the multiline row: it processes `\u` inside `"""` too and
// says {"a":"A"}. Java leaves it alone, and java is the authority here.
//
// Open, deliberately untested: java takes a LONE high surrogate ('a = "\ud83d"'
// parses, and only its JSON printer gives up and writes "?"). UTF-8 has no
// encoding for one, so that row needs a decision — reject it, or carry WTF-8 —
// before it can be a test.
test "unquote.a unicode escape is UTF-16 in and UTF-8 out" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    try expectText("A", true, "\"\\u0041\"");
    try expectText("xAy", true, "\"x\\u0041y\"");
    try expectText("\u{00e9}", true, "\"\\u00e9\"");
    try expectText("\u{1f600}", true, "\"\\ud83d\\ude00\"");
    try expectText("\\u0041", true, "\"\"\"\\u0041\"\"\"");

    try testing.expectError(Error.InvalidEscape, unquote(gpa, "\"\\uZZZZ\""));
    try testing.expectError(Error.InvalidEscape, unquote(gpa, "\"\\u00\""));
}
