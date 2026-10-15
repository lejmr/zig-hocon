//! `include`: find the file, read it, and hand its object back to be merged in.
//!
//! Called from `Value.fromNode` where it meets an `.include` node inside a
//! block, one file at a time: the included file goes source → tree → value like
//! the main one does, and what comes back is an object. Nothing is resolved here;
//! substitutions wait for the finished document, so an included file sees keys
//! that are defined after the include, in the including file.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Node = @import("Ast.zig").Node;
const Ast = @import("Ast.zig");
const Tokenizer = @import("Tokenizer.zig").Tokenizer;
const Key = @import("Key.zig");
const unquote = @import("utils/unqoute.zig");
const values = @import("Value.zig");
const Value = values.Value;

pub const Error = error{
    /// `parseFromSlice` has no file system, so there is nothing to include from.
    IncludeNeedsFile,
    /// `required(…)` and the file is not there.
    IncludeNotFound,
    /// A file includes itself, directly or through others, or files nest more than 64 deep.
    IncludeCycle,
    /// `classpath(…)`, `url(…)` with something that is not an http, https or file URL,
    /// and a `.properties` line with a backslash (escapes are not decoded).
    UnsupportedInclude,
    /// The server answered with something other than success, not found or gone.
    IncludeFetchFailed,
    /// A fetch took longer than `ParseOptions.http_timeout`. Not a missing include,
    /// also under a plain `include`.
    IncludeTimeout,
    /// The included file is a list or a plain value, and only an object can be merged.
    IncludedRootNotObject,
    /// A `.json` file that is not JSON: unquoted values, trailing commas, duplicate keys …
    InvalidJson,
} || std.Io.Cancelable || std.Io.Dir.ReadFileAllocError || std.http.Client.FetchError || std.Uri.ResolveInPlaceError;

/// How deep files may include files. A cycle is caught by name long before this; the
/// limit is for names that never repeat: a server that makes up a new URL each time,
/// or a symlink loop the system does not stop.
const max_depth = 64;

/// How long one fetch may take, connect to last byte, unless the caller says otherwise.
pub const default_http_timeout = std.Io.Duration.fromSeconds(30);

/// A file read for an include may be as large as the main one the CLI reads.
pub const max_file_size = 64 * 1024 * 1024;

/// Which spelling of the argument was written.
const Kind = enum { plain, file, url, classpath };

/// What an include name points at: a path on this machine, or an http(s) URL.
const Target = union(enum) { local: []const u8, remote: []const u8 };

const Format = enum { hocon, json, properties };

/// Loads the object an `include` node stands for: empty when nothing is there
/// and the include is not `required`.
pub fn load(gpa: Allocator, node: Node, ctx: Value.Context) values.Error!Value {
    // The parser already checked the wrappers: `required`, then at most one kind.
    var required = false;
    var kind: Kind = .plain;
    for (node.children) |wrapper| {
        if (std.mem.eql(u8, wrapper.value, "required")) {
            required = true;
        } else if (std.mem.eql(u8, wrapper.value, "file")) {
            kind = .file;
        } else if (std.mem.eql(u8, wrapper.value, "url")) {
            kind = .url;
        } else {
            kind = .classpath;
        }
    }

    const name = (try unquote.unquote(gpa, node.value)).text;
    const target: Target = switch (kind) {
        // A URL when it starts with http:, https: or file:, or with any other scheme://
        // (refused in urlTarget); foo:bar.conf is a file name.
        .plain => blk: {
            if (urlScheme(name)) |scheme| {
                if (isSupportedScheme(scheme) or std.mem.startsWith(u8, name[scheme.len + 1 ..], "//")) {
                    break :blk try urlTarget(gpa, name);
                }
            }
            // Beside the file it was written in: a path, or a URL on the same server.
            if (ctx.base_url) |base| break :blk .{ .remote = try resolveUrl(gpa, base, name) };
            if (std.fs.path.isAbsolute(name)) break :blk .{ .local = name };
            break :blk .{ .local = try std.fs.path.join(gpa, &.{ ctx.dir, name }) };
        },
        // `file("…")` is not relative to the including file, but to wherever the
        // process is: the path is used as written.
        .file => .{ .local = name },
        .url => if (urlScheme(name) != null) try urlTarget(gpa, name) else return error.UnsupportedInclude,
        .classpath => return error.UnsupportedInclude,
    };

    const io = ctx.io orelse return error.IncludeNeedsFile;
    var merged: Value = .{ .object = &.{} };
    var found = false;
    switch (target) {
        .local => |path| {
            // A name with no extension is a basename: every file that exists of
            // path.properties, path.json and path.conf is loaded, later ones on top
            // of earlier ones.
            var probes: std.ArrayList([]const u8) = .empty;
            if (std.fs.path.extension(path).len != 0) {
                try probes.append(gpa, path);
            } else {
                for ([_][]const u8{ ".properties", ".json", ".conf" }) |extension| {
                    try probes.append(gpa, try std.mem.concat(gpa, u8, &.{ path, extension }));
                }
            }
            for (probes.items) |probe| {
                const included = try loadFile(gpa, io, probe, ctx) orelse continue;
                found = true;
                try merged.update(gpa, included);
            }
        },
        // ponytail: no basename probing over the network, one request per include;
        // add it if a server ever needs `include "https://host/base"` to find base.json.
        .remote => |url| {
            if (try loadUrl(gpa, io, url, ctx)) |included| {
                found = true;
                try merged.update(gpa, included);
            }
        },
    }
    if (!found and required) return error.IncludeNotFound;
    return merged;
}

/// The part before the first `:`, when the name starts like a URL: a letter, then
/// letters, digits, `+`, `-` or `.`. `sub/x.conf` and `x.conf` are not URLs.
fn urlScheme(name: []const u8) ?[]const u8 {
    if (name.len == 0 or !std.ascii.isAlphabetic(name[0])) return null;
    for (name, 0..) |c, i| {
        if (c == ':') return name[0..i];
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return null;
    }
    return null;
}

fn isSupportedScheme(scheme: []const u8) bool {
    for ([_][]const u8{ "http", "https", "file" }) |known| {
        if (std.ascii.eqlIgnoreCase(scheme, known)) return true;
    }
    return false;
}

/// A `file:` URL is the path in it, percent-decoded; http and https are fetched.
/// Any other scheme is an error: this is where `url("ftp://…")` ends.
fn urlTarget(gpa: Allocator, url: []const u8) values.Error!Target {
    const scheme = urlScheme(url).?;
    if (!isSupportedScheme(scheme)) return error.UnsupportedInclude;
    if (!std.ascii.eqlIgnoreCase(scheme, "file")) return .{ .remote = url };
    // ponytail: the host is ignored, `file://anyhost/x.conf` is `/x.conf` here; refuse a
    // host other than localhost if that ever misleads someone.
    const uri = try std.Uri.parse(url);
    // `%20` in a URL is a space in the file name.
    return .{ .local = try uri.path.toRawMaybeAlloc(gpa) };
}

