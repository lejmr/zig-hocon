//! Why a parse failed and, when the error has one, where.
//!
//! The place is worked out while the parse still has its files: one that fails
//! gives its memory back, the text of every included file with it. So the path
//! and the line are copies, made with the allocator the parse was given, and
//! `deinit` with that allocator frees them.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Diagnostics = @This();

/// The first error the parse ran into. Null while nothing has failed: every
/// parse starts by clearing it. `deinit` first when handing it to another parse,
/// or the copies of the last one are lost.
err: ?anyerror = null,
/// Null for the errors that have no place in a file: OutOfMemory, a file that
/// cannot be read, a missing field, and a value turned into T that does not
/// say where it was written: an empty list or object, a value from a `.json`
/// include.
location: ?Location = null,
/// For an error turning the tree into T: the path of the value it is about,
/// `db.pool` or `ports[1]`, copied like the location. Empty for the others, and
/// for the root.
key_path: []const u8 = "",
/// And what T wanted there: `u16`, `string`, `one of debug, info`. Empty when
/// the error is not about the value's type, as for MissingField.
expected: []const u8 = "",

pub const Location = struct {
    /// The file the error is in, as it was named: the path the parse was given,
    /// or the one an include made of its name. Empty for a slice.
    path: []const u8,
    /// Bytes from the start of that file.
    offset: usize,
    /// 1-based.
    line: usize,
    /// 1-based, counted in code points: `é` and `🦆` are one column each.
    column: usize,
    /// The line the offset is on, as written, without its line ending.
    source_line: []const u8,

    /// The same place with its own copy of the path and the line, so it outlives
    /// the files it came from.
    pub fn dupe(self: Location, gpa: Allocator) Allocator.Error!Location {
        const path = try gpa.dupe(u8, self.path);
        errdefer gpa.free(path);
        return .{
            .path = path,
            .offset = self.offset,
            .line = self.line,
            .column = self.column,
            .source_line = try gpa.dupe(u8, self.source_line),
        };
    }
};

pub fn deinit(self: *Diagnostics, gpa: Allocator) void {
    if (self.location) |loc| {
        gpa.free(loc.path);
        gpa.free(loc.source_line);
    }
    if (self.key_path.len > 0) gpa.free(self.key_path);
    self.* = .{};
}

/// Where `offset` is in `source`, the way `std.zig.Ast.tokenLocation` works it
/// out. The path and the line are slices of what it was given.
pub fn locate(path: []const u8, source: []const u8, offset: usize) Location {
    var at = @min(offset, source.len);
    // The end of the input is on the line after the last one when the file ends
    // with a newline, and that line is empty: there is nothing to show. The end
    // is where the text stops, right after its last character.
    if (at == source.len) {
        while (at > 0 and std.ascii.isWhitespace(source[at - 1])) at -= 1;
    }
    // `\r\n` ends a line as `\n` does, so an error at the `\n` is at the `\r`:
    // the same column as without it, right after the text.
    if (at > 0 and at < source.len and source[at] == '\n' and source[at - 1] == '\r') at -= 1;

    var line: usize = 1;
    var line_start: usize = 0;
    for (source[0..at], 0..) |c, i| {
        if (c == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }

    // A code point is one leading byte and 0-3 continuation bytes `10xxxxxx`,
    // so counting the bytes that are not continuations counts code points. It
    // cannot fail on invalid UTF-8 the way std.unicode would.
    var column: usize = 1;
    for (source[line_start..at]) |c| {
        if (c & 0b1100_0000 != 0b1000_0000) column += 1;
    }

    var line_end = std.mem.indexOfScalarPos(u8, source, at, '\n') orelse source.len;
    if (line_end > line_start and source[line_end - 1] == '\r') line_end -= 1;

    return .{
        .path = path,
        .offset = at,
        .line = line,
        .column = column,
        .source_line = source[line_start..line_end],
    };
}

/// Prints the error the way the zig compiler prints its own: `path:line:col:`,
/// the line, and a caret under the column. Without a position it is the first
/// line alone, `error: Name`. A slice has no path, so `line:col:` is all there is.
/// A conversion error says which value and what it should have been:
/// `error: TypeMismatch at db.pool: expected u8`.
pub fn render(self: Diagnostics, w: *std.Io.Writer) std.Io.Writer.Error!void {
    // Nothing failed, nothing to say.
    const err = self.err orelse return;
    if (self.location) |loc| {
        if (loc.path.len > 0) try w.print("{s}:", .{loc.path});
        try w.print("{d}:{d}: ", .{ loc.line, loc.column });
    }
    try w.print("error: {t}", .{err});
    if (self.key_path.len > 0) try w.print(" at {s}", .{self.key_path});
    if (self.expected.len > 0) try w.print(": expected {s}", .{self.expected});
    try w.writeByte('\n');

    const loc = self.location orelse return;
    // A tab or a stray `\r` would move the text and leave the caret behind, and
    // ESC and the other control characters would steer the terminal, so each
    // prints as one space — the zig compiler does the same for tabs.
    for (loc.source_line) |c| {
        try w.writeByte(if (c < 0x20 or c == 0x7f) ' ' else c);
    }
    try w.writeByte('\n');
    try w.splatByteAll(' ', loc.column - 1);
    try w.writeAll("^\n");
}
