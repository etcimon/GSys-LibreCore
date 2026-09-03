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
use crate::pmu::PmuTable;

/// Schema version of the emitted model document.
///
/// Consumers read this before the payload. A field rename is a bump plus a fixture
/// update, never a silent reinterpretation.
pub const SCHEMA_VERSION: &str = "2";

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
    /// `(field, change, reason)` for every derivation the design's build step applies.
    ///
    /// These are **not** overrides and do not taint the model: they are what the design
    /// itself elaborates from the written package. They are recorded because a reader
    /// comparing the model against the package would otherwise see an unexplained
    /// difference, and because a derivation the emulator applies wrongly is invisible
    /// unless it is stated.
    pub derivations: Vec<(String, String, String)>,
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
            (
                "derivations",
                Json::arr(self.derivations.iter().map(|(f, c, r)| {
                    Json::obj([
                        ("field", Json::str(f)),
                        ("change", Json::str(c)),
                        ("reason", Json::str(r)),
                    ])
                })),
            ),
        ])
    }
}

/// One memory-mapped peripheral.
#[derive(Debug, Clone, Default)]
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
    /// `reg-shift` for 16550-style UARTs, in bytes.
    pub reg_shift: Option<u32>,
    /// `reg-io-width` for 16550-style UARTs, in bytes.
    pub reg_io_width: Option<u32>,
    /// `clock-frequency` for peripheral baud-rate generation, in Hz.
    pub clock_frequency: Option<u64>,
    /// `current-speed` for 16550-style UARTs, in baud.
    pub current_speed: Option<u64>,
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
            (
                "reg_shift",
                self.reg_shift.map_or(Json::Null, |i| Json::Int(i as i64)),
            ),
            (
                "reg_io_width",
                self.reg_io_width
                    .map_or(Json::Null, |i| Json::Int(i as i64)),
            ),
            (
                "clock_frequency",
                self.clock_frequency
                    .map_or(Json::Null, |i| Json::Int(i as i64)),
            ),
            (
                "current_speed",
                self.current_speed
                    .map_or(Json::Null, |i| Json::Int(i as i64)),
            ),
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

/// One field inside a packed capability word.
///
/// The `name` is the `AiIslandConfig` field that supplies the value (e.g. `queues`), or a
/// placeholder for fields that are not modeled (e.g. a measured counter). The `low` and `width`
/// are the bit position inside the 32-bit capability word.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CapPackedField {
    /// Field name. A leading underscore means the value is not in the config struct.
    pub name: String,
    /// Low bit inside the packed word.
    pub low: u32,
    /// Width in bits.
    pub width: u32,
}

impl CapPackedField {
    /// Render as a JSON object.
    pub fn to_json(&self) -> Json {
        Json::obj([
            ("name", Json::str(self.name.clone())),
            ("low", Json::Int(self.low as i64)),
            ("width", Json::Int(self.width as i64)),
        ])
    }
}

/// Packed capability words whose bit layout is not a single flat value.
///
/// The map is keyed by the capability name (the lowercased `CAP_OFF_*` suffix). Each entry is a
/// list of fields ordered from LSB to MSB. Unknown field names are treated as zero so measured or
/// reserved upper fields do not need a model value.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CapPackedWords {
    /// Map from capability name to the ordered list of packed fields.
    pub words: std::collections::BTreeMap<String, Vec<CapPackedField>>,
}

impl CapPackedWords {
    /// Render as a JSON object keyed by capability name.
    pub fn to_json(&self) -> Json {
        Json::obj(self.words.iter().map(|(k, v)| {
            (
                k.as_str(),
                Json::arr(v.iter().map(|f| f.to_json()).collect::<Vec<_>>()),
            )
        }))
    }
}

/// Bit layout of the packed `block_mnk` capability word.
///
/// Each field records the low bit and width of `log2(AccTileM|N|K)` inside the 32-bit word.
/// Width is present because the cap window could widen or narrow the field; the model does not
/// assume it is always four bits.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct CapBlockMnk {
    /// Low bit of the M field.
    pub m_low: u32,
    /// Width in bits of the M field.
    pub m_width: u32,
    /// Low bit of the N field.
    pub n_low: u32,
    /// Width in bits of the N field.
    pub n_width: u32,
    /// Low bit of the K field.
    pub k_low: u32,
    /// Width in bits of the K field.
    pub k_width: u32,
}

impl CapBlockMnk {
    /// Render as a JSON object.
    pub fn to_json(&self) -> Json {
        Json::obj([
            ("m_low", Json::Int(self.m_low as i64)),
            ("m_width", Json::Int(self.m_width as i64)),
            ("n_low", Json::Int(self.n_low as i64)),
            ("n_width", Json::Int(self.n_width as i64)),
            ("k_low", Json::Int(self.k_low as i64)),
            ("k_width", Json::Int(self.k_width as i64)),
        ])
    }
}

