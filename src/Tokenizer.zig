const std = @import("std");
const log = std.log;
const testing = std.testing;

pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub const Loc = struct { start: usize, end: usize };

    pub const Tag = enum {
        l_brace,
        r_brace,
        l_bracket,
        r_bracket,

        string,
        quoted_string,
        multiline_string,
        newline,
        comma,
        assignment, // = or :

        invalid,
        eof,
    };
};

pub const Tokenizer = struct {
    input: [:0]const u8,
    pos: usize = 0,

    const State = enum {
        start,
        comment,
        word,
        quoted,
        multiline,
        eof,
    };

    pub fn init(input: [:0]const u8) Tokenizer {
        return .{ .input = input };
    }

    pub fn next(self: *Tokenizer) Token {
        var state: State = .start;
        var state_start: usize = undefined;

        while (true) : (self.pos += 1) {
            const c = self.input[self.pos];
            //std.debug.print("c={c} (0x{x}) pos={d}\n", .{ c, c, self.pos });

            sw_state: switch (state) {
                // This is my initial state
                .start => switch (c) {
                    // Basic hocon syntax
                    'a'...'z', 'A'...'Z', '0'...'9', '-', '.' => {
                        state = .word;
                        state_start = self.pos;
                    },
                    '"' => {
                        if (self.input[self.pos + 1] == '"' and self.input[self.pos + 2] == '"') {
                            self.pos += 2;
                            state = .multiline;
                        } else {
                            state = .quoted;
                        }
                        state_start = self.pos + 1;
                    },
                    '#' => state = .comment,
                    '/' => {
                        if (self.input[self.pos + 1] == '/') {
                            self.pos += 1; // Skip the second slash
                            state = .comment;
                        } else {
                            // Single slash starts a legal unquoted string
                            state = .word;
                            state_start = self.pos;
                        }
                    },
                    ':', '=' => {
                        self.pos += 1;
                        return .{ .tag = .assignment, .loc = .{ .start = self.pos - 1, .end = self.pos } };
                    },
                    '\n', '\r' => {
                        self.pos += 1;
                        return .{ .tag = .newline, .loc = .{ .start = self.pos - 1, .end = self.pos } };
                    },
                    ',' => {
                        self.pos += 1;
                        return .{ .tag = .comma, .loc = .{ .start = self.pos - 1, .end = self.pos } };
                    },

                    // Noops in starting phase
                    ' ', '\t' => {},

                    // Blocks and arrays can be returned directyl
                    '{' => {
                        self.pos += 1;
                        return .{ .tag = .l_brace, .loc = .{ .start = self.pos - 1, .end = self.pos } };
                    },
                    '}' => {
                        self.pos += 1;
                        return .{ .tag = .r_brace, .loc = .{ .start = self.pos - 1, .end = self.pos } };
                    },
                    '[' => {
                        self.pos += 1;
                        return .{ .tag = .l_bracket, .loc = .{ .start = self.pos - 1, .end = self.pos } };
                    },
                    ']' => {
                        self.pos += 1;
                        return .{ .tag = .r_bracket, .loc = .{ .start = self.pos - 1, .end = self.pos } };
                    },

                    // End of the file
                    0 => continue :sw_state .eof,

                    // Invalid state that should happen only as part of development
                    else => return .{ .tag = .invalid, .loc = .{
                        .start = self.pos,
                        .end = self.pos,
                    } },
                },
                .word => switch (c) {
                    '`', '^', '?', '!', '@', '*', '&', '\\', '$', '"', '{', '}', '[', ']', ',', '+', '#', '\t', '\n', '\r' => return .{
                        .tag = .string,
                        .loc = .{ .start = state_start, .end = self.pos },
                    },

                    // Special comment handling
                    '/' => {
                        if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '/') {
                            self.pos += 1; // Skip the second slash
                            return .{ .tag = .string, .loc = .{
                                .start = state_start,
                                .end = self.pos - 1,
                            } };
                        } else {
                            // Single slash is a legal unquoted string character
                        }
                    },

                    // Proper ending
                    '=', ':', ' ' => {
                        state = .start;
                        return .{ .tag = .string, .loc = .{
                            .start = state_start,
                            .end = self.pos,
                        } };
                    },

                    0 => return .{ .tag = .string, .loc = .{
                        .start = state_start,
                        .end = self.pos,
                    } },
                    else => {},
                },
                // Comment handling
                .comment => switch (c) {
                    '\n', '\r' => {
                        self.pos += 1;
                        return .{ .tag = .newline, .loc = .{
                            .start = self.pos - 1,
                            .end = self.pos,
                        } };
                    },
                    0 => return .{ .tag = .eof, .loc = .{
                        .start = self.pos,
                        .end = self.pos,
                    } },
                    else => {},
                },
                // Quoted string handling
                .quoted => switch (c) {
                    '"' => {
                        if (self.input[self.pos - 1] != '\\') {
                            self.pos += 1;
                            return .{ .tag = .quoted_string, .loc = .{
                                .start = state_start,
                                .end = self.pos - 1,
                            } };
                        }
                    },
                    0 => return .{ .tag = .invalid, .loc = .{
                        .start = state_start,
                        .end = self.pos,
                    } },
                    else => {},
                },
                // Triple-quoted """multiline""" string handling
                .multiline => switch (c) {
                    '"' => {
                        if (self.input[self.pos + 1] == '"' and self.input[self.pos + 2] == '"') {
                            // Per spec the string ends at the last possible
                            // triple quote: extra quotes belong to the content
                            var end = self.pos;
                            while (self.input[end + 3] == '"') end += 1;
                            self.pos = end + 3;
                            return .{ .tag = .multiline_string, .loc = .{
                                .start = state_start,
                                .end = end,
                            } };
                        }
                    },
                    0 => return .{ .tag = .invalid, .loc = .{
                        .start = state_start,
                        .end = self.pos,
                    } },
                    else => {},
                },
                // End of file reached
                .eof => return .{
                    .tag = if (self.pos == self.input.len) .eof else .invalid,
                    .loc = .{
                        .start = self.pos,
                        .end = self.pos,
                    },
                },
            }
        }
        return .{ .tag = .string, .loc = .{ .start = self.pos, .end = self.pos } };
    }
};

