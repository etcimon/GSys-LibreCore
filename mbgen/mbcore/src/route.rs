//! Occupancy and integer routing. Pack courtyard (`DEFAULT_GAP_UM`) is not
//! keep-out. Power/GND are rails with empty paths until a Footprint exists.

use std::cmp::Ordering;
use std::collections::{BinaryHeap, HashMap};

use serde::{Deserialize, Serialize};

use crate::net::{auto_connect, Hit, Net, NetClass, NetError, NetErrorKind, Path, PathHitKind, Pin};
use crate::net::pins_for;
use crate::pack::PackError;
use crate::scene::{scene, Body};
use crate::template::Design;

pub const GRID_UM: i64 = 250;
pub const TRACE_CLEAR_UM: i64 = 150;
pub const TRACE_HALF_UM: i64 = 75;
pub const VIA_CLEAR_UM: i64 = 200;
pub const BODY_KEEP_UM: i64 = TRACE_CLEAR_UM + TRACE_HALF_UM;
const VIA_COST: i32 = 8;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RouteResult {
    pub nets: Vec<Net>,
    pub paths: Vec<Path>,
    pub errors: Vec<NetError>,
}

#[derive(Clone, Debug)]
pub struct Occupancy {
    pub w_um: i64,
    pub d_um: i64,
    pub grid_um: i64,
    pub cols: i32,
    pub rows: i32,
    body: Vec<u8>,
}

impl Occupancy {
    pub fn new(w_um: i64, d_um: i64) -> Self {
        let cols = ((w_um + GRID_UM - 1) / GRID_UM).max(1) as i32;
        let rows = ((d_um + GRID_UM - 1) / GRID_UM).max(1) as i32;
        Self {
            w_um,
            d_um,
            grid_um: GRID_UM,
            cols,
            rows,
            body: vec![0; (cols * rows) as usize],
        }
    }

    pub fn from_bodies(bodies: &[Body], w_um: i64, d_um: i64) -> Self {
        let mut occ = Self::new(w_um, d_um);
        for body in bodies {
            if body.id == "pcb" || body.id == "shield" {
                continue;
            }
            occ.mark_body(body);
        }
        occ
    }

    pub fn mark_body(&mut self, body: &Body) {
        let (x0, x1, y0, y1) = expanded_aabb(body);
        if x1 < 0 || y1 < 0 || x0 >= self.w_um || y0 >= self.d_um {
            return;
        }
        let c0 = self.cell(x0).clamp(0, self.cols - 1);
        let c1 = self.cell(x1).clamp(0, self.cols - 1);
        let r0 = self.cell(y0).clamp(0, self.rows - 1);
        let r1 = self.cell(y1).clamp(0, self.rows - 1);
        for y in r0..=r1 {
            for x in c0..=c1 {
                self.body[(y * self.cols + x) as usize] = 1;
            }
        }
    }

    pub fn blocked(&self, cx: i32, cy: i32) -> bool {
        if cx < 0 || cy < 0 || cx >= self.cols || cy >= self.rows {
            return true;
        }
        self.body[(cy * self.cols + cx) as usize] != 0
    }

    pub fn cell(&self, um: i64) -> i32 {
        um.div_euclid(self.grid_um) as i32
    }

    pub fn cell_um(&self, cell: i32) -> i64 {
        i64::from(cell) * self.grid_um + self.grid_um / 2
    }
}

pub fn expanded_aabb(body: &Body) -> (i64, i64, i64, i64) {
    (
        body.x_um - body.sx_um / 2 - BODY_KEEP_UM,
        body.x_um + body.sx_um / 2 + BODY_KEEP_UM,
        body.y_um - body.sy_um / 2 - BODY_KEEP_UM,
        body.y_um + body.sy_um / 2 + BODY_KEEP_UM,
    )
}

/// Clear micrometres between two expanded AABBs along X when they share Y.
pub fn corridor_x_um(a: &Body, b: &Body) -> Option<i64> {
    let (ax0, ax1, ay0, ay1) = expanded_aabb(a);
    let (bx0, bx1, by0, by1) = expanded_aabb(b);
    if ay1 <= by0 || by1 <= ay0 {
        return None;
    }
    let (left, right) = if ax0 <= bx0 { (ax1, bx0) } else { (bx1, ax0) };
    Some(right - left)
}

pub fn route(design: &Design) -> Result<RouteResult, PackError> {
    let nets = auto_connect(design);
    let template = design.template()?;
    let bodies = scene(design)?;
    let occ = Occupancy::from_bodies(&bodies, template.board_w_um, template.board_d_um);
    let mut paths = Vec::new();
    let mut errors = Vec::new();
    for net in &nets {
        match net.class {
            NetClass::Power | NetClass::Ground => {}
            NetClass::Signal | NetClass::Clock => {
                route_signal(net, design, &bodies, &occ, &mut paths, &mut errors);
            }
        }
    }
    Ok(RouteResult { nets, paths, errors })
}

