#!/bin/sh
A=$(cd "$(dirname "$0")/.." && pwd)   # conformance/survey/adapters; artifacts are built in place
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)   # the repository
TOOLS=${TOOLS:-/tmp/tools}  IMPL=${IMPL:-/tmp/impl}   # toolchains, upstream clones
# adapter: pyhocon — run.sh contract (path in, compact JSON out, non-zero on rejection)
[ "${1:-}" = "--version" ] && { echo "pyhocon 0.3.63"; exit 0; }
exec timeout 30 $A/py-adapters/venv/bin/python $A/py-adapters/adapters/pyhocon_adapter.py "$1"
