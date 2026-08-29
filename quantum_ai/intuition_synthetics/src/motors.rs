// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//! Virtual humanoid motor / actuation system.
//!
//! Every joint is driven by one or more *muscular hydraulic tendon filament
//! dented-compression motors* operating on the pulley principle. In this stub:
//!
//!   - a `Tendon` is a filament that shortens (compression) under hydraulic
//!     pressure and pulls on a pulley;
//!   - the pulley multiplies force and converts the linear stroke into joint
//!     rotation;
//!   - the joint's output is an angle and an angular momentum (the inertial
//!     state used by the controller).
//!
//! The motors are anchored to the anatomy tables so every tendon has a purpose,
//! a direction of positive action and a compression-distance budget.

use crate::anatomy::{joint_by_id, JointAxis, JointId, PartId};

/// One hydraulic-tendon motor. The "dented-compression" refers to the filament
/// surface: as the hydraulic chamber pressurises, the filament teeth ratchet
/// into a shorter length without slipping. The "pulley principle" means the
/// tendon wraps around a sheave at the joint, so a short stroke produces a large
/// torque arm.
#[derive(Clone, Copy, Debug, Default)]
#[repr(C)]
pub struct Tendon {
    /// Joint this tendon acts on.
    pub joint: JointId,
    /// Name for diagnostics, e.g. "left_elbow_flexor".
    pub name: [u8; 32],
    /// 0..1 : current compression (shortening) of the filament.
    pub compression: f32,
    /// Maximum linear stroke in metres.
    pub compression_distance_m: f32,
    /// Effective pulley radius in metres.
    pub pulley_radius_m: f32,
    /// Force produced at the current pressure, newtons.
    pub tension_n: f32,
    /// Torque = tension * pulley_radius, N·m.
    pub torque_nm: f32,
    /// Direction of positive joint motion when this tendon contracts.
    pub direction: JointAxis,
    /// Sign of action: +1 for agonist, -1 for antagonist.
    pub sign: f32,
    /// Angular momentum this tendon contributes this tick, kg·m²/s.
    pub angular_momentum: f32,
}

/// A single joint, with its tendons and current dynamic state.
#[derive(Clone, Debug, Default)]
#[repr(C)]
pub struct PulleyJoint {
    pub def: JointId,
    pub current_angle: f32,
    pub angular_momentum: f32,
    pub angular_velocity: f32,
    pub target_angle: f32,
    pub min_angle: f32,
    pub max_angle: f32,
    pub tendons: Vec<Tendon>,
}

/// A movement command targeted at one joint.
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct Articulation {
    pub joint: JointId,
    /// Target angle in radians.
    pub target: f32,
    /// Desired peak angular momentum (i.e. effort).
    pub effort: f32,
    /// Primary purpose of this motion, e.g. "raise arm".
    pub purpose: [u8; 48],
}

impl Default for Articulation {
    fn default() -> Self {
        Self {
            joint: JointId(0),
            target: 0.0,
            effort: 0.0,
            purpose: [0u8; 48],
        }
    }
}

/// The full motor bank. Tendons are stored flat, but indexed through joints.
#[derive(Clone, Debug)]
pub struct MotorBank {
    pub joints: Vec<PulleyJoint>,
    pub total_compression: f32,
}

impl Default for MotorBank {
    fn default() -> Self {
        Self::new()
    }
}

impl MotorBank {
    pub fn new() -> Self {
        let mut joints = Vec::new();
        for j in crate::anatomy::JOINTS.iter() {
            let mut tendons = Vec::new();
            let (min_a, max_a) = angle_range(j.primary_axis);

            // Build one agonist and one antagonist tendon per motor the table
            // declares for this joint.
            for i in 0..j.n_motors {
                let is_agonist = (i % 2) == 0;
                let sign = if is_agonist { 1.0 } else { -1.0 };
                let axis = if is_agonist { j.primary_axis } else { opposite_axis(j.primary_axis) };

                let mut name = [0u8; 32];
                let s = if is_agonist { "agonist" } else { "antagonist" };
                let text = format!("{}_{}", j.name, s);
                let bytes = text.as_bytes();
                let len = bytes.len().min(31);
                name[..len].copy_from_slice(&bytes[..len]);

                tendons.push(Tendon {
                    joint: j.id,
                    name,
                    compression: 0.0,
                    compression_distance_m: 0.025,
                    pulley_radius_m: 0.01,
                    tension_n: 0.0,
                    torque_nm: 0.0,
                    direction: axis,
                    sign,
                    angular_momentum: 0.0,
                });
            }

            joints.push(PulleyJoint {
                def: j.id,
                current_angle: 0.0,
                angular_momentum: 0.0,
                angular_velocity: 0.0,
                target_angle: 0.0,
                min_angle: min_a,
                max_angle: max_a,
                tendons,
            });
        }
        Self { joints, total_compression: 0.0 }
    }

