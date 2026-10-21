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
//! // svt-pipe: cycle <dom> q=<flop> d=<next> hold=<sig> steps=<n|param>
//! ```
//!
//! `cycle` names one register-to-register step the hardware already has.
//! The long cone leaves the single-cycle board only when that step measures
//! at or under the FO4 budget. A step over budget stays on the board so a
//! latency-neutral transform can still shrink it. The pragma writes no
//! register and no stall.
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
    /// Kill expression with `$id` standing for the operation's id; empty
    /// when the domain declares none (cancellation handled outside, flush only).
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
    /// Further consumer-side assignments (by LHS root) that read carried or
    /// protocol signals and must read the last stage's copies.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub result_also: Vec<String>,
    /// `latency <dom> <param> base=<n|param>` (A129): the parameter that
    /// publishes this domain's stage count to the module's consumers (a
    /// wrapper's cancellation liveness, a scoreboard's latency table), and
    /// the stages the source already has — a number, or a parameter when the
    /// source follows it. A plan of k stages is admitted only when
    /// `base + k` equals the parameter's elaborated value.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub latency: Option<(String, String)>,
    /// `cycle <dom> q=<flop> d=<next> hold=<sig> steps=<n|param>`. The one
    /// enabled register-to-register step. `hold` is the signal consumers
    /// already wait on. `steps` is the published wait count.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cycle: Option<CycleStep>,
    /// A149 M12: `protocol … ready=<sig>` — the downstream ready the
    /// module's producer logic waits on. A stage on such a domain is an
    /// elastic register: it accepts when empty or draining
    /// (`en = ~v | ready_next`), the producer's reads of `ready` are rewired
    /// to the first stage's `en`, and the consumer side keeps the real
    /// `ready`. Latency-insensitive: the handshake absorbs the added cycle.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ready: Option<String>,
    /// A149 throughput: `throughput <dom> accept=<n>` — the domain's
    /// consumers absorb up to `n` added cycles without a bubble (an elastic
    /// channel with room, or a consumer that issues less than once per
    /// cycle). The planner places at most `n` stages on the domain, and the
    /// bottleneck trace marks callers whose wait is within `n` as absorbed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub accept: Option<u32>,
    /// A149 M7: `hint <dom> verified-by=<sig>` — the domain's outputs are
    /// predictions a named verifier checks later (a predictor table, a
    /// memory-dependence guess). A stage on its cycle cone changes when the
    /// prediction is made, not what the machine computes; the capacity rule
    /// does not apply. The obligation is the verifier.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hint: Option<String>,
    /// A149 M1: the stage a carried signal starts at (default 1). A balance
    /// line for cut net *j*, read past stage *j+1*, starts at stage *j+1*:
    /// that stage samples the net itself (age *j*), every later stage the
    /// previous copy, so the copy at stage *k* has age *k*.
    #[serde(default, skip_serializing_if = "std::collections::BTreeMap::is_empty")]
    pub carry_from: std::collections::BTreeMap<String, u32>,
}

/// One enabled cycle of a multi-cycle or pipelined domain.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CycleStep {
    /// Launch flop.
    pub q: String,
    /// Capture net of that same cycle.
    pub d: String,
    /// Handshake the rest of the machine already waits on.
    pub hold: String,
    /// Published cycle count (a number or a parameter name).
    pub steps: String,
}

impl PipeDomain {
    /// `kill` with `$id` replaced by `id_expr`, parenthesised; `(1'b0)` for
    /// a domain without a kill.
    pub fn kill_for(&self, id_expr: &str) -> String {
        if self.kill.is_empty() {
            return "(1'b0)".to_string();
        }
        if self.id.is_empty() || !self.kill.contains("$id") {
            return format!("({})", self.kill);
        }
        format!("({})", self.kill.replace("$id", id_expr))
    }

    /// Does the domain travel with a transaction id?
    pub fn has_id(&self) -> bool {
        !self.id.is_empty()
    }

    /// Validate the bundle shape before emitting scalar valid registers.
    /// Multi-lane valids need independent domains, not silent truncation.
    pub fn check_widths(&self, width: &dyn Fn(&str) -> Option<u32>) -> Result<(), String> {
        for valid in std::iter::once(&self.valid).chain(self.result_valid.iter()) {
            if width(valid) != Some(1) {
                return Err(format!("protocol `{}`: `{valid}` must have a resolved one-bit valid; split vector lanes into domains", self.name));
            }
        }
        for sig in self.carry.iter().chain(self.has_id().then_some(&self.id)) {
            if !width(sig).is_some_and(|w| w > 0) {
                return Err(format!(
                    "protocol `{}`: unresolved bundle width for `{sig}`",
                    self.name
                ));
            }
        }
        Ok(())
    }

    /// Check added stages against the published latency, using exact parameter
    /// names. A source that already follows that parameter has no spare cycles.
    pub fn check_latency(
        &self,
        added: usize,
        values: &std::collections::BTreeMap<String, i64>,
    ) -> Result<(), String> {
        let Some((param, base)) = &self.latency else {
            return Ok(());
        };
        let lookup = |name: &str| {
            name.parse::<i64>()
                .ok()
                .or_else(|| values.get(name).copied())
        };
        let (Some(published), Some(existing)) = (lookup(param), lookup(base)) else {
            return Err(format!(
                "latency: `{param}` / base `{base}` lack an exact elaborated value"
            ));
        };
        if published < 1 || existing < 0 {
            return Err(
                "latency: published depth must be positive and source depth nonnegative".into(),
            );
        }
        let expected = i64::try_from(added)
            .ok()
            .and_then(|n| existing.checked_add(n))
            .ok_or("latency: stage count overflow")?;
        if published == expected {
            return Ok(());
        }
        if param == base {
            return Err(format!(
                "latency: source already follows `{param}` ({existing} cycles); adding {added} \
                 stage(s) requires an RTL boundary change and matching consumer depth, not \
                 merely increasing the same parameter"
            ));
        }
        Err(format!(
            "latency: `{param}` = {published}, source depth = {existing}, added = {added}; \
             consumers must track {expected} cycles"
        ))
    }

