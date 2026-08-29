// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! AI-island capability window (`g6lc_ai_cap_window.sv`) reader.
//!
//! The capability window packs values that are not in `g6lc_ai_island_cfg_pkg.sv`:
//! the data-type grant mask and the bit layout of packed capability words.  This
//! module reads those directly from the module that implements the window.

use g6q_core::model::{CapBlockMnk, CapPackedField, CapPackedWords};

/// Parse the `DtypeMask` parameter from a capability-window module.
///
/// The parameter is declared like `parameter logic [15:0] DtypeMask = 16'h0001;`.
/// If the declaration is not present, or the value cannot be decoded, this returns
/// `None` so the caller can report the word as unsourced rather than invent it.
pub fn parse_cap_window_dtype_mask(text: &str) -> Option<u32> {
    let cleaned = strip_sv_comments(text);
    // Parameter port lists are comma-separated; module-body declarations are semicolon-
    // separated.  Split on both and look for a declaration whose name is `DtypeMask`.
    for sep in [',', ';'] {
        for stmt in cleaned.split(sep) {
            let stmt = stmt.trim();
            if !stmt.contains("DtypeMask") {
                continue;
            }
            let mut words = stmt.split_whitespace().peekable();
            let mut saw_parameter = false;
            let mut name = "";
            let mut saw_eq = false;
            for w in words.by_ref() {
                if w == "parameter" || w == "localparam" {
                    saw_parameter = true;
                    name = "";
                    saw_eq = false;
                } else if w == "=" {
                    saw_eq = true;
                } else if saw_parameter
                    && !saw_eq
                    && !w.starts_with('[')
                    && !w.ends_with(']')
                    && w != "logic"
                    && w != "integer"
                    && w != "int"
                    && w != "unsigned"
                {
                    name = w;
                } else if saw_eq && name == "DtypeMask" {
                    return Some(parse_int_literal(w)? as u32);
                }
            }
        }
    }
    None
}

/// Parse the packed `block_mnk` capability word layout from the cap window.
///
/// The word is built from `log2(AccTileM)`, `log2(AccTileN)` and `log2(AccTileK)`.  This
/// function finds the case arm in the module's `always_comb` block, extracts the
/// concatenation order, and computes the low bit and width of each field.
pub fn parse_cap_window_block_mnk(text: &str) -> Option<CapBlockMnk> {
    let cleaned = strip_sv_comments(text);

    // Width of the `lg2u` helper, which determines how wide each packed field is.
    let lg2u_width = parse_lg2u_width(&cleaned).unwrap_or(4);

    // Find the case arm for the block_mnk word (word index 5, from CAP_OFF_BLOCK_MNK / 4).
    // The source is hand-formatted, so the assignment may cross several lines; we collect
    // from the `14'h05:` label to the terminating semicolon.
    let start = cleaned.find("14'h05:")?;
    let rest = &cleaned[start..];
    let end = rest.find(';')?;
    let arm = &rest[..end + 1];

    // Extract the concatenation body `{ ... }`.
    let open = arm.find('{')?;
    let close = arm.rfind('}')?;
    let inner = &arm[open + 1..close];

    // Items are comma-separated.  We are only interested in `lg2u(IslandCfg.AccTile*)`.
    // Items are listed MSB-first, so we walk them right-to-left to assign low bits.
    let mut fields: Vec<(char, u32)> = Vec::new();
    for item in inner.split(',') {
        let item = item.trim();
        if let Some(field) = extract_tile_field(item) {
            fields.push((field, lg2u_width));
        } else if let Some(w) = extract_literal_width(item) {
            // Padding like `20'h0` carries a width but maps to no field.
            fields.push((' ', w));
        }
    }

    // Items are MSB-first; the rightmost occupies low bits.
    let mut low: u32 = 0;
    let mut m_low = None;
    let mut n_low = None;
    let mut k_low = None;
    for (name, width) in fields.iter().rev() {
        match *name {
            'M' => m_low = Some(low),
            'N' => n_low = Some(low),
            'K' => k_low = Some(low),
            _ => {}
        }
        low += width;
    }

    Some(CapBlockMnk {
        m_low: m_low?,
        m_width: lg2u_width,
        n_low: n_low?,
        n_width: lg2u_width,
        k_low: k_low?,
        k_width: lg2u_width,
    })
}

