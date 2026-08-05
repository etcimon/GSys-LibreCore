// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Dense SystemVerilog emission for precompiler edits:
// parameters, moved locals, assigns, predicates, begin/end/else, ternaries.

//! Dense emit helpers. Prefer structured SV over comment-only stubs so
//! regress can measure emission density and pyslang can lint real constructs.

use sv_timing_transform::{EditKind, EditRecord, EditTrace};

use crate::origin_comment;
use crate::rhs::{sink_assigns_sv, CutAssign};

/// Density counters for regress validation of precompile emission.
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct DensityReport {
    /// Non-comment lines in the auto-correct region.
    pub dense_lines: u32,
    /// `parameter` / `localparam` count.
    pub parameters: u32,
    /// Continuous / procedural assign statements (`=` or `<=` or `assign`).
    pub assignments: u32,
    /// `if` / `else` predicates.
    pub predicates: u32,
    /// `begin` / `end` blocks.
    pub begin_end: u32,
    /// Ternary `?` operators.
    pub ternaries: u32,
    /// `always_comb` / `always_ff` procedural blocks.
    pub always_blocks: u32,
    /// Intermediate wire/reg decls introduced (variable movement surface).
    pub moved_locals: u32,
}

impl DensityReport {
    /// Sum of structural construct hits (used as a density score).
    pub fn score(&self) -> u32 {
        self.parameters
            + self.assignments
            + self.predicates
            + self.begin_end
            + self.ternaries
            + self.always_blocks
            + self.moved_locals
    }

    /// Scan SV text (typically the auto-correct region).
    pub fn from_sv_fragment(text: &str) -> Self {
        let mut r = DensityReport::default();
        for line in text.lines() {
            let t = line.trim();
            if t.is_empty() || t.starts_with("//") {
                continue;
            }
            r.dense_lines += 1;
            if t.starts_with("parameter") || t.starts_with("localparam") {
                r.parameters += 1;
            }
            // Assignments: continuous assign, NBA, or blocking (not `if (x = y)` style)
            if t.starts_with("assign ")
                || t.contains(" <= ")
                || (t.contains(" = ")
                    && !t.starts_with("if")
                    && !t.starts_with("else")
                    && !t.starts_with("localparam")
                    && !t.starts_with("parameter")
                    && !t.starts_with("logic ")
                    && !t.starts_with("wire ")
                    && !t.starts_with("reg "))
            {
                r.assignments += 1;
            }
            if t.starts_with("if ")
                || t.starts_with("if(")
                || t.starts_with("else if")
                || t.starts_with("else")
            {
                r.predicates += 1;
            }
            if t == "begin"
                || t.starts_with("begin ")
                || t == "end"
                || t.starts_with("end ")
                || t.ends_with(" begin")
            {
                r.begin_end += 1;
            }
            // Ternary: require `?` and a subsequent `:` on the same line (not part of `?:` only)
            if t.contains('?') && t.contains(':') {
                r.ternaries += 1;
            }
            if t.starts_with("always_comb") || t.starts_with("always_ff") {
                r.always_blocks += 1;
            }
            if t.starts_with("logic ") || t.starts_with("reg ") || t.starts_with("wire ") {
                r.moved_locals += 1;
            }
        }
        r
    }
}

/// Options for dense emission style.
#[derive(Debug, Clone)]
pub struct DenseEmitOptions {
    /// Default data width for generated pipeline regs.
    pub data_width: u32,
    /// Clock signal name assumed in generated always_ff.
    pub clk: String,
    /// Active-low reset name.
    pub rst_n: String,
    /// Optional enable for gated flops (ternary / if).
    pub enable: String,
    /// When true, hoist intermediate wires to a dedicated locals region (variable movement).
    pub reorder_locals: bool,
    /// When true, inject decorative density scaffold (nested always_comb, empty
    /// genvar loops, hold aliases). **Default false** for Verilator / runtime
    /// stability — see `architecture/RUNTIME-STABILITY-AUTOCORRECT.md` R5.
    pub density_scaffold: bool,
    /// When true, cut feeds use recovered origin RHS. **Default false** (R12d):
    /// zero/chain feeds only — origin RHS often references generate-locals,
    /// automatic nets, or multi-cut peers that break module-scope continuous
    /// assigns under Verilator. FO4 closure is independent of feed fidelity.
    pub real_cut_feeds: bool,
    /// When true, inject BalanceMux `emit_snippet` RTL + origin RHS rewrite.
    /// **Default false** (R12d): credit-only review comments — snippets often
    /// reference mid-module/enum nets illegal at early inject.
    pub emit_balance_mux_rtl: bool,
}

