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
const STEP_LIMIT: u32 = 16_000_000;
const UART0: u64 = 0x1000_0000;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Halt {
    Wfi,
    UartPoll,
    Srst,
    Limit,
    Unimp(u32),
}

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
    /// Scanout surface geometry (resource w/h).
    pub vio_fb_w: u32,
    pub vio_fb_h: u32,
    /// `SET_SCANOUT` completed.
    pub vio_scanout: bool,
    /// `RESOURCE_FLUSH` count.
    pub vio_flushes: u32,
    /// Used-buffer interrupt assertions (InterruptStatus bit 0 sets).
    pub vio_irqs: u32,
    /// Uncore display engine latched a scanout commit (`disp`-class
    /// peripheral; `architecture/uncore/hdmi-display.md`).
    pub disp_committed: bool,
    /// Display-engine framebuffer descriptor: (fb, width, height, stride,
    /// format) latched at COMMIT.
    pub disp_desc: (u64, u32, u32, u32, u32),
}

/// Lower `module` at `entry` and run hart 0 until park/UART/SBI SRST.
pub fn run_module(spec: &BoardSpec, module: &Module, entry: u64) -> Result<Smoke, String> {
    run_module_hart(spec, module, entry, 0)
}

/// Same as [`run_module`] with OpenSBI `a0=hartid`.
pub fn run_module_hart(
    spec: &BoardSpec,
    module: &Module,
    entry: u64,
    hartid: u64,
) -> Result<Smoke, String> {
    let (insns, rodata) = module.to_words(entry)?;
    let mut image = Vec::with_capacity(insns.len() * 4 + rodata.len());
    for w in insns {
        image.extend_from_slice(&w.to_le_bytes());
    }
    image.extend_from_slice(&rodata);
    let memsz = payload_memsz(
        image.len() as u64,
        module.n_harts(),
        module
            .gr_bytes
            .saturating_add(module.line_bytes)
            .saturating_add(module.ui_bytes)
            .saturating_add(module.dom_bytes)
            .saturating_add(module.vio_bytes)
            .saturating_add(module.vio_fb_bytes),
    );
    run_with_kick(
        spec,
        &image,
        entry,
        memsz,
        hartid,
        b'V',
        spec.wants_virtio_gpu(),
        true,
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
    let memsz = payload_memsz(
        image.len() as u64,
        module.n_harts(),
        module
            .gr_bytes
            .saturating_add(module.line_bytes)
            .saturating_add(module.ui_bytes)
            .saturating_add(module.dom_bytes)
            .saturating_add(module.vio_bytes)
            .saturating_add(module.vio_fb_bytes),
    );
    run_with_kick(
        spec,
        &image,
        entry,
        memsz,
        0,
        kick,
        spec.wants_virtio_gpu(),
        true,
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
    let memsz = payload_memsz(
        image.len() as u64,
        module.n_harts(),
        module
            .gr_bytes
            .saturating_add(module.line_bytes)
            .saturating_add(module.ui_bytes)
            .saturating_add(module.dom_bytes)
            .saturating_add(module.vio_bytes)
            .saturating_add(module.vio_fb_bytes),
    );
    run_with_kick(spec, &image, entry, memsz, 0, b'V', false, true)
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
    let memsz = payload_memsz(
        image.len() as u64,
        module.n_harts(),
        module
            .gr_bytes
            .saturating_add(module.line_bytes)
            .saturating_add(module.ui_bytes)
            .saturating_add(module.dom_bytes)
            .saturating_add(module.vio_bytes)
            .saturating_add(module.vio_fb_bytes),
    );
    run_with_kick(
        spec,
        &image,
        entry,
        memsz,
        0,
        b'V',
        spec.wants_virtio_gpu(),
        false,
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
) -> Result<Smoke, String> {
    let xlen = spec.isa.xlen;
    if xlen != 32 && xlen != 64 {
        return Err(format!("unsupported xlen {xlen}"));
    }
    let mut ram = vec![0u8; memsz as usize];
    if image.len() > ram.len() {
        return Err("image larger than memsz".into());
    }
    ram[..image.len()].copy_from_slice(image);
    let mut x = [0u64; 32];
    x[10] = hartid; // a0 hartid
                    // a1 models the OpenSBI handoff: the *boot* hart gets the FDT pointer
                    // (nonzero), harts started via SBI HSM get a1=opaque=0 — the payload
                    // parks on a1==0, so any hart id can be primary. The model's boot hart
                    // is hart 0; the marker is never dereferenced.
    x[11] = if hartid == 0 { 0x8fe0_0000 } else { 0 };
    let mut pc = entry;
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
        vio_inp: vio_gpu && spec.wants_virtio_input(),
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
        ui_base: {
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
            if spec.kernel.wasm.enable || spec.kernel.http.files.enable {
                stacks.wrapping_add(gr).wrapping_add(UART_LINE_BSS)
            } else {
                0
            }
        },
        dom_base: {
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
            if spec.kernel.wasm.enable && spec.kernel.wasm.jit {
                stacks
                    .wrapping_add(gr)
                    .wrapping_add(UART_LINE_BSS)
                    .wrapping_add(crate::UI_HEADER_BYTES)
            } else {
                0
            }
        },
        disp_base: spec.display_ctrl().unwrap_or(0),
        ..Default::default()
    };
    let mut console = String::new();
    let mut uart_polls = 0u32;
    let mut steps = 0u32;
    loop {
        if steps >= STEP_LIMIT {
            return Ok(done(console, steps, Halt::Limit, &csr, &ram, entry, xlen));
        }
        steps += 1;
        csr.time = csr.time.wrapping_add(1);
        if take_pending_sei(xlen, &mut pc, &mut csr) {
            continue;
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
                // (QEMU `sendkey` arrives asynchronously the same way).
                if host_inp_kick(&mut csr, &mut ram, entry)
                    && take_pending_sei(xlen, &mut pc, &mut csr)
                {
                    continue;
                }
                if host_uart_kick(&mut csr) && take_pending_sei(xlen, &mut pc, &mut csr) {
                    continue;
                }
                return Ok(done(console, steps, h, &csr, &ram, entry, xlen));
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
            ));
        }
    }
}

