// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Bounded image assets for the BIOS browser UI: PNG decode/encode, SVG
//! rasterization, and a first-party icon registry — all fail-closed, all
//! without external image dependencies (KD0).

#![deny(missing_docs)]

pub mod icons;
pub mod png;
pub mod svg;

use std::collections::BTreeMap;

use g6b_dom::Node;
use g6b_gr::canvas32::Rgba;

/// A decoded raster image in straight RGBA8.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RgbaImage {
    /// Width in pixels.
    pub w: u32,
    /// Height in pixels.
    pub h: u32,
    /// Row-major RGBA8, `w * h * 4` bytes.
    pub rgba: Vec<u8>,
}

impl RgbaImage {
    /// Single solid-colour image.
    pub fn solid(w: u32, h: u32, c: Rgba) -> Self {
        let mut rgba = vec![0u8; (w * h * 4) as usize];
        for i in rgba.chunks_exact_mut(4) {
            i.copy_from_slice(&c);
        }
        Self { w, h, rgba }
    }

    /// Blit this image scaled into `cvs` at `(dx, dy, dw, dh)` source-over.
    pub fn blit(
        &self,
        cvs: &mut g6b_gr::canvas32::Canvas32,
        dx: i32,
        dy: i32,
        dw: i32,
        dh: i32,
        alpha: u8,
    ) {
        cvs.blit_rgba(&self.rgba, self.w, self.h, dx, dy, dw, dh, alpha);
    }
}

/// One named asset the DOM may reference through `<img src>`,
/// `background-image: url()`, or `list-style-image`.
#[derive(Debug, Clone)]
pub enum Asset {
    /// Decoded bitmap (PNG today; the only raster codec this package ships).
    Raster(RgbaImage),
    /// Parsed SVG document (kept as a DOM so it rasterizes at box size).
    Vector(Node),
}

/// `name -> Asset` map the render lane resolves `url()`/`src` against.
/// Only keys present here may paint — a missing asset draws the element's
/// fallback (the `alt` text / empty box), never a network fetch.
pub type AssetMap = BTreeMap<String, Asset>;

/// Load one asset by content sniffing: `\x89PNG` → [`png::decode`]; a `<svg`
/// element → [`svg`]. Returns `Err` with the reason when neither matches.
pub fn load_asset(name: &str, bytes: &[u8]) -> Result<Asset, String> {
    if bytes.starts_with(b"\x89PNG") {
        return png::decode(bytes)
            .map(Asset::Raster)
            .map_err(|e| format!("{name}: {e}"));
    }
    let text = std::str::from_utf8(bytes).map_err(|_| format!("{name}: not png or svg"))?;
    let head = text.trim_start_matches(|c: char| c.is_whitespace());
    if head.starts_with("<svg") || head.starts_with("<?xml") || head.starts_with("<!DOCTYPE svg") {
        let dom = g6b_html::parse_checked(text).map_err(|e| format!("{name}: {e}"))?;
        let svg_node = find_svg(&dom)
            .cloned()
            .ok_or_else(|| format!("{name}: no <svg>"))?;
        return Ok(Asset::Vector(svg_node));
    }
    Err(format!("{name}: unrecognized asset type"))
}

fn find_svg(node: &Node) -> Option<&Node> {
    if node.name == "svg" {
        return Some(node);
    }
    node.children.iter().find_map(find_svg)
}

/// Maximum number of named assets one render may consult.
pub const MAX_ASSETS: usize = 64;
/// Maximum decoded bytes across all raster assets.
pub const MAX_ASSET_BYTES: usize = 16 * 1024 * 1024;

/// Build an `AssetMap` from `(name, bytes)` pairs, enforcing the budgets and
/// the fail-closed rule: a single bad asset fails the whole map so a broken
/// page is loud, not half-rendered.
pub fn load_assets<I, N, B>(items: I) -> Result<AssetMap, String>
where
    I: IntoIterator<Item = (N, B)>,
    N: AsRef<str>,
    B: AsRef<[u8]>,
{
    let mut map = AssetMap::new();
    let mut total = 0usize;
    for (name, bytes) in items {
        let name = name.as_ref();
        if map.len() >= MAX_ASSETS {
            return Err(format!("asset budget exceeded at {name}"));
        }
        if name.contains(['\\', ':']) || name.split('/').any(|s| matches!(s, ".." | ".")) {
            return Err(format!("asset name {name} is not a local path"));
        }
        let asset = load_asset(name, bytes.as_ref())?;
        if let Asset::Raster(r) = &asset {
            total += r.rgba.len();
            if total > MAX_ASSET_BYTES {
                return Err(format!("decoded-asset budget exceeded at {name}"));
            }
        }
        map.insert(name.to_string(), asset);
    }
    Ok(map)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn load_asset_sniffs_png_and_svg() {
        let png_bytes = png::encode(&RgbaImage::solid(2, 2, [255, 0, 0, 255]));
        let a = load_asset("/a.png", &png_bytes).unwrap();
        assert!(matches!(a, Asset::Raster(r) if r.w == 2));
        let s = load_asset(
            "/i.svg",
            br##"<svg viewBox="0 0 4 4"><rect width="4" height="4" fill="#00f"/></svg>"##,
        )
        .unwrap();
        assert!(matches!(s, Asset::Vector(_)));
        assert!(load_asset("/x.bin", b"\x00\x01").is_err());
    }

    #[test]
    fn load_assets_enforces_budget_and_names() {
        assert!(load_assets([("../evil.png", &b"\x89PNG"[..])]).is_err());
        let ok = load_assets([(
            "logo.png",
            png::encode(&RgbaImage::solid(1, 1, [0, 0, 0, 255])).as_slice(),
        )]);
        assert!(ok.unwrap().contains_key("logo.png"));
    }
}
