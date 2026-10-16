//! Writes a value as HOCON, the way `std.json.Stringify` writes one as JSON:
//! `stringify(value, .{}, writer)`, or `stringifyAlloc` for the text alone.
//!
//! Any Zig value a config is made of, and `Value` too — resolved or not, so a
//! document read without resolving it prints with its `${…}` still in place.
//!
//! What comes out: nested blocks `a { b = 1 }`, `=` before anything else, two
//! spaces per level, keys in field order, no comments. A struct or an object at
//! the top is the document itself, written without braces.

const std = @import("std");
const Writer = std.Io.Writer;
const Value = @import("Value.zig").Value;
const Ref = @import("Value.zig").Ref;
const Ast = @import("Ast.zig");
const number = @import("utils/number.zig");
const unqoute = @import("utils/unqoute.zig");
const whitespaceLen = @import("Tokenizer.zig").whitespaceLen;
const isExponentSign = @import("Tokenizer.zig").isExponentSign;
const units = @import("units.zig");

/// Nothing to set yet: it is here so a call reads like `std.json.Stringify.value`.
pub const Options = struct {};

/// A document is a block or a list (spec L130), so the value is one of those;
/// anything else is a compile error. An optional is too: no document reads
/// back as null, so the caller unwraps it.
pub fn stringify(value: anytype, options: Options, w: *Writer) Writer.Error!void {
    const T = @TypeOf(value);
    const document = switch (@typeInfo(T)) {
        .pointer => |p| if (p.size == .one) return stringify(value.*, options, w) else p.child != u8,
        .array => |a| a.child != u8,
        .@"struct" => comptime !isUnits(T),
        .@"union", .void => true,
        else => false,
    };
    if (!document) @compileError("hocon: a document is a block or a list, not " ++ @typeName(T));
    if (isBlock(value)) return writeMembers(value, w, 0);
    try writeValue(value, w, 0);
    try w.writeByte('\n');
}

/// `stringify` into memory; the caller owns what comes back.
pub fn stringifyAlloc(gpa: std.mem.Allocator, value: anytype, options: Options) error{OutOfMemory}![]u8 {
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    // Writing to memory fails only when the memory runs out.
    stringify(value, options, &out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// Types as std.json writes them: an enum is its name, `[]const u8` a string, a
/// tagged union `{ tag = … }`, slices and arrays lists, a pointer what it points to.
fn writeValue(value: anytype, w: *Writer, indent: usize) Writer.Error!void {
    const T = @TypeOf(value);
    if (T == Value) return writeTree(value, w, indent);
    if (comptime isUnits(T)) return value.format(w);
    switch (@typeInfo(T)) {
        .bool => try w.writeAll(if (value) "true" else "false"),
        .int, .comptime_int => try w.print("{d}", .{value}),
        .float => try writeFloat(value, w),
        .comptime_float => try writeFloat(@as(f64, value), w),
        .null => try w.writeAll("null"),
        .optional => if (value) |v| try writeValue(v, w, indent) else try w.writeAll("null"),
        // A value outside the named ones of a non-exhaustive enum has no name.
        .@"enum" => if (std.enums.tagName(T, value)) |name| try writeString(name, w) else try w.print("{d}", .{@intFromEnum(value)}),
        .enum_literal => try writeString(@tagName(value), w),
        .@"struct", .@"union", .void => try writeBlock(value, w, indent),
        .array => try writeValue(@as([]const std.meta.Elem(T), &value), w, indent),
        .pointer => |p| switch (p.size) {
            .one => try writeValue(value.*, w, indent),
            // Bytes are a string when they are text, as HOCON is UTF-8.
            // WTF-8 as well: what a quoted `"\ud83d"` was read into (see `unqoute`).
            .slice => if (p.child == u8 and std.unicode.wtf8ValidateSlice(value)) try writeString(value, w) else try writeList(value, w, indent),
            else => @compileError("hocon: cannot stringify " ++ @typeName(T)),
        },
        else => @compileError("hocon: cannot stringify " ++ @typeName(T)),
    }
}

/// A `Value` prints the way it was written. A quoted scalar stays quoted, so
/// `"80"` stays a string; unquoted text comes out as it went in where it reads
/// back that way (`isRaw`).
fn writeTree(value: Value, w: *Writer, indent: usize) Writer.Error!void {
    switch (value) {
        .scalar => |s| if (!s.quoted and isRaw(s.value)) try w.writeAll(s.value) else try writeQuoted(s.value, w),
        .array => |items| try writeList(items, w, indent),
        .object => try writeBlock(value, w, indent),
        .ref => |r| try writeRef(r, w),
        // The parts side by side. A gap between them is a part of its own, an
        // unquoted scalar of whitespace, and goes out as it is.
        .pending => |parts| for (parts) |part| {
            if (part.value.isGap()) try w.writeAll(part.value.scalar.value) else try writeTree(part.value, w, indent);
        },
        // Only a field holds one, and `writeMembers` writes it as that many fields.
        .stack => unreachable,
    }
}

/// `${a.b}` or `${?a.b}`, each element as a key is written, and `[]` after
/// the path for a list from the environment (`${X[]}`, #11). The path is the
/// whole path from the root, the way the ref looks it up; one from a file
/// included inside a block has a fallback too (`writeScopedRef`).
fn writeRef(ref: Ref, w: *Writer) Writer.Error!void {
    try w.writeAll(if (ref.flags.optional) "${?" else "${");
    for (ref.path, 0..) |key, i| {
        if (i > 0) try w.writeByte('.');
        try writeKey(key.value, w);
    }
    if (ref.flags.list) try w.writeAll("[]");
    try w.writeByte('}');
}

/// A field that is a ref from a file included inside a block: the path with
/// the block in front, and when that finds nothing, the path as written
/// (spec L1048). Written as the key twice, `a = ${x}` under `a = ${?scope.x}`,
/// the one below is what is left when the one on top finds nothing. The
/// resolver keeps the scope only while the scoped path may find nothing
/// (`Value.mayVanish`), and a self-reference, `+=` too, as its own layers
/// over `${x}`.
// ponytail: what `${…}` cannot say, each needing an unusual input. Inside a
// list or a concatenation other than `+=` the fallback is lost: the scoped
// path alone is written. An object found at `scope.x` merges onto `${x}`,
// which then has to resolve too. And the variables the original never reads:
// `scope.x` when `${?scope.x}` finds nothing, and `x` when a self-reference's
// fallback, the root's `x`, vanishes (`a += 1` over the root's
// `a = ${?L[]}`). Upgrade if one shows up.
fn writeScopedRef(key: []const u8, ref: Ref, w: *Writer, indent: usize) Writer.Error!void {
    try writeMember(key, Value{ .ref = ref.from(ref.path[ref.scope_len..]) }, w, indent);
    var scoped = ref.from(ref.path);
    scoped.flags.optional = true;
    try writeMember(key, Value{ .ref = scoped }, w, indent);
}

/// What `a += b` added, when the layer is still that: `a = ${?a} [b]`, the ref
/// made by `+=` (`append`) and a list of one.
fn appended(layer: Value) ?Value {
    if (layer != .pending or layer.pending.len != 2) return null;
    const self_ref = layer.pending[0].value;
    const list = layer.pending[1].value;
    if (self_ref != .ref or !self_ref.ref.flags.append) return null;
    if (list != .array or list.array.len != 1) return null;
    return list.array[0];
}

fn writeBlock(value: anytype, w: *Writer, indent: usize) Writer.Error!void {
    if (!hasMembers(value)) return w.writeAll("{}");
    try w.writeAll("{\n");
    try writeMembers(value, w, indent + 2);
    try w.splatByteAll(' ', indent);
    try w.writeByte('}');
}

/// The members of a block, one per line, without the braces.
fn writeMembers(value: anytype, w: *Writer, indent: usize) Writer.Error!void {
    const T = @TypeOf(value);
    if (T == Value) {
        for (value.object) |m| {
            // A key written more than once and kept as a stack is written that
            // many times again, bottom first: loading it stacks it up the same way.
            const layers: []const Value = if (m.value == .stack) m.value.stack else &.{m.value};
            for (layers) |layer| {
                if (layer == .ref and layer.ref.scope_len > 0) {
                    try writeScopedRef(m.key.value, layer.ref, w, indent);
                } else if (appended(layer)) |item| {
                    try w.splatByteAll(' ', indent);
                    try writeKey(m.key.value, w);
                    try w.writeAll(" += ");
                    try writeValue(item, w, indent);
                    try w.writeByte('\n');
                } else {
                    try writeMember(m.key.value, layer, w, indent);
                }
            }
        }
        return;
    }
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            if (s.is_tuple) @compileError("hocon: cannot stringify a tuple, " ++ @typeName(T));
            inline for (s.fields) |field| {
                if (written(field, value)) try writeMember(field.name, @field(value, field.name), w, indent);
            }
        },
        // `inline else` hands over the payload with its own type, `void` included.
        .@"union" => switch (value) {
            inline else => |payload, tag| try writeMember(@tagName(tag), payload, w, indent),
        },
        else => {},
    }
}

