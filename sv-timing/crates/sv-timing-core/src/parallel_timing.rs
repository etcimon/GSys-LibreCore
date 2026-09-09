// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Parallel-timing scratchboard. Timing basis is structural FO4 (not STA):
//   period_ns = 1000 / f_MHz
//   budget_FO4 B = period_ns * 1000 / fo4_ps * (1 - margin)
// Statement-order IR sums are *not* silicon delay. This board schedules each
// assign/call ASAP on the procedural reference tree (write→read edges) so
// independent ops share a time slot (max), and only true deps serialize (sum).
// Cycle count toward "reference ready" is ceil(makespan / B). Just-in-time
// cuts sit where ASAP completion first crosses k·B on the critical chain.

//! Parallel FO4 scratchboard over [`crate::ref_order::RefOrderTree`].
//!
//! **Timing basis (every formula here):**
//!
//! 1. Node latency `L(s)` = that statement's `fo4_cost` (expr critical path,
//!    already addr-scale-cheapened). A function *call* uses the callee's
//!    recorded makespan when we have one, otherwise `L(s)`.
//! 2. ASAP start `S(s) = max { ready(v) | v ∈ reads(s) ∪ preds(s) }` (0 if none).
//!    Independent writes therefore start together — that is the parallel
//!    inference. A forward write→read edge from the ref-tree *forces* the
//!    consumer to wait; that is the only serialization we trust.
//! 3. Completion `C(s) = S(s) + L(s)`. Variable `v` is **reference-ready** at
//!    `ready(v) = C(writer)`.
//! 4. Makespan `M = max C(s)` is the comb depth of the region.
//! 5. JIT cycles `N = ceil(M / B)` at budget `B`. An InsertReg is justified
//!    only on a zero-slack (critical) op whose `C(s)` crosses a multiple of `B`.
//! 6. ALAP: schedule backward from `M` so unused slack is visible; just-in-time
//!    means a value arrives at the consumer, not earlier than needed.
//!
//! Every **module** gets a [`ModuleParallelTiming`] (all regions + all declared
//! functions). Every **function** name gets a [`FunctionTiming`] so subroutine
//! calls add callee delay instead of treating `$clog2`/`foo()` as free.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::ir::{
    CombRegion, EdgeKind, GateInfo, NodeId, RegionKind, TimingDesign, TimingModule, TimingTarget,
};
use crate::ref_order::RefOrderTree;

/// Clock this scratchboard is scheduled against.
///
/// Comb regions have an empty `clock_name` (pure FO4, no capturing edge).
/// `always_ff` regions bind `clock_name` / `edge` from [`GateInfo`] so cycle
/// bars are **that clock's** period, not a generic unclocked budget. The
/// `sequential` flag stays true even when the clock net is unresolved, so a
/// factorizer / OpenSTA seed never silently treats NBA as combinational.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct ClockDomain {
    /// Clock net (`clk_i`). Empty ⇒ name unresolved (still sequential if
    /// [`Self::sequential`]) or combinational.
    pub clock_name: String,
    /// `posedge` / `negedge` / empty for comb.
    pub edge: String,
    /// Reset net (`rst_ni`) when the sensitivity list has one.
    pub reset_name: String,
    /// Clock period in nanoseconds (`1000 / f_MHz`). 0 for comb.
    pub period_ns: f64,
    /// FO4 budget of **one cycle of this clock** (timing basis \(B\)).
    pub budget_fo4: f64,
    /// True for an `always_ff` capturing edge even if `clock_name` is empty.
    #[serde(default)]
    pub sequential: bool,
}

impl ClockDomain {
    /// Unclocked comb board: still uses the design FO4 budget as \(B\).
    pub fn combinational(budget_fo4: f64) -> Self {
        Self {
            budget_fo4,
            ..Self::default()
        }
    }

    /// Clock-aware board from an `always_ff` gate + design target.
    ///
    /// Timing basis: `period_ns = 1000 / f_MHz`, `B = period_ns * 1000 / fo4_ps * (1-m)`.
    /// Cycle \(k\) is the \(k\)-th capturing edge of `clock_name` after reset.
    pub fn from_gate(gate: &GateInfo, target: &TimingTarget) -> Self {
        let edge = match gate.edge {
            Some(EdgeKind::Posedge) => "posedge",
            Some(EdgeKind::Negedge) => "negedge",
            Some(EdgeKind::Level) => "level",
            None => "posedge",
        };
        Self {
            clock_name: gate.clock_name.clone().unwrap_or_default(),
            edge: edge.into(),
            reset_name: gate.reset_name.clone().unwrap_or_default(),
            period_ns: if target.target_mhz > 0.0 {
                1000.0 / target.target_mhz
            } else {
                0.0
            },
            budget_fo4: target.budget_fo4,
            sequential: true,
        }
    }

    /// True when this board is bound to a capturing clock edge.
    ///
    /// Name-unresolved `always_ff` still counts: cycle bars use `period_ns` /
    /// `budget_fo4` of the design target, not a combinational FO4 counter.
    pub fn is_sequential(&self) -> bool {
        self.sequential || !self.clock_name.is_empty()
    }

