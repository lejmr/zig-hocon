//! Value holder for received data
//!
//! The union and what everything else reads off it. What is done with a value
//! is next to this file, in `Value/`:
//!
//!   build.zig     a node of the tree turned into a value, includes followed
//!   merge.zig     a key written again: what its values make together
//!   Resolver.zig  every `${…}` replaced, once the whole document is there
//!   Scalar.zig, Member.zig, Ref.zig  the parts a value is made of

const std = @import("std");
const Key = @import("Key.zig");
const Ast = @import("Ast.zig");
const Tokenizer = @import("Tokenizer.zig");
const unqoute = @import("utils/unqoute.zig");
const number = @import("utils/number.zig");
const Include = @import("Include.zig");
const build = @import("Value/build.zig");
const merge = @import("Value/merge.zig");
const Resolver = @import("Value/Resolver.zig");

pub const Error = error{
    UnsupportedNodeKind,
    UnsupportedConcatenation,
} || Key.Error || unqoute.Error || Ast.Parser.Error || Include.Error;

pub const Scalar = @import("Value/Scalar.zig");
pub const Member = @import("Value/Member.zig");
pub const Ref = @import("Value/Ref.zig");

pub const Value = union(enum) {
    scalar: Scalar,
    array: []Value,
    object: []Member,
    ref: Ref,

    // For right updates of already stored data, but not yet resolved
    pending: []Part,

    /// A key written more than once, where a later value is a ref or a pending:
    /// whether it merges with the ones before it, or looks back at them, is
    /// known only once it is resolved. Bottom first, the way they were written.
    stack: []Value,

    /// One part of a concatenation with a ref in it, which can join the others
    /// only once the refs have values. `pos` is where it starts, for when a
    /// resolved part does not fit onto the one before it.
    pub const Part = struct {
        value: Value,
        pos: Pos,
    };

    /// A place in the document: which file, as an index into `Files.list`, and
    /// the byte offset in it. Every file counts from 0, so an offset alone does
    /// not say where it is once included files are merged in.
    pub const Pos = struct { file: u16, offset: usize };

    pub const File = build.File;
    pub const Files = build.Files;
    pub const Frame = build.Frame;
    pub const Context = build.Context;
    pub const wayDown = build.wayDown;

    pub const fromNode = build.fromNode;
    pub const update = merge.update;
    pub const numbered = merge.numbered;

    /// Found by `std.json.Stringify` on its own, the way `std.json.Value` is:
    /// `std.json.Stringify.value(v, .{}, writer)` then prints the tree as JSON.
    ///
    /// A scalar is text here, and JSON wants a type. Quoted is always a string;
    /// unquoted `true`/`false`/`null` are themselves, unquoted text that is a
    /// JSON number is a number printed as written, and anything else a string.
    /// A `.ref` or `.pending` cannot be printed before resolving.
    ///
    /// Text with a surrogate on its own, `"\ud83d"`, is written as it was read;
    /// `jw.write` would make it a list of bytes.
    ///
    /// std.json writes 256 lists and objects deep at most, and past that panics
    /// in a safe build: deeper is `error.WriteFailed`.
    pub fn jsonStringify(self: Value, jw: anytype) !void {
        if ((self == .array or self == .object) and jw.indent_level >= 256) return error.WriteFailed;
        switch (self) {
            .scalar => |s| {
                if (!s.quoted) {
                    if (std.mem.eql(u8, s.value, "true")) return jw.write(true);
                    if (std.mem.eql(u8, s.value, "false")) return jw.write(false);
                    if (std.mem.eql(u8, s.value, "null")) return jw.write(null);
                    // Printed as written, not parsed and re-rendered: 1e5 stays 1e5.
                    if (number.isJsonNumber(s.value)) return jw.print("{s}", .{s.value});
                }
                if (!unqoute.hasSurrogate(s.value)) return jw.write(s.value);
                try jw.beginWriteRaw();
                try unqoute.writeJson(s.value, jw.options, jw.writer);
                jw.endWriteRaw();
            },
            // `jw.write` on a Value comes back here: the recursion is std's.
            .array => |items| try jw.write(items),
            .object => |members| {
                try jw.beginObject();
                for (members) |m| {
                    if (unqoute.hasSurrogate(m.key.value)) {
                        try jw.beginObjectFieldRaw();
                        try unqoute.writeJson(m.key.value, jw.options, jw.writer);
                        jw.endObjectFieldRaw();
                    } else {
                        try jw.objectField(m.key.value);
                    }
                    try jw.write(m.value);
                }
                try jw.endObject();
            },
            // Stringify allows no error of its own, so an unresolved tree is refused
            // earlier, by `parseFromSlice(Value, …)`. Only one kept for the
            // environment (`Env.keep`) or built by hand gets here; `hocon.stringify`
            // writes those, as HOCON.
            .ref, .pending, .stack => return error.WriteFailed,
        }
    }

    /// No `.ref` or `.pending` anywhere below: nothing left for resolving to do.
    pub fn isResolved(self: Value) bool {
        return switch (self) {
            .scalar => true,
            .array => |items| for (items) |item| {
                if (!item.isResolved()) break false;
            } else true,
            .object => |members| for (members) |m| {
                if (!m.value.isResolved()) break false;
            } else true,
            .ref, .pending, .stack => false,
        };
    }

    pub const ResolveError = Resolver.Error;
    pub const Env = Resolver.Env;
    pub const resolve = Resolver.resolve;

    /// Unquoted and nothing but whitespace — any of it, NBSP and BOM included.
    pub fn isGap(self: Value) bool {
        if (self != .scalar or self.scalar.quoted) return false;
        var rest = self.scalar.value;
        while (rest.len > 0) {
            const len = Tokenizer.whitespaceLen(rest);
            if (len == 0) return false;
            rest = rest[len..];
        }
        return true;
    }
};

test {
    _ = Scalar;
    _ = Member;
    _ = Ref;
    _ = build;
    _ = merge;
    _ = Resolver;
}
