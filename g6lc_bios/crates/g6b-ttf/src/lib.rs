// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Bounded TTF loader and rasterizer for the BIOS display-proxy.
//!
//! This crate reads a TrueType/OpenType font from raw bytes and renders glyph
//! coverage bitmaps. It is intentionally narrow: one size, one bitmap output,
//! no hinting beyond what the font table supplies, and an explicit fail-closed
//! budget. It links to `g6b-gr::Canvas` so rendered glyphs can be blitted into
//! the BIOS UI without leaving the 16-colour palette.

#![forbid(unsafe_code)]
#![allow(missing_docs)]

use fontdue::{layout::GlyphRasterConfig, Font, FontSettings};

/// A rendered glyph plus its placement box.
#[derive(Debug, Clone)]
pub struct Glyph {
    pub width: u32,
    pub height: u32,
    pub min_x: i32,
    pub min_y: i32,
    /// 8-bit alpha coverage, row-major.
    pub coverage: Vec<u8>,
    /// Advance width in pixels.
    pub advance: f32,
}

/// Budgets for the BIOS font display unit.
pub const MAX_FONT_BYTES: usize = 2 * 1024 * 1024;
pub const MAX_GLYPH_SIZE: u32 = 64;

/// Bundled OFL Inconsolata font (default). May be overridden via
/// `BiosFont::from_bytes`.
pub const DEFAULT_FONT_BYTES: &[u8] =
    include_bytes!("../../../fixtures/fonts/Inconsolata-Regular.ttf");

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TtfError {
    Oversized,
    Parse(String),
    NoGlyph,
    BadSize,
    EmptyCoverage,
}

/// A loaded TTF/OpenType font.
#[derive(Debug, Clone)]
pub struct BiosFont {
    font: Font,
}

/// Load the bundled OFL Inconsolata font. This is the BIOS default; use
/// `BiosFont::from_bytes` to override it.
pub fn default_bios_font() -> Result<BiosFont, TtfError> {
    BiosFont::from_bytes(DEFAULT_FONT_BYTES)
}

impl BiosFont {
    /// Load a TTF from raw bytes. Fails closed if the file is over
    /// `MAX_FONT_BYTES` or `fontdue` cannot parse it.
    pub fn from_bytes(data: &[u8]) -> Result<Self, TtfError> {
        if data.len() > MAX_FONT_BYTES {
            return Err(TtfError::Oversized);
        }
        let settings = FontSettings {
            collection_index: 0,
            scale: 1.0,
            load_substitutions: false,
        };
        let font = Font::from_bytes(data, settings).map_err(|e| TtfError::Parse(e.to_string()))?;
        Ok(Self { font })
    }

    /// Rasterize a single code point at `px` pixels per em.
    pub fn render(&self, codepoint: char, px: f32) -> Result<Glyph, TtfError> {
        if !(1.0..=MAX_GLYPH_SIZE as f32).contains(&px) {
            return Err(TtfError::BadSize);
        }
        let idx = self.font.lookup_glyph_index(codepoint);
        let (metrics, coverage) = self.font.rasterize_config(GlyphRasterConfig {
            glyph_index: idx,
            px,
            font_hash: self.font.file_hash(),
        });
        if coverage.is_empty() {
            return Err(TtfError::EmptyCoverage);
        }
        Ok(Glyph {
            width: metrics.width as u32,
            height: metrics.height as u32,
            min_x: metrics.xmin,
            min_y: metrics.ymin,
            coverage,
            advance: metrics.advance_width,
        })
    }

    /// Return metrics for a codepoint without rasterizing.
    pub fn metrics(&self, codepoint: char, px: f32) -> Result<fontdue::Metrics, TtfError> {
        if !(1.0..=MAX_GLYPH_SIZE as f32).contains(&px) {
            return Err(TtfError::BadSize);
        }
        let idx = self.font.lookup_glyph_index(codepoint);
        Ok(self.font.metrics_indexed(idx, px))
    }

    /// Advance width for a codepoint, falling back to `'?'` if the glyph is
    /// missing so text does not stop at an unsupported character.
    pub fn advance_for(&self, codepoint: char, px: f32) -> f32 {
        let c = if self.font.lookup_glyph_index(codepoint) != 0 {
            codepoint
        } else {
            '?'
        };
        self.metrics(c, px).map(|m| m.advance_width).unwrap_or(px)
    }

    /// Render a codepoint, falling back to `'?'`.
    pub fn rasterize_for(&self, codepoint: char, px: f32) -> Glyph {
        let c = if self.font.lookup_glyph_index(codepoint) != 0 {
            codepoint
        } else {
            '?'
        };
        self.render(c, px).unwrap_or_else(|_| Glyph {
            width: 0,
            height: 0,
            min_x: 0,
            min_y: 0,
            coverage: Vec::new(),
            advance: px,
        })
    }
}

/// Blit a glyph into a `g6b_gr::Canvas` with the given foreground/background
/// palette indices. Coverage is threshold-blended into the foreground.
pub fn blit_glyph(
    canvas: &mut g6b_gr::canvas::Canvas,
    baseline_x: i32,
    baseline_y: i32,
    glyph: &Glyph,
    fg: u8,
) {
    // The coverage vector is top-left first. Metrics give the bitmap's
    // left (xmin) and bottom (ymin) edges relative to the baseline origin,
    // so the top row in canvas coordinates is `baseline_y - ymin - (h-1)`.
    let top = baseline_y - glyph.min_y - (glyph.height as i32 - 1);
    for row in 0..glyph.height {
        for col in 0..glyph.width {
            let cov = glyph.coverage[(row * glyph.width + col) as usize];
            if cov > 127 {
                let px = baseline_x + glyph.min_x + col as i32;
                let py = top + row as i32;
                canvas.set_pixel(px, py, fg);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // A minimal public-domain TTF subset is not embedded here. Tests that use
    // real font files live under `g6b-gr` fixtures.
    #[test]
    fn oversized_font_fails_closed() {
        let huge = vec![0u8; MAX_FONT_BYTES + 1];
        assert!(matches!(
            BiosFont::from_bytes(&huge),
            Err(TtfError::Oversized)
        ));
    }
}
