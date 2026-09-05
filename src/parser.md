# Parser map

Orientation for picking the work back up after a break. Doc comments in
`Ast.zig` explain how each function works; this page is the part that lives
between them — who calls whom, who knows what, and which rules were settled by
running the oracle rather than by reading the spec.

## Phases

| phase | input → output | job |
|---|---|---|
| `Tokenizer.zig` | bytes → tokens | lexical: what is a word, a quote, a separator |
| `Ast.zig` | tokens → tree | syntactic: what is a member, a value, a substitution |
| `Value.zig` | tree → values | semantic, as far as it goes without the whole document: concatenation, merging, path splitting |
| *(not built)* includes | tree → tree | splice included files in |
| *(not built)* evaluation | values → values | resolve substitutions, convert types |

The line between parser and evaluation: **an error belongs to the parser only if
it can be seen without looking elsewhere in the tree.** `a = b = c` is a parse
error; `a = ${nope}` is not, it needs the rest of the document.

The litmus test for everything the parser stores: **two sources that mean
different things must not produce the same tree.** Undecided is fine, lost is
not. This is why quotes stay in `.value` (`"1"` must stay distinguishable from
`1`), why the whitespace between parts becomes a part of its own, why `.concat`
exists instead of joining the text right away, and why a substitution is a node
rather than the text it was written as.

## Call graph

```
parse()
└── parseContainer(ending, containerType)   KNOWS where it is: root / block / array
    │                                       loops over MEMBERS (or, in an array, values)
    ├── newline | comma        → skip           (separators are handled here, only here)
    ├── string | quoted_string → in an array:  parseValue()
    │                            `include`:    parseInclude()
    │                            otherwise:    parseMember()
    ├── l_brace                → parseContainer(.block)    root or array only
    ├── l_bracket              → parseContainer(.array)    root or array only
    └── ${ | ${?              → parseValue()              ARRAY ONLY — a substitution
                                                           is a value, and where a member
                                                           begins there is no key for it

parseMember()    key, separator, value. Requires the separator, so nothing but an
│                `.assignment` can come back — and nothing needs checking after.
├── parseText()  the key: text only, no blocks, no arrays, no substitutions
└── parseValue()

parseValue()     does NOT know where it is. Loops over the PARTS of one value.
├── parseText()       text parts
├── parseContainer()  a block or an array part
└── parseValue()      the path inside `${…}`, then `}` is required
```

That dispatch is the whole design. Anything that depends on *position* must be
decided in `parseContainer`, before it delegates — `include`, whether a key is
expected, whether a brace or a `${` is legal. A `bool` parameter threaded down
into `parseValue`/`parseText` means the decision is at the wrong level.

The general form: **decide before delegating when position and one token are
enough; check afterwards only when they are not.** `{ {a=1} }` is caught by the
first (a `{` where a member begins), `a = b\nc` by the second (`c` looks like a
key until the input runs out). The inside of `${…}` is the one place that
delegates wide and narrows after: `parseValue` parses it and `isPathText`
rejects whatever a path may not contain.

Newlines are skipped in exactly three places, all of them places where the
parser has already committed and is waiting for something: before the separator
in `parseMember`, after it, and after the `include` keyword. Everywhere else a
newline ends what is being parsed.

## The gap between two parts

`a = ${b} ${c}` and `a = ${b}${c}` resolve to different strings — `"1 2"` and
`"12"` — so the whitespace between two parts carries meaning and the tree keeps
it, as a `value` part of its own holding exactly those bytes. One rule, applied
between *any* two parts, not only between text ones:

```
a = x "y"        concat(value(x), value( ), value("y"))
a = ${b} ${c}    concat(subst(value(b)), value( ), subst(value(c)))
a = {x:5} {y:6}  concat(block(…), value( ), block(…))
a = x${b}        concat(value(x), subst(value(b)))          no gap, none emitted
```

Whether it *matters* is not the parser's call, because it depends on what the
parts turn out to be — and with a substitution that is unknown until the
document is resolved:

