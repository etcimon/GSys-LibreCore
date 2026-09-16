// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! TLS 1.3 CertificateVerify (RFC 8446 §4.4.3).

#![allow(missing_docs)]

use crate::rsa::{rsa_pkcs1_sha256_verify, rsa_pss_sha256_verify, RsaPub};
use crate::sha::sha256;

pub const SIG_RSA_PSS_SHA256: u16 = 0x0804;
pub const SIG_RSA_PKCS1_SHA256: u16 = 0x0401;

const SERVER_CTX: &[u8] = b"TLS 1.3, server CertificateVerify";
const CLIENT_CTX: &[u8] = b"TLS 1.3, client CertificateVerify";

/// 64 spaces + context + 0x00 + Transcript-Hash.
pub fn signed_content(server: bool, transcript_hash: &[u8; 32]) -> Vec<u8> {
    let mut v = vec![0x20u8; 64];
    v.extend_from_slice(if server { SERVER_CTX } else { CLIENT_CTX });
    v.push(0);
    v.extend_from_slice(transcript_hash);
    v
}

pub fn transcript_hash(messages: &[u8]) -> [u8; 32] {
    sha256(messages)
}

/// Verify CertificateVerify. `scheme` is the TLS SignatureScheme.
pub fn verify_certificate_verify(
    pubk: &RsaPub,
    scheme: u16,
    server: bool,
    handshake_messages: &[u8],
    sig: &[u8],
) -> bool {
    let th = transcript_hash(handshake_messages);
    let content = signed_content(server, &th);
    match scheme {
        SIG_RSA_PSS_SHA256 => rsa_pss_sha256_verify(pubk, &content, sig),
        SIG_RSA_PKCS1_SHA256 => rsa_pkcs1_sha256_verify(pubk, &content, sig),
        _ => false,
    }
}

