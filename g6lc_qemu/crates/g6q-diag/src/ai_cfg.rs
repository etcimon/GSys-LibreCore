// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! AI-island configuration package (`g6lc_ai_island_cfg_pkg.sv`) reader.
//!
//! The package defines the cluster/queue/throughput parameters in the `ai_island_cfg_t` struct and
//! the capability-window layout.  This module extracts the latency-default SKU and the capability
//! offsets without hard-coding any of the values.

use g6q_core::model::AiIslandConfig;

/// Parse an AI-island configuration package and return the derived `AiIslandConfig`.
pub fn parse_ai_island_cfg_pkg(text: &str) -> Result<AiIslandConfig, String> {
    let cleaned = strip_sv_comments(text);

    // Find the latency default struct literal.
    let default = extract_struct_literal(&cleaned, "AiIslandLatencyDefault")
        .ok_or_else(|| "AiIslandLatencyDefault not found".to_string())?;

    let mut cfg = AiIslandConfig::default();
    for (field, raw) in split_member_list(&default) {
        if field == "QueueClusterMap" {
            cfg.queue_cluster_map = parse_array_literal(&raw).ok();
            continue;
        }
        let v = eval_field(&raw)?;
        match field.as_str() {
            "Clusters" => cfg.clusters = v as u32,
            "MacsPerCycle" => cfg.macs_per_cycle = v as u32,
            "ClockKhz" => cfg.clock_khz = v as u32,
            "SramBytes" => cfg.sram_bytes = v as u64,
            "AccTileM" => cfg.acc_tile_m = v as u32,
            "AccTileN" => cfg.acc_tile_n = v as u32,
            "AccTileK" => cfg.acc_tile_k = v as u32,
            "NocWidth" => cfg.noc_width = v as u32,
            "DramChannels" => cfg.dram_channels = v as u32,
            "DramGBps" => cfg.dram_gbps = v as u32,
            "Queues" => cfg.queues = v as u32,
            "QueueDepth" => cfg.queue_depth = v as u32,
            "QosClasses" => cfg.qos_classes = v as u32,
            "WorkQuantumK" => cfg.work_quantum_k = v as u32,
            _ => {}
        }
    }

    // Capability version.
    if let Some(v) = extract_localparam_scalar(&cleaned, "AiIslandCapVersion") {
        cfg.cap_version = v as u16;
    }

    // Capability window offsets, and the island MMIO placement when the design states it.
    //
    // The offsets live in this package, but the *placement* of each window is decided by
    // the island's address decode. A design that keeps the decode only in RTL leaves the
    // placement unresolved here: the reader will not parse an address decoder, and it will
    // not guess, because a guessed base puts the whole descriptor at the wrong address
    // while every individual field still looks plausible.
    let mut ai_cap_base: Option<u64> = None;
    let mut ai_desc_base: Option<u64> = None;
    for line in cleaned.split(';') {
        let line = line.trim();
        if let Some((name, value)) = parse_localparam_hex_scalar(line) {
            if let Some(short) = name.strip_prefix("CAP_OFF_") {
                cfg.cap_offsets.insert(short.to_lowercase(), value);
            }
            // The island's own measured PMU counters. These are the only quantities that can
            // contradict the modelled bound in `roofline`, so they are ingested the same way
            // and left empty -- never defaulted -- when the design publishes them only as
            // register-map comments (ask F9).
            if let Some(short) = name.strip_prefix("PMU_OFF_") {
                cfg.pmu_offsets.insert(short.to_lowercase(), value);
            }
            match name {
                "CAP_BASE" | "REG_OFF_CAP" => cfg.cap_base = Some(value),
                "DESC_BASE" | "REG_OFF_DESC" => cfg.desc_base = Some(value),
                "AI_CAP_BASE" => ai_cap_base = Some(value),
                "AI_DESC_BASE" => ai_desc_base = Some(value),
                _ => {}
            }
        }
    }
    // When the package publishes the absolute island and descriptor bases, convert to
    // island-relative offsets.  The capability window is at the island base, so its
    // offset is zero; the descriptor window is above it.
    if let (Some(cap), Some(desc)) = (ai_cap_base, ai_desc_base) {
        if desc > cap {
            cfg.cap_base = Some(0);
            cfg.desc_base = Some(desc - cap);
        }
    }

    // Queue-to-cluster map may be published as a top-level localparam array.
    if cfg.queue_cluster_map.is_none() {
        for stmt in cleaned.split(';') {
            let stmt = stmt.trim();
            if !stmt.contains("QueueClusterMap") && !stmt.contains("QUEUE_TO_CLUSTER") {
                continue;
            }
            if let Some(eq) = stmt.find('=') {
                let raw = &stmt[eq + 1..];
                if let Ok(m) = parse_array_literal(raw) {
                    cfg.queue_cluster_map = Some(m);
                    break;
                }
            }
        }
    }

    Ok(cfg)
}

