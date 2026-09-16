// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Completed TLS 1.2 ECDHE-GCM and TLS 1.3 1-RTT handshake drivers.
//! TLS 1.2 SKE is PKCS#1 SHA-256 over client_random||server_random||params.
//! TLS 1.3 Certificate + CertificateVerify are the RFC 8448 RSA-PSS leaf
//! (CN=rsa, self-signed, CA:FALSE). X25519 is schoolbook, not CT.
//! Not a browser, not CSPRNG quality, not live OpenWrt, not a CA path.

#![allow(missing_docs)]

use crate::cert::{leaf_from_tls13_certificate, rsa_pub};
use crate::entropy::Entropy;
use crate::hello::client_hello_with;
use crate::hkdf::traffic_keys;
use crate::hmac::tls12_prf_sha256;
use crate::record::{open_record, seal_record};
use crate::rsa::{rsa_pkcs1_sha256_sign, rsa_pss_sha256_sign};
use crate::server::{REC_APP, REC_HANDSHAKE};
use crate::session::{
    issue_ticket, new_session_ticket, parse_new_session_ticket, res_master, Ticket,
};
use crate::sha::sha256;
use crate::tls12::{
    change_cipher_spec, open_record_tls12, parse_ccs, parse_client_key_exchange,
    parse_server_hello_done, parse_server_key_exchange, parse_tls12_certificate, seal_record_tls12,
    tls12_finished, tls12_finished_msg, verify_server_key_exchange,
};
use crate::tls13::{
    ap_traffic, client_hello_tls13, hs_from_x25519, master_secret, parse_encrypted_extensions,
    parse_x25519_share, refuse_certificate_request,
};
use crate::transcript::{
    check_finished, finished_key, finished_mac, parse_finished, split_handshake,
};
use crate::verify::{
    parse_certificate_verify, signed_content, verify_certificate_verify, SIG_RSA_PSS_SHA256,
};
use crate::x25519::{x25519, x25519_public};

/// RFC 8448 simple 1-RTT RSA modulus / private exponent (1024-bit).
const RFC8448_N: &str = "b4bb498f8279303d980836399b36c6988c0c68de55e1bdb826d3901a2461eafd2de49a91d015abbc9a95137ace6c1af19eaa6af98c7ced43120998e187a80ee0ccb0524b1b018c3e0b63264d449a6d38e22a5fda430846748030530ef0461c8ca9d9efbfae8ea6d1d03e2bd193eff0ab9a8002c47428a6d35a8d88d79f7f1e3f";
const RFC8448_D: &str = "04dea705d43a6ea7209dd8072111a83c81e322a59278b33480641eaf7c0a6985b8e31c44f6de62e1b4c2309f6126e77b7c41e923314bbfa3881305dc1217f16c819ce538e922f369828d0e57195d8c8488460207b2faa726bcf708bbd7db7f679f893492fc2a622e08970aac441ce4e0c3088df25ae679233df8a3bda2ff9941";
const RFC8448_CERT: &str = "0b0001b9000001b50001b0308201ac30820115a003020102020102300d06092a864886f70d01010b0500300e310c300a06035504031303727361301e170d3136303733303031323335395a170d3236303733303031323335395a300e310c300a0603550403130372736130819f300d06092a864886f70d010101050003818d0030818902818100b4bb498f8279303d980836399b36c6988c0c68de55e1bdb826d3901a2461eafd2de49a91d015abbc9a95137ace6c1af19eaa6af98c7ced43120998e187a80ee0ccb0524b1b018c3e0b63264d449a6d38e22a5fda430846748030530ef0461c8ca9d9efbfae8ea6d1d03e2bd193eff0ab9a8002c47428a6d35a8d88d79f7f1e3f0203010001a31a301830090603551d1304023000300b0603551d0f0404030205a0300d06092a864886f70d01010b05000381810085aad2a0e5b9276b908c65f73a7267170618a54c5f8a7b337d2df7a594365417f2eae8f8a58c8f8172f9319cf36b7fd6c55b80f21a03015156726096fd335e5e67f2dbf102702e608ccae6bec1fc63a42a99be5c3eb7107c3c54e9b9eb2bd5203b1c3b84e0a8b2f759409ba3eac9d91d402dcc0cc8f8961229ac9187b42b4de10000";