fn writeMember(key: []const u8, value: anytype, w: *Writer, indent: usize) Writer.Error!void {
    try w.splatByteAll(' ', indent);
    try writeKey(key, w);
    try w.writeAll(if (isBlock(value)) " " else " = ");
    try writeValue(value, w, indent);
    try w.writeByte('\n');
}

/// A null optional is left out: it reads back as null from its absence, unless
/// the field's default is something else. Then it has to say `null`.
fn written(comptime field: std.builtin.Type.StructField, value: anytype) bool {
    if (@typeInfo(field.type) != .optional) return true;
    if (@field(value, field.name) != null) return true;
    const default = field.defaultValue() orelse return false;
    return default != null;
}

/// Text and numbers on one line, `[80, 443]`; anything with a block or a list
/// in it one element per line, which is a separator in HOCON like the comma.
fn writeList(items: anytype, w: *Writer, indent: usize) Writer.Error!void {
    if (items.len == 0) return w.writeAll("[]");
    const flat = for (items) |item| {
        if (!isFlat(item)) break false;
    } else true;

    if (flat) {
        try w.writeByte('[');
        for (items, 0..) |item, i| {
            if (i > 0) try w.writeAll(", ");
            try writeValue(item, w, indent);
        }
        return w.writeByte(']');
    }
    try w.writeAll("[\n");
    for (items) |item| {
        try w.splatByteAll(' ', indent + 2);
        try writeValue(item, w, indent + 2);
        try w.writeByte('\n');
    }
    try w.splatByteAll(' ', indent);
    try w.writeByte(']');
}

/// Written as `{ … }`, so its key needs no `=`.
fn isBlock(value: anytype) bool {
    const T = @TypeOf(value);
    if (T == Value) return value == .object;
    if (comptime isUnits(T)) return false;
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .void => true,
        .optional => if (value) |v| isBlock(v) else false,
        .pointer => |p| p.size == .one and isBlock(value.*),
        else => false,
    };
}

/// One line and no container: a scalar, text, a ref.
fn isFlat(value: anytype) bool {
    const T = @TypeOf(value);
    if (T == Value) return value == .scalar or value == .ref;
    if (comptime isUnits(T)) return true;
    return switch (@typeInfo(T)) {
        .optional => if (value) |v| isFlat(v) else true,
        .pointer => |p| if (p.size == .one) isFlat(value.*) else p.child == u8,
        .array => |a| a.child == u8,
        .@"struct", .@"union", .void => false,
        else => true,
    };
}

