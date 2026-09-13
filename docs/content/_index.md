---
title: zig-hocon
---

# Read the config the JVM world already runs on — from Zig

<p class="lede">HOCON is what Akka, Play, Kafka and Spark are configured with.
Those files exist, in their thousands, and nobody is rewriting them. This reads
them, with no JVM underneath.</p>

<div class="status">
<strong>Status: early development.</strong> Tokenizer, parser and value graph
are built and tested — eighty tests, each recording which reference
implementations agree. There is no public API yet and no CLI, so the Zig and
shell snippets below are the target rather than a description.
{{< ref-link "coverage" "Coverage" >}} tracks the spec section by section,
honestly.
</div>

```ini
# A comment. Quotes are optional, so are commas, so is the = before a brace.
app {
  name    = orders-api
  version = "2.4.1"

  # Substitution: written once, used anywhere.
  data-dir = /srv/${app.name}

  # ...including from the environment, and only if it is set.
  # Without PORT, port keeps the 8080 above it.
  port = 8080
  port = ${?PORT}

  # Adjacent lists join, so this is [primary, replica, analytics].
  pools    = [primary, replica]
  pools    = ${app.pools} [analytics]

  timeouts { connect = 500, read = 2000 }
}
```

## Notation designed to leave the file readable

HOCON started as "JSON a human can edit" and every one of its quality-of-life
features earns its place in a real config file.

<div class="compare">
<div>
<h4>application.json</h4>

```json
{
  "server": {
    "host": "0.0.0.0",
    "port": 8080,
    "tls": { "enabled": true }
  },
  "log": { "level": "info" }
}
```

</div>
<div>
<h4>application.conf</h4>

```ini
# the same thing, and you can say why
server {
  host = "0.0.0.0"
  port = 8080
  tls.enabled = true     # dotted keys nest
}

log.level = info         # unquoted strings
```

</div>
</div>

Every JSON document is already a valid HOCON document, so there is nothing to
convert — rename the file and start deleting punctuation.

Comments (`#` and `//`), trailing commas, commas that can be newlines instead,
optional quotes, optional root braces, dotted keys, triple-quoted strings that
keep their backslashes, and `=` or `:` as you prefer.

## Configuration is composed, not copied

This is the part JSON, TOML and Ziggy have no answer to, and it is why HOCON
survives in places where the config is genuinely complicated.

```ini
include "common.conf"        # pull another file in, right here
base    = /srv/app           # then say what is different
logs    = ${base}/logs       # refer to what you already wrote
retries = 3
retries = ${?RETRIES}        # let the environment win, if it has an opinion
```

Files layer, objects merge key by key, lists concatenate, and a substitution is
resolved against the *finished* document — so `${app.name}` works whether the
name was set above it, below it, in an included file, or by an environment
variable. {{< ref-link "patterns" "Patterns" >}} walks through what people
actually build with that.

## Typed, from the Zig side

A schema does not need to be a separate file when the host language has one.
Declare the shape as a struct and `comptime` reflection does the rest:

<div class="compare">
<div>
<h4>application.conf</h4>

```ini
server {
  host = "0.0.0.0"
  port = 8080
  port = ${?PORT}
}

timeouts {
  connect = 500
  read    = 2000
}
```

</div>
<div>
<h4>main.zig</h4>

```zig
const Config = struct {
    server: struct {
        host: []const u8 = "localhost",
        port: u16 = 8080,
    } = .{},
    timeouts: struct {
        connect: u32 = 500,
        read: u32 = 500,
    } = .{},
};

var cfg = try hocon.parseInto(Config, gpa, src);
defer cfg.deinit();

cfg.value.server.port // a u16, not a lookup
```

</div>
</div>

Field names are the keys, field types do the converting, field defaults are the
config's defaults, and a missing required field fails at load rather than at
three in the morning. The schema is the code that reads the config, so the two
cannot drift apart — and printing the struct back out gives you the default
config file for free.

## Eight lines that each cost a rule

HOCON asks more of a parser than it looks. These all mean something different:

```ini
a = [1] [2]            // one list, [1,2] — adjacent lists join
a = {x=1} {y=2}        // one object, merged by key
a = grumpy "wombat"    // one string, and the gap is a character in it
a = [1]   [2]          // the same gap here is a separator, not a character
a = [1] " " [2]        // ...but a *quoted* space is a value, so this is an error
a."b.c" = 1            // one key containing a dot
a.b.c = 1              // three keys, nested
a = ${x} [2]           // unknown until x resolves, so the check waits
```

The last one is why a value either finishes loading or stays explicitly
pending: a substitution's type is not known until the document is, so the check
that rejects `a = 1 [2]` cannot run across one.

## A CLI, because layered config needs looking at

The moment a configuration is composed out of four files, the first question
anyone asks is *what did it actually come out as*. Reviewing the layers is how
mistakes survive review; reading the resolved document is how they do not.

```sh
# every include followed, every substitution resolved, printed as JSON
$ zig-hocon render config/uat/application.conf
{
  "service": {
    "name": "orders-api-uat",
    "data-dir": "/srv/orders-api-uat",
    "workers": 2,
    ...
```

```sh
# one path, for a script or a health check
$ zig-hocon get service.data-dir config/uat/application.conf
/srv/orders-api-uat

# what two environments actually differ by
$ zig-hocon diff config/prod/application.conf config/uat/application.conf

# parse and resolve, say nothing, set an exit code — for CI
$ zig-hocon check config/prod/application.conf
```

No JVM to start, so it is fast enough to put in a pre-commit hook.
{{< ref-link "patterns" "Patterns" >}} builds the config those commands are
reading.

## Settled by running it, not by reading it

The spec is prose, and no amount of reading it tells you that `[1] " " [2]` is
an error while `[1]   [2]` is `[1,2]`. So the repository carries both reference
implementations behind one interface:

```sh
printf 'a = [1] " " [2]\n' | tools/oracle/hocon-java
# ERROR WrongType: SimpleConfigList([1]) and Quoted(" ") are not compatible

printf 'a = [1]   [2]\n' | tools/oracle/hocon-java
# {"a":[1,2]}
```

Every behavioural test says which of the three agreed and names the divergence
where they did not. {{< ref-link "oracles" "More on that" >}}.