// ponytail: the name is used as written; a character a URL may not hold (a space) is
// not percent-encoded and the server refuses it. Percent-encode the name before
// resolveInPlace when a real name needs it.
/// `name` as seen from the file at `base`, by the rules of RFC 3986.
fn resolveUrl(gpa: Allocator, base: []const u8, name: []const u8) values.Error![]const u8 {
    const base_uri = try std.Uri.parse(base);
    // The new text goes first; the rest is room for the merged path.
    const buffer = try std.mem.concat(gpa, u8, &.{ name, base, name });
    var rest: []u8 = buffer;
    const uri = try base_uri.resolveInPlace(name.len, &rest);
    return std.fmt.allocPrint(gpa, "{f}", .{uri.fmt(.{ .scheme = true, .authentication = true, .authority = true, .path = true, .query = true })});
}

/// The cycle check: this file may not be one that is being read right now.
fn checkCycle(ctx: Value.Context, id: []const u8) error{IncludeCycle}!void {
    if (ctx.stack.len >= max_depth) return error.IncludeCycle;
    for (ctx.stack) |open| {
        if (std.mem.eql(u8, open, id)) return error.IncludeCycle;
    }
}

/// Reads one file and turns it into an object; null when it does not exist.
fn loadFile(gpa: Allocator, io: std.Io, path: []const u8, ctx: Value.Context) values.Error!?Value {
    // `a/../b.conf` and `b.conf` are the same file as far as a cycle goes.
    const id = try std.fs.path.resolve(gpa, &.{path});
    try checkCycle(ctx, id);

    // Everything read lives as long as the document: values point into the text.
    const source = std.Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .limited(max_file_size), .of(u8), 0) catch |err| switch (err) {
        error.FileNotFound => return null,
        // The system gave up on a symlink loop before our own depth limit did.
        error.SymLinkLoop => return error.IncludeCycle,
        else => return err,
    };

    const child: Value.Context = .{
        .io = io,
        .http_timeout = ctx.http_timeout,
        .dir = std.fs.path.dirname(path) orelse "",
        .stack = try std.mem.concat(gpa, []const u8, &.{ ctx.stack, &.{id} }),
        .scope = try scopeOf(gpa, ctx),
    };
    return try parseSource(gpa, source, formatOfPath(path), child);
}

/// What a server answered: the body, and the type it named for it, if any.
const Fetched = struct { source: [:0]const u8, content_type: ?[]const u8 };

/// What the race in `fetchWithTimeout` can end with.
const Race = union(enum) { fetch: values.Error!?Fetched, timeout: std.Io.Cancelable!void };

/// `fetch`, given `timeout` for the whole of it. std's HTTP client has no timeout of its
/// own, so the fetch runs beside a sleep and whichever ends first decides.
fn fetchWithTimeout(gpa: Allocator, io: std.Io, uri: std.Uri, timeout: std.Io.Duration) values.Error!?Fetched {
    var results: [2]Race = undefined;
    var race = std.Io.Select(Race).init(io, &results);
    // Both need a thread of their own to run beside each other.
    // ponytail: with an Io that has none (single-threaded) there is no timeout; the
    // fetch then runs plain and a server that never answers hangs the parse.
    // Upgrade: none needed with std.Io.Threaded (the default); a single-threaded Io would
    // need a socket timeout, which std.http.Client does not offer yet.
    race.concurrent(.fetch, fetch, .{ gpa, io, uri }) catch return fetch(gpa, io, uri);
    // No thread left for the clock: the fetch already runs, and runs to its end.
    race.concurrent(.timeout, std.Io.sleep, .{ io, timeout, .awake }) catch {};
    // The loser is cancelled and waited for; what it returns is not needed.
    defer race.cancelDiscard();
    switch (try race.await()) {
        .fetch => |result| return result,
        .timeout => return error.IncludeTimeout,
    }
}

/// One GET. Null when the server says it is not there (404) or gone (410).
/// Apart from the connection everything is allocated from `gpa`, the document's.
fn fetch(gpa: Allocator, io: std.Io, uri: std.Uri) values.Error!?Fetched {
    // std's HTTP client; it is closed when this returns, before the answer is
    // parsed, so an include inside it opens its own connection.
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    // ponytail: redirects are followed by the client, but a relative include in
    // the answer is still resolved against the URL asked for, not the final one.
    // Upgrade: after receiveHead, request.uri is the final URL; return it from fetch
    // and use it as base_url.
    var request = try client.request(.GET, uri, .{
        // A compressed body would need a decompressor; ask for plain text.
        .headers = .{ .accept_encoding = .omit },
    });
    defer request.deinit();
    try request.sendBodiless();
    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);

    switch (response.head.status) {
        .not_found, .gone => return null,
        else => if (response.head.status.class() != .success) return error.IncludeFetchFailed,
    }
    // The head's strings are gone once the body is read.
    const content_type: ?[]const u8 = if (response.head.content_type) |t| try gpa.dupe(u8, t) else null;

    var transfer_buffer: [64]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    // As large as a file may be, and with the same 0 at the end.
    const source = reader.allocRemainingAlignedSentinel(gpa, .limited(max_file_size), .of(u8), 0) catch |err| switch (err) {
        // A bad body sets bodyErr; a failed read of the connection (reset, or cut
        // short by the timeout) leaves it null.
        error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
        else => return err,
    };
    return .{ .source = source, .content_type = content_type };
}

/// Fetches one URL and turns the answer into an object; null when it is not there.
fn loadUrl(gpa: Allocator, io: std.Io, url: []const u8, ctx: Value.Context) values.Error!?Value {
    try checkCycle(ctx, url);
    const uri = try std.Uri.parse(url);
    const fetched = try fetchWithTimeout(gpa, io, uri, ctx.http_timeout) orelse return null;

    // What the server says the file is wins over what its name looks like.
    const format = formatOfContentType(fetched.content_type) orelse formatOfPath(uri.path.percent_encoded);
    const child: Value.Context = .{
        .io = io,
        .base_url = url,
        .http_timeout = ctx.http_timeout,
        .stack = try std.mem.concat(gpa, []const u8, &.{ ctx.stack, &.{url} }),
        .scope = try scopeOf(gpa, ctx),
    };
    return try parseSource(gpa, fetched.source, format, child);
}

/// The type the server named, without `; charset=…`, if it is one we know.
fn formatOfContentType(content_type: ?[]const u8) ?Format {
    const full = content_type orelse return null;
    const media = std.mem.trim(u8, full[0 .. std.mem.indexOfScalar(u8, full, ';') orelse full.len], " \t");
    if (std.ascii.eqlIgnoreCase(media, "application/json")) return .json;
    if (std.ascii.eqlIgnoreCase(media, "text/x-java-properties")) return .properties;
    if (std.ascii.eqlIgnoreCase(media, "application/hocon")) return .hocon;
    return null;
}

/// By extension: `.json` and `.properties` are what they say, anything else is HOCON.
fn formatOfPath(path: []const u8) Format {
    const extension = std.fs.path.extension(path);
    if (std.mem.eql(u8, extension, ".json")) return .json;
    if (std.mem.eql(u8, extension, ".properties")) return .properties;
    return .hocon;
}

