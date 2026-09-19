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
    return src.replace("\\", "\\\\").replace("\t", "\\t").replace('"', '\\"').replace("\n", "\\n")


def is_json(s):
    try:
        json.loads(s)
        return True
    except json.JSONDecodeError:
        return False


def ask(cmd, lines, strict=True):
    """Run one oracle over every case at once. A short answer means the oracle
    died or broke the protocol, and every later row would be scored against its
    neighbour's answer — so it is an error, never a silent shift."""
    out = subprocess.run([str(c) for c in cmd], input="\n".join(lines) + "\n",
                         capture_output=True, text=True).stdout.splitlines()
    if len(out) == len(lines):
        return out
    if strict:
        sys.exit("{} returned {} lines for {} cases".format(cmd[0], len(out), len(lines)))
    return ["ERROR OracleFailed: {} lines for {} cases".format(len(out), len(lines))] * len(lines)


def cases():
    """Every case with a sidecar, sorted. Orphans are returned separately rather
    than skipped quietly — a .conf with no .json is unfinished work, not a case."""
    found = sorted(SUITE.rglob("*.conf"))
    orphans = [c for c in found if not c.with_suffix(".json").exists()]
    keep = [c for c in found if c not in set(orphans)]
    return keep, [json.loads(c.with_suffix(".json").read_text()) for c in keep], orphans


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
