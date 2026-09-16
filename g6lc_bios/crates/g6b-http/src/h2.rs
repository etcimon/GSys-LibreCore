// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! HTTP/2 (RFC 9113) + HPACK static/literal + Huffman.
//! Higher-level selection prefers H2 over HTTP/1.1 when both are on.
//! ALPN `h2` and h2c Upgrade are selected above this module. Live `H2Session`
//! multiplexes odd streams, CONTINUATION across TCP chunks, receive
//! flow-control, and send WINDOW_UPDATE / respond. Not CSPRNG, CT, VNC,
//! SPI, or live OpenWrt.

#![allow(missing_docs)]

use std::collections::BTreeMap;

use crate::{Request, Response, Version};

pub const PREFACE: &[u8] = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

const FRAME_DATA: u8 = 0;
const FRAME_HEADERS: u8 = 1;
const FRAME_PRIORITY: u8 = 2;
const FRAME_RST: u8 = 3;
const FRAME_SETTINGS: u8 = 4;
const FRAME_PUSH: u8 = 5;
const FRAME_PING: u8 = 6;
const FRAME_GOAWAY: u8 = 7;
const FRAME_WINDOW: u8 = 8;
const FRAME_CONTINUATION: u8 = 9;
const END_STREAM: u8 = 0x01;
const END_HEADERS: u8 = 0x04;
const PADDED: u8 = 0x08;
const ACK: u8 = 0x01;
const PRIORITY_FLAG: u8 = 0x20;
const MAX_FRAME: usize = 16 * 1024;

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
    String::from_utf8(bytes).map_err(|_| "hpack utf8".into())
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
            if dyn_tab.len() > 32 {
                dyn_tab.pop();
            }
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

/// One preface, one odd request stream. Encoded responses use `stream`.
#[derive(Debug)]
pub struct H2Exchange {
    pub stream: u32,
    pub req: Request,
}

/// Parse HTTP/2 preface + frames into a request. Preface is required.
pub fn parse(raw: &[u8]) -> Result<Request, String> {
    Ok(parse_exchange(raw)?.req)
}