/// A struct that is one value in the units format, `90s`, `3mo`, `512MiB`: the
/// largest unit it is a whole number of, so it reads back the same.
fn isUnits(comptime T: type) bool {
    return T == units.Duration or T == units.Period or T == units.Size;
}

/// Whether the block has anything in it, so an empty one is `{}` on one line.
fn hasMembers(value: anytype) bool {
    const T = @TypeOf(value);
    if (T == Value) return value.object.len > 0;
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            inline for (s.fields) |field| {
                if (written(field, value)) return true;
            }
            return false;
        },
        .@"union" => return true,
        else => return false,
    }
}

/// `{d}` writes every digit, all 301 of 1e300: past these bounds a number gets
/// an exponent, as in JavaScript. Both are JSON numbers. Not a number and the
/// infinities are none, so they are strings, as std.json writes them, and
/// `parseFloat` reads them back.
fn writeFloat(value: anytype, w: *Writer) Writer.Error!void {
    if (!std.math.isFinite(value)) return w.print("\"{d}\"", .{value});
    const size = @abs(value);
    if (size == 0 or (size >= 1e-6 and size < 1e21)) return w.print("{d}", .{value});
    try w.print("{e}", .{value});
}

/// A string from a Zig value: bare when it reads back as the same string
/// (`grumpy-wombat.pem`), quoted otherwise.
fn writeString(text: []const u8, w: *Writer) Writer.Error!void {
    if (isBare(text, true)) return w.writeAll(text);
    try writeQuoted(text, w);
}

/// One element of a path. A dot would split it, so `"a.b"` is quoted.
fn writeKey(text: []const u8, w: *Writer) Writer.Error!void {
    if (isBare(text, false)) return w.writeAll(text);
    try writeQuoted(text, w);
}

/// A HOCON quoted string is a JSON string, escapes and all. Always on one line:
/// a newline is `\n`, never a `"""` block, which has no escapes and cannot end
/// in a quote.
fn writeQuoted(text: []const u8, w: *Writer) Writer.Error!void {
    try unqoute.writeJson(text, .{}, w);
}

/// A word that reads back as the same string without quotes: ASCII letters,
/// digits, `_` and `-`, a letter first, as a digit or `-` would start a number,
/// and not a word HOCON reads as something else. Space, `:`, `${`, `//`, Unicode
/// whitespace and the empty string are all outside it. A dot belongs to a value
/// (`grumpy-wombat.pem`) but splits a key.
fn isBare(text: []const u8, dots: bool) bool {
    if (text.len == 0 or !std.ascii.isAlphabetic(text[0])) return false;
    for (text) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or (dots and c == '.')) continue;
        return false;
    }
    for ([_][]const u8{ "true", "false", "null", "include" }) |word| {
        if (std.mem.eql(u8, text, word)) return false;
    }
    return true;
}

/// Unquoted text of a `Value` goes back as it was — `the dog ate my homework`,
/// `1.50` — when it reads back as the same text: nothing in it ends it early,
/// no whitespace at either end is trimmed, and a word that starts like a number
/// is one (`Ast.checkNumbers`). `+` is reserved but in the exponent of a
/// word, `1e+5 x`.
fn isRaw(text: []const u8) bool {
    if (number.isJsonNumber(text)) return true;
    if (text.len == 0 or std.mem.indexOf(u8, text, "//") != null) return false;
    if (std.mem.indexOfAny(u8, text, "$\"{}[]:=,#`^?!@*&\\\n") != null) return false;
    var word: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const ws = whitespaceLen(text[i..]);
        if (ws > 0) {
            i += ws;
            word = i;
            continue;
        }
        if (text[i] == '+' and !isExponentSign(text[word..], i - word)) return false;
        i += 1;
    }
    // The last character starts at the last byte that does not continue one.
    var last = text.len - 1;
    while (last > 0 and text[last] & 0xC0 == 0x80) last -= 1;
    if (whitespaceLen(text) > 0 or whitespaceLen(text[last..]) > 0) return false;
    var at: ?usize = null;
    Ast.checkNumbers(.{ .kind = .value, .children = &.{}, .value = text }, number.checkNumber, &at) catch return false;
    return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Tokenizer = @import("Tokenizer.zig").Tokenizer;
const Config = @import("Config.zig").Config;
const Member = @import("Value.zig").Member;
const table = @import("table.zig");

fn expectText(value: anytype, want: []const u8) !void {
    const got = try stringifyAlloc(testing.allocator, value, .{});
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

/// Written out and read back into the same type, the value it started as.
fn expectRoundTrip(value: anytype) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const text = try stringifyAlloc(gpa, value, .{});
    const back = Config.parseFromSliceLeaky(@TypeOf(value), gpa, try gpa.dupeZ(u8, text), .{}) catch |err| {
        std.debug.print("does not read back ({t}):\n{s}\n", .{ err, text });
        return err;
    };
    try testing.expectEqualDeep(value, back);
}

// java ✓ · pyhocon ✓ · spec ✓ — the default config of a program, written out:
// nested blocks, `=` before anything else, keys in field order, strings bare
// where they can be. Both oracles read this text to the JSON std.json writes
// for the same struct (key order aside; java sorts).
test "stringify.a struct is the document" {
    const T = struct {
        name: []const u8 = "the dog ate my homework",
        port: u16 = 8080,
        debug: bool = false,
        ratio: f64 = 0.25,
        level: enum { quiet, loud } = .quiet,
        plugins: []const []const u8 = &.{ "auth", "metrics" },
        tls: struct { cert: []const u8 = "grumpy-wombat.pem", ciphers: []const u8 = "HIGH" } = .{},
        empty: struct {} = .{},
    };
    try expectText(T{},
        \\name = "the dog ate my homework"
        \\port = 8080
        \\debug = false
        \\ratio = 0.25
        \\level = quiet
        \\plugins = [auth, metrics]
        \\tls {
        \\  cert = grumpy-wombat.pem
        \\  ciphers = HIGH
        \\}
        \\empty {}
        \\
    );
    try expectRoundTrip(T{});
}

