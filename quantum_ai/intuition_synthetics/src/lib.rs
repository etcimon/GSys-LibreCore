// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//! Simulated Quantum-Reversible C runtime + environmental intuition.
//!
//! This crate exports a stable C ABI (`qrc_full.h`, `qrc_env.h`, `qrc_humanoid.h`).
//! Hardware is stubbed: registers hold classical amplitudes; qRAM is
//! a Vec. The *shape* of the API is the product — superposition query
//! over a pre-loaded world, late measurement into DRAM-shaped buffers.

pub mod anatomy;
mod cycle;
mod ffi;
pub mod humanoid;
mod intuition;
pub mod motors;
pub mod physiology;
mod qram;
pub mod senses;

#[cfg(test)]
mod tests;

pub use anatomy::{JointAxis, JointDef, JointId, PartDef, PartId, RegionDef, RegionId, PARTS, REGIONS, JOINTS};
pub use humanoid::{head_camera, standing_humanoid, Humanoid};
pub use intuition::{EnvWorld, Hit, Keyframe, PlanHint, Pose, Vec3};
pub use motors::{Articulation, MotorBank, PulleyJoint, Tendon};
pub use physiology::{CervicalBus, CirculatorySystem, ZipperRing};
pub use senses::{CaptorBank, StereoCamera, ThermoCell, TouchCell};

/// Crate-level error used only on the Rust side.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QrcError {
    Null,
    Oob,
    Empty,
}
