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
    name.split('[').next().unwrap_or(name).trim().to_string()
}

/// Field-granular dependency key (delay-v43): bracket contents become `*`,
/// members stay. `q[k].be` → `q[*].be`; `byp_d.paddr[55:3]` → `byp_d.paddr[*]`.
pub fn dep_key(name: &str) -> String {
    let mut out = String::with_capacity(name.len());
    let mut depth = 0u32;
    for c in name.trim().chars() {
        match c {
            '[' => {
                if depth == 0 {
                    out.push_str("[*");
                }
                depth += 1;
            }
            ']' => {
                depth = depth.saturating_sub(1);
                if depth == 0 {
                    out.push(']');
                }
            }
            c if depth == 0 && !c.is_whitespace() => out.push(c),
            _ => {}
        }
    }
    out
}

fn split_scope(key: &str) -> (&str, &str) {
    key.split_once('@').unwrap_or((key, ""))
}

/// Root identifier of a dependency key, keeping its lexical scope suffix.
pub(crate) fn dep_root(key: &str) -> Option<String> {
    let (name, scope) = split_scope(key);
    let root = name.split(['.', '[']).next().unwrap_or(name).trim();
    if root.is_empty() {
        return None;
    }
    Some(if scope.is_empty() {
        root.to_string()
    } else {
        format!("{root}@{scope}")
    })
}

fn prefix_at_boundary(short: &str, long: &str) -> bool {
    long.len() > short.len()
        && long.starts_with(short)
        && matches!(long.as_bytes()[short.len()], b'.' | b'[')
}

/// Same storage: equal keys, or one is a whole containing the other field.
pub(crate) fn dep_related(a: &str, b: &str) -> bool {
    let (an, asc) = split_scope(a);
    let (bn, bsc) = split_scope(b);
    asc == bsc && (an == bn || prefix_at_boundary(an, bn) || prefix_at_boundary(bn, an))
}

/// The write defines everything the read observes: same or containing key
/// with no element index (an indexed write defines one element only).
fn dep_covers(writer: &str, read: &str) -> bool {
    let (wn, wsc) = split_scope(writer);
    let (rn, rsc) = split_scope(read);
    wsc == rsc && !wn.contains("[*]") && (wn == rn || prefix_at_boundary(wn, rn))
}

/// Field-granular read keys of an expression, including identifiers inside
/// the brackets of a flattened `a[i].f` member path (`wbuffer_q[ptr].wtag`
/// reads `ptr`).
fn collect_dep_reads(ex: &Expr, out: &mut Vec<String>) {
    ex.walk_idents(&mut |id| push_dep_read(id, out));
}

fn push_dep_read(id: &str, out: &mut Vec<String>) {
    let k = dep_key(id);
    if !k.is_empty() && !out.contains(&k) {
        out.push(k);
    }
    let b = id.as_bytes();
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
            if let Some(inner) = id.get(start..end) {
                Expr::parse(inner).walk_idents(&mut |s| push_dep_read(s, out));
            }
            i = j;
            continue;
        }
        i += 1;
    }
}

/// Lexical keys for def-use analysis. Source spelling is retained on IR nodes;
/// these keys never enter emitted SystemVerilog. Build once per graph traversal.
pub(crate) struct BindingIndex<'a> {
    scopes: BTreeMap<&'a str, Vec<&'a crate::SourceLoc>>,
}

impl<'a> BindingIndex<'a> {
    pub(crate) fn new(module: &'a TimingModule) -> Self {
        let mut scopes: BTreeMap<&str, Vec<&crate::SourceLoc>> = BTreeMap::new();
        for decl in &module.decls {
            if let Some(scope) = &decl.scope {
                if scope.origin == crate::OriginKind::UserFile {
                    scopes.entry(&decl.name).or_default().push(scope);
                }
            }
        }
        for loop_info in &module.gen_loops {
            if loop_info.loc.origin == crate::OriginKind::UserFile
                && loop_info.loc.byte_end > loop_info.loc.byte_start
            {
                scopes
                    .entry(&loop_info.genvar)
                    .or_default()
                    .push(&loop_info.loc);
            }
        }
        for spans in scopes.values_mut() {
            spans.sort_by_key(|s| s.byte_end - s.byte_start);
            spans.dedup();
        }
        Self { scopes }
    }

