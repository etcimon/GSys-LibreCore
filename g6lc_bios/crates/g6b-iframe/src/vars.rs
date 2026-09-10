// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Parent-provided JS bindings for an iframe session (`vars` attribute).
//! Data + function *names* live here; host callables stay in the JS adapter.

use std::collections::BTreeMap;

/// HTML / element property name.
pub const PROP_VARS: &str = "vars";

/// Bounded map size.
pub const MAX_SESSION_VARS: usize = 32;

/// Names the nested JS env already owns, or that would elevate native.
pub const RESERVED_VAR_NAMES: &[&str] = &[
    "window",
    "document",
    "console",
    "eval",
    "Function",
    "globalThis",
    "self",
    "top",
    "parent",
    "frames",
    "location",
    "navigator",
    "holyc",
    "holycEval",
    "fetchBios",
    "registerEndpoint",
    "register_endpoint",
    "pglite",
    "platform",
    "hw",
    "contentWindow",
    "contentDocument",
    "src",
    "srcdoc",
];

/// JS identifier that is safe to intern as a nested global.
pub fn session_var_name_allowed(name: &str) -> bool {
    let mut chars = name.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    if !(first.is_ascii_alphabetic() || first == '_') {
        return false;
    }
    if !chars.all(|c| c.is_ascii_alphanumeric() || c == '_') {
        return false;
    }
    !RESERVED_VAR_NAMES.iter().any(|r| *r == name)
}

/// How Svelte wrote the `vars` attribute.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum VarsAttr {
    /// `vars={frameVars}` / `vars=frameVars` — parent JS map.
    Binding(String),
    /// `vars='{"greeting":"hi"}'` — JSON object of data (no functions).
    Json(String),
}

/// Parse the attribute string. Functions are never in JSON; they come from
/// the live parent map named by [`VarsAttr::Binding`].
pub fn parse_vars_attr(attr: &str) -> Option<VarsAttr> {
    let t = attr.trim();
    if t.is_empty() {
        return None;
    }
    if t.starts_with('{') && t.ends_with('}') {
        let inner = t[1..t.len() - 1].trim();
        if !inner.is_empty()
            && inner.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
            && session_var_name_allowed(inner)
        {
            return Some(VarsAttr::Binding(inner.to_string()));
        }
        if inner.starts_with('"') || inner.contains(':') {
            return Some(VarsAttr::Json(t.to_string()));
        }
        if inner.is_empty() {
            return Some(VarsAttr::Json("{}".into()));
        }
        return None;
    }
    if t.starts_with('[') {
        return None;
    }
    if session_var_name_allowed(t) {
        return Some(VarsAttr::Binding(t.to_string()));
    }
    None
}

/// One interned value. [`SessionVar::Function`] is a host callable; no body.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SessionVar {
    Null,
    Bool(bool),
    Number(String),
    String(String),
    Json(String),
    Function,
}

/// Filtered name → value map for a session slot.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SessionVars {
    entries: BTreeMap<String, SessionVar>,
}

impl SessionVars {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn get(&self, name: &str) -> Option<&SessionVar> {
        self.entries.get(name)
    }

    pub fn names(&self) -> impl Iterator<Item = &str> {
        self.entries.keys().map(String::as_str)
    }

    pub fn insert(&mut self, name: String, value: SessionVar) -> bool {
        if !session_var_name_allowed(&name) {
            return false;
        }
        if !self.entries.contains_key(&name) && self.entries.len() >= MAX_SESSION_VARS {
            return false;
        }
        self.entries.insert(name, value);
        true
    }

    pub fn iter(&self) -> impl Iterator<Item = (&str, &SessionVar)> {
        self.entries.iter().map(|(k, v)| (k.as_str(), v))
    }

    /// JSON object of data values. Functions cannot appear in JSON.
    pub fn from_json(src: &str) -> Self {
        let mut out = Self::new();
        if let Some(map) = parse_json_object(src.trim()) {
            for (k, v) in map {
                let _ = out.insert(k, v);
            }
        }
        out
    }
}

fn parse_json_object(s: &str) -> Option<Vec<(String, SessionVar)>> {
    let s = s.trim();
    if !s.starts_with('{') || !s.ends_with('}') {
        return None;
    }
    let inner = &s[1..s.len() - 1];
    let mut out = Vec::new();
    let mut i = 0;
    let b = inner.as_bytes();
    skip_ws(b, &mut i);
    if i >= b.len() {
        return Some(out);
    }
    loop {
        skip_ws(b, &mut i);
        let key = parse_json_string(inner, &mut i)?;
        skip_ws(b, &mut i);
        if i >= b.len() || b[i] != b':' {
            return None;
        }
        i += 1;
        skip_ws(b, &mut i);
        let (val, next) = parse_json_value(inner, i)?;
        out.push((key, val));
        i = next;
        skip_ws(b, &mut i);
        if i >= b.len() {
            break;
        }
        if b[i] == b',' {
            i += 1;
            continue;
        }
        return None;
    }
    Some(out)
}

