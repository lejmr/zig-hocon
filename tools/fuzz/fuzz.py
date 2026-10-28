"""Fuzzing zig-hocon against typesafe/config, against the suite's neighbours and
against the spec's own equivalences.

    python3 tools/fuzz/fuzz.py gen    --seed 1 --batches 56 --out .scratch/fuzz/runs/gen-1
    python3 tools/fuzz/fuzz.py mutate --seed 1 --batches 56 --out .scratch/fuzz/runs/mut-1
    python3 tools/fuzz/fuzz.py json   --seed 1 --batches 14 --out .scratch/fuzz/runs/json-1
    python3 tools/fuzz/fuzz.py replay <id>     # print the files of one case

A case is a small tree of files, `main.conf` and what it includes, and its id
(`gen-1-3-17`: engine, seed, batch, index) rebuilds it exactly. Every batch is
one worker: it writes its cases to a temp dir, runs `hocon --json` on each and
then one typesafe/config process over all of them, so the JVM starts once per
batch. Both engines get the same environment, ENV below and nothing else that
varies.

Engines:
- gen: a generator weighted towards feature interactions. Each case is rendered
  twice, the second time through one equivalence the spec states (a.b = x is
  a { b = x }, = is :, the braces around the root, ...), so a single case
  checks zig against java and zig against itself.
- mutate: the suite's own inputs, mutated a few edits at a time.
- json: random JSON, which must parse to itself.

On every case that zig accepts, its HOCON export is parsed again by zig and by
java and must give the same JSON. A zig exit that is neither 0 nor 1, or a
run past TIMEOUT seconds, is a finding of its own.

With --no-java, java is not run, and only what zig shows on its own is a
finding: a crash, a hang, a broken equivalence, an export that reads back
otherwise. CI runs it so (.github/workflows/fuzz.yml), with --fail-on-crash:
exit 1 when zig crashed or hung.

Findings go to <out>/findings.jsonl, one per line, and counts to <out>/stats.json.
Comparison: key order never matters, numbers compare by value, errors compare
only as "rejected", never by class.
"""

import argparse
import json
import os
import pathlib
import random
import re
import shutil
import subprocess
import sys
import tempfile
from multiprocessing import Pool

ROOT = pathlib.Path(__file__).resolve().parents[2]
ZIG = os.environ.get("HOCON_BIN", str(ROOT / "zig-out" / "bin" / "hocon"))
JAVA = str(ROOT / "tools" / "oracle" / "hocon-java")
sys.path.insert(0, str(ROOT / "conformance" / "maintaining"))
import suite  # noqa: E402
TIMEOUT = 5

# ponytail: one fixed environment for the whole campaign, so java batches stay
# one process; a case that needs other values is a suite case, not a fuzz one
ENV = {"FZ_S": "hello world", "FZ_N": "42", "FZ_E": "", "FZ_D": "a.b", "FZ_Q": 'say "hi"'}


def environ():
    return {"PATH": os.environ["PATH"], "HOME": os.environ.get("HOME", "/"), "LANG": "en_US.UTF-8", **ENV}


# ---------------------------------------------------------------- engines

def run_zig(d, *args):
    """('ok', value) | ('err', ErrorName) | ('crash', detail) | ('hang', None).
    With --hocon the value is the text it printed."""
    try:
        p = subprocess.run([ZIG, *args, "main.conf"], cwd=d, capture_output=True, timeout=TIMEOUT, env=environ())
    except subprocess.TimeoutExpired:
        return ("hang", None)
    out, err = p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")
    if p.returncode == 0:
        if "--json" not in args:
            return ("ok", out)
        try:
            return ("ok", json.loads(out))
        except json.JSONDecodeError:
            return ("crash", "not JSON: " + out[:300])
    if p.returncode == 1:
        m = re.search(r"error: (\w+)", err)
        return ("err", m.group(1) if m else err.strip()[-200:])
    return ("crash", "exit {}: {}".format(p.returncode, err[-600:]))


