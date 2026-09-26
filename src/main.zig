//! `hocon <file.conf>` — parses a HOCON file and prints it as compact JSON.
//!
//! Exit 0 with the JSON on stdout, or exit 1 with the reason on stderr. That is
//! also the whole contract of a conformance adapter (conformance/adapters/), so
//! this binary is what `conformance/run.sh` measures.

const std = @import("std");
const hocon = @import("hocon");

const usage = "usage: hocon <file.conf>";

var stdout_buffer: [4096]u8 = undefined;

pub fn main(init: std.process.Init) !void {
    // A one-shot process: everything goes to the process arena and is dropped
    // on exit, which is what the Leaky variant is for.
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) std.process.fatal("{s}", .{usage});
    const path = args[1];

    const source = std.Io.Dir.cwd().readFileAllocOptions(io, path, arena, .limited(64 * 1024 * 1024), .of(u8), 0) catch |err|
        std.process.fatal("{s}: {t}", .{ path, err });

    const value = hocon.parseFromSliceLeaky(hocon.Value, arena, source) catch |err|
        std.process.fatal("{s}: {t}", .{ path, err });

    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    std.json.Stringify.value(value, .{}, stdout) catch |err|
        std.process.fatal("{s}: {t}", .{ path, err });
    try stdout.writeByte('\n');
    try stdout.flush();
}
