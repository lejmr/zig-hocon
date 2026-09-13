---
title: Choosing a format
description: Where HOCON belongs next to JSON, TOML, YAML, Ziggy and Pkl — and when to use one of those instead.
---

Format comparisons usually read as a competition. This one is meant to read as
advice, so it is organised by the question you are actually asking rather than
by a table of features.

## 1. Is the config already in HOCON?

Then use HOCON, and the rest of this page is irrelevant. Migration cost beats
every other consideration, and rewriting a configuration that works is the most
expensive way there is to obtain a nicer format. Akka, Play, Kafka, Spark and
most of the Lightbend-flavoured JVM world put you here.

## 2. One file, a flat set of settings?

Then **HOCON, TOML and YAML are level**, and picking between them is taste and
ecosystem. Anyone claiming otherwise is selling something.

What HOCON brings to the simple case is nothing you have to learn:

```ini
# every JSON document is already a valid HOCON document
{ "port": 8080, "host": "0.0.0.0" }

# so you start there and delete punctuation until you like it
port = 8080
host = "0.0.0.0"    # comments, and quotes only when you want them
```

A few things it does not do, which matter more in anger than on a comparison
page: no significant whitespace, so indentation cannot change meaning; no
implicit type coercion of bare words, so `no` is the string `no` and not a
boolean; and one obvious way to nest, rather than block style and flow style
and a choice between them on every line.

Against **TOML** it is close. TOML's tables are arguably nicer for flat
sections; HOCON's braces are nicer once things nest three deep. Against
**Ziggy** the trade is the other way round — Ziggy has a schema language and
better editor tooling, HOCON has an installed base and composition.

The reason to lean HOCON anyway is the next section: it is the only one of the
three you do not have to leave when the config stops being one file.

## 3. Layers — environments, shared defaults, overrides?

This is the real decision, and it is **HOCON or Pkl**.

Everything else on this page makes you build layering yourself. In TOML you
merge dictionaries in application code. In YAML you reach for anchors and
aliases, which do not cross file boundaries, cannot be partially overridden,
and whose merge key `<<` was never part of the standard. Both of those are
someone's Tuesday afternoon reimplementing what these two formats do properly.

**HOCON** does it with includes, merging and substitutions. A file says only
what it changes, a substitution resolves against the *finished* document, and
nothing needs a toolchain — see {{< ref-link "patterns" "Patterns" >}}.

**Pkl** does it with `amends`, and gives you two things HOCON has no answer to:
type constraints in the file itself —

```
serverPort: Int(isBetween(0, 1023))
```

— and generated typed bindings for Java, Kotlin, Swift and Go.

Choose **HOCON** when the files exist already, when you do not want a language
in your build, or when the people editing the config should not have to learn
one. Choose **Pkl** when you are starting from nothing and the extra strictness
is worth the adoption.

One honest note on the constraints, because the gap is narrower than it looks
from the outside: Pkl's are declarative and travel with the file, which is a
real advantage — but they cannot reference other properties. "Read timeout must
exceed connect timeout" is not expressible as a Pkl constraint, while it is one
line of ordinary code in a `validate()` method next to the struct the config
parses into. Different shape, not strictly more.

## 4. A contract across teams and languages?

Then **Pkl**, and it is not close.

If a platform team owns what a service's configuration looks like, and the
services reading it are written in four languages, then generating typed
bindings from one schema is exactly the problem Pkl was built for — it came out
of Apple, and that list of target languages is not a coincidence.

That is a different problem from the one this library solves. Bindings here
exist so that several languages can call *one parser*, because the files are
already HOCON and nobody wants to write the parser five times. Pkl's codegen
exists so that several languages can share *one schema*. The first is interop
with what exists; the second is a contract about what will.

If you have the second problem, use Pkl. This library will not give you that,
and pretending otherwise would waste your time.

## The short version

| you have | use |
|---|---|
| config already in HOCON | HOCON |
| one flat file | HOCON, TOML or YAML — level |
| layers and environments | HOCON, or Pkl if greenfield |
| one schema, many languages, many teams | Pkl |
| data to serialise, with a schema, in Zig | [Ziggy](https://ziggy-lang.io) |
