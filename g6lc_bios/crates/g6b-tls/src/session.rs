// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! TLS 1.3 1-RTT PSK-DHE session tickets. No 0-RTT. Local and remote
//! clients reuse a ticket so the certificate flight is not repeated.

#![allow(missing_docs)]

use std::collections::BTreeMap;

use crate::hkdf::{derive_secret, expand_label, extract};
use crate::hmac::hmac_sha256;
use crate::sha::sha256;
use crate::transcript::finished_key;

const HASH_LEN: usize = 32;

/// Resumption PSK bound to a host. Identity is the ticket blob.
#[derive(Clone, Debug)]
pub struct Ticket {
    pub host: String,
    pub identity: Vec<u8>,
    pub nonce: Vec<u8>,
    pub psk: [u8; HASH_LEN],
    pub pk: [u8; 32],
}

/// Per-host ticket cache. One live ticket per SNI/host.
#[derive(Clone, Debug, Default)]
pub struct SessionCache {
    by_host: BTreeMap<String, Ticket>,
}

impl SessionCache {
    pub fn store(&mut self, t: Ticket) {
        self.by_host.insert(t.host.clone(), t);
    }

    pub fn lookup(&self, host: &str) -> Option<&Ticket> {
        self.by_host.get(host)
    }

    pub fn forget(&mut self, host: &str) {
        self.by_host.remove(host);
    }

    pub fn len(&self) -> usize {
        self.by_host.len()
    }

    pub fn is_empty(&self) -> bool {
        self.by_host.is_empty()
    }
}

/// HKDF-Extract(0, PSK).
pub fn early_secret_psk(psk: &[u8; 32]) -> [u8; HASH_LEN] {
    extract(&[0u8; HASH_LEN], psk)
}

/// `HKDF-Expand-Label(res_master, "resumption", ticket_nonce, Hash.length)`.
pub fn resumption_psk(res_master: &[u8; 32], nonce: &[u8]) -> Result<[u8; HASH_LEN], String> {
    let v = expand_label(res_master, "resumption", nonce, HASH_LEN)?;
    let mut out = [0u8; HASH_LEN];
    out.copy_from_slice(&v);
    Ok(out)
}

/// `Derive-Secret(Master, "res master", Transcript)`.
pub fn res_master(master: &[u8; 32], transcript: &[u8]) -> Result<[u8; HASH_LEN], String> {
    derive_secret(master, "res master", transcript)
}

/// NewSessionTicket handshake message → (nonce, ticket identity).
pub fn parse_new_session_ticket(msg: &[u8]) -> Result<(Vec<u8>, Vec<u8>), String> {
    if msg.len() < 13 || msg[0] != 0x04 {
        return Err("tls: not NewSessionTicket".into());
    }
    let n = ((msg[1] as usize) << 16) | ((msg[2] as usize) << 8) | (msg[3] as usize);
    if msg.len() < 4 + n {
        return Err("tls: NewSessionTicket length".into());
    }
    let mut i = 4 + 4 + 4;
    if i >= msg.len() {
        return Err("tls: NewSessionTicket nonce".into());
    }
    let nl = msg[i] as usize;
    i += 1;
    if i + nl + 2 > msg.len() {
        return Err("tls: NewSessionTicket nonce".into());
    }
    let nonce = msg[i..i + nl].to_vec();
    i += nl;
    let tl = u16::from_be_bytes([msg[i], msg[i + 1]]) as usize;
    i += 2;
    if i + tl > msg.len() {
        return Err("tls: NewSessionTicket ticket".into());
    }
    Ok((nonce, msg[i..i + tl].to_vec()))
}

impl SessionCache {
    /// Install a ticket from a NewSessionTicket message after a 1-RTT handshake.
    pub fn install_nst(
        &mut self,
        host: &str,
        nst: &[u8],
        res_master: &[u8; 32],
        pk: &[u8; 32],
    ) -> Result<(), String> {
        let (nonce, identity) = parse_new_session_ticket(nst)?;
        self.store(issue_ticket(host, res_master, &nonce, &identity, pk)?);
        Ok(())
    }
}

/// NewSessionTicket handshake message (type 0x04). Empty extensions.
pub fn new_session_ticket(lifetime: u32, age_add: u32, nonce: &[u8], ticket: &[u8]) -> Vec<u8> {
    let mut body = Vec::new();
    body.extend_from_slice(&lifetime.to_be_bytes());
    body.extend_from_slice(&age_add.to_be_bytes());
    body.push(nonce.len() as u8);
    body.extend_from_slice(nonce);
    body.extend_from_slice(&(ticket.len() as u16).to_be_bytes());
    body.extend_from_slice(ticket);
    body.extend_from_slice(&0u16.to_be_bytes());
    let n = body.len();
    let mut h = vec![
        0x04,
        ((n >> 16) & 0xff) as u8,
        ((n >> 8) & 0xff) as u8,
        (n & 0xff) as u8,
    ];
    h.extend(body);
    h
}

