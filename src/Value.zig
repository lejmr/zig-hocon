//! Value holder for received data

const std = @import("std");
const testing = std.testing;
const Key = @import("Key.zig");
const Ast = @import("Ast.zig");
const Tokenizer = @import("Tokenizer.zig");
const Node = Ast.Node;
const unqoute = @import("utils/unqoute.zig");
const number = @import("utils/number.zig");
const Include = @import("Include.zig");
const table = @import("table.zig");

pub const Error = error{
    UnsupportedNodeKind,
    UnsupportedConcatenation,
} || Key.Error || unqoute.Error || Ast.Parser.Error || Include.Error;

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

    /// One file that went into the document, for an error to point into.
    pub const File = struct {
        /// As it was named: the path the parse was given, the include's path or
        /// URL. Empty for a slice.
        path: []const u8,
        source: []const u8,
    };

    /// Every file of one document, the main one first, and the first error found
    /// in any of them. All of them share it through `Context`.
    pub const Files = struct {
        list: std.ArrayList(File) = .empty,
        failed: ?Pos = null,

        /// Called where the parse or the build of `file` gave up, `offset` being
        /// where in it. An included file that failed has said so already, and the
        /// files around it leave that be: written once, where the error starts.
        pub fn fail(self: *Files, file: u16, offset: ?usize) void {
            if (self.failed != null) return;
            const at = offset orelse return;
            self.failed = .{ .file = file, .offset = at };
        }
    };

    /// One step of the way down from a file's root, kept on the stack while the
    /// value below it is built: an include needs the whole way as a path.
    pub const Frame = struct { parent: ?*const Frame, key: Key };

    /// What building a value needs to know about the file it comes from, so an
    /// `include` has somewhere to look. The default is a document read from a
    /// slice: there is no file system behind it, and an include is an error.
    pub const Context = struct {
        /// Null when the document came from a slice.
        io: ?std.Io = null,
        /// The directory of the file being built; a plain include name is found there.
        dir: []const u8 = "",
        /// The files being built right now, outermost first, as normalised paths.
        /// Including one of them again would never end.
        stack: []const []const u8 = &.{},
        /// The URL of the file being built, when it came from one: a plain include
        /// name is then a URL on the same server, not a path.
        base_url: ?[]const u8 = null,
        /// How long a fetch may take (see `ParseOptions`).
        http_timeout: std.Io.Duration = Include.default_http_timeout,
        /// Where this file's keys sit in the whole document; every substitution in
        /// it is tried with this in front first (see `Ref`).
        scope: []const Key = &.{},
        /// The keys from this file's root down to the object being built.
        frame: ?*const Frame = null,
        /// The files of the document, and this one's index among them.
        files: ?*Files = null,
        file: u16 = 0,

        /// Where building this file gave up, for the diagnostics. The first error
        /// of the document is the one kept (`Files.fail`). Nothing to tell when
        /// the tree was built by hand, without files.
        pub fn fail(ctx: Context, offset: usize) void {
            const files = ctx.files orelse return;
            files.fail(ctx.file, offset);
        }
    };

    /// Turns one node of the tree into a value. Dispatch only: `.value` is a
    /// scalar, `.block` an object, `.array` a list, `.subst`/`.subst_optional`
    /// a ref. Anything else never stands where a value stands. `ctx` says which
    /// file the node comes from, so an `include` in a block can be followed; `.{}`
    /// when there is none.
    ///
    /// On failure `ctx.fail` gets the position of the node that failed, where the
    /// error starts: `try` only passes it on. An error inside an included file
    /// has been placed there already, and the include's place does not replace it.
    pub fn fromNode(gpa: std.mem.Allocator, node: Node, ctx: Context) Error!Value {
        return switch (node.kind) {
            .value => .{ .scalar = try Scalar.fromNode(gpa, node, ctx) },
            .block, .root => blk: {
                // A braced root `{a = 1}` is `root(block(...))`: the block is the
                // document. So is the array of `[1, 2]`, which has no braces around it.
                if (node.kind == .root and node.children.len == 1 and
                    (node.children[0].kind == .block or node.children[0].kind == .array))
                    return Value.fromNode(gpa, node.children[0], ctx);

                var members_map: std.StringArrayHashMapUnmanaged(Value) = .empty;
                defer members_map.deinit(gpa);

                for (node.children) |assignment| {
                    // An include stands where its members would: they come in at
                    // this point, under the rules of any other duplicate key.
                    if (assignment.kind == .include) {
                        // A missing file, a cycle, a bad name: the include is the
                        // place.
                        const included = Include.load(gpa, assignment, ctx) catch |err| {
                            ctx.fail(assignment.pos);
                            return err;
                        };
                        for (included.object) |m| try putMember(gpa, &members_map, m.key.value, m.value);
                        continue;
                    }
                    if (assignment.kind != .assignment and assignment.kind != .append) {
                        ctx.fail(assignment.pos);
                        return Error.UnsupportedNodeKind;
                    }
                    const member = try Member.fromNode(gpa, assignment, ctx);
                    try putMember(gpa, &members_map, member.key.value, member.value);
                }
                var members: std.ArrayList(Member) = .empty;
                for (members_map.keys(), members_map.values()) |k, val| {
                    try members.append(gpa, .{ .key = .{ .value = k }, .value = val });
                }
                break :blk .{ .object = try members.toOwnedSlice(gpa) };
            },
            .array => blk: {
                var members: std.ArrayList(Value) = .empty;
                for (node.children) |object| {
                    const val = try Value.fromNode(gpa, object, ctx);
                    try members.append(gpa, val);
                }
                break :blk .{ .array = try members.toOwnedSlice(gpa) };
            },
            .subst, .subst_optional => .{ .ref = try Ref.fromNode(gpa, node, ctx) },
            .concat => {
                var values: std.ArrayList(Part) = .empty;
                var buffer: ?Value = null;
                // Where the buffer starts. Not at a gap: in ` tea` it is the `t`.
                var buffer_pos: usize = node.pos;

                for (node.children) |ch| {
                    // Update buffer value from right
                    const val = try Value.fromNode(gpa, ch, ctx);
                    const tag = std.meta.activeTag(val);

                    if (buffer) |*ebuffer| {
                        if (ebuffer.* == .ref or tag == .ref) {
                            try values.append(gpa, .{ .value = ebuffer.*, .pos = .{ .file = ctx.file, .offset = buffer_pos } });
                            buffer = val;
                            buffer_pos = ch.pos;
                            continue;
                        }

                        if (ebuffer.isGap()) buffer_pos = ch.pos;
                        // The part that does not fit onto what came before it.
                        ebuffer.update(gpa, val) catch |err| {
                            ctx.fail(ch.pos);
                            return err;
                        };
                    } else {
                        buffer = val;
                        buffer_pos = ch.pos;
                    }
                }

                if (buffer) |b| try values.append(gpa, .{ .value = b, .pos = .{ .file = ctx.file, .offset = buffer_pos } });
                if (values.items.len == 0) {
                    ctx.fail(node.pos);
                    return Error.UnsupportedConcatenation;
                }
                if (values.items.len > 1) return .{ .pending = try values.toOwnedSlice(gpa) };
                return values.items[0].value;
            },
            else => {
                ctx.fail(node.pos);
                return Error.UnsupportedNodeKind;
            },
        };
    }

    /// Adds a member the way a repeated key is added (see `push`).
    fn putMember(gpa: std.mem.Allocator, map: *std.StringArrayHashMapUnmanaged(Value), key: []const u8, value: Value) Error!void {
        if (map.getPtr(key)) |current_v| {
            try current_v.push(gpa, value);
        } else {
            try map.put(gpa, key, value);
        }
    }

    /// Puts `other` on top of what a repeated key already holds. Two objects
    /// merge. A ref or a pending goes on a stack above what was there, since it
    /// may merge with it or look back at it once resolved; so does an object on
    /// top of one. Anything else replaces what was there, which is then never
    /// looked at again.
    fn push(self: *Value, gpa: std.mem.Allocator, other: Value) Error!void {
        switch (other) {
            // From an include: its layers go on one by one.
            .stack => |layers| for (layers) |layer| try self.push(gpa, layer),
            .ref, .pending => {
                // Built before it is stored: `self.* = .{ .stack = … self.* … }`
                // would read `self` after its tag changed.
                const below: []const Value = if (self.* == .stack) self.stack else &.{self.*};
                const layers = try std.mem.concat(gpa, Value, &.{ below, &.{other} });
                self.* = .{ .stack = layers };
            },
            .object => switch (self.*) {
                .object => try self.update(gpa, other),
                .ref, .pending => {
                    const layers = try gpa.dupe(Value, &.{ self.*, other });
                    self.* = .{ .stack = layers };
                },
                .stack => |layers| {
                    // A copy: the slice may be shared with the value this one came from.
                    const copy = try std.mem.concat(gpa, Value, &.{ layers, &.{other} });
                    // Two objects next to each other merge right away.
                    if (layers[layers.len - 1] == .object) {
                        try copy[layers.len - 1].update(gpa, other);
                        self.stack = copy[0..layers.len];
                    } else {
                        self.stack = copy;
                    }
                },
                else => self.* = other,
            },
            else => self.* = other,
        }
    }

    pub fn update(self: *Value, gpa: std.mem.Allocator, other: Value) Error!void {
        const tag_self = std.meta.activeTag(self.*);
        const tag_other = std.meta.activeTag(other);

        // There are cases when different tags can be handled..
        if (tag_self != tag_other) {
            if ((tag_self == .array or tag_self == .object) and other.isGap()) return;
            // this is how to destroy nicely the empty space!
            if ((tag_other == .array or tag_other == .object) and self.isGap()) {
                self.* = other;
                return;
            }
            return Error.UnsupportedConcatenation;
        }
        switch (tag_other) {
            .array => {
                const merged = try std.mem.concat(gpa, Value, &.{ self.array, other.array });
                self.array = merged;
            },
            .scalar => {
                self.scalar = .{
                    .value = try std.mem.concat(gpa, u8, &.{ self.scalar.value, other.scalar.value }),
                    .quoted = true,
                };
            },
            .object => {
                // Convert self block to hasmap
                var map: std.StringArrayHashMapUnmanaged(Value) = .empty;
                defer map.deinit(gpa);
                for (self.object) |m| try putMember(gpa, &map, m.key.value, m.value);

                // Update self about other
                for (other.object) |oo| try putMember(gpa, &map, oo.key.value, oo.value);

                // Convert to list of Members
                var merged: std.ArrayList(Member) = .empty;
                for (map.keys(), map.values()) |k, val| {
                    try merged.append(gpa, .{ .key = .{ .value = k }, .value = val });
                }
                self.object = try merged.toOwnedSlice(gpa);
            },
            else => return Error.UnsupportedConcatenation,
        }
    }

    /// Found by `std.json.Stringify` on its own, the way `std.json.Value` is:
    /// `std.json.Stringify.value(v, .{}, writer)` then prints the tree as JSON.
    ///
    /// A scalar is text here, and JSON wants a type. Quoted is always a string;
    /// unquoted `true`/`false`/`null` are themselves, unquoted text that is a
    /// JSON number is a number printed as written, and anything else a string.
    /// A `.ref` or `.pending` cannot be printed before resolving.
    pub fn jsonStringify(self: Value, jw: anytype) !void {
        switch (self) {
            .scalar => |s| {
                if (s.quoted) return jw.write(s.value);
                if (std.mem.eql(u8, s.value, "true")) return jw.write(true);
                if (std.mem.eql(u8, s.value, "false")) return jw.write(false);
                if (std.mem.eql(u8, s.value, "null")) return jw.write(null);
                // Printed as written, not parsed and re-rendered: 1e5 stays 1e5.
                if (number.isJsonNumber(s.value)) return jw.print("{s}", .{s.value});
                return jw.write(s.value);
            },
            // `jw.write` on a Value comes back here: the recursion is std's.
            .array => |items| try jw.write(items),
            .object => |members| {
                try jw.beginObject();
                for (members) |m| {
                    try jw.objectField(m.key.value);
                    try jw.write(m.value);
                }
                try jw.endObject();
            },
            // Stringify allows no error of its own, so an unresolved tree is refused
            // earlier, by `parseFromSlice(Value, …)`. Only a hand-built Value gets here.
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

    pub const ResolveError = error{ Unresolved, SubstitutionCycle } || Error;

    /// Replaces all refs and pendings in the document. Self has to be the root.
    /// On failure `err_pos` is the `${` of the substitution that failed, or the
    /// part that does not fit once the refs around it have values — in whichever
    /// file it came from.
    pub fn resolve(self: *Value, gpa: std.mem.Allocator, err_pos: *?Pos) ResolveError!void {
        var state: Resolving = .{ .err_pos = err_pos };
        defer {
            state.visiting.deinit(gpa);
            state.fields.deinit(gpa);
            var it = state.index.valueIterator();
            while (it.next()) |members| members.deinit(gpa);
            state.index.deinit(gpa);
        }

        // Root is object and object never disappears
        self.* = (try self.resolveValue(gpa, self, &state)) orelse unreachable;
    }

    // What resolve carries along
    const Resolving = struct {
        // Places we are resolving right now, so a = ${b}, b = ${a} ends
        visiting: std.ArrayList(*Value) = .empty,
        // Fields whose top value is being resolved right now, innermost last.
        // A path that reaches one of them does not see the field (see `seen`).
        fields: std.ArrayList(Field) = .empty,
        // Members of an object by key, built on the first lookup into it. Keyed by
        // the slice, which never changes once built: a resolved object is a new one.
        index: std.AutoHashMapUnmanaged([*]Member, std.StringHashMapUnmanaged(*Value)) = .empty,
        // Where the error points; written once, where the error starts.
        err_pos: *?Pos,
    };

    // One layer of a field being resolved, and what a path to the field sees
    // meanwhile. A ref or a pending is self-referential: the path sees the
    // layers below it, as if the field were never written from here up. An
    // object is not: the path sees it merged onto the layers below.
    const Field = struct {
        place: *Value,
        below: []const Value,
        // The object being resolved, for an object layer.
        object: ?*Value = null,
        // `below` merged, worked out on the first path that needs it.
        merged: ?Value = null,
        progress: enum { todo, busy, done } = .todo,
    };

    // Returns null when the value is gone - ${?x} pointing to nothing
    fn resolveValue(self: Value, gpa: std.mem.Allocator, root: *Value, state: *Resolving) ResolveError!?Value {
        switch (self) {
            .scalar => return self,
            .array => |items| {
                var values: std.ArrayList(Value) = .empty;
                for (items) |item| {
                    if (try item.resolveValue(gpa, root, state)) |val| try values.append(gpa, val);
                }
                return .{ .array = try values.toOwnedSlice(gpa) };
            },
            .object => |members| {
                var resolved: std.ArrayList(Member) = .empty;
                for (members) |*m| {
                    // A member is being resolved too, so a ref that leads back to
                    // it closes a cycle — and that ref is the one reported.
                    try state.visiting.append(gpa, &m.value);
                    defer _ = state.visiting.pop();

                    if (try resolveField(&m.value, gpa, root, state)) |val| {
                        try resolved.append(gpa, .{ .key = m.key, .value = val });
                    }
                }
                return .{ .object = try resolved.toOwnedSlice(gpa) };
            },
            .ref => |r| {
                if (try follow(gpa, root, r, r.path, state)) |val| return val;
                // From an included file: not found with the scope in front, or
                // gone (an optional that found nothing), so try the path as written.
                if (r.scope_len > 0) {
                    if (try follow(gpa, root, r, r.path[r.scope_len..], state)) |val| return val;
                }
                if (r.optional) return null;
                state.err_pos.* = r.at();
                return ResolveError.Unresolved;
            },
            .pending => |parts| {
                // Same as concat in fromNode, just now refs have values
                var buffer: ?Value = null;
                for (parts) |part| {
                    const val = try part.value.resolveValue(gpa, root, state) orelse continue;
                    if (buffer) |*ebuffer| {
                        // The part that does not fit onto what came before it.
                        ebuffer.update(gpa, val) catch |err| {
                            state.err_pos.* = part.pos;
                            return err;
                        };
                    } else {
                        buffer = val;
                    }
                }
                var result = buffer orelse return null;
                // Merged text is always string, ${?x}42 is "42"
                if (result == .scalar) result.scalar.quoted = true;
                return result;
            },
            // Only a field holds one, and a field is resolved by `resolveField`.
            .stack => unreachable,
        }
    }

    // Resolves the value of a field and stores it back, so the next ref there
    // gets it for free: memoised per place, not per path.
    fn resolveField(place: *Value, gpa: std.mem.Allocator, root: *Value, state: *Resolving) ResolveError!?Value {
        // A field written once is a stack of one.
        const one = [_]Value{place.*};
        const val = switch (place.*) {
            .stack => |layers| try resolveStack(place, layers, gpa, root, state),
            .ref, .pending => try resolveStack(place, &one, gpa, root, state),
            else => try place.resolveValue(gpa, root, state),
        } orelse return null;
        place.* = val;
        return val;
    }

    // The layers of a field, from the top: the top one decides, and the ones
    // below are resolved only when it merges with them or looks back at them.
    // Null when there is nothing, or an optional that found nothing is all there is.
    fn resolveStack(place: *Value, layers: []const Value, gpa: std.mem.Allocator, root: *Value, state: *Resolving) ResolveError!?Value {
        if (layers.len == 0) return null;
        const top = layers[layers.len - 1];
        const below = layers[0 .. layers.len - 1];

        switch (top) {
            // Hides whatever is below it.
            .scalar, .array => return try top.resolveValue(gpa, root, state),
            // Looks forward, into itself merged with what was below it. The merge
            // goes first, so a key it has and the layers below have too is one
            // field with a stack of its own.
            .object => {
                var merged = top;
                const under = if (mergeable(below)) try resolveStack(place, below, gpa, root, state) else null;
                if (under) |u| if (u == .object) {
                    merged = u;
                    try merged.update(gpa, top);
                };
                const object = try gpa.create(Value);
                object.* = merged;
                try state.fields.append(gpa, .{ .place = place, .below = below, .object = object });
                defer _ = state.fields.pop();
                // A path ending at the object itself is a cycle, `a : { b : ${a} }`.
                try state.visiting.append(gpa, object);
                defer _ = state.visiting.pop();
                return try object.resolveValue(gpa, root, state);
            },
            .ref, .pending => {
                try state.fields.append(gpa, .{ .place = place, .below = below });
                const val = try top.resolveValue(gpa, root, state);
                const field = state.fields.pop().?;

                // Gone, or an object that merges onto what was below: then that counts.
                if (val != null and val.? != .object) return val;
                const under = if (field.progress == .done)
                    field.merged
                else if (val != null and !mergeable(below))
                    null
                else
                    try resolveStack(place, below, gpa, root, state);
                // An optional that found nothing leaves what was below in place.
                var result = val orelse return under;
                if (under) |u| if (u == .object) {
                    var merged = u;
                    try merged.update(gpa, result);
                    result = merged;
                };
                return result;
            },
            .stack => unreachable,
        }
    }

    // Whether an object on top of these layers may merge with them. Text or a
    // list on top of them never does, so they are not even looked at.
    fn mergeable(layers: []const Value) bool {
        if (layers.len == 0) return false;
        const top = layers[layers.len - 1];
        return top != .scalar and top != .array;
    }

    // The value at a path, resolved; null when nothing is there or it vanishes.
    // `ref` is the one that asked, for the errors on the way.
    fn follow(gpa: std.mem.Allocator, root: *Value, ref: Ref, path: []const Key, state: *Resolving) ResolveError!?Value {
        const target = try lookup(gpa, root, ref, path, state) orelse return null;
        return try resolveTarget(target, gpa, root, ref.at(), state);
    }

    // Resolves the place a ref points to and stores it back, next ref there is for free.
    // `from` is where the ref that asked is, the one that closes a cycle.
    fn resolveTarget(target: *Value, gpa: std.mem.Allocator, root: *Value, from: Pos, state: *Resolving) ResolveError!?Value {
        for (state.visiting.items) |place| {
            if (place == target) {
                state.err_pos.* = from;
                return ResolveError.SubstitutionCycle;
            }
        }
        try state.visiting.append(gpa, target);
        defer _ = state.visiting.pop();

        return try resolveField(target, gpa, root, state);
    }

    // Walks the path from root, a ref on the way has to be resolved first
    fn lookup(gpa: std.mem.Allocator, root: *Value, ref: Ref, path: []const Key, state: *Resolving) ResolveError!?*Value {
        var current = root;
        for (path) |key| {
            current = try seen(current, gpa, root, ref, state) orelse return null;
            if (current.* == .ref or current.* == .pending or current.* == .stack) {
                _ = try resolveTarget(current, gpa, root, ref.at(), state) orelse return null;
            }
            if (current.* != .object) return null;

            const members = try state.index.getOrPut(gpa, current.object.ptr);
            if (!members.found_existing) {
                members.value_ptr.* = .empty;
                // A later duplicate overwrites, the last one wins as in the slice
                for (current.object) |*m| try members.value_ptr.put(gpa, m.key.value, &m.value);
            }
            current = members.value_ptr.get(key.value) orelse return null;
        }
        return try seen(current, gpa, root, ref, state);
    }

    // What a path finds at `place`: the place itself, unless it is a field being
    // resolved (see `Field`). With nothing below, a ref back to the field it is
    // in finds nothing, as if it named a missing path; one that came round
    // through another field is a cycle, unless it is optional.
    fn seen(place: *Value, gpa: std.mem.Allocator, root: *Value, ref: Ref, state: *Resolving) ResolveError!?*Value {
        var i = state.fields.items.len;
        while (i > 0) {
            i -= 1;
            const field = &state.fields.items[i];
            if (field.place != place) continue;
            if (field.object) |object| return object;

            switch (field.progress) {
                .done => {},
                // `a = [${a}], a = ${?a}`: the layers below lead back here.
                .busy => {
                    if (ref.optional) return null;
                    state.err_pos.* = ref.at();
                    return ResolveError.SubstitutionCycle;
                },
                .todo => {
                    if (field.below.len == 0 and !ref.optional and i + 1 < state.fields.items.len) {
                        state.err_pos.* = ref.at();
                        return ResolveError.SubstitutionCycle;
                    }
                    field.progress = .busy;
                    const below = field.below;
                    // Resolving appends to `fields`, so `field` may have moved.
                    const merged = try resolveStack(place, below, gpa, root, state);
                    state.fields.items[i].merged = merged;
                    state.fields.items[i].progress = .done;
                },
            }
            const copy = try gpa.create(Value);
            copy.* = state.fields.items[i].merged orelse return null;
            return copy;
        }
        return place;
    }

    /// Unquoted and nothing but whitespace — any of it, NBSP and BOM included.
    fn isGap(self: Value) bool {
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

// PLace holder for any string or number
pub const Scalar = struct {
    value: []const u8,
    quoted: bool,

    pub fn fromNode(gpa: std.mem.Allocator, node: Node, ctx: Value.Context) Error!Scalar {
        const ut = unqoute.unquote(gpa, node.value) catch |err| {
            ctx.fail(node.pos);
            return err;
        };
        return .{ .value = ut.text, .quoted = ut.quoted };
    }
};
pub const Member = struct {
    key: Key,
    value: Value,

    /// From an `.assignment` or an `.append`: `children[0]` is the key,
    /// `children[1]` the value.
    pub fn fromNode(gpa: std.mem.Allocator, node: Node, ctx: Value.Context) Error!Member {
        // Member can only by assignment type, with a key and a value
        if ((node.kind != .assignment and node.kind != .append) or node.children.len < 2) {
            ctx.fail(node.pos);
            return Error.UnsupportedNodeKind;
        }

        // Lets prepare key: one part, or the `concat` of parts one element can be
        const key_node = node.children[0];
        if (key_node.kind != .value and key_node.kind != .concat) {
            ctx.fail(key_node.pos);
            return Error.UnsupportedNodeKind;
        }

        const key = try Key.fromNode(gpa, key_node, ctx);
        // Below this key, an include knows where it is.
        const frame: Value.Frame = .{ .parent = ctx.frame, .key = key };
        var inner = ctx;
        inner.frame = &frame;
        const value = try Value.fromNode(gpa, node.children[1], inner);
        if (node.kind != .append) return .{ .key = key, .value = value };

        // `a += b` is `a = ${?a} [b]`, where `a` is the field's whole path: the
        // include's scope, then the keys from the file's root down to this one.
        var keys: std.ArrayList(Key) = .empty;
        var step: ?*const Value.Frame = &frame;
        while (step) |s| : (step = s.parent) try keys.append(gpa, s.key);
        std.mem.reverse(Key, keys.items);
        const self_ref: Ref = .{
            .path = try std.mem.concat(gpa, Key, &.{ ctx.scope, keys.items }),
            .optional = true,
            .scope_len = @intCast(ctx.scope.len),
            .file = ctx.file,
            .pos = @intCast(node.pos),
        };
        const parts = try gpa.dupe(Value.Part, &.{
            .{ .value = .{ .ref = self_ref }, .pos = self_ref.at() },
            .{ .value = .{ .array = try gpa.dupe(Value, &.{value}) }, .pos = .{ .file = ctx.file, .offset = node.children[1].pos } },
        });
        return .{ .key = key, .value = .{ .pending = parts } };
    }

    pub fn update(self: *Member, gpa: std.mem.Allocator, other: Member) Error!void {
        if (self.value == .object and other.value == .object) {
            try self.value.update(gpa, other.value);
        } else {
            self.value.* = other.value;
        }
    }
};
/// A reference. From an included file, `path` is the path as written with the
/// include's scope in front, and `scope_len` says how much of it that is: the
/// path is looked up as it stands, and when that finds nothing, again without
/// the scope, from the document root.
pub const Ref = struct {
    path: []const Key,
    optional: bool,
    /// A u8, so that `file` fits too: Ref stays 24 bytes and Value 32. More keys
    /// than that above an include are refused where the scope is made.
    scope_len: u8 = 0,
    /// Where its `${` is, for the resolver's errors: the file it was written in
    /// and the offset there. A u32 like the byte offsets in std.zig.Ast: a usize
    /// would make every Value 8 bytes bigger.
    file: u16,
    pos: u32,

    /// Where its `${` is, as a place in the document.
    pub fn at(self: Ref) Value.Pos {
        return .{ .file = self.file, .offset = self.pos };
    }

    /// A malformed path is reported at the `${`, like everything about a ref;
    /// a bad escape at the quoted part it is in.
    pub fn fromNode(gpa: std.mem.Allocator, node: Node, ctx: Value.Context) Error!Ref {
        var single = [_]Node{node.children[0]};
        const parts: []const Node = switch (node.children[0].kind) {
            .value => &single,
            .concat => node.children[0].children,
            else => {
                ctx.fail(node.pos);
                return Error.UnsupportedNodeKind;
            },
        };

        var key_list: std.ArrayList(Key) = .empty;
        var current: std.ArrayList(u8) = .empty;
        defer current.deinit(gpa);
        var written = false;

        for (parts) |part| {
            if (part.kind != .value) {
                ctx.fail(node.pos);
                return Error.MalformedKey;
            }
            const ut = unqoute.unquote(gpa, part.value) catch |err| {
                ctx.fail(part.pos);
                return err;
            };
            if (ut.quoted) {
                try current.appendSlice(gpa, ut.text);
                written = true;
                continue;
            }

            var it = std.mem.splitScalar(u8, ut.text, '.');
            try current.appendSlice(gpa, it.first());
            while (it.next()) |x| {
                if (current.items.len == 0 and !written) {
                    ctx.fail(node.pos);
                    return Error.MalformedKey;
                }
                try key_list.append(gpa, .{ .value = try gpa.dupe(u8, current.items) });
                current.clearRetainingCapacity();
                written = false;
                try current.appendSlice(gpa, x);
            }
        }
        if (current.items.len == 0 and !written) {
            ctx.fail(node.pos);
            return Error.MalformedKey;
        }
        try key_list.append(gpa, .{ .value = try gpa.dupe(u8, current.items) });

        return .{
            .path = try std.mem.concat(gpa, Key, &.{ ctx.scope, key_list.items }),
            .optional = if (node.kind == .subst_optional) true else false,
            .scope_len = @intCast(ctx.scope.len),
            .file = ctx.file,
            .pos = @intCast(node.pos),
        };
    }
};
// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn v(text: []const u8) Node {
    return .{ .kind = .value, .value = text, .children = &.{} };
}

fn n(kind: Node.NodeKind, children: []Node) Node {
    return .{ .kind = kind, .value = "", .children = children };
}

/// `Value.fromNode` for a tree with no file behind it.
fn build(gpa: std.mem.Allocator, node: Node) Error!Value {
    return Value.fromNode(gpa, node, .{});
}

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

test "value.an object holds its members in written order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var m1 = [_]Node{ v("x"), v("1") };
    var m2 = [_]Node{ v("y"), v("2") };
    var members = [_]Node{ n(.assignment, &m1), n(.assignment, &m2) };

    const obj = try build(gpa, n(.block, &members));
    try testing.expectEqual(@as(usize, 2), obj.object.len);
    try testing.expectEqualStrings("x", obj.object[0].key.value);
    try testing.expectEqualStrings("2", obj.object[1].value.scalar.value);
}

test "value.an array holds anything, nested included" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var inner = [_]Node{v("2")};
    var elems = [_]Node{ v("1"), n(.array, &inner) };

    const arr = try build(gpa, n(.array, &elems));
    try testing.expectEqual(@as(usize, 2), arr.array.len);
    try testing.expectEqualStrings("1", arr.array[0].scalar.value);
    try testing.expectEqualStrings("2", arr.array[1].array[0].scalar.value);
}

