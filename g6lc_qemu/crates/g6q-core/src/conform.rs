// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! The conformance report — the package's first-class output.
//!
//! Three inputs describe a design and they routinely disagree: the **configuration**
//! says what is enabled, the **flist** says what is actually compiled, and the **device
//! tree** says what software is told. A capability is only safe to emulate when all three
//! agree; every other combination is a finding.
//!
//! This module is deliberately independent of *how* the three facts were obtained, so
//! that the verdict logic has exactly one implementation and is unit-testable without any
//! reader.

use crate::json::Json;

/// The verdict for one capability.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Verdict {
    /// Enabled in configuration, compiled into the design, declared to software.
    Live,
    /// Enabled in configuration, but the compiled RTL is a stub or placeholder.
    Stub,
    /// Disabled, and consistently absent elsewhere.
    Absent,
    /// Live in the design but not advertised to software: the guest will not use it.
    Undeclared,
    /// Advertised to software but not live in the design — a guest-visible lie.
    Overdeclared,
    /// A reader could not determine the value.
    Unresolved,
    /// Forced by a command-line override; taints every downstream artifact.
    Synthetic,
}

impl Verdict {
    /// The stable wire name used in JSON and in reports.
    pub fn as_str(self) -> &'static str {
        match self {
            Verdict::Live => "live",
            Verdict::Stub => "stub",
            Verdict::Absent => "absent",
            Verdict::Undeclared => "undeclared",
            Verdict::Overdeclared => "overdeclared",
            Verdict::Unresolved => "unresolved",
            Verdict::Synthetic => "synthetic",
        }
    }

    /// Whether `--conform strict` refuses to emulate this capability.
    ///
    /// `Stub`, `Overdeclared` and `Unresolved` are refused because each one means the
    /// emulator would be asserting something the elaborated design does not support.
    /// `Undeclared` is permitted with a warning: the hardware really does have the
    /// feature, the guest simply will not be told about it.
    pub fn refused_under_strict(self) -> bool {
        matches!(
            self,
            Verdict::Stub | Verdict::Overdeclared | Verdict::Unresolved
        )
    }
}

/// What the three inputs say about one capability.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Inputs {
    /// The configuration enables the capability.
    pub config_enabled: bool,
    /// The implementing RTL is present in the compiled file set (not a stub).
    pub flist_present: bool,
    /// The device tree advertises the capability to software.
    pub dts_declared: bool,
}

impl Inputs {
    /// Convenience constructor.
    pub fn new(config_enabled: bool, flist_present: bool, dts_declared: bool) -> Self {
        Self {
            config_enabled,
            flist_present,
            dts_declared,
        }
    }
}

/// One capability row of the report.
#[derive(Debug, Clone)]
pub struct Row {
    /// Capability name, e.g. `"vector"`, `"hypervisor"`, `"instruction-supply"`.
    pub capability: String,
    /// What each input said.
    pub inputs: Inputs,
    /// The primary verdict.
    pub verdict: Verdict,
    /// Secondary observations, e.g. a `Stub` row that is *also* `Overdeclared`.
    pub also: Vec<Verdict>,
    /// Human-readable explanation.
    pub note: String,
}

impl Row {
    /// Classify a capability from its three inputs.
    ///
    /// The one subtlety worth stating: a capability that is enabled in configuration but
    /// whose RTL is not compiled is `Stub`, and if the device tree *also* advertises it
    /// the row additionally carries `Overdeclared` — because those are two distinct
    /// problems with two distinct fixes (the flist, and the device tree).
    pub fn classify(capability: impl Into<String>, inputs: Inputs) -> Self {
        let capability = capability.into();
        let (verdict, note) = match (inputs.config_enabled, inputs.flist_present) {
            (true, true) => {
                if inputs.dts_declared {
                    (Verdict::Live, "enabled, compiled and declared".to_string())
                } else {
                    (
                        Verdict::Undeclared,
                        "live in the design but not advertised to software".to_string(),
                    )
                }
            }
            (true, false) => (
                Verdict::Stub,
                "configuration enables the capability but the compiled design has no \
                 implementation"
                    .to_string(),
            ),
            (false, _) => {
                if inputs.dts_declared {
                    (
                        Verdict::Overdeclared,
                        "advertised to software but disabled in configuration".to_string(),
                    )
                } else {
                    (
                        Verdict::Absent,
                        "disabled and consistently absent".to_string(),
                    )
                }
            }
        };

        let mut also = Vec::new();
        if verdict == Verdict::Stub && inputs.dts_declared {
            also.push(Verdict::Overdeclared);
        }

        Row {
            capability,
            inputs,
            verdict,
            also,
            note,
        }
    }