/// Where the keys of a file included from `ctx` sit in the whole document.
/// Substitutions in it get this in front of their path (see `Value.Ref`).
fn scopeOf(gpa: Allocator, ctx: Value.Context) Allocator.Error![]const Key {
    var keys: std.ArrayList(Key) = .empty;
    var frame = ctx.frame;
    while (frame) |f| {
        try keys.append(gpa, f.key);
        frame = f.parent;
    }
    // The frames came innermost first.
    std.mem.reverse(Key, keys.items);
    return std.mem.concat(gpa, Key, &.{ ctx.scope, keys.items });
}

fn parseSource(gpa: Allocator, source: [:0]const u8, format: Format, child: Value.Context) values.Error!Value {
    // ponytail: errors name no file; #5 will say which file an error is in.
    const object = switch (format) {
        .json => try fromJson(gpa, source),
        .properties => try fromProperties(gpa, source),
        .hocon => blk: {
            var parser = Ast.Parser{ .gpa = gpa, .t = .{ .t = Tokenizer.init(source) } };
            const tree = try parser.parse();
            // `[1, 2]` as a whole document is a list: java's WrongType.
            if (tree.children.len == 1 and tree.children[0].kind == .array) return error.IncludedRootNotObject;
            break :blk try Value.fromNode(gpa, tree, child);
        },
    };
    if (object != .object) return error.IncludedRootNotObject;
    return object;
}

/// Strict JSON: what std.json accepts, with duplicate keys refused. Numbers keep
/// the text they were written with, as they do in a HOCON file. A key is a plain
/// string, never a path: `{"a.b": 1}` is one key.
fn fromJson(gpa: Allocator, source: []const u8) values.Error!Value {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, gpa, source, .{
        .parse_numbers = false,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        // Without this, a failed allocation would report bad JSON.
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    return fromJsonValue(gpa, parsed);
}

fn fromJsonValue(gpa: Allocator, json: std.json.Value) Allocator.Error!Value {
    switch (json) {
        // true, false, null and numbers are unquoted text, as they would be in HOCON.
        .null => return .{ .scalar = .{ .value = "null", .quoted = false } },
        .bool => |b| return .{ .scalar = .{ .value = if (b) "true" else "false", .quoted = false } },
        .number_string => |text| return .{ .scalar = .{ .value = text, .quoted = false } },
        .string => |text| return .{ .scalar = .{ .value = text, .quoted = true } },
        .array => |items| {
            var list: std.ArrayList(Value) = .empty;
            for (items.items) |item| try list.append(gpa, try fromJsonValue(gpa, item));
            return .{ .array = try list.toOwnedSlice(gpa) };
        },
        .object => |map| {
            var members: std.ArrayList(values.Member) = .empty;
            for (map.keys(), map.values()) |key, item| {
                try members.append(gpa, .{ .key = .{ .value = key }, .value = try fromJsonValue(gpa, item) });
            }
            return .{ .object = try members.toOwnedSlice(gpa) };
        },
        // Not produced with `parse_numbers = false`.
        .integer, .float => unreachable,
    }
}

/// A key of a properties file and what is below it. A key can be a value and a
/// parent at once (`a=4` next to `a.b=1`); then the parent wins.
const Property = struct {
    text: ?[]const u8 = null,
    children: std.StringArrayHashMapUnmanaged(Property) = .empty,
};

/// Java properties: `key = value` or `key : value`, one per line; `#` and `!`
/// start a comment; values are strings and a dotted key is a path.
///
/// A key ends at the first `=`, `:` or whitespace, as in java.util.Properties.
fn fromProperties(gpa: Allocator, source: []const u8) values.Error!Value {
    var root: Property = .{};
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == '!') continue;

        // ponytail: escapes and `\` continuations are not decoded, so a line with a
        // backslash is refused rather than read wrong. Decode them when a real file needs it.
        if (std.mem.indexOfScalar(u8, line, '\\') != null) return error.UnsupportedInclude;

        const at = std.mem.indexOfAny(u8, line, "=: \t") orelse line.len;
        const key = line[0..at];
        // `key = value`, `key value` and `key: value` are the same line.
        var rest = std.mem.trimStart(u8, line[at..], " \t");
        if (rest.len > 0 and (rest[0] == '=' or rest[0] == ':')) rest = rest[1..];
        const text = std.mem.trim(u8, rest, " \t");

        var current = &root;
        var elements = std.mem.splitScalar(u8, key, '.');
        while (elements.next()) |element| {
            const entry = try current.children.getOrPut(gpa, element);
            if (!entry.found_existing) entry.value_ptr.* = .{};
            current = entry.value_ptr;
        }
        current.text = text;
    }
    return propertyToValue(gpa, root);
}

fn propertyToValue(gpa: Allocator, property: Property) Allocator.Error!Value {
    if (property.children.count() == 0) {
        return .{ .scalar = .{ .value = property.text orelse "", .quoted = true } };
    }
    var members: std.ArrayList(values.Member) = .empty;
    for (property.children.keys(), property.children.values()) |key, child| {
        try members.append(gpa, .{ .key = .{ .value = key }, .value = try propertyToValue(gpa, child) });
    }
    return .{ .object = try members.toOwnedSlice(gpa) };
}

// ---------------------------------------------------------------------------
// Tests
//
// Oracle columns: java is the conformance suite's own `--java` result for the
// rows named. pyhocon passes include-merging and include-missing-and-required,
// but only 3 of 23 file-format rows and 12 of 19 substitution rows
// (conformance/run.sh --spec with adapters/oracle.sh hocon-py), so it is marked –
// unless it was run on the case.
// ---------------------------------------------------------------------------

const testing = std.testing;
const Config = @import("Config.zig").Config;

/// A file to write before parsing: its path inside the temp directory, and what is in it.
const Fixture = struct { path: []const u8, text: []const u8 };

/// Writes the fixtures into a fresh temp directory and parses the first one,
/// the way the CLI would: through its path. Returns the result as JSON.
///
/// A fixture may name its own directory, since a test cannot know it up front:
/// `{abs}` is its absolute path and `{rel}` the path from the working directory,
/// which is where the test runs.
fn parseFixtures(arena: Allocator, files: []const Fixture) ![]const u8 {
    return parseFixturesWith(arena, files, .{});
}

fn parseFixturesWith(arena: Allocator, files: []const Fixture, options: Config.ParseOptions) ![]const u8 {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const rel = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const abs = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    for (files) |f| {
        if (std.fs.path.dirname(f.path)) |sub| try tmp.dir.createDirPath(testing.io, sub);
        const with_abs = try std.mem.replaceOwned(u8, arena, f.text, "{abs}", abs);
        const text = try std.mem.replaceOwned(u8, arena, with_abs, "{rel}", rel);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = f.path, .data = text });
    }
    const main = try std.fs.path.join(arena, &.{ rel, files[0].path });
    const value = try Config.parseFromFileLeaky(Value, arena, testing.io, main, options);
    return std.json.Stringify.valueAlloc(arena, value, .{});
}

fn expectJson(files: []const Fixture, want: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(want, try parseFixtures(arena.allocator(), files));
}

