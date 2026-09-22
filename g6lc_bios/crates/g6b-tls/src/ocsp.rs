// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! RFC 6960 BasicOCSPResponse parse. Spec: Botan `cert/x509/ocsp` (not linked).
//! No HTTP fetch.

#![allow(missing_docs)]

use crate::asn1::{self, GENTIME, INT, OCTET, OID, SEQ};
use crate::clock::Clock;
use crate::rsa::{rsa_pkcs1_sha1_verify, rsa_pkcs1_sha256_verify, RsaPub};

const OID_SHA256_RSA: &[u8] = &[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0b];
const OID_SHA1_RSA: &[u8] = &[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x05];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OcspStatus {
    Good,
    Revoked,
    Unknown,
}

#[derive(Clone, Debug)]
pub struct OcspResponse {
    pub serial: Vec<u8>,
    pub status: OcspStatus,
    pub this_update: u64,
    pub tbs: Vec<u8>,
    pub signature: Vec<u8>,
    pub sig_oid: Vec<u8>,
}

/// `BasicOCSPResponse` DER.
pub fn parse_basic(der: &[u8]) -> Result<OcspResponse, String> {
    let (top, rest) = asn1::expect(der, SEQ)?;
    if !rest.is_empty() {
        return Err("ocsp: trailing".into());
    }
    let ch = asn1::children(top.value)?;
    if ch.len() < 3 {
        return Err("ocsp: fields".into());
    }
    if ch[0].tag != SEQ || ch[1].tag != SEQ || ch[2].tag != asn1::BITS {
        return Err("ocsp: tags".into());
    }
    let tbs = ch[0].full.to_vec();
    let sig_oid = {
        let a = asn1::children(ch[1].value)?;
        if a.is_empty() || a[0].tag != OID {
            return Err("ocsp: alg".into());
        }
        a[0].value.to_vec()
    };
    let signature = asn1::bit_payload(ch[2].value)?.to_vec();
    let rd = asn1::children(ch[0].value)?;
    // version [0] optional, responderID, producedAt, responses
    let mut i = 0usize;
    if rd.first().map(|t| t.tag) == Some(0xa0) {
        i = 1;
    }
    if i + 3 > rd.len() {
        return Err("ocsp: tbs".into());
    }
    i += 1; // responderID
    i += 1; // producedAt
    if rd[i].tag != SEQ {
        return Err("ocsp: responses".into());
    }
    let singles = asn1::children(rd[i].value)?;
    let first = singles.first().ok_or("ocsp: empty")?;
    if first.tag != SEQ {
        return Err("ocsp: single".into());
    }
    let sr = asn1::children(first.value)?;
    if sr.len() < 3 {
        return Err("ocsp: single fields".into());
    }
    let cert_id = asn1::children(sr[0].value)?;
    let serial_tlv = cert_id.last().ok_or("ocsp: certid")?;
    if serial_tlv.tag != INT {
        return Err("ocsp: serial".into());
    }
    let serial = asn1::int_be(serial_tlv.value)?;
    let status = match sr[1].tag {
        0x80 => OcspStatus::Good,
        0xa1 | 0x81 => OcspStatus::Revoked,
        0x82 => OcspStatus::Unknown,
        _ => return Err("ocsp: status".into()),
    };
    let this_update = gentime(&sr[2])?;
    Ok(OcspResponse {
        serial,
        status,
        this_update,
        tbs,
        signature,
        sig_oid,
    })
}

fn gentime(t: &asn1::Tlv<'_>) -> Result<u64, String> {
    if t.tag != GENTIME && t.tag != asn1::UTC {
        return Err("ocsp: time".into());
    }
    // reuse cert time via a tiny local parse
    let s = core::str::from_utf8(t.value).map_err(|_| "ocsp: time")?;
    if t.tag == GENTIME && s.len() >= 15 && s.ends_with('Z') {
        let y: i32 = s[0..4].parse().map_err(|_| "ocsp: time")?;
        ocsp_ymdhms(y, &s[4..])
    } else if t.tag == asn1::UTC && s.len() == 13 {
        let yy: i32 = s[0..2].parse().map_err(|_| "ocsp: time")?;
        let y = if yy >= 50 { 1900 + yy } else { 2000 + yy };
        ocsp_ymdhms(y, &s[2..])
    } else {
        Err("ocsp: time".into())
    }
}

fn ocsp_ymdhms(y: i32, rest: &str) -> Result<u64, String> {
    if rest.len() < 11 {
        return Err("ocsp: time".into());
    }
    let m: u32 = rest[0..2].parse().map_err(|_| "ocsp: time")?;
    let d: u32 = rest[2..4].parse().map_err(|_| "ocsp: time")?;
    let h: u32 = rest[4..6].parse().map_err(|_| "ocsp: time")?;
    let mi: u32 = rest[6..8].parse().map_err(|_| "ocsp: time")?;
    let s: u32 = rest[8..10].parse().map_err(|_| "ocsp: time")?;
    let mut days: i64 = 0;
    let yy0 = y.clamp(1970, 9999);
    for yy in 1970..yy0 {
        days += if yy % 4 == 0 && (yy % 100 != 0 || yy % 400 == 0) {
            366
        } else {
            365
        };
    }
    const MD: [i64; 12] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    let months = (m as usize).saturating_sub(1).min(11);
    for (i, days_in_month) in MD.iter().enumerate().take(months) {
        days += days_in_month;
        if i == 1 && y % 4 == 0 {
            days += 1;
        }
    }
    days += d as i64 - 1;
    Ok((days * 86400 + h as i64 * 3600 + mi as i64 * 60 + s as i64) as u64)
}

