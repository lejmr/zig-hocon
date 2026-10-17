const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Value = @import("Value.zig").Value;
const Ast = @import("Ast.zig");
const Tokenizer = @import("Tokenizer.zig").Tokenizer;
const Include = @import("Include.zig");
const Diagnostics = @import("Diagnostics.zig");
const Duration = @import("units/Duration.zig");
const Period = @import("units/Period.zig");
const Size = @import("units/Size.zig");
const stringify = @import("stringify.zig");

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

    /// What a parse can be told.
    pub const ParseOptions = struct {
        /// Filled in with the error, and where it is, when the parse fails. Its
        /// copies are made with the allocator the parse is given; `deinit` it
        /// with that one.
        diagnostics: ?*Diagnostics = null,
        /// One fetch of an `http(s)` include, from connect to the last byte; longer is
        /// `error.IncludeTimeout`.
        http_timeout: std.Io.Duration = Include.default_http_timeout,
        /// Where a substitution whose path is not in the document looks next.
        /// The library never reads the process environment on its own: pass
        /// `.{ .map = init.environ_map }` for that, the way `std.process.run`
        /// takes its `environ_map`.
        env: Value.Env = .none,
    };

    /// Like `parseFromSliceLeaky`, but any allocator will do: everything lands in
    /// an arena owned by the result, and `deinit` on the result frees it.
    ///
    /// Text comes out as UTF-8, with one exception JSON makes: a surrogate on
    /// its own, quoted `"\ud83d"`, has no UTF-8, so it stays as its three WTF-8
    /// bytes, in a `[]const u8` as in a `Value`. Check with
    /// `std.unicode.utf8ValidateSlice` where UTF-8 is required.
    pub fn parseFromSlice(comptime T: type, gpa: Allocator, source: [:0]const u8, options: ParseOptions) !Parsed(T) {
        const arena = gpa.create(std.heap.ArenaAllocator) catch |err| {
            noPlace(options, err);
            return err;
        };
        errdefer gpa.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(gpa);
        // Runs before the destroy above: `errdefer`s unwind in reverse order.
        errdefer arena.deinit();

        // The arena goes when the parse fails, the diagnostics stay: theirs is `gpa`.
        return .{ .arena = arena, .value = try parseSource(T, arena.allocator(), gpa, "", source, .{}, options) };
    }

    pub fn parseFromSliceLeaky(comptime T: type, allocator: Allocator, file_content: [:0]const u8, options: ParseOptions) !T {
        // No file behind the text, so an `include` in it is an error.
        return parseSource(T, allocator, allocator, "", file_content, .{}, options);
    }

    /// Reads the file at `path` and every file it includes through `io`, and
    /// parses them as one document. Includes resolve relative to the file that
    /// has the `include`; `file("…")` ones relative to the working directory.
    /// Everything lands in an arena owned by the result, as in `parseFromSlice`.
    pub fn parseFromFile(comptime T: type, gpa: Allocator, io: std.Io, path: []const u8, options: ParseOptions) !Parsed(T) {
        const arena = gpa.create(std.heap.ArenaAllocator) catch |err| {
            noPlace(options, err);
            return err;
        };
        errdefer gpa.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();

        return .{ .arena = arena, .value = try readSource(T, arena.allocator(), gpa, io, path, options) };
    }

    pub fn parseFromFileLeaky(comptime T: type, allocator: Allocator, io: std.Io, path: []const u8, options: ParseOptions) !T {
        return readSource(T, allocator, allocator, io, path, options);
    }

    /// The file at `path`, parsed. `keep` is what the diagnostics copy with.
    fn readSource(comptime T: type, allocator: Allocator, keep: Allocator, io: std.Io, path: []const u8, options: ParseOptions) !T {
        // The text stays in the arena: the values point into it.
        const source = std.Io.Dir.cwd().readFileAllocOptions(io, path, allocator, .limited(Include.max_file_size), .of(u8), 0) catch |err| {
            noPlace(options, err);
            return err;
        };
        const full_path = std.fs.path.resolve(allocator, &.{path}) catch |err| {
            noPlace(options, err);
            return err;
        };
        return parseSource(T, allocator, keep, path, source, .{
            .io = io,
            .http_timeout = options.http_timeout,
            .dir = std.fs.path.dirname(path) orelse "",
            .stack = &.{full_path},
        }, options);
    }

    /// An error with nothing to point into: the file was never read.
    fn noPlace(options: ParseOptions, err: anyerror) void {
        if (options.diagnostics) |diag| diag.* = .{ .err = err };
    }

    /// `keep` is what the diagnostics copy the path and the line with: the files
    /// go with a failed parse.
    fn parseSource(comptime T: type, allocator: Allocator, keep: Allocator, path: []const u8, source: [:0]const u8, ctx: Value.Context, options: ParseOptions) !T {
        // A Diagnostics reused from an earlier parse must not keep its error.
        if (options.diagnostics) |diag| diag.* = .{};
        // A file is never bigger than this, so a slice is not either: every
        // offset then fits the u32 in `Ref`.
        if (source.len >= Include.max_file_size) {
            noPlace(options, error.StreamTooLong);
            return error.StreamTooLong;
        }

        var files: Value.Files = .{};
        const obj = load(allocator, path, source, ctx, options.env, &files) catch |err| {
            if (options.diagnostics) |diag| {
                diag.* = .{ .err = err, .location = if (err == error.OutOfMemory) null else locate(keep, files, files.failed) };
            }
            return err;
        };
        // `.keep` leaves what waits for the environment in the tree on purpose.
        if (T == Value and options.env == .keep) return obj;
        var failed: Failed = .{};
        return parseFromValue(T, allocator, obj, &failed) catch |err| {
            if (options.diagnostics) |diag| {
                diag.* = .{ .err = err };
                // Out of memory has no place, and no memory to copy one with.
                if (err != error.OutOfMemory) {
                    diag.expected = failed.expected;
                    diag.key_path = keyPath(keep, failed.steps.items) catch "";
                    if (failed.value) |value| diag.location = locate(keep, files, placeOf(files, value));
                }
            }
            return err;
        };
    }

    /// Where a conversion failed, filled in on the way up from there: each
    /// level adds its key or index, so `steps` is innermost first.
    pub const Failed = struct {
        steps: std.ArrayList(Step) = .empty,
        /// The value that did not fit; null for a missing field, which has none.
        value: ?Value = null,
        /// What the level it failed at wanted there (`expected`).
        expected: []const u8 = "",

        pub const Step = union(enum) { key: []const u8, index: usize };
    };

    /// `db.pool`, `ports[1]`: the keys as a path says them, quoted where they
    /// need it, an index after the list it is in.
    fn keyPath(gpa: Allocator, steps: []const Failed.Step) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var i = steps.len;
        while (i > 0) {
            i -= 1;
            switch (steps[i]) {
                .key => |key| {
                    if (i != steps.len - 1) try out.writer.writeByte('.');
                    try stringify.writeKey(key, &out.writer);
                },
                .index => |index| try out.writer.print("[{d}]", .{index}),
            }
        }
        return out.toOwnedSlice();
    }

    /// Where `value` was written, if it still says. A ref knows where its `${`
    /// is, a concatenation waiting for one where it starts, and a scalar where
    /// it is (`Scalar.at`). A key does not, but its text is a slice of the file
    /// it was read from, unless it had to be put together (escapes): the file
    /// it points into is the file, and how far in is the offset. A list is
    /// where its first element is, an object where its first key is, a key set
    /// twice where it was set last; but what waits for the environment is
    /// where the first thing in it that waits is.
    // ponytail: no place for an empty list or object, or a value from a
    // `.json` include; a position on every value when that matters.
    fn placeOf(files: Value.Files, value: Value) ?Value.Pos {
        const text = switch (value) {
            .ref => |r| return r.at(),
            .pending => |parts| return parts[0].pos,
            .stack => |items| return placeOf(files, items[items.len - 1]),
            .array => |items| {
                for (items) |item| if (!item.isResolved()) return placeOf(files, item);
                for (items) |item| if (placeOf(files, item)) |pos| return pos;
                return null;
            },
            .object => |members| for (members) |m| {
                if (!m.value.isResolved()) return placeOf(files, m.value);
            } else if (members.len > 0) members[0].key.value else return null,
            .scalar => |s| return s.at(),
        };
        for (files.list.items, 0..) |file, i| {
            const start = @intFromPtr(file.source.ptr);
            const at = @intFromPtr(text.ptr);
            if (at >= start and at < start + file.source.len) return .{ .file = @intCast(i), .offset = at - start };
        }
        return null;
    }

    /// What a value of type T is, in words, for `Diagnostics.expected`.
    fn expected(comptime T: type) []const u8 {
        if (T == Duration) return "duration";
        if (T == Period) return "period";
        if (T == Size) return "size";
        return switch (@typeInfo(T)) {
            .int, .float => @typeName(T),
            .bool => "bool",
            .pointer => |info| if (info.size == .one) expected(info.child) else if (info.child == u8) "string" else "list",
            .optional => |info| expected(info.child),
            .array => |info| if (info.child == u8)
                std.fmt.comptimePrint("string of {d} bytes or list of {d}", .{ info.len, info.len })
            else
                std.fmt.comptimePrint("list of {d}", .{info.len}),
            .@"struct" => "object",
            .void => "empty object",
            // The names it can be, `one of debug, info`, and for a union the
            // object that has one of them as its key.
            .@"enum" => |info| comptime if (info.is_exhaustive) oneOf(T) else oneOf(T) ++ " or a number",
            .@"union" => comptime "object with " ++ oneOf(T),
            else => "",
        };
    }

    /// `one of debug, info`, the names of T. Called at compile time, the only
    /// time `++` joins strings.
    fn oneOf(comptime T: type) []const u8 {
        var words: []const u8 = "one of";
        for (std.meta.fieldNames(T), 0..) |name, i| {
            words = words ++ (if (i == 0) " " else ", ") ++ name;
        }
        return words;
    }

    /// Where `place` is in `files`, with its own copy of the path and the line:
    /// the files themselves go with the parse.
    fn locate(gpa: Allocator, files: Value.Files, place: ?Value.Pos) ?Diagnostics.Location {
        const at = place orelse return null;
        const file = files.list.items[at.file];
        return Diagnostics.locate(file.path, file.source, at.offset).dupe(gpa) catch null;
    }

    /// Source to a resolved tree. `files` gets this file and every file it
    /// includes, and on failure the place the error is at, if it has one.
    fn load(gpa: Allocator, path: []const u8, source: [:0]const u8, ctx: Value.Context, env: Value.Env, files: *Value.Files) Value.ResolveError!Value {
        try files.list.append(gpa, .{ .path = path, .source = source });
        var main = ctx;
        main.files = files;

        // `parse` is a method, so the parser has to exist first.
        var parser = Ast.Parser{ .gpa = gpa, .t = .{ .t = Tokenizer.init(source) } };
        const ast = parser.parse() catch |err| {
            files.fail(0, parser.err_offset);
            return err;
        };
        var obj = try Value.fromNode(gpa, ast, main);
        try obj.resolve(gpa, env, &files.failed);
        return obj;
    }

    pub const ConvertError = error{ TypeMismatch, MissingField, Unresolved, UnsupportedType, OutOfMemory, UnknownUnit } ||
        std.fmt.ParseIntError;

    /// Converts a Value into T. `T` is comptime, so the compiler builds one copy
    /// of this function per target type, and the `switch` below is decided at
    /// compile time: for `usize` only the `.int` branch exists at all.
    /// `failed` learns where it failed and why (see `Failed`).
    pub fn parseFromValue(comptime T: type, allocator: Allocator, value: Value, failed: *Failed) ConvertError!T {
        return convert(T, allocator, value, failed) catch |err| {
            // The first level to see the error is the one it starts at: the
            // levels above it have added their step by the time they see it.
            if (failed.steps.items.len == 0 and failed.value == null) {
                failed.value = value;
                if (err != error.Unresolved) failed.expected = expected(T);
            }
            return err;
        };
    }

    fn convert(comptime T: type, allocator: Allocator, value: Value, failed: *Failed) ConvertError!T {
        // The dynamic tree as it is, the way std.json.parseFromSlice(std.json.Value, …)
        // hands back its own — finished, so anything can print it.
        if (T == Value) return if (value.isResolved()) value else error.Unresolved;
        // Not resolved yet: refuse loudly instead of guessing.
        if (value == .ref or value == .pending or value == .stack) return error.Unresolved;
        // Structs, but read from text in the units format: `10ms` is a Duration.
        if (T == Duration or T == Period or T == Size) return T.fromValue(value);
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
                // `*T` is a `T` of its own, as std.json reads one.
                if (info.size == .one) {
                    const one = try allocator.create(info.child);
                    one.* = try parseFromValue(info.child, allocator, value, failed);
                    return one;
                }
                if (info.size != .slice) @compileError("hocon: unsupported target type " ++ @typeName(T));
                switch (value) {
                    .scalar => {
                        if (info.child != u8) return error.TypeMismatch;
                        if (std.mem.eql(u8, value.scalar.value, "null") and !value.scalar.quoted) return error.TypeMismatch;
                        if (info.sentinel() != null) return try allocator.dupeZ(u8, value.scalar.value);
                        return try allocator.dupe(u8, value.scalar.value);
                    },
                    .array => {
                        if (info.child == u8) return error.TypeMismatch;
                        var a: std.ArrayList(info.child) = .empty;
                        for (value.array, 0..) |item, i| {
                            const val = parseFromValue(info.child, allocator, item, failed) catch |err| {
                                try failed.steps.append(allocator, .{ .index = i });
                                return err;
                            };
                            try a.append(allocator, val);
                        }
                        if (info.sentinel()) |end| return try a.toOwnedSliceSentinel(allocator, end);
                        return try a.toOwnedSlice(allocator);
                    },
                    // A list is asked for, so numeric keys make one.
                    .object => {
                        const items = try Value.numbered(allocator, value.object) orelse return error.TypeMismatch;
                        return parseFromValue(T, allocator, .{ .array = items }, failed);
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
                        @field(result, field.name) = parseFromValue(field.type, allocator, member.value, failed) catch |err| {
                            try failed.steps.append(allocator, .{ .key = field.name });
                            return err;
                        };
                    } else if (field.defaultValue()) |default| {
                        @field(result, field.name) = default;
                    } else if (@typeInfo(field.type) == .optional) {
                        @field(result, field.name) = null;
                    } else {
                        // The path names the field; there is no value to point at.
                        try failed.steps.append(allocator, .{ .key = field.name });
                        return error.MissingField;
                    }
                }
                return result;
            },
            // A name, or for a non-exhaustive enum also a number, as std.json reads it.
            .@"enum" => |info| {
                if (value != .scalar) return error.TypeMismatch;
                if (std.meta.stringToEnum(T, value.scalar.value)) |tag| return tag;
                if (info.is_exhaustive or value.scalar.quoted) return error.TypeMismatch;
                return @enumFromInt(try std.fmt.parseInt(info.tag_type, value.scalar.value, 10));
            },
            // The payload of a tag that has none, as std.json writes it.
            .void => if (value != .object or value.object.len != 0) return error.TypeMismatch,
            .optional => |info| {
                if (value == .scalar and !value.scalar.quoted and std.mem.eql(u8, value.scalar.value, "null")) return null;
                return try parseFromValue(info.child, allocator, value, failed);
            },
            // A list of exactly that many, or for `[N]u8` a string of N bytes,
            // as `stringify` writes them.
            .array => |info| {
                var result: T = undefined;
                // `undefined` leaves out the sentinel too.
                if (info.sentinel()) |end| result[info.len] = end;
                if (info.child == u8 and value == .scalar) {
                    if (std.mem.eql(u8, value.scalar.value, "null") and !value.scalar.quoted) return error.TypeMismatch;
                    if (value.scalar.value.len != info.len) return error.TypeMismatch;
                    @memcpy(&result, value.scalar.value);
                    return result;
                }
                if (value == .object) {
                    const items = try Value.numbered(allocator, value.object) orelse return error.TypeMismatch;
                    return parseFromValue(T, allocator, .{ .array = items }, failed);
                }
                if (value != .array or value.array.len != info.len) return error.TypeMismatch;
                for (&result, value.array, 0..) |*item, v, i| {
                    item.* = parseFromValue(info.child, allocator, v, failed) catch |err| {
                        try failed.steps.append(allocator, .{ .index = i });
                        return err;
                    };
                }
                return result;
            },
            // `{ tag = payload }`, one member, the way std.json writes a tagged
            // union; a `void` payload is `{}` (see `.void`).
            .@"union" => |info| {
                if (info.tag_type == null) @compileError("hocon: unsupported untagged union " ++ @typeName(T));
                if (value != .object or value.object.len != 1) return error.TypeMismatch;
                const member = value.object[0];
                inline for (info.fields) |field| {
                    if (std.mem.eql(u8, member.key.value, field.name)) {
                        return @unionInit(T, field.name, parseFromValue(field.type, allocator, member.value, failed) catch |err| {
                            try failed.steps.append(allocator, .{ .key = field.name });
                            return err;
                        });
                    }
                }
                return error.TypeMismatch;
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

    const config = try Config.parseFromSliceLeaky(target_s1, gpa, "{a=5, b: 6}", .{});
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
    const got = try Config.parseFromSliceLeaky(T, arena.allocator(), src, .{});
    try testing.expectEqualDeep(expected, got);
}

