// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! HTML subset parser → [`g6b_dom::Node`].

#![allow(missing_docs)]

use g6b_dom::Node;

/// Parse a tiny HTML subset into a DOM tree.
pub fn parse(src: &str) -> Node {
    parse_checked(src).unwrap_or_else(|_| Node::elem("document"))
}

pub fn parse_checked(src: &str) -> Result<Node, String> {
    if src.len() > 1_048_576 {
        return Err("HTML source limit exceeded".into());
    }
    let mut root = Node::elem("document");
    let mut rest = src;
    // skip doctype
    root.children = parse_nodes(&mut rest, None, 0)?;
    Ok(root)
}

fn parse_nodes(rest: &mut &str, parent: Option<&str>, depth: usize) -> Result<Vec<Node>, String> {
    if depth > 128 {
        return Err("HTML nesting limit exceeded".into());
    }
    let mut nodes = Vec::new();
    while !rest.is_empty() {
        if rest.starts_with("<!--") {
            let end = rest[4..].find("-->").ok_or("unterminated HTML comment")? + 4;
            *rest = &rest[end + 3..];
        } else if rest
            .get(..9)
            .map(|s| s.eq_ignore_ascii_case("<!doctype"))
            .unwrap_or(false)
        {
            let end = rest.find('>').ok_or("unterminated doctype")?;
            if !rest[9..end].trim().eq_ignore_ascii_case("html") {
                return Err("unsupported doctype".into());
            }
            *rest = &rest[end + 1..];
        } else if rest.starts_with("</") {
            let end = rest.find('>').ok_or("unterminated closing tag")?;
            let name = rest[2..end].trim();
            if !parent
                .map(|p| name.eq_ignore_ascii_case(p))
                .unwrap_or(false)
            {
                return Err(format!("unexpected closing tag {name}"));
            }
            *rest = &rest[end + 1..];
            return Ok(nodes);
        } else if rest.starts_with('<') {
            nodes.push(parse_elem(rest, depth)?);
        } else {
            let end = rest.find('<').unwrap_or(rest.len());
            nodes.push(Node::text_node(&decode_entities(&rest[..end])));
            *rest = &rest[end..];
        }
    }
    if let Some(parent) = parent {
        return Err(format!("unclosed element {parent}"));
    }
    Ok(nodes)
}

fn parse_elem(rest: &mut &str, depth: usize) -> Result<Node, String> {
    *rest = &rest[1..];
    let name_end = rest
        .find(|c: char| c.is_ascii_whitespace() || c == '>' || c == '/')
        .unwrap_or(rest.len());
    let name = rest[..name_end].to_ascii_lowercase();
    g6b_dom::validate_element_name(&name)?;
    *rest = &rest[name_end..];
    let mut node = Node::elem(&name);
    // attributes
    loop {
        let had_space = rest.starts_with(|c: char| c.is_ascii_whitespace());
        skip_ws(rest);
        if rest.starts_with('>') {
            *rest = &rest[1..];
            break;
        }
        if rest.starts_with("/>") {
            *rest = &rest[2..];
            return Ok(node);
        }
        if rest.is_empty() || !had_space {
            return Err("expected whitespace or > after tag/attribute".into());
        }
        let key_end = rest
            .find(|c: char| c == '=' || c.is_ascii_whitespace() || c == '>' || c == '/')
            .unwrap_or(rest.len());
        let key = rest[..key_end].to_ascii_lowercase();
        g6b_dom::validate_attribute_name(&key)?;
        *rest = &rest[key_end..];
        let after_key = *rest;
        skip_ws(rest);
        let mut value = String::new();
        if let Some(tail) = rest.strip_prefix('=') {
            *rest = tail;
            skip_ws(rest);
            if rest.starts_with(['\'', '"']) {
                let quote = rest.as_bytes()[0] as char;
                *rest = &rest[1..];
                let end = rest.find(quote).ok_or("unterminated attribute value")?;
                value = decode_entities(&rest[..end]);
                *rest = &rest[end + 1..];
            } else {
                let end = rest
                    .find(|c: char| {
                        c.is_ascii_whitespace() || matches!(c, '>' | '\'' | '"' | '<' | '=' | '`')
                    })
                    .unwrap_or(rest.len());
                if end == 0 {
                    return Err("expected attribute value".into());
                }
                value = decode_entities(&rest[..end]);
                *rest = &rest[end..];
            }
        } else {
            *rest = after_key;
        }
        if node.get_attribute(&key).is_none() {
            node.set_attribute(&key, &value)?;
        }
    }
    if VOID.contains(&name.as_str()) {
        return Ok(node);
    }
    if name == "script" || name == "style" {
        let (start, end) = find_close(rest, &name).ok_or("unclosed raw-text element")?;
        if start != 0 {
            node.children.push(Node::text_node(&rest[..start]));
        }
        *rest = &rest[end..];
    } else {
        node.children = parse_nodes(rest, Some(&name), depth + 1)?;
    }
    Ok(node)
}

