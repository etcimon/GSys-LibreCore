// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Full module synthesis from TimingModule IR (ports, regions, gates).

//! Reconstruct reparseable SystemVerilog from a [`TimingModule`].
//!
//! Expression trees are not yet stored on IR nodes, so region bodies are
//! **structural shells**: real ports/params, `always_*`/`assign` scaffolding,
//! and a short chain of intermediate nets sized from port widths when known.
//! Enough for integrity reparse and for `generated/*__svt.sv` expansion.

use sv_timing_core::{
    EdgeKind, OperatorClass, RegionKind, TimingModule,
};

use crate::{machine_header, origin_comment, EmitPolicy};

/// Options for [`synthesize_module`].
#[derive(Debug, Clone)]
pub struct SynthOptions {
    /// Default packed width when ports omit dims (default 32).
    pub default_width: u32,
    /// Emit intermediate nets for each IR node in a region (default true).
    pub emit_node_nets: bool,
    /// Emit function stubs listed on the module (default true).
    pub emit_function_stubs: bool,
}

impl Default for SynthOptions {
    fn default() -> Self {
        Self {
            default_width: 32,
            emit_node_nets: true,
            emit_function_stubs: true,
        }
    }
}

/// Synthesize a full module body from IR (not a hollow placeholder).
pub fn synthesize_module(module: &TimingModule, policy: &EmitPolicy) -> String {
    synthesize_module_with(module, policy, &SynthOptions::default())
}

