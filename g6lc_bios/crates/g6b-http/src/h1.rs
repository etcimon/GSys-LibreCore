// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! HTTP/1.1 request/response (RFC 9112 subset). Content-Length bodies.

#![allow(missing_docs)]

use crate::{Request, Response, Version};

/// Parse an HTTP/1.1 request.
pub fn parse(raw: &[u8]) -> Result<Request, String> {
    let s = core::str::from_utf8(raw).map_err(|_| "http1 utf8")?;
    let (head, body) = s.split_once("\r\n\r\n").ok_or("http1 missing header end")?;
    let mut lines = head.split("\r\n");
    let req = lines.next().ok_or("http1 empty")?;
    let mut it = req.splitn(3, ' ');
    let method = it.next().ok_or("http1 method")?.to_string();
    let path = it.next().ok_or("http1 path")?.to_string();
    let ver = it.next().unwrap_or("HTTP/1.1");
    if method.len() > 16 || path.len() > 2048 || path.contains('\0') {
        return Err("http1: request-line".into());
    }
    if !path.starts_with('/') || path.contains("//") || path.contains('\\') {
        return Err("http1: path".into());
    }
    let pl = path.to_ascii_lowercase();
    if pl.contains("%2e.")
        || pl.contains(".%2e")
        || pl.contains("%2e%2e")
        || pl.contains("%2f")
        || pl.contains("%5c")
    {
        return Err("http1: path".into());
    }
    if ver.eq_ignore_ascii_case("HTTP/1.0") {
        return Err("http1: 1.0 refused".into());
    }
    if !ver.eq_ignore_ascii_case("HTTP/1.1") {
        return Err(format!("http1 version {ver}"));
    }
    let mut headers = Vec::new();
    let mut content_len = 0usize;
    let mut has_host = false;
    let mut saw_cl = false;
    let mut nheaders = 0usize;
    for line in lines {
        if line.is_empty() {
            continue;
        }
        if line.len() > 8192 {
            return Err("http1: header too long".into());
        }
        nheaders += 1;
        if nheaders > 64 {
            return Err("http1: too many headers".into());
        }
        let (n, v) = line.split_once(':').ok_or("http1 header")?;
        let name = n.trim().to_ascii_lowercase();
        if name.is_empty()
            || name
                .bytes()
                .any(|b| !(33..=126).contains(&b) || b == b'(' || b == b')')
        {
            return Err("http1: header name".into());
        }
        let val = v.trim().to_string();
        if val.contains('\r') || val.contains('\n') {
            return Err("http1: header value".into());
        }
        if name == "content-length" {
            let nlen: usize = val.parse().map_err(|_| "http1 content-length")?;
            if saw_cl && nlen != content_len {
                return Err("http1: duplicate content-length".into());
            }
            saw_cl = true;
            content_len = nlen;
        }
        if name == "host" {
            if has_host {
                return Err("http1: duplicate host".into());
            }
            if val.contains('@') || val.contains(' ') {
                return Err("http1: host".into());
            }
            if !val.is_empty() {
                has_host = true;
            }
        }
        if name == "transfer-encoding" && val.to_ascii_lowercase().contains("chunked") {
            return Err("http1: chunked refused".into());
        }
        if name == "expect" && val.to_ascii_lowercase().contains("100-continue") {
            return Err("http1: expect continue refused".into());
        }
        headers.push((name, val));
    }
    if ver.eq_ignore_ascii_case("HTTP/1.1") && !has_host {
        return Err("http1: host required".into());
    }
    if content_len > 64 * 1024 {
        return Err("http1: body too long".into());
    }
    let b = body.as_bytes();
    if b.len() < content_len {
        return Err("http1 truncated body".into());
    }
    Ok(Request {
        method,
        path,
        version: Version::Http11,
        headers,
        body: b[..content_len].to_vec(),
    })
}

/// RFC 7540 §3.2 h2c: `Connection: Upgrade` + `Upgrade: h2c`.
pub fn is_h2c_upgrade(req: &Request) -> bool {
    let mut up = false;
    let mut conn = false;
    for (k, v) in &req.headers {
        if k.eq_ignore_ascii_case("upgrade") && v.to_ascii_lowercase().contains("h2c") {
            up = true;
        }
        if k.eq_ignore_ascii_case("connection") && v.to_ascii_lowercase().contains("upgrade") {
            conn = true;
        }
    }
    up && conn
}

/// 101 Switching Protocols for h2c. Next bytes must be the PRI preface.
pub fn h2c_switching_protocols() -> Response {
    let mut r = Response::file(101, "text/plain", Vec::new());
    r.headers.push(("connection".into(), "Upgrade".into()));
    r.headers.push(("upgrade".into(), "h2c".into()));
    r
}

