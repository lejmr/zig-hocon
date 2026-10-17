//! A key written more than once: what its values make, one on top of the
//! other. Two objects merge, a ref or a pending goes on a stack for
//! `Resolver` to decide, anything else replaces what was there.

const std = @import("std");
const Value = @import("../Value.zig").Value;
const Member = @import("../Value.zig").Member;
const Error = @import("../Value.zig").Error;

// For the tests.
const testing = std.testing;
const Ast = @import("../Ast.zig");
const Node = Ast.Node;
const Tokenizer = @import("../Tokenizer.zig");
const table = @import("../table.zig");
const build = @import("build.zig").build;
const v = @import("build.zig").v;
const n = @import("build.zig").n;

/// The members in the order their keys first came, a key written more than
/// once holding what its values make one on top of the other (see `push`).
pub fn mergeMembers(gpa: std.mem.Allocator, members: []const Member) Error![]Member {
    var by_key: std.StringArrayHashMapUnmanaged(std.ArrayList(Value)) = .empty;
    defer by_key.deinit(gpa);
    for (members) |m| {
        const entry = try by_key.getOrPut(gpa, m.key.value);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(gpa, m.value);
    }
    var merged: std.ArrayList(Member) = .empty;
    for (by_key.keys(), by_key.values()) |key, *written| {
        defer written.deinit(gpa);
        try merged.append(gpa, .{ .key = .{ .value = key }, .value = try fold(gpa, written.items) });
    }
    return merged.toOwnedSlice(gpa);
}

/// The values of one key, each pushed onto the ones before it. Objects that
/// follow each other merge first, all at once, which is the same, as merging
/// is associative: a thousand `a.x = …` lines are then a thousand steps, not
/// half a million, which merging them two at a time took.
fn fold(gpa: std.mem.Allocator, written: []const Value) Error!Value {
    var result: ?Value = null;
    var i: usize = 0;
    while (i < written.len) {
        var end = i + 1;
        while (written[i] == .object and end < written.len and written[end] == .object) end += 1;
        var next = written[i];
        if (end - i > 1) {
            var members: std.ArrayList(Member) = .empty;
            defer members.deinit(gpa);
            for (written[i..end]) |object| try members.appendSlice(gpa, object.object);
            next = .{ .object = try mergeMembers(gpa, members.items) };
        }
        if (result) |*r| try push(r, gpa, next) else result = next;
        i = end;
    }
    return result.?;
}

/// Puts `other` on top of what a repeated key already holds. Two objects
/// merge. A ref or a pending goes on a stack above what was there, since it
/// may merge with it or look back at it once resolved; so does an object on
/// top of one. Anything else replaces what was there, which is then never
/// looked at again.
// ponytail: a ref or a pending is appended by copying the stack, so a key
// written as a ref thousands of times is quadratic (10 000: 0.2 s). Build the
// layers in one list in `fold` if a real file ever does that.
fn push(self: *Value, gpa: std.mem.Allocator, other: Value) Error!void {
    switch (other) {
        // From an include: its layers go on one by one.
        .stack => |layers| for (layers) |layer| try push(self, gpa, layer),
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
        // A list and an object with numeric keys: the object is a list too.
        if (tag_self == .array and tag_other == .object) {
            const items = try numbered(gpa, other.object) orelse return Error.UnsupportedConcatenation;
            self.array = try std.mem.concat(gpa, Value, &.{ self.array, items });
            return;
        }
        if (tag_self == .object and tag_other == .array) {
            const items = try numbered(gpa, self.object) orelse return Error.UnsupportedConcatenation;
            self.* = .{ .array = try std.mem.concat(gpa, Value, &.{ items, other.array }) };
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
            // Where the text starts, which is not at a gap in front of it.
            const start = if (self.isGap()) other.scalar else self.scalar;
            self.scalar = .{
                .value = try std.mem.concat(gpa, u8, &.{ self.scalar.value, other.scalar.value }),
                // A gap onto a gap is still a gap.
                .quoted = !(self.isGap() and other.isGap()),
                .file = start.file,
                .pos = start.pos,
            };
        },
        .object => {
            const both = try std.mem.concat(gpa, Member, &.{ self.object, other.object });
            defer gpa.free(both);
            self.object = try mergeMembers(gpa, both);
        },
        else => return Error.UnsupportedConcatenation,
    }
}

/// The values of an object with numeric keys as a list, in the order of the
/// keys: `{ "2" : b, "0" : a }` is `[a, b]` (spec L1184), for where a list is
/// expected: next to one, or read into a slice (`Config`). A key that is not
/// a whole number of 0 or more is left out; null when no key is one. A key
/// is read the way java reads it, `Integer.parseInt`: `01`, `+1` and `-0`
/// count, `1_0` and anything over 2^31 - 1 do not. Only ASCII digits, where
/// java takes any Unicode digit, `١`. `1` and `01` are one index, and the
/// later one wins, as for a repeated key.
pub fn numbered(gpa: std.mem.Allocator, members: []const Member) std.mem.Allocator.Error!?[]Value {
    const Entry = struct {
        index: i32,
        value: Value,

        fn lessThan(_: void, a: @This(), b: @This()) bool {
            return a.index < b.index;
        }
    };
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(gpa);
    for (members) |m| {
        // std.fmt.parseInt skips `_`, java does not.
        if (std.mem.indexOfScalar(u8, m.key.value, '_') != null) continue;
        const index = std.fmt.parseInt(i32, m.key.value, 10) catch continue;
        if (index < 0) continue;
        try entries.append(gpa, .{ .index = index, .value = m.value });
    }
    if (entries.items.len == 0) return null;

    // Stable: of two entries with one index, the later one stays later.
    std.mem.sort(Entry, entries.items, {}, Entry.lessThan);
    var items: std.ArrayList(Value) = .empty;
    for (entries.items, 0..) |e, i| {
        if (i + 1 < entries.items.len and entries.items[i + 1].index == e.index) continue;
        try items.append(gpa, e.value);
    }
    return try items.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

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
// A key written again and again, `a.x0 = 0` … `a.x1999 = 1999` the way a
// properties-like file does, and nested one deeper: the objects merge all at
// once (`fold`), so the bytes it takes grow with the lines. Two at a time,
// each row took 525 MB; now it is 5 to 8 MB, the budget is 20.
// Zig only (java – · pyhocon – · spec –)
test "merge.a key written many times costs as many steps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    inline for (.{ "a.x{d} = {d}\n", "a.b.x{d} = {d}\n", "a {{ x{d} = {d} }}\n" }) |line| {
        var out: std.Io.Writer.Allocating = .init(arena.allocator());
        for (0..2000) |i| try out.writer.print(line, .{ i, i });
        const src = try out.toOwnedSliceSentinel(0);

        var counting = testing.FailingAllocator.init(arena.allocator(), .{});
        const gpa = counting.allocator();
        var parser = Ast.Parser{ .gpa = gpa, .t = .{ .t = Tokenizer.Tokenizer.init(src) } };
        _ = try build(gpa, try parser.parse());
        try testing.expect(counting.allocated_bytes < 20 * 1024 * 1024);
    }
}
