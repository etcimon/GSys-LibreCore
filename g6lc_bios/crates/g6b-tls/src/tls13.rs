// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! TLS 1.3 key schedule from X25519 ECDHE (RFC 8446 §7.1). Not a full stack.

#![allow(missing_docs)]

use crate::hkdf::{derive_secret, extract};
use crate::x25519::x25519;

const HASH_LEN: usize = 32;
/// TLS_AES_128_GCM_SHA256
pub const TLS13_AES_128_GCM_SHA256: u16 = 0x1301;
/// X25519 named group
pub const GROUP_X25519: u16 = 0x001d;

/// Handshake secrets after ClientHello + ServerHello.
#[derive(Clone, Debug)]
pub struct HsSecrets {
    pub handshake: [u8; HASH_LEN],
    pub c_hs: [u8; HASH_LEN],
    pub s_hs: [u8; HASH_LEN],
}

/// Application traffic secrets after server Finished.
#[derive(Clone, Debug)]
pub struct ApSecrets {
    pub master: [u8; HASH_LEN],
    pub c_ap: [u8; HASH_LEN],
    pub s_ap: [u8; HASH_LEN],
}

fn arr32(v: &[u8]) -> [u8; 32] {
    let mut a = [0u8; 32];
    a.copy_from_slice(v);
    a
}

/// Early secret with no PSK: HKDF-Extract(0, 0).
pub fn early_secret() -> [u8; HASH_LEN] {
    let z = [0u8; HASH_LEN];
    extract(&z, &z)
}

/// Handshake secret from the ECDHE shared secret (no PSK).
pub fn handshake_secret(ecdhe: &[u8; 32]) -> Result<[u8; HASH_LEN], String> {
    handshake_secret_psk_dhe(&early_secret(), ecdhe)
}

/// PSK-DHE: Extract(Derive-Secret(Early, "derived", ""), ECDHE). Still ECDHE.
pub fn handshake_secret_psk_dhe(
    early: &[u8; 32],
    ecdhe: &[u8; 32],
) -> Result<[u8; HASH_LEN], String> {
    let derived = derive_secret(early, "derived", b"")?;
    Ok(extract(&derived, ecdhe))
}

/// `c hs traffic` / `s hs traffic` from CH||SH handshake messages.
pub fn hs_traffic(hs: &[u8; 32], ch_sh: &[u8]) -> Result<HsSecrets, String> {
    Ok(HsSecrets {
        handshake: *hs,
        c_hs: derive_secret(hs, "c hs traffic", ch_sh)?,
        s_hs: derive_secret(hs, "s hs traffic", ch_sh)?,
    })
}

/// Master secret: Extract(Derive-Secret(handshake, "derived", ""), 0).
pub fn master_secret(handshake: &[u8; 32]) -> Result<[u8; HASH_LEN], String> {
    let derived = derive_secret(handshake, "derived", b"")?;
    Ok(extract(&derived, &[0u8; HASH_LEN]))
}

/// RFC 8446 `HKDF-Expand-Label(secret, "traffic upd", "", Hash.length)`.
pub fn traffic_update(secret: &[u8; 32]) -> Result<[u8; HASH_LEN], String> {
    let v = crate::hkdf::expand_label(secret, "traffic upd", &[], HASH_LEN)?;
    let mut out = [0u8; HASH_LEN];
    out.copy_from_slice(&v);
    Ok(out)
}

/// Handshake type 0x18 KeyUpdate. `true` = update_requested.
pub fn parse_key_update(msg: &[u8]) -> Result<bool, String> {
    if msg.len() != 5 || msg[0] != 0x18 {
        return Err("tls: not KeyUpdate".into());
    }
    let n = ((msg[1] as usize) << 16) | ((msg[2] as usize) << 8) | (msg[3] as usize);
    if n != 1 {
        return Err("tls: KeyUpdate length".into());
    }
    match msg[4] {
        0 => Ok(false),
        1 => Ok(true),
        _ => Err("tls: KeyUpdate request".into()),
    }
}

pub fn key_update_msg(request: bool) -> [u8; 5] {
    [0x18, 0x00, 0x00, 0x01, u8::from(request)]
}

/// `Derive-Secret(Master, "exp master", ClientHello…client Finished)`.
pub fn exporter_master(master: &[u8; 32], ch_to_cf: &[u8]) -> Result<[u8; HASH_LEN], String> {
    derive_secret(master, "exp master", ch_to_cf)
}

/// EncryptedExtensions. `early_data` (0x002a) is refused.
pub fn parse_encrypted_extensions(msg: &[u8]) -> Result<(), String> {
    if msg.len() < 6 || msg[0] != 0x08 {
        return Err("tls: not EncryptedExtensions".into());
    }
    let n = ((msg[1] as usize) << 16) | ((msg[2] as usize) << 8) | (msg[3] as usize);
    if msg.len() != 4 + n || n < 2 {
        return Err("tls: EncryptedExtensions length".into());
    }
    let el = u16::from_be_bytes([msg[4], msg[5]]) as usize;
    if 6 + el != msg.len() {
        return Err("tls: EncryptedExtensions ext".into());
    }
    let mut i = 6;
    while i + 4 <= msg.len() {
        let id = u16::from_be_bytes([msg[i], msg[i + 1]]);
        let ln = u16::from_be_bytes([msg[i + 2], msg[i + 3]]) as usize;
        i += 4;
        if i + ln > msg.len() {
            return Err("tls: EncryptedExtensions truncated".into());
        }
        if id == 0x002a {
            return Err("tls: 0-rtt early_data refused".into());
        }
        if id == 0x0031 {
            return Err("tls: post_handshake_auth refused".into());
        }
        if id == 0x0010 {
            parse_alpn(&msg[i..i + ln])?;
        }
        if id == 0x000f {
            return Err("tls: heartbeat refused".into());
        }
        if id == 0x0012 {
            return Err("tls: signed_certificate_timestamp refused".into());
        }
        if id == 0x001b {
            return Err("tls: compress_certificate refused".into());
        }
        if id == 0x002c {
            return Err("tls: cookie in ee refused".into());
        }
        if id == 0x002d {
            return Err("tls: psk_key_exchange_modes in ee refused".into());
        }
        if id == 0xff01 {
            return Err("tls: renegotiation_info in ee refused".into());
        }
        if id == 0x0001 {
            return Err("tls: max_fragment_length refused".into());
        }
        i += ln;
    }
    Ok(())
}

