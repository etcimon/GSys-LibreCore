// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! X.509 v3 leaf/chain parse. Spec: Botan `cert/x509` (not linked).
//! DNS/email name constraints, EKU serverAuth, SKI/AKI.
//! Not a full policy/CT engine.

#![allow(missing_docs)]

use crate::asn1::{self, Tlv, BITS, CTX0_C, CTX3_C, GENTIME, INT, OCTET, OID, SEQ, UTC};
use crate::ecdsa::ecdsa_p256_sha256_verify;
use crate::rsa::{rsa_pkcs1_sha1_verify, rsa_pkcs1_sha256_verify, RsaPub};

const OID_RSA: &[u8] = &[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01];
const OID_SHA256_RSA: &[u8] = &[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0b];
const OID_SHA1_RSA: &[u8] = &[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x05];
const OID_EC: &[u8] = &[0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01];
const OID_P256: &[u8] = &[0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07];
const OID_ECDSA_SHA256: &[u8] = &[0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02];
const OID_CN: &[u8] = &[0x55, 0x04, 0x03];
const OID_SAN: &[u8] = &[0x55, 0x1d, 0x11];
const OID_KU: &[u8] = &[0x55, 0x1d, 0x0f];
const OID_BC: &[u8] = &[0x55, 0x1d, 0x13];
const OID_SKI: &[u8] = &[0x55, 0x1d, 0x0e];
const OID_AKI: &[u8] = &[0x55, 0x1d, 0x23];
const OID_EKU: &[u8] = &[0x55, 0x1d, 0x25];
const OID_AIA: &[u8] = &[0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x01, 0x01];
const OID_AD_OCSP: &[u8] = &[0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x30, 0x01];
const OID_NC: &[u8] = &[0x55, 0x1d, 0x1e];
const OID_EKU_SERVER_AUTH: &[u8] = &[0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01];
const OID_ANY_EKU: &[u8] = &[0x55, 0x1d, 0x25, 0x00];

pub const KU_DIGITAL_SIGNATURE: u16 = 1 << 0;
pub const KU_KEY_CERT_SIGN: u16 = 1 << 5;

/// Parsed certificate view.
#[derive(Debug, Clone)]
pub struct Cert {
    pub cn: String,
    pub algo: &'static str,
    pub der_len: usize,
    pub der: Vec<u8>,
    pub tbs: Vec<u8>,
    pub serial: Vec<u8>,
    pub issuer_der: Vec<u8>,
    pub subject_der: Vec<u8>,
    pub not_before: u64,
    pub not_after: u64,
    pub san: Vec<String>,
    pub san_ip: Vec<[u8; 4]>,
    pub is_ca: bool,
    pub path_len: Option<u32>,
    pub key_usage: Option<u16>,
    pub sig_oid: Vec<u8>,
    pub signature: Vec<u8>,
    pub rsa: Option<RsaPub>,
    pub ecdsa: Option<([u8; 32], [u8; 32])>,
    pub ocsp_uris: Vec<String>,
    pub eku: Vec<Vec<u8>>,
    pub nc_permit_dns: Vec<String>,
    pub nc_exclude_dns: Vec<String>,
    pub san_email: Vec<String>,
    pub nc_permit_email: Vec<String>,
    pub nc_exclude_email: Vec<String>,
    pub ski: Vec<u8>,
    pub aki: Vec<u8>,
}

/// Parse PEM or raw DER. One certificate.
pub fn parse(input: &[u8]) -> Result<Cert, String> {
    let ders = pem_or_der_list(input)?;
    let der = ders.into_iter().next().ok_or("not an x509 cert")?;
    parse_der(&der)
}

/// Every PEM CERTIFICATE block, or a single DER.
pub fn parse_chain(input: &[u8]) -> Result<Vec<Cert>, String> {
    let ders = pem_or_der_list(input)?;
    ders.iter().map(|d| parse_der(d)).collect()
}

/// RSA modulus/exponent from a PEM or DER certificate.
pub fn rsa_pub(input: &[u8]) -> Result<RsaPub, String> {
    parse(input)?.rsa.ok_or_else(|| "no rsa pub".into())
}

/// Leaf certificate DER from a TLS 1.3 Certificate handshake message.
pub fn leaf_from_tls13_certificate(msg: &[u8]) -> Result<Vec<u8>, String> {
    certs_from_tls13(msg)?
        .into_iter()
        .next()
        .ok_or_else(|| "tls: Certificate leaf".into())
}

