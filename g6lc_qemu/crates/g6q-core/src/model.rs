// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! The [`TargetModel`] — the single interface between ingest and every backend.
//!
//! No emitter, virtual machine or diagnosis model reads a design file directly; they all
//! read this. That one constraint is what keeps the backends consistent with each other
//! and with the design ([`architecture/IR.md`]).
//!
//! Q0 defines the skeleton and the invariants that are expensive to retrofit: the machine
//! profile, the faithfulness flag, provenance, and canonical rendering. Ingest fills it in
//! at Q1.
//!
//! [`architecture/IR.md`]: ../../../architecture/IR.md

use crate::conform::Report;
use crate::json::Json;

/// Schema version of the emitted model document.
///
/// Consumers read this before the payload. A field rename is a bump plus a fixture
/// update, never a silent reinterpretation.
pub const SCHEMA_VERSION: &str = "1";

/// Which machine is being described.
///
/// These are never merged. The faithful profile is the only one any diagnosis may cite;
/// the virt profile exists so an operating system that needs a disk and a network can
/// boot, and its results are software-valid and hardware-invalid
/// ([`architecture/DESIGN.md`] §4).
///
/// [`architecture/DESIGN.md`]: ../../../architecture/DESIGN.md
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Profile {
    /// Byte-faithful to the design's SoC description. No PCI, no virtio.
    #[default]
    Soc,
    /// The faithful machine plus virtio transports and a configurable RAM window.
    Virt,
}

impl Profile {
    /// The stable wire name, also the machine id passed to a backend.
    pub fn as_str(self) -> &'static str {
        match self {
            Profile::Soc => "g6lc-soc",
            Profile::Virt => "g6lc-virt",
        }
    }

    /// Whether diagnosis output from this profile may be trusted without a taint flag.
    pub fn diagnosable(self) -> bool {
        matches!(self, Profile::Soc)
    }
}

/// Where a model came from, so that a document attached to a bug report is
/// self-describing and a stale one is detectable.
#[derive(Debug, Clone, Default)]
pub struct Provenance {
    /// Absolute path of the design tree that was read, when one was used.
    pub design_root: Option<String>,
    /// Design revision, when discoverable.
    pub design_rev: Option<String>,
    /// `(path, sha256)` for every file ingested.
    pub sources: Vec<(String, String)>,
    /// The `+define+` set in effect.
    pub defines: Vec<String>,
    /// `(field, value, origin)` for every command-line override.
    pub overrides: Vec<(String, String, String)>,
}

impl Provenance {
    /// Render as JSON.
    pub fn to_json(&self) -> Json {
        Json::obj([
            (
                "design_root",
                self.design_root.as_deref().map_or(Json::Null, Json::str),
            ),
            (
                "design_rev",
                self.design_rev.as_deref().map_or(Json::Null, Json::str),
            ),
            (
                "sources",
                Json::arr(
                    self.sources.iter().map(|(p, h)| {
                        Json::obj([("path", Json::str(p)), ("sha256", Json::str(h))])
                    }),
                ),
            ),
            ("defines", Json::arr(self.defines.iter().map(Json::str))),
            (
                "overrides",
                Json::arr(self.overrides.iter().map(|(f, v, o)| {
                    Json::obj([
                        ("field", Json::str(f)),
                        ("value", Json::str(v)),
                        ("origin", Json::str(o)),
                    ])
                })),
            ),
        ])
    }
}

/// One memory-mapped peripheral.
#[derive(Debug, Clone)]
pub struct Peripheral {
    /// Short identifier, e.g. `"clint"`, `"uart"`.
    pub id: String,
    /// Base address.
    pub base: u64,
    /// Window length in bytes.
    pub len: u64,
    /// Device model name for the backend, when one is known.
    pub model: Option<String>,
    /// External interrupt line, when the device has one.
    pub irq: Option<u32>,
}

impl Peripheral {
    /// Render as JSON.
    pub fn to_json(&self) -> Json {
        Json::obj([
            ("id", Json::str(&self.id)),
            ("base", Json::addr(self.base)),
            ("len", Json::addr(self.len)),
            ("model", self.model.as_deref().map_or(Json::Null, Json::str)),
            ("irq", self.irq.map_or(Json::Null, |i| Json::Int(i as i64))),
        ])
    }

    /// The half-open address range this peripheral occupies.
    pub fn range(&self) -> (u64, u64) {
        (self.base, self.base.saturating_add(self.len))
    }

    /// Whether two windows overlap. Used by the memory-map self-check.
    pub fn overlaps(&self, other: &Peripheral) -> bool {
        let (a0, a1) = self.range();
        let (b0, b1) = other.range();
        a0 < b1 && b0 < a1
    }
}