fn skip_ws(rest: &mut &str) {
    *rest = rest.trim_start_matches(|c: char| c.is_ascii_whitespace());
}

const VOID: &[&str] = &[
    "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source",
    "track", "wbr",
];

fn find_close(hay: &str, name: &str) -> Option<(usize, usize)> {
    for (start, _) in hay.match_indices("</") {
        let tail = &hay[start + 2..];
        if tail
            .get(..name.len())
            .map(|s| s.eq_ignore_ascii_case(name))
            .unwrap_or(false)
        {
            let remainder = &tail[name.len()..];
            let trimmed = remainder.trim_start_matches(|c: char| c.is_ascii_whitespace());
            if trimmed.starts_with('>') {
                return Some((start, hay.len() - trimmed.len() + 1));
            }
        }
    }
    None
}

pub fn decode_entities(source: &str) -> String {
    let mut out = String::new();
    let mut rest = source;
    while let Some(start) = rest.find('&') {
        out.push_str(&rest[..start]);
        rest = &rest[start..];
        if let Some(end) = rest.as_bytes().iter().take(33).position(|b| *b == b';') {
            let entity = &rest[1..end];
            let decoded = match entity {
                "amp" => Some('&'),
                "lt" => Some('<'),
                "gt" => Some('>'),
                "quot" => Some('"'),
                "apos" => Some('\''),
                "nbsp" => Some('\u{a0}'),
                _ => {
                    let number = if let Some(digits) = entity
                        .strip_prefix("#x")
                        .or_else(|| entity.strip_prefix("#X"))
                    {
                        u32::from_str_radix(digits, 16).ok()
                    } else if let Some(digits) = entity.strip_prefix('#') {
                        digits.parse::<u32>().ok()
                    } else {
                        None
                    };
                    number.map(|n| {
                        char::from_u32(n)
                            .filter(|c| *c != '\0')
                            .unwrap_or('\u{fffd}')
                    })
                }
            };
            if let Some(c) = decoded {
                out.push(c);
                rest = &rest[end + 1..];
                continue;
            }
        }
        out.push('&');
        rest = &rest[1..];
    }
    out.push_str(rest);
    out
}

pub fn escape_text(source: &str) -> String {
    let mut out = String::new();
    for c in source.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            _ => out.push(c),
        }
    }
    out
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
    if width == 0 {
        return vec![String::new()];
    }
    let mut lines = Vec::new();
    walk(node, &mut lines, width);
    if lines.is_empty() {
        lines.push(String::new());
    }
    lines
}

fn walk(n: &Node, lines: &mut Vec<String>, width: usize) {
    if n.hidden {
        return;
    }
    if n.name == "#text" {
        push_text(lines, &n.text, width);
        return;
    }
    if n.name == "title" || n.name == "script" || n.name == "style" {
        return;
    }
    // Replaced elements: represent what we can in text, skip the rest.
    if n.name == "img" {
        if let Some(alt) = n.get_attribute("alt") {
            push_text(lines, alt, width);
        }
        return;
    }
    if matches!(n.name.as_str(), "svg" | "canvas") {
        return;
    }
    let block = matches!(
        n.name.as_str(),
        "h1" | "h2"
            | "h3"
            | "h4"
            | "h5"
            | "h6"
            | "p"
            | "div"
            | "section"
            | "nav"
            | "pre"
            | "tr"
            | "li"
    );
    if block && !lines.last().map(|s| s.is_empty()).unwrap_or(true) {
        lines.push(String::new());
    }
    for c in &n.children {
        walk(c, lines, width);
    }
    if block || n.name == "br" {
        lines.push(String::new());
    }
}

