// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! AI-island tensor events.
//!
//! A tensor event captures one descriptor submission or completion as seen by the accelerator.
//! It is separate from the architectural `CommitRecord` stream: it carries the descriptor
//! address, input/output buffers, dimensions, data type and completion state, so D2 analysis
//! can correlate MMIO traffic with actual work rather than just counting window accesses.

use g6q_core::model::DescFlagsLayout;
use g6q_core::Json;

/// Fallback `flags` word layout for traces that do not carry their own layout.
///
/// This matches the reference package (`flags[13:8]` combined type fields, `flags[19:16]`
/// priority, `flags[2]` interrupt) and is used only when an older or bare event array is read.
/// `dtype_combined` is `true` because that span holds several ABI subfields, so a consumer
/// must not report the extracted value as a data type.
const DEFAULT_FLAGS_LAYOUT: DescFlagsLayout = DescFlagsLayout {
    dtype_shift: 8,
    dtype_mask: 0x3f,
    priority_shift: 16,
    priority_mask: 0x0f,
    irq_bit: 2,
    dtype_combined: true,
    accmode: None,
    ew: None,
    sp24_bit: None,
};

/// One AI-island descriptor event.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct AiTensorEvent {
    /// Monotonic event order inside the AI-island stream.
    pub order: u64,
    /// Hart that submitted the descriptor.
    pub hart: u32,
    /// Descriptor address (queue entry or MMIO base for register submissions).
    pub descriptor_addr: u64,
    /// Operation code (GEMM, CONV2D, ...).
    pub op: u16,
    /// Descriptor version.
    pub version: u16,
    /// Flag word.
    pub flags: u32,
    /// M dimension.
    pub m: u32,
    /// N dimension.
    pub n: u32,
    /// K dimension.
    pub k: u32,
    /// Leading-dimension packing for A/B.
    pub ld_ab: u32,
    /// Input/weight A buffer address.
    pub ptr_a: u64,
    /// Input/weight B buffer address.
    pub ptr_b: u64,
    /// Output C buffer address.
    pub ptr_c: u64,
    /// Scale pointer (optional).
    pub ptr_scale: u64,
    /// Completion pointer (where the done word is written).
    pub ptr_done: u64,
    /// Data type, derived from the packed `flags` layout.
    pub dtype: u8,
    /// Cluster that executed or will execute the operation.
    ///
    /// The RTL does not currently expose per-cluster dispatch in the descriptor, so this
    /// defaults to 0 and is recorded as an unresolved ask in `architecture/RTL_FEEDBACK.md`.
    pub cluster: u32,
    /// Completion ticket, if already known.
    pub ticket: u32,
    /// Completion status, if already known (0 = ST_OK).
    pub status: u16,
    /// True when the done word has been written back.
    pub done: bool,
    /// Modelled AXI read beats for this completion; sticky PMU value from the B3 device.
    pub pmu_r_beats: u32,
    /// Modelled AXI write beats for this completion; sticky PMU value from the B3 device.
    pub pmu_w_beats: u32,
    /// Modelled active cycles for this completion; sticky PMU value from the B3 device.
    pub pmu_cycles: u32,
    /// Modelled sustained bandwidth in 1/1000 GB/s for this completion; sticky PMU value from the B3 device.
    pub pmu_gbps_x1000: u32,
}

fn dtype_bytes(dtype: u8) -> u64 {
    match dtype {
        0..=3 => 1,
        4..=7 => 2,
        8..=11 => 4,
        _ => 8,
    }
}

