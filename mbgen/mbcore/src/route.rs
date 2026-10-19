// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Occupancy and integer routing over two copper layers.
//!
//! * **A\*** over `(x, y, layer, heading)` with an admissible Manhattan
//!   heuristic to a target pad set; tree joins (third and later terminals of a
//!   net) run as Dijkstra against the net's reserved copper because no cheap
//!   admissible bound to "any tree cell" exists.
//! * **Layer-specific obstacles**: an SMT body blocks only its own side; a
//!   through-hole pad blocks both. Pack courtyard (`DEFAULT_GAP_UM`) is not
//!   keep-out — trace clearance plus half a trace width is.
//! * **Exact endpoints**: a path starts and ends on the pad's micrometre
//!   position, not a cell centre.
//! * **Reservation**: accepted copper and vias are owned by their net; the
//!   same net may join, another net may not cross. Other nets' pads are
//!   obstacles.
//! * **Deterministic**: explicit total ordering in the open set and sorted
//!   terminal order; the same inputs give byte-identical paths.
//! * Power and ground stay classified rails with `paths = []` until a plane /
//!   zone plan exists; a supply is not a thin two-pin trace.

use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet, BinaryHeap};

use serde::{Deserialize, Serialize};

use crate::circuit::{resolve, Circuit};
use crate::geometry::{copper_z, layer_of, pad_world, Rect};
use crate::net::{Hit, Net, NetClass, NetError, NetErrorKind, Path, PathHitKind, Pin, PinSide};
use crate::pack::PackError;
use crate::scene::{scene, Body};
use crate::template::{Design, Side};

pub const GRID_UM: i64 = 250;
pub const TRACE_CLEAR_UM: i64 = 150;
pub const TRACE_HALF_UM: i64 = 75;
pub const VIA_CLEAR_UM: i64 = 200;
pub const BODY_KEEP_UM: i64 = TRACE_CLEAR_UM + TRACE_HALF_UM;
const VIA_COST: i32 = 8;
const BEND_COST: i32 = 1;
/// Expansions per search before the net is reported unroutable (budget, not a hang).
pub const SEARCH_BUDGET: usize = 2_000_000;
const LAYERS: usize = 2;
const HEADINGS: usize = 5; // none + 4

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct RouteResult {
    pub nets: Vec<Net>,
    pub paths: Vec<Path>,
    pub errors: Vec<NetError>,
    /// Nets whose paths were (re)computed in this call.
    #[serde(default)]
    pub changed_nets: Vec<String>,
    /// Nets that existed in the previous result and are gone now.
    #[serde(default)]
    pub removed_nets: Vec<String>,
    #[serde(default)]
    pub grid_um: i64,
}

/// Per-layer grid: fixed obstacles plus net ownership of copper.
#[derive(Clone, Debug)]
pub struct Occupancy {
    pub w_um: i64,
    pub d_um: i64,
    pub grid_um: i64,
    pub cols: i32,
    pub rows: i32,
    blocked: [Vec<u8>; LAYERS],
    /// 0 = free, n+1 = owned by net index n.
    owner: [Vec<u32>; LAYERS],
    /// Via cells (both layers), with owning net index + 1.
    vias: Vec<(i32, i32, u32)>,
}