fn extract_tile_field(item: &str) -> Option<char> {
    // Look for `lg2u(IslandCfg.AccTileX)` and return the last letter of the field name.
    let item = item.replace(['\n', '\t'], " ");
    let item = item.trim();
    if !item.starts_with("lg2u") {
        return None;
    }
    if let Some(start) = item.find("AccTile") {
        let rest = &item[start + "AccTile".len()..];
        let mut chars = rest.chars();
        let c = chars.next()?;
        if c == 'M' || c == 'N' || c == 'K' {
            return Some(c);
        }
    }
    None
}

fn extract_literal_width(item: &str) -> Option<u32> {
    // Sized literals like `20'h0` or `32'd0`.
    let item = item.trim();
    if let Some(end) = item.find('\'') {
        let prefix = &item[..end];
        prefix.parse::<u32>().ok()
    } else {
        None
    }
}

fn parse_lg2u_width(text: &str) -> Option<u32> {
    // `function automatic logic [3:0] lg2u(input int unsigned v);`
    let start = text.find("function automatic")?;
    let rest = &text[start..];
    let end = rest.find(';')?;
    let decl = &rest[..end];
    if !decl.contains("lg2u") {
        return None;
    }
    let open = decl.rfind('[')?;
    let close = decl.rfind(']')?;
    let range = &decl[open + 1..close];
    let mut parts = range.split(':');
    let high = parts.next()?.trim().parse::<u32>().ok()?;
    let low = parts.next()?.trim().parse::<u32>().ok()?;
    Some(high - low + 1)
}

/// Parse packed capability words from the cap window module.
///
/// The case arm labels (`14'h05:`, `14'h06:`, ...) are converted to byte offsets and matched
/// against the `cap_offsets` map from `g6lc_ai_island_cfg_pkg.sv`. Each matching arm is decoded
/// into a list of fields from LSB to MSB. Fields not in `AiIslandConfig` are prefixed with `_` so
/// the VM treats them as zero.
pub fn parse_cap_window_packed(
    text: &str,
    cap_offsets: &std::collections::BTreeMap<String, u64>,
) -> Option<CapPackedWords> {
    let cleaned = strip_sv_comments(text);
    let case_start = cleaned.find("unique case (addr_i[15:2])")?;
    let rest = &cleaned[case_start..];
    let endcase = rest.find("endcase")?;
    let body_with_header = &rest[..endcase];
    // The header line `unique case (addr_i[15:2])` is not a case arm; skip it.
    let header_end = body_with_header.find('\n')?;
    let body = &body_with_header[header_end + 1..];

    let mut words = CapPackedWords::default();
    let cap_by_offset: std::collections::BTreeMap<u64, String> =
        cap_offsets.iter().map(|(k, v)| (*v, k.clone())).collect();

    for arm in body.split(';') {
        let arm = arm.trim();
        if !arm.contains(':') {
            continue;
        }
        let label = arm.split(':').next()?.trim();
        let word = match parse_case_word_index(label) {
            Some(w) => w,
            None => continue,
        };
        let offset = word * 4;
        let cap_name = match cap_by_offset.get(&offset) {
            Some(n) => n.clone(),
            None => continue,
        };

        // The dtype_mask and block_mnk words are handled by dedicated readers: dtype_mask is a
        // flat parameter, and block_mnk needs log2 transforms. Keep this path for raw packings.
        if cap_name == "dtype_mask" || cap_name == "block_mnk" {
            continue;
        }

        let (open, close) = match (arm.find('{'), arm.rfind('}')) {
            (Some(o), Some(c)) if o < c => (o, c),
            _ => continue,
        };
        let inner = &arm[open + 1..close];
        let fields = parse_packed_arm(inner)?;
        words.words.insert(cap_name, fields);
    }

    Some(words)
}

