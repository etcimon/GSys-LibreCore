// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Host S-mode smoke for generated payloads (QEMU stand-in, never Variane).
//!
//! Executes the instruction subset `g6b-asm` emits. SBI ecall: putchar, TIME,
//! SRST. UART RX is PLIC irq 1 (`trap_uart`); a leftover poll still ends the
//! run after the boot log. No crates.io.

#![allow(missing_docs)]

use g6b_spec::BoardSpec;

use crate::encode::{
    CSR_SATP, CSR_SCAUSE, CSR_SEPC, CSR_SIE, CSR_SSTATUS, CSR_STVEC, CSR_TIME, MBOX_CMD_BYTES,
    MBOX_KICK, MBOX_MAGIC, MBOX_OFF_CMD, MBOX_OFF_DOORBELL, MBOX_OFF_IRQ_EN, MBOX_OFF_LENGTH,
    MBOX_OFF_RSP, MBOX_OFF_STATUS, MBOX_RSP_BYTES, PLIC_CLAIM_S0, PLIC_ENABLE_S0, PLIC_THRESH_S0,
    SBI_HSM_EID, SBI_IPI_EID, SBI_PUTCHAR, SBI_SRST_EID, SBI_TIME_EID, SIE_SEIE, SIE_STIE, SRET,
    SSTATUS_SIE, UART_IRQ,
};
use crate::{
    gr_bss_len, gr_stride, payload_memsz, stack_memsz, Module, GR_HEADER_BYTES, UART_LINE_BSS,
};

/// Host-executor step bound. The guest's `VioPaint` 4bpp→X8R8G8B8 expand is a
/// real w*h/2-iteration loop (≈2M words at 640×480) plus DOM paint and the
/// rest of boot; real QEMU has no such bound.
/// Host-model step ceiling — raised for the timer-tick background repaint
/// (DomPaint+VioPaint per dirty tick) plus the await/dom-nav lane.
///
/// Raised again for **CLI-first on a complete build**: the container paints its
/// frame at power-on and the browser paints its own when the picker hands the plane
/// over, so a full boot now contains two glyph passes over a 640×480 plane plus two
/// scanout expands. That is real work the firmware does on purpose, not a runaway
/// loop, and a ceiling that forbids it would only hide the ordering this build is
/// supposed to have. Real QEMU does the same work in milliseconds.
const STEP_LIMIT: u32 = 48_000_000;
const UART0: u64 = 0x1000_0000;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Halt {
    Wfi,
    UartPoll,
    Srst,
    Limit,
    Unimp(u32),
}

/// One live `__dom` node record as the exec model snapshots it:
/// `(idx, tag, parent, x, y, w, h, tlen, text)`.
pub type DomtNodeRow = (u32, u32, u32, u32, u32, u32, u32, u32, String);

#[derive(Debug, Clone)]
pub struct Smoke {
    pub console: String,
    pub steps: u32,
    pub halt: Halt,
    pub satp: u64,
    /// SBI TIME ecalls (TimerInit + each IRQ_TIMER).
    pub time_ecalls: u32,
    /// Supervisor timer traps taken (irq 5).
    pub ticks: u32,
    /// Synchronous exceptions taken (`trap_fault`).
    pub faults: u32,
    /// PLIC SEI (irq 9) deliveries.
    pub sei_claims: u32,
    /// SBI HSM hart_start calls.
    pub hsm_starts: u32,
    /// SBI IPI send_ipi calls.
    pub ipi_sends: u32,
    /// Latched `G6MB` identity from MboxInit (doorbell may later become a kick).
    pub mbox_magic: u32,
    /// Mailbox STATUS after command service.
    pub mbox_status: u32,
    /// First little-endian word of the mailbox RSP buffer.
    pub mbox_rsp: u32,
    /// Second little-endian word of the mailbox RSP buffer (GET size).
    pub mbox_rsp1: u32,
    /// Mailbox LENGTH after command service.
    pub mbox_len: u32,
    /// ns16550 RBR bytes drained by `trap_uart`.
    pub uart_rxs: u32,
    /// SysGrInit `GR16` magic written at `__gr_plane`.
    pub gr_magic: u32,
    /// First word of the 4bpp plane (boot scanline).
    pub gr_pix0: u32,
    /// First word of the G6LC 8×8 blit (y=8, glyph G).
    pub gr_glyph0: u32,
    /// Guest `G6UI` ident at `__ui_blob`.
    pub ui_magic: u32,
    /// Guest advertised wasm size (bytes).
    pub ui_size: u32,
    /// Guest G6UI flags word.
    pub ui_flags: u32,
    /// Guest `proxy.accel` code at G6UI+12.
    pub ui_accel: u32,
    /// First word of `__ui_wasm` echoed by FileServe (`\0asm`).
    pub ui_wasm_magic: u32,
    /// Number of `/ui/` paths FileServe published.
    pub ui_nfiles: u32,
    /// Guest DOM row count at `__ui_dom` (WasmStart `set_inner_text` calls).
    pub dom_rows: u32,
    /// A DOM row with id `inp.last` exists — `DomKey` mirrored a queued
    /// virtio-input EV_KEY into the DOM (the guest input→DOM bridge).
    pub dom_lastkey: bool,
    /// A DOM row with id `nav.sel` exists — `DomNav` drove the menu
    /// selection from queued EV_KEY events (input → menu navigation).
    pub dom_nav: bool,
    /// `nav.sel` row text (`"nav <name>"` or `"open <name>"` after Enter).
    pub dom_navtext: String,
    /// First painted 4bpp word at the DOM text origin (y=DOM_Y0).
    pub dom_pix0: u32,
    /// `__dom` (DomT) bump-alloc cursor `H_NEXT` — nodes the guest DOM arena
    /// allocated (root + cell-created). `0` when no DomT arena was resolved.
    pub domt_next: u32,
    /// `__dom` nodes with a nonzero `N_TAG` — live (non-free) nodes.
    pub domt_live: u32,
    /// `__dom` nodes with a nonzero `N_LEV` event mask — a registered
    /// `add_event_listener` (the BIOS protocol passes `listener=0`, so
    /// `N_LISTEN` stays 0 and `N_LEV` is the real registration signal).
    pub domt_listen: u32,
    /// `__dom_id` slots carrying a set id — `setProperty(..,"id",..)` writes.
    pub domt_ids: u32,
    /// Debug snapshot of each live `__dom` node after the run. Lets a test
    /// verify the guest `DomtLayout` actually nested/placed the tree rather
    /// than guess.
    pub domt_nodes: Vec<DomtNodeRow>,
    /// Executed `__gr_plane` bytes (GR16 header + 4bpp plane) when Gr live.
    pub gr_frame: Vec<u8>,
    /// Final virtio STATUS register (0xF = ACK|DRIVER|FEATURES_OK|DRIVER_OK).
    pub vio_status: u32,
    /// Last ctrlq `type` the device model serviced (0x0100 = GET_DISPLAY_INFO).
    pub vio_last_cmd: u32,
    /// Last response `type` written to a device-write desc (0x1101 = DISPLAY_INFO).
    pub vio_last_resp: u32,
    /// Device-side X8R8G8B8 scanout surface written by `TRANSFER_TO_HOST_2D`.
    pub vio_fb: Vec<u8>,
    /// Program counter at halt — where a `Limit` run was spinning.
    pub pc: u64,
    /// 64-byte window of memory around `pc` at halt — lets a test disassemble
    /// the exact instructions a spinning/trapping pc was executing.
    pub pc_win: Vec<u8>,
    /// Native 32bpp `__scan_fb` contents at the end of the run (when the
    /// module allocated a scanout surface; empty otherwise).
    pub scan_fb: Vec<u8>,
    /// Scanout surface geometry (resource w/h).
    pub vio_fb_w: u32,
    pub vio_fb_h: u32,
    /// `SET_SCANOUT` completed.
    pub vio_scanout: bool,
    /// Tablet eventq was DRIVER_OK / QUEUE_READY.
    pub tab_ready: bool,
    /// Posted tablet event buffers the device still holds.
    pub tab_bufs: usize,
    pub tab_qused: u64,
    pub tab_poked: bool,
    /// `RESOURCE_FLUSH` count.
    pub vio_flushes: u32,
    /// Negotiated virgl capset id (`GET_CAPSET_INFO` → `CAPSET`), nonzero when
    /// the `proxy.gl` device answered the CAPSET handshake (M4).
    pub virgl_capset: u32,
    /// Virgl contexts created (`CTX_CREATE`).
    pub virgl_ctxs: u32,
    /// `SUBMIT_3D` submissions the device accepted (execbuffer parsed + run).
    pub virgl_submits: u32,
    /// `DRAW_VBO` draws that reached the surface (fb bound + surface object).
    pub virgl_draws: u32,
    /// Pixels the modelled virgl raster wrote into `vio_fb` (textured quad).
    pub virgl_px: u32,
    /// Device-side surface of the virgl offscreen render target — the textured
    /// quad `SUBMIT_3D` rasterized (empty unless the virgl lane ran).
    pub virgl_fb: Vec<u8>,
    /// Guest-RAM `__virgl_out` after `TRANSFER_FROM_HOST_3D` — the rendered
    /// quad DMA'd back into guest memory (empty unless the readback ran).
    pub virgl_out: Vec<u8>,
    /// `SET_SCANOUT` moved the console onto the virgl render target — the
    /// virgl composite present path.
    pub virgl_scanout: bool,
    /// `RESOURCE_FLUSH` count on the virgl render target.
    pub virgl_flushes: u32,
    /// The scanout surface as `SUBMIT_3D` sampled it — the composite's input
    /// (a repaint may have since overwritten `vio_fb`).
    pub virgl_src: Vec<u8>,
    /// Compact persist magic (`G6CP`) when `__ui_cap` is allocated.
    pub cap_magic: u32,
    /// Live g6b-dom node count packed into `__ui_cap` (B91).
    pub cap_nodes: u32,
    /// Dirty-tile count remaining in `__ui_cap` after the run.
    pub cap_tiles: u32,
    /// Used-buffer interrupt assertions (InterruptStatus bit 0 sets).
    pub vio_irqs: u32,
    /// virtio-blk requests the modelled device completed. A test asserts the
    /// driver *asked the device* for its sectors rather than reading stale RAM.
    pub blk_reqs: u32,
    /// Uncore display engine latched a scanout commit (`disp`-class
    /// peripheral; `architecture/uncore/hdmi-display.md`).
    pub disp_committed: bool,
    /// Display-engine framebuffer descriptor: (fb, width, height, stride,
    /// format) latched at COMMIT.
    pub disp_desc: (u64, u32, u32, u32, u32),
    /// `DispSel` result read out of `__disp`: `(class, surface, w, h, stride,
    /// hpd)`. Class/surface follow `g6b_spec::OutputClass::code` and
    /// `Surface::code`; `hpd` is one of `vio::HPD_*`.
    pub disp_sel: (u32, u32, u32, u32, u32, u32),
    /// `PciProbe` result: `(bar0, vendor<<16|device)`, both 0 when nothing was
    /// accepted.
    pub pci_fb: (u32, u32),
    /// Device-memory shadow of the accepted linear BAR — what `PciPaint`
    /// blitted into it (`FbExpandSel` destination = `__disp.fb`). Empty when
    /// no PCIe display device was modelled.
    pub pci_fb_img: Vec<u8>,
}

/// Lower `module` at `entry` and run hart 0 until park/UART/SBI SRST.
pub fn run_module(spec: &BoardSpec, module: &Module, entry: u64) -> Result<Smoke, String> {
    run_module_hart(spec, module, entry, 0)
}

pub fn run_module_with_limit(
    spec: &BoardSpec,
    module: &Module,
    entry: u64,
    step_limit: u32,
) -> Result<Smoke, String> {
    if step_limit == 0 || step_limit > 192_000_000 {
        return Err("execution step limit must be in 1..=192000000".into());
    }
    run_module_web_inner(spec, module, entry, 0, b'V', None, None, step_limit)
}

/// Same as [`run_module`] with OpenSBI `a0=hartid`.
pub fn run_module_hart(
    spec: &BoardSpec,
    module: &Module,
    entry: u64,
    hartid: u64,
) -> Result<Smoke, String> {
    run_module_web(spec, module, entry, hartid, None)
}

/// Same as [`run_module`] but with a custom virtio-blk backing image.
pub fn run_module_with_blk_image(
    spec: &BoardSpec,
    module: &Module,
    entry: u64,
    blk_image: Vec<u8>,
) -> Result<Smoke, String> {
    run_module_hart_with_blk_image(spec, module, entry, 0, blk_image)
}

/// Same as [`run_module_hart`] but with a custom virtio-blk backing image.
pub fn run_module_hart_with_blk_image(
    spec: &BoardSpec,
    module: &Module,
    entry: u64,
    hartid: u64,
    blk_image: Vec<u8>,
) -> Result<Smoke, String> {
    let (insns, rodata) = module.to_words(entry)?;
    let mut image = Vec::with_capacity(insns.len() * 4 + rodata.len());
    for w in insns {
        image.extend_from_slice(&w.to_le_bytes());
    }
    image.extend_from_slice(&rodata);
    let memsz = payload_memsz(image.len() as u64, module.n_harts(), module.extra_bss());
    let uart_ui_pc = module.label_addr(entry, "uart_ui").unwrap_or(0);
    let trap_timer_pc = module.label_addr(entry, "trap_timer").unwrap_or(0);
    run_with_kick(
        spec,
        &image,
        entry,
        memsz,
        hartid,
        b'V',
        spec.wants_virtio_gpu(),
        true,
        module.vio_bss_addr(entry).unwrap_or(0),
        module.scan_fb_addr(entry).unwrap_or(0),
        module.vio_fb_bytes,
        module.cap_addr(entry).unwrap_or(0),
        module.domt_addr(entry).unwrap_or(0),
        None,
        None,
        uart_ui_pc,
        trap_timer_pc,
        Some(blk_image),
        STEP_LIMIT,
    )
}

/// Host-injected Canvas32 + dirty tiles for the guest compact persist (B91).
/// Exec writes these into `__scan_fb` / `__ui_cap` before the payload runs
/// so `VioPaint` TRANSFERs the web engine, not a glyph expand. Does not
/// grow `start_ops`.
#[derive(Debug, Clone, Default)]
pub struct GuestWebPresent {
    pub scan_fb: Vec<u8>,
    pub tiles: Vec<DirtyTile>,
    pub node_count: u32,
}

/// One virtio-gpu `TRANSFER_TO_HOST_2D` rectangle packed into `__ui_cap`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct DirtyTile {
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
}

/// Live svelte-d engine the exec model can ask for a fresh Canvas32 when
/// the guest UART `Ui` command runs. Implemented in `g6b-kernel` so this
/// crate does not depend on the browser session.
pub trait WebFeed {
    fn initial(&mut self) -> Option<GuestWebPresent>;
    /// UART `Ui` ≡ UI-hart tick: restyle + GLES2 pack for the next `VioPaint`.
    fn on_guest_ui(&mut self) -> Option<GuestWebPresent>;
    /// virtio-input `EV_KEY` (Linux `KEY_*` / `BTN_*` code, press=true).
    /// Default ignore.
    fn on_guest_key(&mut self, _code: u16, _pressed: bool) -> Option<GuestWebPresent> {
        let _ = (_code, _pressed);
        None
    }
    /// virtio-input `EV_ABS` (Linux `ABS_*` axis, tablet 0..=`VIO_ABS_MAX`).
    /// Default ignore.
    fn on_guest_abs(&mut self, _axis: u16, _value: u32) -> Option<GuestWebPresent> {
        let _ = (_axis, _value);
        None
    }
    /// virtio-input `EV_REL` (Linux `REL_*` axis, signed pixel delta).
    /// Default ignore.
    fn on_guest_rel(&mut self, _axis: u16, _value: i32) -> Option<GuestWebPresent> {
        let _ = (_axis, _value);
        None
    }
    /// Tablet ABS pair (`ABS_X`, `ABS_Y`) the exec-model poke may write.
    /// Default none — dummy (0,0) still drains the tablet eventq.
    fn hint_abs(&self) -> Option<(u32, u32)> {
        None
    }
    /// Guest `trap_timer` ≡ UI-hart `tick`. Return `None` when skip-if-clean
    /// (no CSS dirty / no due rAF) so `VioPaint` does not TRANSFER.
    fn on_guest_tick(&mut self) -> Option<GuestWebPresent> {
        None
    }
}

/// Like [`run_module`] with an optional web-engine present (compact persist).
pub fn run_module_web(
    spec: &BoardSpec,
    module: &Module,
    entry: u64,
    hartid: u64,
    web: Option<&GuestWebPresent>,
) -> Result<Smoke, String> {
    run_module_web_inner(spec, module, entry, hartid, b'V', web, None, STEP_LIMIT)
}

/// Same as [`run_module_web`] but UART `Ui` re-queries [`WebFeed::on_guest_ui`]
/// and re-injects `__ui_cap` so skip-if-clean is not stuck on the boot frame.
pub fn run_module_web_feed(
    spec: &BoardSpec,
    module: &Module,
    entry: u64,
    hartid: u64,
    feed: &mut dyn WebFeed,
) -> Result<Smoke, String> {
    run_module_web_feed_kick(spec, module, entry, hartid, b'V', feed)
}

/// Same as [`run_module_web_feed`] with a mailbox doorbell byte (`U` = Ui).
pub fn run_module_web_feed_kick(
    spec: &BoardSpec,
    module: &Module,
    entry: u64,
    hartid: u64,
    kick: u8,
    feed: &mut dyn WebFeed,
) -> Result<Smoke, String> {
    run_module_web_inner(
        spec,
        module,
        entry,
        hartid,
        kick,
        None,
        Some(feed),
        STEP_LIMIT,
    )
}

#[allow(clippy::too_many_arguments)]
fn run_module_web_inner(
    spec: &BoardSpec,
    module: &Module,
    entry: u64,
    hartid: u64,
    kick: u8,
    web: Option<&GuestWebPresent>,
    feed: Option<&mut dyn WebFeed>,
    step_limit: u32,
) -> Result<Smoke, String> {
    let (insns, rodata) = module.to_words(entry)?;
    let mut image = Vec::with_capacity(insns.len() * 4 + rodata.len());
    for w in insns {
        image.extend_from_slice(&w.to_le_bytes());
    }
    image.extend_from_slice(&rodata);
    let memsz = payload_memsz(image.len() as u64, module.n_harts(), module.extra_bss());
    let uart_ui_pc = module.label_addr(entry, "uart_ui").unwrap_or(0);
    let trap_timer_pc = module.label_addr(entry, "trap_timer").unwrap_or(0);
    run_with_kick(
        spec,
        &image,
        entry,
        memsz,
        hartid,
        kick,
        spec.wants_virtio_gpu(),
        true,
        module.vio_bss_addr(entry).unwrap_or(0),
        module.scan_fb_addr(entry).unwrap_or(0),
        module.vio_fb_bytes,
        module.cap_addr(entry).unwrap_or(0),
        module.domt_addr(entry).unwrap_or(0),
        web,
        feed,
        uart_ui_pc,
        trap_timer_pc,
        None,
        step_limit,
    )
}

/// Same as [`run_module`] but the host poke uses `cmd` as the first mailbox byte.
pub fn run_module_kick(
    spec: &BoardSpec,
    module: &Module,
    entry: u64,
    kick: u8,
) -> Result<Smoke, String> {
    let (insns, rodata) = module.to_words(entry)?;
    let mut image = Vec::with_capacity(insns.len() * 4 + rodata.len());
    for w in insns {
        image.extend_from_slice(&w.to_le_bytes());
    }
    image.extend_from_slice(&rodata);
    let memsz = payload_memsz(image.len() as u64, module.n_harts(), module.extra_bss());
    run_with_kick(
        spec,
        &image,
        entry,
        memsz,
        0,
        kick,
        spec.wants_virtio_gpu(),
        true,
        module.vio_bss_addr(entry).unwrap_or(0),
        module.scan_fb_addr(entry).unwrap_or(0),
        module.vio_fb_bytes,
        module.cap_addr(entry).unwrap_or(0),
        module.domt_addr(entry).unwrap_or(0),
        None,
        None,
        0,
        0,
        None,
        STEP_LIMIT,
    )
}

/// Same as [`run_module`] but overrides whether the virtio-gpu mmio device is
/// modeled — for the `VIRTIO-GPU-NONE` (absent device) path.
pub fn run_module_no_gpu(spec: &BoardSpec, module: &Module, entry: u64) -> Result<Smoke, String> {
    let (insns, rodata) = module.to_words(entry)?;
    let mut image = Vec::with_capacity(insns.len() * 4 + rodata.len());
    for w in insns {
        image.extend_from_slice(&w.to_le_bytes());
    }
    image.extend_from_slice(&rodata);
    let memsz = payload_memsz(image.len() as u64, module.n_harts(), module.extra_bss());
    run_with_kick(
        spec,
        &image,
        entry,
        memsz,
        0,
        b'V',
        false,
        true,
        module.vio_bss_addr(entry).unwrap_or(0),
        module.scan_fb_addr(entry).unwrap_or(0),
        module.vio_fb_bytes,
        module.cap_addr(entry).unwrap_or(0),
        module.domt_addr(entry).unwrap_or(0),
        None,
        None,
        0,
        0,
        None,
        STEP_LIMIT,
    )
}

/// Same as [`run_module`] but models *stock QEMU virt*: no g6lc-bios mailbox
/// and no second ns16550 — the `MboxInit`/`uart1` probe windows must detect
/// absence (fault-recover on unmapped MMIO) instead of parking.
pub fn run_module_bare(spec: &BoardSpec, module: &Module, entry: u64) -> Result<Smoke, String> {
    let (insns, rodata) = module.to_words(entry)?;
    let mut image = Vec::with_capacity(insns.len() * 4 + rodata.len());
    for w in insns {
        image.extend_from_slice(&w.to_le_bytes());
    }
    image.extend_from_slice(&rodata);
    let memsz = payload_memsz(image.len() as u64, module.n_harts(), module.extra_bss());
    run_with_kick(
        spec,
        &image,
        entry,
        memsz,
        0,
        b'V',
        spec.wants_virtio_gpu(),
        false,
        module.vio_bss_addr(entry).unwrap_or(0),
        module.scan_fb_addr(entry).unwrap_or(0),
        module.vio_fb_bytes,
        module.cap_addr(entry).unwrap_or(0),
        module.domt_addr(entry).unwrap_or(0),
        None,
        None,
        0,
        0,
        None,
        STEP_LIMIT,
    )
}

pub fn run(
    spec: &BoardSpec,
    image: &[u8],
    entry: u64,
    memsz: u64,
    hartid: u64,
) -> Result<Smoke, String> {
    run_with_kick(
        spec,
        image,
        entry,
        memsz,
        hartid,
        b'V',
        spec.wants_virtio_gpu(),
        true,
        // Raw-image entry point: no module, so the `__vio` layout is unknown
        // and the display-mux read-out is skipped rather than guessed.
        0,
        // Raw-image entry point: no module, so the `__scan_fb` layout is
        // unknown and is skipped rather than guessed.
        0,
        0,
        0,
        0,
        None,
        None,
        0,
        0,
        None,
        STEP_LIMIT,
    )
}

