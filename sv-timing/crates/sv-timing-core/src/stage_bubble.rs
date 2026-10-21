// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! `svt-stage` bubble-up (PIPELINE-PRAGMAS §19.1): what a declared stage's
//! added cycles do to the readers of the nets it publishes.
//!
//! A register in a cone that produces a READINESS / NEXT-ADDRESS DECISION
//! (issue wakeup → select → grant, dispatch issue_valid, scoreboard
//! operand-ready, a frontend npc recurrence, a rename map → prd
//! back-to-back) is a DRAG: it inserts a bubble between dependent
//! decisions and no other issue port can wake the dependent one sooner.
//! A register on a VALUE path (multiplier, ALU result, a verdict,
//! write-buffer forward) is a STALL that out-of-order issue covers when
//! another instruction is ready — the dependent use still waits the full
//! depth.
//!
//! For every stage that adds cycles (`cycles>1`, `window>0`, or a region
//! that contains the registers publishing its results) this computes the
//! stage's output nets, walks their readers — in-module readers in other
//! stages plus parent-side readers through `carry_over` — classifies each
//! reader `decision`/`value` and reports a verdict: `drag`,
//! `covered` or `absorbed`. It is a report; it changes no IR and awards
//! no FO4.

use serde::Serialize;
use std::collections::BTreeSet;

use crate::carry_over::{carry_over_for_stage, net_is_recurrence, reads_root};
use crate::ir::{TimingDesign, TimingModule};
use crate::stage_pragma::stage_map;

fn root(s: &str) -> &str {
    TimingModule::root_ident(s).unwrap_or(s)
}

/// One reader of a net a stage publishes.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct BubbleReader {
    /// Module the reader lives in (the staged module for in-module
    /// readers, the parent for instance-side readers).
    pub module: String,
    /// Instance name when the reader is parent-side; empty in-module.
    pub instance: String,
    /// LHS the reader writes from the staged net.
    pub lhs: String,
    /// Source line of that read.
    pub line: u32,
    /// `flop`, `comb`, `output`, or `recurrence`.
    pub kind: String,
    /// Extra cycles the stage declares/implements for this reader
    /// (`+1` on a recurrence, same `wait_of` rule as the bottleneck trace).
    pub wait_cycles: u32,
    /// `decision` or `value`.
    pub class: String,
    /// `pragma`, `recurrence`, `heuristic`, or `default`.
    pub class_source: String,
    /// True when a declaration absorbs the wait.
    pub absorbed: bool,
    /// Which declaration absorbs it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub absorbed_by: Option<String>,
}

/// A declared architectural cover (`svt-stage: absorb`) attached to a
/// stage, with the result of the IR precondition check.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct StageCover {
    /// Cover mechanism (`spec-wakeup`, `read-ahead`, …).
    pub by: String,
    /// Cover precondition text carried from the pragma.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cond: Option<String>,
    /// Whether the cover's precondition was visible/checkable in the IR.
    /// `false` rows also raise a `unverified-cover` finding.
    pub verified: bool,
}

/// Bubble-up report for one declared stage.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct StageBubble {
    /// Module declaring the stage.
    pub module: String,
    /// Stage name.
    pub stage: String,
    /// Extra cycles the stage declares/implements:
    /// `(cycles−1) + window + (publishing register ? 1 : 0)`.
    pub extra_cycles: u32,
    /// Nets driven inside the stage and read outside it.
    pub output_nets: Vec<String>,
    /// Every reader found, absorbed or not.
    pub readers: Vec<BubbleReader>,
    /// `drag`, `covered`, or `absorbed`.
    pub verdict: String,
    /// One sentence a person can use while reading the board.
    pub rationale: String,
    /// `svt-pipe: cycle` lines (file:line) a `drag` verdict collides with.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub collides: Vec<String>,
    /// Declared architectural cover, when the stage carries an
    /// `svt-stage: absorb` pragma.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover: Option<StageCover>,
    /// Findings raised while validating the stage (`unverified-cover`, …).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub findings: Vec<String>,
}

/// Readiness / next-address vocabulary (§19.1 heuristic): a reader LHS
/// matching any of these is a `decision` reader, labelled `heuristic`.
fn looks_decision(lhs: &str) -> bool {
    let l = lhs.to_ascii_lowercase();
    l.ends_with("valid_o")
        || l.ends_with("valid_i")
        || l.contains("ready")
        || l.contains("rdy")
        || l.contains("grant")
        || l.contains("select")
        || l.contains("issue")
        || l.contains("npc")
        || l.contains("map")
        || l.contains("prd")
        || l.contains("wake")
}