/// Every cert_data in a TLS 1.3 Certificate handshake message.
pub fn certs_from_tls13(msg: &[u8]) -> Result<Vec<Vec<u8>>, String> {
    if msg.len() < 12 || msg[0] != 0x0b {
        return Err("tls: not Certificate".into());
    }
    let n = ((msg[1] as usize) << 16) | ((msg[2] as usize) << 8) | (msg[3] as usize);
    if msg.len() != 4 + n {
        return Err("tls: Certificate length".into());
    }
    let ctx = msg[4] as usize;
    let mut i = 5 + ctx;
    if i + 3 > msg.len() {
        return Err("tls: Certificate list".into());
    }
    let list_end =
        i + 3 + (((msg[i] as usize) << 16) | ((msg[i + 1] as usize) << 8) | (msg[i + 2] as usize));
    i += 3;
    if list_end > msg.len() {
        return Err("tls: Certificate list".into());
    }
    let mut out = Vec::new();
    while i + 3 <= list_end {
        let cl = ((msg[i] as usize) << 16) | ((msg[i + 1] as usize) << 8) | (msg[i + 2] as usize);
        i += 3;
        if i + cl + 2 > list_end && i + cl > list_end {
            return Err("tls: Certificate leaf".into());
        }
        if i + cl > list_end {
            return Err("tls: Certificate leaf".into());
        }
        out.push(msg[i..i + cl].to_vec());
        i += cl;
        if i + 2 > list_end {
            break;
        }
        let el = u16::from_be_bytes([msg[i], msg[i + 1]]) as usize;
        i += 2 + el;
    }
    if out.is_empty() {
        return Err("tls: Certificate empty".into());
    }
    Ok(out)
}

/// OCSP staple (status_request 0x0005) from the first TLS 1.3 CertificateEntry.
pub fn ocsp_staple_from_tls13(msg: &[u8]) -> Result<Option<Vec<u8>>, String> {
    if msg.len() < 12 || msg[0] != 0x0b {
        return Err("tls: not Certificate".into());
    }
    let n = ((msg[1] as usize) << 16) | ((msg[2] as usize) << 8) | (msg[3] as usize);
    if msg.len() != 4 + n {
        return Err("tls: Certificate length".into());
    }
    let ctx = msg[4] as usize;
    let mut i = 5 + ctx + 3;
    if i + 3 > msg.len() {
        return Err("tls: Certificate list".into());
    }
    let cl = ((msg[i] as usize) << 16) | ((msg[i + 1] as usize) << 8) | (msg[i + 2] as usize);
    i += 3 + cl;
    if i + 2 > msg.len() {
        return Ok(None);
    }
    let el = u16::from_be_bytes([msg[i], msg[i + 1]]) as usize;
    i += 2;
    if i + el > msg.len() {
        return Err("tls: Certificate ext".into());
    }
    let ext = &msg[i..i + el];
    let mut j = 0;
    while j + 4 <= ext.len() {
        let id = u16::from_be_bytes([ext[j], ext[j + 1]]);
        let ln = u16::from_be_bytes([ext[j + 2], ext[j + 3]]) as usize;
        j += 4;
        if j + ln > ext.len() {
            return Err("tls: Certificate ext truncated".into());
        }
        if id == 0x0005 {
            return Ok(Some(ext[j..j + ln].to_vec()));
        }
        j += ln;
    }
    Ok(None)
}

pub fn verify_signature(child: &Cert, issuer: &Cert) -> bool {
    match child.sig_oid.as_slice() {
        x if x == OID_SHA256_RSA => match &issuer.rsa {
            Some(k) => rsa_pkcs1_sha256_verify(k, &child.tbs, &child.signature),
            None => false,
        },
        x if x == OID_SHA1_RSA => match &issuer.rsa {
            Some(k) => rsa_pkcs1_sha1_verify(k, &child.tbs, &child.signature),
            None => false,
        },
        x if x == OID_ECDSA_SHA256 => match issuer.ecdsa {
            Some((qx, qy)) => ecdsa_sig(&child.signature)
                .map(|(r, s)| ecdsa_p256_sha256_verify(&qx, &qy, &child.tbs, &r, &s))
                .unwrap_or(false),
            None => false,
        },
        _ => false,
    }
}

pub fn name_matches(cert: &Cert, host: &str) -> bool {
    let h = host.trim().to_ascii_lowercase();
    if h.is_empty() {
        return false;
    }
    if !cert.san.is_empty() || !cert.san_ip.is_empty() {
        if let Some(ip) = parse_ipv4(&h) {
            return cert.san_ip.iter().any(|a| a == &ip);
        }
        return cert.san.iter().any(|s| dns_match(s, &h));
    }
    !cert.cn.is_empty() && cert.cn.eq_ignore_ascii_case(&h)
}