/// ALPN: `h2` preferred, `http/1.1` fallback. `h3` refused.
fn parse_alpn(list: &[u8]) -> Result<(), String> {
    if list.len() < 2 {
        return Err("tls: alpn".into());
    }
    let n = u16::from_be_bytes([list[0], list[1]]) as usize;
    if 2 + n != list.len() {
        return Err("tls: alpn".into());
    }
    let mut i = 2;
    let mut saw = false;
    while i < list.len() {
        let ln = list[i] as usize;
        i += 1;
        if i + ln > list.len() {
            return Err("tls: alpn".into());
        }
        let p = &list[i..i + ln];
        if p == b"h3" {
            return Err("tls: alpn h3 refused".into());
        }
        if p == b"h2" || p == b"http/1.1" {
            saw = true;
        }
        i += ln;
    }
    if !saw {
        return Err("tls: alpn h2 or http/1.1 required".into());
    }
    Ok(())
}

/// RFC 8446 HelloRetryRequest magic random. We do not retry — named refuse.
const HRR_RANDOM: [u8; 32] = [
    0xcf, 0x21, 0xad, 0x74, 0xe5, 0x9a, 0x61, 0x11, 0xbe, 0x1d, 0x8c, 0x02, 0x1e, 0x65, 0xb8, 0x91,
    0xc2, 0xa2, 0x11, 0x16, 0x7a, 0xbb, 0x8c, 0x5e, 0x07, 0x9e, 0x09, 0xe2, 0xc8, 0xa8, 0x33, 0x9c,
];

/// HelloRetryRequest is not implemented.
pub fn refuse_hello_retry(msg: &[u8]) -> Result<(), String> {
    let hs = if msg.len() > 5 && msg[0] == 0x16 {
        &msg[5..]
    } else {
        msg
    };
    if hs.len() < 38 || hs[0] != 2 {
        return Ok(());
    }
    if hs[6..38] == HRR_RANDOM {
        Err("tls: hello_retry_request refused".into())
    } else {
        Ok(())
    }
}

/// `h2` then `http/1.1` (H2 preferred when both are on).
fn alpn_h2_then_http11() -> Vec<u8> {
    let mut proto = Vec::new();
    proto.push(2);
    proto.extend_from_slice(b"h2");
    proto.push(8);
    proto.extend_from_slice(b"http/1.1");
    let mut v = Vec::new();
    v.extend_from_slice(&(proto.len() as u16).to_be_bytes());
    v.extend(proto);
    v
}

/// TLS 1.3 CertificateRequest (0x0d) is not implemented — fail closed.
pub fn refuse_certificate_request(msg: &[u8]) -> Result<(), String> {
    if !msg.is_empty() && msg[0] == 0x0d {
        Err("tls: client certificate requested".into())
    } else {
        Ok(())
    }
}

/// `c ap traffic` / `s ap traffic` from CH … server Finished.
pub fn ap_traffic(master: &[u8; 32], ch_to_sf: &[u8]) -> Result<ApSecrets, String> {
    Ok(ApSecrets {
        master: *master,
        c_ap: derive_secret(master, "c ap traffic", ch_to_sf)?,
        s_ap: derive_secret(master, "s ap traffic", ch_to_sf)?,
    })
}

/// ECDHE then the CH/SH traffic secrets. Schoolbook X25519; not CT.
pub fn hs_from_x25519(
    sk: &[u8; 32],
    peer_pk: &[u8; 32],
    ch_sh: &[u8],
) -> Result<HsSecrets, String> {
    let ecdhe = x25519(sk, peer_pk);
    let hs = handshake_secret(&ecdhe)?;
    hs_traffic(&hs, ch_sh)
}

/// X25519 `key_share` entry: group 0x001d + 32-byte u-coordinate.
pub fn key_share_x25519(pk: &[u8; 32]) -> Vec<u8> {
    let mut v = Vec::with_capacity(6 + 32);
    v.extend_from_slice(&((4 + 32) as u16).to_be_bytes());
    v.extend_from_slice(&GROUP_X25519.to_be_bytes());
    v.extend_from_slice(&(32u16).to_be_bytes());
    v.extend_from_slice(pk);
    v
}

fn handshake_exts(hello: &[u8]) -> Result<(&[u8], u8), String> {
    if hello.len() < 6 {
        return Err("tls13: short hello".into());
    }
    let typ = hello[0];
    let mut i = 4;
    i += 2 + 32;
    if i >= hello.len() {
        return Err("tls13: short hello".into());
    }
    let sid = hello[i] as usize;
    i += 1 + sid;
    if typ == 1 {
        if i + 3 > hello.len() {
            return Err("tls13: short clienthello".into());
        }
        let cl = u16::from_be_bytes([hello[i], hello[i + 1]]) as usize;
        i += 2 + cl;
        let comp = hello[i] as usize;
        i += 1 + comp;
    } else if typ == 2 {
        i += 2 + 1;
    } else {
        return Err("tls13: not hello".into());
    }
    if i + 2 > hello.len() {
        return Err("tls13: no extensions".into());
    }
    let el = u16::from_be_bytes([hello[i], hello[i + 1]]) as usize;
    i += 2;
    if i + el > hello.len() {
        return Err("tls13: truncated extensions".into());
    }
    Ok((&hello[i..i + el], typ))
}

