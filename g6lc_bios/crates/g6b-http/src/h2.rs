// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! HTTP/2 frames (RFC 9113) + HPACK (RFC 7541) static/literal + Huffman.

#![allow(missing_docs)]

use crate::{Request, Response, Version};

pub const PREFACE: &[u8] = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

const FRAME_DATA: u8 = 0;
const FRAME_HEADERS: u8 = 1;
const FRAME_SETTINGS: u8 = 4;
const FRAME_PING: u8 = 6;
const END_STREAM: u8 = 0x01;
const END_HEADERS: u8 = 0x04;
const ACK: u8 = 0x01;

/// RFC 7541 Appendix A (1-based).
const STATIC: &[(&str, &str)] = &[
    (":authority", ""),
    (":method", "GET"),
    (":method", "POST"),
    (":path", "/"),
    (":path", "/index.html"),
    (":scheme", "http"),
    (":scheme", "https"),
    (":status", "200"),
    (":status", "204"),
    (":status", "206"),
    (":status", "304"),
    (":status", "400"),
    (":status", "404"),
    (":status", "500"),
    ("accept-charset", ""),
    ("accept-encoding", "gzip, deflate"),
    ("accept-language", ""),
    ("accept-ranges", ""),
    ("accept", ""),
    ("access-control-allow-origin", ""),
    ("age", ""),
    ("allow", ""),
    ("authorization", ""),
    ("cache-control", ""),
    ("content-disposition", ""),
    ("content-encoding", ""),
    ("content-language", ""),
    ("content-length", ""),
    ("content-location", ""),
    ("content-range", ""),
    ("content-type", ""),
    ("cookie", ""),
    ("date", ""),
    ("etag", ""),
    ("expect", ""),
    ("expires", ""),
    ("from", ""),
    ("host", ""),
    ("if-match", ""),
    ("if-modified-since", ""),
    ("if-none-match", ""),
    ("if-range", ""),
    ("if-unmodified-since", ""),
    ("last-modified", ""),
    ("link", ""),
    ("location", ""),
    ("max-forwards", ""),
    ("proxy-authenticate", ""),
    ("proxy-authorization", ""),
    ("range", ""),
    ("referer", ""),
    ("refresh", ""),
    ("retry-after", ""),
    ("server", ""),
    ("set-cookie", ""),
    ("strict-transport-security", ""),
    ("transfer-encoding", ""),
    ("user-agent", ""),
    ("vary", ""),
    ("via", ""),
    ("www-authenticate", ""),
];