pub fn parse_exchange(raw: &[u8]) -> Result<H2Exchange, String> {
    if !raw.starts_with(PREFACE) {
        return Err("h2: preface required".into());
    }
    let mut i = PREFACE.len();
    let mut header_block = Vec::new();
    let mut body = Vec::new();
    let mut req_stream: Option<u32> = None;
    let mut want_cont = false;
    let mut headers_done = false;
    let mut max_frame = MAX_FRAME;
    while i + 9 <= raw.len() {
        let len = ((raw[i] as usize) << 16) | ((raw[i + 1] as usize) << 8) | raw[i + 2] as usize;
        if len > max_frame {
            return Err("h2: frame too long".into());
        }
        let kind = raw[i + 3];
        let flags = raw[i + 4];
        let stream = u32::from_be_bytes([raw[i + 5] & 0x7f, raw[i + 6], raw[i + 7], raw[i + 8]]);
        i += 9;
        if i + len > raw.len() {
            return Err("h2 truncated frame".into());
        }
        let payload = &raw[i..i + len];
        i += len;
        match kind {
            FRAME_HEADERS => {
                if stream == 0 || stream % 2 == 0 {
                    return Err("h2: stream".into());
                }
                if flags & (PADDED | PRIORITY_FLAG) != 0 {
                    return Err("h2: padded/priority refused".into());
                }
                if want_cont {
                    return Err("h2: expected continuation".into());
                }
                if let Some(s) = req_stream {
                    if s != stream {
                        return Err("h2: one stream".into());
                    }
                }
                req_stream = Some(stream);
                header_block.extend_from_slice(payload);
                headers_done = flags & END_HEADERS != 0;
                want_cont = !headers_done;
            }
            FRAME_CONTINUATION => {
                if !want_cont || req_stream != Some(stream) {
                    return Err("h2: continuation".into());
                }
                header_block.extend_from_slice(payload);
                headers_done = flags & END_HEADERS != 0;
                want_cont = !headers_done;
            }
            FRAME_DATA => {
                if req_stream != Some(stream) || !headers_done {
                    return Err("h2: data".into());
                }
                if flags & PADDED != 0 {
                    return Err("h2: padded/priority refused".into());
                }
                body.extend_from_slice(payload);
            }
            FRAME_SETTINGS => {
                if stream != 0 {
                    return Err("h2: settings stream".into());
                }
                if flags & ACK != 0 {
                    if !payload.is_empty() {
                        return Err("h2: settings ack".into());
                    }
                } else if payload.len() % 6 != 0 || payload.len() > 6 * 16 {
                    return Err("h2: settings".into());
                } else {
                    let mut k = 0;
                    while k + 6 <= payload.len() {
                        let id = u16::from_be_bytes([payload[k], payload[k + 1]]);
                        let val = u32::from_be_bytes([
                            payload[k + 2],
                            payload[k + 3],
                            payload[k + 4],
                            payload[k + 5],
                        ]);
                        if id == 2 && val != 0 {
                            return Err("h2: push refused".into());
                        }
                        if id == 5 {
                            if val < 16384 || val > 16_777_215 {
                                return Err("h2: max frame".into());
                            }
                            max_frame = max_frame.min(val as usize);
                        }
                        k += 6;
                    }
                }
            }
            FRAME_PING => {
                if stream != 0 || payload.len() != 8 {
                    return Err("h2: ping".into());
                }
            }
            FRAME_WINDOW => {
                if payload.len() != 4 {
                    return Err("h2: window".into());
                }
                let inc =
                    u32::from_be_bytes([payload[0] & 0x7f, payload[1], payload[2], payload[3]]);
                if inc == 0 {
                    return Err("h2: window".into());
                }
            }
            FRAME_PRIORITY | FRAME_RST | FRAME_PUSH | FRAME_GOAWAY => {
                return Err("h2: frame refused".into());
            }
            _ => return Err("h2: frame refused".into()),
        }
    }
    if want_cont {
        return Err("h2: truncated headers".into());
    }
    let stream = req_stream.ok_or("h2: no headers")?;
    let headers = hpack_decode(&header_block)?;
    let mut method = "GET".to_string();
    let mut path = "/".to_string();
    let mut rest = Vec::new();
    for (n, v) in headers {
        match n.as_str() {
            ":method" => method = v,
            ":path" => path = v,
            ":scheme" | ":authority" => {}
            _ => rest.push((n, v)),
        }
    }
    let mu = method.to_ascii_uppercase();
    if matches!(mu.as_str(), "TRACE" | "CONNECT" | "TRACK" | "HEAD") {
        return Err("h2: method".into());
    }
    if !path.starts_with('/') || path.contains("//") || path.contains('\\') {
        return Err("h2: path".into());
    }
    if path.contains("password=") || path.contains("token=") {
        return Err("h2: secret in url".into());
    }
    Ok(H2Exchange {
        stream,
        req: Request {
            method,
            path,
            version: Version::Http2,
            headers: rest,
            body,
        },
    })
}

/// PING ACK on stream 0.
pub fn ping_ack(opaque: &[u8; 8]) -> Vec<u8> {
    frame(FRAME_PING, ACK, 0, opaque)
}

fn window_update(stream: u32, inc: u32) -> Vec<u8> {
    frame(FRAME_WINDOW, 0, stream, &inc.to_be_bytes())
}

#[cfg(test)]
fn goaway_frame(last: u32, err: u32) -> Vec<u8> {
    let mut p = Vec::with_capacity(8);
    p.extend_from_slice(&last.to_be_bytes());
    p.extend_from_slice(&err.to_be_bytes());
    frame(FRAME_GOAWAY, 0, 0, &p)
}

#[cfg(test)]
fn rst_frame(stream: u32, err: u32) -> Vec<u8> {
    frame(FRAME_RST, 0, stream, &err.to_be_bytes())
}

const INITIAL_WINDOW: i32 = 65535;

#[derive(Debug)]
struct H2Stream {
    header_block: Vec<u8>,
    body: Vec<u8>,
    headers_done: bool,
    win_in: i32,
    win_out: i32,
}