/// First X25519 share in a ServerHello/ClientHello key_share extension.
pub fn parse_x25519_share(hello: &[u8]) -> Result<[u8; 32], String> {
    let (exts, typ) = handshake_exts(hello)?;
    let mut i = 0;
    while i + 4 <= exts.len() {
        let id = u16::from_be_bytes([exts[i], exts[i + 1]]);
        let n = u16::from_be_bytes([exts[i + 2], exts[i + 3]]) as usize;
        i += 4;
        if i + n > exts.len() {
            break;
        }
        if id == 0x0033 {
            let data = &exts[i..i + n];
            if typ == 2 {
                if data.len() >= 36 {
                    let g = u16::from_be_bytes([data[0], data[1]]);
                    let kn = u16::from_be_bytes([data[2], data[3]]) as usize;
                    if g == GROUP_X25519 && kn == 32 && data.len() >= 4 + 32 {
                        return Ok(arr32(&data[4..36]));
                    }
                }
            } else if data.len() >= 2 {
                let mut j = 2;
                while j + 4 <= data.len() {
                    let g = u16::from_be_bytes([data[j], data[j + 1]]);
                    let kn = u16::from_be_bytes([data[j + 2], data[j + 3]]) as usize;
                    j += 4;
                    if g == GROUP_X25519 && kn == 32 && j + 32 <= data.len() {
                        return Ok(arr32(&data[j..j + 32]));
                    }
                    j += kn;
                }
            }
        }
        i += n;
    }
    Err("tls13: no x25519 key_share".into())
}

/// TLS 1.3 ClientHello (handshake message, no record). AES-128-GCM-SHA256 + X25519.
/// Also lists TLS 1.2 ECDHE-GCM and supported_versions 1.3 then 1.2 (fallback).
/// No PSK, no early_data.
pub fn client_hello_tls13(random: &[u8; 32], pk: &[u8; 32], host: &str) -> Vec<u8> {
    let mut body = Vec::new();
    body.extend_from_slice(&[0x03, 0x03]);
    body.extend_from_slice(random);
    body.push(0);
    body.extend_from_slice(&[0x00, 0x06, 0x13, 0x01, 0xc0, 0x2f, 0xc0, 0x2b]);
    body.extend_from_slice(&[0x01, 0x00]);
    let mut ext = Vec::new();
    push_server_name(&mut ext, host);
    push_ext(&mut ext, 0x000a, &[0x00, 0x06, 0x00, 0x1d, 0x00, 0x17]);
    push_ext(
        &mut ext,
        0x000d,
        &[0x00, 0x06, 0x08, 0x04, 0x04, 0x03, 0x04, 0x01],
    );
    push_ext(&mut ext, 0x0033, &key_share_x25519(pk));
    push_ext(&mut ext, 0x002b, &[0x04, 0x03, 0x04, 0x03, 0x03]);
    push_ext(&mut ext, 0x0010, &alpn_h2_then_http11());
    push_ext(&mut ext, 0xff01, &[0x00]);
    body.extend_from_slice(&(ext.len() as u16).to_be_bytes());
    body.extend(ext);
    let mut hs = vec![0x01];
    let bl = body.len();
    hs.push(((bl >> 16) & 0xff) as u8);
    hs.push(((bl >> 8) & 0xff) as u8);
    hs.push((bl & 0xff) as u8);
    hs.extend(body);
    hs
}

/// TLS 1.3 ClientHello with 1-RTT PSK-DHE (ticket + binder). No early_data.
pub fn client_hello_tls13_psk(
    random: &[u8; 32],
    pk: &[u8; 32],
    host: &str,
    ticket: &crate::session::Ticket,
) -> Result<Vec<u8>, String> {
    let mut body = Vec::new();
    body.extend_from_slice(&[0x03, 0x03]);
    body.extend_from_slice(random);
    body.push(0);
    body.extend_from_slice(&[0x00, 0x06, 0x13, 0x01, 0xc0, 0x2f, 0xc0, 0x2b]);
    body.extend_from_slice(&[0x01, 0x00]);
    let mut ext = Vec::new();
    push_server_name(&mut ext, host);
    push_ext(&mut ext, 0x000a, &[0x00, 0x06, 0x00, 0x1d, 0x00, 0x17]);
    push_ext(
        &mut ext,
        0x000d,
        &[0x00, 0x06, 0x08, 0x04, 0x04, 0x03, 0x04, 0x01],
    );
    push_ext(&mut ext, 0x0033, &key_share_x25519(pk));
    push_ext(&mut ext, 0x002b, &[0x04, 0x03, 0x04, 0x03, 0x03]);
    push_ext(&mut ext, 0x0010, &alpn_h2_then_http11());
    push_ext(&mut ext, 0xff01, &[0x00]);
    push_ext(&mut ext, 0x002d, &[0x01, 0x01]);
    let mut id = Vec::new();
    id.extend_from_slice(&(ticket.identity.len() as u16).to_be_bytes());
    id.extend_from_slice(&ticket.identity);
    id.extend_from_slice(&0u32.to_be_bytes());
    let mut identities = Vec::new();
    identities.extend_from_slice(&(id.len() as u16).to_be_bytes());
    identities.extend(id);
    let binders_hdr = [0x00, 0x21, 0x20];
    let psk_len = identities.len() + binders_hdr.len() + 32;
    ext.extend_from_slice(&0x0029u16.to_be_bytes());
    ext.extend_from_slice(&(psk_len as u16).to_be_bytes());
    ext.extend_from_slice(&identities);
    ext.extend_from_slice(&binders_hdr);
    ext.extend_from_slice(&[0u8; 32]);
    body.extend_from_slice(&(ext.len() as u16).to_be_bytes());
    body.extend(ext);
    let mut hs = vec![0x01];
    let bl = body.len();
    hs.push(((bl >> 16) & 0xff) as u8);
    hs.push(((bl >> 8) & 0xff) as u8);
    hs.push((bl & 0xff) as u8);
    hs.extend(body);
    let cut = hs.len() - 35;
    let binder = crate::session::psk_binder(&ticket.psk, &hs[..cut])?;
    hs[cut + 3..].copy_from_slice(&binder);
    Ok(hs)
}

