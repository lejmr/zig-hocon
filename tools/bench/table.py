"""Renders the .tsv files tools/bench/run.sh leaves in <dir> as a markdown table.

    python3 table.py zig-out/bench
"""
import os
import sys

out = sys.argv[1]


def load(name):
    rows = {}
    for line in open(os.path.join(out, name + ".tsv")):
        path, ns, _runs = line.rstrip("\n").split("\t")
        rows[path] = None if ns == "skipped" else int(ns)
    return rows


def size(n):
    return "{:.0f} MB".format(n / 1e6) if n >= 1e6 else "{:.0f} KB".format(n / 1e3)


def cell(ns, n):
    if ns is None:
        return "skipped"
    ms = ns / 1e6
    t = ("{:.3f} ms" if ms < 1 else "{:.1f} ms").format(ms) if ms < 1000 else "{:.1f} s".format(ms / 1000)
    rate = n / (ns / 1e9)
    r = "{:.0f} MB/s".format(rate / 1e6) if rate >= 1e6 else "{:.0f} KB/s".format(rate / 1e3)
    return "{} · {}".format(t, r)


z, j, p = load("zig"), load("java"), load("py")
print("| file | zig-hocon | typesafe/config | pyhocon |")
print("|---|---|---|---|")
for path in z:
    n = os.path.getsize(path)
    print("| {} | {} | {} | {} |".format(size(n), cell(z[path], n), cell(j.get(path), n), cell(p.get(path), n)))