/// RFC 7541 Appendix B Huffman codes (symbol 0..255).
const HUFF_CODE: [u32; 256] = [
    0x1ff8, 0x7fffd8, 0xfffffe2, 0xfffffe3, 0xfffffe4, 0xfffffe5, 0xfffffe6, 0xfffffe7, 0xfffffe8,
    0xffffea, 0x3ffffffc, 0xfffffe9, 0xfffffea, 0x3ffffffd, 0xfffffeb, 0xfffffec, 0xfffffed,
    0xfffffee, 0xfffffef, 0xffffff0, 0xffffff1, 0xffffff2, 0x3ffffffe, 0xffffff3, 0xffffff4,
    0xffffff5, 0xffffff6, 0xffffff7, 0xffffff8, 0xffffff9, 0xffffffa, 0xffffffb, 0x14, 0x3f8,
    0x3f9, 0xffa, 0x1ff9, 0x15, 0xf8, 0x7fa, 0x3fa, 0x3fb, 0xf9, 0x7fb, 0xfa, 0x16, 0x17, 0x18,
    0x0, 0x1, 0x2, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x5c, 0xfb, 0x7ffc, 0x20, 0xffb,
    0x3fc, 0x1ffa, 0x21, 0x5d, 0x5e, 0x5f, 0x60, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
    0x69, 0x6a, 0x6b, 0x6c, 0x6d, 0x6e, 0x6f, 0x70, 0x71, 0x72, 0xfc, 0x73, 0xfd, 0x1ffb, 0x7fff0,
    0x1ffc, 0x3ffc, 0x22, 0x7ffd, 0x3, 0x23, 0x4, 0x24, 0x5, 0x25, 0x26, 0x27, 0x6, 0x74, 0x75,
    0x28, 0x29, 0x2a, 0x7, 0x2b, 0x76, 0x2c, 0x8, 0x9, 0x2d, 0x77, 0x78, 0x79, 0x7a, 0x7b, 0x7ffe,
    0x7fc, 0x3ffd, 0x1ffd, 0xffffffc, 0xfffe6, 0x3fffd2, 0xfffe7, 0xfffe8, 0x3fffd3, 0x3fffd4,
    0x3fffd5, 0x7fffd9, 0x3fffd6, 0x7fffda, 0x7fffdb, 0x7fffdc, 0x7fffdd, 0x7fffde, 0xffffeb,
    0x7fffdf, 0xffffec, 0xffffed, 0x3fffd7, 0x7fffe0, 0xffffee, 0x7fffe1, 0x7fffe2, 0x7fffe3,
    0x7fffe4, 0x1fffdc, 0x3fffd8, 0x7fffe5, 0x3fffd9, 0x7fffe6, 0x7fffe7, 0xffffef, 0x3fffda,
    0x1fffdd, 0xfffe9, 0x3fffdb, 0x3fffdc, 0x7fffe8, 0x7fffe9, 0x1fffde, 0x7fffea, 0x3fffdd,
    0x3fffde, 0xfffff0, 0x1fffdf, 0x3fffdf, 0x7fffeb, 0x7fffec, 0x1fffe0, 0x1fffe1, 0x3fffe0,
    0x1fffe2, 0x7fffed, 0x3fffe1, 0x7fffee, 0x7fffef, 0xfffea, 0x3fffe2, 0x3fffe3, 0x3fffe4,
    0x7ffff0, 0x3fffe5, 0x3fffe6, 0x7ffff1, 0x3ffffe0, 0x3ffffe1, 0xfffeb, 0x7fff1, 0x3fffe7,
    0x7ffff2, 0x3fffe8, 0x1ffffec, 0x3ffffe2, 0x3ffffe3, 0x3ffffe4, 0x7ffffde, 0x7ffffdf,
    0x3ffffe5, 0xfffff1, 0x1ffffed, 0x7fff2, 0x1fffe3, 0x3ffffe6, 0x7ffffe0, 0x7ffffe1, 0x3ffffe7,
    0x7ffffe2, 0xfffff2, 0x1fffe4, 0x1fffe5, 0x3ffffe8, 0x3ffffe9, 0xffffffd, 0x7ffffe3, 0x7ffffe4,
    0x7ffffe5, 0xfffec, 0xfffff3, 0xfffed, 0x1fffe6, 0x3fffe9, 0x1fffe7, 0x1fffe8, 0x7ffff3,
    0x3fffea, 0x3fffeb, 0x1ffffee, 0x1ffffef, 0xfffff4, 0xfffff5, 0x3ffffea, 0x7ffff4, 0x3ffffeb,
    0x7ffffe6, 0x3ffffec, 0x3ffffed, 0x7ffffe7, 0x7ffffe8, 0x7ffffe9, 0x7ffffea, 0x7ffffeb,
    0xffffffe, 0x7ffffec, 0x7ffffed, 0x7ffffee, 0x7ffffef, 0x7fffff0, 0x3ffffee,
];

const HUFF_LEN: [u8; 256] = [
    13, 23, 28, 28, 28, 28, 28, 28, 28, 24, 30, 28, 28, 30, 28, 28, 28, 28, 28, 28, 28, 28, 30, 28,
    28, 28, 28, 28, 28, 28, 28, 28, 6, 10, 10, 12, 13, 6, 8, 11, 10, 10, 8, 11, 8, 6, 6, 6, 5, 5,
    5, 6, 6, 6, 6, 6, 6, 6, 7, 8, 15, 6, 12, 10, 13, 6, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
    7, 7, 7, 7, 7, 7, 7, 7, 8, 7, 8, 13, 19, 13, 14, 6, 15, 5, 6, 5, 6, 5, 6, 6, 6, 5, 7, 7, 6, 6,
    6, 5, 6, 7, 6, 5, 5, 6, 7, 7, 7, 7, 7, 15, 11, 14, 13, 28, 20, 22, 20, 20, 22, 22, 22, 23, 22,
    23, 23, 23, 23, 23, 24, 23, 24, 24, 22, 23, 24, 23, 23, 23, 23, 21, 22, 23, 22, 23, 23, 24, 22,
    21, 20, 22, 22, 23, 23, 21, 23, 22, 22, 24, 21, 22, 23, 23, 21, 21, 22, 21, 23, 22, 23, 23, 20,
    22, 22, 22, 23, 22, 22, 23, 26, 26, 20, 19, 22, 23, 22, 25, 26, 26, 26, 27, 27, 26, 24, 25, 19,
    21, 26, 27, 27, 26, 27, 24, 21, 21, 26, 26, 28, 27, 27, 27, 20, 24, 20, 21, 22, 21, 21, 23, 22,
    22, 25, 25, 24, 24, 26, 23, 26, 27, 26, 26, 27, 27, 27, 27, 27, 28, 27, 27, 27, 27, 27, 26,
];