#[allow(clippy::too_many_arguments)]
fn run_with_kick(
    spec: &BoardSpec,
    image: &[u8],
    entry: u64,
    memsz: u64,
    hartid: u64,
    kick: u8,
    vio_gpu: bool,
    extras: bool,
    // Resolved `__vio` address so `done()` can read the `DispSel`/`PciProbe`
    // result block. `0` when the caller has no module to resolve it from.
    vio_base: u64,
    // Resolved `__scan_fb` address and size so `done()` can report the native
    // 32bpp surface. Both `0` when the caller has no module to resolve it from.
    scan_fb_base: u64,
    scan_fb_bytes: u64,
    cap_base: u64,
    // Resolved `__dom` (DomT) arena base so `done()` can snapshot the live DOM
    // (`__dom`/`__dom_str`/`__dom_id` are contiguous). `0` when the caller has
    // no module to resolve it from.
    domt_base: u64,
    web: Option<&GuestWebPresent>,
    mut feed: Option<&mut dyn WebFeed>,
    uart_ui_pc: u64,
    trap_timer_pc: u64,
    blk_image: Option<Vec<u8>>,
    step_limit: u32,
) -> Result<Smoke, String> {
    let xlen = spec.isa.xlen;
    if xlen != 32 && xlen != 64 {
        return Err(format!("unsupported xlen {xlen}"));
    }
    // `__uart_line` BSS base: stacks region + the gr plane. The CLI/autoboot
    // line state (`AUTO_ON`, `FACE_OWNER`, `WEB_STAMPED`, the edit line) lives
    // here regardless of whether the wasm/http `__ui_blob` follows it.
    let line_base = {
        let stacks = entry.wrapping_add(stack_memsz(image.len() as u64, spec.harts.max(1)));
        let gr = if spec.kernel.gr.enable || spec.kernel.proxy.enable {
            let w = if spec.kernel.gr.enable {
                spec.kernel.gr.w.max(8)
            } else {
                640
            };
            let h = if spec.kernel.gr.enable {
                spec.kernel.gr.h.max(8)
            } else {
                480
            };
            gr_bss_len(w, h, spec.kernel.gr.colors.max(16))
        } else {
            0
        };
        stacks.wrapping_add(gr)
    };
    let mut ram = vec![0u8; memsz as usize];
    if image.len() > ram.len() {
        return Err("image larger than memsz".into());
    }
    ram[..image.len()].copy_from_slice(image);
    if let Some(web) = web {
        inject_web_present(&mut ram, entry, scan_fb_base, cap_base, line_base, web);
    } else if let Some(feed) = feed.as_mut() {
        if let Some(present) = feed.initial() {
            inject_web_present(&mut ram, entry, scan_fb_base, cap_base, line_base, &present);
        }
    }
    let mut x = [0u64; 32];
    x[10] = hartid; // a0 hartid
                    // a1 models the OpenSBI handoff: the *boot* hart gets the FDT pointer
                    // (nonzero), harts started via SBI HSM get a1=opaque=0 — the payload
                    // parks on a1==0, so any hart id can be primary. The model's boot hart
                    // is hart 0; the marker is never dereferenced.
    x[11] = if hartid == 0 { 0x8fe0_0000 } else { 0 };
    let mut pc = entry;
    // One modelled bus-0 display controller when the board asks for the
    // scan: QEMU-stdvga-shaped (vendor 0x1234), base class 0x03, with BAR0
    // parked at the declared window base so it is inside `pcie.mmio`. This
    // stands in for "firmware already mode-set an adapter"; there is no
    // AtomBIOS/GSP model because there is no such guest code to exercise.
    let pci_dev = spec.pcie_ecam().and_then(|_| {
        let (mmio, _) = spec.pcie_mmio_window()?;
        Some((1u64, 0x1234_1111u32, 0x0300_0000u32, mmio as u32))
    });
    // The accepted BAR is device memory, not guest RAM: `PciPaint` blits
    // straight into it (`DISP_SEL_FB_LO`), so the model keeps a bounded shadow.
    // The aperture is `VIO_FB_MAX` — the BAR's size is a device property the
    // read-only `PciProbe` deliberately cannot discover (sizing needs a BAR
    // write), so the modelled aperture is the largest surface a blit can
    // produce. Stores past it still fault like any other unmapped MMIO.
    let pci_fb_base = pci_dev.map(|d| u64::from(d.3)).unwrap_or(0);
    let pci_fb_img = if pci_dev.is_some() {
        vec![0u8; crate::vio::VIO_FB_MAX as usize]
    } else {
        Vec::new()
    };
    let mut csr = Csr {
        mbox_base: if extras && spec.loopback.enable {
            hex_u64(&spec.loopback.base)
        } else {
            0
        },
        mbox_irq: spec.loopback.irq,
        mbox_cmd: vec![0; 256],
        mbox_rsp: vec![0; 256],
        uart1_repl: extras && spec.holyc.dual_band.tcp.enable,
        uart1_base: crate::analyze::uart1_base(spec),
        vio_gpu,
        // `virtio-gpu-gl-device` (proxy.gl): offer F_VIRGL + the 3D commands.
        vio_gl: vio_gpu && spec.kernel.proxy.enable && spec.kernel.proxy.gl,
        vio_inp: vio_gpu && spec.wants_virtio_input(),
        vio_net: spec.wants_virtio_net(),
        vio_blk: spec.wants_virtio_blk(),
        blk_status: 0,
        blk_feat_sel: 0,
        blk_qsel: 0,
        blk_qnum: 0,
        blk_qdesc: 0,
        blk_qavail: 0,
        blk_qused: 0,
        blk_ready: false,
        blk_isr: 0,
        blk_used_idx: 0,
        blk_image: if let Some(img) = blk_image {
            img
        } else if spec.wants_virtio_blk() {
            modelled_blk_image()
        } else {
            Vec::new()
        },
        blk_reqs: 0,
        vio_base,
        scan_fb_base,
        scan_fb_bytes,
        cap_base,
        domt_base,
        pci_ecam: spec.pcie_ecam().unwrap_or(0),
        pci_dev,
        pci_fb_base,
        pci_fb_img,
        vio_disp_w: if spec.kernel.gr.enable {
            spec.kernel.gr.w.max(8)
        } else {
            640
        },
        vio_disp_h: if spec.kernel.gr.enable {
            spec.kernel.gr.h.max(8)
        } else {
            480
        },
        gr_bytes: if spec.kernel.gr.enable || spec.kernel.proxy.enable {
            let w = if spec.kernel.gr.enable {
                spec.kernel.gr.w.max(8)
            } else {
                640
            };
            let h = if spec.kernel.gr.enable {
                spec.kernel.gr.h.max(8)
            } else {
                480
            };
            gr_bss_len(w, h, spec.kernel.gr.colors.max(16))
        } else {
            0
        },
        gr_base: {
            if spec.kernel.gr.enable || spec.kernel.proxy.enable {
                entry.wrapping_add(stack_memsz(image.len() as u64, spec.harts.max(1)))
            } else {
                0
            }
        },
        gr_glyph_off: if spec.kernel.gr.enable || spec.kernel.proxy.enable {
            let w = if spec.kernel.gr.enable {
                spec.kernel.gr.w.max(8)
            } else {
                640
            };
            let stride = gr_stride(w, spec.kernel.gr.colors.max(16));
            GR_HEADER_BYTES + 8 * u64::from(stride)
        } else {
            0
        },
        gr_dom_off: if spec.kernel.gr.enable || spec.kernel.proxy.enable {
            let w = if spec.kernel.gr.enable {
                spec.kernel.gr.w.max(8)
            } else {
                640
            };
            let stride = gr_stride(w, spec.kernel.gr.colors.max(16));
            GR_HEADER_BYTES + crate::dom::DOM_Y0 as u64 * u64::from(stride)
        } else {
            0
        },
        line_base,
        ui_base: if spec.kernel.wasm.enable || spec.kernel.http.files.enable {
            // `__ui_blob` follows the `__uart_line` BSS block.
            line_base.wrapping_add(UART_LINE_BSS)
        } else {
            0
        },
        dom_base: {
            // `__ui_blob` only exists when the UI object is live; the row table
            // follows it. Both the wasm DOM lane and the CLI text face use the
            // same table, so the probe latches it for either.
            let ui = if spec.kernel.wasm.enable || spec.kernel.http.files.enable {
                crate::UI_HEADER_BYTES
            } else {
                0
            };
            if (spec.kernel.wasm.enable && spec.kernel.wasm.jit)
                || crate::analyze::wants_cli_face(spec)
            {
                line_base.wrapping_add(UART_LINE_BSS).wrapping_add(ui)
            } else {
                0
            }
        },
        disp_base: spec.display_ctrl().unwrap_or(0),
        jit_lane: spec.kernel.wasm.enable && spec.kernel.wasm.jit,
        cli_face: crate::analyze::wants_cli_face(spec),
        ..Default::default()
    };
    let mut console = String::new();
    let mut uart_polls = 0u32;
    let mut steps = 0u32;
    loop {
        if steps >= step_limit {
            return Ok(done(
                console,
                steps,
                Halt::Limit,
                &csr,
                &ram,
                entry,
                xlen,
                pc,
            ));
        }
        steps += 1;
        csr.time = csr.time.wrapping_add(1);
        // Deliver the canned input burst as soon as the boot picker is armed
        // (`__uart_line[AUTO_ON]`), not only on `wfi`. The picker's vga-surface
        // `FbExpand` upscales the low-res plane to the full scanout and can
        // spend the whole step budget before `park`, so a halt-gated poke would
        // never land the irq. `take_pending_sei` runs every step, so raising
        // irq 2 here reaches `CliKey`→`AutoKey` at the next boundary while the
        // picker still owns the plane — and lets `AutoPick` flip `__disp.surface`
        // to gpu before `VioPaint`, which then skips `FbExpand` entirely.
        if !csr.inp_poked
            && csr.vio_inp
            && csr.inp_ready
            && csr.inp_qused != 0
            && !csr.inp_bufs.is_empty()
            && csr.line_base != 0
            && load_u32(
                &ram,
                entry,
                csr.line_base.wrapping_add(crate::AUTO_ON_OFF as u64),
            )
            .unwrap_or(0)
                != 0
        {
            let evs = host_inp_kick(&mut csr, &mut ram, entry);
            feed_events(
                &mut feed,
                &mut ram,
                entry,
                scan_fb_base,
                cap_base,
                line_base,
                evs,
            );
        }
        if take_pending_sei(xlen, &mut pc, &mut csr) {
            continue;
        }
        if uart_ui_pc != 0 && pc == uart_ui_pc {
            if let Some(feed) = feed.as_mut() {
                if let Some(present) = feed.on_guest_ui() {
                    inject_web_present(
                        &mut ram,
                        entry,
                        scan_fb_base,
                        cap_base,
                        line_base,
                        &present,
                    );
                }
            }
        }
        if trap_timer_pc != 0 && pc == trap_timer_pc {
            if let Some(feed) = feed.as_mut() {
                if let Some(present) = feed.on_guest_tick() {
                    inject_web_present(
                        &mut ram,
                        entry,
                        scan_fb_base,
                        cap_base,
                        line_base,
                        &present,
                    );
                }
            }
        }
        let w = match fetch_u32(&ram, entry, pc) {
            Some(w) => w,
            None => {
                return Ok(done(
                    console,
                    steps,
                    Halt::Unimp(0),
                    &csr,
                    &ram,
                    entry,
                    xlen,
                    pc,
                ))
            }
        };
        match step(
            xlen,
            &mut x,
            &mut pc,
            &mut csr,
            &mut ram,
            entry,
            w,
            &mut console,
            &mut uart_polls,
        ) {
            Step::Cont => {}
            Step::Halt(h) => {
                if host_mbox_kick(&mut csr, kick) && take_pending_sei(xlen, &mut pc, &mut csr) {
                    continue;
                }
                // Input before UART: the canned key lands in INP_KQ early so a
                // `Keys` command later in the UART sequence finds it queued
                // (QEMU `sendkey` arrives asynchronously the same way). The
                // `AUTO_ON`-armed kick above usually lands this first; this
                // remains the fallback for non-autoboot faces.
                let evs = host_inp_kick(&mut csr, &mut ram, entry);
                let had_inp = !evs.is_empty();
                feed_events(
                    &mut feed,
                    &mut ram,
                    entry,
                    scan_fb_base,
                    cap_base,
                    line_base,
                    evs,
                );
                // Same Halt as keys: after InpDrain the guest often stays in
                // the UART poll loop and never WFI-Halts again for a second
                // poke. KEY SEQ is unchanged; tablet is EV_ABS only.
                let hint = feed.as_ref().and_then(|f| f.hint_abs());
                let tabs = host_inp_tab_kick(&mut csr, &mut ram, entry, hint);
                let had_tab = !tabs.is_empty();
                feed_events(
                    &mut feed,
                    &mut ram,
                    entry,
                    scan_fb_base,
                    cap_base,
                    line_base,
                    tabs,
                );
                if (had_inp || had_tab) && take_pending_sei(xlen, &mut pc, &mut csr) {
                    continue;
                }
                if host_uart_kick(&mut csr) && take_pending_sei(xlen, &mut pc, &mut csr) {
                    continue;
                }
                return Ok(done(console, steps, h, &csr, &ram, entry, xlen, pc));
            }
        }
        if uart_polls > 16 && !console.is_empty() {
            if host_mbox_kick(&mut csr, kick) && take_pending_sei(xlen, &mut pc, &mut csr) {
                uart_polls = 0;
                continue;
            }
            if host_uart_kick(&mut csr) && take_pending_sei(xlen, &mut pc, &mut csr) {
                uart_polls = 0;
                continue;
            }
            return Ok(done(
                console,
                steps,
                Halt::UartPoll,
                &csr,
                &ram,
                entry,
                xlen,
                pc,
            ));
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn done(
    console: String,
    steps: u32,
    halt: Halt,
    csr: &Csr,
    ram: &[u8],
    base: u64,
    xlen: u32,
    pc: u64,
) -> Smoke {
    let gr_frame = if csr.gr_base != 0 && csr.gr_bytes != 0 {
        let off = csr.gr_base.wrapping_sub(base) as usize;
        let end = off.saturating_add(csr.gr_bytes as usize).min(ram.len());
        if off < end {
            ram[off..end].to_vec()
        } else {
            Vec::new()
        }
    } else {
        Vec::new()
    };
    // Walk the DOM row table for a row id → (text_ptr, text_len).
    let dom_find = |id: &[u8]| -> Option<(u64, u32)> {
        if csr.dom_base == 0 {
            return None;
        }
        (0..csr.dom_rows.min(48)).find_map(|i| {
            let row = csr
                .dom_base
                .wrapping_add(crate::dom::DOM_HDR as u64 + u64::from(i) * 32);
            let idp = if xlen == 64 {
                load_u64(ram, base, row).unwrap_or(0)
            } else {
                u64::from(load_u32(ram, base, row).unwrap_or(0))
            };
            let idl = load_u32(ram, base, row + 16).unwrap_or(0);
            if idl != id.len() as u32
                || !(0..u64::from(idl))
                    .all(|k| load_u8(ram, base, idp.wrapping_add(k)) == Some(id[k as usize]))
            {
                return None;
            }
            let tp = if xlen == 64 {
                load_u64(ram, base, row + 8).unwrap_or(0)
            } else {
                u64::from(load_u32(ram, base, row + 8).unwrap_or(0))
            };
            Some((tp, load_u32(ram, base, row + 20).unwrap_or(0)))
        })
    };
    // `inp.last` (DomKey) — newest queued key mirrored into the DOM.
    let dom_lastkey = dom_find(b"inp.last").is_some();
    // `nav.sel` (DomNav) — menu navigation row: "nav <name>" / "open <name>".
    let nav = dom_find(b"nav.sel");
    let dom_nav = nav.is_some();
    let dom_navtext = nav
        .map(|(tp, tl)| {
            (0..tl.min(24))
                .filter_map(|k| load_u8(ram, base, tp.wrapping_add(u64::from(k))))
                .map(char::from)
                .collect()
        })
        .unwrap_or_default();
    let pc_win = {
        let off = pc.wrapping_sub(base).wrapping_sub(32) as usize;
        if off < ram.len() {
            let end = (off + 96).min(ram.len());
            ram[off..end].to_vec()
        } else {
            Vec::new()
        }
    };
    // Scan the live `__dom` (DomT) arena: the bump-alloc cursor, live (non-free)
    // nodes, nodes carrying a registered listener, and `__dom_id` slots holding
    // a set id. `domt_base` is `__dom`; `__dom_str`/`__dom_id` follow
    // contiguously so the id table is `__dom + DOMT_BYTES + DOMT_STR_BYTES`.
    let (domt_next, domt_live, domt_listen, domt_ids) = if csr.domt_base != 0 {
        use crate::domt as dt;
        let d = csr.domt_base;
        let next = load_u32(ram, base, d.wrapping_add(dt::H_NEXT as u64)).unwrap_or(0);
        let mut live = 0u32;
        let mut listen = 0u32;
        for i in 0..dt::DOMT_NODES as u64 {
            let n = d
                .wrapping_add(dt::DOMT_HDR as u64)
                .wrapping_add(i * dt::DOMT_NODE as u64);
            if load_u32(ram, base, n.wrapping_add(dt::N_TAG as u64)).unwrap_or(0) != 0 {
                live += 1;
            }
            // `N_LEV` (event mask) is the registration signal — `N_LISTEN` is
            // legitimately `0` for the BIOS protocol listener (`g6b_listen`
            // passes `listener=0` so the host runs fetch/select).
            if load_u32(ram, base, n.wrapping_add(dt::N_LEV as u64)).unwrap_or(0) != 0 {
                listen += 1;
            }
        }
        let id_base = d
            .wrapping_add(dt::DOMT_BYTES)
            .wrapping_add(dt::DOMT_STR_BYTES);
        let mut ids = 0u32;
        for i in 0..dt::DOMT_NODES as u64 {
            let s = id_base.wrapping_add(i * dt::DOMT_ID_SLOT);
            if load_u32(ram, base, s).unwrap_or(0) != 0 {
                ids += 1;
            }
        }
        (next, live, listen, ids)
    } else {
        (0, 0, 0, 0)
    };
    // Debug snapshot of each live `__dom` node's laid-out rect + text so a test
    // can verify DomtLayout actually nested/placed the tree. `__dom_str` sits at
    // `__dom + DOMT_BYTES`; `N_TPTR` is an offset into that pool.
    let mut domt_nodes = Vec::new();
    if csr.domt_base != 0 {
        use crate::domt as dt;
        let d = csr.domt_base;
        let strb = d.wrapping_add(dt::DOMT_BYTES);
        for i in 0..dt::DOMT_NODES as u64 {
            let n = d
                .wrapping_add(dt::DOMT_HDR as u64)
                .wrapping_add(i * dt::DOMT_NODE as u64);
            let tag = load_u32(ram, base, n.wrapping_add(dt::N_TAG as u64)).unwrap_or(0);
            if tag == 0 {
                continue;
            }
            let rd = |o: i32| load_u32(ram, base, n.wrapping_add(o as u64)).unwrap_or(0);
            let tptr = rd(dt::N_TPTR) as u64;
            let tlen = rd(dt::N_TLEN);
            let text: String = (0..tlen.min(64))
                .filter_map(|k| {
                    load_u8(
                        ram,
                        base,
                        strb.wrapping_add(tptr).wrapping_add(u64::from(k)),
                    )
                })
                .map(|b| {
                    if (0x20..0x7f).contains(&b) {
                        b as char
                    } else {
                        '.'
                    }
                })
                .collect();
            domt_nodes.push((
                i as u32,
                tag,
                rd(dt::N_PARENT),
                rd(dt::N_X),
                rd(dt::N_Y),
                rd(dt::N_W),
                rd(dt::N_H),
                tlen,
                format!("{text} bg={:#08x} fg={:#08x}", rd(dt::N_BG), rd(dt::N_FG)),
            ));
        }
    }
    Smoke {
        console,
        steps,
        halt,
        pc,
        pc_win,
        satp: csr.satp,
        time_ecalls: csr.time_ecalls,
        ticks: csr.ticks,
        faults: csr.faults,
        sei_claims: csr.sei_claims,
        hsm_starts: csr.hsm_starts,
        ipi_sends: csr.ipi_sends,
        mbox_magic: csr.mbox_magic,
        mbox_status: csr.mbox_status,
        mbox_rsp: u32::from_le_bytes([
            csr.mbox_rsp[0],
            csr.mbox_rsp[1],
            csr.mbox_rsp[2],
            csr.mbox_rsp[3],
        ]),
        mbox_rsp1: u32::from_le_bytes([
            csr.mbox_rsp[4],
            csr.mbox_rsp[5],
            csr.mbox_rsp[6],
            csr.mbox_rsp[7],
        ]),
        mbox_len: csr.mbox_len,
        uart_rxs: csr.uart_rxs,
        gr_magic: csr.gr_magic,
        gr_pix0: csr.gr_pix0,
        gr_glyph0: csr.gr_glyph0,
        ui_magic: csr.ui_magic,
        ui_size: csr.ui_size,
        ui_flags: csr.ui_flags,
        ui_accel: csr.ui_accel,
        ui_wasm_magic: csr.ui_wasm_magic,
        ui_nfiles: csr.ui_nfiles,
        dom_rows: csr.dom_rows,
        dom_lastkey,
        dom_nav,
        dom_navtext,
        dom_pix0: csr.dom_pix0,
        domt_next,
        domt_live,
        domt_listen,
        domt_ids,
        domt_nodes,
        gr_frame,
        scan_fb: if csr.scan_fb_base != 0 && csr.scan_fb_bytes != 0 {
            let off = csr.scan_fb_base.wrapping_sub(base) as usize;
            let end = off
                .saturating_add(csr.scan_fb_bytes as usize)
                .min(ram.len());
            if off < end {
                ram[off..end].to_vec()
            } else {
                Vec::new()
            }
        } else {
            Vec::new()
        },
        vio_status: csr.vio_status,
        vio_last_cmd: csr.vio_last_cmd,
        vio_last_resp: csr.vio_last_resp,
        vio_fb: csr.vio_fb.clone(),
        vio_fb_w: csr.vio_res_w,
        vio_fb_h: csr.vio_res_h,
        vio_scanout: csr.vio_scanout,
        tab_ready: csr.tab_ready,
        tab_bufs: csr.tab_bufs.len(),
        tab_qused: csr.tab_qused,
        tab_poked: csr.tab_poked,
        vio_flushes: csr.vio_flushes,
        virgl_capset: csr.virgl_capset_id,
        virgl_ctxs: csr.virgl_ctxs,
        virgl_submits: csr.virgl_submits,
        virgl_draws: csr.virgl_draws,
        virgl_px: csr.virgl_px,

        virgl_fb: csr.virgl_fb.clone(),
        virgl_scanout: csr.virgl_scanout,
        virgl_flushes: csr.virgl_flushes,
        virgl_src: csr.virgl_src.clone(),
        virgl_out: {
            // The guest attached `__virgl_out` as RES_RT's backing; read the
            // rendered quad back out of guest RAM at that attached address.
            let rt = csr.virgl_rt;
            let n = (csr.virgl_rt_w as usize) * (csr.virgl_rt_h as usize) * 4;
            match (rt != 0, csr.virgl_backing.get(&rt).copied()) {
                (true, Some(addr)) if n != 0 => {
                    let off = addr.wrapping_sub(base) as usize;
                    let end = off.saturating_add(n).min(ram.len());
                    if off < end {
                        ram[off..end].to_vec()
                    } else {
                        Vec::new()
                    }
                }
                _ => Vec::new(),
            }
        },
        cap_magic: if csr.cap_base != 0 {
            load_u32(ram, base, csr.cap_base).unwrap_or(0)
        } else {
            0
        },
        cap_nodes: if csr.cap_base != 0 {
            load_u32(
                ram,
                base,
                csr.cap_base
                    .wrapping_add(crate::vio::UI_CAP_OFF_NODES as u64),
            )
            .unwrap_or(0)
        } else {
            0
        },
        cap_tiles: if csr.cap_base != 0 {
            load_u32(
                ram,
                base,
                csr.cap_base
                    .wrapping_add(crate::vio::UI_CAP_OFF_NTILE as u64),
            )
            .unwrap_or(0)
        } else {
            0
        },
        vio_irqs: csr.vio_irqs,
        blk_reqs: csr.blk_reqs,
        disp_committed: csr.disp_committed,
        disp_desc: (
            csr.disp_regs[3] as u64 | ((csr.disp_regs[4] as u64) << 32),
            csr.disp_regs[5],
            csr.disp_regs[6],
            csr.disp_regs[7],
            csr.disp_regs[8],
        ),
        disp_sel: {
            let at = |off: i32| {
                if csr.vio_base == 0 {
                    0
                } else {
                    load_u32(ram, base, csr.vio_base.wrapping_add(off as u64)).unwrap_or(0)
                }
            };
            (
                at(crate::vio::DISP_SEL_CLASS),
                at(crate::vio::DISP_SEL_SURFACE),
                at(crate::vio::DISP_SEL_W),
                at(crate::vio::DISP_SEL_H),
                at(crate::vio::DISP_SEL_STRIDE),
                at(crate::vio::DISP_SEL_HPD),
            )
        },
        pci_fb: {
            let at = |off: i32| {
                if csr.vio_base == 0 {
                    0
                } else {
                    load_u32(ram, base, csr.vio_base.wrapping_add(off as u64)).unwrap_or(0)
                }
            };
            (at(crate::vio::DISP_PCI_FB), at(crate::vio::DISP_PCI_ID))
        },
        pci_fb_img: csr.pci_fb_img.clone(),
    }
}

#[derive(Default)]
struct Csr {
    satp: u64,
    stvec: u64,
    sie: u64,
    sstatus: u64,
    scause: u64,
    sepc: u64,
    stval: u64,
    time: u64,
    timecmp: u64,
    time_ecalls: u32,
    ticks: u32,
    faults: u32,
    plic_enable: u32,
    plic_pending: u32,
    plic_threshold: u32,
    plic_claim: u32,
    plic_injected: bool,
    sei_claims: u32,
    hsm_starts: u32,
    ipi_sends: u32,
    mbox_base: u64,
    mbox_irq: u32,
    mbox_magic: u32,
    mbox_doorbell: u32,
    mbox_status: u32,
    mbox_irq_en: u32,
    mbox_len: u32,
    mbox_cmd: Vec<u8>,
    mbox_rsp: Vec<u8>,
    mbox_poked: bool,
    uart0: Uart16550,
    uart1: Uart16550,
    uart1_repl: bool,
    uart1_base: u64,
    uart_rxs: u32,
    uart_seq_i: u8,
    gr_base: u64,
    gr_bytes: u64,
    gr_magic: u32,
    gr_pix0: u32,
    gr_glyph_off: u64,
    gr_glyph0: u32,
    /// `__uart_line` BSS base (`stacks + gr`) — where `CliInit` latches the
    /// autoboot `AUTO_ON` arm flag. Unconditional (unlike `ui_base`, which is
    /// zero without wasm/http) so the armed-input kick works on a CLI-only
    /// picker too.
    line_base: u64,
    ui_base: u64,
    ui_magic: u32,
    ui_size: u32,
    ui_flags: u32,
    ui_accel: u32,
    ui_wasm_magic: u32,
    ui_nfiles: u32,
    dom_base: u64,
    dom_rows: u32,
    dom_pix0: u32,
    /// `kernel.wasm.jit` — the await/throw UART commands exist only there.
    jit_lane: bool,
    /// The guest `g6b-zealcli` container is compiled, so an unmatched band line
    /// is dispatched by `CliEnter`.
    cli_face: bool,
    gr_dom_off: u64,
    /// Modelled virtio-mmio GPU at slot 0 (matches `qemu_dual_band_argv`).
    vio_gpu: bool,
    /// Virtio device registers/status for the slot-0 model.
    vio_status: u32,
    vio_feat_sel: u32,
    vio_drv_sel: u32,
    /// Word-0 feature bits the driver wrote to `DRV_FEATURES` (the negotiated
    /// `VIRTIO_GPU_F_VIRGL` the 3D commands gate on).
    vio_drv_feats: u32,
    vio_qsel: u32,
    vio_qnum: u32,
    vio_qdesc: u64,
    vio_qavail: u64,
    vio_qused: u64,
    vio_ready: bool,
    vio_isr: u32,
    vio_used_idx: u16,
    /// Used-buffer interrupt assertions (bit 0 of InterruptStatus).
    vio_irqs: u32,
    /// Last ctrlq `type` word serviced (e.g. `GET_DISPLAY_INFO` = 0x0100).
    vio_last_cmd: u32,
    /// Last response `type` word written into a device-write desc.
    vio_last_resp: u32,
    /// Modelled virtio-blk at [`VIO_BLK_SLOT`] (DeviceID 2) with a real backing
    /// image: the requestq is serviced, so `BlkRead` reads the bytes the test put
    /// there. This is what makes the guest driver testable without QEMU.
    vio_blk: bool,
    blk_status: u32,
    blk_feat_sel: u32,
    blk_qsel: u32,
    blk_qnum: u32,
    blk_qdesc: u64,
    blk_qavail: u64,
    blk_qused: u64,
    blk_ready: bool,
    blk_isr: u32,
    blk_used_idx: u16,
    /// Sectors the device serves, 512 bytes each.
    blk_image: Vec<u8>,
    /// Requests the device completed — a test asserts the driver asked once, not
    /// that it spun.
    blk_reqs: u32,
    /// Modelled virtio-net at slot 5 (DeviceID 1). Not a QEMU `-netdev`.
    vio_net: bool,
    /// Modelled virtio-input keyboard at slot 1 (`-device
    /// virtio-keyboard-device`; QEMU virt PLIC irq = 1+slot → 2).
    vio_inp: bool,
    inp_status: u32,
    inp_feat_sel: u32,
    inp_drv_sel: u32,
    inp_qsel: u32,
    inp_qnum: u32,
    inp_qdesc: u64,
    inp_qavail: u64,
    inp_qused: u64,
    inp_ready: bool,
    inp_isr: u32,
    /// Used-ring publish index for the input eventq (queue 0).
    inp_used_idx: u16,
    /// Avail-ring entries the device has consumed (eventq buffer posts).
    inp_avail_seen: u16,
    /// Eventq buffers the driver posted and the device holds — each element
    /// is a desc head id waiting for an input event.
    inp_bufs: Vec<u16>,
    /// Host event injection latch (one canned EV_KEY per run).
    inp_poked: bool,
    /// virtio-input config window selector (`select` byte0 | `subsel` byte1)
    /// written by the driver's capability probe. The keyboard reports no
    /// `EV_ABS` bits, so its `EV_BITS`/`EV_ABS` size reads back 0.
    inp_cfgsel: u32,
    /// Modelled virtio-tablet at slot 3 (`-device virtio-tablet-device`).
    /// Slot 2 is unused so PLIC source 3 remains the mailbox. Irq = 1+3 → 4.
    tab_status: u32,
    tab_feat_sel: u32,
    tab_drv_sel: u32,
    tab_qsel: u32,
    tab_qnum: u32,
    tab_qdesc: u64,
    tab_qavail: u64,
    tab_qused: u64,
    tab_ready: bool,
    tab_isr: u32,
    tab_used_idx: u16,
    tab_avail_seen: u16,
    tab_bufs: Vec<u16>,
    tab_poked: bool,
    /// virtio-input config window selector (`select` byte0 | `subsel` byte1)
    /// written by the driver's capability probe. The tablet reports `EV_ABS`,
    /// so `EV_BITS`/`EV_ABS` reads back a nonzero bitmap length — that is how
    /// the probe tells it apart from the keyboard regardless of slot order.
    tab_cfgsel: u32,
    /// Modelled pmode geometry (BoardSpec `kernel.gr.w/h`).
    vio_disp_w: u32,
    vio_disp_h: u32,
    /// Single-resource 2D model: created resource id and geometry.
    vio_res_id: u32,
    vio_res_w: u32,
    vio_res_h: u32,
    /// `ATTACH_BACKING` guest base/length.
    vio_backing: u64,
    vio_backing_len: u64,
    /// `SET_SCANOUT` completed for the resource.
    vio_scanout: bool,
    /// `RESOURCE_FLUSH` count (scanout present updates).
    vio_flushes: u32,
    /// Device-side X8R8G8B8 surface filled by `TRANSFER_TO_HOST_2D` — the
    /// host-modelled analogue of the QEMU scanout pixels.
    vio_fb: Vec<u8>,
    /// `virtio-gpu-gl-device` (`proxy.gl`) — the device offers
    /// `VIRTIO_GPU_F_VIRGL` and services the 3D/`SUBMIT_3D` commands.
    vio_gl: bool,
    /// `GET_CAPSET_INFO` result latched for the response payload.
    virgl_capset_id: u32,
    virgl_capset_ver: u32,
    virgl_capset_size: u32,
    /// Bitmap of created virgl context ids (bit `ctx_id`).
    virgl_ctx: u64,
    /// `CTX_CREATE` commands serviced.
    virgl_ctxs: u32,
    /// Bitmap of resources `CTX_ATTACH_RESOURCE` bound to a ctx.
    virgl_attached: u64,
    /// `SUBMIT_3D` execbuffers consumed.
    virgl_submits: u32,
    /// virgl command headers parsed across all submits.
    virgl_cmds: u32,
    /// `CLEAR` raster ops modelled.
    virgl_clears: u32,
    /// `DRAW_VBO` draws modelled.
    virgl_draws: u32,
    /// Pixels the model rasterizer wrote into `virgl_fb` for the quad.
    virgl_px: u32,
    /// The virgl offscreen render-target resource id (`RESOURCE_CREATE_3D`).
    virgl_rt: u32,
    /// Render-target geometry (w,h).
    virgl_rt_w: u32,
    virgl_rt_h: u32,
    /// Device-side surface for the virgl render target — `SUBMIT_3D` rasters
    /// the textured quad here. Kept separate from `vio_fb` (the 2D scanout)
    /// so the virgl lane never disturbs the committed display frame.
    virgl_fb: Vec<u8>,
    /// Bitmap of `RESOURCE_CREATE_3D` resource ids (≤64) — RT, VBO, …
    virgl_res: u64,
    /// Geometry of each created 3D resource (`res → (w,h)`); buffers keep
    /// their byte size in `w`.
    virgl_dims: std::collections::BTreeMap<u32, (u32, u32)>,
    /// Device-side surfaces for non-RT 3D resources (`res → w*h*4` bytes);
    /// the RT surface stays in `virgl_fb` and the 2D scanout in `vio_fb`.
    virgl_surf: std::collections::BTreeMap<u32, Vec<u8>>,
    /// The texture bytes `SUBMIT_3D` sampled — the scanout surface **at
    /// composite time**. Later repaints (`Ui → VioPaint` on the timer tick)
    /// keep mutating `vio_fb`, so this snapshot is the composite's honest
    /// input record: `virgl_fb` must equal it, not end-state `vio_fb`.
    virgl_src: Vec<u8>,
    /// `SET_SCANOUT` moved the console onto `virgl_rt` (the virgl present).
    virgl_scanout: bool,
    /// `RESOURCE_FLUSH` count on the virgl render target.
    virgl_flushes: u32,
    /// Guest backing for non-scanout (3D) resources — `res_id → base` —
    /// `TRANSFER_FROM_HOST_3D` reads the surface back into this guest buffer.
    virgl_backing: std::collections::BTreeMap<u32, u64>,
    /// Uncore display-engine window base (`display`-class peripheral;
    /// `architecture/uncore/hdmi-display.md`) — 0 = absent.
    disp_base: u64,
    /// Display-engine register file (off/4) for the RW window.
    disp_regs: [u32; 16],
    /// COMMIT latched a scanout (fb/w/h/stride/format valid).
    disp_committed: bool,
    /// STATUS readback: 1 after COMMIT.
    disp_status: u32,
    /// Resolved `__vio` base, for reading the `DispSel`/`PciProbe` block.
    vio_base: u64,
    /// Resolved `__scan_fb` base, for copying the native scanout into `Smoke`.
    scan_fb_base: u64,
    /// Bytes of `__scan_fb` to copy (0 when no native scanout is allocated).
    scan_fb_bytes: u64,
    /// Resolved `__ui_cap` base (0 when the module has no compact persist).
    cap_base: u64,
    /// Resolved `__dom` (DomT) base — `__dom`/`__dom_str`/`__dom_id` snapshot
    /// for the live-DOM regression probes. `0` when no DomT arena exists.
    domt_base: u64,
    /// PCIe ECAM window base — 0 = no host bridge modelled.
    pci_ecam: u64,
    /// Modelled bus-0 display controller: `(dev, vendor<<16|device, class_word,
    /// bar0)`. `None` = no PCIe display device present.
    pci_dev: Option<(u64, u32, u32, u32)>,
    /// Modelled BAR base (device memory, not guest RAM) — 0 when absent.
    pci_fb_base: u64,
    /// Shadow of the linear-framebuffer BAR; `PciPaint` blits straight into it
    /// via `DISP_SEL_FB_LO`. Reported as `Smoke::pci_fb_img`.
    pci_fb_img: Vec<u8>,
    /// Scalar-FP register file (`f0`-`f31`), M3b exec-model FPU. Each slot holds
    /// the value's bit pattern; `f32` ops read/write the low 32 bits
    /// (NaN-boxing is not modelled — the guest JIT keeps FP values as raw bit
    /// patterns on the value stack and only parks them here mid-compute).
    fr: [u64; 32],
}

#[derive(Default)]
struct Uart16550 {
    ier: u8,
    rx: u8,
    rx_valid: bool,
}

enum Step {
    Cont,
    Halt(Halt),
}

#[allow(clippy::too_many_arguments)]
fn step(
    xlen: u32,
    x: &mut [u64; 32],
    pc: &mut u64,
    csr: &mut Csr,
    ram: &mut [u8],
    base: u64,
    w: u32,
    console: &mut String,
    uart_polls: &mut u32,
) -> Step {
    x[0] = 0;
    let npc = pc.wrapping_add(4);
    let op = w & 0x7f;
    let rd = (w >> 7) & 0x1f;
    let f3 = (w >> 12) & 0x7;
    let rs1 = (w >> 15) & 0x1f;
    let rs2 = (w >> 20) & 0x1f;
    let f7 = (w >> 25) & 0x7f;
    match op {
        0x37 => {
            // lui
            wr(xlen, x, rd, sext32(((w >> 12) as i32) << 12, xlen));
            *pc = npc;
        }
        0x17 => {
            // auipc
            let imm = sext32(((w >> 12) as i32) << 12, xlen);
            wr(xlen, x, rd, pc.wrapping_add(imm));
            *pc = npc;
        }
        0x13 => {
            let imm = iimm(w);
            let a = x[rs1 as usize];
            let v = match f3 {
                0 => a.wrapping_add(imm as u64),
                1 => a << (shamt(w, xlen)),
                // slti — signed immediate compare.
                2 => u64::from((a as i64) < (imm as i64)),
                // sltiu — the imm sign-extends, then unsigned compare (both
                // sides are sign-extended identically, so ordering holds).
                3 => u64::from(a < (imm as i64) as u64),
                5 if f7 & 0x20 == 0 => {
                    let unsigned = if xlen == 32 { u64::from(a as u32) } else { a };
                    unsigned >> shamt(w, xlen)
                }
                // srai — registers store the sign-extended value, so an i64
                // arithmetic shift is correct on both xlens.
                5 => ((a as i64) >> shamt(w, xlen)) as u64,
                7 => a & (imm as u64),
                _ => return Step::Halt(Halt::Unimp(w)),
            };
            wr(xlen, x, rd, v);
            *pc = npc;
        }
        0x1b => {
            // OP-IMM-32 (rv64 only): addiw / slliw / srliw / sraiw — the guest
            // JIT's wasm i32 lowering. Results sign-extend from bit 31.
            if xlen != 64 {
                return Step::Halt(Halt::Unimp(w));
            }
            let a = x[rs1 as usize] as u32;
            let sh = (w >> 20) & 0x1f;
            let v = match f3 {
                0 => (a as i32).wrapping_add(iimm(w)) as u32,
                1 => a << sh,
                5 if f7 & 0x20 == 0 => a >> sh,
                5 => ((a as i32) >> sh) as u32,
                _ => return Step::Halt(Halt::Unimp(w)),
            };
            wr(xlen, x, rd, sext32(v as i32, xlen));
            *pc = npc;
        }
        0x3b => {
            // OP-32 (rv64 only): addw/subw/mulw/sllw/srlw/sraw/div*/rem*.
            if xlen != 64 {
                return Step::Halt(Halt::Unimp(w));
            }
            let a = x[rs1 as usize] as u32;
            let b = x[rs2 as usize] as u32;
            let sh = b & 0x1f;
            let v = match (f3, f7) {
                (0, 0) => a.wrapping_add(b),
                (0, 0x20) => a.wrapping_sub(b),
                (0, 1) => a.wrapping_mul(b),
                (1, 0) => a << sh,
                (5, 0) => a >> sh,
                (5, 0x20) => ((a as i32) >> sh) as u32,
                (4, 1) => {
                    let (na, nb) = (a as i32, b as i32);
                    if nb == 0 {
                        u32::MAX
                    } else if na == i32::MIN && nb == -1 {
                        i32::MIN as u32
                    } else {
                        (na / nb) as u32
                    }
                }
                (5, 1) => {
                    if b == 0 {
                        u32::MAX
                    } else {
                        a / b
                    }
                }
                (6, 1) => {
                    let (na, nb) = (a as i32, b as i32);
                    if nb == 0 {
                        a
                    } else if na == i32::MIN && nb == -1 {
                        0
                    } else {
                        (na % nb) as u32
                    }
                }
                (7, 1) => {
                    if b == 0 {
                        a
                    } else {
                        a % b
                    }
                }
                _ => return Step::Halt(Halt::Unimp(w)),
            };
            wr(xlen, x, rd, sext32(v as i32, xlen));
            *pc = npc;
        }
        0x33 => {
            let a = x[rs1 as usize];
            let b = x[rs2 as usize];
            let v = match (f3, f7) {
                (0, 0) => a.wrapping_add(b),
                (0, 0x20) => a.wrapping_sub(b),
                (0, 1) => a.wrapping_mul(b),
                // divu — runtime `FbExpand` scale (`__disp.w / low_w`).
                // Registers hold sign-extended values on rv32, so mask to
                // u32 first; div-by-zero yields all-ones per the spec.
                (5, 1) => {
                    if xlen == 32 {
                        let (na, nb) = (a as u32, b as u32);
                        if nb == 0 {
                            u64::from(u32::MAX)
                        } else {
                            u64::from(na / nb)
                        }
                    } else if b == 0 {
                        u64::MAX
                    } else {
                        a / b
                    }
                }
                (4, 0) => a ^ b,
                // sltu — unsigned compare, used by `PciProbe`'s BAR window
                // check. On rv32 the registers are already zero-extended by
                // `wr`, so the u64 compare is the u32 compare.
                (3, 0) => u64::from(a < b),
                // slt — signed compare (both sides sign-extended identically).
                (2, 0) => u64::from((a as i64) < (b as i64)),
                (1, 0) => a << (b & if xlen == 32 { 0x1f } else { 0x3f }),
                (5, 0) => {
                    let sh = b & if xlen == 32 { 0x1f } else { 0x3f };
                    let unsigned = if xlen == 32 { u64::from(a as u32) } else { a };
                    unsigned >> sh
                }
                (5, 0x20) => ((a as i64) >> (b & if xlen == 32 { 0x1f } else { 0x3f })) as u64,
                (6, 0) => a | b,
                (7, 0) => a & b,
                // div — signed divide (M ext). Div-by-zero yields all-ones,
                // INT_MIN/-1 yields INT_MIN per the spec.
                (4, 1) => {
                    if xlen == 32 {
                        let (na, nb) = (a as i32, b as i32);
                        if nb == 0 {
                            u64::from(u32::MAX)
                        } else if na == i32::MIN && nb == -1 {
                            u64::from(i32::MIN as u32)
                        } else {
                            u64::from((na / nb) as u32)
                        }
                    } else {
                        let (na, nb) = (a as i64, b as i64);
                        if nb == 0 {
                            u64::MAX
                        } else if na == i64::MIN && nb == -1 {
                            i64::MIN as u64
                        } else {
                            (na / nb) as u64
                        }
                    }
                }
                // rem — signed remainder; divisor zero yields the dividend.
                (6, 1) => {
                    if xlen == 32 {
                        let (na, nb) = (a as i32, b as i32);
                        if nb == 0 {
                            u64::from(na as u32)
                        } else if na == i32::MIN && nb == -1 {
                            0
                        } else {
                            u64::from((na % nb) as u32)
                        }
                    } else {
                        let (na, nb) = (a as i64, b as i64);
                        if nb == 0 {
                            a
                        } else if na == i64::MIN && nb == -1 {
                            0
                        } else {
                            (na % nb) as u64
                        }
                    }
                }
                // remu — unsigned remainder; divisor zero yields the dividend.
                (7, 1) => {
                    if xlen == 32 {
                        let (na, nb) = (a as u32, b as u32);
                        if nb == 0 {
                            u64::from(na)
                        } else {
                            u64::from(na % nb)
                        }
                    } else if b == 0 {
                        a
                    } else {
                        a % b
                    }
                }
                _ => return Step::Halt(Halt::Unimp(w)),
            };
            wr(xlen, x, rd, v);
            *pc = npc;
        }
        0x53 => {
            // OP-FP — M3b exec-model FPU. `f7 & 1` is the fmt width (0=f32,
            // 1=f64) for the arith/cmp/move rows; conversion rows are
            // type-specific funct7s. FP operands are bit patterns in `csr.fr`;
            // int results land in `x[rd]`, FP results in `csr.fr[rd]`.
            let d = f7 & 1 == 1; // 1 → f64 row
            let fa = f32::from_bits(csr.fr[rs1 as usize] as u32);
            let fb = f32::from_bits(csr.fr[rs2 as usize] as u32);
            let da = f64::from_bits(csr.fr[rs1 as usize]);
            let db = f64::from_bits(csr.fr[rs2 as usize]);
            let mut fres: Option<u64> = None; // FP result → fr[rd]
            let mut xres: Option<u64> = None; // int result → x[rd]
                                              // Push a bit-pattern result honouring the row width.
            macro_rules! fpres {
                ($v32:expr, $v64:expr) => {
                    fres = Some(if d {
                        ($v64).to_bits()
                    } else {
                        ($v32).to_bits() as u64
                    })
                };
            }
            match (f7 & !1, f3) {
                (0x00, _) => fpres!(fa + fb, da + db),       // fadd
                (0x04, _) => fpres!(fa - fb, da - db),       // fsub
                (0x08, _) => fpres!(fa * fb, da * db),       // fmul
                (0x0c, _) => fpres!(fa / fb, da / db),       // fdiv
                (0x14, 0) => fpres!(fa.min(fb), da.min(db)), // fmin
                (0x14, 1) => fpres!(fa.max(fb), da.max(db)), // fmax
                (0x10, f3) => {
                    // fsgnj / fsgnjn / fsgnjx — sign injection on the fmt width.
                    let (mb, sb) = if d {
                        (63, 0x7fff_ffff_ffff_ffff)
                    } else {
                        (31, 0x7fff_ffff)
                    };
                    let (av, bv) = (csr.fr[rs1 as usize], csr.fr[rs2 as usize]);
                    let s = match f3 {
                        0 => bv,
                        1 => !bv,
                        _ => av ^ bv,
                    } & (1u64 << mb);
                    fres = Some((av & sb) | s);
                }
                (0x2c, 0) => fpres!(fa.sqrt(), da.sqrt()), // fsqrt
                // compares → int reg
                (0x50, 0) => xres = Some(u64::from(if d { da <= db } else { fa <= fb })),
                (0x50, 1) => xres = Some(u64::from(if d { da < db } else { fa < fb })),
                (0x50, 2) => xres = Some(u64::from(if d { da == db } else { fa == fb })),
                // fcvt int<-fp (rs2 selects dest width/signedness; f3 = rm)
                (0x60, _) => {
                    xres = Some(match rs2 {
                        0 => sext32(
                            if d {
                                fcvt_d_i32(da, f3)
                            } else {
                                fcvt_to_i32(fa, f3)
                            },
                            xlen,
                        ),
                        1 => sext32(
                            if d {
                                fcvt_d_u32(da, f3)
                            } else {
                                fcvt_to_u32(fa, f3)
                            } as i32,
                            xlen,
                        ),
                        2 => {
                            (if d {
                                fcvt_d_i64(da, f3)
                            } else {
                                fcvt_to_i64(fa, f3)
                            }) as u64
                        }
                        _ => {
                            if d {
                                fcvt_d_u64(da, f3)
                            } else {
                                fcvt_to_u64(fa, f3)
                            }
                        }
                    });
                }
                // fcvt fp<-int (rs2 selects src width/signedness)
                (0x68, _) => {
                    let sv = x[rs1 as usize];
                    if d {
                        let v = match rs2 {
                            0 => sv as u32 as i32 as f64,
                            1 => sv as u32 as f64,
                            2 => sv as i64 as f64,
                            _ => sv as f64,
                        };
                        fres = Some(v.to_bits());
                    } else {
                        let v = match rs2 {
                            0 => sv as u32 as i32 as f32,
                            1 => sv as u32 as f32,
                            2 => sv as i64 as f32,
                            _ => sv as f32,
                        };
                        fres = Some(v.to_bits() as u64);
                    }
                }
                (0x70, 0) => xres = Some(sext32(csr.fr[rs1 as usize] as u32 as i32, xlen)), // fmv.x.w
                (0x71, 0) => xres = Some(csr.fr[rs1 as usize]), // fmv.x.d
                (0x70, 1) => xres = Some(fclass_s(fa)),         // fclass.s
                (0x71, 1) => xres = Some(fclass_d(da)),         // fclass.d
                (0x78, 0) => fres = Some(x[rs1 as usize] & 0xffff_ffff), // fmv.w.x
                (0x79, 0) => fres = Some(x[rs1 as usize]),      // fmv.d.x
                _ => return Step::Halt(Halt::Unimp(w)),
            }
            // f32<->f64 widening sit on distinct funct7s (not the fmt bit).
            match f7 {
                0x20 if rs2 == 1 => fres = Some((da as f32).to_bits() as u64), // fcvt.s.d
                0x21 if rs2 == 0 => fres = Some((fa as f64).to_bits()),        // fcvt.d.s
                _ => {}
            }
            if let Some(v) = xres {
                wr(xlen, x, rd, v);
            }
            if let Some(v) = fres {
                csr.fr[rd as usize] = v;
            }
            *pc = npc;
        }
        0x03 => {
            let addr = eff_addr(xlen, x, rs1, iimm(w));
            if is_uart1(csr, addr) {
                *uart_polls += 1;
                wr(xlen, x, rd, uart_load(csr, addr));
                *pc = npc;
                return Step::Cont;
            }
            if is_uart0(addr) {
                wr(xlen, x, rd, uart_load(csr, addr));
                *pc = npc;
                return Step::Cont;
            }
            if is_plic(addr) {
                wr(xlen, x, rd, u64::from(plic_load(csr, addr)));
                *pc = npc;
                return Step::Cont;
            }
            if is_mbox(csr, addr) {
                wr(xlen, x, rd, u64::from(mbox_load(csr, addr, f3)));
                *pc = npc;
                return Step::Cont;
            }
            if is_vio_mmio(addr) {
                wr(xlen, x, rd, u64::from(vio_load(csr, addr)));
                *pc = npc;
                return Step::Cont;
            }
            if is_disp(csr, addr) {
                wr(xlen, x, rd, u64::from(disp_load(csr, addr)));
                *pc = npc;
                return Step::Cont;
            }
            if is_pci_ecam(csr, addr) {
                wr(xlen, x, rd, u64::from(pci_load(csr, addr)));
                *pc = npc;
                return Step::Cont;
            }
            *uart_polls = 0;
            let v = match f3 {
                // lb — sign-extended byte.
                0 => load_u8(ram, base, addr).map(|v| sext32(v as i8 as i32, xlen)),
                // lh — sign-extended halfword.
                1 => load_u16(ram, base, addr).map(|v| sext32(v as i16 as i32, xlen)),
                2 => load_u32(ram, base, addr).map(|v| sext32(v as i32, xlen)),
                3 => load_u64(ram, base, addr),
                4 => load_u8(ram, base, addr).map(u64::from),
                // lhu — zero-extended halfword.
                5 => load_u16(ram, base, addr).map(u64::from),
                // lwu — zero-extended word (rv64 only).
                6 if xlen == 64 => load_u32(ram, base, addr).map(u64::from),
                _ => return Step::Halt(Halt::Unimp(w)),
            };
            match v {
                Some(v) => wr(xlen, x, rd, v),
                None => {
                    if csr.stvec != 0 {
                        // Unmapped MMIO load → load access fault (5): the
                        // trap window marks probe reads device-absent.
                        take_mmio_fault(*pc, 5, addr, csr);
                        *pc = csr.stvec;
                        return Step::Cont;
                    }
                    return Step::Halt(Halt::Unimp(w));
                }
            }
            *pc = npc;
        }
        0x23 => {
            let addr = eff_addr(xlen, x, rs1, simm(w));
            let val = x[rs2 as usize];
            if is_uart0(addr) || is_uart1(csr, addr) {
                uart_store(csr, addr, val as u8);
                *pc = npc;
                return Step::Cont;
            }
            if is_plic(addr) {
                plic_store(csr, addr, val as u32);
                *pc = npc;
                return Step::Cont;
            }
            if is_mbox(csr, addr) {
                mbox_store(csr, addr, val as u32, f3);
                *pc = npc;
                return Step::Cont;
            }
            if is_vio_mmio(addr) {
                if f3 == 2 {
                    vio_store(csr, ram, base, addr, val as u32);
                }
                *pc = npc;
                return Step::Cont;
            }
            if is_disp(csr, addr) {
                disp_store(csr, addr, val as u32);
                *pc = npc;
                return Step::Cont;
            }
            if is_pci_fb(csr, addr) {
                if f3 == 2 {
                    pci_fb_store(csr, addr, val as u32);
                }
                *pc = npc;
                return Step::Cont;
            }
            let ok = match f3 {
                0 => store_u8(ram, base, addr, val as u8),
                1 => store_u16(ram, base, addr, val as u16),
                2 => store_u32(ram, base, addr, val as u32),
                3 => store_u64(ram, base, addr, val),
                _ => return Step::Halt(Halt::Unimp(w)),
            };
            if !ok {
                if csr.stvec != 0 {
                    take_mmio_fault(*pc, 7, addr, csr);
                    *pc = csr.stvec;
                    return Step::Cont;
                }
                return Step::Halt(Halt::Unimp(w));
            }
            if is_gr(csr, addr) {
                let off = addr.wrapping_sub(csr.gr_base);
                if off == 0 {
                    csr.gr_magic = val as u32;
                } else if off == GR_HEADER_BYTES {
                    csr.gr_pix0 = val as u32;
                } else if off == csr.gr_glyph_off {
                    csr.gr_glyph0 = val as u32;
                } else if off == csr.gr_dom_off {
                    csr.dom_pix0 = val as u32;
                }
            }
            if csr.ui_base != 0 {
                let off = addr.wrapping_sub(csr.ui_base);
                match off {
                    0 => csr.ui_magic = val as u32,
                    4 => csr.ui_size = val as u32,
                    8 => csr.ui_flags = val as u32,
                    12 => csr.ui_accel = val as u32,
                    24 => csr.ui_wasm_magic = val as u32,
                    28 => csr.ui_nfiles = val as u32,
                    _ => {}
                }
            }
            if csr.dom_base != 0 {
                let off = addr.wrapping_sub(csr.dom_base);
                if off == 0 {
                    csr.dom_rows = val as u32;
                }
            }
            *pc = npc;
        }
        0x63 => {
            let a = x[rs1 as usize] as i64;
            let b = x[rs2 as usize] as i64;
            let (au, bu) = (x[rs1 as usize], x[rs2 as usize]);
            let take = match f3 {
                0 => a == b,
                1 => a != b,
                4 => a < b,
                5 => a >= b,
                // Sign-extension to 64 bits preserves unsigned ordering, so
                // the u64 compare is the rv32 unsigned compare on rv32 too.
                6 => au < bu,
                7 => au >= bu,
                _ => return Step::Halt(Halt::Unimp(w)),
            };
            *pc = if take {
                pc.wrapping_add(bimm(w) as u64)
            } else {
                npc
            };
        }
        0x0f => {
            // fence — no ordering state to model.
            *pc = npc;
        }
        0x6f => {
            wr(xlen, x, rd, npc);
            *pc = pc.wrapping_add(jimm(w) as u64);
        }
        0x67 => {
            let t = npc;
            let target = eff_addr(xlen, x, rs1, iimm(w)) & !1;
            wr(xlen, x, rd, t);
            *pc = target;
        }
        0x73 => {
            if w == encode_ecall() {
                return sbi(xlen, x, pc, npc, csr, console);
            }
            if w == crate::encode::wfi() {
                if take_pending_sei(xlen, pc, csr) {
                    return Step::Cont;
                }
                // Timer tick budget: one boot tick (existing) plus, once the
                // input burst has been delivered, one more — the post-input
                // tick exercises trap_timer's dirty-check background repaint
                // (DomNav/await mutations flushed without a Ui command).
                let tick_budget = 1 + u32::from(csr.inp_poked);
                if timer_armed(csr) && csr.ticks < tick_budget && csr.stvec != 0 {
                    take_timer_trap(xlen, *pc, csr);
                    *pc = csr.stvec;
                    return Step::Cont;
                }
                // Inside a trap (SIE masked, SPIE latched) a `wfi` is a
                // bounded poll pause, not a halt: the caller's loop
                // re-checks the used ring, which the model completes
                // synchronously at notify. Returning Halt here would abort
                // the run mid-trap the moment a pending kick can't be
                // delivered (SIE is off, so SEI can never be taken).
                if (csr.sstatus & SSTATUS_SIE as u64) == 0 && (csr.sstatus & SSTATUS_SPIE) != 0 {
                    *pc = npc;
                    return Step::Cont;
                }
                *pc = npc;
                return Step::Halt(Halt::Wfi);
            }
            if w == crate::encode::sfence_vma() {
                *pc = npc;
                return Step::Cont;
            }
            if w == SRET {
                sret(csr, pc);
                return Step::Cont;
            }
            if (1..=3).contains(&f3) {
                let n = w >> 20;
                let old = csr_read(csr, n);
                let rs = x[rs1 as usize];
                if f3 == 1 {
                    csr_write(csr, n, rs);
                } else if rs1 != 0 {
                    csr_write(csr, n, if f3 == 2 { old | rs } else { old & !rs });
                }
                wr(xlen, x, rd, old);
                *pc = npc;
            } else {
                return Step::Halt(Halt::Unimp(w));
            }
        }
        _ => {
            if csr.stvec != 0 {
                csr.stval = u64::from(w);
                take_sync_trap(*pc, 2, csr);
                *pc = csr.stvec;
                return Step::Cont;
            }
            return Step::Halt(Halt::Unimp(w));
        }
    }
    Step::Cont
}

const SSTATUS_SPIE: u64 = 1 << 5;
const SSTATUS_SPP: u64 = 1 << 8;

fn sei_ready(csr: &Csr) -> bool {
    (csr.sstatus & SSTATUS_SIE as u64) != 0
        && (csr.sie & SIE_SEIE as u64) != 0
        && csr.plic_threshold == 0
        && (csr.plic_pending & csr.plic_enable) != 0
}

fn take_sei_trap(xlen: u32, pc: u64, csr: &mut Csr) {
    enter_s_trap(pc, (1u64 << (xlen.saturating_sub(1))) | 9, csr);
    csr.sei_claims = csr.sei_claims.saturating_add(1);
}

fn take_pending_sei(xlen: u32, pc: &mut u64, csr: &mut Csr) -> bool {
    // Bounded irq-storm guard: covers the canned SEQ (per-byte UART claims),
    // the input burst, virtqueue used-buffer irqs (2 per repaint) and a
    // headroom margin — 128 still fails a runaway storm closed.
    if csr.stvec == 0 || csr.sei_claims >= 128 || !sei_ready(csr) {
        return false;
    }
    take_sei_trap(xlen, *pc, csr);
    *pc = csr.stvec;
    true
}

fn hex_u64(s: &str) -> u64 {
    let t = s
        .trim()
        .trim_start_matches("0x")
        .trim_start_matches("0X")
        .replace('_', "");
    u64::from_str_radix(&t, 16).unwrap_or(0x1010_0000)
}

fn is_gr(csr: &Csr, addr: u64) -> bool {
    csr.gr_base != 0 && addr.wrapping_sub(csr.gr_base) < csr.gr_bytes.max(GR_HEADER_BYTES)
}

fn is_mbox(csr: &Csr, addr: u64) -> bool {
    csr.mbox_base != 0 && addr.wrapping_sub(csr.mbox_base) < 0x1000
}

fn mbox_load(csr: &Csr, addr: u64, f3: u32) -> u32 {
    let off = addr.wrapping_sub(csr.mbox_base);
    match off {
        MBOX_OFF_DOORBELL => csr.mbox_doorbell,
        MBOX_OFF_LENGTH => csr.mbox_len,
        MBOX_OFF_STATUS => csr.mbox_status,
        MBOX_OFF_IRQ_EN => csr.mbox_irq_en,
        o if (MBOX_OFF_CMD..MBOX_OFF_CMD + MBOX_CMD_BYTES).contains(&o) => {
            mbox_bytes_load(&csr.mbox_cmd, (o - MBOX_OFF_CMD) as usize, f3)
        }
        o if (MBOX_OFF_RSP..MBOX_OFF_RSP + MBOX_RSP_BYTES).contains(&o) => {
            mbox_bytes_load(&csr.mbox_rsp, (o - MBOX_OFF_RSP) as usize, f3)
        }
        _ => 0,
    }
}

/// Uncore display-engine window (`architecture/uncore/hdmi-display.md`):
/// `+0x00` MAGIC RO 'G6DS', `+0x04` REV RO 1, `+0x08..+0x24` RW
/// (CTRL/FB_LO/FB_HI/W/H/STRIDE/FORMAT/COMMIT), `+0x28` STATUS RO.
fn is_disp(csr: &Csr, addr: u64) -> bool {
    csr.disp_base != 0 && addr.wrapping_sub(csr.disp_base) < 0x40
}

fn disp_load(csr: &Csr, addr: u64) -> u32 {
    match addr.wrapping_sub(csr.disp_base) {
        0 => crate::vio::DISP_MAGIC,
        4 => 1,
        0x28 => csr.disp_status,
        o if o < 0x40 => csr.disp_regs[(o / 4) as usize],
        _ => 0,
    }
}

/// PCIe ECAM config window: `bus << 20 | dev << 15 | fn << 12 | off`. Only bus
/// 0 function 0 is modelled, which is what `PciProbe` walks. Reads are
/// **read-only** — the BIOS never writes config space, so there is no store
/// path here, and an absent slot returns all-ones exactly like real hardware.
fn is_pci_ecam(csr: &Csr, addr: u64) -> bool {
    csr.pci_ecam != 0 && addr.wrapping_sub(csr.pci_ecam) < (1 << 20)
}

/// Inside the modelled linear-framebuffer BAR (device memory, not guest RAM).
fn is_pci_fb(csr: &Csr, addr: u64) -> bool {
    csr.pci_fb_base != 0 && addr.wrapping_sub(csr.pci_fb_base) < csr.pci_fb_img.len() as u64
}

fn pci_fb_store(csr: &mut Csr, addr: u64, v: u32) {
    let off = addr.wrapping_sub(csr.pci_fb_base) as usize;
    if off + 4 <= csr.pci_fb_img.len() {
        csr.pci_fb_img[off..off + 4].copy_from_slice(&v.to_le_bytes());
    }
}

fn pci_load(csr: &Csr, addr: u64) -> u32 {
    let off = addr.wrapping_sub(csr.pci_ecam);
    let dev = off >> 15;
    let reg = (off & 0xfff) as i32;
    match csr.pci_dev {
        Some((d, id, class, bar0)) if d == dev => match reg {
            crate::vio::PCI_CFG_ID => id,
            crate::vio::PCI_CFG_CLASS => class,
            crate::vio::PCI_CFG_BAR0 => bar0,
            _ => 0,
        },
        // No device in this slot: all-ones is the architectural "absent" reply.
        _ => u32::MAX,
    }
}

fn disp_store(csr: &mut Csr, addr: u64, val: u32) {
    let off = addr.wrapping_sub(csr.disp_base);
    if off >= 0x40 {
        return;
    }
    csr.disp_regs[(off / 4) as usize] = val;
    if off == 0x24 && val != 0 {
        // COMMIT — latch the programmed surface and go live.
        csr.disp_committed = true;
        csr.disp_status = 1;
    }
}

fn mbox_store(csr: &mut Csr, addr: u64, val: u32, f3: u32) {
    let off = addr.wrapping_sub(csr.mbox_base);
    match off {
        MBOX_OFF_DOORBELL => {
            csr.mbox_doorbell = val;
            if val == MBOX_MAGIC {
                csr.mbox_magic = val;
            }
            if val == MBOX_KICK && csr.mbox_irq_en != 0 && csr.mbox_irq > 0 && csr.mbox_irq < 32 {
                csr.plic_pending |= 1u32 << csr.mbox_irq;
            }
        }
        MBOX_OFF_LENGTH => csr.mbox_len = val,
        MBOX_OFF_STATUS => csr.mbox_status = val,
        MBOX_OFF_IRQ_EN => {
            csr.mbox_irq_en = val;
            if val != 0 && csr.mbox_irq > 0 && csr.mbox_irq < 32 {
                csr.plic_pending |= 1u32 << csr.mbox_irq;
            }
        }
        o if (MBOX_OFF_CMD..MBOX_OFF_CMD + MBOX_CMD_BYTES).contains(&o) => {
            mbox_bytes_store(&mut csr.mbox_cmd, (o - MBOX_OFF_CMD) as usize, val, f3);
        }
        o if (MBOX_OFF_RSP..MBOX_OFF_RSP + MBOX_RSP_BYTES).contains(&o) => {
            mbox_bytes_store(&mut csr.mbox_rsp, (o - MBOX_OFF_RSP) as usize, val, f3);
        }
        _ => {}
    }
}

fn mbox_bytes_load(buf: &[u8], i: usize, f3: u32) -> u32 {
    if i >= buf.len() {
        return 0;
    }
    match f3 {
        2 => {
            let mut b = [0u8; 4];
            for (k, slot) in b.iter_mut().enumerate() {
                if i + k < buf.len() {
                    *slot = buf[i + k];
                }
            }
            u32::from_le_bytes(b)
        }
        _ => u32::from(buf[i]),
    }
}

fn mbox_bytes_store(buf: &mut [u8], i: usize, val: u32, f3: u32) {
    match f3 {
        0 if i < buf.len() => buf[i] = val as u8,
        2 => {
            let b = val.to_le_bytes();
            for (k, byte) in b.iter().enumerate() {
                if i + k < buf.len() {
                    buf[i + k] = *byte;
                }
            }
        }
        _ => {}
    }
}

fn host_mbox_kick(csr: &mut Csr, cmd: u8) -> bool {
    if csr.mbox_poked || csr.mbox_base == 0 || csr.mbox_magic != MBOX_MAGIC || csr.mbox_irq_en == 0
    {
        return false;
    }
    csr.mbox_poked = true;
    csr.mbox_cmd[0] = cmd;
    csr.mbox_len = 1;
    csr.mbox_doorbell = MBOX_KICK;
    if csr.mbox_irq > 0 && csr.mbox_irq < 32 {
        csr.plic_pending |= 1u32 << csr.mbox_irq;
    }
    true
}

fn is_plic(addr: u64) -> bool {
    (0x0c00_0000..0x0c40_0000).contains(&addr)
}

/// QEMU virt virtio-mmio transports (`VIO_MMIO_BASE + VIO_MMIO_STEP*i`, 8
/// slots, each only 0x200 wide — the stride gaps are unmapped). Only slot 0
/// is populated when the spec's `virtio-gpu-device` argv condition holds;
/// absent slots read 0 (magic mismatch → probe skips).
fn is_vio_mmio(addr: u64) -> bool {
    use crate::encode::{VIO_MMIO_BASE, VIO_MMIO_STEP};
    let off = addr.wrapping_sub(VIO_MMIO_BASE);
    off < VIO_MMIO_STEP * 8 && off % VIO_MMIO_STEP < 0x200
}

fn vio_load(csr: &Csr, addr: u64) -> u32 {
    use crate::encode::{
        VIO_DEV_GPU, VIO_DEV_INPUT, VIO_F_VERSION_1, VIO_MAGIC, VIO_MMIO_BASE, VIO_MMIO_STEP,
        VIO_NET_SLOT,
    };
    let off = addr - VIO_MMIO_BASE;
    let slot = off / VIO_MMIO_STEP;
    if slot == 1 && csr.vio_inp {
        return inp_load(csr, off % VIO_MMIO_STEP, VIO_DEV_INPUT);
    }
    // Slot 2 is left empty so PLIC source 3 stays the mailbox
    // (`loopback.irq`). Tablet is slot 3 (irq 4).
    if slot == 3 && csr.vio_inp {
        return tab_load(csr, off % VIO_MMIO_STEP, VIO_DEV_INPUT);
    }
    if slot == VIO_NET_SLOT && csr.vio_net {
        return net_load(off % VIO_MMIO_STEP);
    }
    if slot == crate::encode::VIO_BLK_SLOT && csr.vio_blk {
        return blk_load(csr, off % VIO_MMIO_STEP);
    }
    if slot != 0 || !csr.vio_gpu {
        return 0;
    }
    match off % VIO_MMIO_STEP {
        0x00 => VIO_MAGIC,
        0x04 => 2, // non-legacy (virtio 1.x) interface version
        0x08 => VIO_DEV_GPU,
        0x10 => {
            if csr.vio_feat_sel == 1 {
                VIO_F_VERSION_1
            } else if csr.vio_gl {
                // Low feature word: a `virtio-gpu-gl-device` offers VIRGL +
                // the context-init and blob bits a virgl guest negotiates.
                crate::encode::VIO_GPU_F_VIRGL
                    | crate::encode::VIO_GPU_F_RESOURCE_BLOB
                    | crate::encode::VIO_GPU_F_CONTEXT_INIT
            } else {
                0
            }
        }
        0x14 => csr.vio_feat_sel,
        0x24 => csr.vio_drv_sel,
        0x30 => csr.vio_qsel,
        0x34 => 1024, // QueueNumMax
        0x38 => csr.vio_qnum,
        0x44 => u32::from(csr.vio_ready),
        0x60 => csr.vio_isr,
        0x70 => csr.vio_status,
        _ => 0,
    }
}

/// virtio-mmio writes for the slot-0 model. A `STATUS == 0` write resets the
/// device; `QUEUE_NOTIFY` walks the avail ring and services descriptor chains.
fn vio_store(csr: &mut Csr, ram: &mut [u8], base: u64, addr: u64, v: u32) {
    use crate::encode::{VIO_MMIO_BASE, VIO_MMIO_STEP};
    let off = addr - VIO_MMIO_BASE;
    let slot = off / VIO_MMIO_STEP;
    if slot == 1 && csr.vio_inp {
        inp_store(csr, ram, base, off % VIO_MMIO_STEP, v);
        return;
    }
    if slot == 3 && csr.vio_inp {
        tab_store(csr, ram, base, off % VIO_MMIO_STEP, v);
        return;
    }
    if slot == crate::encode::VIO_BLK_SLOT && csr.vio_blk {
        blk_store(csr, ram, base, off % VIO_MMIO_STEP, v);
        return;
    }
    if slot != 0 || !csr.vio_gpu {
        return;
    }
    match off % VIO_MMIO_STEP {
        0x14 => csr.vio_feat_sel = v,
        0x20 => {
            // Driver feature acceptance: `DRV_FEATURES_SEL` picks the word.
            // Word 0 carries VIRTIO_GPU_F_VIRGL — gate the 3D lane on the
            // negotiated bit, not just device capability.
            if csr.vio_drv_sel == 0 {
                csr.vio_drv_feats = v;
            }
        }
        0x24 => csr.vio_drv_sel = v,
        0x30 => csr.vio_qsel = v,
        0x38 => csr.vio_qnum = v,
        0x44 => csr.vio_ready = v != 0,
        0x50 => vio_notify(csr, ram, base),
        0x64 => csr.vio_isr &= !v,
        0x70 => {
            csr.vio_status = v;
            if v == 0 {
                csr.vio_qnum = 0;
                csr.vio_ready = false;
                csr.vio_isr = 0;
                csr.vio_irqs = 0;
                csr.vio_used_idx = 0;
                csr.vio_last_cmd = 0;
                csr.vio_last_resp = 0;
            }
        }
        0x80 => csr.vio_qdesc = (csr.vio_qdesc & !0xffff_ffff) | u64::from(v),
        0x84 => csr.vio_qdesc = (csr.vio_qdesc & 0xffff_ffff) | (u64::from(v) << 32),
        0x90 => csr.vio_qavail = (csr.vio_qavail & !0xffff_ffff) | u64::from(v),
        0x94 => csr.vio_qavail = (csr.vio_qavail & 0xffff_ffff) | (u64::from(v) << 32),
        0xa0 => csr.vio_qused = (csr.vio_qused & !0xffff_ffff) | u64::from(v),
        0xa4 => csr.vio_qused = (csr.vio_qused & 0xffff_ffff) | (u64::from(v) << 32),
        _ => {}
    }
}

/// Service newly-published avail entries on the selected queue: walk each
/// descriptor chain, execute the ctrlq command, push used elems, set ISR.
fn vio_notify(csr: &mut Csr, ram: &mut [u8], base: u64) {
    if !csr.vio_ready || csr.vio_qsel != 0 || csr.vio_qdesc == 0 {
        return;
    }
    let avail = csr.vio_qavail;
    let used = csr.vio_qused;
    let idx = load_u32(ram, base, avail)
        .map(|w| (w >> 16) as u16)
        .unwrap_or(0);
    let mut pending = idx.wrapping_sub(csr.vio_used_idx).min(8);
    while pending > 0 {
        pending -= 1;
        let ri = csr.vio_used_idx % 8;
        // avail.ring[ri]: u16 slots packed two per word.
        let word = load_u32(ram, base, avail + 4 + u64::from(ri & !1) * 2).unwrap_or(0);
        let head = ((word >> ((ri & 1) * 16)) & 0xffff) as u16;
        let wrote = vio_exec_chain(csr, ram, base, head);
        let ui = csr.vio_used_idx % 8;
        store_u32(ram, base, used + 4 + u64::from(ui) * 8, u32::from(head));
        store_u32(ram, base, used + 8 + u64::from(ui) * 8, wrote);
        csr.vio_used_idx = csr.vio_used_idx.wrapping_add(1);
        store_u32(ram, base, used, u32::from(csr.vio_used_idx) << 16);
        csr.vio_isr |= 1;
        csr.vio_irqs += 1;
        // QEMU virt raises PLIC irq 1+slot for the used-buffer update; the
        // modelled device sits at slot 0 → irq 1 (claimed by trap_vio when
        // PlicInit enabled the 1..=8 range).
        csr.plic_pending |= 1 << 1;
    }
}

/// The medium the modelled virtio-blk device serves: a GPT-shaped disk.
///
/// LBA 0 is a protective MBR (`0x55AA` at 510, one `0xEE` entry) and LBA 1 carries
/// the `"EFI PART"` header signature — the layout every installer writes, and the
/// one the guest `BlkSig` has to recognize from the bytes rather than from a claim.
/// 64 sectors is enough for both and keeps the model cheap.
fn modelled_blk_image() -> Vec<u8> {
    let mut d = vec![0u8; 64 * 512];
    d[446 + 4] = 0xEE; // protective MBR entry type
    d[510] = 0x55;
    d[511] = 0xAA;
    d[512..520].copy_from_slice(b"EFI PART");
    d[512 + 12..512 + 16].copy_from_slice(&92u32.to_le_bytes());
    d
}

/// A minimal FAT32 superfloppy for the payload file-read test.
///
/// 64 sectors, 512 BPS, 1 SPC, 2 FATs of 1 sector each, root cluster 2, and a
/// single 8.3 file `HELLO.TXT` in the root whose first cluster holds text.
#[cfg(test)]
fn modelled_fat32_image() -> Vec<u8> {
    let mut d = vec![0u8; 64 * 512];
    let bps = 512u16;
    let spc = 1u8;
    let rsvd = 2u16;
    let num_fats = 2u8;
    let fatsz = 1u32;
    let total = 64u32;
    let root_clus = 2u32;
    // BPB at LBA 0.
    d[0..3].copy_from_slice(&[0xEB, 0x58, 0x90]);
    d[3..11].copy_from_slice(b"MSDOS5.0");
    d[0x0B..0x0D].copy_from_slice(&bps.to_le_bytes());
    d[0x0D] = spc;
    d[0x0E..0x10].copy_from_slice(&rsvd.to_le_bytes());
    d[0x10] = num_fats;
    d[0x11..0x13].fill(0); // root entry count
    d[0x13..0x15].fill(0); // total sectors 16
    d[0x15] = 0xF8; // media
    d[0x16..0x18].fill(0); // fat size 16
    d[0x18..0x1A].copy_from_slice(&32u16.to_le_bytes()); // sectors per track
    d[0x1A..0x1C].copy_from_slice(&64u16.to_le_bytes()); // heads
    d[0x1C..0x20].copy_from_slice(&0u32.to_le_bytes()); // hidden
    d[0x20..0x24].copy_from_slice(&total.to_le_bytes());
    d[0x24..0x28].copy_from_slice(&fatsz.to_le_bytes());
    d[0x28..0x2A].copy_from_slice(&0u16.to_le_bytes()); // ext flags
    d[0x2A..0x2C].copy_from_slice(&0u16.to_le_bytes()); // version
    d[0x2C..0x30].copy_from_slice(&root_clus.to_le_bytes());
    d[0x30..0x32].copy_from_slice(&1u16.to_le_bytes()); // fsinfo sector
    d[0x32..0x34].copy_from_slice(&6u16.to_le_bytes()); // backup boot sector
    d[0x40] = 0x80; // drive number
    d[0x41] = 0;
    d[0x42] = 0x29; // boot signature
    d[0x43..0x47].copy_from_slice(&0u32.to_le_bytes()); // volume id
    d[0x47..0x52].fill(0x20); // volume label spaces
    d[0x47..0x47 + 9].copy_from_slice(b"NO NAME  "[..9].as_ref());
    d[0x52..0x5A].copy_from_slice(b"FAT32   ");
    d[0x1FE] = 0x55;
    d[0x1FF] = 0xAA;
    // FAT1 at LBA 2 and FAT2 at LBA 3.
    for fat in [2usize, 3] {
        let off = fat * 512;
        d[off..off + 4].copy_from_slice(&0x0FFFFFF8u32.to_le_bytes()); // entry 0: media
        d[off + 4..off + 8].copy_from_slice(&0xFFFFFFFFu32.to_le_bytes()); // entry 1: reserved
        d[off + 8..off + 12].copy_from_slice(&0x0FFFFFF8u32.to_le_bytes()); // entry 2: root EOC
        d[off + 12..off + 16].copy_from_slice(&0x0FFFFFF8u32.to_le_bytes()); // entry 3: file EOC
    }
    // Root directory at LBA 4 (cluster 2).
    let root = 4 * 512;
    d[root..root + 11].copy_from_slice(b"HELLO   TXT");
    d[root + 11] = 0x20; // archive attribute
    d[root + 0x14..root + 0x16].copy_from_slice(&0u16.to_le_bytes()); // start cluster high
    d[root + 0x1A..root + 0x1C].copy_from_slice(&3u16.to_le_bytes()); // start cluster low
    d[root + 0x1C..root + 0x20].copy_from_slice(&15u32.to_le_bytes()); // file size
                                                                       // File content at LBA 5 (cluster 3).
    let data = 5 * 512;
    d[data..data + 15].copy_from_slice(b"hello from fat\n");
    d
}

/// A minimal ext4 superfloppy for the payload file-read test.
///
/// 64 sectors, 1024-byte blocks (2 sectors/block). The superblock is block 1
/// (LBA 2), the group-0 descriptor block 2 (LBA 4), the inode table block 3
/// (LBA 6), the root directory block 4 (LBA 8) holding `hello.txt` → inode 3,
/// and the file's data block 5 (LBA 10). Inodes are 128 bytes, direct-block
/// `i_block` only — the layout `Ext4Read` is contracted to understand.
#[cfg(test)]
fn modelled_ext4_image() -> Vec<u8> {
    let mut d = vec![0u8; 64 * 512];
    // Superblock at byte 1024 (LBA 2).
    let sb = 1024usize;
    d[sb..sb + 4].copy_from_slice(&128u32.to_le_bytes()); // s_inodes_count
    d[sb + 4..sb + 8].copy_from_slice(&32u32.to_le_bytes()); // s_blocks_count_lo
    d[sb + 20..sb + 24].copy_from_slice(&1u32.to_le_bytes()); // s_first_data_block
    d[sb + 24..sb + 28].copy_from_slice(&0u32.to_le_bytes()); // s_log_block_size = 1024
    d[sb + 32..sb + 36].copy_from_slice(&8192u32.to_le_bytes()); // s_blocks_per_group
    d[sb + 40..sb + 44].copy_from_slice(&128u32.to_le_bytes()); // s_inodes_per_group
    d[sb + 56..sb + 58].copy_from_slice(&0xEF53u16.to_le_bytes()); // s_magic
    d[sb + 58..sb + 60].copy_from_slice(&1u16.to_le_bytes()); // s_state clean
    d[sb + 88..sb + 90].copy_from_slice(&128u16.to_le_bytes()); // s_inode_size
    d[sb + 96..sb + 100].copy_from_slice(&2u32.to_le_bytes()); // s_feature_incompat = FILETYPE
                                                               // Group-0 descriptor at block 2 (LBA 4): bg_inode_table_lo = block 3.
    let gdt = 4 * 512;
    d[gdt + 8..gdt + 12].copy_from_slice(&3u32.to_le_bytes());
    // Inode table at block 3 (LBA 6). Inode 2 (root dir) at offset 128,
    // inode 3 (the file) at offset 256 — both inside the first sector.
    let itab = 6 * 512;
    let ino2 = itab + 128;
    d[ino2..ino2 + 2].copy_from_slice(&0x41EDu16.to_le_bytes()); // i_mode = dir | 0755
    d[ino2 + 4..ino2 + 8].copy_from_slice(&1024u32.to_le_bytes()); // i_size_lo
    d[ino2 + 32..ino2 + 36].copy_from_slice(&0u32.to_le_bytes()); // i_flags
    d[ino2 + 40..ino2 + 44].copy_from_slice(&4u32.to_le_bytes()); // i_block[0] = block 4
    let ino3 = itab + 256;
    d[ino3..ino3 + 2].copy_from_slice(&0x81A4u16.to_le_bytes()); // i_mode = reg | 0644
    d[ino3 + 4..ino3 + 8].copy_from_slice(&16u32.to_le_bytes()); // i_size_lo
    d[ino3 + 32..ino3 + 36].copy_from_slice(&0u32.to_le_bytes()); // i_flags
    d[ino3 + 40..ino3 + 44].copy_from_slice(&5u32.to_le_bytes()); // i_block[0] = block 5
                                                                  // Root directory block 4 (LBA 8): ".", "..", "hello.txt" → inode 3.
    let dir = 8 * 512;
    d[dir..dir + 4].copy_from_slice(&2u32.to_le_bytes()); // inode 2
    d[dir + 4..dir + 6].copy_from_slice(&12u16.to_le_bytes()); // rec_len
    d[dir + 6] = 1; // name_len
    d[dir + 7] = 2; // file_type dir
    d[dir + 8] = b'.';
    d[dir + 12..dir + 16].copy_from_slice(&2u32.to_le_bytes()); // inode 2
    d[dir + 16..dir + 18].copy_from_slice(&12u16.to_le_bytes());
    d[dir + 18] = 2;
    d[dir + 19] = 2;
    d[dir + 20..dir + 22].copy_from_slice(b"..");
    d[dir + 24..dir + 28].copy_from_slice(&3u32.to_le_bytes()); // inode 3
    d[dir + 28..dir + 30].copy_from_slice(&1000u16.to_le_bytes()); // rec_len to end
    d[dir + 30] = 9; // name_len
    d[dir + 31] = 1; // file_type reg
    d[dir + 32..dir + 41].copy_from_slice(b"hello.txt");
    // File data block 5 (LBA 10).
    let data = 10 * 512;
    d[data..data + 16].copy_from_slice(b"hello from ext4\n");
    d
}

/// virtio-blk register reads (DeviceID 2).
fn blk_load(csr: &Csr, reg: u64) -> u32 {
    use crate::encode::{VIO_DEV_BLK, VIO_F_VERSION_1, VIO_MAGIC};
    match reg {
        0x00 => VIO_MAGIC,
        0x04 => 2, // modern (virtio 1.x) transport
        0x08 => VIO_DEV_BLK,
        0x10 => {
            if csr.blk_feat_sel == 1 {
                VIO_F_VERSION_1
            } else {
                0
            }
        }
        0x14 => csr.blk_feat_sel,
        0x30 => csr.blk_qsel,
        0x34 => 1024, // QueueNumMax
        0x38 => csr.blk_qnum,
        0x44 => u32::from(csr.blk_ready),
        0x60 => csr.blk_isr,
        0x70 => csr.blk_status,
        _ => 0,
    }
}

/// virtio-blk register writes. A `QUEUE_NOTIFY` services the requestq.
fn blk_store(csr: &mut Csr, ram: &mut [u8], base: u64, reg: u64, v: u32) {
    match reg {
        0x14 => csr.blk_feat_sel = v,
        0x20 => {}
        0x24 => {}
        0x30 => csr.blk_qsel = v,
        0x38 => csr.blk_qnum = v,
        0x44 => csr.blk_ready = v != 0,
        0x50 => blk_notify(csr, ram, base),
        0x64 => csr.blk_isr &= !v,
        0x70 => {
            csr.blk_status = v;
            if v == 0 {
                csr.blk_qnum = 0;
                csr.blk_ready = false;
                csr.blk_isr = 0;
                csr.blk_used_idx = 0;
            }
        }
        0x80 => csr.blk_qdesc = (csr.blk_qdesc & !0xffff_ffff) | u64::from(v),
        0x84 => csr.blk_qdesc = (csr.blk_qdesc & 0xffff_ffff) | (u64::from(v) << 32),
        0x90 => csr.blk_qavail = (csr.blk_qavail & !0xffff_ffff) | u64::from(v),
        0x94 => csr.blk_qavail = (csr.blk_qavail & 0xffff_ffff) | (u64::from(v) << 32),
        0xa0 => csr.blk_qused = (csr.blk_qused & !0xffff_ffff) | u64::from(v),
        0xa4 => csr.blk_qused = (csr.blk_qused & 0xffff_ffff) | (u64::from(v) << 32),
        _ => {}
    }
}

/// Service the requestq: walk the three-descriptor chain, copy the requested
/// sector out of the backing image, write the status byte, publish the used elem.
///
/// It follows the descriptor chain rather than assuming the driver's layout — a
/// model that hard-codes offsets would pass even if the driver built a chain no
/// real device could follow.
fn blk_notify(csr: &mut Csr, ram: &mut [u8], base: u64) {
    if !csr.blk_ready || csr.blk_qsel != 0 || csr.blk_qdesc == 0 {
        return;
    }
    let avail = csr.blk_qavail;
    let idx = load_u32(ram, base, avail)
        .map(|w| (w >> 16) as u16)
        .unwrap_or(0);
    while csr.blk_used_idx != idx {
        let ri = csr.blk_used_idx % 8;
        let word = load_u32(ram, base, avail + 4 + u64::from(ri & !1) * 2).unwrap_or(0);
        let head = ((word >> ((ri & 1) * 16)) & 0xffff) as u16;
        // desc0: the 16-byte request header {type, reserved, sector}.
        let d0 = csr.blk_qdesc + u64::from(head) * 16;
        let hdr = load_u64(ram, base, d0).unwrap_or(0);
        let flags0 = load_u32(ram, base, d0 + 12).unwrap_or(0);
        let ty = load_u32(ram, base, hdr).unwrap_or(u32::MAX);
        let sector = load_u64(ram, base, hdr + 8).unwrap_or(0);
        let next1 = u64::from((flags0 >> 16) & 0xffff);
        // desc1: the data buffer the device fills.
        let d1 = csr.blk_qdesc + next1 * 16;
        let data = load_u64(ram, base, d1).unwrap_or(0);
        let dlen = load_u32(ram, base, d1 + 8).unwrap_or(0);
        let flags1 = load_u32(ram, base, d1 + 12).unwrap_or(0);
        let next2 = u64::from((flags1 >> 16) & 0xffff);
        // desc2: the one-byte status.
        let d2 = csr.blk_qdesc + next2 * 16;
        let stat = load_u64(ram, base, d2).unwrap_or(0);
        // Only reads are modelled; anything else is an honest IOERR (1), which is
        // also what the driver must notice instead of trusting the used ring.
        let mut status = 1u8;
        if ty == 0 {
            let start = (sector as usize) * 512;
            let want = dlen.min(512) as usize;
            if start + want <= csr.blk_image.len() {
                let bytes: Vec<u8> = csr.blk_image[start..start + want].to_vec();
                for (i, b) in bytes.iter().enumerate() {
                    store_u8(ram, base, data + i as u64, *b);
                }
                status = 0;
            }
        }
        store_u8(ram, base, stat, status);
        let used = csr.blk_qused;
        let ui = csr.blk_used_idx % 8;
        store_u32(ram, base, used + 4 + u64::from(ui) * 8, u32::from(head));
        store_u32(ram, base, used + 8 + u64::from(ui) * 8, dlen + 1);
        csr.blk_used_idx = csr.blk_used_idx.wrapping_add(1);
        store_u32(ram, base, used, u32::from(csr.blk_used_idx) << 16);
        csr.blk_isr |= 1;
        csr.blk_reqs += 1;
        // QEMU virt raises PLIC source 1+slot for a used-buffer update.
        csr.plic_pending |= 1 << (1 + crate::encode::VIO_BLK_SLOT);
    }
}

/// virtio-net identity (DeviceID 1). Probe-only: magic/version/id, no queues.
fn net_load(reg: u64) -> u32 {
    use crate::encode::{VIO_DEV_NET, VIO_F_VERSION_1, VIO_MAGIC};
    match reg {
        0x00 => VIO_MAGIC,
        0x04 => 2,
        0x08 => VIO_DEV_NET,
        0x10 => VIO_F_VERSION_1, // FEATURES_SEL=1 window is not modelled
        _ => 0,
    }
}

/// virtio-input register reads (transport regs only — DeviceID 18, no
/// device-cfg window modelled: `EV_KEY` events are device-initiated).
fn inp_load(csr: &Csr, reg: u64, dev_id: u32) -> u32 {
    use crate::encode::{VIO_F_VERSION_1, VIO_MAGIC};
    match reg {
        0x00 => VIO_MAGIC,
        0x04 => 2,
        0x08 => dev_id,
        0x10 => {
            if csr.inp_feat_sel == 1 {
                VIO_F_VERSION_1
            } else {
                0
            }
        }
        0x14 => csr.inp_feat_sel,
        0x24 => csr.inp_drv_sel,
        0x30 => csr.inp_qsel,
        0x34 => 8, // eventq QueueNumMax (driver posts 8 event buffers)
        0x38 => csr.inp_qnum,
        0x44 => u32::from(csr.inp_ready),
        0x60 => csr.inp_isr,
        0x70 => csr.inp_status,
        // virtio-input config window `size` field (offset 0x102): the keyboard
        // reports EV_KEY/EV_REP/EV_LED only — an `EV_BITS`/`EV_ABS` select
        // (0x0311) yields no bitmap, so size reads 0. The probe uses that to
        // tell the keyboard from the tablet.
        0x102 => 0,
        _ => 0,
    }
}

/// virtio-input register writes — `QUEUE_NOTIFY` on the eventq records the
/// newly-posted event buffers in `inp_bufs` (the device holds them until a
/// key event arrives, exactly like QEMU's virtio-input backend).
fn inp_store(csr: &mut Csr, ram: &mut [u8], base: u64, reg: u64, v: u32) {
    match reg {
        0x14 => csr.inp_feat_sel = v,
        0x24 => csr.inp_drv_sel = v,
        0x30 => csr.inp_qsel = v,
        0x38 => csr.inp_qnum = v,
        0x44 => csr.inp_ready = v != 0,
        // Config window select word (offset 0x100): byte0=select byte1=subsel.
        0x100 => csr.inp_cfgsel = v,
        0x50 => {
            if csr.inp_ready && csr.inp_qsel == 0 && csr.inp_qdesc != 0 {
                let avail = csr.inp_qavail;
                let idx = load_u32(ram, base, avail)
                    .map(|w| (w >> 16) as u16)
                    .unwrap_or(0);
                let mut n = idx.wrapping_sub(csr.inp_avail_seen).min(8);
                while n > 0 {
                    n -= 1;
                    let ri = csr.inp_avail_seen % 8;
                    let word = load_u32(ram, base, avail + 4 + u64::from(ri & !1) * 2).unwrap_or(0);
                    let head = ((word >> ((ri & 1) * 16)) & 0xffff) as u16;
                    csr.inp_bufs.push(head);
                    csr.inp_avail_seen = csr.inp_avail_seen.wrapping_add(1);
                }
            }
        }
        0x64 => csr.inp_isr &= !v,
        0x70 => {
            csr.inp_status = v;
            if v == 0 {
                csr.inp_qnum = 0;
                csr.inp_ready = false;
                csr.inp_isr = 0;
                csr.inp_used_idx = 0;
                csr.inp_avail_seen = 0;
                csr.inp_bufs.clear();
                csr.inp_poked = false;
            }
        }
        0x80 => csr.inp_qdesc = (csr.inp_qdesc & !0xffff_ffff) | u64::from(v),
        0x84 => csr.inp_qdesc = (csr.inp_qdesc & 0xffff_ffff) | (u64::from(v) << 32),
        0x90 => csr.inp_qavail = (csr.inp_qavail & !0xffff_ffff) | u64::from(v),
        0x94 => csr.inp_qavail = (csr.inp_qavail & 0xffff_ffff) | (u64::from(v) << 32),
        0xa0 => csr.inp_qused = (csr.inp_qused & !0xffff_ffff) | u64::from(v),
        0xa4 => csr.inp_qused = (csr.inp_qused & 0xffff_ffff) | (u64::from(v) << 32),
        _ => {}
    }
}

/// One `virtio_input_event` the host poke wrote into a posted buffer.
#[derive(Clone, Copy, Debug)]
struct InpEv {
    ty: u16,
    code: u16,
    value: u32,
}

fn feed_inp(feed: &mut dyn WebFeed, ev: InpEv) -> Option<GuestWebPresent> {
    use crate::encode::{VIO_INP_EV_ABS, VIO_INP_EV_KEY, VIO_INP_EV_REL};
    match u32::from(ev.ty) {
        VIO_INP_EV_KEY => feed.on_guest_key(ev.code, ev.value != 0),
        VIO_INP_EV_ABS => feed.on_guest_abs(ev.code, ev.value),
        VIO_INP_EV_REL => feed.on_guest_rel(ev.code, ev.value as i32),
        _ => None,
    }
}

/// Inject a canned `sendkey` burst into the posted eventq buffers — models
/// QEMU `sendkey a; sendkey down; sendkey ret` at idle (press events only;
/// QEMU also emits releases, which `InpDrain`/`DomNav` ignore by value).
/// Fills the desc buffers, publishes used elems and raises PLIC irq
/// 1+slot(=2) for the virtio-mmio slot.
///
/// SEQ is EV_KEY only (VGA `DomNav` tests). Pointer `EV_ABS`/`EV_REL` use
/// the same `InpEv` / [`WebFeed`] dispatcher when a later poke writes them;
/// do not append tablet events to this burst.
fn host_inp_kick(csr: &mut Csr, ram: &mut [u8], base: u64) -> Vec<InpEv> {
    if !csr.vio_inp || csr.inp_poked || !csr.inp_ready || csr.inp_qused == 0 {
        return Vec::new();
    }
    csr.inp_poked = true;
    // virtio_input_event {u16 type=EV_KEY, u16 code, u32 value}: 'a' (30),
    // KEY_DOWN (108), KEY_ENTER (28) — a non-nav letter, a nav arrow and an
    // activation in one burst.
    const SEQ: [(u16, u32); 3] = [(30, 1), (108, 1), (28, 1)];
    let used = csr.inp_qused;
    let mut out = Vec::new();
    for &(code, val) in &SEQ {
        let Some(head) = csr.inp_bufs.pop() else {
            break;
        };
        let daddr =
            load_u64(ram, base, csr.inp_qdesc.wrapping_add(u64::from(head) * 16)).unwrap_or(0);
        let _ = store_u32(ram, base, daddr, 1 | (u32::from(code) << 16));
        let _ = store_u32(ram, base, daddr + 4, val);
        let ui = csr.inp_used_idx % 8;
        let _ = store_u32(ram, base, used + 4 + u64::from(ui) * 8, u32::from(head));
        let _ = store_u32(ram, base, used + 8 + u64::from(ui) * 8, 8);
        csr.inp_used_idx = csr.inp_used_idx.wrapping_add(1);
        out.push(InpEv {
            ty: 1,
            code,
            value: val,
        });
    }
    if !out.is_empty() {
        let _ = store_u32(ram, base, used, u32::from(csr.inp_used_idx) << 16);
        csr.inp_isr |= 1;
        csr.plic_pending |= 1 << 2;
    }
    out
}

/// Push a batch of injected input events through [`WebFeed`] (when present) and
/// blit the last returned present into the modelled `__scan_fb`/`__ui_cap`.
/// Used by both the `Step::Halt` poke and the `AUTO_ON`-armed kick.
fn feed_events(
    feed: &mut Option<&mut dyn WebFeed>,
    ram: &mut [u8],
    entry: u64,
    scan_fb_base: u64,
    cap_base: u64,
    line_base: u64,
    evs: Vec<InpEv>,
) {
    if evs.is_empty() {
        return;
    }
    if let Some(feed) = feed.as_mut() {
        let mut last = None;
        for ev in evs {
            if let Some(p) = feed_inp(&mut **feed, ev) {
                last = Some(p);
            }
        }
        if let Some(p) = last {
            inject_web_present(ram, entry, scan_fb_base, cap_base, line_base, &p);
        }
    }
}

fn tab_load(csr: &Csr, reg: u64, dev_id: u32) -> u32 {
    use crate::encode::{VIO_F_VERSION_1, VIO_MAGIC};
    match reg {
        0x00 => VIO_MAGIC,
        0x04 => 2,
        0x08 => dev_id,
        0x10 => {
            if csr.tab_feat_sel == 1 {
                VIO_F_VERSION_1
            } else {
                0
            }
        }
        0x14 => csr.tab_feat_sel,
        0x24 => csr.tab_drv_sel,
        0x30 => csr.tab_qsel,
        0x34 => 8,
        0x38 => csr.tab_qnum,
        0x44 => u32::from(csr.tab_ready),
        0x60 => csr.tab_isr,
        0x70 => csr.tab_status,
        // virtio-input config window `size` field (offset 0x102): for an
        // `EV_BITS`/`EV_ABS` select (0x0311) the tablet reports its ABS bitmap
        // — a nonzero length is how the probe recognises it as the pointer.
        0x102 => {
            if csr.tab_cfgsel == 0x0311 {
                8
            } else {
                0
            }
        }
        _ => 0,
    }
}

fn tab_store(csr: &mut Csr, ram: &mut [u8], base: u64, reg: u64, v: u32) {
    match reg {
        0x14 => csr.tab_feat_sel = v,
        0x24 => csr.tab_drv_sel = v,
        0x30 => csr.tab_qsel = v,
        0x38 => csr.tab_qnum = v,
        0x44 => csr.tab_ready = v != 0,
        // Config window select word (offset 0x100): byte0=select byte1=subsel.
        0x100 => csr.tab_cfgsel = v,
        0x50 => {
            if csr.tab_ready && csr.tab_qsel == 0 && csr.tab_qdesc != 0 {
                let avail = csr.tab_qavail;
                let idx = load_u32(ram, base, avail)
                    .map(|w| (w >> 16) as u16)
                    .unwrap_or(0);
                let mut n = idx.wrapping_sub(csr.tab_avail_seen).min(8);
                while n > 0 {
                    n -= 1;
                    let ri = csr.tab_avail_seen % 8;
                    let word = load_u32(ram, base, avail + 4 + u64::from(ri & !1) * 2).unwrap_or(0);
                    let head = ((word >> ((ri & 1) * 16)) & 0xffff) as u16;
                    csr.tab_bufs.push(head);
                    csr.tab_avail_seen = csr.tab_avail_seen.wrapping_add(1);
                }
            }
        }
        0x64 => csr.tab_isr &= !v,
        0x70 => {
            csr.tab_status = v;
            if v == 0 {
                csr.tab_qnum = 0;
                csr.tab_ready = false;
                csr.tab_isr = 0;
                csr.tab_used_idx = 0;
                csr.tab_avail_seen = 0;
                csr.tab_bufs.clear();
                csr.tab_poked = false;
            }
        }
        0x80 => csr.tab_qdesc = (csr.tab_qdesc & !0xffff_ffff) | u64::from(v),
        0x84 => csr.tab_qdesc = (csr.tab_qdesc & 0xffff_ffff) | (u64::from(v) << 32),
        0x90 => csr.tab_qavail = (csr.tab_qavail & !0xffff_ffff) | u64::from(v),
        0x94 => csr.tab_qavail = (csr.tab_qavail & 0xffff_ffff) | (u64::from(v) << 32),
        0xa0 => csr.tab_qused = (csr.tab_qused & !0xffff_ffff) | u64::from(v),
        0xa4 => csr.tab_qused = (csr.tab_qused & 0xffff_ffff) | (u64::from(v) << 32),
        _ => {}
    }
}

/// Inject a canned virtio-tablet packet into the tablet eventq: `ABS_X`,
/// `ABS_Y`, then `BTN_LEFT` press (QEMU VNC click). Does not change the
/// keyboard KEY SEQ and does not touch `INP_KQ` (`TabDrain` re-posts).
/// `abs` is the feed hint (svelte-d tab hit in tablet units) or (0,0).
fn host_inp_tab_kick(
    csr: &mut Csr,
    ram: &mut [u8],
    base: u64,
    abs: Option<(u32, u32)>,
) -> Vec<InpEv> {
    use crate::encode::{VIO_INP_EV_ABS, VIO_INP_EV_KEY};
    use crate::vio::{VIO_ABS_X, VIO_ABS_Y, VIO_BTN_LEFT};
    if !csr.vio_inp || csr.tab_poked || !csr.tab_ready || csr.tab_qused == 0 {
        return Vec::new();
    }
    if csr.tab_bufs.is_empty() {
        return Vec::new();
    }
    csr.tab_poked = true;
    let (ax, ay) = abs.unwrap_or((0, 0));
    let seq = [
        InpEv {
            ty: VIO_INP_EV_ABS as u16,
            code: VIO_ABS_X as u16,
            value: ax,
        },
        InpEv {
            ty: VIO_INP_EV_ABS as u16,
            code: VIO_ABS_Y as u16,
            value: ay,
        },
        InpEv {
            ty: VIO_INP_EV_KEY as u16,
            code: VIO_BTN_LEFT as u16,
            value: 1,
        },
    ];
    let used = csr.tab_qused;
    let mut out = Vec::new();
    for ev in seq {
        let Some(head) = csr.tab_bufs.pop() else {
            break;
        };
        let daddr =
            load_u64(ram, base, csr.tab_qdesc.wrapping_add(u64::from(head) * 16)).unwrap_or(0);
        let _ = store_u32(
            ram,
            base,
            daddr,
            u32::from(ev.ty) | (u32::from(ev.code) << 16),
        );
        let _ = store_u32(ram, base, daddr + 4, ev.value);
        let ui = csr.tab_used_idx % 8;
        let _ = store_u32(ram, base, used + 4 + u64::from(ui) * 8, u32::from(head));
        let _ = store_u32(ram, base, used + 8 + u64::from(ui) * 8, 8);
        csr.tab_used_idx = csr.tab_used_idx.wrapping_add(1);
        out.push(ev);
    }
    if !out.is_empty() {
        let _ = store_u32(ram, base, used, u32::from(csr.tab_used_idx) << 16);
        csr.tab_isr |= 1;
        csr.plic_pending |= 1 << 4;
    }
    out
}

fn vio_packet(ram: &[u8], base: u64, outs: &[(u64, u32)]) -> Option<Vec<u8>> {
    let mut packet = Vec::new();
    for &(address, length) in outs {
        let start = usize::try_from(address.checked_sub(base)?).ok()?;
        let end = start.checked_add(length as usize)?;
        if packet.len().checked_add(length as usize)? > 64 * 1024 + 32 {
            return None;
        }
        packet.extend_from_slice(ram.get(start..end)?);
    }
    (packet.len() >= 24).then_some(packet)
}

/// Walk one descriptor chain (≤8): gather the OUT descriptors (the first
/// carries `ctrl_hdr.type`; a `SUBMIT_3D` execbuffer rides the *rest*), run
/// the command, write `resp_hdr.type` + any typed payload to the first WRITE
/// descriptor. Returns used-elem `len`.
fn vio_exec_chain(csr: &mut Csr, ram: &mut [u8], base: u64, head: u16) -> u32 {
    use crate::encode::{VIO_DESC_NEXT, VIO_DESC_WRITE, VIO_GPU_RESP_OK_DISPLAY_INFO};
    use crate::vio::VIO_RESP_DISPLAY_INFO;
    let mut d = u64::from(head);
    let mut outs: Vec<(u64, u32)> = Vec::new(); // (addr, len)
    let mut wins: Vec<(u64, u32)> = Vec::new();
    let mut seen = 0u8;
    let mut terminated = false;
    for _ in 0..8 {
        if d >= u64::from(csr.vio_qnum.min(8)) || seen & (1 << d) != 0 {
            return 0;
        }
        seen |= 1 << d;
        let Some(dbase) = csr.vio_qdesc.checked_add(d * 16) else {
            return 0;
        };
        let (Some(daddr), Some(dlen), Some(dfl)) = (
            load_u64(ram, base, dbase),
            dbase.checked_add(8).and_then(|a| load_u32(ram, base, a)),
            dbase.checked_add(12).and_then(|a| load_u32(ram, base, a)),
        ) else {
            return 0;
        };
        let Some(start) = daddr
            .checked_sub(base)
            .and_then(|a| usize::try_from(a).ok())
        else {
            return 0;
        };
        let Some(end) = start.checked_add(dlen as usize) else {
            return 0;
        };
        if ram.get(start..end).is_none() || dfl & 0xfffc != 0 {
            return 0;
        }
        if dfl & VIO_DESC_WRITE == 0 {
            if !wins.is_empty() {
                return 0;
            }
            outs.push((daddr, dlen));
        } else {
            wins.push((daddr, dlen));
        }
        if dfl & VIO_DESC_NEXT == 0 {
            terminated = true;
            break;
        }
        d = u64::from((dfl >> 16) & 0xffff);
    }
    if !terminated || wins.len() != 1 {
        return 0;
    }
    let Some(packet) = vio_packet(ram, base, &outs) else {
        return 0;
    };
    let (raddr, rlen) = wins[0];
    if rlen < 24 {
        return 0;
    }
    let ty = load_u32(&packet, 0, 0).unwrap();
    let needed = match ty {
        crate::encode::VIO_GPU_GET_DISPLAY_INFO => VIO_RESP_DISPLAY_INFO,
        crate::encode::VIO_GPU_GET_CAPSET_INFO => 40,
        crate::encode::VIO_GPU_GET_CAPSET => 24 + crate::virgl::CAPSET_WORDS.len() as u32 * 4,
        _ => 24,
    };
    csr.vio_last_cmd = ty;
    let resp = if rlen < needed {
        crate::encode::VIO_GPU_RESP_ERR_INVALID_PARAMETER
    } else {
        vio_cmd(csr, ram, base, &outs, ty)
    };
    csr.vio_last_resp = resp;
    let cap = if resp >= crate::encode::VIO_GPU_RESP_ERR_UNSPEC {
        24
    } else {
        needed
    };
    let mut response = vec![0u8; cap as usize];
    store_u32(&mut response, 0, 0, resp);
    if load_u32(&packet, 0, 4).unwrap() & 1 != 0 {
        store_u32(&mut response, 0, 4, 1);
        response[8..16].copy_from_slice(&packet[8..16]);
    }
    // Typed payload after the 24-byte resp_hdr.
    match resp {
        VIO_GPU_RESP_OK_DISPLAY_INFO => {
            // pmodes[0]: x, y, w, h, enabled, flags.
            for (i, v) in [0u32, 0, csr.vio_disp_w, csr.vio_disp_h, 1, 0]
                .iter()
                .enumerate()
            {
                store_u32(&mut response, 0, 24 + (i as u64) * 4, *v);
            }
        }
        crate::encode::VIO_GPU_RESP_OK_CAPSET_INFO => {
            // resp_capset_info: capset_id, max_version, max_size, padding.
            for (i, v) in [
                csr.virgl_capset_id,
                csr.virgl_capset_ver,
                csr.virgl_capset_size,
                0,
            ]
            .iter()
            .enumerate()
            {
                store_u32(&mut response, 0, 24 + (i as u64) * 4, *v);
            }
        }
        crate::encode::VIO_GPU_RESP_OK_CAPSET => {
            // resp_capset: a bounded virgl capset blob the guest may read.
            for (i, w) in crate::virgl::CAPSET_WORDS.iter().enumerate() {
                store_u32(&mut response, 0, 24 + (i as u64) * 4, *w);
            }
        }
        _ => {}
    }
    let start = (raddr - base) as usize;
    ram[start..start + response.len()].copy_from_slice(&response);
    cap
}

/// True once the virgl lane is live: the device is a `virtio-gpu-gl-device`
/// (`vio_gl`, set at probe) *and* the driver negotiated `VIRTIO_GPU_F_VIRGL`
/// (word-0 `DRV_FEATURES`). The 3D/capset commands are fail-closed before that.
fn virgl_live(csr: &Csr) -> bool {
    csr.vio_gl && csr.vio_drv_feats & crate::encode::VIO_GPU_F_VIRGL != 0
}

/// Execute one ctrlq command whose OUT descriptors are `outs` (the first is
/// the `virtio_gpu_*` request; a `SUBMIT_3D` execbuffer rides `outs[1]`).
/// Returns the `resp_hdr.type` the device would write (virtio spec 5.7.6/
/// 5.7.8–5.7.10). The 3D commands are serviced only when `virgl_live` — the
/// `proxy.gl` board offered `VIRTIO_GPU_F_VIRGL` and `VioInit` accepted it.
fn vio_cmd(csr: &mut Csr, ram: &mut [u8], base: u64, outs: &[(u64, u32)], ty: u32) -> u32 {
    use crate::encode::{
        VIO_GPU_CAPSET_VIRGL, VIO_GPU_CTX_ATTACH_RESOURCE, VIO_GPU_CTX_CREATE, VIO_GPU_GET_CAPSET,
        VIO_GPU_GET_CAPSET_INFO, VIO_GPU_GET_DISPLAY_INFO, VIO_GPU_RESOURCE_ATTACH_BACKING,
        VIO_GPU_RESOURCE_CREATE_2D, VIO_GPU_RESOURCE_CREATE_3D, VIO_GPU_RESOURCE_FLUSH,
        VIO_GPU_RESP_ERR_INVALID_CONTEXT_ID, VIO_GPU_RESP_ERR_INVALID_PARAMETER,
        VIO_GPU_RESP_ERR_INVALID_RESOURCE_ID, VIO_GPU_RESP_ERR_OUT_OF_MEMORY,
        VIO_GPU_RESP_ERR_UNSPEC, VIO_GPU_RESP_OK_CAPSET, VIO_GPU_RESP_OK_CAPSET_INFO,
        VIO_GPU_RESP_OK_DISPLAY_INFO, VIO_GPU_RESP_OK_NODATA, VIO_GPU_SET_SCANOUT,
        VIO_GPU_SUBMIT_3D, VIO_GPU_TRANSFER_FROM_HOST_3D, VIO_GPU_TRANSFER_TO_HOST_2D,
    };
    use crate::vio::VIO_FB_MAX;
    let Some(packet) = vio_packet(ram, base, outs) else {
        return VIO_GPU_RESP_ERR_INVALID_PARAMETER;
    };
    let needed = match ty {
        VIO_GPU_GET_CAPSET_INFO
        | VIO_GPU_GET_CAPSET
        | VIO_GPU_CTX_ATTACH_RESOURCE
        | VIO_GPU_SUBMIT_3D => 32,
        VIO_GPU_CTX_CREATE => 96,
        VIO_GPU_RESOURCE_CREATE_3D | VIO_GPU_TRANSFER_FROM_HOST_3D => 72,
        VIO_GPU_RESOURCE_CREATE_2D => 40,
        VIO_GPU_RESOURCE_ATTACH_BACKING | VIO_GPU_SET_SCANOUT | VIO_GPU_RESOURCE_FLUSH => 48,
        VIO_GPU_TRANSFER_TO_HOST_2D => 56,
        _ => 24,
    };
    if packet.len() < needed {
        return VIO_GPU_RESP_ERR_INVALID_PARAMETER;
    }
    let rd = |o: u64| load_u32(&packet, 0, o).unwrap_or(0);
    match ty {
        VIO_GPU_GET_DISPLAY_INFO => VIO_GPU_RESP_OK_DISPLAY_INFO,
        VIO_GPU_GET_CAPSET_INFO => {
            // resp_capset_info: the bounded model provides only index 0 → VIRGL v1.
            if !virgl_live(csr) {
                return VIO_GPU_RESP_ERR_UNSPEC;
            }
            csr.virgl_capset_id = if rd(24) == 0 { VIO_GPU_CAPSET_VIRGL } else { 0 };
            if csr.virgl_capset_id == 0 {
                csr.virgl_capset_ver = 0;
                csr.virgl_capset_size = 0;
            } else {
                csr.virgl_capset_ver = 1; // virgl v1 capset version
                csr.virgl_capset_size = crate::virgl::CAPSET_WORDS.len() as u32 * 4;
            }
            VIO_GPU_RESP_OK_CAPSET_INFO
        }
        VIO_GPU_GET_CAPSET => {
            if !virgl_live(csr) || rd(24) != VIO_GPU_CAPSET_VIRGL || rd(28) > 1 {
                return VIO_GPU_RESP_ERR_INVALID_PARAMETER;
            }
            VIO_GPU_RESP_OK_CAPSET
        }
        VIO_GPU_CTX_CREATE => {
            let ctx = rd(16); // ctrl_hdr.ctx_id
            if !virgl_live(csr) || ctx == 0 {
                return VIO_GPU_RESP_ERR_INVALID_CONTEXT_ID;
            }
            csr.virgl_ctx |= 1u64 << ctx.min(63);
            csr.virgl_ctxs += 1;
            VIO_GPU_RESP_OK_NODATA
        }
        VIO_GPU_CTX_ATTACH_RESOURCE => {
            let (res, ctx) = (rd(24), rd(16));
            if !virgl_live(csr) || csr.virgl_ctx & (1u64 << ctx.min(63)) == 0 {
                return VIO_GPU_RESP_ERR_INVALID_CONTEXT_ID;
            }
            // The resource must exist — the 2D scanout (`vio_res_id`, which
            // the composite samples) or a `RESOURCE_CREATE_3D` handle.
            if res == 0 || (res != csr.vio_res_id && csr.virgl_res & (1u64 << res.min(63)) == 0) {
                return VIO_GPU_RESP_ERR_INVALID_RESOURCE_ID;
            }
            csr.virgl_attached |= 1u64 << res.min(63);
            VIO_GPU_RESP_OK_NODATA
        }
        VIO_GPU_RESOURCE_CREATE_3D => {
            // resource_id@24, target@28, format@32, bind@36, w@40, h@44
            // (`virtio_gpu_resource_create_3d` — target precedes format).
            let (res, w, h) = (rd(24), rd(40), rd(44));
            if !virgl_live(csr) || res == 0 || w == 0 || h == 0 {
                return VIO_GPU_RESP_ERR_INVALID_PARAMETER;
            }
            if u64::from(w) * u64::from(h) * 4 > VIO_FB_MAX {
                return VIO_GPU_RESP_ERR_OUT_OF_MEMORY;
            }
            csr.virgl_res |= 1u64 << res.min(63);
            csr.virgl_dims.insert(res, (w, h));
            if rd(36) & crate::virgl::VIRGL_BIND_RENDER_TARGET != 0 {
                // The virgl render target gets its own device-side surface —
                // `virgl_fb` — deliberately separate from `vio_fb` (the 2D
                // scanout) so a `SUBMIT_3D` render never disturbs the
                // committed frame.
                csr.virgl_rt = res;
                csr.virgl_rt_w = w;
                csr.virgl_rt_h = h;
                csr.virgl_fb = vec![0; (w as usize) * (h as usize) * 4];
            } else {
                csr.virgl_surf
                    .insert(res, vec![0; (w as usize) * (h as usize) * 4]);
            }
            VIO_GPU_RESP_OK_NODATA
        }
        VIO_GPU_SUBMIT_3D => {
            let ctx = rd(16); // ctrl_hdr.ctx_id
            let size = rd(24); // cmd_submit.size = stream bytes
            if !virgl_live(csr) || ctx == 0 || csr.virgl_ctx & (1u64 << ctx.min(63)) == 0 {
                return VIO_GPU_RESP_ERR_INVALID_CONTEXT_ID;
            }
            // The execbuffer is the OUT descriptors after the 32-byte
            // cmd_submit header, gathered without depending on segment boundaries.
            if size % 4 != 0 || size as usize != packet.len() - 32 {
                return VIO_GPU_RESP_ERR_INVALID_PARAMETER;
            }
            let ok = virgl_exec(csr, &packet, 0, 32, u64::from(size));
            if ok {
                csr.virgl_submits += 1;
                VIO_GPU_RESP_OK_NODATA
            } else {
                VIO_GPU_RESP_ERR_INVALID_PARAMETER
            }
        }
        VIO_GPU_TRANSFER_FROM_HOST_3D => {
            // host resource → guest backing. `virtio_gpu_transfer_from_host_3d`
            // = hdr(24) + box{x,y,z,w,h,d}@24..47 + offset@48 + res@56 (the
            // modelled layout — real QEMU carries the resource handle in the
            // ctrl stream; field fidelity is part of the gated real-GPU work).
            let (x, y, rw, rh) = (rd(24), rd(28), rd(36), rd(40));
            let off = load_u64(&packet, 0, 48).unwrap_or(0);
            let res = rd(56);
            if res != csr.virgl_rt || csr.virgl_fb.is_empty() {
                return VIO_GPU_RESP_ERR_INVALID_RESOURCE_ID;
            }
            let Some(&backing) = csr.virgl_backing.get(&res) else {
                return VIO_GPU_RESP_ERR_INVALID_RESOURCE_ID;
            };
            let stride = u64::from(csr.virgl_rt_w) * 4;
            let rows = rh.min(csr.virgl_rt_h.saturating_sub(y));
            for row in 0..rows {
                let pix = u64::from(y + row) * stride + u64::from(x) * 4;
                let len = u64::from(rw.min(csr.virgl_rt_w.saturating_sub(x))) * 4;
                let di = backing
                    .wrapping_add(off)
                    .wrapping_add(pix)
                    .wrapping_sub(base);
                let si = pix as usize;
                if si + len as usize <= csr.virgl_fb.len() {
                    if let Some(dst) = ram.get_mut(di as usize..(di + len) as usize) {
                        dst.copy_from_slice(&csr.virgl_fb[si..si + len as usize]);
                    }
                }
            }
            VIO_GPU_RESP_OK_NODATA
        }
        VIO_GPU_RESOURCE_CREATE_2D => {
            let (res, w, h) = (rd(24), rd(32), rd(36));
            if res == 0 || w == 0 || h == 0 || u64::from(w) * u64::from(h) * 4 > VIO_FB_MAX {
                VIO_GPU_RESP_ERR_UNSPEC
            } else {
                csr.vio_res_id = res;
                csr.vio_res_w = w;
                csr.vio_res_h = h;
                csr.vio_fb = vec![0; (w as usize) * (h as usize) * 4];
                csr.vio_backing = 0;
                csr.vio_scanout = false;
                csr.vio_flushes = 0;
                VIO_GPU_RESP_OK_NODATA
            }
        }
        VIO_GPU_RESOURCE_ATTACH_BACKING => {
            let (res, nr) = (rd(24), rd(28));
            let addr = load_u64(&packet, 0, 32).unwrap_or(0);
            let len = rd(40);
            if nr == 0 || addr == 0 {
                VIO_GPU_RESP_ERR_UNSPEC
            } else if res == csr.vio_res_id {
                csr.vio_backing = addr;
                csr.vio_backing_len = u64::from(len);
                VIO_GPU_RESP_OK_NODATA
            } else if csr.virgl_res & (1u64 << res.min(63)) != 0 {
                // A 3D (virgl) resource's guest backing — e.g. the readback
                // target `__virgl_out` for TRANSFER_FROM_HOST_3D.
                csr.virgl_backing.insert(res, addr);
                VIO_GPU_RESP_OK_NODATA
            } else {
                VIO_GPU_RESP_ERR_INVALID_RESOURCE_ID
            }
        }
        VIO_GPU_SET_SCANOUT => {
            let (scanout, res) = (rd(40), rd(44));
            if scanout != 0 {
                VIO_GPU_RESP_ERR_UNSPEC
            } else if res == csr.vio_res_id && !csr.vio_fb.is_empty() {
                csr.vio_scanout = true;
                csr.virgl_scanout = false;
                VIO_GPU_RESP_OK_NODATA
            } else if res == csr.virgl_rt && !csr.virgl_fb.is_empty() {
                // The virgl present — the console moves onto the
                // GPU-rastered `RES_RT` (the composite output).
                csr.virgl_scanout = true;
                csr.vio_scanout = false;
                VIO_GPU_RESP_OK_NODATA
            } else {
                VIO_GPU_RESP_ERR_UNSPEC
            }
        }
        VIO_GPU_TRANSFER_TO_HOST_2D => {
            let (x, y, rw, rh) = (rd(24), rd(28), rd(32), rd(36));
            let off = load_u64(&packet, 0, 40).unwrap_or(0);
            let res = rd(48);
            if res != csr.vio_res_id || csr.vio_backing == 0 || csr.vio_fb.is_empty() {
                return VIO_GPU_RESP_ERR_UNSPEC;
            }
            let stride = u64::from(csr.vio_res_w) * 4;
            let rows = rh.min(csr.vio_res_h.saturating_sub(y));
            for row in 0..rows {
                let pix = u64::from(y + row) * stride + u64::from(x) * 4;
                let len = u64::from(rw.min(csr.vio_res_w.saturating_sub(x))) * 4;
                let so = csr
                    .vio_backing
                    .wrapping_add(off)
                    .wrapping_add(pix)
                    .wrapping_sub(base) as usize;
                let di = pix as usize;
                if let Some(src) = ram.get(so..so + len as usize) {
                    if di + len as usize <= csr.vio_fb.len() {
                        csr.vio_fb[di..di + len as usize].copy_from_slice(src);
                    }
                }
            }
            VIO_GPU_RESP_OK_NODATA
        }
        VIO_GPU_RESOURCE_FLUSH => {
            let res = rd(40);
            if res == csr.vio_res_id && !csr.vio_fb.is_empty() {
                csr.vio_flushes = csr.vio_flushes.wrapping_add(1);
                VIO_GPU_RESP_OK_NODATA
            } else if res == csr.virgl_rt && !csr.virgl_fb.is_empty() {
                csr.virgl_flushes = csr.virgl_flushes.wrapping_add(1);
                VIO_GPU_RESP_OK_NODATA
            } else {
                VIO_GPU_RESP_ERR_UNSPEC
            }
        }
        _ => VIO_GPU_RESP_ERR_UNSPEC,
    }
}

/// Parse a `SUBMIT_3D` execbuffer: walk the `VIRGL_CMD0` headers, validate the
/// framing (`len` = body dwords, stream consumed exactly), track object
/// handles and inline-write payloads, and on a `CLEAR`+`DRAW_VBO` model the
/// textured-quad raster into `vio_fb`. Returns false on a malformed stream
/// (bad header / overrun) — the device answers `ERR_INVALID_PARAMETER`.
fn virgl_exec(csr: &mut Csr, ram: &[u8], base: u64, buf: u64, size: u64) -> bool {
    use crate::encode::{
        VIRGL_CCMD_CLEAR, VIRGL_CCMD_CREATE_OBJECT, VIRGL_CCMD_DRAW_VBO, VIRGL_CCMD_NOP,
        VIRGL_CCMD_RESOURCE_INLINE_WRITE, VIRGL_CCMD_SET_FRAMEBUFFER_STATE, VIRGL_OBJ_SAMPLER_VIEW,
    };
    let ndw = (size / 4) as usize;
    if ndw == 0 || ndw > 16384 {
        return false;
    }
    let mut s = Vec::with_capacity(ndw);
    for i in 0..ndw {
        let Some(w) = load_u32(ram, base, buf + (i as u64) * 4) else {
            return false;
        };
        s.push(w);
    }
    let mut i = 0usize;
    let mut ncmd = 0u32;
    let mut saw_clear = false;
    let mut clear_rgba = [0u32; 4];
    let mut drew = false;
    let mut fb_bound = false;
    let mut objects = 0u64; // created-object handle bitmap (≤64)
                            // The resource the `SAMPLER_VIEW` object samples — for the composite
                            // this is `RES_SCAN` (the 2D scanout, i.e. `vio_fb` itself).
    let mut tex_res: Option<u32> = None;
    while i < s.len() {
        let hdr = s[i];
        let cmd = hdr & 0xff;
        let len = ((hdr >> 16) & 0xffff) as usize; // body dwords
        if cmd != VIRGL_CCMD_NOP && len == 0 {
            return false;
        }
        if i + 1 + len > s.len() {
            return false;
        }
        let body = &s[i + 1..i + 1 + len];
        match cmd {
            VIRGL_CCMD_CREATE_OBJECT => {
                if !body.is_empty() && body[0] < 64 {
                    objects |= 1u64 << body[0];
                }
                // `CREATE_OBJECT` carries the object type in the header's
                // `obj` field; a sampler view's body[1] is the res handle
                // (`VIRGL_OBJ_SAMPLER_VIEW_RES_HANDLE`).
                if ((hdr >> 8) & 0xff) == VIRGL_OBJ_SAMPLER_VIEW && body.len() >= 2 {
                    tex_res = Some(body[1]);
                }
            }
            VIRGL_CCMD_SET_FRAMEBUFFER_STATE => {
                // body[0]=nr_cbufs; a nonzero colour count means a surface is bound.
                fb_bound = body.first().copied().unwrap_or(0) >= 1;
            }
            VIRGL_CCMD_CLEAR => {
                saw_clear = true;
                for (k, px) in clear_rgba.iter_mut().enumerate() {
                    *px = body.get(1 + k).copied().unwrap_or(0);
                }
            }
            VIRGL_CCMD_RESOURCE_INLINE_WRITE => {
                // res@0, level@1, usage@2, stride@3, layer_stride@4,
                // box{x,y,z,w,h,d}@5..10, data@11+ — the wire layout is
                // `VIRGL_RESOURCE_IW_*` (res,level,usage,stride,layer_stride,
                // x,y,z,w,h,d then payload). An upload onto a modelled 3D
                // surface fills it (the VBO bytes; texture data reaches the
                // scanout resource through TRANSFER_TO_HOST_2D instead).
                if body.len() >= 11 {
                    let res = body[0];
                    if let Some(surf) = csr.virgl_surf.get_mut(&res) {
                        let data = &body[11..];
                        for (k, w) in data.iter().enumerate() {
                            let off = k * 4;
                            if off + 4 <= surf.len() {
                                surf[off..off + 4].copy_from_slice(&w.to_le_bytes());
                            }
                        }
                    }
                }
            }
            VIRGL_CCMD_DRAW_VBO => drew = true,
            _ => {}
        }
        ncmd = ncmd.wrapping_add(1);
        i += 1 + len;
    }
    csr.virgl_cmds = csr.virgl_cmds.wrapping_add(ncmd);
    if saw_clear {
        csr.virgl_clears = csr.virgl_clears.wrapping_add(1);
    }
    // The texture the draw samples is the `SAMPLER_VIEW` object's resource:
    // the 2D scanout surface (`vio_fb` — the committed `__scan_fb` frame),
    // the virgl render target, or another created 3D surface.
    let tex: Option<(u32, u32, Vec<u32>)> = tex_res.and_then(|res| {
        let (tw, th, bytes) = if res == csr.vio_res_id {
            (csr.vio_res_w, csr.vio_res_h, csr.vio_fb.as_slice())
        } else if res == csr.virgl_rt {
            (csr.virgl_rt_w, csr.virgl_rt_h, csr.virgl_fb.as_slice())
        } else {
            let (w, h) = csr.virgl_dims.get(&res).copied().unwrap_or((0, 0));
            (
                w,
                h,
                csr.virgl_surf.get(&res).map_or(&[][..], |v| v.as_slice()),
            )
        };
        if tw == 0 || th == 0 {
            return None;
        }
        // Record the sampled source — the composite's input snapshot.
        csr.virgl_src = bytes.to_vec();
        let px: Vec<u32> = bytes
            .chunks_exact(4)
            .map(|c| u32::from_le_bytes([c[0], c[1], c[2], c[3]]))
            .collect();
        Some((tw, th, px))
    });
    // A draw only reaches the surface when a framebuffer was bound and the
    // surface object (handle `OBJ_SURFACE`) was created in this stream.
    let surface = objects & (1u64 << crate::virgl::OBJ_SURFACE) != 0;
    if drew && fb_bound && surface {
        csr.virgl_draws = csr.virgl_draws.wrapping_add(1);
        virgl_raster_quad(csr, saw_clear.then_some(clear_rgba), tex.as_ref());
    }
    i == s.len()
}

/// Model a textured quad: sample the `SAMPLER_VIEW`-bound resource across
/// the offscreen render-target surface (`virgl_fb`), falling back to the
/// CLEAR colour when no sampler view was created. For the composite the
/// bound resource is `RES_SCAN` — `vio_fb` itself — so the raster is a
/// 1:1 resample of the committed frame, matching what vrend produces on a
/// y0top render target (verified byte-exact in `out/virgl/vhw`).
fn virgl_raster_quad(csr: &mut Csr, clear: Option<[u32; 4]>, tex: Option<&(u32, u32, Vec<u32>)>) {
    let (w, h) = (csr.virgl_rt_w as usize, csr.virgl_rt_h as usize);
    if w == 0 || h == 0 || csr.virgl_fb.len() < w * h * 4 {
        return;
    }
    let clear_px = clear.map(|c| {
        // rgba are f32 bits; convert to X8R8G8B8 little-endian word.
        let f = |b: u32| (f32::from_bits(b).clamp(0.0, 1.0) * 255.0) as u32;
        f(c[0]) | (f(c[1]) << 8) | (f(c[2]) << 16) | (f(c[3]) << 24)
    });
    let mut px = 0u32;
    for y in 0..h {
        for x in 0..w {
            let word = if let Some((tw, th, data)) = tex {
                // nearest-sample the texture across the fullscreen quad.
                let u = (x * (*tw as usize)) / w.max(1);
                let v = (y * (*th as usize)) / h.max(1);
                data.get(v * (*tw as usize) + u).copied().unwrap_or(0)
            } else {
                clear_px.unwrap_or(0)
            };
            let off = (y * w + x) * 4;
            if off + 4 <= csr.virgl_fb.len() {
                csr.virgl_fb[off..off + 4].copy_from_slice(&word.to_le_bytes());
                px += 1;
            }
        }
    }
    csr.virgl_px = csr.virgl_px.wrapping_add(px);
}

/// True when `addr` is an S-mode PLIC context register: `base` is the
/// hart-0 S address and `stride` is the per-*hart* spacing (S contexts are
/// the odd contexts: ctx = 2*h + 1). Single-context model — whichever hart
/// programs it owns the same state.
fn plic_s_ctx(addr: u64, base: u64, stride: u64) -> bool {
    addr >= base && (addr - base) % stride == 0 && (addr - base) / stride < 32
}

fn plic_load(csr: &mut Csr, addr: u64) -> u32 {
    if plic_s_ctx(addr, PLIC_CLAIM_S0, 0x2000) {
        let bits = csr.plic_pending & csr.plic_enable;
        if bits == 0 {
            return 0;
        }
        let irq = bits.trailing_zeros();
        csr.plic_pending &= !1u32.wrapping_shl(irq);
        csr.plic_claim = irq;
        irq
    } else if plic_s_ctx(addr, PLIC_ENABLE_S0, 0x100) {
        csr.plic_enable
    } else if plic_s_ctx(addr, PLIC_THRESH_S0, 0x2000) {
        csr.plic_threshold
    } else {
        0
    }
}

fn plic_store(csr: &mut Csr, addr: u64, val: u32) {
    if plic_s_ctx(addr, PLIC_ENABLE_S0, 0x100) {
        csr.plic_enable = val;
        if !csr.plic_injected {
            // One UART RX injection so the trap_uart path is exercised; irq
            // 10 is QEMU virt UART0 (1..=8 are the virtio-mmio slots).
            csr.plic_pending |= 1 << UART_IRQ;
            csr.plic_injected = true;
        }
    } else if plic_s_ctx(addr, PLIC_THRESH_S0, 0x2000) {
        csr.plic_threshold = val;
    } else if plic_s_ctx(addr, PLIC_CLAIM_S0, 0x2000) && val == csr.plic_claim {
        csr.plic_claim = 0;
    }
}

fn timer_armed(csr: &Csr) -> bool {
    (csr.sstatus & SSTATUS_SIE as u64) != 0 && (csr.sie & SIE_STIE as u64) != 0
}

fn enter_s_trap(pc: u64, scause: u64, csr: &mut Csr) {
    csr.sepc = pc;
    csr.scause = scause;
    let sie = (csr.sstatus >> 1) & 1;
    csr.sstatus &= !SSTATUS_SIE as u64;
    csr.sstatus = (csr.sstatus & !SSTATUS_SPIE) | (sie << 5);
    csr.sstatus |= SSTATUS_SPP;
}

fn take_timer_trap(xlen: u32, pc: u64, csr: &mut Csr) {
    enter_s_trap(pc, (1u64 << (xlen.saturating_sub(1))) | 5, csr);
    if csr.time < csr.timecmp {
        csr.time = csr.timecmp;
    }
    csr.ticks = csr.ticks.saturating_add(1);
}

fn take_sync_trap(pc: u64, code: u64, csr: &mut Csr) {
    enter_s_trap(pc, code, csr);
    csr.faults = csr.faults.saturating_add(1);
}

/// Synchronous MMIO access fault — `stval` carries the faulting address so
/// the guest probe window (`trap_fault`) can classify it as device-absent.
fn take_mmio_fault(pc: u64, code: u64, addr: u64, csr: &mut Csr) {
    csr.stval = addr;
    take_sync_trap(pc, code, csr);
}

fn sret(csr: &mut Csr, pc: &mut u64) {
    let spie = (csr.sstatus >> 5) & 1;
    csr.sstatus = (csr.sstatus & !SSTATUS_SIE as u64) | (spie << 1);
    csr.sstatus |= SSTATUS_SPIE;
    *pc = csr.sepc;
}

fn sbi(
    xlen: u32,
    x: &mut [u64; 32],
    pc: &mut u64,
    npc: u64,
    csr: &mut Csr,
    console: &mut String,
) -> Step {
    let eid = x[17] as i64; // a7
    if eid == SBI_PUTCHAR {
        let ch = (x[10] as u8) as char;
        if ch == '\0' {
            wr(xlen, x, 10, 0);
        } else {
            console.push(ch);
            wr(xlen, x, 10, 0);
        }
        *pc = npc;
        Step::Cont
    } else if eid == SBI_TIME_EID {
        csr.timecmp = x[10];
        csr.time_ecalls = csr.time_ecalls.saturating_add(1);
        wr(xlen, x, 10, 0);
        wr(xlen, x, 11, 0);
        *pc = npc;
        Step::Cont
    } else if eid == SBI_SRST_EID {
        *pc = npc;
        Step::Halt(Halt::Srst)
    } else if eid == SBI_HSM_EID {
        csr.hsm_starts = csr.hsm_starts.saturating_add(1);
        wr(xlen, x, 10, 0);
        *pc = npc;
        Step::Cont
    } else if eid == SBI_IPI_EID {
        csr.ipi_sends = csr.ipi_sends.saturating_add(1);
        wr(xlen, x, 10, 0);
        *pc = npc;
        Step::Cont
    } else {
        wr(xlen, x, 10, u64::MAX);
        *pc = npc;
        Step::Cont
    }
}

fn csr_read(c: &Csr, n: u32) -> u64 {
    match n {
        CSR_SATP => c.satp,
        CSR_STVEC => c.stvec,
        CSR_SIE => c.sie,
        CSR_SSTATUS => c.sstatus,
        CSR_SCAUSE => c.scause,
        CSR_SEPC => c.sepc,
        crate::encode::CSR_STVAL => c.stval,
        CSR_TIME => c.time,
        _ => 0,
    }
}

fn csr_write(c: &mut Csr, n: u32, v: u64) {
    match n {
        CSR_SATP => c.satp = v,
        CSR_STVEC => c.stvec = v,
        CSR_SIE => c.sie = v,
        CSR_SSTATUS => c.sstatus = v,
        CSR_SCAUSE => c.scause = v,
        CSR_SEPC => c.sepc = v,
        crate::encode::CSR_STVAL => c.stval = v,
        CSR_TIME => c.time = v,
        _ => {}
    }
}

/// Effective address for load/store/`jalr`. The RV32 register file holds
/// sign-extended values (`wr`), so a `la`/`auipc` pair at `0x8xxx_xxxx`
/// leaves `rs1` looking like `0xFFFF_FFFF_8xxx_xxxx`; the address must wrap
/// at 32 bits, not carry the sign extension into the u64 compare.
fn eff_addr(xlen: u32, x: &[u64; 32], rs1: u32, imm: i32) -> u64 {
    if xlen == 32 {
        u64::from((x[rs1 as usize] as u32).wrapping_add(imm as u32))
    } else {
        x[rs1 as usize].wrapping_add(imm as u64)
    }
}

fn wr(xlen: u32, x: &mut [u64; 32], rd: u32, v: u64) {
    if rd == 0 {
        return;
    }
    x[rd as usize] = if xlen == 32 {
        v as u32 as i32 as i64 as u64
    } else {
        v
    };
}

fn sext32(v: i32, xlen: u32) -> u64 {
    if xlen == 32 {
        v as u32 as u64
    } else {
        v as i64 as u64
    }
}

fn iimm(w: u32) -> i32 {
    (w as i32) >> 20
}

fn simm(w: u32) -> i32 {
    let imm = ((w >> 25) << 5) | ((w >> 7) & 0x1f);
    ((imm as i32) << 20) >> 20
}

fn bimm(w: u32) -> i32 {
    let imm = (((w >> 31) & 1) << 12)
        | (((w >> 25) & 0x3f) << 5)
        | (((w >> 8) & 0xf) << 1)
        | (((w >> 7) & 1) << 11);
    ((imm as i32) << 19) >> 19
}

fn jimm(w: u32) -> i32 {
    let imm = (((w >> 31) & 1) << 20)
        | (((w >> 21) & 0x3ff) << 1)
        | (((w >> 20) & 1) << 11)
        | (((w >> 12) & 0xff) << 12);
    ((imm as i32) << 11) >> 11
}

fn shamt(w: u32, xlen: u32) -> u32 {
    if xlen == 32 {
        (w >> 20) & 0x1f
    } else {
        (w >> 20) & 0x3f
    }
}

// ---- M3b FP conversion helpers (RISC-V fcvt semantics) ---------------------
// Round-to-nearest-even; NaN → the signed/unsigned max; saturate on range.

/// Round an f32 toward the `rm` rounding mode, then saturate to int range.
/// rm 1 = RTZ (toward zero — WASM `trunc`), else RNE (the convert default and
/// RISC-V dynamic-mode approximation). NaN saturates to the int max, matching
/// hardware fcvt's invalid-result convention.
fn fround(v: f32, rm: u32) -> f32 {
    if rm == 1 {
        v.trunc()
    } else {
        v.round_ties_even()
    }
}

fn fcvt_to_i32(v: f32, rm: u32) -> i32 {
    if v.is_nan() {
        i32::MAX
    } else {
        fround(v, rm).clamp(i32::MIN as f32, i32::MAX as f32) as i32
    }
}

fn fcvt_to_u32(v: f32, rm: u32) -> u32 {
    if v.is_nan() {
        u32::MAX
    } else {
        fround(v, rm).clamp(0.0, u32::MAX as f32) as u32
    }
}

fn fcvt_to_i64(v: f32, rm: u32) -> i64 {
    if v.is_nan() {
        i64::MAX
    } else {
        fround(v, rm).clamp(i64::MIN as f32, i64::MAX as f32) as i64
    }
}

fn fcvt_to_u64(v: f32, rm: u32) -> u64 {
    if v.is_nan() {
        u64::MAX
    } else {
        fround(v, rm).clamp(0.0, u64::MAX as f32) as u64
    }
}

/// `fclass.s` — the 10-bit IEEE class mask of an f32.
fn fclass_s(v: f32) -> u64 {
    if v.is_nan() {
        return if v.is_sign_negative() { 1 << 9 } else { 1 << 8 };
    }
    match (v.classify(), v.is_sign_negative()) {
        (std::num::FpCategory::Infinite, true) => 1 << 0,
        (std::num::FpCategory::Infinite, false) => 1 << 7,
        (std::num::FpCategory::Normal, true) => 1 << 1,
        (std::num::FpCategory::Normal, false) => 1 << 6,
        (std::num::FpCategory::Subnormal, true) => 1 << 2,
        (std::num::FpCategory::Subnormal, false) => 1 << 5,
        (std::num::FpCategory::Zero, true) => 1 << 3,
        (std::num::FpCategory::Zero, false) => 1 << 4,
        _ => 0,
    }
}

fn fround_d(v: f64, rm: u32) -> f64 {
    if rm == 1 {
        v.trunc()
    } else {
        v.round_ties_even()
    }
}

fn fcvt_d_i32(v: f64, rm: u32) -> i32 {
    if v.is_nan() {
        i32::MAX
    } else {
        fround_d(v, rm).clamp(i32::MIN as f64, i32::MAX as f64) as i32
    }
}

fn fcvt_d_u32(v: f64, rm: u32) -> u32 {
    if v.is_nan() {
        u32::MAX
    } else {
        fround_d(v, rm).clamp(0.0, u32::MAX as f64) as u32
    }
}

fn fcvt_d_i64(v: f64, rm: u32) -> i64 {
    if v.is_nan() {
        i64::MAX
    } else {
        fround_d(v, rm).clamp(i64::MIN as f64, i64::MAX as f64) as i64
    }
}

fn fcvt_d_u64(v: f64, rm: u32) -> u64 {
    if v.is_nan() {
        u64::MAX
    } else {
        fround_d(v, rm).clamp(0.0, u64::MAX as f64) as u64
    }
}

/// `fclass.d` — the 10-bit IEEE class mask of an f64.
fn fclass_d(v: f64) -> u64 {
    if v.is_nan() {
        return if v.is_sign_negative() { 1 << 9 } else { 1 << 8 };
    }
    match (v.classify(), v.is_sign_negative()) {
        (std::num::FpCategory::Infinite, true) => 1 << 0,
        (std::num::FpCategory::Infinite, false) => 1 << 7,
        (std::num::FpCategory::Normal, true) => 1 << 1,
        (std::num::FpCategory::Normal, false) => 1 << 6,
        (std::num::FpCategory::Subnormal, true) => 1 << 2,
        (std::num::FpCategory::Subnormal, false) => 1 << 5,
        (std::num::FpCategory::Zero, true) => 1 << 3,
        (std::num::FpCategory::Zero, false) => 1 << 4,
        _ => 0,
    }
}

fn encode_ecall() -> u32 {
    crate::encode::ecall()
}

fn is_uart0(addr: u64) -> bool {
    (UART0..UART0 + 0x100).contains(&addr)
}

fn is_uart1(csr: &Csr, addr: u64) -> bool {
    csr.uart1_repl && (csr.uart1_base..csr.uart1_base + 0x100).contains(&addr)
}

fn uart_dev(csr: &mut Csr, addr: u64) -> &mut Uart16550 {
    if is_uart1(csr, addr) {
        &mut csr.uart1
    } else {
        &mut csr.uart0
    }
}

fn uart_load(csr: &mut Csr, addr: u64) -> u64 {
    let off = addr & 0x7;
    let uart1 = is_uart1(csr, addr);
    match off {
        0 => {
            let b = {
                let u = if uart1 {
                    &mut csr.uart1
                } else {
                    &mut csr.uart0
                };
                if !u.rx_valid {
                    return 0;
                }
                u.rx_valid = false;
                u.rx
            };
            csr.uart_rxs = csr.uart_rxs.saturating_add(1);
            u64::from(b)
        }
        1 => {
            let u = if uart1 { &csr.uart1 } else { &csr.uart0 };
            u64::from(u.ier)
        }
        5 => {
            let u = if uart1 { &csr.uart1 } else { &csr.uart0 };
            let mut lsr = 0x20u64; // THRE
            if u.rx_valid {
                lsr |= 1;
            }
            lsr
        }
        _ => 0,
    }
}

fn uart_store(csr: &mut Csr, addr: u64, val: u8) {
    let off = addr & 0x7;
    let u = uart_dev(csr, addr);
    if off == 1 {
        u.ier = val;
    }
}

fn host_uart_kick(csr: &mut Csr) -> bool {
    let ier = if csr.uart1_repl {
        csr.uart1.ier
    } else {
        csr.uart0.ier
    };
    if ier & 1 == 0 {
        return false;
    }
    const SEQ: &[u8] = b"ViewSection(\"config\")\nUi\nFile\nGet\n";
    // On boards with the virtio-input lane, follow up with `Keys` — the
    // canned host_inp_kick keypress should already sit in INP_KQ — then
    // `Await`×5 (4 slots + the bounded-capacity `AWAIT-REJ full`) + `Throw`
    // (reject the newest pending → `AWAIT-THROW`) + `Ui` (the DomAwait poll
    // drains the 3 still-pending slots).
    const SEQ_KEYS: &[u8] = b"Keys\n";
    const SEQ_AWAIT: &[u8] = b"Await\nAwait\nAwait\nAwait\nAwait\nThrow\nUi\n";
    // With the zealcli face compiled, a line no band command claims belongs to
    // the container: `help` switches to the packed page, `nosuchcmd` must be
    // reported (`CLI-CMD?`) rather than guessed at.
    // Ordered so the run ends on a page: the final painted frame is the `help`
    // page, which is what a test can assert about the screen.
    const SEQ_CLI: &[u8] = b"nosuchcmd\nclear\nhelp\n";
    // With a block device, `Blk` makes the guest read LBA 0/1 itself and name the
    // medium. It goes *before* the CLI segment so the run still ends on a page.
    const SEQ_BLK: &[u8] = b"Blk\n";
    let i = csr.uart_seq_i as usize;
    // Segments past SEQ only exist when their lane is live; the AWAIT base
    // skips the KEYS segment on input-less specs.
    let keys_len = if csr.vio_inp { SEQ_KEYS.len() } else { 0 };
    let await_base = SEQ.len() + keys_len;
    let blk_base = await_base + if csr.jit_lane { SEQ_AWAIT.len() } else { 0 };
    let cli_base = blk_base + if csr.vio_blk { SEQ_BLK.len() } else { 0 };
    let byte = if i < SEQ.len() {
        SEQ[i]
    } else if i < await_base {
        SEQ_KEYS[i - SEQ.len()]
    } else if csr.jit_lane && i < blk_base {
        // `Await` only exists under the jit DOM lane (the CLI text face shares
        // the row table but has no await slots).
        SEQ_AWAIT[i - await_base]
    } else if csr.vio_blk && i < cli_base {
        SEQ_BLK[i - blk_base]
    } else if csr.cli_face && i < cli_base + SEQ_CLI.len() {
        SEQ_CLI[i - cli_base]
    } else {
        return false;
    };
    csr.uart_seq_i = csr.uart_seq_i.saturating_add(1);
    let u = if csr.uart1_repl {
        &mut csr.uart1
    } else {
        &mut csr.uart0
    };
    u.rx = byte;
    u.rx_valid = true;
    if (csr.plic_enable & (1u32 << UART_IRQ)) != 0 {
        csr.plic_pending |= 1u32 << UART_IRQ;
    }
    true
}

fn fetch_u32(ram: &[u8], base: u64, pc: u64) -> Option<u32> {
    load_u32(ram, base, pc)
}

fn load_u8(ram: &[u8], base: u64, addr: u64) -> Option<u8> {
    let o = addr.checked_sub(base)? as usize;
    ram.get(o).copied()
}

fn load_u16(ram: &[u8], base: u64, addr: u64) -> Option<u16> {
    let o = addr.checked_sub(base)? as usize;
    ram.get(o..o + 2)
        .and_then(|b| b.try_into().ok())
        .map(u16::from_le_bytes)
}

fn load_u32(ram: &[u8], base: u64, addr: u64) -> Option<u32> {
    let o = addr.checked_sub(base)? as usize;
    ram.get(o..o + 4)
        .and_then(|b| b.try_into().ok())
        .map(u32::from_le_bytes)
}

fn load_u64(ram: &[u8], base: u64, addr: u64) -> Option<u64> {
    let o = addr.checked_sub(base)? as usize;
    ram.get(o..o + 8)
        .and_then(|b| b.try_into().ok())
        .map(u64::from_le_bytes)
}

fn store_u16(ram: &mut [u8], base: u64, addr: u64, v: u16) -> bool {
    if let Some(o) = addr.checked_sub(base).and_then(|d| usize::try_from(d).ok()) {
        if o + 2 <= ram.len() {
            ram[o..o + 2].copy_from_slice(&v.to_le_bytes());
            return true;
        }
    }
    false
}

fn store_u8(ram: &mut [u8], base: u64, addr: u64, v: u8) -> bool {
    if let Some(o) = addr.checked_sub(base).and_then(|d| usize::try_from(d).ok()) {
        if o < ram.len() {
            ram[o] = v;
            return true;
        }
    }
    false
}

fn inject_web_present(
    ram: &mut [u8],
    base: u64,
    scan_fb_base: u64,
    cap_base: u64,
    line_base: u64,
    web: &GuestWebPresent,
) {
    // `WEB_STAMPED` is the authoritative "a real web canvas owns the surface"
    // latch `WebBlit` reads — the cap's `UI_CAP_FLAG_WEB` alone only routes
    // `vp_web` (DomtRaster sets it too), so it cannot mark ownership.
    if line_base != 0 {
        store_u32(ram, base, line_base + crate::WEB_STAMPED_OFF as u64, 1);
    }
    if scan_fb_base != 0 && !web.scan_fb.is_empty() {
        if let Some(o) = scan_fb_base
            .checked_sub(base)
            .and_then(|d| usize::try_from(d).ok())
        {
            let n = web.scan_fb.len().min(ram.len().saturating_sub(o));
            if n > 0 {
                ram[o..o + n].copy_from_slice(&web.scan_fb[..n]);
            }
        }
    }
    if cap_base == 0 {
        return;
    }
    let ntile = web.tiles.len().min(crate::vio::UI_CAP_MAX_TILES) as u32;
    store_u32(ram, base, cap_base, crate::vio::UI_CAP_MAGIC);
    store_u32(
        ram,
        base,
        cap_base.wrapping_add(crate::vio::UI_CAP_OFF_FLAGS as u64),
        crate::vio::UI_CAP_FLAG_WEB | crate::vio::UI_CAP_FLAG_PK,
    );
    store_u32(
        ram,
        base,
        cap_base.wrapping_add(crate::vio::UI_CAP_OFF_NODES as u64),
        web.node_count,
    );
    store_u32(
        ram,
        base,
        cap_base.wrapping_add(crate::vio::UI_CAP_OFF_NTILE as u64),
        ntile,
    );
    for (i, t) in web
        .tiles
        .iter()
        .take(crate::vio::UI_CAP_MAX_TILES)
        .enumerate()
    {
        let at = cap_base
            .wrapping_add(crate::vio::UI_CAP_OFF_RECTS as u64)
            .wrapping_add((i as u64) * 16);
        store_u32(ram, base, at, t.x as u32);
        store_u32(ram, base, at.wrapping_add(4), t.y as u32);
        store_u32(ram, base, at.wrapping_add(8), t.w as u32);
        store_u32(ram, base, at.wrapping_add(12), t.h as u32);
    }
}

fn store_u32(ram: &mut [u8], base: u64, addr: u64, v: u32) -> bool {
    if let Some(o) = addr.checked_sub(base).and_then(|d| usize::try_from(d).ok()) {
        if o + 4 <= ram.len() {
            ram[o..o + 4].copy_from_slice(&v.to_le_bytes());
            return true;
        }
    }
    false
}

fn store_u64(ram: &mut [u8], base: u64, addr: u64, v: u64) -> bool {
    if let Some(o) = addr.checked_sub(base).and_then(|d| usize::try_from(d).ok()) {
        if o + 8 <= ram.len() {
            ram[o..o + 8].copy_from_slice(&v.to_le_bytes());
            return true;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::analyze;
    use crate::task::{
        task_entry_ir, task_switch_ir, TaskLayout, TaskStart, TASK_ENTRY, TASK_REGISTERS,
        TASK_SWITCH,
    };
    use crate::{Addr, Node, Op, Purpose};

    const TASK_BASE: u64 = 0x1000;

    struct TaskMachine {
        xlen: u32,
        x: [u64; 32],
        pc: u64,
        csr: Csr,
        ram: Vec<u8>,
        console: String,
    }

    impl TaskMachine {
        fn new(xlen: u32, module: &Module) -> Self {
            let (words, rodata) = module.to_words(TASK_BASE).unwrap();
            assert!(rodata.is_empty());
            let mut ram = vec![0; 0x10000];
            for (slot, word) in words.iter().enumerate() {
                ram[slot * 4..slot * 4 + 4].copy_from_slice(&word.to_le_bytes());
            }
            Self {
                xlen,
                x: [0; 32],
                pc: TASK_BASE,
                csr: Csr::default(),
                ram,
                console: String::new(),
            }
        }

        fn tick(&mut self) -> Option<Halt> {
            let word = fetch_u32(&self.ram, TASK_BASE, self.pc).unwrap();
            match step(
                self.xlen,
                &mut self.x,
                &mut self.pc,
                &mut self.csr,
                &mut self.ram,
                TASK_BASE,
                word,
                &mut self.console,
                &mut 0,
            ) {
                Step::Cont => None,
                Step::Halt(halt) => Some(halt),
            }
        }

        fn put(&mut self, address: u64, image: &[u8]) {
            let offset = (address - TASK_BASE) as usize;
            self.ram[offset..offset + image.len()].copy_from_slice(image);
        }

        fn word(&self, address: u64) -> u64 {
            if self.xlen == 32 {
                u64::from(load_u32(&self.ram, TASK_BASE, address).unwrap())
            } else {
                load_u64(&self.ram, TASK_BASE, address).unwrap()
            }
        }

        fn reg(&self, register: u32) -> u64 {
            if self.xlen == 32 {
                u64::from(self.x[register as usize] as u32)
            } else {
                self.x[register as usize]
            }
        }
    }

    fn task_module(ops: Vec<Op>) -> Module {
        Module {
            nodes: vec![Node {
                purpose: Purpose::Topology,
                ops,
            }],
            ..Module::default()
        }
    }

    fn task_label(module: &Module, label: &str) -> u64 {
        let mut pc = TASK_BASE;
        for op in module.nodes.iter().flat_map(|n| &n.ops) {
            if matches!(op, Op::Label(name) if name == label) {
                return pc;
            }
            pc += crate::op_nwords(op) as u64 * 4;
        }
        panic!("missing label {label}");
    }

    fn task_load(xlen: u32, rd: u32, rs: u32, off: i32) -> Op {
        if xlen == 32 {
            Op::Lw { rd, rs, off }
        } else {
            Op::Ld { rd, rs, off }
        }
    }

    fn task_store(xlen: u32, rs2: u32, rs1: u32, off: i32) -> Op {
        if xlen == 32 {
            Op::Sw { rs2, rs1, off }
        } else {
            Op::Sd { rs2, rs1, off }
        }
    }

    fn task_yield(ops: &mut Vec<Op>, old: u64, next: u64) {
        ops.extend([
            Op::La {
                rd: 10,
                addr: Addr::Abs(old),
            },
            Op::La {
                rd: 11,
                addr: Addr::Abs(next),
            },
            Op::Jal {
                rd: 1,
                to: TASK_SWITCH.into(),
            },
        ]);
    }

    fn task_handler(xlen: u32, name: &str, old: u64, next: u64, enable: bool) -> Vec<Op> {
        let word = (xlen / 8) as i32;
        let frame = 16 * word;
        let mut ops = vec![
            Op::Label(format!("{name}_enter")),
            Op::Addi {
                rd: 2,
                rs: 2,
                imm: -frame,
            },
        ];
        let saved: Vec<_> = TASK_REGISTERS.iter().copied().filter(|r| *r != 2).collect();
        for (slot, register) in saved.iter().enumerate() {
            ops.push(task_store(xlen, *register, 2, slot as i32 * word));
        }
        ops.push(task_store(xlen, 10, 2, 13 * word));
        for (slot, register) in TASK_REGISTERS[2..].iter().enumerate() {
            ops.push(Op::Li {
                rd: *register,
                imm: -100 - slot as i64 - if enable { 100 } else { 0 },
            });
        }
        ops.push(Op::Li {
            rd: 5,
            imm: SSTATUS_SIE,
        });
        ops.push(if enable {
            Op::Csrrs {
                rd: 0,
                csr: CSR_SSTATUS,
                rs: 5,
            }
        } else {
            Op::Csrrc {
                rd: 0,
                csr: CSR_SSTATUS,
                rs: 5,
            }
        });
        ops.push(Op::Label(format!("{name}_ready")));
        task_yield(&mut ops, old, next);
        ops.push(Op::Label(format!("{name}_resumed")));
        ops.push(task_load(xlen, 10, 2, 13 * word));
        ops.push(Op::Addi {
            rd: 10,
            rs: 10,
            imm: 1,
        });
        for (slot, register) in saved.iter().enumerate() {
            ops.push(task_load(xlen, *register, 2, slot as i32 * word));
        }
        ops.extend([
            Op::Addi {
                rd: 2,
                rs: 2,
                imm: frame,
            },
            Op::Jalr {
                rd: 0,
                rs: 1,
                imm: 0,
            },
        ]);
        ops
    }

    #[test]
    fn task_lowered_words_alternate_stacks_registers_and_exit_rv32_rv64() {
        for xlen in [32, 64] {
            let layout = TaskLayout::new(xlen).unwrap();
            let mut ops = Vec::new();
            task_yield(&mut ops, 0x6000, 0x6100);
            ops.extend([Op::Label("root_resumed".into()), Op::Wfi]);
            ops.extend(task_handler(xlen, "a", 0x6100, 0x6200, false));
            ops.extend(task_handler(xlen, "b", 0x6200, 0x6100, true));
            for (name, old, next) in [("a", 0x6100, 0x6200), ("b", 0x6200, 0x6000)] {
                ops.push(Op::Label(format!("{name}_exit")));
                task_yield(&mut ops, old, next);
                ops.push(Op::Wfi);
            }
            let mut module = task_module(ops);
            module.nodes.extend(task_entry_ir(xlen).unwrap().nodes);
            module.nodes.extend(task_switch_ir(xlen).unwrap().nodes);
            let switch_pc = task_label(&module, TASK_SWITCH);
            let switch_end = TASK_BASE + module.to_words(TASK_BASE).unwrap().0.len() as u64 * 4;
            let mut machine = TaskMachine::new(xlen, &module);
            let argument = if xlen == 32 {
                0xfedc_ba98
            } else {
                0x1234_5678_fedc_ba98
            };
            let bootstrap = layout.empty_context(0x6000, 3).unwrap();
            machine.put(0x6000, &bootstrap);
            for (name, address, stack_base, arg, enable) in [
                ("a", 0x6100, 0x8000, argument, true),
                ("b", 0x6200, 0x9000, argument + 16, false),
            ] {
                let image = layout
                    .initial_context(
                        address,
                        TaskStart {
                            hart_id: 3,
                            stack_base,
                            stack_bytes: 0x1000,
                            entry_pc: task_label(&module, TASK_ENTRY),
                            handler_pc: task_label(&module, &format!("{name}_enter")),
                            argument: arg,
                            exit_pc: task_label(&module, &format!("{name}_exit")),
                            enable_interrupts: enable,
                        },
                    )
                    .unwrap();
                layout
                    .validate_switch(0x6000, &bootstrap, address, &image, 3)
                    .unwrap();
                machine.put(address, &image);
            }
            machine.x[2] = 0x8000;
            machine.x[3] = 0x1357_2468;
            machine.x[4] = 3;
            for (slot, register) in TASK_REGISTERS[2..].iter().enumerate() {
                wr(xlen, &mut machine.x, *register, 0x3456_0000 + slot as u64);
            }
            let root_registers = machine.x;
            let other_status = 0xc0000 | SSTATUS_SPIE | SSTATUS_SPP;
            machine.csr.sstatus = other_status | 2;
            machine.csr.satp = 0x1234;
            machine.csr.sie = 0x220;
            machine.csr.sepc = 0x5678;
            let checkpoints = [
                "a_enter",
                "a_ready",
                "b_enter",
                "b_ready",
                "a_resumed",
                "a_exit",
                "b_resumed",
                "b_exit",
                "root_resumed",
            ];
            let mut seen = Vec::new();
            let mut snapshots = [[0u64; 32]; 2];
            let mut switches = 0;
            let mut halt = None;
            for _ in 0..2000 {
                if machine.pc == switch_pc {
                    switches += 1;
                }
                for (index, label) in checkpoints.iter().enumerate() {
                    if machine.pc != task_label(&module, label) {
                        continue;
                    }
                    seen.push(index);
                    match *label {
                        "a_enter" | "b_enter" => {
                            let b = *label == "b_enter";
                            assert_eq!(machine.reg(10), argument + if b { 16 } else { 0 });
                            assert_eq!(machine.reg(2), if b { 0xa000 } else { 0x9000 });
                            assert_eq!(machine.csr.sstatus & 2, if b { 0 } else { 2 });
                        }
                        "a_ready" | "b_ready" => {
                            snapshots[usize::from(*label == "b_ready")] = machine.x;
                        }
                        "a_resumed" | "b_resumed" => {
                            let b = *label == "b_resumed";
                            let snapshot = snapshots[usize::from(b)];
                            for register in TASK_REGISTERS.iter().filter(|r| **r != 1) {
                                assert_eq!(
                                    machine.x[*register as usize], snapshot[*register as usize],
                                    "RV{xlen} {label} x{register}"
                                );
                            }
                            assert_eq!(machine.reg(10), 0);
                            assert_eq!(machine.reg(1), task_label(&module, label));
                            let address = if b { 0x6200 } else { 0x6100 };
                            for register in TASK_REGISTERS {
                                let saved = machine.word(
                                    address + layout.register_offset(register).unwrap() as u64,
                                );
                                assert_eq!(saved, machine.reg(register), "saved x{register}");
                            }
                            assert_eq!(
                                machine.word(machine.reg(2) + 13 * layout.word_bytes() as u64),
                                argument + if b { 16 } else { 0 }
                            );
                            assert_eq!(machine.csr.sstatus & 2, if b { 2 } else { 0 });
                        }
                        "a_exit" | "b_exit" => {
                            let b = *label == "b_exit";
                            assert_eq!(machine.reg(10), argument + if b { 17 } else { 1 });
                            assert_eq!(machine.reg(2), if b { 0xa000 } else { 0x9000 });
                        }
                        "root_resumed" => {
                            for register in TASK_REGISTERS.iter().filter(|r| **r != 1) {
                                assert_eq!(
                                    machine.x[*register as usize],
                                    root_registers[*register as usize]
                                );
                            }
                            assert_eq!(machine.reg(10), 0);
                            assert_eq!(machine.csr.sstatus & 2, 2);
                        }
                        _ => unreachable!(),
                    }
                }
                let word = fetch_u32(&machine.ram, TASK_BASE, machine.pc).unwrap();
                if (switch_pc..switch_end).contains(&machine.pc)
                    && matches!(word & 0x7f, 0x03 | 0x23)
                {
                    assert_eq!(
                        machine.csr.sstatus & 2,
                        0,
                        "context memory touched with SIE"
                    );
                }
                halt = machine.tick();
                assert_eq!(machine.reg(3), 0x1357_2468);
                assert_eq!(machine.reg(4), 3);
                assert_eq!(machine.csr.sstatus & !2, other_status);
                assert_eq!(machine.csr.satp, 0x1234);
                assert_eq!(machine.csr.sie, 0x220);
                assert_eq!(machine.csr.sepc, 0x5678);
                if halt.is_some() {
                    break;
                }
            }
            assert_eq!(halt, Some(Halt::Wfi));
            assert_eq!(seen, (0..checkpoints.len()).collect::<Vec<_>>());
            assert_eq!(switches, 5);
            for address in [0x6000, 0x6100, 0x6200] {
                assert_eq!(machine.word(address + layout.hart_offset() as u64), 3);
            }
        }
    }

    #[test]
    fn task_switch_rejects_wrong_hart_and_invalid_context_without_mutation() {
        for xlen in [32, 64] {
            for enabled in [0, 2] {
                for case in 0..15 {
                    let layout = TaskLayout::new(xlen).unwrap();
                    let module = task_switch_ir(xlen).unwrap();
                    let mut machine = TaskMachine::new(xlen, &module);
                    let mut old = layout.empty_context(0x6000, 3).unwrap();
                    let mut next = layout
                        .initial_context(
                            0x6100,
                            TaskStart {
                                hart_id: 3,
                                stack_base: 0x8000,
                                stack_bytes: 0x1000,
                                entry_pc: 0x2000,
                                handler_pc: 0x2100,
                                argument: 0,
                                exit_pc: 0x2200,
                                enable_interrupts: true,
                            },
                        )
                        .unwrap();
                    let word_bytes = layout.word_bytes();
                    let corrupt = |image: &mut [u8], offset: usize, value: u64| {
                        image[offset..offset + word_bytes]
                            .copy_from_slice(&value.to_le_bytes()[..word_bytes]);
                    };
                    machine.x[1] = 0x1800;
                    machine.x[2] = 0xa000;
                    machine.x[3] = 0x123456;
                    machine.x[4] = 3;
                    machine.x[10] = 0x6000;
                    machine.x[11] = 0x6100;
                    match case {
                        0 => corrupt(&mut old, layout.hart_offset(), 4),
                        1 => corrupt(&mut next, layout.hart_offset(), 4),
                        2 => corrupt(&mut next, layout.register_offset(2).unwrap(), 0x8008),
                        3 => corrupt(&mut next, layout.register_offset(1).unwrap(), 0x2002),
                        4 => corrupt(&mut next, layout.sie_offset(), 0x22),
                        5 => machine.x[10] = 0,
                        6 => machine.x[11] = 0,
                        7 => machine.x[10] += 8,
                        8 => machine.x[11] += 8,
                        9 => machine.x[11] = machine.x[10],
                        10 => machine.x[2] += 8,
                        11 => machine.x[1] += 2,
                        12..=14 => {}
                        _ => unreachable!(),
                    }
                    machine.put(0x6000, &old);
                    machine.put(0x6100, &next);
                    let ram_before = machine.ram.clone();
                    let regs_before = machine.x;
                    let status_before = 0xc0000
                        | enabled
                        | match case {
                            12 => 1 << 13,
                            13 => 1 << 9,
                            14 => 1 << 15,
                            _ => 0,
                        };
                    machine.csr.sstatus = status_before;
                    let mut returned = false;
                    for _ in 0..200 {
                        assert_eq!(machine.tick(), None, "RV{xlen} reject case {case}");
                        if machine.pc == regs_before[1] {
                            returned = true;
                            break;
                        }
                    }
                    assert!(returned);
                    assert_eq!(
                        machine.reg(10),
                        if xlen == 32 {
                            u64::from(u32::MAX)
                        } else {
                            u64::MAX
                        }
                    );
                    for register in TASK_REGISTERS.into_iter().chain([3, 4]) {
                        assert_eq!(machine.x[register as usize], regs_before[register as usize]);
                    }
                    assert_eq!(machine.csr.sstatus, status_before);
                    assert_eq!(machine.ram, ram_before);
                }
            }
        }
    }

    #[test]
    fn task_entry_masks_sie_and_parks_if_exit_hook_returns() {
        for xlen in [32, 64] {
            let mut module = task_entry_ir(xlen).unwrap();
            module.nodes.extend(
                task_module(vec![
                    Op::Label("handler".into()),
                    Op::Addi {
                        rd: 10,
                        rs: 10,
                        imm: 7,
                    },
                    Op::Jalr {
                        rd: 0,
                        rs: 1,
                        imm: 0,
                    },
                    Op::Label("exit".into()),
                    Op::Addi {
                        rd: 11,
                        rs: 10,
                        imm: 0,
                    },
                    Op::Jalr {
                        rd: 0,
                        rs: 1,
                        imm: 0,
                    },
                ])
                .nodes,
            );
            let mut machine = TaskMachine::new(xlen, &module);
            machine.x[2] = 0x8000;
            machine.x[3] = 0x1234;
            machine.x[4] = 2;
            machine.x[8] = task_label(&module, "handler");
            machine.x[9] = 41;
            machine.x[18] = task_label(&module, "exit");
            machine.csr.sstatus = 0x66002;
            let mut halt = None;
            for _ in 0..20 {
                halt = machine.tick();
                if halt.is_some() {
                    break;
                }
            }
            assert_eq!(halt, Some(Halt::Wfi));
            assert_eq!(machine.reg(11), 48);
            assert_eq!(machine.reg(2), 0x8000);
            assert_eq!(machine.reg(3), 0x1234);
            assert_eq!(machine.reg(4), 2);
            assert_eq!(machine.csr.sstatus, 0x66000);
            assert_eq!(machine.tick(), None);
            assert_eq!(machine.tick(), Some(Halt::Wfi));
        }
    }

    #[test]
    fn rv32_srli_zero_extends_sign_extended_register_before_shifting() {
        for xlen in [32, 64] {
            let module = task_module(vec![
                Op::Li { rd: 5, imm: -1 },
                Op::Srli {
                    rd: 6,
                    rs: 5,
                    shamt: xlen - 1,
                },
                Op::Srli {
                    rd: 7,
                    rs: 5,
                    shamt: 1,
                },
                Op::Srli {
                    rd: 8,
                    rs: 5,
                    shamt: 0,
                },
                Op::Wfi,
            ]);
            let mut machine = TaskMachine::new(xlen, &module);
            for _ in 0..4 {
                assert_eq!(machine.tick(), None);
            }
            assert_eq!(machine.tick(), Some(Halt::Wfi));
            assert_eq!(machine.reg(6), 1);
            assert_eq!(
                machine.reg(7),
                if xlen == 32 {
                    0x7fff_ffff
                } else {
                    0x7fff_ffff_ffff_ffff
                }
            );
            assert_eq!(
                machine.reg(8),
                if xlen == 32 { 0xffff_ffff } else { u64::MAX }
            );
        }
    }

    #[test]
    fn execution_budget_is_explicit_and_bounded() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1}"#).unwrap();
        let module = analyze::kstart(&spec);
        for limit in [0, 192_000_001, u32::MAX] {
            assert!(run_module_with_limit(&spec, &module, 0x8020_0000, limit).is_err());
        }
        let smoke = run_module_with_limit(&spec, &module, 0x8020_0000, 1).unwrap();
        assert_eq!(smoke.halt, Halt::Limit);
        assert_eq!(smoke.steps, 1);
    }

    #[test]
    fn kstart_smoke_prints_satp_and_timer() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let m = analyze::kstart(&spec);
        let s = run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(
            s.console.contains("KSTART-SATP-BARE"),
            "halt={:?} steps={} satp={:#x} console={:?}",
            s.halt,
            s.steps,
            s.satp,
            s.console
        );
        assert!(s.console.contains("KSTART-TIMER"), "{}", s.console);
        assert!(s.console.contains("KMAIN"), "{}", s.console);
        assert!(s.console.contains("KSTART-UART0"), "{}", s.console);
        assert_eq!(s.satp, 0);
        assert!(matches!(s.halt, Halt::Wfi | Halt::UartPoll), "{:?}", s.halt);
        assert!(!s.console.contains("CR3"));
        let once = s.console.matches("KSTART-TIMER").count();
        assert_eq!(once, 1, "UART0 THR must not duplicate SBI putchar");
        assert!(
            s.ticks >= 1 && s.time_ecalls >= 2,
            "IRQ_TIMER must run: ticks={} time_ecalls={} halt={:?}",
            s.ticks,
            s.time_ecalls,
            s.halt
        );
    }

    #[test]
    fn secondary_hart_parks_without_boot_log() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"harts":{"count":2}}"#,
        )
        .unwrap();
        let m = analyze::kstart(&spec);
        let s = run_module_hart(&spec, &m, 0x8020_0000, 1).unwrap();
        assert!(s.console.is_empty(), "{}", s.console);
        assert!(matches!(s.halt, Halt::Wfi), "{:?}", s.halt);
        assert_eq!(s.satp, 0);
        assert_eq!(s.ticks, 0, "hart≠0 parks before TimerInit");
    }

    #[test]
    fn trap_fault_dumps_illegal_and_halts() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let m = analyze::illegal_probe(&spec);
        let s = run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(
            s.console.contains("TRAP-"),
            "halt={:?} faults={} console={:?}",
            s.halt,
            s.faults,
            s.console
        );
        assert!(
            s.console.contains("0000000000000002"),
            "scause illegal-insn: {}",
            s.console
        );
        assert!(s.faults >= 1, "faults={}", s.faults);
        assert!(matches!(s.halt, Halt::Wfi), "{:?}", s.halt);
        assert!(!s.console.contains("IRET"));
    }

    #[test]
    fn plic_sei_claims_uart_irq() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"uncore":{"plic":true},"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let m = analyze::kstart(&spec);
        let s = run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(
            s.sei_claims >= 1,
            "SEI not taken: sei={} ticks={} halt={:?} console={:?}",
            s.sei_claims,
            s.ticks,
            s.halt,
            s.console
        );
        assert!(!s.console.contains("TRAP-"), "{}", s.console);
        assert!(s.ticks >= 1, "timer still after SEI: ticks={}", s.ticks);
        assert!(s.console.contains("KSTART-PLIC"), "{}", s.console);
    }

    #[test]
    fn hsm_starts_secondary_and_sends_ipi() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"harts":{"count":2},"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let m = analyze::kstart(&spec);
        let s = run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(
            s.hsm_starts >= 1 && s.ipi_sends >= 1,
            "hsm={} ipi={} halt={:?} console={:?}",
            s.hsm_starts,
            s.ipi_sends,
            s.halt,
            s.console
        );
        assert!(s.console.contains("KSTART-HSM"), "{}", s.console);
        assert!(!s.console.contains("TRAP-"), "{}", s.console);
        assert!(s.ticks >= 1, "ticks={}", s.ticks);
    }

    #[test]
    fn mbox_init_writes_magic_and_enables_irq() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"uncore":{"plic":true},"loopback":{"enable":true},"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let m = analyze::kstart(&spec);
        let s = run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(s.console.contains("KSTART-MBOX"), "{}", s.console);
        assert_eq!(s.mbox_magic, MBOX_MAGIC, "doorbell magic");
        assert!(
            s.sei_claims >= 1,
            "mbox irq should hit PLIC: sei={} halt={:?}",
            s.sei_claims,
            s.halt
        );
        assert!(!s.console.contains("TRAP-"), "{}", s.console);
        assert_eq!(
            s.mbox_status & crate::encode::MBOX_ST_RSP,
            crate::encode::MBOX_ST_RSP,
            "View kick should set ST_RSP: status={:#x} halt={:?}",
            s.mbox_status,
            s.halt
        );
        assert_eq!(
            s.mbox_rsp,
            crate::encode::MBOX_RSP_VIEW,
            "VIEW rsp word {:#x}",
            s.mbox_rsp
        );
    }

    #[test]
    fn vio_probe_finds_modelled_gpu_at_slot0() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"uncore":{"plic":true},
