// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Device tree source: node/property model and parser.
//!
//! Narrow in the same way [`crate`] is narrow: it reads the forms real board trees use
//! and keeps anything it does not interpret as raw text rather than discarding it.

use std::collections::BTreeMap;

/// A property value.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Prop {
    /// A valueless property, e.g. `tlb-split;`.
    Flag,
    /// A string list, e.g. `compatible = "a", "b";`.
    Strings(Vec<String>),
    /// Numeric cells, e.g. `reg = <0x0 0x8000_0000>;`. Phandle references are dropped
    /// from the numeric view and preserved in [`Prop::raw_text`].
    Cells(Vec<u64>),
    /// Anything else, kept verbatim.
    Other(String),
}

impl Prop {
    /// The string list, if this is one.
    pub fn strings(&self) -> Option<&[String]> {
        match self {
            Prop::Strings(v) => Some(v),
            _ => None,
        }
    }

    /// The first string, if this is a string list.
    pub fn first_string(&self) -> Option<&str> {
        self.strings().and_then(|v| v.first()).map(String::as_str)
    }

    /// The numeric cells, if this is a cell list.
    pub fn cells(&self) -> Option<&[u64]> {
        match self {
            Prop::Cells(v) => Some(v),
            _ => None,
        }
    }

    /// The single numeric value, if this is a one-cell property.
    pub fn u64(&self) -> Option<u64> {
        match self {
            Prop::Cells(v) if v.len() == 1 => Some(v[0]),
            _ => None,
        }
    }

    /// Original source text, for reporting.
    pub fn raw_text(&self) -> String {
        match self {
            Prop::Flag => String::new(),
            Prop::Strings(v) => v.join(", "),
            Prop::Cells(v) => v
                .iter()
                .map(|c| format!("{c:#x}"))
                .collect::<Vec<_>>()
                .join(" "),
            Prop::Other(t) => t.clone(),
        }
    }

    /// Render this property as a single source line (without trailing newline).
    pub fn to_dts(&self, name: &str, _indent: &str) -> String {
        match self {
            Prop::Flag => format!("{name};\n"),
            Prop::Strings(v) if v.is_empty() => format!("{name} = \"\";\n"),
            Prop::Strings(v) => format!(
                "{name} = {};\n",
                v.iter()
                    .map(|s| format!("\"{s}\""))
                    .collect::<Vec<_>>()
                    .join(", ")
            ),
            Prop::Cells(v) if v.is_empty() => format!("{name} = <>;\n"),
            Prop::Cells(v) => format!(
                "{name} = <{}>;\n",
                v.iter()
                    .map(|c| format!("{c:#x}"))
                    .collect::<Vec<_>>()
                    .join(" ")
            ),
            Prop::Other(t) => format!("{name} = {t};\n"),
        }
    }
}

/// A device tree node.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Node {
    /// Node name including any unit address, e.g. `uart@10000000`.
    pub name: String,
    /// Label preceding the node, e.g. `PLIC0` in `PLIC0: interrupt-controller@…`.
    pub label: Option<String>,
    /// Properties, canonically ordered.
    pub props: BTreeMap<String, Prop>,
    /// Child nodes, in source order.
    pub children: Vec<Node>,
}

impl Node {
    /// The name with any `@unit-address` removed.
    pub fn base_name(&self) -> &str {
        self.name.split('@').next().unwrap_or(&self.name)
    }

    /// The unit address, parsed from the node name.
    pub fn unit_address(&self) -> Option<u64> {
        let a = self.name.split('@').nth(1)?;
        u64::from_str_radix(a.trim_start_matches("0x"), 16).ok()
    }

    /// A direct child by exact name.
    pub fn child(&self, name: &str) -> Option<&Node> {
        self.children.iter().find(|c| c.name == name)
    }

    /// Direct children whose base name matches.
    pub fn children_named(&self, base: &str) -> Vec<&Node> {
        self.children
            .iter()
            .filter(|c| c.base_name() == base)
            .collect()
    }

    /// A property by name.
    pub fn prop(&self, name: &str) -> Option<&Prop> {
        self.props.get(name)
    }

    /// Whether a valueless or truthy property is present.
    pub fn has(&self, name: &str) -> bool {
        self.props.contains_key(name)
    }

