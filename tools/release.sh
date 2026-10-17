#!/bin/sh
# The repository side of a release (.github/workflows/release.yml runs it).
#
#   tools/release.sh --check <version>   refuse a version that cannot be released
#   tools/release.sh <version>           CHANGELOG.md, build.zig.zon,
#                                        python/pyproject.toml and the README
#                                        say the version; nothing is committed
#   tools/release.sh --notes <version>   the version's CHANGELOG.md section,
#                                        for the GitHub release
#
# One version for everything: the Zig package, libhocon and the Python
# package. CHANGELOG.md's `## [Unreleased]` becomes `## [<version>] - <date>`.
set -eu
cd "$(dirname "$0")/.."

mode=prepare
case "${1:-}" in
    --check | --notes) mode=${1#--}; shift ;;
esac
v=${1:?usage: tools/release.sh [--check | --notes] <version>}

fail() {
    echo "::error::$*" >&2
    exit 1
}

if [ "$mode" = notes ]; then
    awk -v head="## [$v]" '
        index($0, head) == 1 { found = 1; next }
        found && /^## \[/ { exit }
        found { print }
    ' CHANGELOG.md | sed -e '/./,$!d'
    exit 0
fi

echo "$v" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || fail "'$v' is not a version like 0.4.0"
if git rev-parse -q --verify "refs/tags/v$v" >/dev/null; then
    fail "tag v$v exists: $v was released already"
fi
if ! grep -q "^## \[$v\]" CHANGELOG.md; then
    grep -q '^## \[Unreleased\]$' CHANGELOG.md || fail "CHANGELOG.md has neither '## [$v]' nor '## [Unreleased]'"
    entries=$(awk '$0 == "## [Unreleased]" { f = 1; next } f && /^## \[/ { exit } f && /^- / { n++ } END { print n + 0 }' CHANGELOG.md)
    [ "$entries" -gt 0 ] || fail "'## [Unreleased]' in CHANGELOG.md has no entries: nothing to release"
fi
[ "$mode" = check ] && { echo "v$v can be released"; exit 0; }

if ! grep -q "^## \[$v\]" CHANGELOG.md; then
    sed -i.bak "s/^## \[Unreleased\]\$/## [$v] - $(date -u +%F)/" CHANGELOG.md
fi
sed -i.bak "s/^    \.version = \"[^\"]*\",/    .version = \"$v\",/" build.zig.zon
sed -i.bak "s/^version = \"[^\"]*\"/version = \"$v\"/" python/pyproject.toml
sed -i.bak "s|/archive/refs/tags/v[0-9.]*\.tar\.gz|/archive/refs/tags/v$v.tar.gz|" README.md
rm -f CHANGELOG.md.bak build.zig.zon.bak python/pyproject.toml.bak README.md.bak

grep -q "\.version = \"$v\"" build.zig.zon || fail "build.zig.zon does not say $v"
grep -q "^version = \"$v\"" python/pyproject.toml || fail "python/pyproject.toml does not say $v"
grep -q "refs/tags/v$v.tar.gz" README.md || fail "README.md does not install v$v"
echo "v$v: CHANGELOG.md, build.zig.zon, python/pyproject.toml and README.md"
