// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//! Virtual humanoid anatomy — the canonical body map.
//!
//! Every sensor, motor and circulatory channel is anchored to a part and to a
//! region. This file is the shared reference frame; it contains the lookup
//! tables the rest of the embodiment code indexes.
//!
//! Naming convention: a *part* is a mechanical segment (e.g. `LeftLowerArm`), a
//! *region* is a functional zone (e.g. `Cervical`, `Thoracic`), and a *joint* is
//! an articulation with one or more degrees of freedom. The tables are
//! `const` slices so an agent can iterate them without constructing an instance.

use crate::QrcError;

/// Strongly-typed part index. 255 parts is enough for a humanoid; `u16` leaves
/// room for sub-segment expansion without changing the ABI.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[repr(transparent)]
pub struct PartId(pub u16);

/// Region index — functional zone of the body.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[repr(transparent)]
pub struct RegionId(pub u8);

/// Joint index — the moving connection between two parts.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[repr(transparent)]
pub struct JointId(pub u16);

/// Captor/sensor type. A part may carry several kinds at once.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(C)]
pub enum CaptorKind {
    /// Temperature pixel / thermopile.
    Temperature = 0,
    /// Pressure / capacitive touch.
    Touch = 1,
    /// Camera / visual feature cell.
    Vision = 2,
    /// Proprioceptive angle / strain.
    Proprioception = 3,
    /// Slip / shear.
    Shear = 4,
}

/// Motor type. The current platform uses one underlying hydraulic-tendon
/// primitive everywhere, but the type records the intended actuation regime.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(C)]
pub enum MotorKind {
    /// Rotational joint around a pivot (most limbs).
    Rotary = 0,
    /// Linear extension / contraction (spine, fingers, jaw).
    Linear = 1,
    /// Twisting / pronation-supination.
    Torsional = 2,
    /// Sphincter-like gripping (hands, eyelids).
    Grip = 3,
}

/// Describes a single body part.
#[derive(Clone, Copy, Debug)]
pub struct PartDef {
    pub id: PartId,
    pub name: &'static str,
    pub region: RegionId,
    /// Primary mechanical role.
    pub purpose: &'static str,
    /// Default number of thermal + touch captors on this part.
    pub n_thermo: u8,
    pub n_touch: u8,
    /// Default number of motors / tendons.
    pub n_motors: u8,
}

/// Describes a functional region.
#[derive(Clone, Copy, Debug)]
pub struct RegionDef {
    pub id: RegionId,
    pub name: &'static str,
    /// Cryo / oil / electrical naming used in physiology.rs.
    pub circulatory_label: &'static str,
    /// Nerve trunk that serves this region from the cervical bus.
    pub nerve_trunk: &'static str,
}

/// Direction of positive joint motion.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
#[repr(C)]
pub enum JointAxis {
    /// Forward/backward in the sagittal plane.
    #[default]
    FlexionExtension,
    /// Left/right in the coronal plane.
    AbductionAdduction,
    /// Rotation around the long axis of the limb.
    InternalExternalRotation,
    /// Up/down (for head, ankles, wrists).
    ElevationDepression,
    /// Pronation / supination.
    PronationSupination,
}

/// Describes a joint / articulation and its purpose.
#[derive(Clone, Copy, Debug)]
pub struct JointDef {
    pub id: JointId,
    pub name: &'static str,
    pub proximal: PartId,
    pub distal: PartId,
    pub primary_axis: JointAxis,
    pub secondary_axis: Option<JointAxis>,
    /// e.g. "elbow flexion, 0..150°".
    pub purpose: &'static str,
    /// Default motor count on this joint (1 for hinge, 2+ for ball).
    pub n_motors: u8,
    /// Degrees of freedom (1..3).
    pub dof: u8,
}

// --------------------------------------------------------------------------
// Region table.
// --------------------------------------------------------------------------