    /// Depth-first iteration over this node and all descendants.
    pub fn walk(&self) -> Vec<&Node> {
        let mut out = vec![self];
        for c in &self.children {
            out.extend(c.walk());
        }
        out
    }

    /// The first `compatible` string.
    pub fn compatible(&self) -> Option<&str> {
        self.prop("compatible").and_then(Prop::first_string)
    }

    /// Render this node and its descendants as device tree source.
    pub fn to_dts(&self, indent: &str) -> String {
        let mut out = String::new();
        if self.name == "/" {
            out.push_str("/dts-v1/;\n\n");
            out.push_str("/ ");
        } else if let Some(label) = &self.label {
            out.push_str(&format!("{label}: {} ", self.name));
        } else {
            out.push_str(&format!("{} ", self.name));
        }
        out.push_str("{\n");
        let inner = format!("{indent}    ");
        for (name, prop) in &self.props {
            out.push_str(&prop.to_dts(name, &inner));
        }
        for child in &self.children {
            for line in child.to_dts(&inner).lines() {
                out.push_str(&inner);
                out.push_str(line);
                out.push('\n');
            }
        }
        out.push_str(indent);
        out.push_str("};\n");
        out
    }
}

/// Parse device tree source.
///
/// Returns the root node. Directives such as `/dts-v1/;` are skipped.
pub fn parse(text: &str) -> Node {
    let src = strip_comments(text);
    let chars: Vec<char> = src.chars().collect();
    let mut i = 0;
    let mut root = Node {
        name: "/".into(),
        ..Node::default()
    };

    // Find the root body: the first `{` that follows a `/` at top level.
    while i < chars.len() {
        if chars[i] == '{' {
            i += 1;
            parse_body(&chars, &mut i, &mut root);
            break;
        }
        i += 1;
    }
    root
}

fn parse_body(c: &[char], i: &mut usize, parent: &mut Node) {
    let mut token = String::new();
    let mut pending_label: Option<String> = None;
    let mut in_string = false;
    let mut escaped = false;

    while *i < c.len() {
        let ch = c[*i];
        if in_string {
            if escaped {
                token.push(ch);
                escaped = false;
            } else if ch == '\\' {
                escaped = true;
            } else if ch == '"' {
                in_string = false;
                token.push(ch);
            } else {
                token.push(ch);
            }
            *i += 1;
            continue;
        }
        match ch {
            '"' => {
                in_string = true;
                token.push(ch);
                *i += 1;
            }
            '}' => {
                *i += 1;
                // consume a trailing `;`
                while *i < c.len() && (c[*i].is_whitespace() || c[*i] == ';') {
                    if c[*i] == ';' {
                        *i += 1;
                        break;
                    }
                    *i += 1;
                }
                return;
            }
            '{' => {
                *i += 1;
                let name = token.trim().to_string();
                token.clear();
                let mut node = Node {
                    name,
                    label: pending_label.take(),
                    ..Node::default()
                };
                parse_body(c, i, &mut node);
                parent.children.push(node);
            }
            ';' => {
                *i += 1;
                let stmt = token.trim().to_string();
                token.clear();
                pending_label = None;
                if stmt.is_empty() || stmt.starts_with('/') {
                    continue; // directive such as /dts-v1/
                }
                let (name, prop) = parse_property(&stmt);
                if !name.is_empty() {
                    parent.props.insert(name, prop);
                }
            }
            ':' => {
                // A label introduces the node that follows.
                pending_label = Some(token.trim().to_string());
                token.clear();
                *i += 1;
            }
            _ => {
                token.push(ch);
                *i += 1;
            }
        }
    }
}

fn parse_property(stmt: &str) -> (String, Prop) {
    let Some((name, value)) = stmt.split_once('=') else {
        return (stmt.trim().to_string(), Prop::Flag);
    };
    let name = name.trim().to_string();
    let value = value.trim();

    if value.starts_with('"') {
        return (name, Prop::Strings(scan_quoted_list(value)));
    }
    if value.starts_with('<') {
        let mut cells = Vec::new();
        let mut had_ref = false;
        for group in value.split('<').skip(1) {
            let body = group.split('>').next().unwrap_or("");
            for tok in body.split_whitespace() {
                if tok.starts_with('&') {
                    had_ref = true;
                    continue;
                }
                if let Some(v) = parse_cell(tok) {
                    cells.push(v);
                }
            }
        }
        if cells.is_empty() && had_ref {
            return (name, Prop::Other(value.to_string()));
        }
        return (name, Prop::Cells(cells));
    }
    (name, Prop::Other(value.to_string()))
}

