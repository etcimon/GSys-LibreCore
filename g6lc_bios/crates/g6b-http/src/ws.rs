// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! RFC 6455 WebSocket upgrade. Origin must match. Not a KVM frame pump.

#![allow(missing_docs)]

use g6b_tls::sha1;

use crate::{Request, Response};

const MAGIC: &[u8] = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

fn b64(data: &[u8]) -> String {
    const A: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    let mut i = 0;
    while i < data.len() {
        let b0 = data[i];
        let b1 = if i + 1 < data.len() { data[i + 1] } else { 0 };
        let b2 = if i + 2 < data.len() { data[i + 2] } else { 0 };
        let n = ((b0 as u32) << 16) | ((b1 as u32) << 8) | (b2 as u32);
        out.push(A[((n >> 18) & 63) as usize] as char);
        out.push(A[((n >> 12) & 63) as usize] as char);
        if i + 1 < data.len() {
            out.push(A[((n >> 6) & 63) as usize] as char);
        } else {
            out.push('=');
        }
        if i + 2 < data.len() {
            out.push(A[(n & 63) as usize] as char);
        } else {
            out.push('=');
        }
        i += 3;
    }
    out
}

fn header<'a>(req: &'a Request, name: &str) -> Option<&'a str> {
    req.headers
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case(name))
        .map(|(_, v)| v.as_str())
}

/// 101 Switching Protocols if Origin matches `allowed` (https origin).
pub fn upgrade(req: &Request, allowed_origin: &str) -> Result<Response, String> {
    if !req.method.eq_ignore_ascii_case("GET") {
        return Err("ws: GET required".into());
    }
    let up = header(req, "upgrade").unwrap_or("");
    if !up.eq_ignore_ascii_case("websocket") {
        return Err("ws: upgrade".into());
    }
    let origin = header(req, "origin").unwrap_or("");
    if origin != allowed_origin {
        return Err("ws: origin".into());
    }
    if !allowed_origin.starts_with("https://") {
        return Err("ws: origin must be https".into());
    }
    let ver = header(req, "sec-websocket-version").unwrap_or("");
    if ver != "13" {
        return Err("ws: version".into());
    }
    let key = header(req, "sec-websocket-key").ok_or("ws: key")?;
    if key.is_empty() {
        return Err("ws: key".into());
    }
    let mut buf = key.as_bytes().to_vec();
    buf.extend_from_slice(MAGIC);
    let accept = b64(&sha1(&buf));
    let mut r = Response::json(101, "{\"ok\":true,\"ws\":true}");
    r.headers.push(("upgrade".into(), "websocket".into()));
    r.headers.push(("connection".into(), "Upgrade".into()));
    r.headers.push(("sec-websocket-accept".into(), accept));
    Ok(r)
}

const MAX_FRAME: usize = 64 * 1024;
const MAX_Q: usize = 4;

/// Server-to-client unmasked frame. Payload > 64 KiB refused.
pub fn encode_frame(opcode: u8, payload: &[u8]) -> Result<Vec<u8>, String> {
    if payload.len() > MAX_FRAME {
        return Err("ws: frame too long".into());
    }
    if !matches!(opcode, 1 | 8 | 9 | 10) {
        return Err("ws: opcode".into());
    }
    let mut v = vec![0x80 | opcode];
    if payload.len() < 126 {
        v.push(payload.len() as u8);
    } else {
        v.push(126);
        v.extend_from_slice(&(payload.len() as u16).to_be_bytes());
    }
    v.extend_from_slice(payload);
    Ok(v)
}

pub fn encode_ping(payload: &[u8]) -> Result<Vec<u8>, String> {
    if payload.len() > 125 {
        return Err("ws: ping too long".into());
    }
    encode_frame(9, payload)
}

pub fn encode_pong(payload: &[u8]) -> Result<Vec<u8>, String> {
    if payload.len() > 125 {
        return Err("ws: pong too long".into());
    }
    encode_frame(10, payload)
}

/// Close frame. 1005/1006/1015 are reserved and refused.
pub fn encode_close(code: u16) -> Result<Vec<u8>, String> {
    if code < 1000 || matches!(code, 1004 | 1005 | 1006 | 1015) {
        return Err("ws: close code".into());
    }
    encode_frame(8, &code.to_be_bytes())
}

/// Decode one unmasked or masked frame. Not a KVM pixel pump.
pub fn decode_frame(raw: &[u8]) -> Result<(u8, Vec<u8>), String> {
    if raw.len() < 2 {
        return Err("ws: short".into());
    }
    if raw[0] & 0x70 != 0 {
        return Err("ws: rsv".into());
    }
    let opcode = raw[0] & 0x0f;
    if !matches!(opcode, 1 | 8 | 9 | 10) {
        return Err("ws: opcode".into());
    }
    if matches!(opcode, 8 | 9 | 10) && raw[0] & 0x80 == 0 {
        return Err("ws: control fin".into());
    }
    let masked = raw[1] & 0x80 != 0;
    let mut len = (raw[1] & 0x7f) as usize;
    let mut i = 2;
    if len == 126 {
        if raw.len() < 4 {
            return Err("ws: short".into());
        }
        len = u16::from_be_bytes([raw[2], raw[3]]) as usize;
        i = 4;
    } else if len == 127 {
        return Err("ws: 64-bit length refused".into());
    }
    if matches!(opcode, 8 | 9 | 10) && len > 125 {
        return Err("ws: control too long".into());
    }
    if len > MAX_FRAME {
        return Err("ws: frame too long".into());
    }
    if masked {
        if raw.len() < i + 4 + len {
            return Err("ws: short".into());
        }
        let m = &raw[i..i + 4];
        i += 4;
        let mut p = raw[i..i + len].to_vec();
        for (j, b) in p.iter_mut().enumerate() {
            *b ^= m[j % 4];
        }
        if opcode == 8 && p.len() == 1 {
            return Err("ws: close payload".into());
        }
        if opcode == 1 && core::str::from_utf8(&p).is_err() {
            return Err("ws: utf8".into());
        }
        Ok((opcode, p))
    } else {
        if raw.len() < i + len {
            return Err("ws: short".into());
        }
        let p = raw[i..i + len].to_vec();
        if opcode == 8 && p.len() == 1 {
            return Err("ws: close payload".into());
        }
        if opcode == 1 && core::str::from_utf8(&p).is_err() {
            return Err("ws: utf8".into());
        }
        Ok((opcode, p))
    }
}

