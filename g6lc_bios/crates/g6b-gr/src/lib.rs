// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Rewrite of `kernel-spec/ZealOS/src/System/Gr` / TempleOS `SysGrInit`.
//!
//! Spec intent: 640×480, 16 colours, 8×8 font. LibreCore: BoardSpec `kernel.gr`;
//! no VGA ports. UART backend is a cell plane; `virtio-gpu` is the same plane
//! exported as PPM on the host (QEMU may attach `virtio-gpu-device` on virt).
//! Display-proxy (`proxy`) scales that plane to HDMI/DP / host-GL.

#![allow(missing_docs)]

pub mod canvas;
pub mod canvas32;
pub mod color;
pub mod gl;
pub mod proxy;

use g6b_spec::BoardSpec;

/// TempleOS 8×8 font cell.
pub const FONT: u32 = 8;

/// VGA-like 16-colour palette (spec intent; not `OutU8` VGA).
pub const PALETTE: [[u8; 3]; 16] = [
    [0, 0, 0],
    [0, 0, 170],
    [0, 170, 0],
    [0, 170, 170],
    [170, 0, 0],
    [170, 0, 170],
    [170, 85, 0],
    [170, 170, 170],
    [85, 85, 85],
    [85, 85, 255],
    [85, 255, 85],
    [85, 255, 255],
    [255, 85, 85],
    [255, 85, 255],
    [255, 255, 85],
    [255, 255, 255],
];

/// CDC-like text plane + pixel size from BoardSpec.
#[derive(Debug, Clone)]
pub struct Frame {
    pub w: u32,
    pub h: u32,
    pub colors: u32,
    pub backend: String,
    pub cols: u32,
    pub rows: u32,
    cells: Vec<u8>,
    fg: Vec<u8>,
    bg: Vec<u8>,
}

impl Frame {
    /// Empty frame from BoardSpec. Disabled Gr still yields a UART 80×25 plane.
    pub fn from_spec(spec: &BoardSpec) -> Self {
        let g = &spec.kernel.gr;
        let (w, h) = if g.enable {
            (g.w.max(FONT), g.h.max(FONT))
        } else {
            (80 * FONT, 25 * FONT)
        };
        let cols = w / FONT;
        let rows = h / FONT;
        let n = (cols * rows) as usize;
        Self {
            w,
            h,
            colors: g.colors.clamp(2, 16),
            backend: if g.enable {
                g.backend.clone()
            } else {
                "uart".into()
            },
            cols,
            rows,
            cells: vec![b' '; n],
            fg: vec![15; n],
            bg: vec![1; n],
        }
    }

    /// Marker `SysGrInit` prints.
    pub fn init_line(&self) -> String {
        format!(
            "GR-INIT {}x{}x{} backend={} cells={}x{}",
            self.w, self.h, self.colors, self.backend, self.cols, self.rows
        )
    }

    /// Paint UART/DOM lines onto the cell plane (row-major).
    pub fn paint_lines(&mut self, lines: &[String]) {
        for (r, line) in lines.iter().enumerate() {
            if r as u32 >= self.rows {
                break;
            }
            for (c, ch) in line.chars().enumerate() {
                if c as u32 >= self.cols {
                    break;
                }
                let i = r * self.cols as usize + c;
                let b = if ch.is_ascii() { ch as u8 } else { b'?' };
                self.cells[i] = b;
                self.fg[i] = 15;
                self.bg[i] = 1;
            }
        }
    }

    /// Text plane for the UART viewport (not VGA memory).
    pub fn to_text_plane(&self) -> String {
        let mut out = String::new();
        for r in 0..self.rows {
            let s = (r * self.cols) as usize;
            let e = s + self.cols as usize;
            let row = String::from_utf8_lossy(&self.cells[s..e]);
            out.push_str(row.trim_end());
            out.push('\n');
        }
        out
    }

    /// RGB of one pixel on the low-res ZealOS plane.
    pub fn rgb_at(&self, x: u32, y: u32) -> [u8; 3] {
        let row = y / FONT;
        let gy = y % FONT;
        let col = x / FONT;
        let gx = x % FONT;
        let i = (row * self.cols + col) as usize;
        let bits = glyph_row(self.cells.get(i).copied().unwrap_or(b' '), gy);
        let on = ((bits >> (7 - gx)) & 1) == 1;
        let pal = if on {
            self.fg.get(i).copied().unwrap_or(15)
        } else {
            self.bg.get(i).copied().unwrap_or(1)
        };
        PALETTE[(pal as usize) % 16]
    }

    /// Binary PPM (P6) of the 8×8 font plane.
    pub fn to_ppm(&self) -> Vec<u8> {
        let mut body = Vec::with_capacity((self.w * self.h * 3) as usize);
        for y in 0..self.h {
            for x in 0..self.w {
                body.extend_from_slice(&self.rgb_at(x, y));
            }
        }
        let mut out = format!("P6\n{} {}\n255\n", self.w, self.h).into_bytes();
        out.extend_from_slice(&body);
        out
    }
}

