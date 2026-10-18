// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Re-pipelining contracts declared in the RTL (ALGORITHMS-EXPERTS A123).
//!
//! A register cut (`InsertReg`) adds a cycle. For a pure datapath that is
//! the whole story; for an operation in flight it is not — the cut data must
//! travel with its *valid*, its *id*, be *killed* by the cancellation the
//! core raises in later cycles, be cleared by *flush*, and bring its
//! side-band (operator, destination) along, as the two-stage multiplier's
//! wrapper does by hand (A115). The IR cannot infer those roles reliably,
//! so the designer declares them in-file, next to the logic, as comment
//! pragmas the parser never sees — the same mechanism as `translate_off`
//! fences and `$onehot0` facts: a fact of the source that the transform
//! treats as a proof obligation and serializes back into the emitted file.
//!
//! ```text
//! // svt-pipe: protocol <dom> valid=<sig> id=<sig> kill=<expr with $id> [flush=<sig>]
//! // svt-pipe: carry <dom> <sig>[,<sig>…]              side-band that rides with the data
//! // svt-pipe: result <dom> valid=<sig> id=<sig>        the stage's consumer-side signals
//! // svt-pipe: cut-ok [<dom>]                           next assignment: a stage may be cut here
//! // svt-pipe: no-cut                                   next assignment: never cut (handshake, side effect)
//! // svt-pipe: require-contract                         module: only pragma-permitted cuts
//! ```
//!
//! Resolution checks every named signal against the module's declarations
//! and ports and refuses a contract it cannot bind; `$id` must appear in
//! `kill`. A cut whose LHS is under `no-cut` is refused; under
//! `require-contract` only `cut-ok` anchors are cut; a cut inside a domain
//! (its node reads the domain's valid or id, or the anchor names the
//! domain) carries the domain's bundle.

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

use crate::ir::{AssignKind, IrNode, TimingModule};

/// A resolved protocol domain.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PipeDomain {
    /// Domain name.
    pub name: String,
    /// Valid of the operation entering the cone.
    pub valid: String,
    /// Transaction / tag identifying the operation.
    pub id: String,
    /// Kill expression with `$id` standing for the operation's id.
    pub kill: String,
    /// Flush signal, when declared.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub flush: Option<String>,
    /// Signals carried in lockstep with the data.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub carry: Vec<String>,
    /// Consumer-side valid / id assignments to rewire onto the last stage.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result_valid: Option<String>,
    /// Consumer-side id assignment to rewire onto the last stage.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result_id: Option<String>,
}

impl PipeDomain {
    /// `kill` with `$id` replaced by `id_expr`, parenthesised.
    pub fn kill_for(&self, id_expr: &str) -> String {
        format!("({})", self.kill.replace("$id", id_expr))
    }
}

/// Everything the pragmas of one module declare.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct PipeContract {
    /// Protocol domains by name.
    pub domains: Vec<PipeDomain>,
    /// LHS roots a stage may be cut at, with the domain each names (if any)
    /// and the line of the anchored statement (a cut on an expression spine
    /// node of that statement inherits the permission).
    pub cut_ok: Vec<(String, Option<String>, u32)>,
    /// LHS roots that must never be cut.
    pub no_cut: BTreeSet<String>,
    /// Only `cut_ok` anchors may be cut.
    pub require_contract: bool,
    /// Pragmas that could not be bound, with the reason (never silent).
    pub rejected: Vec<String>,
}

/// Verdict for a cut at an LHS root.
#[derive(Debug, Clone, PartialEq)]
pub enum CutPermission {
    /// No pragma speaks about this cut.
    Unconstrained,
    /// Permitted here; carries this domain's bundle when `Some`.
    Allowed(Option<PipeDomain>),
    /// `no-cut`, or `require-contract` without a `cut-ok`.
    Forbidden(String),
}

fn name_declared(module: &TimingModule, name: &str) -> bool {
    let root = TimingModule::root_ident(name).unwrap_or(name);
    module.decls.iter().any(|d| d.name == root) || module.ports.iter().any(|p| p.name == root)
}