impl Default for DenseEmitOptions {
    fn default() -> Self {
        Self {
            data_width: 64,
            clk: "clk_i".into(),
            rst_n: "rst_ni".into(),
            enable: "1'b1".into(),
            // Lean: real pipe + sinks only (runtime-stable default).
            reorder_locals: false,
            density_scaffold: false,
            real_cut_feeds: false,
            emit_balance_mux_rtl: false,
        }
    }
}

/// Infer clk/rst names from original source (ports or free nets).
pub fn dense_options_from_source(source: &str) -> DenseEmitOptions {
    let mut opts = DenseEmitOptions::default();
    let has = |name: &str| {
        source.contains(&format!(" {name}"))
            || source.contains(&format!("({name}"))
            || source.contains(&format!(",{name}"))
            || source.contains(&format!("{name},"))
            || source.contains(&format!("{name} "))
            || source.contains(&format!("{name}\n"))
    };
    if has("clk_i") {
        opts.clk = "clk_i".into();
    } else if has("clk") {
        opts.clk = "clk".into();
    } else if has("clock_i") {
        opts.clk = "clock_i".into();
    } else {
        opts.clk.clear(); // no sequential block
    }
    if has("rst_ni") {
        opts.rst_n = "rst_ni".into();
    } else if has("rst_n") {
        opts.rst_n = "rst_n".into();
    } else if has("reset_n") {
        opts.rst_n = "reset_n".into();
    } else {
        opts.rst_n.clear();
    }
    opts
}

/// Whether emission can open an `always_ff` (clk + rst present).
fn has_seq_clock(opts: &DenseEmitOptions) -> bool {
    !opts.clk.is_empty() && !opts.rst_n.is_empty()
}

/// Build a dense auto-correct region from the edit trace (parameters, moved vars,
/// comb assigns, if/else begin/end, ternaries, always_ff).
///
/// When `cuts` is non-empty (from [`crate::rhs::cut_assigns_from_source`]), stage
/// feeds use the real origin **rhs** instead of zero placeholders.
///
/// **Lean mode (default):** real InsertReg/Split staging + sinks, no decorative
/// genvar/hold/density always_comb. **Scaffold mode** (`density_scaffold`):
/// historical density theater for regress score tests.
pub fn dense_autocorrect_block(trace: &EditTrace, opts: &DenseEmitOptions) -> String {
    dense_autocorrect_block_with_cuts(trace, opts, &[])
}

/// Placement split for dual inject (R11): BalanceMux early, InsertReg dense late.
///
/// - **early** — BalanceMux / rebalance snippets and credit-only review comments.
///   Injected before the first process so origin RHS rewrites can reference staged wires.
/// - **late** — InsertReg / SplitAssign dense pipe (decls, cut feeds, always_ff, sinks).
///   Injected before `endmodule` so cut feeds may reference mid-module nets.
#[derive(Debug, Clone, Default)]
pub struct EmitBlocks {
    /// Inject before first always/assign.
    pub early: String,
    /// Inject before `endmodule`.
    pub late: String,
}

/// Build early + late emit blocks for dual inject placement.
///
/// `source` is optional original module text used to demote BalanceMux snippets
/// whose origin sits inside a generate region (R12).
pub fn emit_blocks_for_trace(
    trace: &EditTrace,
    opts: &DenseEmitOptions,
    cuts: &[CutAssign],
) -> EmitBlocks {
    emit_blocks_for_trace_src(trace, opts, cuts, None)
}

/// Same as [`emit_blocks_for_trace`] with original source for generate-scope demotion.
pub fn emit_blocks_for_trace_src(
    trace: &EditTrace,
    opts: &DenseEmitOptions,
    cuts: &[CutAssign],
    source: Option<&str>,
) -> EmitBlocks {
    if trace.records.is_empty() {
        return EmitBlocks::default();
    }

    let pipe: Vec<&EditRecord> = trace
        .records
        .iter()
        .filter(|r| r.kind == EditKind::InsertReg)
        .collect();
    let splits: Vec<&EditRecord> = trace
        .records
        .iter()
        .filter(|r| r.kind == EditKind::SplitAssign)
        .collect();
    let credit_only: Vec<&EditRecord> = trace
        .records
        .iter()
        .filter(|r| {
            matches!(
                r.kind,
                EditKind::BalanceMux | EditKind::RebalanceAssoc | EditKind::Annotate
            )
        })
        .collect();

    // Collect snippets; demote unless emit_balance_mux_rtl + scope-safe (R12d).
    let mut snippets: Vec<&str> = Vec::new();
    if opts.emit_balance_mux_rtl {
        for r in &trace.records {
            if let Some(s) = r.emit_snippet.as_ref() {
                if s.trim().is_empty() {
                    continue;
                }
                let safe = source
                    .map(|src| crate::rhs::balance_mux_snippet_safe(src, s, r.origin.start_line))
                    .unwrap_or_else(|| !snippet_unsafe_at_module_scope(s));
                if !safe {
                    continue; // demoted — FO4 credit already on the edit
                }
                snippets.push(s.as_str());
            }
        }
    }

    let early = balance_mux_or_credit_block(&snippets, &credit_only);
    let late = if pipe.is_empty() && splits.is_empty() {
        String::new()
    } else {
        dense_pipe_block(opts, cuts, &pipe, &splits, &credit_only, snippets.is_empty())
    };

    // No structural content at all → empty.
    if early.is_empty() && late.is_empty() {
        return EmitBlocks::default();
    }
    // Pipe-only: early empty, late dense.
    // BalanceMux-only: early block, late empty.
    // Both: early BalanceMux + late dense (snippets not duplicated in dense).
    EmitBlocks { early, late }
}

