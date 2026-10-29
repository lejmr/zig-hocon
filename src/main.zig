//! `hocon [--hocon | --json] [--env=process|none|keep] <file.conf>` — parses a
//! HOCON file, resolves it and prints it as HOCON, or with `--json` as compact
//! JSON. A path that is not in the file reads the process environment, or with
//! `--env=none` nothing; `--env=keep` leaves it as written, for wherever the
//! printed file is read next.
//!
//! Exit 0 with the result on stdout, or exit 1 with the reason on stderr. With
//! `--json` that is the whole contract of a conformance adapter
//! (conformance/adapters/), so this binary is what `conformance/run.sh` measures.
//!
//! And three commands, which read their files the same way and take the same
//! flags, anywhere among the other arguments:
//!
//! - `hocon get <path> <file.conf>` prints one value: text as it is, for a
//!   shell, anything else as HOCON, or with `--json` as JSON.
//! - `hocon check [--schema <file.zig>:<Type>] <file.conf>...` reads each file,
//!   and with `--schema` into that type, and says which ones fail and where.
//! - `hocon diff <a.conf> <b.conf>` prints what differs between the two, path
//!   by path; exit 1 when anything does, 2 when it cannot tell.
//!
//! A file named like a command is `./get`.

const std = @import("std");
const hocon = @import("hocon");
const check = @import("check.zig");
/// `schema`: whether `check --schema` is built in (build.zig); the wheels'
/// CLI has none.
const build_options = @import("options");

const usage = "usage: hocon [--hocon | --json] [--env=process|none|keep] <file.conf>";
const usage_get = "usage: hocon get [--hocon | --json] [--env=process|none|keep] <path> <file.conf>";
const usage_check = if (build_options.schema)
    "usage: hocon check [--env=process|none|keep] [--schema <file.zig>:<Type>] <file.conf>..."
else
    "usage: hocon check [--env=process|none|keep] <file.conf>...";
const usage_diff = "usage: hocon diff [--json] [--env=process|none|keep] <a.conf> <b.conf>";
/// All four, one under the other, below the `error: ` that `fatal` puts first.
const usage_all = usage ++
    "\n" ++ " " ** 14 ++ usage_get["usage: ".len..] ++
    "\n" ++ " " ** 14 ++ usage_check["usage: ".len..] ++
    "\n" ++ " " ** 14 ++ usage_diff["usage: ".len..];

const Command = enum { get, check, diff };

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
    if (args.len < 2) std.process.fatal("{s}", .{usage_all});
    if (std.meta.stringToEnum(Command, args[1])) |command| return run(init, command, args[2..]) catch |err| {
        // A stdout that is gone, say: one line, as `fatal` prints it.
        std.log.err("{t}", .{err});
        std.process.exit(if (command == .diff) 2 else 1);
    };
    if (args.len > 4) std.process.fatal("{s}", .{usage});
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
        if (diag.location == null and diag.file.len == 0) try stderr.print("{s}: ", .{path});
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

/// What a command was given: each flag at most once, and the other arguments
/// in their order.
const Flags = struct {
    format: ?Format = null,
    env: ?Env = null,
    schema: ?[]const u8 = null,
    rest: std.ArrayList([]const u8) = .empty,
};

fn run(init: std.process.Init, command: Command, args: []const []const u8) !void {
    const arena = init.arena.allocator();
    const command_usage = switch (command) {
        .get => usage_get,
        .check => usage_check,
        .diff => usage_diff,
    };
    var flags: Flags = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        // Nothing is no file name, and no path either.
        if (arg.len == 0) std.process.fatal("{s}", .{command_usage});
        if (!std.mem.startsWith(u8, arg, "--")) {
            try flags.rest.append(arena, arg);
        } else if (std.mem.startsWith(u8, arg, "--env=")) {
            if (flags.env != null) std.process.fatal("{s}", .{command_usage});
            flags.env = std.meta.stringToEnum(Env, arg["--env=".len..]) orelse std.process.fatal("{s}", .{command_usage});
        } else if (build_options.schema and std.mem.eql(u8, arg, "--schema") and command == .check) {
            if (flags.schema != null or i + 1 == args.len) std.process.fatal("{s}", .{command_usage});
            i += 1;
            flags.schema = args[i];
        } else {
            if (flags.format != null) std.process.fatal("{s}", .{command_usage});
            flags.format = std.meta.stringToEnum(Format, arg[2..]) orelse std.process.fatal("{s}", .{command_usage});
            // `check` prints no document, and `diff` no HOCON.
            if (command == .check or (command == .diff and flags.format == .hocon)) std.process.fatal("{s}", .{command_usage});
        }
    }
    const rest = flags.rest.items;
    const env = flags.env orelse .process;
    switch (command) {
        .get => {
            if (rest.len != 2) std.process.fatal("{s}", .{command_usage});
            try get(init, rest[0], rest[1], flags.format, env);
        },
        .check => {
            if (rest.len == 0) std.process.fatal("{s}", .{command_usage});
            if (comptime build_options.schema) if (flags.schema) |schema| try checkSchema(init, schema, env, rest);
            if (try check.run(hocon.Value, init.gpa, init.io, rest, envOf(init, env)) > 0) std.process.exit(1);
        },
        .diff => {
            if (rest.len != 2) std.process.fatal("{s}", .{command_usage});
            try diff(init, rest[0], rest[1], flags.format, env);
        },
    }
}

