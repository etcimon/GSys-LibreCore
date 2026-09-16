// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! TLS 1.2 ChangeCipherSpec, AES-GCM record (RFC 5288), Finished
//! verify_data (RFC 5246), and ECDHE ServerKeyExchange. SKE verify is
//! PKCS#1 SHA-256 over client_random||server_random||params.

#![allow(missing_docs)]

use crate::gcm::{open, seal};
use crate::hmac::tls12_prf_sha256;
use crate::rsa::{rsa_pkcs1_sha256_verify, RsaPub};
use crate::sha::sha256;
use crate::x25519::x25519;

/// ChangeCipherSpec record type.
pub const REC_CCS: u8 = 0x14;
const TAG_LEN: usize = 16;

/// `type=20, version=1.2, length=1, 0x01`.
pub fn change_cipher_spec() -> Vec<u8> {
    vec![REC_CCS, 0x03, 0x03, 0x00, 0x01, 0x01]
}

pub fn parse_ccs(rec: &[u8]) -> Result<(), String> {
    if rec == change_cipher_spec() {
        Ok(())
    } else {
        Err("tls: ccs".into())
    }
}

/// RFC 5288 nonce = 4-byte salt || 8-byte explicit (sequence).
pub fn tls12_gcm_nonce(salt: &[u8; 4], seq: u64) -> [u8; 12] {
    let mut n = [0u8; 12];
    n[..4].copy_from_slice(salt);
    n[4..].copy_from_slice(&seq.to_be_bytes());
    n
}

/// TLS 1.2 AES-128-GCM record. Explicit nonce is `seq`. `wrap_app` stays plaintext.
pub fn seal_record_tls12(
    key: &[u8; 16],
    salt: &[u8; 4],
    seq: u64,
    content_type: u8,
    pt: &[u8],
) -> Result<Vec<u8>, String> {
    if pt.len() > 16 * 1024 {
        return Err("tls12: record too long".into());
    }
    let nonce = tls12_gcm_nonce(salt, seq);
    let mut aad = Vec::with_capacity(13);
    aad.extend_from_slice(&seq.to_be_bytes());
    aad.push(content_type);
    aad.extend_from_slice(&[0x03, 0x03]);
    aad.extend_from_slice(&(pt.len() as u16).to_be_bytes());
    let (ct, tag) = seal(key, &nonce, &aad, pt)?;
    let n = 8 + ct.len() + TAG_LEN;
    let mut rec = Vec::with_capacity(5 + n);
    rec.push(content_type);
    rec.extend_from_slice(&[0x03, 0x03]);
    rec.extend_from_slice(&(n as u16).to_be_bytes());
    rec.extend_from_slice(&seq.to_be_bytes());
    rec.extend_from_slice(&ct);
    rec.extend_from_slice(&tag);
    Ok(rec)
}

pub fn open_record_tls12(
    key: &[u8; 16],
    salt: &[u8; 4],
    seq: u64,
    rec: &[u8],
) -> Result<Vec<u8>, String> {
    if rec.len() < 5 + 8 + TAG_LEN {
        return Err("tls12: short record".into());
    }
    if rec[1] != 0x03 || rec[2] != 0x03 {
        return Err("tls12: version".into());
    }
    let n = u16::from_be_bytes([rec[3], rec[4]]) as usize;
    if rec.len() != 5 + n || n < 8 + TAG_LEN {
        return Err("tls12: record length".into());
    }
    let explicit = &rec[5..13];
    if explicit != seq.to_be_bytes() {
        return Err("tls12: nonce".into());
    }
    let body = &rec[13..];
    let ct = &body[..body.len() - TAG_LEN];
    let mut tag = [0u8; TAG_LEN];
    tag.copy_from_slice(&body[body.len() - TAG_LEN..]);
    let nonce = tls12_gcm_nonce(salt, seq);
    let mut aad = Vec::with_capacity(13);
    aad.extend_from_slice(&seq.to_be_bytes());
    aad.push(rec[0]);
    aad.extend_from_slice(&[0x03, 0x03]);
    aad.extend_from_slice(&(ct.len() as u16).to_be_bytes());
    open(key, &nonce, &aad, ct, &tag)
}