test "value.a substitution becomes a ref, optional and all" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var path = [_]Node{v("a.b")};
    const req = try build(gpa, n(.subst, &path));
    try testing.expect(!req.ref.optional);
    try testing.expectEqual(@as(usize, 2), req.ref.path.len);
    try testing.expectEqualStrings("a", req.ref.path[0].value);
    try testing.expectEqualStrings("b", req.ref.path[1].value);

    const opt = try build(gpa, n(.subst_optional, &path));
    try testing.expect(opt.ref.optional);
}

// The root of a document is an object like any other: its children are members,
// so it converts exactly as a `.block` does. Java says the same by rejecting a
// document whose root is a list, `[1,2]`, as WrongType rather than as syntax.
test "value.the root converts like a block" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var m1 = [_]Node{ v("x"), v("1") };
    var members = [_]Node{n(.assignment, &m1)};

    const doc = try build(gpa, n(.root, &members));
    try testing.expectEqual(@as(usize, 1), doc.object.len);
    try testing.expectEqualStrings("x", doc.object[0].key.value);
}

// The size of a `Value` is a cost paid for every scalar of every document, and
// the depth a chain of substitutions can reach before the stack runs out. A ref
// carries its place (a u16 file, a u32 offset) and the include scope (a u8)
// in what its path and flag leave of 24 bytes.
test "value.a ref's place and scope fit in the padding" {
    try testing.expectEqual(32, @sizeOf(Value));
    try testing.expectEqual(24, @sizeOf(Ref));
}

