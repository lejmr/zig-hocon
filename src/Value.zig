//! Value holder for received data

const Key = @import("Key.zig");

const Value = @This();

// PLace holder for any string or number
const Scalar = struct {
    value: []const u8,
    quoted: bool,
};

const Array = struct {
    values: []const Scalar,
};

const Object = struct {
    members: []const Member,
};

const Member = struct { key: Key, value: union {
    scalar: Scalar,
    array: Array,
    obj: Object,
} };