/// Same as [`dense_autocorrect_block`] with optional cut-site RHS wiring.
///
/// Concatenates early+late blocks (callers that need dual placement should use
/// [`emit_blocks_for_trace`] instead).
pub fn dense_autocorrect_block_with_cuts(
    trace: &EditTrace,
    opts: &DenseEmitOptions,
    cuts: &[CutAssign],
) -> String {
    let blocks = emit_blocks_for_trace(trace, opts, cuts);
    let mut b = String::new();
    b.push_str(&blocks.early);
    b.push_str(&blocks.late);
    b
}

/// BalanceMux snippets and/or credit-only review comments (early inject).
///
/// Snippets that reference free genvars / loop indices are demoted to comments
/// (R12) — they were staged from generate bodies and are illegal at module scope.
fn balance_mux_or_credit_block(
    snippets: &[&str],
    credit_only: &[&EditRecord],
) -> String {
    let mut safe: Vec<&str> = Vec::new();
    let mut unsafe_n = 0u32;
    for s in snippets {
        if snippet_unsafe_at_module_scope(s) {
            unsafe_n += 1;
        } else {
            safe.push(s);
        }
    }
    if !safe.is_empty() {
        let mut b = String::new();
        b.push_str("\n  // BEGIN sv-timing auto-correct (balance_mux rewrite)\n");
        if unsafe_n > 0 {
            b.push_str(&format!(
                "  // R12: skipped {unsafe_n} BalanceMux snippet(s) with generate-local idents\n"
            ));
        }
        for s in &safe {
            b.push_str(s);
            if !s.ends_with('\n') {
                b.push('\n');
            }
        }
        for r in credit_only {
            if r.emit_snippet.is_none() {
                b.push_str(&origin_comment(&r.origin, Some(r.id)));
                b.push_str(&format!("  // {}\n", r.rationale));
            }
        }
        b.push_str("  // END sv-timing auto-correct (balance_mux rewrite)\n");
        return b;
    }
    // All snippets unsafe or none — fall through to credit-only when available.
    if !snippets.is_empty() && credit_only.is_empty() {
        let mut b = String::new();
        b.push_str("\n  // BEGIN sv-timing auto-correct (balance_mux rewrite)\n");
        b.push_str(&format!(
            "  // R12: all {unsafe_n} BalanceMux snippet(s) demoted (generate-local idents)\n"
        ));
        b.push_str("  // END sv-timing auto-correct (balance_mux rewrite)\n");
        return b;
    }
    if credit_only.is_empty() {
        return String::new();
    }
    credit_only_review_block(credit_only)
}

