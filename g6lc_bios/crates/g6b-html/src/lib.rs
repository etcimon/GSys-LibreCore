// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! HTML subset parser → [`g6b_dom::Node`].

#![allow(missing_docs)]

use g6b_dom::Node;

/// Parse a tiny HTML subset into a DOM tree.
pub fn parse(src: &str) -> Node {
    let mut root = Node::elem("document");
    let mut rest = src;
    // skip doctype
    if let Some(i) = rest.find('<') {
        rest = &rest[i..];
    }
    root.children = parse_nodes(&mut rest);
    root
}

fn parse_nodes(rest: &mut &str) -> Vec<Node> {
    let mut nodes = Vec::new();
    loop {
        skip_ws(rest);
        if rest.is_empty() {
            break;
        }
        if rest.starts_with("</") {
            break;
        }
        if rest.starts_with('<') {
            if let Some(n) = parse_elem(rest) {
                nodes.push(n);
            } else {
                break;
            }
        } else if let Some(i) = rest.find('<') {
            let text = rest[..i].to_string();
            *rest = &rest[i..];
            if !text.trim().is_empty() {
                nodes.push(Node::text_node(text.trim()));
            }
        } else {
            if !rest.trim().is_empty() {
                nodes.push(Node::text_node(rest.trim()));
            }
            *rest = "";
        }
    }
    nodes
}

fn parse_elem(rest: &mut &str) -> Option<Node> {
    if !rest.starts_with('<') {
        return None;
    }
    *rest = &rest[1..];
    if rest.starts_with('/') {
        return None;
    }
    let name_end = rest
        .find(|c: char| c.is_whitespace() || c == '>' || c == '/')
        .unwrap_or(rest.len());
    let name = rest[..name_end].to_ascii_lowercase();
    *rest = &rest[name_end..];
    let mut node = Node::elem(&name);
    // attributes
    loop {
        skip_ws(rest);
        if rest.starts_with('>') {
            *rest = &rest[1..];
            break;
        }
        if rest.starts_with("/>") {
            *rest = &rest[2..];
            return Some(node);
        }
        if rest.is_empty() {
            return Some(node);
        }
        let key_end = rest
            .find(|c: char| c == '=' || c.is_whitespace() || c == '>')
            .unwrap_or(rest.len());
        let key = rest[..key_end].to_ascii_lowercase();
        *rest = &rest[key_end..];
        skip_ws(rest);
        let mut val = String::new();
        if rest.starts_with('=') {
            *rest = &rest[1..];
            skip_ws(rest);
            if rest.starts_with('"') {
                *rest = &rest[1..];
                if let Some(e) = rest.find('"') {
                    val = rest[..e].to_string();
                    *rest = &rest[e + 1..];
                }
            }
        }
        if key == "id" {
            node.id = Some(val);
        }
    }
    if VOID.contains(&name.as_str()) {
        return Some(node);
    }
    if name == "script" || name == "style" {
        let closer = format!("</{name}>");
        if let Some(i) = find_close(rest, &closer) {
            let raw = rest[..i].to_string();
            *rest = &rest[i + closer.len()..];
            if !raw.trim().is_empty() {
                node.children.push(Node::text_node(raw.trim()));
            }
            return Some(node);
        }
    }
    node.children = parse_nodes(rest);
    if rest.starts_with("</") {
        if let Some(e) = rest.find('>') {
            *rest = &rest[e + 1..];
        }
    }
    Some(node)
}

fn skip_ws(rest: &mut &str) {
    *rest = rest.trim_start();
}

const VOID: &[&str] = &["br", "hr", "img", "input", "meta", "link"];

fn find_close(hay: &str, closer: &str) -> Option<usize> {
    let h = hay.as_bytes();
    let c = closer.as_bytes();
    if c.is_empty() || h.len() < c.len() {
        return None;
    }
    (0..=h.len() - c.len()).find(|&i| h[i..i + c.len()].eq_ignore_ascii_case(c))
}

/// Text of every `<script>` element, in document order.
pub fn script_sources(node: &Node) -> Vec<String> {
    let mut out = Vec::new();
    collect_scripts(node, &mut out);
    out
}

fn collect_scripts(node: &Node, out: &mut Vec<String>) {
    if node.name == "script" {
        let t = node.inner_text();
        if !t.is_empty() {
            out.push(t);
        }
        return;
    }
    for c in &node.children {
        collect_scripts(c, out);
    }
}

/// Flatten DOM text for a UART viewport (BIOS display without Gr).
pub fn to_uart_lines(node: &Node, width: usize) -> Vec<String> {
    let mut lines = Vec::new();
    walk(node, &mut lines, width);
    if lines.is_empty() {
        lines.push(String::new());
    }
    lines
}

fn walk(n: &Node, lines: &mut Vec<String>, width: usize) {
    if n.name == "#text" {
        push_text(lines, &n.text, width);
        return;
    }
    if n.name == "title" || n.name == "script" || n.name == "style" {
        return;
    }
    if (n.name == "h1" || n.name == "p" || n.name == "div")
        && !lines.last().map(|s| s.is_empty()).unwrap_or(true)
    {
        lines.push(String::new());
    }
    for c in &n.children {
        walk(c, lines, width);
    }
    if n.name == "h1" || n.name == "p" || n.name == "div" || n.name == "br" {
        lines.push(String::new());
    }
}

fn push_text(lines: &mut Vec<String>, text: &str, width: usize) {
    if lines.is_empty() {
        lines.push(String::new());
    }
    let last = lines.last_mut().unwrap();
    if last.len() + text.len() + 1 > width && !last.is_empty() {
        lines.push(text.to_string());
    } else {
        if !last.is_empty() {
            last.push(' ');
        }
        last.push_str(text);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_setup_page() {
        let html = r#"<html><head><title>G6LC-BIOS</title></head>
            <body><h1 id="banner">G6LC-BIOS</h1><p>Press ESC to boot</p></body></html>"#;
        let mut dom = parse(html);
        let banner = dom.get_element_by_id("banner").unwrap();
        assert_eq!(banner.inner_text(), "G6LC-BIOS");
        let lines = to_uart_lines(&parse(html), 80);
        let joined = lines.join("\n");
        assert!(joined.contains("G6LC-BIOS"), "{joined}");
    }

    #[test]
    fn script_extracted_not_painted() {
        let html = r#"<body><p id="status">boot</p><script>document.getElementById("status").innerText = "UI-BOOT";</script></body>"#;
        let dom = parse(html);
        let scripts = script_sources(&dom);
        assert_eq!(scripts.len(), 1);
        assert!(scripts[0].contains("UI-BOOT"));
        let painted = to_uart_lines(&dom, 80).join("\n");
        assert!(!painted.contains("getElementById"), "{painted}");
    }
}
