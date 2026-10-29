# Contributing

## Workflow

1. Open a pull request. If it's not ready for review yet, mark it as a **draft** — draft is also the default state for anything that isn't passing CI yet.
2. A PR is only taken out of draft / considered for review once **CI is green** (`zig fmt --check` and `zig build test` both pass). Red CI = draft, no exceptions.
3. One feature or fix per PR. If you're implementing more than one item from the [spec checklist](docs/spec.md), split it into separate PRs — smaller PRs get reviewed faster.
4. If you're proposing a feature not yet on the checklist, open an issue first to discuss scope before investing time in a PR.

## Requirements for a mergeable PR

- `zig fmt --check .` passes.
- `zig build test` passes, including a new test for whatever you added or fixed.
- If your PR implements an item of the spec checklist, tick it off in the same PR.

## Local setup

Requires Zig 0.16.0.

```sh
zig fmt --check .
zig build test
git config core.hooksPath tools/hooks    # once per clone
```

The hook keeps zig-hocon's conformance results current. Before a push it checks whether `conformance/reports/zig-hocon.*.json` were measured on the code in HEAD; if not, it builds HEAD, runs the suite (about 25 seconds), and amends the fresh results into your last commit — or adds a commit on top when that one is already on the server. The push then stops once; push again and it goes through with the results included. `git push --no-verify` skips it.

## Commits

Conventional commits: `type(scope): what changed`, with type one of `feat`, `fix`, `perf`, `refactor`, `docs`, `test`, `build`, `ci`, `chore`, `revert`, and `!` after it for a change that breaks something. CI checks every commit a pull request brings (`tools/check-commits.sh`).

A `feat` or a `fix` someone using the library would notice also gets a line under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md), written for them: what they can do now, or what works that did not.

## Versions

What a version promises, to someone who pins one:

- **A patch release (0.5.3 → 0.5.4) does not change what a config means.** It fixes a crash or an error that should not be one, each under *Fixed* in CHANGELOG.md, with the input that shows it. A config that read fine reads the same, even where it read against the spec.
- **A change of what a valid config reads as goes into a minor release (0.5 → 0.6),** under *Changed* in CHANGELOG.md, with the old and the new value: a value that was read against the spec, a spec reading revisited, a default that is different.
- **Nothing is renamed or removed** in the Zig API, `c/hocon.h` or the Python package; something new is added beside it (see the compatibility rules in CLAUDE.md).
- **A wheel built for a pull request or a branch is `X.Y.Z+g<commit>`**, a local version PyPI refuses, so it is never taken for the release of the same number. Only the Release workflow builds `X.Y.Z` itself.

## Releasing

One version, one tag, everything at once: the Zig package, libhocon for C and the Python package. A release is **Actions → Release → Run workflow** on `main`, with the version. It refuses a version that has a tag already or that CHANGELOG.md has nothing for, runs every test on Linux, macOS and Windows and every wheel on each Python, and only then commits `chore(release): vX.Y.Z` (CHANGELOG.md, `build.zig.zon`, `python/pyproject.toml` and the README's install line), tags it, and publishes the GitHub release, with the CHANGELOG.md section as its notes and the wheels and C zips attached, and the wheels on PyPI. `dry_run` does all of it but push, and publishes to TestPyPI instead.

Once, before the first release: on PyPI and on TestPyPI, add a pending publisher for the project `zig-hocon`, repository `lejmr/zig-hocon`, workflow `release.yml`, environment `pypi` (on TestPyPI: `testpypi`), and create the two environments in the repository settings.