/// AES-128-GCM keys after a TLS 1.2 ECDHE handshake.
#[derive(Clone, Debug)]
pub struct Traffic12 {
    pub client_key: [u8; 16],
    pub server_key: [u8; 16],
    pub client_salt: [u8; 4],
    pub server_salt: [u8; 4],
    pub master: Vec<u8>,
}

/// Application traffic after a TLS 1.3 1-RTT handshake, plus a 1-RTT ticket.
#[derive(Clone, Debug)]
pub struct Traffic13 {
    pub client_key: [u8; 16],
    pub client_iv: [u8; 12],
    pub server_key: [u8; 16],
    pub server_iv: [u8; 12],
    pub ticket: Ticket,
}

fn hx(s: &str) -> Result<Vec<u8>, String> {
    if s.len() % 2 != 0 {
        return Err("tls: hex".into());
    }
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).map_err(|_| "tls: hex".into()))
        .collect()
}

fn rfc8448_n() -> Result<Vec<u8>, String> {
    hx(RFC8448_N)
}

fn rfc8448_d() -> Result<Vec<u8>, String> {
    hx(RFC8448_D)
}

fn rfc8448_cert_hs() -> Result<Vec<u8>, String> {
    hx(RFC8448_CERT)
}

fn inner_hs(rec: &[u8]) -> Result<&[u8], String> {
    if rec.len() >= 5 && rec[0] == REC_HANDSHAKE {
        let n = u16::from_be_bytes([rec[3], rec[4]]) as usize;
        if rec.len() < 5 + n {
            return Err("tls: truncated".into());
        }
        Ok(&rec[5..5 + n])
    } else {
        Ok(rec)
    }
}

fn hello_random(hs: &[u8]) -> Result<[u8; 32], String> {
    if hs.len() < 4 + 2 + 32 || (hs[0] != 1 && hs[0] != 2) {
        return Err("tls: hello random".into());
    }
    let mut r = [0u8; 32];
    r.copy_from_slice(&hs[6..38]);
    Ok(r)
}