impl Occupancy {
    pub fn new(w_um: i64, d_um: i64) -> Self {
        let cols = ((w_um + GRID_UM - 1) / GRID_UM).max(1) as i32;
        let rows = ((d_um + GRID_UM - 1) / GRID_UM).max(1) as i32;
        let n = (cols * rows) as usize;
        Self {
            w_um,
            d_um,
            grid_um: GRID_UM,
            cols,
            rows,
            blocked: [vec![0; n], vec![0; n]],
            owner: [vec![0; n], vec![0; n]],
            vias: Vec::new(),
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

    /// Body keep-out on the body's own layer only.
    pub fn mark_body(&mut self, body: &Body) {
        let (x0, x1, y0, y1) = expanded_aabb(body);
        self.mark_rect(layer_of(body.side), x0, x1, y0, y1);
    }

    pub fn mark_rect(&mut self, layer: u8, x0: i64, x1: i64, y0: i64, y1: i64) {
        if x1 < 0 || y1 < 0 || x0 >= self.w_um || y0 >= self.d_um {
            return;
        }
        let c0 = self.cell(x0).clamp(0, self.cols - 1);
        let c1 = self.cell(x1).clamp(0, self.cols - 1);
        let r0 = self.cell(y0).clamp(0, self.rows - 1);
        let r1 = self.cell(y1).clamp(0, self.rows - 1);
        for y in r0..=r1 {
            for x in c0..=c1 {
                let i = self.idx(x, y);
                self.blocked[layer as usize][i] = 1;
            }
        }
    }

    fn idx(&self, x: i32, y: i32) -> usize {
        (y * self.cols + x) as usize
    }

    pub fn in_bounds(&self, x: i32, y: i32) -> bool {
        x >= 0 && y >= 0 && x < self.cols && y < self.rows
    }

    pub fn blocked(&self, layer: u8, cx: i32, cy: i32) -> bool {
        !self.in_bounds(cx, cy) || self.blocked[layer as usize][self.idx(cx, cy)] != 0
    }

    pub fn owner(&self, layer: u8, cx: i32, cy: i32) -> u32 {
        if !self.in_bounds(cx, cy) {
            return u32::MAX;
        }
        self.owner[layer as usize][self.idx(cx, cy)]
    }

    pub fn set_owner(&mut self, layer: u8, cx: i32, cy: i32, net_plus_one: u32) {
        if self.in_bounds(cx, cy) {
            let i = self.idx(cx, cy);
            self.owner[layer as usize][i] = net_plus_one;
        }
    }

    pub fn cell(&self, um: i64) -> i32 {
        um.div_euclid(self.grid_um) as i32
    }

    pub fn cell_um(&self, cell: i32) -> i64 {
        i64::from(cell) * self.grid_um + self.grid_um / 2
    }

    /// Walkable for net `me` (index+1): not an obstacle, free or same-net.
    fn passable(&self, layer: u8, x: i32, y: i32, me: u32) -> bool {
        if self.blocked(layer, x, y) {
            return false;
        }
        let o = self.owner(layer, x, y);
        o == 0 || o == me
    }

    fn via_ok(&self, x: i32, y: i32, me: u32) -> bool {
        let r = (VIA_CLEAR_UM.div_euclid(self.grid_um)).max(1) as i32;
        self.vias
            .iter()
            .all(|(vx, vy, owner)| *owner == me || (x - vx).abs() > r || (y - vy).abs() > r)
    }
}

pub fn expanded_aabb(body: &Body) -> (i64, i64, i64, i64) {
    let (sx, sy) = crate::geometry::world_span(body.sx_um, body.sy_um, body.yaw_q);
    (
        body.x_um - sx / 2 - BODY_KEEP_UM,
        body.x_um + sx / 2 + BODY_KEEP_UM,
        body.y_um - sy / 2 - BODY_KEEP_UM,
        body.y_um + sy / 2 + BODY_KEEP_UM,
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

/// A routable terminal: exact board position and layer.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Terminal {
    pub pin: String,
    pub x_um: i64,
    pub y_um: i64,
    pub layer: u8,
    pub through: bool,
}

/// Pad terminals of a pin on a placed body, if the pin has pad geometry.
pub fn terminal_of(pin: &Pin, body: &Body) -> Option<Terminal> {
    let (dx, dy) = (pin.dx_um?, pin.dy_um?);
    let (x_um, y_um) = pad_world(body.x_um, body.y_um, dx, dy, body.yaw_q, body.side);
    let through = pin.side == PinSide::Through;
    let layer = match pin.side {
        PinSide::Top => 0,
        PinSide::Bottom => 1,
        PinSide::Through => layer_of(body.side),
    };
    Some(Terminal { pin: pin.id.clone(), x_um, y_um, layer, through })
}

/// Route the design's resolved circuit. Thin wrapper over `route_nets`.
pub fn route(design: &Design) -> Result<RouteResult, PackError> {
    let circuit = resolve(design)?;
    route_circuit(design, &circuit)
}

pub fn route_circuit(design: &Design, circuit: &Circuit) -> Result<RouteResult, PackError> {
    let template = design.template()?;
    let bodies = scene(design)?;
    let nets: Vec<Net> = circuit
        .nets
        .iter()
        .map(|n| Net { id: n.id.clone(), pins: n.pins.clone(), class: n.class })
        .collect();
    let terminals = terminals_for(&circuit.pins, &bodies);
    Ok(route_nets(&nets, &terminals, &bodies, template.board_w_um, template.board_d_um, None))
}

/// Terminals for every pin with pad geometry, keyed by pin id.
pub fn terminals_for(pins: &[Pin], bodies: &[Body]) -> BTreeMap<String, Terminal> {
    let mut out = BTreeMap::new();
    for pin in pins {
        let Some(body) = bodies.iter().find(|b| b.id == pin.part) else {
            continue;
        };
        if let Some(t) = terminal_of(pin, body) {
            out.insert(pin.id.clone(), t);
        }
    }
    out
}

/// Previously accepted paths to keep (incremental routing).
pub struct Keep<'a> {
    pub paths: &'a [Path],
    pub dirty_nets: &'a BTreeSet<String>,
}

/// The engine. `keep` reserves the previous paths of non-dirty nets first so
/// dirty nets route around them; without `keep` every routable net is routed.
pub fn route_nets(
    nets: &[Net],
    terminals: &BTreeMap<String, Terminal>,
    bodies: &[Body],
    w_um: i64,
    d_um: i64,
    keep: Option<Keep<'_>>,
) -> RouteResult {
    let mut occ = Occupancy::from_bodies(bodies, w_um, d_um);
    let mut paths = Vec::new();
    let mut errors = Vec::new();
    let mut changed_nets = Vec::new();
    // Deterministic net order.
    let mut order: Vec<usize> = (0..nets.len()).collect();
    order.sort_by(|a, b| nets[*a].id.cmp(&nets[*b].id));
    let net_index: BTreeMap<&str, u32> = order.iter().enumerate().map(|(k, i)| (nets[*i].id.as_str(), k as u32 + 1)).collect();

    // Pads: same-net pads are walkable for their net; every other pad is an
    // obstacle to everyone else. Through-hole pads block both layers.
    for net in nets {
        let me = net_index[net.id.as_str()];
        for pin in &net.pins {
            if let Some(t) = terminals.get(pin) {
                let (cx, cy) = (occ.cell(t.x_um), occ.cell(t.y_um));
                if t.through {
                    occ.set_owner(0, cx, cy, me);
                    occ.set_owner(1, cx, cy, me);
                } else {
                    occ.set_owner(t.layer, cx, cy, me);
                }
            }
        }
    }
    let on_a_net: BTreeSet<&str> = nets.iter().flat_map(|n| n.pins.iter().map(String::as_str)).collect();
    for (pin, t) in terminals {
        if !on_a_net.contains(pin.as_str()) {
            let (cx, cy) = (occ.cell(t.x_um), occ.cell(t.y_um));
            let layers: &[u8] = if t.through { &[0, 1] } else { std::slice::from_ref(&t.layer) };
            for l in layers {
                if occ.in_bounds(cx, cy) {
                    let i = occ.idx(cx, cy);
                    occ.blocked[*l as usize][i] = 1;
                }
            }
        }
    }

    // Reserve kept paths before routing anything dirty.
    let mut kept: BTreeMap<String, Vec<Path>> = BTreeMap::new();
    if let Some(k) = &keep {
        for p in k.paths {
            if k.dirty_nets.contains(&p.net) || !net_index.contains_key(p.net.as_str()) {
                continue;
            }
            let me = net_index[p.net.as_str()];
            reserve_path(&mut occ, p, me);
            kept.entry(p.net.clone()).or_default().push(p.clone());
        }
    }

    let mut scratch = Scratch::new(&occ);
    for i in order {
        let net = &nets[i];
        if let Some(k) = kept.remove(&net.id) {
            paths.extend(k);
            continue;
        }
        match net.class {
            NetClass::Power | NetClass::Ground => continue,
            NetClass::Signal | NetClass::Clock => {}
        }
        let me = net_index[net.id.as_str()];
        let mut pads: Vec<&Terminal> = net.pins.iter().filter_map(|p| terminals.get(p)).collect();
        pads.sort_by(|a, b| a.pin.cmp(&b.pin));
        if pads.len() < 2 {
            if pads.len() == 1 {
                errors.push(NetError {
                    kind: NetErrorKind::OpenRequired,
                    pin: Some(pads[0].pin.clone()),
                    net: Some(net.id.clone()),
                    reason: format!("{} has one pad with geometry", net.id),
                });
            }
            continue;
        }
        changed_nets.push(net.id.clone());
        let mut joined: Vec<[u8; 2]> = vec![[0, 0]; (occ.cols * occ.rows) as usize];
        let first = pads[0];
        mark_joined(&occ, &mut joined, first);
        for (k, pad) in pads.iter().enumerate().skip(1) {
            if is_joined(&occ, &joined, pad) {
                continue;
            }
            // Segment 1 runs from the first pad to the second with the
            // Manhattan heuristic; later segments start at the new terminal
            // and join the tree (Dijkstra, h = 0).
            let (from, goal) = if k == 1 { (first, Goal::Pad(pad)) } else { (*pad, Goal::Tree) };
            match search(&occ, &mut scratch, from, goal, &joined, me) {
                Some(cells) => {
                    let to_pad = if k == 1 { Some(*pad) } else { None };
                    let path = build_path(&occ, &cells, from, to_pad, &net.id, paths.len());
                    reserve_path(&mut occ, &path, me);
                    for &(x, y, l) in &cells {
                        if occ.in_bounds(x, y) {
                            joined[occ.idx(x, y)][l as usize] = 1;
                        }
                    }
                    paths.push(path);
                }
                None => errors.push(NetError {
                    kind: NetErrorKind::Unroutable,
                    pin: Some(pad.pin.clone()),
                    net: Some(net.id.clone()),
                    reason: format!("{} did not reach {} within the search budget or around obstacles", net.id, pad.pin),
                }),
            }
        }
    }
    let mut nets_out = nets.to_vec();
    nets_out.sort_by(|a, b| a.id.cmp(&b.id));
    RouteResult { nets: nets_out, paths, errors, changed_nets, removed_nets: Vec::new(), grid_um: GRID_UM }
}

fn mark_joined(occ: &Occupancy, joined: &mut [[u8; 2]], t: &Terminal) {
    let (cx, cy) = (occ.cell(t.x_um), occ.cell(t.y_um));
    if !occ.in_bounds(cx, cy) {
        return;
    }
    let i = occ.idx(cx, cy);
    if t.through {
        joined[i] = [1, 1];
    } else {
        joined[i][t.layer as usize] = 1;
    }
}

fn is_joined(occ: &Occupancy, joined: &[[u8; 2]], t: &Terminal) -> bool {
    let (cx, cy) = (occ.cell(t.x_um), occ.cell(t.y_um));
    occ.in_bounds(cx, cy) && (joined[occ.idx(cx, cy)][t.layer as usize] != 0 || (t.through && joined[occ.idx(cx, cy)] != [0, 0]))
}

fn reserve_path(occ: &mut Occupancy, path: &Path, me: u32) {
    let mut prev: Option<(i32, i32, u8)> = None;
    for hit in &path.hits {
        let (cx, cy) = (occ.cell(hit.x_um), occ.cell(hit.y_um));
        if let Some((px, py, pl)) = prev {
            if pl == hit.layer {
                // Fill the straight run between consecutive hits.
                let (dx, dy) = ((cx - px).signum(), (cy - py).signum());
                let (mut x, mut y) = (px, py);
                while (x, y) != (cx, cy) {
                    x += dx;
                    y += dy;
                    occ.set_owner(hit.layer, x, y, me);
                }
            }
        }
        if hit.kind == PathHitKind::Via {
            occ.set_owner(0, cx, cy, me);
            occ.set_owner(1, cx, cy, me);
            if !occ.vias.iter().any(|(x, y, _)| *x == cx && *y == cy) {
                occ.vias.push((cx, cy, me));
            }
        } else {
            occ.set_owner(hit.layer, cx, cy, me);
        }
        prev = Some((cx, cy, hit.layer));
    }
}

/// Reusable search arrays with generation stamps (no per-net re-zeroing).
struct Scratch {
    gen: u32,
    stamp: Vec<u32>,
    best: Vec<i32>,
    parent: Vec<u32>,
    cols: i32,
}

impl Scratch {
    fn new(occ: &Occupancy) -> Self {
        let n = (occ.cols * occ.rows) as usize * LAYERS * HEADINGS;
        Self { gen: 0, stamp: vec![0; n], best: vec![i32::MAX; n], parent: vec![u32::MAX; n], cols: occ.cols }
    }

    fn key(&self, x: i32, y: i32, l: u8, h: u8) -> usize {
        ((((y * self.cols + x) as usize) * LAYERS) + l as usize) * HEADINGS + h as usize
    }

    fn unkey(&self, k: usize) -> (i32, i32, u8, u8) {
        let h = (k % HEADINGS) as u8;
        let rest = k / HEADINGS;
        let l = (rest % LAYERS) as u8;
        let cell = rest / LAYERS;
        ((cell as i32) % self.cols, (cell as i32) / self.cols, l, h)
    }

    fn get(&self, k: usize) -> i32 {
        if self.stamp[k] == self.gen {
            self.best[k]
        } else {
            i32::MAX
        }
    }

    fn set(&mut self, k: usize, g: i32, parent: u32) {
        self.stamp[k] = self.gen;
        self.best[k] = g;
        self.parent[k] = parent;
    }
}

#[derive(Copy, Clone, Eq, PartialEq)]
struct Node {
    f: i32,
    g: i32,
    x: i32,
    y: i32,
    layer: u8,
    heading: u8,
}

impl Ord for Node {
    fn cmp(&self, other: &Self) -> Ordering {
        // Min-heap on f, then g, then an explicit total order for determinism.
        other
            .f
            .cmp(&self.f)
            .then_with(|| other.g.cmp(&self.g))
            .then_with(|| other.x.cmp(&self.x))
            .then_with(|| other.y.cmp(&self.y))
            .then_with(|| other.layer.cmp(&self.layer))
            .then_with(|| other.heading.cmp(&self.heading))
    }
}

impl PartialOrd for Node {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

const DIRS: [(i32, i32); 4] = [(1, 0), (-1, 0), (0, 1), (0, -1)];

/// What a search is trying to reach.
#[derive(Clone, Copy)]
enum Goal<'a> {
    /// One specific pad: A* with the Manhattan heuristic.
    Pad(&'a Terminal),
    /// Any cell of the net's joined tree: Dijkstra.
    Tree,
}

/// A* from `from` to `goal`. Returns the cell chain from `from` to the
/// reached cell, inclusive, or None when unreachable or over budget.
fn search(
    occ: &Occupancy,
    scratch: &mut Scratch,
    from: &Terminal,
    goal: Goal<'_>,
    joined: &[[u8; 2]],
    me: u32,
) -> Option<Vec<(i32, i32, u8)>> {
    scratch.gen = scratch.gen.wrapping_add(1);
    if scratch.gen == 0 {
        scratch.stamp.iter_mut().for_each(|s| *s = 0);
        scratch.gen = 1;
    }
    let (sx, sy) = (occ.cell(from.x_um), occ.cell(from.y_um));
    if !occ.in_bounds(sx, sy) {
        return None;
    }
    let target = match goal {
        Goal::Pad(t) => Some((occ.cell(t.x_um), occ.cell(t.y_um), t.through, t.layer)),
        Goal::Tree => None,
    };
    let h = |x: i32, y: i32| -> i32 {
        match target {
            Some((tx, ty, _, _)) => (x - tx).abs() + (y - ty).abs(),
            None => 0,
        }
    };
    let mut heap = BinaryHeap::new();
    let start_layers: Vec<u8> = if from.through { vec![0, 1] } else { vec![from.layer] };
    for l in start_layers {
        let k = scratch.key(sx, sy, l, 4);
        scratch.set(k, 0, u32::MAX);
        heap.push(Node { f: h(sx, sy), g: 0, x: sx, y: sy, layer: l, heading: 4 });
    }
    let mut expansions = 0usize;
    while let Some(Node { g, x, y, layer, heading, .. }) = heap.pop() {
        let k = scratch.key(x, y, layer, heading);
        if scratch.get(k) < g {
            continue;
        }
        let at_start = x == sx && y == sy;
        let reached = match target {
            Some((tx, ty, through, tl)) => x == tx && y == ty && (through || layer == tl),
            None => !at_start && joined[occ.idx(x, y)][layer as usize] != 0,
        };
        if reached {
            return Some(rebuild(scratch, k));
        }
        expansions += 1;
        if expansions > SEARCH_BUDGET {
            return None;
        }
        for (d, (dx, dy)) in DIRS.iter().enumerate() {
            let (nx, ny) = (x + dx, y + dy);
            if !occ.passable(layer, nx, ny, me) {
                continue;
            }
            let bend = if heading != 4 && heading != d as u8 { BEND_COST } else { 0 };
            let ng = g + 1 + bend;
            let nk = scratch.key(nx, ny, layer, d as u8);
            if ng < scratch.get(nk) {
                scratch.set(nk, ng, k as u32);
                heap.push(Node { f: ng + h(nx, ny), g: ng, x: nx, y: ny, layer, heading: d as u8 });
            }
        }
        let other = 1 - layer;
        if occ.passable(other, x, y, me) && occ.via_ok(x, y, me) {
            let ng = g + VIA_COST;
            let nk = scratch.key(x, y, other, 4);
            if ng < scratch.get(nk) {
                scratch.set(nk, ng, k as u32);
                heap.push(Node { f: ng + h(x, y), g: ng, x, y, layer: other, heading: 4 });
            }
        }
    }
    None
}

fn rebuild(scratch: &Scratch, goal_key: usize) -> Vec<(i32, i32, u8)> {
    let mut chain = Vec::new();
    let mut k = goal_key;
    loop {
        let (x, y, l, _) = scratch.unkey(k);
        if chain.last() != Some(&(x, y, l)) {
            chain.push((x, y, l));
        }
        let p = scratch.parent[k];
        if p == u32::MAX {
            break;
        }
        k = p as usize;
    }
    chain.reverse();
    chain
}

/// Cells → hits: exact pad µm at both ends when the end is a pad, cell
/// centres at bends and vias, straight runs compressed.
fn build_path(occ: &Occupancy, cells: &[(i32, i32, u8)], from: &Terminal, to_pad: Option<&Terminal>, net: &str, k: usize) -> Path {
    let mut hits: Vec<Hit> = Vec::new();
    let n = cells.len();
    for (i, &(x, y, l)) in cells.iter().enumerate() {
        let is_first = i == 0;
        let is_last = i + 1 == n;
        let via_here = i > 0 && cells[i - 1].2 != l;
        let bend = i > 0 && i + 1 < n && {
            let (px, py, _) = cells[i - 1];
            let (nx, ny, nl) = cells[i + 1];
            nl != l || (nx - x, ny - y) != (x - px, y - py)
        };
        if !(is_first || is_last || via_here || bend) {
            continue;
        }
        let (mut x_um, mut y_um) = (occ.cell_um(x), occ.cell_um(y));
        if is_first {
            x_um = from.x_um;
            y_um = from.y_um;
        } else if is_last {
            if let Some(t) = to_pad {
                if occ.cell(t.x_um) == x && occ.cell(t.y_um) == y {
                    x_um = t.x_um;
                    y_um = t.y_um;
                }
            }
        }
        hits.push(Hit { x_um, y_um, layer: l, kind: if via_here { PathHitKind::Via } else { PathHitKind::Trace } });
    }
    Path { net: net.to_string(), hits, id: format!("{net}#{k}") }
}

/// Incremental routing: keep the previous paths of nets that are not dirty.
/// A net is dirty when it touches a changed part or when one of its previous
/// paths crosses the keep-out of a changed part's body.
pub fn route_incremental(design: &Design, previous: &RouteResult, changed_parts: &[String]) -> Result<RouteResult, PackError> {
    let circuit = resolve(design)?;
    let template = design.template()?;
    let bodies = scene(design)?;
    let nets: Vec<Net> = circuit.nets.iter().map(|n| Net { id: n.id.clone(), pins: n.pins.clone(), class: n.class }).collect();
    let terminals = terminals_for(&circuit.pins, &bodies);
    let mut dirty: BTreeSet<String> = BTreeSet::new();
    let changed: BTreeSet<&str> = changed_parts.iter().map(String::as_str).collect();
    for n in &nets {
        if n.pins.iter().any(|p| p.rsplit_once('.').map(|(part, _)| changed.contains(part)).unwrap_or(false)) {
            dirty.insert(n.id.clone());
        }
    }
    let changed_rects: Vec<Rect> = bodies
        .iter()
        .filter(|b| changed.contains(b.id.as_str()))
        .map(|b| {
            let (x0, x1, y0, y1) = expanded_aabb(b);
            Rect { x0, y0, x1, y1 }
        })
        .collect();
    for p in &previous.paths {
        if p.hits.iter().any(|h| changed_rects.iter().any(|r| r.contains(h.x_um, h.y_um))) {
            dirty.insert(p.net.clone());
        }
    }
    let live: BTreeSet<&str> = nets.iter().map(|n| n.id.as_str()).collect();
    let removed: Vec<String> = previous.nets.iter().filter(|n| !live.contains(n.id.as_str())).map(|n| n.id.clone()).collect();
    let mut out = route_nets(
        &nets,
        &terminals,
        &bodies,
        template.board_w_um,
        template.board_d_um,
        Some(Keep { paths: &previous.paths, dirty_nets: &dirty }),
    );
    out.removed_nets = removed;
    Ok(out)
}

/// Z of a hit for painting, from its layer.
pub fn hit_z_um(layer: u8) -> i64 {
    copper_z(if layer == 0 { Side::Top } else { Side::Bottom })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::export::compile;
    use crate::net::pins_for;
    use crate::template::Design;
    use crate::DEFAULT_GAP_UM;
    use std::time::Instant;

    fn body(id: &str, x: i64, y: i64, sx: i64, sy: i64, side: Side) -> Body {
        Body {
            id: id.into(),
            role: "test".into(),
            support: "board".into(),
            library: None,
            note: String::new(),
            material: "ceramic".into(),
            x_um: x,
            y_um: y,
            z_um: 0,
            sx_um: sx,
            sy_um: sy,
            sz_um: 1_000,
            yaw_q: 0,
            side,
            refdes: None,
        }
    }

    fn term(pin: &str, x: i64, y: i64, layer: u8) -> (String, Terminal) {
        (pin.into(), Terminal { pin: pin.into(), x_um: x, y_um: y, layer, through: false })
    }

    fn signal(id: &str, pins: &[&str]) -> Net {
        Net { id: id.into(), pins: pins.iter().map(|p| p.to_string()).collect(), class: NetClass::Signal }
    }

    #[test]
    fn a_two_pad_net_routes_straight_with_exact_endpoints() {
        let terminals: BTreeMap<_, _> = [term("a.1", 1_120, 5_080, 0), term("b.1", 9_130, 5_080, 0)].into_iter().collect();
        let r = route_nets(&[signal("S", &["a.1", "b.1"])], &terminals, &[], 10_000, 10_000, None);
        assert!(r.errors.is_empty(), "{:?}", r.errors);
        assert_eq!(r.paths.len(), 1);
        let hits = &r.paths[0].hits;
        assert_eq!((hits[0].x_um, hits[0].y_um), (1_120, 5_080), "starts on the exact pad");
        let last = hits.last().unwrap();
        assert_eq!((last.x_um, last.y_um), (9_130, 5_080), "ends on the exact pad");
        assert_eq!(hits.len(), 2, "a straight run is two hits, not one per cell");
        assert!(hits.iter().all(|h| h.kind == PathHitKind::Trace && h.layer == 0));
        assert_eq!(r.paths[0].id, "S#0");
        assert_eq!(r.changed_nets, vec!["S".to_string()]);
    }

    #[test]
    fn a_body_blocks_only_its_own_layer_and_the_router_takes_the_bottom() {
        // Wall across the whole board on top; nothing on the bottom.
        let wall = body("wall", 5_000, 5_000, 400, 20_000, Side::Top);
        let terminals: BTreeMap<_, _> = [term("a.1", 1_000, 5_000, 0), term("b.1", 9_000, 5_000, 0)].into_iter().collect();
        let r = route_nets(&[signal("S", &["a.1", "b.1"])], &terminals, &[wall.clone()], 10_000, 10_000, None);
        assert!(r.errors.is_empty(), "{:?}", r.errors);
        let hits = &r.paths[0].hits;
        assert!(hits.iter().any(|h| h.kind == PathHitKind::Via), "must via to the bottom to pass the wall");
        assert!(hits.iter().any(|h| h.layer == 1));
        // Same wall on the bottom too: unroutable, reported, not hung.
        let mut bottom = wall.clone();
        bottom.id = "wall_b".into();
        bottom.side = Side::Bottom;
        let r2 = route_nets(&[signal("S", &["a.1", "b.1"])], &terminals, &[wall, bottom], 10_000, 10_000, None);
        assert!(r2.paths.is_empty());
        assert!(r2.errors.iter().any(|e| e.kind == NetErrorKind::Unroutable));
    }

    #[test]
    fn two_nets_cannot_cross_on_one_layer_and_pads_of_others_are_obstacles() {
        // A horizontal and a vertical net crossing in the middle.
        let terminals: BTreeMap<_, _> = [
            term("a.1", 1_000, 5_000, 0),
            term("b.1", 9_000, 5_000, 0),
            term("c.1", 5_000, 1_000, 0),
            term("d.1", 5_000, 9_000, 0),
        ]
        .into_iter()
        .collect();
        let nets = [signal("H", &["a.1", "b.1"]), signal("V", &["c.1", "d.1"])];
        let r = route_nets(&nets, &terminals, &[], 10_000, 10_000, None);
        assert!(r.errors.is_empty(), "{:?}", r.errors);
        assert_eq!(r.paths.len(), 2);
        // Reserved copper of the two nets never shares a (cell, layer).
        let mut occ = Occupancy::new(10_000, 10_000);
        let mut seen: BTreeMap<(i32, i32, u8), String> = BTreeMap::new();
        for p in &r.paths {
            let me = if p.net == "H" { 1 } else { 2 };
            let before = occ.clone();
            reserve_path(&mut occ, p, me);
            for l in 0..2u8 {
                for y in 0..occ.rows {
                    for x in 0..occ.cols {
                        if occ.owner(l, x, y) != 0 && before.owner(l, x, y) == 0 {
                            if let Some(other) = seen.insert((x, y, l), p.net.clone()) {
                                panic!("{} and {} share cell {x},{y} layer {l}", other, p.net);
                            }
                        }
                    }
                }
            }
        }
        assert!(r.paths.iter().any(|p| p.hits.iter().any(|h| h.kind == PathHitKind::Via)), "one net must via around the other");
        // A pad that belongs to no net is an obstacle: route around it.
        let mut with_stray = terminals.clone();
        with_stray.insert("stray.1".into(), Terminal { pin: "stray.1".into(), x_um: 3_000, y_um: 5_000, layer: 0, through: false });
        let r3 = route_nets(&[signal("H", &["a.1", "b.1"])], &with_stray, &[], 10_000, 10_000, None);
        assert!(r3.errors.is_empty());
        assert!(r3.paths[0].hits.len() > 2, "detour around the stray pad");
    }

    #[test]
    fn a_three_terminal_net_joins_the_existing_tree_once() {
        let terminals: BTreeMap<_, _> = [term("a.1", 1_000, 5_000, 0), term("b.1", 9_000, 5_000, 0), term("c.1", 5_000, 9_000, 0)]
            .into_iter()
            .collect();
        let r = route_nets(&[signal("T", &["a.1", "b.1", "c.1"])], &terminals, &[], 10_000, 10_000, None);
        assert!(r.errors.is_empty(), "{:?}", r.errors);
        assert_eq!(r.paths.len(), 2, "two segments for three terminals");
        let join = &r.paths[1];
        assert_eq!((join.hits[0].x_um, join.hits[0].y_um), (5_000, 9_000));
        // The join lands on the first segment's row (y = 5000 cell), not at a pad.
        let end = join.hits.last().unwrap();
        assert_eq!(end.y_um, 5_125, "joined the H run at its cell centre row");
    }

    #[test]
    fn routing_is_deterministic_and_within_budget_on_a_mini_itx_grid() {
        // 32 parallel two-pad nets across the real Mini-ITX body set: the
        // plan's "declared small dirty-route batch" shape.
        let bodies = scene(&Design::mini_itx().unwrap()).unwrap();
        let clear = |x: i64, y: i64| {
            bodies.iter().filter(|b| b.id != "pcb" && b.id != "shield").all(|b| {
                let (x0, x1, y0, y1) = expanded_aabb(b);
                !(x >= x0 && x <= x1 && y >= y0 && y <= y1)
            })
        };
        let mut terminals = BTreeMap::new();
        let mut nets = Vec::new();
        let mut x = 6_000i64;
        while nets.len() < 32 {
            assert!(x < 170_000, "fixture ran out of free columns");
            let (ya, yb) = (20_000, 150_000);
            if clear(x, ya) && clear(x, yb) {
                let i = nets.len();
                let a = format!("p{i}.a");
                let b = format!("p{i}.b");
                terminals.insert(a.clone(), Terminal { pin: a.clone(), x_um: x, y_um: ya, layer: 0, through: false });
                terminals.insert(b.clone(), Terminal { pin: b.clone(), x_um: x, y_um: yb, layer: 0, through: false });
                nets.push(signal(&format!("N{i:02}"), &[&a, &b]));
            }
            x += 2_000;
        }
        let t0 = Instant::now();
        let r1 = route_nets(&nets, &terminals, &bodies, 170_000, 170_000, None);
        let ms = t0.elapsed().as_millis();
        let r2 = route_nets(&nets, &terminals, &bodies, 170_000, 170_000, None);
        assert_eq!(serde_json::to_string(&r1).unwrap(), serde_json::to_string(&r2).unwrap());
        assert_eq!(r1.paths.len(), 32, "{:?}", r1.errors);
        // Debug builds are an order of magnitude slower than the release
        // binary the hosts load; the release budget is the plan's 100 ms.
        let budget = if cfg!(debug_assertions) { 8_000 } else { 400 };
        assert!(ms < budget, "32 nets on the 680x680 grid took {ms} ms (budget {budget})");
    }

    #[test]
    fn crossing_nets_are_deterministic_and_each_gets_a_verdict() {
        // Eight mutually crossing nets: adversarial for two layers, must
        // terminate with a path or an Unroutable per net, identically twice.
        let mut terminals = BTreeMap::new();
        let mut nets = Vec::new();
        for i in 0..8i64 {
            let a = format!("p{i}.a");
            let b = format!("p{i}.b");
            terminals.insert(a.clone(), Terminal { pin: a.clone(), x_um: 2_000 + i * 2_000, y_um: 2_000, layer: 0, through: false });
            terminals.insert(b.clone(), Terminal { pin: b.clone(), x_um: 2_000 + (7 - i) * 2_000, y_um: 18_000, layer: 0, through: false });
            nets.push(signal(&format!("X{i}"), &[&a, &b]));
        }
        let r1 = route_nets(&nets, &terminals, &[], 20_000, 20_000, None);
        let r2 = route_nets(&nets, &terminals, &[], 20_000, 20_000, None);
        assert_eq!(serde_json::to_string(&r1).unwrap(), serde_json::to_string(&r2).unwrap());
        assert_eq!(r1.paths.len() + r1.errors.len(), 8);
        assert!(r1.paths.len() >= 6, "two layers should carry most of eight crossings: {:?}", r1.errors);
    }

    #[test]
    fn incremental_keeps_untouched_paths_and_recomputes_crossed_ones() {
        let terminals: BTreeMap<_, _> = [
            term("a.1", 1_000, 2_000, 0),
            term("b.1", 9_000, 2_000, 0),
            term("c.1", 1_000, 8_000, 0),
            term("d.1", 9_000, 8_000, 0),
        ]
        .into_iter()
        .collect();
        let nets = [signal("LOW", &["a.1", "b.1"]), signal("HIGH", &["c.1", "d.1"])];
        let first = route_nets(&nets, &terminals, &[], 10_000, 10_000, None);
        assert_eq!(first.paths.len(), 2);
        // A part moves onto the LOW run: LOW is dirty, HIGH is kept byte-for-byte.
        let mover = body("mover", 5_000, 2_000, 1_000, 1_000, Side::Top);
        let dirty: BTreeSet<String> = ["LOW".to_string()].into_iter().collect();
        let second = route_nets(&nets, &terminals, &[mover], 10_000, 10_000, Some(Keep { paths: &first.paths, dirty_nets: &dirty }));
        let high_before = first.paths.iter().find(|p| p.net == "HIGH").unwrap();
        let high_after = second.paths.iter().find(|p| p.net == "HIGH").unwrap();
        assert_eq!(high_before, high_after);
        let low_after = second.paths.iter().find(|p| p.net == "LOW").unwrap();
        assert!(low_after.hits.len() > 2, "LOW detoured around the mover");
        assert_eq!(second.changed_nets, vec!["LOW".to_string()]);
    }

    #[test]
    fn design_level_incremental_marks_dirty_by_part_and_by_crossing() {
        let design = Design::mini_itx().unwrap();
        let first = route(&design).unwrap();
        assert!(first.paths.is_empty(), "no production footprint has pad XY yet");
        let again = route_incremental(&design, &first, &["usb0".into()]).unwrap();
        assert!(again.removed_nets.is_empty());
        assert!(again.nets.iter().any(|n| n.id == "P12V"));
    }

    #[test]
    fn power_edge_neighbours_keep_a_quarter_millimetre_corridor() {
        let bundle = compile(&Design::mini_itx().unwrap()).unwrap();
        let bodies: Vec<Body> = serde_json::from_value(bundle.scene).unwrap();
        let mut power: Vec<_> = bodies.iter().filter(|b| matches!(b.role.as_str(), "spi_flash" | "vtt" | "decap")).collect();
        power.sort_by_key(|b| b.x_um);
        assert!(power.len() >= 2);
        let mut saw = false;
        for pair in power.windows(2) {
            let Some(gap) = corridor_x_um(pair[0], pair[1]) else { continue };
            saw = true;
            assert!(gap >= GRID_UM, "{} vs {} corridor {gap} µm", pair[0].id, pair[1].id);
            assert!(gap < DEFAULT_GAP_UM, "occupancy must use trace keep-out, not pack gap");
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
        let _ = crate::net::auto_connect(&design);
        let mut best = u128::MAX;
        for _ in 0..8 {
            let start = Instant::now();
            let nets = crate::net::auto_connect(&design);
            best = best.min(start.elapsed().as_micros());
            assert!(!nets.is_empty());
        }
        assert!(best < 1_000, "membership took {best} µs");
    }

    #[test]
    fn hit_layers_map_to_copper_planes() {
        assert_eq!(hit_z_um(0), 1_600);
        assert_eq!(hit_z_um(1), 0);
    }
}
