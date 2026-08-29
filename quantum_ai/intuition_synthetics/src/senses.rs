// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//! Virtual humanoid sensor suite.
//!
//! Three subsystems:
//!   - a movable stereo camera (two eyes with individual and combined focus);
//!   - a temperature sensor array laid over every body part;
//!   - a touch sensor array laid over the same parts.
//!
//! All captors are indexed by `PartId` from `anatomy.rs`. The camera is mounted
//! in the head, but its coordinate frame is separate because vision is not a
//! skin sensor.

use crate::anatomy::{part_by_id, CaptorKind, PartId, PARTS};
use crate::intuition::Vec3;

/// One eye of the stereo head.
#[derive(Clone, Copy, Debug, Default)]
#[repr(C)]
pub struct Eye {
    /// Focal length in millimetres.
    pub focal_mm: f32,
    /// Focus distance in metres (accommodation / vergence target).
    pub focus_m: f32,
    /// Aperture diameter in millimetres.
    pub aperture_mm: f32,
    /// Horizontal offset from the head centre, in metres (IPD/2 with sign).
    pub offset_m: f32,
    /// Current optical axis as a unit vector.
    pub gaze: Vec3,
}

/// Combined / movable 3D camera.
///
/// The head can pan, tilt and roll. Each eye can focus independently
/// (accommodation) and the two eyes can converge on a single point (vergence).
/// The *combination* focalization is the shared focus point; the *individual*
/// focalization is the per-eye lens tuning. This is a stub: the images are not
/// rendered; only the optical state and a coarse "feature vector" are produced.
#[derive(Clone, Debug)]
#[repr(C)]
pub struct StereoCamera {
    /// Left eye.
    pub left: Eye,
    /// Right eye.
    pub right: Eye,
    /// Head pan (yaw), tilt (pitch), roll, in radians.
    pub pan: f32,
    pub tilt: f32,
    pub roll: f32,
    /// Shared vergence point in head-local metres.
    pub vergence_point: Vec3,
    /// Coarse output: number of "detected features" binned by depth.
    pub feature_depth_bins: [f32; 8],
}

/// A single thermal pixel.
#[derive(Clone, Copy, Debug, Default)]
#[repr(C)]
pub struct ThermoCell {
    pub part: PartId,
    /// Local index on this part.
    pub local_idx: u8,
    pub kelvin: f32,
    /// Whether this cell has been freshly sampled this tick.
    pub fresh: bool,
}

/// A single touch / pressure / proximity cell.
#[derive(Clone, Copy, Debug, Default)]
#[repr(C)]
pub struct TouchCell {
    pub part: PartId,
    pub local_idx: u8,
    /// Normalised pressure, 0..1.
    pub pressure: f32,
    /// Proximity / hover, 0..1.
    pub proximity: f32,
    /// Shear / slip, 0..1.
    pub shear: f32,
    pub fresh: bool,
}

/// The full captor bank. This is the vector that would be passed to the
/// `encode_vector_classical` / `QRAM_LoadSuperposition` path after a quantum
/// preprocessing step.
#[derive(Clone, Debug)]
pub struct CaptorBank {
    pub camera: StereoCamera,
    pub thermo: Vec<ThermoCell>,
    pub touch: Vec<TouchCell>,
    /// Flattened output ready for encoding. Length = `thermo.len() + touch.len()
    /// + camera.feature_depth_bins.len()`.
    pub vector: Vec<f32>,
}

impl Default for CaptorBank {
    fn default() -> Self {
        Self::new()
    }
}

impl CaptorBank {
    pub fn new() -> Self {
        let mut thermo = Vec::new();
        let mut touch = Vec::new();
        for p in PARTS.iter() {
            for i in 0..p.n_thermo {
                thermo.push(ThermoCell {
                    part: p.id,
                    local_idx: i,
                    kelvin: 310.0,
                    fresh: false,
                });
            }
            for i in 0..p.n_touch {
                touch.push(TouchCell {
                    part: p.id,
                    local_idx: i,
                    pressure: 0.0,
                    proximity: 0.0,
                    shear: 0.0,
                    fresh: false,
                });
            }
        }
        Self {
            camera: StereoCamera::default(),
            thermo,
            touch,
            vector: Vec::new(),
        }
    }

    /// Total number of captor cells across all parts.
    pub fn n_cells(&self) -> usize {
        self.thermo.len() + self.touch.len() + self.camera.feature_depth_bins.len()
    }

