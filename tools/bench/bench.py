"""Python side of tools/bench/run.sh: time to parse each file, per library.

    python bench.py <lib> <file>...
    python bench.py <lib> --json <file>

<lib> is one of LIBS. Prints `<file>\t<median ns>\t<runs>\t<first ns>` per file:
the first run on its own, then runs until a second has passed and at least
three are in. A first run over 10 s is reported alone rather than repeated.
A run is the library's parse_string on text already in memory, resolved, into
the library's own tree, the way a user calls it.

--json prints what the library makes of the file as compact JSON, through its
file API so includes resolve beside the file: the output run.sh compares
before timing, and a conformance adapter (conformance/run.sh -- python
bench.py <lib> --json).
"""
import json
import os
import statistics
import sys
import time


def pyhocon():
    from pyhocon import ConfigFactory, HOCONConverter
    to_json = lambda c: json.loads(HOCONConverter.to_json(c))
    return ConfigFactory.parse_string, ConfigFactory.parse_file, to_json


def pulse():
    # the default route: native Rust parser, pyhocon where it says unsupported
    import pulse_pyhocon
    from pyhocon import HOCONConverter
    to_json = lambda c: json.loads(HOCONConverter.to_json(c))
    return pulse_pyhocon.parse_string, pulse_pyhocon.parse_file, to_json


def py_hocon():
    import hocon
    return hocon.parse, hocon.parse_file, lambda c: c.to_object()


def hocon2():
    # also imports as `hocon`, so it has an environment of its own
    import hocon
    from collections import UserString

    def plain(v):
        # its quoted and unquoted strings reach the resolved tree as UserString
        if isinstance(v, dict):
            return {str(k): plain(x) for k, x in v.items()}
        if isinstance(v, list):
            return [plain(x) for x in v]
        return str(v) if isinstance(v, UserString) else v

    def parse_file(path):
        with open(path, encoding="utf-8") as f:
            return hocon.load(f)
    return hocon.loads, parse_file, plain


def zig_hocon():
    # the package from this checkout, with the libhocon `zig build python` put in it
    sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "python"))
    from zig_hocon import ConfigFactory
    return ConfigFactory.parse_string, ConfigFactory.parse_file, lambda c: json.loads(c.to_json())


LIBS = {"pyhocon": pyhocon, "pulse-pyhocon": pulse, "py.hocon": py_hocon, "hocon2": hocon2,
        "zig-hocon-python": zig_hocon}

parse_string, parse_file, to_json = LIBS[sys.argv[1]]()

if sys.argv[2] == "--json":
    print(json.dumps(to_json(parse_file(sys.argv[3])), separators=(",", ":")))
    sys.exit()

for path in sys.argv[2:]:
    text = open(path).read()
    times = []
    while len(times) < 3 or sum(times) < 1e9:
        start = time.perf_counter_ns()
        parse_string(text)
        times.append(time.perf_counter_ns() - start)
        if times[0] > 10e9:
            break
    print("{}\t{}\t{}\t{}".format(path, int(statistics.median(times)), len(times), times[0]), flush=True)
