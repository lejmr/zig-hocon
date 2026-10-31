<img src="https://raw.githubusercontent.com/lejmr/zig-hocon/main/docs/brand/zig-Hocon-badge-master-1650x500.png" width="600" alt="zig-hocon">

Read [HOCON](https://github.com/lightbend/config/blob/main/HOCON.md) config files in Python, to the spec. An alternative to pyhocon that follows the spec, with a check that shows what changes for your configs when you switch.

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
```

```hocon
# prod.conf
include required("app.conf")
db.host = db.example.org
db.pool = ${?DB_POOL}   # only when DB_POOL is set
```

```python
from zig_hocon import ConfigFactory

conf = ConfigFactory.parse_file("prod.conf")
conf.get_string("db.host")   # "db.example.org"
conf.get_int("db.pool")      # 4, or $DB_POOL when it is set
```

## Why

- **To the spec.** It passes every case of a [conformance suite](https://github.com/lejmr/zig-hocon/blob/main/conformance/README.md) built from the sentences of the HOCON spec, where pyhocon reads `a = true foo` as `"Truefoo"` and `a += b` as `" b"`. [How the Python libraries score](https://github.com/lejmr/zig-hocon/blob/main/python/BENCHMARK.md).
- **Fast.** A 1 KB config with substitutions loads in 0.09 ms, where pyhocon takes 8 ms ([BENCHMARK.md](https://github.com/lejmr/zig-hocon/blob/main/python/BENCHMARK.md)).
- **Clear errors.** File, line, column, and a caret under the mistake.
- **No dependencies.** A thin ctypes layer over one bundled library, written in Zig.

## Install

```sh
pip install zig-hocon
```

One wheel per platform, for every Python from 3.10 on, free-threaded builds and PyPy included: macOS (arm64, x86_64), Linux (x86_64, aarch64; glibc 2.17+ and musl) and Windows (x86_64). The import name is `zig_hocon`. It also puts two commands on the path: `zig-hocon-migrate` ([Coming from pyhocon](#coming-from-pyhocon)) and `hocon` ([Command line](#command-line)).

Beta: the API can change before 1.0.

## Use

```python
from zig_hocon import ConfigFactory, KEEP

conf = ConfigFactory.parse_file("prod.conf")                       # DB_POOL from os.environ
conf = ConfigFactory.parse_file("prod.conf", env={"DB_POOL": "8"}) # from a dict
conf = ConfigFactory.parse_file("prod.conf", env=None)             # no variables: pool stays 4
conf = ConfigFactory.parse_file("prod.conf", http_timeout=5)       # an http(s) include waits 5 s, not 30
conf = ConfigFactory.parse_string('include "prod.conf"', basedir=".")  # text, includes from basedir

conf.get_string("db.host")      # "db.example.org"
conf.get_int("db.pool")         # 4, or $DB_POOL
conf.get_float("ratio")         # 0.75
conf.get_bool("debug")          # False: true/yes/on, false/no/off
conf.get_duration("timeout")    # timedelta(seconds=30)
conf.get_bytes("cache")         # 536870912: "512MB" counts by 1000, "512MiB" by 1024
conf.get_period("retention")    # Period(years=0, months=3, days=0): a timedelta has no months
conf.get_config("db")           # the object at db, read the same way
conf.get_int("db.size", default=10)  # 10: nothing at db.size

conf.as_dict()                  # plain dicts and lists
conf.to_json()                  # bytes, for msgspec.json.decode
```

A path is written as in the file: `db.host`, `a."b.c"`. The package is typed (`py.typed`): `get_int("a")` is an `int`, `get_int("a", None)` an `int | None`. One document can be read from many threads at once.

### Errors

Every error is a `ConfigException`, with `name`, `file`, `line`, `column` and `source_line`:

| exception | when |
|---|---|
| `ConfigParseException` | the text is not valid HOCON, or an include fails |
| `ConfigSubstitutionException` | a `${…}` with no value, or a cycle |
| `ConfigMissingException` (also a `KeyError`) | nothing at the path, or `null` |
| `ConfigWrongTypeException` (also a `ValueError`) | the value is not what the getter wants |

### One file to deploy

`env=KEEP` resolves includes and overrides and leaves the environment variables in, for the machine the file is deployed to:

```python
from pathlib import Path

Path("deploy.conf").write_text(ConfigFactory.parse_file("prod.conf", env=KEEP).to_hocon())
```

## Coming from pyhocon

Moving over is a rewrite of the code that works with the tree, not a change of import. What carries over: `ConfigFactory.parse_file` and `parse_string`, the typed getters (`get_string`, `get_int`, `get_float`, `get_bool`, `get_config`) and the exception names. What does not:

- **The tree is not a dict**, and `get`, `get_list`, `with_fallback` and `put` are not there: a typed getter, `conf.as_dict()` or an include does the job.
- **A list has no getters.** Read it through your model (`list[str]`), which checks the type as `get_list` did.
- **Durations stay text.** `30s` is `"30s"` in `as_dict()` until a getter or a model reads it.
- **`+=` appends one element.** `x += [a]`, the form pyhocon takes, adds the list `[a]` as one element; `x = ${x} [a]` extends it.
- **Values from the environment are text**, read as numbers and booleans only as written: `08` or a capitalised `True` makes `get_int` and `get_bool` raise `ConfigWrongTypeException`. Check your secret store first.
- **Strict syntax**, and no `include package(...)`.

`zig-hocon-migrate` reads your configs with pyhocon and with zig-hocon and shows what differs:

```sh
zig-hocon-migrate conf/prod.conf --env-file env/prod.env
```

[MIGRATING.md](https://github.com/lejmr/zig-hocon/blob/main/python/MIGRATING.md) has every difference, what to write instead, and how to run the check for each deployment in CI.

## Into a model

The package hands over a dict (`as_dict()`) or JSON bytes (`to_json()`), and a model library does the checking. With pydantic, a duration is text in the file, so a `BeforeValidator` turns it into a `timedelta`:

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

settings = Settings.model_validate(zig_hocon.ConfigFactory.parse_file("prod.conf").as_dict())
```

`zig_hocon.parse_bytes` and `parse_period` do the same for sizes and periods. The [examples](https://github.com/lejmr/zig-hocon/tree/main/python/examples) do it with msgspec and dataclasses too, as tests, with layered environments, errors and one-file deploys.

### Strict, as the Zig side reads it

A model's rules for a number or a boolean are not the library's, and a value from the environment is always text: `${DB_POOL}` with `08` in it is `"08"`.

| text | `get_int` / `get_bool`, a Zig struct | pydantic | msgspec, `strict=False` |
|---|---|---|---|
| `"08"`, `"+9000"`, `"9_000"`, `" 48"` | refused | 8, 9000, 9000, 48 | refused |
| `"True"`, `"1"` | refused | `True` | `True` |
| `"yes"`, `"on"` | `True` | `True` | refused |

`zig_hocon.parse_int` and `zig_hocon.parse_bool` read as `get_int` and `get_bool` do; as validators they make a model take exactly what the Zig side takes ([MIGRATING.md](https://github.com/lejmr/zig-hocon/blob/main/python/MIGRATING.md)).

## Command line

`hocon` prints a config resolved, writes one deployable file with the `${…}` left to resolve at run time, gets one value for a script, checks files in CI, and diffs two configs as they resolve: [docs/cli.md](https://github.com/lejmr/zig-hocon/blob/main/docs/cli.md). `python -m zig_hocon [--json] [--env=process|none|keep] prod.conf` prints a file resolved through the package.

## Building from source

```sh
zig build python -Doptimize=ReleaseSafe   # libhocon into python/zig_hocon/
pip install python/
zig build test-python                     # the package's tests, with uv
```

Needs Zig 0.16. Source, issues, and the Zig and C libraries: [github.com/lejmr/zig-hocon](https://github.com/lejmr/zig-hocon). BSD-3-Clause.
