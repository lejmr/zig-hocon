# Contributing

## Workflow

1. Open a pull request. If it's not ready for review yet, mark it as a
   **draft** — draft is also the default state for anything that isn't
   passing CI yet.
2. A PR is only taken out of draft / considered for review once **CI is
   green** (`zig fmt --check` and `zig build test` both pass). Red CI = draft,
   no exceptions.
3. One feature or fix per PR. If you're implementing more than one item from
   the [README feature checklist](README.md#features), split it into separate
   PRs — smaller PRs get reviewed faster.
4. If you're proposing a feature not yet on the checklist, open an issue
   first to discuss scope before investing time in a PR.

## Requirements for a mergeable PR

- `zig fmt --check .` passes.
- `zig build test` passes, including a new test for whatever you added or
  fixed.
- If your PR implements a checklist item in the README, tick it off in the
  same PR.

## Local setup

Requires Zig 0.16.0.

```sh
zig fmt --check .
zig build test
git config core.hooksPath tools/hooks    # once per clone
```

The hook keeps zig-hocon's conformance results current. Before a push it
checks whether `conformance/reports/zig-hocon.*.json` were measured on the code
in HEAD; if not, it builds HEAD, runs the suite (about 25 seconds), and amends
the fresh results into your last commit — or adds a commit on top when that one
is already on the server. The push then stops once; push again and it goes
through with the results included. `git push --no-verify` skips it.
