// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Live CSS engine: goosie cascade/layout/paint on a `g6b_dom::Node` tree.
//!
//! This is the B88 seam. Callers pass the live DOM; the engine never
//! serializes HTML or re-parses it. Skip-if-clean uses [`DirtyFlag`].
//! Incremental dirty *tiles* (TRANSFER rects) are B90.

use g6b_dom::{DirtyFlag, Node};
use g6b_gr::canvas32::Canvas32;
use g6b_img::AssetMap;
use g6b_ttf::FontSet;

use crate::render::HitBox;
use crate::render32::{self, Render32Output};
use crate::{parse_survey, Stylesheet};

/// Axis-aligned dirty rectangle. B88 records one full-frame region when
/// anything is dirty; B90 splits this into tiles.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct DirtyRegion {
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
}

impl DirtyRegion {
    /// Virtio / GLES2 tile size (B90).
    pub const TILE: i32 = 64;
    pub const MAX_TILES: usize = 64;

    pub fn empty() -> Self {
        Self::default()
    }

    pub fn full(w: u32, h: u32) -> Self {
        Self {
            x: 0,
            y: 0,
            w: w as i32,
            h: h as i32,
        }
    }

    pub fn is_empty(self) -> bool {
        self.w <= 0 || self.h <= 0
    }

    /// Bounding box of pixels that differ between two canvases.
    pub fn from_diff(prev: &Canvas32, next: &Canvas32) -> Self {
        if prev.w != next.w || prev.h != next.h {
            return Self::full(next.w, next.h);
        }
        let mut x0 = i32::MAX;
        let mut y0 = i32::MAX;
        let mut x1 = i32::MIN;
        let mut y1 = i32::MIN;
        for y in 0..next.h as i32 {
            for x in 0..next.w as i32 {
                if prev.get(x, y) != next.get(x, y) {
                    x0 = x0.min(x);
                    y0 = y0.min(y);
                    x1 = x1.max(x);
                    y1 = y1.max(y);
                }
            }
        }
        if x0 > x1 {
            return Self::empty();
        }
        Self {
            x: x0,
            y: y0,
            w: x1 - x0 + 1,
            h: y1 - y0 + 1,
        }
    }

    /// Grid-aligned tiles covering this region. Empty input → no tiles.
    /// More than [`Self::MAX_TILES`] collapses to a single covering rect.
    pub fn tiles(self, tile: i32) -> Vec<Self> {
        if self.is_empty() {
            return Vec::new();
        }
        let t = tile.max(1);
        let x0 = self.x.div_euclid(t) * t;
        let y0 = self.y.div_euclid(t) * t;
        let x1 = self.x + self.w;
        let y1 = self.y + self.h;
        let mut out = Vec::new();
        let mut y = y0;
        while y < y1 {
            let mut x = x0;
            while x < x1 {
                let w = t.min(x1 - x);
                let h = t.min(y1 - y);
                out.push(Self { x, y, w, h });
                x += t;
            }
            y += t;
        }
        if out.len() > Self::MAX_TILES {
            vec![self]
        } else {
            out
        }
    }
}

/// One Engine::paint result. `skipped` is the 100+ fps budget: the previous
/// canvas is reused when no Style/Layout/Paint bit is set.
#[derive(Debug, Clone)]
pub struct PaintOutput {
    pub canvas: Canvas32,
    pub hit_boxes: Vec<HitBox>,
    pub dirty: DirtyRegion,
    pub skipped: bool,
    pub flags: DirtyFlag,
}

impl From<PaintOutput> for Render32Output {
    fn from(p: PaintOutput) -> Self {
        Self {
            canvas: p.canvas,
            hit_boxes: p.hit_boxes,
        }
    }
}

/// Parsed stylesheet + last frame. `paint(&Node)` is the live path.
pub struct Engine {
    sheet: Stylesheet,
    w: u32,
    h: u32,
    assets: AssetMap,
    fonts: FontSet,
    last: Option<PaintOutput>,
}

impl Engine {
    pub fn new(
        css: &str,
        w: u32,
        h: u32,
        assets: AssetMap,
        fonts: FontSet,
    ) -> Result<Self, String> {
        let (sheet, _unsupported) = parse_survey(css).map_err(|e| e.to_string())?;
        Ok(Self {
            sheet,
            w: w.max(1),
            h: h.max(1),
            assets,
            fonts,
            last: None,
        })
    }

    pub fn viewport(&self) -> (u32, u32) {
        (self.w, self.h)
    }

    /// Changing geometry drops the cached frame so the next paint cannot
    /// skip-if-clean at the old size.
    pub fn set_viewport(&mut self, w: u32, h: u32) {
        let w = w.max(1);
        let h = h.max(1);
        if self.w != w || self.h != h {
            self.w = w;
            self.h = h;
            self.last = None;
        }
    }

    /// Live paint. Skips when `node.dirty_union()` is empty and a prior
    /// canvas exists.
    pub fn paint(&mut self, node: &Node) -> Result<PaintOutput, String> {
        self.paint_nodes(&[node], false)
    }

    /// Always raster, even if the tree is clean (goldens, first present).
    pub fn paint_force(&mut self, node: &Node) -> Result<PaintOutput, String> {
        self.paint_nodes(&[node], true)
    }

    /// Paint several live nodes as children of an anonymous `body` (cell
    /// `<main>` plus shell chrome such as `#disp-toggle`).
    pub fn paint_nodes_force(&mut self, nodes: &[&Node]) -> Result<PaintOutput, String> {
        self.paint_nodes(nodes, true)
    }