/// The system-on-chip view: memory map, interrupt geometry, hart count.
#[derive(Debug, Clone, Default)]
pub struct Soc {
    /// Memory-mapped peripherals.
    pub peripherals: Vec<Peripheral>,
    /// Main memory base and length.
    pub dram: Option<(u64, u64)>,
    /// External interrupt sources.
    pub intc_sources: u32,
    /// External interrupt contexts (targets).
    pub intc_targets: u32,
    /// Interrupt contexts consumed per hart, typically one per privilege level served.
    pub contexts_per_hart: u32,
    /// Total logical harts: cores multiplied by threads per core.
    pub harts_total: u32,
}

impl Soc {
    /// Maximum logical harts the interrupt controller can serve.
    ///
    /// This is the constraint that silently caps how many CPUs a guest can be given, so
    /// it is computed rather than assumed.
    pub fn max_harts(&self) -> u32 {
        if self.contexts_per_hart == 0 {
            return 0;
        }
        self.intc_targets / self.contexts_per_hart
    }

    /// Whether the configured hart count fits the interrupt controller.
    pub fn hart_count_fits(&self) -> bool {
        self.harts_total <= self.max_harts()
    }

    /// Any pair of overlapping peripheral windows. Empty is the expected result.
    pub fn overlapping(&self) -> Vec<(String, String)> {
        let mut out = Vec::new();
        for (i, a) in self.peripherals.iter().enumerate() {
            for b in &self.peripherals[i + 1..] {
                if a.overlaps(b) {
                    out.push((a.id.clone(), b.id.clone()));
                }
            }
        }
        out
    }

    /// Render as JSON.
    pub fn to_json(&self) -> Json {
        Json::obj([
            (
                "peripherals",
                Json::arr(self.peripherals.iter().map(Peripheral::to_json)),
            ),
            (
                "dram",
                self.dram.map_or(Json::Null, |(b, l)| {
                    Json::obj([("base", Json::addr(b)), ("len", Json::addr(l))])
                }),
            ),
            (
                "intc",
                Json::obj([
                    ("sources", Json::Int(self.intc_sources as i64)),
                    ("targets", Json::Int(self.intc_targets as i64)),
                    (
                        "contexts_per_hart",
                        Json::Int(self.contexts_per_hart as i64),
                    ),
                    ("max_harts", Json::Int(self.max_harts() as i64)),
                ]),
            ),
            ("harts_total", Json::Int(self.harts_total as i64)),
        ])
    }
}

/// The instruction-set view.
#[derive(Debug, Clone, Default)]
pub struct Isa {
    /// Register width in bits.
    pub xlen: u32,
    /// Base integer ISA name, e.g. `"rv64i"`.
    pub base: String,
    /// `(token, verdict)` for every extension, using the conformance vocabulary so a
    /// stub is never mistaken for a live feature.
    pub extensions: Vec<(String, String)>,
    /// The ISA string as advertised to software.
    pub isa_string: String,
    /// Address-translation mode name, when the design has an MMU.
    pub mmu_mode: Option<String>,
}

impl Isa {
    /// Render as JSON.
    pub fn to_json(&self) -> Json {
        Json::obj([
            ("xlen", Json::Int(self.xlen as i64)),
            ("base", Json::str(&self.base)),
            (
                "extensions",
                Json::obj(
                    self.extensions
                        .iter()
                        .map(|(k, v)| (k.clone(), Json::str(v))),
                ),
            ),
            ("isa_string", Json::str(&self.isa_string)),
            (
                "mmu_mode",
                self.mmu_mode.as_deref().map_or(Json::Null, Json::str),
            ),
        ])
    }
}

/// The complete model.
#[derive(Debug, Clone, Default)]
pub struct TargetModel {
    /// Target identifier, normally the configuration package name.
    pub target_id: String,
    /// Which planes were ingested: `core`, `apu` or `soc`.
    pub plane: String,
    /// Machine profile.
    pub profile: Profile,
    /// False as soon as any override deviates from the design's own description.
    pub faithful: bool,
    /// Where the facts came from.
    pub provenance: Provenance,
    /// Instruction-set view.
    pub isa: Isa,
    /// System-on-chip view.
    pub soc: Soc,
    /// Conformance verdicts.
    pub conformance: Report,
}

impl TargetModel {
    /// A model with the given target id, faithful by default.
    pub fn new(target_id: impl Into<String>) -> Self {
        Self {
            target_id: target_id.into(),
            plane: "soc".to_string(),
            profile: Profile::Soc,
            faithful: true,
            ..Default::default()
        }
    }

