// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! TLS 1.3 handshake transcript and Finished (RFC 8446 §4.4.4 / §7.1).
//! Not a full handshake.

#![allow(missing_docs)]

use crate::hkdf::expand_label;
use crate::hmac::hmac_sha256;
use crate::sha::sha256;

const MAX_TRANSCRIPT: usize = 64 * 1024;

/// Concatenation of handshake messages (type + 24-bit length + body).
#[derive(Clone, Default)]
pub struct HandshakeTranscript {
    buf: Vec<u8>,
}

impl HandshakeTranscript {
    pub fn new() -> Self {
        Self { buf: Vec::new() }
    }

    /// `msg` is one handshake message, including the 4-byte header.
    pub fn push(&mut self, msg: &[u8]) -> Result<(), String> {
        if msg.len() < 4 {
            return Err("tls: handshake msg".into());
        }
        let n = ((msg[1] as usize) << 16) | ((msg[2] as usize) << 8) | (msg[3] as usize);
        if msg.len() != 4 + n {
            return Err("tls: handshake length".into());
        }
        if self.buf.len().saturating_add(msg.len()) > MAX_TRANSCRIPT {
            return Err("tls: transcript too long".into());
        }
        self.buf.extend_from_slice(msg);
        Ok(())
    }

    pub fn hash(&self) -> [u8; 32] {
        sha256(&self.buf)
    }
}

/// `HKDF-Expand-Label(base, "finished", "", Hash.length)`.
pub fn finished_key(base: &[u8]) -> Result<[u8; 32], String> {
    let v = expand_label(base, "finished", &[], 32)?;
    let mut out = [0u8; 32];
    out.copy_from_slice(&v);
    Ok(out)
}

/// `HMAC(finished_key, Transcript-Hash)`.
pub fn finished_mac(key: &[u8; 32], transcript_hash: &[u8; 32]) -> [u8; 32] {
    hmac_sha256(key, transcript_hash)
}

/// Constant-time compare. Mismatch is `tls: finished`.
pub fn check_finished(
    key: &[u8; 32],
    transcript_hash: &[u8; 32],
    verify_data: &[u8],
) -> Result<(), String> {
    if verify_data.len() != 32 {
        return Err("tls: finished".into());
    }
    let got = finished_mac(key, transcript_hash);
    let mut diff = 0u8;
    for i in 0..32 {
        diff |= got[i] ^ verify_data[i];
    }
    if diff != 0 {
        Err("tls: finished".into())
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hx(s: &str) -> Vec<u8> {
        (0..s.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
            .collect()
    }

    #[test]
    fn rfc8448_ch_sh_transcript_hash() {
        let ch = hx(
            "010000c00303cb34ecb1e78163ba1c38c6dacb196a6dffa21a8d9912ec18a2ef6283024dece7000006130113031302010000910000000b0009000006736572766572ff01000100000a00140012001d0017001800190100010101020103010400230000003300260024001d002099381de560e4bd43d23d8e435a7dbafeb3c06e51c13cae4d5413691e529aaf2c002b0003020304000d0020001e040305030603020308040805080604010501060102010402050206020202002d00020101001c00024001",
        );
        let sh = hx(
            "020000560303a6af06a4121860dc5e6e60249cd34c95930c8ac5cb1434dac155772ed3e2692800130100002e00330024001d0020c9828876112095fe66762bdbf7c672e156d6cc253b833df1dd69b1b04e751f0f002b00020304",
        );
        let mut t = HandshakeTranscript::new();
        t.push(&ch).unwrap();
        t.push(&sh).unwrap();
        assert_eq!(
            t.hash(),
            hx("860c06edc07858ee8e78f0e7428c58edd6b43f2ca3e6e95f02ed063cf0e1cad8")[..]
        );
        assert!(t.push(&[0x01, 0x00, 0x00, 0x01]).is_err());
    }

    #[test]
    fn rfc8448_finished_key_and_check() {
        let prk = hx("b67b7d690cc16c4e75e54213cb2d37b4e9c912bcded9105d42befd59d391ad38");
        let key = finished_key(&prk).unwrap();
        assert_eq!(
            key,
            hx("008d3b66f816ea559f96b537e885c31fc068bf492c652f01f288a1d8cdc19fc8")[..]
        );
        let th = [0x11u8; 32];
        let mac = finished_mac(&key, &th);
        check_finished(&key, &th, &mac).unwrap();
        let mut bad = mac;
        bad[0] ^= 1;
        assert!(check_finished(&key, &th, &bad).unwrap_err().contains("finished"));
    }
}