fn done(
    console: String,
    steps: u32,
    halt: Halt,
    csr: &Csr,
    ram: &[u8],
    base: u64,
    xlen: u32,
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
            let row = csr.dom_base.wrapping_add(16 + u64::from(i) * 32);
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
    Smoke {
        console,
        steps,
        halt,
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
        gr_frame,
        vio_status: csr.vio_status,
        vio_last_cmd: csr.vio_last_cmd,
        vio_last_resp: csr.vio_last_resp,
        vio_fb: csr.vio_fb.clone(),
        vio_fb_w: csr.vio_res_w,
        vio_fb_h: csr.vio_res_h,
        vio_scanout: csr.vio_scanout,
        vio_flushes: csr.vio_flushes,
        vio_irqs: csr.vio_irqs,
        disp_committed: csr.disp_committed,
        disp_desc: (
            csr.disp_regs[3] as u64 | ((csr.disp_regs[4] as u64) << 32),
            csr.disp_regs[5],
            csr.disp_regs[6],
            csr.disp_regs[7],
            csr.disp_regs[8],
        ),
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
    gr_dom_off: u64,
    /// Modelled virtio-mmio GPU at slot 0 (matches `qemu_dual_band_argv`).
    vio_gpu: bool,
    /// Virtio device registers/status for the slot-0 model.
    vio_status: u32,
    vio_feat_sel: u32,
    vio_drv_sel: u32,
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
    /// Uncore display-engine window base (`display`-class peripheral;
    /// `architecture/uncore/hdmi-display.md`) — 0 = absent.
    disp_base: u64,
    /// Display-engine register file (off/4) for the RW window.
    disp_regs: [u32; 16],
    /// COMMIT latched a scanout (fb/w/h/stride/format valid).
    disp_committed: bool,
    /// STATUS readback: 1 after COMMIT.
    disp_status: u32,
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
                5 if f7 & 0x20 == 0 => {
                    let unsigned = if xlen == 32 { u64::from(a as u32) } else { a };
                    unsigned >> shamt(w, xlen)
                }
                7 => a & (imm as u64),
                _ => return Step::Halt(Halt::Unimp(w)),
            };
            wr(xlen, x, rd, v);
            *pc = npc;
        }
        0x33 => {
            let a = x[rs1 as usize];
            let b = x[rs2 as usize];
            let v = match (f3, f7) {
                (0, 0) => a.wrapping_add(b),
                (0, 0x20) => a.wrapping_sub(b),
                (0, 1) => a.wrapping_mul(b),
                (4, 0) => a ^ b,
                _ => return Step::Halt(Halt::Unimp(w)),
            };
            wr(xlen, x, rd, v);
            *pc = npc;
        }
        0x03 => {
            let addr = x[rs1 as usize].wrapping_add(iimm(w) as u64);
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
            *uart_polls = 0;
            let v = match f3 {
                2 => load_u32(ram, base, addr).map(|v| sext32(v as i32, xlen)),
                3 => load_u64(ram, base, addr),
                4 => load_u8(ram, base, addr).map(u64::from),
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
            let addr = x[rs1 as usize].wrapping_add(simm(w) as u64);
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
            let ok = match f3 {
                0 => store_u8(ram, base, addr, val as u8),
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
            let take = match f3 {
                0 => a == b,
                1 => a != b,
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
            let target = x[rs1 as usize].wrapping_add(iimm(w) as u64) & !1;
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
                if timer_armed(csr) && csr.ticks < 1 && csr.stvec != 0 {
                    take_timer_trap(xlen, *pc, csr);
                    *pc = csr.stvec;
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
    if csr.stvec == 0 || csr.sei_claims >= 64 || !sei_ready(csr) {
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
    };
    let off = addr - VIO_MMIO_BASE;
    let slot = off / VIO_MMIO_STEP;
    if slot == 1 && csr.vio_inp {
        return inp_load(csr, off % VIO_MMIO_STEP, VIO_DEV_INPUT);
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
    if slot != 0 || !csr.vio_gpu {
        return;
    }
    match off % VIO_MMIO_STEP {
        0x14 => csr.vio_feat_sel = v,
        0x20 => {} // driver features accepted without a gate
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

/// Inject a canned `sendkey` burst into the posted eventq buffers — models
/// QEMU `sendkey a; sendkey down; sendkey ret` at idle (press events only;
/// QEMU also emits releases, which `InpDrain`/`DomNav` ignore by value).
/// Fills the desc buffers, publishes used elems and raises PLIC irq
/// 1+slot(=2) for the virtio-mmio slot.
fn host_inp_kick(csr: &mut Csr, ram: &mut [u8], base: u64) -> bool {
    if !csr.vio_inp || csr.inp_poked || !csr.inp_ready || csr.inp_qused == 0 {
        return false;
    }
    csr.inp_poked = true;
    // virtio_input_event {u16 type=EV_KEY, u16 code, u32 value}: 'a' (30),
    // KEY_DOWN (108), KEY_ENTER (28) — a non-nav letter, a nav arrow and an
    // activation in one burst.
    const SEQ: [(u16, u32); 3] = [(30, 1), (108, 1), (28, 1)];
    let used = csr.inp_qused;
    let mut pushed = false;
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
        pushed = true;
    }
    if pushed {
        let _ = store_u32(ram, base, used, u32::from(csr.inp_used_idx) << 16);
        csr.inp_isr |= 1;
        csr.plic_pending |= 1 << 2;
    }
    pushed
}

/// Walk one descriptor chain (≤8): OUT descriptors carry `ctrl_hdr.type`, the
/// first WRITE descriptor gets the response. Returns used-elem `len`.
fn vio_exec_chain(csr: &mut Csr, ram: &mut [u8], base: u64, head: u16) -> u32 {
    use crate::encode::{VIO_DESC_NEXT, VIO_DESC_WRITE, VIO_GPU_RESP_OK_DISPLAY_INFO};
    use crate::vio::VIO_RESP_DISPLAY_INFO;
    let mut d = u64::from(head);
    let mut wrote = 0u32;
    let mut pending: Option<u32> = None;
    for _ in 0..8 {
        let dbase = csr.vio_qdesc.wrapping_add(d.wrapping_mul(16));
        let daddr = load_u64(ram, base, dbase).unwrap_or(0);
        let dlen = load_u32(ram, base, dbase + 8).unwrap_or(0);
        let dfl = load_u32(ram, base, dbase + 12).unwrap_or(0);
        if dfl & VIO_DESC_WRITE == 0 {
            let ty = load_u32(ram, base, daddr).unwrap_or(0);
            csr.vio_last_cmd = ty;
            pending = Some(vio_cmd(csr, ram, base, daddr, ty));
        } else if let Some(ty) = pending.take() {
            store_u32(ram, base, daddr, ty);
            csr.vio_last_resp = ty;
            if ty == VIO_GPU_RESP_OK_DISPLAY_INFO {
                // pmodes[0]: enabled, flags, x, y, w, h (24-byte resp hdr).
                for (i, v) in [1u32, 0, 0, 0, csr.vio_disp_w, csr.vio_disp_h]
                    .iter()
                    .enumerate()
                {
                    store_u32(ram, base, daddr + 24 + (i as u64) * 4, *v);
                }
            }
            let cap = if ty == VIO_GPU_RESP_OK_DISPLAY_INFO {
                VIO_RESP_DISPLAY_INFO
            } else {
                24
            };
            wrote = wrote.saturating_add(dlen.min(cap));
        }
        if dfl & VIO_DESC_NEXT == 0 {
            break;
        }
        d = u64::from((dfl >> 16) & 0xffff);
    }
    wrote
}

/// Execute one ctrlq command read from `req` in guest RAM; returns the
/// `resp_hdr.type` the device would write (virtio spec 5.7.6/5.7.8–5.7.10).
fn vio_cmd(csr: &mut Csr, ram: &mut [u8], base: u64, req: u64, ty: u32) -> u32 {
    use crate::encode::{
        VIO_GPU_GET_DISPLAY_INFO, VIO_GPU_RESOURCE_ATTACH_BACKING, VIO_GPU_RESOURCE_CREATE_2D,
        VIO_GPU_RESOURCE_FLUSH, VIO_GPU_RESP_ERR_UNSPEC, VIO_GPU_RESP_OK_DISPLAY_INFO,
        VIO_GPU_RESP_OK_NODATA, VIO_GPU_SET_SCANOUT, VIO_GPU_TRANSFER_TO_HOST_2D,
    };
    use crate::vio::VIO_FB_MAX;
    let rd = |o: u64| load_u32(ram, base, req + o).unwrap_or(0);
    match ty {
        VIO_GPU_GET_DISPLAY_INFO => VIO_GPU_RESP_OK_DISPLAY_INFO,
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
            let addr = load_u64(ram, base, req + 32).unwrap_or(0);
            let len = rd(40);
            if res != csr.vio_res_id || nr == 0 || addr == 0 {
                VIO_GPU_RESP_ERR_UNSPEC
            } else {
                csr.vio_backing = addr;
                csr.vio_backing_len = u64::from(len);
                VIO_GPU_RESP_OK_NODATA
            }
        }
        VIO_GPU_SET_SCANOUT => {
            let (scanout, res) = (rd(40), rd(44));
            if scanout != 0 || res != csr.vio_res_id || csr.vio_fb.is_empty() {
                VIO_GPU_RESP_ERR_UNSPEC
            } else {
                csr.vio_scanout = true;
                VIO_GPU_RESP_OK_NODATA
            }
        }
        VIO_GPU_TRANSFER_TO_HOST_2D => {
            let (x, y, rw, rh) = (rd(24), rd(28), rd(32), rd(36));
            let off = load_u64(ram, base, req + 40).unwrap_or(0);
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
            if rd(40) == csr.vio_res_id && !csr.vio_fb.is_empty() {
                csr.vio_flushes = csr.vio_flushes.wrapping_add(1);
                VIO_GPU_RESP_OK_NODATA
            } else {
                VIO_GPU_RESP_ERR_UNSPEC
            }
        }
        _ => VIO_GPU_RESP_ERR_UNSPEC,
    }
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
    // canned host_inp_kick keypress should already sit in INP_KQ.
    const SEQ_KEYS: &[u8] = b"Keys\n";
    let i = csr.uart_seq_i as usize;
    let byte = if i < SEQ.len() {
        SEQ[i]
    } else if csr.vio_inp && i < SEQ.len() + SEQ_KEYS.len() {
        SEQ_KEYS[i - SEQ.len()]
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

fn store_u8(ram: &mut [u8], base: u64, addr: u64, v: u8) -> bool {
    if let Some(o) = addr.checked_sub(base).and_then(|d| usize::try_from(d).ok()) {
        if o < ram.len() {
            ram[o] = v;
            return true;
        }
    }
    false
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
            }
        }

        fn tick(&mut self) -> Option<Halt> {
            let word = fetch_u32(&self.ram, TASK_BASE, self.pc).unwrap();
            let mut console = String::new();
            match step(
                self.xlen,
                &mut self.x,
                &mut self.pc,
                &mut self.csr,
                &mut self.ram,
                TASK_BASE,
                word,
                &mut console,
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

    #[test]
    fn vio_paint_scale_expands_to_proxy_high_res() {
        // Display-proxy live (1920×1080, dpi mode → scale 2): the scanout
        // resource is the *high-res* surface and FbExpand paints the 4bpp
        // plane into a centered 1280×960 window — the `Proxy::to_ppm`
        // semantics (ox=(1920-1280)/2=320, oy=(1080-960)/2=60).
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"uncore":{"plic":true},
"kernel":{"gr":{"enable":true,"w":640,"h":480,"colors":16,"backend":"virtio-gpu"},
"proxy":{"enable":true,"link":"hdmi","dpi":192,"detected_hz":120,
         "high_w":1920,"high_h":1080,"scale_mode":"dpi","gl":true}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let m = analyze::kstart(&spec);
        let s = run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(s.console.contains("VIRTIO-SCAN"), "{}", s.console);
        assert!(s.vio_scanout);
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
            r#"{"schema_version":1,"isa":{"xlen":64},"uncore":{"plic":true},"kernel":{"gr":{"enable":true,"backend":"virtio-gpu"},"wasm":{"enable":true,"jit":true}},"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        assert!(spec.wants_virtio_input());
        let m = analyze::kstart(&spec);
        let s = run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(s.console.contains("VIRTIO-INPUT-OK"), "{}", s.console);
        assert!(!s.console.contains("VIRTIO-INPUT-FAIL"), "{}", s.console);
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
        assert!(!s.console.contains("TRAP-"), "{}", s.console);
        assert!(matches!(s.halt, Halt::Wfi), "{:?}", s.halt);
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
            r#"{"schema_version":1,"isa":{"xlen":64},"kernel":{"gr":{"enable":true,"w":640,"h":480},"proxy":{"enable":true,"link":"hdmi","high_w":1920,"high_h":1080,"dpi":192,"scale_mode":"dpi"}},"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
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
        assert_eq!(s.ui_size, crate::BIOS_UI_WASM.len() as u32, "wasm size");
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
            crate::BIOS_UI_WASM.len() as u32,
            "GET rsp size {}",
            s.mbox_rsp1
        );
        assert_eq!(s.mbox_len, 8, "GET rsp length");
        assert!(!s.console.contains("TRAP-"), "{}", s.console);
    }
}