// java ✓ · pyhocon ✓ · spec ✓ — a list of scalars stays on one line; one with
// a block or a list in it puts each element on a line of its own, which
// separates them as a comma would.
test "stringify.lists, unions and pointers" {
    const Storage = union(enum) { memory, disk: struct { path: []const u8 } };
    const Host = struct { host: []const u8, weight: u8 };
    try expectText(.{ .ports = [_]u16{ 80, 443 }, .none = [_]u16{} }, "ports = [80, 443]\nnone = []\n");
    try expectText(.{ .grid = [_][]const i32{ &.{ 1, 2 }, &.{3} } },
        \\grid = [
        \\  [1, 2]
        \\  [3]
        \\]
        \\
    );
    try expectText(.{ .upstreams = [_]Host{ .{ .host = "a.example.org", .weight = 1 }, .{ .host = "b.example.org", .weight = 3 } } },
        \\upstreams = [
        \\  {
        \\    host = a.example.org
        \\    weight = 1
        \\  }
        \\  {
        \\    host = b.example.org
        \\    weight = 3
        \\  }
        \\]
        \\
    );
    try expectText(.{ .cache = @as(Storage, .memory), .store = Storage{ .disk = .{ .path = "/var/lib/wombat" } } },
        \\cache {
        \\  memory {}
        \\}
        \\store {
        \\  disk {
        \\    path = "/var/lib/wombat"
        \\  }
        \\}
        \\
    );
    // A pointer is what it points to; a union at the top is a document of one key.
    const host: Host = .{ .host = "sleepy-owl", .weight = 2 };
    try expectText(&host, "host = sleepy-owl\nweight = 2\n");
    try expectText(@as(Storage, .memory), "memory {}\n");
    // A list at the top is a document too (#6); java ⚠️ has no list root.
    try expectText(@as([]const u16, &.{ 4, 8 }), "[4, 8]\n");
    // A number, a string or an optional at the top is no document: a compile
    // error, as a tuple is. No test can show one.
}

// java ✓ · pyhocon ✓ · spec ✓ — a string is bare only when it is a plain word
// that cannot read as anything else; everything else is a JSON string, which a
// quoted HOCON string is. Each row reads back to the same string, and the
// oracles read the quoted ones as strings, not numbers or booleans. pyhocon ⚠️
// on the rows with non-ASCII text, which its oracle reads as Latin-1, and on
// `\u0007`, which it keeps as the six characters.
test "stringify.strings are quoted where they have to be" {
    const rows = [_]struct { []const u8, []const u8 }{
        .{ "wombat", "wombat" },
        .{ "grumpy-wombat.pem", "grumpy-wombat.pem" },
        .{ "snake_case", "snake_case" },
        .{ "", "\"\"" },
        .{ "the dog ate my homework", "\"the dog ate my homework\"" },
        .{ "key: value", "\"key: value\"" },
        .{ "${HOME}/bin", "\"${HOME}/bin\"" },
        .{ "http://example.org", "\"http://example.org\"" },
        .{ "tea // biscuits", "\"tea // biscuits\"" },
        .{ "no\u{a0}break", "\"no\u{a0}break\"" },
        .{ "\u{2003}", "\"\u{2003}\"" },
        .{ "café", "\"café\"" },
        .{ "true", "\"true\"" },
        .{ "null", "\"null\"" },
        .{ "include", "\"include\"" },
        .{ "80", "\"80\"" },
        .{ "-5", "\"-5\"" },
        .{ "_private", "\"_private\"" },
        .{ "/usr/bin", "\"/usr/bin\"" },
        .{ "say \"hi\"", "\"say \\\"hi\\\"\"" },
        .{ "back\\slash", "\"back\\\\slash\"" },
        .{ "C:\\", "\"C:\\\\\"" },
        .{ "line one\nline two\ttab", "\"line one\\nline two\\ttab\"" },
        .{ "bell\x07", "\"bell\\u0007\"" },
        // a surrogate on its own, as a quoted `"\ud83d"` is read (see `unqoute`)
        .{ "lone \xed\xa0\xbd", "\"lone \\ud83d\"" },
    };
    for (rows) |row| {
        const in, const want = row;
        errdefer std.debug.print("failed on \"{s}\"\n", .{in});
        const T = struct { a: []const u8 };
        const line = try std.fmt.allocPrint(testing.allocator, "a = {s}\n", .{want});
        defer testing.allocator.free(line);
        try expectText(T{ .a = in }, line);
        try expectRoundTrip(T{ .a = in });
    }
}

// java ✓ · pyhocon ⚠️ · spec ✓ — a key is one path element: a dot in it would
// split it, so `"a.b"` is quoted, and so is `include`, which would start an
// include. pyhocon reads 🦆 as Latin-1, the rest as java does.
test "stringify.keys are quoted where they have to be" {
    const T = struct {
        plain: u8 = 1,
        @"kebab-case": u8 = 2,
        @"a.b": u8 = 3,
        @"x y": u8 = 4,
        include: u8 = 6,
        true: u8 = 7,
        @"8": u8 = 8,
        @"🦆": u8 = 9,
    };
    try expectText(T{},
        \\plain = 1
        \\kebab-case = 2
        \\"a.b" = 3
        \\"x y" = 4
        \\"include" = 6
        \\"true" = 7
        \\"8" = 8
        \\"🦆" = 9
        \\
    );
    try expectRoundTrip(T{});
}