/// D2 microarchitectural counters derived from a stream of `AiTensorEvent`s.
///
/// All returned counters are `Fidelity::Synthetic` because the tensor event stream is
/// an instrumented model of accelerator activity, not architectural evidence from the RTL.
pub fn tensor_counters(events: &[AiTensorEvent]) -> Vec<crate::Counter> {
    let mut ops = 0u64;
    let mut bytes = 0u64;
    let mut macs = 0u64;
    let mut completes = 0u64;
    let mut last_pmu: Option<&AiTensorEvent> = None;
    for ev in events {
        ops += 1;
        if ev.done {
            completes += 1;
            last_pmu = Some(ev);
        }
        let esize = dtype_bytes(ev.dtype);
        let a = ev.m as u64 * ev.k as u64;
        let b = ev.k as u64 * ev.n as u64;
        let c = ev.m as u64 * ev.n as u64;
        bytes += (a + b + c) * esize;
        macs += ev.m as u64 * ev.n as u64 * ev.k as u64;
    }
    let pmu = last_pmu.copied().unwrap_or_default();
    vec![
        crate::Counter {
            name: "ai.tensor.ops".into(),
            value: ops,
            fidelity: crate::Fidelity::Synthetic,
        },
        crate::Counter {
            name: "ai.tensor.completes".into(),
            value: completes,
            fidelity: crate::Fidelity::Synthetic,
        },
        crate::Counter {
            name: "ai.tensor.bytes".into(),
            value: bytes,
            fidelity: crate::Fidelity::Synthetic,
        },
        crate::Counter {
            name: "ai.tensor.macs".into(),
            value: macs,
            fidelity: crate::Fidelity::Synthetic,
        },
        crate::Counter {
            name: "ai.tensor.queue_entries".into(),
            value: events.len() as u64,
            fidelity: crate::Fidelity::Synthetic,
        },
        crate::Counter {
            name: "ai.pmu.r_beats".into(),
            value: pmu.pmu_r_beats as u64,
            fidelity: crate::Fidelity::Modelled,
        },
        crate::Counter {
            name: "ai.pmu.w_beats".into(),
            value: pmu.pmu_w_beats as u64,
            fidelity: crate::Fidelity::Modelled,
        },
        crate::Counter {
            name: "ai.pmu.cycles".into(),
            value: pmu.pmu_cycles as u64,
            fidelity: crate::Fidelity::Modelled,
        },
        crate::Counter {
            name: "ai.pmu.gbps_x1000".into(),
            value: pmu.pmu_gbps_x1000 as u64,
            fidelity: crate::Fidelity::Modelled,
        },
    ]
}

impl AiTensorEvent {
    /// Render as a JSON object.
    pub fn to_json(&self) -> Json {
        Json::obj([
            ("order", Json::Int(self.order as i64)),
            ("hart", Json::Int(self.hart as i64)),
            ("descriptor_addr", Json::Int(self.descriptor_addr as i64)),
            ("op", Json::Int(self.op as i64)),
            ("version", Json::Int(self.version as i64)),
            ("flags", Json::Int(self.flags as i64)),
            ("m", Json::Int(self.m as i64)),
            ("n", Json::Int(self.n as i64)),
            ("k", Json::Int(self.k as i64)),
            ("ld_ab", Json::Int(self.ld_ab as i64)),
            ("ptr_a", Json::Int(self.ptr_a as i64)),
            ("ptr_b", Json::Int(self.ptr_b as i64)),
            ("ptr_c", Json::Int(self.ptr_c as i64)),
            ("ptr_scale", Json::Int(self.ptr_scale as i64)),
            ("ptr_done", Json::Int(self.ptr_done as i64)),
            ("dtype", Json::Int(self.dtype as i64)),
            ("cluster", Json::Int(self.cluster as i64)),
            ("ticket", Json::Int(self.ticket as i64)),
            ("status", Json::Int(self.status as i64)),
            ("done", Json::Bool(self.done)),
            ("pmu_r_beats", Json::Int(self.pmu_r_beats as i64)),
            ("pmu_w_beats", Json::Int(self.pmu_w_beats as i64)),
            ("pmu_cycles", Json::Int(self.pmu_cycles as i64)),
            ("pmu_gbps_x1000", Json::Int(self.pmu_gbps_x1000 as i64)),
        ])
    }

    /// Parse a JSON object back into an event.
    ///
    /// Missing numeric fields default to zero; missing `dtype` is recovered from `flags` when
    /// a layout is present, so a trace written by an older emitter still yields the right
    /// element size using `DEFAULT_FLAGS_LAYOUT`.
    pub fn from_json(json: &Json) -> Option<Self> {
        Self::from_json_with_layout(json, None)
    }