fn envOf(init: std.process.Init, env: Env) hocon.Value.Env {
    return switch (env) {
        .process => .{ .map = init.environ_map },
        .none => .none,
        .keep => .keep,
    };
}

/// The file resolved, or null with the reason it is not on stderr.
fn load(init: std.process.Init, path: []const u8, env: Env) !?hocon.Value {
    var diag: hocon.Diagnostics = .{};
    const options: hocon.ParseOptions = .{ .diagnostics = &diag, .env = envOf(init, env) };
    return hocon.parseFromFileLeaky(hocon.Value, init.arena.allocator(), init.io, path, options) catch {
        var stderr_writer = std.Io.File.stderr().writerStreaming(init.io, &stderr_buffer);
        try check.printError(&stderr_writer.interface, path, diag);
        return null;
    };
}

/// `hocon get <path> <file>`. Text comes out bare, so `$(hocon get port
/// app.conf)` is the port; anything else as `write` prints a document.
fn get(init: std.process.Init, text: []const u8, path: []const u8, format: ?Format, env: Env) !void {
    const arena = init.arena.allocator();
    var stderr_writer = std.Io.File.stderr().writerStreaming(init.io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    var diag: hocon.Diagnostics = .{};
    const keys = hocon.parsePath(arena, text, &diag) catch {
        try diag.render(stderr);
        try stderr.flush();
        std.process.exit(1);
    };
    var value = try load(init, path, env) orelse std.process.exit(1);
    for (keys) |key| {
        const members = if (value == .object) value.object else std.process.fatal("no value at '{s}'", .{text});
        value = for (members) |m| {
            if (m.key.eql(key)) break m.value;
        } else std.process.fatal("no value at '{s}'", .{text});
    }

    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    // A stdout that is gone is `<file>: WriteFailed` here as below.
    if (format == null and value == .scalar) {
        stdout.print("{s}\n", .{value.scalar.value}) catch |err| std.process.fatal("{s}: {t}", .{ path, err });
        stdout.flush() catch |err| std.process.fatal("{s}: {t}", .{ path, err });
        return;
    }
    // A key `--env=keep` left set twice, `port = 8080` then `${?PORT}`, is two
    // values until the environment says which: no one document.
    if (value == .stack) std.process.fatal("{s}: WaitsForTheEnvironment", .{path});
    write(value, format orelse .hocon, stdout) catch |err| std.process.fatal("{s}: {t}", .{ path, err });
}

/// The library's own source, built into the binary: `check --schema` compiles a
/// program against it, and an installed `hocon` has no source tree next to it.
/// It is the very library this binary is, so the check reads the files exactly
/// as `hocon` does. A file the library gains goes here too; the end-to-end test
/// of `--schema` fails to compile the program without it.
const library = [_][2][]const u8{
    .{ "hocon/root.zig", @embedFile("root.zig") },
    .{ "hocon/Ast.zig", @embedFile("Ast.zig") },
    .{ "hocon/Config.zig", @embedFile("Config.zig") },
    .{ "hocon/Diagnostics.zig", @embedFile("Diagnostics.zig") },
    .{ "hocon/Include.zig", @embedFile("Include.zig") },
    .{ "hocon/Key.zig", @embedFile("Key.zig") },
    .{ "hocon/Tokenizer.zig", @embedFile("Tokenizer.zig") },
    .{ "hocon/Value.zig", @embedFile("Value.zig") },
    .{ "hocon/Value/Member.zig", @embedFile("Value/Member.zig") },
    .{ "hocon/Value/Ref.zig", @embedFile("Value/Ref.zig") },
    .{ "hocon/Value/Resolver.zig", @embedFile("Value/Resolver.zig") },
    .{ "hocon/Value/Resolver/env.zig", @embedFile("Value/Resolver/env.zig") },
    .{ "hocon/Value/Resolver/keep.zig", @embedFile("Value/Resolver/keep.zig") },
    .{ "hocon/Value/Resolver/stack.zig", @embedFile("Value/Resolver/stack.zig") },
    .{ "hocon/Value/Scalar.zig", @embedFile("Value/Scalar.zig") },
    .{ "hocon/Value/build.zig", @embedFile("Value/build.zig") },
    .{ "hocon/Value/merge.zig", @embedFile("Value/merge.zig") },
    .{ "hocon/stringify.zig", @embedFile("stringify.zig") },
    .{ "hocon/table.zig", @embedFile("table.zig") },
    .{ "hocon/units/Duration.zig", @embedFile("units/Duration.zig") },
    .{ "hocon/units/Period.zig", @embedFile("units/Period.zig") },
    .{ "hocon/units/Size.zig", @embedFile("units/Size.zig") },
    .{ "hocon/units/parse.zig", @embedFile("units/parse.zig") },
    .{ "hocon/utils/number.zig", @embedFile("utils/number.zig") },
    .{ "hocon/utils/unqoute.zig", @embedFile("utils/unqoute.zig") },
    .{ "check.zig", @embedFile("check.zig") },
};

/// `hocon check --schema <file.zig>:<Type>`: compiles a program that is
/// `check.main(@import("schema").Type, …)` with `zig run`, which caches the
/// build, and becomes it. `zig run` in turn becomes the program, so what it
/// prints and its exit code are the check's.
fn checkSchema(init: std.process.Init, schema: []const u8, env: Env, files: []const []const u8) !noreturn {
    const arena = init.arena.allocator();
    const colon = std.mem.lastIndexOfScalar(u8, schema, ':') orelse std.process.fatal("{s}", .{usage_check});
    const file = schema[0..colon];
    const type_name = schema[colon + 1 ..];
    // The name goes into the program's source as it is, so it has to be a name.
    if (file.len == 0 or !isTypeName(type_name)) std.process.fatal("{s}", .{usage_check});
    // Said here as for a .conf, rather than by zig's cache.
    std.Io.Dir.cwd().access(init.io, file, .{}) catch |err| std.process.fatal("{s}: {t}", .{ file, err });

    // `<cache>/zig-hocon/<hash>/`, one directory per library version: a
    // binary built from other sources never reads these.
    var hash = std.hash.Wyhash.init(0);
    for (library) |f| {
        hash.update(f[0]);
        hash.update(f[1]);
    }
    // An empty or relative XDG_CACHE_HOME is none, as the XDG spec has it.
    const xdg = init.environ_map.get("XDG_CACHE_HOME") orelse "";
    const cache = if (std.fs.path.isAbsolute(xdg))
        xdg
    else if (init.environ_map.get("HOME")) |home|
        try std.fs.path.join(arena, &.{ home, ".cache" })
    else
        std.process.fatal("--schema needs HOME or XDG_CACHE_HOME, for its cache", .{});
    const dir = try std.fmt.allocPrint(arena, "{s}/zig-hocon/{x}", .{ cache, hash.final() });
    for (library) |f| writeOnce(init.io, dir, f[0], f[1]) catch |err| std.process.fatal("--schema writes its cache in {s}: {t}", .{ cache, err });
    const main_source = try std.fmt.allocPrint(arena,
        \\pub fn main(init: @import("std").process.Init) !void {{
        \\    return @import("check").main(@import("schema").{s}, init);
        \\}}
        \\
    , .{type_name});
    // Named by what is in it: `Config` and `config` are one file name where
    // the file system ignores case, as macOS does.
    const main_name = try std.fmt.allocPrint(arena, "check-{x}.zig", .{std.hash.Wyhash.hash(0, main_source)});
    writeOnce(init.io, dir, main_name, main_source) catch |err| std.process.fatal("--schema writes its cache in {s}: {t}", .{ cache, err });

    var argv: std.ArrayList([]const u8) = .empty;
    // The program's root needs `check` and `schema`, and both of them `hocon`.
    try argv.appendSlice(arena, &.{ "zig", "run" });
    try argv.appendSlice(arena, &.{ "--dep", "check", "--dep", "schema", try std.fmt.allocPrint(arena, "-Mroot={s}/{s}", .{ dir, main_name }) });
    try argv.appendSlice(arena, &.{ "--dep", "hocon", try std.fmt.allocPrint(arena, "-Mcheck={s}/check.zig", .{dir}) });
    try argv.appendSlice(arena, &.{ "--dep", "hocon", try std.fmt.allocPrint(arena, "-Mschema={s}", .{file}) });
    try argv.appendSlice(arena, &.{try std.fmt.allocPrint(arena, "-Mhocon={s}/hocon/root.zig", .{dir})});
    // With the ZIG_EXE the user had, as `zig run` sets its own (see `check.main`).
    const zig_exe = init.environ_map.get("ZIG_EXE");
    try argv.appendSlice(arena, &.{ "--", if (env == .process and zig_exe != null) try std.fmt.allocPrint(arena, "process={s}", .{zig_exe.?}) else @tagName(env) });
    try argv.appendSlice(arena, files);
    const err = std.process.replace(init.io, .{ .argv = argv.items });
    if (err != error.OperationUnsupported) std.process.fatal("--schema runs zig, from the PATH: {t}", .{err});
    // Windows has no exec: zig runs as a child, and its exit code is ours.
    var child = std.process.spawn(init.io, .{ .argv = argv.items }) catch |e| std.process.fatal("--schema runs zig, from the PATH: {t}", .{e});
    const term = child.wait(init.io) catch |e| std.process.fatal("--schema runs zig, from the PATH: {t}", .{e});
    std.process.exit(switch (term) {
        .exited => |code| code,
        else => 1,
    });
}

/// `Config`, `config.App`: names joined by dots, each one Zig could declare.
fn isTypeName(text: []const u8) bool {
    var names = std.mem.splitScalar(u8, text, '.');
    while (names.next()) |name| {
        if (name.len == 0 or std.ascii.isDigit(name[0])) return false;
        for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

/// `dir/name` with `data` in it, unless it is there already: every name in the
/// cache says what is in it, so one that is there has the same bytes. It
/// appears whole or not at all: another `hocon check` may be reading it right
/// now, as a build runs several at once.
fn writeOnce(io: std.Io, dir: []const u8, name: []const u8, data: []const u8) !void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buffer, "{s}/{s}", .{ dir, name });
    if (std.Io.Dir.cwd().access(io, path, .{})) |_| return else |_| {}
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .make_path = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, data);
    // Someone else's copy got there first: the same bytes.
    atomic.link(io) catch |err| if (err != error.PathAlreadyExists) return err;
}

