//! The C API of `c/hocon.h`: what `zig build lib` builds into libhocon,
//! and what the Python package calls through ctypes.
//!
//! Thin on purpose. Parsing, paths and conversions are the library's own; this
//! only turns them into C types and the codes of hocon.h. A document is an
//! arena of its own, and everything handed out is freed here: `hocon_free`,
//! `hocon_free_string`, `hocon_error_free`.

const std = @import("std");
const builtin = @import("builtin");
const hocon = @import("hocon");
const Allocator = std.mem.Allocator;
const Map = std.process.Environ.Map;

/// malloc; in tests the testing allocator, so a test that leaks fails.
const gpa = if (builtin.is_test) std.testing.allocator else std.heap.c_allocator;

/// `HOCON_OK`, `HOCON_ERR_…` of hocon.h, in that order.
const Code = enum(c_int) { ok, parse, substitution, missing, wrong_type, io, bad_path, too_deep, other };

/// `HOCON_ENV_…` of hocon.h. Any other number is an error, not a crash.
const Env = enum(c_int) { process, none, map, keep, _ };

/// `hocon_options`. The defaults are what NULL options mean, and what a
/// field past the caller's `size` is.
const Options = extern struct {
    size: usize = @sizeOf(Options),
    env: Env = .process,
    env_vars: ?[*:null]const ?[*:0]const u8 = null,
    resolve: bool = true,
    include_dir: ?[*:0]const u8 = null,
    http_timeout_ms: u32 = 0,
};

/// `hocon_error`.
const Error = extern struct {
    code: Code = .ok,
    name: ?[*:0]const u8 = null,
    file: ?[*:0]u8 = null,
    line: usize = 0,
    column: usize = 0,
    source_line: ?[*:0]u8 = null,
    key_path: ?[*:0]u8 = null,
    expected: ?[*:0]u8 = null,
};

/// What a `hocon_doc *` points at: the tree, the files it was read from (for
/// a getter's error to point into) and the arena they live in, and why the
/// last call on it that failed failed.
const Doc = struct {
    arena: std.heap.ArenaAllocator,
    value: hocon.Value,
    files: hocon.Value.Files,
    last: Error = .{},
};

export fn hocon_parse_file(path: ?[*:0]const u8, options: ?*const Options, err: ?*Error) ?*Doc {
    const p = path orelse {
        fail(err, error.NullArgument, null, .{});
        return null;
    };
    return parse(std.mem.span(p), "", options, err);
}

export fn hocon_parse_string(src: ?[*]const u8, len: usize, options: ?*const Options, err: ?*Error) ?*Doc {
    const s = src orelse {
        fail(err, error.NullArgument, null, .{});
        return null;
    };
    return parse(null, s[0..len], options, err);
}

/// The file at `path`, or with no path `text`, as a document.
fn parse(path: ?[]const u8, text: []const u8, options: ?*const Options, err: ?*Error) ?*Doc {
    return onBigStack(parseHere, .{ path, text, options, err });
}

/// `function(args)` on a thread of its own, with `std.Thread`'s 16 MiB of
/// stack, joined before this returns: parsing, resolving and writing recurse
/// once per level of nesting, up to 500 levels, and the caller's thread may
/// have far less (musl's 128 KiB, a Python thread made smaller), where a deep
/// document would end the process. On a thread of its own the limit is
/// `TooDeep` on every thread alike. Where no thread can be started, on the
/// caller's.
// ponytail: a thread per call, about 20 µs; one long-lived thread if that ever
// matters more than a parse at startup.
fn onBigStack(comptime function: anytype, args: anytype) @typeInfo(@TypeOf(function)).@"fn".return_type.? {
    const Result = @typeInfo(@TypeOf(function)).@"fn".return_type.?;
    if (builtin.single_threaded) return @call(.auto, function, args);
    const Run = struct {
        fn run(out: *Result, a: @TypeOf(args)) void {
            out.* = @call(.auto, function, a);
        }
    };
    var out: Result = undefined;
    const thread = std.Thread.spawn(.{}, Run.run, .{ &out, args }) catch return @call(.auto, function, args);
    thread.join();
    return out;
}

fn parseHere(path: ?[]const u8, text: []const u8, options: ?*const Options, err: ?*Error) ?*Doc {
    if (err) |e| e.* = .{};
    const doc = gpa.create(Doc) catch {
        fail(err, error.OutOfMemory, null, .{});
        return null;
    };
    doc.* = .{ .arena = .init(gpa), .value = undefined, .files = .{} };
    var diag: hocon.Diagnostics = .{};
    doc.value = load(doc, path, text, options, &diag) catch |e| {
        // The place is in the arena: copied out before the arena goes.
        fail(err, e, path, diag);
        doc.arena.deinit();
        gpa.destroy(doc);
        return null;
    };
    return doc;
}

fn load(doc: *Doc, path: ?[]const u8, text: []const u8, given: ?*const Options, diag: *hocon.Diagnostics) !hocon.Value {
    const options = try optionsOf(given);
    const arena = doc.arena.allocator();
    var vars: Map = .init(arena);
    const env: hocon.Value.Env = switch (options.env) {
        .process => blk: {
            try putProcess(&vars);
            break :blk .{ .map = &vars };
        },
        .none => .none,
        .map => blk: {
            if (options.env_vars) |entries| try putAll(&vars, std.mem.span(entries));
            break :blk .{ .map = &vars };
        },
        .keep => .keep,
        _ => return error.BadOptions,
    };
    // An Io of its own for this parse, with threads: an `http` include is
    // fetched beside a sleep, and the first to end decides
    // (Include.fetchWithTimeout). The threads start with the first fetch, and
    // `deinit` joins them before the parse returns: none outlives the call, and
    // nothing is shared to start once for the library. The fetch that lost is
    // woken with SIGIO, so it needs SIGIO and SIGPIPE set to a handler that
    // does nothing. `init` sets them, and they are put back at once: a parse
    // that fetches nothing leaves them as they were. A fetch sets them
    // (setFetchSignals) until the last parse that fetched has joined its
    // threads: a SIGIO with no handler ends the process on Linux.
    var threaded: std.Io.Threaded = .init(gpa, .{});
    if (threaded.have_signal_handler) {
        if (@TypeOf(threaded.old_sig_io) != void) std.posix.sigaction(.IO, &threaded.old_sig_io, null);
        if (@TypeOf(threaded.old_sig_pipe) != void) std.posix.sigaction(.PIPE, &threaded.old_sig_pipe, null);
        threaded.have_signal_handler = false;
    }
    defer if (fetched_here) putBackSignals();
    defer threaded.deinit();
    const io = threaded.io();
    var parse_options: hocon.ParseOptions = .{ .diagnostics = diag, .env = env, .resolve = options.resolve, .files = &doc.files, .before_fetch = setFetchSignals };
    if (options.http_timeout_ms > 0) parse_options.http_timeout = .fromMilliseconds(options.http_timeout_ms);
    // The files keep the path they were named by, and the caller's may go.
    if (path) |p| return hocon.parseFromFileLeaky(hocon.Value, arena, io, try arena.dupe(u8, p), parse_options);

    // The values point into the text, so it goes into the arena, with the 0
    // the parser wants after it.
    const source = try arena.dupeZ(u8, text);
    const dir = options.include_dir orelse return hocon.parseFromSliceLeaky(hocon.Value, arena, source, parse_options);
    return hocon.parseFromSliceInDirLeaky(hocon.Value, arena, io, std.mem.span(dir), source, parse_options);
}