/// AI-island capability and clustering configuration, derived from
/// `g6lc_ai_island_cfg_pkg.sv`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AiIslandConfig {
    /// Capability window contract version.
    pub cap_version: u16,
    /// Number of island clusters (replication unit).
    pub clusters: u32,
    /// Dense INT8 MACs per cycle per cluster.
    pub macs_per_cycle: u32,
    /// Island clock in kHz.
    pub clock_khz: u32,
    /// Per-cluster staging + weight SRAM in bytes.
    pub sram_bytes: u64,
    /// Island blocking M row.
    pub acc_tile_m: u32,
    /// Island blocking N row.
    pub acc_tile_n: u32,
    /// Island blocking K row.
    pub acc_tile_k: u32,
    /// NoC width in bits.
    pub noc_width: u32,
    /// Number of DRAM channels.
    pub dram_channels: u32,
    /// Nameplate aggregate DRAM bandwidth in GB/s (0 when not measured).
    pub dram_gbps: u32,
    /// Measured sustained aggregate DRAM bandwidth in milli-GB/s, when a measurement is
    /// available. This is the value the cap window returns in its `meas_milli` half, and it
    /// takes precedence over the nameplate in the roofline when present.
    pub measured_dram_gbps_x1000: Option<u32>,
    /// T2 rings visible to the island.
    pub queues: u32,
    /// Depth of each queue (power of two expected).
    pub queue_depth: u32,
    /// Number of QoS classes.
    pub qos_classes: u32,
    /// Preemption boundary in k-steps.
    pub work_quantum_k: u32,
    /// Bit layout of the packed `block_mnk` capability word, when the design publishes it.
    ///
    /// The cap window packs `log2(AccTileM)`, `log2(AccTileN)` and `log2(AccTileK)` into one
    /// 32-bit word. The generator reads the concatenation order and widths from
    /// `g6lc_ai_cap_window.sv`; if the module does not publish a recognizable case arm, this
    /// stays `None` and the word is reported through `cap_unsourced`.
    pub block_mnk: Option<CapBlockMnk>,
    /// Other packed capability words (e.g. `dram_gbps`, `queues`) whose bit layout the cap
    /// window declares by concatenation. Each word is a list of fields from LSB to MSB.
    pub cap_packed: CapPackedWords,
    /// Data-type grant bits the cap window reports, when the design publishes them.
    ///
    /// This value lives as a module parameter in `g6lc_ai_cap_window.sv`; the generator reads it
    /// from there because the `ai_island_cfg_t` package does not carry it. If even the cap window
    /// does not publish it, this stays `None` and the word is reported through `cap_unsourced`.
    pub dtype_mask: Option<u32>,
    /// Capability window offsets by name, from `CAP_OFF_*` localparams.
    pub cap_offsets: std::collections::BTreeMap<String, u64>,
    /// Island PMU register offsets by name, from `PMU_OFF_*` localparams.
    ///
    /// These are the island's own *measured* counters (bus beats, active cycles, sustained
    /// bandwidth). They are the only quantities that can contradict the modelled bound in
    /// `g6q-diag::roofline`, which is why ingesting them matters: a modelled number never
    /// diffed against a measurement is decoration rather than feedback.
    ///
    /// Empty when the design publishes the register map only as comments, which is the
    /// current state — recorded as ask F9 in `architecture/RTL_FEEDBACK.md`.
    pub pmu_offsets: std::collections::BTreeMap<String, u64>,
    /// Island control-surface offsets by name, from `REG_OFF_*` localparams.
    ///
    /// These are the registers a driver writes to *operate* the island — control, status,
    /// doorbell, completion claim, per-queue region programming — as opposed to the
    /// read-only capability window. They are the second half of ask F1: the descriptor
    /// window placement alone lets a guest find the descriptor, but not ring the bell.
    ///
    /// Names are the `REG_OFF_` suffix, lowercased: `ctl`, `status`, `doorbell`, `cpl`,
    /// `queue`, `cap`, `desc`. Empty when the design publishes the map only as comments,
    /// in which case a backend falls back to a *derived* placement and says so.
    pub reg_offsets: std::collections::BTreeMap<String, u64>,
    /// Base of the capability window inside the island MMIO region, when the design
    /// states it.
    ///
    /// `None` means *not resolved*, which is different from zero. The capability
    /// *offsets* come from the configuration package, but the *placement* of the window
    /// is decided by the island's address decode — so a design that does not publish the
    /// base leaves this unresolved rather than defaulting, per [`INGEST.md`] §2.1.
    pub cap_base: Option<u64>,
    /// Base of the descriptor latch window inside the island MMIO region, when stated.
    ///
    /// Descriptor field offsets are relative to this base. As with [`Self::cap_base`],
    /// absence is reported rather than assumed: guessing a base would place the whole
    /// descriptor at the wrong address and make every field look individually plausible.
    pub desc_base: Option<u64>,
    /// Queue-to-cluster map, when the design publishes it.
    ///
    /// The `i`-th entry is the cluster that queue `i` dispatches to; shorter lists wrap.
    /// If the design does not publish a dispatch map, this stays `None` and the B3 path
    /// falls back to a `cluster` field in the descriptor or leaves the event unresolved.
    pub queue_cluster_map: Option<Vec<u32>>,
}

impl AiIslandConfig {
    /// Render as a JSON object.
    pub fn to_json(&self) -> Json {
        Json::obj([
            ("cap_version", Json::Int(self.cap_version as i64)),
            ("clusters", Json::Int(self.clusters as i64)),
            ("macs_per_cycle", Json::Int(self.macs_per_cycle as i64)),
            ("clock_khz", Json::Int(self.clock_khz as i64)),
            ("sram_bytes", Json::Int(self.sram_bytes as i64)),
            ("acc_tile_m", Json::Int(self.acc_tile_m as i64)),
            ("acc_tile_n", Json::Int(self.acc_tile_n as i64)),
            ("acc_tile_k", Json::Int(self.acc_tile_k as i64)),
            ("noc_width", Json::Int(self.noc_width as i64)),
            ("dram_channels", Json::Int(self.dram_channels as i64)),
            ("dram_gbps", Json::Int(self.dram_gbps as i64)),
            (
                "measured_dram_gbps_x1000",
                self.measured_dram_gbps_x1000
                    .map_or(Json::Null, |v| Json::Int(v as i64)),
            ),
            ("queues", Json::Int(self.queues as i64)),
            ("queue_depth", Json::Int(self.queue_depth as i64)),
            ("qos_classes", Json::Int(self.qos_classes as i64)),
            ("work_quantum_k", Json::Int(self.work_quantum_k as i64)),
            (
                "dtype_mask",
                self.dtype_mask.map_or(Json::Null, |v| Json::Int(v as i64)),
            ),
            (
                "block_mnk",
                self.block_mnk.map_or(Json::Null, |c| c.to_json()),
            ),
            ("cap_packed", self.cap_packed.to_json()),
            (
                "cap_offsets",
                Json::obj(
                    self.cap_offsets
                        .iter()
                        .map(|(k, v)| (k.as_str(), Json::Int(*v as i64))),
                ),
            ),
            (
                "pmu_offsets",
                Json::obj(
                    self.pmu_offsets
                        .iter()
                        .map(|(k, v)| (k.as_str(), Json::Int(*v as i64))),
                ),
            ),
            (
                "reg_offsets",
                Json::obj(
                    self.reg_offsets
                        .iter()
                        .map(|(k, v)| (k.as_str(), Json::Int(*v as i64))),
                ),
            ),
            (
                "cap_base",
                self.cap_base.map_or(Json::Null, |v| Json::Int(v as i64)),
            ),
            (
                "desc_base",
                self.desc_base.map_or(Json::Null, |v| Json::Int(v as i64)),
            ),
            (
                "queue_cluster_map",
                self.queue_cluster_map.as_ref().map_or(Json::Null, |m| {
                    Json::arr(m.iter().map(|v| Json::Int(*v as i64)))
                }),
            ),
        ])
    }

