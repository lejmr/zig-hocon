//! zig-hocon: a HOCON (Human-Optimized Config Object Notation) parser for Zig.
const std = @import("std");

test {
    _ = @import("Tokenizer.zig");
    _ = @import("Ast.zig");
    _ = @import("utils/unqoute.zig");
    _ = @import("Key.zig");
    _ = @import("Value.zig");
    _ = @import("Config.zig");
    _ = @import("Include.zig");
    _ = @import("stringify.zig");
    _ = @import("units/parse.zig");
    _ = @import("units/Duration.zig");
    _ = @import("units/Period.zig");
    _ = @import("units/Size.zig");
}

// Export functionality to users
const config = @import("Config.zig").Config;
pub const Value = @import("Value.zig").Value;
pub const Parsed = config.Parsed;
pub const parseFromSlice = config.parseFromSlice;
pub const parseFromSliceLeaky = config.parseFromSliceLeaky;
pub const parseFromFile = config.parseFromFile;
pub const parseFromFileLeaky = config.parseFromFileLeaky;
pub const parseFromSliceInDirLeaky = config.parseFromSliceInDirLeaky;
pub const parseFromValue = config.parseFromValue;
pub const parseFromValueIn = config.parseFromValueIn;
pub const ParseOptions = config.ParseOptions;
pub const Diagnostics = @import("Diagnostics.zig");
pub const Key = @import("Key.zig");
pub const parsePath = Key.parsePath;
pub const ParseFromValueError = config.ConvertError;
pub const stringify = @import("stringify.zig").stringify;
pub const stringifyAlloc = @import("stringify.zig").stringifyAlloc;
pub const StringifyOptions = @import("stringify.zig").Options;
pub const writeKey = @import("stringify.zig").writeKey;
pub const Duration = @import("units/Duration.zig");
pub const Period = @import("units/Period.zig");
pub const Size = @import("units/Size.zig");

// ---------------------------------------------------------------------------
// Tests of the public surface: called the way a user calls it, through the
// names exported above and nothing else.
// ---------------------------------------------------------------------------

const testing = std.testing;
// The package as a user imports it, so the tests read like calling code.
const hocon = @This();

// `parseFromSlice` is `parseFromSliceLeaky` plus an arena it owns, the same
// split as std.json. These tests use `testing.allocator` directly, not an arena:
// it reports every byte not given back, so a passing test is the proof that
// `deinit` frees everything the parse allocated.

test "parsed.deinit gives back everything the parse took" {
    const T = struct { name: []const u8, ports: []const u16, tls: ?struct { cert: []const u8 } };
    const parsed = try hocon.parseFromSlice(T, testing.allocator,
        \\name = the dog ate my homework
        \\ports = [80, 443]
        \\tls { cert = grumpy-wombat.pem }
    , .{});
    defer parsed.deinit();

    try testing.expectEqualStrings("the dog ate my homework", parsed.value.name);
    try testing.expectEqualSlices(u16, &.{ 80, 443 }, parsed.value.ports);
    try testing.expectEqualStrings("grumpy-wombat.pem", parsed.value.tls.?.cert);
}

// The value is plain T — no wrapper type to unwrap field by field.
test "parsed.value is the target type itself" {
    const T = struct { a: usize };
    const parsed = try hocon.parseFromSlice(T, testing.allocator, "a = 1", .{});
    defer parsed.deinit();
    comptime std.debug.assert(@TypeOf(parsed.value) == T);
}

// A failed parse returns an error and leaks nothing: the arena, and the memory
// holding the arena, are both given back on the way out (the two `errdefer`s).
test "parsed.a failed parse leaves nothing behind" {
    const T = struct { a: usize, b: []const u8 };
    try testing.expectError(error.MissingField, hocon.parseFromSlice(T, testing.allocator, "b = the cat sat on the keyboard", .{}));
    try testing.expectError(error.TypeMismatch, hocon.parseFromSlice(T, testing.allocator, "a { x = 1 }\nb = x", .{}));
    try testing.expectError(error.UnexpectedToken, hocon.parseFromSlice(T, testing.allocator, "a = 1\nb = {", .{}));
}

// Parsed is passed around by value, so a copy has to free the same memory as the
// original — which works only because the arena sits behind a pointer.
test "parsed.a copy frees what the original allocated" {
    const T = struct { a: []const u8 };
    const original = try hocon.parseFromSlice(T, testing.allocator, "a = the coffee runs out on monday morning", .{});
    const copy = original;
    defer copy.deinit();
    try testing.expectEqualStrings("the coffee runs out on monday morning", copy.value.a);
}

// Every allocation the parse makes is made to fail once, in turn. Each of those
// runs has to end in error.OutOfMemory with nothing leaked — the check the other
// tests cannot make, because they never see an allocation fail halfway.
test "parsed.out of memory at any point leaks nothing" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            const parsed = try hocon.parseFromSlice(struct { a: []const u8, b: ?usize }, gpa, "a = and now it looks innocent\nb = 2", .{});
            parsed.deinit();
        }
    }.run, .{});
}

// ---------------------------------------------------------------------------
// Files: the point of includes. `prod.conf` pulls in `defaults.conf` and
// overrides some of it. The files are written to a temp directory and parsed
// through their path, the way a program would.
// ---------------------------------------------------------------------------

const Prod = struct { name: []const u8, port: u16, tls: struct { cert: []const u8, key: []const u8 } };

/// Writes the two files and returns the path of `prod.conf`, relative to where the test runs.
fn writeProd(tmp: *testing.TmpDir) ![]u8 {
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "defaults.conf",
        .data = "name = the dog ate my homework\nport = 80\ntls { cert = grumpy-wombat.pem }",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "prod.conf",
        .data = "include \"defaults.conf\"\nport = 443\ntls { key = sleepy-owl.key }",
    });
    return std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/prod.conf", .{tmp.sub_path});
}

// java ✓ · pyhocon ✓ · spec ✓ — the included defaults are there, what prod.conf
// writes after the include wins, and objects merge (tls has both keys). Nothing
// is left behind by `deinit`: this is `testing.allocator`, not an arena.
test "file.prod.conf includes defaults.conf and overrides it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeProd(&tmp);
    defer testing.allocator.free(path);

    const parsed = try hocon.parseFromFile(Prod, testing.allocator, testing.io, path, .{});
    defer parsed.deinit();

    try testing.expectEqualStrings("the dog ate my homework", parsed.value.name);
    try testing.expectEqual(443, parsed.value.port);
    try testing.expectEqualStrings("grumpy-wombat.pem", parsed.value.tls.cert);
    try testing.expectEqualStrings("sleepy-owl.key", parsed.value.tls.key);
}

// Every allocation of the file parse, includes included, fails once in turn.
test "file.out of memory at any point leaks nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeProd(&tmp);
    defer testing.allocator.free(path);

    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: std.mem.Allocator, file: []const u8) !void {
            const parsed = try hocon.parseFromFile(Prod, gpa, testing.io, file, .{});
            parsed.deinit();
        }
    }.run, .{path});
}

// The workflow of round 1 end to end (#10): the program writes its defaults
// once with `stringify`, an environment includes them and says what differs —
// an override, an object merged by a dotted key, `+=` — and that reads back
// into the struct, everything it does not mention still the default.
// java ✓ (same JSON from prod.conf) · pyhocon ⚠️ fails on `+=` · spec ✓
test "file.defaults.conf from stringify, prod.conf on top of it" {
    const App = struct {
        name: []const u8 = "grumpy wombat",
        port: u16 = 8080,
        debug: bool = true,
        plugins: []const []const u8 = &.{"auth"},
        db: struct { host: []const u8 = "localhost", pool: u8 = 4 } = .{},
        motto: ?[]const u8 = null,
    };
    const defaults = try hocon.stringifyAlloc(testing.allocator, App{}, .{});
    defer testing.allocator.free(defaults);
    try testing.expectEqualStrings(
        \\name = "grumpy wombat"
        \\port = 8080
        \\debug = true
        \\plugins = [auth]
        \\db {
        \\  host = localhost
        \\  pool = 4
        \\}
        \\
    , defaults);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "defaults.conf", .data = defaults });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "prod.conf", .data =
        \\include "defaults.conf"
        \\port = 443
        \\debug = off
        \\plugins += metrics
        \\db.host = db.example.org
        \\motto = the wombat sleeps at noon
        \\
    });
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/prod.conf", .{tmp.sub_path});
    defer testing.allocator.free(path);

    const parsed = try hocon.parseFromFile(App, testing.allocator, testing.io, path, .{});
    defer parsed.deinit();
    try testing.expectEqualDeep(App{
        .port = 443,
        .debug = false,
        .plugins = &.{ "auth", "metrics" },
        .db = .{ .host = "db.example.org" },
        .motto = "the wombat sleeps at noon",
    }, parsed.value);
}

// Durations, periods and sizes (round 2) the way a program has them: its
// defaults written with `stringify`, an environment that says what differs in
// any unit it likes, read back from disk into the same struct. A unit there is
// none of fails with the place it is written, in the file it is written in.
// java ✓ (getDuration, getPeriod, getBytes of prod.conf give the same values;
// java's error is a BadValue at defaults.conf: 2) · pyhocon – · spec ✓
test "file.durations, periods and sizes from files" {
    const Cache = struct {
        ttl: hocon.Duration = .of(30, .s),
        retention: hocon.Period = .of(3, .mo),
        size: hocon.Size = .of(512, .MiB),
        sweeps: []const hocon.Duration = &.{ .of(1, .h), .of(1500, .ms) },
    };
    const defaults = try hocon.stringifyAlloc(testing.allocator, Cache{}, .{});
    defer testing.allocator.free(defaults);
    try testing.expectEqualStrings(
        \\ttl = 30s
        \\retention = 3mo
        \\size = 512MiB
        \\sweeps = [1h, 1500ms]
        \\
    , defaults);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "defaults.conf", .data = defaults });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "prod.conf", .data =
        \\include "defaults.conf"
        \\ttl = 2 minutes
        \\retention = 14
        \\size = "1.5 GiB"
        \\sweeps += 90
        \\
    });
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/prod.conf", .{tmp.sub_path});
    defer testing.allocator.free(path);

    const parsed = try hocon.parseFromFile(Cache, testing.allocator, testing.io, path, .{});
    defer parsed.deinit();
    try testing.expectEqualDeep(Cache{
        .ttl = .of(120, .s),
        .retention = .of(2, .weeks),
        .size = .of(1536, .MiB),
        .sweeps = &.{ .of(1, .h), .of(1500, .ms), .of(90, .ms) },
    }, parsed.value);
    try testing.expectEqual(120_000, parsed.value.ttl.whole(.ms));
    try testing.expectEqual(1.5, parsed.value.size.as(.GiB));

    // A typo in the included file: the error points there, not at prod.conf.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "defaults.conf", .data = "ttl = 30s\nsweeps = [1h, 1500 MS]\n" });
    var diag: hocon.Diagnostics = .{};
    defer diag.deinit(testing.allocator);
    try testing.expectError(error.UnknownUnit, hocon.parseFromFile(Cache, testing.allocator, testing.io, path, .{ .diagnostics = &diag }));
    const loc = diag.location.?;
    try testing.expect(std.mem.endsWith(u8, loc.path, "defaults.conf"));
    try testing.expectEqual(2, loc.line);
    try testing.expectEqual(15, loc.column);
    try testing.expectEqualStrings("sweeps = [1h, 1500 MS]", loc.source_line);
}