fn arg<'a>(args: &'a [(String, String)], key: &str) -> Option<&'a str> {
    args.iter().find(|(k, _)| k == key).map(|(_, v)| v.as_str())
}

/// The assignment the pragma anchors to: the first node that starts after
/// the pragma line, within three lines (comments between are fine).
fn anchor_lhs(module: &TimingModule, line: u32) -> Option<(String, u32)> {
    let n = module
        .nodes
        .values()
        .filter(|n| n.loc.start_line > line && n.loc.start_line <= line + 3)
        .min_by_key(|n| n.loc.start_line)?;
    let lhs = n.lhs.as_deref().and_then(TimingModule::root_ident)?;
    Some((lhs.to_string(), n.loc.start_line))
}

/// Resolve the module's pragmas. `None` when the module declares none.
pub fn resolve(module: &TimingModule) -> Option<PipeContract> {
    if module.pipe_pragmas.is_empty() {
        return None;
    }
    let mut c = PipeContract::default();
    for p in &module.pipe_pragmas {
        let at = format!("{}:{}", p.loc.file, p.loc.start_line);
        match p.kind.as_str() {
            "protocol" => {
                let Some(name) = p.domain.clone() else {
                    c.rejected
                        .push(format!("{at}: protocol without a domain name"));
                    continue;
                };
                let (Some(valid), Some(id), Some(kill)) = (
                    arg(&p.args, "valid"),
                    arg(&p.args, "id"),
                    arg(&p.args, "kill"),
                ) else {
                    c.rejected
                        .push(format!("{at}: protocol {name} needs valid=, id= and kill="));
                    continue;
                };
                if !kill.contains("$id") {
                    c.rejected
                        .push(format!("{at}: protocol {name}: kill= must use $id"));
                    continue;
                }
                let flush = arg(&p.args, "flush").map(str::to_string);
                let mut missing = Vec::new();
                for s in [valid, id].into_iter().chain(flush.as_deref()) {
                    if !name_declared(module, s) {
                        missing.push(s.to_string());
                    }
                }
                let kill_bound = kill.replace("$id", "0");
                let mut kill_idents = Vec::new();
                crate::expr::Expr::parse(&kill_bound)
                    .walk_idents(&mut |i| kill_idents.push(i.to_string()));
                for i in &kill_idents {
                    if !name_declared(module, i) {
                        missing.push(i.clone());
                    }
                }
                if !missing.is_empty() {
                    c.rejected.push(format!(
                        "{at}: protocol {name}: unknown signal(s) {}",
                        missing.join(", ")
                    ));
                    continue;
                }
                c.domains.push(PipeDomain {
                    name,
                    valid: valid.to_string(),
                    id: id.to_string(),
                    kill: kill.to_string(),
                    flush,
                    carry: Vec::new(),
                    result_valid: None,
                    result_id: None,
                });
            }
            "carry" | "result" => {
                let Some(name) = p.domain.clone() else {
                    c.rejected
                        .push(format!("{at}: {} without a domain name", p.kind));
                    continue;
                };
                let Some(d) = c.domains.iter_mut().find(|d| d.name == name) else {
                    c.rejected.push(format!(
                        "{at}: {} names unknown domain {name} (declare protocol first)",
                        p.kind
                    ));
                    continue;
                };
                if p.kind == "carry" {
                    let unknown: Vec<_> = p
                        .words
                        .iter()
                        .filter(|w| !name_declared(module, w))
                        .cloned()
                        .collect();
                    if !unknown.is_empty() {
                        c.rejected.push(format!(
                            "{at}: carry {name}: unknown signal(s) {}",
                            unknown.join(", ")
                        ));
                        continue;
                    }
                    d.carry.extend(p.words.iter().cloned());
                } else {
                    let (rv, rid) = (arg(&p.args, "valid"), arg(&p.args, "id"));
                    for s in [rv, rid].into_iter().flatten() {
                        if !name_declared(module, s) {
                            c.rejected
                                .push(format!("{at}: result {name}: unknown signal {s}"));
                        }
                    }
                    d.result_valid = rv.map(str::to_string);
                    d.result_id = rid.map(str::to_string);
                }
            }
            "cut-ok" => {
                let lhs = arg(&p.args, "on")
                    .map(|l| (l.to_string(), 0))
                    .or_else(|| anchor_lhs(module, p.loc.start_line));
                match lhs {
                    Some((l, line)) => c.cut_ok.push((l, p.domain.clone(), line)),
                    None => c
                        .rejected
                        .push(format!("{at}: cut-ok has no assignment to anchor to")),
                }
            }
            "no-cut" => {
                let lhs = arg(&p.args, "on")
                    .map(|l| (l.to_string(), 0))
                    .or_else(|| anchor_lhs(module, p.loc.start_line));
                match lhs {
                    Some((l, _)) => {
                        c.no_cut.insert(l);
                    }
                    None => c
                        .rejected
                        .push(format!("{at}: no-cut has no assignment to anchor to")),
                }
            }
            "require-contract" => c.require_contract = true,
            other => c
                .rejected
                .push(format!("{at}: unknown svt-pipe kind `{other}`")),
        }
    }
    for (lhs, dom, _) in &c.cut_ok {
        if let Some(d) = dom {
            if !c.domains.iter().any(|x| &x.name == d) {
                c.rejected
                    .push(format!("cut-ok on {lhs} names unknown domain {d}"));
            }
        }
    }
    Some(c)
}