/// Cycle-declared names (q/d/hold) of a module's own contract: a reader
/// writing one of these sits on a `svt-pipe: cycle` recurrence.
fn cycle_names(module: &TimingModule) -> BTreeSet<String> {
    crate::pipe_contract::resolve(module)
        .map(|c| {
            c.domains
                .iter()
                .filter_map(|d| d.cycle.as_ref())
                .flat_map(|s| [root(&s.q).to_string(), root(&s.d).to_string(), root(&s.hold).to_string()])
                .collect()
        })
        .unwrap_or_default()
}

/// The domain of the staged module's contract the net belongs to, under
/// the same rule the bottleneck trace uses.
fn domain_of_net<'a>(
    contract: &'a crate::pipe_contract::PipeContract,
    net: &str,
) -> Option<&'a crate::pipe_contract::PipeDomain> {
    contract.domains.iter().find(|d| {
        contract
            .cut_ok
            .iter()
            .any(|(a, dom, _)| root(a) == net && dom.as_deref().map_or(true, |x| x == d.name))
            || d.result_also.iter().any(|r| root(r) == net)
            || d.cycle.as_ref().is_some_and(|s| root(&s.d) == net)
    })
}

/// Absorption declarations the net carries in the staged module, applied
/// per reader: `throughput accept`, the domain's `protocol ready=`,
/// `replicate`, or the *reader* module's `async … cycles=` on the read.
fn absorbed_by(
    design: &TimingDesign,
    staged: &TimingModule,
    contract: Option<&crate::pipe_contract::PipeContract>,
    domain: Option<&crate::pipe_contract::PipeDomain>,
    reader_module: &str,
    net: &str,
    actual: Option<&str>,
    wait: u32,
) -> Option<String> {
    if let Some(d) = domain {
        if let Some(n) = d.accept {
            if n >= wait {
                return Some(format!(
                    "throughput {} accept={n} ({wait}-cycle wait within the domain's tolerance)",
                    d.name
                ));
            }
        }
        if let Some(rdy) = &d.ready {
            return Some(format!(
                "elastic protocol {} ready={rdy} (the handshake absorbs the {wait}-cycle wait)",
                d.name
            ));
        }
        if let Some(c) = contract {
            if c.replicable.iter().any(|r| r == &d.name) {
                return Some(format!(
                    "replicate {} (a caller that does not need this result may take its own copy)",
                    d.name
                ));
            }
        }
    }
    // The caller module's own declaration about the net it reads.
    let _ = staged;
    let async_cycles = design
        .modules
        .values()
        .find(|m| m.name == reader_module)
        .and_then(crate::pipe_contract::resolve)
        .and_then(|k| {
            actual
                .and_then(|a| k.async_reads.get(a).copied())
                .or_else(|| k.async_reads.get(net).copied())
        });
    if async_cycles.is_some_and(|n| n >= wait) {
        return Some(format!(
            "`{reader_module}` declares `async … cycles={}` on this read",
            async_cycles.unwrap_or(0)
        ));
    }
    None
}

/// `file:line` of the `svt-pipe: cycle` pragma in `module` that binds
/// `lhs` as its q/d/hold — the recurrence a `drag` reader sits on.
fn cycle_loc_of(module: &TimingModule, lhs: &str) -> Option<String> {
    module
        .pipe_pragmas
        .iter()
        .find(|p| {
            p.kind == "cycle"
                && p.args.iter().any(|(k, v)| {
                    matches!(k.as_str(), "q" | "d" | "hold") && root(v) == lhs
                })
        })
        .map(|p| format!("{}:{}", p.loc.file, p.loc.start_line))
}

/// Reader class: the stage's `class` pragma wins; then recurrence; then
/// the readiness heuristic; else `value`.
fn classify(
    pragma_class: Option<&str>,
    kind: &str,
    lhs: &str,
    reader_cycle_names: &BTreeSet<String>,
) -> (String, String) {
    if let Some(c) = pragma_class {
        return (c.to_string(), "pragma".to_string());
    }
    if kind == "recurrence" || reader_cycle_names.contains(lhs) {
        return ("decision".to_string(), "recurrence".to_string());
    }
    if looks_decision(lhs) {
        return ("decision".to_string(), "heuristic".to_string());
    }
    ("value".to_string(), "default".to_string())
}

