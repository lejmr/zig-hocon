//! Resolving: every `${…}` in a finished document replaced by what it names,
//! walking the tree once (`resolveValue`). A key written more than once is
//! decided in `Resolver/stack.zig`; where a path that is not in the document
//! looks next, in `Resolver/env.zig`; what `.keep` leaves for later, in
//! `Resolver/keep.zig`.
//!
//! One `Resolver` lives as long as one `Value.resolve` call: it is what the
//! walk carries along, and every step is a method on it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Key = @import("../Key.zig");
const Value = @import("../Value.zig").Value;
const Ref = @import("../Value.zig").Ref;
const Member = @import("../Value.zig").Member;
const Pos = Value.Pos;
const Part = Value.Part;
const stack = @import("Resolver/stack.zig");
const environment = @import("Resolver/env.zig");
const keep = @import("Resolver/keep.zig");
const waits = keep.waits;
const waitsInList = keep.waitsInList;
const mayVanish = keep.mayVanish;
const stacked = keep.stacked;

// For the tests.
const testing = std.testing;
const Ast = @import("../Ast.zig");
const Node = Ast.Node;
const Tokenizer = @import("../Tokenizer.zig");
const table = @import("../table.zig");
const build = @import("build.zig").build;
const v = @import("build.zig").v;
const n = @import("build.zig").n;

const Resolver = @This();

pub const Error = error{ Unresolved, SubstitutionCycle } || @import("../Value.zig").Error;
pub const Env = environment.Env;

// What resolve carries along
gpa: Allocator,
// The document: a path is looked up from here.
root: *Value,
// Places we are resolving right now, so a = ${b}, b = ${a} ends
visiting: std.ArrayList(*Value) = .empty,
// Fields whose top value is being resolved right now, innermost last.
// A path that reaches one of them does not see the field (see `seen`).
fields: std.ArrayList(stack.Field) = .empty,
// Members of an object by key, built on the first lookup into it. Keyed by
// the slice, which never changes once built: a resolved object is a new one.
index: std.AutoHashMapUnmanaged([*]Member, std.StringHashMapUnmanaged(*Value)) = .empty,
// `.keep`: fields resolved to a value that waits. It looks the same as
// one that is not resolved yet, and resolving it again would give it
// again, at the price of everything it refers to.
kept: std.AutoHashMapUnmanaged(*Value, void) = .empty,
// Optionals that closed a cycle (one without `?` would be a
// SubstitutionCycle) and so found nothing. A field that vanished
// because of one is in the document: never a variable.
cycles: usize = 0,
// Optionals being followed, each as how many places were being visited when
// it began: a cycle closed past one runs through it (`resolveOptional`).
optionals: std.ArrayList(usize) = .empty,
// The one of `optionals` a cycle is unwinding to.
breaking: ?usize = null,
// The lowest place in `visiting` a cycle closed at, while the innermost
// optional being followed was: one below where that optional began led
// back to its own field (`resolveOptional`).
closed: ?usize = null,
// Objects walked again from inside a look-back of a field in them, and the
// ref that led back (`walkAgain`).
again: std.ArrayList(struct { place: *Value, ref: Ref }) = .empty,
// What a place resolved to when it was walked again inside the look-back of a
// field outside it: its value, resolved once (`walkAgain`, `resolveField`).
walked: std.AutoHashMapUnmanaged(*Value, Value) = .empty,
// Fields that resolved to nothing, an optional with nothing behind it: that
// is their value too, and resolving them again later, once the cycle that
// made it so is over, would find something (`resolveField`). True when a
// cycle made it so: the field is in the document, never a variable.
vanished: std.AutoHashMapUnmanaged(*Value, bool) = .empty,
// The list elements the walk is in, outermost first, from `element_base`
// on: where a ref anchored at the n-th one starts (`Ref.flags.anchor`). A
// place a path from the document root reaches is in no list, as no path can
// name an element, so below it they count afresh (`resolveTarget`).
elements: std.ArrayList(*Value) = .empty,
element_base: usize = 0,
// Where a path that is not in the document is looked up.
env: Env,
// Where the error points; written once, where the error starts.
err_pos: *?Pos,
// How many lists and objects deep the value being resolved is, the root
// counting as one, as in the parser: what a substitution brings in
// counts where it lands, so the resolved tree is no deeper than a file
// may be (`Ast.max_depth`), and reads back.
depth: usize = 0,
// How many `resolveStack` calls are open: one per substitution in a
// chain, and per layer of a key written again. At most `Ast.max_depth`.
chain: usize = 0,
// The innermost substitution being followed: a list or an object it
// brings in that is too deep has no place to point at, so this is it.
followed: ?Pos = null,

