// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Per-module algorithm-set explorer. Timing basis (structural FO4, not STA):
//   B = period_ns * 1000 / fo4_ps * (1 - margin)
//   a module "passes" when every primary path has slack ≥ 0, or a set is
//   presumed to close that path (JIT/multi-cut on CombDatapath; multi-cycle
//   tag on atomic/iterative). always_ff cycle bars stay on ClockDomain.
// Optimization (per module):
//   maximize C(s) = w_ff D_ff(s) + w_comb D_comb(s) − w_a A(s) − w_t 1[¬pass]
//   s.t. s logically applicable
//   prefer {s | pass(s)} if nonempty (timing is a hard constraint when possible)
// Weights favour always_ff / always_comb process density. Higher A(s)
// (InsertReg spray, multi-cut) is presumed less clean.

//! Per-module cleanliness optimization over logical algorithm sets.
//!
//! Each module explores a **catalog** of algorithm sets (classify, clock-aware
//! `always_ff` factorize, exclusive/bundle comb, split, JIT InsertReg,
//! multi-cycle honesty, aggressive pipeline). A set is considered only when it
//! applies to that module's regions and cone lanes. Among applicable sets the
//! solver picks a **working** solution: timing-passing sets first, then the
//! maximum cleanliness score. Cleanliness weights `always_ff` and
//! `always_comb` density above other structure; aggressiveness is a penalty.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::cone_lane::{cone_lane, ConeLane};
use crate::ir::{OpportunityKind, RegionKind, TimingDesign, TimingModule};
use crate::path_class::PathClassKind;

/// Named algorithm set a module may run.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AlgoSetId {
    /// Path class + scratch only. Cleanest when timing already passes.
    ClassifyOnly,
    /// Clock-aware `always_ff` factorize (kept sequential scratch).
    FfFactorClock,
    /// Exclusive / bundle / dense comb exploration + BalanceMux.
    CombExclusive,
    /// Comb exclusive plus named-wire SplitAssign (latency-neutral).
    CombSplit,
    /// `always_ff` factorize **and** comb exclusive (mixed modules).
    SeqPlusComb,
    /// JIT InsertReg on CombDatapath only (timing-fail closer).
    JitDatapath,
    /// Multi-cycle / T3 honesty for atomic, iterative, pipelined units.
    MulticycleHonest,
    /// Multi-cut budget-fit pipeline (most aggressive, least clean).
    AggressivePipeline,
}

impl AlgoSetId {
    /// Stable label for reports.
    pub fn as_str(self) -> &'static str {
        match self {
            AlgoSetId::ClassifyOnly => "classify_only",
            AlgoSetId::FfFactorClock => "ff_factor_clock",
            AlgoSetId::CombExclusive => "comb_exclusive",
            AlgoSetId::CombSplit => "comb_split",
            AlgoSetId::SeqPlusComb => "seq_plus_comb",
            AlgoSetId::JitDatapath => "jit_datapath",
            AlgoSetId::MulticycleHonest => "multicycle_honest",
            AlgoSetId::AggressivePipeline => "aggressive_pipeline",
        }
    }
}

/// Catalog entry: which algorithms fire and how aggressive the set is.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AlgoSetSpec {
    /// Set id.
    pub id: AlgoSetId,
    /// Presumed aggressiveness \(A \in [0,1]\) (1 = least clean).
    pub aggressiveness: f64,
    /// Clock-aware always_ff factorize.
    pub ff_factor: bool,
    /// Exclusive / bundle / dense / BalanceMux on always_comb.
    pub comb_exclusive: bool,
    /// SplitAssign named wires.
    pub comb_split: bool,
    /// JIT InsertReg on CombDatapath.
    pub jit_reg: bool,
    /// Multi-cut pipeline (O3-class).
    pub multi_cut: bool,
    /// Tag atomic/iterative/pipelined as multi-cycle / T3.
    pub mc_tag: bool,
}

/// Weights for the cleanliness objective. Defaults **favour** always_ff and
/// always_comb density; timing fail is a larger penalty than aggressiveness.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct CleanlinessWeights {
    /// Weight on sequential process density (`always_ff`).
    pub always_ff: f64,
    /// Weight on combinational process density (`always_comb`).
    pub always_comb: f64,
    /// Penalty on aggressiveness \(A(s)\).
    pub aggressiveness: f64,
    /// Penalty when the set does not meet the timing objective.
    pub timing_fail: f64,
}

impl Default for CleanlinessWeights {
    fn default() -> Self {
        Self {
            always_ff: 0.40,
            always_comb: 0.40,
            aggressiveness: 0.20,
            timing_fail: 0.50,
        }
    }
}