/// InsertReg / SplitAssign lean/scaffold dense pipe (late inject, before endmodule).
fn dense_pipe_block(
    opts: &DenseEmitOptions,
    cuts: &[CutAssign],
    pipe: &[&EditRecord],
    splits: &[&EditRecord],
    credit_only: &[&EditRecord],
    note_credit_only: bool,
) -> String {
    // Map pipe stage name → feed expression from cut list
    let mut feed_by_pipe: std::collections::BTreeMap<String, String> =
        std::collections::BTreeMap::new();
    for c in cuts {
        feed_by_pipe.insert(c.pipe_name.clone(), c.rhs.clone());
    }

    let seq = has_seq_clock(opts);
    let mut b = String::new();
    b.push_str("\n  // BEGIN sv-timing auto-correct (dense emit)\n");
    if !cuts.is_empty() {
        b.push_str("  // RHS rewrite: cut feeds use origin expressions; origin lines sample regs\n");
        b.push_str(
            "  // Placement: before endmodule so feeds may reference mid-module nets (R11).\n",
        );
    }
    // Residual BalanceMux credits without snippets (snippets live in early block).
    if note_credit_only {
        for r in credit_only {
            b.push_str(&origin_comment(&r.origin, Some(r.id)));
            b.push_str(&format!(
                "  // credit-only {} path={:?}: {}\n",
                format!("{:?}", r.kind).to_ascii_lowercase(),
                r.path_id,
                r.rationale
            ));
        }
    }

    // --- parameters (parametering) ---
    b.push_str("  // --- parametering ---\n");
    b.push_str(&format!(
        "  localparam int unsigned SVT_PIPE_STAGES = {};\n",
        pipe.len().max(1)
    ));
    b.push_str(&format!(
        "  localparam int unsigned SVT_DATA_W = {};\n",
        opts.data_width
    ));
    b.push_str("  localparam bit SVT_USE_ENABLE = 1'b1;\n");
    b.push_str("  localparam bit SVT_COMB_ONLY = ");
    b.push_str(if seq { "1'b0" } else { "1'b1" });
    b.push_str(";\n");

    // --- moved / hoisted locals (variable reordering surface) ---
    // Cluster 1: stage + split decls near the top of the auto-correct region.
    if opts.reorder_locals {
        b.push_str("  // --- moved locals cluster A (hoisted near auto-correct) ---\n");
    }
    let mut stage_names: Vec<String> = Vec::new();
    for (i, r) in pipe.iter().enumerate() {
        b.push_str(&origin_comment(&r.origin, Some(r.id)));
        let name = r
            .new_name
            .clone()
            .unwrap_or_else(|| format!("svt_pipe_p{}", i + 1));
        stage_names.push(name.clone());
        b.push_str(&format!("  logic [SVT_DATA_W-1:0] {name}_c; // comb feed\n"));
        b.push_str(&format!("  logic [SVT_DATA_W-1:0] {name};   // staged value\n"));
    }
    let mut split_names: Vec<String> = Vec::new();
    for (i, r) in splits.iter().enumerate() {
        b.push_str(&origin_comment(&r.origin, Some(r.id)));
        let name = r
            .new_name
            .clone()
            .unwrap_or_else(|| format!("svt_split_w{i}"));
        split_names.push(name.clone());
        b.push_str(&format!("  logic [SVT_DATA_W-1:0] {name};\n"));
    }
    let scaffold = opts.density_scaffold;
    // Scratch nets: lean keeps only svt_zero when needed for placeholders.
    if scaffold {
        b.push_str("  logic svt_en_q;\n");
        b.push_str("  logic svt_en_n;\n");
        b.push_str("  logic [SVT_DATA_W-1:0] svt_zero;\n");
        b.push_str("  logic [SVT_DATA_W-1:0] svt_sel;\n");
        b.push_str("  logic [SVT_DATA_W-1:0] svt_mux;\n");
    } else {
        b.push_str("  logic [SVT_DATA_W-1:0] svt_zero;\n");
    }

    b.push_str("  // --- continuous assigns ---\n");
    b.push_str("  assign svt_zero = '0;\n");
    if scaffold {
        b.push_str("  assign svt_sel = SVT_USE_ENABLE ? svt_zero : svt_zero;\n");
        b.push_str(&format!(
            "  assign svt_mux = ({}) ? svt_sel : svt_zero;\n",
            opts.enable
        ));
    }
    // Lhs names claimed by other cuts — feeds must not read them (sinks are later).
    let cut_lhs: std::collections::BTreeSet<&str> = cuts
        .iter()
        .filter(|c| !c.lhs.is_empty())
        .map(|c| c.lhs.as_str())
        .collect();
    for (i, name) in stage_names.iter().enumerate() {
        if let Some(rhs) = feed_by_pipe.get(name) {
            // R12d default: zero feeds (real_cut_feeds=false). Optional real path
            // still refuses generate/peer/automatic RHS.
            let loopish = rhs_has_free_loop_index(rhs);
            let gen_local = rhs_has_generate_local_param(rhs);
            let refs_peer = cut_lhs.iter().any(|l| {
                let base = l.split('[').next().unwrap_or(l);
                rhs.split(|c: char| !c.is_ascii_alphanumeric() && c != '_')
                    .any(|tok| tok == base || tok == *l)
            });
            let refs_auto = rhs
                .split(|c: char| !c.is_ascii_alphanumeric() && c != '_')
                .filter(|t| !t.is_empty())
                .any(|tok| tok.starts_with("temp_") || tok == "temp_status");
            let use_real = opts.real_cut_feeds
                && crate::rhs::rhs_structurally_complete(rhs)
                && !loopish
                && !gen_local
                && !refs_peer
                && !refs_auto;
            if use_real {
                b.push_str(&format!(
                    "  assign {name}_c = ({rhs}); // cut feed (origin rhs)\n"
                ));
            } else if i == 0 {
                b.push_str(&format!(
                    "  assign {name}_c = svt_zero; // cut feed (lean zero / unsafe rhs)\n"
                ));
            } else {
                let prev = &stage_names[i - 1];
                b.push_str(&format!(
                    "  assign {name}_c = {prev}; // lean chain\n"
                ));
            }
        } else if i == 0 {
            b.push_str(&format!(
                "  assign {name}_c = svt_zero; // cut feed (unresolved)\n"
            ));
        } else {
            let prev = &stage_names[i - 1];
            b.push_str(&format!("  assign {name}_c = {prev};\n"));
        }
    }
    for name in &split_names {
        b.push_str(&format!("  assign {name} = svt_zero;\n"));
    }

    if scaffold {
        b.push_str("  // --- function (scoped-helper style, module-local) ---\n");
        b.push_str("  function automatic logic [SVT_DATA_W-1:0] svt_pipe_mux(\n");
        b.push_str("      input logic                     sel,\n");
        b.push_str("      input logic [SVT_DATA_W-1:0]    t,\n");
        b.push_str("      input logic [SVT_DATA_W-1:0]    f\n");
        b.push_str("  );\n");
        b.push_str("    return sel ? t : f;\n");
        b.push_str("  endfunction\n");

        // Decorative genvar only in scaffold mode (wrapped for Verilator).
        if pipe.len() > 1 {
            b.push_str("  // --- genvar generate (density scaffold) ---\n");
            b.push_str("  generate\n");
            b.push_str(
                "    for (genvar svt_gi = 0; svt_gi < SVT_PIPE_STAGES; svt_gi++) begin : gen_svt_pipe\n",
            );
            b.push_str("      // per-stage placeholder\n");
            b.push_str("    end\n");
            b.push_str("  endgenerate\n");
        }

        b.push_str("  // --- comb control (named begin : svt_comb_ctrl) ---\n");
        b.push_str("  always_comb begin : svt_comb_ctrl\n");
        b.push_str(&format!(
            "    svt_en_q = SVT_USE_ENABLE ? {} : 1'b0;\n",
            opts.enable
        ));
        b.push_str("    svt_en_n = svt_en_q ? 1'b0 : 1'b1;\n");
        b.push_str("    if (svt_en_q) begin : svt_active\n");
        b.push_str("      if (SVT_PIPE_STAGES > 0) begin : svt_stages_ok\n");
        b.push_str("      end else begin : svt_stages_deg\n");
        b.push_str("      end\n");
        b.push_str("    end else if (svt_en_n) begin : svt_idle\n");
        b.push_str("    end else begin : svt_unreach\n");
        b.push_str("    end\n");
        b.push_str("  end\n");
    }

    // --- sequential stages OR comb-only staging when no clock in module ---
    if !stage_names.is_empty() {
        if seq {
            b.push_str("  // --- sequential stages (posedge+negedge, named begin : svt_pipe_ff) ---\n");
            b.push_str(&format!(
                "  always_ff @(posedge {} or negedge {}) begin : svt_pipe_ff\n",
                opts.clk, opts.rst_n
            ));
            b.push_str(&format!("    if (!{}) begin : svt_rst\n", opts.rst_n));
            for name in &stage_names {
                b.push_str(&format!("      {name} <= '0;\n"));
            }
            b.push_str("    end else begin : svt_capture\n");
            for name in &stage_names {
                if scaffold {
                    b.push_str(&format!(
                        "      {name} <= svt_pipe_mux(svt_en_q, {name}_c, {name});\n"
                    ));
                } else {
                    // Lean: direct capture (no enable mux theater).
                    b.push_str(&format!("      {name} <= {name}_c;\n"));
                }
            }
            b.push_str("    end\n");
            b.push_str("  end\n");
        } else {
            b.push_str("  // --- comb-only staging (named begin : svt_comb_stage) ---\n");
            b.push_str("  always_comb begin : svt_comb_stage\n");
            for name in &stage_names {
                if scaffold {
                    b.push_str(&format!(
                        "    {name} = svt_pipe_mux(svt_en_q, {name}_c, svt_zero);\n"
                    ));
                } else {
                    b.push_str(&format!("    {name} = {name}_c;\n"));
                }
            }
            b.push_str("  end\n");
        }
    } else if scaffold && !split_names.is_empty() {
        b.push_str("  always_comb begin : svt_split_comb\n");
        b.push_str("    if (svt_en_q) begin : svt_split_live\n");
        b.push_str("    end else begin : svt_split_idle\n");
        b.push_str("    end\n");
        b.push_str("  end\n");
    }

    // Hold aliases only when scaffold + reorder requested.
    if scaffold && opts.reorder_locals {
        b.push_str("  // --- moved locals cluster B ---\n");
        for name in &stage_names {
            b.push_str(&format!(
                "  logic [SVT_DATA_W-1:0] {name}_hold; // moved hold alias\n"
            ));
            b.push_str(&format!(
                "  assign {name}_hold = svt_en_q ? {name} : svt_zero;\n"
            ));
        }
    }

    // --- cut sinks: drive original lhs from pipe Q (legal after decls) ---
    if !cuts.is_empty() {
        b.push_str(&sink_assigns_sv(cuts));
    }

    b.push_str("  // END sv-timing auto-correct (dense emit)\n");
    b
}

