// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! `svt-stage:` comment pragmas — a stage-aware FO4 view (PIPELINE-PRAGMAS
//! §19). Distinct from `svt-pipe` cut contracts and `svt-plan` notes: a
//! `svt-stage` region only groups the nodes whose origin-mapped source line
//! falls between its `begin`/`end` comments and gives that group its own
//! budget multiplier. This is a *view*: the base closure numbers are
//! measurement truth and are not changed.
//!
//! ```text
//! // svt-stage: begin <name> [cycles=<n>] [window=<n>] [after=<name2>]
//! // svt-stage: end <name>
//! // svt-stage: order <module> <s1>,<s2>,...
//! // svt-stage: use <name> on=<signal>[,<signal>...]
//! // svt-stage: class <stage> decision|value
//! // svt-stage: absorb <stage> by=<mechanism> [cond=<text>]
//! ```
//!
//! * `cycles=n` (default 1): a path whose start and end nodes are both in
//!   the stage is judged against `n × budget_fo4` (a declared multi-cycle
//!   window, reported as such).
//! * `window=n` (default 0): a path entering the stage from another stage
//!   gets `n` extra cycles: budget `(1+n) × budget_fo4`.
//! * `after=<name2>`: a combinational path crossing from `name2` into this
//!   stage without a flop boundary is a finding.
//! * `use … on=` overrides the region assignment for the nodes that drive
//!   the named nets (LHS root match), wherever the assign sits.
//! * Nodes in no region belong to the implicit stage `-` (unstaged).

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::ir::{IrNode, PathId, TimingDesign, TimingModule};
use crate::loc::SourceLoc;
use crate::OriginKind;

/// One resolved `svt-stage: begin/end` region.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StageDecl {
    /// Stage name.
    pub name: String,
    /// Multi-cycle allowance for in-stage paths (default 1).
    #[serde(default = "one_u32")]
    pub cycles: u32,
    /// Extra cycles granted to paths entering the stage (default 0).
    #[serde(default)]
    pub window: u32,
    /// Declared predecessor stage for the boundary check.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub after: Option<String>,
    /// `begin` pragma location (file, line).
    pub begin: SourceLoc,
    /// `end` pragma location (file, line).
    pub end: SourceLoc,
}

fn one_u32() -> u32 {
    1
}

/// A `svt-stage: use <name> on=<sig>[,<sig>…]` override.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StageUse {
    /// Stage the named nets belong to.
    pub stage: String,
    /// Driven net names (LHS root).
    pub nets: Vec<String>,
    /// Pragma location.
    pub loc: SourceLoc,
}

/// An `absorb <stage> by=<mechanism> [cond=<text>]` declaration: a declared
/// architectural cover for a decision-class stage (speculative wakeup,
/// read-ahead, …) — §19.1.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StageAbsorb {
    /// Covered stage name.
    pub stage: String,
    /// Cover mechanism — one of [`ABSORB_MECHANISMS`].
    pub by: String,
    /// Cover precondition text (quoted or free-form rest-of-line).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cond: Option<String>,
    /// Pragma location.
    pub loc: SourceLoc,
}

/// Cover mechanism names accepted by `svt-stage: absorb`.
pub const ABSORB_MECHANISMS: [&str; 6] = [
    "spec-wakeup",
    "read-ahead",
    "elastic",
    "replicate",
    "async",
    "throughput",
];

/// The `svt-stage` surface of one module, collected over its body span.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ModuleStages {
    /// Resolved regions.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub stages: Vec<StageDecl>,
    /// `use … on=` overrides.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub uses: Vec<StageUse>,
    /// Declared stage order (`svt-stage: order`), when present.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub order: Vec<String>,
    /// Module name the `order` pragma was written for (documentation).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub order_module: Option<String>,
    /// `class <stage> decision|value` — author classification for the
    /// bubble-up analysis (§19.1); wins over every heuristic.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub classes: BTreeMap<String, String>,
    /// `absorb <stage> by=…` — declared architectural covers (§19.1).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub absorbs: Vec<StageAbsorb>,
    /// Structural issues (unbalanced begin/end, nesting deeper than one
    /// level, duplicated region name, pragma argument problems).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub issues: Vec<String>,
}

impl ModuleStages {
    /// True when nothing was declared.
    pub fn is_empty(&self) -> bool {
        self.stages.is_empty() && self.uses.is_empty() && self.order.is_empty()
    }
}

/// An open `begin` while scanning.
struct OpenStage {
    name: String,
    cycles: u32,
    window: u32,
    after: Option<String>,
    begin: SourceLoc,
}