/// Latency-class / wakeup vocabulary that makes a `spec-wakeup` cover's
/// precondition visible in the module (`hyp_lat_class`, `LAT_NONSPEC`,
/// `alloc_lat`, `wake_cnt`, …).
fn spec_wakeup_visible(m: &TimingModule) -> bool {
    let has_tok = |s: &str| {
        let l = s.to_ascii_lowercase();
        ["lat_", "_lat", ".lat", "wake_", "wk_", "nonspec", "rearm", "re_arm"]
            .iter()
            .any(|t| l.contains(t))
    };
    m.ports.iter().any(|p| has_tok(&p.name))
        || m.nodes.values().any(|n| {
            n.lhs.as_deref().is_some_and(&has_tok)
                || n.rhs.as_deref().is_some_and(&has_tok)
                || n.rhs_expr.as_ref().is_some_and(|e| {
                    let mut hit = false;
                    e.walk_idents(&mut |i| {
                        hit |= has_tok(i);
                    });
                    hit
                })
        })
}

/// Registers driven (NBA) inside the stage `in_stage`.
fn regs_in_stage(
    m: &TimingModule,
    in_stage: &dyn Fn(&crate::ir::NodeId) -> bool,
) -> BTreeSet<String> {
    m.nodes
        .values()
        .filter(|n| n.assign_kind.is_seq_def() && in_stage(&n.id))
        .filter_map(|n| {
            n.lhs
                .as_deref()
                .and_then(TimingModule::root_ident)
                .map(str::to_string)
        })
        .collect()
}

/// True when `e` contains an index/select whose base net is in `regs` —
/// `state_q <= table_q[next_idx]` is the read-ahead signature.
fn expr_indexes_reg(e: &crate::expr::Expr, regs: &BTreeSet<String>) -> bool {
    use crate::expr::Expr;
    match e {
        Expr::Index { base, index } => {
            let base_is_reg = match base.as_ref() {
                Expr::Ident { name } => regs.contains(root(name)),
                _ => {
                    let mut hit = false;
                    base.walk_idents(&mut |i| {
                        hit |= regs.contains(root(i));
                    });
                    hit
                }
            };
            base_is_reg || expr_indexes_reg(base, regs) || expr_indexes_reg(index, regs)
        }
        Expr::Unary { arg, .. } => expr_indexes_reg(arg, regs),
        Expr::PartSelect { left, right, .. } => {
            expr_indexes_reg(left, regs) || expr_indexes_reg(right, regs)
        }
        Expr::Binary { left, right, .. } => {
            expr_indexes_reg(left, regs) || expr_indexes_reg(right, regs)
        }
        Expr::Ternary {
            cond,
            then_e,
            else_e,
        } => {
            expr_indexes_reg(cond, regs)
                || expr_indexes_reg(then_e, regs)
                || expr_indexes_reg(else_e, regs)
        }
        Expr::Concat { parts } => parts.iter().any(|p| expr_indexes_reg(p, regs)),
        Expr::Replicate { count, body } => {
            expr_indexes_reg(count, regs) || expr_indexes_reg(body, regs)
        }
        Expr::Call { args, .. } => args.iter().any(|a| expr_indexes_reg(a, regs)),
        Expr::Ident { .. } | Expr::Literal { .. } | Expr::Opaque { .. } => false,
    }
}

/// `read-ahead` precondition: the stage contains a register whose D is an
/// indexed read of another register inside the same stage (the table read
/// produced one cycle ahead of its use).
fn read_ahead_visible(
    m: &TimingModule,
    in_stage: &dyn Fn(&crate::ir::NodeId) -> bool,
) -> bool {
    let regs = regs_in_stage(m, in_stage);
    m.nodes.values().any(|n| {
        n.assign_kind.is_seq_def()
            && in_stage(&n.id)
            && (n.rhs_expr
                .as_ref()
                .is_some_and(|e| expr_indexes_reg(e, &regs))
                || n.rhs.as_deref().is_some_and(|rhs| {
                    // Text fallback: `ident[` where the base is a stage reg.
                    let bytes = rhs.as_bytes();
                    let mut i = 0;
                    let mut found = false;
                    while i < bytes.len() {
                        if bytes[i] == b'[' {
                            let mut j = i;
                            while j > 0
                                && (bytes[j - 1].is_ascii_alphanumeric()
                                    || bytes[j - 1] == b'_'
                                    || bytes[j - 1] == b'$')
                            {
                                j -= 1;
                            }
                            if j < i && regs.contains(&rhs[j..i]) {
                                found = true;
                                break;
                            }
                        }
                        i += 1;
                    }
                    found
                }))
    })
}