fn parse_case_word_index(label: &str) -> Option<u64> {
    // Match `14'h05` or `14'd5` or `5'b101`.
    let label = label.trim();
    let hex = label.split_whitespace().last()?;
    if let Some(rest) = hex.strip_prefix("14'h") {
        return u64::from_str_radix(rest, 16).ok();
    }
    if let Some(rest) = hex.strip_prefix("14'd") {
        return rest.parse().ok();
    }
    None
}

#[derive(Debug, Clone, Default)]
struct PackedItem {
    /// Field name, or `None` for padding.
    pub name: Option<String>,
    /// Width in bits. `None` means it must be inferred from the remaining bits.
    pub width: Option<u32>,
}

fn parse_packed_arm(inner: &str) -> Option<Vec<CapPackedField>> {
    let mut items: Vec<PackedItem> = Vec::new();
    let mut known_total: u32 = 0;
    let mut unknown: Vec<usize> = Vec::new();

    for item in inner.split(',') {
        let item = item.replace(['\n', '\t'], " ");
        let item = item.trim();
        if item.is_empty() {
            continue;
        }
        let pi = parse_packed_item(item);
        if let Some(w) = pi.width {
            known_total += w;
        } else {
            unknown.push(items.len());
        }
        items.push(pi);
    }

    // Infer the width of one un-sized field if exactly one exists.
    if unknown.len() == 1 {
        let inferred = 32u32.checked_sub(known_total)?;
        items[unknown[0]].width = Some(inferred);
        known_total += inferred;
    }
    if known_total != 32 {
        return None;
    }

    // Items are MSB-first; walk them in reverse to assign low bits.
    let mut low: u32 = 0;
    let mut fields: Vec<CapPackedField> = Vec::new();
    for item in items.iter().rev() {
        if let Some(name) = &item.name {
            let width = item.width.unwrap_or(0);
            fields.push(CapPackedField {
                name: name.clone(),
                low,
                width,
            });
        }
        low += item.width.unwrap_or(0);
    }
    Some(fields)
}

fn parse_packed_item(item: &str) -> PackedItem {
    // Sized cast: `16'(IslandCfg.Queues)` or `16'(meas_milli)`.
    if let Some(apo) = item.find('\'') {
        if let Ok(width) = item[..apo].parse::<u32>() {
            let expr = &item[apo + 1..];
            let expr = expr.trim().trim_start_matches('(').trim_end_matches(')');
            let name = packed_field_name(expr);
            if name.is_some() {
                return PackedItem {
                    name,
                    width: Some(width),
                };
            }
            // Sized literal like `20'h0` is padding.
            return PackedItem {
                name: None,
                width: Some(width),
            };
        }
    }

    // Bare identifier like `meas_milli`.
    if !item.contains(' ') && !item.contains('{') && !item.contains('(') {
        let name = packed_field_name(item);
        return PackedItem { name, width: None };
    }

    // Anything else (e.g. `lg2u(...)` or complex expressions) is ignored; it will likely make
    // the total width check fail, which is the right outcome for unsupported packings.
    PackedItem {
        name: None,
        width: Some(0),
    }
}

fn packed_field_name(expr: &str) -> Option<String> {
    let expr = expr.trim();
    // Sized literals like `h0`, `d0`, `b0` are padding, not fields.
    if is_sv_literal(expr) {
        return None;
    }
    // `IslandCfg.Queues` -> `queues`; preserve the exact config field names that the
    // `ai_cfg` parser uses, so the packed word can index `AiIslandConfig` fields.
    if let Some(field) = expr.strip_prefix("IslandCfg.") {
        return Some(cfg_field_name(field.trim()));
    }
    // A bare identifier that is not a function call.
    if expr.chars().all(|c| c.is_alphanumeric() || c == '_') {
        return Some(format!("_{}", expr.to_lowercase()));
    }
    None
}