    /// Paint several live nodes. `force` skips the DirtyFlag short-circuit
    /// (goldens / first present). Skip-if-clean does not consume the last
    /// dirty bbox — [`Self::consume_tiles`] does that at present.
    pub fn paint_nodes(&mut self, nodes: &[&Node], force: bool) -> Result<PaintOutput, String> {
        let flags = nodes
            .iter()
            .fold(DirtyFlag::NONE, |acc, n| acc.union(n.dirty_union()));
        if !force && flags.is_empty() {
            if let Some(last) = self.last.as_ref() {
                let mut out = last.clone();
                out.skipped = true;
                out.dirty = DirtyRegion::empty();
                out.flags = DirtyFlag::NONE;
                return Ok(out);
            }
        }
        let rendered = render32::paint_nodes(
            &self.sheet,
            nodes,
            self.w,
            self.h,
            &self.assets,
            &self.fonts,
        )?;
        let dirty = if let Some(ref last) = self.last {
            DirtyRegion::from_diff(&last.canvas, &rendered.canvas)
        } else {
            DirtyRegion::full(self.w, self.h)
        };
        let out = PaintOutput {
            canvas: rendered.canvas,
            hit_boxes: rendered.hit_boxes,
            dirty,
            skipped: false,
            flags,
        };
        self.last = Some(out.clone());
        Ok(out)
    }

    /// Last paint (for dirty-tile present without a second raster).
    pub fn last(&self) -> Option<&PaintOutput> {
        self.last.as_ref()
    }

    /// Forced paint with the `Canvas32` display-list recorder armed — the
    /// `__web_dl` pack lane. Same dirty bookkeeping as a forced
    /// [`Self::paint_nodes`] so the skip-if-clean cache stays honest.
    pub fn paint_nodes_dl(
        &mut self,
        nodes: &[&Node],
    ) -> Result<(PaintOutput, Vec<g6b_gr::canvas32::DlOp>), String> {
        let flags = nodes
            .iter()
            .fold(DirtyFlag::NONE, |acc, n| acc.union(n.dirty_union()));
        let (rendered, ops) = render32::paint_nodes_dl(
            &self.sheet,
            nodes,
            self.w,
            self.h,
            &self.assets,
            &self.fonts,
        )?;
        let dirty = if let Some(ref last) = self.last {
            DirtyRegion::from_diff(&last.canvas, &rendered.canvas)
        } else {
            DirtyRegion::full(self.w, self.h)
        };
        let out = PaintOutput {
            canvas: rendered.canvas,
            hit_boxes: rendered.hit_boxes,
            dirty,
            skipped: false,
            flags,
        };
        self.last = Some(out.clone());
        Ok((out, ops))
    }

    /// Tiles covering the last dirty bbox, then mark the region presented
    /// so a second present without a new raster is skip-if-clean.
    pub fn consume_tiles(&mut self) -> Vec<DirtyRegion> {
        match self.last.as_mut() {
            Some(p) => {
                let tiles = p.dirty.tiles(DirtyRegion::TILE);
                p.dirty = DirtyRegion::empty();
                tiles
            }
            None => Vec::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use g6b_dom::Node;

    fn engine() -> Engine {
        let fonts = FontSet::default_set().expect("font");
        Engine::new(
            "body { background-color: #ffffff; } \
             #box { width: 10px; height: 10px; background-color: #ff0000; }",
            40,
            20,
            AssetMap::new(),
            fonts,
        )
        .unwrap()
    }

    fn box_tree() -> Node {
        let mut body = Node::elem("body");
        let mut boxn = Node::elem("div");
        boxn.set_attribute("id", "box").unwrap();
        body.append_child(boxn);
        body
    }

    #[test]
    fn paint_uses_the_live_node_not_html() {
        let mut eng = engine();
        let tree = box_tree();
        let out = eng.paint(&tree).unwrap();
        assert!(!out.skipped);
        assert!(out.hit_boxes.iter().any(|h| h.id.as_deref() == Some("box")));
        let mut saw_red = false;
        for y in 0..out.canvas.h as i32 {
            for x in 0..out.canvas.w as i32 {
                let p = out.canvas.get(x, y);
                if p[0] == 255 && p[1] == 0 && p[2] == 0 {
                    saw_red = true;
                }
            }
        }
        assert!(saw_red, "live node must paint the #box fill");
    }

    #[test]
    fn skip_if_clean_reuses_the_last_canvas() {
        let mut eng = engine();
        let mut tree = box_tree();
        let first = eng.paint(&tree).unwrap();
        tree.clear_dirty();
        let second = eng.paint(&tree).unwrap();
        assert!(second.skipped);
        assert_eq!(first.canvas, second.canvas);
        tree.get_element_by_id("box")
            .unwrap()
            .set_attribute("class", "on")
            .unwrap();
        let third = eng.paint(&tree).unwrap();
        assert!(!third.skipped);
    }

    #[test]
    fn dirty_region_tiles_cover_a_bbox() {
        let r = DirtyRegion {
            x: 10,
            y: 10,
            w: 20,
            h: 20,
        };
        let tiles = r.tiles(16);
        assert!(!tiles.is_empty());
        assert!(tiles.iter().all(|t| t.w > 0 && t.h > 0));
        assert!(DirtyRegion::empty().tiles(16).is_empty());
    }

    #[test]
    fn consume_tiles_empties_dirty_after_present() {
        let mut eng = engine();
        let tree = box_tree();
        let first = eng.paint(&tree).unwrap();
        assert!(!first.dirty.is_empty());
        let tiles = eng.consume_tiles();
        assert!(!tiles.is_empty());
        assert!(eng.consume_tiles().is_empty());
    }
}