/// Handshake type 0x0f CertificateVerify → (scheme, signature).
pub fn parse_certificate_verify(msg: &[u8]) -> Result<(u16, Vec<u8>), String> {
    if msg.len() < 8 || msg[0] != 0x0f {
        return Err("tls: not CertificateVerify".into());
    }
    let n = ((msg[1] as usize) << 16) | ((msg[2] as usize) << 8) | (msg[3] as usize);
    if msg.len() != 4 + n || n < 4 {
        return Err("tls: CertificateVerify length".into());
    }
    let scheme = u16::from_be_bytes([msg[4], msg[5]]);
    let sl = u16::from_be_bytes([msg[6], msg[7]]) as usize;
    if 8 + sl != msg.len() {
        return Err("tls: CertificateVerify sig".into());
    }
    Ok((scheme, msg[8..].to_vec()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rsa::{rsa_pss_sha256_sign, RsaPub};

    fn hx(s: &str) -> Vec<u8> {
        (0..s.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
            .collect()
    }

    #[test]
    fn rsa_pss_sha256_roundtrip_rfc8448_key() {
        let n = hx("b4bb498f8279303d980836399b36c6988c0c68de55e1bdb826d3901a2461eafd2de49a91d015abbc9a95137ace6c1af19eaa6af98c7ced43120998e187a80ee0ccb0524b1b018c3e0b63264d449a6d38e22a5fda430846748030530ef0461c8ca9d9efbfae8ea6d1d03e2bd193eff0ab9a8002c47428a6d35a8d88d79f7f1e3f");
        let d = hx("04dea705d43a6ea7209dd8072111a83c81e322a59278b33480641eaf7c0a6985b8e31c44f6de62e1b4c2309f6126e77b7c41e923314bbfa3881305dc1217f16c819ce538e922f369828d0e57195d8c8488460207b2faa726bcf708bbd7db7f679f893492fc2a622e08970aac441ce4e0c3088df25ae679233df8a3bda2ff9941");
        let salt = [0x5au8; 32];
        let msg = b"g6lc-tls13-cv";
        let sig = rsa_pss_sha256_sign(&n, &d, msg, &salt).unwrap();
        let pubk = RsaPub {
            n: n.clone(),
            e: vec![0x01, 0x00, 0x01],
        };
        assert!(rsa_pss_sha256_verify(&pubk, msg, &sig));
        assert!(!rsa_pss_sha256_verify(&pubk, b"tampered", &sig));
        let th = transcript_hash(b"ch-sh-ee-cert");
        let content = signed_content(true, &th);
        let sig2 = rsa_pss_sha256_sign(&n, &d, &content, &salt).unwrap();
        assert!(verify_certificate_verify(
            &pubk,
            SIG_RSA_PSS_SHA256,
            true,
            b"ch-sh-ee-cert",
            &sig2
        ));
        let cv = {
            let mut m = vec![0x0f, 0x00, 0x00, 0x84, 0x08, 0x04, 0x00, 0x80];
            m.extend_from_slice(&sig2);
            m
        };
        let (sch, s) = parse_certificate_verify(&cv).unwrap();
        assert_eq!(sch, SIG_RSA_PSS_SHA256);
        assert_eq!(s, sig2);
    }

    #[test]
    fn rfc8448_simple_1rtt_certificate_verify_bytes() {
        let ch = hx("010000c00303cb34ecb1e78163ba1c38c6dacb196a6dffa21a8d9912ec18a2ef6283024dece7000006130113031302010000910000000b0009000006736572766572ff01000100000a00140012001d0017001800190100010101020103010400230000003300260024001d002099381de560e4bd43d23d8e435a7dbafeb3c06e51c13cae4d5413691e529aaf2c002b0003020304000d0020001e040305030603020308040805080604010501060102010402050206020202002d00020101001c00024001");
        let sh = hx("020000560303a6af06a4121860dc5e6e60249cd34c95930c8ac5cb1434dac155772ed3e2692800130100002e00330024001d0020c9828876112095fe66762bdbf7c672e156d6cc253b833df1dd69b1b04e751f0f002b00020304");
        let ee =
            hx("080000240022000a00140012001d00170018001901000101010201030104001c0002400100000000");
        let cert = hx("0b0001b9000001b50001b0308201ac30820115a003020102020102300d06092a864886f70d01010b0500300e310c300a06035504031303727361301e170d3136303733303031323335395a170d3236303733303031323335395a300e310c300a0603550403130372736130819f300d06092a864886f70d010101050003818d0030818902818100b4bb498f8279303d980836399b36c6988c0c68de55e1bdb826d3901a2461eafd2de49a91d015abbc9a95137ace6c1af19eaa6af98c7ced43120998e187a80ee0ccb0524b1b018c3e0b63264d449a6d38e22a5fda430846748030530ef0461c8ca9d9efbfae8ea6d1d03e2bd193eff0ab9a8002c47428a6d35a8d88d79f7f1e3f0203010001a31a301830090603551d1304023000300b0603551d0f0404030205a0300d06092a864886f70d01010b05000381810085aad2a0e5b9276b908c65f73a7267170618a54c5f8a7b337d2df7a594365417f2eae8f8a58c8f8172f9319cf36b7fd6c55b80f21a03015156726096fd335e5e67f2dbf102702e608ccae6bec1fc63a42a99be5c3eb7107c3c54e9b9eb2bd5203b1c3b84e0a8b2f759409ba3eac9d91d402dcc0cc8f8961229ac9187b42b4de10000");
        let cv = hx("0f000084080400805a747c5d88fa9bd2e55ab085a61015b7211f824cd484145ab3ff52f1fda8477b0b7abc90db78e2d33a5c141a078653fa6bef780c5ea248eeaaa785c4f394cab6d30bbe8d4859ee511f602957b15411ac027671459e46445c9ea58c181e818e95b8c3fb0bf3278409d3be152a3da5043e063dda65cdf5aea20d53dfacd42f74f3");
        let mut msgs = Vec::new();
        msgs.extend_from_slice(&ch);
        msgs.extend_from_slice(&sh);
        msgs.extend_from_slice(&ee);
        msgs.extend_from_slice(&cert);
        assert_eq!(
            transcript_hash(&msgs),
            hx("764d6632b3c35c3f3205e3499ac3edbaabb88295fba751461d3678e2e5ea0687")[..]
        );
        let der = crate::cert::leaf_from_tls13_certificate(&cert).unwrap();
        let pubk = crate::cert::rsa_pub(&der).unwrap();
        assert_eq!(pubk.n, hx("b4bb498f8279303d980836399b36c6988c0c68de55e1bdb826d3901a2461eafd2de49a91d015abbc9a95137ace6c1af19eaa6af98c7ced43120998e187a80ee0ccb0524b1b018c3e0b63264d449a6d38e22a5fda430846748030530ef0461c8ca9d9efbfae8ea6d1d03e2bd193eff0ab9a8002c47428a6d35a8d88d79f7f1e3f"));
        assert_eq!(pubk.e, vec![0x01, 0x00, 0x01]);
        let (sch, sig) = parse_certificate_verify(&cv).unwrap();
        assert_eq!(sch, SIG_RSA_PSS_SHA256);
        assert!(verify_certificate_verify(&pubk, sch, true, &msgs, &sig));
        let mut bad = sig.clone();
        bad[0] ^= 1;
        assert!(!verify_certificate_verify(&pubk, sch, true, &msgs, &bad));
    }
}
