// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//! Virtual humanoid physiology — dual circulatory system and cervical nervous
//! distribution.
//!
//! Two independent hydraulic loops:
//!   - **stator loop** : liquid nitrogen (LN2). Cools the stationary armature,
//!     superconducting magnetic bearings and the motor stator windings.
//!   - **rotor loop**    : oil. Lubricates and transmits power to the moving
//!     rotor shafts, joint pulleys and tendon hydraulic chambers.
//!
//! The loops open behind the neck through a **zipper-style ring-attach-switch
//! micro-tech cord replacement port** — a wearable docking ring whose mating
//! face is split like a zip fastener: align, press and the micro-cords latch in
//! sequence. To replace a cord, flip the switch, detach, insert the new cord,
//! zip the ring shut. This is a stub: the simulation just tracks port state.
//!
//! The **cervical-electrical-distribution** is the robot's nervous system: a
//! star bus rooted at the neck that fans out into region trunks. It feeds
//! captor data to the quantum AI and routes motor commands back to the body.

use crate::anatomy::{region_by_id, RegionDef, RegionId, REGIONS};

/// A hydraulic loop channel.
#[derive(Clone, Copy, Debug, Default)]
#[repr(C)]
pub struct FluidChannel {
    /// Fluid name, e.g. "LN2" or "synthetic-rotor-oil".
    pub fluid: [u8; 24],
    pub pressure_kpa: f32,
    pub flow_rate_lpm: f32,
    pub temperature_k: f32,
    pub loop_active: bool,
}

/// The dual-circulatory system.
#[derive(Clone, Copy, Debug)]
#[repr(C)]
pub struct CirculatorySystem {
    pub stator: FluidChannel, // liquid nitrogen
    pub rotor: FluidChannel,  // oil
    pub stator_volume_l: f32,
    pub rotor_volume_l: f32,
    pub purge_cycles: u32,
}

/// One ring attachment point behind the neck.
#[derive(Clone, Copy, Debug, Default)]
#[repr(C)]
pub struct CordPort {
    pub latched: bool,
    pub switch_open: bool,
    pub cord_idx: u8,
    pub name: [u8; 24],
}

/// The zip-ring service port behind the neck.
#[derive(Clone, Debug)]
#[repr(C)]
pub struct ZipperRing {
    pub ring_closed: bool,
    pub attached: bool,
    pub ports: [CordPort; 4],
}

/// A nerve trunk from the cervical star bus to one body region.
#[derive(Clone, Copy, Debug, Default)]
#[repr(C)]
pub struct NerveTrunk {
    pub region: RegionId,
    pub bandwidth_mbps: f32,
    pub latency_ms: f32,
    pub active: bool,
    pub signal_quality: f32,
}

/// The cervical-electrical nervous system. Physically this is a star-configured
/// bus behind the neck; logically it is the aggregation point that feeds the
/// qRAM / lreg intuition layer and receives motor actuation vectors from it.
#[derive(Clone, Debug)]
#[repr(C)]
pub struct CervicalBus {
    pub neck_open: bool,
    pub trunks: Vec<NerveTrunk>,
    /// Total captor bandwidth budget.
    pub captor_bandwidth_mbps: f32,
    /// Total motor bandwidth budget.
    pub motor_bandwidth_mbps: f32,
    /// Quantum AI handle this bus is bound to (0 = unbound).
    pub bound_ai: u64,
}

impl Default for CirculatorySystem {
    fn default() -> Self {
        Self::new()
    }
}

impl CirculatorySystem {
    pub fn new() -> Self {
        let mut stator_name = [0u8; 24];
        let mut rotor_name = [0u8; 24];
        stator_name[..3].copy_from_slice(b"LN2");
        rotor_name[..3].copy_from_slice(b"oil");
        Self {
            stator: FluidChannel {
                fluid: stator_name,
                pressure_kpa: 120.0,
                flow_rate_lpm: 4.0,
                temperature_k: 77.0,
                loop_active: true,
            },
            rotor: FluidChannel {
                fluid: rotor_name,
                pressure_kpa: 8000.0,
                flow_rate_lpm: 12.0,
                temperature_k: 320.0,
                loop_active: true,
            },
            stator_volume_l: 1.2,
            rotor_volume_l: 0.9,
            purge_cycles: 0,
        }
    }