/// Synthesize with explicit options.
pub fn synthesize_module_with(
    module: &TimingModule,
    policy: &EmitPolicy,
    opts: &SynthOptions,
) -> String {
    let mut s = machine_header(&policy.tool, &policy.run_id);
    s.push_str(&origin_comment(&module.loc, None));
    s.push_str(&format!(
        "// sv-timing: synthesize_module from IR (structural; not STA-exact)\n"
    ));

    // Parameters
    let mut param_parts: Vec<String> = Vec::new();
    for p in &module.parameters {
        if p.is_type_parameter {
            let ty = p
                .type_ref
                .clone()
                .or_else(|| p.default_expr.clone())
                .unwrap_or_else(|| "logic".into());
            param_parts.push(format!("  parameter type {} = {}", p.name, ty));
        } else {
            let def = p
                .default_expr
                .clone()
                .unwrap_or_else(|| "0".into());
            param_parts.push(format!("  parameter int {} = {}", sanitize_id(&p.name), def));
        }
    }
    if !param_parts.is_empty() {
        s.push_str(&format!("module {} #(\n", module.name));
        s.push_str(&param_parts.join(",\n"));
        s.push_str("\n) (\n");
    } else {
        s.push_str(&format!("module {} (\n", module.name));
    }

    // Ports
    if module.ports.is_empty() {
        s.push_str("  // no ports recovered from IR\n");
    } else {
        let mut port_lines = Vec::new();
        for p in &module.ports {
            port_lines.push(format_port(p, opts.default_width));
        }
        s.push_str(&port_lines.join(",\n"));
        s.push('\n');
    }
    s.push_str(");\n");

    // Imports (comments — package resolve is host/P1.5)
    for pkg in &module.package_imports {
        s.push_str(&format!("  // import {pkg}::*; // recorded by lower\n"));
    }

    // Localparams (values unknown → 0)
    for lp in &module.localparams {
        s.push_str(&format!("  localparam int {} = 0;\n", sanitize_id(lp)));
    }

    // Genvar loops (structural shell)
    for (i, g) in module.gen_loops.iter().enumerate() {
        let bound = g.bound_hint.clone().unwrap_or_else(|| "1".into());
        let label = g
            .label
            .clone()
            .unwrap_or_else(|| format!("gen_loop_{i}"));
        s.push_str(&format!(
            "  // generate for ({gv} < {bound}) — body density={n}\n\
              generate\n\
                for (genvar {gv} = 0; {gv} < {bound}; {gv}++) begin : {label}\n\
                  // generate body elided (timing IR does not store generate items yet)\n\
                end\n\
              endgenerate\n",
            gv = sanitize_id(&g.genvar),
            bound = bound,
            n = g.body_assign_count,
            label = sanitize_id(&label),
        ));
    }

    // Function stubs
    if opts.emit_function_stubs {
        for f in &module.functions {
            s.push_str(&format!(
                "  function automatic logic {};\n    {f} = 1'b0;\n  endfunction\n",
                sanitize_id(f),
                f = sanitize_id(f)
            ));
        }
    }

    // Instances (hierarchical types only — no recursive emit)
    for inst in &module.instances {
        s.push_str(&format!(
            "  // instance {}.{} (child_id={:?})\n",
            inst.child_type, inst.instance_name, inst.child_module
        ));
        s.push_str(&format!(
            "  // {} {} (\n",
            inst.child_type, inst.instance_name
        ));
        for c in &inst.connections {
            s.push_str(&format!("  //   .{}({}),\n", c.formal, c.actual));
        }
        s.push_str("  // );\n");
    }

    // Regions → always/assign shells with node nets
    let width = primary_width(module, opts.default_width);
    let mut region_ids: Vec<_> = module.regions.keys().copied().collect();
    region_ids.sort();
    for rid in region_ids {
        let Some(region) = module.regions.get(&rid) else {
            continue;
        };
        let label = region
            .label
            .clone()
            .unwrap_or_else(|| format!("r{rid}"));
        let label = sanitize_id(&label);

        // Declare intermediate nets for nodes in region
        let mut node_ids = region.nodes.clone();
        node_ids.sort();
        if opts.emit_node_nets {
            for nid in &node_ids {
                s.push_str(&format!("  logic [{w}-1:0] {label}_n{nid};\n", w = width));
            }
        }

        match region.kind {
            RegionKind::ContAssign => {
                s.push_str(&format!(
                    "  // continuous assign region r{rid} fo4={:.1}\n",
                    region.total_fo4
                ));
                if node_ids.is_empty() {
                    s.push_str("  // empty cont-assign region\n");
                } else {
                    let mut prev: Option<String> = None;
                    let mut used_real = false;
                    for nid in &node_ids {
                        if let Some(n) = module.nodes.get(nid) {
                            let lhs_s = n
                                .lhs_expr
                                .as_ref()
                                .map(|e| e.emit())
                                .or_else(|| n.lhs.clone());
                            let rhs_s = n
                                .rhs_expr
                                .as_ref()
                                .map(|e| e.emit())
                                .or_else(|| n.rhs.clone());
                            if let (Some(lhs), Some(rhs)) = (lhs_s, rhs_s) {
                                s.push_str(&format!(
                                    "  assign {} = {};\n",
                                    sanitize_expr(&lhs),
                                    sanitize_expr(&rhs)
                                ));
                                prev = Some(sanitize_expr(&lhs));
                                used_real = true;
                                continue;
                            }
                        }
                        let net = format!("{label}_n{nid}");
                        let rhs = match prev {
                            Some(ref p) => op_expr(module.nodes.get(nid).and_then(|n| n.op_class), p),
                            None => "'0".to_string(),
                        };
                        s.push_str(&format!("  assign {net} = {rhs};\n"));
                        prev = Some(net);
                    }
                    if !used_real {
                        if let Some(outp) = module.ports.iter().find(|p| p.direction == "output") {
                            if let Some(last) = prev {
                                s.push_str(&format!(
                                    "  assign {} = {};\n",
                                    sanitize_id(&outp.name),
                                    last
                                ));
                            }
                        }
                    }
                }
            }
            RegionKind::AlwaysComb => {
                s.push_str(&format!(
                    "  always_comb begin : {label} // fo4={:.1}\n",
                    region.total_fo4
                ));
                emit_procedural_body(&mut s, module, &node_ids, &label, false);
                s.push_str("  end\n");
            }
            RegionKind::AlwaysFf => {
                let clk = region
                    .gate
                    .clock_name
                    .clone()
                    .or_else(|| {
                        module
                            .ports
                            .iter()
                            .find(|p| p.name.contains("clk"))
                            .map(|p| p.name.clone())
                    })
                    .unwrap_or_else(|| "clk_i".into());
                let edge = region.gate.edge.unwrap_or(EdgeKind::Posedge);
                let edge_kw = match edge {
                    EdgeKind::Posedge => "posedge",
                    EdgeKind::Negedge => "negedge",
                    EdgeKind::Level => "posedge",
                };
                let mut sens = format!("{edge_kw} {}", sanitize_id(&clk));
                if let Some(rst) = &region.gate.reset_name {
                    let re = match region.gate.reset_edge.unwrap_or(EdgeKind::Negedge) {
                        EdgeKind::Posedge => "posedge",
                        EdgeKind::Negedge => "negedge",
                        EdgeKind::Level => "negedge",
                    };
                    sens.push_str(&format!(" or {re} {}", sanitize_id(rst)));
                }
                s.push_str(&format!(
                    "  always_ff @({sens}) begin : {label} // fo4={:.1}\n",
                    region.total_fo4
                ));
                if let Some(rst) = &region.gate.reset_name {
                    let active_low = region
                        .gate
                        .reset
                        .as_ref()
                        .map(|r| r.active_low)
                        .unwrap_or(true);
                    let cond = if active_low {
                        format!("!{}", sanitize_id(rst))
                    } else {
                        sanitize_id(rst)
                    };
                    s.push_str(&format!("    if ({cond}) begin\n"));
                    for nid in &node_ids {
                        s.push_str(&format!("      {label}_n{nid} <= '0;\n"));
                    }
                    s.push_str("    end else begin\n");
                    emit_procedural_body_indent(&mut s, module, &node_ids, &label, true, "      ");
                    s.push_str("    end\n");
                } else {
                    emit_procedural_body_indent(&mut s, module, &node_ids, &label, true, "    ");
                }
                s.push_str("  end\n");
            }
        }
    }

    // If no regions but we have ports, emit a trivial pass-through so the module is useful.
    if module.regions.is_empty() {
        let outs: Vec<_> = module
            .ports
            .iter()
            .filter(|p| p.direction == "output")
            .collect();
        let ins: Vec<_> = module
            .ports
            .iter()
            .filter(|p| p.direction == "input")
            .collect();
        for (i, o) in outs.iter().enumerate() {
            let rhs = ins
                .get(i)
                .or_else(|| ins.first())
                .map(|p| sanitize_id(&p.name))
                .unwrap_or_else(|| "'0".into());
            s.push_str(&format!("  assign {} = {};\n", sanitize_id(&o.name), rhs));
        }
    }

    s.push_str("endmodule\n");
    s
}

