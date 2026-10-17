## Agent skills

### Issue tracker

Issues live in GitHub Issues for lejmr/zig-hocon, managed via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five-role vocabulary: needs-triage, needs-info, ready-for-agent, ready-for-human, wontfix. See `docs/agents/triage-labels.md`.

The maintainer writes all implementation (`src/`) by hand, so implementation issues get `ready-for-human`. Reserve `ready-for-agent` for tests, tooling (`tools/`, `conformance/`) and docs.

### Domain docs

Single-context: one `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.

## Branches and agent worktrees

- `main` is the public release line, a release is a tag (`v0.1.0`) that only the Release workflow makes (CONTRIBUTING.md, Releasing). Commits are conventional, and a user-visible `feat`/`fix` gets a CHANGELOG.md line. `dev` is the integration branch and stays on this machine: work there is committed locally, never pushed, no PRs.
- Agents work in herdr worktrees on `agent/<issue>-…` branches and implement `src/` there too. Text sitting unsent in an agent's input is the maintainer's draft; act on what this session asks.
- Branches stack: each one sits on the branch below it (`dev` ← #6 ← #5 ← …). The maintainer decides when anything is squashed into `dev`; after a squash, move the next branch with `git rebase --onto dev <old tip> <branch> --update-refs`.

### Restacking a branch

When asked to rebase an agent branch onto another one:

1. Back up the old tip as `backup/<issue>-before-<what>`. Rebase a copy branch in a scratch worktree, so the agent's worktree and its uncommitted files stay as they are.
2. Uncommitted agent work gets committed first — one commit per conformance suite section where it splits cleanly. `.idea/` and stray files like `test.conf` stay out.
3. Resolve conflicts by keeping the lower branch's logic and porting the upper branch's feature onto it. Code the lower branch made obsolete goes; tests it made wrong are rewritten to the new behaviour, with the reason in a comment.
4. Generated files (`conformance/reports/`, the `conformance:start` block in `README.md`, `conformance/report.html`) take the lower branch's version on conflict. Regenerate them by running `sh tools/hooks/pre-push` after committing; it measures HEAD and amends the results in.
5. Done when: `zig build test` is green, `zig fmt --check src` is clean, `conformance/run.sh --spec` and `--java` are at least the lower branch's score, and every error the stack introduces has a caret test (once #5 is in the stack).
6. Move the agent's branch onto the result with `git -C <agent worktree> reset --keep <new tip>`, then remove the scratch worktree and the copy branch.
