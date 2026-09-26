//! zig-hocon: a HOCON (Human-Optimized Config Object Notation) parser for Zig.
const std = @import("std");

test {
    _ = @import("Tokenizer.zig");
    _ = @import("Ast.zig");
    _ = @import("utils/unqoute.zig");
    _ = @import("Key.zig");
    _ = @import("Value.zig");
    _ = @import("Config.zig");
}

// Export functionality to users
const config = @import("Config.zig").Config;
pub const Value = @import("Value.zig").Value;
pub const Parsed = config.Parsed;
pub const parseFromSlice = config.parseFromSlice;
pub const parseFromSliceLeaky = config.parseFromSliceLeaky;
pub const ParseFromValueError = config.ConvertError;

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
//
// Add `.{}` to the calls once ParseOptions exists.

test "parsed.deinit gives back everything the parse took" {
    const T = struct { name: []const u8, ports: []const u16, tls: ?struct { cert: []const u8 } };
    const parsed = try hocon.parseFromSlice(T, testing.allocator,
        \\name = the dog ate my homework
        \\ports = [80, 443]
        \\tls { cert = grumpy-wombat.pem }
    );
    defer parsed.deinit();

    try testing.expectEqualStrings("the dog ate my homework", parsed.value.name);
    try testing.expectEqualSlices(u16, &.{ 80, 443 }, parsed.value.ports);
    try testing.expectEqualStrings("grumpy-wombat.pem", parsed.value.tls.?.cert);
}

// The value is plain T — no wrapper type to unwrap field by field.
test "parsed.value is the target type itself" {
    const T = struct { a: usize };
    const parsed = try hocon.parseFromSlice(T, testing.allocator, "a = 1");
    defer parsed.deinit();
    comptime std.debug.assert(@TypeOf(parsed.value) == T);
}

// A failed parse returns an error and leaks nothing: the arena, and the memory
// holding the arena, are both given back on the way out (the two `errdefer`s).
test "parsed.a failed parse leaves nothing behind" {
    const T = struct { a: usize, b: []const u8 };
    try testing.expectError(error.MissingField, hocon.parseFromSlice(T, testing.allocator, "b = the cat sat on the keyboard"));
    try testing.expectError(error.TypeMismatch, hocon.parseFromSlice(T, testing.allocator, "a { x = 1 }\nb = x"));
    try testing.expectError(error.UnexpectedToken, hocon.parseFromSlice(T, testing.allocator, "a = 1\nb = {"));
}

// Parsed is passed around by value, so a copy has to free the same memory as the
// original — which works only because the arena sits behind a pointer.
test "parsed.a copy frees what the original allocated" {
    const T = struct { a: []const u8 };
    const original = try hocon.parseFromSlice(T, testing.allocator, "a = the coffee runs out on monday morning");
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
            const parsed = try hocon.parseFromSlice(struct { a: []const u8, b: ?usize }, gpa, "a = and now it looks innocent\nb = 2");
            parsed.deinit();
        }
    }.run, .{});
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
    const parsed = try hocon.parseFromSlice(hocon.Value, testing.allocator, src);
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

// S10.11 · java ≈ · pyhocon ≈ · spec ✓ — a number prints as written. Both oracles
// renormalise 1e5 (java 100000, pyhocon 100000.0): the same JSON value, other text.
test "json.a number prints as written" {
    try expectJson("a = 1e5", "{\"a\":1e5}");
    try expectJson("a = 1.50", "{\"a\":1.50}");
}

// A number is JSON's number grammar, all of the text or nothing.
// `-foo` · java ✓ · pyhocon ✓ — a string (FINDINGS.md: the spec would not even
//          parse it, see unquoted-strings/012).
// `.5`   · java ✓ · pyhocon ⚠️ 0.5 — JSON numbers need a digit before the dot.
// `1.`   · java ⚠️ 1 · pyhocon ✓ — nor may they end in one.
// `1 2`  · java ✓ · pyhocon ✓ — one unquoted text with a space, not a number.
test "json.almost a number is a string" {
    try expectJson("a = -foo", "{\"a\":\"-foo\"}");
    try expectJson("a = .5", "{\"a\":\".5\"}");
    try expectJson("a = 1.", "{\"a\":\"1.\"}");
    try expectJson("a = 1 2", "{\"a\":\"1 2\"}");
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

// Nothing resolves substitutions yet, so a tree holding one is refused when it is
// parsed — Stringify allows no error of its own, printing is too late.
test "json.an unresolved substitution is an error" {
    try testing.expectError(error.Unresolved, hocon.parseFromSlice(hocon.Value, testing.allocator, "a = ${b}"));
    try testing.expectError(error.Unresolved, hocon.parseFromSlice(hocon.Value, testing.allocator, "a { b = [1, ${c}] }"));
}