/// Collect the `svt-stage:` pragma lines over one module span. Same scan
/// discipline as `collect_pipe_pragmas`: raw source lines, comment prefix
/// match only.
pub fn collect_stage_pragmas(
    bytes: &[u8],
    path_str: &str,
    start: &SourceLoc,
    end: &u32,
) -> ModuleStages {
    let lo = start.byte_start as usize;
    let hi = (*end as usize).max(lo).min(bytes.len());
    let text = String::from_utf8_lossy(&bytes[lo..hi]);
    let line_base = start.start_line;
    let mut out = ModuleStages::default();
    let mut open: Vec<OpenStage> = Vec::new();
    let mut offset = lo;
    for (i, line) in text.split_inclusive('\n').enumerate() {
        let line_no = line_base + i as u32;
        let line_start = offset;
        offset += line.len();
        let Some(ci) = line.find("//") else { continue };
        let body = line[ci + 2..].trim();
        let Some(rest) = body.strip_prefix("svt-stage:") else {
            continue;
        };
        let trimmed_len = line.trim_end_matches(['\n', '\r']).len();
        let loc = SourceLoc {
            file: path_str.to_string(),
            start_line: line_no,
            start_col: (ci + 1) as u32,
            end_line: line_no,
            end_col: (trimmed_len + 1) as u32,
            byte_start: (line_start + ci) as u32,
            byte_end: (line_start + trimmed_len) as u32,
            origin: OriginKind::UserFile,
        };
        let mut words = rest.split_whitespace();
        let Some(kind) = words.next() else { continue };
        let words: Vec<&str> = words.collect();
        match kind {
            "begin" => {
                let Some(name) = words.first().copied() else {
                    out.issues
                        .push(format!("{line_no}: `svt-stage: begin` without a stage name"));
                    continue;
                };
                if name.contains('=') {
                    out.issues
                        .push(format!("{line_no}: `svt-stage: begin` name looks like an arg `{name}`"));
                    continue;
                }
                let mut cycles = 1u32;
                let mut window = 0u32;
                let mut after = None;
                let mut bad = false;
                for w in &words[1..] {
                    if let Some((k, v)) = w.split_once('=') {
                        match k {
                            "cycles" => match v.parse::<u32>() {
                                Ok(n) if n >= 1 => cycles = n,
                                _ => {
                                    out.issues.push(format!(
                                        "{line_no}: bad `cycles=` value `{v}`"
                                    ));
                                    bad = true;
                                }
                            },
                            "window" => match v.parse::<u32>() {
                                Ok(n) => window = n,
                                _ => {
                                    out.issues.push(format!(
                                        "{line_no}: bad `window=` value `{v}`"
                                    ));
                                    bad = true;
                                }
                            },
                            "after" => after = Some(v.to_string()),
                            other => out.issues.push(format!(
                                "{line_no}: unknown `svt-stage: begin` arg `{other}`"
                            )),
                        }
                    } else {
                        out.issues
                            .push(format!("{line_no}: stray token `{w}` on `begin`"));
                        bad = true;
                    }
                }
                if bad {
                    continue;
                }
                if open.len() >= 2 {
                    out.issues.push(format!(
                        "{line_no}: `begin {name}` nests deeper than one level (open: {})",
                        open.iter().map(|o| o.name.as_str()).collect::<Vec<_>>().join(","),
                    ));
                    continue;
                }
                if open.iter().any(|o| o.name == name)
                    || out.stages.iter().any(|s| s.name == name)
                {
                    out.issues
                        .push(format!("{line_no}: duplicate stage name `{name}`"));
                    continue;
                }
                open.push(OpenStage {
                    name: name.to_string(),
                    cycles,
                    window,
                    after,
                    begin: loc,
                });
            }
            "end" => {
                let Some(name) = words.first().copied() else {
                    out.issues
                        .push(format!("{line_no}: `svt-stage: end` without a stage name"));
                    continue;
                };
                match open.iter().rposition(|o| o.name == name) {
                    Some(pos) if pos == open.len() - 1 => {
                        let st = open.pop().expect("stack non-empty");
                        out.stages.push(StageDecl {
                            name: st.name,
                            cycles: st.cycles,
                            window: st.window,
                            after: st.after,
                            begin: st.begin,
                            end: loc,
                        });
                    }
                    Some(pos) => {
                        out.issues.push(format!(
                            "{line_no}: `end {name}` while `{}` is still open",
                            open.last().map(|o| o.name.as_str()).unwrap_or("?")
                        ));
                        let st = open.remove(pos);
                        out.stages.push(StageDecl {
                            name: st.name,
                            cycles: st.cycles,
                            window: st.window,
                            after: st.after,
                            begin: st.begin,
                            end: loc.clone(),
                        });
                    }
                    None => out.issues.push(format!(
                        "{line_no}: `end {name}` without a matching `begin`"
                    )),
                }
            }
            "order" => {
                // `order <module> <s1>,<s2>,...` — module name is
                // documentation; the list is what consumers read.
                let Some(module_name) = words.first().copied() else {
                    out.issues
                        .push(format!("{line_no}: `svt-stage: order` without arguments"));
                    continue;
                };
                out.order_module = Some(module_name.to_string());
                if let Some(list) = words.get(1) {
                    out.order = list
                        .split(',')
                        .map(|s| s.trim())
                        .filter(|s| !s.is_empty())
                        .map(|s| s.to_string())
                        .collect();
                }
            }
            "use" => {
                let Some(name) = words.first().copied() else {
                    out.issues
                        .push(format!("{line_no}: `svt-stage: use` without a stage name"));
                    continue;
                };
                let mut nets = Vec::new();
                for w in &words[1..] {
                    if let Some((k, v)) = w.split_once('=') {
                        if k == "on" {
                            nets.extend(
                                v.split(',')
                                    .map(|s| s.trim())
                                    .filter(|s| !s.is_empty())
                                    .map(|s| s.to_string()),
                            );
                        } else {
                            out.issues.push(format!(
                                "{line_no}: unknown `svt-stage: use` arg `{k}`"
                            ));
                        }
                    } else {
                        for part in w.split(',') {
                            if !part.is_empty() {
                                nets.push(part.to_string());
                            }
                        }
                    }
                }
                if nets.is_empty() {
                    out.issues
                        .push(format!("{line_no}: `svt-stage: use {name}` names no nets"));
                }
                out.uses.push(StageUse {
                    stage: name.to_string(),
                    nets,
                    loc,
                });
            }
            "class" => {
                // `class <stage> decision|value` — the author's verdict for
                // the bubble-up classification (§19.1).
                let Some(name) = words.first().copied() else {
                    out.issues
                        .push(format!("{line_no}: `svt-stage: class` without a stage name"));
                    continue;
                };
                match words.get(1).copied() {
                    Some(v @ ("decision" | "value")) => {
                        out.classes.insert(name.to_string(), v.to_string());
                    }
                    Some(other) => out.issues.push(format!(
                        "{line_no}: `svt-stage: class {name}` wants decision|value, got `{other}`"
                    )),
                    None => out.issues.push(format!(
                        "{line_no}: `svt-stage: class {name}` without a class"
                    )),
                }
            }
            "absorb" => {
                // `absorb <stage> by=<mechanism> [cond=<text>]` — the cond
                // may be a quoted phrase, so it is taken as the raw tail of
                // the line after `cond=`.
                let Some(name) = words.first().copied() else {
                    out.issues
                        .push(format!("{line_no}: `svt-stage: absorb` without a stage name"));
                    continue;
                };
                let mut by: Option<String> = None;
                for w in &words[1..] {
                    if let Some((k, v)) = w.split_once('=') {
                        if k == "by" {
                            by = Some(v.to_string());
                        } else if k != "cond" {
                            out.issues.push(format!(
                                "{line_no}: unknown `svt-stage: absorb` arg `{k}`"
                            ));
                        }
                    }
                }
                let cond = rest.find("cond=").map(|ci| {
                    let raw = rest[ci + 5..].trim();
                    raw.trim_matches('"').trim().to_string()
                });
                match by {
                    Some(mech) if ABSORB_MECHANISMS.contains(&mech.as_str()) => {
                        out.absorbs.push(StageAbsorb {
                            stage: name.to_string(),
                            by: mech,
                            cond: cond.filter(|c| !c.is_empty()),
                            loc,
                        });
                    }
                    Some(other) => out.issues.push(format!(
                        "{line_no}: `svt-stage: absorb {name}` wants by={}, got `{other}`",
                        ABSORB_MECHANISMS.join("|")
                    )),
                    None => out.issues.push(format!(
                        "{line_no}: `svt-stage: absorb {name}` without `by=`"
                    )),
                }
            }
            other => out
                .issues
                .push(format!("{line_no}: unknown `svt-stage` kind `{other}`")),
        }
    }
    for st in open {
        out.issues.push(format!(
            "{}: `begin {}` never closed",
            st.begin.start_line, st.name
        ));
        out.stages.push(StageDecl {
            name: st.name,
            cycles: st.cycles,
            window: st.window,
            after: st.after,
            end: SourceLoc {
                file: st.begin.file.clone(),
                start_line: u32::MAX,
                start_col: 0,
                end_line: u32::MAX,
                end_col: 0,
                byte_start: u32::MAX,
                byte_end: u32::MAX,
                origin: OriginKind::UserFile,
            },
            begin: st.begin,
        });
    }
    out
}

