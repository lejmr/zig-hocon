"""Shrink, bucket and match the findings of fuzz.py against the suite.

    python3 tools/fuzz/triage.py .scratch/fuzz/runs/* --out .scratch/fuzz/buckets.json
    python3 tools/fuzz/triage.py --rebucket .scratch/fuzz/buckets.triaged.jsonl --out ...

Every finding is minimized with delta debugging, first on lines and then on
tokens, keeping its signature: what zig does (ok, or the error's name) and
what typesafe/config does (ok, or rejected), and for two values that differ,
that they still differ. A shrink step that would turn the finding into one of
the divergences the suite already records (`java: diverges | unsupported |
lenient`) is refused, so a case does not collapse onto a known one.

A metamorphic finding becomes a differential one when typesafe/config gives
the same answer for both forms and zig differs from it on one; the rest stay
as they are, for reading.

Buckets are keyed by the signature and the set of features of the minimized
input. Each bucket lists the suite cases with the same features and outcome,
the ones that might already cover it.
"""

import json
import os
import pathlib
import re
import select
import subprocess
import sys
import tempfile
from multiprocessing import Pool

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import fuzz  # noqa: E402

suite = fuzz.suite


class Java:
    """One JVM per worker, asked one case at a time."""

    def __init__(self, version="1.4.9"):
        self.p = None
        self.version = version

    def start(self):
        self.p = subprocess.Popen([fuzz.JAVA], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  env=dict(fuzz.environ(), HOCON_JAVA_VERSION=self.version),
                                  text=True, encoding="utf-8", errors="replace", bufsize=1)

    def ask(self, path):
        if self.p is None or self.p.poll() is not None:
            self.start()
        self.p.stdin.write("resolve:file:{}\n".format(path))
        self.p.stdin.flush()
        ready, _, _ = select.select([self.p.stdout], [], [], 20)
        if not ready:
            self.p.kill()
            self.p = None
            return ("err", "OracleHang")
        line = self.p.stdout.readline()
        return fuzz.parse_java(line.rstrip("\n")) if line else ("err", "OracleDied")


JAVA = Java()
JAVA_MAIN = Java("main")


def outcome(o):
    return "ok" if o[0] == "ok" else o[0] + ":" + str(o[1])[:40]


def evaluate(files):
    d = pathlib.Path(tempfile.mkdtemp(prefix="hocon-shrink-"))
    try:
        fuzz.write_case(d, files)
        z = fuzz.run_zig(d, "--json")
        j = JAVA.ask(d / "main.conf")
        return z, j
    finally:
        import shutil
        shutil.rmtree(d, ignore_errors=True)


def signature(z, j):
    """What a shrink must keep. Java is only ok or rejected."""
    zs = outcome(z) if z[0] != "crash" else "crash"
    js = "ok" if j[0] == "ok" else "err"
    return (zs, js, z[0] == j[0] == "ok")


# ---------------------------------------------------------------- known

def features(files):
    """Coarse, readable features of a file tree's text."""
    t = "\n".join(files.values())
    f = set()
    checks = {
        "subst": r"\$\{[^?]", "opt-subst": r"\$\{\?", "plus-equals": r"\+=", "include": r"\binclude\b",
        "object": r"\{", "list": r"\[", "quoted-key": r'^\s*"[^"\n]*"\s*(\.|[=:{+])', "path-key": r"^\s*[\w\"-]+\.[\w\"]",
        "env": r"\$\{\??FZ_", "null": r"\bnull\b", "unit": r"\d\s*(ms|s|K|day|MB|EB|ex)\b",
        "triple-quote": r'"""', "comment": r"#|//", "comma": r",", "number": r"(?<![\w.])-?\d",
        "obj-concat": r"\}\s*\$\{|\}\s*\{|\$\{[^}]*\}\s*\{", "list-concat": r"\]\s*\$\{|\]\s*\[|\$\{[^}]*\}\s*\[",
        "str-concat": r"\$\{[^}]*\}\s*[\w\"]|[\w\"]\s*\$\{", "files": r"",
    }
    for name, rx in checks.items():
        if name == "files":
            if len(files) > 1:
                f.add("files")
        elif re.search(rx, t, re.M):
            f.add(name)
    keys = re.findall(r"^\s*([\w\"][^=:{\n+]*?)\s*(?:[=:{]|\+=)", t, re.M)
    if len(keys) != len(set(keys)):
        f.add("duplicate-key")
    for k in keys:
        k = k.strip().strip('"')
        if re.search(r"\$\{\??" + re.escape(k) + r"[}.]", t):
            f.add("self-or-cross-ref")
    return frozenset(f)


