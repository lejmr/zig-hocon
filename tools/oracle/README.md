# HOCON oracles

Two reference implementations, same input and output format, so a disputed case
can be answered by running it instead of arguing from the spec.

```sh
printf 'a = b\na = milos kozak\n' | tools/oracle/hocon-java
printf 'a = b\na = milos kozak\n' | tools/oracle/hocon-py
```

Both scripts bootstrap themselves on first run: `hocon-java` downloads
`config.jar` from Maven Central and compiles `Oracle.java`, `hocon-py` creates a
venv and installs `pyhocon`. None of that is committed — see `.gitignore`.

## Format

One test case per line on stdin, with `\n`, `\t`, `\"` escapes:

```
a = b\nc = d
```

One result line out: compact JSON, or `ERROR <Class>: <message>`. Substitutions
are left unresolved unless the line is prefixed with `resolve:`.

## Which one is right

**`hocon-java` is the authority.** It is Lightbend's `typesafe/config`, the
implementation the HOCON spec was written against.

`hocon-py` is here because pyhocon is what this project is meant to replace —
useful for checking that we stay compatible with configs that work today, not
for deciding what is correct. Confirmed divergences:

| input | java | pyhocon |
|---|---|---|
| `"a" b = c` | `{"a b":"c"}` | error |
| `"a"."b" = c` | `{"a":{"b":"c"}}` | error |
| `a = b\tc` | `{"a":"b\tc"}` — tab kept | `{"a":"b   c"}` — tab expanded |
| `a = b:c` | error — `:` is reserved | `{"a":"b:c"}` |
| `a = b\\c` | error — `\` is reserved | `{"a":"b\\c"}` |
| `,a = b` | error | `{"a":"b"}` |
| `a = b,,c = d` | error | `{"a":"b","c":"d"}` |

Where the two disagree, follow java; where java is stricter, being lenient like
pyhocon is the safer choice for migration — a config that parses today should
keep parsing.