    /// Parse a JSON object back into an event, using the trace's `flags_layout` to recover
    /// `dtype` when the field is missing.
    pub fn from_json_with_layout(json: &Json, layout: Option<&DescFlagsLayout>) -> Option<Self> {
        fn u64_from(j: &Json) -> u64 {
            match j {
                Json::Int(i) if *i >= 0 => *i as u64,
                _ => 0,
            }
        }
        fn u32_from(j: &Json) -> u32 {
            u64_from(j) as u32
        }
        fn u16_from(j: &Json) -> u16 {
            u64_from(j) as u16
        }
        fn u8_from(j: &Json) -> u8 {
            u64_from(j) as u8
        }
        fn bool_from(j: &Json) -> bool {
            matches!(j, Json::Bool(true))
        }

        let flags = u32_from(json.get("flags"));
        let mut dtype = u8_from(json.get("dtype"));
        if dtype == 0 && flags != 0 {
            let layout = layout.unwrap_or(&DEFAULT_FLAGS_LAYOUT);
            dtype = Self::dtype_from_flags(flags, layout);
        }

        Some(Self {
            order: u64_from(json.get("order")),
            hart: u32_from(json.get("hart")),
            descriptor_addr: u64_from(json.get("descriptor_addr")),
            op: u16_from(json.get("op")),
            version: u16_from(json.get("version")),
            flags,
            m: u32_from(json.get("m")),
            n: u32_from(json.get("n")),
            k: u32_from(json.get("k")),
            ld_ab: u32_from(json.get("ld_ab")),
            ptr_a: u64_from(json.get("ptr_a")),
            ptr_b: u64_from(json.get("ptr_b")),
            ptr_c: u64_from(json.get("ptr_c")),
            ptr_scale: u64_from(json.get("ptr_scale")),
            ptr_done: u64_from(json.get("ptr_done")),
            dtype,
            cluster: u32_from(json.get("cluster")),
            ticket: u32_from(json.get("ticket")),
            status: u16_from(json.get("status")),
            done: bool_from(json.get("done")),
            pmu_r_beats: u32_from(json.get("pmu_r_beats")),
            pmu_w_beats: u32_from(json.get("pmu_w_beats")),
            pmu_cycles: u32_from(json.get("pmu_cycles")),
            pmu_gbps_x1000: u32_from(json.get("pmu_gbps_x1000")),
        })
    }

    /// Compute `dtype` from the descriptor flag word using an ingested `flags_layout`.
    pub const fn dtype_from_flags(flags: u32, layout: &DescFlagsLayout) -> u8 {
        ((flags >> layout.dtype_shift) & layout.dtype_mask) as u8
    }
}

/// A stream of tensor events, stamped like a `RecordFile` but separate from the architectural
/// commit stream.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TensorTrace {
    /// Events in emission order.
    pub events: Vec<AiTensorEvent>,
    /// Packed `flags` word layout that was used to produce this trace, when known.
    pub flags_layout: Option<DescFlagsLayout>,
}

impl TensorTrace {
    /// Append one event.
    pub fn push(&mut self, ev: AiTensorEvent) {
        self.events.push(ev);
    }

    /// Render as a JSON array.
    pub fn to_json(&self) -> Json {
        Json::Arr(self.events.iter().map(|e| e.to_json()).collect())
    }

    /// Parse a JSON array back into a trace.
    pub fn from_json(json: &Json) -> Option<Self> {
        Self::from_json_with_layout(json, None)
    }

    /// Parse a JSON array back into a trace, using a known `flags_layout`.
    pub fn from_json_with_layout(
        json: &Json,
        flags_layout: Option<DescFlagsLayout>,
    ) -> Option<Self> {
        match json {
            Json::Arr(items) => {
                let layout_ref = flags_layout.as_ref();
                let events: Option<Vec<_>> = items
                    .iter()
                    .map(|j| AiTensorEvent::from_json_with_layout(j, layout_ref))
                    .collect();
                events.map(|events| Self {
                    events,
                    flags_layout,
                })
            }
            _ => None,
        }
    }

    /// Read a trace from a file path.
    pub fn from_file(path: &str) -> Result<Self, String> {
        let text = std::fs::read_to_string(path)
            .map_err(|e| format!("cannot read tensor trace {path}: {e}"))?;
        let json = Json::parse(&text).map_err(|e| format!("invalid JSON in {path}: {e}"))?;
        Self::from_json(&json).ok_or_else(|| format!("{path} is not a tensor event array"))
    }
}

/// A tensor artifact: a stamped header plus an event stream.
///
/// This is the file unit emitted by both the native VM and the B2 QEMU plugin. The
/// wrapper form is `{"header": {...}, "events": [...]}`; a bare event array is also
/// accepted for backwards compatibility and ad-hoc traces.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TensorArtifact {
    /// Artifact header describing the profile that produced the events.
    pub header: crate::ArtifactHeader,
    /// Tensor events in emission order.
    pub trace: TensorTrace,
}