// ---------------------------------------------------------------------------
// The environment (#11) is the caller's to give: `ParseOptions.env`. The
// library never reads the process on its own, so these tests build their own
// variables and the shell they run in cannot change the result.
// ---------------------------------------------------------------------------

// java ✓ · pyhocon ⚠️ (no `[]`) · spec ✓ — a variable is a string, and a typed
// field converts it like any other string: "9090" into a u16.
test "env.variables fill a struct" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("PORT", "9090");
    try env.put("ADMINS_0", "grumpy-owl");
    try env.put("ADMINS_1", "sleepy-badger");

    const T = struct { port: u16, admins: []const []const u8, motto: []const u8 };
    const parsed = try hocon.parseFromSlice(T, testing.allocator,
        \\port = 80
        \\port = ${?PORT}
        \\admins = ${ADMINS[]}
        \\motto = "the badger guards port "${PORT}
    , .{ .env = .{ .map = &env } });
    defer parsed.deinit();

    try testing.expectEqual(9090, parsed.value.port);
    try testing.expectEqual(2, parsed.value.admins.len);
    try testing.expectEqualStrings("sleepy-badger", parsed.value.admins[1]);
    try testing.expectEqualStrings("the badger guards port 9090", parsed.value.motto);
}

// The values are copied out of the map: freeing it right after the parse leaves
// the result intact (the map's memory is scribbled over first, so a borrowed
// slice would read as garbage, not as a lucky pass).
test "env.the result outlives the map" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    try env.put("MOOD", "grumpy");
    const parsed = try hocon.parseFromSlice(hocon.Value, testing.allocator, "mood = ${MOOD}", .{ .env = .{ .map = &env } });
    defer parsed.deinit();
    @memset(@constCast(env.get("MOOD").?), 'x');
    env.deinit();

    try testing.expectEqualStrings("grumpy", parsed.value.object[0].value.scalar.value);
}

// `.keep`: everything the files can answer is resolved, what waits for the
// environment stays in the tree — to be written out and resolved where it
// runs. Zig only, no oracle has the mode. A struct cannot hold what waits,
// so a field that needs it is `Unresolved`; one that does not is fine.
test "env.keep leaves the environment for later" {
    const parsed = try hocon.parseFromSlice(hocon.Value, testing.allocator,
        \\port = ${?PORT}
        \\motto = the wombat sleeps at noon
    , .{ .env = .keep });
    defer parsed.deinit();
    try testing.expect(!parsed.value.isResolved());
    try testing.expectEqualStrings("PORT", parsed.value.object[0].value.ref.path[0].value);

    const T = struct { motto: []const u8 };
    try testing.expectError(error.Unresolved, hocon.parseFromSlice(struct { port: u16 }, testing.allocator, "port = ${PORT}", .{ .env = .keep }));
    const typed = try hocon.parseFromSlice(T, testing.allocator, "port = ${PORT}\nmotto = grumpy", .{ .env = .keep });
    defer typed.deinit();
    try testing.expectEqualStrings("grumpy", typed.value.motto);
}

// The files of the CLI test (build.zig, tests/cli-env): kept on one machine,
// resolved on another with its variables, it is what the CLI prints there.
// The ref from `server.conf`, included under `server`, has lost the scope it
// was tried with: what is left is the variable's name.
test "env.keep then resolve later is the CLI's answer" {
    const parsed = try hocon.parseFromFile(hocon.Value, testing.allocator, testing.io, "tests/cli-env/prod.conf", .{ .env = .keep });
    defer parsed.deinit();
    const port = parsed.value.object[0].value.object[1].value;
    try testing.expectEqual(2, port.stack.len);
    try testing.expectEqual(1, port.stack[1].ref.path.len);
    try testing.expectEqualStrings("WOMBAT_PORT", port.stack[1].ref.path[0].value);

    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("WOMBAT_PORT", "9090");
    try env.put("WOMBAT_ADMINS_0", "grumpy-owl");
    try env.put("WOMBAT_ADMINS_1", "sleepy-badger");
    try env.put("WOMBAT_MOOD", "grumpy");

    var later = parsed.value;
    var err_pos: ?hocon.Value.Pos = null;
    try later.resolve(parsed.arena.allocator(), .{ .map = &env }, &err_pos);
    const json = try std.json.Stringify.valueAlloc(testing.allocator, later, .{});
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("{\"server\":{\"host\":\"localhost\",\"port\":\"9090\"},\"admins\":[\"grumpy-owl\",\"sleepy-badger\"],\"motto\":\"the grumpy wombat sleeps at noon\",\"HOME\":null,\"home\":null}", json);
}

// include-semantics-substitution.1 · java ⚠️ (fails 009 and 014, leaves `a`
// out of 011) · spec ✓ — a ref from an included file that is kept because its
// scoped target waits keeps its scope: resolved later, the scoped `x.y`
// vanishes and the path as written, `x.y` at the root, is found instead.
test "env.keep, a ref found with the scope keeps the fallback to the path as written" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var empty: std.process.Environ.Map = .init(gpa);

    for ([_][]const u8{
        "conformance/suite/include-substitution/009-undefined-optional-at-fixed-up-path-falls-back/main.conf",
        "conformance/suite/include-substitution/011-optional-reference-falls-back-too/main.conf",
        "conformance/suite/include-substitution/014-unrelated-key-does-not-change-the-result/main.conf",
    }) |path| {
        const now = try hocon.parseFromFileLeaky(hocon.Value, gpa, testing.io, path, .{ .env = .{ .map = &empty } });
        var later = try hocon.parseFromFileLeaky(hocon.Value, gpa, testing.io, path, .{ .env = .keep });
        var err_pos: ?hocon.Value.Pos = null;
        try later.resolve(gpa, .{ .map = &empty }, &err_pos);
        try testing.expectEqualStrings(
            try std.json.Stringify.valueAlloc(gpa, now, .{}),
            try std.json.Stringify.valueAlloc(gpa, later, .{}),
        );
    }
}

// Compaction through the library: kept, written by `stringify`, and read
// again with the variables of where it runs, the file of the CLI test
// (build.zig, tests/cli-compact) is what reading it there right away gives —
// with every variable set, and with only the required `HOST`.
// java ✓ (both files, same JSON; ⚠️ fails on the original with only `HOST`,
// lightbend/config#863) · pyhocon ⚠️ no `[]` · spec ✓
test "env.keep, stringify, read with the variables is reading now" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const path = "tests/cli-compact/prod.conf";

    const kept = try hocon.parseFromFileLeaky(hocon.Value, gpa, testing.io, path, .{ .env = .keep });
    const text = try hocon.stringifyAlloc(gpa, kept, .{});

    var all: std.process.Environ.Map = .init(gpa);
    try all.put("HOST", "wombat.example");
    try all.put("PORT", "9090");
    try all.put("L_0", "alpha");
    try all.put("L_1", "beta");
    try all.put("DB_TIMEOUT", "5");
    var host: std.process.Environ.Map = .init(gpa);
    try host.put("HOST", "wombat.example");

    for ([_]*const std.process.Environ.Map{ &all, &host }) |env| {
        const now = try hocon.parseFromFileLeaky(hocon.Value, gpa, testing.io, path, .{ .env = .{ .map = env } });
        const later = try hocon.parseFromSliceLeaky(hocon.Value, gpa, try gpa.dupeZ(u8, text), .{ .env = .{ .map = env } });
        try testing.expectEqualStrings(
            try std.json.Stringify.valueAlloc(gpa, now, .{}),
            try std.json.Stringify.valueAlloc(gpa, later, .{}),
        );
    }
}

/// `src` kept and written by `stringify`. That text has to read back, with
/// and without the variables of `compact_env`, as `src` does right away; if
/// not, the row says which.
fn dumpCompacted(gpa: std.mem.Allocator, src: [:0]const u8) anyerror![]u8 {
    const kept = try hocon.parseFromSliceLeaky(hocon.Value, gpa, src, .{ .env = .keep });
    const text = try hocon.stringifyAlloc(gpa, kept, .{});

    var none: std.process.Environ.Map = .init(gpa);
    var some: std.process.Environ.Map = .init(gpa);
    for (compact_env) |kv| try some.put(kv[0], kv[1]);
    for ([_]*const std.process.Environ.Map{ &none, &some }) |env| {
        const now = try resolvedJson(gpa, src, env);
        const later = try resolvedJson(gpa, try gpa.dupeZ(u8, text), env);
        if (!std.mem.eql(u8, now, later)) return std.fmt.allocPrint(gpa, "{s} reads back as {s}, not {s}", .{ text, later, now });
    }
    return text;
}

const compact_env = [_][2][]const u8{
    .{ "PORT", "9090" },
    .{ "HOST", "wombat.example" },
    .{ "L_0", "alpha" },
    .{ "L_1", "beta" },
    .{ "X", "x" },
    .{ "O", "plain text" },
};

/// JSON, or the name of the error.
fn resolvedJson(gpa: std.mem.Allocator, src: [:0]const u8, env: *const std.process.Environ.Map) ![]const u8 {
    const value = hocon.parseFromSliceLeaky(hocon.Value, gpa, src, .{ .env = .{ .map = env } }) catch |err| return @errorName(err);
    return std.json.Stringify.valueAlloc(gpa, value, .{});
}