pub const resolveField = stack.resolveField;
pub const resolveStack = stack.resolveStack;
pub const resolveObjectLayer = stack.resolveObjectLayer;
pub const seen = stack.seen;

/// Replaces all refs and pendings in the document. Self has to be the root.
/// On failure `err_pos` is the `${` of the substitution that failed, or the
/// part that does not fit once the refs around it have values — in whichever
/// file it came from.
pub fn resolve(self: *Value, gpa: Allocator, env: Env, err_pos: *?Pos) Error!void {
    var state: Resolver = .{ .gpa = gpa, .root = self, .env = env, .err_pos = err_pos };
    defer state.deinit();

    // Root is object and object never disappears
    self.* = (try state.resolveValue(self.*)) orelse unreachable;
}

fn deinit(state: *Resolver) void {
    const gpa = state.gpa;
    state.visiting.deinit(gpa);
    state.fields.deinit(gpa);
    state.optionals.deinit(gpa);
    state.again.deinit(gpa);
    state.walked.deinit(gpa);
    state.vanished.deinit(gpa);
    state.elements.deinit(gpa);
    state.kept.deinit(gpa);
    var it = state.index.valueIterator();
    while (it.next()) |members| members.deinit(gpa);
    state.index.deinit(gpa);
}

// What a path leads to. Only `absent` goes on to the environment.
const Found = union(enum) {
    // Not in the document: no such key, or an optional that found
    // nothing and so made no field.
    absent,
    // An optional that hit a cycle: the field is in the document, so
    // never a variable.
    gone,
    // `.keep` only: on the way is a value that waits, so where the path
    // ends is known later.
    waits,
    value: Value,
};

// Returns null when the value is gone - ${?x} pointing to nothing
//
// The longer cases here and in `resolveStack` are `noinline` functions of
// their own, and so is `fromEnv`: inlined, their locals would sit in every
// frame of the recursion, and a deep document would run out of stack sooner.
pub fn resolveValue(state: *Resolver, value: Value) Error!?Value {
    const gpa = state.gpa;
    const level: usize = if (value == .array or value == .object) 1 else 0;
    state.depth += level;
    defer state.depth -= level;
    if (state.depth > Ast.max_depth) {
        state.err_pos.* = state.followed;
        return error.TooDeep;
    }
    switch (value) {
        .scalar => return value,
        .array => |items| {
            var values: std.ArrayList(Value) = .empty;
            for (items) |*item| {
                try state.elements.append(gpa, item);
                defer _ = state.elements.pop();
                if (try state.resolveValue(item.*)) |val| try values.append(gpa, val);
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

                // Walked again: a field that looks back is what it looks back at.
                if (state.again.items.len > 0 and looksBackAt(state, &m.value)) {
                    const ref = state.again.items[state.again.items.len - 1].ref;
                    const seen_as = try state.seen(&m.value, ref, false) orelse continue;
                    if (try state.resolveValue(seen_as.*)) |val| try resolved.append(gpa, .{ .key = m.key, .value = val });
                    continue;
                }
                if (try state.resolveField(&m.value)) |val| {
                    try resolved.append(gpa, .{ .key = m.key, .value = val });
                }
            }
            const out = try resolved.toOwnedSlice(gpa);
            // `.keep`: a field that waits is still resolved in the new
            // object. Resolved again, a value-reference's fallback under
            // its layers (`resolveRef`) would be followed, and may lead back.
            for (out) |*m| if (waits(m.value)) try state.kept.put(gpa, &m.value, {});
            return .{ .object = out };
        },
        .ref => |r| return try state.resolveRef(r, false),
        .pending => |parts| return try state.resolvePending(parts),
        // Only a field holds one, and a field is resolved by `resolveField`.
        .stack => unreachable,
    }
}

