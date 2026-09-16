// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! TLS 1.3 AEAD record (RFC 8446 §5.2). `wrap_app` stays plaintext.

#![allow(missing_docs)]

use crate::gcm::{open, seal, tls13_nonce};
use crate::server::REC_APP;

const TAG_LEN: usize = 16;
const MAX_INNER: usize = 16 * 1024 + 1;

/// Encrypt `content` as a TLS 1.3 application_data record.
/// Inner plaintext is `content || content_type` (no padding).
pub fn seal_record(
    key: &[u8; 16],
    iv: &[u8; 12],
    seq: u64,
    content_type: u8,
    content: &[u8],
) -> Result<Vec<u8>, String> {
    if content.len() + 1 > MAX_INNER {
        return Err("tls: record too long".into());
    }
    let mut inner = Vec::with_capacity(content.len() + 1);
    inner.extend_from_slice(content);
    inner.push(content_type);
    let enc_len = inner.len() + TAG_LEN;
    if enc_len > 0xffff {
        return Err("tls: record too long".into());
    }
    let aad = [
        REC_APP,
        0x03,
        0x03,
        (enc_len >> 8) as u8,
        enc_len as u8,
    ];
    let nonce = tls13_nonce(iv, seq);
    let (ct, tag) = seal(key, &nonce, &aad, &inner)?;
    let mut rec = Vec::with_capacity(5 + enc_len);
    rec.extend_from_slice(&aad);
    rec.extend_from_slice(&ct);
    rec.extend_from_slice(&tag);
    Ok(rec)
}

/// Decrypt a TLS 1.3 application_data record. Returns `(content_type, content)`.
pub fn open_record(
    key: &[u8; 16],
    iv: &[u8; 12],
    seq: u64,
    rec: &[u8],
) -> Result<(u8, Vec<u8>), String> {
    if rec.len() < 5 + TAG_LEN + 1 {
        return Err("tls: short record".into());
    }
    if rec[0] != REC_APP || rec[1] != 0x03 || rec[2] != 0x03 {
        return Err("tls: not an encrypted record".into());
    }
    let n = u16::from_be_bytes([rec[3], rec[4]]) as usize;
    if rec.len() != 5 + n || n < TAG_LEN + 1 {
        return Err("tls: record length".into());
    }
    let body = &rec[5..];
    let ct = &body[..n - TAG_LEN];
    let mut tag = [0u8; TAG_LEN];
    tag.copy_from_slice(&body[n - TAG_LEN..]);
    let aad = &rec[..5];
    let nonce = tls13_nonce(iv, seq);
    let inner = open(key, &nonce, aad, ct, &tag)?;
    let Some((&ty, content)) = inner.split_last() else {
        return Err("tls: empty inner".into());
    };
    if ty == 0 {
        return Err("tls: inner type".into());
    }
    Ok((ty, content.to_vec()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::{unwrap_app, wrap_app};

    fn hx(s: &str) -> Vec<u8> {
        (0..s.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
            .collect()
    }

    fn arr16(v: &[u8]) -> [u8; 16] {
        let mut a = [0u8; 16];
        a.copy_from_slice(v);
        a
    }

    fn arr12(v: &[u8]) -> [u8; 12] {
        let mut a = [0u8; 12];
        a.copy_from_slice(v);
        a
    }

    #[test]
    fn seal_open_round_trip_and_seq() {
        let key = [0x11u8; 16];
        let iv = [0x22u8; 12];
        let rec = seal_record(&key, &iv, 0, REC_APP, b"ping").unwrap();
        let (ty, body) = open_record(&key, &iv, 0, &rec).unwrap();
        assert_eq!(ty, REC_APP);
        assert_eq!(body, b"ping");
        assert!(open_record(&key, &iv, 1, &rec).unwrap_err().contains("tag"));
        let rec1 = seal_record(&key, &iv, 1, REC_APP, b"ping").unwrap();
        assert_ne!(rec, rec1);
    }

    #[test]
    fn wrap_app_stays_plaintext() {
        let w = wrap_app(b"HTTP/1.1 200 OK\r\n\r\n");
        assert_eq!(unwrap_app(&w).unwrap(), b"HTTP/1.1 200 OK\r\n\r\n");
        assert_eq!(&w[5..], b"HTTP/1.1 200 OK\r\n\r\n");
    }

    #[test]
    fn rfc8448_client_appdata_record() {
        let key = arr16(&hx("17422dda596ed5d9acd890e3c63f5051"));
        let iv = arr12(&hx("5b78923dee08579033e523d9"));
        let pt: Vec<u8> = (0u8..=0x31).collect();
        let rec = seal_record(&key, &iv, 0, REC_APP, &pt).unwrap();
        let expect = hx(
            "1703030043a23f7054b62c94d0affafe8228ba55cbefacea42f914aa66bcab3f2b9819a8a5b46b395bd54a9a20441e2b62974e1f5a6292a2977014bd1e3deae63aeebb21694915e4",
        );
        assert_eq!(rec, expect);
        let (ty, body) = open_record(&key, &iv, 0, &rec).unwrap();
        assert_eq!(ty, REC_APP);
        assert_eq!(body, pt);
    }
}