    /// Map key for [`ModuleParallelTiming::clocks`] (`clk_i`, or `#ff{id}`).
    pub fn map_key(&self, region_id: u32) -> String {
        if self.clock_name.is_empty() {
            format!("#ff{region_id}")
        } else {
            self.clock_name.clone()
        }
    }
}

/// One scheduled statement on the scratchboard.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ScratchOp {
    /// Procedural statement index (same as [`crate::ref_order::RefEvent::stmt_ord`]).
    pub stmt_ord: u32,
    /// IR node.
    pub node_id: NodeId,
    /// ASAP start FO4 (max of producer completions).
    pub asap_start: f64,
    /// Statement latency FO4 (`L(s)`).
    pub latency_fo4: f64,
    /// ASAP completion FO4 (`C(s)`).
    pub asap_end: f64,
    /// ALAP start FO4 (as late as possible without growing makespan).
    pub alap_start: f64,
    /// Slack FO4 = ALAP start − ASAP start. Zero ⇒ critical; >0 ⇒ can wait (JIT).
    pub slack_fo4: f64,
    /// Earliest integer cycle this op is ready (`ceil(asap_end / B)`, 1-indexed).
    /// For `always_ff` this is a cycle of [`ClockDomain::clock_name`], not a
    /// free-running FO4 counter.
    pub ready_cycle: u32,
}

/// Per-function (subroutine) timing tracked for every declared / called name.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct FunctionTiming {
    /// Function / system-function name (`$clog2`, `foo`, …).
    pub name: String,
    /// How many times it is invoked in this module.
    pub call_count: u32,
    /// Parameter / localparam uses at call sites (`WIDTH` → n).
    pub param_uses: BTreeMap<String, u32>,
    /// Structural FO4 charged per call (callee makespan if known, else site `L`).
    pub latency_fo4: f64,
    /// Cycle slot of the latest invocation (`ceil(ready / B)`).
    pub ready_cycle: u32,
}

/// Per-module parallel-timing board (every region + every function).
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct ModuleParallelTiming {
    /// Module name.
    pub module: String,
    /// Makespan FO4 of the worst region in the module (`max M`).
    pub makespan_fo4: f64,
    /// JIT stages to close the worst region at the current budget.
    pub cycle_count: u32,
    /// Per-region scratchboards (full board, including [`ParallelScratch::clock`]).
    /// `always_ff` entries stay sequential; comb entries have an empty clock name.
    pub regions: BTreeMap<u32, ParallelScratch>,
    /// When each variable becomes reference-ready (FO4 from t=0).
    pub var_ready_fo4: BTreeMap<String, f64>,
    /// Timing for every function declared *or* called in this module.
    pub functions: BTreeMap<String, FunctionTiming>,
    /// True when every region's ref-tree is procedurally well-ordered.
    pub procedural_ok: bool,
    /// Clock-aware domains keyed by clock name (always_ff regions).
    /// The per-region source of truth is `regions[id].clock`.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub clocks: BTreeMap<String, ClockDomain>,
}

/// Path-local scratchboard used by classifiers and JIT cut selection.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct ParallelScratch {
    /// Scheduled ops in statement order.
    pub ops: Vec<ScratchOp>,
    /// Comb depth FO4 (timing basis §4).
    pub makespan_fo4: f64,
    /// `ceil(makespan / budget)` — cycles until the endpoint is reference-ready.
    pub cycle_count: u32,
    /// Variable → FO4 when the last write completes.
    pub var_ready_fo4: BTreeMap<String, f64>,
    /// Function timing observed on this path (subset of the module board).
    pub functions: BTreeMap<String, FunctionTiming>,
    /// Forward-edge count from the ref-tree (0 ⇒ fully parallel).
    pub dep_edges: u32,
    /// Ref-tree procedural assertion.
    pub procedural_ok: bool,
    /// Clock this board is scheduled on (empty clock_name ⇒ comb).
    /// `always_ff` boards **keep** a sequential [`ClockDomain`] here; do not
    /// replace this with [`ClockDomain::combinational`] after scheduling.
    #[serde(default)]
    pub clock: ClockDomain,
}

