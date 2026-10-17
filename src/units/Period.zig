//! A length of time on the calendar, as `java.time.Period` has it: a month and
//! a year have no fixed length, so they are kept apart from the days.
//!
//! In a config: `d w m mo y` and their long forms, lowercase only (spec L1315),
//! `m` being months. A number with no unit is days. Weeks are kept as days.

const std = @import("std");
const testing = std.testing;
const Value = @import("../Value.zig").Value;
const parse = @import("parse.zig");
const Duration = @import("Duration.zig");

const Period = @This();

years: i32 = 0,
months: i32 = 0,
days: i32 = 0,

pub const Unit = enum {
    d,
    w,
    mo,
    y,

    pub const day: Unit = .d;
    pub const days: Unit = .d;
    pub const week: Unit = .w;
    pub const weeks: Unit = .w;
    pub const m: Unit = .mo;
    pub const month: Unit = .mo;
    pub const months: Unit = .mo;
    pub const year: Unit = .y;
    pub const years: Unit = .y;
};

/// Exactly the unit names the spec lists for a period.
const names = std.StaticStringMap(Unit).initComptime(.{
    .{ "d", .d },     .{ "day", .d },  .{ "days", .d },  .{ "w", .w },      .{ "week", .w },
    .{ "weeks", .w }, .{ "m", .mo },   .{ "mo", .mo },   .{ "month", .mo }, .{ "months", .mo },
    .{ "y", .y },     .{ "year", .y }, .{ "years", .y },
});

/// `n` of `unit`; weeks become days.
pub fn of(n: i32, unit: Unit) Period {
    return switch (unit) {
        .d => .{ .days = n },
        .w => .{ .days = n * 7 },
        .mo => .{ .months = n },
        .y => .{ .years = n },
    };
}

/// The same length as a `Duration`, which needs it to have no months and no
/// years: how long those are depends on where on the calendar they start.
pub fn toDuration(self: Period) error{NotExact}!Duration {
    if (self.years != 0 or self.months != 0) return error.NotExact;
    return .of(self.days, .d);
}

/// A string or a number in the units format; a number alone is days. The
/// number is a whole one, as java has it: half a month is no period.
pub fn fromValue(value: Value) parse.Error!Period {
    const text = try parse.split(value);
    const unit = if (text.unit.len == 0) .d else names.get(text.unit) orelse return error.UnknownUnit;
    const n = try std.fmt.parseInt(i32, text.number, 10);
    if (unit == .w) return .{ .days = try std.math.mul(i32, n, 7) };
    return .of(n, unit);
}

/// `2y`, `3mo`, `2w`, `10d`: one number and the largest unit that says it.
/// Years and months together are written as months (`14mo`), the same
/// length. With days besides there is no unit that says it, so it is
/// written as java prints a period, `P1Y2M3D`, which does not read back.
pub fn format(self: Period, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (self.years == 0 and self.months == 0 and self.days == 0) return w.writeAll("0d");
    if (self.days == 0) {
        if (self.months == 0) return w.print("{d}y", .{self.years});
        return w.print("{d}mo", .{@as(i64, self.years) * 12 + self.months});
    }
    if (self.years != 0 or self.months != 0) return self.writeJava(w);
    if (@rem(self.days, 7) == 0) return w.print("{d}w", .{@divExact(self.days, 7)});
    return w.print("{d}d", .{self.days});
}

/// As `java.time.Period` prints it: `P1Y2M3D`, the parts that are 0 left
/// out, and `P0D` when all of them are.
pub fn writeJava(self: Period, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (self.years == 0 and self.months == 0 and self.days == 0) return w.writeAll("P0D");
    try w.writeByte('P');
    if (self.years != 0) try w.print("{d}Y", .{self.years});
    if (self.months != 0) try w.print("{d}M", .{self.months});
    if (self.days != 0) try w.print("{d}D", .{self.days});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const expectReads = parse.expectReads;
const expectFormat = parse.expectFormat;

// period-format · java ✓ · pyhocon – · spec ✓ — pyhocon has no getPeriod.
// Every value row is java's `getPeriod`. The number is a whole one, as in
// java: half a month is no period. Weeks are days, `m` is months.
test "units.a period from the units format" {
    try expectReads(Period, &.{
        .ok("a = 10", "P10D"),
        .ok("a = \"10\"", "P10D"),
        .ok("a = 5d", "P5D"),
        .ok("a = 2 weeks", "P14D"),
        .ok("a = 1m", "P1M"),
        .ok("a = 3 mo", "P3M"),
        .ok("a = 1y", "P1Y"),
        .ok("a = -3 y", "P-3Y"),
        .ok("a = 0", "P0D"),
        .ok("a = 2147483647 d", "P2147483647D"),
        .ok("a = \"5\\u00A0d\"", "P5D"),
        .ok("a = 10D", "UnknownUnit"),
        .ok("a = 3 h", "UnknownUnit"),
        .ok("a = 1.5", "InvalidCharacter"),
        .ok("a = 1e3 d", "InvalidCharacter"),
        .ok("a = 2147483648 d", "Overflow"),
        // java ⚠️ ArithmeticException, an error all the same.
        .ok("a = 400000000 w", "Overflow"),
        // java ⚠️ P1D: `01` is not a JSON number.
        .ok("a = \"01 d\"", "InvalidCharacter"),
    });
}

// Zig only — a period only becomes a duration where it has a fixed length.
test "units.a period to a duration" {
    try testing.expectEqual(Duration.of(14, .d), try Period.of(2, .weeks).toDuration());
    try testing.expectError(error.NotExact, Period.of(3, .mo).toDuration());
    try testing.expectError(error.NotExact, Period.of(1, .y).toDuration());
    try testing.expectEqual(Period{ .days = 14 }, Period.of(2, .w));
    try testing.expectEqual(Period{ .months = 1 }, Period.of(1, .m));
}

// Zig only — the largest unit that says it exactly, a name a config can say.
test "units.a period is written in the largest exact unit" {
    try expectFormat(Period.of(3, .mo), "3mo");
    try expectFormat(Period.of(2, .y), "2y");
    try expectFormat(Period.of(2, .w), "2w");
    try expectFormat(Period.of(10, .d), "10d");
    try expectFormat(Period{}, "0d");
    try expectFormat(Period{ .years = 1, .months = 2 }, "14mo");
    try expectFormat(Period{ .years = 1, .months = 2, .days = 3 }, "P1Y2M3D");
    try expectFormat(Period{ .years = 1, .days = 3 }, "P1Y3D");
    try expectFormat(Period{ .months = 2, .days = -3 }, "P2M-3D");
}
