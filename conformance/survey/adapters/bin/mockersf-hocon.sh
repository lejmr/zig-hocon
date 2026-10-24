#!/bin/sh
A=$(cd "$(dirname "$0")/.." && pwd)   # conformance/survey/adapters; artifacts are built in place
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)   # the repository
TOOLS=${TOOLS:-/tmp/tools}  IMPL=${IMPL:-/tmp/impl}   # toolchains, upstream clones
# adapter: mockersf-hocon — run.sh contract
[ "${1:-}" = "--version" ] && { echo "hocon 0.9.0 (Rust, mockersf, strict loader)"; exit 0; }
exec timeout 30 $A/rust-adapters/target/release/mockersf "$1"
