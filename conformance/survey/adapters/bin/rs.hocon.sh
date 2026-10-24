#!/bin/sh
A=$(cd "$(dirname "$0")/.." && pwd)   # conformance/survey/adapters; artifacts are built in place
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)   # the repository
TOOLS=${TOOLS:-/tmp/tools}  IMPL=${IMPL:-/tmp/impl}   # toolchains, upstream clones
# adapter: rs.hocon — run.sh contract
[ "${1:-}" = "--version" ] && { echo "hocon-parser 1.14.2 (Rust, o3co/rs.hocon)"; exit 0; }
exec timeout 30 $A/rust-adapters/target/release/o3co "$1"
