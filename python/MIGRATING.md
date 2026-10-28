# Migrating from pyhocon

This guide moves a project from pyhocon to zig_hocon. Code that reads through `ConfigFactory` and the typed getters changes its imports: those and the exception names are the same. Code that uses the tree as a dict, or `get`, `get_list`, `with_fallback`, `put` or `from_dict`, needs a few lines more (Step 2), and a config with `include package(...)` needs a change. Steps 1 to 3 cover all of it, and the checklist at the end finds every place to look at.

## Why move

- **Correct.** zig_hocon passes all 586 tests in the [conformance suite](https://htmlpreview.github.io/?https://github.com/lejmr/zig-hocon/blob/main/conformance/report.html), pyhocon 359.
- **Fast.** A 10 MB config loads in 0.3 s. pyhocon takes 68 s, and 867 s when the file has substitutions.
- **No crash on `+=`.** Appending one element to a list stops pyhocon 0.3.63 with an `AttributeError`, in one file or across an include:

  ```hocon
  plugins = [auth]
  plugins += metrics
  ```

  zig_hocon gives `["auth", "metrics"]`. pyhocon reads only `plugins += [metrics]`, a list, which the spec reads as one element: `migrate` shows each such line.
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
| `HOCONConverter.to_json(conf)` | `conf.to_json()` (bytes) |
| `HOCONConverter.to_hocon(conf)` | `conf.to_hocon()` |

The exception names are the same: `ConfigException`, `ConfigMissingException` (also a `KeyError`), `ConfigSubstitutionException`, `ConfigWrongTypeException` (also a `ValueError`), plus `ConfigParseException` for text that is not valid HOCON.

## Step 2: what needs code

**The tree is not a dict.** (`zig_hocon.ConfigTree` is the type `parse_file` gives, for your type hints.) pyhocon's `ConfigTree` is an `OrderedDict`, so `conf["db"]["host"]`, `"db" in conf`, `for key in conf`, `dict(conf)` and `json.dumps(conf)` work on it. Here the values stay in the library until a getter asks; take a dict where you need one:

```python
settings = conf.as_dict()
settings["db"]["host"]
```

**Methods that are not there**, and what does the job:

| pyhocon | instead |
|---|---|
| `conf.get(path)`, `conf.get_list(path)` | a typed getter, or `functools.reduce(dict.__getitem__, path.split("."), conf.as_dict())` for a plain dotted path |
| `conf.with_fallback(defaults)` | `include "defaults.conf"` at the top of the file: the same merge, done by the parser. For defaults that ship inside your package, build the includes in code: `ConfigFactory.parse_string(f'include required(file({json.dumps(str(defaults))}))\ninclude required(file({json.dumps(str(app))}))', basedir=app.parent)`; `basedir` is needed even for absolute paths, and `required` makes a missing file an error, where a plain include skips it: a `ConfigParseException` named `IncludeNotFound`, not the `FileNotFound` of `parse_file`. A `${…}` in the defaults sees the value the file sets over it (`url = "…${host}…"` with `host` overridden takes the new host), as the spec and typesafe/config resolve, and as pyhocon does over `resolve=False`; a loader that resolved each file first kept the old one. `migrate --fallback defaults.conf` reads your configs as such a loader does |
| `conf.put(…)`, `conf.pop(…)` | change the dict from `as_dict()` |
| `ConfigFactory.from_dict(d)` | `ConfigFactory.parse_string(json.dumps(d))`: JSON is HOCON |
| `ConfigFactory.parse_URL(url)` | `include url("…")` in a file, or fetch it and `parse_string` |
| `parse_file(path, encoding=…)` | files are UTF-8 |
| `parse_file(path, required=False)` | catch the `ConfigException` named `FileNotFound` |
| `unresolved_value=…` | `resolve=False` keeps every `${…}`, `env=KEEP` only the variables |
| `include package("pkg:file.conf")` | not supported, see Step 3 |

`parse_file` takes everything after the path by keyword, so `parse_file(path, "utf-8")` fails loudly instead of meaning something else.

## Step 3: configs that read differently

- **`include package(...)` is not supported.** It is pyhocon's own extension, not HOCON, and zig_hocon reports it as an error (`UnexpectedToken` where `package` starts). Include the file by its path instead, relative to the file that includes it:

  ```hocon
  include "defaults.conf"
  ```

  For a file that ships inside an installed Python package, find it in Python and parse it from there:

  ```python
  from importlib.resources import files

  conf = ConfigFactory.parse_file(str(files("mypackage") / "defaults.conf"))
  ```

- **Durations and sizes are text until something asks.** pyhocon turns `30s` into a `timedelta` while it parses; here `as_dict()` has `"30s"`, and `get_duration` or the model converts it. With pydantic, a `BeforeValidator(zig_hocon.parse_duration)` on the field; [examples/durations-and-sizes](examples/durations-and-sizes) has it for pydantic and msgspec.
- **A concatenation is a string.** `a = ${?nope}42` is `"42"` by the spec; pyhocon gives the number `42`. A model that wants an int converts it.
- **An `include url(…)` gives up after 30 s.** pyhocon waits as long as `socket.setdefaulttimeout` says, by default for ever. Here `http_timeout=` on `parse_file` and `parse_string` sets it, and a server that does not answer in time is a `ConfigParseException` named `IncludeTimeout`.
- **A leading zero keeps the text.** A value that begins with a digit begins with the number JSON reads there, and the rest is text, so `zip = 01234` is `"01234"` by the spec; pyhocon gives the number 1234. An IP address, a version or a UUID is text as written, as in pyhocon. So is a value that begins with `-` and no number, `-foo` or `-Xmx2g`, and a fraction JSON has no number for: `.5` and `-.5` are the text `".5"` and `"-.5"`, where pyhocon gives 0.5 and -0.5. Text becomes a number only by the JSON rules, so `get_int("zip")` on `01234` and `get_float` on `-.5` raise `ConfigWrongTypeException`, where pyhocon gives 1234 and -0.5: write `zip = "01234"` and read it with `get_string`, or `-0.5`.
- **`+=` appends one element.** `x += [3, 4]` after `x = [1, 2]` is `[1, 2, [3, 4]]`, as `x = ${?x} [[3, 4]]` is; pyhocon gives `[1, 2, 3, 4]`. It is the one form of `+=` pyhocon takes, so every pyhocon repo has it: `grep -rnE '\+= *\[' conf/` finds each. To extend a list with another, `x = ${x} [3, 4]`. pyhocon reads that the same in one file, but across nested includes it loses elements (its own bug: `[1, 3]` for `[1, 2, 3]`), so do not count on a config reading alike in both while you move: `migrate` shows where they part.
- **Strict syntax.** The other inputs in the table under *No silent guesses* are errors now. They are rare, and each error says where to look.

Everything else (variables, includes, merging) reads the same, except where pyhocon breaks the spec; the conformance report lists those cases.

## Checklist

Read your configs with both, with pyhocon installed beside zig-hocon:

```sh
python -m zig_hocon migrate conf/ --env-file prod.env
```

```
conf/prod.conf
  db
    ≈ timeout   pyhocon datetime.timedelta(seconds=30)   zig-hocon '30s'
        the same through conf.get_duration("db.timeout")
    pool
      ≠ size   pyhocon 24   zig-hocon '0024'
          conf.get_int("db.pool.size") is an error: InvalidCharacter
  ≠ tags   pyhocon [1, 2, 3, 4]   zig-hocon [1, 2, [3, 4]]
      += appends one element, here a list; x = ${x} [...] extends it (MIGRATING.md, Step 3)

  conf/prod.conf   3 differences
  conf/test.conf   both fail
3 differences in 1 file.
```

Each config is read by pyhocon and by `zig_hocon`, with the same environment (`--env-file` with `KEY=value` lines, as a shell or docker writes them, `export` and quotes allowed, a later file over an earlier one; `--env KEY=VALUE` over the files), and what differs is shown as the config's tree:

- `≈` another type that a getter reads the same: code that reads it with that getter, as most pyhocon code does, is not touched by it; `as_dict()` and a model are. The [examples](examples) show how a model reads a duration, with pydantic, msgspec and dataclasses.
- `≠` another value, or a key only one of them has, with the getter's error where there is one. Also the same value that a getter reads otherwise: a number `get_string` reads as written (`1.10` where pyhocon has `1.1`), text pyhocon's `get_int`, `get_float` or `get_bool` reads and zig_hocon's do not (`"08"`, `" 4"`, `"True"`, often from the environment), and `null`, which pyhocon's getters give as `None` and zig_hocon's as an error. Getters are not run on list elements, nor `get_int` on a number with a fraction, which pyhocon cuts.
- `!` one of them fails, with the error and its place; when both fail (`· both fail`), say on a `${…}` the environment has no value for, it is no difference.

With an env file per environment, check each overlay with its own, one run per environment:

```sh
for env in prod staging dev; do
  python -m zig_hocon migrate "conf/$env.conf" --env-file "env/$env.env" --fallback reference.conf || status=1
done
exit ${status:-0}
```

The values that matter most are the ones in no file here: production's environment from the secret store. zig_hocon reads a number or a boolean from it only as written, so `08`, ` 48`, `True` or `1` that started a service on pyhocon stop it now (`get_int`, `get_bool`). Export them once into an env file, `KEY=value` lines, and run `migrate` with it, or check them by hand before the switch.

A difference you have reviewed and keep, `"0640"` your code reads with `get_string`, is `--accept storage.file_mode`: it is still shown, marked `(accepted)`, and no longer a difference. A path names one value, a list element (`tags[2]`) or everything below it (`storage`). With those, and `--getters` where durations and sizes go through the getters or your model's validators, the run can wait in CI for green.

A config your loader merges in code, `conf.with_fallback(reference)`, is read alone by neither library as it is in your service; pyhocon often fails on it with `AttributeError: 'bool' object has no attribute 'count'` (its bug with `+=` onto a list from another file). `--fallback reference.conf` reads each config over it, pyhocon through `with_fallback` over `resolve=False` as such a loader does, zig_hocon through `include required(file(…))`; give it again for one under that. `--getters` makes `≈` no difference and lists it with the same: for code that reads such values through the getters, or through a model that converts them as they do (a duration field with `BeforeValidator(zig_hocon.parse_duration)`, below). Without it a duration stays a difference, as plain `as_dict()` would give `"30s"`.

A directory is its `*.conf` files (`--glob` for others), without those another file includes: they are checked through the file that includes them, as they often cannot be read alone. `--all` checks every file and shows what is the same, and `--json` gives the same tree as JSON. It exits 0 when everything is the same, 1 when not, 2 when it cannot run or compares nothing: a path that is not there, a directory with no file `--glob` names, or configs that each fail in both, so it can wait in CI for the day it is green. pyhocon is no dependency of zig-hocon; the tool imports it.

In the code, each place that uses pyhocon's API is a row in Step 2 or 3:

```sh
grep -rnE "pyhocon|include package|as_plain_ordered_dict|get_list|with_fallback|from_dict|parse_URL|HOCONConverter|\.put\(|\.pop\(|\.get\(|conf\[| in conf\b|json\.dumps\(conf|\+= *\[" .
```
