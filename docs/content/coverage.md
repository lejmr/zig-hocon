---
title: Coverage
description: What of the HOCON spec is implemented, section by section, with the divergences named.
---

Tracking [the HOCON spec](https://github.com/lightbend/config/blob/main/HOCON.md)
by its own section names, so the two can be read side by side. Done means
implemented *and* tested against the oracles.

## Syntax

| Section | State |
|---|---|
| Unchanged from JSON | done |
| Comments | done — `#` and `//` |
| Omit root braces | done |
| Key-value separator | done — `=`, `:`, and omitted before `{` |
| Commas | done — interchangeable with newlines, runs collapse, trailing allowed |
| Whitespace | done — verbatim inside a value, trimmed at its ends |
| Unquoted strings | done, including the reserved characters that end one |
| Multi-line strings | done — `"""` stays in the tree, because escapes are literal inside it |
| Path expressions | done — split on dots outside quotes; `BadPath` naming still to do |
| Paths as keys | done — `a.b.c = 1` nests; a multi-part key does too |
| Duplicate keys and object merging | done — merges by key, descends only when both sides are objects |
| Value concatenation | done — lists, objects and text, with the whitespace rules |
| Substitutions | parsed, not resolved |
| Includes | not started |
| Numerically-indexed objects to arrays | not started |
| `+=` field separator | not started |

## API recommendations

The spec marks these advisory, but they are what makes the format pleasant.

| Section | State |
|---|---|
| Automatic type conversions | not started |
| Duration format | not started |
| Period format | not started |
| Size in bytes format | not started |
| Config merging and file merging | not started |
| Substitution fallback to environment variables | not started |

Deliberately out of scope: Java properties mapping, JVM config file name
conventions, and override by system properties. Those describe the JVM, not the
format.

## Where this differs, and on purpose or not

Three different things get called a divergence and they deserve separating.

**The spec is the authority. Lightbend's `typesafe/config` is how the spec gets
read**, because it is the implementation the spec was written against and the
one every `.conf` file in the world was written for. On every disagreement
found so far the two agree with each other and pyhocon is simply wrong — so
"follow the spec" and "follow java" have not yet pulled in opposite directions,
and claiming to hold one against the other would be a distinction without a
difference.

### Bugs — differs, and should not

| input | java | here |
|---|---|---|
| an unquoted string starting `_ ' ~ % ( <` | accepted | tokenizer will not start one |
| `a = b\\"c"` — escaped backslash before a closing quote | accepted | mis-lexed |
| `a = +1` | accepted | rejected |
| `a "b c" d = f` | one key, `a b c d` | parts kept side by side, not joined |

### Deliberate leniency — differs, and stays that way

Java is stricter than the spec strictly needs to be in a couple of places, and
accepting more is the safer side to err on when the job is reading files that
already exist. A config that parses today should keep parsing.

| input | java | here | why |
|---|---|---|---|
| `,a = b` | error | accepted | a stray leading comma cannot change a value, only be noise |
| `a = b,,c = d` | error | accepted | same — a doubled separator separates nothing extra |

The rule that keeps this honest: **leniency may only accept more inputs, never
produce a different value.** Where java and pyhocon give the same input
different *output* — `a = b\tc`, where pyhocon expands the tab and java keeps
it — java wins, every time.

### Cosmetic — same verdict, different label

`.a = 1`, `a. = 1` and `a..b = 1` are rejected here as the parser's
`UnexpectedToken` where java names them `BadPath`. Same inputs refused, less
helpful message. Worth fixing, changes nothing about what is accepted.

The full table, with a note on each row about what the spec says and which
implementation it backs, is in
[`tools/oracle/README.md`](https://github.com/lejmr/zig-hocon/blob/main/tools/oracle/README.md).

## Not yet decided

Substitution resolution is the next large piece, and it brings questions the
spec answers only partly — a self-reference (`a = ${a} [1]`) reading the
previous value of its own key, a cycle coming back as `UnresolvedSubstitution`,
and an unresolved optional (`${?x}`) removing the member it belongs to rather
than leaving an empty one.
