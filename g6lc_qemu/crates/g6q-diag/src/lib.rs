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

pub mod ai_cap;
pub mod ai_cfg;
pub mod ai_desc;
pub mod ai_instr;
pub mod ai_tensor;
pub mod roofline;
pub mod rvfi;
pub mod uarch;

pub use uarch::{ai_island_counters, model_counters, structure_counters};

use g6q_core::model::TargetModel;
use g6q_core::Json;
use std::fs;
use std::path::Path;

/// How much a reported quantity can be trusted.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Fidelity {
    /// Architectural state, traps, memory contents, retired-instruction counts and counts
    /// of architectural events. A mismatch is a bug in one of the two implementations.
    Exact,
    /// A value measured by the design's own PMU or diagnostic harness. Comparable for
    /// equality with a later measurement, but not a prediction of a future run.
    Measured,
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
            Fidelity::Measured => "measured",
            Fidelity::Modelled => "modelled",
            Fidelity::Weak => "weak",
            Fidelity::Synthetic => "synthetic",
        }
    }

    /// Whether a value of this fidelity may be compared for equality with hardware.
    pub fn comparable_for_equality(self) -> bool {
        matches!(self, Fidelity::Exact | Fidelity::Measured)
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
/// universe. Q0 carries the subset needed to implement and test comparison; Q5 extends it
/// with trap cause, privilege and halt flags needed for checkpoint hand-off.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct CommitRecord {
    /// Monotonic record index for this hart (not necessarily the architectural instret).
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
    /// Trap or interrupt cause (`mcause` value) when `trap` is true.
    pub cause: u64,
    /// Privilege mode before the instruction.
    pub prv: u8,
    /// Whether this record marks the end of the run.
    pub halt: bool,
    /// Integer destination register index, zero when none.
    pub rd_addr: u8,
    /// Value written to the integer destination register.
    pub rd_wdata: u64,
    /// Floating-point destination register index, zero when none.
    pub frd_addr: u8,
    /// Value written to the floating-point destination register.
    pub frd_wdata: u64,
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
            ("cause", Json::Int(self.cause as i64)),
            ("prv", Json::Int(self.prv as i64)),
            ("halt", Json::Bool(self.halt)),
            ("rd_addr", Json::Int(self.rd_addr as i64)),
            ("rd_wdata", Json::Int(self.rd_wdata as i64)),
            ("frd_addr", Json::Int(self.frd_addr as i64)),
            ("frd_wdata", Json::Int(self.frd_wdata as i64)),
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
            cause: get_u64("cause").unwrap_or(0),
            prv: get_u8("prv").unwrap_or(0),
            halt: matches!(o.get("halt")?, Json::Bool(true)),
            rd_addr: get_u8("rd_addr")?,
            rd_wdata: get_u64("rd_wdata")?,
            frd_addr: get_u8("frd_addr").unwrap_or(0),
            frd_wdata: get_u64("frd_wdata").unwrap_or(0),
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
        cmp!(cause, "{:#x}");
        cmp!(prv, "{}");
        cmp!(halt, "{}");
        cmp!(rd_addr, "{}");
        cmp!(rd_wdata, "{:#x}");
        cmp!(frd_addr, "{}");
        cmp!(frd_wdata, "{:#x}");
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

/// Parse a JSON text into a record array.
pub fn records_from_str(text: &str) -> Result<Vec<CommitRecord>, String> {
    let j = Json::parse(text).map_err(|e| format!("invalid JSON: {e}"))?;
    records_from_json(&j).ok_or_else(|| "expected a JSON array of records".to_string())
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
#[derive(Debug, Clone, PartialEq, Eq)]
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

/// A D1 record file: an artifact header plus a commit-record stream.
///
/// This is the file unit for `--record` / `--replay` and for checkpoint hand-off. The
/// header stamps the profile and taint so a record cannot be mistaken for evidence even
/// when it is read by a different tool.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecordFile {
    /// Artifact header describing the profile that produced the records.
    pub header: ArtifactHeader,
    /// Architectural commit records in execution order.
    pub records: Vec<CommitRecord>,
}

impl RecordFile {
    /// Render the whole record file as a single JSON object.
    pub fn to_json(&self) -> Json {
        Json::obj(vec![
            ("header", self.header.to_json()),
            ("records", records_to_json(&self.records)),
        ])
    }

    /// Parse a record file from JSON.
    pub fn from_json(j: &Json) -> Option<Self> {
        let Json::Obj(o) = j else {
            return None;
        };
        let header_json = o.get("header")?;
        let header = ArtifactHeader::from_json(header_json)?;
        let records = records_from_json(o.get("records")?)?;
        Some(Self { header, records })
    }
}

/// Build an artifact header from a model, then wrap it around a record vector.
impl RecordFile {
    /// Build a record file from a model and its records.
    pub fn from_model_and_records(model: &TargetModel, records: Vec<CommitRecord>) -> Self {
        Self {
            header: ArtifactHeader::from_model(model),
            records,
        }
    }
}

impl ArtifactHeader {
    /// Parse an artifact header from JSON.
    pub fn from_json(j: &Json) -> Option<Self> {
        let Json::Obj(o) = j else {
            return None;
        };
        let profile = match o.get("profile")? {
            Json::Str(s) => s.clone(),
            _ => return None,
        };
        Some(Self {
            profile,
            tainted: matches!(o.get("profile_tainted")?, Json::Bool(true)),
        })
    }
}

/// Write a record file to a path.
pub fn write_record_file<P: AsRef<Path>>(path: P, file: &RecordFile) -> Result<(), String> {
    let text = file.to_json().to_pretty();
    fs::write(path.as_ref(), text)
        .map_err(|e| format!("cannot write {}: {e}", path.as_ref().display()))
}

/// Read a record file from a path.
pub fn read_record_file<P: AsRef<Path>>(path: P) -> Result<RecordFile, String> {
    let text = fs::read_to_string(path.as_ref())
        .map_err(|e| format!("cannot read {}: {e}", path.as_ref().display()))?;
    let j = Json::parse(&text).map_err(|e| format!("invalid JSON: {e}"))?;
    RecordFile::from_json(&j).ok_or_else(|| "not a valid record file".to_string())
}

/// A D1 checkpoint: enough architectural state to resume the native VM from where it was
/// taken.  It is the hand-off boundary between B3 (the interpreter) and D1 (the diagnosis
/// harness that may replay or compare).
#[derive(Debug, Clone, PartialEq)]
pub struct Checkpoint {
    /// The record order at which this checkpoint was taken.
    pub record_order: u64,
    /// General-purpose registers, including x0 (which is always zero but kept for round-trip).
    pub x: Vec<u64>,
    /// Program counter.
    pub pc: u64,
    /// Floating-point registers, nan-boxed where relevant.
    pub f: Vec<u64>,
    /// Floating-point control/status register.
    pub fcsr: u64,
    /// Privilege mode.
    pub prv: u8,
    /// Retired-instruction count.
    pub instret: u64,
    /// LR/SC reservation address, if any.
    pub reservation: Option<u64>,
    /// Trap handler scratch: the address that caused the next trap.
    pub fault_addr: u64,
    /// CSR bank values as (name, value) pairs.
    pub csr: Vec<(String, u64)>,
    /// Deterministic clock retired-instruction counter.
    pub clock_instret: u64,
    /// Clock retirement-per-tick ratio.
    pub clock_instret_per_tick: u64,
    /// Physical memory regions present at the time of the checkpoint.
    pub memory: Vec<MemRegion>,
    /// Snapshot of each memory-mapped device.  The exact fields depend on the device kind.
    pub devices: Vec<DeviceSnapshot>,
}

/// One physical memory region in a checkpoint.
#[derive(Debug, Clone, PartialEq)]
pub struct MemRegion {
    /// Region base address.
    pub base: u64,
    /// Region length.
    pub len: u64,
    /// Backing bytes as lowercase hex, two characters per byte.
    pub data: String,
}

/// A named device state blob inside a checkpoint.
#[derive(Debug, Clone, PartialEq)]
pub struct DeviceSnapshot {
    /// Device base address.
    pub base: u64,
    /// Device kind tag, e.g. "clint" or "uart".
    pub kind: String,
    /// Device-specific scalar and array state.
    pub state: Vec<(String, Json)>,
}

impl Checkpoint {
    /// Render the checkpoint as JSON.
    pub fn to_json(&self) -> Json {
        Json::obj(vec![
            ("record_order", Json::Int(self.record_order as i64)),
            ("x", Json::arr(self.x.iter().map(|v| Json::Int(*v as i64)))),
            ("pc", Json::Int(self.pc as i64)),
            ("f", Json::arr(self.f.iter().map(|v| Json::Int(*v as i64)))),
            ("fcsr", Json::Int(self.fcsr as i64)),
            ("prv", Json::Int(self.prv as i64)),
            ("instret", Json::Int(self.instret as i64)),
            (
                "reservation",
                self.reservation.map_or(Json::Null, |v| Json::Int(v as i64)),
            ),
            ("fault_addr", Json::Int(self.fault_addr as i64)),
            ("clock_instret", Json::Int(self.clock_instret as i64)),
            (
                "clock_instret_per_tick",
                Json::Int(self.clock_instret_per_tick as i64),
            ),
            (
                "csr",
                Json::arr(self.csr.iter().map(|(k, v)| {
                    Json::obj(vec![
                        ("name", Json::str(k)),
                        ("value", Json::Int(*v as i64)),
                    ])
                })),
            ),
            (
                "memory",
                Json::arr(self.memory.iter().map(|r| {
                    Json::obj(vec![
                        ("base", Json::Int(r.base as i64)),
                        ("len", Json::Int(r.len as i64)),
                        ("data", Json::str(&r.data)),
                    ])
                })),
            ),
            (
                "devices",
                Json::arr(self.devices.iter().map(|d| {
                    Json::obj(vec![
                        ("base", Json::Int(d.base as i64)),
                        ("kind", Json::str(&d.kind)),
                        (
                            "state",
                            Json::arr(d.state.iter().map(|(k, v)| {
                                Json::obj(vec![("name", Json::str(k)), ("value", v.clone())])
                            })),
                        ),
                    ])
                })),
            ),
        ])
    }

    /// Parse a checkpoint from JSON.
    pub fn from_json(j: &Json) -> Option<Self> {
        let Json::Obj(o) = j else {
            return None;
        };
        let get_u64 = |k: &str| match o.get(k)? {
            Json::Int(i) => Some(*i as u64),
            _ => None,
        };
        let get_u8 = |k: &str| match o.get(k)? {
            Json::Int(i) => Some(*i as u8),
            _ => None,
        };
        let u64s = |k: &str| -> Option<Vec<u64>> {
            let Json::Arr(items) = o.get(k)? else {
                return None;
            };
            items
                .iter()
                .map(|x| match x {
                    Json::Int(i) => Some(*i as u64),
                    _ => None,
                })
                .collect()
        };
        Some(Self {
            record_order: get_u64("record_order")?,
            x: u64s("x")?,
            pc: get_u64("pc")?,
            f: u64s("f")?,
            fcsr: get_u64("fcsr")?,
            prv: get_u8("prv")?,
            instret: get_u64("instret")?,
            reservation: match o.get("reservation")? {
                Json::Null => None,
                Json::Int(i) => Some(*i as u64),
                _ => return None,
            },
            fault_addr: get_u64("fault_addr")?,
            clock_instret: get_u64("clock_instret")?,
            clock_instret_per_tick: get_u64("clock_instret_per_tick")?,
            csr: {
                let Json::Arr(items) = o.get("csr")? else {
                    return None;
                };
                items
                    .iter()
                    .map(|c| {
                        let Json::Obj(o) = c else {
                            return None;
                        };
                        let name = match o.get("name")? {
                            Json::Str(s) => s.clone(),
                            _ => return None,
                        };
                        let value = match o.get("value")? {
                            Json::Int(i) => *i as u64,
                            _ => return None,
                        };
                        Some((name, value))
                    })
                    .collect::<Option<Vec<_>>>()?
            },
            memory: {
                let Json::Arr(items) = o.get("memory")? else {
                    return None;
                };
                items
                    .iter()
                    .map(|r| {
                        let Json::Obj(o) = r else {
                            return None;
                        };
                        Some(MemRegion {
                            base: match o.get("base")? {
                                Json::Int(i) => *i as u64,
                                _ => return None,
                            },
                            len: match o.get("len")? {
                                Json::Int(i) => *i as u64,
                                _ => return None,
                            },
                            data: match o.get("data")? {
                                Json::Str(s) => s.clone(),
                                _ => return None,
                            },
                        })
                    })
                    .collect::<Option<Vec<_>>>()?
            },
            devices: {
                let Json::Arr(items) = o.get("devices")? else {
                    return None;
                };
                items
                    .iter()
                    .map(|d| {
                        let Json::Obj(o) = d else {
                            return None;
                        };
                        let base = match o.get("base")? {
                            Json::Int(i) => *i as u64,
                            _ => return None,
                        };
                        let kind = match o.get("kind")? {
                            Json::Str(s) => s.clone(),
                            _ => return None,
                        };
                        let Json::Arr(state_items) = o.get("state")? else {
                            return None;
                        };
                        let state = state_items
                            .iter()
                            .map(|s| {
                                let Json::Obj(o) = s else {
                                    return None;
                                };
                                let name = match o.get("name")? {
                                    Json::Str(s) => s.clone(),
                                    _ => return None,
                                };
                                let value = o.get("value")?.clone();
                                Some((name, value))
                            })
                            .collect::<Option<Vec<_>>>()?;
                        Some(DeviceSnapshot { base, kind, state })
                    })
                    .collect::<Option<Vec<_>>>()?
            },
        })
    }
}

/// Read a checkpoint from a file.
pub fn read_checkpoint<P: AsRef<Path>>(path: P) -> Result<Checkpoint, String> {
    let text = fs::read_to_string(path.as_ref())
        .map_err(|e| format!("cannot read {}: {e}", path.as_ref().display()))?;
    let j = Json::parse(&text).map_err(|e| format!("invalid JSON: {e}"))?;
    Checkpoint::from_json(&j).ok_or_else(|| "not a valid checkpoint".to_string())
}

/// Write a checkpoint to a file.
pub fn write_checkpoint<P: AsRef<Path>>(path: P, cp: &Checkpoint) -> Result<(), String> {
    let text = cp.to_json().to_pretty();
    fs::write(path.as_ref(), text)
        .map_err(|e| format!("cannot write {}: {e}", path.as_ref().display()))
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
        assert!(Fidelity::Measured.comparable_for_equality());
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

    #[test]
    fn record_file_round_trips_through_json() {
        let mut m = TargetModel::new("t");
        m.profile = Profile::Virt;
        let rf = RecordFile::from_model_and_records(&m, vec![rec(0, 0x1000), rec(1, 0x1004)]);
        let j = rf.to_json();
        let parsed = RecordFile::from_json(&j).expect("parse record file");
        assert_eq!(parsed, rf);
    }

    #[test]
    fn checkpoint_round_trips_through_json() {
        let cp = Checkpoint {
            record_order: 5,
            x: (0..32).collect(),
            pc: 0x8000_0000,
            f: vec![0xffff_ffff_7fc0_0000; 32],
            fcsr: 0,
            prv: 3,
            instret: 10,
            reservation: Some(0x9000_0000),
            fault_addr: 0,
            csr: vec![("mstatus".into(), 0)],
            clock_instret: 10,
            clock_instret_per_tick: 1,
            memory: vec![MemRegion {
                base: 0x8000_0000,
                len: 4,
                data: "efbeadde".into(),
            }],
            devices: vec![],
        };
        let j = cp.to_json();
        let parsed = Checkpoint::from_json(&j).expect("parse checkpoint");
        assert_eq!(parsed, cp);
    }

    #[test]
    fn record_file_round_trips_through_temp_file() {
        let mut m = TargetModel::new("t");
        m.mark_unfaithful();
        let rf = RecordFile::from_model_and_records(&m, vec![rec(0, 0x1000)]);
        let tmp = std::env::temp_dir().join("g6q-record-file-test.json");
        write_record_file(&tmp, &rf).unwrap();
        let back = read_record_file(&tmp).unwrap();
        assert_eq!(back, rf);
        let _ = std::fs::remove_file(&tmp);
    }
}