/// Validate the declared `absorb` cover's precondition against the IR.
/// Returns `true` when the precondition is visible/checkable; `false`
/// raises an `unverified-cover` finding.
fn cover_verified(
    m: &TimingModule,
    in_stage: &dyn Fn(&crate::ir::NodeId) -> bool,
    ab: &crate::stage_pragma::StageAbsorb,
) -> bool {
    match ab.by.as_str() {
        "spec-wakeup" => spec_wakeup_visible(m),
        "read-ahead" => read_ahead_visible(m, in_stage),
        "elastic" => crate::pipe_contract::resolve(m)
            .is_some_and(|c| c.domains.iter().any(|d| d.ready.is_some())),
        "replicate" => crate::pipe_contract::resolve(m).is_some_and(|c| !c.replicable.is_empty()),
        "async" => crate::pipe_contract::resolve(m).is_some_and(|c| !c.async_reads.is_empty()),
        "throughput" => crate::pipe_contract::resolve(m)
            .is_some_and(|c| c.domains.iter().any(|d| d.accept.is_some())),
        _ => false,
    }
}

/// Bubble-up analysis for every module that declares `svt-stage` regions.
pub fn stage_bubbles(design: &TimingDesign) -> Vec<StageBubble> {
    let mut out = Vec::new();
    for m in design.modules.values() {
        if m.stage_decls.stages.is_empty() {
            continue;
        }
        let smap = stage_map(m);
        let stage_of = |id: &crate::ir::NodeId| -> Option<String> {
            smap.get(id).cloned().flatten()
        };
        let m_cycle = cycle_names(m);
        let m_contract = crate::pipe_contract::resolve(m);
        let output_ports: BTreeSet<&str> = m
            .ports
            .iter()
            .filter(|p| p.direction == "output" || p.direction == "inout")
            .map(|p| root(&p.name))
            .collect();
        for st in &m.stage_decls.stages {
            let in_stage = |id: &crate::ir::NodeId| stage_of(id).as_deref() == Some(st.name.as_str());
            // Output nets: driven inside S, read outside S (in-module
            // readers in other stages) or an output port (parent readers).
            let mut output_nets: BTreeSet<String> = BTreeSet::new();
            for n in m.nodes.values() {
                if !in_stage(&n.id) {
                    continue;
                }
                let Some(net) = n.lhs.as_deref().and_then(TimingModule::root_ident) else {
                    continue;
                };
                let read_outside = m
                    .nodes
                    .values()
                    .any(|r| !in_stage(&r.id) && reads_root(m, r, net));
                if read_outside || output_ports.contains(net) {
                    output_nets.insert(net.to_string());
                }
            }
            // A flop capture inside S whose Q reaches an output net through
            // the stage's own combinational nodes also publishes: the
            // register sits in the stage's decision cone even when no node
            // outside S reads Q directly (a whole-region state recurrence).
            let reaches_output = |q: &str| -> bool {
                let mut frontier: BTreeSet<String> = BTreeSet::new();
                frontier.insert(q.to_string());
                loop {
                    let mut grew = false;
                    for n in m.nodes.values() {
                        if !in_stage(&n.id) {
                            continue;
                        }
                        let Some(lhs) = n.lhs.as_deref().and_then(TimingModule::root_ident)
                        else {
                            continue;
                        };
                        if frontier.contains(lhs) {
                            continue;
                        }
                        if frontier.iter().any(|f| reads_root(m, n, f)) {
                            frontier.insert(lhs.to_string());
                            grew = true;
                        }
                    }
                    if !grew {
                        break;
                    }
                }
                frontier
                    .iter()
                    .any(|f| output_nets.contains(f) || output_ports.contains(f.as_str()))
            };
            // Publishing register: a flop capture inside S whose Q is read
            // by a node outside S, or that reaches an output net through S.
            let publishes = m.nodes.values().any(|n| {
                n.assign_kind.is_seq_def()
                    && in_stage(&n.id)
                    && n
                        .lhs
                        .as_deref()
                        .and_then(TimingModule::root_ident)
                        .is_some_and(|q| {
                            output_ports.contains(q)
                                || reaches_output(q)
                                || m.nodes.values().any(|r| {
                                    !in_stage(&r.id) && reads_root(m, r, q)
                                })
                        })
            });
            let extra = st.cycles.saturating_sub(1) + st.window + u32::from(publishes);
            if extra == 0 {
                continue;
            }
            let pragma_class = m.stage_decls.classes.get(&st.name).map(String::as_str);
            let mut readers: Vec<BubbleReader> = Vec::new();
            let mut collide_set: BTreeSet<String> = BTreeSet::new();
            for net in &output_nets {
                let domain = m_contract.as_ref().and_then(|c| domain_of_net(c, net));
                let net_rec = net_is_recurrence(m, net);
                // In-module readers in other stages.
                for n in m.nodes.values() {
                    if in_stage(&n.id) || !reads_root(m, n, net) {
                        continue;
                    }
                    let lhs = n.lhs.as_deref().map(root).unwrap_or("");
                    if lhs.is_empty() || lhs == net {
                        continue;
                    }
                    let mut kind = if n.assign_kind.is_seq_def() {
                        "flop"
                    } else if output_ports.contains(lhs) {
                        "output"
                    } else {
                        "comb"
                    };
                    let recurrence = net_rec || m_cycle.contains(lhs);
                    if recurrence {
                        kind = "recurrence";
                    }
                    let wait = extra + u32::from(recurrence);
                    let (class, class_source) =
                        classify(pragma_class, kind, lhs, &m_cycle);
                    let abs = absorbed_by(
                        design, m,
                        m_contract.as_ref(),
                        domain,
                        &m.name,
                        net,
                        None,
                        wait,
                    );
                    if class_source == "recurrence" {
                        if let Some(l) = cycle_loc_of(m, lhs) {
                            collide_set.insert(l);
                        }
                    }
                    readers.push(BubbleReader {
                        module: m.name.clone(),
                        instance: String::new(),
                        lhs: lhs.to_string(),
                        line: n.loc.start_line,
                        kind: kind.to_string(),
                        wait_cycles: wait,
                        class,
                        class_source,
                        absorbed: abs.is_some(),
                        absorbed_by: abs,
                    });
                }
                // Parent-side readers when the net is an output port.
                let Some(co) = carry_over_for_stage(design, m, net, Some(&st.name)) else {
                    continue;
                };
                for consumer in &co.consumers {
                    let parent_mod = design
                        .modules
                        .values()
                        .find(|pm| pm.name == consumer.parent);
                    let p_cycle = parent_mod.map(cycle_names).unwrap_or_default();
                    let p_outputs: BTreeSet<&str> = parent_mod
                        .map(|pm| {
                            pm.ports
                                .iter()
                                .filter(|p| p.direction == "output" || p.direction == "inout")
                                .map(|p| root(&p.name))
                                .collect()
                        })
                        .unwrap_or_default();
                    let recurrence = net_rec || consumer.feeds_back;
                    for r in &consumer.readers {
                        let lhs = r.lhs.as_str();
                        let rec_r = recurrence || p_cycle.contains(lhs);
                        let mut kind = r.kind.clone();
                        if rec_r {
                            kind = "recurrence".to_string();
                        }
                        let wait = extra + u32::from(rec_r);
                        let (class, class_source) =
                            classify(pragma_class, &kind, lhs, &p_cycle);
                        let abs = absorbed_by(
                            design,
                            m,
                            m_contract.as_ref(),
                            domain,
                            &consumer.parent,
                            net,
                            Some(&consumer.actual),
                            wait,
                        );
                        if class_source == "recurrence" {
                            if let Some(pm) = parent_mod {
                                if let Some(l) = cycle_loc_of(pm, lhs) {
                                    collide_set.insert(l);
                                }
                            }
                        }
                        readers.push(BubbleReader {
                            module: consumer.parent.clone(),
                            instance: consumer.instance.clone(),
                            lhs: lhs.to_string(),
                            line: r.line,
                            kind,
                            wait_cycles: wait,
                            class,
                            class_source,
                            absorbed: abs.is_some(),
                            absorbed_by: abs,
                        });
                    }
                    // One hop past a combinational parent reader: the flop
                    // that samples the derived net waits the same cycles.
                    if let Some(pm) = parent_mod {
                        let comb_nets: Vec<&str> = consumer
                            .readers
                            .iter()
                            .filter(|r| r.kind != "flop" && !r.lhs.is_empty())
                            .map(|r| r.lhs.as_str())
                            .collect();
                        for n in pm.nodes.values() {
                            if !n.assign_kind.is_seq_def() {
                                continue;
                            }
                            if !comb_nets.iter().any(|cn| reads_root(pm, n, cn)) {
                                continue;
                            }
                            let lhs = n.lhs.as_deref().map(root).unwrap_or("");
                            if lhs.is_empty() {
                                continue;
                            }
                            let rec2 = recurrence || p_cycle.contains(lhs);
                            let kind = if rec2 { "recurrence" } else { "flop" };
                            let wait = extra + u32::from(rec2);
                            let (class, class_source) =
                                classify(pragma_class, kind, lhs, &p_cycle);
                            let abs = absorbed_by(
                                design,
                                m,
                                m_contract.as_ref(),
                                domain,
                                &pm.name,
                                net,
                                Some(&consumer.actual),
                                wait,
                            );
                            if class_source == "recurrence" {
                                if let Some(l) = cycle_loc_of(pm, lhs) {
                                    collide_set.insert(l);
                                }
                            }
                            readers.push(BubbleReader {
                                module: pm.name.clone(),
                                instance: consumer.instance.clone(),
                                lhs: lhs.to_string(),
                                line: n.loc.start_line,
                                kind: kind.to_string(),
                                wait_cycles: wait,
                                class,
                                class_source,
                                absorbed: abs.is_some(),
                                absorbed_by: abs,
                            });
                        }
                    }
                    let _ = p_outputs;
                }
            }
            readers.sort_by(|a, b| {
                a.module
                    .cmp(&b.module)
                    .then(a.instance.cmp(&b.instance))
                    .then(a.lhs.cmp(&b.lhs))
                    .then(a.line.cmp(&b.line))
            });
            readers.dedup_by(|a, b| {
                a.module == b.module && a.instance == b.instance && a.lhs == b.lhs && a.line == b.line
            });
            let non_absorbed: Vec<&BubbleReader> =
                readers.iter().filter(|r| !r.absorbed).collect();
            let drags: Vec<&&BubbleReader> = non_absorbed
                .iter()
                .filter(|r| r.class == "decision")
                .collect();
            let worst = non_absorbed
                .iter()
                .map(|r| r.wait_cycles)
                .max()
                .unwrap_or(0);
            // A declared `svt-stage: absorb` cover legitimizes a
            // decision-class register: verdict `absorbed`, but the readers
            // stay listed verbatim and an uncheckable precondition raises
            // `unverified-cover`.
            let absorb_decl = m
                .stage_decls
                .absorbs
                .iter()
                .find(|a| a.stage == st.name);
            let mut findings: Vec<String> = Vec::new();
            let cover = absorb_decl.map(|ab| {
                let verified = cover_verified(
                    m,
                    &|id: &crate::ir::NodeId| in_stage(id),
                    ab,
                );
                if !verified {
                    findings.push(format!(
                        "unverified-cover: `{by}` cover precondition not visible in the IR (cond: {cond})",
                        by = ab.by,
                        cond = ab.cond.clone().unwrap_or_else(|| "-".to_string())
                    ));
                }
                StageCover {
                    by: ab.by.clone(),
                    cond: ab.cond.clone(),
                    verified,
                }
            });
            let (verdict, rationale) = if let Some(c) = &cover {
                (
                    "absorbed".to_string(),
                    format!(
                        "stage {s} adds {extra} cycle(s) in a readiness/next-address cone covered by a declared `{by}` cover (cond: {cond}); {} reader(s) listed verbatim, worst wait {worst}",
                        readers.len(),
                        s = st.name,
                        by = c.by,
                        cond = c.cond.clone().unwrap_or_else(|| "-".to_string()),
                    ),
                )
            } else if readers.is_empty() {
                (
                    "covered".to_string(),
                    format!(
                        "stage {s} adds {extra} cycle(s); no reader outside the stage waits on its nets",
                        s = st.name
                    ),
                )
            } else if non_absorbed.is_empty() {
                (
                    "absorbed".to_string(),
                    format!(
                        "stage {s} adds {extra} cycle(s); every reader is absorbed by a declared throughput/async/replicate/elastic contract",
                        s = st.name
                    ),
                )
            } else if !drags.is_empty() {
                (
                    "drag".to_string(),
                    format!(
                        "stage {s} adds {extra} cycle(s) in a readiness/next-address cone: it inserts a bubble between dependent decisions; other issue ports cannot wake the dependent one sooner ({} decision reader(s), worst wait {worst})",
                        drags.len(),
                        s = st.name
                    ),
                )
            } else {
                (
                    "covered".to_string(),
                    format!(
                        "stage {s} adds {extra} cycle(s) on a value path: out-of-order issue overlaps the wait with independent work; the dependent use still waits the full depth ({} reader(s), worst wait {worst})",
                        non_absorbed.len(),
                        s = st.name
                    ),
                )
            };
            // A drag collides with the module's `svt-pipe: cycle` lines:
            // report every declared recurrence the stage inserts latency on.
            let mut collides = Vec::new();
            if verdict == "drag" {
                let mut names: BTreeSet<String> = output_nets.clone();
                names.extend(drags.iter().map(|r| r.lhs.clone()));
                if let Some(c) = &m_contract {
                    for p in &m.pipe_pragmas {
                        if p.kind != "cycle" {
                            continue;
                        }
                        let hit = c.domains.iter().any(|d| {
                            d.name.as_str() == p.domain.as_deref().unwrap_or("")
                                && d.cycle.as_ref().is_some_and(|s| {
                                    names.contains(root(&s.q))
                                        || names.contains(root(&s.d))
                                        || names.contains(root(&s.hold))
                                })
                        });
                        if hit {
                            collides.push(format!("{}:{}", p.loc.file, p.loc.start_line));
                        }
                    }
                }
                collides.extend(collide_set.iter().cloned());
                if collides.is_empty() {
                    for p in &m.pipe_pragmas {
                        if p.kind == "cycle" {
                            collides.push(format!("{}:{}", p.loc.file, p.loc.start_line));
                        }
                    }
                }
                collides.sort();
                collides.dedup();
            }
            out.push(StageBubble {
                module: m.name.clone(),
                stage: st.name.clone(),
                extra_cycles: extra,
                output_nets: output_nets.into_iter().collect(),
                readers,
                verdict,
                rationale,
                collides,
                cover,
                findings,
            });
        }
    }
    out.sort_by(|a, b| a.module.cmp(&b.module).then(a.stage.cmp(&b.stage)));
    out
}

