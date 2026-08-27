// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! `g6q-diag` — the diagnosis layer.
//!
//! Two tiers, one front end, **never the same run**
//! ([`architecture/DIAG.md`]):
//!
//! * **D1 tandem** — commit records, lockstep against a reference, first-divergence
//!   bisection, checkpoint export. Accepts **equality**.
//! * **D2 microarchitectural** — structures modelled at their configured sizes, plus the
//!   design's own performance events. Accepts **correlation**, with error bars.
//!
//! # Two rules encoded here rather than documented and hoped for
//!
//! 1. **Cycles are not modelled.** Any cycle-like quantity is marked
//!    [`Fidelity::Synthetic`] and says so wherever it is printed. A report that states a
//!    cycle count is a reporting defect.
//! 2. **Nothing here is verification evidence.** Every artifact carries `evidence: false`
//!    and, when produced from a non-faithful machine, a profile taint.
//!
//! # Stage
//!
//! Q0 defines the fidelity vocabulary, the divergence comparison and the taint rules.
//! Q5 adds the record format and checkpoints; Q7 adds the structure models and counters.
//!
//! [`architecture/DIAG.md`]: ../../../architecture/DIAG.md

#![forbid(unsafe_code)]

use g6q_core::model::TargetModel;
use g6q_core::Json;

/// How much a reported quantity can be trusted.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Fidelity {
    /// Architectural state, traps, memory contents, retired-instruction counts and counts
    /// of architectural events. A mismatch is a bug in one of the two implementations.
    Exact,
    /// Structure hit and miss rates. Same geometry and policy as the design, but no
    /// pipeline timing and no speculative-path pollution: expect the shape to match and
    /// the absolute rate to differ.
    Modelled,
    /// Occupancy and stall events. Indicative only.
    Weak,
    /// Cycles and anything latency-derived. **Not modelled**; present only so software
    /// that reads the counter sees a monotonic value.
    Synthetic,
}

impl Fidelity {
    /// Stable wire name.
    pub fn as_str(self) -> &'static str {
        match self {
            Fidelity::Exact => "exact",
            Fidelity::Modelled => "modelled",
            Fidelity::Weak => "weak",
            Fidelity::Synthetic => "synthetic",
        }
    }

    /// Whether a value of this fidelity may be compared for equality with hardware.
    pub fn comparable_for_equality(self) -> bool {
        matches!(self, Fidelity::Exact)
    }
}

/// A reported counter with its fidelity attached.
///
/// The fidelity travels with the value rather than living in a legend, so a number cannot
/// be copied out of a report and quoted without it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Counter {
    /// Event name, from the design's own event table.
    pub name: String,
    /// Observed value.
    pub value: u64,
    /// How much it can be trusted.
    pub fidelity: Fidelity,
}

impl Counter {
    /// Render as JSON.
    pub fn to_json(&self) -> Json {
        Json::obj([
            ("name", Json::str(&self.name)),
            ("value", Json::Int(self.value as i64)),
            ("fidelity", Json::str(self.fidelity.as_str())),
        ])
    }
}

/// One field that differed between two implementations at the same instruction.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FieldDiff {
    /// Field name, e.g. `"pc_wdata"`.
    pub field: String,
    /// Value from the implementation under test.
    pub lhs: String,
    /// Value from the reference.
    pub rhs: String,
}

/// A minimal architectural commit record.
///
/// The full record follows the design project's own trace format, consumed by pin so that
/// this package slots into an existing tandem flow rather than forming a separate
/// universe. Q0 carries the subset needed to implement and test comparison.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct CommitRecord {
    /// Monotonic retire index for this hart.
    pub order: u64,
    /// Hart identifier.
    pub hart: u32,
    /// Program counter before the instruction.
    pub pc_rdata: u64,
    /// Program counter after the instruction.
    pub pc_wdata: u64,
    /// Instruction word.
    pub insn: u32,
    /// Whether the instruction trapped.
    pub trap: bool,
    /// Destination register index, zero when none.
    pub rd_addr: u8,
    /// Value written to the destination register.
    pub rd_wdata: u64,
}

impl CommitRecord {
    /// Serialize to a canonical JSON object.
    pub fn to_json(&self) -> Json {
        Json::obj(vec![
            ("order", Json::Int(self.order as i64)),
            ("hart", Json::Int(self.hart as i64)),
            ("pc_rdata", Json::Int(self.pc_rdata as i64)),
            ("pc_wdata", Json::Int(self.pc_wdata as i64)),
            ("insn", Json::Int(self.insn as i64)),
            ("trap", Json::Bool(self.trap)),
            ("rd_addr", Json::Int(self.rd_addr as i64)),
            ("rd_wdata", Json::Int(self.rd_wdata as i64)),
        ])
    }