// A concatenation's value: its parts, resolved and joined.
pub noinline fn resolvePending(state: *Resolver, parts: []const Part) Error!?Value {
    const gpa = state.gpa;
    // Same as concat in fromNode, just now refs have values
    var buffer: ?Value = null;
    var start: Pos = undefined;
    // `.keep`: from the first part that waits on, the parts join
    // later. These are them: what joined before it, then each one.
    var kept: std.ArrayList(Part) = .empty;
    for (parts) |part| {
        const val = try state.resolveValue(part.value) orelse continue;
        if (kept.items.len > 0) try kept.append(gpa, .{ .value = val, .pos = part.pos });
        if (waits(val) or (buffer != null and waitsInList(buffer.?, val))) {
            if (kept.items.len == 0) {
                if (buffer) |b| try kept.append(gpa, .{ .value = b, .pos = start });
                try kept.append(gpa, .{ .value = val, .pos = part.pos });
            }
            // Whatever it turns out to be joins onto the buffer and
            // leaves it a list, an object or text, as it was — or
            // fails. So the buffer goes on, to fail now on what
            // fails anyway. A gap takes the shape of what comes next.
            if (buffer) |b| if (b.isGap()) {
                buffer = null;
            };
            continue;
        }
        // Nor does a gap right after one that waits say anything.
        if (buffer == null and kept.items.len > 0 and val.isGap()) continue;
        if (buffer) |*ebuffer| {
            // Text starts after a gap, as in fromNode.
            if (ebuffer.isGap()) start = part.pos;
            // The part that does not fit onto what came before it.
            ebuffer.update(gpa, val) catch |err| {
                state.err_pos.* = part.pos;
                return err;
            };
        } else {
            buffer = val;
            start = part.pos;
        }
    }
    if (kept.items.len > 0) return .{ .pending = try kept.toOwnedSlice(gpa) };
    var result = buffer orelse return null;
    // Merged text is always string, ${?x}42 is "42", and it starts
    // where its first part past a gap is written.
    if (result == .scalar) {
        result.scalar.quoted = true;
        result.scalar.file = start.file;
        result.scalar.pos = @intCast(start.offset);
    }
    return result;
}

// A ref's value: at its path, scope first, then in the environment.
// Null for an optional that found nothing. `on_top`: it is the top layer
// of the field being resolved, the last one in `state.fields`.
pub fn resolveRef(state: *Resolver, r: Ref, on_top: bool) Error!?Value {
    if (r.flags.optional) return state.resolveOptional(r, on_top);
    return state.followRef(r, on_top);
}

// A cycle closed while an optional is followed runs through it, and a cycle
// is a missing value for an optional (spec L714): so it finds nothing, even
// when a ref further on is the one that came round. `v { x = ${?r} }`,
// `r = ${v}` is `v = {}` whichever field is resolved first.
//
// One that led back to the field it stands in, through a cycle another
// optional on the way broke, is nonexistent as well (spec L716: "If ${?foo}
// refers to itself then it's as if it referred to a nonexistent value"), so
// `f = ${?a.t}x`, `a = ${?y}${?f}` is `f = "x"` whichever field goes first.
noinline fn resolveOptional(state: *Resolver, r: Ref, on_top: bool) Error!?Value {
    const mark = state.optionals.items.len;
    const start = state.visiting.items.len;
    try state.optionals.append(state.gpa, start);
    defer state.optionals.shrinkRetainingCapacity(mark);
    const fields = state.fields.items.len;
    const err_pos = state.err_pos.*;
    const outer = state.closed;
    state.closed = null;
    // What closed in here closed for the optionals around it too.
    defer if (outer) |o| {
        if (state.closed == null or o < state.closed.?) state.closed = o;
    };
    const val = state.followRef(r, on_top) catch |err| {
        if (err != error.SubstitutionCycle or state.breaking != mark) return err;
        state.breaking = null;
        state.err_pos.* = err_pos;
        // The fields it was in the middle of are not any more.
        state.fields.shrinkRetainingCapacity(fields);
        state.cycles += 1;
        return null;
    };
    if (state.closed) |closed| if (closed < start) {
        state.cycles += 1;
        return null;
    };
    return val;
}

// A cycle closed at the i-th place in `visiting`, and an optional found
// nothing there (`resolveOptional`).
pub fn closeAt(state: *Resolver, i: usize) void {
    state.cycles += 1;
    if (state.closed == null or i < state.closed.?) state.closed = i;
}

// A required ref closed a cycle at the i-th place in `visiting`: the last
// optional that began after it is on the cycle, and it breaks there, unless a
// field on the cycle can look back (`resolveOptional`).
pub fn markBreaking(state: *Resolver, i: usize) void {
    const last = state.optionals.items.len;
    const looking_back = for (state.visiting.items[i + 1 ..]) |p| {
        if (looksBackAt(state, p)) break true;
    } else false;
    if (!looking_back and last > 0 and state.optionals.items[last - 1] > i) state.breaking = last - 1;
}

// Where `place` is in `visiting`, if it is there.
pub fn visitingAt(state: *Resolver, place: *Value) ?usize {
    for (state.visiting.items, 0..) |p, i| if (p == place) return i;
    return null;
}