/// The `--stages` bubble-up line for one stage row, or `None` when the
/// stage adds no cycles / declares no bubble report.
pub fn bubble_line(b: &StageBubble) -> String {
    let drags: Vec<String> = b
        .readers
        .iter()
        .filter(|r| !r.absorbed && r.class == "decision")
        .map(|r| {
            let where_ = if r.instance.is_empty() {
                r.module.clone()
            } else {
                format!("{}.{}", r.module, r.instance)
            };
            format!("{where_} {} (line {}, {})", r.lhs, r.line, r.kind)
        })
        .collect();
    let worst = b
        .readers
        .iter()
        .map(|r| r.wait_cycles)
        .max()
        .unwrap_or(0);
    let mut s = format!(
        "      bubble-up: {} — {} reader(s), worst wait {} cycle(s)",
        b.verdict,
        b.readers.len(),
        worst
    );
    if let Some(c) = &b.cover {
        s.push_str(&format!(
            "; cover by {} (cond: {}){}",
            c.by,
            c.cond.as_deref().unwrap_or("-"),
            if c.verified { "" } else { " [unverified]" }
        ));
    }
    if !drags.is_empty() {
        let label = if b.verdict == "drag" {
            "drag readers"
        } else {
            "decision readers"
        };
        s.push_str(&format!("; {label}: {}", drags.join("; ")));
    }
    for f in &b.findings {
        s.push_str(&format!("; finding: {f}"));
    }
    if !b.collides.is_empty() {
        s.push_str(&format!("; collides with `svt-pipe: cycle` at {}", b.collides.join(", ")));
    }
    s
}



