# zig-hocon in Zig

The library's reference: the parse options, errors, durations, periods and sizes, a config without a struct, and writing HOCON. The examples read `app.conf` and `prod.conf`, the two files at the top of the [README](../README.md).

What the options do, each set to something other than its default:

```zig
.{
    .env = .{ .map = init.environ_map }, // where ${DB_POOL} looks; default .none, no variables; or .keep
    .resolve = false,                    // default true; false keeps every ${…} as written, for hocon.Value
    .ignore_unknown_fields = false,      // default true, a key the struct has no field for is skipped; false makes it an error
    .diagnostics = &diag,                // default null; where an error is, see below
    .http_timeout = .fromSeconds(5),     // default 30 s; for an include of an http(s) URL
}
```

**Errors** are plain Zig errors. To know where, pass `Diagnostics`:

```zig
var diag: hocon.Diagnostics = .{};
defer diag.deinit(init.gpa);
const parsed = hocon.parseFromFile(Config, init.gpa, init.io, "prod.conf", .{
    .env = .{ .map = init.environ_map },
    .diagnostics = &diag,
}) catch |err| {
    var buffer: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(init.io, &buffer);
    try diag.render(&stderr.interface); // any *std.Io.Writer
    try stderr.interface.flush();
    return err;
};
```

With `DB_POOL=eight` in the environment it prints what the zig compiler would, pointing at where the value comes from:

```
prod.conf:4:11: error: InvalidCharacter at db.pool: expected u16
db.pool = ${?DB_POOL}   # only when DB_POOL is set
          ^
```

`diag.location` has the same `path`, `line`, `column` and the line itself, `diag.key_path` and `diag.expected` the rest, for a message of your own.

**Durations, periods and sizes** are read in any unit the spec lists, a bare number in the default one:

```zig
config.timeout.whole(.ms)      // 30000; .as(.minutes) gives an f64, .toIo() a std.Io.Duration
config.cache.whole(.B)         // 536870912; "512MB" counts by 1000, "512MiB" by 1024
period.months                  // hocon.Period: years, months, days, as java.time.Period
```

The units are `.ns`, `.us`, `.ms`, `.s`, `.min`, `.h`, `.d` and `.w` for a duration, `.B`, `.kB`, `.MB`, `.GB`, `.TB`, `.PB`, `.EB` and `.KiB` … `.EiB` for a size. A `Duration` holds its nanoseconds exactly, in an i96 (`.nanoseconds`); `whole` gives an i64, so past 292 years `whole(.ns)` is the largest i64 rather than the value.

**Without a struct**, when the keys are not known ahead of time, ask for `hocon.Value`: the whole tree of objects, lists and values, to walk with a `switch`. `std.json.Stringify` prints it as JSON:

```zig
const parsed = try hocon.parseFromFile(hocon.Value, gpa, io, "prod.conf", .{});
try std.json.Stringify.value(parsed.value, .{}, writer);
```

**Writing HOCON**: `hocon.stringify(value, .{}, writer)` writes a struct or a `hocon.Value`, so a program can write its defaults once and let each environment include them; `stringifyAlloc` returns the text.
