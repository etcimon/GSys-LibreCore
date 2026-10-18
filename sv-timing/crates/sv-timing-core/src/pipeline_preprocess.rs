// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Initial-IR compilation of pipeline representation contracts.
//!
//! This deterministic preprocessor changes contract facts, not executable
//! nodes or delay estimates. Later passes still own cut selection, latency,
//! area, clock/reset, alignment and emission. See PIPELINING-RT-LEARNING.md.

use crate::ir::{AssignKind, PipePragma, TimingDesign, TimingModule};
use crate::{Expr, OriginKind, SourceLoc};
use serde::{Deserialize, Serialize};

/// An authored two-row representation compiled into an ordinary carry bundle.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RepresentationPlan {
    /// Protocol domain.
    pub domain: String,
    /// Sum component; either row may become the critical data anchor later.
    pub sum: String,
    /// Already-shifted carry row captured at the same edge.
    pub carry: String,
    /// Explicit, equal-width sum-plus-carry consumer.
    pub result: String,
    /// Resolved width of both rows and the consumer.
    pub width: u32,
    /// Original directive location, retained through normalization/emission.
    pub loc: SourceLoc,
}

fn arg<'a>(p: &'a PipePragma, key: &str) -> Option<&'a str> {
    p.args
        .iter()
        .find(|(k, _)| k == key)
        .map(|(_, v)| v.as_str())
}

fn ident(s: &str) -> bool {
    !s.is_empty()
        && !s.as_bytes()[0].is_ascii_digit()
        && s.bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'_' || c == b'$')
}

fn fact(p: &PipePragma, kind: &str, args: Vec<(String, String)>, words: Vec<String>) -> PipePragma {
    PipePragma {
        derived: true,
        kind: kind.into(),
        domain: p.domain.clone(),
        args,
        words,
        loc: p.loc.clone(),
    }
}

fn pure_reads(expr: &Expr, out: &mut Vec<String>) -> bool {
    match expr {
        Expr::Ident { name } => {
            out.push(TimingModule::root_ident(name).unwrap_or(name).into());
            true
        }
        Expr::Literal { .. } => true,
        Expr::Unary { arg, .. } => pure_reads(arg, out),
        Expr::Index { base, index } => pure_reads(base, out) && pure_reads(index, out),
        Expr::PartSelect { left, right, .. } => pure_reads(left, out) && pure_reads(right, out),
        Expr::Binary { left, right, .. } => pure_reads(left, out) && pure_reads(right, out),
        Expr::Ternary {
            cond,
            then_e,
            else_e,
        } => pure_reads(cond, out) && pure_reads(then_e, out) && pure_reads(else_e, out),
        _ => false,
    }
}

fn independent_rows(
    module: &TimingModule,
    rows: [&str; 2],
    result: &str,
) -> Option<std::collections::BTreeSet<String>> {
    let mut inputs = std::collections::BTreeSet::new();
    for row in rows {
        let writer = module
            .nodes
            .values()
            .find(|n| n.lhs.as_deref() == Some(row))
            .unwrap();
        let mut pending = Vec::new();
        if !writer
            .rhs_expr
            .as_ref()
            .is_some_and(|e| pure_reads(e, &mut pending))
        {
            return None;
        }
        let mut seen = std::collections::BTreeSet::new();
        let mut edges = std::collections::BTreeMap::<String, Vec<String>>::new();
        while let Some(name) = pending.pop() {
            if rows.contains(&name.as_str()) || name == result {
                return None;
            }
            if !seen.insert(name.clone()) {
                continue;
            }
            let writers: Vec<_> = module
                .nodes
                .values()
                .filter(|n| n.lhs.as_deref() == Some(name.as_str()))
                .collect();
            if !writers.is_empty()
                && writers
                    .iter()
                    .all(|n| n.assign_kind == AssignKind::Nonblocking)
            {
                continue;
            }
            if writers.is_empty() && module.ports.iter().any(|p| p.name == name) {
                continue;
            }
            let mut reads = Vec::new();
            if writers.len() != 1
                || writers[0].assign_kind != AssignKind::Continuous
                || !writers[0]
                    .rhs_expr
                    .as_ref()
                    .is_some_and(|e| pure_reads(e, &mut reads))
            {
                return None;
            }
            pending.extend(reads.iter().cloned());
            edges.insert(name, reads);
        }
        // Reject feedback even when its cycle does not contain a named row.
        while !edges.is_empty() {
            let leaves: Vec<_> = edges
                .iter()
                .filter(|(_, reads)| reads.iter().all(|r| !edges.contains_key(r)))
                .map(|(n, _)| n.clone())
                .collect();
            if leaves.is_empty() {
                return None;
            }
            for name in leaves {
                edges.remove(&name);
            }
        }
        inputs.extend(seen);
    }
    Some(inputs)
}