#[cfg(test)]
mod tests {
    use super::*;
    use crate::cost_table::default_fo4_v1_embedded;
    use crate::ir::TimingTarget;
    use crate::lower::{analyze_files, LowerOptions};
    use crate::parse::ParseOptions;
    use std::path::PathBuf;

    fn analyze_fixture() -> crate::lower::AnalyzeOutput {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../fixtures/auto_correct/stage_bubbles.sv");
        let parse = ParseOptions::default();
        let mut opts = LowerOptions::default();
        opts.cost_model = default_fo4_v1_embedded();
        opts.target = TimingTarget::new(5000.0, 20.0, 0.2);
        analyze_files(&[path], &parse, &opts).expect("analyze stage_bubbles fixture")
    }

    #[test]
    fn classify_orders_pragma_recurrence_heuristic_default() {
        let cyc: BTreeSet<String> = ["state_d".to_string()].into_iter().collect();
        // (a) pragma wins over everything
        assert_eq!(
            classify(Some("value"), "flop", "issue_valid_o", &cyc).0,
            "value"
        );
        // (b) recurrence kind or a cycle-name LHS -> decision
        assert_eq!(
            classify(None, "recurrence", "x", &cyc),
            ("decision".into(), "recurrence".into())
        );
        assert_eq!(
            classify(None, "comb", "state_d", &cyc).0,
            "decision"
        );
        // (c) readiness vocabulary -> decision heuristic
        for lhs in ["issue_valid_o", "rdy_gnt", "grant_sel", "npc_next", "map_prd", "wake_q"] {
            assert_eq!(
                classify(None, "comb", lhs, &BTreeSet::new()),
                ("decision".into(), "heuristic".into()),
                "lhs={lhs}"
            );
        }
        // (d) everything else -> value
        assert_eq!(
            classify(None, "flop", "result_q", &BTreeSet::new()),
            ("value".into(), "default".into())
        );
    }