/// The stage a node belongs to: `use … on=` override on its LHS root first,
/// then the innermost region containing its origin-mapped line.
/// `None` → implicit stage `-` (unstaged).
pub fn node_stage(decls: &ModuleStages, node: &IrNode) -> Option<String> {
    if let Some(lhs) = node.lhs.as_deref() {
        if let Some(root) = TimingModule::root_ident(lhs) {
            for u in &decls.uses {
                if u.nets.iter().any(|n| n == root) {
                    return Some(u.stage.clone());
                }
            }
        }
    }
    let mut best: Option<&StageDecl> = None;
    for st in &decls.stages {
        let inside = node.loc.file == st.begin.file
            && node.loc.start_line > st.begin.start_line
            && node.loc.start_line < st.end.start_line;
        if inside && best.map_or(true, |b| st.begin.start_line > b.begin.start_line) {
            best = Some(st);
        }
    }
    best.map(|s| s.name.clone())
}

/// Stage of every node in a module (the computed side table — not stored
/// in the IR).
pub fn stage_map(module: &TimingModule) -> BTreeMap<crate::ir::NodeId, Option<String>> {
    module
        .nodes
        .iter()
        .map(|(id, n)| (*id, node_stage(&module.stage_decls, n)))
        .collect()
}

/// Path-endpoint stage pair: stage of the first and last comb node on the
/// path (`None` → unstaged `-`).
pub fn path_stages(design: &TimingDesign, path: &crate::ir::TimingPath) -> (Option<String>, Option<String>) {
    let Some(m) = design.modules.get(&path.module) else {
        return (None, None);
    };
    if m.stage_decls.is_empty() {
        return (None, None);
    }
    let first = path
        .nodes
        .first()
        .and_then(|id| m.nodes.get(id))
        .and_then(|n| node_stage(&m.stage_decls, n));
    let last = path
        .nodes
        .last()
        .and_then(|id| m.nodes.get(id))
        .and_then(|n| node_stage(&m.stage_decls, n));
    (first, last)
}