/// RFC 5246 Finished verify_data (12 bytes). `label` is `client finished` or `server finished`.
pub fn tls12_finished(master: &[u8], label: &[u8], handshake: &[u8]) -> Result<[u8; 12], String> {
    let h = sha256(handshake);
    let v = tls12_prf_sha256(master, label, &h, 12)?;
    let mut out = [0u8; 12];
    out.copy_from_slice(&v);
    Ok(out)
}

/// Handshake Finished message (type 0x14, 12-byte verify_data).
pub fn tls12_finished_msg(verify: &[u8; 12]) -> Vec<u8> {
    let mut m = vec![0x14, 0x00, 0x00, 0x0c];
    m.extend_from_slice(verify);
    m
}

/// TLS 1.2 ServerHelloDone (handshake type 14, empty).
pub fn parse_server_hello_done(msg: &[u8]) -> Result<(), String> {
    if msg == [0x0e, 0x00, 0x00, 0x00] {
        Ok(())
    } else {
        Err("tls12: server_hello_done".into())
    }
}

/// TLS 1.2 ECDHE ServerKeyExchange (RFC 4492). Named curve only; DHE/RSA-KEX refused.
pub fn parse_server_key_exchange(msg: &[u8]) -> Result<(u16, Vec<u8>), String> {
    let hs = if msg.len() > 5 && msg[0] == 0x16 {
        &msg[5..]
    } else {
        msg
    };
    if hs.len() < 4 || hs[0] != 12 {
        return Err("tls12: not server_key_exchange".into());
    }
    let n = ((hs[1] as usize) << 16) | ((hs[2] as usize) << 8) | (hs[3] as usize);
    if hs.len() != 4 + n {
        return Err("tls12: ske length".into());
    }
    let body = &hs[4..];
    if body.len() < 4 {
        return Err("tls12: ske short".into());
    }
    if body[0] != 3 {
        return Err("tls12: explicit curve refused".into());
    }
    let curve = u16::from_be_bytes([body[1], body[2]]);
    if curve != 0x0017 && curve != 0x001d {
        return Err("tls12: curve".into());
    }
    let plen = body[3] as usize;
    if body.len() < 4 + plen + 2 {
        return Err("tls12: ske point".into());
    }
    let point = body[4..4 + plen].to_vec();
    if point.is_empty() {
        return Err("tls12: ske point".into());
    }
    let rest = &body[4 + plen..];
    if rest.len() < 4 {
        return Err("tls12: ske signature".into());
    }
    let slen = u16::from_be_bytes([rest[2], rest[3]]) as usize;
    if rest.len() != 4 + slen || slen == 0 {
        return Err("tls12: ske signature".into());
    }
    Ok((curve, point))
}

/// RFC 4492: `SHA-256`+`RSA` over `client_random || server_random || params`.
pub fn verify_server_key_exchange(
    pubk: &RsaPub,
    cr: &[u8; 32],
    sr: &[u8; 32],
    msg: &[u8],
) -> Result<(), String> {
    let hs = if msg.len() > 5 && msg[0] == 0x16 {
        &msg[5..]
    } else {
        msg
    };
    if hs.len() < 4 || hs[0] != 12 {
        return Err("tls12: not server_key_exchange".into());
    }
    let n = ((hs[1] as usize) << 16) | ((hs[2] as usize) << 8) | (hs[3] as usize);
    if hs.len() != 4 + n {
        return Err("tls12: ske length".into());
    }
    let body = &hs[4..];
    if body.len() < 4 || body[0] != 3 {
        return Err("tls12: ske params".into());
    }
    let plen = body[3] as usize;
    if body.len() < 4 + plen + 4 {
        return Err("tls12: ske signature".into());
    }
    let params = &body[..4 + plen];
    let rest = &body[4 + plen..];
    let scheme = u16::from_be_bytes([rest[0], rest[1]]);
    if scheme != 0x0401 {
        return Err("tls12: ske scheme".into());
    }
    let slen = u16::from_be_bytes([rest[2], rest[3]]) as usize;
    if rest.len() != 4 + slen || slen == 0 {
        return Err("tls12: ske signature".into());
    }
    let mut content = Vec::with_capacity(64 + params.len());
    content.extend_from_slice(cr);
    content.extend_from_slice(sr);
    content.extend_from_slice(params);
    if !rsa_pkcs1_sha256_verify(pubk, &content, &rest[4..]) {
        return Err("tls12: ske verify".into());
    }
    Ok(())
}