fn expectError(files: []const Fixture, want: anyerror) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(want, parseFixtures(arena.allocator(), files));
}

// include-locating/002, 003 · java ✓ · pyhocon – · spec ✓ — a plain name is a
// file beside the including one, and that holds for an include made from a file
// that was itself included: `sub/inner.conf` finds `x.conf` in `sub/`, not next
// to `main.conf` and not in the working directory.
test "include.a plain name is found beside the including file" {
    try expectJson(&.{
        .{ .path = "main.conf", .text = "own = 1\ninclude \"x.conf\"" },
        .{ .path = "x.conf", .text = "x = adjacent" },
    }, "{\"own\":1,\"x\":\"adjacent\"}");

    try expectJson(&.{
        .{ .path = "main.conf", .text = "include \"sub/inner.conf\"" },
        .{ .path = "sub/inner.conf", .text = "include \"x.conf\"" },
        .{ .path = "sub/x.conf", .text = "a = 1" },
        .{ .path = "x.conf", .text = "a = wrong" },
    }, "{\"a\":1}");
}

// include-locating/004, 005 · java ✓ · pyhocon – · spec ✓ — an absolute path is
// not looked for beside the including file, and `file("…")` is a path from the
// working directory, not from the including file: here `main.conf` lives in
// `sub/`, and `{rel}/x.conf` only exists when read from where the test runs.
// (The suite's rows 004 and 005 are about the file *not* being found; that half
// needs a missing include and is in the next test group.)
test "include.absolute and file() paths do not start at the including file" {
    try expectJson(&.{
        .{ .path = "sub/main.conf", .text = "include \"{abs}/elsewhere/x.conf\"" },
        .{ .path = "elsewhere/x.conf", .text = "a = absolute" },
    }, "{\"a\":\"absolute\"}");

    try expectJson(&.{
        .{ .path = "sub/main.conf", .text = "include file(\"{rel}/x.conf\")" },
        .{ .path = "x.conf", .text = "a = from the working directory" },
    }, "{\"a\":\"from the working directory\"}");
}

// include-locating/001 · java ✓ · pyhocon – — a quoted string with a scheme is a
// URL, and a `file:` URL is the path behind it, `//` or not, in any case, with
// `%20` and the like decoded. Other schemes are refused (next tests); http and
// https are fetched (see "include.http"). pyhocon: `file:` is not understood.
test "include.a file URL is a path" {
    try expectJson(&.{
        .{ .path = "main.conf", .text = "include \"file:{abs}/x.conf\"\ninclude url(\"file://{abs}/y.conf\")\ninclude \"FILE://{abs}/z%20z.conf\"" },
        .{ .path = "x.conf", .text = "x = 1" },
        .{ .path = "y.conf", .text = "y = 2" },
        .{ .path = "z z.conf", .text = "z = 3" },
    }, "{\"x\":1,\"y\":2,\"z\":3}");
}

// include-syntax/011 · java ✓ for url("x.conf"), – for the others · pyhocon – ·
// spec – (open review row) — what we do with the URL forms we cannot follow.
// `classpath()` has no classpath to look in, and `url()` wants an http, https or
// file URL (java: "include url() specifies an invalid URL"). Needs no file
// system: refused before anything is read, so a slice gets the same answer.
test "include.url() and classpath() refuse what they cannot follow" {
    for ([_][:0]const u8{
        "include url(\"ftp://example.org/x.conf\")",
        "include \"ftp://example.org/x.conf\"",
        "include classpath(\"x.conf\")",
        "include url(\"x.conf\")",
        "include url(\"foo:x.conf\")",
        "include required(classpath(\"x.conf\"))",
    }) |source| {
        try testing.expectError(error.UnsupportedInclude, Config.parseFromSlice(Value, testing.allocator, source));
    }
}

// spec L1111–1116 · java ✓ · pyhocon ✓ for foo:bar.conf (both read it as a file
// name; ftp:// was not run on java, which would fetch it) — a bare string is a
// URL for a scheme we follow (http, https, file), and for any other `scheme://`
// too, which is refused (above); `foo:bar.conf` has no `//` and is a file name.
test "include.a name that only looks like a URL is a file name" {
    try expectJson(&.{
        .{ .path = "main.conf", .text = "include \"foo:bar.conf\"" },
        .{ .path = "foo:bar.conf", .text = "a = 1" },
    }, "{\"a\":1}");
}

// java – · pyhocon – · spec – — ours alone: a slice has no files, so an include
// in it is an error instead of a silently empty object.
test "include.a document from a slice cannot include" {
    try testing.expectError(error.IncludeNeedsFile, Config.parseFromSlice(Value, testing.allocator, "include \"x.conf\""));
    try testing.expectError(error.IncludeNeedsFile, Config.parseFromSlice(Value, testing.allocator, "a { include file(\"x.conf\") }"));
}

// include-merging/001, 004, 005–010 · java ✓ · pyhocon – · spec ✓ — the included
// object stands where the include is: keys land between the ones around it, in a
// nested object and in an object that is a list element, and a key that is
// already there is merged or replaced by the usual duplicate-key rules, in both
// directions (the included key after the earlier one, the later key after the
// included one).
test "include.included keys merge in place" {
    try expectJson(&.{
        .{ .path = "main.conf", .text = "a = 1\ninclude \"common.conf\"\nc = 3" },
        .{ .path = "common.conf", .text = "b = 2" },
    }, "{\"a\":1,\"b\":2,\"c\":3}");

    try expectJson(&.{
        .{ .path = "main.conf", .text = "a {\n  x = 1\n  include \"inner.conf\"\n  z = 3\n}" },
        .{ .path = "inner.conf", .text = "y = 2" },
    }, "{\"a\":{\"x\":1,\"y\":2,\"z\":3}}");

    try expectJson(&.{
        .{ .path = "main.conf", .text = "a = [ { include \"child.conf\" } ]" },
        .{ .path = "child.conf", .text = "x = 1" },
    }, "{\"a\":[{\"x\":1}]}");

    // An included scalar replaces an earlier one, and an earlier object.
    try expectJson(&.{
        .{ .path = "main.conf", .text = "a = 1\ninclude \"over.conf\"" },
        .{ .path = "over.conf", .text = "a = 2" },
    }, "{\"a\":2}");
    try expectJson(&.{
        .{ .path = "main.conf", .text = "a { x = 1 }\ninclude \"over.conf\"" },
        .{ .path = "over.conf", .text = "a = 2" },
    }, "{\"a\":2}");

    // Objects merge, whichever side is the included one.
    try expectJson(&.{
        .{ .path = "main.conf", .text = "a { x = 1 }\ninclude \"merge.conf\"" },
        .{ .path = "merge.conf", .text = "a { y = 2 }" },
    }, "{\"a\":{\"x\":1,\"y\":2}}");
    try expectJson(&.{
        .{ .path = "main.conf", .text = "include \"base.conf\"\na { y = 2 }" },
        .{ .path = "base.conf", .text = "a { x = 1 }" },
    }, "{\"a\":{\"x\":1,\"y\":2}}");

    // A later scalar replaces the included one.
    try expectJson(&.{
        .{ .path = "main.conf", .text = "include \"base.conf\"\na = 2" },
        .{ .path = "base.conf", .text = "a = 1" },
    }, "{\"a\":2}");

    // A braced root works the same, and the included file may include more.
    try expectJson(&.{
        .{ .path = "main.conf", .text = "{ include \"one.conf\" }" },
        .{ .path = "one.conf", .text = "include \"two.conf\"\none = 1" },
        .{ .path = "two.conf", .text = "two = 2" },
    }, "{\"two\":2,\"one\":1}");
}