noinline fn followRef(state: *Resolver, r: Ref, on_top: bool) Error!?Value {
    const gpa = state.gpa;
    const outer = state.followed;
    state.followed = r.at();
    defer state.followed = outer;
    var path = r.path;
    var found = try state.follow(r, path);
    // From an included file: nothing found with the scope in front,
    // so try the path as written.
    // From a list element too, unless it is a `+=` there, which only looks
    // at what its own field held.
    if ((found == .absent or found == .gone) and (r.scope_len > 0 or (r.flags.anchor > 0 and !r.flags.append))) {
        const scoped = found;
        path = r.path[r.scope_len..];
        found = try state.follow(r.from(path), path);
        // A cycle is in the document: no variable for it.
        if (found == .absent and scoped == .gone) found = .gone;
    }
    // `.keep`: what waits is looked up later the way it went now:
    // scope first, if it was found with the scope.
    var later: Value = .{ .ref = if (path.len == r.path.len) r else r.from(path) };
    switch (found) {
        // What it found waits, or holds something that does, so it
        // waits too, as written. Not a copy: `b = ${a}` after
        // `a = ${?PORT}` is required, and `a = ${a} x` inside a
        // copy of `a` would read `a`, not itself. Found with the scope,
        // it falls back to the path as written only if what it found
        // may still turn out to be nothing; otherwise it never will, and
        // the path it was found at is all it looks up.
        .value => |val| {
            if (state.env != .keep or val.isResolved()) return val;
            if (!mayVanish(val)) later.ref = r.from(path);
            // A self-reference, on top of its field or a `+=`, found the
            // layers below it, and falls back to the path as written only
            // once they find nothing: that goes under them, and after it
            // the variable, as for any path not in the document.
            const self_ref = later.ref.scope_len > 0 and (on_top or r.flags.append);
            const field = if (self_ref) &state.fields.items[state.fields.items.len - 1] else null;
            if (field != null and field.?.merged != null and std.meta.eql(field.?.merged.?, val)) {
                const written = r.path[r.scope_len..];
                const under = try stacked(gpa, .{ .ref = r.from(written) }, val);
                // On top, it is just those layers.
                if (on_top) return under;
                field.?.merged = under;
                later.ref = r.from(r.path);
            }
            return later;
        },
        // The path runs through a value that waits.
        .waits => return later,
        .absent => switch (state.env) {
            .none => {},
            .map => |map| if (try environment.fromEnv(gpa, map, r)) |val| return val,
            // Absent with the scope too, so `later` has none.
            .keep => return later,
        },
        .gone => {},
    }
    if (r.flags.optional) return null;
    state.err_pos.* = r.at();
    return Error.Unresolved;
}

// The value at a path, resolved. `ref` is the one that asked, for the
// errors on the way.
fn follow(state: *Resolver, ref: Ref, path: []const Key) Error!Found {
    const target = switch (try state.lookup(ref, path)) {
        .place => |place| place,
        .absent => return .absent,
        .gone => return .gone,
        .waits => return .waits,
    };
    // An optional that found nothing leaves no field: not in the document.
    // Unless it hit a cycle on the way, then the field is just gone.
    const cycles = state.cycles;
    const val = try state.resolveTarget(target, ref, true) orelse
        return if (state.cycles > cycles) .gone else .absent;
    return .{ .value = val };
}

// Resolves the place a ref points to and stores it back, next ref there is for free.
// `ref` is the one that asked, the one that closes a cycle. An optional one
// finds nothing there instead (spec L714): `a = [${?a}]` is `[]`.
//
// `whole`: the path ends at the target. Only then does a ref to an object a
// place being resolved is in come back round; on the way through it the path
// goes into it and resolves what it passes, as objects may refer to paths
// within themselves (spec L815).
fn resolveTarget(state: *Resolver, target: *Value, ref: Ref, whole: bool) Error!?Value {
    const gpa = state.gpa;
    // The lists around the target: from the document root none, so the ones
    // below it count afresh; from a list element, that element and the ones
    // around it, not the ones the walk went on into from there.
    const base = state.element_base;
    defer state.element_base = base;
    var below: []*Value = &.{};
    if (ref.flags.anchor == 0) {
        state.element_base = state.elements.items.len;
    } else if (base + ref.flags.anchor < state.elements.items.len) {
        below = try gpa.dupe(*Value, state.elements.items[base + ref.flags.anchor ..]);
        state.elements.shrinkRetainingCapacity(base + ref.flags.anchor);
    }
    defer state.elements.appendSliceAssumeCapacity(below);
    for (state.visiting.items, 0..) |place, i| {
        // A ref to a place being resolved, or to an object it is in, comes
        // back round (spec L697: the lookup document is an ancestor).
        if (place == target or (whole and holds(target.*, place))) {
            if (ref.flags.optional) {
                state.closeAt(i);
                return null;
            }
            // A field on the cycle that can look back breaks it first
            // (spec L849): inside the target, it is walked again; anywhere
            // else that is not done, and the cycle stays one.
            if (try state.walkAgain(target, ref, i)) |val| return val;
            // Else an optional that began after the target did is on it.
            state.markBreaking(i);
            state.err_pos.* = ref.at();
            return Error.SubstitutionCycle;
        }
    }
    try state.visiting.append(gpa, target);
    defer _ = state.visiting.pop();

    return try state.resolveField(target);
}