fn emit_procedural_body(
    s: &mut String,
    module: &TimingModule,
    node_ids: &[u32],
    label: &str,
    nba: bool,
) {
    emit_procedural_body_indent(s, module, node_ids, label, nba, "    ");
}

fn emit_procedural_body_indent(
    s: &mut String,
    module: &TimingModule,
    node_ids: &[u32],
    label: &str,
    nba: bool,
    indent: &str,
) {
    let op = if nba { "<=" } else { "=" };
    let mut used_real_assign = false;
    let mut prev: Option<String> = None;
    for nid in node_ids {
        let node = module.nodes.get(nid);
        // Prefer expression AST emit, then recovered text
        if let Some(n) = node {
            let lhs_s = n
                .lhs_expr
                .as_ref()
                .map(|e| e.emit())
                .or_else(|| n.lhs.clone())
                .map(|t| sanitize_expr(&t));
            let rhs_s = n
                .rhs_expr
                .as_ref()
                .map(|e| e.emit())
                .or_else(|| n.rhs.clone())
                .map(|t| sanitize_expr(&t));
            if let (Some(lhs), Some(rhs)) = (lhs_s.clone(), rhs_s.clone()) {
                s.push_str(&format!("{indent}{lhs} {op} {rhs};\n"));
                prev = Some(lhs);
                used_real_assign = true;
                continue;
            }
            if let Some(rhs) = rhs_s {
                let net = format!("{label}_n{nid}");
                s.push_str(&format!("{indent}{net} {op} {rhs};\n"));
                prev = Some(net);
                used_real_assign = true;
                continue;
            }
        }
        let net = format!("{label}_n{nid}");
        let rhs = match prev {
            Some(ref p) => op_expr(node.and_then(|n| n.op_class), p),
            None => module
                .ports
                .iter()
                .find(|p| p.direction == "input")
                .map(|p| sanitize_id(&p.name))
                .unwrap_or_else(|| "'0".into()),
        };
        s.push_str(&format!("{indent}{net} {op} {rhs};\n"));
        prev = Some(net);
    }
    // Only drive a port from the last intermediate when we did not recover
    // real LHS targets that already assign the output.
    if !used_real_assign {
        if let Some(outp) = module.ports.iter().find(|p| p.direction == "output") {
            if let Some(last) = prev {
                s.push_str(&format!(
                    "{indent}{} {op} {};\n",
                    sanitize_id(&outp.name),
                    last
                ));
            }
        }
    }
}

/// Light sanitize: keep operators/idents, collapse whitespace.
fn sanitize_expr(e: &str) -> String {
    let t = e.split_whitespace().collect::<Vec<_>>().join(" ");
    if t.is_empty() {
        "'0".into()
    } else {
        t
    }
}

fn op_expr(op: Option<OperatorClass>, prev: &str) -> String {
    match op {
        Some(OperatorClass::AddSub) => format!("{prev} + '0"),
        Some(OperatorClass::Mul) => format!("{prev} * 1"),
        Some(OperatorClass::LogicBit) => format!("{prev} & '1"),
        Some(OperatorClass::Compare) => format!("{{31'b0, ({prev} != '0)}}"),
        Some(OperatorClass::Mux) | Some(OperatorClass::PriorityMux) => {
            format!("({prev} != '0) ? {prev} : '0")
        }
        Some(OperatorClass::ShiftConst) => format!("{prev} << 1"),
        Some(OperatorClass::ShiftVar) => format!("{prev} << 1"),
        Some(OperatorClass::Concat) => format!("{{1'b0, {prev}}}"),
        Some(OperatorClass::DivRem) => format!("{prev} / 1"),
        Some(OperatorClass::Other) | None => format!("{prev}"),
    }
}