/// One difference: only `new` when the path was added, only `old` when it
/// went, both when it changed.
const Change = struct { path: []const u8, old: ?hocon.Value, new: ?hocon.Value };

/// `hocon diff <a> <b>`: both files resolved, then compared path by path.
/// Values print as JSON, so `8080` and `"8080"` look as different as they are.
fn diff(init: std.process.Init, a_path: []const u8, b_path: []const u8, format: ?Format, env: Env) !void {
    const arena = init.arena.allocator();
    // Exit 1 says they differ, so trouble is 2, as for diff(1).
    const a = try load(init, a_path, env) orelse std.process.exit(2);
    const b = try load(init, b_path, env) orelse std.process.exit(2);
    for ([_]hocon.Value{ a, b }, [_][]const u8{ a_path, b_path }) |value, path| {
        // `--env=keep` left a `${…}`, which has no value to compare yet. A
        // value is written two below the top of the JSON output, and std.json
        // goes 256 deep (see `write`).
        const refused = if (!value.isResolved()) "WaitsForTheEnvironment" else if (depth(value) > 254) "TooDeepForJson" else continue;
        std.log.err("{s}: {s}", .{ path, refused });
        std.process.exit(2);
    }

    var changes: std.ArrayList(Change) = .empty;
    try compare(arena, &changes, "", a, b);

    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    try writeChanges(changes.items, format orelse .hocon, &stdout_writer.interface);
    if (changes.items.len > 0) std.process.exit(1);
}