    /// Resolve a queue id to a cluster using the published map, if any.
    pub fn cluster_for_queue(&self, queue_id: u32) -> Option<u32> {
        self.queue_cluster_map.as_ref().map(|m| {
            let idx = (queue_id as usize) % m.len();
            m[idx]
        })
    }

    /// Whether the island's MMIO placement is fully resolved.
    ///
    /// Reported so a caller can distinguish "the guest cannot address this island" from
    /// "the island has no capabilities", which are very different findings.
    pub fn placement_resolved(&self) -> bool {
        self.cap_base.is_some() && self.desc_base.is_some()
    }

    /// Island-relative offset of a control register the design publishes.
    ///
    /// `None` means the design did not name it, which is different from "it is at zero":
    /// a backend must fall back visibly rather than invent a doorbell address.
    pub fn reg_offset(&self, name: &str) -> Option<u64> {
        self.reg_offsets.get(name).copied()
    }

    /// Whether the island can be *operated* from the published map, not merely addressed.
    ///
    /// [`Self::placement_resolved`] answers "can a guest find the descriptor window".
    /// This answers the question that actually gates an in-guest driver: is there a
    /// published doorbell to ring and a published completion register to claim?
    pub fn control_surface_resolved(&self) -> bool {
        self.reg_offset("doorbell").is_some() && self.reg_offset("cpl").is_some()
    }

    /// Capability words the guest may read, as window-relative offset -> value.
    ///
    /// This lives in the IR rather than in a backend because *every* backend has to answer
    /// the same window: the native VM answers it directly, the generated QEMU device
    /// answers it from an emitted table, and a divergence between them is indistinguishable
    /// from a design bug. Words this configuration cannot source are omitted, not zeroed —
    /// zero is a legal capability value, so a zero would look like a real answer.
    pub fn cap_words(&self) -> Vec<(u64, u64)> {
        let mut out: Vec<(u64, u64)> = self
            .cap_offsets
            .iter()
            .filter_map(|(name, off)| self.cap_value(name).map(|v| (*off, v)))
            .collect();
        out.sort_unstable();
        out
    }

    /// Source one capability word from the configuration, by the design's own name.
    ///
    /// Returning `None` means *this configuration cannot source that word*, which callers
    /// report through [`Self::cap_unsourced`].
    pub fn cap_value(&self, name: &str) -> Option<u64> {
        // Names are the package's `CAP_OFF_*` suffixes, lowercased by the reader.
        match name {
            "version" => Some(self.cap_version as u64),
            "clusters" => Some(self.clusters as u64),
            "macs_cycle" | "macs_per_cycle" => Some(self.macs_per_cycle as u64),
            "clock_khz" => Some(self.clock_khz as u64),
            "sram_bytes" => Some(self.sram_bytes),
            "qos" | "qos_classes" => Some(self.qos_classes as u64),
            "quantum" | "work_quantum_k" => Some(self.work_quantum_k as u64),
            "acc_tile_m" => Some(self.acc_tile_m as u64),
            "acc_tile_n" => Some(self.acc_tile_n as u64),
            "acc_tile_k" => Some(self.acc_tile_k as u64),
            "noc_width" => Some(self.noc_width as u64),
            "dram_channels" => Some(self.dram_channels as u64),
            "dtype_mask" => self.dtype_mask.map(|v| v as u64),
            "block_mnk" => self.pack_block_mnk(),
            // Packed words have a field list in the model.
            _ => self.pack_cap_packed(name),
        }
    }

    /// Capability words the model names but this configuration cannot source, with offsets.
    ///
    /// This exists so a capability added to the design shows up as a tracked gap instead of
    /// silently disappearing from the guest-visible window.
    pub fn cap_unsourced(&self) -> Vec<(String, u64)> {
        let mut out: Vec<(String, u64)> = self
            .cap_offsets
            .iter()
            .filter(|(name, _)| self.cap_value(name).is_none())
            .map(|(name, off)| (name.clone(), *off))
            .collect();
        out.sort();
        out
    }

    fn pack_block_mnk(&self) -> Option<u64> {
        let layout = self.block_mnk?;
        Some(
            ((clog2_u32(self.acc_tile_m) as u64) << layout.m_low)
                | ((clog2_u32(self.acc_tile_n) as u64) << layout.n_low)
                | ((clog2_u32(self.acc_tile_k) as u64) << layout.k_low),
        )
    }

    fn pack_cap_packed(&self, name: &str) -> Option<u64> {
        let fields = self.cap_packed.words.get(name)?;
        let mut word: u64 = 0;
        for field in fields {
            let value = self.packed_field_value(&field.name)?;
            let mask = if field.width >= 64 {
                !0u64
            } else {
                (1u64 << field.width) - 1
            };
            word |= (value & mask) << field.low;
        }
        Some(word)
    }

    fn packed_field_value(&self, name: &str) -> Option<u64> {
        if name == "_meas_milli" {
            // The cap window's `meas_milli` half reports sustained GB/s from the last GEMM,
            // in units of 1/1000 GB/s, saturated to 16 bits to match the RTL packing.
            // When no measurement is supplied the field is zero (not yet measured).
            return Some(self.measured_dram_gbps_x1000.unwrap_or(0).min(0xFFFF) as u64);
        }
        if name.starts_with('_') {
            // Other design-side fields not in the config struct are zero.
            return Some(0);
        }
        match name {
            "dram_gbps" => Some(self.dram_gbps as u64),
            "queues" => Some(self.queues as u64),
            "queue_depth" => Some(self.queue_depth as u64),
            "dtype_mask" => self.dtype_mask.map(|v| v as u64),
            _ => None,
        }
    }
}

/// Ceiling of log2 of a positive 32-bit value; matches SystemVerilog `$clog2`.
///
/// `$clog2(0) = 0` in the reference cap-window implementation, so the helper returns 0 for 0.
pub fn clog2_u32(v: u32) -> u32 {
    if v == 0 {
        0
    } else if v.is_power_of_two() {
        v.trailing_zeros()
    } else {
        32 - v.leading_zeros()
    }
}

