// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Bounded SVG rasterizer over a `g6b_dom::Node` subtree.
//
// This is not an SVG implementation — it is the smallest honest subset that
// covers icon art and simple panels: `rect`, `circle`, `ellipse`, `line`,
// `polyline`, `polygon`, `path` (M L H V C Q S T Z), `g`/`svg` nesting with a
// 2×3 affine `transform`, `use href="#id"`, `viewBox` scaling, and the
// `fill`/`stroke`/`stroke-width`/`*-opacity`/`opacity`/`color` presentation
// attributes. `defs`, gradients, filters, clipping, text and `arc` (A)
// commands are *skipped*, never silently approximated. Everything flattens
// to polygons and rasterizes with a scanline even-odd fill — hard edges, no
// anti-aliasing — which is the honest budget for a BIOS surface.

#![allow(missing_docs)]

use g6b_dom::Node;
use g6b_gr::canvas32::{Canvas32, Rgba};
use g6b_gr::color::{parse_opacity, parse_rgba, parse_rgba_current};

pub const MAX_SVG_NODES: usize = 512;
pub const MAX_PATH_CMDS: usize = 4096;
pub const MAX_POINTS: usize = 16384;
pub const MAX_DEPTH: usize = 32;
const CURVE_STEPS: u32 = 12;

#[derive(Debug, Clone, PartialEq)]
pub enum SvgError {
    Empty,
    Unsupported(&'static str),
    Budget,
}

impl std::fmt::Display for SvgError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Empty => write!(f, "empty svg"),
            Self::Unsupported(w) => write!(f, "unsupported svg: {w}"),
            Self::Budget => write!(f, "svg resource budget exceeded"),
        }
    }
}

impl std::error::Error for SvgError {}

type R<T> = Result<T, SvgError>;

/// A presentation-attribute resolver: first argument the node, second the
/// property name. The CSS lane passes a closure reading computed style then
/// the attribute; a plain `|n, k| n.get_attribute(k)` works for DOM-only art.
pub type Style<'a> = &'a dyn Fn(&Node, &str) -> Option<String>;

fn attr_style(node: &Node, key: &str) -> Option<String> {
    node.get_attribute(key).map(str::to_string)
}

/// Rasterize an `<svg>` subtree into a fresh `w`×`h` transparent image.
pub fn raster(node: &Node, w: u32, h: u32) -> R<RgbaImage> {
    raster_styled(node, w, h, &attr_style)
}

/// Same with a style resolver (the CSS render lane passes its cascade here).
pub fn raster_styled(node: &Node, w: u32, h: u32, style: Style<'_>) -> R<RgbaImage> {
    let mut c = Canvas32::new(w, h);
    paint(&mut c, node, 0, 0, w as i32, h as i32, 255, style)?;
    Ok(RgbaImage {
        w,
        h,
        rgba: c.pixels().to_vec(),
    })
}

use crate::RgbaImage;

/// Paint an `<svg>` subtree onto `cvs` inside the box `(x, y, w, h)`.
#[allow(clippy::too_many_arguments)]
pub fn paint(
    cvs: &mut Canvas32,
    node: &Node,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    alpha: u8,
    style: Style<'_>,
) -> R<()> {
    if node.name != "svg" {
        return Err(SvgError::Unsupported("root element is not <svg>"));
    }
    if w <= 0 || h <= 0 {
        return Ok(());
    }
    let vb = view_box(node, w, h);
    let m = viewport_map(vb, w, h);
    let mut st = State {
        nodes: 0,
        points: 0,
        root: node,
    };
    let ctx = Ctx {
        fill: Some([0, 0, 0, 255]),
        fill_opacity: 255,
        stroke: None,
        stroke_w: 1.0,
        stroke_opacity: 255,
        opacity: alpha,
        color: [0, 0, 0, 255],
    };
    let mut t = Transform::translate(x as f32, y as f32).then(m);
    let outer = clip(node, w, h);
    walk(cvs, node, &ctx, &mut t, &mut st, style, 0, outer);
    Ok(())
}

/// viewBox → `[min_x, min_y, w, h]`; absent → the element box.
fn view_box(node: &Node, w: i32, h: i32) -> [f32; 4] {
    let vb = node
        .get_attribute("viewBox")
        .or_else(|| node.get_attribute("viewbox"));
    if let Some(v) = vb {
        let nums = numbers(v);
        if nums.len() >= 4 && nums[2] > 0.0 && nums[3] > 0.0 {
            return [nums[0], nums[1], nums[2], nums[3]];
        }
    }
    [0.0, 0.0, w.max(0) as f32, h.max(0) as f32]
}