def java_line(text):
    return "ERROR" if text is None else text


def parse_java(line):
    if line.startswith("ERROR"):
        return ("err", line[len("ERROR "):].split(":", 1)[0])
    try:
        return ("ok", json.loads(line))
    except json.JSONDecodeError:
        return ("err", "Unparsable")


def run_java(paths):
    """One JVM over many main.conf paths. A short answer re-runs them one by one."""
    lines = ["resolve:file:" + str(p) for p in paths]
    if not lines:
        return []
    try:
        p = subprocess.run([JAVA], input="\n".join(lines) + "\n", capture_output=True, timeout=600,
                           env=environ(), encoding="utf-8", errors="replace")
        out = p.stdout.splitlines()
    except subprocess.TimeoutExpired:
        out = []
    if len(out) == len(lines):
        return [parse_java(o) for o in out]
    if len(lines) == 1:
        return [("err", "OracleDied")]
    return [r for path in paths for r in run_java_one(path)]


def run_java_one(path):
    try:
        p = subprocess.run([JAVA], input="resolve:file:{}\n".format(path), capture_output=True, timeout=60,
                           env=environ(), encoding="utf-8", errors="replace")
        out = p.stdout.splitlines()
    except subprocess.TimeoutExpired:
        return [("err", "OracleHang")]
    return [parse_java(out[0]) if out else ("err", "OracleDied")]


def same(a, b):
    """Two outcomes agree: both rejected, or both the same value."""
    if a[0] == "ok" and b[0] == "ok":
        return a[1] == b[1]
    return a[0] == b[0] == "err"


def write_case(d, files):
    d.mkdir(parents=True, exist_ok=True)
    for name, text in files.items():
        (d / name).parent.mkdir(parents=True, exist_ok=True)
        (d / name).write_text(text)


# ---------------------------------------------------------------- generator

# A small key pool so fields collide: duplicates, merges, self-references.
KEYS = ["a", "a", "a", "b", "b", "c", "x", "y", '"a"', '"a.b"', '"q r"', "FZ_S", "FZ_N",
        "0", "1", '"0"', "true", "null", "10", "a-b", '""', "include1"]
ENV_PATHS = ["FZ_S", "FZ_N", "FZ_E", "FZ_D", "FZ_Q", "FZ_MISSING"]
SCALARS = [
    "1", "2", "10", "-3", "1.5", "1e3", "0", "100", "3.0",
    "true", "false", "null", "yes",
    "foo", "bar", "hello world", "foo.bar", "/usr/x", "a-b",
    '"q"', '"a b"', '""', '" sp "', '"1"', '"${a}"', '"true"', '"""tri"""', '"""x"y"""',
    "10 s", "5ms", "512K", "1 day", "5EB", "1ex", "10.0bar", "truefoo", "nullx", "1 2", "3.5 MB",
    '"""\nline\n"""', '"""a""""', '"\\n\\t"', '"\\u0041"', "{ 0 = x, 1 = y }", '{ "1" = b, "0" = a }',
    "1.0", "-0", "1E2", "0.5e-1", "include", "a\tb", "a\u00a0b", "x //c", "x #c", "1 . 2",
]
# ponytail: inputs the suite already records as java-lenient (01, -foo, 1.2.3,
# 1., -.33, 1e, UUIDs) are left out, or they drown every other divergence


