# HOCON in Python, benchmarked

I was curious how the other Python HOCON libraries compare, so I benchmarked them: each one that parses HOCON itself, scored against the [conformance suite](../conformance/README.md) and timed on generated config files. The best Rust parser is in the table too, because a PyO3 binding is all it would take to make it a Python library, and so are zig-hocon without Python and typesafe/config, for reference.

| implementation | language / binding | version | spec | 1 KB | 1 MB | 10 MB | notes |
|---|---|---|---:|---:|---:|---:|---|
| zig-hocon | Zig, ctypes over libhocon | v0.5.3-23-gca6d6f4 | 588/588 (100.0 %) | 0.093 ms | 12.6 ms | 135.7 ms | the tree stays in Zig and is read on access |
| pulse-pyhocon | Rust (PyO3), pyhocon fallback | 0.2.1 | 384/588 (65.3 %) | 0.144 ms | 144.0 ms | 2.2 s | native parser on these files; pyhocon on anything it does not support |
| py.hocon (hocon-parser) | pure Python | 1.14.2 | 466/588 (79.3 %) | 0.837 ms | 924.0 ms | 11.2 s |  |
| hocon2 | pure Python | 0.6.3 | 476/588 (81.0 %) | 2.9 ms | > 120 s | > 120 s | quadratic in file size |
| pyhocon | pure Python (pyparsing) | 0.3.63 | 379/588 (64.5 %) | 8.0 ms | 8.0 s | > 120 s |  |
| rs.hocon (hocon-parser) | Rust, no Python binding yet | 1.14.2 | 463/588 (78.7 %) | 0.074 ms | 80.9 ms | 879.6 ms | timed natively; same author and version as py.hocon |
| zig-hocon, native | Zig | v0.5.3-23-gca6d6f4 | 588/588 (100.0 %) | 0.014 ms | 12.6 ms | 136.5 ms | reference: the same core without Python |
| typesafe/config | Java | 1.4.9 | 497/588 (84.5 %) | 0.035 ms | 388.4 ms | 21.1 s | reference implementation; JIT warmed up for 2 s |

Measured on 2026-10-28, the spec scores again on 2026-10-30 after the suite settled its readings (#56), on an Apple M4 Pro with 48 GB, macOS 27.0.1, Python 3.12.8, Rust 1.97.1, OpenJDK 27 and Zig 0.16.0.

- **spec**: `conformance/run.sh --spec`, cases passed out of the suite's 588, many of them from fuzzing; the [conformance report](https://htmlpreview.github.io/?https://github.com/lejmr/zig-hocon/blob/main/conformance/report.html) has the cases each fails.
- **1 KB, 1 MB, 10 MB**: files written by `tools/bench/gen.py --refs`, service configs with substitutions in them: values from a shared block, lists and strings built around a reference, whole objects copied, references that chain from one service to the next, and later blocks merged into earlier ones. A cell is the time to parse and resolve text already in memory, inside the process, as the library's own result object (`parse_string` or its equivalent): the median of warm runs. Cold times and whole-command times are in what `run.sh` prints.
- Before a file is timed, the library's output for it is compared with typesafe/config's JSON, and the cell would say "wrong output" if they differed. None did.
- **> 120 s**: the library did not parse the file within two minutes and was cut off.

## What it costs

- **zig-hocon** returns a `ConfigTree` over the document that libhocon holds, so the parse is the native one plus a call. Turning the whole tree into Python dicts with `as_dict()` adds 5 ms at 1 MB and 65 ms at 10 MB.
- **pulse-pyhocon** parses natively in Rust what it supports and hands everything else to pyhocon, parse errors included. That is why its spec score is pyhocon's give or take a case: the cases it does not support run on pyhocon. The bench files all take the native route.
- **rs.hocon** has no Python binding. It is timed natively, so a binding would add the cost of building Python objects on top.
- **pyhocon** took 490 s for the 10 MB file, measured once outside the table.
- **hocon2** grows with the square of the file: 58 ms at 10 KB, 3.4 s at 100 KB.
- **typesafe/config** takes 0.4 s for the 1 MB file and 21 s for the 10 MB one, fifty times as long for ten times the text. Its JVM needs more than 4 GB of heap for the 10 MB file.

## Not in the table

The table keeps pyhocon, every Python parser of its own above 60 % against the spec, and the best Rust one. These were looked at too and left out:

- **hocon-rs 0.2.0** (Rust, mikai233/hocon-rs): 448/588 (76.2 %), behind rs.hocon. It is the fastest parser here after zig-hocon: 27.0 ms at 1 MB, 299.7 ms at 10 MB.
- **hocon 0.9.0** (Rust, mockersf/hocon.rs): 381/588 (64.8 %) with its strict loader; the repository is archived since 2023, and it is quadratic too (over two minutes at 1 MB).
- **hocon_** (Rust, pepa65): a republished fork of hocon 0.9.0, not measured on its own.
- **pyhocon-fix 0.0.4** (Python, 2018) and **dd-pyhocon 0.3.61** (Python, 2023): forks of pyhocon, within two cases of it on the 445-case suite of 2026-10-18 (316 and 314), not measured again; dd-pyhocon hangs on one merge-stack case.
- Not parsers of their own: `hocon` 0.3.0, `hocon-validator`, `pytyped-hocon`, `pyhocon-dantic` and `dataconf` wrap pyhocon; `atomr` (Rust/PyO3) builds its `Config` from TOML or a dict and parses no HOCON; chris-martin/hocon-python (2015) is an unfinished port of typesafe/config.

## Reproducing it

```sh
tools/bench/landscape.sh
```

It needs zig, cargo, uv and a JDK, and takes about 40 minutes, most of it waiting for the slow parsers to hit the two-minute cut-off. The Python libraries are pinned in `tools/bench/run.sh` and installed into `zig-out/bench-py*`, the Rust crates in `tools/bench/rust/Cargo.lock`; everything it downloads or writes stays in `zig-out/`. The scores for pyhocon and typesafe/config are the ones in `conformance/reports/`; the rest are measured by the same commands that are timed.
