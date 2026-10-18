"""Renders what tools/bench/run.sh leaves in <dir> as markdown tables.

    python3 table.py zig-out/bench
    python3 table.py --landscape zig-out/bench-refs zig-out/landscape

Two tables. Parse: time to parse text already in memory, inside the process,
first run on its own (cold: nothing warmed up, no JIT) and the median after
warming up (warm). End to end: the whole command from process start to exit.
An implementation whose files are missing is left out.

--landscape: the table for python/BENCHMARK.md instead, one row per
implementation with its spec score from <spec-dir>/<name>.spec.json (what
tools/bench/landscape.sh writes) and its warm parse times: the Python
libraries, the best Rust crate, and zig-hocon and typesafe/config as
references.
"""
import json
import os
import sys

# key, label, language / binding, note
PYTHON = [
    ("zig-hocon-python", "zig-hocon", "Zig, ctypes over libhocon", "the tree stays in Zig and is read on access"),
    ("pulse-pyhocon", "pulse-pyhocon", "Rust (PyO3), pyhocon fallback", "native parser on these files; pyhocon on anything it does not support"),
    ("py.hocon", "py.hocon (hocon-parser)", "pure Python", ""),
    ("hocon2", "hocon2", "pure Python", "quadratic in file size"),
    ("pyhocon", "pyhocon", "pure Python (pyparsing)", ""),
]
REFERENCE = [
    ("zig", "zig-hocon, native", "Zig", "reference: the same core without Python"),
    ("java", "typesafe/config", "Java", "reference implementation; JIT warmed up for 2 s"),
]
RUST = [
    ("rs.hocon", "rs.hocon (hocon-parser)", "Rust, no Python binding yet", "timed natively; same author and version as py.hocon"),
    ("hocon-rs", "hocon-rs", "Rust", ""),
    ("hocon", "hocon", "Rust", "strict mode; quadratic in file size"),
]
MARKS = {"skipped": "—", "timeout": "> 120 s", "wrong": "wrong output", "error": "error"}

landscape = sys.argv[1] == "--landscape"
out = sys.argv[2] if landscape else sys.argv[1]


def load(name):
    """path → (median, first): ns as int, or a mark from MARKS."""
    rows = {}
    try:
        lines = open(os.path.join(out, name + ".tsv")).read().splitlines()
    except FileNotFoundError:
        return None
    for line in lines:
        f = line.split("\t")
        num = lambda x: x if x in MARKS else int(x)
        rows[f[0]] = (num(f[1]), num(f[3]) if len(f) > 3 else None)
    return rows


def size(n):
    return "{:.0f} MB".format(n / 1e6) if n >= 1e6 else "{:.0f} KB".format(n / 1e3)


def ms(ns):
    if ns is None:
        return "—"
    if ns in MARKS:
        return MARKS[ns]
    m = ns / 1e6
    return "{:.3f} ms".format(m) if m < 1 else "{:.1f} ms".format(m) if m < 1000 else "{:.1f} s".format(m / 1000)


if landscape:
    spec_dir = sys.argv[3]
    impls = [(k, l, b, n, load(k)) for k, l, b, n in PYTHON + RUST[:1] + REFERENCE]
    impls = [i for i in impls if i[4]]
    files = list(impls[0][4])
    print("| implementation | language / binding | version | spec | "
          + " | ".join(size(os.path.getsize(f)) for f in files) + " | notes |")
    print("|---|---|---|---:|" + "---:|" * len(files) + "---|")
    for key, label, binding, note, rows in impls:
        spec = json.load(open(os.path.join(spec_dir, key + ".spec.json")))
        print("| {} | {} | {} | {}/{} ({:.1f} %) | {} | {} |".format(
            label, binding, spec["version"].split()[-1], spec["passed"], spec["total"], spec["percent"],
            " | ".join(ms(rows.get(f, (None,))[0]) for f in files), note))
    sys.exit()

IMPLS = [(k, l) for k, l, *_ in REFERENCE[:1] + PYTHON + RUST + REFERENCE[1:]]
parse = [(label, load(key)) for key, label in IMPLS]
parse = [(label, rows) for label, rows in parse if rows]
files = list(parse[0][1])

print("**Parse** — in-process, cold = first run, warm = median after warm-up\n")
print("| file | " + " | ".join("{} cold | {} warm".format(l, l) for l, _ in parse) + " |")
print("|---|" + "---:|---:|" * len(parse))
for f in files:
    cells = []
    for _, rows in parse:
        median, first = rows.get(f, (None, None))
        cells += [ms(first), ms(median)]
    print("| {} | {} |".format(size(os.path.getsize(f)), " | ".join(cells)))

e2e = [(label, load("e2e-" + key)) for key, label in IMPLS]
e2e = [(label, rows) for label, rows in e2e if rows]
if e2e:
    print("\n**End to end** — the command, process start to exit, JSON written\n")
    print("| file | " + " | ".join(l for l, _ in e2e) + " |")
    print("|---|" + "---:|" * len(e2e))
    for f in files:
        print("| {} | {} |".format(size(os.path.getsize(f)),
                                   " | ".join(ms(rows.get(f, (None,))[0]) for _, rows in e2e)))