/// Does `node` read the domain's valid or id (directly, or through a guard)?
fn node_in_domain(module: &TimingModule, node: &IrNode, d: &PipeDomain) -> bool {
    let mut reads = BTreeSet::new();
    if let Some(e) = &node.rhs_expr {
        e.walk_idents(&mut |i| {
            reads.insert(TimingModule::root_ident(i).unwrap_or(i).to_string());
        });
    }
    for g in module.guards.get(&node.id).into_iter().flatten() {
        crate::expr::Expr::parse(g.trim_start_matches('^')).walk_idents(&mut |i| {
            reads.insert(TimingModule::root_ident(i).unwrap_or(i).to_string());
        });
    }
    let root = |s: &str| TimingModule::root_ident(s).unwrap_or(s).to_string();
    reads.contains(&root(&d.valid)) || reads.contains(&root(&d.id))
}

/// Permission for a cut at `node`. A node of a statement under a `cut-ok`
/// (by LHS root, or by line for an expression-spine node the planner split
/// out of that statement) is permitted; `no-cut` forbids; a module that
/// requires a contract forbids everything else.
pub fn cut_permission(
    module: &TimingModule,
    contract: &PipeContract,
    node: &IrNode,
) -> CutPermission {
    let lhs_root = node.lhs.as_deref().and_then(TimingModule::root_ident);
    let by_line = contract
        .cut_ok
        .iter()
        .find(|(_, _, line)| *line != 0 && *line == node.loc.start_line);
    let Some(lhs) = lhs_root.or_else(|| by_line.map(|(l, _, _)| l.as_str())) else {
        return if contract.require_contract {
            CutPermission::Forbidden("require-contract: cut has no LHS to anchor".into())
        } else {
            CutPermission::Unconstrained
        };
    };
    if contract.no_cut.contains(lhs) {
        return CutPermission::Forbidden(format!("no-cut on `{lhs}`"));
    }
    if let Some((_, dom, _)) = contract
        .cut_ok
        .iter()
        .find(|(l, _, line)| l == lhs || (*line != 0 && *line == node.loc.start_line))
    {
        let d = dom
            .as_ref()
            .and_then(|n| contract.domains.iter().find(|d| &d.name == n))
            .or_else(|| {
                contract
                    .domains
                    .iter()
                    .find(|d| node_in_domain(module, node, d))
            })
            .cloned();
        return CutPermission::Allowed(d);
    }
    if contract.require_contract {
        return CutPermission::Forbidden(format!("require-contract: `{lhs}` has no cut-ok"));
    }
    match contract
        .domains
        .iter()
        .find(|d| node_in_domain(module, node, d))
    {
        Some(d) => CutPermission::Allowed(Some(d.clone())),
        None => CutPermission::Unconstrained,
    }
}