    pub(crate) fn key(&self, name: &str, loc: &crate::SourceLoc) -> String {
        if loc.origin == crate::OriginKind::UserFile {
            if let Some(root) = TimingModule::root_ident(name) {
                if let Some(spans) = self.scopes.get(root) {
                    if let Some(scope) = spans.iter().find(|s| {
                        s.file == loc.file
                            && s.byte_start <= loc.byte_start
                            && loc.byte_start < s.byte_end
                    }) {
                        return format!("{name}@{}:{}", scope.byte_start, scope.byte_end);
                    }
                }
            }
        }
        name.to_string()
    }
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
        let bindings = BindingIndex::new(module);
        let mut tree = Self {
            procedural_ok: true,
            ..Self::default()
        };
        // delay-v43: writes indexed by root identifier, each with its
        // field-granular dependency key (`q[*].be`) and base name. A read
        // depends on the most recent writes of a related key (equal, a
        // containing whole, or a contained field) that are not in an
        // exclusive arm, back to the first one that encloses the read and
        // covers it entirely (priority-mux semantics: an enclosed partial or
        // conditional write still lets older values through).
        let mut writes: BTreeMap<String, Vec<(String, u32, String)>> = BTreeMap::new();
        let mut seen_edges: std::collections::BTreeSet<(u32, u32)> = Default::default();