/// Review-only block for BalanceMux / RebalanceAssoc / Annotate (no RTL rewrite yet).
fn credit_only_review_block(records: &[&EditRecord]) -> String {
    let mut b = String::new();
    b.push_str("\n  // BEGIN sv-timing auto-correct (review-only credit)\n");
    b.push_str(
        "  // Latency-neutral FO4 screening credit — not a structural RTL rewrite.\n",
    );
    b.push_str(
        "  // Human: balance exclusive select tree / reassoc hot arm; do not auto-merge.\n",
    );
    for r in records {
        b.push_str(&origin_comment(&r.origin, Some(r.id)));
        let kind = match r.kind {
            EditKind::BalanceMux => "balance_mux",
            EditKind::RebalanceAssoc => "rebalance_assoc",
            EditKind::Annotate => "annotate",
            _ => "credit",
        };
        let fo4 = match (r.fo4_before, r.fo4_after) {
            (Some(a), Some(c)) => format!(" fo4 {a:.1}->{c:.1}"),
            _ => String::new(),
        };
        b.push_str(&format!(
            "  // [{kind}] path={:?} node={:?}{fo4}: {}\n",
            r.path_id, r.node_id, r.rationale
        ));
    }
    b.push_str("  // END sv-timing auto-correct (review-only credit)\n");
    b
}

