// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! RSA PKCS#1 v1.5 SHA-256 verify. Spec: Botan `pubkey/rsa` (not linked).

#![allow(missing_docs)]

use crate::bigint::BigUint;
use crate::sha::sha256;
use crate::sha1::sha1;

/// DigestInfo prefix for SHA-256 (RFC 8017).
const SHA256_PREFIX: &[u8] = &[
    0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05,
    0x00, 0x04, 0x20,
];
/// DigestInfo prefix for SHA-1 (X.509 path vectors; not TLS 1.3 CV).
const SHA1_PREFIX: &[u8] = &[
    0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e, 0x03, 0x02, 0x1a, 0x05, 0x00, 0x04, 0x14,
];

/// RSA public key (big-endian modulus / exponent).
#[derive(Clone, Debug)]
pub struct RsaPub {
    pub n: Vec<u8>,
    pub e: Vec<u8>,
}

fn rsa_pkcs1_verify(pubk: &RsaPub, sig: &[u8], digest_info: &[u8]) -> bool {
    let n = BigUint::from_be_bytes(&pubk.n);
    let e = BigUint::from_be_bytes(&pubk.e);
    let k = pubk.n.len();
    if sig.len() != k || k < digest_info.len() + 11 {
        return false;
    }
    let s = BigUint::from_be_bytes(sig);
    if s.cmp(&n) != core::cmp::Ordering::Less {
        return false;
    }
    let em = s.modpow(&e, &n).to_be_bytes(k);
    if em[0] != 0 || em[1] != 1 {
        return false;
    }
    let mut i = 2usize;
    while i < em.len() && em[i] == 0xff {
        i += 1;
    }
    if i < 10 || i >= em.len() || em[i] != 0 {
        return false;
    }
    i += 1;
    em.get(i..) == Some(digest_info)
}

/// PKCS#1 v1.5 SHA-256 signature verify (web default).
pub fn rsa_pkcs1_sha256_verify(pubk: &RsaPub, msg: &[u8], sig: &[u8]) -> bool {
    let h = sha256(msg);
    let di = [SHA256_PREFIX, h.as_slice()].concat();
    rsa_pkcs1_verify(pubk, sig, &di)
}

/// PKCS#1 v1.5 SHA-1. X.509 path of older vectors only. Not TLS 1.3 CV.
pub fn rsa_pkcs1_sha1_verify(pubk: &RsaPub, msg: &[u8], sig: &[u8]) -> bool {
    let h = sha1(msg);
    let di = [SHA1_PREFIX, h.as_slice()].concat();
    rsa_pkcs1_verify(pubk, sig, &di)
}

fn mgf1_sha256(seed: &[u8], len: usize) -> Vec<u8> {
    let mut out = Vec::with_capacity(len);
    let mut c = 0u32;
    while out.len() < len {
        let mut block = seed.to_vec();
        block.extend_from_slice(&c.to_be_bytes());
        out.extend_from_slice(&sha256(&block));
        c = c.saturating_add(1);
    }
    out.truncate(len);
    out
}

/// RSA-PSS SHA-256 verify, salt length = 32 (TLS 1.3 `rsa_pss_rsae_sha256`).
pub fn rsa_pss_sha256_verify(pubk: &RsaPub, msg: &[u8], sig: &[u8]) -> bool {
    let n = BigUint::from_be_bytes(&pubk.n);
    let e = BigUint::from_be_bytes(&pubk.e);
    let k = pubk.n.len();
    if sig.len() != k || k < 32 + 32 + 2 {
        return false;
    }
    let s = BigUint::from_be_bytes(sig);
    if s.cmp(&n) != core::cmp::Ordering::Less {
        return false;
    }
    let em = s.modpow(&e, &n).to_be_bytes(k);
    if em.last() != Some(&0xbc) {
        return false;
    }
    let h_len = 32usize;
    let db_len = k - h_len - 1;
    let mut db: Vec<u8> = em[..db_len].to_vec();
    let h = &em[db_len..db_len + h_len];
    let db_mask = mgf1_sha256(h, db_len);
    for (a, b) in db.iter_mut().zip(db_mask.iter()) {
        *a ^= b;
    }
    let em_bits = n.bit_len().saturating_sub(1);
    let unused = 8 * k - em_bits;
    if unused > 0 && unused < 8 {
        db[0] &= 0xffu8 >> unused;
    }
    let mut i = 0usize;
    while i < db_len.saturating_sub(h_len) && db[i] == 0 {
        i += 1;
    }
    if i >= db_len.saturating_sub(h_len) || db[i] != 1 {
        return false;
    }
    i += 1;
    if db_len - i != h_len {
        return false;
    }
    let salt = &db[i..];
    let mut m = vec![0u8; 8];
    m.extend_from_slice(&sha256(msg));
    m.extend_from_slice(salt);
    sha256(&m).as_slice() == h
}

/// PSS-SHA256 sign. `d` is the private exponent (tests / RFC 8448).
pub fn rsa_pss_sha256_sign(
    n: &[u8],
    d: &[u8],
    msg: &[u8],
    salt: &[u8; 32],
) -> Result<Vec<u8>, String> {
    let nn = BigUint::from_be_bytes(n);
    let dd = BigUint::from_be_bytes(d);
    let k = n.len();
    let h_len = 32usize;
    let db_len = k - h_len - 1;
    if db_len < 1 + salt.len() {
        return Err("rsa-pss: key too small".into());
    }
    let mut db = vec![0u8; db_len];
    let ps = db_len - 1 - salt.len();
    db[ps] = 1;
    db[ps + 1..].copy_from_slice(salt);
    let mut m = vec![0u8; 8];
    m.extend_from_slice(&sha256(msg));
    m.extend_from_slice(salt);
    let h = sha256(&m);
    let db_mask = mgf1_sha256(&h, db_len);
    for (a, b) in db.iter_mut().zip(db_mask.iter()) {
        *a ^= b;
    }
    let em_bits = nn.bit_len().saturating_sub(1);
    let unused = 8 * k - em_bits;
    if unused > 0 && unused < 8 {
        db[0] &= 0xffu8 >> unused;
    }
    let mut em = db;
    em.extend_from_slice(&h);
    em.push(0xbc);
    let s = BigUint::from_be_bytes(&em).modpow(&dd, &nn);
    Ok(s.to_be_bytes(k))
}

/// PKCS#1 v1.5 SHA-256 sign. `d` is the private exponent (TLS 1.2 SKE).
pub fn rsa_pkcs1_sha256_sign(n: &[u8], d: &[u8], msg: &[u8]) -> Result<Vec<u8>, String> {
    let nn = BigUint::from_be_bytes(n);
    let dd = BigUint::from_be_bytes(d);
    let k = n.len();
    let h = sha256(msg);
    let di = [SHA256_PREFIX, h.as_slice()].concat();
    if k < di.len() + 11 {
        return Err("rsa-pkcs1: key too small".into());
    }
    let ps = k - di.len() - 3;
    if ps < 8 {
        return Err("rsa-pkcs1: key too small".into());
    }
    let mut em = vec![0u8; k];
    em[1] = 1;
    for b in em.iter_mut().skip(2).take(ps) {
        *b = 0xff;
    }
    em[2 + ps] = 0;
    em[3 + ps..].copy_from_slice(&di);
    let s = BigUint::from_be_bytes(&em).modpow(&dd, &nn);
    Ok(s.to_be_bytes(k))
}
