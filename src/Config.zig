const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Value = @import("Value.zig").Value;
const Ast = @import("Ast.zig");
const Tokenizer = @import("Tokenizer.zig").Tokenizer;

pub const Config = struct {
    object: Value,

    /// Leaky: everything (Ast, Value, T) lands in `allocator` and nothing is
    /// freed here. Pass an arena and drop it as a whole.
    ///
    /// `[:0]const u8` because the tokenizer wants a 0-terminated input; string
    /// literals coerce to it for free.
    pub fn parseFromSliceLeaky(comptime T: type, allocator: Allocator, file_content: [:0]const u8) !T {
        // `parse` is a method, so the parser has to exist first.
        var parser = Ast.Parser{ .gpa = allocator, .t = .{ .t = Tokenizer.init(file_content) } };
        const ast = try parser.parse();
        const obj = try Value.fromNode(allocator, ast);

        // Resolve: not yet, `.ref` and `.pending` end in error.Unresolved below.
        return parseFromValue(T, allocator, obj);
    }

    pub const ConvertError = error{ TypeMismatch, MissingField, Unresolved, UnsupportedType, OutOfMemory } ||
        std.fmt.ParseIntError;

    /// Converts a Value into T. `T` is comptime, so the compiler builds one copy
    /// of this function per target type, and the `switch` below is decided at
    /// compile time: for `usize` only the `.int` branch exists at all.
    pub fn parseFromValue(comptime T: type, allocator: Allocator, value: Value) ConvertError!T {
        // Not resolved yet: refuse loudly instead of guessing.
        if (value == .ref or value == .pending) return error.Unresolved;
        switch (@typeInfo(T)) {
            .int => {
                if (value != .scalar) return error.TypeMismatch;
                if (std.mem.eql(u8, value.scalar.value, "null") and !value.scalar.quoted) return error.TypeMismatch;
                return std.fmt.parseInt(T, value.scalar.value, 10);
            },
            .bool => {
                if (value != .scalar) return error.TypeMismatch;
                for ([_][]const u8{ "true", "on", "yes" }) |word| {
                    if (std.mem.eql(u8, value.scalar.value, word)) return true;
                }
                for ([_][]const u8{ "false", "no", "off" }) |word| {
                    if (std.mem.eql(u8, value.scalar.value, word)) return false;
                }
                return error.TypeMismatch;
            },
            .float => {
                if (value != .scalar) return error.TypeMismatch;
                if (std.mem.eql(u8, value.scalar.value, "null") and !value.scalar.quoted) return error.TypeMismatch;
                return std.fmt.parseFloat(T, value.scalar.value);
            },
            .pointer => |info| {
                switch (value) {
                    .scalar => {
                        if (info.child != u8) return error.TypeMismatch;
                        if (std.mem.eql(u8, value.scalar.value, "null") and !value.scalar.quoted) return error.TypeMismatch;
                        return try allocator.dupe(u8, value.scalar.value);
                    },
                    .array => {
                        if (info.child == u8) return error.TypeMismatch;
                        var a: std.ArrayList(info.child) = .empty;
                        for (value.array) |item| {
                            const val = try parseFromValue(info.child, allocator, item);
                            try a.append(allocator, val);
                        }
                        return try a.toOwnedSlice(allocator);
                    },
                    else => return error.TypeMismatch,
                }
            },
            .@"struct" => |info| {
                if (value != .object) return error.TypeMismatch;

                // `undefined` is fine: the loop sets every field or returns an error.
                var result: T = undefined;

                // `inline for`: each field has a different `field.type`, and that is a
                // comptime value. The loop is unrolled, one body per field.
                inline for (info.fields) |field| {
                    const member = for (value.object) |m| {
                        if (std.mem.eql(u8, m.key.value, field.name)) break m;
                    } else return error.MissingField;

                    // `@field(result, "a")` is `result.a`, with the name known at comptime.
                    @field(result, field.name) = try parseFromValue(field.type, allocator, member.value);
                }
                return result;
            },
            // A compile error, not a runtime one: asking for `f64` fails the build
            // and points at the type, until a branch for it exists.
            else => @compileError("hocon: unsupported target type " ++ @typeName(T)),
        }
    }
};