// java ✓ · pyhocon ✓ · spec ✓ — the shortest digits that read back as the
// same float, with an exponent only where plain digits would run long. The
// rest are no JSON number: strings, as std.json writes them.
test "stringify.floats" {
    const rows = [_]struct { f64, []const u8 }{
        .{ 1.5, "1.5" },
        .{ 2, "2" },
        .{ -0.0, "-0" },
        .{ 0.1, "0.1" },
        .{ 123456.789, "123456.789" },
        .{ 1e-7, "1e-7" },
        .{ 1e21, "1e21" },
        .{ 1e300, "1e300" },
        .{ 5e-324, "5e-324" },
        .{ std.math.inf(f64), "\"inf\"" },
        .{ -std.math.inf(f64), "\"-inf\"" },
        .{ std.math.nan(f64), "\"nan\"" },
    };
    for (rows) |row| {
        const x, const want = row;
        errdefer std.debug.print("failed on {d}\n", .{x});
        const line = try std.fmt.allocPrint(testing.allocator, "a = {s}\n", .{want});
        defer testing.allocator.free(line);
        try expectText(.{ .a = x }, line);
        if (!std.math.isNan(x)) try expectRoundTrip(struct { a: f64 }{ .a = x });
    }
    try expectText(.{ .a = @as(f32, 0.1), .b = 1.25 }, "a = 0.1\nb = 1.25\n");
}

// java ✓ · pyhocon ✓ · spec ✓ on the text — bytes that are not UTF-8 cannot
// be HOCON text (spec L117), so they are a list of numbers, as std.json writes
// them. A `[N]u8` reads them back; a `[]const u8` is a string and refuses a
// list (spec L1254, "convert.string refuses containers").
test "stringify.bytes that are not UTF-8 are a list of numbers" {
    const ip: struct { b: [4]u8 } = .{ .b = .{ 192, 168, 0, 1 } };
    try expectText(ip, "b = [192, 168, 0, 1]\n");
    try expectRoundTrip(ip);
    try expectText(.{ .a = @as([]const u8, "a\x80b") }, "a = [97, 128, 98]\n");
}

// Zig only — a null optional is left out, since a missing field reads back as
// null; unless its default is not null, then it says so. In a list it cannot
// be left out. java ✓ · pyhocon ✓ · spec ✓ on the text itself.
test "stringify.null optionals" {
    const T = struct { gone: ?u8 = null, required: ?u8, kept: ?u8 = 5, list: []const ?u8 = &.{ 1, null } };
    try expectText(T{ .kept = null, .required = null }, "kept = null\nlist = [1, null]\n");
    try expectRoundTrip(T{ .kept = null, .required = null });
    try expectRoundTrip(T{ .gone = 1, .required = 2, .kept = 3 });
}

// java ✓ · pyhocon – · spec ✓ — a duration, a period and a size are one value
// in the units format, the largest unit that says it exactly; java's
// getDuration, getPeriod and getBytes read this text to the same values.
// pyhocon has none of the three getters.
test "stringify.durations, periods and sizes" {
    const T = struct {
        timeout: units.Duration = .of(90, .s),
        idle: units.Duration = .of(120, .min),
        retention: units.Period = .of(3, .mo),
        audit: units.Period = .of(2, .weeks),
        cache: units.Size = .of(512, .MiB),
        disk: units.Size = .of(10, .kB),
        backoff: []const units.Duration = &.{ .of(1500, .ms), .of(1, .ns) },
        grace: ?units.Duration = null,
    };
    try expectText(T{},
        \\timeout = 90s
        \\idle = 2h
        \\retention = 3mo
        \\audit = 2w
        \\cache = 512MiB
        \\disk = 10kB
        \\backoff = [1500ms, 1ns]
        \\
    );
    try expectRoundTrip(T{});
    // Every value a config can say comes back as it was. A period built with
    // years and months both is not one: `14mo` reads back as 14 months.
    try expectRoundTrip(T{
        .timeout = .{ .nanoseconds = -1 },
        .idle = .{ .nanoseconds = std.math.maxInt(i96) },
        .retention = .of(-7, .y),
        .audit = .of(-1, .d),
        .cache = .{ .bytes = std.math.maxInt(u64) },
        .disk = .of(5, .EiB),
        .grace = .of(0, .s),
    });
}

// java ✓ · pyhocon ✓ · spec ✓ (the text; the types are Zig's) — every type the
// conversion reads, written and read back to the same value.
test "stringify.every supported type reads back as it was" {
    const Storage = union(enum) { memory, disk: struct { path: []const u8, size_mb: u32 } };
    const T = struct {
        name: []const u8 = "the dog ate my homework",
        enabled: bool = true,
        port: u16 = 8080,
        offset: i64 = -42,
        ratio: f64 = 0.25,
        tiny: f32 = 1e-9,
        level: enum { debug, info, @"very loud" } = .@"very loud",
        lucky: *const u8 = &7,
        // A value with no name in a non-exhaustive enum is its number.
        mood: enum(u8) { calm, _ } = @enumFromInt(200),
        nickname: ?[]const u8 = null,
        retries: ?u8 = 3,
        timeout: ?u32 = null,
        tags: []const []const u8 = &.{ "tea", "cake", "" },
        grid: []const []const i32 = &.{ &.{ 1, 2 }, &.{} },
        origin: [2]i32 = .{ -1, 1 },
        code: [4]u8 = "WMBT".*,
        storage: Storage = .{ .disk = .{ .path = "/var/lib/wombat", .size_mb = 512 } },
        cache: Storage = .memory,
        upstreams: []const struct { host: []const u8, weight: u8 } = &.{ .{ .host = "a.example.org", .weight = 1 }, .{ .host = "b.example.org", .weight = 3 } },
        tls: struct { cert: []const u8 = "grumpy-wombat.pem", key: ?[]const u8 = null } = .{},
    };
    try expectRoundTrip(T{});
    try expectRoundTrip(T{ .nickname = "sleepy owl", .retries = null, .timeout = 30, .cache = .{ .disk = .{ .path = "x", .size_mb = 1 } }, .tls = .{ .key = "k" } });
}

