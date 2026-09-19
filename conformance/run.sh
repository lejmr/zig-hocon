#!/bin/sh
# Run any HOCON parser against the conformance suite and print the result as JSON.
#
#   conformance/run.sh -- ./my-parser
#   conformance/run.sh --java -- python3 parse.py
#   conformance/run.sh --only substitutions -- ./my-parser > result.json
#   conformance/run.sh --impl my-parser --version 0.4.1 -- ./my-parser
#   conformance/run.sh --text -- ./my-parser            # read it instead of uploading it
#
# Needs a POSIX shell and python3. Nothing else, and nothing from outside this
# directory — the suite travels on its own.
#
# The result names the implementation and its version, because a score without
# them is not a fact about anything. If --version is not given, the command is
# asked for one with `<command> --version`; a command that does not answer is
# recorded as "unknown".
#
# The contract your command must satisfy, and nothing more:
#
#   <command> <path-to-.conf>
#     exit 0  — print the parsed config as compact JSON on stdout
#     exit !0 — the input is rejected; stdout is ignored, stderr is yours
#
# Substitutions must be resolved. Key order does not matter. Whitespace in the
# JSON does not matter. Anything your command prints on stderr is left alone, so
# it can log freely.
#
# Modes:
#   --spec (default)  score against what the HOCON specification requires
#   --java            score against what typesafe/config does, on the rows where
#                     the two disagree — compatibility with the JVM world rather
#                     than conformance; see conformance/PROCESS.md
set -eu

MODE=spec
FORMAT=json
ONLY=
IMPL=
VERSION=
DIR=$(cd "$(dirname "$0")" && pwd)/suite

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --mode) MODE=$2; shift 2 ;;
        --spec) MODE=spec; shift ;;
        --java) MODE=java; shift ;;
        --only) ONLY=$2; shift 2 ;;
        --text) FORMAT=text; shift ;;
        --impl) IMPL=$2; shift 2 ;;
        --version) VERSION=$2; shift 2 ;;
        --dir)  DIR=$2; shift 2 ;;
        -h|--help) usage 0 ;;
        --) shift; break ;;
        *) echo "unknown option: $1" >&2; usage 1 >&2 ;;
    esac
done

[ $# -gt 0 ] || { echo "no command given" >&2; usage 1 >&2; }
case "$MODE" in spec|java) ;; *) echo "mode must be spec or java" >&2; exit 1 ;; esac
[ -d "$DIR" ] || { echo "no suite at $DIR" >&2; exit 1; }

# the last word names the thing better than the first: `oracle.sh hocon-py` is
# pyhocon, not an adapter, and `python3 parse.py` is parse.py
for word in "$@"; do :; done
[ -n "$IMPL" ] || IMPL=$(basename "$word")
[ -n "$VERSION" ] || VERSION=$("$@" --version </dev/null 2>/dev/null | head -1) || true
[ -n "$VERSION" ] || VERSION=unknown

# Results go to a temp file as NUL-delimited records, so a config file containing
# newlines or quotes cannot corrupt the stream.
RESULTS=$(mktemp)
trap 'rm -f "$RESULTS"' EXIT INT TERM

for case_file in $(find "$DIR" -name '*.conf' | sort); do
    [ -z "$ONLY" ] || case "$case_file" in *"$ONLY"*) ;; *) continue ;; esac
    [ -f "${case_file%.conf}.json" ] || continue

    if out=$("$@" "$case_file" 2>/dev/null); then status=0; else status=$?; fi
    printf '%s\037%s\037%s\036' "$case_file" "$status" "$out" >> "$RESULTS"
done

COMMAND="$*" MODE="$MODE" FORMAT="$FORMAT" RESULTS="$RESULTS" DIR="$DIR" IMPL="$IMPL" VERSION="$VERSION" \
  RAN_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ) python3 - <<'PY'
import json, os, pathlib, sys

mode, root = os.environ["MODE"], pathlib.Path(os.environ["DIR"])
records = [r for r in pathlib.Path(os.environ["RESULTS"]).read_text(errors="replace").split("\036") if r]

sections, failures, verdicts, outputs, passed = {}, [], {}, {}, 0
for record in records:
    path, status, out = record.split("\037", 2)
    case = pathlib.Path(path)
    meta = json.loads(case.with_suffix(".json").read_text())

    # on a row where the spec and typesafe/config disagree, java mode scores
    # against what typesafe/config does instead
    if mode == "java" and "java_expect" in meta:
        want, rejects = meta["java_expect"], False
    elif mode == "java" and "java_error" in meta:
        want, rejects = None, True
    else:
        want, rejects = meta.get("expect"), "error" in meta

    if rejects:
        ok, got = status != "0", ("rejected" if status != "0" else out.strip())
    elif status != "0":
        ok, got = False, "rejected (exit {})".format(status)
    else:
        try:
            got_value = json.loads(out)
            ok, got = got_value == want, got_value
        except json.JSONDecodeError:
            ok, got = False, out.strip()[:200]

    name = case.parent.name
    rel = str(case.relative_to(root))
    verdicts[rel] = "open" if "review" in meta else "pass" if ok else "fail"
    # the contested rows are worth keeping verbatim: a report wants to show what
    # each implementation actually did, not only whether it agreed
    if "java" in meta or "review" in meta:
        outputs[rel] = "rejected" if status != "0" else out.strip()[:120]
    tally = sections.setdefault(name, {"total": 0, "passed": 0})
    tally["total"] += 1
    tally["passed"] += ok
    passed += ok
    if not ok:
        failures.append({
            "case": str(case.relative_to(root)),
            "spec": meta.get("spec"),
            "rule": meta.get("why"),
            "expected": "rejected" if rejects else want,
            "got": got,
            **({"open_question": meta["review"]} if "review" in meta else {}),
            **({"java": meta["java"]} if "java" in meta else {}),
        })

total = len(records)
report = {
    "suite": "hocon-conformance",
    "implementation": os.environ["IMPL"],
    "version": os.environ["VERSION"],
    "mode": mode,
    "command": os.environ["COMMAND"],
    "ran_at": os.environ["RAN_AT"],
    "total": total,
    "passed": passed,
    "percent": round(100 * passed / total, 1) if total else 0.0,
    "sections": dict(sorted(sections.items())),
    "cases": dict(sorted(verdicts.items())),
    "outputs": dict(sorted(outputs.items())),
    "failures": failures,
}

if os.environ["FORMAT"] == "json":
    json.dump(report, sys.stdout, indent=2, ensure_ascii=False)
    print()
else:
    bar = lambda p, n: "#" * round(20 * p / n) + "." * (20 - round(20 * p / n)) if n else ""
    print("{} {} — {} mode".format(report["implementation"], report["version"], mode))
    print("{}  {}/{}  {}%\n".format(bar(passed, total), passed, total, report["percent"]))
    for name, t in report["sections"].items():
        if t["passed"] < t["total"]:
            print("  {:<46} {:>3}/{}".format(name, t["passed"], t["total"]))
    if failures:
        print("\n{} failing:".format(len(failures)))
        for f in failures:
            print("\n  {}\n    rule     {}\n    expected {}\n    got      {}".format(
                f["case"], (f["rule"] or "")[:100],
                json.dumps(f["expected"], ensure_ascii=False)[:100],
                json.dumps(f["got"], ensure_ascii=False)[:100]))
    else:
        print("\n  everything this suite can check, checks out")

sys.exit(0 if passed == total else 1)
PY
