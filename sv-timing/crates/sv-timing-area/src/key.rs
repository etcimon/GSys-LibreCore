// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Area cache key. Target megahertz is in this key and not in the design key.

//! Sorted record hashed to `area_key`. Effort and job count are not fields.

use sha2::{Digest, Sha256};
use sv_timing_core::lower_fields_cover;

/// Inputs to [`area_key`]. `decls` and `fn_bodies` are 0 until those fields exist.
pub struct AreaKeyParts<'a> {
    /// Area model id.
    pub area_model: &'a str,
    /// Area report schema id.
    pub area_schema: &'a str,
    /// Raw `area-v1.toml` bytes.
    pub area_table: &'a [u8],
    /// FO4 cost-model id stored on the design.
    pub cost_model: &'a str,
    /// 1 when the key claims declaration text.
    pub decls: u8,
    /// Design cache key.
    pub design_key: &'a str,
    /// 1 when the key claims function bodies.
    pub fn_bodies: u8,
    /// FO4 delay in picoseconds.
    pub fo4_ps: f64,
    /// Canonical inclusion text.
    pub inclusion: &'a str,
    /// IR version.
    pub ir: &'a str,
    /// Budget margin.
    pub margin: f64,
    /// Measurement version.
    pub measurement: &'a str,
    /// [`sv_timing_core::ParamMap::value_canonical`].
    pub param_values: &'a str,
    /// Path-class detector version, decimal text.
    pub path_class: &'a str,
    /// Caller target. Not part of `design_key`.
    pub target_mhz: f64,
    /// Structural mark model id. Not an FO4 input.
    pub marks_model: &'a str,
}

/// 17 significant digits, Rust `{:.16e}`.
pub fn canon_f64(value: f64) -> String {
    format!("{value:.16e}")
}

/// SHA-256 hex of the sorted area-key record.
pub fn area_key(parts: &AreaKeyParts<'_>) -> String {
    sha256_hex(area_key_record(parts).as_bytes())
}

/// The record itself. Used to show that job count is not a field.
pub fn area_key_record(parts: &AreaKeyParts<'_>) -> String {
    let mut lines = [
        format!("area_model={}", parts.area_model),
        format!("area_schema={}", parts.area_schema),
        format!("area_table={}", sha256_hex(parts.area_table)),
        format!("cost_model={}", parts.cost_model),
        format!("decls={}", parts.decls),
        format!("design_key={}", parts.design_key),
        format!("fn_bodies={}", parts.fn_bodies),
        format!("fo4_ps={}", canon_f64(parts.fo4_ps)),
        format!("inclusion={}", parts.inclusion),
        format!("ir={}", parts.ir),
        format!("margin={}", canon_f64(parts.margin)),
        format!("marks_model={}", parts.marks_model),
        format!("measurement={}", parts.measurement),
        format!("param_values={}", parts.param_values),
        format!("path_class={}", parts.path_class),
        format!("target_mhz={}", canon_f64(parts.target_mhz)),
    ];
    lines.sort();
    lines.join("\n")
}

/// True when a report with these claims may be stored.
///
/// A pre-field design, or a key that claims `decls` / `fn_bodies` the lowerer
/// did not write, is not stored.
pub fn may_store_area_report(decls: u8, fn_bodies: u8, emitted: &[String]) -> bool {
    if !lower_fields_cover(emitted) {
        return false;
    }
    if decls == 1 && !emitted.iter().any(|name| name == "decls") {
        return false;
    }
    if fn_bodies == 1 && !emitted.iter().any(|name| name == "fn_bodies") {
        return false;
    }
    true
}

fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

#[cfg(test)]
mod tests {
    use super::*;
    use sv_timing_core::emitted_lower_field_names;

    fn sample<'a>(
        table: &'a [u8],
        inclusion: &'a str,
        values: &'a str,
        mhz: f64,
    ) -> AreaKeyParts<'a> {
        AreaKeyParts {
            area_model: "area-v1",
            area_schema: "1",
            area_table: table,
            cost_model: "fo4-v1",
            decls: 0,
            design_key: "dk",
            fn_bodies: 0,
            fo4_ps: 20.0,
            inclusion,
            ir: "ir-v1",
            margin: 0.2,
            measurement: "delay-v25",
            param_values: values,
            path_class: "24",
            target_mhz: mhz,
            marks_model: "area-asm-marks-v1",
        }
    }

    #[test]
    fn canon_f64_locks_the_three_vectors() {
        assert_eq!(canon_f64(0.2), "2.0000000000000001e-1");
        assert_eq!(canon_f64(20.0), "2.0000000000000000e1");
        assert_eq!(canon_f64(1250.0), "1.2500000000000000e3");
    }

    #[test]
    fn inclusion_value_and_table_miss_and_jobs_are_absent() {
        let base = area_key(&sample(b"table", "", "W=64", 1000.0));
        assert_ne!(
            base,
            area_key(&sample(b"table", "subtree=leaf", "W=64", 1000.0))
        );
        assert_ne!(base, area_key(&sample(b"table", "", "W=64.0", 1000.0)));
        assert_ne!(base, area_key(&sample(b"table!", "", "W=64", 1000.0)));
        assert_eq!(base, area_key(&sample(b"table", "", "W=64", 1000.0)));
        let record = area_key_record(&sample(b"table", "", "W=64", 1000.0));
        assert!(!record.contains("jobs"));
        assert!(!record.contains("opt="));
        assert!(record.contains("decls=0"));
        assert!(record.contains("fn_bodies=0"));
        assert!(record.contains("marks_model=area-asm-marks-v1"));
        assert!(record.contains(&format!("target_mhz={}", canon_f64(1000.0))));
    }

    #[test]
    fn pre_field_and_unemitted_claims_are_not_stored() {
        let current: Vec<String> = emitted_lower_field_names()
            .iter()
            .map(|name| (*name).to_string())
            .collect();
        assert!(may_store_area_report(0, 0, &current));
        assert!(may_store_area_report(1, 0, &current));
        assert!(may_store_area_report(0, 1, &current));
        assert!(!may_store_area_report(0, 0, &[]));
    }
}
