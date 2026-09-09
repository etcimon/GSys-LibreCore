// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Procedural reference-ordering tree: per-variable read/write counts, call
// counts with parameter-use counters, and write→read edges in statement order.

//! Procedural use-def tree for combinational / sequential regions.
//!
//! IR statement order is **not** silicon depth. This tree records, for each
//! variable and each function call, when it is written, read, or invoked, and
//! whether a later statement actually consumes an earlier write. Timing lanes
//! serialize only those forward edges; write-only next-state and port assigns
//! stay parallel.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::expr::{ConstSeed, Expr};
use crate::ir::{AssignKind, NodeId, TimingModule};

/// Strip bit/part selects so `rdata[31:0]` and `foo_d[i]` share one name.
pub fn ident_base(name: &str) -> String {
    name.split('[')
        .next()
        .unwrap_or(name)
        .trim()
        .to_string()
}

/// Per-variable reference counters in one procedural region.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct VarRefCount {
    /// Blocking / continuous writes.
    pub writes: u32,
    /// Reads on an RHS (including the same-statement `x = x - 1`).
    pub reads: u32,
    /// Reads that occur **after** some write of the same name (true comb dep).
    pub forward_reads: u32,
    /// Reads that occur **before** any write (input, loop, or latch risk).
    pub reads_before_write: u32,
}

impl VarRefCount {
    /// Written in this process and never consumed by a later statement.
    pub fn is_write_only(&self) -> bool {
        self.writes > 0 && self.forward_reads == 0
    }

    /// A later statement reads a value this process produced — comb chain.
    pub fn has_forward_comb_use(&self) -> bool {
        self.forward_reads > 0
    }
}

/// Per-call counters plus how often each parameter/ident appears in arguments.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct CallRefCount {
    /// Invocation count.
    pub calls: u32,
    /// Argument ident / localparam uses (`WIDTH`, `CVA6Cfg.Xlen`, …).
    pub param_uses: BTreeMap<String, u32>,
}

/// One procedural reference (statement order).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RefEvent {
    /// Statement index in the region (IR node order).
    pub stmt_ord: u32,
    /// IR node id.
    pub node_id: NodeId,
    /// Variable or call name (base ident).
    pub name: String,
    /// `write`, `read`, or `call`.
    pub role: RefRole,
}

/// Role of a [`RefEvent`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RefRole {
    /// LHS write.
    Write,
    /// RHS read of a variable.
    Read,
    /// Function / system-function / task call.
    Call,
}

/// Write→read edge in statement order (`var` produced at `from`, consumed at `to`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RefEdge {
    /// Producer statement.
    pub from_stmt: u32,
    /// Consumer statement.
    pub to_stmt: u32,
    /// Variable flowing along the edge.
    pub var: String,
}

/// Reference-ordering tree + counters for one path / region.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct RefOrderTree {
    /// Ordered events.
    pub events: Vec<RefEvent>,
    /// Per-variable counters.
    pub vars: BTreeMap<String, VarRefCount>,
    /// Per-call counters (name → count + param uses).
    pub calls: BTreeMap<String, CallRefCount>,
    /// Parameter / localparam uses anywhere on the path.
    pub params: BTreeMap<String, u32>,
    /// Forward write→read edges (procedural comb deps).
    pub edges: Vec<RefEdge>,
    /// False when a call reads a var that is only written **after** the call.
    pub procedural_ok: bool,
}