test "empty input yields eof" {
    var t = Tokenizer.init("");
    const tok = t.next();
    try testing.expectEqual(Token.Tag.eof, tok.tag);
}

test "comment followed by newline emits exactly one newline token" {
    var t = Tokenizer.init("b#c\na");
    try testing.expectEqual(Token.Tag.string, t.next().tag);
    try testing.expectEqual(Token.Tag.newline, t.next().tag);
    try testing.expectEqual(Token.Tag.string, t.next().tag);
    try testing.expectEqual(Token.Tag.eof, t.next().tag);
}

test "just one word" {
    const inputs = [_][:0]const u8{
        //"abc",
        "   abc",
        "abc ",
    };

    for (inputs) |input| {
        log.debug("testing {s}", .{input});
        var t = Tokenizer.init(input);
        try testing.expectEqual(Token.Tag.string, t.next().tag);
        try testing.expectEqual(Token.Tag.eof, t.next().tag);
    }
}

test "basic assignment with whitespace variants" {
    const inputs = [_][:0]const u8{
        "a=b",
        "a : b",
        "a= b",
        "a =b",
        "a:b",
        " a:b",
        "   a:    b",
    };

    for (inputs) |input| {
        var t = Tokenizer.init(input);
        errdefer std.debug.print("failed on input: \"{s}\"\n", .{input});

        try testing.expectEqual(Token.Tag.string, t.next().tag);
        try testing.expectEqual(Token.Tag.assignment, t.next().tag);
        try testing.expectEqual(Token.Tag.string, t.next().tag);
    }
}

test "unquoted string terminates before each reserved character" {
    // HOCON spec reserved chars: $ " { } [ ] : = , + # ` ^ ? ! @ * & \
    const inputs = [_][:0]const u8{
        "a$", "a\"", "a{",  "a}", "a[",  "a]",  "a:",  "a=",
        "a,", "a+",  "a#",  "a`", "a^",  "a?",  "a!",  "a@",
        "a*", "a&",  "a\\", "a ", "a\t", "a\n", "a\r",
    };

    for (inputs) |input| {
        var t = Tokenizer.init(input);
        errdefer std.debug.print("failed on input: \"{s}\"\n", .{input});

        const tok = t.next();
        try testing.expectEqual(Token.Tag.string, tok.tag);
        try testing.expectEqualStrings("a", t.input[tok.loc.start..tok.loc.end]);
    }
}

