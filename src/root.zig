//! zig-hocon: a HOCON (Human-Optimized Config Object Notation) parser for Zig.
const std = @import("std");

test {
    _ = @import("Tokenizer.zig");
    _ = @import("Ast.zig");
    _ = @import("utils/unqoute.zig");
    _ = @import("Key.zig");
    _ = @import("Value.zig");
    _ = @import("Config.zig");
    _ = @import("Include.zig");
    _ = @import("stringify.zig");
}

// Export functionality to users
const config = @import("Config.zig").Config;
pub const Value = @import("Value.zig").Value;
pub const Parsed = config.Parsed;
pub const parseFromSlice = config.parseFromSlice;
pub const parseFromSliceLeaky = config.parseFromSliceLeaky;
pub const parseFromFile = config.parseFromFile;
pub const parseFromFileLeaky = config.parseFromFileLeaky;
pub const ParseOptions = config.ParseOptions;
pub const Diagnostics = @import("Diagnostics.zig");
pub const ParseFromValueError = config.ConvertError;
pub const stringify = @import("stringify.zig").stringify;
pub const stringifyAlloc = @import("stringify.zig").stringifyAlloc;
pub const StringifyOptions = @import("stringify.zig").Options;

// ---------------------------------------------------------------------------
// Tests of the public surface: called the way a user calls it, through the
// names exported above and nothing else.
// ---------------------------------------------------------------------------

const testing = std.testing;
// The package as a user imports it, so the tests read like calling code.
const hocon = @This();

// `parseFromSlice` is `parseFromSliceLeaky` plus an arena it owns, the same
// split as std.json. These tests use `testing.allocator` directly, not an arena:
// it reports every byte not given back, so a passing test is the proof that
// `deinit` frees everything the parse allocated.

test "parsed.deinit gives back everything the parse took" {
    const T = struct { name: []const u8, ports: []const u16, tls: ?struct { cert: []const u8 } };
    const parsed = try hocon.parseFromSlice(T, testing.allocator,
        \\name = the dog ate my homework
        \\ports = [80, 443]
        \\tls { cert = grumpy-wombat.pem }
    , .{});
    defer parsed.deinit();

    try testing.expectEqualStrings("the dog ate my homework", parsed.value.name);
    try testing.expectEqualSlices(u16, &.{ 80, 443 }, parsed.value.ports);
    try testing.expectEqualStrings("grumpy-wombat.pem", parsed.value.tls.?.cert);
}

// The value is plain T — no wrapper type to unwrap field by field.
test "parsed.value is the target type itself" {
    const T = struct { a: usize };
    const parsed = try hocon.parseFromSlice(T, testing.allocator, "a = 1", .{});
    defer parsed.deinit();
    comptime std.debug.assert(@TypeOf(parsed.value) == T);
}

// A failed parse returns an error and leaks nothing: the arena, and the memory
// holding the arena, are both given back on the way out (the two `errdefer`s).
test "parsed.a failed parse leaves nothing behind" {
    const T = struct { a: usize, b: []const u8 };
    try testing.expectError(error.MissingField, hocon.parseFromSlice(T, testing.allocator, "b = the cat sat on the keyboard", .{}));
    try testing.expectError(error.TypeMismatch, hocon.parseFromSlice(T, testing.allocator, "a { x = 1 }\nb = x", .{}));
    try testing.expectError(error.UnexpectedToken, hocon.parseFromSlice(T, testing.allocator, "a = 1\nb = {", .{}));
}

// Parsed is passed around by value, so a copy has to free the same memory as the
// original — which works only because the arena sits behind a pointer.
test "parsed.a copy frees what the original allocated" {
    const T = struct { a: []const u8 };
    const original = try hocon.parseFromSlice(T, testing.allocator, "a = the coffee runs out on monday morning", .{});
    const copy = original;
    defer copy.deinit();
    try testing.expectEqualStrings("the coffee runs out on monday morning", copy.value.a);
}

// Every allocation the parse makes is made to fail once, in turn. Each of those
// runs has to end in error.OutOfMemory with nothing leaked — the check the other
// tests cannot make, because they never see an allocation fail halfway.
test "parsed.out of memory at any point leaks nothing" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            const parsed = try hocon.parseFromSlice(struct { a: []const u8, b: ?usize }, gpa, "a = and now it looks innocent\nb = 2", .{});
            parsed.deinit();
        }
    }.run, .{});
}

// ---------------------------------------------------------------------------
// Files: the point of includes. `prod.conf` pulls in `defaults.conf` and
// overrides some of it. The files are written to a temp directory and parsed
// through their path, the way a program would.
// ---------------------------------------------------------------------------

const Prod = struct { name: []const u8, port: u16, tls: struct { cert: []const u8, key: []const u8 } };

/// Writes the two files and returns the path of `prod.conf`, relative to where the test runs.
fn writeProd(tmp: *testing.TmpDir) ![]u8 {
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "defaults.conf",
        .data = "name = the dog ate my homework\nport = 80\ntls { cert = grumpy-wombat.pem }",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "prod.conf",
        .data = "include \"defaults.conf\"\nport = 443\ntls { key = sleepy-owl.key }",
    });
    return std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/prod.conf", .{tmp.sub_path});
}

