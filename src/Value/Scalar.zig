//! Place holder for any string or number: text, quoted or not, whatever it
//! will be read as.

const std = @import("std");
const Value = @import("../Value.zig").Value;
const Error = @import("../Value.zig").Error;
const unqoute = @import("../utils/unqoute.zig");

// For the tests.
const testing = std.testing;
const Ast = @import("../Ast.zig");
const Node = Ast.Node;
const Tokenizer = @import("../Tokenizer.zig");
const table = @import("../table.zig");
const build = @import("build.zig").build;
const v = @import("build.zig").v;
const n = @import("build.zig").n;

const Scalar = @This();

value: []const u8,
quoted: bool,
/// Where the text is written, for an error in reading it as a type (a
/// duration in a unit there is none of): the file and the offset there, as
/// in `Ref`. Offset 0 is nowhere, as a value never starts a file: a key or a
/// `[` comes first. Text from a JSON include or made in code has no place.
file: u16 = 0,
pos: u32 = 0,

pub fn fromNode(gpa: std.mem.Allocator, node: Node, ctx: Value.Context) Error!Scalar {
    const ut = unqoute.unquote(gpa, node.value) catch |err| {
        ctx.fail(node.pos);
        return err;
    };
    return .{ .value = ut.text, .quoted = ut.quoted, .file = ctx.file, .pos = @intCast(node.pos) };
}

/// Where it is written, if anywhere.
pub fn at(self: Scalar) ?Value.Pos {
    if (self.pos == 0) return null;
    return .{ .file = self.file, .offset = self.pos };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "value.a scalar keeps its text and remembers the quotes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const plain = try build(gpa, v("1"));
    try testing.expectEqualStrings("1", plain.scalar.value);
    try testing.expect(!plain.scalar.quoted);

    const quoted = try build(gpa, v("\"1\""));
    try testing.expectEqualStrings("1", quoted.scalar.value);
    try testing.expect(quoted.scalar.quoted);
}
// java ✓ · pyhocon ✓ · spec ✓ — `null`, `true` and a number are unquoted text
// and nothing more until type conversion, so they join and fail like any other:
//
//   'a = null'      -> {"a":null}       kept as written
//   'a = null "x"'  -> {"a":"null x"}   joins as text
//   'a = 1.5e10'    -> {"a":15000000000}  java converts, this layer does not
//   'a = [1] null'  -> WrongType        a list and a non-list, as ever
//
// Reading a type out of the text belongs to evaluation; giving one to it here
// would mean `a = "null"` and `a = null` stopped being distinguishable, which
// is the whole reason a scalar carries its delimiter as a flag.
test "value.null, booleans and numbers are text at this layer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    for ([_][]const u8{ "null", "true", "false", "1.5e10" }) |word| {
        errdefer std.debug.print("failed on {s}\n", .{word});
        const val = try build(gpa, v(word));
        try testing.expectEqualStrings(word, val.scalar.value);
        try testing.expect(!val.scalar.quoted);
    }

    var joined = [_]Node{ v("null"), v(" "), v("\"x\"") };
    const j = try build(gpa, n(.concat, &joined));
    try testing.expectEqualStrings("null x", j.scalar.value);

    var e1 = [_]Node{v("1")};
    var mixed = [_]Node{ n(.array, &e1), v(" "), v("null") };
    try testing.expectError(
        Error.UnsupportedConcatenation,
        build(gpa, n(.concat, &mixed)),
    );
}
