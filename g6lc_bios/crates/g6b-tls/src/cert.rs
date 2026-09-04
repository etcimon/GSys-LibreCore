// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! X.509 certificate parse (DER/PEM). Spec: Botan `cert/x509`. Not a path
//! validator — extracts CN + public-key algorithm for the BIOS browser.

#![allow(missing_docs)]

/// Parsed certificate view.
#[derive(Debug, Clone)]
pub struct Cert {
    pub cn: String,
    pub algo: &'static str,
    pub der_len: usize,
}

const OID_RSA: &[u8] = &[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01];
const OID_EC: &[u8] = &[0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01];
const OID_CN: &[u8] = &[0x55, 0x04, 0x03];

/// Parse PEM or raw DER.
pub fn parse(input: &[u8]) -> Result<Cert, String> {
    let der = if input.windows(10).any(|w| w == b"-----BEGIN") {
        pem_der(input)?
    } else {
        input.to_vec()
    };
    parse_der(&der)
}

fn pem_der(s: &[u8]) -> Result<Vec<u8>, String> {
    let t = core::str::from_utf8(s).map_err(|_| "pem utf8")?;
    let start = t.find("-----BEGIN").ok_or("pem begin")?;
    let rest = &t[start..];
    let nl = rest.find('\n').ok_or("pem header")?;
    let body = &rest[nl + 1..];
    let end = body.find("-----END").ok_or("pem end")?;
    let b64: String = body[..end]
        .chars()
        .filter(|c| !c.is_ascii_whitespace())
        .collect();
    b64_decode(&b64)
}

fn b64_decode(s: &str) -> Result<Vec<u8>, String> {
    fn val(c: u8) -> Option<u8> {
        match c {
            b'A'..=b'Z' => Some(c - b'A'),
            b'a'..=b'z' => Some(c - b'a' + 26),
            b'0'..=b'9' => Some(c - b'0' + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            b'=' => Some(0),
            _ => None,
        }
    }
    let bytes = s.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i + 3 < bytes.len() {
        let a = val(bytes[i]).ok_or("b64")?;
        let b = val(bytes[i + 1]).ok_or("b64")?;
        let c = val(bytes[i + 2]).ok_or("b64")?;
        let d = val(bytes[i + 3]).ok_or("b64")?;
        out.push((a << 2) | (b >> 4));
        if bytes[i + 2] != b'=' {
            out.push((b << 4) | (c >> 2));
        }
        if bytes[i + 3] != b'=' {
            out.push((c << 6) | d);
        }
        i += 4;
    }
    Ok(out)
}

fn parse_der(der: &[u8]) -> Result<Cert, String> {
    let mut cn = String::new();
    let mut algo = "unknown";
    walk(der, &mut cn, &mut algo)?;
    if cn.is_empty() && algo == "unknown" {
        return Err("not an x509 cert".into());
    }
    Ok(Cert {
        cn,
        algo,
        der_len: der.len(),
    })
}

fn walk(der: &[u8], cn: &mut String, algo: &mut &'static str) -> Result<(), String> {
    walk_cn(der, cn, algo, &mut false)
}

fn walk_cn(
    der: &[u8],
    cn: &mut String,
    algo: &mut &'static str,
    after_cn: &mut bool,
) -> Result<(), String> {
    let mut i = 0usize;
    while i < der.len() {
        let tag = der[i];
        i += 1;
        let (len, ni) = der_len(der, i)?;
        i = ni;
        if i + len > der.len() {
            break;
        }
        let body = &der[i..i + len];
        if tag & 0x20 != 0 {
            walk_cn(body, cn, algo, after_cn)?;
        } else {
            match tag {
                0x06 => {
                    if body == OID_RSA {
                        *algo = "rsa";
                    } else if body == OID_EC {
                        *algo = "ecdsa";
                    } else if body == OID_CN {
                        *after_cn = true;
                    }
                }
                0x0c | 0x13 | 0x16 => {
                    if *after_cn && cn.is_empty() {
                        *cn = String::from_utf8_lossy(body).into_owned();
                        *after_cn = false;
                    }
                }
                _ => {}
            }
        }
        i += len;
    }
    Ok(())
}

fn der_len(b: &[u8], mut i: usize) -> Result<(usize, usize), String> {
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
    Ok((v, i))
}