"kernel":{"gr":{"enable":true,"w":640,"h":480,"colors":16,"backend":"virtio-gpu"}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let m = analyze::kstart(&spec);
        let s = run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(s.console.contains("VIRTIO-GPU 0"), "{}", s.console);
        assert!(!s.console.contains("VIRTIO-GPU-NONE"), "{}", s.console);
        // Full handshake + ctrlq GET_DISPLAY_INFO round-trip.
        assert!(s.console.contains("VIRTIO-GPU-OK"), "{}", s.console);
        assert!(s.console.contains("VIRTIO-INFO"), "{}", s.console);
        assert!(!s.console.contains("VIRTIO-GPU-FAIL"), "{}", s.console);
        assert_eq!(s.vio_status, 0x0f); // ACK|DRIVER|FEATURES_OK|DRIVER_OK
        assert_eq!(s.vio_last_cmd, 0x0104); // last cmd = RESOURCE_FLUSH
        assert_eq!(s.vio_last_resp, 0x1100); // RESP_OK_NODATA
                                             // Pixel path: scanout bound; after the band transfer,
                                             // VioPaint pushed the palette-expanded __gr_plane over the full
                                             // framebuffer and flushed it (once per paint pass).
        assert!(s.console.contains("VIRTIO-SCAN"), "{}", s.console);
        assert!(s.vio_scanout);
        let paints = s.console.matches("VIRTIO-PAINT\n").count() as u32;
        assert!(paints >= 1, "{}", s.console);
        assert_eq!(s.vio_flushes, 1 + paints);
        // Six scan chains (INFO + CREATE + ATTACH + SET_SCANOUT + TRANSFER +
        // FLUSH) plus TRANSFER + FLUSH per paint → used-buffer interrupts,
        // each raising PLIC irq 1+slot and claimed by trap_vio through the
        // modelled PLIC (plus the one-shot UART injection claim).
        assert_eq!(s.vio_irqs, 6 + 2 * paints);
        assert!(
            s.sei_claims >= 6 + 2 * paints,
            "virtio SEIs not claimed through PLIC: sei={} console={}",
            s.sei_claims,
            s.console
        );
        assert_eq!((s.vio_fb_w, s.vio_fb_h), (640, 480));
        // vio_fb is the X8R8G8B8 expansion of the executed __gr_plane 4bpp
        // image (high nibble = even pixel) through the same 16-colour VGA
        // palette as g6b-gr (kept crate-independent here).
        const PAL: [u32; 16] = [
            0x0000_0000,
            0x0000_00AA,
            0x0000_AA00,
            0x0000_AAAA,
            0x00AA_0000,
            0x00AA_00AA,
            0x00AA_5500,
            0x00AA_AAAA,
            0x0055_5555,
            0x0055_55FF,
            0x0055_FF55,
            0x0055_FFFF,
            0x00FF_5555,
            0x00FF_55FF,
            0x00FF_FF55,
            0x00FF_FFFF,
        ];
        let hdr = u32::from_le_bytes(s.gr_frame[40..44].try_into().unwrap()) as usize;
        for (i, &b) in s.gr_frame[hdr..].iter().enumerate() {
            let o = i * 8;
            assert_eq!(
                u32::from_le_bytes(s.vio_fb[o..o + 4].try_into().unwrap()),
                PAL[(b >> 4) as usize],
                "even pixel of plane byte {i}"
            );
            assert_eq!(
                u32::from_le_bytes(s.vio_fb[o + 4..o + 8].try_into().unwrap()),
                PAL[(b & 0xf) as usize],
                "odd pixel of plane byte {i}"
            );
        }
    }

    /// The payload reads a disk **itself**: probe, requestq bring-up, a real
    /// `VIRTIO_BLK_T_IN` request, and the medium identified from LBA 0/1.
    ///
    /// This is the capability the autoboot handoff has been waiting on since B97 —
    /// until now the guest could only list what a host had told it about.
    #[test]
    fn the_guest_reads_its_own_sectors_and_names_the_medium() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"uncore":{"plic":true,"storage":true},
