# Migrating from pyhocon

This guide moves a project from pyhocon to zig_hocon. For most code it is a change of imports: `ConfigFactory`, the typed getters and the exception names are the same. Code that uses the tree as a dict needs a few lines more, and a config with `include package(...)` needs a change. Steps 1 to 3 cover all of it, and the checklist at the end finds every place to look at.

## Why move

- **Correct.** zig_hocon passes all 506 tests in the [conformance suite](https://htmlpreview.github.io/?https://github.com/lejmr/zig-hocon/blob/main/conformance/report.html), pyhocon 343.
- **Fast.** A 10 MB config loads in 0.3 s. pyhocon takes 68 s, and 867 s when the file has substitutions.
- **No crash on a layered config.** A list from an included file, extended with `+=`, stops pyhocon 0.3.63 with an `AttributeError`:

  ```hocon
  # defaults.conf
  plugins = [auth]
  ```
  ```hocon
  # prod.conf
  include "defaults.conf"
  plugins += metrics
  ```

  zig_hocon gives `["auth", "metrics"]`.
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

**The tree is not a dict.** pyhocon's `ConfigTree` is an `OrderedDict`, so `conf["db"]["host"]`, `"db" in conf`, `for key in conf`, `dict(conf)` and `json.dumps(conf)` work on it. Here the values stay in the library until a getter asks; take a dict where you need one:

```python
settings = conf.as_dict()
settings["db"]["host"]
```

**Methods that are not there**, and what does the job:

| pyhocon | instead |
|---|---|
| `conf.get(path)`, `conf.get_list(path)` | a typed getter, or `functools.reduce(dict.__getitem__, path.split("."), conf.as_dict())` for a plain dotted path |
| `conf.with_fallback(defaults)` | `include "defaults.conf"` at the top of the file: the same merge, done by the parser |
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
- **Strict syntax.** The other inputs in the table under *No silent guesses* are errors now. They are rare, and each error says where to look.

Everything else (variables, `+=`, includes, merging) reads the same, except where pyhocon breaks the spec; the conformance report lists those cases.

## Checklist

Run this over the code that uses pyhocon; each hit is a row in Step 2 or 3:

```sh
grep -rnE "pyhocon|include package|as_plain_ordered_dict|get_list|with_fallback|from_dict|parse_URL|HOCONConverter|\.put\(|\.pop\(|conf\[" .
```

Then load each of your configs with both and compare. With both packages installed:

```python
import sys

import pyhocon
import zig_hocon

for path in sys.argv[1:]:
    old = pyhocon.ConfigFactory.parse_file(path).as_plain_ordered_dict()
    new = zig_hocon.ConfigFactory.parse_file(path).as_dict()
    print("same" if old == new else "DIFFERENT", path)
```

A duration shows as a difference by design: pyhocon has a `timedelta`, zig_hocon the text `"30s"`. The [examples](examples) show how a model reads it, with pydantic, msgspec and dataclasses.
