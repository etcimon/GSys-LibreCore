// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Explicit entropy for TLS random. Hostnames, ticks, and handshake
//! hashes are not entropy. Absent entropy fails closed. HMAC-DRBG is a
//! construct with health tests, not an independent CSPRNG-quality review.

/// Fill 32-byte TLS random (and later nonces). Not a clock.
pub trait Entropy {
    fn fill(&mut self, buf: &mut [u8]) -> Result<(), String>;
}

/// Stuck-bit / repetition health on a noise-source sample. Not SP 800-90B
/// certification.
pub fn entropy_health(bytes: &[u8]) -> Result<(), String> {
    if bytes.len() < 32 {
        return Err("tls: entropy short".into());
    }
    if bytes.iter().all(|&b| b == 0) {
        return Err("tls: entropy stuck zero".into());
    }
    if bytes.iter().all(|&b| b == 0xff) {
        return Err("tls: entropy stuck ones".into());
    }
    let ones = bytes.iter().fold(0u32, |n, b| n + b.count_ones());
    let bits = (bytes.len() as u32).saturating_mul(8);
    if ones < bits / 8 || ones > bits.saturating_sub(bits / 8) {
        return Err("tls: entropy weight".into());
    }
    let mut run = 1u8;
    for w in bytes.windows(2) {
        if w[0] == w[1] {
            run = run.saturating_add(1);
            if run >= 16 {
                return Err("tls: entropy repetition".into());
            }
        } else {
            run = 1;
        }
    }
    Ok(())
}

/// Production default: no CSPRNG / virtio-rng is wired yet.
#[derive(Clone, Copy, Debug, Default)]
pub struct NoEntropy;

impl Entropy for NoEntropy {
    fn fill(&mut self, _buf: &mut [u8]) -> Result<(), String> {
        Err("tls: no entropy".into())
    }
}

/// Test-only stream. Not a CSPRNG. Not `sha256(host)`.
#[derive(Clone, Copy, Debug)]
pub struct FixtureEntropy {
    seed: [u8; 32],
}

impl FixtureEntropy {
    /// Distinct from all-zero and from a hostname hash.
    pub const TEST: Self = Self { seed: [0xa5; 32] };

    pub fn from_seed(seed: [u8; 32]) -> Self {
        Self { seed }
    }
}

impl Entropy for FixtureEntropy {
    fn fill(&mut self, buf: &mut [u8]) -> Result<(), String> {
        for (i, b) in buf.iter_mut().enumerate() {
            *b = self.seed[i % 32] ^ (i as u8);
        }
        self.seed[0] = self.seed[0].wrapping_add(1);
        Ok(())
    }
}

/// virtio-rng (DeviceID 4) adapter. Bytes come from the device ring.
/// Exhaustion / empty device fails closed. Not a CSPRNG claim.
#[derive(Clone, Debug, Default)]
pub struct VirtioRng {
    buf: Vec<u8>,
    off: usize,
}

impl VirtioRng {
    /// Guest-visible entropy from a virtio-rng used buffer.
    pub fn from_device(bytes: Vec<u8>) -> Self {
        Self { buf: bytes, off: 0 }
    }

    /// HKDF-Extract whitener over device bytes. Health-tested. Still not a
    /// CSPRNG-quality review.
    pub fn from_device_extracted(bytes: &[u8]) -> Result<Self, String> {
        entropy_health(bytes)?;
        let prk = crate::hkdf::extract(&[], bytes);
        Ok(Self {
            buf: prk.to_vec(),
            off: 0,
        })
    }
}

impl Entropy for VirtioRng {
    fn fill(&mut self, buf: &mut [u8]) -> Result<(), String> {
        if self.buf.is_empty() {
            return Err("tls: no virtio-rng".into());
        }
        if self.off.saturating_add(buf.len()) > self.buf.len() {
            return Err("tls: virtio-rng exhausted".into());
        }
        buf.copy_from_slice(&self.buf[self.off..self.off + buf.len()]);
        self.off += buf.len();
        Ok(())
    }
}

/// NIST SP 800-90A HMAC-DRBG-SHA256 over a seed. Not a CSPRNG-quality claim.
#[derive(Clone, Debug)]
pub struct HmacDrbg {
    k: [u8; 32],
    v: [u8; 32],
}