test "unquoted string terminates before line comment //" {
    var t = Tokenizer.init("a//b");
    const tok = t.next();
    try testing.expectEqual(Token.Tag.string, tok.tag);
    try testing.expectEqualStrings("a", t.input[tok.loc.start..tok.loc.end]);
}

test "// comment at token start is skipped" {
    var t = Tokenizer.init("a = b // comment\nc");
    try testing.expectEqual(Token.Tag.string, t.next().tag);
    try testing.expectEqual(Token.Tag.assignment, t.next().tag);
    try testing.expectEqual(Token.Tag.string, t.next().tag);
    try testing.expectEqual(Token.Tag.newline, t.next().tag);
    try testing.expectEqual(Token.Tag.string, t.next().tag);
    try testing.expectEqual(Token.Tag.eof, t.next().tag);
}

test "unquoted string can start with a single slash" {
    var t = Tokenizer.init("/usr/local ");
    const tok = t.next();
    try testing.expectEqual(Token.Tag.string, tok.tag);
    try testing.expectEqualStrings("/usr/local", t.input[tok.loc.start..tok.loc.end]);
}

test "single slash is a legal unquoted string character" {
    var t = Tokenizer.init("a/b");
    const tok = t.next();
    try testing.expectEqual(Token.Tag.string, tok.tag);
    try testing.expectEqualStrings("a/b", t.input[tok.loc.start..tok.loc.end]);
}

test "quoted string" {
    var t = Tokenizer.init("\"abc\"");
    const tok = t.next();
    try testing.expectEqual(Token.Tag.quoted_string, tok.tag);
    try testing.expectEqualStrings("abc", t.input[tok.loc.start..tok.loc.end]);
}

test "empty quoted string" {
    var t = Tokenizer.init("\"\"");
    const tok = t.next();
    try testing.expectEqual(Token.Tag.quoted_string, tok.tag);
    try testing.expectEqualStrings("", t.input[tok.loc.start..tok.loc.end]);
}

test "escaped quote inside quoted string does not terminate it" {
    // source: "he said \"hi\""  (raw, unescaped content expected back)
    var t = Tokenizer.init("\"he said \\\"hi\\\"\"");
    const tok = t.next();
    try testing.expectEqual(Token.Tag.quoted_string, tok.tag);
    try testing.expectEqualStrings("he said \\\"hi\\\"", t.input[tok.loc.start..tok.loc.end]);
}

test "multiline string" {
    var t = Tokenizer.init("\"\"\"a \"quoted\" text\nsecond line\"\"\"");
    const tok = t.next();
    try testing.expectEqual(Token.Tag.multiline_string, tok.tag);
    try testing.expectEqualStrings("a \"quoted\" text\nsecond line", t.input[tok.loc.start..tok.loc.end]);
    try testing.expectEqual(Token.Tag.eof, t.next().tag);
}

test "multiline string ends at the last possible triple quote" {
    // """a"""" -> content is a" per the HOCON spec
    var t = Tokenizer.init("\"\"\"a\"\"\"\"");
    const tok = t.next();
    try testing.expectEqual(Token.Tag.multiline_string, tok.tag);
    try testing.expectEqualStrings("a\"", t.input[tok.loc.start..tok.loc.end]);
    try testing.expectEqual(Token.Tag.eof, t.next().tag);
}

test "empty multiline string" {
    var t = Tokenizer.init("\"\"\"\"\"\"");
    const tok = t.next();
    try testing.expectEqual(Token.Tag.multiline_string, tok.tag);
    try testing.expectEqualStrings("", t.input[tok.loc.start..tok.loc.end]);
    try testing.expectEqual(Token.Tag.eof, t.next().tag);
}