/// Bounded inbound queue. Full queue is backpressure, not drop-oldest.
#[derive(Debug, Default)]
pub struct WsInbox {
    q: Vec<Vec<u8>>,
}

impl WsInbox {
    pub fn push(&mut self, payload: Vec<u8>) -> Result<(), String> {
        if payload.len() > MAX_FRAME {
            return Err("ws: frame too long".into());
        }
        if self.q.len() >= MAX_Q {
            return Err("ws: backpressure".into());
        }
        self.q.push(payload);
        Ok(())
    }

    pub fn pop(&mut self) -> Option<Vec<u8>> {
        if self.q.is_empty() {
            None
        } else {
            Some(self.q.remove(0))
        }
    }

    pub fn len(&self) -> usize {
        self.q.len()
    }

    pub fn is_empty(&self) -> bool {
        self.q.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Version;

    fn req(origin: &str, key: &str) -> Request {
        Request {
            method: "GET".into(),
            path: "/bios/kvm".into(),
            version: Version::Http11,
            headers: vec![
                ("upgrade".into(), "websocket".into()),
                ("origin".into(), origin.into()),
                ("sec-websocket-version".into(), "13".into()),
                ("sec-websocket-key".into(), key.into()),
            ],
            body: Vec::new(),
        }
    }

    #[test]
    fn rfc6455_accept_and_origin() {
        let r = upgrade(
            &req("https://bios.local", "dGhlIHNhbXBsZSBub25jZQ=="),
            "https://bios.local",
        )
        .unwrap();
        assert_eq!(r.status, 101);
        let acc = r
            .headers
            .iter()
            .find(|(k, _)| k == "sec-websocket-accept")
            .map(|(_, v)| v.as_str())
            .unwrap();
        assert_eq!(acc, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");
        assert!(upgrade(
            &req("https://evil.example", "dGhlIHNhbXBsZSBub25jZQ=="),
            "https://bios.local"
        )
        .unwrap_err()
        .contains("origin"));
        assert!(upgrade(
            &req("http://bios.local", "dGhlIHNhbXBsZSBub25jZQ=="),
            "http://bios.local"
        )
        .unwrap_err()
        .contains("https"));
    }

    #[test]
    fn ws_frame_backpressure_and_bound() {
        let f = encode_frame(1, b"hi").unwrap();
        let (op, p) = decode_frame(&f).unwrap();
        assert_eq!(op, 1);
        assert_eq!(p, b"hi");
        let bad = encode_frame(1, &[0xff, 0xfe]).unwrap();
        assert!(decode_frame(&bad).unwrap_err().contains("utf8"));
        assert!(encode_frame(1, &vec![0; MAX_FRAME + 1]).is_err());
        assert!(encode_frame(2, b"px").unwrap_err().contains("opcode"));
        let bin = encode_frame(1, b"hi").unwrap();
        let mut rsv = bin.clone();
        rsv[0] |= 0x40;
        assert!(decode_frame(&rsv).unwrap_err().contains("rsv"));
        let cl = encode_close(1000).unwrap();
        let (op, p) = decode_frame(&cl).unwrap();
        assert_eq!(op, 8);
        assert_eq!(p, 1000u16.to_be_bytes());
        assert!(encode_close(1005).unwrap_err().contains("close code"));
        assert!(encode_close(999).unwrap_err().contains("close code"));
        assert!(encode_close(1004).unwrap_err().contains("close code"));
        assert!(decode_frame(&[0x88, 1, 0])
            .unwrap_err()
            .contains("close payload"));
        assert!(encode_close(1006).unwrap_err().contains("close code"));
        let mut nofin = encode_ping(b"hi").unwrap();
        nofin[0] &= 0x7f;
        assert!(decode_frame(&nofin).unwrap_err().contains("control fin"));
        assert!(decode_frame(&[0x89, 126, 0, 126])
            .unwrap_err()
            .contains("control too long"));
        let ping = encode_ping(b"hi").unwrap();
        let (op, p) = decode_frame(&ping).unwrap();
        assert_eq!(op, 9);
        assert_eq!(p, b"hi");
        let pong = encode_pong(&p).unwrap();
        let (op2, p2) = decode_frame(&pong).unwrap();
        assert_eq!(op2, 10);
        assert_eq!(p2, b"hi");
        let mut q = WsInbox::default();
        for _ in 0..MAX_Q {
            q.push(b"x".to_vec()).unwrap();
        }
        assert!(q.push(b"y".to_vec()).unwrap_err().contains("backpressure"));
        assert_eq!(q.pop().unwrap(), b"x");
        q.push(b"z".to_vec()).unwrap();
    }
}
