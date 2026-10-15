//! `hocon <file.conf>` — parses a HOCON file and prints it as compact JSON.
//!
//! Exit 0 with the JSON on stdout, or exit 1 with the reason on stderr. That is
//! also the whole contract of a conformance adapter (conformance/adapters/), so
//! this binary is what `conformance/run.sh` measures.

const std = @import("std");
const hocon = @import("hocon");

const usage = "usage: hocon <file.conf>";

var stdout_buffer: [4096]u8 = undefined;
var stderr_buffer: [1024]u8 = undefined;

pub fn main(init: std.process.Init) !void {
    // A one-shot process: everything goes to the process arena and is dropped
    // on exit, which is what the Leaky variant is for.
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) std.process.fatal("{s}", .{usage});
    const path = args[1];

    var diag: hocon.Diagnostics = .{};
    const value = hocon.parseFromFileLeaky(hocon.Value, arena, io, path, .{ .diagnostics = &diag }) catch {
        // The compiler's own format, caret and all, so editors can jump to it.
        var stderr_writer = std.Io.File.stderr().writerStreaming(io, &stderr_buffer);
        const stderr = &stderr_writer.interface;
        // No place in a file, so no file named by it: say which one was given.
        if (diag.location == null) try stderr.print("{s}: ", .{path});
        try diag.render(stderr);
        try stderr.flush();
        std.process.exit(1);
    };

    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    std.json.Stringify.value(value, .{}, stdout) catch |err|
        std.process.fatal("{s}: {t}", .{ path, err });
    try stdout.writeByte('\n');
    try stdout.flush();
}
