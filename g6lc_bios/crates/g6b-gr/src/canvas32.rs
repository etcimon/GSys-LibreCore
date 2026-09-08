// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// True-colour RGBA8 canvas for the modern render lane.
//
// The 16-colour [`crate::canvas::Canvas`] exists for the golden-image gate:
// a palette index is either exactly right or exactly wrong. Alpha, images and
// vector artwork need real colour, so this is a separate surface with
// source-over compositing. `to_x8r8` emits the same B8G8R8X8 layout the guest
// `__scan_fb` writes (`DomPaint32`/`PciPaint`), keeping the host raster and the
// scanout on one format.

use crate::PALETTE;

/// One pixel in straight (non-premultiplied) RGBA8.
pub type Rgba = [u8; 4];

/// Opaque black.
pub const BLACK: Rgba = [0, 0, 0, 255];
/// Opaque white.
pub const WHITE: Rgba = [255, 255, 255, 255];
/// Fully transparent.
pub const CLEAR: Rgba = [0, 0, 0, 0];

/// A 2D RGBA8 surface. Every write is clipped; out-of-bounds is silently
/// ignored, matching [`crate::canvas::Canvas`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Canvas32 {
    pub w: u32,
    pub h: u32,
    /// Row-major RGBA8, `w * h * 4` bytes.
    px: Vec<u8>,
}

impl Canvas32 {
    /// New canvas cleared to [`CLEAR`].
    pub fn new(w: u32, h: u32) -> Self {
        Self {
            w,
            h,
            px: vec![0; (w.saturating_mul(h).saturating_mul(4)) as usize],
        }
    }

    /// New canvas filled with one colour.
    pub fn fill(w: u32, h: u32, c: Rgba) -> Self {
        let mut cvs = Self::new(w, h);
        if c[3] == 255 {
            for i in cvs.px.chunks_exact_mut(4) {
                i.copy_from_slice(&c);
            }
        } else {
            cvs.blend_rect(0, 0, w as i32, h as i32, c);
        }
        cvs
    }

    /// Opaque single-colour canvas, the RGBA analogue of `Canvas::white`.
    pub fn opaque(w: u32, h: u32, rgb: [u8; 3]) -> Self {
        Self::fill(w, h, [rgb[0], rgb[1], rgb[2], 255])
    }

    fn idx(&self, x: i32, y: i32) -> Option<usize> {
        if x < 0 || y < 0 || x as u32 >= self.w || y as u32 >= self.h {
            return None;
        }
        Some((y as u32 * self.w + x as u32) as usize * 4)
    }

    /// Read one pixel. Out-of-bounds returns [`CLEAR`].
    pub fn get(&self, x: i32, y: i32) -> Rgba {
        match self.idx(x, y) {
            Some(i) => [self.px[i], self.px[i + 1], self.px[i + 2], self.px[i + 3]],
            None => CLEAR,
        }
    }

    /// Read-only access to the raw RGBA8 pixels.
    pub fn pixels(&self) -> &[u8] {
        &self.px
    }

    /// Store one pixel (no blending). `a == 0` writes transparent.
    pub fn set(&mut self, x: i32, y: i32, c: Rgba) {
        if let Some(i) = self.idx(x, y) {
            self.px[i..i + 4].copy_from_slice(&c);
        }
    }

    /// Multiply a 0..255 alpha and a coverage/element factor (also 0..255)
    /// into a single effective alpha, saturating.
    pub fn mul_alpha(a: u8, factor: u8) -> u8 {
        ((a as u32 * factor as u32 + 127) / 255) as u8
    }

    /// Scale a straight-alpha colour by a 0..255 extra factor (element
    /// `opacity`, `fill-opacity`, …). RGB is unchanged.
    pub fn with_alpha(c: Rgba, factor: u8) -> Rgba {
        [c[0], c[1], c[2], Self::mul_alpha(c[3], factor)]
    }

    /// Source-over blend of `src` over the existing pixel, `cov` (0..255) as
    /// coverage. This is the one compositing rule everything else uses.
    pub fn blend(&mut self, x: i32, y: i32, src: Rgba, cov: u8) {
        let a = Self::mul_alpha(src[3], cov);
        if a == 0 {
            return;
        }
        let Some(i) = self.idx(x, y) else {
            return;
        };
        if a == 255 {
            self.px[i..i + 4].copy_from_slice(&src);
            return;
        }
        let af = a as u32;
        let da = self.px[i + 3] as u32;
        // out_a = a + da*(1-a); out_rgb = (src*a + dst*da*(1-a)) / out_a
        let out_a = af + (da * (255 - af) + 127) / 255;
        if out_a == 0 {
            self.px[i..i + 4].copy_from_slice(&CLEAR);
            return;
        }
        let keep = da * (255 - af) / 255; // dst contribution weight
        for (ch, dst) in self.px[i..i + 3].iter_mut().enumerate() {
            let s = src[ch] as u32 * af;
            let d = *dst as u32 * keep;
            *dst = ((s + d) / out_a).min(255) as u8;
        }
        self.px[i + 3] = out_a.min(255) as u8;
    }