fn expectConvertError(comptime T: type, src: [:0]const u8, expected: anyerror) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(expected, Config.parseFromSliceLeaky(T, arena.allocator(), src, .{}));
}

// automatic-type-conversions L1238 · java ✓ · pyhocon ✓ · spec ✓ — a number is text until something asks for
// a number, so a quoted "5" converts just like 5.
test "convert.int" {
    try expectConverts(struct { a: usize }, "a = 5", .{ .a = 5 });
    try expectConverts(struct { a: i64 }, "a = -3", .{ .a = -3 });
    try expectConverts(struct { a: usize }, "a = \"5\"", .{ .a = 5 });
    try expectConvertError(struct { a: usize }, "a = abc", error.InvalidCharacter);
}

// unquoted-strings.12-13 · java ⚠️ · pyhocon ⚠️ · spec ✓ — text that only starts
// like a number never gets as far as converting: the spec makes it a parse
// error. Both oracles parse `-foo` and `1.2.3` as strings and fail only when
// asked for a number (FINDINGS.md, unquoted-strings).
test "convert.int refuses a string that merely starts like a number" {
    try expectConvertError(struct { a: usize }, "a = 1.2.3", error.BadNumber);
    try expectConvertError(struct { a: i64 }, "a = -foo", error.HyphenIsNotAJsonNumber);
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

// java ✓ · pyhocon ✓ · spec ✓ — a required substitution with nothing behind it.
test "convert.an unresolved substitution is an error" {
    try expectConvertError(struct { a: usize }, "a = ${b}", error.Unresolved);
}

// java ✓ · pyhocon ✓ · spec ✓ — substitutions look at the finished document: a
// later `x = 2` wins over the earlier one even for `a`, written between them.
// Paths go into objects, refs chain, and parts around a ref join as text.
test "convert.substitutions resolve against the whole document" {
    const T = struct { a: usize, b: usize, c: usize, d: []const u8 };
    try expectConverts(T,
        \\x = 1
        \\a = ${x}
        \\x = 2
        \\o { p = 3 }
        \\b = ${o.p}
        \\c = ${b}
        \\d = ${x}" ducks in a row"
    , .{ .a = 2, .b = 3, .c = 3, .d = "2 ducks in a row" });
}

// java ✓ · pyhocon ✓ · spec ✓ — an optional with nothing behind it removes the
// member, so the field falls back to its default; a ref that needs itself fails.
test "convert.substitution optional and cycle" {
    try expectConverts(struct { a: usize = 7 }, "a = ${?nope}", .{ .a = 7 });
    try expectConvertError(struct { a: usize }, "a = ${b}\nb = ${a}", error.SubstitutionCycle);
    try expectConvertError(struct { a: struct { b: usize } }, "a { b = ${a} }", error.SubstitutionCycle);
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
    const got = try Config.parseFromSliceLeaky(T, arena.allocator(), source, .{});
    @memset(source, 'x');
    testing.allocator.free(source);

    try testing.expectEqualStrings("the dog ate my homework", got.a);
    try testing.expectEqualStrings("and then the teacher", got.b);
    try testing.expectEqualStrings("and now it looks innocent", got.c);
}

// unchanged-from-json/027 · java ✓ (a String holds one UTF-16 unit) · pyhocon ⚠️
// keeps the escape as text · spec ✓ — a surrogate on its own is its WTF-8 bytes.
test "convert.a surrogate on its own is WTF-8 in a string" {
    try expectConverts(struct { s: []const u8 }, "s = \"tea\\ud83d\"", .{ .s = "tea\xed\xa0\xbd" });
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
    const T = struct { a: []const usize };
    try expectConverts(T, "a { \"0\" = 1, \"1\" = 2 }", .{ .a = &.{ 1, 2 } });
    try expectConverts(T, "a { \"2\" = 20, \"0\" = 0 }", .{ .a = &.{ 0, 20 } });
    try expectConverts(T, "a { \"0\" = 1, x = 9 }", .{ .a = &.{1} });
    try expectConvertError(T, "a {}", error.TypeMismatch);
    try expectConvertError(T, "a { x = 1 }", error.TypeMismatch);
    // the way a properties file writes a list, and a fixed array as well
    try expectConverts(T, "a.1 = 2\na.0 = 1\na.-1 = 9", .{ .a = &.{ 1, 2 } });
    try expectConverts(struct { a: [2][]const u8 }, "a { 1 = cake, 0 = tea }", .{ .a = .{ "tea", "cake" } });
    try expectConvertError(struct { a: [3]u8 }, "a { 0 = 1, 1 = 2 }", error.TypeMismatch);
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
// included. pyhocon has no enums. Zig only: a non-exhaustive enum also takes
// the unquoted number of a value with no name, as std.json reads it.
test "convert.enum" {
    const Level = enum { debug, info };
    try expectConverts(struct { level: Level }, "level = debug", .{ .level = .debug });
    try expectConvertError(struct { level: Level }, "level = DEBUG", error.TypeMismatch);

    const Mood = enum(u8) { calm, _ };
    try expectConverts(struct { mood: Mood }, "mood = 200", .{ .mood = @enumFromInt(200) });
    try expectConverts(struct { mood: Mood }, "mood = calm", .{ .mood = .calm });
    try expectConvertError(struct { mood: Mood }, "mood = \"200\"", error.TypeMismatch);
    try expectConvertError(struct { level: Level }, "level = 0", error.TypeMismatch);
}

// Zig only, as std.json reads them — java and pyhocon have neither type. A
// fixed array takes a list of exactly its length, `[N]u8` a string of N bytes.
test "convert.array" {
    try expectConverts(struct { a: [3]u8 }, "a = [1, 2, 3]", .{ .a = .{ 1, 2, 3 } });
    try expectConverts(struct { a: [2][]const u8 }, "a = [tea, cake]", .{ .a = .{ "tea", "cake" } });
    try expectConverts(struct { a: [6]u8 }, "a = wombat", .{ .a = "wombat".* });
    try expectConvertError(struct { a: [3]u8 }, "a = [1, 2]", error.TypeMismatch);
    try expectConvertError(struct { a: [2]u8 }, "a = wombat", error.TypeMismatch);
    // A sentinel comes after the last one, in an array and in a slice.
    try expectConverts(struct { a: [6:0]u8 }, "a = wombat", .{ .a = "wombat".* });
    try expectConverts(struct { a: [2:0]u16 }, "a = [1, 2]", .{ .a = .{ 1, 2 } });
    try expectConverts(struct { a: [:0]const u8 }, "a = wombat", .{ .a = "wombat" });
    try expectConverts(struct { a: [:0]const u16 }, "a = [1, 2]", .{ .a = &.{ 1, 2 } });
    // null is no text, as for `[]const u8`; quoted it is.
    try expectConvertError(struct { a: [4]u8 }, "a = null", error.TypeMismatch);
    try expectConverts(struct { a: [4]u8 }, "a = \"null\"", .{ .a = "null".* });
    try expectConvertError(struct { a: [2]u16 }, "a = { b = 1 }", error.TypeMismatch);
}

// Zig only, as std.json reads it — a pointer to one value is that value,
// allocated, which is how a type refers to itself.
test "convert.pointer" {
    const Turtle = struct { name: []const u8, below: ?*const @This() = null };
    try expectConverts(Turtle, "name = top, below { name = bottom }", .{ .name = "top", .below = &.{ .name = "bottom" } });
    try expectConverts(struct { a: *const u8 }, "a = 7", .{ .a = &7 });
}

// Zig only, as std.json reads it — `{ tag = payload }` with exactly one member;
// a `void` payload is an empty object.
test "convert.tagged union" {
    const Storage = union(enum) { memory, disk: struct { path: []const u8 } };
    const T = struct { storage: Storage };
    try expectConverts(T, "storage { memory {} }", .{ .storage = .memory });
    try expectConverts(T, "storage.disk.path = /tmp/wombat", .{ .storage = .{ .disk = .{ .path = "/tmp/wombat" } } });
    try expectConvertError(T, "storage { tape {} }", error.TypeMismatch);
    try expectConvertError(T, "storage { memory {}, disk { path = x } }", error.TypeMismatch);
    try expectConvertError(T, "storage { memory = 1 }", error.TypeMismatch);
    try expectConvertError(T, "storage = memory", error.TypeMismatch);
}
