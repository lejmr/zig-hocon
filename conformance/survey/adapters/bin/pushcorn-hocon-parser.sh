#!/bin/sh
A=$(cd "$(dirname "$0")/.." && pwd)   # conformance/survey/adapters; artifacts are built in place
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)   # the repository
TOOLS=${TOOLS:-/tmp/tools}  IMPL=${IMPL:-/tmp/impl}   # toolchains, upstream clones
# adapter: pushcorn-hocon-parser — run.sh contract (path in, compact JSON out, non-zero on rejection)
[ "${1:-}" = "--version" ] && { echo "@pushcorn/hocon-parser 1.3.1"; exit 0; }
exec timeout 30 node $A/ts-adapters/adapters/pushcorn.mjs "$1"
