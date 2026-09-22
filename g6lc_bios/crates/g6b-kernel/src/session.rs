// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Setup session: construction, the painted tree, and which menu is selected.
//! Clicks live in actions. Dynamic GETs live in fetch_extra.

use std::collections::BTreeMap;

use g6b_css::Engine;
use g6b_dom::Node;
use g6b_holyc::Program;
use g6b_html::script_sources;
use g6b_spec::BoardSpec;

use super::{
    each_id, install_boot_inventory, libwasm_lane, live_css, live_paint_targets, load_program,
    remap_hit_paths, session_assets, session_page_html, task_services, BrowserEventHost,
    DirVolumes, FrameEngine, FrameGuest, WasmUi, MAX_TABS_PER_WINDOW,
};

pub struct BrowserSession {
    pub dom: Node,
    pub program: Program,
    pub diagnostics: Vec<String>,
    pub wasm_executed: bool,
    pub task_services: Option<task_services::TaskServices>,
    pub hit_boxes: Vec<g6b_css::render::HitBox>,
    pub event_host: BrowserEventHost,
    /// Loaded svelte-d LDC application (persistent instance).
    pub wasm_ui: Option<WasmUi>,
    /// Which UI surface feeds the scanout. Starts at the BoardSpec default
    /// (which follows the highest-priority output's class) and is flipped by
    /// the `#disp-toggle` control or `DisplaySurface` in the HolyC lane.
    pub surface: g6b_spec::Surface,
    pub(crate) selected_menu: String,
    pub(crate) field_focus: BTreeMap<String, usize>,
    /// B92 session pool (`g6b-iframe`). Window/tab chrome is Svelte.
    /// Kernel registers hooks and fulfills [`HostNeed`] GETs.
    pub(crate) frames: FrameEngine,
    /// Test / adapter bodies for armed outbound `http(s):` (never `/bios`).
    pub(crate) outbound_stubs: BTreeMap<String, (u16, String)>,
    /// Per-tab guest object tables (B92e). Never the shell `WasmUi` table.
    pub(crate) frame_guests: [Option<FrameGuest>; MAX_TABS_PER_WINDOW],
    pub(crate) async_scripts: g6b_js::AsyncScheduler,
    pub(crate) spec: BoardSpec,
    /// Live CSS engine. Parsed once; `paint(&Node)` is the raster (B88).
    pub(crate) css: Option<Engine>,
    pub(crate) timers: crate::timers::TimerHeap,
    pub(crate) now_ns: u64,
    /// Modelled `__scan_fb` (X8R8G8B8). Host blit of Canvas32 dirty tiles (B90).
    pub scan_fb: Vec<u8>,
    pub(crate) scan_fb_w: u32,
    pub(crate) scan_fb_h: u32,
    /// Last virtio-gpu transfer listing (empty tiles → skip-if-clean).
    pub(crate) last_transfer: String,
    pub(crate) last_tiles: Vec<g6b_css::DirtyRegion>,
    /// Post-boot lazy adapter session. Not started from `_start`.
    pub hw: g6b_hw::HwSession,
    /// CLI, firmware, settings, and the console window. One overlay.
    pub(crate) shell: g6b_zealcli::Session,
    /// The CLI console window is focused. Setup tab keys are ignored.
    pub(crate) console_open: bool,
}

impl BrowserSession {
    pub fn new(spec: &BoardSpec) -> Result<Self, String> {
        Self::with_volumes(spec, DirVolumes::new())
    }

    pub fn with_volumes(spec: &BoardSpec, volumes: DirVolumes) -> Result<Self, String> {
        let mut program = load_program(spec)?;
        install_boot_inventory(spec, &mut program.router, &volumes)?;
        Self::from_program(spec, program)
    }