// An include is a member of a block, handled where the block is built, so one
// standing where a value stands is a phase that ran out of order. A bare
// assignment is a member, not a value, and `Member.fromNode` is the one that takes it.
test "value.an include or a bare assignment is not a value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var child = [_]Node{v("x")};
    for ([_]Node.NodeKind{ .include, .assignment }) |kind| {
        try testing.expectError(Error.UnsupportedNodeKind, build(gpa, n(kind, &child)));
    }
}

// An assignment is a key and a value. One without both is a tree the parser
// never builds, refused rather than read past its end.
test "value.an assignment without a value is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var key_only = [_]Node{v("a")};
    var members = [_]Node{n(.assignment, &key_only)};
    try testing.expectError(Error.UnsupportedNodeKind, build(gpa, n(.block, &members)));
    var empty = [_]Node{n(.assignment, &.{})};
    try testing.expectError(Error.UnsupportedNodeKind, build(gpa, n(.block, &empty)));
}

// java ✓ · pyhocon ✓ · spec ✓ — lists written next to each other are one
// list, and the gap between them is a separator rather than a character:
//
//   'a = [1] [2]'      -> {"a":[1,2]}
//   'a = [1] [2] [3]'  -> {"a":[1,2,3]}
//   'a = [1,2] []'     -> {"a":[1,2]}     an empty part adds nothing
//
// The join is flat and stays on the surface: elements are carried over as they
// are, never looked into. Two lists of lists give a list of two lists, and two
// one-element lists holding the *same* key give two members, not one.
//
//   'a = [[1]] [[2]]'        -> {"a":[[1],[2]]}
//   'a = [{x=1}] [{x=2}]'    -> {"a":[{"x":1},{"x":2}]}
//
// That is the whole difference from an object: a key is an identity, a position
// is not, so merging descends and this never does.
test "value.lists concatenate flatly at load" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var a1 = [_]Node{v("1")};
    var a2 = [_]Node{v("2")};
    var a3 = [_]Node{v("3")};

    var pair = [_]Node{ n(.array, &a1), v(" "), n(.array, &a2) };
    const two = try build(gpa, n(.concat, &pair));
    try testing.expectEqual(@as(usize, 2), two.array.len);
    try testing.expectEqualStrings("1", two.array[0].scalar.value);
    try testing.expectEqualStrings("2", two.array[1].scalar.value);

    var triple = [_]Node{ n(.array, &a1), v(" "), n(.array, &a2), v(" "), n(.array, &a3) };
    const three = try build(gpa, n(.concat, &triple));
    try testing.expectEqual(@as(usize, 3), three.array.len);
    try testing.expectEqualStrings("3", three.array[2].scalar.value);

    var empty = [_]Node{};
    var with_empty = [_]Node{ n(.array, &a1), v(" "), n(.array, &empty) };
    const kept = try build(gpa, n(.concat, &with_empty));
    try testing.expectEqual(@as(usize, 1), kept.array.len);

    var outer1 = [_]Node{n(.array, &a1)};
    var outer2 = [_]Node{n(.array, &a2)};
    var nested = [_]Node{ n(.array, &outer1), v(" "), n(.array, &outer2) };
    const deep = try build(gpa, n(.concat, &nested));
    try testing.expectEqual(@as(usize, 2), deep.array.len);
    try testing.expectEqualStrings("1", deep.array[0].array[0].scalar.value);
    try testing.expectEqualStrings("2", deep.array[1].array[0].scalar.value);
}

