// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! TLS 1.2 ClientHello with web-compatible ECDHE-GCM suites.
//! Spec: Botan `tls/messages` ClientHello (not linked).

#![allow(missing_docs)]

use crate::entropy::{Entropy, FixtureEntropy};

/// IANA: TLS_RSA_WITH_AES_128_CBC_SHA256 — not advertised (CBC / RSA key transport).
pub const SUITE_RSA_AES128_SHA256: u16 = 0x003c;
/// IANA: TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
pub const SUITE_ECDHE_ECDSA_AES128_GCM: u16 = 0xc02b;
/// IANA: TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
pub const SUITE_ECDHE_RSA_AES128_GCM: u16 = 0xc02f;

/// signature_algorithms: rsa_pkcs1_sha256, ecdsa_secp256r1_sha256
pub const SIG_RSA_PKCS1_SHA256: u16 = 0x0401;
pub const SIG_ECDSA_SECP256R1_SHA256: u16 = 0x0403;

/// Test-only ClientHello. Uses [`FixtureEntropy::TEST`], not a CSPRNG.
pub fn client_hello(host: &str) -> Vec<u8> {
    let mut rng = FixtureEntropy::TEST;
    client_hello_with(host, &mut rng).expect("fixture entropy")
}

/// ClientHello random comes from `rng`. Hostname is SNI only.
pub fn client_hello_with(host: &str, rng: &mut dyn Entropy) -> Result<Vec<u8>, String> {
    let mut rnd = [0u8; 32];
    rng.fill(&mut rnd)?;
    let mut body = Vec::new();
    body.extend_from_slice(&[0x03, 0x03]); // legacy version TLS 1.2
    body.extend_from_slice(&rnd);
    body.push(0); // session id
    let suites: [u16; 2] = [
        SUITE_ECDHE_ECDSA_AES128_GCM,
        SUITE_ECDHE_RSA_AES128_GCM,
    ];
    let sl = (suites.len() * 2) as u16;
    body.extend_from_slice(&sl.to_be_bytes());
    for s in suites {
        body.extend_from_slice(&s.to_be_bytes());
    }
    body.extend_from_slice(&[0x01, 0x00]); // null compression
    let mut ext = Vec::new();
    // SNI
    let hb = host.as_bytes();
    let mut sni = Vec::new();
    sni.push(0x00); // host_name
    sni.extend_from_slice(&(hb.len() as u16).to_be_bytes());
    sni.extend_from_slice(hb);
    let mut sni_list = Vec::new();
    sni_list.extend_from_slice(&(sni.len() as u16).to_be_bytes());
    sni_list.extend(sni);
    ext_push(&mut ext, 0x0000, &sni_list);
    // elliptic_curves: secp256r1
    ext_push(&mut ext, 0x000a, &[0x00, 0x02, 0x00, 0x17]);
    // ec_point_formats: uncompressed
    ext_push(&mut ext, 0x000b, &[0x01, 0x00]);
    // signature_algorithms
    let mut sa = vec![0x00, 0x04];
    sa.extend_from_slice(&SIG_ECDSA_SECP256R1_SHA256.to_be_bytes());
    sa.extend_from_slice(&SIG_RSA_PKCS1_SHA256.to_be_bytes());
    ext_push(&mut ext, 0x000d, &sa);
    body.extend_from_slice(&(ext.len() as u16).to_be_bytes());
    body.extend(ext);
    let mut hs = vec![0x01]; // client_hello
    let bl = body.len();
    hs.push(((bl >> 16) & 0xff) as u8);
    hs.push(((bl >> 8) & 0xff) as u8);
    hs.push((bl & 0xff) as u8);
    hs.extend(body);
    let mut rec = vec![0x16, 0x03, 0x03];
    rec.extend_from_slice(&(hs.len() as u16).to_be_bytes());
    rec.extend(hs);
    Ok(rec)
}

fn ext_push(ext: &mut Vec<u8>, id: u16, data: &[u8]) {
    ext.extend_from_slice(&id.to_be_bytes());
    ext.extend_from_slice(&(data.len() as u16).to_be_bytes());
    ext.extend_from_slice(data);
}

/// True if the hello advertises ECDHE-GCM web suites + sigalgs, not CBC/RSA-KEX.
pub fn is_web_compatible(hello: &[u8]) -> bool {
    let has = |a, b| hello.windows(2).any(|w| w == [a, b]);
    hello.len() > 5
        && hello[0] == 0x16
        && hello[1] == 0x03
        && hello[2] == 0x03
        && has(0xc0, 0x2b)
        && has(0xc0, 0x2f)
        && !offers_suite(hello, SUITE_RSA_AES128_SHA256)
        && has(0x04, 0x01)
        && has(0x04, 0x03)
}

pub(crate) fn offers_suite(hello: &[u8], suite: u16) -> bool {
    if hello.len() < 44 {
        return false;
    }
    let sid = hello[43] as usize;
    let at = 44 + sid;
    if hello.len() < at + 2 {
        return false;
    }
    let n = u16::from_be_bytes([hello[at], hello[at + 1]]) as usize;
    let start = at + 2;
    let end = start.saturating_add(n);
    if hello.len() < end {
        return false;
    }
    hello[start..end]
        .chunks_exact(2)
        .any(|c| u16::from_be_bytes([c[0], c[1]]) == suite)
}
