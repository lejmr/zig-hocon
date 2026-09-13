---
title: zig-hocon
---

# A HOCON parser for Zig

<p class="lede">HOCON is the configuration format the JVM world already runs on —
Akka, Play, Kafka, Spark. This reads it, from Zig, with no JVM under it.</p>

<div class="status">
<strong>Status: early development.</strong> The tokenizer, the parser and the
value graph are built and tested; there is no public API yet, so the interface
below is the target rather than a description. <a href="/coverage/">Coverage</a>
tracks the spec section by section, honestly.
</div>

## The point of it

A config format is only worth parsing if the files already exist. HOCON's do —
in their thousands, in repositories nobody is going to rewrite. So the goal is
not a nicer format to write. It is reading the one that is already there, from
a language with no runtime to drag along.

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
  read    = ${timeouts.connect}
}
```

</div>
<div>
<h4>The struct it lands in</h4>

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
```

</div>
</div>

Field names are the keys, field types do the converting, field defaults are the
config's defaults, and a missing required field is an error at load rather than
a surprise at three in the morning. The schema is the code that reads the
config, so the two cannot drift apart.

## What HOCON asks of a parser

More than it looks. Every line here means something different, and each costs a
rule:

```ini
a = [1] [2]            // one list, [1,2] — lists next to each other join
a = {x=1} {y=2}        // one object, merged by key
a = grumpy "wombat"    // one string, and the gap is a character
a = [1]   [2]          // the same gap here is a separator, not a character
a = 1 [2]              // an error: a list and a non-list cannot be joined
a."b.c" = 1            // one key containing a dot, not two keys
a.b.c = 1              // three keys, nested
a = ${x} [2]           // unknown until x resolves, so the check waits
```

That last one is why a value either finishes loading or stays explicitly
pending: a substitution's type is not known until the document is, so the check
that rejects `1 [2]` cannot run across one.

## How disputes get settled

The spec is prose, and the implementations disagree with it and with each
other. So the repository carries both of them behind one interface:

```sh
printf 'a = [1] ${x} [2]\n' | tools/oracle/hocon-java   # the authority
printf 'a = [1] ${x} [2]\n' | tools/oracle/hocon-py     # pyhocon, for comparison
```

Every behavioural test records which of the three agreed, and names the
divergence where they did not. [More on the oracles](/oracles/).