impl RefOrderTree {
    /// Build from IR nodes in **procedural (statement) order**.
    pub fn from_nodes(module: &TimingModule, nodes: &[NodeId]) -> Self {
        let param_names = param_name_set(module);
        let mut tree = Self {
            procedural_ok: true,
            ..Self::default()
        };
        let mut last_write: BTreeMap<String, u32> = BTreeMap::new();

        for (ord, nid) in nodes.iter().copied().enumerate() {
            let stmt_ord = ord as u32;
            let Some(n) = module.nodes.get(&nid) else {
                continue;
            };
            let lhs = n
                .lhs
                .as_deref()
                .map(ident_base)
                .filter(|s| !s.is_empty());

            let mut reads: Vec<String> = Vec::new();
            if let Some(ref ex) = n.rhs_expr {
                collect_expr(&mut tree, &param_names, stmt_ord, nid, ex, &mut reads);
            } else if let Some(ref rhs) = n.rhs {
                collect_expr(
                    &mut tree,
                    &param_names,
                    stmt_ord,
                    nid,
                    &Expr::parse(rhs),
                    &mut reads,
                );
            }

            for r in &reads {
                let e = tree.vars.entry(r.clone()).or_default();
                e.reads += 1;
                tree.events.push(RefEvent {
                    stmt_ord,
                    node_id: nid,
                    name: r.clone(),
                    role: RefRole::Read,
                });
                if let Some(&wstmt) = last_write.get(r) {
                    if wstmt < stmt_ord {
                        let writer = module.nodes.get(&nodes[wstmt as usize]);
                        // NBA updates after the timestep (IEEE 1800). A later
                        // statement reading that LHS sees Q, not a combo chain.
                        // Treating it as a forward edge poisoned always_ff
                        // IndependentLhsBundle (gemm 144-node 161.5 serial sum).
                        if writer.is_some_and(|w| w.assign_kind.is_seq_def()) {
                            continue;
                        }
                        e.forward_reads += 1;
                        if writer
                            .and_then(|w| w.gate.as_ref())
                            .is_some_and(|gate| !gate.is_comb)
                        {
                            tree.procedural_ok = false;
                        }
                        tree.edges.push(RefEdge {
                            from_stmt: wstmt,
                            to_stmt: stmt_ord,
                            var: r.clone(),
                        });
                    } else if wstmt == stmt_ord {
                        // Same-statement `x = x - 1`: not a cross-statement comb chain.
                    }
                } else {
                    e.reads_before_write += 1;
                }
            }

            if let Some(ref l) = lhs {
                let e = tree.vars.entry(l.clone()).or_default();
                e.writes += 1;
                tree.events.push(RefEvent {
                    stmt_ord,
                    node_id: nid,
                    name: l.clone(),
                    role: RefRole::Write,
                });
                last_write.insert(l.clone(), stmt_ord);
            }
        }

        tree.procedural_ok &= tree.assert_procedural_use();
        tree
    }

    /// Call arguments must not depend only on writes that happen **after** the call.
    fn assert_procedural_use(&self) -> bool {
        let mut first_write: BTreeMap<&str, u32> = BTreeMap::new();
        for ev in &self.events {
            if ev.role == RefRole::Write {
                first_write.entry(ev.name.as_str()).or_insert(ev.stmt_ord);
            }
        }
        for ev in &self.events {
            if ev.role != RefRole::Call {
                continue;
            }
            let Some(cc) = self.calls.get(&ev.name) else {
                continue;
            };
            for (pname, _) in &cc.param_uses {
                if let Some(&w) = first_write.get(pname.as_str()) {
                    if w > ev.stmt_ord {
                        return false;
                    }
                }
            }
        }
        true
    }

    /// Write-only (no forward comb consumer) — flop-bound `_d` or comb output.
    pub fn is_write_only(&self, var: &str) -> bool {
        self.vars
            .get(var)
            .map(VarRefCount::is_write_only)
            .unwrap_or(false)
    }

    /// Longest write→read chain (number of edges). 0 = fully parallel assigns.
    pub fn procedural_depth(&self) -> u32 {
        if self.edges.is_empty() {
            return 0;
        }
        let mut dist: BTreeMap<u32, u32> = BTreeMap::new();
        for e in &self.edges {
            let src = *dist.get(&e.from_stmt).unwrap_or(&0);
            let dst = dist.entry(e.to_stmt).or_insert(0);
            *dst = (*dst).max(src + 1);
        }
        dist.values().copied().max().unwrap_or(0)
    }

    /// Count of write-only variables among `lhs` keys.
    pub fn write_only_lhs(&self, lhs: impl Iterator<Item = impl AsRef<str>>) -> usize {
        lhs.filter(|k| self.is_write_only(k.as_ref())).count()
    }
}

