# Migrating from pyhocon

This guide moves a project from pyhocon to zig_hocon. It is not an import swap: only `ConfigFactory` and the typed getters carry over (Step 1); code that uses the tree as a dict, reads lists or calls pyhocon's other methods is rewritten (Step 2), mostly onto `as_dict()` or a model; a few configs read differently (Step 3). `zig-hocon-migrate` reads your configs with both and shows every difference ([Checklist](#checklist)).

**Before you switch, check your secret store.** zig_hocon reads a number or a boolean from the environment only as written: `08`, ` 48` or `True`, which pyhocon took, now stop a service at startup in `get_int` or `get_bool`. It is the most common way a service does not start after the move. Export each deployment's environment into an env file and run `zig-hocon-migrate` with it.

## Why move

- **Correct.** zig_hocon passes all 588 tests in the [conformance suite](https://htmlpreview.github.io/?https://github.com/lejmr/zig-hocon/blob/main/conformance/report.html), pyhocon 379.
- **Fast.** A 1 MB config with substitutions loads in 13 ms, where pyhocon takes 8 s; a 10 MB one in 0.14 s, where pyhocon took 490 s ([BENCHMARK.md](BENCHMARK.md)).
- **`+=` as written.** pyhocon stops with an `AttributeError` on `plugins += metrics` after `plugins = [auth]`, puts 2 in place of the list on `x += 2`, and keeps only some elements when a list is appended to in two files or inside a `{ }` block. zig_hocon gives `["auth", "metrics"]` and reads every append the file names.
- **No silent guesses.** pyhocon accepts input the spec rejects and changes what you wrote. zig_hocon reports an error with its place:

  | input | pyhocon 0.3.63 | zig_hocon |
  |---|---|---|
  | `a = [include "x"]` | `{"a": []}`, the element is gone | `{"a": ["include x"]}` |
  | `a..b = 1` | `{"a": {"b": 1}}` | error at 1:3 |
  | `a = b:c` | `{"a": "b:c"}` | error at 1:6 (`:` is reserved) |
  | `,a = b` | `{"a": "b"}` | error at 1:1 |
  | `a = b<TAB>c` | `"b   c"`, the tab became spaces | `"b\tc"` |

- **One exception to catch.** Every error is a `ConfigException`, with the file, line and column. A syntax error in pyhocon is pyparsing's `ParseSyntaxException`, which `except ConfigException` misses.

## Step 1: imports

| pyhocon | zig_hocon |
|---|---|
| `from pyhocon import ConfigFactory` | `from zig_hocon import ConfigFactory` |
| `from pyhocon.exceptions import ConfigMissingException` (and the others) | `from zig_hocon.exceptions import ConfigMissingException` |
| `ConfigFactory.parse_file(path, resolve=False)` | the same |
| `ConfigFactory.parse_string(text, basedir=…)` | the same |
| `conf.get_string / get_int / get_float / get_bool / get_config(path, default)` | the same |
| `conf.as_plain_ordered_dict()` | `conf.as_dict()` |
| `HOCONConverter.to_json(conf)` | `conf.to_json()` (bytes); a duration is its text, `"10s"`, where pyhocon wrote milliseconds |
| `HOCONConverter.to_hocon(conf)` | `conf.to_hocon()` |

The exception names are the same: `ConfigException`, `ConfigMissingException` (also a `KeyError`), `ConfigSubstitutionException`, `ConfigWrongTypeException` (also a `ValueError`), plus `ConfigParseException` for text that is not valid HOCON. `zig_hocon.ConfigTree` is the type `parse_file` returns, for type hints.

## Step 2: what needs code

**The tree is not a dict.** pyhocon's `ConfigTree` is an `OrderedDict`, so `conf["db"]["host"]`, `"db" in conf`, `for key in conf` and `json.dumps(conf)` work on it. Here the values stay in the library until a getter asks; take a dict where you need one: `settings = conf.as_dict()`. Code that reads the tree outside the model is where pyhocon's getters checked types for you; move it onto the model.

| pyhocon | instead |
|---|---|
| `conf.get(path)` | a typed getter, `get_string`, `get_int`, …; a duration pyhocon gave as a `timedelta` is `conf.get_duration(path)`, a new call, and a size `conf.get_bytes(path)` |
| `conf.get_list(path)` | the field in your model, `list[str]` or a list of durations with the validator (Step 3); `as_dict()[…]` only where you check the type yourself: `proxies = ${?PROXIES}` with `a,b` in it is the text `"a,b"`, which `get_list` refused and a loop reads letter by letter |
| `conf.with_fallback(defaults)` | an include, below |
| `conf.put(…)`, `conf.pop(…)` | change the dict from `as_dict()` |
| `conf.copy()`, `copy.deepcopy(conf)` | not needed: a tree is read only, `copy.deepcopy` gives the tree itself (0.6.0; before, a `TypeError`) |
| `ConfigFactory.from_dict(d)` | `ConfigFactory.parse_string(json.dumps(d))`: JSON is HOCON |
| `ConfigFactory.parse_URL(url)` | `include url("…")` in a file, or fetch it and `parse_string` |
| `parse_file(path, encoding=…)` | files are UTF-8 |
| `parse_file(path, required=False)` | catch the `ConfigException` named `FileNotFound` |
| `unresolved_value=…` | `resolve=False` keeps every `${…}`, `env=KEEP` only the variables |
| `include package("pkg:file.conf")` | not supported, see Step 3 |

`parse_file` takes everything after the path by keyword, so `parse_file(path, "utf-8")` fails loudly instead of meaning something else.

**`with_fallback` becomes an include**, the merge done where HOCON does it. Make the defaults the first line of `application.conf`:

```hocon
include required("reference.conf")
```

Every file that includes `application.conf` then reads the defaults under it, and `parse_file`, `hocon check` and `zig-hocon-migrate` read the whole config from one file. For defaults that ship inside your package, build the includes in code:

```python
text = f'include required(file({json.dumps(str(defaults))}))\ninclude required(file({json.dumps(str(app))}))'
conf = ConfigFactory.parse_string(text, basedir=app.parent)
```

`basedir` is needed even for absolute paths. `required` makes a missing file a `ConfigParseException` named `IncludeNotFound`, where a plain include skips it. A `${…}` in the defaults sees the value the file sets over it: `url = "…${host}…"` takes the overridden host, as the spec and typesafe/config resolve, and as pyhocon does over `resolve=False`.

## Step 3: configs that read differently

- **Durations and sizes are text until something asks.** pyhocon turns `30s` into a `timedelta` while it parses; here `as_dict()` has `"30s"`, and `get_duration` or the model converts it. With pydantic, a `BeforeValidator(zig_hocon.parse_duration)` on the field; [examples/durations-and-sizes](examples/durations-and-sizes) has it for pydantic and msgspec. A number alone is milliseconds to `parse_duration` (`"0.5"` is half a millisecond), so keep the validator on duration fields, not on a `float | timedelta`.
- **Values from the environment are text.** `${DB_POOL}` with `48` in it is `"48"`, as the spec has it: `get_int` reads it, `" 48"` and `08` it refuses. A pydantic model with lax types reads `"48"` too, and also takes `"08"` as 8; a strict one refuses them all, so keep config models lax, and to read a number or a boolean as the getters and a Zig struct do, give the field `BeforeValidator(zig_hocon.parse_int)` or `parse_bool` (README, *Strict, as the Zig side reads it*). When a getter refuses a value, a traceback notes what it read, `found '08'` (zig-hocon 0.6.0, Python 3.11 and later).
- **A leading zero keeps the text.** `zip = 01234` is `"01234"`; pyhocon gives 1234. So are `.5` and `-.5`, `-foo` and `-Xmx2g`, an IP address, a version and a UUID: text becomes a number only by the JSON rules. `get_int("zip")` on `01234` and `get_float` on `-.5` raise `ConfigWrongTypeException`: write `zip = "01234"` and read it with `get_string`, or write `-0.5`.
- **`+=` appends one element.** `x += [3, 4]` after `x = [1, 2]` is `[1, 2, [3, 4]]`; pyhocon gives `[1, 2, 3, 4]`. It is the one form of `+=` pyhocon takes, so every pyhocon config has it (`grep -rnE '\+= *\[' conf/`). To extend a list with another, `x = ${x} [3, 4]`. pyhocon reads that alike in one file but loses elements across nested includes, so compare the old config with the new one (`--before`, below).
- **An undefined optional next to one other value keeps that value's type.** The suite, typesafe/config and zig-hocon read `a = ${?nope}42` as the number `42` (L376, L636-637); pyhocon already has the number.
- **`include package(...)` is not supported.** It is pyhocon's own; zig_hocon reports `UnexpectedToken` where `package` starts. Include the file by its path, or for a file in an installed package find it in Python: `ConfigFactory.parse_file(str(importlib.resources.files("mypackage") / "defaults.conf"))`.
- **An `include url(…)` gives up after 30 s**, where pyhocon waits as long as `socket.setdefaulttimeout` says. `http_timeout=` on `parse_file` and `parse_string` sets it; a server that does not answer in time is a `ConfigParseException` named `IncludeTimeout`.
- **Strict syntax.** The other inputs under *No silent guesses* are errors now, each with where to look.

Everything else (variables, includes, merging) reads the same, except where pyhocon breaks the spec; the conformance report lists those cases.

## Checklist

`pip install -U zig-hocon` puts `zig-hocon-migrate` on the path (`python -m zig_hocon migrate` is the same; both come with zig-hocon 0.6.0). With pyhocon installed beside it, it reads each config with both, with the same environment, and shows what differs as the config's tree:

```sh
zig-hocon-migrate conf/prod.conf --env-file env/prod.env
```

```
conf/prod.conf
  db
    ≈ timeout   pyhocon datetime.timedelta(seconds=30) → zig-hocon '30s'
        the same through zig_hocon's conf.get_duration("db.timeout")
    pool
      ≠ size   pyhocon 24 → zig-hocon '0024'
          conf.get_int("db.pool.size"): zig-hocon error (InvalidCharacter)
  ≠ tags   pyhocon [1, 2, 3, 4] → zig-hocon [1, 2, [3, 4]]
      += appends one element, here a list; tags = ${?tags} [...] extends it (MIGRATING.md, Step 3)

  conf/prod.conf   3 differences
3 differences in 1 file.
pyhocon → zig-hocon · ≠ reads differently · ≈ the same through a zig_hocon getter (--getters) · ! fails in one of them · --accept PATH once reviewed
```

On a terminal, pyhocon's side is red and zig-hocon's green, without the labels. The marks:

- `≠` another value, a key only one of them has, or the same value that a getter reads otherwise: `'0640' in both` with `get_int: pyhocon 640 → zig-hocon error` below.
- `≈` another type that zig_hocon's getter reads the same, such as a duration: code that reads it through that getter is not touched, `as_dict()` and a model are. A key `null` on one side and absent on the other is `≈` too.
- `!` one of them fails, with the error and its place. When both fail, say on a `${…}` with no value, it is no difference.

It exits 0 when everything is the same, 1 when not, and 2 when it compares nothing: no such path, no `*.conf` in a directory, or every config failing in both.

| flag | what it does |
|---|---|
| `--env-file FILE`, `--env KEY=VALUE` | the environment both read: the shell's, with these over it (`KEY=value` lines as docker compose and python-dotenv read them, a file written for `source` with `export` and quotes as it is, a later file over an earlier one; below); `env -i PATH="$PATH" zig-hocon-migrate …` starts from none |
| `--before REV` | pyhocon reads the configs as git has them at `REV`, zig_hocon as they are now: the check a migration pull request wants, as a config rewritten for zig_hocon (`x += a`) often stops pyhocon |
| `--getters` | `≈` is no difference, for code that reads such values through the getters or a model's validators |
| `--accept PATH` | a difference you reviewed and keep: still shown, marked `(accepted)`, not counted, such as `"0640"` your code reads with `get_string`, or a list of durations, whose elements no getter reads; a path names a value, a list element (`tags[2]`) or everything below it, and one that names no difference is reported |
| `--fallback FILE` | reads each config over `FILE`, as an old loader's `conf.with_fallback(FILE)`; `--resolve-each` for a loader that resolved each file before merging |
| `--all`, `--json`, `--glob`, `--color` | every file and what is the same; the tree as JSON; the files of a directory (`*.conf`); colours (`auto`, `always`, `never`, and `NO_COLOR`) |

An env file, one per deployment:

```sh
# env/prod.env
DB_HOST=db.internal
DB_POOL=16
# a line written for `source` reads the same
export LOG_LEVEL="warn"
```

A directory is its `*.conf` files without those another file includes, as those are checked through the files that include them.

In CI, check each deployment with its own environment against the configs on your main branch, until it is green:

```sh
failed=0
for env in prod staging dev; do
  zig-hocon-migrate "conf/$env.conf" --env-file "env/$env.env" --before main --getters || failed=1
done
test "$failed" = 0
```

In the code, each place that uses pyhocon's API is a row in Step 2. This grep finds them where the config is called `conf`; look for your own names too:

```sh
grep -rnE "pyhocon|include package|as_plain_ordered_dict|get_list|with_fallback|from_dict|parse_URL|HOCONConverter|conf\.(get|put|pop|copy)\(|deepcopy\(conf|conf\[| in conf\b|json\.dumps\(conf|\+= *\[" .
```