def known_cases():
    """The suite cases typesafe/config is known to get wrong, and every case's
    features and outcomes, for matching."""
    out = []
    for case, meta in zip(*suite.cases()[:2]):
        if meta.get("env"):
            continue
        if suite.is_dir_case(case):
            d = case.parent
            files = {p.relative_to(d).as_posix(): p.read_text(errors="replace") for p in d.rglob("*")
                     if p.is_file() and p.suffix in (".conf", ".json", ".properties") and p.name != "main.json"}
        else:
            files = {"main.conf": case.read_text(errors="replace")}
        spec_ok = "expect" in meta
        java_ok = "java_expect" in meta if "java" in meta else spec_ok
        out.append({"case": suite.key_of(case), "java": meta.get("java"), "files": files,
                    "features": features(files), "spec_ok": spec_ok, "java_ok": java_ok,
                    "expect": meta.get("expect"), "error": meta.get("error"),
                    "resolve": meta.get("resolve", False)})
    return out


KNOWN = []


def is_known(files, z, j):
    """The shape of a divergence the suite already records: zig passes the
    suite, so zig agreeing with a recorded java-divergent row's spec answer
    and java with its java answer, on the same features, is that row."""
    fs = features(files)
    for k in KNOWN:
        if k["java"] and k["features"] == fs and (z[0] == "ok") == k["spec_ok"] and (j[0] == "ok") == k["java_ok"]:
            return k["case"]
    return None


# ---------------------------------------------------------------- shrinking

