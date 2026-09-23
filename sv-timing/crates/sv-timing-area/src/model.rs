// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Load area-v1.toml. Weights are placeholder until a mapped netlist calibrates them.

//! Area weight table. The parser accepts the same `key = number` subset as
//! `parse_fo4_toml` and requires every area key.

use std::path::Path;

use sv_timing_core::OperatorClass;
use thiserror::Error;

/// Keys that `resources/area-v1.toml` must contain, besides `version`.
pub const REQUIRED_AREA_KEYS: &[&str] = &[
    "logic_bit",
    "compare",
    "shift_const",
    "shift_var",
    "add_sub",
    "mux",
    "priority_mux_per_level",
    "concat",
    "other",
    "flop",
    "mul_at_w32",
    "div_rem_per_bit",
];

/// Structural area weights. Units are area units from the loaded table.
#[derive(Debug, Clone, PartialEq)]
pub struct AreaModel {
    /// Model id. The packaged table uses `area-v1`.
    pub id: String,
    /// Per resolved bit of bitwise logic.
    pub logic_bit: f64,
    /// Per resolved bit of a compare.
    pub compare: f64,
    /// Constant shift. Wiring; the placeholder may be nonzero.
    pub shift_const: f64,
    /// Per resolved bit of a variable shift.
    pub shift_var: f64,
    /// Per resolved bit of an add or subtract.
    pub add_sub: f64,
    /// Per resolved bit of a 2:1 mux, also the case-select surcharge base.
    pub mux: f64,
    /// Per resolved bit of one priority-mux level.
    pub priority_mux_per_level: f64,
    /// Concatenation. Wiring.
    pub concat: f64,
    /// Unclassified operator, including an unlowered call.
    pub other: f64,
    /// Per resolved storage bit.
    pub flop: f64,
    /// Multiply area at width 32. Other widths scale by `(w/32)^2`.
    pub mul_at_w32: f64,
    /// Combinational divide or remainder, per resolved bit.
    pub div_rem_per_bit: f64,
}

/// Errors while reading an area table.
#[derive(Debug, Error, PartialEq)]
pub enum AreaError {
    /// A line was not `key = value`.
    #[error("invalid area table line: {0}")]
    BadLine(String),
    /// A numeric value did not parse.
    #[error("bad area number for {key}: {value}")]
    BadNumber {
        /// Table key.
        key: String,
        /// Source text.
        value: String,
    },
    /// A key was repeated.
    #[error("duplicate area key: {0}")]
    DuplicateKey(String),
    /// A key is not part of area-v1.
    #[error("unknown area key: {0}")]
    UnknownKey(String),
    /// A required key was absent.
    #[error("missing area key: {0}")]
    MissingKey(String),
    /// The version string was empty.
    #[error("area table version is empty")]
    EmptyVersion,
    /// Filesystem read failed.
    #[error("io error for {path}: {message}")]
    Io {
        /// Path that failed.
        path: String,
        /// OS message.
        message: String,
    },
}

/// Result alias for area-table loads.
pub type AreaResult<T> = Result<T, AreaError>;

impl AreaModel {
    /// Area of one operator of `class` at `width_bits`.
    ///
    /// Width 0 is treated as unresolved width 1. Multiply uses
    /// [`mul_area_at_width`]. Other classes scale the table base by the width.
    pub fn operator_area(&self, class: OperatorClass, width_bits: u32) -> f64 {
        let width = width_bits.max(1);
        let bits = f64::from(width);
        match class {
            OperatorClass::Mul => mul_area_at_width(self, width),
            OperatorClass::DivRem => self.div_rem_per_bit * bits,
            OperatorClass::LogicBit => self.logic_bit * bits,
            OperatorClass::Compare => self.compare * bits,
            OperatorClass::ShiftConst => self.shift_const * bits,
            OperatorClass::ShiftVar => self.shift_var * bits,
            OperatorClass::AddSub => self.add_sub * bits,
            OperatorClass::Mux => self.mux * bits,
            OperatorClass::PriorityMux => self.priority_mux_per_level * bits,
            OperatorClass::Concat => self.concat * bits,
            OperatorClass::Other => self.other * bits,
        }
    }
}

/// Multiply area at `width_bits`.
///
/// Unresolved width is 1. The result is
/// `max(mul_at_w32 * (w/32)^2, logic_bit)` with `w = max(width_bits, 1)`.
pub fn mul_area_at_width(model: &AreaModel, width_bits: u32) -> f64 {
    let w = f64::from(width_bits.max(1));
    let ratio = w / 32.0;
    let scaled = model.mul_at_w32 * ratio * ratio;
    scaled.max(model.logic_bit)
}

