#!/bin/sh
A=$(cd "$(dirname "$0")/.." && pwd)   # conformance/survey/adapters; artifacts are built in place
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)   # the repository
TOOLS=${TOOLS:-/tmp/tools}  IMPL=${IMPL:-/tmp/impl}   # toolchains, upstream clones
# adapter: hocon-rs — run.sh contract
[ "${1:-}" = "--version" ] && { echo "hocon-rs 0.2.0 (Rust, mikai233)"; exit 0; }
exec timeout 30 $A/rust-adapters/target/release/mikai "$1"
