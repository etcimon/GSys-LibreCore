// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Explicit entropy for TLS random. Hostnames, ticks, and handshake
//! hashes are not entropy. Absent entropy fails closed.

/// Fill 32-byte TLS random (and later nonces). Not a clock.
pub trait Entropy {
    fn fill(&mut self, buf: &mut [u8]) -> Result<(), String>;
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