impl HmacDrbg {
    pub fn instantiate(seed: &[u8]) -> Result<Self, String> {
        entropy_health(seed)?;
        let mut d = Self {
            k: [0u8; 32],
            v: [1u8; 32],
        };
        d.update(seed);
        Ok(d)
    }

    /// Whitened virtio-rng bytes become the DRBG seed. Health-tested.
    pub fn from_virtio_extracted(bytes: &[u8]) -> Result<Self, String> {
        entropy_health(bytes)?;
        let prk = crate::hkdf::extract(&[], bytes);
        Self::instantiate(&prk)
    }

    fn update(&mut self, provided: &[u8]) {
        self.k = hmac_kv(&self.k, &self.v, 0x00, provided);
        self.v = crate::hmac::hmac_sha256(&self.k, &self.v);
        if !provided.is_empty() {
            self.k = hmac_kv(&self.k, &self.v, 0x01, provided);
            self.v = crate::hmac::hmac_sha256(&self.k, &self.v);
        }
    }
}

fn hmac_kv(k: &[u8; 32], v: &[u8; 32], sep: u8, provided: &[u8]) -> [u8; 32] {
    let mut m = Vec::with_capacity(32 + 1 + provided.len());
    m.extend_from_slice(v);
    m.push(sep);
    m.extend_from_slice(provided);
    crate::hmac::hmac_sha256(k, &m)
}

impl Entropy for HmacDrbg {
    fn fill(&mut self, buf: &mut [u8]) -> Result<(), String> {
        if buf.is_empty() {
            return Err("tls: drbg empty".into());
        }
        let mut out = Vec::with_capacity(buf.len());
        while out.len() < buf.len() {
            self.v = crate::hmac::hmac_sha256(&self.k, &self.v);
            out.extend_from_slice(&self.v);
        }
        buf.copy_from_slice(&out[..buf.len()]);
        self.update(&[]);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn virtio_rng_fail_closed_then_fills() {
        let mut empty = VirtioRng::from_device(vec![]);
        assert!(empty
            .fill(&mut [0u8; 8])
            .unwrap_err()
            .contains("virtio-rng"));
        let mut rng = VirtioRng::from_device((0u8..64).collect());
        let mut a = [0u8; 32];
        rng.fill(&mut a).unwrap();
        assert_eq!(a[0], 0);
        assert_eq!(a[31], 31);
        let mut b = [0u8; 32];
        rng.fill(&mut b).unwrap();
        assert_eq!(b[0], 32);
        assert!(rng.fill(&mut [0u8; 1]).unwrap_err().contains("exhausted"));
        assert!(VirtioRng::from_device_extracted(&[1, 2, 3])
            .unwrap_err()
            .contains("entropy"));
        let seed: Vec<u8> = (0u8..32).collect();
        let mut w = VirtioRng::from_device_extracted(&seed).unwrap();
        let mut out = [0u8; 32];
        w.fill(&mut out).unwrap();
        assert_ne!(out, seed.as_slice());
    }

    #[test]
    fn hmac_drbg_from_extracted_is_not_the_seed() {
        assert!(HmacDrbg::instantiate(&[1, 2, 3])
            .unwrap_err()
            .contains("entropy"));
        let seed: Vec<u8> = (0u8..32).collect();
        let mut d = HmacDrbg::from_virtio_extracted(&seed).unwrap();
        let mut a = [0u8; 32];
        d.fill(&mut a).unwrap();
        assert_ne!(&a[..], seed.as_slice());
        let mut b = [0u8; 32];
        d.fill(&mut b).unwrap();
        assert_ne!(a, b);
        let mut d2 = HmacDrbg::from_virtio_extracted(&seed).unwrap();
        let mut c = [0u8; 32];
        d2.fill(&mut c).unwrap();
        assert_eq!(a, c);
        assert!(entropy_health(&[0u8; 32])
            .unwrap_err()
            .contains("stuck zero"));
        assert!(entropy_health(&[0xffu8; 32])
            .unwrap_err()
            .contains("stuck ones"));
        assert!(entropy_health(&[7u8; 32])
            .unwrap_err()
            .contains("repetition"));
    }
}