def ddmin(items, test):
    """Classic delta debugging: the smallest sublist (1-minimal) that passes test."""
    n = 2
    while len(items) >= 2:
        chunk = max(1, len(items) // n)
        reduced = False
        for i in range(0, len(items), chunk):
            rest = items[:i] + items[i + chunk:]
            if rest and test(rest):
                items, n, reduced = rest, max(n - 1, 2), True
                break
        if not reduced:
            if n >= len(items):
                break
            n = min(len(items), n * 2)
    return items


def shrink(files, keep):
    """keep(files) -> bool. Files, then lines, then tokens, file by file."""
    files = dict(files)
    for name in sorted(files, key=lambda n: n == "main.conf"):
        if name != "main.conf":
            trial = {k: v for k, v in files.items() if k != name}
            if keep(trial):
                files = trial
    for unit in ("lines", "tokens"):
        for name in sorted(files, key=lambda n: n != "main.conf"):
            if unit == "lines":
                parts = files[name].split("\n")
                glue = "\n"
            else:
                parts = fuzz.toks(files[name])
                glue = ""

            def test(sub, name=name, glue=glue):
                return keep(dict(files, **{name: glue.join(sub)}))

            files[name] = glue.join(ddmin(parts, test))
    return files


def triage_one(f):
    """(finding, minimized files, zig, java) or None when it does not reproduce."""
    files = f["files"]
    kind = f["kind"]
    if kind.startswith("meta"):
        za, zb, ja, jb = f["zig"], f.get("zig_b"), f["java"], f.get("java_b")
        # java agrees with itself and zig strays on one form: that form is a diff
        if jb is not None and fuzz.same(ja, jb):
            if not fuzz.same(za, ja):
                kind = "diff"
            elif zb is not None and not fuzz.same(zb, jb):
                files, kind = f["variant"], "diff"
    if kind.startswith(("roundtrip", "json")):
        return {"finding": f, "kind": kind, "files": files, "zig": f.get("zig"), "java": f.get("java"),
                "features": sorted(features(files)), "known": None}
    if kind.startswith("meta"):
        return {"finding": f, "kind": kind, "files": files, "files_b": f.get("variant"), "zig": f.get("zig"),
                "zig_b": f.get("zig_b"), "java": f.get("java"), "java_b": f.get("java_b"),
                "features": sorted(features(files)), "known": None}
    z, j = evaluate(files)
    sig = signature(z, j)
    if kind == "diff" and fuzz.same(z, j):
        return None
    pre = known_rule({"kind": kind, "files": files, "zig": z, "java": j})
    if pre:
        # ponytail: a known divergence is not shrunk, and whatever else the
        # same input hides is left to another case to find
        return {"finding": f["id"], "kind": kind, "files": files, "zig": z, "java": j, "signature": list(sig),
                "features": sorted(features(files)), "known": pre, "shrunk": False}
    known = is_known(files, z, j)

    def keep(trial):
        tz, tj = evaluate(trial)
        if signature(tz, tj) != sig:
            return False
        if kind == "diff" and fuzz.same(tz, tj):
            return False
        if known is not None:
            return True
        return is_known(trial, tz, tj) is None and known_rule({"kind": kind, "files": trial, "zig": tz, "java": tj}) is None

    small = shrink(files, keep)
    z, j = evaluate(small)
    d = pathlib.Path(tempfile.mkdtemp(prefix="hocon-main-"))
    fuzz.write_case(d, small)
    jm = JAVA_MAIN.ask(d / "main.conf")
    return {"finding": f["id"], "kind": kind if z[0] not in ("crash", "hang") else "zig-" + z[0],
            "files": small, "zig": z, "java": j, "java_main": jm, "signature": list(sig),
            "features": sorted(features(small)), "known": is_known(small, z, j)}


def init():
    global KNOWN
    fuzz.init_worker()
    KNOWN = known_cases()


# The divergences the suite already records, as patterns over a minimized
# input and what the engines did with it: (suite case, test). A pattern is
# coarser than its case on purpose, triage only has to set the known aside.
def _j(t, cls=None):
    return t["java"][0] == "err" and (cls is None or t["java"][1] == cls)


def _z(t, *names):
    return t["zig"][0] == "err" and (not names or t["zig"][1] in names)


def _ok(t, who):
    return t[who][0] == "ok"


KNOWN_RULES = [
    ("omit-root-braces/006 (array root)", lambda x, t: re.match(r"\s*(#[^\n]*\n\s*)*\[", x) and _j(t, "WrongType")),
    ("unchanged-from-json/009-014, unquoted-strings/012-027 (number runs)",
     lambda x, t: _z(t, "BadNumber", "LeadingZeroIsNotAJsonNumber", "HyphenIsNotAJsonNumber") and _ok(t, "java")),
    ("unchanged-from-json/029-030 (\\u escapes)", lambda x, t: _z(t, "InvalidEscape") and _ok(t, "java")),
    ("string-value-concatenation/010-016 (list or object then text)",
     lambda x, t: _z(t, "UnsupportedConcatenation") and _ok(t, "java")
     and re.search(r"[\]}][ \t]*[^\s,\]}#/$\[{]|[^\s=:,\[{]\s*[\[{]|\u200b", x)),
    ("include-file-formats/006-024 (.json, .properties, unknown extension)",
     lambda x, t: re.search(r"\.(json|properties|txt)\b|include\s*(required\()?\"[^\".]*\"", x)),
    ("paths-as-keys/008 (include.foo)", lambda x, t: re.search(r"^\s*include\.", x, re.M)),
    ("plus-equals-field-separator/006 (+= in a list element)", lambda x, t: re.search(r"\[[^\]]*\{[^}]*\+=", x) and _j(t)),
    ("include-merging/011 (include in a list element)", lambda x, t: re.search(r"\[[^\]]*\{\s*include", x) and _j(t)),
    ("array-and-object-concatenation/018-022 (BugOrBroken)", lambda x, t: _j(t, "BugOrBroken")),
    ("concatenation-whitespace-and-substitutions/009 (undefined optional, then list or object)",
     lambda x, t: "${?" in x and _ok(t, "zig") and _j(t, "WrongType")),
    ("duplicate-keys-and-object-merging/010-017 (null in a merge)", lambda x, t: "null" in x and _ok(t, "zig")),
    ("plus-equals 009-012, self-referential-examples 027-033 (${x} { ... } is a merge)",
     lambda x, t: re.search(r"\$\{[^}]*\}\s*\{", x) and _ok(t, "zig") and not fuzz.same(t["zig"], t["java"])),
    ("self-referential-examples/015, 021, dup/025 (hidden field never evaluated)",
     lambda x, t: _ok(t, "zig") and _j(t, "UnresolvedSubstitution")),
    ("include-substitution/009-014 (fixed-up paths)", lambda x, t: "include" in x and _ok(t, "zig") and _j(t)),
]


# Families this campaign found, not (yet) in the suite: labelled so a later
# round sorts into them instead of reopening them. See .scratch/fuzz/report.md.
FAMILY_RULES = [
    ("F1 a comma after the root object", lambda x, t: _ok(t, "zig") and _j(t, "Parse") and re.search(r"\}\s*,\s*$", x)),
    ("F2 key {...} followed by a concatenation", lambda x, t: _ok(t, "zig") and _j(t, "Parse")
     and re.search(r"^[^=:\n\[]*?[\w\"]\s*\{[^\n]*\}[ \t]*(\{|\$\{)", x, re.M)),
    ("F2b += inside the value of +=", lambda x, t: _ok(t, "zig") and _j(t, "Parse") and re.search(r"\+=\s*\{[^}]*\+=", x)),
    ("F5 cycle, or a look back / an undefined optional", lambda x, t: _z(t, "SubstitutionCycle", "Unresolved") and _ok(t, "java")),
    ("F9 number next to an undefined optional (substitutions/039)", lambda x, t: _ok(t, "zig") and _ok(t, "java")
     and re.search(r"\d\$\{\?|\$\{\?[^}]*\}-?\d", x)),
    ("F6 include merged as a whole object", lambda x, t: len(t["files"]) > 1 and _ok(t, "zig") and _ok(t, "java")),
    ("F7 += or a merge after a non-object", lambda x, t: _ok(t, "zig") and _ok(t, "java")),
]


def family(t):
    if t["kind"] != "diff":
        return None
    x = "\n".join(t["files"].values())
    for name, test in FAMILY_RULES:
        if test(x, t):
            return name
    return None


def known_rule(t):
    if t["kind"] == "roundtrip-java":
        # java has no list root and turns integers past 64 bits into strings
        x = "\n".join(t["files"].values())
        if t["zig"][0] == "ok" and (isinstance(t["zig"][1], list) or re.search(r"\d{19}", x)):
            return "omit-root-braces/006, unchanged-from-json/028 (java cannot read the export)"
        return None
    if t["kind"] != "diff":
        return None
    if t.get("java_main") and fuzz.same(t["zig"], t["java_main"]):
        return "fixed in typesafe/config main"
    x = "\n".join(t["files"].values())
    for name, test in KNOWN_RULES:
        if test(x, t):
            return name
    return None


def shape(files):
    """The input with its names abstracted: keys and words in order of first
    appearance become k1, k2, ..., numbers N, quoted strings S."""
    names = {}
    out = []
    for name in sorted(files, key=lambda n: n != "main.conf"):
        out.append("[" + ("main" if name == "main.conf" else "f") + "]")
        for tok in fuzz.toks(files[name]):
            if tok.strip() == "":
                out.append(" " if "\n" not in tok else "⏎")
            elif re.fullmatch(r"-?\d[\w.]*", tok):
                out.append("N")
            elif tok.startswith('"""') or (tok.startswith('"') and tok.endswith('"') and len(tok) > 1):
                out.append("S")
            elif re.fullmatch(r"[\w-]+", tok) and tok not in ("include", "required", "true", "false", "null"):
                out.append(names.setdefault(tok, "k{}".format(len(names) + 1)))
            elif tok.startswith("${"):
                inner = re.sub(r"[\w-]+", lambda m: names.setdefault(m.group(0), "k{}".format(len(names) + 1)), tok)
                out.append(inner)
            else:
                out.append(tok)
    return "".join(out)


def bucket_key(t):
    zs = outcome(t["zig"]) if t.get("zig") else "-"
    js = "ok" if t.get("java") and t["java"][0] == "ok" else "err"
    return "{} | zig {} | java {} | {}".format(t["kind"], zs, js, shape(t["files"]))


def covering(t):
    """Suite cases with the same features: the ones that might cover it."""
    fs = set(t["features"])
    return [k["case"] for k in KNOWN if k["features"] == fs][:8]


def main(argv):
    out = pathlib.Path(argv[argv.index("--out") + 1]) if "--out" in argv else fuzz.ROOT / ".scratch" / "fuzz" / "buckets.json"
    runs = [pathlib.Path(a) for a in argv if not a.startswith("--") and a != str(out)]
    if "--rebucket" in argv:
        init()
        done = [json.loads(line) for r in runs for line in r.open()]
        write_buckets(done, out)
        return 0
    findings = []
    for r in runs:
        p = r / "findings.jsonl"
        if p.exists():
            findings += [json.loads(line) for line in p.open()]
    init()
    with Pool(os.cpu_count(), initializer=init) as pool:
        done = [t for t in pool.imap_unordered(triage_one, findings, chunksize=4) if t]
    with open(out.with_suffix(".triaged.jsonl"), "w") as f:
        for t in done:
            f.write(json.dumps(t, ensure_ascii=False) + "\n")
    write_buckets(done, out)
    return 0


def write_buckets(done, out):
    buckets = {}
    for t in done:
        t["known"] = known_rule(t) or t.get("known")
        t["family"] = None if t["known"] else family(t)
        buckets.setdefault(bucket_key(t), []).append(t)
    report = []
    for key, ts in sorted(buckets.items(), key=lambda kv: -len(kv[1])):
        ts.sort(key=lambda t: sum(len(v) for v in t["files"].values()))
        smallest = ts[0]
        report.append({"bucket": key, "count": len(ts), "known": sorted({t["known"] for t in ts if t["known"]}),
                       "family": sorted({t["family"] for t in ts if t.get("family")}),
                       "covering": covering(smallest), "smallest": smallest,
                       "others": [t["files"] for t in ts[1:4]]})
    out.write_text(json.dumps(report, indent=1, ensure_ascii=False))
    print("{} reproduced, {} buckets ({} unknown)".format(
        len(done), len(report), sum(1 for b in report if not b["known"])))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
