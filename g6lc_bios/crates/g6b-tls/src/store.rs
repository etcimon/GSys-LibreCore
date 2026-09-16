// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! In-memory trust store. Spec: Botan `certstor` (not linked). No system roots.

#![allow(missing_docs)]

use crate::cert::{
    check_name_constraints, name_matches, tls_server_eku_ok, verify_signature, Cert,
    KU_DIGITAL_SIGNATURE, KU_KEY_CERT_SIGN,
};
use crate::clock::{check_validity, Clock};

const MAX_CHAIN: usize = 8;
const MAX_ROOTS: usize = 32;

/// Pinned roots. Empty store fails closed.
#[derive(Clone, Debug, Default)]
pub struct CertStore {
    roots: Vec<Cert>,
}

impl CertStore {
    pub fn len(&self) -> usize {
        self.roots.len()
    }

    pub fn is_empty(&self) -> bool {
        self.roots.is_empty()
    }

    pub fn roots(&self) -> &[Cert] {
        &self.roots
    }

    /// Pin a trust anchor. Self-signed end-entity pins are allowed (RFC 8448).
    pub fn add_root(&mut self, c: Cert) -> Result<(), String> {
        if self.roots.len() >= MAX_ROOTS {
            return Err("tls: trust budget".into());
        }
        let self_signed = c.issuer_der == c.subject_der;
        if !c.is_ca && !self_signed {
            return Err("tls: not a trust anchor".into());
        }
        if self_signed && !verify_signature(&c, &c) {
            return Err("tls: root signature".into());
        }
        if self
            .roots
            .iter()
            .any(|r| r.subject_der == c.subject_der && r.der == c.der)
        {
            return Ok(());
        }
        self.roots.push(c);
        Ok(())
    }

    /// `chain[0]` is the leaf. Host is SNI / URL host.
    pub fn verify_chain(
        &self,
        chain: &[Cert],
        host: &str,
        clock: &dyn Clock,
    ) -> Result<(), String> {
        if self.roots.is_empty() {
            return Err("tls: no trust store".into());
        }
        if chain.is_empty() || chain.len() > MAX_CHAIN {
            return Err("tls: chain".into());
        }
        let leaf = &chain[0];
        if !name_matches(leaf, host) {
            return Err("tls: name".into());
        }
        if let Some(ku) = leaf.key_usage {
            if ku & KU_DIGITAL_SIGNATURE == 0 {
                return Err("tls: key usage".into());
            }
        }
        if !tls_server_eku_ok(leaf) {
            return Err("tls: eku".into());
        }
        for (i, c) in chain.iter().enumerate() {
            check_validity(c.not_before, c.not_after, clock)?;
            if i + 1 < chain.len() {
                let issuer = &chain[i + 1];
                if !issuer.is_ca {
                    return Err("tls: issuer not ca".into());
                }
                if let Some(ku) = issuer.key_usage {
                    if ku & KU_KEY_CERT_SIGN == 0 {
                        return Err("tls: issuer key usage".into());
                    }
                }
                if c.issuer_der != issuer.subject_der {
                    return Err("tls: issuer name".into());
                }
                if !verify_signature(c, issuer) {
                    return Err("tls: cert signature".into());
                }
                if !c.aki.is_empty() && !issuer.ski.is_empty() && c.aki != issuer.ski {
                    return Err("tls: aki".into());
                }
                for prior in chain.iter().take(i + 1) {
                    check_name_constraints(prior, issuer)?;
                }
            }
        }
        let anchor = chain.last().unwrap();
        let pinned = self.roots.iter().any(|r| {
            r.der == anchor.der
                || (r.subject_der == anchor.subject_der && verify_signature(anchor, r))
        });
        if !pinned {
            // leaf may be the pin
            let leaf_pin = self.roots.iter().any(|r| r.der == leaf.der);
            if !leaf_pin {
                return Err("tls: untrusted".into());
            }
        }
        if chain.len() == 1 {
            if !verify_signature(leaf, leaf)
                && !self.roots.iter().any(|r| verify_signature(leaf, r))
            {
                return Err("tls: cert signature".into());
            }
        }
        Ok(())
    }