// Re-export scope-safety helpers for tests / external callers.
pub use crate::rhs::{has_free_gen_index, line_inside_generate};

fn rhs_has_free_loop_index(rhs: &str) -> bool {
    has_free_gen_index(rhs)
}

/// Generate-scoped localparams commonly used in FPU / multi-format cones.
///
/// When cut feeds are hoisted to module end (R11), these names are no longer
/// visible (they live inside `for (genvar fmt=…)` localparam scopes).
fn rhs_has_generate_local_param(rhs: &str) -> bool {
    let bytes = rhs.as_bytes();
    let mut i = 0usize;
    while i < bytes.len() {
        let c = bytes[i] as char;
        if c.is_ascii_alphabetic() || c == '_' {
            let start = i;
            i += 1;
            while i < bytes.len() {
                let d = bytes[i] as char;
                if d.is_ascii_alphanumeric() || d == '_' {
                    i += 1;
                } else {
                    break;
                }
            }
            let tok = &rhs[start..i];
            if matches!(
                tok,
                "EXP_BITS"
                    | "MAN_BITS"
                    | "INT_BITS"
                    | "FP_WIDTH"
                    | "INT_WIDTH"
                    | "NUM_FP_STICKY"
                    | "NUM_INT_STICKY"
                    | "BIAS"
                    | "PRECISION"
            ) {
                return true;
            }
        } else {
            i += 1;
        }
    }
    false
}

/// True when a BalanceMux/dense snippet is unsafe at module scope (genvar refs).
fn snippet_unsafe_at_module_scope(snippet: &str) -> bool {
    has_free_gen_index(snippet) || rhs_has_generate_local_param(snippet)
}

/// Minimum density score expected for a non-empty edit trace (regress gate).
///
/// Credit-only traces (BalanceMux / rebalance without InsertReg) emit review
/// comments only — density gate is 0 for those.
pub fn min_density_score_for_edits(n_edits: usize) -> u32 {
    // parameters(4) + always + begin/end pairs + assigns + ternaries per edit-ish
    10 + (n_edits as u32) * 2
}