fn cfg_field_name(sv_name: &str) -> String {
    match sv_name {
        "CapVersion" => "cap_version".to_string(),
        "Clusters" => "clusters".to_string(),
        "MacsPerCycle" => "macs_per_cycle".to_string(),
        "ClockKhz" => "clock_khz".to_string(),
        "SramBytes" => "sram_bytes".to_string(),
        "AccTileM" => "acc_tile_m".to_string(),
        "AccTileN" => "acc_tile_n".to_string(),
        "AccTileK" => "acc_tile_k".to_string(),
        "NocWidth" => "noc_width".to_string(),
        "DramChannels" => "dram_channels".to_string(),
        "DramGBps" => "dram_gbps".to_string(),
        "Queues" => "queues".to_string(),
        "QueueDepth" => "queue_depth".to_string(),
        "QosClasses" => "qos_classes".to_string(),
        "WorkQuantumK" => "work_quantum_k".to_string(),
        "DtypeMask" => "dtype_mask".to_string(),
        _ => sv_name.to_lowercase(),
    }
}

fn is_sv_literal(expr: &str) -> bool {
    let expr = expr.trim();
    if expr == "0" || expr == "1" {
        return true;
    }
    if expr.len() < 2 {
        return false;
    }
    let base = expr.chars().next().unwrap();
    if !"hdbox".contains(base) {
        return false;
    }
    let rest = &expr[1..];
    if rest.is_empty() {
        return false;
    }
    rest.chars()
        .all(|c| c.is_ascii_hexdigit() || c == '_' || c == 'x' || c == 'z')
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

fn parse_int_literal(s: &str) -> Option<i64> {
    let s = s.trim();
    if let Some(rest) = s.strip_prefix("0x") {
        return i64::from_str_radix(rest, 16).ok();
    }
    if let Some(rest) = s.strip_prefix("16'h") {
        return i64::from_str_radix(rest, 16).ok();
    }
    if let Some(rest) = s.strip_prefix("16'd") {
        return rest.parse().ok();
    }
    if let Some(rest) = s.strip_prefix("0b") {
        return i64::from_str_radix(rest, 2).ok();
    }
    s.parse().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_dtype_mask_from_module_parameter() {
        let text = r#"
module g6lc_ai_cap_window
#(
    parameter ai_island_cfg_t IslandCfg = AiIslandLatencyDefault,
    parameter logic [15:0]    DtypeMask = 16'h0003
) (
    input logic clk_i,
    output logic [31:0] rdata_o
);
endmodule
"#;
        assert_eq!(parse_cap_window_dtype_mask(text), Some(0x0003));
    }

    #[test]
    fn parses_block_mnk_layout_from_cap_window() {
        let text = r#"
module g6lc_ai_cap_window;
  function automatic logic [3:0] lg2u(input int unsigned v);
    return 4'($clog2(v == 0 ? 1 : v));
  endfunction
  always_comb begin
    rdata_n = '0;
    unique case (addr_i[15:2])
      14'h05: rdata_n = {20'h0, lg2u(IslandCfg.AccTileK),
                                 lg2u(IslandCfg.AccTileN),
                                 lg2u(IslandCfg.AccTileM)};
      default: rdata_n = 32'h0;
    endcase
  end
endmodule
"#;
        let layout = parse_cap_window_block_mnk(text).unwrap();
        // K is MSB of the three packed fields (bits 11:8), N next (7:4), M low (3:0).
        assert_eq!(layout.m_low, 0);
        assert_eq!(layout.n_low, 4);
        assert_eq!(layout.k_low, 8);
        assert_eq!(layout.m_width, 4);
    }

    #[test]
    fn parses_real_cap_window_block_mnk_if_present() {
        let path = std::path::Path::new(r"E:/cva6/corev_apu/ai_island/g6lc_ai_cap_window.sv");
        if !path.exists() {
            return;
        }
        let text = std::fs::read_to_string(path).unwrap();
        let layout = parse_cap_window_block_mnk(&text).unwrap();
        // Live cap window packs K above N above M, each four bits wide.
        assert_eq!(layout.m_low, 0);
        assert_eq!(layout.n_low, 4);
        assert_eq!(layout.k_low, 8);
        assert_eq!(layout.m_width, 4);
    }

    #[test]
    fn parses_real_cap_window_dtype_mask_if_present() {
        let path = std::path::Path::new(r"E:/cva6/corev_apu/ai_island/g6lc_ai_cap_window.sv");
        if !path.exists() {
            return;
        }
        let text = std::fs::read_to_string(path).unwrap();
        let mask = parse_cap_window_dtype_mask(&text);
        assert!(
            mask.is_some(),
            "DtypeMask should be present in the live cap window"
        );
        assert_eq!(mask.unwrap(), 0x0001, "live cap window default is s8 dense");
    }

    #[test]
    fn parses_packed_dram_gbps_and_queues_from_cap_window() {
        let text = r#"
module g6lc_ai_cap_window;
  always_comb begin
    rdata_n = '0;
    unique case (addr_i[15:2])
      14'h06: rdata_n = {meas_milli, 16'(IslandCfg.DramGBps)};
      14'h07: rdata_n = {16'(IslandCfg.QueueDepth), 16'(IslandCfg.Queues)};
      default: rdata_n = 32'h0;
    endcase
  end
