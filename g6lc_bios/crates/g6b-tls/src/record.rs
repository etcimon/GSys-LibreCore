// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! TLS 1.3 AEAD record (RFC 8446 §5.2). `wrap_app` stays plaintext.

#![allow(missing_docs)]

use crate::gcm::{open, seal, tls13_nonce};
use crate::server::REC_APP;

const TAG_LEN: usize = 16;
const MAX_INNER: usize = 16 * 1024 + 256;
const MAX_REASM: usize = 5 + 16 * 1024 + 256;

/// TLS 1.3 alert content type (inner).
pub const REC_ALERT: u8 = 0x15;

/// `close_notify` (warning, 0).
pub fn close_notify() -> [u8; 2] {
    [1, 0]
}

/// `handshake_failure` (fatal, 40).
pub fn handshake_failure() -> [u8; 2] {
    [2, 40]
}

/// `unexpected_message` (fatal, 10).
pub fn unexpected_message() -> [u8; 2] {
    [2, 10]
}

/// `bad_record_mac` (fatal, 20).
pub fn bad_record_mac() -> [u8; 2] {
    [2, 20]
}

/// `decrypt_error` (fatal, 51).
pub fn decrypt_error() -> [u8; 2] {
    [2, 51]
}

pub fn decode_alert(body: &[u8]) -> Result<(u8, u8), String> {
    if body.len() != 2 {
        return Err("tls: alert".into());
    }
    if body[0] != 1 && body[0] != 2 {
        return Err("tls: alert level".into());
    }
    Ok((body[0], body[1]))
}

/// Collect a TLSCiphertext split across TCP chunks. One complete record.
#[derive(Default)]
pub struct RecordReasm {
    buf: Vec<u8>,
}

impl RecordReasm {
    pub fn push(&mut self, chunk: &[u8]) -> Result<Option<Vec<u8>>, String> {
        if self.buf.len().saturating_add(chunk.len()) > MAX_REASM {
            return Err("tls: record reasm too long".into());
        }
        self.buf.extend_from_slice(chunk);
        if self.buf.len() < 5 {
            return Ok(None);
        }
        let n = u16::from_be_bytes([self.buf[3], self.buf[4]]) as usize;
        if n == 0 {
            return Err("tls: empty record".into());
        }
        if n > 16 * 1024 + 256 {
            return Err("tls: record too long".into());
        }
        if self.buf.len() < 5 + n {
            return Ok(None);
        }
        Ok(Some(self.buf.drain(..5 + n).collect()))
    }
}

/// Encrypt `content` as a TLS 1.3 application_data record.
/// Inner plaintext is `content || content_type || zeros` (RFC 8446 §5.4).
pub fn seal_record(
    key: &[u8; 16],
    iv: &[u8; 12],
    seq: u64,
    content_type: u8,
    content: &[u8],
) -> Result<Vec<u8>, String> {
    seal_record_padded(key, iv, seq, content_type, content, 0)
}