class Gen:
    def __init__(self, r, files):
        self.r = r
        self.files = files
        self.defined = {}  # absolute path (tuple of segments) -> "obj" | "arr" | "str"

    def seg(self):
        return self.r.choice(KEYS)

    def segs(self, prefix):
        r = self.r
        n = r.choices([1, 2, 3], [6, 3, 1])[0]
        if prefix is not None:
            n = max(1, min(n, 3 - len(prefix)))
        elif self.r.random() < 0.7:
            n = 1
        return [self.seg() for _ in range(n)]

    def ref(self, here, want):
        """A path to refer to, mostly one already defined with the type wanted."""
        r = self.r
        # an ancestor of the field being written is a cycle, not a reference
        typed = [list(p) for p, t in self.defined.items() if want in (None, t)
                 and not (here is not None and tuple(here[:len(p)]) == p)]
        k = r.random()
        if here is not None and k < 0.2:
            return list(here), tuple(here) not in self.defined or r.random() < 0.3
        if typed and k < 0.8:
            return r.choice(typed), r.random() < 0.15
        if want in (None, "str") and k < 0.9:
            return [r.choice(ENV_PATHS)], r.random() < 0.3
        return [self.seg() for _ in range(r.randint(1, 2))], r.random() < 0.9

    def sub(self, here, want=None):
        p, opt = self.ref(here, want)
        return ("sub", p, opt)

    def scalar(self):
        return ("raw", self.r.choice(SCALARS))

    def obj(self, depth, here, n):
        return ("obj", self.fields(depth + 1, here, n), self.seps())

    def arr(self, depth):
        return ("arr", [self.value(depth + 1, None) for _ in range(self.r.randint(0, 3))], self.seps())

    def atom(self, depth, here):
        r = self.r
        k = r.choices(["scalar", "sub", "obj", "arr"], [3, 3, 2 if depth < 2 else 0, 2 if depth < 2 else 0])[0]
        if k == "scalar":
            return self.scalar()
        if k == "sub":
            return self.sub(here)
        if k == "obj":
            return self.obj(depth, here, r.randint(0, 3))
        return self.arr(depth)

    def value(self, depth, here):
        r = self.r
        if r.random() < 0.5:
            return self.atom(depth, here)
        # a concatenation, mostly of parts that can concatenate
        kind = r.choices(["str", "arr", "obj", "any"], [3, 2, 4, 1])[0]
        parts = []
        for _ in range(r.randint(2, 3)):
            lit = r.random() < 0.5
            if kind == "str":
                parts.append(self.scalar() if lit else self.sub(here, "str"))
            elif kind == "arr":
                parts.append(self.arr(depth) if lit or depth >= 2 else self.sub(here, "arr"))
            elif kind == "obj":
                parts.append(self.obj(depth, here, r.randint(0, 3)) if lit and depth < 2 else self.sub(here, "obj"))
            else:
                parts.append(self.atom(depth + 1, here))
        # no empty gap between two literals: 1 then 0 would be the number 01
        gaps = [r.choice([" ", " ", "  ", "\t", "\u00a0"] + ([""] if "sub" in (x[0], y[0]) else []))
                for x, y in zip(parts, parts[1:])]
        return ("cat", parts, gaps)

    def kind(self, v):
        t = v[0]
        if t == "cat":
            return self.kind(v[1][0])
        if t == "sub":
            return self.defined.get(tuple(v[1]), "str")
        return {"raw": "str", "obj": "obj", "arr": "arr"}[t]

    def seps(self):
        return self.r.choice(["\n", "\n", ", ", ",\n", "\n\n"])

    def fields(self, depth, prefix, n):
        """prefix: absolute path of the enclosing object, None inside a list."""
        r = self.r
        out = []
        for _ in range(n):
            if self.files and r.random() < 0.12:
                out.append(self.include())
                continue
            if prefix is not None and self.defined and r.random() < 0.3:
                # a path already in use: duplicates, merges, overrides
                segs = list(r.choice(list(self.defined)))
                if segs[:len(prefix)] == prefix and len(segs) > len(prefix):
                    segs = segs[len(prefix):]
                else:
                    segs = self.segs(prefix)
            else:
                segs = self.segs(prefix)
            here = None if prefix is None else prefix + segs
            op = r.choices(["=", ":", "+=", "{"], [5, 3, 1, 2])[0]
            if op == "{":
                val = self.obj(depth, here, r.randint(0, 3))
            elif op == "+=":
                val = self.atom(depth + 1, here) if r.random() < 0.7 else self.value(depth + 1, here)
            else:
                val = self.value(depth, here)
            if here is not None:
                kind = "arr" if op == "+=" else self.kind(val)
                if kind != "obj":  # what was under it is gone
                    for p in [p for p in self.defined if p[:len(here)] == tuple(here) and len(p) > len(here)]:
                        del self.defined[p]
                for j in range(len(prefix) + 1, len(here)):
                    self.defined[tuple(here[:j])] = "obj"
                self.defined[tuple(here)] = kind
            out.append(("f", segs, op, val))
        return out

    def include(self):
        r = self.r
        target = r.choice(list(self.files) + ["missing.conf", "f1"]) if self.files else "missing.conf"
        # ponytail: no file(), typesafe/config reads it against the JVM's working
        # directory and one JVM serves a whole batch
        form = r.choices(["plain", "required"], [4, 2])[0]
        return ("inc", form, target)

    def doc(self, n):
        return self.fields(0, [], n)