/// `~ port: 8080 → 443`, `+ db.host: "x"`, `- feature.beta`, one per line,
/// or with `.json` a list of `{"op", "path", "old", "new"}`.
fn writeChanges(changes: []const Change, format: Format, w: *std.Io.Writer) !void {
    if (format == .json) {
        var jw: std.json.Stringify = .{ .writer = w };
        try jw.beginArray();
        for (changes) |c| {
            try jw.beginObject();
            try jw.objectField("op");
            try jw.write(if (c.old == null) "added" else if (c.new == null) "removed" else "changed");
            try jw.objectField("path");
            try jw.write(c.path);
            if (c.old) |old| {
                try jw.objectField("old");
                try jw.write(old);
            }
            if (c.new) |new| {
                try jw.objectField("new");
                try jw.write(new);
            }
            try jw.endObject();
        }
        try jw.endArray();
        try w.writeByte('\n');
    } else for (changes) |c| {
        if (c.old == null) {
            try w.print("+ {s}: ", .{c.path});
            try std.json.Stringify.value(c.new.?, .{}, w);
        } else if (c.new == null) {
            try w.print("- {s}", .{c.path});
        } else {
            try w.print("~ {s}: ", .{c.path});
            try std.json.Stringify.value(c.old.?, .{}, w);
            try w.writeAll(" → ");
            try std.json.Stringify.value(c.new.?, .{}, w);
        }
        try w.writeByte('\n');
    }
    try w.flush();
}

