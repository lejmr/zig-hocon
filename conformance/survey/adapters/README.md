# Survey adapters

One adapter per implementation measured in `../REPORT.md`, each speaking the `run.sh` contract of `conformance/adapters/example.sh`: one `.conf` path in, compact JSON out, non-zero to reject, `--version` for the label. `bin/<name>.sh` is what `run.sh` is pointed at; the directories beside it hold the small programs those scripts call. Build artifacts are produced in place and git-ignored (`.gitignore`).

| bin/ | implementation | needs |
|---|---|---|
| `java-1.4.9.sh` | typesafe/config 1.4.9 | this repository's oracle (`conformance/adapters/oracle.sh hocon-java`) through `javashim/` |
| `lightbend-main.sh` | typesafe/config main | `lightbend-main/LightbendAdapter.java` compiled against a build of lightbend/config main into `lightbend-main/classes` |
| `sconfig.sh` | ekrich/sconfig 2.1.0 | `sconfig/SconfigAdapter.java` and the sconfig_3 2.1.0, scala3-library, scala-library and scala-collection-compat jars from Maven Central in `sconfig/` |
| `ruby-hocon.sh` | puppetlabs/ruby-hocon 1.4.0 | `make ruby` |
| `cpp-hocon.sh` | puppetlabs/cpp-hocon 4981ed4 | `cpp/adapter.cc` built against cpp-hocon and leatherman into `cpp/cpp-hocon-adapter` |
| `akkadotnet-hocon.sh` | akkadotnet/HOCON (NuGet Hocon 2.0.4) | `dotnet publish -o out` in `dotnet/`, a .NET SDK under `$TOOLS/dotnet` |
| `emqx-hocon.sh` | emqx/hocon 7759b15 | `erlang/emqx_hocon_adapter.escript`, an emqx/hocon clone built with rebar3 under `$IMPL/emqx_hocon` |
| `go.hocon.sh`, `gurkankaymak-hocon.sh`, `go-akka-configuration.sh` | o3co/go.hocon, gurkankaymak/hocon, go-akka/configuration | `make go` |
| `ts.hocon.sh`, `pushcorn-hocon-parser.sh`, `hocon-parser-js.sh` | @o3co/ts.hocon, @pushcorn/hocon-parser, hocon-parser (npm) | `make ts` |
| `rs.hocon.sh`, `hocon-rs.sh`, `mockersf-hocon.sh` | o3co/rs.hocon, mikai233/hocon-rs, mockersf/hocon.rs | `make rust` |
| `pyhocon.sh`, `hocon2.sh`, `py.hocon.sh`, `pulse-pyhocon.sh` | pyhocon 0.3.63, hocon2 0.6.3, o3co/py.hocon, pulse-pyhocon 0.2.1 | `make py` makes `py-adapters/venv` (pyhocon); pulse-pyhocon is installed into the same venv, hocon2 into `venv-hocon2`, hocon-parser (o3co/py.hocon) into `venv-o3` |

`javashim/java` adds `-Dstdout.encoding=UTF-8 -Dfile.encoding=UTF-8`: `run.sh` runs adapters under `env -i`, and a JVM without a locale prints `?` for every non-ASCII character.

## Provenance

`Makefile`, `go-adapters/`, `ts-adapters/`, `rust-adapters/`, `ruby-adapters/` and `py-adapters/adapters/{pyhocon,hocon}_adapter.py` come from the `ecosystem-bench` directory of [o3co/xx.hocon](https://github.com/o3co/xx.hocon) at `38d02ca`, under the Apache License 2.0 (`LICENSE.ecosystem-bench`). Changed from there: `go.mod`/`go.sum`, `rust-adapters/Cargo.{toml,lock}` and `ts-adapters/package.json` (dependency versions), `rust-adapters/src/bin/{mikai,mockersf}.rs`, `ts-adapters/adapters/o3co.mjs` (`parseFile`, so includes resolve), `py-adapters/adapters/hocon_adapter.py` (`default=str`). Everything else here was written for this survey.
