// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! HKDF-SHA256 (RFC 5869). TLS 1.3 key schedule primitive. Not a handshake.

#![allow(missing_docs)]

use crate::hmac::hmac_sha256;

const HASH_LEN: usize = 32;

/// HKDF-Extract(salt, IKM) → PRK. Empty salt is HashLen zeros.
pub fn extract(salt: &[u8], ikm: &[u8]) -> [u8; HASH_LEN] {
    if salt.is_empty() {
        hmac_sha256(&[0u8; HASH_LEN], ikm)
    } else {
        hmac_sha256(salt, ikm)
    }
}

/// HKDF-Expand(PRK, info, L). L is at most 255 × HashLen.
pub fn expand(prk: &[u8], info: &[u8], len: usize) -> Result<Vec<u8>, String> {
    if prk.len() < HASH_LEN {
        return Err("hkdf: short prk".into());
    }
    if len > 255 * HASH_LEN {
        return Err("hkdf: too long".into());
    }
    if len == 0 {
        return Ok(Vec::new());
    }
    let n = len.div_ceil(HASH_LEN);
    let mut t = [0u8; HASH_LEN];
    let mut t_len = 0usize;
    let mut out = Vec::with_capacity(len);
    for i in 1..=n {
        let mut data = Vec::with_capacity(t_len + info.len() + 1);
        data.extend_from_slice(&t[..t_len]);
        data.extend_from_slice(info);
        data.push(i as u8);
        t = hmac_sha256(prk, &data);
        t_len = HASH_LEN;
        let take = (len - out.len()).min(HASH_LEN);
        out.extend_from_slice(&t[..take]);
    }
    Ok(out)
}

/// Extract then expand.
pub fn hkdf(salt: &[u8], ikm: &[u8], info: &[u8], len: usize) -> Result<Vec<u8>, String> {
    expand(&extract(salt, ikm), info, len)
}

const TLS13_PREFIX: &[u8] = b"tls13 ";

/// RFC 8446 `HKDF-Expand-Label`. 0-RTT labels are refused. 1-RTT PSK
/// resumption (`res master` / `resumption`) is allowed.
pub fn expand_label(
    secret: &[u8],
    label: &str,
    context: &[u8],
    len: usize,
) -> Result<Vec<u8>, String> {
    match label {
        "c e traffic" | "e exp master" => {
            return Err("tls: 0-rtt label refused".into());
        }
        _ => {}
    }
    if label.is_empty() || !label.is_ascii() {
        return Err("hkdf: label".into());
    }
    let mut full = Vec::with_capacity(TLS13_PREFIX.len() + label.len());
    full.extend_from_slice(TLS13_PREFIX);
    full.extend_from_slice(label.as_bytes());
    if full.len() > 255 || context.len() > 255 || len > 0xffff {
        return Err("hkdf: label".into());
    }
    let mut info = Vec::with_capacity(2 + 1 + full.len() + 1 + context.len());
    info.extend_from_slice(&(len as u16).to_be_bytes());
    info.push(full.len() as u8);
    info.extend_from_slice(&full);
    info.push(context.len() as u8);
    info.extend_from_slice(context);
    expand(secret, &info, len)
}

/// RFC 8446 `Derive-Secret(Secret, Label, Messages)`.
pub fn derive_secret(
    secret: &[u8],
    label: &str,
    messages: &[u8],
) -> Result<[u8; HASH_LEN], String> {
    let ctx = crate::sha::sha256(messages);
    let v = expand_label(secret, label, &ctx, HASH_LEN)?;
    let mut out = [0u8; HASH_LEN];
    out.copy_from_slice(&v);
    Ok(out)
}

/// TLS 1.3 `key` (16) + `iv` (12) from a traffic secret. Not a record seal.
pub fn traffic_keys(secret: &[u8]) -> Result<([u8; 16], [u8; 12]), String> {
    let k = expand_label(secret, "key", &[], 16)?;
    let iv = expand_label(secret, "iv", &[], 12)?;
    let mut key = [0u8; 16];
    let mut nonce_iv = [0u8; 12];
    key.copy_from_slice(&k);
    nonce_iv.copy_from_slice(&iv);
    Ok((key, nonce_iv))
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
    fn rfc5869_case_1() {
        let ikm = hx("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b");
        let salt = hx("000102030405060708090a0b0c");
        let info = hx("f0f1f2f3f4f5f6f7f8f9");
        let prk = extract(&salt, &ikm);
        assert_eq!(
            prk,
            hx("077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5")[..]
        );
        let okm = expand(&prk, &info, 42).unwrap();
        assert_eq!(
            okm,
            hx("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
        );
    }

    #[test]
    fn rfc5869_case_3_empty_salt() {
        let ikm = hx("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b");
        let prk = extract(&[], &ikm);
        assert_eq!(
            prk,
            hx("19ef24a32c717b167f33a91d6f648bdf96596776afdb6377ac434c1c293ccb04")[..]
        );
        let okm = expand(&prk, &[], 42).unwrap();
        assert_eq!(
            okm,
            hx("8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8")
        );
    }

    #[test]
    fn expand_refuses_overlong() {
        let prk = [0u8; 32];
        assert!(expand(&prk, &[], 255 * 32 + 1)
            .unwrap_err()
            .contains("too long"));
        assert!(expand(&[], &[], 1).unwrap_err().contains("short prk"));
    }

    #[test]
    fn rfc8448_early_secret_and_derived() {
        let z = [0u8; 32];
        let early = extract(&z, &z);
        assert_eq!(
            early,
            hx("33ad0a1c607ec03b09e6cd9893680ce210adf300aa1f2660e1b22e10f170f92a")[..]
        );
        let derived = derive_secret(&early, "derived", b"").unwrap();
        assert_eq!(
            derived,
            hx("6f2615a108c702c5678f54fc9dbab69716c076189c48250cebeac3576c3611ba")[..]
        );
        let key = expand_label(&derived, "key", &[], 16).unwrap();
        assert_eq!(key.len(), 16);
        assert!(expand_label(&early, "c e traffic", &[], 32)
            .unwrap_err()
            .contains("0-rtt"));
        assert_eq!(
            expand_label(&early, "res master", &[], 32).unwrap().len(),
            32
        );
    }

    #[test]
    fn rfc8448_handshake_write_traffic_keys() {
        let secret = hx("b67b7d690cc16c4e75e54213cb2d37b4e9c912bcded9105d42befd59d391ad38");
        let (key, iv) = traffic_keys(&secret).unwrap();
        assert_eq!(key, hx("3fce516009c21727d0f2e4e86ee403bc")[..]);
        assert_eq!(iv, hx("5d313eb2671276ee13000b30")[..]);
    }
}