/// A field inside a packed AI descriptor (`desc_t`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DescField {
    /// Byte offset inside the descriptor.
    pub offset: u64,
    /// Size in bytes.
    pub size: u64,
    /// Low bit inside the packed `desc_bits_t`.
    pub bit_low: u64,
    /// High bit inside the packed `desc_bits_t`.
    pub bit_high: u64,
}

impl DescField {
    /// Render as JSON.
    pub fn to_json(&self) -> Json {
        Json::obj([
            ("offset", Json::Int(self.offset as i64)),
            ("size", Json::Int(self.size as i64)),
            ("bit_low", Json::Int(self.bit_low as i64)),
            ("bit_high", Json::Int(self.bit_high as i64)),
        ])
    }
}

/// One packed subfield of the descriptor `flags` word.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct FlagField {
    /// Low bit position inside `flags`.
    pub shift: u32,
    /// Mask of the field, after shifting.
    pub mask: u32,
}

impl FlagField {
    /// Build from an inclusive bit range.
    pub fn from_range(high: u32, low: u32) -> Self {
        let width = high.saturating_sub(low) + 1;
        let mask = if width >= 32 {
            u32::MAX
        } else {
            (1u32 << width) - 1
        };
        Self { shift: low, mask }
    }

    /// Extract this field from a `flags` word.
    pub fn extract(&self, flags: u32) -> u32 {
        (flags >> self.shift) & self.mask
    }

    /// Render as JSON.
    pub fn to_json(&self) -> Json {
        Json::obj([
            ("shift", Json::Int(self.shift as i64)),
            ("mask", Json::Int(self.mask as i64)),
        ])
    }

    /// Parse from JSON.
    pub fn from_json(json: &Json) -> Option<Self> {
        fn u32_from(j: &Json) -> Option<u32> {
            match j {
                Json::Int(i) if *i >= 0 => Some(*i as u32),
                _ => None,
            }
        }
        Some(Self {
            shift: u32_from(json.get("shift"))?,
            mask: u32_from(json.get("mask"))?,
        })
    }
}

/// Packed subfields of the descriptor `flags` word.
///
/// The reference package does not publish these as named localparams, so the reader parses
/// the comment and helper functions (`desc_prio`, `desc_irq`) in the package. `None` means
/// the package did not expose a recognizable flags layout.
///
/// The arithmetic-type subfields (`dtype`, `accmode`, `ew`, `sp24`) are separate ABI fields.
/// A package that publishes a per-field accessor resolves them individually; a package that
/// only carries a combined `flags[hi:lo] type fields` comment resolves them as one blob, and
/// `dtype_combined` records that so no consumer reports a combined value as a data type.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct DescFlagsLayout {
    /// Low bit of the data-type selector inside `flags`.
    pub dtype_shift: u32,
    /// Mask of the data-type selector, after shifting.
    pub dtype_mask: u32,
    /// Low bit of the priority field inside `flags`.
    pub priority_shift: u32,
    /// Mask of the priority field, after shifting.
    pub priority_mask: u32,
    /// Bit index of the completion-interrupt flag inside `flags`.
    pub irq_bit: u32,
    /// True when `dtype_shift`/`dtype_mask` came from a *combined* type-field comment rather
    /// than a per-field accessor, so the extracted value mixes several ABI subfields.
    ///
    /// A consumer must not report a combined value as a data type: it is a plausible-looking
    /// wrong answer, which is worse than an unresolved one.
    pub dtype_combined: bool,
    /// Accumulate-mode selector, when the package publishes it as its own accessor.
    pub accmode: Option<FlagField>,
    /// Element-width selector, when the package publishes it as its own accessor.
    ///
    /// This is the sub-byte (INT4) lever. While it is unresolved the emulator cannot express
    /// a sub-byte request, so no backend may claim a sub-byte effective-throughput multiplier.
    pub ew: Option<FlagField>,
    /// Bit index of the structured 2:4 sparsity request, when the package publishes it.
    pub sp24_bit: Option<u32>,
}

impl DescFlagsLayout {
    /// Render as JSON.
    pub fn to_json(&self) -> Json {
        Json::obj([
            ("dtype_shift", Json::Int(self.dtype_shift as i64)),
            ("dtype_mask", Json::Int(self.dtype_mask as i64)),
            ("priority_shift", Json::Int(self.priority_shift as i64)),
            ("priority_mask", Json::Int(self.priority_mask as i64)),
            ("irq_bit", Json::Int(self.irq_bit as i64)),
            ("dtype_combined", Json::Bool(self.dtype_combined)),
            ("accmode", self.accmode.map_or(Json::Null, |f| f.to_json())),
            ("ew", self.ew.map_or(Json::Null, |f| f.to_json())),
            (
                "sp24_bit",
                self.sp24_bit.map_or(Json::Null, |b| Json::Int(b as i64)),
            ),
        ])
    }

    /// Parse from JSON. Any missing or negative *required* field makes the layout unresolved;
    /// the arithmetic-type subfields are optional and stay `None` when absent.
    pub fn from_json(json: &Json) -> Option<Self> {
        fn u32_from(j: &Json) -> Option<u32> {
            match j {
                Json::Int(i) if *i >= 0 => Some(*i as u32),
                _ => None,
            }
        }
        Some(Self {
            dtype_shift: u32_from(json.get("dtype_shift"))?,
            dtype_mask: u32_from(json.get("dtype_mask"))?,
            priority_shift: u32_from(json.get("priority_shift"))?,
            priority_mask: u32_from(json.get("priority_mask"))?,
            irq_bit: u32_from(json.get("irq_bit"))?,
            dtype_combined: matches!(json.get("dtype_combined"), Json::Bool(true)),
            accmode: FlagField::from_json(json.get("accmode")),
            ew: FlagField::from_json(json.get("ew")),
            sp24_bit: u32_from(json.get("sp24_bit")),
        })
    }

    /// True when every arithmetic-type subfield the ABI defines is individually resolved.
    ///
    /// Only then can a backend honestly distinguish an INT8 request from a sub-byte or
    /// sparse one, which is what an effective-throughput claim depends on.
    pub fn arith_type_resolved(&self) -> bool {
        !self.dtype_combined
            && self.accmode.is_some()
            && self.ew.is_some()
            && self.sp24_bit.is_some()
    }
}