fn dns_match(pat: &str, host: &str) -> bool {
    let p = pat.to_ascii_lowercase();
    if let Some(rest) = p.strip_prefix("*.") {
        if rest.is_empty() || rest.contains('*') || rest.starts_with('.') {
            return false;
        }
        match host.split_once('.') {
            Some((a, b)) if !a.is_empty() && !a.contains('.') && b == rest => true,
            _ => false,
        }
    } else {
        p == host
    }
}

fn parse_ipv4(s: &str) -> Option<[u8; 4]> {
    let mut o = [0u8; 4];
    let mut i = 0usize;
    for p in s.split('.') {
        if i == 4 {
            return None;
        }
        let n: u8 = p.parse().ok()?;
        if p.len() > 1 && p.starts_with('0') {
            return None;
        }
        o[i] = n;
        i += 1;
    }
    if i == 4 {
        Some(o)
    } else {
        None
    }
}

fn pem_or_der_list(input: &[u8]) -> Result<Vec<Vec<u8>>, String> {
    if input.windows(10).any(|w| w == b"-----BEGIN") {
        pem_certs(input)
    } else {
        Ok(vec![input.to_vec()])
    }
}

fn pem_certs(s: &[u8]) -> Result<Vec<Vec<u8>>, String> {
    let t = core::str::from_utf8(s).map_err(|_| "pem utf8")?;
    let mut out = Vec::new();
    let mut rest = t;
    while let Some(start) = rest.find("-----BEGIN") {
        let chunk = &rest[start..];
        let nl = chunk.find('\n').ok_or("pem header")?;
        let body = &chunk[nl + 1..];
        let end = body.find("-----END").ok_or("pem end")?;
        let b64: String = body[..end]
            .chars()
            .filter(|c| !c.is_ascii_whitespace())
            .collect();
        out.push(b64_decode(&b64)?);
        rest = &body[end + 5..];
    }
    if out.is_empty() {
        return Err("pem begin".into());
    }
    Ok(out)
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
    let (top, rest) = asn1::expect(der, SEQ)?;
    if rest.iter().any(|&b| b != 0) {
        return Err("x509: trailing".into());
    }
    let ch = asn1::children(top.value)?;
    if ch.len() != 3 {
        return Err("x509: cert fields".into());
    }
    if ch[0].tag != SEQ || ch[1].tag != SEQ || ch[2].tag != BITS {
        return Err("x509: cert tags".into());
    }
    let tbs = ch[0].full.to_vec();
    let sig_oid = alg_oid(ch[1].value)?;
    let signature = asn1::bit_payload(ch[2].value)?.to_vec();
    let tbs_ch = asn1::children(ch[0].value)?;
    let mut i = 0usize;
    if tbs_ch.first().map(|t| t.tag) == Some(CTX0_C) {
        i = 1;
    }
    if i + 6 > tbs_ch.len() {
        return Err("x509: tbs short".into());
    }
    if tbs_ch[i].tag != INT {
        return Err("x509: serial".into());
    }
    let serial = asn1::int_be(tbs_ch[i].value)?;
    i += 1;
    let _tbs_sig = alg_oid(tbs_ch[i].value)?;
    i += 1;
    if tbs_ch[i].tag != SEQ {
        return Err("x509: issuer".into());
    }
    let issuer_der = tbs_ch[i].full.to_vec();
    i += 1;
    let (not_before, not_after) = validity(tbs_ch[i].value)?;
    i += 1;
    if tbs_ch[i].tag != SEQ {
        return Err("x509: subject".into());
    }
    let subject_der = tbs_ch[i].full.to_vec();
    let cn = cn_of(tbs_ch[i].value)?;
    i += 1;
    if tbs_ch[i].tag != SEQ {
        return Err("x509: spki".into());
    }
    let (algo, rsa, ecdsa) = spki(tbs_ch[i].value)?;
    i += 1;
    let mut is_ca = false;
    let mut path_len = None;
    let mut key_usage = None;
    let mut san = Vec::new();
    let mut san_ip = Vec::new();
    let mut ocsp_uris = Vec::new();
    let mut eku = Vec::new();
    let mut nc_permit_dns = Vec::new();
    let mut nc_exclude_dns = Vec::new();
    let mut san_email = Vec::new();
    let mut nc_permit_email = Vec::new();
    let mut nc_exclude_email = Vec::new();
    let mut ski = Vec::new();
    let mut aki = Vec::new();
    if let Some(exts) = tbs_ch.get(i..) {
        for t in exts {
            if t.tag == 0xa1 || t.tag == 0xa2 {
                continue;
            }
            if t.tag == CTX3_C {
                parse_exts(
                    t.value,
                    &mut is_ca,
                    &mut path_len,
                    &mut key_usage,
                    &mut san,
                    &mut san_ip,
                    &mut san_email,
                    &mut ocsp_uris,
                    &mut eku,
                    &mut nc_permit_dns,
                    &mut nc_exclude_dns,
                    &mut nc_permit_email,
                    &mut nc_exclude_email,
                    &mut ski,
                    &mut aki,
                )?;
            }
        }
    }
    if cn.is_empty() && algo == "unknown" {
        return Err("not an x509 cert".into());
    }
    Ok(Cert {
        cn,
        algo,
        der_len: der.len(),
        der: der.to_vec(),
        tbs,
        serial,
        issuer_der,
        subject_der,
        not_before,
        not_after,
        san,
        san_ip,
        is_ca,
        path_len,
        key_usage,
        sig_oid,
        signature,
        rsa,
        ecdsa,
        ocsp_uris,
        eku,
        nc_permit_dns,
        nc_exclude_dns,
        san_email,
        nc_permit_email,
        nc_exclude_email,
        ski,
        aki,
    })
}