// config-and-file-merging/002–005 · java ✓ · pyhocon – · spec ✓ — the spec's own
// examples of merging files: objects present in both merge recursively, a
// non-object in between hides everything under it (merging is done in pairs),
// and null clears an object so the next one starts over.
test "include.files merge like duplicate keys" {
    try expectJson(&.{
        .{ .path = "main.conf", .text = "include \"defaults.conf\"\na {\n  b { y : 2 }\n  k : \"override\"\n}" },
        .{ .path = "defaults.conf", .text = "a {\n  b { x : 1 }\n  k : \"default\"\n}" },
    }, "{\"a\":{\"b\":{\"x\":1,\"y\":2},\"k\":\"override\"}}");

    try expectJson(&.{
        .{ .path = "main.conf", .text = "include \"another-fallback.conf\"\ninclude \"fallback.conf\"\na : { x : 1 }" },
        .{ .path = "another-fallback.conf", .text = "a : { y : 2 }" },
        .{ .path = "fallback.conf", .text = "a : 42" },
    }, "{\"a\":{\"x\":1}}");

    try expectJson(&.{
        .{ .path = "main.conf", .text = "include \"another-fallback.conf\"\ninclude \"fallback.conf\"\na : { x : 1 }" },
        .{ .path = "another-fallback.conf", .text = "a : 42" },
        .{ .path = "fallback.conf", .text = "a : { y : 2 }" },
    }, "{\"a\":{\"y\":2,\"x\":1}}");

    try expectJson(&.{
        .{ .path = "main.conf", .text = "include \"defaults.conf\"\na : null\na { z : 3 }" },
        .{ .path = "defaults.conf", .text = "a {\n  x : 1\n  y : 2\n}" },
    }, "{\"a\":{\"z\":3}}");
}

// include-merging/002 · java ✓ · pyhocon – · spec ✓ — an included file must hold
// an object; a list as the root is an error (java: WrongType).
test "include.a list as the root is not an object" {
    try expectError(&.{
        .{ .path = "main.conf", .text = "include \"list.conf\"" },
        .{ .path = "list.conf", .text = "[1, 2]" },
    }, error.IncludedRootNotObject);
}

// java ✓ (Parse error) · pyhocon – (never returns) · spec ✓ — a file that
// includes itself, or two that include each other, ends in an error instead of
// never ending. Java: "include statement ... would cause a cycle"
// (ConfigException.Parse). A name that differs on paper (`./a.conf`,
// `sub/../a.conf`) is the same file.
test "include.a cycle is an error" {
    try expectError(&.{
        .{ .path = "main.conf", .text = "include \"main.conf\"" },
    }, error.IncludeCycle);

    try expectError(&.{
        .{ .path = "main.conf", .text = "a = 1\ninclude \"b.conf\"" },
        .{ .path = "b.conf", .text = "include \"c.conf\"" },
        .{ .path = "c.conf", .text = "include \"sub/../b.conf\"" },
    }, error.IncludeCycle);
}

// java – · pyhocon – · spec – — ours alone: files nest at most 64 deep, so a chain
// of 65 ends in an error even though no name repeats (a server that makes up a
// new URL each time would do the same).
test "include.more than 64 files deep is a cycle" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var files: [65]Fixture = undefined;
    for (&files, 0..) |*f, depth| {
        f.* = .{
            .path = try std.fmt.allocPrint(a, "f{d}.conf", .{depth}),
            .text = try std.fmt.allocPrint(a, "include \"f{d}.conf\"", .{depth + 1}),
        };
    }
    try testing.expectError(error.IncludeCycle, parseFixtures(a, &files));
}

// java – · pyhocon – · spec – — ours alone: a symlink makes a new name for the same
// file every time round, so the names never repeat. The system's own limit on
// symlinks (or ours on depth, whichever is first) stops it. `loop` points at its
// own directory.
test "include.a symlink loop is a cycle" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.symLink(testing.io, ".", "loop", .{ .is_directory = true });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "main.conf", .data = "include \"loop/main.conf\"" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const main = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}/main.conf", .{tmp.sub_path});
    try testing.expectError(error.IncludeCycle, Config.parseFromFileLeaky(Value, arena.allocator(), testing.io, main, .{}));
}

// include-locating/001, 004, 005, include-missing-and-required/001–003 · java ✓ ·
// pyhocon – · spec ✓ — a file that is not there is an empty object, wherever the
// include stands, however it is spelled. That is also what makes the locating
// rows observable: an absolute path is not looked up beside the including file
// (a file of that name sits there and is not loaded), and `file("x.conf")`
// starts at the working directory, not at `sub/` where `x.conf` is.
test "include.a missing file is an empty object" {
    try expectJson(&.{
        .{ .path = "main.conf", .text = "a = 1\ninclude \"nope.conf\"\nb = 2" },
    }, "{\"a\":1,\"b\":2}");
    try expectJson(&.{
        .{ .path = "main.conf", .text = "a { include \"nope.conf\" }" },
    }, "{\"a\":{}}");
    try expectJson(&.{
        .{ .path = "main.conf", .text = "a = 1\ninclude file(\"nope.conf\")\nb = 2" },
    }, "{\"a\":1,\"b\":2}");
    try expectJson(&.{
        .{ .path = "main.conf", .text = "include \"file:does-not-exist.txt\"" },
    }, "{}");
    try expectJson(&.{
        .{ .path = "main.conf", .text = "own = 1\ninclude \"/zig-hocon-absolute-include-marker.conf\"" },
        .{ .path = "zig-hocon-absolute-include-marker.conf", .text = "marker = relativized" },
    }, "{\"own\":1}");
    try expectJson(&.{
        .{ .path = "sub/main.conf", .text = "own = 1\ninclude file(\"x.conf\")" },
        .{ .path = "sub/x.conf", .text = "x = beside" },
    }, "{\"own\":1}");
}

// include-missing-and-required/004–006, include-file-formats/005 · java ✓ ·
// pyhocon – · spec ✓ — `required()` turns a missing file into an error, around
// a file() too and around a basename; one that is there is included as usual.
test "include.required fails when nothing is there" {
    try expectError(&.{
        .{ .path = "main.conf", .text = "a = 1\ninclude required(\"nope.conf\")\nb = 2" },
    }, error.IncludeNotFound);
    try expectError(&.{
        .{ .path = "main.conf", .text = "include required(file(\"nope.conf\"))" },
    }, error.IncludeNotFound);
    try expectError(&.{
        .{ .path = "main.conf", .text = "include required(\"nothing\")" },
    }, error.IncludeNotFound);
    try expectJson(&.{
        .{ .path = "main.conf", .text = "a = 1\ninclude required(\"common.conf\")\nc = 3" },
        .{ .path = "common.conf", .text = "b = 2" },
    }, "{\"a\":1,\"b\":2,\"c\":3}");
}