/// Same as [`seal_record`] with inner zero-padding after the content type.
pub fn seal_record_padded(
    key: &[u8; 16],
    iv: &[u8; 12],
    seq: u64,
    content_type: u8,
    content: &[u8],
    pad: usize,
) -> Result<Vec<u8>, String> {
    if seq == u64::MAX {
        return Err("tls: seq wrap".into());
    }
    if content.len().saturating_add(1).saturating_add(pad) > MAX_INNER {
        return Err("tls: record too long".into());
    }
    let mut inner = Vec::with_capacity(content.len() + 1 + pad);
    inner.extend_from_slice(content);
    inner.push(content_type);
    inner.resize(inner.len() + pad, 0);
    let enc_len = inner.len() + TAG_LEN;
    if enc_len > 0xffff {
        return Err("tls: record too long".into());
    }
    let aad = [REC_APP, 0x03, 0x03, (enc_len >> 8) as u8, enc_len as u8];
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
    let mut end = inner.len();
    while end > 0 && inner[end - 1] == 0 {
        end -= 1;
    }
    if end == 0 {
        return Err("tls: empty inner".into());
    }
    let ty = inner[end - 1];
    let content = &inner[..end - 1];
    if ty == 0 || ty == 20 || ty == 24 {
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
        assert!(seal_record(&key, &iv, u64::MAX, REC_APP, b"x")
            .unwrap_err()
            .contains("seq wrap"));
        let ccs = seal_record(&key, &iv, 2, 20, b"").unwrap();
        assert!(open_record(&key, &iv, 2, &ccs)
            .unwrap_err()
            .contains("inner type"));
        let rec1 = seal_record(&key, &iv, 1, REC_APP, b"ping").unwrap();
        assert_ne!(rec, rec1);
        let padded = seal_record_padded(&key, &iv, 3, REC_APP, b"ping", 5).unwrap();
        let (ty, body) = open_record(&key, &iv, 3, &padded).unwrap();
        assert_eq!(ty, REC_APP);
        assert_eq!(body, b"ping");
        assert!(seal_record_padded(&key, &iv, 4, REC_APP, b"x", MAX_INNER)
            .unwrap_err()
            .contains("too long"));
    }

    #[test]
    fn alert_close_notify_is_inner_type_21() {
        let key = [0x11u8; 16];
        let iv = [0x22u8; 12];
        let rec = seal_record(&key, &iv, 0, REC_ALERT, &close_notify()).unwrap();
        let (ty, body) = open_record(&key, &iv, 0, &rec).unwrap();
        assert_eq!(ty, REC_ALERT);
        assert_eq!(decode_alert(&body).unwrap(), (1, 0));
        let rec = seal_record(&key, &iv, 1, REC_ALERT, &handshake_failure()).unwrap();
        let (ty, body) = open_record(&key, &iv, 1, &rec).unwrap();
        assert_eq!(ty, REC_ALERT);
        assert_eq!(decode_alert(&body).unwrap(), (2, 40));
        assert_eq!(unexpected_message(), [2, 10]);
        assert_eq!(bad_record_mac(), [2, 20]);
        assert_eq!(decrypt_error(), [2, 51]);
        let rec = seal_record(&key, &iv, 2, REC_ALERT, &decrypt_error()).unwrap();
        let (ty, body) = open_record(&key, &iv, 2, &rec).unwrap();
        assert_eq!(ty, REC_ALERT);
        assert_eq!(decode_alert(&body).unwrap(), (2, 51));
        assert!(decode_alert(&[3, 0]).unwrap_err().contains("alert"));
    }

    #[test]
    fn record_reasm_joins_split_header_and_body() {
        let key = [0x33u8; 16];
        let iv = [0x44u8; 12];
        let rec = seal_record(&key, &iv, 0, REC_APP, b"xy").unwrap();
        let mut r = RecordReasm::default();
        assert!(r.push(&rec[..3]).unwrap().is_none());
        let mut empty = RecordReasm::default();
        assert!(empty
            .push(&[0x17, 0x03, 0x03, 0x00, 0x00])
            .unwrap_err()
            .contains("empty record"));
        let mut too = RecordReasm::default();
        assert!(too
            .push(&[0x17, 0x03, 0x03, 0x41, 0x01])
            .unwrap_err()
            .contains("too long"));
        let got = r.push(&rec[3..]).unwrap().expect("complete");
        assert_eq!(got, rec);
        let (ty, body) = open_record(&key, &iv, 0, &got).unwrap();
        assert_eq!(ty, REC_APP);
        assert_eq!(body, b"xy");
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

    #[test]
    fn rfc8448_simple_1rtt_server_appdata_record() {
        let key = arr16(&hx("9f02283b6c9c07efc26bb9f2ac92e356"));
        let iv = arr12(&hx("cf782b88dd83549aadf1e984"));
        let pt: Vec<u8> = (0u8..=0x31).collect();
        let rec = seal_record(&key, &iv, 1, REC_APP, &pt).unwrap();
        let expect = hx(
            "17030300432e937e11ef4ac740e538ad36005fc4a46932fc3225d05f82aa1b36e30efaf97d90e6dffc602dcb501a59a8fcc49c4bf2e5f0a21c0047c2abf332540dd032e167c2955d",
        );
        assert_eq!(rec, expect);
        let (ty, body) = open_record(&key, &iv, 1, &rec).unwrap();
        assert_eq!(ty, REC_APP);
        assert_eq!(body, pt);
    }

    #[test]
    fn rfc8448_simple_1rtt_close_notify_records() {
        let ck = arr16(&hx("17422dda596ed5d9acd890e3c63f5051"));
        let civ = arr12(&hx("5b78923dee08579033e523d9"));
        let crec = seal_record(&ck, &civ, 1, REC_ALERT, &close_notify()).unwrap();
        assert_eq!(crec, hx("1703030013c9872760655666b74d7ff1153efd6db6d0b0e3"));
        let (ty, body) = open_record(&ck, &civ, 1, &crec).unwrap();
        assert_eq!(ty, REC_ALERT);
        assert_eq!(decode_alert(&body).unwrap(), (1, 0));
        let sk = arr16(&hx("9f02283b6c9c07efc26bb9f2ac92e356"));
        let siv = arr12(&hx("cf782b88dd83549aadf1e984"));
        let srec = seal_record(&sk, &siv, 2, REC_ALERT, &close_notify()).unwrap();
        assert_eq!(srec, hx("1703030013b58fd67166ebf599d24720cfbe7efa7a8864a9"));
        let (ty, body) = open_record(&sk, &siv, 2, &srec).unwrap();
        assert_eq!(ty, REC_ALERT);
        assert_eq!(decode_alert(&body).unwrap(), (1, 0));
    }
}
