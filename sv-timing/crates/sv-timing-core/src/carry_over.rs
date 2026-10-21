// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Cross-module carry-over (A149): who consumes a staged net past the port.
//!
//! A stage on a module's output moves that output one cycle later. Inside the
//! module the carried valid/id travel with it; outside, every reader of the
//! connected parent net still samples on the old cycle. This module names
//! those readers through the instance graph so the adaptation can be planned
//! (delay the reader with the stage's valid, propagate the stage upward, or
//! refuse when the net feeds back into the same instance). It is a reference
//! search and a report. It changes no IR and awards no FO4.

use serde::Serialize;

use crate::ir::{AssignKind, TimingDesign, TimingModule};

/// One parent-side reader of a staged output.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct CarryReader {
    /// LHS root of the reading statement (empty for a nameless node).
    pub lhs: String,
    /// Source line in the parent module.
    pub line: u32,
    /// `flop` (non-blocking capture), `comb` (continuous / blocking), or
    /// `output` (a combinational write to a parent output port).
    pub kind: String,
}

/// One instance of the staged module and the parent's use of the port.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct CarryConsumer {
    /// Parent module name.
    pub parent: String,
    /// Instance name.
    pub instance: String,
    /// Parent-side actual net connected to the staged port.
    pub actual: String,
    /// Parent statements that read the actual.
    pub readers: Vec<CarryReader>,
    /// True when the actual (or a combinational net derived from it in the
    /// parent) drives an input of the same instance: a cross-module loop.
    pub feeds_back: bool,
    /// True when the parent writes one of its own output ports from the
    /// actual combinationally: the stage propagates another level up.
    pub propagates_up: bool,
}

/// Carry-over of one emitted stage.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct CarryOver {
    /// Staged module.
    pub module: String,
    /// Staged net (LHS root).
    pub net: String,
    /// Output port the net is (the same name).
    pub port: String,
    /// Stage register name, when known.
    pub stage: Option<String>,
    /// Parent-side consumers.
    pub consumers: Vec<CarryConsumer>,
    /// What the consumers need, in one sentence.
    pub verdict: String,
}

fn root(s: &str) -> &str {
    TimingModule::root_ident(s).unwrap_or(s)
}

pub(crate) fn reads_root(module: &TimingModule, node: &crate::ir::IrNode, name: &str) -> bool {
    let mut hit = false;
    if let Some(e) = &node.rhs_expr {
        e.walk_idents(&mut |i| {
            if root(i) == name {
                hit = true;
            }
        });
    }
    if !hit {
        for g in module.guards.get(&node.id).into_iter().flatten() {
            crate::expr::Expr::parse(g.trim_start_matches('^')).walk_idents(&mut |i| {
                if root(i) == name {
                    hit = true;
                }
            });
        }
    }
    hit
}

/// One caller that must wait more than one cycle for a staged result.
///
/// A single retimed flop still waits one cycle and is not listed. A cone cut
/// of several stages, a combinational caller of those stages, or a
/// recurrence that now takes the new stages plus its own edge, is a bubble:
/// the caller stalls for `wait_cycles` before it may use the result.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct WaitCaller {
    /// Parent module, or the staged module when the caller is internal.
    pub module: String,
    /// Instance name in the parent. Empty for a reader inside the staged module.
    pub instance: String,
    /// LHS the caller writes from the staged net.
    pub caller: String,
    /// Source line of that read.
    pub line: u32,
    /// `flop`, `comb`, `output`, or `recurrence`.
    pub kind: String,
    /// Cycles the caller must wait after the cuts before the result is usable.
    pub wait_cycles: u32,
    /// Why that wait is a throughput bubble.
    pub bubble: String,
}

/// Bottleneck of one net that received one or more InsertReg / cut-ok /
/// cycle-cone stages. `callers` holds only waits of more than one cycle.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct StageBottleneck {
    /// Staged module.
    pub module: String,
    /// Staged net (LHS root).
    pub net: String,
    /// Output port when the net leaves the module.
    pub port: Option<String>,
    /// Stage register names, in the order the edits were recorded.
    pub stages: Vec<String>,
    /// Registers placed on this net. This is the latency the cuts add.
    pub added_cycles: u32,
    /// `cut-ok`, `cycle-cone`, or `insert-reg`.
    pub via: String,
    /// Callers whose wait is greater than one cycle.
    pub callers: Vec<WaitCaller>,
    /// A149 throughput: callers whose wait a declaration covers — the
    /// domain's `throughput … accept=<n>`, or the caller module's
    /// `async <sig> cycles=<n>` — so the wait is no bubble. `bubble` says
    /// which declaration absorbs it.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub absorbed: Vec<WaitCaller>,
    /// A149 throughput: the domain declares `replicate`; a caller that does
    /// not need *this* result may take its own copy of the callee.
    #[serde(default)]
    pub replicable: bool,
    /// One sentence a person can use while reading the emit.
    pub verdict: String,
}

