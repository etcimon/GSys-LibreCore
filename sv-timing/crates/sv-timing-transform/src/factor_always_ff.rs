// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// always_ff factorizer. Timing basis (clock-aware ParallelScratch):
//   period_ns = 1000 / f_MHz of THIS capturing clock
//   B = period_ns * 1000 / fo4_ps * (1 - margin)
//   ready_cycle k = k-th posedge/negedge of clock_name after reset
// Independent NBA (no write→read edge) share cycle 1. Forward deps serialize
// onto later edges of the same clock. Emit is review-only comments + optional
// staged always_ff template for OpenSTA report_timing -from/-to seeds.

//! Factor `always_ff` processes by ParallelScratch cycle counts on **their** clock.

use std::collections::BTreeMap;

use sv_timing_core::{
    CombRegion, ModuleParallelTiming, ParallelScratch, RegionKind, TimingTarget,
};

use crate::edit::{EditKind, EditRecord};
use crate::pass::PassContext;

/// Annotate / factor every `always_ff` region on the allowlist.
///
/// Does **not** rewrite the original process body. It records an `Annotate`
/// edit whose `emit_snippet` is a commented staging plan OpenSTA can check:
/// `create_clock` seed + `report_timing -from <clk> -to <q>` per capture.
///
/// The region's clock-aware [`ParallelScratch`] is **kept** on
/// `design.parallel_timing` (reused if fill already stored it, re-bound if a
/// combinational board leaked in).
pub fn factor_always_ff_regions(ctx: &mut PassContext) {
    let target = ctx.design.target.clone();
    let allow = ctx.policy.correct_allow_modules.clone();
    let empty = BTreeMap::new();
    let mut pending: Vec<(
        String,
        u32,
        sv_timing_core::SourceLoc,
        Option<String>,
        ParallelScratch,
    )> = Vec::new();

    for module in ctx.design.modules.values() {
        if !allow.is_empty() && !allow.iter().any(|a| a == &module.name || a == "*") {
            continue;
        }
        for region in module.regions.values() {
            if region.kind != RegionKind::AlwaysFf {
                continue;
            }
            // Prefer the kept clock-aware board; never schedule combinational
            // `path.nodes` over an always_ff region.
            let mut scratch = ctx
                .design
                .parallel_timing
                .get(&module.name)
                .and_then(|b| b.scratch_for_region(region.id))
                .cloned()
                .unwrap_or_else(|| {
                    ParallelScratch::schedule_for_region(module, region, &target, &empty)
                });
            if !scratch.clock.is_sequential() {
                scratch.bind_always_ff_clock(&region.gate, &target);
            }
            let sv = scratch
                .procedural_ok
                .then(|| render_factor_sv(module.name.as_str(), region, &scratch, &target));
            pending.push((
                module.name.clone(),
                region.id,
                region.loc_span.clone(),
                sv,
                scratch,
            ));
        }
    }

    for (mod_name, rid, origin, sv, scratch) in pending {
        let m = scratch.makespan_fo4;
        let board = ctx
            .design
            .parallel_timing
            .entry(mod_name.clone())
            .or_insert_with(|| ModuleParallelTiming {
                module: mod_name,
                procedural_ok: true,
                ..ModuleParallelTiming::default()
            });
        board.keep_region_scratch(rid, scratch, false);
        let Some(sv) = sv else {
            continue;
        };
        ctx.trace.record_edit(EditRecord {
            id: 0,
            kind: EditKind::Annotate,
            origin,
            path_id: None,
            node_id: None,
            new_name: None,
            fo4_before: Some(m),
            fo4_after: Some(m),
            rationale: "always_ff factorize (clock-aware ParallelScratch; OpenSTA order expect)"
                .into(),
            emit_rhs: None,
            emit_rhs_extras: Vec::new(),
            emit_snippet: Some(sv),
        });
    }
}