/// RFC 6066 forbids an IP literal in server_name. A DNS name is still sent.
fn push_server_name(ext: &mut Vec<u8>, host: &str) {
    if host.parse::<std::net::IpAddr>().is_ok() {
        return;
    }
    let hb = host.as_bytes();
    let mut sni = vec![0x00];
    sni.extend_from_slice(&(hb.len() as u16).to_be_bytes());
    sni.extend_from_slice(hb);
    let mut sni_list = Vec::new();
    sni_list.extend_from_slice(&(sni.len() as u16).to_be_bytes());
    sni_list.extend(sni);
    push_ext(ext, 0x0000, &sni_list);
}

fn push_ext(ext: &mut Vec<u8>, id: u16, data: &[u8]) {
    ext.extend_from_slice(&id.to_be_bytes());
    ext.extend_from_slice(&(data.len() as u16).to_be_bytes());
    ext.extend_from_slice(data);
}

pub fn offers_tls13(hello: &[u8]) -> bool {
    hello.windows(2).any(|w| w == [0x13, 0x01])
        && hello.windows(2).any(|w| w == [0x03, 0x04])
        && hello.windows(2).any(|w| w == [0x00, 0x1d])
        && !hello.windows(2).any(|w| w == [0x00, 0x2a])
}

/// Wire version after ServerHello (legacy 1.2 record, 1.3 via supported_versions).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TlsVersion {
    Tls12,
    Tls13,
}

