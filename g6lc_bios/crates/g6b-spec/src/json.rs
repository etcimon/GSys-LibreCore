// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Minimal JSON parser/writer. No serde (KD0).

use std::collections::BTreeMap;

/// A JSON value. Objects use [`BTreeMap`] so key order is canonical.
#[derive(Debug, Clone, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    Int(i64),
    Str(String),
    Arr(Vec<Json>),
    Obj(BTreeMap<String, Json>),
}

impl Json {
    pub fn get(&self, key: &str) -> &Json {
        match self {
            Json::Obj(m) => m.get(key).unwrap_or(&Json::Null),
            _ => &Json::Null,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Json::Str(s) => Some(s),
            _ => None,
        }
    }

    pub fn as_u32(&self) -> Option<u32> {
        match self {
            Json::Int(i) if *i >= 0 && *i <= u32::MAX as i64 => Some(*i as u32),
            _ => None,
        }
    }

    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Json::Bool(b) => Some(*b),
            _ => None,
        }
    }
}

/// Parse a JSON document.
pub fn parse_json(s: &str) -> Result<Json, String> {
    let mut p = Parser {
        s: s.as_bytes(),
        i: 0,
    };
    p.skip_ws();
    let v = p.value()?;
    p.skip_ws();
    if p.i != p.s.len() {
        return Err("trailing junk after JSON value".into());
    }
    Ok(v)
}

struct Parser<'a> {
    s: &'a [u8],
    i: usize,
}

