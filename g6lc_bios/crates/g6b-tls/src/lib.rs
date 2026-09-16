// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! First-party TLS / X.509 / RSA / ECDSA for HolyC HTTPS.
//! Spec: `kernel-spec/botan` (BSD-2-Clause, not linked). Not OpenSSL.

#![allow(missing_docs)]

mod aes;
mod asn1;
mod bigint;
mod cert;
mod clock;
mod ecdsa;
mod entropy;
mod gcm;
mod handshake;
mod hello;
mod hkdf;
mod hmac;
mod ocsp;
mod record;
mod rsa;
mod server;
mod session;
mod sha;
mod sha1;
mod store;
mod tls12;
mod tls13;
mod transcript;
mod verify;
mod x25519;

pub use aes::aes128_encrypt_block;
pub use cert::{
    certs_from_tls13, check_name_constraints, dns_in_constraint, email_in_constraint,
    leaf_from_tls13_certificate, name_matches, ocsp_staple_from_tls13, parse as parse_cert,
    parse_chain as parse_cert_chain, rsa_pub as rsa_pub_from_cert, tls_server_eku_ok,
    verify_signature as verify_cert_signature, Cert, KU_DIGITAL_SIGNATURE, KU_KEY_CERT_SIGN,
};
pub use clock::{check_validity, Clock, FixtureClock, NoClock, VirtioRtc};
pub use ecdsa::ecdsa_p256_sha256_verify;
pub use entropy::{entropy_health, Entropy, FixtureEntropy, HmacDrbg, NoEntropy, VirtioRng};
pub use gcm::{open as aes128_gcm_open, seal as aes128_gcm_seal, tls13_nonce};
pub use handshake::{complete_tls12_ecdhe_gcm, complete_tls13_1rtt, Traffic12, Traffic13};
pub use hello::{client_hello, client_hello_with, is_web_compatible, offers_tls12_fallback};
pub use hkdf::{
    derive_secret, expand as hkdf_expand, expand_label as hkdf_expand_label,
    extract as hkdf_extract, hkdf, traffic_keys as tls13_traffic_keys,
};
pub use hmac::{hmac_sha256, pbkdf2_hmac_sha256, tls12_prf_sha256};
pub use ocsp::{
    check as check_ocsp, parse_basic as parse_ocsp, request_for_serial as ocsp_request_for_serial,
    OcspResponse, OcspStatus,
};
pub use record::{
    bad_record_mac, close_notify, decode_alert, decrypt_error, handshake_failure, open_record,
    seal_record, seal_record_padded, unexpected_message, RecordReasm, REC_ALERT,
};
pub use rsa::{
    rsa_pkcs1_sha1_verify, rsa_pkcs1_sha256_sign, rsa_pkcs1_sha256_verify, rsa_pss_sha256_sign,
    rsa_pss_sha256_verify, RsaPub,
};
pub use server::{
    is_app_record, is_client_hello, server_handshake, unwrap_app, wrap_app, REC_APP, REC_HANDSHAKE,
};
pub use session::{issue_ticket, new_session_ticket, res_master, SessionCache, Ticket};
pub use sha::sha256;
pub use sha1::sha1;
pub use store::CertStore;
pub use tls12::{
    change_cipher_spec, open_record_tls12, parse_ccs, parse_client_key_exchange,
    parse_server_hello_done, parse_server_key_exchange, parse_tls12_certificate, seal_record_tls12,
    tls12_ecdhe_x25519, tls12_finished, tls12_finished_msg, tls12_gcm_nonce,
    verify_server_key_exchange, REC_CCS,
};
pub use tls13::{
    ap_traffic, client_hello_tls13, client_hello_tls13_psk, exporter_master, handshake_secret,
    handshake_secret_psk_dhe, hs_from_x25519, hs_traffic, key_update_msg, master_secret,
    negotiated_version, offers_tls13, parse_encrypted_extensions, parse_key_update,
    parse_x25519_share, refuse_certificate_request, refuse_hello_retry, traffic_update, ApSecrets,
    TlsVersion, TLS13_AES_128_GCM_SHA256,
};
pub use transcript::{
    check_finished, finished_key, finished_mac, parse_finished, split_handshake,
    HandshakeTranscript,
};
pub use verify::{parse_certificate_verify, verify_certificate_verify};
pub use x25519::{x25519, x25519_public};

