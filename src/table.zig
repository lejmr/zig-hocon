//! The table-test runner shared by `Tokenizer.zig` and `Ast.zig`.
//!
//! Both phases are tested the same way: run one input, render the result as one
//! line of text, compare it with what the oracle says. Only the rendering
//! differs — a token stream for the tokenizer, an s-expression for the parser —
//! so that is the one thing a caller passes in.
const std = @import("std");
const testing = std.testing;

/// One row of a table test: an input and what it should render as. `.err`
/// instead of `.want` says the input must not get that far at all — the dump
/// function returns an error rather than text.
pub const Case = struct {
    in: [:0]const u8,
    want: ?[]const u8 = null,
    err: bool = false,
    focus: bool = false,

    /// `.{ .in = "a = b", .want = "…" }` reads fine, but the shorthands read
    /// better in a long table.
    pub fn ok(in: [:0]const u8, want: []const u8) Case {
        return .{ .in = in, .want = want };
    }
    pub fn bad(in: [:0]const u8) Case {
        return .{ .in = in, .err = true };
    }

    /// Debugging aid: mark a row `.only` and `expectAll` runs that one alone, so
    /// a breakpoint inside the parser fires on the case you care about instead of
    /// once per row. Works on both shapes — `.only(.bad("…"))`.
    pub fn only(c: Case) Case {
        var focused = c;
        focused.focus = true;
        return focused;
    }
};

/// What a caller has to supply: how to turn an input into the one line the table
/// compares against, and optionally something extra to print for a `.only` row.
pub const Options = struct {
    /// Renders `in` into text allocated from `gpa`. The allocator is an arena
    /// that lives exactly as long as the row, so nothing needs freeing.
    /// Returning an error means the input did not get that far — a `.bad` row.
    dump: *const fn (gpa: std.mem.Allocator, in: [:0]const u8) anyerror![]u8,
};

/// Runs every case and only then fails, listing each one as ✓ or ✗.
///
/// A plain `try expect…(…)` chain stops at the first mismatch, so a red test
/// says nothing about the rows below it — which is what makes people comment
/// them out one at a time. This runs all of them, so one run shows exactly which
/// variants work and which do not.
///
/// Nothing is printed while every row passes: `zig build test` reports a passing
/// test that wrote to stderr as a failed command.
pub fn expectAll(cases: []const Case, opts: Options) !void {
    var report = std.Io.Writer.Allocating.init(testing.allocator);
    defer report.deinit();
    const w = &report.writer;

    var focused = false;
    for (cases) |c| focused = focused or c.focus;

    var failures: usize = 0;
    for (cases) |c| {
        if (focused and !c.focus) continue;

        // One arena per row: whatever the dump function allocates on the way to
        // its line of text goes away with the row, so it never has to say who
        // owns what.
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        var got: []const u8 = undefined;
        var dumped = false;
        if (opts.dump(arena.allocator(), c.in)) |text| {
            got = text;
            dumped = true;
        } else |e| {
            got = @errorName(e);
        }

        const passed = if (c.err) !dumped else dumped and std.mem.eql(u8, c.want.?, got);

        try w.writeAll(if (passed) "  \x1b[32m✓\x1b[0m " else "  \x1b[31m✗\x1b[0m ");
        try writeEscaped(w, c.in);
        try w.writeByte('\n');
        if (!passed) {
            failures += 1;
            try w.print("      want {s}\n", .{if (c.err) "an error" else c.want.?});
            try w.print("      got  ", .{});
            try writeEscaped(w, got);
            try w.writeByte('\n');
        }
    }

    // A focused run fails even when the row passes: `.only` skips coverage, so it
    // must be impossible to leave behind in a green test.
    if (focused) {
        std.debug.print("\n{s}  focused on .only — remove it to run the whole table\n", .{report.written()});
        return error.TestFocused;
    }
    if (failures != 0) {
        std.debug.print("\n{s}  {d}/{d} cases failed\n", .{ report.written(), failures, cases.len });
        return error.TestExpectedEqual;
    }
}

/// Writes `s` with its newlines and tabs escaped, so one case stays one line of
/// the report even when the input spans several.
pub fn writeEscaped(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    for (s) |c| switch (c) {
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        '\r' => try w.writeAll("\\r"),
        else => try w.writeByte(c),
    };
}
