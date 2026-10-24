#!/bin/sh
A=$(cd "$(dirname "$0")/.." && pwd)   # conformance/survey/adapters; artifacts are built in place
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)   # the repository
TOOLS=${TOOLS:-/tmp/tools}  IMPL=${IMPL:-/tmp/impl}   # toolchains, upstream clones
# adapter: typesafe/config main (built from source), parseFile+resolve
[ "${1:-}" = "--version" ] && { echo "typesafe/config main@a9e5a9d (2026-10-23)"; exit 0; }
exec timeout 30 java -cp "$A/lightbend-main/classes:$A/lightbend-main" LightbendAdapter "$1"