    pub(crate) fn from_program(spec: &BoardSpec, program: Program) -> Result<Self, String> {
        let mut session = Self {
            dom: g6b_html::parse_checked(&session_page_html(spec))?,
            program,
            diagnostics: Vec::new(),
            wasm_executed: false,
            task_services: if spec.kernel.tasking.enable {
                Some(task_services::TaskServices::new(spec).map_err(|error| error.to_string())?)
            } else {
                None
            },
            hit_boxes: Vec::new(),
            event_host: BrowserEventHost::default(),
            wasm_ui: None,
            surface: g6b_spec::Surface::Vga,
            selected_menu: spec.kernel.start_menu.clone(),
            field_focus: BTreeMap::new(),
            frames: {
                let mut frames = FrameEngine::new();
                if spec.kernel.usb.enable && spec.kernel.usb.key {
                    let mut vols: Vec<String> = Vec::new();
                    if spec.kernel.usb.fs_fat32 {
                        vols.push("fat32".into());
                    }
                    if spec.kernel.usb.fs_ntfs {
                        vols.push("ntfs".into());
                    }
                    if spec.kernel.usb.fs_ext4 {
                        vols.push("ext4".into());
                    }
                    if spec.kernel.usb.fs_btrfs {
                        vols.push("btrfs".into());
                    }
                    frames.register_hook(g6b_iframe::AppHook::files_volumes(vols));
                }
                // Outbound stays off until `g6b-hw` announces net support.
                frames.set_outbound(false);
                frames
            },
            hw: g6b_hw::HwSession::from_board(spec),
            frame_guests: std::array::from_fn(|_| None),
            outbound_stubs: BTreeMap::new(),
            async_scripts: g6b_js::AsyncScheduler::default(),
            spec: spec.clone(),
            css: None,
            timers: crate::timers::TimerHeap::new(),
            now_ns: 0,
            scan_fb: Vec::new(),
            scan_fb_w: 0,
            scan_fb_h: 0,
            last_transfer: String::new(),
            last_tiles: Vec::new(),
            shell: crate::zealcli::session(spec),
            console_open: false,
        };
        if spec.kernel.js == "aot" {
            for src in script_sources(&session.dom) {
                session.execute_script(&src)?;
            }
        }
        if spec.kernel.wasm.enable {
            // The LDC/libwasm cell is the only UI wasm. The MVP encoder
            // artifact is a compiler demonstration and a guest VGA-glyph
            // lowering input — never a silent host fallback.
            if libwasm_lane(spec) {
                session.run_libwasm_start()?;
            } else if spec.kernel.ui == "svelte-d" && spec.kernel.js == "aot" {
                return Err(
                    "svelte-d UI requires the LDC libwasm cell (kernel.wasm + http.files.wasm)"
                        .into(),
                );
            }
            session.refresh()?;
        }
        session.select_menu(&spec.kernel.start_menu)?;
        if let Some(svc) = session.task_services.as_mut() {
            let _ = svc.ensure_ui();
            session.diagnostics.push("UI-HART ready".into());
        }
        Ok(session)
    }

    pub(crate) fn paint_status(&mut self, fallback: &str) {
        // Status text is owned by the BIOS UI. Record the fallback on the
        // serial/diagnostic ring only.
        self.diagnostics.push(format!("UI-STATUS {fallback}"));
    }

    /// Live CSS paint of the Svelte tree. No HTML serialize/parse.
    pub fn paint_css(&mut self) -> Result<g6b_css::render32::Render32Output, String> {
        let w = self.spec.kernel.gr.w.max(320);
        let h = self.spec.kernel.gr.h.max(200);
        self.paint_css_at(w, h)
    }

    /// Live CSS paint at an explicit canvas size (GPU scanout geometry).
    pub fn paint_css_at(
        &mut self,
        w: u32,
        h: u32,
    ) -> Result<g6b_css::render32::Render32Output, String> {
        self.ensure_engine(w, h)?;
        let mut engine = self.css.take().ok_or("css engine missing")?;
        let targets = live_paint_targets(&self.dom);
        let painted = engine.paint_nodes(&targets, false);
        self.css = Some(engine);
        let painted = painted?;
        let mut hits = painted.hit_boxes.clone();
        remap_hit_paths(&self.dom, &mut hits);
        self.hit_boxes = hits.clone();
        Ok(g6b_css::render32::Render32Output {
            canvas: painted.canvas,
            hit_boxes: hits,
        })
    }