fn alg_oid(seq: &[u8]) -> Result<Vec<u8>, String> {
    let ch = asn1::children(seq)?;
    if ch.is_empty() || ch[0].tag != OID {
        return Err("x509: alg".into());
    }
    Ok(ch[0].value.to_vec())
}

fn cn_of(name: &[u8]) -> Result<String, String> {
    let mut cn = String::new();
    for rdn in asn1::children(name)? {
        if rdn.tag != asn1::SET {
            continue;
        }
        for atv in asn1::children(rdn.value)? {
            if atv.tag != SEQ {
                continue;
            }
            let av = asn1::children(atv.value)?;
            if av.len() >= 2 && av[0].tag == OID && av[0].value == OID_CN {
                cn = String::from_utf8_lossy(av[1].value).into_owned();
            }
        }
    }
    Ok(cn)
}

fn validity(seq: &[u8]) -> Result<(u64, u64), String> {
    let ch = asn1::children(seq)?;
    if ch.len() != 2 {
        return Err("x509: validity".into());
    }
    Ok((asn_time(&ch[0])?, asn_time(&ch[1])?))
}

fn asn_time(t: &Tlv<'_>) -> Result<u64, String> {
    let s = core::str::from_utf8(t.value).map_err(|_| "x509: time utf8")?;
    match t.tag {
        UTC if s.len() == 13 && s.ends_with('Z') => {
            let yy: i32 = s[0..2].parse().map_err(|_| "x509: time")?;
            let y = if yy >= 50 { 1900 + yy } else { 2000 + yy };
            ymdhms(y, &s[2..])
        }
        GENTIME if s.len() >= 15 && s.ends_with('Z') => {
            let y: i32 = s[0..4].parse().map_err(|_| "x509: time")?;
            ymdhms(y, &s[4..])
        }
        _ => Err("x509: time tag".into()),
    }
}

fn ymdhms(y: i32, rest: &str) -> Result<u64, String> {
    if rest.len() < 11 {
        return Err("x509: time".into());
    }
    let m: u32 = rest[0..2].parse().map_err(|_| "x509: time")?;
    let d: u32 = rest[2..4].parse().map_err(|_| "x509: time")?;
    let h: u32 = rest[4..6].parse().map_err(|_| "x509: time")?;
    let mi: u32 = rest[6..8].parse().map_err(|_| "x509: time")?;
    let s: u32 = rest[8..10].parse().map_err(|_| "x509: time")?;
    if !(1..=12).contains(&m) || d == 0 || d > 31 || h > 23 || mi > 59 || s > 60 {
        return Err("x509: time range".into());
    }
    Ok(unix_utc(y, m, d, h, mi, s))
}

fn leap(y: i32) -> bool {
    y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)
}

fn unix_utc(y: i32, m: u32, d: u32, h: u32, mi: u32, s: u32) -> u64 {
    let mut days: i64 = 0;
    let yy0 = y.min(9999).max(1970);
    for yy in 1970..yy0 {
        days += if leap(yy) { 366 } else { 365 };
    }
    const MD: [i64; 12] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    for i in 0..(m as usize).saturating_sub(1).min(11) {
        days += MD[i];
        if i == 1 && leap(y) {
            days += 1;
        }
    }
    days += d as i64 - 1;
    (days * 86400 + h as i64 * 3600 + mi as i64 * 60 + s as i64) as u64
}