test "basic deserialization" {
    const target_s1 = struct { a: usize, b: usize };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const config = try Config.parseFromSliceLeaky(target_s1, gpa, "{a=5, b: 6}");
    try testing.expectEqual(5, config.a);
}

// Conversion tests: "automatic type conversions" (spec L1230, items S17.x) and the
// typed half of numerically-indexed objects (S15.x). The conformance suite leaves
// these out on purpose — it compares parse output as JSON and never calls a typed
// getter (conformance/maintaining/SECTIONS.md) — so this is where they live.
// Item ids are from conformance/maintaining/spec-items.md.
//
// The ones for target types `parseFromValue` does not handle yet open with
// `if (true) return error.SkipZigTest;` — delete that line when the branch exists.
// Without it the file would not compile at all: an unsupported type is a
// `@compileError`, and that fails the build, not just the test.

fn expectConverts(comptime T: type, src: [:0]const u8, expected: T) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try Config.parseFromSliceLeaky(T, arena.allocator(), src);
    try testing.expectEqualDeep(expected, got);
}

fn expectConvertError(comptime T: type, src: [:0]const u8, expected: anyerror) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(expected, Config.parseFromSliceLeaky(T, arena.allocator(), src));
}

// S17.3 · java ✓ · pyhocon ✓ · spec ✓ — a number is text until something asks for
// a number, so a quoted "5" converts just like 5.
test "convert.int" {
    try expectConverts(struct { a: usize }, "a = 5", .{ .a = 5 });
    try expectConverts(struct { a: i64 }, "a = -3", .{ .a = -3 });
    try expectConverts(struct { a: usize }, "a = \"5\"", .{ .a = 5 });
    try expectConvertError(struct { a: usize }, "a = abc", error.InvalidCharacter);
}

// S17.3 · java ✓ · pyhocon ✓ · spec ✓ — text that only starts like a number is not
// one. FINDINGS.md (unquoted-strings) has java *parsing* `-foo` and `1.2.3` as
// strings against the spec; asked for a number, all three agree it is an error.
test "convert.int refuses a string that merely starts like a number" {
    try expectConvertError(struct { a: usize }, "a = 1.2.3", error.InvalidCharacter);
    try expectConvertError(struct { a: i64 }, "a = -foo", error.InvalidCharacter);
}

// S17.3 · java ⚠️ · pyhocon ⚠️ · spec – — both truncate 1.5 to 1 without a word.
// Here it is an error on purpose: a fraction where a whole number belongs is a
// typo, and dropping it silently is how `timeout = 0.5` becomes 0.
test "convert.int refuses a fraction" {
    try expectConvertError(struct { a: usize }, "a = 1.5", error.InvalidCharacter);
}

// Zig only — java has no u8. The target type sets the range, not the text.
test "convert.int out of range for the field" {
    try expectConvertError(struct { a: u8 }, "a = 300", error.Overflow);
    try expectConvertError(struct { a: usize }, "a = -1", error.Overflow);
}

// java ✓ · pyhocon ✓ · spec ✓ — nesting in the struct follows nesting in the file,
// and it does not matter how the object got there: braces, a braced root (S3), or
// two blocks merged by key (S7).
test "convert.struct" {
    const T = struct { a: struct { b: usize, c: usize } };
    try expectConverts(T, "a { b = 1, c = 2 }", .{ .a = .{ .b = 1, .c = 2 } });
    try expectConverts(T, "{ a { b = 1, c = 2 } }", .{ .a = .{ .b = 1, .c = 2 } });
    try expectConverts(T, "a { b = 1 }\na { c = 2 }", .{ .a = .{ .b = 1, .c = 2 } });
}

// java ✓ · pyhocon ✓ · spec ✓ — the later value wins.
test "convert.struct takes the last of a repeated key" {
    try expectConverts(struct { a: usize }, "a = 1\na = 2", .{ .a = 2 });
}

// java ✓ · pyhocon ✓ · spec – — a getter reads its own path and nothing else, so
// keys the struct does not mention are fine. A real config carries more than any
// one consumer needs.
test "convert.struct ignores keys it has no field for" {
    try expectConverts(struct { a: usize }, "a = 1\nb = 2\nc { d = 3 }", .{ .a = 1 });
}