    #[test]
    fn fixture_verdicts_covered_drag_absorbed() {
        let out = analyze_fixture();
        let bubbles = stage_bubbles(&out.design);
        let get = |stage: &str| -> &StageBubble {
            bubbles
                .iter()
                .find(|b| b.module == "sb_child" && b.stage == stage)
                .unwrap_or_else(|| panic!("no bubble row for {stage}"))
        };
        // V1: class pragma value; the parent flop reader is covered.
        let v1 = get("V1");
        assert_eq!(v1.verdict, "covered");
        assert!(v1
            .readers
            .iter()
            .any(|r| r.module == "sb_parent" && r.lhs == "sink_q" && r.kind == "flop"
                && r.class == "value" && r.class_source == "pragma"));
        // R1: feeds the parent's cycle d -> drag with the cycle line.
        let r1 = get("R1");
        assert_eq!(r1.verdict, "drag");
        assert!(r1
            .readers
            .iter()
            .any(|r| r.lhs == "state_d" && r.kind == "recurrence"
                && r.class == "decision" && r.class_source == "recurrence"
                && r.wait_cycles == 2));
        assert!(r1.collides.iter().any(|l| l.contains("stage_bubbles.sv")),
            "collides={:?}", r1.collides);
        // D1: readiness heuristic on issue_valid_o -> drag.
        let d1 = get("D1");
        assert_eq!(d1.verdict, "drag");
        assert!(d1
            .readers
            .iter()
            .any(|r| r.lhs == "issue_valid_o" && r.class_source == "heuristic"));
        // E1: elastic `protocol … ready=` domain absorbs its reader.
        let e1 = get("E1");
        assert_eq!(e1.verdict, "absorbed");
        assert!(e1.readers.iter().all(|r| r.absorbed));
        assert!(e1
            .readers
            .iter()
            .any(|r| r.absorbed_by.as_deref().is_some_and(|a| a.contains("ready"))));
    }

