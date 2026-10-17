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
/// tells them apart. A HOCON quoted string is a JSON string by definition (see
/// `unescape`).
pub fn unquote(gpa: mem.Allocator, in: []const u8) Error!UnquotedText {
    if (in.len >= 6 and mem.startsWith(u8, in, "\"\"\"") and mem.endsWith(u8, in, "\"\"\"")) {
        // Escapes stay literal inside a triple-quoted string.
        return .{ .text = in[3 .. in.len - 3], .quoted = true };
    }
    if (in.len >= 2 and in[0] == '"' and in[in.len - 1] == '"') {
        return .{ .text = try unescape(gpa, in[1 .. in.len - 1]), .quoted = true };
    }
    return .{ .text = in, .quoted = false }; // unquoted text arrives as it was written
}

/// The inside of a JSON string, escapes applied. `\u` counts UTF-16 code
/// units: a high surrogate and the low one right after it are one character.
/// JSON takes a surrogate on its own too, `"\ud83d"`, and UTF-8 has no bytes
/// for that, so the text is WTF-8: UTF-8 that may hold one (std.unicode).
/// `writeJson` writes it back as `\ud83d`. std.json would refuse it.
fn unescape(gpa: mem.Allocator, in: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < in.len) {
        const c = in[i];
        i += 1;
        if (c != '\\') {
            // JSON wants these escaped, a tab too.
            if (c < 0x20) return Error.InvalidEscape;
            try out.append(gpa, c);
            continue;
        }
        if (i == in.len) return Error.InvalidEscape;
        const e = in[i];
        i += 1;
        const byte: u8 = switch (e) {
            '"', '\\', '/' => e,
            'b' => 0x08,
            'f' => 0x0C,
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'u' => {
                const unit = try hex4(in[i..]);
                i += 4;
                var code: u21 = unit;
                if (std.unicode.utf16IsHighSurrogate(unit) and mem.startsWith(u8, in[i..], "\\u")) {
                    const low = try hex4(in[i + 2 ..]);
                    if (std.unicode.utf16IsLowSurrogate(low)) {
                        code = std.unicode.utf16DecodeSurrogatePair(&.{ unit, low }) catch unreachable;
                        i += 6;
                    }
                }
                var buf: [4]u8 = undefined;
                const len = std.unicode.wtf8Encode(code, &buf) catch unreachable;
                try out.appendSlice(gpa, buf[0..len]);
                continue;
            },
            else => return Error.InvalidEscape,
        };
        try out.append(gpa, byte);
    }
    return out.toOwnedSlice(gpa);
}

/// The four hex digits of a `\u` escape. Only digits: `std.fmt.parseInt` would
/// take `+fff` too.
fn hex4(in: []const u8) Error!u16 {
    if (in.len < 4) return Error.InvalidEscape;
    for (in[0..4]) |h| {
        if (!std.ascii.isHex(h)) return Error.InvalidEscape;
    }
    return std.fmt.parseInt(u16, in[0..4], 16) catch unreachable;
}

/// Writes `text` as a JSON string, quotes and all, the way `std.json` writes
/// one, except that a surrogate on its own (see `unescape`) is `\ud83d` again.
/// In WTF-8 such a surrogate is three bytes, 0xED then 0xA0 or more; in UTF-8
/// 0xED is never followed by that.
pub fn writeJson(text: []const u8, options: std.json.Stringify.Options, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeByte('"');
    var start: usize = 0;
    var i: usize = 0;
    while (i + 2 < text.len) : (i += 1) {
        if (text[i] != 0xED or text[i + 1] < 0xA0) continue;
        try std.json.Stringify.encodeJsonStringChars(text[start..i], options, w);
        // The low bits of the second and the third byte, under 0xD000.
        const unit = 0xD000 | @as(u16, text[i + 1] & 0x3F) << 6 | (text[i + 2] & 0x3F);
        try w.print("\\u{x:0>4}", .{unit});
        i += 2;
        start = i + 1;
    }
    try std.json.Stringify.encodeJsonStringChars(text[start..], options, w);
    try w.writeByte('"');
}

/// Text with a surrogate on its own in it (see `unescape`): WTF-8 that is not UTF-8.
pub fn hasSurrogate(text: []const u8) bool {
    return !std.unicode.utf8ValidateSlice(text) and std.unicode.wtf8ValidateSlice(text);
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
    // No arena: what was written before the bad escape is freed, or it leaks.
    const gpa = testing.allocator;

    try testing.expectError(Error.InvalidEscape, unquote(gpa, "\"a\\zb\""));
    try testing.expectError(Error.InvalidEscape, unquote(gpa, "\"a\\\""));
    // JSON has no raw control characters in a string, a tab included.
    try testing.expectError(Error.InvalidEscape, unquote(gpa, "\"a\tb\""));
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
// A surrogate on its own is the next test.
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

// unchanged-from-json/027 · java ✓ (and it prints each back as written) ·
// pyhocon ⚠️ keeps the escape as six characters · spec ✓ — JSON takes any
// `\uXXXX`, a surrogate on its own too, and the string then holds that one code
// unit. UTF-8 has no bytes for it, WTF-8 has (U+D83D is 0xED 0xA0 0xBD), and
// `writeJson` turns them back into the escape:
//
//   'a = "\ud83d"'              -> {"a":"\ud83d"}
//   'a = "\ude00\ud83d"'        -> {"a":"\ude00\ud83d"}   low then high is no pair
//   'a = "\ud83d\ud83d\ude00"'  -> {"a":"\ud83d😀"}       the second high has its low
//   'a = "\u+fff"'              -> java ⚠️ {"a":"\u0fff"}: it reads the digits with
//                                  Integer.parseInt; JSON wants four hex digits
test "unquote.a surrogate on its own is kept" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    try expectText("\xed\xa0\xbd", true, "\"\\ud83d\"");
    try expectText("\xed\xb8\x80\xed\xa0\xbd", true, "\"\\ude00\\ud83d\"");
    try expectText("\xed\xa0\xbd\u{1f600}", true, "\"\\ud83d\\ud83d\\ude00\"");
    try expectText("tea\xed\xa0\xbd", true, "\"tea\\uD83D\"");

    try testing.expectError(Error.InvalidEscape, unquote(gpa, "\"\\u+fff\""));
    try testing.expectError(Error.InvalidEscape, unquote(gpa, "\"\\ud83d\\u12\""));
    try testing.expectError(Error.InvalidEscape, unquote(gpa, "\"\\ud83d\\\""));
}

// What `unquote` read, `writeJson` writes as it was: a surrogate on its own as
// its escape, everything else the way std.json writes it, `escape_unicode` too.
// java ✓ (prints the escape back) · pyhocon ⚠️ keeps it as six characters · spec ✓
test "unquote.writeJson writes a surrogate back as its escape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    for ([_][]const u8{ "\"\\ud83d\"", "\"\\ude00\\ud83d\"", "\"x\\ud83dy\\n\"", "\"\\ud83d😀\"", "\"the wombat sleeps\"", "\"\"" }) |in| {
        var out: std.Io.Writer.Allocating = .init(gpa);
        try writeJson((try unquote(gpa, in)).text, .{}, &out.writer);
        try testing.expectEqualStrings(in, out.written());
    }
    var out: std.Io.Writer.Allocating = .init(gpa);
    try writeJson("é\xed\xa0\xbd", .{ .escape_unicode = true }, &out.writer);
    try testing.expectEqualStrings("\"\\u00e9\\ud83d\"", out.written());
}
