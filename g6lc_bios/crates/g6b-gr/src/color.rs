// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Shared RGBA colour parsing for the modern render lane.
//
// One parser for both CSS declarations (`g6b-css`) and SVG presentation
// attributes (`g6b-img`), so `fill="#00000080"` and `color: rgba(...)` mean
// the same pixel everywhere. Kept in `g6b-gr` because the colour space is a
// property of the surface, not of either parser.

use crate::canvas32::Rgba;

/// Parse a CSS/SVG colour into straight RGBA8.
///
/// Accepted: `#rgb`/`#rgba`/`#rrggbb`/`#rrggbbaa`, `rgb()`/`rgba()` with
/// integer channels and a `0..1` or `%` alpha, `none`, `transparent`, and the
/// named set below (the CSS level-1/VGA names this project already uses plus
/// `currentcolor`, resolved by the caller — this returns `None` for it).
pub fn parse_rgba(value: &str) -> Option<Rgba> {
    let v = value.trim().to_ascii_lowercase();
    if v == "transparent" || v == "none" {
        return Some([0, 0, 0, 0]);
    }
    if v == "currentcolor" {
        return None;
    }
    if let Some(rest) = v.strip_prefix("rgba(").or_else(|| v.strip_prefix("rgb(")) {
        return rgb_fn(rest);
    }
    if let Some(rest) = v.strip_prefix('#') {
        return hex(rest);
    }
    named(&v)
}

/// `parse_rgba` plus `currentcolor` resolution — SVG `fill`/`stroke` and any
/// CSS colour that may inherit the element's `color`.
pub fn parse_rgba_current(value: &str, current: Rgba) -> Option<Rgba> {
    let v = value.trim();
    if v.eq_ignore_ascii_case("currentcolor") {
        return Some(current);
    }
    parse_rgba(v)
}

fn hex(h: &str) -> Option<Rgba> {
    let nib = |c: u8| -> Option<u8> { (c as char).to_digit(16).map(|d| d as u8) };
    let b = h.as_bytes();
    match b.len() {
        3 | 4 => {
            let r = nib(b[0])? * 17;
            let g = nib(b[1])? * 17;
            let bl = nib(b[2])? * 17;
            let a = if b.len() == 4 { nib(b[3])? * 17 } else { 255 };
            Some([r, g, bl, a])
        }
        6 | 8 => {
            let r = (nib(b[0])? << 4) | nib(b[1])?;
            let g = (nib(b[2])? << 4) | nib(b[3])?;
            let bl = (nib(b[4])? << 4) | nib(b[5])?;
            let a = if b.len() == 8 {
                (nib(b[6])? << 4) | nib(b[7])?
            } else {
                255
            };
            Some([r, g, bl, a])
        }
        _ => None,
    }
}

fn rgb_fn(rest: &str) -> Option<Rgba> {
    let rest = rest.strip_suffix(')')?;
    let parts: Vec<&str> = rest.split(',').map(str::trim).collect();
    if !(3..=4).contains(&parts.len()) {
        return None;
    }
    let ch = |s: &str| -> Option<u8> {
        if let Some(p) = s.strip_suffix('%') {
            Some((p.parse::<f64>().ok()? / 100.0 * 255.0).round() as u8)
        } else {
            s.parse::<u8>().ok()
        }
    };
    let a = if parts.len() == 4 {
        let s = parts[3];
        if let Some(p) = s.strip_suffix('%') {
            (p.parse::<f64>().ok()? / 100.0 * 255.0).round() as u8
        } else {
            (s.parse::<f64>().ok()?.clamp(0.0, 1.0) * 255.0).round() as u8
        }
    } else {
        255
    };
    Some([ch(parts[0])?, ch(parts[1])?, ch(parts[2])?, a])
}