// The parses fetching an include now, and the handlers they set SIGIO and
// SIGPIPE over: the first to fetch keeps them, the last to end puts them back.
// ponytail: a handler a program sets while a fetch runs is replaced by the one
// from before, when the last fetching parse ends.
var fetching_parses: usize = 0;
var fetching_lock: std.atomic.Value(bool) = .init(false);
var old_sig_io: if (has_sig_io) std.posix.Sigaction else void = undefined;
var old_sig_pipe: if (has_sig_pipe) std.posix.Sigaction else void = undefined;
const has_sig_io = std.posix.Sigaction != void and @hasField(std.posix.SIG, "IO");
const has_sig_pipe = std.posix.Sigaction != void and @hasField(std.posix.SIG, "PIPE");
/// Whether the parse on this thread has set the signals for a fetch.
threadlocal var fetched_here = false;

/// SIGIO and SIGPIPE to a handler that does nothing, as `std.Io.Threaded.init`
/// sets them, for an `http(s)` include to be fetched (see `load`); once per
/// parse.
fn setFetchSignals() void {
    if (fetched_here or std.posix.Sigaction == void) return;
    fetched_here = true;
    lockFetching();
    defer fetching_lock.store(false, .release);
    fetching_parses += 1;
    if (fetching_parses > 1) return;
    const act: std.posix.Sigaction = .{ .handler = .{ .handler = doNothing }, .mask = std.posix.sigemptyset(), .flags = 0 };
    if (has_sig_io) std.posix.sigaction(.IO, &act, &old_sig_io);
    if (has_sig_pipe) std.posix.sigaction(.PIPE, &act, &old_sig_pipe);
}

/// After a parse that fetched has joined its threads: the last one puts back
/// the handlers from before the first.
fn putBackSignals() void {
    fetched_here = false;
    lockFetching();
    defer fetching_lock.store(false, .release);
    fetching_parses -= 1;
    if (fetching_parses > 0) return;
    if (has_sig_io) std.posix.sigaction(.IO, &old_sig_io, null);
    if (has_sig_pipe) std.posix.sigaction(.PIPE, &old_sig_pipe, null);
}