def gen_case(r):
    """files: {name: tree}, the trees are rendered later."""
    nfiles = r.choices([0, 1, 2, 3], [6, 2, 1, 1])[0]
    names = ["f{}.conf".format(i + 1) for i in range(nfiles)]
    trees = {}
    # a file includes only files after it: no include cycles
    for i in reversed(range(nfiles)):
        g = Gen(r, {n: None for n in names[i + 1:]})
        trees[names[i]] = g.doc(r.randint(1, 3))
    g = Gen(r, {n: None for n in names})
    trees["main.conf"] = g.doc(r.randint(1, 5))
    return trees


# ---------------------------------------------------------------- renderer

BASE = {"kv": None, "braces": False, "expand": False, "longplus": False, "split": False,
        "comments": False, "ws": False, "sep": None, "inline": False}
RELATIONS = {
    # name: (option changes, strict) — strict: any outcome must stay the same;
    # otherwise only an accepted original pins the variant
    "kv-equals": ({"kv": "="}, True),
    "kv-colon": ({"kv": ":"}, True),
    "root-braces": ({"braces": True}, True),
    "path-expanded": ({"expand": True}, True),
    "plus-equals-long": ({"longplus": True}, True),
    "concat-split": ({"split": True}, False),
    "comments": ({"comments": True}, True),
    "whitespace": ({"ws": True}, True),
    "sep-newline": ({"sep": "\n"}, True),
    "sep-comma": ({"sep": ", "}, True),
    "include-inlined": ({"inline": True}, True),
}


