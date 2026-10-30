//! Text in the units format (spec L1264), `10ms`, `3 mo`, `512K`, taken apart
//! into a number and a unit name: what `Duration`, `Period` and `Size` share.
//!
//! HOCON has no such types of its own; the text is a string or a number until
//! something asks for one of these. `fromValue` on each type is that ask, for
//! one value: the struct conversion calls it for a field of the type, and
//! anything holding a `Value` can call it without a struct around it.

const std = @import("std");
const testing = std.testing;
const Value = @import("../Value.zig").Value;
const number = @import("../utils/number.zig");
const whitespaceLen = @import("../Tokenizer.zig").whitespaceLen;
const Duration = @import("Duration.zig");
const Period = @import("Period.zig");
const Size = @import("Size.zig");

/// What reading one of these types from a value can fail with. A number that
/// is not one is `InvalidCharacter`, as for an integer field; a unit name the
/// family does not have is `UnknownUnit`.
pub const Error = error{ TypeMismatch, Unresolved, InvalidCharacter, UnknownUnit, Overflow };

/// A number and a unit name, as the units format writes them (spec L1264):
/// whitespace, a number, whitespace, the name in letters, whitespace, every
/// one of them but the number optional. The name is the letters at the end, so
/// `1e3` is a number but `5e` is 5 of `e`; `unit` is empty when there are none.
/// The number is JSON's, as anywhere in HOCON: not `.5`, `01` or `+1`.
pub fn split(value: Value) Error!struct { number: []const u8, unit: []const u8 } {
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
pub fn times(text: []const u8, factor: u128) Error!i128 {
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

const Config = @import("../Config.zig").Config;
const table = @import("../table.zig");

/// Each row is a document with `a` in it, read into `struct { a: T }`. What
/// came out is written the way `tools/oracle/hocon-java` prints `as:duration:`,
/// `as:period:` and `as:bytes:` (nanoseconds, `P1Y2M3D`, bytes), so a row is
/// checked against java by feeding it the same line; an error is its name.
pub fn expectReads(comptime T: type, cases: []const table.Case) !void {
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
        .ok("duration-format/002-uppercase-unit-stays-a-string.conf", "t=UnknownUnit"),
        .ok("duration-format/003-nanoseconds-spellings.conf", "ns=5 nano=5 nanos=5 nanosecond=5 nanoseconds=5"),
        .ok("duration-format/004-microseconds-spellings.conf", "us=5000 micro=5000 micros=5000 microsecond=5000 microseconds=5000"),
        .ok("duration-format/005-milliseconds-spellings.conf", "ms=5000000 milli=5000000 millis=5000000 millisecond=5000000 milliseconds=5000000"),
        .ok("duration-format/006-seconds-spellings.conf", "s=5000000000 second=5000000000 seconds=5000000000"),
        .ok("duration-format/007-minutes-spellings.conf", "m=300000000000 minute=300000000000 minutes=300000000000"),
        .ok("duration-format/008-hours-spellings.conf", "h=18000000000000 hour=18000000000000 hours=18000000000000"),
        .ok("duration-format/009-days-spellings.conf", "d=432000000000000 day=432000000000000 days=432000000000000"),
        .ok("period-format/001-bare-number-is-days.conf", "p=P10D"),
        .ok("period-format/002-uppercase-unit-stays-a-string.conf", "p=UnknownUnit"),
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
        .ok("units-format/006-unit-before-number-stays-a-string.conf", "t=InvalidCharacter"),
    }, .{ .dump = dumpSuiteFile });
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
pub fn expectFormat(x: anytype, want: []const u8) !void {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try x.format(&w);
    try testing.expectEqualStrings(want, w.buffered());
}