fn reaches_protected(
    module: &TimingModule,
    starts: [&str; 3],
    protected: &std::collections::BTreeSet<String>,
) -> bool {
    let mut pending: Vec<String> = starts.into_iter().map(str::to_string).collect();
    let mut visited = std::collections::BTreeSet::new();
    while let Some(name) = pending.pop() {
        if !visited.insert(name.clone()) {
            continue;
        }
        for n in module.nodes.values() {
            let mut reads = std::collections::BTreeSet::new();
            if let Some(e) = &n.rhs_expr {
                e.walk_idents(&mut |i| {
                    reads.insert(TimingModule::root_ident(i).unwrap_or(i).to_string());
                });
            }
            for g in module.guards.get(&n.id).into_iter().flatten() {
                Expr::parse(g.trim_start_matches('^')).walk_idents(&mut |i| {
                    reads.insert(TimingModule::root_ident(i).unwrap_or(i).to_string());
                });
            }
            if reads.contains(&name) {
                if let Some(lhs) = n.lhs.as_deref().and_then(TimingModule::root_ident) {
                    if protected.contains(lhs) {
                        return true;
                    }
                    pending.push(lhs.into());
                }
            }
        }
    }
    false
}

fn compile_pair(
    module: &TimingModule,
    p: &PipePragma,
    base: &[PipePragma],
    width: &dyn Fn(&str) -> Option<u32>,
) -> Result<(RepresentationPlan, Vec<PipePragma>), String> {
    if p.loc.origin != OriginKind::UserFile || p.loc.byte_end <= p.loc.byte_start {
        return Err("representation needs an original-source directive".into());
    }
    if p.words != ["carry-save"]
        || p.args.len() != 3
        || p.args
            .iter()
            .any(|(k, _)| !matches!(k.as_str(), "sum" | "carry" | "result"))
    {
        return Err(
            "representation supports: <domain> carry-save sum=<net> carry=<net> result=<net>"
                .into(),
        );
    }
    let (Some(domain), Some(sum), Some(carry), Some(result)) = (
        p.domain.as_deref(),
        arg(p, "sum"),
        arg(p, "carry"),
        arg(p, "result"),
    ) else {
        return Err("representation is missing its domain or row/consumer names".into());
    };
    if sum == carry || sum == result || carry == result {
        return Err("representation rows and consumer must be distinct".into());
    }
    for name in [sum, carry, result] {
        if !ident(name)
            || module
                .decls
                .iter()
                .any(|d| d.name == name && (d.block_local || !d.unpacked_text.is_empty()))
            || (!module.decls.iter().any(|d| d.name == name)
                && !module.ports.iter().any(|q| q.name == name))
        {
            return Err(format!(
                "representation `{name}` needs an unambiguous module-level packed net"
            ));
        }
        let writers: Vec<_> = module
            .nodes
            .values()
            .filter(|n| n.lhs.as_deref() == Some(name))
            .collect();
        if writers.len() != 1
            || writers[0].assign_kind != AssignKind::Continuous
            || writers[0].loc.origin != OriginKind::UserFile
            || module
                .guards
                .get(&writers[0].id)
                .is_some_and(|g| !g.is_empty())
        {
            return Err(format!(
                "representation `{name}` needs one unguarded continuous writer"
            ));
        }
    }
    let Some(w) = width(sum).filter(|w| *w > 0) else {
        return Err("representation sum width is unresolved".into());
    };
    if width(carry) != Some(w) || width(result) != Some(w) {
        return Err("representation rows/consumer require equal resolved widths".into());
    }
    let consumer = module
        .nodes
        .values()
        .find(|n| n.lhs.as_deref() == Some(result))
        .unwrap();
    let matches_pair = match consumer.rhs_expr.as_ref() {
        Some(Expr::Binary {
            op, left, right, ..
        }) if op == "+" => match (&**left, &**right) {
            (Expr::Ident { name: a }, Expr::Ident { name: b }) => {
                (a == sum && b == carry) || (a == carry && b == sum)
            }
            _ => false,
        },
        _ => false,
    };
    if !matches_pair {
        return Err(format!(
            "representation consumer `{result}` must be exactly sum + carry"
        ));
    }
    let Some(mut protected) = independent_rows(module, [sum, carry], result) else {
        return Err("representation row cones must be independent up to ports/registers; cross-row feedback, calls or ambiguous writers need a different lowering".into());
    };
    if !module.functions.is_empty() {
        return Err(
            "representation lowering does not analyze hidden reads in module functions".into(),
        );
    }
    let contract = crate::pipe_contract::resolve_pragmas(module, base)
        .ok_or("representation needs an existing protocol")?;
    if !contract.rejected.is_empty() {
        return Err(format!(
            "representation has an invalid base contract: {}",
            contract.rejected[0]
        ));
    }
    let mut d = contract
        .domains
        .iter()
        .find(|d| d.name == domain)
        .cloned()
        .ok_or_else(|| format!("representation names unknown domain `{domain}`"))?;
    if d.result_valid.is_none() || d.has_id() != d.result_id.is_some() {
        return Err("representation needs matching input/result valid/id roles".into());
    }
    let mut controls: Vec<String> = [
        Some(&d.valid),
        d.has_id().then_some(&d.id),
        d.flush.as_ref(),
        d.result_valid.as_ref(),
        d.result_id.as_ref(),
    ]
    .into_iter()
    .flatten()
    .cloned()
    .collect();
    if controls.iter().any(|s| !ident(s)) {
        return Err("representation valid/id/flush/result roles need simple signal names".into());
    }
    if !d.kill.is_empty() && !pure_reads(&Expr::parse(&d.kill.replace("$id", &d.id)), &mut controls)
    {
        return Err("representation kill expression has unresolved/hidden reads".into());
    }
    for r in module.regions.values() {
        controls.extend(
            r.gate
                .clock_name
                .iter()
                .chain(r.gate.reset_name.iter())
                .cloned(),
        );
    }
    if controls
        .iter()
        .any(|c| [sum, carry, result].contains(&c.as_str()))
    {
        return Err("representation data cannot alias protocol, clock or reset roles".into());
    }
    protected.extend(controls);
    protected.extend(
        d.carry
            .iter()
            .filter(|c| c.as_str() != sum && c.as_str() != carry)
            .cloned(),
    );
    if reaches_protected(module, [sum, carry, result], &protected) {
        return Err("representation feeds back into an input/control/carried source; a recurrence needs a different pipeline strategy".into());
    }
    let mut facts = Vec::new();
    if !d.carry.iter().any(|c| c == carry) {
        d.carry.push(carry.into());
        facts.push(fact(p, "carry", vec![], vec![carry.into()]));
    }
    d.check_widths(width)?;
    if !d.result_also.iter().any(|c| c == result) {
        let mut args = vec![("valid".into(), d.result_valid.unwrap())];
        if let Some(id) = d.result_id {
            args.push(("id".into(), id));
        }
        facts.push(fact(p, "result", args, vec![result.into()]));
    }
    // One authored boundary, two equivalent anchors: either row may be the
    // critical path. A no-cut on either component blocks the whole boundary.
    let anchors: Vec<_> = contract
        .cut_ok
        .iter()
        .filter(|(on, _, _)| on == sum || on == carry)
        .collect();
    if anchors.iter().any(|(_, d, _)| d.as_deref() != Some(domain)) {
        return Err("representation cut anchors must name their protocol domain".into());
    }
    if contract.no_cut.contains(sum) || contract.no_cut.contains(carry) {
        for row in [sum, carry] {
            facts.push(fact(p, "no-cut", vec![("on".into(), row.into())], vec![]));
        }
    } else if !anchors.is_empty() {
        for row in [sum, carry] {
            if !anchors.iter().any(|(on, _, _)| on == row) {
                facts.push(fact(p, "cut-ok", vec![("on".into(), row.into())], vec![]));
            }
        }
    }
    let mut args = p.args.clone();
    args.push(("width".into(), w.to_string()));
    facts.push(fact(p, "representation-ready", args, p.words.clone()));
    Ok((
        RepresentationPlan {
            domain: domain.into(),
            sum: sum.into(),
            carry: carry.into(),
            result: result.into(),
            width: w,
            loc: p.loc.clone(),
        },
        facts,
    ))
}

