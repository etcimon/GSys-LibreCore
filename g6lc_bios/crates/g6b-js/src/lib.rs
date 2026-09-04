// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Goja-shaped ES5 subset: AOT `document.getElementById(id).innerText = "…"`.
//!
//! Host objects live on [`g6b_dom::Node`]. No Go runtime, no live eval in B0.

#![allow(missing_docs)]

use g6b_dom::Node;

/// Bytecode op against the BIOS DOM.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Op {
    /// `document.getElementById(id).innerText = value`
    SetInnerText { id: String, value: String },
    /// `console.log(value)` — WebIDL Console (live).
    Log { value: String },
    /// `document.getElementById(id).getContext("webgl"|"opengl")`
    GetContext { id: String, kind: String },
    /// `fetch("/bios/...")` — proxied to the kernel HTTP router.
    Fetch { method: String, url: String },
    /// `kernel.register("/bios/custom")` — JS endpoint, same table as HolyC.
    RegisterEndpoint { method: String, path: String },
    /// `kernel.holyc("UsbLs(\"fat32\")")` — HolyC REPL line (browser-ui jsExports).
    HolycEval { line: String },
}

/// Compile a tiny JS subset to [`Op`]s.
pub fn compile(src: &str) -> Result<Vec<Op>, String> {
    let mut ops = Vec::new();
    let stripped = strip_comments(src);
    let mut s = stripped.as_str();
    while !s.trim().is_empty() {
        skip_ws(&mut s);
        if s.is_empty() {
            break;
        }
        if s.starts_with(';') {
            s = &s[1..];
            continue;
        }
        ops.push(parse_assign(&mut s)?);
        skip_ws(&mut s);
        if s.starts_with(';') {
            s = &s[1..];
        }
    }
    Ok(ops)
}

/// Run AOT ops against a DOM tree.
pub fn run(ops: &[Op], dom: &mut Node) -> Result<(), String> {
    for op in ops {
        match op {
            Op::SetInnerText { id, value } => {
                let n = dom
                    .get_element_by_id(id)
                    .ok_or_else(|| format!("no element id={id}"))?;
                n.set_inner_text(value);
            }
            Op::Log { .. } => {}
            Op::GetContext { id, kind } => {
                let n = dom
                    .get_element_by_id(id)
                    .ok_or_else(|| format!("no element id={id}"))?;
                n.set_inner_text(&format!("GL-ADAPTER {kind}"));
            }
            Op::Fetch { .. } | Op::RegisterEndpoint { .. } | Op::HolycEval { .. } => {}
        }
    }
    Ok(())
}

fn strip_comments(src: &str) -> String {
    let mut out = String::new();
    let mut chars = src.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '/' && chars.peek() == Some(&'/') {
            chars.next();
            for n in chars.by_ref() {
                if n == '\n' {
                    out.push('\n');
                    break;
                }
            }
        } else if c == '/' && chars.peek() == Some(&'*') {
            chars.next();
            let mut prev = ' ';
            for n in chars.by_ref() {
                if prev == '*' && n == '/' {
                    break;
                }
                prev = n;
            }
        } else {
            out.push(c);
        }
    }
    out
}

fn skip_ws(s: &mut &str) {
    *s = s.trim_start();
}