"kernel":{"gr":{"enable":true,"w":640,"h":480,"colors":16,"backend":"virtio-gpu"},
"cli":{"enable":true}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        assert!(
            spec.wants_virtio_blk(),
            "storage + cli + virtio → a blk driver"
        );
        let m = analyze::kstart(&spec);
        // `Blk` on the serial line runs `BlkSig`, which is two real reads.
        // The canned serial sequence includes Blk on a blk-capable board.
        let s = run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(
            s.console
                .contains(&format!("VIRTIO-BLK {}", crate::encode::VIO_BLK_SLOT)),
            "the slot it found, and its irq is 1+slot: {}",
            s.console
        );
        assert!(s.console.contains("VIRTIO-BLK-OK"), "{}", s.console);
        assert!(!s.console.contains("VIRTIO-BLK-NONE"), "{}", s.console);
        assert!(!s.console.contains("VIRTIO-BLK-FAIL"), "{}", s.console);
        // The medium is named from its own bytes: a protective MBR whose LBA 1
        // carries "EFI PART" is a GPT disk, not an MBR one.
        assert!(s.console.contains("BLK-SIG gpt"), "{}", s.console);
        assert!(!s.console.contains("BLK-TIMEOUT"), "{}", s.console);
        assert!(!s.console.contains("BLK-ERR"), "{}", s.console);
        assert!(!s.console.contains("BLK-NODEV"), "{}", s.console);
        // Real requests reached the device — the bytes were read, not assumed
        // from RAM that happened to look right. Boot names the medium once and the
        // Blk verb repeats it, so two reads each. FatRead/Ext4Read gate on the
        // BlkSig kind latch and cost nothing on a GPT medium.
        assert_eq!(
            s.blk_reqs, 4,
            "LBA 0 + LBA 1, at boot and on Blk: {}",
            s.console
        );
        assert!(!s.console.contains("TRAP-"), "{}", s.console);
    }

    /// The payload not only identifies a FAT32 medium but reads a file from it.
    #[test]
    fn the_guest_reads_a_file_from_fat32() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"uncore":{"plic":true,"storage":true},