/// ServerHello selected version. 1.3 is `supported_versions` 0x0304.
pub fn negotiated_version(server_hello: &[u8]) -> Result<TlsVersion, String> {
    let hs = if server_hello.len() > 5 && server_hello[0] == 0x16 {
        &server_hello[5..]
    } else {
        server_hello
    };
    if hs.is_empty() || hs[0] != 2 {
        return Err("tls: not ServerHello".into());
    }
    let (exts, typ) = match handshake_exts(hs) {
        Ok(v) => v,
        Err(_) => return Ok(TlsVersion::Tls12),
    };
    if typ != 2 {
        return Err("tls: not ServerHello".into());
    }
    let mut i = 0;
    while i + 4 <= exts.len() {
        let id = u16::from_be_bytes([exts[i], exts[i + 1]]);
        let n = u16::from_be_bytes([exts[i + 2], exts[i + 3]]) as usize;
        i += 4;
        if i + n > exts.len() {
            break;
        }
        if id == 0x002b && n >= 2 && exts[i] == 0x03 && exts[i + 1] == 0x04 {
            return Ok(TlsVersion::Tls13);
        }
        i += n;
    }
    Ok(TlsVersion::Tls12)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hkdf::traffic_keys;

    fn hx(s: &str) -> Vec<u8> {
        (0..s.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
            .collect()
    }

    fn hx32(s: &str) -> [u8; 32] {
        let v = hx(s);
        arr32(&v)
    }

    fn botan_simple(key: &str) -> Vec<u8> {
        let text = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../kernel-spec/botan/test_data/tls_13_rfc8448/transcripts.vec"
        ));
        let start = text.find("[Simple_1RTT_Handshake]").expect("section");
        let rest = &text[start..];
        let end = rest[1..].find("\n[").map(|i| i + 1).unwrap_or(rest.len());
        let body = &rest[..end];
        for line in body.lines() {
            if let Some((k, v)) = line.split_once('=') {
                if k.trim() == key {
                    let hex: String = v.chars().filter(|c| c.is_ascii_hexdigit()).collect();
                    return hx(&hex);
                }
            }
        }
        panic!("missing {key}");
    }

    #[test]
    fn rfc8448_handshake_secret_from_ecdhe() {
        let ecdhe = hx32("8bd4054fb55b9d63fdfbacf9f04b9f0d35e6d63f537563efd46272900f89492d");
        let hs = handshake_secret(&ecdhe).unwrap();
        assert_eq!(
            hs,
            hx32("1dc826e93606aa6fdc0aadc12f741b01046aa6b99f691ed221a9f0ca043fbeac")
        );
        let ch = hx("010000c00303cb34ecb1e78163ba1c38c6dacb196a6dffa21a8d9912ec18a2ef6283024dece7000006130113031302010000910000000b0009000006736572766572ff01000100000a00140012001d0017001800190100010101020103010400230000003300260024001d002099381de560e4bd43d23d8e435a7dbafeb3c06e51c13cae4d5413691e529aaf2c002b0003020304000d0020001e040305030603020308040805080604010501060102010402050206020202002d00020101001c00024001");
        let sh = hx("020000560303a6af06a4121860dc5e6e60249cd34c95930c8ac5cb1434dac155772ed3e2692800130100002e00330024001d0020c9828876112095fe66762bdbf7c672e156d6cc253b833df1dd69b1b04e751f0f002b00020304");
        let mut msgs = ch.clone();
        msgs.extend_from_slice(&sh);
        let t = hs_traffic(&hs, &msgs).unwrap();
        assert_eq!(
            t.c_hs,
            hx32("b3eddb126e067f35a780b3abf45e2d8f3b1a950738f52e9600746a0e27a55a21")
        );
        assert_eq!(
            t.s_hs,
            hx32("b67b7d690cc16c4e75e54213cb2d37b4e9c912bcded9105d42befd59d391ad38")
        );
        let (key, iv) = traffic_keys(&t.s_hs).unwrap();
        assert_eq!(key, hx("3fce516009c21727d0f2e4e86ee403bc")[..]);
        assert_eq!(iv, hx("5d313eb2671276ee13000b30")[..]);
        let spk = parse_x25519_share(&sh).unwrap();
        assert_eq!(
            spk,
            hx32("c9828876112095fe66762bdbf7c672e156d6cc253b833df1dd69b1b04e751f0f")
        );
    }

    #[test]
    fn rfc8448_ecdhe_from_x25519() {
        let csk = hx32("49af42ba7f7994852d713ef2784bcbcaa7911de26adc5642cb634540e7ea5005");
        let spk = hx32("c9828876112095fe66762bdbf7c672e156d6cc253b833df1dd69b1b04e751f0f");
        let ecdhe = x25519(&csk, &spk);
        assert_eq!(
            ecdhe,
            hx32("8bd4054fb55b9d63fdfbacf9f04b9f0d35e6d63f537563efd46272900f89492d")
        );
    }

    #[test]
    fn client_hello_tls13_has_x25519_share_no_early_data() {
        let pk = hx32("99381de560e4bd43d23d8e435a7dbafeb3c06e51c13cae4d5413691e529aaf2c");
        let rnd = [0xcbu8; 32];
        let ch = client_hello_tls13(&rnd, &pk, "server");
        assert!(offers_tls13(&ch));
        assert_eq!(parse_x25519_share(&ch).unwrap(), pk);
        assert!(!ch.windows(2).any(|w| w == [0x00, 0x2a]), "no early_data");
        assert!(crate::hello::offers_tls12_fallback(&ch));
        assert!(ch.windows(2).any(|w| w == [0x03, 0x03]));
        assert!(ch.windows(8).any(|w| w == b"http/1.1"));
        assert!(ch.windows(2).any(|w| w == b"h2"));
        let h2_at = ch.windows(2).position(|w| w == b"h2").unwrap();
        let h11_at = ch.windows(8).position(|w| w == b"http/1.1").unwrap();
        assert!(h2_at < h11_at, "h2 preferred over http/1.1");
    }

    #[test]
    fn tls13_hello_omits_sni_for_an_ip_and_binds_the_psk() {
        let pk = [0x22u8; 32];
        let rnd = [0x11u8; 32];
        let named = client_hello_tls13(&rnd, &pk, "server");
        let ip = client_hello_tls13(&rnd, &pk, "127.0.0.1");
        let v6 = client_hello_tls13(&rnd, &pk, "::1");
        assert!(named.windows(6).any(|w| w == b"server"));
        assert!(!ip.windows(9).any(|w| w == b"127.0.0.1"));
        assert!(!v6.windows(3).any(|w| w == b"::1"));
        assert_eq!(ip, v6);
        assert_eq!(named.len(), ip.len() + 9 + "server".len());
        assert!(offers_tls13(&ip));
        assert_eq!(parse_x25519_share(&ip).unwrap(), pk);

        let t = crate::session::issue_ticket("127.0.0.1", &[7u8; 32], &[0, 0], b"ticket-1", &pk)
            .unwrap();
        let resumed = client_hello_tls13_psk(&rnd, &pk, "127.0.0.1", &t).unwrap();
        assert!(!resumed.windows(9).any(|w| w == b"127.0.0.1"));
        assert!(resumed.windows(2).any(|w| w == [0x00, 0x29]));
        assert!(!resumed.windows(2).any(|w| w == [0x00, 0x2a]));
        let binder = crate::session::psk_binder(&t.psk, &resumed[..resumed.len() - 35]).unwrap();
        assert_eq!(&resumed[resumed.len() - 32..], &binder);
        let named_psk = client_hello_tls13_psk(&rnd, &pk, "gsys.dev", &t).unwrap();
        assert!(named_psk.windows(8).any(|w| w == b"gsys.dev"));
        assert_eq!(named_psk.len(), resumed.len() + 9 + "gsys.dev".len());
    }

    #[test]
    fn alpn_h2_hrr_and_post_handshake_auth_refused() {
        let mut ee = vec![0x08, 0, 0, 0, 0, 0];
        let mut payload = Vec::new();
        let alpn = {
            let p = b"h2";
            let mut a = Vec::new();
            a.extend_from_slice(&((1 + p.len()) as u16).to_be_bytes());
            a.push(p.len() as u8);
            a.extend_from_slice(p);
            a
        };
        payload.extend_from_slice(&0x0010u16.to_be_bytes());
        payload.extend_from_slice(&(alpn.len() as u16).to_be_bytes());
        payload.extend_from_slice(&alpn);
        let n = 2 + payload.len();
        ee[1] = ((n >> 16) & 0xff) as u8;
        ee[2] = ((n >> 8) & 0xff) as u8;
        ee[3] = (n & 0xff) as u8;
        ee[4] = ((payload.len() >> 8) & 0xff) as u8;
        ee[5] = (payload.len() & 0xff) as u8;
        ee.extend(payload);
        parse_encrypted_extensions(&ee).unwrap();
        let mut ee3 = vec![0x08, 0, 0, 0, 0, 0];
        let mut p3 = Vec::new();
        let a3 = {
            let p = b"h3";
            let mut a = Vec::new();
            a.extend_from_slice(&((1 + p.len()) as u16).to_be_bytes());
            a.push(p.len() as u8);
            a.extend_from_slice(p);
            a
        };
        p3.extend_from_slice(&0x0010u16.to_be_bytes());
        p3.extend_from_slice(&(a3.len() as u16).to_be_bytes());
        p3.extend_from_slice(&a3);
        let n3 = 2 + p3.len();
        ee3[1] = ((n3 >> 16) & 0xff) as u8;
        ee3[2] = ((n3 >> 8) & 0xff) as u8;
        ee3[3] = (n3 & 0xff) as u8;
        ee3[4] = ((p3.len() >> 8) & 0xff) as u8;
        ee3[5] = (p3.len() & 0xff) as u8;
        ee3.extend(p3);
        assert!(parse_encrypted_extensions(&ee3).unwrap_err().contains("h3"));
        let pha = hx("08000006000400310000");
        assert!(parse_encrypted_extensions(&pha)
            .unwrap_err()
            .contains("post_handshake_auth"));
        let mut hrr = vec![2, 0, 0, 38, 0x03, 0x03];
        hrr.extend_from_slice(&HRR_RANDOM);
        assert!(refuse_hello_retry(&hrr)
            .unwrap_err()
            .contains("hello_retry_request"));
        let mut sh = vec![2, 0, 0, 38, 0x03, 0x03];
        sh.extend_from_slice(&[0x11u8; 32]);
        refuse_hello_retry(&sh).unwrap();
    }

    #[test]
    fn rfc8448_serverhello_negotiates_tls13() {
        let sh = hx("020000560303a6af06a4121860dc5e6e60249cd34c95930c8ac5cb1434dac155772ed3e2692800130100002e00330024001d0020c9828876112095fe66762bdbf7c672e156d6cc253b833df1dd69b1b04e751f0f002b00020304");
        assert_eq!(negotiated_version(&sh).unwrap(), TlsVersion::Tls13);
    }

    #[test]
    fn rfc8448_traffic_update_rotates_app_keys() {
        use crate::hkdf::traffic_keys;
        use crate::record::{open_record, seal_record};
        use crate::server::REC_APP;

        let s_ap = hx32("a11af9f05531f856ad47116b45a950328204b4f44bfb6b3a4b4f1f3fcb631643");
        let next = traffic_update(&s_ap).unwrap();
        assert_ne!(next, s_ap);
        let (k0, iv0) = traffic_keys(&s_ap).unwrap();
        let (k1, iv1) = traffic_keys(&next).unwrap();
        assert_ne!(k0, k1);
        let rec = seal_record(&k1, &iv1, 0, REC_APP, b"upd").unwrap();
        let (ty, body) = open_record(&k1, &iv1, 0, &rec).unwrap();
        assert_eq!(ty, REC_APP);
        assert_eq!(body, b"upd");
        assert!(open_record(&k0, &iv0, 0, &rec).is_err());
        assert!(parse_key_update(&key_update_msg(true)).unwrap());
        assert!(!parse_key_update(&key_update_msg(false)).unwrap());
        assert!(parse_key_update(&[0x18, 0, 0, 1, 2]).is_err());
    }

    #[test]
    fn rfc8448_exporter_master_and_ee_refuse_early_data() {
        let master = hx32("18df06843d13a08bf2a449844c5f8a478001bc4d4c627984d5a41da8d0402919");
        let ch = hx("010000c00303cb34ecb1e78163ba1c38c6dacb196a6dffa21a8d9912ec18a2ef6283024dece7000006130113031302010000910000000b0009000006736572766572ff01000100000a00140012001d0017001800190100010101020103010400230000003300260024001d002099381de560e4bd43d23d8e435a7dbafeb3c06e51c13cae4d5413691e529aaf2c002b0003020304000d0020001e040305030603020308040805080604010501060102010402050206020202002d00020101001c00024001");
        let sh = hx("020000560303a6af06a4121860dc5e6e60249cd34c95930c8ac5cb1434dac155772ed3e2692800130100002e00330024001d0020c9828876112095fe66762bdbf7c672e156d6cc253b833df1dd69b1b04e751f0f002b00020304");
        let mut ch_sh = ch;
        ch_sh.extend_from_slice(&sh);
        let exp = exporter_master(&master, &ch_sh).unwrap();
        assert_eq!(exp.len(), 32);
        assert_ne!(exp, master);
        let again = derive_secret(&master, "exp master", &ch_sh).unwrap();
        assert_eq!(exp, again);
        let ee =
            hx("080000240022000a00140012001d00170018001901000101010201030104001c0002400100000000");
        parse_encrypted_extensions(&ee).unwrap();
        let ee0 = hx("080000060004002a0000");
        assert!(parse_encrypted_extensions(&ee0)
            .unwrap_err()
            .contains("0-rtt"));
        let hb = hx("080000060004000f0000");
        assert!(parse_encrypted_extensions(&hb)
            .unwrap_err()
            .contains("heartbeat"));
        let sct = hx("08000006000400120000");
        assert!(parse_encrypted_extensions(&sct)
            .unwrap_err()
            .contains("signed_certificate_timestamp"));
        let cc = hx("080000060004001b0000");
        assert!(parse_encrypted_extensions(&cc)
            .unwrap_err()
            .contains("compress_certificate"));
        let ck = hx("080000060004002c0000");
        assert!(parse_encrypted_extensions(&ck)
            .unwrap_err()
            .contains("cookie"));
        let pskm = hx("080000060004002d0000");
        assert!(parse_encrypted_extensions(&pskm)
            .unwrap_err()
            .contains("psk_key_exchange_modes"));
        let ri = hx("080000060004ff010000");
        assert!(parse_encrypted_extensions(&ri)
            .unwrap_err()
            .contains("renegotiation_info"));
        let mf = hx("08000006000400010000");
        assert!(parse_encrypted_extensions(&mf)
            .unwrap_err()
            .contains("max_fragment_length"));
        assert!(refuse_certificate_request(&[0x0d, 0, 0, 0])
            .unwrap_err()
            .contains("client certificate"));
        refuse_certificate_request(&[0x0b, 0, 0, 0]).unwrap();
        let cert = hx("0b0000100000000c000001000006000500020000");
        assert!(crate::cert::ocsp_staple_from_tls13(&cert)
            .unwrap()
            .is_some());
    }

    #[test]
    fn rfc8448_simple_1rtt_encrypted_flight_finished_and_app() {
        use crate::record::open_record;
        use crate::server::REC_HANDSHAKE;
        use crate::transcript::{
            check_finished, finished_key, split_handshake, HandshakeTranscript,
        };
        use crate::verify::{
            parse_certificate_verify, verify_certificate_verify, SIG_RSA_PSS_SHA256,
        };

        let ch = hx("010000c00303cb34ecb1e78163ba1c38c6dacb196a6dffa21a8d9912ec18a2ef6283024dece7000006130113031302010000910000000b0009000006736572766572ff01000100000a00140012001d0017001800190100010101020103010400230000003300260024001d002099381de560e4bd43d23d8e435a7dbafeb3c06e51c13cae4d5413691e529aaf2c002b0003020304000d0020001e040305030603020308040805080604010501060102010402050206020202002d00020101001c00024001");
        let sh = hx("020000560303a6af06a4121860dc5e6e60249cd34c95930c8ac5cb1434dac155772ed3e2692800130100002e00330024001d0020c9828876112095fe66762bdbf7c672e156d6cc253b833df1dd69b1b04e751f0f002b00020304");
        let rec = botan_simple("Record_ServerHandshakeMessages");
        let hs = handshake_secret(&hx32(
            "8bd4054fb55b9d63fdfbacf9f04b9f0d35e6d63f537563efd46272900f89492d",
        ))
        .unwrap();
        let mut ch_sh = ch.clone();
        ch_sh.extend_from_slice(&sh);
        let t = hs_traffic(&hs, &ch_sh).unwrap();
        let (key, iv) = traffic_keys(&t.s_hs).unwrap();
        let mut k = [0u8; 16];
        let mut n = [0u8; 12];
        k.copy_from_slice(&key);
        n.copy_from_slice(&iv);
        let (ty, body) = open_record(&k, &n, 0, &rec).unwrap();
        assert_eq!(ty, REC_HANDSHAKE);
        let msgs = split_handshake(&body).unwrap();
        assert_eq!(msgs.len(), 4);
        assert_eq!(msgs[0][0], 0x08);
        assert_eq!(msgs[1][0], 0x0b);
        assert_eq!(msgs[2][0], 0x0f);
        assert_eq!(msgs[3][0], 0x14);
        let der = crate::cert::leaf_from_tls13_certificate(msgs[1]).unwrap();
        let pubk = crate::cert::rsa_pub(&der).unwrap();
        let mut pre_cv = HandshakeTranscript::new();
        pre_cv.push(&ch).unwrap();
        pre_cv.push(&sh).unwrap();
        pre_cv.push(msgs[0]).unwrap();
        pre_cv.push(msgs[1]).unwrap();
        let (sch, sig) = parse_certificate_verify(msgs[2]).unwrap();
        assert_eq!(sch, SIG_RSA_PSS_SHA256);
        assert!(verify_certificate_verify(
            &pubk,
            sch,
            true,
            pre_cv.bytes(),
            &sig
        ));
        let mut all = pre_cv;
        all.push(msgs[2]).unwrap();
        let fk = finished_key(&t.s_hs).unwrap();
        check_finished(&fk, &all.hash(), &msgs[3][4..]).unwrap();
        all.push(msgs[3]).unwrap();
        let master = master_secret(&hs).unwrap();
        assert_eq!(
            master,
            hx32("18df06843d13a08bf2a449844c5f8a478001bc4d4c627984d5a41da8d0402919")
        );
        let ap = ap_traffic(&master, all.bytes()).unwrap();
        assert_eq!(
            ap.c_ap,
            hx32("9e40646ce79a7f9dc05af8889bce6552875afa0b06df0087f792ebb7c17504a5")
        );
        assert_eq!(
            ap.s_ap,
            hx32("a11af9f05531f856ad47116b45a950328204b4f44bfb6b3a4b4f1f3fcb631643")
        );
        let (ck, civ) = traffic_keys(&ap.c_ap).unwrap();
        assert_eq!(ck, hx("17422dda596ed5d9acd890e3c63f5051")[..]);
        assert_eq!(civ, hx("5b78923dee08579033e523d9")[..]);
        let (sk, siv) = traffic_keys(&ap.s_ap).unwrap();
        assert_eq!(sk, hx("9f02283b6c9c07efc26bb9f2ac92e356")[..]);
        assert_eq!(siv, hx("cf782b88dd83549aadf1e984")[..]);
        let mut ck16 = [0u8; 16];
        let mut civ12 = [0u8; 12];
        let mut sk16 = [0u8; 16];
        let mut siv12 = [0u8; 12];
        ck16.copy_from_slice(&ck);
        civ12.copy_from_slice(&civ);
        sk16.copy_from_slice(&sk);
        siv12.copy_from_slice(&siv);
        let pt: Vec<u8> = (0u8..=0x31).collect();
        let crec = botan_simple("Record_Client_AppData");
        let (cty, cbody) = open_record(&ck16, &civ12, 0, &crec).unwrap();
        assert_eq!(cty, crate::server::REC_APP);
        assert_eq!(cbody, pt);
        let nst_rec = botan_simple("Record_NewSessionTicket");
        let (nty, nbody) = open_record(&sk16, &siv12, 0, &nst_rec).unwrap();
        assert_eq!(nty, REC_HANDSHAKE);
        let (nonce, identity) = crate::session::parse_new_session_ticket(&nbody).unwrap();
        assert_eq!(nonce, hx("0000"));
        assert!(!identity.is_empty());
        let srec = botan_simple("Record_Server_AppData");
        let (sty, sbody) = open_record(&sk16, &siv12, 1, &srec).unwrap();
        assert_eq!(sty, crate::server::REC_APP);
        assert_eq!(sbody, pt);
    }

    #[test]
    fn rfc8448_simple_1rtt_client_finished_res_master_and_close() {
        use crate::record::{decode_alert, open_record, REC_ALERT};
        use crate::server::REC_HANDSHAKE;
        use crate::session::{res_master, resumption_psk, SessionCache};
        use crate::transcript::{
            check_finished, finished_key, parse_finished, split_handshake, HandshakeTranscript,
        };

        let ch = hx("010000c00303cb34ecb1e78163ba1c38c6dacb196a6dffa21a8d9912ec18a2ef6283024dece7000006130113031302010000910000000b0009000006736572766572ff01000100000a00140012001d0017001800190100010101020103010400230000003300260024001d002099381de560e4bd43d23d8e435a7dbafeb3c06e51c13cae4d5413691e529aaf2c002b0003020304000d0020001e040305030603020308040805080604010501060102010402050206020202002d00020101001c00024001");
        let sh = hx("020000560303a6af06a4121860dc5e6e60249cd34c95930c8ac5cb1434dac155772ed3e2692800130100002e00330024001d0020c9828876112095fe66762bdbf7c672e156d6cc253b833df1dd69b1b04e751f0f002b00020304");
        let hs = handshake_secret(&hx32(
            "8bd4054fb55b9d63fdfbacf9f04b9f0d35e6d63f537563efd46272900f89492d",
        ))
        .unwrap();
        let mut ch_sh = ch.clone();
        ch_sh.extend_from_slice(&sh);
        let t = hs_traffic(&hs, &ch_sh).unwrap();
        let (sk, siv) = traffic_keys(&t.s_hs).unwrap();
        let (ty, body) = open_record(
            &sk,
            &siv,
            0,
            &botan_simple("Record_ServerHandshakeMessages"),
        )
        .unwrap();
        assert_eq!(ty, REC_HANDSHAKE);
        let msgs = split_handshake(&body).unwrap();
        let mut tr = HandshakeTranscript::new();
        tr.push(&ch).unwrap();
        tr.push(&sh).unwrap();
        for m in &msgs {
            tr.push(m).unwrap();
        }
        let master = master_secret(&hs).unwrap();
        let ap = ap_traffic(&master, tr.bytes()).unwrap();
        let (ck, civ) = traffic_keys(&t.c_hs).unwrap();
        assert_eq!(ck, hx("dbfaa693d1762c5b666af5d950258d01")[..]);
        assert_eq!(civ, hx("5bd3c71b836e0b76bb73265f")[..]);
        let (fty, fbody) =
            open_record(&ck, &civ, 0, &botan_simple("Record_ClientFinished")).unwrap();
        assert_eq!(fty, REC_HANDSHAKE);
        let cf = parse_finished(&fbody).unwrap();
        let cfk = finished_key(&t.c_hs).unwrap();
        assert_eq!(
            cfk,
            hx32("b80ad01015fb2f0bd65ff7d4da5d6bf83f84821d1f87fdc7d3c75b5a7b42d9c4")
        );
        check_finished(&cfk, &tr.hash(), &cf).unwrap();
        tr.push(&fbody).unwrap();
        let rm = res_master(&master, tr.bytes()).unwrap();
        assert_eq!(
            rm,
            hx32("7df235f2031d2a051287d02b0241b0bfdaf86cc856231f2d5aba46c434ec196c")
        );
        let (apk, apiv) = traffic_keys(&ap.s_ap).unwrap();
        let (nty, nbody) =
            open_record(&apk, &apiv, 0, &botan_simple("Record_NewSessionTicket")).unwrap();
        assert_eq!(nty, REC_HANDSHAKE);
        let mut cache = SessionCache::default();
        let pk = parse_x25519_share(&ch).unwrap();
        cache.install_nst("server", &nbody, &rm, &pk).unwrap();
        let ticket = cache.lookup("server").unwrap();
        assert_eq!(ticket.nonce, hx("0000"));
        assert_eq!(
            ticket.psk,
            hx32("4ecd0eb6ec3b4d87f5d6028f922ca4c5851a277fd41311c9e62d2c9492e1c4f3")
        );
        assert_eq!(ticket.psk, resumption_psk(&rm, &ticket.nonce).unwrap());
        let (cak, caiv) = traffic_keys(&ap.c_ap).unwrap();
        let (aty, abody) =
            open_record(&cak, &caiv, 1, &botan_simple("Record_Client_CloseNotify")).unwrap();
        assert_eq!(aty, REC_ALERT);
        assert_eq!(decode_alert(&abody).unwrap(), (1, 0));
        let (sty, sbody) =
            open_record(&apk, &apiv, 2, &botan_simple("Record_Server_CloseNotify")).unwrap();
        assert_eq!(sty, REC_ALERT);
        assert_eq!(decode_alert(&sbody).unwrap(), (1, 0));
    }
}