/// Functional zones of the humanoid.
pub const REGIONS: &[RegionDef] = &[
    RegionDef { id: RegionId(0),  name: "Cranial",        circulatory_label: "cranial-ln2", nerve_trunk: "trigeminal-v" },
    RegionDef { id: RegionId(1),  name: "Cervical",       circulatory_label: "cervical-ln2", nerve_trunk: "cervical-plexus" },
    RegionDef { id: RegionId(2),  name: "Thoracic",       circulatory_label: "thoracic-oil", nerve_trunk: "thoracic-nerve" },
    RegionDef { id: RegionId(3),  name: "Lumbar",         circulatory_label: "lumbar-oil",   nerve_trunk: "lumbar-plexus" },
    RegionDef { id: RegionId(4),  name: "Pelvic",         circulatory_label: "pelvic-oil",   nerve_trunk: "sacral-plexus" },
    RegionDef { id: RegionId(5),  name: "LeftUpper",      circulatory_label: "left-ln2",     nerve_trunk: "left-brachial" },
    RegionDef { id: RegionId(6),  name: "RightUpper",     circulatory_label: "right-ln2",    nerve_trunk: "right-brachial" },
    RegionDef { id: RegionId(7),  name: "LeftLower",      circulatory_label: "left-oil",     nerve_trunk: "left-lumbar-sacral" },
    RegionDef { id: RegionId(8),  name: "RightLower",     circulatory_label: "right-oil",    nerve_trunk: "right-lumbar-sacral" },
    RegionDef { id: RegionId(9),  name: "Manus",          circulatory_label: "manus-ln2",    nerve_trunk: "median-nerve" },
    RegionDef { id: RegionId(10), name: "Pes",            circulatory_label: "pes-oil",      nerve_trunk: "tibial-nerve" },
];

// --------------------------------------------------------------------------
// Part table.
//
// Numbering is grouped by region so an iterator can quickly find all parts in
// a region by range check, but the public API is through `region_of`.
// --------------------------------------------------------------------------

pub const PART_HEAD: PartId            = PartId(0);
pub const PART_NECK: PartId            = PartId(1);
pub const PART_TORSO: PartId           = PartId(2);
pub const PART_PELVIS: PartId          = PartId(3);
pub const PART_LEFT_SHOULDER: PartId   = PartId(10);
pub const PART_LEFT_UPPER_ARM: PartId  = PartId(11);
pub const PART_LEFT_LOWER_ARM: PartId  = PartId(12);
pub const PART_LEFT_HAND: PartId       = PartId(13);
pub const PART_RIGHT_SHOULDER: PartId  = PartId(20);
pub const PART_RIGHT_UPPER_ARM: PartId = PartId(21);
pub const PART_RIGHT_LOWER_ARM: PartId = PartId(22);
pub const PART_RIGHT_HAND: PartId      = PartId(23);
pub const PART_LEFT_HIP: PartId        = PartId(30);
pub const PART_LEFT_THIGH: PartId      = PartId(31);
pub const PART_LEFT_SHANK: PartId      = PartId(32);
pub const PART_LEFT_FOOT: PartId       = PartId(33);
pub const PART_RIGHT_HIP: PartId       = PartId(40);
pub const PART_RIGHT_THIGH: PartId     = PartId(41);
pub const PART_RIGHT_SHANK: PartId     = PartId(42);
pub const PART_RIGHT_FOOT: PartId      = PartId(43);