fn huff_decode(src: &[u8]) -> Result<Vec<u8>, String> {
    let mut acc: u64 = 0;
    let mut nbits: u32 = 0;
    let mut out = Vec::new();
    for &b in src {
        acc = (acc << 8) | u64::from(b);
        nbits += 8;
        loop {
            let mut found = false;
            for (sym, (&code, &len)) in HUFF_CODE.iter().zip(HUFF_LEN.iter()).enumerate() {
                let len = u32::from(len);
                if nbits < len {
                    continue;
                }
                let shift = nbits - len;
                if ((acc >> shift) as u32)
                    & if len == 32 {
                        u32::MAX
                    } else {
                        (1u32 << len) - 1
                    }
                    == code
                {
                    out.push(sym as u8);
                    acc &= if shift >= 64 { 0 } else { (1u64 << shift) - 1 };
                    nbits = shift;
                    found = true;
                    break;
                }
            }
            if !found {
                break;
            }
        }
    }
    Ok(out)
}

struct Cursor<'a> {
    s: &'a [u8],
    i: usize,
}

impl<'a> Cursor<'a> {
    fn new(s: &'a [u8]) -> Self {
        Self { s, i: 0 }
    }
    fn rest(&self) -> &[u8] {
        &self.s[self.i..]
    }
    fn take(&mut self, n: usize) -> Result<&'a [u8], String> {
        if self.i + n > self.s.len() {
            return Err("hpack truncated".into());
        }
        let o = &self.s[self.i..self.i + n];
        self.i += n;
        Ok(o)
    }
}

fn decode_int(c: &mut Cursor, first: u8, prefix: u8) -> Result<usize, String> {
    let mask = (1u8 << prefix) - 1;
    let mut v = usize::from(first & mask);
    if v < usize::from(mask) {
        return Ok(v);
    }
    let mut m = 0u32;
    loop {
        let b = *c.take(1)?.first().ok_or("hpack int")?;
        v += usize::from(b & 0x7f) << m;
        m += 7;
        if b & 0x80 == 0 {
            break;
        }
        if m > 28 {
            return Err("hpack int overflow".into());
        }
    }
    Ok(v)
}