/// Annotate `stage_start` / `stage_end` on every path (post-pass in lower).
pub fn annotate_paths(design: &mut TimingDesign) {
    let mut table: BTreeMap<PathId, (Option<String>, Option<String>)> = BTreeMap::new();
    for p in &design.paths {
        let (s, e) = path_stages(design, p);
        if s.is_some() || e.is_some() {
            table.insert(p.id, (s, e));
        }
    }
    for p in &mut design.paths {
        if let Some((s, e)) = table.remove(&p.id) {
            p.stage_start = s;
            p.stage_end = e;
        }
    }
}

/// Compact path reference for the stage report.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StagePathRef {
    /// Path id.
    pub path_id: PathId,
    /// Total FO4.
    pub total_fo4: f64,
    /// Startpoint label.
    pub startpoint: String,
    /// Endpoint label.
    pub endpoint: String,
    /// Hottest node location.
    pub primary_loc: SourceLoc,
}

/// Into-stage path reference (adds the launching stage).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StageIntoRef {
    /// Stage the path starts in (`-` = unstaged).
    pub from_stage: String,
    /// Path id.
    pub path_id: PathId,
    /// Total FO4.
    pub total_fo4: f64,
    /// Startpoint label.
    pub startpoint: String,
    /// Endpoint label.
    pub endpoint: String,
}

/// Declaration coordinates as reported.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StageDeclJson {
    /// Region file.
    pub file: String,
    /// `begin` line.
    pub line_begin: u32,
    /// `end` line.
    pub line_end: u32,
    /// Declared cycles.
    pub cycles: u32,
    /// Declared window.
    pub window: u32,
    /// Declared predecessor.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub after: Option<String>,
}

/// One `stages[]` row of the analyze/correct report.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StageReportRow {
    /// Module name.
    pub module: String,
    /// Stage name.
    pub stage: String,
    /// Declaration coordinates.
    pub decl: StageDeclJson,
    /// Nodes assigned to the stage.
    pub node_count: usize,
    /// Worst path fully inside the stage.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worst_in_stage: Option<StagePathRef>,
    /// Worst path entering the stage from another stage.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worst_into_stage: Option<StageIntoRef>,
    /// `cycles × budget_fo4`.
    pub stage_budget_fo4: f64,
    /// True when every in-stage path closes at the stage budget.
    pub closes_in_stage: bool,
    /// True when every into-stage path closes at `(1+window) × budget`.
    pub closes_into_stage: bool,
    /// Findings (boundary crossed combinationally, pragma issues).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub findings: Vec<String>,
}

/// One `stage_users[]` row: the modules that declare stages and where they
/// are instantiated.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StageUseRow {
    /// Module declaring stages.
    pub module: String,
    /// Declared stage names.
    pub stages: Vec<String>,
    /// Instantiation sites.
    pub used_by: Vec<StageUsedBy>,
}