fn skip_ws(b: &[u8], i: &mut usize) {
    while *i < b.len() && b[*i].is_ascii_whitespace() {
        *i += 1;
    }
}

fn parse_json_string(s: &str, i: &mut usize) -> Option<String> {
    let b = s.as_bytes();
    if *i >= b.len() || b[*i] != b'"' {
        return None;
    }
    *i += 1;
    let mut out = String::new();
    while *i < b.len() {
        let c = b[*i];
        *i += 1;
        match c {
            b'"' => return Some(out),
            b'\\' => {
                if *i >= b.len() {
                    return None;
                }
                let e = b[*i];
                *i += 1;
                match e {
                    b'"' | b'\\' | b'/' => out.push(e as char),
                    b'n' => out.push('\n'),
                    b't' => out.push('\t'),
                    _ => return None,
                }
            }
            _ if c >= 32 => out.push(c as char),
            _ => return None,
        }
    }
    None
}

fn parse_json_value(s: &str, start: usize) -> Option<(SessionVar, usize)> {
    let b = s.as_bytes();
    let mut i = start;
    skip_ws(b, &mut i);
    if i >= b.len() {
        return None;
    }
    match b[i] {
        b'"' => {
            let st = parse_json_string(s, &mut i)?;
            Some((SessionVar::String(st), i))
        }
        b't' if s[i..].starts_with("true") => Some((SessionVar::Bool(true), i + 4)),
        b'f' if s[i..].starts_with("false") => Some((SessionVar::Bool(false), i + 5)),
        b'n' if s[i..].starts_with("null") => Some((SessionVar::Null, i + 4)),
        b'{' | b'[' => {
            let end = skip_json_value(b, i)?;
            Some((SessionVar::Json(s[i..end].to_string()), end))
        }
        b'-' | b'0'..=b'9' => {
            let end = skip_json_number(b, i)?;
            Some((SessionVar::Number(s[i..end].to_string()), end))
        }
        _ => None,
    }
}

fn skip_json_number(b: &[u8], start: usize) -> Option<usize> {
    let mut i = start;
    if i < b.len() && b[i] == b'-' {
        i += 1;
    }
    if i >= b.len() || !b[i].is_ascii_digit() {
        return None;
    }
    while i < b.len()
        && (b[i].is_ascii_digit()
            || b[i] == b'.'
            || b[i] == b'e'
            || b[i] == b'E'
            || b[i] == b'+'
            || b[i] == b'-')
    {
        i += 1;
    }
    Some(i)
}

fn skip_json_value(b: &[u8], start: usize) -> Option<usize> {
    let mut i = start;
    if i >= b.len() {
        return None;
    }
    match b[i] {
        b'"' => {
            i += 1;
            while i < b.len() {
                if b[i] == b'\\' {
                    i += 2;
                    continue;
                }
                if b[i] == b'"' {
                    return Some(i + 1);
                }
                i += 1;
            }
            None
        }
        b'{' | b'[' => {
            let open = b[i];
            let close = if open == b'{' { b'}' } else { b']' };
            let mut depth = 1;
            i += 1;
            while i < b.len() && depth > 0 {
                match b[i] {
                    b'"' => {
                        i = skip_json_value(b, i)?;
                        continue;
                    }
                    c if c == open => depth += 1,
                    c if c == close => depth -= 1,
                    _ => {}
                }
                i += 1;
            }
            if depth == 0 {
                Some(i)
            } else {
                None
            }
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_and_attr_shapes() {
        assert!(session_var_name_allowed("greeting"));
        assert!(session_var_name_allowed("onReady"));
        assert!(!session_var_name_allowed("eval"));
        assert!(!session_var_name_allowed("holycEval"));
        assert!(!session_var_name_allowed("pglite"));
        assert!(!session_var_name_allowed("platform"));
        assert!(!session_var_name_allowed("hw"));
        assert!(!session_var_name_allowed("1x"));
        assert_eq!(
            parse_vars_attr("{frameVars}"),
            Some(VarsAttr::Binding("frameVars".into()))
        );
        assert_eq!(
            parse_vars_attr("frameVars"),
            Some(VarsAttr::Binding("frameVars".into()))
        );
        assert!(matches!(
            parse_vars_attr("{\"greeting\":\"hi\"}"),
            Some(VarsAttr::Json(_))
        ));
        assert!(parse_vars_attr("{eval}").is_none());
    }

    #[test]
    fn json_data_skips_reserved() {
        let v = SessionVars::from_json(
            r#"{"greeting":"hello","count":2,"ok":true,"meta":{"k":1},"eval":"nope"}"#,
        );
        assert_eq!(v.get("greeting"), Some(&SessionVar::String("hello".into())));
        assert_eq!(v.get("count"), Some(&SessionVar::Number("2".into())));
        assert_eq!(v.get("ok"), Some(&SessionVar::Bool(true)));
        assert!(matches!(v.get("meta"), Some(SessionVar::Json(_))));
        assert!(v.get("eval").is_none());
    }
}
