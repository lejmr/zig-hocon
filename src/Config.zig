const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Value = @import("Value.zig").Value;
const Ast = @import("Ast.zig");
const Tokenizer = @import("Tokenizer.zig").Tokenizer;

pub const Config = struct {
    object: Value,

    /// A parsed value together with the memory it lives in. `deinit` gives all
    /// of it back at once, so the caller never needs to know about the arena.
    pub fn Parsed(comptime T: type) type {
        return struct {
            /// Behind a pointer: `Parsed` is passed around by value, and every
            /// copy has to free the same arena, not a stale copy of its state.
            arena: *std.heap.ArenaAllocator,
            value: T,

            pub fn deinit(self: @This()) void {
                // Read before the arena goes: afterwards `self.arena` is gone too.
                const gpa = self.arena.child_allocator;
                self.arena.deinit();
                gpa.destroy(self.arena);
            }
        };
    }

    /// Like `parseFromSliceLeaky`, but any allocator will do: everything lands in
    /// an arena owned by the result, and `deinit` on the result frees it.
    pub fn parseFromSlice(comptime T: type, gpa: Allocator, source: [:0]const u8) !Parsed(T) {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(gpa);
        // Runs before the destroy above: `errdefer`s unwind in reverse order.
        errdefer arena.deinit();

        return .{
            .arena = arena,
            .value = try parseFromSliceLeaky(T, arena.allocator(), source),
        };
    }

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
        // The dynamic tree as it is, the way std.json.parseFromSlice(std.json.Value, …)
        // hands back its own — finished, so anything can print it.
        if (T == Value) return if (value.isResolved()) value else error.Unresolved;
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
                    // Going schema attribute one by one and looking for value from config file
                    const found = for (value.object) |m| {
                        if (std.mem.eql(u8, m.key.value, field.name)) break m;
                    } else null;

                    if (found) |member| {
                        // At some point field.type can be optional, but we have value, so jump to .optional
                        @field(result, field.name) = try parseFromValue(field.type, allocator, member.value);
                    } else if (field.defaultValue()) |default| {
                        @field(result, field.name) = default;
                    } else if (@typeInfo(field.type) == .optional) {
                        @field(result, field.name) = null;
                    } else {
                        return error.MissingField;
                    }
                }
                return result;
            },
            .@"enum" => {
                if (value != .scalar) return error.TypeMismatch;
                return std.meta.stringToEnum(T, value.scalar.value) orelse error.TypeMismatch;
            },
            .optional => |info| {
                if (value == .scalar and !value.scalar.quoted and std.mem.eql(u8, value.scalar.value, "null")) return null;
                return try parseFromValue(info.child, allocator, value);
            },
            // A compile error, not a runtime one: asking for `f64` fails the build
            // and points at the type, until a branch for it exists.
            else => @compileError("hocon: unsupported target type " ++ @typeName(T) ++ "(" ++ @tagName(@typeInfo(T)) ++ ")"),
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
// Rule ids are from conformance/maintaining/RULES.md.
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

// automatic-type-conversions L1238 · java ✓ · pyhocon ✓ · spec ✓ — a number is text until something asks for
// a number, so a quoted "5" converts just like 5.
test "convert.int" {
    try expectConverts(struct { a: usize }, "a = 5", .{ .a = 5 });
    try expectConverts(struct { a: i64 }, "a = -3", .{ .a = -3 });
    try expectConverts(struct { a: usize }, "a = \"5\"", .{ .a = 5 });
    try expectConvertError(struct { a: usize }, "a = abc", error.InvalidCharacter);
}

// automatic-type-conversions L1238 · java ✓ · pyhocon ✓ · spec ✓ — text that only starts like a number is not
// one. FINDINGS.md (unquoted-strings) has java *parsing* `-foo` and `1.2.3` as
// strings against the spec; asked for a number, all three agree it is an error.
test "convert.int refuses a string that merely starts like a number" {
    try expectConvertError(struct { a: usize }, "a = 1.2.3", error.InvalidCharacter);
    try expectConvertError(struct { a: i64 }, "a = -foo", error.InvalidCharacter);
}

// automatic-type-conversions L1238 · java ⚠️ · pyhocon ⚠️ · spec – — both truncate 1.5 to 1 without a word.
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

// automatic-type-conversions L1254 · java ✓ · pyhocon ✓ · spec ✓ — no object to anything, no anything to object.
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

// automatic-type-conversions L1239 · java ✓ · pyhocon ⚠️ · spec ✓ — true/yes/on and false/no/off, lowercase
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

// automatic-type-conversions L1238 · java ✓ · pyhocon ✓ · spec ✓
test "convert.float" {
    try expectConverts(struct { a: f64 }, "a = 1.5", .{ .a = 1.5 });
    try expectConverts(struct { a: f64 }, "a = 2", .{ .a = 2 });
    try expectConverts(struct { a: f64 }, "a = 1e5", .{ .a = 100000 });
}