// java ✓ · pyhocon ✓ · spec ✓ — the included defaults are there, what prod.conf
// writes after the include wins, and objects merge (tls has both keys). Nothing
// is left behind by `deinit`: this is `testing.allocator`, not an arena.
test "file.prod.conf includes defaults.conf and overrides it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeProd(&tmp);
    defer testing.allocator.free(path);

    const parsed = try hocon.parseFromFile(Prod, testing.allocator, testing.io, path, .{});
    defer parsed.deinit();

    try testing.expectEqualStrings("the dog ate my homework", parsed.value.name);
    try testing.expectEqual(443, parsed.value.port);
    try testing.expectEqualStrings("grumpy-wombat.pem", parsed.value.tls.cert);
    try testing.expectEqualStrings("sleepy-owl.key", parsed.value.tls.key);
}

// Every allocation of the file parse, includes included, fails once in turn.
test "file.out of memory at any point leaks nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeProd(&tmp);
    defer testing.allocator.free(path);

    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: std.mem.Allocator, file: []const u8) !void {
            const parsed = try hocon.parseFromFile(Prod, gpa, testing.io, file, .{});
            parsed.deinit();
        }
    }.run, .{path});
}

// The workflow of round 1 end to end (#10): the program writes its defaults
// once with `stringify`, an environment includes them and says what differs —
// an override, an object merged by a dotted key, `+=` — and that reads back
// into the struct, everything it does not mention still the default.
// java ✓ (same JSON from prod.conf) · pyhocon ⚠️ fails on `+=` · spec ✓
test "file.defaults.conf from stringify, prod.conf on top of it" {
    const App = struct {
        name: []const u8 = "grumpy wombat",
        port: u16 = 8080,
        debug: bool = true,
        plugins: []const []const u8 = &.{"auth"},
        db: struct { host: []const u8 = "localhost", pool: u8 = 4 } = .{},
        motto: ?[]const u8 = null,
    };
    const defaults = try hocon.stringifyAlloc(testing.allocator, App{}, .{});
    defer testing.allocator.free(defaults);
    try testing.expectEqualStrings(
        \\name = "grumpy wombat"
        \\port = 8080
        \\debug = true
        \\plugins = [auth]
        \\db {
        \\  host = localhost
        \\  pool = 4
        \\}
        \\
    , defaults);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "defaults.conf", .data = defaults });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "prod.conf", .data =
        \\include "defaults.conf"
        \\port = 443
        \\debug = off
        \\plugins += metrics
        \\db.host = db.example.org
        \\motto = the wombat sleeps at noon
        \\
    });
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/prod.conf", .{tmp.sub_path});
    defer testing.allocator.free(path);

    const parsed = try hocon.parseFromFile(App, testing.allocator, testing.io, path, .{});
    defer parsed.deinit();
    try testing.expectEqualDeep(App{
        .port = 443,
        .debug = false,
        .plugins = &.{ "auth", "metrics" },
        .db = .{ .host = "db.example.org" },
        .motto = "the wombat sleeps at noon",
    }, parsed.value);
}

// ---------------------------------------------------------------------------
// Value as JSON — what the `hocon` CLI prints, and what the conformance suite
// compares. `parseFromSlice(hocon.Value, …)` hands back the tree, and
// std.json.Stringify finds `Value.jsonStringify` on its own.
//
// Java's rendering is from
// tools/oracle/hocon-java; it sorts keys, which is why the key order below is
// ours (written order) and not compared against it.
// ---------------------------------------------------------------------------

fn expectJson(src: [:0]const u8, expected: []const u8) !void {
    const parsed = try hocon.parseFromSlice(hocon.Value, testing.allocator, src, .{});
    defer parsed.deinit();
    const json = try std.json.Stringify.valueAlloc(testing.allocator, parsed.value, .{});
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(expected, json);
}

// S1 · java ✓ · pyhocon ✓ · spec ✓ — unquoted true/false/null and numbers are
// themselves, as in JSON.
test "json.unquoted scalars keep their JSON type" {
    try expectJson("a = 1", "{\"a\":1}");
    try expectJson("a = -3.25", "{\"a\":-3.25}");
    try expectJson("a = true", "{\"a\":true}");
    try expectJson("a = false", "{\"a\":false}");
    try expectJson("a = null", "{\"a\":null}");
}

// java ✓ · pyhocon ✓ · spec ✓ — quotes make a string, whatever is inside.
test "json.quoted is always a string" {
    try expectJson("a = \"1\"", "{\"a\":\"1\"}");
    try expectJson("a = \"true\"", "{\"a\":\"true\"}");
    try expectJson("a = \"null\"", "{\"a\":\"null\"}");
    try expectJson("a = \"say \\\"hi\\\"\"", "{\"a\":\"say \\\"hi\\\"\"}");
}

// string-value-concatenation.10 · java ≈ · pyhocon ≈ · spec ✓ — a number prints as written. Both oracles
// renormalise 1e5 (java 100000, pyhocon 100000.0): the same JSON value, other text.
test "json.a number prints as written" {
    try expectJson("a = 1e5", "{\"a\":1e5}");
    try expectJson("a = 1.50", "{\"a\":1.50}");
}

