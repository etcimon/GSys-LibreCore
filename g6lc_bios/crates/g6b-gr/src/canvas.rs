// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Pixel-accurate canvas for CSS golden-image validation.
//!
//! The existing [`Frame`] is an 8×8 cell text plane (rows of glyphs). For
//! testing computed box geometry we need a real 2D pixel surface, so this is a
//! small, separate canvas that shares the same 16-colour [`PALETTE`] and P6
//! output format.

use crate::PALETTE;

const BLACK: u8 = 0;
const WHITE: u8 = 15;

/// 2D pixel canvas with 16-index colour support.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Canvas {
    pub w: u32,
    pub h: u32,
    pixels: Vec<u8>,
}

/// Result of comparing two PPM images pixel-by-pixel.
#[derive(Debug, Clone, PartialEq)]
pub struct PpmDiff {
    pub same: bool,
    pub different_pixels: u32,
    pub total_pixels: u32,
    pub max_channel_delta: u32,
    pub bad_pixels: u32,
    pub ratio: f64,
}

impl Canvas {
    /// New blank canvas, cleared to black.
    pub fn new(w: u32, h: u32) -> Self {
        Self {
            w,
            h,
            pixels: vec![BLACK; (w * h) as usize],
        }
    }

    /// Palette-index surface. Extra pixels are dropped; missing pixels are black.
    pub fn from_indices(w: u32, h: u32, mut pixels: Vec<u8>) -> Self {
        let n = (w as usize).saturating_mul(h as usize);
        pixels.resize(n, BLACK);
        for p in &mut pixels {
            *p &= 0x0f;
        }
        Self { w, h, pixels }
    }

    fn idx(&self, x: i32, y: i32) -> Option<usize> {
        if x < 0 || y < 0 || x as u32 >= self.w || y as u32 >= self.h {
            return None;
        }
        Some((y as u32 * self.w + x as u32) as usize)
    }

    /// Set one pixel. Out-of-bounds is silently ignored (clipped).
    pub fn set_pixel(&mut self, x: i32, y: i32, color: u8) {
        if let Some(i) = self.idx(x, y) {
            self.pixels[i] = color & 0x0f;
        }
    }

    /// Fill an axis-aligned rectangle, clipped to the canvas.
    pub fn fill_rect(&mut self, x: i32, y: i32, w: i32, h: i32, color: u8) {
        let color = color & 0x0f;
        let x0 = x.max(0);
        let y0 = y.max(0);
        let x1 = (x + w).min(self.w as i32);
        let y1 = (y + h).min(self.h as i32);
        for yy in y0..y1 {
            for xx in x0..x1 {
                if let Some(i) = self.idx(xx, yy) {
                    self.pixels[i] = color;
                }
            }
        }
    }

    /// Draw a rectangular outline with the given thickness (>= 1), clipped.
    pub fn draw_rect(&mut self, x: i32, y: i32, w: i32, h: i32, thickness: i32, color: u8) {
        let t = thickness.max(1);
        // Top and bottom borders.
        self.fill_rect(x, y, w, t, color);
        self.fill_rect(x, y + h - t, w, t, color);
        // Left and right borders.
        self.fill_rect(x, y, t, h, color);
        self.fill_rect(x + w - t, y, t, h, color);
    }

    /// Draw one 8×8 glyph at `(x, y)` with foreground `fg` over `bg`, clipped.
    pub fn draw_char(&mut self, x: i32, y: i32, ch: u8, fg: u8, bg: u8) {
        let fg = fg & 0x0f;
        let bg = bg & 0x0f;
        for gy in 0..8i32 {
            let bits = crate::glyph_row(ch, gy as u32);
            for gx in 0..8i32 {
                let on = ((bits >> (7 - gx)) & 1) == 1;
                self.set_pixel(x + gx, y + gy, if on { fg } else { bg });
            }
        }
    }