/// Parse a SystemVerilog packed array literal like `'{0, 1, 2}`.
fn parse_array_literal(raw: &str) -> Result<Vec<u32>, String> {
    let s = raw.trim();
    let s = s.strip_prefix("'").unwrap_or(s);
    if !s.starts_with('{') {
        return Err("array literal does not start with {".to_string());
    }
    // Find matching closing brace.
    let mut depth = 0;
    let mut in_str = false;
    let mut end = None;
    for (i, c) in s.char_indices() {
        match c {
            '{' if !in_str => depth += 1,
            '}' if !in_str => {
                depth -= 1;
                if depth == 0 {
                    end = Some(i);
                    break;
                }
            }
            '"' => in_str = !in_str,
            _ => {}
        }
    }
    let end = end.ok_or("unterminated array literal")?;
    let inner = &s[1..end];
    let mut out = Vec::new();
    for item in split_top_level(inner, ',') {
        let item = item.trim();
        if item.is_empty() {
            continue;
        }
        out.push(parse_atom(item)? as u32);
    }
    Ok(out)
}

fn strip_sv_comments(text: &str) -> String {
    let mut out = String::new();
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '/' && chars.peek() == Some(&'/') {
            chars.next();
            while chars.next().is_some_and(|x| x != '\n') {}
            out.push('\n');
        } else if c == '/' && chars.peek() == Some(&'*') {
            chars.next();
            let mut prev = ' ';
            for x in chars.by_ref() {
                if prev == '*' && x == '/' {
                    break;
                }
                prev = x;
            }
        } else {
            out.push(c);
        }
    }
    out
}

fn extract_struct_literal(text: &str, name: &str) -> Option<String> {
    let needle = format!("localparam ai_island_cfg_t {name}");
    let start = text.find(&needle)?;
    let after_sig = text[start..].find('=')?;
    let body_start = start + after_sig + 1;
    // Skip whitespace and the optional leading quote of the '{...}' initializer.
    let mut it = text[body_start..].chars();
    for c in it.by_ref() {
        if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
            continue;
        }
        if c == '\'' {
            continue;
        }
        if c == '{' {
            break;
        }
        return None;
    }
    let mut depth = 1;
    let mut out = String::new();
    let mut in_str = false;
    for c in it {
        match c {
            '{' => {
                depth += 1;
                if depth == 1 {
                    continue;
                }
            }
            '}' => {
                depth -= 1;
                if depth == 0 {
                    break;
                }
            }
            '"' => in_str = !in_str,
            _ => {}
        }
        out.push(c);
    }
    Some(out)
}

fn split_member_list(body: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    for member in split_top_level(body, ',') {
        if let Some((name, raw)) = split_member(&member) {
            out.push((name, raw));
        }
    }
    out
}

