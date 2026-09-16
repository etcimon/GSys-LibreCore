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

/// Header + body ceilings for a complete response snapshot.
const MAX_HEADER_BYTES: usize = 64 * 1024;
const MAX_BODY_BYTES: usize = 64 * 1024 * 1024;

/// Incremental HTTP/1.1 response parse.
///
/// `NeedMore` means the buffer is a prefix of a framed body (`Content-Length`
/// or chunked). `NeedEof` means headers are complete and the body is
/// close-delimited: only a caller-supplied EOF completes it. Fatal framing
/// errors are `Done` with status 502.
#[derive(Debug, Clone)]
pub enum Http1Parse {
    NeedMore,
    NeedEof,
    Done(Response),
}

/// Parse a complete HTTP/1 response snapshot (`eof = true`).
///
/// Headers are ASCII. The body is copied as bytes (no UTF-8). When
/// `Content-Length` is present the body is exactly that many bytes;
/// a short buffer is truncated (502), extra bytes after the length are
/// ignored. `Transfer-Encoding: chunked` (alone) is decoded; trailers are
/// discarded. Any other coding, or `Content-Length` plus `Transfer-Encoding`,
/// or two disagreeing lengths, is conflicting/refused (502). Close-delimited
/// (no length, no chunked) takes the remainder of this buffer when `eof`.
pub fn parse_http1_response(raw: &[u8]) -> Response {
    match parse_http1_response_partial(raw, true) {
        Http1Parse::Done(r) => r,
        Http1Parse::NeedMore | Http1Parse::NeedEof => {
            Response::file(502, "text/plain", "outbound truncated")
        }
    }
}

/// Parse `raw` as a possibly-partial HTTP/1.1 response.
///
/// `eof` is the caller's claim that no more bytes will arrive (peer close),
/// not idle time. This crate does not read sockets.
pub fn parse_http1_response_partial(raw: &[u8], eof: bool) -> Http1Parse {
    match parse_http1_framed(raw, eof) {
        Ok(p) => p,
        Err(msg) => Http1Parse::Done(Response::file(502, "text/plain", msg)),
    }
}

fn parse_http1_framed(raw: &[u8], eof: bool) -> Result<Http1Parse, String> {
    let Some(end) = header_end(raw) else {
        if raw.len() > MAX_HEADER_BYTES {
            return Err("outbound headers too large".into());
        }
        if eof {
            return Err("outbound truncated".into());
        }
        return Ok(Http1Parse::NeedMore);
    };
    if end > MAX_HEADER_BYTES {
        return Err("outbound headers too large".into());
    }
    let head = &raw[..end - 4];
    let rest = &raw[end..];

    let (status_line, headers) = split_status_line(head)?;
    let status = parse_status_line(status_line)?;

    let mut content_type = "text/html".to_string();
    let mut content_len: Option<usize> = None;
    let mut saw_chunked = false;
    let mut saw_other_te = false;
    let mut location: Option<String> = None;

    for line in headers_lines(headers) {
        if line.is_empty() {
            continue;
        }
        let line = ascii_str(line)?;
        let (name, value) = line.split_once(':').ok_or("outbound header")?;
        let name = name.trim();
        if name.is_empty() {
            return Err("outbound header".into());
        }
        let value = value.trim();
        if name.eq_ignore_ascii_case("content-type") {
            if !value.is_empty() {
                content_type = value.to_string();
            }
        } else if name.eq_ignore_ascii_case("content-length") {
            let n: usize = value.parse().map_err(|_| "outbound content-length")?;
            if let Some(prev) = content_len {
                if prev != n {
                    return Err("outbound conflicting framing".into());
                }
            }
            content_len = Some(n);
        } else if name.eq_ignore_ascii_case("location") {
            if let Some(prev) = location.as_ref() {
                if prev != value {
                    return Err("outbound conflicting location".into());
                }
            }
            location = Some(value.to_string());
        } else if name.eq_ignore_ascii_case("transfer-encoding") {
            for part in value.split(',') {
                let coding = part.trim().split(';').next().unwrap_or("").trim();
                if coding.is_empty() {
                    continue;
                }
                if coding.eq_ignore_ascii_case("chunked") {
                    saw_chunked = true;
                } else {
                    saw_other_te = true;
                }
            }
        }
    }

    if (saw_chunked || saw_other_te) && content_len.is_some() {
        return Err("outbound conflicting framing".into());
    }
    if saw_other_te {
        return Err("outbound transfer-encoding refused".into());
    }

    let body = if saw_chunked {
        match decode_chunked(rest)? {
            Some(b) => b,
            None if eof => return Err("outbound truncated".into()),
            None => return Ok(Http1Parse::NeedMore),
        }
    } else if let Some(len) = content_len {
        if len > MAX_BODY_BYTES {
            return Err("outbound body too large".into());
        }
        if rest.len() < len {
            if eof {
                return Err("outbound truncated".into());
            }
            return Ok(Http1Parse::NeedMore);
        }
        rest[..len].to_vec()
    } else {
        if rest.len() > MAX_BODY_BYTES {
            return Err("outbound body too large".into());
        }
        if !eof {
            return Ok(Http1Parse::NeedEof);
        }
        rest.to_vec()
    };

    let mut resp = Response::file(status, &content_type, body);
    if let Some(loc) = location {
        resp.headers.push(("location".into(), loc));
    }
    Ok(Http1Parse::Done(resp))
}