/// Canonical part table. Each row is a body segment with its default sensor
/// and motor complement. The counts are *stubs* — they set the array size and
/// the wire budget, not a final hardware spec.
pub const PARTS: &[PartDef] = &[
    PartDef { id: PART_HEAD,            name: "head",            region: RegionId(0),  purpose: "stereo vision, auditory, thermal intake", n_thermo: 8, n_touch: 0,  n_motors: 6 },
    PartDef { id: PART_NECK,            name: "neck",            region: RegionId(1),  purpose: "cervical distribution, gaze pointing",    n_thermo: 4, n_touch: 4,  n_motors: 6 },
    PartDef { id: PART_TORSO,           name: "torso",           region: RegionId(2),  purpose: "core structure, power reservoirs",          n_thermo: 12, n_touch: 8, n_motors: 4 },
    PartDef { id: PART_PELVIS,          name: "pelvis",          region: RegionId(4),  purpose: "load transfer, balance anchor",             n_thermo: 4, n_touch: 4,  n_motors: 0 },
    PartDef { id: PART_LEFT_SHOULDER,   name: "left_shoulder",   region: RegionId(5),  purpose: "arm root, abduction/adduction",             n_thermo: 2, n_touch: 2,  n_motors: 4 },
    PartDef { id: PART_LEFT_UPPER_ARM,  name: "left_upper_arm",  region: RegionId(5),  purpose: "humeral housing, rotation",                 n_thermo: 4, n_touch: 4,  n_motors: 0 },
    PartDef { id: PART_LEFT_LOWER_ARM,  name: "left_lower_arm",  region: RegionId(5),  purpose: "forearm, pronation/supination",             n_thermo: 4, n_touch: 6,  n_motors: 2 },
    PartDef { id: PART_LEFT_HAND,       name: "left_hand",       region: RegionId(9),  purpose: "grip and manipulation",                     n_thermo: 5, n_touch: 16, n_motors: 4 },
    PartDef { id: PART_RIGHT_SHOULDER,  name: "right_shoulder",  region: RegionId(6),  purpose: "arm root, abduction/adduction",             n_thermo: 2, n_touch: 2,  n_motors: 4 },
    PartDef { id: PART_RIGHT_UPPER_ARM, name: "right_upper_arm", region: RegionId(6),  purpose: "humeral housing, rotation",                 n_thermo: 4, n_touch: 4,  n_motors: 0 },
    PartDef { id: PART_RIGHT_LOWER_ARM, name: "right_lower_arm", region: RegionId(6),  purpose: "forearm, pronation/supination",             n_thermo: 4, n_touch: 6,  n_motors: 2 },
    PartDef { id: PART_RIGHT_HAND,      name: "right_hand",      region: RegionId(9),  purpose: "grip and manipulation",                     n_thermo: 5, n_touch: 16, n_motors: 4 },
    PartDef { id: PART_LEFT_HIP,        name: "left_hip",        region: RegionId(7),  purpose: "leg root, flexion/extension",               n_thermo: 2, n_touch: 2,  n_motors: 4 },
    PartDef { id: PART_LEFT_THIGH,      name: "left_thigh",      region: RegionId(7),  purpose: "femoral housing, load",                     n_thermo: 6, n_touch: 4,  n_motors: 0 },
    PartDef { id: PART_LEFT_SHANK,      name: "left_shank",      region: RegionId(7),  purpose: "tibial/fibular housing",                    n_thermo: 4, n_touch: 4,  n_motors: 2 },
    PartDef { id: PART_LEFT_FOOT,       name: "left_foot",       region: RegionId(10), purpose: "balance, contact, propulsion",              n_thermo: 4, n_touch: 12, n_motors: 3 },
    PartDef { id: PART_RIGHT_HIP,       name: "right_hip",       region: RegionId(8),  purpose: "leg root, flexion/extension",               n_thermo: 2, n_touch: 2,  n_motors: 4 },
    PartDef { id: PART_RIGHT_THIGH,     name: "right_thigh",     region: RegionId(8),  purpose: "femoral housing, load",                     n_thermo: 6, n_touch: 4,  n_motors: 0 },
    PartDef { id: PART_RIGHT_SHANK,     name: "right_shank",     region: RegionId(8),  purpose: "tibial/fibular housing",                    n_thermo: 4, n_touch: 4,  n_motors: 2 },
    PartDef { id: PART_RIGHT_FOOT,      name: "right_foot",      region: RegionId(10), purpose: "balance, contact, propulsion",              n_thermo: 4, n_touch: 12, n_motors: 3 },
];

// --------------------------------------------------------------------------
// Joint table.
// --------------------------------------------------------------------------