/// One instantiation of a staged module.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StageUsedBy {
    /// Parent module name.
    pub parent_module: String,
    /// Instance name.
    pub instance: String,
    /// File the instantiation sits in.
    pub file: String,
}

/// Combinational `pred -> stage` crossings seen in the node graph (the
/// spec fallback when no single path spans both regions): a comb node in
/// `stage` reads a net whose *driver* is a comb node in `pred`, so the
/// boundary is crossed with no flop between. Returns `net (file:line)`
/// evidence strings, deduplicated.
fn comb_boundary_crossings(m: &TimingModule, pred: &str, stage: &str) -> Vec<String> {
    // node -> inside a combinational region (always_comb / cont assign)?
    let mut comb_node: BTreeMap<crate::ir::NodeId, bool> = BTreeMap::new();
    for r in m.regions.values() {
        let is_comb = matches!(
            r.kind,
            crate::ir::RegionKind::AlwaysComb | crate::ir::RegionKind::ContAssign
        );
        for n in &r.nodes {
            comb_node.insert(*n, is_comb);
        }
    }
    let is_comb = |id: &crate::ir::NodeId| comb_node.get(id).copied().unwrap_or(true);
    // comb drivers: lhs root -> comb nodes that assign it.
    let mut drivers: BTreeMap<String, Vec<crate::ir::NodeId>> = BTreeMap::new();
    for (id, n) in &m.nodes {
        if !is_comb(id) {
            continue;
        }
        if let Some(lhs) = n.lhs.as_deref() {
            if let Some(root) = TimingModule::root_ident(lhs) {
                drivers.entry(root.to_string()).or_default().push(*id);
            }
        }
    }
    let mut out = Vec::new();
    for (id, n) in &m.nodes {
        if !is_comb(id) || node_stage(&m.stage_decls, n).as_deref() != Some(stage) {
            continue;
        }
        let parsed;
        let e = match &n.rhs_expr {
            Some(e) => e,
            None => {
                let Some(rhs) = &n.rhs else { continue };
                parsed = crate::expr::Expr::parse(rhs);
                &parsed
            }
        };
        let mut idents = Vec::new();
        e.walk_idents(&mut |s| idents.push(s.to_string()));
        for net in idents {
            let Some(dnodes) = drivers.get(&net) else { continue };
            for d in dnodes {
                if *d == *id {
                    continue;
                }
                if node_stage(&m.stage_decls, &m.nodes[d]).as_deref() == Some(pred) {
                    out.push(format!(
                        "net `{net}` driven comb in {pred} ({}:{}), read in {stage} ({}:{})",
                        m.nodes[d].loc.file,
                        m.nodes[d].loc.start_line,
                        n.loc.file,
                        n.loc.start_line
                    ));
                }
            }
        }
    }
    out.sort();
    out.dedup();
    out
}

