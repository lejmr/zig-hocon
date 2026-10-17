//! An exact length of time, in nanoseconds like `std.Io.Duration`.
//!
//! In a config: `ns us ms s m h d` and their long forms, lowercase only
//! (spec L1295). A number with no unit is milliseconds.

const std = @import("std");
const testing = std.testing;
const Value = @import("../Value.zig").Value;
const parse = @import("parse.zig");

const Duration = @This();

nanoseconds: i96,

/// For reading a duration in any of them. Each one is its length in
/// nanoseconds. Weeks can be read, but a config cannot write `2 weeks` for a
/// duration: the spec has no such unit there.
pub const Unit = enum(i64) {
    ns = 1,
    us = std.time.ns_per_us,
    ms = std.time.ns_per_ms,
    s = std.time.ns_per_s,
    min = std.time.ns_per_min,
    h = std.time.ns_per_hour,
    d = std.time.ns_per_day,
    w = std.time.ns_per_week,

    pub const nano: Unit = .ns;
    pub const nanos: Unit = .ns;
    pub const nanosecond: Unit = .ns;
    pub const nanoseconds: Unit = .ns;
    pub const micro: Unit = .us;
    pub const micros: Unit = .us;
    pub const microsecond: Unit = .us;
    pub const microseconds: Unit = .us;
    pub const milli: Unit = .ms;
    pub const millis: Unit = .ms;
    pub const millisecond: Unit = .ms;
    pub const milliseconds: Unit = .ms;
    pub const second: Unit = .s;
    pub const seconds: Unit = .s;
    pub const m: Unit = .min;
    pub const minute: Unit = .min;
    pub const minutes: Unit = .min;
    pub const hour: Unit = .h;
    pub const hours: Unit = .h;
    pub const day: Unit = .d;
    pub const days: Unit = .d;
    pub const week: Unit = .w;
    pub const weeks: Unit = .w;
};

/// Exactly the unit names the spec lists for a duration.
const names = std.StaticStringMap(Unit).initComptime(.{
    .{ "ns", .ns },       .{ "nano", .ns },  .{ "nanos", .ns },  .{ "nanosecond", .ns },  .{ "nanoseconds", .ns },
    .{ "us", .us },       .{ "micro", .us }, .{ "micros", .us }, .{ "microsecond", .us }, .{ "microseconds", .us },
    .{ "ms", .ms },       .{ "milli", .ms }, .{ "millis", .ms }, .{ "millisecond", .ms }, .{ "milliseconds", .ms },
    .{ "s", .s },         .{ "second", .s }, .{ "seconds", .s }, .{ "m", .min },          .{ "minute", .min },
    .{ "minutes", .min }, .{ "h", .h },      .{ "hour", .h },    .{ "hours", .h },        .{ "d", .d },
    .{ "day", .d },       .{ "days", .d },
});

/// `n` of `unit`. Like `std.Io.Duration.fromSeconds`, too big a number for
/// an i96 of nanoseconds is a panic, not an error: it is written in code.
pub fn of(n: i64, unit: Unit) Duration {
    return .{ .nanoseconds = @as(i96, n) * @intFromEnum(unit) };
}

/// How many of `unit` it is, fractions included.
pub fn as(self: Duration, unit: Unit) f64 {
    return @as(f64, @floatFromInt(self.nanoseconds)) / @as(f64, @floatFromInt(@intFromEnum(unit)));
}

/// How many whole `unit`s it is, cut toward zero. One that does not fit an
/// i64 (`200000d` in `.ns`) is the nearest i64, not a panic: the number
/// comes from a config file.
pub fn whole(self: Duration, unit: Unit) i64 {
    return std.math.lossyCast(i64, @divTrunc(self.nanoseconds, @intFromEnum(unit)));
}

pub fn toIo(self: Duration) std.Io.Duration {
    return .{ .nanoseconds = self.nanoseconds };
}