    /// Alpha-aware rectangle fill, clipped.
    pub fn blend_rect(&mut self, x: i32, y: i32, w: i32, h: i32, c: Rgba) {
        let x0 = x.max(0);
        let y0 = y.max(0);
        let x1 = (x + w).min(self.w as i32);
        let y1 = (y + h).min(self.h as i32);
        if x1 <= x0 || y1 <= y0 {
            return;
        }
        if c[3] == 255 {
            for yy in y0..y1 {
                for xx in x0..x1 {
                    self.set(xx, yy, c);
                }
            }
            return;
        }
        for yy in y0..y1 {
            for xx in x0..x1 {
                self.blend(xx, yy, c, 255);
            }
        }
    }

    /// Rounded-rectangle fill. `r` is the corner radius in pixels, clamped to
    /// the half-extents; a pixel is inside if it falls within `r` of a corner
    /// centre or inside the straight sections. Hard-edged (no AA), which is
    /// honest for a bounded BIOS raster.
    pub fn fill_rounded_rect(&mut self, x: i32, y: i32, w: i32, h: i32, r: i32, c: Rgba) {
        let r = r.clamp(0, w.min(h) / 2);
        if r == 0 {
            self.blend_rect(x, y, w, h, c);
            return;
        }
        let x0 = x.max(0);
        let y0 = y.max(0);
        let x1 = (x + w).min(self.w as i32);
        let y1 = (y + h).min(self.h as i32);
        for yy in y0..y1 {
            for xx in x0..x1 {
                if Self::inside_rounded(xx, yy, x, y, w, h, r) {
                    self.blend(xx, yy, c, 255);
                }
            }
        }
    }

    /// Inside test used by both fill and stroke of a rounded rect.
    fn inside_rounded(xx: i32, yy: i32, x: i32, y: i32, w: i32, h: i32, r: i32) -> bool {
        let cx = if xx < x + r {
            x + r - xx
        } else if xx >= x + w - r {
            xx - (x + w - r - 1)
        } else {
            0
        };
        let cy = if yy < y + r {
            y + r - yy
        } else if yy >= y + h - r {
            yy - (y + h - r - 1)
        } else {
            0
        };
        cx == 0 || cy == 0 || cx * cx + cy * cy <= r * r
    }

    /// Rounded-rect *outline* of `bw` pixels — pixels inside the outer
    /// rounded rect but outside the inner one. The border path for
    /// `border-radius` so a rounded border does not paint its interior.
    #[allow(clippy::too_many_arguments)]
    pub fn stroke_rounded_rect(
        &mut self,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        r: i32,
        bw: i32,
        c: Rgba,
    ) {
        if bw <= 0 || w <= 0 || h <= 0 {
            return;
        }
        let r = r.clamp(0, w.min(h) / 2);
        if r == 0 {
            // Square border: four side strips, no interior paint.
            self.blend_rect(x, y, w, bw, c);
            self.blend_rect(x, y + h - bw, w, bw, c);
            self.blend_rect(x, y, bw, h, c);
            self.blend_rect(x + w - bw, y, bw, h, c);
            return;
        }
        let ir = (r - bw).max(0);
        let x0 = x.max(0);
        let y0 = y.max(0);
        let x1 = (x + w).min(self.w as i32);
        let y1 = (y + h).min(self.h as i32);
        for yy in y0..y1 {
            for xx in x0..x1 {
                if Self::inside_rounded(xx, yy, x, y, w, h, r)
                    && !Self::inside_rounded(xx, yy, x + bw, y + bw, w - 2 * bw, h - 2 * bw, ir)
                {
                    self.blend(xx, yy, c, 255);
                }
            }
        }
    }