fn spki(
    seq: &[u8],
) -> Result<(&'static str, Option<RsaPub>, Option<([u8; 32], [u8; 32])>), String> {
    let ch = asn1::children(seq)?;
    if ch.len() != 2 || ch[0].tag != SEQ || ch[1].tag != BITS {
        return Err("x509: spki".into());
    }
    let alg = asn1::children(ch[0].value)?;
    if alg.is_empty() || alg[0].tag != OID {
        return Err("x509: spki oid".into());
    }
    let bits = asn1::bit_payload(ch[1].value)?;
    if alg[0].value == OID_RSA {
        let rsa = parse_rsa_pkcs1(bits)?;
        Ok(("rsa", Some(rsa), None))
    } else if alg[0].value == OID_EC {
        if alg.len() < 2 || alg[1].tag != OID || alg[1].value != OID_P256 {
            return Err("x509: not p256".into());
        }
        if bits.len() != 65 || bits[0] != 0x04 {
            return Err("x509: ec point".into());
        }
        let mut x = [0u8; 32];
        let mut y = [0u8; 32];
        x.copy_from_slice(&bits[1..33]);
        y.copy_from_slice(&bits[33..65]);
        Ok(("ecdsa", None, Some((x, y))))
    } else {
        Ok(("unknown", None, None))
    }
}

fn parse_rsa_pkcs1(der: &[u8]) -> Result<RsaPub, String> {
    let (seq, rest) = asn1::expect(der, SEQ)?;
    if !rest.is_empty() {
        return Err("rsa pkcs1".into());
    }
    let ch = asn1::children(seq.value)?;
    if ch.len() < 2 || ch[0].tag != INT || ch[1].tag != INT {
        return Err("rsa pkcs1".into());
    }
    Ok(RsaPub {
        n: asn1::int_be(ch[0].value)?,
        e: asn1::int_be(ch[1].value)?,
    })
}

#[allow(clippy::too_many_arguments)]
fn parse_exts(
    explicit: &[u8],
    is_ca: &mut bool,
    path_len: &mut Option<u32>,
    key_usage: &mut Option<u16>,
    san: &mut Vec<String>,
    san_ip: &mut Vec<[u8; 4]>,
    san_email: &mut Vec<String>,
    ocsp_uris: &mut Vec<String>,
    eku: &mut Vec<Vec<u8>>,
    nc_permit: &mut Vec<String>,
    nc_exclude: &mut Vec<String>,
    nc_permit_email: &mut Vec<String>,
    nc_exclude_email: &mut Vec<String>,
    ski: &mut Vec<u8>,
    aki: &mut Vec<u8>,
) -> Result<(), String> {
    let (seq, rest) = asn1::expect(explicit, SEQ)?;
    if !rest.is_empty() {
        return Err("x509: exts".into());
    }
    for ext in asn1::children(seq.value)? {
        if ext.tag != SEQ {
            continue;
        }
        let f = asn1::children(ext.value)?;
        if f.is_empty() || f[0].tag != OID {
            continue;
        }
        let mut k = 1usize;
        let mut critical = false;
        if f.get(k).map(|t| t.tag) == Some(0x01) {
            critical = f[k].value == [0xff];
            k += 1;
        }
        let oct = f.get(k).ok_or("x509: ext value")?;
        if oct.tag != OCTET {
            return Err("x509: ext octet".into());
        }
        let oid = f[0].value;
        if oid == OID_BC {
            bc(oct.value, is_ca, path_len)?;
        } else if oid == OID_KU {
            *key_usage = Some(ku(oct.value)?);
        } else if oid == OID_SAN {
            san_names(oct.value, san, san_ip, san_email)?;
        } else if oid == OID_AIA {
            aia_ocsp(oct.value, ocsp_uris)?;
        } else if oid == OID_EKU {
            eku_oids(oct.value, eku)?;
        } else if oid == OID_NC {
            name_constraints(
                oct.value,
                nc_permit,
                nc_exclude,
                nc_permit_email,
                nc_exclude_email,
            )?;
        } else if oid == OID_SKI {
            *ski = ski_bytes(oct.value)?;
        } else if oid == OID_AKI {
            *aki = aki_keyid(oct.value)?;
        } else if critical {
            return Err("x509: critical unknown".into());
        }
    }
    Ok(())
}