/// `xMidYMid meet` — the default preserveAspectRatio.
fn viewport_map(vb: [f32; 4], w: i32, h: i32) -> Transform {
    let sx = w as f32 / vb[2].max(1e-6);
    let sy = h as f32 / vb[3].max(1e-6);
    let s = sx.min(sy);
    let dx = (w as f32 - vb[2] * s) / 2.0;
    let dy = (h as f32 - vb[3] * s) / 2.0;
    Transform::translate(dx, dy)
        .then(Transform::scale(s, s))
        .then(Transform::translate(-vb[0], -vb[1]))
}

/// `clip="..."/overflow` on the outer svg — we always clip to the box.
fn clip(_node: &Node, w: i32, h: i32) -> (i32, i32, i32, i32) {
    (0, 0, w, h)
}

// ---------------------------------------------------------------------------
// geometry
// ---------------------------------------------------------------------------

/// 2×3 affine `[a b c d e f]`: x' = a·x + c·y + e, y' = b·x + d·y + f.
#[derive(Debug, Clone, Copy, PartialEq)]
struct Transform([f32; 6]);

impl Transform {
    fn identity() -> Self {
        Self([1.0, 0.0, 0.0, 1.0, 0.0, 0.0])
    }
    fn translate(x: f32, y: f32) -> Self {
        Self([1.0, 0.0, 0.0, 1.0, x, y])
    }
    fn scale(x: f32, y: f32) -> Self {
        Self([x, 0.0, 0.0, y, 0.0, 0.0])
    }
    fn rotate_origin(deg: f32) -> Self {
        let r = deg.to_radians();
        let (s, c) = r.sin_cos();
        Self([c, s, -s, c, 0.0, 0.0])
    }
    /// `self` followed by `other` (other applied first to user coords).
    fn then(&self, o: Transform) -> Transform {
        let [a, b, c, d, e, f] = self.0;
        let [g, h, i, j, k, l] = o.0;
        Transform([
            a * g + c * h,
            b * g + d * h,
            a * i + c * j,
            b * i + d * j,
            a * k + c * l + e,
            b * k + d * l + f,
        ])
    }
    fn point(&self, x: f32, y: f32) -> (f32, f32) {
        let [a, b, c, d, e, f] = self.0;
        (a * x + c * y + e, b * x + d * y + f)
    }
    /// Approximate uniform scale factor for stroke width.
    fn scale_factor(&self) -> f32 {
        let [a, b, c, d, _, _] = self.0;
        ((a * a + b * b).sqrt() + (c * c + d * d).sqrt()) / 2.0
    }
}

fn parse_transform(value: &str) -> Transform {
    let mut t = Transform::identity();
    let mut rest = value.trim();
    while let Some(open) = rest.find('(') {
        let name = rest[..open].trim().to_ascii_lowercase();
        let Some(close) = rest[open..].find(')') else {
            break;
        };
        let args = numbers(&rest[open + 1..open + close]);
        let m = match name.as_str() {
            "translate" => Transform::translate(
                args.first().copied().unwrap_or(0.0),
                args.get(1).copied().unwrap_or(0.0),
            ),
            "scale" => {
                let sx = args.first().copied().unwrap_or(1.0);
                Transform::scale(sx, args.get(1).copied().unwrap_or(sx))
            }
            "rotate" => {
                let deg = args.first().copied().unwrap_or(0.0);
                if args.len() >= 3 {
                    Transform::translate(args[1], args[2])
                        .then(Transform::rotate_origin(deg))
                        .then(Transform::translate(-args[1], -args[2]))
                } else {
                    Transform::rotate_origin(deg)
                }
            }
            "matrix" if args.len() >= 6 => {
                Transform([args[0], args[1], args[2], args[3], args[4], args[5]])
            }
            _ => Transform::identity(), // skew/unknown: ignored, not misparsed
        };
        t = t.then(m);
        rest = &rest[open + close + 1..];
    }
    t
}

/// Whitespace/comma-separated numbers.
fn numbers(s: &str) -> Vec<f32> {
    s.split(|c: char| c.is_ascii_whitespace() || c == ',')
        .filter_map(|p| {
            let p = p.trim();
            if p.is_empty() {
                None
            } else {
                p.parse::<f32>().ok()
            }
        })
        .collect()
}

// ---------------------------------------------------------------------------
// paint state
// ---------------------------------------------------------------------------

#[derive(Clone, Copy)]
struct Ctx {
    fill: Option<Rgba>,
    fill_opacity: u8,
    stroke: Option<Rgba>,
    stroke_w: f32,
    stroke_opacity: u8,
    opacity: u8,
    color: Rgba,
}

