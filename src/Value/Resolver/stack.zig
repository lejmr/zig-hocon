//! A key written more than once, resolved from the top layer down. Two cases,
//! and everything here follows from them:
//!
//!   a = 1, a = ${a} x      a ref or a pending LOOKS DOWN at the layers below
//!                          it, as if the field had never been written from
//!                          here up: `a` is `1 x`.
//!   a = { x = 1 }, a = { y = ${a.x} }
//!                          an object LOOKS FORWARD at itself merged onto the
//!                          layers below: `a.x` is there, `a.y` is 1.
//!
//! While a field is resolved it is on `Resolver.fields`, and `seen` says what a
//! path that reaches it finds meanwhile: the layers below for the first case,
//! the merged object for the second.

const std = @import("std");
const Key = @import("../../Key.zig");
const Value = @import("../../Value.zig").Value;
const Ref = @import("../../Value.zig").Ref;
const Pos = Value.Pos;
const Resolver = @import("../Resolver.zig");
const Error = Resolver.Error;
const keep = @import("keep.zig");
const waits = keep.waits;

// For the tests.
const testing = std.testing;
const Ast = @import("../../Ast.zig");
const Node = Ast.Node;
const Tokenizer = @import("../../Tokenizer.zig");
const table = @import("../../table.zig");
const build = @import("../build.zig").build;
const expectResolved = Resolver.expectResolved;
const expectResolveError = Resolver.expectResolveError;
const expectAllResolved = Resolver.expectAllResolved;
const v = @import("../build.zig").v;
const n = @import("../build.zig").n;

// One layer of a field being resolved, and what a path to the field sees
// meanwhile. A ref or a pending that looks back is self-referential: the
// path sees the layers below it, as if the field were never written from
// here up. An object is not: the path sees it merged onto the layers below.
pub const Field = struct {
    place: *Value,
    below: []const Value,
    // What a path finds at the field, when it is an object: the object layer
    // being resolved, or the object right below a ref (see `seen`).
    object: ?*Value = null,
    // `below` merged, worked out on the first path that needs it.
    merged: ?Value = null,
    progress: enum { todo, busy, done } = .todo,
};

// Resolves the value of a field and stores it back, so the next ref there
// gets it for free: memoised per place, not per path.
pub fn resolveField(state: *Resolver, place: *Value) Error!?Value {
    const gpa = state.gpa;
    if (state.kept.contains(place)) return place.*;
    // A field written once is a stack of one.
    const one = [_]Value{place.*};
    const val = switch (place.*) {
        .stack => |layers| try state.resolveStack(place, layers),
        .ref, .pending => try state.resolveStack(place, &one),
        else => try state.resolveValue(place.*),
    } orelse return null;
    place.* = val;
    if (waits(val)) try state.kept.put(gpa, place, {});
    return val;
}