/// Compute the stage report: per stage, the worst in-stage and into-stage
/// paths against the stage's declared budgets, plus the after-boundary
/// findings and pragma issues.
pub fn stage_report(design: &TimingDesign) -> Vec<StageReportRow> {
    let budget = design.target.budget_fo4;
    let mut rows = Vec::new();
    for m in design.modules.values() {
        if m.stage_decls.stages.is_empty() && m.stage_decls.issues.is_empty() {
            continue;
        }
        let smap = stage_map(m);
        let mpaths: Vec<&crate::ir::TimingPath> = design
            .paths
            .iter()
            .filter(|p| p.module == m.id)
            .collect();
        let stage_of = |nid: &crate::ir::NodeId| -> Option<String> {
            smap.get(nid).cloned().flatten()
        };
        for (idx, st) in m.stage_decls.stages.iter().enumerate() {
            let node_count = smap
                .values()
                .filter(|s| s.as_deref() == Some(st.name.as_str()))
                .count();
            let mut worst_in: Option<StagePathRef> = None;
            let mut worst_into: Option<StageIntoRef> = None;
            let mut in_fail = false;
            let mut into_fail = false;
            let stage_budget = st.cycles as f64 * budget;
            let into_budget = (1 + st.window) as f64 * budget;
            for p in &mpaths {
                let s0 = p.nodes.first().and_then(stage_of);
                let s1 = p.nodes.last().and_then(stage_of);
                if s0.as_deref() == Some(st.name.as_str())
                    && s1.as_deref() == Some(st.name.as_str())
                {
                    if p.total_fo4 > stage_budget {
                        in_fail = true;
                    }
                    if worst_in
                        .as_ref()
                        .map_or(true, |w| p.total_fo4 > w.total_fo4)
                    {
                        worst_in = Some(StagePathRef {
                            path_id: p.id,
                            total_fo4: p.total_fo4,
                            startpoint: p.startpoint.clone(),
                            endpoint: p.endpoint.clone(),
                            primary_loc: p.primary_loc.clone(),
                        });
                    }
                } else if s1.as_deref() == Some(st.name.as_str())
                    && s0.as_deref() != Some(st.name.as_str())
                {
                    if p.total_fo4 > into_budget {
                        into_fail = true;
                    }
                    if worst_into
                        .as_ref()
                        .map_or(true, |w| p.total_fo4 > w.total_fo4)
                    {
                        worst_into = Some(StageIntoRef {
                            from_stage: s0.unwrap_or_else(|| "-".into()),
                            path_id: p.id,
                            total_fo4: p.total_fo4,
                            startpoint: p.startpoint.clone(),
                            endpoint: p.endpoint.clone(),
                        });
                    }
                }
            }
            let mut findings = Vec::new();
            if let Some(pred) = &st.after {
                for p in &mpaths {
                    let s0 = p.nodes.first().and_then(stage_of);
                    let s1 = p.nodes.last().and_then(stage_of);
                    if s0.as_deref() == Some(pred.as_str())
                        && s1.as_deref() == Some(st.name.as_str())
                    {
                        findings.push(format!(
                            "stage boundary crossed combinationally: {pred} -> {} (path {}: {} -> {})",
                            st.name, p.id, p.startpoint, p.endpoint
                        ));
                    }
                }
                for ev in comb_boundary_crossings(m, pred, &st.name) {
                    findings.push(format!(
                        "stage boundary crossed combinationally: {pred} -> {} ({ev})",
                        st.name
                    ));
                }
            }
            if idx == 0 {
                findings.extend(m.stage_decls.issues.iter().cloned());
            }
            rows.push(StageReportRow {
                module: m.name.clone(),
                stage: st.name.clone(),
                decl: StageDeclJson {
                    file: st.begin.file.clone(),
                    line_begin: st.begin.start_line,
                    line_end: if st.end.start_line == u32::MAX {
                        0
                    } else {
                        st.end.start_line
                    },
                    cycles: st.cycles,
                    window: st.window,
                    after: st.after.clone(),
                },
                node_count,
                worst_in_stage: worst_in,
                worst_into_stage: worst_into,
                stage_budget_fo4: stage_budget,
                closes_in_stage: !in_fail,
                closes_into_stage: !into_fail,
                findings,
            });
        }
        // Modules whose every pragma failed to resolve still report issues.
        if m.stage_decls.stages.is_empty() && !m.stage_decls.issues.is_empty() {
            rows.push(StageReportRow {
                module: m.name.clone(),
                stage: "-".into(),
                decl: StageDeclJson {
                    file: m.file.clone(),
                    line_begin: 0,
                    line_end: 0,
                    cycles: 1,
                    window: 0,
                    after: None,
                },
                node_count: 0,
                worst_in_stage: None,
                worst_into_stage: None,
                stage_budget_fo4: budget,
                closes_in_stage: true,
                closes_into_stage: true,
                findings: m.stage_decls.issues.clone(),
            });
        }
    }
    rows
}

/// Every instantiation site of a module that declares stages.
pub fn stage_users(design: &TimingDesign) -> Vec<StageUseRow> {
    let mut rows = Vec::new();
    for m in design.modules.values() {
        if m.stage_decls.is_empty() {
            continue;
        }
        let mut used_by: Vec<StageUsedBy> = design
            .all_instances()
            .into_iter()
            .filter(|i| i.child_type == m.name)
            .map(|i| StageUsedBy {
                parent_module: i.parent_name.clone(),
                instance: i.instance_name.clone(),
                file: i.loc.file.clone(),
            })
            .collect();
        used_by.sort_by(|a, b| {
            a.parent_module
                .cmp(&b.parent_module)
                .then(a.instance.cmp(&b.instance))
        });
        used_by.dedup_by(|a, b| {
            a.parent_module == b.parent_module && a.instance == b.instance
        });
        rows.push(StageUseRow {
            module: m.name.clone(),
            stages: m
                .stage_decls
                .stages
                .iter()
                .map(|s| s.name.clone())
                .collect(),
            used_by,
        });
    }
    rows
}

