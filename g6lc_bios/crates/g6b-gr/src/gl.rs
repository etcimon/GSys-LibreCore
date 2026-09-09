// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! OpenGL-ES2 adapter listing for the display-proxy. No libGL, no Chromium.
//! Host software-composites; a later uncore GPU may consume the same listing.

#![allow(missing_docs)]

use crate::canvas32::Canvas32;
use crate::proxy::Proxy;
use crate::Frame;

/// GLES2 program that samples the ZealOS plane and a DOM status texture.
pub fn listing(proxy: &Proxy) -> String {
    format!(
        "/* g6b-gr OpenGL-ES2 adapter — display-proxy {lw}x{lh} → {hw}x{hh} fps={fps} dpi={dpi} mode={mode} accel={accel} */\n\
         /* purpose=gl-adapter home=gles2 */\n\
         /* GL-ACCEL {accel}: rvv=vle8/vse8 scale blit; ai-island=16x16 tiles (GEMM @ 0x40000000, not the GR plane) */\n\
         #version 100\n\
         attribute vec2 a_pos;\n\
         attribute vec2 a_uv;\n\
         varying vec2 v_uv;\n\
         void main() {{\n\
         \tgl_Position = vec4(a_pos, 0.0, 1.0);\n\
         \tv_uv = a_uv;\n\
         }}\n\
         /* fragment */\n\
         #version 100\n\
         precision mediump float;\n\
         varying vec2 v_uv;\n\
         uniform sampler2D u_zeal;\n\
         uniform sampler2D u_dom;\n\
         void main() {{\n\
         \tvec4 z = texture2D(u_zeal, v_uv);\n\
         \tvec4 d = texture2D(u_dom, v_uv);\n\
         \tgl_FragColor = mix(z, d, d.a);\n\
         }}\n\
         /* draw: triangle strip fullscreen */\n\
         /* u_zeal = VGA 640x480 plane (vga surface only) */\n\
         /* u_dom  = CSS Canvas32 of the wasm-mutated BrowserSession DOM */\n\
         /* dirty tiles: glTexSubImage2D per TILE (64px); skip-if-clean */\n\
         /* virtio: TRANSFER_TO_HOST_2D + RESOURCE_FLUSH of those rects */\n\
         /* GL-ADAPTER opengl-es2 fps={fps} link={link} accel={accel} */\n",
        lw = proxy.low_w,
        lh = proxy.low_h,
        hw = proxy.high_w,
        hh = proxy.high_h,
        fps = proxy.fps,
        dpi = proxy.dpi,
        mode = proxy.scale_mode,
        link = proxy.link,
        accel = proxy.accel.as_str(),
    )
}

/// Software composite (stand-in for binding the listing to a real context).
pub fn composite_ppm(proxy: &Proxy, low: &Frame, dom_status: &str) -> Vec<u8> {
    proxy.to_ppm(low, dom_status)
}

/// GLES2 `u_dom` stand-in: the CSS Canvas32 of the live BrowserSession.
pub fn composite_ppm32(proxy: &Proxy, canvas: &Canvas32, dom_status: &str) -> Vec<u8> {
    proxy.to_ppm32(canvas, dom_status)
}

/// Tile size matching CSS [`DirtyRegion::TILE`] (64 px). Defined here so
/// `g6b-gr` does not depend on `g6b-css` (that crate already depends on this
/// one for Canvas32).
pub const TILE: i32 = 64;

/// One GLES2 `glTexSubImage2D` / virtio-gpu `TRANSFER_TO_HOST_2D` rectangle.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Tile {
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
}

/// Virtio-gpu controlq listing for dirty tiles (not a full-frame transfer).
pub fn transfer_listing(tiles: &[Tile]) -> String {
    let mut out = String::from("/* virtio-gpu dirty present */\n");
    if tiles.is_empty() {
        out.push_str("/* SKIP-IF-CLEAN no TRANSFER */\n");
        return out;
    }
    for t in tiles {
        out.push_str(&format!(
            "TRANSFER_TO_HOST_2D x={} y={} w={} h={}\n",
            t.x, t.y, t.w, t.h
        ));
    }
    out.push_str("RESOURCE_FLUSH\n");
    out
}