impl CleanlinessWeights {
    /// \(C = w_{ff} D_{ff} + w_{comb} D_{comb} - w_a A - w_t 1[\neg pass]\).
    pub fn score(self, d_ff: f64, d_comb: f64, aggressiveness: f64, timing_pass: bool) -> f64 {
        self.always_ff * d_ff.clamp(0.0, 1.0)
            + self.always_comb * d_comb.clamp(0.0, 1.0)
            - self.aggressiveness * aggressiveness.clamp(0.0, 1.0)
            - if timing_pass { 0.0 } else { self.timing_fail }
    }
}

/// One explored set for a module (applicable or not).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AlgoSetCandidate {
    /// Set id.
    pub id: AlgoSetId,
    /// Human label.
    pub label: String,
    /// Whether the set is logically applicable to this module.
    pub applicable: bool,
    /// Presumed aggressiveness.
    pub aggressiveness: f64,
    /// Estimated `always_ff` process density after the set.
    pub always_ff_density: f64,
    /// Estimated `always_comb` process density after the set.
    pub always_comb_density: f64,
    /// Whether the set is estimated to meet the FO4 budget (or honest MC).
    pub timing_pass: bool,
    /// Objective value \(C(s)\).
    pub cleanliness: f64,
    /// Short why (lanes, bonuses, pass/fail).
    pub note: String,
}

/// Chosen solution plus the explored catalog for one module.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ModuleSolution {
    /// Module name.
    pub module: String,
    /// Winning set.
    pub chosen: AlgoSetId,
    /// Final cleanliness of the winner (the optimization objective).
    pub cleanliness: f64,
    /// Winner `always_ff` density.
    pub always_ff_density: f64,
    /// Winner `always_comb` density.
    pub always_comb_density: f64,
    /// Winner timing estimate.
    pub timing_pass: bool,
    /// True when primary paths already close before a new transform.
    pub timing_now: bool,
    /// Count of `always_ff` regions.
    pub n_always_ff: u32,
    /// Count of `always_comb` regions.
    pub n_always_comb: u32,
    /// Count of continuous-assign regions.
    pub n_assign: u32,
    /// True when the winner was chosen from the timing-feasible subset.
    pub feasible: bool,
    /// Full catalog (inapplicable sets included with `applicable=false`).
    pub candidates: Vec<AlgoSetCandidate>,
    /// One-line solver rationale.
    pub rationale: String,
}

impl ModuleSolution {
    /// Whether this solution permits an auto-correct opportunity kind.
    pub fn allows_opportunity(&self, kind: OpportunityKind) -> bool {
        let spec = spec_of(self.chosen);
        match kind {
            OpportunityKind::InsertReg => spec.jit_reg || spec.multi_cut,
            OpportunityKind::SplitAssign => spec.comb_split || spec.comb_exclusive,
            OpportunityKind::BalanceMux => {
                spec.comb_exclusive || spec.ff_factor || spec.comb_split
            }
        }
    }
}

/// Catalog in aggressiveness order (stable tie-break prefers earlier / cleaner).
pub fn algo_set_catalog() -> [AlgoSetSpec; 8] {
    [
        AlgoSetSpec {
            id: AlgoSetId::ClassifyOnly,
            aggressiveness: 0.00,
            ff_factor: false,
            comb_exclusive: false,
            comb_split: false,
            jit_reg: false,
            multi_cut: false,
            mc_tag: false,
        },
        AlgoSetSpec {
            id: AlgoSetId::FfFactorClock,
            aggressiveness: 0.10,
            ff_factor: true,
            comb_exclusive: false,
            comb_split: false,
            jit_reg: false,
            multi_cut: false,
            mc_tag: false,
        },
        AlgoSetSpec {
            id: AlgoSetId::CombExclusive,
            aggressiveness: 0.20,
            ff_factor: false,
            comb_exclusive: true,
            comb_split: false,
            jit_reg: false,
            multi_cut: false,
            mc_tag: false,
        },
        AlgoSetSpec {
            id: AlgoSetId::MulticycleHonest,
            aggressiveness: 0.25,
            ff_factor: false,
            comb_exclusive: false,
            comb_split: false,
            jit_reg: false,
            multi_cut: false,
            mc_tag: true,
        },
        AlgoSetSpec {
            id: AlgoSetId::SeqPlusComb,
            aggressiveness: 0.30,
            ff_factor: true,
            comb_exclusive: true,
            comb_split: false,
            jit_reg: false,
            multi_cut: false,
            mc_tag: false,
        },
        AlgoSetSpec {
            id: AlgoSetId::CombSplit,
            aggressiveness: 0.40,
            ff_factor: false,
            comb_exclusive: true,
            comb_split: true,
            jit_reg: false,
            multi_cut: false,
            mc_tag: false,
        },
        AlgoSetSpec {
            id: AlgoSetId::JitDatapath,
            aggressiveness: 0.70,
            ff_factor: false,
            comb_exclusive: false,
            comb_split: true,
            jit_reg: true,
            multi_cut: false,
            mc_tag: false,
        },
        AlgoSetSpec {
            id: AlgoSetId::AggressivePipeline,
            aggressiveness: 0.95,
            ff_factor: false,
            comb_exclusive: false,
            comb_split: true,
            jit_reg: true,
            multi_cut: true,
            mc_tag: false,
        },
    ]
}