"kernel":{"gr":{"enable":true,"w":640,"h":480,"colors":16,"backend":"virtio-gpu"},
"cli":{"enable":true}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let m = analyze::kstart(&spec);
        let s = run_module_with_blk_image(&spec, &m, 0x8020_0000, modelled_fat32_image()).unwrap();
        assert!(s.console.contains("VIRTIO-BLK-OK"), "{}", s.console);
        assert!(s.console.contains("BLK-SIG fat"), "{}", s.console);
        assert!(!s.console.contains("BLK-SIG gpt"), "{}", s.console);
        assert!(!s.console.contains("FILE-NODEV"), "{}", s.console);
        assert!(
            s.console.contains("FILE-FOUND hello from fat"),
            "{}",
            s.console
        );
        // Boot: BlkSig (LBA 0, FAT), FatRead (root + file); Ext4Read gates on the
        // kind latch and reads nothing. The canned `Blk` verb repeats it.
        assert!(s.blk_reqs >= 3, "blk_reqs={} {}", s.blk_reqs, s.console);
        assert!(!s.console.contains("TRAP-"), "{}", s.console);
    }

    /// The payload not only identifies an ext4 medium but reads a file from it:
    /// superblock → group descriptor → inode table → root directory → file data,
    /// all through the same BlkRead device path the FAT reader uses.
    #[test]
    fn the_guest_reads_a_file_from_ext4() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"uncore":{"plic":true,"storage":true},