impl Ctx {
    fn inherit(&self, node: &Node, style: Style<'_>) -> Self {
        let mut c = *self;
        let get = |k: &str| style(node, k).or_else(|| node.get_attribute(k).map(str::to_string));
        if let Some(v) = get("color") {
            if let Some(rgb) = parse_rgba(&v) {
                c.color = rgb;
            }
        }
        if let Some(v) = get("fill") {
            c.fill = parse_rgba_current(&v, c.color).filter(|c| c[3] != 0);
        }
        if let Some(v) = get("fill-opacity") {
            if let Some(a) = parse_opacity(&v) {
                c.fill_opacity = a;
            }
        }
        if let Some(v) = get("stroke") {
            c.stroke = parse_rgba_current(&v, c.color).filter(|c| c[3] != 0);
        }
        if let Some(v) = get("stroke-width") {
            if let Ok(n) = v.trim().trim_end_matches("px").parse::<f32>() {
                c.stroke_w = n.max(0.0);
            }
        }
        if let Some(v) = get("stroke-opacity") {
            if let Some(a) = parse_opacity(&v) {
                c.stroke_opacity = a;
            }
        }
        if let Some(v) = get("opacity") {
            if let Some(a) = parse_opacity(&v) {
                c.opacity = Canvas32::mul_alpha(c.opacity, a);
            }
        }
        c
    }

    fn fill_paint(&self) -> Option<Rgba> {
        self.fill.map(|c| {
            let c = Canvas32::with_alpha(c, self.fill_opacity);
            Canvas32::with_alpha(c, self.opacity)
        })
    }
    fn stroke_paint(&self) -> Option<Rgba> {
        self.stroke.map(|c| {
            let c = Canvas32::with_alpha(c, self.stroke_opacity);
            Canvas32::with_alpha(c, self.opacity)
        })
    }
}

struct State<'a> {
    nodes: usize,
    points: usize,
    root: &'a Node,
}

fn hidden(node: &Node, style: Style<'_>) -> bool {
    if node.hidden {
        return true;
    }
    let v = style(node, "display").or_else(|| node.get_attribute("display").map(str::to_string));
    if v.as_deref().map(str::trim) == Some("none") {
        return true;
    }
    let v =
        style(node, "visibility").or_else(|| node.get_attribute("visibility").map(str::to_string));
    matches!(
        v.as_deref().map(str::trim),
        Some("hidden") | Some("collapse")
    )
}

#[allow(clippy::too_many_arguments)]
fn walk(
    cvs: &mut Canvas32,
    node: &Node,
    ctx: &Ctx,
    t: &mut Transform,
    st: &mut State<'_>,
    style: Style<'_>,
    depth: usize,
    clip: (i32, i32, i32, i32),
) {
    if depth > MAX_DEPTH {
        return;
    }
    for child in &node.children {
        if st.nodes >= MAX_SVG_NODES {
            return;
        }
        st.nodes += 1;
        if child.name == "#text" || hidden(child, style) {
            continue;
        }
        match child.name.as_str() {
            "svg" | "g" | "a" | "symbol" => {
                if child.name == "symbol" {
                    continue; // only painted via <use>
                }
                let c2 = ctx.inherit(child, style);
                let mut t2 = *t;
                if let Some(v) = style(child, "transform")
                    .or_else(|| child.get_attribute("transform").map(str::to_string))
                {
                    t2 = t2.then(parse_transform(&v));
                }
                // Nested <svg> re-establishes a viewport.
                if child.name == "svg" {
                    let (x, y, w, h) = svg_child_box(child, style);
                    let vb = view_box(child, w, h);
                    t2 = t2.then(Transform::translate(x as f32, y as f32));
                    t2 = t2.then(viewport_map(vb, w, h));
                }
                walk(cvs, child, &c2, &mut t2, st, style, depth + 1, clip);
            }
            "use" => {
                let href = child
                    .get_attribute("href")
                    .or_else(|| child.get_attribute("xlink:href"))
                    .unwrap_or_default();
                if let Some(id) = href.strip_prefix('#') {
                    if let Some(target) = find_id(st.root, id) {
                        // The referenced element's own presentation attributes
                        // win over the <use> element's inherited ones.
                        let mut c2 = ctx.inherit(child, style).inherit(target, style);
                        let mut t2 = *t;
                        let x = num_attr(child, "x", 0.0);
                        let y = num_attr(child, "y", 0.0);
                        t2 = t2.then(Transform::translate(x, y));
                        if let Some(v) = child.get_attribute("transform").map(str::to_string) {
                            t2 = t2.then(parse_transform(&v));
                        }
                        // Paint the referenced subtree as a group.
                        let mut fake;
                        let ref_node = if target.name == "symbol" {
                            fake = Node::elem("g");
                            fake.children = target.children.clone();
                            &fake
                        } else {
                            target
                        };
                        shape(cvs, ref_node, &mut c2, &mut t2, st, style, clip);
                        walk(cvs, ref_node, &c2, &mut t2, st, style, depth + 1, clip);
                    }
                }
            }
            "defs" | "title" | "desc" | "metadata" | "style" | "script" | "lineargradient"
            | "radialgradient" | "clippath" | "mask" | "pattern" | "filter" | "marker" | "text"
            | "tspan" | "image" => {
                // Skipped by contract: defs-content and paint servers we do
                // not implement must not leak stray geometry.
            }
            _ => {
                let mut c2 = ctx.inherit(child, style);
                let mut t2 = *t;
                if let Some(v) = style(child, "transform")
                    .or_else(|| child.get_attribute("transform").map(str::to_string))
                {
                    t2 = t2.then(parse_transform(&v));
                }
                shape(cvs, child, &mut c2, &mut t2, st, style, clip);
            }
        }
    }
}