/// TLS 1.2 Certificate (handshake type 11). Reuses X.509 parse.
pub fn parse_tls12_certificate(msg: &[u8]) -> Result<Vec<u8>, String> {
    let hs = if msg.len() > 5 && msg[0] == 0x16 {
        &msg[5..]
    } else {
        msg
    };
    if hs.len() < 7 || hs[0] != 11 {
        return Err("tls12: not certificate".into());
    }
    let n = ((hs[1] as usize) << 16) | ((hs[2] as usize) << 8) | (hs[3] as usize);
    if hs.len() != 4 + n || n < 3 {
        return Err("tls12: cert length".into());
    }
    let list_n = ((hs[4] as usize) << 16) | ((hs[5] as usize) << 8) | (hs[6] as usize);
    if 3 + list_n != n {
        return Err("tls12: cert list".into());
    }
    if list_n < 3 {
        return Err("tls12: empty cert".into());
    }
    let cn = ((hs[7] as usize) << 16) | ((hs[8] as usize) << 8) | (hs[9] as usize);
    if cn == 0 {
        return Err("tls12: empty cert".into());
    }
    if 3 + cn > list_n {
        return Err("tls12: cert truncated".into());
    }
    Ok(hs[10..10 + cn].to_vec())
}

/// TLS 1.2 ECDHE ClientKeyExchange (handshake type 16). RSA-KEX refused.
pub fn parse_client_key_exchange(msg: &[u8]) -> Result<Vec<u8>, String> {
    let hs = if msg.len() > 5 && msg[0] == 0x16 {
        &msg[5..]
    } else {
        msg
    };
    if hs.len() < 5 || hs[0] != 16 {
        return Err("tls12: not client_key_exchange".into());
    }
    let n = ((hs[1] as usize) << 16) | ((hs[2] as usize) << 8) | (hs[3] as usize);
    if hs.len() != 4 + n || n < 2 {
        return Err("tls12: cke length".into());
    }
    let plen = hs[4] as usize;
    if plen + 1 != n || plen == 0 {
        return Err("tls12: rsa kex refused".into());
    }
    if plen != 32 && plen != 65 {
        return Err("tls12: cke point".into());
    }
    Ok(hs[5..5 + plen].to_vec())
}

