// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//! Classical stand-in for bucket-brigade qRAM.

use crate::intuition::Keyframe;

#[derive(Clone, Debug)]
pub struct Qram {
    pub capacity: u64,
    pub width_bits: u32,
    pub slots: Vec<Option<Keyframe>>,
    pub coherence_s: f64,
    pub fidelity: f64,
}

impl Qram {
    pub fn new(capacity: u64, width_bits: u32) -> Self {
        let cap = capacity.min(1 << 24) as usize; // keep the stub bounded
        Self {
            capacity: cap as u64,
            width_bits,
            slots: vec![None; cap],
            coherence_s: 1e-3,
            fidelity: 0.99,
        }
    }

    pub fn store(&mut self, addr: u64, kf: Keyframe) -> bool {
        if let Some(slot) = self.slots.get_mut(addr as usize) {
            *slot = Some(kf);
            true
        } else {
            false
        }
    }

    pub fn load(&self, addr: u64) -> Option<Keyframe> {
        self.slots.get(addr as usize).and_then(|s| *s)
    }

    pub fn occupied(&self) -> u64 {
        self.slots.iter().filter(|s| s.is_some()).count() as u64
    }
}