/// One placed stage, as the corrector recorded it.
pub struct StageSite<'a> {
    /// Module name.
    pub module: &'a str,
    /// LHS root that was cut.
    pub net: &'a str,
    /// `pipe_svt_pN` or another stage name.
    pub stage: &'a str,
    /// `cut-ok`, `cycle-cone`, or `insert-reg`.
    pub via: &'a str,
}

/// Group placed stages by net and list callers that must wait more than one
/// cycle. This is a report. It does not change the IR or award FO4.
pub fn bottleneck_trace(design: &TimingDesign, sites: &[StageSite<'_>]) -> Vec<StageBottleneck> {
    let mut groups: Vec<(&str, &str, Vec<usize>)> = Vec::new();
    for (i, s) in sites.iter().enumerate() {
        if let Some(g) = groups
            .iter_mut()
            .find(|g| g.0 == s.module && g.1 == root(s.net))
        {
            g.2.push(i);
        } else {
            groups.push((s.module, root(s.net), vec![i]));
        }
    }
    let mut out = Vec::new();
    for (mod_name, net, idxs) in groups {
        let Some(module) = design.modules.values().find(|m| m.name == mod_name) else {
            continue;
        };
        let added = idxs.len() as u32;
        if added == 0 {
            continue;
        }
        let stages: Vec<String> = idxs.iter().map(|&i| sites[i].stage.to_string()).collect();
        let via = if idxs.iter().any(|&i| sites[i].via == "cycle-cone") {
            "cycle-cone"
        } else if idxs.iter().any(|&i| sites[i].via == "cut-ok") {
            "cut-ok"
        } else {
            "insert-reg"
        };
        let co = carry_over_for_stage(design, module, net, stages.first().map(String::as_str));
        let recurrence = net_is_recurrence(module, net) || co.as_ref().is_some_and(|c| {
            c.consumers.iter().any(|k| k.feeds_back)
        });
        let mut callers = Vec::new();
        if let Some(c) = &co {
            for consumer in &c.consumers {
                for r in &consumer.readers {
                    if let Some(w) = wait_of(r.kind.as_str(), added, consumer.feeds_back || recurrence)
                    {
                        callers.push(WaitCaller {
                            module: consumer.parent.clone(),
                            instance: consumer.instance.clone(),
                            caller: r.lhs.clone(),
                            line: r.line,
                            kind: if consumer.feeds_back {
                                "recurrence".into()
                            } else {
                                r.kind.clone()
                            },
                            wait_cycles: w.0,
                            bubble: w.1,
                        });
                    }
                }
                // One hop past a combinational caller: the flop that samples
                // that net waits the same number of extra cycles.
                let Some(parent_mod) = design.modules.values().find(|m| m.name == consumer.parent)
                else {
                    continue;
                };
                let comb_nets: Vec<&str> = consumer
                    .readers
                    .iter()
                    .filter(|r| r.kind != "flop" && !r.lhs.is_empty())
                    .map(|r| r.lhs.as_str())
                    .collect();
                for n in parent_mod.nodes.values() {
                    if !n.assign_kind.is_seq_def() {
                        continue;
                    }
                    if !comb_nets.iter().any(|net| reads_root(parent_mod, n, net)) {
                        continue;
                    }
                    let lhs = n.lhs.as_deref().map(root).unwrap_or("");
                    if lhs.is_empty() {
                        continue;
                    }
                    if let Some(w) = wait_of("flop", added, consumer.feeds_back || recurrence) {
                        callers.push(WaitCaller {
                            module: consumer.parent.clone(),
                            instance: consumer.instance.clone(),
                            caller: lhs.to_string(),
                            line: n.loc.start_line,
                            kind: if consumer.feeds_back || recurrence {
                                "recurrence".into()
                            } else {
                                "flop".into()
                            },
                            wait_cycles: w.0,
                            bubble: w.1,
                        });
                    }
                }
            }
        }
        for n in module.nodes.values() {
            if !reads_root(module, n, net) {
                continue;
            }
            let lhs = n.lhs.as_deref().map(root).unwrap_or("");
            if lhs.is_empty() || lhs == net {
                continue;
            }
            let kind = if n.assign_kind.is_seq_def() {
                "flop"
            } else {
                "comb"
            };
            if let Some(w) = wait_of(kind, added, recurrence) {
                callers.push(WaitCaller {
                    module: module.name.clone(),
                    instance: String::new(),
                    caller: lhs.to_string(),
                    line: n.loc.start_line,
                    kind: if recurrence { "recurrence".into() } else { kind.into() },
                    wait_cycles: w.0,
                    bubble: w.1,
                });
            }
        }
        callers.sort_by(|a, b| {
            b.wait_cycles
                .cmp(&a.wait_cycles)
                .then(a.module.cmp(&b.module))
                .then(a.caller.cmp(&b.caller))
                .then(a.line.cmp(&b.line))
        });
        callers.dedup_by(|a, b| {
            a.module == b.module && a.caller == b.caller && a.line == b.line
        });
        // A149 throughput declarations: the staged domain's `accept`, the
        // caller modules' `async` reads, the domain's `replicate`.
        let contract = crate::pipe_contract::resolve(module);
        let domain_of_net = contract.as_ref().and_then(|c| {
            c.domains.iter().find(|d| {
                c.cut_ok
                    .iter()
                    .any(|(a, dom, _)| root(a) == net && dom.as_deref().map_or(true, |x| x == d.name))
                    || d.result_also.iter().any(|r| root(r) == net)
                    || d.cycle.as_ref().is_some_and(|s| root(&s.d) == net)
            })
        });
        let accept = domain_of_net.and_then(|d| d.accept);
        let replicable = contract
            .as_ref()
            .zip(domain_of_net)
            .is_some_and(|(c, d)| c.replicable.iter().any(|r| r == &d.name));
        let mut absorbed: Vec<WaitCaller> = Vec::new();
        let mut real: Vec<WaitCaller> = Vec::new();
        for mut c in callers {
            // the caller module's own declaration about the net it reads
            let async_cycles = design
                .modules
                .values()
                .find(|m| m.name == c.module)
                .and_then(crate::pipe_contract::resolve)
                .and_then(|k| {
                    // the parent reads the actual of this port; the staged
                    // module's internal readers read the net itself
                    let actual = co.as_ref().and_then(|co| {
                        co.consumers
                            .iter()
                            .find(|k2| k2.parent == c.module && k2.instance == c.instance)
                            .map(|k2| k2.actual.clone())
                    });
                    actual
                        .and_then(|a| k.async_reads.get(&a).copied())
                        .or_else(|| k.async_reads.get(net).copied())
                });
            if accept.is_some_and(|n| n >= c.wait_cycles) {
                c.bubble = format!(
                    "absorbed: domain declares `throughput accept={}`; a {}-cycle wait is within what its consumers take without a bubble",
                    accept.unwrap_or(0),
                    c.wait_cycles
                );
                absorbed.push(c);
            } else if async_cycles.is_some_and(|n| n >= c.wait_cycles) {
                c.bubble = format!(
                    "absorbed: `{}` declares `async … cycles={}` on this read; the interface tolerates the {}-cycle wait",
                    c.module,
                    async_cycles.unwrap_or(0),
                    c.wait_cycles
                );
                absorbed.push(c);
            } else {
                real.push(c);
            }
        }
        if real.is_empty() && absorbed.is_empty() {
            continue;
        }
        let worst = real.iter().map(|c| c.wait_cycles).max().unwrap_or(0);
        let verdict = if real.is_empty() {
            format!(
                "{via} placed {added} stage(s) on `{net}`; {n} caller(s) wait, all absorbed by declared throughput",
                n = absorbed.len(),
            )
        } else {
            format!(
                "{via} placed {added} stage(s) on `{net}`; {n} caller(s) wait up to {worst} cycle(s), a bubble on a dependent use{}{}",
                if absorbed.is_empty() { String::new() } else { format!("; {} absorbed by declaration", absorbed.len()) },
                if replicable { "; the domain is replicable: a caller that does not need this result may take its own copy" } else { "" },
                n = real.len(),
            )
        };
        out.push(StageBottleneck {
            module: module.name.clone(),
            net: net.to_string(),
            port: co.as_ref().map(|c| c.port.clone()),
            stages,
            added_cycles: added,
            via: via.to_string(),
            callers: real,
            absorbed,
            replicable,
            verdict,
        });
    }
    out.sort_by(|a, b| {
        let aw = a.callers.iter().map(|c| c.wait_cycles).max().unwrap_or(0);
        let bw = b.callers.iter().map(|c| c.wait_cycles).max().unwrap_or(0);
        bw.cmp(&aw)
            .then(a.module.cmp(&b.module))
            .then(a.net.cmp(&b.net))
    });
    out
}

/// `(wait_cycles, bubble)` when the caller must wait more than one cycle.
pub(crate) fn wait_of(kind: &str, added: u32, recurrence: bool) -> Option<(u32, String)> {
    if recurrence {
        let wait = added.saturating_add(1);
        if wait > 1 {
            return Some((
                wait,
                format!(
                    "recurrence: the caller uses this result to produce the next one, so {added} cut(s) make the loop take {wait} cycle(s)"
                ),
            ));
        }
        return None;
    }
    match kind {
        "flop" => {
            // One stage can move into the capture the caller already has.
            // Further stages are a stall on top of that capture.
            if added > 1 {
                Some((
                    added,
                    format!(
                        "flop caller: one stage can move into the existing capture; {added} cut(s) leave a {added}-cycle wait"
                    ),
                ))
            } else {
                None
            }
        }
        "comb" | "output" => {
            if added > 1 {
                Some((
                    added,
                    format!(
                        "combinational caller sampled this result in the same cycle; {added} cut(s) make it wait {added} cycle(s)"
                    ),
                ))
            } else {
                None
            }
        }
        _ => None,
    }
}

pub(crate) fn net_is_recurrence(module: &TimingModule, net: &str) -> bool {
    let Some(c) = crate::pipe_contract::resolve(module) else {
        return false;
    };
    c.domains.iter().any(|d| {
        d.cycle
            .as_ref()
            .is_some_and(|s| s.q == net || s.d == net)
    })
}

/// Consumers of `net` (an output port of `module`) across the instance graph.
/// `None` when the net is not an output port: an internal stage has no
/// cross-module carry-over.
pub fn carry_over_for_stage(
    design: &TimingDesign,
    module: &TimingModule,
    net: &str,
    stage: Option<&str>,
) -> Option<CarryOver> {
    let net = root(net);
    let port = module
        .ports
        .iter()
        .find(|p| root(&p.name) == net && (p.direction == "output" || p.direction == "inout"))?;
    let inputs: std::collections::BTreeSet<&str> = module
        .ports
        .iter()
        .filter(|p| p.direction == "input")
        .map(|p| root(&p.name))
        .collect();
    let mut consumers = Vec::new();
    for inst in design.all_instances().into_iter().filter(|i| {
        i.child_type == module.name
            || i.child_module == design.module_names.get(&module.name).copied()
    }) {
        let Some(conn) = inst
            .connections
            .iter()
            .find(|c| root(&c.formal) == root(&port.name))
        else {
            continue;
        };
        let actual = root(&conn.actual).to_string();
        let Some(parent) = design.modules.get(&inst.parent_module) else {
            continue;
        };
        let parent_outputs: std::collections::BTreeSet<&str> = parent
            .ports
            .iter()
            .filter(|p| p.direction == "output" || p.direction == "inout")
            .map(|p| root(&p.name))
            .collect();
        let mut readers = Vec::new();
        let mut derived: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
        derived.insert(actual.clone());
        let mut propagates_up = false;
        for n in parent.nodes.values() {
            if !reads_root(parent, n, &actual) {
                continue;
            }
            let lhs = n.lhs.as_deref().map(root).unwrap_or("").to_string();
            let kind = if n.assign_kind.is_seq_def() {
                "flop"
            } else if parent_outputs.contains(lhs.as_str()) {
                propagates_up = true;
                "output"
            } else {
                "comb"
            };
            if n.assign_kind != AssignKind::Nonblocking && !lhs.is_empty() {
                derived.insert(lhs.clone());
            }
            readers.push(CarryReader {
                lhs,
                line: n.loc.start_line,
                kind: kind.into(),
            });
        }
        readers.sort_by_key(|r| (r.line, r.lhs.clone()));
        readers.dedup();
        // One combinational hop: a parent net derived from the actual that
        // drives an input of this same instance closes a cross-module loop.
        let feeds_back = inst
            .connections
            .iter()
            .any(|c| inputs.contains(root(&c.formal)) && derived.contains(root(&c.actual)));
        consumers.push(CarryConsumer {
            parent: parent.name.clone(),
            instance: inst.instance_name.clone(),
            actual,
            readers,
            feeds_back,
            propagates_up,
        });
    }
    let verdict = if consumers.is_empty() {
        "no instance on the design reads this port; the stage is local".to_string()
    } else if consumers.iter().any(|c| c.feeds_back) {
        "feedback: a parent net derived from this port drives an input of the same instance; the stage closes a cross-module recurrence and needs a protocol decision, not a delay".to_string()
    } else if consumers.iter().any(|c| c.propagates_up) {
        "propagates: a parent output is written from this port combinationally; the stage moves that output too and its consumers need the same adaptation".to_string()
    } else if consumers
        .iter()
        .all(|c| c.readers.iter().all(|r| r.kind == "flop"))
    {
        "adaptable: every parent reader is a flop capture; sample it one cycle later with the stage's valid".to_string()
    } else {
        "adaptable with retiming: parent combinational readers must be staged with the same valid before their own captures".to_string()
    };
    Some(CarryOver {
        module: module.name.clone(),
        net: net.to_string(),
        port: port.name.clone(),
        stage: stage.map(str::to_string),
        consumers,
        verdict,
    })
}

/// One adaptation a stage on a port asks of the design outside the module.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Adaptation {
    /// Module the adaptation lands in.
    pub module: String,
    /// Net whose timing moves by one cycle there.
    pub net: String,
    /// `delay-capture` (a flop reader samples one cycle later, with the
    /// stage's valid), `stage-comb` (a combinational reader is re-staged and
    /// its own readers follow), `propagate-port` (a parent output moves and
    /// the walk continues in the grandparent), `blocked-feedback` (the net
    /// re-enters an instance already on the walk: a cross-module recurrence).
    pub action: String,
    /// Other reads of the adapted statement that must take the same delay
    /// (balance registers), when known.
    pub balance: Vec<String>,
    /// Hops from the staged port.
    pub depth: u32,
    /// M3: the guards of a `delay-capture` (reset, flush, enable) as written;
    /// the capture must additionally be gated by the stage's valid, and the
    /// parent's flush must enter the domain's kill.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub guards: Vec<String>,
}

