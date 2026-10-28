# HOCON in Python, benchmarked

I was curious how the other Python HOCON libraries compare, so I benchmarked them: each one that parses HOCON itself, scored against the [conformance suite](../conformance/README.md) and timed on generated config files. The best Rust parser is in the table too, because a PyO3 binding is all it would take to make it a Python library, and so are zig-hocon without Python and typesafe/config, for reference.

| implementation | language / binding | version | spec | 1 KB | 1 MB | 10 MB | notes |
|---|---|---|---:|---:|---:|---:|---|
| zig-hocon | Zig, ctypes over libhocon | v0.5.0-4-g4ae9d03 | 444/445 (99.8 %) | 0.064 ms | 12.1 ms | 130.7 ms | the tree stays in Zig and is read on access |
| pulse-pyhocon | Rust (PyO3), pyhocon fallback | 0.2.1 | 316/445 (71.0 %) | 0.145 ms | 138.7 ms | 2.2 s | native parser on these files; pyhocon on anything it does not support |
| py.hocon (hocon-parser) | pure Python | 1.14.2 | 397/445 (89.2 %) | 0.838 ms | 897.6 ms | 11.1 s |  |
| hocon2 | pure Python | 0.6.3 | 386/445 (86.7 %) | 2.9 ms | > 120 s | > 120 s | quadratic in file size |
| pyhocon | pure Python (pyparsing) | 0.3.63 | 314/445 (70.6 %) | 7.9 ms | 7.7 s | > 120 s |  |
| rs.hocon (hocon-parser) | Rust, no Python binding yet | 1.14.2 | 397/445 (89.2 %) | 0.072 ms | 79.5 ms | 799.8 ms | timed natively; same author and version as py.hocon |
| zig-hocon, native | Zig | v0.5.0-4-g4ae9d03 | 444/445 (99.8 %) | 0.014 ms | 12.3 ms | 132.2 ms | reference: the same core without Python |
| typesafe/config | Java | 1.4.9 | 401/445 (90.1 %) | 0.035 ms | 370.3 ms | 19.8 s | reference implementation; JIT warmed up for 2 s |

Measured on 2026-10-18 on an Apple M4 Pro with 48 GB, macOS 27.0.1, Python 3.12.8, Rust 1.97.1, OpenJDK 27 and Zig 0.16.0.

- **spec**: `conformance/run.sh --spec`, cases passed out of the 445 the suite had then, on v0.5.0. It has 586 now, many of them from fuzzing; the [conformance report](https://htmlpreview.github.io/?https://github.com/lejmr/zig-hocon/blob/main/conformance/report.html) has today's numbers for zig-hocon, typesafe/config and pyhocon. The times are as measured then.
- **1 KB, 1 MB, 10 MB**: files written by `tools/bench/gen.py --refs`, service configs with substitutions in them: values from a shared block, lists and strings built around a reference, whole objects copied, references that chain from one service to the next, and later blocks merged into earlier ones. A cell is the time to parse and resolve text already in memory, inside the process, as the library's own result object (`parse_string` or its equivalent): the median of warm runs. Cold times and whole-command times are in what `run.sh` prints.
- Before a file is timed, the library's output for it is compared with typesafe/config's JSON, and the cell would say "wrong output" if they differed. None did.
- **> 120 s**: the library did not parse the file within two minutes and was cut off.

## What it costs

- **zig-hocon** returns a `ConfigTree` over the document that libhocon holds, so the parse is the native one plus a call. Turning the whole tree into Python dicts with `as_dict()` adds 5 ms at 1 MB and 65 ms at 10 MB.
- **pulse-pyhocon** parses natively in Rust what it supports and hands everything else to pyhocon, parse errors included. That is why its spec score is pyhocon's give or take a case: the cases it does not support run on pyhocon. The bench files all take the native route.
- **rs.hocon** has no Python binding. It is timed natively, so a binding would add the cost of building Python objects on top.
- **pyhocon** took 490 s for the 10 MB file, measured once outside the table.
- **hocon2** grows with the square of the file: 58 ms at 10 KB, 3.4 s at 100 KB.
- **typesafe/config** takes 0.4 s for the 1 MB file and 20 s for the 10 MB one, fifty times as long for ten times the text.

## Not in the table

The table keeps the best parsers: every Python parser of its own above 70 % against the spec, and the best Rust one. These were looked at too and left out:

- **hocon-rs 0.2.0** (Rust, mikai233/hocon-rs): 376/445 (84.5 %), behind rs.hocon. It is the fastest parser here after zig-hocon: 24.8 ms at 1 MB, 290 ms at 10 MB.
- **hocon 0.9.0** (Rust, mockersf/hocon.rs): 319/445 (71.7 %) with its strict loader; the repository is archived since 2023, and it is quadratic too (over two minutes at 1 MB).
- **hocon_** (Rust, pepa65): a republished fork of hocon 0.9.0, not measured on its own.
- **pyhocon-fix 0.0.4** (Python, 2018) and **dd-pyhocon 0.3.61** (Python, 2023): forks of pyhocon, 316/445 (71.0 %) and 314/445 (70.6 %), within two cases of it; dd-pyhocon hangs on one merge-stack case.
- Not parsers of their own: `hocon` 0.3.0, `hocon-validator`, `pytyped-hocon`, `pyhocon-dantic` and `dataconf` wrap pyhocon; `atomr` (Rust/PyO3) builds its `Config` from TOML or a dict and parses no HOCON; chris-martin/hocon-python (2015) is an unfinished port of typesafe/config.

## Reproducing it

```sh
tools/bench/landscape.sh
```

It needs zig, cargo, uv and a JDK, and takes about 40 minutes, most of it waiting for the slow parsers to hit the two-minute cut-off. The Python libraries are pinned in `tools/bench/run.sh` and installed into `zig-out/bench-py*`, the Rust crates in `tools/bench/rust/Cargo.lock`; everything it downloads or writes stays in `zig-out/`. The scores for pyhocon and typesafe/config are the ones in `conformance/reports/`; the rest are measured by the same commands that are timed.