fn spec_of(id: AlgoSetId) -> AlgoSetSpec {
    algo_set_catalog()
        .into_iter()
        .find(|s| s.id == id)
        .expect("catalog covers every AlgoSetId")
}

/// Region / lane / slack snapshot used to decide applicability and pass/fail.
#[derive(Debug, Clone)]
struct ModuleProfile {
    n_ff: u32,
    n_comb: u32,
    n_assign: u32,
    has_exclusive: bool,
    has_datapath: bool,
    has_atomic_iter: bool,
    has_pipelined: bool,
    closes_now: bool,
    n_primary: u32,
    n_failing: u32,
    n_failing_datapath: u32,
    n_failing_multicycle: u32,
}

fn profile_of(design: &TimingDesign, module: &TimingModule) -> ModuleProfile {
    let mut n_ff = 0u32;
    let mut n_comb = 0u32;
    let mut n_assign = 0u32;
    for r in module.regions.values() {
        match r.kind {
            RegionKind::AlwaysFf => n_ff += 1,
            RegionKind::AlwaysComb => n_comb += 1,
            RegionKind::ContAssign => n_assign += 1,
        }
    }
    let mut has_exclusive = false;
    let mut has_datapath = false;
    let mut has_atomic_iter = false;
    let mut has_pipelined = false;
    let mut n_primary = 0u32;
    let mut n_failing = 0u32;
    let mut n_failing_datapath = 0u32;
    let mut n_failing_multicycle = 0u32;
    for p in design.paths.iter().filter(|p| p.module == module.id) {
        let lane = cone_lane(design, p);
        match lane {
            ConeLane::ExclusiveMux | ConeLane::NextStateFsm => has_exclusive = true,
            ConeLane::CombDatapath => has_datapath = true,
            ConeLane::AtomicMul | ConeLane::IterativeArith => has_atomic_iter = true,
            ConeLane::PipelinedUnit => has_pipelined = true,
            ConeLane::Screening => {}
        }
        if matches!(
            p.path_class,
            PathClassKind::ExclusiveCaseMux
                | PathClassKind::ExclusiveIfChain
                | PathClassKind::IndependentLhsBundle
                | PathClassKind::DenseControlCone
        ) {
            has_exclusive = true;
        }
        if p.multi_cycle
            || p.path_class == PathClassKind::MultiCycleTagged
            || lane == ConeLane::Screening
        {
            continue; // already tagged / not a timing objective
        }
        if matches!(lane, ConeLane::AtomicMul | ConeLane::IterativeArith) {
            // Still on the single-cycle books until an mc_tag set is chosen.
            n_primary += 1;
            n_failing += 1;
            n_failing_multicycle += 1;
            continue;
        }
        n_primary += 1;
        if p.slack_fo4 < 0.0 {
            n_failing += 1;
            match lane {
                ConeLane::CombDatapath => n_failing_datapath += 1,
                ConeLane::PipelinedUnit => n_failing_multicycle += 1,
                _ => {}
            }
        }
    }
    ModuleProfile {
        n_ff,
        n_comb,
        n_assign,
        has_exclusive,
        has_datapath,
        has_atomic_iter,
        has_pipelined,
        closes_now: n_failing == 0,
        n_primary,
        n_failing,
        n_failing_datapath,
        n_failing_multicycle,
    }
}

fn applicable(spec: &AlgoSetSpec, p: &ModuleProfile) -> bool {
    match spec.id {
        AlgoSetId::ClassifyOnly => true,
        AlgoSetId::FfFactorClock => p.n_ff > 0,
        AlgoSetId::CombExclusive => p.n_comb + p.n_assign > 0 && p.has_exclusive,
        AlgoSetId::CombSplit => p.n_comb + p.n_assign > 0 && (p.has_datapath || p.has_exclusive),
        AlgoSetId::SeqPlusComb => p.n_ff > 0 && p.n_comb + p.n_assign > 0,
        AlgoSetId::JitDatapath => p.has_datapath && !p.closes_now,
        AlgoSetId::MulticycleHonest => p.has_atomic_iter || p.has_pipelined,
        AlgoSetId::AggressivePipeline => p.has_datapath && !p.closes_now,
    }
}