/// Rebuild derived representation facts before cost attribution. Source facts
/// and applied-boundary guards survive; obsolete derived facts are discarded.
/// Safe to call repeatedly and after rehydrating a module from JSON/cache.
pub fn prepare_design(design: &mut TimingDesign) {
    for module in design.modules.values_mut() {
        if !module
            .pipe_pragmas
            .iter()
            .any(|p| p.kind == "representation")
        {
            continue;
        }
        let source: Vec<_> = module
            .pipe_pragmas
            .iter()
            .filter(|p| !p.derived || p.kind == "pipeline-boundary-applied")
            .cloned()
            .collect();
        let mut base: Vec<_> = source
            .iter()
            .filter(|p| p.kind != "representation")
            .cloned()
            .collect();
        let resolver = crate::width::WidthResolver::from_parts(
            &design.packages,
            &design.param_map_ints,
            &module.decls,
            &module.ports,
            &module.const_exprs,
            &module.typedef_texts,
            &module.package_imports,
            design.width_map.get(&module.name),
        );
        let width = |s: &str| resolver.expr_width(&Expr::parse(s));
        let mut derived = Vec::new();
        for p in source.iter().filter(|p| p.kind == "representation") {
            if source
                .iter()
                .filter(|q| q.kind == "representation" && q.domain == p.domain)
                .count()
                != 1
            {
                derived.push(fact(
                    p,
                    "preprocess-error",
                    vec![],
                    vec!["only one representation per domain is supported".into()],
                ));
                continue;
            }
            match compile_pair(module, p, &base, &width) {
                Ok((_, facts)) => {
                    base.extend(facts.iter().cloned());
                    derived.extend(facts);
                }
                Err(reason) => {
                    let error = fact(p, "preprocess-error", vec![], vec![reason]);
                    base.push(error.clone());
                    derived.push(error);
                }
            }
        }
        module.pipe_pragmas = source.into_iter().chain(derived).collect();
    }
}

