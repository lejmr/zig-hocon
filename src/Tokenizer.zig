const std = @import("std");
const log = std.log;
const testing = std.testing;

const Token = struct {
    tag: Tag,
    loc: Loc,

    const Loc = struct { start: usize, end: usize };

    const Tag = enum {
        l_brace,
        r_brace,
        l_bracket,
        r_bracket,

        string,
        unquoted_string,
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
        eof,
    };

    pub fn init(input: [:0]const u8) Tokenizer {
        return .{ .input = input };
    }

    pub fn next(self: *Tokenizer) Token {
        var state: State = .start;
        var state_start: usize = undefined;
        var quoted_char: u8 = undefined;

        while (true) : (self.pos += 1) {
            const c = self.input[self.pos];
            if (std.c.getenv("CI") == null) {
                std.debug.print("c={c} (0x{x}) pos={d}\n", .{ c, c, self.pos });
            }

            sw_state: switch (state) {
                // This is my initial state
                .start => switch (c) {
                    // Basic hocon syntax
                    'a'...'z', 'A'...'Z' => {
                        state = .word;
                        state_start = self.pos;
                    },
                    '"', '\'' => {
                        state = .quoted;
                        state_start = self.pos+1;
                        quoted_char = c;
                    },
                    '#' => state = .comment,
                    ':', '=' => {
                        self.pos += 1;
                        return .{ .tag = .assignment, .loc = .{ .start = self.pos, .end = self.pos + 1 } };
                    },

                    // Noops in starting phase
                    ' ', '\t', '\n', '\r' => {},

                    // Blocks and arrays can be returned directyl
                    '{' => return .{ .tag = .l_brace, .loc = .{ .start = self.pos, .end = self.pos + 1 } },
                    '}' => return .{ .tag = .r_brace, .loc = .{ .start = self.pos, .end = self.pos + 1 } },
                    '[' => return .{ .tag = .l_bracket, .loc = .{ .start = self.pos, .end = self.pos + 1 } },
                    ']' => return .{ .tag = .r_bracket, .loc = .{ .start = self.pos, .end = self.pos + 1 } },

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
                    '\n', '\r' => state = .start,
                    0 => return .{ .tag = .eof, .loc = .{
                        .start = self.pos,
                        .end = self.pos,
                    } },
                    else => {},
                },
                // Quoted string handling
                .quoted => switch (c) {
                    else =>{
                        if (c == quoted_char) {
                            return .{ .tag = .string, .loc = .{
                                .start = state_start,
                                .end = self.pos,
                            } };
                        }
                    },
                    0 => return .{ .tag = .string, .loc = .{
                        .start = state_start,
                        .end = self.pos,
                    } },
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
        "a$", "a\"", "a{",  "a}", "a[", "a]", "a:", "a=",
        "a,", "a+",  "a#",  "a`", "a^", "a?", "a!", "a@",
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

test "single slash is a legal unquoted string character" {
    var t = Tokenizer.init("a/b");
    const tok = t.next();
    try testing.expectEqual(Token.Tag.string, tok.tag);
    try testing.expectEqualStrings("a/b", t.input[tok.loc.start..tok.loc.end]);
}

test "quoted string variants" {
    const inputs = [_][:0]const u8{
        "\"abc\"",
        "'abc'",
        "\"abc",
        "'abc",
    };

    for (inputs) |input| {
        var t = Tokenizer.init(input);
        errdefer std.debug.print("failed on input: \"{s}\"\n", .{input});

        const tok = t.next();
        try testing.expectEqual(Token.Tag.string, tok.tag);
        try testing.expectEqualStrings("abc", t.input[tok.loc.start..tok.loc.end]);
    }
}