    /// Parse from JSON.
    pub fn from_json(j: &Json) -> Option<Self> {
        let Json::Obj(o) = j else {
            return None;
        };
        let get_u64 = |k: &str| match o.get(k)? {
            Json::Int(i) => Some(*i as u64),
            _ => None,
        };
        let get_u32 = |k: &str| match o.get(k)? {
            Json::Int(i) => Some(*i as u32),
            _ => None,
        };
        let get_u8 = |k: &str| match o.get(k)? {
            Json::Int(i) => Some(*i as u8),
            _ => None,
        };
        Some(Self {
            order: get_u64("order")?,
            hart: get_u32("hart")?,
            pc_rdata: get_u64("pc_rdata")?,
            pc_wdata: get_u64("pc_wdata")?,
            insn: get_u32("insn")?,
            trap: matches!(o.get("trap")?, Json::Bool(true)),
            rd_addr: get_u8("rd_addr")?,
            rd_wdata: get_u64("rd_wdata")?,
        })
    }

    /// Compare against a reference record, returning every differing field.
    ///
    /// Comparison is field-by-field rather than whole-struct so the divergence report can
    /// name *what* differed, which is usually enough to classify the bug without opening
    /// a waveform.
    pub fn diff(&self, reference: &CommitRecord) -> Vec<FieldDiff> {
        let mut out = Vec::new();
        macro_rules! cmp {
            ($field:ident, $fmt:literal) => {
                if self.$field != reference.$field {
                    out.push(FieldDiff {
                        field: stringify!($field).to_string(),
                        lhs: format!($fmt, self.$field),
                        rhs: format!($fmt, reference.$field),
                    });
                }
            };
        }
        cmp!(order, "{}");
        cmp!(hart, "{}");
        cmp!(pc_rdata, "{:#x}");
        cmp!(pc_wdata, "{:#x}");
        cmp!(insn, "{:#010x}");
        cmp!(trap, "{}");
        cmp!(rd_addr, "{}");
        cmp!(rd_wdata, "{:#x}");
        out
    }

    /// Whether this record agrees with the reference.
    pub fn agrees_with(&self, reference: &CommitRecord) -> bool {
        self.diff(reference).is_empty()
    }
}

/// Find the first index at which two record streams disagree.
///
/// Returns the index and the differing fields. A shorter stream diverges at its end,
/// which is the common shape when one side hangs.
pub fn first_divergence(
    under_test: &[CommitRecord],
    reference: &[CommitRecord],
) -> Option<(usize, Vec<FieldDiff>)> {
    for (i, (a, b)) in under_test.iter().zip(reference.iter()).enumerate() {
        let d = a.diff(b);
        if !d.is_empty() {
            return Some((i, d));
        }
    }
    if under_test.len() != reference.len() {
        let i = under_test.len().min(reference.len());
        return Some((
            i,
            vec![FieldDiff {
                field: "stream-length".to_string(),
                lhs: under_test.len().to_string(),
                rhs: reference.len().to_string(),
            }],
        ));
    }
    None
}

/// Records as a JSON array.
pub fn records_to_json(records: &[CommitRecord]) -> Json {
    Json::arr(records.iter().map(CommitRecord::to_json))
}

/// Parse a JSON array of records.
pub fn records_from_json(j: &Json) -> Option<Vec<CommitRecord>> {
    let Json::Arr(items) = j else {
        return None;
    };
    items.iter().map(CommitRecord::from_json).collect()
}

/// Run a D1 tandem comparison and return a report.
pub fn tandem_report(under_test: &[CommitRecord], reference: &[CommitRecord]) -> Json {
    match first_divergence(under_test, reference) {
        Some((idx, diffs)) => Json::obj(vec![
            ("divergence", Json::Bool(true)),
            ("index", Json::Int(idx as i64)),
            (
                "diffs",
                Json::arr(diffs.iter().map(|d| {
                    Json::obj(vec![
                        ("field", Json::Str(d.field.clone())),
                        ("lhs", Json::Str(d.lhs.clone())),
                        ("rhs", Json::Str(d.rhs.clone())),
                    ])
                })),
            ),
        ]),
        None => Json::obj(vec![
            ("divergence", Json::Bool(false)),
            ("records", Json::Int(under_test.len() as i64)),
        ]),
    }
}

/// Why a diagnosis run is or is not permitted.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiagPermission {
    /// The machine is faithful; results stand on their own.
    Allowed,
    /// The machine deviates; permitted only with an explicit override, and tainted.
    RequiresOverride,
}

/// Decide whether diagnosis may run against this model.
///
/// A deviated or virtio-extended machine contains device state and address decisions with
/// no hardware counterpart. Refusing by default is what stops such a run being quoted as
/// a hardware result later.
pub fn permission(model: &TargetModel) -> DiagPermission {
    if model.diagnosable() {
        DiagPermission::Allowed
    } else {
        DiagPermission::RequiresOverride
    }
}