/// Print the `--stages` table: per staged module, one line per stage plus
/// a users table. Empty when no module declares stages.
pub fn render_stage_table(design: &TimingDesign) -> String {
    let rows = stage_report(design);
    if rows.is_empty() {
        return String::new();
    }
    let mut out = String::new();
    // §19.1 bubble-up: one line after each stage that adds cycles.
    let bubbles: BTreeMap<(String, String), crate::stage_bubble::StageBubble> =
        crate::stage_bubble::stage_bubbles(design)
            .into_iter()
            .map(|b| ((b.module.clone(), b.stage.clone()), b))
            .collect();
    let mut cur_module: Option<&str> = None;
    for r in &rows {
        if cur_module != Some(r.module.as_str()) {
            if cur_module.is_some() {
                out.push('\n');
            }
            cur_module = Some(r.module.as_str());
            out.push_str(&format!("  module {}\n", r.module));
            out.push_str(
                "    stage      cyc win   nodes  worst-in FO4 (budget)      worst-into FO4 (from)        decl                findings\n",
            );
        }
        let win = if let Some(w) = &r.worst_in_stage {
            format!("{:>5.1} / {:>5.1}{}", w.total_fo4, r.stage_budget_fo4, if r.closes_in_stage { " " } else { " !" })
        } else {
            "    -    ".to_string()
        };
        let winto = if let Some(w) = &r.worst_into_stage {
            format!(
                "{:>5.1} / {:>5.1} ({}){}",
                w.total_fo4,
                (1.0 + r.decl.window as f64) * design.target.budget_fo4,
                w.from_stage,
                if r.closes_into_stage { "" } else { " !" }
            )
        } else {
            "    -    ".to_string()
        };
        out.push_str(&format!(
            "    {:<10} {:>3} {:>3} {:>7}  {:<23} {:<27} {}:{}-{}  {}\n",
            r.stage,
            r.decl.cycles,
            r.decl.window,
            r.node_count,
            win,
            winto,
            short_file(&r.decl.file),
            r.decl.line_begin,
            r.decl.line_end,
            r.findings.join("; "),
        ));
        if let Some(b) = bubbles.get(&(r.module.clone(), r.stage.clone())) {
            out.push_str(&crate::stage_bubble::bubble_line(b));
            out.push('\n');
        }
    }
    let users = stage_users(design);
    if !users.is_empty() {
        out.push_str("\n  stage users\n");
        for u in &users {
            let where_: Vec<String> = u
                .used_by
                .iter()
                .map(|x| format!("{}.{} ({})", x.parent_module, x.instance, short_file(&x.file)))
                .collect();
            out.push_str(&format!(
                "    {:<20} stages=[{}] used_by={}\n",
                u.module,
                u.stages.join(","),
                if where_.is_empty() {
                    "-".to_string()
                } else {
                    where_.join("; ")
                },
            ));
        }
    }
    out
}