/// Parse `area-v1` text. Every [`REQUIRED_AREA_KEYS`] entry must appear once.
pub fn parse_area_toml(text: &str) -> AreaResult<AreaModel> {
    let mut id: Option<String> = None;
    let mut values: [Option<f64>; 12] = [None; 12];
    for raw in text.lines() {
        let line = raw.split('#').next().unwrap_or("").trim();
        if line.is_empty() {
            continue;
        }
        let Some((k, v)) = line.split_once('=') else {
            return Err(AreaError::BadLine(line.to_string()));
        };
        let key = k.trim();
        let val = v.trim().trim_matches('"');
        if key == "version" {
            if id.is_some() {
                return Err(AreaError::DuplicateKey(key.to_string()));
            }
            if val.is_empty() {
                return Err(AreaError::EmptyVersion);
            }
            id = Some(val.to_string());
            continue;
        }
        let Some(idx) = REQUIRED_AREA_KEYS.iter().position(|name| *name == key) else {
            return Err(AreaError::UnknownKey(key.to_string()));
        };
        if values[idx].is_some() {
            return Err(AreaError::DuplicateKey(key.to_string()));
        }
        let number = val.parse::<f64>().map_err(|_| AreaError::BadNumber {
            key: key.to_string(),
            value: val.to_string(),
        })?;
        if !number.is_finite() {
            return Err(AreaError::BadNumber {
                key: key.to_string(),
                value: val.to_string(),
            });
        }
        values[idx] = Some(number);
    }
    let id = id.ok_or_else(|| AreaError::MissingKey("version".to_string()))?;
    let mut numbers = [0.0; 12];
    for (idx, name) in REQUIRED_AREA_KEYS.iter().enumerate() {
        numbers[idx] = values[idx].ok_or_else(|| AreaError::MissingKey((*name).to_string()))?;
    }
    Ok(AreaModel {
        id,
        logic_bit: numbers[0],
        compare: numbers[1],
        shift_const: numbers[2],
        shift_var: numbers[3],
        add_sub: numbers[4],
        mux: numbers[5],
        priority_mux_per_level: numbers[6],
        concat: numbers[7],
        other: numbers[8],
        flop: numbers[9],
        mul_at_w32: numbers[10],
        div_rem_per_bit: numbers[11],
    })
}

/// Load an area table from a filesystem path.
pub fn load_area_model_path(path: impl AsRef<Path>) -> AreaResult<AreaModel> {
    let path_ref = path.as_ref();
    let text = std::fs::read_to_string(path_ref).map_err(|err| AreaError::Io {
        path: path_ref.display().to_string(),
        message: err.to_string(),
    })?;
    parse_area_toml(&text)
}

/// Embedded packaged table (`resources/area-v1.toml`).
pub fn default_area_v1_embedded() -> AreaModel {
    parse_area_toml(include_str!("../../../resources/area-v1.toml"))
        .expect("embedded area-v1.toml must parse")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn packaged_table_parses_every_key() {
        let text = include_str!("../../../resources/area-v1.toml");
        assert!(
            text.contains("not a mapped-netlist measurement"),
            "placeholder comment must say the numbers are not calibrated"
        );
        let model = parse_area_toml(text).expect("packaged table");
        assert_eq!(model.id, "area-v1");
        let loaded = [
            model.logic_bit,
            model.compare,
            model.shift_const,
            model.shift_var,
            model.add_sub,
            model.mux,
            model.priority_mux_per_level,
            model.concat,
            model.other,
            model.flop,
            model.mul_at_w32,
            model.div_rem_per_bit,
        ];
        for (key, value) in REQUIRED_AREA_KEYS.iter().zip(loaded) {
            assert!(text.contains(key), "missing key line {key}");
            assert!(value.is_finite(), "{key} must be finite");
        }
        let unresolved = mul_area_at_width(&model, 0);
        let ratio = 1.0_f64 / 32.0;
        let formula = (model.mul_at_w32 * ratio * ratio).max(model.logic_bit);
        assert_eq!(unresolved, formula);
        assert_eq!(mul_area_at_width(&model, 1), formula);
    }

    #[test]
    fn missing_required_key_errors() {
        let err = parse_area_toml("version = \"area-v1\"\nlogic_bit = 1\n").unwrap_err();
        assert!(matches!(err, AreaError::MissingKey(_)));
    }

    #[test]
    fn unknown_key_errors() {
        let mut text = include_str!("../../../resources/area-v1.toml").to_string();
        text.push_str("\nextra = 1\n");
        let err = parse_area_toml(&text).unwrap_err();
        assert_eq!(err, AreaError::UnknownKey("extra".to_string()));
    }
}
