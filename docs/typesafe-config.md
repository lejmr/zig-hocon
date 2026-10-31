# Coming from typesafe/config

typesafe/config (Lightbend Config) is the JVM's HOCON library, the one the spec was written against. zig-hocon follows the spec, and where the two part ways the spec wins. Of the 589 cases of the [conformance suite](https://htmlpreview.github.io/?https://github.com/lejmr/zig-hocon/blob/main/conformance/report.html), zig-hocon reads 498 as typesafe/config 1.4.9 does. Each of the other 91 is a case the suite marks as one where typesafe/config parts from the spec, with what it does instead; the report lists every one. They come in three kinds.

## Read by both, to other values (29)

The config loads on both sides and a value differs. These are the ones to look for in your files:

| config | zig-hocon, as the spec has it | typesafe/config |
|---|---|---|
| `port = 08080` | `"08080"`, text: a number is JSON's, which has no leading zero | `8080` |
| `x { l = [1] }`, `y : ${x} { l += 2 }` | `y.l = [1, 2]`: `+=` appends to what `y` holds, `x`'s list | `y.l = [2]` |
| `HOME = ${?HOME}` | the variable `HOME` | `{}`, the field gone |

The leading zeros are the common one: `get_int` on `"08080"` is an error, where the JVM read 8080. Quote what is text, `zip = "01234"`, and write numbers as JSON does.

## Read by zig-hocon, refused by typesafe/config (43)

A config the JVM cannot load, so none of yours has these yet:

| config | zig-hocon | typesafe/config |
|---|---|---|
| `[1, 2, 3]` | a list at the root, as the spec allows | `WrongType`: no list root |
| `a = [ { b += 1 } ]` | `[{"b": [1]}]` | `Parse`: `+=` inside a list |
| `a = ${mixin} { y = ${a.hello} }` | `y` sees the mixin's `hello` | `UnresolvedSubstitution` |

## Taken by typesafe/config, refused by zig-hocon (19)

Input the spec forbids, which the JVM reads anyway. A config with one of these fails here, with the line and column:

| config | zig-hocon | typesafe/config |
|---|---|---|
| `a = [1, 2] x` | `UnsupportedConcatenation`: a list and text do not join | `[1, 2]`, the `x` dropped |
| `include.foo : 42` | `UnexpectedToken`: `include` starts an include | `{"include": {"foo": 42}}` |
| `a = -.33e+1` | `BadNumber`: no JSON number, which needs a digit before `.`, and as text its `+` is reserved | `-3.3` |

## The API

| typesafe/config | zig-hocon |
|---|---|
| `ConfigFactory.load()`, `application.conf` and `reference.conf` on the classpath | `parseFromFile` with the path; `include classpath(…)` is not supported |
| `config.withFallback(reference)` | `include required("reference.conf")`, the first line of `application.conf` |
| system properties over the config (`-Dkey=value`) | none; a `${?VAR}` reads the environment |
| `getDuration`, nanoseconds in a long, up to 292 years | `hocon.Duration`, exact in an i96 |
| `getBytes`, a long | `hocon.Size`, a u64, up to 16 EiB |
| `getConfig`, `getString`, … | a field of your struct, or `hocon.Value` |

[docs/spec.md](spec.md) goes through the spec section by section, with what typesafe/config does where it differs.

## Check your own configs

Print each config resolved, from both, and compare:

```sh
hocon --json --env=none app.conf > zig.json
# on the JVM: ConfigFactory.parseFile(new File("app.conf")).resolve().root().render(ConfigRenderOptions.concise())
```

[tools/oracle/hocon-java](../tools/oracle/README.md) does the JVM side from the command line.