// Where a path ends: as `Found`, with the place instead of its value.
const Place = union(enum) { absent, gone, waits, place: *Value };

// `o { a = [], a += ${o} }`: the ref came back to an object that a field
// looking back is in, so the cycle breaks there (spec L659): the object is
// walked again, not stored, with the field at what it looks back at, o's
// a at [] (the implementation the spec sketches, L693). `i` is where the
// object is in `visiting`; null where nothing in it looks back, or it is
// being walked again already, and the cycle cannot be broken.
//
// A target the field is not in, `a = [${p}]`, `p = 1`, `p = ${a}`: walked again
// too, the field it led to seen at its earlier value, and what it resolves to
// there is its value, as a substitution is resolved once (spec L886): `a` is
// `[1]`, whichever field goes first.
fn walkAgain(state: *Resolver, target: *Value, ref: Ref, i: usize) Error!?Value {
    // A list the same as an object (spec L684, L801): `a = [{c = 2, c = ${a}}]`.
    if (target.* != .object and target.* != .array) return null;
    for (state.again.items) |a| if (a.place == target) return null;
    for (state.visiting.items[i + 1 ..]) |place| {
        if (!looksBackAt(state, place)) continue;
        const inside = holds(target.*, place);
        try state.again.append(state.gpa, .{ .place = target, .ref = ref });
        defer _ = state.again.pop();
        const val = try state.resolveValue(target.*) orelse return null;
        if (!inside) try state.walked.put(state.gpa, target, val);
        return val;
    }
    return null;
}

// Whether `place` is a member of `value` or of a list or object in it.
fn holds(value: Value, place: *Value) bool {
    switch (value) {
        .object => |members| for (members) |*m| {
            if (&m.value == place or holds(m.value, place)) return true;
        },
        .array => |items| for (items) |*item| {
            if (item == place or holds(item.*, place)) return true;
        },
        else => {},
    }
    return false;
}

// Whether `place` is a field being resolved that looks back at layers below.
fn looksBackAt(state: *Resolver, place: *Value) bool {
    for (state.fields.items) |f| {
        if (f.place == place and f.object == null and f.below.len > 0) return true;
    }
    return false;
}

// Walks the path from root, a ref on the way has to be resolved first.
// A key missing, or text where the path goes on, is `absent`: `${x.y}`
// with `x = 1` has no `x.y` in the document.
fn lookup(state: *Resolver, ref: Ref, path: []const Key) Error!Place {
    const gpa = state.gpa;
    // From the list element the path starts at, if it is anchored at one.
    var current = state.root;
    const anchor = ref.flags.anchor;
    if (anchor > 0 and state.element_base + anchor <= state.elements.items.len)
        current = state.elements.items[state.element_base + anchor - 1];
    for (path, 0..) |key, k| {
        // A field that refers to itself sees the layers below it. With
        // nothing there it is as if the path were not in the document
        // (spec L767), so it reads the variable; a cycle on the way is gone.
        const before = state.cycles;
        current = try state.seen(current, ref, false) orelse
            return if (state.cycles > before) .gone else .absent;
        if (try state.throughAlias(ref, current, path[k..])) |found| return found;
        if (current.* == .ref or current.* == .pending or current.* == .stack) {
            const cycles = state.cycles;
            const val = try state.resolveTarget(current, ref, false) orelse
                return if (state.cycles > cycles) .gone else .absent;
            if (waits(val)) return .waits;
        }
        if (current.* != .object) return .absent;

        const members = try state.index.getOrPut(gpa, current.object.ptr);
        if (!members.found_existing) {
            members.value_ptr.* = .empty;
            // A later duplicate overwrites, the last one wins as in the slice
            for (current.object) |*m| try members.value_ptr.put(gpa, m.key.value, &m.value);
        }
        current = members.value_ptr.get(key.value) orelse return .absent;
    }
    const before = state.cycles;
    const place = try state.seen(current, ref, true) orelse
        return if (state.cycles > before) .gone else .absent;
    return .{ .place = place };
}

