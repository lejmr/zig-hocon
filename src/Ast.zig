const std = @import("std");
const testing = std.testing;

const Tokenizer = @import("Tokenizer.zig");
const Key = @import("Key.zig");
const table = @import("table.zig");
const Case = table.Case;
const unquote = @import("utils/unqoute.zig");

pub const Node = struct {
    kind: NodeKind,
    children: []Node,
    value: []const u8 = "",

    pub const NodeKind = enum {
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
        /// A substitution: `${a.b}`. `children[0]` is the path it refers to,
        /// kept as the text it was written as — `${a."b.c"}` and `${a.b.c}`
        /// stay distinguishable because splitting on `.` happens later, once
        /// keys and substitutions can share one splitter.
        ///
        /// Only the *reference* is syntax; what it resolves to, and whether the
        /// parts around it then join as text, merge as objects or concatenate
        /// as lists, needs the finished document — so it stays here as a node
        /// rather than being folded into the neighbouring text.
        subst,
        /// The same, written `${?a.b}`. The difference is not "may be missing":
        /// an unresolved optional substitution removes the *member it is part
        /// of* rather than producing an empty value, so `a = ${?nope}` leaves no
        /// `a` at all. Its own kind rather than a flag on `subst`, so a tree
        /// dump cannot silently lose it.
        subst_optional,
    };
};

