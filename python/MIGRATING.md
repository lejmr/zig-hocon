# Migrating from pyhocon

This guide moves a project from pyhocon to zig_hocon. There are two ways:

- **`zig_hocon.pyhocon`, a change of import.** pyhocon's API as pyhocon 0.3.63 has it: the same modules, names, arguments and output, the tree an `OrderedDict` you can `put` into and `pop` from. The section below says what it covers and what it does not.
- **`zig_hocon`, the package's own API.** Typed getters on a document that stays in the library until one asks, and no tree in Python at all: Steps 1 and 2.

Either way a config reads by the spec, which in a few places is not how pyhocon reads it: Step 3. The checklist at the end finds every place to look at.

## Why move

- **Correct.** zig_hocon passes all 586 tests in the [conformance suite](https://htmlpreview.github.io/?https://github.com/lejmr/zig-hocon/blob/main/conformance/report.html), pyhocon 359.
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

## The short way: zig_hocon.pyhocon

Replace `pyhocon` with `zig_hocon.pyhocon` in the imports and leave the rest:

```python
from zig_hocon.pyhocon import ConfigFactory, ConfigTree, HOCONConverter
from zig_hocon.pyhocon.exceptions import ConfigMissingException
```

Everything of pyhocon's public API is there: `ConfigFactory.parse_file` (with `encoding` and `required`), `parse_string`, `parse_URL`, `from_dict`; the `ConfigTree` with `get`, the typed getters, `get_list`, `get_config`, `put`, `pop`, `with_fallback`, `merge_configs`, `as_plain_ordered_dict`, `conf["db.host"]` and `conf.db.host`; `ConfigParser.parse`, `resolve_substitutions` and `resolve_package_path`; `HOCONConverter` with its JSON, HOCON, YAML and .properties output to the character; `period_parser` and `period_serializer`; and pyhocon's command line as `python -m zig_hocon.pyhocon.tool`. The exceptions are zig_hocon's, so one `except` catches either module's.

Two tests hold it against the newest pyhocon on every change: [test_pyhocon_signatures.py](tests/test_pyhocon_signatures.py) has every public name of pyhocon's modules, with the same parameters, and [test_pyhocon_compat.py](tests/test_pyhocon_compat.py) reads documents with both and compares the values, their types and the converter's output. Each difference by design is in them with its reason.

Values have pyhocon's types: `30s` is a `timedelta`, or with python-dateutil installed a `relativedelta`, as pyhocon makes it; months and years need dateutil there too. One difference: a quoted `"30s"` is a duration as well, where pyhocon keeps it text.

The measure is pyhocon's own test suite with the import swapped: 263 of its 308 tests pass. Of the 45 that do not, 44 are a config that reads differently by the spec (Step 3) or the class of a syntax error:

| tests | what pyhocon does |
|---|---|
| 12 | raises pyparsing's exceptions for a syntax error; here it is a `ConfigParseException` |
| 9 | flattens `x += [3, 4]` into `x`; by the spec it appends the list as one element |
| 6 | reads `-Xmx1g` unquoted; the spec does not let an unquoted string start with `-` |
| 6 | `include` inside a list, `include glob(…)` and `include package(…)`, its own extensions |
| 5 | resolves a self-reference typesafe/config refuses too: `x = ${x}` with `x` only in the environment, `x = [${x}, 2]`, an object that refers into itself |
| 3 | accepts `.54`, and a backslash escape in an unquoted string: `abc\"test`, `abc\n` |
| 2 | includes a file named without an extension; the spec tries `.conf`, `.json` and `.properties` after the name |
| 1 | reads `${?nope} 4` as the number 4; by the spec it is the text `" 4"` |

The one left is `ConfigTree.resolve()`, which is not there. Nor are a few things pyhocon has inside its parser:

- **A value with a `${…}` is no `ConfigValues`.** A document read with `resolve=False` has its values where it resolves on its own; where it does not, it has none until `with_fallback()` or `ConfigParser.resolve_substitutions()` gives it what it waits for, and reading it before is a `ConfigSubstitutionException`.
- **`unresolved_value`** takes `DEFAULT_SUBSTITUTION`, `MANDATORY_SUBSTITUTION` and `NO_SUBSTITUTION`; `STR_SUBSTITUTION` and a value of your own are a `NotImplementedError`.
- **`parse_URL`** reads a document with no `include` in it: one is an error, as it has no directory to be found in.

The whole document is in Python, as in pyhocon, so it is a little slower than `zig_hocon`, still far from pyhocon: a 5 KB config in 0.3 ms (pyhocon 29 ms), 10 MB in 0.38 s (pyhocon 68 s), against 0.2 ms and 0.13 s for `zig_hocon`.

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

- **Durations and sizes are text until something asks** (not in `zig_hocon.pyhocon`, which has pyhocon's `timedelta`). pyhocon turns `30s` into a `timedelta` while it parses; here `as_dict()` has `"30s"`, and `get_duration` or the model converts it. With pydantic, a `BeforeValidator(zig_hocon.parse_duration)` on the field; [examples/durations-and-sizes](examples/durations-and-sizes) has it for pydantic and msgspec.
- **A concatenation is a string.** `a = ${?nope}42` is `"42"` by the spec; pyhocon gives the number `42`. A model that wants an int converts it.
- **An `include url(…)` gives up after 30 s.** pyhocon waits as long as `socket.setdefaulttimeout` says, by default for ever. Here `http_timeout=` on `parse_file` and `parse_string` sets it, and a server that does not answer in time is a `ConfigParseException` named `IncludeTimeout`.
- **A leading zero keeps the text.** A value that begins with a digit begins with the number JSON reads there, and the rest is text, so `zip = 01234` is `"01234"` by the spec; pyhocon gives the number 1234. An IP address, a version or a UUID is text as written, as in pyhocon. So is a value that begins with `-` and no number, `-foo` or `-Xmx2g`, and a fraction JSON has no number for: `.5` and `-.5` are the text `".5"` and `"-.5"`, where pyhocon gives 0.5 and -0.5. Text becomes a number only by the JSON rules, so `get_int("zip")` on `01234` and `get_float` on `-.5` raise `ConfigWrongTypeException`, where pyhocon gives 1234 and -0.5: write `zip = "01234"` and read it with `get_string`, or `-0.5`.
- **`+=` appends one element.** `x += [3, 4]` after `x = [1, 2]` is `[1, 2, [3, 4]]`, as `x = ${?x} [[3, 4]]` is; pyhocon gives `[1, 2, 3, 4]`. To extend a list with another, `x = ${x} [3, 4]`.
- **Strict syntax.** The other inputs in the table under *No silent guesses* are errors now. They are rare, and each error says where to look.

Everything else (variables, includes, merging) reads the same, except where pyhocon breaks the spec; the conformance report lists those cases.

## Checklist

With `zig_hocon.pyhocon`, only Step 3 applies. With `zig_hocon`, run this over the code that uses pyhocon; each hit is a row in Step 2 or 3:

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