impl ModuleParallelTiming {
    /// Store a region's scratchboard and keep its clock if sequential.
    ///
    /// Timing basis: `always_ff` cycle bars stay on `scratch.clock` (name,
    /// edge, period, \(B\)). Comb boards are stored too, but are not entered
    /// in [`Self::clocks`]. `merge_functions` is true on the first fill pass
    /// only so a second callee-latency reschedule does not double call counts.
    pub fn keep_region_scratch(
        &mut self,
        region_id: u32,
        scratch: ParallelScratch,
        merge_functions: bool,
    ) {
        self.makespan_fo4 = self.makespan_fo4.max(scratch.makespan_fo4);
        self.procedural_ok &= scratch.procedural_ok;
        self.cycle_count = self.cycle_count.max(scratch.cycle_count).max(1);
        if scratch.clock.is_sequential() {
            self.clocks
                .insert(scratch.clock.map_key(region_id), scratch.clock.clone());
        }
        for (v, t) in &scratch.var_ready_fo4 {
            let e = self.var_ready_fo4.entry(v.clone()).or_insert(0.0);
            *e = e.max(*t);
        }
        if merge_functions {
            for (fname, ft) in &scratch.functions {
                let slot = self.functions.entry(fname.clone()).or_default();
                if slot.name.is_empty() {
                    slot.name = ft.name.clone();
                }
                slot.call_count += ft.call_count;
                slot.latency_fo4 = slot.latency_fo4.max(ft.latency_fo4);
                slot.ready_cycle = slot.ready_cycle.max(ft.ready_cycle);
                for (p, n) in &ft.param_uses {
                    *slot.param_uses.entry(p.clone()).or_insert(0) += *n;
                }
            }
        }
        self.regions.insert(region_id, scratch);
    }

    /// Clock-aware scratch for one region, if fill kept it.
    pub fn scratch_for_region(&self, region_id: u32) -> Option<&ParallelScratch> {
        self.regions.get(&region_id)
    }
}

impl ParallelScratch {
    /// ASAP + ALAP schedule of `nodes` using the procedural reference tree.
    ///
    /// `budget_fo4` is `TimingTarget.budget_fo4` (timing basis §5). Zero/negative
    /// budget is treated as 1 FO4 so cycle counts stay defined.
    pub fn schedule(
        module: &TimingModule,
        nodes: &[NodeId],
        budget_fo4: f64,
        callee_latency: &BTreeMap<String, f64>,
    ) -> Self {
        let tree = RefOrderTree::from_nodes(module, nodes);
        let b = budget_fo4.max(1.0);
        let n = nodes.len();
        if n == 0 {
            return Self {
                procedural_ok: tree.procedural_ok,
                ..Self::default()
            };
        }

        // --- ASAP (timing basis §2–§3) ------------------------------------
        // preds[s] = statements that must complete before s may start.
        let mut preds: BTreeMap<u32, Vec<u32>> = BTreeMap::new();
        for e in &tree.edges {
            preds.entry(e.to_stmt).or_default().push(e.from_stmt);
        }
        let mut latency = vec![0.0f64; n];
        let mut functions: BTreeMap<String, FunctionTiming> = BTreeMap::new();
        for (i, nid) in nodes.iter().copied().enumerate() {
            let node_l = module
                .nodes
                .get(&nid)
                .map(|nd| nd.fo4_cost.max(0.0))
                .unwrap_or(0.0);
            // Subroutine: if this statement contains a call, charge the callee's
            // known makespan when we have one (module/function board), else the
            // site's own FO4. Never treat a call as zero-delay.
            let mut call_l = 0.0f64;
            if let Some(nd) = module.nodes.get(&nid) {
                if let Some(ref ex) = nd.rhs_expr {
                    ex.walk_calls(&mut |cname, _args| {
                        let lat = callee_latency.get(cname).copied().unwrap_or(node_l);
                        call_l = call_l.max(lat);
                        let ft = functions.entry(cname.to_string()).or_default();
                        ft.name = cname.to_string();
                        ft.call_count += 1;
                        ft.latency_fo4 = ft.latency_fo4.max(lat);
                    });
                }
            }
            // Merge call param-uses from the ref-tree (already counted).
            for (cname, cc) in &tree.calls {
                if let Some(ft) = functions.get_mut(cname) {
                    for (p, n) in &cc.param_uses {
                        *ft.param_uses.entry(p.clone()).or_insert(0) += *n;
                    }
                }
            }
            latency[i] = node_l.max(call_l);
        }

        let mut asap_start = vec![0.0f64; n];
        let mut asap_end = vec![0.0f64; n];
        for i in 0..n {
            let s = i as u32;
            let start = preds
                .get(&s)
                .map(|ps| {
                    ps.iter()
                        .map(|&p| asap_end.get(p as usize).copied().unwrap_or(0.0))
                        .fold(0.0f64, f64::max)
                })
                .unwrap_or(0.0);
            asap_start[i] = start;
            asap_end[i] = start + latency[i];
        }
        let makespan = asap_end.iter().copied().fold(0.0f64, f64::max);

        // --- ALAP (timing basis §6, just-in-time) -------------------------
        // An op may start as late as (min consumer start) − L, or makespan − L
        // if it is an endpoint (write-only / no forward consumer).
        let mut succs: BTreeMap<u32, Vec<u32>> = BTreeMap::new();
        for e in &tree.edges {
            succs.entry(e.from_stmt).or_default().push(e.to_stmt);
        }
        let mut alap_start = vec![0.0f64; n];
        for i in (0..n).rev() {
            let s = i as u32;
            let latest_end = succs
                .get(&s)
                .map(|cs| {
                    cs.iter()
                        .map(|&c| alap_start.get(c as usize).copied().unwrap_or(makespan))
                        .fold(makespan, f64::min)
                })
                .unwrap_or(makespan);
            alap_start[i] = (latest_end - latency[i]).max(0.0);
        }

        let mut var_ready_fo4: BTreeMap<String, f64> = BTreeMap::new();
        let mut ops = Vec::with_capacity(n);
        for (i, nid) in nodes.iter().copied().enumerate() {
            let slack = (alap_start[i] - asap_start[i]).max(0.0);
            let ready_cycle = (asap_end[i] / b).ceil().max(1.0) as u32;
            if let Some(nd) = module.nodes.get(&nid) {
                if let Some(ref lhs) = nd.lhs {
                    let base = crate::ref_order::ident_base(lhs);
                    let e = var_ready_fo4.entry(base).or_insert(0.0);
                    *e = e.max(asap_end[i]);
                }
            }
            ops.push(ScratchOp {
                stmt_ord: i as u32,
                node_id: nid,
                asap_start: asap_start[i],
                latency_fo4: latency[i],
                asap_end: asap_end[i],
                alap_start: alap_start[i],
                slack_fo4: slack,
                ready_cycle,
            });
        }
        for ft in functions.values_mut() {
            ft.ready_cycle = (makespan / b).ceil().max(1.0) as u32;
        }

        Self {
            ops,
            makespan_fo4: makespan,
            cycle_count: (makespan / b).ceil().max(1.0) as u32,
            var_ready_fo4,
            functions,
            dep_edges: tree.edges.len() as u32,
            procedural_ok: tree.procedural_ok,
            clock: ClockDomain::combinational(b),
        }
    }