/// Layout of the completion word the island writes to `ptr_done`.
///
/// Derived from the `make_completion` function in `g6lc_ai_desc_pkg.sv`. Each field gives
/// the bit range the function assigns to the ticket and status. When the package does not
/// publish the function, this is `None` and the B2 `ai.poll` path cannot decode the word.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct CompletionLayout {
    /// Low bit of the ticket field inside the 64-bit completion word.
    pub ticket_bit_low: u64,
    /// High bit of the ticket field inside the 64-bit completion word.
    pub ticket_bit_high: u64,
    /// Low bit of the status field inside the 64-bit completion word.
    pub status_bit_low: u64,
    /// High bit of the status field inside the 64-bit completion word.
    pub status_bit_high: u64,
}

/// AI descriptor layout and constants, derived from `g6lc_ai_desc_pkg.sv`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AiDescLayout {
    /// Descriptor size in bytes.
    pub desc_bytes: u64,
    /// The descriptor version the island implements, when the package names it.
    ///
    /// `None` means unresolved. The reference package validates a version in RTL without
    /// publishing the accepted value as a named constant, so a device that wants to
    /// report "bad version" has nothing to compare against. Absence is recorded rather
    /// than defaulted so the fallback is visible instead of looking model-derived.
    pub version: Option<u64>,
    /// Field name -> layout.
    pub fields: std::collections::BTreeMap<String, DescField>,
    /// Op-code name -> value.
    pub ops: std::collections::BTreeMap<String, u64>,
    /// Status-code name -> value.
    pub statuses: std::collections::BTreeMap<String, u64>,
    /// Packed `flags` word layout, when the package exposes it through comments or helpers.
    pub flags_layout: Option<DescFlagsLayout>,
    /// Completion word layout, when the package publishes it through `make_completion`.
    pub completion: Option<CompletionLayout>,
}

impl AiDescLayout {
    /// Render as JSON.
    pub fn to_json(&self) -> Json {
        Json::obj([
            ("desc_bytes", Json::Int(self.desc_bytes as i64)),
            (
                "version",
                self.version.map_or(Json::Null, |v| Json::Int(v as i64)),
            ),
            (
                "fields",
                Json::obj(self.fields.iter().map(|(k, v)| (k.as_str(), v.to_json()))),
            ),
            (
                "ops",
                Json::obj(
                    self.ops
                        .iter()
                        .map(|(k, v)| (k.as_str(), Json::Int(*v as i64))),
                ),
            ),
            (
                "statuses",
                Json::obj(
                    self.statuses
                        .iter()
                        .map(|(k, v)| (k.as_str(), Json::Int(*v as i64))),
                ),
            ),
            (
                "flags_layout",
                self.flags_layout.map_or(Json::Null, |f| f.to_json()),
            ),
            (
                "completion",
                self.completion.map_or(Json::Null, |c| {
                    Json::obj([
                        ("ticket_bit_low", Json::Int(c.ticket_bit_low as i64)),
                        ("ticket_bit_high", Json::Int(c.ticket_bit_high as i64)),
                        ("status_bit_low", Json::Int(c.status_bit_low as i64)),
                        ("status_bit_high", Json::Int(c.status_bit_high as i64)),
                    ])
                }),
            ),
        ])
    }

    /// Byte offset for a known descriptor field.
    pub fn offset(&self, name: &str) -> Option<u64> {
        self.fields.get(name).map(|f| f.offset)
    }

    /// Op code value.
    pub fn op(&self, name: &str) -> Option<u64> {
        self.ops.get(name).copied()
    }

    /// Status code value.
    pub fn status(&self, name: &str) -> Option<u64> {
        self.statuses.get(name).copied()
    }

    /// Pack the completion word the island writes to `ptr_done`.
    ///
    /// The bit layout comes from the ingested `make_completion` function. It lives here, in
    /// the IR, because the native VM, the TCG plugin's decoder and the generated in-target
    /// device must produce and consume *the same* word; three implementations of one bit
    /// layout is how a completion mismatch gets misattributed to the RTL.
    ///
    /// When the package does not publish `make_completion`, the fallback in
    /// [`FALLBACK_COMPLETION_STATUS_SHIFT`] is used. It is named rather than inlined so an
    /// unparsed design is visibly on a fallback instead of looking model-derived.
    pub fn pack_completion_word(&self, ticket: u64, status: u64) -> u64 {
        let Some(c) = self.completion else {
            return (status << FALLBACK_COMPLETION_STATUS_SHIFT) | ticket;
        };
        place_field(ticket, c.ticket_bit_low, c.ticket_bit_high)
            | place_field(status, c.status_bit_low, c.status_bit_high)
    }
}

/// Status shift used only when the descriptor package does not publish `make_completion`.
///
/// The reference package places status above the ticket in a 64-bit word. This is a
/// deliberate, named fallback: only a design-side constant can remove it.
pub const FALLBACK_COMPLETION_STATUS_SHIFT: u64 = 32;

/// Mask `value` to `[high:low]` and shift it into place inside a 64-bit word.
fn place_field(value: u64, low: u64, high: u64) -> u64 {
    if high < low || high > 63 {
        return 0;
    }
    let width = high - low + 1;
    let mask = if width >= 64 {
        !0u64
    } else {
        (1u64 << width) - 1
    };
    (value & mask) << low
}

/// AI instruction set and queue CSRs, derived from `g6lc_ai_instr_pkg.sv`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AiInstrSet {
    /// Custom-2 major opcode (`0x5B` on the reference design).
    pub opcode_custom2: u32,
    /// Mask that keeps funct7+funct3+opcode for custom instructions.
    pub mask_f7f3op: u32,
    /// `aiqbase` CSR number.
    pub csr_aiqbase: u16,
    /// `aiqctl` CSR number.
    pub csr_aiqctl: u16,
    /// `aiqhead` CSR number.
    pub csr_aiqhead: u16,
    /// Match value for `ai.enq`.
    pub match_enq: u32,
    /// Match value for `ai.poll`.
    pub match_poll: u32,
    /// Match value for `ai.qfence`.
    pub match_qfence: u32,
}

impl AiInstrSet {
    /// Render as JSON.
    pub fn to_json(&self) -> Json {
        Json::obj([
            ("opcode_custom2", Json::Int(self.opcode_custom2 as i64)),
            ("mask_f7f3op", Json::Int(self.mask_f7f3op as i64)),
            ("csr_aiqbase", Json::Int(self.csr_aiqbase as i64)),
            ("csr_aiqctl", Json::Int(self.csr_aiqctl as i64)),
            ("csr_aiqhead", Json::Int(self.csr_aiqhead as i64)),
            ("match_enq", Json::Int(self.match_enq as i64)),
            ("match_poll", Json::Int(self.match_poll as i64)),
            ("match_qfence", Json::Int(self.match_qfence as i64)),
        ])
    }
}