impl TensorArtifact {
    /// Wrap a header and a trace.
    pub fn new(header: crate::ArtifactHeader, trace: TensorTrace) -> Self {
        Self { header, trace }
    }

    /// Render as a JSON object with `header`, optional `flags_layout`, and `events`.
    pub fn to_json(&self) -> Json {
        let mut pairs: Vec<(&str, Json)> = Vec::new();
        pairs.push(("header", self.header.to_json()));
        if let Some(f) = self.trace.flags_layout {
            pairs.push(("flags_layout", f.to_json()));
        }
        pairs.push(("events", self.trace.to_json()));
        Json::obj(pairs)
    }

    /// Parse from JSON. Accepts a wrapped object or a bare event array.
    pub fn from_json(json: &Json) -> Option<Self> {
        match json {
            Json::Obj(_) => {
                let header = crate::ArtifactHeader::from_json(json.get("header"))?;
                let flags_layout = DescFlagsLayout::from_json(json.get("flags_layout"));
                let trace = TensorTrace::from_json_with_layout(json.get("events"), flags_layout)?;
                Some(Self { header, trace })
            }
            Json::Arr(_) => {
                let trace = TensorTrace::from_json(json)?;
                Some(Self {
                    header: crate::ArtifactHeader {
                        profile: "unknown".into(),
                        tainted: true,
                    },
                    trace,
                })
            }
            _ => None,
        }
    }

    /// Read a tensor artifact from a file path.
    pub fn from_file(path: &str) -> Result<Self, String> {
        let text = std::fs::read_to_string(path)
            .map_err(|e| format!("cannot read tensor artifact {path}: {e}"))?;
        let json = Json::parse(&text).map_err(|e| format!("invalid JSON in {path}: {e}"))?;
        Self::from_json(&json).ok_or_else(|| format!("{path} is not a tensor artifact"))
    }

