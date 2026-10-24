#!/bin/sh
A=$(cd "$(dirname "$0")/.." && pwd)   # conformance/survey/adapters; artifacts are built in place
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)   # the repository
TOOLS=${TOOLS:-/tmp/tools}  IMPL=${IMPL:-/tmp/impl}   # toolchains, upstream clones
# adapter: ruby hocon (puppetlabs/ruby-hocon)
[ "${1:-}" = "--version" ] && { echo "ruby hocon 1.4.0"; exit 0; }
GEM_HOME=$A/ruby-adapters/.gems exec timeout 30 ruby $A/ruby-adapters/adapter.rb "$1"