    /// Clock-aware schedule for one IR region.
    ///
    /// `always_ff`: cycle bars are edges of `gate.clock_name` at `target` period.
    /// The sequential [`ClockDomain`] is **kept** on the returned board.
    /// `always_comb` / `assign`: combinational board (same FO4 budget, no edge).
    pub fn schedule_for_region(
        module: &TimingModule,
        region: &CombRegion,
        target: &TimingTarget,
        callee_latency: &BTreeMap<String, f64>,
    ) -> Self {
        let mut s = Self::schedule(module, &region.nodes, target.budget_fo4, callee_latency);
        if region.kind == RegionKind::AlwaysFf {
            s.bind_always_ff_clock(&region.gate, target);
        }
        s
    }

    /// Bind (or re-bind) this board to an `always_ff` capturing edge.
    ///
    /// Ops / makespan stay; `ready_cycle` and `cycle_count` are restamped
    /// against **this clock's** \(B\). Call this whenever a combinational
    /// [`Self::schedule`] was used on NBA by mistake — the clock must stay.
    pub fn bind_always_ff_clock(&mut self, gate: &GateInfo, target: &TimingTarget) {
        self.clock = ClockDomain::from_gate(gate, target);
        self.procedural_ok &= self.dep_edges == 0;
        let b = self.clock.budget_fo4.max(1.0);
        for op in &mut self.ops {
            op.ready_cycle = (op.asap_end / b).ceil().max(1.0) as u32;
        }
        self.cycle_count = (self.makespan_fo4 / b).ceil().max(1.0) as u32;
    }

    /// Just-in-time InsertReg sites: critical ops (`slack ≈ 0`) whose ASAP end
    /// first crosses `k * budget` (timing basis §5). Each returned node is the
    /// statement *after which* a flop captures a value that would otherwise
    /// miss the next cycle boundary.
    pub fn jit_cuts(&self, budget_fo4: f64) -> Vec<NodeId> {
        if !self.procedural_ok {
            return Vec::new();
        }
        let b = budget_fo4.max(1.0);
        let mut cuts = Vec::new();
        let mut next_bar = b;
        for op in &self.ops {
            if op.slack_fo4 > 1e-6 {
                continue; // not critical — can wait (JIT slack)
            }
            if op.asap_end + 1e-9 >= next_bar && op.asap_start + 1e-9 < next_bar {
                cuts.push(op.node_id);
                next_bar += b;
            }
        }
        cuts
    }

    /// JIT cuts against **this board's clock** \(B\) (always_ff period, or
    /// the combinational design budget). Prefer this over a caller-supplied
    /// generic budget so sequential scratches stay clock-aware.
    pub fn jit_cuts_on_clock(&self) -> Vec<NodeId> {
        self.jit_cuts(self.clock.budget_fo4.max(1.0))
    }
}