// include-file-formats/001–004, 025, 026 · java ✓ · pyhocon – · spec ✓ — a name
// without an extension is a basename: every one of base.properties, base.json and
// base.conf that exists is loaded, in that order, so the last one wins where they
// overlap; none of them is a missing include. A name with an extension, any
// extension, is that one file (024: x.txt is HOCON; java diverges and finds
// nothing there). A dot first is no extension: `.env` is a basename, as in java.
test "include.a basename loads properties, then json, then conf" {
    try expectJson(&.{
        .{ .path = "main.conf", .text = "include \".env\"" },
        .{ .path = ".env.conf", .text = "a = 1" },
    }, "{\"a\":1}");
    try expectJson(&.{
        .{ .path = "main.conf", .text = "include \"base\"" },
        .{ .path = "base.conf", .text = "a = conf\nc = conf" },
        .{ .path = "base.json", .text = "{\"a\": \"json\", \"b\": \"json\", \"d\": \"json\"}" },
        .{ .path = "base.properties", .text = "a=props\nb=props\nc=props\ne=props" },
    }, "{\"a\":\"conf\",\"b\":\"json\",\"c\":\"conf\",\"e\":\"props\",\"d\":\"json\"}");
    try expectJson(&.{
        .{ .path = "main.conf", .text = "include \"base\"" },
        .{ .path = "base.conf", .text = "a = 1" },
    }, "{\"a\":1}");
    try expectJson(&.{
        .{ .path = "main.conf", .text = "include \"base\"" },
        .{ .path = "base.properties", .text = "a=1" },
    }, "{\"a\":\"1\"}");
    try expectJson(&.{
        .{ .path = "main.conf", .text = "include \"nothing\"" },
    }, "{}");
    try expectJson(&.{
        .{ .path = "main.conf", .text = "include \"base\"" },
        .{ .path = "base.properties", .text = "a=props" },
        .{ .path = "base.json", .text = "{\"a\": \"json\"}" },
    }, "{\"a\":\"json\"}");
    try expectJson(&.{
        .{ .path = "main.conf", .text = "include \"x.txt\"" },
        .{ .path = "x.txt", .text = "a = 1" },
    }, "{\"a\":1}");
}

// include-file-formats/010, 022 · java ✓ · pyhocon – · spec ✓ — JSON values keep
// their types (numbers as written, strings quoted) and a key is one key, dots
// and all.
test "include.json keeps its types and its keys" {
    try expectJson(&.{
        .{ .path = "main.conf", .text = "include \"x.json\"" },
        .{ .path = "x.json", .text = "{\"a\": 1, \"b\": [1, 2], \"c\": {\"d\": true, \"e\": null}, \"f\": \"1\", \"g\": 1e5}" },
    }, "{\"a\":1,\"b\":[1,2],\"c\":{\"d\":true,\"e\":null},\"f\":\"1\",\"g\":1e5}");
    try expectJson(&.{
        .{ .path = "main.conf", .text = "include \"x.json\"" },
        .{ .path = "x.json", .text = "{\"a.b\": 1}" },
    }, "{\"a.b\":1}");
}

// include-merging/003, include-file-formats/006, 011–017, 019, 020, 023 ·
// java ⚠️ lenient on 006 and 023 (it parses a named .json as HOCON; the conformance
// sidecar says so) · pyhocon –
// · spec ✓ — a .json file is strict JSON: no unquoted values, substitutions,
// trailing commas, missing commas, duplicate keys, leading zeros, numbers or
// unquoted words as keys; the document is one object and not nothing.
test "include.json is strict" {
    for ([_][]const u8{
        "{\"a\": b}",
        "{\"a\": ${x}}",
        "{\"a\": 1,}",
        "{\"a\": 1, \"a\": 2}",
        "{\"a\": [1 2]}",
        "",
        "{1: 2}",
        "{\"a\": 1\n\"b\": 2}",
        "{\"a\": 01}",
        "{\"a\": 1} {\"b\": 2}",
    }) |text| {
        try expectError(&.{
            .{ .path = "main.conf", .text = "include \"x.json\"" },
            .{ .path = "x.json", .text = text },
        }, error.InvalidJson);
    }
    for ([_][]const u8{ "42", "[1, 2]", "\"a\"" }) |text| {
        try expectError(&.{
            .{ .path = "main.conf", .text = "include \"x.json\"" },
            .{ .path = "x.json", .text = text },
        }, error.IncludedRootNotObject);
    }
}

// include-file-formats/007, 008 · java ✓ (007 java: unsupported — it parses a named
// .properties as HOCON) · pyhocon – · spec ✓ — the first `=`, `:` or whitespace
// ends the key, values are strings, a dotted key is a path, and when a key is both
// a value and a parent the object wins whichever comes first. Comments and blank
// lines are skipped. A line with a backslash is refused: escapes and continuations
// are not decoded.
test "include.properties" {
    try expectJson(&.{
        .{ .path = "main.conf", .text = "include \"x.properties\"" },
        .{ .path = "x.properties", .text = "# a comment\n\n! another\na=b=c\nn : 1\n  spaced  =  out  \nlonely  words here" },
    }, "{\"a\":\"b=c\",\"n\":\"1\",\"spaced\":\"out\",\"lonely\":\"words here\"}");
    try expectJson(&.{
        .{ .path = "main.conf", .text = "include \"x\"" },
        .{ .path = "x.properties", .text = "a.b=1\na.c=2\nd=3\na=4\ne.f.g=5" },
    }, "{\"a\":{\"b\":\"1\",\"c\":\"2\"},\"d\":\"3\",\"e\":{\"f\":{\"g\":\"5\"}}}");
    try expectJson(&.{
        .{ .path = "main.conf", .text = "include \"x\"" },
        .{ .path = "x.properties", .text = "a=4\na.b=1" },
    }, "{\"a\":{\"b\":\"1\"}}");
    try expectError(&.{
        .{ .path = "main.conf", .text = "include \"x.properties\"" },
        .{ .path = "x.properties", .text = "a = one \\\n  two" },
    }, error.UnsupportedInclude);
}