// `a = ${p}` on the way, with `rest` of the path after it: `a.q` is `p.q`,
// so only p.q is resolved, not all of p, which may itself need `a.q`
// (`p = { r = ${a.q} }`): the path looks forward and no further than it
// goes (spec L815). Null where the path goes on through `a` as it is: an
// optional, a `+=`, a ref from an included file or one kept for later.
fn throughAlias(state: *Resolver, ref: Ref, place: *Value, rest: []const Key) Error!?Place {
    if (state.env == .keep) return null;
    const alias = aliasOf(place.*) orelse return null;
    if (alias.flags.anchor > 0) return null;
    if (alias.flags.optional or alias.flags.append or alias.scope_len > 0) return null;
    // Resolving it already, it is a cycle, which `resolveTarget` says.
    for (state.visiting.items) |p| if (p == place) return null;
    const gpa = state.gpa;
    try state.visiting.append(gpa, place);
    defer _ = state.visiting.pop();
    // The alias's path is from the document root, whatever `ref` starts at.
    var from_root = ref;
    from_root.flags.anchor = 0;
    return try state.lookup(from_root, try std.mem.concat(gpa, Key, &.{ alias.path, rest }));
}

// The ref an alias is: `a = ${p}`, also written more than once, which merges
// p onto p and is p still. Null for anything else.
fn aliasOf(value: Value) ?Ref {
    switch (value) {
        .ref => |r| return r,
        .stack => |layers| {
            if (layers[0] != .ref) return null;
            const first = layers[0].ref;
            for (layers[1..]) |layer| {
                if (layer != .ref or layer.ref.path.len != first.path.len) return null;
                for (layer.ref.path, first.path) |a, b| {
                    if (!std.mem.eql(u8, a.value, b.value)) return null;
                }
            }
            return first;
        },
        else => return null,
    }
}