/// Named colours. The 16 VGA names are fixed by `crate::PALETTE`; a small set
/// of common extra names is kept for CSS/SVG ergonomics — this is a lookup
/// table, not a claim of CSS colour coverage.
pub fn named(v: &str) -> Option<Rgba> {
    let (r, g, b) = match v {
        "black" => (0, 0, 0),
        "blue" => (0, 0, 170),
        "green" => (0, 170, 0),
        "cyan" | "aqua" => (0, 170, 170),
        "red" => (170, 0, 0),
        "magenta" | "fuchsia" | "purple" => (170, 0, 170),
        "brown" | "orange" => (170, 85, 0),
        "lightgray" | "lightgrey" | "silver" | "gray" | "grey" => (170, 170, 170),
        "darkgray" | "darkgrey" => (85, 85, 85),
        "lightblue" => (85, 85, 255),
        "lightgreen" | "lime" => (85, 255, 85),
        "lightcyan" => (85, 255, 255),
        "lightred" => (255, 85, 85),
        "pink" => (255, 85, 255),
        "yellow" => (255, 255, 85),
        "white" => (255, 255, 255),
        "navy" => (0, 0, 128),
        "teal" => (0, 128, 128),
        "gold" => (255, 215, 0),
        "tomato" => (255, 99, 71),
        "rebeccapurple" => (102, 51, 153),
        _ => return None,
    };
    Some([r, g, b, 255])
}

/// A `0..1` float or `0..100%` → 0..255 alpha byte. Shared by `opacity`,
/// `fill-opacity`, `stroke-opacity` and `stop-opacity`.
pub fn parse_opacity(value: &str) -> Option<u8> {
    let v = value.trim();
    if let Some(p) = v.strip_suffix('%') {
        Some((p.parse::<f64>().ok()?.clamp(0.0, 100.0) / 100.0 * 255.0).round() as u8)
    } else {
        Some((v.parse::<f64>().ok()?.clamp(0.0, 1.0) * 255.0).round() as u8)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_alpha_forms() {
        assert_eq!(parse_rgba("#f00"), Some([255, 0, 0, 255]));
        assert_eq!(parse_rgba("#f008"), Some([255, 0, 0, 0x88]));
        assert_eq!(parse_rgba("#ff0000"), Some([255, 0, 0, 255]));
        assert_eq!(parse_rgba("#ff000080"), Some([255, 0, 0, 0x80]));
        assert_eq!(parse_rgba("#ff00"), Some([255, 255, 0, 0]));
        assert_eq!(parse_rgba("#ff00008"), None);
    }

    #[test]
    fn rgb_fn_alpha() {
        assert_eq!(parse_rgba("rgb(255,0,0)"), Some([255, 0, 0, 255]));
        assert_eq!(parse_rgba("rgba(255, 0, 0, 0.5)"), Some([255, 0, 0, 128]));
        assert_eq!(parse_rgba("rgba(50%, 0%, 0%, 50%)"), Some([128, 0, 0, 128]));
        assert_eq!(parse_rgba("rgba(0,0,0,2)"), Some([0, 0, 0, 255]));
    }

    #[test]
    fn keywords() {
        assert_eq!(parse_rgba("transparent"), Some([0, 0, 0, 0]));
        assert_eq!(parse_rgba("none"), Some([0, 0, 0, 0]));
        assert_eq!(parse_rgba("currentcolor"), None);
        assert_eq!(
            parse_rgba_current("currentColor", [1, 2, 3, 9]),
            Some([1, 2, 3, 9])
        );
        assert_eq!(parse_rgba("rebeccapurple"), Some([102, 51, 153, 255]));
        assert_eq!(parse_rgba("not-a-color"), None);
    }

    #[test]
    fn opacity_scalar() {
        assert_eq!(parse_opacity("0.5"), Some(128));
        assert_eq!(parse_opacity("50%"), Some(128));
        assert_eq!(parse_opacity("2"), Some(255));
        assert_eq!(parse_opacity("none"), None);
    }
}