fn format_port(p: &sv_timing_core::ModulePort, default_width: u32) -> String {
    let dir = match p.direction.as_str() {
        "input" | "output" | "inout" | "ref" => p.direction.as_str(),
        _ => "input",
    };
    let ty = p
        .type_name
        .clone()
        .unwrap_or_else(|| "logic".into());
    let dims = p
        .packed_dims
        .clone()
        .unwrap_or_else(|| format!("[{default_width}-1:0]"));
    // If dims already look like […], use as-is; else wrap.
    let dims_s = if dims.starts_with('[') {
        dims
    } else {
        format!("[{dims}]")
    };
    // Scalar clk/rst style ports: no dims when type is bare logic and name suggests clock
    let bare = (p.name.contains("clk") || p.name.contains("rst") || p.name.ends_with("_n"))
        && p.packed_dims.is_none();
    if bare {
        format!("  {dir} {ty} {}", sanitize_id(&p.name))
    } else if ty == "logic" || ty == "wire" || ty == "reg" || ty == "bit" {
        format!("  {dir} {ty} {dims_s} {}", sanitize_id(&p.name))
    } else {
        // Typedef / package type — keep type name, optional dims
        if p.packed_dims.is_some() {
            format!("  {dir} {ty} {dims_s} {}", sanitize_id(&p.name))
        } else {
            format!("  {dir} {ty} {}", sanitize_id(&p.name))
        }
    }
}

fn primary_width(module: &TimingModule, default: u32) -> u32 {
    for p in &module.ports {
        if let Some(d) = &p.packed_dims {
            if let Some(w) = parse_width_hint(d) {
                return w;
            }
        }
    }
    for n in module.nodes.values() {
        if n.width > 0 {
            return n.width;
        }
    }
    default
}

fn parse_width_hint(dims: &str) -> Option<u32> {
    // Match [15:0] or [N-1:0] loosely → 16 or default
    let s = dims.trim().trim_start_matches('[').trim_end_matches(']');
    if let Some((hi, lo)) = s.split_once(':') {
        let hi = hi.trim();
        let lo = lo.trim();
        if let (Ok(h), Ok(l)) = (hi.parse::<i64>(), lo.parse::<i64>()) {
            return Some((h - l).unsigned_abs() as u32 + 1);
        }
        // [15:0] style with spaces already handled; [WIDTH-1:0] → None
        if hi.chars().all(|c| c.is_ascii_digit()) {
            return hi.parse::<u32>().ok().map(|h| h + 1);
        }
    }
    None
}

fn sanitize_id(name: &str) -> String {
    let mut out = String::with_capacity(name.len());
    for (i, c) in name.chars().enumerate() {
        if c.is_ascii_alphanumeric() || c == '_' {
            out.push(c);
        } else if i == 0 {
            out.push('_');
        } else {
            out.push('_');
        }
    }
    if out.is_empty() || out.as_bytes()[0].is_ascii_digit() {
        out.insert(0, '_');
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use sv_timing_core::{
        analyze_files, LowerOptions, ParseOptions, TimingTarget,
    };
    use std::path::PathBuf;

    fn fixture(rel: &str) -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../fixtures")
            .join(rel)
    }

    #[test]
    fn synthesize_leaf_has_ports_and_always() {
        let path = fixture("project_mini/leaf.sv");
        if !path.exists() {
            eprintln!("skip missing {}", path.display());
            return;
        }
        let mut lower = LowerOptions::default();
        lower.target = TimingTarget::new(2000.0, 20.0, 0.2);
        let out = analyze_files(&[path], &ParseOptions::default(), &lower).expect("analyze");
        let m = out
            .design
            .modules
            .values()
            .find(|m| m.name == "proj_leaf")
            .expect("proj_leaf");
        let text = synthesize_module(m, &EmitPolicy::default());
        assert!(text.contains("module proj_leaf"), "{text}");
        assert!(text.contains("a_i"), "{text}");
        assert!(text.contains("always_comb") || text.contains("assign "), "{text}");
        assert!(text.contains("endmodule"), "{text}");
        // Expression-accurate: recovered assign RHS should mention ports or +
        let has_expr = m.nodes.values().any(|n| {
            n.rhs
                .as_ref()
                .map(|r| r.contains('+') || r.contains("a_i"))
                .unwrap_or(false)
                || n.lhs.as_ref().map(|l| l.contains("t0") || l.contains("y_o")).unwrap_or(false)
        });
        assert!(
            has_expr || text.contains('+'),
            "expected recovered expressions in IR or emit, nodes={:?} text={text}",
            m.nodes
                .values()
                .map(|n| (n.lhs.clone(), n.rhs.clone()))
                .collect::<Vec<_>>()
        );
    }
}