/// Hex of SHA-256 (lowercase).
pub fn sha256_hex(data: &[u8]) -> String {
    const H: &[u8; 16] = b"0123456789abcdef";
    let mut s = String::with_capacity(64);
    for b in sha256(data) {
        s.push(H[(b >> 4) as usize] as char);
        s.push(H[(b & 0xf) as usize] as char);
    }
    s
}

/// TLS ClientHello stub marker (not a handshake).
pub fn tls_hello() -> &'static str {
    "TLS-HELLO"
}

/// Classify a TLS record header (5 bytes). Used by the kernel after it
/// reads from an hw TCP socket — this crate does not own the socket.
pub fn tls_record_kind(hdr: &[u8]) -> Result<&'static str, String> {
    if hdr.len() < 5 {
        return Err("tls record truncated".into());
    }
    if hdr[1] != 0x03 || hdr[2] != 0x03 {
        return Err("tls: 1.0/1.1 refused".into());
    }
    match hdr[0] {
        0x16 => Ok("handshake"),
        0x15 => Ok("alert"),
        0x17 => Ok("appdata"),
        0x14 => Ok("ccs"),
        other => Err(format!("tls: not a TLS record (type {other})")),
    }
}

/// HTTPS GET: ClientHello fingerprint + SHA-256 of the URL.
pub fn https_get(url: &str) -> String {
    let host = url
        .trim_start_matches("https://")
        .trim_start_matches("http://")
        .split('/')
        .next()
        .unwrap_or(url);
    let hello = client_hello(host);
    let compat = if is_web_compatible(&hello) {
        "rsa+ecdsa"
    } else {
        "incompatible"
    };
    format!(
        "HTTPS-GET {url} sha256={} hello={} suites={compat}",
        sha256_hex(url.as_bytes()),
        hello.len()
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha256_empty() {
        assert_eq!(
            sha256_hex(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }

    #[test]
    fn sha256_abc() {
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn sha256_two_block() {
        assert_eq!(
            sha256_hex(b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        );
    }

    #[test]
    fn aes128_fips_c1() {
        let key = [
            0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d,
            0x0e, 0x0f,
        ];
        let pt = [
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd,
            0xee, 0xff,
        ];
        let ct = aes128_encrypt_block(&key, &pt);
        assert_eq!(
            ct,
            [
                0x69, 0xc4, 0xe0, 0xd8, 0x6a, 0x7b, 0x04, 0x30, 0xd8, 0xcd, 0xb7, 0x80, 0x70, 0xb4,
                0xc5, 0x5a
            ]
        );
    }

    #[test]
    fn https_get_mentions_url() {
        let s = https_get("https://gsys.dev/");
        assert!(s.contains("HTTPS-GET"), "{s}");
        assert!(s.contains("gsys.dev"), "{s}");
        assert!(s.contains("rsa+ecdsa"), "{s}");
        assert!(!s.to_lowercase().contains("openssl"), "{s}");
    }

    #[test]
    fn tls_record_kind_handshake_and_alert() {
        assert_eq!(
            tls_record_kind(&[0x16, 0x03, 0x03, 0, 1]).unwrap(),
            "handshake"
        );
        assert_eq!(tls_record_kind(&[0x15, 0x03, 0x03, 0, 2]).unwrap(), "alert");
        assert_eq!(tls_record_kind(&[0x14, 0x03, 0x03, 0, 1]).unwrap(), "ccs");
        assert!(tls_record_kind(&[0x16, 0x03, 0x01, 0, 1])
            .unwrap_err()
            .contains("1.0/1.1"));
        assert!(tls_record_kind(&[0x16]).is_err());
        let hello = client_hello("httpbin.org");
        assert!(is_web_compatible(&hello));
        assert!(!hello.is_empty());
        assert!(
            !super::hello::offers_suite(&hello, super::hello::SUITE_RSA_AES128_SHA256),
            "CBC/RSA key transport must not be advertised"
        );
        assert_ne!(
            &hello[11..43],
            &sha256(b"httpbin.org"),
            "hostname hash is not entropy"
        );
        assert!(client_hello_with("httpbin.org", &mut NoEntropy)
            .unwrap_err()
            .contains("entropy"));
        let mut a = FixtureEntropy::from_seed([1; 32]);
        let mut b = FixtureEntropy::from_seed([2; 32]);
        let ha = client_hello_with("httpbin.org", &mut a).unwrap();
        let hb = client_hello_with("httpbin.org", &mut b).unwrap();
        assert_ne!(&ha[11..43], &hb[11..43], "fixture seed changes random");
    }

    #[test]
    fn rsa_pkcs1_sha256_roundtrip() {
        let n = hex::decode_like(
            "815c029ff8b7593781dec7634e505deef848346dd617a7651423760d95bb5de6f104dd990a0e1f0f35b04e637444ac43180c0927bcad89ea0f5f2a5a673c6a3d",
        );
        let sig = hex::decode_like(
            "61709c427fb87e83dd7480f83be96e0ffd448cce36518a6c726f5dcc710c7754f09c80f8ac7bcba1d9fceae8a80d206ceb8c0b8307af4ba2b3fddea440852203",
        );
        let pubk = RsaPub {
            n,
            e: vec![0x01, 0x00, 0x01],
        };
        assert!(rsa_pkcs1_sha256_verify(&pubk, b"g6lc-bios", &sig));
        assert!(!rsa_pkcs1_sha256_verify(&pubk, b"tampered", &sig));
    }

    #[test]
    fn ecdsa_rfc6979_sample() {
        let (qx, qy) = ecdsa::rfc6979_p256_pub();
        let r =
            hex::decode_like("EFD48B2AACB6A8FD1140DD9CD45E81D69D2C877B56AAF991C34D0EA84EAF3716");
        let s =
            hex::decode_like("F7CB1C942D657C41D436C7A1B6E29F65F3E900DBB9AFF4064DC4AB2F843ACDA8");
        assert!(ecdsa_p256_sha256_verify(&qx, &qy, b"sample", &r, &s));
    }

    #[test]
    fn botan_pem_cn_rsa() {
        let pem = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../kernel-spec/botan/test_data/tls_13_rfc8448/server_certificate.pem"
        ));
        let c = parse_cert(pem.as_bytes()).unwrap();
        assert_eq!(c.algo, "rsa");
        assert!(c.cn.contains("rsa"), "{c:?}");
        assert!(c.not_after > c.not_before);
        let pubk = rsa_pub_from_cert(pem.as_bytes()).unwrap();
        assert_eq!(pubk.e, vec![0x01, 0x00, 0x01]);
        assert_eq!(pubk.n.len(), 128);
        assert!(verify_cert_signature(&c, &c));
    }

    fn hex_of(d: &[u8]) -> String {
        const H: &[u8; 16] = b"0123456789abcdef";
        let mut s = String::with_capacity(d.len() * 2);
        for &b in d {
            s.push(H[(b >> 4) as usize] as char);
            s.push(H[(b & 0xf) as usize] as char);
        }
        s
    }

    #[test]
    fn hmac_rfc4231_1() {
        let m = hmac_sha256(b"key", b"The quick brown fox jumps over the lazy dog");
        assert_eq!(
            hex_of(&m),
            "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8"
        );
    }

    mod hex {
        pub fn decode_like(s: &str) -> Vec<u8> {
            let t: String = s.chars().filter(|c| c.is_ascii_hexdigit()).collect();
            (0..t.len())
                .step_by(2)
                .map(|i| u8::from_str_radix(&t[i..i + 2], 16).unwrap())
                .collect()
        }
    }
}
