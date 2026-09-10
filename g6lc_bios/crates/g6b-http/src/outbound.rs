// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Outbound `http(s):` **plan** for iframe / JS / HolyC fetch (`plan-iframe.md`
//! §6.2). Live sockets belong to the **kernel**, which lowers onto `g6b-hw`
//! TCP/IP. This crate does not open sockets and does not speak TLS.

use crate::Response;

/// Parsed remote URL. Transport is the kernel's job.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OutboundReq {
    pub https: bool,
    pub host: String,
    pub port: u16,
    pub path: String,
}

/// GET a remote `http:` / `https:` URL **without** a socket: HTTPS is the
/// TLS adapter (ClientHello), HTTP is the kernel hw-tcp path. Callers that
/// need a real GET go through `BrowserSession` / `KernelHost`.
pub fn get(url: &str) -> Response {
    match plan(url) {
        Err(e) => Response::file(400, "text/plain", e),
        Ok(u) if u.https => Response::file(
            501,
            "text/plain",
            "outbound https: adapter TLS (g6b-tls ClientHello)",
        ),
        Ok(_) => Response::file(501, "text/plain", "outbound http: kernel hw-tcp"),
    }
}

/// Parse and refuse-closed a remote `http(s):` URL.
pub fn plan(url: &str) -> Result<OutboundReq, String> {
    let url = url.trim();
    if url.chars().any(char::is_control) || url.contains('\\') {
        return Err("outbound url refused".into());
    }
    let https = if url.starts_with("https://") {
        true
    } else if url.starts_with("http://") {
        false
    } else {
        return Err("outbound url must be http(s)".into());
    };
    let rest = url.split_once("://").map(|(_, r)| r).unwrap_or(url);
    if rest.starts_with('/') || rest.starts_with('[') {
        return Err("outbound host refused".into());
    }
    let (hostport, pathq) = rest.split_once('/').unwrap_or((rest, ""));
    if hostport.is_empty() || hostport.contains('@') {
        return Err("outbound host refused".into());
    }
    let (host, port) = if let Some((h, p)) = hostport.split_once(':') {
        let port: u16 = p.parse().map_err(|_| "outbound port refused")?;
        (h.to_string(), port)
    } else {
        (hostport.to_string(), if https { 443 } else { 80 })
    };
    if host.is_empty()
        || host == "."
        || host == ".."
        || host.contains('/')
        || !host
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-')
    {
        return Err("outbound host refused".into());
    }
    let mut path = String::from("/");
    path.push_str(pathq.split('#').next().unwrap_or(pathq));
    if path.split('/').any(|p| p == "..") {
        return Err("outbound path refused".into());
    }
    Ok(OutboundReq {
        https,
        host,
        port,
        path,
    })
}

/// HTTP/1.1 GET bytes the kernel writes onto an hw TCP socket.
pub fn http1_get_request(u: &OutboundReq) -> Vec<u8> {
    format!(
        "GET {} HTTP/1.1\r\nHost: {}\r\nConnection: close\r\nUser-Agent: g6lc-bios\r\n\r\n",
        u.path, u.host
    )
    .into_bytes()
}

pub fn parse_http1_response(raw: &[u8]) -> Response {
    let text = String::from_utf8_lossy(raw);
    let Some((head, body)) = text.split_once("\r\n\r\n") else {
        return Response::file(502, "text/plain", "outbound truncated");
    };
    let status = head
        .split_whitespace()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(502);
    let ct = head
        .lines()
        .find(|l| l.to_ascii_lowercase().starts_with("content-type:"))
        .map(|l| {
            l.split_once(':')
                .map(|(_, v)| v.trim())
                .unwrap_or("text/html")
        })
        .unwrap_or("text/html");
    Response::file(status, ct, body.as_bytes().to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_and_refuses() {
        let u = plan("https://example/path").unwrap();
        assert!(u.https && u.host == "example" && u.port == 443 && u.path == "/path");
        let h = plan("http://localhost:8080/ui/help.html").unwrap();
        assert!(!h.https && h.port == 8080 && h.path == "/ui/help.html");
        assert!(plan("javascript:alert(1)").is_err());
        assert!(plan("https://user@host/").is_err());
        assert!(plan("http://ex/../etc").is_err());
        let req = http1_get_request(&h);
        let s = String::from_utf8(req).unwrap();
        assert!(s.starts_with("GET /ui/help.html HTTP/1.1"), "{s}");
        assert!(s.contains("Host: localhost"), "{s}");
    }

    #[test]
    fn parse_http1_body_without_network() {
        let raw = b"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html>ok</html>";
        let r = parse_http1_response(raw);
        assert_eq!(r.status, 200);
        assert_eq!(r.body_str(), "<html>ok</html>");
    }

    #[test]
    fn https_is_adapter_not_openssl() {
        let r = get("https://example/path");
        assert_eq!(r.status, 501);
        assert!(r.body_str().contains("adapter TLS"), "{}", r.body_str());
        assert!(!r.body_str().to_ascii_lowercase().contains("openssl"));
        let h = get("http://example/path");
        assert_eq!(h.status, 501);
        assert!(h.body_str().contains("kernel hw-tcp"), "{}", h.body_str());
    }
}
