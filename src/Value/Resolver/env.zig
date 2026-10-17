//! Where a path that is not in the document looks next (#11).

const std = @import("std");
const Key = @import("../../Key.zig");
const Value = @import("../../Value.zig").Value;
const Ref = @import("../../Value.zig").Ref;
const Pos = Value.Pos;
const Resolver = @import("../Resolver.zig");
const Error = Resolver.Error;

// For the tests.
const testing = std.testing;
const Ast = @import("../../Ast.zig");
const Node = Ast.Node;
const Tokenizer = @import("../../Tokenizer.zig");
const table = @import("../../table.zig");
const build = @import("../build.zig").build;
const expectAllResolved = Resolver.expectAllResolved;

/// Where a substitution looks when its path is not in the document at all,
/// not even as `null`.
pub const Env = union(enum) {
    /// Nowhere: the path is undefined.
    none,
    /// In these variables, e.g. `std.process.Init.environ_map`.
    map: *const std.process.Environ.Map,
    /// Later: the substitution stays in the tree for whoever resolves it
    /// with the environment it runs in, e.g. a config written out on one
    /// machine by `hocon.stringify` and read on another. Everything the
    /// document can answer is resolved; what waits stays `.ref`, `.pending`
    /// or `.stack` (see `waits`), which JSON cannot write.
    keep,
};