    /// Compare two tensor artifacts and return the first difference, if any.
    pub fn compare(&self, other: &Self) -> Option<String> {
        if self.header.profile != other.header.profile {
            return Some(format!(
                "profile mismatch: {} vs {}",
                self.header.profile, other.header.profile
            ));
        }
        if self.header.tainted != other.header.tainted {
            return Some(format!(
                "profile_tainted mismatch: {} vs {}",
                self.header.tainted, other.header.tainted
            ));
        }
        if self.trace.events.len() != other.trace.events.len() {
            return Some(format!(
                "event count mismatch: {} vs {}",
                self.trace.events.len(),
                other.trace.events.len()
            ));
        }
        for (i, (a, b)) in self
            .trace
            .events
            .iter()
            .zip(other.trace.events.iter())
            .enumerate()
        {
            if a != b {
                return Some(format!(
                    "event {i} differs:\n  left: {}\n right: {}",
                    a.to_json().to_pretty(),
                    b.to_json().to_pretty()
                ));
            }
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn event_round_trips_to_json() {
        let ev = AiTensorEvent {
            order: 0,
            hart: 0,
            descriptor_addr: 0x8000_0000,
            op: 1,
            version: 1,
            flags: 0x0000_0100,
            m: 4,
            n: 4,
            k: 4,
            ld_ab: 4,
            ptr_a: 0x9000_0000,
            ptr_b: 0x9000_1000,
            ptr_c: 0x9000_2000,
            ptr_scale: 0,
            ptr_done: 0xa000_0000,
            dtype: AiTensorEvent::dtype_from_flags(0x0000_0100, &DEFAULT_FLAGS_LAYOUT),
            ticket: 1,
            cluster: 0,
            status: 0,
            done: true,
            ..Default::default()
        };
        let j = ev.to_json().to_pretty();
        assert!(j.contains("\"op\": 1"));
        assert!(j.contains("\"dtype\": 1"));
        assert!(j.contains("\"done\": true"));
    }

    #[test]
    fn dtype_lives_in_flags_bits_13_8() {
        assert_eq!(
            AiTensorEvent::dtype_from_flags(0x0000_0100, &DEFAULT_FLAGS_LAYOUT),
            1
        );
        assert_eq!(
            AiTensorEvent::dtype_from_flags(0x0000_3f00, &DEFAULT_FLAGS_LAYOUT),
            0x3f
        );
        assert_eq!(AiTensorEvent::dtype_from_flags(0, &DEFAULT_FLAGS_LAYOUT), 0);
    }

    #[test]
    fn tensor_counters_are_synthetic_and_sum_event_stream() {
        let ev = AiTensorEvent {
            order: 0,
            hart: 0,
            descriptor_addr: 0x8000_0000,
            op: 1,
            version: 1,
            flags: 0,
            m: 4,
            n: 4,
            k: 4,
            ld_ab: 4,
            ptr_a: 0x9000_0000,
            ptr_b: 0x9000_1000,
            ptr_c: 0x9000_2000,
            ptr_scale: 0,
            ptr_done: 0xa000_0000,
            dtype: 0,
            ticket: 1,
            cluster: 0,
            status: 0,
            done: true,
            ..Default::default()
        };
        let counters = tensor_counters(&[ev]);
        let by_name: std::collections::BTreeMap<_, _> =
            counters.iter().map(|c| (c.name.as_str(), c)).collect();
        assert_eq!(by_name["ai.tensor.ops"].value, 1);
        assert!(by_name["ai.tensor.ops"].fidelity == crate::Fidelity::Synthetic);
        assert_eq!(by_name["ai.tensor.completes"].value, 1);
        assert_eq!(by_name["ai.tensor.queue_entries"].value, 1);
        // dtype 0 -> 1 byte; matrices: 4*4 + 4*4 + 4*4 = 48 bytes.
        assert_eq!(by_name["ai.tensor.bytes"].value, 48);
        assert_eq!(by_name["ai.tensor.macs"].value, 64);
        // With dtype 0 the event's PMU fields are all zero in this test.
        assert_eq!(by_name["ai.pmu.r_beats"].value, 0);
        assert_eq!(by_name["ai.pmu.w_beats"].value, 0);
        assert_eq!(by_name["ai.pmu.cycles"].value, 0);
        assert_eq!(by_name["ai.pmu.gbps_x1000"].value, 0);
        assert!(by_name["ai.pmu.r_beats"].fidelity == crate::Fidelity::Modelled);
    }

    #[test]
    fn tensor_counters_report_last_done_pmu() {
        let mut ev = AiTensorEvent {
            m: 4,
            n: 4,
            k: 4,
            done: true,
            pmu_r_beats: 7,
            pmu_w_beats: 8,
            pmu_cycles: 9,
            pmu_gbps_x1000: 10,
            ..Default::default()
        };
        let counters = tensor_counters(&[ev]);
        let by_name: std::collections::BTreeMap<_, _> =
            counters.iter().map(|c| (c.name.as_str(), c)).collect();
        assert_eq!(by_name["ai.pmu.r_beats"].value, 7);
        assert_eq!(by_name["ai.pmu.w_beats"].value, 8);
        assert_eq!(by_name["ai.pmu.cycles"].value, 9);
        assert_eq!(by_name["ai.pmu.gbps_x1000"].value, 10);

        // An in-flight event is not the "last done" PMU source.
        ev.done = false;
        let counters = tensor_counters(&[
            ev,
            AiTensorEvent {
                done: true,
                ..Default::default()
            },
        ]);
        let by_name: std::collections::BTreeMap<_, _> =
            counters.iter().map(|c| (c.name.as_str(), c)).collect();
        assert_eq!(by_name["ai.pmu.r_beats"].value, 0);
        assert_eq!(by_name["ai.pmu.gbps_x1000"].value, 0);
    }

    #[test]
    fn tensor_event_round_trips_through_json() {
        let ev = AiTensorEvent {
            order: 1,
            hart: 0,
            descriptor_addr: 0x8000_0000,
            op: 2,
            version: 1,
            flags: 0x0000_0800,
            m: 8,
            n: 8,
            k: 8,
            ld_ab: 8,
            ptr_a: 0x9000_0000,
            ptr_b: 0x9000_1000,
            ptr_c: 0x9000_2000,
            ptr_scale: 0,
            ptr_done: 0xa000_0000,
            dtype: 0,
            ticket: 3,
            cluster: 0,
            status: 0,
            done: false,
            ..Default::default()
        };
        let trace = TensorTrace {
            events: vec![ev],
            flags_layout: None,
        };
        let parsed = TensorTrace::from_json(&trace.to_json()).unwrap();
        assert_eq!(parsed.events.len(), 1);
        let back = &parsed.events[0];
        assert_eq!(back.order, 1);
        assert_eq!(back.op, 2);
        assert_eq!(back.dtype, 8, "dtype should be recovered from flags");
        assert_eq!(back.m, 8);
        assert_eq!(back.ptr_c, 0x9000_2000);
    }

    #[test]
    fn tensor_artifact_round_trips_with_header() {
        let ev = AiTensorEvent {
            order: 1,
            hart: 0,
            descriptor_addr: 0x8000_0000,
            op: 2,
            version: 1,
            flags: 0x0000_0800,
            m: 8,
            n: 8,
            k: 8,
            ld_ab: 8,
            ptr_a: 0x9000_0000,
            ptr_b: 0x9000_1000,
            ptr_c: 0x9000_2000,
            ptr_scale: 0,
            ptr_done: 0xa000_0000,
            dtype: AiTensorEvent::dtype_from_flags(0x0000_0800, &DEFAULT_FLAGS_LAYOUT),
            ticket: 3,
            cluster: 0,
            status: 0,
            done: false,
            ..Default::default()
        };
        let trace = TensorTrace {
            events: vec![ev],
            flags_layout: None,
        };
        let header = crate::ArtifactHeader {
            profile: "g6lc-soc".into(),
            tainted: false,
        };
        let artifact = TensorArtifact::new(header, trace);
        let parsed = TensorArtifact::from_json(&artifact.to_json()).unwrap();
        assert_eq!(parsed.header.profile, "g6lc-soc");
        assert!(!parsed.header.tainted);
        assert_eq!(parsed.trace.events.len(), 1);
        assert_eq!(parsed, artifact);
    }

    #[test]
    fn tensor_artifact_accepts_bare_event_array() {
        let ev = AiTensorEvent {
            order: 0,
            hart: 1,
            descriptor_addr: 0x8000_0000,
            op: 1,
            version: 1,
            flags: 0,
            m: 4,
            n: 4,
            k: 4,
            ld_ab: 4,
            ptr_a: 0x9000_0000,
            ptr_b: 0x9000_1000,
            ptr_c: 0x9000_2000,
            ptr_scale: 0,
            ptr_done: 0xa000_0000,
            dtype: 0,
            ticket: 1,
            cluster: 0,
            status: 0,
            done: true,
            ..Default::default()
        };
        let trace = TensorTrace {
            events: vec![ev],
            flags_layout: None,
        };
        let parsed = TensorArtifact::from_json(&trace.to_json()).unwrap();
        assert_eq!(parsed.header.profile, "unknown");
        assert!(parsed.header.tainted);
        assert_eq!(parsed.trace.events.len(), 1);
    }

    #[test]
    fn b2_tensor_event_parses_pmu_fields_as_zero() {
        // A JSON object in the exact shape the B2 plugin emits via fprintf.
        let raw = r#"{
            "order": 0,
            "hart": 1,
            "descriptor_addr": 1073741824,
            "op": 1,
            "version": 1,
            "flags": 0,
            "m": 4,
            "n": 4,
            "k": 4,
            "ld_ab": 4,
            "ptr_a": 2415919104,
            "ptr_b": 2415984640,
            "ptr_c": 2416050176,
            "ptr_scale": 0,
            "ptr_done": 2684354560,
            "dtype": 0,
            "ticket": 7,
            "cluster": 0,
            "status": 0,
            "done": true,
            "pmu_r_beats": 0,
            "pmu_w_beats": 0,
            "pmu_cycles": 0,
            "pmu_gbps_x1000": 0
        }"#;
        let json = g6q_core::Json::parse(raw).unwrap();
        let ev = AiTensorEvent::from_json(&json).unwrap();
        assert!(ev.done);
        assert_eq!(ev.ticket, 7);
        assert_eq!(ev.pmu_r_beats, 0);
        assert_eq!(ev.pmu_w_beats, 0);
        assert_eq!(ev.pmu_cycles, 0);
        assert_eq!(ev.pmu_gbps_x1000, 0);
    }

    #[test]
    fn tensor_event_round_trips_pmu_values() {
        let ev = AiTensorEvent {
            order: 1,
            hart: 0,
            descriptor_addr: 0x8000_0000,
            op: 2,
            version: 1,
            flags: 0x0000_0800,
            m: 8,
            n: 8,
            k: 8,
            ld_ab: 8,
            ptr_a: 0x9000_0000,
            ptr_b: 0x9000_1000,
            ptr_c: 0x9000_2000,
            ptr_scale: 0,
            ptr_done: 0xa000_0000,
            dtype: 0,
            ticket: 3,
            cluster: 0,
            status: 0,
            done: true,
            pmu_r_beats: 100,
            pmu_w_beats: 50,
            pmu_cycles: 200,
            pmu_gbps_x1000: 3000,
        };
        let trace = TensorTrace {
            events: vec![ev],
            flags_layout: None,
        };
        let parsed = TensorTrace::from_json(&trace.to_json()).unwrap();
        assert_eq!(parsed.events.len(), 1);
        let back = &parsed.events[0];
        assert_eq!(back.pmu_r_beats, 100);
        assert_eq!(back.pmu_w_beats, 50);
        assert_eq!(back.pmu_cycles, 200);
        assert_eq!(back.pmu_gbps_x1000, 3000);
    }

    #[test]
    fn tensor_artifact_compare_reports_pmu_modelled_vs_zero() {
        // A B2 artifact and a B3 artifact that are identical except for the modelled
        // PMU values. `compare` must surface the first PMU field, not silently treat
        // modelled and zero as equivalent.
        let b2 = AiTensorEvent {
            order: 1,
            hart: 0,
            descriptor_addr: 0x8000_0000,
            op: 2,
            version: 1,
            flags: 0,
            m: 4,
            n: 4,
            k: 4,
            ld_ab: 4,
            ptr_a: 0x9000_0000,
            ptr_b: 0x9000_1000,
            ptr_c: 0x9000_2000,
            ptr_scale: 0,
            ptr_done: 0xa000_0000,
            dtype: 0,
            ticket: 1,
            cluster: 0,
            status: 0,
            done: true,
            ..Default::default()
        };
        let mut b3 = b2;
        b3.pmu_r_beats = 100;
        b3.pmu_w_beats = 50;
        b3.pmu_cycles = 200;
        b3.pmu_gbps_x1000 = 3000;

        let h = crate::ArtifactHeader {
            profile: "g6lc-soc".into(),
            tainted: false,
        };
        let a = TensorArtifact::new(
            h.clone(),
            TensorTrace {
                events: vec![b2],
                flags_layout: None,
            },
        );
        let b = TensorArtifact::new(
            h,
            TensorTrace {
                events: vec![b3],
                flags_layout: None,
            },
        );
        let diff = a.compare(&b);
        assert!(diff.is_some(), "B2 vs B3 PMU difference must be reported");
        assert!(
            diff.unwrap().contains("pmu_r_beats"),
            "difference report must name the PMU field"
        );
    }

    #[test]
    fn tensor_artifact_compare_reports_first_difference() {
        let ev = AiTensorEvent {
            order: 0,
            hart: 0,
            descriptor_addr: 0x8000_0000,
            op: 1,
            version: 1,
            flags: 0,
            m: 4,
            n: 4,
            k: 4,
            ld_ab: 4,
            ptr_a: 0x9000_0000,
            ptr_b: 0x9000_1000,
            ptr_c: 0x9000_2000,
            ptr_scale: 0,
            ptr_done: 0xa000_0000,
            dtype: 0,
            ticket: 1,
            cluster: 0,
            status: 0,
            done: true,
            ..Default::default()
        };
        let h = crate::ArtifactHeader {
            profile: "g6lc-soc".into(),
            tainted: false,
        };
        let a = TensorArtifact::new(
            h.clone(),
            TensorTrace {
                events: vec![ev],
                flags_layout: None,
            },
        );
        let mut ev2 = ev;
        ev2.done = false;
        let b = TensorArtifact::new(
            h,
            TensorTrace {
                events: vec![ev2],
                flags_layout: None,
            },
        );
        assert!(a.compare(&a).is_none());
        assert!(a.compare(&b).is_some());
        let p = crate::ArtifactHeader {
            profile: "g6lc-virt".into(),
            tainted: true,
        };
        let c = TensorArtifact::new(
            p,
            TensorTrace {
                events: vec![ev],
                flags_layout: None,
            },
        );
        assert!(a.compare(&c).is_some());
    }
}