/// Alignment of a carried cut plan (A123). `cut_lhs` are the LHS roots of
/// the cuts in path order (first stage first); `readers` are, per cut, the
/// LHS roots the node right after that cut reads. A node after cut *i* may
/// read the LHS of cut *i − 1* (the chain) but no earlier cut's: that value
/// would arrive with fewer stages than the bundle, so the stage would mix
/// operations. Such a plan is refused here rather than balanced — inserting
/// balance registers on side paths is the next mechanism, not this one.
pub fn alignment_violation(cut_lhs: &[String], readers: &[BTreeSet<String>]) -> Option<String> {
    for (i, reads) in readers.iter().enumerate() {
        for (j, earlier) in cut_lhs.iter().enumerate() {
            if j + 1 < i && reads.contains(earlier) {
                return Some(format!(
                    "stage {} reads `{earlier}` (cut {}) past stage {}: side path needs {} balance register(s)",
                    i + 1,
                    j + 1,
                    j + 2,
                    i - j - 1
                ));
            }
        }
    }
    None
}

/// The bundle one stage of a domain carries, as the emitter serializes it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PipeStage {
    /// Domain name.
    pub domain: String,
    /// Stage number within this cut plan (1-based).
    pub stage: u32,
    /// Valid / id / carried sources this stage samples (the previous stage's
    /// nets for stage > 1, the domain's signals for stage 1).
    pub valid_src: String,
    /// Id source this stage samples.
    pub id_src: String,
    /// Carried sources this stage samples, in `carry` order.
    pub carry_src: Vec<String>,
    /// The carried signals' original names, in `carry` order (the staged
    /// net of each is `carry_net(pipe, sig)` at every stage).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub carry_sigs: Vec<String>,
    /// Declared width of the id, when the resolver knows it: the staged id
    /// is then a plain `logic [W-1:0]` declared at the module header, where
    /// `type(<signal>)` of a later-declared variable would be illegal.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id_width: Option<u32>,
    /// Declared widths of the carried signals, in `carry` order (`None`
    /// falls back to `type()`, legal only for ports).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub carry_widths: Vec<Option<u32>>,
    /// `kill` with `$id` bound to `id_src`.
    pub kill_expr: String,
    /// Flush signal, when declared.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub flush: Option<String>,
    /// Consumer-side rewires: (origin line of the result assign, old ident, new ident).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub consumer_rewires: Vec<(u32, String, String)>,
    /// Rewires inside this stage's data feed: a carried signal read by the
    /// stage's logic must be the previous stage's carried copy (stage 1
    /// reads the live signals, same cycle).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub feed_rewires: Vec<(String, String)>,
}

/// Staged net names for a pipe `name`.
pub fn stage_nets(name: &str) -> (String, String) {
    (format!("{name}_v"), format!("{name}_id"))
}

/// Carried net name for pipe `name` and carried signal `sig`.
pub fn carry_net(name: &str, sig: &str) -> String {
    format!("{name}_c_{}", sig.replace(['.', '[', ']'], "_"))
}