// java ✓ · pyhocon ⚠️ · spec ✓ — a substitution cannot be joined into, so it
// stands as a part of its own and the lists around it stay apart. What it does
// *not* do is stop the joining: the run on each side of it is still one list.
//
//   'a = [1] ${x} [2]'          -> {"a":[1]${x}[2]}       three parts
//   'a = [1] [2] ${x} [3] [4]'  -> {"a":[1,2]${x}[3,4]}   three parts, not five
//
// Which is what makes the order matter and why the parts are a list rather than
// a set — resolve drops the middle one in place:
//
//   'x = [9], a = [1] [2] ${x} [3] [4]'  -> {"a":[1,2,9,3,4]}
//
// (pyhocon cannot print an unresolved substitution, so it is only comparable
// once resolved.)
test "value.a ref parts the lists around it without stopping them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var a1 = [_]Node{v("1")};
    var a2 = [_]Node{v("2")};
    var a3 = [_]Node{v("3")};
    var a4 = [_]Node{v("4")};
    var path = [_]Node{v("x")};
    const subst = n(.subst, &path);

    var single = [_]Node{ n(.array, &a1), v(" "), subst, v(" "), n(.array, &a2) };
    const p = try build(gpa, n(.concat, &single));
    try testing.expectEqual(@as(usize, 3), p.pending.len);
    try testing.expect(p.pending[0].value == .array);
    try testing.expect(p.pending[1].value == .ref);
    try testing.expect(p.pending[2].value == .array);
    try testing.expectEqual(@as(usize, 1), p.pending[0].value.array.len);
    try testing.expectEqualStrings("2", p.pending[2].value.array[0].scalar.value);

    var runs = [_]Node{
        n(.array, &a1), v(" "), n(.array, &a2), v(" "),
        subst,          v(" "), n(.array, &a3), v(" "),
        n(.array, &a4),
    };
    const q = try build(gpa, n(.concat, &runs));
    try testing.expectEqual(@as(usize, 3), q.pending.len);
    try testing.expectEqual(@as(usize, 2), q.pending[0].value.array.len);
    try testing.expectEqualStrings("1", q.pending[0].value.array[0].scalar.value);
    try testing.expectEqualStrings("2", q.pending[0].value.array[1].scalar.value);
    try testing.expect(q.pending[1].value == .ref);
    try testing.expectEqual(@as(usize, 2), q.pending[2].value.array.len);
    try testing.expectEqualStrings("3", q.pending[2].value.array[0].scalar.value);
    try testing.expectEqualStrings("4", q.pending[2].value.array[1].scalar.value);
}

// java ✓ · pyhocon ✓ · spec ✓ — text parts join with their gaps as characters:
//
//   'a = grumpy "wombat"' -> {"a":"grumpy wombat"}
//   'a = 1 " x"'          -> {"a":"1  x"}          gap plus a quoted space
//
// A text join only arises when a quoted part is involved — adjacent unquoted
// text is one slice already and never reaches a `.concat` — so the result is
// always quoted: '1 " x"' has stopped being a number.
test "value.text parts join, gaps and all" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var texts = [_]Node{ v("grumpy"), v(" "), v("\"wombat\"") };
    const text = try build(gpa, n(.concat, &texts));
    try testing.expectEqualStrings("grumpy wombat", text.scalar.value);
    try testing.expect(text.scalar.quoted);

    var spaced = [_]Node{ v("1"), v(" "), v("\" x\"") };
    const joined = try build(gpa, n(.concat, &spaced));
    try testing.expectEqualStrings("1  x", joined.scalar.value);
    try testing.expect(joined.scalar.quoted);
}

// java ✓ · pyhocon ✓ · spec ✓ — the last kind, and the only one that goes
// deeper than the surface: objects merge by key, and a key held by both sides
// merges again if both hold an object, otherwise the right one wins.
//
//   'a = {x=1} {y=2}'            -> {"a":{"x":1,"y":2}}
//   'a = {b=1, c=2} {c=3, d=4}'  -> {"a":{"b":1,"c":3,"d":4}}   c keeps its place
//   'a = {b={c=1}} {b={d=2}}'    -> {"a":{"b":{"c":1,"d":2}}}
//   'a = {b=[1]} {b=[2]}'        -> {"a":{"b":[2]}}             not [1,2]
//
// That last one is the difference from a concatenation worth keeping in view:
// two lists written next to each other join, the same two lists arriving under
// one key do not.
test "value.objects merge by key, recursively" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var m1 = [_]Node{ v("x"), v("1") };
    var m2 = [_]Node{ v("y"), v("2") };
    var b1 = [_]Node{n(.assignment, &m1)};
    var b2 = [_]Node{n(.assignment, &m2)};
    var objs = [_]Node{ n(.block, &b1), v(" "), n(.block, &b2) };
    const obj = try build(gpa, n(.concat, &objs));
    try testing.expectEqual(@as(usize, 2), obj.object.len);
    try testing.expectEqualStrings("x", obj.object[0].key.value);
    try testing.expectEqualStrings("y", obj.object[1].key.value);

    // a shared key keeps its position and takes the right-hand value
    var l1 = [_]Node{ v("b"), v("1") };
    var l2 = [_]Node{ v("c"), v("2") };
    var r1 = [_]Node{ v("c"), v("3") };
    var r2 = [_]Node{ v("d"), v("4") };
    var left = [_]Node{ n(.assignment, &l1), n(.assignment, &l2) };
    var right = [_]Node{ n(.assignment, &r1), n(.assignment, &r2) };
    var overlap = [_]Node{ n(.block, &left), v(" "), n(.block, &right) };
    const o = try build(gpa, n(.concat, &overlap));
    try testing.expectEqual(@as(usize, 3), o.object.len);
    try testing.expectEqualStrings("b", o.object[0].key.value);
    try testing.expectEqualStrings("c", o.object[1].key.value);
    try testing.expectEqualStrings("3", o.object[1].value.scalar.value);
    try testing.expectEqualStrings("d", o.object[2].key.value);

    // both sides an object under the same key: down one level
    var deep_l = [_]Node{ v("c"), v("1") };
    var deep_r = [_]Node{ v("d"), v("2") };
    var inner_l = [_]Node{n(.assignment, &deep_l)};
    var inner_r = [_]Node{n(.assignment, &deep_r)};
    var outer_l = [_]Node{ v("b"), n(.block, &inner_l) };
    var outer_r = [_]Node{ v("b"), n(.block, &inner_r) };
    var wrap_l = [_]Node{n(.assignment, &outer_l)};
    var wrap_r = [_]Node{n(.assignment, &outer_r)};
    var nested = [_]Node{ n(.block, &wrap_l), v(" "), n(.block, &wrap_r) };
    const d = try build(gpa, n(.concat, &nested));
    try testing.expectEqual(@as(usize, 1), d.object.len);
    try testing.expectEqual(@as(usize, 2), d.object[0].value.object.len);
    try testing.expectEqualStrings("c", d.object[0].value.object[0].key.value);
    try testing.expectEqualStrings("d", d.object[0].value.object[1].key.value);

    // anything but two objects: the right one wins outright, no joining
    var list_l = [_]Node{v("1")};
    var list_r = [_]Node{v("2")};
    var kl = [_]Node{ v("b"), n(.array, &list_l) };
    var kr = [_]Node{ v("b"), n(.array, &list_r) };
    var wl = [_]Node{n(.assignment, &kl)};
    var wr = [_]Node{n(.assignment, &kr)};
    var lists = [_]Node{ n(.block, &wl), v(" "), n(.block, &wr) };
    const w = try build(gpa, n(.concat, &lists));
    try testing.expectEqual(@as(usize, 1), w.object.len);
    try testing.expectEqual(@as(usize, 1), w.object[0].value.array.len);
    try testing.expectEqualStrings("2", w.object[0].value.array[0].scalar.value);
}

// java ✓ · pyhocon ⚠️ · spec ✓ — nothing has to stand between a substitution
// and the part next to it. Written with no gap they are still two parts, and
// the ref still cannot be joined into:
//
//   'a = ${x}"c"'    -> ${x}"c"        two parts, no gap to carry
//   'a = "c"${x}'    -> "c"${x}
//   'a = ${x}[1]'    -> ${x}[1]
//   'a = ${x}{b=1}'  -> ${x}{"b":1}
//
// Which resolve then joins with nothing added — 'x = 1' gives "1c", not "1 c",
// so the gap is never invented on the way out either.
//
// (pyhocon cannot print an unresolved substitution, so it is only comparable
// once resolved.)
test "value.a ref needs no gap to stand apart" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var px = [_]Node{v("x")};
    const sx = n(.subst, &px);
    var elems = [_]Node{v("1")};
    var m = [_]Node{ v("b"), v("1") };
    var assigns = [_]Node{n(.assignment, &m)};

    var after = [_]Node{ sx, v("\"c\"") };
    const a = try build(gpa, n(.concat, &after));
    try testing.expectEqual(@as(usize, 2), a.pending.len);
    try testing.expect(a.pending[0].value == .ref);
    try testing.expectEqualStrings("c", a.pending[1].value.scalar.value);

    var before = [_]Node{ v("\"c\""), sx };
    const b = try build(gpa, n(.concat, &before));
    try testing.expectEqual(@as(usize, 2), b.pending.len);
    try testing.expectEqualStrings("c", b.pending[0].value.scalar.value);
    try testing.expect(b.pending[1].value == .ref);

    var with_list = [_]Node{ sx, n(.array, &elems) };
    const l = try build(gpa, n(.concat, &with_list));
    try testing.expectEqual(@as(usize, 2), l.pending.len);
    try testing.expect(l.pending[0].value == .ref);
    try testing.expect(l.pending[1].value == .array);

    var with_block = [_]Node{ sx, n(.block, &assigns) };
    const o = try build(gpa, n(.concat, &with_block));
    try testing.expectEqual(@as(usize, 2), o.pending.len);
    try testing.expect(o.pending[0].value == .ref);
    try testing.expect(o.pending[1].value == .object);
}