fn route_signal(
    net: &Net,
    design: &Design,
    bodies: &[Body],
    occ: &Occupancy,
    paths: &mut Vec<Path>,
    errors: &mut Vec<NetError>,
) {
    let mut pads = Vec::new();
    for port in &design.ports {
        for pin in pins_for(&port.id, &port.role) {
            if !net.pins.iter().any(|id| id == &pin.id) {
                continue;
            }
            if let Some(xy) = pad_xy(&pin, bodies) {
                pads.push((pin, xy));
            }
        }
    }
    if pads.len() < 2 {
        if pads.len() == 1 {
            errors.push(NetError {
                kind: NetErrorKind::OpenRequired,
                pin: Some(pads[0].0.id.clone()),
                net: Some(net.id.clone()),
                reason: format!("{} has one pad", net.id),
            });
        }
        return;
    }
    let start = pads[0].1;
    for (pin, goal) in pads.iter().skip(1) {
        match astar(occ, start, *goal, &[]) {
            Some(hits) => paths.push(Path {
                net: net.id.clone(),
                hits,
            }),
            None => errors.push(NetError {
                kind: NetErrorKind::Unroutable,
                pin: Some(pin.id.clone()),
                net: Some(net.id.clone()),
                reason: format!("{} did not reach {}", net.id, pin.id),
            }),
        }
    }
}

fn pad_xy(pin: &Pin, bodies: &[Body]) -> Option<(i64, i64)> {
    let (dx, dy) = (pin.dx_um?, pin.dy_um?);
    let body = bodies.iter().find(|b| b.id == pin.part)?;
    Some((body.x_um + dx, body.y_um + dy))
}

#[derive(Copy, Clone, Eq, PartialEq)]
struct Node {
    cost: i32,
    x: i32,
    y: i32,
    layer: u8,
}

impl Ord for Node {
    fn cmp(&self, other: &Self) -> Ordering {
        other
            .cost
            .cmp(&self.cost)
            .then_with(|| self.x.cmp(&other.x))
            .then_with(|| self.y.cmp(&other.y))
            .then_with(|| self.layer.cmp(&other.layer))
    }
}

