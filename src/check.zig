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
    // Then `--env-file=<file>`s, then the files to check.
    var first: usize = 2;
    while (first < args.len and std.mem.startsWith(u8, args[first], "--env-file=")) first += 1;
    const env_files = try init.arena.allocator().alloc([]const u8, first - 2);
    for (env_files, args[2..first]) |*file, arg| file.* = arg["--env-file=".len..];
    const env: hocon.Value.Env = if (std.mem.eql(u8, args[1], "keep"))
        .keep
    else if (env_files.len > 0)
        .{ .map = withEnvFiles(init.arena.allocator(), init.io, if (std.mem.eql(u8, args[1], "none")) null else init.environ_map, env_files) }
    else if (std.mem.eql(u8, args[1], "none"))
        .none
    else
        .{ .map = init.environ_map };
    // A stdout that is gone, say: one line, as `fatal` prints it.
    const failed = run(T, init.gpa, init.io, args[first..], env) catch |err| std.process.fatal("{t}", .{err});
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

/// `base`, the process environment or null for none, with the `KEY=value`
/// lines of each file over it, a later file over an earlier one. The lines a
/// shell's or docker's env file has, and `zig-hocon-migrate --env-file` reads:
/// blank lines and `#` comments skipped, `export ` before a key, a value in
/// matching quotes taken out of them. A file that cannot be read, or a line
/// with no key, ends the process with where.
pub fn withEnvFiles(arena: std.mem.Allocator, io: std.Io, base: ?*const std.process.Environ.Map, files: []const []const u8) *std.process.Environ.Map {
    const map = arena.create(std.process.Environ.Map) catch std.process.fatal("OutOfMemory", .{});
    map.* = if (base) |b| b.clone(arena) catch std.process.fatal("OutOfMemory", .{}) else .init(arena);
    for (files) |path| {
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err| std.process.fatal("{s}: {t}", .{ path, err });
        var lines = std.mem.splitScalar(u8, text, '\n');
        var n: usize = 0;
        while (lines.next()) |raw| {
            n += 1;
            var line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (std.mem.startsWith(u8, line, "export ")) line = std.mem.trimStart(u8, line["export ".len..], " \t");
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse 0;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            // `put` asserts a key: not empty, no NUL.
            if (key.len == 0 or std.mem.indexOfScalar(u8, key, 0) != null) std.process.fatal("{s}:{d}: not a KEY=value line", .{ path, n });
            var value = line[eq + 1 ..];
            if (value.len >= 2 and value[0] == value[value.len - 1] and (value[0] == '"' or value[0] == '\'')) value = value[1 .. value.len - 1];
            map.put(key, value) catch std.process.fatal("OutOfMemory", .{});
        }
    }
    return map;
}