    #[test]
    fn fixture_absorb_covers() {
        let out = analyze_fixture();
        let bubbles = stage_bubbles(&out.design);
        let get = |stage: &str| -> &StageBubble {
            bubbles
                .iter()
                .find(|b| b.module == "sb_child" && b.stage == stage)
                .unwrap_or_else(|| panic!("no bubble row for {stage}"))
        };
        // A1: declared `spec-wakeup` cover; the fixture has no
        // latency-class/wakeup state -> `absorbed` but `unverified-cover`.
        let a1 = get("A1");
        assert_eq!(a1.verdict, "absorbed");
        let c1 = a1.cover.as_ref().expect("A1 carries an absorb decl");
        assert_eq!(c1.by, "spec-wakeup");
        assert!(!c1.verified);
        assert!(a1
            .findings
            .iter()
            .any(|f| f.contains("unverified-cover")));
        // Decision readers are still listed verbatim.
        assert!(a1
            .readers
            .iter()
            .any(|r| r.class == "decision" && r.lhs == "grant_a1_o"),
            "readers: {:?}", a1.readers.iter().map(|r| format!("{}.{} {} ({})", r.module, r.instance, r.lhs, r.class)).collect::<Vec<_>>());
        // A2: declared `read-ahead` cover; `rd2_q <= tbl_q[a_i[1:0]]` is a
        // register whose D is indexed by a stage register -> verified.
        let a2 = get("A2");
        assert_eq!(a2.verdict, "absorbed");
        let c2 = a2.cover.as_ref().expect("A2 carries an absorb decl");
        assert_eq!(c2.by, "read-ahead");
        assert!(c2.verified, "findings: {:?}", a2.findings);
        assert!(a2.findings.is_empty());
    }
}