/// Typed plans carried in the initial IR. These describe normalized contracts,
/// not accepted stages, measured gains or closure claims.
pub fn representations(module: &TimingModule) -> Vec<RepresentationPlan> {
    module
        .pipe_pragmas
        .iter()
        .filter(|p| p.derived && p.kind == "representation-ready")
        .filter_map(|p| {
            Some(RepresentationPlan {
                domain: p.domain.clone()?,
                sum: arg(p, "sum")?.into(),
                carry: arg(p, "carry")?.into(),
                result: arg(p, "result")?.into(),
                width: arg(p, "width")?.parse().ok()?,
                loc: p.loc.clone(),
            })
        })
        .collect()
}

/// Select the other row as companion when a paired boundary is reached through
/// either critical path. A data net must not also feed itself as a carried
/// signal after emission replaces its source assignment with a staged value.
pub fn domain_at_cut(
    module: &TimingModule,
    mut domain: crate::pipe_contract::PipeDomain,
    lhs: &str,
) -> crate::pipe_contract::PipeDomain {
    for plan in representations(module) {
        if plan.domain == domain.name && (plan.sum == lhs || plan.carry == lhs) {
            let other = if plan.sum == lhs {
                plan.carry
            } else {
                plan.sum
            };
            domain.carry.retain(|c| c != lhs);
            if !domain.carry.contains(&other) {
                domain.carry.push(other);
            }
        }
    }
    domain
}

