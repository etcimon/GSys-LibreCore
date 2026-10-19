// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Board-matching load term (delay-v43): unbuffered fanout delay per driver.

//! Output and select-broadcast loads.
//!
//! The `fo4-v1` table prices each operator at a fanout-of-four load. The
//! module board maps with minimum-size cells and no repair: a net keeps every
//! load up to the board's broadcast limit (64), and a driver above it is
//! taken out of the timing graph. A gate's delay grows linearly with its load
//! (logical effort `d = g·h + p`), so a driver of `F` unit loads costs about
//! `g/5` FO4 per load beyond the reference four. The paths the board shows
//! carry exactly that: an `OAI33` driving 64 loads at 1.04 ns, `NOR4`s with
//! 51–59 loads at 0.94–1.11 ns (A144 path reports, Nangate45).
//!
//! Loads counted per bit of a net:
//!
//! * a data read (operand, comparator input, flop D) is one load per
//!   occurrence;
//! * a bare-identifier select — `if (v)`, `v ? a : b`, a dynamic index — drives
//!   one mux select per bit of the guarded / selected value;
//! * a compound guard predicate is one net (its compare/AND output) driving
//!   the select of every bit its arm assigns; the guarded node pays it.
//!
//! The extra delay is charged to the last writer of the net in its region
//! (where the final value leaves the cone), and to each node for its own
//! compound select broadcasts. Above the cap the board removes the driver;
//! a repaired netlist buffers it — one FO4 stage per factor of four.

use std::collections::{BTreeMap, BTreeSet};

use crate::expr::Expr;
use crate::ir::{NodeId, RegionKind, TimingModule};
use crate::measure::CostModel;
use crate::ref_order::dep_key;
use crate::width::WidthResolver;

/// Mux inputs one select bit of a dynamic index drives per selected bit.
const INDEX_SPREAD: f64 = 4.0;

fn load_enabled(model: &CostModel) -> bool {
    model.load_per_fanout.is_finite() && model.load_per_fanout > 0.0
}

/// Extra FO4 of a driver with `fanout` unit loads beyond the reference load.
pub fn load_fo4(model: &CostModel, fanout: f64) -> f64 {
    let reference = model.load_reference_fanout.max(1.0);
    if fanout.is_nan() || fanout <= reference || !load_enabled(model) {
        return 0.0;
    }
    if fanout <= model.load_fanout_cap {
        model.load_per_fanout * (fanout - reference)
    } else {
        model.logic_bit * (fanout / reference).log(4.0).ceil()
    }
}

/// Net key for loads: members kept, element indices dropped
/// (`q[k].be` → `q.be`), so a field read loads that field's bits.
fn load_key(name: &str) -> String {
    dep_key(name).replace("[*]", "")
}

fn bare_select_ident(e: &Expr) -> Option<&str> {
    match e {
        Expr::Ident { name } => Some(name),
        Expr::Unary { op, arg } if op == "!" || op == "~" => bare_select_ident(arg),
        Expr::Index { base, index } if matches!(**index, Expr::Literal { .. }) => {
            bare_select_ident(base)
        }
        _ => None,
    }
}

#[derive(Default)]
struct LoadCounts {
    net: BTreeMap<String, f64>,
}

impl LoadCounts {
    fn add(&mut self, name: &str, n: f64) {
        let k = load_key(name);
        if !k.is_empty() {
            *self.net.entry(k).or_insert(0.0) += n;
        }
    }

    /// Data reads of `e`; returns the widest compound-select broadcast inside
    /// it (a ternary whose condition is not a bare signal).
    fn data(&mut self, e: &Expr, w: f64) -> f64 {
        match e {
            Expr::Ident { name } => {
                self.add(name, 1.0);
                self.index_selects(name, w);
                0.0
            }
            Expr::Literal { .. } | Expr::Opaque { .. } => 0.0,
            Expr::Unary { arg, .. } => self.data(arg, w),
            Expr::Binary { left, right, .. } => self.data(left, w).max(self.data(right, w)),
            Expr::Ternary {
                cond,
                then_e,
                else_e,
            } => {
                let inner = self.data(then_e, w).max(self.data(else_e, w));
                if let Some(id) = bare_select_ident(cond) {
                    self.add(id, w);
                    inner
                } else {
                    self.data(cond, 1.0).max(inner).max(w)
                }
            }
            Expr::Concat { parts } => parts.iter().map(|p| self.data(p, w)).fold(0.0, f64::max),
            Expr::Replicate { body, .. } => self.data(body, w),
            Expr::Index { base, index } => {
                let b = self.data(base, w);
                if matches!(**index, Expr::PartSelect { .. } | Expr::Literal { .. }) {
                    b.max(self.data(index, 1.0))
                } else {
                    index.walk_idents(&mut |id| self.add(id, w * INDEX_SPREAD));
                    b
                }
            }
            Expr::PartSelect { left, .. } => {
                // `[i +: W]` with a runtime base is a shifter select.
                left.walk_idents(&mut |id| self.add(id, w * INDEX_SPREAD));
                0.0
            }
            Expr::Call { args, .. } => args.iter().map(|a| self.data(a, w)).fold(0.0, f64::max),
        }
    }

