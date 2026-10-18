//! One entry point per crate, for the command (`rust-hocon`): read a file,
//! parse, resolve. All resolve while loading, the same work the other
//! implementations do. Reading through each crate's file API resolves includes
//! beside the file, so the command doubles as a conformance adapter.

pub fn parse(crate_name: &str, path: &str) -> Result<serde_json::Value, String> {
    match crate_name {
        "hocon-rs" => hocon_rs::Config::load::<hocon_rs::Value>(path, None)
            .map(Into::into)
            .map_err(|e| e.to_string()),
        // strict(): the crate's default replaces what it cannot read with a
        // placeholder instead of failing, which is not the same work.
        "hocon" => {
            let loaded = hocon::HoconLoader::new().strict().load_file(path).map_err(|e| e.to_string())?;
            to_json(&loaded.hocon().map_err(|e| e.to_string())?)
        }
        "rs.hocon" => {
            let config = rs_hocon::parse_file(path).map_err(|e| e.to_string())?;
            // ponytail: no root accessor, so each top-level key is looked up quoted
            let mut map = serde_json::Map::new();
            for key in config.keys() {
                let quoted = format!("\"{}\"", key.replace('\\', "\\\\").replace('"', "\\\""));
                map.insert(key.to_string(), rs_to_json(config.get(&quoted).ok_or("top-level key lookup")?)?);
            }
            Ok(serde_json::Value::Object(map))
        }
        other => Err(format!("unknown crate {other}")),
    }
}

/// `Hocon` has no Serialize. As the crate's own serde layer: a field holding a
/// BadValue reads as absent, a BadValue anywhere else is an error.
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
            J::Object(map.iter().filter(|(_, v)| !matches!(v, hocon::Hocon::BadValue(_)))
                .map(|(k, v)| Ok((k.clone(), to_json(v)?))).collect::<Result<_, String>>()?)
        }
    })
}

/// rs.hocon keeps numbers and booleans as their source text.
fn rs_to_json(v: &rs_hocon::HoconValue) -> Result<serde_json::Value, String> {
    use rs_hocon::{HoconValue, ScalarType};
    use serde_json::Value as J;
    Ok(match v {
        HoconValue::Object(map) => {
            J::Object(map.iter().map(|(k, v)| Ok((k.clone(), rs_to_json(v)?))).collect::<Result<_, String>>()?)
        }
        HoconValue::Array(items) => J::Array(items.iter().map(rs_to_json).collect::<Result<_, _>>()?),
        HoconValue::Scalar(s) => match s.value_type {
            ScalarType::Null => J::Null,
            // `01` or `1.` is not JSON but the crate accepts it as a number:
            // what it means to the crate is what gets compared
            ScalarType::Boolean | ScalarType::Number => serde_json::from_str(&s.raw)
                .or_else(|_| s.raw.parse::<f64>().map(J::from))
                .map_err(|e| e.to_string())?,
            ScalarType::String => J::String(s.raw.clone()),
            _ => return Err("unknown scalar type".into()),
        },
        _ => return Err("unresolved placeholder in output".into()),
    })
}
