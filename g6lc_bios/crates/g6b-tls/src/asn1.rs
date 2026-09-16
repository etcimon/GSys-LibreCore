// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Bounded DER TLV. Spec: Botan `asn1` (not linked). Not BER indefinite.

#![allow(missing_docs, dead_code)]

#[derive(Clone, Copy, Debug)]
pub struct Tlv<'a> {
    pub tag: u8,
    pub value: &'a [u8],
    /// Tag + length + value (for TBS extraction).
    pub full: &'a [u8],
}

pub const SEQ: u8 = 0x30;
pub const SET: u8 = 0x31;
pub const INT: u8 = 0x02;
pub const BITS: u8 = 0x03;
pub const OCTET: u8 = 0x04;
pub const NULL: u8 = 0x05;
pub const OID: u8 = 0x06;
pub const UTF8: u8 = 0x0c;
pub const PRINT: u8 = 0x13;
pub const IA5: u8 = 0x16;
pub const UTC: u8 = 0x17;
pub const GENTIME: u8 = 0x18;
pub const CTX0_C: u8 = 0xa0;
pub const CTX3_C: u8 = 0xa3;

const MAX: usize = 64 * 1024;

pub fn take(buf: &[u8]) -> Result<(Tlv<'_>, &[u8]), String> {
    if buf.is_empty() {
        return Err("der: empty".into());
    }
    if buf.len() > MAX {
        return Err("der: too long".into());
    }
    let tag = buf[0];
    let (len, i) = der_len(buf, 1)?;
    if i + len > buf.len() {
        return Err("der: truncated".into());
    }
    Ok((
        Tlv {
            tag,
            value: &buf[i..i + len],
            full: &buf[..i + len],
        },
        &buf[i + len..],
    ))
}

pub fn expect<'a>(buf: &'a [u8], tag: u8) -> Result<(Tlv<'a>, &'a [u8]), String> {
    let (t, rest) = take(buf)?;
    if t.tag != tag {
        return Err("der: tag".into());
    }
    Ok((t, rest))
}

pub fn children(seq: &[u8]) -> Result<Vec<Tlv<'_>>, String> {
    let mut rest = seq;
    let mut out = Vec::new();
    while !rest.is_empty() {
        let (t, r) = take(rest)?;
        out.push(t);
        rest = r;
    }
    Ok(out)
}

pub fn der_len(b: &[u8], mut i: usize) -> Result<(usize, usize), String> {
    let f = *b.get(i).ok_or("der len")?;
    i += 1;
    if f < 0x80 {
        return Ok((f as usize, i));
    }
    let n = (f & 0x7f) as usize;
    if n == 0 || n > 3 || i + n > b.len() {
        return Err("der len form".into());
    }
    let mut v = 0usize;
    for _ in 0..n {
        v = (v << 8) | b[i] as usize;
        i += 1;
    }
    if v < 0x80 {
        return Err("der len non-canonical".into());
    }
    Ok((v, i))
}

pub fn int_be(v: &[u8]) -> Result<Vec<u8>, String> {
    if v.is_empty() {
        return Err("der int".into());
    }
    let mut o = v.to_vec();
    while o.len() > 1 && o[0] == 0 {
        o.remove(0);
    }
    Ok(o)
}

pub fn bit_payload(v: &[u8]) -> Result<&[u8], String> {
    if v.is_empty() {
        return Err("der bits".into());
    }
    if v[0] != 0 {
        // unused bits allowed for KeyUsage; strip the count byte
    }
    Ok(&v[1..])
}

pub fn oid_eq(v: &[u8], oid: &[u8]) -> bool {
    v == oid
}
