// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! DolDoc subset: `$FG,BLUE$…$FG$` and `$LK,"tag"$` plus ToHtml.

#![allow(missing_docs)]

/// A rendered DolDoc span.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Span {
    Text(String),
    Fg { color: String, text: String },
    Link { tag: String },
}

/// Parse a tiny DolDoc subset into spans.
pub fn parse(src: &str) -> Vec<Span> {
    let mut out = Vec::new();
    let mut rest = src;
    while !rest.is_empty() {
        if let Some(idx) = rest.find('$') {
            if idx > 0 {
                out.push(Span::Text(rest[..idx].to_string()));
            }
            rest = &rest[idx + 1..];
            if let Some(end) = rest.find('$') {
                let cmd = &rest[..end];
                rest = &rest[end + 1..];
                if let Some(color) = cmd.strip_prefix("FG,") {
                    let (text, tail) = split_until_fg(rest);
                    out.push(Span::Fg {
                        color: color.to_string(),
                        text,
                    });
                    rest = tail;
                } else if let Some(tag) = cmd.strip_prefix("LK,\"") {
                    let tag = tag.trim_end_matches('"').to_string();
                    out.push(Span::Link { tag });
                } else if cmd == "FG" {
                    // closer already consumed by split_until_fg
                } else {
                    out.push(Span::Text(format!("${cmd}$")));
                }
            } else {
                out.push(Span::Text(format!("${rest}")));
                break;
            }
        } else {
            out.push(Span::Text(rest.to_string()));
            break;
        }
    }
    out
}

fn split_until_fg(s: &str) -> (String, &str) {
    if let Some(i) = s.find("$FG$") {
        (s[..i].to_string(), &s[i + 4..])
    } else {
        (s.to_string(), "")
    }
}

/// Convert spans to a minimal HTML5 document (BIOS setup page).
pub fn to_html(title: &str, spans: &[Span]) -> String {
    let mut body = String::new();
    for s in spans {
        match s {
            Span::Text(t) => body.push_str(&escape(t)),
            Span::Fg { color, text } => {
                body.push_str("<span style=\"color:");
                body.push_str(css_color(color));
                body.push_str("\">");
                body.push_str(&escape(text));
                body.push_str("</span>");
            }
            Span::Link { tag } => {
                body.push_str("<a href=\"#");
                body.push_str(&escape(tag));
                body.push_str("\">");
                body.push_str(&escape(tag));
                body.push_str("</a>");
            }
        }
    }
    format!(
        "<!DOCTYPE html>\n<html><head><title>{}</title></head><body>\n{}\n</body></html>\n",
        escape(title),
        body
    )
}

fn escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

fn css_color(name: &str) -> &'static str {
    match name {
        "BLUE" | "LTBLUE" => "#00a",
        "RED" => "#a00",
        "GREEN" => "#0a0",
        "WHITE" => "#eee",
        _ => "#ccc",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fg_and_link_roundtrip_html() {
        let spans = parse("$FG,BLUE$Hello$FG$ $LK,\"Boot\"$");
        let html = to_html("G6LC-BIOS", &spans);
        assert!(html.contains("G6LC-BIOS"));
        assert!(html.contains("color:#00a"));
        assert!(html.contains("Hello"));
        assert!(html.contains("href=\"#Boot\""));
    }
}