/// The adaptation plan of a stage on `net` (an output port of `module`).
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct PropagationPlan {
    /// Staged module and port.
    pub module: String,
    /// Staged port.
    pub port: String,
    /// Adaptations in walk order.
    pub steps: Vec<Adaptation>,
    /// True when every frontier ended at a flop capture or an unread net;
    /// false when any step is `blocked-feedback` or the walk hit its bound.
    pub valid: bool,
    /// M4: true when the lag can be absorbed with **no added latency** — every
    /// step is a `delay-capture` that reads nothing but the staged net, and
    /// all those captures share one guard class (same reset / flush /
    /// enable). The parent registers then move into the child (backward
    /// retiming across the port); `moved_registers` names them.
    pub retimable: bool,
    /// M4: parent registers a retiming would move into the child.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub moved_registers: Vec<String>,
    /// One sentence.
    pub verdict: String,
}

fn reads_of(module: &TimingModule, node: &crate::ir::IrNode) -> Vec<String> {
    let mut out = std::collections::BTreeSet::new();
    if let Some(e) = &node.rhs_expr {
        e.walk_idents(&mut |i| {
            out.insert(root(i).to_string());
        });
    }
    for g in module.guards.get(&node.id).into_iter().flatten() {
        crate::expr::Expr::parse(g.trim_start_matches('^')).walk_idents(&mut |i| {
            out.insert(root(i).to_string());
        });
    }
    out.into_iter().collect()
}