/// Live HTTP/2 connection: leftover bytes, many odd streams, receive windows.
#[derive(Debug)]
pub struct H2Session {
    buf: Vec<u8>,
    preface: bool,
    streams: BTreeMap<u32, H2Stream>,
    conn_win_in: i32,
    conn_win_out: i32,
    send_win: BTreeMap<u32, i32>,
    max_frame: usize,
    max_streams: u32,
    init_win_out: i32,
    goaway: Option<u32>,
    cont: Option<u32>,
}

/// Session output: a completed request or control bytes to write.
#[derive(Debug)]
pub enum H2Event {
    Request { stream: u32, req: Request },
    Control(Vec<u8>),
}

impl Default for H2Session {
    fn default() -> Self {
        Self {
            buf: Vec::new(),
            preface: false,
            streams: BTreeMap::new(),
            conn_win_in: INITIAL_WINDOW,
            conn_win_out: INITIAL_WINDOW,
            send_win: BTreeMap::new(),
            max_frame: MAX_FRAME,
            max_streams: 32,
            init_win_out: INITIAL_WINDOW,
            goaway: None,
            cont: None,
        }
    }
}

impl H2Session {
    pub fn new() -> Self {
        Self::default()
    }

    /// Encode HEADERS+DATA on an odd stream. Body must fit the send window.
    pub fn respond(&mut self, stream: u32, resp: &Response) -> Result<Vec<u8>, String> {
        if stream == 0 || stream % 2 == 0 {
            return Err("h2: stream".into());
        }
        let n = resp.body.len() as i32;
        let sw = *self.send_win.get(&stream).unwrap_or(&INITIAL_WINDOW);
        if n > self.conn_win_out || n > sw {
            return Err("h2: send window".into());
        }
        self.conn_win_out -= n;
        self.send_win.insert(stream, sw - n);
        Ok(encode_response(resp, stream))
    }

    /// Push a TCP chunk. Incomplete frames stay buffered (CONTINUATION-safe).
    pub fn push(&mut self, chunk: &[u8]) -> Result<Vec<H2Event>, String> {
        self.buf.extend_from_slice(chunk);
        let mut out = Vec::new();
        if !self.preface {
            if self.buf.len() < PREFACE.len() {
                if PREFACE.starts_with(self.buf.as_slice()) {
                    return Ok(out);
                }
                return Err("h2: preface required".into());
            }
            if !self.buf.starts_with(PREFACE) {
                return Err("h2: preface required".into());
            }
            self.buf.drain(..PREFACE.len());
            self.preface = true;
        }
        loop {
            if self.buf.len() < 9 {
                break;
            }
            let len = ((self.buf[0] as usize) << 16)
                | ((self.buf[1] as usize) << 8)
                | self.buf[2] as usize;
            if len > self.max_frame {
                return Err("h2: frame too long".into());
            }
            if self.buf.len() < 9 + len {
                break;
            }
            let fr: Vec<u8> = self.buf.drain(..9 + len).collect();
            out.extend(self.feed(&fr)?);
        }
        Ok(out)
    }

