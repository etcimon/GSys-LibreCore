// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//! Environmental intuition: query a pre-loaded world as if it were qRAM.
//!
//! Optimal usage (programmatic):
//! 1. Load the site once (`load_keyframe` / `load_batch`).
//! 2. Each control tick: encode pose → score all slots → measure top-k.
//! 3. Emit a plan hint (foothold, avoid) — never dump the full map.
//! 4. Write outcomes back (`remember_failure` / `remember_success`).
//!
//! Servo loops stay classical. This module only removes the search tax.

use crate::qram::Qram;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct Vec3 {
    pub x: f32,
    pub y: f32,
    pub z: f32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct Pose {
    pub position: Vec3,
    pub yaw: f32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct Keyframe {
    pub pose: Pose,
    pub occupancy: f32,
    pub slip_risk: f32,
    pub affordance: f32,
    pub flags: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct Hit {
    pub slot: u64,
    pub frame: Keyframe,
    pub score: f32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct PlanHint {
    pub next_foothold: Vec3,
    pub avoid: Vec3,
    pub confidence: f32,
    pub n_hits_used: u32,
}

fn dist2(a: Vec3, b: Vec3) -> f32 {
    let dx = a.x - b.x;
    let dy = a.y - b.y;
    let dz = a.z - b.z;
    dx * dx + dy * dy + dz * dz
}

/// Simulated kernel K(q, k) ≈ exp(−||p_q − p_k||² / 2σ²) · (1 − slip) · affordance.
fn kernel(query: &Pose, kf: &Keyframe, sigma: f32) -> f32 {
    let d2 = dist2(query.position, kf.pose.position);
    let s2 = (sigma * sigma).max(1e-4);
    let spatial = (-0.5 * d2 / s2).exp();
    let dyaw = (query.yaw - kf.pose.yaw).sin().abs();
    let heading = (1.0 - dyaw).max(0.0);
    spatial * heading * (1.0 - kf.slip_risk.clamp(0.0, 1.0)) * kf.affordance.clamp(0.05, 1.0)
}

pub struct EnvWorld {
    pub ram: Qram,
    pub sigma: f32,
}

impl EnvWorld {
    pub fn new(capacity: u64) -> Self {
        Self {
            ram: Qram::new(capacity, 128),
            sigma: 1.5,
        }
    }

    pub fn load(&mut self, slot: u64, kf: Keyframe) -> bool {
        self.ram.store(slot, kf)
    }

    pub fn len(&self) -> u64 {
        self.ram.occupied()
    }

    /// "Superposition query": score every occupied slot, keep top-k.
    /// In the hypothesized hardware this is one QRAM_LoadSuperposition
    /// + kernel_swap_test + amp_estimate_to_dram of only k hits.
    pub fn query(&self, q: &Pose, max_hits: usize) -> Vec<Hit> {
        let mut hits: Vec<Hit> = self
            .ram
            .slots
            .iter()
            .enumerate()
            .filter_map(|(i, slot)| {
                slot.map(|kf| Hit {
                    slot: i as u64,
                    frame: kf,
                    score: kernel(q, &kf, self.sigma),
                })
            })
            .collect();
        hits.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));
        hits.truncate(max_hits.max(1));
        hits
    }

    pub fn plan_hint(&self, here: &Pose) -> PlanHint {
        let hits = self.query(here, 8);
        if hits.is_empty() {
            return PlanHint {
                next_foothold: here.position,
                avoid: Vec3::default(),
                confidence: 0.0,
                n_hits_used: 0,
            };
        }

        // Foothold: highest-affordance nearby hit that is not occupied.
        let mut foothold = here.position;
        let mut best_a = -1.0f32;
        let mut avoid = Vec3::default();
        let mut worst_slip = -1.0f32;

        for h in &hits {
            if h.frame.occupancy < 0.5 && h.frame.affordance > best_a {
                best_a = h.frame.affordance;
                foothold = h.frame.pose.position;
            }
            if h.frame.slip_risk > worst_slip {
                worst_slip = h.frame.slip_risk;
                avoid = h.frame.pose.position;
            }
        }

        let conf = hits.first().map(|h| h.score).unwrap_or(0.0).clamp(0.0, 1.0);
        PlanHint {
            next_foothold: foothold,
            avoid,
            confidence: conf,
            n_hits_used: hits.len() as u32,
        }
    }

    pub fn remember_failure(&mut self, where_: &Pose, severity: f32) {
        if let Some((i, _)) = self.nearest_slot(where_) {
            if let Some(kf) = self.ram.slots[i].as_mut() {
                kf.slip_risk = (kf.slip_risk + severity.clamp(0.0, 1.0)).min(1.0);
            }
        } else {
            let slot = self.first_free();
            let mut kf = Keyframe {
                pose: *where_,
                occupancy: 0.2,
                slip_risk: severity.clamp(0.0, 1.0),
                affordance: 0.2,
                flags: 1,
            };
            kf.slip_risk = severity.clamp(0.0, 1.0);
            let _ = self.ram.store(slot, kf);
        }
    }

    pub fn remember_success(&mut self, where_: &Pose, quality: f32) {
        if let Some((i, _)) = self.nearest_slot(where_) {
            if let Some(kf) = self.ram.slots[i].as_mut() {
                kf.affordance = (kf.affordance + quality.clamp(0.0, 1.0) * 0.2).min(1.0);
                kf.slip_risk = (kf.slip_risk * 0.9).max(0.0);
            }
        } else {
            let slot = self.first_free();
            let kf = Keyframe {
                pose: *where_,
                occupancy: 0.1,
                slip_risk: 0.0,
                affordance: quality.clamp(0.05, 1.0),
                flags: 2,
            };
            let _ = self.ram.store(slot, kf);
        }
    }

    fn nearest_slot(&self, p: &Pose) -> Option<(usize, f32)> {
        self.ram
            .slots
            .iter()
            .enumerate()
            .filter_map(|(i, s)| s.map(|kf| (i, dist2(p.position, kf.pose.position))))
            .min_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal))
            .filter(|(_, d2)| *d2 < 0.25)
    }

    fn first_free(&self) -> u64 {
        self.ram
            .slots
            .iter()
            .position(|s| s.is_none())
            .unwrap_or(0) as u64
    }
}