    /// Tick the fluid loops. In a full model this would solve thermal exchange
    /// between the stator and rotor loops and the body parts. Here we just keep
    /// the pressures bounded and count purge cycles.
    pub fn tick(&mut self, _dt_s: f32) {
        // Stator maintains cryogenic temperature; rotor warms slightly and is
        // cooled by the stator heat exchanger (stub).
        self.rotor.temperature_k = (self.rotor.temperature_k + 0.01).min(340.0);
        self.stator.temperature_k = 77.0; // LN2 at 1 atm
        self.stator.pressure_kpa = 120.0;
        self.rotor.pressure_kpa = 8000.0;
    }

    /// Purge and refill one loop. Used after the zipper ring has been opened.
    pub fn purge(&mut self) {
        self.purge_cycles += 1;
        self.rotor.temperature_k = 310.0;
    }
}

impl Default for ZipperRing {
    fn default() -> Self {
        Self::new()
    }
}

impl ZipperRing {
    pub fn new() -> Self {
        let mut ports = [CordPort::default(); 4];
        let names: [&[u8]; 4] = [b"stator-in ", b"stator-out", b"rotor-in  ", b"rotor-out " ];
        for (i, name) in names.iter().enumerate() {
            ports[i].cord_idx = i as u8;
            ports[i].latched = true;
            ports[i].name[..name.len()].copy_from_slice(name);
        }
        Self {
            ring_closed: true,
            attached: true,
            ports,
        }
    }

    /// Open the service ring. Detaches all four micro-cords and stops the
    /// circulatory loops for the duration of the replacement.
    pub fn open(&mut self, circ: &mut CirculatorySystem) {
        self.ring_closed = false;
        self.attached = false;
        for p in self.ports.iter_mut() {
            p.latched = false;
            p.switch_open = true;
        }
        circ.stator.loop_active = false;
        circ.rotor.loop_active = false;
    }

    /// Replace a cord by index and re-zip the ring. The ring can close only
    /// after all four cords are re-seated.
    pub fn replace_cord(&mut self, idx: usize, circ: &mut CirculatorySystem) -> bool {
        if idx >= self.ports.len() {
            return false;
        }
        self.ports[idx].switch_open = false;
        self.ports[idx].latched = true;

        if self.ports.iter().all(|p| p.latched && !p.switch_open) {
            self.ring_closed = true;
            self.attached = true;
            circ.stator.loop_active = true;
            circ.rotor.loop_active = true;
            circ.purge();
        }
        true
    }

    /// True if the service port is closed and the robot can operate.
    pub fn sealed(&self) -> bool {
        self.ring_closed && self.attached && self.ports.iter().all(|p| p.latched)
    }
}

impl Default for CervicalBus {
    fn default() -> Self {
        Self::new()
    }
}

impl CervicalBus {
    pub fn new() -> Self {
        let mut trunks = Vec::new();
        for r in REGIONS.iter() {
            trunks.push(NerveTrunk {
                region: r.id,
                bandwidth_mbps: 10.0,
                latency_ms: 0.5,
                active: true,
                signal_quality: 1.0,
            });
        }
        Self {
            neck_open: false,
            trunks,
            captor_bandwidth_mbps: 1000.0,
            motor_bandwidth_mbps: 1000.0,
            bound_ai: 0,
        }
    }

    /// Feed one region's captor vector into the bus. Returns the index of the
    /// region's trunk.
    pub fn feed_captors(&mut self, region: RegionId, _vector: &[f32]) -> bool {
        if let Some(t) = self.trunks.iter_mut().find(|t| t.region == region) {
            t.active = true;
            t.signal_quality = 1.0;
            true
        } else {
            false
        }
    }

    /// Route a motor command vector back down a region trunk.
    pub fn route_motors(&mut self, region: RegionId, _commands: &[f32]) -> bool {
        if let Some(t) = self.trunks.iter_mut().find(|t| t.region == region) {
            t.active = true;
            true
        } else {
            false
        }
    }

    /// The total afferent (sensor) load currently on the bus.
    pub fn afferent_load(&self) -> f32 {
        self.trunks
            .iter()
            .filter(|t| t.active)
            .map(|t| t.bandwidth_mbps * t.signal_quality)
            .sum()
    }

    /// Region table for the current bus, for diagnostics.
    pub fn region_def(&self, id: RegionId) -> Option<&'static RegionDef> {
        region_by_id(id)
    }
}