/// Timing objective for a set. Comb exclusive does not invent slack — it uses
/// already-classified path FO4. JIT / multi-cut on CombDatapath are presumed
/// to close (N = ceil(M/B) stages). Atomic/iterative pass via honest MC tag.
fn timing_pass(spec: &AlgoSetSpec, p: &ModuleProfile) -> bool {
    if p.closes_now {
        return true;
    }
    if p.n_failing == 0 {
        return true;
    }
    // Remaining failures: a set passes only if it has a closer for them.
    if p.n_failing_datapath == p.n_failing && (spec.jit_reg || spec.multi_cut) {
        return true;
    }
    if spec.mc_tag {
        // MC tag removes atomic/iterative from the primary objective; if the
        // only failures were those lanes, treat as pass. Mixed datapath still
        // needs JIT — handled above.
        if p.n_failing_multicycle == p.n_failing {
            return true;
        }
    }
    false
}

fn densities(spec: &AlgoSetSpec, p: &ModuleProfile) -> (f64, f64) {
    let n = (p.n_ff + p.n_comb + p.n_assign).max(1) as f64;
    // Half the score is the observed always_* fraction so a module that is
    // already all always_comb still has headroom for exclusive/factor bonuses
    // (otherwise clamp-to-1 would hide the cleanliness ranking).
    let mut d_ff = 0.50 * (p.n_ff as f64 / n);
    let mut d_comb = 0.50 * (p.n_comb as f64 / n);
    // Process-structure bonuses: factorize / exclusive keep always_* blocks.
    // InsertReg / multi-cut spray is presumed less clean (not an always_ff).
    if spec.ff_factor {
        d_ff += 0.30;
    }
    if spec.comb_exclusive {
        d_comb += 0.25;
    }
    if spec.comb_split && !spec.jit_reg {
        d_comb += 0.10;
    }
    if spec.jit_reg {
        d_ff -= 0.20;
        d_comb -= 0.15;
    }
    if spec.multi_cut {
        d_ff -= 0.15;
        d_comb -= 0.10;
    }
    if spec.id == AlgoSetId::ClassifyOnly && p.n_ff > 0 {
        d_ff += 0.05; // leave existing always_ff untouched
    }
    if spec.id == AlgoSetId::ClassifyOnly && p.n_comb > 0 {
        d_comb += 0.05;
    }
    (d_ff.clamp(0.0, 1.0), d_comb.clamp(0.0, 1.0))
}

/// Explore the catalog for one module and pick the cleanliness winner.
pub fn explore_module(
    design: &TimingDesign,
    module: &TimingModule,
    weights: CleanlinessWeights,
) -> ModuleSolution {
    let p = profile_of(design, module);
    let mut candidates = Vec::new();
    for spec in algo_set_catalog() {
        let appl = applicable(&spec, &p);
        let (d_ff, d_comb) = densities(&spec, &p);
        let pass = appl && timing_pass(&spec, &p);
        let c = if appl {
            weights.score(d_ff, d_comb, spec.aggressiveness, pass)
        } else {
            f64::NEG_INFINITY
        };
        candidates.push(AlgoSetCandidate {
            id: spec.id,
            label: spec.id.as_str().into(),
            applicable: appl,
            aggressiveness: spec.aggressiveness,
            always_ff_density: d_ff,
            always_comb_density: d_comb,
            timing_pass: pass,
            cleanliness: if appl { c } else { 0.0 },
            note: format!(
                "ff={} comb={} asg={} excl={} dp={} atom={} pipe={} fail={}/{} A={:.2}",
                p.n_ff,
                p.n_comb,
                p.n_assign,
                p.has_exclusive,
                p.has_datapath,
                p.has_atomic_iter,
                p.has_pipelined,
                p.n_failing,
                p.n_primary,
                spec.aggressiveness
            ),
        });
    }

    let applicable: Vec<&AlgoSetCandidate> = candidates.iter().filter(|c| c.applicable).collect();
    let feasible: Vec<&AlgoSetCandidate> = applicable
        .iter()
        .copied()
        .filter(|c| c.timing_pass)
        .collect();
    let pool_is_feasible = !feasible.is_empty();
    let pool = if feasible.is_empty() {
        applicable
    } else {
        feasible
    };
    let chosen = pool
        .iter()
        .max_by(|a, b| {
            a.cleanliness
                .partial_cmp(&b.cleanliness)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| {
                    b.aggressiveness
                        .partial_cmp(&a.aggressiveness)
                        .unwrap_or(std::cmp::Ordering::Equal)
                })
                .then_with(|| a.id.cmp(&b.id))
        })
        .map(|c| (*c).clone())
        .or_else(|| candidates.first().cloned())
        .expect("catalog nonempty");
    let from_feasible = pool_is_feasible && chosen.timing_pass;
    let rationale = if chosen.timing_pass {
        format!(
            "argmax C among timing-pass sets → {} C={:.3} D_ff={:.2} D_comb={:.2} A={:.2}",
            chosen.label, chosen.cleanliness, chosen.always_ff_density, chosen.always_comb_density,
            chosen.aggressiveness
        )
    } else {
        format!(
            "no timing-pass set; argmax C with fail penalty → {} C={:.3}",
            chosen.label, chosen.cleanliness
        )
    };
    ModuleSolution {
        module: module.name.clone(),
        chosen: chosen.id,
        cleanliness: chosen.cleanliness,
        always_ff_density: chosen.always_ff_density,
        always_comb_density: chosen.always_comb_density,
        timing_pass: chosen.timing_pass,
        timing_now: p.closes_now,
        n_always_ff: p.n_ff,
        n_always_comb: p.n_comb,
        n_assign: p.n_assign,
        feasible: from_feasible && chosen.timing_pass,
        candidates,
        rationale,
    }
}

