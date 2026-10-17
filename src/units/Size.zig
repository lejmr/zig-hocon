//! A size in bytes.
//!
//! In a config: `B`, `kB`…`YB` (powers of 1000), `K`/`KiB`…`Y`/`YiB` (powers
//! of 1024) and their long forms (spec L1335). A number with no unit is bytes.
//! Zetta and yotta are there, but anything that big is more than a u64 holds.

const std = @import("std");
const testing = std.testing;
const Value = @import("../Value.zig").Value;
const parse = @import("parse.zig");

const Size = @This();

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
pub fn fromValue(value: Value) parse.Error!Size {
    const text = try parse.split(value);
    const unit = if (text.unit.len == 0) 1 else names.get(text.unit) orelse return error.UnknownUnit;
    const bytes = try parse.times(text.number, unit);
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const expectReads = parse.expectReads;
const expectFormat = parse.expectFormat;

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

// Zig only — the largest unit that says it exactly, a name a config can say.
test "units.a size is written in the largest exact unit" {
    try expectFormat(Size.of(512, .MiB), "512MiB");
    try expectFormat(Size.of(10, .kB), "10kB");
    try expectFormat(Size.of(1024, .kB), "1000KiB");
    try expectFormat(Size.of(4097, .B), "4097B");
    try expectFormat(Size.of(0, .B), "0B");
    try expectFormat(Size{ .bytes = std.math.maxInt(u64) }, "18446744073709551615B");
}
