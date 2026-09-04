// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! TLS 1.2 ServerHello for BIOS HTTPS file serve.
//! Spec: Botan `tls/messages` ServerHello (not linked). Not OpenSSL.

#![allow(missing_docs)]

use crate::hello::{
    SUITE_ECDHE_ECDSA_AES128_GCM, SUITE_ECDHE_RSA_AES128_GCM, SUITE_RSA_AES128_SHA256,
};
use crate::sha::sha256;

/// Handshake record content type.
pub const REC_HANDSHAKE: u8 = 0x16;
/// Application data record.
pub const REC_APP: u8 = 0x17;

/// True when `raw` is a TLS 1.2 ClientHello record.
pub fn is_client_hello(raw: &[u8]) -> bool {
    raw.len() > 6 && raw[0] == REC_HANDSHAKE && raw[1] == 0x03 && raw[5] == 0x01
}

/// True when `raw` is a TLS application-data record.
pub fn is_app_record(raw: &[u8]) -> bool {
    raw.len() >= 5 && raw[0] == REC_APP && raw[1] == 0x03
}

/// ServerHello + Certificate + ServerHelloDone in one handshake record.
pub fn server_handshake(client_hello: &[u8]) -> Result<Vec<u8>, String> {
    if !is_client_hello(client_hello) {
        return Err("not a TLS 1.2 ClientHello".into());
    }
    let suite = pick_suite(client_hello);
    let mut body = Vec::new();
    body.extend(server_hello_msg(suite, client_hello));
    body.extend(certificate_msg());
    body.extend(hello_done_msg());
    Ok(record(REC_HANDSHAKE, &body))
}

/// Framing only: host tests use plaintext inside the record (cipher after Finished is later).
pub fn wrap_app(http: &[u8]) -> Vec<u8> {
    record(REC_APP, http)
}

/// Strip a TLS application-data record header.
pub fn unwrap_app(raw: &[u8]) -> Result<Vec<u8>, String> {
    if !is_app_record(raw) {
        return Err("not TLS application data".into());
    }
    let n = u16::from_be_bytes([raw[3], raw[4]]) as usize;
    if raw.len() < 5 + n {
        return Err("truncated TLS app record".into());
    }
    Ok(raw[5..5 + n].to_vec())
}

fn pick_suite(hello: &[u8]) -> u16 {
    let has = |a, b| hello.windows(2).any(|w| w == [a, b]);
    if has(0xc0, 0x2f) {
        SUITE_ECDHE_RSA_AES128_GCM
    } else if has(0xc0, 0x2b) {
        SUITE_ECDHE_ECDSA_AES128_GCM
    } else {
        SUITE_RSA_AES128_SHA256
    }
}

fn server_hello_msg(suite: u16, client_hello: &[u8]) -> Vec<u8> {
    let mut rnd = [0u8; 32];
    rnd.copy_from_slice(&sha256(client_hello));
    let mut body = Vec::new();
    body.extend_from_slice(&[0x03, 0x03]);
    body.extend_from_slice(&rnd);
    body.push(0);
    body.extend_from_slice(&suite.to_be_bytes());
    body.push(0);
    handshake(0x02, &body)
}

fn certificate_msg() -> Vec<u8> {
    // One stub certificate (CN=g6lc-bios, RSA OID) — not a CA chain.
    let cert = stub_cert_der();
    let mut list = Vec::new();
    list.extend_from_slice(&(cert.len() as u32).to_be_bytes()[1..]);
    list.extend(cert);
    let mut body = Vec::new();
    body.extend_from_slice(&(list.len() as u32).to_be_bytes()[1..]);
    body.extend(list);
    handshake(0x0b, &body)
}

fn hello_done_msg() -> Vec<u8> {
    handshake(0x0e, &[])
}

fn handshake(typ: u8, body: &[u8]) -> Vec<u8> {
    let n = body.len();
    let mut h = vec![
        typ,
        ((n >> 16) & 0xff) as u8,
        ((n >> 8) & 0xff) as u8,
        (n & 0xff) as u8,
    ];
    h.extend_from_slice(body);
    h
}

fn record(typ: u8, payload: &[u8]) -> Vec<u8> {
    let mut r = vec![typ, 0x03, 0x03];
    r.extend_from_slice(&(payload.len() as u16).to_be_bytes());
    r.extend_from_slice(payload);
    r
}

fn stub_cert_der() -> Vec<u8> {
    // SEQUENCE { SET { SEQUENCE { OID CN, PRINTABLESTRING "g6lc-bios" } }, OID RSA }
    let mut inner = Vec::new();
    inner.extend_from_slice(&[0x06, 0x03, 0x55, 0x04, 0x03]);
    inner.extend_from_slice(&[0x13, 0x09]);
    inner.extend_from_slice(b"g6lc-bios");
    let mut seq = vec![0x30, inner.len() as u8];
    seq.extend(inner);
    let mut set = vec![0x31, seq.len() as u8];
    set.extend(seq);
    let mut name = vec![0x30, set.len() as u8];
    name.extend(set);
    let rsa = [
        0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01,
    ];
    let mut top = Vec::new();
    top.extend(name);
    top.extend_from_slice(&rsa);
    let mut der = vec![0x30, top.len() as u8];
    der.extend(top);
    der
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hello::client_hello;

    #[test]
    fn server_hello_answers_web_client() {
        let ch = client_hello("gsys.dev");
        let sh = server_handshake(&ch).unwrap();
        assert_eq!(sh[0], REC_HANDSHAKE);
        assert!(sh.windows(2).any(|w| w == [0xc0, 0x2f]), "{sh:?}");
        assert!(sh.iter().any(|&b| b == 0x02), "ServerHello");
        assert!(sh.iter().any(|&b| b == 0x0b), "Certificate");
        assert!(sh.iter().any(|&b| b == 0x0e), "HelloDone");
        let wrapped = wrap_app(b"HTTP/1.1 200 OK\r\n\r\n");
        assert!(is_app_record(&wrapped));
        assert_eq!(unwrap_app(&wrapped).unwrap(), b"HTTP/1.1 200 OK\r\n\r\n");
    }
}