// automatic-type-conversions L1235 automatic-type-conversions L1237 string-value-concatenation.10 · java ✓ · pyhocon ⚠️ · spec ✓ — any scalar reads as a string,
// and a number reads *as written*: `1.50` stays "1.50", `1e5` stays "1e5".
// pyhocon renormalises to "1.5" and "100000.0" — a config that round-trips through
// pyhocon today can change text here, worth knowing for the bridge.
test "convert.string" {
    const T = struct { a: []const u8 };
    try expectConverts(T, "a = the coffee runs out on monday morning", .{ .a = "the coffee runs out on monday morning" });
    try expectConverts(T, "a = \"the coffee runs out on monday morning\"", .{ .a = "the coffee runs out on monday morning" });
    try expectConverts(T, "a = 5", .{ .a = "5" });
    try expectConverts(T, "a = 1.50", .{ .a = "1.50" });
    try expectConverts(T, "a = 1e5", .{ .a = "1e5" });
    try expectConverts(T, "a = true", .{ .a = "true" });
}

// automatic-type-conversions L1254 automatic-type-conversions L1255 · java ✓ · pyhocon ⚠️ · spec ✓ — objects and arrays never become
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
        \\a = the dog ate my homework
        \\b = "and then the teacher"
        \\c = """and now it looks innocent"""
    );
    const got = try Config.parseFromSliceLeaky(T, arena.allocator(), source);
    @memset(source, 'x');
    testing.allocator.free(source);

    try testing.expectEqualStrings("the dog ate my homework", got.a);
    try testing.expectEqualStrings("and then the teacher", got.b);
    try testing.expectEqualStrings("and now it looks innocent", got.c);
}

// automatic-type-conversions L1252 automatic-type-conversions L1244 · java ✓ · pyhocon ⚠️ · spec ✓ — null into a plain type is an error;
// only an unquoted null is null, a quoted "null" is the four letters.
// pyhocon hands back None instead of failing.
test "convert.null is not a value of any plain type" {
    try expectConvertError(struct { a: usize }, "a = null", error.TypeMismatch);
    try expectConvertError(struct { a: bool }, "a = null", error.TypeMismatch);
    try expectConvertError(struct { a: []const u8 }, "a = null", error.TypeMismatch);
    try expectConverts(struct { a: []const u8 }, "a = \"null\"", .{ .a = "null" });
}

// automatic-type-conversions L1255 · java ✓ · pyhocon ✓ · spec ✓
test "convert.list" {
    const T = struct { a: []const usize };
    try expectConverts(T, "a = [1, 2, 3]", .{ .a = &.{ 1, 2, 3 } });
    try expectConverts(T, "a = []", .{ .a = &.{} });
    try expectConvertError(T, "a = 5", error.TypeMismatch);
}

// conversion-of-numerically-indexed-objects-to-arrays.1 conversion-of-numerically-indexed-objects-to-arrays.4-conversion-of-numerically-indexed-objects-to-arrays.6 · java ✓ · pyhocon ✓ · spec ✓ — an object with numeric keys
// becomes a list when a list is asked for: sorted by the number, gaps closed, other
// keys ignored, and an object with no numeric key at all (empty included) is not
// converted. The suite pins only the other half (conversion-of-numerically-indexed-objects-to-arrays.2: without a list asked for
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
// automatic-type-conversions L1244 config-object-merging-and-file-merging.7: an explicit null is null too, and it clears an earlier object.
test "convert.optional" {
    const T = struct { a: ?usize };
    try expectConverts(T, "a = 5", .{ .a = 5 });
    try expectConverts(T, "b = 5", .{ .a = null });
    try expectConverts(T, "a = null", .{ .a = null });
    try expectConverts(struct { a: ?struct { b: usize } }, "a { b = 1 }\na = null", .{ .a = null });
}

// Found while checking the README example: `.optional` and `.@"enum"` read
// `value.scalar` without asking which variant is active, so an object there is a
// safety panic in a debug build, not an error. A panic takes the whole test run
// down with it, hence the skip until both branches check `value == .scalar`.
test "convert.an object where an optional or an enum reads a scalar" {
    try expectConverts(struct { tls: ?struct { cert: []const u8 } }, "tls { cert = grumpy-wombat.pem }", .{ .tls = .{ .cert = "grumpy-wombat.pem" } });
    try expectConvertError(struct { level: enum { debug, info } }, "level { a = 1 }", error.TypeMismatch);
}

// Zig only — a field default stands in for a missing key; a present key wins.
test "convert.default field value" {
    // if (true) return error.SkipZigTest; // needs `field.defaultValue()` in the struct branch
    const T = struct { a: usize = 7 };
    try expectConverts(T, "b = 1", .{ .a = 7 });
    try expectConverts(T, "a = 1", .{ .a = 1 });
}

// java ✓ · pyhocon – · spec – — getEnum matches the constant name exactly, case
// included. pyhocon has no enums.
test "convert.enum" {
    const Level = enum { debug, info };
    try expectConverts(struct { level: Level }, "level = debug", .{ .level = .debug });
    try expectConvertError(struct { level: Level }, "level = DEBUG", error.TypeMismatch);
}