/// Build the stage bundle for pipe `name` of `domain`; `prev` is the
/// previous stage's pipe name when chaining.
pub fn stage_for(
    module: &TimingModule,
    domain: &PipeDomain,
    name: &str,
    stage: u32,
    prev: Option<&str>,
    width_of: &dyn Fn(&str) -> Option<u32>,
) -> PipeStage {
    let (valid_src, id_src, carry_src) = match prev {
        Some(p) => {
            let (v, i) = stage_nets(p);
            (v, i, domain.carry.iter().map(|c| carry_net(p, c)).collect())
        }
        None => (
            domain.valid.clone(),
            domain.id.clone(),
            domain.carry.clone(),
        ),
    };
    let (v_net, id_net) = stage_nets(name);
    let feed_rewires: Vec<(String, String)> = match prev {
        Some(p) => domain
            .carry
            .iter()
            .map(|c| (c.clone(), carry_net(p, c)))
            .collect(),
        None => Vec::new(),
    };
    let mut consumer_rewires = Vec::new();
    // The consumer-side assigns named by `result` read the staged valid
    // (killed again at use: a cancel in the consuming cycle must count), id
    // and carried signals instead of the domain's inputs.
    for target in [domain.result_valid.as_deref(), domain.result_id.as_deref()]
        .into_iter()
        .flatten()
    {
        for n in module.nodes.values() {
            if !matches!(
                n.assign_kind,
                AssignKind::Continuous | AssignKind::Blocking | AssignKind::Nonblocking
            ) {
                continue;
            }
            if n.lhs.as_deref().and_then(TimingModule::root_ident) != Some(target) {
                continue;
            }
            let line = n.loc.start_line;
            consumer_rewires.push((
                line,
                domain.valid.clone(),
                format!("({v_net} & ~{})", domain.kill_for(&id_net)),
            ));
            consumer_rewires.push((line, domain.id.clone(), id_net.clone()));
            for c in &domain.carry {
                consumer_rewires.push((line, c.clone(), carry_net(name, c)));
            }
        }
    }
    PipeStage {
        domain: domain.name.clone(),
        stage,
        kill_expr: domain.kill_for(&id_src),
        valid_src,
        id_src,
        carry_src,
        carry_sigs: domain.carry.clone(),
        id_width: width_of(&domain.id),
        carry_widths: domain.carry.iter().map(|c| width_of(c)).collect(),
        flush: domain.flush.clone(),
        consumer_rewires,
        feed_rewires,
    }
}

