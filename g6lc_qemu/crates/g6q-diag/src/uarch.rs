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
use g6q_core::model::{AiIslandConfig, TargetModel, Uarch};

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

    // Issue / commit width.
    if let Some(v) = get_u64(uarch, "NrIssuePorts") {
        if v > 0 {
            push(&mut out, "uarch.issue.ports", v);
        }
    }
    if let Some(v) = get_u64(uarch, "NrCommitPorts") {
        if v > 0 {
            push(&mut out, "uarch.commit.ports", v);
        }
    }
    if let Some(v) = get_u64(uarch, "NrWbPorts") {
        if v > 0 {
            push(&mut out, "uarch.writeback.ports", v);
        }
    }
    if let Some(v) = get_u64(uarch, "NrALUs") {
        if v > 0 {
            push(&mut out, "uarch.alu.units", v);
        }
    }
    if let Some(v) = get_u64(uarch, "SuperscalarEn") {
        push(&mut out, "uarch.superscalar.enabled", v);
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
    if let Some(v) = get_u64(uarch, "IcacheSetAssoc") {
        if v > 0 {
            push(&mut out, "uarch.l1i.associativity", v);
        }
    }
    if let Some(v) = get_u64(uarch, "IcacheLineWidth") {
        if v > 0 {
            push(&mut out, "uarch.l1i.line_width", v);
        }
    }
    if let Some(v) = get_u64(uarch, "DcacheByteSize") {
        push(&mut out, "uarch.l1d.size_bytes", v);
    }
    if let Some(v) = get_u64(uarch, "DcacheSetAssoc") {
        if v > 0 {
            push(&mut out, "uarch.l1d.associativity", v);
        }
    }
    if let Some(v) = get_u64(uarch, "DcacheLineWidth") {
        if v > 0 {
            push(&mut out, "uarch.l1d.line_width", v);
        }
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
        if let Some(v) = get_u64(uarch, "L2SetAssoc") {
            if v > 0 {
                push(&mut out, "uarch.l2.associativity", v);
            }
        }
        if let Some(v) = get_u64(uarch, "L2LineWidth") {
            if v > 0 {
                push(&mut out, "uarch.l2.line_width", v);
            }
        }
        if let Some(v) = get_u64(uarch, "L2MshrDepth") {
            if v > 0 {
                push(&mut out, "uarch.l2.mshr_depth", v);
            }
        }
        if let Some(v) = get_u64(uarch, "L2DataBanks") {
            if v > 0 {
                push(&mut out, "uarch.l2.data_banks", v);
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
        if let Some(v) = get_u64(uarch, "L3SetAssoc") {
            if v > 0 {
                push(&mut out, "uarch.l3.associativity", v);
            }
        }
        if let Some(v) = get_u64(uarch, "L3LineWidth") {
            if v > 0 {
                push(&mut out, "uarch.l3.line_width", v);
            }
        }
        if let Some(v) = get_u64(uarch, "L3DataBanks") {
            if v > 0 {
                push(&mut out, "uarch.l3.data_banks", v);
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

    // SMT / fetch scheduling.
    if let Some(v) = get_u64(uarch, "SmtFetchQuantum") {
        if v > 0 {
            push(&mut out, "uarch.smt.fetch_quantum", v);
        }
    }
    if let Some(v) = get_u64(uarch, "SmtStarveLimit") {
        if v > 0 {
            push(&mut out, "uarch.smt.starve_limit", v);
        }
    }

    // AXI / memory-side bus.
    if let Some(v) = get_u64(uarch, "AxiAddrWidth") {
        if v > 0 {
            push(&mut out, "uarch.axi.addr_width", v);
        }
    }
    if let Some(v) = get_u64(uarch, "AxiDataWidth") {
        if v > 0 {
            push(&mut out, "uarch.axi.data_width", v);
        }
    }
    if let Some(v) = get_u64(uarch, "AxiIdWidth") {
        if v > 0 {
            push(&mut out, "uarch.axi.id_width", v);
        }
    }
    if let Some(v) = get_u64(uarch, "MemTidWidth") {
        if v > 0 {
            push(&mut out, "uarch.axi.tid_width", v);
        }
    }

    // Extension / interface enables.
    if let Some(v) = get_u64(uarch, "CvxifEn") {
        push(&mut out, "uarch.cvxif.enabled", v);
    }
    if let Some(v) = get_u64(uarch, "ZawrsEn") {
        push(&mut out, "uarch.zawrs.enabled", v);
    }

    if let Some(v) = get_u64(uarch, "HwPrefetchStreams") {
        if v > 0 {
            push(&mut out, "uarch.l2.prefetch_streams", v);
        }
    }

    out
}

/// D2 microarchitectural counters derived from the AI-island configuration package.
///
/// Structural and geometric values are reported as `Exact` because they are the design's
/// own configured dimensions. Throughput- and bandwidth-claim fields (`macs_per_cycle`,
/// `dram_gbps`) are reported as `Synthetic` with their values present so diagnostics can
/// scale or correlate, but the emulator does not simulate timing or bandwidth and does not
/// treat these as architectural guarantees.
pub fn ai_island_counters(cfg: &AiIslandConfig) -> Vec<Counter> {
    let mut out = Vec::new();

    if cfg.clusters > 0 {
        push(&mut out, "ai.island.clusters", cfg.clusters as u64);
    }
    if cfg.sram_bytes > 0 {
        push(&mut out, "ai.island.sram_bytes", cfg.sram_bytes);
    }
    if cfg.acc_tile_m > 0 {
        push(&mut out, "ai.island.acc_tile.m", cfg.acc_tile_m as u64);
    }
    if cfg.acc_tile_n > 0 {
        push(&mut out, "ai.island.acc_tile.n", cfg.acc_tile_n as u64);
    }
    if cfg.acc_tile_k > 0 {
        push(&mut out, "ai.island.acc_tile.k", cfg.acc_tile_k as u64);
    }
    if cfg.noc_width > 0 {
        push(&mut out, "ai.island.noc_width", cfg.noc_width as u64);
    }
    if cfg.dram_channels > 0 {
        push(
            &mut out,
            "ai.island.dram_channels",
            cfg.dram_channels as u64,
        );
    }
    if cfg.queues > 0 {
        push(&mut out, "ai.island.queues", cfg.queues as u64);
    }
    if cfg.queue_depth > 0 {
        push(&mut out, "ai.island.queue_depth", cfg.queue_depth as u64);
    }
    if cfg.qos_classes > 0 {
        push(&mut out, "ai.island.qos_classes", cfg.qos_classes as u64);
    }
    if cfg.work_quantum_k > 0 {
        push(
            &mut out,
            "ai.island.work_quantum_k",
            cfg.work_quantum_k as u64,
        );
    }

    // Clock frequency is a configured value, not a measured one.
    if cfg.clock_khz > 0 {
        push(&mut out, "ai.island.clock_khz", cfg.clock_khz as u64);
    }

    // Throughput and bandwidth claims are reported as synthetic because the emulator does
    // not model cycles, timing, or bandwidth closure.
    if cfg.macs_per_cycle > 0 {
        out.push(Counter {
            name: "ai.island.macs_per_cycle".into(),
            value: cfg.macs_per_cycle as u64,
            fidelity: Fidelity::Synthetic,
        });
    }
    if cfg.dram_gbps > 0 {
        out.push(Counter {
            name: "ai.island.dram_gbps".into(),
            value: cfg.dram_gbps as u64,
            fidelity: Fidelity::Synthetic,
        });
    }
    if let Some(m) = cfg.measured_dram_gbps_x1000.filter(|m| *m > 0) {
        out.push(Counter {
            name: "ai.island.measured_dram_gbps_x1000".into(),
            value: m as u64,
            fidelity: Fidelity::Measured,
        });
    }

    // Analytic machine properties (blocking factor, intensity, balance, §2 peak). These are
    // `Modelled`: exact arithmetic over the design's own geometry, but bounds rather than
    // observations. Unresolved halves are omitted -- see `roofline`.
    out.extend(crate::roofline::machine_counters(cfg));

    out
}

/// All D2 microarchitectural counters for a resolved target model.
///
/// Combines the CPU-side structure counters with AI-island counters when the model has an
/// AI island. Each counter keeps its own fidelity.
pub fn model_counters(model: &TargetModel) -> Vec<Counter> {
    let mut out = structure_counters(&model.uarch);
    if let Some(island) = model.soc.ai_island.as_ref() {
        out.extend(ai_island_counters(&island.config));
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

    #[test]
    fn ai_island_counters_report_geometry_exact_and_throughput_synthetic() {
        let cfg = AiIslandConfig {
            clusters: 4,
            macs_per_cycle: 64,
            clock_khz: 1_000_000,
            sram_bytes: 1024 * 1024,
            acc_tile_m: 16,
            acc_tile_n: 16,
            acc_tile_k: 16,
            noc_width: 128,
            dram_channels: 4,
            dram_gbps: 100,
            queues: 8,
            queue_depth: 16,
            qos_classes: 4,
            work_quantum_k: 64,
            ..Default::default()
        };
        let counters = ai_island_counters(&cfg);
        let names: Vec<&str> = counters.iter().map(|c| c.name.as_str()).collect();
        assert!(names.contains(&"ai.island.clusters"));
        assert!(names.contains(&"ai.island.sram_bytes"));
        assert!(names.contains(&"ai.island.macs_per_cycle"));
        assert!(names.contains(&"ai.island.dram_gbps"));

        let macs = counters
            .iter()
            .find(|c| c.name == "ai.island.macs_per_cycle")
            .unwrap();
        assert_eq!(macs.value, 64);
        assert_eq!(macs.fidelity, Fidelity::Synthetic);

        let sram = counters
            .iter()
            .find(|c| c.name == "ai.island.sram_bytes")
            .unwrap();
        assert_eq!(sram.value, 1024 * 1024);
        assert_eq!(sram.fidelity, Fidelity::Exact);
    }

    #[test]
    fn ai_island_counters_skip_zero_or_unset_fields() {
        let cfg = AiIslandConfig {
            clusters: 2,
            ..Default::default()
        };
        let counters = ai_island_counters(&cfg);
        let names: Vec<&str> = counters.iter().map(|c| c.name.as_str()).collect();
        assert!(names.contains(&"ai.island.clusters"));
        assert!(!names.contains(&"ai.island.macs_per_cycle"));
    }

    #[test]
    fn model_counters_combine_cpu_and_ai_island() {
        let mut model = TargetModel::new("mini");
        model
            .uarch
            .raw
            .insert("IcacheByteSize".into(), g6q_core::Json::Int(16 * 1024));
        model.soc.ai_island = Some(g6q_core::model::AiIslandModel {
            config: AiIslandConfig {
                clusters: 2,
                queues: 8,
                ..Default::default()
            },
            ..Default::default()
        });
        let counters = model_counters(&model);
        let names: Vec<&str> = counters.iter().map(|c| c.name.as_str()).collect();
        assert!(names.contains(&"uarch.l1i.size_bytes"));
        assert!(names.contains(&"ai.island.clusters"));
        assert!(names.contains(&"ai.island.queues"));
    }

    /// The analytic bound must reach the D2 stream, and must stay out of it when the geometry
    /// is unresolved. Wiring a model that produces no number is the failure this pins.
    #[test]
    fn the_roofline_bound_reaches_the_d2_counter_stream() {
        let mut model = TargetModel::new("island");
        model.soc.ai_island = Some(g6q_core::model::AiIslandModel {
            config: AiIslandConfig {
                clusters: 8,
                macs_per_cycle: 4096,
                clock_khz: 1_500_000,
                acc_tile_m: 512,
                acc_tile_n: 512,
                dram_gbps: 400,
                ..Default::default()
            },
            ..Default::default()
        });
        let names: Vec<String> = model_counters(&model).into_iter().map(|c| c.name).collect();
        for want in [
            "ai.roofline.macs_per_cycle_total",
            "ai.roofline.blocking_t",
            "ai.roofline.tiled_input_intensity_mac_per_byte",
            "ai.roofline.balance_mac_per_byte",
            "ai.roofline.peak_ops_per_sec",
        ] {
            assert!(names.contains(&want.to_string()), "missing {want}");
        }

        // An island whose MAC rate is unpublished contributes no bound at all, rather than a
        // zero one -- the same discipline the rest of the model follows.
        let mut bare = TargetModel::new("island");
        bare.soc.ai_island = Some(g6q_core::model::AiIslandModel {
            config: AiIslandConfig {
                clusters: 1,
                ..Default::default()
            },
            ..Default::default()
        });
        let bare_names: Vec<String> = model_counters(&bare).into_iter().map(|c| c.name).collect();
        assert!(
            !bare_names.iter().any(|n| n.starts_with("ai.roofline.")),
            "unresolved geometry must emit no bound: {bare_names:?}"
        );
    }

    #[test]
    fn structure_counters_expose_issue_width_and_cache_geometry() {
        let u = uarch_with(&[
            ("NrIssuePorts", g6q_core::Json::Int(4)),
            ("NrCommitPorts", g6q_core::Json::Int(4)),
            ("NrWbPorts", g6q_core::Json::Int(6)),
            ("NrALUs", g6q_core::Json::Int(4)),
            ("SuperscalarEn", g6q_core::Json::Bool(true)),
            ("SmtFetchQuantum", g6q_core::Json::Int(4)),
            ("AxiDataWidth", g6q_core::Json::Int(64)),
            ("AxiAddrWidth", g6q_core::Json::Int(64)),
            ("IcacheSetAssoc", g6q_core::Json::Int(4)),
            ("IcacheLineWidth", g6q_core::Json::Int(128)),
            ("DcacheSetAssoc", g6q_core::Json::Int(8)),
            ("DcacheLineWidth", g6q_core::Json::Int(128)),
            ("L2En", g6q_core::Json::Bool(true)),
            ("L2SetAssoc", g6q_core::Json::Int(8)),
            ("L2LineWidth", g6q_core::Json::Int(512)),
        ]);
        let counters = structure_counters(&u);
        let names: Vec<&str> = counters.iter().map(|c| c.name.as_str()).collect();
        assert!(names.contains(&"uarch.issue.ports"));
        assert!(names.contains(&"uarch.commit.ports"));
        assert!(names.contains(&"uarch.writeback.ports"));
        assert!(names.contains(&"uarch.alu.units"));
        assert!(names.contains(&"uarch.superscalar.enabled"));
        assert!(names.contains(&"uarch.smt.fetch_quantum"));
        assert!(names.contains(&"uarch.axi.data_width"));
        assert!(names.contains(&"uarch.axi.addr_width"));
        assert!(names.contains(&"uarch.l1i.associativity"));
        assert!(names.contains(&"uarch.l1i.line_width"));
        assert!(names.contains(&"uarch.l2.associativity"));
        assert!(names.contains(&"uarch.l2.line_width"));
        assert!(!names.contains(&"uarch.l3.associativity"));
    }
}
