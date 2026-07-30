const Tokenizer = @import("Tokenizer.zig");

const Node = struct {
    kind: NodeKind,
    children: []Node,
    value: []const u8 = "",

    const NodeKind = enum {
        root,
        assignment,
        block,
        array,
        value,
        include,
    };
};

const PeakingTokenizer = struct {
    gpa: std.mem.Allocator,
    t: Tokenizer.Tokenizer,
    peeked: ?Tokenizer.Token = null,

    fn next(self: *PeakingTokenizer) Tokenizer.Token {
        if (self.peeked) |token| {
            self.peeked = null;
            return token;
        }
        return self.t.next();
    }

    fn peek(self: *PeakingTokenizer) Tokenizer.Token {
        if (self.peeked == null) {
            self.peeked = self.t.next();
        }
        return self.peeked.?;
    }
};

pub const Parser = struct {
    gpa: std.mem.Allocator,
    t: PeakingTokenizer,

    const StringStates = enum {
        start,
        string_lhs,
        string_rhs,
        // block,
        // array,
        // string,
        // string_rhs,
    };

    /// Written out rather than inferred (`!Node`): `parseInternal` recurses, and
    /// an inferred error set cannot be resolved when it depends on itself.
    pub const Error = error{UnexpectedToken} || std.mem.Allocator.Error;

    pub fn init(allocator: std.mem.Allocator, t: *Tokenizer.Tokenizer) Parser {
        return Parser{ .gpa = allocator, .t = &PeakingTokenizer{
            .gpa = allocator,
            .t = t,
        } };
    }

    fn parse(self: *Parser) Error!Node {
        return self.parseInternal(.eof, .root);
    }

    fn parseStrings(self: *Parser) Error!Node {
        var token: Tokenizer.Token = undefined;
        var key_quoted: bool = false;
        var key_loc: [2]usize = .{ 0, 0 };
        var values: std.ArrayList(Tokenizer.Token) = .empty;
        defer values.deinit(self.gpa);

        return states: switch (StringStates.start) {
            .start => {
                token = self.t.next();
                key_quoted = if (token.tag == .string) false else true;
                key_loc = .{ token.loc.start, token.loc.end };
                continue :states .string_lhs;
            },
            .string_lhs => {
                token = self.t.next();
                switch (token.tag) {
                    .string => {
                        key_loc[1] = token.loc.end;
                        continue :states .string_lhs;
                    },
                    .assignment => continue :states .string_rhs,
                    else => return Error.UnexpectedToken,
                }
            },
            .string_rhs => {
                token = self.t.peek();
                switch (token.tag) {
                    .string, .quoted_string => {
                        _ = self.t.next();
                        try values.append(self.gpa, token);
                        continue :states .string_rhs;
                    },
                    else => {
                        const children = try self.gpa.alloc(Node, 2);
                        const start = values.items[0].loc.start;
                        const end = values.getLast().loc.end;
                        children[0] = .{
                            .kind = .value,
                            .value = self.t.t.input[key_loc[0]..key_loc[1]],
                            .children = &.{},
                        };
                        children[1] = .{
                            .kind = .value,
                            .value = self.t.t.input[start..end],
                            .children = &.{},
                        };
                        return Node{ .kind = .assignment, .children = children };
                    },
                }
            },
        };
    }

    fn parseInternal(self: *Parser, ending: Tokenizer.Token.Tag, containerType: Node.NodeKind) Error!Node {
        var objects: std.ArrayList(Node) = .empty;
        while (self.t.peek().tag != ending) {
            const node: ?Node = switch (self.t.peek().tag) {
                .newline, .comma => blk: {
                    _ = self.t.next();
                    break :blk null;
                },
                .string, .quoted_string => try self.parseStrings(),
                .l_brace => blk: {
                    _ = self.t.next();
                    break :blk try self.parseInternal(.r_brace, .block);
                },
                else => return Error.UnexpectedToken,
            };

            if (node != null) {
                try objects.append(self.gpa, node.?);
            }
        }

        _ = self.t.next();
        return Node{
            .kind = containerType,
            .children = try objects.toOwnedSlice(self.gpa),
        };
    }
};

const std = @import("std");
const testing = std.testing;

/// Prints the whole token stream for `input`, one token per line. `expectAst`
/// runs this on failure, so a red test shows straight away whether the problem is
/// in the tokenizer or in the parser.
fn dumpTokens(input: [:0]const u8) void {
    var t = Tokenizer.Tokenizer.init(input);
    std.debug.print("tokens for \"{s}\":\n", .{input});
    while (true) {
        const tok = t.next();
        std.debug.print("  {s:<16} @{d}..{d} \"{s}\"\n", .{
            @tagName(tok.tag),
            tok.loc.start,
            tok.loc.end,
            input[tok.loc.start..tok.loc.end],
        });
        if (tok.tag == .eof or tok.tag == .invalid) break;
    }
}

/// Renders `node` as a one-line s-expression, e.g. `root(assign(value(a), value(b)))`.
/// Leaf text is `node.value` verbatim, so quotes are kept: `a = "b"` dumps as
/// `value("b")`.
fn dumpNode(node: Node, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (node.kind) {
        // Containers all render the same way: kind(child, child, …). An
        // assignment is one too — children[0] is the key, children[1] the value.
        .root, .block, .array, .assignment => {
            try w.writeAll(switch (node.kind) {
                .root => "root(",
                .block => "block(",
                .array => "array(",
                else => "assign(",
            });
            for (node.children, 0..) |child, i| {
                if (i != 0) try w.writeAll(", ");
                try dumpNode(child, w);
            }
            try w.writeByte(')');
        },
        .value => try w.print("value({s})", .{node.value}),
        .include => try w.print("include({s})", .{node.value}),
    }
}

/// `dumpNode` into a freshly allocated string owned by the caller.
fn dump(node: Node, allocator: std.mem.Allocator) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try dumpNode(node, &aw.writer);
    return aw.toOwnedSlice();
}

/// Parses `input` and asserts that dumping the resulting tree renders exactly
/// `expected`. This is the single point coupling the tests to the parser API —
/// if the signature changes, only this function needs updating.
fn expectAst(input: [:0]const u8, expected: []const u8) !void {
    errdefer {
        std.debug.print("failed on input: \"{s}\"\n", .{input});
        dumpTokens(input);
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const t = Tokenizer.Tokenizer.init(input);
    var p = Parser{
        .gpa = arena.allocator(),
        .t = .{
            .gpa = arena.allocator(),
            .t = t,
        },
    };
    const root = try p.parse();

    const got = try dump(root, testing.allocator);
    defer testing.allocator.free(got);

    try testing.expectEqualStrings(expected, got);
}

test "assignment with =" {
    try expectAst("a = b", "root(assign(value(a), value(b)))");
    try expectAst("a: b", "root(assign(value(a), value(b)))");
    try expectAst("a = b\nc: d", "root(assign(value(a), value(b)), assign(value(c), value(d)))");
    try expectAst("{a = b}", "root(block(assign(value(a), value(b))))");
    try expectAst("{a = b\nc: d}", "root(block(assign(value(a), value(b)), assign(value(c), value(d))))");
    try expectAst("{a = b, c: d}", "root(block(assign(value(a), value(b)), assign(value(c), value(d))))");
}

test "complex structures with arrays" {
    try expectAst("a: {c: d}", "root(assign(value(a), block(assign(value(c), value(d)))))");
    //try expectAst("{a = b, c: [1,2,3]}", "root(block(assign(value(a), value(b)), assign(value(c), array(1,2,3))))");
}