fn svg_child_box(node: &Node, style: Style<'_>) -> (i32, i32, i32, i32) {
    let n = |k: &str, d: f32| -> f32 {
        style(node, k)
            .or_else(|| node.get_attribute(k).map(str::to_string))
            .and_then(|v| v.trim().trim_end_matches("px").parse().ok())
            .unwrap_or(d)
    };
    let x = n("x", 0.0);
    let y = n("y", 0.0);
    (
        x as i32,
        y as i32,
        n("width", 0.0) as i32,
        n("height", 0.0) as i32,
    )
}

fn find_id<'a>(node: &'a Node, id: &str) -> Option<&'a Node> {
    if node.id.as_deref() == Some(id) {
        return Some(node);
    }
    node.children.iter().find_map(|c| find_id(c, id))
}

fn num_attr(node: &Node, k: &str, d: f32) -> f32 {
    node.get_attribute(k)
        .and_then(|v| v.trim().trim_end_matches("px").parse().ok())
        .unwrap_or(d)
}

// ---------------------------------------------------------------------------
// shape → polygon flatten + raster
// ---------------------------------------------------------------------------

fn shape(
    cvs: &mut Canvas32,
    node: &Node,
    ctx: &mut Ctx,
    t: &mut Transform,
    st: &mut State<'_>,
    _style: Style<'_>,
    clip: (i32, i32, i32, i32),
) {
    let mut polys: Vec<Vec<(f32, f32)>> = Vec::new();
    let mut open_stroke: Vec<Vec<(f32, f32)>> = Vec::new();
    match node.name.as_str() {
        "rect" => {
            let (x, y) = (num_attr(node, "x", 0.0), num_attr(node, "y", 0.0));
            let (w, h) = (num_attr(node, "width", 0.0), num_attr(node, "height", 0.0));
            let (rx, ry) = (
                num_attr(node, "rx", num_attr(node, "ry", 0.0)),
                num_attr(node, "ry", num_attr(node, "rx", 0.0)),
            );
            polys.push(round_rect(x, y, w, h, rx, ry));
        }
        "circle" => {
            let (cx, cy, r) = (
                num_attr(node, "cx", 0.0),
                num_attr(node, "cy", 0.0),
                num_attr(node, "r", 0.0),
            );
            polys.push(ellipse(cx, cy, r, r));
        }
        "ellipse" => {
            polys.push(ellipse(
                num_attr(node, "cx", 0.0),
                num_attr(node, "cy", 0.0),
                num_attr(node, "rx", 0.0),
                num_attr(node, "ry", 0.0),
            ));
        }
        "line" => {
            open_stroke.push(vec![
                (num_attr(node, "x1", 0.0), num_attr(node, "y1", 0.0)),
                (num_attr(node, "x2", 0.0), num_attr(node, "y2", 0.0)),
            ]);
        }
        "polyline" | "polygon" => {
            let nums = numbers(node.get_attribute("points").unwrap_or_default());
            let pts: Vec<(f32, f32)> = nums.chunks_exact(2).map(|p| (p[0], p[1])).collect();
            if node.name == "polygon" {
                polys.push(pts);
            } else {
                open_stroke.push(pts);
            }
        }
        "path" => {
            let (closed, open) = parse_path(node.get_attribute("d").unwrap_or_default());
            polys.extend(closed);
            open_stroke.extend(open);
        }
        _ => return, // unknown leaf: skipped, never misparsed
    }
    if st.points + polys.iter().map(Vec::len).sum::<usize>() > MAX_POINTS {
        return; // budget: skip the shape, keep rendering siblings
    }
    st.points += polys.iter().map(Vec::len).sum::<usize>();
    if let Some(c) = ctx.fill_paint() {
        for p in &polys {
            let tp: Vec<(f32, f32)> = p.iter().map(|&(x, y)| t.point(x, y)).collect();
            fill_poly(cvs, &tp, c, clip);
        }
    }
    if let Some(c) = ctx.stroke_paint() {
        let w = ctx.stroke_w * t.scale_factor();
        let stroke_polys = polys
            .iter()
            .map(|p| {
                let mut v: Vec<(f32, f32)> = p.iter().map(|&(x, y)| t.point(x, y)).collect();
                if let (Some(&f), Some(&l)) = (v.first(), v.last()) {
                    if f != l {
                        v.push(f);
                    }
                }
                v
            })
            .collect::<Vec<_>>();
        let open_t: Vec<Vec<(f32, f32)>> = open_stroke
            .iter()
            .map(|o| o.iter().map(|&(x, y)| t.point(x, y)).collect())
            .collect();
        for p in stroke_polys.iter().chain(open_t.iter()) {
            stroke_poly(cvs, p, w, c, clip);
        }
    }
}

