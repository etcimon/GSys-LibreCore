// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! D2 microarchitectural counters sized from the design's own configuration.
//!
//! These are *not* cycle counts. They are the configured sizes of structures the
//! pipeline uses: the guest-visible dimensions of predictors, TLBs, caches and
//! queues. A mismatch with hardware would be a configuration bug, not a timing
//! difference.
//!
//! Values that are written as `0` to mean "infer at build time" are intentionally
//! skipped here rather than reported as zero; the inference logic lives in
//! `g6q-svcfg::derive` and is mirrored when a consumer needs it.

use crate::{Counter, Fidelity};
use g6q_core::model::Uarch;

fn get_u64(uarch: &Uarch, key: &str) -> Option<u64> {
    match uarch.raw.get(key)? {
        g6q_core::Json::Int(i) if *i >= 0 => Some(*i as u64),
        g6q_core::Json::Bool(b) => Some(*b as u64),
        _ => None,
    }
}

fn get_bool(uarch: &Uarch, key: &str) -> Option<bool> {
    match uarch.raw.get(key)? {
        g6q_core::Json::Bool(b) => Some(*b),
        g6q_core::Json::Int(i) => Some(*i != 0),
        _ => None,
    }
}

fn push(out: &mut Vec<Counter>, name: &str, value: u64) {
    out.push(Counter {
        name: name.into(),
        value,
        fidelity: Fidelity::Exact,
    });
}

