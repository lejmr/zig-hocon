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
        /// Parts written next to each other with no separator between them, e.g.
        /// `grumpy "wombat"`, `[1] [2]`, `{x=1} {y=2}`. Whether they join as text,
        /// concatenate as arrays, merge as objects, or are a type error is not a
        /// syntactic question, so the ast leaves it open and stores the parts.
        ///
        /// Adjacent *unquoted* strings are one part, not several — they are a
        /// contiguous slice of the input, so `a = grumpy wombat` stays a plain
        /// `value`. A `concat` appears only when the value cannot be one slice:
        /// a quoted part is involved, or a part is an object or an array.
        concat,
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

    /// member := value ( ('=' | ':') value | object )
    ///
    /// Exactly one assignment and one value: `a = b = c` is not legal HOCON. The
    /// `=` may be omitted, but only directly before a block — `a [1]` is an error
    /// while `a {x=1}` is not (both verified against tools/oracle/hocon-java).
    fn parseStringAssignment(self: *Parser) Error!Node {
        const key = try self.parseStringValue();

        if (self.t.peek().tag != .l_brace) {
            if (self.t.next().tag != .assignment) return Error.UnexpectedToken;
        }

        const children = try self.gpa.alloc(Node, 2);
        children[0] = key;
        children[1] = try self.parseParts();
        return .{ .kind = .assignment, .children = children };
    }

    /// One value: the parts written next to each other with no separator in
    /// between. A part is text, a block or an array; `=` is deliberately not one,
    /// so `a = b = c` ends the value here and the caller reports the stray `=`.
    ///
    /// Lives here rather than inside `parseStringValue` so that the text scanner
    /// stays text-only. Array elements will want the same loop, which is why it
    /// is its own function.
    fn parseParts(self: *Parser) Error!Node {
        var parts: std.ArrayList(Node) = .empty;
        defer parts.deinit(self.gpa);

        while (true) {
            const part: Node = switch (self.t.peek().tag) {
                .string, .quoted_string => try self.parseStringValue(),
                .l_brace => blk: {
                    _ = self.t.next();
                    break :blk try self.parseInternal(.r_brace, .block);
                },
                .l_bracket => blk: {
                    _ = self.t.next();
                    break :blk try self.parseInternal(.r_bracket, .array);
                },
                else => break,
            };
            // `parseStringValue` already returns a concat when the text itself is
            // several parts; splice those in rather than nesting concat in concat.
            if (part.kind == .concat) {
                try parts.appendSlice(self.gpa, part.children);
            } else {
                try parts.append(self.gpa, part);
            }
        }

        return switch (parts.items.len) {
            0 => Error.UnexpectedToken,
            1 => parts.items[0],
            else => .{ .kind = .concat, .children = try parts.toOwnedSlice(self.gpa) },
        };
    }

    /// Appends `input[start..end]` as a value part, preceded by the whitespace
    /// separating it from the part before — `prev_end` tracks where that one
    /// stopped. Keeping the gap as its own part means a part is always exactly
    /// the text of its token, with one representation instead of two.
    fn appendPart(
        self: *Parser,
        parts: *std.ArrayList(Node),
        prev_end: *?usize,
        start: usize,
        end: usize,
    ) Error!void {
        const input = self.t.t.input;
        if (prev_end.*) |gap_start| {
            if (gap_start < start) try parts.append(self.gpa, .{
                .kind = .value,
                .children = &.{},
                .value = input[gap_start..start],
            });
        }
        try parts.append(self.gpa, .{
            .kind = .value,
            .children = &.{},
            .value = input[start..end],
        });
        prev_end.* = end;
    }

    /// Parses one value: everything written next to each other with no separator
    /// in between. Used on both sides of an assignment — a key follows the same
    /// concatenation rules as a value, so `grumpy "wombat" = 1` has the key
    /// `grumpy wombat` (verified against tools/oracle/hocon-java).
    ///
    /// Consumes tokens only for as long as they are parts. Anything else — a
    /// separator, a closing brace, `=`, `.eof`, an invalid character — ends the
    /// value and is left for the caller, which is the one that knows whether it
    /// is legal there. That keeps the rule positive: there is no list of
    /// terminators to keep in sync, only a list of what a part can be.
    ///
    /// Returns, depending on how many parts were found:
    ///   - 0  `Error.UnexpectedToken`, e.g. for `a = ` with nothing after it
    ///   - 1  that part itself, so the common `a = b` stays flat
    ///   - 2+ a `.concat` holding them, since what they do together (join as
    ///        text, merge as objects, concatenate as arrays, or fail as a type
    ///        error) depends on their types and belongs to evaluation
    ///
    /// A run of adjacent unquoted strings counts as *one* part: it is a single
    /// contiguous slice of the input, so `grumpy wombat` stays a plain `.value`.
    /// The whitespace between two parts becomes a part of its own, and quoted
    /// parts keep their quotes, so joining the parts end to end reproduces the
    /// source and `"1"` stays distinguishable from `1`.
    ///
    fn parseStringValue(self: *Parser) Error!Node {
        var parts: std.ArrayList(Node) = .empty;
        defer parts.deinit(self.gpa);

        // Where the last emitted part stopped, so the next gap can be sliced.
        var prev_end: ?usize = null;
        // A run of adjacent unquoted strings is one part: it is one contiguous
        // slice of the input, so it is only emitted once the run ends.
        var run: ?[2]usize = null;

        while (true) {
            const token = self.t.peek();
            switch (token.tag) {
                .string => {
                    _ = self.t.next();
                    if (run) |*r| {
                        r[1] = token.loc.end;
                    } else {
                        run = .{ token.loc.start, token.loc.end };
                    }
                },
                .quoted_string => {
                    _ = self.t.next();
                    if (run) |r| {
                        try self.appendPart(&parts, &prev_end, r[0], r[1]);
                        run = null;
                    }
                    // The tokenizer reports the loc of the content only, so widen
                    // it by one on each side to keep the quotes in the tree —
                    // later phases need `"1"` to stay distinguishable from `1`.
                    try self.appendPart(&parts, &prev_end, token.loc.start - 1, token.loc.end + 1);
                },
                else => break,
            }
        }
        if (run) |r| try self.appendPart(&parts, &prev_end, r[0], r[1]);

        return switch (parts.items.len) {
            0 => Error.UnexpectedToken,
            1 => parts.items[0],
            else => Node{ .kind = .concat, .children = try parts.toOwnedSlice(self.gpa) },
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
                .string, .quoted_string => try if (containerType == .array) self.parseStringValue() else self.parseStringAssignment(),
                .l_brace => blk: {
                    _ = self.t.next();
                    break :blk try self.parseInternal(.r_brace, .block);
                },
                .l_bracket => blk: {
                    _ = self.t.next();
                    break :blk try self.parseInternal(.r_bracket, .array);
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
        .root, .block, .array, .assignment, .concat => {
            try w.writeAll(switch (node.kind) {
                .root => "root(",
                .block => "block(",
                .array => "array(",
                .concat => "concat(",
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

fn expectString(input: [:0]const u8, expected: []const u8) !void {
    errdefer {
        std.debug.print("failed on input: \"{s}\"\n", .{input});
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

    const node = try p.parseStringValue();

    const got = try dump(node, testing.allocator);
    defer testing.allocator.free(got);

    try testing.expectEqualStrings(expected, got);
}

// java ✓ · pyhocon ✓ · spec ✓ — joining the parts end to end reproduces what the
// oracles return:
//   'a = x "y"'   -> {"a":"x y"}       'a = "a""b"'  -> {"a":"ab"}
//   'a = "a" "b"' -> {"a":"a b"}       'a = x  '     -> {"a":"x"}
//
// One rule for the shape: **a part is exactly the text of its token, and the
// whitespace between two parts is a part of its own.** Nothing is folded into a
// neighbour, so `x "y"` has a single representation rather than one rule for
// "gap after an unquoted run" and another for "gap between two quoted strings".
//
// A gap part is emitted only when there is a gap — an empty `value()` carries
// nothing and every later phase would have to skip it. Gaps only ever appear
// between text parts: whitespace plays no role in merging objects or
// concatenating arrays, so `{x=1} {y=2}` gives `concat(block(…), block(…))`.
//
// Adjacent *unquoted* strings stay one part, being one contiguous slice of the
// input — `grumpy wombat` is `value(grumpy wombat)`, not two parts and a gap.
test "validate parse string functionality" {
    try expectString("x", "value(x)");
    try expectString("\"x\"", "value(\"x\")");
    try expectString("grumpy wombat", "value(grumpy wombat)");

    // Trailing whitespace is not part of the value.
    try expectString("x  ", "value(x)");

    // A quoted part with nothing after it — the pending run must not be left
    // half-open, or the terminator branch reads an end that was never set.
    try expectString("x \"y\"", "concat(value(x), value( ), value(\"y\"))");
    try expectString("\"x\" y", "concat(value(\"x\"), value( ), value(y))");

    try expectString("\"a\"\"b\"", "concat(value(\"a\"), value(\"b\"))");
    try expectString("\"a\" \"b\"", "concat(value(\"a\"), value( ), value(\"b\"))");
    try expectString("x\"y\"", "concat(value(x), value(\"y\"))");

    // Bigger examples
    try expectString("grumpy wombat {additional = true}", "value(grumpy wombat)");
    try expectString(
        "grumpy wombat    \"caffeinated but polite\"   send help",
        "concat(value(grumpy wombat), value(    ), value(\"caffeinated but polite\"), value(   ), value(send help))",
    );
    try expectString(
        "grumpy wombat    \"caffeinated but polite\"   send help    ",
        "concat(value(grumpy wombat), value(    ), value(\"caffeinated but polite\"), value(   ), value(send help))",
    );
}

// java ✓ · pyhocon ✓ · spec ✓ — all six inputs agree on both oracles.
// `:` and `=` are interchangeable; `,` and newline are interchangeable separators.
test "assignment with =" {
    try expectAst("a = b", "root(assign(value(a), value(b)))");
    try expectAst("a: b", "root(assign(value(a), value(b)))");
    try expectAst("a = b\nc: d", "root(assign(value(a), value(b)), assign(value(c), value(d)))");
    try expectAst("{a = b}", "root(block(assign(value(a), value(b))))");
    try expectAst("{a = b\nc: d}", "root(block(assign(value(a), value(b)), assign(value(c), value(d))))");
    try expectAst("{a = b, c: d}", "root(block(assign(value(a), value(b)), assign(value(c), value(d))))");
}

// java ✓ · pyhocon ✓ · spec ✓ — all seven inputs agree on both oracles,
// including the empty block (`a = {}` -> {"a":{}}).
test "nested blocks" {
    try expectAst("a = {b = c}", "root(assign(value(a), block(assign(value(b), value(c)))))");
    try expectAst("a: {c: d}", "root(assign(value(a), block(assign(value(c), value(d)))))");
    try expectAst("a = {}", "root(assign(value(a), block()))");
    try expectAst("a = {b = {c = d}}", "root(assign(value(a), block(assign(value(b), block(assign(value(c), value(d)))))))");
    try expectAst("a = {b = c}\nd = e", "root(assign(value(a), block(assign(value(b), value(c)))), assign(value(d), value(e)))");
    try expectAst("a = {b = c, d = e}", "root(assign(value(a), block(assign(value(b), value(c)), assign(value(d), value(e)))))");
    try expectAst("{a = {b = c}}", "root(block(assign(value(a), block(assign(value(b), value(c))))))");
}

// java ✓ · pyhocon ✓ · spec ✓ — both `#` and `//` start a comment, a comment
// terminates the value on its line, and runs of blank lines collapse.
test "separators and comments are not nodes" {
    try expectAst("", "root()");
    try expectAst("\na = b\n", "root(assign(value(a), value(b)))");
    try expectAst("a = b\n\nc = d", "root(assign(value(a), value(b)), assign(value(c), value(d)))");
    try expectAst("# comment\na = b", "root(assign(value(a), value(b)))");
    try expectAst("// comment\na = b", "root(assign(value(a), value(b)))");
    try expectAst("a = b # comment\nc = d", "root(assign(value(a), value(b)), assign(value(c), value(d)))");
}

// java ✓ · pyhocon ✓ · spec ✓ — unquoted strings may contain spaces on both
// sides of the assignment; interior whitespace is kept verbatim, the trailing
// run is dropped.
//   'a = grumpy   wombat' -> {"a":"grumpy   wombat"}
//   'a b = c'           -> {"a b":"c"}
// Careful: a tab is NOT the same case — java keeps `a = b\tc` as "b\tc", pyhocon
// expands it to spaces. Follow java when that test gets written.
test "multi-word keys and values" {
    try expectAst("a = grumpy wombat", "root(assign(value(a), value(grumpy wombat)))");
    try expectAst("a = grumpy   wombat", "root(assign(value(a), value(grumpy   wombat)))");
    try expectAst("a b = c", "root(assign(value(a b), value(c)))");
}

// java ✓ · pyhocon ✓ · spec ✓ — 'a {b = c}' -> {"a":{"b":"c"}} on both oracles.
test "the = before a block may be omitted" {
    try expectAst("a {b = c}", "root(assign(value(a), block(assign(value(b), value(c)))))");
}

// java ✓ · pyhocon ✓ · spec ✓ — all eleven inputs agree on both oracles.
//
// An array node holds its elements directly, with no `assign` in between — that
// is the whole difference from a block: `parseInternal` collects members, an
// array collects values. Separators are the same (`,` and newline, runs collapse,
// a trailing one is allowed), and an element may itself be an array or a block.
test "arrays" {
    try expectAst("a = []", "root(assign(value(a), array()))");
    try expectAst("a = [1]", "root(assign(value(a), array(value(1))))");
    try expectAst("a = [1, 2]", "root(assign(value(a), array(value(1), value(2))))");
    try expectAst("a = [1, 2,]", "root(assign(value(a), array(value(1), value(2))))");
    try expectAst("a = [\n1\n2\n]", "root(assign(value(a), array(value(1), value(2))))");
    try expectAst("a = [grumpy wombat]", "root(assign(value(a), array(value(grumpy wombat))))");
    try expectAst("a = [[1], [2]]", "root(assign(value(a), array(array(value(1)), array(value(2)))))");
    try expectAst("a = [1, [2, [3]]]", "root(assign(value(a), array(value(1), array(value(2), array(value(3))))))");
    try expectAst("a = [{b = c}]", "root(assign(value(a), array(block(assign(value(b), value(c))))))");
    try expectAst("a = [{b = c}, {d = e}]", "root(assign(value(a), array(block(assign(value(b), value(c))), block(assign(value(d), value(e))))))");
    try expectAst("a = {b = [1, 2]}", "root(assign(value(a), block(assign(value(b), array(value(1), value(2))))))");
}

// java ✓ · pyhocon ✓ · spec ✓ — the input itself is uncontroversial
// ('a = "b"' -> {"a":"b"} on both oracles); what is unresolved is our own ast.
//
// Blocked on a tokenizer decision, not on the parser: Tokenizer.zig:69 and :181
// report `quoted_string` locs *without* the surrounding quotes, so `a = "b"` and
// `a = b` build an identical tree. Type inference later needs to tell `a = "1"`
// (string) from `a = 1` (number), so the quotes have to survive into the ast —
// either by widening the loc, or by flagging the node as quoted.
test "quoted value keeps its quotes" {
    try expectAst("a = \"b\"", "root(assign(value(a), value(\"b\")))");
}