fn round_rect(x: f32, y: f32, w: f32, h: f32, rx: f32, ry: f32) -> Vec<(f32, f32)> {
    if rx <= 0.0 || ry <= 0.0 {
        return vec![(x, y), (x + w, y), (x + w, y + h), (x, y + h)];
    }
    let rx = rx.min(w / 2.0);
    let ry = ry.min(h / 2.0);
    let mut pts = Vec::with_capacity(4 + 8 * 4);
    for &(cx, cy, a0) in &[
        (x + w - rx, y + ry, -90.0f32),
        (x + w - rx, y + h - ry, 0.0),
        (x + rx, y + h - ry, 90.0),
        (x + rx, y + ry, 180.0),
    ] {
        for i in 0..=6 {
            let a = (a0 + 90.0 * i as f32 / 6.0).to_radians();
            pts.push((cx + rx * a.cos(), cy + ry * a.sin()));
        }
    }
    pts
}

fn ellipse(cx: f32, cy: f32, rx: f32, ry: f32) -> Vec<(f32, f32)> {
    (0..32)
        .map(|i| {
            let a = std::f32::consts::TAU * i as f32 / 32.0;
            (cx + rx * a.cos(), cy + ry * a.sin())
        })
        .collect()
}

// ---------------------------------------------------------------------------
// path parsing (M L H V C S Q T Z, absolute + relative)
// ---------------------------------------------------------------------------