// What compaction writes. A key whose top waits is written once per layer,
// bottom first, the way it was: `port = 8080` then `port = ${?PORT}` is a
// default and the variable over it, and reads back to 9090 with PORT set and
// to 8080 without. A key that refers to one that waits stays a reference.
// Zig only, no oracle has `.keep`; each row is checked against reading the
// source right away (`dumpCompacted`).
test "env.keep is written as a file that resolves the same later" {
    try table.expectAll(&.{
        .ok("port = 8080\nport = ${?PORT}", "port = 8080\nport = ${?PORT}\n"),
        .ok("port = ${PORT}", "port = ${PORT}\n"),
        .ok("a = ${?PORT}\nb = ${a}", "a = ${?PORT}\nb = ${a}\n"),
        .ok("url = \"http://\"${HOST}\":\"${port}\nport = 80", "url = \"http://\"${HOST}\":\"80\nport = 80\n"),
        .ok("hosts = [localhost]\nhosts = ${?L[]}", "hosts = [localhost]\nhosts = ${?L[]}\n"),
        .ok("l = [1]\nl += ${?X}", "l = [1, ${?X}]\n"),
        .ok("hosts = ${?L[]}\nhosts += spare", "hosts = ${?L[]}\nhosts += spare\n"),
        .ok("o { p = 1 }\no = ${?O}\no { q = 2 }", "o {\n  p = 1\n}\no = ${?O}\no {\n  q = 2\n}\n"),
        .ok("m = the ${w} sleeps ${?X}\nw = wombat", "m = \"the wombat sleeps \"${?X}\nw = wombat\n"),
        // A field that waits is no element: the list and the object join later.
        .ok("l = [1] { 0 = ${?X} }", "l = [1]{\n  \"0\" = ${?X}\n}\n"),
        .ok("l = [] { 0 { m = moody }, 0 = ${?O} } [2]", "l = []{\n  \"0\" {\n    m = moody\n  }\n  \"0\" = ${?O}\n}[2]\n"),
        .ok("l = [] { 0 = tea, 1 = ${?X} }", "l = []{\n  \"0\" = tea\n  \"1\" = ${?X}\n}\n"),
    }, .{ .dump = dumpCompacted });

    // The first row, read back: the variable when it is set, the default when not.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var none: std.process.Environ.Map = .init(gpa);
    var port: std.process.Environ.Map = .init(gpa);
    try port.put("PORT", "9090");
    try testing.expectEqualStrings("{\"port\":\"9090\"}", try resolvedJson(gpa, "port = 8080\nport = ${?PORT}\n", &port));
    try testing.expectEqualStrings("{\"port\":8080}", try resolvedJson(gpa, "port = 8080\nport = ${?PORT}\n", &none));
}

// `.resolve = false`: the tree as written, every `${…}` still in it — also
// the ones the document itself could answer. Written by `stringify`, it is a
// file that reads back, resolved, as the source does (`dumpUnresolved`).
// java ✓ (parseString without resolve() renders the same `${…}`, a key written
// twice twice, `+=` as `${?l}[2]`) · pyhocon ✓ (`resolve=False`) · spec ✓
test "resolve.false keeps every substitution" {
    try table.expectAll(&.{
        .ok("a = 1\nb = ${a}", "a = 1\nb = ${a}\n"),
        .ok("port = 8080\nport = ${?PORT}", "port = 8080\nport = ${?PORT}\n"),
        .ok("url = \"http://\"${HOST}\":\"${port}\nport = 80", "url = \"http://\"${HOST}\":\"${port}\nport = 80\n"),
        .ok("m = the ${w} sleeps\nw = wombat", "m = \"the \"${w}\" sleeps\"\nw = wombat\n"),
        .ok("o { p = 1 }\no = ${?O}\no { q = 2 }", "o {\n  p = 1\n}\no = ${?O}\no {\n  q = 2\n}\n"),
        .ok("a = ${?nope}", "a = ${?nope}\n"),
    }, .{ .dump = dumpUnresolved });
}

/// `src` read without resolving and written by `stringify`; that text has to
/// read back as `src` does, with and without the variables of `compact_env`.
fn dumpUnresolved(gpa: std.mem.Allocator, src: [:0]const u8) anyerror![]u8 {
    const tree = try hocon.parseFromSliceLeaky(hocon.Value, gpa, src, .{ .resolve = false });
    const text = try hocon.stringifyAlloc(gpa, tree, .{});

    var none: std.process.Environ.Map = .init(gpa);
    var some: std.process.Environ.Map = .init(gpa);
    for (compact_env) |kv| try some.put(kv[0], kv[1]);
    for ([_]*const std.process.Environ.Map{ &none, &some }) |env| {
        const now = try resolvedJson(gpa, src, env);
        const later = try resolvedJson(gpa, try gpa.dupeZ(u8, text), env);
        if (!std.mem.eql(u8, now, later)) return std.fmt.allocPrint(gpa, "{s} reads back as {s}, not {s}", .{ text, later, now });
    }
    return text;
}

// Into a struct: a field with a substitution in it cannot be filled, one
// without is. java ✓ (getString on an unresolved config: NotResolved) ·
// pyhocon ⚠️ hands back the substitution object · spec –
test "resolve.false into a struct" {
    const T = struct { motto: []const u8 };
    try testing.expectError(error.Unresolved, hocon.parseFromSlice(T, testing.allocator, "motto = ${m}\nm = grumpy", .{ .resolve = false }));
    const parsed = try hocon.parseFromSlice(T, testing.allocator, "motto = grumpy\nport = ${PORT}", .{ .resolve = false });
    defer parsed.deinit();
    try testing.expectEqualStrings("grumpy", parsed.value.motto);
}

// Not resolving changes nothing about where a syntax error is, and a
// substitution that has no value is no error at all.
test "diagnostics.resolve = false" {
    var cases = [_]table.Case{
        .ok("a = ${b\n       ^ UnexpectedToken", "a = ${b\n       ^ UnexpectedToken"),
        .ok("a = [${b}] {}\n           ^ UnsupportedConcatenation", "a = [${b}] {}\n           ^ UnsupportedConcatenation"),
    };
    try table.expectAll(&cases, .{ .dump = struct {
        fn dump(gpa: std.mem.Allocator, row: [:0]const u8) anyerror![]u8 {
            const src = try withoutCaret(gpa, row);
            var diag: hocon.Diagnostics = .{};
            const err = if (hocon.parseFromSliceLeaky(hocon.Value, gpa, src, .{ .diagnostics = &diag, .resolve = false })) |_|
                return error.ParsedWithoutError
            else |e|
                e;
            return drawCaret(gpa, src, err, diag);
        }
    }.dump });
    const tree = try hocon.parseFromSlice(hocon.Value, testing.allocator, "a = ${b}", .{ .resolve = false });
    tree.deinit();
}

// A string that stands for a file in a directory includes from there, the
// way pyhocon's `parse_string(…, basedir=…)` does. java – (parseString has no
// directory) · pyhocon ✓ · spec ✓ (a relative include is found where the
// including file is)
test "file.a slice in a directory includes from it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    testing.allocator.free(try writeProd(&tmp));
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(dir);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const app = try hocon.parseFromSliceInDirLeaky(Prod, arena.allocator(), testing.io, dir, "include \"prod.conf\"\nname = the owl ate the router", .{});
    try testing.expectEqualStrings("the owl ate the router", app.name);
    try testing.expectEqual(443, app.port);
    try testing.expectEqualStrings("grumpy-wombat.pem", app.tls.cert);
}

// ---------------------------------------------------------------------------
// Value as JSON — what the `hocon` CLI prints, and what the conformance suite
// compares. `parseFromSlice(hocon.Value, …)` hands back the tree, and
// std.json.Stringify finds `Value.jsonStringify` on its own.
//
// Java's rendering is from
// tools/oracle/hocon-java; it sorts keys, which is why the key order below is
// ours (written order) and not compared against it.
// ---------------------------------------------------------------------------

fn expectJson(src: [:0]const u8, expected: []const u8) !void {
    const parsed = try hocon.parseFromSlice(hocon.Value, testing.allocator, src, .{});
    defer parsed.deinit();
    const json = try std.json.Stringify.valueAlloc(testing.allocator, parsed.value, .{});
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(expected, json);
}

// S1 · java ✓ · pyhocon ✓ · spec ✓ — unquoted true/false/null and numbers are
// themselves, as in JSON.
test "json.unquoted scalars keep their JSON type" {
    try expectJson("a = 1", "{\"a\":1}");
    try expectJson("a = -3.25", "{\"a\":-3.25}");
    try expectJson("a = true", "{\"a\":true}");
    try expectJson("a = false", "{\"a\":false}");
    try expectJson("a = null", "{\"a\":null}");
}

// java ✓ · pyhocon ✓ · spec ✓ — quotes make a string, whatever is inside.
test "json.quoted is always a string" {
    try expectJson("a = \"1\"", "{\"a\":\"1\"}");
    try expectJson("a = \"true\"", "{\"a\":\"true\"}");
    try expectJson("a = \"null\"", "{\"a\":\"null\"}");
    try expectJson("a = \"say \\\"hi\\\"\"", "{\"a\":\"say \\\"hi\\\"\"}");
}

// string-value-concatenation.10 · java ≈ · pyhocon ≈ · spec ✓ — a number prints as written. Both oracles
// renormalise 1e5 (java 100000, pyhocon 100000.0): the same JSON value, other text.
test "json.a number prints as written" {
    try expectJson("a = 1e5", "{\"a\":1e5}");
    try expectJson("a = 1.50", "{\"a\":1.50}");
}

// A number is JSON's number grammar, all of the text or nothing. What starts
// like one and is not — `-foo`, `1.` — is a parse error, see "numbers" in Ast.zig.
// `.5`   · java ✓ · pyhocon ⚠️ 0.5 — JSON numbers need a digit before the dot,
//          and a dot does not start one.
// `1 2`  · java ✓ · pyhocon ✓ — one unquoted text with a space, not a number.
// `10.0bar` · java ✓ · pyhocon ✓ — a number with text after it is text.
test "json.almost a number is a string" {
    try expectJson("a = .5", "{\"a\":\".5\"}");
    try expectJson("a = 1 2", "{\"a\":\"1 2\"}");
    try expectJson("a = 10.0bar", "{\"a\":\"10.0bar\"}");
    try expectJson("a = true foo", "{\"a\":\"true foo\"}");
    try expectJson("a = the dog ate my homework", "{\"a\":\"the dog ate my homework\"}");
}

// java ✓ · pyhocon ✓ · spec ✓ — containers nest, and keys come out in the order
// they were written.
test "json.objects and arrays" {
    try expectJson("a { b = [1, x, {c = 2}] }", "{\"a\":{\"b\":[1,\"x\",{\"c\":2}]}}");
    try expectJson("b = 1\na = 2", "{\"b\":1,\"a\":2}");
    try expectJson("a { b = 1 }\na { c = 2 }", "{\"a\":{\"b\":1,\"c\":2}}");
    try expectJson("a = []\nb {}", "{\"a\":[],\"b\":{}}");
    try expectJson("", "{}");
}

// omit-root-braces/006-010 · java ⚠️ · pyhocon ✓ · spec ✓ — a document that
// starts with `[` is an array, after comments and blank lines too. Java has no
// array-rooted config and rejects all four with WrongType.
test "json.an array root is the document" {
    try expectJson("[1, 2, 3]", "[1,2,3]");
    try expectJson("[]", "[]");
    try expectJson("# a leading comment\n[1, 2]", "[1,2]");
    try expectJson("\n[1, 2]", "[1,2]");
}

// As in std.json, the root is whatever T says, so a list parses into a slice.
test "parsed.an array root parses into a slice" {
    const parsed = try hocon.parseFromSlice([]u32, testing.allocator, "[4, 8, 15, 16, 23, 42]", .{});
    defer parsed.deinit();
    try testing.expectEqualSlices(u32, &.{ 4, 8, 15, 16, 23, 42 }, parsed.value);
}

