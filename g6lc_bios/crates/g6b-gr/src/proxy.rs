// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Low-res ZealOS plane → high-res high-DPI scanout.

#![allow(missing_docs)]

use g6b_spec::{BoardSpec, ProxyAccel};

use crate::Frame;

/// Display-proxy mode derived from BoardSpec.
#[derive(Debug, Clone)]
pub struct Proxy {
    pub low_w: u32,
    pub low_h: u32,
    pub high_w: u32,
    pub high_h: u32,
    pub dpi: u32,
    pub fps: u32,
    pub link: String,
    pub gl: bool,
    /// `fit` | `fill` | `dpi`
    pub scale_mode: String,
    /// Optional RVV / AI-island scale path (`off` unless BoardSpec asks).
    pub accel: ProxyAccel,
}

impl Proxy {
    /// From BoardSpec. Disabled proxy still names the low-res plane.
    pub fn from_spec(spec: &BoardSpec) -> Self {
        let g = &spec.kernel.gr;
        let p = &spec.kernel.proxy;
        let (lw, lh) = if g.enable {
            (g.w.max(8), g.h.max(8))
        } else {
            (640, 480)
        };
        Self {
            low_w: lw,
            low_h: lh,
            high_w: if p.enable { p.high_w.max(lw) } else { lw },
            high_h: if p.enable { p.high_h.max(lh) } else { lh },
            dpi: if p.enable { p.dpi } else { 96 },
            fps: p.refresh_hz(),
            link: if p.enable {
                p.link.clone()
            } else {
                g.backend.clone()
            },
            gl: p.enable && p.gl,
            scale_mode: if p.scale_mode.is_empty() {
                "fit".into()
            } else {
                p.scale_mode.clone()
            },
            accel: spec.proxy_accel(),
        }
    }

    fn fit_scale(&self) -> u32 {
        let sx = self.high_w / self.low_w.max(1);
        let sy = self.high_h / self.low_h.max(1);
        sx.min(sy).max(1)
    }

    /// Integer scale for `fit`/`dpi`; for `fill` the larger axis (crop/stretch).
    pub fn scale(&self) -> u32 {
        let fit = self.fit_scale();
        match self.scale_mode.as_str() {
            "fill" => {
                let sx = self.high_w / self.low_w.max(1);
                let sy = self.high_h / self.low_h.max(1);
                sx.max(sy).max(1)
            }
            "dpi" => (self.dpi / 96).max(1).min(fit),
            _ => fit,
        }
    }

    /// Marker for boot log / HolyC.
    pub fn init_line(&self) -> String {
        format!(
            "PROXY-INIT {}x{}→{}x{} dpi={} fps={} link={} gl={} scale={} mode={} accel={}",
            self.low_w,
            self.low_h,
            self.high_w,
            self.high_h,
            self.dpi,
            self.fps,
            self.link,
            u32::from(self.gl),
            self.scale(),
            self.scale_mode,
            self.accel.as_str()
        )
    }

    /// High-res PPM: nearest-neighbour `fit` (letterbox), `fill` (stretch), or `dpi`.
    pub fn to_ppm(&self, low: &Frame, dom_status: &str) -> Vec<u8> {
        let sc = self.scale();
        let used_w = self.low_w.saturating_mul(sc);
        let used_h = self.low_h.saturating_mul(sc);
        let ox = self.high_w.saturating_sub(used_w) / 2;
        let oy = self.high_h.saturating_sub(used_h) / 2;
        let bar = bar_h(self);
        let fill = self.scale_mode == "fill";
        let mut body = vec![0u8; (self.high_w * self.high_h * 3) as usize];
        let step = match self.accel {
            ProxyAccel::Rvv => 8u32,
            ProxyAccel::AiIsland => 16u32,
            ProxyAccel::Off => 1u32,
        };
        let mut y = 0u32;
        while y < self.high_h {
            let y_tile = if self.accel == ProxyAccel::AiIsland {
                step.min(self.high_h - y)
            } else {
                1
            };
            for yy in 0..y_tile {
                let py = y + yy;
                let mut x = 0u32;
                while x < self.high_w {
                    let n = step.min(self.high_w - x);
                    for k in 0..n {
                        let px = x + k;
                        let i = ((py * self.high_w + px) * 3) as usize;
                        let rgb = sample(
                            self, low, px, py, bar, fill, ox, oy, used_w, used_h, sc, dom_status,
                        );
                        body[i] = rgb[0];
                        body[i + 1] = rgb[1];
                        body[i + 2] = rgb[2];
                    }
                    x += n;
                }
            }
            y += y_tile;
        }
        let mut out = format!("P6\n{} {}\n255\n", self.high_w, self.high_h).into_bytes();
        out.extend_from_slice(&body);
        out
    }
}