// The value of the variable named like the path as written, without the
// include's scope: `${a.b}` reads `a.b`. Always a string, `""` included;
// `${X[]}` collects `X_0`, `X_1`, … up to the first one missing.
// Null when there is no such variable, or not even `X_0`.
pub noinline fn fromEnv(gpa: std.mem.Allocator, map: *const std.process.Environ.Map, r: Ref) Error!?Value {
    var name: std.ArrayList(u8) = .empty;
    for (r.path[r.scope_len..], 0..) |key, i| {
        if (i > 0) try name.append(gpa, '.');
        try name.appendSlice(gpa, key.value);
    }
    if (!r.flags.list) {
        const text = map.get(name.items) orelse return null;
        // A copy: the map is the caller's, and may go before the document
        // does. Text that is not UTF-8 gets U+FFFD for each bad byte.
        return .{ .scalar = .{ .value = try std.fmt.allocPrint(gpa, "{f}", .{std.unicode.fmtUtf8(text)}), .quoted = true, .file = r.file, .pos = r.pos } };
    }

    var items: std.ArrayList(Value) = .empty;
    while (true) {
        const element = try std.fmt.allocPrint(gpa, "{s}_{d}", .{ name.items, items.items.len });
        const text = map.get(element) orelse break;
        try items.append(gpa, .{ .scalar = .{ .value = try std.fmt.allocPrint(gpa, "{f}", .{std.unicode.fmtUtf8(text)}), .quoted = true, .file = r.file, .pos = r.pos } });
    }
    if (items.items.len == 0) return null;
    return .{ .array = try items.toOwnedSlice(gpa) };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

pub const test_env = [_][2][]const u8{
    .{ "PORT", "8080" },
    .{ "EMPTY", "" },
    .{ "NUM", "42" },
    .{ "YES", "true" },
    .{ "NOTHING", "null" },
    .{ "x.y", "the dotted one" },
    .{ "gone", "the environment" },
    .{ "HOSTS_0", "alpha" },
    .{ "HOSTS_1", "beta" },
    .{ "GAP_0", "first" },
    .{ "GAP_2", "after the gap" },
    .{ "BYTES", "\xff\xfe" },
    .{ "BYTES_0", "caf\xe9" },
};
fn expectAllFromEnv(cases: []const table.Case) !void {
    return table.expectAll(cases, .{ .dump = struct {
        fn dump(gpa: std.mem.Allocator, src: [:0]const u8) anyerror![]u8 {
            var map: std.process.Environ.Map = .init(gpa);
            for (test_env) |kv| try map.put(kv[0], kv[1]);

            var parser = Ast.Parser{ .gpa = gpa, .t = .{ .t = Tokenizer.Tokenizer.init(src) } };
            var root = try build(gpa, try parser.parse());
            var err_pos: ?Value.Pos = null;
            root.resolve(gpa, .{ .map = &map }, &err_pos) catch |err| return gpa.dupe(u8, @errorName(err));
            return std.json.Stringify.valueAlloc(gpa, root, .{});
        }
    }.dump });
}
// substitution-fallback-to-environment · java ✓ · pyhocon ✓ · spec ✓ — a path
// that is not in the document is a variable of the same name, always a string:
// set to "" it is "", and 42, true and null stay text. A key in the document
// wins, null included, and only the same case counts as the same key.
test "env.a path not in the document reads the variable" {
    try expectAllFromEnv(&.{
        .ok("port = ${PORT}", "{\"port\":\"8080\"}"),
        .ok("port = ${?PORT}", "{\"port\":\"8080\"}"),
        .ok("url = \"http://localhost:\"${PORT}\"/wombat\"", "{\"url\":\"http://localhost:8080/wombat\"}"),
        .ok("a = ${EMPTY}\nb = ${?EMPTY}", "{\"a\":\"\",\"b\":\"\"}"),
        .ok("n = ${NUM}\nb = ${YES}\nz = ${NOTHING}", "{\"n\":\"42\",\"b\":\"true\",\"z\":\"null\"}"),
        .ok("PORT = 443\nport = ${PORT}", "{\"PORT\":443,\"port\":443}"),
        .ok("port = 443\na = ${PORT}", "{\"port\":443,\"a\":\"8080\"}"),
        .ok("a = ${?NOPE}", "{}"),
        .ok("a = ${NOPE}", "Unresolved"),
    });
}
// substitution-fallback-to-environment.4 · java ✓ · pyhocon ⚠️ · spec ✓ —
// `PORT = null` blocks the variable. pyhocon drops `port` altogether.
test "env.null in the document blocks the variable" {
    try expectAllFromEnv(&.{
        .ok("PORT = null\nport = ${PORT}", "{\"PORT\":null,\"port\":null}"),
    });
}
// java ✓ · pyhocon ⚠️ · spec ✓ — the variable is named like the path, dots
// and all. `x = 1` has no `x.y` in it, so `${x.y}` is not in the document
// either; pyhocon says "x has type int rather than dict" instead.
//
// `${"x.y"}` · java ⚠️ · pyhocon ⚠️ — both leave it unresolved: java reads the
// variables as paths, so `x.y` is `y` inside `x`. The spec says "a variable of
// the same name", and `x.y` is the name of both paths.
test "env.the variable is named like the path" {
    try expectAllFromEnv(&.{
        .ok("b = ${x.y}", "{\"b\":\"the dotted one\"}"),
        .ok("x = 1\nb = ${x.y}", "{\"x\":1,\"b\":\"the dotted one\"}"),
        .ok("b = ${\"x.y\"}", "{\"b\":\"the dotted one\"}"),
    });
}
// java ✓ · pyhocon ⚠️ · spec ✓ — a field that refers to itself, `+=`
// included, sees what was below it, never a variable named like it: the
// field is in the document. pyhocon reads `gone` from the environment in
// both rows.
test "env.a self-reference never reads the variable" {
    try expectAllFromEnv(&.{
        .ok("gone = ${?gone}", "{}"),
        .ok("gone += 1", "{\"gone\":[1]}"),
    });
}
// java ⚠️ · pyhocon ✓ (one row ⚠️) · spec ✓ — an optional that found nothing
// leaves no field ("the field should not be created"), so the path is not
// present and reads the variable, whatever the order of the fields. An
// earlier rule said a vanished field was the document's and read nothing;
// that came out differently by order, since an object resolved first has
// dropped the field already. Java resolves keys in sorted order and reads
// the variable only where the object comes first: never at the top level,
// for `x { y = … }` not before `b`, but for `x = ${?NOPE}` always. pyhocon
// fails `b = ${x.y}` before `x = ${?NOPE}` with a type error.
test "env.a field that vanished reads the variable, in either order" {
    try expectAllFromEnv(&.{
        .ok("gone = ${?NOPE}\nb = ${?gone}", "{\"b\":\"the environment\"}"),
        .ok("gone = ${?NOPE}\nb = ${gone}", "{\"b\":\"the environment\"}"),
        .ok("b = ${gone}\ngone = ${?NOPE}", "{\"b\":\"the environment\"}"),
        .ok("x { y = ${?NOPE} }\nb = ${x.y}", "{\"x\":{},\"b\":\"the dotted one\"}"),
        .ok("b = ${x.y}\nx { y = ${?NOPE} }", "{\"b\":\"the dotted one\",\"x\":{}}"),
        .ok("x = ${?NOPE}\nb = ${x.y}", "{\"b\":\"the dotted one\"}"),
        .ok("b = ${x.y}\nx = ${?NOPE}", "{\"b\":\"the dotted one\"}"),
    });
}
// java ✓ (one row ⚠️) · pyhocon ⚠️ · spec ✓ — fields that vanish because
// their optionals refer to each other are in the document, so neither reads
// its variable, whichever is set: a cycle counts as missing for `${?}`, never
// as absent. In the last row the cycle runs through the layer below `gone`;
// Java reads the variable `gone` there, the way it does for a self-reference
// that finds nothing. pyhocon fails every row with a cycle error.
test "env.an optional cycle never reads the variable" {
    try expectAllFromEnv(&.{
        .ok("gone = ${?PORT}\nPORT = ${?gone}", "{}"),
        .ok("PORT = ${?gone}\ngone = ${?PORT}", "{}"),
        .ok("gone = ${?NUM}\nNUM = ${?gone}\nb = ${gone}", "Unresolved"),
        .ok("gone = ${?PORT}\ngone = ${?gone}\nPORT = ${?gone}", "{}"),
    });
}
// java ✓ · pyhocon ⚠️ · spec ✓ — a variable is a string, and text that is not
// UTF-8 becomes one with each bad byte as U+FFFD, the way Java decodes it
// ("encoding is handled by Java"). Raw bytes would print as JSON numbers and
// as HOCON that does not read back. pyhocon keeps them as lone surrogates.
test "env.a variable that is not UTF-8 is a string all the same" {
    try expectAllFromEnv(&.{
        .ok("b = ${BYTES}", "{\"b\":\"\u{FFFD}\u{FFFD}\"}"),
        .ok("l = ${BYTES[]}", "{\"l\":[\"caf\u{FFFD}\"]}"),
    });
}
// list-values-from-environment-variables · java ✓ · pyhocon ⚠️ · spec ✓ —
// `${X[]}` is `X_0`, `X_1`, … up to the first one missing, each a string. No
// `X_0` is undefined: an error, or nothing for `${?X[]}`. A key in the
// document wins as for any path, and its `_0` keys are not collected. pyhocon
// has no `[]` and leaves every row undefined.
//
// `${HOSTS[]}x` · java 1.4.9 ⚠️ drops the `x` (main says WrongType) — a list
// and text do not join.
test "env.a list from numbered variables" {
    try expectAllFromEnv(&.{
        .ok("hosts = ${HOSTS[]}", "{\"hosts\":[\"alpha\",\"beta\"]}"),
        .ok("hosts = ${?HOSTS[]}", "{\"hosts\":[\"alpha\",\"beta\"]}"),
        .ok("a = ${GAP[]}", "{\"a\":[\"first\"]}"),
        .ok("a = ${?NOPE[]}", "{}"),
        .ok("a = ${NOPE[]}", "Unresolved"),
        .ok("a = ${PORT[]}", "Unresolved"),
        .ok("HOSTS = [q]\na = ${HOSTS[]}", "{\"HOSTS\":[\"q\"],\"a\":[\"q\"]}"),
        .ok("NOPE_0 = q\nb = ${?NOPE[]}", "{\"NOPE_0\":\"q\"}"),
        .ok("a = ${HOSTS[]} [gamma]", "{\"a\":[\"alpha\",\"beta\",\"gamma\"]}"),
        .ok("a = [${HOSTS[]}]", "{\"a\":[[\"alpha\",\"beta\"]]}"),
        .ok("a = ${HOSTS[]}x", "UnsupportedConcatenation"),
    });
}
// No environment given, no environment read: the default is the document alone.
test "env.none by default" {
    try expectAllResolved(&.{
        .bad("port = ${PORT}"),
        .ok("port = ${?PORT}", "{}"),
        .ok("hosts = ${?HOSTS[]}", "{}"),
    });
}
