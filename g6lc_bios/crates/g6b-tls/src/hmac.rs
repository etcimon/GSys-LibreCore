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

/// PBKDF2-HMAC-SHA256 (RFC 8018). Bounded iterations. Not a login session.
pub fn pbkdf2_hmac_sha256(
    password: &[u8],
    salt: &[u8],
    rounds: u32,
    dk_len: usize,
) -> Result<Vec<u8>, String> {
    if rounds == 0 {
        return Err("pbkdf2: rounds".into());
    }
    if dk_len == 0 || dk_len > 1024 {
        return Err("pbkdf2: dkLen".into());
    }
    if salt.is_empty() {
        return Err("pbkdf2: salt".into());
    }
    let mut out = Vec::with_capacity(dk_len);
    let mut block = 1u32;
    while out.len() < dk_len {
        let mut u = {
            let mut s = salt.to_vec();
            s.extend_from_slice(&block.to_be_bytes());
            hmac_sha256(password, &s)
        };
        let mut t = u;
        for _ in 1..rounds {
            u = hmac_sha256(password, &u);
            for (a, b) in t.iter_mut().zip(u.iter()) {
                *a ^= b;
            }
        }
        let need = (dk_len - out.len()).min(32);
        out.extend_from_slice(&t[..need]);
        block = block.saturating_add(1);
        if block == 0 {
            return Err("pbkdf2: overflow".into());
        }
    }
    Ok(out)
}

/// TLS 1.2 PRF with SHA-256 (RFC 5246 §5 P_hash). Not a full 1.2 handshake.
pub fn tls12_prf_sha256(
    secret: &[u8],
    label: &[u8],
    seed: &[u8],
    n: usize,
) -> Result<Vec<u8>, String> {
    if n == 0 || n > 1024 {
        return Err("tls12: prf len".into());
    }
    let mut seed_l = Vec::with_capacity(label.len() + seed.len());
    seed_l.extend_from_slice(label);
    seed_l.extend_from_slice(seed);
    let mut a = hmac_sha256(secret, &seed_l);
    let mut out = Vec::with_capacity(n);
    while out.len() < n {
        let mut inp = Vec::with_capacity(32 + seed_l.len());
        inp.extend_from_slice(&a);
        inp.extend_from_slice(&seed_l);
        let u = hmac_sha256(secret, &inp);
        let need = (n - out.len()).min(32);
        out.extend_from_slice(&u[..need]);
        a = hmac_sha256(secret, &a);
    }
    Ok(out)
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
    fn pbkdf2_rfc6070_sha256_c1() {
        // Common SHA-256 PBKDF2 vector (RFC 6070 shape, SHA-256 PRF).
        let dk = pbkdf2_hmac_sha256(b"password", b"salt", 1, 32).unwrap();
        assert_eq!(
            dk,
            hx("120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
        );
        assert!(pbkdf2_hmac_sha256(b"p", b"salt", 0, 32).is_err());
        assert!(pbkdf2_hmac_sha256(b"p", b"", 1, 32).is_err());
    }

    #[test]
    fn rfc4231_case_1() {
        let key = [0x0bu8; 20];
        let mac = hmac_sha256(&key, b"Hi There");
        assert_eq!(
            mac,
            hx("b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")[..]
        );
    }

    #[test]
    fn tls12_prf_sha256_label_seed() {
        let dk = tls12_prf_sha256(b"secret", b"test label", b"seed", 32).unwrap();
        assert_eq!(
            dk,
            hx("bfc72aea54e12f176b7549dc7d0082fecd2be093284636015f9149017f433669")
        );
        assert_ne!(
            tls12_prf_sha256(b"secret", b"master secret", b"seed", 32).unwrap(),
            dk
        );
        assert!(tls12_prf_sha256(b"s", b"l", b"d", 0).is_err());
    }
}
