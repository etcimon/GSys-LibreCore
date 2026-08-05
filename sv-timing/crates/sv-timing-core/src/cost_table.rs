// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Load fo4-v1.toml into CostModel.

//! Cost model table loading from packaged `resources/fo4-v1.toml`.

use std::path::Path;

use crate::error::{CoreError, CoreResult};
use crate::measure::CostModel;

/// Parse a minimal TOML subset used by fo4-v1 (key = number | string).
/// Avoids a toml crate dependency for v1.
pub fn parse_fo4_toml(text: &str) -> CoreResult<CostModel> {
    let mut model = CostModel::default();
    for raw in text.lines() {
        let line = raw.split('#').next().unwrap_or("").trim();
        if line.is_empty() {
            continue;
        }
        let Some((k, v)) = line.split_once('=') else {
            continue;
        };
        let key = k.trim();
        let val = v.trim().trim_matches('"');
        match key {
            "version" => model.id = val.to_string(),
            "logic_bit" => model.logic_bit = parse_f64(val)?,
            "compare" => model.compare = parse_f64(val)?,
            "shift_const" => model.shift_const = parse_f64(val)?,
            "shift_var" => model.shift_var = parse_f64(val)?,
            "add_sub" => model.add_sub = parse_f64(val)?,
            "mul" => model.mul = parse_f64(val)?,
            "div_rem" => model.div_rem = parse_f64(val)?,
            "mux" => model.mux = parse_f64(val)?,
            "priority_mux_per_level" => model.priority_mux_per_level = parse_f64(val)?,
            "concat" => model.concat = parse_f64(val)?,
            "other" => model.other = parse_f64(val)?,
            _ => {}
        }
    }
    Ok(model)
}

fn parse_f64(s: &str) -> CoreResult<f64> {
    s.parse::<f64>()
        .map_err(|_| CoreError::InvalidOptions(format!("bad fo4 number: {s}")))
}

/// Load cost model from a filesystem path.
pub fn load_cost_model_path(path: impl AsRef<Path>) -> CoreResult<CostModel> {
    let text = std::fs::read_to_string(path.as_ref()).map_err(|source| CoreError::Io {
        path: path.as_ref().to_path_buf(),
        source,
    })?;
    parse_fo4_toml(&text)
}

/// Embedded default table (same as resources/fo4-v1.toml).
pub fn default_fo4_v1_embedded() -> CostModel {
    parse_fo4_toml(include_str!("../../../resources/fo4-v1.toml"))
        .expect("embedded fo4-v1.toml must parse")
}

/// Try package-relative `resources/fo4-v1.toml`, else embedded.
pub fn load_fo4_v1_default() -> CostModel {
    let candidates = [
        Path::new("resources/fo4-v1.toml"),
        Path::new("../resources/fo4-v1.toml"),
        Path::new("../../resources/fo4-v1.toml"),
    ];
    for c in candidates {
        if c.is_file() {
            if let Ok(m) = load_cost_model_path(c) {
                return m;
            }
        }
    }
    default_fo4_v1_embedded()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn embedded_fo4_matches_mul() {
        let m = default_fo4_v1_embedded();
        assert_eq!(m.id, "fo4-v1");
        assert!((m.mul - 56.0).abs() < 1e-9);
        assert!((m.add_sub - 10.0).abs() < 1e-9);
    }
}
