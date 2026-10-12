//! CATIA-like preview navigation. Lengths are centimetres in the Unreal
//! preview (actor-local * 20). The live pawn copies these constants.

/// Per-notch distance scale. Unreal `AddZoomToward` / `DollyViewport` use this.
pub const ZOOM_RATIO: f64 = 1.04;
/// One wheel event cannot exceed this many notches (stops a spin-wheel slam).
pub const WHEEL_NOTCH_LIMIT: f64 = 1.0;
pub const DEFAULT_SENS: f64 = 0.25;
pub const MIN_DIST: f64 = 20.0;
pub const MAX_DIST: f64 = 8000.0;
pub const ORBIT_YAW_PER_PX: f64 = 0.12;
pub const ORBIT_PITCH_PER_PX: f64 = 0.10;
/// Half-extent multiplier for the finite desk the board rests on (1.5 = 50% margin).
pub const DESK_PAD: f64 = 1.5;
const PITCH_LIMIT: f64 = 85.0;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Desk {
    pub cx: f64,
    pub cy: f64,
    pub z: f64,
    pub hx: f64,
    pub hy: f64,
}

/// Actor-local centimetres. `z` is the rest plane (PCB bottom).
pub fn desk_from_board(board_w_cm: f64, board_d_cm: f64, z: f64) -> Desk {
    Desk {
        cx: board_w_cm * 0.5,
        cy: board_d_cm * 0.5,
        z,
        hx: board_w_cm * 0.5 * DESK_PAD,
        hy: board_d_cm * 0.5 * DESK_PAD,
    }
}