// unchanged-from-json/027 · java ✓ · pyhocon ⚠️ (keeps the escape as text) ·
// spec ✓ — a surrogate on its own goes out as it came in, in a value and in a
// key; std.json alone would write its WTF-8 bytes as a list of numbers.
test "json.a surrogate on its own is written as it was read" {
    const parsed = try hocon.parseFromSlice(hocon.Value, testing.allocator, "\"\\ud83d\" = \"half a \\ud83d\"", .{});
    defer parsed.deinit();
    const json = try std.json.Stringify.valueAlloc(testing.allocator, parsed.value, .{});
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("{\"\\ud83d\":\"half a \\ud83d\"}", json);
}

// Resolution runs inside the parse, so a substitution with nothing behind it is
// refused there — Stringify allows no error of its own, printing is too late.
test "json.an unresolved substitution is an error" {
    try testing.expectError(error.Unresolved, hocon.parseFromSlice(hocon.Value, testing.allocator, "a = ${b}", .{}));
    try testing.expectError(error.Unresolved, hocon.parseFromSlice(hocon.Value, testing.allocator, "a { b = [1, ${c}] }", .{}));
}

// Zig only (java – · pyhocon – · spec –) — a tree std.json cannot write,
// deeper than its 256 open lists and objects, is an error, not a panic; the
// parser takes up to 500.
test "json.deeper than std.json writes is an error" {
    const parsed = try hocon.parseFromSlice(hocon.Value, testing.allocator, "a = " ++ "[" ** 300 ++ "]" ** 300, .{});
    defer parsed.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectError(error.WriteFailed, std.json.Stringify.value(parsed.value, .{}, &out.writer));
}

// ---------------------------------------------------------------------------
// Diagnostics — where a parse failed. The error itself stays a plain Zig error;
// `Diagnostics` keeps the first one and where it is: the file, the byte offset,
// line and column (1-based, the column in code points, the way
// std.zig.Ast.tokenLocation counts) and the line itself. Errors in included
// files are in Include.zig, next to the files they need.
//
// The caret tables write a row the way a reader would point at the mistake: the
// source, with one extra line under the line the error is on — `^` under its
// column, then the error's name. A source line never starts with `^` (it is
// forbidden in unquoted text), so the caret line cannot be mistaken for one.
//
// Oracles: the rows below are errors for java too (`String: <line>:` matches
// ours on every row) except where a group says otherwise. Neither oracle gives a
// column we could copy: java reports the line only, pyhocon counts bytes and
// points one past the end of the token (`port = 80 [1]` → col 14). The column
// is ours: the first byte of the token or part that cannot stand there, or the
// `${` of the substitution that failed.
// ---------------------------------------------------------------------------

const table = @import("table.zig");

fn expectCarets(rows: []const [:0]const u8) !void {
    const cases = try testing.allocator.alloc(table.Case, rows.len);
    defer testing.allocator.free(cases);
    for (cases, rows) |*c, row| c.* = .ok(row, row);
    try table.expectAll(cases, .{ .dump = dumpCaret });
}

/// Takes the caret line out of `row`, parses what is left, and puts a caret line
/// back where the diagnostic says — so a correct parse renders the row unchanged.
fn dumpCaret(gpa: std.mem.Allocator, row: [:0]const u8) anyerror![]u8 {
    return caretOf(hocon.Value, gpa, row, .none);
}

/// The same, with `PORT` and `HOSTS_0` set in the environment.
fn dumpCaretEnv(gpa: std.mem.Allocator, row: [:0]const u8) anyerror![]u8 {
    var map: std.process.Environ.Map = .init(gpa);
    try map.put("PORT", "8080");
    try map.put("HOSTS_0", "alpha");
    return caretOf(hocon.Value, gpa, row, .{ .map = &map });
}

/// The same, with the environment left for later (`.keep`).
fn dumpCaretKept(gpa: std.mem.Allocator, row: [:0]const u8) anyerror![]u8 {
    return caretOf(hocon.Value, gpa, row, .keep);
}

/// Read into a struct with a field of each type in the units format, `TIMEOUT`
/// set in the environment.
fn dumpCaretUnits(gpa: std.mem.Allocator, row: [:0]const u8) anyerror![]u8 {
    var map: std.process.Environ.Map = .init(gpa);
    try map.put("TIMEOUT", "a fortnight");
    const T = struct { t: ?hocon.Duration = null, p: ?hocon.Period = null, s: ?hocon.Size = null };
    return caretOf(T, gpa, row, .{ .map = &map });
}

/// `T` is what the row is read into; `hocon.Value` stops at the tree.
fn caretOf(comptime T: type, gpa: std.mem.Allocator, row: [:0]const u8, env: hocon.Value.Env) anyerror![]u8 {
    const src = try withoutCaret(gpa, row);

    var diag: hocon.Diagnostics = .{};
    const options: hocon.ParseOptions = .{ .diagnostics = &diag, .env = env };
    const err = if (hocon.parseFromSliceLeaky(T, gpa, src, options)) |_|
        return error.ParsedWithoutError
    else |e|
        e;
    return drawCaret(gpa, src, err, diag);
}

/// The source of a caret row: the row with its caret line taken out.
fn withoutCaret(gpa: std.mem.Allocator, row: [:0]const u8) ![:0]u8 {
    var source: std.ArrayList(u8) = .empty;
    var rows = std.mem.splitScalar(u8, row, '\n');
    var first = true;
    while (rows.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "^")) continue;
        if (!first) try source.append(gpa, '\n');
        first = false;
        try source.appendSlice(gpa, line);
    }
    return source.toOwnedSliceSentinel(gpa, 0);
}

/// `src` with a caret line under the place `diag` holds for `err`.
fn drawCaret(gpa: std.mem.Allocator, src: []const u8, err: anyerror, diag: hocon.Diagnostics) ![]u8 {
    // Said in the table's own report rather than as a bare `TestUnexpectedError`.
    const kept = diag.err orelse return std.fmt.allocPrint(gpa, "{t}, but Diagnostics is empty", .{err});
    if (kept != err) return std.fmt.allocPrint(gpa, "{t}, but Diagnostics holds {t}", .{ err, kept });

    const loc = diag.location orelse return std.fmt.allocPrint(gpa, "{t}, but without a position", .{err});
    if (loc.line == 0 or loc.column == 0) return std.fmt.allocPrint(gpa, "{t} at {d}:{d}, but both count from 1", .{ err, loc.line, loc.column });

    var out: std.Io.Writer.Allocating = .init(gpa);
    var lines = std.mem.splitScalar(u8, src, '\n');
    var n: usize = 1;
    while (lines.next()) |line| : (n += 1) {
        if (n > 1) try out.writer.writeByte('\n');
        try out.writer.writeAll(line);
        if (n == loc.line) {
            try out.writer.writeByte('\n');
            try out.writer.splatByteAll(' ', loc.column - 1);
            try out.writer.print("^ {t}", .{err});
            if (diag.key_path.len > 0) try out.writer.print(" at {s}", .{diag.key_path});
            if (diag.expected.len > 0) try out.writer.print(": expected {s}", .{diag.expected});
        }
    }
    if (loc.line >= n) try out.writer.print("\n(past the last line: {d}:{d} {t})", .{ loc.line, loc.column, err });
    return out.toOwnedSlice();
}

// Parser: the token it did not expect. At the end of the input that is right
// after the last character that is not whitespace, also when the file ends with
// a newline: the line after it is empty, and an empty line shows nothing. Zig
// does the same with a missing `;`, at the end of the token before it.
// java ✓ · pyhocon ⚠️ — pyhocon takes `a = ` as an empty string.
// `a = [1, 2⏎` · java ⚠️ line 2 · pyhocon ⚠️ 2:1 — both put the end of the input
// on the empty line after the newline.
// `a\nb = 1` is a newline inside an unfinished member, so the token is `b`.
test "diagnostics.UnexpectedToken" {
    try expectCarets(&.{
        \\a = 
        \\   ^ UnexpectedToken
        ,
        \\a = [1, 2
        \\         ^ UnexpectedToken
        \\
        ,
        \\a = }
        \\    ^ UnexpectedToken
        ,
        \\a = 1 }
        \\      ^ UnexpectedToken
        ,
        \\a = $x
        \\    ^ UnexpectedToken
        ,
        \\a = "the dog ate my homework
        \\    ^ UnexpectedToken
        ,
        \\a
        \\b = 1
        \\^ UnexpectedToken
        ,
        \\a = 1
        \\b = {
        \\     ^ UnexpectedToken
        ,
    });
}

// The opening quote of the string with the bad escape, in a value, a key and a
// substitution path alike.
// java ✓ · pyhocon ⚠️ — pyhocon keeps `\q` in a value as the two characters.
test "diagnostics.InvalidEscape" {
    try expectCarets(&.{
        \\a = "\q"
        \\    ^ InvalidEscape
        ,
        \\"\q" = 1
        \\^ InvalidEscape
        ,
        \\a = 1
        \\b = ${a."\q"}
        \\        ^ InvalidEscape
        ,
        // A key is split while the file is read, so its bad escape comes before
        // a syntax error further down (README, Diagnostics).
        // java ✓ line 1 · pyhocon ⚠️ reports the `}` on line 2
        \\"\q" = 1
        \\^ InvalidEscape
        \\b = }
        ,
    });
}

// Value building: the first part that cannot join what came before it.
// java ✓ · pyhocon ✓ · spec ✓ — a list does not concatenate with text.
// `c = [1] tea` · java ⚠️ `{"c":[1]}` — drops `tea` without a word (and does the
// same to `a = {b = 1} x`), while `a = [1] 2` is its WrongType. The spec makes
// both an error, and the spec decides.
test "diagnostics.UnsupportedConcatenation" {
    try expectCarets(&.{
        \\port = 80 [1]
        \\          ^ UnsupportedConcatenation
        ,
        \\a = [1] 2
        \\        ^ UnsupportedConcatenation
        ,
        \\a = "x" [1]
        \\        ^ UnsupportedConcatenation
        ,
        \\a { b = 1 }
        \\c = [1] tea
        \\        ^ UnsupportedConcatenation
        ,
        // Only the resolver finds this one: until `${a}` is a list, it is text.
        // The same part is blamed as at load, the one that does not fit.
        // java ⚠️ reports line 1, where the list was written; pyhocon ✓ 2:10.
        \\a = [1]
        \\b = ${a} tea
        \\         ^ UnsupportedConcatenation
        ,
    });
}