pub const JOINT_HEAD_PITCH: JointId       = JointId(0);
pub const JOINT_HEAD_YAW: JointId         = JointId(1);
pub const JOINT_HEAD_ROLL: JointId        = JointId(2);
pub const JOINT_NECK_TILT: JointId        = JointId(10);
pub const JOINT_NECK_ROLL: JointId        = JointId(11);
pub const JOINT_SPINE_LUMBAR: JointId     = JointId(12);
pub const JOINT_LEFT_SHOULDER_ABD: JointId = JointId(20);
pub const JOINT_LEFT_SHOULDER_FLEX: JointId = JointId(21);
pub const JOINT_LEFT_ELBOW: JointId       = JointId(22);
pub const JOINT_LEFT_WRIST_FLEX: JointId  = JointId(23);
pub const JOINT_LEFT_WRIST_DEV: JointId   = JointId(24);
pub const JOINT_RIGHT_SHOULDER_ABD: JointId = JointId(30);
pub const JOINT_RIGHT_SHOULDER_FLEX: JointId = JointId(31);
pub const JOINT_RIGHT_ELBOW: JointId      = JointId(32);
pub const JOINT_RIGHT_WRIST_FLEX: JointId = JointId(33);
pub const JOINT_RIGHT_WRIST_DEV: JointId  = JointId(34);
pub const JOINT_LEFT_HIP_FLEX: JointId    = JointId(40);
pub const JOINT_LEFT_HIP_ABD: JointId     = JointId(41);
pub const JOINT_LEFT_KNEE: JointId        = JointId(42);
pub const JOINT_LEFT_ANKLE: JointId       = JointId(43);
pub const JOINT_RIGHT_HIP_FLEX: JointId   = JointId(50);
pub const JOINT_RIGHT_HIP_ABD: JointId    = JointId(51);
pub const JOINT_RIGHT_KNEE: JointId       = JointId(52);
pub const JOINT_RIGHT_ANKLE: JointId      = JointId(53);