// include-substitution/001, 003–007, 009–011, 013, 015–017 · java ✓ except
// 009 (unsupported) and 011 (diverges) · pyhocon – · spec ✓ — a substitution in
// an included file is looked up with the key path of the include in front, and
// when that finds nothing, or the value vanishes (an optional that was undefined),
// as written from the root. Substitutions are resolved after everything is
// merged, so the fixed-up path sees keys defined later in the including file.
// 012 and 018 need merge stacks (#7) and 008 the environment (#11).
test "include.substitutions are relative to the include, then to the root" {
    // 001: a.x
    try expectJson(&.{
        .{ .path = "main.conf", .text = "{ a : { include \"foo.conf\" } }" },
        .{ .path = "foo.conf", .text = "{ x : 10, y : ${x} }" },
    }, "{\"a\":{\"x\":10,\"y\":10}}");
    // 003: no a.x, so the root x
    try expectJson(&.{
        .{ .path = "main.conf", .text = "{\n x : 7\n a : { include \"foo.conf\" }\n}" },
        .{ .path = "foo.conf", .text = "{ y : ${x} }" },
    }, "{\"x\":7,\"a\":{\"y\":7}}");
    // 004: a.x first
    try expectJson(&.{
        .{ .path = "main.conf", .text = "{\n x : 7\n a : { include \"foo.conf\" }\n}" },
        .{ .path = "foo.conf", .text = "{ x : 10, y : ${x} }" },
    }, "{\"x\":7,\"a\":{\"x\":10,\"y\":10}}");
    // 005: neither
    try expectError(&.{
        .{ .path = "main.conf", .text = "{ a : { include \"foo.conf\" } }" },
        .{ .path = "foo.conf", .text = "{ y : ${x} }" },
    }, error.Unresolved);
    // 006: optional, neither: omitted
    try expectJson(&.{
        .{ .path = "main.conf", .text = "{ a : { include \"foo.conf\" } }" },
        .{ .path = "foo.conf", .text = "{ z : 1, y : ${?x} }" },
    }, "{\"a\":{\"z\":1}}");
    // 007: through two levels, a.b.x
    try expectJson(&.{
        .{ .path = "main.conf", .text = "{ a : { include \"foo.conf\" } }" },
        .{ .path = "foo.conf", .text = "{ b : { include \"bar.conf\" } }" },
        .{ .path = "bar.conf", .text = "{ x : 1, y : ${x} }" },
    }, "{\"a\":{\"b\":{\"x\":1,\"y\":1}}}");
    // 009, 011, 013: the fixed-up path is there but holds nothing useful
    try expectJson(&.{
        .{ .path = "main.conf", .text = "common { include \"child.conf\" }\nx.y = 0" },
        .{ .path = "child.conf", .text = "x.y = ${?nope}\na = ${x.y}" },
    }, "{\"common\":{\"x\":{},\"a\":0},\"x\":{\"y\":0}}");
    try expectJson(&.{
        .{ .path = "main.conf", .text = "common { include \"child.conf\" }\nx.y = 0" },
        .{ .path = "child.conf", .text = "x.y = ${?nope}\na = ${?x.y}" },
    }, "{\"common\":{\"x\":{},\"a\":0},\"x\":{\"y\":0}}");
    try expectJson(&.{
        .{ .path = "main.conf", .text = "common { include \"child.conf\" }\nx.y = 0" },
        .{ .path = "child.conf", .text = "x = {}\na = ${x.y}" },
    }, "{\"common\":{\"x\":{},\"a\":0},\"x\":{\"y\":0}}");
    // 010, 015: undefined at both paths
    try expectError(&.{
        .{ .path = "main.conf", .text = "common { include \"child.conf\" }" },
        .{ .path = "child.conf", .text = "x.y = ${?does-not-exist}\na = ${x.y}" },
    }, error.Unresolved);
    try expectError(&.{
        .{ .path = "main.conf", .text = "common { include \"child.conf\" }\nx.y = ${?nope2}" },
        .{ .path = "child.conf", .text = "x.y = ${?nope}\na = ${x.y}" },
    }, error.Unresolved);
    // 016, 017: inside a concatenation and inside a list
    try expectJson(&.{
        .{ .path = "main.conf", .text = "p { include \"child.conf\" }\nx = 1" },
        .{ .path = "child.conf", .text = "a = ${x} y" },
    }, "{\"p\":{\"a\":\"1 y\"},\"x\":1}");
    try expectJson(&.{
        .{ .path = "main.conf", .text = "p { include \"child.conf\" }\nx = 1" },
        .{ .path = "child.conf", .text = "l = [ ${x} ]" },
    }, "{\"p\":{\"l\":[1]},\"x\":1}");
}

// include-substitution/002, 019 · java ✓ · pyhocon – · spec ✓ — the included
// file is never resolved on its own: substitutions wait for the finished
// document. So the parent's later `a : { x : 42 }` wins over the included
// `x : 10`, and `a.x = null`, set by the parent after the include, is found.
test "include.an included file is resolved with the whole document" {
    // 002: the later redefinition of a.x is the one seen
    try expectJson(&.{
        .{ .path = "main.conf", .text = "{\n a : { include \"foo.conf\" }\n a : { x : 42 }\n}" },
        .{ .path = "foo.conf", .text = "{ x : 10, y : ${x} }" },
    }, "{\"a\":{\"x\":42,\"y\":42}}");
    // 019: null at the fixed-up path is a value, found
    try expectJson(&.{
        .{ .path = "main.conf", .text = "{ x : 7, a : { include \"foo.conf\" }, a : { x : null } }" },
        .{ .path = "foo.conf", .text = "{ y : ${x} }" },
    }, "{\"x\":7,\"a\":{\"y\":null,\"x\":null}}");
}

// include-merging/011 · java ⚠️ (unsupported: an include nested in a list with
// substitutions) · pyhocon – · spec ✓ — an object in a list has no key path of its
// own: the fixed-up path runs into the list, where a lookup finds nothing, so the
// substitutions are looked up as written. A substitution to a key of the included
// file itself is therefore not found (java refuses the include altogether).
test "include.an include in a list keeps its substitutions as written" {
    try expectJson(&.{
        .{ .path = "main.conf", .text = "a = [ { include \"child.conf\" } ]\ny = 1" },
        .{ .path = "child.conf", .text = "x = ${y}" },
    }, "{\"a\":[{\"x\":1}],\"y\":1}");
}

// ---------------------------------------------------------------------------
// HTTP: includes from a server. The server is ours, on 127.0.0.1, in a thread of
// the test, so no network is needed.
// ---------------------------------------------------------------------------

const Route = struct {
    path: []const u8,
    status: std.http.Status = .ok,
    content_type: []const u8 = "text/plain",
    body: []const u8 = "",
};

const routes = [_]Route{
    .{ .path = "/base.conf", .body = "base = 1\ninclude \"sub/inner.conf\"" },
    .{ .path = "/sub/inner.conf", .body = "inner = 2\ninclude \"x.conf\"" },
    .{ .path = "/sub/x.conf", .body = "deep = 3" },
    .{ .path = "/loop.conf", .body = "include \"loop.conf\"" },
    .{ .path = "/gone.conf", .status = .gone },
    .{ .path = "/broken.conf", .status = .internal_server_error, .body = "oops" },
    // The type says one thing and the name another; the type wins.
    .{ .path = "/typed.txt", .content_type = "application/json; charset=utf-8", .body = "{\"j\": 1}" },
    .{ .path = "/typed.json", .content_type = "application/hocon", .body = "h = unquoted" },
    .{ .path = "/typed.conf", .content_type = "text/x-java-properties", .body = "p = 1" },
    // No usable type: the name decides.
    .{ .path = "/plain.json", .content_type = "text/plain", .body = "{\"k\": 1}" },
};

