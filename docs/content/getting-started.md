---
title: Getting started
description: What works today, how to run it, and what the interface is going to look like.
---

<div class="status">
<strong>There is no published package yet</strong>, and no public API. What
follows is half description and half plan, and each section says which it is.
</div>

## Running it today — this works

Zig 0.16.0 or newer.

```sh
git clone https://github.com/lejmr/zig-hocon
cd zig-hocon
zig build test
```

Eighty tests, covering the tokenizer, the parser and the value graph. Most of
them carry a note saying which reference implementations agree with them.

The oracles bootstrap themselves on first use — `hocon-java` fetches
`config.jar` from Maven Central, `hocon-py` makes a venv and installs pyhocon:

```sh
printf 'a = grumpy wombat\n' | tools/oracle/hocon-java
# {"a":"grumpy wombat"}
```

One document per input line, with `\n` written as an escape. A line prefixed
`resolve:` is resolved before printing; without it substitutions come back
unresolved, which is often the more informative answer.

## The interface — this is the plan

Two of them, for two audiences.

### Typed, for Zig

The one worth using. Declare the shape as a struct and let `comptime`
reflection do the mapping:

```zig
const hocon = @import("hocon");

const Config = struct {
    port: u16 = 8080,
    host: []const u8 = "localhost",
};

var cfg = try hocon.parseInto(Config, gpa, source);
defer cfg.deinit();

std.debug.print("{s}:{d}\n", .{ cfg.value.host, cfg.value.port });
```

Field names are the keys and field types do the converting, so `cfg.value.port`
is a `u16` rather than a lookup that might be null. Going the other way prints
the defaults as a config file, which is a thing operators want and few config
libraries do.

### Dynamic, for everyone else

`comptime` reflection has no ABI, so the C shim and the bindings built on it
get a different shape: open a document, ask for a path, free it. That API has
to be good on its own, because five languages will be using it.

## Validating a config against a struct

The struct is already the schema, so "does this file fit" is a question
something can answer. There are two honest ways to ask it, and which one you
want depends on where the struct lives.

### In your own test suite — the one that scales

If the struct is part of a program, validating against it belongs in that
program's build, where the module graph is already correct:

```zig
test "every environment still fits the struct" {
    inline for (.{ "prod", "uat", "dev" }) |env| {
        const src = @embedFile("../config/" ++ env ++ "/application.conf");
        var cfg = try hocon.parseInto(Config, testing.allocator, src);
        defer cfg.deinit();
    }
}
```

That is a real test in CI: rename a field and the configs that still use the
old name fail the build, in the same run that compiles the code reading them.
No new tool, no schema to keep in sync.

And note which configs it checked. **Every environment, in one run, on a
laptop.** The usual way to find out that the UAT config no longer fits the
program is to deploy to UAT; here prod, uat and dev are all checked before
anything ships, because loading a config needs no environment to load it in.

It catches the failure that HOCON cannot catch on its own, too. A deep override
path is just a key:

```ini
service.timeouts.raed = 5000    # adds a key nobody reads
service.timeouts.read = 5000    # changes the one that matters
```

Nothing in the format can tell those apart — there is no declared shape for it
to check against. A struct is exactly that declaration, so the first line stops
being a silent no-op and starts being a build failure.

Where it stops: a type is not a constraint. `port: u16` refuses `70000` and
accepts `0`, and "a timeout must be under thirty seconds" is not something a
type says. That is a `validate()` method on the struct, run after loading — and
it is worth writing, because by then everything else has already been checked.

### From the command line — the convenient one

For a config struct that stands on its own, the CLI can do it:

```sh
zig-hocon validate --schema src/config.zig:Config config/prod/application.conf
```

The magic is less magical than it looks: there is no runtime reflection over
arbitrary source, so the command writes a small program that imports your file,
calls `parseInto` with your type, compiles it with `zig` and runs it. Errors
come back from the Zig compiler and the loader.

Which also says where it stops. It needs the type to be `pub`, and it needs the
file to compile on its own — the moment the struct pulls in the rest of your
module graph, the generated shim does not know how to build it and the test
above is the answer instead. A convenience for a standalone `config.zig`, not a
replacement for having one's own build.

## What it cannot do yet

Substitutions parse but do not resolve, so `${a.b}` is a reference in the tree
rather than a value. Includes are not implemented. Types are not inferred, so
`1` and `"1"` are both text carrying a flag that says which way they were
written — that flag is what type conversion will read.

{{< ref-link "coverage" "Coverage" >}} has the section-by-section list.
