//! In-process parse times, the Rust side of tools/bench/run.sh.
//!
//!   rust-bench <hocon-rs|hocon> <file>...
//!
//! Prints `<file>\t<median ns>\t<runs>\t<first ns>` per file: the first run on
//! its own, then runs until a second has passed and at least five are in. A
//! first run over 30 s is reported alone rather than repeated. The JSON conversion is
//! not timed, only the crate's own parse and resolve.
use std::time::Instant;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let crate_name = &args[1];
    for path in &args[2..] {
        let text = std::fs::read_to_string(path).expect("read");
        let run = || -> u128 {
            let start = Instant::now();
            match crate_name.as_str() {
                "hocon-rs" => {
                    std::hint::black_box(hocon_rs::Config::parse_str::<hocon_rs::Value>(&text, None).expect("parse"));
                }
                _ => {
                    let l = hocon::HoconLoader::new().strict().load_str(&text).expect("parse");
                    std::hint::black_box(l.hocon().expect("resolve"));
                }
            }
            start.elapsed().as_nanos()
        };
        let first = run();
        if first > 30_000_000_000 {
            println!("{}\t{}\t1\t{}", path, first, first);
            continue;
        }
        let mut times = Vec::new();
        let mut total = 0u128;
        while times.len() < 5 || total < 1_000_000_000 {
            let t = run();
            times.push(t);
            total += t;
        }
        times.sort();
        println!("{}\t{}\t{}\t{}", path, times[times.len() / 2], times.len(), first);
    }
}