// ---------------------------------------------------------------------------
// A `Value` as loaded, before resolving: the refs, the concatenations around
// them and the repeated keys are written out as such. Each row is loaded,
// written, loaded again from what was written, and the two trees compared —
// a row fails when they differ, whatever the text.
// ---------------------------------------------------------------------------

/// The document loaded but not resolved, as `Value.fromNode` leaves it.
fn load(gpa: std.mem.Allocator, src: [:0]const u8) !Value {
    var parser = Ast.Parser{ .gpa = gpa, .t = .{ .t = Tokenizer.init(src) } };
    return Value.fromNode(gpa, try parser.parse(), .{});
}

fn dumpLoaded(gpa: std.mem.Allocator, src: [:0]const u8) anyerror![]u8 {
    const tree = try load(gpa, src);
    const text = try stringifyAlloc(gpa, tree, .{});
    const again = try load(gpa, try gpa.dupeZ(u8, text));
    if (!sameTree(tree, again)) return std.fmt.allocPrint(gpa, "{s}(reads back as another tree)", .{text});
    return text;
}

fn expectAllLoaded(cases: []const table.Case) !void {
    return table.expectAll(cases, .{ .dump = dumpLoaded });
}

/// The same tree, positions aside: a ref written elsewhere is the same ref.
fn sameTree(a: Value, b: Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    switch (a) {
        .scalar => |s| return s.quoted == b.scalar.quoted and std.mem.eql(u8, s.value, b.scalar.value),
        .array, .stack => |items| {
            const other = if (a == .array) b.array else b.stack;
            if (items.len != other.len) return false;
            for (items, other) |x, y| if (!sameTree(x, y)) return false;
            return true;
        },
        .object => |members| {
            if (members.len != b.object.len) return false;
            for (members, b.object) |x, y| {
                if (!x.key.eql(y.key) or !sameTree(x.value, y.value)) return false;
            }
            return true;
        },
        .ref => |r| {
            if (r.flags != b.ref.flags or r.scope_len != b.ref.scope_len or r.path.len != b.ref.path.len) return false;
            for (r.path, b.ref.path) |x, y| if (!x.eql(y)) return false;
            return true;
        },
        .pending => |parts| {
            if (parts.len != b.pending.len) return false;
            for (parts, b.pending) |x, y| if (!sameTree(x.value, y.value)) return false;
            return true;
        },
    }
}

// java ✓ · pyhocon – · spec ✓ — a ref is written as its whole path, each
// element quoted as a key would be. java renders each source and its output to
// the same unresolved JSON; pyhocon cannot print an unresolved substitution.
test "stringify.a ref is written as its path" {
    try expectAllLoaded(&.{
        .ok("a = ${x}", "a = ${x}\n"),
        .ok("a = ${?x}", "a = ${?x}\n"),
        .ok("a = ${o.p.q}", "a = ${o.p.q}\n"),
        .ok("a = ${\"b.c\".d}", "a = ${\"b.c\".d}\n"),
        .ok("a = ${\"x y\"}", "a = ${\"x y\"}\n"),
        .ok("a = ${b.\"\".c}", "a = ${b.\"\".c}\n"),
        .ok("a = ${o.\"🦆\"}", "a = ${o.\"🦆\"}\n"),
        .ok("a = ${include}", "a = ${\"include\"}\n"),
        .ok("a = [${x}, 1]", "a = [${x}, 1]\n"),
        .ok("a { b = ${?x} }", "a {\n  b = ${?x}\n}\n"),
        // A list from the environment (#11) keeps its `[]`.
        .ok("a = ${PATHS[]}", "a = ${PATHS[]}\n"),
        .ok("a = ${?PATHS []}", "a = ${?PATHS[]}\n"),
    });
}

// java ✓ · pyhocon – · spec ✓ — a concatenation with a ref in it is its parts
// side by side: a quoted part stays quoted, a gap between two refs is written
// as the whitespace it is, and one next to a list or an object is gone already.
test "stringify.a concatenation is written part by part" {
    try expectAllLoaded(&.{
        .ok("path = ${HOME}\"/bin\"", "path = ${HOME}\"/bin\"\n"),
        .ok("a = ${x} tea", "a = ${x}\" tea\"\n"),
        .ok("a = tea${x}", "a = tea${x}\n"),
        .ok("a = ${x} ${y}", "a = ${x} ${y}\n"),
        .ok("a = ${x}\u{a0}${y}", "a = ${x}\u{a0}${y}\n"),
        .ok("a = ${?x}42", "a = ${?x}42\n"),
        .ok("a = ${?a} [1]", "a = ${?a}[1]\n"),
        .ok("a = [1] ${x} [2]", "a = [1]${x}[2]\n"),
        .ok("a = ${x} { b = 1 }", "a = ${x}{\n  b = 1\n}\n"),
        .ok("l = [ ${x} [1], 2 ]", "l = [\n  ${x}[1]\n  2\n]\n"),
    });
}