    /// Identifiers inside the brackets of a flattened member path
    /// (`wbuffer_q[ptr].wtag`) select among the entries.
    fn index_selects(&mut self, name: &str, w: f64) {
        let b = name.as_bytes();
        let mut i = 0usize;
        while i < b.len() {
            if b[i] == b'[' {
                let start = i + 1;
                let mut depth = 1i32;
                let mut j = start;
                while j < b.len() && depth > 0 {
                    match b[j] {
                        b'[' => depth += 1,
                        b']' => depth -= 1,
                        _ => {}
                    }
                    j += 1;
                }
                let end = if depth == 0 { j - 1 } else { j };
                if let Some(inner) = name.get(start..end) {
                    if !inner.contains(':') {
                        Expr::parse(inner).walk_idents(&mut |id| self.add(id, w * INDEX_SPREAD));
                    }
                }
                i = j;
                continue;
            }
            i += 1;
        }
    }

    /// Per-bit fanout of a writer of `key`: reads of the key or any whole
    /// containing it, plus the busiest field it contains.
    fn fanout_of(&self, key: &str) -> f64 {
        let mut whole = self.net.get(key).copied().unwrap_or(0.0);
        let mut field = 0.0_f64;
        for (k, n) in &self.net {
            if k.len() < key.len() && key.starts_with(k.as_str()) && key.as_bytes()[k.len()] == b'.'
            {
                whole += n;
            } else if k.len() > key.len() && k.starts_with(key) && k.as_bytes()[key.len()] == b'.' {
                field = field.max(*n);
            }
        }
        whole + field
    }
}

/// Loads of one module: extra latency per node, and launch arrivals.
#[derive(Debug, Default)]
pub struct ModuleLoads {
    /// Extra FO4 per node: its output fanout (last writer of a net in a
    /// region) and its own select broadcasts.
    pub extra: BTreeMap<NodeId, f64>,
    /// Arrival per node of the register outputs it reads: a flop's Q net
    /// carries its whole fanout before any consumer sees the value.
    pub launch: BTreeMap<NodeId, f64>,
}