/// Blit `tiles` of a Canvas32 into an X8R8G8B8 `__scan_fb` buffer (stride =
/// canvas width). Translucent pixels flatten over white, matching
/// [`Canvas32::to_ppm`]. First present should pass a full-frame tile so the
/// buffer is defined.
pub fn blit_tiles_x8r8(canvas: &Canvas32, fb: &mut [u8], tiles: &[Tile]) {
    let stride = canvas.w as i32;
    let need = (canvas.w as usize)
        .saturating_mul(canvas.h as usize)
        .saturating_mul(4);
    if fb.len() < need {
        return;
    }
    for t in tiles {
        let x0 = t.x.max(0);
        let y0 = t.y.max(0);
        let x1 = (t.x + t.w).min(stride);
        let y1 = (t.y + t.h).min(canvas.h as i32);
        for y in y0..y1 {
            for x in x0..x1 {
                let p = canvas.get(x, y);
                let a = p[3] as u32;
                let (r, g, b) = if a == 255 {
                    (p[0], p[1], p[2])
                } else if a == 0 {
                    (255, 255, 255)
                } else {
                    let f = |s: u8| ((s as u32 * a + 255 * (255 - a) + 127) / 255) as u8;
                    (f(p[0]), f(p[1]), f(p[2]))
                };
                let i = ((y * stride + x) * 4) as usize;
                // B8G8R8X8 LE — same layout as Canvas32::to_x8r8.
                fb[i] = b;
                fb[i + 1] = g;
                fb[i + 2] = r;
                fb[i + 3] = 0xff;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::proxy::Proxy;
    use g6b_spec::BoardSpec;

    #[test]
    fn listing_is_gles2_not_chromium() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
            "kernel":{"gr":{"enable":true,"backend":"host-gl"},
                      "proxy":{"enable":true,"link":"host-gl","gl":true}}}"#,
        )
        .unwrap();
        let p = Proxy::from_spec(&spec);
        let s = listing(&p);
        assert!(s.contains("GL-ADAPTER"), "{s}");
        assert!(s.contains("u_zeal"), "{s}");
        assert!(s.contains("u_dom"), "{s}");
        assert!(s.contains("Canvas32"), "{s}");
        assert!(!s.to_lowercase().contains("chromium"), "{s}");
        assert!(!s.to_lowercase().contains("puppeteer"), "{s}");
        assert!(s.contains("accel=off") || s.contains("GL-ACCEL"), "{s}");
        assert!(
            s.contains("TRANSFER_TO_HOST_2D") || s.contains("dirty tiles"),
            "{s}"
        );
    }

    #[test]
    fn transfer_listing_skips_when_clean() {
        let s = transfer_listing(&[]);
        assert!(s.contains("SKIP-IF-CLEAN"), "{s}");
        assert!(
            !s.contains("RESOURCE_FLUSH\n") || s.contains("no TRANSFER"),
            "{s}"
        );
    }

    #[test]
    fn blit_tiles_writes_only_the_rect() {
        let mut c = Canvas32::opaque(4, 2, [255, 0, 0]);
        c.set(1, 0, [0, 255, 0, 255]);
        let mut fb = vec![0u8; 4 * 2 * 4];
        let tile = Tile {
            x: 1,
            y: 0,
            w: 1,
            h: 1,
        };
        blit_tiles_x8r8(&c, &mut fb, &[tile]);
        // pixel (1,0) is green → BGRX 0, 255, 0, 255
        assert_eq!(&fb[4..8], &[0, 255, 0, 0xff]);
        assert_eq!(&fb[0..4], &[0, 0, 0, 0]);
    }
}
