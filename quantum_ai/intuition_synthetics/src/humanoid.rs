// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//! Virtual humanoid integration.
//!
//! The humanoid is the top-level object that owns the sensor bank, the motor
//! bank, the dual-circulatory system and the cervical-electrical nervous
//! distribution. It is deliberately a *stub* of the embodied platform:
//!
//!   - the cameras do not render images;
//!   - the muscles do not solve multi-body dynamics;
//!   - the circulatory loops do not solve thermofluids;
//!   - the nervous bus does not contain an actual quantum co-processor.
//!
//! What it does contain is the **wiring plan**: how captor data are aggregated,
//! fed to the quantum-reversible C runtime, and converted back into motor
//! commands and physiological state. That is the minimum needed to demonstrate
//! the thesis's claim that environmental intuition can guide a body.

use crate::anatomy::{validate_tables, PartId, RegionId};
use crate::intuition::{EnvWorld, Pose, Vec3};
use crate::motors::{Articulation, MotorBank};
use crate::physiology::{CervicalBus, CirculatorySystem, ZipperRing};
use crate::senses::{CaptorBank, StereoCamera};

/// The top-level humanoid embodiment.
#[derive(Clone, Debug)]
pub struct Humanoid {
    pub captors: CaptorBank,
    pub motors: MotorBank,
    pub circulation: CirculatorySystem,
    pub zipper: ZipperRing,
    pub cervical: CervicalBus,
    /// Bound qrc_env handle (0 = none). The world is queried by reference from
    /// the C ABI; the humanoid does not own it so the qrc_env handle stays valid
    /// for independent use.
    pub env_id: u64,
    /// Last computed proprioceptive pose (head position + yaw).
    pub pose: Pose,
    pub tick_count: u64,
}

impl Default for Humanoid {
    fn default() -> Self {
        Self::new()
    }
}

impl Humanoid {
    /// Construct a humanoid and validate the anatomy tables.
    pub fn new() -> Self {
        validate_tables().expect("anatomy tables are self-consistent");
        Self {
            captors: CaptorBank::new(),
            motors: MotorBank::new(),
            circulation: CirculatorySystem::new(),
            zipper: ZipperRing::new(),
            cervical: CervicalBus::new(),
            env_id: 0,
            pose: Pose::default(),
            tick_count: 0,
        }
    }

    /// Bind an environment world by qrc_env handle. The world stays
    /// pre-loaded (rule 1 of the thesis: load once, query many).
    pub fn bind_env_id(&mut self, id: u64) {
        self.env_id = id;
        self.cervical.bound_ai = id;
    }

    /// Point the head and converge the eyes on a world point.
    pub fn look_at(&mut self, world_point: Vec3) {
        self.captors.camera.focalize(world_point);
        // Update proprioceptive pose: head is at a fixed offset above the torso.
        self.pose.position = Vec3 { x: 0.0, y: 1.6, z: 0.0 };
        self.pose.yaw = self.captors.camera.pan;
    }

    /// Command one joint. The command is normalised to the joint's range in the
    /// motor bank.
    pub fn articulate(&mut self, cmd: Articulation) -> bool {
        self.motors.articulate(cmd)
    }

    /// Read one captor cell as a normalised scalar. Used by the cervical bus
    /// before quantum encoding.
    pub fn captor_scalar(&self, part: PartId, idx: u8) -> f32 {
        if let Some(c) = self.captors.thermo.iter().find(|c| c.part == part && c.local_idx == idx) {
            return (c.kelvin - 273.0) / 100.0;
        }
        if let Some(c) = self.captors.touch.iter().find(|c| c.part == part && c.local_idx == idx) {
            return (c.pressure + c.proximity + c.shear) / 3.0;
        }
        0.0
    }

