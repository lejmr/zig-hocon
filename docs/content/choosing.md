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

This is where HOCON earns its keep, and it is worth being plain that this is
also where the alternatives stop being level.

Everything else on this page makes you build layering yourself. In TOML you
merge dictionaries in application code. In YAML you reach for anchors and
aliases, which do not cross file boundaries, cannot be partially overridden,
and whose merge key `<<` was never part of the standard. Both of those are
someone's Tuesday afternoon spent reimplementing what HOCON does as a language
feature: a file says only what it changes, objects merge key by key, and a
substitution resolves against the *finished* document, so a value derived in a
shared file follows an override made three layers later. That is
{{< ref-link "patterns" "Patterns" >}}, and it is the whole reason the format
outlived the decade it was designed in.

## 4. So when is it not HOCON?

Two cases, and neither is common. If you are in either, it is worth knowing;
if you are not, the answer is HOCON and this section is trivia.

### It is infrastructure, not application config

If what you are describing is Kubernetes manifests, Terraform, CI pipelines —
anything whose consumer is a tool that eats YAML — then look at
**[Pkl](https://pkl-lang.org)**.

The difference is not taste. In that pipeline there is no type system anywhere
between what you write and what runs, so a typo in `replcias` reaches the
cluster. Pkl supplies the type system that is missing: manifests are typed
against generated classes from the Kubernetes OpenAPI schema, and it can reach
into a list to override one element by predicate —

```
containers {
  [[name == "follower"]] { env { [[name == "GET_HOSTS_FROM"]] { value = "env" } } }
}
```

— which HOCON genuinely cannot do. Lists there can be replaced or extended,
never edited in the middle, and infrastructure config is lists all the way
down.

### The same config is read by programs in several languages

If a platform team owns the shape and four languages consume it, one schema
generating typed bindings for each is exactly the problem Pkl was built for. It
came out of Apple, and that list of target languages is not a coincidence.

### And when it is application config in one language — it is not Pkl

Which is the ordinary case, and where the argument is the other way round.

Pkl's pitch for an application is a type system and constraints. You already
have a type system: the one in the language reading the config. So what Pkl
adds is mostly a re-derivation of what your own struct already says, and it
costs a language in the build, a code generation step, and generated files in
the repository that nobody edits and everybody has to regenerate.

| | what has to exist and stay in agreement |
|---|---|
| Pkl | the `.pkl` schema → the generated types → your code |
| HOCON + a struct | your code |

Removing an artefact beats shortening a syntax, and this removes two. The
struct that reads the configuration *is* the schema — see
{{< ref-link "getting-started" "Getting started" >}}.

Two honest points against that, so the trade is visible. Pkl's constraints live
in the file and are checked by its LSP as you type; a `validate()` method is
checked when the build runs, so someone editing config without compiling gets
no feedback until CI. And Pkl's constraints are declarative, which is a real
advantage — though narrower than it looks, since they cannot reference other
properties: "read timeout must exceed connect timeout" is not expressible as a
Pkl constraint and is one line of ordinary code next to the struct.

## The short version

| you have | use |
|---|---|
| config already in HOCON | HOCON |
| one flat file | HOCON, TOML or YAML — level |
| layers, environments, shared defaults | HOCON |
| Kubernetes, Terraform, anything rendering YAML | [Pkl](https://pkl-lang.org) |
| one schema, many languages, many teams | [Pkl](https://pkl-lang.org) |
| data to serialise, with a schema, in Zig | [Ziggy](https://ziggy-lang.io) |