fn decode_str(c: &mut Cursor) -> Result<String, String> {
    let first = *c.take(1)?.first().ok_or("hpack str")?;
    let huff = first & 0x80 != 0;
    let len = decode_int(c, first, 7)?;
    let raw = c.take(len)?;
    let bytes = if huff {
        huff_decode(raw)?
    } else {
        raw.to_vec()
    };
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

fn static_ent(i: usize) -> Result<(&'static str, &'static str), String> {
    STATIC
        .get(i.wrapping_sub(1))
        .copied()
        .ok_or_else(|| "hpack index".into())
}

fn hpack_decode(block: &[u8]) -> Result<Vec<(String, String)>, String> {
    let mut c = Cursor::new(block);
    let mut headers = Vec::new();
    let mut dyn_tab: Vec<(String, String)> = Vec::new();
    while !c.rest().is_empty() {
        let first = *c.take(1)?.first().ok_or("hpack empty")?;
        if first & 0x80 != 0 {
            let idx = decode_int(&mut c, first, 7)?;
            let (n, v) = lookup(idx, &dyn_tab)?;
            headers.push((n, v));
        } else if first & 0x40 != 0 {
            let (n, v) = literal(&mut c, first, 6, &dyn_tab)?;
            dyn_tab.insert(0, (n.clone(), v.clone()));
            headers.push((n, v));
        } else if first & 0xe0 == 0x20 {
            let _sz = decode_int(&mut c, first, 5)?;
        } else {
            let (n, v) = literal(&mut c, first, 4, &dyn_tab)?;
            headers.push((n, v));
        }
    }
    Ok(headers)
}

fn lookup(idx: usize, dyn_tab: &[(String, String)]) -> Result<(String, String), String> {
    if idx == 0 {
        return Err("hpack index 0".into());
    }
    if idx <= STATIC.len() {
        let (n, v) = static_ent(idx)?;
        return Ok((n.into(), v.into()));
    }
    let d = idx - STATIC.len() - 1;
    dyn_tab.get(d).cloned().ok_or_else(|| "hpack dyn".into())
}

fn literal(
    c: &mut Cursor,
    first: u8,
    nbits: u8,
    dyn_tab: &[(String, String)],
) -> Result<(String, String), String> {
    let idx = decode_int(c, first, nbits)?;
    let name = if idx == 0 {
        decode_str(c)?
    } else {
        lookup(idx, dyn_tab)?.0
    };
    let val = decode_str(c)?;
    Ok((name, val))
}

fn frame(kind: u8, flags: u8, stream: u32, payload: &[u8]) -> Vec<u8> {
    let n = payload.len() as u32;
    let mut o = Vec::with_capacity(9 + payload.len());
    o.push(((n >> 16) & 0xff) as u8);
    o.push(((n >> 8) & 0xff) as u8);
    o.push((n & 0xff) as u8);
    o.push(kind);
    o.push(flags);
    o.extend_from_slice(&stream.to_be_bytes());
    o.extend_from_slice(payload);
    o
}

/// Parse HTTP/2 (optional preface) into a request.
pub fn parse(raw: &[u8]) -> Result<Request, String> {
    let mut i = 0usize;
    if raw.starts_with(PREFACE) {
        i = PREFACE.len();
    }
    let mut header_block = Vec::new();
    let mut body = Vec::new();
    while i + 9 <= raw.len() {
        let len = ((raw[i] as usize) << 16) | ((raw[i + 1] as usize) << 8) | raw[i + 2] as usize;
        let kind = raw[i + 3];
        i += 9;
        if i + len > raw.len() {
            return Err("h2 truncated frame".into());
        }
        let payload = &raw[i..i + len];
        i += len;
        match kind {
            FRAME_HEADERS | 9 => header_block.extend_from_slice(payload),
            FRAME_DATA => body.extend_from_slice(payload),
            FRAME_SETTINGS | FRAME_PING => {}
            _ => {}
        }
    }
    let headers = hpack_decode(&header_block)?;
    let mut method = "GET".to_string();
    let mut path = "/".to_string();
    let mut rest = Vec::new();
    for (n, v) in headers {
        match n.as_str() {
            ":method" => method = v,
            ":path" => path = v,
            _ => rest.push((n, v)),
        }
    }
    Ok(Request {
        method,
        path,
        version: Version::Http2,
        headers: rest,
        body,
    })
}

/// Encode a response as HEADERS(:status) + DATA on `stream`.
pub fn encode(resp: &Response, stream: u32) -> Vec<u8> {
    let mut blk = Vec::new();
    let st = match resp.status {
        200 => 8u8,
        204 => 9,
        404 => 13,
        500 => 14,
        _ => 8,
    };
    blk.push(0x80 | st);
    let mut out = frame(FRAME_SETTINGS, ACK, 0, &[]);
    out.extend(frame(FRAME_HEADERS, END_HEADERS, stream, &blk));
    out.extend(frame(FRAME_DATA, END_STREAM, stream, &resp.body));
    out
}

/// Indexed GET + literal :path (no Huffman) for tests.
pub fn client_get(path: &str) -> Vec<u8> {
    let mut blk = vec![0x82];
    blk.push(0x04);
    let pb = path.as_bytes();
    blk.push(pb.len() as u8); // H=0, len in 7 bits
    blk.extend_from_slice(pb);
    let mut out = PREFACE.to_vec();
    out.extend(frame(FRAME_HEADERS, END_HEADERS | END_STREAM, 1, &blk));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn indexed_get_root() {
        // 0x82 = indexed 2 = :method GET; 0x84 = indexed 4 = :path /
        let mut raw = PREFACE.to_vec();
        raw.extend(frame(FRAME_HEADERS, END_HEADERS, 1, &[0x82, 0x84]));
        let r = parse(&raw).unwrap();
        assert_eq!(r.method, "GET");
        assert_eq!(r.path, "/");
        assert_eq!(r.version, Version::Http2);
    }

    #[test]
    fn literal_path() {
        let raw = client_get("/bios/clocks");
        let r = parse(&raw).unwrap();
        assert_eq!(r.method, "GET");
        assert_eq!(r.path, "/bios/clocks");
    }
}