    /// Blend a glyph coverage bitmap: `cov` scales `c`'s alpha per pixel.
    /// `coverage` is row-major `gw`×`gh` bytes.
    pub fn blend_coverage(&mut self, x: i32, y: i32, gw: u32, gh: u32, coverage: &[u8], c: Rgba) {
        if coverage.len() < (gw * gh) as usize {
            return;
        }
        for row in 0..gh {
            for col in 0..gw {
                let cov = coverage[(row * gw + col) as usize];
                if cov != 0 {
                    self.blend(x + col as i32, y + row as i32, c, cov);
                }
            }
        }
    }

    /// Nearest-neighbour scaled blit of an RGBA8 image, source-over. `dw`/`dh`
    /// is the destination box; `sw`/`sh` the source size.
    #[allow(clippy::too_many_arguments)]
    pub fn blit_rgba(
        &mut self,
        src: &[u8],
        sw: u32,
        sh: u32,
        dx: i32,
        dy: i32,
        dw: i32,
        dh: i32,
        alpha: u8,
    ) {
        if sw == 0 || sh == 0 || dw <= 0 || dh <= 0 || src.len() < (sw * sh * 4) as usize {
            return;
        }
        let x0 = dx.max(0);
        let y0 = dy.max(0);
        let x1 = (dx + dw).min(self.w as i32);
        let y1 = (dy + dh).min(self.h as i32);
        for yy in y0..y1 {
            let sy = ((yy - dy) as u64 * sh as u64 / dh.max(1) as u64) as u32;
            for xx in x0..x1 {
                let sx = ((xx - dx) as u64 * sw as u64 / dw.max(1) as u64) as u32;
                let i = (sy.min(sh - 1) * sw + sx.min(sw - 1)) as usize * 4;
                let mut c: Rgba = [src[i], src[i + 1], src[i + 2], src[i + 3]];
                c[3] = Self::mul_alpha(c[3], alpha);
                self.blend(xx, yy, c, 255);
            }
        }
    }

    /// Like [`Self::blit_rgba`], but sampling the source sub-rectangle
    /// `(sx, sy, sw2, sh2)` — the `object-fit: cover` centre-crop path.
    #[allow(clippy::too_many_arguments)]
    pub fn blit_rgba_region(
        &mut self,
        src: &[u8],
        sw: u32,
        sh: u32,
        sx: u32,
        sy: u32,
        sw2: u32,
        sh2: u32,
        dx: i32,
        dy: i32,
        dw: i32,
        dh: i32,
        alpha: u8,
    ) {
        if sw2 == 0 || sh2 == 0 || sx >= sw || sy >= sh {
            return;
        }
        let sw2 = sw2.min(sw - sx);
        let sh2 = sh2.min(sh - sy);
        for yy in dy.max(0)..(dy + dh).min(self.h as i32) {
            let fy = ((yy - dy) as u64 * sh2 as u64 / dh.max(1) as u64) as u32;
            for xx in dx.max(0)..(dx + dw).min(self.w as i32) {
                let fx = ((xx - dx) as u64 * sw2 as u64 / dw.max(1) as u64) as u32;
                let i = ((sy + fy).min(sh - 1) * sw + (sx + fx).min(sw - 1)) as usize * 4;
                let mut c: Rgba = [src[i], src[i + 1], src[i + 2], src[i + 3]];
                c[3] = Self::mul_alpha(c[3], alpha);
                self.blend(xx, yy, c, 255);
            }
        }
    }

    /// Binary PPM (P6). PPM has no alpha channel, so translucent pixels are
    /// composited over `bg` — the honest flatten, and what a monitor would
    /// show against that background.
    pub fn to_ppm_over(&self, bg: [u8; 3]) -> Vec<u8> {
        let mut body = Vec::with_capacity((self.w * self.h * 3) as usize);
        for i in self.px.chunks_exact(4) {
            let a = i[3] as u32;
            if a == 255 {
                body.extend_from_slice(&i[..3]);
            } else if a == 0 {
                body.extend_from_slice(&bg);
            } else {
                for ch in 0..3 {
                    let v = (i[ch] as u32 * a + bg[ch] as u32 * (255 - a) + 127) / 255;
                    body.push(v as u8);
                }
            }
        }
        let mut out = format!("P6\n{} {}\n255\n", self.w, self.h).into_bytes();
        out.extend_from_slice(&body);
        out
    }

    /// PPM composited over white (the page background this renderer uses).
    pub fn to_ppm(&self) -> Vec<u8> {
        self.to_ppm_over([255, 255, 255])
    }

