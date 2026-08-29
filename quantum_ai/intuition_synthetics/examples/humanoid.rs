// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//! Minimal humanoid tick example.
//!
//! Build: cargo run --example humanoid
//!
//! The robot stands, looks at a point in space, commands the left elbow to
//! flex, ticks its physiology / sensors / cervical bus / motors for one second,
//! and prints the final captor and motor vector dimensions.

use qrc_env::anatomy::{JOINT_LEFT_ELBOW, PART_LEFT_LOWER_ARM};
use qrc_env::humanoid::standing_humanoid;
use qrc_env::motors::Articulation;
use qrc_env::{EnvWorld, Keyframe, Pose, Vec3};

fn main() {
    let mut h = standing_humanoid();

    // Pre-load a simple environment (rule 1: load once).
    let mut world = EnvWorld::new(64);
    world.load(
        0,
        Keyframe {
            pose: Pose {
                position: Vec3 { x: 0.0, y: 0.0, z: 0.0 },
                yaw: 0.0,
            },
            occupancy: 0.0,
            slip_risk: 0.0,
            affordance: 0.9,
            flags: 0,
        },
    );

    // Gaze + vergence.
    h.look_at(Vec3 { x: 1.0, y: 0.0, z: 5.0 });

    // Flex the left elbow.
    let mut cmd = Articulation::default();
    cmd.joint = JOINT_LEFT_ELBOW;
    cmd.target = 1.2;
    cmd.effort = 0.8;
    h.articulate(cmd);

    // Tick with the bound world (rule 2: sparse measurement only).
    let dt = 0.01;
    for _ in 0..100 {
        h.tick(dt, Some(&world));
    }

    println!("humanoid ticked {} times", h.tick_count);
    println!("sensor frame dimension: {}", h.captors.n_cells());
    println!("motor frame dimension:  {}", h.motors.flatten().len());

    // Read a captor and a motor.
    let temp = h.captor_scalar(PART_LEFT_LOWER_ARM, 0);
    let elbow = h
        .motors
        .joints
        .iter()
        .find(|j| j.def == JOINT_LEFT_ELBOW)
        .unwrap();
    println!("left lower arm temp (normalised): {:.3}", temp);
    println!("left elbow angle: {:.3} rad", elbow.current_angle);

    // Check circulatory state.
    println!(
        "rotor oil: {:.0} kPa, {:.1} K, {:.1} L/min",
        h.circulation.rotor.pressure_kpa,
        h.circulation.rotor.temperature_k,
        h.circulation.rotor.flow_rate_lpm
    );
    println!("zipper sealed: {}", h.zipper.sealed());
}
