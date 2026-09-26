//! A crate as a command, for the end-to-end timings: read, parse, resolve,
//! print compact JSON — the same job as `hocon <file>`.
//!
//!   rust-hocon <hocon-rs|hocon> <file>
fn main() {
    let args: Vec<String> = std::env::args().collect();
    let text = std::fs::read_to_string(&args[2]).expect("read");
    match hocon_bench_rust::parse(&args[1], &text) {
        Ok(json) => println!("{}", serde_json::to_string(&json).unwrap()),
        Err(e) => {
            eprintln!("error: {e}");
            std::process::exit(1);
        }
    }
}