    /// Recompute the flattened `vector`. Values are normalised so the vector
    /// can be fed straight to `encode_vector_classical`. This is a stub: real
    /// preprocessing would do retinotopic warping, thermal drift correction and
    /// shear de-aliasing before the qRAM load.
    pub fn flatten(&mut self) {
        self.vector.clear();
        for t in &self.thermo {
            self.vector.push((t.kelvin - 273.0) / 100.0);
        }
        for t in &self.touch {
            self.vector.push(t.pressure);
            self.vector.push(t.proximity);
            self.vector.push(t.shear);
        }
        for b in &self.camera.feature_depth_bins {
            self.vector.push(*b);
        }
    }

    /// Sample a single temperature cell.
    pub fn set_temperature(&mut self, part: PartId, local_idx: u8, kelvin: f32) {
        if let Some(c) = self.thermo.iter_mut().find(|c| c.part == part && c.local_idx == local_idx) {
            c.kelvin = kelvin;
            c.fresh = true;
        }
    }

    /// Sample a single touch cell.
    pub fn set_touch(&mut self, part: PartId, local_idx: u8, pressure: f32, proximity: f32, shear: f32) {
        if let Some(c) = self.touch.iter_mut().find(|c| c.part == part && c.local_idx == local_idx) {
            c.pressure = pressure.clamp(0.0, 1.0);
            c.proximity = proximity.clamp(0.0, 1.0);
            c.shear = shear.clamp(0.0, 1.0);
            c.fresh = true;
        }
    }

    /// Convenience: return all cells on a part.
    pub fn cells_on_part(&self, part: PartId) -> impl Iterator<Item = CaptorKind> + '_ {
        let n_thermo = part_by_id(part).map(|p| p.n_thermo as usize).unwrap_or(0);
        let n_touch = part_by_id(part).map(|p| p.n_touch as usize).unwrap_or(0);
        (0..n_thermo).map(move |_| CaptorKind::Temperature)
            .chain((0..n_touch).map(move |_| CaptorKind::Touch))
    }
}

impl StereoCamera {
    /// Default head: 50 mm focal length, 6.5 cm IPD, forward gaze.
    pub fn new() -> Self {
        let half_ipd = 0.0325;
        Self {
            left: Eye {
                focal_mm: 50.0,
                focus_m: 10.0,
                aperture_mm: 4.0,
                offset_m: -half_ipd,
                gaze: Vec3 { x: 0.0, y: 0.0, z: 1.0 },
            },
            right: Eye {
                focal_mm: 50.0,
                focus_m: 10.0,
                aperture_mm: 4.0,
                offset_m: half_ipd,
                gaze: Vec3 { x: 0.0, y: 0.0, z: 1.0 },
            },
            pan: 0.0,
            tilt: 0.0,
            roll: 0.0,
            vergence_point: Vec3 { x: 0.0, y: 0.0, z: 10.0 },
            feature_depth_bins: [0.0; 8],
        }
    }

    /// Point the head and converge both eyes on a world point. This is
    /// "combination focalization" (shared focus) plus individual lens tuning
    /// (each eye's `focus_m` is set to the distance of the vergence point).
    pub fn focalize(&mut self, world_point: Vec3) {
        self.vergence_point = world_point;

        // Head yaw / pitch so the vergence point sits in the cyclopean gaze.
        self.pan = world_point.x.atan2(world_point.z.max(1e-4));
        self.tilt = (-world_point.y).atan2(world_point.z.max(1e-4));

        // Distance from the head origin to the vergence point.
        let d = (world_point.x * world_point.x
            + world_point.y * world_point.y
            + world_point.z * world_point.z)
            .sqrt()
            .max(0.05);

        // Each eye's lens is tuned to that distance.
        self.left.focus_m = d;
        self.right.focus_m = d;

        // Vergence: each eye rotates slightly inward. The angle is arcsin(ipd/2d).
        let half_ipd = (self.right.offset_m - self.left.offset_m) / 2.0;
        let vergence = (half_ipd / d).min(1.0).asin();

        self.left.gaze = Vec3 {
            x: self.pan.sin() * self.tilt.cos() + vergence,
            y: -self.tilt.sin(),
            z: self.pan.cos() * self.tilt.cos(),
        };
        self.right.gaze = Vec3 {
            x: self.pan.sin() * self.tilt.cos() - vergence,
            y: -self.tilt.sin(),
            z: self.pan.cos() * self.tilt.cos(),
        };

        // Stub feature map: more bins populated for nearby points.
        for (i, b) in self.feature_depth_bins.iter_mut().enumerate() {
            let bin_far = (i + 1) as f32 * 2.5;
            let bin_near = i as f32 * 2.5;
            *b = if d >= bin_near && d < bin_far { 1.0 } else { 0.0 };
        }
    }

    /// Move the head in world space and track a moving target.
    pub fn track(&mut self, target: Vec3) {
        self.focalize(target);
    }
}

impl Default for StereoCamera {
    fn default() -> Self {
        Self::new()
    }
}