/// Set by the test to let a connection held by `/hang` go.
var release = std.atomic.Value(bool).init(false);

fn serve(server: *std.Io.net.Server) void {
    const io = testing.io;
    while (true) {
        const stream = server.accept(io) catch return;
        defer stream.close(io);
        var read_buffer: [4096]u8 = undefined;
        var write_buffer: [4096]u8 = undefined;
        var reader = stream.reader(io, &read_buffer);
        var writer = stream.writer(io, &write_buffer);
        var http_server = std.http.Server.init(&reader.interface, &writer.interface);
        while (true) {
            var request = http_server.receiveHead() catch break;
            // Asked by the test when it is done.
            if (std.mem.eql(u8, request.head.target, "/quit")) {
                request.respond("", .{}) catch {};
                return;
            }
            // Sends the head and one byte of a longer body, then holds the connection
            // like `/hang` below: the timeout strikes in the middle of the body.
            if (std.mem.eql(u8, request.head.target, "/trickle")) {
                var body = request.respondStreaming(&.{}, .{ .content_length = 1000 }) catch break;
                body.writer.writeAll("#") catch break;
                body.flush() catch break;
            }
            // Takes the request and never answers, until the test is over.
            if (std.mem.eql(u8, request.head.target, "/hang") or std.mem.eql(u8, request.head.target, "/trickle")) {
                while (!release.load(.acquire)) std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
                break;
            }
            const route = for (routes) |r| {
                if (std.mem.eql(u8, r.path, request.head.target)) break r;
            } else Route{ .path = "", .status = .not_found };
            request.respond(route.body, .{
                .status = route.status,
                .extra_headers = &.{.{ .name = "content-type", .value = route.content_type }},
            }) catch break;
        }
    }
}

fn stop(port: u16) void {
    var buffer: [64]u8 = undefined;
    const url = std.fmt.bufPrint(&buffer, "http://127.0.0.1:{d}/quit", .{port}) catch return;
    var client: std.http.Client = .{ .allocator = testing.allocator, .io = testing.io };
    defer client.deinit();
    _ = client.fetch(.{ .location = .{ .url = url } }) catch {};
}

fn includeUrl(arena: Allocator, port: u16, path: []const u8) ![]const u8 {
    const main = try std.fmt.allocPrint(arena, "include url(\"http://127.0.0.1:{d}{s}\")", .{ port, path });
    return parseFixtures(arena, &.{.{ .path = "main.conf", .text = main }});
}

// java – · pyhocon – · spec ✓ — a URL is fetched with a GET; the answer
// merges in place; a name inside it is a name on the same server, found the way
// RFC 3986 says (`x.conf` in `/sub/inner.conf` is `/sub/x.conf`); 404 and 410 are
// a missing include, so empty, or an error under `required`; any other status is
// a failed fetch; the type the server names beats the extension; a URL that
// includes itself is a cycle.
test "include.http" {
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(testing.io, .{});
    defer server.deinit(testing.io);
    const port = server.socket.address.getPort();
    const thread = try std.Thread.spawn(.{}, serve, .{&server});
    // Stops the server whatever happens below, and waits for it.
    defer thread.join();
    defer stop(port);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Merged in place, and the relative include went back to the server.
    try testing.expectEqualStrings("{\"base\":1,\"inner\":2,\"deep\":3}", try includeUrl(a, port, "/base.conf"));

    // a bare string with the scheme is the same include
    const bare = try std.fmt.allocPrint(a, "before = 0\ninclude \"http://127.0.0.1:{d}/sub/x.conf\"\nafter = 4", .{port});
    try testing.expectEqualStrings("{\"before\":0,\"deep\":3,\"after\":4}", try parseFixtures(a, &.{.{ .path = "main.conf", .text = bare }}));

    // Not found and gone are ignored, or an error when required
    try testing.expectEqualStrings("{}", try includeUrl(a, port, "/missing.conf"));
    try testing.expectEqualStrings("{}", try includeUrl(a, port, "/gone.conf"));
    const required = try std.fmt.allocPrint(a, "include required(url(\"http://127.0.0.1:{d}/missing.conf\"))", .{port});
    try testing.expectError(error.IncludeNotFound, parseFixtures(a, &.{.{ .path = "main.conf", .text = required }}));

    // Anything else
    try testing.expectError(error.IncludeFetchFailed, includeUrl(a, port, "/broken.conf"));

    // the type wins over the name; no usable type falls back to the name
    try testing.expectEqualStrings("{\"j\":1}", try includeUrl(a, port, "/typed.txt"));
    try testing.expectEqualStrings("{\"h\":\"unquoted\"}", try includeUrl(a, port, "/typed.json"));
    try testing.expectEqualStrings("{\"p\":\"1\"}", try includeUrl(a, port, "/typed.conf"));
    try testing.expectEqualStrings("{\"k\":1}", try includeUrl(a, port, "/plain.json"));

    // The name check stops this at the second fetch; the depth cap would stop it too, at
    // the 64th, so the result alone cannot tell them apart.
    try testing.expectError(error.IncludeCycle, includeUrl(a, port, "/loop.conf"));
}

// java – · pyhocon – · spec – — ours alone: a server that takes the request and never
// answers, and one that sends part of the body and stops, end the parse with
// `IncludeTimeout` after `http_timeout`, for a plain include as well as a required one
// (a hung server is not a missing file). The server holds
// the connection until the test releases it, then thread and socket are joined.
test "include.a server that never answers times out" {
    release.store(false, .release);
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(testing.io, .{});
    defer server.deinit(testing.io);
    const port = server.socket.address.getPort();
    const thread = try std.Thread.spawn(.{}, serve, .{&server});
    defer thread.join();
    defer stop(port);
    // Runs first of the three: the server is single-threaded and must let go of the
    // hung connection before it can hear `/quit`.
    defer release.store(true, .release);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const options: Config.ParseOptions = .{ .http_timeout = .fromMilliseconds(200) };

    // First: the server has one thread, and once it holds a connection it reads no
    // other request. The ones below then time out waiting for the head.
    const trickle = try std.fmt.allocPrint(a, "include url(\"http://127.0.0.1:{d}/trickle\")", .{port});
    try testing.expectError(error.IncludeTimeout, parseFixturesWith(a, &.{.{ .path = "main.conf", .text = trickle }}, options));

    const plain = try std.fmt.allocPrint(a, "include url(\"http://127.0.0.1:{d}/hang\")", .{port});
    try testing.expectError(error.IncludeTimeout, parseFixturesWith(a, &.{.{ .path = "main.conf", .text = plain }}, options));
    const required = try std.fmt.allocPrint(a, "include required(url(\"http://127.0.0.1:{d}/hang\"))", .{port});
    try testing.expectError(error.IncludeTimeout, parseFixturesWith(a, &.{.{ .path = "main.conf", .text = required }}, options));
}

test "include.the default timeout is 30 seconds" {
    try testing.expectEqual(std.Io.Duration.fromSeconds(30), (Config.ParseOptions{}).http_timeout);
}
