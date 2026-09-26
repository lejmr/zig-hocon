//! One entry point per crate, so the timing loop and the command share it.
//! Both resolve while loading, the same work the other implementations do.

pub fn parse(crate_name: &str, text: &str) -> Result<serde_json::Value, String> {
    match crate_name {
        "hocon-rs" => hocon_rs::Config::parse_str::<hocon_rs::Value>(text, None)
            .map(Into::into)
            .map_err(|e| e.to_string()),
        // strict(): the crate's default replaces what it cannot read with a
        // placeholder instead of failing, which is not the same work.
        "hocon" => {
            let loaded = hocon::HoconLoader::new().strict().load_str(text).map_err(|e| e.to_string())?;
            to_json(&loaded.hocon().map_err(|e| e.to_string())?)
        }
        other => Err(format!("unknown crate {other}")),
    }
}

/// `Hocon` has no Serialize.
fn to_json(h: &hocon::Hocon) -> Result<serde_json::Value, String> {
    use serde_json::Value as J;
    Ok(match h {
        hocon::Hocon::Real(f) => J::from(*f),
        hocon::Hocon::Integer(i) => J::from(*i),
        hocon::Hocon::String(s) => J::String(s.clone()),
        hocon::Hocon::Boolean(b) => J::Bool(*b),
        hocon::Hocon::Null => J::Null,
        hocon::Hocon::BadValue(e) => return Err(e.to_string()),
        hocon::Hocon::Array(items) => J::Array(items.iter().map(to_json).collect::<Result<_, _>>()?),
        hocon::Hocon::Hash(map) => {
            J::Object(map.iter().map(|(k, v)| Ok((k.clone(), to_json(v)?))).collect::<Result<_, String>>()?)
        }
    })
}