fn bc(der: &[u8], is_ca: &mut bool, path_len: &mut Option<u32>) -> Result<(), String> {
    let (seq, _) = asn1::expect(der, SEQ)?;
    for t in asn1::children(seq.value)? {
        if t.tag == 0x01 {
            *is_ca = t.value == [0xff];
        } else if t.tag == INT {
            let v = asn1::int_be(t.value)?;
            let mut n = 0u32;
            for b in v {
                n = n.saturating_mul(256).saturating_add(b as u32);
            }
            *path_len = Some(n);
        }
    }
    Ok(())
}

fn ku(der: &[u8]) -> Result<u16, String> {
    let (bits, _) = asn1::expect(der, BITS)?;
    let p = asn1::bit_payload(bits.value)?;
    let mut u = 0u16;
    for (i, b) in p.iter().enumerate() {
        for bit in 0..8 {
            if b & (0x80 >> bit) != 0 {
                let idx = i * 8 + bit;
                if idx < 16 {
                    u |= 1 << idx;
                }
            }
        }
    }
    Ok(u)
}

fn aia_ocsp(der: &[u8], uris: &mut Vec<String>) -> Result<(), String> {
    let (seq, _) = asn1::expect(der, SEQ)?;
    for ad in asn1::children(seq.value)? {
        if ad.tag != SEQ {
            continue;
        }
        let f = asn1::children(ad.value)?;
        if f.len() < 2 || f[0].tag != OID {
            continue;
        }
        if f[0].value == OID_AD_OCSP && f[1].tag == 0x86 {
            let s = core::str::from_utf8(f[1].value).map_err(|_| "x509: ocsp uri")?;
            if s.starts_with("http://") {
                uris.push(s.to_string());
            }
        }
    }
    Ok(())
}

fn eku_oids(der: &[u8], eku: &mut Vec<Vec<u8>>) -> Result<(), String> {
    let (seq, _) = asn1::expect(der, SEQ)?;
    for t in asn1::children(seq.value)? {
        if t.tag == OID {
            eku.push(t.value.to_vec());
        }
    }
    Ok(())
}

fn ski_bytes(der: &[u8]) -> Result<Vec<u8>, String> {
    match asn1::expect(der, OCTET) {
        Ok((oct, rest)) if rest.is_empty() => Ok(oct.value.to_vec()),
        _ => Ok(der.to_vec()),
    }
}

fn aki_keyid(der: &[u8]) -> Result<Vec<u8>, String> {
    if let Ok((seq, _)) = asn1::expect(der, SEQ) {
        for t in asn1::children(seq.value)? {
            if t.tag == 0x80 {
                return Ok(t.value.to_vec());
            }
        }
    }
    Ok(Vec::new())
}

fn name_constraints(
    der: &[u8],
    permit: &mut Vec<String>,
    exclude: &mut Vec<String>,
    permit_email: &mut Vec<String>,
    exclude_email: &mut Vec<String>,
) -> Result<(), String> {
    let (seq, _) = asn1::expect(der, SEQ)?;
    for t in asn1::children(seq.value)? {
        let dns = if t.tag == 0xa0 {
            &mut *permit
        } else if t.tag == 0xa1 {
            &mut *exclude
        } else {
            continue;
        };
        let email = if t.tag == 0xa0 {
            &mut *permit_email
        } else {
            &mut *exclude_email
        };
        for st in asn1::children(t.value)? {
            if st.tag != SEQ {
                continue;
            }
            for gn in asn1::children(st.value)? {
                if gn.tag == 0x82 {
                    let s = core::str::from_utf8(gn.value).map_err(|_| "x509: nc utf8")?;
                    dns.push(s.to_ascii_lowercase());
                } else if gn.tag == 0x81 {
                    let s = core::str::from_utf8(gn.value).map_err(|_| "x509: nc utf8")?;
                    email.push(s.to_string());
                } else if gn.tag == 0xa4 {
                    let cn = dn_cn(gn.value)?;
                    dns.push(format!("cn={cn}"));
                } else {
                    return Err("x509: name constraint not dns/email/dir".into());
                }
            }
        }
    }
    Ok(())
}

/// RFC 5280 DNS subtree: `.test` matches `www.tls.test`; `example.com` matches that name and children.
pub fn dns_in_constraint(name: &str, constraint: &str) -> bool {
    let n = name.trim_end_matches('.').to_ascii_lowercase();
    let c = constraint.trim_end_matches('.').to_ascii_lowercase();
    if c.is_empty() || n.is_empty() {
        return false;
    }
    if let Some(rest) = c.strip_prefix('.') {
        n == rest || n.ends_with(&c)
    } else {
        n == c || n.ends_with(&format!(".{c}"))
    }
}