class Render:
    def __init__(self, r, o, trees):
        self.r, self.o, self.trees = r, o, trees

    def sep(self, s):
        o = self.o
        if o["sep"] is not None:
            s = o["sep"]
        if o["comments"] and self.r.random() < 0.5:
            s = (" # remark" if "\n" in s else ", // remark") + "\n" + ("  " if o["ws"] else "")
        return s

    def kv(self, op):
        k = self.o["kv"] if op in "=:" and self.o["kv"] else op
        if self.o["ws"]:
            return {"=": "   =\t", ":": " :  ", "+=": "  +=   "}[k]
        return {"=": " = ", ":": " : ", "+=": " += "}[k]

    def path(self, p):
        return ".".join(p)

    def val(self, v, prefix):
        t = v[0]
        if t == "raw":
            return v[1]
        if t == "sub":
            return "${" + ("?" if v[2] else "") + self.path(v[1]) + "}"
        if t == "obj":
            return "{" + self.items(v[1], prefix, v[2], inner=True) + "}"
        if t == "arr":
            s = self.sep(v[2])
            return "[" + s.join(self.val(x, None) for x in v[1]) + "]"
        out = self.val(v[1][0], prefix)
        for gap, part in zip(v[2], v[1][1:]):
            out += gap + self.val(part, prefix)
        return out

    def field(self, f, prefix):
        _, segs, op, val = f
        o = self.o
        here = None if prefix is None else prefix + segs
        if o["expand"] and len(segs) > 1:
            inner = ("f", segs[1:], op, val)
            return segs[0] + " { " + self.field(inner, None if prefix is None else prefix + segs[:1]) + " }"
        if op == "{":
            return self.path(segs) + (" " if not o["ws"] else "   ") + self.val(val, here)
        if op == "+=" and o["longplus"] and here is not None:
            return self.path(segs) + self.kv("=") + "${?" + self.path(here) + "} [" + self.val(val, here) + "]"
        if (o["split"] and op in "=:" and val[0] == "cat" and len(val[1]) == 2
                and val[1][0][0] == "sub" and val[1][1][0] == "obj"):
            return (self.path(segs) + self.kv(op) + self.val(val[1][0], here) + "\n"
                    + self.path(segs) + " " + self.val(val[1][1], here))
        return self.path(segs) + self.kv(op) + self.val(val, here)

    def items(self, items, prefix, sep, inner=False, file_root=False):
        parts = []
        for it in items:
            if it[0] == "inc":
                inlined = self.inline(it) if file_root else None
                parts.append(inlined if inlined is not None else self.include(it))
            else:
                parts.append(self.field(it, prefix))
        body = "".join(p + self.sep(sep) for p in parts)
        if inner:
            return " " + body if body else ""
        return body

    def include(self, it):
        _, form, target = it
        q = '"' + target + '"'
        return "include " + {"plain": q, "required": "required(" + q + ")", "file": "file(" + q + ")"}[form]

    def inline(self, it):
        """A root-level include of a file that exists, written out in place."""
        _, form, target = it
        if not self.o["inline"] or target not in self.trees:
            return None
        return self.items(self.trees[target], [], "\n", file_root=True).rstrip("\n, ") or " "

    def doc(self, items):
        body = self.items(items, [], "\n", file_root=True)
        if self.o["braces"]:
            return "{\n" + body + "}\n"
        return body


def render_all(trees, o, r):
    files = {}
    for name, items in trees.items():
        files[name] = Render(r, o, trees).doc(items)
    return files


# ---------------------------------------------------------------- mutator

TOKEN = re.compile(r'"""[\s\S]*?"""+|"(?:\\.|[^"\\\n])*"|\$\{\??[^}\n]*\}|\+=|//[^\n]*|#[^\n]*|[{}\[\],:=\n]|[ \t]+|[^\s{}\[\],:="#$]+|.')


def seeds():
    """Every suite input, as a file tree, with its key."""
    out = []
    for case, meta in zip(*suite.cases()[:2]):
        if meta.get("env"):
            continue  # ponytail: the campaign runs one fixed environment
        if suite.is_dir_case(case):
            d = case.parent
            files = {p.relative_to(d).as_posix(): p.read_text(errors="replace") for p in d.rglob("*")
                     if p.is_file() and p.suffix in (".conf", ".json", ".properties") and p.name != "main.json"}
        else:
            files = {"main.conf": case.read_text(errors="replace")}
        out.append((suite.key_of(case), files))
    return out


def mutate(r, files):
    files = dict(files)
    for _ in range(r.randint(1, 3)):
        name = r.choice(sorted(n for n in files if n.endswith(".conf")))
        files[name] = r.choice(MUTATIONS)(r, files[name], files)
    return files


def toks(text):
    return TOKEN.findall(text)


def words(t):
    return [i for i, x in enumerate(t) if x.strip() and x not in "{}[],:=\n" and not x.startswith(("#", "//"))]


def keys_of(text):
    return re.findall(r"^\s*([A-Za-z_][\w.-]*)\s*(?:[=:{]|\+=)", text, re.M) or ["a"]


def m_line_delete(r, s, files):
    ls = s.split("\n")
    if len(ls) > 1:
        del ls[r.randrange(len(ls))]
    return "\n".join(ls)


