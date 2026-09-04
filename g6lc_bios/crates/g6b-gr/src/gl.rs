// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! OpenGL-ES2 adapter listing for the display-proxy. No libGL, no Chromium.
//! Host software-composites; a later uncore GPU may consume the same listing.

#![allow(missing_docs)]

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
         /* draw: triangle strip fullscreen; textures = ZealOS plane + DOM status */\n\
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
        assert!(!s.to_lowercase().contains("chromium"), "{s}");
        assert!(!s.to_lowercase().contains("puppeteer"), "{s}");
        assert!(s.contains("accel=off") || s.contains("GL-ACCEL"), "{s}");
    }
}