#[allow(clippy::type_complexity)]
fn parse_path(d: &str) -> (Vec<Vec<(f32, f32)>>, Vec<Vec<(f32, f32)>>) {
    let mut closed = Vec::new();
    let mut open = Vec::new();
    let mut cur: Vec<(f32, f32)> = Vec::new();
    let (mut x, mut y) = (0.0f32, 0.0f32);
    let (mut sx, mut sy) = (0.0f32, 0.0f32); // subpath start for Z
    let mut ctrl: Option<(f32, f32)> = None; // last control point for S/T
    let mut cmds = 0usize;

    let b = d.as_bytes();
    let mut i = 0usize;
    let skip = |i: &mut usize| {
        while *i < b.len() && (b[*i] as char).is_ascii_whitespace() || *i < b.len() && b[*i] == b','
        {
            *i += 1;
        }
    };
    let num = |i: &mut usize| -> Option<f32> {
        skip(i);
        let start = *i;
        if *i < b.len() && (b[*i] == b'-' || b[*i] == b'+') {
            *i += 1;
        }
        let mut seen_dot = false;
        let mut seen_exp = false;
        while *i < b.len() {
            let c = b[*i] as char;
            if c.is_ascii_digit() {
                *i += 1;
            } else if c == '.' && !seen_dot {
                seen_dot = true;
                *i += 1;
            } else if (c == 'e' || c == 'E') && !seen_exp && *i + 1 < b.len() {
                seen_exp = true;
                *i += 1;
                if b[*i] == b'-' || b[*i] == b'+' {
                    *i += 1;
                }
            } else {
                break;
            }
        }
        if start == *i {
            return None;
        }
        d[start..*i].parse().ok()
    };

    let mut cmd = ' ';
    while i < b.len() {
        skip(&mut i);
        if i >= b.len() {
            break;
        }
        let c = b[i] as char;
        if c.is_ascii_alphabetic() {
            cmd = c;
            i += 1;
        } else if cmd == 'M' {
            cmd = 'L'; // implicit lineto after first moveto pair
        } else if cmd == 'm' {
            cmd = 'l';
        }
        if cmds >= MAX_PATH_CMDS {
            break;
        }
        cmds += 1;
        let rel = cmd.is_ascii_lowercase();
        let cmdu = cmd.to_ascii_uppercase();
        let (px, py) = if rel { (x, y) } else { (0.0, 0.0) };
        match cmdu {
            'M' => {
                if let (Some(a), Some(b2)) = (num(&mut i), num(&mut i)) {
                    if !cur.is_empty() {
                        open.push(std::mem::take(&mut cur));
                    }
                    x = px + a;
                    y = py + b2;
                    sx = x;
                    sy = y;
                    cur.push((x, y));
                    ctrl = None;
                } else {
                    break;
                }
            }
            'L' => {
                if let (Some(a), Some(b2)) = (num(&mut i), num(&mut i)) {
                    x = px + a;
                    y = py + b2;
                    cur.push((x, y));
                    ctrl = None;
                } else {
                    break;
                }
            }
            'H' => {
                if let Some(a) = num(&mut i) {
                    x = px + a;
                    cur.push((x, y));
                    ctrl = None;
                } else {
                    break;
                }
            }
            'V' => {
                if let Some(a) = num(&mut i) {
                    y = py + a;
                    cur.push((x, y));
                    ctrl = None;
                } else {
                    break;
                }
            }
            'C' | 'S' | 'Q' | 'T' => {
                let (c1, c2, e) = match cmdu {
                    'C' => {
                        let (Some(x1), Some(y1), Some(x2), Some(y2), Some(x3), Some(y3)) = (
                            num(&mut i),
                            num(&mut i),
                            num(&mut i),
                            num(&mut i),
                            num(&mut i),
                            num(&mut i),
                        ) else {
                            break;
                        };
                        ((px + x1, py + y1), (px + x2, py + y2), (px + x3, py + y3))
                    }
                    'S' => {
                        let c1 = ctrl
                            .map(|(cx, cy)| (2.0 * x - cx, 2.0 * y - cy))
                            .unwrap_or((x, y));
                        let (Some(x2), Some(y2), Some(x3), Some(y3)) =
                            (num(&mut i), num(&mut i), num(&mut i), num(&mut i))
                        else {
                            break;
                        };
                        (c1, (px + x2, py + y2), (px + x3, py + y3))
                    }
                    'Q' => {
                        let (Some(x1), Some(y1), Some(x2), Some(y2)) =
                            (num(&mut i), num(&mut i), num(&mut i), num(&mut i))
                        else {
                            break;
                        };
                        ((px + x1, py + y1), (0.0, 0.0), (px + x2, py + y2))
                    }
                    _ => {
                        // 'T': reflect the last quadratic control point.
                        let c1 = ctrl
                            .map(|(cx, cy)| (2.0 * x - cx, 2.0 * y - cy))
                            .unwrap_or((x, y));
                        let (Some(x2), Some(y2)) = (num(&mut i), num(&mut i)) else {
                            break;
                        };
                        (c1, (0.0, 0.0), (px + x2, py + y2))
                    }
                };
                let start = (x, y);
                for s in 1..=CURVE_STEPS {
                    let t = s as f32 / CURVE_STEPS as f32;
                    let pt = if cmdu == 'C' || cmdu == 'S' {
                        cubic(start, c1, c2, e, t)
                    } else {
                        quad(start, c1, e, t)
                    };
                    cur.push(pt);
                }
                x = e.0;
                y = e.1;
                ctrl = Some(if cmdu == 'C' || cmdu == 'S' { c2 } else { c1 });
            }
            'Z' => {
                x = sx;
                y = sy;
                if cur.len() > 1 {
                    if let Some(&f) = cur.first() {
                        if *cur.last().unwrap() != f {
                            cur.push(f);
                        }
                    }
                    closed.push(std::mem::take(&mut cur));
                } else {
                    cur.clear();
                }
                ctrl = None;
            }
            // A (arc), or any unsupported command: stop parsing this path
            // rather than misinterpreting following numbers.
            _ => break,
        }
    }
    if !cur.is_empty() {
        open.push(cur);
    }
    (closed, open)
}

