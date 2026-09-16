---
title: Patterns
description: What people actually build with includes, merging and substitutions — a layered config that does not repeat itself.
---

<div class="status">
<strong>This page teaches the format, not the library.</strong> Object merging
is built and tested here; includes and substitution <em>resolution</em> are
not, and neither is the CLI — so most of what follows is HOCON as it works,
and as this will. See {{< ref-link "coverage" "Coverage" >}} for the line.
</div>

The reason HOCON is still around is not its syntax. It is that a configuration
can be *composed* — layered out of files that each say only what they change.
Here is the shape that falls out of that, and why each piece of it is there.

## The layout

```
config/
├── common.conf              things true of every service we run
├── defaults.conf            things true of this service everywhere
├── prod/
│   └── application.conf     production, built on the two above
└── uat/
    └── application.conf     UAT, built on production
```

Two rules produce the whole structure. **An include merges a file in at the
point it is written**, and **anything after an include wins over it**. So a
file reads top to bottom as "everything from there, then these differences".

## The files

<div class="compare">
<div>
<h4>common.conf</h4>

```ini
company {
  name    = "Acme"
  support = "ops@acme.example"
}

log {
  level  = info
  format = json
}
```

</div>
<div>
<h4>defaults.conf</h4>

```ini
service {
  name     = orders-api
  port     = 8080
  workers  = 4

  # note: refers to the name above
  data-dir = "/srv/"${service.name}

  timeouts { connect = 500, read = 2000 }
  pools    = [primary]
}
```

</div>
</div>

<div class="compare">
<div>
<h4>prod/application.conf</h4>

```ini
include "../common.conf"
include "../defaults.conf"

service {
  workers      = 16
  pools        = ${service.pools} [replica]
  timeouts.read = 5000
}

log.level = warn
port      = ${?PORT}
```

</div>
<div>
<h4>uat/application.conf</h4>

```ini
include "../prod/application.conf"

service {
  name    = orders-api-uat
  workers = 2
}

log.level = debug
```

</div>
</div>

Note how short the UAT file is. That is the point: **the file is the diff.** A
reviewer does not have to compare two hundred lines to see what differs between
environments — the differences are the whole file.

## What that resolves to

```sh
$ zig-hocon render config/uat/application.conf
```

```json
{
  "company": { "name": "Acme", "support": "ops@acme.example" },
  "log":     { "level": "debug", "format": "json" },
  "service": {
    "name": "orders-api-uat",
    "port": 8080,
    "workers": 2,
    "data-dir": "/srv/orders-api-uat",
    "timeouts": { "connect": 500, "read": 5000 },
    "pools": ["primary", "replica"]
  }
}
```

Four things happened there that are worth looking at one at a time.

### Objects merge, they do not replace

`prod` writes `service { workers = 16 }` and does not mention `port`, `name` or
`data-dir` — they survive from `defaults.conf`. Merging goes all the way down,
so `timeouts.read = 5000` replaces one field and leaves `connect` alone.

The rule underneath: when a key exists on both sides and **both hold an
object**, they merge; otherwise the later one wins outright. That is why
`pools` would be replaced rather than appended if you just wrote it again —
lists are not objects.

### A substitution is resolved against the finished document

`data-dir` was written in `defaults.conf` as `"/srv/"${service.name}` — long
before anyone knew this was UAT. The UAT file overrides `service.name`, and
`data-dir` follows it to `/srv/orders-api-uat`.

This is the single most useful thing in the format and the one most often
misunderstood. `${…}` is not "the value as it is here". It is "the value once
the whole document, every include and every later override, has been read".
Write the relationship once and every layer keeps it.

It is also the footgun: overriding a value silently moves everything derived
from it. That is usually what you want and occasionally a surprise, so it is
worth knowing which of your keys are derived.

### A list can extend itself

```ini
pools = ${service.pools} [replica]
```

`${service.pools}` here means *the value this key had before this assignment* —
so the line appends rather than replaces, and `defaults.conf` keeps ownership
of the base list. Layer it again in another file and you get another element,
not a reset.

The spec has sugar for exactly this, `pools += replica`, defined as `pools =
${?pools} [replica]` — the optional form, so it also works when nothing set it
first.

### The environment gets the last word, but only if it has one

```ini
port = 8080
port = ${?PORT}
```

The `?` makes the substitution optional, and an unresolved optional **removes
the assignment rather than producing an empty value**. So with `PORT` unset the
second line evaporates and `port` stays `8080`; with `PORT=9090` it wins.

Two lines, no defaulting logic, no `getenv` sprinkled through the program. The
config file says what the precedence is, which is where that decision belongs.

## Where it goes wrong

**Include order is precedence.** `include` at the top means "start from this";
at the bottom it means "and let this override everything I just said". Both are
legitimate and they are opposites. Put includes at the top unless you mean the
other thing, and when you mean the other thing, write a comment.

**A missing include is an error unless you say otherwise.** `include
"optional.conf"` on a file that does not exist is silently skipped; if the file
is required for the config to make sense, say `include required("x.conf")` and
fail loudly instead of debugging a mysterious default three environments later.

**Diamonds are fine, cycles are not.** Two files including the same third one
is harmless — it merges twice with the same content. A substitution that refers
to itself through another key is an error the loader reports as a cycle.

**Deep override paths are easy to mistype.** `service.timeouts.raed = 5000`
adds a key rather than changing one, because nothing declares the shape. This
is the real argument for {{< ref-link "getting-started" "parsing into a typed struct" >}} —
an unknown key becomes an error at load instead of a value nobody reads.

## Seeing what you actually got

A layered config is only comfortable when you can ask what it came out as.
That is what the CLI is for:

```sh
# the whole thing, resolved
zig-hocon render config/uat/application.conf

# one path, for a script or a health check
zig-hocon get service.data-dir config/uat/application.conf
# /srv/orders-api-uat

# what changed between two environments
zig-hocon diff config/prod/application.conf config/uat/application.conf
```

`render` is the one that earns its place. Reviewing a layered config by reading
the layers is how mistakes survive review; reading the resolved output is how
they do not.