/// RFC 5280 rfc822Name: full mailbox is exact (local case-sensitive);
/// host / `.host` matches the domain (case-insensitive).
pub fn email_in_constraint(addr: &str, constraint: &str) -> bool {
    let a = addr.trim();
    let c = constraint.trim();
    if a.is_empty() || c.is_empty() {
        return false;
    }
    if c.contains('@') {
        match (a.split_once('@'), c.split_once('@')) {
            (Some((al, ad)), Some((cl, cd))) => al == cl && ad.eq_ignore_ascii_case(cd),
            _ => false,
        }
    } else {
        let ad = match a.split_once('@') {
            Some((_, d)) => d.to_ascii_lowercase(),
            None => return false,
        };
        dns_in_constraint(&ad, &c.to_ascii_lowercase())
    }
}

/// TLS serverAuth, or no EKU (unrestricted). anyExtendedKeyUsage is accepted.
pub fn tls_server_eku_ok(cert: &Cert) -> bool {
    if cert.eku.is_empty() {
        return true;
    }
    cert.eku
        .iter()
        .any(|o| o.as_slice() == OID_EKU_SERVER_AUTH || o.as_slice() == OID_ANY_EKU)
}

fn dn_cn(der: &[u8]) -> Result<String, String> {
    let rdns = if der.first() == Some(&SEQ) {
        asn1::children(asn1::expect(der, SEQ)?.0.value)?
    } else {
        asn1::children(der)?
    };
    for rdn in rdns {
        if rdn.tag != SEQ && rdn.tag != 0x31 {
            continue;
        }
        let sets = if rdn.tag == 0x31 {
            asn1::children(rdn.value)?
        } else {
            vec![rdn]
        };
        for at in sets {
            let seq = if at.tag == SEQ { at.value } else { continue };
            let f = asn1::children(seq)?;
            if f.len() >= 2 && f[0].tag == OID && f[0].value == OID_CN {
                let s = core::str::from_utf8(f[1].value).unwrap_or("");
                return Ok(s.to_ascii_lowercase());
            }
        }
    }
    Err("x509: directoryName cn".into())
}

fn names_for_nc(cert: &Cert) -> Vec<String> {
    if !cert.san.is_empty() {
        cert.san.clone()
    } else if !cert.cn.is_empty() {
        vec![cert.cn.to_ascii_lowercase()]
    } else {
        Vec::new()
    }
}

/// Issuer nameConstraints apply to every subsequent subject (leaf first in `chain`).
pub fn check_name_constraints(subject: &Cert, issuer: &Cert) -> Result<(), String> {
    let dns_nc = !issuer.nc_permit_dns.is_empty() || !issuer.nc_exclude_dns.is_empty();
    let email_nc = !issuer.nc_permit_email.is_empty() || !issuer.nc_exclude_email.is_empty();
    if !dns_nc && !email_nc {
        return Ok(());
    }
    if dns_nc {
        let permit_dns: Vec<&str> = issuer
            .nc_permit_dns
            .iter()
            .filter(|c| !c.starts_with("cn="))
            .map(String::as_str)
            .collect();
        let permit_dn: Vec<&str> = issuer
            .nc_permit_dns
            .iter()
            .filter_map(|c| c.strip_prefix("cn="))
            .collect();
        let exclude_dns: Vec<&str> = issuer
            .nc_exclude_dns
            .iter()
            .filter(|c| !c.starts_with("cn="))
            .map(String::as_str)
            .collect();
        let exclude_dn: Vec<&str> = issuer
            .nc_exclude_dns
            .iter()
            .filter_map(|c| c.strip_prefix("cn="))
            .collect();
        if !permit_dn.is_empty() && !permit_dn.iter().any(|c| subject.cn.eq_ignore_ascii_case(c)) {
            return Err("tls: name constraint".into());
        }
        if exclude_dn
            .iter()
            .any(|c| subject.cn.eq_ignore_ascii_case(c))
        {
            return Err("tls: name constraint".into());
        }
        if !permit_dns.is_empty() || !exclude_dns.is_empty() {
            let names = names_for_nc(subject);
            if names.is_empty() {
                return Err("tls: name constraint".into());
            }
            for n in &names {
                if !permit_dns.is_empty() && !permit_dns.iter().any(|c| dns_in_constraint(n, c)) {
                    return Err("tls: name constraint".into());
                }
                if exclude_dns.iter().any(|c| dns_in_constraint(n, c)) {
                    return Err("tls: name constraint".into());
                }
            }
        }
    }
    if email_nc {
        if subject.san_email.is_empty() && !issuer.nc_permit_email.is_empty() {
            return Err("tls: name constraint".into());
        }
        for e in &subject.san_email {
            if !issuer.nc_permit_email.is_empty()
                && !issuer
                    .nc_permit_email
                    .iter()
                    .any(|c| email_in_constraint(e, c))
            {
                return Err("tls: name constraint".into());
            }
            if issuer
                .nc_exclude_email
                .iter()
                .any(|c| email_in_constraint(e, c))
            {
                return Err("tls: name constraint".into());
            }
        }
    }
    Ok(())
}