    /// Draw a line of 8×8 ASCII text, word-wrapping within the content width
    /// (measured in *characters*, not pixels). Returns the Y coordinate of the
    /// next text baseline. Chars beyond `content_w` are clipped, not wrapped.
    pub fn draw_text(
        &mut self,
        x: i32,
        mut y: i32,
        text: &str,
        fg: u8,
        bg: u8,
        content_w: u32,
    ) -> i32 {
        let mut cx = 0u32;
        for word in text.split_whitespace() {
            let w = word.chars().count() as u32;
            if cx > 0 && cx + 1 + w > content_w {
                cx = 0;
                y += 8;
            }
            if w > content_w {
                for c in word.chars() {
                    if c.is_ascii() && cx < content_w {
                        self.draw_char(x + (cx * 8) as i32, y, c as u8, fg, bg);
                        cx += 1;
                    }
                }
                continue;
            }
            if cx > 0 && cx < content_w {
                self.draw_char(x + (cx * 8) as i32, y, b' ', fg, bg);
                cx += 1;
            }
            for c in word.chars() {
                if c.is_ascii() && cx < content_w {
                    self.draw_char(x + (cx * 8) as i32, y, c as u8, fg, bg);
                    cx += 1;
                }
            }
        }
        y + 8
    }

    /// Index at a coordinate. Panics only on out-of-range.
    pub fn get(&self, x: u32, y: u32) -> u8 {
        self.pixels[(y * self.w + x) as usize]
    }

    /// Binary PPM (P6) output.
    pub fn to_ppm(&self) -> Vec<u8> {
        let mut body = Vec::with_capacity((self.w * self.h * 3) as usize);
        for c in &self.pixels {
            body.extend_from_slice(&PALETTE[(*c as usize) % 16]);
        }
        let mut out = format!("P6\n{} {}\n255\n", self.w, self.h).into_bytes();
        out.extend_from_slice(&body);
        out
    }

    /// Build a canvas from a P6 PPM, returning `None` on an unsupported
    /// format or a mismatch with the 16-colour palette. The latter check
    /// matters because a golden image must be produced by this canvas, not by
    /// a lossy conversion from a host browser or image editor.
    pub fn from_ppm(ppm: &[u8]) -> Option<Self> {
        let (w, h, body) = parse_ppm_header(ppm)?;
        if body.len() != (w * h * 3) as usize {
            return None;
        }
        let mut pixels = Vec::with_capacity((w * h) as usize);
        for i in 0..(w * h) as usize {
            let rgb = &body[i * 3..i * 3 + 3];
            pixels.push(palette_index_for(rgb)?);
        }
        Some(Self { w, h, pixels })
    }

    /// Read-only access to the raw palette-index pixels.
    pub fn pixels(&self) -> &[u8] {
        &self.pixels
    }

    /// Clear the entire canvas.
    pub fn clear(&mut self, color: u8) {
        self.pixels.fill(color & 0x0f);
    }

    /// Default canvas: small and white, convenient for a CSS fixture whose
    /// background is not explicitly styled.
    pub fn white(w: u32, h: u32) -> Self {
        let mut c = Self::new(w, h);
        c.clear(WHITE);
        c
    }
}

fn parse_ppm_header(ppm: &[u8]) -> Option<(u32, u32, &[u8])> {
    if !ppm.starts_with(b"P6\n") {
        return None;
    }
    // The header may contain arbitrary comments starting with '#'.
    let mut rest = &ppm[3..];
    let mut dims: Option<(u32, u32)> = None;
    while !rest.is_empty() {
        let end = rest.iter().position(|&c| c == b'\n')?;
        let line = &rest[..end];
        rest = &rest[end + 1..];
        if line.is_empty() || line.starts_with(b"#") {
            continue;
        }
        if line == b"255" {
            return Some((dims?.0, dims?.1, rest));
        }
        if dims.is_none() {
            let s = std::str::from_utf8(line).ok()?;
            let mut parts = s.split_whitespace();
            let w = parts.next()?.parse().ok()?;
            let h = parts.next()?.parse().ok()?;
            dims = Some((w, h));
        }
    }
    None
}

fn palette_index_for(rgb: &[u8]) -> Option<u8> {
    for (i, &c) in PALETTE.iter().enumerate() {
        if c == [rgb[0], rgb[1], rgb[2]] {
            return Some(i as u8);
        }
    }
    None
}

