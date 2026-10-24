//! `Env.keep`: everything the document can answer is resolved, what waits for
//! the environment stays, as a `.ref`, a `.pending` or a `.stack`. These
//! helpers say what waits; the branches that keep it are where each value
//! is resolved, in `Resolver.zig` and `stack.zig`.

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
const test_env = @import("env.zig").test_env;

// `.keep` only: still to be resolved, as a whole. A list or an object with
// such a thing inside is not: it is already a list or an object.
pub fn waits(value: Value) bool {
    return value == .ref or value == .pending or value == .stack;
}

// `.keep` only: a list and an object with a field that waits. Joined, the
// field would be an element, and an element cannot wait the way a field does.
pub fn waitsInList(a: Value, b: Value) bool {
    const object = if (a == .array and b == .object) b else if (a == .object and b == .array) a else return false;
    for (object.object) |m| {
        if (waits(m.value)) return true;
    }
    return false;
}

// `.keep` only: whether a value that waits may resolve to nothing at all,
// so that a ref to it finds nothing. Only an optional can vanish; a
// concatenation or a stack only when every part or layer can.
pub fn mayVanish(value: Value) bool {
    return switch (value) {
        .ref => |r| r.flags.optional,
        .pending => |parts| for (parts) |part| {
            if (!part.value.isGap() and !mayVanish(part.value)) break false;
        } else true,
        .stack => |layers| for (layers) |layer| {
            if (!mayVanish(layer)) break false;
        } else true,
        else => false,
    };
}