// A number is JSON's number grammar, all of the text or nothing. What starts
// like one and is not — `-foo`, `1.` — is a parse error, see "numbers" in Ast.zig.
// `.5`   · java ✓ · pyhocon ⚠️ 0.5 — JSON numbers need a digit before the dot,
//          and a dot does not start one.
// `1 2`  · java ✓ · pyhocon ✓ — one unquoted text with a space, not a number.
// `10.0bar` · java ✓ · pyhocon ✓ — a number with text after it is text.
test "json.almost a number is a string" {
    try expectJson("a = .5", "{\"a\":\".5\"}");
    try expectJson("a = 1 2", "{\"a\":\"1 2\"}");
    try expectJson("a = 10.0bar", "{\"a\":\"10.0bar\"}");
    try expectJson("a = true foo", "{\"a\":\"true foo\"}");
    try expectJson("a = the dog ate my homework", "{\"a\":\"the dog ate my homework\"}");
}

// java ✓ · pyhocon ✓ · spec ✓ — containers nest, and keys come out in the order
// they were written.
test "json.objects and arrays" {
    try expectJson("a { b = [1, x, {c = 2}] }", "{\"a\":{\"b\":[1,\"x\",{\"c\":2}]}}");
    try expectJson("b = 1\na = 2", "{\"b\":1,\"a\":2}");
    try expectJson("a { b = 1 }\na { c = 2 }", "{\"a\":{\"b\":1,\"c\":2}}");
    try expectJson("a = []\nb {}", "{\"a\":[],\"b\":{}}");
    try expectJson("", "{}");
}

// omit-root-braces/006-010 · java ⚠️ · pyhocon ✓ · spec ✓ — a document that
// starts with `[` is an array, after comments and blank lines too. Java has no
// array-rooted config and rejects all four with WrongType.
test "json.an array root is the document" {
    try expectJson("[1, 2, 3]", "[1,2,3]");
    try expectJson("[]", "[]");
    try expectJson("# a leading comment\n[1, 2]", "[1,2]");
    try expectJson("\n[1, 2]", "[1,2]");
}

// As in std.json, the root is whatever T says, so a list parses into a slice.
test "parsed.an array root parses into a slice" {
    const parsed = try hocon.parseFromSlice([]u32, testing.allocator, "[4, 8, 15, 16, 23, 42]", .{});
    defer parsed.deinit();
    try testing.expectEqualSlices(u32, &.{ 4, 8, 15, 16, 23, 42 }, parsed.value);
}

// Resolution runs inside the parse, so a substitution with nothing behind it is
// refused there — Stringify allows no error of its own, printing is too late.
test "json.an unresolved substitution is an error" {
    try testing.expectError(error.Unresolved, hocon.parseFromSlice(hocon.Value, testing.allocator, "a = ${b}", .{}));
    try testing.expectError(error.Unresolved, hocon.parseFromSlice(hocon.Value, testing.allocator, "a { b = [1, ${c}] }", .{}));
}

// ---------------------------------------------------------------------------
// Diagnostics — where a parse failed. The error itself stays a plain Zig error;
// `Diagnostics` keeps the first one and where it is: the file, the byte offset,
// line and column (1-based, the column in code points, the way
// std.zig.Ast.tokenLocation counts) and the line itself. Errors in included
// files are in Include.zig, next to the files they need.
//
// The caret tables write a row the way a reader would point at the mistake: the
// source, with one extra line under the line the error is on — `^` under its
// column, then the error's name. A source line never starts with `^` (it is
// forbidden in unquoted text), so the caret line cannot be mistaken for one.
//
// Oracles: the rows below are errors for java too (`String: <line>:` matches
// ours on every row) except where a group says otherwise. Neither oracle gives a
// column we could copy: java reports the line only, pyhocon counts bytes and
// points one past the end of the token (`port = 80 [1]` → col 14). The column
// is ours: the first byte of the token or part that cannot stand there, or the
// `${` of the substitution that failed.
// ---------------------------------------------------------------------------

const table = @import("table.zig");

fn expectCarets(rows: []const [:0]const u8) !void {
    const cases = try testing.allocator.alloc(table.Case, rows.len);
    defer testing.allocator.free(cases);
    for (cases, rows) |*c, row| c.* = .ok(row, row);
    try table.expectAll(cases, .{ .dump = dumpCaret });
}