test "unterminated quoted string is invalid" {
    const inputs = [_][:0]const u8{
        "\"abc",
        "\"\"\"abc",
        "\"\"\"abc\"\"",
    };

    for (inputs) |input| {
        var t = Tokenizer.init(input);
        errdefer std.debug.print("failed on input: \"{s}\"\n", .{input});

        try testing.expectEqual(Token.Tag.invalid, t.next().tag);
    }
}

test "token loc points at the exact source slice" {
    var t = Tokenizer.init("a=b\nc,d");

    const a = t.next();
    try testing.expectEqualStrings("a", t.input[a.loc.start..a.loc.end]);

    const eq = t.next();
    try testing.expectEqualStrings("=", t.input[eq.loc.start..eq.loc.end]);

    const b = t.next();
    try testing.expectEqualStrings("b", t.input[b.loc.start..b.loc.end]);

    const nl = t.next();
    try testing.expectEqualStrings("\n", t.input[nl.loc.start..nl.loc.end]);

    const c = t.next();
    try testing.expectEqualStrings("c", t.input[c.loc.start..c.loc.end]);

    const comma = t.next();
    try testing.expectEqualStrings(",", t.input[comma.loc.start..comma.loc.end]);
}

test "braces and brackets loc points at the exact source slice" {
    var t = Tokenizer.init("{[]}");

    const lb = t.next();
    try testing.expectEqualStrings("{", t.input[lb.loc.start..lb.loc.end]);

    const lbr = t.next();
    try testing.expectEqualStrings("[", t.input[lbr.loc.start..lbr.loc.end]);

    const rbr = t.next();
    try testing.expectEqualStrings("]", t.input[rbr.loc.start..rbr.loc.end]);

    const rb = t.next();
    try testing.expectEqualStrings("}", t.input[rb.loc.start..rb.loc.end]);
}

test "unquoted string can start with - or ." {
    const inputs = [_][:0]const u8{ "-5", ".5", "-1.5e10" };

    for (inputs) |input| {
        var t = Tokenizer.init(input);
        errdefer std.debug.print("failed on input: \"{s}\"\n", .{input});

        const tok = t.next();
        try testing.expectEqual(Token.Tag.string, tok.tag);
        try testing.expectEqualStrings(input, t.input[tok.loc.start..tok.loc.end]);
    }
}

test "key path stays a single token, dot is not split off" {
    var t = Tokenizer.init("a.b.c = 1");
    const key = t.next();
    try testing.expectEqual(Token.Tag.string, key.tag);
    try testing.expectEqualStrings("a.b.c", t.input[key.loc.start..key.loc.end]);

    try testing.expectEqual(Token.Tag.assignment, t.next().tag);

    const value = t.next();
    try testing.expectEqual(Token.Tag.string, value.tag);
    try testing.expectEqualStrings("1", t.input[value.loc.start..value.loc.end]);
}

test "single quote is a legal unquoted string character" {
    var t = Tokenizer.init("a'b' ");
    const tok = t.next();
    try testing.expectEqual(Token.Tag.string, tok.tag);
    try testing.expectEqualStrings("a'b'", t.input[tok.loc.start..tok.loc.end]);
}

test "full sequence" {
    var t = Tokenizer.init(
        \\# komentář
        \\a = b
        \\obj { x = "y" }
        \\ arr = [1, 2, 3]
        \\d = """
        \\ this is my 
        \\ multiline string
        \\ """
    );
    const expected = [_]Token.Tag{
        .newline,
        .string,
        .assignment,
        .string,
        .newline,
        .string,
        .l_brace,
        .string,
        .assignment,
        .quoted_string,
        .r_brace,
        .newline,
        .string,
        .assignment,
        .l_bracket,
        .string,
        .comma,
        .string,
        .comma,
        .string,
        .r_bracket,
        .newline,
        .string,
        .assignment,
        .multiline_string,
        .eof,
    };
    for (expected) |tag| {
        //std.debug.print("** Stepping onto {} \n", .{tag});
        errdefer std.debug.print("failed {} on input: \"{s}\"\n", .{ tag, t.input[t.pos..] });
        try testing.expectEqual(tag, t.next().tag);
    }
}