"kernel":{"gr":{"enable":true,"w":640,"h":480,"colors":16,"backend":"virtio-gpu"},
"cli":{"enable":true}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let m = analyze::kstart(&spec);
        let s = run_module_with_blk_image(&spec, &m, 0x8020_0000, modelled_ext4_image()).unwrap();
        assert!(s.console.contains("VIRTIO-BLK-OK"), "{}", s.console);
        assert!(s.console.contains("BLK-SIG ext4"), "{}", s.console);
        assert!(!s.console.contains("FILE-NODEV"), "{}", s.console);
        assert!(
            s.console.contains("FILE-FOUND hello from ext4"),
            "{}",
            s.console
        );
        // BlkSig (LBA 0 + LBA 2 probe) plus Ext4Read's GDT, two inode-table,
        // root-dir and file reads — real requests, not RAM that happened to fit.
        assert!(s.blk_reqs >= 6, "blk_reqs={} {}", s.blk_reqs, s.console);
        assert!(!s.console.contains("TRAP-"), "{}", s.console);
    }

    /// A board with no storage compiles no driver, and the `Blk` verb does not
    /// exist — the CLI reports an unknown command rather than a silent no-op.
    #[test]
    fn no_storage_means_no_block_driver_at_all() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"uncore":{"plic":true},
"kernel":{"gr":{"enable":true,"w":640,"h":480,"colors":16,"backend":"virtio-gpu"},
"cli":{"enable":true}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        assert!(!spec.wants_virtio_blk(), "no uncore.storage → no driver");
        let m = analyze::kstart(&spec);
        let asm = m.to_asm();
        assert!(!asm.contains("BlkInit"), "the driver is not compiled in");
        assert!(!asm.contains("uart_blk"), "and neither is its verb");
        let s = run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(!s.console.contains("VIRTIO-BLK"), "{}", s.console);
        assert_eq!(s.blk_reqs, 0);
        assert!(!s.console.contains("TRAP-"), "{}", s.console);
    }

    #[test]
    fn vio_net_probe_finds_modelled_net_at_slot5() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"uncore":{"plic":true},
"kernel":{"hw":{"enable":true,"virtio_net":true}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        assert!(spec.wants_virtio_net());
        let m = analyze::kstart(&spec);
        let s = run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(s.console.contains("VIRTIO-NET 5"), "{}", s.console);
        assert!(!s.console.contains("VIRTIO-NET-NONE"), "{}", s.console);
        assert!(!s.console.contains("TRAP-"), "{}", s.console);
    }

    #[test]
    fn vio_paint_web_present_transfers_dirty_tiles_not_glyphs() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"uncore":{"plic":true},
"kernel":{"gr":{"enable":true,"w":640,"h":480,"colors":16,"backend":"virtio-gpu"}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let m = analyze::kstart(&spec);
        let mut fb = vec![0u8; 640 * 480 * 4];
        // Opaque red in B8G8R8X8 at (0,0).
        fb[0] = 0;
        fb[1] = 0;
        fb[2] = 0xff;
        fb[3] = 0xff;
        let web = GuestWebPresent {
            scan_fb: fb,
            tiles: vec![DirtyTile {
                x: 0,
                y: 0,
                w: 1,
                h: 1,
            }],
            node_count: 7,
        };
        let s = run_module_web(&spec, &m, 0x8020_0000, 0, Some(&web)).unwrap();
        assert!(s.console.contains("VIRTIO-PAINT\n"), "{}", s.console);
        // UART `Ui` re-paints after tiles were consumed → skip-if-clean.
        assert!(s.console.contains("VIRTIO-PAINT-SKIP"), "{}", s.console);
        assert_eq!(s.cap_magic, crate::vio::UI_CAP_MAGIC);
        assert_eq!(s.cap_nodes, 7);
        assert_eq!(s.cap_tiles, 0, "VioPaint consumes tiles");
        assert_eq!(&s.vio_fb[..4], &[0, 0, 0xff, 0xff]);
        // Neighbour pixel was not in the dirty tile — stays the VioScan band
        // or zero, not a 4bpp glyph expand of the whole frame.
        assert_ne!(&s.vio_fb[4..8], &[0, 0, 0xff, 0xff]);
    }

    /// `__web_pk` byte builder for the tests below: magic + geometry + node
    /// count + the token stream + the `0` stream-end marker.
    fn web_pk(w: u32, h: u32, nodes: u32, tokens: &[u32]) -> Vec<u8> {
        let mut pk = Vec::new();
        pk.extend_from_slice(&crate::webp::WEB_PK_MAGIC.to_le_bytes());
        pk.extend_from_slice(&w.to_le_bytes());
        pk.extend_from_slice(&h.to_le_bytes());
        pk.extend_from_slice(&nodes.to_le_bytes());
        for t in tokens {
            pk.extend_from_slice(&t.to_le_bytes());
        }
        pk.extend_from_slice(&0u32.to_le_bytes());
        pk
    }

    /// Non-shared guest-JIT board: the browser face owns the plane from
    /// power-on, so `WebBlit` must decode `__web_pk` into `__scan_fb` at boot
    /// and `vp_web` must transfer it — no picker, no text face.
    #[test]
    fn web_blit_paints_pack_into_scan_fb() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"uncore":{"plic":true},
"kernel":{"gr":{"enable":true,"w":640,"h":480,"colors":16,"backend":"virtio-gpu"},
          "cli":{"enable":false},
          "wasm":{"enable":true,"jit":true,"guest_jit":true}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let mut m = analyze::kstart(&spec);
        // 4×2 pack. Row 0 = LIT(1,b)+RUN(3,a); row 1 = LIT(4,c,d,e,f) — both
        // token forms on one surface, with the row-0 literal deliberately
        // *not* row-final: a corrupt literal count must still stop at its
        // declared width rather than swallow the run that follows (an RV64
        // `lw` sign-extension once made it clamp to the row remainder).
        let (a, b, c, d, e, f) = (
            0xff11_2233u32,
            0xff44_5566u32,
            0xff00_00ffu32,
            0xff00_ff00u32,
            0xffff_0000u32,
            0xffaa_bbccu32,
        );
        m.web_pk = web_pk(4, 2, 5, &[0x8000_0001, b, 3, a, 0x8000_0004, c, d, e, f]);
        let s = run_module(&spec, &m, 0x8020_0000).unwrap();
        let (w, h, stride) = (s.disp_sel.2, s.disp_sel.3, s.disp_sel.4);
        assert_eq!((w, h), (640, 480), "disp_sel {:?}", s.disp_sel);
        let px = |fb: &[u8], x: u32, y: u32| -> u32 {
            let off = (y * stride + x * 4) as usize;
            u32::from_le_bytes(fb[off..off + 4].try_into().unwrap())
        };
        // The RLE stream decoded into __scan_fb at the latched stride…
        assert_eq!(px(&s.scan_fb, 0, 0), b, "scan_fb(0,0) the literal");
        assert_eq!(px(&s.scan_fb, 1, 0), a, "scan_fb(1,0) run start");
        assert_eq!(px(&s.scan_fb, 3, 0), a, "scan_fb(3,0) inside the run");
        assert_eq!(px(&s.scan_fb, 0, 1), c, "scan_fb(0,1) second row");
        assert_eq!(px(&s.scan_fb, 3, 1), f, "scan_fb(3,1) row end");
        // …and `vp_web` transferred the wipe tile to the device surface.
        assert_eq!(px(&s.vio_fb, 0, 0), b, "vio_fb(0,0)");
        assert_eq!(px(&s.vio_fb, 3, 1), f, "vio_fb(3,1)");
        // `__ui_cap`: web persist stamped from the pack header; the wipe tile
        // is consumed by the paint.
        assert_eq!(s.cap_magic, crate::vio::UI_CAP_MAGIC);
        assert_eq!(s.cap_nodes, 5);
        assert_eq!(s.cap_tiles, 0, "VioPaint consumes the wipe tile");
        // One decode total: `wasm_ui` + `domt_boot` + the UART `Ui` each call
        // `WebBlit`, but the live check makes the repeats a0=1 early-outs —
        // the `WEBPK` marker only prints on a real blit.
        assert_eq!(s.console.matches("WEBPK ").count(), 1, "{}", s.console);
        assert!(s.console.contains("VIRTIO-PAINT\n"), "{}", s.console);
        assert!(!s.console.contains("TRAP-"), "{}", s.console);
    }

    /// Same board, no pack installed (the `.word 0` sentinel): `WebBlit`
    /// returns a0=0 and the bounded text face still paints — the pack is a
    /// preference, never a requirement.
    #[test]
    fn web_blit_no_pack_keeps_text_face() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"uncore":{"plic":true},
"kernel":{"gr":{"enable":true,"w":640,"h":480,"colors":16,"backend":"virtio-gpu"},
          "cli":{"enable":false},
          "wasm":{"enable":true,"jit":true,"guest_jit":true}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let m = analyze::kstart(&spec);
        let s = run_module(&spec, &m, 0x8020_0000).unwrap();
        assert_eq!(s.console.matches("WEBPK ").count(), 0, "{}", s.console);
        // DomtRaster's own persist stamp still drives vp_web — the text face
        // is the documented fallback and its navy page clear proves it ran.
        assert_eq!(s.cap_magic, crate::vio::UI_CAP_MAGIC);
        assert!(s.console.contains("VIRTIO-PAINT\n"), "{}", s.console);
        let navy = 0x0010_1620u32.to_le_bytes();
        assert_eq!(&s.vio_fb[..4], &navy[..], "DomtRaster page bg");
    }

    /// Exec-model contract: an injected `GuestWebPresent` already reads as a
    /// live web canvas (`G6CP`+WEB), so `WebBlit` must NOT overwrite it with
    /// the static pack — the host feed wins on web-feed runs.
    #[test]
    fn web_blit_yields_to_injected_present() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"uncore":{"plic":true},