fn split_member(member: &str) -> Option<(String, String)> {
    let b: Vec<char> = member.chars().collect();
    let mut depth = 0i32;
    for (i, c) in b.iter().enumerate() {
        match c {
            '{' | '(' | '[' => depth += 1,
            '}' | ')' | ']' => depth -= 1,
            ':' if depth == 0 => {
                let name = b[..i].iter().collect::<String>().trim().to_string();
                let raw = b[i + 1..].iter().collect::<String>().trim().to_string();
                if !name.is_empty() && !raw.is_empty() {
                    return Some((name, raw));
                }
                return None;
            }
            _ => {}
        }
    }
    None
}

fn split_top_level(s: &str, sep: char) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut depth = 0i32;
    for c in s.chars() {
        match c {
            '{' | '(' | '[' => {
                depth += 1;
                cur.push(c);
            }
            '}' | ')' | ']' => {
                depth -= 1;
                cur.push(c);
            }
            c if c == sep && depth == 0 => out.push(std::mem::take(&mut cur)),
            _ => cur.push(c),
        }
    }
    if !cur.trim().is_empty() {
        out.push(cur);
    }
    out
}

fn extract_localparam_scalar(text: &str, name: &str) -> Option<i64> {
    for stmt in text.split(';') {
        if let Some((n, v)) = parse_localparam(stmt.trim()) {
            if n == name {
                return Some(v);
            }
        }
    }
    None
}

fn parse_localparam(line: &str) -> Option<(&str, i64)> {
    let line = line.trim();
    let rest = line.strip_prefix("localparam")?;
    if !rest.starts_with(char::is_whitespace) {
        return None;
    }
    let (lhs, value) = split_top_level_assign(rest)?;
    let name = lhs
        .split(|c: char| !(c.is_alphanumeric() || c == '_'))
        .filter(|t| !t.is_empty())
        .next_back()?;
    eval_field(value).ok().map(|v| (name, v))
}

fn split_top_level_assign(s: &str) -> Option<(&str, &str)> {
    let b: Vec<char> = s.chars().collect();
    let mut depth = 0i32;
    for (i, c) in b.iter().enumerate() {
        match c {
            '{' | '(' | '[' => depth += 1,
            '}' | ')' | ']' => depth -= 1,
            '=' if depth == 0 => {
                let byte = s.char_indices().nth(i)?.0;
                return Some((&s[..byte], &s[byte + 1..]));
            }
            _ => {}
        }
    }
    None
}

fn parse_localparam_hex_scalar(line: &str) -> Option<(&str, u64)> {
    let line = line.trim();
    // Accept any `localparam logic [A:B] NAME = Wx'y...;` or `localparam logic [A:B] NAME = y;`.
    // Width and base prefix are not trusted for the numeric value: we strip them.
    let rest = line.strip_prefix("localparam logic [")?;
    let rest = rest.split_once("]")?.1.trim();
    let (name, value) = split_top_level_assign(rest)?;
    let name = name
        .split(|c: char| !(c.is_alphanumeric() || c == '_'))
        .filter(|t| !t.is_empty())
        .next_back()?;
    let value = value.trim().trim_end_matches(';');
    // Strip a width/base prefix like `64'h`, `16'd`, `32'h`, or a plain `0x` prefix.
    // Track which base was declared so a hex value composed only of digits is not
    // mistaken for decimal.
    let (base, value) = if let Some((_, v)) = value.split_once("'h") {
        (16, v)
    } else if let Some((_, v)) = value.split_once("'d") {
        (10, v)
    } else if let Some((_, v)) = value.split_once("'b") {
        (2, v)
    } else if let Some(v) = value
        .strip_prefix("0x")
        .or_else(|| value.strip_prefix("0X"))
    {
        (16, v)
    } else {
        (10, value)
    };
    let value = value.replace('_', "");
    u64::from_str_radix(&value, base).ok().map(|n| (name, n))
}

