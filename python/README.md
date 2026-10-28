<img src="https://raw.githubusercontent.com/lejmr/zig-hocon/main/docs/brand/zig-Hocon-badge-master-1650x500.png" width="600" alt="zig-hocon">

Read [HOCON](https://github.com/lightbend/config/blob/main/HOCON.md) config files in Python, to the spec. Fast, because the parser is written in Zig. Familiar, because the API is pyhocon's.

HOCON is JSON made for people: comments, no quotes needed, units like `30s` and `512MiB`, files that include other files, later settings that merge over earlier ones, and values taken from other keys or from environment variables. One base file, one small file per environment on top.

```hocon
# app.conf
db {
  host = localhost
  pool = 4
}
timeout = 30s
cache = 512MiB
retention = 3 months
debug = false
ratio = 0.75
include "prod.conf"
```

```hocon
# prod.conf
db.host = db.example.org
db.pool = ${?DB_POOL}   # only when DB_POOL is set
```

```python
from zig_hocon import ConfigFactory

conf = ConfigFactory.parse_file("app.conf")
conf.get_string("db.host")   # "db.example.org"
conf.get_int("db.pool")      # 4, or $DB_POOL when it is set
```

The rest of this page reads these two files.

## Why zig-hocon

- **Correct.** Passes all 586 tests in the [conformance suite](https://htmlpreview.github.io/?https://github.com/lejmr/zig-hocon/blob/main/conformance/report.html), one test for each sentence of the spec.
- **Fast.** Orders of magnitude faster than what Python usually has.\*
- **Clear errors.** File, line, column, and a caret under the mistake.
- **No dependencies.** A thin ctypes layer over one bundled library.

\* A 6 KB config in 1 ms, a 10 MB one in 0.3 s, on an Apple M4 Pro.

## Install

```sh
pip install zig-hocon
```

One wheel per platform, for every Python from 3.10 on, free-threaded builds and PyPy included: macOS (arm64, x86_64), Linux (x86_64, aarch64; glibc 2.17+ and musl) and Windows (x86_64). The import name is `zig_hocon`. Anywhere else, build it from source (below).

Beta: the API can still change before 1.0. BSD-3-Clause.

## Use

```python
from zig_hocon import ConfigFactory, KEEP

conf = ConfigFactory.parse_file("app.conf")                       # DB_POOL from os.environ
conf = ConfigFactory.parse_file("app.conf", env={"DB_POOL": "8"}) # from a dict
conf = ConfigFactory.parse_file("app.conf", env=None)             # no variables: pool stays 4
conf = ConfigFactory.parse_file("app.conf", env=KEEP)             # ${?DB_POOL} kept, for later
conf = ConfigFactory.parse_file("app.conf", resolve=False)        # every ${…} as written
conf = ConfigFactory.parse_file("app.conf", http_timeout=5)       # an http(s) include waits 5 s, not 30
conf = ConfigFactory.parse_string('include "app.conf"', basedir=".")  # text, includes from basedir

conf.get_string("db.host")      # "db.example.org"
conf.get_int("db.pool")         # 4
conf.get_float("ratio")         # 0.75
conf.get_bool("debug")          # False: true/yes/on, false/no/off
conf.get_duration("timeout")    # timedelta(seconds=30)
conf.get_bytes("cache")         # 536870912: "512MB" counts by 1000, "512MiB" by 1024
conf.get_period("retention")    # {"years": 0, "months": 3, "days": 0}: a timedelta has no months
conf.get_config("db")           # the object at db, read the same way
conf.get_int("db.size", default=10)  # 10: nothing at db.size

conf.as_dict()                  # plain dicts and lists
conf.to_json()                  # bytes, not str: for msgspec.json.decode
conf.to_hocon()                 # HOCON text
```

A path is written as in the file: `db.host`, `a."b.c"`. A getter's default is its second argument, as in pyhocon; `parse_file` and `parse_string` take everything after the path by keyword. The package is typed (`py.typed`): `get_int("a")` is an `int`, `get_int("a", None)` an `int | None`. One document can be read from many threads at once.

**Errors** are `ConfigException`s, with `name`, `file`, `line`, `column` and `source_line`:

| exception | when |
|---|---|
| `ConfigParseException` | the text is not valid HOCON, or an include fails |
| `ConfigSubstitutionException` | a `${…}` with no value, or a cycle |
| `ConfigMissingException` (also a `KeyError`) | nothing at the path, or `null` |
| `ConfigWrongTypeException` (also a `ValueError`) | the value is not what the getter wants |

**One file to deploy.** `env=KEEP` resolves includes, overrides and references between keys, and leaves the environment variables in; `to_hocon()` writes the result, to be read on the server with its own environment:

```python
from pathlib import Path

Path("deploy.conf").write_text(ConfigFactory.parse_file("app.conf", env=KEEP).to_hocon())
```

**Durations and sizes** have helpers with the same rules as the getters: `zig_hocon.parse_duration("30s")` gives a `timedelta`, `zig_hocon.parse_bytes("512MiB")` an int.

**From the shell**, `hocon [--json] [--env=process|none|keep] app.conf` (pip installs the command; `python -m zig_hocon` is the same) prints the file resolved.

## Coming from pyhocon

Code that reads through `ConfigFactory` and the typed getters changes its import: those and the exception names are the same. `get`, `get_list`, `with_fallback`, `put` and dict access are not there; MIGRATING.md has what does their job. What reads differently:

- **The tree is not a dict.** `conf["db"]["host"]` and `json.dumps(conf)` fail; take `conf.as_dict()` first. `as_plain_ordered_dict()` is `as_dict()`.
- **Fewer methods.** `get`, `get_list`, `with_fallback` and `put` are not there: a typed getter, an `include`, or the dict does the job.
- **Durations stay text.** `30s` is `"30s"` in `as_dict()` until a getter or a model reads it.
- **`+=` appends one element.** `x += [a]`, the form pyhocon takes, adds the list `[a]` as one element; `x = ${x} [a]` extends it.
- **Strict syntax.** Input pyhocon quietly accepted, such as `a..b = 1` or `a = b:c`, is an error with its line and column.
- **No `include package(...)`.** It is pyhocon's own; include by path.

To see what would change in your own configs, read them with both: with pyhocon installed beside zig-hocon 0.6.0 or later (`pip install -U zig-hocon`; an older one answers `migrate` with `unrecognized arguments`),

```sh
hocon migrate conf/ --env-file prod.env --fallback reference.conf
```

reads every config in `conf/` with each, with the same environment (and over `reference.conf`, as `conf.with_fallback(reference)` in your loader), and shows where they differ as the config's tree: `≈` another type that a getter reads the same, `≠` another value, `!` one of them fails. It exits 1 when anything differs, so it can wait in CI for the day it is green; once you rewrite the configs for zig-hocon, `--before main` has pyhocon read them as they are on `main`, against the new ones on zig-hocon. [MIGRATING.md](MIGRATING.md#checklist) has the flags for a loader, an environment per deployment and reviewed differences.

The [migration guide](https://github.com/lejmr/zig-hocon/blob/main/python/MIGRATING.md) has every difference, with what to write instead.

## Into a model

The package hands over a dict (`as_dict()`) or JSON bytes (`to_json()`); a model library does the checking. The same `app.conf` into the three usual ones.

**pydantic** reads the dict. A duration is text in the file, `"30s"`, so a `BeforeValidator` turns it into a `timedelta` first:

```python
from datetime import timedelta
from typing import Annotated

import zig_hocon
from pydantic import BaseModel, BeforeValidator

Duration = Annotated[timedelta, BeforeValidator(zig_hocon.parse_duration)]

class Db(BaseModel):
    host: str
    pool: int

class Settings(BaseModel):
    db: Db
    timeout: Duration
    debug: bool

conf = zig_hocon.ConfigFactory.parse_file("app.conf")
settings = Settings.model_validate(conf.as_dict())
```

**msgspec** decodes the JSON bytes straight into a Struct. It reads a `timedelta` itself only from ISO 8601 (`"PT30S"`), so the field gets a type of its own that msgspec hands to `dec_hook`. An environment variable is always a string, so `strict=False` lets `DB_POOL=16` into the `int`:

```python
from datetime import timedelta

import msgspec
import zig_hocon

class Duration(timedelta):
    pass

def dec_hook(type, value):
    if type is Duration:
        d = zig_hocon.parse_duration(value)
        return Duration(d.days, d.seconds, d.microseconds)
    raise NotImplementedError(type)

class Db(msgspec.Struct):
    host: str
    pool: int

class Settings(msgspec.Struct):
    db: Db
    timeout: Duration
    debug: bool

conf = zig_hocon.ConfigFactory.parse_file("app.conf")
settings = msgspec.json.decode(conf.to_json(), type=Settings, dec_hook=dec_hook, strict=False)
```

**`@dataclass`** converts no types and does not build `Db` from a dict, so msgspec builds it, with the `Duration`, `dec_hook` and `conf` from above:

```python
from dataclasses import dataclass

@dataclass
class Db:
    host: str
    pool: int

@dataclass
class Settings:
    db: Db
    timeout: Duration
    debug: bool

settings = msgspec.json.decode(conf.to_json(), type=Settings, dec_hook=dec_hook, strict=False)
```

All three give `settings.db.host == "db.example.org"` and `settings.timeout == timedelta(seconds=30)`, and fail with the model's own error, path included, on a value of the wrong type. A size works the same way through `zig_hocon.parse_bytes`. The [examples](https://github.com/lejmr/zig-hocon/tree/main/python/examples) have these as tests, with layered environments, errors and one-file deploys.

## Building from source

```sh
zig build python -Doptimize=ReleaseSafe   # libhocon into python/zig_hocon/
pip install python/
zig build test-python                     # the package's tests, with uv
zig build wheels                          # a wheel for every platform, into zig-out/wheels/
```

Needs Zig 0.16. Source, issues and the Zig and C libraries: [github.com/lejmr/zig-hocon](https://github.com/lejmr/zig-hocon). BSD-3-Clause.
