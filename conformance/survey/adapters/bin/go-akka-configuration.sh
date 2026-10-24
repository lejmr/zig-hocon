#!/bin/sh
A=$(cd "$(dirname "$0")/.." && pwd)   # conformance/survey/adapters; artifacts are built in place
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)   # the repository
TOOLS=${TOOLS:-/tmp/tools}  IMPL=${IMPL:-/tmp/impl}   # toolchains, upstream clones
# adapter: go-akka-configuration — run.sh contract (path in, compact JSON out, non-zero on rejection)
[ "${1:-}" = "--version" ] && { echo "go-akka/configuration v0.0.0-20200606091224-a002c0330665"; exit 0; }
exec timeout 30 $A/go-adapters/bin/goakka "$1"