/// A diagnosis artifact header, attached to every report this crate produces.
#[derive(Debug, Clone)]
pub struct ArtifactHeader {
    /// Machine profile the run used.
    pub profile: String,
    /// Whether the machine deviated from the design's own description.
    pub tainted: bool,
}

impl ArtifactHeader {
    /// Build from a model.
    pub fn from_model(model: &TargetModel) -> Self {
        Self {
            profile: model.profile.as_str().to_string(),
            tainted: !model.diagnosable(),
        }
    }

    /// Render as JSON. `evidence` is unconditionally false.
    pub fn to_json(&self) -> Json {
        Json::obj([
            ("profile", Json::str(&self.profile)),
            ("profile_tainted", Json::Bool(self.tainted)),
            ("evidence", Json::Bool(false)),
        ])
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use g6q_core::model::Profile;

    fn rec(order: u64, pc: u64) -> CommitRecord {
        CommitRecord {
            order,
            hart: 0,
            pc_rdata: pc,
            pc_wdata: pc + 4,
            ..CommitRecord::default()
        }
    }

    #[test]
    fn only_exact_quantities_may_be_compared_with_hardware() {
        assert!(Fidelity::Exact.comparable_for_equality());
        assert!(!Fidelity::Modelled.comparable_for_equality());
        assert!(!Fidelity::Weak.comparable_for_equality());
        assert!(!Fidelity::Synthetic.comparable_for_equality());
    }

    #[test]
    fn a_cycle_like_counter_is_marked_synthetic() {
        let c = Counter {
            name: "cycle".into(),
            value: 12345,
            fidelity: Fidelity::Synthetic,
        };
        let text = c.to_json().to_pretty();
        assert!(text.contains("\"fidelity\": \"synthetic\""), "{text}");
    }

    #[test]
    fn identical_records_agree() {
        assert!(rec(1, 0x8000_0000).agrees_with(&rec(1, 0x8000_0000)));
    }

    #[test]
    fn a_diff_names_the_field_that_differed() {
        let a = rec(1, 0x8000_0000);
        let mut b = a.clone();
        b.pc_wdata = 0x9000_0000;
        b.rd_wdata = 42;
        let d = a.diff(&b);
        let fields: Vec<_> = d.iter().map(|f| f.field.as_str()).collect();
        assert!(fields.contains(&"pc_wdata"), "{fields:?}");
        assert!(fields.contains(&"rd_wdata"), "{fields:?}");
        assert!(!fields.contains(&"pc_rdata"), "{fields:?}");
    }

    #[test]
    fn first_divergence_reports_the_index() {
        let lhs = vec![rec(0, 0x1000), rec(1, 0x1004), rec(2, 0x1008)];
        let mut rhs = lhs.clone();
        rhs[2].pc_wdata = 0xdead_beef;
        let (idx, diffs) = first_divergence(&lhs, &rhs).expect("divergence");
        assert_eq!(idx, 2);
        assert_eq!(diffs[0].field, "pc_wdata");
    }

    #[test]
    fn identical_streams_do_not_diverge() {
        let lhs = vec![rec(0, 0x1000), rec(1, 0x1004)];
        assert!(first_divergence(&lhs, &lhs.clone()).is_none());
    }

    #[test]
    fn a_truncated_stream_diverges_at_its_end() {
        // The common shape when one side hangs.
        let lhs = vec![rec(0, 0x1000)];
        let rhs = vec![rec(0, 0x1000), rec(1, 0x1004)];
        let (idx, diffs) = first_divergence(&lhs, &rhs).expect("divergence");
        assert_eq!(idx, 1);
        assert_eq!(diffs[0].field, "stream-length");
    }

    #[test]
    fn a_faithful_machine_may_be_diagnosed_and_a_deviated_one_may_not() {
        let mut m = TargetModel::new("t");
        assert_eq!(permission(&m), DiagPermission::Allowed);

        m.profile = Profile::Virt;
        assert_eq!(permission(&m), DiagPermission::RequiresOverride);

        let mut m2 = TargetModel::new("t");
        m2.mark_unfaithful();
        assert_eq!(permission(&m2), DiagPermission::RequiresOverride);
    }

    #[test]
    fn every_artifact_denies_being_evidence_and_stamps_the_profile() {
        let mut m = TargetModel::new("t");
        m.profile = Profile::Virt;
        let text = ArtifactHeader::from_model(&m).to_json().to_pretty();
        assert!(text.contains("\"evidence\": false"), "{text}");
        assert!(text.contains("\"profile\": \"g6lc-virt\""), "{text}");
        assert!(text.contains("\"profile_tainted\": true"), "{text}");
    }
}