// A new place holding `value`, resolved already, for a path to find.
// `.keep`: one that waits is marked as resolved, or the path that finds
// it would resolve it again.
pub fn placeFor(state: *Resolver, value: Value) Error!*Value {
    const gpa = state.gpa;
    const place = try gpa.create(Value);
    place.* = value;
    if (waits(value)) try state.kept.put(gpa, place, {});
    return place;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test {
    _ = stack;
    _ = environment;
    _ = keep;
}

/// Parses `src`, resolves it and compares the result printed as JSON.
pub fn expectResolved(src: [:0]const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var parser = Ast.Parser{ .gpa = gpa, .t = .{ .t = Tokenizer.Tokenizer.init(src) } };
    var root = try build(gpa, try parser.parse());
    var err_pos: ?Value.Pos = null;
    try root.resolve(gpa, .none, &err_pos);
    try testing.expectEqualStrings(expected, try std.json.Stringify.valueAlloc(gpa, root, .{}));
}
/// Parses `src`, resolves it and prints it as JSON.
fn resolvedJson(gpa: Allocator, src: [:0]const u8) ![]const u8 {
    var parser = Ast.Parser{ .gpa = gpa, .t = .{ .t = Tokenizer.Tokenizer.init(src) } };
    var root = try build(gpa, try parser.parse());
    var err_pos: ?Value.Pos = null;
    try root.resolve(gpa, .none, &err_pos);
    return try std.json.Stringify.valueAlloc(gpa, root, .{});
}

/// The same JSON, whatever order the keys come in.
fn sameJson(a: std.json.Value, b: std.json.Value) bool {
    switch (a) {
        .object => |members| {
            if (b != .object or b.object.count() != members.count()) return false;
            var it = members.iterator();
            while (it.next()) |entry| {
                const other = b.object.get(entry.key_ptr.*) orelse return false;
                if (!sameJson(entry.value_ptr.*, other)) return false;
            }
            return true;
        },
        .array => |items| {
            if (b != .array or b.array.items.len != items.items.len) return false;
            for (items.items, b.array.items) |x, y| if (!sameJson(x, y)) return false;
            return true;
        },
        .string => |text| return b == .string and std.mem.eql(u8, text, b.string),
        else => return std.meta.eql(a, b),
    }
}

pub fn expectResolveError(src: [:0]const u8, expected: anyerror) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var parser = Ast.Parser{ .gpa = gpa, .t = .{ .t = Tokenizer.Tokenizer.init(src) } };
    var root = try build(gpa, try parser.parse());
    var err_pos: ?Value.Pos = null;
    try testing.expectError(expected, root.resolve(gpa, .none, &err_pos));
}
/// Runs a table of documents through parse, load and resolve; a row renders as
/// the resolved document printed as JSON, and a `.bad` row must fail on the way.
pub fn expectAllResolved(cases: []const table.Case) !void {
    return table.expectAll(cases, .{ .dump = struct {
        fn dump(gpa: std.mem.Allocator, src: [:0]const u8) anyerror![]u8 {
            var parser = Ast.Parser{ .gpa = gpa, .t = .{ .t = Tokenizer.Tokenizer.init(src) } };
            var root = try build(gpa, try parser.parse());
            var err_pos: ?Value.Pos = null;
            try root.resolve(gpa, .none, &err_pos);
            return std.json.Stringify.valueAlloc(gpa, root, .{});
        }
    }.dump });
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
// self-referential-examples/039 · java ✓ · pyhocon ✗ (overflows its stack) ·
// spec ✓ — `resolveOptional`: an optional on a cycle finds nothing, also when a
// required ref further on is the one that comes round, in either order. A cycle
// with no optional on it stays an error, an optional before it or not.
test "resolve.an optional on a cycle breaks it" {
    try expectResolved("v { x = ${?r} }\nr = ${v}", "{\"v\":{},\"r\":{}}");
    try expectResolved("r = ${v}\nv { x = ${?r} }", "{\"r\":{},\"v\":{}}");
    try expectResolveError("a = ${?b}\nb = ${c}\nc = ${b}", error.SubstitutionCycle);
}
// self-referential-examples/038 · java ✓ · pyhocon ✗ (WrongType) · spec ✓ —
// `throughAlias`: a path through `a = ${p}` goes on in p, so `${a.q}` inside p
// needs only p.q and there is no cycle. One through two aliases that lead
// back to each other still is one.
test "resolve.a path through an alias needs only what it reaches" {
    try expectResolved("p = { q = 1 }\na = ${p}\np = { r = ${a.q} }", "{\"p\":{\"q\":1,\"r\":1},\"a\":{\"q\":1,\"r\":1}}");
    try expectResolved("p { q = 1, r = ${a.q} }\na = ${b}\nb = ${p}", "{\"p\":{\"q\":1,\"r\":1},\"a\":{\"q\":1,\"r\":1},\"b\":{\"q\":1,\"r\":1}}");
    try expectResolveError("a = ${b}\nb = ${a}\nc = ${a.q}", error.SubstitutionCycle);
}
// self-referential-examples/035, 037 · java ✓ · pyhocon ⚠️ (a = "1x", which the
// suite takes too) · spec ✓ — a ref that comes round to a field with nothing
// below it, through one that has: the cycle breaks at the one with a value
// below, and the first is resolved anew inside its look-back and keeps that
// value, whichever field is resolved first. Through two fields the same.
test "resolve.a cycle through an alias breaks where there is a value below" {
    try expectResolved("p = 1\na = ${p}\np = ${a}x", "{\"p\":\"1x\",\"a\":1}");
    try expectResolved("a = ${p}\np = 1\np = ${a}x", "{\"a\":1,\"p\":\"1x\"}");
    try expectResolved("a = ${p}y\np = 1\np = ${a}x", "{\"a\":\"1y\",\"p\":\"1yx\"}");
    try expectResolved("a = ${b}\nb = ${p}\np = 1\np = ${a}x", "{\"a\":1,\"b\":1,\"p\":\"1x\"}");
}
// self-referential-substitutions/007 · java ✓ · pyhocon ✗ (overflows its
// stack) · spec ✓ — `walkAgain`: a field that looks back and refers to an
// object it is in sees the object with itself at what it looks back at, at
// any depth, the other fields as they are. `a { b = ${a} }` has nothing to
// look back at and stays a cycle, and so does a second ref back to the object.
test "resolve.a look-back that refers to its own object" {
    try expectResolved("o { a = [], a += ${o} }", "{\"o\":{\"a\":[{\"a\":[]}]}}");
    try expectResolved("o { x = 1, a = [], a += ${o} }", "{\"o\":{\"x\":1,\"a\":[{\"x\":1,\"a\":[]}]}}");
    try expectResolved("o { b { a = [], a += ${o} } }", "{\"o\":{\"b\":{\"a\":[{\"b\":{\"a\":[]}}]}}}");
    try expectResolved("o { a = 1, a = ${o} }", "{\"o\":{\"a\":{\"a\":1}}}");
    try expectResolveError("a { b = ${a} }", error.SubstitutionCycle);
    try expectResolveError("o { a = [], a += ${o}, c = ${o} }", error.SubstitutionCycle);
}
// plus-equals-field-separator/015-016 · java ⚠️ (refuses += in a list) ·
// pyhocon ✗ · spec ✓ — `+=` in an object in a list looks at the value it
// overrides in that object (L745), not at a path from the root that cannot
// name the element: no earlier value is a new list, a list is appended to,
// anything else is an error, and a root key of the same name is not seen.
test "resolve.+= in a list element sees the value it overrides there" {
    try expectResolved("a = [ { b = [1], b += 2 } ]", "{\"a\":[{\"b\":[1,2]}]}");
    try expectResolved("a = [ { b += 2 } ]", "{\"a\":[{\"b\":[2]}]}");
    try expectResolved("b = [7]\na = [ { b += 2 } ]", "{\"b\":[7],\"a\":[{\"b\":[2]}]}");
    try expectResolved("a = [ [ { b = [1], b += 2 } ] ]", "{\"a\":[[{\"b\":[1,2]}]]}");
    try expectResolveError("a = [ { b = 1, b += 2 } ]", error.UnsupportedConcatenation);
}

// self-referential-examples/040, 043, 045–048 · java ✓ (all but the `f =
// ${?a.t}` row, where it gives f = 1) · spec ✓ — the same lines in either
// order give the same values: an optional that leads back to its own field is
// nonexistent (L716), and a target walked again inside a look-back keeps that
// value (L886), whichever field is resolved first.
test "resolve.a cycle gives the same values in either order" {
    const pairs = [_]struct { [:0]const u8, [:0]const u8, []const u8 }{
        .{ "o = ${a.n}\n", "a { n = { h = 0 } ${?a} }\n", "{\"o\":{\"h\":0},\"a\":{\"n\":{\"h\":0}}}" },
        .{ "f = ${?a.t}x\n", "a = ${?y}${?f}\ny { t = 1 }\n", "{\"f\":\"x\",\"a\":{\"t\":1},\"y\":{\"t\":1}}" },
        .{ "f = ${?a.t}\n", "a = ${?y}${?f}\ny { t = 1 }\n", "{\"a\":{\"t\":1},\"y\":{\"t\":1}}" },
        .{ "d = yes${?c}\n", "c = ${d}\n", "{\"d\":\"yes\",\"c\":\"yes\"}" },
        .{ "e += ${?c}\n", "c = ${e}\n", "{\"e\":[],\"c\":[]}" },
        .{ "a = [${p}]\n", "p = 1\np = ${a}\n", "{\"a\":[1],\"p\":[1]}" },
        .{ "d { a = ${i.b} }\n", "i.b = 7\ni = ${d}\n", "{\"d\":{\"a\":7},\"i\":{\"b\":7,\"a\":7}}" },
    };
    for (pairs) |p| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const gpa = arena.allocator();
        for ([_][2][]const u8{ .{ p[0], p[1] }, .{ p[1], p[0] } }) |order| {
            const src = try std.mem.concatWithSentinel(gpa, u8, &.{ order[0], order[1] }, 0);
            const want: std.json.Value = try std.json.parseFromSliceLeaky(std.json.Value, gpa, p[2], .{});
            const got = try resolvedJson(gpa, src);
            const have: std.json.Value = try std.json.parseFromSliceLeaky(std.json.Value, gpa, got, .{});
            errdefer std.debug.print("order: {s}\ngot: {s}\n", .{ src, got });
            try testing.expect(sameJson(want, have));
        }
    }
}