fn eval_field(raw: &str) -> Result<i64, String> {
    let s = raw.trim();
    let s = s
        .strip_prefix("unsigned'")
        .or_else(|| s.strip_prefix("int'"))
        .map_or(s, |inner| inner.trim().trim_start_matches('(').trim());
    let s = s.strip_suffix(")").map_or(s, |inner| inner.trim());
    eval_expr(s)
}

fn eval_expr(s: &str) -> Result<i64, String> {
    // Sum of products: supports "A * B + C" and "A * B * C".
    let mut total: i64 = 0;
    for term in split_top_level(s, '+') {
        let term = term.trim();
        if term.is_empty() {
            continue;
        }
        let mut prod: i64 = 1;
        for factor in split_top_level(term, '*') {
            let factor = factor.trim();
            if factor.is_empty() {
                return Err(format!("empty factor in expression: {s}"));
            }
            let v = parse_atom(factor)?;
            prod = prod.checked_mul(v).ok_or("integer overflow")?;
        }
        total = total.checked_add(prod).ok_or("integer overflow")?;
    }
    Ok(total)
}

fn parse_atom(s: &str) -> Result<i64, String> {
    let s = s.trim().replace('_', "");
    if let Some(rest) = s.strip_prefix("0x") {
        return i64::from_str_radix(rest, 16).map_err(|_| format!("bad hex integer: {s}"));
    }
    if let Some(rest) = s.strip_prefix("16'd") {
        return rest.parse().map_err(|_| format!("bad decimal: {s}"));
    }
    if let Some(rest) = s.strip_prefix("16'h") {
        return i64::from_str_radix(rest, 16).map_err(|_| format!("bad hex: {s}"));
    }
    s.parse().map_err(|_| format!("bad integer: {s}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_real_ai_island_cfg_package_if_present() {
        let path = std::path::Path::new(r"E:/cva6/corev_apu/include/g6lc_ai_island_cfg_pkg.sv");
        if !path.exists() {
            return;
        }
        let text = std::fs::read_to_string(path).unwrap();
        let cfg = parse_ai_island_cfg_pkg(&text).unwrap();
        assert!(cfg.queues > 0);
        assert!(cfg.queue_depth > 0);
        assert!(cfg.clusters > 0);
        assert!(cfg.cap_offsets.contains_key("version"));
        // F9: the island's PMU registers exist (island_top 0x180-0x18C) but are published
        // only as comments, so nothing can be ingested. If this starts failing because the
        // design added PMU_OFF_* localparams, that is the good outcome -- close F9.
        assert!(
            cfg.pmu_offsets.is_empty(),
            "if PMU_OFF_* is now published, close F9 in RTL_FEEDBACK.md"
        );
    }

    #[test]
    fn published_pmu_offsets_are_ingested() {
        let text = r#"
package g6lc_ai_island_cfg_pkg;
  localparam ai_island_cfg_t AiIslandLatencyDefault = '{
      Clusters: unsigned'(1),
      Queues: unsigned'(1),
      QueueDepth: unsigned'(8)
  };
  localparam logic [15:0] CAP_OFF_VERSION   = 16'h00;
  localparam logic [15:0] PMU_OFF_R_BEATS   = 16'h180;
  localparam logic [15:0] PMU_OFF_W_BEATS   = 16'h184;
  localparam logic [15:0] PMU_OFF_CYCLES    = 16'h188;
  localparam logic [15:0] PMU_OFF_GBPS_X1000 = 16'h18C;
endpackage
"#;
        let cfg = parse_ai_island_cfg_pkg(text).unwrap();
        assert_eq!(cfg.pmu_offsets.get("r_beats"), Some(&0x180));
        assert_eq!(cfg.pmu_offsets.get("w_beats"), Some(&0x184));
        assert_eq!(cfg.pmu_offsets.get("cycles"), Some(&0x188));
        assert_eq!(cfg.pmu_offsets.get("gbps_x1000"), Some(&0x18c));
        // A PMU offset must not leak into the capability table.
        assert!(!cfg.cap_offsets.contains_key("r_beats"));
    }

    #[test]
    fn parses_reference_config_package() {
        let text = r#"
package g6lc_ai_island_cfg_pkg;
  localparam logic [15:0] AiIslandCapVersion = 16'd1;

  typedef struct packed {
    int unsigned Clusters;
    int unsigned MacsPerCycle;
    int unsigned ClockKhz;
    int unsigned SramBytes;
    int unsigned AccTileM;
    int unsigned AccTileN;
    int unsigned AccTileK;
    int unsigned NocWidth;
    int unsigned DramChannels;
    int unsigned DramGBps;
    int unsigned Queues;
    int unsigned QueueDepth;
    int unsigned QosClasses;
    int unsigned WorkQuantumK;
  } ai_island_cfg_t;

  localparam ai_island_cfg_t AiIslandLatencyDefault = '{
      Clusters:     unsigned'(1),
      MacsPerCycle: unsigned'(256),
      ClockKhz:     unsigned'(1_000_000),
      SramBytes:    unsigned'(2 * 1024 * 1024),
      AccTileM:     unsigned'(256),
      AccTileN:     unsigned'(256),
      AccTileK:     unsigned'(256),
      NocWidth:     unsigned'(64),
      DramChannels: unsigned'(1),
      DramGBps:     unsigned'(0),
      Queues:       unsigned'(2),
      QueueDepth:   unsigned'(64),
      QosClasses:   unsigned'(2),
      WorkQuantumK: unsigned'(64)
  };

  localparam logic [15:0] CAP_OFF_VERSION     = 16'h00;
  localparam logic [15:0] CAP_OFF_CLUSTERS    = 16'h04;
  localparam logic [15:0] CAP_OFF_MACS_CYCLE  = 16'h08;
endpackage
"#;
        let cfg = parse_ai_island_cfg_pkg(text).unwrap();
        assert_eq!(cfg.cap_version, 1);
        assert_eq!(cfg.clusters, 1);
        assert_eq!(cfg.macs_per_cycle, 256);
        assert_eq!(cfg.clock_khz, 1_000_000);
        assert_eq!(cfg.sram_bytes, 2 * 1024 * 1024);
        assert_eq!(cfg.queues, 2);
        assert_eq!(cfg.queue_depth, 64);
        assert_eq!(cfg.cap_offsets.get("version"), Some(&0));
        assert_eq!(cfg.cap_offsets.get("clusters"), Some(&4));
        assert_eq!(cfg.cap_offsets.get("macs_cycle"), Some(&8));
    }

    #[test]
    fn a_package_without_a_stated_placement_leaves_it_unresolved() {
        // The reference package publishes CAP_OFF_* but keeps the window *placement* in
        // the island's address decode. The reader must report that rather than guess:
        // a guessed base puts the descriptor at the wrong address while every individual
        // field still looks plausible.
        let text = r#"
package g6lc_ai_island_cfg_pkg;
  localparam ai_island_cfg_t AiIslandLatencyDefault = '{
      Clusters: unsigned'(1),
      Queues: unsigned'(2),
      QueueDepth: unsigned'(64)
  };
  localparam logic [15:0] CAP_OFF_VERSION  = 16'h00;
  localparam logic [15:0] CAP_OFF_CLUSTERS = 16'h04;