    fn feed(&mut self, fr: &[u8]) -> Result<Vec<H2Event>, String> {
        let len = ((fr[0] as usize) << 16) | ((fr[1] as usize) << 8) | fr[2] as usize;
        let kind = fr[3];
        let flags = fr[4];
        let stream = u32::from_be_bytes([fr[5] & 0x7f, fr[6], fr[7], fr[8]]);
        let payload = &fr[9..9 + len];
        let mut out = Vec::new();
        match kind {
            FRAME_HEADERS => {
                if stream == 0 || stream % 2 == 0 {
                    return Err("h2: stream".into());
                }
                if flags & (PADDED | PRIORITY_FLAG) != 0 {
                    return Err("h2: padded/priority refused".into());
                }
                if self.cont.is_some() {
                    return Err("h2: expected continuation".into());
                }
                if let Some(last) = self.goaway {
                    if stream > last {
                        return Err("h2: goaway".into());
                    }
                }
                if !self.streams.contains_key(&stream)
                    && self.streams.len() as u32 >= self.max_streams
                {
                    return Err("h2: max streams".into());
                }
                let init_out = self.init_win_out;
                let st = self.streams.entry(stream).or_insert_with(|| H2Stream {
                    header_block: Vec::new(),
                    body: Vec::new(),
                    headers_done: false,
                    win_in: INITIAL_WINDOW,
                    win_out: init_out,
                });
                st.header_block.extend_from_slice(payload);
                st.headers_done = flags & END_HEADERS != 0;
                let done = st.headers_done;
                let end = flags & END_STREAM != 0;
                self.cont = if done { None } else { Some(stream) };
                if done && end {
                    let win = st.win_out;
                    let req = finish_h2_request(st)?;
                    self.streams.remove(&stream);
                    self.send_win.insert(stream, win);
                    out.push(H2Event::Request { stream, req });
                }
            }
            FRAME_CONTINUATION => {
                if self.cont != Some(stream) {
                    return Err("h2: continuation".into());
                }
                let st = self.streams.get_mut(&stream).ok_or("h2: continuation")?;
                st.header_block.extend_from_slice(payload);
                st.headers_done = flags & END_HEADERS != 0;
                let done = st.headers_done;
                let end = flags & END_STREAM != 0;
                self.cont = if done { None } else { Some(stream) };
                if done && end {
                    let win = st.win_out;
                    let req = finish_h2_request(st)?;
                    self.streams.remove(&stream);
                    self.send_win.insert(stream, win);
                    out.push(H2Event::Request { stream, req });
                }
            }
            FRAME_DATA => {
                if stream == 0 {
                    return Err("h2: stream".into());
                }
                let n = payload.len() as i32;
                if n > self.conn_win_in {
                    return Err("h2: conn window".into());
                }
                let st = self.streams.get_mut(&stream).ok_or("h2: data")?;
                if !st.headers_done {
                    return Err("h2: data".into());
                }
                if flags & PADDED != 0 {
                    return Err("h2: padded/priority refused".into());
                }
                if n > st.win_in {
                    return Err("h2: stream window".into());
                }
                st.body.extend_from_slice(payload);
                st.win_in -= n;
                self.conn_win_in -= n;
                if n > 0 {
                    let mut wu = window_update(0, n as u32);
                    wu.extend(window_update(stream, n as u32));
                    self.conn_win_in += n;
                    st.win_in += n;
                    out.push(H2Event::Control(wu));
                }
                if flags & END_STREAM != 0 {
                    let win = st.win_out;
                    let req = finish_h2_request(st)?;
                    self.streams.remove(&stream);
                    self.send_win.insert(stream, win);
                    out.push(H2Event::Request { stream, req });
                }
            }
            FRAME_SETTINGS => {
                if stream != 0 {
                    return Err("h2: settings stream".into());
                }
                if flags & ACK != 0 {
                    if !payload.is_empty() {
                        return Err("h2: settings ack".into());
                    }
                } else {
                    if payload.len() % 6 != 0 || payload.len() > 6 * 16 {
                        return Err("h2: settings".into());
                    }
                    let mut k = 0;
                    while k + 6 <= payload.len() {
                        let id = u16::from_be_bytes([payload[k], payload[k + 1]]);
                        let val = u32::from_be_bytes([
                            payload[k + 2],
                            payload[k + 3],
                            payload[k + 4],
                            payload[k + 5],
                        ]);
                        if id == 1 && val != 0 {
                            return Err("h2: header table".into());
                        }
                        if id == 2 && val != 0 {
                            return Err("h2: push refused".into());
                        }
                        if id == 3 {
                            self.max_streams = val.min(32);
                        }
                        if id == 5 {
                            if val < 16384 || val > 16_777_215 {
                                return Err("h2: max frame".into());
                            }
                            self.max_frame = self.max_frame.min(val as usize);
                        }
                        if id == 4 {
                            if val > 2_147_483_647 {
                                return Err("h2: window".into());
                            }
                            let neww = val as i32;
                            let delta = neww - self.init_win_out;
                            self.init_win_out = neww;
                            for st in self.streams.values_mut() {
                                st.win_out = st.win_out.saturating_add(delta);
                            }
                            for v in self.send_win.values_mut() {
                                *v = v.saturating_add(delta);
                            }
                        }
                        if id == 8 && val != 0 {
                            return Err("h2: connect refused".into());
                        }
                        k += 6;
                    }
                    out.push(H2Event::Control(frame(FRAME_SETTINGS, ACK, 0, &[])));
                }
            }
            FRAME_PING => {
                if stream != 0 || payload.len() != 8 {
                    return Err("h2: ping".into());
                }
                if flags & ACK == 0 {
                    let mut o = [0u8; 8];
                    o.copy_from_slice(payload);
                    out.push(H2Event::Control(ping_ack(&o)));
                }
            }
            FRAME_WINDOW => {
                if payload.len() != 4 {
                    return Err("h2: window".into());
                }
                let inc =
                    u32::from_be_bytes([payload[0] & 0x7f, payload[1], payload[2], payload[3]]);
                if inc == 0 {
                    return Err("h2: window".into());
                }
                if stream == 0 {
                    self.conn_win_out = self.conn_win_out.saturating_add(inc as i32);
                } else if let Some(st) = self.streams.get_mut(&stream) {
                    st.win_out = st.win_out.saturating_add(inc as i32);
                } else {
                    let e = self.send_win.entry(stream).or_insert(INITIAL_WINDOW);
                    *e = e.saturating_add(inc as i32);
                }
            }
            FRAME_RST => {
                if stream == 0 || payload.len() != 4 {
                    return Err("h2: rst".into());
                }
                self.streams.remove(&stream);
                self.send_win.remove(&stream);
                if self.cont == Some(stream) {
                    self.cont = None;
                }
            }
            FRAME_GOAWAY => {
                if stream != 0 || payload.len() < 8 {
                    return Err("h2: goaway".into());
                }
                let last =
                    u32::from_be_bytes([payload[0] & 0x7f, payload[1], payload[2], payload[3]]);
                self.goaway = Some(last);
            }
            FRAME_PRIORITY | FRAME_PUSH => {
                return Err("h2: frame refused".into());
            }
            _ => return Err("h2: frame refused".into()),
        }
        Ok(out)
    }
}