    /// TLS 1.3 Certificate handshake message (leaf first).
    pub fn verify_tls13(&self, msg: &[u8], host: &str, clock: &dyn Clock) -> Result<Cert, String> {
        let ders = crate::cert::certs_from_tls13(msg)?;
        let chain: Vec<Cert> = ders
            .iter()
            .map(|d| crate::cert::parse(d))
            .collect::<Result<_, _>>()?;
        self.verify_chain(&chain, host, clock)?;
        chain.into_iter().next().ok_or_else(|| "tls: chain".into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cert::{name_matches, parse, parse_chain, tls_server_eku_ok, verify_signature};
    use crate::clock::{FixtureClock, NoClock};

    fn rfc8448_pem() -> &'static str {
        include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../kernel-spec/botan/test_data/tls_13_rfc8448/server_certificate.pem"
        ))
    }

    fn alt_pem() -> &'static str {
        include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../kernel-spec/botan/test_data/x509/x509test/ValidAltName.pem"
        ))
    }

    #[test]
    fn rfc8448_leaf_pin_and_name() {
        let c = parse(rfc8448_pem().as_bytes()).unwrap();
        assert_eq!(c.cn, "rsa");
        assert_eq!(c.algo, "rsa");
        assert!(!c.is_ca);
        assert!(c.rsa.is_some());
        assert!(verify_signature(&c, &c));
        assert!(name_matches(&c, "rsa"));
        assert!(!name_matches(&c, "server"));
        let mut store = CertStore::default();
        assert!(store
            .verify_chain(
                &[c.clone()],
                "rsa",
                &FixtureClock {
                    unix: 1_483_228_800
                }
            )
            .unwrap_err()
            .contains("trust"));
        store.add_root(c.clone()).unwrap();
        store
            .verify_chain(
                &[c.clone()],
                "rsa",
                &FixtureClock {
                    unix: 1_483_228_800,
                },
            )
            .unwrap();
        assert!(store
            .verify_chain(
                &[c.clone()],
                "server",
                &FixtureClock {
                    unix: 1_483_228_800
                }
            )
            .unwrap_err()
            .contains("name"));
        assert!(store
            .verify_chain(&[c], "rsa", &NoClock)
            .unwrap_err()
            .contains("time"));
    }

    #[test]
    fn botan_altname_chain_prefers_san() {
        let chain = parse_chain(alt_pem().as_bytes()).unwrap();
        assert_eq!(chain.len(), 2);
        assert!(chain[0].san.iter().any(|s| s == "www.tls.test"));
        assert!(!name_matches(&chain[0], "www.tls.test.invalid.test"));
        assert!(name_matches(&chain[0], "www.tls.test"));
        let mut store = CertStore::default();
        store.add_root(chain[1].clone()).unwrap();
        let clock = FixtureClock {
            unix: 1_445_360_000,
        };
        store.verify_chain(&chain, "www.tls.test", &clock).unwrap();
        assert!(store
            .verify_chain(&chain, "evil.test", &clock)
            .unwrap_err()
            .contains("name"));
    }

    fn botan_x509test(name: &str) -> &'static str {
        match name {
            "ValidNameConstraint.pem" => include_str!(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../../kernel-spec/botan/test_data/x509/x509test/ValidNameConstraint.pem"
            )),
            "InvalidNameConstraintPermit.pem" => include_str!(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../../kernel-spec/botan/test_data/x509/x509test/InvalidNameConstraintPermit.pem"
            )),
            "InvalidNameConstraintExclude.pem" => include_str!(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../../kernel-spec/botan/test_data/x509/x509test/InvalidNameConstraintExclude.pem"
            )),
            "InvalidExtendedKeyUsage.pem" => include_str!(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../../kernel-spec/botan/test_data/x509/x509test/InvalidExtendedKeyUsage.pem"
            )),
            _ => panic!("unknown botan fixture {name}"),
        }
    }

    #[test]
    fn botan_name_constraints_and_eku() {
        let clock = FixtureClock {
            unix: 1_445_360_000,
        };
        let valid = parse_chain(botan_x509test("ValidNameConstraint.pem").as_bytes()).unwrap();
        assert!(valid.len() >= 2);
        assert!(
            !valid.last().unwrap().nc_permit_dns.is_empty()
                || valid
                    .iter()
                    .any(|c| !c.nc_permit_dns.is_empty() || !c.nc_exclude_dns.is_empty())
        );
        let mut store = CertStore::default();
        store.add_root(valid.last().unwrap().clone()).unwrap();
        store.verify_chain(&valid, "www.tls.test", &clock).unwrap();
        let permit =
            parse_chain(botan_x509test("InvalidNameConstraintPermit.pem").as_bytes()).unwrap();
        let mut s2 = CertStore::default();
        s2.add_root(permit.last().unwrap().clone()).unwrap();
        assert!(s2
            .verify_chain(&permit, "www.tls.test", &clock)
            .unwrap_err()
            .contains("name constraint"));
        let excl =
            parse_chain(botan_x509test("InvalidNameConstraintExclude.pem").as_bytes()).unwrap();
        let mut s3 = CertStore::default();
        s3.add_root(excl.last().unwrap().clone()).unwrap();
        assert!(s3
            .verify_chain(&excl, "www.tls.test", &clock)
            .unwrap_err()
            .contains("name constraint"));
        let eku = parse_chain(botan_x509test("InvalidExtendedKeyUsage.pem").as_bytes()).unwrap();
        assert!(!tls_server_eku_ok(&eku[0]));
        let mut s4 = CertStore::default();
        s4.add_root(eku.last().unwrap().clone()).unwrap();
        assert!(s4
            .verify_chain(&eku, eku[0].cn.as_str(), &clock)
            .unwrap_err()
            .contains("eku"));
    }
}