// include-semantics-substitution · spec ✓ · java ✓ on every compacted file;
// on the originals java ⚠️ does not fall back to the path as written
// (lightbend/config#863, suite 009 and 011): it fails rows 1 and 9 without
// the variables, leaves `a` out of row 2 without `nope`, and its `+=` adds to
// nothing in rows 6, 8 and 14 · pyhocon ⚠️ tries the path as written first in
// rows 1–4 and gets the self-references of rows 8–14 wrong.
// A ref from `inner.conf`, included under `common`, kept by `.keep` with its
// fallback is written as two fields: the path as written below, the scoped one
// over it. One whose scoped target cannot vanish is the scoped path alone, so
// the `{ k = 1 }` there never merges with the root's `{ m = 2 }`, and one found
// only at the root is the path as written alone. A self-reference is the layers
// below it, over the path as written, a `+=` too. Each compacted file reads
// back as the original does with none of the variables and with those `some`
// sets. Row 10 is a known loss: it reads a variable `a` the original never
// does, and differs once one is set.
test "stringify.a kept ref from an include inside a block keeps its fallback" {
    const rows = [_]struct { inner: []const u8, root: []const u8, want: []const u8 }{
        // The scoped `x.y` waits for an optional: without it, the root's `x.y`.
        .{ .inner = "x.y = ${?nope}\na = ${x.y}", .root = "x.y = 0", .want = "common {\n  x {\n    y = ${?nope}\n  }\n  a = ${x.y}\n  a = ${?common.x.y}\n}\nx {\n  y = 0\n}\n" },
        .{ .inner = "x.y = ${?nope}\na = ${?x.y}", .root = "x.y = 0", .want = "common {\n  x {\n    y = ${?nope}\n  }\n  a = ${?x.y}\n  a = ${?common.x.y}\n}\nx {\n  y = 0\n}\n" },
        // The path runs through a value that waits: `x.y` in text is no path.
        .{ .inner = "x = ${?FOO}\na = ${x.y}", .root = "x.y = 1", .want = "common {\n  x = ${?FOO}\n  a = ${x.y}\n  a = ${?common.x.y}\n}\nx {\n  y = 1\n}\n" },
        // Never nothing: an object under the variable, a required variable.
        .{ .inner = "x = { k = 1 }\nx = ${?FOO}\na = ${x}", .root = "x = { m = 2 }", .want = "common {\n  x {\n    k = 1\n  }\n  x = ${?FOO}\n  a = ${common.x}\n}\nx {\n  m = 2\n}\n" },
        .{ .inner = "x = ${FOO}\na = ${x}", .root = "x = 2", .want = "common {\n  x = ${FOO}\n  a = ${common.x}\n}\nx = 2\n" },
        // `+=` finds nothing at `common.a` and adds to the root's `a`: no `+=`
        // in the block says that.
        .{ .inner = "a += x", .root = "a = ${?L[]}", .want = "common {\n  a = ${?a}[x]\n}\na = ${?L[]}\n" },
        // Found only at the root: the path as written, whatever waits there.
        .{ .inner = "url = ${host}", .root = "host = ${HOST}", .want = "common {\n  url = ${host}\n}\nhost = ${HOST}\n" },
        .{ .inner = "a += 1", .root = "a = ${?L[]}\na += 0", .want = "common {\n  a = ${?a}[1]\n}\na = ${?L[]}\na += 0\n" },
        // A self-reference finds the layers below it, and only when they
        // find nothing the path as written: that goes under them. Not in the
        // document, the self-reference is gone, never a variable.
        .{ .inner = "a = ${?FOO}\na = ${a}", .root = "a = 7", .want = "common {\n  a = ${a}\n  a = ${?FOO}\n}\na = 7\n" },
        .{ .inner = "a = ${?nope}\na = ${?a}", .root = "a = ${?FOO}", .want = "common {\n  a = ${?a}\n  a = ${?nope}\n}\na = ${?FOO}\n" },
        .{ .inner = "path = ${?EXTRA}\npath = ${path}", .root = "", .want = "common {\n  path = ${?EXTRA}\n  path = ${common.path}\n}\n" },
        .{ .inner = "J = ${?E}\nJ = ${?J}", .root = "", .want = "common {\n  J = ${?E}\n  J = ${?common.J}\n}\n" },
        // The root's `a` reads `common.a` back: the fallback under the
        // layers is not followed while compacting, so no cycle.
        .{ .inner = "a = ${?FOO}\na = ${a}", .root = "a = ${?common.a}", .want = "common {\n  a = ${a}\n  a = ${?FOO}\n}\na = ${?common.a}\n" },
        // A `+=` is a self-reference too.
        .{ .inner = "a = ${?L[]}\na += 1", .root = "a = [0]", .want = "common {\n  a = ${?a}\n  a = ${?L[]}\n  a += 1\n}\na = [0]\n" },
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var none: std.process.Environ.Map = .init(gpa);
    var some: std.process.Environ.Map = .init(gpa);
    try some.put("nope", "the wombat sleeps");
    try some.put("FOO", "grumpy");
    try some.put("L_0", "sleepy");
    try some.put("HOST", "burrow.example");
    try some.put("EXTRA", "/opt/burrow");
    try some.put("J", "seven sleepy jays");

    for (rows) |row| {
        errdefer std.debug.print("failed on \"{s}\"\n", .{row.inner});
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "inner.conf", .data = row.inner });
        const root = try std.fmt.allocPrint(gpa, "common {{ include \"inner.conf\" }}\n{s}\n", .{row.root});
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "main.conf", .data = root });
        const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/main.conf", .{tmp.sub_path});

        const kept = try Config.parseFromFileLeaky(Value, gpa, testing.io, path, .{ .env = .keep });
        const text = try stringifyAlloc(gpa, kept, .{});
        try testing.expectEqualStrings(row.want, text);
        for ([_]*const std.process.Environ.Map{ &none, &some }) |env| {
            const now = Config.parseFromFileLeaky(Value, gpa, testing.io, path, .{ .env = .{ .map = env } });
            const later = Config.parseFromSliceLeaky(Value, gpa, try gpa.dupeZ(u8, text), .{ .env = .{ .map = env } });
            if (now) |want| {
                const got = try later;
                try testing.expectEqualStrings(try std.json.Stringify.valueAlloc(gpa, want, .{}), try std.json.Stringify.valueAlloc(gpa, got, .{}));
            } else |err| try testing.expectError(err, later);
        }
    }
}

