// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! AI-island tensor events.
//!
//! A tensor event captures one descriptor submission or completion as seen by the accelerator.
//! It is separate from the architectural `CommitRecord` stream: it carries the descriptor
//! address, input/output buffers, dimensions, data type and completion state, so D2 analysis
//! can correlate MMIO traffic with actual work rather than just counting window accesses.

use g6q_core::Json;

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
    /// Data type, derived from `flags[13:8]`.
    pub dtype: u8,
    /// Completion ticket, if already known.
    pub ticket: u32,
    /// Completion status, if already known (0 = ST_OK).
    pub status: u16,
    /// True when the done word has been written back.
    pub done: bool,
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
    for ev in events {
        ops += 1;
        let esize = dtype_bytes(ev.dtype);
        let a = ev.m as u64 * ev.k as u64;
        let b = ev.k as u64 * ev.n as u64;
        let c = ev.m as u64 * ev.n as u64;
        bytes += (a + b + c) * esize;
        macs += ev.m as u64 * ev.n as u64 * ev.k as u64;
    }
    vec![
        crate::Counter {
            name: "ai.tensor.ops".into(),
            value: ops,
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
            ("ticket", Json::Int(self.ticket as i64)),
            ("status", Json::Int(self.status as i64)),
            ("done", Json::Bool(self.done)),
        ])
    }

    /// Compute `dtype` from the descriptor flag word.
    ///
    /// The packing constants live in `g6q_core::model` so this and the generated QEMU
    /// plugin cannot drift apart.
    pub const fn dtype_from_flags(flags: u32) -> u8 {
        ((flags >> g6q_core::model::DTYPE_SHIFT) & g6q_core::model::DTYPE_MASK) as u8
    }
}

/// A stream of tensor events, stamped like a `RecordFile` but separate from the architectural
/// commit stream.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TensorTrace {
    /// Events in emission order.
    pub events: Vec<AiTensorEvent>,
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
            dtype: AiTensorEvent::dtype_from_flags(0x0000_0100),
            ticket: 1,
            status: 0,
            done: true,
        };
        let j = ev.to_json().to_pretty();
        assert!(j.contains("\"op\": 1"));
        assert!(j.contains("\"dtype\": 1"));
        assert!(j.contains("\"done\": true"));
    }

    #[test]
    fn dtype_lives_in_flags_bits_13_8() {
        assert_eq!(AiTensorEvent::dtype_from_flags(0x0000_0100), 1);
        assert_eq!(AiTensorEvent::dtype_from_flags(0x0000_3f00), 0x3f);
        assert_eq!(AiTensorEvent::dtype_from_flags(0), 0);
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
            status: 0,
            done: true,
        };
        let counters = tensor_counters(&[ev]);
        let by_name: std::collections::BTreeMap<_, _> =
            counters.iter().map(|c| (c.name.as_str(), c)).collect();
        assert_eq!(by_name["ai.tensor.ops"].value, 1);
        assert!(by_name["ai.tensor.ops"].fidelity == crate::Fidelity::Synthetic);
        assert_eq!(by_name["ai.tensor.queue_entries"].value, 1);
        // dtype 0 -> 1 byte; matrices: 4*4 + 4*4 + 4*4 = 48 bytes.
        assert_eq!(by_name["ai.tensor.bytes"].value, 48);
        assert_eq!(by_name["ai.tensor.macs"].value, 64);
    }
}