// S17.7 · java ✓ · pyhocon ✓ · spec ✓ — no object to anything, no anything to object.
test "convert.struct errors" {
    try expectConvertError(struct { a: usize }, "b = 1", error.MissingField);
    try expectConvertError(struct { a: usize }, "a { b = 1 }", error.TypeMismatch);
    try expectConvertError(struct { a: struct { b: usize } }, "a = 1", error.TypeMismatch);
}

// Resolve does not exist yet, so a substitution must not pass as a value.
test "convert.an unresolved substitution is an error" {
    try expectConvertError(struct { a: usize }, "a = ${b}", error.Unresolved);
}

// S11 · java ✓ · pyhocon ✓ · spec ✓ — `a.b = 1` is `a { b = 1 }`.
test "convert.struct from a dotted key" {
    try expectConverts(struct { a: struct { b: usize } }, "a.b = 1", .{ .a = .{ .b = 1 } });
}

// S17.4 · java ✓ · pyhocon ⚠️ · spec ✓ — true/yes/on and false/no/off, lowercase
// only; the spec asks to stick to these six. pyhocon also takes TRUE.
test "convert.bool" {
    const T = struct { a: bool };
    try expectConverts(T, "a = true", .{ .a = true });
    try expectConverts(T, "a = \"true\"", .{ .a = true });
    try expectConverts(T, "a = yes", .{ .a = true });
    try expectConverts(T, "a = on", .{ .a = true });
    try expectConverts(T, "a = false", .{ .a = false });
    try expectConverts(T, "a = no", .{ .a = false });
    try expectConverts(T, "a = off", .{ .a = false });
    try expectConverts(T, "a = \"true\"", .{ .a = true });
    try expectConvertError(T, "a = TRUE", error.TypeMismatch);
    try expectConvertError(T, "a = 1", error.TypeMismatch);
}

// S17.3 · java ✓ · pyhocon ✓ · spec ✓
test "convert.float" {
    try expectConverts(struct { a: f64 }, "a = 1.5", .{ .a = 1.5 });
    try expectConverts(struct { a: f64 }, "a = 2", .{ .a = 2 });
    try expectConverts(struct { a: f64 }, "a = 1e5", .{ .a = 100000 });
}

// S17.1 S17.2 S10.11 · java ✓ · pyhocon ⚠️ · spec ✓ — any scalar reads as a string,
// and a number reads *as written*: `1.50` stays "1.50", `1e5` stays "1e5".
// pyhocon renormalises to "1.5" and "100000.0" — a config that round-trips through
// pyhocon today can change text here, worth knowing for the bridge.
test "convert.string" {
    const T = struct { a: []const u8 };
    try expectConverts(T, "a = kafe dochazi v pondeli rano", .{ .a = "kafe dochazi v pondeli rano" });
    try expectConverts(T, "a = \"kafe dochazi v pondeli rano\"", .{ .a = "kafe dochazi v pondeli rano" });
    try expectConverts(T, "a = 5", .{ .a = "5" });
    try expectConverts(T, "a = 1.50", .{ .a = "1.50" });
    try expectConverts(T, "a = 1e5", .{ .a = "1e5" });
    try expectConverts(T, "a = true", .{ .a = "true" });
}

// S17.7 S17.8 · java ✓ · pyhocon ⚠️ · spec ✓ — objects and arrays never become
// strings. pyhocon returns "[1]" for the array.
test "convert.string refuses containers" {
    const T = struct { a: []const u8 };
    try expectConvertError(T, "a { b = 1 }", error.TypeMismatch);
    try expectConvertError(T, "a = [1]", error.TypeMismatch);
}