impl Parser<'_> {
    fn skip_ws(&mut self) {
        while self.i < self.s.len() && self.s[self.i].is_ascii_whitespace() {
            self.i += 1;
        }
    }

    fn peek(&self) -> Option<u8> {
        self.s.get(self.i).copied()
    }

    fn bump(&mut self) -> Option<u8> {
        let c = self.peek()?;
        self.i += 1;
        Some(c)
    }

    fn value(&mut self) -> Result<Json, String> {
        self.skip_ws();
        match self.peek() {
            Some(b'n') => self.ident(b"null").map(|_| Json::Null),
            Some(b't') => self.ident(b"true").map(|_| Json::Bool(true)),
            Some(b'f') => self.ident(b"false").map(|_| Json::Bool(false)),
            Some(b'"') => self.string().map(Json::Str),
            Some(b'[') => self.array(),
            Some(b'{') => self.object(),
            Some(b'-') | Some(b'0'..=b'9') => self.number(),
            other => Err(format!("unexpected JSON at byte {}: {other:?}", self.i)),
        }
    }

    fn ident(&mut self, want: &[u8]) -> Result<(), String> {
        for &b in want {
            if self.bump() != Some(b) {
                return Err(format!("expected {}", std::str::from_utf8(want).unwrap()));
            }
        }
        Ok(())
    }

    fn string(&mut self) -> Result<String, String> {
        if self.bump() != Some(b'"') {
            return Err("expected string".into());
        }
        let mut out = String::new();
        loop {
            match self.bump() {
                None => return Err("unterminated string".into()),
                Some(b'"') => return Ok(out),
                Some(b'\\') => match self.bump() {
                    Some(b'"') => out.push('"'),
                    Some(b'\\') => out.push('\\'),
                    Some(b'/') => out.push('/'),
                    Some(b'b') => out.push('\u{8}'),
                    Some(b'f') => out.push('\u{c}'),
                    Some(b'n') => out.push('\n'),
                    Some(b'r') => out.push('\r'),
                    Some(b't') => out.push('\t'),
                    Some(b'u') => {
                        let mut n = self.hex_quad()?;
                        if (0xd800..=0xdbff).contains(&n) {
                            if self.bump() != Some(b'\\') || self.bump() != Some(b'u') {
                                return Err("missing low surrogate".into());
                            }
                            let low = self.hex_quad()?;
                            if !(0xdc00..=0xdfff).contains(&low) {
                                return Err("invalid low surrogate".into());
                            }
                            n = 0x10000 + ((n - 0xd800) << 10) + low - 0xdc00;
                        }
                        out.push(char::from_u32(n).ok_or("invalid Unicode escape")?);
                    }
                    _ => return Err("invalid string escape".into()),
                },
                Some(0..=31) => return Err("unescaped control in string".into()),
                Some(c) if c.is_ascii() => out.push(c as char),
                Some(_) => {
                    let tail =
                        std::str::from_utf8(&self.s[self.i - 1..]).map_err(|_| "invalid UTF-8")?;
                    let ch = tail.chars().next().ok_or("missing character")?;
                    self.i += ch.len_utf8() - 1;
                    out.push(ch);
                }
            }
        }
    }

    fn hex_quad(&mut self) -> Result<u32, String> {
        let mut n = 0;
        for _ in 0..4 {
            let c = self.bump().ok_or("incomplete Unicode escape")? as char;
            n = (n << 4) | c.to_digit(16).ok_or("invalid Unicode escape")?;
        }
        Ok(n)
    }

    fn number(&mut self) -> Result<Json, String> {
        let start = self.i;
        if self.peek() == Some(b'-') {
            self.i += 1;
        }
        while matches!(self.peek(), Some(b'0'..=b'9')) {
            self.i += 1;
        }
        let slice = std::str::from_utf8(&self.s[start..self.i]).unwrap();
        let n: i64 = slice.parse().map_err(|_| format!("bad int {slice}"))?;
        Ok(Json::Int(n))
    }

    fn array(&mut self) -> Result<Json, String> {
        self.bump();
        let mut items = Vec::new();
        self.skip_ws();
        if self.peek() == Some(b']') {
            self.bump();
            return Ok(Json::Arr(items));
        }
        loop {
            items.push(self.value()?);
            self.skip_ws();
            match self.bump() {
                Some(b']') => return Ok(Json::Arr(items)),
                Some(b',') => continue,
                _ => return Err("expected , or ] in array".into()),
            }
        }
    }

    fn object(&mut self) -> Result<Json, String> {
        self.bump();
        let mut map = BTreeMap::new();
        self.skip_ws();
        if self.peek() == Some(b'}') {
            self.bump();
            return Ok(Json::Obj(map));
        }
        loop {
            self.skip_ws();
            let k = self.string()?;
            self.skip_ws();
            if self.bump() != Some(b':') {
                return Err("expected : in object".into());
            }
            let v = self.value()?;
            map.insert(k, v);
            self.skip_ws();
            match self.bump() {
                Some(b'}') => return Ok(Json::Obj(map)),
                Some(b',') => continue,
                _ => return Err("expected , or } in object".into()),
            }
        }
    }
}

pub fn quote_json(s: &str) -> String {
    let mut out = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if c < ' ' || matches!(c, '<' | '>' | '&' | '\u{2028}' | '\u{2029}') => {
                out.push_str(&format!("\\u{:04x}", c as u32));
            }
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strings_roundtrip_and_reject_invalid_escapes() {
        for s in ["αβ", "\"\\\n\r\t\u{8}", "</script>", "\u{1d11e}"] {
            assert_eq!(parse_json(&quote_json(s)).unwrap(), Json::Str(s.into()));
        }
        assert_eq!(
            parse_json(r#""\uD834\uDD1E""#).unwrap(),
            Json::Str("\u{1d11e}".into())
        );
        for s in [
            r#""\uD834x""#,
            r#""\uDD1E""#,
            r#""\q""#,
            r#""\uxxxx""#,
            "\"a\nb\"",
        ] {
            assert!(parse_json(s).is_err(), "{s}");
        }
    }

    #[test]
    fn parses_nested() {
        let v = parse_json(r#"{"a":1,"b":[true,"x"]}"#).unwrap();
        assert_eq!(v.get("a").as_u32(), Some(1));
        match v.get("b") {
            Json::Arr(a) => assert_eq!(a[1].as_str(), Some("x")),
            _ => panic!(),
        }
    }
}
