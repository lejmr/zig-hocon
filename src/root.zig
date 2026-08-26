//! zig-hocon: a HOCON (Human-Optimized Config Object Notation) parser for Zig.
const std = @import("std");

test {
    _ = @import("Tokenizer.zig");
    _ = @import("Ast.zig");
    _ = @import("utils/unqoute.zig");
    _ = @import("Key.zig");
    _ = @import("Value.zig");
}
