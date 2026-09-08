// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Low-res ZealOS plane → high-res high-DPI scanout.

#![allow(missing_docs)]

use g6b_spec::{BoardSpec, DisplayOutput, ProxyAccel, Surface};

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
    /// Candidate scanout outputs, highest priority first.
    pub outputs: Vec<DisplayOutput>,
    /// Index into `outputs` of the output the proxy is driving.
    pub active: usize,
    /// Which UI surface feeds the scanout.
    pub surface: Surface,
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
            outputs: spec.display_outputs(),
            active: 0,
            surface: spec.default_surface(),
        }
    }

    /// The output currently being driven.
    pub fn output(&self) -> &DisplayOutput {
        self.outputs
            .get(self.active)
            .unwrap_or_else(|| &self.outputs[0])
    }

    /// Select an output by id. Fails closed on an unknown id rather than
    /// silently keeping the previous one.
    pub fn select_output(&mut self, id: &str) -> Result<(), String> {
        let idx = self
            .outputs
            .iter()
            .position(|o| o.id == id)
            .ok_or_else(|| format!("unknown display output {id}"))?;
        self.active = idx;
        self.surface = self.outputs[idx].surface;
        Ok(())
    }

    /// Flip between the low-res VGA surface and the native GPU surface.
    /// Refused when no accelerated output exists — there is nothing to flip to.
    pub fn set_surface(&mut self, surface: Surface) -> Result<(), String> {
        if surface == Surface::Gpu && !self.output().class.is_accelerated() {
            return Err(format!(
                "output {} is {} — the gpu surface needs an accelerated output",
                self.output().id,
                self.output().class.as_str()
            ));
        }
        self.surface = surface;
        Ok(())
    }

    pub fn toggle_surface(&mut self) -> Result<Surface, String> {
        self.set_surface(self.surface.toggled())?;
        Ok(self.surface)
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

    /// Marker naming the resolved output and surface — the display-output
    /// counterpart of `init_line`. Emitted by the boot log and mirrored by
    /// the guest `DispSel` mux.
    pub fn select_line(&self) -> String {
        let o = self.output();
        format!(
            "DISP-SEL {} {} {} {}x{} outputs={}",
            o.id,
            o.class.as_str(),
            self.surface.as_str(),
            o.w,
            o.h,
            self.outputs.len()
        )
    }

    /// Native-resolution scanout of an already-rendered high-DPI canvas.
    ///
    /// This is the `Surface::Gpu` path: the canvas is expected to be rendered
    /// **at the output's own geometry**, so nothing is scaled, letterboxed, or
    /// overlaid — that is the whole point of splitting the surfaces. A canvas
    /// whose size disagrees with the output is refused rather than stretched,
    /// because silently upscaling here would reintroduce exactly the low-res
    /// artefact the split removes.
    pub fn to_ppm_gpu(&self, canvas: &crate::canvas::Canvas) -> Result<Vec<u8>, String> {
        let o = self.output();
        if !o.class.is_accelerated() {
            return Err(format!(
                "output {} is {} — no native surface to scan out",
                o.id,
                o.class.as_str()
            ));
        }
        if canvas.w != o.w || canvas.h != o.h {
            return Err(format!(
                "gpu surface canvas is {}x{} but output {} is {}x{}; \
                 render at the output geometry instead of scaling",
                canvas.w, canvas.h, o.id, o.w, o.h
            ));
        }
        Ok(canvas.to_ppm())
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

    /// High-res PPM of a 32-bit RGBA canvas. The canvas is treated like the
    /// low-res ZealOS plane: scaled to the proxy output geometry using the same
    /// `fit`/`fill`/`dpi` rules, then composited over black. This is the modern
    /// lane counterpart of `to_ppm` — the 4bpp plane is replaced by a `Canvas32`
    /// already rendered by `g6b-css::render32`.
    pub fn to_ppm32(&self, canvas: &crate::canvas32::Canvas32, dom_status: &str) -> Vec<u8> {
        let sc = self.scale();
        let used_w = self.low_w.saturating_mul(sc);
        let used_h = self.low_h.saturating_mul(sc);
        let ox = self.high_w.saturating_sub(used_w) / 2;
        let oy = self.high_h.saturating_sub(used_h) / 2;
        let bar = bar_h(self);
        let fill = self.scale_mode == "fill";
        let mut body = vec![0u8; (self.high_w * self.high_h * 3) as usize];
        let mut y = 0u32;
        while y < self.high_h {
            let mut x = 0u32;
            while x < self.high_w {
                let i = ((y * self.high_w + x) * 3) as usize;
                let rgb = sample32(
                    self, canvas, x, y, bar, fill, ox, oy, used_w, used_h, sc, dom_status,
                );
                body[i] = rgb[0];
                body[i + 1] = rgb[1];
                body[i + 2] = rgb[2];
                x += 1;
            }
            y += 1;
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

/// Status-strip height. Zero on the native GPU surface: there the status is a
/// real DOM node rendered at native resolution, so overlaying a synthetic
/// low-res strip on top of it would be the same artefact the surface split
/// exists to remove.
#[allow(clippy::too_many_arguments)]
fn sample32(
    p: &Proxy,
    canvas: &crate::canvas32::Canvas32,
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
        return bar_pixel(p, x, y, dom_status);
    }
    let (cx, cy) = if fill {
        let avail_h = p.high_h.saturating_sub(bar).max(1);
        let lx = (x * p.low_w) / p.high_w.max(1);
        let ly = ((y - bar) * p.low_h) / avail_h;
        (lx as i32, ly as i32)
    } else if x >= ox && x < ox + used_w && y >= oy && y < oy + used_h {
        let lx = ((x - ox) / sc.max(1)) as i32;
        let ly = ((y - oy) / sc.max(1)) as i32;
        (lx, ly)
    } else {
        return [0, 0, 0];
    };
    let c = canvas.get(cx, cy);
    if c[3] == 255 {
        [c[0], c[1], c[2]]
    } else if c[3] == 0 {
        [0, 0, 0]
    } else {
        // Compositing over black, so the background term is zero.
        let a = c[3] as u32;
        [
            ((c[0] as u32 * a + 127) / 255) as u8,
            ((c[1] as u32 * a + 127) / 255) as u8,
            ((c[2] as u32 * a + 127) / 255) as u8,
        ]
    }
}

fn bar_h(p: &Proxy) -> u32 {
    if p.surface == Surface::Gpu {
        return 0;
    }
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

    fn virtio_spec() -> BoardSpec {
        BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
            "kernel":{"gr":{"enable":true,"w":640,"h":480,"backend":"virtio-gpu"},
                      "proxy":{"enable":true,"link":"virtio-gpu","dpi":192,
                               "high_w":1920,"high_h":1080}}}"#,
        )
        .unwrap()
    }

    #[test]
    fn accelerated_output_defaults_to_the_gpu_surface() {
        let spec = virtio_spec();
        let p = Proxy::from_spec(&spec);
        assert_eq!(p.surface, Surface::Gpu);
        assert_eq!(p.output().id, "vio0");
        assert_eq!(p.output().class.as_str(), "virtio-gpu");
        assert!(p
            .select_line()
            .contains("DISP-SEL vio0 virtio-gpu gpu 1920x1080"));
    }

    #[test]
    fn no_accelerated_output_stays_on_the_vga_surface() {
        // Gr plane only, no proxy and no scanout transport.
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
            "kernel":{"gr":{"enable":true,"w":640,"h":480,"backend":"uart"}}}"#,
        )
        .unwrap();
        let p = Proxy::from_spec(&spec);
        assert_eq!(p.surface, Surface::Vga);
        assert_eq!(p.output().class.as_str(), "none");
        assert!(!spec.surface_toggle());
        // The gpu surface is refused, not silently accepted.
        let mut p = p;
        assert!(p.set_surface(Surface::Gpu).is_err());
        assert!(p.toggle_surface().is_err());
    }

    #[test]
    fn gpu_surface_suppresses_the_low_res_status_strip() {
        let spec = virtio_spec();
        let mut f = Frame::from_spec(&spec);
        f.paint_lines(&["G6LC-BIOS".into()]);
        let gpu = Proxy::from_spec(&spec);
        assert_eq!(bar_h(&gpu), 0, "no synthetic strip over a native surface");
        let mut vga = gpu.clone();
        vga.set_surface(Surface::Vga).unwrap();
        assert!(bar_h(&vga) > 0, "the vga surface keeps its strip");
        // The strip is the only difference, so the two frames must differ.
        assert_ne!(
            gpu.to_ppm(&f, "DOM status=UI-BOOT"),
            vga.to_ppm(&f, "DOM status=UI-BOOT")
        );
    }

    #[test]
    fn gpu_surface_refuses_a_canvas_that_is_not_native_geometry() {
        let spec = virtio_spec();
        let p = Proxy::from_spec(&spec);
        // A low-res canvas must be refused, never upscaled — that upscale is
        // exactly the artefact the surface split removes.
        let low = crate::canvas::Canvas::white(640, 480);
        let err = p.to_ppm_gpu(&low).unwrap_err();
        assert!(err.contains("640x480"), "{err}");
        assert!(err.contains("1920x1080"), "{err}");
        let native = crate::canvas::Canvas::white(1920, 1080);
        let ppm = p.to_ppm_gpu(&native).unwrap();
        assert!(ppm.starts_with(b"P6\n1920 1080\n255\n"));
    }

    #[test]
    fn select_output_fails_closed_on_an_unknown_id() {
        let spec = virtio_spec();
        let mut p = Proxy::from_spec(&spec);
        assert!(p.select_output("nope").is_err());
        p.select_output("vga0").unwrap();
        assert_eq!(p.surface, Surface::Vga, "vga0 brings the vga surface");
    }
}