def m_line_dup(r, s, files):
    ls = s.split("\n")
    i = r.randrange(len(ls))
    ls.insert(r.randrange(len(ls) + 1), ls[i])
    return "\n".join(ls)


def m_line_swap(r, s, files):
    ls = s.split("\n")
    i, j = r.randrange(len(ls)), r.randrange(len(ls))
    ls[i], ls[j] = ls[j], ls[i]
    return "\n".join(ls)


def m_line_to_include(r, s, files):
    ls = s.split("\n")
    i = r.randrange(len(ls))
    n = "m{}.conf".format(len(files))
    files[n] = ls[i] + "\n"
    ls[i] = 'include "{}"'.format(n)
    return "\n".join(ls)


def m_value_to_sub(r, s, files):
    t = toks(s)
    w = words(t)
    if w:
        t[r.choice(w)] = "${" + ("?" if r.random() < 0.3 else "") + r.choice(keys_of(s)) + "}"
    return "".join(t)


def m_sub_to_value(r, s, files):
    t = toks(s)
    subs = [i for i, x in enumerate(t) if x.startswith("${")]
    if subs:
        t[r.choice(subs)] = r.choice(SCALARS + ["{ z = 1 }", "[ 9 ]"])
    return "".join(t)


def m_wrap(r, s, files):
    t = toks(s)
    w = words(t)
    if w:
        i = r.choice(w)
        t[i] = r.choice(["{ w = " + t[i] + " }", "[" + t[i] + "]", "[ " + t[i] + ", " + t[i] + " ]"])
    return "".join(t)


def m_concat(r, s, files):
    t = toks(s)
    w = words(t)
    if w:
        i = r.choice(w)
        other = r.choice([t[j] for j in w] + ["${" + r.choice(keys_of(s)) + "}", "{ m = 2 }", "[ 7 ]"])
        t[i] = t[i] + r.choice([" ", ""]) + other if r.random() < 0.5 else other + r.choice([" ", ""]) + t[i]
    return "".join(t)


def m_separator(r, s, files):
    t = toks(s)
    idx = [i for i, x in enumerate(t) if x in ("=", ":", "+=", "\n", ",")]
    if idx:
        i = r.choice(idx)
        t[i] = {"=": r.choice([":", "+=", " "]), ":": r.choice(["=", "+="]), "+=": "=",
                "\n": ",", ",": "\n"}[t[i]]
    return "".join(t)


def m_field_dup(r, s, files):
    k = r.choice(keys_of(s))
    extra = r.choice([k + " = " + r.choice(SCALARS), k + " { n = 1 }", k + " += 5", k + " = ${" + k + "}",
                      k + " = ${?" + k + "} [1]", k + " = null", k + ".z = 3"])
    ls = s.split("\n")
    ls.insert(r.randrange(len(ls) + 1), extra)
    return "\n".join(ls)


def m_token_delete(r, s, files):
    t = toks(s)
    if t:
        del t[r.randrange(len(t))]
    return "".join(t)


def m_token_dup(r, s, files):
    t = toks(s)
    if t:
        i = r.randrange(len(t))
        t.insert(i, t[i])
    return "".join(t)


MUTATIONS = [m_line_delete, m_line_dup, m_line_swap, m_line_to_include, m_value_to_sub, m_sub_to_value,
             m_wrap, m_concat, m_separator, m_field_dup, m_token_delete, m_token_dup]


# ---------------------------------------------------------------- json

def rand_json(r, depth=0):
    k = r.choices(["obj", "arr", "str", "num", "lit"], [3 if depth < 4 else 0, 2 if depth < 4 else 0, 3, 3, 1])[0]
    if k == "obj":
        return {r.choice(["a", "b", "c.d", "e f", "", "$x", "#", "//", "include", "true", "1", "a\\b", "é"]): rand_json(r, depth + 1)
                for _ in range(r.randint(0, 4))}
    if k == "arr":
        return [rand_json(r, depth + 1) for _ in range(r.randint(0, 4))]
    if k == "str":
        return r.choice(["", "x", "a b", "${a}", "\n\t", "\"q\"", "é€😀", "\\", "true", "1", "  ", "\u0000", "/*", "//"])
    if k == "num":
        return r.choice([0, 1, -1, 1.5, -0.0, 1e300, 12345678901234, 2.5e-3, 100.0])
    return r.choice([True, False, None])


