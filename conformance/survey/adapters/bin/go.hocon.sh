#!/bin/sh
A=$(cd "$(dirname "$0")/.." && pwd)   # conformance/survey/adapters; artifacts are built in place
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)   # the repository
TOOLS=${TOOLS:-/tmp/tools}  IMPL=${IMPL:-/tmp/impl}   # toolchains, upstream clones
# adapter: go.hocon — run.sh contract (path in, compact JSON out, non-zero on rejection)
[ "${1:-}" = "--version" ] && { echo "o3co/go.hocon v1.14.2"; exit 0; }
exec timeout 30 $A/go-adapters/bin/o3co "$1"