```
resolve:b={x:1}\na = ${b} {y:2}     {"x":1,"y":2}    merge, whitespace irrelevant
resolve:b=str\na   = ${b} x         "str x"          text, whitespace IS the value
resolve:b=[1]\na   = ${b} [2]       [1,2]            list, whitespace irrelevant
```

Java drops the gap next to an object or a list, since nothing can concatenate as
text there. We keep it and let evaluation skip it — dropping it is a decision
about what the parts mean.

The end of a part comes from **one** place, `PeakingTokenizer.last_end`, the end
of the last consumed token. Per-branch bookkeeping was tried and got it wrong:
a text part recorded the *next* token's start as its own end, so its gap always
measured zero, and containers reached into `tokenizer.pos`, which runs ahead as
soon as anything has been peeked.

## Rules settled against the oracle

Java (`tools/oracle/hocon-java`) is the authority; see `tools/oracle/README.md`
for why, and for the table of pyhocon divergences. Re-run any of these with:

```sh
printf 'a = {x:5}\n{y:6}\n' | tools/oracle/hocon-java
```

Substitutions print unresolved unless the line starts with `resolve:`, which is
what makes the three rows above testable at all — pyhocon's oracle cannot print
an unresolved substitution and can only be asked the `resolve:` form.

Include cases need a real target on the classpath, otherwise a missing file and
a successful splice both print `{}`:

```sh
printf 'marker = spliced\n' > tools/oracle/inc.conf   # not committed
```

### A newline ends a value

Concatenation only works on one line.

```
a = {x:5} {y:6}       {"a":{"x":5,"y":6}}
a = {x:5}\n{y:6}      ERROR      indenting the second line does not help
a = [1] [2]           {"a":[1,2]}
a = [1]\n[2]          ERROR
a = ${b}\n${c}        ERROR      the second one starts a member with no separator
a = {x:5} # c\n{y:6}  ERROR      a comment counts as a newline
a = b\nc              ERROR      `c` becomes a new key with no value
```

Two places where a newline does *not* end anything, both because the value has
not started or cannot have ended yet:

```
a =\n{x:5}                    OK   right after `=`
a = {\n x:5\n} {\n y:6\n}     OK   inside the braces, where it belongs to the container
```

### `include` is positional, and it commits

A keyword only where a member begins, and only unquoted. Once seen, there is no
fallback to a field named `include` — which is what makes `include = 42` an
error instead of an assignment, and what makes one token of lookahead enough.

```
include "x.conf"          spliced
include"x.conf"           spliced     no whitespace needed, they are two tokens
include\n\n"x.conf"       spliced     newlines between keyword and path are skipped
include # c\n"x.conf"     spliced     and so are comments (folded into .newline)
include,"x.conf"          ERROR: include keyword is not followed by a quoted string
include "a" "b"           ERROR: Expecting end of input or a comma
include ${a}              ERROR       a substitution is not a quoted string
include = 42              ERROR
Include "x.conf"          ERROR       case-sensitive
a = include "x"           {"a":"include x"}       value side: ordinary text
a = [include "x"]         {"a":["include x"]}     array elements too
a { include "x.conf" }    spliced     allowed inside a block
```

The terminator set after the path is newline / comma / eof / `}` / `]`.

### The key side is only strings

```
a.b = 1        {"a":{"b":1}}    the tokenizer keeps `.` inside the word; splitting
"a"."b" = 1    {"a":{"b":1}}    it is the parser's job — see paths below
a "b" c = 1    {"a b c":1}      concatenation, same rules as a value
1 = x          {"1":"x"}        a number is just an unquoted string here
${b} = 1       ERROR            no substitutions in a key
a${b} = 1      ERROR            not even next to one
[a] = 1        ERROR
{a} = 1        ERROR
```

The separator after a key is `=`, `:` (both arrive as `.assignment`), or nothing
at all before a `{`. HOCON also has `+=` (`a += 1` → `{"a":${?a}[1]}`); the
tokenizer does not know it yet.

### Paths as keys

A key is a *path*: elements separated by `.`. An unquoted one nests, and a
malformed one is java's `BadPath`:

```
a.b = 1          {"a":{"b":1}}
a.b.c = 1        {"a":{"b":{"c":1}}}
a. b = 1         {"a":{" b":1}}       whitespace after a dot IS part of the name
a .b = 1         {"a ":{"b":1}}
.a = 1           ERROR BadPath: leading, trailing, or two adjacent period '.'
a. = 1           ERROR BadPath
a..b = 1         ERROR BadPath
a.b = 1
a.c = 2          {"a":{"b":1,"c":2}}  java merges them; our tree keeps both
                                      members side by side, merging is evaluation
```

The two whitespace rows need no special handling: adjacent unquoted strings are
one contiguous slice of the input, *interior whitespace included*, so the key
really is the text `a. b` and splitting it on the dot yields `a` and ` b`.

A key made of several parts is **not** split yet, because the dot that matters
may be inside a quoted part: `a."b.c"` is one element `b.c`, `a.b.c` is two.

```
"a"."b" = 1      assign(concat(value("a"), value(.), value("b")), value(1))
a."b.c" = 1      the same shape — java nests, we keep the parts side by side
```

### Substitutions

`${…}` and `${?…}` stand wherever a value may stand, and nowhere else. The
tokenizer contributes two tokens (`${`, `${?`) and nothing more: the inside is
an ordinary token stream closed by `}`, which is what makes the parser's job one
sentence — parse the path, then require the brace.