/// A string or a number in the units format; a number alone is milliseconds.
pub fn fromValue(value: Value) parse.Error!Duration {
    const text = try parse.split(value);
    const unit = if (text.unit.len == 0) .ms else names.get(text.unit) orelse return error.UnknownUnit;
    const ns = try parse.times(text.number, @intCast(@intFromEnum(unit)));
    return .{ .nanoseconds = std.math.cast(i96, ns) orelse return error.Overflow };
}

/// The largest unit it is a whole number of: `90s`, `2h`, `1500ms`. That
/// is how `stringify` writes it, and it reads back the same.
pub fn format(self: Duration, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (self.nanoseconds == 0) return w.writeAll("0s");
    // Largest first; the names are the ones a config can say.
    const largest = [_]struct { Unit, []const u8 }{
        .{ .d, "d" }, .{ .h, "h" }, .{ .min, "m" }, .{ .s, "s" }, .{ .ms, "ms" }, .{ .us, "us" }, .{ .ns, "ns" },
    };
    for (largest) |u| {
        const unit, const name = u;
        if (@rem(self.nanoseconds, @intFromEnum(unit)) == 0) {
            return w.print("{d}{s}", .{ @divExact(self.nanoseconds, @intFromEnum(unit)), name });
        }
    } else unreachable;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const expectReads = parse.expectReads;
const expectFormat = parse.expectFormat;

// duration-format, units-format · java ✓ · pyhocon – · spec ✓ — pyhocon has no
// getDuration (it turns an unquoted `10 seconds` into a timedelta while it
// parses, `10 ms` it leaves as text). Every value row is java's `getDuration`
// in nanoseconds. A fraction is exact, as in java: `0.3 s` is not 299999999.
// A unit is the letters at the end, so `1e3 ms` is a number and a unit.
test "units.a duration from the units format" {
    try expectReads(Duration, &.{
        .ok("a = 10", "10000000"),
        .ok("a = \"10\"", "10000000"),
        .ok("a = 1.5", "1500000"),
        .ok("a = 10ms", "10000000"),
        .ok("a = 10 ms", "10000000"),
        .ok("a = \" 10 ms \"", "10000000"),
        .ok("a = 5ns", "5"),
        .ok("a = 5us", "5000"),
        .ok("a = 5s", "5000000000"),
        .ok("a = 5m", "300000000000"),
        .ok("a = 5h", "18000000000000"),
        .ok("a = 5d", "432000000000000"),
        .ok("a = 2 hours", "7200000000000"),
        .ok("a = 0.3 s", "300000000"),
        .ok("a = 1.5e-3 s", "1500000"),
        .ok("a = 1e3 ms", "1000000000"),
        .ok("a = 1e+3 ms", "1000000000"),
        .ok("a = 1e3", "1000000000"),
        .ok("a = -5 s", "-5000000000"),
        .ok("a = 0.5 ns", "0"),
        .ok("a = \"5\\u00A0ms\"", "5000000"),
        .ok("a = \"\"\"\n 5 ms\n\"\"\"", "5000000"),
        .ok("b = 10\na = ${b} ms", "10000000"),
        // Any number of digits, any exponent: still exact, and 0 stays 0.
        .ok("a = 1.0000000000000000000000000 d", "86400000000000"),
        .ok("a = 1.00000000000000000000000000000000000000000", "1000000"),
        .ok("a = 100000000000000000000000000000000000000000e-40 s", "10000000000"),
        .ok("a = 0.1234567890123456789012345678901234567890 s", "123456789"),
        .ok("a = 3.14159265358979323846264338327950288419716939937510 s", "3141592653"),
        .ok("a = 0e9999999999 s", "0"),
        .ok("a = \"0e2147483648 s\"", "0"),
        .ok("a = 1e-9999999999 s", "0"),
        .ok("a = 1e-2147483649 s", "0"),
        .ok("a = 0.1e-2147483648 s", "0"),
        // The unit is case-sensitive, and the names are exactly the spec's.
        .ok("a = 10MS", "UnknownUnit"),
        .ok("a = 5 weeks", "UnknownUnit"),
        .ok("a = 5 sec", "UnknownUnit"),
        // Not a number, then letters.
        .ok("a = 10m2", "InvalidCharacter"),
        .ok("a = ms10", "InvalidCharacter"),
        .ok("a = ms", "InvalidCharacter"),
        .ok("a = \"\"", "InvalidCharacter"),
        .ok("a = \"5 s s\"", "InvalidCharacter"),
        .ok("a = true", "InvalidCharacter"),
        // Not text at all.
        .ok("a = null", "TypeMismatch"),
        .ok("a = [1]", "TypeMismatch"),
        .ok("a { b = 1 }", "TypeMismatch"),
    });
}

// Where java differs, and why here is right.
// java ⚠️ — `.5`, `01` and `+5` are numbers to java's `Double.parseDouble`, and
// `NaN` is one that is 0; HOCON's number is JSON's (spec L1264 "a number"),
// and a parse of `a = 01 s` refuses it as well.
// java ⚠️ — java's long saturates: 9223372036854775807 d and 1e400 s are both
// 292 years. An i96 holds 106752 d exactly, and more than it holds is an error.
// java ✓ `μs` is an error there too, of an unknown unit; here only ASCII
// letters make a unit, so it is a number that is not one.
test "units.a duration where java reads it otherwise" {
    try expectReads(Duration, &.{
        .ok("a = \".5 s\"", "InvalidCharacter"),
        .ok("a = \"01 s\"", "InvalidCharacter"),
        .ok("a = \"+5 s\"", "InvalidCharacter"),
        .ok("a = \"NaN s\"", "InvalidCharacter"),
        .ok("a = 106752 d", "9223372800000000000"),
        .ok("a = 9223372036854775807 d", "Overflow"),
        .ok("a = 1e400 s", "Overflow"),
        .ok("a = 1e9999999999 s", "Overflow"),
        // java ⚠️ 10000000000: its double rounds the nines up.
        .ok("a = 9.9999999999999999999999999999999999999999 s", "9999999999"),
        .ok("a = 5 μs", "InvalidCharacter"),
    });
}

// Zig only — reading what was read. Stored in nanoseconds, read in any unit,
// the long names too (decl literals: `.weeks` is `Unit.weeks`, which is `.w`).
test "units.a duration read in any unit" {
    const d: Duration = .of(90, .minutes);
    try testing.expectEqual(1.5, d.as(.h));
    try testing.expectEqual(1, d.whole(.hours));
    try testing.expectEqual(5400, d.whole(.s));
    try testing.expectEqual(90, d.whole(.m));
    try testing.expectEqual(1.5 / 168.0, d.as(.weeks));
    try testing.expectEqual(0, d.whole(.weeks));
    try testing.expectEqual(std.Io.Duration.fromSeconds(5400), d.toIo());
    // Cut toward zero, below zero too.
    try testing.expectEqual(-1, Duration.of(-90, .min).whole(.h));
    // More than an i64 holds is the nearest one, not a panic.
    const long: Duration = .of(200000, .d);
    try testing.expectEqual(std.math.maxInt(i64), long.whole(.ns));
    try testing.expectEqual(200000, long.whole(.days));
}

// Zig only — the largest unit that says it exactly, a name a config can say.
test "units.a duration is written in the largest exact unit" {
    try expectFormat(Duration.of(90, .s), "90s");
    try expectFormat(Duration.of(120, .min), "2h");
    try expectFormat(Duration.of(90, .min), "90m");
    try expectFormat(Duration.of(1500, .ms), "1500ms");
    try expectFormat(Duration.of(2, .w), "14d");
    try expectFormat(Duration.of(-3, .s), "-3s");
    try expectFormat(Duration.of(1, .ns), "1ns");
    try expectFormat(Duration.of(0, .h), "0s");
}