endpackage
"#;
        let cfg = parse_ai_island_cfg_pkg(text).unwrap();
        assert!(!cfg.cap_offsets.is_empty(), "offsets are ingested");
        assert_eq!(cfg.cap_base, None, "placement must not be invented");
        assert_eq!(cfg.desc_base, None, "placement must not be invented");
        assert!(!cfg.placement_resolved());
    }

    #[test]
    fn a_stated_placement_is_ingested() {
        let text = r#"
package g6lc_ai_island_cfg_pkg;
  localparam ai_island_cfg_t AiIslandLatencyDefault = '{
      Clusters: unsigned'(1),
      Queues: unsigned'(1),
      QueueDepth: unsigned'(8)
  };
  localparam logic [15:0] CAP_BASE         = 16'h00;
  localparam logic [15:0] DESC_BASE        = 16'h0140;
  localparam logic [15:0] CAP_OFF_CLUSTERS = 16'h04;
endpackage
"#;
        let cfg = parse_ai_island_cfg_pkg(text).unwrap();
        assert_eq!(cfg.cap_base, Some(0x0000));
        assert_eq!(cfg.desc_base, Some(0x0140));
        assert!(cfg.placement_resolved());
        // A base must not leak into the offset table.
        assert!(!cfg.cap_offsets.contains_key("base"));
    }

    #[test]
    fn parses_queue_cluster_map_from_struct_field() {
        let text = r#"
package g6lc_ai_island_cfg_pkg;
  typedef struct packed {
    int unsigned Clusters;
    int unsigned Queues;
    int unsigned QueueDepth;
    int unsigned QueueClusterMap [0:1];
  } ai_island_cfg_t;

  localparam ai_island_cfg_t AiIslandLatencyDefault = '{
      Clusters:       unsigned'(1),
      Queues:         unsigned'(2),
      QueueDepth:     unsigned'(64),
      QueueClusterMap: '{0, 1}
  };
