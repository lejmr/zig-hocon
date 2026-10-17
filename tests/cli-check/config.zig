//! The type `hocon check --schema config.zig:Config` reads the files into: a
//! file of its own, as a program would have it, importing only std and hocon.
const std = @import("std");
const hocon = @import("hocon");

pub const Level = enum { debug, info, warn };

pub const Config = struct {
    name: []const u8,
    port: u16 = 8080,
    level: Level = .info,
    timeout: hocon.Duration = .of(30, .s),
    db: struct {
        host: []const u8 = "localhost",
        pool: u8 = 4,
    } = .{},
};

/// The same name in other letters, a type of its own: the check of one must
/// not run as the other, also where the file system ignores case.
pub const config = struct {
    name: []const u8,
    level: []const u8 = "",
};
