// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Rewrite of `kernel-spec/ZealOS/src/System/Gr` / TempleOS `SysGrInit`.
//!
//! Spec intent: 640×480, 16 colours, 8×8 font. LibreCore: BoardSpec `kernel.gr`;
//! no VGA ports. UART backend is a cell plane; `virtio-gpu` is the same plane
//! exported as PPM on the host (QEMU may attach `virtio-gpu-device` on virt).
//! Display-proxy (`proxy`) scales that plane to HDMI/DP / host-GL.

#![allow(missing_docs)]

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

/// 8×8 glyph row (MSB = left). Letters used by the BIOS banner are distinct.
fn glyph_row(ch: u8, row: u32) -> u8 {
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
}
