// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! `g6q-svcfg` — the configuration-package reader.
//!
//! The inputs are a small number of stylistically uniform SystemVerilog package files:
//! `localparam` scalars and one named struct literal per target. A full SystemVerilog
//! parser is a large dependency for that job, so this reader is **deliberately narrow**.
//!
//! A survey of the real packages found exactly five expression forms and **no
//! arithmetic** ([`value`]). The reader handles those five and reports anything else as
//! [`Value::Unresolved`], carrying the original source text. That is the property that
//! makes a narrow reader safe: it *fails loudly*. A reader that guesses is worse than one
//! that stops, because a guessed configuration produces a plausible wrong emulator.
//!
//! Whether an unresolved field matters is decided downstream, by whether a consumer
//! actually reads it — an unresolved field nobody uses is carried and harmless.
//!
//! # Modules
//!
//! * [`value`] — the value model and the expression forms
//! * [`parse`] — package reading: comments, `localparam` statements, evaluation
//! * [`legality`] — the design's own legality rules, split into checkable and derived

#![forbid(unsafe_code)]

pub mod derive;
pub mod legality;
pub mod parse;
pub mod value;

pub use derive::{derive, Derivation};
pub use legality::{validate, Rule};
pub use parse::{read_package, Package};
pub use value::Value;

/// Read a package from a file.
pub fn read_package_file(path: &std::path::Path) -> std::io::Result<Package> {
    let text = std::fs::read_to_string(path)?;
    Ok(read_package(&text))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The shape of a real target package, reduced to the forms that matter.
    const SAMPLE: &str = r#"
// a leading comment
package cva6_config_pkg;

  localparam CVA6ConfigXlen = 64;
  localparam CVA6ConfigAExtEn = 1;
  localparam CVA6ConfigBExtEn = 1;
  localparam CVA6ConfigNrScoreboardEntries = 16;
  localparam config_pkg::cache_type_t CVA6ConfigDcacheType = config_pkg::HPDCACHE_WT;

  localparam config_pkg::ai_cfg_t ai_cfg = '{
      MatrixEn: bit'(1),
      AccelEn: bit'(0),   // seam B
      TileLdEn: bit'(0),
      TileM: unsigned'(8),
      Queues: unsigned'(2)
  };

  localparam config_pkg::cva6_user_cfg_t cva6_cfg = '{
      XLEN: unsigned'(CVA6ConfigXlen),
      RVA: bit'(CVA6ConfigAExtEn),
      RVB: bit'(CVA6ConfigBExtEn),
      RVZacas: bit'(1),
      RVV: bit'(0),
      RVH: bit'(1),
      RVS: bit'(1),
      MmuPresent: bit'(1),
      SoftwareInterruptEn: bit'(1),
      RASDepth: unsigned'(2),
      BTBEntries: unsigned'(32),
      BPType: config_pkg::TAGE_LITE,
      BPTageTables: unsigned'(3),
      NrScoreboardEntries: unsigned'(CVA6ConfigNrScoreboardEntries),
      DCacheType: CVA6ConfigDcacheType,
      AiCfg: ai_cfg,
      HaltAddress: 64'h800,
      PMPCfgRstVal: {64{64'h0}},
      NrExecuteRegionRules: unsigned'(3),
      ExecuteRegionAddrBase: 1024'({64'h8000_0000, 64'h1_0000, 64'h0}),
      L2En: bit'(1),
      L2ByteSize: unsigned'(0),
      NrHarts: unsigned'(1),
      NrCores: unsigned'(2),
      SmtPolicy: config_pkg::SMT_HYBRID,
      SmtFetchQuantum: unsigned'(4),
      CohPolicy: config_pkg::COH_FILTERED
  };

endpackage
"#;

    #[test]
    fn a_realistic_package_reads_end_to_end() {
        let pkg = read_package(SAMPLE);
        assert_eq!(pkg.name, "cva6_config_pkg");

        // Scalars resolved through an earlier localparam.
        assert_eq!(pkg.int_or("XLEN", 0), 64);
        assert_eq!(pkg.int_or("NrScoreboardEntries", 0), 16);

        // Flags.
        assert!(pkg.flag("RVA"));
        assert!(pkg.flag("RVZacas"));
        assert!(!pkg.flag("RVV"));
        assert!(pkg.flag("RVH"));

        // Enums by name, including one reached through a typed localparam.
        assert_eq!(pkg.enum_of("BPType"), Some("TAGE_LITE"));
        assert_eq!(pkg.enum_of("SmtPolicy"), Some("SMT_HYBRID"));
        assert_eq!(pkg.enum_of("DCacheType"), Some("HPDCACHE_WT"));

        // Nested struct reached by identifier reference.
        assert!(pkg.nested_flag("AiCfg", "MatrixEn"));
        assert!(!pkg.nested_flag("AiCfg", "AccelEn"));
        assert_eq!(pkg.nested("AiCfg", "TileM"), Some(&Value::Int(8)));

        // Aggregates.
        match pkg.field("ExecuteRegionAddrBase") {
            Some(Value::List(items)) => assert_eq!(items.len(), 3),
            other => panic!("expected a region list, got {other:?}"),
        }
        match pkg.field("PMPCfgRstVal") {
            Some(Value::List(items)) => assert_eq!(items.len(), 64),
            other => panic!("expected a replicated list, got {other:?}"),
        }

        // Nothing in a well-formed package should be unresolved.
        assert!(
            pkg.unresolved_fields().is_empty(),
            "{:?}",
            pkg.unresolved_fields()
        );
    }

    #[test]
    fn the_sample_package_is_legal_and_declares_its_unchecked_rules() {
        let pkg = read_package(SAMPLE);
        let r = validate(&pkg);
        assert!(r.is_legal(), "{:?}", r.violations());
        // L2En with size 0 must not be reported as a violation; it is inference.
        assert!(!r.unchecked().is_empty());
    }

    #[test]
    fn reading_is_deterministic() {
        assert_eq!(read_package(SAMPLE), read_package(SAMPLE));
    }
}
