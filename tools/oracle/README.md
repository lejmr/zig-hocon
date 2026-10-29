# HOCON oracles

Two reference implementations, same input and output format, so a disputed case can be answered by running it instead of arguing from the spec.

```sh
printf 'a = b\na = the cat sat on the keyboard\n' | tools/oracle/hocon-java
printf 'a = b\na = the cat sat on the keyboard\n' | tools/oracle/hocon-py
```

Both scripts bootstrap themselves on first run: `hocon-java` downloads `config-1.4.9.jar` (or the release `HOCON_JAVA_VERSION` names) from Maven Central and compiles `Oracle.java`, `hocon-py` creates a venv and installs `pyhocon`. None of that is committed — see `.gitignore`.

## Format

One test case per line on stdin, with `\n`, `\t`, `\"` escapes:

```
a = b\nc = d
```

One result line out: compact JSON, or `ERROR <Class>: <message>`. Substitutions are left unresolved unless the line is prefixed with `resolve:`.

`hocon-java` also has the typed getters of the units format: a line prefixed with `as:duration:`, `as:period:` or `as:bytes:` is resolved and its key `a` read with `getDuration` (printed in nanoseconds), `getPeriod` (`P1Y2M3D`) or `getBytes`. pyhocon has no getters for them; it turns durations and periods into `timedelta` while parsing, and leaves sizes as strings.

```sh
printf 'as:duration:a = 1.5 s\nas:bytes:a = 512K\n' | tools/oracle/hocon-java
```

## Which one is right

**The spec is the authority.** `hocon-java` is Lightbend's `typesafe/config`, the implementation the HOCON spec was written against, and the first witness; where it disagrees with the spec, the spec wins.

`hocon-py` is here because pyhocon is what this project is meant to replace — useful for checking that we stay compatible with configs that work today, not for deciding what is correct. Confirmed divergences:

| input | java | pyhocon | zig-Hocon (this repo) | what the spec says |
|---|---|---|---|---|
| `"a" b = c` | `{"a b":"c"}` | error | ✅ `assign(concat(value("a"), value( ), value(b)), value(c))` — matches java | **java.** A key is a path expression, and a path element may be a quoted or an unquoted string; adjacent ones concatenate like any value. |
| `"a"."b" = c` | `{"a":{"b":"c"}}` | error | ✅ `{"a":{"b":"c"}}` — matches java | **java.** Path elements are separated by `.` and each may be quoted, which is the documented way to put a `.` inside a single key. |
| `a = b\tc` | `{"a":"b\tc"}` — tab kept | `{"a":"b   c"}` — tab expanded | ✅ `value(b\tc)` — matches java | **java.** Whitespace between simple values is preserved verbatim in value concatenation; nothing licenses rewriting a tab. |
| `a = b:c` | error — `:` is reserved | `{"a":"b:c"}` | ✅ `UnexpectedToken` | **java.** `:` is in the list of characters forbidden in unquoted strings (``$ " { } [ ] : = , + # ` ^ ? ! @ * & \``). |
| `a = b\\c` | error — `\` is reserved | `{"a":"b\\c"}` | ✅ `UnexpectedToken` | **java.** `\` is on the same forbidden list. |
| `,a = b` | error | `{"a":"b"}` | ✅ `UnexpectedToken` — matches java | **java.** A comma *separates* elements, and only a trailing one is explicitly permitted — a leading comma has nothing to separate. |
| `a = b,,c = d` | error | `{"a":"b","c":"d"}` | ✅ `UnexpectedToken` — matches java | **java.** Same rule: `,` and newline are separators, not filler, so a doubled comma is not covered. |
| `a = include "x"` | `{"a":"include x"}` | error — tries to load `x` | ✅ `concat(value(include), …)` — matches java | **java.** `include` is a keyword only where a field starts. On the value side it is an ordinary unquoted string. |
| `a = [include "x"]` | `{"a":["include x"]}` | `{"a":[]}` — **silently dropped** | ✅ matches java | **java.** Same rule. Note pyhocon loses the element with no error at all. |
| `include = 42` | error | `{"include":42}` | ✅ `UnexpectedToken` — matches java, the keyword commits | **java.** The keyword commits: the spec has it followed by a quoted string or one of `file()`/`url()`/`classpath()`, with no fallback to a field named `include`. |
| `.a = 1` | error — `BadPath` | `{"a":1}` — **empty element dropped** | ✅ `MalformedKey` — rejected like java, the split refuses an empty element | **java.** A path element may be empty only if written as `""`; the error message says so outright. |
| `a..b = 1` | error — `BadPath` | `{"a":{"b":1}}` — **silently** | ✅ `MalformedKey` — matches java | **java.** Same rule, and pyhocon guesses at what the author meant. |
| `a "b c" d = f` | `{"a b c d":"f"}` | error | ✅ `{"a b c d":"f"}` — matches java | **java.** A key is a path expression and adjacent elements concatenate exactly like a value. |
| `Include "x.conf"` | error | includes the file | ✅ `UnexpectedToken` — matches java | **java.** The spec spells the keyword lowercase; pyhocon matches case-insensitively. |

The zig-Hocon column is what the parser does *today*, produced by dumping the ast for each input — not what it is meant to do. ✅ means the behaviour is settled; every row is.

The spec is written against java, so on every divergence found so far it backs java and pyhocon is simply wrong.

Where they differ, the spec decides; on every row above it backs java.