fn finish_h2_request(st: &H2Stream) -> Result<Request, String> {
    let headers = hpack_decode(&st.header_block)?;
    let mut method = "GET".to_string();
    let mut path = "/".to_string();
    let mut rest = Vec::new();
    for (n, v) in headers {
        match n.as_str() {
            ":method" => method = v,
            ":path" => path = v,
            ":scheme" | ":authority" => {}
            _ => rest.push((n, v)),
        }
    }
    let mu = method.to_ascii_uppercase();
    if matches!(mu.as_str(), "TRACE" | "CONNECT" | "TRACK" | "HEAD") {
        return Err("h2: method".into());
    }
    if !path.starts_with('/') || path.contains("//") || path.contains('\\') {
        return Err("h2: path".into());
    }
    if path.contains("password=") || path.contains("token=") {
        return Err("h2: secret in url".into());
    }
    Ok(Request {
        method,
        path,
        version: Version::Http2,
        headers: rest,
        body: st.body.clone(),
    })
}

fn hpack_status(code: u16) -> Vec<u8> {
    match code {
        200 => vec![0x80 | 8],
        204 => vec![0x80 | 9],
        404 => vec![0x80 | 13],
        500 => vec![0x80 | 14],
        400 => vec![0x80 | 12],
        _ => {
            let s = code.to_string();
            let mut v = vec![0x08, s.len() as u8];
            v.extend_from_slice(s.as_bytes());
            v
        }
    }
}

/// HEADERS(:status) + DATA on `stream` (no SETTINGS ACK).
pub fn encode_response(resp: &Response, stream: u32) -> Vec<u8> {
    let blk = hpack_status(resp.status);
    let mut out = frame(FRAME_HEADERS, END_HEADERS, stream, &blk);
    out.extend(frame(FRAME_DATA, END_STREAM, stream, &resp.body));
    out
}