// The layers of a field, from the top: the top one decides, and the ones
// below are resolved only when it merges with them or looks back at them.
// Null when there is nothing, or an optional that found nothing is all there is.
pub fn resolveStack(state: *Resolver, place: *Value, layers: []const Value) Error!?Value {
    const gpa = state.gpa;
    if (layers.len == 0) return null;
    const top = layers[layers.len - 1];
    const below = layers[0 .. layers.len - 1];

    state.chain += 1;
    defer state.chain -= 1;
    // Said at a layer that has a place; an object layer has none, and the
    // one below it is a ref or a pending, or it would have merged.
    if (state.chain > Ast.max_depth) switch (top) {
        .ref => |r| {
            state.err_pos.* = r.at();
            return error.TooDeep;
        },
        .pending => |parts| {
            state.err_pos.* = parts[0].pos;
            return error.TooDeep;
        },
        else => {},
    };

    switch (top) {
        // Hides whatever is below it.
        .scalar, .array => return try state.resolveValue(top),
        // Looks forward, into itself merged with what was below it. The merge
        // goes first, so a key it has and the layers below have too is one
        // field with a stack of its own.
        .object => return try state.resolveObjectLayer(place, top, below),
        .ref, .pending => {
            // A list next to an object: a list, which hides what is below.
            if (!looksBack(top)) return try state.resolveValue(top);
            try state.fields.append(gpa, .{ .place = place, .below = below });
            const val = if (top == .ref) try state.resolveRef(top.ref, true) else try state.resolveValue(top);
            const field = state.fields.pop().?;
            // `.keep`: a self-reference, already the layers below over its
            // fallback (`resolveRef`).
            if (val != null and val.? == .stack) return val;

            // Gone, or an object that merges onto what was below: then that
            // counts. So does what is below a top that waits, to fall back to.
            if (val != null and val.? != .object and !waits(val.?)) return val;
            const under = if (field.progress == .done)
                field.merged
            else if (val != null and !waits(val.?) and !mergeable(below))
                null
            else
                try state.resolveStack(place, below);
            // An optional that found nothing leaves what was below in place.
            var result = val orelse return under;
            if (waits(result)) return try keep.stacked(gpa, under, result);
            if (under) |u| if (waits(u)) return try keep.stacked(gpa, u, result);
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

// An object layer of a field: merged onto the layers below, then resolved.
pub noinline fn resolveObjectLayer(state: *Resolver, place: *Value, top: Value, below: []const Value) Error!?Value {
    const gpa = state.gpa;
    var merged = top;
    const under = if (mergeable(below)) try state.resolveStack(place, below) else null;
    if (under) |u| if (u == .object) {
        merged = u;
        try merged.update(gpa, top);
    };
    const object = try state.placeFor(merged);
    // `.keep`: over what waits, a path into the field waits too.
    const seen_as = if (under != null and waits(under.?)) try state.placeFor(under.?) else object;
    try state.fields.append(gpa, .{ .place = place, .below = below, .object = seen_as });
    defer _ = state.fields.pop();
    // A path ending at the object itself is a cycle, `a : { b : ${a} }`.
    try state.visiting.append(gpa, object);
    defer _ = state.visiting.pop();
    const resolved = try state.resolveValue(object.*) orelse unreachable;
    // `.keep`: whether it merges onto what is below is known later.
    if (under) |u| if (waits(u)) return try keep.stacked(gpa, u, resolved);
    return resolved;
}

// A ref, or a concatenation with one among its parts: it may look back at
// what its key held before (spec L684). A list next to an object is not,
// with a ref inside them or not.
fn looksBack(value: Value) bool {
    if (value == .ref) return true;
    if (value != .pending) return false;
    for (value.pending) |part| {
        if (part.value == .ref) return true;
    }
    return false;
}

// Whether an object on top of these layers may merge with them. Text or a
// list on top of them never does, so they are not even looked at.
fn mergeable(layers: []const Value) bool {
    if (layers.len == 0) return false;
    const top = layers[layers.len - 1];
    return top == .object or looksBack(top);
}

// What a path finds at `place`: the place itself, unless it is a field being
// resolved (see `Field`). With nothing below, a ref back to the field it is
// in finds nothing, as if it named a missing path; one that came round
// through another field is a cycle, unless it is optional.
pub fn seen(state: *Resolver, place: *Value, ref: Ref) Error!?*Value {
    const gpa = state.gpa;
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
                if (ref.flags.optional) {
                    state.cycles += 1;
                    return null;
                }
                state.err_pos.* = ref.at();
                return Error.SubstitutionCycle;
            },
            .todo => {
                if (field.below.len == 0 and i + 1 < state.fields.items.len) {
                    if (!ref.flags.optional) {
                        state.err_pos.* = ref.at();
                        return Error.SubstitutionCycle;
                    }
                    state.cycles += 1;
                }
                const below = field.below;
                // An object that hides the layers under it: the path goes
                // into it, and resolves only the members it passes (spec
                // L776). In place, so they are done when the rest is needed.
                // Every path sees this one object, so one that leads back
                // into it is a cycle.
                if (below.len > 0 and below[below.len - 1] == .object and !mergeable(below[0 .. below.len - 1])) {
                    const object = try gpa.create(Value);
                    object.* = below[below.len - 1];
                    field.object = object;
                    return object;
                }
                field.progress = .busy;
                // Resolver appends to `fields`, so `field` may have moved.
                const merged = try state.resolveStack(place, below);
                state.fields.items[i].merged = merged;
                state.fields.items[i].progress = .done;
            },
        }
        return try state.placeFor(state.fields.items[i].merged orelse return null);
    }
    return place;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

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
// java ✓ · pyhocon ⚠️ WrongType on the first four rows and the cycle, ✓ on the
// fifth · spec ✓ — a path into the object below resolves only what it passes:
// `c` ends as `true`, which hides the object, and a substitution that is hidden
// is never looked at (spec L776). A member that leads back into it is a cycle.
test "resolve.a self-reference resolves only its path below" {
    try expectAllResolved(&.{
        .ok("c = { b = ${nope}, a = true }\nc : ${c.a}", "{\"c\":true}"),
        .ok("c = { b = ${nope} }\nc : { a = true }\nc : ${c.a}", "{\"c\":true}"),
        .ok("c = { b = 2, a = ${c.b} }\nc : ${c.a}", "{\"c\":2}"),
        .ok("c = { b = 1, a = true }\nc : ${c.a}\nd = ${c}", "{\"c\":true,\"d\":true}"),
        .ok("c = { a = { x = 1 } }\nc : ${c.a} { y = 2 }", "{\"c\":{\"a\":{\"x\":1},\"x\":1,\"y\":2}}"),
        .bad("c = { b = ${nope}, a = { x = 1 } }\nc : ${c.a}"),
    });
    try expectResolveError("c = { a = ${c} }\nc : ${c.a}", error.SubstitutionCycle);
}
// numerically-indexed-objects-to-arrays/003–008 · java ✓ · pyhocon ✗ (WrongType
// on every row that converts) · spec ✓ — next to a list, an object with numeric
// keys is a list of its values, ordered by the keys, gaps closed. Keys are read
// like java's `Integer.parseInt`, so `01` and `1` are one index, the later wins.
// Left to right: in the second to last row the list is `[0, 1]` before `{y : 3}`
// comes, and that has no numeric key. The last row is java ⚠️ `[1]`: java
// converts the object before `${?nope}` removes its only field; resolved, it is
// empty, and an empty object is not converted (spec L1212).
test "resolve.an object with numeric keys next to a list is a list" {
    try expectAllResolved(&.{
        .ok("a = [1, 2] { \"0\" : x, \"1\" : y }", "{\"a\":[1,2,\"x\",\"y\"]}"),
        .ok("a = { \"0\" : x, \"1\" : y } [1]", "{\"a\":[\"x\",\"y\",1]}"),
        .ok("a = [] { \"2\" : y, \"0\" : x }", "{\"a\":[\"x\",\"y\"]}"),
        .ok("a = [] { \"-1\" : z, \"0\" : x }", "{\"a\":[\"x\"]}"),
        .ok("a = [1] { \"0\" : x, foo : y }", "{\"a\":[1,\"x\"]}"),
        .ok("a = [] { \"01\" : x, \"1\" : y }", "{\"a\":[\"y\"]}"),
        .ok("a = [] { \"+1\" : x, \"-0\" : y, \"1_0\" : z, \"2147483648\" : w }", "{\"a\":[\"y\",\"x\"]}"),
        .ok("a = { 0 : x } { 1 : y } [] { 0 : z }", "{\"a\":[\"x\",\"y\",\"z\"]}"),
        // java ⚠️ reads any Unicode digit, `١` and `０` too: [1,"y","x"], [1,"x"]
        .ok("a = [1] { \"١\" : x, \"0\" : y }", "{\"a\":[1,\"y\"]}"),
        .bad("a = [1] { \"０\" : x }"),
        // through a substitution, the way a properties file makes a list
        .ok("a.0 = x\na.1 = y\nb = [] ${a}", "{\"a\":{\"0\":\"x\",\"1\":\"y\"},\"b\":[\"x\",\"y\"]}"),
        .ok("a = { 0 : x }\na = [] ${a}", "{\"a\":[\"x\"]}"),
        // a key written twice is one field, merged before it is an element
        .ok("a = [] { \"0\" : { x : 1 }, \"0\" : ${b} }\nb { y : 2 }", "{\"a\":[{\"x\":1,\"y\":2}],\"b\":{\"y\":2}}"),
        .bad("a = [1] {}"),
        .bad("a = [1] { b = 1 }"),
        .bad("a = [0] { \"0\" : 1, x : 2 } { y : 3 }"),
        .bad("a = [1] { \"0\" : ${?nope} }"),
        // no numeric key is known at load, so a later value does not hide it
        .bad("a = [1] {}\na = 2"),
        .bad("a = { x : 1 } [1]\na = 2"),
        .bad("a = [0] { \"0\" : 1, x : 2 } { y : 3 }\na = 2"),
        .ok("a = [1] { \"0\" : 1 }\na = 2", "{\"a\":2}"),
    });
}
// java ✓ · pyhocon ✓ on the first three rows, ⚠️ WrongType on the rest (no
// numeric keys) · spec ✓ — objects after a substitution merge before it has a
// value, as anywhere but right after a list: a field the later object hides is
// never looked at (spec L776), and two numeric objects are one before they join
// the list.
test "resolve.objects after a substitution merge first" {
    try expectAllResolved(&.{
        .ok("x = ${?nope} { c = ${missing} } { c = 1 }", "{\"x\":{\"c\":1}}"),
        .ok("b = { k = 1 }\nx = ${b} { c = ${missing} } { c = 1 }", "{\"b\":{\"k\":1},\"x\":{\"k\":1,\"c\":1}}"),
        .ok("x = [ ${?nope} { c = ${missing} } { c = 1 } ]", "{\"x\":[{\"c\":1}]}"),
        .ok("a = [1]\na = ${a} { \"0\" : tea } { \"0\" : coffee }", "{\"a\":[1,\"coffee\"]}"),
        .ok("b = [1]\na = ${b} { \"0\" : x } { y : 1 }", "{\"b\":[1],\"a\":[1,\"x\"]}"),
        .ok("a = [1] ${?n} { \"0\" : x } { \"0\" : y }", "{\"a\":[1,\"y\"]}"),
    });
}
// java ✓ (a cycle, the first three; the rest as here) · pyhocon ⚠️ WrongType,
// it converts no object · spec ✓ — a list next to an object is a list, with a
// substitution inside it or not, so it is not self-referential (spec L684): a
// ref in it to its own key is a cycle, and it hides what the key held before.
test "resolve.a list next to an object does not look back" {
    try expectResolveError("a = [5]\na = [${a}] { \"0\" : 2 }", error.SubstitutionCycle);
    try expectResolveError("a = { x : 5 }\na = [1] { \"0\" : ${a.x} }", error.SubstitutionCycle);
    try expectResolveError("a = { \"0\" : 5 }\na = { \"1\" : ${a} } [2]", error.SubstitutionCycle);
    try expectAllResolved(&.{
        .ok("a = [1] { \"0\" : ${nope} }\na = { x : 1 }", "{\"a\":{\"x\":1}}"),
        .ok("a = [1] { \"0\" : 2 }\na = ${?n}", "{\"a\":[1,2]}"),
        .ok("a = [1] { \"0\" : 2 }\na = ${a} [3]", "{\"a\":[1,2,3]}"),
    });
}
// self-referential-examples/014 (open review row) · java ✓ first row, ⚠️ second
// (1 and 1 again) · pyhocon ✓ · spec ✓ — two keys that refer to each other over
// a value of their own: the spec allows both 1, both 2, or an error (L875), only
// never two different values. Resolved in key order, the first key's own value
// below wins.
test "resolve.two keys over each other agree on one value" {
    try expectAllResolved(&.{
        .ok("a : 1\nb : 2\na : ${b}\nb : ${a}", "{\"a\":1,\"b\":1}"),
        .ok("b : 2\na : 1\nb : ${a}\na : ${b}", "{\"b\":2,\"a\":2}"),
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
// java ✓ (⚠️ last row) · pyhocon ⚠️ · spec ✓ — inside a list or an object a ref
// back to its own field is a cycle, and an optional one finds nothing there
// (spec L714), also with a value below. In the last row the object is empty
// once the ref is gone, so it does not convert (spec L1212); java converts it
// first and gives `[1]`. pyhocon keeps a null in the list, takes `5` from
// below, and fails on the numbered object.
test "resolve.an optional ref in a cycle finds nothing" {
    try expectAllResolved(&.{
        .ok("a = [${?a}]", "{\"a\":[]}"),
        .ok("a = 5\na = [${?a}]", "{\"a\":[]}"),
        .ok("a = { b : ${?a} }", "{\"a\":{}}"),
        .ok("a = [1] { \"0\" : ${?a}, \"1\" : 2 }", "{\"a\":[1,2]}"),
        .bad("a = [1] { \"0\" : ${?a} }"),
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