/// First-pass module auto-const from the reference tree.
///
/// For each **expression-less** combo/continuous assign (`x = 4`, `x = WIDTH`,
/// `x = y` of a const) whose LHS is a **single exclusive writer** and is
/// **read** (not a write-only next-state `_d`), add the LHS to [`ConstSeed`].
/// Copy-propagates through ident aliases to a fixpoint. NBA / indexed LHS /
/// multi-writer nets stay runtime.
pub fn extend_seed_auto_const(module: &TimingModule, seed: &mut ConstSeed) {
    let ids: Vec<NodeId> = module.nodes.keys().copied().collect();
    if ids.is_empty() {
        return;
    }
    let tree = RefOrderTree::from_nodes(module, &ids);
    let mut exclusive_assigns: Vec<(String, Expr)> = Vec::new();
    for n in module.nodes.values() {
        if !matches!(
            n.assign_kind,
            AssignKind::Blocking | AssignKind::Continuous | AssignKind::Unknown
        ) {
            continue;
        }
        let Some(lhs_raw) = n.lhs.as_deref() else {
            continue;
        };
        if lhs_raw.contains('[') {
            continue;
        }
        let lhs = ident_base(lhs_raw);
        if lhs.is_empty() {
            continue;
        }
        let Some(vc) = tree.vars.get(&lhs) else {
            continue;
        };
        // Exclusive writer, and the value is actually read (not write-only `_d`).
        if vc.writes != 1 || vc.reads == 0 {
            continue;
        }
        let rhs = n
            .rhs_expr
            .clone()
            .or_else(|| n.rhs.as_deref().map(Expr::parse));
        let Some(rhs) = rhs else {
            continue;
        };
        if !rhs.is_expression_less() {
            continue;
        }
        exclusive_assigns.push((lhs, rhs));
    }
    if !exclusive_assigns.is_empty() {
        for _ in 0..32 {
            let mut added = false;
            for (lhs, rhs) in &exclusive_assigns {
                if seed.looks_const(lhs) {
                    continue;
                }
                let const_rhs = match rhs {
                    Expr::Literal { .. } => true,
                    Expr::Ident { name } => seed.looks_const(name),
                    _ => false,
                };
                if const_rhs {
                    seed.add(lhs.clone());
                    added = true;
                }
            }
            if !added {
                break;
            }
        }
    }
    extend_seed_aligned(module, &tree, seed);
}

/// First-pass aligned nets: exclusive combo `{x[MSB:K], {K{0}}}` (and ident
/// aliases of those nets). `ident + (y << K)` then bills as a field insert.
/// Exclusive `t = y << K` temps (BalanceMux shift staging) make
/// `aligned + t` a field insert with matching `K`.
fn extend_seed_aligned(
    module: &TimingModule,
    tree: &RefOrderTree,
    seed: &mut ConstSeed,
) {
    let mut exclusive: Vec<(String, Expr)> = Vec::new();
    for n in module.nodes.values() {
        if !matches!(
            n.assign_kind,
            AssignKind::Blocking | AssignKind::Continuous | AssignKind::Unknown
        ) {
            continue;
        }
        let Some(lhs_raw) = n.lhs.as_deref() else {
            continue;
        };
        if lhs_raw.contains('[') {
            continue;
        }
        let lhs = ident_base(lhs_raw);
        if lhs.is_empty() {
            continue;
        }
        let Some(vc) = tree.vars.get(&lhs) else {
            continue;
        };
        if vc.writes != 1 || vc.reads == 0 {
            continue;
        }
        let rhs = n
            .rhs_expr
            .clone()
            .or_else(|| n.rhs.as_deref().map(Expr::parse));
        let Some(rhs) = rhs else {
            continue;
        };
        exclusive.push((lhs, rhs));
    }
    for _ in 0..32 {
        let mut added = false;
        for (lhs, rhs) in &exclusive {
            if seed.aligned_k(lhs).is_none() {
                if let Some(k) = rhs.zero_pad_align_key() {
                    seed.set_aligned(lhs.clone(), k);
                    added = true;
                } else if let Expr::Ident { name } = rhs {
                    if let Some(k) = seed.aligned_k(name).map(str::to_string) {
                        seed.set_aligned(lhs.clone(), k);
                        added = true;
                    }
                }
            }
            if seed.shifted_k(lhs).is_none() {
                if let Some(k) = rhs.shift_align_key() {
                    seed.set_shifted(lhs.clone(), k);
                    added = true;
                } else if let Expr::Ident { name } = rhs {
                    if let Some(k) = seed.shifted_k(name).map(str::to_string) {
                        seed.set_shifted(lhs.clone(), k);
                        added = true;
                    }
                }
            }
        }
        if !added {
            break;
        }
    }
}