    /// B8G8R8X8 little-endian — the `__scan_fb`/virtio-gpu scanout layout.
    /// Translucent pixels composite over `bg`; X is written as 0xFF.
    pub fn to_x8r8(&self, bg: [u8; 3]) -> Vec<u8> {
        let mut out = Vec::with_capacity((self.w * self.h * 4) as usize);
        for i in self.px.chunks_exact(4) {
            let a = i[3] as u32;
            let (r, g, b) = if a == 255 {
                (i[0], i[1], i[2])
            } else {
                let f = |s: u8, d: u8| ((s as u32 * a + d as u32 * (255 - a) + 127) / 255) as u8;
                (f(i[0], bg[0]), f(i[1], bg[1]), f(i[2], bg[2]))
            };
            out.extend_from_slice(&[b, g, r, 0xff]);
        }
        out
    }

    /// Convert a palette [`crate::canvas::Canvas`] to RGBA. Every palette
    /// colour is opaque.
    pub fn from_canvas(c: &crate::canvas::Canvas) -> Self {
        let mut out = Self::new(c.w, c.h);
        for (i, &p) in c.pixels().iter().enumerate() {
            let rgb = PALETTE[(p % 16) as usize];
            out.px[i * 4] = rgb[0];
            out.px[i * 4 + 1] = rgb[1];
            out.px[i * 4 + 2] = rgb[2];
            out.px[i * 4 + 3] = 255;
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn source_over_blends_and_stays_opaque() {
        let mut c = Canvas32::new(8, 8);
        c.blend_rect(0, 0, 8, 8, [0, 0, 170, 255]);
        c.blend_rect(2, 2, 4, 4, [255, 0, 0, 128]);
        let p = c.get(3, 3);
        // Half alpha red over full blue: R~127 B~85, alpha stays 255.
        assert_eq!(p[3], 255);
        assert!((p[0] as i32 - 127).abs() <= 1, "{p:?}");
        assert!((p[2] as i32 - 85).abs() <= 1, "{p:?}");
        assert_eq!(c.get(0, 0), [0, 0, 170, 255]);
        assert_eq!(c.get(3, 3), c.get(5, 5));
    }

    #[test]
    fn rounded_rect_clips_corners() {
        let mut c = Canvas32::new(16, 16);
        c.fill_rounded_rect(2, 2, 12, 12, 4, [0, 0, 0, 255]);
        assert_eq!(c.get(2, 2)[3], 0, "corner stays clear");
        assert_eq!(c.get(8, 2)[3], 255, "top edge painted");
        assert_eq!(c.get(2, 8)[3], 255, "left edge painted");
        // Radius larger than half-extents clamps, not panics.
        let mut d = Canvas32::new(8, 8);
        d.fill_rounded_rect(0, 0, 8, 8, 32, [255, 255, 255, 255]);
        assert_eq!(d.get(4, 4)[3], 255);
    }

    #[test]
    fn blit_scales_and_respects_source_alpha() {
        // 2x2 image: top-left opaque red, rest transparent.
        let src = [255, 0, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
        let mut c = Canvas32::new(8, 8);
        c.blit_rgba(&src, 2, 2, 0, 0, 8, 8, 255);
        assert_eq!(c.get(0, 0), [255, 0, 0, 255]);
        assert_eq!(c.get(3, 3), [255, 0, 0, 255]);
        assert_eq!(c.get(4, 4), CLEAR);
        c.blit_rgba(&src, 2, 2, 0, 0, 0, 8, 255); // zero-width blit is a no-op
    }

    #[test]
    fn ppm_and_x8r8_flatten_alpha_over_a_base() {
        let mut c = Canvas32::new(2, 1);
        c.set(0, 0, [255, 0, 0, 128]);
        c.set(1, 0, [0, 255, 0, 255]);
        let ppm = c.to_ppm_over([0, 0, 0]);
        let head = b"P6\n2 1\n255\n";
        assert!(ppm.starts_with(head));
        let body = &ppm[head.len()..];
        assert!((body[0] as i32 - 127).abs() <= 1);
        assert_eq!(body[3..6], [0, 255, 0]);
        let x = c.to_x8r8([0, 0, 0]);
        assert_eq!(&x[4..8], &[0, 255, 0, 0xff]);
        assert_eq!(x.len(), 8);
    }

    #[test]
    fn palette_canvas_converts_opaque() {
        let mut pal = crate::canvas::Canvas::white(4, 4);
        pal.set_pixel(0, 0, 1);
        let c = Canvas32::from_canvas(&pal);
        assert_eq!(c.get(0, 0), [0, 0, 170, 255]);
        assert_eq!(c.get(1, 1), [255, 255, 255, 255]);
    }
}