    /// One embodiment tick. Order matters:
    ///   1. Physiology (fluid state, zipper integrity).
    ///   2. Sensors (sample from the current pose / world).
    ///   3. Cervical bus aggregates afferent data by region.
    ///   4. Quantum intuition query (if `world` is provided) produces a plan hint.
    ///   5. Motor actuators update joints.
    pub fn tick(&mut self, dt_s: f32, world: Option<&EnvWorld>) {
        if !self.zipper.sealed() {
            // The robot cannot move or sense safely while the neck service port
            // is open. Clear commands and wait.
            return;
        }

        // 1. Physiology.
        self.circulation.tick(dt_s);

        // 2. Sample sensors (stub: just drift thermal noise and mark fresh).
        self.sample_sensors(dt_s);

        // 3. Aggregate captors onto the cervical bus.
        self.captors.flatten();
        for r in crate::anatomy::REGIONS.iter() {
            // Extract the sub-vector for this region.
            let mut region_vec = Vec::new();
            for t in self.captors.thermo.iter() {
                if crate::anatomy::part_by_id(t.part).map_or(false, |p| p.region == r.id) {
                    region_vec.push((t.kelvin - 273.0) / 100.0);
                }
            }
            for t in self.captors.touch.iter() {
                if crate::anatomy::part_by_id(t.part).map_or(false, |p| p.region == r.id) {
                    region_vec.push(t.pressure);
                    region_vec.push(t.proximity);
                    region_vec.push(t.shear);
                }
            }
            if r.name == "Cranial" {
                // Vision also belongs to the head.
                for b in self.captors.camera.feature_depth_bins.iter() {
                    region_vec.push(*b);
                }
            }
            let _ = self.cervical.feed_captors(r.id, &region_vec);
        }

        // 4. Late measurement / environmental intuition.
        if let Some(world) = world {
            // The quantum query is the same as qrc_env_plan_hint: score the
            // stored world against the head pose and read a sparse decision
            // vector (foothold, avoid, confidence).
            let hint = world.plan_hint(&self.pose);

            // Route the resulting sparse decision to the motor regions.
            // This is the point where quantum output becomes classical motor
            // features.
            let mut leg_vec = vec![hint.confidence, hint.next_foothold.x, hint.next_foothold.y, hint.next_foothold.z];
            leg_vec.resize(8, 0.0);
            self.cervical.route_motors(RegionId(7), &leg_vec); // LeftLower
            self.cervical.route_motors(RegionId(8), &leg_vec); // RightLower
        }

        // 5. Motors update.
        self.motors.tick(dt_s);

        // 6. Proprioception: read back the motor bank into pose (stub).
        self.update_proprioception();

        self.tick_count += 1;
    }

    /// Return the flattened captor vector that would be encoded into a logical
    /// register for QRAM_LoadSuperposition.
    pub fn sensor_frame(&mut self) -> Vec<f32> {
        self.captors.flatten();
        self.captors.vector.clone()
    }

    /// Return the flattened motor command vector.
    pub fn motor_frame(&self) -> Vec<f32> {
        self.motors.flatten()
    }

    /// Total number of captor and motor scalars in the embodiment.
    pub fn io_dimension(&self) -> usize {
        self.captors.n_cells() + self.motors.flatten().len()
    }

    fn sample_sensors(&mut self, _dt_s: f32) {
        // Stub: mark every cell fresh. Thermal drift is a deterministic small
        // sinusoid so the captor vector stays reproducible without a random
        // dependency.
        let w = self.tick_count as f32 * 0.01;
        for (i, t) in self.captors.thermo.iter_mut().enumerate() {
            t.kelvin += (w + i as f32).sin() * 0.02;
            t.fresh = true;
        }
        for t in self.captors.touch.iter_mut() {
            // Contact with self is zero in free air.
            t.pressure = 0.0;
            t.proximity = 0.0;
            t.shear = 0.0;
            t.fresh = true;
        }
        // Camera features are produced by `focalize` / `track`.
    }

    fn update_proprioception(&mut self) {
        // Stub: set the head height; later this would read the foot/hip joints.
        self.pose.position.y = 1.6;
        self.pose.yaw = self.captors.camera.pan;
    }
}

/// Convenience constructor for a humanoid already looking forward.
pub fn standing_humanoid() -> Humanoid {
    let mut h = Humanoid::new();
    h.look_at(Vec3 { x: 0.0, y: 0.0, z: 5.0 });
    h
}

/// Helper: return a reference to the stereo camera.
pub fn head_camera(humanoid: &Humanoid) -> &StereoCamera {
    &humanoid.captors.camera
}