impl PartialOrd for Node {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

/// 4-connected Manhattan A* on two layers. `vias` are existing via cells for keep-out.
pub fn astar(
    occ: &Occupancy,
    start_um: (i64, i64),
    goal_um: (i64, i64),
    vias: &[(i32, i32)],
) -> Option<Vec<Hit>> {
    let sx = occ.cell(start_um.0);
    let sy = occ.cell(start_um.1);
    let gx = occ.cell(goal_um.0);
    let gy = occ.cell(goal_um.1);
    let via_cells = VIA_CLEAR_UM.div_euclid(occ.grid_um).max(1) as i32;
    let mut heap = BinaryHeap::new();
    let mut best: HashMap<(i32, i32, u8), i32> = HashMap::new();
    let mut parent: HashMap<(i32, i32, u8), (i32, i32, u8)> = HashMap::new();
    heap.push(Node {
        cost: 0,
        x: sx,
        y: sy,
        layer: 0,
    });
    best.insert((sx, sy, 0), 0);
    let walkable = |x: i32, y: i32| {
        if x == sx && y == sy || x == gx && y == gy {
            return x >= 0 && y >= 0 && x < occ.cols && y < occ.rows;
        }
        !occ.blocked(x, y)
    };
    let via_ok = |x: i32, y: i32| {
        vias.iter().all(|(vx, vy)| (x - vx).abs() > via_cells || (y - vy).abs() > via_cells)
    };
    while let Some(Node { cost, x, y, layer }) = heap.pop() {
        if x == gx && y == gy {
            return Some(rebuild(occ, &parent, (sx, sy, 0), (x, y, layer)));
        }
        if best.get(&(x, y, layer)).copied().unwrap_or(i32::MAX) < cost {
            continue;
        }
        const DIRS: [(i32, i32); 4] = [(1, 0), (-1, 0), (0, 1), (0, -1)];
        for (dx, dy) in DIRS {
            let nx = x + dx;
            let ny = y + dy;
            if !walkable(nx, ny) {
                continue;
            }
            let ncost = cost + 1;
            let key = (nx, ny, layer);
            if ncost < best.get(&key).copied().unwrap_or(i32::MAX) {
                best.insert(key, ncost);
                parent.insert(key, (x, y, layer));
                heap.push(Node {
                    cost: ncost,
                    x: nx,
                    y: ny,
                    layer,
                });
            }
        }
        let other = 1 - layer;
        if via_ok(x, y) && walkable(x, y) {
            let ncost = cost + VIA_COST;
            let key = (x, y, other);
            if ncost < best.get(&key).copied().unwrap_or(i32::MAX) {
                best.insert(key, ncost);
                parent.insert(key, (x, y, layer));
                heap.push(Node {
                    cost: ncost,
                    x,
                    y,
                    layer: other,
                });
            }
        }
    }
    None
}

fn rebuild(
    occ: &Occupancy,
    parent: &HashMap<(i32, i32, u8), (i32, i32, u8)>,
    start: (i32, i32, u8),
    goal: (i32, i32, u8),
) -> Vec<Hit> {
    let mut cur = goal;
    let mut rev = vec![cur];
    while cur != start {
        cur = parent[&cur];
        rev.push(cur);
    }
    rev.reverse();
    let mut hits = Vec::new();
    let mut prev_layer = rev[0].2;
    for (x, y, layer) in rev {
        let kind = if layer != prev_layer {
            PathHitKind::Via
        } else {
            PathHitKind::Trace
        };
        hits.push(Hit {
            x_um: occ.cell_um(x),
            y_um: occ.cell_um(y),
            layer,
            kind,
        });
        prev_layer = layer;
    }
    hits
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::export::compile;
    use crate::pins_for;
    use crate::template::Design;
    use crate::DEFAULT_GAP_UM;
    use std::time::Instant;

    #[test]
    fn power_edge_neighbours_keep_a_quarter_millimetre_corridor() {
        let bundle = compile(&Design::mini_itx().unwrap()).unwrap();
        let bodies: Vec<Body> = serde_json::from_value(bundle.scene).unwrap();
        let mut power: Vec<_> = bodies
            .iter()
            .filter(|b| matches!(b.role.as_str(), "spi_flash" | "vtt" | "decap"))
            .collect();
        power.sort_by_key(|b| b.x_um);
        assert!(power.len() >= 2);
        let mut saw = false;
        for pair in power.windows(2) {
            let Some(gap) = corridor_x_um(pair[0], pair[1]) else {
                continue;
            };
            saw = true;
            assert!(
                gap >= GRID_UM,
                "{} vs {} corridor {gap} µm",
                pair[0].id,
                pair[1].id
            );
            assert!(
                gap < DEFAULT_GAP_UM,
                "occupancy must use trace keep-out, not pack gap"
            );
        }
        assert!(saw, "power-edge parts should sit on one strip");
    }

    #[test]
    fn rails_have_empty_paths_and_usb_stays_pinless() {
        let design = Design::mini_itx().unwrap();
        let result = route(&design).unwrap();
        assert!(result.paths.is_empty());
        assert!(result.nets.iter().any(|n| n.id == "P12V" && n.class == NetClass::Power));
        assert!(result.nets.iter().any(|n| n.id == "GND" && n.class == NetClass::Ground));
        assert!(result.errors.is_empty());
        assert!(pins_for("usb0", "usb_stack").is_empty());
        assert!(pins_for("socket", "socket").is_empty());
        let bundle = compile(&design).unwrap();
        assert!(bundle.paths.as_array().unwrap().is_empty());
        assert!(bundle.nets.as_array().unwrap().iter().any(|n| n["id"] == "P12V"));
        assert!(bundle.nets.as_array().unwrap().iter().all(|n| n["id"] != "VBUS"));
    }

    #[test]
    fn membership_is_under_one_millisecond() {
        let design = Design::mini_itx().unwrap();
        let _ = auto_connect(&design);
        let mut best = u128::MAX;
        for _ in 0..8 {
            let start = Instant::now();
            let nets = auto_connect(&design);
            best = best.min(start.elapsed().as_micros());
            assert!(!nets.is_empty());
        }
        assert!(best < 1_000, "membership took {best} µs");
    }

    #[test]
    fn astar_walks_an_empty_board_and_fails_a_wall() {
        let empty = Occupancy::new(10_000, 10_000);
        let hits = astar(&empty, (500, 500), (4_500, 500), &[]).unwrap();
        assert!(hits.len() >= 2);
        assert!(hits.iter().all(|h| h.kind == PathHitKind::Trace));
        let mut walled = Occupancy::new(10_000, 10_000);
        for y in 4..8 {
            for x in 0..walled.cols {
                walled.body[(y * walled.cols + x) as usize] = 1;
            }
        }
        assert!(astar(&walled, (500, 500), (500, 8_000), &[]).is_none());
    }
}
