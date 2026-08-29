// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//! Cycle-function primitive: √P sin³(ωt) + √Q cos³(ωt) (and phase).
//!
//! A single dual-rail photonic mode. Gates below match the 2025-era
//! wave-plate / beam-splitter table from the thesis.

use std::f64::consts::FRAC_1_SQRT_2;

#[derive(Clone, Copy, Debug)]
pub struct Cycle {
    pub p: f64, // amplitude on sin³ rail (real for the stub)
    pub q: f64, // amplitude on cos³ rail
    pub phase_q: f64,
}

impl Default for Cycle {
    fn default() -> Self {
        Self {
            p: 1.0,
            q: 0.0,
            phase_q: 0.0,
        }
    }
}

impl Cycle {
    #[allow(dead_code)]
    pub fn identity(self) -> Self {
        self
    }

    /// X: half-wave plate at 45° — swap P ↔ Q
    pub fn x(self) -> Self {
        Self {
            p: self.q,
            q: self.p,
            phase_q: self.phase_q,
        }
    }

    /// Z: √P sin³ − √Q cos³
    pub fn z(self) -> Self {
        Self {
            p: self.p,
            q: -self.q,
            phase_q: self.phase_q,
        }
    }

    /// Hadamard via 50/50 splitter (real stub).
    pub fn h(self) -> Self {
        let p = FRAC_1_SQRT_2 * (self.p + self.q);
        let q = FRAC_1_SQRT_2 * (self.p - self.q);
        Self {
            p,
            q,
            phase_q: self.phase_q,
        }
    }

    pub fn s(mut self) -> Self {
        self.phase_q += std::f64::consts::FRAC_PI_2;
        self
    }

    pub fn t(mut self) -> Self {
        self.phase_q += std::f64::consts::FRAC_PI_4;
        self
    }

    pub fn rz(mut self, phi: f64) -> Self {
        self.phase_q += phi;
        self
    }

    pub fn measure(&self) -> i32 {
        let wp = self.p * self.p;
        let wq = self.q * self.q;
        if wp + wq <= 0.0 {
            return 0;
        }
        if wp >= wq {
            0
        } else {
            1
        }
    }
}

#[derive(Clone, Debug)]
pub struct PregBank {
    pub modes: Vec<Cycle>,
}

impl PregBank {
    pub fn new(n: usize) -> Self {
        Self {
            modes: vec![Cycle::default(); n.max(1)],
        }
    }
}

#[derive(Clone, Debug)]
pub struct LregBank {
    pub logical_id: u64,
    pub distance: u32,
    pub amps: Vec<f32>,
}

impl LregBank {
    pub fn new(n: usize) -> Self {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
        Self {
            logical_id: NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed),
            distance: 29,
            amps: vec![0.0; n.max(1)],
        }
    }
}