fn cubic(p0: (f32, f32), c1: (f32, f32), c2: (f32, f32), p1: (f32, f32), t: f32) -> (f32, f32) {
    let u = 1.0 - t;
    let (w0, w1, w2, w3) = (u * u * u, 3.0 * u * u * t, 3.0 * u * t * t, t * t * t);
    (
        w0 * p0.0 + w1 * c1.0 + w2 * c2.0 + w3 * p1.0,
        w0 * p0.1 + w1 * c1.1 + w2 * c2.1 + w3 * p1.1,
    )
}

fn quad(p0: (f32, f32), c1: (f32, f32), p1: (f32, f32), t: f32) -> (f32, f32) {
    let u = 1.0 - t;
    let (w0, w1, w2) = (u * u, 2.0 * u * t, t * t);
    (
        w0 * p0.0 + w1 * c1.0 + w2 * p1.0,
        w0 * p0.1 + w1 * c1.1 + w2 * p1.1,
    )
}

// ---------------------------------------------------------------------------
// raster: even-odd scanline fill + distance stroke
// ---------------------------------------------------------------------------

fn fill_poly(cvs: &mut Canvas32, pts: &[(f32, f32)], c: Rgba, clip: (i32, i32, i32, i32)) {
    if c[3] == 0 || pts.len() < 3 {
        return;
    }
    let (cx0, cy0, cx1, cy1) = clip;
    let (mut min_y, mut max_y) = (f32::MAX, f32::MIN);
    for &(_, y) in pts {
        min_y = min_y.min(y);
        max_y = max_y.max(y);
    }
    let y0 = (min_y.floor() as i32).max(cy0);
    let y1 = (max_y.ceil() as i32).min(cy1);
    let n = pts.len();
    for y in y0..y1 {
        let yc = y as f32 + 0.5;
        let mut xs: Vec<f32> = Vec::with_capacity(8);
        for i in 0..n {
            let (x1, y1) = pts[i];
            let (x2, y2) = pts[(i + 1) % n];
            if (y1 <= yc) == (y2 <= yc) || y1 == y2 {
                continue;
            }
            xs.push(x1 + (yc - y1) / (y2 - y1) * (x2 - x1));
        }
        xs.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        for pair in xs.chunks_exact(2) {
            let x0 = (pair[0].floor() as i32).max(cx0);
            let x1 = (pair[1].ceil() as i32).min(cx1);
            for x in x0..x1 {
                // Sample at pixel centre for honest coverage.
                let xc = x as f32 + 0.5;
                if xc >= pair[0] && xc < pair[1] {
                    cvs.blend(x, y, c, 255);
                }
            }
        }
    }
}

fn dist_seg(px: f32, py: f32, ax: f32, ay: f32, bx: f32, by: f32) -> f32 {
    let (dx, dy) = (bx - ax, by - ay);
    let len2 = dx * dx + dy * dy;
    if len2 == 0.0 {
        return ((px - ax).powi(2) + (py - ay).powi(2)).sqrt();
    }
    let t = (((px - ax) * dx + (py - ay) * dy) / len2).clamp(0.0, 1.0);
    let (cx, cy) = (ax + t * dx, ay + t * dy);
    ((px - cx).powi(2) + (py - cy).powi(2)).sqrt()
}