// The parser never builds one — a `.concat` exists because there were parts to
// hold — but `fromNode` reads `values.items[0]` to decide what it is looking
// at, and on an empty list that is a read past the end rather than an error.
// A node arriving from anywhere but `parseValue` has to come back as an error.
test "value.an empty concatenation is an error, not an index out of range" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var none = [_]Node{};
    try testing.expectError(
        Error.UnsupportedConcatenation,
        build(gpa, n(.concat, &none)),
    );
}

// java ✓ · pyhocon ✓ · spec ✓ — 'Cannot concatenate object or list with a
// non-object-or-list' comes out of java at *parse* time; 'a = 1 [2]' never
// gets as far as resolve. The gap between the parts does not soften the pair:
// in '{b=1} "s"' the object stands against the string, the space belongs to
// neither.
test "value.mixing containers with anything else fails at load" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var elems = [_]Node{v("2")};
    var m = [_]Node{ v("b"), v("1") };
    var assigns = [_]Node{n(.assignment, &m)};
    const array = n(.array, &elems);
    const block = n(.block, &assigns);

    var path = [_]Node{v("x")};
    const subst = n(.subst, &path);

    var scalar_array = [_]Node{ v("1"), v(" "), array };
    var array_block = [_]Node{ array, v(" "), block };
    var block_scalar = [_]Node{ block, v(" "), v("\"s\"") };
    // 'a = "1" [2] ${x}' — the ref defers nothing here, the pair before it is
    // already adjacent and already wrong.
    var before_ref = [_]Node{ v("\"1\""), v(" "), array, v(" "), subst };
    for ([_][]Node{ &scalar_array, &array_block, &block_scalar, &before_ref }) |parts| {
        try testing.expectError(
            Error.UnsupportedConcatenation,
            build(gpa, n(.concat, parts)),
        );
    }
}

// java ✓ · pyhocon ⚠️ · spec ✓ — a gap is a part like any other and follows
// the same rules, so what happens to it falls out of its neighbours. Java
// prints the unresolved forms, which is the shape this has to load as:
//
//   'a = ${x} ${y}'    -> ${x}" "${y}     alone: nothing to join it to
//   'a = ${x} "c"'     -> ${x}" c"        joined into the scalar on its right
//   'a = "c" ${x}'     -> "c "${x}        and into the one on its left
//   'a = [1] ${x}'     -> [1]${x}         gone: a list has no use for it
//   'a = ${x} {b=1}'   -> ${x}{"b":1}     nor an object
//
// So it survives only where a text join is still possible, and its width
// survives with it — 'a = ${x}   ${y}' resolves to "1   2" against x=1, y=2,
// which nothing downstream could reconstruct once the gap is dropped.
//
// (pyhocon cannot print an unresolved substitution, so it is only comparable
// once resolved.)
test "value.a gap lives or dies by its neighbours" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var px = [_]Node{v("x")};
    var py = [_]Node{v("y")};
    const sx = n(.subst, &px);
    const sy = n(.subst, &py);

    // between two refs it has nowhere to go, so it stands alone
    var alone = [_]Node{ sx, v(" "), sy };
    const a = try build(gpa, n(.concat, &alone));
    try testing.expectEqual(@as(usize, 3), a.pending.len);
    try testing.expect(a.pending[0].value == .ref);
    try testing.expectEqualStrings(" ", a.pending[1].value.scalar.value);
    try testing.expect(a.pending[2].value == .ref);

    // next to text it is a character of that text, from either side
    var right = [_]Node{ sx, v(" "), v("\"c\"") };
    const r = try build(gpa, n(.concat, &right));
    try testing.expectEqual(@as(usize, 2), r.pending.len);
    try testing.expect(r.pending[0].value == .ref);
    try testing.expectEqualStrings(" c", r.pending[1].value.scalar.value);

    var left = [_]Node{ v("\"c\""), v(" "), sx };
    const l = try build(gpa, n(.concat, &left));
    try testing.expectEqual(@as(usize, 2), l.pending.len);
    try testing.expectEqualStrings("c ", l.pending[0].value.scalar.value);
    try testing.expect(l.pending[1].value == .ref);

    // next to a container it is a separator and disappears
    var elems = [_]Node{v("1")};
    var with_list = [_]Node{ n(.array, &elems), v(" "), sx };
    const wl = try build(gpa, n(.concat, &with_list));
    try testing.expectEqual(@as(usize, 2), wl.pending.len);
    try testing.expect(wl.pending[0].value == .array);
    try testing.expect(wl.pending[1].value == .ref);

    var m = [_]Node{ v("b"), v("1") };
    var assigns = [_]Node{n(.assignment, &m)};
    var with_block = [_]Node{ sx, v(" "), n(.block, &assigns) };
    const wb = try build(gpa, n(.concat, &with_block));
    try testing.expectEqual(@as(usize, 2), wb.pending.len);
    try testing.expect(wb.pending[0].value == .ref);
    try testing.expect(wb.pending[1].value == .object);
}

// java ✓ · pyhocon ✓ · spec ✓ — a key written twice inside one block is one
// member, and the rule under it is the merge rule, not the concatenation one:
//
//   'a = {b=1, b=2}'          -> {"a":{"b":2}}
//   'a = {b=1, c=2, b=3}'     -> {"a":{"b":3,"c":2}}     b keeps its place
//   'a = {b={x=1}, b={y=2}}'  -> {"a":{"b":{"x":1,"y":2}}}
//   'a = {b=[1], b=[2]}'      -> {"a":{"b":[2]}}         not [1,2]
//   'a = {b={x=1}, b=2}'      -> {"a":{"b":2}}
//
// Two lists written next to each other join; the same two arriving under one
// key do not. That is the whole difference between the two operations, and it
// is why this cannot be `update`.
test "value.a key written twice in one block is one member" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var d1 = [_]Node{ v("b"), v("1") };
    var d2 = [_]Node{ v("b"), v("2") };
    var dup = [_]Node{ n(.assignment, &d1), n(.assignment, &d2) };
    const one = try build(gpa, n(.block, &dup));
    try testing.expectEqual(@as(usize, 1), one.object.len);
    try testing.expectEqualStrings("b", one.object[0].key.value);
    try testing.expectEqualStrings("2", one.object[0].value.scalar.value);

    // the surviving member keeps the position of the first spelling
    var o1 = [_]Node{ v("b"), v("1") };
    var o2 = [_]Node{ v("c"), v("2") };
    var o3 = [_]Node{ v("b"), v("3") };
    var ordered = [_]Node{ n(.assignment, &o1), n(.assignment, &o2), n(.assignment, &o3) };
    const ord = try build(gpa, n(.block, &ordered));
    try testing.expectEqual(@as(usize, 2), ord.object.len);
    try testing.expectEqualStrings("b", ord.object[0].key.value);
    try testing.expectEqualStrings("3", ord.object[0].value.scalar.value);
    try testing.expectEqualStrings("c", ord.object[1].key.value);

    // both sides an object: down one level
    var ix = [_]Node{ v("x"), v("1") };
    var iy = [_]Node{ v("y"), v("2") };
    var bx = [_]Node{n(.assignment, &ix)};
    var by = [_]Node{n(.assignment, &iy)};
    var n1 = [_]Node{ v("b"), n(.block, &bx) };
    var n2 = [_]Node{ v("b"), n(.block, &by) };
    var nested = [_]Node{ n(.assignment, &n1), n(.assignment, &n2) };
    const deep = try build(gpa, n(.block, &nested));
    try testing.expectEqual(@as(usize, 1), deep.object.len);
    try testing.expectEqual(@as(usize, 2), deep.object[0].value.object.len);
    try testing.expectEqualStrings("x", deep.object[0].value.object[0].key.value);
    try testing.expectEqualStrings("y", deep.object[0].value.object[1].key.value);

    // anything else: the right one wins outright, lists included
    var e1 = [_]Node{v("1")};
    var e2 = [_]Node{v("2")};
    var l1 = [_]Node{ v("b"), n(.array, &e1) };
    var l2 = [_]Node{ v("b"), n(.array, &e2) };
    var lists = [_]Node{ n(.assignment, &l1), n(.assignment, &l2) };
    const won = try build(gpa, n(.block, &lists));
    try testing.expectEqual(@as(usize, 1), won.object.len);
    try testing.expectEqual(@as(usize, 1), won.object[0].value.array.len);
    try testing.expectEqualStrings("2", won.object[0].value.array[0].scalar.value);
}

// `a.b += 1` loads as `b = ${?a.b} [1]` under `a`: the ref carries the whole
// path down to the member, the include's scope in front, so it can be told
// apart from a plain `${?b}` and looked up from the root.
test "value.+= is an optional self-reference and a one-element list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var inner = [_]Node{ v("b"), v("1") };
    var appends = [_]Node{n(.append, &inner)};
    var outer = [_]Node{ v("a"), n(.block, &appends) };
    var members = [_]Node{n(.assignment, &outer)};
    const scope = [_]Key{.{ .value = "inc" }};
    const o = try Value.fromNode(gpa, n(.block, &members), .{ .scope = &scope });

    const parts = o.object[0].value.object[0].value.pending;
    try testing.expectEqual(@as(usize, 2), parts.len);
    const r = parts[0].value.ref;
    try testing.expect(r.optional);
    try testing.expectEqual(@as(u16, 1), r.scope_len);
    try testing.expectEqual(@as(usize, 3), r.path.len);
    for ([_][]const u8{ "inc", "a", "b" }, r.path) |want, got| try testing.expectEqualStrings(want, got.value);
    try testing.expectEqualStrings("1", parts[1].value.array[0].scalar.value);
}