const PeakingTokenizer = struct {
    t: Tokenizer.Tokenizer,
    peeked: ?Tokenizer.Token = null,
    last_end: usize = 0,

    fn next(self: *PeakingTokenizer) Tokenizer.Token {
        const token = if (self.peeked) |peeked| blk: {
            self.peeked = null;
            break :blk peeked;
        } else self.t.next();
        self.last_end = token.loc.end;
        return token;
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

    /// Written out rather than inferred (`!Node`): `parseContainer` recurses, and
    /// an inferred error set cannot be resolved when it depends on itself.
    pub const Error = error{UnexpectedToken} || std.mem.Allocator.Error || unquote.Error;

    pub fn parse(self: *Parser) Error!Node {
        return self.parseContainer(.eof, .root);
    }

    /// One member of an object: a key, a separator, and a value. Only
    /// `parseContainer` calls this, and only where a member may begin — which is
    /// what makes the separator *required* rather than something to guess at
    /// afterwards from the parts that happened to show up.
    ///
    /// The key side is text only: `${b} = 1`, `[a] = 1` and `{a} = 1` are all
    /// errors, so this is `parseText` rather than `parseValue`.
    ///
    /// Newlines are skipped on both sides of the separator. While the parser is
    /// waiting for `=` or for the value there is nothing complete for a newline
    /// to end, so `a\n= b` and `a =\n\nb` are both fine. Everywhere else a
    /// newline does end the member, which is why `a\nb = c` is an error: the
    /// separator is still required once the newlines are gone.
    fn parseMember(self: *Parser) Error!Node {
        const key = try self.parseText();

        while (self.t.peek().tag == .newline) _ = self.t.next();
        switch (self.t.peek().tag) {
            .assignment => {
                _ = self.t.next();
                while (self.t.peek().tag == .newline) _ = self.t.next();
            },
            // `a {b = c}` .. the separator may be omitted before a block, but
            // only before a block — java rejects `a [1, 2]`.
            .l_brace => {},
            else => return Error.UnexpectedToken,
        }

        return prepareMemberNode(self.gpa, key, try self.parseValue());
    }

    /// One value: the parts written next to each other with no separator in
    /// between. A part is text, a block or an array; `=` is deliberately not one,
    /// so `a = b = c` ends the value here and the caller reports the stray `=`.
    ///
    /// Lives here rather than inside `parseText` so that the text scanner
    /// stays text-only. Array elements want the same loop, which is why it
    /// is its own function — and why it knows nothing about keys or `=`.
    ///
    /// A newline ends the value, with no exceptions: the two places where one is
    /// skipped (around `=`, and after the `include` keyword) are both places
    /// where the parser has committed to something and is waiting for it, so
    /// they live in `parseMember` and `parseInclude` instead.
    fn parseValue(self: *Parser) Error!Node {
        var parts: std.ArrayList(Node) = .empty;
        defer parts.deinit(self.gpa);

        var concat_type: ?Node.NodeKind = null;
        // Where the previous part ended, so the whitespace before the next one
        // can be sliced out. Null until the first part, which has nothing before
        // it to be separated from.
        var prev_end: ?usize = null;

        while (true) {
            // Read before the switch, kept until after it: the gap belongs in
            // front of the part, but the part is what decides there is one at
            // all — a value that ends here leaves its trailing whitespace out.
            const part_start = self.t.peek().loc.start;
            const gap: ?[]const u8 = if (prev_end) |end|
                if (end < part_start) self.t.t.input[end..part_start] else null
            else
                null;

            const part: Node = switch (self.t.peek().tag) {
                .string, .quoted_string, .multiline_string => try self.parseText(),
                .l_brace => blk: {
                    _ = self.t.next();
                    if (concat_type != null and concat_type != .block) {
                        return Error.UnexpectedToken;
                    }
                    concat_type = .block;

                    break :blk try self.parseContainer(.r_brace, .block);
                },
                .l_bracket => blk: {
                    _ = self.t.next();
                    if (concat_type != null and concat_type != .array) {
                        return Error.UnexpectedToken;
                    }
                    concat_type = .array;

                    break :blk try self.parseContainer(.r_bracket, .array);
                },
                .dollar_brace_optional, .dollar_brace => |tag| blk: {
                    _ = self.t.next();

                    // The inside is a path expression, which is text — anything
                    // else is rejected, and then the `}` is required.
                    const path = try self.parseValue();
                    if (!isPathText(path)) return Error.UnexpectedToken;
                    if (self.t.next().tag != .r_brace) return Error.UnexpectedToken;

                    break :blk Node{
                        .kind = if (tag == .dollar_brace_optional) .subst_optional else .subst,
                        .children = try self.gpa.dupe(Node, &.{path}),
                    };
                },
                else => break,
            };

            if (gap) |text| try parts.append(self.gpa, .{
                .kind = .value,
                .value = text,
                .children = &.{},
            });
            prev_end = self.t.last_end;

            switch (part.kind) {
                else => {
                    try parts.append(self.gpa, part);
                },
                .concat => {
                    try parts.appendSlice(self.gpa, part.children);
                },
            }

            // Early stop for arrays
            const next = self.t.peek();
            if (next.tag == .comma) {
                _ = self.t.next();
                break;
            }
        }

        return switch (parts.items.len) {
            0 => Error.UnexpectedToken,
            1 => parts.items[0],
            else => Node{
                .kind = .concat,
                .children = try parts.toOwnedSlice(self.gpa),
            },
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
    fn parseText(self: *Parser) Error!Node {
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
                .quoted_string, .multiline_string => {
                    _ = self.t.next();
                    if (run) |r| {
                        try self.appendPart(&parts, &prev_end, r[0], r[1]);
                        run = null;
                    }
                    try self.appendPart(&parts, &prev_end, token.loc.start, token.loc.end);
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

    fn parseInclude(self: *Parser) Error!Node {
        // Lets consume "include"
        _ = self.t.next();
        while (true) {
            const next = self.t.peek();
            switch (next.tag) {
                .newline => {
                    _ = self.t.next();
                },
                .quoted_string, .multiline_string => {
                    // Check what is after next = URI
                    _ = self.t.next();
                    const peeked = self.t.peek();
                    switch (peeked.tag) {
                        .newline, .comma, .eof, .r_brace, .r_bracket => {},
                        else => return Error.UnexpectedToken,
                    }
                    // Return proper node
                    return Node{
                        .kind = .include,
                        .value = self.t.t.input[next.loc.start..next.loc.end],
                        .children = &[0]Node{},
                    };
                },
                else => return Error.UnexpectedToken,
            }
        }
    }

    fn parseContainer(self: *Parser, ending: Tokenizer.Token.Tag, containerType: Node.NodeKind) Error!Node {
        var objects: std.ArrayList(Node) = .empty;
        // A root that opens with `{` or `[` is the whole document: nothing may
        // come before it and nothing after it. Only root needs this — inside a
        // value `{x=1} {y=2}` concatenates happily.
        var braced_root = false;
        while (true) {
            const token = self.t.peek();
            if (token.tag == ending) break;

            const node: ?Node = switch (token.tag) {
                .newline, .comma => blk: {
                    _ = self.t.next();
                    break :blk null;
                },
                .string, .quoted_string, .multiline_string => blk: {
                    // Inside an array this is an element, so it is a plain value.
                    if (containerType == .array) break :blk try self.parseValue();
                    if (braced_root) return Error.UnexpectedToken;

                    // `include` is a keyword only here, and only unquoted. Seeing
                    // it commits: there is no falling back to a key of that name,
                    // so one token of lookahead is enough.
                    const value = self.t.t.input[token.loc.start..token.loc.end];
                    if (token.tag == .string and std.mem.eql(u8, value, "include")) {
                        break :blk try self.parseInclude();
                    }

                    break :blk try self.parseMember();
                },
                .l_brace => blk: {
                    // A brace where a member begins has no key to attach itself
                    // to .. `{ {a=1} }`. Merging two objects is a *value*, so it
                    // happens in parseValue, not here.
                    if (containerType == .block) return Error.UnexpectedToken;
                    if (containerType == .root) {
                        if (objects.items.len > 0) return Error.UnexpectedToken;
                        braced_root = true;
                    }
                    _ = self.t.next();
                    const val = try self.parseContainer(.r_brace, .block);
                    break :blk val;
                },
                .l_bracket => blk: {
                    if (containerType == .block) return Error.UnexpectedToken;
                    if (containerType == .root) {
                        if (objects.items.len > 0) return Error.UnexpectedToken;
                        braced_root = true;
                    }
                    _ = self.t.next();
                    break :blk try self.parseContainer(.r_bracket, .array);
                },
                .dollar_brace, .dollar_brace_optional => blk: {
                    if (containerType != .array) return Error.UnexpectedToken;
                    break :blk try self.parseValue();
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

/// Builds the member node for `key = value`, expanding a dotted key into the
/// nesting it stands for: `a.b = 1`, `"a"."b" = 1` and `a { b = 1 }` build the
/// same tree on purpose.
/// Stupid part is a) is based on one node holding value="a.b" while
///                b) concat(n("\"a\""),n("."),n("\"b\""))
fn prepareMemberNode(gpa: std.mem.Allocator, key: Node, value: Node) Parser.Error!Node {
    const first = [_]Node{key};
    const parts = if (key.kind == .value) &first else key.children;

    // Build hierarych of keys
    var elements: std.ArrayList([]Node) = .empty;
    defer elements.deinit(gpa);
    var current: std.ArrayList(Node) = .empty;
    defer current.deinit(gpa);

    for (parts) |part| {
        const unquoted = try unquote.unquote(gpa, part.value);
        if (unquoted.quoted) {
            try current.append(gpa, part);
            continue;
        }

        var it = std.mem.splitScalar(u8, part.value, '.');
        const head = it.first();
        if (head.len > 0) try current.append(gpa, .{ .kind = .value, .value = head, .children = &.{} });
        while (it.next()) |seq| {
            try elements.append(gpa, try current.toOwnedSlice(gpa));
            if (seq.len > 0) try current.append(gpa, .{ .kind = .value, .value = seq, .children = &.{} });
        }
    }
    try elements.append(gpa, try current.toOwnedSlice(gpa));

    var return_node: ?Node = null;
    for (0..elements.items.len) |i| {
        const nodes = elements.items[elements.items.len - i - 1];
        if (nodes.len == 0) return Parser.Error.UnexpectedToken;

        const element: Node = if (nodes.len == 1) nodes[0] else .{ .kind = .concat, .children = nodes };
        const inner: Node = if (return_node) |nn|
            .{ .kind = .block, .children = try gpa.dupe(Node, &.{nn}) }
        else
            value;
        return_node = .{ .kind = .assignment, .children = try gpa.dupe(Node, &.{ element, inner }) };
    }
    return return_node orelse Parser.Error.UnexpectedToken;
}

/// Whether `node` is the text a path expression is made of. The inside of
/// `${…}` is a path, so a block, an array or a nested substitution in there is
/// an error — java rejects all three with `BadPath`.
fn isPathText(node: Node) bool {
    return switch (node.kind) {
        .value => true,
        .concat => for (node.children) |child| {
            if (!isPathText(child)) break false;
        } else true,
        else => false,
    };
}

/// Renders `node` as a one-line s-expression, e.g. `root(assign(value(a), value(b)))`.
/// Leaf text is `node.value` verbatim, so quotes are kept: `a = "b"` dumps as
/// `value("b")`.
fn dumpNode(node: Node, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (node.kind) {
        // Containers all render the same way: kind(child, child, …). An
        // assignment is one too — children[0] is the key, children[1] the value.
        .root, .block, .array, .assignment, .concat, .subst, .subst_optional => {
            try w.writeAll(switch (node.kind) {
                .root => "root(",
                .block => "block(",
                .array => "array(",
                .concat => "concat(",
                .subst => "subst(",
                .subst_optional => "subst?(",
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

/// Builds the `table.Options.dump` for one entry point into the parser, so a
/// table can be run through `parse` or through `parseText` alone.
fn dumper(comptime parseFn: fn (*Parser) Parser.Error!Node) *const fn (std.mem.Allocator, [:0]const u8) anyerror![]u8 {
    return &struct {
        fn dump(gpa: std.mem.Allocator, in: [:0]const u8) anyerror![]u8 {
            var p = Parser{ .gpa = gpa, .t = .{ .t = Tokenizer.Tokenizer.init(in) } };
            const tree = try parseFn(&p);

            var aw = std.Io.Writer.Allocating.init(gpa);
            try dumpNode(tree, &aw.writer);
            return aw.toOwnedSlice();
        }
    }.dump;
}

/// Runs a table of cases through the whole parser. See `table.expectAll` for
/// what the report looks like and what `.only` does.
fn expectAll(cases: []const Case) !void {
    return table.expectAll(cases, .{ .dump = dumper(Parser.parse) });
}

/// The same table, run through `parseText` instead of the whole parser — for the
/// rows that are about how text splits into parts, with no document around them.
fn expectAllText(cases: []const Case) !void {
    return table.expectAll(cases, .{ .dump = dumper(Parser.parseText) });
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
    try expectAllText(&.{
        .ok("x", "value(x)"),
        .ok("\"x\"", "value(\"x\")"),
        .ok("grumpy wombat", "value(grumpy wombat)"),

        // Trailing whitespace is not part of the value.
        .ok("x  ", "value(x)"),

        // A quoted part with nothing after it — the pending run must not be left
        // half-open, or the terminator branch reads an end that was never set.
        .ok("x \"y\"", "concat(value(x), value( ), value(\"y\"))"),
        .ok("\"x\" y", "concat(value(\"x\"), value( ), value(y))"),

        .ok("\"a\"\"b\"", "concat(value(\"a\"), value(\"b\"))"),
        .ok("\"a\" \"b\"", "concat(value(\"a\"), value( ), value(\"b\"))"),
        .ok("x\"y\"", "concat(value(x), value(\"y\"))"),

        // Bigger examples
        .ok("grumpy wombat {additional = true}", "value(grumpy wombat)"),
        .ok(
            "grumpy wombat    \"caffeinated but polite\"   send help",
            "concat(value(grumpy wombat), value(    ), value(\"caffeinated but polite\"), value(   ), value(send help))",
        ),
        .ok(
            "grumpy wombat    \"caffeinated but polite\"   send help    ",
            "concat(value(grumpy wombat), value(    ), value(\"caffeinated but polite\"), value(   ), value(send help))",
        ),
    });
}

// java ✓ · pyhocon ✓ · spec ✓ — all six inputs agree on both oracles.
// `:` and `=` are interchangeable; `,` and newline are interchangeable separators.
test "assignment with =" {
    try expectAll(&.{
        .ok("a = b", "root(assign(value(a), value(b)))"),
        .ok("a: b", "root(assign(value(a), value(b)))"),
        .ok("a = b\nc: d", "root(assign(value(a), value(b)), assign(value(c), value(d)))"),
        .ok("{a = b}", "root(block(assign(value(a), value(b))))"),
        .ok("{a = b\nc: d}", "root(block(assign(value(a), value(b)), assign(value(c), value(d))))"),
        .ok("{a = b, c: d}", "root(block(assign(value(a), value(b)), assign(value(c), value(d))))"),
    });
}

// java ✓ · pyhocon ✓ · spec ✓ — all seven inputs agree on both oracles,
// including the empty block (`a = {}` -> {"a":{}}).
test "nested blocks" {
    try expectAll(&.{
        .ok("a = {b = c}", "root(assign(value(a), block(assign(value(b), value(c)))))"),
        .ok("a: {c: d}", "root(assign(value(a), block(assign(value(c), value(d)))))"),
        .ok("a = {}", "root(assign(value(a), block()))"),
        .ok("a = {b = {c = d}}", "root(assign(value(a), block(assign(value(b), block(assign(value(c), value(d)))))))"),
        .ok("a = {b = c}\nd = e", "root(assign(value(a), block(assign(value(b), value(c)))), assign(value(d), value(e)))"),
        .ok("a = {b = c, d = e}", "root(assign(value(a), block(assign(value(b), value(c)), assign(value(d), value(e)))))"),
        .ok("{a = {b = c}}", "root(block(assign(value(a), block(assign(value(b), value(c))))))"),
    });
}

// java ✓ · pyhocon ✓ · spec ✓ — both `#` and `//` start a comment, a comment
// terminates the value on its line, and runs of blank lines collapse.
test "separators and comments are not nodes" {
    try expectAll(&.{
        .ok("", "root()"),
        .ok("\na = b\n", "root(assign(value(a), value(b)))"),
        .ok("a = b\n\nc = d", "root(assign(value(a), value(b)), assign(value(c), value(d)))"),
        .ok("# comment\na = b", "root(assign(value(a), value(b)))"),
        .ok("// comment\na = b", "root(assign(value(a), value(b)))"),
        .ok("a = b # comment\nc = d", "root(assign(value(a), value(b)), assign(value(c), value(d)))"),
    });
}

// java ✓ · pyhocon ✓ · spec ✓ — unquoted strings may contain spaces on both
// sides of the assignment; interior whitespace is kept verbatim, the trailing
// run is dropped.
//   'a = grumpy   wombat' -> {"a":"grumpy   wombat"}
//   'a b = c'           -> {"a b":"c"}
// Careful: a tab is NOT the same case — java keeps `a = b\tc` as "b\tc", pyhocon
// expands it to spaces. Follow java when that test gets written.
test "multi-word keys and values" {
    try expectAll(&.{
        .ok("a = grumpy wombat", "root(assign(value(a), value(grumpy wombat)))"),
        .ok("a = grumpy   wombat", "root(assign(value(a), value(grumpy   wombat)))"),
        .ok("a b = c", "root(assign(value(a b), value(c)))"),
    });
}

// java ✓ · pyhocon ✓ · spec ✓ — 'a {b = c}' -> {"a":{"b":"c"}} on both oracles.
test "the = before a block may be omitted" {
    try expectAll(&.{
        .ok("a {b = c}", "root(assign(value(a), block(assign(value(b), value(c)))))"),
    });
}

// java ✓ · pyhocon ✓ · spec ✓ — all eleven inputs agree on both oracles.
//
// An array node holds its elements directly, with no `assign` in between — that
// is the whole difference from a block: `parseContainer` collects members, an
// array collects values. Separators are the same (`,` and newline, runs collapse,
// a trailing one is allowed), and an element may itself be an array or a block.
test "arrays" {
    try expectAll(&.{
        .ok("a = []", "root(assign(value(a), array()))"),
        .ok("a = [1]", "root(assign(value(a), array(value(1))))"),
        .ok("a = [1, 2]", "root(assign(value(a), array(value(1), value(2))))"),
        .ok("a = [1, 2,]", "root(assign(value(a), array(value(1), value(2))))"),
        .ok("a = [\n1\n2\n]", "root(assign(value(a), array(value(1), value(2))))"),
        .ok("a = [grumpy wombat]", "root(assign(value(a), array(value(grumpy wombat))))"),
        .ok("a = [[1], [2]]", "root(assign(value(a), array(array(value(1)), array(value(2)))))"),
        .ok("a = [1, [2, [3]]]", "root(assign(value(a), array(value(1), array(value(2), array(value(3))))))"),
        .ok("a = [{b = c}]", "root(assign(value(a), array(block(assign(value(b), value(c))))))"),
        .ok("a = [{b = c}, {d = e}]", "root(assign(value(a), array(block(assign(value(b), value(c))), block(assign(value(d), value(e))))))"),
        .ok("a = {b = [1, 2]}", "root(assign(value(a), block(assign(value(b), array(value(1), value(2))))))"),
    });
}

// java ✓ · pyhocon ✓ · spec ✓ — both oracles parse it; they disagree only on
// whether the *document* is valid, which is exactly the point. An array as the
// whole document parses. Java rejects it as
// `WrongType: has type LIST rather than object at file root` — a type error, not
// a parse error — so the tree is well-formed and the rejection belongs to a
// later phase. Kept out of "arrays" because it is about the document root
// rather than about array syntax.
test "arrays.a root array is a valid tree" {
    try expectAll(&.{
        .ok("[1, 2]", "root(array(value(1), value(2)))"),
    });
}

// java ✓ · pyhocon ⚠️ · spec ✓ — every input below was run through both oracles.
// Twelve of seventeen agree; pyhocon diverges on five, and follows java on none
// of them:
//
//   'a = include "x"'     java {"a":"include x"}    pyhocon ERROR
//   'a = [include "x"]'   java {"a":["include x"]}  pyhocon {"a":[]}
//   'include = 42'        java ERROR                pyhocon {"include":42}
//   'Include "x.conf"'    java ERROR                pyhocon includes the file
//   'INCLUDE "x.conf"'    java ERROR                pyhocon includes the file
//
// The second one is the reason to care: pyhocon treats `include` as a keyword on
// the value side too, fails to find the file, and returns an empty array instead
// of an error. Silent data loss, no warning on stdout. Java is followed here.
//
// `include = 42` is the one arguable case. Java rejects it, pyhocon accepts it as
// an ordinary key, and by the leniency rule in tools/oracle/README.md ("where java
// is stricter, stay lenient") that would make pyhocon the target. Java is followed
// anyway: staying lenient means giving up the commit below and reintroducing
// backtracking, which is a lot of parser to pay for a config with a field called
// `include`. A deliberate exception, not an oversight.
//
// `include` is a keyword in exactly one position — where a member of an object
// begins — and only unquoted. Everywhere else it is an ordinary unquoted string:
//   'a = include "x"'   -> {"a":"include x"}
//   'a = [include "x"]' -> {"a":["include x"]}
//   '"include" = 42'    -> {"include":42}
//
// That means no second token of lookahead is needed. Java does not fall back to
// treating `include` as a key when what follows is wrong ('include = 42' is a
// parse error, not {"include":42}), so seeing the keyword is a commitment: the
// next token must be a quoted string or the input is invalid.
//
// The quotes are kept in the node, same as everywhere else in the tree — a part
// is exactly the text of its token, and include targets are no exception.
//
// Only the plain quoted form here. `file()`, `url()`, `classpath()` and
// `required()` are variants of the same shape and are deliberately left out for
// now; the tokenizer has no rule for `(` yet.
test "include.happy path" {
    try expectAll(&.{
        .ok("include \"a.conf\"", "root(include(\"a.conf\"))"),
        // No space is required after the keyword.
        .ok("include\"a.conf\"", "root(include(\"a.conf\"))"),
        .ok("include\n\n\"a.conf\"", "root(include(\"a.conf\"))"),
        .ok("include \"a.conf\"\na = b", "root(include(\"a.conf\"), assign(value(a), value(b)))"),
        .ok("include \"a.conf\", a = b", "root(include(\"a.conf\"), assign(value(a), value(b)))"),
        .ok("a = b\ninclude \"a.conf\"", "root(assign(value(a), value(b)), include(\"a.conf\"))"),

        // An include is a member, so it appears wherever members do.
        .ok("a { include \"a.conf\" }", "root(assign(value(a), block(include(\"a.conf\"))))"),
        .ok("{include \"a.conf\"}", "root(block(include(\"a.conf\")))"),

        // Not a keyword on the value side, nor inside an array: plain text there,
        // and the existing concatenation rules apply unchanged.
        .ok("a = include \"x\"", "root(assign(value(a), concat(value(include), value( ), value(\"x\"))))"),
        .ok("a = [include \"x\"]", "root(assign(value(a), array(concat(value(include), value( ), value(\"x\")))))"),

        // With an unquoted argument it is not even a concatenation: `include foo`
        // is one run of adjacent unquoted strings, so it stays a single part.
        // This is the shape a leftover check in `parseText` used to reject.
        .ok("a = include foo", "root(assign(value(a), value(include foo)))"),
        .ok("a = [include foo]", "root(assign(value(a), array(value(include foo))))"),
        .ok("a = include", "root(assign(value(a), value(include)))"),
        .ok("foo = include bar baz", "root(assign(value(foo), value(include bar baz)))"),

        // Not a keyword when quoted — then it is just a key like any other.
        .ok("\"include\" = 42", "root(assign(value(\"include\"), value(42)))"),

        // A key that merely starts with the word is untouched, since the
        // tokenizer hands over `includes` as one token.
        .ok("includes = 1", "root(assign(value(includes), value(1)))"),
    });
}

// java ✓ · pyhocon ⚠️ · spec ✓ — the keyword commits, so anything but a quoted
// string after it is an error rather than a fallback to an ordinary key. Java is
// the reference throughout; pyhocon accepts three of these six (`include = 42`
// as an ordinary key, and both `Include`/`INCLUDE` as the keyword, since it
// matches case-insensitively). The spec spells the keyword lowercase.
//
// Known divergence, accepted for now: java also rejects 'include "a.conf" b = c',
// because members must be separated. Nothing here separates members yet, so we
// accept it. Worth revisiting when separators get tightened up.
// Five of the six are not really about `include` at all: they end up as a bare
// value where a member belongs, so the member rule below rejects them. Only
// `include = 42` needs the keyword itself to commit.
test "include.bad argument" {
    try expectAll(&.{
        .bad("include"),
        .bad("include nope"),
        // Exactly one argument — no concatenation, unlike a value.
        .bad("include \"a.conf\" \"b.conf\""),
        // Case-sensitive.
        .bad("Include \"a.conf\""),
        .bad("INCLUDE \"a.conf\""),
    });
}

// Parked rather than commented out: `if (true) return error.SkipZigTest` leaves
// the body compiling, so it cannot rot when something around it is renamed, and
// `tools/zt` lists it as a todo instead of it silently vanishing from the run.
//
// The keyword commits — it is recognised from the first token where a member
// begins, in `parseContainer`, rather than matched against the parts afterwards.
// That is the whole reason this is an error instead of assign(value(include),
// value(42)): once `parseInclude` has been entered there is no way back out.
test "include.keyword commits" {
    try expectAll(&.{
        .bad("include = 42"),
    });
}

// java ✓ · pyhocon ✓ · spec ✓ — all nine inputs agree on both oracles.
//
// A member of an object is an assignment or an include; a bare value is a key
// with nothing after it.
//   'a'            -> ERROR ... may not be followed by token: end of file
//   'a = b\n{c=d}' -> ERROR       a bare block is not a member
//   '{ {a=1} }'    -> ERROR       nor is it one inside another object
// The one place a bare block is legal is as the whole document: '{a=1}' -> {"a":1}.
//
// '[1,2]' looks like it belongs here but does not: java reports `WrongType: has
// type LIST rather than object at file root`, a type error rather than a parse
// error, so the tree is fine and only the document is wrong. It is asserted as
// a tree in "arrays" instead.
test "member.a bare value is not a member" {
    try expectAll(&.{
        .bad("a"),
        .bad("a b"),
        .bad("\"a\""),
        .bad("a = b\nc"),
        .bad("{a = b\nc}"),
        .bad("a = b\n{c=d}"),
        .bad("{ {a=1} }"),

        // Still fine: the braced root, and values inside an array.
        .ok("{a = b}", "root(block(assign(value(a), value(b))))"),
        .ok("a = [b, c]", "root(assign(value(a), array(value(b), value(c))))"),
    });
}

// java ✓ · pyhocon ✓ · spec ✓ — all seven inputs agree on both oracles; pyhocon
// says "Expected end of text" where java says "Document has trailing tokens".
//
// When a document opens with `{` or `[`, that one value IS the
// document. Nothing may follow it — not another member, not a concatenation, not
// even on the same line:
//   '{a = b}\n{c = d}' -> ERROR Document has trailing tokens after first object or array
//   '{a = b} {c = d}'  -> ERROR       same, so concatenation is out too
//   '[1] [2]'          -> ERROR
//   '[1, 2]\n[3]'      -> ERROR
//
// This is the only rule where root differs from a block: inside a value,
// 'a = {x:5} {y:6}' concatenates happily (see "nested blocks"). Root has no
// implicit braces around it once an explicit one has opened.
//
// Parked: needs `parseContainer` to know that a root which started with a
// brace or a bracket is finished after one member.
test "member.a braced root is the whole document" {
    try expectAll(&.{
        .bad("{a = b}\n{c = d}"),
        .bad("{a = b} {c = d}"),
        .bad("[1] [2]"),
        .bad("[1, 2]\n[3]"),
        .bad("{a = 1}\nb = 2"),
        .bad("a = b\n{c = d}"),

        // A trailing newline is not "something after it": '{a = 1}\n' -> {"a":1}.
        .ok("{a = 1}\n", "root(block(assign(value(a), value(1))))"),
    });
}

// java ✓ · pyhocon ✓ · spec ✓ — all ten inputs agree on both oracles.
//
// A newline separates members, but it does NOT end a member that is not finished
// yet. While the parser is waiting for a separator or for a value, newlines are
// skipped and the thing it was waiting for is still required:
//
//   'a\n\n= b'     -> {"a":"b"}       any number of them, before the separator
//   'a b\n= c'     -> {"a b":"c"}     multi-word key, same thing
//   'a =\n\n b'    -> {"a":"b"}       and before the value
//   'a\nb = c'     -> ERROR  Key 'a' may not be followed by token: 'b'
//   'a = b\nc'     -> ERROR  Key 'c' may not be followed by token: end of file
//
// That third error message is the tell: java did not treat `a` as complete at the
// end of the line, it kept reading and complained about `b`. Once the member IS
// complete the newline ends it as usual, which is why 'a = b\nc = d' stays two
// members.
//
// Inside `[ ]` and `{ }` this already works, because those swallow newlines
// explicitly. The gap is everywhere else.
//
// `include\n"a.conf"` is the same rule and not a special case: after the keyword
// the parser is waiting for an argument, so newlines are skipped there too.
//
// Parked: this is its own piece of work — two places need "skip newlines, then
// require what was expected" — rather than something to fold into another change.
test "member.newline does not end an unfinished member" {
    // if (true) return error.SkipZigTest;
    try expectAll(&.{
        .ok("a =\nb", "root(assign(value(a), value(b)))"),
        .ok("a\n= b", "root(assign(value(a), value(b)))"),
        .ok("a\n\n= b", "root(assign(value(a), value(b)))"),
        .ok("a = \n\n b", "root(assign(value(a), value(b)))"),
        .ok("a b\n= c", "root(assign(value(a b), value(c)))"),
        .ok("include\n\"a.conf\"", "root(include(\"a.conf\"))"),

        // A complete member still ends at the newline.
        .ok("a = b\nc = d", "root(assign(value(a), value(b)), assign(value(c), value(d)))"),

        // And an unfinished one that is never finished is still an error.
        .bad("a\nb = c"),
        .bad("a = b\nc"),
        .bad("a = b c\n= d"),
    });
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
    try expectAll(&.{
        .ok("a = \"b\"", "root(assign(value(a), value(\"b\")))"),
    });
}

// java ✓ · pyhocon ✓ · spec ✓ — a triple-quoted string is a text part, nothing
// more, and java takes it everywhere a quoted one goes:
//
//   'a = """x"""'       -> {"a":"x"}       '"""a""" = 1'    -> {"a":1}
//   'a = """x""" y'     -> {"a":"x y"}     'a = x """y"""'  -> {"a":"x y"}
//   'a = """x"""${b}'   -> {"a":"x"${b}}   'a = ["""x"""]'  -> {"a":["x"]}
//   'include """inc.conf"""'               -> spliced, same as the quoted form
//   'a = """x"""\n"""y"""'                 -> ERROR, a newline still ends a value
//
// The tree keeps the `"""` for the same reason it keeps `"`, and here the stakes
// are higher than telling `"1"` from `1` — the two forms treat escapes
// differently, and only the delimiter says which is which:
//
//   'a = """a\\nb"""' -> {"a":"a\\nb"}   backslash-n, two characters
//   'a = "a\\nb"'     -> {"a":"a\nb"}    a newline
test "multiline string is an ordinary text part" {
    try expectAll(&.{
        .ok("a = \"\"\"m\"\"\"", "root(assign(value(a), value(\"\"\"m\"\"\")))"),
        .ok("\"\"\"a\"\"\" = 1", "root(assign(value(\"\"\"a\"\"\"), value(1)))"),
        .ok("a = [\"\"\"m\"\"\"]", "root(assign(value(a), array(value(\"\"\"m\"\"\"))))"),
        .ok("a = {b = \"\"\"m\"\"\"}", "root(assign(value(a), block(assign(value(b), value(\"\"\"m\"\"\")))))"),

        // Newlines inside belong to the string, not to the document.
        .ok("a = \"\"\"x\ny\"\"\"", "root(assign(value(a), value(\"\"\"x\ny\"\"\")))"),
        // Between two of them it still ends the value, so the second one starts
        // a member with no separator.
        .bad("a = \"\"\"x\"\"\"\n\"\"\"y\"\"\""),

        // Concatenation, both directions, with the gap in between.
        .ok("a = \"\"\"x\"\"\" y", "root(assign(value(a), concat(value(\"\"\"x\"\"\"), value( ), value(y))))"),
        .ok("a = x \"\"\"y\"\"\"", "root(assign(value(a), concat(value(x), value( ), value(\"\"\"y\"\"\"))))"),
        .ok("a = \"\"\"x\"\"\"${b}", "root(assign(value(a), concat(value(\"\"\"x\"\"\"), subst(value(b)))))"),

        // An include path may be triple-quoted too.
        .ok("include \"\"\"inc.conf\"\"\"", "root(include(\"\"\"inc.conf\"\"\"))"),
    });
}

// java ✓ · pyhocon ⚠️ · spec ✓ — every input below through both oracles. Twelve
// of eighteen agree; pyhocon diverges on six, all malformed paths, and every
// time in the losing direction — it drops the empty element instead of saying
// anything.
//
//   input             java                       pyhocon
//   a.b = 1           {"a":{"b":1}}              same
//   a.b.c = 1         {"a":{"b":{"c":1}}}        same
//   a.b.c.d = 1       {"a":{"b":{"c":{"d":1}}}}  same
//   a {b = 1}         {"a":{"b":1}}              same
//   a.b {c = 1}       {"a":{"b":{"c":1}}}        same
//   1.5 = x           {"1":{"5":"x"}}            same
//   a. b = 1          {"a":{" b":1}}             same
//   a .b = 1          {"a ":{"b":1}}             same
//   "a.b" = 1         {"a.b":1}                  same
//   a = b.c           {"a":"b.c"}                same
//   a.b = 1\na.c = 2  {"a":{"b":1,"c":2}}        same
//   .. = 1            ERROR BadPath              ERROR
//   .a = 1            ERROR BadPath              {"a":1}
//   a. = 1            ERROR BadPath              {"a":1}
//   a..b = 1          ERROR BadPath              {"a":{"b":1}}
//   ..a = 1           ERROR BadPath              {"a":1}
//   a..b.c = 1        ERROR BadPath              {"a":{"b":{"c":1}}}
//   a.b..c = 1        ERROR BadPath              {"a":{"b":{"c":1}}}
//
// Java is followed. The leniency rule in tools/oracle/README.md ("where java is
// stricter, stay lenient") does not apply here: java's own message points at the
// fix ('use quoted "" empty string if you want an empty element'), so accepting
// the input silently would be guessing at what an empty path element meant.
//
// A key is a *path*: elements separated by `.`. Splitting it belongs here rather
// than to evaluation, because the only thing carrying the difference between
// `a."b.c"` and `a.b.c` is which dots were quoted — and evaluation, which joins
// the parts into text, no longer has that. Same litmus test as everywhere else.
//
// The shape is the one `a {b = 1}` already produces, deliberately: the two spell
// the same thing, so they should build the same tree. Evaluation then merges
// 'a.b = 1' with 'a {c = 2}' without knowing they were written differently.
//
// Two rows need no code of their own. Adjacent unquoted strings are one
// contiguous slice of the input, interior whitespace included, so 'a. b' really
// is the text `a. b` and splitting it on the dot yields `a` and ` b` — which is
// exactly what java reports.
//
// The four rows with an empty element away from the last dot ('..a', 'a..b.c',
// 'a.b..c', '..') are the ones worth keeping: an implementation that peels one
// element off the right and only checks that one would accept all four.
test "key.a dotted key is a path" {
    try expectAll(&.{
        .ok("a.b = 1", "root(assign(value(a), block(assign(value(b), value(1)))))"),
        .ok("a.b.c = 1", "root(assign(value(a), block(assign(value(b), block(assign(value(c), value(1)))))))"),

        // The point of the shape: these two must dump identically.
        .ok("a {b = 1}", "root(assign(value(a), block(assign(value(b), value(1)))))"),
        .ok("a.b {c = 1}", "root(assign(value(a), block(assign(value(b), block(assign(value(c), value(1)))))))"),

        // A number is just an unquoted string, so it splits like any other key.
        .ok("1.5 = x", "root(assign(value(1), block(assign(value(5), value(x)))))"),

        // Whitespace around a dot belongs to the element it touches.
        .ok("a. b = 1", "root(assign(value(a), block(assign(value( b), value(1)))))"),
        .ok("a .b = 1", "root(assign(value(a ), block(assign(value(b), value(1)))))"),

        // Quoted: one element, not split.
        .ok("\"a.b\" = 1", "root(assign(value(\"a.b\"), value(1)))"),

        // Only keys are paths — a dot in a value is ordinary text.
        .ok("a = b.c", "root(assign(value(a), value(b.c)))"),

        // An empty element is a BadPath in java, whichever end it is on.
        .bad(".a = 1"),
        .bad("a. = 1"),
        .bad("a..b = 1"),

        // An empty element anywhere, not just next to the last dot — the check
        // has to reach every element, not only the one being peeled off.
        .bad("..a = 1"),
        .bad("a..b.c = 1"),
        .bad("a.b..c = 1"),
        .bad(".. = 1"),

        // Depth is not special-cased.
        .ok(
            "a.b.c.d = 1",
            "root(assign(value(a), block(assign(value(b), block(assign(value(c), block(assign(value(d), value(1)))))))))",
        ),

        // Two paths sharing a prefix stay two members side by side. Merging them
        // into {"a":{"b":1,"c":2}} is evaluation, not the parser.
        .ok(
            "a.b = 1\na.c = 2",
            "root(assign(value(a), block(assign(value(b), value(1)))), assign(value(a), block(assign(value(c), value(2)))))",
        ),
    });
}

// java ✓ · pyhocon ⚠️ · spec ✓ — every row through both oracles; pyhocon rejects
// any key with a quoted part outright (see tools/oracle/README.md), java takes
// them all:
//
//   input                 java
//   "a"."b" = 1           {"a":{"b":1}}
//   "a".b = 1             {"a":{"b":1}}
//   a."b.c" = 1           {"a":{"b.c":1}}
//   a."b".c = 1           {"a":{"b":{"c":1}}}
//   "a.b".c = 1           {"a.b":{"c":1}}
//   """a.b""".c = 1       {"a.b":{"c":1}}
//   a.".".b = 1           {"a":{".":{"b":1}}}
//   a."" = 1              {"a":{"":1}}
//   "".a = 1              {"":{"a":1}}
//   a"b".c = 1            {"ab":{"c":1}}
//   a."b c" d = 1         {"a":{"b c d":1}}
//   "a" . "b" = 1         {"a ":{" b":1}}
//   "a"."b" { c = 1 }     {"a":{"b":{"c":1}}}
//   a."b.c" = 1\na.b.c = 2  {"a":{"b":{"c":2},"b.c":1}}
//   "a". = 1              ERROR BadPath
//   ."a" = 1              ERROR BadPath
//   "a"..b = 1            ERROR BadPath
//
// One splitter for both spellings of a key. It walks the parts `parseText`
// left rather than the joined text: a dot inside an unquoted part ends an
// element, a dot inside a quoted part is a character, and the boundary between
// two parts means nothing — so `a"b".c` has two elements, the first made of
// two parts. That is the same rule `${…}` already follows in Value.zig, and it
// is why the quotes stay on the leaves here: the tree still has to tell
// `"a.b"` from `a.b` one level down.
//
// An element made of one part is a `value`, of several a `concat`, exactly as
// a whole key was before — so `a "b c" d` (no dot) dumps as it always did.
test "key.a multi-part key is a path too" {
    try expectAll(&.{
        // The dot alone between two quoted parts.
        .ok("\"a\".\"b\" = 1", "root(assign(value(\"a\"), block(assign(value(\"b\"), value(1)))))"),
        .ok("\"a\".b = 1", "root(assign(value(\"a\"), block(assign(value(b), value(1)))))"),

        // A quoted dot is a character of its element.
        .ok("a.\"b.c\" = 1", "root(assign(value(a), block(assign(value(\"b.c\"), value(1)))))"),
        .ok("a.\"b\".c = 1", "root(assign(value(a), block(assign(value(\"b\"), block(assign(value(c), value(1)))))))"),
        .ok("\"a.b\".c = 1", "root(assign(value(\"a.b\"), block(assign(value(c), value(1)))))"),
        .ok("\"\"\"a.b\"\"\".c = 1", "root(assign(value(\"\"\"a.b\"\"\"), block(assign(value(c), value(1)))))"),
        .ok("a.\".\".b = 1", "root(assign(value(a), block(assign(value(\".\"), block(assign(value(b), value(1)))))))"),

        // An empty element is legal when it is written as `""`.
        .ok("a.\"\" = 1", "root(assign(value(a), block(assign(value(\"\"), value(1)))))"),
        .ok("\"\".a = 1", "root(assign(value(\"\"), block(assign(value(a), value(1)))))"),

        // A part boundary is not an element boundary: only a dot is.
        .ok("a\"b\".c = 1", "root(assign(concat(value(a), value(\"b\")), block(assign(value(c), value(1)))))"),
        .ok("a.\"b c\" d = 1", "root(assign(value(a), block(assign(concat(value(\"b c\"), value( ), value(d)), value(1)))))"),

        // Whitespace around a dot belongs to the element it touches, as in
        // `a .b` — here it arrives as gap parts and stays with them.
        .ok("\"a\" . \"b\" = 1", "root(assign(concat(value(\"a\"), value( )), block(assign(concat(value( ), value(\"b\")), value(1)))))"),

        // No dot anywhere: one element, the concat it always was.
        .ok("a \"b c\" d = f", "root(assign(concat(value(a), value( ), value(\"b c\"), value( ), value(d)), value(f)))"),

        // The value side is untouched by the split.
        .ok("\"a\".\"b\" { c = 1 }", "root(assign(value(\"a\"), block(assign(value(\"b\"), block(assign(value(c), value(1)))))))"),

        // Two spellings, two members side by side; that they name different
        // keys is for evaluation to find out.
        .ok(
            "a.\"b.c\" = 1\na.b.c = 2",
            "root(assign(value(a), block(assign(value(\"b.c\"), value(1)))), assign(value(a), block(assign(value(b), block(assign(value(c), value(2)))))))",
        ),

        // An unquoted empty element is a BadPath here too, whichever side of
        // the quotes it falls on.
        .bad("\"a\". = 1"),
        .bad(".\"a\" = 1"),
        .bad("\"a\"..b = 1"),
    });
}

// java ✓ · pyhocon ✓ · spec ✓ — the oracle prints substitutions unresolved, so
// these are read off java directly:
//
//   'a = ${b}'    -> {"a":${b}}        'a = ${?b}'   -> {"a":${?b}}
//   'a = ${a.b}'  -> {"a":${a.b}}      'a = ${ a }'  -> {"a":${a}}
//   'a = ${a b}'  -> {"a":${"a b"}}    'a = ${a"b"}' -> {"a":${ab}}
//   'a = {x:${b}}'-> {"a":{"x":${b}}}  'a = [${b}]'  -> {"a":[${b}]}
//
// pyhocon can only be asked with `resolve:`, its oracle being unable to print an
// unresolved substitution, and agrees wherever it can answer:
// 'resolve:b=1\na = ${b}c' -> {"a":"1c"} on both.
//
// The inside of `${…}` is a *path expression* — the same thing a key is — so it
// is `parseText` followed by a required `}`, and nothing more. Everything java
// rejects falls out of that one sentence rather than needing a rule of its own:
// `${}` has no parts, `${a` and `${a#c}` (the comment eats the brace) never
// reach one, `${a\nb}` stops at the newline, and `${${a}}` stops at a token that
// is not text.
//
// The path is NOT split on `.` yet: `${a.b}` keeps the whole text. Nothing is
// lost by waiting — `${a."b.c"}` and `${a.b.c}` already dump differently — and
// splitting wants doing once, for keys and substitutions together, which is why
// `${.a}` and `${a..b}` are still accepted here where java says BadPath. See
// tools/oracle/README.md.
test "substitution" {
    try expectAll(&.{
        .ok("a = ${b}", "root(assign(value(a), subst(value(b))))"),
        .ok("a = ${?b}", "root(assign(value(a), subst?(value(b))))"),
        .ok("a = ${? b}", "root(assign(value(a), subst?(value(b))))"),

        // Whitespace around the path is not part of it; whitespace inside is.
        .ok("a = ${ a }", "root(assign(value(a), subst(value(a))))"),
        .ok("a = ${a b}", "root(assign(value(a), subst(value(a b))))"),

        // A path expression, so the same shapes a key can have.
        .ok("a = ${a.b}", "root(assign(value(a), subst(value(a.b))))"),
        .ok("a = ${\"a.b\"}", "root(assign(value(a), subst(value(\"a.b\"))))"),
        .ok("a = ${a\"b\"}", "root(assign(value(a), subst(concat(value(a), value(\"b\")))))"),

        // Nowhere but a value: not a key, not an include target, not text.
        .bad("${a} = 1"),
        .bad("a${b} = 1"),
        .bad("include ${a}"),
        .ok("a = \"${b}\"", "root(assign(value(a), value(\"${b}\")))"),

        // `$` exists only as the start of `${`.
        .bad("a = $b"),
        .bad("a = b$c"),
        .bad("a = $"),

        // Every one of these is a java error, and all of them for the same
        // reason: `parseText` then `}`.
        .bad("a = ${}"),
        .bad("a = ${ }"),
        .bad("a = ${?}"),
        .bad("a = ${a"),
        .bad("a = ${a#c}"),
        .bad("a = ${a\nb}"),
        .bad("a = ${${a}}"),
        .bad("a = ${a${b}}"),
        // `?` is a reserved character anywhere but directly after `${`.
        .bad("a = ${ ?a}"),
        .bad("a = ${a?}"),
    });
}

// java ✓ · pyhocon ✓ · spec ✓ — a substitution is one part among others, so the
// concatenation rules that already exist apply unchanged:
//
//   'a = ${b}c'      -> {"a":${b}"c"}       'a = c${b}'   -> {"a":"c"${b}}
//   'a = ${b}${c}'   -> {"a":${b}${c}}      'a = ${b} [1]'-> {"a":${b}[1]}
//   'a = ${b} ${c}'  -> {"a":${b}" "${c}}   'a = [1] ${b}'-> {"a":[1]${b}}
//
// The gap rows are the point of this group. `${b} ${c}` and `${b}${c}` resolve
// to different strings ("1 2" against "12"), so the whitespace between two parts
// carries meaning and the tree has to keep it — which is why the gap part is
// emitted between *any* two parts now, not only between text ones.
//
// Java drops the gap next to an object or a list ('${b} [1]' -> `${b}[1]`),
// since nothing can concatenate as text there. We keep it, because dropping it
// is a decision about what the parts mean — evaluation skips whitespace parts
// when it merges objects or concatenates lists.
test "substitution.is an ordinary part of a value" {
    try expectAll(&.{
        .ok("a = ${b}c", "root(assign(value(a), concat(subst(value(b)), value(c))))"),
        .ok("a = c${b}", "root(assign(value(a), concat(value(c), subst(value(b)))))"),
        .ok("a = ${b}${c}", "root(assign(value(a), concat(subst(value(b)), subst(value(c)))))"),
        .ok("a = ${b} ${c}", "root(assign(value(a), concat(subst(value(b)), value( ), subst(value(c)))))"),
        .ok("a = ${b} c", "root(assign(value(a), concat(subst(value(b)), value( ), value(c))))"),
        .ok("a = ${a}${?b}", "root(assign(value(a), concat(subst(value(a)), subst?(value(b)))))"),

        // A comment ends the value, exactly as it does without a substitution.
        .ok("a = ${a} # c", "root(assign(value(a), subst(value(a))))"),

        // Inside the containers, and next to them.
        .ok("a = [${b}]", "root(assign(value(a), array(subst(value(b)))))"),
        .ok("a = [${b}, ${c}]", "root(assign(value(a), array(subst(value(b)), subst(value(c)))))"),
        .ok("a = {x:${b}}", "root(assign(value(a), block(assign(value(x), subst(value(b))))))"),
        .ok("a = ${b}[1]", "root(assign(value(a), concat(subst(value(b)), array(value(1)))))"),
        .ok("a = [1] ${b}", "root(assign(value(a), concat(array(value(1)), value( ), subst(value(b)))))"),
        .ok("a = {x:1} ${b}", "root(assign(value(a), concat(block(assign(value(x), value(1))), value( ), subst(value(b)))))"),

        // A newline still ends the value: `a = ${b}\n${c}` is two members, and
        // the second one has no separator. (java: same error.)
        .bad("a = ${b}\n${c}"),
    });
}

// java ✓ · pyhocon ✓ · spec ✓ — the gap between two parts is a part of its own
// wherever the parts are, not only inside `parseText`:
//   'a = {x:5} {y:6}' -> {"a":{"x":5,"y":6}}   'a = [1] [2]' -> {"a":[1,2]}
//   'a = {x=1} y'     -> {"a":{"x":1}}         java parses it and drops the text
//                                              part when merging — a decision for
//                                              evaluation, so the tree keeps it.
// In the first three rows the whitespace plays no role,
// but it does in 'a = ${b} ${c}', and one rule for both beats two rules split by
// what the neighbours happen to be. Evaluation is where a whitespace part gets
// ignored — merging objects, concatenating lists — not the parser.
test "value.the gap between two parts is always a part" {
    try expectAll(&.{
        .ok("a = {x:5} {y:6}", "root(assign(value(a), concat(block(assign(value(x), value(5))), value( ), block(assign(value(y), value(6))))))"),
        .ok("a = {x:5}{y:6}", "root(assign(value(a), concat(block(assign(value(x), value(5))), block(assign(value(y), value(6))))))"),
        .ok("a = [1] [2]", "root(assign(value(a), concat(array(value(1)), value( ), array(value(2)))))"),
        .ok("a = {x=1} y", "root(assign(value(a), concat(block(assign(value(x), value(1))), value( ), value(y))))"),

        // The gap on the other side of a text part — the direction that goes
        // wrong on its own, because a text part knows where it *started* and
        // using the next token's start as its end measures no gap at all.
        //   'a = x ${b}' -> {"a":"x "${b}}    the space is part of the result
        .ok("a = x ${b}", "root(assign(value(a), concat(value(x), value( ), subst(value(b)))))"),
        .ok("a = x {y:1}", "root(assign(value(a), concat(value(x), value( ), block(assign(value(y), value(1))))))"),
        .ok("a = x [1]", "root(assign(value(a), concat(value(x), value( ), array(value(1)))))"),

        // And with a quoted part, where the gap used to swallow the closing
        // quote: `Token.loc` reported the content, so the part ended one byte
        // early. It covers the whole token now, which is also what lets
        // `parseText` and `parseInclude` stop adding the quotes back by hand.
        .ok("a = \"x\" ${b}", "root(assign(value(a), concat(value(\"x\"), value( ), subst(value(b)))))"),
        .ok("a = \"x\" [1]", "root(assign(value(a), concat(value(\"x\"), value( ), array(value(1)))))"),
        .ok("a = [1] \"x\"", "root(assign(value(a), concat(array(value(1)), value( ), value(\"x\"))))"),
    });
}
