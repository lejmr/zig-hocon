#!/usr/bin/env python3
"""Compaction round trip over the whole conformance suite.

    zig build && tools/compact-roundtrip.py [--only <text>]

For every case `hocon --json` accepts, `hocon --hocon --env=keep` writes it out
with no variables at all, the way it would be compacted before it ships. That
file, read again with the case's variables (`"env"` in the sidecar), must give
the same JSON as the original read with them. Prints each case that does not,
and exits 1 if there is one.

HOCON_BIN points it at another build.
"""
import json, os, pathlib, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
BIN = os.environ.get("HOCON_BIN", str(ROOT / "zig-out/bin/hocon"))
ONLY = sys.argv[sys.argv.index("--only") + 1] if "--only" in sys.argv else ""


def hocon(args, env):
    # Only what the case sets, as run.sh does: the shell this runs in counts for nothing.
    return subprocess.run([BIN, *args], env={"PATH": os.environ["PATH"], **env}, capture_output=True, text=True)


def cases():
    # <name>.conf beside <name>.json, or <name>/main.conf beside main.json
    for conf in sorted((ROOT / "conformance/suite").rglob("*.conf")):
        if not conf.with_suffix(".json").exists():
            continue
        if conf.name != "main.conf" and (conf.parent / "main.conf").exists():
            continue
        yield conf


failed = checked = 0
with tempfile.TemporaryDirectory() as tmp:
    compacted = pathlib.Path(tmp) / "compact.conf"
    for conf in cases():
        name = str(conf.relative_to(ROOT / "conformance/suite"))
        if ONLY not in name:
            continue
        env = json.loads(conf.with_suffix(".json").read_text()).get("env", {})
        original = hocon(["--json", str(conf)], env)
        if original.returncode != 0:
            continue
        checked += 1
        compact = hocon(["--hocon", "--env=keep", str(conf)], {})
        if compact.returncode != 0:
            failed += 1
            print(f"{name}: --env=keep fails\n  {compact.stderr.strip()}")
            continue
        compacted.write_text(compact.stdout)
        again = hocon(["--json", str(compacted)], env)
        if again.stdout != original.stdout:
            failed += 1
            got = again.stdout.strip() or "rejected: " + again.stderr.strip()
            print(f"{name}\n  want {original.stdout.strip()}\n  got  {got}")
            print("  " + compact.stdout.strip().replace("\n", "\n  "))

print(f"{checked - failed}/{checked} cases read back the same once compacted")
sys.exit(1 if failed else 0)