#[allow(clippy::too_many_arguments)]
fn sample(
    p: &Proxy,
    low: &Frame,
    x: u32,
    y: u32,
    bar: u32,
    fill: bool,
    ox: u32,
    oy: u32,
    used_w: u32,
    used_h: u32,
    sc: u32,
    dom_status: &str,
) -> [u8; 3] {
    if y < bar {
        bar_pixel(p, x, y, dom_status)
    } else if fill {
        let avail_h = p.high_h.saturating_sub(bar).max(1);
        let lx = x.saturating_mul(p.low_w) / p.high_w.max(1);
        let ly = (y - bar).saturating_mul(p.low_h) / avail_h;
        low.rgb_at(
            lx.min(low.w.saturating_sub(1)),
            ly.min(low.h.saturating_sub(1)),
        )
    } else if x >= ox && x < ox + used_w && y >= oy && y < oy + used_h {
        let lx = (x - ox) / sc.max(1);
        let ly = (y - oy) / sc.max(1);
        low.rgb_at(
            lx.min(low.w.saturating_sub(1)),
            ly.min(low.h.saturating_sub(1)),
        )
    } else {
        [0, 0, 0]
    }
}

fn bar_h(p: &Proxy) -> u32 {
    ((p.dpi / 6).max(16)).min(p.high_h / 8)
}

fn bar_pixel(p: &Proxy, x: u32, y: u32, status: &str) -> [u8; 3] {
    let h = bar_h(p);
    if y >= h {
        return [0, 0, 32];
    }
    let col_w = (p.dpi / 12).max(8);
    let col = x / col_w;
    let ch = status.chars().nth(col as usize).unwrap_or(' ');
    let on = y > h / 4 && y < (h * 3) / 4 && ch != ' ';
    if on {
        [0, 220, 80]
    } else {
        [0, 0, 48]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use g6b_spec::{BoardSpec, ProxyAccel};

    #[test]
    fn hdmi_120hz_scales_640_to_1920() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
            "kernel":{"gr":{"enable":true,"w":640,"h":480,"backend":"hdmi"},
                      "proxy":{"enable":true,"link":"hdmi","dpi":192,"fps":0,"detected_hz":120,
                               "high_w":1920,"high_h":1080,"gl":true}}}"#,
        )
        .unwrap();
        let p = Proxy::from_spec(&spec);
        assert_eq!(p.fps, 120);
        assert_eq!(p.scale(), 2);
        assert!(p.init_line().contains("PROXY-INIT"), "{}", p.init_line());
        let mut f = Frame::from_spec(&spec);
        f.paint_lines(&["G6LC-BIOS".into()]);
        let ppm = p.to_ppm(&f, "DOM status=UI-BOOT");
        assert!(ppm.starts_with(b"P6\n1920 1080\n255\n"), "{:?}", &ppm[..24]);
    }

    #[test]
    fn fill_4k_high_dpi() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
            "kernel":{"gr":{"enable":true,"w":640,"h":480,"backend":"hdmi"},
                      "proxy":{"enable":true,"link":"hdmi","dpi":192,"fps":60,
                               "high_w":3840,"high_h":2160,"gl":true,"scale_mode":"fill"}}}"#,
        )
        .unwrap();
        let p = Proxy::from_spec(&spec);
        assert_eq!(p.high_w, 3840);
        assert_eq!(p.scale_mode, "fill");
        assert!(p.scale() >= 4, "scale={}", p.scale());
        let mut f = Frame::from_spec(&spec);
        f.paint_lines(&["G6LC-BIOS".into()]);
        let ppm = p.to_ppm(&f, "UI-BOOT");
        assert!(ppm.starts_with(b"P6\n3840 2160\n255\n"), "{:?}", &ppm[..28]);
    }

    #[test]
    fn rvv_accel_same_ppm_as_scalar() {
        let json = r#"{"schema_version":1,"isa":{"xlen":64,"extensions":{"v":"live"}},
            "kernel":{"gr":{"enable":true,"w":640,"h":480},
                      "proxy":{"enable":true,"link":"host-gl","gl":true,
                               "high_w":1280,"high_h":720,"accel":"rvv"}}}"#;
        let spec = BoardSpec::from_json_str(json).unwrap();
        assert_eq!(spec.proxy_accel(), ProxyAccel::Rvv);
        let mut off = spec.clone();
        off.kernel.proxy.accel = "off".into();
        let mut f = Frame::from_spec(&spec);
        f.paint_lines(&["G6LC-BIOS".into()]);
        let a = Proxy::from_spec(&spec).to_ppm(&f, "UI-BOOT");
        let b = Proxy::from_spec(&off).to_ppm(&f, "UI-BOOT");
        assert_eq!(a, b);
        assert!(Proxy::from_spec(&spec).init_line().contains("accel=rvv"));
    }
}