/// Serialize an HTTP/1.1 response.
pub fn encode(resp: &Response) -> Vec<u8> {
    let reason = match resp.status {
        101 => "Switching Protocols",
        200 => "OK",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        429 => "Too Many Requests",
        _ => "Error",
    };
    let mut out = format!("HTTP/1.1 {} {reason}\r\n", resp.status);
    let mut has_len = false;
    for (k, v) in &resp.headers {
        if k.eq_ignore_ascii_case("content-length") {
            has_len = true;
        }
        out.push_str(k);
        out.push_str(": ");
        out.push_str(v);
        out.push_str("\r\n");
    }
    if !has_len {
        out.push_str(&format!("Content-Length: {}\r\n", resp.body.len()));
    }
    out.push_str("\r\n");
    let mut b = out.into_bytes();
    b.extend_from_slice(&resp.body);
    b
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn get_clocks() {
        let raw = b"GET /bios/clocks HTTP/1.1\r\nHost: bios\r\n\r\n";
        let r = parse(raw).unwrap();
        assert_eq!(r.method, "GET");
        assert_eq!(r.path, "/bios/clocks");
        assert_eq!(r.version, Version::Http11);
    }

    #[test]
    fn post_body() {
        let raw = b"POST /bios/custom HTTP/1.1\r\nHost: bios\r\nContent-Length: 4\r\n\r\nABCD";
        let r = parse(raw).unwrap();
        assert_eq!(r.body, b"ABCD");
        assert!(parse(b"GET /bios/clocks HTTP/1.1\r\n\r\n")
            .unwrap_err()
            .contains("host required"));
        assert!(
            parse(b"GET /x HTTP/1.1\r\nHost: bios\r\nTransfer-Encoding: chunked\r\n\r\n")
                .unwrap_err()
                .contains("chunked")
        );
        assert!(
            parse(b"POST /x HTTP/1.1\r\nHost: bios\r\nContent-Length: 99999\r\n\r\n")
                .unwrap_err()
                .contains("body too long")
        );
        assert!(parse(b"GET /x HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n")
            .unwrap_err()
            .contains("duplicate host"));
        assert!(parse(
            b"POST /x HTTP/1.1\r\nHost: bios\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nab"
        )
        .unwrap_err()
        .contains("duplicate content-length"));
        let long = format!("GET /{} HTTP/1.1\r\nHost: bios\r\n\r\n", "a".repeat(2049));
        assert!(parse(long.as_bytes()).unwrap_err().contains("request-line"));
        let hline = format!(
            "GET /x HTTP/1.1\r\nHost: bios\r\nX-Pad: {}\r\n\r\n",
            "x".repeat(8193)
        );
        assert!(parse(hline.as_bytes())
            .unwrap_err()
            .contains("header too long"));
        assert!(parse(b"GET /x HTTP/1.1\r\nHost: user@bios\r\n\r\n")
            .unwrap_err()
            .contains("host"));
        assert!(
            parse(b"GET /x HTTP/1.1\r\nHost: bios\r\nExpect: 100-continue\r\n\r\n")
                .unwrap_err()
                .contains("expect continue")
        );
        assert!(
            parse(b"GET /x HTTP/1.1\r\nBad Name: x\r\nHost: bios\r\n\r\n")
                .unwrap_err()
                .contains("header name")
        );
        assert!(parse(b"GET /x HTTP/1.0\r\nHost: bios\r\n\r\n")
            .unwrap_err()
            .contains("1.0 refused"));
        assert!(parse(b"GET //bios HTTP/1.1\r\nHost: bios\r\n\r\n")
            .unwrap_err()
            .contains("path"));
        let h2c =
            parse(b"GET /x HTTP/1.1\r\nHost: bios\r\nConnection: Upgrade\r\nUpgrade: h2c\r\n\r\n")
                .unwrap();
        assert!(is_h2c_upgrade(&h2c));
        assert!(parse(b"GET /%2e%2e/bios HTTP/1.1\r\nHost: bios\r\n\r\n")
            .unwrap_err()
            .contains("path"));
        assert!(parse(b"GET /x HTTP/1.1\r\nHost: bios\nX\r\n\r\n")
            .unwrap_err()
            .contains("header value"));
        let mut many = String::from("GET /x HTTP/1.1\r\nHost: bios\r\n");
        for i in 0..64 {
            many.push_str(&format!("X-{i}: a\r\n"));
        }
        many.push_str("\r\n");
        assert!(parse(many.as_bytes())
            .unwrap_err()
            .contains("too many headers"));
    }
}
