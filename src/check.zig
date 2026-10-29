//! `hocon check`: reads each file the way a program would, and says how it went.
//!
//! Without a schema the files are read into `hocon.Value`, which checks the
//! syntax, the includes, the substitutions and cycles. With `--schema` the same
//! loop runs inside a small program compiled with the user's type, so the files
//! are read into that type, the way the user's own program reads them. That
//! program is built from this file too, which is why it imports nothing but
//! `std` and `hocon`.

const std = @import("std");
const hocon = @import("hocon");

var stdout_buffer: [4096]u8 = undefined;
var stderr_buffer: [4096]u8 = undefined;

/// The `main` of the program `--schema` builds, `T` being the user's type.
/// `hocon check` hands it how to read the environment, then the files.
pub fn main(comptime T: type, init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    // `zig run` sets ZIG_EXE for the program it runs. `process=<it>` is the
    // one the user had, anything else says they had none.
    if (std.mem.startsWith(u8, args[1], "process=")) {
        try init.environ_map.put("ZIG_EXE", args[1]["process=".len..]);
    } else _ = init.environ_map.swapRemove("ZIG_EXE");
    const env: hocon.Value.Env = if (std.mem.eql(u8, args[1], "none"))
        .none
    else if (std.mem.eql(u8, args[1], "keep"))
        .keep
    else
        .{ .map = init.environ_map };
    // A stdout that is gone, say: one line, as `fatal` prints it.
    const failed = run(T, init.gpa, init.io, args[2..], env) catch |err| std.process.fatal("{t}", .{err});
    if (failed > 0) std.process.exit(1);
}

/// Reads each file into T: an error goes to stderr with its place, as the
/// zig compiler prints one, a good file is `<file>: ok` on stdout. At the end,
/// when any failed, `N of M failed`. Returns N.
pub fn run(comptime T: type, gpa: std.mem.Allocator, io: std.Io, files: []const []const u8, env: hocon.Value.Env) !usize {
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    var stderr_writer = std.Io.File.stderr().writerStreaming(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    var failed: usize = 0;
    for (files) |path| {
        var diag: hocon.Diagnostics = .{};
        defer diag.deinit(gpa);
        if (hocon.parseFromFile(T, gpa, io, path, .{ .diagnostics = &diag, .env = env })) |parsed| {
            parsed.deinit();
            try stdout.print("{s}: ok\n", .{path});
            try stdout.flush();
        } else |_| {
            failed += 1;
            try printError(stderr, path, diag);
        }
    }
    if (failed > 0) {
        try stderr.print("{d} of {d} failed\n", .{ failed, files.len });
        try stderr.flush();
    }
    return failed;
}

/// The error of a parse of `path`. With no place in a file and no file the
/// diagnostics name, it says which one it was given.
pub fn printError(w: *std.Io.Writer, path: []const u8, diag: hocon.Diagnostics) !void {
    if (diag.location == null and diag.file.len == 0) try w.print("{s}: ", .{path});
    try diag.render(w);
    try w.flush();
}