// A line that ends with `\r\n` has its error at the same column as with `\n`:
// the `\r` is part of the line ending, not a character to count. No table, as a
// `\r` cannot be written in a multiline string.
// java ✓ line 1 · pyhocon ✓ 1:5 at the `${`, an error either way
test "diagnostics.column at a CRLF line end" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for ([_][:0]const u8{ "a = ${b\nc = 1", "a = ${b\r\nc = 1" }) |src| {
        var diag: hocon.Diagnostics = .{};
        try testing.expectError(error.UnexpectedToken, hocon.parseFromSliceLeaky(hocon.Value, arena.allocator(), src, .{ .diagnostics = &diag }));
        try testing.expectEqual(1, diag.location.?.line);
        try testing.expectEqual(8, diag.location.?.column);
        try testing.expectEqualStrings("a = ${b", diag.location.?.source_line);
    }
}

// No row for UnsupportedNodeKind: `[1, 2]` was the last input reaching it, and #6
// made an array root valid. The parser builds no node `Value` rejects, so the
// error is an internal invariant, covered by the unit test in Value.zig.

// A slice has no file to include from, so an include in it fails at the
// keyword. Errors in included files are in Include.zig.
// java ⚠️ ignores it (no such file is an empty object) · pyhocon ⚠️ the same · spec –
test "diagnostics.IncludeNeedsFile" {
    try expectCarets(&.{
        \\a = 1
        \\  include "x.conf"
        \\  ^ IncludeNeedsFile
        ,
    });
}

// `a += b` is `a = ${?a} [b]`, so a value below it that is not a list fails
// the way the long form does: at the list, the part that does not fit.
// java ✓ (WrongType) · pyhocon ⚠️ gives "1 b" and {"b":2} · spec ✓
test "diagnostics.UnsupportedConcatenation from +=" {
    try expectCarets(&.{
        \\a = 1
        \\a += b
        \\     ^ UnsupportedConcatenation
        ,
        \\a { b = { c = 1 } }
        \\a.b += 2
        \\       ^ UnsupportedConcatenation
        ,
    });
}

// A HOCON file is UTF-8 (spec L117): the first byte that is not, quoted or
// not, wherever it stands. Written with `\x` escapes, which a multiline string
// does not have.
// java ⚠️ reads the byte as U+FFFD · pyhocon ⚠️ UnicodeDecodeError, no place · spec ✓
test "diagnostics.InvalidUtf8" {
    try expectCarets(&.{
        "a = caf\xe9\n       ^ InvalidUtf8",
        "a = \"caf\xe9\"\n        ^ InvalidUtf8",
        "a { b = 1 }\ncaf\xc3 = 1\n   ^ InvalidUtf8",
        // Columns count code points, `é` is one. This took the place of a test
        // for an error after a bad byte on the same line, which cannot happen
        // now: the bad byte is the error.
        "a = xé\xff [1]\n      ^ InvalidUtf8",
        // An overlong `/` and a lone surrogate are not UTF-8 either.
        "a = \xc0\xaf\n    ^ InvalidUtf8",
        "a = \xed\xa0\x80\n    ^ InvalidUtf8",
    });
}

// The number error points at the start of the word, also when it is not the
// first word of the value. A word that is no number is text since 2026-10-25
// (`01`, `-foo`, `-.5`), so a `+` outside a number is the one way to it.
// java ⚠️ lenient on `-.5e+1` (-5) · pyhocon ⚠️ lenient · spec ✓
test "diagnostics.BadNumber" {
    try expectCarets(&.{
        \\a = -.5e+1
        \\    ^ BadNumber
        ,
        \\a = my cat is -.5e+1
        \\              ^ BadNumber
        ,
    });
}

// A `+` outside the exponent of a number, in a value, a key or a path: the word
// it is in. java ✓ (Parse error, same line) · pyhocon ✓ on the first two rows,
// the third is Unresolved there · spec ✓
test "diagnostics.BadNumber a + that is no exponent" {
    try expectCarets(&.{
        \\a = tea 1e+5.x
        \\        ^ BadNumber
        ,
        \\a { 1e+5.5 = 1 }
        \\    ^ BadNumber
        ,
        \\a = ${1e+5.x}
        \\      ^ BadNumber
        ,
    });
}

