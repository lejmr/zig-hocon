#!/bin/sh
A=$(cd "$(dirname "$0")/.." && pwd)   # conformance/survey/adapters; artifacts are built in place
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)   # the repository
TOOLS=${TOOLS:-/tmp/tools}  IMPL=${IMPL:-/tmp/impl}   # toolchains, upstream clones
# adapter: puppetlabs/cpp-hocon 4981ed4 (archived), parse_file_any_syntax + resolve; output re-encoded as ASCII JSON
[ "${1:-}" = "--version" ] && { echo "cpp-hocon 4981ed4 (2025-01-14, archived)"; exit 0; }
out=$(timeout 30 $A/cpp/cpp-hocon-adapter "$1") || exit 1
printf '%s' "$out" | python3 -c 'import sys,json
t=sys.stdin.buffer.read().decode("utf-8","replace")
try: print(json.dumps(json.loads(t)))
except Exception: print("".join(c for c in t if c>=" ")); sys.exit(1)'
