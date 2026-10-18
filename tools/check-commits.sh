#!/bin/sh
# Every commit in <base>..<head> has a conventional subject:
#   type(scope)!: what changed
# with type one of the list below; scope and ! are optional. Merge commits
# are skipped.
#
#   tools/check-commits.sh origin/main HEAD
set -eu
types='feat|fix|perf|refactor|docs|test|build|ci|chore|revert'
# Squashed before the rule, and published since: history is not rewritten.
older='0e0abe6'
git log --no-merges --format='%h %s' "$1..$2" | while read -r sha subject; do
    case " $older " in *" $sha "*) continue ;; esac
    if ! printf '%s\n' "$subject" | grep -Eq "^($types)(\([a-z0-9/._-]+\))?!?: .+"; then
        echo "$sha: not a conventional commit: $subject"
        echo "  want: <$(echo "$types" | tr '|' ',')>(scope)?: subject"
        exit 1
    fi
done