// Nested past `max_depth` (500), the bracket, block or key where it went too
// deep, or the substitution that brought in what is; chained past it, the
// substitution or the layer the resolver gave up at.
// java ⚠️ resolves them all · pyhocon ⚠️ RecursionError, no line · spec –
test "diagnostics.TooDeep" {
    try expectCarets(&.{
        "a = " ++ "[" ** 600 ++ "]" ** 600 ++ "\n" ++ " " ** 503 ++ "^ TooDeep",
        "a" ++ ".a" ** 600 ++ " = 1\n^ TooDeep",
        "a = [[ {}, " ++ "{ b " ** 498 ++ "{}" ++ "}" ** 498 ++ " ]]\n" ++ " " ** 1999 ++ "^ TooDeep",
        // What a substitution brings in nests where it lands: `y` is 600 deep.
        "z" ++ ".a" ** 299 ++ " = tea\ny" ++ ".a" ** 299 ++ " = ${z}\n" ++ " " ** 602 ++ "^ TooDeep",
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    // `a0 = ${a1}` … `a600 = 1`: the 501st link is one too many.
    var chain: std.ArrayList(u8) = .empty;
    for (0..600) |i| {
        try chain.print(gpa, "a{d} = ${{a{d}}}\n", .{ i, i + 1 });
        if (i == 500) try chain.appendSlice(gpa, "       ^ TooDeep\n");
    }
    try chain.appendSlice(gpa, "a600 = 1");
    const row = try chain.toOwnedSliceSentinel(gpa, 0);
    try testing.expectEqualStrings(row, try dumpCaret(gpa, row));

    // `x0 = [${x1}]` … `x600 = 1`: every link a list deeper, and `${x499}`
    // brings in the 501st.
    var lists: std.ArrayList(u8) = .empty;
    for (0..600) |i| {
        try lists.print(gpa, "x{d} = [${{x{d}}}]\n", .{ i, i + 1 });
        if (i == 498) try lists.appendSlice(gpa, "        ^ TooDeep\n");
    }
    try lists.appendSlice(gpa, "x600 = 1");
    const nested = try lists.toOwnedSliceSentinel(gpa, 0);
    try testing.expectEqualStrings(nested, try dumpCaret(gpa, nested));

    // A key written 600 times over itself: resolved from the top, the 500th
    // layer down is too deep.
    var layers: std.ArrayList(u8) = .empty;
    try layers.appendSlice(gpa, "a = sleepy");
    for (0..600) |i| {
        try layers.appendSlice(gpa, "\na = ${a} wombat");
        if (i == 99) try layers.appendSlice(gpa, "\n    ^ TooDeep");
    }
    const stacked = try layers.toOwnedSliceSentinel(gpa, 0);
    try testing.expectEqualStrings(stacked, try dumpCaret(gpa, stacked));
}

// A comma no element claims (#6) points at that comma.
// java ✓ · pyhocon ⚠️ accepts a doubled comma · spec ✓
test "diagnostics.UnexpectedToken extra comma" {
    try expectCarets(&.{
        \\a = [1,,2]
        \\       ^ UnexpectedToken
        ,
        \\a = [,1]
        \\     ^ UnexpectedToken
        ,
        \\, a = 1
        \\^ UnexpectedToken
        ,
        \\a { b = 1,, }
        \\          ^ UnexpectedToken
        ,
    });
}

// A path with an empty element fails at the dot that has nothing before or
// after it, in a key and in a `${…}` alike: both go through Key.split. Until
// #12 a key said UnexpectedToken and a substitution pointed at its `${`; the
// dot is the more exact place, and one splitter has one answer.
// java ✓ (BadPath, same line) · pyhocon ⚠️ drops the empty element of a key,
// and points at the `${` (col 5) of a substitution · spec ✓
test "diagnostics.MalformedKey" {
    try expectCarets(&.{
        \\a = ${a.}
        \\       ^ MalformedKey
        ,
        \\a = ${a..b}
        \\        ^ MalformedKey
        ,
        \\a = ${."b"}
        \\      ^ MalformedKey
        ,
        \\x = 1
        \\a..b = 2
        \\  ^ MalformedKey
        ,
        \\x = 1
        \\.a = 2
        \\^ MalformedKey
        ,
        \\a.b. = 1
        \\   ^ MalformedKey
        ,
        \\x = 1
        \\"a". = 2
        \\   ^ MalformedKey
        ,
    });
}

// `parsePath`: a path given as text, `hocon get a."b.c"` and the like. It goes
// through the parser and Key.split like a key or a `${…}`, so it fails where
// they fail: the empty element at its dot, and anything that is not text at
// its first character — a comment included, which in a file would simply end
// the line. java ✓ (ConfigUtil.splitPath: BadPath on every row) · pyhocon ⚠️
// (ConfigTree.parse_key accepts them all: drops empty elements, keeps `\q`,
// splits `a = b` into `a ` and ` b`) · spec ✓
test "diagnostics.parsePath" {
    const rows = [_][:0]const u8{
        \\a..b
        \\  ^ MalformedKey
        ,
        \\.a
        \\^ MalformedKey
        ,
        \\a."b".
        \\     ^ MalformedKey
        ,
        \\a = b
        \\  ^ UnexpectedToken
        ,
        \\a.${x}
        \\  ^ UnexpectedToken
        ,
        \\a # the cat walked over the keyboard
        \\  ^ UnexpectedToken
        ,
        // A comment in front is blamed where it starts, not at the newline that
        // ends it (java: "Token not allowed in path expression: '# c' (COMMENT)").
        \\# the parrot knows the password
        \\^ UnexpectedToken
        \\a
        ,
        \\  // the parrot knows the password
        \\  ^ UnexpectedToken
        \\a
        ,
        // A newline after the path is whitespace around it, so what comes after
        // the newline is the extra text (java: BadPath at the newline).
        \\a
        \\b
        \\^ UnexpectedToken
        ,
        \\"a
        \\^ UnexpectedToken
        ,
        // Nothing at all is no path either: java's BadPath, ours the missing text.
        "\n^ UnexpectedToken",
        \\a."b\q"
        \\  ^ InvalidEscape
        ,
        "caf\xe9\n   ^ InvalidUtf8",
    };
    var cases: [rows.len]table.Case = undefined;
    for (&cases, rows) |*c, row| c.* = .ok(row, row);
    try table.expectAll(&cases, .{ .dump = dumpPathCaret });
}

// The README's example, without diagnostics. Every suite path goes through it
// in Key.zig's table; this is the call as a user writes it.
// java ✓ (ConfigUtil.splitPath: [server, tls.cert, path], BadPath for `..`) ·
// pyhocon ⚠️ (ConfigTree.parse_key keeps the quotes, `"tls.cert"`, and makes
// `server..path` two elements) · spec ✓
test "parsePath.a path as text is its keys" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const keys = try hocon.parsePath(arena.allocator(), "server.\"tls.cert\".path", null);
    try testing.expectEqual(3, keys.len);
    try testing.expectEqualStrings("server", keys[0].value);
    try testing.expectEqualStrings("tls.cert", keys[1].value);
    try testing.expectEqualStrings("path", keys[2].value);
    try testing.expectError(error.MalformedKey, hocon.parsePath(arena.allocator(), "server..path", null));
}

/// `dumpCaret` for `parsePath`: the row without its caret line is the path.
fn dumpPathCaret(gpa: std.mem.Allocator, row: [:0]const u8) anyerror![]u8 {
    const src = try withoutCaret(gpa, row);
    var diag: hocon.Diagnostics = .{};
    const err = if (hocon.parsePath(gpa, src, &diag)) |_|
        return error.ParsedWithoutError
    else |e|
        e;
    return drawCaret(gpa, src, err, diag);
}

// Resolver: the `${` that has nothing behind it, and the first one when there
// are several. java ✓ · pyhocon ✓ (same line and column) · spec ✓
test "diagnostics.Unresolved" {
    try expectCarets(&.{
        \\a = ${b}
        \\    ^ Unresolved
        ,
        \\a = 1
        \\b = ${nope}
        \\    ^ Unresolved
        ,
        \\a = ${x}
        \\    ^ Unresolved
        \\b = ${y}
        ,
        \\a = ${b} ${c}
        \\    ^ Unresolved
        ,
    });
}

// The environment (#11) fails at the same places: the `${` that found no
// variable, and the part that does not fit once one has a value. `PORT` and
// `HOSTS_0` are set (`dumpCaretEnv`).
// java ✓ (same line; 1.4.9 ⚠️ drops the `x` of the last row) · pyhocon ⚠️ has
// no `[]` · spec ✓
test "diagnostics.from the environment" {
    const rows = [_][:0]const u8{
        \\port = ${PORT}
        \\host = ${HOST}
        \\       ^ Unresolved
        ,
        \\ports = ${PORT[]}
        \\        ^ Unresolved
        ,
        \\a = ${PORT}
        \\b = ${HOSTS[]}x
        \\              ^ UnsupportedConcatenation
        ,
        \\a = ${HOSTS[]} ${PORT}
        \\               ^ UnsupportedConcatenation
        ,
    };
    var cases: [rows.len]table.Case = undefined;
    for (&cases, rows) |*c, row| c.* = .ok(row, row);
    try table.expectAll(&cases, .{ .dump = dumpCaretEnv });
}

// `.keep` fails on what the document alone decides, whatever the variable
// turns out to be, at the part it fails at when resolved right away: a list
// stays a list across `${?PORT}`, and text stays text. Zig only, no oracle has
// the mode; resolved right away, each row fails the same in java.
test "diagnostics.env = .keep fails where the document decides" {
    const rows = [_][:0]const u8{
        \\a = [1] ${?PORT} x
        \\                 ^ UnsupportedConcatenation
        ,
        \\a = ${?PORT} x [1]
        \\               ^ UnsupportedConcatenation
        ,
        \\a = the wombat ${?MOOD} { sleeps = true }
        \\                        ^ UnsupportedConcatenation
        ,
    };
    var cases: [rows.len]table.Case = undefined;
    for (&cases, rows) |*c, row| c.* = .ok(row, row);
    try table.expectAll(&cases, .{ .dump = dumpCaretKept });
}

// Text that is no duration, period or size (`t`, `p`, `s` here): the caret is
// on where the text starts, inside the quotes or not. Text joined from parts
// starts at the first one, a `${…}` included; the value of a substitution alone
// is where it is written, and a variable's where its `${` is. The caret line
// names the field and what it wanted, as every conversion error does (R2-6).
// java ✓ (BadValue, same line; for the joined row the lines its parts come
// from, `1-2`) · pyhocon – (no getters) · spec ✓
test "diagnostics.text in units that says no unit" {
    const rows = [_][:0]const u8{
        \\t = 10 MS
        \\    ^ UnknownUnit at t: expected duration
        ,
        \\t = 1s
        \\p = 3 h
        \\    ^ UnknownUnit at p: expected period
        ,
        \\t = " 10 MS "
        \\    ^ UnknownUnit at t: expected duration
        ,
        \\p = 1.5 mo
        \\    ^ InvalidCharacter at p: expected period
        ,
        \\s = 1 ZB
        \\    ^ Overflow at s: expected size
        ,
        \\x = 10
        \\t = ${x} MS
        \\    ^ UnknownUnit at t: expected duration
        ,
        \\x = 10 MS
        \\    ^ UnknownUnit at t: expected duration
        \\t = ${x}
        ,
        // What is left once the optional ones are gone starts at a gap: the
        // text starts after it.
        \\t = ${?nope} ${?nope2} 10 MS
        \\                       ^ UnknownUnit at t: expected duration
        ,
        \\x = 10
        \\t = ${?nope} ${x} MS
        \\             ^ UnknownUnit at t: expected duration
        ,
        \\x = 10
        \\t = ${?a}  ${?b}  ${x}MS
        \\                  ^ UnknownUnit at t: expected duration
        ,
        \\t = ${TIMEOUT}
        \\    ^ InvalidCharacter at t: expected duration
        ,
    };
    var cases: [rows.len]table.Case = undefined;
    for (&cases, rows) |*c, row| c.* = .ok(row, row);
    try table.expectAll(&cases, .{ .dump = dumpCaretUnits });
}

// A self-reference with nothing below it is undefined, as if it named a missing
// path (spec), not a cycle: the caret is on its own `${`. Also when a value comes
// for the key later — the self-reference cannot see forward.
// java ✓ (UnresolvedSubstitution, same line) · pyhocon ✓ (same line and column) · spec ✓
test "diagnostics.Unresolved self-reference" {
    try expectCarets(&.{
        \\a = ${a}
        \\    ^ Unresolved
        ,
        \\mood = ${mood} wombat
        \\       ^ Unresolved
        \\mood = { grumpy = true }
        ,
    });
}

// The value a hidden layer would never have shown is evaluated once an object
// merges onto it, and an undefined optional on top leaves it to be evaluated.
// java ✓ (same line) · pyhocon ⚠️ hangs on the first · spec ✓
test "diagnostics.Unresolved below a merge" {
    try expectCarets(&.{
        \\a = { b = ${nope} }
        \\          ^ Unresolved
        \\r = {}
        \\a = ${r}
        ,
        \\a = [${nope}]
        \\     ^ Unresolved
        \\a = ${?nope}
        ,
    });
}

// The `${` that closes the cycle: the one that leads back to a member still
// being resolved. In the second row `a` leads through `${b}` to `b`, and `${a}`
// on line 2 leads back to `a`.
// java ✓ (same line) · pyhocon ✓ (lists every `${` of the cycle) · spec ✓
test "diagnostics.SubstitutionCycle" {
    try expectCarets(&.{
        \\a = ${b}
        \\b = ${a}
        \\    ^ SubstitutionCycle
        ,
        \\a { b = ${a} }
        \\        ^ SubstitutionCycle
        ,
        \\a = ${b}
        \\b = ${c}
        \\c = ${a}
        \\    ^ SubstitutionCycle
        ,
        // Entered from outside, it is still the ref that closes the cycle.
        \\x = ${a}
        \\a = ${b}
        \\b = ${a}
        \\    ^ SubstitutionCycle
        ,
        // A list is not a self-referential field, so looking back from the
        // optional on top only comes round to it again (java ✓, pyhocon ⚠️
        // overflows its stack).
        \\a = [${a}]
        \\     ^ SubstitutionCycle
        \\a = ${?a}
        ,
    });
}

// The column counts code points, not bytes: é is 2 bytes, ☕ 3, 🦆 4, the NBSP
// 2, and each is one column. A line resets the count, wide characters before it
// or not. pyhocon ⚠️ counts bytes (col 25 for the first row).
test "diagnostics.column counts code points" {
    try expectCarets(&.{
        \\a = "café ☕ 🦆" [1]
        \\               ^ UnsupportedConcatenation
        ,
        "a = x\u{a0}y [1]\n        ^ UnsupportedConcatenation",
        \\"🦆" = 1
        \\b = 1 [2]
        \\      ^ UnsupportedConcatenation
        ,
    });
}

// The offset is in bytes, the column in code points — the same spot both ways.
test "diagnostics.offset is bytes, location is code points" {
    const src = "a = \"🦆\" [1]";
    var diag: hocon.Diagnostics = .{};
    defer diag.deinit(testing.allocator);
    try testing.expectError(error.UnsupportedConcatenation, hocon.parseFromSlice(hocon.Value, testing.allocator, src, .{ .diagnostics = &diag }));
    const loc = diag.location.?;
    try testing.expectEqual(11, loc.offset);
    try testing.expectEqual(1, loc.line);
    try testing.expectEqual(9, loc.column);
}

// A parse that succeeds says nothing, even when the Diagnostics it is handed
// still holds an error from an earlier one; a second failure replaces the first.
// The copies of the first are freed in between, by whoever handed it over.
test "diagnostics.each parse starts it afresh" {
    var diag: hocon.Diagnostics = .{};
    defer diag.deinit(testing.allocator);
    try testing.expectError(error.Unresolved, hocon.parseFromSlice(hocon.Value, testing.allocator, "a = ${b}", .{ .diagnostics = &diag }));
    diag.deinit(testing.allocator);
    try testing.expectError(error.UnexpectedToken, hocon.parseFromSlice(hocon.Value, testing.allocator, "a = 1 }", .{ .diagnostics = &diag }));
    try testing.expectEqual(error.UnexpectedToken, diag.err.?);
    try testing.expectEqual(6, diag.location.?.offset);
    diag.deinit(testing.allocator);

    const parsed = try hocon.parseFromSlice(hocon.Value, testing.allocator, "a = the cat sat on the keyboard", .{ .diagnostics = &diag });
    defer parsed.deinit();
    try testing.expectEqual(null, diag.err);
}

// Rendered the way the zig compiler prints its own errors: `path:line:col:`,
// the line, and a caret under the column. A slice has no file name, so the
// path is left out; `parseFromFile` names it (Include.zig).
test "diagnostics.render" {
    const src =
        \\name = grumpy wombat
        \\host = example.org
        \\port = 80 [1]
        \\tls = off
    ;
    var diag: hocon.Diagnostics = .{};
    defer diag.deinit(testing.allocator);
    try testing.expectError(error.UnsupportedConcatenation, hocon.parseFromSlice(hocon.Value, testing.allocator, src, .{ .diagnostics = &diag }));

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try diag.render(&out.writer);
    try testing.expectEqualStrings(
        \\3:11: error: UnsupportedConcatenation
        \\port = 80 [1]
        \\          ^
        \\
    , out.written());
}

// Where a member begins, the token that cannot begin one: after a braced root,
// a second root container, a container with no key in a block, a `${` as a key.
// java ✓ (same line on every row) · pyhocon ✓ (same line and column) · spec ✓
test "diagnostics.UnexpectedToken where a member begins" {
    try expectCarets(&.{
        \\{a = 1} b = 2
        \\        ^ UnexpectedToken
        ,
        \\a { {b = 1} }
        \\    ^ UnexpectedToken
        ,
        \\a { [1] }
        \\    ^ UnexpectedToken
        ,
        \\a = 1
        \\{b = 2}
        \\^ UnexpectedToken
        ,
        \\a = 1
        \\[1]
        \\^ UnexpectedToken
        ,
        \\a = 1
        \\${b} = 2
        \\^ UnexpectedToken
        ,
    });
}

// A comma after a braced root: the root is no field and no element, so the
// one trailing comma does not apply to it (commas/015–016).
// java ✓ (Document has trailing tokens, same line) · pyhocon ✗ accepts
// both · spec ✓
test "diagnostics.UnexpectedToken at a comma after the root" {
    try expectCarets(&.{
        \\{a = 1},
        \\       ^ UnexpectedToken
        ,
        \\[1, 2],
        \\      ^ UnexpectedToken
        ,
        \\{a = 1}
        \\,
        \\^ UnexpectedToken
        ,
    });
}

// Inside a value: a substitution path that is not text — at the part that is
// not —, a `${` that is never closed, junk around `include`.
// java ✓ (line 1 on every row, and it names the `[` too) · pyhocon ⚠️ errors,
// but its positions are no help here · spec ✓
test "diagnostics.UnexpectedToken inside a value" {
    try expectCarets(&.{
        \\a = ${[1]}
        \\      ^ UnexpectedToken
        ,
        \\a = ${b [1]}
        \\        ^ UnexpectedToken
        ,
        // `[]` is one mark (#11): at its `[` when it is anything else. After
        // it only the `}` may come. java ✓ BadPath on both, naming the `[`.
        \\a = ${PORTS[ ]}
        \\           ^ UnexpectedToken
        ,
        \\a = ${PORTS[]x}
        \\             ^ UnexpectedToken
        ,
        // The newline ends the path, so the newline is the token that is not `}`.
        \\a = ${b
        \\       ^ UnexpectedToken
        \\c = 1
        ,
        \\include "x" y
        \\            ^ UnexpectedToken
        ,
        \\include x
        \\        ^ UnexpectedToken
        ,
    });
}

// The quoted part with the bad escape, when something comes before it in the
// same key or value. java ✓ (line 1) · pyhocon ⚠️ keeps `\q` as two characters
test "diagnostics.InvalidEscape after another part" {
    try expectCarets(&.{
        \\a."\q" = 1
        \\  ^ InvalidEscape
        ,
        \\a = x "\q"
        \\      ^ InvalidEscape
        ,
    });
}

// java ✓ (WrongType, line 1) · pyhocon ✓ line, ⚠️ column (end of the token) · spec ✓
test "diagnostics.UnsupportedConcatenation text then an object" {
    try expectCarets(&.{
        \\a = 1 {b = 1}
        \\      ^ UnsupportedConcatenation
        ,
    });
}

// A list next to an object with no numeric key, or a list that the object after
// it no longer fits once an earlier one made it longer: the object is the part.
// java ✓ (WrongType, line 1) · pyhocon ✓ line (WrongType on every list and
// object) · spec ✓
test "diagnostics.UnsupportedConcatenation a list and an object" {
    try expectCarets(&.{
        \\a = [1] { b = 1 }
        \\        ^ UnsupportedConcatenation
        ,
        \\a = { b = 1 } [1]
        \\              ^ UnsupportedConcatenation
        ,
        \\a = [0] { "0" : 1, x : 2 } { y : 3 }
        \\                           ^ UnsupportedConcatenation
        ,
    });
}

// A misfit only the resolver sees is the same part that load would blame: the
// first one that does not fit onto what came before it. A `${?x}` with nothing
// behind it is gone by then, so it is never the one.
// java ✓ (same line, or the line the list was written on) · pyhocon ✓ (same
// part, its column one past the end) · spec ✓
test "diagnostics.UnsupportedConcatenation found by the resolver" {
    try expectCarets(&.{
        \\a = [1]
        \\b = x
        \\c = ${b} ${a}
        \\         ^ UnsupportedConcatenation
        ,
        \\a = [1]
        \\b = [2]
        \\c = ${a} ${b} tea
        \\              ^ UnsupportedConcatenation
        ,
        \\a = [1] ${?x} tea
        \\              ^ UnsupportedConcatenation
        ,
        \\a = x ${?nope} [2]
        \\               ^ UnsupportedConcatenation
        ,
    });
}

// The rendered line is the source line as written — indentation kept, a CRLF
// ending gone, the caret indented by code points — except that a tab, a stray
// `\r` or another control character prints as one space, or the caret would not
// line up under it.
test "diagnostics.render keeps the line as written" {
    const cases = [_]struct { src: [:0]const u8, err: anyerror = error.UnsupportedConcatenation, want: []const u8 }{
        .{ .src = "name = grumpy wombat\r\n  port = 80 [1]\r\n", .want = "2:13: error: UnsupportedConcatenation\n  port = 80 [1]\n            ^\n" },
        .{ .src = "a = \"🦆\" [1]", .want = "1:9: error: UnsupportedConcatenation\na = \"🦆\" [1]\n        ^\n" },
        .{ .src = "a = 1\n\tb = 2 [3]", .want = "2:8: error: UnsupportedConcatenation\n b = 2 [3]\n       ^\n" },
        // Only `\n` starts a line, so a lone `\r` keeps the line together — and
        // since it is whitespace (#6), `1\rb` is one value and the `=` is what fails.
        .{ .src = "a = 1\rb = }", .err = error.UnexpectedToken, .want = "1:9: error: UnexpectedToken\na = 1 b = }\n        ^\n" },
        // Nor does any other control character reach the terminal: ESC c resets it.
        .{ .src = "a = x\x1bcy, b = ${nope}", .err = error.Unresolved, .want = "1:15: error: Unresolved\na = x cy, b = ${nope}\n              ^\n" },
    };
    for (cases) |c| {
        var diag: hocon.Diagnostics = .{};
        defer diag.deinit(testing.allocator);
        try testing.expectError(c.err, hocon.parseFromSlice(hocon.Value, testing.allocator, c.src, .{ .diagnostics = &diag }));
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try diag.render(&out.writer);
        try testing.expectEqualStrings(c.want, out.written());
    }
}

// A conversion error says which value did not fit and what the type wanted
// there, and points at the value where the file still says where it was
// written: a scalar read as it stands, the first element of a list, the first
// key of an object, in the file it came from. An index goes after its list.
// java ✓ names the same path and line (`db.pool has type STRING rather than
// NUMBER`) · pyhocon ✓ the path · spec — says nothing about errors. The
// column is ours, as for the parse errors above.
fn expectTypeCarets(comptime T: type, comptime env: hocon.Value.Env, rows: []const [:0]const u8) !void {
    const cases = try testing.allocator.alloc(table.Case, rows.len);
    defer testing.allocator.free(cases);
    for (cases, rows) |*c, row| c.* = .ok(row, row);
    try table.expectAll(cases, .{ .dump = struct {
        fn dump(gpa: std.mem.Allocator, row: [:0]const u8) anyerror![]u8 {
            const src = try withoutCaret(gpa, row);
            var diag: hocon.Diagnostics = .{};
            const err = if (hocon.parseFromSliceLeaky(T, gpa, src, .{ .diagnostics = &diag, .env = env })) |_|
                return error.ParsedWithoutError
            else |e|
                e;
            return drawCaret(gpa, src, err, diag);
        }
    }.dump });
}

test "diagnostics.conversion" {
    const Level = enum { debug, info };
    const T = struct {
        name: []const u8 = "grumpy wombat",
        db: struct { pool: u8 = 4, hosts: []const []const u8 = &.{} } = .{},
        ports: []const u16 = &.{},
        level: Level = .info,
        tls: ?struct { on: bool } = null,
        mode: union(enum) { quiet: void, loud: u8 } = .quiet,
        size: enum(u8) { small, big, _ } = .small,
    };
    try expectTypeCarets(T, .none, &.{
        \\db { pool = eight }
        \\            ^ InvalidCharacter at db.pool: expected u8
        ,
        \\db.pool = 300
        \\          ^ Overflow at db.pool: expected u8
        ,
        // The second element is the one, and a quoted string is where its
        // quote is.
        \\ports = [80, "the owl"]
        \\             ^ InvalidCharacter at ports[1]: expected u16
        ,
        \\name = "x"
        \\level = "loud"
        \\        ^ TypeMismatch at level: expected one of debug, info
        ,
        // A list where a string goes: its first element.
        \\name = [the cat, sat]
        \\        ^ TypeMismatch at name: expected string
        ,
        // An object where a number goes: its first key.
        \\db { pool { size = 8 } }
        \\            ^ TypeMismatch at db.pool: expected u8
        ,
        \\db.hosts = [alpha, [beta]]
        \\                    ^ TypeMismatch at db.hosts[1]: expected string
        ,
        // Through a substitution, the value is where it was written.
        \\eight = eight
        \\        ^ InvalidCharacter at db.pool: expected u8
        \\db.pool = ${eight}
        ,
        \\tls { on = maybe }
        \\           ^ TypeMismatch at tls.on: expected bool
        ,
        // A tagged union is an object with one of its names as the one key,
        // and a `void` payload is `{}`; a non-exhaustive enum takes a number
        // too. Both are Zig's own: java and pyhocon have neither.
        \\mode = quiet
        \\       ^ TypeMismatch at mode: expected object with one of quiet, loud
        ,
        \\mode { quiet = 1 }
        \\               ^ TypeMismatch at mode.quiet: expected empty object
        ,
        \\mode { loud = very }
        \\              ^ InvalidCharacter at mode.loud: expected u8
        ,
        \\size = huge
        \\       ^ InvalidCharacter at size: expected one of small, big or a number
    });
}

// What `.keep` left waiting for the environment cannot go into a string, and
// it is where its `${` is: alone, in a concatenation (where that starts), as
// the last of a key set twice, or deep in a `Value` field. java — the oracle
// reads no typed value (its `ConfigException.NotResolved` names the path) ·
// pyhocon — resolves while it parses · spec — says nothing about errors.
test "diagnostics.conversion of a value that waits for the environment" {
    const T = struct { a: []const u8 = "", b: []const u8 = "", c: []const []const u8 = &.{}, d: ?hocon.Value = null };
    try expectTypeCarets(T, .keep, &.{
        \\a = fine
        \\b = ${NOT_YET}
        \\    ^ Unresolved at b
        ,
        \\b = the ${NOT_YET} owl
        \\    ^ Unresolved at b
        ,
        \\b = fine
        \\b = ${?NOT_YET}
        \\    ^ Unresolved at b
        ,
        \\c = [fine, ${NOT_YET}]
        \\           ^ Unresolved at c[1]
        ,
        \\d { fine = 1, later = ${NOT_YET} }
        \\                      ^ Unresolved at d
        ,
        \\d = [fine, [also fine, ${NOT_YET}]]
        \\                       ^ Unresolved at d
    });
}

// An object with numeric keys read as a list (R2-1): the path has the index
// in the list the keys make, `ports[1]` for the second key in order, here `5`;
// the caret is on the value itself, so it is plain which one. An object with
// no numeric key is no list, and is where its first key is. A `Duration` in
// a list is a field like any other.
// java ✓ the list is numbered the same way (its error names only `ports`) ·
// pyhocon – no typed getters · spec ✓ numerically-indexed objects
test "diagnostics.conversion of an object with numeric keys" {
    const T = struct { ports: []const u16 = &.{}, pair: [2]u8 = .{ 0, 0 }, ttls: []const hocon.Duration = &.{} };
    try expectTypeCarets(T, .none, &.{
        \\ports { 0 = 80, 5 = "the owl" }
        \\                    ^ InvalidCharacter at ports[1]: expected u16
        ,
        \\pair { 1 = 2, 0 = x }
        \\                  ^ InvalidCharacter at pair[0]: expected u8
        ,
        \\ports { a = 1 }
        \\        ^ TypeMismatch at ports: expected list
        ,
        \\ttls { 0 = 1s, 1 = 3 fortnights }
        \\                   ^ UnknownUnit at ttls[1]: expected duration
    });
}

// Without a place to point at, the first line alone, path and all: a missing
// field has no value, and an empty list has nothing in it to point at. The
// root has no path.
test "diagnostics.conversion without a position" {
    const T = struct { a: u8, b: struct { c: []const u8 } = .{ .c = "" }, d: [2]u16 = .{ 0, 0 } };
    const cases = [_]struct { src: [:0]const u8, err: anyerror, want: []const u8 }{
        .{ .src = "b = the cat sat on the keyboard", .err = error.MissingField, .want = "error: MissingField at a\n" },
        .{ .src = "a = 1\nb { }", .err = error.MissingField, .want = "error: MissingField at b.c\n" },
        .{ .src = "a = 1\nd = []", .err = error.TypeMismatch, .want = "error: TypeMismatch at d: expected list of 2\n" },
        .{ .src = "[]", .err = error.TypeMismatch, .want = "error: TypeMismatch: expected object\n" },
        .{ .src = "a = 1\n\"weird.key\" = 2\nb { c = [] }", .err = error.TypeMismatch, .want = "error: TypeMismatch at b.c: expected string\n" },
    };
    for (cases) |c| {
        var diag: hocon.Diagnostics = .{};
        defer diag.deinit(testing.allocator);
        try testing.expectError(c.err, hocon.parseFromSlice(T, testing.allocator, c.src, .{ .diagnostics = &diag }));
        try testing.expectEqual(null, diag.location);
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try diag.render(&out.writer);
        try testing.expectEqualStrings(c.want, out.written());
    }
}

// `ignore_unknown_fields = false`: a key the struct has no field for is an
// error, with its path, at its value (a key has no place of its own). The
// default skips it, as before and as `std.json`'s option of the same name.
// java – reads by path, never into a struct · pyhocon – the same · spec – an
// API choice, not the format's
test "diagnostics.conversion of an unknown field" {
    const T = struct { port: u16 = 80, db: struct { host: []const u8 = "" } = .{} };
    const skipped = try hocon.parseFromSlice(T, testing.allocator, "port = 8080\nprot = 8081", .{});
    defer skipped.deinit();
    try testing.expectEqual(8080, skipped.value.port);

    const cases = [_]struct { src: [:0]const u8, want: []const u8 }{
        .{ .src = "port = 8080\nprot = 8081", .want = "2:8: error: UnknownField at prot\nprot = 8081\n       ^\n" },
        .{ .src = "db { host = a, hots = b }", .want = "1:23: error: UnknownField at db.hots\ndb { host = a, hots = b }\n                      ^\n" },
    };
    for (cases) |c| {
        var diag: hocon.Diagnostics = .{};
        defer diag.deinit(testing.allocator);
        try testing.expectError(error.UnknownField, hocon.parseFromSlice(T, testing.allocator, c.src, .{ .diagnostics = &diag, .ignore_unknown_fields = false }));
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try diag.render(&out.writer);
        try testing.expectEqualStrings(c.want, out.written());
    }
}

// A key that a path has to quote is quoted in it, so the path can be pasted
// into `parsePath` (or `hocon get`) as it is.
test "diagnostics.conversion quotes a key that needs it" {
    const T = struct { @"db.main": struct { pool: u8 } };
    var diag: hocon.Diagnostics = .{};
    defer diag.deinit(testing.allocator);
    try testing.expectError(error.InvalidCharacter, hocon.parseFromSlice(T, testing.allocator, "\"db.main\".pool = x", .{ .diagnostics = &diag }));
    try testing.expectEqualStrings("\"db.main\".pool", diag.key_path);
}

// The place and the path are copies, so they outlive the arena of a failed
// parse, and `deinit` gives them back: this is `testing.allocator`.
test "diagnostics.conversion in an included file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "pool.conf", .data = "pool = eight\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "app.conf", .data = "name = grumpy wombat\ndb { include \"pool.conf\" }\n" });
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/app.conf", .{tmp.sub_path});
    defer testing.allocator.free(path);

    var diag: hocon.Diagnostics = .{};
    defer diag.deinit(testing.allocator);
    const T = struct { name: []const u8, db: struct { pool: u8 } };
    try testing.expectError(error.InvalidCharacter, hocon.parseFromFile(T, testing.allocator, testing.io, path, .{ .diagnostics = &diag }));
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try diag.render(&out.writer);
    const want = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/pool.conf:1:8: error: InvalidCharacter at db.pool: expected u8\npool = eight\n       ^\n", .{tmp.sub_path});
    defer testing.allocator.free(want);
    try testing.expectEqualStrings(want, out.written());
}