        for (ord, nid) in nodes.iter().copied().enumerate() {
            let stmt_ord = ord as u32;
            let Some(n) = module.nodes.get(&nid) else {
                continue;
            };
            let lhs = n
                .lhs
                .as_deref()
                .map(ident_base)
                .filter(|s| !s.is_empty())
                .map(|s| bindings.key(&s, &n.loc));
            let lhs_dep = n
                .lhs
                .as_deref()
                .map(|s| s.trim())
                .filter(|s| !s.is_empty())
                .map(|s| bindings.key(&dep_key(s), &n.loc));

            let mut reads: Vec<String> = Vec::new();
            let mut dep_reads: Vec<String> = Vec::new();
            let rhs_parsed;
            let rhs_ex = match (&n.rhs_expr, &n.rhs) {
                (Some(ex), _) => Some(ex),
                (None, Some(rhs)) => {
                    rhs_parsed = Expr::parse(rhs);
                    Some(&rhs_parsed)
                }
                _ => None,
            };
            if let Some(ex) = rhs_ex {
                collect_expr(&mut tree, &param_names, stmt_ord, nid, ex, &mut reads);
                collect_dep_reads(ex, &mut dep_reads);
            }
            // Guards (if predicates, dynamic LHS indices) are reads of the
            // node: the select of `if (g) x = a` waits for `g`.
            if let Some(gs) = module.guards.get(&nid) {
                for g in gs {
                    let gex = Expr::parse(g.strip_prefix('^').unwrap_or(g));
                    gex.walk_idents(&mut |id| {
                        let base = ident_base(id);
                        if !base.is_empty() && !reads.contains(&base) {
                            reads.push(base);
                        }
                    });
                    collect_dep_reads(&gex, &mut dep_reads);
                }
            }

            for r in &mut reads {
                *r = bindings.key(r, &n.loc);
            }
            for r in &mut dep_reads {
                *r = bindings.key(r, &n.loc);
            }
            let mut forwarded_roots: std::collections::BTreeSet<String> = Default::default();
            let mut consumed_bases: std::collections::BTreeSet<String> = Default::default();
            for r in &dep_reads {
                let Some(root) = dep_root(r) else {
                    continue;
                };
                let Some(ws) = writes.get(&root) else {
                    continue;
                };
                let mut taken = 0usize;
                for (wkey, wstmt, wbase) in ws.iter().rev() {
                    if *wstmt >= stmt_ord || !dep_related(wkey, r) {
                        continue;
                    }
                    let wnid = nodes[*wstmt as usize];
                    if module.nodes_exclusive(wnid, nid) {
                        continue;
                    }
                    let writer = module.nodes.get(&wnid);
                    // NBA updates after the timestep (IEEE 1800). A later
                    // statement reading that LHS sees Q, not a combo chain.
                    // Treating it as a forward edge poisoned always_ff
                    // IndependentLhsBundle (gemm 144-node 161.5 serial sum).
                    if writer.is_some_and(|w| w.assign_kind.is_seq_def()) {
                        break;
                    }
                    if writer
                        .and_then(|w| w.gate.as_ref())
                        .is_some_and(|gate| !gate.is_comb)
                    {
                        tree.procedural_ok = false;
                    }
                    if seen_edges.insert((*wstmt, stmt_ord)) {
                        tree.edges.push(RefEdge {
                            from_stmt: *wstmt,
                            to_stmt: stmt_ord,
                            var: r.clone(),
                        });
                    }
                    forwarded_roots.insert(root.clone());
                    consumed_bases.insert(wbase.clone());
                    taken += 1;
                    if (module.arms_enclose(wnid, nid) && dep_covers(wkey, r)) || taken >= 8 {
                        break;
                    }
                }
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
                let root = dep_root(r).unwrap_or_else(|| r.clone());
                if forwarded_roots.contains(&root) {
                    consumed_bases.insert(r.clone());
                } else if !writes.contains_key(&root) {
                    e.reads_before_write += 1;
                }
            }
            for b in consumed_bases {
                tree.vars.entry(b).or_default().forward_reads += 1;
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
                if let Some(dk) = lhs_dep {
                    if let Some(root) = dep_root(&dk) {
                        writes
                            .entry(root)
                            .or_default()
                            .push((dk, stmt_ord, l.clone()));
                    }
                }
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
fn extend_seed_aligned(module: &TimingModule, tree: &RefOrderTree, seed: &mut ConstSeed) {
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

    fn node(id: u32, lhs: &str, rhs: &str, op: OperatorClass, fo4: f64) -> IrNode {
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
        nodes.insert(
            1,
            node(1, "cnt_d", "cnt_q - 1", OperatorClass::AddSub, 10.0),
        );
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
            function_bodies: Vec::new(),
            package_imports: vec![],
            instances: vec![],
            decls: Vec::new(),
            const_exprs: Default::default(),
            typedef_texts: Default::default(),
            config_branch: false,
            guards: Default::default(),
            onehot_facts: Default::default(),
            guard_sites: Default::default(),
            decl_texts: Default::default(),
            pipe_pragmas: Default::default(),
            stage_decls: Default::default(),
            branch_arms: Default::default(),
            launch_fo4: Default::default(),
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
            function_bodies: Vec::new(),
            package_imports: vec![],
            instances: vec![],
            decls: Vec::new(),
            const_exprs: Default::default(),
            typedef_texts: Default::default(),
            config_branch: false,
            guards: Default::default(),
            onehot_facts: Default::default(),
            guard_sites: Default::default(),
            decl_texts: Default::default(),
            pipe_pragmas: Default::default(),
            stage_decls: Default::default(),
            branch_arms: Default::default(),
            launch_fo4: Default::default(),
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

        sequential
            .nodes
            .get_mut(&0)
            .unwrap()
            .gate
            .as_mut()
            .unwrap()
            .is_comb = true;
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
            function_bodies: Vec::new(),
            package_imports: vec![],
            instances: vec![],
            decls: Vec::new(),
            const_exprs: Default::default(),
            typedef_texts: Default::default(),
            config_branch: false,
            guards: Default::default(),
            onehot_facts: Default::default(),
            guard_sites: Default::default(),
            decl_texts: Default::default(),
            pipe_pragmas: Default::default(),
            stage_decls: Default::default(),
            branch_arms: Default::default(),
            launch_fo4: Default::default(),
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
            function_bodies: Vec::new(),
            package_imports: vec![],
            instances: vec![],
            decls: Vec::new(),
            const_exprs: Default::default(),
            typedef_texts: Default::default(),
            config_branch: false,
            guards: Default::default(),
            onehot_facts: Default::default(),
            guard_sites: Default::default(),
            decl_texts: Default::default(),
            pipe_pragmas: Default::default(),
            stage_decls: Default::default(),
            branch_arms: Default::default(),
            launch_fo4: Default::default(),
            loc: loc(),
        };
        let t = RefOrderTree::from_nodes(&m, &[0]);
        assert!(
            t.calls.values().any(|c| c.calls >= 1),
            "calls={:?}",
            t.calls
        );
        assert!(
            t.params.contains_key("WIDTH")
                || t.calls.values().any(|c| c.param_uses.contains_key("WIDTH")),
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
            function_bodies: Vec::new(),
            package_imports: vec![],
            instances: vec![],
            decls: Vec::new(),
            const_exprs: Default::default(),
            typedef_texts: Default::default(),
            config_branch: false,
            guards: Default::default(),
            onehot_facts: Default::default(),
            guard_sites: Default::default(),
            decl_texts: Default::default(),
            pipe_pragmas: Default::default(),
            stage_decls: Default::default(),
            branch_arms: Default::default(),
            launch_fo4: Default::default(),
            loc: loc(),
        };
        let mut seed = crate::expr::ConstSeed::heuristic();
        super::extend_seed_auto_const(&m, &mut seed);
        assert!(seed.looks_const("k"), "literal assign must seed k");
        assert!(
            seed.looks_const("k_alias"),
            "ident alias of const must seed k_alias"
        );
        assert!(!seed.looks_const("y"), "a+k is not expression-less");
        assert!(!seed.looks_const("a"), "undriven ident must stay runtime");
        assert_eq!(
            crate::expr::Expr::parse("a + k_alias").dominant_op_class_latticed(&seed),
            crate::ir::OperatorClass::Compare,
            "const-offset add after auto-const is an incrementer, not a CPA"
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
            function_bodies: Vec::new(),
            package_imports: vec![],
            instances: vec![],
            decls: Vec::new(),
            const_exprs: Default::default(),
            typedef_texts: Default::default(),
            config_branch: false,
            guards: Default::default(),
            onehot_facts: Default::default(),
            guard_sites: Default::default(),
            decl_texts: Default::default(),
            pipe_pragmas: Default::default(),
            stage_decls: Default::default(),
            branch_arms: Default::default(),
            launch_fo4: Default::default(),
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
            function_bodies: Vec::new(),
            package_imports: vec![],
            instances: vec![],
            decls: Vec::new(),
            const_exprs: Default::default(),
            typedef_texts: Default::default(),
            config_branch: false,
            guards: Default::default(),
            onehot_facts: Default::default(),
            guard_sites: Default::default(),
            decl_texts: Default::default(),
            pipe_pragmas: Default::default(),
            stage_decls: Default::default(),
            branch_arms: Default::default(),
            launch_fo4: Default::default(),
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
            function_bodies: Vec::new(),
            package_imports: vec![],
            instances: vec![],
            decls: Vec::new(),
            const_exprs: Default::default(),
            typedef_texts: Default::default(),
            config_branch: false,
            guards: Default::default(),
            onehot_facts: Default::default(),
            guard_sites: Default::default(),
            decl_texts: Default::default(),
            pipe_pragmas: Default::default(),
            stage_decls: Default::default(),
            branch_arms: Default::default(),
            launch_fo4: Default::default(),
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
            crate::expr::Expr::parse("wrap_boundary + ((ax_req_q.len + 1) << LOG_NR_BYTES)")
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
            function_bodies: Vec::new(),
            package_imports: vec![],
            instances: vec![],
            decls: Vec::new(),
            const_exprs: Default::default(),
            typedef_texts: Default::default(),
            config_branch: false,
            guards: Default::default(),
            onehot_facts: Default::default(),
            guard_sites: Default::default(),
            decl_texts: Default::default(),
            pipe_pragmas: Default::default(),
            stage_decls: Default::default(),
            branch_arms: Default::default(),
            launch_fo4: Default::default(),
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

    fn module_of(nodes: Vec<IrNode>) -> TimingModule {
        let mut map = Map::new();
        for n in nodes {
            map.insert(n.id, n);
        }
        TimingModule {
            id: 0,
            name: "m".into(),
            file: "t.sv".into(),
            nodes: map,
            regions: Map::new(),
            localparams: vec![],
            parameters: vec![],
            ports: vec![],
            gen_loops: vec![],
            functions: vec![],
            function_bodies: Vec::new(),
            package_imports: vec![],
            instances: vec![],
            decls: Vec::new(),
            const_exprs: Default::default(),
            typedef_texts: Default::default(),
            config_branch: false,
            guards: Default::default(),
            onehot_facts: Default::default(),
            guard_sites: Default::default(),
            decl_texts: Default::default(),
            pipe_pragmas: Default::default(),
            stage_decls: Default::default(),
            branch_arms: Default::default(),
            launch_fo4: Default::default(),
            loc: loc(),
        }
    }

    fn has_edge(t: &RefOrderTree, from: u32, to: u32) -> bool {
        t.edges
            .iter()
            .any(|e| e.from_stmt == from && e.to_stmt == to)
    }

    #[test]
    fn dep_keys_keep_members_and_star_indices() {
        assert_eq!(dep_key("q[k].be"), "q[*].be");
        assert_eq!(dep_key("byp_d.paddr[55:3]"), "byp_d.paddr[*]");
        assert_eq!(dep_key("a[b[c]].f"), "a[*].f");
        assert!(dep_related("byp_d", "byp_d.be"));
        assert!(dep_related("q[*]", "q[*].be"));
        assert!(!dep_related("q[*].be", "q[*].paddr"));
        assert!(!dep_related("byp", "byp_d"));
        assert!(dep_covers("byp_d", "byp_d.be"));
        assert!(
            !dep_covers("q[*]", "q[*].be"),
            "an element write covers one element"
        );
    }

    /// delay-v43: the write buffer's T47 shape. A whole-struct write, then a
    /// guard that reads one field and a field rewrite: both depend on it.
    #[test]
    fn guard_reads_and_field_reads_follow_whole_struct_writes() {
        let mut m = module_of(vec![
            node(0, "byp_d", "push_entry", OperatorClass::Mux, 2.5),
            node(
                1,
                "byp_d.be",
                "byp_d.be & ~mask_i",
                OperatorClass::LogicBit,
                1.0,
            ),
            node(2, "other_d.x", "a_i", OperatorClass::Other, 1.0),
        ]);
        m.guards.insert(1, vec!["byp_d.paddr == req_i".into()]);
        let t = RefOrderTree::from_nodes(&m, &[0, 1, 2]);
        assert!(
            has_edge(&t, 0, 1),
            "field read + guard read of a whole write: {:?}",
            t.edges
        );
        assert!(!has_edge(&t, 0, 2) && !has_edge(&t, 1, 2));
        assert!(
            !t.is_write_only("byp_d"),
            "a field read consumes the whole write"
        );
    }

    /// Arms of one `case`/`if` are exclusive: a read in one arm sees the
    /// value from before the statement, not the other arm's write.
    #[test]
    fn exclusive_arms_do_not_chain() {
        let mut m = module_of(vec![
            node(0, "cnt_d", "cnt_q", OperatorClass::Other, 0.0),
            node(1, "cnt_d", "cnt_d + 1", OperatorClass::AddSub, 10.0),
            node(2, "cnt_d", "cnt_d - 1", OperatorClass::AddSub, 10.0),
            node(3, "out_d", "cnt_d", OperatorClass::Other, 1.0),
        ]);
        m.branch_arms.insert(1, vec![[100, 0]]);
        m.branch_arms.insert(2, vec![[100, 1]]);
        let t = RefOrderTree::from_nodes(&m, &[0, 1, 2, 3]);
        assert!(has_edge(&t, 0, 1));
        assert!(has_edge(&t, 0, 2), "arm 1 reads the pre-case value");
        assert!(!has_edge(&t, 1, 2), "arm 1 does not see arm 0's write");
        // after the case, the read is a mux over both arms and the default
        assert!(has_edge(&t, 1, 3) && has_edge(&t, 2, 3));
        assert!(
            has_edge(&t, 0, 3),
            "an unconditional earlier write still reaches the mux"
        );
    }

    /// An enclosing write of the whole value ends the priority chain.
    #[test]
    fn covering_write_stops_the_search() {
        let m = module_of(vec![
            node(0, "x_d", "a_i", OperatorClass::Other, 1.0),
            node(1, "x_d", "b_i + c_i", OperatorClass::AddSub, 10.0),
            node(2, "y_d", "x_d", OperatorClass::Other, 1.0),
        ]);
        let t = RefOrderTree::from_nodes(&m, &[0, 1, 2]);
        assert!(has_edge(&t, 1, 2));
        assert!(
            !has_edge(&t, 0, 2),
            "x_d was overwritten whole before the read"
        );
    }
}