/// Compare two P6 PPM byte streams. `tolerance` is the maximum allowed per-
/// channel absolute difference for a pixel to be considered matching.
///
/// Returns `PpmDiff` with `same == true` only when every pixel is within
/// tolerance. This is the golden-image gate for `bios_regress.py`.
pub fn compare_ppm(actual: &[u8], golden: &[u8], tolerance: u8) -> Option<PpmDiff> {
    let (w1, h1, b1) = parse_ppm_header(actual)?;
    let (w2, h2, b2) = parse_ppm_header(golden)?;
    if w1 != w2 || h1 != h2 || b1.len() != b2.len() {
        return Some(PpmDiff {
            same: false,
            different_pixels: 0,
            total_pixels: 0,
            max_channel_delta: 0,
            bad_pixels: 0,
            ratio: 0.0,
        });
    }
    let px = (w1 * h1) as usize;
    let mut different = 0;
    let mut max_delta = 0u32;
    let mut bad = 0;
    for i in 0..px {
        let mut pixel_max = 0;
        for j in 0..3 {
            let a = b1[i * 3 + j];
            let g = b2[i * 3 + j];
            let d = if a >= g { a - g } else { g - a };
            if d > pixel_max {
                pixel_max = d;
            }
            if u32::from(d) > max_delta {
                max_delta = u32::from(d);
            }
        }
        if pixel_max > 0 {
            different += 1;
        }
        if pixel_max > tolerance {
            bad += 1;
        }
    }
    let same = bad == 0;
    Some(PpmDiff {
        same,
        different_pixels: different,
        total_pixels: px as u32,
        max_channel_delta: max_delta,
        bad_pixels: bad,
        ratio: if px > 0 { bad as f64 / px as f64 } else { 0.0 },
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canvas_draws_box_and_ppm_round_trips() {
        let mut c = Canvas::white(16, 16);
        c.fill_rect(2, 2, 12, 12, 1); // blue background
        c.draw_rect(2, 2, 12, 12, 1, 4); // red border
        let ppm = c.to_ppm();
        assert!(ppm.starts_with(b"P6\n16 16\n255\n"));
        let back = Canvas::from_ppm(&ppm).unwrap();
        assert_eq!(back, c);
        // A non-palette colour round-trips to nothing.
        let mut bad = ppm.clone();
        let header_len = b"P6\n16 16\n255\n".len();
        bad[header_len] = 7;
        bad[header_len + 1] = 7;
        bad[header_len + 2] = 7;
        assert!(Canvas::from_ppm(&bad).is_none());
    }

    #[test]
    fn canvas_draws_8x8_text() {
        let mut c = Canvas::white(64, 16);
        let next_y = c.draw_text(0, 4, "G6LC", 0, 9, 8);
        assert!(next_y >= 12);
        // A few pixels of the G and L should be the foreground colour (black).
        assert!(c.get(2, 5) == 0 || c.get(0, 5) == 0);
    }

    #[test]
    fn compare_ppm_detects_and_allows_tolerated_differences() {
        let a = Canvas::white(8, 8).to_ppm();
        let mut b = Canvas::white(8, 8);
        b.set_pixel(2, 2, 1);
        let bppm = b.to_ppm();
        let exact = compare_ppm(&a, &bppm, 0).unwrap();
        assert!(!exact.same);
        assert_eq!(exact.different_pixels, 1);
        assert_eq!(exact.bad_pixels, 1);
        // Tolerance 255 allows any 8-bit per-channel difference.
        assert!(compare_ppm(&a, &bppm, 255).unwrap().same);
    }

    #[test]
    fn compare_ppm_fails_on_dimension_mismatch() {
        let a = Canvas::white(8, 8).to_ppm();
        let b = Canvas::white(9, 8).to_ppm();
        let d = compare_ppm(&a, &b, 0).unwrap();
        assert!(!d.same);
        assert_eq!(d.total_pixels, 0);
    }

    #[test]
    fn palette_index_for_matches_vice_versa() {
        assert_eq!(palette_index_for(&[0, 0, 0]), Some(0));
        assert_eq!(palette_index_for(&[255, 255, 255]), Some(15));
        assert_eq!(palette_index_for(&[1, 1, 1]), None);
    }

    #[test]
    fn nearest_palette_index_is_exact_on_palette_and_close_off_it() {
        for (i, &rgb) in crate::PALETTE.iter().enumerate() {
            assert_eq!(crate::nearest_palette_index(rgb), i as u8);
        }
        assert_eq!(crate::nearest_palette_index([1, 1, 1]), 0);
        assert_eq!(crate::nearest_palette_index([254, 254, 254]), 15);
    }
}