/// Reads a stage's logic may make (A123): its chain predecessor, the
/// domain's carried signals, the kill / flush signals, constants and loop
/// variables. Anything else of the operation read past stage 1 arrives
/// with the wrong age; the contract refuses unless it is declared `carry`.
pub fn foreign_reads(
    module: &TimingModule,
    domain: &PipeDomain,
    reads: &BTreeSet<String>,
    predecessor: Option<&str>,
    is_const: &dyn Fn(&str) -> bool,
) -> Vec<String> {
    let mut allowed: BTreeSet<String> = BTreeSet::new();
    let root = |s: &str| TimingModule::root_ident(s).unwrap_or(s).to_string();
    if let Some(p) = predecessor {
        allowed.insert(root(p));
    }
    for c in &domain.carry {
        allowed.insert(root(c));
    }
    allowed.insert(root(&domain.valid));
    allowed.insert(root(&domain.id));
    if let Some(f) = &domain.flush {
        allowed.insert(root(f));
    }
    crate::expr::Expr::parse(&domain.kill.replace("$id", "0")).walk_idents(&mut |i| {
        allowed.insert(root(i));
    });
    reads
        .iter()
        .filter(|r| !allowed.contains(*r))
        .filter(|r| !is_const(r))
        .filter(|r| !module.decls.iter().any(|d| &d.name == *r && d.loop_var))
        .filter(|r| !module.gen_loops.iter().any(|g| &g.genvar == *r))
        .cloned()
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{analyze_files, LowerOptions, ParseOptions};

    fn analyze(text: &str) -> TimingModule {
        let dir = std::env::temp_dir().join(format!(
            "svt_pipe_{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("p.sv");
        std::fs::write(&p, text).unwrap();
        let out = analyze_files(&[p], &ParseOptions::default(), &LowerOptions::default()).unwrap();
        let m = out.design.modules.values().next().unwrap().clone();
        let _ = std::fs::remove_dir_all(dir);
        m
    }

    const SRC: &str =
        "module p(input logic clk_i, rst_ni, flush_i, input logic valid_i, input logic [2:0] tid_i,
       input logic [7:0] cancel_i, input logic [1:0] op_i, input logic [15:0] a_i, b_i,
       output logic res_valid_o, output logic [2:0] res_tid_o, output logic [15:0] res_o);
     // svt-pipe: protocol ex valid=valid_i id=tid_i kill=cancel_i[$id] flush=flush_i
     // svt-pipe: carry ex op_i
     // svt-pipe: result ex valid=res_valid_o id=res_tid_o
     logic [15:0] sum, prod;
     // svt-pipe: cut-ok ex
     assign sum = a_i + b_i;
     // svt-pipe: no-cut
     assign prod = sum * b_i;
     assign res_o = op_i[0] ? prod : sum;
     assign res_valid_o = valid_i & ~cancel_i[tid_i];
     assign res_tid_o = tid_i;
     endmodule";

    #[test]
    fn pragmas_are_collected_resolved_and_anchored() {
        let m = analyze(SRC);
        assert_eq!(m.pipe_pragmas.len(), 5, "{:?}", m.pipe_pragmas);
        let c = resolve(&m).expect("contract");
        assert!(c.rejected.is_empty(), "{:?}", c.rejected);
        assert_eq!(c.domains.len(), 1);
        let d = &c.domains[0];
        assert_eq!(
            (
                d.name.as_str(),
                d.valid.as_str(),
                d.id.as_str(),
                d.kill.as_str()
            ),
            ("ex", "valid_i", "tid_i", "cancel_i[$id]")
        );
        assert_eq!(d.flush.as_deref(), Some("flush_i"));
        assert_eq!(d.carry, vec!["op_i".to_string()]);
        assert_eq!(d.result_valid.as_deref(), Some("res_valid_o"));
        assert_eq!(c.cut_ok.len(), 1);
        assert_eq!(
            (c.cut_ok[0].0.as_str(), c.cut_ok[0].1.as_deref()),
            ("sum", Some("ex"))
        );
        assert!(c.cut_ok[0].2 > 0);
        assert!(c.no_cut.contains("prod"));
        let sum = m
            .nodes
            .values()
            .find(|n| n.lhs.as_deref() == Some("sum"))
            .unwrap();
        let prod = m
            .nodes
            .values()
            .find(|n| n.lhs.as_deref() == Some("prod"))
            .unwrap();
        assert!(matches!(
            cut_permission(&m, &c, sum),
            CutPermission::Allowed(Some(_))
        ));
        assert!(matches!(
            cut_permission(&m, &c, prod),
            CutPermission::Forbidden(_)
        ));
        let w = |_: &str| Some(3u32);
        let st = stage_for(&m, d, "sum_svt_p1", 1, None, &w);
        assert_eq!(st.id_width, Some(3));
        assert_eq!(st.kill_expr, "(cancel_i[tid_i])");
        assert_eq!(st.valid_src, "valid_i");
        assert!(st
            .consumer_rewires
            .iter()
            .any(|(_, old, new)| old == "valid_i"
                && new.contains("sum_svt_p1_v & ~(cancel_i[sum_svt_p1_id])")));
        assert!(st
            .consumer_rewires
            .iter()
            .any(|(_, old, new)| old == "op_i" && new == "sum_svt_p1_c_op_i"));
        let st2 = stage_for(&m, d, "sum_svt_p2", 2, Some("sum_svt_p1"), &w);
        assert_eq!(st2.valid_src, "sum_svt_p1_v");
        assert_eq!(st2.kill_expr, "(cancel_i[sum_svt_p1_id])");
    }

    #[test]
    fn unbound_names_and_missing_id_are_rejected_not_guessed() {
        let m = analyze(
            "module p(input logic clk_i, input logic v_i, input logic [2:0] t_i, output logic y_o);
             // svt-pipe: protocol a valid=v_i id=t_i kill=nothing_i[$id]
             // svt-pipe: protocol b valid=v_i id=t_i kill=v_i
             // svt-pipe: carry zz t_i
             // svt-pipe: require-contract
             assign y_o = v_i;
             endmodule",
        );
        let c = resolve(&m).unwrap();
        assert!(c.domains.is_empty(), "{:?}", c.domains);
        assert_eq!(c.rejected.len(), 3, "{:?}", c.rejected);
        assert!(c.require_contract);
        let y = m
            .nodes
            .values()
            .find(|n| n.lhs.as_deref() == Some("y_o"))
            .unwrap();
        assert!(matches!(
            cut_permission(&m, &c, y),
            CutPermission::Forbidden(_)
        ));
    }
}
