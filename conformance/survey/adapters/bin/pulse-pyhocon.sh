#!/bin/sh
A=$(cd "$(dirname "$0")/.." && pwd)   # conformance/survey/adapters; artifacts are built in place
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)   # the repository
TOOLS=${TOOLS:-/tmp/tools}  IMPL=${IMPL:-/tmp/impl}   # toolchains, upstream clones
# adapter: pulse-pyhocon 0.2.1; output re-encoded as ASCII JSON (raw U+001E/U+001F in output break run.sh's record format)
[ "${1:-}" = "--version" ] && { echo "pulse-pyhocon 0.2.1"; exit 0; }
out=$(timeout 30 $A/py-adapters/venv/bin/python $A/py-adapters/adapters/pulse_adapter.py "$1") || exit 1
printf '%s' "$out" | python3 -c 'import sys,json
t=sys.stdin.buffer.read().decode("utf-8","replace")
try: print(json.dumps(json.loads(t)))
except Exception: print("".join(c for c in t if c>=" ")); sys.exit(1)'