fn lockFetching() void {
    while (fetching_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn doNothing(_: std.posix.SIG) callconv(.c) void {}

/// The caller's options: the fields its `size` holds, and the defaults for
/// the rest, which a program built against an older hocon.h does not know of.
fn optionsOf(given: ?*const Options) !Options {
    var options: Options = .{};
    const g = given orelse return options;
    // No `size`: the fields set beside it would look read and not be.
    if (g.size < @sizeOf(usize)) return error.BadOptions;
    inline for (@typeInfo(Options).@"struct".fields) |f| {
        if (@offsetOf(Options, f.name) + @sizeOf(f.type) <= g.size) @field(options, f.name) = @field(g, f.name);
    }
    return options;
}

/// The variables of the process we are loaded into, as they are now: a
/// program that sets one before the parse has it read.
fn putProcess(vars: *Map) !void {
    if (builtin.os.tag == .windows) {
        const environ: std.process.Environ = .{ .block = .global };
        vars.* = try environ.createMap(vars.allocator);
        return;
    }
    try putAll(vars, std.mem.span(std.c.environ));
}

/// `KEY=VALUE` entries, as `environ` has them. One that is not is skipped: no
/// `${…}` could name it.
fn putAll(vars: *Map, entries: []const ?[*:0]const u8) !void {
    for (entries) |entry| {
        const text = std.mem.span(entry.?);
        const eq = std.mem.indexOfScalar(u8, text, '=') orelse continue;
        if (!Map.validateKeyForPut(text[0..eq])) continue;
        try vars.put(text[0..eq], text[eq + 1 ..]);
    }
}

/// Fills in `err` for a parse that failed with `e`. `path` is the file the
/// parse read, null for a string.
fn fail(err: ?*Error, e: anyerror, path: ?[]const u8, diag: hocon.Diagnostics) void {
    const out = err orelse return;
    fill(out, parseCode(e, path != null and diag.location == null), e, diag);
}

/// `out` for `e`, with its own copies of what `diag` says about it.
fn fill(out: *Error, code: Code, e: anyerror, diag: hocon.Diagnostics) void {
    out.* = .{ .code = code, .name = @errorName(e) };
    // Out of memory here leaves out what could not be copied, not the error.
    if (diag.key_path.len > 0) out.key_path = gpa.dupeZ(u8, diag.key_path) catch null;
    if (diag.expected.len > 0) out.expected = gpa.dupeZ(u8, diag.expected) catch null;
    const loc = diag.location orelse return;
    const file = gpa.dupeZ(u8, loc.path) catch return;
    const source_line = gpa.dupeZ(u8, loc.source_line) catch {
        gpa.free(file);
        return;
    };
    // A 0 in the line would end it early for C; it prints as a space anyway.
    std.mem.replaceScalar(u8, source_line, 0, ' ');
    out.file = file;
    out.source_line = source_line;
    out.line = loc.line;
    out.column = loc.column;
}

fn parseCode(e: anyerror, unread_file: bool) Code {
    return switch (e) {
        error.Unresolved, error.SubstitutionCycle => .substitution,
        error.OutOfMemory, error.NullArgument, error.BadOptions => .other,
        // The file itself, not read: an error of reading it, with no place in
        // it. One read but too much for the parser is a parse error.
        else => if (unread_file and isReadError(e)) .io else .parse,
    };
}

fn isReadError(e: anyerror) bool {
    inline for (@typeInfo(std.Io.Dir.ReadFileAllocError).error_set.?) |f| {
        if (e == @field(anyerror, f.name)) return true;
    }
    return false;
}

export fn hocon_get_int(doc: ?*Doc, path: ?[*:0]const u8, out: ?*i64) Code {
    const o = out orelse return .other;
    o.* = get(i64, doc, path) catch |err| return getCode(err);
    return .ok;
}

export fn hocon_get_float(doc: ?*Doc, path: ?[*:0]const u8, out: ?*f64) Code {
    const o = out orelse return .other;
    o.* = get(f64, doc, path) catch |err| return getCode(err);
    return .ok;
}

export fn hocon_get_bool(doc: ?*Doc, path: ?[*:0]const u8, out: ?*bool) Code {
    const o = out orelse return .other;
    o.* = get(bool, doc, path) catch |err| return getCode(err);
    return .ok;
}

export fn hocon_get_string(doc: ?*Doc, path: ?[*:0]const u8, out: ?*[*]const u8, len: ?*usize) Code {
    if (out == null or len == null) return .other;
    // The conversion says whether it is text; the text handed out is the
    // document's own, which lives as long as the document, not get's copy.
    _ = get([]const u8, doc, path) catch |err| return getCode(err);
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const value = lookup(doc, path, scratch.allocator()) catch |err| return getCode(err);
    out.?.* = value.scalar.value.ptr;
    len.?.* = value.scalar.value.len;
    return .ok;
}

export fn hocon_get_duration_ns(doc: ?*Doc, path: ?[*:0]const u8, out: ?*i64) Code {
    const o = out orelse return .other;
    // Past an i64 of nanoseconds (292 years) it is the largest one, as java's
    // getDuration has it.
    o.* = (get(hocon.Duration, doc, path) catch |err| return getCode(err)).whole(.ns);
    return .ok;
}

export fn hocon_get_bytes(doc: ?*Doc, path: ?[*:0]const u8, out: ?*u64) Code {
    const o = out orelse return .other;
    o.* = (get(hocon.Size, doc, path) catch |err| return getCode(err)).bytes;
    return .ok;
}

export fn hocon_get_period(doc: ?*Doc, path: ?[*:0]const u8, years: ?*i32, months: ?*i32, days: ?*i32) Code {
    if (years == null or months == null or days == null) return .other;
    const period = get(hocon.Period, doc, path) catch |err| return getCode(err);
    years.?.* = period.years;
    months.?.* = period.months;
    days.?.* = period.days;
    return .ok;
}

export fn hocon_get_config(doc: ?*Doc, path: ?[*:0]const u8) Code {
    // A struct of no fields takes any object, and is what the conversion
    // says "expected object" for, where the value is written.
    _ = get(struct {}, doc, path) catch |err| return getCode(err);
    return .ok;
}

/// `T` read from the value at `path` by the library's own conversion. A
/// failure is kept on `doc`, with what the conversion says about it.
fn get(comptime T: type, doc: ?*Doc, path: ?[*:0]const u8) !T {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    var diag: hocon.Diagnostics = .{};
    // Runs before the scratch goes, which has the diagnostics' copies.
    errdefer |err| _ = remember(doc, path, err, diag);
    // A NULL doc is an error of lookup's, before `doc.?`.
    const value = try lookup(doc, path, scratch.allocator());
    return hocon.parseFromValueIn(T, scratch.allocator(), doc.?.files, value, &diag);
}

/// Keeps why a call on `doc` failed for `hocon_last_error`, the path it was
/// given as the path of the error, and gives the code the call returns.
fn remember(doc: ?*Doc, path: ?[*:0]const u8, err: anyerror, diag: hocon.Diagnostics) Code {
    const code = getCode(err);
    const d = doc orelse return code;
    hocon_error_free(&d.last);
    var said = diag;
    said.key_path = if (path) |p| std.mem.span(p) else "";
    fill(&d.last, code, err, said);
    return code;
}

/// Why the last call on `doc` that failed failed; HOCON_OK while none has.
export fn hocon_last_error(doc: ?*Doc) ?*const Error {
    const d = doc orelse return null;
    return &d.last;
}

/// The value at `path` for a getter, which has nothing to give for `null`.
fn lookup(doc: ?*Doc, path: ?[*:0]const u8, scratch: Allocator) !hocon.Value {
    const value = try find(doc, path, scratch);
    // java ✓: getString on `null` is ConfigException.Null, a Missing.
    if (isNull(value)) return error.Missing;
    return value;
}

/// The value at `path`, a path as text; "" is the root. The keys of the path
/// go to `scratch`; the value is the document's.
fn find(doc: ?*Doc, path: ?[*:0]const u8, scratch: Allocator) !hocon.Value {
    const d = doc orelse return error.NullArgument;
    const text = std.mem.span(path orelse return error.NullArgument);
    if (text.len == 0) return d.value;
    const keys = hocon.parsePath(scratch, text, null) catch |err| return if (err == error.OutOfMemory) err else error.BadPath;

    var value = d.value;
    for (keys) |key| {
        value = switch (value) {
            .object => |members| for (members) |m| {
                if (m.key.eql(key)) break m.value;
            } else return error.Missing,
            // java ✓: `null` on the way is missing, anything else is the wrong
            // type. WrongType is only this: a conversion fails with its own.
            .scalar => return if (isNull(value)) error.Missing else error.WrongType,
            .array => return error.WrongType,
            .ref, .pending, .stack => return error.Unresolved,
        };
    }
    return value;
}

fn isNull(value: hocon.Value) bool {
    return value == .scalar and !value.scalar.quoted and std.mem.eql(u8, value.scalar.value, "null");
}

fn getCode(err: anyerror) Code {
    return switch (err) {
        error.Missing => .missing,
        error.Unresolved => .substitution,
        error.BadPath => .bad_path,
        error.TooDeep => .too_deep,
        error.OutOfMemory, error.NullArgument => .other,
        // WrongType of a path, and what a conversion fails with: TypeMismatch,
        // InvalidCharacter, Overflow, UnknownUnit.
        else => .wrong_type,
    };
}

export fn hocon_to_json(doc: ?*Doc, path: ?[*:0]const u8, code: ?*Code) ?[*:0]u8 {
    return write(.json, doc, path, code);
}

export fn hocon_to_hocon(doc: ?*Doc, path: ?[*:0]const u8, code: ?*Code) ?[*:0]u8 {
    return write(.hocon, doc, path, code);
}

const Format = enum { json, hocon };

fn write(format: Format, doc: ?*Doc, path: ?[*:0]const u8, code: ?*Code) ?[*:0]u8 {
    return onBigStack(writeHere, .{ format, doc, path, code });
}

fn writeHere(format: Format, doc: ?*Doc, path: ?[*:0]const u8, code: ?*Code) ?[*:0]u8 {
    const text = writeAlloc(format, doc, path) catch |err| {
        const failed = remember(doc, path, err, .{});
        if (code) |c| c.* = failed;
        return null;
    };
    if (code) |c| c.* = .ok;
    return text.ptr;
}

fn writeAlloc(format: Format, doc: ?*Doc, path: ?[*:0]const u8) ![:0]u8 {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const value = try find(doc, path, scratch.allocator());

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    switch (format) {
        .json => {
            // JSON has no way to write a `${…}`.
            if (!value.isResolved()) return error.Unresolved;
            // Deeper than 256 is the one way `Value.jsonStringify` fails, and
            // out of memory fails the same way: the depth tells them apart.
            std.json.Stringify.value(value, .{}, &out.writer) catch
                return if (tooDeep(value, 0)) error.TooDeep else error.OutOfMemory;
        },
        .hocon => {
            // A key written twice, `port = 8080` then `${?PORT}`, kept so: two
            // values until it is resolved, no one document. Below the root a
            // `${…}` is the root's, and the text alone would look it up in
            // the subtree.
            if (value == .stack) return error.Unresolved;
            if (std.mem.span(path.?).len > 0 and !value.isResolved()) return error.Unresolved;
            hocon.stringify(value, .{}, &out.writer) catch return error.OutOfMemory;
        },
    }
    return out.toOwnedSliceSentinel(0);
}

/// Whether a list or an object in `value`, at `level` itself, is 256 or more
/// inside one another, where `Value.jsonStringify` stops.
fn tooDeep(value: hocon.Value, level: usize) bool {
    switch (value) {
        .array => |items| {
            if (level >= 256) return true;
            for (items) |item| if (tooDeep(item, level + 1)) return true;
        },
        .object => |members| {
            if (level >= 256) return true;
            for (members) |m| if (tooDeep(m.value, level + 1)) return true;
        },
        else => {},
    }
    return false;
}

export fn hocon_free_string(s: ?[*:0]u8) void {
    gpa.free(std.mem.span(s orelse return));
}

export fn hocon_error_free(err: ?*Error) void {
    const e = err orelse return;
    if (e.file) |file| gpa.free(std.mem.span(file));
    if (e.source_line) |line| gpa.free(std.mem.span(line));
    if (e.key_path) |key_path| gpa.free(std.mem.span(key_path));
    if (e.expected) |expected| gpa.free(std.mem.span(expected));
    e.* = .{};
}

export fn hocon_free(doc: ?*Doc) void {
    const d = doc orelse return;
    hocon_error_free(&d.last);
    d.arena.deinit();
    gpa.destroy(d);
}

/// std calls libc's statx on any musl, but musl has it only from 1.2.5: the
/// musllinux_1_2 wheel would not load on Alpine 3.13–3.19. So libhocon has a
/// statx of its own there, the system call itself, as std makes it on glibc
/// 2.17 for the manylinux wheels. Hidden: it is for libhocon alone.
fn statx(dir: c_int, path: [*:0]const u8, flags: u32, mask: std.os.linux.STATX, buf: *std.os.linux.Statx) callconv(.c) c_int {
    const e = std.os.linux.errno(std.os.linux.statx(dir, path, flags, mask, buf));
    if (e == .SUCCESS) return 0;
    std.c._errno().* = @intFromEnum(e);
    return -1;
}

comptime {
    if (builtin.abi.isMusl()) @export(&statx, .{ .name = "statx", .visibility = .hidden });
}

// ---------------------------------------------------------------------------
// Tests: the exported functions called as C calls them, with C's types. The
// allocator is the testing one (`gpa`), so whatever a test does not free
// fails it.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// One getter on one document: `{ getter, path, source, what it gives }`.
/// What it gives is the value, or the name of the code it returns.
const Row = struct { []const u8, [:0]const u8, []const u8, []const u8 };

/// Runs every row and only then fails, listing the rows that did not give
/// what they should — the way `table.expectAll` reports (src/table.zig
/// belongs to the library's module, so it cannot be imported here).
fn expectRows(rows: []const Row, options: Options) !void {
    var report: std.Io.Writer.Allocating = .init(testing.allocator);
    defer report.deinit();
    for (rows) |row| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const getter, const path, const src, const want = row;
        const got = try dumpGet(arena.allocator(), getter, path, src, options);
        if (std.mem.eql(u8, want, got)) continue;
        try report.writer.print("  {s} {s} on '{s}'\n      want {s}\n      got  {s}\n", .{ getter, path, src, want, got });
    }
    if (report.written().len == 0) return;
    std.debug.print("\n{s}", .{report.written()});
    return error.TestExpectedEqual;
}

fn dumpGet(arena: Allocator, getter: []const u8, path: [:0]const u8, src: []const u8, options: Options) ![]const u8 {
    var err: Error = .{};
    defer hocon_error_free(&err);
    const doc = hocon_parse_string(src.ptr, src.len, &options, &err) orelse
        return std.fmt.allocPrint(arena, "{t} {s}", .{ err.code, err.name.? });
    defer hocon_free(doc);
    // `!int`: what `hocon_last_error` says after the getter, drawn as a caret
    // row of src/root.zig is: a line under the line it points at.
    if (getter[0] != '!') return call(arena, doc, getter, path);
    _ = try call(arena, doc, getter[1..], path);
    const last = hocon_last_error(doc).?;
    if (last.code == .ok) return "no error";
    var said: std.Io.Writer.Allocating = .init(arena);
    try said.writer.print("{s}", .{last.name.?});
    if (last.key_path) |key_path| try said.writer.print(" at {s}", .{key_path});
    if (last.expected) |expected| try said.writer.print(": expected {s}", .{expected});
    if (last.line == 0) return std.fmt.allocPrint(arena, "{s} → {s}", .{ src, said.written() });

    try testing.expectEqualStrings("", std.mem.span(last.file.?));
    var out: std.Io.Writer.Allocating = .init(arena);
    var lines = std.mem.splitScalar(u8, src, '\n');
    var n: usize = 1;
    while (lines.next()) |line| : (n += 1) {
        if (n > 1) try out.writer.writeByte('\n');
        try out.writer.writeAll(line);
        if (n != last.line) continue;
        try out.writer.writeByte('\n');
        try out.writer.splatByteAll(' ', last.column - 1);
        try out.writer.print("^ {s}", .{said.written()});
    }
    return out.written();
}

/// `getter` on `doc`: the value it gives, or the code it returns.
fn call(arena: Allocator, doc: *Doc, getter: []const u8, path: [:0]const u8) ![]const u8 {
    if (std.mem.eql(u8, getter, "int")) {
        var out: i64 = undefined;
        const code = hocon_get_int(doc, path, &out);
        return if (code == .ok) std.fmt.allocPrint(arena, "{d}", .{out}) else @tagName(code);
    }
    if (std.mem.eql(u8, getter, "float")) {
        var out: f64 = undefined;
        const code = hocon_get_float(doc, path, &out);
        return if (code == .ok) std.fmt.allocPrint(arena, "{d}", .{out}) else @tagName(code);
    }
    if (std.mem.eql(u8, getter, "bool")) {
        var out: bool = undefined;
        const code = hocon_get_bool(doc, path, &out);
        return if (code == .ok) std.fmt.allocPrint(arena, "{}", .{out}) else @tagName(code);
    }
    if (std.mem.eql(u8, getter, "string")) {
        var out: [*]const u8 = undefined;
        var len: usize = undefined;
        const code = hocon_get_string(doc, path, &out, &len);
        return if (code == .ok) std.fmt.allocPrint(arena, "'{s}'", .{out[0..len]}) else @tagName(code);
    }
    if (std.mem.eql(u8, getter, "ns")) {
        var out: i64 = undefined;
        const code = hocon_get_duration_ns(doc, path, &out);
        return if (code == .ok) std.fmt.allocPrint(arena, "{d}", .{out}) else @tagName(code);
    }
    if (std.mem.eql(u8, getter, "bytes")) {
        var out: u64 = undefined;
        const code = hocon_get_bytes(doc, path, &out);
        return if (code == .ok) std.fmt.allocPrint(arena, "{d}", .{out}) else @tagName(code);
    }
    if (std.mem.eql(u8, getter, "period")) {
        var y: i32 = undefined;
        var m: i32 = undefined;
        var d: i32 = undefined;
        const code = hocon_get_period(doc, path, &y, &m, &d);
        return if (code == .ok) std.fmt.allocPrint(arena, "{d}y {d}mo {d}d", .{ y, m, d }) else @tagName(code);
    }
    if (std.mem.eql(u8, getter, "config")) return @tagName(hocon_get_config(doc, path));
    var code: Code = undefined;
    const text = if (std.mem.eql(u8, getter, "json")) hocon_to_json(doc, path, &code) else hocon_to_hocon(doc, path, &code);
    const t = text orelse return @tagName(code);
    defer hocon_free_string(t);
    return arena.dupe(u8, std.mem.span(t));
}

// The getters convert as `hocon.parseFromValueIn` does, so as a struct field of
// the type would. java ✓ on every row but where it says ⚠️, pyhocon ⚠️ (its
// get_int truncates, get_string on null is None, no durations or sizes) ·
// spec ✓ (automatic type conversions, L1230; units, L1264).
test "capi.getters" {
    try expectRows(&.{
        .{ "int", "a", "a = 5", "5" },
        .{ "int", "a", "a = \"5\"", "5" },
        .{ "int", "a", "a = -3", "-3" },
        // java ⚠️ 1 and 1000: a fraction or an exponent is no whole number here.
        .{ "int", "a", "a = 1.5", "wrong_type" },
        .{ "int", "a", "a = 1e3", "wrong_type" },
        .{ "int", "a", "a = 9223372036854775808", "wrong_type" },
        .{ "int", "a", "a = true", "wrong_type" },
        .{ "int", "a", "a { b = 1 }", "wrong_type" },
        .{ "int", "a", "a = null", "missing" },
        .{ "int", "b", "a = 1", "missing" },
        .{ "float", "a", "a = 1.5", "1.5" },
        .{ "float", "a", "a = \"5\"", "5" },
        .{ "float", "a", "a = [1]", "wrong_type" },
        // A number from text is a JSON number (spec L1238), nothing that
        // std.fmt also reads; and `inf`, `-inf`, which is how `stringify`
        // writes an infinite f64 (its `nan` is not read back). java ⚠️ reads
        // `+5`, `0x1p3`, `NaN` and `Infinity`; pyhocon ⚠️ also `1_000`, `nan`.
        .{ "int", "a", "a = 1_000", "wrong_type" },
        .{ "int", "a", "a = \"1__0\"", "wrong_type" },
        .{ "int", "a", "a = \"+5\"", "wrong_type" },
        .{ "float", "a", "a = \"1_000.5\"", "wrong_type" },
        .{ "float", "a", "a = \"0x10\"", "wrong_type" },
        .{ "float", "a", "a = \"0x1p3\"", "wrong_type" },
        .{ "float", "a", "a = \"Infinity\"", "wrong_type" },
        .{ "float", "a", "a = \"NaN\"", "wrong_type" },
        .{ "float", "a", "a = nan", "wrong_type" },
        .{ "float", "a", "a = \"-inf\"", "-inf" },
        .{ "float", "a", "a = \"1e3\"", "1000" },
        .{ "bool", "a", "a = yes", "true" },
        .{ "bool", "a", "a = off", "false" },
        .{ "bool", "a", "a = \"5\"", "wrong_type" },
        .{ "string", "a", "a = the owl ate the router", "'the owl ate the router'" },
        .{ "string", "a", "a = true", "'true'" },
        .{ "string", "a", "a = 1e3", "'1e3'" },
        .{ "string", "a", "a = \"null\"", "'null'" },
        .{ "string", "a", "a = \"\"", "''" },
        .{ "string", "a", "a = null", "missing" },
        .{ "string", "a", "a = [1, 2]", "wrong_type" },
        .{ "string", "a", "a { b = 1 }", "wrong_type" },
        .{ "ns", "a", "a = 10s", "10000000000" },
        .{ "ns", "a", "a = 3", "3000000" },
        .{ "ns", "a", "a = 200000d", "9223372036854775807" },
        // java ⚠️ BadValue, a ConfigException of its own.
        .{ "ns", "a", "a = 10 parsecs", "wrong_type" },
        .{ "bytes", "a", "a = 3", "3" },
        .{ "bytes", "a", "a = 512MB", "512000000" },
        .{ "bytes", "a", "a = \"1.5 GiB\"", "1610612736" },
        .{ "bytes", "a", "a = 10s", "wrong_type" },
        .{ "period", "a", "a = 3", "0y 0mo 3d" },
        .{ "period", "a", "a = 2w", "0y 0mo 14d" },
        .{ "period", "a", "a = 14mo", "0y 14mo 0d" },
        .{ "period", "a", "a = 2y", "2y 0mo 0d" },
        .{ "config", "a", "a { b = 1 }", "ok" },
        .{ "config", "a", "a = [1, 2]", "wrong_type" },
        .{ "config", "a", "a = null", "missing" },
        .{ "config", "", "a = 1", "ok" },
    }, .{ .env = .none });
}

// What `hocon_last_error` says after a getter failed, the way a parse into a
// struct says it (diagnostics.conversion in src/root.zig): the error, the
// path, what the getter wanted, and the value where it is written — for a
// `${…}` that waits, its `${`. What has no value has no place.
// java ✓ (WrongType at the same path and line; Missing, Null) · pyhocon ⚠️
// (no line) · spec –
test "capi.last error" {
    try expectRows(&.{
        .{ "!int", "db.pool", "db { pool = eight }", "db { pool = eight }\n            ^ InvalidCharacter at db.pool: expected i64" },
        .{ "!int", "db.pool", "db {\n  pool = 300000000000000000000\n}", "db {\n  pool = 300000000000000000000\n         ^ Overflow at db.pool: expected i64\n}" },
        .{ "!bool", "debug", "debug = maybe", "debug = maybe\n        ^ TypeMismatch at debug: expected bool" },
        .{ "!ns", "timeout", "timeout = 10 parsecs", "timeout = 10 parsecs\n          ^ UnknownUnit at timeout: expected duration" },
        .{ "!bytes", "cache", "cache = [1, 2]", "cache = [1, 2]\n         ^ TypeMismatch at cache: expected size" },
        .{ "!string", "db", "db { host = burrow }", "db { host = burrow }\n     ^ TypeMismatch at db: expected string" },
        .{ "!int", "db.size", "db { pool = 4 }", "db { pool = 4 } → Missing at db.size" },
        .{ "!int", "db.pool.size", "db { pool = 4 }", "db { pool = 4 } → WrongType at db.pool.size" },
        .{ "!config", "db", "db = 4", "db = 4\n     ^ TypeMismatch at db: expected object" },
        .{ "!json", "a..b", "a = 1", "a = 1 → BadPath at a..b" },
    }, .{ .env = .none });
    try expectRows(&.{
        .{ "!int", "port", "port = ${PORT}", "port = ${PORT}\n       ^ Unresolved at port" },
    }, .{ .resolve = false });
}

// A path is text, as in a config file. On the way down, `null` is missing and
// anything that is no object the wrong type. java ✓ (Null, WrongType, BadPath)
// · pyhocon ⚠️ (splits at every dot, quotes or not) · spec ✓ (path expressions)
test "capi.paths" {
    try expectRows(&.{
        .{ "string", "db.host", "db { host = burrow.example }", "'burrow.example'" },
        .{ "string", "db.host", "db.host = burrow.example", "'burrow.example'" },
        .{ "string", "a.\"b.c\"", "a { \"b.c\" = dot }", "'dot'" },
        .{ "string", "a.b.c", "a { \"b.c\" = dot }", "missing" },
        .{ "string", "a.b", "a = null", "missing" },
        .{ "string", "a.b", "a = 5", "wrong_type" },
        .{ "string", "a.b", "a = [1]", "wrong_type" },
        .{ "string", "a..b", "a = 1", "bad_path" },
        .{ "string", "a = b", "a = 1", "bad_path" },
        .{ "json", "", "a { b = [1, x] }", "{\"a\":{\"b\":[1,\"x\"]}}" },
        .{ "json", "a", "a { b = [1, x] }", "{\"b\":[1,\"x\"]}" },
        .{ "json", "a.b", "a { b = [1, x] }", "[1,\"x\"]" },
        .{ "json", "a.c", "a { b = [1, x] }", "missing" },
        .{ "json", "a", "a = null", "null" },
        .{ "hocon", "a", "a { b = [1, x], c = 30s }", "b = [1, x]\nc = 30s\n" },
        .{ "hocon", "", "a = 1", "a = 1\n" },
    }, .{ .env = .none });
}

// What is left unresolved — the variables with `.keep`, everything without
// resolving — is there for `hocon_to_hocon`; a getter or JSON that reaches it
// says it still waits, a getter that does not is fine. A key written twice
// whose top waits is two values, not one. Zig only for `.keep`; java ✓ and
// pyhocon ✓ print the unresolved `${…}`.
test "capi.unresolved" {
    const src = "name = grumpy wombat\nport = 8080\nport = ${?PORT}\nurl = \"http://\"${host}\nhost = burrow";
    const rows = [_]Row{
        .{ "string", "name", src, "'grumpy wombat'" },
        .{ "int", "port", src, "substitution" },
        .{ "json", "port", src, "substitution" },
        .{ "json", "", src, "substitution" },
        .{ "hocon", "port", src, "substitution" },
        .{ "config", "port", src, "substitution" },
        .{ "string", "port.x", src, "substitution" },
    };
    try expectRows(&rows, .{ .env = .keep });
    try expectRows(&rows, .{ .resolve = false });
    // `${mood}` in `parrot` is the root's `mood`; written alone, the subtree
    // would read it from its own.
    const parrot = "mood = ${MOOD}\nparrot { mood = asleep, says = ${mood} }";
    try expectRows(&.{
        .{ "hocon", "parrot", parrot, "substitution" },
        .{ "hocon", "parrot.mood", parrot, "asleep\n" },
    }, .{ .env = .keep });
    try expectRows(&.{
        .{ "hocon", "", src, "name = grumpy wombat\nport = 8080\nport = ${?PORT}\nurl = \"http://burrow\"\nhost = burrow\n" },
        .{ "string", "url", src, "'http://burrow'" },
    }, .{ .env = .keep });
    try expectRows(&.{
        .{ "hocon", "", src, "name = grumpy wombat\nport = 8080\nport = ${?PORT}\nurl = \"http://\"${host}\nhost = burrow\n" },
        // A `${…}` below the root is written as it is only with the root:
        // read alone, the text would look it up from the subtree, or not at all.
        .{ "hocon", "url", src, "substitution" },
        .{ "string", "url", src, "substitution" },
    }, .{ .resolve = false });
}

/// `setenv(3)`; std has no way to change the environment of the process.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

// The four places `${…}` looks. The process's own variables are read as they
// are when the parse starts; a map is `environ` built by hand, an entry that
// is no `KEY=VALUE` skipped. java ✓ · pyhocon ⚠️ (no `[]`) · spec ✓
test "capi.environment" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const src = "mood = ${?ZIG_HOCON_TEST_MOOD}\nhosts = ${?ZIG_HOCON_TEST_HOSTS[]}";
    try testing.expectEqual(0, setenv("ZIG_HOCON_TEST_MOOD", "grumpy", 1));
    try expectRows(&.{.{ "json", "", src, "{\"mood\":\"grumpy\"}" }}, .{});
    try testing.expectEqual(0, setenv("ZIG_HOCON_TEST_MOOD", "sleepy", 1));
    try expectRows(&.{.{ "json", "", src, "{\"mood\":\"sleepy\"}" }}, .{ .env = .process });
    try expectRows(&.{.{ "json", "", src, "{}" }}, .{ .env = .none });

    const vars = [_:null]?[*:0]const u8{ "ZIG_HOCON_TEST_MOOD=moody", "ZIG_HOCON_TEST_HOSTS_0=a=b", "no equals sign", "=empty name" };
    try expectRows(&.{.{ "json", "", src, "{\"mood\":\"moody\",\"hosts\":[\"a=b\"]}" }}, .{ .env = .map, .env_vars = &vars });
    try expectRows(&.{.{ "json", "", src, "{}" }}, .{ .env = .map });
    try expectRows(&.{.{ "hocon", "", src, "mood = ${?ZIG_HOCON_TEST_MOOD}\nhosts = ${?ZIG_HOCON_TEST_HOSTS[]}\n" }}, .{ .env = .keep });
    try expectRows(&.{.{ "json", "", src, "other BadOptions" }}, .{ .env = @enumFromInt(7) });
}

