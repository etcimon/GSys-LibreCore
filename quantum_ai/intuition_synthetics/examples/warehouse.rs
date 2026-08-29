// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//! Load a warehouse floor into the palace, then glance.

use qrc_env::{EnvWorld, Keyframe, Pose, Vec3};

fn kf(x: f32, y: f32, occ: f32, slip: f32, aff: f32) -> Keyframe {
    Keyframe {
        pose: Pose {
            position: Vec3 { x, y, z: 0.0 },
            yaw: 0.0,
        },
        occupancy: occ,
        slip_risk: slip,
        affordance: aff,
        flags: 0,
    }
}

fn main() {
    let mut world = EnvWorld::new(4096);
    // aisle
    for i in 0..40 {
        let _ = world.load(i, kf(i as f32 * 0.5, 0.0, 0.1, 0.05, 0.8));
    }
    // wet patch that ate a foot last Tuesday
    let _ = world.load(100, kf(7.0, 0.2, 0.3, 0.95, 0.1));
    // good footholds along the wall
    for i in 0..10 {
        let _ = world.load(200 + i, kf(5.0, i as f32, 0.0, 0.02, 0.95));
    }

    let here = Pose {
        position: Vec3 {
            x: 6.8,
            y: 0.1,
            z: 0.0,
        },
        yaw: 0.0,
    };

    let hits = world.query(&here, 5);
    println!("glance: {} hits", hits.len());
    for h in &hits {
        println!(
            "  slot {} score {:.3} slip {:.2} aff {:.2} @ ({:.1},{:.1})",
            h.slot, h.score, h.frame.slip_risk, h.frame.affordance, h.frame.pose.position.x, h.frame.pose.position.y
        );
    }

    let hint = world.plan_hint(&here);
    println!(
        "hint foothold=({:.2},{:.2}) avoid=({:.2},{:.2}) conf={:.3} used={}",
        hint.next_foothold.x,
        hint.next_foothold.y,
        hint.avoid.x,
        hint.avoid.y,
        hint.confidence,
        hint.n_hits_used
    );

    world.remember_failure(&here, 0.6);
    println!("palace size after scar: {}", world.len());
}