/// Adds the changes from `old` to `new`, both at `path`, null where it is not
/// there. Objects are compared key by key, also when one side has none, so a
/// change names the deepest path it is at; anything else, a list included, is
/// compared whole.
fn compare(arena: std.mem.Allocator, changes: *std.ArrayList(Change), path: []const u8, old: ?hocon.Value, new: ?hocon.Value) !void {
    const by_key = (old == null or old.? == .object) and (new == null or new.? == .object) and
        (membersOf(old).len > 0 or membersOf(new).len > 0);
    if (by_key) {
        for (membersOf(old)) |m| {
            try compare(arena, changes, try pathTo(arena, path, m.key.value), m.value, field(new, m.key));
        }
        for (membersOf(new)) |m| {
            if (field(old, m.key) == null) try compare(arena, changes, try pathTo(arena, path, m.key.value), null, m.value);
        }
        return;
    }
    if (old != null and new != null and try same(arena, old.?, new.?)) return;
    try changes.append(arena, .{ .path = path, .old = old, .new = new });
}

fn membersOf(value: ?hocon.Value) @FieldType(hocon.Value, "object") {
    const v = value orelse return &.{};
    return if (v == .object) v.object else &.{};
}

fn field(value: ?hocon.Value, key: hocon.Key) ?hocon.Value {
    for (membersOf(value)) |m| {
        if (m.key.eql(key)) return m.value;
    }
    return null;
}

/// Equal as the program reading them sees it: the same JSON, but an object's
/// keys in any order, as HOCON objects have none.
fn same(arena: std.mem.Allocator, a: hocon.Value, b: hocon.Value) !bool {
    switch (a) {
        .scalar => {
            if (b != .scalar) return false;
            const a_json = try std.json.Stringify.valueAlloc(arena, a, .{});
            return std.mem.eql(u8, a_json, try std.json.Stringify.valueAlloc(arena, b, .{}));
        },
        .array => |items| {
            if (b != .array or b.array.len != items.len) return false;
            for (items, b.array) |x, y| {
                if (!try same(arena, x, y)) return false;
            }
            return true;
        },
        .object => |members| {
            if (b != .object or b.object.len != members.len) return false;
            for (members) |m| {
                const other = field(b, m.key) orelse return false;
                if (!try same(arena, m.value, other)) return false;
            }
            return true;
        },
        // `diff` compares resolved trees only.
        .ref, .pending, .stack => unreachable,
    }
}

/// `path.key`, the key quoted when a path would read it otherwise, so the
/// path can be given to `hocon get` as it is printed.
fn pathTo(arena: std.mem.Allocator, path: []const u8, key: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll(path);
    if (path.len > 0) try out.writer.writeByte('.');
    try hocon.writeKey(key, &out.writer);
    return out.toOwnedSlice();
}