/// Walk the consumers of a staged output across the instance graph. A flop
/// reader absorbs the lag (its other reads are the balance it needs); a
/// combinational reader passes it on inside the parent; a parent output
/// passes it to the grandparent; a net that drives an input of an instance
/// already on the walk is feedback. Bounded by `max_steps`.
pub fn propagation_plan(
    design: &TimingDesign,
    module: &TimingModule,
    net: &str,
    max_steps: usize,
) -> Option<PropagationPlan> {
    let net = root(net);
    let port = module
        .ports
        .iter()
        .find(|p| root(&p.name) == net && (p.direction == "output" || p.direction == "inout"))?;
    let mut steps: Vec<Adaptation> = Vec::new();
    let mut valid = true;
    let mut bounded = false;
    // (module name, net, depth) frontier; visited (module, net).
    let mut frontier: Vec<(String, String, u32)> = vec![(module.name.clone(), net.to_string(), 0)];
    let mut seen: std::collections::BTreeSet<(String, String)> = std::collections::BTreeSet::new();
    // instances whose outputs the walk has moved: re-entering one is feedback
    let mut moved_instances: std::collections::BTreeSet<(String, String)> =
        std::collections::BTreeSet::new();
    while let Some((mname, n, depth)) = frontier.pop() {
        if !seen.insert((mname.clone(), n.clone())) {
            continue;
        }
        if steps.len() >= max_steps {
            bounded = true;
            break;
        }
        let Some(&mid) = design.module_names.get(&mname) else {
            continue;
        };
        let Some(m) = design.modules.get(&mid) else {
            continue;
        };
        // Is `n` an output port of `m`? Then the lag crosses into every parent.
        let is_output = m
            .ports
            .iter()
            .any(|p| root(&p.name) == n && (p.direction == "output" || p.direction == "inout"));
        if is_output {
            for inst in design.all_instances().into_iter().filter(|i| i.child_type == m.name) {
                let Some(conn) = inst.connections.iter().find(|c| root(&c.formal) == n) else {
                    continue;
                };
                let actual = root(&conn.actual).to_string();
                let Some(parent) = design.modules.get(&inst.parent_module) else {
                    continue;
                };
                moved_instances.insert((parent.name.clone(), inst.instance_name.clone()));
                if depth > 0 {
                    steps.push(Adaptation {
                        module: parent.name.clone(),
                        net: actual.clone(),
                        action: "propagate-port".into(),
                        balance: Vec::new(),
                        depth,
                        guards: Vec::new(),
                    });
                }
                frontier.push((parent.name.clone(), actual, depth + 1));
            }
            if depth == 0 {
                continue;
            }
        }
        // Readers of `n` inside `m`.
        let inputs_of = |child: &str| -> std::collections::BTreeSet<String> {
            design
                .module_names
                .get(child)
                .and_then(|id| design.modules.get(id))
                .map(|c| {
                    c.ports
                        .iter()
                        .filter(|p| p.direction == "input")
                        .map(|p| root(&p.name).to_string())
                        .collect()
                })
                .unwrap_or_default()
        };
        // Feedback: `n` drives an input of an instance whose output the walk moved.
        for inst in m.instances.iter() {
            let ins = inputs_of(&inst.child_type);
            if inst
                .connections
                .iter()
                .any(|c| ins.contains(root(&c.formal)) && root(&c.actual) == n)
                && moved_instances.contains(&(m.name.clone(), inst.instance_name.clone()))
            {
                steps.push(Adaptation {
                    module: m.name.clone(),
                    net: n.clone(),
                    action: format!(
                        "blocked-feedback: drives an input of `{}`",
                        inst.instance_name
                    ),
                    balance: Vec::new(),
                    depth,
                    guards: Vec::new(),
                });
                valid = false;
            }
        }
        for node in m.nodes.values() {
            if !reads_root(m, node, &n) {
                continue;
            }
            let lhs = node.lhs.as_deref().map(root).unwrap_or("").to_string();
            // reset and clock pins are guards, not data the capture merges
            let balance: Vec<String> = reads_of(m, node)
                .into_iter()
                .filter(|r| r != &n && !(r.contains("rst") || r.contains("clk")))
                .collect();
            let guards: Vec<String> = m
                .guards
                .get(&node.id)
                .map(|g| {
                    g.iter()
                        .map(|s| s.trim_start_matches('^').to_string())
                        .collect()
                })
                .unwrap_or_default();
            if node.assign_kind.is_seq_def() {
                steps.push(Adaptation {
                    module: m.name.clone(),
                    net: lhs,
                    action: "delay-capture".into(),
                    balance,
                    depth,
                    guards,
                });
            } else if !lhs.is_empty() {
                steps.push(Adaptation {
                    module: m.name.clone(),
                    net: lhs.clone(),
                    action: "stage-comb".into(),
                    balance,
                    depth,
                    guards,
                });
                frontier.push((m.name.clone(), lhs, depth + 1));
            }
        }
    }
    if bounded {
        valid = false;
    }
    // M4: a pure capture frontier of one guard class is a retiming, not a
    // latency change. Reset/clock pins in the guards do not split classes.
    let captures: Vec<&Adaptation> = steps
        .iter()
        .filter(|s| s.action == "delay-capture")
        .collect();
    let class_of = |a: &Adaptation| -> Vec<String> {
        a.guards
            .iter()
            .filter(|g| !(g.contains("rst") || g.contains("clk")))
            .cloned()
            .collect()
    };
    let retimable = valid
        && !captures.is_empty()
        && steps.iter().all(|s| s.action == "delay-capture")
        && captures.iter().all(|c| c.balance.is_empty())
        && captures
            .windows(2)
            .all(|w| class_of(w[0]) == class_of(w[1]));
    let moved_registers: Vec<String> = if retimable {
        captures
            .iter()
            .map(|c| format!("{}.{}", c.module, c.net))
            .collect()
    } else {
        Vec::new()
    };
    let verdict = if retimable {
        format!(
            "retimable: {} parent capture(s) of one guard class read only the staged net; move them into the child and the stage adds no latency",
            captures.len()
        )
    } else if !valid && bounded {
        format!("walk exceeded {max_steps} adaptations; the lag does not settle within the bound")
    } else if !valid {
        "feedback: the staged output re-enters an instance it left; a cross-module recurrence, not a delay".into()
    } else if steps.is_empty() {
        "no reader outside the module; the stage is local".into()
    } else {
        format!(
            "settles: {} capture(s) sample one cycle later, {} combinational net(s) re-staged, {} port(s) propagated",
            steps.iter().filter(|s| s.action == "delay-capture").count(),
            steps.iter().filter(|s| s.action == "stage-comb").count(),
            steps.iter().filter(|s| s.action == "propagate-port").count()
        )
    };
    Some(PropagationPlan {
        module: module.name.clone(),
        port: port.name.clone(),
        steps,
        valid,
        retimable,
        moved_registers,
        verdict,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{analyze_files, LowerOptions, ParseOptions};

    fn analyze(text: &str) -> TimingDesign {
        static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let dir = std::env::temp_dir().join(format!(
            "svt_carry_{}_{}",
            std::process::id(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("c.sv");
        std::fs::write(&p, text).unwrap();
        let out = analyze_files(&[p], &ParseOptions::default(), &LowerOptions::default()).unwrap();
        let _ = std::fs::remove_dir_all(dir);
        out.design
    }

    #[test]
    fn readers_feedback_and_propagation_are_named() {
        let d = analyze(
            "module leaf(input logic clk_i, input logic [7:0] a_i, output logic [7:0] y_o);
  assign y_o = a_i + 8'd1;
endmodule
module top(input logic clk_i, input logic [7:0] x_i, output logic [7:0] z_o, output logic [7:0] w_o);
  logic [7:0] y, y_q, fb;
  leaf u0 (.clk_i(clk_i), .a_i(fb), .y_o(y));
  assign fb = x_i ^ y;
  assign z_o = y;
  always_ff @(posedge clk_i) y_q <= y;
  assign w_o = y_q;
endmodule",
        );
        let leaf = d.modules.values().find(|m| m.name == "leaf").unwrap();
        let co = carry_over_for_stage(&d, leaf, "y_o", Some("pipe_svt_p1")).expect("port");
        assert_eq!(co.consumers.len(), 1);
        let c = &co.consumers[0];
        assert_eq!(c.actual, "y");
        assert!(c.feeds_back, "fb = x ^ y drives a_i");
        assert!(c.propagates_up, "z_o = y");
        assert!(c.readers.iter().any(|r| r.lhs == "y_q" && r.kind == "flop"));
        assert!(co.verdict.starts_with("feedback"));
        assert!(carry_over_for_stage(&d, leaf, "a_i", None).is_none());
        let plan = propagation_plan(&d, leaf, "y_o", 32).expect("port");
        assert!(!plan.valid, "fb re-enters u0: {plan:?}");
        assert!(plan
            .steps
            .iter()
            .any(|s| s.action.starts_with("blocked-feedback")));
    }

    /// M4: a parent that only captures the port into flops of one guard
    /// class can absorb the stage by moving those flops into the child.
    #[test]
    fn a_pure_capture_frontier_is_retimable() {
        let d = analyze(
            "module leaf(input logic clk_i, input logic [7:0] a_i, output logic [7:0] y_o);
  assign y_o = a_i + 8'd1;
endmodule
module top(input logic clk_i, rst_ni, input logic [7:0] x_i, output logic [7:0] w_o, z_o);
  logic [7:0] y, y_q, y2_q;
  leaf u0 (.clk_i(clk_i), .a_i(x_i), .y_o(y));
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin y_q <= '0; y2_q <= '0; end
    else begin y_q <= y; y2_q <= y; end
  end
  assign w_o = y_q;
  assign z_o = y2_q;
endmodule",
        );
        let leaf = d.modules.values().find(|m| m.name == "leaf").unwrap();
        let plan = propagation_plan(&d, leaf, "y_o", 32).expect("port");
        assert!(plan.valid && plan.retimable, "{plan:?}");
        assert_eq!(plan.moved_registers.len(), 2, "{plan:?}");
        assert!(plan.verdict.starts_with("retimable"));
    }

    #[test]
    fn a_feed_forward_consumer_settles_at_its_captures() {
        let d = analyze(
            "module leaf(input logic clk_i, input logic [7:0] a_i, output logic [7:0] y_o);
  assign y_o = a_i + 8'd1;
endmodule
module top(input logic clk_i, input logic [7:0] x_i, k_i, output logic [7:0] w_o);
  logic [7:0] y, s, s_q;
  leaf u0 (.clk_i(clk_i), .a_i(x_i), .y_o(y));
  assign s = y ^ k_i;
  always_ff @(posedge clk_i) s_q <= s;
  assign w_o = s_q;
endmodule",
        );
        let leaf = d.modules.values().find(|m| m.name == "leaf").unwrap();
        let plan = propagation_plan(&d, leaf, "y_o", 32).expect("port");
        assert!(plan.valid, "{plan:?}");
        let comb = plan
            .steps
            .iter()
            .find(|s| s.action == "stage-comb")
            .expect("s re-staged");
        assert_eq!(comb.net, "s");
        assert_eq!(
            comb.balance,
            vec!["k_i".to_string()],
            "k_i needs the same delay"
        );
        assert!(plan
            .steps
            .iter()
            .any(|s| s.action == "delay-capture" && s.net == "s_q"));
        assert!(plan.verdict.starts_with("settles"));
    }

    /// A149 throughput: a caller module that declares `async <net> cycles=n`
    /// on the net it reads, or a domain that declares `throughput accept=n`,
    /// moves its waiting callers out of the bubble list.
    #[test]
    fn declared_throughput_absorbs_waits() {
        let src = |leaf_decl: &str, top_decl: &str| {
            format!(
                "module leaf(input logic clk_i, rst_ni, v_i, rdy_i, input logic [7:0] a_i, output logic q_o, output logic [7:0] y_o);
  // svt-pipe: protocol st valid=v_i ready=rdy_i
  // svt-pipe: result st valid=q_o y_o
  {leaf_decl}
  // svt-pipe: cut-ok st
  assign y_o = a_i + 8'd1;
  assign q_o = v_i;
endmodule
module top(input logic clk_i, v_i, rdy_i, input logic [7:0] x_i, k_i, output logic [7:0] w_o, output logic q_o);
  logic [7:0] y, s, s_q;
  {top_decl}
  leaf u0 (.clk_i(clk_i), .rst_ni(1'b1), .v_i(v_i), .rdy_i(rdy_i), .a_i(x_i), .q_o(q_o), .y_o(y));
  assign s = y ^ k_i;
  always_ff @(posedge clk_i) s_q <= s;
  assign w_o = s_q;
endmodule"
            )
        };
        let two = [
            StageSite { module: "leaf", net: "y_o", stage: "pipe_svt_p1", via: "cut-ok" },
            StageSite { module: "leaf", net: "y_o", stage: "pipe_svt_p2", via: "cut-ok" },
        ];
        let plain = analyze(&src("", ""));
        let rows = bottleneck_trace(&plain, &two);
        assert_eq!(rows.len(), 1);
        assert!(!rows[0].callers.is_empty() && rows[0].absorbed.is_empty(), "{rows:?}");

        let by_domain = analyze(&src("// svt-pipe: throughput st accept=2", ""));
        let rows = bottleneck_trace(&by_domain, &two);
        assert_eq!(rows.len(), 1, "{rows:?}");
        assert!(rows[0].callers.is_empty(), "{rows:?}");
        assert!(rows[0].absorbed.iter().all(|c| c.bubble.contains("throughput accept=2")), "{rows:?}");
        assert!(rows[0].verdict.contains("all absorbed"), "{}", rows[0].verdict);

        let by_caller = analyze(&src("", "// svt-pipe: async y cycles=2"));
        let rows = bottleneck_trace(&by_caller, &two);
        assert_eq!(rows.len(), 1, "{rows:?}");
        assert!(rows[0].callers.is_empty(), "{rows:?}");
        assert!(rows[0].absorbed.iter().all(|c| c.bubble.contains("async")), "{rows:?}");

        let replicable = analyze(&src("// svt-pipe: replicate st", ""));
        let rows = bottleneck_trace(&replicable, &two);
        assert!(rows[0].replicable && rows[0].verdict.contains("replicable"), "{rows:?}");
    }

    #[test]
    fn callers_waiting_more_than_one_cycle_are_listed() {
        let d = analyze(
            "module leaf(input logic clk_i, input logic [7:0] a_i, output logic [7:0] y_o);
  assign y_o = a_i + 8'd1;
endmodule
module top(input logic clk_i, input logic [7:0] x_i, k_i, output logic [7:0] w_o);
  logic [7:0] y, s, s_q;
  leaf u0 (.clk_i(clk_i), .a_i(x_i), .y_o(y));
  assign s = y ^ k_i;
  always_ff @(posedge clk_i) s_q <= s;
  assign w_o = s_q;
endmodule",
        );
        let one = [StageSite {
            module: "leaf",
            net: "y_o",
            stage: "pipe_svt_p1",
            via: "cut-ok",
        }];
        assert!(
            bottleneck_trace(&d, &one).is_empty(),
            "one stage is a one-cycle wait and is not a bubble list"
        );
        let two = [
            StageSite {
                module: "leaf",
                net: "y_o",
                stage: "pipe_svt_p1",
                via: "cut-ok",
            },
            StageSite {
                module: "leaf",
                net: "y_o",
                stage: "pipe_svt_p2",
                via: "cycle-cone",
            },
        ];
        let rows = bottleneck_trace(&d, &two);
        assert_eq!(rows.len(), 1, "{rows:?}");
        let row = &rows[0];
        assert_eq!(row.added_cycles, 2);
        assert_eq!(row.via, "cycle-cone");
        assert!(row.callers.iter().any(|c| c.caller == "s" && c.wait_cycles == 2));
        assert!(row.callers.iter().any(|c| c.caller == "s_q" && c.wait_cycles == 2));
        assert!(row.verdict.contains("bubble"));
    }

    #[test]
    fn a_feedback_caller_waits_the_loop_plus_the_cuts() {
        let d = analyze(
            "module leaf(input logic clk_i, input logic [7:0] a_i, output logic [7:0] y_o);
  assign y_o = a_i + 8'd1;
endmodule
module top(input logic clk_i, input logic [7:0] x_i, output logic [7:0] z_o);
  logic [7:0] y, fb;
  leaf u0 (.clk_i(clk_i), .a_i(fb), .y_o(y));
  assign fb = x_i ^ y;
  assign z_o = y;
endmodule",
        );
        let one = [StageSite {
            module: "leaf",
            net: "y_o",
            stage: "pipe_svt_p1",
            via: "insert-reg",
        }];
        let rows = bottleneck_trace(&d, &one);
        assert_eq!(rows.len(), 1, "{rows:?}");
        assert!(
            rows[0].callers.iter().any(|c| c.kind == "recurrence" && c.wait_cycles == 2),
            "{:?}",
            rows[0].callers
        );
    }
}