// Out of memory has no position either. Every allocation the parse makes is
// made to fail once, in turn: each of those runs keeps OutOfMemory with no
// place, until the parse gets far enough to fail on its own. Copying the place
// into the Diagnostics can run out too; then the error stays and the place goes.
// The very first allocation is the arena, before there is any text: the error
// is still the one in the Diagnostics, not one an earlier parse left there.
test "diagnostics.out of memory has no position" {
    var i: usize = 0;
    while (true) : (i += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = i });
        var diag: hocon.Diagnostics = .{ .err = error.InvalidEscape };
        defer diag.deinit(testing.allocator);
        if (hocon.parseFromSlice(hocon.Value, failing.allocator(), "a = 1\nb = ${nope}", .{ .diagnostics = &diag })) |parsed| {
            parsed.deinit();
            return error.ParsedWithoutError;
        } else |err| switch (err) {
            error.OutOfMemory => {
                try testing.expectEqual(error.OutOfMemory, diag.err.?);
                try testing.expectEqual(null, diag.location);
            },
            else => {
                try testing.expectEqual(error.Unresolved, err);
                try testing.expectEqual(error.Unresolved, diag.err.?);
                const loc = diag.location orelse continue;
                try testing.expectEqual(10, loc.offset);
                return;
            },
        }
    }
}