fn handshake_hdr(typ: u8, body: &[u8]) -> Vec<u8> {
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

fn tls12_master(premaster: &[u8], cr: &[u8; 32], sr: &[u8; 32]) -> Result<Vec<u8>, String> {
    let mut seed = Vec::with_capacity(64);
    seed.extend_from_slice(cr);
    seed.extend_from_slice(sr);
    tls12_prf_sha256(premaster, b"master secret", &seed, 48)
}

fn tls12_keys(master: &[u8], cr: &[u8; 32], sr: &[u8; 32]) -> Result<Traffic12, String> {
    let mut seed = Vec::with_capacity(64);
    seed.extend_from_slice(sr);
    seed.extend_from_slice(cr);
    let kb = tls12_prf_sha256(master, b"key expansion", &seed, 40)?;
    let mut ck = [0u8; 16];
    let mut sk = [0u8; 16];
    let mut civ = [0u8; 4];
    let mut siv = [0u8; 4];
    ck.copy_from_slice(&kb[0..16]);
    sk.copy_from_slice(&kb[16..32]);
    civ.copy_from_slice(&kb[32..36]);
    siv.copy_from_slice(&kb[36..40]);
    Ok(Traffic12 {
        client_key: ck,
        server_key: sk,
        client_salt: civ,
        server_salt: siv,
        master: master.to_vec(),
    })
}

fn tls12_certificate(der: &[u8]) -> Vec<u8> {
    let mut list = Vec::new();
    list.extend_from_slice(&(der.len() as u32).to_be_bytes()[1..]);
    list.extend_from_slice(der);
    let mut body = Vec::new();
    body.extend_from_slice(&(list.len() as u32).to_be_bytes()[1..]);
    body.extend(list);
    handshake_hdr(11, &body)
}

fn ske_x25519_signed(
    pk: &[u8; 32],
    cr: &[u8; 32],
    sr: &[u8; 32],
    n: &[u8],
    d: &[u8],
) -> Result<Vec<u8>, String> {
    let mut params = vec![3, 0x00, 0x1d, 32];
    params.extend_from_slice(pk);
    let mut to_sign = Vec::with_capacity(64 + params.len());
    to_sign.extend_from_slice(cr);
    to_sign.extend_from_slice(sr);
    to_sign.extend_from_slice(&params);
    let sig = rsa_pkcs1_sha256_sign(n, d, &to_sign)?;
    let mut body = params;
    body.extend_from_slice(&[0x04, 0x01]);
    body.extend_from_slice(&(sig.len() as u16).to_be_bytes());
    body.extend_from_slice(&sig);
    Ok(handshake_hdr(12, &body))
}

fn cke_x25519(pk: &[u8; 32]) -> Vec<u8> {
    let mut body = vec![32];
    body.extend_from_slice(pk);
    handshake_hdr(16, &body)
}

/// TLS 1.2 ECDHE-GCM: both peers derive the same keys, Finished, and app GCM.
/// SKE is PKCS#1 SHA-256 with the RFC 8448 RSA leaf (not a CA path).
pub fn complete_tls12_ecdhe_gcm(
    client_sk: &[u8; 32],
    server_sk: &[u8; 32],
    host: &str,
    crng: &mut dyn Entropy,
    srng: &mut dyn Entropy,
) -> Result<(Traffic12, Vec<u8>, Vec<u8>), String> {
    let ch_rec = client_hello_with(host, crng)?;
    let ch = inner_hs(&ch_rec)?;
    let cr = hello_random(ch)?;
    let cpk = x25519_public(client_sk);
    let spk = x25519_public(server_sk);
    let mut srnd = [0u8; 32];
    srng.fill(&mut srnd)?;
    let mut sh_body = Vec::new();
    sh_body.extend_from_slice(&[0x03, 0x03]);
    sh_body.extend_from_slice(&srnd);
    sh_body.push(0);
    sh_body.extend_from_slice(&0xc02fu16.to_be_bytes());
    sh_body.push(0);
    let sh = handshake_hdr(2, &sh_body);
    let der = leaf_from_tls13_certificate(&rfc8448_cert_hs()?)?;
    let cert = tls12_certificate(&der);
    let got = parse_tls12_certificate(&cert)?;
    if got != der {
        return Err("tls12: cert".into());
    }
    let pubk = rsa_pub(&der)?;
    let n = rfc8448_n()?;
    let d = rfc8448_d()?;
    let ske = ske_x25519_signed(&spk, &cr, &srnd, &n, &d)?;
    parse_server_key_exchange(&ske)?;
    verify_server_key_exchange(&pubk, &cr, &srnd, &ske)?;
    let shd = handshake_hdr(14, &[]);
    parse_server_hello_done(&shd)?;
    let mut tx = Vec::new();
    tx.extend_from_slice(ch);
    tx.extend_from_slice(&sh);
    tx.extend_from_slice(&cert);
    tx.extend_from_slice(&ske);
    tx.extend_from_slice(&shd);
    let cke = cke_x25519(&cpk);
    parse_client_key_exchange(&cke)?;
    tx.extend_from_slice(&cke);
    let premaster_c = x25519(client_sk, &spk);
    let premaster_s = x25519(server_sk, &cpk);
    if premaster_c != premaster_s {
        return Err("tls12: ecdhe mismatch".into());
    }
    let master = tls12_master(&premaster_c, &cr, &srnd)?;
    let keys = tls12_keys(&master, &cr, &srnd)?;
    let cfin = tls12_finished(&master, b"client finished", &tx)?;
    let cfin_msg = tls12_finished_msg(&cfin);
    tx.extend_from_slice(&cfin_msg);
    let sfin = tls12_finished(&master, b"server finished", &tx)?;
    let sfin_msg = tls12_finished_msg(&sfin);
    parse_ccs(&change_cipher_spec())?;
    let rec_c = seal_record_tls12(
        &keys.client_key,
        &keys.client_salt,
        0,
        REC_HANDSHAKE,
        &cfin_msg,
    )?;
    let rec_s = seal_record_tls12(
        &keys.server_key,
        &keys.server_salt,
        0,
        REC_HANDSHAKE,
        &sfin_msg,
    )?;
    let got_c = open_record_tls12(&keys.client_key, &keys.client_salt, 0, &rec_c)?;
    let got_s = open_record_tls12(&keys.server_key, &keys.server_salt, 0, &rec_s)?;
    if got_c != cfin_msg || got_s != sfin_msg {
        return Err("tls12: finished record".into());
    }
    let ping = seal_record_tls12(&keys.client_key, &keys.client_salt, 1, REC_APP, b"ping")?;
    let pong = seal_record_tls12(&keys.server_key, &keys.server_salt, 1, REC_APP, b"pong")?;
    if open_record_tls12(&keys.client_key, &keys.client_salt, 1, &ping)? != b"ping" {
        return Err("tls12: app".into());
    }
    if open_record_tls12(&keys.server_key, &keys.server_salt, 1, &pong)? != b"pong" {
        return Err("tls12: app".into());
    }
    Ok((keys, ping, pong))
}

fn empty_ee() -> Vec<u8> {
    handshake_hdr(8, &[0, 0])
}

fn tls13_finished_msg(verify: &[u8; 32]) -> Vec<u8> {
    handshake_hdr(0x14, verify)
}

fn tls13_certificate_verify(n: &[u8], d: &[u8], transcript: &[u8]) -> Result<Vec<u8>, String> {
    let th = sha256(transcript);
    let content = signed_content(true, &th);
    let salt = [0x5au8; 32];
    let sig = rsa_pss_sha256_sign(n, d, &content, &salt)?;
    let mut m = vec![0x0f, 0, 0, 0, 0x08, 0x04];
    m.extend_from_slice(&(sig.len() as u16).to_be_bytes());
    m.extend_from_slice(&sig);
    let nbody = m.len() - 4;
    m[1] = ((nbody >> 16) & 0xff) as u8;
    m[2] = ((nbody >> 8) & 0xff) as u8;
    m[3] = (nbody & 0xff) as u8;
    Ok(m)
}

/// TLS 1.3 1-RTT: CH, SH, dummy CCS, EE, Certificate, CertificateVerify,
/// both Finished, NewSessionTicket, application traffic.
/// CertificateVerify is RSA-PSS SHA-256 over the RFC 8448 leaf (not a CA).
pub fn complete_tls13_1rtt(
    client_sk: &[u8; 32],
    server_sk: &[u8; 32],
    host: &str,
) -> Result<Traffic13, String> {
    let cpk = x25519_public(client_sk);
    let spk = x25519_public(server_sk);
    let cr = [0x11u8; 32];
    let sr = [0x22u8; 32];
    let ch = client_hello_tls13(&cr, &cpk, host);
    let mut sh_body = Vec::new();
    sh_body.extend_from_slice(&[0x03, 0x03]);
    sh_body.extend_from_slice(&sr);
    sh_body.push(0);
    sh_body.extend_from_slice(&[0x13, 0x01]);
    sh_body.push(0);
    let mut ext = Vec::new();
    let mut ks = Vec::new();
    ks.extend_from_slice(&0x001du16.to_be_bytes());
    ks.extend_from_slice(&32u16.to_be_bytes());
    ks.extend_from_slice(&spk);
    ext.extend_from_slice(&0x0033u16.to_be_bytes());
    ext.extend_from_slice(&(ks.len() as u16).to_be_bytes());
    ext.extend_from_slice(&ks);
    ext.extend_from_slice(&0x002bu16.to_be_bytes());
    ext.extend_from_slice(&2u16.to_be_bytes());
    ext.extend_from_slice(&[0x03, 0x04]);
    sh_body.extend_from_slice(&(ext.len() as u16).to_be_bytes());
    sh_body.extend(ext);
    let sh = handshake_hdr(2, &sh_body);
    parse_x25519_share(&sh)?;
    parse_ccs(&change_cipher_spec())?;
    let hs = hs_from_x25519(client_sk, &spk, &{
        let mut t = ch.clone();
        t.extend_from_slice(&sh);
        t
    })?;
    let ee = empty_ee();
    parse_encrypted_extensions(&ee)?;
    refuse_certificate_request(&ee)?;
    let cert = rfc8448_cert_hs()?;
    let der = leaf_from_tls13_certificate(&cert)?;
    let pubk = rsa_pub(&der)?;
    let n = rfc8448_n()?;
    let d = rfc8448_d()?;
    let mut tx_cv = ch.clone();
    tx_cv.extend_from_slice(&sh);
    tx_cv.extend_from_slice(&ee);
    tx_cv.extend_from_slice(&cert);
    let cv = tls13_certificate_verify(&n, &d, &tx_cv)?;
    let (sch, sig) = parse_certificate_verify(&cv)?;
    if sch != SIG_RSA_PSS_SHA256 {
        return Err("tls13: cv scheme".into());
    }
    if !verify_certificate_verify(&pubk, sch, true, &tx_cv, &sig) {
        return Err("tls13: certificate_verify".into());
    }
    let fk_c = finished_key(&hs.c_hs)?;
    let fk_s = finished_key(&hs.s_hs)?;
    let mut tx = tx_cv.clone();
    tx.extend_from_slice(&cv);
    let th_s = sha256(&tx);
    let sfin = finished_mac(&fk_s, &th_s);
    let sfin_msg = tls13_finished_msg(&sfin);
    let mut flight = Vec::new();
    flight.extend_from_slice(&ee);
    flight.extend_from_slice(&cert);
    flight.extend_from_slice(&cv);
    flight.extend_from_slice(&sfin_msg);
    let (s_hs_key, s_hs_iv) = traffic_keys(&hs.s_hs)?;
    let rec_sf = seal_record(&s_hs_key, &s_hs_iv, 0, REC_HANDSHAKE, &flight)?;
    let (ty_s, opened) = open_record(&s_hs_key, &s_hs_iv, 0, &rec_sf)?;
    if ty_s != REC_HANDSHAKE {
        return Err("tls13: finished type".into());
    }
    let parts = split_handshake(&opened)?;
    if parts.len() != 4 {
        return Err("tls13: server flight".into());
    }
    parse_encrypted_extensions(parts[0])?;
    leaf_from_tls13_certificate(parts[1])?;
    parse_certificate_verify(parts[2])?;
    check_finished(&fk_s, &th_s, &parse_finished(parts[3])?)?;
    tx.extend_from_slice(&sfin_msg);
    let th_c = sha256(&tx);
    let cfin = finished_mac(&fk_c, &th_c);
    let cfin_msg = tls13_finished_msg(&cfin);
    tx.extend_from_slice(&cfin_msg);
    let (c_hs_key, c_hs_iv) = traffic_keys(&hs.c_hs)?;
    let rec_cf = seal_record(&c_hs_key, &c_hs_iv, 0, REC_HANDSHAKE, &cfin_msg)?;
    let (ty_c, opened_c) = open_record(&c_hs_key, &c_hs_iv, 0, &rec_cf)?;
    if ty_c != REC_HANDSHAKE {
        return Err("tls13: finished type".into());
    }
    check_finished(&fk_c, &th_c, &parse_finished(&opened_c)?)?;
    let master = master_secret(&hs.handshake)?;
    let mut ch_to_sf = ch.clone();
    ch_to_sf.extend_from_slice(&sh);
    ch_to_sf.extend_from_slice(&ee);
    ch_to_sf.extend_from_slice(&cert);
    ch_to_sf.extend_from_slice(&cv);
    ch_to_sf.extend_from_slice(&sfin_msg);
    let ap = ap_traffic(&master, &ch_to_sf)?;
    let (ck, civ) = traffic_keys(&ap.c_ap)?;
    let (sk, siv) = traffic_keys(&ap.s_ap)?;
    let rm = res_master(&master, &tx)?;
    let nst = new_session_ticket(86400, 0, &[0x00, 0x00], b"g6b-ticket");
    parse_new_session_ticket(&nst)?;
    let rec_nst = seal_record(&sk, &siv, 0, REC_HANDSHAKE, &nst)?;
    let (ty_n, opened_n) = open_record(&sk, &siv, 0, &rec_nst)?;
    if ty_n != REC_HANDSHAKE {
        return Err("tls13: nst type".into());
    }
    parse_new_session_ticket(&opened_n)?;
    let ticket = issue_ticket(host, &rm, &[0x00, 0x00], b"g6b-ticket", &spk)?;
    let ping = seal_record(&ck, &civ, 0, REC_APP, b"ping")?;
    let (t1, b1) = open_record(&ck, &civ, 0, &ping)?;
    if t1 != REC_APP || b1 != b"ping" {
        return Err("tls13: app".into());
    }
    let pong = seal_record(&sk, &siv, 1, REC_APP, b"pong")?;
    let (t2, b2) = open_record(&sk, &siv, 1, &pong)?;
    if t2 != REC_APP || b2 != b"pong" {
        return Err("tls13: app".into());
    }
    Ok(Traffic13 {
        client_key: ck,
        client_iv: civ,
        server_key: sk,
        server_iv: siv,
        ticket,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::entropy::FixtureEntropy;

    #[test]
    fn tls12_completed_ecdhe_gcm_appdata() {
        let csk = [0x11u8; 32];
        let ssk = [0x22u8; 32];
        let mut crng = FixtureEntropy::TEST;
        let mut srng = FixtureEntropy::TEST;
        let (keys, ping, pong) =
            complete_tls12_ecdhe_gcm(&csk, &ssk, "server.example", &mut crng, &mut srng).unwrap();
        assert_eq!(keys.master.len(), 48);
        assert_ne!(keys.client_key, keys.server_key);
        assert_eq!(
            open_record_tls12(&keys.client_key, &keys.client_salt, 1, &ping).unwrap(),
            b"ping"
        );
        assert_eq!(
            open_record_tls12(&keys.server_key, &keys.server_salt, 1, &pong).unwrap(),
            b"pong"
        );
    }

    #[test]
    fn tls13_completed_1rtt_appdata() {
        let csk = [0x33u8; 32];
        let ssk = [0x44u8; 32];
        let t = complete_tls13_1rtt(&csk, &ssk, "server").unwrap();
        assert!(!t.ticket.identity.is_empty());
        assert_ne!(t.ticket.psk, [0u8; 32]);
        let rec = seal_record(&t.client_key, &t.client_iv, 1, REC_APP, b"ok").unwrap();
        assert_eq!(
            open_record(&t.client_key, &t.client_iv, 1, &rec).unwrap().1,
            b"ok"
        );
        let rec2 = seal_record(&t.server_key, &t.server_iv, 2, REC_APP, b"ok").unwrap();
        assert_eq!(
            open_record(&t.server_key, &t.server_iv, 2, &rec2)
                .unwrap()
                .1,
            b"ok"
        );
    }
}