// java ✓ · pyhocon ⚠️ · spec ✓ — `a += b` is loaded as `a = ${?a} [b]`, the
// ref holding the field's whole path, and written back as `a += b`. Written
// out by hand, `${?a} [b]` is the same, but stays as it was. java resolves
// each source and its output to the same list; pyhocon gets `+=` wrong
// (" crisps", or 2).
test "stringify.+= is written as +=" {
    try expectAllLoaded(&.{
        .ok("snacks += crisps", "snacks += crisps\n"),
        .ok("o.p { a = [1]\n  a += 2 }", "o {\n  p {\n    a = [1]\n    a += 2\n  }\n}\n"),
        .ok("a += [1, 2]\nb += { c = 1 }\nd += ${x}\" tea\"", "a += [1, 2]\nb += {\n  c = 1\n}\nd += ${x}\" tea\"\n"),
        .ok("snacks = ${?snacks} [crisps]", "snacks = ${?snacks}[crisps]\n"),
    });
}

// java ✓ · pyhocon ⚠️ · spec ✓ — a key whose later value is a ref or a pending
// is a stack (#7), and it is written as the key written again for each layer,
// bottom first: loading it stacks the layers up in the same order. Two objects
// next to each other were merged when it was loaded, so none are left to merge;
// java ≈ keeps them as two layers in its unresolved form, the same once
// resolved. pyhocon fails on the `+=` row.
test "stringify.a stack is the key written again" {
    try expectAllLoaded(&.{
        .ok("a = [1]\na = ${x}\na = { b = 1 }", "a = [1]\na = ${x}\na {\n  b = 1\n}\n"),
        .ok("snacks = [cake]\nsnacks += crisps\nsnacks += pie", "snacks = [cake]\nsnacks += crisps\nsnacks += pie\n"),
        .ok("mood = grumpy\nmood = ${mood}\" wombat\"", "mood = grumpy\nmood = ${mood}\" wombat\"\n"),
        .ok("a { b = 1, b = ${x} }", "a {\n  b = 1\n  b = ${x}\n}\n"),
        .ok("a = ${x}\na = { b = 1 }\na { c = 2 }", "a = ${x}\na {\n  b = 1\n  c = 2\n}\n"),
    });
}

// java ✓ · pyhocon ⚠️ · spec ✓ — resolved or not, a scalar of a `Value` is
// written as it was loaded: unquoted text as it is, so `1.50` stays a number
// written that way, quoted text quoted. A `"""` string becomes an ordinary
// quoted one; the text inside is the same. pyhocon rejects `1e+5 x` and
// `[1e+5 b]`: it takes a `+` only in a number standing alone.
test "stringify.a loaded scalar keeps how it was written" {
    try expectAllLoaded(&.{
        .ok("a = the dog ate my homework", "a = the dog ate my homework\n"),
        .ok("a = 1.50\nb = \"80\"\nc = null\nd = \"true\"", "a = 1.50\nb = \"80\"\nc = null\nd = \"true\"\n"),
        .ok("a = \"\"\"triple \"quoted\" text\n\"\"\"", "a = \"triple \\\"quoted\\\" text\\n\"\n"),
        .ok("a = grumpy \"wombat\"", "a = \"grumpy wombat\"\n"),
        .ok("\"a.b\" = 1\n\"\" = 2\n\"include\" = 3", "\"a.b\" = 1\n\"\" = 2\n\"include\" = 3\n"),
        .ok("a {}\nb = []\nc = [{ d = 1 }, { e = 2 }]", "a {}\nb = []\nc = [\n  {\n    d = 1\n  }\n  {\n    e = 2\n  }\n]\n"),
        .ok("a = 1e+5\nb = [-1.5E+3]", "a = 1e+5\nb = [-1.5E+3]\n"),
        .ok("a = 1e+5 x\nb = [1e+5 b]\nc = x 1e+5", "a = 1e+5 x\nb = [1e+5 b]\nc = x 1e+5\n"),
        .ok("\"\\ud83d\" = \"half a \\ud83d\"", "\"\\ud83d\" = \"half a \\ud83d\"\n"),
        .ok("[1, 2]", "[1, 2]\n"),
        .ok("", ""),
    });
}

// java ✓ · pyhocon ⚠️ · spec ✓ — unquoted text of a `Value` built by hand goes
// out bare only when it reads back as the same text; otherwise it is quoted.
// Whitespace at either end would be trimmed, a word that starts like a number
// has to be one, and a `+` belongs only to an exponent. Both oracles read every
// output as the text it came from but `tea 1e+5`, which pyhocon reads as
// `tea 100000.0`; they would take `-a` and `01` bare too, which the spec does not.
test "stringify.unquoted text built by hand reads back" {
    const rows = [_]struct { []const u8, []const u8 }{
        .{ "the wombat sleeps", "the wombat sleeps" },
        .{ "%x", "%x" },
        .{ "1e+5", "1e+5" },
        .{ "tea 1e+5", "tea 1e+5" },
        .{ "1e+5 e+5", "\"1e+5 e+5\"" },
        .{ "5EB", "5EB" },
        .{ " the wombat sleeps ", "\" the wombat sleeps \"" },
        .{ "tea\u{a0}", "\"tea\u{a0}\"" },
        .{ " ", "\" \"" },
        .{ "-a", "\"-a\"" },
        .{ "tea -a", "\"tea -a\"" },
        .{ "01", "\"01\"" },
        .{ "a+b", "\"a+b\"" },
        .{ "a // b", "\"a // b\"" },
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    for (rows) |row| {
        const in, const want = row;
        errdefer std.debug.print("failed on \"{s}\"\n", .{in});
        const member: Member = .{ .key = .{ .value = "k" }, .value = .{ .scalar = .{ .value = in, .quoted = false } } };
        const value: Value = .{ .object = try gpa.dupe(Member, &.{member}) };
        const text = try stringifyAlloc(gpa, value, .{});
        try testing.expectEqualStrings(try std.fmt.allocPrint(gpa, "k = {s}\n", .{want}), text);
        const back = try load(gpa, try gpa.dupeZ(u8, text));
        try testing.expectEqualStrings(in, back.object[0].value.scalar.value);
    }
}
