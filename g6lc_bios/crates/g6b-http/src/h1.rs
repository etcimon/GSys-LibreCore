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
    if !ver.eq_ignore_ascii_case("HTTP/1.1") && !ver.eq_ignore_ascii_case("HTTP/1.0") {
        return Err(format!("http1 version {ver}"));
    }
    let mut headers = Vec::new();
    let mut content_len = 0usize;
    for line in lines {
        if line.is_empty() {
            continue;
        }
        let (n, v) = line.split_once(':').ok_or("http1 header")?;
        let name = n.trim().to_ascii_lowercase();
        let val = v.trim().to_string();
        if name == "content-length" {
            content_len = val.parse().map_err(|_| "http1 content-length")?;
        }
        headers.push((name, val));
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

/// Serialize an HTTP/1.1 response.
pub fn encode(resp: &Response) -> Vec<u8> {
    let reason = match resp.status {
        200 => "OK",
        404 => "Not Found",
        405 => "Method Not Allowed",
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
        let raw = b"POST /bios/custom HTTP/1.1\r\nContent-Length: 4\r\n\r\nABCD";
        let r = parse(raw).unwrap();
        assert_eq!(r.body, b"ABCD");
    }
}