    /// Record a deviation from the design's own description.
    ///
    /// Anything that relocates a window, resizes memory, or forces a configuration field
    /// makes the machine non-faithful, and the flag travels with every artifact so a
    /// deviated run cannot be quoted as a hardware result.
    pub fn mark_unfaithful(&mut self) {
        self.faithful = false;
    }

    /// Whether diagnosis may be run without an explicit taint override.
    pub fn diagnosable(&self) -> bool {
        self.profile.diagnosable() && self.faithful
    }

    /// Render the canonical model document.
    pub fn to_json(&self) -> Json {
        Json::obj([
            ("schema_version", Json::str(SCHEMA_VERSION)),
            (
                "generated_by",
                Json::obj([
                    ("tool", Json::str("g6lc-qemu")),
                    ("version", Json::str(env!("CARGO_PKG_VERSION"))),
                ]),
            ),
            ("provenance", self.provenance.to_json()),
            (
                "target",
                Json::obj([
                    ("id", Json::str(&self.target_id)),
                    ("plane", Json::str(&self.plane)),
                    ("profile", Json::str(self.profile.as_str())),
                    ("faithful", Json::Bool(self.faithful)),
                ]),
            ),
            ("isa", self.isa.to_json()),
            ("soc", self.soc.to_json()),
            ("conformance", self.conformance.to_json()),
        ])
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::conform::{Inputs, Row};

    fn periph(id: &str, base: u64, len: u64) -> Peripheral {
        Peripheral {
            id: id.into(),
            base,
            len,
            model: None,
            irq: None,
        }
    }

    #[test]
    fn profile_names_are_stable() {
        assert_eq!(Profile::Soc.as_str(), "g6lc-soc");
        assert_eq!(Profile::Virt.as_str(), "g6lc-virt");
    }

    #[test]
    fn only_the_faithful_profile_is_diagnosable() {
        let mut m = TargetModel::new("t");
        assert!(m.diagnosable());
        m.profile = Profile::Virt;
        assert!(!m.diagnosable());
    }

    #[test]
    fn deviation_clears_faithfulness_permanently() {
        let mut m = TargetModel::new("t");
        m.mark_unfaithful();
        assert!(!m.faithful);
        assert!(
            !m.diagnosable(),
            "an unfaithful soc machine must not be diagnosable"
        );
    }

    #[test]
    fn interrupt_contexts_cap_the_hart_count() {
        // Two contexts per hart against sixteen targets means eight logical harts.
        let mut soc = Soc {
            intc_targets: 16,
            contexts_per_hart: 2,
            harts_total: 8,
            ..Soc::default()
        };
        assert_eq!(soc.max_harts(), 8);
        assert!(soc.hart_count_fits());
        soc.harts_total = 9;
        assert!(!soc.hart_count_fits());
    }

    #[test]
    fn zero_contexts_per_hart_does_not_divide_by_zero() {
        let soc = Soc {
            intc_targets: 16,
            contexts_per_hart: 0,
            ..Soc::default()
        };
        assert_eq!(soc.max_harts(), 0);
    }

    #[test]
    fn overlapping_windows_are_detected() {
        let soc = Soc {
            peripherals: vec![
                periph("rom", 0x1_0000, 0x1_0000),
                periph("clint", 0x200_0000, 0xc_0000),
                periph("shadow", 0x1_8000, 0x1000),
            ],
            ..Soc::default()
        };
        let bad = soc.overlapping();
        assert_eq!(bad.len(), 1);
        assert_eq!(bad[0], ("rom".to_string(), "shadow".to_string()));
    }

    #[test]
    fn a_clean_map_reports_no_overlap() {
        let soc = Soc {
            peripherals: vec![
                periph("rom", 0x1_0000, 0x1_0000),
                periph("clint", 0x200_0000, 0xc_0000),
                periph("uart", 0x1000_0000, 0x1000),
            ],
            ..Soc::default()
        };
        assert!(soc.overlapping().is_empty());
    }

    #[test]
    fn model_json_carries_schema_profile_and_faithfulness() {
        let mut m = TargetModel::new("example-target");
        m.conformance
            .push(Row::classify("zacas", Inputs::new(true, true, true)));
        let text = m.to_json().to_pretty();
        assert!(text.contains("\"schema_version\": \"1\""), "{text}");
        assert!(text.contains("\"profile\": \"g6lc-soc\""), "{text}");
        assert!(text.contains("\"faithful\": true"), "{text}");
        assert!(text.contains("example-target"), "{text}");
    }

    #[test]
    fn model_rendering_is_deterministic() {
        let m = TargetModel::new("t");
        assert_eq!(m.to_json().to_pretty(), m.to_json().to_pretty());
    }
}
