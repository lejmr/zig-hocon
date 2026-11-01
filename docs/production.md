# Defaults that matter in production

| | Zig | `hocon` | C | Python |
|---|---|---|---|---|
| a `${X}` not in the file reads | nothing: `.env = .none`; pass `.{ .map = init.environ_map }` for the process environment | the process environment; `--env=none` for nothing | the process environment (`HOCON_ENV_PROCESS`, also with `NULL` options); `HOCON_ENV_NONE` for nothing | `os.environ`; `env=None` for nothing |
| an http(s) include | fetched, 30 s per fetch; `.http_timeout` | fetched, 30 s per fetch; no flag to change it | fetched; `http_timeout_ms`, 0 is 30 s | fetched; `http_timeout=`, 30 s by default |

- **http(s) includes cannot be turned off.** No surface has an option for it: a file that includes a URL fetches it, during the parse. The only way to read with no includes at all is to read the text yourself and parse it as text: `parseFromSlice` in Zig, `hocon_parse_string` with `include_dir` left `NULL` in C, `parse_string` without `basedir` in Python. Each of them refuses every include, files too. `hocon` has no such mode: it reads files, and fetches the http(s) URLs they include.
- **Everything is resolved inside the parse call.** Includes are read first, then the substitutions resolve once over the whole document, against the environment as it is at that moment. Keep mode (`.keep`, `--env=keep`, `HOCON_ENV_KEEP`, `env=KEEP`) and reading without resolving (`resolve = false`) leave the `${…}` in, for later.

## Gotchas

- **Variables go last.** A later setting hides an earlier one, and that includes a `${?…}`. If `app.conf` has `workers = ${?WORKERS}` and `prod.conf` sets `workers = 8` after its `include`, `workers` is 8 whatever `WORKERS` says. Put a setting the environment overrides where nothing comes after it, as `prod.conf` does with `${?DB_POOL}`, or in a file that every environment includes last.
- **Unknown keys are skipped.** `.ignore_unknown_fields` defaults to `true`, unlike `std.json`, so a misspelled key is skipped without a word; set it to `false` to catch it. `hocon check --schema` always reads with the default, and has no flag for it: a program that sets `.ignore_unknown_fields = false` refuses such a key, so a file `check` passes can still stop that program.