/// Decode an executed `GR16` 4bpp plane (`__gr_plane`, header included, as
/// written by payload `GrInit` + `DomPaint`) into a binary P6 PPM.
/// `None` on a bad/missing header or truncated pixels.
pub fn plane_to_ppm(plane: &[u8]) -> Option<Vec<u8>> {
    fn u32_at(b: &[u8], off: usize) -> Option<u32> {
        Some(u32::from_le_bytes(b.get(off..off + 4)?.try_into().ok()?))
    }
    if u32_at(plane, 0)? != u32::from_le_bytes(*b"GR16") {
        return None;
    }
    let w = u32_at(plane, 4)?;
    let h = u32_at(plane, 8)?;
    let stride = u32_at(plane, 36)? as usize;
    let hdr = u32_at(plane, 40)? as usize;
    let (w, h) = (w as usize, h as usize);
    if w == 0 || h == 0 || w > 4096 || h > 4096 || stride < w.div_ceil(2) {
        return None;
    }
    let px = plane.get(hdr..hdr + stride.checked_mul(h)?)?;
    let mut body = Vec::with_capacity(w * h * 3);
    for y in 0..h {
        let row = &px[y * stride..y * stride + w.div_ceil(2)];
        for x in 0..w {
            let byte = row[x / 2];
            let nib = if x % 2 == 0 { byte >> 4 } else { byte & 0x0f };
            body.extend_from_slice(&PALETTE[(nib % 16) as usize]);
        }
    }
    let mut out = format!("P6\n{w} {h}\n255\n").into_bytes();
    out.extend_from_slice(&body);
    Some(out)
}

/// Decode a virtio-gpu `B8G8R8X8` scanout surface (the device-side
/// `Smoke::vio_fb` filled by `TRANSFER_TO_HOST_2D`) into a binary P6 PPM.
/// `None` on an empty/mismatched buffer. This is the host-modelled analogue
/// of what QEMU's scanout would display — not a QEMU capture.
pub fn x8r8_to_ppm(w: u32, h: u32, fb: &[u8]) -> Option<Vec<u8>> {
    let (w, h) = (w as usize, h as usize);
    let px = w.checked_mul(h)?.checked_mul(4)?;
    if w == 0 || h == 0 || w > 4096 || h > 4096 || fb.len() < px {
        return None;
    }
    let mut body = Vec::with_capacity(w * h * 3);
    for i in 0..w * h {
        let o = i * 4;
        body.extend_from_slice(&[fb[o + 2], fb[o + 1], fb[o]]);
    }
    let mut out = format!("P6\n{w} {h}\n255\n").into_bytes();
    out.extend_from_slice(&body);
    Some(out)
}

/// 8×8 glyph row (MSB = left). Letters used by the BIOS banner are distinct.
pub fn glyph_row(ch: u8, row: u32) -> u8 {
    let r = row as usize;
    if r > 7 {
        return 0;
    }
    match ch {
        b' ' => 0,
        b'-' => [0, 0, 0, 0x7E, 0x7E, 0, 0, 0][r],
        b'0' => [0x3C, 0x66, 0x6E, 0x76, 0x66, 0x66, 0x3C, 0][r],
        b'6' => [0x1C, 0x30, 0x60, 0x7C, 0x66, 0x66, 0x3C, 0][r],
        b'B' => [0x7C, 0x66, 0x66, 0x7C, 0x66, 0x66, 0x7C, 0][r],
        b'C' => [0x3C, 0x66, 0x60, 0x60, 0x60, 0x66, 0x3C, 0][r],
        b'G' => [0x3C, 0x66, 0x60, 0x6E, 0x66, 0x66, 0x3C, 0][r],
        b'I' => [0x3C, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0][r],
        b'L' => [0x60, 0x60, 0x60, 0x60, 0x60, 0x66, 0x7E, 0][r],
        b'O' => [0x3C, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0][r],
        b'S' => [0x3C, 0x66, 0x60, 0x3C, 0x06, 0x66, 0x3C, 0][r],
        _ => {
            if r == 0 || r == 7 {
                0x7E
            } else if (1..7).contains(&r) {
                0x42
            } else {
                0
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn virt_fixture_ppm_is_640x480() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"kernel":{"gr":{"enable":true,"w":640,"h":480,"colors":16,"backend":"virtio-gpu"}}}"#,
        )
        .unwrap();
        let mut f = Frame::from_spec(&spec);
        assert_eq!(f.w, 640);
        assert_eq!(f.h, 480);
        assert_eq!(f.cols, 80);
        assert_eq!(f.rows, 60);
        f.paint_lines(&["G6LC-BIOS".into()]);
        let ppm = f.to_ppm();
        assert!(ppm.starts_with(b"P6\n640 480\n255\n"), "{:?}", &ppm[..20]);
        assert!(f.init_line().contains("GR-INIT 640x480x16"));
        assert!(f.init_line().contains("virtio-gpu"));
        let plane = f.to_text_plane();
        assert!(plane.contains("G6LC-BIOS"), "{plane}");
    }

    #[test]
    fn plane_ppm_decodes_executed_gr16_4bpp() {
        // 8x8 GR16 frame: stride=4, hdr=64 — one lit pixel at (0,0).
        let mut plane = vec![0u8; 64 + 4 * 8];
        plane[0..4].copy_from_slice(b"GR16");
        for (off, v) in [(4usize, 8u32), (8, 8), (12, 16), (36, 4), (40, 64)] {
            plane[off..off + 4].copy_from_slice(&v.to_le_bytes());
        }
        plane[64] = 0xF0; // px0 = colour 15, px1 = colour 0
        let ppm = plane_to_ppm(&plane).unwrap();
        let head = b"P6\n8 8\n255\n";
        assert!(ppm.starts_with(head));
        let body = &ppm[head.len()..];
        assert_eq!(&body[0..3], &PALETTE[15]);
        assert_eq!(&body[3..6], &PALETTE[0]);
        // Fail closed: empty, bad magic, truncated pixels.
        assert!(plane_to_ppm(&[]).is_none());
        let mut bad = plane.clone();
        bad[0] = 0;
        assert!(plane_to_ppm(&bad).is_none());
        assert!(plane_to_ppm(&plane[..80]).is_none());
    }
}