fn param_name_set(module: &TimingModule) -> BTreeMap<String, ()> {
    let mut s = BTreeMap::new();
    for p in &module.localparams {
        s.insert(ident_base(p), ());
        let leaf = p.rsplit('.').next().unwrap_or(p);
        s.insert(leaf.to_string(), ());
    }
    for p in &module.parameters {
        s.insert(ident_base(&p.name), ());
    }
    s
}

fn is_param_ident(name: &str, params: &BTreeMap<String, ()>) -> bool {
    if params.contains_key(name) {
        return true;
    }
    let leaf = name.rsplit('.').next().unwrap_or(name);
    if params.contains_key(leaf) {
        return true;
    }
    let n = leaf.to_ascii_lowercase();
    n.contains("cfg")
        || n.contains("width")
        || n.contains("bits")
        || n.contains("len")
        || n.starts_with("cva6")
        || (leaf
            .chars()
            .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == '_')
            && leaf.chars().any(|c| c.is_ascii_uppercase()))
}

fn collect_expr(
    tree: &mut RefOrderTree,
    params: &BTreeMap<String, ()>,
    stmt_ord: u32,
    nid: NodeId,
    ex: &Expr,
    reads: &mut Vec<String>,
) {
    ex.walk_calls(&mut |cname, args| {
        let cc = tree.calls.entry(cname.to_string()).or_default();
        cc.calls += 1;
        tree.events.push(RefEvent {
            stmt_ord,
            node_id: nid,
            name: cname.to_string(),
            role: RefRole::Call,
        });
        for a in args {
            a.walk_idents(&mut |id| {
                let base = ident_base(id);
                if is_param_ident(&base, params) {
                    *cc.param_uses.entry(base.clone()).or_insert(0) += 1;
                    *tree.params.entry(base).or_insert(0) += 1;
                }
            });
        }
    });
    ex.walk_idents(&mut |id| {
        let base = ident_base(id);
        if is_param_ident(&base, params) {
            *tree.params.entry(base.clone()).or_insert(0) += 1;
        }
        if !reads.contains(&base) {
            reads.push(base);
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ir::{IrNode, OperatorClass, TimingModule};
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

    fn node(
        id: u32,
        lhs: &str,
        rhs: &str,
        op: OperatorClass,
        fo4: f64,
    ) -> IrNode {
        IrNode {
            id,
            op_class: Some(op),
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

    #[test]
    fn write_only_next_state_has_no_forward_edge() {
        let mut nodes = Map::new();
        nodes.insert(0, node(0, "state_d", "IDLE", OperatorClass::Other, 1.0));
        nodes.insert(1, node(1, "cnt_d", "cnt_q - 1", OperatorClass::AddSub, 10.0));
        let m = TimingModule {
            id: 0,
            name: "axi_adapter".into(),
            file: "a.sv".into(),
            nodes,
            regions: Map::new(),
            localparams: vec![],
            parameters: vec![],
            ports: vec![],
            gen_loops: vec![],
            functions: vec![],
            package_imports: vec![],
            instances: vec![],
            loc: loc(),
        };
        let t = RefOrderTree::from_nodes(&m, &[0, 1]);
        assert!(t.is_write_only("state_d"));
        assert!(t.vars.get("cnt_d").unwrap().writes == 1);
        assert_eq!(t.procedural_depth(), 0);
        assert!(t.procedural_ok);
    }

    #[test]
    fn forward_read_builds_ordering_edge() {
        let mut nodes = Map::new();
        nodes.insert(0, node(0, "tmp", "a + b", OperatorClass::AddSub, 10.0));
        nodes.insert(1, node(1, "y", "tmp + c", OperatorClass::AddSub, 10.0));
        let m = TimingModule {
            id: 0,
            name: "comb".into(),
            file: "c.sv".into(),
            nodes,
            regions: Map::new(),
            localparams: vec![],
            parameters: vec![],
            ports: vec![],
            gen_loops: vec![],
            functions: vec![],
            package_imports: vec![],
            instances: vec![],
            loc: loc(),
        };
        let t = RefOrderTree::from_nodes(&m, &[0, 1]);
        assert!(t.vars.get("tmp").unwrap().has_forward_comb_use());
        assert_eq!(t.edges.len(), 1);
        assert_eq!(t.edges[0].var, "tmp");
        assert_eq!(t.procedural_depth(), 1);
        assert!(!t.is_write_only("tmp"));
        assert!(t.procedural_ok);

        let mut sequential = m.clone();
        sequential.nodes.get_mut(&0).unwrap().gate = Some(crate::ir::GateInfo {
            is_comb: false,
            ..crate::ir::GateInfo::default()
        });
        let uncertain = RefOrderTree::from_nodes(&sequential, &[0, 1]);
        assert_eq!(uncertain.edges, t.edges);
        assert_eq!(uncertain.procedural_depth(), 1);
        assert!(!uncertain.procedural_ok);

        sequential.nodes.get_mut(&0).unwrap().gate.as_mut().unwrap().is_comb = true;
        assert!(RefOrderTree::from_nodes(&sequential, &[0, 1]).procedural_ok);
    }

    #[test]
    fn nba_write_is_not_forward_comb_edge() {
        // always_ff: `a_q <= b_i; c_q <= a_q + 1;` — second NBA reads Q, not combo.
        let mut nodes = Map::new();
        let mut a = node(0, "a_q", "b_i", OperatorClass::Other, 1.0);
        a.assign_kind = crate::ir::AssignKind::Nonblocking;
        a.gate = Some(crate::ir::GateInfo {
            is_comb: false,
            ..crate::ir::GateInfo::default()
        });
        let mut c = node(1, "c_q", "a_q + 1", OperatorClass::AddSub, 10.0);
        c.assign_kind = crate::ir::AssignKind::Nonblocking;
        c.gate = Some(crate::ir::GateInfo {
            is_comb: false,
            ..crate::ir::GateInfo::default()
        });
        nodes.insert(0, a);
        nodes.insert(1, c);
        let m = TimingModule {
            id: 0,
            name: "seq".into(),
            file: "s.sv".into(),
            nodes,
            regions: Map::new(),
            localparams: vec![],
            parameters: vec![],
            ports: vec![],
            gen_loops: vec![],
            functions: vec![],
            package_imports: vec![],
            instances: vec![],
            loc: loc(),
        };
        let t = RefOrderTree::from_nodes(&m, &[0, 1]);
        assert!(
            t.edges.is_empty(),
            "NBA→NBA must not be a combo edge: {:?}",
            t.edges
        );
        assert!(t.procedural_ok);
        assert_eq!(t.procedural_depth(), 0);
    }

    #[test]
    fn call_count_tracks_parameter_uses() {
        let mut nodes = Map::new();
        nodes.insert(
            0,
            node(
                0,
                "y",
                "$clog2(WIDTH) + foo(XLEN)",
                OperatorClass::Other,
                2.0,
            ),
        );
        let m = TimingModule {
            id: 0,
            name: "u".into(),
            file: "u.sv".into(),
            nodes,
            regions: Map::new(),
            localparams: vec!["WIDTH".into(), "XLEN".into()],
            parameters: vec![],
            ports: vec![],
            gen_loops: vec![],
            functions: vec![],
            package_imports: vec![],
            instances: vec![],
            loc: loc(),
        };
        let t = RefOrderTree::from_nodes(&m, &[0]);
        assert!(
            t.calls.values().any(|c| c.calls >= 1),
            "calls={:?}",
            t.calls
        );
        assert!(
            t.params.contains_key("WIDTH") || t.calls.values().any(|c| c.param_uses.contains_key("WIDTH")),
            "params={:?} calls={:?}",
            t.params,
            t.calls
        );
        assert!(t.procedural_ok);
    }

    #[test]
    fn auto_const_expression_less_exclusive_read() {
        let mut nodes = Map::new();
        let mut k = node(0, "k", "4", OperatorClass::Other, 0.0);
        k.assign_kind = crate::ir::AssignKind::Continuous;
        let mut alias = node(1, "k_alias", "k", OperatorClass::Other, 0.0);
        alias.assign_kind = crate::ir::AssignKind::Continuous;
        let mut y = node(2, "y", "a + k_alias", OperatorClass::AddSub, 10.0);
        y.assign_kind = crate::ir::AssignKind::Continuous;
        nodes.insert(0, k);
        nodes.insert(1, alias);
        nodes.insert(2, y);
        let m = TimingModule {
            id: 0,
            name: "m".into(),
            file: "m.sv".into(),
            nodes,
            regions: Map::new(),
            localparams: vec![],
            parameters: vec![],
            ports: vec![],
            gen_loops: vec![],
            functions: vec![],
            package_imports: vec![],
            instances: vec![],
            loc: loc(),
        };
        let mut seed = crate::expr::ConstSeed::heuristic();
        super::extend_seed_auto_const(&m, &mut seed);
        assert!(seed.looks_const("k"), "literal assign must seed k");
        assert!(
            seed.looks_const("k_alias"),
            "ident alias of const must seed k_alias"
        );
        assert!(
            !seed.looks_const("y"),
            "a+k is not expression-less"
        );
        assert!(
            !seed.looks_const("a"),
            "undriven ident must stay runtime"
        );
        assert_eq!(
            crate::expr::Expr::parse("a + k_alias").dominant_op_class_latticed(&seed),
            crate::ir::OperatorClass::LogicBit,
            "const-offset add after auto-const"
        );
    }

    #[test]
    fn auto_const_skips_nba_and_write_only_and_multi_writer() {
        let mut nodes = Map::new();
        let mut q = node(0, "q", "4", OperatorClass::Other, 0.0);
        q.assign_kind = crate::ir::AssignKind::Nonblocking;
        let mut d = node(1, "state_d", "IDLE", OperatorClass::Other, 0.0);
        d.assign_kind = crate::ir::AssignKind::Blocking;
        // write-only: state_d never read
        let mut w1 = node(2, "shared", "1", OperatorClass::Other, 0.0);
        w1.assign_kind = crate::ir::AssignKind::Continuous;
        let mut w2 = node(3, "shared", "0", OperatorClass::Other, 0.0);
        w2.assign_kind = crate::ir::AssignKind::Continuous;
        let mut use_q = node(4, "y", "q + shared", OperatorClass::AddSub, 10.0);
        use_q.assign_kind = crate::ir::AssignKind::Continuous;
        nodes.insert(0, q);
        nodes.insert(1, d);
        nodes.insert(2, w1);
        nodes.insert(3, w2);
        nodes.insert(4, use_q);
        let m = TimingModule {
            id: 0,
            name: "m".into(),
            file: "m.sv".into(),
            nodes,
            regions: Map::new(),
            localparams: vec![],
            parameters: vec![],
            ports: vec![],
            gen_loops: vec![],
            functions: vec![],
            package_imports: vec![],
            instances: vec![],
            loc: loc(),
        };
        let mut seed = crate::expr::ConstSeed::heuristic();
        super::extend_seed_auto_const(&m, &mut seed);
        assert!(!seed.looks_const("q"), "NBA must not auto-const");
        assert!(
            !seed.looks_const("state_d"),
            "write-only next-state must not auto-const"
        );
        assert!(
            !seed.looks_const("shared"),
            "multi-writer must not auto-const"
        );
    }

    #[test]
    fn auto_const_aligned_zero_pad_names_field_insert() {
        let mut nodes = Map::new();
        let mut al = node(
            0,
            "aligned_address",
            "{addr[31:3], {3{1'b0}}}",
            OperatorClass::Concat,
            1.0,
        );
        al.assign_kind = crate::ir::AssignKind::Blocking;
        let mut cons = node(
            1,
            "cons_addr",
            "aligned_address + (cnt << 3)",
            OperatorClass::AddSub,
            10.0,
        );
        cons.assign_kind = crate::ir::AssignKind::Blocking;
        nodes.insert(0, al);
        nodes.insert(1, cons);
        let m = TimingModule {
            id: 0,
            name: "axi2mem".into(),
            file: "a.sv".into(),
            nodes,
            regions: Map::new(),
            localparams: vec![],
            parameters: vec![],
            ports: vec![],
            gen_loops: vec![],
            functions: vec![],
            package_imports: vec![],
            instances: vec![],
            loc: loc(),
        };
        let mut seed = crate::expr::ConstSeed::heuristic();
        super::extend_seed_auto_const(&m, &mut seed);
        assert_eq!(seed.aligned_k("aligned_address"), Some("3"));
        assert_ne!(
            crate::expr::Expr::parse("aligned_address + (cnt << 3)")
                .dominant_op_class_latticed(&seed),
            crate::ir::OperatorClass::AddSub,
            "named aligned + (y<<K) must not be CPA"
        );
        assert_eq!(
            crate::expr::Expr::parse("wrap_boundary + (cnt << 3)")
                .dominant_op_class_latticed(&seed),
            crate::ir::OperatorClass::AddSub,
            "unproven wrap ident must stay CPA"
        );
    }

    #[test]
    fn auto_const_aligned_double_brace_ident_pad() {
        let mut nodes = Map::new();
        let mut al = node(
            0,
            "aligned_address",
            "{ax_req_q.addr[AXI_ADDR_WIDTH-1:LOG_NR_BYTES], {{LOG_NR_BYTES}{1'b0}}}",
            OperatorClass::Concat,
            1.0,
        );
        al.assign_kind = crate::ir::AssignKind::Blocking;
        let mut cons = node(
            1,
            "cons_addr",
            "aligned_address + (cnt_q << LOG_NR_BYTES)",
            OperatorClass::AddSub,
            10.0,
        );
        cons.assign_kind = crate::ir::AssignKind::Blocking;
        nodes.insert(0, al);
        nodes.insert(1, cons);
        let m = TimingModule {
            id: 0,
            name: "axi2mem".into(),
            file: "a.sv".into(),
            nodes,
            regions: Map::new(),
            localparams: vec![],
            parameters: vec![],
            ports: vec![],
            gen_loops: vec![],
            functions: vec![],
            package_imports: vec![],
            instances: vec![],
            loc: loc(),
        };
        let mut seed = crate::expr::ConstSeed::heuristic();
        super::extend_seed_auto_const(&m, &mut seed);
        assert_eq!(
            seed.aligned_k("aligned_address"),
            Some("LOG_NR_BYTES"),
            "double-brace ident pad must seed K"
        );
        assert_ne!(
            crate::expr::Expr::parse("aligned_address + (cnt_q << LOG_NR_BYTES)")
                .dominant_op_class_latticed(&seed),
            crate::ir::OperatorClass::AddSub,
            "named aligned + (y<<LOG) must not be CPA"
        );
        assert_eq!(
            crate::expr::Expr::parse(
                "wrap_boundary + ((ax_req_q.len + 1) << LOG_NR_BYTES)"
            )
            .dominant_op_class_latticed(&seed),
            crate::ir::OperatorClass::AddSub,
            "wrap ident from a call must stay CPA"
        );
    }

    #[test]
    fn auto_const_aligned_plus_staged_shift_temp() {
        let mut nodes = Map::new();
        let mut al = node(
            0,
            "aligned_address",
            "{addr[31:3], {3{1'b0}}}",
            OperatorClass::Concat,
            1.0,
        );
        al.assign_kind = crate::ir::AssignKind::Blocking;
        let mut sh = node(
            1,
            "svt_bm_shift",
            "cnt_q << 3",
            OperatorClass::ShiftConst,
            2.0,
        );
        sh.assign_kind = crate::ir::AssignKind::Blocking;
        let mut cons = node(
            2,
            "cons_addr",
            "aligned_address + svt_bm_shift",
            OperatorClass::AddSub,
            10.0,
        );
        cons.assign_kind = crate::ir::AssignKind::Blocking;
        nodes.insert(0, al);
        nodes.insert(1, sh);
        nodes.insert(2, cons);
        let m = TimingModule {
            id: 0,
            name: "axi2mem".into(),
            file: "a.sv".into(),
            nodes,
            regions: Map::new(),
            localparams: vec![],
            parameters: vec![],
            ports: vec![],
            gen_loops: vec![],
            functions: vec![],
            package_imports: vec![],
            instances: vec![],
            loc: loc(),
        };
        let mut seed = crate::expr::ConstSeed::heuristic();
        super::extend_seed_auto_const(&m, &mut seed);
        assert_eq!(seed.aligned_k("aligned_address"), Some("3"));
        assert_eq!(seed.shifted_k("svt_bm_shift"), Some("3"));
        assert_ne!(
            crate::expr::Expr::parse("aligned_address + svt_bm_shift")
                .dominant_op_class_latticed(&seed),
            crate::ir::OperatorClass::AddSub,
            "BM-staged aligned + t must not be CPA"
        );
        assert_eq!(
            crate::expr::Expr::parse("wrap_boundary + svt_bm_shift")
                .dominant_op_class_latticed(&seed),
            crate::ir::OperatorClass::AddSub,
            "BM-staged wrap + t must stay CPA"
        );
    }
}
