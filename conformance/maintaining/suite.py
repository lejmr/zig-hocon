"""Reading the suite and talking to an oracle. The two things both scripts do."""

import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SUITE = ROOT / "conformance" / "suite"
REPORTS = ROOT / "conformance" / "reports"
SPEC = ROOT / "spec" / "HOCON.md"


def encode(src):
    """One case per line, `\\n` `\\t` `\\"` escaped — the oracle protocol.

    The wrappers drop blank input lines, so an empty document has to travel as
    whitespace; same parse, and it keeps one line in == one line out.
    ponytail: only empty-vs-whitespace is affected, fix the wrappers if a case
    ever needs to distinguish them.
    """
    if not src.strip():
        src = " " + src.lstrip("\n")
    return src.replace("\\", "\\\\").replace("\t", "\\t").replace('"', '\\"').replace("\r", "\\r").replace("\n", "\\n")


def is_json(s):
    try:
        json.loads(s)
        return True
    except json.JSONDecodeError:
        return False


def ask(cmd, lines, strict=True, env=None):
    """Run one oracle over every case at once. A short answer means the oracle
    died or broke the protocol, and every later row would be scored against its
    neighbour's answer — so it is an error, never a silent shift."""
    out = subprocess.run([str(c) for c in cmd], input="\n".join(lines) + "\n",
                         capture_output=True, text=True, env=env).stdout.splitlines()
    if len(out) == len(lines):
        return out
    if strict:
        sys.exit("{} returned {} lines for {} cases".format(cmd[0], len(out), len(lines)))
    return ["ERROR OracleFailed: {} lines for {} cases".format(len(out), len(lines))] * len(lines)


def is_dir_case(case):
    """A case that needs more than one file lives in its own directory as
    `<nnn>-<name>/main.conf` + `main.json`; every other .conf beside main.conf
    is a fixture it includes, not a case."""
    return case.name == "main.conf"


def is_fixture(path):
    """Any file under a directory case that is not its main.conf, however deep."""
    if path.name == "main.conf":
        return False
    p = path.parent
    while p != SUITE and p != p.parent:
        if (p / "main.conf").exists():
            return True
        p = p.parent
    return False


def section_of(case):
    return case.parent.parent.name if is_dir_case(case) else case.parent.name


def name_of(case):
    return case.parent.name if is_dir_case(case) else case.stem


def key_of(case):
    return case.relative_to(SUITE).as_posix()


def cases():
    """Every case with a sidecar, sorted. Orphans are returned separately rather
    than skipped quietly — a .conf with no .json is unfinished work, not a case.
    Fixtures inside a directory case are neither."""
    found = [c for c in sorted(SUITE.rglob("*.conf")) if not is_fixture(c)]
    orphans = [c for c in found if not c.with_suffix(".json").exists()]
    keep = [c for c in found if c not in set(orphans)]
    return keep, [json.loads(c.with_suffix(".json").read_text()) for c in keep], orphans


def oracle_line(case, meta):
    """The one line that asks an oracle about this case. A directory case is sent
    as a path so its includes resolve beside it; anything else as escaped text."""
    body = "file:" + str(case.resolve()) if is_dir_case(case) else encode(case.open(newline="").read())
    return ("resolve:" if meta.get("resolve") else "") + body


def anchors():
    """Heading slugs of the spec, the way GitHub builds them."""
    out = {}
    for line in SPEC.read_text().splitlines():
        if line.startswith("#"):
            title = line.lstrip("#").strip()
            out[re.sub(r"[^a-z0-9 -]", "", title.lower()).replace(" ", "-")] = title
    return out


def bad_anchors(paths, metas):
    known = anchors()
    return [(p, m.get("spec", "")) for p, m in zip(paths, metas)
            if m.get("spec", "").split("#", 1)[-1] not in known]


def version(cmd):
    """What an implementation calls itself. A command that has no --version, or
    hangs on to stdin instead of answering, is reported as unknown rather than
    holding up the run."""
    try:
        out = subprocess.run([str(c) for c in cmd] + ["--version"], input="",
                             capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return "unknown"
    first = (out.stdout or out.stderr).strip().splitlines()
    return first[0][:80] if out.returncode == 0 and first else "unknown"


def spec_items():
    """The vendored rule inventory: id -> text. The denominator for coverage."""
    out = {}
    path = pathlib.Path(__file__).resolve().parent / "spec-items.md"
    for line in path.read_text().splitlines():
        m = re.match(r"- \*\*(S[\dA-Za-z.]+)\*\* (.*)", line)
        if m:
            out[m.group(1)] = m.group(2)
    return out


def digest():
    """Fingerprint of every case and sidecar — the same one run.sh records, so a
    stale result file can be told from a current one."""
    import hashlib
    h = hashlib.sha256()
    for path in sorted(SUITE.rglob("*.conf")):
        h.update(path.relative_to(SUITE).as_posix().encode())
        h.update(path.read_bytes())
        side = path.with_suffix(".json")
        if side.exists():  # a fixture has none, and is still an input
            h.update(side.read_bytes())
    return h.hexdigest()[:16]