/// Encode a response as SETTINGS ACK + HEADERS(:status) + DATA (one-shot adapter).
pub fn encode(resp: &Response, stream: u32) -> Vec<u8> {
    let mut out = frame(FRAME_SETTINGS, ACK, 0, &[]);
    out.extend(encode_response(resp, stream));
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

    #[test]
    fn preface_stream_and_refused_frames() {
        assert!(parse(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
            .unwrap_err()
            .contains("preface"));
        let mut push = PREFACE.to_vec();
        push.extend(frame(FRAME_PUSH, 0, 1, &[0, 0, 0, 1]));
        assert!(parse(&push).unwrap_err().contains("frame refused"));
        let mut even = PREFACE.to_vec();
        even.extend(frame(FRAME_HEADERS, END_HEADERS, 2, &[0x82, 0x84]));
        assert!(parse(&even).unwrap_err().contains("stream"));
        let mut pad = PREFACE.to_vec();
        pad.extend(frame(
            FRAME_HEADERS,
            END_HEADERS | PADDED,
            1,
            &[0, 0x82, 0x84],
        ));
        assert!(parse(&pad).unwrap_err().contains("padded"));
        let mut ping = PREFACE.to_vec();
        ping.extend(frame(FRAME_PING, 0, 0, &[0u8; 8]));
        ping.extend(frame(FRAME_HEADERS, END_HEADERS, 3, &[0x82, 0x84]));
        let ex = parse_exchange(&ping).unwrap();
        assert_eq!(ex.stream, 3);
        assert_eq!(ex.req.method, "GET");
        let mut two = PREFACE.to_vec();
        two.extend(frame(FRAME_HEADERS, END_HEADERS, 1, &[0x82, 0x84]));
        two.extend(frame(FRAME_HEADERS, END_HEADERS, 3, &[0x82, 0x84]));
        assert!(parse(&two).unwrap_err().contains("one stream"));
        let secret = client_get("/bios/trust?password=x");
        assert!(parse(&secret).unwrap_err().contains("secret"));
        let mut push_on = PREFACE.to_vec();
        let mut set = Vec::new();
        set.extend_from_slice(&2u16.to_be_bytes());
        set.extend_from_slice(&1u32.to_be_bytes());
        push_on.extend(frame(FRAME_SETTINGS, 0, 0, &set));
        push_on.extend(frame(FRAME_HEADERS, END_HEADERS, 1, &[0x82, 0x84]));
        assert!(parse(&push_on).unwrap_err().contains("push"));
        assert_eq!(ping_ack(&[9u8; 8])[3], FRAME_PING);
        assert_eq!(ping_ack(&[9u8; 8])[4], ACK);
    }

    #[test]
    fn session_multiplex_continuation_and_window() {
        let mut s = H2Session::new();
        assert!(s.push(b"PRI").unwrap().is_empty());
        let mut two = PREFACE[3..].to_vec();
        two.extend(frame(
            FRAME_HEADERS,
            END_HEADERS | END_STREAM,
            1,
            &[0x82, 0x84],
        ));
        two.extend(frame(
            FRAME_HEADERS,
            END_HEADERS | END_STREAM,
            3,
            &[0x82, 0x84],
        ));
        let ev = s.push(&two).unwrap();
        let reqs: Vec<u32> = ev
            .iter()
            .filter_map(|e| match e {
                H2Event::Request { stream, .. } => Some(*stream),
                _ => None,
            })
            .collect();
        assert_eq!(reqs, vec![1, 3]);
        let mut s2 = H2Session::new();
        s2.push(PREFACE).unwrap();
        let h = frame(FRAME_HEADERS, 0, 1, &[0x82]);
        assert!(s2.push(&h).unwrap().is_empty());
        let c = frame(FRAME_CONTINUATION, END_HEADERS | END_STREAM, 1, &[0x84]);
        let ev = s2.push(&c).unwrap();
        assert!(ev
            .iter()
            .any(|e| matches!(e, H2Event::Request { stream: 1, .. })));
        let mut s3 = H2Session::new();
        s3.push(PREFACE).unwrap();
        s3.push(&frame(FRAME_HEADERS, END_HEADERS, 1, &[0x82, 0x84]))
            .unwrap();
        let data = frame(FRAME_DATA, END_STREAM, 1, b"abcd");
        let ev = s3.push(&data).unwrap();
        assert!(ev.iter().any(|e| matches!(e, H2Event::Control(_))));
        assert!(ev
            .iter()
            .any(|e| matches!(e, H2Event::Request { stream: 1, req } if req.body == b"abcd")));
        let mut s4 = H2Session::new();
        s4.push(PREFACE).unwrap();
        s4.push(&frame(
            FRAME_HEADERS,
            END_HEADERS | END_STREAM,
            1,
            &[0x82, 0x84],
        ))
        .unwrap();
        let wu = window_update(0, 16);
        s4.push(&wu).unwrap();
        let resp = Response {
            status: 405,
            headers: Vec::new(),
            body: b"no".to_vec(),
        };
        let wire = s4.respond(1, &resp).unwrap();
        assert_eq!(wire[3], FRAME_HEADERS);
        assert!(s4.respond(2, &resp).unwrap_err().contains("stream"));
        let big = Response {
            status: 200,
            headers: Vec::new(),
            body: vec![0u8; 70_000],
        };
        assert!(s4.respond(1, &big).unwrap_err().contains("send window"));
        let mut s5 = H2Session::new();
        s5.push(PREFACE).unwrap();
        let mut set = Vec::new();
        set.extend_from_slice(&3u16.to_be_bytes());
        set.extend_from_slice(&1u32.to_be_bytes());
        s5.push(&frame(FRAME_SETTINGS, 0, 0, &set)).unwrap();
        s5.push(&frame(FRAME_HEADERS, END_HEADERS, 1, &[0x82, 0x84]))
            .unwrap();
        assert!(s5
            .push(&frame(
                FRAME_HEADERS,
                END_HEADERS | END_STREAM,
                3,
                &[0x82, 0x84],
            ))
            .unwrap_err()
            .contains("max streams"));
        let mut s6 = H2Session::new();
        s6.push(PREFACE).unwrap();
        s6.push(&goaway_frame(1, 0)).unwrap();
        assert!(s6
            .push(&frame(
                FRAME_HEADERS,
                END_HEADERS | END_STREAM,
                3,
                &[0x82, 0x84],
            ))
            .unwrap_err()
            .contains("goaway"));
        s6.push(&frame(
            FRAME_HEADERS,
            END_HEADERS | END_STREAM,
            1,
            &[0x82, 0x84],
        ))
        .unwrap();
        let mut s7 = H2Session::new();
        s7.push(PREFACE).unwrap();
        s7.push(&frame(FRAME_HEADERS, 0, 1, &[0x82])).unwrap();
        s7.push(&rst_frame(1, 8)).unwrap();
        assert!(s7
            .push(&frame(FRAME_DATA, END_STREAM, 1, b"x"))
            .unwrap_err()
            .contains("data"));
        let mut tbl = Vec::new();
        tbl.extend_from_slice(&1u16.to_be_bytes());
        tbl.extend_from_slice(&4096u32.to_be_bytes());
        let mut s8 = H2Session::new();
        s8.push(PREFACE).unwrap();
        assert!(s8
            .push(&frame(FRAME_SETTINGS, 0, 0, &tbl))
            .unwrap_err()
            .contains("header table"));
        let mut conn = Vec::new();
        conn.extend_from_slice(&8u16.to_be_bytes());
        conn.extend_from_slice(&1u32.to_be_bytes());
        let mut s9 = H2Session::new();
        s9.push(PREFACE).unwrap();
        assert!(s9
            .push(&frame(FRAME_SETTINGS, 0, 0, &conn))
            .unwrap_err()
            .contains("connect"));
        assert!(s9
            .push(&frame(FRAME_DATA, END_STREAM, 0, b"x"))
            .unwrap_err()
            .contains("stream"));
    }
}