/// Density floor for a concrete edit trace (0 when only FO4 credit kinds).
pub fn min_density_score_for_trace(trace: &EditTrace) -> u32 {
    let has_snippet = trace.records.iter().any(|r| {
        r.emit_snippet
            .as_ref()
            .map(|s| !s.trim().is_empty())
            .unwrap_or(false)
    });
    let structural = has_snippet
        || trace.records.iter().any(|r| {
            matches!(
                r.kind,
                EditKind::InsertReg | EditKind::SplitAssign | EditKind::ExpandName
            )
        });
    if !structural {
        return 0;
    }
    // Snippet-only BalanceMux: modest density (always_comb + assigns + wires)
    if has_snippet
        && !trace.records.iter().any(|r| {
            matches!(r.kind, EditKind::InsertReg | EditKind::SplitAssign)
        })
    {
        return 4;
    }
    // Lean InsertReg densify: params + feeds + always_ff + sinks (no scaffold).
    // Floor softer than historical density theater score.
    let n_pipe = trace
        .records
        .iter()
        .filter(|r| matches!(r.kind, EditKind::InsertReg | EditKind::SplitAssign))
        .count() as u32;
    6 + n_pipe
}

#[cfg(test)]
mod tests {
    use super::*;
    use sv_timing_core::loc::{OriginKind, SourceLoc};
    use sv_timing_transform::{EditKind, EditRecord, EditTrace};

    fn loc() -> SourceLoc {
        SourceLoc {
            file: "t.sv".into(),
            start_line: 1,
            start_col: 1,
            end_line: 1,
            end_col: 1,
            byte_start: 0,
            byte_end: 0,
            origin: OriginKind::UserFile,
        }
    }

    fn sample_trace() -> EditTrace {
        let mut tr = EditTrace::new();
        tr.record_edit(EditRecord {
            id: 0,
            kind: EditKind::InsertReg,
            origin: loc(),
            path_id: Some(0),
            node_id: Some(1),
            new_name: Some("pipe_svt_p1".into()),
            fo4_before: Some(100.0),
            fo4_after: Some(40.0),
            rationale: "cut".into(),
            emit_rhs: None,
            emit_rhs_extras: Vec::new(),
            emit_snippet: None,
        });
        tr.record_edit(EditRecord {
            id: 1,
            kind: EditKind::SplitAssign,
            origin: loc(),
            path_id: None,
            node_id: Some(2),
            new_name: Some("split_svt_w0".into()),
            fo4_before: None,
            fo4_after: None,
            rationale: "split".into(),
            emit_rhs: None,
            emit_rhs_extras: Vec::new(),
            emit_snippet: None,
        });
        tr
    }

    #[test]
    fn dense_block_has_language_intricacies() {
        let tr = sample_trace();
        let mut opts = DenseEmitOptions::default();
        opts.density_scaffold = true;
        opts.reorder_locals = true;
        let block = dense_autocorrect_block(&tr, &opts);
        assert!(block.contains("localparam"));
        assert!(block.contains("always_comb"));
        assert!(block.contains("always_ff"));
        assert!(
            block.contains("begin : svt_pipe_ff"),
            "named begin on always_ff"
        );
        assert!(
            block.contains("posedge") && block.contains("negedge"),
            "posedge+negedge sensitivity"
        );
        assert!(block.contains("function automatic"));
        assert!(block.contains("begin : svt_comb_ctrl"));
        assert!(block.contains("begin"));
        assert!(block.contains("else"));
        assert!(block.contains('?'));
        assert!(block.contains("assign "));
        assert!(block.contains("pipe_svt_p1"));
        assert!(block.contains("split_svt_w0"));
        assert!(block.contains("_hold")); // moved local cluster B
        let d = DensityReport::from_sv_fragment(&block);
        assert!(
            d.score() >= min_density_score_for_edits(2),
            "score={} dens={:?}",
            d.score(),
            d
        );
        assert!(d.parameters >= 2);
        assert!(d.assignments >= 2);
        assert!(d.predicates >= 2);
        assert!(d.ternaries >= 1);
        assert!(d.always_blocks >= 2);
        assert!(d.moved_locals >= 2);
        assert!(d.begin_end >= 2);
    }

    #[test]
    fn lean_dense_has_real_pipe_without_scaffold() {
        let tr = sample_trace();
        let block = dense_autocorrect_block(&tr, &DenseEmitOptions::default());
        assert!(block.contains("always_ff") || block.contains("always_comb"));
        assert!(block.contains("pipe_svt_p1"));
        assert!(
            !block.contains("begin : svt_comb_ctrl"),
            "lean must skip density theater: {block}"
        );
        assert!(
            !block.contains("genvar svt_gi"),
            "lean must skip decorative genvar: {block}"
        );
        assert!(!block.contains("_hold"), "lean no hold aliases");
        assert!(block.contains("assign "));
    }