/// The complete AI-island model: configuration, descriptor layout and instruction set.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AiIslandModel {
    /// Cluster/queue capability configuration.
    pub config: AiIslandConfig,
    /// Descriptor field and constant layout.
    pub desc_layout: AiDescLayout,
    /// Queue CSRs and custom instruction encodings.
    pub instr_set: AiInstrSet,
}

impl AiIslandModel {
    /// Render as JSON.
    pub fn to_json(&self) -> Json {
        Json::obj([
            ("config", self.config.to_json()),
            ("desc_layout", self.desc_layout.to_json()),
            ("instr_set", self.instr_set.to_json()),
        ])
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
    /// Total logical harts the configuration describes: cores × threads per core.
    pub harts_total: u32,
    /// Harts the device tree declares to software, when a tree was read.
    ///
    /// Kept separate from [`Soc::harts_total`] because the two answer different
    /// questions — what the hardware has, and what the operating system will be told it
    /// has. A mismatch means the guest silently runs on fewer processors than the design
    /// provides, which is invisible in either input on its own.
    pub harts_declared: Option<u32>,
    /// Number of virtio-mmio transports the virt profile adds to the SoC memory map.
    ///
    /// Zero means no transports are added (the faithful SoC view). A non-zero value is
    /// a machine-profile choice, not an RTL constant, and is emitted only when present.
    pub virtio_mmio: u32,
    /// Memory-mapped boot ROM (MROM) used by the generated QEMU machine.
    ///
    /// `None` means the machine has no MROM and uses a direct kernel reset vector.
    /// A `Some((base, len))` value is emitted as the platform reset-vector region.
    pub bootrom: Option<(u64, u64)>,
    /// Kernel boot arguments advertised in the device tree `chosen` node.
    pub bootargs: Option<String>,
    /// Console path advertised in the device tree `chosen` node.
    pub stdout_path: Option<String>,
    /// Number of physical cores, when known from the design.
    pub cores: Option<u32>,
    /// Number of hardware threads per core, when known from the design.
    pub threads_per_core: Option<u32>,
    /// AI-island model, when the design has one.
    pub ai_island: Option<AiIslandModel>,
}

impl Soc {
    /// Maximum logical harts the interrupt controller can serve.
    ///
    /// This is the constraint that silently caps how many CPUs a guest can be given, so
    /// it is computed rather than assumed. `None` when the controller's context count is
    /// not known from the inputs — reporting `0` there would state a limit the inputs do
    /// not support, and would make every configuration look over budget.
    pub fn max_harts(&self) -> Option<u32> {
        if self.contexts_per_hart == 0 || self.intc_targets == 0 {
            return None;
        }
        Some(self.intc_targets / self.contexts_per_hart)
    }

    /// Whether the configured hart count fits the interrupt controller.
    ///
    /// True when the limit is unknown: an unknown budget is not a violated one.
    pub fn hart_count_fits(&self) -> bool {
        self.max_harts().is_none_or(|m| self.harts_total <= m)
    }

    /// Whether the device tree tells software about every hart the design has.
    ///
    /// `None` when no tree was read.
    pub fn hart_topology_agrees(&self) -> Option<bool> {
        self.harts_declared.map(|d| d == self.harts_total)
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
                    (
                        "max_harts",
                        self.max_harts().map_or(Json::Null, |m| Json::Int(m as i64)),
                    ),
                ]),
            ),
            ("harts_total", Json::Int(self.harts_total as i64)),
            (
                "harts_declared",
                self.harts_declared
                    .map_or(Json::Null, |h| Json::Int(h as i64)),
            ),
            (
                "hart_topology_agrees",
                self.hart_topology_agrees().map_or(Json::Null, Json::Bool),
            ),
            (
                "virtio_mmio",
                if self.virtio_mmio == 0 {
                    Json::Null
                } else {
                    Json::Int(self.virtio_mmio as i64)
                },
            ),
            (
                "bootrom",
                self.bootrom.map_or(Json::Null, |(b, l)| {
                    Json::obj([("base", Json::addr(b)), ("len", Json::addr(l))])
                }),
            ),
            (
                "bootargs",
                self.bootargs.as_deref().map_or(Json::Null, Json::str),
            ),
            (
                "stdout_path",
                self.stdout_path.as_deref().map_or(Json::Null, Json::str),
            ),
            (
                "cores",
                self.cores.map_or(Json::Null, |c| Json::Int(c as i64)),
            ),
            (
                "threads_per_core",
                self.threads_per_core
                    .map_or(Json::Null, |t| Json::Int(t as i64)),
            ),
            (
                "ai_island",
                self.ai_island
                    .as_ref()
                    .map_or(Json::Null, AiIslandModel::to_json),
            ),
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
    /// `timebase-frequency` advertised to software, in Hz.
    pub timebase_hz: u64,
    /// C10: physical address width, derived from the MMU geometry.
    pub paddr_bits: u8,
    /// C10: virtual address width for the selected MMU mode.
    pub vaddr_bits: u8,
    /// C10: page-table walk levels.
    pub page_table_levels: u8,
    /// C10: bits per VPN level.
    pub vpn_bits: u8,
    /// C10: SATP mode field value (0 = bare, 1 = sv32, 8 = sv39, 9 = sv48).
    pub satp_mode: u8,
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
            ("timebase_hz", Json::Int(self.timebase_hz as i64)),
            ("paddr_bits", Json::Int(self.paddr_bits as i64)),
            ("vaddr_bits", Json::Int(self.vaddr_bits as i64)),
            (
                "page_table_levels",
                Json::Int(self.page_table_levels as i64),
            ),
            ("vpn_bits", Json::Int(self.vpn_bits as i64)),
            ("satp_mode", Json::Int(self.satp_mode as i64)),
        ])
    }
}