/// Fill [`TimingDesign::module_cleanliness`] for every module.
///
/// Run after path_class + parallel-timing so lanes, slacks, and clock-aware
/// `always_ff` scratches are already on the design.
pub fn fill_design_cleanliness(design: &mut TimingDesign) {
    let w = CleanlinessWeights::default();
    let mut out = BTreeMap::new();
    for module in design.modules.values() {
        out.insert(module.name.clone(), explore_module(design, module, w));
    }
    design.module_cleanliness = out;
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::expr::Expr;
    use crate::ir::{
        CombRegion, EdgeKind, GateInfo, IrNode, OperatorClass, PathEndpoint, PathKind, TimingPath,
        TimingTarget,
    };
    use crate::loc::{OriginKind, SourceLoc};

    fn loc() -> SourceLoc {
        SourceLoc {
            file: "c.sv".into(),
            start_line: 1,
            start_col: 1,
            end_line: 1,
            end_col: 2,
            byte_start: 0,
            byte_end: 1,
            origin: OriginKind::UserFile,
        }
    }

    fn node(id: u32, lhs: &str, rhs: &str, fo4: f64) -> IrNode {
        IrNode {
            id,
            op_class: Some(OperatorClass::AddSub),
            width: 32,
            fo4_cost: fo4,
            gate: None,
            loc: loc(),
            fans_in: vec![],
            fans_out: vec![],
            width_defaulted: true,
            reads_reg: false,
            lhs: Some(lhs.into()),
            rhs: Some(rhs.into()),
            lhs_expr: None,
            rhs_expr: Some(Expr::parse(rhs)),
            case_labels: Vec::new(),
            case_is_default: false,
            case_selector: None,
            fo4_locked: false,
        }
    }

    fn empty_module(name: &str, nodes: BTreeMap<u32, IrNode>) -> TimingModule {
        TimingModule {
            id: 0,
            name: name.into(),
            file: "c.sv".into(),
            nodes,
            regions: BTreeMap::new(),
            localparams: vec![],
            parameters: vec![],
            ports: vec![],
            gen_loops: vec![],
            functions: vec![],
            package_imports: vec![],
            instances: vec![],
            loc: loc(),
        }
    }

    fn path(
        id: u32,
        region: u32,
        fo4: f64,
        budget: f64,
        class: PathClassKind,
        multi: bool,
    ) -> TimingPath {
        TimingPath {
            id,
            region_id: region,
            module: 0,
            start: PathEndpoint::InputPort { module: 0, port: 0 },
            end: PathEndpoint::OutputPort { module: 0, port: 1 },
            path_kind: PathKind::InToOut,
            startpoint: "m.in".into(),
            endpoint: "m.out".into(),
            nodes: vec![0],
            total_fo4: fo4,
            slack_fo4: budget - fo4,
            max_freq_mhz: 4000.0,
            primary_loc: loc(),
            multi_cycle: multi,
            path_class: class,
            total_fo4_raw: None,
            class_note: None,
        }
    }

    fn ff_region(id: u32, nodes: Vec<u32>) -> CombRegion {
        let mut gate = GateInfo {
            is_comb: false,
            ..GateInfo::default()
        };
        gate.clock_name = Some("clk_i".into());
        gate.edge = Some(EdgeKind::Posedge);
        CombRegion {
            id,
            module: 0,
            kind: RegionKind::AlwaysFf,
            label: None,
            gate,
            nodes,
            total_fo4: 1.0,
            loc_span: loc(),
            multi_cycle: false,
        }
    }

    fn comb_region(id: u32, nodes: Vec<u32>) -> CombRegion {
        CombRegion {
            id,
            module: 0,
            kind: RegionKind::AlwaysComb,
            label: None,
            gate: GateInfo {
                is_comb: true,
                ..GateInfo::default()
            },
            nodes,
            total_fo4: 1.0,
            loc_span: loc(),
            multi_cycle: false,
        }
    }

    fn design_with_paths(paths: &[(PathClassKind, f64, bool)]) -> TimingDesign {
        let mut design = TimingDesign::empty(TimingTarget::new(4000.0, 20.0, 0.2));
        assert_eq!(design.target.budget_fo4, 10.0);
        let mut module = empty_module("mixed_lanes", BTreeMap::new());
        for (id, &(class, fo4, multi_cycle)) in paths.iter().enumerate() {
            let id = id as u32;
            module
                .nodes
                .insert(id, node(id, &format!("out_{id}"), "a + b", fo4));
            module.regions.insert(id, comb_region(id, vec![id]));
            let mut p = path(id, id, fo4, design.target.budget_fo4, class, multi_cycle);
            p.nodes = vec![id];
            design.paths.push(p);
        }
        design.modules.insert(0, module);
        design
    }

    #[test]
    fn jit_does_not_cover_failing_exclusive_or_next_state_paths() {
        for class in [
            PathClassKind::ExclusiveCaseMux,
            PathClassKind::ExclusiveIfChain,
            PathClassKind::IndependentLhsBundle,
            PathClassKind::DenseControlCone,
        ] {
            for datapath_fo4 in [1.0, 40.0] {
                let design = design_with_paths(&[
                    (PathClassKind::Plain, datapath_fo4, false),
                    (class, 20.0, false),
                ]);
                let sol = explore_module(
                    &design,
                    design.modules.get(&0).unwrap(),
                    CleanlinessWeights::default(),
                );
                for id in [AlgoSetId::JitDatapath, AlgoSetId::AggressivePipeline] {
                    let candidate = sol.candidates.iter().find(|c| c.id == id).unwrap();
                    assert!(candidate.applicable);
                    assert!(
                        !candidate.timing_pass,
                        "{id:?} cannot cover {class:?}: {}",
                        candidate.note
                    );
                }
                assert!(!sol.timing_now);
                assert!(!sol.timing_pass, "{}", sol.rationale);
                assert!(!sol.feasible);
            }
        }
    }

    #[test]
    fn jit_does_not_cover_failing_atomic_path() {
        let design = design_with_paths(&[
            (PathClassKind::Plain, 40.0, false),
            (PathClassKind::AtomicOverBudget, 56.0, false),
        ]);
        let sol = explore_module(
            &design,
            design.modules.get(&0).unwrap(),
            CleanlinessWeights::default(),
        );
        assert!(!sol.timing_now);
        assert!(!sol.feasible, "{}", sol.rationale);
        assert!(sol.candidates.iter().all(|c| !c.timing_pass));
    }

    #[test]
    fn multicycle_does_not_cover_failing_exclusive_or_next_state_paths() {
        for class in [
            PathClassKind::ExclusiveCaseMux,
            PathClassKind::ExclusiveIfChain,
            PathClassKind::IndependentLhsBundle,
            PathClassKind::DenseControlCone,
        ] {
            for tagged in [false, true] {
                let design = design_with_paths(&[
                    (PathClassKind::AtomicOverBudget, 56.0, tagged),
                    (class, 20.0, false),
                ]);
                let sol = explore_module(
                    &design,
                    design.modules.get(&0).unwrap(),
                    CleanlinessWeights::default(),
                );
                let mc = sol
                    .candidates
                    .iter()
                    .find(|c| c.id == AlgoSetId::MulticycleHonest)
                    .unwrap();
                assert!(mc.applicable);
                assert!(!mc.timing_pass, "MC cannot cover {class:?}: {}", mc.note);
                assert!(!sol.timing_now);
                assert!(!sol.timing_pass, "{}", sol.rationale);
                assert!(!sol.feasible);
            }
        }
    }

    #[test]
    fn multicycle_covers_atomic_with_only_passing_companion_paths() {
        let design = design_with_paths(&[
            (PathClassKind::AtomicOverBudget, 56.0, false),
            (PathClassKind::Plain, 1.0, false),
            (PathClassKind::ExclusiveCaseMux, 10.0, false),
        ]);
        let sol = explore_module(
            &design,
            design.modules.get(&0).unwrap(),
            CleanlinessWeights::default(),
        );
        assert!(!sol.timing_now);
        assert_eq!(sol.chosen, AlgoSetId::MulticycleHonest, "{}", sol.rationale);
        assert!(sol.timing_pass && sol.feasible);
        for candidate in &sol.candidates {
            assert_eq!(
                candidate.timing_pass,
                candidate.id == AlgoSetId::MulticycleHonest,
                "{}",
                candidate.note
            );
        }
    }

    #[test]
    fn jit_covers_datapath_with_only_passing_or_tagged_companion_paths() {
        let design = design_with_paths(&[
            (PathClassKind::Plain, 40.0, false),
            (PathClassKind::ExclusiveCaseMux, 10.0, false),
            (PathClassKind::AtomicOverBudget, 56.0, true),
            (PathClassKind::MultiCycleTagged, 120.0, false),
        ]);
        let sol = explore_module(
            &design,
            design.modules.get(&0).unwrap(),
            CleanlinessWeights::default(),
        );
        assert!(!sol.timing_now);
        assert_eq!(sol.chosen, AlgoSetId::JitDatapath, "{}", sol.rationale);
        assert!(sol.timing_pass && sol.feasible);
        assert!(sol.allows_opportunity(OpportunityKind::InsertReg));
    }

    #[test]
    fn density_weights_cannot_make_uncovered_failures_feasible() {
        let design = design_with_paths(&[
            (PathClassKind::Plain, 40.0, false),
            (PathClassKind::ExclusiveCaseMux, 20.0, false),
        ]);
        let sol = explore_module(
            &design,
            design.modules.get(&0).unwrap(),
            CleanlinessWeights {
                always_ff: 1000.0,
                always_comb: 1000.0,
                aggressiveness: 0.0,
                timing_fail: 0.0,
            },
        );
        assert!(!sol.timing_now);
        assert!(!sol.timing_pass, "{}", sol.rationale);
        assert!(!sol.feasible);
        assert!(sol.candidates.iter().all(|c| !c.timing_pass));
    }

    #[test]
    fn under_budget_mixed_prefers_seq_plus_comb_density() {
        let budget = 10.0;
        let mut design = TimingDesign::empty(TimingTarget::new(4000.0, 20.0, 0.2));
        let mut nodes = BTreeMap::new();
        nodes.insert(0, node(0, "q", "d", 1.0));
        nodes.insert(1, node(1, "y", "a + b", 1.0));
        let mut m = empty_module("u_mix", nodes);
        m.regions.insert(0, ff_region(0, vec![0]));
        m.regions.insert(1, comb_region(1, vec![1]));
        design.modules.insert(0, m);
        design.paths.push(path(
            1,
            1,
            1.0,
            budget,
            PathClassKind::ExclusiveCaseMux,
            false,
        ));
        let sol = explore_module(
            &design,
            design.modules.get(&0).unwrap(),
            CleanlinessWeights::default(),
        );
        assert_eq!(sol.chosen, AlgoSetId::SeqPlusComb, "{}", sol.rationale);
        assert!(sol.timing_pass);
        assert!(sol.feasible);
        assert!(sol.always_ff_density > 0.4, "ff density {}", sol.always_ff_density);
        assert!(sol.always_comb_density > 0.4, "comb density {}", sol.always_comb_density);
        assert!(sol.allows_opportunity(OpportunityKind::BalanceMux));
        assert!(!sol.allows_opportunity(OpportunityKind::InsertReg));
    }

    #[test]
    fn datapath_over_budget_picks_jit_not_aggressive() {
        let budget = 10.0;
        let mut design = TimingDesign::empty(TimingTarget::new(4000.0, 20.0, 0.2));
        let mut nodes = BTreeMap::new();
        nodes.insert(0, node(0, "y", "a + b", 40.0));
        let mut m = empty_module("alu", nodes);
        m.regions.insert(0, comb_region(0, vec![0]));
        design.modules.insert(0, m);
        design.paths.push(path(1, 0, 40.0, budget, PathClassKind::Plain, false));
        let sol = explore_module(
            &design,
            design.modules.get(&0).unwrap(),
            CleanlinessWeights::default(),
        );
        assert_eq!(sol.chosen, AlgoSetId::JitDatapath, "{}", sol.rationale);
        assert!(sol.timing_pass, "JIT presumed to close CombDatapath");
        assert!(sol.allows_opportunity(OpportunityKind::InsertReg));
        let agg = sol
            .candidates
            .iter()
            .find(|c| c.id == AlgoSetId::AggressivePipeline)
            .unwrap();
        assert!(agg.applicable && agg.timing_pass);
        assert!(
            sol.cleanliness > agg.cleanliness,
            "more aggressive must score less clean when both pass: {} vs {}",
            sol.cleanliness,
            agg.cleanliness
        );
    }

    #[test]
    fn exclusive_over_budget_does_not_pick_insert_reg() {
        let budget = 10.0;
        let mut design = TimingDesign::empty(TimingTarget::new(4000.0, 20.0, 0.2));
        let mut nodes = BTreeMap::new();
        nodes.insert(0, node(0, "rdata", "mux", 20.0));
        let mut m = empty_module("csr", nodes);
        m.regions.insert(0, comb_region(0, vec![0]));
        design.modules.insert(0, m);
        design.paths.push(path(
            1,
            0,
            20.0,
            budget,
            PathClassKind::ExclusiveCaseMux,
            false,
        ));
        let sol = explore_module(
            &design,
            design.modules.get(&0).unwrap(),
            CleanlinessWeights::default(),
        );
        assert_ne!(sol.chosen, AlgoSetId::JitDatapath, "{}", sol.rationale);
        assert_ne!(sol.chosen, AlgoSetId::AggressivePipeline, "{}", sol.rationale);
        assert!(!sol.allows_opportunity(OpportunityKind::InsertReg));
        assert!(
            matches!(
                sol.chosen,
                AlgoSetId::CombExclusive | AlgoSetId::CombSplit | AlgoSetId::ClassifyOnly
            ),
            "{}",
            sol.rationale
        );
    }

    #[test]
    fn atomic_picks_multicycle_honest() {
        let budget = 10.0;
        let mut design = TimingDesign::empty(TimingTarget::new(4000.0, 20.0, 0.2));
        let mut nodes = BTreeMap::new();
        nodes.insert(0, node(0, "p", "a * b", 56.0));
        let mut m = empty_module("mul", nodes);
        m.regions.insert(0, comb_region(0, vec![0]));
        design.modules.insert(0, m);
        design.paths.push(path(
            1,
            0,
            56.0,
            budget,
            PathClassKind::AtomicOverBudget,
            false,
        ));
        let sol = explore_module(
            &design,
            design.modules.get(&0).unwrap(),
            CleanlinessWeights::default(),
        );
        assert_eq!(sol.chosen, AlgoSetId::MulticycleHonest, "{}", sol.rationale);
        assert!(!sol.allows_opportunity(OpportunityKind::InsertReg));
    }

    #[test]
    fn always_ff_only_keeps_clock_aware_factor_set() {
        let mut design = TimingDesign::empty(TimingTarget::new(4000.0, 20.0, 0.2));
        let mut nodes = BTreeMap::new();
        nodes.insert(0, node(0, "state_q", "state_d", 1.0));
        let mut m = empty_module("u_ff", nodes);
        m.regions.insert(0, ff_region(0, vec![0]));
        design.modules.insert(0, m);
        // No primary comb path — sequential NBA is 1 cycle of clk_i.
        let sol = explore_module(
            &design,
            design.modules.get(&0).unwrap(),
            CleanlinessWeights::default(),
        );
        assert_eq!(sol.chosen, AlgoSetId::FfFactorClock, "{}", sol.rationale);
        assert!(sol.timing_pass);
        assert!(sol.always_ff_density > sol.always_comb_density);
        assert!(sol.n_always_ff == 1);
    }

    #[test]
    fn weights_favour_always_blocks_over_aggressiveness() {
        let w = CleanlinessWeights::default();
        let clean = w.score(0.8, 0.8, 0.10, true);
        let dirty = w.score(0.2, 0.2, 0.95, true);
        assert!(clean > dirty, "density must beat aggressiveness: {clean} vs {dirty}");
        let fail = w.score(0.8, 0.8, 0.10, false);
        assert!(clean > fail, "timing fail must penalize: {clean} vs {fail}");
    }

    #[test]
    fn fill_stores_final_cleanliness_per_module() {
        let mut design = TimingDesign::empty(TimingTarget::new(4000.0, 20.0, 0.2));
        let mut nodes = BTreeMap::new();
        nodes.insert(0, node(0, "q", "d", 1.0));
        let mut m = empty_module("u_ff", nodes);
        m.regions.insert(0, ff_region(0, vec![0]));
        design.modules.insert(0, m);
        fill_design_cleanliness(&mut design);
        let sol = design.module_cleanliness.get("u_ff").expect("stored");
        assert_eq!(sol.chosen, AlgoSetId::FfFactorClock);
        assert!(sol.cleanliness.is_finite());
        assert!(!sol.candidates.is_empty());
    }
}