/// TLS 1.2 ECDHE-X25519 shared secret from our scalar and the peer ServerKeyExchange.
/// Schoolbook X25519; not constant-time. Completed flight is `complete_tls12_ecdhe_gcm`.
pub fn tls12_ecdhe_x25519(sk: &[u8; 32], ske: &[u8]) -> Result<[u8; 32], String> {
    let (curve, pt) = parse_server_key_exchange(ske)?;
    if curve != 0x001d || pt.len() != 32 {
        return Err("tls12: not x25519".into());
    }
    let mut u = [0u8; 32];
    u.copy_from_slice(&pt);
    Ok(x25519(sk, &u))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::{wrap_app, REC_APP, REC_HANDSHAKE};

    #[test]
    fn tls12_ccs_gcm_finished_and_wrap_app_stays_plaintext() {
        parse_ccs(&change_cipher_spec()).unwrap();
        assert!(parse_ccs(&[REC_HANDSHAKE, 0x03, 0x03, 0, 1, 1])
            .unwrap_err()
            .contains("ccs"));
        let key = [0x11u8; 16];
        let salt = [0x22, 0x33, 0x44, 0x55];
        let rec = seal_record_tls12(&key, &salt, 7, REC_APP, b"ping").unwrap();
        assert_eq!(rec[0], REC_APP);
        assert_eq!(&rec[5..13], &7u64.to_be_bytes());
        assert_eq!(open_record_tls12(&key, &salt, 7, &rec).unwrap(), b"ping");
        assert!(open_record_tls12(&key, &salt, 8, &rec).is_err());
        let plain = wrap_app(b"ping");
        assert_eq!(&plain[5..], b"ping");
        assert_ne!(plain, rec);
        let v = tls12_finished(b"secret", b"client finished", b"ch+sh").unwrap();
        assert_eq!(v.len(), 12);
        let again = tls12_finished(b"secret", b"client finished", b"ch+sh").unwrap();
        assert_eq!(v, again);
        assert_ne!(
            tls12_finished(b"secret", b"server finished", b"ch+sh").unwrap(),
            v
        );
        let msg = tls12_finished_msg(&v);
        assert_eq!(msg[0], 0x14);
        assert_eq!(&msg[4..], &v);
        parse_server_hello_done(&[0x0e, 0, 0, 0]).unwrap();
        assert!(parse_server_hello_done(&[0x0e, 0, 0, 1, 0]).is_err());
        let mut ske = vec![12, 0, 0, 0];
        let mut body = vec![3, 0x00, 0x1d, 32];
        body.extend_from_slice(&[0x11u8; 32]);
        body.extend_from_slice(&[0x04, 0x01, 0x00, 0x02, 0xaa, 0xbb]);
        let n = body.len();
        ske[1] = ((n >> 16) & 0xff) as u8;
        ske[2] = ((n >> 8) & 0xff) as u8;
        ske[3] = (n & 0xff) as u8;
        ske.extend(body);
        let (curve, pt) = parse_server_key_exchange(&ske).unwrap();
        assert_eq!(curve, 0x001d);
        assert_eq!(pt.len(), 32);
        let mut dhe = ske.clone();
        dhe[4] = 1;
        assert!(parse_server_key_exchange(&dhe)
            .unwrap_err()
            .contains("explicit curve"));
        let mut cke = vec![16, 0, 0, 33, 32];
        cke.extend_from_slice(&[0x22u8; 32]);
        assert_eq!(parse_client_key_exchange(&cke).unwrap().len(), 32);
        let rsa = vec![16, 0, 0, 2, 0x00, 0x00];
        assert!(parse_client_key_exchange(&rsa)
            .unwrap_err()
            .contains("rsa kex"));
        let cert = vec![11, 0, 0, 6, 0, 0, 3, 0, 0, 0];
        assert!(parse_tls12_certificate(&cert)
            .unwrap_err()
            .contains("empty cert"));
        let mut cert_ok = vec![11, 0, 0, 6, 0, 0, 3, 0, 0, 1, 0x30];
        cert_ok[3] = 7;
        cert_ok[6] = 4;
        assert_eq!(parse_tls12_certificate(&cert_ok).unwrap(), vec![0x30]);
    }

    #[test]
    fn tls12_ecdhe_x25519_shared() {
        let a = [0x11u8; 32];
        let pa = crate::x25519::x25519_public(&a);
        let mut ske = vec![12, 0, 0, 0];
        let mut body = vec![3, 0x00, 0x1d, 32];
        body.extend_from_slice(&pa);
        body.extend_from_slice(&[0x04, 0x01, 0x00, 0x02, 0xaa, 0xbb]);
        let n = body.len();
        ske[1] = ((n >> 16) & 0xff) as u8;
        ske[2] = ((n >> 8) & 0xff) as u8;
        ske[3] = (n & 0xff) as u8;
        ske.extend(body);
        let b = [0x22u8; 32];
        assert_eq!(
            tls12_ecdhe_x25519(&b, &ske).unwrap(),
            crate::x25519::x25519(&b, &pa)
        );
    }
}
