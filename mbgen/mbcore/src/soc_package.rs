// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! The custom LibreCore SoC package contract — the one external input the
//! manufacturing endpoint depends on, kept as a checked-in document so the
//! workspace can say exactly what is still missing instead of implying a
//! socket geometry.
//!
//! `data/soc_package.json` lists package, ball map, I/O banks, power rails
//! and sequence, thermal limits, reset/clock/boot pins, implemented external
//! interfaces, and footprint/model. `assess` walks it and reports every
//! unresolved field by path. The report rides in the bundle manifest, the
//! layout and the resolved circuit, and is a blocker in the manufacturing
//! gate until the document is `approved` with nothing unresolved.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::profile::sha256_hex;

pub const SOC_PACKAGE_SCHEMA_VERSION: u64 = 1;
pub const SOC_PACKAGE_JSON: &str = include_str!("../data/soc_package.json");

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SocPackageReport {
    pub id: String,
    /// `draft` | `approved` as declared in the document.
    pub declared_status: String,
    /// True only when declared approved **and** nothing is unresolved.
    pub approved: bool,
    /// JSON paths of fields that are null / empty.
    pub unresolved: Vec<String>,
    /// Problems with the document itself (schema, types).
    pub errors: Vec<String>,
    pub sha256: String,
}

impl SocPackageReport {
    pub fn blocker(&self) -> Option<String> {
        if self.approved {
            return None;
        }
        Some(format!(
            "custom SoC package contract {} is {} with {} unresolved field(s)",
            self.id,
            self.declared_status,
            self.unresolved.len()
        ))
    }
}

fn unresolved_at(value: &Value, path: &str, out: &mut Vec<String>) {
    match value {
        Value::Null => out.push(path.to_string()),
        Value::String(s) if s.trim().is_empty() => out.push(path.to_string()),
        Value::Array(a) if a.is_empty() => out.push(path.to_string()),
        Value::Object(map) => {
            for (k, v) in map {
                if k == "description" || k == "status" || k == "schema_version" || k == "id" {
                    continue;
                }
                unresolved_at(v, &format!("{path}.{k}"), out);
            }
        }
        _ => {}
    }
}

/// Required top-level sections and the type each must have.
const SECTIONS: &[(&str, &str)] = &[
    ("package", "object"),
    ("ball_map", "object"),
    ("io_banks", "array"),
    ("power", "object"),
    ("thermal", "object"),
    ("reset_clock_boot", "object"),
    ("interfaces", "array"),
    ("footprint", "object"),
];

pub fn assess_text(text: &str) -> SocPackageReport {
    let sha256 = sha256_hex(text.as_bytes());
    let mut report = SocPackageReport {
        id: String::new(),
        declared_status: "draft".into(),
        approved: false,
        unresolved: Vec::new(),
        errors: Vec::new(),
        sha256,
    };
    let doc: Value = match serde_json::from_str(text) {
        Ok(v) => v,
        Err(e) => {
            report.errors.push(format!("not JSON: {e}"));
            return report;
        }
    };
    if doc.get("schema_version").and_then(Value::as_u64) != Some(SOC_PACKAGE_SCHEMA_VERSION) {
        report.errors.push(format!("schema_version is not {SOC_PACKAGE_SCHEMA_VERSION}"));
    }
    report.id = doc.get("id").and_then(Value::as_str).unwrap_or("").to_string();
    if report.id.is_empty() {
        report.errors.push("id is missing".into());
    }
    report.declared_status = doc.get("status").and_then(Value::as_str).unwrap_or("draft").to_string();
    if !matches!(report.declared_status.as_str(), "draft" | "approved") {
        report.errors.push(format!("status {:?} is not draft|approved", report.declared_status));
    }
    for (name, kind) in SECTIONS {
        match doc.get(*name) {
            None => report.errors.push(format!("{name} section is missing")),
            Some(v) => {
                let ok = match *kind {
                    "object" => v.is_object(),
                    "array" => v.is_array(),
                    _ => true,
                };
                if !ok {
                    report.errors.push(format!("{name} must be a JSON {kind}"));
                    continue;
                }
                unresolved_at(v, name, &mut report.unresolved);
            }
        }
    }
    report.approved = report.declared_status == "approved" && report.unresolved.is_empty() && report.errors.is_empty();
    report
}

/// The committed contract document's report.
pub fn assess() -> SocPackageReport {
    assess_text(SOC_PACKAGE_JSON)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_committed_contract_is_an_honest_draft() {
        let r = assess();
        assert_eq!(r.id, "g6lc-soc-pkg");
        assert_eq!(r.declared_status, "draft");
        assert!(!r.approved);
        assert!(r.errors.is_empty(), "{:?}", r.errors);
        for must in [
            "package.type",
            "ball_map.balls",
            "io_banks",
            "power.rails",
            "thermal.tdp_w",
            "reset_clock_boot.por_pin",
            "interfaces",
            "footprint.kicad",
        ] {
            assert!(r.unresolved.iter().any(|u| u == must), "{must} must be reported unresolved: {:?}", r.unresolved);
        }
        assert!(r.blocker().unwrap().contains("unresolved"));
        assert_eq!(r.sha256.len(), 64);
    }

    #[test]
    fn declaring_approved_does_not_make_it_so_until_nothing_is_unresolved() {
        let text = SOC_PACKAGE_JSON.replacen("\"status\": \"draft\"", "\"status\": \"approved\"", 1);
        let r = assess_text(&text);
        assert_eq!(r.declared_status, "approved");
        assert!(!r.approved, "approved with unresolved fields is still blocked");
        assert!(r.blocker().is_some());
    }

    #[test]
    fn a_complete_approved_contract_opens_the_gate() {
        let text = r#"{
          "schema_version": 1, "id": "x", "status": "approved",
          "package": {"type": "FCBGA", "body_mm": 23, "pitch_mm": 0.8, "ball_count": 784, "source": "pkg-rev-A.pdf"},
          "ball_map": {"source": "ballmap.csv", "sha256": "ab", "balls": [{"ball": "A1", "net": "GND"}]},
          "io_banks": [{"id": "B0", "vccio_v": 3.3}],
          "power": {"rails": [{"name": "VDD_CORE", "v": 0.8, "max_a": 6}], "sequence": ["VDD_CORE"], "source": "pdn.md"},
          "thermal": {"tdp_w": 12, "tj_max_c": 105, "theta_ja_c_per_w": 8.5, "source": "thermal.md"},
          "reset_clock_boot": {"por_pin": "A2", "refclk_pins": ["B3"], "boot_mode_pins": ["C4"], "jtag_pins": ["D1"], "source": "boot.md"},
          "interfaces": [{"id": "pcie0", "kind": "pcie", "lanes": 4}],
          "footprint": {"kicad": "G6LC:FCBGA-784", "model_3d": "g6lc.step", "source": "cse"}
        }"#;
        let r = assess_text(text);
        assert!(r.errors.is_empty(), "{:?}", r.errors);
        assert!(r.unresolved.is_empty(), "{:?}", r.unresolved);
        assert!(r.approved);
        assert!(r.blocker().is_none());
    }

    #[test]
    fn a_malformed_document_is_an_error_not_a_pass() {
        let r = assess_text("{\"schema_version\": 2, \"status\": \"shipped\"}");
        assert!(!r.approved);
        assert!(r.errors.iter().any(|e| e.contains("schema_version")));
        assert!(r.errors.iter().any(|e| e.contains("draft|approved")));
        assert!(r.errors.iter().any(|e| e.contains("package section is missing")));
        assert!(!assess_text("nope").approved);
    }
}