// `.keep` only: `top` over the layers it falls back to or merges onto, as
// one stack, bottom first — written out, a key assigned once per layer.
pub fn stacked(gpa: std.mem.Allocator, under: ?Value, top: Value) Error!Value {
    const u = under orelse return top;
    const below: []const Value = if (u == .stack) u.stack else &.{u};
    const above: []const Value = if (top == .stack) top.stack else &.{top};
    return .{ .stack = try std.mem.concat(gpa, Value, &.{ below, above }) };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// The kept tree in a HOCON-like shorthand: a ref as written, a pending as its
/// parts side by side, a stack as its layers bottom first.
fn writeKept(value: Value, w: *std.Io.Writer) !void {
    switch (value) {
        .scalar => |s| if (s.quoted) try w.print("\"{s}\"", .{s.value}) else try w.writeAll(s.value),
        .array => |items| {
            try w.writeByte('[');
            for (items, 0..) |item, i| {
                if (i > 0) try w.writeAll(", ");
                try writeKept(item, w);
            }
            try w.writeByte(']');
        },
        .object => |members| {
            try w.writeByte('{');
            for (members, 0..) |m, i| {
                if (i > 0) try w.writeAll(", ");
                try w.print("{s}: ", .{m.key.value});
                try writeKept(m.value, w);
            }
            try w.writeByte('}');
        },
        .ref => |r| {
            try w.writeAll(if (r.flags.optional) "${?" else "${");
            for (r.path, 0..) |key, i| {
                if (i > 0) try w.writeByte('.');
                try w.writeAll(key.value);
            }
            try w.writeAll(if (r.flags.list) "[]}" else "}");
        },
        .pending => |parts| for (parts) |part| try writeKept(part.value, w),
        .stack => |layers| {
            try w.writeAll("stack(");
            for (layers, 0..) |layer, i| {
                if (i > 0) try w.writeAll(", ");
                try writeKept(layer, w);
            }
            try w.writeByte(')');
        },
    }
}
fn expectAllKept(cases: []const table.Case) !void {
    return table.expectAll(cases, .{ .dump = struct {
        fn dump(gpa: std.mem.Allocator, src: [:0]const u8) anyerror![]u8 {
            var parser = Ast.Parser{ .gpa = gpa, .t = .{ .t = Tokenizer.Tokenizer.init(src) } };
            var root = build(gpa, try parser.parse()) catch |err| return gpa.dupe(u8, @errorName(err));
            var err_pos: ?Value.Pos = null;
            root.resolve(gpa, .keep, &err_pos) catch |err| return gpa.dupe(u8, @errorName(err));
            var out: std.Io.Writer.Allocating = .init(gpa);
            try writeKept(root, &out.writer);
            return out.toOwnedSlice();
        }
    }.dump });
}
// What stays, and in what shape. A path in the document is resolved as ever;
// one that is not stays as written. A key that refers to one that waits
// waits too, as `${a}`: the key is there to be found again, and copying
// `${?PORT}` would make the required `b` optional. A field whose top waits
// keeps what is below it — `port = 8080` then `port = ${?PORT}` is the usual
// way to give a variable a default. A self-reference and `+=` with nothing
// below read the variable named like them, so they wait as written.
test "keep.what waits for the environment stays" {
    try expectAllKept(&.{
        .ok("port = ${?PORT}", "{port: ${?PORT}}"),
        .ok("port = ${PORT}", "{port: ${PORT}}"),
        .ok("hosts = ${?HOSTS[]}", "{hosts: ${?HOSTS[]}}"),
        .ok("x = 1\nb = ${x}", "{x: 1, b: 1}"),
        .ok("PORT = null\np = ${PORT}", "{PORT: null, p: null}"),
        .ok("x = 1\nb = ${x.y}", "{x: 1, b: ${x.y}}"),
        .ok("a = ${?PORT}\nb = ${a}", "{a: ${?PORT}, b: ${a}}"),
        .ok("url = \"http://\"${HOST}\":\"${port}\nport = 80", "{url: \"http://\"${HOST}\":\"80, port: 80}"),
        .ok("m = the ${w} sleeps ${?MOOD}\nw = wombat", "{m: \"the wombat sleeps \"${?MOOD}, w: wombat}"),
        .ok("port = 8080\nport = ${?PORT}", "{port: stack(8080, ${?PORT})}"),
        .ok("a = ${?PORT}\na = ${a}x", "{a: stack(${?PORT}, ${a}x)}"),
        // a self-reference over one that waits is kept once, not followed again
        .ok("a = ${?X}\na = ${a} x\na = ${a} y", "{a: stack(${?X}, ${a}\" x\", ${a}\" y\")}"),
        .ok("a = ${?X}\na += 1\na += 2", "{a: stack(${?X}, ${?a}[1], ${?a}[2])}"),
        // an object that holds what waits is referred to, not copied: a copy
        // merged onto itself doubled `p` with every line
        .ok("a = { p = ${?X} }\na = ${a} { q = 1 }\na = ${a} { r = 1 }", "{a: stack({p: ${?X}}, ${a}{q: 1}, ${a}{r: 1})}"),
        .ok("o { p = 1 }\no = ${?O}", "{o: stack({p: 1}, ${?O})}"),
        .ok("o { p = 1 }\no = ${?O}\no { q = 2 }", "{o: stack({p: 1}, ${?O}, {q: 2})}"),
        .ok("l = [1]\nl += ${?X}", "{l: [1, ${?X}]}"),
        .ok("l += 1", "{l: ${?l}[1]}"),
        .ok("gone = ${?gone}", "{gone: ${?gone}}"),
        .ok("a = ${a}", "{a: ${a}}"),
        // what the document alone decides fails now, as ever, also across a
        // part that waits: a list stays a list, text stays text
        .ok("a = [1] x", "UnsupportedConcatenation"),
        .ok("a = [1] ${?PORT} x", "UnsupportedConcatenation"),
        .ok("a = ${?PORT} [1] x", "UnsupportedConcatenation"),
        .ok("a = x ${?PORT} [1]", "UnsupportedConcatenation"),
        .ok("a = [1] ${?X} [2]", "{a: [1]${?X}[2]}"),
        .ok("a = ${?X} [1]", "{a: ${?X}[1]}"),
        .ok("a = x ${?X} y", "{a: \"x \"${?X}\" y\"}"),
    });
}
// The point of keeping: resolving the kept tree later, with whatever
// environment is there then, is resolving the document with it. Every source
// is tried with no variables and with all of `test_env` plus a few more, and
// both ways have to agree on the JSON, or on the error.
test "keep.resolved later is the same as resolved now" {
    const sources = [_][:0]const u8{
        "port = ${?PORT}",
        "port = ${PORT}",
        "hosts = ${?HOSTS[]}",
        "hosts = ${HOSTS[]} [gamma]",
        "x = 1\nb = ${x.y}",
        "a = ${?PORT}\nb = ${a}",
        "a = ${?PORT}\nb = ${?a}",
        "url = \"http://\"${HOST}\":\"${port}\nport = 80",
        "m = the ${w} sleeps ${?MOOD}\nw = wombat",
        "port = 8080\nport = ${?PORT}",
        "a = ${?PORT}\na = ${a}x",
        "a = ${?NOPE}\na = ${a}x",
        "a = ${?X}\na = ${a} x\na = ${a} y",
        "a = ${X}\na = ${a} x\na = ${a} y",
        "a = ${?X}\na += 1\na += 2",
        "a { l = [1] }\na { l = ${?L} }\na { l += 2 }\nd = ${a}",
        "a = { p = ${?X} }\na = ${a} { q = 1 }\na = ${a} { r = 1 }",
        "a { c = ${?C} }\na { c = ${a.c} x }\nd = ${a}",
        "a { c = 1 }\na = ${?O}\nd = ${a}\nd { c = ${d.c} y }",
        "a { c = 1 }\na = ${?O}\nd = ${a}\nd { e = 2, c = ${?d.c} y }",
        "o { a = ${?X}\na = ${o.a} x\na = ${o.a} y }",
        "o { p = 1 }\no = ${?O}",
        "o { p = 1 }\no = ${?O}\no { q = 2 }",
        "o { p = 1 }\no = ${?OBJ}\no { q = 2 }",
        "o { p = 1, p = ${?PORT} }\nb = ${o}\nc = ${o.p}",
        "l = [1]\nl += ${?X}",
        "l = [${?PORT}, ${?NOPE}]\nm = ${l} [2]",
        "a = ${?HOSTS[]}x",
        "a = [1] ${?PORT} x",
        "a = [1] ${?X} [2]",
        "a = ${?X} [1]",
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var none: std.process.Environ.Map = .init(gpa);
    var some: std.process.Environ.Map = .init(gpa);
    for (test_env) |kv| try some.put(kv[0], kv[1]);
    try some.put("HOST", "wombat.example");
    try some.put("O", "a string where an object was");
    try some.put("X", "x");
    try some.put("C", "q");
    try some.put("L", "a string where a list was");

    for (sources) |src| for ([_]*const std.process.Environ.Map{ &none, &some }) |env| {
        const now = try resolvedJson(gpa, src, .{ .map = env }, false);
        const later = try resolvedJson(gpa, src, .{ .map = env }, true);
        testing.expectEqualStrings(now, later) catch |err| {
            std.debug.print("source: {s}\nenv: {s}\n", .{ src, if (env == &none) "none" else "some" });
            return err;
        };
    };
}
// Each field is resolved once, also one that waits: kept, a chain where every
// key joins the one before it twice is as cheap as resolved now, not 2^n. The
// allocator gives out ten times what one pass over 40 keys takes (781), and fails
// after that.
test "keep.a field that waits is resolved once" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    try out.writer.writeAll("a0 = ${?X}\n");
    for (1..40) |i| try out.writer.print("a{d} = ${{a{d}}}${{a{d}}}\n", .{ i, i - 1, i - 1 });
    const src = try out.toOwnedSliceSentinel(0);

    var failing = testing.FailingAllocator.init(arena.allocator(), .{ .fail_index = 8_000 });
    const gpa = failing.allocator();
    var parser = Ast.Parser{ .gpa = gpa, .t = .{ .t = Tokenizer.Tokenizer.init(src) } };
    var root = try build(gpa, try parser.parse());
    var err_pos: ?Value.Pos = null;
    try root.resolve(gpa, .keep, &err_pos);
    try testing.expectEqual(.pending, std.meta.activeTag(root.object[39].value));
}
/// `src` resolved with `env` as JSON, or the name of the error. With `kept`,
/// it is resolved with `.keep` first, and the tree that leaves resolved again.
fn resolvedJson(gpa: std.mem.Allocator, src: [:0]const u8, env: Value.Env, kept: bool) ![]const u8 {
    var parser = Ast.Parser{ .gpa = gpa, .t = .{ .t = Tokenizer.Tokenizer.init(src) } };
    var root = try build(gpa, try parser.parse());
    var err_pos: ?Value.Pos = null;
    if (kept) root.resolve(gpa, .keep, &err_pos) catch |err| return @errorName(err);
    root.resolve(gpa, env, &err_pos) catch |err| return @errorName(err);
    return std.json.Stringify.valueAlloc(gpa, root, .{});
}