    /// [`Self::paint_css_at`] with the `Canvas32` display-list recorder armed
    /// — the `__web_dl` pack lane (`dl_pack`). The op vec is the paint log
    /// `DlPaint` replays guest-side; the canvas is the pixel-exact reference
    /// the packer's `TILEPX` relief diffs against.
    pub fn paint_css_dl_at(
        &mut self,
        w: u32,
        h: u32,
    ) -> Result<
        (
            g6b_css::render32::Render32Output,
            Vec<g6b_gr::canvas32::DlOp>,
        ),
        String,
    > {
        self.ensure_engine(w, h)?;
        let mut engine = self.css.take().ok_or("css engine missing")?;
        let targets = live_paint_targets(&self.dom);
        let painted = engine.paint_nodes_dl(&targets);
        self.css = Some(engine);
        let (painted, ops) = painted?;
        let mut hits = painted.hit_boxes.clone();
        remap_hit_paths(&self.dom, &mut hits);
        self.hit_boxes = hits.clone();
        Ok((
            g6b_css::render32::Render32Output {
                canvas: painted.canvas,
                hit_boxes: hits,
            },
            ops,
        ))
    }

    pub(crate) fn ensure_engine(&mut self, w: u32, h: u32) -> Result<(), String> {
        let w = w.max(320);
        let h = h.max(200);
        if self.css.is_none() {
            let css = live_css(&self.dom, &self.spec)?;
            let fonts = g6b_css::FontSet::default_set().map_err(|e| format!("{e:?}"))?;
            let assets = session_assets(&self.spec);
            self.css = Some(Engine::new(&css, w, h, assets, fonts)?);
        } else if let Some(engine) = self.css.as_mut() {
            engine.set_viewport(w, h);
        }
        Ok(())
    }

    pub fn select_menu(&mut self, id: &str) -> Result<(), String> {
        if !g6b_ui::MENUS.iter().any(|face| face.id == id) {
            return Err(format!("unknown menu {id}"));
        }
        for face in g6b_ui::MENUS {
            let mut found = false;
            let show = face.id == id;
            each_id(&mut self.dom, &format!("menu-{}", face.id), &mut |panel| {
                found = true;
                panel.set_visible(show);
                Ok(())
            })?;
            if !found {
                return Err(format!("missing menu {}", face.id));
            }
        }
        if self.selected_menu != id {
            self.async_scripts.cancel_all();
        }
        self.selected_menu = id.into();
        self.paint_live_tabs(id)?;
        self.focus_field(0)?;
        Ok(())
    }

    /// Restyle the live Svelte tab strip (`bios-tab-active`, aria) so goosie
    /// plus GLES2 present the selected menu. Every node with that id is
    /// updated (static shell and LDC cell tree).
    fn paint_live_tabs(&mut self, id: &str) -> Result<(), String> {
        for face in g6b_ui::MENUS {
            let active = face.id == id;
            each_id(&mut self.dom, &format!("tab-{}", face.id), &mut |tab| {
                tab.set_attribute(
                    "class",
                    if active {
                        "bios-tab bios-tab-active"
                    } else {
                        "bios-tab"
                    },
                )?;
                tab.set_attribute("aria-selected", if active { "true" } else { "false" })?;
                tab.set_attribute("tabindex", if active { "0" } else { "-1" })?;
                if active {
                    tab.set_attribute("aria-current", "page")?;
                } else {
                    tab.remove_attribute("aria-current");
                }
                Ok(())
            })?;
        }
        Ok(())
    }
}