/// 301/302/303/307/308.
pub fn is_redirect(status: u16) -> bool {
    matches!(status, 301 | 302 | 303 | 307 | 308)
}

/// Next hop from `Location`. Same-origin only. HTTPS must not become HTTP.
/// Does not fetch. Relative paths stay on `from`.
pub fn redirect_hop(from: &OutboundReq, location: &str) -> Result<OutboundReq, String> {
    let location = location.trim();
    if location.is_empty() {
        return Err("redirect: missing location".into());
    }
    if location.contains('\\') || location.chars().any(char::is_control) {
        return Err("redirect: location refused".into());
    }
    if location.starts_with('/') {
        if location.split('/').any(|p| p == "..") {
            return Err("redirect: path refused".into());
        }
        let mut next = from.clone();
        next.path = location.split('#').next().unwrap_or(location).to_string();
        return Ok(next);
    }
    let next = plan(location)?;
    if from.https && !next.https {
        return Err("redirect: https downgrade".into());
    }
    if next.https != from.https || next.host != from.host || next.port != from.port {
        return Err("redirect: origin mismatch".into());
    }
    Ok(next)
}

fn header_end(raw: &[u8]) -> Option<usize> {
    raw.windows(4).position(|w| w == b"\r\n\r\n").map(|i| i + 4)
}

fn split_status_line(head: &[u8]) -> Result<(&[u8], &[u8]), String> {
    match head.windows(2).position(|w| w == b"\r\n") {
        Some(at) => Ok((&head[..at], &head[at + 2..])),
        None => Ok((head, b"")),
    }
}

fn headers_lines(headers: &[u8]) -> impl Iterator<Item = &[u8]> {
    let mut rest = headers;
    core::iter::from_fn(move || {
        if rest.is_empty() {
            return None;
        }
        match rest.windows(2).position(|w| w == b"\r\n") {
            Some(at) => {
                let line = &rest[..at];
                rest = &rest[at + 2..];
                Some(line)
            }
            None => {
                let line = rest;
                rest = b"";
                Some(line)
            }
        }
    })
}

fn ascii_str(bytes: &[u8]) -> Result<&str, String> {
    if !bytes.is_ascii() {
        return Err("outbound header".into());
    }
    core::str::from_utf8(bytes).map_err(|_| "outbound header".into())
}