```
a = ${b}          {"a":${b}}
a = ${?b}         {"a":${?b}}         `?` only directly after `${`
a = ${? b}        {"a":${?b}}         whitespace after it is free
a = ${ a }        {"a":${a}}          trimmed at the ends
a = ${a b}        {"a":${"a b"}}      but kept inside
a = ${a"b"}       {"a":${ab}}         adjacent parts concatenate, as in a key
a = ${a.b}        {"a":${a.b}}        a path, still unsplit here
a = "${b}"        {"a":"${b}"}        inside quotes it is literal text
a = ${a} # c      {"a":${a}}          a comment ends the value as usual
```

Every rejection falls out of "parse the path, then require `}`" rather than
needing a rule of its own:

```
a = ${}           ERROR BadPath           no parts at all
a = ${ }          ERROR BadPath
a = ${?}          ERROR BadPath
a = ${a           ERROR                   never reaches the brace
a = ${a#c}        ERROR                   the comment eats the brace
a = ${a\nb}       ERROR BadPath           a newline is not part of a path
a = ${${a}}       ERROR BadPath           nor is a substitution
a = ${a${b}}      ERROR BadPath
a = ${ ?a}        ERROR                   `?` is a reserved character here
a = ${a?}         ERROR
a = $b            ERROR                   `$` exists only as the start of `${`
a = b$c           ERROR
```

The optional form is a `NodeKind` of its own rather than a flag: an unresolved
`${?a}` removes the member it belongs to instead of yielding an empty value, and
that difference is too easy to lose in a `bool`.

Mixing with the other parts follows the ordinary concatenation rules, including
next to containers — java allows what it cannot type-check until resolution:

```
a = ${b}c         {"a":${b}"c"}
a = ${b}[1]       {"a":${b}[1]}
a = [1] ${b}      {"a":[1]${b}}
a = {x:1} ${b}    {"a":{"x":1}${b}}
a = [${b}, ${c}]  {"a":[${b},${c}]}
```

## The value graph

`Value.zig` is where the tree stops being about syntax. Two stages, deliberately
separate, because a substitution resolves against the *finished* document:

```
tree  → Value    every member pushed onto its key's stack, nothing decided
Value → Value    resolve folds the stacks, looks up refs, joins concatenations
```

Resolving earlier gives the wrong answer, and it is the bug this project exists
to avoid:

```
a = 1
b = ${a}
a = 2            {"a":2,"b":2}      b sees the finished value, not the one above it
b = ${a}\na = 1  {"a":1,"b":1}      a forward reference is fine
a = ${b}\nb = ${a}   ERROR          a cycle is not
```

### Three holes

A `Value` carries `scalar`, `list` and `object`, plus three kinds of hole that
`resolve` fills and that never occur afterwards. They are separate kinds rather
than one "unresolved" flag because each is filled by a different rule.

`ref` is `${a.b}`. `concat` holds the parts of one value that have not been
joined, since whether they join as text, merge as objects or concatenate as
lists depends on their types.

`pending_merge` is the stack of values written for the *same key* that could not
be merged yet, java's `ConfigDelayedMerge`. It exists because a reference hides
the type that decides the merge:

```
b = {y:2}   a = {x:1}   a = ${b}      {"a":{"x":1,"y":2}}    merged
b = 5       a = {x:1}   a = ${b}      {"a":5}                replaced
a = {x:1}   a = ${b}    (unresolved)  {"a":{"x":1},"a":${b}} java keeps both
```

The last line is java's own unresolved rendering: two members side by side,
because it cannot decide either.

### Why the stack pays for itself

Two rules that would otherwise need special cases fall out of it. Resolving the
entry at index `i` may only look at `[0..i]`, which the spec words as *"when
this would create a cycle, when possible the cycle must be broken by looking
backward only"*. Java implements it by swapping the whole stack for the part
below the entry being resolved, with the comment *"we resetParents() here
because we'll be resolving 'end' against a root which does NOT contain 'end'"*.

That gives:

```
a = 1
a = ${a} 2       {"a":"1 2"}   self-reference, and the mechanism behind `+=`
a = 1
a = ${?nope}     {"a":1}       the entry disappears, the one below stays
```

Neither needs a rule of its own. The first reads the entry below it, the second
removes its own entry.

### Keys

A key in the graph is a **single path element**, already unquoted and
unescaped, so `a` and `"a"` are the same member and nesting is structural:

```
a = 1\n"a" = 2                {"a":2}                  same key
a { x = 1 }\n"a" { y = 2 }    {"a":{"x":1,"y":2}}      merged
"a.b" = 1\na.b = 2            {"a":{"b":2},"a.b":1}    NOT the same key
"a\"b" = 1                    {"a\"b":1}               escapes apply in keys too
```

Only the dot makes a difference, and only when quoted. `Key.zig` owns that
cleanup so the three places that produce an element — a key, a path inside
`${…}`, and a caller's `get("a.b")` — cannot drift apart.

## Next: one splitter for keys and substitution paths

Both sides now hold a path as text and neither splits it. They want the same
code, because they are the same question — which dots separate elements and
which are inside a quoted one:

```
"a"."b" = 1      →  a { b = 1 }
a."b.c" = 1      →  a { "b.c" = 1 }
${a."b.c"}       →  a path of two elements, the second containing a dot
${.a}            →  BadPath, exactly as `.a = 1` already is
```

`prepareMemberNode` does the unquoted half today, by scanning `key.value` for
the last dot. That approach cannot see quotes, which is why it bails out on a
`.concat` key. The replacement walks the *parts*: a dot inside an unquoted part
separates, a dot inside a quoted part does not.

After that: multi-line strings as a value part (the tokenizer already emits
them), then evaluation, where the memory model has to be decided before the
first data structure is written.

## Tests

`table.zig` holds the runner both phases share: a table of `Case`, one input per
row, one line of expected output, and a report that lists every row as ✓/✗
instead of stopping at the first failure. A caller supplies only how to render
one input:

```zig
// Ast.zig — an s-expression of the tree
.ok("a = ${b}", "root(assign(value(a), subst(value(b))))"),
.bad("a = ${}"),

// Tokenizer.zig — the token stream, tag and exact source slice
.ok("${?b}", "dollar_brace_optional(${?) string(b) r_brace(}) eof"),
```

Decl literals mean the `Case.` prefix can be dropped. `.only(…)` runs one row
alone, for a breakpoint — and fails the test even when the row passes, so it
cannot be left behind in a green suite.

Per the standing convention, every test group carries a
`java ✓ · pyhocon ✓ · spec ✓` comment recording what the oracles said, with
divergences spelled out.

One debugger note, learned the hard way: a breakpoint stops *before* its line
runs, and on a function's signature line the parameters are not stored yet — an
enum read there shows its first member. Read values one step further in, or
print them.