/// Takes the caret line out of `row`, parses what is left, and puts a caret line
/// back where the diagnostic says — so a correct parse renders the row unchanged.
fn dumpCaret(gpa: std.mem.Allocator, row: [:0]const u8) anyerror![]u8 {
    var source: std.ArrayList(u8) = .empty;
    var rows = std.mem.splitScalar(u8, row, '\n');
    var first = true;
    while (rows.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "^")) continue;
        if (!first) try source.append(gpa, '\n');
        first = false;
        try source.appendSlice(gpa, line);
    }
    const src = try source.toOwnedSliceSentinel(gpa, 0);

    var diag: hocon.Diagnostics = .{};
    const err = if (hocon.parseFromSliceLeaky(hocon.Value, gpa, src, .{ .diagnostics = &diag })) |_|
        return error.ParsedWithoutError
    else |e|
        e;

    // Said in the table's own report rather than as a bare `TestUnexpectedError`.
    const kept = diag.err orelse return std.fmt.allocPrint(gpa, "{t}, but Diagnostics is empty", .{err});
    if (kept != err) return std.fmt.allocPrint(gpa, "{t}, but Diagnostics holds {t}", .{ err, kept });

    const loc = diag.location orelse return std.fmt.allocPrint(gpa, "{t}, but without a position", .{err});
    if (loc.line == 0 or loc.column == 0) return std.fmt.allocPrint(gpa, "{t} at {d}:{d}, but both count from 1", .{ err, loc.line, loc.column });

    var out: std.Io.Writer.Allocating = .init(gpa);
    var lines = std.mem.splitScalar(u8, src, '\n');
    var n: usize = 1;
    while (lines.next()) |line| : (n += 1) {
        if (n > 1) try out.writer.writeByte('\n');
        try out.writer.writeAll(line);
        if (n == loc.line) {
            try out.writer.writeByte('\n');
            try out.writer.splatByteAll(' ', loc.column - 1);
            try out.writer.print("^ {t}", .{err});
        }
    }
    if (loc.line >= n) try out.writer.print("\n(past the last line: {d}:{d} {t})", .{ loc.line, loc.column, err });
    return out.toOwnedSlice();
}

// Parser: the token it did not expect. At the end of the input that is right
// after the last character that is not whitespace, also when the file ends with
// a newline: the line after it is empty, and an empty line shows nothing. Zig
// does the same with a missing `;`, at the end of the token before it.
// java ✓ · pyhocon ⚠️ — pyhocon takes `a = ` as an empty string.
// `a = [1, 2⏎` · java ⚠️ line 2 · pyhocon ⚠️ 2:1 — both put the end of the input
// on the empty line after the newline.
// `a\nb = 1` is a newline inside an unfinished member, so the token is `b`.
test "diagnostics.UnexpectedToken" {
    try expectCarets(&.{
        \\a = 
        \\   ^ UnexpectedToken
        ,
        \\a = [1, 2
        \\         ^ UnexpectedToken
        \\
        ,
        \\a = }
        \\    ^ UnexpectedToken
        ,
        \\a = 1 }
        \\      ^ UnexpectedToken
        ,
        \\a = $x
        \\    ^ UnexpectedToken
        ,
        \\a = "the dog ate my homework
        \\    ^ UnexpectedToken
        ,
        \\a
        \\b = 1
        \\^ UnexpectedToken
        ,
        \\a = 1
        \\b = {
        \\     ^ UnexpectedToken
        ,
    });
}

// The opening quote of the string with the bad escape, in a value, a key and a
// substitution path alike.
// java ✓ · pyhocon ⚠️ — pyhocon keeps `\q` in a value as the two characters.
test "diagnostics.InvalidEscape" {
    try expectCarets(&.{
        \\a = "\q"
        \\    ^ InvalidEscape
        ,
        \\"\q" = 1
        \\^ InvalidEscape
        ,
        \\a = 1
        \\b = ${a."\q"}
        \\        ^ InvalidEscape
        ,
    });
}

// Value building: the first part that cannot join what came before it.
// java ✓ · pyhocon ✓ · spec ✓ — a list does not concatenate with text.
// `c = [1] tea` · java ⚠️ `{"c":[1]}` — drops `tea` without a word (and does the
// same to `a = {b = 1} x`), while `a = [1] 2` is its WrongType. The spec makes
// both an error, and the spec decides.
test "diagnostics.UnsupportedConcatenation" {
    try expectCarets(&.{
        \\port = 80 [1]
        \\          ^ UnsupportedConcatenation
        ,
        \\a = [1] 2
        \\        ^ UnsupportedConcatenation
        ,
        \\a = "x" [1]
        \\        ^ UnsupportedConcatenation
        ,
        \\a { b = 1 }
        \\c = [1] tea
        \\        ^ UnsupportedConcatenation
        ,
        // Only the resolver finds this one: until `${a}` is a list, it is text.
        // The same part is blamed as at load, the one that does not fit.
        // java ⚠️ reports line 1, where the list was written; pyhocon ✓ 2:10.
        \\a = [1]
        \\b = ${a} tea
        \\         ^ UnsupportedConcatenation
        ,
    });
}

// A line that ends with `\r\n` has its error at the same column as with `\n`:
// the `\r` is part of the line ending, not a character to count. No table, as a
// `\r` cannot be written in a multiline string.
// java ✓ line 1 · pyhocon ✓ 1:5 at the `${`, an error either way
test "diagnostics.column at a CRLF line end" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for ([_][:0]const u8{ "a = ${b\nc = 1", "a = ${b\r\nc = 1" }) |src| {
        var diag: hocon.Diagnostics = .{};
        try testing.expectError(error.UnexpectedToken, hocon.parseFromSliceLeaky(hocon.Value, arena.allocator(), src, .{ .diagnostics = &diag }));
        try testing.expectEqual(1, diag.location.?.line);
        try testing.expectEqual(8, diag.location.?.column);
        try testing.expectEqualStrings("a = ${b", diag.location.?.source_line);
    }
}