// A failed parse says why and where: the file as it was named, line, column
// and the line itself, freed by `hocon_error_free`. The error in an included
// file names that file. java ✓ (same line) · pyhocon ✓ · spec –
test "capi.errors" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "app.conf", .data = "name = grumpy wombat\ninclude \"limits.conf\"\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "limits.conf", .data = "max = 10\nburst = ${max} ${unknown}\n" });
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(dir);
    const path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/app.conf", .{dir}, 0);
    defer testing.allocator.free(path);

    var err: Error = .{};
    const opts: Options = .{ .env = .none };
    try testing.expectEqual(null, hocon_parse_file(path, &opts, &err));
    try testing.expectEqual(.substitution, err.code);
    try testing.expectEqualStrings("Unresolved", std.mem.span(err.name.?));
    try testing.expect(std.mem.endsWith(u8, std.mem.span(err.file.?), "/limits.conf"));
    try testing.expectEqual(2, err.line);
    try testing.expectEqual(16, err.column);
    try testing.expectEqualStrings("burst = ${max} ${unknown}", std.mem.span(err.source_line.?));
    hocon_error_free(&err);
    try testing.expectEqual(null, err.file);

    // A string: no file name, the place in the string.
    const src = "a = 1\nb = [1, 2\n";
    try testing.expectEqual(null, hocon_parse_string(src, src.len, &opts, &err));
    try testing.expectEqual(.parse, err.code);
    try testing.expectEqualStrings("UnexpectedToken", std.mem.span(err.name.?));
    try testing.expectEqualStrings("", std.mem.span(err.file.?));
    try testing.expectEqual(2, err.line);
    try testing.expectEqual(10, err.column);
    try testing.expectEqualStrings("b = [1, 2", std.mem.span(err.source_line.?));
    hocon_error_free(&err);

    // No file, no place.
    try testing.expectEqual(null, hocon_parse_file("no/such/burrow.conf", &opts, &err));
    try testing.expectEqual(.io, err.code);
    try testing.expectEqualStrings("FileNotFound", std.mem.span(err.name.?));
    try testing.expectEqual(null, err.file);
    try testing.expectEqual(0, err.line);
    hocon_error_free(&err);

    // A string with no place for its error is still no file that was not
    // read: too big to parse (64 MiB, `max_file_size` in Include.zig).
    const big = try testing.allocator.alloc(u8, 64 * 1024 * 1024);
    defer testing.allocator.free(big);
    @memset(big, ' ');
    try testing.expectEqual(null, hocon_parse_string(big.ptr, big.len, &opts, &err));
    try testing.expectEqual(.parse, err.code);
    try testing.expectEqualStrings("StreamTooLong", std.mem.span(err.name.?));
    hocon_error_free(&err);

    // A string includes nothing, unless it is given a directory to look in.
    const include = "include \"limits.conf\"";
    try testing.expectEqual(null, hocon_parse_string(include, include.len, &opts, &err));
    try testing.expectEqualStrings("IncludeNeedsFile", std.mem.span(err.name.?));
    hocon_error_free(&err);
    const dir_z = try testing.allocator.dupeZ(u8, dir);
    defer testing.allocator.free(dir_z);
    const in_dir: Options = .{ .env = .none, .include_dir = dir_z };
    try testing.expectEqual(null, hocon_parse_string(include, include.len, &in_dir, &err));
    try testing.expect(std.mem.endsWith(u8, std.mem.span(err.file.?), "limits.conf"));
    try testing.expectEqual(2, err.line);
    hocon_error_free(&err);

    // NULL in, an error out, not a crash; NULL `err` is fine.
    try testing.expectEqual(null, hocon_parse_file(null, null, &err));
    try testing.expectEqual(.other, err.code);
    try testing.expectEqual(null, hocon_parse_file(null, null, null));
    try testing.expectEqual(.other, hocon_get_int(null, "a", null));
    hocon_free(null);
    hocon_free_string(null);
}