// java ✓ · spec ✓ — a cycle is broken by looking back where that gives every
// field one value, and only there: a field resolved anew a second time stays a
// cycle. An object the look-back is not in is walked again inside it, and what
// it resolves to there is its value, a substitution being resolved once (L886);
// until 2026-10-25 that was a cycle too, the last two rows, which typesafe/config
// resolves to these values.
test "resolve.a cycle breaks only where its look-back stays one value" {
    try expectResolved("bar : ${foo}\nfoo += 5\nfoo : ${bar}", "{\"bar\":[5],\"foo\":[5]}");
    try expectResolved("a : ${?t} ${?a}${?n.x}\nn = ${a}", "{\"a\":\" \",\"n\":\" \"}");
    try expectResolveError("a = ${p}\np = 1\np = ${a}x\np = ${a}x", error.SubstitutionCycle);
    try expectResolved("v { n = { x = ${a} } }\na = { n = { h = 0 } }\na = ${v}", "{\"v\":{\"n\":{\"x\":{\"n\":{\"h\":0}}}},\"a\":{\"n\":{\"h\":0,\"x\":{\"n\":{\"h\":0}}}}}");
    try expectResolved("v = { x = ${?a} }\nr = null\nr = ${v}\na = null\na = ${r}", "{\"v\":{\"x\":null},\"r\":{\"x\":null},\"a\":{\"x\":null}}");
}
