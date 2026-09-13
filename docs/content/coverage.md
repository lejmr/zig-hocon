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

## Known divergences

Where this parser and the Lightbend implementation differ, and it is on purpose
or not yet fixed:

- A malformed path (`.a`, `a.`, `a..b`) is rejected as the parser's
  `UnexpectedToken` rather than the `BadPath` java names. Same verdict,
  different label.
- The tokenizer cannot yet start an unquoted string on `_ ' ~ % ( <`.
- An escaped backslash immediately before a closing quote (`\\"`) is not
  handled, nor is a leading `+` on a number.

## Not yet decided

Substitution resolution is the next large piece, and it brings questions the
spec answers only partly — a self-reference (`a = ${a} [1]`) reading the
previous value of its own key, a cycle coming back as `UnresolvedSubstitution`,
and an unresolved optional (`${?x}`) removing the member it belongs to rather
than leaving an empty one.