/// Split a `"a", "b"` list, taking only what is **inside** the quotes.
///
/// Splitting on raw commas would be wrong for every vendor-prefixed string — `"riscv,sv39"`,
/// `"sifive,clint0"`, `"vendor,device"` — silently turning one string into two fragments
/// and corrupting `compatible` and `mmu-type` across the whole tree.
fn scan_quoted_list(value: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut in_string = false;
    let mut escaped = false;
    for ch in value.chars() {
        if escaped {
            cur.push(ch);
            escaped = false;
            continue;
        }
        match ch {
            '\\' if in_string => escaped = true,
            '"' => {
                if in_string {
                    out.push(std::mem::take(&mut cur));
                }
                in_string = !in_string;
            }
            _ if in_string => cur.push(ch),
            _ => {}
        }
    }
    out
}

fn parse_cell(tok: &str) -> Option<u64> {
    let t = tok.trim().trim_end_matches(',');
    if let Some(hex) = t.strip_prefix("0x").or_else(|| t.strip_prefix("0X")) {
        return u64::from_str_radix(&hex.replace('_', ""), 16).ok();
    }
    t.replace('_', "").parse::<u64>().ok()
}

fn strip_comments(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let b: Vec<char> = text.chars().collect();
    let mut i = 0;
    while i < b.len() {
        if b[i] == '/' && b.get(i + 1) == Some(&'/') {
            while i < b.len() && b[i] != '\n' {
                i += 1;
            }
            continue;
        }
        if b[i] == '/' && b.get(i + 1) == Some(&'*') {
            i += 2;
            while i < b.len() && !(b[i] == '*' && b.get(i + 1) == Some(&'/')) {
                i += 1;
            }
            i = (i + 2).min(b.len());
            out.push(' ');
            continue;
        }
        out.push(b[i]);
        i += 1;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const SRC: &str = r#"
// a comment
/dts-v1/;

/ {
  #address-cells = <2>;
  compatible = "example,board";

  cpus {
    timebase-frequency = <32768>;
    CPU0: cpu@0 {
      device_type = "cpu";
      reg = <0>;
      riscv,isa-base = "rv64i";
      riscv,isa-extensions = "i", "m", "a", "c", "v";
      mmu-type = "riscv,sv39";
      tlb-split;
      CPU0_intc: interrupt-controller {
        compatible = "riscv,cpu-intc";
      };
    };
  };

  memory@80000000 {
    device_type = "memory";
    reg = <0x0 0x80000000 0x0 0x10000000>;
  };

  soc {
    INTC0: interrupt-controller@c000000 {
      compatible = "example,intc0";
      reg = <0x0 0xc000000 0x0 0x4000000>;
      riscv,ndev = <30>;
    };
    uart@10000000 {
      compatible = "ns16550a";
      reg = <0x0 0x10000000 0x0 0x1000>;
      interrupt-parent = <&INTC0>;
      interrupts = <1>;
    };
  };
};
"#;

    #[test]
    fn nodes_and_nesting_parse() {
        let root = parse(SRC);
        assert!(root.child("cpus").is_some());
        assert!(root.child("soc").is_some());
        let cpus = root.child("cpus").unwrap();
        let cpu = cpus.child("cpu@0").expect("cpu node");
        assert_eq!(cpu.base_name(), "cpu");
        assert_eq!(cpu.unit_address(), Some(0));
        assert!(cpu.child("interrupt-controller").is_some());
    }

    #[test]
    fn labels_attach_to_the_node_that_follows() {
        let root = parse(SRC);
        let cpu = root.child("cpus").unwrap().child("cpu@0").unwrap();
        assert_eq!(cpu.label.as_deref(), Some("CPU0"));
        let intc = root
            .child("soc")
            .unwrap()
            .child("interrupt-controller@c000000")
            .unwrap();
        assert_eq!(intc.label.as_deref(), Some("INTC0"));
    }

    #[test]
    fn string_lists_parse() {
        let root = parse(SRC);
        let cpu = root.child("cpus").unwrap().child("cpu@0").unwrap();
        let ext = cpu.prop("riscv,isa-extensions").unwrap().strings().unwrap();
        assert_eq!(ext, ["i", "m", "a", "c", "v"]);
        assert_eq!(
            cpu.prop("mmu-type").unwrap().first_string(),
            Some("riscv,sv39")
        );
    }

    #[test]
    fn cell_lists_parse_and_single_cells_are_scalars() {
        let root = parse(SRC);
        let mem = root.child("memory@80000000").unwrap();
        assert_eq!(
            mem.prop("reg").unwrap().cells().unwrap(),
            [0, 0x8000_0000, 0, 0x1000_0000]
        );
        let intc = root
            .child("soc")
            .unwrap()
            .child("interrupt-controller@c000000")
            .unwrap();
        assert_eq!(intc.prop("riscv,ndev").unwrap().u64(), Some(30));
    }

    #[test]
    fn commas_inside_quotes_do_not_split_a_string() {
        // Vendor-prefixed strings are everywhere in a real tree. Splitting on raw commas
        // turns "sifive,clint0" into two fragments and corrupts every compatible string.
        let root = parse(
            "/ { dev { compatible = \"vendor,thing\", \"generic-thing\"; \
             mmu-type = \"riscv,sv39\"; }; };",
        );
        let dev = root.child("dev").unwrap();
        assert_eq!(
            dev.prop("compatible").unwrap().strings().unwrap(),
            ["vendor,thing", "generic-thing"]
        );
        assert_eq!(dev.compatible(), Some("vendor,thing"));
        assert_eq!(
            dev.prop("mmu-type").unwrap().first_string(),
            Some("riscv,sv39")
        );
    }

    #[test]
    fn colons_and_semicolons_inside_strings_do_not_misparse() {
        // `stdout-path` values carry a colon and the surrounding node names carry @ and ;.
        let root = parse("/ { chosen { stdout-path = \"/soc/uart@10000000:115200\"; }; };");
        let chosen = root.child("chosen").unwrap();
        assert_eq!(
            chosen.prop("stdout-path").unwrap().first_string(),
            Some("/soc/uart@10000000:115200")
        );
    }

    #[test]
    fn valueless_properties_are_flags() {
        let root = parse(SRC);
        let cpu = root.child("cpus").unwrap().child("cpu@0").unwrap();
        assert!(cpu.has("tlb-split"));
        assert_eq!(cpu.prop("tlb-split"), Some(&Prop::Flag));
    }

    #[test]
    fn phandle_only_properties_are_kept_verbatim_not_silently_zero() {
        let root = parse(SRC);
        let uart = root.child("soc").unwrap().child("uart@10000000").unwrap();
        match uart.prop("interrupt-parent") {
            Some(Prop::Other(t)) => assert!(t.contains("INTC0")),
            other => panic!("expected the reference preserved, got {other:?}"),
        }
        // A numeric property alongside a reference still reads numerically.
        assert_eq!(uart.prop("interrupts").unwrap().u64(), Some(1));
    }

    #[test]
    fn walk_visits_every_node() {
        let root = parse(SRC);
        let names: Vec<&str> = root.walk().iter().map(|n| n.name.as_str()).collect();
        assert!(names.contains(&"uart@10000000"));
        assert!(names.contains(&"interrupt-controller"));
        assert!(names.len() >= 7, "{names:?}");
    }

    #[test]
    fn parsing_is_deterministic() {
        assert_eq!(parse(SRC), parse(SRC));
    }

    #[test]
    fn rendering_round_trips() {
        let root = parse(SRC);
        let rendered = root.to_dts("");
        let reparsed = parse(&rendered);
        // The structural content must survive; labels and ordering may shift.
        assert_eq!(root.props, reparsed.props);
        assert_eq!(root.children.len(), reparsed.children.len());
        assert!(reparsed.child("cpus").is_some());
        assert!(reparsed.child("soc").is_some());
    }
}