/// `Ok(None)` means the chunked prefix is incomplete, not fatal.
fn decode_chunked(mut rest: &[u8]) -> Result<Option<Vec<u8>>, String> {
    let mut body = Vec::new();
    loop {
        let Some(at) = rest.windows(2).position(|w| w == b"\r\n") else {
            return Ok(None);
        };
        if at > 128 {
            return Err("outbound chunk-size".into());
        }
        let line = ascii_str(&rest[..at])?;
        rest = &rest[at + 2..];
        let size_str = line.split(';').next().unwrap_or(line).trim();
        if size_str.is_empty() || !size_str.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err("outbound chunk-size".into());
        }
        let size = usize::from_str_radix(size_str, 16).map_err(|_| "outbound chunk-size")?;
        if size == 0 {
            if rest.starts_with(b"\r\n") {
                return Ok(Some(body));
            }
            let Some(end) = rest.windows(4).position(|w| w == b"\r\n\r\n") else {
                return Ok(None);
            };
            if !rest[..end].is_ascii() {
                return Err("outbound header".into());
            }
            return Ok(Some(body));
        }
        if body.len().saturating_add(size) > MAX_BODY_BYTES {
            return Err("outbound body too large".into());
        }
        if rest.len() < size + 2 {
            return Ok(None);
        }
        body.extend_from_slice(&rest[..size]);
        rest = &rest[size..];
        if !rest.starts_with(b"\r\n") {
            return Err("outbound chunk framing".into());
        }
        rest = &rest[2..];
    }
}