// The same for `parsePath`: its first allocation is the copy of the text, and a
// quoted part that runs out while it is unquoted has no place either. Only one
// allocation fails, so the copy of a place would get its memory if there were
// a place to copy.
test "diagnostics.out of memory in parsePath has no position" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var i: usize = 0;
    while (true) : (i += 1) {
        var failing: FailOnce = .{ .child = arena.allocator(), .fail_index = i };
        var diag: hocon.Diagnostics = .{ .err = error.InvalidEscape };
        if (hocon.parsePath(failing.allocator(), "a.\"b\\n\" \"c\\t\"", &diag)) |_| {
            try testing.expectEqual(null, diag.err);
            return;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(error.OutOfMemory, diag.err.?);
            try testing.expectEqual(null, diag.location);
        }
    }
}

/// Fails allocation number `fail_index` and that one only.
/// `std.testing.FailingAllocator` keeps failing from there on, so whatever
/// runs after the failure would run out too.
const FailOnce = struct {
    child: std.mem.Allocator,
    fail_index: usize,
    index: usize = 0,

    fn allocator(self: *FailOnce) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = std.mem.Allocator.noResize,
            .remap = std.mem.Allocator.noRemap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *FailOnce = @ptrCast(@alignCast(ctx));
        defer self.index += 1;
        if (self.index == self.fail_index) return null;
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *FailOnce = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

// The same for a file, where the arena and the text come before there is a
// place to point at.
test "diagnostics.out of memory reading a file has no position" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "app.conf", .data = "a = 1\nb = ${nope}" });
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/app.conf", .{tmp.sub_path});
    defer testing.allocator.free(path);

    var i: usize = 0;
    while (true) : (i += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = i });
        var diag: hocon.Diagnostics = .{ .err = error.InvalidEscape };
        defer diag.deinit(testing.allocator);
        if (hocon.parseFromFile(hocon.Value, failing.allocator(), testing.io, path, .{ .diagnostics = &diag })) |parsed| {
            parsed.deinit();
            return error.ParsedWithoutError;
        } else |err| switch (err) {
            error.OutOfMemory => {
                try testing.expectEqual(error.OutOfMemory, diag.err.?);
                try testing.expectEqual(null, diag.location);
            },
            else => {
                try testing.expectEqual(error.Unresolved, diag.err.?);
                if (diag.location == null) continue;
                return;
            },
        }
    }
}

// A slice is held to the size a file may have, the size every offset in a
// document fits: one byte short of it parses, the size itself is refused before
// any parsing.
test "diagnostics.a slice as big as the file limit is refused" {
    // 64 MiB, `max_file_size` in Include.zig.
    const big = try testing.allocator.allocSentinel(u8, 64 * 1024 * 1024, 0);
    defer testing.allocator.free(big);
    @memset(big, ' ');

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: hocon.Diagnostics = .{};
    try testing.expectError(error.StreamTooLong, hocon.parseFromSliceLeaky(hocon.Value, arena.allocator(), big, .{ .diagnostics = &diag }));
    try testing.expectEqual(error.StreamTooLong, diag.err.?);
    try testing.expectEqual(null, diag.location);

    big[big.len - 1] = 0;
    _ = try hocon.parseFromSliceLeaky(hocon.Value, arena.allocator(), big[0 .. big.len - 1 :0], .{});
}

// Nothing failed, nothing to print — a render after a good parse writes nothing
// rather than tripping over the missing error.
test "diagnostics.render with no error writes nothing" {
    const diag: hocon.Diagnostics = .{};
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try diag.render(&out.writer);
    try testing.expectEqualStrings("", out.written());
}

// An offset past the end — never one a parse makes — points just past the last
// character instead of out of bounds.
test "diagnostics.locate clamps an offset past the end" {
    const loc = hocon.Diagnostics.locate("app.conf", "a = 1\nb", 99);
    try testing.expectEqual(2, loc.line);
    try testing.expectEqual(2, loc.column);
    try testing.expectEqualStrings("b", loc.source_line);
}