// A field past the caller's `size` is not read: a program built against an
// older hocon.h passes a smaller struct, and gets the defaults for what it
// does not know of. No `size` at all is an error, not options ignored.
test "capi.options size" {
    const include = "include \"no-such-burrow.conf\"";
    try expectRows(&.{.{ "json", "", include, "{}" }}, .{ .env = .none, .include_dir = "." });
    try expectRows(&.{.{ "json", "", include, "parse IncludeNeedsFile" }}, .{ .size = @offsetOf(Options, "include_dir"), .env = .none, .include_dir = "." });
    try expectRows(&.{.{ "json", "", include, "other BadOptions" }}, .{ .size = 0, .env = .none, .include_dir = "." });
}

// The file end to end, as a program reads it: includes next to the file,
// values through the getters, and NULL options (the process environment).
test "capi.a file with an include" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "defaults.conf", .data = "port = 80\ntimeout = 30s\nplugins = [auth]\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "prod.conf", .data = "include \"defaults.conf\"\nport = 443\nplugins += metrics\n" });
    const path = try std.fmt.allocPrintSentinel(testing.allocator, ".zig-cache/tmp/{s}/prod.conf", .{tmp.sub_path}, 0);
    defer testing.allocator.free(path);

    const doc = hocon_parse_file(path, null, null).?;
    defer hocon_free(doc);
    var port: i64 = undefined;
    try testing.expectEqual(.ok, hocon_get_int(doc, "port", &port));
    try testing.expectEqual(443, port);
    var ns: i64 = undefined;
    try testing.expectEqual(.ok, hocon_get_duration_ns(doc, "timeout", &ns));
    try testing.expectEqual(30 * std.time.ns_per_s, ns);
    const json = hocon_to_json(doc, "", null).?;
    defer hocon_free_string(json);
    try testing.expectEqualStrings("{\"port\":443,\"timeout\":\"30s\",\"plugins\":[\"auth\",\"metrics\"]}", std.mem.span(json));
}

