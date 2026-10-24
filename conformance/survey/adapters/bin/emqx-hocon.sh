#!/bin/sh
A=$(cd "$(dirname "$0")/.." && pwd)   # conformance/survey/adapters; artifacts are built in place
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)   # the repository
TOOLS=${TOOLS:-/tmp/tools}  IMPL=${IMPL:-/tmp/impl}   # toolchains, upstream clones
[ "${1:-}" = "--version" ] && { echo "emqx/hocon 7759b15 (2026-09-22)"; exit 0; }
exec timeout 30 escript $A/erlang/emqx_hocon_adapter.escript "$1"
