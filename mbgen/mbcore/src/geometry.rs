// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! One transform for everything that has a position on the board: bodies,
//! pads, anchors, meshes and exports. Integer micrometres, board origin at the
//! front-left corner, X along the board width, Y along its depth, Z up.
//!
//! Rotation is exact quarter-turns (`yaw_q` ∈ 0..=3, counter-clockwise seen
//! from above). A bottom-side part is mirrored about its own Y axis before
//! rotation, which is how a footprint flips when a board is turned over.

use serde::{Deserialize, Serialize};

use crate::template::Side;

/// PCB thickness and the two copper planes, in micrometres.
pub const PCB_THICKNESS_UM: i64 = 1_600;
pub const TOP_COPPER_Z_UM: i64 = PCB_THICKNESS_UM;
pub const BOTTOM_COPPER_Z_UM: i64 = 0;

/// Rotate a footprint-local offset by `yaw_q` quarter turns (CCW from above).
pub fn rotate_q(dx: i64, dy: i64, yaw_q: u8) -> (i64, i64) {
    match yaw_q % 4 {
        0 => (dx, dy),
        1 => (-dy, dx),
        2 => (-dx, -dy),
        _ => (dy, -dx),
    }
}

/// Footprint-local offset to board XY for a part centred at `(cx, cy)`.
/// Bottom-side parts are mirrored in X (the footprint is seen from below).
pub fn pad_world(cx: i64, cy: i64, dx: i64, dy: i64, yaw_q: u8, side: Side) -> (i64, i64) {
    let mx = if side == Side::Bottom { -dx } else { dx };
    let (rx, ry) = rotate_q(mx, dy, yaw_q);
    (cx + rx, cy + ry)
}

/// Copper plane a pad on `side` sits on.
pub fn copper_z(side: Side) -> i64 {
    match side {
        Side::Top => TOP_COPPER_Z_UM,
        Side::Bottom => BOTTOM_COPPER_Z_UM,
    }
}

/// Routing layer index for a side: 0 = top, 1 = bottom.
pub fn layer_of(side: Side) -> u8 {
    match side {
        Side::Top => 0,
        Side::Bottom => 1,
    }
}

/// Body extents after rotation (axis-aligned span in board XY).
pub fn world_span(sx: i64, sy: i64, yaw_q: u8) -> (i64, i64) {
    if yaw_q % 2 == 1 {
        (sy, sx)
    } else {
        (sx, sy)
    }
}

/// Body centre Z: sits on the top copper, or hangs under the bottom copper.
pub fn body_z(sz: i64, side: Side) -> i64 {
    match side {
        Side::Top => TOP_COPPER_Z_UM + sz / 2,
        Side::Bottom => BOTTOM_COPPER_Z_UM - sz / 2,
    }
}

/// Axis-aligned rectangle in board micrometres.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Rect {
    pub x0: i64,
    pub y0: i64,
    pub x1: i64,
    pub y1: i64,
}

impl Rect {
    pub fn centred(cx: i64, cy: i64, sx: i64, sy: i64) -> Self {
        Self { x0: cx - sx / 2, y0: cy - sy / 2, x1: cx + sx / 2, y1: cy + sy / 2 }
    }

    pub fn inflate(self, by: i64) -> Self {
        Self { x0: self.x0 - by, y0: self.y0 - by, x1: self.x1 + by, y1: self.y1 + by }
    }

    pub fn intersects(self, o: Rect) -> bool {
        self.x0 < o.x1 && o.x0 < self.x1 && self.y0 < o.y1 && o.y0 < self.y1
    }

    pub fn contains(self, x: i64, y: i64) -> bool {
        x >= self.x0 && x <= self.x1 && y >= self.y0 && y <= self.y1
    }

    pub fn inside(self, outer: Rect) -> bool {
        self.x0 >= outer.x0 && self.y0 >= outer.y0 && self.x1 <= outer.x1 && self.y1 <= outer.y1
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quarter_turns_are_exact_and_cycle() {
        assert_eq!(rotate_q(10, 3, 0), (10, 3));
        assert_eq!(rotate_q(10, 3, 1), (-3, 10));
        assert_eq!(rotate_q(10, 3, 2), (-10, -3));
        assert_eq!(rotate_q(10, 3, 3), (3, -10));
        assert_eq!(rotate_q(10, 3, 4), (10, 3));
        let mut p = (7, -2);
        for _ in 0..4 {
            p = rotate_q(p.0, p.1, 1);
        }
        assert_eq!(p, (7, -2));
    }

    #[test]
    fn bottom_side_mirrors_x_before_rotation() {
        assert_eq!(pad_world(100, 200, 10, 3, 0, Side::Top), (110, 203));
        assert_eq!(pad_world(100, 200, 10, 3, 0, Side::Bottom), (90, 203));
        // Mirror then rotate: (-10, 3) rotated once is (-3, -10).
        assert_eq!(pad_world(100, 200, 10, 3, 1, Side::Bottom), (97, 190));
        assert_eq!(copper_z(Side::Top), 1_600);
        assert_eq!(copper_z(Side::Bottom), 0);
        assert_eq!(layer_of(Side::Bottom), 1);
        assert_eq!(body_z(4_000, Side::Top), 3_600);
        assert_eq!(body_z(4_000, Side::Bottom), -2_000);
    }

    #[test]
    fn rect_algebra() {
        let a = Rect::centred(100, 100, 20, 10);
        assert_eq!(a, Rect { x0: 90, y0: 95, x1: 110, y1: 105 });
        assert!(a.intersects(Rect::centred(105, 100, 20, 10)));
        assert!(!a.intersects(Rect::centred(200, 100, 20, 10)));
        assert!(a.inflate(5).contains(85, 100));
        assert!(a.inside(Rect { x0: 0, y0: 0, x1: 1000, y1: 1000 }));
        assert!(!a.inside(Rect { x0: 95, y0: 0, x1: 1000, y1: 1000 }));
        assert_eq!(world_span(20, 10, 1), (10, 20));
    }
}