endmodule
"#;
        let mut cap_offsets = std::collections::BTreeMap::new();
        cap_offsets.insert("dram_gbps".to_string(), 0x18u64);
        cap_offsets.insert("queues".to_string(), 0x1cu64);
        let packed = parse_cap_window_packed(text, &cap_offsets).unwrap();

        let dram = packed.words.get("dram_gbps").expect("dram_gbps packed");
        assert_eq!(dram.len(), 2);
        assert_eq!(dram[0].name, "dram_gbps");
        assert_eq!(dram[0].low, 0);
        assert_eq!(dram[0].width, 16);
        assert_eq!(dram[1].name, "_meas_milli");
        assert_eq!(dram[1].low, 16);
        assert_eq!(dram[1].width, 16);

        let queues = packed.words.get("queues").expect("queues packed");
        assert_eq!(queues.len(), 2);
        assert_eq!(queues[0].name, "queues");
        assert_eq!(queues[0].low, 0);
        assert_eq!(queues[0].width, 16);
        assert_eq!(queues[1].name, "queue_depth");
        assert_eq!(queues[1].low, 16);
        assert_eq!(queues[1].width, 16);
    }

    #[test]
    fn parses_real_cap_window_packed_if_present() {
        let cap_path = std::path::Path::new(r"E:/cva6/corev_apu/ai_island/g6lc_ai_cap_window.sv");
        let cfg_path = std::path::Path::new(r"E:/cva6/corev_apu/include/g6lc_ai_island_cfg_pkg.sv");
        if !cap_path.exists() || !cfg_path.exists() {
            return;
        }
        let cfg_text = std::fs::read_to_string(cfg_path).unwrap();
        let cfg = crate::ai_cfg::parse_ai_island_cfg_pkg(&cfg_text).unwrap();
        let cap_text = std::fs::read_to_string(cap_path).unwrap();
        let packed = parse_cap_window_packed(&cap_text, &cfg.cap_offsets);
        assert!(
            packed
                .as_ref()
                .map(|p| p.words.contains_key("dram_gbps"))
                .unwrap_or(false),
            "live cap window should publish a packed dram_gbps word"
        );
        assert!(
            packed
                .as_ref()
                .map(|p| p.words.contains_key("queues"))
                .unwrap_or(false),
            "live cap window should publish a packed queues word"
        );
    }
}
