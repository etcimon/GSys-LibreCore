// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! HMAC-SHA256 (RFC 2104). Botan `mac/hmac`.

#![allow(missing_docs)]

use crate::sha::sha256;

/// HMAC-SHA256.
pub fn hmac_sha256(key: &[u8], data: &[u8]) -> [u8; 32] {
    let mut k = [0u8; 64];
    if key.len() > 64 {
        let h = sha256(key);
        k[..32].copy_from_slice(&h);
    } else {
        k[..key.len()].copy_from_slice(key);
    }
    let mut ipad = [0x36u8; 64];
    let mut opad = [0x5cu8; 64];
    for (ip, &kb) in ipad.iter_mut().zip(k.iter()) {
        *ip ^= kb;
    }
    for (op, &kb) in opad.iter_mut().zip(k.iter()) {
        *op ^= kb;
    }
    let mut inner = Vec::with_capacity(64 + data.len());
    inner.extend_from_slice(&ipad);
    inner.extend_from_slice(data);
    let ih = sha256(&inner);
    let mut outer = Vec::with_capacity(96);
    outer.extend_from_slice(&opad);
    outer.extend_from_slice(&ih);
    sha256(&outer)
}