/// Emit one `Counter` per scalar structure size the design publishes.
///
/// The field names are the design's own `cva6_user_cfg_t` member names; the
/// counter names are the package's stable D2 vocabulary.  A field the package
/// does not state, or states as `0` to mean "infer", is omitted rather than
/// guessed.
pub fn structure_counters(uarch: &Uarch) -> Vec<Counter> {
    let mut out = Vec::new();

    // Branch prediction.
    if let Some(v) = get_u64(uarch, "BTBEntries") {
        push(&mut out, "uarch.btb.entries", v);
    }
    if let Some(v) = get_u64(uarch, "BHTEntries") {
        push(&mut out, "uarch.bht.entries", v);
    }
    if let Some(v) = get_u64(uarch, "BHTHist") {
        push(&mut out, "uarch.bht.history_bits", v);
    }
    if let Some(v) = get_u64(uarch, "RASDepth") {
        push(&mut out, "uarch.ras.depth", v);
    }
    if let Some(v) = get_u64(uarch, "BPTageTables") {
        push(&mut out, "uarch.bp.tage_tables", v);
    }
    if let Some(v) = get_u64(uarch, "BPTageTableEntries") {
        push(&mut out, "uarch.bp.tage_table_entries", v);
    }
    if let Some(v) = get_u64(uarch, "BPTageTagBits") {
        push(&mut out, "uarch.bp.tage_tag_bits", v);
    }
    if let Some(v) = get_u64(uarch, "BPIndirectEntries") {
        push(&mut out, "uarch.bp.indirect_entries", v);
    }
    if let Some(v) = get_u64(uarch, "BPCkptDepth") {
        push(&mut out, "uarch.bp.checkpoint_depth", v);
    }

    // Front-end queues.
    if let Some(v) = get_u64(uarch, "FtqDepth") {
        push(&mut out, "uarch.frontend.ftq_depth", v);
    }
    if let Some(v) = get_u64(uarch, "LoopBufEntries") {
        push(&mut out, "uarch.frontend.loop_buffer_entries", v);
    }

    // Issue / scoreboard.
    if let Some(v) = get_u64(uarch, "NrScoreboardEntries") {
        push(&mut out, "uarch.scoreboard.entries", v);
    }
    if let Some(v) = get_u64(uarch, "RobEntries") {
        if v > 0 {
            push(&mut out, "uarch.reorder_buffer.entries", v);
        }
    }
    if let Some(v) = get_u64(uarch, "IqEntries") {
        if v > 0 {
            push(&mut out, "uarch.issue_queue.entries", v);
        }
    }
    if let Some(v) = get_u64(uarch, "PrfEntries") {
        if v > 0 {
            push(&mut out, "uarch.physical_register_file.entries", v);
        }
    }

    // LSQ / load-store.
    if let Some(v) = get_u64(uarch, "NrLoadBufEntries") {
        push(&mut out, "uarch.lsq.load_entries", v);
    }
    if let Some(v) = get_u64(uarch, "MaxOutstandingStores") {
        push(&mut out, "uarch.lsq.store_entries", v);
    }
    if let Some(v) = get_u64(uarch, "LsqLoadEntries") {
        if v > 0 {
            push(&mut out, "uarch.lsq.load_queue", v);
        }
    }
    if let Some(v) = get_u64(uarch, "LsqStoreEntries") {
        if v > 0 {
            push(&mut out, "uarch.lsq.store_queue", v);
        }
    }

    // Caches.
    if let Some(v) = get_u64(uarch, "IcacheByteSize") {
        push(&mut out, "uarch.l1i.size_bytes", v);
    }
    if let Some(v) = get_u64(uarch, "DcacheByteSize") {
        push(&mut out, "uarch.l1d.size_bytes", v);
    }
    if let Some(v) = get_u64(uarch, "L2En") {
        push(&mut out, "uarch.l2.enabled", v);
    }
    if get_bool(uarch, "L2En").unwrap_or(false) {
        if let Some(v) = get_u64(uarch, "L2ByteSize") {
            if v > 0 {
                push(&mut out, "uarch.l2.size_bytes", v);
            }
        }
        if let Some(v) = get_u64(uarch, "L2MshrDepth") {
            if v > 0 {
                push(&mut out, "uarch.l2.mshr_depth", v);
            }
        }
    }
    if let Some(v) = get_u64(uarch, "L3En") {
        push(&mut out, "uarch.l3.enabled", v);
    }
    if get_bool(uarch, "L3En").unwrap_or(false) {
        if let Some(v) = get_u64(uarch, "L3ByteSize") {
            if v > 0 {
                push(&mut out, "uarch.l3.size_bytes", v);
            }
        }
    }
    if let Some(v) = get_u64(uarch, "DcacheMshrDepth") {
        if v > 0 {
            push(&mut out, "uarch.l1d.mshr_depth", v);
        }
    }

    // TLBs.
    if let Some(v) = get_u64(uarch, "InstrTlbEntries") {
        push(&mut out, "uarch.tlb.instr_entries", v);
    }
    if let Some(v) = get_u64(uarch, "DataTlbEntries") {
        push(&mut out, "uarch.tlb.data_entries", v);
    }
    if let Some(v) = get_u64(uarch, "SharedTlbDepth") {
        if v > 0 {
            push(&mut out, "uarch.tlb.shared_depth", v);
        }
    }

    // Coherence / multi-core.
    if let Some(v) = get_u64(uarch, "NrCores") {
        push(&mut out, "uarch.cores", v);
    }
    if let Some(v) = get_u64(uarch, "NrHarts") {
        push(&mut out, "uarch.threads_per_core", v);
    }
    if let Some(v) = get_u64(uarch, "SnoopFilterEntries") {
        if v > 0 {
            push(&mut out, "uarch.snoop_filter.entries", v);
        }
    }
    if let Some(v) = get_u64(uarch, "CohInvalDepth") {
        if v > 0 {
            push(&mut out, "uarch.coh.inval_depth", v);
        }
    }

    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn uarch_with(pairs: &[(&str, g6q_core::Json)]) -> Uarch {
        Uarch {
            raw: pairs
                .iter()
                .map(|(k, v)| (k.to_string(), v.clone()))
                .collect(),
        }
    }

    #[test]
    fn structure_counters_emit_exact_fidelity() {
        let u = uarch_with(&[
            ("BTBEntries", g6q_core::Json::Int(64)),
            ("BHTEntries", g6q_core::Json::Int(512)),
            ("RASDepth", g6q_core::Json::Int(8)),
            ("IcacheByteSize", g6q_core::Json::Int(16 * 1024)),
            ("L2En", g6q_core::Json::Bool(true)),
            ("L2ByteSize", g6q_core::Json::Int(256 * 1024)),
            ("L3En", g6q_core::Json::Bool(false)),
            ("L3ByteSize", g6q_core::Json::Int(0)),
            ("RobEntries", g6q_core::Json::Int(0)), // 0 = infer, should be skipped
        ]);
        let counters = structure_counters(&u);
        let names: Vec<&str> = counters.iter().map(|c| c.name.as_str()).collect();
        assert!(names.contains(&"uarch.btb.entries"));
        assert!(names.contains(&"uarch.bht.entries"));
        assert!(names.contains(&"uarch.ras.depth"));
        assert!(names.contains(&"uarch.l2.enabled"));
        assert!(names.contains(&"uarch.l2.size_bytes"));
        assert!(
            !names.contains(&"uarch.l3.size_bytes"),
            "L3 disabled, size skipped"
        );
        assert!(
            !names.contains(&"uarch.reorder_buffer.entries"),
            "0 = infer, skipped"
        );

        for c in &counters {
            assert_eq!(c.fidelity, Fidelity::Exact);
        }
    }

    #[test]
    fn missing_fields_are_silent_not_zero() {
        let u = Uarch::default();
        let counters = structure_counters(&u);
        assert!(counters.is_empty());
    }
}