/// Loads of a module. `skip` holds dead / locked nodes: they neither load
/// nor pay.
pub fn node_loads(
    module: &TimingModule,
    widths: &WidthResolver,
    model: &CostModel,
    skip: &BTreeSet<NodeId>,
) -> ModuleLoads {
    let mut out = ModuleLoads::default();
    if !load_enabled(model) {
        return out;
    }
    let width_of = |id: NodeId| -> f64 {
        let Some(n) = module.nodes.get(&id) else {
            return 1.0;
        };
        n.lhs_expr
            .as_ref()
            .and_then(|l| widths.expr_width(l))
            .map(f64::from)
            .or_else(|| (!n.width_defaulted).then_some(f64::from(n.width)))
            .unwrap_or(1.0)
            .max(1.0)
    };
    let mut counts = LoadCounts::default();
    let mut own_select: BTreeMap<NodeId, f64> = BTreeMap::new();
    let mut pred_width: BTreeMap<String, f64> = BTreeMap::new();
    let mut pred_seen: BTreeSet<String> = BTreeSet::new();
    let mut compound: BTreeMap<NodeId, Vec<String>> = BTreeMap::new();
    for (id, n) in &module.nodes {
        if skip.contains(id) {
            continue;
        }
        let w = width_of(*id);
        if let Some(ex) = &n.rhs_expr {
            let sel = counts.data(ex, w);
            if sel > 0.0 {
                own_select.insert(*id, sel);
            }
        }
        for g in module.guards.get(id).into_iter().flatten() {
            let text = g.strip_prefix('^').unwrap_or(g).trim().to_string();
            let gex = Expr::parse(&text);
            if gex.is_opaque() {
                continue;
            }
            if let Some(idn) = bare_select_ident(&gex) {
                counts.add(idn, w);
                continue;
            }
            *pred_width.entry(text.clone()).or_insert(0.0) += w;
            if pred_seen.insert(text.clone()) {
                counts.data(&gex, 1.0);
            }
            compound.entry(*id).or_default().push(text);
        }
    }
    // The final value of a net leaves its region at the region's last writer.
    let mut last_writer: BTreeMap<(u32, String), NodeId> = BTreeMap::new();
    for region in module.regions.values() {
        if !matches!(region.kind, RegionKind::AlwaysComb | RegionKind::ContAssign) {
            continue;
        }
        for id in &region.nodes {
            if skip.contains(id) {
                continue;
            }
            let Some(n) = module.nodes.get(id) else {
                continue;
            };
            if !n.assign_kind.is_comb_def() {
                continue;
            }
            if let Some(lhs) = n.lhs.as_deref() {
                let k = load_key(lhs);
                if !k.is_empty() {
                    last_writer.insert((region.id, k), *id);
                }
            }
        }
    }
    for ((_, key), id) in &last_writer {
        let extra = load_fo4(model, counts.fanout_of(key));
        if extra > 0.0 {
            *out.extra.entry(*id).or_insert(0.0) += extra;
        }
    }
    for (id, preds) in &compound {
        let worst = preds
            .iter()
            .map(|p| load_fo4(model, pred_width.get(p).copied().unwrap_or(0.0)))
            .fold(0.0, f64::max);
        if worst > 0.0 {
            *out.extra.entry(*id).or_insert(0.0) += worst;
        }
    }
    for (id, w) in &own_select {
        let extra = load_fo4(model, *w);
        if extra > 0.0 {
            *out.extra.entry(*id).or_insert(0.0) += extra;
        }
    }
    // Register outputs: the Q net of each flop (NBA LHS) carries its fanout
    // before any reader sees it. Input ports are ideal drivers on the board.
    let regs: BTreeSet<String> = module
        .nodes
        .values()
        .filter(|n| n.assign_kind.is_seq_def())
        .filter_map(|n| n.lhs.as_deref().map(load_key))
        .filter(|k| !k.is_empty())
        .collect();
    if regs.is_empty() {
        return out;
    }
    let q_arrival: BTreeMap<&str, f64> = regs
        .iter()
        .map(|k| (k.as_str(), load_fo4(model, counts.fanout_of(k))))
        .filter(|(_, a)| *a > 0.0)
        .collect();
    if q_arrival.is_empty() {
        return out;
    }
    let reg_of = |name: &str| -> f64 {
        let k = load_key(name);
        let mut best = 0.0_f64;
        for (r, a) in &q_arrival {
            if k == *r
                || (k.len() > r.len() && k.starts_with(r) && k.as_bytes()[r.len()] == b'.')
                || (r.len() > k.len() && r.starts_with(k.as_str()) && r.as_bytes()[k.len()] == b'.')
            {
                best = best.max(*a);
            }
        }
        best
    };
    for (id, n) in &module.nodes {
        if skip.contains(id) || n.assign_kind.is_seq_def() {
            continue;
        }
        let mut arrival = 0.0_f64;
        if let Some(ex) = &n.rhs_expr {
            ex.walk_idents(&mut |s| arrival = arrival.max(reg_of(s)));
        }
        for g in module.guards.get(id).into_iter().flatten() {
            Expr::parse(g.strip_prefix('^').unwrap_or(g))
                .walk_idents(&mut |s| arrival = arrival.max(reg_of(s)));
        }
        if arrival > 0.0 {
            out.launch.insert(*id, arrival);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn load_is_linear_to_the_cap_then_buffered() {
        let m = CostModel::default();
        assert_eq!(load_fo4(&m, 4.0), 0.0);
        let at_cap = load_fo4(&m, 64.0);
        assert!((at_cap - m.load_per_fanout * 60.0).abs() < 1e-9);
        assert!(load_fo4(&m, 32.0) < at_cap);
        // above the cap the board drops the driver; repaired: log4 stages
        assert!(load_fo4(&m, 256.0) <= 3.0 + 1e-9);
    }

    #[test]
    fn load_key_keeps_members_and_drops_indices() {
        assert_eq!(load_key("q[k].be"), "q.be");
        assert_eq!(load_key("byp_d.paddr[55:3]"), "byp_d.paddr");
        assert_eq!(load_key("x"), "x");
    }
}
