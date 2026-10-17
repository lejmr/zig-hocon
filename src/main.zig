//! `hocon [--hocon | --json] [--env=process|none|keep] <file.conf>` — parses a
//! HOCON file, resolves it and prints it as HOCON, or with `--json` as compact
//! JSON. A path that is not in the file reads the process environment, or with
//! `--env=none` nothing; `--env=keep` leaves it as written, for wherever the
//! printed file is read next.
//!
//! Exit 0 with the result on stdout, or exit 1 with the reason on stderr. With
//! `--json` that is the whole contract of a conformance adapter
//! (conformance/adapters/), so this binary is what `conformance/run.sh` measures.

const std = @import("std");
const hocon = @import("hocon");

const usage = "usage: hocon [--hocon | --json] [--env=process|none|keep] <file.conf>";

const Format = enum { json, hocon };
const Env = enum { process, none, keep };

var stdout_buffer: [4096]u8 = undefined;
var stderr_buffer: [1024]u8 = undefined;

pub fn main(init: std.process.Init) !void {
    // A one-shot process: everything goes to the process arena and is dropped
    // on exit, which is what the Leaky variant is for.
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2 or args.len > 4) std.process.fatal("{s}", .{usage});
    const path = args[args.len - 1];
    // A flag is no file name, and nothing is none; `./--json` is one.
    if (path.len == 0 or std.mem.startsWith(u8, path, "--")) std.process.fatal("{s}", .{usage});
    // The flags are the ones before the file, each at most once; without
    // them it is HOCON and the process environment.
    var format: ?Format = null;
    var env: ?Env = null;
    for (args[1 .. args.len - 1]) |arg| {
        if (!std.mem.startsWith(u8, arg, "--")) std.process.fatal("{s}", .{usage});
        if (std.mem.startsWith(u8, arg, "--env=")) {
            if (env != null) std.process.fatal("{s}", .{usage});
            env = std.meta.stringToEnum(Env, arg["--env=".len..]) orelse std.process.fatal("{s}", .{usage});
        } else {
            if (format != null) std.process.fatal("{s}", .{usage});
            format = std.meta.stringToEnum(Format, arg[2..]) orelse std.process.fatal("{s}", .{usage});
        }
    }

    var diag: hocon.Diagnostics = .{};
    // `${PORT}` with no `PORT` in the file reads the process environment.
    const options: hocon.ParseOptions = .{ .diagnostics = &diag, .env = switch (env orelse .process) {
        .process => .{ .map = init.environ_map },
        .none => .none,
        .keep => .keep,
    } };
    const value = hocon.parseFromFileLeaky(hocon.Value, arena, io, path, options) catch {
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
    write(value, format orelse .hocon, &stdout_writer.interface) catch |err| std.process.fatal("{s}: {t}", .{ path, err });
}

fn write(value: hocon.Value, format: Format, w: *std.Io.Writer) !void {
    switch (format) {
        .json => {
            // `--env=keep` left a `${…}` in it, which JSON has no way to write.
            if (!value.isResolved()) return error.WaitsForTheEnvironment;
            // std.json keeps a stack of 256 open lists and objects, and past it
            // panics in a safe build.
            if (depth(value) > 256) return error.TooDeepForJson;
            try std.json.Stringify.value(value, .{}, w);
            try w.writeByte('\n');
        },
        // Ends with a newline of its own.
        .hocon => try hocon.stringify(value, .{}, w),
    }
    try w.flush();
}

/// How many lists and objects deep the tree goes.
fn depth(value: hocon.Value) usize {
    var below: usize = 0;
    switch (value) {
        .array => |items| for (items) |item| {
            below = @max(below, depth(item));
        },
        .object => |members| for (members) |m| {
            below = @max(below, depth(m.value));
        },
        else => return 0,
    }
    return below + 1;
}
