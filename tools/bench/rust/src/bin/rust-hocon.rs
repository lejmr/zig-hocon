//! A crate as a command, for the end-to-end timings: read, parse, resolve,
//! print compact JSON — the same job as `hocon --json <file>`.
//!
//!   rust-hocon <hocon-rs|hocon|rs.hocon> <file>
fn main() {
    let args: Vec<String> = std::env::args().collect();
    match hocon_bench_rust::parse(&args[1], &args[2]) {
        Ok(json) => println!("{}", serde_json::to_string(&json).unwrap()),
        Err(e) => {
            eprintln!("error: {e}");
            std::process::exit(1);
        }
    }
}