    /// Set a target for one joint. Returns false if the joint is unknown.
    pub fn articulate(&mut self, cmd: Articulation) -> bool {
        let Some(j) = self.joints.iter_mut().find(|j| j.def == cmd.joint) else {
            return false;
        };
        j.target_angle = cmd.target.clamp(j.min_angle, j.max_angle);
        true
    }

    /// Simulate one physics tick. Each tendon is pressurised proportionally to
    /// the angle error and the commanded effort. The compression-distance and
    /// pulley-radius convert that linear stroke into an angular change, and
    /// the resulting angular momentum is written back into the joint state.
    ///
    /// This is intentionally a *stub*: no tendon elastic damping, no hydraulic
    /// latency, no multi-body dynamics. It gives enough fidelity to demonstrate
    /// the control loop from the cervical bus to the joints.
    pub fn tick(&mut self, dt_s: f32) {
        let mut total_comp = 0.0;
        for j in self.joints.iter_mut() {
            let error = j.target_angle - j.current_angle;

            for t in j.tendons.iter_mut() {
                // Agonist fires if target > current and sign is positive,
                // or target < current and sign is negative.
                let wants = error.signum() == t.sign.signum() && error.abs() > 1e-4;
                let target_comp = if wants {
                    error.abs().min(t.compression_distance_m) / t.compression_distance_m
                } else {
                    0.0
                };

                // Filament compresses / relaxes with a simple first-order lag.
                t.compression += (target_comp - t.compression) * 10.0 * dt_s;
                t.compression = t.compression.clamp(0.0, 1.0);

                // Convert to torque.
                let stroke_m = t.compression * t.compression_distance_m;
                t.tension_n = if wants { 200.0 * t.compression } else { 0.0 };
                t.torque_nm = t.tension_n * t.pulley_radius_m * t.sign;
                t.angular_momentum = t.torque_nm * t.pulley_radius_m * dt_s;
                total_comp += stroke_m;
            }

            // Sum tendon torques into joint angular acceleration (stub inertia
            // of 0.5 kg·m²).
            let net_torque: f32 = j.tendons.iter().map(|t| t.torque_nm).sum();
            let inertia = 0.5;
            let alpha = net_torque / inertia;
            j.angular_velocity += alpha * dt_s;
            j.angular_velocity *= 0.95; // light damping
            j.current_angle += j.angular_velocity * dt_s;
            j.angular_momentum = inertia * j.angular_velocity;
            j.current_angle = j.current_angle.clamp(j.min_angle, j.max_angle);
        }
        self.total_compression = total_comp;
    }

    /// All tendons that act on a part (i.e. on joints whose distal part is this
    /// one).
    pub fn tendons_for_part(&self, part: PartId) -> impl Iterator<Item = &Tendon> {
        self.joints
            .iter()
            .filter(move |j| joint_by_id(j.def).map_or(false, |jd| jd.distal == part))
            .flat_map(|j| j.tendons.iter())
    }

    /// Flat motor state for the quantum bus. One scalar per tendon.
    pub fn flatten(&self) -> Vec<f32> {
        self.joints
            .iter()
            .flat_map(|j| j.tendons.iter().map(|t| t.compression))
            .collect()
    }
}

/// Default angle range in radians for a joint axis.
fn angle_range(axis: JointAxis) -> (f32, f32) {
    match axis {
        JointAxis::FlexionExtension => (-0.26, 2.27),       // -15° .. 130°
        JointAxis::AbductionAdduction => (-0.52, 0.79),     // -30° .. 45°
        JointAxis::InternalExternalRotation => (-1.57, 1.57),// -90° .. 90°
        JointAxis::ElevationDepression => (-0.52, 0.52),    // -30° .. 30°
        JointAxis::PronationSupination => (-1.57, 1.57),    // -90° .. 90°
    }
}

fn opposite_axis(axis: JointAxis) -> JointAxis {
    match axis {
        JointAxis::FlexionExtension => JointAxis::FlexionExtension,
        JointAxis::AbductionAdduction => JointAxis::AbductionAdduction,
        JointAxis::InternalExternalRotation => JointAxis::InternalExternalRotation,
        JointAxis::ElevationDepression => JointAxis::ElevationDepression,
        JointAxis::PronationSupination => JointAxis::PronationSupination,
    }
}