// java ✓ · pyhocon ✓ · spec ✓ — a dot inside quotes is a character of one key,
// a dot outside them separates two. The oracle answers by resolving, since only
// a matching key proves how the path was cut:
//
//   'x { "y.z" = 1 }, a = ${x."y.z"}'  -> {"a":1}    two elements: x, y.z
//   'x { y = { z = 1 } }, a = ${x.y.z}'-> {"a":1}    three: x, y, z
//   '"a.b" = 1, r = ${"a.b"}'          -> {"r":1}    one: a.b
//
// Which is why the split has to run on the text as written and unquote each
// piece afterwards. Unquoting first throws away the only thing that says which
// dot was which, and no later pass can recover it. The parser leaves the two
// spellings distinguishable for exactly this reason: `${x."y.z"}` arrives as a
// concat of `x.` and `"y.z"`, `${x.y.z}` as one text part.
test "ref.a quoted dot is a character, not a separator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var plain = [_]Node{v("x.y")};
    const p = try build(gpa, n(.subst, &plain));
    try testing.expectEqual(@as(usize, 2), p.ref.path.len);
    try testing.expectEqualStrings("x", p.ref.path[0].value);
    try testing.expectEqualStrings("y", p.ref.path[1].value);

    var parts = [_]Node{ v("x."), v("\"y.z\"") };
    var quoted_tail = [_]Node{n(.concat, &parts)};
    const q = try build(gpa, n(.subst, &quoted_tail));
    try testing.expectEqual(@as(usize, 2), q.ref.path.len);
    try testing.expectEqualStrings("x", q.ref.path[0].value);
    try testing.expectEqualStrings("y.z", q.ref.path[1].value);

    var whole = [_]Node{v("\"a.b\"")};
    const w = try build(gpa, n(.subst, &whole));
    try testing.expectEqual(@as(usize, 1), w.ref.path.len);
    try testing.expectEqualStrings("a.b", w.ref.path[0].value);

    var single = [_]Node{v("x")};
    const one = try build(gpa, n(.subst, &single));
    try testing.expectEqual(@as(usize, 1), one.ref.path.len);
    try testing.expectEqualStrings("x", one.ref.path[0].value);

    // A segment stays open across the part boundary, so a part beginning with a
    // dot closes the one before it rather than adding an empty one of its own.
    // Every path below resolves in java against a config holding exactly the
    // key it names, which is what proves where the cuts fell:
    //
    //   'a { "b.c" { d = 1 } }, r = ${a."b.c".d}'    -> {"r":1}   three elements
    //   'a { b = 1 }, r = ${"a"."b"}'                -> {"r":1}   two, the dot alone
    //   '"a.b" { c = 1 }, r = ${"""a.b""".c}'          -> {"r":1}   two, triple-quoted
    //   'a { "" { b = 1 } }, r = ${a."".b}'          -> {"r":1}   an empty one is legal
    var p1 = [_]Node{ v("a."), v("\"b.c\""), v(".d") };
    var p2 = [_]Node{ v("\"a\""), v("."), v("\"b\"") };
    var p3 = [_]Node{ v("\"\"\"a.b\"\"\""), v(".c") };
    var p4 = [_]Node{ v("a."), v("\"\""), v(".b") };
    // and with no dot between them the parts are one element, not two:
    //   'ab = 1, r = ${a"b"}'  -> {"r":1}
    var p5 = [_]Node{ v("a"), v("\"b\"") };
    const want = [_][]const []const u8{
        &.{ "a", "b.c", "d" },
        &.{ "a", "b" },
        &.{ "a.b", "c" },
        &.{ "a", "", "b" },
        &.{"ab"},
    };
    for ([_][]Node{ &p1, &p2, &p3, &p4, &p5 }, want, 0..) |path_parts, expected, i| {
        errdefer std.debug.print("failed on path {d}\n", .{i});
        var child = [_]Node{n(.concat, path_parts)};
        const r = try build(gpa, n(.subst, &child));
        try testing.expectEqual(expected.len, r.ref.path.len);
        for (expected, r.ref.path) |e, got| try testing.expectEqualStrings(e, got.value);
    }
}

// java ✓ · pyhocon ⚠️ · spec ✓ — an element made of several parts is one key
// at load, the way `Key.fromNode` already joins it:
//
//   'a"b" = 1'    -> {"ab":1}       '"a" b = c'  -> {"a b":"c"}
//
// Such keys reach here routinely now that the parser splits `a"b".c` into
// elements, so a `concat` key node is a member like any other. pyhocon rejects
// the mixed spelling (see tools/oracle/README.md).
test "value.a key made of several parts is one member" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var glued = [_]Node{ v("a"), v("\"b\"") };
    var m1 = [_]Node{ n(.concat, &glued), v("1") };
    var spaced = [_]Node{ v("\"a\""), v(" "), v("b") };
    var m2 = [_]Node{ n(.concat, &spaced), v("c") };
    var members = [_]Node{ n(.assignment, &m1), n(.assignment, &m2) };
    const o = try build(gpa, n(.block, &members));
    try testing.expectEqual(@as(usize, 2), o.object.len);
    try testing.expectEqualStrings("ab", o.object[0].key.value);
    try testing.expectEqualStrings("a b", o.object[1].key.value);
    try testing.expectEqualStrings("c", o.object[1].value.scalar.value);
}

// java ✓ · pyhocon ⚠️ · spec ✓ — the empty element java calls BadPath, on a path
// inside `${…}`. Quotes make the same difference they make on the key side: an
// empty element is legal only when it is written as `""`.
//
//   'a = ${.b}'      -> ERROR BadPath      'a = ${"b".}'  -> ERROR BadPath
//   'a = ${b.}'      -> ERROR BadPath      'a = ${."b"}'  -> ERROR BadPath
//   'a = ${b..c}'    -> ERROR BadPath
//   'a = ${"".b}'    -> {"a":${"".b}}      'a = ${b.""}'  -> {"a":${b.""}}
//
// The two legal ones resolve in java against exactly the key they name:
// 'resolve:"" { b = 1 }\na = ${"".b}' -> {"":{"b":1},"a":1}. pyhocon cannot
// parse a quoted path element at all, so it is not comparable here.
//
// The parser still lets these through (its own `substitution` table says so),
// so the ref is where they have to stop: the same splitter that cuts the path
// is the one that knows an element came out empty without quotes to say so.
test "ref.an unquoted empty element is a BadPath" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var b1 = [_]Node{v(".b")};
    var b2 = [_]Node{v("b.")};
    var b3 = [_]Node{v("b..c")};
    var b4 = [_]Node{ v("\"b\""), v(".") };
    var b5 = [_]Node{ v("."), v("\"b\"") };
    for ([_][]Node{ &b1, &b2, &b3, &b4, &b5 }, 0..) |path_parts, i| {
        errdefer std.debug.print("failed on bad path {d}\n", .{i});
        var child = [_]Node{n(.concat, path_parts)};
        try testing.expectError(Error.MalformedKey, build(gpa, n(.subst, &child)));
    }

    // Written as `""`, the empty element is an element like any other.
    var ok1 = [_]Node{ v("\"\""), v(".b") };
    var ok2 = [_]Node{ v("b."), v("\"\"") };
    const want = [_][]const []const u8{ &.{ "", "b" }, &.{ "b", "" } };
    for ([_][]Node{ &ok1, &ok2 }, want, 0..) |path_parts, expected, i| {
        errdefer std.debug.print("failed on legal path {d}\n", .{i});
        var child = [_]Node{n(.concat, path_parts)};
        const r = try build(gpa, n(.subst, &child));
        try testing.expectEqual(expected.len, r.ref.path.len);
        for (expected, r.ref.path) |e, got| try testing.expectEqualStrings(e, got.value);
    }
}

// java ✓ · pyhocon ⚠️ · spec ✓ — a pending value is not only a thing a member
// holds; it is a value, so it stands wherever one may:
//
//   'a = [${x}]'            -> {"a":[${x}]}          a ref as an element
//   'a = [ ${x} [1] ]'      -> {"a":[${x}[1]]}       a pending as an element
//   'a = { b = ${x} [1] }'  -> {"a":{"b":${x}[1]}}   and as a member value
//
// Nothing collapses on the way out: the list keeps one element and the object
// one member, each holding the unresolved thing whole.
//
// (pyhocon cannot print an unresolved substitution, so it is only comparable
// once resolved.)
test "value.a ref or a pending stands inside a container too" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var px = [_]Node{v("x")};
    const sx = n(.subst, &px);
    var e1 = [_]Node{v("1")};

    var elems = [_]Node{sx};
    const arr = try build(gpa, n(.array, &elems));
    try testing.expectEqual(@as(usize, 1), arr.array.len);
    try testing.expect(arr.array[0] == .ref);

    var inner = [_]Node{ sx, v(" "), n(.array, &e1) };
    var wrapped = [_]Node{n(.concat, &inner)};
    const nested = try build(gpa, n(.array, &wrapped));
    try testing.expectEqual(@as(usize, 1), nested.array.len);
    try testing.expectEqual(@as(usize, 2), nested.array[0].pending.len);
    try testing.expect(nested.array[0].pending[0].value == .ref);
    try testing.expect(nested.array[0].pending[1].value == .array);

    var member = [_]Node{ v("b"), n(.concat, &inner) };
    var members = [_]Node{n(.assignment, &member)};
    const obj = try build(gpa, n(.block, &members));
    try testing.expectEqual(@as(usize, 1), obj.object.len);
    try testing.expectEqualStrings("b", obj.object[0].key.value);
    try testing.expectEqual(@as(usize, 2), obj.object[0].value.pending.len);
    try testing.expect(obj.object[0].value.pending[0].value == .ref);
}

// java ✓ · pyhocon ⚠️ · spec ✓ — `${?x}` parts a concatenation exactly as
// `${x}` does; the difference is what resolution does with it, so the flag has
// to survive the load:
//
//   'a = ${?x} [1]'            -> {"a":${?x}[1]}
//   'resolve: a = ${?x} "y"'   -> {"a":" y"}     missing: contributes nothing,
//                                                but the gap beside it stays
//   'resolve: a = 1 ${?x} 2'   -> {"a":"1  2"}   both gaps survive
//   'resolve: a = ${?x}, b=1'  -> {"b":1}        alone: the member goes too
//
// That last line is why this is its own kind rather than a flag on the value:
// an unresolved optional removes the member it belongs to, which nothing but
// the member itself can do.
test "value.an optional substitution parts a concatenation like any ref" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var px = [_]Node{v("x")};
    var e1 = [_]Node{v("1")};
    var parts = [_]Node{ n(.subst_optional, &px), v(" "), n(.array, &e1) };
    const p = try build(gpa, n(.concat, &parts));
    try testing.expectEqual(@as(usize, 2), p.pending.len);
    try testing.expect(p.pending[0].value == .ref);
    try testing.expect(p.pending[0].value.ref.optional);
    try testing.expect(p.pending[1].value == .array);

    // and between two texts the gap is still a part of its own
    var texts = [_]Node{ v("1"), v(" "), n(.subst_optional, &px), v(" "), v("2") };
    const t = try build(gpa, n(.concat, &texts));
    try testing.expectEqual(@as(usize, 3), t.pending.len);
    try testing.expectEqualStrings("1 ", t.pending[0].value.scalar.value);
    try testing.expect(t.pending[1].value.ref.optional);
    try testing.expectEqualStrings(" 2", t.pending[2].value.scalar.value);
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