/// Persist a successful boundary in mutable IR so later passes/preprocessing
/// cannot schedule a second, unbalanced cut at the same sum.
pub fn mark_applied(module: &mut TimingModule, plans: &[RepresentationPlan]) {
    for plan in plans {
        for row in [&plan.sum, &plan.carry] {
            if module.pipe_pragmas.iter().any(|p| {
                p.derived
                    && p.kind == "pipeline-boundary-applied"
                    && arg(p, "on") == Some(row.as_str())
            }) {
                continue;
            }
            module.pipe_pragmas.push(PipePragma {
                derived: true,
                kind: "pipeline-boundary-applied".into(),
                domain: Some(plan.domain.clone()),
                args: vec![("on".into(), row.clone())],
                words: vec![],
                loc: plan.loc.clone(),
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{analyze_files, LowerOptions, ParseOptions};

    const SOURCE: &str = include_str!("../../../fixtures/auto_correct/pipe_representation.sv");

    fn analyze(text: &str) -> TimingDesign {
        static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let path = std::env::temp_dir().join(format!(
            "svt_repr_{}_{}.sv",
            std::process::id(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        std::fs::write(&path, text).unwrap();
        let out = analyze_files(
            &[path.clone()],
            &ParseOptions::default(),
            &LowerOptions::default(),
        )
        .unwrap();
        std::fs::remove_file(path).unwrap();
        out.design
    }

    #[test]
    fn initial_ir_compiles_companion_without_hardware_or_timing_credit() {
        let mut design = analyze(SOURCE);
        let m = design.modules.values().next().unwrap();
        let plan = representations(m);
        assert_eq!(plan.len(), 1);
        assert_eq!(plan[0].width, 32);
        let c = crate::pipe_contract::resolve(m).unwrap();
        assert!(c.rejected.is_empty(), "{:?}", c.rejected);
        assert_eq!(c.domains[0].carry, ["carry_row"]);
        assert_eq!(c.domains[0].result_valid.as_deref(), Some("res_valid_d"));
        assert_eq!(c.domains[0].result_id.as_deref(), Some("res_tid_d"));
        assert_eq!(c.domains[0].result_also, ["res_d"]);
        assert_eq!(c.cut_ok.len(), 2, "two anchors for one authored boundary");
        assert_eq!(
            m.pipe_pragmas
                .iter()
                .filter(|p| !p.derived && p.kind == "cut-ok")
                .count(),
            1
        );
        let without = analyze(
            &SOURCE
                .lines()
                .filter(|l| !l.contains("representation ex"))
                .collect::<Vec<_>>()
                .join("\n"),
        );
        let costs = |d: &TimingDesign| {
            d.modules
                .values()
                .next()
                .unwrap()
                .nodes
                .values()
                .map(|n| (n.lhs.clone(), n.rhs.clone(), n.width, n.fo4_cost))
                .collect::<Vec<_>>()
        };
        assert_eq!(costs(&design), costs(&without), "metadata must not buy FO4");
        let before = serde_json::to_value(&design).unwrap();
        prepare_design(&mut design);
        assert_eq!(before, serde_json::to_value(&design).unwrap(), "idempotent");
    }

    #[test]
    fn cache_roundtrip_rebuilds_facts_and_preserves_applied_boundary() {
        let mut d = analyze(SOURCE);
        let m = d.modules.values_mut().next().unwrap();
        let plans = representations(m);
        mark_applied(m, &plans);
        let mut restored: TimingDesign =
            serde_json::from_value(serde_json::to_value(&d).unwrap()).unwrap();
        prepare_design(&mut restored);
        let m = restored.modules.values().next().unwrap();
        let c = crate::pipe_contract::resolve(m).unwrap();
        let node = m
            .nodes
            .values()
            .find(|n| n.lhs.as_deref() == Some("sum_row"))
            .unwrap();
        assert!(matches!(
            crate::pipe_contract::cut_permission(m, &c, node),
            crate::pipe_contract::CutPermission::Forbidden(_)
        ));
        assert_eq!(c.domains[0].carry, ["carry_row"], "no duplicate lowering");
    }

    #[test]
    fn reprocessing_uses_the_current_parameter_context() {
        let source = SOURCE
            .replace(
                "module pipe_representation (",
                "module pipe_representation #(parameter int unsigned W = 32) (",
            )
            .replace(
                "logic [31:0] a_q, b_q, c_q, sum_row, carry_row, res_d;",
                "logic [W-1:0] a_q, b_q, c_q, sum_row, carry_row, res_d;",
            );
        let mut d = analyze(&source);
        assert_eq!(
            representations(d.modules.values().next().unwrap())[0].width,
            32
        );
        d.param_map_ints.insert("W".into(), 16);
        prepare_design(&mut d);
        assert_eq!(
            representations(d.modules.values().next().unwrap())[0].width,
            16
        );
    }

    #[test]
    fn unsupported_shapes_refuse_without_partial_bundle() {
        for text in [
            SOURCE.replace("carry=carry_row", "carry=missing"),
            SOURCE.replace("sum_row + carry_row", "sum_row - carry_row"),
            SOURCE.replace(
                "((a_q & b_q) | (a_q & c_q) | (b_q & c_q)) << 1",
                "sum_row << 1",
            ),
            SOURCE.replace("kill=cancel_i[$id]", "kill=carry_row[0]"),
            SOURCE.replace("valid=valid_q", "valid=sum_row[0]"),
            SOURCE.replace("id=tid_q kill=cancel_i[$id]", "kill=flush_i"),
            SOURCE.replace("a_q <= a_i;", "a_q <= res_d;"),
            SOURCE.replace(
                "logic valid_q, res_valid_d;",
                "logic [1:0] valid_q, res_valid_d;",
            ),
            SOURCE.replace(
                "logic [31:0] a_q, b_q, c_q, sum_row, carry_row, res_d;",
                "logic [31:0] a_q, b_q, c_q, sum_row, res_d;\nlogic [15:0] carry_row;",
            ),
            SOURCE.replace("carry-save sum=", "speculative-queue sum="),
            SOURCE.replace(
                "// svt-pipe: representation ex carry-save sum=sum_row carry=carry_row result=res_d",
                "initial $display(\"// svt-pipe: representation ex carry-save sum=sum_row carry=carry_row result=res_d\");"),
        ] {
            let d = analyze(&text);
            let m = d.modules.values().next().unwrap();
            assert!(representations(m).is_empty());
            let c = crate::pipe_contract::resolve(m).unwrap();
            assert!(!c.rejected.is_empty());
            assert!(
                c.domains[0].carry.is_empty(),
                "failed compile must be atomic"
            );
            let n = m
                .nodes
                .values()
                .find(|n| n.lhs.as_deref() == Some("sum_row"))
                .unwrap();
            assert!(matches!(
                crate::pipe_contract::cut_permission(m, &c, n),
                crate::pipe_contract::CutPermission::Forbidden(_)
            ));
        }
    }

    #[test]
    fn unprepared_or_unpermitted_source_cannot_authorize_a_stage() {
        let mut d = analyze(SOURCE);
        let m = d.modules.values_mut().next().unwrap();
        m.pipe_pragmas.retain(|p| !p.derived);
        assert!(!crate::pipe_contract::resolve(m)
            .unwrap()
            .rejected
            .is_empty());
        let d = analyze(&SOURCE.replace("cut-ok ex on=sum_row", "no-cut on=sum_row"));
        let m = d.modules.values().next().unwrap();
        assert_eq!(representations(m).len(), 1, "representation is still known");
        let c = crate::pipe_contract::resolve(m).unwrap();
        let n = m
            .nodes
            .values()
            .find(|n| n.lhs.as_deref() == Some("sum_row"))
            .unwrap();
        assert!(matches!(
            crate::pipe_contract::cut_permission(m, &c, n),
            crate::pipe_contract::CutPermission::Forbidden(_)
        ));
        assert!(
            c.no_cut.contains("carry_row"),
            "one forbidden row blocks the atomic pair"
        );
    }

    #[test]
    fn either_row_can_be_critical_but_neither_captures_itself_twice() {
        let d = analyze(SOURCE);
        let m = d.modules.values().next().unwrap();
        let c = crate::pipe_contract::resolve(m).unwrap();
        for (data, companion) in [("sum_row", "carry_row"), ("carry_row", "sum_row")] {
            let n = m
                .nodes
                .values()
                .find(|n| n.lhs.as_deref() == Some(data))
                .unwrap();
            let crate::pipe_contract::CutPermission::Allowed(Some(domain)) =
                crate::pipe_contract::cut_permission(m, &c, n)
            else {
                panic!("paired boundary")
            };
            assert_eq!(domain.carry, [companion]);
        }
    }
}