fn parse_assign(s: &mut &str) -> Result<Op, String> {
    skip_ws(s);
    if s.starts_with("fetch(") {
        *s = &s["fetch(".len()..];
        skip_ws(s);
        let url = take_string(s)?;
        skip_ws(s);
        if s.starts_with(')') {
            *s = &s[1..];
        }
        return Ok(Op::Fetch {
            method: "GET".into(),
            url,
        });
    }
    if s.starts_with("kernel.holyc(") {
        *s = &s["kernel.holyc(".len()..];
        skip_ws(s);
        let line = take_string(s)?;
        skip_ws(s);
        if s.starts_with(')') {
            *s = &s[1..];
        }
        return Ok(Op::HolycEval { line });
    }
    if s.starts_with("kernel.register(") {
        *s = &s["kernel.register(".len()..];
        skip_ws(s);
        let path = take_string(s)?;
        skip_ws(s);
        let mut method = "GET".to_string();
        if s.starts_with(',') {
            *s = &s[1..];
            skip_ws(s);
            method = take_string(s).unwrap_or(method);
        }
        skip_ws(s);
        if s.starts_with(')') {
            *s = &s[1..];
        }
        return Ok(Op::RegisterEndpoint { method, path });
    }
    if s.starts_with("console.log(") {
        *s = &s["console.log(".len()..];
        skip_ws(s);
        let value = take_string(s)?;
        skip_ws(s);
        if s.starts_with(')') {
            *s = &s[1..];
        }
        return Ok(Op::Log { value });
    }
    const PREFIX: &str = "document.getElementById(";
    if !s.starts_with(PREFIX) {
        return Err(format!("expected {PREFIX}, got {}", trunc(s)));
    }
    *s = &s[PREFIX.len()..];
    skip_ws(s);
    let id = take_string(s)?;
    skip_ws(s);
    if !s.starts_with(')') {
        return Err("expected ) after getElementById".into());
    }
    *s = &s[1..];
    skip_ws(s);
    if !s.starts_with('.') {
        return Err("expected .innerText or .getContext".into());
    }
    *s = &s[1..];
    skip_ws(s);
    if s.starts_with("getContext(") {
        *s = &s["getContext(".len()..];
        skip_ws(s);
        let kind = take_string(s)?;
        skip_ws(s);
        if s.starts_with(')') {
            *s = &s[1..];
        }
        return Ok(Op::GetContext { id, kind });
    }
    if !(s.starts_with("innerText") || s.starts_with("innerHTML")) {
        return Err("expected innerText".into());
    }
    if let Some(rest) = s.strip_prefix("innerText") {
        *s = rest;
    } else if let Some(rest) = s.strip_prefix("innerHTML") {
        *s = rest;
    }
    skip_ws(s);
    if !s.starts_with('=') {
        return Err("expected =".into());
    }
    *s = &s[1..];
    skip_ws(s);
    let value = take_string(s)?;
    Ok(Op::SetInnerText { id, value })
}

fn take_string(s: &mut &str) -> Result<String, String> {
    skip_ws(s);
    let quote = s.chars().next();
    if quote != Some('"') && quote != Some('\'') {
        return Err("expected string".into());
    }
    let q = quote.unwrap();
    *s = &s[q.len_utf8()..];
    let mut out = String::new();
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'\\' && i + 1 < bytes.len() {
            match bytes[i + 1] {
                b'n' => out.push('\n'),
                b't' => out.push('\t'),
                c => out.push(c as char),
            }
            i += 2;
            continue;
        }
        if bytes[i] == q as u8 {
            *s = &s[i + 1..];
            return Ok(out);
        }
        out.push(bytes[i] as char);
        i += 1;
    }
    Err("unterminated string".into())
}

fn trunc(s: &str) -> &str {
    let n = s.len().min(40);
    &s[..n]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sets_status() {
        let mut dom = Node::elem("body");
        let mut st = Node::elem("p");
        st.id = Some("status".into());
        st.set_inner_text("boot");
        dom.children.push(st);
        let ops = compile(r#"document.getElementById("status").innerText = "UI-BOOT";"#).unwrap();
        run(&ops, &mut dom).unwrap();
        assert_eq!(
            dom.get_element_by_id("status").unwrap().inner_text(),
            "UI-BOOT"
        );
        assert_eq!(g6b_webidl::status("Document"), g6b_webidl::Status::Live);
        let f = compile(r#"fetch("/bios/clocks");"#).unwrap();
        assert!(matches!(&f[0], Op::Fetch { url, .. } if url == "/bios/clocks"));
        let h = compile(r#"kernel.holyc("UsbLs(\"fat32\")");"#).unwrap();
        assert!(matches!(&h[0], Op::HolycEval { line } if line == "UsbLs(\"fat32\")"));
    }
}