/// Fail closed on revoked/unknown, serial mismatch, future thisUpdate, bad sig.
pub fn check(
    resp: &OcspResponse,
    serial: &[u8],
    clock: &dyn Clock,
    issuer: Option<&RsaPub>,
) -> Result<(), String> {
    if resp.serial != serial {
        return Err("ocsp: serial".into());
    }
    match resp.status {
        OcspStatus::Good => {}
        OcspStatus::Revoked => return Err("ocsp: revoked".into()),
        OcspStatus::Unknown => return Err("ocsp: unknown".into()),
    }
    let now = clock.unix_seconds()?;
    if resp.this_update > now + 300 {
        return Err("ocsp: thisUpdate".into());
    }
    if let Some(k) = issuer {
        let ok = match resp.sig_oid.as_slice() {
            x if x == OID_SHA256_RSA => rsa_pkcs1_sha256_verify(k, &resp.tbs, &resp.signature),
            x if x == OID_SHA1_RSA => rsa_pkcs1_sha1_verify(k, &resp.tbs, &resp.signature),
            _ => false,
        };
        if !ok {
            return Err("ocsp: signature".into());
        }
    }
    Ok(())
}

/// Minimal `OCSPRequest` for one serial (no HTTP).
pub fn request_for_serial(serial: &[u8]) -> Vec<u8> {
    let mut serial_der = vec![INT, serial.len() as u8];
    serial_der.extend_from_slice(serial);
    let sha1_alg = [
        SEQ,
        0x09,
        OID,
        0x05,
        0x2b,
        0x0e,
        0x03,
        0x02,
        0x1a,
        asn1::NULL,
        0x00,
    ];
    let mut cert_id = Vec::new();
    cert_id.extend_from_slice(&sha1_alg);
    cert_id.extend_from_slice(&[OCTET, 20]);
    cert_id.extend_from_slice(&[0u8; 20]);
    cert_id.extend_from_slice(&[OCTET, 20]);
    cert_id.extend_from_slice(&[0u8; 20]);
    cert_id.extend_from_slice(&serial_der);
    let mut cid_seq = vec![SEQ, cert_id.len() as u8];
    cid_seq.extend(cert_id);
    let mut inner = vec![SEQ, cid_seq.len() as u8];
    inner.extend(&cid_seq);
    let mut req_list = vec![SEQ, inner.len() as u8];
    req_list.extend(&inner);
    let mut tbs = vec![SEQ, req_list.len() as u8];
    tbs.extend(&req_list);
    let mut top = vec![SEQ, tbs.len() as u8];
    top.extend(tbs);
    top
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clock::{FixtureClock, NoClock};

    fn seq(body: &[u8]) -> Vec<u8> {
        let mut v = vec![SEQ];
        if body.len() < 128 {
            v.push(body.len() as u8);
        } else {
            v.push(0x81);
            v.push(body.len() as u8);
        }
        v.extend_from_slice(body);
        v
    }

    fn basic(serial: u8, status: u8) -> Vec<u8> {
        let sha1_alg = [
            SEQ, 0x09, OID, 0x05, 0x2b, 0x0e, 0x03, 0x02, 0x1a, 0x05, 0x00,
        ];
        let mut cid = Vec::new();
        cid.extend_from_slice(&sha1_alg);
        cid.extend_from_slice(&[OCTET, 20]);
        cid.extend_from_slice(&[0u8; 20]);
        cid.extend_from_slice(&[OCTET, 20]);
        cid.extend_from_slice(&[0u8; 20]);
        cid.extend_from_slice(&[INT, 1, serial]);
        let cert_id = seq(&cid);
        let gt = [
            GENTIME, 15, b'2', b'0', b'1', b'6', b'0', b'1', b'0', b'1', b'0', b'0', b'0', b'0',
            b'0', b'0', b'Z',
        ];
        let mut sr = Vec::new();
        sr.extend_from_slice(&cert_id);
        sr.extend_from_slice(&[status, 0x00]);
        sr.extend_from_slice(&gt);
        let single = seq(&sr);
        let responses = seq(&single);
        let mut tbs_body = Vec::new();
        tbs_body.extend_from_slice(&[0x82, 20]);
        tbs_body.extend_from_slice(&[0u8; 20]);
        tbs_body.extend_from_slice(&gt);
        tbs_body.extend_from_slice(&responses);
        let tbs = seq(&tbs_body);
        let alg = [
            SEQ, 0x0d, OID, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0b, 0x05, 0x00,
        ];
        let mut sig = vec![asn1::BITS, 9, 0x00];
        sig.extend_from_slice(&[1, 2, 3, 4, 5, 6, 7, 8]);
        let mut top = Vec::new();
        top.extend_from_slice(&tbs);
        top.extend_from_slice(&alg);
        top.extend_from_slice(&sig);
        seq(&top)
    }

    #[test]
    fn ocsp_good_serial_and_revoked() {
        let der = basic(2, 0x80);
        let r = parse_basic(&der).unwrap();
        assert_eq!(r.status, OcspStatus::Good);
        assert_eq!(r.serial, vec![2]);
        let clock = FixtureClock {
            unix: 1_483_228_800,
        };
        check(&r, &[2], &clock, None).unwrap();
        assert!(check(&r, &[9], &clock, None)
            .unwrap_err()
            .contains("serial"));
        assert!(check(&r, &[2], &NoClock, None)
            .unwrap_err()
            .contains("time"));
        let rev = parse_basic(&basic(2, 0xa1)).unwrap();
        assert_eq!(rev.status, OcspStatus::Revoked);
        assert!(check(&rev, &[2], &clock, None)
            .unwrap_err()
            .contains("revoked"));
        let req = request_for_serial(&[2]);
        assert_eq!(req[0], SEQ);
    }
}