const testing = std.testing;

// `diff` compares what a program reading the files gets: JSON types, so `1`
// and `"1"` differ while `x` and `"x"` do not; `1` and `1.0` differ too, as a
// `u16` reads one and not the other. An object's keys in any order are the
// same object, in a list too; a list's elements are not. `null` is a value,
// different from no key at all. Objects are walked to the deepest path that
// changed, also when one side has no object there.
// java ⚠️ has no diff; its `ConfigValue.equals` agrees except on `1` vs `1.0`,
// which it takes as equal · pyhocon — · spec — says nothing about comparing.
test "diff.path by path" {
    const cases = [_]struct { a: [:0]const u8, b: [:0]const u8, want: []const u8 }{
        .{ .a = "a = 1", .b = "a = 1", .want = "" },
        .{ .a = "a = 1", .b = "a = \"1\"", .want = "~ a: 1 → \"1\"\n" },
        .{ .a = "a = x", .b = "a = \"x\"", .want = "" },
        .{ .a = "a = 1", .b = "a = 1.0", .want = "~ a: 1 → 1.0\n" },
        .{ .a = "a = true", .b = "a = on", .want = "~ a: true → \"on\"\n" },
        .{ .a = "a { b = 1, c = 2 }", .b = "a { c = 2, b = 1 }", .want = "" },
        .{ .a = "a = [{ b = 1, c = 2 }]", .b = "a = [{ c = 2, b = 1 }]", .want = "" },
        .{ .a = "a = [1, 2]", .b = "a = [2, 1]", .want = "~ a: [1,2] → [2,1]\n" },
        .{ .a = "a = [1, 2]", .b = "a = [1, 2, 3]", .want = "~ a: [1,2] → [1,2,3]\n" },
        .{ .a = "a = null", .b = "", .want = "- a\n" },
        .{ .a = "", .b = "a = null", .want = "+ a: null\n" },
        .{ .a = "", .b = "a { b { c = 1 } }", .want = "+ a.b.c: 1\n" },
        .{ .a = "a { b = 1 }", .b = "a {}", .want = "- a.b\n" },
        .{ .a = "a {}", .b = "", .want = "- a\n" },
        .{ .a = "a {}", .b = "a {}", .want = "" },
        .{ .a = "a = 5", .b = "a { b = 1 }", .want = "~ a: 5 → {\"b\":1}\n" },
        .{ .a = "a = [1]", .b = "a { b = 1 }", .want = "~ a: [1] → {\"b\":1}\n" },
        .{ .a = "x = 1\ny = 2", .b = "y = 3\nz = 4", .want = "- x\n~ y: 2 → 3\n+ z: 4\n" },
        // A key a path has to quote is quoted, so `hocon get` takes the path.
        .{ .a = "\"x.y\" = 1", .b = "\"x.y\" = 2", .want = "~ \"x.y\": 1 → 2\n" },
        .{ .a = "\"true\" = 1", .b = "\"\" = 1", .want = "- \"true\"\n+ \"\": 1\n" },
        .{ .a = "a.b-c_d = 1", .b = "a.b-c_d = 2", .want = "~ a.b-c_d: 1 → 2\n" },
    };
    for (cases) |c| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const gpa = arena.allocator();
        const a = try hocon.parseFromSliceLeaky(hocon.Value, gpa, c.a, .{});
        const b = try hocon.parseFromSliceLeaky(hocon.Value, gpa, c.b, .{});
        var changes: std.ArrayList(Change) = .empty;
        try compare(gpa, &changes, "", a, b);
        var out: std.Io.Writer.Allocating = .init(gpa);
        try writeChanges(changes.items, .hocon, &out.writer);
        testing.expectEqualStrings(c.want, out.written()) catch |err| {
            std.debug.print("a: {s}\nb: {s}\n", .{ c.a, c.b });
            return err;
        };
    }
}

// The type goes into the program's source as it is written, so only names.
test "check.a schema type is a name" {
    for ([_][]const u8{ "Config", "config.App", "_T1", "a.b.C" }) |name| try testing.expect(isTypeName(name));
    for ([_][]const u8{ "", "1T", "a..b", ".T", "T.", "T;", "T{}", "@\"T\"", "T x" }) |name| try testing.expect(!isTypeName(name));
}