// Zig only — the result must not borrow from `source`. Scalars in Value point
// into the input (utils/unqoute.zig: unquoted and triple-quoted text arrive as
// written), so a string field that is not copied dangles once the caller frees
// the buffer the file was read into. The buffer is scribbled over before the
// check, so a borrowed slice shows up as "xxxx", not as a lucky pass.
test "convert.string outlives the source buffer" {
    const T = struct { a: []const u8, b: []const u8, c: []const u8 };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = try testing.allocator.dupeZ(u8,
        \\a = pes snedl domaci ukol
        \\b = "a pak i ucitelku"
        \\c = """a ted se tvari nevinne"""
    );
    const got = try Config.parseFromSliceLeaky(T, arena.allocator(), source);
    @memset(source, 'x');
    testing.allocator.free(source);

    try testing.expectEqualStrings("pes snedl domaci ukol", got.a);
    try testing.expectEqualStrings("a pak i ucitelku", got.b);
    try testing.expectEqualStrings("a ted se tvari nevinne", got.c);
}

// S17.6 S17.5 · java ✓ · pyhocon ⚠️ · spec ✓ — null into a plain type is an error;
// only an unquoted null is null, a quoted "null" is the four letters.
// pyhocon hands back None instead of failing.
test "convert.null is not a value of any plain type" {
    try expectConvertError(struct { a: usize }, "a = null", error.TypeMismatch);
    try expectConvertError(struct { a: bool }, "a = null", error.TypeMismatch);
    try expectConvertError(struct { a: []const u8 }, "a = null", error.TypeMismatch);
    try expectConverts(struct { a: []const u8 }, "a = \"null\"", .{ .a = "null" });
}

// S17.8 · java ✓ · pyhocon ✓ · spec ✓
test "convert.list" {
    const T = struct { a: []const usize };
    try expectConverts(T, "a = [1, 2, 3]", .{ .a = &.{ 1, 2, 3 } });
    try expectConverts(T, "a = []", .{ .a = &.{} });
    try expectConvertError(T, "a = 5", error.TypeMismatch);
}

// S15.1 S15.4-S15.7 · java ✓ · pyhocon ✓ · spec ✓ — an object with numeric keys
// becomes a list when a list is asked for: sorted by the number, gaps closed, other
// keys ignored, and an object with no numeric key at all (empty included) is not
// converted. The suite pins only the other half (S15.2: without a list asked for
// it stays an object), because JSON output cannot ask.
test "convert.list from a numerically-indexed object" {
    if (true) return error.SkipZigTest; // needs the S15 conversion in the slice branch
    const T = struct { a: []const usize };
    try expectConverts(T, "a { \"0\" = 1, \"1\" = 2 }", .{ .a = &.{ 1, 2 } });
    try expectConverts(T, "a { \"2\" = 20, \"0\" = 0 }", .{ .a = &.{ 0, 20 } });
    try expectConverts(T, "a { \"0\" = 1, x = 9 }", .{ .a = &.{1} });
    try expectConvertError(T, "a {}", error.TypeMismatch);
    try expectConvertError(T, "a { x = 1 }", error.TypeMismatch);
}

// Zig only: no field in java can be "absent" — a missing path is an error there,
// and `hasPath` is how you ask first. `?T` is that question folded into the type.
// S17.5 S22.3: an explicit null is null too, and it clears an earlier object.
test "convert.optional" {
    if (true) return error.SkipZigTest; // needs an `.optional` branch and a missing-key path
    const T = struct { a: ?usize };
    try expectConverts(T, "a = 5", .{ .a = 5 });
    try expectConverts(T, "b = 5", .{ .a = null });
    try expectConverts(T, "a = null", .{ .a = null });
    try expectConverts(struct { a: ?struct { b: usize } }, "a { b = 1 }\na = null", .{ .a = null });
}

// Zig only — a field default stands in for a missing key; a present key wins.
test "convert.default field value" {
    if (true) return error.SkipZigTest; // needs `field.defaultValue()` in the struct branch
    const T = struct { a: usize = 7 };
    try expectConverts(T, "b = 1", .{ .a = 7 });
    try expectConverts(T, "a = 1", .{ .a = 1 });
}

// java ✓ · pyhocon – · spec – — getEnum matches the constant name exactly, case
// included. pyhocon has no enums.
test "convert.enum" {
    if (true) return error.SkipZigTest; // needs an `.@"enum"` branch
    const Level = enum { debug, info };
    try expectConverts(struct { level: Level }, "level = debug", .{ .level = .debug });
    try expectConvertError(struct { level: Level }, "level = DEBUG", error.TypeMismatch);
}