// java – · pyhocon – · spec – — ours alone: a deep document on a thread with
// little stack, as musl gives a thread or Python one made smaller, is
// TooDeep past the limit of 500 and read below it, as on any thread: the
// parse and the writing run on a thread of the library's own.
test "capi.a small stack reads as deep as any" {
    const Small = struct {
        fn run(result: *anyerror!void) void {
            result.* = readDeep();
        }

        fn readDeep() !void {
            for ([_]struct { usize, []const u8 }{ .{ 499, "ok" }, .{ 1000, "TooDeep" } }) |row| {
                const n, const want = row;
                for ([_][]const u8{ "appends", "nested", "chained" }) |shape| {
                    var src: std.Io.Writer.Allocating = .init(testing.allocator);
                    defer src.deinit();
                    const w = &src.writer;
                    if (std.mem.eql(u8, shape, "appends")) {
                        try w.writeAll("x = []\n");
                        for (0..n) |i| try w.print("x += [{d}]\n", .{i});
                    } else if (std.mem.eql(u8, shape, "nested")) {
                        try w.writeAll("a = ");
                        for (0..n) |_| try w.writeAll("{b = ");
                        try w.writeAll("1");
                        try w.splatByteAll('}', n);
                    } else {
                        // each field waits for the next, so the chain is resolved in depth
                        for (0..n) |i| try w.print("a{d} = ${{a{d}}}\n", .{ i, i + 1 });
                        try w.print("a{d} = 1\n", .{n});
                    }
                    var err: Error = .{};
                    defer hocon_error_free(&err);
                    const doc = hocon_parse_string(src.written().ptr, src.written().len, &.{ .env = .none }, &err);
                    defer if (doc) |d| hocon_free(d);
                    const got: []const u8 = if (doc) |d| got: {
                        var code: Code = undefined;
                        if (hocon_to_hocon(d, "", &code)) |text| hocon_free_string(text);
                        break :got @tagName(code);
                    } else std.mem.span(err.name.?);
                    testing.expectEqualStrings(want, got) catch |e| {
                        std.debug.print("{s} × {d}\n", .{ shape, n });
                        return e;
                    };
                }
            }
            // as deep as JSON is written, and one deeper
            for ([_]struct { usize, Code }{ .{ 255, .ok }, .{ 400, .too_deep } }) |row| {
                const n, const want = row;
                var src: std.Io.Writer.Allocating = .init(testing.allocator);
                defer src.deinit();
                try src.writer.writeAll("a = ");
                try src.writer.splatByteAll('[', n);
                try src.writer.splatByteAll(']', n);
                const doc = hocon_parse_string(src.written().ptr, src.written().len, &.{ .env = .none }, null).?;
                defer hocon_free(doc);
                var code: Code = undefined;
                if (hocon_to_json(doc, "", &code)) |json| hocon_free_string(json);
                try testing.expectEqual(want, code);
            }
        }
    };
    var result: anyerror!void = {};
    const thread = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, Small.run, .{&result});
    thread.join();
    try result;
}