// java ✓ · pyhocon ✓ · spec ✓ — an empty *quoted* string is a value, not a
// gap, and the gap beside it is still a character:
//
//   'a = "" [1]'  -> WrongType     the same as '"x" [1]'
//   'a = [1] ""'  -> WrongType
//   'a = "" "x"'  -> {"a":" x"}    the gap between them survives
//
// Which is the whole reason `isGap` asks about the delimiter rather than only
// trimming: `[1] " " [2]` is an error where `[1]   [2]` is [1,2].
test "value.an empty quoted string is a value, not a gap" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var e1 = [_]Node{v("1")};
    var after = [_]Node{ v("\"\""), v(" "), n(.array, &e1) };
    var before = [_]Node{ n(.array, &e1), v(" "), v("\"\"") };
    var spaced = [_]Node{ n(.array, &e1), v(" "), v("\" \""), v(" "), n(.array, &e1) };
    for ([_][]Node{ &after, &before, &spaced }) |parts| {
        try testing.expectError(
            Error.UnsupportedConcatenation,
            build(gpa, n(.concat, parts)),
        );
    }

    var texts = [_]Node{ v("\"\""), v(" "), v("\"x\"") };
    const t = try build(gpa, n(.concat, &texts));
    try testing.expectEqualStrings(" x", t.scalar.value);
}

// java ✓ · pyhocon ✓ · spec ✓ — an empty container is a part like any other
// and contributes nothing:
//
//   'a = [] [1]'       -> {"a":[1]}
//   'a = {} {b=1}'     -> {"a":{"b":1}}
//   'a = {b=1} {}'     -> {"a":{"b":1}}
//   'a = {} {}'        -> {"a":{}}
//   'a = {} [1]'       -> WrongType      empty or not, a kind is a kind
test "value.an empty container joins without adding anything" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var none = [_]Node{};
    var e1 = [_]Node{v("1")};
    var m = [_]Node{ v("b"), v("1") };
    var assigns = [_]Node{n(.assignment, &m)};

    var lists = [_]Node{ n(.array, &none), v(" "), n(.array, &e1) };
    const l = try build(gpa, n(.concat, &lists));
    try testing.expectEqual(@as(usize, 1), l.array.len);

    var left_empty = [_]Node{ n(.block, &none), v(" "), n(.block, &assigns) };
    const le = try build(gpa, n(.concat, &left_empty));
    try testing.expectEqual(@as(usize, 1), le.object.len);
    try testing.expectEqualStrings("b", le.object[0].key.value);

    var right_empty = [_]Node{ n(.block, &assigns), v(" "), n(.block, &none) };
    const re = try build(gpa, n(.concat, &right_empty));
    try testing.expectEqual(@as(usize, 1), re.object.len);

    var both = [_]Node{ n(.block, &none), v(" "), n(.block, &none) };
    const b = try build(gpa, n(.concat, &both));
    try testing.expectEqual(@as(usize, 0), b.object.len);

    var crossed = [_]Node{ n(.block, &none), v(" "), n(.array, &e1) };
    try testing.expectError(
        Error.UnsupportedConcatenation,
        build(gpa, n(.concat, &crossed)),
    );
}

// java ✓ · pyhocon ✓ · spec ✓ — a triple-quoted part joins like any other, and
// what is inside it stays as it was written:
//
//   'a = """a""" "b"'     -> {"a":"a b"}
//   'a = """a\nb""" "c"'  -> {"a":"a\nb c"}   a real newline, not a backslash
//   'a = x """y"""'       -> {"a":"x y"}
//
// The escapes were already decided by the delimiter when the part was read, so
// the join is a plain append — anything cleverer here would process them twice.
test "value.a multi-line part joins without reprocessing it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var simple = [_]Node{ v("\"\"\"a\"\"\""), v(" "), v("\"b\"") };
    const s1 = try build(gpa, n(.concat, &simple));
    try testing.expectEqualStrings("a b", s1.scalar.value);
    try testing.expect(s1.scalar.quoted);

    // inside """ a backslash-n is those two characters; the quoted part beside
    // it turns its own into a newline, and both survive the join as they are
    var mixed = [_]Node{ v("\"\"\"a\\nb\"\"\""), v(" "), v("\"c\\nd\"") };
    const s2 = try build(gpa, n(.concat, &mixed));
    try testing.expectEqualStrings("a\\nb c\nd", s2.scalar.value);

    var leading = [_]Node{ v("x"), v(" "), v("\"\"\"y\"\"\"") };
    const s3 = try build(gpa, n(.concat, &leading));
    try testing.expectEqualStrings("x y", s3.scalar.value);
}

// java ✓ · pyhocon ✓ · spec ✓ — the remaining shapes, each a one-liner:
//
//   'a = [1]\t[2]'          -> {"a":[1,2]}          a tab separates too
//   'a = {b=1}\t{c=2}'      -> {"a":{"b":1,"c":2}}
//   'a = {a=1} {b=2} {a=3}'  -> {"a":{"a":3,"b":2}}  a key met twice, not adjacent
test "value.tabs separate, and a key can be met more than twice" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var e1 = [_]Node{v("1")};
    var e2 = [_]Node{v("2")};
    var tabbed = [_]Node{ n(.array, &e1), v("\t"), n(.array, &e2) };
    const t = try build(gpa, n(.concat, &tabbed));
    try testing.expectEqual(@as(usize, 2), t.array.len);

    var k1 = [_]Node{ v("a"), v("1") };
    var k2 = [_]Node{ v("b"), v("2") };
    var k3 = [_]Node{ v("a"), v("3") };
    var b1 = [_]Node{n(.assignment, &k1)};
    var b2 = [_]Node{n(.assignment, &k2)};
    var b3 = [_]Node{n(.assignment, &k3)};
    var three = [_]Node{ n(.block, &b1), v(" "), n(.block, &b2), v(" "), n(.block, &b3) };
    const o = try build(gpa, n(.concat, &three));
    try testing.expectEqual(@as(usize, 2), o.object.len);
    try testing.expectEqualStrings("a", o.object[0].key.value);
    try testing.expectEqualStrings("3", o.object[0].value.scalar.value);
    try testing.expectEqualStrings("b", o.object[1].key.value);
}

// ---------------------------------------------------------------------------
// Resolve — from text, since a ref only means something in a whole document.
// One test per branch of `resolveValue`, small enough to step through.
// ---------------------------------------------------------------------------

/// Parses `src`, resolves it and compares the result printed as JSON.
fn expectResolved(src: [:0]const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var parser = Ast.Parser{ .gpa = gpa, .t = .{ .t = @import("Tokenizer.zig").Tokenizer.init(src) } };
    var root = try build(gpa, try parser.parse());
    var err_pos: ?Value.Pos = null;
    try root.resolve(gpa, &err_pos);
    try testing.expectEqualStrings(expected, try std.json.Stringify.valueAlloc(gpa, root, .{}));
}

fn expectResolveError(src: [:0]const u8, expected: anyerror) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var parser = Ast.Parser{ .gpa = gpa, .t = .{ .t = @import("Tokenizer.zig").Tokenizer.init(src) } };
    var root = try build(gpa, try parser.parse());
    var err_pos: ?Value.Pos = null;
    try testing.expectError(expected, root.resolve(gpa, &err_pos));
}

// java ✓ · pyhocon ✓ · spec ✓ — `.ref`: the whole finished document is looked
// at, so the later `x = 2` wins even for `a`, written before it.
test "resolve.a ref takes the last value of its target" {
    try expectResolved("x = 1\na = ${x}\nx = 2", "{\"x\":2,\"a\":2}");
}

// java ✓ · pyhocon ✓ · spec ✓ — `lookup`: a path steps into objects.
test "resolve.a path steps into objects" {
    try expectResolved("o { p = 3 }\nb = ${o.p}", "{\"o\":{\"p\":3},\"b\":3}");
}

// java ✓ · pyhocon ✓ · spec ✓ — `resolveTarget`: `c` needs `b`, which needs `a`;
// each is resolved before it is copied, and stored back on the way.
test "resolve.refs chain" {
    try expectResolved("c = ${b}\nb = ${a}\na = 1", "{\"c\":1,\"b\":1,\"a\":1}");
}

// java ✓ · pyhocon ✓ · spec ✓ — `lookup` meets a ref on the way: `a` has to
// become an object before `.p` can be found in it.
test "resolve.a path through a ref" {
    try expectResolved("c { p = 5 }\na = ${c}\nb = ${a.p}", "{\"c\":{\"p\":5},\"a\":{\"p\":5},\"b\":5}");
}

// java ✓ · pyhocon ✓ · spec ✓ — `.pending`: the parts around a ref join once
// it has a value, text into text, lists into one list.
test "resolve.pending parts join" {
    try expectResolved("x = 2\nd = ${x}\" ducks in a row\"", "{\"x\":2,\"d\":\"2 ducks in a row\"}");
    try expectResolved("x = [2]\nl = [1] ${x} [3]", "{\"x\":[2],\"l\":[1,2,3]}");
}

// concatenation-whitespace-and-substitutions/005-006 · java ✓ · pyhocon ⚠️ · spec ✓
// — any whitespace between two lists is a gap, NBSP and BOM included:
//   'x = [1]\ny = [2]\na = ${x}<NBSP>${y}' -> {"a":[1,2],…} on java; pyhocon
// rejects the NBSP as a token and the BOM as a WrongType.
test "resolve.any whitespace between lists is a gap" {
    try expectResolved("x = [1]\ny = [2]\na = ${x}\u{a0}${y}", "{\"x\":[1],\"y\":[2],\"a\":[1,2]}");
    try expectResolved("x = [1]\ny = [2]\na = ${x}\u{feff}${y}", "{\"x\":[1],\"y\":[2],\"a\":[1,2]}");
}

// java ✓ · pyhocon ✓ · spec ✓ — `${?x}` with nothing behind it is null from
// `resolveValue`: the member or element is dropped, not set to null.
test "resolve.an undefined optional removes what it stands in" {
    try expectResolved("a = ${?nope}\nb = 1", "{\"b\":1}");
    try expectResolved("l = [1, ${?nope}, 2]", "{\"l\":[1,2]}");
}

// S13.18 · java ⚠️ · pyhocon ⚠️ · spec ✓ — inside a concatenation the undefined
// optional is empty and the rest is still a concatenation, so a string. Both
// oracles give the number 42 (suite: substitutions/039).
test "resolve.an undefined optional in a concatenation leaves a string" {
    try expectResolved("a = ${?nope}42", "{\"a\":\"42\"}");
}

// java ✓ · pyhocon ✓ · spec ✓ — a required ref with nothing behind it.
test "resolve.a missing target is an error" {
    try expectResolveError("a = ${nope}", error.Unresolved);
    try expectResolveError("o { p = 1 }\na = ${o.q}", error.Unresolved);
}