// No row for UnsupportedNodeKind: `[1, 2]` was the last input reaching it, and #6
// made an array root valid. The parser builds no node `Value` rejects, so the
// error is an internal invariant, covered by the unit test in Value.zig.

// A slice has no file to include from, so an include in it fails at the
// keyword. Errors in included files are in Include.zig.
// java ⚠️ ignores it (no such file is an empty object) · pyhocon ⚠️ the same · spec –
test "diagnostics.IncludeNeedsFile" {
    try expectCarets(&.{
        \\a = 1
        \\  include "x.conf"
        \\  ^ IncludeNeedsFile
        ,
    });
}

// `a += b` is `a = ${?a} [b]`, so a value below it that is not a list fails
// the way the long form does: at the list, the part that does not fit.
// java ✓ (WrongType) · pyhocon ⚠️ gives "1 b" and {"b":2} · spec ✓
test "diagnostics.UnsupportedConcatenation from +=" {
    try expectCarets(&.{
        \\a = 1
        \\a += b
        \\     ^ UnsupportedConcatenation
        ,
        \\a { b = { c = 1 } }
        \\a.b += 2
        \\       ^ UnsupportedConcatenation
        ,
    });
}

// The number errors from #6 point at the start of the word that is not a JSON
// number, also when it is not the first word of the value.
// java ⚠️ lenient (a string) · pyhocon ⚠️ lenient · spec ✓
test "diagnostics.LeadingZeroIsNotAJsonNumber" {
    try expectCarets(&.{
        \\a = 01
        \\    ^ LeadingZeroIsNotAJsonNumber
        ,
        \\a = my cat is 01
        \\              ^ LeadingZeroIsNotAJsonNumber
        ,
    });
}

// A HOCON file is UTF-8 (spec L117): the first byte that is not, quoted or
// not, wherever it stands. Written with `\x` escapes, which a multiline string
// does not have.
// java ⚠️ reads the byte as U+FFFD · pyhocon ⚠️ UnicodeDecodeError, no place · spec ✓
test "diagnostics.InvalidUtf8" {
    try expectCarets(&.{
        "a = caf\xe9\n       ^ InvalidUtf8",
        "a = \"caf\xe9\"\n        ^ InvalidUtf8",
        "a { b = 1 }\ncaf\xc3 = 1\n   ^ InvalidUtf8",
        // Columns count code points, `é` is one. This took the place of a test
        // for an error after a bad byte on the same line, which cannot happen
        // now: the bad byte is the error.
        "a = xé\xff [1]\n      ^ InvalidUtf8",
        // An overlong `/` and a lone surrogate are not UTF-8 either.
        "a = \xc0\xaf\n    ^ InvalidUtf8",
        "a = \xed\xa0\x80\n    ^ InvalidUtf8",
    });
}

// java ⚠️ lenient · pyhocon ⚠️ lenient · spec ✓
test "diagnostics.HyphenIsNotAJsonNumber" {
    try expectCarets(&.{
        \\a = -foo
        \\    ^ HyphenIsNotAJsonNumber
        ,
    });
}

// java ⚠️ lenient · pyhocon ⚠️ lenient · spec ✓
test "diagnostics.BadNumber" {
    try expectCarets(&.{
        \\a = 1.
        \\    ^ BadNumber
        ,
        \\a { b = -.33 }
        \\        ^ BadNumber
        ,
    });
}

// A comma no element claims (#6) points at that comma.
// java ✓ · pyhocon ⚠️ accepts a doubled comma · spec ✓
test "diagnostics.UnexpectedToken extra comma" {
    try expectCarets(&.{
        \\a = [1,,2]
        \\       ^ UnexpectedToken
        ,
        \\a = [,1]
        \\     ^ UnexpectedToken
        ,
        \\, a = 1
        \\^ UnexpectedToken
        ,
        \\a { b = 1,, }
        \\          ^ UnexpectedToken
        ,
    });
}

// java ✓ (BadPath) · pyhocon ✓ (col 5) — a path with an empty element.
test "diagnostics.MalformedKey" {
    try expectCarets(&.{
        \\a = ${a.}
        \\    ^ MalformedKey
        ,
    });
}

// Resolver: the `${` that has nothing behind it, and the first one when there
// are several. java ✓ · pyhocon ✓ (same line and column) · spec ✓
test "diagnostics.Unresolved" {
    try expectCarets(&.{
        \\a = ${b}
        \\    ^ Unresolved
        ,
        \\a = 1
        \\b = ${nope}
        \\    ^ Unresolved
        ,
        \\a = ${x}
        \\    ^ Unresolved
        \\b = ${y}
        ,
        \\a = ${b} ${c}
        \\    ^ Unresolved
        ,
    });
}