pub const JOINTS: &[JointDef] = &[
    JointDef { id: JOINT_HEAD_PITCH,    name: "head_pitch",       proximal: PART_NECK,            distal: PART_HEAD,            primary_axis: JointAxis::FlexionExtension,      secondary_axis: None, purpose: "gaze up/down", n_motors: 2, dof: 1 },
    JointDef { id: JOINT_HEAD_YAW,      name: "head_yaw",         proximal: PART_NECK,            distal: PART_HEAD,            primary_axis: JointAxis::InternalExternalRotation, secondary_axis: None, purpose: "gaze left/right", n_motors: 2, dof: 1 },
    JointDef { id: JOINT_HEAD_ROLL,     name: "head_roll",        proximal: PART_NECK,            distal: PART_HEAD,            primary_axis: JointAxis::PronationSupination,   secondary_axis: None, purpose: "head roll", n_motors: 2, dof: 1 },
    JointDef { id: JOINT_NECK_TILT,     name: "neck_tilt",        proximal: PART_TORSO,           distal: PART_NECK,            primary_axis: JointAxis::FlexionExtension,      secondary_axis: Some(JointAxis::AbductionAdduction), purpose: "neck bend & side-bend", n_motors: 4, dof: 2 },
    JointDef { id: JOINT_NECK_ROLL,     name: "neck_roll",        proximal: PART_TORSO,           distal: PART_NECK,            primary_axis: JointAxis::InternalExternalRotation, secondary_axis: None, purpose: "head roll", n_motors: 2, dof: 1 },
    JointDef { id: JOINT_SPINE_LUMBAR,  name: "spine_lumbar",     proximal: PART_PELVIS,          distal: PART_TORSO,            primary_axis: JointAxis::FlexionExtension,      secondary_axis: Some(JointAxis::AbductionAdduction), purpose: "trunk lean & twist", n_motors: 4, dof: 2 },
    JointDef { id: JOINT_LEFT_SHOULDER_ABD,  name: "left_shoulder_abd",  proximal: PART_TORSO,  distal: PART_LEFT_SHOULDER,  primary_axis: JointAxis::AbductionAdduction,     secondary_axis: None, purpose: "arm raise to side", n_motors: 2, dof: 1 },
    JointDef { id: JOINT_LEFT_SHOULDER_FLEX, name: "left_shoulder_flex", proximal: PART_TORSO,  distal: PART_LEFT_SHOULDER,  primary_axis: JointAxis::FlexionExtension,      secondary_axis: None, purpose: "arm swing forward/back", n_motors: 2, dof: 1 },
    JointDef { id: JOINT_LEFT_ELBOW,    name: "left_elbow",       proximal: PART_LEFT_UPPER_ARM,  distal: PART_LEFT_LOWER_ARM,  primary_axis: JointAxis::FlexionExtension,      secondary_axis: None, purpose: "elbow flexion", n_motors: 2, dof: 1 },
    JointDef { id: JOINT_LEFT_WRIST_FLEX, name: "left_wrist_flex", proximal: PART_LEFT_LOWER_ARM, distal: PART_LEFT_HAND,      primary_axis: JointAxis::FlexionExtension,      secondary_axis: None, purpose: "wrist up/down", n_motors: 2, dof: 1 },
    JointDef { id: JOINT_LEFT_WRIST_DEV,  name: "left_wrist_dev",  proximal: PART_LEFT_LOWER_ARM, distal: PART_LEFT_HAND,      primary_axis: JointAxis::AbductionAdduction,     secondary_axis: None, purpose: "wrist side-bend", n_motors: 2, dof: 1 },
    JointDef { id: JOINT_RIGHT_SHOULDER_ABD,  name: "right_shoulder_abd",  proximal: PART_TORSO, distal: PART_RIGHT_SHOULDER, primary_axis: JointAxis::AbductionAdduction,     secondary_axis: None, purpose: "arm raise to side", n_motors: 2, dof: 1 },
    JointDef { id: JOINT_RIGHT_SHOULDER_FLEX, name: "right_shoulder_flex", proximal: PART_TORSO, distal: PART_RIGHT_SHOULDER, primary_axis: JointAxis::FlexionExtension,      secondary_axis: None, purpose: "arm swing forward/back", n_motors: 2, dof: 1 },
    JointDef { id: JOINT_RIGHT_ELBOW,   name: "right_elbow",      proximal: PART_RIGHT_UPPER_ARM, distal: PART_RIGHT_LOWER_ARM, primary_axis: JointAxis::FlexionExtension,      secondary_axis: None, purpose: "elbow flexion", n_motors: 2, dof: 1 },
    JointDef { id: JOINT_RIGHT_WRIST_FLEX, name: "right_wrist_flex", proximal: PART_RIGHT_LOWER_ARM, distal: PART_RIGHT_HAND, primary_axis: JointAxis::FlexionExtension,      secondary_axis: None, purpose: "wrist up/down", n_motors: 2, dof: 1 },
    JointDef { id: JOINT_RIGHT_WRIST_DEV,  name: "right_wrist_dev",  proximal: PART_RIGHT_LOWER_ARM, distal: PART_RIGHT_HAND,  primary_axis: JointAxis::AbductionAdduction,     secondary_axis: None, purpose: "wrist side-bend", n_motors: 2, dof: 1 },
    JointDef { id: JOINT_LEFT_HIP_FLEX, name: "left_hip_flex",    proximal: PART_PELVIS,          distal: PART_LEFT_HIP,       primary_axis: JointAxis::FlexionExtension,      secondary_axis: None, purpose: "leg swing forward/back", n_motors: 2, dof: 1 },
    JointDef { id: JOINT_LEFT_HIP_ABD,  name: "left_hip_abd",     proximal: PART_PELVIS,          distal: PART_LEFT_HIP,       primary_axis: JointAxis::AbductionAdduction,     secondary_axis: None, purpose: "leg raise to side", n_motors: 2, dof: 1 },
    JointDef { id: JOINT_LEFT_KNEE,     name: "left_knee",        proximal: PART_LEFT_THIGH,      distal: PART_LEFT_SHANK,     primary_axis: JointAxis::FlexionExtension,      secondary_axis: None, purpose: "knee flexion", n_motors: 2, dof: 1 },
    JointDef { id: JOINT_LEFT_ANKLE,    name: "left_ankle",       proximal: PART_LEFT_SHANK,      distal: PART_LEFT_FOOT,      primary_axis: JointAxis::FlexionExtension,      secondary_axis: Some(JointAxis::AbductionAdduction), purpose: "ankle plantar/dorsiflex + inversion", n_motors: 3, dof: 2 },
    JointDef { id: JOINT_RIGHT_HIP_FLEX, name: "right_hip_flex",  proximal: PART_PELVIS,          distal: PART_RIGHT_HIP,      primary_axis: JointAxis::FlexionExtension,      secondary_axis: None, purpose: "leg swing forward/back", n_motors: 2, dof: 1 },
    JointDef { id: JOINT_RIGHT_HIP_ABD,  name: "right_hip_abd",   proximal: PART_PELVIS,          distal: PART_RIGHT_HIP,      primary_axis: JointAxis::AbductionAdduction,     secondary_axis: None, purpose: "leg raise to side", n_motors: 2, dof: 1 },
    JointDef { id: JOINT_RIGHT_KNEE,    name: "right_knee",       proximal: PART_RIGHT_THIGH,     distal: PART_RIGHT_SHANK,    primary_axis: JointAxis::FlexionExtension,      secondary_axis: None, purpose: "knee flexion", n_motors: 2, dof: 1 },
    JointDef { id: JOINT_RIGHT_ANKLE,   name: "right_ankle",      proximal: PART_RIGHT_SHANK,     distal: PART_RIGHT_FOOT,     primary_axis: JointAxis::FlexionExtension,      secondary_axis: Some(JointAxis::AbductionAdduction), purpose: "ankle plantar/dorsiflex + inversion", n_motors: 3, dof: 2 },
];

