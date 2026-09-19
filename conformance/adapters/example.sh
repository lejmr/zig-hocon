#!/bin/sh
# Copy this, point it at your parser, and you are done.
#
#   cp conformance/adapters/example.sh my-adapter.sh
#   $EDITOR my-adapter.sh
#   conformance/run.sh --text -- ./my-adapter.sh
#
# The whole contract:
#
#   your adapter is called with ONE argument, the path to a .conf file
#   it parses that file and prints the result as compact JSON on stdout
#   it exits 0 on success, non-zero if it rejects the input
#
# Substitutions must be resolved. Key order and JSON whitespace do not matter.
# stderr is yours — log whatever you like there.
set -eu

# Answering --version is optional; it only labels the result.
[ "${1:-}" = "--version" ] && { echo "my-parser 0.1.0"; exit 0; }

# Replace this line with your parser. Anything that reads a path and writes JSON
# will do: a compiled binary, a script, `node parse.js`, `cargo run --quiet --`.
exec my-parser --json "$1"
