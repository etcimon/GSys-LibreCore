// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
#[cfg(test)]
mod tests {
    use crate::anatomy::{validate_tables, PARTS, REGIONS, JOINTS};
    use crate::humanoid::standing_humanoid;
    use crate::intuition::{EnvWorld, Keyframe, Pose, Vec3};
    use crate::motors::{Articulation, MotorBank};
    use crate::physiology::{CirculatorySystem, ZipperRing};
    use crate::senses::CaptorBank;

    #[test]
    fn wet_patch_is_avoided() {
        let mut w = EnvWorld::new(64);
        w.load(
            0,
            Keyframe {
                pose: Pose {
                    position: Vec3 {
                        x: 0.0,
                        y: 0.0,
                        z: 0.0,
                    },
                    yaw: 0.0,
                },
                occupancy: 0.0,
                slip_risk: 0.0,
                affordance: 0.9,
                flags: 0,
            },
        );
        w.load(
            1,
            Keyframe {
                pose: Pose {
                    position: Vec3 {
                        x: 0.2,
                        y: 0.0,
                        z: 0.0,
                    },
                    yaw: 0.0,
                },
                occupancy: 0.2,
                slip_risk: 0.99,
                affordance: 0.1,
                flags: 1,
            },
        );
        let here = Pose {
            position: Vec3 {
                x: 0.1,
                y: 0.0,
                z: 0.0,
            },
            yaw: 0.0,
        };
        let hint = w.plan_hint(&here);
        assert!(hint.n_hits_used >= 1);
        assert!(hint.avoid.x > 0.0 || hint.next_foothold.x < 0.15);
    }

    #[test]
    fn anatomy_tables_are_consistent() {
        assert!(validate_tables().is_ok());
        assert_eq!(REGIONS.len(), 11);
        assert_eq!(PARTS.len(), 20);
        assert_eq!(JOINTS.len(), 24);
    }

    #[test]
    fn captor_bank_counts_match_anatomy() {
        let bank = CaptorBank::new();
        let expected_thermo: usize = PARTS.iter().map(|p| p.n_thermo as usize).sum();
        let expected_touch: usize = PARTS.iter().map(|p| p.n_touch as usize).sum();
        assert_eq!(bank.thermo.len(), expected_thermo);
        assert_eq!(bank.touch.len(), expected_touch);
        assert_eq!(bank.n_cells(), expected_thermo + expected_touch + 8);
    }

    #[test]
    fn motor_bank_counts_match_anatomy() {
        let bank = MotorBank::new();
        let expected_motors: usize = PARTS.iter().map(|p| p.n_motors as usize).sum();
        let actual: usize = bank.joints.iter().map(|j| j.tendons.len()).sum();
        assert_eq!(actual, expected_motors);
    }

    #[test]
    fn stereo_camera_converges() {
        let mut h = standing_humanoid();
        h.look_at(Vec3 { x: 1.0, y: 0.0, z: 1.0 });
        assert!(h.captors.camera.left.focus_m > 1.0);
        assert!(h.captors.camera.right.focus_m > 1.0);
        assert!((h.captors.camera.pan - 0.78).abs() < 0.1);
    }

    #[test]
    fn zipper_ring_blocks_motion() {
        let mut h = standing_humanoid();
        assert!(h.zipper.sealed());
        h.zipper.open(&mut h.circulation);
        assert!(!h.zipper.sealed());
        // With the neck port open, the tick should return early and the camera
        // should not change its vergence point.
        let old_vergence = h.captors.camera.vergence_point;
        h.tick(0.01, None);
        assert_eq!(h.captors.camera.vergence_point.x, old_vergence.x);
        assert_eq!(h.captors.camera.vergence_point.y, old_vergence.y);
        assert_eq!(h.captors.camera.vergence_point.z, old_vergence.z);
    }

    #[test]
    fn cord_replacement_closes_ring() {
        let mut circ = CirculatorySystem::new();
        let mut ring = ZipperRing::new();
        ring.open(&mut circ);
        assert!(!ring.sealed());
        for i in 0..4 {
            assert!(ring.replace_cord(i, &mut circ));
        }
        assert!(ring.sealed());
        assert!(circ.rotor.loop_active);
    }

    #[test]
    fn joint_articulation_moves() {
        let mut h = standing_humanoid();
        let mut cmd = Articulation::default();
        cmd.joint = crate::anatomy::JOINT_LEFT_ELBOW;
        cmd.target = 1.0; // ~57° flexion
        cmd.effort = 0.8;
        assert!(h.articulate(cmd));
        h.tick(0.01, None);
        let joint = h.motors.joints.iter().find(|j| j.def == cmd.joint).unwrap();
        assert!(joint.current_angle > 0.0);
    }

    #[test]
    fn humanoid_binds_env_and_queries() {
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
        let mut h = standing_humanoid();
        h.tick(0.01, Some(&world));
        assert!(h.tick_count >= 1);
    }
}