fn parse_status_line(line: &[u8]) -> Result<u16, String> {
    let s = ascii_str(line)?;
    let mut it = s.splitn(3, ' ');
    let ver = it.next().ok_or("outbound status")?;
    if !ver.eq_ignore_ascii_case("HTTP/1.1") && !ver.eq_ignore_ascii_case("HTTP/1.0") {
        return Err("outbound version".into());
    }
    let code = it.next().ok_or("outbound status")?;
    if code.len() != 3 || !code.bytes().all(|b| b.is_ascii_digit()) {
        return Err("outbound status".into());
    }
    code.parse().map_err(|_| "outbound status".into())
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
    fn parse_http1_preserves_binary_body() {
        let raw = b"HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 4\r\n\r\n\x00\xff\xfe\x80";
        let r = parse_http1_response(raw);
        assert_eq!(r.status, 200);
        assert_eq!(r.body, [0x00, 0xff, 0xfe, 0x80]);
    }

    #[test]
    fn parse_http1_content_length_drops_extra() {
        let raw = b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nABCDXXXX";
        let r = parse_http1_response(raw);
        assert_eq!(r.status, 200);
        assert_eq!(r.body, b"ABCD");
    }

    #[test]
    fn parse_http1_short_content_length_is_truncated() {
        let raw = b"HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\nABCD";
        let r = parse_http1_response(raw);
        assert_eq!(r.status, 502);
        assert_eq!(r.body_str(), "outbound truncated");
    }

    #[test]
    fn parse_http1_rejects_content_length_and_chunked() {
        let raw = b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\nABCD";
        let r = parse_http1_response(raw);
        assert_eq!(r.status, 502);
        assert_eq!(r.body_str(), "outbound conflicting framing");
    }

    #[test]
    fn parse_http1_decodes_chunked_body() {
        let raw = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nABCD\r\n0\r\n\r\n";
        let r = parse_http1_response(raw);
        assert_eq!(r.status, 200);
        assert_eq!(r.body, b"ABCD");
    }

    #[test]
    fn parse_http1_chunked_preserves_binary() {
        let raw = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Type: application/octet-stream\r\n\r\n4\r\n\x00\xff\xfe\x80\r\n0\r\n\r\n";
        let r = parse_http1_response(raw);
        assert_eq!(r.status, 200);
        assert_eq!(r.body, [0x00, 0xff, 0xfe, 0x80]);
    }

    #[test]
    fn parse_http1_chunked_joins_chunks_and_drops_trailers() {
        let raw = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\nX-Checksum: dead\r\n\r\n";
        let r = parse_http1_response(raw);
        assert_eq!(r.status, 200);
        assert_eq!(r.body, b"hello world");
    }

    #[test]
    fn parse_http1_chunked_truncated_is_refused() {
        let raw = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n8\r\nABCD";
        let r = parse_http1_response(raw);
        assert_eq!(r.status, 502);
        assert_eq!(r.body_str(), "outbound truncated");
    }

    #[test]
    fn parse_http1_gzip_chunked_is_refused() {
        let raw =
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n4\r\nABCD\r\n0\r\n\r\n";
        let r = parse_http1_response(raw);
        assert_eq!(r.status, 502);
        assert_eq!(r.body_str(), "outbound transfer-encoding refused");
    }

    #[test]
    fn parse_http1_rejects_disagreeing_content_lengths() {
        let raw = b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\nContent-Length: 5\r\n\r\nABCDE";
        let r = parse_http1_response(raw);
        assert_eq!(r.status, 502);
        assert_eq!(r.body_str(), "outbound conflicting framing");
    }

    #[test]
    fn parse_http1_missing_separator_is_truncated() {
        let raw = b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\nABCD";
        let r = parse_http1_response(raw);
        assert_eq!(r.status, 502);
        assert_eq!(r.body_str(), "outbound truncated");
    }

    fn done_body(p: Http1Parse) -> Vec<u8> {
        match p {
            Http1Parse::Done(r) => {
                assert_eq!(r.status, 200, "{}", r.body_str());
                r.body
            }
            other => panic!("expected Done, got {other:?}"),
        }
    }

    #[test]
    fn parse_http1_partial_headers_need_more() {
        let raw = b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n";
        assert!(matches!(
            parse_http1_response_partial(raw, false),
            Http1Parse::NeedMore
        ));
        let r = parse_http1_response_partial(raw, true);
        match r {
            Http1Parse::Done(resp) => {
                assert_eq!(resp.status, 502);
                assert_eq!(resp.body_str(), "outbound truncated");
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn parse_http1_partial_content_length_needs_more() {
        let raw = b"HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\nABCD";
        assert!(matches!(
            parse_http1_response_partial(raw, false),
            Http1Parse::NeedMore
        ));
        let full = b"HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\nABCDEFGH";
        assert_eq!(
            done_body(parse_http1_response_partial(full, false)),
            b"ABCDEFGH"
        );
    }

    #[test]
    fn parse_http1_partial_chunked_needs_more_until_last_chunk() {
        let prefix = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nABCD\r\n";
        assert!(matches!(
            parse_http1_response_partial(prefix, false),
            Http1Parse::NeedMore
        ));
        let full = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nABCD\r\n0\r\n\r\n";
        assert_eq!(
            done_body(parse_http1_response_partial(full, false)),
            b"ABCD"
        );
    }

    #[test]
    fn parse_http1_close_delimited_needs_eof() {
        let raw = b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nhello";
        assert!(matches!(
            parse_http1_response_partial(raw, false),
            Http1Parse::NeedEof
        ));
        assert_eq!(done_body(parse_http1_response_partial(raw, true)), b"hello");
    }

    #[test]
    fn parse_http1_partial_conflicting_framing_fails_before_body() {
        let raw = b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n";
        match parse_http1_response_partial(raw, false) {
            Http1Parse::Done(r) => {
                assert_eq!(r.status, 502);
                assert_eq!(r.body_str(), "outbound conflicting framing");
            }
            other => panic!("{other:?}"),
        }
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

    #[test]
    fn redirect_hop_same_origin_only() {
        let from = plan("http://10.0.2.2/fw.bin").unwrap();
        let rel = redirect_hop(&from, "/other.bin").unwrap();
        assert_eq!(rel.host, "10.0.2.2");
        assert_eq!(rel.path, "/other.bin");
        assert!(!rel.https);
        let abs = redirect_hop(&from, "http://10.0.2.2/other.bin").unwrap();
        assert_eq!(abs.path, "/other.bin");
        assert!(
            redirect_hop(&from, "http://evil.example/x")
                .unwrap_err()
                .contains("origin")
        );
        let https = plan("https://10.0.2.2/fw.bin").unwrap();
        assert!(
            redirect_hop(&https, "http://10.0.2.2/fw.bin")
                .unwrap_err()
                .contains("downgrade")
        );
        assert!(redirect_hop(&from, "http://user@10.0.2.2/x").is_err());
        assert!(redirect_hop(&from, "/../etc").unwrap_err().contains("path"));
        assert!(redirect_hop(&from, "").unwrap_err().contains("missing"));
        let r = parse_http1_response(
            b"HTTP/1.1 302 Found\r\nLocation: http://evil.example/x\r\nContent-Length: 0\r\n\r\n",
        );
        assert_eq!(r.status, 302);
        assert_eq!(
            r.headers
                .iter()
                .find(|(k, _)| k == "location")
                .map(|(_, v)| v.as_str()),
            Some("http://evil.example/x")
        );
    }
}