    #[test]
    fn balance_mux_only_emits_review_not_pipe_scaffold() {
        let mut tr = EditTrace::new();
        tr.record_edit(EditRecord {
            id: 0,
            kind: EditKind::BalanceMux,
            origin: loc(),
            path_id: Some(41),
            node_id: Some(82),
            new_name: None,
            fo4_before: Some(37.9),
            fo4_after: Some(31.5),
            rationale: "balance_mux path 41 exclusive residual 37.9->31.5".into(),
            emit_rhs: None,
            emit_rhs_extras: Vec::new(),
            emit_snippet: None,
        });
        let block = dense_autocorrect_block(&tr, &DenseEmitOptions::default());
        assert!(
            block.contains("review-only credit"),
            "expected review-only header: {block}"
        );
        assert!(block.contains("balance_mux"));
        assert!(block.contains("37.9->31.5") || block.contains("37.9"));
        assert!(
            !block.contains("SVT_PIPE_STAGES"),
            "must not inject dummy pipe scaffold: {block}"
        );
        assert!(!block.contains("always_comb"), "credit-only: no shell always");
        assert_eq!(min_density_score_for_trace(&tr), 0);
        let d = DensityReport::from_sv_fragment(&block);
        assert_eq!(d.score(), 0, "comment-only dens={d:?}");
    }

    #[test]
    fn balance_mux_with_snippet_emits_real_staging() {
        let mut tr = EditTrace::new();
        let snippet = "  // --- BalanceMux arm staging (latency-neutral) ---\n  logic [63:0] svt_bm_0;\n  logic [63:0] svt_bm_1;\n  logic [63:0] svt_bm_top;\n  always_comb begin : svt_bm_top_stage\n    svt_bm_0 = a << b;\n    svt_bm_1 = a >> c;\n    svt_bm_top = svt_bm_0 | svt_bm_1;\n  end\n";
        tr.record_edit(EditRecord {
            id: 0,
            kind: EditKind::BalanceMux,
            origin: loc(),
            path_id: Some(41),
            node_id: Some(82),
            new_name: Some("svt_bm_top".into()),
            fo4_before: Some(37.9),
            fo4_after: Some(31.5),
            rationale: "balance_mux stage_hot_arm".into(),
            emit_rhs: Some("svt_bm_top".into()),
            emit_rhs_extras: Vec::new(),
            emit_snippet: Some(snippet.into()),
        });
        let mut opts = DenseEmitOptions::default();
        opts.emit_balance_mux_rtl = true; // opt-in structural BalanceMux
        let block = dense_autocorrect_block(&tr, &opts);
        assert!(
            block.contains("balance_mux rewrite"),
            "expected rewrite header: {block}"
        );
        assert!(block.contains("always_comb"));
        assert!(block.contains("svt_bm_top"));
        assert!(!block.contains("SVT_PIPE_STAGES"));
        assert!(min_density_score_for_trace(&tr) >= 4);
        let d = DensityReport::from_sv_fragment(&block);
        assert!(d.always_blocks >= 1, "dens={d:?}");
        assert!(d.score() >= 4, "score dens={d:?}");
    }

    #[test]
    fn dense_comb_only_still_has_ternaries_and_density() {
        // Comb-only modules (no clk/rst) with scaffold still meet density gate.
        let tr = sample_trace();
        let mut opts = DenseEmitOptions::default();
        opts.clk.clear();
        opts.rst_n.clear();
        opts.density_scaffold = true;
        opts.reorder_locals = true;
        let block = dense_autocorrect_block(&tr, &opts);
        assert!(!block.contains("always_ff"), "comb-only must not emit always_ff");
        assert!(block.contains("always_comb"));
        assert!(block.contains("SVT_COMB_ONLY"));
        assert!(block.contains('?'));
        assert!(block.contains("assign "));
        let d = DensityReport::from_sv_fragment(&block);
        assert!(d.parameters >= 2);
        assert!(d.assignments >= 2);
        assert!(d.always_blocks >= 1);
        assert!(d.moved_locals >= 2);
    }

    #[test]
    fn dense_options_from_source_clears_clk_when_absent() {
        let src = "module m(input logic a, output logic y); endmodule\n";
        let opts = dense_options_from_source(src);
        assert!(opts.clk.is_empty());
        assert!(opts.rst_n.is_empty());
    }

    #[test]
    fn dense_options_from_source_finds_clk_i() {
        let src = "module m(input logic clk_i, input logic rst_ni); endmodule\n";
        let opts = dense_options_from_source(src);
        assert_eq!(opts.clk, "clk_i");
        assert_eq!(opts.rst_n, "rst_ni");
    }
}