fn san_names(
    der: &[u8],
    dns: &mut Vec<String>,
    ips: &mut Vec<[u8; 4]>,
    email: &mut Vec<String>,
) -> Result<(), String> {
    let (seq, _) = asn1::expect(der, SEQ)?;
    for gn in asn1::children(seq.value)? {
        match gn.tag {
            0x82 => {
                let s = core::str::from_utf8(gn.value).map_err(|_| "x509: san utf8")?;
                dns.push(s.to_ascii_lowercase());
            }
            0x81 => {
                let s = core::str::from_utf8(gn.value).map_err(|_| "x509: san utf8")?;
                email.push(s.to_string());
            }
            0x87 if gn.value.len() == 4 => {
                let mut a = [0u8; 4];
                a.copy_from_slice(gn.value);
                ips.push(a);
            }
            _ => {}
        }
    }
    Ok(())
}

fn ecdsa_sig(sig: &[u8]) -> Option<(Vec<u8>, Vec<u8>)> {
    let (seq, rest) = asn1::expect(sig, SEQ).ok()?;
    if !rest.is_empty() {
        return None;
    }
    let ch = asn1::children(seq.value).ok()?;
    if ch.len() < 2 || ch[0].tag != INT || ch[1].tag != INT {
        return None;
    }
    Some((
        asn1::int_be(ch[0].value).ok()?,
        asn1::int_be(ch[1].value).ok()?,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn aia_ocsp_http_only() {
        let der = {
            let oid = [0x06, 0x08, 0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x30, 0x01];
            let uri = b"http://10.0.2.2/ocsp";
            let mut loc = vec![0x86, uri.len() as u8];
            loc.extend_from_slice(uri);
            let mut ad = Vec::new();
            ad.extend_from_slice(&oid);
            ad.extend_from_slice(&loc);
            let mut inner = vec![0x30, ad.len() as u8];
            inner.extend(ad);
            let mut top = vec![0x30, inner.len() as u8];
            top.extend(inner);
            top
        };
        let mut uris = Vec::new();
        aia_ocsp(&der, &mut uris).unwrap();
        assert_eq!(uris, vec!["http://10.0.2.2/ocsp".to_string()]);
    }

    #[test]
    fn dns_constraint_dot_test_matches_www_tls_test() {
        assert!(dns_in_constraint("www.tls.test", ".test"));
        assert!(dns_in_constraint("int.lev1.ca.authority", ".ca.authority"));
        assert!(!dns_in_constraint("www.tls.test", ".testx"));
        assert!(dns_in_constraint("www.tls.test", ".test"));
        assert!(!dns_in_constraint(
            "www.tls.test",
            "www.tls.test.invalid.test"
        ));
    }

    #[test]
    fn ski_aki_and_email_constraint() {
        let id = [0xabu8; 20];
        let mut ski = vec![0x04, 20];
        ski.extend_from_slice(&id);
        assert_eq!(ski_bytes(&ski).unwrap(), id);
        let mut aki_body = vec![0x80, 20];
        aki_body.extend_from_slice(&id);
        let mut aki = vec![0x30, aki_body.len() as u8];
        aki.extend(aki_body);
        assert_eq!(aki_keyid(&aki).unwrap(), id);
        assert!(email_in_constraint("user@example.com", "user@example.com"));
        assert!(!email_in_constraint("User@example.com", "user@example.com"));
        assert!(email_in_constraint("a@mail.test", ".test"));
        assert!(email_in_constraint("a@mail.test", "mail.test"));
        assert!(!email_in_constraint("a@evil.test", "mail.test"));
        assert!(!email_in_constraint("a@mail.test", "b@mail.test"));
        let cn = b"leaf";
        let mut atv = vec![0x06, 3, 0x55, 0x04, 0x03, 0x13, cn.len() as u8];
        atv.extend_from_slice(cn);
        let mut seq = vec![0x30, atv.len() as u8];
        seq.extend(atv);
        let mut set = vec![0x31, seq.len() as u8];
        set.extend(seq);
        let mut name = vec![0x30, set.len() as u8];
        name.extend(set);
        assert_eq!(dn_cn(&name).unwrap(), "leaf");
    }
}