    /// A149 M6: the parameter change that would make `added` stages legal —
    /// `(param, published, required)` — when the latency word names a
    /// parameter distinct from the source depth and both resolve. `None` when
    /// the plan is already legal, when the source follows the same parameter
    /// (no parameter value makes room), or when a value is unresolved.
    pub fn latency_update(
        &self,
        added: usize,
        values: &std::collections::BTreeMap<String, i64>,
    ) -> Option<(String, i64, i64)> {
        let (param, base) = self.latency.as_ref()?;
        if param == base {
            return None;
        }
        let lookup = |name: &str| {
            name.parse::<i64>()
                .ok()
                .or_else(|| values.get(name).copied())
        };
        let (published, existing) = (lookup(param)?, lookup(base)?);
        let required = existing.checked_add(i64::try_from(added).ok()?)?;
        (published != required).then(|| (param.clone(), published, required))
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
    /// Rows already staged by an applied boundary (`pipeline-boundary-applied`).
    /// A second cut there would unbalance the representation; the authored
    /// `cut-ok` that admitted the first stage does not reopen it.
    #[serde(default)]
    pub applied: BTreeSet<String>,
    /// A149 throughput: `async <sig> cycles=<n>` — this module samples
    /// `<sig>` through an interface that tolerates `n` added cycles of
    /// latency (a handshake, a FIFO, a credit). The bottleneck trace marks
    /// this module's reads of that signal as absorbed up to `n`.
    #[serde(default, skip_serializing_if = "std::collections::BTreeMap::is_empty")]
    pub async_reads: std::collections::BTreeMap<String, u32>,
    /// A149 throughput: `replicate <dom>` — the domain's logic holds no state
    /// a second copy would have to share; independent callers may take their
    /// own copy instead of waiting on this one. Reported, not performed.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub replicable: Vec<String>,
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

/// Declared in the module: a declaration site, a port, or — for a variable
/// of a package-imported user type the parser does not record as a
/// declaration (`fu_op operator_s1;`) — the LHS root of some assignment.
fn name_declared(module: &TimingModule, name: &str) -> bool {
    let root = TimingModule::root_ident(name).unwrap_or(name);
    module.decls.iter().any(|d| d.name == root)
        || module.ports.iter().any(|p| p.name == root)
        || module
            .nodes
            .values()
            .any(|n| n.lhs.as_deref().and_then(TimingModule::root_ident) == Some(root))
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
    resolve_pragmas(module, &module.pipe_pragmas)
}

pub(crate) fn resolve_pragmas(
    module: &TimingModule,
    pragmas: &[crate::ir::PipePragma],
) -> Option<PipeContract> {
    if pragmas.is_empty() {
        return None;
    }
    let mut c = PipeContract::default();
    for p in pragmas {
        let at = format!("{}:{}", p.loc.file, p.loc.start_line);
        match p.kind.as_str() {
            "representation" | "row-local" => {
                if p.kind == "row-local" {
                    c.require_contract = true;
                }
                let prepared = pragmas.iter().any(|q| {
                    q.derived
                        && q.loc == p.loc
                        && matches!(
                            q.kind.as_str(),
                            "representation-ready" | "row-local-ready" | "preprocess-error"
                        )
                });
                if !prepared {
                    c.rejected.push(format!(
                        "{at}: representation requires initial-IR preprocessing"
                    ));
                }
            }
            "representation-ready" if p.derived => {}
            "row-local-ready" if p.derived => {}
            "row-local-applied" => c.require_contract = true,
            "pipeline-boundary-applied" if p.derived => {
                if let Some(on) = arg(&p.args, "on") {
                    c.no_cut.insert(on.to_string());
                    c.applied.insert(on.to_string());
                }
            }
            "preprocess-error" if p.derived => {
                c.rejected.push(format!("{at}: {}", p.words.join(" ")));
            }
            "protocol" => {
                if let Some((key, _)) = p.args.iter().find(|(key, _)| {
                    !matches!(key.as_str(), "valid" | "id" | "kill" | "flush" | "ready")
                }) {
                    c.rejected.push(format!(
                        "{at}: unsupported protocol field `{key}`; no handshake is inferred"
                    ));
                    continue;
                }
                let Some(name) = p.domain.clone() else {
                    c.rejected
                        .push(format!("{at}: protocol without a domain name"));
                    continue;
                };
                let Some(valid) = arg(&p.args, "valid") else {
                    c.rejected
                        .push(format!("{at}: protocol {name} needs valid="));
                    continue;
                };
                // id-less domain (A127): a stream with a global kill (fetch
                // realign, frontend queues) — `kill=` may not use `$id` then.
                let id = arg(&p.args, "id").unwrap_or("");
                let kill = arg(&p.args, "kill").unwrap_or("");
                if id.is_empty() && kill.contains("$id") {
                    c.rejected.push(format!(
                        "{at}: protocol {name}: kill= uses $id but the domain has no id="
                    ));
                    continue;
                }
                let flush = arg(&p.args, "flush").map(str::to_string);
                let ready = arg(&p.args, "ready").map(str::to_string);
                let mut missing = Vec::new();
                for s in [valid, id]
                    .into_iter()
                    .filter(|s| !s.is_empty())
                    .chain(flush.as_deref())
                    .chain(ready.as_deref())
                {
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
                    hint: None,
                    accept: None,
                    ready,
                    carry_from: Default::default(),
                    name,
                    valid: valid.to_string(),
                    id: id.to_string(),
                    kill: kill.to_string(),
                    flush,
                    carry: Vec::new(),
                    result_valid: None,
                    result_id: None,
                    result_also: Vec::new(),
                    latency: None,
                    cycle: None,
                });
            }
            "latency" => {
                // latency <dom> <param> base=<n>
                let Some(name) = p.domain.as_deref() else {
                    c.rejected
                        .push(format!("{at}: latency without a domain name"));
                    continue;
                };
                let (Some(param), Some(base)) = (p.words.first(), arg(&p.args, "base")) else {
                    c.rejected.push(format!(
                        "{at}: latency {name} needs <param> and base=<n|param>"
                    ));
                    continue;
                };
                match c.domains.iter_mut().find(|d| &d.name == name) {
                    Some(d) => d.latency = Some((param.clone(), base.to_string())),
                    None => c
                        .rejected
                        .push(format!("{at}: latency {name}: domain not declared")),
                }
            }
            "hint" => {
                // hint <dom> verified-by=<sig>
                let Some(name) = p.domain.as_deref() else {
                    c.rejected.push(format!("{at}: hint without a domain name"));
                    continue;
                };
                let Some(verifier) = arg(&p.args, "verified-by") else {
                    c.rejected
                        .push(format!("{at}: hint {name} needs verified-by=<sig>"));
                    continue;
                };
                if !name_declared(module, verifier) {
                    c.rejected.push(format!(
                        "{at}: hint {name}: verifier `{verifier}` is not declared in this module"
                    ));
                    continue;
                }
                match c.domains.iter_mut().find(|d| &d.name == name) {
                    Some(d) => d.hint = Some(verifier.to_string()),
                    None => c
                        .rejected
                        .push(format!("{at}: hint {name}: domain not declared")),
                }
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
                    let unknown: Vec<_> = p
                        .words
                        .iter()
                        .filter(|w| !name_declared(module, w))
                        .cloned()
                        .collect();
                    if !unknown.is_empty() {
                        c.rejected.push(format!(
                            "{at}: result {name}: unknown consumer(s) {}",
                            unknown.join(", ")
                        ));
                    } else {
                        d.result_also.extend(p.words.iter().cloned());
                    }
                }
            }
            "cut-ok" => {
                let lhs = arg(&p.args, "on")
                    .map(|l| (l.to_string(), 0))
                    .or_else(|| anchor_lhs(module, p.loc.start_line));
                match lhs {
                    Some((l, line)) => c.cut_ok.push((l, p.domain.clone(), line)),
                    None => c.rejected.push(format!(
                        "{at}: cut-ok has no assignment to anchor to (an inactive generate branch, or more than three lines above it)"
                    )),
                }
            }
            "no-cut" => {
                let lhs = arg(&p.args, "on")
                    .map(|l| (l.to_string(), 0))
                    .or_else(|| anchor_lhs(module, p.loc.start_line));
                match lhs {
                    Some((l, _)) => {
                        c.no_cut.extend(l.split(',').map(str::to_string));
                    }
                    None => c
                        .rejected
                        .push(format!("{at}: no-cut has no assignment to anchor to")),
                }
            }
            "require-contract" => c.require_contract = true,
            "throughput" => {
                // throughput <dom> accept=<n>
                let Some(name) = p.domain.as_deref() else {
                    c.rejected
                        .push(format!("{at}: throughput without a domain name"));
                    continue;
                };
                let Some(n) = arg(&p.args, "accept").and_then(|v| v.parse::<u32>().ok()) else {
                    c.rejected
                        .push(format!("{at}: throughput {name} needs accept=<n>"));
                    continue;
                };
                match c.domains.iter_mut().find(|d| &d.name == name) {
                    Some(d) => d.accept = Some(n),
                    None => c
                        .rejected
                        .push(format!("{at}: throughput {name}: domain not declared")),
                }
            }
            "async" => {
                // async <sig> cycles=<n>
                let Some(sig) = p.words.first() else {
                    c.rejected.push(format!("{at}: async needs <sig> cycles=<n>"));
                    continue;
                };
                let Some(n) = arg(&p.args, "cycles").and_then(|v| v.parse::<u32>().ok()) else {
                    c.rejected.push(format!("{at}: async {sig} needs cycles=<n>"));
                    continue;
                };
                if !name_declared(module, sig) {
                    c.rejected
                        .push(format!("{at}: async {sig}: signal not declared in this module"));
                    continue;
                }
                c.async_reads
                    .insert(TimingModule::root_ident(sig).unwrap_or(sig).to_string(), n);
            }
            "replicate" => {
                let Some(name) = p.domain.as_deref() else {
                    c.rejected
                        .push(format!("{at}: replicate without a domain name"));
                    continue;
                };
                if c.domains.iter().any(|d| d.name == name) {
                    c.replicable.push(name.to_string());
                } else {
                    c.rejected
                        .push(format!("{at}: replicate {name}: domain not declared"));
                }
            }
            "cycle" => {
                // cycle <dom> q=<flop> d=<next> hold=<sig> steps=<n|param>
                let Some(name) = p.domain.as_deref() else {
                    c.rejected
                        .push(format!("{at}: cycle without a domain name"));
                    continue;
                };
                let (q, d, hold, steps) = (
                    arg(&p.args, "q"),
                    arg(&p.args, "d"),
                    arg(&p.args, "hold"),
                    arg(&p.args, "steps"),
                );
                let (Some(q), Some(d), Some(hold), Some(steps)) = (q, d, hold, steps) else {
                    c.rejected
                        .push(format!("{at}: cycle {name} needs q=, d=, hold= and steps="));
                    continue;
                };
                let mut missing = Vec::new();
                for s in [q, d, hold] {
                    if !name_declared(module, s) {
                        missing.push(s.to_string());
                    }
                }
                // A parameter path (`CVA6Cfg.MultStages`) is not a local
                // declaration. A bare unknown word is still rejected.
                if steps.parse::<u32>().is_err()
                    && !steps.contains('.')
                    && !name_declared(module, steps)
                {
                    missing.push(steps.to_string());
                }
                if !missing.is_empty() {
                    c.rejected.push(format!(
                        "{at}: cycle {name}: unknown signal(s) {}",
                        missing.join(", ")
                    ));
                    continue;
                }
                match c.domains.iter_mut().find(|dom| dom.name == name) {
                    Some(dom) => {
                        dom.cycle = Some(CycleStep {
                            q: q.to_string(),
                            d: d.to_string(),
                            hold: hold.to_string(),
                            steps: steps.to_string(),
                        });
                    }
                    None => c
                        .rejected
                        .push(format!("{at}: cycle {name}: domain not declared")),
                }
            }
            // reserved words of the vocabulary that take no action yet
            "stage-input" => c.rejected.push(format!(
                "{at}: stage-input is reserved (input staging is not implemented)"
            )),
            other => c
                .rejected
                .push(format!("{at}: unknown svt-pipe kind `{other}`")),
        }
    }
    // A module that declares a protocol has said how its operations travel:
    // a bare register anywhere else in it would desynchronise them, so the
    // contract is required implicitly.
    if !c.domains.is_empty() {
        c.require_contract = true;
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
    reads.contains(&root(&d.valid)) || (d.has_id() && reads.contains(&root(&d.id)))
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
    // Rejected facts cannot become permission for an uncarried register.
    // In particular an unknown explicit domain used to fall through to None.
    if let Some(reason) = contract.rejected.first() {
        return CutPermission::Forbidden(format!("invalid pipeline contract: {reason}"));
    }
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
    // A `cycle` line is the contract for one capture. It authorizes a stage
    // on `d` even when `require-contract` or `no-cut` would otherwise lock
    // that net. The launch flop `q` and every other locked name stay locked.
    let cycle_domains: Vec<_> = contract
        .domains
        .iter()
        .filter(|d| d.cycle.as_ref().is_some_and(|c| c.d == lhs))
        .collect();
    if cycle_domains.len() > 1 {
        return CutPermission::Forbidden(
            "cycle capture matches multiple domains; name one step".into(),
        );
    }
    if let Some(d) = cycle_domains.first() {
        return CutPermission::Allowed(Some(crate::pipeline_preprocess::domain_at_cut(
            module,
            (*d).clone(),
            lhs,
        )));
    }
    // A row an applied boundary already staged stays locked: the authored
    // `cut-ok` admitted that stage, not a second one on the same row.
    if contract.applied.contains(lhs) {
        return CutPermission::Forbidden(format!(
            "`{lhs}` is already staged by an applied boundary"
        ));
    }
    // An explicit cut-ok is the change. It wins over no-cut on the same name
    // so the stage can be emitted. no-cut still locks every name without one.
    if let Some((_, dom, _)) = contract
        .cut_ok
        .iter()
        .find(|(l, _, line)| l == lhs || (*line != 0 && *line == node.loc.start_line))
    {
        let d = if let Some(name) = dom {
            match contract.domains.iter().find(|d| &d.name == name) {
                Some(d) => Some(d.clone()),
                None => {
                    return CutPermission::Forbidden(format!("unknown pipeline domain `{name}`"))
                }
            }
        } else {
            let mut domains = contract
                .domains
                .iter()
                .filter(|d| node_in_domain(module, node, d));
            let first = domains.next().cloned();
            if domains.next().is_some() {
                return CutPermission::Forbidden(
                    "cut-ok matches multiple domains; name one explicitly".into(),
                );
            }
            first
        };
        if d.is_none() && contract.require_contract {
            return CutPermission::Forbidden(
                "require-contract: cut-ok has no resolved domain".into(),
            );
        }
        return CutPermission::Allowed(
            d.map(|d| crate::pipeline_preprocess::domain_at_cut(module, d, lhs)),
        );
    }
    if contract.no_cut.contains(lhs) {
        return CutPermission::Forbidden(format!("no-cut on `{lhs}`"));
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

/// A `cycle` step over budget authorizes every cut along that cone, not only
/// the capture `d`. `require-contract` does not have to name each intermediate.
/// The launch `q` stays locked, and so does any other `no-cut` name.
pub fn cone_cut_permission(
    design: &crate::ir::TimingDesign,
    module: &TimingModule,
    node: &IrNode,
) -> CutPermission {
    let Some(contract) = resolve(module) else {
        return CutPermission::Unconstrained;
    };
    let direct = cut_permission(module, &contract, node);
    if matches!(direct, CutPermission::Allowed(_)) {
        return direct;
    }
    if let CutPermission::Forbidden(reason) = &direct {
        if reason.starts_with("invalid pipeline contract") {
            return direct;
        }
    }
    // A nameless expression-spine node is not a locked name. It can still sit
    // on the q→d cone. The launch `q` and any other `no-cut` stay locked.
    let lhs = node.lhs.as_deref().and_then(TimingModule::root_ident);
    let Some(&mid) = design.module_names.get(&module.name) else {
        return direct;
    };
    let budget = design.target.budget_fo4;
    let mut hits = Vec::new();
    for domain in &contract.domains {
        let Some(step) = &domain.cycle else { continue };
        if lhs.is_some_and(|name| step.q == name) {
            continue;
        }
        if lhs.is_some_and(|name| contract.no_cut.contains(name) && step.d != name) {
            continue;
        }
        let on_cone = design.paths.iter().any(|path| {
            path.module == mid
                && path.total_fo4 > budget + 1e-6
                && path.nodes.contains(&node.id)
                && path_names(design, path, &step.q)
                && path_names(design, path, &step.d)
        });
        if on_cone {
            hits.push(domain);
        }
    }
    match hits.as_slice() {
        [d] => CutPermission::Allowed(Some(crate::pipeline_preprocess::domain_at_cut(
            module,
            (*d).clone(),
            lhs.unwrap_or(""),
        ))),
        [_, _, ..] => {
            CutPermission::Forbidden("cone matches multiple cycle domains; name one step".into())
        }
        [] => direct,
    }
}

/// Registers that split `total` into pieces of at most `budget`, capped.
/// Zero when the cone is already inside the budget. A single operator wider
/// than `budget` still counts here; the cut cannot land inside that operator.
pub fn budget_fit_cuts(total: f64, budget: f64, cap: u32) -> u32 {
    if !(budget > 0.0) || total <= budget || cap == 0 {
        return 0;
    }
    let pieces = (total / budget).ceil() as u32;
    pieces.saturating_sub(1).min(cap)
}

/// Worst remaining segment if `max_cuts` registers are spread along `total`.
/// A single operator wider than `budget` cannot be split by these cuts.
pub fn budget_fit_worst(total: f64, budget: f64, max_cuts: u32) -> f64 {
    let cuts = budget_fit_cuts(total, budget, max_cuts);
    if cuts == 0 {
        return total;
    }
    total / (f64::from(cuts) + 1.0)
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

/// A149 M1: the balance lines that satisfy [`alignment_violation`] and the
/// foreign-read check. The reader after cut `i` (zero-based) feeds stage
/// `i + 2`; its chain predecessor is cut `i`'s net (age `i + 1`). A read of
/// cut `j`'s net with `j < i` is `i - j` cycles too old, so that net is
/// carried from stage `j + 2` (one-based) on: that stage samples the net
/// (age `j + 1`), each later stage the previous copy, and the copy the
/// reader is rewired to (stage `i + 1`) has age `i + 1`.
/// Returns `(net, start stage)` pairs, each net once at its earliest start.
pub fn alignment_balance(cut_lhs: &[String], readers: &[BTreeSet<String>]) -> Vec<(String, u32)> {
    let mut out: Vec<(String, u32)> = Vec::new();
    for (i, reads) in readers.iter().enumerate() {
        for (j, earlier) in cut_lhs.iter().enumerate() {
            if j < i && !earlier.is_empty() && reads.contains(earlier) {
                let start = (j + 2) as u32;
                match out.iter_mut().find(|(n, _)| n == earlier) {
                    Some(e) => e.1 = e.1.min(start),
                    None => out.push((earlier.clone(), start)),
                }
            }
        }
    }
    out
}

/// The bundle one stage of a domain carries, as the emitter serializes it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PipeStage {
    /// Representation directives consumed by this cut: (original line,
    /// comma-separated row names). Emission guards both against another cut.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub consumed_representations: Vec<(u32, String)>,
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
    /// A149 M12: the domain's downstream ready, when declared. The stage is
    /// then elastic (`<name>_en = ~<name>_v | <next stage's en, or ready>`),
    /// captures only when enabled, and the producer's reads of `ready` are
    /// rewired to the first stage's `en` (consumer rewires).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ready: Option<String>,
    /// A149: carried signals that are ports of a non-vector type (a packed
    /// struct or enum). Their staged copies are declared `var type(<port>)`
    /// so a consumer may still select a member; a width-declared `logic`
    /// copy under a cast cannot (`type(p)'(net).member` does not parse).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub carry_typed_port: Vec<bool>,
    /// Width of the staged data net (the cut node's), when the measurement
    /// resolved it: the pipe is declared at that width instead of the
    /// module-wide `SVT_DATA_W` (a 128-bit product sum must not be staged
    /// through a 64-bit pipe).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data_width: Option<u32>,
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

/// Is `name` declared as a plain vector (`logic`/`bit`/`reg`/`wire`, any
/// packed range) — or as a user type whose consumers need a cast back?
pub fn plain_vector(module: &TimingModule, name: &str) -> bool {
    let root = TimingModule::root_ident(name).unwrap_or(name);
    let ty = module
        .decls
        .iter()
        .find(|d| d.name == root)
        .map(|d| d.type_name.clone())
        .or_else(|| {
            module
                .ports
                .iter()
                .find(|p| p.name == root)
                .and_then(|p| p.type_name.clone())
        });
    match ty {
        Some(t) => {
            let head = t
                .trim()
                .split(|c: char| c.is_whitespace() || c == '[')
                .next()
                .unwrap_or("");
            matches!(
                head,
                "logic" | "bit" | "reg" | "wire" | "" | "signed" | "unsigned" | "int" | "integer"
            )
        }
        // not recorded as a declaration (a package-imported user type such as
        // `fu_op x;`): read back through a cast, which is also legal on vectors
        None => false,
    }
}

/// The text a consumer reads for carried signal `sig` of pipe `name`.
pub fn carry_read(module: &TimingModule, name: &str, sig: &str) -> String {
    let net = carry_net(name, sig);
    // A149: a typed port's copy is declared with the port's own type (see
    // `PipeStage::carry_typed_port`), so it reads without a cast and keeps
    // its members selectable.
    if plain_vector(module, sig) || is_port(module, sig) {
        net
    } else {
        format!("type({sig})'({net})")
    }
}

/// `name` is a port of the module (any direction).
pub fn is_port(module: &TimingModule, name: &str) -> bool {
    let root = TimingModule::root_ident(name).unwrap_or(name);
    module
        .ports
        .iter()
        .any(|p| TimingModule::root_ident(&p.name).unwrap_or(&p.name) == root)
}

/// Labeled generate-for that owns every block-local name in `text`.
/// A module-level pipe cannot see a genvar. The stage belongs inside that loop.
pub fn labeled_genvar_scope(module: &TimingModule, text: &str) -> Option<crate::SourceLoc> {
    let locals = module.block_local_names();
    if locals.is_empty() || !module.text_refs_block_local(text, &locals) {
        return None;
    }
    let mut hit: Option<&crate::ir::GenerateLoop> = None;
    let bytes = text.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i].is_ascii_alphabetic() || matches!(bytes[i], b'_' | b'$') {
            let start = i;
            i += 1;
            while i < bytes.len()
                && (bytes[i].is_ascii_alphanumeric() || matches!(bytes[i], b'_' | b'$'))
            {
                i += 1;
            }
            let name = &text[start..i];
            if !locals.contains(name) {
                continue;
            }
            let Some(g) = module
                .gen_loops
                .iter()
                .find(|g| !g.procedural && g.label.is_some() && g.genvar == name)
            else {
                return None;
            };
            if let Some(prev) = hit {
                if prev.loc.start_line != g.loc.start_line || prev.loc.end_line != g.loc.end_line {
                    return None;
                }
            }
            hit = Some(g);
        } else {
            i += 1;
        }
    }
    hit.map(|g| g.loc.clone())
}

/// The named generate block (if/case generate — not a `for` body, whose
/// copies would each need their own stage) that declares `name`, as the
/// declaration site's lexical scope. `None` for a module-level name, a loop
/// variable, or a scope that is a generate loop's body.
pub fn generate_scope_of(module: &TimingModule, name: &str) -> Option<crate::SourceLoc> {
    let d = module.decls.iter().find(|d| d.name == name)?;
    if d.loop_var || !d.block_local {
        return None;
    }
    let sc = d.scope.clone()?;
    // A labeled generate-for gets one stage per copy, inside that block.
    // An unlabeled or procedural loop still has no place to put the flop.
    if let Some(g) = module
        .gen_loops
        .iter()
        .filter(|g| {
            !g.procedural
                && g.label.is_some()
                && g.loc.file == sc.file
                && g.loc.start_line <= sc.start_line
                && g.loc.end_line >= sc.end_line
        })
        .min_by_key(|g| g.loc.end_line.saturating_sub(g.loc.start_line))
    {
        return Some(g.loc.clone());
    }
    Some(sc)
}

/// Do all block-local names `text` reads live in scope `sc` (or at module
/// level)? A name declared in another block is not visible where the stage
/// will be emitted.
pub fn block_locals_within(module: &TimingModule, text: &str, sc: &crate::SourceLoc) -> bool {
    let mut ok = true;
    crate::expr::Expr::parse(text).walk_idents(&mut |i| {
        let root = TimingModule::root_ident(i).unwrap_or(i);
        if let Some(d) = module
            .decls
            .iter()
            .find(|d| d.name == root && d.block_local)
        {
            match &d.scope {
                Some(s)
                    if s.file == sc.file
                        && s.start_line >= sc.start_line
                        && s.end_line <= sc.end_line => {}
                // a nested scope inside `sc` is fine only if the name is not read
                // from outside it; the stage's feed sits at `sc`'s level, so refuse.
                _ => ok = false,
            }
        }
    });
    ok
}

/// Merge balance (A125). Everything downstream of the stage's consumers —
/// the result registers and whatever reads them, up to the module's outputs
/// — is at the staged age. A register it merges with that is *not* staged
/// with the domain (a parallel datapath of its own depth, such as the
/// carry-less product beside the multiplier's product) arrives at the old
/// age: the merge would pair results of different operations. Returns the
/// first such register and the node that reads it.
pub fn merge_violation(
    module: &TimingModule,
    domain: &PipeDomain,
    consumer_lhs: &BTreeSet<String>,
    is_const: &dyn Fn(&str) -> bool,
) -> Option<(String, String, u32)> {
    let regs = crate::select_increment::register_roots(module);
    let root = |s: &str| TimingModule::root_ident(s).unwrap_or(s).to_string();
    let mut allowed: BTreeSet<String> = consumer_lhs.clone();
    for c in domain.carry.iter().chain(domain.result_also.iter()) {
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
    // downstream closure over the module's nodes: first the whole closure
    // (every LHS reached is at the staged age), then the reads
    let node_reads = |n: &IrNode| -> BTreeSet<String> {
        let mut reads = BTreeSet::new();
        if let Some(e) = &n.rhs_expr {
            e.walk_idents(&mut |i| {
                reads.insert(root(i));
            });
        }
        for g in module.guards.get(&n.id).into_iter().flatten() {
            crate::expr::Expr::parse(g.trim_start_matches('^')).walk_idents(&mut |i| {
                reads.insert(root(i));
            });
        }
        reads
    };
    let mut frontier: Vec<String> = consumer_lhs.iter().cloned().collect();
    let mut visited: BTreeSet<u32> = BTreeSet::new();
    while let Some(name) = frontier.pop() {
        let mut newly: Vec<String> = Vec::new();
        for n in module.nodes.values() {
            if visited.contains(&n.id) || !node_reads(n).contains(&name) {
                continue;
            }
            visited.insert(n.id);
            if let Some(lhs) = n.lhs.as_deref().and_then(TimingModule::root_ident) {
                if allowed.insert(lhs.to_string()) {
                    frontier.push(lhs.to_string());
                }
                newly.push(lhs.to_string());
            }
        }
        // every other writer of a reached LHS is the same merge point (the
        // other arms of a case / if that select the result)
        for lhs in newly {
            for n in module.nodes.values() {
                if n.lhs.as_deref().and_then(TimingModule::root_ident) == Some(lhs.as_str()) {
                    visited.insert(n.id);
                }
            }
        }
    }
    let mut hits: Vec<(String, String, u32)> = Vec::new();
    for id in &visited {
        let Some(n) = module.nodes.get(id) else {
            continue;
        };
        let lhs = n
            .lhs
            .as_deref()
            .and_then(TimingModule::root_ident)
            .unwrap_or("?");
        for r in node_reads(n) {
            if regs.contains(&r) && !allowed.contains(&r) && !is_const(&r) {
                hits.push((r, lhs.to_string(), n.loc.start_line));
            }
        }
    }
    hits.sort();
    hits.into_iter().next()
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
    // A149 M1: a carry is present from its start stage on. At the start
    // stage the copy samples the signal itself; later stages sample the
    // previous stage's copy.
    let start_of = |c: &String| domain.carry_from.get(c).copied().unwrap_or(1).max(1);
    let active: Vec<&String> = domain
        .carry
        .iter()
        .filter(|c| start_of(c) <= stage)
        .collect();
    let (valid_src, id_src, carry_src) = match prev {
        Some(p) => {
            let (v, i) = stage_nets(p);
            (
                v,
                if domain.has_id() { i } else { String::new() },
                active
                    .iter()
                    .map(|c| {
                        if start_of(c) == stage {
                            (*c).clone()
                        } else {
                            carry_net(p, c)
                        }
                    })
                    .collect(),
            )
        }
        None => (
            domain.valid.clone(),
            domain.id.clone(),
            active.iter().map(|c| (*c).clone()).collect(),
        ),
    };
    let (v_net, id_net) = stage_nets(name);
    // The feed of this stage reads the previous stage's copy of every carry
    // that already existed there (start < this stage).
    let feed_rewires: Vec<(String, String)> = match prev {
        Some(p) => active
            .iter()
            .filter(|c| start_of(c) < stage)
            .map(|c| ((*c).clone(), carry_read(module, p, c)))
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
        .chain(domain.result_also.iter().map(String::as_str))
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
            // only the signals the consumer actually reads: an export of an
            // unread carried signal would need a default the consumer's
            // scope may not see
            let mut reads = BTreeSet::new();
            if let Some(e) = &n.rhs_expr {
                e.walk_idents(&mut |i| {
                    reads.insert(TimingModule::root_ident(i).unwrap_or(i).to_string());
                });
            }
            let root = |s: &str| TimingModule::root_ident(s).unwrap_or(s).to_string();
            if reads.contains(&root(&domain.valid)) {
                consumer_rewires.push((
                    line,
                    domain.valid.clone(),
                    format!("({v_net} & ~{})", domain.kill_for(&id_net)),
                ));
            }
            if domain.has_id() && reads.contains(&root(&domain.id)) {
                consumer_rewires.push((line, domain.id.clone(), id_net.clone()));
            }
            for c in active.iter() {
                if reads.contains(&root(c)) {
                    consumer_rewires.push((line, (*c).clone(), carry_read(module, name, c)));
                }
            }
        }
    }
    PipeStage {
        consumed_representations: Vec::new(),
        domain: domain.name.clone(),
        stage,
        kill_expr: domain.kill_for(&id_src),
        valid_src,
        id_src,
        carry_src,
        carry_sigs: active.iter().map(|c| (*c).clone()).collect(),
        ready: domain.ready.clone(),
        id_width: width_of(&domain.id),
        carry_widths: active.iter().map(|c| width_of(c)).collect(),
        carry_typed_port: active
            .iter()
            .map(|c| !plain_vector(module, c) && is_port(module, c))
            .collect(),
        data_width: None,
        flush: domain.flush.clone(),
        consumer_rewires,
        feed_rewires,
    }
}

/// A carried stage may rewrite a result net only together with the result
/// valid. No `result` data signals means there is nothing to pair. The
/// valid counts as rewritten when the consumer reads `domain.valid` or the
/// result-valid net itself.
pub fn result_and_valid_paired(domain: &PipeDomain, rewires: &[(u32, String, String)]) -> bool {
    if domain.result_also.is_empty() {
        return true;
    }
    let Some(rv) = &domain.result_valid else {
        return false;
    };
    let valid_moved = rewires
        .iter()
        .any(|(_, old, _)| old == rv || old == &domain.valid);
    let data_moved = rewires
        .iter()
        .any(|(_, old, _)| domain.result_also.iter().any(|r| r == old));
    if data_moved {
        valid_moved
    } else {
        valid_moved || domain.result_also.iter().all(|r| r == rv)
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
    // a `result` consumer is rewired onto the last stage's copies, so a
    // read of it is at the stage's age (a derived net such as a shifted
    // carried value)
    for c in &domain.result_also {
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

fn label_has(label: &str, name: &str) -> bool {
    label
        .split(|c: char| !c.is_ascii_alphanumeric() && c != '_')
        .any(|part| part == name)
}

/// True when `name` is the path start, the path end, an LHS on the path, or
/// a name the path reads. A `cycle` launch is often the flop the cone reads
/// (`a_q`), while the startpoint string is only `reg0/CP`.
fn path_names(design: &crate::ir::TimingDesign, path: &crate::ir::TimingPath, name: &str) -> bool {
    if label_has(&path.startpoint, name) || label_has(&path.endpoint, name) {
        return true;
    }
    let Some(module) = design.modules.get(&path.module) else {
        return false;
    };
    path.nodes.iter().any(|id| {
        let Some(n) = module.nodes.get(id) else {
            return false;
        };
        n.lhs.as_deref().is_some_and(|lhs| label_has(lhs, name))
            || n.rhs.as_deref().is_some_and(|rhs| label_has(rhs, name))
    })
}

/// A149 balance: a side read a stage may carry instead of refusing. The
/// name is an input port, a register of the module, or a combinational net
/// whose every source (through at most `depth` combinational writers, none
/// of them on the plan's own path) is such a stable source. A net derived
/// from the staged chain is not balanceable this way: its lag would have to
/// follow the cut it branches from, which a stage-1 carry does not give.
pub fn balanceable_side_read(
    module: &TimingModule,
    name: &str,
    on_plan: &BTreeSet<crate::ir::NodeId>,
    is_const: &dyn Fn(&str) -> bool,
    depth: u32,
) -> bool {
    let name = TimingModule::root_ident(name).unwrap_or(name);
    if is_const(name) {
        return true;
    }
    if module.ports.iter().any(|p| {
        p.direction == "input" && TimingModule::root_ident(&p.name).unwrap_or(&p.name) == name
    }) {
        return true;
    }
    let writers: Vec<&IrNode> = module
        .nodes
        .values()
        .filter(|n| n.lhs.as_deref().and_then(TimingModule::root_ident) == Some(name))
        .collect();
    if writers.is_empty() {
        return false;
    }
    if writers.iter().all(|n| n.assign_kind.is_seq_def()) {
        return true;
    }
    if depth == 0 {
        return false;
    }
    writers.iter().all(|w| {
        if on_plan.contains(&w.id) {
            return false;
        }
        let mut reads = BTreeSet::new();
        if let Some(e) = &w.rhs_expr {
            e.walk_idents(&mut |i| {
                reads.insert(TimingModule::root_ident(i).unwrap_or(i).to_string());
            });
        }
        for g in module.guards.get(&w.id).into_iter().flatten() {
            crate::expr::Expr::parse(g.trim_start_matches('^')).walk_idents(&mut |i| {
                reads.insert(TimingModule::root_ident(i).unwrap_or(i).to_string());
            });
        }
        reads
            .iter()
            .filter(|r| r.as_str() != name)
            .all(|r| balanceable_side_read(module, r, on_plan, is_const, depth - 1))
    })
}

/// A149 M12 port stage. A module's over-budget cone that ends at an output
/// port is only half of the path the clock sees: the other half is the
/// parent's logic from the connected net. A register on the port cuts that
/// cross-module path in two. It is a legal stage when the port belongs to a
/// domain with `ready=` (the handshake absorbs the cycle) and the port's
/// assembling statement is a `cut-ok` anchor. Returns one `InsertReg`
/// opportunity per such port whose cross-module total exceeds the budget:
/// the child's longest path ending at the anchor, cut after that node, with
/// `estimated_fo4_before` the child + parent total and `estimated_fo4_after`
/// the longer half. The rationale starts with `port-stage` so the planner
/// places exactly that one cut.
pub fn port_stage_opportunities(design: &crate::ir::TimingDesign) -> Vec<crate::ir::Opportunity> {
    let budget = design.target.budget_fo4;
    let mut out = Vec::new();
    for (mid, module) in &design.modules {
        let Some(contract) = resolve(module) else { continue };
        if !contract.rejected.is_empty() {
            continue;
        }
        for domain in contract.domains.iter().filter(|d| d.ready.is_some()) {
            if std::env::var("SVT_DEBUG_PORT_STAGE").is_ok() {
                eprintln!("DBG port-stage module={} domain={} cut_ok={:?}", module.name, domain.name, contract.cut_ok);
            }
            let outputs: Vec<&str> = module
                .ports
                .iter()
                .filter(|p| p.direction == "output")
                .map(|p| TimingModule::root_ident(&p.name).unwrap_or(&p.name))
                .collect();
            for (anchor, dom, _) in &contract.cut_ok {
                if dom.as_deref().is_some_and(|d| d != domain.name) {
                    continue;
                }
                let anchor_root = TimingModule::root_ident(anchor).unwrap_or(anchor);
                if !outputs.contains(&anchor_root) {
                    continue;
                }
                // the path that ends at the anchor's statement (the cut sits on
                // it) and the child's cone: the longest path ending at the
                // anchor or at a net the anchor's assembly reads (`y_o = pkt`
                // is its own zero-cost path; the cone ends at `pkt`)
                let ends_at = |p: &crate::ir::TimingPath, root: &str| {
                    p.nodes.last().and_then(|id| module.nodes.get(id)).is_some_and(|n| {
                        n.lhs.as_deref().and_then(TimingModule::root_ident) == Some(root)
                    })
                };
                let anchor_path = design
                    .paths
                    .iter()
                    .filter(|p| p.module == *mid && !p.multi_cycle && ends_at(p, anchor_root))
                    .max_by(|a, b| a.total_fo4.total_cmp(&b.total_fo4));
                let Some(anchor_path) = anchor_path else { continue };
                let Some(&anchor_node) = anchor_path.nodes.last() else { continue };
                let mut feeds: BTreeSet<String> = BTreeSet::new();
                feeds.insert(anchor_root.to_string());
                if let Some(n) = module.nodes.get(&anchor_node) {
                    let owned: Option<crate::expr::Expr> = match n.rhs_expr.as_ref() {
                        Some(e) => Some(e.clone()),
                        None => n.rhs.as_deref().map(crate::expr::Expr::parse),
                    };
                    if let Some(e) = owned {
                        e.walk_idents(&mut |i| {
                            feeds.insert(TimingModule::root_ident(i).unwrap_or(i).to_string());
                        });
                    }
                }
                let child_fo4 = design
                    .paths
                    .iter()
                    .filter(|p| p.module == *mid && !p.multi_cycle)
                    .filter(|p| feeds.iter().any(|f| ends_at(p, f)))
                    .map(|p| p.total_fo4)
                    .fold(0.0f64, f64::max);
                let child = anchor_path;
                // the longest reader path on the other side of the port. A
                // parent that only passes the net on to its own output port is
                // climbed (up to four levels): the cache's request leaves
                // through two wrappers before the adapter's logic reads it.
                let mut parent_fo4 = 0.0f64;
                let mut parent_desc = String::new();
                let reads_root = |m: &TimingModule, n: &IrNode, root: &str| -> bool {
                    let mut hit = false;
                    let owned: Option<crate::expr::Expr> = match n.rhs_expr.as_ref() {
                        Some(e) => Some(e.clone()),
                        None => n.rhs.as_deref().map(crate::expr::Expr::parse),
                    };
                    if let Some(e) = owned {
                        e.walk_idents(&mut |i| {
                            if TimingModule::root_ident(i).unwrap_or(i) == root {
                                hit = true;
                            }
                        });
                    }
                    if !hit {
                        hit = m.guards.get(&n.id).is_some_and(|g| g.iter().any(|t| label_has(t, root)));
                    }
                    hit
                };
                // Breadth-first over (module, net): the paths that start by
                // reading the net; the child instances the net is wired into
                // (their paths start at the formal); and, when the net is an
                // output port, the parents it leaves through. The cache's
                // request crosses two wrappers and lands in the adapter's
                // request FIFO this way.
                let mut frontier: Vec<(String, String, u32)> = Vec::new();
                let mut seen_nets: BTreeSet<(String, String)> = BTreeSet::new();
                // start one level up: the anchor is an output of `module`
                for inst in design.all_instances().into_iter().filter(|i| i.child_type == module.name) {
                    if let Some(conn) = inst
                        .connections
                        .iter()
                        .find(|c| TimingModule::root_ident(&c.formal).unwrap_or(&c.formal) == anchor_root)
                    {
                        frontier.push((
                            inst.parent_name.clone(),
                            TimingModule::root_ident(&conn.actual).unwrap_or(&conn.actual).to_string(),
                            1,
                        ));
                    }
                }
                while let Some((mname, net, depth)) = frontier.pop() {
                    if depth > 6 || !seen_nets.insert((mname.clone(), net.clone())) {
                        continue;
                    }
                    let Some(&mid2) = design.module_names.get(&mname) else { continue };
                    let Some(m2) = design.modules.get(&mid2) else { continue };
                    for p in design.paths.iter().filter(|p| p.module == mid2 && !p.multi_cycle) {
                        let starts_here = p
                            .nodes
                            .first()
                            .and_then(|id| m2.nodes.get(id))
                            .is_some_and(|n| reads_root(m2, n, &net));
                        if starts_here && p.total_fo4 > parent_fo4 {
                            parent_fo4 = p.total_fo4;
                            parent_desc = format!("{mname} via {net}");
                        }
                    }
                    // into the children the net is wired to
                    for inst in m2.instances.iter() {
                        let Some(cid) = inst.child_module else { continue };
                        let Some(cm) = design.modules.get(&cid) else { continue };
                        for c in inst.connections.iter() {
                            if TimingModule::root_ident(&c.actual).unwrap_or(&c.actual) != net {
                                continue;
                            }
                            let formal = TimingModule::root_ident(&c.formal).unwrap_or(&c.formal);
                            let is_input = cm.ports.iter().any(|pp| {
                                pp.direction == "input"
                                    && TimingModule::root_ident(&pp.name).unwrap_or(&pp.name) == formal
                            });
                            if is_input {
                                frontier.push((cm.name.clone(), formal.to_string(), depth + 1));
                            }
                        }
                    }
                    // up through an output port of this module
                    let is_out = |name: &str| {
                        m2.ports.iter().any(|pp| {
                            pp.direction == "output"
                                && TimingModule::root_ident(&pp.name).unwrap_or(&pp.name) == name
                        })
                    };
                    let mut outs: Vec<String> = Vec::new();
                    if is_out(&net) {
                        outs.push(net.clone());
                    }
                    for n in m2.nodes.values() {
                        if let Some(l) = n.lhs.as_deref().and_then(TimingModule::root_ident) {
                            if is_out(l) && reads_root(m2, n, &net) {
                                outs.push(l.to_string());
                            }
                        }
                    }
                    for o in outs {
                        for inst in design.all_instances().into_iter().filter(|i| i.child_type == mname) {
                            if let Some(conn) = inst
                                .connections
                                .iter()
                                .find(|c| TimingModule::root_ident(&c.formal).unwrap_or(&c.formal) == o)
                            {
                                frontier.push((
                                    inst.parent_name.clone(),
                                    TimingModule::root_ident(&conn.actual).unwrap_or(&conn.actual).to_string(),
                                    depth + 1,
                                ));
                            }
                        }
                    }
                }
                let cross = child_fo4 + parent_fo4;
                if std::env::var("SVT_DEBUG_PORT_STAGE").is_ok() {
                    eprintln!("DBG port-stage anchor={anchor_root} feeds={feeds:?} child={child_fo4} parent={parent_fo4} ({parent_desc}) budget={budget}");
                }
                if cross <= budget + 1e-6 {
                    continue;
                }
                let loc = module
                    .nodes
                    .get(&anchor_node)
                    .map(|n| n.loc.clone())
                    .unwrap_or_else(|| child.primary_loc.clone());
                out.push(crate::ir::Opportunity {
                    kind: crate::ir::OpportunityKind::InsertReg,
                    path_id: child.id,
                    insert_after: anchor_node,
                    estimated_fo4_before: cross,
                    estimated_fo4_after: child_fo4.max(parent_fo4),
                    loc,
                    rationale: format!(
                        "port-stage `{anchor_root}` of domain `{}`: child {:.1} + parent {:.1} FO4 ({}) cross the port; an elastic register on the port cuts the cross-module path",
                        domain.name, child_fo4, parent_fo4,
                        if parent_desc.is_empty() { "no parent reader measured".to_string() } else { parent_desc }
                    ),
                    requires_clock_in_scope: true,
                    changes_latency: true,
                });
            }
        }
    }
    out
}

/// A149 M13: a statement is an *observer* when nothing functional reads
/// what it writes — its LHS is not an output port, not a flop, and every
/// combinational reader of it (through at most `depth` hops) is itself an
/// observer. Debug aliases (`speculative_write_pointer_q`, read only by
/// `$display`s and assertions, which the IR has no nodes for), RVFI and
/// performance taps are this shape. An observer may read a staged net one
/// stage late: functional state does not depend on it.
pub fn observer_only(module: &TimingModule, node: &IrNode, depth: u32) -> bool {
    let Some(lhs) = node.lhs.as_deref().and_then(TimingModule::root_ident) else {
        return false;
    };
    if node.assign_kind.is_seq_def() {
        return false;
    }
    if module.ports.iter().any(|p| {
        TimingModule::root_ident(&p.name).unwrap_or(&p.name) == lhs
            && (p.direction == "output" || p.direction == "inout")
    }) {
        return false;
    }
    // A net wired into a child instance is read there; the IR has no node for it.
    if module.instances.iter().any(|inst| {
        inst.connections
            .iter()
            .any(|c| TimingModule::root_ident(&c.actual).unwrap_or(&c.actual) == lhs)
    }) {
        return false;
    }
    if depth == 0 {
        return false;
    }
    module
        .nodes
        .values()
        .filter(|n| n.id != node.id)
        .filter(|n| {
            let mut reads = false;
            if let Some(e) = &n.rhs_expr {
                e.walk_idents(&mut |i| {
                    if TimingModule::root_ident(i).unwrap_or(i) == lhs {
                        reads = true;
                    }
                });
            } else if let Some(text) = n.rhs.as_deref() {
                reads = label_has(text, lhs);
            }
            if !reads {
                for g in module.guards.get(&n.id).into_iter().flatten() {
                    if label_has(g, lhs) {
                        reads = true;
                    }
                }
            }
            reads
        })
        .all(|n| observer_only(module, n, depth - 1))
}

/// `steps` as an integer: a literal, a parameter-map entry
/// (`CVA6Cfg.MultStages`), or a module parameter with an integer default.
pub fn cycle_steps_value(
    design: &crate::ir::TimingDesign,
    module: &TimingModule,
    step: &CycleStep,
) -> Option<u32> {
    let text = step.steps.trim();
    if let Ok(n) = text.parse::<u32>() {
        return Some(n);
    }
    if let Some(v) = design.param_map_ints.get(text) {
        return u32::try_from(*v).ok();
    }
    module
        .parameters
        .iter()
        .find(|p| p.name == text)
        .and_then(|p| p.default_expr.as_deref())
        .and_then(|e| e.trim().parse::<u32>().ok())
}

/// The cycle launch `q` is a flop of this module and every update of it is
/// under `hold`: either the non-blocking write itself is guarded by `hold`,
/// or it copies a `_d` net whose every non-identity writer is. A step whose
/// hold does not gate its launch is a single-cycle recurrence as far as the
/// tool can see; a register inside it changes the machine, not its timing.
pub fn hold_gates_launch(module: &TimingModule, step: &CycleStep) -> bool {
    let q = TimingModule::root_ident(&step.q).unwrap_or(&step.q);
    let hold = TimingModule::root_ident(&step.hold).unwrap_or(&step.hold);
    fn root_of(n: &IrNode) -> Option<&str> {
        n.lhs.as_deref().and_then(TimingModule::root_ident)
    }
    let guarded = |n: &IrNode| {
        module
            .guards
            .get(&n.id)
            .is_some_and(|g| g.iter().any(|t| label_has(t, hold)))
    };
    // Reset and flush clears (`q <= '0`) are not steps of the recurrence.
    let constant = |rhs: &str| {
        let r = rhs.trim();
        r.starts_with('\'')
            || r.starts_with("{default")
            || r.starts_with("'{")
            || r.chars().next().is_some_and(|c| c.is_ascii_digit())
    };
    let seq: Vec<&IrNode> = module
        .nodes
        .values()
        .filter(|n| {
            n.assign_kind.is_seq_def()
                && root_of(n) == Some(q)
                && !n.rhs.as_deref().is_some_and(constant)
        })
        .collect();
    if seq.is_empty() {
        return false;
    }
    seq.iter().all(|n| {
        if guarded(n) {
            return true;
        }
        // `q <= q_d`: the hold must guard every writer of q_d except the copy.
        let Some(d) = n
            .rhs
            .as_deref()
            .map(str::trim)
            .filter(|r| r.chars().all(|c| c.is_ascii_alphanumeric() || c == '_'))
        else {
            return false;
        };
        let writers: Vec<&IrNode> = module
            .nodes
            .values()
            .filter(|w| w.assign_kind.is_comb_def() && root_of(w) == Some(d))
            .collect();
        !writers.is_empty()
            && writers
                .iter()
                .all(|w| w.rhs.as_deref().map(str::trim) == Some(q) || guarded(w))
    })
}

/// Why a plan of `wanted` new registers on a `cycle` cone is not a stage,
/// or `None` when the published wait absorbs them. `placed` counts the
/// stages already emitted on that domain. A step of `steps` cycles holds
/// its launch for `steps` cycles, so it can hide at most `steps - 1`
/// registers; a single-cycle step hides none.
pub fn cycle_capacity_refusal(
    design: &crate::ir::TimingDesign,
    module: &TimingModule,
    domain: &PipeDomain,
    placed: usize,
    wanted: usize,
) -> Option<String> {
    let step = domain.cycle.as_ref()?;
    // A149 M7: an advisory domain's cone may take stages; the verifier the
    // designer named carries the obligation.
    if domain.hint.is_some() {
        return None;
    }
    let Some(steps) = cycle_steps_value(design, module, step) else {
        return Some(format!(
            "cycle {}: steps `{}` is not a resolved integer; a stage needs the published wait",
            domain.name, step.steps
        ));
    };
    if !hold_gates_launch(module, step) {
        return Some(format!(
            "cycle {}: `{}` does not gate the launch register `{}`; a register on a single-cycle recurrence changes the machine, not its timing",
            domain.name, step.hold, step.q
        ));
    }
    let capacity = usize::try_from(steps.saturating_sub(1)).unwrap_or(0);
    if placed + wanted > capacity {
        return Some(format!(
            "cycle {}: steps={steps} absorbs {capacity} register(s) under `{}`; {placed} placed and {wanted} planned would add latency the wait does not cover",
            domain.name, step.hold
        ));
    }
    None
}

fn append_note(path: &mut crate::ir::TimingPath, text: String) {
    match path.class_note.as_mut() {
        Some(note) if note.contains("cycle ") => {}
        Some(note) => {
            note.push_str("; ");
            note.push_str(&text);
        }
        None => path.class_note = Some(text),
    }
}

/// One `cycle` step measured against the structural budget.
#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct CycleStepReport {
    /// Module that declared the pragma.
    pub module: String,
    /// Domain name.
    pub domain: String,
    /// Launch name.
    pub q: String,
    /// Capture name.
    pub d: String,
    /// Handshake the rest of the machine waits on.
    pub hold: String,
    /// Published step count.
    pub steps: String,
    /// Worst FO4 of a path from `q` to `d`. None when no such path exists.
    pub step_fo4: Option<f64>,
    /// Structural budget the step is compared with.
    pub budget_fo4: f64,
    /// True only when a path was found and its FO4 is within budget.
    pub within_budget: bool,
}

/// Read-only measurement of every `cycle` pragma. Does not change the board.
pub fn cycle_step_reports(design: &crate::ir::TimingDesign) -> Vec<CycleStepReport> {
    let budget = design.target.budget_fo4;
    let mut out = Vec::new();
    for (id, module) in &design.modules {
        let Some(contract) = resolve(module) else {
            continue;
        };
        for domain in contract.domains {
            let Some(step) = domain.cycle else { continue };
            let step_fo4 = design
                .paths
                .iter()
                .filter(|path| {
                    path.module == *id
                        && path_names(design, path, &step.q)
                        && path_names(design, path, &step.d)
                })
                .map(|path| path.total_fo4)
                .reduce(f64::max);
            let within_budget = step_fo4.is_some_and(|fo4| fo4 <= budget + 1e-6);
            out.push(CycleStepReport {
                module: module.name.clone(),
                domain: domain.name,
                q: step.q,
                d: step.d,
                hold: step.hold,
                steps: step.steps,
                step_fo4,
                budget_fo4: budget,
                within_budget,
            });
        }
    }
    out
}

/// Measure each `cycle` step and decide which cones leave the single-cycle board.
///
/// The step path (`q` launch to `d` capture) always stays. Its FO4 is compared
/// with the budget. Longer cones in the same module are excluded only when
/// that step is within budget. An unmeasured step, or a step over budget,
/// clears `multi_cycle` on the module so a name heuristic cannot hide the
/// clock path. The step note begins with `cycle step`. An over-budget step
/// stays eligible for budget-fit cuts along that cone.
pub fn apply_cycle_contracts(design: &mut crate::ir::TimingDesign) {
    let budget = design.target.budget_fo4;
    let specs: Vec<_> = design
        .modules
        .iter()
        .filter_map(|(id, module)| {
            let contract = resolve(module)?;
            Some(
                contract
                    .domains
                    .into_iter()
                    .filter_map(move |domain| domain.cycle.map(|step| (*id, domain.name, step))),
            )
        })
        .flatten()
        .collect();
    for (mid, dom, step) in specs {
        let step_ix: Vec<usize> = design
            .paths
            .iter()
            .enumerate()
            .filter(|(_, path)| {
                path.module == mid
                    && path_names(design, path, &step.q)
                    && path_names(design, path, &step.d)
            })
            .map(|(i, _)| i)
            .collect();
        let step_fo4 = step_ix
            .iter()
            .map(|i| design.paths[*i].total_fo4)
            .reduce(f64::max);
        let Some(step_fo4) = step_fo4 else {
            for path in design.paths.iter_mut().filter(|p| p.module == mid) {
                path.multi_cycle = false;
            }
            if let Some(path) = design
                .paths
                .iter_mut()
                .filter(|p| p.module == mid)
                .max_by(|a, b| a.total_fo4.total_cmp(&b.total_fo4))
            {
                append_note(
                    path,
                    format!(
                        "cycle {dom}: {}→{} not measured; cone stays on the board",
                        step.q, step.d
                    ),
                );
            }
            continue;
        };
        let within = step_fo4 <= budget + 1e-6;
        // A148 boot validity: a declared step says nothing about the other
        // single-cycle paths of its module. A step inside the budget is noted
        // on them; it does not take them off the board. (An "unrolled" path
        // that runs through q and d is itself a step path above.)
        for (i, path) in design.paths.iter_mut().enumerate() {
            if path.module != mid {
                continue;
            }
            if step_ix.contains(&i) {
                path.multi_cycle = false;
                append_note(
                    path,
                    format!(
                        "cycle step {dom}: {}→{} {step_fo4:.1} FO4 vs budget {budget:.1}",
                        step.q, step.d
                    ),
                );
            } else if within && path.total_fo4 > step_fo4 + 0.05 {
                append_note(
                    path,
                    format!(
                        "cycle {dom}: step {}→{} is {step_fo4:.1} FO4 within budget {budget:.1}; this path is not that step and stays on the board",
                        step.q, step.d
                    ),
                );
            } else if !within {
                path.multi_cycle = false;
                append_note(
                    path,
                    format!(
                        "cycle {dom}: step {}→{} {step_fo4:.1} FO4 over budget {budget:.1}; cone stays on the board",
                        step.q, step.d
                    ),
                );
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{analyze_files, LowerOptions, ParseOptions};
    use std::sync::atomic::AtomicU64;

    static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

    fn analyze(text: &str) -> TimingModule {
        let n = NEXT_FIXTURE.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("svt_pipe_{n}"));
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
    fn cut_ok_overrides_no_cut_on_the_same_name() {
        let m = analyze(
            "module p(input logic valid_i, input logic [15:0] a, b,
       output logic [15:0] sum, output logic other);
     // svt-pipe: protocol ex valid=valid_i id=valid_i
     // svt-pipe: require-contract
     // svt-pipe: no-cut on=sum
     // svt-pipe: no-cut on=other
     // svt-pipe: cut-ok ex on=sum
     assign sum = a + b;
     assign other = a;
     endmodule",
        );
        let c = resolve(&m).expect("contract");
        assert!(c.rejected.is_empty(), "{:?}", c.rejected);
        let sum = m
            .nodes
            .values()
            .find(|n| n.lhs.as_deref() == Some("sum"))
            .unwrap();
        let other = m
            .nodes
            .values()
            .find(|n| n.lhs.as_deref() == Some("other"))
            .unwrap();
        assert!(matches!(
            cut_permission(&m, &c, sum),
            CutPermission::Allowed(Some(_))
        ));
        assert!(matches!(
            cut_permission(&m, &c, other),
            CutPermission::Forbidden(_)
        ));
    }

    #[test]
    fn cycle_capture_unlocks_a_locked_result() {
        let m = analyze(
            "module ex(input logic clk_i, input logic flu_valid_o,
       output logic [7:0] flu_result_o);
     logic [7:0] alu_result;
     // svt-pipe: require-contract
     // svt-pipe: protocol flu valid=flu_valid_o
     // svt-pipe: no-cut on=flu_result_o
     // svt-pipe: no-cut on=alu_result
     // svt-pipe: cycle flu q=alu_result d=flu_result_o hold=flu_valid_o steps=1
     assign alu_result = 8'd1;
     assign flu_result_o = alu_result;
     endmodule",
        );
        let c = resolve(&m).expect("contract");
        assert!(c.rejected.is_empty(), "{:?}", c.rejected);
        let result = m
            .nodes
            .values()
            .find(|n| n.lhs.as_deref() == Some("flu_result_o"))
            .unwrap_or_else(|| {
                let have: Vec<_> = m.nodes.values().map(|n| n.lhs.clone()).collect();
                panic!("no flu_result_o among {have:?}");
            });
        let launch = m
            .nodes
            .values()
            .find(|n| n.lhs.as_deref() == Some("alu_result"))
            .unwrap();
        assert!(
            matches!(
                cut_permission(&m, &c, result),
                CutPermission::Allowed(Some(_))
            ),
            "cycle capture is the permitted stage"
        );
        assert!(
            matches!(cut_permission(&m, &c, launch), CutPermission::Forbidden(_)),
            "launch flop stays locked"
        );
    }

    /// A148 boot validity: a `cycle` step can hide `steps - 1` registers, and
    /// only when its hold gates the launch flop. A single-cycle recurrence
    /// (`steps=1`), a hold that does not gate `q`, or a launch that is not a
    /// register of the module refuses every stage on that cone.
    #[test]
    fn cycle_capacity_follows_the_published_wait_and_the_hold() {
        let text = |steps: &str, gated: bool| {
            format!(
                "module fsm(input logic clk_i, rst_ni, input logic go_i, input logic [15:0] a_i,
       output logic busy_o, output logic [15:0] y_o);
     logic [15:0] acc_q, acc_d, step1, step2;
     logic busy_q;
     // svt-pipe: require-contract
     // svt-pipe: protocol st valid=go_i
     // svt-pipe: no-cut on=acc_q
     // svt-pipe: cycle st q=acc_q d=acc_d hold=busy_q steps={steps}
     // svt-pipe: cut-ok st on=acc_d
     assign step1 = acc_q + a_i;
     assign step2 = step1 * 16'd3;
     assign acc_d = step2 + 16'd1;
     assign busy_o = busy_q;
     assign y_o = acc_q;
     always_ff @(posedge clk_i or negedge rst_ni) begin
       if (!rst_ni) begin acc_q <= '0; busy_q <= 1'b0; end
       else begin
         busy_q <= go_i;
         {gate}
       end
     end
     endmodule",
                gate = if gated {
                    "if (busy_q) acc_q <= acc_d;"
                } else {
                    "acc_q <= acc_d;"
                }
            )
        };
        let design_of = |m: &TimingModule| {
            let mut d =
                crate::ir::TimingDesign::empty(crate::ir::TimingTarget::new(4000.0, 20.0, 0.2));
            d.modules.insert(0, m.clone());
            d
        };
        // steps=3 with the hold on the launch: two registers fit, three do not.
        let m = analyze(&text("3", true));
        let c = resolve(&m).expect("contract");
        assert!(c.rejected.is_empty(), "{:?}", c.rejected);
        let dom = c.domains.iter().find(|d| d.name == "st").unwrap();
        assert!(hold_gates_launch(&m, dom.cycle.as_ref().unwrap()));
        let d = design_of(&m);
        assert_eq!(cycle_capacity_refusal(&d, &m, dom, 0, 2), None);
        assert!(cycle_capacity_refusal(&d, &m, dom, 1, 2)
            .is_some_and(|why| why.contains("absorbs 2 register")));
        // steps=1: a single-cycle recurrence hides nothing.
        let m1 = analyze(&text("1", true));
        let c1 = resolve(&m1).unwrap();
        let dom1 = c1.domains.iter().find(|d| d.name == "st").unwrap();
        assert!(cycle_capacity_refusal(&design_of(&m1), &m1, dom1, 0, 1)
            .is_some_and(|why| why.contains("absorbs 0 register")));
        // steps=3 but the launch updates every cycle: the hold is not a wait.
        let m2 = analyze(&text("3", false));
        let c2 = resolve(&m2).unwrap();
        let dom2 = c2.domains.iter().find(|d| d.name == "st").unwrap();
        assert!(!hold_gates_launch(&m2, dom2.cycle.as_ref().unwrap()));
        assert!(cycle_capacity_refusal(&design_of(&m2), &m2, dom2, 0, 1)
            .is_some_and(|why| why.contains("does not gate the launch")));
    }

    /// A149 balance: an input, a register, and a net derived only from them
    /// off the plan's path can be carried; a net derived from the staged
    /// chain cannot.
    #[test]
    fn side_reads_are_balanceable_when_their_sources_are_stable() {
        let m = analyze(
            "module b(input logic clk_i, input logic [7:0] a_i, k_i, output logic [7:0] y_o);
     logic [7:0] s1, s2, side, side_q, from_chain;
     assign s1 = a_i + 8'd1;
     assign s2 = s1 * 8'd3;
     assign side = k_i ^ 8'h55;
     assign from_chain = s1 | k_i;
     always_ff @(posedge clk_i) side_q <= side;
     assign y_o = s2 + side + side_q + from_chain;
     endmodule",
        );
        let on_plan: BTreeSet<crate::ir::NodeId> = m
            .nodes
            .values()
            .filter(|n| matches!(n.lhs.as_deref(), Some("s1") | Some("s2") | Some("y_o")))
            .map(|n| n.id)
            .collect();
        let no_const = |_: &str| false;
        assert!(
            balanceable_side_read(&m, "k_i", &on_plan, &no_const, 6),
            "input"
        );
        assert!(
            balanceable_side_read(&m, "side_q", &on_plan, &no_const, 6),
            "register"
        );
        assert!(
            balanceable_side_read(&m, "side", &on_plan, &no_const, 6),
            "derived from an input"
        );
        assert!(
            !balanceable_side_read(&m, "from_chain", &on_plan, &no_const, 6),
            "derived from the staged chain"
        );
        assert!(!balanceable_side_read(
            &m, "nothing", &on_plan, &no_const, 6
        ));
    }

    /// A149 M1: a late read of an earlier stage's net is a balance line
    /// starting at the stage after that cut; `stage_for` carries it from
    /// there (the net itself at the start stage, the previous copy later)
    /// and rewires the feeds that read it past its stage.
    #[test]
    fn balance_lines_start_at_the_stage_after_their_cut() {
        let cut_lhs: Vec<String> = ["s1", "s2", "s3"].iter().map(|s| s.to_string()).collect();
        let set =
            |names: &[&str]| -> BTreeSet<String> { names.iter().map(|s| s.to_string()).collect() };
        // reader after cut 0 reads s1 (chain); after cut 1 reads s2 (chain)
        // and s1 (one stage old); after cut 2 (the tail) reads s3, s2, s1.
        let readers = vec![
            set(&["s1", "c_q"]),
            set(&["s2", "s1"]),
            set(&["s3", "s2", "s1", "op_q"]),
        ];
        let balance = alignment_balance(&cut_lhs, &readers);
        assert_eq!(balance, vec![("s1".to_string(), 2), ("s2".to_string(), 3)]);
        let m = analyze(
            "module b(input logic clk_i, valid_i, input logic [3:0] tid_i, input logic [15:0] a_i, c_i,
       output logic [15:0] y_o);
     // svt-pipe: protocol ex valid=valid_i id=tid_i
     logic [15:0] s1, s2, s3;
     assign s1 = a_i + 16'd1;
     assign s2 = s1 + c_i;
     assign s3 = s2 + s1;
     assign y_o = s3 ^ s2 ^ s1;
     endmodule",
        );
        let c = resolve(&m).expect("contract");
        let mut d = c.domains[0].clone();
        for (net, start) in balance {
            d.carry.push(net.clone());
            d.carry_from.insert(net, start);
        }
        let w = |_: &str| Some(16u32);
        let st1 = stage_for(&m, &d, "p1", 1, None, &w);
        assert!(
            st1.carry_src.is_empty(),
            "no balance exists at stage 1: {:?}",
            st1.carry_src
        );
        let st2 = stage_for(&m, &d, "p2", 2, Some("p1"), &w);
        assert_eq!(
            st2.carry_src,
            vec!["s1".to_string()],
            "stage 2 samples s1 itself"
        );
        assert!(
            st2.feed_rewires.is_empty(),
            "stage 2's feed reads its chain predecessor only"
        );
        let st3 = stage_for(&m, &d, "p3", 3, Some("p2"), &w);
        assert_eq!(
            st3.carry_src,
            vec![carry_net("p2", "s1"), "s2".to_string()],
            "stage 3 chains the s1 copy and starts s2"
        );
        assert!(
            st3.feed_rewires
                .iter()
                .any(|(from, to)| from == "s1" && to == &carry_net("p2", "s1")),
            "stage 3's feed reads the stage-2 copy of s1: {:?}",
            st3.feed_rewires
        );
    }

    /// A149 M7: a `hint` domain names its verifier; its cycle cone may take
    /// a stage. Without the word the single-cycle recurrence refuses.
    #[test]
    fn hint_domain_admits_a_stage_on_its_cycle_cone() {
        let src = |hint: &str| {
            format!(
                "module p(input logic clk_i, rst_ni, q_i, train_i, input logic [3:0] pc_i,
       output logic predict_o);
     // svt-pipe: protocol md valid=q_i
     {hint}
     // svt-pipe: cycle md q=tbl_q d=predict_o hold=q_i steps=1
     logic [15:0] tbl_q, tbl_d;
     always_comb begin
       tbl_d = tbl_q;
       predict_o = 1'b0;
       if (train_i) tbl_d[pc_i] = 1'b1;
       if (q_i && tbl_q[pc_i]) predict_o = 1'b1;
     end
     always_ff @(posedge clk_i or negedge rst_ni)
       if (!rst_ni) tbl_q <= '0; else tbl_q <= tbl_d;
     endmodule"
            )
        };
        let plain = analyze(&src(""));
        let c = resolve(&plain).expect("contract");
        assert!(c.rejected.is_empty(), "{:?}", c.rejected);
        let d = crate::ir::TimingDesign::empty(crate::ir::TimingTarget::new(4000.0, 20.0, 0.2));
        assert!(
            cycle_capacity_refusal(&d, &plain, &c.domains[0], 0, 1).is_some(),
            "steps=1 recurrence refuses without a hint"
        );
        let hinted = analyze(&src("// svt-pipe: hint md verified-by=train_i"));
        let c = resolve(&hinted).expect("contract");
        assert!(c.rejected.is_empty(), "{:?}", c.rejected);
        assert_eq!(c.domains[0].hint.as_deref(), Some("train_i"));
        assert!(cycle_capacity_refusal(&d, &hinted, &c.domains[0], 0, 1).is_none());
        let bad = analyze(&src("// svt-pipe: hint md verified-by=nope"));
        let c = resolve(&bad).expect("contract");
        assert!(
            c.rejected.iter().any(|r| r.contains("verifier `nope`")),
            "{:?}",
            c.rejected
        );
    }

    /// A149 M12: an elastic output whose child + parent cone crosses the
    /// budget yields one port-stage opportunity at the port's assembly.
    #[test]
    fn port_stage_opportunity_crosses_the_port() {
        let dir = std::env::temp_dir().join(format!(
            "svt_port_{}_{}",
            std::process::id(),
            NEXT_FIXTURE.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("p.sv");
        std::fs::write(
            &p,
            "module leaf(input logic clk_i, rst_ni, v_i, ready_i, input logic [31:0] a_i, b_i, c_i,
       output logic req_o, output logic [31:0] y_o);
  logic v_q; logic [31:0] a_q, b_q, c_q, pkt;
  always_ff @(posedge clk_i or negedge rst_ni)
    if (!rst_ni) begin v_q <= 1'b0; a_q <= '0; b_q <= '0; c_q <= '0; end
    else if (ready_i || !v_q) begin v_q <= v_i; a_q <= a_i; b_q <= b_i; c_q <= c_i; end
  // svt-pipe: protocol st valid=v_q ready=ready_i
  // svt-pipe: result st valid=req_o y_o
  assign pkt = ((a_q + b_q) ^ c_q) + {c_q[15:0], a_q[15:0]} + (a_q ^ (b_q >> 3)) + (c_q - a_q);
  // svt-pipe: cut-ok st
  assign y_o = pkt;
  assign req_o = v_q;
endmodule
module top(input logic clk_i, rst_ni, v_i, rdy_i, input logic [31:0] a_i, b_i, c_i, output logic [31:0] z_o, output logic q_o);
  logic req; logic [31:0] y, z_d, z_q;
  leaf u0 (.clk_i, .rst_ni, .v_i, .ready_i(rdy_i), .a_i, .b_i, .c_i, .req_o(req), .y_o(y));
  assign z_d = (y * 32'd7) ^ (y >> 3);
  always_ff @(posedge clk_i or negedge rst_ni) if (!rst_ni) z_q <= '0; else z_q <= z_d;
  assign z_o = z_q;
  assign q_o = req;
endmodule",
        )
        .unwrap();
        let out = analyze_files(
            &[p],
            &ParseOptions::default(),
            &LowerOptions {
                target: crate::ir::TimingTarget::new(4000.0, 20.0, 0.2),
                ..Default::default()
            },
        )
        .unwrap();
        let _ = std::fs::remove_dir_all(dir);
        let opps = port_stage_opportunities(&out.design);
        assert_eq!(opps.len(), 1, "{opps:#?}");
        let o = &opps[0];
        assert!(o.rationale.starts_with("port-stage `y_o`"), "{}", o.rationale);
        assert!(o.estimated_fo4_before > o.estimated_fo4_after, "{o:?}");
        let leaf = out.design.modules.values().find(|m| m.name == "leaf").unwrap();
        assert_eq!(
            leaf.nodes.get(&o.insert_after).and_then(|n| n.lhs.as_deref()),
            Some("y_o")
        );
    }

    #[test]
    fn three_class_fixtures_resolve() {
        // Class A: execute result and valid are one step, both locked.
        let class_a = "module ex(input logic clk_i, input logic rst_ni,
       output logic flu_valid_o, output logic [7:0] flu_result_o);
     logic [7:0] alu_result;
     // svt-pipe: require-contract
     // svt-pipe: protocol flu valid=flu_valid_o
     // svt-pipe: result flu valid=flu_valid_o flu_result_o
     // svt-pipe: no-cut on=flu_result_o
     // svt-pipe: no-cut on=flu_valid_o
     // svt-pipe: cycle flu q=alu_result d=flu_result_o hold=flu_valid_o steps=1
     assign alu_result = 8'd0;
     assign flu_result_o = alu_result;
     assign flu_valid_o = 1'b1;
     endmodule";
        // Class B: index stays locked; the step is index to the issued entry.
        let class_b = "module iq(input logic clk_i, input logic valid_i, input logic flush_i,
       output logic [3:0] fetch_entry_o);
     logic [3:0] idx_is_q;
     // svt-pipe: require-contract
     // svt-pipe: protocol iq valid=valid_i flush=flush_i
     // svt-pipe: no-cut on=idx_is_q
     // svt-pipe: cycle iq q=idx_is_q d=fetch_entry_o hold=valid_i steps=1
     assign fetch_entry_o = idx_is_q;
     endmodule";
        // Class C: published depth, output flops locked, product on the result list.
        let class_c = "module mul(input logic clk_i, input logic mult_valid_i,
       output logic mult_valid_q, output logic [7:0] mult_result_q);
     logic [7:0] prod_sum_q, mult_result_d;
     // svt-pipe: protocol mul valid=mult_valid_i id=mult_valid_i
     // svt-pipe: result mul valid=mult_valid_q mult_result_q
     // svt-pipe: latency mul CVA6Cfg.MultStages base=CVA6Cfg.MultStages
     // svt-pipe: cycle mul q=prod_sum_q d=mult_result_d hold=mult_valid_q steps=CVA6Cfg.MultStages
     // svt-pipe: no-cut on=prod_sum
     // svt-pipe: no-cut on=mult_valid_q
     // svt-pipe: no-cut on=mult_result_q
     assign mult_result_d = prod_sum_q;
     assign mult_result_q = mult_result_d;
     assign mult_valid_q = mult_valid_i;
     endmodule";
        for (label, src, q, d) in [
            ("ex_stage", class_a, "alu_result", "flu_result_o"),
            ("instr_queue", class_b, "idx_is_q", "fetch_entry_o"),
            ("multiplier", class_c, "prod_sum_q", "mult_result_d"),
        ] {
            let m = analyze(src);
            let c = resolve(&m).unwrap_or_else(|| panic!("{label} contract"));
            assert!(c.rejected.is_empty(), "{label}: {:?}", c.rejected);
            let step = c.domains[0].cycle.as_ref().expect(label);
            assert_eq!(step.q, q, "{label}");
            assert_eq!(step.d, d, "{label}");
        }
    }

    #[test]
    fn cycle_forms_used_on_the_core_bind() {
        // Miniature of the comment pattern added across the locked modules:
        // id-less protocol, a parameter steps path, and an explicit no-cut
        // on the output flop rather than a bare `no-cut`.
        let src = "module m(input logic clk_i, input logic valid_i, input logic flush_i,
       output logic result_o, output logic valid_o);
     logic state_q, state_d;
     // svt-pipe: protocol dom valid=valid_i flush=flush_i
     // svt-pipe: no-cut on=state_q
     // svt-pipe: no-cut on=valid_o
     // svt-pipe: cycle dom q=state_q d=result_o hold=valid_i steps=CVA6Cfg.MultStages
     assign state_d = state_q;
     assign result_o = state_d;
     assign valid_o = valid_i;
     endmodule";
        let m = analyze(src);
        let c = resolve(&m).expect("contract");
        assert!(c.rejected.is_empty(), "{:?}", c.rejected);
        assert!(c.require_contract);
        assert!(c.no_cut.contains("state_q"));
        assert!(c.no_cut.contains("valid_o"));
        let step = c.domains[0].cycle.as_ref().expect("cycle");
        assert_eq!(step.q, "state_q");
        assert_eq!(step.d, "result_o");
        assert_eq!(step.hold, "valid_i");
        assert_eq!(step.steps, "CVA6Cfg.MultStages");
    }

