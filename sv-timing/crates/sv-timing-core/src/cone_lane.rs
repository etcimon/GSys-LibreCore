// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Virtual timing lanes: compartmentalize 4 GHz concerns so one InsertReg
// cascade cannot starve comb / exclusive / atomic / iterative cones.

//! Algorithm lanes — a **view** over path class + module + reference tree.
//!
//! Path classification stays the measurement. Lanes decide which *transforms*
//! may run. Combinational (`always_comb` / `assign`) cones always keep
//! exclusive/dense/bundle exploration; lanes only gate InsertReg vs T3.

use crate::ir::{TimingDesign, TimingPath};
use crate::path_class::PathClassKind;
use crate::pass_strategy::{is_resilient_datapath, path_has_indexed_restore, path_is_handshake_locked};
use crate::ref_order::RefOrderTree;

/// Virtual concern a path belongs to (4 GHz worklist routing).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConeLane {
    /// Indivisible mul/div — T3 stage count, never InsertReg.
    AtomicMul,
    /// Iterative SRT / serdiv / SRAM — measure only.
    IterativeArith,
    /// Exclusive case/if mux — BalanceMux; explore comb.
    ExclusiveMux,
    /// Next-state `_d` / write-only bundle — BalanceMux, no InsertReg.
    NextStateFsm,
    /// Ordinary comb datapath — SplitAssign + capped InsertReg.
    CombDatapath,
    /// fpnew-style unit that already has pipe regs — T3 NumPipeRegs, comb ok.
    PipelinedUnit,
    /// SVA / bind / comment-only — not primary.
    Screening,
}

impl ConeLane {
    /// InsertReg is the wrong tool.
    pub fn allows_insert_reg(self) -> bool {
        matches!(self, ConeLane::CombDatapath)
    }

    /// Latency-neutral mux / rebalance / split on comb structure.
    pub fn explore_comb(self) -> bool {
        matches!(
            self,
            ConeLane::ExclusiveMux
                | ConeLane::NextStateFsm
                | ConeLane::CombDatapath
                | ConeLane::PipelinedUnit
                | ConeLane::AtomicMul
        )
    }

    /// Rank in the single-cycle primary worklist.
    pub fn in_primary(self) -> bool {
        !matches!(
            self,
            ConeLane::Screening | ConeLane::IterativeArith | ConeLane::AtomicMul
        )
    }
}

/// Derive the lane for a classified path.
pub fn cone_lane(design: &TimingDesign, path: &TimingPath) -> ConeLane {
    let Some(module) = design.modules.get(&path.module) else {
        return ConeLane::CombDatapath;
    };
    let name = module.name.to_ascii_lowercase();
    if module_is_screening(&name) {
        return ConeLane::Screening;
    }
    if path.path_class == PathClassKind::AtomicOverBudget {
        return ConeLane::AtomicMul;
    }
    if path.multi_cycle
        || path.path_class == PathClassKind::MultiCycleTagged
        || module_looks_iterative(&name)
    {
        return ConeLane::IterativeArith;
    }
    if module_looks_pipelined(&name) {
        return ConeLane::PipelinedUnit;
    }
    // Leading/trailing-zero and similar prefix trees are functions: a flop
    // here adds latency to every consumer (PASS-STRATEGY §8 lzc).
    if module_looks_prefix_tree(&name) {
        return ConeLane::ExclusiveMux;
    }
    // Indexed restores (FTQ / pc_bank) never take InsertReg. A gemm-shaped
    // Plain RegToReg that only shares an always_ff with a status pulse is
    // still CombDatapath (audit-gemm-expol2 path 3131 lane_forbids).
    if path_has_indexed_restore(design, path)
        || (path_is_handshake_locked(design, path) && !is_resilient_datapath(design, path))
    {
        return ConeLane::NextStateFsm;
    }
    match path.path_class {
        PathClassKind::ExclusiveCaseMux | PathClassKind::ExclusiveIfChain => {
            ConeLane::ExclusiveMux
        }
        PathClassKind::IndependentLhsBundle | PathClassKind::DenseControlCone => {
            let tree = RefOrderTree::from_nodes(module, &path.nodes);
            let write_only = tree.vars.values().filter(|v| v.is_write_only()).count();
            if write_only >= 4 || tree.procedural_depth() == 0 {
                ConeLane::NextStateFsm
            } else {
                ConeLane::ExclusiveMux
            }
        }
        PathClassKind::UnderBudget | PathClassKind::Plain => ConeLane::CombDatapath,
        PathClassKind::AtomicOverBudget => ConeLane::AtomicMul,
        PathClassKind::MultiCycleTagged => ConeLane::IterativeArith,
    }
}

fn module_is_screening(n: &str) -> bool {
    n.ends_with("_sva") || n.contains("_sva") || n.ends_with("_bind")
}

fn module_looks_iterative(n: &str) -> bool {
    n.contains("vfdsu")
        || n.contains("srt_radix")
        || n.contains("control_mvp")
        || n.contains("serdiv")
        || n.contains("norm_div")
}

fn module_looks_pipelined(n: &str) -> bool {
    n.contains("fpnew_fma")
        || n.contains("fpnew_cast")
        || n.contains("fpnew_noncomp")
        || n.contains("fpnew_opgroup")
}

fn module_looks_prefix_tree(n: &str) -> bool {
    n == "lzc" || n.starts_with("lzc_") || n.ends_with("_lzc")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lanes_gate_insert_reg() {
        assert!(!ConeLane::AtomicMul.allows_insert_reg());
        assert!(!ConeLane::IterativeArith.allows_insert_reg());
        assert!(!ConeLane::ExclusiveMux.allows_insert_reg());
        assert!(!ConeLane::NextStateFsm.allows_insert_reg());
        assert!(!ConeLane::PipelinedUnit.allows_insert_reg());
        assert!(!ConeLane::Screening.allows_insert_reg());
        assert!(ConeLane::CombDatapath.allows_insert_reg());
        assert!(ConeLane::ExclusiveMux.explore_comb());
        assert!(ConeLane::AtomicMul.explore_comb());
        assert!(!ConeLane::Screening.in_primary());
    }
}