"kernel":{"gr":{"enable":true,"w":640,"h":480,"colors":16,"backend":"virtio-gpu"},
          "cli":{"enable":false},
          "wasm":{"enable":true,"jit":true,"guest_jit":true}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let mut m = analyze::kstart(&spec);
        m.web_pk = web_pk(4, 2, 5, &[4, 0xff11_2233, 0x8000_0004, 1, 2, 3, 4]);
        let mut fb = vec![0u8; 640 * 480 * 4];
        fb[0] = 0;
        fb[1] = 0;
        fb[2] = 0xff;
        fb[3] = 0xff;
        let web = GuestWebPresent {
            scan_fb: fb,
            tiles: vec![DirtyTile {
                x: 0,
                y: 0,
                w: 1,
                h: 1,
            }],
            node_count: 7,
        };
        let s = run_module_web(&spec, &m, 0x8020_0000, 0, Some(&web)).unwrap();
        // The injected canvas presented, not the pack: no WEBPK decode ran.
        assert_eq!(s.console.matches("WEBPK ").count(), 0, "{}", s.console);
        assert_eq!(&s.vio_fb[..4], &[0, 0, 0xff, 0xff]);
        assert_eq!(s.cap_nodes, 7, "injected persist, not the pack's 5");
    }

    // ------------------------------------------------------------------
    // `__web_dl` (DlPaint) tests — the op-stream carry Stage 2 installs
    // beside the pixel pack. Builders below emit the exact record layout
    // `g6b_asm::dlp`'s module comment documents.
    // ------------------------------------------------------------------

    /// Op-stream helpers — `DLOP_*` words + args, matching `dl_state_stream`.
    fn dl_fill(x: i32, y: i32, w: i32, h: i32, rgba: u32) -> Vec<u8> {
        let mut s = Vec::new();
        for v in [
            crate::dlp::DLOP_FILL as u32,
            x as u32,
            y as u32,
            w as u32,
            h as u32,
            rgba,
        ] {
            s.extend_from_slice(&v.to_le_bytes());
        }
        s
    }

    fn dl_words(words: &[u32]) -> Vec<u8> {
        let mut s = Vec::new();
        for v in words {
            s.extend_from_slice(&v.to_le_bytes());
        }
        s
    }

    /// `__web_dl` byte image: header + tables laid out in the documented
    /// order (state, tref, size, glyph, blob, hit, strings, streams, blobs).
    /// `trefs` are the 14-word records verbatim; `glyphs` the 6-word records;
    /// `strings` the pool the recs' offsets point into.
    #[allow(clippy::too_many_arguments)]
    fn web_dl(
        w: u32,
        h: u32,
        states: &[(&str, Vec<u8>)],
        trefs: &[[u32; 14]],
        sizes: &[u32],
        glyphs: &[[u32; 6]],
        blobs: &[(u32, u32, Vec<u8>)],
        strings: &[u8],
    ) -> Vec<u8> {
        use crate::dlp::*;
        let hdr = WEB_DL_HDR as u32;
        let (n_state, n_tref, n_size, n_glyph, n_blob) = (
            states.len() as u32,
            trefs.len() as u32,
            sizes.len() as u32,
            glyphs.len() as u32,
            blobs.len() as u32,
        );
        let state_off = hdr;
        let tref_off = state_off + n_state * DL_STATE_REC as u32;
        let size_off = tref_off + n_tref * DL_TREF_REC as u32;
        let glyph_off = size_off + n_size * 4;
        let blobtab_off = glyph_off + n_glyph * DL_GLYPH_REC as u32;
        let hit_off = blobtab_off + n_blob * DL_BLOB_REC as u32;
        let str_off = hit_off;
        let ops_off = str_off + strings.len() as u32;
        let mut cursor = ops_off;
        let mut ops_at = Vec::new();
        for (_, stream) in states {
            ops_at.push((cursor, stream.len() as u32));
            cursor += stream.len() as u32;
        }
        let blobdata_off = cursor;
        let mut out = Vec::new();
        let push = |out: &mut Vec<u8>, v: u32| out.extend_from_slice(&v.to_le_bytes());
        for v in [
            WEB_DL_MAGIC,
            w,
            h,
            n_state,
            n_tref,
            n_size,
            n_glyph,
            n_blob,
            0, // n_hit
            state_off,
            tref_off,
            size_off,
            glyph_off,
            blobtab_off,
            hit_off,
            str_off,
            strings.len() as u32,
            blobdata_off,
        ] {
            push(&mut out, v);
        }
        // state recs {name8, off, len}
        for ((name, _), (off, len)) in states.iter().zip(&ops_at) {
            let mut nb = [0u8; 8];
            for (i, b) in name.as_bytes().iter().take(8).enumerate() {
                nb[i] = *b;
            }
            out.extend_from_slice(&nb);
            push(&mut out, *off);
            push(&mut out, *len);
        }
        for rec in trefs {
            for v in rec {
                push(&mut out, *v);
            }
        }
        for v in sizes {
            push(&mut out, *v);
        }
        for rec in glyphs {
            for v in rec {
                push(&mut out, *v);
            }
        }
        let mut bcursor = blobdata_off;
        for (bw, bh, cov) in blobs {
            for v in [bcursor, *bw, *bh, cov.len() as u32] {
                push(&mut out, v);
            }
            bcursor += cov.len() as u32;
        }
        out.extend_from_slice(strings);
        for (_, stream) in states {
            out.extend_from_slice(stream);
        }
        for (_, _, cov) in blobs {
            out.extend_from_slice(cov);
        }
        out
    }

    /// Splice `ops` right after the `jal DomtBoot` in the boot stream — the
    /// guest-side equivalent of the JS cell's `__dom` writes, for tests that
    /// need DOM state (`H_WST`, `__dom_id`, node text) set before the boot
    /// `WebPaint` runs in the same node.
    fn seed_after_domt_boot(m: &mut Module, ops: Vec<Op>) {
        // The earliest `jal WebPaint` in the program is the first `DlPaint`
        // the guest runs — live `__dom`/`__dom_id` state has to be in place
        // before it, so splice immediately ahead of that call rather than
        // after `DomtBoot` (a later node whose WebPaint would already see the
        // surface latched).
        for n in &mut m.nodes {
            if let Some(pos) = n
                .ops
                .iter()
                .position(|o| matches!(o, Op::Jal { to, .. } if to == "WebPaint"))
            {
                n.ops.splice(pos..pos, ops);
                return;
            }
        }
        panic!("no WebPaint call site");
    }

    /// The guest-JIT web spec the web tests share (browser owns the plane).
    fn web_guest_spec() -> BoardSpec {
        BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"uncore":{"plic":true},
"kernel":{"gr":{"enable":true,"w":640,"h":480,"colors":16,"backend":"virtio-gpu"},
  "cli":{"enable":false},
  "wasm":{"enable":true,"jit":true,"guest_jit":true}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap()
    }

    /// `DlPaint` replays the op stream into `__scan_fb`: FILL ground, FILLR
    /// corner test, STRKR ring, COV blob blit, TILEPX pixel relief — one op
    /// of each shape, each in its own region of a 16×8 canvas.
    #[test]
    fn dl_paint_replays_op_stream() {
        let spec = web_guest_spec();
        let mut m = analyze::kstart(&spec);
        let (navy, red, green, white) = (
            0x3020_10ffu32,
            0x4040_ffffu32,
            0x40ff_40ffu32,
            0xffff_ffffu32,
        );
        let mut stream = dl_fill(0, 0, 16, 8, navy);
        // FILLR {0,0,4,4,r=2,red} — inside_rounded leaves only the 2x2 centre.
        stream.extend(dl_words(&[
            crate::dlp::DLOP_FILLR as u32,
            0,
            0,
            4,
            4,
            2,
            red,
        ]));
        // STRKR {5,0,4,4,r=2,bw=1,green} — inner 2x2 r=1 is empty; the ring.
        stream.extend(dl_words(&[
            crate::dlp::DLOP_STRKR as u32,
            5,
            0,
            4,
            4,
            2,
            1,
            green,
        ]));
        // COV {10,0,blob0,white} — 2x2 full-coverage stamp.
        stream.extend(dl_words(&[crate::dlp::DLOP_COV as u32, 10, 0, 0, white]));
        // TILEPX {12,0,2,2} — LIT(2)+LIT(2) raw pixel relief.
        stream.extend(dl_words(&[
            crate::dlp::DLOP_TILEPX as u32,
            12,
            0,
            2,
            2,
            0x8000_0002,
            0xff11_2233,
            0xff44_5566,
            0x8000_0002,
            0xffaa_bbcc,
            0xffde_ad00,
        ]));
        stream.extend(dl_words(&[0])); // END
        m.web_dl = web_dl(
            16,
            8,
            &[("main", stream)],
            &[],
            &[],
            &[],
            &[(2, 2, vec![255, 255, 255, 255])],
            &[],
        );
        let s = run_module(&spec, &m, 0x8020_0000).unwrap();
        let stride = s.disp_sel.4;
        let px = |x: u32, y: u32| -> u32 {
            let off = (y * stride + x * 4) as usize;
            u32::from_le_bytes(s.scan_fb[off..off + 4].try_into().unwrap())
        };
        // Opaque store word = 0xFF<<24 | rgba>>8.
        let (x_navy, x_red, x_green, x_white) = (
            0xff00_0000 | (navy >> 8),
            0xff00_0000 | (red >> 8),
            0xff00_0000 | (green >> 8),
            0xff00_0000 | (white >> 8),
        );
        assert_eq!(px(0, 0), x_navy, "FILLR corner stays ground");
        assert_eq!(px(1, 1), x_red, "FILLR centre");
        assert_eq!(px(2, 2), x_red, "FILLR centre");
        assert_eq!(px(3, 0), x_navy, "FILLR edge column outside");
        // STRKR r=2/4x4: outer inside = the 4 centre px; inner r=1 on a 2x2
        // box is empty → the ring is exactly those four.
        assert_eq!(px(7, 0), x_navy, "STRKR corner-adjacent outside");
        assert_eq!(px(6, 1), x_green, "STRKR ring px");
        assert_eq!(px(7, 2), x_green, "STRKR ring px");
        assert_eq!(px(5, 0), x_navy, "STRKR corner outside");
        assert_eq!(px(10, 0), x_white, "COV stamp");
        assert_eq!(px(11, 1), x_white, "COV stamp");
        assert_eq!(px(12, 0), 0xff11_2233, "TILEPX literal");
        assert_eq!(px(13, 1), 0xffde_ad00, "TILEPX literal row 1");
        assert_eq!(px(15, 7), x_navy, "ground survives");
        // Ownership: WEBDL marker once, cap stamped WEB|PK + wipe consumed.
        assert_eq!(s.console.matches("WEBDL ").count(), 1, "{}", s.console);
        assert!(
            s.console.contains("WEBDL 0000000000000000\n"),
            "{}",
            s.console
        );
        assert_eq!(s.console.matches("WEBPK ").count(), 0, "{}", s.console);
        assert_eq!(s.cap_magic, crate::vio::UI_CAP_MAGIC);
        assert_eq!(s.cap_tiles, 0, "VioPaint consumes the wipe tile");
        assert!(s.console.contains("VIRTIO-PAINT\n"), "{}", s.console);
        assert!(!s.console.contains("TRAP-"), "{}", s.console);
    }

    /// Per-state lists: `__dom+H_WST` selects the state stream. Seeding
    /// H_WST=1 before the boot `WebPaint` must paint state 1's colour, not
    /// state 0's — the same latch the menu picker writes at runtime.
    #[test]
    fn dl_paint_state_select_via_h_wst() {
        let spec = web_guest_spec();
        let mut m = analyze::kstart(&spec);
        let s0 = {
            let mut v = dl_fill(0, 0, 16, 8, 0x3020_10ff);
            v.extend(dl_words(&[0]));
            v
        };
        let s1 = {
            let mut v = dl_fill(0, 0, 16, 8, 0x10ff_30ff);
            v.extend(dl_words(&[0]));
            v
        };
        m.web_dl = web_dl(16, 8, &[("main", s0), ("cpu", s1)], &[], &[], &[], &[], &[]);
        seed_after_domt_boot(&mut m, {
            use crate::domt::H_WST;
            vec![
                Op::La {
                    rd: crate::encode::T0,
                    addr: Addr::DomT,
                },
                Op::Li {
                    rd: crate::encode::T1,
                    imm: 1,
                },
                Op::Sw {
                    rs2: crate::encode::T1,
                    rs1: crate::encode::T0,
                    off: H_WST,
                },
            ]
        });
        let s = run_module(&spec, &m, 0x8020_0000).unwrap();
        let stride = s.disp_sel.4;
        let px = |x: u32, y: u32| -> u32 {
            let off = (y * stride + x * 4) as usize;
            u32::from_le_bytes(s.scan_fb[off..off + 4].try_into().unwrap())
        };
        assert_eq!(
            px(4, 4),
            0xff00_0000 | (0x10ff_30ff >> 8),
            "state 1 ground\n{}",
            s.console
        );
        assert!(
            s.console.contains("WEBDL 0000000000000001\n"),
            "{}",
            s.console
        );
    }

    /// `DomtKey` menu-nav: a `KEY_RIGHT` press drained through `INP_KQ` moves
    /// `__dom+H_WST` forward one `__web_dl` state (BIOS-protocol nav — the
    /// shipped cell wires its tabs `listener=0`, and `menu_for_key` maps
    /// Left/Right/Home/End). The key is queued and `DomtKey` drained ahead of
    /// the boot `WebPaint`, so `H_WST` 0→1 paints state 1's colour — the guest
    /// half of `guest_cell_key("ArrowRight")`, driven by real input.
    #[test]
    fn dl_paint_nav_key_switches_state_via_domt_key() {
        let spec = web_guest_spec();
        let mut m = analyze::kstart(&spec);
        let s0 = {
            let mut v = dl_fill(0, 0, 16, 8, 0x3020_10ff);
            v.extend(dl_words(&[0]));
            v
        };
        let s1 = {
            let mut v = dl_fill(0, 0, 16, 8, 0x10ff_30ff);
            v.extend(dl_words(&[0]));
            v
        };
        m.web_dl = web_dl(16, 8, &[("main", s0), ("cpu", s1)], &[], &[], &[], &[], &[]);
        // Queue a KEY_RIGHT press into INP_KQ and drain it through DomtKey
        // ahead of the boot WebPaint — the real input path, not an H_WST poke.
        seed_after_domt_boot(&mut m, {
            use crate::encode::{RA, T0, T1, X0};
            use crate::vio::{DOMT_SEEN_OFF, INP_KQ_HEAD, INP_KQ_OFF, VIO_KEY_RIGHT};
            vec![
                Op::La {
                    rd: T0,
                    addr: Addr::VioBss,
                },
                Op::Li {
                    rd: T1,
                    imm: (VIO_KEY_RIGHT << 8) | 1,
                },
                Op::Sw {
                    rs2: T1,
                    rs1: T0,
                    off: INP_KQ_OFF,
                },
                Op::Li { rd: T1, imm: 1 },
                Op::Sw {
                    rs2: T1,
                    rs1: T0,
                    off: INP_KQ_HEAD,
                },
                Op::Sw {
                    rs2: X0,
                    rs1: T0,
                    off: DOMT_SEEN_OFF,
                },
                Op::Jal {
                    rd: RA,
                    to: "DomtKey".into(),
                },
            ]
        });
        let s = run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(
            s.console.contains("WEBDL 0000000000000001\n"),
            "KEY_RIGHT nav repainted state 1: {}",
            s.console
        );
        let stride = s.disp_sel.4;
        let px = |x: u32, y: u32| -> u32 {
            let off = (y * stride + x * 4) as usize;
            u32::from_le_bytes(s.scan_fb[off..off + 4].try_into().unwrap())
        };
        assert_eq!(
            px(4, 4),
            0xff00_0000 | (0x10ff_30ff >> 8),
            "KEY_RIGHT nav left state 1 painted\n{}",
            s.console
        );
        assert!(!s.console.contains("TRAP-"), "{}", s.console);
    }

    /// `TREF`: the live `__dom` text wins over the packed fallback. The seed
    /// binds node 1's `__dom_id` slot to "s1" and points its text at "LIVE"
    /// in `__dom_str`; the pack's fallback is the single char "P". If the
    /// lookup works the glyph stamp repeats 4×; on fallback, once.
    #[test]
    fn dl_paint_tref_renders_live_dom_text() {
        let spec = web_guest_spec();
        let mut m = analyze::kstart(&spec);
        let mut stream = dl_fill(0, 0, 16, 8, 0x3020_10ff);
        stream.extend(dl_words(&[crate::dlp::DLOP_TREF as u32, 0]));
        stream.extend(dl_words(&[0]));
        // strings: id "s1" @0 (2B), txt "P" @2 (1B).
        let strings = b"s1P";
        // tref {clip 0,0,16,8; pen_x 1; base_y 6; max_w 60; size_idx 0;
        //        fg white-rgba; bg navy X8R8; id 0,2; txt 2,1}
        let tref = [
            0,
            0,
            16,
            8,
            1,
            6,
            60,
            0,
            0xffff_ffffu32,
            0xff00_0000 | (0x3020_10ff >> 8),
            0,
            2,
            2,
            1,
        ];
        // glyphs: every LIVE/PACKED char → the shared 2x2 blob, adv 4px.
        let glyphs: Vec<[u32; 6]> = [b'P', b'L', b'I', b'V', b'E']
            .iter()
            .map(|c| [*c as u32, 0, 0, 0, 0, 4 * 64])
            .collect();
        m.web_dl = web_dl(
            16,
            8,
            &[("main", stream)],
            &[tref],
            &[128],
            &glyphs,
            &[(2, 2, vec![255, 255, 255, 255])],
            strings,
        );
        {
            use crate::domt::{DOMT_HDR, DOMT_NODE, N_TLEN, N_TPTR};
            use crate::encode::{T0, T1};
            let mut ops = vec![
                // __dom_id[1] = [len=2]['s','1']
                Op::La {
                    rd: T0,
                    addr: Addr::DomId,
                },
                Op::Addi {
                    rd: T0,
                    rs: T0,
                    imm: 32,
                },
                Op::Li { rd: T1, imm: 2 },
                Op::Sw {
                    rs2: T1,
                    rs1: T0,
                    off: 0,
                },
                Op::Li {
                    rd: T1,
                    imm: i64::from(b's'),
                },
                Op::Sb {
                    rs2: T1,
                    rs1: T0,
                    off: 4,
                },
                Op::Li {
                    rd: T1,
                    imm: i64::from(b'1'),
                },
                Op::Sb {
                    rs2: T1,
                    rs1: T0,
                    off: 5,
                },
                // node[1]: N_TPTR=100 (__dom_str off), N_TLEN=4
                Op::La {
                    rd: T0,
                    addr: Addr::DomT,
                },
                Op::Addi {
                    rd: T0,
                    rs: T0,
                    imm: (DOMT_HDR + DOMT_NODE) as i32,
                },
                Op::Li { rd: T1, imm: 100 },
                Op::Sw {
                    rs2: T1,
                    rs1: T0,
                    off: N_TPTR,
                },
                Op::Li { rd: T1, imm: 4 },
                Op::Sw {
                    rs2: T1,
                    rs1: T0,
                    off: N_TLEN,
                },
                // __dom_str+100 = "LIVE"
                Op::La {
                    rd: T0,
                    addr: Addr::DomS,
                },
            ];
            for (i, b) in b"LIVE".iter().enumerate() {
                ops.push(Op::Li {
                    rd: T1,
                    imm: i64::from(*b),
                });
                ops.push(Op::Sb {
                    rs2: T1,
                    rs1: T0,
                    off: 100 + i as i32,
                });
            }
            seed_after_domt_boot(&mut m, ops);
        }
        let s = run_module(&spec, &m, 0x8020_0000).unwrap();
        let stride = s.disp_sel.4;
        let px = |x: u32, y: u32| -> u32 {
            let off = (y * stride + x * 4) as usize;
            u32::from_le_bytes(s.scan_fb[off..off + 4].try_into().unwrap())
        };
        let white = 0xffff_ffffu32;
        // base_y 6, my 0, bh 2 → rows 5..6; pens at x = 1,5,9,13 (4px adv).
        for (i, x) in [1u32, 5, 9, 13].iter().enumerate() {
            assert_eq!(px(*x, 5), white, "LIVE glyph {i} row5");
            assert_eq!(px(*x + 1, 6), white, "LIVE glyph {i} row6");
        }
        assert_eq!(px(15, 7), 0xff00_0000 | (0x3020_10ff >> 8));
    }

    /// The packed-text fallback: no `__dom` seed → `DlFindId` misses → the
    /// guest draws the packed "P" — one glyph stamp at the pen, the rest of
    /// the clear rect back to the tref bg.
    #[test]
    fn dl_paint_tref_packed_text_fallback() {
        let spec = web_guest_spec();
        let mut m = analyze::kstart(&spec);
        let mut stream = dl_fill(0, 0, 16, 8, 0x3020_10ff);
        stream.extend(dl_words(&[crate::dlp::DLOP_TREF as u32, 0]));
        stream.extend(dl_words(&[0]));
        let strings = b"s1P";
        let tref = [
            0,
            0,
            16,
            8,
            1,
            6,
            60,
            0,
            0xffff_ffffu32,
            0xff00_0000 | (0x3020_10ff >> 8),
            0,
            2,
            2,
            1,
        ];
        let glyphs: Vec<[u32; 6]> = [b'P', b'L', b'I', b'V', b'E']
            .iter()
            .map(|c| [*c as u32, 0, 0, 0, 0, 4 * 64])
            .collect();
        m.web_dl = web_dl(
            16,
            8,
            &[("main", stream)],
            &[tref],
            &[128],
            &glyphs,
            &[(2, 2, vec![255, 255, 255, 255])],
            strings,
        );
        let s = run_module(&spec, &m, 0x8020_0000).unwrap();
        let stride = s.disp_sel.4;
        let px = |x: u32, y: u32| -> u32 {
            let off = (y * stride + x * 4) as usize;
            u32::from_le_bytes(s.scan_fb[off..off + 4].try_into().unwrap())
        };
        assert_eq!(px(1, 5), 0xffff_ffff, "packed 'P' stamp");
        assert_eq!(px(2, 6), 0xffff_ffff, "packed 'P' stamp");
        // 'P' is one char — x=5's slot stays the tref bg (navy).
        assert_eq!(px(5, 5), 0xff00_0000 | (0x3020_10ff >> 8), "no 2nd glyph");
        assert!(s.console.contains("WEBDL "), "{}", s.console);
    }

    /// Absent/malformed `__web_dl` fails closed into `WebBlit`: install a
    /// pixel pack plus a garbage-word list — the WEBPK decode runs, not
    /// WEBDL, and the pixel pack reaches the surface.
    #[test]
    fn dl_paint_invalid_falls_back_to_webpk() {
        let spec = web_guest_spec();
        let mut m = analyze::kstart(&spec);
        m.web_dl = b"G6XXgarbage-list".to_vec();
        m.web_pk = web_pk(4, 2, 5, &[4, 0xff11_2233, 0x8000_0004, 1, 2, 3, 4]);
        let s = run_module(&spec, &m, 0x8020_0000).unwrap();
        assert_eq!(s.console.matches("WEBDL ").count(), 0, "{}", s.console);
        assert_eq!(s.console.matches("WEBPK ").count(), 1, "{}", s.console);
        let stride = s.disp_sel.4;
        let px = |x: u32, y: u32| -> u32 {
            let off = (y * stride + x * 4) as usize;
            u32::from_le_bytes(s.scan_fb[off..off + 4].try_into().unwrap())
        };
        assert_eq!(px(0, 0), 0xff11_2233, "web_pk run decoded");
        assert_eq!(px(0, 1), 1, "web_pk literal decoded");
    }

    #[test]
    fn vio_paint_scale_expands_to_proxy_high_res() {
        // Display-proxy live (1920×1080, dpi mode → scale 2) on the **VGA
        // surface**: the scanout resource is the high-res surface and
        // `FbExpand` paints the 4bpp plane into a centered 1280×960 window —
        // the `Proxy::to_ppm` semantics (ox=(1920-1280)/2=320,
        // oy=(1080-960)/2=60).
        //
        // `proxy.surface:"vga"` is explicit because this board's output is
        // GPU-class, whose *default* is now the 1:1 native surface — that is
        // the whole point of the split, and the upscale path must still be
        // provable on demand rather than quietly becoming unreachable.
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"uncore":{"plic":true},
"kernel":{"gr":{"enable":true,"w":640,"h":480,"colors":16,"backend":"virtio-gpu"},
"proxy":{"enable":true,"link":"hdmi","dpi":192,"detected_hz":120,
         "high_w":1920,"high_h":1080,"scale_mode":"dpi","gl":true,"surface":"vga"}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        assert_eq!(spec.default_surface(), g6b_spec::Surface::Vga);
        let m = analyze::kstart(&spec);
        let s = run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(s.console.contains("VIRTIO-SCAN"), "{}", s.console);
        // `gl:true` → `VioVirgl` ran after the paint: SET_SCANOUT(RES_RT)
        // moved the console onto the GPU surface, clearing the res-1 binding.
        assert!(s.virgl_scanout && !s.vio_scanout);
        assert_eq!((s.vio_fb_w, s.vio_fb_h), (1920, 1080));
        assert!(s.console.contains("VIRTIO-PAINT"), "{}", s.console);
        // Sampled scale-parity: dst(x,y) in the content window equals the
        // palette colour of src(x/2, y/2); letterbox rows/cols stay black.
        let pal_px = |lx: u32, ly: u32| -> u32 {
            let hdr = u32::from_le_bytes(s.gr_frame[40..44].try_into().unwrap()) as usize;
            let b = s.gr_frame[hdr + (ly * 320 + lx / 2) as usize];
            const PAL: [u32; 16] = [
                0x0000_0000,
                0x0000_00AA,
                0x0000_AA00,
                0x0000_AAAA,
                0x00AA_0000,
                0x00AA_00AA,
                0x00AA_5500,
                0x00AA_AAAA,
                0x0055_5555,
                0x0055_55FF,
                0x0055_FF55,
                0x0055_FFFF,
                0x00FF_5555,
                0x00FF_55FF,
                0x00FF_FF55,
                0x00FF_FFFF,
            ];
            PAL[if lx % 2 == 0 {
                (b >> 4) as usize
            } else {
                (b & 0xf) as usize
            }]
        };
        let (ox, oy, sc) = (320u32, 60u32, 2u32);
        let dp = |x: u32, y: u32| -> u32 {
            u32::from_le_bytes(
                s.vio_fb[(y * 1920 + x) as usize * 4..][..4]
                    .try_into()
                    .unwrap(),
            )
        };
        for y in (oy..oy + 480 * sc).step_by(47) {
            for x in (ox..ox + 640 * sc).step_by(53) {
                assert_eq!(
                    dp(x, y),
                    pal_px((x - ox) / sc, (y - oy) / sc),
                    "dst({x},{y})"
                );
            }
        }
        // Centered letterbox: left of ox and right of ox+used_w stay black
        // below the VioScan top band (the band fills rows 0..63 across the
        // full width before FbExpand runs).
        for y in (oy.max(64)..1080).step_by(61) {
            assert_eq!(dp(10, y), 0, "left letterbox y={y}");
            assert_eq!(dp(1900, y), 0, "right letterbox y={y}");
        }
        for x in (0..1920).step_by(97) {
            assert_eq!(dp(x, 1070), 0, "bottom letterbox x={x}");
        }
    }

    fn p0_command_machine(xlen: u32, buffered: bool, index: u16) -> TaskMachine {
        use crate::encode::{A0, A1, A2, A3, RA};
        let mut spec = BoardSpec::from_json_str(r#"{"schema_version":1}"#).unwrap();
        spec.isa.xlen = xlen;
        spec.uncore.plic = false;
        let mut node = if buffered {
            crate::vio::cmdbuf_node(&spec)
        } else {
            crate::vio::cmd_node(&spec)
        };
        for op in &mut node.ops {
            if let Op::La {
                addr: addr @ Addr::VioBss,
                ..
            } = op
            {
                *addr = Addr::Abs(0x6000);
            }
        }
        let module = Module {
            nodes: vec![
                node,
                Node {
                    purpose: Purpose::Virtio,
                    ops: vec![Op::Label("p0_return".into()), Op::Wfi],
                },
            ],
            ..Default::default()
        };
        let mut machine = TaskMachine::new(xlen, &module);
        machine.csr = Csr {
            vio_gpu: true,
            vio_gl: true,
            vio_drv_feats: 1,
            vio_ready: true,
            vio_qnum: 8,
            vio_qdesc: 0x6000,
            vio_qavail: 0x6080,
            vio_qused: 0x60c0,
            vio_used_idx: index,
            virgl_ctx: 2,
            ..Default::default()
        };
        machine.x[RA as usize] = task_label(&module, "p0_return");
        machine.x[A0 as usize] = 32;
        machine.x[A1 as usize] = if buffered { 24 } else { 40 };
        machine.x[A2 as usize] = 0x9000;
        machine.x[A3 as usize] = 4;
        machine.put(0x6080, &(u32::from(index) << 16).to_le_bytes());
        machine.put(0x60c0, &(u32::from(index) << 16).to_le_bytes());
        machine.put(
            0x6000 + crate::vio::VIO_DEV_OFF as u64,
            &(crate::encode::VIO_MMIO_BASE as u32).to_le_bytes(),
        );
        let mut request = vec![0u8; 32];
        request[0..4].copy_from_slice(&(if buffered { 0x0207u32 } else { 0x0108 }).to_le_bytes());
        if buffered {
            request[4..8].copy_from_slice(&1u32.to_le_bytes());
            request[8..16].copy_from_slice(&0x1234_5678_8765_4321u64.to_le_bytes());
            request[16..20].copy_from_slice(&1u32.to_le_bytes());
            request[24..28].copy_from_slice(&4u32.to_le_bytes());
        }
        machine.put(0x6120, &request);
        machine
    }

    #[test]
    fn p0_generated_submitters_handle_u16_index_wrap() {
        for xlen in [32, 64] {
            for buffered in [false, true] {
                for index in [0x7fff, 0x8000, 0xffff] {
                    let mut machine = p0_command_machine(xlen, buffered, index);
                    let halt = (0..2000).find_map(|_| machine.tick());
                    assert!(
                        matches!(halt, Some(Halt::Wfi)),
                        "xlen={xlen} buffered={buffered} index={index:#x}"
                    );
                    assert_eq!(
                        machine.reg(crate::encode::A0),
                        if buffered { 0x1100 } else { 0x1102 }
                    );
                    assert_eq!(machine.csr.vio_used_idx, index.wrapping_add(1));
                }
            }
        }
    }

    #[test]
    fn p0_generated_submitter_rejects_mismatched_fence() {
        for xlen in [32, 64] {
            let mut machine = p0_command_machine(xlen, true, 0);
            let mut tampered = false;
            let mut halt = None;
            for _ in 0..2000 {
                halt = machine.tick();
                if !tampered && machine.csr.vio_irqs != 0 {
                    machine.put(0x618c, &0xdead_beefu32.to_le_bytes());
                    tampered = true;
                }
                if halt.is_some() {
                    break;
                }
            }
            assert!(tampered && matches!(halt, Some(Halt::Wfi)));
            assert_eq!(machine.reg(crate::encode::A0), 0);
        }
    }

    #[test]
    fn p0_virgl_client_stops_at_first_failed_response() {
        use crate::encode::{A0, RA, S11, SP, X0};
        for xlen in [32, 64] {
            let mut spec = BoardSpec::from_json_str(r#"{"schema_version":1}"#).unwrap();
            spec.isa.xlen = xlen;
            let mut virgl = crate::vio::virgl_node(&spec);
            for op in &mut virgl.ops {
                if let Op::La { addr, .. } = op {
                    *addr = Addr::Abs(match addr {
                        Addr::VioBss => 0x6000,
                        Addr::VirglReq => 0x8000,
                        Addr::VirglCmd => 0xa000,
                        Addr::VirglOut => 0xc000,
                        other => panic!("unexpected address {other:?}"),
                    });
                }
            }
            let mut nodes = vec![
                Node {
                    purpose: Purpose::Virtio,
                    ops: vec![
                        Op::Li {
                            rd: SP,
                            imm: 0x10000,
                        },
                        Op::Jal {
                            rd: RA,
                            to: "VioVirgl".into(),
                        },
                        Op::Wfi,
                    ],
                },
                virgl,
            ];
            for name in ["VioCmd", "VioCmdBuf"] {
                nodes.push(Node {
                    purpose: Purpose::Virtio,
                    ops: vec![
                        Op::Label(name.into()),
                        Op::Addi {
                            rd: S11,
                            rs: S11,
                            imm: 1,
                        },
                        Op::Li {
                            rd: A0,
                            imm: 0x1205,
                        },
                        Op::Jalr {
                            rd: X0,
                            rs: RA,
                            imm: 0,
                        },
                    ],
                });
            }
            let module = Module {
                nodes,
                ..Default::default()
            };
            let mut machine = TaskMachine::new(xlen, &module);
            machine.put(0x8000, &crate::virgl::reqtab(640, 480));
            let halt = (0..20000).find_map(|_| machine.tick());
            assert!(matches!(halt, Some(Halt::Wfi)));
            assert_eq!(
                machine.reg(S11),
                1,
                "failed capability query must stop the sequence"
            );
            assert!(!machine.console.contains("VIRTIO-VIRGL "));
            assert!(machine.console.contains("VIRTIO-VIRGL-FAIL"));
        }
    }

    fn p0_control_chain(request: &[u8], response_len: u32) -> (Csr, Vec<u8>, u64) {
        let mut ram = vec![0u8; 4096];
        let desc = TASK_BASE + 0x100;
        let req = TASK_BASE + 0x400;
        let rsp = TASK_BASE + 0x800;
        ram[0x400..0x400 + request.len()].copy_from_slice(request);
        ram[0x800..0xc00].fill(0xa5);
        for (i, value) in [
            req as u32,
            0,
            request.len() as u32,
            1 | (1 << 16),
            rsp as u32,
            0,
            response_len,
            2,
        ]
        .into_iter()
        .enumerate()
        {
            assert!(store_u32(&mut ram, TASK_BASE, desc + i as u64 * 4, value));
        }
        (
            Csr {
                vio_qdesc: desc,
                vio_qnum: 8,
                vio_gl: true,
                vio_drv_feats: 1,
                ..Default::default()
            },
            ram,
            rsp,
        )
    }

    #[test]
    fn p0_response_echoes_full_fence_and_respects_descriptor_bounds() {
        let mut request = vec![0u8; 96];
        request[0..4].copy_from_slice(&0x0200u32.to_le_bytes());
        request[4..8].copy_from_slice(&1u32.to_le_bytes());
        request[8..16].copy_from_slice(&0xfedc_ba98_7654_3210u64.to_le_bytes());
        request[16..20].copy_from_slice(&1u32.to_le_bytes());
        let (mut csr, mut ram, rsp) = p0_control_chain(&request, 24);
        assert_eq!(vio_exec_chain(&mut csr, &mut ram, TASK_BASE, 0), 24);
        assert_eq!(load_u32(&ram, TASK_BASE, rsp), Some(0x1100));
        assert_eq!(load_u32(&ram, TASK_BASE, rsp + 4), Some(1));
        assert_eq!(
            load_u64(&ram, TASK_BASE, rsp + 8),
            Some(0xfedc_ba98_7654_3210)
        );
        assert!(ram[0x818..0xc00].iter().all(|b| *b == 0xa5));
    }

    #[test]
    fn p0_invalid_response_or_descriptor_loop_has_no_command_side_effects() {
        let mut request = vec![0u8; 96];
        request[0..4].copy_from_slice(&0x0200u32.to_le_bytes());
        request[16..20].copy_from_slice(&1u32.to_le_bytes());
        let (mut csr, mut ram, _) = p0_control_chain(&request, 8);
        assert_eq!(vio_exec_chain(&mut csr, &mut ram, TASK_BASE, 0), 0);
        assert_eq!(csr.virgl_ctxs, 0);
        assert!(ram[0x800..0xc00].iter().all(|b| *b == 0xa5));
        let (mut csr, mut ram, _) = p0_control_chain(&request, 24);
        store_u32(&mut ram, TASK_BASE, csr.vio_qdesc + 12, 1);
        assert_eq!(vio_exec_chain(&mut csr, &mut ram, TASK_BASE, 0), 0);
        assert_eq!(csr.virgl_ctxs, 0);
    }

    #[test]
    fn p0_short_capset_response_cannot_overwrite_the_following_buffer() {
        let mut request = vec![0u8; 32];
        request[0..4].copy_from_slice(&0x0109u32.to_le_bytes());
        request[24..28].copy_from_slice(&1u32.to_le_bytes());
        request[28..32].copy_from_slice(&1u32.to_le_bytes());
        let (mut csr, mut ram, rsp) = p0_control_chain(&request, 24);
        assert_eq!(vio_exec_chain(&mut csr, &mut ram, TASK_BASE, 0), 24);
        assert_eq!(load_u32(&ram, TASK_BASE, rsp), Some(0x1205));
        assert!(ram[0x818..0xc00].iter().all(|b| *b == 0xa5));
    }

    #[test]
    fn p0_submit_uses_complete_out_chain_and_rejects_truncated_size() {
        let mut packet = vec![0u8; 36];
        packet[0..4].copy_from_slice(&0x0207u32.to_le_bytes());
        packet[16..20].copy_from_slice(&1u32.to_le_bytes());
        packet[24..28].copy_from_slice(&4u32.to_le_bytes());
        for segments in [
            vec![(0, 36)],
            vec![(0, 32), (32, 4)],
            vec![(0, 12), (12, 20), (32, 4)],
        ] {
            let mut csr = Csr {
                vio_gl: true,
                vio_drv_feats: 1,
                virgl_ctx: 2,
                ..Default::default()
            };
            assert_eq!(vio_cmd(&mut csr, &mut packet, 0, &segments, 0x0207), 0x1100);
            assert_eq!(csr.virgl_submits, 1);
        }
        packet[24..28].copy_from_slice(&8u32.to_le_bytes());
        let mut csr = Csr {
            vio_gl: true,
            vio_drv_feats: 1,
            virgl_ctx: 2,
            ..Default::default()
        };
        assert_eq!(
            vio_cmd(&mut csr, &mut packet, 0, &[(0, 32), (32, 4)], 0x0207),
            0x1205
        );
        assert_eq!(csr.virgl_submits, 0);
    }

    #[test]
    fn p0_capset_model_checks_id_and_version_without_prior_enumeration() {
        let mut csr = Csr {
            vio_gl: true,
            vio_drv_feats: crate::encode::VIO_GPU_F_VIRGL,
            ..Default::default()
        };
        let mut ram = vec![0u8; 64];
        for (id, version, expected) in [
            (1u32, 0u32, crate::encode::VIO_GPU_RESP_OK_CAPSET),
            (1, 1, crate::encode::VIO_GPU_RESP_OK_CAPSET),
            (1, 2, crate::encode::VIO_GPU_RESP_ERR_INVALID_PARAMETER),
            (2, 1, crate::encode::VIO_GPU_RESP_ERR_INVALID_PARAMETER),
        ] {
            ram[24..28].copy_from_slice(&id.to_le_bytes());
            ram[28..32].copy_from_slice(&version.to_le_bytes());
            assert_eq!(
                vio_cmd(
                    &mut csr,
                    &mut ram,
                    0,
                    &[(0, 32)],
                    crate::encode::VIO_GPU_GET_CAPSET
                ),
                expected
            );
        }
        ram[24..28].copy_from_slice(&0u32.to_le_bytes());
        assert_eq!(
            vio_cmd(
                &mut csr,
                &mut ram,
                0,
                &[(0, 32)],
                crate::encode::VIO_GPU_GET_CAPSET_INFO
            ),
            crate::encode::VIO_GPU_RESP_OK_CAPSET_INFO
        );
        assert_eq!(
            (
                csr.virgl_capset_id,
                csr.virgl_capset_ver,
                csr.virgl_capset_size
            ),
            (1, 1, 308)
        );
        ram[24..28].copy_from_slice(&1u32.to_le_bytes());
        vio_cmd(
            &mut csr,
            &mut ram,
            0,
            &[(0, 32)],
            crate::encode::VIO_GPU_GET_CAPSET_INFO,
        );
        assert_eq!(
            (
                csr.virgl_capset_id,
                csr.virgl_capset_ver,
                csr.virgl_capset_size
            ),
            (0, 0, 0)
        );
    }

    #[test]
    fn virgl_submit_composites_scanout_frame() {
        // M4+M5: a `virtio-gpu-gl-device` board (`proxy.gl`). `VioInit`
        // accepts `VIRTIO_GPU_F_VIRGL`; `VioVirgl` runs **after** `VioPaint`
        // and walks `__virgl_req` (CAPSET_INFO → CAPSET → CTX_CREATE →
        // CREATE_3D×2 → CTX_ATTACH×3 → SUBMIT_3D → SET_SCANOUT → FLUSH).
        // The execbuffer's sampler view binds the 2D scanout resource
        // (`RES_SCAN` = 1), so `virgl_exec` composites the *committed frame*
        // (`vio_fb` — what `VioPaint` uploaded from `__scan_fb`) into
        // `virgl_fb`, then the console moves onto `RES_RT`. Real-QEMU raster
        // stays gated on a DRM render node — the modelled path is verified.
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"uncore":{"plic":true},
"kernel":{"gr":{"enable":true,"w":640,"h":480,"colors":16,"backend":"virtio-gpu"},
"proxy":{"enable":true,"link":"hdmi","gl":true,"high_w":640,"high_h":480,"scale_mode":"fit"}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let m = analyze::kstart(&spec);
        assert!(
            !m.virgl_cmd.is_empty() && !m.virgl_req.is_empty(),
            "proxy.gl board emits __virgl_cmd + __virgl_req"
        );
        let s = run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(s.console.contains("VIRTIO-VIRGL"), "{}", s.console);
        assert!(s.console.contains("VIRTIO-SCAN"), "{}", s.console);
        // CAPSET negotiated → CTX_CREATE → SUBMIT_3D ran.
        assert_ne!(s.virgl_capset, 0, "CAPSET_INFO/CAPSET negotiated");
        assert!(s.virgl_ctxs >= 1, "CTX_CREATE ran: {}", s.console);
        assert!(s.virgl_submits >= 1, "SUBMIT_3D accepted: {}", s.console);
        assert!(s.virgl_draws >= 1, "DRAW_VBO reached a bound surface");
        assert_eq!(s.virgl_px, 640 * 480);
        // The composite contract: `virgl_fb` is the scanout surface resampled
        // across the quad — same 640×480 geometry → an identity blit of the
        // texture as sampled at submit time (`virgl_src`). `vio_fb` itself is
        // a *moving* surface (a timer-tick `Ui → VioPaint` repaint can rewrite
        // it after the composite), so the gate compares against the snapshot.
        assert_eq!(
            s.virgl_src.len(),
            s.vio_fb.len(),
            "composite source is the scanout surface (same geometry)"
        );
        assert!(
            s.virgl_src.iter().any(|&b| b != 0),
            "the composite sampled a committed frame, not a blank surface"
        );
        assert_eq!(
            s.virgl_fb, s.virgl_src,
            "virgl composite reproduces the scanout frame it sampled"
        );
        // The present moved the console onto RES_RT.
        assert!(s.virgl_scanout, "SET_SCANOUT(RES_RT) latched");
        assert!(!s.vio_scanout, "scanout0 no longer bound to res 1");
        assert!(s.virgl_flushes >= 1, "RESOURCE_FLUSH(RES_RT) presented");
        // M4b: `__virgl_out` readback is byte-identical to the device surface.
        assert_eq!(
            s.virgl_out.len(),
            (640 * 480 * 4) as usize,
            "__virgl_out holds the full composite in guest RAM"
        );
        assert_eq!(
            s.virgl_out, s.virgl_fb,
            "guest __virgl_out == device virgl_fb (readback is exact)"
        );
    }

    #[test]
    fn virgl_exec_composites_scanout_texture() {
        const PA: u32 = 0x1122_3344;
        const PB: u32 = 0xAABB_CCDD;
        // Drive `virgl_exec` directly on the emitted execbuffer: the sampler
        // view binds `RES_SCAN` (1), so the draw composites `vio_fb` — the
        // committed scanout frame — into `virgl_fb`. Seed `vio_fb` with a
        // 2×2-block checkerboard; same geometry → identity blit.
        let w = 8u32;
        let h = 8u32;
        let mut fb = vec![0u8; (w * h * 4) as usize];
        for y in 0..h {
            for x in 0..w {
                let c = if (x / 2 + y / 2) % 2 == 0 { PA } else { PB };
                fb[((y * w + x) * 4) as usize..][..4].copy_from_slice(&c.to_le_bytes());
            }
        }
        let mut csr = Csr {
            vio_gl: true,
            vio_drv_feats: crate::encode::VIO_GPU_F_VIRGL,
            vio_res_id: crate::virgl::RES_SCAN,
            vio_res_w: w,
            vio_res_h: h,
            vio_fb: fb.clone(),
            virgl_rt: crate::virgl::RES_RT,
            virgl_rt_w: w,
            virgl_rt_h: h,
            virgl_fb: vec![0; (w * h * 4) as usize],
            virgl_ctx: 1 << crate::virgl::CTX_ID,
            virgl_res: (1 << crate::virgl::RES_VBO)
                | (1 << crate::virgl::RES_RT)
                | (1 << crate::virgl::RES_SCAN),
            ..Default::default()
        };
        let buf = crate::virgl::execbuf(w, h);
        let base = 0x8000_0000u64;
        let mut ram = vec![0u8; 0x1000];
        let baddr = base + 0x800;
        ram[0x800..0x800 + buf.len()].copy_from_slice(&buf);
        assert!(virgl_exec(&mut csr, &ram, base, baddr, buf.len() as u64));
        assert!(csr.virgl_draws >= 1, "draw recognized");
        assert_eq!(csr.virgl_px, w * h, "fullscreen quad rastered");
        // Same geometry → the composite is an exact copy of the scanout.
        assert_eq!(csr.virgl_fb, fb, "virgl_fb == vio_fb (composite blit)");
        let px = |x: usize, y: usize| {
            u32::from_le_bytes(csr.virgl_fb[(y * 8 + x) * 4..][..4].try_into().unwrap())
        };
        assert_eq!(px(0, 0), PA);
        assert_eq!(px(2, 0), PB);
        assert_eq!(px(0, 2), PB);
        // Malformed stream — a header whose body-dword count overruns the
        // buffer — must fail closed (virgl_exec returns false → INVALID_PARAM).
        let mut bad = [0u8; 4];
        bad.copy_from_slice(
            &crate::encode::virgl_cmd0(crate::encode::VIRGL_CCMD_DRAW_VBO, 0, 0xffff).to_le_bytes(),
        );
        let mut csr2 = Csr {
            virgl_fb: vec![0; (w * h * 4) as usize],
            ..Default::default()
        };
        let mut ram2 = vec![0u8; 0x1000];
        ram2[0x800..0x804].copy_from_slice(&bad);
        assert!(!virgl_exec(&mut csr2, &ram2, base, baddr, bad.len() as u64));
    }

    #[test]
    fn virgl_transfer_requires_attached_backing() {
        // M4b readback guards: TRANSFER_FROM_HOST_3D on a resource with no
        // attached guest backing must fail (no `virgl_backing` entry), and
        // RESOURCE_ATTACH_BACKING on an unknown resource must fail — the
        // readback can't DMA to an address the guest never attached.
        let (w, h) = (8u32, 8u32);
        let base = 0x8000_0000u64;
        let mut ram = vec![0u8; 0x1000];
        let req = base + 0x800;
        let w32 = |ram: &mut [u8], o: u64, v: u32| {
            let i = (req - base + o) as usize;
            ram[i..i + 4].copy_from_slice(&v.to_le_bytes());
        };
        let mut csr = Csr {
            vio_gl: true,
            vio_drv_feats: crate::encode::VIO_GPU_F_VIRGL,
            virgl_rt: crate::virgl::RES_RT,
            virgl_rt_w: w,
            virgl_rt_h: h,
            virgl_fb: vec![0x11; (w * h * 4) as usize],
            virgl_ctx: 1 << crate::virgl::CTX_ID,
            ..Default::default()
        };
        // TRANSFER_FROM_HOST_3D with RES_RT valid but no backing attached.
        w32(&mut ram, 0, crate::encode::VIO_GPU_TRANSFER_FROM_HOST_3D);
        w32(&mut ram, 16, crate::virgl::CTX_ID);
        w32(&mut ram, 36, w);
        w32(&mut ram, 40, h);
        w32(&mut ram, 44, 1);
        w32(&mut ram, 56, crate::virgl::RES_RT);
        let r = vio_cmd(
            &mut csr,
            &mut ram,
            base,
            &[(req, 72)],
            crate::encode::VIO_GPU_TRANSFER_FROM_HOST_3D,
        );
        assert_eq!(
            r,
            crate::encode::VIO_GPU_RESP_ERR_INVALID_RESOURCE_ID,
            "transfer on unbacked RES_RT is refused"
        );
        // ATTACH_BACKING on a resource id that is neither the 2D scanout nor
        // the 3D RT must fail (catches a misdirected attach).
        w32(&mut ram, 0, crate::encode::VIO_GPU_RESOURCE_ATTACH_BACKING);
        w32(&mut ram, 24, 999);
        w32(&mut ram, 28, 1);
        let i = (req - base + 32) as usize;
        ram[i..i + 8].copy_from_slice(&(base + 0x900).to_le_bytes());
        w32(&mut ram, 40, 64);
        let r = vio_cmd(
            &mut csr,
            &mut ram,
            base,
            &[(req, 48)],
            crate::encode::VIO_GPU_RESOURCE_ATTACH_BACKING,
        );
        assert_eq!(
            r,
            crate::encode::VIO_GPU_RESP_ERR_INVALID_RESOURCE_ID,
            "attach on unknown resource is refused"
        );
    }

    #[test]
    fn virgl_texture_byte_kill_test() {
        // Kill test: rasterizing the quad against two textures that differ by
        // one texel must change the surface — proves the draw *really* samples
        // the guest-uploaded texture, not a hard-coded colour.
        let (w, h) = (8u32, 8u32);
        let run = |tex: Vec<u32>| -> Vec<u8> {
            let mut csr = Csr {
                virgl_rt_w: w,
                virgl_rt_h: h,
                virgl_fb: vec![0; (w * h * 4) as usize],
                ..Default::default()
            };
            virgl_raster_quad(&mut csr, None, Some(&(4, 4, tex)));
            csr.virgl_fb
        };
        let good = run(vec![0x1122_3344; 16]);
        let mut tex2 = vec![0x1122_3344; 16];
        tex2[0] = 0xAABB_CCDD; // flip texel (0,0)
        let killed = run(tex2);
        assert_ne!(
            good, killed,
            "a texture texel change must reach the surface"
        );
        // And the changed region is exactly where texel(0,0) maps (top-left).
        let first_diff = good
            .iter()
            .zip(&killed)
            .position(|(a, b)| a != b)
            .expect("differing byte");
        assert_eq!(first_diff / 4, 0, "texel(0,0) lands at surface pixel 0");
    }

    #[test]
    fn gpu_surface_places_the_plane_1to1_instead_of_magnifying_it() {
        // Same board, but on the **default** surface for a GPU-class output.
        // `FbExpandSel` must pick `FbExpand1`, so the 640×480 plane lands at
        // scale 1 centred at ((1920-640)/2, (1080-480)/2) = (640, 300) rather
        // than being blown up ×2. This is the regression that fails if the
        // low-res plane ever goes back to being magnified onto a GPU output.
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"uncore":{"plic":true},
"kernel":{"gr":{"enable":true,"w":640,"h":480,"colors":16,"backend":"virtio-gpu"},
"proxy":{"enable":true,"link":"hdmi","dpi":192,"detected_hz":120,
         "high_w":1920,"high_h":1080,"scale_mode":"dpi","gl":true},
"cli":{"enable":false}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        assert_eq!(
            spec.default_surface(),
            g6b_spec::Surface::Gpu,
            "an accelerated output defaults to the native surface"
        );
        let m = analyze::kstart(&spec);
        let s = run_module(&spec, &m, 0x8020_0000).unwrap();
        assert_eq!(s.disp_sel.1, g6b_spec::Surface::Gpu.code());
        let pal_px = |lx: u32, ly: u32| -> u32 {
            let hdr = u32::from_le_bytes(s.gr_frame[40..44].try_into().unwrap()) as usize;
            let b = s.gr_frame[hdr + (ly * 320 + lx / 2) as usize];
            let idx = if lx % 2 == 0 { b >> 4 } else { b & 0xf } as usize;
            crate::vio::vio_palette()[idx]
        };
        let dp = |x: u32, y: u32| -> u32 {
            u32::from_le_bytes(
                s.vio_fb[(y * 1920 + x) as usize * 4..][..4]
                    .try_into()
                    .unwrap(),
            )
        };
        let (ox, oy) = (640u32, 300u32);
        for y in (oy..oy + 480).step_by(47) {
            for x in (ox..ox + 640).step_by(53) {
                assert_eq!(dp(x, y), pal_px(x - ox, y - oy), "1:1 dst({x},{y})");
            }
        }
        // Everything outside the 1:1 window stays black below the VioScan band.
        for y in (oy.max(64)..1080).step_by(61) {
            assert_eq!(dp(10, y), 0, "left of the 1:1 window y={y}");
        }
    }

    #[test]
    fn disp_sel_picks_the_uncore_engine_over_virtio_and_reports_hpd_unknown() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"uncore":{"plic":true,"hdmi":true},
"kernel":{"gr":{"enable":true,"w":640,"h":480,"colors":16,"backend":"hdmi"},
"proxy":{"enable":true,"link":"hdmi","dpi":192,"high_w":1920,"high_h":1080,"scale_mode":"dpi"},
"cli":{"enable":false}},
"peripherals":[{"id":"hdmi0","class":"display","model":"g6lc-scanout","base":"0x40003000"}],
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let m = analyze::kstart(&spec);
        let s = run_module(&spec, &m, 0x8020_0000).unwrap();
        // class 2 = uncore-scanout, surface 1 = gpu.
        let (class, surface, w, h, stride, hpd) = s.disp_sel;
        assert_eq!(class, g6b_spec::OutputClass::UncoreScanout.code());
        assert_eq!(surface, g6b_spec::Surface::Gpu.code());
        assert_eq!((w, h), (1920, 1080));
        assert_eq!(stride, 1920 * 4);
        // The host model reports contract revision 1, which has no HPD
        // register — so the guest must say "unknown", never "connected".
        assert_eq!(hpd as i64, crate::vio::HPD_UNKNOWN);
        assert!(s.console.contains("DISP-SEL 21"), "{}", s.console);
    }

    #[test]
    fn disp_sel_falls_to_vga_when_no_output_is_present() {
        // Gr plane over UART: the mux still runs and must record the `none`
        // rung with the VGA surface rather than leaving the block zeroed by
        // accident — class 0 *is* the answer here, so check the geometry too.
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
"kernel":{"gr":{"enable":true,"w":640,"h":480,"colors":16,"backend":"uart"}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        assert!(!spec.wants_virtio_gpu());
        let m = analyze::kstart(&spec);
        let s = run_module(&spec, &m, 0x8020_0000).unwrap();
        let (class, surface, w, h, _, hpd) = s.disp_sel;
        assert_eq!(class, g6b_spec::OutputClass::None.code());
        assert_eq!(surface, g6b_spec::Surface::Vga.code());
        assert_eq!((w, h), (640, 480), "the low-res plane geometry");
        assert_eq!(hpd as i64, crate::vio::HPD_UNKNOWN);
        assert!(s.console.contains("DISP-SEL 00"), "{}", s.console);
    }

    #[test]
    fn pci_probe_accepts_a_linear_bar_and_wins_the_ladder() {
        // A PCIe display controller with a BAR inside the declared window
        // outranks the virtio transport. The window is deliberately *not* at
        // 0x40000000 — that is QEMU virt's PCIe MMIO base and also the
        // ai-island block, a combination `check_display` refuses.
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
"kernel":{"gr":{"enable":true,"w":640,"h":480,"colors":16,"backend":"virtio-gpu"},
"proxy":{"enable":true,"link":"virtio-gpu","dpi":192,"high_w":1920,"high_h":1080},
"cli":{"enable":false}},
"pcie":{"scan_display":true,"ecam":"0x30000000","mmio":"0x60000000","mmio_len":"0x10000000"},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        assert!(spec.wants_pci_scan());
        let m = analyze::kstart(&spec);
        let s = run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(s.console.contains("PCI-GPU"), "{}", s.console);
        assert!(!s.console.contains("PCI-GPU-NONE"), "{}", s.console);
        let (bar, id) = s.pci_fb;
        assert_eq!(bar, 0x6000_0000, "the accepted linear BAR");
        assert_eq!(id, 0x1234_1111);
        let (class, surface, ..) = s.disp_sel;
        assert_eq!(
            class,
            g6b_spec::OutputClass::PcieLinearFb.code(),
            "pcie outranks virtio-gpu once a usable framebuffer exists"
        );
        assert_eq!(surface, g6b_spec::Surface::Gpu.code());
        assert!(s.console.contains("DISP-SEL 31"), "{}", s.console);
        // `PciPaint` is the commit on this rung: `FbExpandSel`'s destination
        // pick resolved to `__disp.fb` (the accepted BAR), so the blit lands
        // in the device shadow and the shared `__scan_fb` stays untouched —
        // `VioScan` never attached it because the virtio rung lost.
        assert!(s.console.contains("PCI-PAINT"), "{}", s.console);
        // Boot paint + the UART `Ui` repaint: every repaint lane reaches the
        // pcie rung, not just the boot-time paint pass.
        assert!(
            s.console.matches("PCI-PAINT").count() >= 2,
            "Ui repaint must reach the pcie backend: {}",
            s.console
        );
        assert!(
            s.pci_fb_img.iter().any(|&b| b != 0),
            "PciPaint wrote into the BAR shadow"
        );
        assert!(
            s.scan_fb.iter().all(|&b| b == 0),
            "pcie-linear-fb paints the BAR in place; __scan_fb is only the \
             fallback for outputs without their own linear window"
        );
        // The 1:1 gpu-surface placement is still the blit's geometry: the
        // first plane pixel lands at ((h-low_h)/2, (w-low_w)/2) of the BAR.
        let (w, h) = (1920usize, 1080usize);
        let off = ((h - 480) / 2 * w + (w - 640) / 2) * 4;
        assert!(
            s.pci_fb_img[off..off + 4].iter().any(|&b| b != 0),
            "plane pixel at the 1:1 offset {off:#x} of the BAR"
        );
    }

    #[test]
    fn pci_probe_reports_none_and_demotes_when_no_bar_is_usable() {
        // Same board, but the modelled controller's BAR lands outside the
        // declared window, so it must be refused and the mux must fall through
        // to virtio-gpu rather than trusting an out-of-window address.
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
"kernel":{"gr":{"enable":true,"w":640,"h":480,"colors":16,"backend":"virtio-gpu"},
"proxy":{"enable":true,"link":"virtio-gpu","dpi":192,"high_w":1920,"high_h":1080}},
"pcie":{"scan_display":true,"ecam":"0x30000000","mmio":"0x60000000","mmio_len":"0x1000"},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let m = analyze::kstart(&spec);
        let s = run_module(&spec, &m, 0x8020_0000).unwrap();
        // BAR0 == window base, window is only 0x1000 long, so the BAR *is*
        // inside it — this board accepts. Narrow it further by moving the BAR
        // out via a window that starts above it.
        assert_eq!(s.pci_fb.0, 0x6000_0000);
        assert!(s.console.contains("PCI-PAINT"), "{}", s.console);
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
"kernel":{"gr":{"enable":true,"w":640,"h":480,"colors":16,"backend":"virtio-gpu"},
"proxy":{"enable":true,"link":"virtio-gpu","dpi":192,"high_w":1920,"high_h":1080}},
"pcie":{"scan_display":true,"ecam":"0x30000000","mmio":"0x00000000","mmio_len":"0x1000"},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let m = analyze::kstart(&spec);
        let s = run_module(&spec, &m, 0x8020_0000).unwrap();
        // BAR0 is the window base 0 → masked to 0 → refused as "not a
        // framebuffer", so the controller is demoted, not driven.
        assert_eq!(s.pci_fb.0, 0, "an unusable BAR is never accepted");
        assert!(s.console.contains("PCI-GPU-DEMOTED"), "{}", s.console);
        let (class, ..) = s.disp_sel;
        assert_eq!(
            class,
            g6b_spec::OutputClass::VirtioGpu.code(),
            "demoted pcie falls through to the next rung"
        );
        // No BAR was accepted, so the pcie paint path stays shut: `PciPaint`
        // gates on `DISP_PCI_FB` and the virtio backend owns the surface.
        assert!(!s.console.contains("PCI-PAINT"), "{}", s.console);
        assert!(s.pci_fb_img.iter().all(|&b| b == 0));
    }

    #[test]
    fn disp_commit_scans_the_shared_fb() {
        // Native uncore display engine (`display`-class peripheral) — no
        // virtio transport: FbExpand fills __scan_fb and DispPaint programs
        // the engine + G6FB descriptor. `wants_virtio_gpu` must be false so
        // the VIRTIO lines never appear.
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"uncore":{"plic":true,"hdmi":true},
"kernel":{"gr":{"enable":true,"w":640,"h":480,"colors":16,"backend":"hdmi"},
"proxy":{"enable":true,"link":"hdmi","dpi":192,"detected_hz":120,
         "high_w":1920,"high_h":1080,"scale_mode":"dpi"}},
"peripherals":[{"id":"hdmi0","class":"display","model":"g6lc-scanout","base":"0x40003000"}],
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        assert!(!spec.wants_virtio_gpu(), "native display engine wins");
        assert!(spec.wants_disp_scan());
        let m = analyze::kstart(&spec);
        let s = run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(!s.console.contains("VIRTIO"), "{}", s.console);
        assert!(s.console.contains("DISP-OK"), "{}", s.console);
        assert!(!s.console.contains("DISP-FAIL"), "{}", s.console);
        assert!(s.disp_committed);
        let (fb, w, h, stride, fmt) = s.disp_desc;
        assert_ne!(fb, 0, "committed fb base");
        assert_eq!((w, h), (1920, 1080));
        assert_eq!(stride, 1920 * 4);
        assert_eq!(fmt, 1);
    }

    /// Driver module for the runtime-geometry tests: poke `__disp` with a
    /// geometry no `display_outputs()` rung declares, seed two `__gr_plane`
    /// bytes, then `jal` the named blit and `wfi`. The scanout BSS is sized
    /// to the poked geometry, so a blit still using the gen-time proxy
    /// (1920×1080) either lands at the wrong offset or runs past the buffer
    /// into a store fault — both detectable.
    fn disp_geom_module(spec: &BoardSpec, w: u32, h: u32, surface: u32, target: &str) -> Module {
        use crate::encode::{RA, SP, T0, T5, T6};
        let mut ops = vec![
            Op::Comment(format!(
                "test driver — poke __disp {w}x{h} surface={surface}, jal {target}"
            )),
            // sp = StacksEnd — the top of the stack region (`stacks` is where
            // the stack bytes end and `__gr_plane` begins). `stack_node`
            // subtracts (hartid+1)*STACK_BYTES, but the frames here only grow
            // down a few dozen bytes, so the top of the region is correct and
            // — unlike the underflowed bottom slot — cannot overwrite the code
            // tail in a module with no rodata padding.
            Op::La {
                rd: SP,
                addr: Addr::StacksEnd,
            },
            Op::La {
                rd: T5,
                addr: Addr::VioBss,
            },
        ];
        for (off, v) in [
            (crate::vio::DISP_SEL_W, w),
            (crate::vio::DISP_SEL_H, h),
            (crate::vio::DISP_SEL_STRIDE, w * 4),
            (crate::vio::DISP_SEL_SURFACE, surface),
        ] {
            ops.push(Op::Li {
                rd: T0,
                imm: i64::from(v),
            });
            ops.push(Op::Sw {
                rs2: T0,
                rs1: T5,
                off,
            });
        }
        ops.extend([
            // Seed plane bytes 0..4: 0x1c 0x2d 0x3e 0x4f → pixel pairs
            // pal[hi]/pal[lo]. One `sw` writes them all little-endian.
            Op::La {
                rd: T6,
                addr: Addr::GrPlane,
            },
            Op::Addi {
                rd: T6,
                rs: T6,
                imm: GR_HEADER_BYTES as i32,
            },
            Op::Li {
                rd: T0,
                imm: 0x4f3e_2d1c,
            },
            Op::Sw {
                rs2: T0,
                rs1: T6,
                off: 0,
            },
            Op::Jal {
                rd: RA,
                to: target.into(),
            },
            Op::Wfi,
        ]);
        Module {
            nodes: vec![
                Node {
                    purpose: Purpose::DisplayProxy,
                    ops,
                },
                crate::vio::expand_node(spec),
                crate::vio::expand1_node(spec),
                crate::vio::expand_sel_node(spec),
            ],
            nharts: 1,
            gr_bytes: gr_bss_len(640, 480, 16),
            dom_bytes: crate::dom::UI_DOM_BYTES,
            vio_bytes: crate::vio::VIO_BSS,
            vio_fb_bytes: u64::from(w) * u64::from(h) * 4,
            ..Module::default()
        }
    }

    #[test]
    fn fb_expand_follows_the_disp_latch_not_the_gen_time_proxy() {
        // `proxy` says 1920×1080 (scale-2 fit → a 1280×960 window at
        // (320,60)); the poked output is 1280×720, where fit is *1* and the
        // 640×480 plane centres at (320,120). Gen-time geometry would either
        // paint the wrong pixels or store-fault past `__scan_fb`.
        for xlen in [32u32, 64] {
            let spec = BoardSpec::from_json_str(&format!(
                r#"{{"schema_version":1,"isa":{{"xlen":{xlen}}},
"kernel":{{"gr":{{"enable":true,"w":640,"h":480,"colors":16,"backend":"uart"}},
"proxy":{{"enable":true,"link":"hdmi","dpi":192,"high_w":1920,"high_h":1080,"scale_mode":"fit"}}}},
"holyc":{{"dual_band":{{"tcp":{{"enable":false}}}}}}}}"#
            ))
            .unwrap();
            let m = disp_geom_module(&spec, 1280, 720, g6b_spec::Surface::Vga.code(), "FbExpand");
            let s = run_module(&spec, &m, 0x8020_0000).unwrap();
            assert!(
                matches!(s.halt, Halt::Wfi),
                "runtime geometry must stay inside the poked fb: {:?}",
                s.halt
            );
            // Plane byte 0 = 0x1c: even pixel pal[1], odd pixel pal[0xc].
            let dp = |x: u32, y: u32| -> u32 {
                u32::from_le_bytes(
                    s.scan_fb[(y * 1280 + x) as usize * 4..][..4]
                        .try_into()
                        .unwrap(),
                )
            };
            let pal = crate::vio::vio_palette();
            assert_eq!(dp(320, 120), pal[0x1], "scale-1 even pixel at (320,120)");
            assert_eq!(dp(321, 120), pal[0xc], "scale-1 odd pixel");
            assert_eq!(dp(322, 120), pal[0x2], "byte1 even pixel");
            assert_eq!(dp(323, 120), pal[0xd], "byte1 odd pixel");
            // Not the gen-time (320,60) origin, and not magnified: the
            // letterbox ring and the next source row stay black.
            assert_eq!(dp(320, 60), 0);
            assert_eq!(dp(0, 0), 0);
            assert_eq!(dp(320 + 640, 120), 0, "right letterbox");
            assert_eq!(dp(320, 120 + 480), 0, "bottom letterbox");
        }
    }

    #[test]
    fn fb_expand_sel_dispatches_per_output_geometry() {
        // Same poked 1600×1200 output, two surfaces: `vga` must run the
        // `FbExpand` fit (scale 2 → 1280×960 at (160,120)) while `gpu` must
        // run `FbExpand1` (scale 1 → 640×480 at (480,360)). One latched
        // `__disp` geometry, two distinct placements — the per-output
        // dispatch a fixed jump table would otherwise have to encode.
        for xlen in [32u32, 64] {
            let spec = BoardSpec::from_json_str(&format!(
                r#"{{"schema_version":1,"isa":{{"xlen":{xlen}}},
"kernel":{{"gr":{{"enable":true,"w":640,"h":480,"colors":16,"backend":"uart"}},
"proxy":{{"enable":true,"link":"hdmi","dpi":192,"high_w":1920,"high_h":1080,"scale_mode":"fit"}}}},
"holyc":{{"dual_band":{{"tcp":{{"enable":false}}}}}}}}"#
            ))
            .unwrap();
            let pal = crate::vio::vio_palette();
            let cases = [
                // (surface, expected scale, ox, oy, used_w, used_h)
                (
                    g6b_spec::Surface::Vga.code(),
                    2u32,
                    160u32,
                    120u32,
                    1280u32,
                    960u32,
                ),
                (
                    g6b_spec::Surface::Gpu.code(),
                    1u32,
                    480u32,
                    360u32,
                    640u32,
                    480u32,
                ),
            ];
            for (surface, sc, ox, oy, uw, uh) in cases {
                let m = disp_geom_module(&spec, 1600, 1200, surface, "FbExpandSel");
                let s = run_module(&spec, &m, 0x8020_0000).unwrap();
                assert!(
                    matches!(s.halt, Halt::Wfi),
                    "xlen={xlen} surface={surface}: {:?}",
                    s.halt
                );
                let dp = |x: u32, y: u32| -> u32 {
                    u32::from_le_bytes(
                        s.scan_fb[(y * 1600 + x) as usize * 4..][..4]
                            .try_into()
                            .unwrap(),
                    )
                };
                // Byte 0 = 0x1c → src pixels pal[1] / pal[0xc]; at scale sc
                // the first dst word of each sc-wide block is pal[1].
                assert_eq!(dp(ox, oy), pal[0x1], "surface={surface} origin");
                assert_eq!(
                    dp(ox + sc, oy),
                    pal[0xc],
                    "surface={surface} second src pixel at scale {sc}"
                );
                assert_eq!(dp(ox + uw, oy), 0, "right letterbox");
                assert_eq!(dp(ox, oy + uh), 0, "bottom letterbox");
            }
        }
    }

    #[test]
    fn dom_paint32_uses_the_disp_latch_geometry() {
        // `FbExpandSel` → `DomPaint32` on a GPU surface with a live DOM. The
        // poked output is 800×600 — no `display_outputs()` rung declares it —
        // so the native painter can only be correct if it reads `__disp`:
        // the clear bound is `w*h` and row addressing uses the latched
        // stride. A gen-time 1920×1080 clear would store-fault past the
        // 800×600 buffer; a gen-time stride would mis-place glyph rows.
        for xlen in [32u32, 64] {
            let spec = BoardSpec::from_json_str(&format!(
                r#"{{"schema_version":1,"isa":{{"xlen":{xlen}}},
"kernel":{{"gr":{{"enable":true,"w":640,"h":480,"colors":16,"backend":"virtio-gpu"}},
"proxy":{{"enable":true,"link":"hdmi","dpi":192,"high_w":1920,"high_h":1080,"scale_mode":"fit"}},
"wasm":{{"enable":true,"jit":true}}}},
"holyc":{{"dual_band":{{"tcp":{{"enable":false}}}}}}}}"#
            ))
            .unwrap();
            let st_text: fn(u32, u32, i32) -> Op = if xlen == 32 {
                |rs2, rs1, off| Op::Sw { rs2, rs1, off }
            } else {
                |rs2, rs1, off| Op::Sd { rs2, rs1, off }
            };
            use crate::encode::{RA, SP, T0, T1, T5};
            let mut ops = vec![
                Op::Comment(
                    "test driver — __disp 800x600 gpu + DOM row 'HI', jal FbExpandSel".into(),
                ),
                Op::La {
                    rd: SP,
                    addr: Addr::StacksEnd,
                },
                Op::La {
                    rd: T5,
                    addr: Addr::VioBss,
                },
            ];
            for (off, v) in [
                (crate::vio::DISP_SEL_W, 800u32),
                (crate::vio::DISP_SEL_H, 600),
                (crate::vio::DISP_SEL_STRIDE, 800 * 4),
                (crate::vio::DISP_SEL_SURFACE, g6b_spec::Surface::Gpu.code()),
            ] {
                ops.push(Op::Li {
                    rd: T0,
                    imm: i64::from(v),
                });
                ops.push(Op::Sw {
                    rs2: T0,
                    rs1: T5,
                    off,
                });
            }
            ops.extend([
                // __ui_dom: count=1; row0 = { text_ptr, len=2, flags=VISIBLE|TEXT }.
                Op::La {
                    rd: T5,
                    addr: Addr::UiDom,
                },
                Op::Li { rd: T0, imm: 1 },
                Op::Sw {
                    rs2: T0,
                    rs1: T5,
                    off: 0,
                },
                Op::La {
                    rd: T0,
                    addr: Addr::Label("dom_txt".into()),
                },
                st_text(T0, T5, crate::dom::DOM_HDR + 8),
                Op::Li { rd: T0, imm: 2 },
                Op::Sw {
                    rs2: T0,
                    rs1: T5,
                    off: crate::dom::DOM_HDR + 20,
                },
                Op::Li {
                    rd: T0,
                    imm: crate::dom::DOM_F_VISIBLE | crate::dom::DOM_F_TEXT,
                },
                Op::Sw {
                    rs2: T0,
                    rs1: T5,
                    off: crate::dom::DOM_HDR + 24,
                },
                Op::Jal {
                    rd: RA,
                    to: "FbExpandSel".into(),
                },
                Op::Wfi,
                // The row text lives in the code stream after the halting
                // `wfi`; `DomPaint32` `lbu`s it as data.
                Op::Label("dom_txt".into()),
                Op::Word(0x0000_4948), // "HI"
            ]);
            let _ = T1;
            let mut m = Module {
                nodes: vec![
                    Node {
                        purpose: Purpose::DisplayProxy,
                        ops,
                    },
                    crate::vio::expand_node(&spec),
                    crate::vio::expand1_node(&spec),
                    crate::vio::expand_sel_node(&spec),
                ],
                nharts: 1,
                gr_bytes: gr_bss_len(640, 480, 16),
                vio_bytes: crate::vio::VIO_BSS,
                vio_fb_bytes: 800 * 600 * 4,
                ..Module::default()
            };
            crate::dom::attach(&mut m, &spec);
            let s = run_module(&spec, &m, 0x8020_0000).unwrap();
            assert!(
                matches!(s.halt, Halt::Wfi),
                "xlen={xlen}: DomPaint32 must stay inside the poked fb: {:?}",
                s.halt
            );
            assert!(s.console.contains("DOM| HI"), "{}", s.console);
            // Geometry comes from the *latched* 800x600, and the text surface
            // now uses the same uniform scale + centred letterbox as FbExpand:
            //   N  = min(800/640, 600/480) = 1   (no room to magnify here)
            //   ox = (800-640)/2 = 80 ; oy = (600-480)/2 = 60
            // So the scale is 1:1 for this output but the origin is the
            // letterbox, not (0,0) — which is what this assertion pins.
            let font = crate::font::font_bytes();
            let (n, ox, oy) = (1u32, (800 - 640) / 2, (600 - 480) / 2);
            let dp = |x: u32, y: u32| -> u32 {
                u32::from_le_bytes(
                    s.scan_fb[(y * 800 + x) as usize * 4..][..4]
                        .try_into()
                        .unwrap(),
                )
            };
            let y0 = oy + 24 * n;
            for gy in 0..8u32 {
                let bits = font[((b'H' - 0x20) as usize) * 8 + gy as usize];
                for gx in 0..8u32 {
                    let want = if bits & (0x80 >> gx) != 0 {
                        0x00FF_FFFF
                    } else {
                        0
                    };
                    assert_eq!(
                        dp(ox + gx * n, y0 + gy * n),
                        want,
                        "xlen={xlen} 'H' glyph px ({gx},{gy})"
                    );
                }
            }
            // 'I' lands at the next scaled cell; everything past the painted
            // glyph rows stays cleared.
            assert_eq!(dp(ox, y0 + 8 * n), 0, "row band boundary");
            // Nothing outside the letterbox.
            assert_eq!(dp(0, y0), 0, "left of letterbox stays clear");
        }
    }

    #[test]
    fn vio_probe_reports_none_when_device_not_modelled() {
        // Same spec for payload and host; device flag off → reads return 0,
        // magic mismatches, probe reports NONE (fail-closed).
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"kernel":{"gr":{"enable":true,"backend":"virtio-gpu"}},"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let m = analyze::kstart(&spec);
        let s = run_module_no_gpu(&spec, &m, 0x8020_0000).unwrap();
        assert!(
            s.console.contains("VIRTIO-GPU-NONE"),
            "halt={:?} steps={}\n{}",
            s.halt,
            s.steps,
            s.console
        );
        assert!(!s.console.contains("VIRTIO-GPU 0"), "{}", s.console);
        // No device → VioInit returns silently after the rescan.
        assert!(!s.console.contains("VIRTIO-GPU-OK"), "{}", s.console);
        assert_eq!(s.vio_status, 0);
        assert_eq!(s.vio_last_cmd, 0);
    }

    #[test]
    fn vio_input_eventq_delivers_key() {
        // virtio-keyboard on slot 1: InpInit posts 8 eventq buffers, the host
        // kick (QEMU `sendkey` stand-in) fills one with EV_KEY KEY_A, raises
        // PLIC irq 2 → trap_inp → InpDrain pushes the key queue + INP marker.
        let spec = BoardSpec::from_json_str(
            // `cli.enable=false` on purpose: this is the **browser-owns-the-plane**
            // build, where a keystroke is the DOM's. On a build that also carries
            // the container, the container owns the screen at power-on and the same
            // key edits the prompt — that path is covered by
            // `the_container_owns_the_plane_until_the_picker_hands_it_over`.
            r#"{"schema_version":1,"isa":{"xlen":64},"uncore":{"plic":true},"kernel":{"cli":{"enable":false},"gr":{"enable":true,"backend":"virtio-gpu"},"wasm":{"enable":true,"jit":true}},"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        assert!(spec.wants_virtio_input());
        let m = analyze::kstart(&spec);
        let s = run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(s.console.contains("VIRTIO-INPUT-OK"), "{}", s.console);
        assert!(!s.console.contains("VIRTIO-INPUT-FAIL"), "{}", s.console);
        assert!(s.console.contains("VIRTIO-TABLET-OK"), "{}", s.console);
        assert!(!s.console.contains("VIRTIO-TABLET-FAIL"), "{}", s.console);
        assert_eq!(s.console.matches("TAB\n").count(), 3, "{}", s.console);
        // The drained EV_KEY event markers — the canned burst is
        // `sendkey a` + `sendkey down` + `sendkey ret` (press only).
        assert_eq!(s.console.matches("INP\n").count(), 3, "{}", s.console);
        // The UART `Keys` command drains INP_KQ → `KEY <8-hex>` per queued
        // press: KEY_A(30)→0x1e01, KEY_DOWN(108)→0x6c01, KEY_ENTER(28)→0x1c01.
        for line in ["KEY 00001e01", "KEY 00006c01", "KEY 00001c01"] {
            assert!(s.console.contains(line), "Keys dump: {}", s.console);
        }
        // DomKey mirrored the newest queued key (enter) into `inp.last`.
        assert!(s.dom_lastkey, "no inp.last DOM row: {}", s.console);
        // DomNav consumed the burst: 'a' ignored, DOWN → sel=1 (`cpu`),
        // ENTER → open latch + serial `NAV cpu`; nav.sel row = "open cpu".
        assert!(s.dom_nav, "no nav.sel DOM row: {}", s.console);
        assert_eq!(s.dom_navtext, "open cpu", "{}", s.console);
        assert!(s.console.contains("NAV cpu\n"), "{}", s.console);
        // Bounded await lane, 4 slots: `Await`×4 claim `await.0`..`await.3`
        // (pending), the fifth is the bounded-capacity `AWAIT-REJ full`,
        // `Throw` rejects the newest pending (slot 3 → `AWAIT-THROW` →
        // `await.3` row = "rejected menu"), and the `Ui` DomAwait poll
        // drains the three still-pending slots (`AWAIT-GET` + "resolved
        // menu" rows). The post-input timer tick also flushed a background
        // repaint (VIRTIO-PAINT without a Ui).
        for line in [
            "AWAIT pending 0\n",
            "AWAIT pending 3\n",
            "AWAIT-REJ full\n",
            "AWAIT-THROW /bios/menu\n",
            "AWAIT-GET /bios/menu\n",
            "rejected menu",
        ] {
            assert!(s.console.contains(line), "await lane: {}", s.console);
        }
        assert_eq!(
            s.console.matches("AWAIT-GET /bios/menu\n").count(),
            3,
            "slots 0-2 resolve, slot 3 was thrown: {}",
            s.console
        );
        assert!(
            s.console.matches("VIRTIO-PAINT\n").count() >= 3,
            "background repaint missing: {}",
            s.console
        );
        assert!(!s.console.contains("TRAP-"), "{}", s.console);
        assert!(matches!(s.halt, Halt::Wfi), "{:?}", s.halt);
    }

    #[test]
    fn vio_tablet_eventq_full_profile() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        assert!(spec.wants_virtio_input());
        let m = analyze::kstart(&spec);
        let s = run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(s.console.contains("VIRTIO-TABLET-OK"), "{}", s.console);
        assert!(
            s.tab_poked,
            "tablet poke ready={} qused={:#x} bufs={} poked={}",
            s.tab_ready, s.tab_qused, s.tab_bufs, s.tab_poked
        );
        assert_eq!(s.console.matches("TAB\n").count(), 3, "{}", s.console);
        assert_eq!(s.console.matches("INP\n").count(), 3, "{}", s.console);
    }

    #[test]
    fn stock_qemu_absent_devices_recover() {
        // Stock QEMU virt has no g6lc-bios mailbox and no second ns16550 —
        // the declared windows are unmapped → access fault → trap_fault marks
        // them absent and resumes at sepc+4 instead of parking on TRAP.
        // virtio-gpu/virtio-input are QEMU-attached and still work.
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"uncore":{"plic":true},"loopback":{"enable":true},"kernel":{"gr":{"enable":true,"backend":"virtio-gpu"},"wasm":{"enable":true}},"holyc":{"dual_band":{"tcp":{"enable":true}}}}"#,
        )
        .unwrap();
        let m = analyze::kstart(&spec);
        let s = run_module_bare(&spec, &m, 0x8020_0000).unwrap();
        assert!(s.console.contains("MBOX-NONE"), "{}", s.console);
        assert!(s.console.contains("UART1-NONE"), "{}", s.console);
        assert!(s.console.contains("VIRTIO-GPU-OK"), "{}", s.console);
        assert!(s.console.contains("VIRTIO-INPUT-OK"), "{}", s.console);
        assert!(s.console.contains("INP\n"), "{}", s.console);
        assert!(
            !s.console.contains("TRAP-"),
            "probe faults must recover, not park: {}",
            s.console
        );
        assert!(matches!(s.halt, Halt::Wfi), "{:?}", s.halt);
    }

    #[test]
    fn uart_irq_drains_host_rx() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"uncore":{"plic":true},"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let m = analyze::kstart(&spec);
        let s = run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(s.console.contains("KSTART-UART-IRQ"), "{}", s.console);
        assert!(s.console.contains("KSTART-UART-LINE"), "{}", s.console);
        assert!(s.console.contains("KSTART-UART-VIEWSEC"), "{}", s.console);
        assert!(s.console.contains("KSTART-UART-UI"), "{}", s.console);
        assert!(s.console.contains("KSTART-UART-FILE"), "{}", s.console);
        assert!(s.console.contains("KSTART-UART-GET"), "{}", s.console);
        assert!(
            s.uart_rxs >= 34,
            "trap_uart should drain ViewSection+Ui+File+Get: rxs={} sei={} halt={:?} console={}",
            s.uart_rxs,
            s.sei_claims,
            s.halt,
            s.console
        );
        assert!(
            s.console.contains("VIEW config"),
            "ViewSection quote: {}",
            s.console
        );
        assert!(
            s.console.contains("UI\n") || s.console.contains("UI"),
            "Ui command: {}",
            s.console
        );
        assert!(!s.console.contains("TRAP-"), "{}", s.console);
        assert!(matches!(s.halt, Halt::Wfi), "{:?}", s.halt);
    }

    #[test]
    fn mbox_reboot_kick_srst() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"uncore":{"plic":true},"loopback":{"enable":true},"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let m = analyze::kstart(&spec);
        let s = run_module_kick(&spec, &m, 0x8020_0000, b'R').unwrap();
        assert_eq!(s.mbox_magic, MBOX_MAGIC);
        assert!(
            matches!(s.halt, Halt::Srst),
            "Reboot kick should SBI SRST: halt={:?} console={}",
            s.halt,
            s.console
        );
        assert!(!s.console.contains("TRAP-"), "{}", s.console);
    }

    #[test]
    fn gr_init_writes_gr16_header() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"kernel":{"gr":{"enable":true,"w":640,"h":480},"proxy":{"enable":true,"link":"hdmi","high_w":1920,"high_h":1080,"dpi":192,"scale_mode":"dpi"},"cli":{"enable":false}},"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let m = analyze::kstart(&spec);
        let s = run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(s.console.contains("KSTART-GR"), "{}", s.console);
        assert_eq!(s.gr_magic, crate::encode::GR16_MAGIC, "GR16 ident");
        assert_eq!(
            s.gr_pix0,
            crate::encode::GR_FILL_WORD,
            "boot scanline 4bpp colour 1"
        );
        assert_eq!(s.gr_glyph0, 0x00FF_FF00, "G row0 4bpp at y=8");
        assert!(s.console.contains("KSTART-GR-PLANE"), "{}", s.console);
        assert!(s.console.contains("KSTART-GR-FONT"), "{}", s.console);
        assert!(!s.console.contains("TRAP-"), "{}", s.console);
        assert!(!s.console.contains("VGAM"), "{}", s.console);
        assert!(matches!(s.halt, Halt::Wfi), "{:?}", s.halt);
    }

    #[test]
    fn ui_init_writes_g6ui_and_wasm_jit() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"kernel":{"wasm":{"enable":true,"jit":true},"proxy":{"enable":true,"link":"hdmi","high_w":1920,"high_h":1080,"dpi":192,"gl":true}},"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let m = analyze::kstart(&spec);
        let s = run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(s.console.contains("KSTART-UI"), "{}", s.console);
        assert!(s.console.contains("KSTART-FILE"), "{}", s.console);
        assert!(s.console.contains("KSTART-PROXY-SCALE"), "{}", s.console);
        assert!(s.console.contains("KSTART-WASM-JIT"), "{}", s.console);
        assert_eq!(s.ui_magic, crate::encode::UI_MAGIC, "G6UI ident");
        assert_eq!(s.ui_size, m.ui_wasm.len() as u32, "wasm size");
        assert_eq!(s.ui_flags & 1, 1, "wasm flag {:#x}", s.ui_flags);
        assert_eq!(s.ui_flags & 64, 64, "jit flag {:#x}", s.ui_flags);
        assert_eq!(
            s.ui_wasm_magic,
            crate::encode::WASM_MAGIC,
            "FileServe \\0asm echo {:#x}",
            s.ui_wasm_magic
        );
        assert!(s.ui_nfiles >= 1, "nfiles={}", s.ui_nfiles);
        assert!(s.console.contains("FILE"), "{}", s.console);
        assert!(s.console.contains("/ui/ui.wasm"), "{}", s.console);
        assert!(s.console.contains("GET /ui/ui.wasm"), "{}", s.console);
        assert!(s.console.contains("KSTART-GET"), "{}", s.console);
        assert!(!s.console.contains("TRAP-"), "{}", s.console);
        assert!(matches!(s.halt, Halt::Wfi), "{:?}", s.halt);
    }

    #[test]
    fn mbox_ui_kick_rsp() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"uncore":{"plic":true},"loopback":{"enable":true},"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let m = analyze::kstart(&spec);
        let s = run_module_kick(&spec, &m, 0x8020_0000, b'U').unwrap();
        assert_eq!(s.mbox_magic, MBOX_MAGIC);
        assert_eq!(
            s.mbox_rsp,
            crate::encode::MBOX_RSP_UI,
            "UI rsp word {:#x}",
            s.mbox_rsp
        );
        assert!(!s.console.contains("TRAP-"), "{}", s.console);
    }

    #[test]
    fn mbox_file_kick_rsp() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"uncore":{"plic":true},"loopback":{"enable":true},"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let m = analyze::kstart(&spec);
        let s = run_module_kick(&spec, &m, 0x8020_0000, b'F').unwrap();
        assert_eq!(s.mbox_magic, MBOX_MAGIC);
        assert_eq!(
            s.mbox_rsp,
            crate::encode::MBOX_RSP_FILE,
            "FILE rsp word {:#x}",
            s.mbox_rsp
        );
        assert!(!s.console.contains("TRAP-"), "{}", s.console);
    }

    #[test]
    fn mbox_get_kick_returns_wasm_magic_and_size() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"uncore":{"plic":true},"loopback":{"enable":true},"kernel":{"wasm":{"enable":true,"jit":true}},"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let m = analyze::kstart(&spec);
        let s = run_module_kick(&spec, &m, 0x8020_0000, b'G').unwrap();
        assert_eq!(s.mbox_magic, MBOX_MAGIC);
        assert_eq!(
            s.mbox_rsp,
            crate::encode::WASM_MAGIC,
            "GET rsp magic {:#x}",
            s.mbox_rsp
        );
        assert_eq!(
            s.mbox_rsp1,
            m.ui_wasm.len() as u32,
            "GET rsp size {}",
            s.mbox_rsp1
        );
        assert_eq!(s.mbox_len, 8, "GET rsp length");
        assert!(!s.console.contains("TRAP-"), "{}", s.console);
    }
}