// --------------------------------------------------------------------------
// Helpers.
// --------------------------------------------------------------------------

/// Look up a part definition by id.
pub fn part_by_id(id: PartId) -> Option<&'static PartDef> {
    PARTS.iter().find(|p| p.id == id)
}

/// Look up a region definition by id.
pub fn region_by_id(id: RegionId) -> Option<&'static RegionDef> {
    REGIONS.iter().find(|r| r.id == id)
}

/// Look up a joint definition by id.
pub fn joint_by_id(id: JointId) -> Option<&'static JointDef> {
    JOINTS.iter().find(|j| j.id == id)
}

/// All parts belonging to a region.
pub fn parts_in_region(region: RegionId) -> impl Iterator<Item = &'static PartDef> {
    PARTS.iter().filter(move |p| p.region == region)
}

/// All joints whose distal part is `part`.
pub fn joints_for_part(part: PartId) -> impl Iterator<Item = &'static JointDef> {
    JOINTS.iter().filter(move |j| j.distal == part)
}

/// Total sensor count across all parts.
pub const fn total_captors() -> usize {
    let mut n = 0;
    let mut i = 0;
    while i < PARTS.len() {
        n += PARTS[i].n_thermo as usize + PARTS[i].n_touch as usize;
        i += 1;
    }
    n
}

/// Total motor count across all parts.
pub const fn total_motors() -> usize {
    let mut n = 0;
    let mut i = 0;
    while i < PARTS.len() {
        n += PARTS[i].n_motors as usize;
        i += 1;
    }
    n
}

/// Validate that all table ids are unique and non-null. Called by tests and on
/// first humanoid construction.
pub fn validate_tables() -> Result<(), QrcError> {
    // Region ids are unique and contiguous-ish.
    for (i, r) in REGIONS.iter().enumerate() {
        if r.id.0 as usize != i {
            return Err(QrcError::Oob);
        }
    }
    // Part ids are unique.
    for (i, p) in PARTS.iter().enumerate() {
        for q in PARTS.iter().take(i) {
            if q.id == p.id {
                return Err(QrcError::Oob);
            }
        }
    }
    // Joint ids are unique.
    for (i, j) in JOINTS.iter().enumerate() {
        for k in JOINTS.iter().take(i) {
            if k.id == j.id {
                return Err(QrcError::Oob);
            }
        }
        // Joints must connect existing parts.
        if part_by_id(j.proximal).is_none() || part_by_id(j.distal).is_none() {
            return Err(QrcError::Oob);
        }
    }
    Ok(())
}