fn short_file(file: &str) -> String {
    file.rsplit(['/', '\\']).next().unwrap_or(file).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cost_table::default_fo4_v1_embedded;
    use crate::ir::TimingTarget;
    use crate::lower::{analyze_files, lower_unit, AnalyzeOutput, LowerOptions};
    use crate::loc::LineIndex;
    use crate::parse::{ParsedFile, ParsedUnit};
    use std::path::PathBuf;

    fn analyze_src(text: &str, target_mhz: f64) -> AnalyzeOutput {
        let path = PathBuf::from("stage_pragma_test.sv");
        let defines: sv_parser::Defines = Default::default();
        let (tree, _) =
            sv_parser::parse_sv_str(text, &path, &defines, &[] as &[PathBuf], false, false)
                .expect("parse inline source");
        let file = ParsedFile {
            path: path.clone(),
            bytes: text.as_bytes().to_vec(),
            line_index: LineIndex::from_bytes(path, text.as_bytes()),
            tree,
        };
        let mut opts = LowerOptions::default();
        opts.cost_model = default_fo4_v1_embedded();
        opts.target = TimingTarget::new(target_mhz, 20.0, 0.2);
        lower_unit(
            &ParsedUnit {
                files: vec![file],
                skipped: vec![],
            },
            &opts,
        )
        .expect("lower inline source")
    }

    fn analyze_fixture() -> AnalyzeOutput {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../fixtures/auto_correct/stage_pragmas.sv");
        let parse = crate::parse::ParseOptions::default();
        let mut opts = LowerOptions::default();
        opts.cost_model = default_fo4_v1_embedded();
        opts.target = TimingTarget::new(5000.0, 20.0, 0.2);
        analyze_files(&[path], &parse, &opts).expect("analyze stage_pragmas fixture")
    }

    #[test]
    fn region_parse_collects_args_and_reports_unbalanced() {
        let text = b"module m;\n  // svt-stage: begin S1 cycles=2 window=1 after=S0\n  logic a;\n  // svt-stage: end S1\n  // svt-stage: begin OPEN\n  logic b;\n  // svt-stage: end MISSING\n  // svt-stage: use S1 on=foo,bar\n  // svt-stage: order m S1,OPEN\nendmodule\n";
        let bytes = text.to_vec();
        let start = SourceLoc {
            file: "m.sv".into(),
            start_line: 1,
            start_col: 1,
            end_line: 10,
            end_col: 1,
            byte_start: 0,
            byte_end: bytes.len() as u32,
            origin: OriginKind::UserFile,
        };
        let decls = collect_stage_pragmas(&bytes, "m.sv", &start, &(bytes.len() as u32));
        // S1 resolved with its args; OPEN closed unbalanced at EOF.
        let s1 = decls.stages.iter().find(|s| s.name == "S1").expect("S1");
        assert_eq!(s1.cycles, 2);
        assert_eq!(s1.window, 1);
        assert_eq!(s1.after.as_deref(), Some("S0"));
        assert_eq!(s1.begin.start_line, 2);
        assert_eq!(s1.end.start_line, 4);
        assert!(decls
            .issues
            .iter()
            .any(|i| i.contains("never closed") && i.contains("OPEN")));
        assert!(decls
            .issues
            .iter()
            .any(|i| i.contains("without a matching `begin`")));
        assert_eq!(decls.uses.len(), 1);
        assert_eq!(decls.uses[0].nets, vec!["foo", "bar"]);
        assert_eq!(decls.order, vec!["S1", "OPEN"]);
    }

    #[test]
    fn node_stage_uses_regions_and_use_override() {
        let src = r#"
module m (input logic [7:0] a_i, output logic [7:0] y_o);
  logic [7:0] p;
  // svt-stage: use S on=p
  assign p = a_i + 8'd1;
  // svt-stage: begin S
  logic [7:0] q;
  always_comb begin
    q = p & a_i;
  end
  // svt-stage: end S
  assign y_o = q;
endmodule
"#;
        let out = analyze_src(src, 5000.0);
        let m = out.design.modules.values().next().unwrap();
        let smap = stage_map(m);
        let stage_of = |lhs: &str| -> Option<String> {
            m.nodes
                .values()
                .find(|n| n.lhs.as_deref() == Some(lhs))
                .and_then(|n| smap.get(&n.id).cloned().flatten())
        };
        // `p`'s assign sits outside the region but is claimed by `use`.
        assert_eq!(stage_of("p").as_deref(), Some("S"));
        assert_eq!(stage_of("q").as_deref(), Some("S"));
        // `y_o` is in no region and not claimed: unstaged.
        assert_eq!(stage_of("y_o"), None);
        // Every path is annotated.
        assert!(out
            .design
            .paths
            .iter()
            .any(|p| p.stage_start.is_some() || p.stage_end.is_some()));
    }

    #[test]
    fn stage_budgets_in_into_finding_and_users() {
        let out = analyze_fixture();
        let rows = stage_report(&out.design);
        let budget = out.design.target.budget_fo4;
        assert!((budget - 8.0).abs() < 1e-6, "budget={budget}");
        let s1 = rows.iter().find(|r| r.stage == "S1").expect("S1 row");
        let s2 = rows.iter().find(|r| r.stage == "S2").expect("S2 row");
        let s3 = rows.iter().find(|r| r.stage == "S3").expect("S3 row");

        // S1: short cone closes at the base budget.
        assert!(s1.closes_in_stage);
        // S2: the cone fails the base budget but closes at cycles=2.
        let s2w = s2.worst_in_stage.as_ref().expect("S2 worst in-stage");
        assert!(s2w.total_fo4 > budget, "S2 must exceed base: {}", s2w.total_fo4);
        assert!(s2w.total_fo4 <= s2.stage_budget_fo4);
        assert!((s2.stage_budget_fo4 - 16.0).abs() < 1e-6);
        assert!(s2.closes_in_stage);
        // The deliberate combinational S1 -> S2 crossing is a finding.
        assert!(
            s2.findings
                .iter()
                .any(|f| f.contains("crossed combinationally") && f.contains("s1x_d")),
            "S2 findings={:?}",
            s2.findings
        );
        // S3: register-bounded behind S2 (no after finding); the path from
        // the unstaged `-` region is the into-stage case at (1+window)x.
        assert!(s3.findings.is_empty(), "S3 findings={:?}", s3.findings);
        let s3i = s3.worst_into_stage.as_ref().expect("S3 worst into-stage");
        assert_eq!(s3i.from_stage, "-");
        assert!(s3.closes_into_stage, "S3 into={:?}", s3i);

        // Per-path view fields are set on staged paths.
        assert!(out.design.paths.iter().any(|p| p.stage_start.as_deref()
            == Some("S2")
            && p.stage_end.as_deref() == Some("S2")));

        // stage_users: two instantiation sites in the top.
        let users = stage_users(&out.design);
        let u = users
            .iter()
            .find(|u| u.module == "stage_pragmas")
            .expect("stage_users row");
        assert_eq!(u.stages, vec!["S1", "S2", "S3"]);
        assert_eq!(u.used_by.len(), 2);
        assert!(u
            .used_by
            .iter()
            .all(|x| x.parent_module == "stage_pragmas_top"));
    }
}