/// Commented SV: timing basis, per-LHS ready_cycle, OpenSTA seeds, optional stages.
fn render_factor_sv(
    module: &str,
    region: &CombRegion,
    scratch: &ParallelScratch,
    target: &TimingTarget,
) -> String {
    // Keep the clock the scratch actually bound — never fake clk_i over
    // clk_j / unresolved sequential boards.
    let clk = if scratch.clock.clock_name.is_empty() {
        "<unresolved_clk>"
    } else {
        scratch.clock.clock_name.as_str()
    };
    let edge = if scratch.clock.edge.is_empty() {
        "posedge"
    } else {
        scratch.clock.edge.as_str()
    };
    let rst = scratch.clock.reset_name.as_str();
    let period = scratch.clock.period_ns;
    let b = scratch.clock.budget_fo4.max(target.budget_fo4);
    let n = scratch.cycle_count.max(1);

    let mut out = String::new();
    out.push_str("// ----------------------------------------------------------------\n");
    out.push_str("// sv-timing: always_ff factorize  (clock-aware ParallelScratch)\n");
    out.push_str("// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;\n");
    out.push_str(&format!(
        "//   N=ceil(M/B) cycles of {edge} {clk}  period_ns={period:.6}  B={b:.3} FO4\n"
    ));
    out.push_str(&format!(
        "// module={module}  region={}  makespan={:.3} FO4  cycle_count={n}  deps={}  procedural_ok={}\n",
        region.id, scratch.makespan_fo4, scratch.dep_edges, scratch.procedural_ok
    ));
    out.push_str("// OpenSTA (review-only seeds — not set_max_delay):\n");
    out.push_str(&format!(
        "//   create_clock -name {clk} -period {period:.6} [get_ports {clk}]\n"
    ));

    // Group NBA / assigns by ready_cycle on THIS clock (factorization key).
    let mut by_cycle: BTreeMap<u32, Vec<String>> = BTreeMap::new();
    for op in &scratch.ops {
        by_cycle
            .entry(op.ready_cycle.max(1))
            .or_default()
            .push(format!(
                "node{} c={:.2} slack={:.2}",
                op.node_id, op.asap_end, op.slack_fo4
            ));
    }
    for (var, t) in &scratch.var_ready_fo4 {
        let cyc = (*t / b.max(1.0)).ceil().max(1.0) as u32;
        out.push_str(&format!(
            "// order expect: {var}  ready_cycle={cyc}  ready_fo4={t:.3}  "
        ));
        out.push_str(&format!(
            "OpenSTA: report_timing -from {clk} -to {var}\n"
        ));
        by_cycle.entry(cyc).or_default();
    }

    let sens = if rst.is_empty() {
        format!("{edge} {clk}")
    } else {
        format!("{edge} {clk} or negedge {rst}")
    };

    for cyc in 1..=n {
        out.push_str(&format!(
            "// --- factor stage {cyc}/{n}  capture on {edge} {clk} ---\n"
        ));
        out.push_str(&format!("// always_ff @({sens}) begin\n"));
        if !rst.is_empty() {
            out.push_str(&format!("//   if (!{rst}) begin /* reset */ end else begin\n"));
        }
        let vars: Vec<_> = scratch
            .var_ready_fo4
            .iter()
            .filter(|(_, t)| {
                let c = (**t / b.max(1.0)).ceil().max(1.0) as u32;
                c == cyc
            })
            .map(|(v, _)| v.as_str())
            .collect();
        if vars.is_empty() {
            out.push_str(&format!(
                "//     /* cycle {cyc}: no capture on this edge (slack) */\n"
            ));
        } else {
            for v in vars {
                out.push_str(&format!(
                    "//     {v} <= …; // sv-timing: cycle {cyc}/{n} on {clk}\n"
                ));
            }
        }
        if let Some(ops) = by_cycle.get(&cyc) {
            for note in ops {
                out.push_str(&format!("//     /* {note} */\n"));
            }
        }
        if !rst.is_empty() {
            out.push_str("//   end\n");
        }
        out.push_str("// end\n");
    }
    out.push_str("// ----------------------------------------------------------------\n");
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use sv_timing_core::{
        CombRegion, EdgeKind, GateInfo, IrNode, OperatorClass, OriginKind, RegionKind, SourceLoc,
        TimingDesign, TimingModule, TimingTarget,
    };
    use std::collections::BTreeMap;

    fn loc() -> SourceLoc {
        SourceLoc {
            file: "ff.sv".into(),
            start_line: 10,
            start_col: 1,
            end_line: 20,
            end_col: 1,
            byte_start: 0,
            byte_end: 1,
            origin: OriginKind::UserFile,
        }
    }

    fn factor_context(dependent: bool) -> crate::pass::PassContext {
        let mut design = TimingDesign::empty(TimingTarget::new(4000.0, 20.0, 0.2));
        let mut nodes = BTreeMap::new();
        nodes.insert(
            0,
            IrNode {
                id: 0,
                op_class: Some(OperatorClass::Other),
                width: 1,
                fo4_cost: 20.0,
                gate: None,
                loc: loc(),
                fans_in: vec![],
                fans_out: vec![],
                width_defaulted: true,
                reads_reg: false,
                lhs: Some("state_q".into()),
                rhs: Some("state_d".into()),
                lhs_expr: None,
                rhs_expr: None,
                case_labels: Vec::new(),
                case_is_default: false,
                case_selector: None,
                fo4_locked: false,
                assign_kind: Default::default(),
            },
        );
        let mut gate = GateInfo {
            is_comb: false,
            ..GateInfo::default()
        };
        gate.clock_name = Some("clk_i".into());
        gate.edge = Some(EdgeKind::Posedge);
        gate.reset_name = Some("rst_ni".into());
        let mut regions = BTreeMap::new();
        regions.insert(
            0,
            CombRegion {
                id: 0,
                module: 0,
                kind: RegionKind::AlwaysFf,
                label: None,
                gate,
                nodes: vec![0],
                total_fo4: 20.0,
                loc_span: loc(),
                multi_cycle: false,
            },
        );
        design.modules.insert(
            0,
            TimingModule {
                id: 0,
                name: "u_ff".into(),
                file: "ff.sv".into(),
                nodes,
                regions,
                localparams: vec![],
                parameters: vec![],
                ports: vec![],
                gen_loops: vec![],
                functions: vec![],
                function_bodies: Vec::new(),
                package_imports: vec![],
                instances: vec![],
                decls: Vec::new(),
                config_branch: false,
                loc: loc(),
            },
        );
        if dependent {
            let module = design.modules.get_mut(&0).unwrap();
            let mut consumer = module.nodes[&0].clone();
            consumer.id = 1;
            consumer.lhs = Some("next_q".into());
            consumer.rhs = Some("state_q + 1".into());
            module.nodes.insert(1, consumer);
            module.regions.get_mut(&0).unwrap().nodes.push(1);
            module.regions.get_mut(&0).unwrap().total_fo4 += 20.0;
        }
        let mut policy = crate::pass::PassPolicy::default();
        policy.correct_enabled = true;
        policy.correct_allow_modules = vec!["u_ff".into()];
        sv_timing_core::fill_design_parallel_timing(&mut design);
        crate::pass::PassContext::new(design, sv_timing_core::NameTable::new(), policy)
    }

    #[test]
    fn ambiguous_sequential_scratch_does_not_emit_staged_factorization() {
        for fallback in 0..3 {
            let mut ctx = factor_context(true);
            if fallback == 1 {
                ctx.design.parallel_timing.clear();
            } else if fallback == 2 {
                ctx.design.parallel_timing.get_mut("u_ff").unwrap()
                    .regions.get_mut(&0).unwrap().clock = Default::default();
            }
            let original = serde_json::to_value(&ctx.design.modules).unwrap();
            factor_always_ff_regions(&mut ctx);
            assert!(ctx.trace.records.is_empty(), "fallback mode {fallback}");
            assert_eq!(serde_json::to_value(&ctx.design.modules).unwrap(), original);
            let board = &ctx.design.parallel_timing["u_ff"];
            let scratch = board.scratch_for_region(0).unwrap();
            assert!(scratch.clock.is_sequential());
            assert!(!scratch.procedural_ok);
        }
    }

    #[test]
    fn factor_comments_name_clock_and_cycles() {
        let mut ctx = factor_context(false);
        let original = serde_json::to_value(&ctx.design.modules).unwrap();
        factor_always_ff_regions(&mut ctx);
        assert!(!ctx.trace.records.is_empty());
        assert_eq!(serde_json::to_value(&ctx.design.modules).unwrap(), original);
        assert_eq!(ctx.trace.records[0].fo4_before, Some(20.0));
        assert_eq!(ctx.trace.records[0].fo4_after, Some(20.0));
        let snip = ctx.trace.records[0].emit_snippet.as_deref().unwrap_or("");
        assert!(snip.contains("clk_i"), "{snip}");
        assert!(snip.contains("posedge"), "{snip}");
        assert!(snip.contains("create_clock"), "{snip}");
        assert!(snip.contains("order expect"), "{snip}");
        assert!(snip.contains("report_timing"), "{snip}");
        assert!(snip.contains("always_ff"), "{snip}");
        assert!(snip.contains("cycle"), "{snip}");
        assert!(
            !snip.contains("<unresolved_clk>"),
            "named clock must not be dropped: {snip}"
        );
        let board = ctx
            .design
            .parallel_timing
            .get("u_ff")
            .expect("factorizer must keep the module board");
        let kept = board
            .scratch_for_region(0)
            .expect("always_ff scratch must stay on the board");
        assert!(kept.clock.is_sequential());
        assert_eq!(kept.clock.clock_name, "clk_i");
        assert_eq!(kept.clock.edge, "posedge");
    }
}