/// Microarchitectural sizing values, carried as a raw map so a D2 model can
/// interpret them without forcing every field into a typed struct up front.
///
/// Values are intentionally design-native: what the package names is the key,
/// and what the package writes is the value. A later pass can add typed getters
/// for the structures that matter to diagnosis.
#[derive(Debug, Clone, Default)]
pub struct Uarch {
    /// `(field, value)` from the design's configuration, limited to scalars so the
    /// map does not accidentally carry large arrays.
    pub raw: std::collections::BTreeMap<String, Json>,
}

impl Uarch {
    /// Render as JSON.
    pub fn to_json(&self) -> Json {
        Json::obj(self.raw.iter().map(|(k, v)| (k.as_str(), v.clone())))
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
    /// Microarchitectural sizing (D2 structure models).
    pub uarch: Uarch,
    /// PMU event table (D2 counters and generated DTB PMU mapping).
    pub pmu: PmuTable,
    /// Conformance verdicts.
    pub conformance: Report,
}

impl TargetModel {
    /// A model with the given target id, faithful by default.
    pub fn new(target_id: impl Into<String>) -> Self {
        let mut m = Self {
            target_id: target_id.into(),
            plane: "soc".to_string(),
            profile: Profile::Soc,
            faithful: true,
            ..Default::default()
        };
        m.isa.timebase_hz = 1_000_000;
        m
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

    /// Conformance rows for topology the design's own arithmetic forbids.
    ///
    /// These are not capability rows — nothing here is about whether some RTL was
    /// compiled. They are cross-input findings about *how many harts* the machine claims,
    /// which is exactly the class of disagreement this package exists to report:
    ///
    /// * a configuration may describe more logical harts than the interrupt controller
    ///   has contexts to serve, which is illegal rather than slow;
    /// * a device tree may declare a different number of processors than the design has,
    ///   in which case the guest and the firmware disagree with the hardware.
    ///
    /// Both are `Overdeclared` when software is told the larger number, because that is a
    /// guest-visible claim the design cannot honour, and `--conform strict` refuses it.
    pub fn topology_rows(&self) -> Vec<crate::conform::Row> {
        use crate::conform::{Inputs, Row, Verdict};
        let mut rows = Vec::new();
        let total = self.soc.harts_total;

        // 1. Interrupt-controller context budget.
        match self.soc.max_harts() {
            None => rows.push(Row {
                capability: "interrupt-contexts".into(),
                inputs: Inputs::new(true, true, false),
                verdict: Verdict::Unresolved,
                also: Vec::new(),
                note: "the interrupt-controller context budget could not be determined, \
                       so the legal hart count is unknown; reporting it as zero would \
                       make every configuration look over budget"
                    .into(),
            }),
            Some(max) if total > max => rows.push(Row {
                capability: "interrupt-contexts".into(),
                inputs: Inputs::new(true, false, true),
                verdict: Verdict::Overdeclared,
                also: Vec::new(),
                note: format!(
                    "the configuration describes {total} logical harts but the interrupt \
                     controller can serve at most {max} ({} contexts each from {} \
                     targets); the surplus harts cannot receive interrupts",
                    self.soc.contexts_per_hart, self.soc.intc_targets
                ),
            }),
            Some(max) => rows.push(Row {
                capability: "interrupt-contexts".into(),
                inputs: Inputs::new(true, true, true),
                verdict: Verdict::Live,
                also: Vec::new(),
                note: format!("{total} logical harts within a budget of {max}"),
            }),
        }

        // 2. What the tree tells software, against what the design has.
        //
        // Only reported when a tree was actually read: no tree is not a finding.
        if let Some(declared) = self.soc.harts_declared {
            let row = match declared.cmp(&total) {
                std::cmp::Ordering::Equal => Row {
                    capability: "hart-topology".into(),
                    inputs: Inputs::new(true, true, true),
                    verdict: Verdict::Live,
                    also: Vec::new(),
                    note: format!("the tree declares {declared} processors, matching the design"),
                },
                std::cmp::Ordering::Greater => Row {
                    capability: "hart-topology".into(),
                    inputs: Inputs::new(true, false, true),
                    verdict: Verdict::Overdeclared,
                    also: Vec::new(),
                    note: format!(
                        "the tree declares {declared} processors but the design provides \
                         {total}; firmware that trusts the tree will start harts that do \
                         not exist"
                    ),
                },
                std::cmp::Ordering::Less => Row {
                    capability: "hart-topology".into(),
                    inputs: Inputs::new(true, true, false),
                    verdict: Verdict::Undeclared,
                    also: Vec::new(),
                    note: format!(
                        "the design provides {total} logical harts but the tree declares \
                         only {declared}; the guest will silently run on fewer processors"
                    ),
                },
            };
            rows.push(row);
        }

        rows
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
            ("uarch", self.uarch.to_json()),
            ("pmu", self.pmu.to_json()),
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
            ..Peripheral::default()
        }
    }

    #[test]
    fn profile_names_are_stable() {
        assert_eq!(Profile::Soc.as_str(), "g6lc-soc");
        assert_eq!(Profile::Virt.as_str(), "g6lc-virt");
    }

    #[test]
    fn the_completion_word_follows_the_ingested_layout() {
        // A layout deliberately unlike the fallback, so a passing assertion can only be
        // reading the model: ticket at 63:16, status at 15:0.
        let l = AiDescLayout {
            completion: Some(CompletionLayout {
                ticket_bit_low: 16,
                ticket_bit_high: 63,
                status_bit_low: 0,
                status_bit_high: 15,
            }),
            ..AiDescLayout::default()
        };
        assert_eq!(l.pack_completion_word(0x1234, 0x5), 0x1234_0005);
    }

    #[test]
    fn the_completion_word_falls_back_only_when_unpublished() {
        let l = AiDescLayout::default();
        assert_eq!(
            l.pack_completion_word(7, 2),
            (2u64 << FALLBACK_COMPLETION_STATUS_SHIFT) | 7
        );
    }

    #[test]
    fn an_out_of_range_completion_field_contributes_nothing() {
        let l = AiDescLayout {
            completion: Some(CompletionLayout {
                ticket_bit_low: 0,
                ticket_bit_high: 31,
                // A malformed range must not panic or wrap into the ticket bits.
                status_bit_low: 40,
                status_bit_high: 32,
            }),
            ..AiDescLayout::default()
        };
        assert_eq!(l.pack_completion_word(0xff, 0xff), 0xff);
    }