    /// Mark this row as forced by an override.
    pub fn synthetic(mut self, origin: &str) -> Self {
        self.also.push(self.verdict);
        self.verdict = Verdict::Synthetic;
        self.note = format!("forced by {origin}; original verdict retained in `also`");
        self
    }

    /// Render as JSON.
    pub fn to_json(&self) -> Json {
        Json::obj([
            ("capability", Json::str(&self.capability)),
            (
                "config",
                Json::obj([("enabled", Json::Bool(self.inputs.config_enabled))]),
            ),
            (
                "flist",
                Json::obj([("present", Json::Bool(self.inputs.flist_present))]),
            ),
            (
                "dts",
                Json::obj([("declared", Json::Bool(self.inputs.dts_declared))]),
            ),
            ("verdict", Json::str(self.verdict.as_str())),
            (
                "also",
                Json::arr(self.also.iter().map(|v| Json::str(v.as_str()))),
            ),
            ("note", Json::str(&self.note)),
        ])
    }
}

/// A complete conformance report.
#[derive(Debug, Clone, Default)]
pub struct Report {
    /// Capability rows, in insertion order.
    pub rows: Vec<Row>,
}

impl Report {
    /// An empty report.
    pub fn new() -> Self {
        Self::default()
    }

    /// Append a row.
    pub fn push(&mut self, row: Row) {
        self.rows.push(row);
    }

    /// Rows that `--conform strict` would refuse.
    pub fn blocking(&self) -> Vec<&Row> {
        self.rows
            .iter()
            .filter(|r| r.verdict.refused_under_strict())
            .collect()
    }

    /// Whether the report passes under `--conform strict`.
    pub fn passes_strict(&self) -> bool {
        self.blocking().is_empty()
    }

    /// Render as JSON.
    pub fn to_json(&self) -> Json {
        Json::obj([
            ("rows", Json::arr(self.rows.iter().map(Row::to_json))),
            ("passes_strict", Json::Bool(self.passes_strict())),
            // Diagnosis output is never verification evidence (`architecture/DIAG.md` §6).
            ("evidence", Json::Bool(false)),
        ])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn all_three_agree_is_live() {
        let r = Row::classify("zacas", Inputs::new(true, true, true));
        assert_eq!(r.verdict, Verdict::Live);
        assert!(!r.verdict.refused_under_strict());
    }

    #[test]
    fn enabled_but_not_compiled_is_stub_and_blocks() {
        let r = Row::classify("vector", Inputs::new(true, false, false));
        assert_eq!(r.verdict, Verdict::Stub);
        assert!(r.verdict.refused_under_strict());
    }

    #[test]
    fn stub_plus_declared_also_reports_overdeclared() {
        // The real case this exists for: configuration enables a vector unit, the vector
        // flist is absent so the design compiles a stub, and the device tree still
        // advertises the extension to Linux. Two problems, two fixes.
        let r = Row::classify("vector", Inputs::new(true, false, true));
        assert_eq!(r.verdict, Verdict::Stub);
        assert!(r.also.contains(&Verdict::Overdeclared));
    }

    #[test]
    fn live_but_undeclared_is_permitted_with_a_warning() {
        // Hardware has the feature; the device tree deliberately omits the token.
        let r = Row::classify("hypervisor", Inputs::new(true, true, false));
        assert_eq!(r.verdict, Verdict::Undeclared);
        assert!(!r.verdict.refused_under_strict());
    }

    #[test]
    fn declared_but_disabled_is_a_guest_visible_lie() {
        let r = Row::classify("hypervisor", Inputs::new(false, false, true));
        assert_eq!(r.verdict, Verdict::Overdeclared);
        assert!(r.verdict.refused_under_strict());
    }

    #[test]
    fn absent_is_quiet() {
        let r = Row::classify("vector", Inputs::new(false, false, false));
        assert_eq!(r.verdict, Verdict::Absent);
        assert!(!r.verdict.refused_under_strict());
    }

    #[test]
    fn synthetic_preserves_the_original_verdict() {
        let r = Row::classify("smt", Inputs::new(true, true, true)).synthetic("--cfg-override");
        assert_eq!(r.verdict, Verdict::Synthetic);
        assert!(r.also.contains(&Verdict::Live));
    }

    #[test]
    fn report_strictness_and_json() {
        let mut rep = Report::new();
        rep.push(Row::classify("a", Inputs::new(true, true, true)));
        assert!(rep.passes_strict());
        rep.push(Row::classify("b", Inputs::new(true, false, true)));
        assert!(!rep.passes_strict());
        assert_eq!(rep.blocking().len(), 1);

        let text = rep.to_json().to_pretty();
        assert!(text.contains("\"evidence\": false"), "{text}");
        assert!(text.contains("\"passes_strict\": false"), "{text}");
    }
}
