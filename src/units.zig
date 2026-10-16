//! Durations, periods and sizes in bytes: a struct field of one of these types
//! reads text in the units format (spec L1264), `10ms`, `3 mo`, `512K`.
//!
//! HOCON has no such types of its own; the text is a string or a number until
//! something asks for one of these. `fromValue` is that ask, for one value: the
//! struct conversion calls it for a field of the type, and anything holding a
//! `Value` can call it without a struct around it.

const std = @import("std");
const testing = std.testing;
const Value = @import("Value.zig").Value;
const number = @import("utils/number.zig");
const whitespaceLen = @import("Tokenizer.zig").whitespaceLen;

/// What reading one of these types from a value can fail with. A number that
/// is not one is `InvalidCharacter`, as for an integer field; a unit name the
/// family does not have is `UnknownUnit`.
pub const Error = error{ TypeMismatch, Unresolved, InvalidCharacter, UnknownUnit, Overflow };

/// An exact length of time, in nanoseconds like `std.Io.Duration`.
///
/// In a config: `ns us ms s m h d` and their long forms, lowercase only
/// (spec L1295). A number with no unit is milliseconds.
pub const Duration = struct {
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
    pub fn fromValue(value: Value) Error!Duration {
        const text = try split(value);
        const unit = if (text.unit.len == 0) .ms else names.get(text.unit) orelse return error.UnknownUnit;
        const ns = try times(text.number, @intCast(@intFromEnum(unit)));
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
};

/// A length of time on the calendar, as `java.time.Period` has it: a month and
/// a year have no fixed length, so they are kept apart from the days.
///
/// In a config: `d w m mo y` and their long forms, lowercase only (spec L1315),
/// `m` being months. A number with no unit is days. Weeks are kept as days.
pub const Period = struct {
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
    pub fn fromValue(value: Value) Error!Period {
        const text = try split(value);
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
    fn writeJava(self: Period, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.years == 0 and self.months == 0 and self.days == 0) return w.writeAll("P0D");
        try w.writeByte('P');
        if (self.years != 0) try w.print("{d}Y", .{self.years});
        if (self.months != 0) try w.print("{d}M", .{self.months});
        if (self.days != 0) try w.print("{d}D", .{self.days});
    }
};

/// A size in bytes.
///
/// In a config: `B`, `kB`…`YB` (powers of 1000), `K`/`KiB`…`Y`/`YiB` (powers
/// of 1024) and their long forms (spec L1335). A number with no unit is bytes.
/// Zetta and yotta are there, but anything that big is more than a u64 holds.
pub const Size = struct {
    bytes: u64,

    /// For reading a size in any of them. Each one is its number of bytes.
    pub const Unit = enum(u64) {
        B = 1,
        kB = bytes_in.kB,
        MB = bytes_in.MB,
        GB = bytes_in.GB,
        TB = bytes_in.TB,
        PB = bytes_in.PB,
        EB = bytes_in.EB,
        KiB = bytes_in.KiB,
        MiB = bytes_in.MiB,
        GiB = bytes_in.GiB,
        TiB = bytes_in.TiB,
        PiB = bytes_in.PiB,
        EiB = bytes_in.EiB,

        pub const b: Unit = .B;
        pub const byte: Unit = .B;
        pub const bytes: Unit = .B;
        pub const kilobyte: Unit = .kB;
        pub const kilobytes: Unit = .kB;
        pub const megabyte: Unit = .MB;
        pub const megabytes: Unit = .MB;
        pub const gigabyte: Unit = .GB;
        pub const gigabytes: Unit = .GB;
        pub const terabyte: Unit = .TB;
        pub const terabytes: Unit = .TB;
        pub const petabyte: Unit = .PB;
        pub const petabytes: Unit = .PB;
        pub const exabyte: Unit = .EB;
        pub const exabytes: Unit = .EB;
        pub const K: Unit = .KiB;
        pub const k: Unit = .KiB;
        pub const Ki: Unit = .KiB;
        pub const kibibyte: Unit = .KiB;
        pub const kibibytes: Unit = .KiB;
        pub const M: Unit = .MiB;
        pub const m: Unit = .MiB;
        pub const Mi: Unit = .MiB;
        pub const mebibyte: Unit = .MiB;
        pub const mebibytes: Unit = .MiB;
        pub const G: Unit = .GiB;
        pub const g: Unit = .GiB;
        pub const Gi: Unit = .GiB;
        pub const gibibyte: Unit = .GiB;
        pub const gibibytes: Unit = .GiB;
        pub const T: Unit = .TiB;
        pub const t: Unit = .TiB;
        pub const Ti: Unit = .TiB;
        pub const tebibyte: Unit = .TiB;
        pub const tebibytes: Unit = .TiB;
        pub const P: Unit = .PiB;
        pub const p: Unit = .PiB;
        pub const Pi: Unit = .PiB;
        pub const pebibyte: Unit = .PiB;
        pub const pebibytes: Unit = .PiB;
        pub const E: Unit = .EiB;
        pub const e: Unit = .EiB;
        pub const Ei: Unit = .EiB;
        pub const exbibyte: Unit = .EiB;
        pub const exbibytes: Unit = .EiB;
    };

    /// How many bytes each unit of the spec is. Zetta and yotta are more than a
    /// u64, so these are integers of any size, as big as the table needs.
    const bytes_in = struct {
        const kB = 1000;
        const MB = 1000 * kB;
        const GB = 1000 * MB;
        const TB = 1000 * GB;
        const PB = 1000 * TB;
        const EB = 1000 * PB;
        const ZB = 1000 * EB;
        const YB = 1000 * ZB;
        const KiB = 1024;
        const MiB = 1024 * KiB;
        const GiB = 1024 * MiB;
        const TiB = 1024 * GiB;
        const PiB = 1024 * TiB;
        const EiB = 1024 * PiB;
        const ZiB = 1024 * EiB;
        const YiB = 1024 * ZiB;
    };

    /// Exactly the unit names the spec lists for a size, each with its number
    /// of bytes. A u128, so zetta and yotta fit: `0.5 ZB` is a u64 of bytes.
    const names = std.StaticStringMap(u128).initComptime(.{
        .{ "B", 1 },                    .{ "b", 1 },                    .{ "byte", 1 },                .{ "bytes", 1 },
        .{ "kB", bytes_in.kB },         .{ "kilobyte", bytes_in.kB },   .{ "kilobytes", bytes_in.kB }, .{ "MB", bytes_in.MB },
        .{ "megabyte", bytes_in.MB },   .{ "megabytes", bytes_in.MB },  .{ "GB", bytes_in.GB },        .{ "gigabyte", bytes_in.GB },
        .{ "gigabytes", bytes_in.GB },  .{ "TB", bytes_in.TB },         .{ "terabyte", bytes_in.TB },  .{ "terabytes", bytes_in.TB },
        .{ "PB", bytes_in.PB },         .{ "petabyte", bytes_in.PB },   .{ "petabytes", bytes_in.PB }, .{ "EB", bytes_in.EB },
        .{ "exabyte", bytes_in.EB },    .{ "exabytes", bytes_in.EB },   .{ "ZB", bytes_in.ZB },        .{ "zettabyte", bytes_in.ZB },
        .{ "zettabytes", bytes_in.ZB }, .{ "YB", bytes_in.YB },         .{ "yottabyte", bytes_in.YB }, .{ "yottabytes", bytes_in.YB },
        .{ "K", bytes_in.KiB },         .{ "k", bytes_in.KiB },         .{ "Ki", bytes_in.KiB },       .{ "KiB", bytes_in.KiB },
        .{ "kibibyte", bytes_in.KiB },  .{ "kibibytes", bytes_in.KiB }, .{ "M", bytes_in.MiB },        .{ "m", bytes_in.MiB },
        .{ "Mi", bytes_in.MiB },        .{ "MiB", bytes_in.MiB },       .{ "mebibyte", bytes_in.MiB }, .{ "mebibytes", bytes_in.MiB },
        .{ "G", bytes_in.GiB },         .{ "g", bytes_in.GiB },         .{ "Gi", bytes_in.GiB },       .{ "GiB", bytes_in.GiB },
        .{ "gibibyte", bytes_in.GiB },  .{ "gibibytes", bytes_in.GiB }, .{ "T", bytes_in.TiB },        .{ "t", bytes_in.TiB },
        .{ "Ti", bytes_in.TiB },        .{ "TiB", bytes_in.TiB },       .{ "tebibyte", bytes_in.TiB }, .{ "tebibytes", bytes_in.TiB },
        .{ "P", bytes_in.PiB },         .{ "p", bytes_in.PiB },         .{ "Pi", bytes_in.PiB },       .{ "PiB", bytes_in.PiB },
        .{ "pebibyte", bytes_in.PiB },  .{ "pebibytes", bytes_in.PiB }, .{ "E", bytes_in.EiB },        .{ "e", bytes_in.EiB },
        .{ "Ei", bytes_in.EiB },        .{ "EiB", bytes_in.EiB },       .{ "exbibyte", bytes_in.EiB }, .{ "exbibytes", bytes_in.EiB },
        .{ "Z", bytes_in.ZiB },         .{ "z", bytes_in.ZiB },         .{ "Zi", bytes_in.ZiB },       .{ "ZiB", bytes_in.ZiB },
        .{ "zebibyte", bytes_in.ZiB },  .{ "zebibytes", bytes_in.ZiB }, .{ "Y", bytes_in.YiB },        .{ "y", bytes_in.YiB },
        .{ "Yi", bytes_in.YiB },        .{ "YiB", bytes_in.YiB },       .{ "yobibyte", bytes_in.YiB }, .{ "yobibytes", bytes_in.YiB },
    });

    /// `n` of `unit`. Too many for a u64 is a panic, not an error: it is
    /// written in code.
    pub fn of(n: u64, unit: Unit) Size {
        return .{ .bytes = n * @intFromEnum(unit) };
    }

    /// How many of `unit` it is, fractions included.
    pub fn as(self: Size, unit: Unit) f64 {
        return @as(f64, @floatFromInt(self.bytes)) / @as(f64, @floatFromInt(@intFromEnum(unit)));
    }

    /// How many whole `unit`s it is, cut down.
    pub fn whole(self: Size, unit: Unit) u64 {
        return self.bytes / @intFromEnum(unit);
    }

    /// A string or a number in the units format; a number alone is bytes.
    pub fn fromValue(value: Value) Error!Size {
        const text = try split(value);
        const unit = if (text.unit.len == 0) 1 else names.get(text.unit) orelse return error.UnknownUnit;
        const bytes = try times(text.number, unit);
        return .{ .bytes = std.math.cast(u64, bytes) orelse return error.Overflow };
    }

    /// The largest unit it is a whole number of, `512MiB`, `10kB`, `4097B`.
    pub fn format(self: Size, w: *std.Io.Writer) std.Io.Writer.Error!void {
        // Largest first: 1024ⁿ is more than 1000ⁿ.
        const largest = [_]Unit{ .EiB, .EB, .PiB, .PB, .TiB, .TB, .GiB, .GB, .MiB, .MB, .KiB, .kB };
        for (largest) |unit| {
            if (self.bytes != 0 and self.bytes % @intFromEnum(unit) == 0) {
                return w.print("{d}{t}", .{ self.bytes / @intFromEnum(unit), unit });
            }
        }
        return w.print("{d}B", .{self.bytes});
    }
};

/// A number and a unit name, as the units format writes them (spec L1264):
/// whitespace, a number, whitespace, the name in letters, whitespace, every
/// one of them but the number optional. The name is the letters at the end, so
/// `1e3` is a number but `5e` is 5 of `e`; `unit` is empty when there are none.
/// The number is JSON's, as anywhere in HOCON: not `.5`, `01` or `+1`.
fn split(value: Value) Error!struct { number: []const u8, unit: []const u8 } {
    switch (value) {
        .scalar => |s| {
            if (!s.quoted and std.mem.eql(u8, s.value, "null")) return error.TypeMismatch;
            const text = trim(s.value);
            var start = text.len;
            while (start > 0 and std.ascii.isAlphabetic(text[start - 1])) start -= 1;
            const n = trim(text[0..start]);
            if (!number.isJsonNumber(n)) return error.InvalidCharacter;
            return .{ .number = n, .unit = text[start..] };
        },
        .array, .object => return error.TypeMismatch,
        .ref, .pending, .stack => return error.Unresolved,
    }
}

/// `text` without the whitespace at either end: HOCON's, so a no-break space
/// counts, and a newline too.
fn trim(text: []const u8) []const u8 {
    var s = text;
    while (s.len > 0) {
        const n = if (s[0] == '\n') 1 else whitespaceLen(s);
        if (n == 0) break;
        s = s[n..];
    }
    while (s.len > 0) {
        // Back to where the last character starts: past its continuation bytes.
        var last = s.len - 1;
        while (last > 0 and s[last] & 0b1100_0000 == 0b1000_0000) last -= 1;
        const n = if (s[last] == '\n') 1 else whitespaceLen(s[last..]);
        if (n != s.len - last) break;
        s = s[0..last];
    }
    return s;
}

/// The number in `text`, a JSON number, times `factor`, cut toward zero.
/// Exact, with no floats and any number of digits: `0.3 s` is 300000000ns and
/// `1.1 EB` 1100000000000000000 bytes, as java has them.
fn times(text: []const u8, factor: u128) Error!i128 {
    const negative = text[0] == '-';
    const end = std.mem.indexOfAny(u8, text, "eE") orelse text.len;
    // The digits, and the point among them if there is one.
    const digits = text[@intFromBool(negative)..end];
    const dot = std.mem.indexOfScalar(u8, digits, '.') orelse digits.len;
    // An exponent too big for an i32 is as good as the biggest one: the
    // number is 0 or more than any unit holds either way.
    const exponent: i32 = if (end == text.len) 0 else std.fmt.parseInt(i32, text[end + 1 ..], 10) catch
        if (text[end + 1] == '-') std.math.minInt(i32) else std.math.maxInt(i32);
    // How many digits are before the point once the exponent moved it.
    const point = @as(i64, @intCast(dot)) + exponent;

    // Before the point: the digits there, then zeros up to it.
    var whole: u128 = 0;
    var place: i64 = 0;
    for (digits) |c| {
        if (c == '.') continue;
        if (place < point) whole = try std.math.add(u128, try std.math.mul(u128, whole, 10), c - '0');
        place += 1;
    }
    // `whole > 0`: zero stays zero, however big the exponent.
    while (place < point and whole > 0) : (place += 1) whole = try std.math.mul(u128, whole, 10);

    // After the point, times `factor`: from the last digit back, each step a
    // tenth of the digit and what follows it. Cut at every step, it is cut the
    // same as the whole fraction at once, and it stays below `factor`.
    var fraction: u128 = 0;
    var i = digits.len;
    while (i > 0) {
        i -= 1;
        // Where the digit is, the point not counted.
        const at: i64 = @intCast(if (i > dot) i - 1 else i);
        if (at < point) break;
        if (digits[i] != '.') fraction = (fraction + (digits[i] - '0') * factor) / 10;
    }
    // The zeros between the point and the first digit, if it moved left of it.
    var zeros = point;
    while (zeros < 0 and fraction > 0) : (zeros += 1) fraction /= 10;

    const sum = try std.math.add(u128, try std.math.mul(u128, whole, factor), fraction);
    const magnitude = std.math.cast(i128, sum) orelse return error.Overflow;
    return if (negative) -magnitude else magnitude;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Config = @import("Config.zig").Config;
const table = @import("table.zig");

/// Each row is a document with `a` in it, read into `struct { a: T }`. What
/// came out is written the way `tools/oracle/hocon-java` prints `as:duration:`,
/// `as:period:` and `as:bytes:` (nanoseconds, `P1Y2M3D`, bytes), so a row is
/// checked against java by feeding it the same line; an error is its name.
fn expectReads(comptime T: type, cases: []const table.Case) !void {
    return table.expectAll(cases, .{ .dump = struct {
        fn dump(gpa: std.mem.Allocator, in: [:0]const u8) anyerror![]u8 {
            const got = Config.parseFromSliceLeaky(struct { a: T }, gpa, in, .{}) catch |err| {
                return std.fmt.allocPrint(gpa, "{t}", .{err});
            };
            if (T == Duration) return std.fmt.allocPrint(gpa, "{d}", .{got.a.nanoseconds});
            if (T == Size) return std.fmt.allocPrint(gpa, "{d}", .{got.a.bytes});
            var out: std.Io.Writer.Allocating = .init(gpa);
            try got.a.writeJava(&out.writer);
            return out.toOwnedSlice();
        }
    }.dump });
}

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

// size-in-bytes-format · java ✓ · pyhocon – · spec ✓ — pyhocon has no
// getBytes. Every value row is java's `getBytes`, exact like java's BigDecimal
// and cut toward zero. Zetta and yotta are units, too big for a u64 but at a
// fraction.
test "units.a size from the units format" {
    try expectReads(Size, &.{
        .ok("a = 10", "10"),
        .ok("a = 5 bytes", "5"),
        .ok("a = 128K", "131072"),
        .ok("a = 1.5 KiB", "1536"),
        .ok("a = 0.1 kB", "100"),
        .ok("a = 1.1 EB", "1100000000000000000"),
        .ok("a = 7.99 EiB", "9211842821808707338"),
        .ok("a = 0.000001 ZB", "1000000000000000"),
        .ok("a = \"5E\"", "5764607523034234880"),
        .ok("a = 1e3", "1000"),
        .ok("a = 1e-3 KiB", "1"),
        .ok("a = 1.9", "1"),
        .ok("a = 0.5", "0"),
        .ok("a = 1.0000000000000000000000000000000000 MB", "1000000"),
        .ok("a = 1.0000000000000000000000000000000000000000 B", "1"),
        .ok("a = 0.50000000000000000000000000000000000000000 KiB", "512"),
        .ok("a = \"0.0000000000001234567890123456 YiB\"", "149250099843"),
        .ok("a = \"0.00000100000000000000000 YiB\"", "1208925819614629174"),
        .ok("a = 0e99999999999", "0"),
        .ok("a = 1Kb", "UnknownUnit"),
        .ok("a = 1kb", "UnknownUnit"),
        .ok("a = 1 ZB", "Overflow"),
        .ok("a = \"1e3e\"", "Overflow"),
        // A negative size: java has an error of its own for it.
        .ok("a = -5", "Overflow"),
    });
}

// java ⚠️ out of range: java's getBytes is a signed long, and 8 EiB is one more
// than it holds; the bare number past it java reads as a double and saturates
// to 9223372036854775807. A u64 holds up to 16 EiB less one byte.
test "units.a size java's long cannot hold" {
    try expectReads(Size, &.{
        .ok("a = 8 EiB", "9223372036854775808"),
        .ok("a = 18446744073709551615", "18446744073709551615"),
        .ok("a = 16 EiB", "Overflow"),
    });
}

/// Reads the suite file `in` names from disk and every key in it as the unit
/// its folder is about: `ns=5 nano=5 …`, an error by its name.
fn dumpSuiteFile(gpa: std.mem.Allocator, in: [:0]const u8) anyerror![]u8 {
    const path = try std.fmt.allocPrint(gpa, "conformance/suite/{s}", .{in});
    const parsed = try Config.parseFromFile(Value, gpa, testing.io, path, .{});
    var out: std.Io.Writer.Allocating = .init(gpa);
    for (parsed.value.object, 0..) |m, i| {
        if (i > 0) try out.writer.writeByte(' ');
        try out.writer.print("{s}=", .{m.key.value});
        if (std.mem.startsWith(u8, in, "period-format/")) {
            if (Period.fromValue(m.value)) |p| try p.writeJava(&out.writer) else |err| try out.writer.print("{t}", .{err});
        } else if (std.mem.startsWith(u8, in, "size-in-bytes-format/")) {
            if (Size.fromValue(m.value)) |b| try out.writer.print("{d}", .{b.bytes}) else |err| try out.writer.print("{t}", .{err});
        } else {
            if (Duration.fromValue(m.value)) |d| try out.writer.print("{d}", .{d.nanoseconds}) else |err| try out.writer.print("{t}", .{err});
        }
    }
    return out.toOwnedSlice();
}

// The conformance suite's files for the units format, read from disk, every key
// as the unit of its folder (units-format as durations). The suite itself can
// only check that the text stays text, as JSON output has no duration; this is
// what the text means. java ✓ on every key (`as:…` per key) · pyhocon – · spec ✓
test "units.the suite's unit files, each key read as its unit" {
    try table.expectAll(&.{
        .ok("duration-format/001-bare-number-is-milliseconds.conf", "t=10000000"),
        .ok("duration-format/002-uppercase-unit-is-illegal.conf", "t=UnknownUnit"),
        .ok("duration-format/003-nanoseconds-spellings.conf", "ns=5 nano=5 nanos=5 nanosecond=5 nanoseconds=5"),
        .ok("duration-format/004-microseconds-spellings.conf", "us=5000 micro=5000 micros=5000 microsecond=5000 microseconds=5000"),
        .ok("duration-format/005-milliseconds-spellings.conf", "ms=5000000 milli=5000000 millis=5000000 millisecond=5000000 milliseconds=5000000"),
        .ok("duration-format/006-seconds-spellings.conf", "s=5000000000 second=5000000000 seconds=5000000000"),
        .ok("duration-format/007-minutes-spellings.conf", "m=300000000000 minute=300000000000 minutes=300000000000"),
        .ok("duration-format/008-hours-spellings.conf", "h=18000000000000 hour=18000000000000 hours=18000000000000"),
        .ok("duration-format/009-days-spellings.conf", "d=432000000000000 day=432000000000000 days=432000000000000"),
        .ok("period-format/001-bare-number-is-days.conf", "p=P10D"),
        .ok("period-format/002-uppercase-unit-is-illegal.conf", "p=UnknownUnit"),
        .ok("period-format/003-days-spellings.conf", "d=P5D day=P5D days=P5D"),
        .ok("period-format/004-weeks-spellings.conf", "w=P35D week=P35D weeks=P35D"),
        .ok("period-format/005-months-spellings.conf", "m=P5M mo=P5M month=P5M months=P5M"),
        .ok("period-format/006-years-spellings.conf", "y=P5Y year=P5Y years=P5Y"),
        .ok("period-format/007-month-m-ambiguous-with-duration-minutes.conf", "p=P1M"),
        .ok("size-in-bytes-format/001-bare-number-is-bytes.conf", "s=10"),
        .ok("size-in-bytes-format/002-single-byte-spellings.conf", "B=5 b=5 byte=5 bytes=5"),
        .ok("size-in-bytes-format/003-powers-of-ten-suffixes.conf", "kB=5000 kilobyte=5000 kilobytes=5000 " ++
            "MB=5000000 megabyte=5000000 megabytes=5000000 " ++
            "GB=5000000000 gigabyte=5000000000 gigabytes=5000000000 " ++
            "TB=5000000000000 terabyte=5000000000000 terabytes=5000000000000 " ++
            "PB=5000000000000000 petabyte=5000000000000000 petabytes=5000000000000000 " ++
            "EB=5000000000000000000 exabyte=5000000000000000000 exabytes=5000000000000000000 " ++
            "ZB=Overflow zettabyte=Overflow zettabytes=Overflow " ++
            "YB=Overflow yottabyte=Overflow yottabytes=Overflow " ++
            "s=UnknownUnit"),
        .ok("size-in-bytes-format/004-powers-of-two-suffixes.conf", "K=5120 k=5120 Ki=5120 KiB=5120 kibibyte=5120 kibibytes=5120 " ++
            "M=5242880 m=5242880 Mi=5242880 MiB=5242880 mebibyte=5242880 mebibytes=5242880 " ++
            "G=5368709120 g=5368709120 Gi=5368709120 GiB=5368709120 gibibyte=5368709120 gibibytes=5368709120 " ++
            "T=5497558138880 t=5497558138880 Ti=5497558138880 TiB=5497558138880 tebibyte=5497558138880 tebibytes=5497558138880 " ++
            "P=5629499534213120 p=5629499534213120 Pi=5629499534213120 PiB=5629499534213120 pebibyte=5629499534213120 pebibytes=5629499534213120 " ++
            "E=5764607523034234880 e=5764607523034234880 Ei=5764607523034234880 EiB=5764607523034234880 exbibyte=5764607523034234880 exbibytes=5764607523034234880 " ++
            "Z=Overflow z=Overflow Zi=Overflow ZiB=Overflow zebibyte=Overflow zebibytes=Overflow " ++
            "Y=Overflow y=Overflow Yi=Overflow YiB=Overflow yobibyte=Overflow yobibytes=Overflow"),
        .ok("size-in-bytes-format/019-single-letter-abbreviation-means-powers-of-two.conf", "s=131072"),
        .ok("units-format/001-number-value-is-default-unit.conf", "t=10000000"),
        .ok("units-format/002-quoted-string-with-no-unit-uses-default-unit.conf", "t=10000000"),
        .ok("units-format/003-string-with-unit-name-specifies-interpretation.conf", "t=10000000"),
        .ok("units-format/004-whitespace-optional-around-number-and-unit.conf", "t=10000000"),
        .ok("units-format/005-unit-name-must-be-letters-only.conf", "t=InvalidCharacter"),
        .ok("units-format/006-unit-before-number-is-illegal.conf", "t=InvalidCharacter"),
    }, .{ .dump = dumpSuiteFile });
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

// Zig only — a period only becomes a duration where it has a fixed length.
test "units.a period to a duration" {
    try testing.expectEqual(Duration.of(14, .d), try Period.of(2, .weeks).toDuration());
    try testing.expectError(error.NotExact, Period.of(3, .mo).toDuration());
    try testing.expectError(error.NotExact, Period.of(1, .y).toDuration());
    try testing.expectEqual(Period{ .days = 14 }, Period.of(2, .w));
    try testing.expectEqual(Period{ .months = 1 }, Period.of(1, .m));
}

// Zig only — `K` is 1024, as in the units format, and a decl literal like `.MiB`.
test "units.a size read in any unit" {
    const s: Size = .of(1536, .K);
    try testing.expectEqual(1572864, s.bytes);
    try testing.expectEqual(1.5, s.as(.MiB));
    try testing.expectEqual(1, s.whole(.MiB));
    try testing.expectEqual(1536, s.whole(.kibibytes));
    try testing.expectEqual(1572.864, s.as(.kB));
    try testing.expectEqual(0, s.whole(.GB));
}

// Zig only — `fromValue` is the conversion without a struct around it, for
// whoever holds a `Value` (the C shim of round 3): the same rules, the same
// errors, and a ref that is not resolved is not guessed at.
test "units.fromValue reads one value" {
    const text: Value = .{ .scalar = .{ .value = "1500 ms", .quoted = true } };
    try testing.expectEqual(Duration.of(1500, .ms), try Duration.fromValue(text));
    try testing.expectEqual(Size.of(1500, .MiB), try Size.fromValue(.{ .scalar = .{ .value = "1500M", .quoted = false } }));
    try testing.expectEqual(Period.of(1500, .d), try Period.fromValue(.{ .scalar = .{ .value = "1500", .quoted = false } }));
    try testing.expectError(error.UnknownUnit, Period.fromValue(text));
    try testing.expectError(error.Unresolved, Duration.fromValue(.{ .ref = .{ .path = &.{}, .flags = .{ .optional = false }, .file = 0, .pos = 0 } }));
}

/// How `format` writes `x`, which is how `stringify` writes it.
fn expectFormat(x: anytype, want: []const u8) !void {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try x.format(&w);
    try testing.expectEqualStrings(want, w.buffered());
}

// Zig only — the largest unit that says it exactly, a name a config can say.
test "units.format writes the largest exact unit" {
    try expectFormat(Duration.of(90, .s), "90s");
    try expectFormat(Duration.of(120, .min), "2h");
    try expectFormat(Duration.of(90, .min), "90m");
    try expectFormat(Duration.of(1500, .ms), "1500ms");
    try expectFormat(Duration.of(2, .w), "14d");
    try expectFormat(Duration.of(-3, .s), "-3s");
    try expectFormat(Duration.of(1, .ns), "1ns");
    try expectFormat(Duration.of(0, .h), "0s");
    try expectFormat(Period.of(3, .mo), "3mo");
    try expectFormat(Period.of(2, .y), "2y");
    try expectFormat(Period.of(2, .w), "2w");
    try expectFormat(Period.of(10, .d), "10d");
    try expectFormat(Period{}, "0d");
    try expectFormat(Period{ .years = 1, .months = 2 }, "14mo");
    try expectFormat(Period{ .years = 1, .months = 2, .days = 3 }, "P1Y2M3D");
    try expectFormat(Period{ .years = 1, .days = 3 }, "P1Y3D");
    try expectFormat(Period{ .months = 2, .days = -3 }, "P2M-3D");
    try expectFormat(Size.of(512, .MiB), "512MiB");
    try expectFormat(Size.of(10, .kB), "10kB");
    try expectFormat(Size.of(1024, .kB), "1000KiB");
    try expectFormat(Size.of(4097, .B), "4097B");
    try expectFormat(Size.of(0, .B), "0B");
    try expectFormat(Size{ .bytes = std.math.maxInt(u64) }, "18446744073709551615B");
}