// java – · pyhocon – · spec – — ours alone: a parse leaves SIGIO and SIGPIPE
// as the program set them, a Python handler too; a fetch of an http(s)
// include sets them while it needs them, and puts them back (see `load`).
test "capi.signals are the program's after a parse" {
    if (std.posix.Sigaction == void or !@hasField(std.posix.SIG, "IO")) return error.SkipZigTest;
    const mine: std.posix.Sigaction = .{ .handler = .{ .handler = owlHoots }, .mask = std.posix.sigemptyset(), .flags = 0 };
    var io_before: std.posix.Sigaction = undefined;
    var pipe_before: std.posix.Sigaction = undefined;
    std.posix.sigaction(.IO, &mine, &io_before);
    defer std.posix.sigaction(.IO, &io_before, null);
    std.posix.sigaction(.PIPE, &mine, &pipe_before);
    defer std.posix.sigaction(.PIPE, &pipe_before, null);
    const options: Options = .{ .env = .none, .include_dir = "." };
    var now: std.posix.Sigaction = undefined;

    const plain = "a = 1\ninclude \"no-such-burrow.conf\"";
    hocon_free(hocon_parse_string(plain, plain.len, &options, null).?);
    std.posix.sigaction(.IO, null, &now);
    try testing.expectEqual(mine.handler.handler, now.handler.handler);
    std.posix.sigaction(.PIPE, null, &now);
    try testing.expectEqual(mine.handler.handler, now.handler.handler);

    // nothing listens on port 1: the fetch fails at once, after the signals are set
    const fetching = "include url(\"http://127.0.0.1:1/owl.conf\")";
    if (hocon_parse_string(fetching, fetching.len, &options, null)) |doc| hocon_free(doc);
    try testing.expectEqual(0, fetching_parses);
    std.posix.sigaction(.IO, null, &now);
    try testing.expectEqual(mine.handler.handler, now.handler.handler);
    std.posix.sigaction(.PIPE, null, &now);
    try testing.expectEqual(mine.handler.handler, now.handler.handler);
}