def json_case(r):
    v = {k: rand_json(r, 1) for k in r.sample(["a", "b", "c", "d e"], r.randint(1, 3))}
    return {"main.conf": json.dumps(v, indent=r.choice([None, 1, 4]), ensure_ascii=r.random() < 0.5)}, v


# ---------------------------------------------------------------- batches

def build(engine, seed, batch, i):
    """The case with this id: (files, variants, expected). variants: [(relation, files)]."""
    r = random.Random("{}:{}:{}:{}".format(engine, seed, batch, i))
    if engine == "gen":
        trees = gen_case(r)
        files = render_all(trees, BASE, random.Random(r.random()))
        rel = r.choice(sorted(RELATIONS))
        if rel == "include-inlined" and len(trees) == 1:
            rel = "path-expanded"
        b = render_all(trees, dict(BASE, **RELATIONS[rel][0]), random.Random(r.random()))
        return files, ([(rel, b)] if b != files else []), None
    if engine == "mutate":
        key, files = r.choice(SEEDS)
        return mutate(r, files), [], None
    files, v = json_case(r)
    return files, [], v


# The findings that compare with java, left out with --no-java.
WITH_JAVA = {"diff", "json-java", "meta-java", "roundtrip-java"}


def run_batch(args):
    engine, seed, batch, n, no_java = args
    work = pathlib.Path(tempfile.mkdtemp(prefix="hocon-fuzz-"))
    findings, stats = [], {"cases": 0, "zig": 0, "java": 0, "zig_ok": 0, "java_ok": 0}
    try:
        jobs = []  # (case id, label, dir)
        meta = {}
        for i in range(n):
            cid = "{}-{}-{}-{}".format(engine, seed, batch, i)
            files, variants, expected = build(engine, seed, batch, i)
            d = work / str(i) / "a"
            write_case(d, files)
            jobs.append((cid, "a", d))
            for rel, vf in variants:
                vd = work / str(i) / "b"
                write_case(vd, vf)
                jobs.append((cid, "b", vd))
            meta[cid] = (files, variants, expected)
        zig = {}
        for cid, label, d in jobs:
            zig[cid, label] = run_zig(d, "--json")
        # zig's own export of every case it accepted, read again by both
        for cid, label, d in jobs:
            if label == "a" and zig[cid, label][0] == "ok":
                h = run_zig(d, "--hocon")
                if h[0] == "ok":
                    write_case(d.parent / "x", {"main.conf": h[1]})
                    zig[cid, "x"] = run_zig(d.parent / "x", "--json")
                else:
                    zig[cid, "x"] = h
        java_jobs = [(cid, label, d) for cid, label, d in jobs] + [
            (cid, "x", work / cid.rsplit("-", 1)[1] / "x") for cid, label, d in jobs if (cid, "x") in zig and zig[cid, "x"][0] != "crash" and (work / cid.rsplit("-", 1)[1] / "x").exists()]
        java_out = [("skip", None)] * len(java_jobs) if no_java else run_java([d / "main.conf" for _, _, d in java_jobs])
        jav = dict(zip([(c, l) for c, l, _ in java_jobs], java_out))
        stats["zig"] += len(zig)
        stats["java"] += 0 if no_java else len(jav)
        for cid, (files, variants, expected) in meta.items():
            stats["cases"] += 1
            za, ja = zig[cid, "a"], jav[cid, "a"]
            stats["zig_ok"] += za[0] == "ok"
            stats["java_ok"] += ja[0] == "ok"
            base = {"id": cid, "files": files}
            if za[0] in ("crash", "hang"):
                findings.append(dict(base, kind="zig-" + za[0], zig=za, java=ja))
                continue
            if expected is not None:
                if za != ("ok", expected):
                    findings.append(dict(base, kind="json-zig", zig=za, java=ja, expect=expected))
                if ja != ("ok", expected):
                    findings.append(dict(base, kind="json-java", zig=za, java=ja, expect=expected))
            elif not same(za, ja):
                findings.append(dict(base, kind="diff", zig=za, java=ja))
            for rel, vf in variants:
                zb, jb = zig[cid, "b"], jav[cid, "b"]
                if zb[0] in ("crash", "hang"):
                    findings.append(dict(base, kind="zig-" + zb[0], zig=zb, java=jb, variant=vf, relation=rel))
                strict = RELATIONS[rel][1]
                if (strict or za[0] == "ok") and not same(za, zb):
                    findings.append(dict(base, kind="meta-zig", relation=rel, variant=vf, zig=za, zig_b=zb, java=ja, java_b=jb))
                if (strict or ja[0] == "ok") and not same(ja, jb):
                    findings.append(dict(base, kind="meta-java", relation=rel, variant=vf, zig=za, zig_b=zb, java=ja, java_b=jb))
            if (cid, "x") in zig:
                zx = zig[cid, "x"]
                export = (work / cid.rsplit("-", 1)[1] / "x" / "main.conf")
                text = export.read_text() if export.exists() else None
                if not same(za, zx):
                    findings.append(dict(base, kind="roundtrip-zig", zig=za, zig_x=zx, export=text))
                if (cid, "x") in jav and not same(za, jav[cid, "x"]):
                    findings.append(dict(base, kind="roundtrip-java", zig=za, java_x=jav[cid, "x"], export=text))
    finally:
        shutil.rmtree(work, ignore_errors=True)
    if no_java:
        findings = [x for x in findings if x["kind"] not in WITH_JAVA]
    return findings, stats