/// Fill [`TimingDesign::parallel_timing`] for **every module** and **every
/// function** (declared names get a zero-call stub so the board is total).
///
/// Walks **IR regions first** so an `always_ff` with no extracted `TimingPath`
/// still keeps a clock-aware [`ParallelScratch`]. Paths whose `region_id` is
/// already filled never replace that sequential board with a combinational
/// `schedule` of `path.nodes`.
pub fn fill_design_parallel_timing(design: &mut TimingDesign) {
    let budget = design.target.budget_fo4;
    let empty_callees = BTreeMap::new();
    let mut boards: BTreeMap<String, ModuleParallelTiming> = BTreeMap::new();
    let mut fn_latency: BTreeMap<String, f64> = BTreeMap::new();

    for (mid, module) in &design.modules {
        let mut board = ModuleParallelTiming {
            module: module.name.clone(),
            procedural_ok: true,
            ..ModuleParallelTiming::default()
        };
        // Every declared function starts on the board (call_count 0 until seen).
        for fname in &module.functions {
            board.functions.insert(
                fname.clone(),
                FunctionTiming {
                    name: fname.clone(),
                    ..FunctionTiming::default()
                },
            );
        }
        // Region-first: keep clock-aware always_ff scratches even without a path.
        for (rid, region) in &module.regions {
            let scratch = ParallelScratch::schedule_for_region(
                module,
                region,
                &design.target,
                &empty_callees,
            );
            for (fname, ft) in &scratch.functions {
                fn_latency.insert(fname.clone(), ft.latency_fo4);
            }
            board.keep_region_scratch(*rid, scratch, true);
        }
        // Synthetic / path-only boards. Never overwrite a kept always_ff scratch.
        for path in design.paths.iter().filter(|p| p.module == *mid) {
            if board.regions.contains_key(&path.region_id) {
                continue;
            }
            let scratch =
                ParallelScratch::schedule(module, &path.nodes, budget, &empty_callees);
            for (fname, ft) in &scratch.functions {
                fn_latency.insert(fname.clone(), ft.latency_fo4);
            }
            board.keep_region_scratch(path.region_id, scratch, true);
        }
        if board.cycle_count == 0 {
            board.cycle_count = 1;
        }
        boards.insert(module.name.clone(), board);
    }

    // Second pass: re-schedule with callee latencies so a function call in
    // module A that targets a timed function in module B (or the same module)
    // charges the callee makespan. Structural only — not a call-graph STA.
    // Clock binding is reapplied via schedule_for_region so always_ff stays
    // sequential after the reschedule.
    if !fn_latency.is_empty() {
        for (mid, module) in &design.modules {
            let Some(board) = boards.get_mut(&module.name) else {
                continue;
            };
            for (rid, region) in &module.regions {
                let scratch = ParallelScratch::schedule_for_region(
                    module,
                    region,
                    &design.target,
                    &fn_latency,
                );
                board.keep_region_scratch(*rid, scratch, false);
            }
            for path in design.paths.iter().filter(|p| p.module == *mid) {
                if module.regions.contains_key(&path.region_id) {
                    continue;
                }
                let scratch =
                    ParallelScratch::schedule(module, &path.nodes, budget, &fn_latency);
                board.keep_region_scratch(path.region_id, scratch, false);
            }
        }
    }

    design.parallel_timing = boards;
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::expr::Expr;
    use crate::ir::{
        CombRegion, EdgeKind, GateInfo, IrNode, OperatorClass, RegionKind, TimingModule,
        TimingTarget,
    };
    use crate::loc::{OriginKind, SourceLoc};
    use std::collections::BTreeMap as Map;

    fn loc() -> SourceLoc {
        SourceLoc {
            file: "t.sv".into(),
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
            assign_kind: Default::default(),
        }
    }

    fn module_with(nodes: Map<u32, IrNode>) -> TimingModule {
        TimingModule {
            id: 0,
            name: "m".into(),
            file: "m.sv".into(),
            nodes,
            regions: Map::new(),
            localparams: vec![],
            parameters: vec![],
            ports: vec![],
            gen_loops: vec![],
            functions: vec!["foo".into()],
            package_imports: vec![],
            instances: vec![],
            loc: loc(),
        }
    }

    fn lower_sequential_body(body: &str) -> TimingDesign {
        let text = format!(
            "module sequential_test(input logic clk_i, input logic [31:0] d, a, b, c, output logic [31:0] q, r);\nlogic [31:0] t;\nalways_ff @(posedge clk_i) begin\n{body}\nend\nendmodule\n"
        );
        let path = std::path::PathBuf::from("sequential_test.sv");
        let defines: sv_parser::Defines = Default::default();
        let (tree, _) = sv_parser::parse_sv_str(
            &text,
            &path,
            &defines,
            &[] as &[std::path::PathBuf],
            false,
            false,
        )
        .expect("parse sequential source");
        let file = crate::parse::ParsedFile {
            path: path.clone(),
            bytes: text.as_bytes().to_vec(),
            line_index: crate::loc::LineIndex::from_bytes(path, text.as_bytes()),
            tree,
        };
        crate::lower::lower_unit(
            &crate::parse::ParsedUnit {
                files: vec![file],
                skipped: vec![],
            },
            &crate::lower::LowerOptions {
                target: TimingTarget::new(4000.0, 20.0, 0.2),
                ..crate::lower::LowerOptions::default()
            },
        )
        .expect("lower sequential source")
        .design
    }

    #[test]
    fn lowered_nba_q_read_is_not_a_combo_edge() {
        // `q <= d + a; r <= q + b;` — second NBA reads Q (IEEE NBA schedule).
        let nba = lower_sequential_body("q <= d + a;\nr <= q + b;");
        let blocking = lower_sequential_body("q  = d + a;\nr <= q + b;");
        let nba_module = nba.modules.values().next().unwrap();
        let blocking_module = blocking.modules.values().next().unwrap();
        let nba_q = nba_module
            .nodes
            .values()
            .find(|n| n.lhs.as_deref() == Some("q"))
            .unwrap();
        let blocking_q = blocking_module
            .nodes
            .values()
            .find(|n| n.lhs.as_deref() == Some("q"))
            .unwrap();
        assert_eq!(nba_q.assign_kind, crate::ir::AssignKind::Nonblocking);
        assert_eq!(blocking_q.assign_kind, crate::ir::AssignKind::Blocking);
        let nba_region = nba_module
            .regions
            .values()
            .find(|r| r.kind == RegionKind::AlwaysFf)
            .unwrap();
        let nba_scratch = ParallelScratch::schedule_for_region(
            nba_module,
            nba_region,
            &nba.target,
            &BTreeMap::new(),
        );
        assert!(nba_scratch.clock.is_sequential());
        assert_eq!(nba_scratch.dep_edges, 0);
        assert!(nba_scratch.procedural_ok);
        let blocking_region = blocking_module
            .regions
            .values()
            .find(|r| r.kind == RegionKind::AlwaysFf)
            .unwrap();
        let blocking_scratch = ParallelScratch::schedule_for_region(
            blocking_module,
            blocking_region,
            &blocking.target,
            &BTreeMap::new(),
        );
        assert!(blocking_scratch.dep_edges > 0);
    }

    #[test]
    fn lowered_blocking_temporary_dependency_is_preserved_when_sequential_kind_is_unknown() {
        let design = lower_sequential_body("t = d + a;\nq <= t;");
        let module = design.modules.values().next().unwrap();
        let region = module
            .regions
            .values()
            .find(|r| r.kind == RegionKind::AlwaysFf)
            .unwrap();
        let scratch = ParallelScratch::schedule_for_region(
            module,
            region,
            &design.target,
            &BTreeMap::new(),
        );
        let consumer = scratch
            .ops
            .iter()
            .find(|op| module.nodes[&op.node_id].lhs.as_deref() == Some("q"))
            .unwrap();
        assert!(scratch.dep_edges > 0);
        assert!(consumer.asap_start > 0.0, "blocking temporary must still chain");
        assert!(!scratch.procedural_ok);
        assert!(scratch.jit_cuts_on_clock().is_empty());
    }

    #[test]
    fn lowered_independent_nba_assignments_remain_parallel() {
        let design = lower_sequential_body("q <= d + a;\nr <= b + c;");
        let module = design.modules.values().next().unwrap();
        let region = module
            .regions
            .values()
            .find(|r| r.kind == RegionKind::AlwaysFf)
            .unwrap();
        let scratch = ParallelScratch::schedule_for_region(
            module,
            region,
            &design.target,
            &BTreeMap::new(),
        );
        assert!(scratch.clock.is_sequential());
        assert!(scratch.procedural_ok);
        assert_eq!(scratch.dep_edges, 0);
        assert!(scratch.ops.iter().all(|op| op.asap_start == 0.0));
    }

    #[test]
    fn binding_sequential_clock_refuses_ambiguous_ir_dependencies_without_erasing_them() {
        let mut nodes = Map::new();
        nodes.insert(0, node(0, "t", "d + a", 10.0));
        nodes.insert(1, node(1, "q", "t + b", 10.0));
        let module = module_with(nodes);
        let target = TimingTarget::new(4000.0, 20.0, 0.2);
        let mut scratch = ParallelScratch::schedule(
            &module,
            &[0, 1],
            target.budget_fo4,
            &BTreeMap::new(),
        );
        assert!(scratch.procedural_ok);
        assert_eq!(scratch.dep_edges, 1);
        assert_eq!(scratch.makespan_fo4, 20.0);
        assert_eq!(scratch.ops[1].asap_start, 10.0);
        assert!(!scratch.jit_cuts(target.budget_fo4).is_empty());
        let gate = GateInfo {
            clock_name: Some("clk_i".into()),
            edge: Some(EdgeKind::Posedge),
            is_comb: false,
            ..GateInfo::default()
        };
        scratch.bind_always_ff_clock(&gate, &target);
        assert!(scratch.clock.is_sequential());
        assert!(!scratch.procedural_ok);
        assert_eq!(scratch.dep_edges, 1);
        assert_eq!(scratch.makespan_fo4, 20.0);
        assert_eq!(scratch.ops[1].asap_start, 10.0);
        assert!(scratch.jit_cuts_on_clock().is_empty());
    }

    #[test]
    fn parallel_writes_share_time_slot() {
        // Timing basis: two independent 10-FO4 assigns → makespan 10, not 20.
        let mut nodes = Map::new();
        nodes.insert(0, node(0, "a_d", "x + 1", 10.0));
        nodes.insert(1, node(1, "b_d", "y + 1", 10.0));
        let m = module_with(nodes);
        let s = ParallelScratch::schedule(&m, &[0, 1], 10.0, &BTreeMap::new());
        assert!(
            (s.makespan_fo4 - 10.0).abs() < 1e-6,
            "makespan={}",
            s.makespan_fo4
        );
        assert_eq!(s.cycle_count, 1);
        assert_eq!(s.dep_edges, 0);
        assert!(s.jit_cuts(10.0).is_empty() || s.ops.iter().any(|o| o.ready_cycle == 1));
    }

    #[test]
    fn forward_read_serializes_and_needs_two_cycles() {
        // Timing basis: tmp then y = tmp + c, each 10 FO4, B=10 → N=2 JIT stages.
        let mut nodes = Map::new();
        nodes.insert(0, node(0, "tmp", "a + b", 10.0));
        nodes.insert(1, node(1, "y", "tmp + c", 10.0));
        let m = module_with(nodes);
        let s = ParallelScratch::schedule(&m, &[0, 1], 10.0, &BTreeMap::new());
        assert!(
            (s.makespan_fo4 - 20.0).abs() < 1e-6,
            "makespan={}",
            s.makespan_fo4
        );
        assert_eq!(s.cycle_count, 2);
        assert_eq!(s.dep_edges, 1);
        let cuts = s.jit_cuts(10.0);
        assert!(!cuts.is_empty(), "chain over budget must JIT-cut");
        let _ = TimingTarget::new(4000.0, 20.0, 0.2);
    }

    #[test]
    fn fill_design_tracks_every_module_and_function() {
        let mut design = TimingDesign::empty(TimingTarget::new(4000.0, 20.0, 0.2));
        let mut nodes = Map::new();
        nodes.insert(0, node(0, "y", "foo(WIDTH) + 1", 4.0));
        let mut m = module_with(nodes);
        m.functions = vec!["foo".into(), "bar".into()];
        design.modules.insert(0, m);
        design.module_names.insert("m".into(), 0);
        design.paths.push(crate::ir::TimingPath {
            id: 1,
            region_id: 0,
            module: 0,
            start: crate::ir::PathEndpoint::InputPort { module: 0, port: 0 },
            end: crate::ir::PathEndpoint::OutputPort { module: 0, port: 1 },
            path_kind: crate::ir::PathKind::InToOut,
            startpoint: "m.in0".into(),
            endpoint: "m.out0".into(),
            nodes: vec![0],
            total_fo4: 4.0,
            slack_fo4: 6.0,
            max_freq_mhz: 4000.0,
            primary_loc: loc(),
            multi_cycle: false,
            path_class: crate::path_class::PathClassKind::Plain,
            total_fo4_raw: None,
            class_note: None,
        });
        fill_design_parallel_timing(&mut design);
        let board = design.parallel_timing.get("m").expect("module board");
        assert!(
            board.functions.contains_key("foo") && board.functions.contains_key("bar"),
            "every declared function must be on the board: {:?}",
            board.functions.keys().collect::<Vec<_>>()
        );
        assert!(board.cycle_count >= 1);
        assert!(board.makespan_fo4 >= 0.0);
    }

    #[test]
    fn always_ff_scratch_is_clock_aware() {
        let mut nodes = Map::new();
        nodes.insert(0, node(0, "state_q", "state_d", 1.0));
        nodes.insert(1, node(1, "cnt_q", "cnt_d", 1.0));
        let mut m = module_with(nodes);
        let mut gate = GateInfo {
            is_comb: false,
            ..GateInfo::default()
        };
        gate.clock_name = Some("clk_i".into());
        gate.edge = Some(EdgeKind::Posedge);
        gate.reset_name = Some("rst_ni".into());
        m.regions.insert(
            0,
            CombRegion {
                id: 0,
                module: 0,
                kind: RegionKind::AlwaysFf,
                label: None,
                gate,
                nodes: vec![0, 1],
                total_fo4: 2.0,
                loc_span: loc(),
                multi_cycle: false,
            },
        );
        let target = TimingTarget::new(4000.0, 20.0, 0.2);
        let s = ParallelScratch::schedule_for_region(
            &m,
            m.regions.get(&0).unwrap(),
            &target,
            &BTreeMap::new(),
        );
        assert!(s.clock.is_sequential(), "always_ff must bind a clock");
        assert!(s.clock.sequential);
        assert_eq!(s.clock.clock_name, "clk_i");
        assert_eq!(s.clock.edge, "posedge");
        assert!((s.clock.period_ns - 0.25).abs() < 1e-9, "4 GHz → 0.25 ns");
        assert!(s.clock.budget_fo4 > 0.0);
        assert!(s.ops.iter().all(|o| o.ready_cycle >= 1));
        // Combinational schedule of the same nodes must NOT be used as the
        // kept always_ff board — re-bind keeps the clock.
        let mut comb = ParallelScratch::schedule(&m, &[0, 1], target.budget_fo4, &BTreeMap::new());
        assert!(!comb.clock.is_sequential());
        comb.bind_always_ff_clock(&m.regions[&0].gate, &target);
        assert!(comb.clock.is_sequential());
        assert_eq!(comb.clock.clock_name, "clk_i");
    }

    #[test]
    fn fill_design_keeps_always_ff_scratch_without_path() {
        // NBA-only always_ff (no TimingPath) still gets a clock-aware board.
        let mut design = TimingDesign::empty(TimingTarget::new(4000.0, 20.0, 0.2));
        let mut nodes = Map::new();
        nodes.insert(0, node(0, "state_q", "state_d", 1.0));
        let mut m = module_with(nodes);
        let mut gate = GateInfo {
            is_comb: false,
            ..GateInfo::default()
        };
        gate.clock_name = Some("clk_i".into());
        gate.edge = Some(EdgeKind::Posedge);
        gate.reset_name = Some("rst_ni".into());
        m.regions.insert(
            0,
            CombRegion {
                id: 0,
                module: 0,
                kind: RegionKind::AlwaysFf,
                label: None,
                gate,
                nodes: vec![0],
                total_fo4: 1.0,
                loc_span: loc(),
                multi_cycle: false,
            },
        );
        design.modules.insert(0, m);
        design.module_names.insert("m".into(), 0);
        fill_design_parallel_timing(&mut design);
        let board = design.parallel_timing.get("m").expect("module board");
        let scratch = board
            .scratch_for_region(0)
            .expect("always_ff region scratch must be kept");
        assert!(
            scratch.clock.is_sequential(),
            "kept always_ff scratch must stay clock-aware: {:?}",
            scratch.clock
        );
        assert_eq!(scratch.clock.clock_name, "clk_i");
        assert_eq!(scratch.clock.edge, "posedge");
        assert!(board.clocks.contains_key("clk_i"));
        assert!(!scratch.ops.is_empty());
    }

    #[test]
    fn fill_does_not_replace_always_ff_scratch_with_path_schedule() {
        // A TimingPath on the same region_id must not demote the sequential board.
        let mut design = TimingDesign::empty(TimingTarget::new(4000.0, 20.0, 0.2));
        let mut nodes = Map::new();
        nodes.insert(0, node(0, "q", "d", 1.0));
        let mut m = module_with(nodes);
        let mut gate = GateInfo {
            is_comb: false,
            ..GateInfo::default()
        };
        gate.clock_name = Some("clk_j".into());
        gate.edge = Some(EdgeKind::Negedge);
        m.regions.insert(
            7,
            CombRegion {
                id: 7,
                module: 0,
                kind: RegionKind::AlwaysFf,
                label: None,
                gate,
                nodes: vec![0],
                total_fo4: 1.0,
                loc_span: loc(),
                multi_cycle: false,
            },
        );
        design.modules.insert(0, m);
        design.module_names.insert("m".into(), 0);
        design.paths.push(crate::ir::TimingPath {
            id: 1,
            region_id: 7,
            module: 0,
            start: crate::ir::PathEndpoint::InputPort { module: 0, port: 0 },
            end: crate::ir::PathEndpoint::OutputPort { module: 0, port: 1 },
            path_kind: crate::ir::PathKind::InToOut,
            startpoint: "m.d".into(),
            endpoint: "m.q".into(),
            nodes: vec![0],
            total_fo4: 1.0,
            slack_fo4: 9.0,
            max_freq_mhz: 4000.0,
            primary_loc: loc(),
            multi_cycle: false,
            path_class: crate::path_class::PathClassKind::Plain,
            total_fo4_raw: None,
            class_note: None,
        });
        fill_design_parallel_timing(&mut design);
        let board = design.parallel_timing.get("m").unwrap();
        let s = board.scratch_for_region(7).unwrap();
        assert!(s.clock.is_sequential());
        assert_eq!(s.clock.clock_name, "clk_j");
        assert_eq!(s.clock.edge, "negedge");
        assert!(board.clocks.contains_key("clk_j"));
        assert!(!board.clocks.contains_key("clk_i"));
    }

    #[test]
    fn unnamed_always_ff_clock_still_sequential() {
        let mut nodes = Map::new();
        nodes.insert(0, node(0, "q", "d", 1.0));
        let mut m = module_with(nodes);
        let gate = GateInfo {
            is_comb: false,
            ..GateInfo::default()
        };
        m.regions.insert(
            0,
            CombRegion {
                id: 0,
                module: 0,
                kind: RegionKind::AlwaysFf,
                label: None,
                gate,
                nodes: vec![0],
                total_fo4: 1.0,
                loc_span: loc(),
                multi_cycle: false,
            },
        );
        let target = TimingTarget::new(4000.0, 20.0, 0.2);
        let s = ParallelScratch::schedule_for_region(
            &m,
            m.regions.get(&0).unwrap(),
            &target,
            &BTreeMap::new(),
        );
        assert!(
            s.clock.is_sequential(),
            "unresolved clock name must not demote always_ff to comb"
        );
        assert!(s.clock.sequential);
        assert!((s.clock.period_ns - 0.25).abs() < 1e-9);
    }
}
