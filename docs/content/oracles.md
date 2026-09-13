---
title: Oracles
description: Why the repository carries two other HOCON implementations, and how they are used.
---

The HOCON spec is prose. It is a good document, but it does not answer
questions like *what is `a = [1] " " [2]`* — and the answer turns out to be an
error, while `a = [1]   [2]` is `[1,2]`. Reading the spec harder does not
produce that. Running an implementation does.

So the repository carries two, behind one interface:

```sh
printf 'a = [1] " " [2]\n' | tools/oracle/hocon-java
# ERROR WrongType: ... SimpleConfigList([1]) and Quoted(" ") are not compatible

printf 'a = [1]   [2]\n' | tools/oracle/hocon-java
# {"a":[1,2]}
```

`hocon-java` is Lightbend's `typesafe/config`, the implementation the spec was
written against, and it is the authority here. `hocon-py` is pyhocon — not an
authority, but a measure of how far the implementation this project is meant to
replace has drifted.

Neither is committed: both scripts bootstrap on first run, one fetching
`config.jar` from Maven Central, the other building a venv.

## The format

One document per line of stdin, with `\n`, `\t` and `\"` as escapes. One line
of compact JSON out, or `ERROR <Class>: <message>`.

Substitutions come back **unresolved** unless the line begins with `resolve:` —
which is usually what you want, because the unresolved form shows how the
parser understood the document:

```sh
printf 'a = ${x} "c"\n' | tools/oracle/hocon-java
# {"a":${x}" c"}
```

That output says the gap was absorbed into the string on its right, and that
the two parts stayed two parts. No amount of prose says it as precisely.

## What it changed about the work

Every behavioural test in the repository carries a line like

```
// java ✓ · pyhocon ⚠️ · spec ✓
```

naming which of the three agree, and spelling out the divergence where they do
not. It costs a minute per test group and it means an argument about intended
behaviour cannot happen twice.

It also settles questions in the direction of *reality* rather than
*intention*. A quoted space between two lists is an error; three unquoted
spaces are not. Two lists written next to each other join, but the same two
arriving under one key do not. None of those are guessable, all of them are one
command away.
