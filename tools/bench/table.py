"""Renders what tools/bench/run.sh leaves in <dir> as markdown tables.

    python3 table.py zig-out/bench

Two tables. Parse: time to parse text already in memory, inside the process,
first run on its own (cold: nothing warmed up, no JIT) and the median after
warming up (warm). End to end: the whole command from process start to exit.
An implementation whose files are missing is left out.
"""
import os
import sys

out = sys.argv[1]
IMPLS = [("zig", "zig-hocon"), ("hocon-rs", "hocon-rs"), ("hocon", "hocon (Rust)"),
         ("java", "typesafe/config"), ("py", "pyhocon")]


def load(name):
    """path → (median ns, first ns), None where skipped."""
    rows = {}
    try:
        lines = open(os.path.join(out, name + ".tsv")).read().splitlines()
    except FileNotFoundError:
        return None
    for line in lines:
        f = line.split("\t")
        num = lambda x: None if x == "skipped" else int(x)
        rows[f[0]] = (num(f[1]), num(f[3]) if len(f) > 3 else None)
    return rows


def size(n):
    return "{:.0f} MB".format(n / 1e6) if n >= 1e6 else "{:.0f} KB".format(n / 1e3)


def ms(ns):
    if ns is None:
        return "—"
    m = ns / 1e6
    return "{:.3f} ms".format(m) if m < 1 else "{:.1f} ms".format(m) if m < 1000 else "{:.1f} s".format(m / 1000)


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
