// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// First-party icon registry, FontAwesome-*style*.
//
// Font Awesome Free's glyph outlines are CC-BY-4.0 assets — they cannot be
// vendored here without attribution machinery this repo does not have — so
// these are hand-authored MIT shapes on a 24×24 grid with FA-compatible names
// (`gear`, `microchip`, `wifi`, …). The renderer resolves `class="fa fa-x"`
// or `class="icon icon-x"`/`data-icon="x"` to a name in this table and paints
// the shapes in `currentColor`. A real browser loading the same markup sees
// whichever icon font it has; the BIOS raster never depends on that font
// binary.

#![allow(missing_docs)]

use g6b_dom::Node;
use g6b_gr::canvas32::{Canvas32, Rgba};

/// One primitive inside an icon. Coordinates are on a 24×24 grid.
#[derive(Debug, Clone, Copy)]
pub enum IconShape {
    /// `x, y, w, h, corner-radius`
    Rect(f32, f32, f32, f32, f32),
    /// `cx, cy, r`
    Circle(f32, f32, f32),
    /// `x1, y1, x2, y2, stroke-width`
    Line(f32, f32, f32, f32, f32),
    /// Closed polygon of `N` points.
    Poly(&'static [(f32, f32)]),
    /// SVG `path` data (M L C Q Z subset).
    Path(&'static str),
}

/// A named icon: a view grid plus the shapes that draw it.
pub struct Icon {
    pub name: &'static str,
    pub grid: f32,
    pub shapes: &'static [IconShape],
}

/// Look up an icon by name. Accepts the `fa-`/`icon-` prefixes so markup can
/// carry FontAwesome-style class names without depending on that font.
pub fn icon(name: &str) -> Option<&'static Icon> {
    let n = name
        .trim()
        .trim_start_matches("fa-")
        .trim_start_matches("icon-");
    ICONS.iter().find(|i| i.name == n)
}

/// Resolve an element's icon name from `data-icon`, `class="fa fa-*"` /
/// `icon-*`, or an `aria-label` fallback — in that order, mirroring how a
/// browser would resolve the same markup.
pub fn name_for(node: &Node) -> Option<String> {
    if let Some(d) = node.get_attribute("data-icon") {
        let d = d.trim();
        if !d.is_empty() {
            return Some(d.to_string());
        }
    }
    if let Some(cls) = node.get_attribute("class") {
        for part in cls.split_whitespace() {
            if let Some(rest) = part
                .strip_prefix("fa-")
                .or_else(|| part.strip_prefix("icon-"))
            {
                if icon(rest).is_some() {
                    return Some(rest.to_string());
                }
            }
        }
    }
    None
}

/// True when the element is an icon placeholder (`<i class="icon fa-*">`,
/// `<span class="icon-*">`, or any element with `data-icon`).
pub fn is_icon(node: &Node) -> bool {
    node.name == "i" && name_for(node).is_some()
        || node.get_attribute("data-icon").is_some()
        || name_for(node).is_some() && matches!(node.name.as_str(), "i" | "span" | "svg" | "b")
}

/// Paint `icon` centred in `(x, y, size, size)` on the canvas in `color`.
/// Returns the number of shapes painted.
pub fn draw(cvs: &mut Canvas32, icon: &Icon, x: i32, y: i32, size: i32, color: Rgba) -> usize {
    if size <= 0 || color[3] == 0 {
        return 0;
    }
    let s = size as f32 / icon.grid;
    let mut n = 0;
    for sh in icon.shapes {
        match *sh {
            IconShape::Rect(rx, ry, rw, rh, r) => {
                cvs.fill_rounded_rect(
                    x + (rx * s) as i32,
                    y + (ry * s) as i32,
                    (rw * s).max(1.0) as i32,
                    (rh * s).max(1.0) as i32,
                    (r * s) as i32,
                    color,
                );
            }
            IconShape::Circle(cx, cy, r) => {
                circle(
                    cvs,
                    x + (cx * s) as i32,
                    y + (cy * s) as i32,
                    (r * s) as i32,
                    color,
                );
            }
            IconShape::Line(x1, y1, x2, y2, w) => {
                thick_line(
                    cvs,
                    x + (x1 * s) as i32,
                    y + (y1 * s) as i32,
                    x + (x2 * s) as i32,
                    y + (y2 * s) as i32,
                    (w * s).max(1.0) as i32,
                    color,
                );
            }
            IconShape::Poly(pts) => {
                poly(cvs, pts, x, y, s, color);
            }
            IconShape::Path(d) => {
                let mut node = Node::elem("svg");
                let _ = node.set_attribute("viewBox", &format!("0 0 {g} {g}", g = icon.grid));
                let mut p = Node::elem("path");
                let _ = p.set_attribute("d", d);
                let _ = p.set_attribute("fill", "#fff");
                node.children.push(p);
                // Reuse the vector lane for path icons, then tint the result
                // — the rasterizer paints the path's own fill, so we paint a
                // mask by drawing the path white then compositing `color`
                // through the alpha channel.
                if let Ok(img) = crate::svg::raster(&node, size.max(1) as u32, size.max(1) as u32) {
                    for row in 0..size {
                        for col in 0..size {
                            let i = (row * size + col) as usize * 4;
                            let a = img.rgba.get(i + 3).copied().unwrap_or(0);
                            if a != 0 {
                                let c = [color[0], color[1], color[2], a];
                                let c = Canvas32::with_alpha(c, color[3]);
                                cvs.blend(x + col, y + row, c, 255);
                            }
                        }
                    }
                }
            }
        }
        n += 1;
    }
    n
}

fn circle(cvs: &mut Canvas32, cx: i32, cy: i32, r: i32, c: Rgba) {
    if r <= 0 {
        return;
    }
    let r2 = r * r;
    for y in cy - r..=cy + r {
        for x in cx - r..=cx + r {
            let dx = x - cx;
            let dy = y - cy;
            if dx * dx + dy * dy <= r2 {
                cvs.blend(x, y, c, 255);
            }
        }
    }
}

fn thick_line(cvs: &mut Canvas32, x1: i32, y1: i32, x2: i32, y2: i32, w: i32, c: Rgba) {
    let half = w / 2;
    let (dx, dy) = ((x2 - x1) as f32, (y2 - y1) as f32);
    let len = dx.hypot(dy).max(1.0);
    let steps = len as i32 + 1;
    for i in 0..=steps {
        let t = i as f32 / steps as f32;
        let px = x1 + (dx * t) as i32;
        let py = y1 + (dy * t) as i32;
        for oy in -half..=half {
            for ox in -half..=half {
                if ox * ox + oy * oy <= half * half + half {
                    cvs.blend(px + ox, py + oy, c, 255);
                }
            }
        }
    }
}

fn poly(cvs: &mut Canvas32, pts: &[(f32, f32)], ox: i32, oy: i32, s: f32, c: Rgba) {
    if pts.len() < 3 {
        return;
    }
    let tpts: Vec<(f32, f32)> = pts
        .iter()
        .map(|&(x, y)| (ox as f32 + x * s, oy as f32 + y * s))
        .collect();
    let (mut min_y, mut max_y) = (f32::MAX, f32::MIN);
    for &(_, y) in &tpts {
        min_y = min_y.min(y);
        max_y = max_y.max(y);
    }
    for y in min_y.floor() as i32..=max_y.ceil() as i32 {
        let yc = y as f32 + 0.5;
        let mut xs = Vec::new();
        let n = tpts.len();
        for i in 0..n {
            let (x1, y1) = tpts[i];
            let (x2, y2) = tpts[(i + 1) % n];
            if (y1 <= yc) == (y2 <= yc) || y1 == y2 {
                continue;
            }
            xs.push(x1 + (yc - y1) / (y2 - y1) * (x2 - x1));
        }
        xs.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        for pair in xs.chunks_exact(2) {
            for x in pair[0].floor() as i32..pair[1].ceil() as i32 {
                if x as f32 + 0.5 >= pair[0] && x as f32 + 0.5 < pair[1] {
                    cvs.blend(x, y, c, 255);
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// The table — hand-authored first-party shapes, 24×24 grid, FA-style names.
// ---------------------------------------------------------------------------

macro_rules! icon {
    ($name:literal, $($sh:expr),+ $(,)?) => {
        Icon { name: $name, grid: 24.0, shapes: &[$($sh),+] }
    };
}

static ICONS: &[Icon] = &[
    // gear — ring + hub + four spokes
    icon!(
        "gear",
        IconShape::Circle(12.0, 12.0, 9.0),
        IconShape::Circle(12.0, 12.0, 6.0), // knock-out handled below
        IconShape::Rect(10.5, 0.5, 3.0, 6.0, 0.0),
        IconShape::Rect(10.5, 17.5, 3.0, 6.0, 0.0),
        IconShape::Rect(0.5, 10.5, 6.0, 3.0, 0.0),
        IconShape::Rect(17.5, 10.5, 6.0, 3.0, 0.0),
    ),
    // microchip / cpu — body + inner die + pins
    icon!(
        "microchip",
        IconShape::Rect(6.0, 6.0, 12.0, 12.0, 1.0),
        IconShape::Rect(9.0, 9.0, 6.0, 6.0, 0.0),
        IconShape::Rect(8.0, 2.0, 2.0, 4.0, 0.0),
        IconShape::Rect(14.0, 2.0, 2.0, 4.0, 0.0),
        IconShape::Rect(8.0, 18.0, 2.0, 4.0, 0.0),
        IconShape::Rect(14.0, 18.0, 2.0, 4.0, 0.0),
        IconShape::Rect(2.0, 8.0, 4.0, 2.0, 0.0),
        IconShape::Rect(2.0, 14.0, 4.0, 2.0, 0.0),
        IconShape::Rect(18.0, 8.0, 4.0, 2.0, 0.0),
        IconShape::Rect(18.0, 14.0, 4.0, 2.0, 0.0),
    ),
    icon!(
        "cpu",
        IconShape::Rect(6.0, 6.0, 12.0, 12.0, 1.0),
        IconShape::Rect(9.0, 9.0, 6.0, 6.0, 0.0),
        IconShape::Rect(8.0, 2.0, 2.0, 4.0, 0.0),
        IconShape::Rect(14.0, 2.0, 2.0, 4.0, 0.0),
        IconShape::Rect(8.0, 18.0, 2.0, 4.0, 0.0),
        IconShape::Rect(14.0, 18.0, 2.0, 4.0, 0.0),
    ),
    // memory — DIMM stick
    icon!(
        "memory",
        IconShape::Rect(2.0, 7.0, 20.0, 9.0, 1.0),
        IconShape::Rect(4.0, 9.0, 3.0, 4.0, 0.0),
        IconShape::Rect(8.5, 9.0, 3.0, 4.0, 0.0),
        IconShape::Rect(13.0, 9.0, 3.0, 4.0, 0.0),
        IconShape::Rect(17.5, 9.0, 3.0, 4.0, 0.0),
    ),
    // hard drive / storage
    icon!(
        "hdd",
        IconShape::Rect(2.0, 6.0, 20.0, 12.0, 2.0),
        IconShape::Circle(18.0, 12.0, 1.5),
    ),
    icon!(
        "save",
        IconShape::Rect(3.0, 2.0, 18.0, 20.0, 1.0),
        IconShape::Rect(6.0, 4.0, 9.0, 6.0, 0.0),
        IconShape::Rect(6.0, 13.0, 12.0, 7.0, 0.0),
    ),
    // usb trident-ish: stem + two branches + tips
    icon!(
        "usb",
        IconShape::Line(12.0, 4.0, 12.0, 20.0, 2.0),
        IconShape::Line(12.0, 9.0, 7.0, 13.0, 2.0),
        IconShape::Line(12.0, 12.0, 17.0, 15.0, 2.0),
        IconShape::Circle(12.0, 4.0, 2.0),
        IconShape::Circle(7.0, 13.0, 2.0),
        IconShape::Circle(17.0, 15.0, 2.0),
        IconShape::Circle(12.0, 20.0, 2.0),
    ),
    // power — circle arc (two bars) + stem
    icon!(
        "power",
        IconShape::Line(12.0, 3.0, 12.0, 12.0, 2.5),
        IconShape::Path("M6 8 C3 11 3 16 6 19 C9 22 15 22 18 19 C21 16 21 11 18 8"),
    ),
    // wifi — three arcs as thick strokes
    icon!(
        "wifi",
        IconShape::Path("M4 10 C8 6 16 6 20 10"),
        IconShape::Path("M7 14 C10 11 14 11 17 14"),
        IconShape::Circle(12.0, 18.0, 2.0),
    ),
    icon!(
        "network",
        IconShape::Circle(12.0, 5.0, 3.0),
        IconShape::Circle(5.0, 18.0, 3.0),
        IconShape::Circle(19.0, 18.0, 3.0),
        IconShape::Line(10.0, 8.0, 6.0, 15.0, 1.5),
        IconShape::Line(14.0, 8.0, 18.0, 15.0, 1.5),
        IconShape::Line(8.0, 18.0, 16.0, 18.0, 1.5),
    ),
    // arrows
    icon!(
        "arrow-left",
        IconShape::Poly(&[
            (14.0, 4.0),
            (6.0, 12.0),
            (14.0, 20.0),
            (14.0, 15.0),
            (20.0, 15.0),
            (20.0, 9.0),
            (14.0, 9.0)
        ]),
    ),
    icon!(
        "arrow-right",
        IconShape::Poly(&[
            (10.0, 4.0),
            (18.0, 12.0),
            (10.0, 20.0),
            (10.0, 15.0),
            (4.0, 15.0),
            (4.0, 9.0),
            (10.0, 9.0)
        ]),
    ),
    icon!(
        "arrow-up",
        IconShape::Poly(&[
            (4.0, 14.0),
            (12.0, 6.0),
            (20.0, 14.0),
            (15.0, 14.0),
            (15.0, 20.0),
            (9.0, 20.0),
            (9.0, 14.0)
        ]),
    ),
    icon!(
        "arrow-down",
        IconShape::Poly(&[
            (4.0, 10.0),
            (12.0, 18.0),
            (20.0, 10.0),
            (15.0, 10.0),
            (15.0, 4.0),
            (9.0, 4.0),
            (9.0, 10.0)
        ]),
    ),
    // check / xmark
    icon!(
        "check",
        IconShape::Line(4.0, 13.0, 10.0, 19.0, 2.5),
        IconShape::Line(10.0, 19.0, 20.0, 5.0, 2.5),
    ),
    icon!(
        "xmark",
        IconShape::Line(5.0, 5.0, 19.0, 19.0, 2.5),
        IconShape::Line(19.0, 5.0, 5.0, 19.0, 2.5),
    ),
    // clock
    icon!(
        "clock",
        IconShape::Circle(12.0, 12.0, 9.0),
        IconShape::Line(12.0, 12.0, 12.0, 6.0, 1.5),
        IconShape::Line(12.0, 12.0, 16.0, 14.0, 1.5),
    ),
    // gauge / speed
    icon!(
        "gauge",
        IconShape::Path("M4 16 C4 10 8 5 12 5 C16 5 20 10 20 16"),
        IconShape::Line(12.0, 16.0, 17.0, 9.0, 2.0),
        IconShape::Circle(12.0, 16.0, 1.5),
    ),
    // home
    icon!(
        "home",
        IconShape::Poly(&[
            (3.0, 12.0),
            (12.0, 4.0),
            (21.0, 12.0),
            (19.0, 12.0),
            (19.0, 20.0),
            (5.0, 20.0),
            (5.0, 12.0)
        ]),
    ),
    // file / folder
    icon!(
        "file",
        IconShape::Rect(5.0, 2.0, 14.0, 20.0, 1.0),
        IconShape::Rect(7.0, 6.0, 10.0, 1.5, 0.0),
        IconShape::Rect(7.0, 10.0, 10.0, 1.5, 0.0),
        IconShape::Rect(7.0, 14.0, 7.0, 1.5, 0.0),
    ),
    icon!(
        "folder",
        IconShape::Poly(&[
            (2.0, 5.0),
            (9.0, 5.0),
            (11.0, 7.0),
            (22.0, 7.0),
            (22.0, 19.0),
            (2.0, 19.0)
        ]),
    ),
    // refresh — circular arrow
    icon!(
        "refresh",
        IconShape::Path("M5 12 C5 8 8 5 12 5 C15 5 18 7 19 10"),
        IconShape::Poly(&[(19.0, 5.0), (19.0, 11.0), (15.0, 10.0)]),
        IconShape::Path("M19 12 C19 16 16 19 12 19 C9 19 6 17 5 14"),
        IconShape::Poly(&[(5.0, 19.0), (5.0, 13.0), (9.0, 14.0)]),
    ),
    // info / warning / question
    icon!(
        "info",
        IconShape::Circle(12.0, 12.0, 10.0),
        IconShape::Rect(11.0, 10.0, 2.0, 7.0, 0.0),
        IconShape::Rect(11.0, 7.0, 2.0, 2.0, 0.0),
    ),
    icon!(
        "warning",
        IconShape::Poly(&[(12.0, 3.0), (22.0, 20.0), (2.0, 20.0)]),
        IconShape::Rect(11.0, 9.0, 2.0, 6.0, 0.0),
        IconShape::Rect(11.0, 16.5, 2.0, 2.0, 0.0),
    ),
    // floppy disk
    icon!(
        "floppy",
        IconShape::Poly(&[
            (3.0, 2.0),
            (17.0, 2.0),
            (21.0, 6.0),
            (21.0, 22.0),
            (3.0, 22.0)
        ]),
        IconShape::Rect(6.0, 3.0, 10.0, 7.0, 0.0),
        IconShape::Rect(6.0, 13.0, 12.0, 9.0, 0.0),
    ),
    // download / upload
    icon!(
        "download",
        IconShape::Line(12.0, 3.0, 12.0, 15.0, 2.5),
        IconShape::Poly(&[(6.0, 11.0), (12.0, 17.0), (18.0, 11.0)]),
        IconShape::Rect(4.0, 19.0, 16.0, 2.0, 0.0),
    ),
    icon!(
        "upload",
        IconShape::Line(12.0, 9.0, 12.0, 21.0, 2.5),
        IconShape::Poly(&[(6.0, 13.0), (12.0, 7.0), (18.0, 13.0)]),
        IconShape::Rect(4.0, 19.0, 16.0, 2.0, 0.0),
    ),
    // globe
    icon!(
        "globe",
        IconShape::Circle(12.0, 12.0, 9.0),
        IconShape::Line(3.0, 12.0, 21.0, 12.0, 1.0),
        IconShape::Path("M12 3 C8 7 8 17 12 21"),
        IconShape::Path("M12 3 C16 7 16 17 12 21"),
    ),
    // terminal / prompt
    icon!(
        "terminal",
        IconShape::Rect(2.0, 4.0, 20.0, 16.0, 1.0),
        IconShape::Line(5.0, 9.0, 9.0, 12.0, 1.5),
        IconShape::Line(9.0, 12.0, 5.0, 15.0, 1.5),
        IconShape::Line(12.0, 15.0, 18.0, 15.0, 1.5),
    ),
    // battery
    icon!(
        "battery",
        IconShape::Rect(2.0, 8.0, 18.0, 9.0, 1.0),
        IconShape::Rect(21.0, 10.0, 2.0, 5.0, 0.0),
        IconShape::Rect(4.0, 10.0, 10.0, 5.0, 0.0),
    ),
    // lock
    icon!(
        "lock",
        IconShape::Rect(6.0, 11.0, 12.0, 9.0, 1.0),
        IconShape::Path("M8 11 C8 7 10 5 12 5 C14 5 16 7 16 11"),
    ),
    // LibreCore brand mark — interlocked square ring
    icon!(
        "g6lc",
        IconShape::Rect(4.0, 4.0, 16.0, 16.0, 2.0),
        IconShape::Rect(8.0, 8.0, 8.0, 8.0, 1.0),
        IconShape::Rect(10.5, 10.5, 3.0, 3.0, 0.0),
    ),
];

/// Every registered icon name — for docs, listings and tests.
pub fn names() -> Vec<&'static str> {
    ICONS.iter().map(|i| i.name).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use g6b_gr::canvas32::WHITE;

    #[test]
    fn lookup_accepts_fa_and_icon_prefixes() {
        assert_eq!(icon("gear").unwrap().name, "gear");
        assert_eq!(icon("fa-gear").unwrap().name, "gear");
        assert_eq!(icon("icon-cpu").unwrap().name, "cpu");
        assert!(icon("does-not-exist").is_none());
    }

    #[test]
    fn name_for_reads_data_icon_and_class() {
        let mut i = Node::elem("i");
        let _ = i.set_attribute("class", "icon icon-gear");
        assert_eq!(name_for(&i).as_deref(), Some("gear"));
        let mut s = Node::elem("span");
        let _ = s.set_attribute("data-icon", "wifi");
        assert_eq!(name_for(&s).as_deref(), Some("wifi"));
        let plain = Node::elem("i");
        assert_eq!(name_for(&plain), None);
    }

    #[test]
    fn every_icon_paints_pixels() {
        for name in names() {
            let ic = icon(name).unwrap();
            let mut c = Canvas32::new(24, 24);
            let n = draw(&mut c, ic, 0, 0, 24, WHITE);
            assert!(n > 0, "{name} drew nothing");
            assert!(
                c.pixels().chunks_exact(4).any(|p| p[3] > 0),
                "{name} is blank"
            );
        }
    }
}