SEEDS = []


def init_worker():
    global SEEDS
    SEEDS = seeds()


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("engine", choices=["gen", "mutate", "json", "replay"])
    ap.add_argument("id", nargs="?")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--batches", type=int, default=14)
    ap.add_argument("--size", type=int, default=300)
    ap.add_argument("--jobs", type=int, default=os.cpu_count())
    ap.add_argument("--out")
    ap.add_argument("--no-java", action="store_true", help="zig alone: crashes, hangs, its own equivalences and exports")
    ap.add_argument("--fail-on-crash", action="store_true", help="exit 1 when zig crashed or hung")
    a = ap.parse_args(argv)
    if a.engine == "replay":
        init_worker()
        engine, seed, batch, i = a.id.rsplit("-", 3)
        files, variants, _ = build(engine, int(seed), int(batch), int(i))
        print(json.dumps({"files": files, "variants": variants}, indent=1, ensure_ascii=False))
        return 0
    out = pathlib.Path(a.out or ROOT / ".scratch" / "fuzz" / "runs" / "{}-{}".format(a.engine, a.seed))
    out.mkdir(parents=True, exist_ok=True)
    total = {}
    n = 0
    with Pool(a.jobs, initializer=init_worker) as pool, open(out / "findings.jsonl", "w") as f:
        crashed = 0
        for findings, stats in pool.imap_unordered(run_batch, [(a.engine, a.seed, b, a.size, a.no_java) for b in range(a.batches)]):
            crashed += sum(x["kind"] in ("zig-crash", "zig-hang") for x in findings)
            for x in findings:
                f.write(json.dumps(x, ensure_ascii=False) + "\n")
            n += len(findings)
            for k, v in stats.items():
                total[k] = total.get(k, 0) + v
            f.flush()
    total["findings"] = n
    total["crashed"] = crashed
    (out / "stats.json").write_text(json.dumps(total, indent=1))
    print(json.dumps(total))
    return 1 if a.fail_on_crash and crashed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