    #[test]
    fn capability_words_come_from_the_configuration() {
        let mut cfg = AiIslandConfig {
            cap_version: 3,
            clusters: 8,
            macs_per_cycle: 4096,
            acc_tile_m: 256,
            acc_tile_n: 256,
            acc_tile_k: 256,
            queues: 4,
            queue_depth: 64,
            block_mnk: Some(CapBlockMnk {
                m_low: 0,
                m_width: 4,
                n_low: 4,
                n_width: 4,
                k_low: 8,
                k_width: 4,
            }),
            ..AiIslandConfig::default()
        };
        cfg.cap_packed.words.insert(
            "queues".into(),
            vec![
                CapPackedField {
                    name: "queues".into(),
                    low: 0,
                    width: 16,
                },
                CapPackedField {
                    name: "queue_depth".into(),
                    low: 16,
                    width: 16,
                },
            ],
        );
        cfg.cap_offsets.insert("version".into(), 0x00);
        cfg.cap_offsets.insert("clusters".into(), 0x04);
        cfg.cap_offsets.insert("block_mnk".into(), 0x14);
        cfg.cap_offsets.insert("queues".into(), 0x18);

        assert_eq!(cfg.cap_value("version"), Some(3));
        // log2(256) = 8 in each of the three nibbles.
        assert_eq!(cfg.cap_value("block_mnk"), Some(0x888));
        assert_eq!(cfg.cap_value("queues"), Some((64 << 16) | 4));
        assert_eq!(
            cfg.cap_words(),
            vec![(0x00, 3), (0x04, 8), (0x14, 0x888), (0x18, (64 << 16) | 4)]
        );
        assert!(cfg.cap_unsourced().is_empty());
    }

    #[test]
    fn an_unsourceable_capability_is_reported_not_zeroed() {
        let mut cfg = AiIslandConfig::default();
        cfg.cap_offsets
            .insert("a_word_no_reader_knows".into(), 0x20);
        assert_eq!(cfg.cap_value("a_word_no_reader_knows"), None);
        assert!(cfg.cap_words().is_empty(), "must omit, not answer zero");
        assert_eq!(
            cfg.cap_unsourced(),
            vec![("a_word_no_reader_knows".to_string(), 0x20)]
        );
    }

    #[test]
    fn clog2_matches_systemverilog() {
        assert_eq!(clog2_u32(0), 0);
        assert_eq!(clog2_u32(1), 0);
        assert_eq!(clog2_u32(256), 8);
        assert_eq!(clog2_u32(257), 9);
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
        assert_eq!(soc.max_harts(), Some(8));
        assert!(soc.hart_count_fits());
        soc.harts_total = 9;
        assert!(!soc.hart_count_fits());
    }

    #[test]
    fn a_hart_count_over_the_interrupt_budget_is_a_blocking_finding() {
        use crate::conform::Verdict;
        let mut m = TargetModel::new("t");
        m.soc.intc_targets = 16;
        m.soc.contexts_per_hart = 2;
        m.soc.harts_total = 8;
        let rows = m.topology_rows();
        let irq = rows
            .iter()
            .find(|r| r.capability == "interrupt-contexts")
            .expect("row present");
        assert_eq!(irq.verdict, Verdict::Live, "eight fits a budget of eight");

        // Nine harts against the same controller is illegal, not merely tight.
        m.soc.harts_total = 9;
        let rows = m.topology_rows();
        let irq = rows
            .iter()
            .find(|r| r.capability == "interrupt-contexts")
            .unwrap();
        assert_eq!(irq.verdict, Verdict::Overdeclared);
        assert!(irq.verdict.refused_under_strict());
        assert!(
            irq.note.contains('9') && irq.note.contains('8'),
            "{}",
            irq.note
        );
    }

    #[test]
    fn an_unknown_interrupt_budget_is_unresolved_not_a_pass() {
        use crate::conform::Verdict;
        let mut m = TargetModel::new("t");
        m.soc.harts_total = 4;
        // No targets/contexts read: the budget is unknown.
        let rows = m.topology_rows();
        let irq = rows
            .iter()
            .find(|r| r.capability == "interrupt-contexts")
            .unwrap();
        assert_eq!(irq.verdict, Verdict::Unresolved);
        assert!(irq.verdict.refused_under_strict());
    }

    #[test]
    fn a_tree_that_disagrees_with_the_design_about_processors_is_reported() {
        use crate::conform::Verdict;
        let mut m = TargetModel::new("t");
        m.soc.intc_targets = 16;
        m.soc.contexts_per_hart = 2;
        m.soc.harts_total = 2;

        // No tree read: silence, not a finding.
        assert!(!m
            .topology_rows()
            .iter()
            .any(|r| r.capability == "hart-topology"));

        // Tree agrees.
        m.soc.harts_declared = Some(2);
        let row = |m: &TargetModel| {
            m.topology_rows()
                .into_iter()
                .find(|r| r.capability == "hart-topology")
                .unwrap()
        };
        assert_eq!(row(&m).verdict, Verdict::Live);

        // Tree claims a processor the design does not have: firmware would start it.
        m.soc.harts_declared = Some(3);
        let r = row(&m);
        assert_eq!(r.verdict, Verdict::Overdeclared);
        assert!(r.verdict.refused_under_strict());

        // Tree hides a processor: legal, but the guest runs on fewer.
        m.soc.harts_declared = Some(1);
        let r = row(&m);
        assert_eq!(r.verdict, Verdict::Undeclared);
        assert!(
            !r.verdict.refused_under_strict(),
            "under-declaring is permitted with a warning"
        );
    }

    #[test]
    fn an_unknown_budget_is_reported_as_unknown_not_as_zero() {
        // Reporting 0 would state a limit the inputs do not support and would make every
        // configuration look over budget.
        let soc = Soc {
            intc_targets: 0,
            contexts_per_hart: 2,
            harts_total: 4,
            ..Soc::default()
        };
        assert_eq!(soc.max_harts(), None);
        assert!(
            soc.hart_count_fits(),
            "an unknown budget is not a violated one"
        );
        assert!(soc.to_json().to_pretty().contains("\"max_harts\": null"));
    }

    #[test]
    fn zero_contexts_per_hart_does_not_divide_by_zero() {
        let soc = Soc {
            intc_targets: 16,
            contexts_per_hart: 0,
            ..Soc::default()
        };
        assert_eq!(soc.max_harts(), None);
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
        assert!(text.contains("\"schema_version\": \"2\""), "{text}");
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