/// Pick on the finite desk. A shallow ray that would hit an infinite plane
/// kilometres away is clamped to the desk rim.
pub fn hit_desk(desk: Desk, origin: Vec3, dir: Vec3) -> Vec3 {
    let xmin = desk.cx - desk.hx;
    let xmax = desk.cx + desk.hx;
    let ymin = desk.cy - desk.hy;
    let ymax = desk.cy + desk.hy;
    let d = dir.norm();
    if d.z.abs() > 1e-8 {
        let t = (desk.z - origin.z) / d.z;
        if t > 0.0 {
            let p = origin.add(d.scale(t));
            return Vec3::new(p.x.clamp(xmin, xmax), p.y.clamp(ymin, ymax), desk.z);
        }
    }
    Vec3::new(
        origin.x.clamp(xmin, xmax),
        origin.y.clamp(ymin, ymax),
        desk.z,
    )
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Vec3 {
    pub x: f64,
    pub y: f64,
    pub z: f64,
}

impl Vec3 {
    pub fn new(x: f64, y: f64, z: f64) -> Self {
        Self { x, y, z }
    }

    pub fn add(self, o: Self) -> Self {
        Self::new(self.x + o.x, self.y + o.y, self.z + o.z)
    }

    pub fn sub(self, o: Self) -> Self {
        Self::new(self.x - o.x, self.y - o.y, self.z - o.z)
    }

    pub fn scale(self, s: f64) -> Self {
        Self::new(self.x * s, self.y * s, self.z * s)
    }

    pub fn dot(self, o: Self) -> f64 {
        self.x * o.x + self.y * o.y + self.z * o.z
    }

    pub fn length(self) -> f64 {
        self.dot(self).sqrt()
    }

    pub fn norm(self) -> Self {
        let l = self.length();
        if l < 1e-9 {
            Self::new(0.0, 0.0, 1.0)
        } else {
            self.scale(1.0 / l)
        }
    }

    pub fn cross(self, o: Self) -> Self {
        Self::new(
            self.y * o.z - self.z * o.y,
            self.z * o.x - self.x * o.z,
            self.x * o.y - self.y * o.x,
        )
    }
}

pub fn clamp_sens(sens: f64) -> f64 {
    sens.clamp(0.05, 2.0)
}

pub fn clamp_wheel(notches: f64) -> f64 {
    notches.clamp(-WHEEL_NOTCH_LIMIT, WHEEL_NOTCH_LIMIT)
}

pub fn zoom_distance(dist: f64, notches: f64, sens: f64) -> f64 {
    let n = clamp_wheel(notches) * clamp_sens(sens);
    (dist / ZOOM_RATIO.powf(n)).clamp(MIN_DIST, MAX_DIST)
}

/// Move the camera along the pick ray. Orientation is the caller's job.
pub fn zoom_toward(cam: Vec3, hit: Vec3, notches: f64, sens: f64) -> Vec3 {
    let rel = cam.sub(hit);
    let dist = rel.length().max(1.0);
    let new_dist = zoom_distance(dist, notches, sens);
    hit.add(rel.norm().scale(new_dist))
}

fn rotate_around_up(v: Vec3, deg: f64) -> Vec3 {
    let r = deg.to_radians();
    let (s, c) = (r.sin(), r.cos());
    Vec3::new(v.x * c - v.y * s, v.x * s + v.y * c, v.z)
}

fn clamp_pitch_dir(forward: Vec3) -> Vec3 {
    let len_xy = (forward.x * forward.x + forward.y * forward.y).sqrt();
    let pitch = forward.z.atan2(len_xy).to_degrees();
    if pitch.abs() <= PITCH_LIMIT {
        return forward.norm();
    }
    let p = PITCH_LIMIT.to_radians().copysign(pitch);
    let xy = Vec3::new(forward.x, forward.y, 0.0).norm();
    xy.scale(p.cos()).add(Vec3::new(0.0, 0.0, p.sin())).norm()
}

/// Camera stays put. Yaw around world Z, pitch around camera right. Roll stays 0.
/// Positive pitch looks up (matches Unreal `RotateAngleAxis` on camera right).
/// Returns `(camera, forward)`. Camera is unchanged so distance to the board stays put.
pub fn look_in_place_pose(cam: Vec3, forward: Vec3, yaw_deg: f64, pitch_deg: f64) -> (Vec3, Vec3) {
    (cam, look_in_place(forward, yaw_deg, pitch_deg))
}

/// Camera stays put. Yaw around world Z, pitch around camera right. Roll stays 0.
/// Positive pitch looks up (matches Unreal `RotateAngleAxis` on camera right).
pub fn look_in_place(forward: Vec3, yaw_deg: f64, pitch_deg: f64) -> Vec3 {
    let f = rotate_around_up(forward.norm(), yaw_deg);
    let right = f.cross(Vec3::new(0.0, 0.0, 1.0));
    let right = if right.length() < 1e-6 {
        Vec3::new(1.0, 0.0, 0.0)
    } else {
        right.norm()
    };
    let r = pitch_deg.to_radians();
    let pitched = f.scale(r.cos()).add(right.cross(f).scale(r.sin()));
    clamp_pitch_dir(pitched)
}

/// Camera flies on a sphere around `pivot`, still looking at `pivot`. Roll stays 0.
pub fn orbit_around(pivot: Vec3, cam: Vec3, yaw_deg: f64, pitch_deg: f64) -> Vec3 {
    let rel = cam.sub(pivot);
    let dist = rel.length().max(1.0);
    let f = look_in_place(pivot.sub(cam).norm(), yaw_deg, pitch_deg);
    pivot.sub(f.scale(dist))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn almost(a: f64, b: f64, eps: f64) -> bool {
        (a - b).abs() <= eps
    }

    fn almost_vec(a: Vec3, b: Vec3, eps: f64) -> bool {
        almost(a.x, b.x, eps) && almost(a.y, b.y, eps) && almost(a.z, b.z, eps)
    }

    #[test]
    fn one_wheel_event_cannot_slam_the_camera() {
        assert_eq!(clamp_wheel(40.0), 1.0);
        assert_eq!(clamp_wheel(-120.0), -1.0);
        assert_eq!(clamp_wheel(0.5), 0.5);
        let d = zoom_distance(1600.0, 40.0, DEFAULT_SENS);
        let one = zoom_distance(1600.0, 1.0, DEFAULT_SENS);
        assert!(almost(d, one, 1e-9));
        assert!(one < 1600.0);
        assert!(one > 1600.0 * 0.97);
    }

    #[test]
    fn default_sens_keeps_a_mini_itx_overview_in_view() {
        let mut d = 1600.0;
        for _ in 0..40 {
            d = zoom_distance(d, 1.0, DEFAULT_SENS);
        }
        assert!(d > 800.0, "40 notches still on the board {d}");
        assert!(d < 1600.0);
        let mut out = 1600.0;
        for _ in 0..40 {
            out = zoom_distance(out, -1.0, DEFAULT_SENS);
        }
        assert!(out < 3200.0, "40 zoom-out notches stay framed {out}");
        assert!(out > 1600.0);
    }

    #[test]
    fn zoom_toward_stays_on_the_pick_ray() {
        let cam = Vec3::new(0.0, -400.0, 200.0);
        let hit = Vec3::new(170.0, 170.0, 2.0);
        let next = zoom_toward(cam, hit, 1.0, DEFAULT_SENS);
        let a = cam.sub(hit).norm();
        let b = next.sub(hit).norm();
        assert!(almost(a.dot(b), 1.0, 1e-9));
        let old = cam.sub(hit).length();
        let new = next.sub(hit).length();
        assert!(new < old);
        assert!(almost(new, zoom_distance(old, 1.0, DEFAULT_SENS), 1e-6));
    }

    #[test]
    fn look_in_place_does_not_move_the_camera() {
        let cam = Vec3::new(10.0, 20.0, 30.0);
        let _ = cam;
        let forward = Vec3::new(0.0, 1.0, 0.0);
        let next = look_in_place(forward, 15.0, -8.0);
        assert!(almost(next.length(), 1.0, 1e-9));
        assert!(next.dot(forward) < 0.999);
        assert!(next.z.abs() < 0.5);
    }

    #[test]
    fn desk_pick_does_not_run_to_infinity() {
        let desk = desk_from_board(17.0, 17.0, 0.0);
        assert!(almost(desk.hx, 8.5 * DESK_PAD, 1e-9));
        let cam = Vec3::new(8.5, -40.0, 30.0);
        let dir = Vec3::new(0.15, 1.0, -0.02);
        let d = dir.norm();
        let t_inf = (0.0 - cam.z) / d.z;
        let inf = cam.add(d.scale(t_inf));
        assert!(inf.sub(cam).length() > 500.0);
        let hit = hit_desk(desk, cam, dir);
        assert!(hit.x >= desk.cx - desk.hx - 1e-9 && hit.x <= desk.cx + desk.hx + 1e-9);
        assert!(hit.y >= desk.cy - desk.hy - 1e-9 && hit.y <= desk.cy + desk.hy + 1e-9);
        assert!(almost(hit.z, 0.0, 1e-9));
        let d_hit = cam.sub(hit).length();
        assert!(d_hit < inf.sub(cam).length());
        assert!(d_hit < MAX_DIST);
        let (next_cam, _) = look_in_place_pose(cam, hit.sub(cam).norm(), 20.0, -12.0);
        assert!(almost_vec(next_cam, cam, 1e-9));
        assert!(almost(next_cam.sub(hit).length(), d_hit, 1e-9));
    }

    #[test]
    fn look_in_place_does_not_recede_from_the_board() {
        let board = Vec3::new(170.0, 170.0, 2.0);
        let cam = Vec3::new(-200.0, -400.0, 350.0);
        let d0 = cam.sub(board).length();
        let (next_cam, next_fwd) =
            look_in_place_pose(cam, board.sub(cam).norm(), 30.0, -18.0);
        assert!(almost_vec(next_cam, cam, 1e-9));
        assert!(almost(next_cam.sub(board).length(), d0, 1e-9));
        assert!(almost(next_fwd.length(), 1.0, 1e-9));
        let mut drag_cam = cam;
        let mut drag_fwd = board.sub(cam).norm();
        for _ in 0..80 {
            let pose = look_in_place_pose(drag_cam, drag_fwd, ORBIT_YAW_PER_PX, -ORBIT_PITCH_PER_PX);
            drag_cam = pose.0;
            drag_fwd = pose.1;
        }
        assert!(almost_vec(drag_cam, cam, 1e-9));
        assert!(almost(drag_cam.sub(board).length(), d0, 1e-9));
        let recede = orbit_around(Vec3::new(0.0, 0.0, 0.0), cam, 30.0, -18.0);
        assert!(
            recede.sub(cam).length() > 50.0,
            "orbiting the origin flies the camera; empty-space look must keep cam"
        );
        assert!(
            (recede.sub(board).length() - d0).abs() > 1.0,
            "orbiting the origin changes Mini-ITX distance; look-in-place must not"
        );
    }

    #[test]
    fn orbit_keeps_distance_and_looks_at_the_pivot() {
        let pivot = Vec3::new(170.0, 170.0, 2.0);
        let cam = Vec3::new(0.0, -200.0, 300.0);
        let next = orbit_around(pivot, cam, 25.0, -10.0);
        let old_d = cam.sub(pivot).length();
        let new_d = next.sub(pivot).length();
        assert!(almost(old_d, new_d, 1e-6));
        let look = pivot.sub(next).norm();
        let inward = pivot.sub(cam).norm();
        assert!(look.dot(inward) < 0.999);
        assert!(almost(look.length(), 1.0, 1e-9));
    }

    #[test]
    fn look_has_no_roll_spin() {
        let f = look_in_place(Vec3::new(1.0, 0.0, 0.0), 90.0, 0.0);
        assert!(almost(f.z, 0.0, 1e-9));
        assert!(almost(f.y, 1.0, 1e-6) || almost(f.y, -1.0, 1e-6));
    }

    #[test]
    fn orbit_pixel_step_is_gentle() {
        let pivot = Vec3::new(0.0, 0.0, 0.0);
        let cam = Vec3::new(0.0, -1600.0, 400.0);
        let next = orbit_around(pivot, cam, ORBIT_YAW_PER_PX, 0.0);
        let moved = next.sub(cam).length();
        assert!(moved < 5.0, "one pixel of orbit should be millimetres not metres {moved}");
    }

    fn azimuth_deg(v: Vec3) -> f64 {
        v.y.atan2(v.x).to_degrees()
    }

    fn pitch_deg(v: Vec3) -> f64 {
        let xy = (v.x * v.x + v.y * v.y).sqrt();
        v.z.atan2(xy).to_degrees()
    }

    #[test]
    fn clamp_sens_keeps_the_default_in_range() {
        assert_eq!(clamp_sens(DEFAULT_SENS), DEFAULT_SENS);
        assert_eq!(clamp_sens(0.0), 0.05);
        assert_eq!(clamp_sens(9.0), 2.0);
    }

    #[test]
    fn spin_wheel_zoom_equals_one_notch() {
        let cam = Vec3::new(0.0, -400.0, 200.0);
        let hit = Vec3::new(170.0, 170.0, 2.0);
        let spin = zoom_toward(cam, hit, 120.0, DEFAULT_SENS);
        let one = zoom_toward(cam, hit, 1.0, DEFAULT_SENS);
        assert!(almost_vec(spin, one, 1e-9));
    }

    #[test]
    fn yaw_keeps_horizon_level() {
        let f0 = Vec3::new(1.0, 0.2, -0.15).norm();
        let f = look_in_place(f0, 35.0, 0.0);
        assert!(almost(f.z, f0.z, 1e-6));
        let delta = (azimuth_deg(f) - azimuth_deg(f0) + 540.0) % 360.0 - 180.0;
        assert!(almost(delta, 35.0, 0.05));
    }

    #[test]
    fn pitch_keeps_azimuth() {
        let f0 = Vec3::new(0.4, 1.0, -0.1).norm();
        let f = look_in_place(f0, 0.0, 12.0);
        assert!(almost(azimuth_deg(f), azimuth_deg(f0), 0.05));
        assert!(pitch_deg(f) > pitch_deg(f0));
    }

    #[test]
    fn look_pitch_stops_before_a_flip() {
        let f = look_in_place(Vec3::new(0.0, 1.0, 0.0), 0.0, 200.0);
        assert!(pitch_deg(f).abs() <= PITCH_LIMIT + 1e-6);
        let down = look_in_place(Vec3::new(0.0, 1.0, 0.0), 0.0, -200.0);
        assert!(pitch_deg(down).abs() <= PITCH_LIMIT + 1e-6);
    }

    #[test]
    fn catia_zoom_then_orbit_stays_on_the_click() {
        let hit = Vec3::new(170.0, 170.0, 2.0);
        let cam = Vec3::new(-80.0, -420.0, 310.0);
        let zoomed = zoom_toward(cam, hit, 1.0, DEFAULT_SENS);
        let along = zoomed.sub(hit).norm().dot(cam.sub(hit).norm());
        assert!(almost(along, 1.0, 1e-9));
        let orbited = orbit_around(hit, zoomed, 18.0, -6.0);
        assert!(almost(
            orbited.sub(hit).length(),
            zoomed.sub(hit).length(),
            1e-6
        ));
        let look = hit.sub(orbited).norm();
        assert!(almost(look.length(), 1.0, 1e-9));
        assert!(look.dot(hit.sub(zoomed).norm()) < 0.999);
    }

    #[test]
    fn old_wheel_law_would_leave_the_board() {
        let slam = 1600.0 / 1.12f64.powf(40.0);
        assert!(slam < MIN_DIST);
        let now = {
            let mut d = 1600.0;
            for _ in 0..40 {
                d = zoom_distance(d, 1.0, DEFAULT_SENS);
            }
            d
        };
        assert!(now > 800.0);
        assert!(now > slam * 40.0);
    }
}