endpackage
"#;
        let cfg = parse_ai_island_cfg_pkg(text).unwrap();
        assert_eq!(cfg.queue_cluster_map, Some(vec![0, 1]));
    }

    #[test]
    fn parses_64_bit_ai_island_placement() {
        let text = r#"
package g6lc_ai_island_cfg_pkg;
  typedef struct packed {
    int unsigned Clusters;
    int unsigned MacsPerCycle;
    int unsigned ClockKhz;
    int unsigned SramBytes;
    int unsigned AccTileM;
    int unsigned AccTileN;
    int unsigned AccTileK;
    int unsigned NocWidth;
    int unsigned DramChannels;
    int unsigned DramGBps;
    int unsigned Queues;
    int unsigned QueueDepth;
    int unsigned QosClasses;
    int unsigned WorkQuantumK;
  } ai_island_cfg_t;
  localparam ai_island_cfg_t AiIslandLatencyDefault = '{
      Clusters: 1, MacsPerCycle: 256, ClockKhz: 1000000, SramBytes: 2097152,
      AccTileM: 256, AccTileN: 256, AccTileK: 256, NocWidth: 64,
      DramChannels: 1, DramGBps: 0, Queues: 2, QueueDepth: 64,
      QosClasses: 2, WorkQuantumK: 64
  };
  localparam logic [63:0] AI_CAP_BASE  = 64'h3000_0000;
  localparam logic [63:0] AI_DESC_BASE = 64'h3000_0140;
endpackage
"#;
        let cfg = parse_ai_island_cfg_pkg(text).unwrap();
        assert_eq!(cfg.cap_base, Some(0));
        assert_eq!(cfg.desc_base, Some(0x140));
    }

    #[test]
    fn parses_queue_cluster_map_from_top_level_localparam() {
        let text = r#"
package g6lc_ai_island_cfg_pkg;
  typedef struct packed {
    int unsigned Clusters;
    int unsigned Queues;
    int unsigned QueueDepth;
  } ai_island_cfg_t;

  localparam ai_island_cfg_t AiIslandLatencyDefault = '{
      Clusters:   unsigned'(1),
      Queues:     unsigned'(2),
      QueueDepth: unsigned'(64)
  };

  localparam int unsigned QueueClusterMap [0:1] = '{0, 1};
endpackage
"#;
        let cfg = parse_ai_island_cfg_pkg(text).unwrap();
        assert_eq!(cfg.queue_cluster_map, Some(vec![0, 1]));
    }
}