// A self-reference with nothing below it is undefined, as if it named a missing
// path (spec), not a cycle: the caret is on its own `${`. Also when a value comes
// for the key later — the self-reference cannot see forward.
// java ✓ (UnresolvedSubstitution, same line) · pyhocon ✓ (same line and column) · spec ✓
test "diagnostics.Unresolved self-reference" {
    try expectCarets(&.{
        \\a = ${a}
        \\    ^ Unresolved
        ,
        \\mood = ${mood} wombat
        \\       ^ Unresolved
        \\mood = { grumpy = true }
        ,
    });
}

// The value a hidden layer would never have shown is evaluated once an object
// merges onto it, and an undefined optional on top leaves it to be evaluated.
// java ✓ (same line) · pyhocon ⚠️ hangs on the first · spec ✓
test "diagnostics.Unresolved below a merge" {
    try expectCarets(&.{
        \\a = { b = ${nope} }
        \\          ^ Unresolved
        \\r = {}
        \\a = ${r}
        ,
        \\a = [${nope}]
        \\     ^ Unresolved
        \\a = ${?nope}
        ,
    });
}

// The `${` that closes the cycle: the one that leads back to a member still
// being resolved. In the second row `a` leads through `${b}` to `b`, and `${a}`
// on line 2 leads back to `a`.
// java ✓ (same line) · pyhocon ✓ (lists every `${` of the cycle) · spec ✓
test "diagnostics.SubstitutionCycle" {
    try expectCarets(&.{
        \\a = ${b}
        \\b = ${a}
        \\    ^ SubstitutionCycle
        ,
        \\a { b = ${a} }
        \\        ^ SubstitutionCycle
        ,
        \\a = ${b}
        \\b = ${c}
        \\c = ${a}
        \\    ^ SubstitutionCycle
        ,
        // Entered from outside, it is still the ref that closes the cycle.
        \\x = ${a}
        \\a = ${b}
        \\b = ${a}
        \\    ^ SubstitutionCycle
        ,
        // A list is not a self-referential field, so looking back from the
        // optional on top only comes round to it again (java ✓, pyhocon ⚠️
        // overflows its stack).
        \\a = [${a}]
        \\     ^ SubstitutionCycle
        \\a = ${?a}
        ,
    });
}

// The column counts code points, not bytes: é is 2 bytes, ☕ 3, 🦆 4, the NBSP
// 2, and each is one column. A line resets the count, wide characters before it
// or not. pyhocon ⚠️ counts bytes (col 25 for the first row).
test "diagnostics.column counts code points" {
    try expectCarets(&.{
        \\a = "café ☕ 🦆" [1]
        \\               ^ UnsupportedConcatenation
        ,
        "a = x\u{a0}y [1]\n        ^ UnsupportedConcatenation",
        \\"🦆" = 1
        \\b = 1 [2]
        \\      ^ UnsupportedConcatenation
        ,
    });
}

// The offset is in bytes, the column in code points — the same spot both ways.
test "diagnostics.offset is bytes, location is code points" {
    const src = "a = \"🦆\" [1]";
    var diag: hocon.Diagnostics = .{};
    defer diag.deinit(testing.allocator);
    try testing.expectError(error.UnsupportedConcatenation, hocon.parseFromSlice(hocon.Value, testing.allocator, src, .{ .diagnostics = &diag }));
    const loc = diag.location.?;
    try testing.expectEqual(11, loc.offset);
    try testing.expectEqual(1, loc.line);
    try testing.expectEqual(9, loc.column);
}

// A parse that succeeds says nothing, even when the Diagnostics it is handed
// still holds an error from an earlier one; a second failure replaces the first.
// The copies of the first are freed in between, by whoever handed it over.
test "diagnostics.each parse starts it afresh" {
    var diag: hocon.Diagnostics = .{};
    defer diag.deinit(testing.allocator);
    try testing.expectError(error.Unresolved, hocon.parseFromSlice(hocon.Value, testing.allocator, "a = ${b}", .{ .diagnostics = &diag }));
    diag.deinit(testing.allocator);
    try testing.expectError(error.UnexpectedToken, hocon.parseFromSlice(hocon.Value, testing.allocator, "a = 1 }", .{ .diagnostics = &diag }));
    try testing.expectEqual(error.UnexpectedToken, diag.err.?);
    try testing.expectEqual(6, diag.location.?.offset);
    diag.deinit(testing.allocator);

    const parsed = try hocon.parseFromSlice(hocon.Value, testing.allocator, "a = the cat sat on the keyboard", .{ .diagnostics = &diag });
    defer parsed.deinit();
    try testing.expectEqual(null, diag.err);
}

// Rendered the way the zig compiler prints its own errors: `path:line:col:`,
// the line, and a caret under the column. A slice has no file name, so the
// path is left out; `parseFromFile` names it (Include.zig).
test "diagnostics.render" {
    const src =
        \\name = grumpy wombat
        \\host = example.org
        \\port = 80 [1]
        \\tls = off
    ;
    var diag: hocon.Diagnostics = .{};
    defer diag.deinit(testing.allocator);
    try testing.expectError(error.UnsupportedConcatenation, hocon.parseFromSlice(hocon.Value, testing.allocator, src, .{ .diagnostics = &diag }));

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try diag.render(&out.writer);
    try testing.expectEqualStrings(
        \\3:11: error: UnsupportedConcatenation
        \\port = 80 [1]
        \\          ^
        \\
    , out.written());
}

