//! zig-hocon side of tools/bench/run.sh: median time to parse each file.
//!
//!   zig build bench -Doptimize=ReleaseFast && zig-out/bin/hocon-bench <file>...
//!
//! Prints `<file>\t<median ns>\t<runs>` per file. One untimed run first, then it
//! runs until a second has passed and at least five runs are in. Every run
//! parses into `hocon.Value` with a fresh arena, so allocation is in the number,
//! the same way the Java and Python sides build their object tree each time.

const std = @import("std");
const hocon = @import("hocon");

var stdout_buffer: [4096]u8 = undefined;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    for (args[1..]) |path| {
        const source = try std.Io.Dir.cwd().readFileAllocOptions(io, path, arena, .limited(1 << 30), .of(u8), 0);

        var times: std.ArrayList(u64) = .empty;
        defer times.deinit(gpa);
        _ = try parseOnce(gpa, source);

        var total: u64 = 0;
        while (times.items.len < 5 or total < std.time.ns_per_s) {
            const start = std.Io.Clock.awake.now(io);
            _ = try parseOnce(gpa, source);
            const t: u64 = @intCast(start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds);
            try times.append(gpa, t);
            total += t;
        }
        std.mem.sort(u64, times.items, {}, std.sort.asc(u64));
        try stdout.print("{s}\t{d}\t{d}\n", .{ path, times.items[times.items.len / 2], times.items.len });
        try stdout.flush();
    }
}

fn parseOnce(gpa: std.mem.Allocator, source: [:0]const u8) !usize {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const value = try hocon.parseFromSliceLeaky(hocon.Value, arena.allocator(), source);
    std.mem.doNotOptimizeAway(&value);
    return value.object.len;
}