// java ✓ · pyhocon ⚠️ · spec ✓ — `visiting`: a ref back to a place still being
// resolved never ends. pyhocon catches the first, overflows its stack on the second.
// `a = ${a}` is not one: it looks back at nothing (see the self-reference tables).
test "resolve.a cycle is an error" {
    try expectResolveError("a = ${b}\nb = ${a}", error.SubstitutionCycle);
    try expectResolveError("a { b = ${a} }", error.SubstitutionCycle);
}

/// Runs a table of documents through parse, load and resolve; a row renders as
/// the resolved document printed as JSON, and a `.bad` row must fail on the way.
fn expectAllResolved(cases: []const table.Case) !void {
    return table.expectAll(cases, .{ .dump = struct {
        fn dump(gpa: std.mem.Allocator, src: [:0]const u8) anyerror![]u8 {
            var parser = Ast.Parser{ .gpa = gpa, .t = .{ .t = Tokenizer.Tokenizer.init(src) } };
            var root = try build(gpa, try parser.parse());
            var err_pos: ?Value.Pos = null;
            try root.resolve(gpa, &err_pos);
            return std.json.Stringify.valueAlloc(gpa, root, .{});
        }
    }.dump });
}

// A key written again with a ref or a pending is a stack, not a replacement:
// what the ref resolves to decides whether it merges with what was below, or
// whether it is there to look back at. An object on top of one goes on the stack
// too; text or a list on top replaces it all, never to be looked at.
test "value.a ref on a repeated key stacks on what was there" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var px = [_]Node{v("x")};
    var e1 = [_]Node{v("1")};
    var m = [_]Node{ v("b"), v("1") };
    var assigns = [_]Node{n(.assignment, &m)};

    // a = [1], a = ${x}, a = {b = 1}, a = {b = 1}: three layers, the two objects one
    var l1 = [_]Node{ v("a"), n(.array, &e1) };
    var l2 = [_]Node{ v("a"), n(.subst, &px) };
    var l3 = [_]Node{ v("a"), n(.block, &assigns) };
    var stacked = [_]Node{ n(.assignment, &l1), n(.assignment, &l2), n(.assignment, &l3), n(.assignment, &l3) };
    const s = try build(gpa, n(.block, &stacked));
    try testing.expectEqual(@as(usize, 1), s.object.len);
    const layers = s.object[0].value.stack;
    try testing.expectEqual(@as(usize, 3), layers.len);
    try testing.expect(layers[0] == .array);
    try testing.expect(layers[1] == .ref);
    try testing.expect(layers[2] == .object);

    // and text on top hides the lot
    var l4 = [_]Node{ v("a"), v("42") };
    var hidden = [_]Node{ n(.assignment, &l2), n(.assignment, &l3), n(.assignment, &l4) };
    const h = try build(gpa, n(.block, &hidden));
    try testing.expectEqualStrings("42", h.object[0].value.scalar.value);
}

// java ✓ · pyhocon ✓ · spec ✓ — a self-reference sees the value below it in the
// stack, also through a path and inside a concatenation, and it is memoised per
// `${…}`, not per path: the two `${a}` below resolve to x and to xy.
test "resolve.a self-reference looks below" {
    try expectAllResolved(&.{
        .ok("mood = \"grumpy\"\nmood = ${mood}\" wombat\"", "{\"mood\":\"grumpy wombat\"}"),
        .ok("a = [1]\na = ${a} [2]", "{\"a\":[1,2]}"),
        .ok("a = { b = 1 }\na = ${a}", "{\"a\":{\"b\":1}}"),
        .ok("a = x\na = ${a}y\nb = ${a}", "{\"a\":\"xy\",\"b\":\"xy\"}"),
        .ok("a = { b = { c = 1 } }\na = ${a.b}\na = { b = 2 }", "{\"a\":{\"b\":2,\"c\":1}}"),
        // the stack of a nested key, and a list that replaces it
        .ok("a = { b = ${?a.b} [2], b = [1] }", "{\"a\":{\"b\":[1]}}"),
    });
}

// java ✓ · pyhocon ⚠️ · spec ✓ — with nothing below, a self-reference is
// undefined, not a cycle: an optional one disappears, a required one is an
// error, and an optional cycle through two fields leaves neither. pyhocon calls
// the optional two-field cycle a cycle; on `a = [${a}]` below an optional it
// overflows its stack, where java and this say cycle — a list is not a
// self-referential field (spec).
test "resolve.a self-reference with nothing below is undefined" {
    try expectAllResolved(&.{
        .ok("a = ${?a}", "{}"),
        .ok("a = ${?a}tea", "{\"a\":\"tea\"}"),
        .ok("a = ${?b}\nb = ${?a}", "{}"),
        .bad("a = ${a}"),
        .bad("a = ${a}\na = { b = 1 }"),
        .bad("a = [${a}]\na = ${?a}"),
    });
}

// java ✓ · pyhocon ✓ · spec ✓ — an undefined optional on top leaves what was
// below it, and that is then evaluated: the second row fails on `${nope}`.
test "resolve.an undefined optional keeps what was below" {
    try expectAllResolved(&.{
        .ok("a = 1\na = ${?nope}", "{\"a\":1}"),
        .bad("a = [${nope}]\na = ${?nope}"),
    });
}

// java ⚠️ · pyhocon ✓ (⚠️ hangs on the third) · spec ✓ — a `null` in a stack
// hides what is below it at its own key only, also when the key is reached
// through a substitution. java carries the null along and drops `y`
// (lightbend/config#864; suite duplicate-keys-and-object-merging/010-016).
test "resolve.null stops a merge only at its own key" {
    try expectAllResolved(&.{
        .ok("v = { x = 1 }\nr = null\nr = ${v}\na = { y = 0 }\na = ${r}", "{\"v\":{\"x\":1},\"r\":{\"x\":1},\"a\":{\"y\":0,\"x\":1}}"),
        .ok("v = { n = { old = 2 }, n = null, n = { x = 1 } }\na = { n = { y = 0 } }\na = ${v}", "{\"v\":{\"n\":{\"x\":1}},\"a\":{\"n\":{\"y\":0,\"x\":1}}}"),
        .ok("v = { n = null, n = ${p} }\nv = ${q}\na = { n = { y = 0 } }\na = ${v}\np = { x = 1 }\nq = { z = 2 }", "{\"v\":{\"n\":{\"x\":1},\"z\":2},\"a\":{\"n\":{\"y\":0,\"x\":1},\"z\":2},\"p\":{\"x\":1},\"q\":{\"z\":2}}"),
    });
}

// java ✓ (⚠️ BugOrBroken on the third) · pyhocon ✓ · spec ✓ — objects and
// substitutions alternate in one stack, a stack nests inside a layer of another,
// and a self-referential concatenation merges onto the layer below.
test "resolve.objects and substitutions alternate in one stack" {
    try expectAllResolved(&.{
        .ok("a = { p = 1 }\na = ${x}\na = { r = 3 }\na = ${y}\nx = { q = 2 }\ny = { s = 4 }", "{\"a\":{\"p\":1,\"q\":2,\"r\":3,\"s\":4},\"x\":{\"q\":2},\"y\":{\"s\":4}}"),
        .ok("a = ${x}\na = { b = ${y}, b = { c = 1 } }\nx = { d = 2 }\ny = { e = 3 }", "{\"a\":{\"d\":2,\"b\":{\"e\":3,\"c\":1}},\"x\":{\"d\":2},\"y\":{\"e\":3}}"),
        .ok("a = { q = 1 }\na = { p = {}, p = ${x} } ${a}\nx = { r = 2 }", "{\"a\":{\"q\":1,\"p\":{\"r\":2}},\"x\":{\"r\":2}}"),
    });
}

// java ⚠️ · pyhocon ✓ (⚠️ hangs on the last) · spec ✓ — a value hidden by one
// it cannot merge with is never evaluated; an object that merges with it is.
// java evaluates the hidden list in the second row and fails on `${nope}`.
test "resolve.a hidden value is never evaluated" {
    try expectAllResolved(&.{
        .ok("a = ${nope}\na = 42", "{\"a\":42}"),
        .ok("a = [${nope}]\nr = {}\na = ${r}", "{\"a\":{},\"r\":{}}"),
        .bad("a = { b = ${nope} }\nr = {}\na = ${r}"),
    });
}

// java ✓ · pyhocon ✓ · spec ✓ — an object layer is not self-referential: a
// path into it looks forward, at the object merged onto the layers below, so
// `y` sees this layer's `x` when it has one and the one below when it has not.
test "resolve.an object layer looks forward" {
    try expectAllResolved(&.{
        .ok("a = ${b}\na = { x = 2, y = ${a.x} }\nb = { x = 1 }", "{\"a\":{\"x\":2,\"y\":2},\"b\":{\"x\":1}}"),
        .ok("a = ${b}\na = { y = ${a.x} }\nb = { x = 1 }", "{\"a\":{\"x\":1,\"y\":1},\"b\":{\"x\":1}}"),
    });
}

// java ✓ (⚠️ refuses the last two) · pyhocon ⚠️ · spec ✓ — `a += b` is
// `a = ${?a} [b]` with the field's whole path in the ref: it starts a list,
// appends to one, twice in a row, inside an object, under a dotted key, with a
// substitution or an object holding a merge as the element. Inside a list the
// path names nothing, so it starts a list there too; java refuses that
// (`+=` "does not work nested inside a list") and fails on the merge
// (BugOrBroken). pyhocon gets nearly every row wrong: `a += b` alone is " b".
test "resolve.+= appends to the list below it" {
    try expectAllResolved(&.{
        .ok("snacks += crisps", "{\"snacks\":[\"crisps\"]}"),
        .ok("snacks = [cake]\nsnacks += crisps\nsnacks += pie", "{\"snacks\":[\"cake\",\"crisps\",\"pie\"]}"),
        .ok("o { snacks = [cake]\n  snacks += ${x} }\nx = pie", "{\"o\":{\"snacks\":[\"cake\",\"pie\"]},\"x\":\"pie\"}"),
        .ok("o.p { a = [1]\n  a += 2 }", "{\"o\":{\"p\":{\"a\":[1,2]}}}"),
        .ok("o.p.a += 1\no.p.a += 2", "{\"o\":{\"p\":{\"a\":[1,2]}}}"),
        // the element is appended whole, a list included
        .ok("a = [1]\na += [2]", "{\"a\":[1,[2]]}"),
        .ok("a = [ { b += 1 } ]", "{\"a\":[{\"b\":[1]}]}"),
        .ok("x = { p = 1 }\nl += { a = {}\n  a = ${x} }", "{\"x\":{\"p\":1},\"l\":[{\"a\":{\"p\":1}}]}"),
        // what was there is not a list, exactly as in the long form
        .bad("a = 1\na += b"),
    });
}

// java ✓ · pyhocon ✓ · spec ✓ (any one value, the same for both) — the order
// both fields are resolved in is undefined, but each `${…}` resolves once.
test "resolve.two fields that refer to each other agree" {
    try expectAllResolved(&.{
        .ok("a = 1\nb = 2\na = ${b}\nb = ${a}", "{\"a\":1,\"b\":1}"),
    });
}
