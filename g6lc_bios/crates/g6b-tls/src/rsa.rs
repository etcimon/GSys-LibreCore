// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! RSA PKCS#1 v1.5 SHA-256 verify. Spec: Botan `pubkey/rsa` (not linked).

#![allow(missing_docs)]

use crate::bigint::BigUint;
use crate::sha::sha256;

/// DigestInfo prefix for SHA-256 (RFC 8017).
const SHA256_PREFIX: &[u8] = &[
    0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05,
    0x00, 0x04, 0x20,
];

/// RSA public key (big-endian modulus / exponent).
#[derive(Clone, Debug)]
pub struct RsaPub {
    pub n: Vec<u8>,
    pub e: Vec<u8>,
}

/// PKCS#1 v1.5 SHA-256 signature verify (web default).
pub fn rsa_pkcs1_sha256_verify(pubk: &RsaPub, msg: &[u8], sig: &[u8]) -> bool {
    let n = BigUint::from_be_bytes(&pubk.n);
    let e = BigUint::from_be_bytes(&pubk.e);
    let k = pubk.n.len();
    if sig.len() != k || k < SHA256_PREFIX.len() + 32 + 11 {
        return false;
    }
    let s = BigUint::from_be_bytes(sig);
    if s.cmp(&n) != core::cmp::Ordering::Less {
        return false;
    }
    let em = s.modpow(&e, &n).to_be_bytes(k);
    let h = sha256(msg);
    // 0x00 0x01 PS 0x00 DigestInfo
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
    let di = [SHA256_PREFIX, h.as_slice()].concat();
    em.get(i..) == Some(di.as_slice())
}