fn owlHoots(_: std.posix.SIG) callconv(.c) void {}

// A parse that failed with no place in the file is the file not read only
// when it failed reading it; a read error with a place is an include's.
test "capi.parse codes" {
    const rows = [_]struct { anyerror, bool, Code }{
        .{ error.FileNotFound, true, .io },
        .{ error.IsDir, true, .io },
        .{ error.AccessDenied, true, .io },
        .{ error.StreamTooLong, true, .io },
        .{ error.FileNotFound, false, .parse },
        .{ error.UnexpectedToken, true, .parse },
        .{ error.Unresolved, true, .substitution },
        .{ error.OutOfMemory, true, .other },
    };
    for (rows) |row| {
        const e, const unread_file, const want = row;
        testing.expectEqual(want, parseCode(e, unread_file)) catch |err| {
            std.debug.print("{t} unread_file={}\n", .{ e, unread_file });
            return err;
        };
    }
}

// JSON as std.json writes it: 256 lists and objects inside one another, the
// document's own object the first, and no more. Past that it is TOO_DEEP,
// not out of memory. java ⚠️ writes any depth · spec –
test "capi.too deep for JSON" {
    for ([_]struct { usize, Code }{ .{ 255, .ok }, .{ 256, .too_deep } }) |row| {
        const n, const want = row;
        var src: std.Io.Writer.Allocating = .init(testing.allocator);
        defer src.deinit();
        try src.writer.writeAll("a = ");
        try src.writer.splatByteAll('[', n);
        try src.writer.splatByteAll(']', n);
        const doc = hocon_parse_string(src.written().ptr, src.written().len, &.{ .env = .none }, null).?;
        defer hocon_free(doc);
        var code: Code = undefined;
        if (hocon_to_json(doc, "", &code)) |json| hocon_free_string(json);
        testing.expectEqual(want, code) catch |err| {
            std.debug.print("{d} lists\n", .{n});
            return err;
        };
    }
}

// c/hocon.h is written by hand, so nothing but this keeps it true: every
// function it declares is exported here with the same C types, every code and
// every `HOCON_ENV_…` has the number the enums give it, and both structs have
// the fields at the same places. A header that drifts fails the build.
test "capi.hocon.h" {
    const h = @import("hocon_h");
    inline for (@typeInfo(Code).@"enum".fields) |f| {
        const name = comptime if (f.value == 0) "HOCON_OK" else "HOCON_ERR_" ++ upper(f.name);
        try testing.expectEqual(f.value, @field(h, name));
    }
    inline for (@typeInfo(Env).@"enum".fields) |f| {
        try testing.expectEqual(f.value, @field(h, "HOCON_ENV_" ++ upper(f.name)));
    }
    comptime {
        // The translated header has every libc and compiler macro in it too.
        @setEvalBranchQuota(100_000);
        if (!sameAbi(Options, h.hocon_options)) @compileError("hocon_options");
        if (!sameAbi(Error, h.hocon_error)) @compileError("hocon_error");
        var functions = 0;
        for (@typeInfo(h).@"struct".decls) |d| {
            if (!std.mem.startsWith(u8, d.name, "hocon_")) continue;
            if (@typeInfo(@TypeOf(@field(h, d.name))) != .@"fn") continue;
            if (!sameAbi(@TypeOf(@field(@This(), d.name)), @TypeOf(@field(h, d.name)))) @compileError(d.name);
            functions += 1;
        }
        if (functions != 16) @compileError("hocon.h has lost a function, or has one more than the 16 exported here");
    }
}

fn upper(comptime name: []const u8) []const u8 {
    return comptime blk: {
        var buf: [name.len]u8 = undefined;
        _ = std.ascii.upperString(&buf, name);
        const out = buf;
        break :blk &out;
    };
}

/// Whether C passes `Z` (the Zig side) and `C` (translated from hocon.h) the
/// same way: ints of the same size and sign, pointers to such things with the
/// same constness, structs with such fields at the same offsets. An opaque
/// pointer in C (`hocon_doc *`) is any pointer here.
fn sameAbi(comptime Z: type, comptime C: type) bool {
    const z = @typeInfo(Z);
    const c = @typeInfo(C);
    if (z == .optional) return sameAbi(z.optional.child, C);
    if (c == .optional) return sameAbi(Z, c.optional.child);
    if (z == .@"enum") return sameAbi(z.@"enum".tag_type, C);
    if (C == anyopaque or c == .@"opaque") return true;
    return switch (z) {
        .int, .float, .bool, .void => Z == C or (z == .int and c == .int and z.int.bits == c.int.bits and z.int.signedness == c.int.signedness),
        .pointer => |zp| c == .pointer and zp.is_const == c.pointer.is_const and sameAbi(zp.child, c.pointer.child),
        .@"struct" => |zs| blk: {
            if (c != .@"struct" or @sizeOf(Z) != @sizeOf(C) or zs.fields.len != c.@"struct".fields.len) break :blk false;
            for (zs.fields) |f| {
                if (!@hasField(C, f.name) or @offsetOf(Z, f.name) != @offsetOf(C, f.name)) break :blk false;
                if (!sameAbi(f.type, @FieldType(C, f.name))) break :blk false;
            }
            break :blk true;
        },
        .@"fn" => |zf| blk: {
            const cf = c.@"fn";
            if (zf.params.len != cf.params.len or !sameAbi(zf.return_type.?, cf.return_type.?)) break :blk false;
            for (zf.params, cf.params) |zp, cp| if (!sameAbi(zp.type.?, cp.type.?)) break :blk false;
            break :blk true;
        },
        else => false,
    };
}