pub fn issue_ticket(
    host: &str,
    res_master: &[u8; 32],
    nonce: &[u8],
    identity: &[u8],
    pk: &[u8; 32],
) -> Result<Ticket, String> {
    Ok(Ticket {
        host: host.into(),
        identity: identity.to_vec(),
        nonce: nonce.to_vec(),
        psk: resumption_psk(res_master, nonce)?,
        pk: *pk,
    })
}

/// Binder key = Derive-Secret(Early, "res binder", "") then Finished-key.
pub fn psk_binder(psk: &[u8; 32], truncated_ch: &[u8]) -> Result<[u8; HASH_LEN], String> {
    let early = early_secret_psk(psk);
    let binder_secret = derive_secret(&early, "res binder", b"")?;
    let fk = finished_key(&binder_secret)?;
    Ok(hmac_sha256(&fk, &sha256(truncated_ch)))
}

#[cfg(test)]
fn arr32(v: &[u8]) -> [u8; 32] {
    let mut a = [0u8; 32];
    a.copy_from_slice(&v[..32]);
    a
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tls13::{client_hello_tls13_psk, handshake_secret_psk_dhe, offers_tls13};

    fn hx(s: &str) -> Vec<u8> {
        (0..s.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
            .collect()
    }

    fn hx32(s: &str) -> [u8; 32] {
        arr32(&hx(s))
    }

    #[test]
    fn rfc8448_resumption_psk() {
        let rm = hx32("7df235f2031d2a051287d02b0241b0bfdaf86cc856231f2d5aba46c434ec196c");
        let psk = resumption_psk(&rm, &[0x00, 0x00]).unwrap();
        assert_eq!(
            psk,
            hx32("4ecd0eb6ec3b4d87f5d6028f922ca4c5851a277fd41311c9e62d2c9492e1c4f3")
        );
        let t = issue_ticket("gsys.dev", &rm, &[0, 0], b"ticket-1", &[9u8; 32]).unwrap();
        let mut cache = SessionCache::default();
        cache.store(t.clone());
        assert_eq!(cache.lookup("gsys.dev").unwrap().psk, psk);
        cache.store(t);
        assert_eq!(cache.len(), 1, "one ticket per host");
        let mut nst = vec![0x04, 0x00, 0x00, 0x11];
        nst.extend_from_slice(&0x1eu32.to_be_bytes());
        nst.extend_from_slice(&0u32.to_be_bytes());
        nst.push(2);
        nst.extend_from_slice(&[0, 0]);
        nst.extend_from_slice(&[0, 2, 0xaa, 0xbb]);
        nst.extend_from_slice(&[0, 0]);
        let mut c2 = SessionCache::default();
        c2.install_nst("10.0.2.2", &nst, &rm, &[9u8; 32]).unwrap();
        assert_eq!(c2.lookup("10.0.2.2").unwrap().nonce, vec![0, 0]);
        assert_eq!(c2.lookup("10.0.2.2").unwrap().identity, vec![0xaa, 0xbb]);
    }

    #[test]
    fn resume_hello_reuses_ticket_without_early_data() {
        let rm = hx32("7df235f2031d2a051287d02b0241b0bfdaf86cc856231f2d5aba46c434ec196c");
        let t = issue_ticket("gsys.dev", &rm, &[0, 0], b"ticket-1", &[9u8; 32]).unwrap();
        let rnd = [0x11u8; 32];
        let ch = client_hello_tls13_psk(&rnd, &t.pk, "gsys.dev", &t).unwrap();
        assert!(offers_tls13(&ch));
        assert!(ch.windows(2).any(|w| w == [0x00, 0x29]), "pre_shared_key");
        assert!(!ch.windows(2).any(|w| w == [0x00, 0x2a]), "no 0-RTT");
        let ecdhe = [0x22u8; 32];
        let early = early_secret_psk(&t.psk);
        let hs = handshake_secret_psk_dhe(&early, &ecdhe).unwrap();
        assert_ne!(hs, extract_zeros());
    }

    fn extract_zeros() -> [u8; 32] {
        extract(&[0u8; 32], &[0u8; 32])
    }
}