fn push_text(lines: &mut Vec<String>, text: &str, width: usize) {
    for word in text.split_whitespace() {
        if lines.is_empty() {
            lines.push(String::new());
        }
        let used = lines.last().unwrap().chars().count();
        if used != 0 {
            if used + 1 + word.chars().count() > width {
                lines.push(String::new());
            } else {
                lines.last_mut().unwrap().push(' ');
            }
        }
        for c in word.chars() {
            if lines.last().unwrap().chars().count() == width {
                lines.push(String::new());
            }
            lines.last_mut().unwrap().push(c);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn setup_tables_have_row_boundaries() {
        let dom = parse_checked("<section><h2>CPU</h2><table><tr><th>Cores</th><td>2</td></tr><tr><th>Threads</th><td>4</td></tr></table></section>").unwrap();
        let lines: Vec<_> = to_uart_lines(&dom, 80)
            .into_iter()
            .filter(|s| !s.is_empty())
            .collect();
        assert_eq!(lines, ["CPU", "Cores 2", "Threads 4"]);
    }

    #[test]
    fn attributes_entities_hidden_and_raw_text() {
        let source = "<!DOCTYPE html><!-- ignored --><body><p id='visible' class=row data-title=ok>A &amp; B &#xE9; &#233;</p><div id=panel hidden='false'><p>secret</p></div><script>console.log('a < b &amp;');</script><style>.x { color: red; }</style></body>";
        let mut dom = parse_checked(source).unwrap();
        let visible = dom.get_element_by_id("visible").unwrap();
        assert_eq!(visible.get_attribute("class"), Some("row"));
        assert_eq!(visible.inner_text(), "A & B é é");
        assert!(dom.get_element_by_id("panel").unwrap().hidden);
        let painted = to_uart_lines(&dom, 80).join("\n");
        assert!(!painted.contains("secret"));
        assert!(!painted.contains("console"));
        assert!(!painted.contains("color"));
        assert_eq!(script_sources(&dom), vec!["console.log('a < b &amp;');"]);
        dom.get_element_by_id("panel").unwrap().set_visible(true);
        assert!(to_uart_lines(&dom, 80).join("\n").contains("secret"));
    }

    #[test]
    fn replaced_elements_emit_alt_or_skip() {
        let dom = parse_checked(
            r#"<body><img src="a.png" alt="Logo"><svg><circle r="5"/></svg><canvas id="fx"></canvas></body>"#,
        )
        .unwrap();
        let text = to_uart_lines(&dom, 80).join("\n");
        assert!(text.contains("Logo"));
        assert!(!text.contains("circle"));
        assert!(!text.contains("fx"));
    }

    #[test]
    fn checked_parser_rejects_malformed_without_hanging() {
        for source in [
            "<p id='bad>",
            "<div><span></div>",
            "<p =x>",
            "<!-- open",
            "<script>open",
            "<p><",
            "<div hidden/",
            "</div>",
        ] {
            assert!(parse_checked(source).is_err(), "{source}");
            assert!(parse(source).children.is_empty(), "{source}");
        }
        assert_eq!(
            parse_checked("leading <p>body</p> trailing")
                .unwrap()
                .inner_text(),
            "leading body trailing"
        );
    }

    #[test]
    fn duplicate_attributes_keep_first_and_width_counts_characters() {
        let mut dom = parse_checked("<p ID='first' id='second'>&lt;é&gt;&quot;&apos;</p>").unwrap();
        assert!(dom.get_element_by_id("first").is_some());
        assert!(dom.get_element_by_id("second").is_none());
        assert_eq!(dom.inner_text(), "<é>\"'");
        let lines = to_uart_lines(&parse("<p>éééééé</p>"), 3);
        assert!(lines.iter().all(|line| line.chars().count() <= 3));
        assert!(to_uart_lines(&dom, 0).iter().all(|line| line.is_empty()));
    }

    #[test]
    fn entity_roundtrip_and_raw_tag_boundaries() {
        let text = "<&\"'é> &amp;";
        assert_eq!(decode_entities(&escape_text(text)), text);
        assert_eq!(
            decode_entities("&unknown; &#0; &#xD800; &#x110000;"),
            "&unknown; \u{fffd} \u{fffd} \u{fffd}"
        );
        let dom =
            parse_checked("<SCRIPT>console.log('</scriptx>');</ScRiPt ><p>shown</p>").unwrap();
        assert_eq!(script_sources(&dom), vec!["console.log('</scriptx>');"]);
        assert!(to_uart_lines(&dom, 80).join("\n").contains("shown"));
        assert!(parse_checked("<p id='x'class='y'></p>").is_err());
        let nested = format!("{}x{}", "<p>".repeat(130), "</p>".repeat(130));
        assert!(parse_checked(&nested).is_err());
    }

    #[test]
    fn short_unicode_html_never_panics() {
        let alphabet = ["é", "<", ">", "=", "'", "\"", "&", ";", "/", "a"];
        for a in alphabet {
            for b in alphabet {
                for c in alphabet {
                    let _ = parse_checked(&format!("{a}{b}{c}"));
                }
            }
        }
    }

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