    #[test]
    fn cycle_pragma_binds_the_enabled_step() {
        let src = "module m(input logic clk_i, rst_ni, valid_i, id_i,
       output logic busy_o, valid_o, result_o);
     logic state_q;
     // svt-pipe: protocol mma valid=valid_i id=id_i
     // svt-pipe: cycle mma q=state_q d=result_o hold=busy_o steps=1
     // svt-pipe: no-cut on=busy_o
     assign result_o = state_q;
     assign busy_o = state_q;
     assign valid_o = state_q;
     endmodule";
        let m = analyze(src);
        let c = resolve(&m).expect("contract");
        assert!(c.rejected.is_empty(), "{:?}", c.rejected);
        let step = c.domains[0].cycle.as_ref().expect("cycle");
        assert_eq!(step.q, "state_q");
        assert_eq!(step.d, "result_o");
        assert_eq!(step.hold, "busy_o");
        assert_eq!(step.steps, "1");
        assert!(c.no_cut.contains("busy_o"));
    }

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
        // `res_valid_o` / `res_tid_o` do not read `op_i`: no rewire of it there
        // (an unread carried signal gets no export either)
        assert!(!st.consumer_rewires.iter().any(|(_, old, _)| old == "op_i"));
        assert!(st
            .consumer_rewires
            .iter()
            .any(|(_, old, new)| old == "tid_i" && new == "sum_svt_p1_id"));
        let st2 = stage_for(&m, d, "sum_svt_p2", 2, Some("sum_svt_p1"), &w);
        assert_eq!(st2.valid_src, "sum_svt_p1_v");
        assert_eq!(st2.kill_expr, "(cancel_i[sum_svt_p1_id])");
        assert!(result_and_valid_paired(d, &st.consumer_rewires));
    }

    #[test]
    fn result_data_without_valid_is_not_paired() {
        let src = "module p(input logic clk_i, input logic valid_i, input logic [2:0] tid_i,
       input logic [7:0] cancel_i, input logic [15:0] a_i,
       output logic res_valid_o, output logic [15:0] res_o);
     // svt-pipe: protocol ex valid=valid_i id=tid_i kill=cancel_i[$id]
     // svt-pipe: result ex valid=res_valid_o res_o
     assign res_o = a_i;
     assign res_valid_o = 1'b1;
     endmodule";
        let m = analyze(src);
        let c = resolve(&m).expect("contract");
        assert!(c.rejected.is_empty(), "{:?}", c.rejected);
        let d = &c.domains[0];
        let st = stage_for(&m, d, "p_svt", 1, None, &|_| None);
        assert!(
            !result_and_valid_paired(d, &st.consumer_rewires),
            "valid assign does not read valid_i: {:?}",
            st.consumer_rewires
        );
    }

    #[test]
    fn unbound_names_and_missing_id_are_rejected_not_guessed() {
        let m = analyze(
            "module p(input logic clk_i, input logic v_i, input logic [2:0] t_i, output logic y_o);
             // svt-pipe: protocol a valid=v_i id=t_i kill=nothing_i[$id]
             // svt-pipe: protocol b valid=v_i kill=t_i[$id]
             // svt-pipe: protocol c valid=v_i kill=v_i
             // svt-pipe: carry zz t_i
             // svt-pipe: require-contract
             assign y_o = v_i;
             endmodule",
        );
        let c = resolve(&m).unwrap();
        // `a`: unbound kill signal; `b`: $id without an id; `zz`: unknown domain
        assert_eq!(c.rejected.len(), 3, "{:?}", c.rejected);
        // `c`: an id-less domain with a global kill (A127)
        assert_eq!(c.domains.len(), 1, "{:?}", c.domains);
        assert!(!c.domains[0].has_id());
        assert_eq!(c.domains[0].kill_for("anything"), "(v_i)");
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

    #[test]
    fn rejected_and_missing_domains_cannot_authorize_bare_cuts() {
        for facts in [
            "// svt-pipe: cut-ok absent on=sum",
            "// svt-pipe: require-contract\n// svt-pipe: cut-ok on=sum",
            "// svt-pipe: protocol ex valid=valid_i\n\
             // svt-pipe: carry ex nonexistent\n// svt-pipe: cut-ok ex on=sum",
        ] {
            let m = analyze(&format!(
                "module p(input logic valid_i, input logic [15:0] a, b, output logic [15:0] sum);\n\
                 {facts}\nassign sum = a+b;\nendmodule"
            ));
            let c = resolve(&m).unwrap();
            let n = m
                .nodes
                .values()
                .find(|n| n.lhs.as_deref() == Some("sum"))
                .unwrap();
            assert!(
                matches!(cut_permission(&m, &c, n), CutPermission::Forbidden(_)),
                "{facts}"
            );
        }
    }

    #[test]
    fn vector_valid_and_unknown_fields_do_not_become_scalar_streams() {
        let m = analyze(SRC);
        let d = resolve(&m).unwrap().domains.remove(0);
        let widths = |s: &str| match s {
            "valid_i" | "res_valid_o" => Some(1),
            "tid_i" => Some(3),
            "op_i" => Some(2),
            _ => None,
        };
        assert!(d.check_widths(&widths).is_ok());
        assert!(d
            .check_widths(&|_| Some(2))
            .unwrap_err()
            .contains("one-bit"));
        assert!(d
            .check_widths(&|s| if s == "op_i" { None } else { widths(s) })
            .is_err());
        // A149 M12: `ready=` is a supported field (elastic stages); an
        // unknown field is still refused, and forbids every cut.
        let m = analyze(&SRC.replace("valid=valid_i", "valid=valid_i ready=valid_i"));
        let c = resolve(&m).unwrap();
        assert!(c.rejected.is_empty(), "{:?}", c.rejected);
        assert_eq!(c.domains[0].ready.as_deref(), Some("valid_i"));
        let m = analyze(&SRC.replace("valid=valid_i", "valid=valid_i ack=valid_i"));
        let c = resolve(&m).unwrap();
        assert!(c
            .rejected
            .iter()
            .any(|r| r.contains("unsupported protocol field")));
        let n = m
            .nodes
            .values()
            .find(|n| n.lhs.as_deref() == Some("sum"))
            .unwrap();
        assert!(matches!(
            cut_permission(&m, &c, n),
            CutPermission::Forbidden(_)
        ));
    }

    #[test]
    fn latency_requires_exact_names_and_distinguishes_source_following_depth() {
        let m = analyze(&SRC.replace(
            "// svt-pipe: carry ex op_i",
            "// svt-pipe: latency ex Cfg.Stages base=2\n// svt-pipe: carry ex op_i",
        ));
        let mut d = resolve(&m).unwrap().domains.remove(0);
        let mut params = std::collections::BTreeMap::from([("Stages".into(), 3)]);
        assert!(d.check_latency(1, &params).unwrap_err().contains("exact"));
        params.insert("Cfg.Stages".into(), 3);
        assert!(d.check_latency(1, &params).is_ok());
        assert!(d.check_latency(2, &params).is_err());
        d.latency.as_mut().unwrap().1 = "0".into();
        assert!(
            d.check_latency(3, &params).is_ok(),
            "a combinational source has zero stages"
        );
        d.latency.as_mut().unwrap().1 = "Cfg.Stages".into();
        assert!(d.check_latency(0, &params).is_ok());
        assert!(d
            .check_latency(1, &params)
            .unwrap_err()
            .contains("RTL boundary"));
        params.insert("Cfg.Stages".into(), -1);
        assert!(d
            .check_latency(0, &params)
            .unwrap_err()
            .contains("positive"));
    }
}
