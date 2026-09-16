// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! AES-128-GCM (NIST SP 800-38D). TLS 1.3 AEAD. 12-byte nonce, 16-byte tag.
//! Not a record layer (`wrap_app` stays plaintext).

#![allow(missing_docs)]

use crate::aes::aes128_encrypt_block;

const TAG_LEN: usize = 16;
const MAX_PT: usize = 16 * 1024 + 256;

fn xor_block(a: &mut [u8; 16], b: &[u8; 16]) {
    for i in 0..16 {
        a[i] ^= b[i];
    }
}

fn inc32(c: &mut [u8; 16]) {
    let n = u32::from_be_bytes(c[12..16].try_into().unwrap()).wrapping_add(1);
    c[12..16].copy_from_slice(&n.to_be_bytes());
}

/// GF(2^128) multiply with R = 0xe1 || 0^120 (NIST SP 800-38D).
fn gcm_mult(x: &[u8; 16], y: &[u8; 16]) -> [u8; 16] {
    let mut z = [0u8; 16];
    let mut v = *y;
    for i in 0..128 {
        if x[i / 8] & (0x80 >> (i % 8)) != 0 {
            xor_block(&mut z, &v);
        }
        let lsb = v[15] & 1;
        for j in (1..16).rev() {
            v[j] = (v[j] >> 1) | (v[j - 1] << 7);
        }
        v[0] >>= 1;
        if lsb != 0 {
            v[0] ^= 0xe1;
        }
    }
    z
}

fn pad16(src: &[u8], dst: &mut Vec<[u8; 16]>) {
    let mut i = 0;
    while i < src.len() {
        let mut b = [0u8; 16];
        let n = (src.len() - i).min(16);
        b[..n].copy_from_slice(&src[i..i + n]);
        dst.push(b);
        i += n;
    }
}

fn ghash(h: &[u8; 16], aad: &[u8], ct: &[u8]) -> [u8; 16] {
    let mut y = [0u8; 16];
    let mut blocks = Vec::new();
    pad16(aad, &mut blocks);
    for b in &blocks {
        xor_block(&mut y, b);
        y = gcm_mult(&y, h);
    }
    blocks.clear();
    pad16(ct, &mut blocks);
    for b in &blocks {
        xor_block(&mut y, b);
        y = gcm_mult(&y, h);
    }
    let mut lenb = [0u8; 16];
    lenb[..8].copy_from_slice(&((aad.len() as u64) * 8).to_be_bytes());
    lenb[8..].copy_from_slice(&((ct.len() as u64) * 8).to_be_bytes());
    xor_block(&mut y, &lenb);
    gcm_mult(&y, h)
}

fn gctr(key: &[u8; 16], mut icb: [u8; 16], data: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(data.len());
    let mut i = 0;
    while i < data.len() {
        let s = aes128_encrypt_block(key, &icb);
        let n = (data.len() - i).min(16);
        for j in 0..n {
            out.push(data[i + j] ^ s[j]);
        }
        i += n;
        inc32(&mut icb);
    }
    out
}

fn j0(nonce: &[u8; 12]) -> [u8; 16] {
    let mut j = [0u8; 16];
    j[..12].copy_from_slice(nonce);
    j[15] = 1;
    j
}

/// Seal. Tag is 16 bytes. Nonce is 12 bytes (TLS 1.3).
pub fn seal(
    key: &[u8; 16],
    nonce: &[u8; 12],
    aad: &[u8],
    pt: &[u8],
) -> Result<(Vec<u8>, [u8; TAG_LEN]), String> {
    if pt.len() > MAX_PT || aad.len() > MAX_PT {
        return Err("gcm: too long".into());
    }
    let h = aes128_encrypt_block(key, &[0u8; 16]);
    let j = j0(nonce);
    let mut ctr = j;
    inc32(&mut ctr);
    let ct = gctr(key, ctr, pt);
    let s = ghash(&h, aad, &ct);
    let t = gctr(key, j, &s);
    let mut tag = [0u8; TAG_LEN];
    tag.copy_from_slice(&t);
    Ok((ct, tag))
}

/// Open. Tag mismatch fails closed (no partial plaintext).
pub fn open(
    key: &[u8; 16],
    nonce: &[u8; 12],
    aad: &[u8],
    ct: &[u8],
    tag: &[u8; TAG_LEN],
) -> Result<Vec<u8>, String> {
    if ct.len() > MAX_PT || aad.len() > MAX_PT {
        return Err("gcm: too long".into());
    }
    let h = aes128_encrypt_block(key, &[0u8; 16]);
    let j = j0(nonce);
    let s = ghash(&h, aad, ct);
    let t = gctr(key, j, &s);
    let mut diff = 0u8;
    for i in 0..TAG_LEN {
        diff |= t[i] ^ tag[i];
    }
    if diff != 0 {
        return Err("gcm: tag".into());
    }
    let mut ctr = j;
    inc32(&mut ctr);
    Ok(gctr(key, ctr, ct))
}

/// TLS 1.3 per-record nonce: `iv XOR (0^32 || seq)`.
pub fn tls13_nonce(iv: &[u8; 12], seq: u64) -> [u8; 12] {
    let mut n = *iv;
    let s = seq.to_be_bytes();
    for i in 0..8 {
        n[4 + i] ^= s[i];
    }
    n
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

    fn arr16(v: &[u8]) -> [u8; 16] {
        let mut a = [0u8; 16];
        a.copy_from_slice(v);
        a
    }

    #[test]
    fn nist_gcm_case_1_empty() {
        let key = [0u8; 16];
        let nonce = [0u8; 12];
        let (ct, tag) = seal(&key, &nonce, &[], &[]).unwrap();
        assert!(ct.is_empty());
        assert_eq!(tag, arr16(&hx("58e2fccefa7e3061367f1d57a4e7455a")));
        assert!(open(&key, &nonce, &[], &[], &tag).unwrap().is_empty());
    }

    #[test]
    fn nist_gcm_case_2_one_block() {
        let key = [0u8; 16];
        let nonce = [0u8; 12];
        let pt = hx("00000000000000000000000000000000");
        let (ct, tag) = seal(&key, &nonce, &[], &pt).unwrap();
        assert_eq!(ct, hx("0388dace60b6a392f328c2b971b2fe78"));
        assert_eq!(tag, arr16(&hx("ab6e47d42cec13bdf53a67b21257bddf")));
        assert_eq!(open(&key, &nonce, &[], &ct, &tag).unwrap(), pt);
        let mut bad = tag;
        bad[0] ^= 1;
        assert!(open(&key, &nonce, &[], &ct, &bad).unwrap_err().contains("tag"));
    }

    #[test]
    fn tls13_nonce_xors_seq_into_low_64() {
        let iv = [0xa5u8; 12];
        assert_eq!(tls13_nonce(&iv, 0), iv);
        let n = tls13_nonce(&iv, 1);
        assert_eq!(n[11], 0xa5 ^ 1);
        assert_eq!(&n[..4], &iv[..4]);
    }
}