fn stroke_poly(
    cvs: &mut Canvas32,
    pts: &[(f32, f32)],
    w: f32,
    c: Rgba,
    clip: (i32, i32, i32, i32),
) {
    if c[3] == 0 || pts.len() < 2 || w <= 0.0 {
        return;
    }
    let half = w / 2.0;
    let (cx0, cy0, cx1, cy1) = clip;
    for seg in pts.windows(2) {
        let (ax, ay) = seg[0];
        let (bx, by) = seg[1];
        let x0 = ((ax.min(bx) - half).floor() as i32).max(cx0);
        let y0 = ((ay.min(by) - half).floor() as i32).max(cy0);
        let x1 = ((ax.max(bx) + half).ceil() as i32).min(cx1);
        let y1 = ((ay.max(by) + half).ceil() as i32).min(cy1);
        for y in y0..y1 {
            for x in x0..x1 {
                if dist_seg(x as f32 + 0.5, y as f32 + 0.5, ax, ay, bx, by) <= half {
                    cvs.blend(x, y, c, 255);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use g6b_dom::Node;

    fn svg(child: Node) -> Node {
        let mut s = Node::elem("svg");
        let _ = s.set_attribute("viewBox", "0 0 10 10");
        s.children.push(child);
        s
    }

    #[test]
    fn rect_fills_viewbox_scaled() {
        let mut r = Node::elem("rect");
        let _ = r.set_attribute("x", "0");
        let _ = r.set_attribute("y", "0");
        let _ = r.set_attribute("width", "10");
        let _ = r.set_attribute("height", "5");
        let _ = r.set_attribute("fill", "#ff0000");
        let img = raster(&svg(r), 20, 20).unwrap();
        // viewBox 10x10 → 2x scale; rect covers top half.
        let px = |x: usize, y: usize| {
            let i = (y * 20 + x) * 4;
            &img.rgba[i..i + 4]
        };
        assert_eq!(px(10, 5), &[255, 0, 0, 255]);
        assert_eq!(px(10, 15), &[0, 0, 0, 0]);
    }

    #[test]
    fn path_fill_and_stroke() {
        let mut p = Node::elem("path");
        let _ = p.set_attribute("d", "M1 1 L9 1 L9 9 Z");
        let _ = p.set_attribute("fill", "rgba(0,0,255,0.5)");
        let _ = p.set_attribute("stroke", "#00ff00");
        let _ = p.set_attribute("stroke-width", "1");
        let img = raster(&svg(p), 10, 10).unwrap();
        let px = |x: usize, y: usize| {
            let i = (y * 10 + x) * 4;
            &img.rgba[i..i + 4]
        };
        // (5,2) is inside the right triangle; (5,5) sits on the diagonal edge
        // where the stroke paints, and (1,1) is the corner vertex.
        assert_eq!(px(5, 2)[3], 128, "fill alpha passes through");
        assert_eq!(px(1, 1), &[0, 255, 0, 255], "stroke on the edge");
        assert_eq!(px(9, 9)[3], 0, "outside the path");
    }

    #[test]
    fn group_transform_and_opacity_multiply() {
        let mut r = Node::elem("rect");
        let _ = r.set_attribute("x", "0");
        let _ = r.set_attribute("y", "0");
        let _ = r.set_attribute("width", "4");
        let _ = r.set_attribute("height", "4");
        let _ = r.set_attribute("fill", "#0000ff");
        let mut g = Node::elem("g");
        let _ = g.set_attribute("transform", "translate(2 2)");
        let _ = g.set_attribute("opacity", "0.5");
        g.children.push(r);
        let img = raster(&svg(g), 10, 10).unwrap();
        let px = |x: usize, y: usize| {
            let i = (y * 10 + x) * 4;
            &img.rgba[i..i + 4]
        };
        assert_eq!(px(3, 3), &[0, 0, 255, 128]);
        assert_eq!(px(1, 1)[3], 0);
    }

    #[test]
    fn hidden_and_defs_are_not_painted() {
        let mut defs = Node::elem("defs");
        let mut r = Node::elem("rect");
        let _ = r.set_attribute("width", "10");
        let _ = r.set_attribute("height", "10");
        defs.children.push(r);
        let img = raster(&svg(defs), 10, 10).unwrap();
        assert!(img.rgba.iter().all(|&b| b == 0));

        let mut r2 = Node::elem("rect");
        let _ = r2.set_attribute("width", "10");
        let _ = r2.set_attribute("height", "10");
        let _ = r2.set_attribute("display", "none");
        let img2 = raster(&svg(r2), 10, 10).unwrap();
        assert!(img2.rgba.iter().all(|&b| b == 0));
    }

    #[test]
    fn use_resolves_id_reference() {
        let mut circle = Node::elem("circle");
        circle.id = Some("dot".into());
        let _ = circle.set_attribute("cx", "5");
        let _ = circle.set_attribute("cy", "5");
        let _ = circle.set_attribute("r", "3");
        let _ = circle.set_attribute("fill", "#ffffff");
        let mut defs = Node::elem("defs");
        defs.children.push(circle);
        let mut use_el = Node::elem("use");
        let _ = use_el.set_attribute("href", "#dot");
        let mut root = Node::elem("svg");
        let _ = root.set_attribute("viewBox", "0 0 10 10");
        root.children.push(defs);
        root.children.push(use_el);
        let img = raster(&root, 10, 10).unwrap();
        let i = (5 * 10 + 5) * 4;
        assert_eq!(&img.rgba[i..i + 4], &[255, 255, 255, 255]);
    }

    #[test]
    fn budgets_fail_closed() {
        let mut root = Node::elem("svg");
        let _ = root.set_attribute("viewBox", "0 0 1 1");
        for _ in 0..MAX_SVG_NODES + 10 {
            root.children.push(Node::elem("rect"));
        }
        // Over the node budget: must terminate, not hang or panic.
        let img = raster(&root, 4, 4).unwrap();
        assert_eq!(img.w, 4);
    }
}