// Where a member begins, the token that cannot begin one: after a braced root,
// a second root container, a container with no key in a block, a `${` as a key.
// java ✓ (same line on every row) · pyhocon ✓ (same line and column) · spec ✓
test "diagnostics.UnexpectedToken where a member begins" {
    try expectCarets(&.{
        \\{a = 1} b = 2
        \\        ^ UnexpectedToken
        ,
        \\a { {b = 1} }
        \\    ^ UnexpectedToken
        ,
        \\a { [1] }
        \\    ^ UnexpectedToken
        ,
        \\a = 1
        \\{b = 2}
        \\^ UnexpectedToken
        ,
        \\a = 1
        \\[1]
        \\^ UnexpectedToken
        ,
        \\a = 1
        \\${b} = 2
        \\^ UnexpectedToken
        ,
    });
}

// Inside a value: a substitution path that is not text — at the part that is
// not —, a `${` that is never closed, junk around `include`.
// java ✓ (line 1 on every row, and it names the `[` too) · pyhocon ⚠️ errors,
// but its positions are no help here · spec ✓
test "diagnostics.UnexpectedToken inside a value" {
    try expectCarets(&.{
        \\a = ${[1]}
        \\      ^ UnexpectedToken
        ,
        \\a = ${b [1]}
        \\        ^ UnexpectedToken
        ,
        // The newline ends the path, so the newline is the token that is not `}`.
        \\a = ${b
        \\       ^ UnexpectedToken
        \\c = 1
        ,
        \\include "x" y
        \\            ^ UnexpectedToken
        ,
        \\include x
        \\        ^ UnexpectedToken
        ,
    });
}

// A key with an empty element, at the dot that has nothing before or after it.
// java ✓ (BadPath, same line) · pyhocon ⚠️ drops the empty element · spec ✓
test "diagnostics.UnexpectedToken empty key element" {
    try expectCarets(&.{
        \\x = 1
        \\a..b = 2
        \\  ^ UnexpectedToken
        ,
        \\x = 1
        \\.a = 2
        \\^ UnexpectedToken
        ,
        \\a.b. = 1
        \\   ^ UnexpectedToken
        ,
        \\x = 1
        \\"a". = 2
        \\   ^ UnexpectedToken
        ,
    });
}

// The quoted part with the bad escape, when something comes before it in the
// same key or value. java ✓ (line 1) · pyhocon ⚠️ keeps `\q` as two characters
test "diagnostics.InvalidEscape after another part" {
    try expectCarets(&.{
        \\a."\q" = 1
        \\  ^ InvalidEscape
        ,
        \\a = x "\q"
        \\      ^ InvalidEscape
        ,
    });
}

// java ✓ (WrongType, line 1) · pyhocon ✓ line, ⚠️ column (end of the token) · spec ✓
test "diagnostics.UnsupportedConcatenation text then an object" {
    try expectCarets(&.{
        \\a = 1 {b = 1}
        \\      ^ UnsupportedConcatenation
        ,
    });
}

// A misfit only the resolver sees is the same part that load would blame: the
// first one that does not fit onto what came before it. A `${?x}` with nothing
// behind it is gone by then, so it is never the one.
// java ✓ (same line, or the line the list was written on) · pyhocon ✓ (same
// part, its column one past the end) · spec ✓
test "diagnostics.UnsupportedConcatenation found by the resolver" {
    try expectCarets(&.{
        \\a = [1]
        \\b = x
        \\c = ${b} ${a}
        \\         ^ UnsupportedConcatenation
        ,
        \\a = [1]
        \\b = [2]
        \\c = ${a} ${b} tea
        \\              ^ UnsupportedConcatenation
        ,
        \\a = [1] ${?x} tea
        \\              ^ UnsupportedConcatenation
        ,
        \\a = x ${?nope} [2]
        \\               ^ UnsupportedConcatenation
        ,
    });
}

// The rendered line is the source line as written — indentation kept, a CRLF
// ending gone, the caret indented by code points — except that a tab or a stray
// `\r` prints as one space, or the caret would not line up under it.
test "diagnostics.render keeps the line as written" {
    const cases = [_]struct { src: [:0]const u8, err: anyerror = error.UnsupportedConcatenation, want: []const u8 }{
        .{ .src = "name = grumpy wombat\r\n  port = 80 [1]\r\n", .want = "2:13: error: UnsupportedConcatenation\n  port = 80 [1]\n            ^\n" },
        .{ .src = "a = \"🦆\" [1]", .want = "1:9: error: UnsupportedConcatenation\na = \"🦆\" [1]\n        ^\n" },
        .{ .src = "a = 1\n\tb = 2 [3]", .want = "2:8: error: UnsupportedConcatenation\n b = 2 [3]\n       ^\n" },
        // Only `\n` starts a line, so a lone `\r` keeps the line together — and
        // since it is whitespace (#6), `1\rb` is one value and the `=` is what fails.
        .{ .src = "a = 1\rb = }", .err = error.UnexpectedToken, .want = "1:9: error: UnexpectedToken\na = 1 b = }\n        ^\n" },
    };
    for (cases) |c| {
        var diag: hocon.Diagnostics = .{};
        defer diag.deinit(testing.allocator);
        try testing.expectError(c.err, hocon.parseFromSlice(hocon.Value, testing.allocator, c.src, .{ .diagnostics = &diag }));
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try diag.render(&out.writer);
        try testing.expectEqualStrings(c.want, out.written());
    }
}

// A conversion error is kept too, but without a place: the document was fine,
// the type did not fit it. It renders as the first line alone.
test "diagnostics.a conversion error has no position" {
    var diag: hocon.Diagnostics = .{};
    const T = struct { a: u8 };
    try testing.expectError(error.MissingField, hocon.parseFromSlice(T, testing.allocator, "b = the cat sat on the keyboard", .{ .diagnostics = &diag }));
    try testing.expectEqual(error.MissingField, diag.err.?);
    try testing.expectEqual(null, diag.location);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try diag.render(&out.writer);
    try testing.expectEqualStrings("error: MissingField\n", out.written());
}

// Out of memory has no position either. Every allocation the parse makes is
// made to fail once, in turn: each of those runs keeps OutOfMemory with no
// place, until the parse gets far enough to fail on its own. Copying the place
// into the Diagnostics can run out too; then the error stays and the place goes.
// The very first allocation is the arena, before there is any text: the error
// is still the one in the Diagnostics, not one an earlier parse left there.
test "diagnostics.out of memory has no position" {
    var i: usize = 0;
    while (true) : (i += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = i });
        var diag: hocon.Diagnostics = .{ .err = error.InvalidEscape };
        defer diag.deinit(testing.allocator);
        if (hocon.parseFromSlice(hocon.Value, failing.allocator(), "a = 1\nb = ${nope}", .{ .diagnostics = &diag })) |parsed| {
            parsed.deinit();
            return error.ParsedWithoutError;
        } else |err| switch (err) {
            error.OutOfMemory => {
                try testing.expectEqual(error.OutOfMemory, diag.err.?);
                try testing.expectEqual(null, diag.location);
            },
            else => {
                try testing.expectEqual(error.Unresolved, err);
                try testing.expectEqual(error.Unresolved, diag.err.?);
                const loc = diag.location orelse continue;
                try testing.expectEqual(10, loc.offset);
                return;
            },
        }
    }
}

// The same for a file, where the arena and the text come before there is a
// place to point at.
test "diagnostics.out of memory reading a file has no position" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "app.conf", .data = "a = 1\nb = ${nope}" });
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/app.conf", .{tmp.sub_path});
    defer testing.allocator.free(path);

    var i: usize = 0;
    while (true) : (i += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = i });
        var diag: hocon.Diagnostics = .{ .err = error.InvalidEscape };
        defer diag.deinit(testing.allocator);
        if (hocon.parseFromFile(hocon.Value, failing.allocator(), testing.io, path, .{ .diagnostics = &diag })) |parsed| {
            parsed.deinit();
            return error.ParsedWithoutError;
        } else |err| switch (err) {
            error.OutOfMemory => {
                try testing.expectEqual(error.OutOfMemory, diag.err.?);
                try testing.expectEqual(null, diag.location);
            },
            else => {
                try testing.expectEqual(error.Unresolved, diag.err.?);
                if (diag.location == null) continue;
                return;
            },
        }
    }
}

// A slice is held to the size a file may have, the size every offset in a
// document fits: one byte short of it parses, the size itself is refused before
// any parsing.
test "diagnostics.a slice as big as the file limit is refused" {
    // 64 MiB, `max_file_size` in Include.zig.
    const big = try testing.allocator.allocSentinel(u8, 64 * 1024 * 1024, 0);
    defer testing.allocator.free(big);
    @memset(big, ' ');

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: hocon.Diagnostics = .{};
    try testing.expectError(error.StreamTooLong, hocon.parseFromSliceLeaky(hocon.Value, arena.allocator(), big, .{ .diagnostics = &diag }));
    try testing.expectEqual(error.StreamTooLong, diag.err.?);
    try testing.expectEqual(null, diag.location);

    big[big.len - 1] = 0;
    _ = try hocon.parseFromSliceLeaky(hocon.Value, arena.allocator(), big[0 .. big.len - 1 :0], .{});
}

// Nothing failed, nothing to print — a render after a good parse writes nothing
// rather than tripping over the missing error.
test "diagnostics.render with no error writes nothing" {
    const diag: hocon.Diagnostics = .{};
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try diag.render(&out.writer);
    try testing.expectEqualStrings("", out.written());
}

// An offset past the end — never one a parse makes — points just past the last
// character instead of out of bounds.
test "diagnostics.locate clamps an offset past the end" {
    const loc = hocon.Diagnostics.locate("app.conf", "a = 1\nb", 99);
    try testing.expectEqual(2, loc.line);
    try testing.expectEqual(2, loc.column);
    try testing.expectEqualStrings("b", loc.source_line);
}
