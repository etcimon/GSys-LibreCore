// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Analyze BoardSpec objects into purpose-tagged ASM IR.
//!
//! The pass names *why* each register/CSR/buffer exists, then emits one
//! [`Node`](crate::Node) per live object. Listings (`.S`) and ELF words lower
//! from the same [`Module`](crate::Module). See `architecture/CODEGEN.md`.

#![allow(missing_docs)]

use g6b_spec::BoardSpec;

use crate::encode::{
    A0, A1, A2, A3, A4, A5, A6, A7, CMD_AWAI, CMD_BLK, CMD_FILE, CMD_FWS, CMD_GET, CMD_JRN,
    CMD_KEYS, CMD_LNX, CMD_REBO, CMD_SHUT, CMD_THRO, CMD_UI, CMD_VIEW, CMD_WAKE, CSR_SATP,
    CSR_SCAUSE, CSR_SEPC, CSR_SIE, CSR_SSTATUS, CSR_STVEC, CSR_TIME, GR16_MAGIC, GR_FILL_WORD,
    MBOX_MAGIC, MBOX_OFF_CMD, MBOX_OFF_DOORBELL, MBOX_OFF_IRQ_EN, MBOX_OFF_LENGTH, MBOX_OFF_RSP,
    MBOX_OFF_STATUS, MBOX_RSP_FILE, MBOX_RSP_KEYS, MBOX_RSP_UI, MBOX_RSP_VIEW, MBOX_RSP_WAKE,
    MBOX_ST_BUSY, MBOX_ST_RSP, PLIC_BASE, PLIC_CTXT_BASE, PLIC_ENABLE_BASE, RA, S1, SBI_HSM_EID,
    SBI_IPI_EID, SBI_PUTCHAR, SBI_SRST_EID, SBI_TIME_EID, SCAUSE_LOAD_ACCESS, SCAUSE_STORE_ACCESS,
    SIE_SEIE, SIE_SSIE, SIE_STIE, SP, SSTATUS_SIE, T0, T1, T2, T3, T4, T5, T6, TP, UART_IER_RX,
    UART_IRQ, UART_LSR_DR, UI_MAGIC, VIO_DEV_GPU, VIO_DEV_NET, VIO_MAGIC, VIO_MMIO_BASE,
    VIO_MMIO_SLOTS, VIO_MMIO_STEP, VTYPE_E8_M1_TA_MA, X0,
};
use crate::{
    gr_bss_len, gr_stride, Addr, Module, Node, Op, Purpose, BIOS_UI_LIBWASM, BIOS_UI_WASM,
    GR_HEADER_BYTES, MBOX_DEAD_OFF, STACK_BYTES, STACK_SHIFT, UART1_DEAD_OFF, UART_LINE_BSS,
    UART_LINE_CAP, UI_HEADER_BYTES,
};

/// One analyzed object: purpose, architectural home, whether it is live.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Object {
    pub purpose: Purpose,
    pub live: bool,
    pub why: &'static str,
}

impl Object {
    pub fn home(self) -> &'static str {
        self.purpose.home()
    }
}

/// Decide which state objects exist for this BoardSpec.
pub fn objects(spec: &BoardSpec) -> Vec<Object> {
    let uart1 = spec.holyc.dual_band.tcp.enable;
    let reboot = spec.postboot.power.iter().any(|p| p == "reboot")
        || spec.postboot.enable != g6b_spec::PostbootMode::Never;
    vec![
        Object {
            purpose: Purpose::HartId,
            live: true,
            why: "OpenSBI a0=hartid → tp (CPU0/Gs rewrite)",
        },
        Object {
            purpose: Purpose::Dtb,
            live: true,
            why: "OpenSBI a1=dtb → s1",
        },
        Object {
            purpose: Purpose::Satp,
            live: true,
            why: "S-mode satp=bare + sfence.vma (Priv ch4); not CR3",
        },
        Object {
            purpose: Purpose::Stack,
            live: true,
            why: "per-hart TaskInit stack after payload; sp = stacks_end-(hartid+1)*0x8000",
        },
        Object {
            purpose: Purpose::TrapVec,
            live: true,
            why: "KInts stvec, not an IDT",
        },
        Object {
            purpose: Purpose::BootLog,
            live: true,
            why: "KMain SBI putchar + UART0 ns16550 THR (QEMU -nographic; not 0x3F8)",
        },
        Object {
            purpose: Purpose::Uart1Repl,
            live: uart1,
            why: "SSH+HolyC dual-band UART1 ns16550 RX irq (chardev, not a NIC, not a poll)",
        },
        Object {
            purpose: Purpose::Park,
            live: true,
            why: "non-handoff harts WFI; the a1=fdt handoff hart runs Adam (boot hart is a lottery, not always 0); UART1 is irq-driven WFI (not a busy poll)",
        },
        Object {
            purpose: Purpose::Trap,
            live: true,
            why: "supervisor trap: irq 5 TIME, irq 9 PLIC (UART 1 RX / mbox); else INT_FAULT",
        },
        Object {
            purpose: Purpose::Timer,
            live: true,
            why: "TimerInit rewrite: sie.STIE + sstatus.SIE + SBI TIME (RISC-V Priv ch3)",
        },
        Object {
            purpose: Purpose::MemCpy,
            live: true,
            why: "HolyC ISel MemCpy(a0,a1,a2); RVV only if v=live and xlen=64",
        },
        Object {
            purpose: Purpose::Reboot,
            live: reboot,
            why: "SBI SRST; not a PC keyboard-controller reset",
        },
        Object {
            purpose: Purpose::DisplayProxy,
            live: spec.kernel.gr.enable || spec.kernel.proxy.enable,
            why: "SysGrInit GR16 header + 4bpp plane at __gr_plane; 640×480 scaled to high-DPI scanout",
        },
        Object {
            purpose: Purpose::GlAdapter,
            live: spec.kernel.proxy.enable && spec.kernel.proxy.gl,
            why: "OpenGL-ES2 listing paints DOM status on the high-res plane",
        },
        Object {
            purpose: Purpose::Virtio,
            live: spec.wants_virtio_gpu(),
            why: "virtio-mmio probe 0x10001000+0x200*N for GPU device_id 16 (QEMU virt; queues/scanout open)",
        },
        Object {
            purpose: Purpose::VirtioNet,
            live: spec.wants_virtio_net(),
            why: "virtio-mmio probe DeviceID 1 (virtio-net); never QEMU -netdev",
        },
        Object {
            purpose: Purpose::VirtioBlk,
            live: spec.wants_virtio_blk(),
            why: "virtio-mmio DeviceID 2 requestq — the payload reads its own sectors (LBA 0/1 identify the medium)",
        },
        Object {
            purpose: Purpose::DispScan,
            live: spec.wants_disp_scan(),
            why: "uncore display-engine commit (architecture/uncore/hdmi-display.md) — __scan_fb is the BIOS+Linux simplefb handoff",
        },
        Object {
            purpose: Purpose::PciScan,
            live: spec.wants_pci_scan(),
            why: "read-only PCIe ECAM scan for a class-0x03 controller with a firmware-assigned linear BAR; no AMD/NVIDIA modeset",
        },
        Object {
            purpose: Purpose::DisplayMux,
            live: spec.kernel.gr.enable || spec.kernel.proxy.enable,
            why: "DispSel — latch the highest-priority PRESENT output and its surface into __disp",
        },
        Object {
            purpose: Purpose::Tls,
            live: spec.kernel.tls.enable,
            why: "Botan-shaped TLS 1.2 ClientHello; SHA-256 + AES-128; not OpenSSL",
        },
        Object {
            purpose: Purpose::Https,
            live: spec.kernel.tls.https,
            why: "HolyC HttpsGet; mailbox after NET-DELEGATE",
        },
        Object {
            purpose: Purpose::WasmJit,
            live: spec.kernel.wasm.enable,
            why: "WASM MVP JIT for svelte-d UI; not wasmtime",
        },
        Object {
            purpose: Purpose::SvelteUi,
            live: spec.kernel.ui == "svelte-d",
            why: "svelte-d NodeDef / @prop / {#if} live; {#await} stub",
        },
        Object {
            purpose: Purpose::Rsa,
            live: spec.kernel.tls.enable && spec.kernel.tls.rsa,
            why: "RSA PKCS#1 v1.5 SHA-256 verify (web ClientHello)",
        },
        Object {
            purpose: Purpose::Ecdsa,
            live: spec.kernel.tls.enable && spec.kernel.tls.ecdsa,
            why: "ECDSA P-256 SHA-256 verify",
        },
        Object {
            purpose: Purpose::Cert,
            live: spec.kernel.tls.enable && spec.kernel.tls.certificates,
            why: "X.509 DER/PEM CN + algo (Botan cert/x509)",
        },
        Object {
            purpose: Purpose::Hmac,
            live: spec.kernel.tls.enable,
            why: "HMAC-SHA256 record MAC / Finished",
        },
        Object {
            purpose: Purpose::Http,
            live: spec.kernel.http.enable,
            why: "HTTP/1.1 + HTTP/2 parse; not SvelteKit; not a netdev",
        },
        Object {
            purpose: Purpose::Endpoint,
            live: spec.kernel.http.enable,
            why: "HolyC/JS register the same kernel router",
        },
        Object {
            purpose: Purpose::BiosParam,
            live: spec.kernel.http.enable
                && (spec.kernel.params.clocks
                    || spec.kernel.params.edk2
                    || spec.kernel.params.uboot
                    || spec.kernel.params.bootloader),
            why: "compiled BIOS clocks/edk2/u-boot/bootloader JSON",
        },
        Object {
            purpose: Purpose::Flash,
            live: spec.kernel.flash.enable,
            why: "OpenWrt / BIOS self-update via spi-nor, mailbox, or USB key",
        },
        Object {
            purpose: Purpose::Settings,
            live: spec.kernel.settings.enable,
            why: "export/import BIOS settings (UART/mailbox/USB)",
        },
        Object {
            purpose: Purpose::Usb,
            live: spec.kernel.usb.enable,
            why: "USB MSC FAT32 flash always; key FileMgr FAT32/NTFS/ext4; not a netdev",
        },
        Object {
            purpose: Purpose::Topology,
            live: spec.smt()
                || spec.multi_core()
                || spec.geo.issue_ports > 1
                || spec.geo.ooo
                || spec.geo.stream,
            why: "SBI HSM hart_start + IPI for every hart except self (MultiProc rewrite); Adam on the boot hart",
        },
        Object {
            purpose: Purpose::Hypervisor,
            live: spec.hypervisor_live(),
            why: "H live for next-stage HS/KVM; BIOS payload stays S-mode",
        },
        Object {
            purpose: Purpose::Uncore,
            live: spec.uncore.clint
                || spec.uncore.plic
                || spec.uncore.ddr
                || spec.uncore.pcie
                || spec.uncore.ethernet
                || spec.uncore.storage
                || spec.uncore.hdmi,
            why: "PLIC S-mode ctx1 claim/complete (UART irq 1, mbox irq); not x86 EOI",
        },
        Object {
            purpose: Purpose::Mailbox,
            live: spec.loopback.enable,
            why: "sideband mbox MMIO (doorbell/status/irq_en); not a netdev",
        },
        Object {
            purpose: Purpose::Menu,
            live: spec.kernel.http.enable || spec.holyc.fast_init,
            why: "inferred setup tree: HolyC Menu* and browser /bios/menu share one model",
        },
        Object {
            purpose: Purpose::FileServe,
            live: spec.kernel.http.files.enable,
            why: "HolyC kernel file server: G6UI blob + generated HTML/JS/WASM; not a Linux VFS",
        },
    ]
}

/// Live objects only, in emission order.
pub fn live_objects(spec: &BoardSpec) -> Vec<Object> {
    objects(spec).into_iter().filter(|o| o.live).collect()
}

/// Full OpenSBI payload: KStart + optional UART1 + park + trap + MemCpy.
pub fn payload(spec: &BoardSpec, boot_log: &[u8]) -> Module {
    let mut m = kstart_inner(spec, Some(boot_log));
    m.rodata = boot_log.to_vec();
    m.push(memcpy_node(spec.isa.xlen, spec.rvv_live()));
    m
}

/// KStart listing / payload prefix.
///
/// Linear flow: **all harts** set tp/dtb/sp/stvec, then harts without an FDT
/// handoff (SBI-HSM secondaries, a1=opaque=0) park; the OpenSBI boot hart —
/// whichever id the lottery picked —
/// prints the boot log, `jal TimerInit` / `PlicInit` / `HartStart` / `MboxInit`
/// / `GrInit` / `ProxyScale` / `UiInit` / `FileServe` / `GetFile` / `WasmJit`, UART1 IER, park WFI. Trap
/// and init bodies sit after park (QEMU OpenSBI next-stage, all-harts entry).
pub fn kstart(spec: &BoardSpec) -> Module {
    kstart_inner(spec, None)
}

/// `boot_log` is the host boot log when one exists (`payload`), so the guest can
/// paint the very container the log shows. The listing / exec-model entry has no
/// log and falls back to the container's own header row.
fn kstart_inner(spec: &BoardSpec, boot_log: Option<&[u8]>) -> Module {
    let mut m = Module {
        nharts: spec.harts.max(1),
        line_bytes: UART_LINE_BSS,
        ..Default::default()
    };
    let mut uart = None;
    let mut park = None;
    let mut trap = None;
    let mut timer = None;
    let mut proxy = None;
    let mut gl = None;
    let mut vio = None;
    let mut vnet = None;
    let mut vblk = None;
    let mut disp = None;
    let mut pci = None;
    let mut dmux = None;
    let mut ui = None;
    let mut fileserve = None;
    let mut getfile = None;
    let mut wasm_jit = None;
    let mut plic = None;
    let mut hsm = None;
    let mut mbox = None;
    for o in live_objects(spec) {
        match o.purpose {
            Purpose::HartId => m.push(hart_id_node(o)),
            Purpose::Dtb => m.push(dtb_node(o)),
            Purpose::Satp => m.push(satp_node(o)),
            Purpose::Stack => m.push(stack_node(o)),
            Purpose::TrapVec => m.push(trap_vec_node(o)),
            Purpose::BootLog => m.push(boot_log_node(o, spec)),
            Purpose::Uart1Repl => uart = Some(o),
            Purpose::Park => park = Some(o),
            Purpose::Trap => trap = Some(o),
            Purpose::Timer => timer = Some(o),
            Purpose::DisplayProxy => proxy = Some(o),
            Purpose::GlAdapter => gl = Some(o),
            Purpose::Virtio => vio = Some(o),
            Purpose::VirtioNet => vnet = Some(o),
            Purpose::VirtioBlk => vblk = Some(o),
            Purpose::DispScan => disp = Some(o),
            Purpose::PciScan => pci = Some(o),
            Purpose::DisplayMux => dmux = Some(o),
            Purpose::FileServe => {
                ui = Some(o);
                fileserve = Some(o);
                getfile = Some(o);
            }
            Purpose::WasmJit => {
                ui = Some(o);
                fileserve = Some(o);
                getfile = Some(o);
                if spec.kernel.wasm.jit {
                    wasm_jit = Some(o);
                }
            }
            Purpose::Http => {
                if spec.kernel.http.enable {
                    getfile = Some(o);
                }
            }
            Purpose::Uncore => {
                if spec.uncore.plic {
                    plic = Some(o);
                }
            }
            Purpose::Topology => {
                if spec.harts > 1 {
                    hsm = Some(o);
                }
            }
            Purpose::Mailbox => mbox = Some(o),
            Purpose::NativeService | Purpose::LinuxHandoff => {}
            Purpose::MemCpy
            | Purpose::Reboot
            | Purpose::Tls
            | Purpose::Https
            | Purpose::SvelteUi
            | Purpose::Rsa
            | Purpose::Ecdsa
            | Purpose::Cert
            | Purpose::Hmac
            | Purpose::Endpoint
            | Purpose::BiosParam
            | Purpose::Flash
            | Purpose::Settings
            | Purpose::Usb
            | Purpose::Hypervisor
            | Purpose::Menu
            | Purpose::UiDom => {}
        }
    }
    if let Some(o) = timer {
        m.push(timer_call_node(o));
    }
    if let Some(o) = uart {
        // The UART1 presence probe must run BEFORE PlicInit arms the UART
        // irq — otherwise trap_uart's drain can take a nested access fault
        // on an absent UART1 before the flag exists (nested traps clobber
        // sepc). In normal context the probe fault recovers cleanly.
        m.push(uart1_node(o, spec));
    }
    if let Some(o) = plic {
        m.push(plic_call_node(o));
    }
    if let Some(o) = hsm {
        m.push(hsm_call_node(o));
    }
    if let Some(o) = mbox {
        m.push(mbox_call_node(o));
    }
    if let Some(o) = proxy {
        let gp = g6b_spec_proxy(spec);
        m.gr_bytes = gr_bss_len(gp.0, gp.1, spec.kernel.gr.colors.max(16));
        m.push(gr_call_node(o));
    }
    if let Some(o) = gl {
        m.push(gl_call_node(o));
    }
    // `__vio` also carries the `DispSel`/`PciProbe` result block, so the mux
    // needs it allocated even on a board with no virtio or display engine.
    if vio.is_some() || vnet.is_some() || disp.is_some() || dmux.is_some() {
        m.vio_bytes = crate::vio::VIO_BSS;
    }
    // The scanout surface itself is only allocated when something actually
    // commits it — a UART-only board must not carry an 8 MB framebuffer just
    // because the mux runs.
    if vio.is_some() || disp.is_some() {
        // `__scan_fb` must hold the largest output the runtime mux may pick,
        // not just the legacy `g6b_spec_proxy` default. `DispSel` latches the
        // winning output's geometry into `__disp`; `VioPaint`/`DispPaint` then
        // commit that surface. Sizing the buffer to the declared maximum keeps
        // every `proxy_outputs` record reachable without over-allocating on
        // UART-only boards.
        let fb = spec
            .display_outputs()
            .iter()
            .map(|o| {
                u64::from(o.w)
                    .saturating_mul(u64::from(o.h))
                    .saturating_mul(4)
            })
            .max()
            .unwrap_or(0)
            .min(crate::vio::VIO_FB_MAX);
        m.vio_fb_bytes = fb;
        m.cap_bytes = crate::vio::UI_CAP_BYTES;
    }
    if let Some(o) = vio {
        m.push(vio_call_node(o, spec));
    }
    if let Some(o) = vnet {
        m.push(vio_net_call_node(o));
    }
    // The block device is brought up next to the other transports, before
    // anything that might want to read a medium (the picker, `Blk`).
    if let Some(o) = vblk {
        m.push(blk_call_node(o));
    }
    // PciProbe runs before the mux so its result is available to the top rung,
    // and before VioScan so a failed ECAM read cannot strand the virtio lane.
    if let Some(o) = pci {
        m.push(pci_call_node(o));
    }
    // DispSel must see every probe result, so it comes after all of them and
    // before anything that paints.
    if let Some(o) = dmux {
        m.push(disp_sel_call_node(o));
    }
    // VioScan runs after the mux so the scanout rect/resource follow the
    // output `DispSel` latched, not the gen-time proxy default.
    if let Some(o) = vio {
        m.push(vio_scan_call_node(o));
    }
    // M4 virgl lane buffers: on a `virtio-gpu-gl-device` board (`proxy.gl`)
    // the execbuffer + request table are emitted here, but `VioVirgl` itself
    // is scheduled **after the paint pass** (below) — the composite's sampler
    // view binds the 2D scanout resource (id 1), so it must run only once
    // `VioPaint` has committed `__scan_fb` into `vio_fb`.
    if vio.is_some() && gl.is_some() {
        let gp = g6b_spec_proxy(spec);
        m.virgl_cmd = crate::virgl::execbuf(gp.0, gp.1);
        m.virgl_req = crate::virgl::reqtab(gp.0, gp.1);
        m.virgl_out_bytes = u64::from(gp.0) * u64::from(gp.1) * 4;
    }
    if let Some(o) = ui {
        m.ui_bytes = UI_HEADER_BYTES;
        m.ui_wasm = ui_wasm_bytes(spec).to_vec();
        m.push(ui_call_node(o));
    }
    if let Some(o) = fileserve {
        m.push(file_call_node(o));
    }
    if let Some(o) = getfile {
        m.push(get_call_node(o));
    }
    if let Some(o) = wasm_jit {
        m.push(wasm_jit_call_node(o));
    }
    // The CLI is the minimally dependent face, so it paints first — *including* on
    // a build that carries the web engine, which is what `kernel.cli.boot=auto`
    // promises. The picker is the power-on screen; the browser takes the plane when
    // an operator asks for it.
    if wants_cli_face(spec) {
        m.push(cli_call_node());
    }
    if let Some(o) = wasm_jit {
        m.push(wasm_ui_call_node(o, spec));
    }
    if spec.kernel.wasm.guest_jit {
        // Guest JIT: translate __jit_in → __jit_code, fence.i, run _start.
        // Independent of the DOM face — its evidence is the WASM-JIT markers.
        m.push(jit_call_node());
        // M2 guest DOM: seed the demo tree (idempotent — a cell that already
        // populated `__dom` via the EXT imports leaves it alone), lay it out,
        // and raster the dirty nodes into `__scan_fb`. The commit rungs below
        // (VioPaint/DispPaint/PciPaint) then present that frame.
        m.push(domt_boot_call_node(spec));
    }
    // The paint pass must run after the last __gr_plane painter (DomPaint
    // inside WasmUi, or GrInit when the DOM lane is absent): FbExpand
    // converts the plane into __scan_fb and each backend commits it —
    // TRANSFER+FLUSH to the bound virtio-gpu (VioPaint) and/or the uncore
    // display-engine register commit (DispPaint).
    if let Some(o) = vio {
        if spec.kernel.gr.enable || spec.kernel.proxy.enable {
            m.push(vio_paint_call_node(o));
        }
    }
    if let Some(o) = disp {
        m.push(disp_paint_call_node(o));
    }
    // PCIe-linear-fb commit: the blit lands in the accepted BAR directly, so
    // this runs last in the paint pass alongside the other backends (each
    // self-gates on `__disp.class`).
    if let Some(o) = pci {
        if spec.kernel.gr.enable || spec.kernel.proxy.enable {
            m.push(pci_paint_call_node(o));
        }
    }
    // M4 virgl composite — **after** the paint pass. The execbuffer's
    // sampler view binds resource 1 (the 2D scanout), so the textured quad
    // draws the frame `VioPaint` just committed into `vio_fb` onto the
    // offscreen `RES_RT`; `SET_SCANOUT(RES_RT)`+`RESOURCE_FLUSH` then move
    // the console onto the GPU-rastered surface. `VioVirgl` finishes by
    // attaching `__virgl_out` as RES_RT's guest backing and
    // TRANSFER_FROM_HOST_3D pulls the composite back into guest RAM.
    if vio.is_some() && gl.is_some() {
        if let Some(o) = vio {
            m.push(vio_gl_call_node(o));
        }
    }
    if let Some(o) = park {
        m.push(park_node(o));
    }
    if let Some(o) = trap {
        m.push(trap_node(o, spec));
        m.push(native_poll_stub());
    }
    if let Some(o) = timer {
        m.push(timer_init_node(o, spec));
    }
    if let Some(o) = plic {
        m.push(plic_init_node(o, spec));
    }
    if let Some(o) = hsm {
        m.push(hsm_init_node(o, spec));
    }
    if let Some(o) = mbox {
        m.push(mbox_init_node(o, spec));
    }
    if let Some(o) = proxy {
        m.push(gr_init_node(o, spec));
        m.push(proxy_geom_node(o, spec));
    }
    if let Some(o) = gl {
        m.push(gl_adapter_node(o, spec));
    }
    // FbExpand is shared by every scanout backend that paints the plane.
    // `FbExpand1` is its scale-1 twin for the native surface, and
    // `FbExpandSel` picks between them from the surface `DispSel` latched —
    // the pcie rung needs them too (`PciPaint` blits into the accepted BAR).
    if (vio.is_some() || disp.is_some() || pci.is_some())
        && (spec.kernel.gr.enable || spec.kernel.proxy.enable)
    {
        m.push(crate::vio::expand_node(spec));
        m.push(crate::vio::expand1_node(spec));
        m.push(crate::vio::expand_sel_node(spec));
    }
    if let Some(o) = vio {
        m.push(vio_probe_node(o));
        m.push(crate::vio::init_node(o, spec));
        m.push(crate::vio::cmd_node(spec));
        m.push(crate::vio::scan_node(spec));
        if gl.is_some() {
            // M4 virgl lane: the 3-desc SUBMIT_3D submitter + the
            // CAPSET→CTX→SUBMIT→TRANSFER→FLUSH driver (VioVirgl).
            m.push(crate::vio::cmdbuf_node(spec));
            m.push(crate::vio::virgl_node(spec));
        }
        if spec.kernel.gr.enable || spec.kernel.proxy.enable {
            m.push(crate::vio::paint_node(spec));
        }
        if spec.wants_virtio_input() {
            m.push(crate::vio::inp_init_node(o));
            m.push(crate::vio::tab_init_node(o));
            m.push(crate::vio::inp_drain_node(o));
            m.push(crate::vio::tab_drain_node(o));
            m.push(crate::vio::inp_poll_node(o, spec));
            if spec.kernel.wasm.jit {
                // DOM-input bridge — `WasmDomText` exists only under the
                // jit lane (dom::attach), so DomKey/DomNav need the same gate.
                m.push(crate::vio::dom_key_node(o, spec));
                m.push(crate::vio::dom_nav_node(o, spec));
            }
            // The CLI face consumes the same queue through its own watermark,
            // so `Keys` and the DOM navigator keep their view of the ring.
        }
    }
    if let Some(o) = vnet {
        m.push(vio_net_probe_node(o));
    }
    if let Some(o) = vblk {
        m.push(crate::vio::blk_init_node(o));
        m.push(crate::vio::blk_read_node(o));
        m.push(crate::vio::blk_write_node(o));
        m.push(crate::vio::blk_flush_node(o));
        m.push(crate::vio::fw_stage_node(o));
        m.push(crate::vio::fw_commit_node(o, spec.isa.xlen));
        m.push(crate::vio::fw_select_node(o, spec.isa.xlen));
        m.push(crate::vio::jrn_load_node(o, spec.isa.xlen));
        m.push(crate::vio::jrn_commit_node(o, spec.isa.xlen));
        m.push(crate::vio::fw_stage_selftest_node());
        m.push(crate::vio::blk_sig_node(o, spec.isa.xlen));
    }
    if disp.is_some() {
        m.push(crate::vio::disp_paint_node(spec));
    }
    if pci.is_some() {
        m.push(crate::vio::pci_probe_node(spec));
        if spec.kernel.gr.enable || spec.kernel.proxy.enable {
            m.push(crate::vio::pci_paint_node(spec));
        }
    }
    if dmux.is_some() {
        m.push(crate::vio::disp_sel_node(spec));
    }
    if let Some(o) = ui {
        m.push(ui_init_node(o, spec));
    }
    m.push(file_serve_node(spec));
    m.push(get_file_node(spec));
    if let Some(o) = wasm_jit {
        m.push(wasm_jit_node(o));
        // `attach` is a superset of the text face: it brings the same row table,
        // font and `DomPaint`, plus the wasm import shims.
        crate::dom::attach(&mut m, spec);
        if spec.kernel.wasm.guest_jit {
            // Guest-JIT substrate: `__jit*`/`__wasm_mem` BSS + the JitRun
            // translator/executor node, with an empty `__jit_in` (JitRun
            // reports `WASM-JIT-NOIMG`). `g6b-elf` installs the real image via
            // `jitr::set_image` — the predecoder lives in `g6b-wasm`, which
            // already depends on this crate.
            crate::jitr::attach(&mut m, &[]);
            // M2 guest DOM tree: `__dom`/`__dom_str` BSS + the node-arena,
            // DOM-op, layout and `__scan_fb` raster routines. The cell reaches
            // these through `env.*` EXT trampolines; `DomtBoot` seeds a demo
            // tree the input→listener→repaint gate mutates.
            crate::domt::ensure_bss(&mut m);
            for n in crate::domt::nodes(spec) {
                m.push(n);
            }
            // Packed web present: `WebBlit` decodes `__web_pk` (installed by
            // g6b-elf when the LDC lane is live) into the latched surface and
            // returns a0=1 so callers skip the text-face paint paths. `dlp`
            // adds `DlPaint`/`WebPaint` for `__web_dl` (the display-list
            // carry): call sites invoke `WebPaint`, which replays the list
            // when installed and falls back to the pixel pack otherwise.
            for n in crate::webp::nodes(spec) {
                m.push(n);
            }
            for n in crate::dlp::nodes(spec) {
                m.push(n);
            }
        }
    } else if wants_cli_face(spec) {
        // Text face only: row table + font + `DomPaint`, no wasm import shims.
        crate::dom::attach_text_face(&mut m, spec);
    }
    if wants_cli_face(spec) {
        // The interactive container (edit line + page dispatch + the picker) is
        // compiled either way — a complete build boots it first.
        for n in crate::cli::nodes(spec, boot_log) {
            m.push(n);
        }
        m.push(crate::cli::sync_node(spec));
    }
    if m.rodata.is_empty() {
        m.rodata = kstart_msg(spec);
    }
    // The BSS zero can only be sized once every block is known, and it has to run
    // *before* the rungs that read those blocks — so it is built last and inserted
    // right after the boot log, which is the first thing the handoff hart does
    // alone. (Before the park split it would be every hart's work, and after the
    // rungs it would wipe what they just set up.)
    // Two ranges, and the gaps are deliberate:
    //
    // * `__uart_line` → `__ui_dom` inclusive **must** be zeroed: these are counts,
    //   watermarks and latches (`AUTO_ON`, `CLI_DIRTY`, the DOM row count), and a
    //   stale one changes a decision rather than a pixel.
    // * `__ui_cap` is **skipped**: it is magic-guarded (`G6CP`) *and* a host may
    //   legitimately hand the guest a pre-filled compact persist before the payload
    //   runs (B91), which zeroing would throw away.
    // * `__vio` must be zeroed for the same reason as the first range — a stale
    //   `VIO_BUSY` would make every repaint skip, forever.
    // * The Gr plane body and `__scan_fb` are skipped: megabytes that each frame
    //   rewrites in full.
    let head = m
        .line_bytes
        .saturating_add(m.ui_bytes)
        .saturating_add(m.dom_bytes);
    let mut ranges: Vec<(Addr, u64)> = Vec::new();
    if head > 0 {
        ranges.push((Addr::UartLine, head));
    }
    if m.vio_bytes > 0 {
        ranges.push((Addr::VioBss, m.vio_bytes));
    }
    // `__jit`…`__wasm_mem` are contiguous (JitHdr→JitStk→JitCode→WasmMem):
    // the wasm linear memory must read zero past its data image, and a clean
    // code arena makes a stray `jalr` deterministic rather than garbage.
    let jit_bss = m
        .jit_bytes
        .saturating_add(m.jit_stk_bytes)
        .saturating_add(m.jit_code_bytes)
        .saturating_add(m.wasm_mem_bytes);
    if jit_bss > 0 {
        ranges.push((Addr::JitHdr, jit_bss));
    }
    // `__dom`/`__dom_str` are contiguous after `__wasm_mem`: the DOM tree
    // header (count/dirty/focus) must start zeroed so `DomtInit` sees a clean
    // arena rather than stale warm-boot state.
    let dom_bss = m.domt_bytes.saturating_add(m.doms_bytes);
    if dom_bss > 0 {
        ranges.push((Addr::DomT, dom_bss));
    }
    if !ranges.is_empty() {
        let at = m
            .nodes
            .iter()
            .position(|n| n.purpose == Purpose::BootLog)
            .map(|i| i + 1)
            .unwrap_or(0);
        m.nodes.insert(at, bss_zero_node(spec.isa.xlen, &ranges));
    }
    // `FatRead`/`Ext4Read` are subroutines called from `blk_call_node` and the
    // `uart_blk` trap path; they live at the end of the image so each `jal`
    // link address points back to the caller, not into the start of the fn.
    if let Some(o) = vblk {
        m.push(crate::fatfile::fat_read_node(o, spec.isa.xlen));
        m.push(crate::ext4file::ext4_read_node(o, spec.isa.xlen));
    }
    m.linux_bytes = crate::linux::LOAD_BYTES;
    let linux_off = m.extra_bss().saturating_sub(m.linux_bytes);
    m.push(crate::linux::linux_enter_node());
    m.push(crate::linux::linux_stub_node());
    m.push(crate::linux::linux_relocate_node(spec.isa.xlen, linux_off));
    if vblk.is_some() {
        m.push(crate::linux::linux_load_disk_node(spec.isa.xlen, linux_off));
    }
    m
}

/// KInts listing: trap with sepc for the rewrite of `KInterrupts.ZC`.
pub fn kints(spec: &BoardSpec) -> Module {
    let mut m = Module {
        line_bytes: UART_LINE_BSS,
        ui_bytes: if spec.kernel.wasm.enable || spec.kernel.http.files.enable {
            UI_HEADER_BYTES
        } else {
            0
        },
        ..Default::default()
    };
    let o = objects(spec)
        .into_iter()
        .find(|o| o.purpose == Purpose::Trap)
        .unwrap_or(Object {
            purpose: Purpose::Trap,
            live: true,
            why: "supervisor trap",
        });
    m.push(trap_node(o, spec));
    m.push(native_poll_stub());
    m.push(file_serve_node(spec));
    m.push(get_file_node(spec));
    m
}

/// TimerInit listing (SBI TIME). Same node as KStart.
pub fn timer(spec: &BoardSpec) -> Module {
    let mut m = Module::default();
    let o = objects(spec)
        .into_iter()
        .find(|o| o.purpose == Purpose::Timer)
        .unwrap_or(Object {
            purpose: Purpose::Timer,
            live: true,
            why: "SBI TIME",
        });
    m.push(timer_init_node(o, spec));
    m
}

/// `MemCpy` + `Reboot` listings (HolyC ISel + SBI SRST).
pub fn libcalls(spec: &BoardSpec) -> Module {
    let mut m = Module::default();
    m.push(memcpy_node(spec.isa.xlen, spec.rvv_live()));
    m.push(reboot_node());
    m
}

/// MemCpy only (ISel). Used by `g6b-holyc` wrappers and ELF payload.
pub fn memcpy(xlen: u32, rvv: bool) -> Module {
    let mut m = Module::default();
    m.push(memcpy_node(xlen, rvv));
    m
}

/// Zero the payload's BSS — every block after the stacks — before any rung reads
/// it.
///
/// **Nothing did this before**, and everything that assumed zeroed memory was
/// getting lucky. QEMU's `-kernel` loader writes `p_filesz` bytes and leaves the
/// `p_memsz` remainder as it found it, which on a real boot is whatever OpenSBI
/// used the DRAM for. The failure it produced was exact and hard to read from the
/// outside: the boot picker's `AUTO_ON`/`AUTO_DONE` words at `__uart_line+276/292`
/// came up non-zero, so `CliInit` decided the picker had already run and skipped it
/// — the complete build painted its container and never offered a boot menu, while
/// the host model (which zeroes RAM) showed the picker every time. A model that is
/// kinder than the machine hides exactly this class of bug.
///
/// The span is the **control** blocks: UART line, `G6UI`, DOM rows, compact
/// persist and the virtio rings — a few kilobytes. Deliberately *not* the Gr plane
/// body or the scanout surface: those are megabytes that every frame rewrites
/// wholesale, and zeroing them at boot would cost real time for no correctness
/// (it also blew the host model's step budget, which is a fair proxy for "this is
/// too much work to do twice"). Stacks are excluded for the same reason — they are
/// written before they are read.
fn bss_zero_node(xlen: u32, ranges: &[(Addr, u64)]) -> Node {
    let step: u64 = if xlen == 64 { 8 } else { 4 };
    let mut ops = vec![Op::Comment(format!(
        "zero {} control BSS range(s) in {step}-byte stores: the ELF loader does not, and a stale \
         AUTO_ON word once cost the boot picker",
        ranges.len()
    ))];
    for (i, (addr, bytes)) in ranges.iter().enumerate() {
        let words = bytes / step;
        let tail = bytes % step;
        let loop_label = format!("bss_zero{i}");
        let tail_label = format!("bss_zero{i}_tail");
        ops.extend([
            Op::La {
                rd: T0,
                addr: addr.clone(),
            },
            Op::Li {
                rd: T1,
                imm: words as i64,
            },
            Op::Label(loop_label.clone()),
            Op::Beq {
                rs1: T1,
                rs2: X0,
                to: tail_label.clone(),
            },
        ]);
        ops.push(if xlen == 64 {
            Op::Sd {
                rs2: X0,
                rs1: T0,
                off: 0,
            }
        } else {
            Op::Sw {
                rs2: X0,
                rs1: T0,
                off: 0,
            }
        });
        ops.extend([
            Op::Addi {
                rd: T0,
                rs: T0,
                imm: step as i32,
            },
            Op::Addi {
                rd: T1,
                rs: T1,
                imm: -1,
            },
            Op::Jal {
                rd: X0,
                to: loop_label,
            },
            Op::Label(tail_label),
        ]);
        for b in 0..tail as i32 {
            ops.push(Op::Sb {
                rs2: X0,
                rs1: T0,
                off: b,
            });
        }
    }
    Node {
        purpose: Purpose::Stack,
        ops,
    }
}

/// Reboot only (SBI SRST).
pub fn reboot() -> Module {
    let mut m = Module::default();
    m.push(reboot_node());
    m
}

/// Short KStart marker string (NUL-terminated). ELF uses the full boot log.
pub fn kstart_msg(spec: &BoardSpec) -> Vec<u8> {
    let mut s = format!(
        "KSTART-XLEN-{}\nKSTART-HARTS-{}\nKSTART-CORES-{}\nKSTART-THREADS-{}\nKSTART-ISSUE-{}\nKSTART-HART\nKSTART-SATP-BARE\nKSTART-UART0\nKSTART-UART0-8N1\nKSTART-STACK\nKSTART-STACKS-{}\nKSTART-STVEC\nKSTART-TIMER\nKMAIN\n",
        spec.isa.xlen, spec.harts, spec.cores, spec.threads, spec.geo.issue_ports, spec.harts.max(1)
    );
    if spec.smt() {
        s.push_str("KSTART-SMT\n");
    }
    if spec.geo.stream {
        s.push_str("KSTART-STREAM\n");
    }
    if spec.geo.ooo {
        s.push_str("KSTART-OOO\n");
    }
    if spec.hypervisor_live() {
        s.push_str("KSTART-H\n");
    }
    if spec.rvv_live() {
        s.push_str("KSTART-RVV\n");
    }
    if spec.kernel.proxy.enable {
        s.push_str("KSTART-PROXY\n");
    }
    if spec.uncore.plic {
        s.push_str("KSTART-PLIC\n");
    }
    if spec.harts > 1 {
        s.push_str("KSTART-HSM\n");
    }
    if spec.loopback.enable {
        s.push_str("KSTART-MBOX\n");
    }
    s.push_str("KSTART-UART-IRQ\n");
    s.push_str("KSTART-UART-LINE\n");
    s.push_str("KSTART-UART-CMD\n");
    s.push_str("KSTART-UART-VIEWSEC\n");
    s.push_str("KSTART-UART-UI\n");
    s.push_str("KSTART-UART-FILE\n");
    s.push_str("KSTART-UART-GET\n");
    if spec.kernel.gr.enable || spec.kernel.proxy.enable {
        s.push_str("KSTART-GR\n");
        s.push_str("KSTART-GR-PLANE\n");
        s.push_str("KSTART-GR-FONT\n");
    }
    if spec.kernel.proxy.enable && spec.kernel.proxy.gl {
        s.push_str("KSTART-PROXY-SCALE\n");
        match spec.proxy_accel() {
            g6b_spec::ProxyAccel::Rvv => s.push_str("KSTART-PROXY-RVV\n"),
            g6b_spec::ProxyAccel::AiIsland => s.push_str("KSTART-PROXY-AI\n"),
            g6b_spec::ProxyAccel::Off => {}
        }
    }
    if spec.kernel.wasm.enable || spec.kernel.http.files.enable {
        s.push_str("KSTART-UI\n");
        s.push_str("KSTART-FILE\n");
        s.push_str("KSTART-GET\n");
    }
    if spec.kernel.http.enable {
        s.push_str("KSTART-HTTP\n");
    }
    if spec.kernel.wasm.jit {
        s.push_str("KSTART-WASM-JIT\n");
        s.push_str("KSTART-WASM-UI\n");
        s.push_str("KSTART-DOM\n");
    }
    if wants_cli_face(spec) {
        s.push_str("KSTART-CLI\n");
    }
    s.push('\0');
    s.into_bytes()
}

/// UART0 ns16550 (QEMU virt `-nographic`). TempleOS COM1 `0x3F8` rewrite.
pub fn uart0_base(spec: &BoardSpec) -> u64 {
    spec.peripherals
        .iter()
        .find(|p| p.class == "uart")
        .and_then(|p| parse_hex(&p.base))
        .unwrap_or(0x1000_0000)
}

/// UART1 base: `uart0 + 0x1000` would land on QEMU virt's first virtio-mmio
/// transport — all 8 exist (0x1000-strided, attached or not) — so the modeled
/// second UART sits just above the window at `VIO_MMIO_BASE + 8*0x1000`
/// (`uart0 + 0x9000` on virt). QEMU virt has only one real ns16550; this
/// keeps the host-modeled dual-band face consistent with the real device map.
pub fn uart1_base(spec: &BoardSpec) -> u64 {
    let base = uart0_base(spec).wrapping_add(0x1000);
    let window_end = VIO_MMIO_BASE + (VIO_MMIO_SLOTS as u64) * VIO_MMIO_STEP;
    if base >= VIO_MMIO_BASE && base < window_end {
        window_end
    } else {
        base
    }
}

fn hart_id_node(o: Object) -> Node {
    Node {
        purpose: Purpose::HartId,
        ops: vec![
            Op::Directive(".section .text.start".into()),
            Op::Comment(format!(
                "KStart rewrite — S-mode, OpenSBI a0=hartid a1=dtb. {}",
                o.why
            )),
            Op::Glob("_start".into()),
            Op::Label("_start".into()),
            Op::Addi {
                rd: TP,
                rs: A0,
                imm: 0,
            },
        ],
    }
}

fn dtb_node(o: Object) -> Node {
    Node {
        purpose: Purpose::Dtb,
        ops: vec![
            Op::Comment(o.why.into()),
            Op::Addi {
                rd: S1,
                rs: A1,
                imm: 0,
            },
        ],
    }
}

fn satp_node(o: Object) -> Node {
    Node {
        purpose: Purpose::Satp,
        ops: vec![
            Op::Comment(o.why.into()),
            Op::Csrrw {
                rd: X0,
                csr: CSR_SATP,
                rs: X0,
            },
            Op::SfenceVma,
        ],
    }
}

/// Per-hart stack: `sp = __stacks_end - hartid*STACK_BYTES`.
///
/// `sp` must be the **top** of the hart's own slot, so the first push lands
/// inside that slot and the deepest legal frame stops at `__stacks_end -
/// nharts*STACK_BYTES`, which is exactly the end of the image. Subtracting one
/// extra `STACK_BYTES` (giving each hart the *bottom* of its slot) makes the
/// very first push write **below** the stacks: on a single-hart image that is
/// the tail of `.rodata` — the `__font` glyph table — so long text painted
/// garbage for high glyph indices, and on a multi-hart image hart 0 quietly ate
/// hart 1's stack.
fn stack_node(o: Object) -> Node {
    Node {
        purpose: Purpose::Stack,
        ops: vec![
            Op::Comment(format!(
                "{} ({STACK_BYTES} bytes each; sp = __stacks_end - hartid*{STACK_BYTES} \
                 (top of this hart's slot))",
                o.why
            )),
            Op::La {
                rd: T2,
                addr: Addr::StacksEnd,
            },
            Op::Slli {
                rd: T1,
                rs: TP,
                shamt: STACK_SHIFT,
            },
            Op::Sub {
                rd: SP,
                rs1: T2,
                rs2: T1,
            },
        ],
    }
}

fn trap_vec_node(o: Object) -> Node {
    Node {
        purpose: Purpose::TrapVec,
        ops: vec![
            Op::Comment(o.why.into()),
            Op::La {
                rd: T2,
                addr: Addr::Label("trap".into()),
            },
            Op::Csrrw {
                rd: X0,
                csr: CSR_STVEC,
                rs: T2,
            },
        ],
    }
}

fn boot_log_node(o: Object, spec: &BoardSpec) -> Node {
    let uart0 = uart0_base(spec);
    Node {
        purpose: Purpose::BootLog,
        ops: vec![
            Op::Comment(format!("{} @ uart0 {uart0:#x}", o.why)),
            // Primary = the hart OpenSBI handed off to (a1=fdt, nonzero — the
            // boot-hart lottery may pick any hart id). Harts started later via
            // SBI HSM enter `_start` with a1=opaque=0 and park here.
            Op::Beq {
                rs1: S1,
                rs2: X0,
                to: "park".into(),
            },
            Op::La {
                rd: A1,
                addr: Addr::Rodata,
            },
            Op::La {
                rd: T0,
                addr: Addr::Abs(uart0),
            },
            Op::Comment("ns16550 8N1: IER=0 LCR=8N1 FCR=FIFO MCR=DTR|RTS (not 0x3F8)".into()),
            Op::Sb {
                rs2: X0,
                rs1: T0,
                off: 1,
            },
            Op::Li { rd: T1, imm: 3 },
            Op::Sb {
                rs2: T1,
                rs1: T0,
                off: 3,
            },
            Op::Li { rd: T1, imm: 7 },
            Op::Sb {
                rs2: T1,
                rs1: T0,
                off: 2,
            },
            Op::Li { rd: T1, imm: 3 },
            Op::Sb {
                rs2: T1,
                rs1: T0,
                off: 4,
            },
            Op::Label("put".into()),
            Op::Lbu {
                rd: A0,
                rs: A1,
                off: 0,
            },
            Op::Beq {
                rs1: A0,
                rs2: X0,
                to: "after".into(),
            },
            Op::Label("uart0_tx".into()),
            Op::Lbu {
                rd: T1,
                rs: T0,
                off: 5,
            },
            Op::Andi {
                rd: T1,
                rs: T1,
                imm: 0x20,
            },
            Op::Beq {
                rs1: T1,
                rs2: X0,
                to: "uart0_tx".into(),
            },
            Op::Sb {
                rs2: A0,
                rs1: T0,
                off: 0,
            },
            Op::Li {
                rd: A7,
                imm: SBI_PUTCHAR,
            },
            Op::Ecall,
            Op::Addi {
                rd: A1,
                rs: A1,
                imm: 1,
            },
            Op::Jal {
                rd: X0,
                to: "put".into(),
            },
            Op::Label("after".into()),
            Op::Comment("ns16550 IER.ERBFI — PLIC irq 1 RX (trap_uart), not a poll".into()),
            Op::Li {
                rd: T1,
                imm: UART_IER_RX,
            },
            Op::Sb {
                rs2: T1,
                rs1: T0,
                off: 1,
            },
        ],
    }
}

fn uart1_node(o: Object, spec: &BoardSpec) -> Node {
    let base = uart1_base(spec);
    let mut ops = vec![
        Op::Comment(format!(
            "{} @ {base:#x} — probe LSR (fault→absent via trap window) then IER.ERBFI",
            o.why
        )),
        Op::La {
            rd: T0,
            addr: Addr::Abs(base),
        },
        // Probe read: on stock QEMU virt the UART1 window is unmapped — the
        // store of any IER byte would fault. trap_fault marks UART1_DEAD and
        // resumes at the next insn; the flag gates both these writes and the
        // trap_uart drain.
        Op::Li { rd: T1, imm: 0 },
        Op::Lbu {
            rd: T1,
            rs: T0,
            off: 5,
        },
        Op::La {
            rd: T2,
            addr: Addr::UartLine,
        },
        Op::Lbu {
            rd: T2,
            rs: T2,
            off: UART1_DEAD_OFF as i32,
        },
        Op::Bne {
            rs1: T2,
            rs2: X0,
            to: "u1_absent".into(),
        },
        Op::La {
            rd: T0,
            addr: Addr::Abs(base),
        },
        Op::Sb {
            rs2: X0,
            rs1: T0,
            off: 1,
        },
        Op::Li { rd: T1, imm: 3 },
        Op::Sb {
            rs2: T1,
            rs1: T0,
            off: 3,
        },
        Op::Li { rd: T1, imm: 7 },
        Op::Sb {
            rs2: T1,
            rs1: T0,
            off: 2,
        },
        Op::Li { rd: T1, imm: 3 },
        Op::Sb {
            rs2: T1,
            rs1: T0,
            off: 4,
        },
        Op::Li {
            rd: T1,
            imm: UART_IER_RX,
        },
        Op::Sb {
            rs2: T1,
            rs1: T0,
            off: 1,
        },
        Op::Jal {
            rd: X0,
            to: "u1_done".into(),
        },
        Op::Label("u1_absent".into()),
    ];
    for ch in b"UART1-NONE\n" {
        ops.extend(putc_ops(i64::from(*ch)));
    }
    ops.push(Op::Label("u1_done".into()));
    Node {
        purpose: Purpose::Uart1Repl,
        ops,
    }
}

fn park_node(o: Object) -> Node {
    let ops = vec![
        Op::Comment(o.why.into()),
        Op::Label("park".into()),
        Op::Wfi,
        Op::Jal {
            rd: X0,
            to: "park".into(),
        },
    ];
    Node {
        purpose: Purpose::Park,
        ops,
    }
}

fn timer_interval(spec: &BoardSpec) -> i64 {
    let fps = u64::from(spec.kernel.proxy.refresh_hz().max(1));
    (crate::encode::TIMEBASE_HZ / fps) as i64
}

fn mbox_call_node(o: Object) -> Node {
    Node {
        purpose: Purpose::Mailbox,
        ops: vec![
            Op::Comment(format!("{} — jal MboxInit", o.why)),
            Op::Jal {
                rd: RA,
                to: "MboxInit".into(),
            },
        ],
    }
}

fn mbox_init_node(o: Object, spec: &BoardSpec) -> Node {
    let base = parse_hex(&spec.loopback.base).unwrap_or(0x1010_0000);
    let mut ops = vec![
        Op::Comment(format!(
            "{} @ {base:#x} irq {} — doorbell write+readback probe; absent → MBOX-NONE",
            o.why, spec.loopback.irq
        )),
        Op::Glob("MboxInit".into()),
        Op::Label("MboxInit".into()),
        Op::La {
            rd: T0,
            addr: Addr::Abs(base),
        },
        Op::Li {
            rd: T1,
            imm: i64::from(MBOX_MAGIC),
        },
        // The store may fault on a fully-unmapped window (trap window marks
        // MBOX_DEAD and resumes); on QEMU virt the address is the fw_cfg
        // region — the write is absorbed but never echoes back.
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: MBOX_OFF_DOORBELL as i32,
        },
        Op::Li { rd: T2, imm: 0 },
        Op::Lw {
            rd: T2,
            rs: T0,
            off: MBOX_OFF_DOORBELL as i32,
        },
        Op::Bne {
            rs1: T2,
            rs2: T1,
            to: "mb_none".into(),
        },
        Op::Sw {
            rs2: X0,
            rs1: T0,
            off: MBOX_OFF_STATUS as i32,
        },
        Op::Li { rd: T1, imm: 1 },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: MBOX_OFF_IRQ_EN as i32,
        },
    ];
    for ch in b"MBOX-OK\n" {
        ops.extend(putc_ops(i64::from(*ch)));
    }
    ops.extend([
        Op::Jalr {
            rd: X0,
            rs: RA,
            imm: 0,
        },
        Op::Label("mb_none".into()),
    ]);
    for ch in b"MBOX-NONE\n" {
        ops.extend(putc_ops(i64::from(*ch)));
    }
    ops.push(Op::Jalr {
        rd: X0,
        rs: RA,
        imm: 0,
    });
    Node {
        purpose: Purpose::Mailbox,
        ops,
    }
}

fn hsm_call_node(o: Object) -> Node {
    Node {
        purpose: Purpose::Topology,
        ops: vec![
            Op::Comment(format!("{} — jal HartStart (SBI HSM+IPI)", o.why)),
            Op::Jal {
                rd: RA,
                to: "HartStart".into(),
            },
        ],
    }
}

fn hsm_init_node(o: Object, spec: &BoardSpec) -> Node {
    let n = i64::from(spec.harts.max(1));
    // The primary is whichever hart OpenSBI handed off to (tp = a0 = its
    // hartid), so start every hart except self and IPI that same set.
    let all = (1i64 << n) - 1;
    Node {
        purpose: Purpose::Topology,
        ops: vec![
            Op::Comment(o.why.into()),
            Op::Glob("HartStart".into()),
            Op::Label("HartStart".into()),
            Op::Li {
                rd: T0,
                imm: SIE_SSIE,
            },
            Op::Csrrs {
                rd: X0,
                csr: CSR_SIE,
                rs: T0,
            },
            Op::Li { rd: T0, imm: 0 },
            Op::Label("hsm_loop".into()),
            Op::Li { rd: T1, imm: n },
            Op::Beq {
                rs1: T0,
                rs2: T1,
                to: "hsm_ipi".into(),
            },
            Op::Beq {
                rs1: T0,
                rs2: TP,
                to: "hsm_next".into(),
            },
            Op::Addi {
                rd: A0,
                rs: T0,
                imm: 0,
            },
            Op::La {
                rd: A1,
                addr: Addr::Label("_start".into()),
            },
            Op::Li { rd: A2, imm: 0 },
            Op::Li { rd: A6, imm: 0 },
            Op::Li {
                rd: A7,
                imm: SBI_HSM_EID,
            },
            Op::Ecall,
            Op::Label("hsm_next".into()),
            Op::Addi {
                rd: T0,
                rs: T0,
                imm: 1,
            },
            Op::Jal {
                rd: X0,
                to: "hsm_loop".into(),
            },
            Op::Label("hsm_ipi".into()),
            // hart_mask = all ^ (1<<tp) — every hart except the primary.
            Op::Li { rd: T2, imm: all },
            Op::Li { rd: T3, imm: 1 },
            Op::Addi {
                rd: T4,
                rs: TP,
                imm: 0,
            },
            Op::Label("hsm_sh".into()),
            Op::Beq {
                rs1: T4,
                rs2: X0,
                to: "hsm_mask".into(),
            },
            Op::Slli {
                rd: T3,
                rs: T3,
                shamt: 1,
            },
            Op::Addi {
                rd: T4,
                rs: T4,
                imm: -1,
            },
            Op::Jal {
                rd: X0,
                to: "hsm_sh".into(),
            },
            Op::Label("hsm_mask".into()),
            Op::Xor {
                rd: T2,
                rs1: T2,
                rs2: T3,
            },
            Op::Addi {
                rd: A0,
                rs: T2,
                imm: 0,
            },
            Op::Li { rd: A1, imm: 0 },
            Op::Li { rd: A6, imm: 0 },
            Op::Li {
                rd: A7,
                imm: SBI_IPI_EID,
            },
            Op::Ecall,
            Op::Jalr {
                rd: X0,
                rs: RA,
                imm: 0,
            },
        ],
    }
}

fn plic_call_node(o: Object) -> Node {
    Node {
        purpose: Purpose::Uncore,
        ops: vec![
            Op::Comment(format!("{} — jal PlicInit (S-mode ctx1)", o.why)),
            Op::Jal {
                rd: RA,
                to: "PlicInit".into(),
            },
        ],
    }
}

fn plic_init_node(o: Object, spec: &BoardSpec) -> Node {
    let uart_irq = UART_IRQ;
    let mbox_irq = i64::from(spec.loopback.irq.max(1));
    // QEMU virt: virtio-mmio slot i → PLIC irq 1+i (DTB `interrupts =
    // <1+i>`); enable the whole 8-slot range (1..=8) — unattached slots
    // never drive a line.
    let vio_irqs = if spec.wants_virtio_gpu() || spec.wants_virtio_net() {
        0xFFi64 << 1
    } else {
        0
    };
    let enable = (1i64 << uart_irq) | (1i64 << mbox_irq) | vio_irqs;
    // A PLIC source with priority 0 never asserts — QEMU reset value is 0,
    // so every enabled source needs an explicit nonzero priority.
    let mut prio: Vec<i64> = vec![uart_irq, mbox_irq];
    if spec.wants_virtio_gpu() || spec.wants_virtio_net() {
        prio.extend(1..=8);
    }
    prio.sort_unstable();
    prio.dedup();
    let mut ops = vec![
        Op::Comment(o.why.into()),
        Op::Glob("PlicInit".into()),
        Op::Label("PlicInit".into()),
        Op::La {
            rd: T0,
            addr: Addr::Abs(PLIC_BASE),
        },
        Op::Li { rd: T1, imm: 1 },
    ];
    for irq in &prio {
        ops.push(Op::Sw {
            rs2: T1,
            rs1: T0,
            off: (*irq * 4) as i32,
        });
    }
    ops.extend([
        Op::Comment("source priorities set; S-mode ctx = 2*tp+1 next".into()),
        // S-mode context for the *running* hart: ctx = 2*tp + 1 (the boot
        // hart is not always hart 0 — OpenSBI's lottery picks).
        Op::Slli {
            rd: T2,
            rs: TP,
            shamt: 1,
        },
        Op::Addi {
            rd: T2,
            rs: T2,
            imm: 1,
        },
        // enable block = PLIC_ENABLE_BASE + ctx*0x80
        Op::La {
            rd: T0,
            addr: Addr::Abs(PLIC_ENABLE_BASE),
        },
        Op::Slli {
            rd: T3,
            rs: T2,
            shamt: 7,
        },
        Op::Add {
            rd: T0,
            rs1: T0,
            rs2: T3,
        },
        Op::Li {
            rd: T1,
            imm: enable,
        },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: 0,
        },
        // threshold page = PLIC_CTXT_BASE + ctx*0x1000
        Op::La {
            rd: T0,
            addr: Addr::Abs(PLIC_CTXT_BASE),
        },
        Op::Slli {
            rd: T3,
            rs: T2,
            shamt: 12,
        },
        Op::Add {
            rd: T0,
            rs1: T0,
            rs2: T3,
        },
        Op::Sw {
            rs2: X0,
            rs1: T0,
            off: 0,
        },
        Op::Li {
            rd: T0,
            imm: SIE_SEIE,
        },
        Op::Csrrs {
            rd: X0,
            csr: CSR_SIE,
            rs: T0,
        },
        Op::Jalr {
            rd: X0,
            rs: RA,
            imm: 0,
        },
    ]);
    Node {
        purpose: Purpose::Uncore,
        ops,
    }
}

fn timer_call_node(o: Object) -> Node {
    Node {
        purpose: Purpose::Timer,
        ops: vec![
            Op::Comment(format!(
                "{} — jal before park/uart (not fall-through)",
                o.why
            )),
            Op::Jal {
                rd: RA,
                to: "TimerInit".into(),
            },
        ],
    }
}

fn store_op(xlen: u32, rs2: u32, rs1: u32, off: i32) -> Op {
    if xlen == 64 {
        Op::Sd { rs2, rs1, off }
    } else {
        Op::Sw { rs2, rs1, off }
    }
}

fn load_op(xlen: u32, rd: u32, rs: u32, off: i32) -> Op {
    if xlen == 64 {
        Op::Ld { rd, rs, off }
    } else {
        Op::Lw { rd, rs, off }
    }
}

/// No-op tick poll when no native callee is composed. `g6b-elf` replaces
/// this node with a `jalr` of the durable `__native_abi` frame.
fn native_poll_stub() -> Node {
    Node {
        purpose: Purpose::NativeService,
        ops: vec![
            Op::Label("NativePoll".into()),
            Op::Comment("no native callee — tick Poll is a no-op".into()),
            Op::Jalr {
                rd: X0,
                rs: RA,
                imm: 0,
            },
        ],
    }
}

fn trap_node(o: Object, spec: &BoardSpec) -> Node {
    let irq = spec.loopback.irq;
    let xlen = spec.isa.xlen;
    let shamt = xlen.saturating_sub(1);
    let slot = if xlen == 64 { 8i32 } else { 4i32 };
    // The frame saves the full caller-clobberable set: ra + t0..t6 +
    // a0..a7. Trap-context `jal`s (DomNav/DomPaint/VioPaint/InpDrain/…)
    // overwrite ra and every t/a register — an irq landing mid-`VioCmd`
    // (its wfi) must not destroy the interrupted transaction's registers.
    // s0..s11/gp/tp are callee-saved and trap-called code preserves them.
    let frame = slot * 16;
    let saves = [
        (RA, 0i32),
        (T0, 1),
        (T1, 2),
        (T2, 3),
        (T3, 4),
        (T4, 5),
        (T5, 6),
        (T6, 7),
        (A0, 8),
        (A1, 9),
        (A2, 10),
        (A3, 11),
        (A4, 12),
        (A5, 13),
        (A6, 14),
        (A7, 15),
    ];
    let mut ops = vec![
        Op::Comment(format!(
            "{} — PLIC irq {irq}; UART irq 1; scause interrupt-bit + code 5 (Priv ch3)",
            o.why
        )),
        Op::Glob("trap".into()),
        Op::Label("trap".into()),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: -frame,
        },
    ];
    for (r, i) in saves {
        ops.push(store_op(xlen, r, SP, i * slot));
    }
    ops.extend([
        Op::Csrrs {
            rd: T0,
            csr: CSR_SCAUSE,
            rs: X0,
        },
        Op::Csrrs {
            rd: T1,
            csr: CSR_SEPC,
            rs: X0,
        },
        Op::Srli {
            rd: T2,
            rs: T0,
            shamt,
        },
        Op::Beq {
            rs1: T2,
            rs2: X0,
            to: "trap_fault".into(),
        },
        Op::Andi {
            rd: T2,
            rs: T0,
            imm: 0x1f,
        },
        Op::Li { rd: A2, imm: 5 },
        Op::Beq {
            rs1: T2,
            rs2: A2,
            to: "trap_timer".into(),
        },
        Op::Li { rd: A2, imm: 1 },
        Op::Beq {
            rs1: T2,
            rs2: A2,
            to: "trap_ssi".into(),
        },
        Op::Li { rd: A2, imm: 9 },
        Op::Bne {
            rs1: T2,
            rs2: A2,
            to: "trap_fault".into(),
        },
        Op::Label("trap_sei".into()),
        Op::Comment("supervisor external interrupt → PLIC claim/complete (not x86 EOI)".into()),
        // claim = PLIC_CTXT_BASE + (2*tp + 1)*0x1000 + 4 — the S-mode context
        // of the hart running the trap, not a fixed hart-0 context.
        Op::Slli {
            rd: T1,
            rs: TP,
            shamt: 1,
        },
        Op::Addi {
            rd: T1,
            rs: T1,
            imm: 1,
        },
        Op::Slli {
            rd: T1,
            rs: T1,
            shamt: 12,
        },
        Op::La {
            rd: T0,
            addr: Addr::Abs(PLIC_CTXT_BASE + 4),
        },
        Op::Add {
            rd: T0,
            rs1: T0,
            rs2: T1,
        },
        Op::Lw {
            rd: T2,
            rs: T0,
            off: 0,
        },
        Op::Beq {
            rs1: T2,
            rs2: X0,
            to: "trap_done".into(),
        },
        Op::Sw {
            rs2: T2,
            rs1: T0,
            off: 0,
        },
        Op::Li {
            rd: T1,
            imm: UART_IRQ,
        },
        Op::Beq {
            rs1: T2,
            rs2: T1,
            to: "trap_uart".into(),
        },
    ]);
    if spec.loopback.enable {
        ops.extend([
            Op::Li {
                rd: T1,
                imm: i64::from(irq),
            },
            Op::Beq {
                rs1: T2,
                rs2: T1,
                to: "trap_mbox".into(),
            },
        ]);
    }
    if spec.wants_virtio_gpu() {
        // virtio-mmio irq = 16 + (dev - VIO_MMIO_BASE)/0x1000; the bound
        // device base is at __vio+VIO_DEV_OFF (0 → nothing claimed yet).
        ops.extend([
            Op::Comment("virtio-mmio PLIC source: irq 16 + mmio slot".into()),
            Op::La {
                rd: T0,
                addr: Addr::VioBss,
            },
            Op::Lw {
                rd: T1,
                rs: T0,
                off: crate::vio::VIO_DEV_OFF,
            },
            Op::Beq {
                rs1: T1,
                rs2: X0,
                to: "trap_vio_ack".into(),
            },
            Op::Li {
                rd: A2,
                imm: VIO_MMIO_BASE as i64,
            },
            Op::Sub {
                rd: T1,
                rs1: T1,
                rs2: A2,
            },
            Op::Srli {
                rd: T1,
                rs: T1,
                shamt: 12, // VIO_MMIO_STEP
            },
            Op::Addi {
                rd: T1,
                rs: T1,
                imm: crate::vio::VIO_IRQ_BASE as i32,
            },
            Op::Beq {
                rs1: T2,
                rs2: T1,
                to: "trap_vio".into(),
            },
        ]);
        if spec.wants_virtio_input() {
            // Same irq = 1+slot mapping for virtio-input devices; keyboard
            // base is at __vio+VIO_INP_OFF, tablet at VIO_TAB_OFF (0 when
            // that slot was not probed).
            ops.extend([
                Op::Comment("virtio-input PLIC source: irq 1 + keyboard slot".into()),
                Op::Lw {
                    rd: T1,
                    rs: T0,
                    off: crate::vio::VIO_INP_OFF,
                },
                Op::Beq {
                    rs1: T1,
                    rs2: X0,
                    to: "trap_tab_chk".into(),
                },
                Op::Li {
                    rd: A2,
                    imm: VIO_MMIO_BASE as i64,
                },
                Op::Sub {
                    rd: T1,
                    rs1: T1,
                    rs2: A2,
                },
                Op::Srli {
                    rd: T1,
                    rs: T1,
                    shamt: 12,
                },
                Op::Addi {
                    rd: T1,
                    rs: T1,
                    imm: crate::vio::VIO_IRQ_BASE as i32,
                },
                Op::Beq {
                    rs1: T2,
                    rs2: T1,
                    to: "trap_inp".into(),
                },
                Op::Label("trap_tab_chk".into()),
                Op::Comment("virtio-tablet PLIC source: irq 1 + tablet slot".into()),
                Op::Lw {
                    rd: T1,
                    rs: T0,
                    off: crate::vio::VIO_TAB_OFF,
                },
                Op::Beq {
                    rs1: T1,
                    rs2: X0,
                    to: "trap_vio_ack".into(),
                },
                Op::Li {
                    rd: A2,
                    imm: VIO_MMIO_BASE as i64,
                },
                Op::Sub {
                    rd: T1,
                    rs1: T1,
                    rs2: A2,
                },
                Op::Srli {
                    rd: T1,
                    rs: T1,
                    shamt: 12,
                },
                Op::Addi {
                    rd: T1,
                    rs: T1,
                    imm: crate::vio::VIO_IRQ_BASE as i32,
                },
                Op::Beq {
                    rs1: T2,
                    rs2: T1,
                    to: "trap_tab".into(),
                },
            ]);
        }
    }
    if spec.wants_virtio_gpu() {
        // An unrecognized source in the **virtio-mmio range** still has to be
        // acked *at the device*, not only completed at the PLIC.
        //
        // This is a real starvation bug, found on QEMU: attach two
        // `virtio-blk-device`s next to the GPU and keyboard and keystrokes stop
        // arriving, while both devices still probe `OK`. A virtio-mmio interrupt
        // is level-triggered — completing the PLIC claim does not lower the
        // device's line, so a device this BIOS has no driver for re-asserts
        // immediately and the hart spends every cycle re-entering `trap_sei`.
        // Reading `InterruptStatus` and writing it back to `InterruptACK` is what
        // a driver owes the bus, even for a device it does not use.
        ops.extend([
            Op::Label("trap_vio_ack".into()),
            Op::Comment(
                "unhandled virtio-mmio source: ack the device ISR too, or a \
                 level-triggered device we have no driver for storms the hart"
                    .into(),
            ),
            // Only the virtio window: irq = VIO_IRQ_BASE..VIO_IRQ_BASE+SLOTS.
            Op::Addi {
                rd: T1,
                rs: T2,
                imm: -(crate::vio::VIO_IRQ_BASE as i32),
            },
            Op::Srli {
                rd: A2,
                rs: T1,
                shamt: xlen.saturating_sub(1),
            },
            Op::Bne {
                rs1: A2,
                rs2: X0,
                to: "trap_done".into(),
            },
            Op::Li {
                rd: A2,
                imm: VIO_MMIO_SLOTS,
            },
            Op::Sub {
                rd: A2,
                rs1: T1,
                rs2: A2,
            },
            Op::Srli {
                rd: A2,
                rs: A2,
                shamt: xlen.saturating_sub(1),
            },
            Op::Beq {
                rs1: A2,
                rs2: X0,
                to: "trap_done".into(),
            },
            // base = VIO_MMIO_BASE + slot * VIO_MMIO_STEP
            Op::Li {
                rd: A2,
                imm: VIO_MMIO_STEP as i64,
            },
            Op::Mul {
                rd: T1,
                rs1: T1,
                rs2: A2,
            },
            Op::Li {
                rd: A2,
                imm: VIO_MMIO_BASE as i64,
            },
            Op::Add {
                rd: T1,
                rs1: T1,
                rs2: A2,
            },
            Op::Lw {
                rd: A0,
                rs: T1,
                off: crate::encode::VIO_REG_ISR_STATUS,
            },
            Op::Sw {
                rs2: A0,
                rs1: T1,
                off: crate::encode::VIO_REG_ISR_ACK,
            },
        ]);
    }
    ops.push(Op::Jal {
        rd: X0,
        to: "trap_done".into(),
    });
    ops.extend(trap_uart_ops(spec));
    if spec.loopback.enable {
        ops.extend(trap_mbox_ops(spec));
    }
    if spec.wants_virtio_gpu() {
        // trap_vio — virtio used-buffer irq: read InterruptStatus, write it
        // to InterruptACK (clears the device level so it does not storm),
        // bump __vio+VIO_IRQF_OFF, done. t0 still holds __vio.
        ops.extend([
            Op::Label("trap_vio".into()),
            Op::Lw {
                rd: T1,
                rs: T0,
                off: crate::vio::VIO_DEV_OFF,
            },
            Op::Lw {
                rd: A0,
                rs: T1,
                off: crate::encode::VIO_REG_ISR_STATUS,
            },
            Op::Sw {
                rs2: A0,
                rs1: T1,
                off: crate::encode::VIO_REG_ISR_ACK,
            },
            Op::Lw {
                rd: A0,
                rs: T0,
                off: crate::vio::VIO_IRQF_OFF,
            },
            Op::Addi {
                rd: A0,
                rs: A0,
                imm: 1,
            },
            Op::Sw {
                rs2: A0,
                rs1: T0,
                off: crate::vio::VIO_IRQF_OFF,
            },
            Op::Jal {
                rd: X0,
                to: "trap_done".into(),
            },
        ]);
        if spec.wants_virtio_input() {
            // trap_inp — virtio-input eventq used-buffer irq: read+ack the
            // device ISR, drain events into the bounded key queue.
            ops.extend([
                Op::Label("trap_inp".into()),
                Op::Lw {
                    rd: T1,
                    rs: T0,
                    off: crate::vio::VIO_INP_OFF,
                },
                Op::Lw {
                    rd: A0,
                    rs: T1,
                    off: crate::encode::VIO_REG_ISR_STATUS,
                },
                Op::Sw {
                    rs2: A0,
                    rs1: T1,
                    off: crate::encode::VIO_REG_ISR_ACK,
                },
                Op::Comment(
                    "jal InpDrain — clobbers ra like the DomPaint trap call; \
                     the parked/WFI context keeps ra dead"
                        .into(),
                ),
                Op::Jal {
                    rd: RA,
                    to: "InpDrain".into(),
                },
            ]);
            if spec.kernel.wasm.jit {
                // DOM-input bridge: DomNav consumes new queue entries as menu
                // input (arrows → nav.sel, Enter → open; watermark scan —
                // the physical ring stays for the Keys dump), then DomKey
                // mirrors the newest key into `inp.last`. No repaint in irq
                // context — the frame is pushed by an explicit Keys/Ui
                // refresh (like a browser input event vs its next frame).
                // A keystroke belongs to whichever face owns the screen. Feeding
                // both would move the picker's marker *and* the browser's menu on
                // one press — two faces reacting to one key is not a UI.
                if faces_share_plane(spec) {
                    ops.extend(face_is(crate::FACE_WEB, "inp_face_cli"));
                }
                ops.push(Op::Jal {
                    rd: RA,
                    to: "DomNav".into(),
                });
                ops.push(Op::Jal {
                    rd: RA,
                    to: "DomKey".into(),
                });
                if spec.kernel.wasm.guest_jit {
                    // M2 tree-DOM: the same key press also reaches the guest
                    // DOM's focused-node listener (`DomtKey` → `DomtDemo`),
                    // which mutates the tree and bumps `__dom` H_DIRTY so the
                    // `trap_timer` tick repaints. Own `DOMT_SEEN` watermark —
                    // DomNav/DomKey keep theirs.
                    ops.push(Op::Jal {
                        rd: RA,
                        to: "DomtKey".into(),
                    });
                }
                if faces_share_plane(spec) {
                    ops.push(Op::Jal {
                        rd: X0,
                        to: "inp_face_done".into(),
                    });
                    ops.push(Op::Label("inp_face_cli".into()));
                }
            }
            if wants_cli_face(spec) {
                // zealcli: the keystroke edits the line and may dispatch a
                // command. Still no paint in irq context — `CliKey` bumps
                // `CLI_DIRTY` and the timer tick flushes the frame.
                ops.push(Op::Jal {
                    rd: RA,
                    to: "CliKey".into(),
                });
            }
            if faces_share_plane(spec) {
                ops.push(Op::Label("inp_face_done".into()));
            }
            ops.push(Op::Jal {
                rd: X0,
                to: "trap_done".into(),
            });
            ops.extend([
                Op::Label("trap_tab".into()),
                Op::Lw {
                    rd: T1,
                    rs: T0,
                    off: crate::vio::VIO_TAB_OFF,
                },
                Op::Lw {
                    rd: A0,
                    rs: T1,
                    off: crate::encode::VIO_REG_ISR_STATUS,
                },
                Op::Sw {
                    rs2: A0,
                    rs1: T1,
                    off: crate::encode::VIO_REG_ISR_ACK,
                },
                Op::Jal {
                    rd: RA,
                    to: "TabDrain".into(),
                },
            ]);
            if spec.kernel.wasm.guest_jit {
                // M2 tree-DOM pointer: `TabDrain` latched MOVE/WHEEL/CLICK
                // plus the last `PTR_X`/`PTR_Y`; `DomtPtr` scales them to
                // display px, hit-tests `__dom` and re-enters hover/move/
                // wheel/click listeners (`JitCall`), bumping `H_DIRTY` for
                // the `trap_timer` repaint.
                ops.push(Op::Jal {
                    rd: RA,
                    to: "DomtPtr".into(),
                });
            }
            ops.push(Op::Jal {
                rd: X0,
                to: "trap_done".into(),
            });
        }
    }
    ops.extend([
        Op::Label("trap_ssi".into()),
        Op::Comment("supervisor software interrupt — SBI IPI wake from wfi".into()),
        Op::Jal {
            rd: X0,
            to: "trap_done".into(),
        },
        Op::Label("trap_timer".into()),
        Op::Comment("supervisor timer interrupt → rdtime + SBI TIME set_timer".into()),
        Op::Csrrs {
            rd: A0,
            csr: CSR_TIME,
            rs: X0,
        },
        Op::Li {
            rd: T0,
            imm: timer_interval(spec),
        },
        Op::Add {
            rd: A0,
            rs1: A0,
            rs2: T0,
        },
        Op::Li { rd: A6, imm: 0 },
        Op::Li {
            rd: A7,
            imm: SBI_TIME_EID,
        },
        Op::Ecall,
    ]);
    if spec.kernel.wasm.jit {
        // Background frame + await poll on the periodic tick: resolve a
        // pending Await, then repaint only when the DOM dirty counter moved
        // since the last tick-covered paint (the DOM_PAINTED watermark).
        // This is the "doesn't block on DOM events" half: input/mutation
        // stay on their own irqs, frames flush here.
        if faces_share_plane(spec) {
            // Whose tick is this? The container's countdown and the browser's
            // repaint are different work on the same timer.
            ops.extend(face_is(crate::FACE_WEB, "tick_face_cli"));
        }
        ops.extend([Op::Jal {
            rd: RA,
            to: "DomAwait".into(),
        }]);
        // `__prom` settle pass: `PromDrain` fulfills pending fetches whose
        // `KernelGet` lands, rescans pending combinators, rejects expired ones,
        // and raises `P_RESUME` when a suspended `_start`'s promise settled.
        // Only on the guest-jit lane (the `__prom` table exists when Domt* do).
        if spec.kernel.wasm.guest_jit {
            ops.push(Op::Jal {
                rd: RA,
                to: "PromDrain".into(),
            });
            // Resume a suspended `_start` whose promise just settled. `wfi`
            // re-executes on every interrupt (`sepc` points at the `wfi`), so
            // the `park` foreground never runs a post-wake check — the resume
            // must live here in trap context, the same `JitCall`-from-IRQ seam
            // the input listeners use. `_start` was left `REWINDING` (jit_after
            // armed `stop_unwind`+`start_rewind` before parking), so re-invoking
            // it rewinds into the await continuation.
            ops.extend([
                Op::La {
                    rd: T0,
                    addr: Addr::Prom,
                },
                Op::Lw {
                    rd: T1,
                    rs: T0,
                    off: crate::domt::P_RESUME,
                },
                Op::Beq {
                    rs1: T1,
                    rs2: X0,
                    to: "tick_prom_done".into(),
                },
                Op::Sw {
                    rs2: X0,
                    rs1: T0,
                    off: crate::domt::P_RESUME,
                },
                // JitCall(entry_funcidx, nargs=1, arg0=__heap_base): `_start`'s
                // REWINDING prologue `start_rewind`s into the saved continuation.
                Op::Jal {
                    rd: RA,
                    to: "JitResume".into(),
                },
                Op::Jal {
                    rd: RA,
                    to: "DomtKey".into(),
                },
                Op::Jal {
                    rd: RA,
                    to: "DomtPtr".into(),
                },
                Op::Label("tick_prom_done".into()),
            ]);
        }
        ops.extend([
            Op::La {
                rd: T0,
                addr: Addr::UiDom,
            },
            Op::Lw {
                rd: T1,
                rs: T0,
                off: 4,
            },
            Op::Lw {
                rd: T2,
                rs: T0,
                off: crate::dom::DOM_PAINTED,
            },
            // A clean row-table skips only the __ui_dom repaint — the M2
            // `__dom` tree still has to be checked before the tick is clean.
            Op::Beq {
                rs1: T1,
                rs2: T2,
                to: "trap_timer_domt".into(),
            },
            Op::Sw {
                rs2: T1,
                rs1: T0,
                off: crate::dom::DOM_PAINTED,
            },
            Op::Jal {
                rd: RA,
                to: "DomPaint".into(),
            },
        ]);
        if spec.wants_virtio_gpu() && (spec.kernel.gr.enable || spec.kernel.proxy.enable) {
            ops.push(Op::Jal {
                rd: RA,
                to: "VioPaint".into(),
            });
        }
        if spec.wants_disp_scan() {
            ops.push(Op::Jal {
                rd: RA,
                to: "DispPaint".into(),
            });
        }
        if spec.wants_pci_scan() && (spec.kernel.gr.enable || spec.kernel.proxy.enable) {
            ops.push(Op::Jal {
                rd: RA,
                to: "PciPaint".into(),
            });
        }
        // M2 guest DOM tree: when `__dom` has dirty nodes, re-run block layout
        // then raster them into `__scan_fb` and present the frame on the same
        // commit rungs the row-table path uses.
        ops.push(Op::Label("trap_timer_domt".into()));
        if spec.kernel.wasm.guest_jit {
            ops.extend([
                Op::La {
                    rd: T0,
                    addr: Addr::DomT,
                },
                Op::Lw {
                    rd: T1,
                    rs: T0,
                    off: crate::domt::H_DIRTY,
                },
                Op::Beq {
                    rs1: T1,
                    rs2: X0,
                    to: "trap_timer_clean".into(),
                },
                // A live packed scene owns the surface: `WebPaint` replays
                // `__web_dl` (first time / new state) or falls back to the
                // `__web_pk` pixel decode, or reports the canvas already
                // live — and the bounded block-flow raster must not paint
                // text over it.
                Op::Jal {
                    rd: RA,
                    to: "WebPaint".into(),
                },
                Op::Bne {
                    rs1: A0,
                    rs2: X0,
                    to: "trap_timer_domt_pk".into(),
                },
                Op::Jal {
                    rd: RA,
                    to: "DomtLayout".into(),
                },
                Op::Jal {
                    rd: RA,
                    to: "DomtRaster".into(),
                },
                Op::Label("trap_timer_domt_pk".into()),
            ]);
            ops.extend(paint_commit_ops(spec));
        }
        ops.push(Op::Label("trap_timer_clean".into()));
        if faces_share_plane(spec) {
            // The container's tick as well, taken only while it owns the plane:
            // the countdown has to run and `CLI_DIRTY` has to flush, or the picker
            // would be a still image that never boots anything.
            ops.push(Op::Jal {
                rd: X0,
                to: "tick_web_done".into(),
            });
            ops.push(Op::Label("tick_face_cli".into()));
            ops.extend(crate::cli::tick_ops(spec.kernel.cli.autoboot.enable));
            ops.extend(paint_commit_ops(spec));
            ops.push(Op::Label(crate::cli::TICK_CLEAN.into()));
            ops.push(Op::Label("tick_web_done".into()));
        }
    } else if wants_cli_face(spec) {
        // Same split for the CLI face: keys edit the line on their own irq,
        // the frame is flushed here when `CLI_DIRTY` moved.
        ops.extend(crate::cli::tick_ops(spec.kernel.cli.autoboot.enable));
        ops.extend(paint_commit_ops(spec));
        ops.push(Op::Label(crate::cli::TICK_CLEAN.into()));
    }
    ops.extend([
        Op::Jal {
            rd: RA,
            to: "NativePoll".into(),
        },
        Op::Jal {
            rd: X0,
            to: "trap_done".into(),
        },
    ]);
    ops.extend(trap_fault_ops(xlen, spec));
    ops.push(Op::Label("trap_done".into()));
    for (r, i) in saves {
        ops.push(load_op(xlen, r, SP, i * slot));
    }
    ops.extend([
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: frame,
        },
        Op::Sret,
    ]);
    Node {
        purpose: Purpose::Trap,
        ops,
    }
}

/// PLIC irq 1: drain one ns16550 RBR, echo, append to `__uart_line`; newline → V/R/S/W.
/// The UART1 drain is emitted only when the board actually has the second
/// ns16550 (`dual_band.tcp`); on stock QEMU virt that MMIO is unmapped and a
/// load would fault inside the trap.
fn trap_uart_ops(spec: &BoardSpec) -> Vec<Op> {
    let u0 = uart0_base(spec);
    let u1 = uart1_base(spec);
    let has_u1 = spec.holyc.dual_band.tcp.enable;
    let cap = i64::from(UART_LINE_CAP);
    let mut ops = vec![
        Op::Label("trap_uart".into()),
        Op::Comment("PLIC irq 1 ns16550 RX + linebuf View/Reboot (not a poll, not 0x3F8)".into()),
        Op::La {
            rd: T0,
            addr: Addr::Abs(u0),
        },
        Op::Lbu {
            rd: T1,
            rs: T0,
            off: 5,
        },
        Op::Andi {
            rd: T1,
            rs: T1,
            imm: UART_LSR_DR as i32,
        },
        Op::Beq {
            rs1: T1,
            rs2: X0,
            to: if has_u1 {
                "uart1_drain".into()
            } else {
                "trap_done".into()
            },
        },
        Op::Lbu {
            rd: A0,
            rs: T0,
            off: 0,
        },
        Op::Jal {
            rd: X0,
            to: "uart_take".into(),
        },
    ];
    if has_u1 {
        ops.extend([
            Op::Label("uart1_drain".into()),
            // Gate on the absent flag: when the boot probe faulted, UART1
            // reads in trap context must not re-fault.
            Op::La {
                rd: T1,
                addr: Addr::UartLine,
            },
            Op::Lbu {
                rd: T1,
                rs: T1,
                off: UART1_DEAD_OFF as i32,
            },
            Op::Bne {
                rs1: T1,
                rs2: X0,
                to: "trap_done".into(),
            },
            Op::La {
                rd: T0,
                addr: Addr::Abs(u1),
            },
            Op::Lbu {
                rd: T1,
                rs: T0,
                off: 5,
            },
            Op::Andi {
                rd: T1,
                rs: T1,
                imm: UART_LSR_DR as i32,
            },
            Op::Beq {
                rs1: T1,
                rs2: X0,
                to: "trap_done".into(),
            },
            Op::Lbu {
                rd: A0,
                rs: T0,
                off: 0,
            },
        ]);
    }
    ops.extend([
        Op::Label("uart_take".into()),
        Op::Addi {
            rd: T2,
            rs: A0,
            imm: 0,
        },
        Op::Li {
            rd: A7,
            imm: SBI_PUTCHAR,
        },
        Op::Ecall,
        Op::La {
            rd: T0,
            addr: Addr::UartLine,
        },
        Op::Lw {
            rd: T1,
            rs: T0,
            off: UART_LINE_CAP as i32,
        },
        Op::Li {
            rd: A2,
            imm: i64::from(b'\n'),
        },
        Op::Beq {
            rs1: T2,
            rs2: A2,
            to: "uart_line_go".into(),
        },
        Op::Li {
            rd: A2,
            imm: i64::from(b'\r'),
        },
        Op::Beq {
            rs1: T2,
            rs2: A2,
            to: "uart_line_go".into(),
        },
        Op::Li { rd: A2, imm: cap },
        Op::Beq {
            rs1: T1,
            rs2: A2,
            to: "trap_done".into(),
        },
        Op::Add {
            rd: A1,
            rs1: T0,
            rs2: T1,
        },
        Op::Sb {
            rs2: T2,
            rs1: A1,
            off: 0,
        },
        Op::Addi {
            rd: T1,
            rs: T1,
            imm: 1,
        },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: UART_LINE_CAP as i32,
        },
        Op::Jal {
            rd: X0,
            to: "trap_done".into(),
        },
        Op::Label("uart_line_go".into()),
        Op::Lw {
            rd: A1,
            rs: T0,
            off: 0,
        },
        Op::Lbu {
            rd: T1,
            rs: T0,
            off: 0,
        },
    ]);
    if wants_cli_face(spec) {
        ops.extend(crate::cli::stash_uart_len_ops(T0));
    }
    ops.extend([
        Op::Sw {
            rs2: X0,
            rs1: T0,
            off: UART_LINE_CAP as i32,
        },
        Op::Li {
            rd: A2,
            imm: i64::from(CMD_VIEW),
        },
        Op::Beq {
            rs1: A1,
            rs2: A2,
            to: "uart_view".into(),
        },
        Op::Li {
            rd: A2,
            imm: i64::from(CMD_REBO),
        },
        Op::Beq {
            rs1: A1,
            rs2: A2,
            to: "uart_reboot".into(),
        },
        Op::Li {
            rd: A2,
            imm: i64::from(CMD_SHUT),
        },
        Op::Beq {
            rs1: A1,
            rs2: A2,
            to: "uart_shutdown".into(),
        },
        Op::Li {
            rd: A2,
            imm: i64::from(CMD_WAKE),
        },
        Op::Beq {
            rs1: A1,
            rs2: A2,
            to: "uart_wakeup".into(),
        },
        Op::Li {
            rd: A2,
            imm: i64::from(b'R'),
        },
        Op::Beq {
            rs1: T1,
            rs2: A2,
            to: "uart_reboot".into(),
        },
        Op::Li {
            rd: A2,
            imm: i64::from(b'S'),
        },
        Op::Beq {
            rs1: T1,
            rs2: A2,
            to: "uart_shutdown".into(),
        },
        Op::Li {
            rd: A2,
            imm: i64::from(b'W'),
        },
        Op::Beq {
            rs1: T1,
            rs2: A2,
            to: "uart_wakeup".into(),
        },
        Op::Li {
            rd: A2,
            imm: i64::from(CMD_UI),
        },
        Op::Beq {
            rs1: A1,
            rs2: A2,
            to: "uart_ui".into(),
        },
        Op::Li {
            rd: A2,
            imm: i64::from(b'U'),
        },
        Op::Beq {
            rs1: T1,
            rs2: A2,
            to: "uart_ui".into(),
        },
        Op::Li {
            rd: A2,
            imm: i64::from(CMD_FILE),
        },
        Op::Beq {
            rs1: A1,
            rs2: A2,
            to: "uart_file".into(),
        },
        Op::Li {
            rd: A2,
            imm: i64::from(b'F'),
        },
        Op::Beq {
            rs1: T1,
            rs2: A2,
            to: "uart_file".into(),
        },
        Op::Li {
            rd: A2,
            imm: i64::from(CMD_GET),
        },
        Op::Beq {
            rs1: A1,
            rs2: A2,
            to: "uart_get".into(),
        },
        Op::Li {
            rd: A2,
            imm: i64::from(b'G'),
        },
        Op::Beq {
            rs1: T1,
            rs2: A2,
            to: "uart_get".into(),
        },
    ]);
    if spec.wants_virtio_input() {
        ops.extend([
            Op::Li {
                rd: A2,
                imm: i64::from(CMD_KEYS),
            },
            Op::Beq {
                rs1: A1,
                rs2: A2,
                to: "uart_keys".into(),
            },
            Op::Li {
                rd: A2,
                imm: i64::from(b'K'),
            },
            Op::Beq {
                rs1: T1,
                rs2: A2,
                to: "uart_keys".into(),
            },
        ]);
    }
    if spec.wants_virtio_blk() {
        // `Blk` — the guest reads LBA 0/1 itself and names the medium. There is
        // no host page behind this one: the answer comes off the disk.
        ops.extend([
            Op::Li {
                rd: A2,
                imm: i64::from(CMD_BLK),
            },
            Op::Beq {
                rs1: A1,
                rs2: A2,
                to: "uart_blk".into(),
            },
            Op::Li {
                rd: A2,
                imm: i64::from(b'B'),
            },
            Op::Beq {
                rs1: T1,
                rs2: A2,
                to: "uart_blk".into(),
            },
            Op::Li {
                rd: A2,
                imm: i64::from(CMD_JRN),
            },
            Op::Beq {
                rs1: A1,
                rs2: A2,
                to: "uart_jrn".into(),
            },
            Op::Li {
                rd: A2,
                imm: i64::from(b'J'),
            },
            Op::Beq {
                rs1: T1,
                rs2: A2,
                to: "uart_jrn".into(),
            },
            Op::Li {
                rd: A2,
                imm: i64::from(CMD_FWS),
            },
            Op::Beq {
                rs1: A1,
                rs2: A2,
                to: "uart_fws".into(),
            },
            Op::Li {
                rd: A2,
                imm: i64::from(CMD_LNX),
            },
            Op::Beq {
                rs1: A1,
                rs2: A2,
                to: "uart_lnx".into(),
            },
            Op::Li {
                rd: A2,
                imm: i64::from(b'L'),
            },
            Op::Beq {
                rs1: T1,
                rs2: A2,
                to: "uart_lnx".into(),
            },
        ]);
    }
    if spec.kernel.wasm.jit {
        ops.extend([
            Op::Li {
                rd: A2,
                imm: i64::from(CMD_AWAI),
            },
            Op::Beq {
                rs1: A1,
                rs2: A2,
                to: "uart_await".into(),
            },
            Op::Li {
                rd: A2,
                imm: i64::from(b'A'),
            },
            Op::Beq {
                rs1: T1,
                rs2: A2,
                to: "uart_await".into(),
            },
            Op::Li {
                rd: A2,
                imm: i64::from(CMD_THRO),
            },
            Op::Beq {
                rs1: A1,
                rs2: A2,
                to: "uart_throw".into(),
            },
            Op::Li {
                rd: A2,
                imm: i64::from(b'T'),
            },
            Op::Beq {
                rs1: T1,
                rs2: A2,
                to: "uart_throw".into(),
            },
        ]);
    }
    // No band command matched. With the CLI face compiled the line belongs to
    // the container (typed over serial on a headless board); otherwise the
    // historical fallthrough into `View` stands.
    if wants_cli_face(spec) {
        ops.extend(crate::cli::uart_line_ops(paint_commit_ops(spec)));
    }
    ops.extend([Op::Label("uart_view".into())]);
    for ch in b"VIEW" {
        ops.extend(putc_ops(i64::from(*ch)));
    }
    ops.extend([
        Op::Comment("ViewSection(\"name\") — print VIEW name (HolyC REPL rewrite)".into()),
        Op::Li { rd: T1, imm: 0 },
        Op::Label("view_findq".into()),
        Op::Li { rd: A2, imm: 128 },
        Op::Beq {
            rs1: T1,
            rs2: A2,
            to: "view_nl".into(),
        },
        Op::Add {
            rd: A1,
            rs1: T0,
            rs2: T1,
        },
        Op::Lbu {
            rd: A2,
            rs: A1,
            off: 0,
        },
        Op::Addi {
            rd: T1,
            rs: T1,
            imm: 1,
        },
        Op::Beq {
            rs1: A2,
            rs2: X0,
            to: "view_nl".into(),
        },
        Op::Li {
            rd: A0,
            imm: i64::from(b'"'),
        },
        Op::Bne {
            rs1: A2,
            rs2: A0,
            to: "view_findq".into(),
        },
        Op::Li {
            rd: A0,
            imm: i64::from(b' '),
        },
        Op::Li {
            rd: A7,
            imm: SBI_PUTCHAR,
        },
        Op::Ecall,
        Op::Label("view_copy".into()),
        Op::Li { rd: A2, imm: 128 },
        Op::Beq {
            rs1: T1,
            rs2: A2,
            to: "view_nl".into(),
        },
        Op::Add {
            rd: A1,
            rs1: T0,
            rs2: T1,
        },
        Op::Lbu {
            rd: A0,
            rs: A1,
            off: 0,
        },
        Op::Addi {
            rd: T1,
            rs: T1,
            imm: 1,
        },
        Op::Beq {
            rs1: A0,
            rs2: X0,
            to: "view_nl".into(),
        },
        Op::Li {
            rd: A2,
            imm: i64::from(b'"'),
        },
        Op::Beq {
            rs1: A0,
            rs2: A2,
            to: "view_nl".into(),
        },
        Op::Li {
            rd: A7,
            imm: SBI_PUTCHAR,
        },
        Op::Ecall,
        Op::Jal {
            rd: X0,
            to: "view_copy".into(),
        },
        Op::Label("view_nl".into()),
        Op::Li {
            rd: A0,
            imm: i64::from(b'\n'),
        },
        Op::Li {
            rd: A7,
            imm: SBI_PUTCHAR,
        },
        Op::Ecall,
        Op::Jal {
            rd: X0,
            to: "trap_done".into(),
        },
    ]);
    ops.push(Op::Label("uart_ui".into()));
    for ch in b"UI\n" {
        ops.extend(putc_ops(i64::from(*ch)));
    }
    if faces_share_plane(spec) {
        // `Ui` on the band *is* a request for the browser face — the same request
        // the picker's "BIOS UI" entry makes with a keystroke. So it claims the
        // plane rather than dumping the browser's DOM onto the container's frame.
        // The claim comes *before* the paint paths: a live pack must not leave
        // the container owning the surface its canvas now covers.
        ops.push(Op::Comment(
            "Ui → the browser face claims the plane (FACE_WEB), then paints".into(),
        ));
        ops.extend([
            Op::La {
                rd: T0,
                addr: Addr::UartLine,
            },
            Op::Li {
                rd: T1,
                imm: crate::FACE_WEB,
            },
            Op::Sw {
                rs2: T1,
                rs1: T0,
                off: crate::FACE_OWNER_OFF,
            },
        ]);
    }
    if spec.kernel.wasm.guest_jit {
        // `Ui` wants the browser face's *canvas*, not its row-table dump:
        // when a web carry is live `WebPaint` owns the surface and the band
        // goes straight to the commit rungs.
        ops.push(Op::Jal {
            rd: RA,
            to: "WebPaint".into(),
        });
        ops.push(Op::Bne {
            rs1: A0,
            rs2: X0,
            to: "uart_ui_webpk".into(),
        });
    }
    if faces_share_plane(spec) {
        ops.push(Op::Jal {
            rd: RA,
            to: "WasmUi".into(),
        });
    }
    if spec.kernel.wasm.enable && spec.kernel.wasm.jit {
        ops.push(Op::Comment(
            "Ui poll: drain the await slots before the repaint (DomAwait resolves \
             one slot per call — AWAIT_SLOTS calls is the bounded drain; the timer \
             tick calls it once so IRQ context stays O(1))"
                .into(),
        ));
        for _ in 0..crate::dom::AWAIT_SLOTS {
            ops.push(Op::Jal {
                rd: RA,
                to: "DomAwait".into(),
            });
        }
        ops.push(Op::Comment(
            "Ui → DomPaint: re-dump live __ui_dom rows (bounded)".into(),
        ));
        ops.push(Op::Jal {
            rd: RA,
            to: "DomPaint".into(),
        });
    }
    if spec.kernel.wasm.guest_jit {
        ops.push(Op::Label("uart_ui_webpk".into()));
    }
    if spec.wants_virtio_gpu() && (spec.kernel.gr.enable || spec.kernel.proxy.enable) {
        ops.push(Op::Comment(
            "Ui → VioPaint: push repainted plane to the virtio-gpu scanout".into(),
        ));
        ops.push(Op::Jal {
            rd: RA,
            to: "VioPaint".into(),
        });
    }
    // `DispPaint` is deliberately absent here: the uncore repaint is covered
    // by the timer tick's dirty-DOM watermark, and running a second full
    // `FbExpandSel` inside UART IRQ context would double the frame cost.
    // `PciPaint` joins `VioPaint` so an explicit `Ui` repaint reaches the BAR
    // on a pcie-won board; it self-gates on `__disp.class` and costs a few
    // instructions elsewhere.
    if spec.wants_pci_scan() && (spec.kernel.gr.enable || spec.kernel.proxy.enable) {
        ops.push(Op::Comment(
            "Ui → PciPaint: BAR blit when the pcie-linear-fb rung won".into(),
        ));
        ops.push(Op::Jal {
            rd: RA,
            to: "PciPaint".into(),
        });
    }
    ops.push(Op::Jal {
        rd: X0,
        to: "trap_done".into(),
    });
    ops.extend([
        Op::Label("uart_file".into()),
        Op::Comment("FileServe(\"/ui\") — HolyC kernel file server rewrite".into()),
        Op::Jal {
            rd: RA,
            to: "FileServe".into(),
        },
        Op::Jal {
            rd: X0,
            to: "trap_done".into(),
        },
        Op::Label("uart_get".into()),
        Op::Comment("Get(\"/ui/ui.wasm\") — mailbox/UART HTTP GET rewrite; not a netdev".into()),
        Op::Jal {
            rd: RA,
            to: "GetFile".into(),
        },
        Op::Jal {
            rd: X0,
            to: "trap_done".into(),
        },
    ]);
    if spec.wants_virtio_blk() {
        // Its own gate: a board can have a disk and no keyboard, or the reverse,
        // and a label that exists under the wrong condition is a link error.
        ops.extend([
            Op::Label("uart_blk".into()),
            Op::Comment("Blk — jal BlkSig (the guest's own sector read)".into()),
            Op::Jal {
                rd: RA,
                to: "BlkSig".into(),
            },
            Op::Jal {
                rd: RA,
                to: "FatRead".into(),
            },
            Op::Jal {
                rd: RA,
                to: "Ext4Read".into(),
            },
            Op::Jal {
                rd: X0,
                to: "trap_done".into(),
            },
            Op::Label("uart_jrn".into()),
            Op::Comment("Jrn — JrnLoad + JrnCommit slot 0 (G6BH window, not Linux)".into()),
            Op::Li { rd: A0, imm: 0 },
            Op::Jal {
                rd: RA,
                to: "JrnLoad".into(),
            },
            Op::Li { rd: A0, imm: 0 },
            Op::Jal {
                rd: RA,
                to: "JrnCommit".into(),
            },
            Op::Jal {
                rd: X0,
                to: "trap_done".into(),
            },
            Op::Label("uart_fws".into()),
            Op::Comment("Fws — stage inactive firmware B, refuse A/journal, FwSelect holds".into()),
            Op::Jal {
                rd: RA,
                to: "FwStageSelftest".into(),
            },
            Op::Jal {
                rd: X0,
                to: "trap_done".into(),
            },
            Op::Label("uart_lnx".into()),
            Op::Comment("Lnx — LinuxLoadDisk canary Image at LBA 40, not autoboot".into()),
            Op::Li {
                rd: A0,
                imm: crate::linux::DISK_IMAGE_LBA,
            },
            Op::Li { rd: A1, imm: 4 },
            Op::Li {
                rd: A2,
                imm: crate::linux::DISK_IMAGE_LBA + 4,
            },
            Op::Li { rd: A3, imm: 1 },
            Op::Jal {
                rd: RA,
                to: "LinuxLoadDisk".into(),
            },
            Op::Jal {
                rd: X0,
                to: "trap_done".into(),
            },
        ]);
    }
    if spec.wants_virtio_input() {
        ops.extend([
            Op::Label("uart_keys".into()),
            Op::Comment(
                "Keys — InpPoll: drain the virtio-input eventq and print \
                 queued EV_KEY codes (KEY <hex>)"
                    .into(),
            ),
            Op::Jal {
                rd: RA,
                to: "InpPoll".into(),
            },
        ]);
        if spec.kernel.wasm.jit {
            if faces_share_plane(spec) {
                ops.extend(face_is(crate::FACE_WEB, "uart_keys_dom_done"));
            }
            // Refresh the nav.sel/inp.last rows after the drain — the repaint
            // is left to the next Ui/refresh (a query shouldn't flush a frame).
            ops.push(Op::Jal {
                rd: RA,
                to: "DomNav".into(),
            });
            ops.push(Op::Jal {
                rd: RA,
                to: "DomKey".into(),
            });
            ops.push(Op::Jal {
                rd: RA,
                to: "DomAwait".into(),
            });
            if faces_share_plane(spec) {
                ops.push(Op::Label("uart_keys_dom_done".into()));
            }
        }
        ops.push(Op::Jal {
            rd: X0,
            to: "trap_done".into(),
        });
    }
    if spec.kernel.wasm.jit {
        // Await — the `env.await` entry: `WasmAwait` claims the first
        // non-pending await slot (`AWAIT_SLOTS`=4 at `__ui_dom`+16) →
        // `AWAIT pending N`; all pending → `AWAIT-REJ full`. The slot
        // logic lives in `g6b-asm::dom` (`WasmAwait`), shared with the
        // lowered wasm `call env.await` — this UART path is a thin jal.
        // Resolution happens on the DomAwait poll points (trap_timer tick
        // + Ui/Keys), never inline — `await` doesn't block DOM events.
        ops.extend([
            Op::Label("uart_await".into()),
            Op::Comment("Await — jal WasmAwait (env.await: bounded slot claim)".into()),
            Op::Jal {
                rd: RA,
                to: "WasmAwait".into(),
            },
            Op::Jal {
                rd: X0,
                to: "trap_done".into(),
            },
        ]);
        // Throw — the `env.throw` entry: `WasmThrow` rejects the newest
        // pending slot → `AWAIT-THROW`; nothing pending → `AWAIT-THROW
        // none`. The slot logic lives in `g6b-asm::dom` (`WasmThrow`),
        // shared with the lowered wasm `call env.throw`.
        ops.extend([
            Op::Label("uart_throw".into()),
            Op::Comment(
                "Throw — jal WasmThrow (env.throw). `Throw N` (N=slot) rejects that \
                 slot; plain `Throw` keeps a0=-1 → newest pending."
                    .into(),
            ),
            Op::Li { rd: A0, imm: -1 },
            // Optional arg: the char after "Throw " (offset 6 in
            // `__uart_line`). In-range digit → a0 = slot; anything else
            // (newline, NUL, junk) → keep -1.
            Op::La {
                rd: T4,
                addr: Addr::UartLine,
            },
            Op::Lbu {
                rd: T4,
                rs: T4,
                off: 6,
            },
            Op::Addi {
                rd: T4,
                rs: T4,
                imm: -48, // '0'
            },
            // Reject negative (sign bit) or >= 4 (any bit above bit1).
            Op::Srli {
                rd: T6,
                rs: T4,
                shamt: crate::dom::signbit(spec.isa.xlen),
            },
            Op::Bne {
                rs1: T6,
                rs2: X0,
                to: "uthrow_go".into(),
            },
            Op::Andi {
                rd: T6,
                rs: T4,
                imm: -4,
            },
            Op::Bne {
                rs1: T6,
                rs2: X0,
                to: "uthrow_go".into(),
            },
            Op::Addi {
                rd: A0,
                rs: T4,
                imm: 0,
            },
            Op::Label("uthrow_go".into()),
            Op::Jal {
                rd: RA,
                to: "WasmThrow".into(),
            },
            Op::Jal {
                rd: X0,
                to: "trap_done".into(),
            },
        ]);
    }
    ops.push(Op::Label("uart_wakeup".into()));
    for ch in b"WAKE\n" {
        ops.extend(putc_ops(i64::from(*ch)));
    }
    ops.push(Op::Jal {
        rd: X0,
        to: "trap_done".into(),
    });
    ops.extend([
        Op::Label("uart_reboot".into()),
        Op::Li {
            rd: A7,
            imm: SBI_SRST_EID,
        },
        Op::Li { rd: A6, imm: 0 },
        Op::Li { rd: A0, imm: 1 },
        Op::Li { rd: A1, imm: 0 },
        Op::Ecall,
        Op::Jal {
            rd: X0,
            to: "trap_done".into(),
        },
        Op::Label("uart_shutdown".into()),
        Op::Li {
            rd: A7,
            imm: SBI_SRST_EID,
        },
        Op::Li { rd: A6, imm: 0 },
        Op::Li { rd: A0, imm: 0 },
        Op::Li { rd: A1, imm: 0 },
        Op::Ecall,
        Op::Jal {
            rd: X0,
            to: "trap_done".into(),
        },
    ]);
    ops
}

/// Sideband mailbox command: Linux `write()` doorbell=1, first CMD byte V/R/S/W/U.
fn trap_mbox_ops(spec: &BoardSpec) -> Vec<Op> {
    let base = parse_hex(&spec.loopback.base).unwrap_or(0x1010_0000);
    let mut ops = vec![
        Op::Label("trap_mbox".into()),
        Op::Comment("mailbox kick — View/Reboot/Shutdown/Wakeup/Ui/File/Get; not a netdev".into()),
        // MBOX_DEAD gate: on a board without the g6lc-bios mailbox the claim
        // can still land here if another source shares the irq line — the
        // doorbell read must not take a nested access fault (nested traps
        // clobber sepc).
        Op::La {
            rd: T1,
            addr: Addr::UartLine,
        },
        Op::Lbu {
            rd: T1,
            rs: T1,
            off: MBOX_DEAD_OFF as i32,
        },
        Op::Bne {
            rs1: T1,
            rs2: X0,
            to: "trap_done".into(),
        },
        Op::La {
            rd: T0,
            addr: Addr::Abs(base),
        },
        Op::Lw {
            rd: T1,
            rs: T0,
            off: MBOX_OFF_DOORBELL as i32,
        },
        Op::Li { rd: T2, imm: 1 },
        Op::Bne {
            rs1: T1,
            rs2: T2,
            to: "trap_done".into(),
        },
        Op::Sw {
            rs2: X0,
            rs1: T0,
            off: MBOX_OFF_DOORBELL as i32,
        },
        Op::Li {
            rd: T1,
            imm: i64::from(MBOX_ST_BUSY),
        },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: MBOX_OFF_STATUS as i32,
        },
        Op::Lbu {
            rd: T1,
            rs: T0,
            off: MBOX_OFF_CMD as i32,
        },
        Op::Li {
            rd: T2,
            imm: i64::from(b'R'),
        },
        Op::Beq {
            rs1: T1,
            rs2: T2,
            to: "mbox_reboot".into(),
        },
        Op::Li {
            rd: T2,
            imm: i64::from(b'S'),
        },
        Op::Beq {
            rs1: T1,
            rs2: T2,
            to: "mbox_shutdown".into(),
        },
        Op::Li {
            rd: T2,
            imm: i64::from(b'W'),
        },
        Op::Beq {
            rs1: T1,
            rs2: T2,
            to: "mbox_wakeup".into(),
        },
        Op::Li {
            rd: T2,
            imm: i64::from(b'U'),
        },
        Op::Beq {
            rs1: T1,
            rs2: T2,
            to: "mbox_ui".into(),
        },
        Op::Li {
            rd: T2,
            imm: i64::from(b'F'),
        },
        Op::Beq {
            rs1: T1,
            rs2: T2,
            to: "mbox_file".into(),
        },
        Op::Li {
            rd: T2,
            imm: i64::from(b'G'),
        },
        Op::Beq {
            rs1: T1,
            rs2: T2,
            to: "mbox_get".into(),
        },
    ];
    if spec.wants_virtio_input() {
        ops.extend([
            Op::Li {
                rd: T2,
                imm: i64::from(b'K'),
            },
            Op::Beq {
                rs1: T1,
                rs2: T2,
                to: "mbox_keys".into(),
            },
        ]);
    }
    ops.extend([
        Op::Label("mbox_view".into()),
        Op::Li {
            rd: T1,
            imm: i64::from(MBOX_RSP_VIEW),
        },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: MBOX_OFF_RSP as i32,
        },
        Op::Li { rd: T1, imm: 0x0a },
        Op::Sb {
            rs2: T1,
            rs1: T0,
            off: (MBOX_OFF_RSP as i32) + 4,
        },
        Op::Li { rd: T1, imm: 5 },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: MBOX_OFF_LENGTH as i32,
        },
        Op::Li {
            rd: T1,
            imm: i64::from(MBOX_ST_RSP),
        },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: MBOX_OFF_STATUS as i32,
        },
        Op::Jal {
            rd: X0,
            to: "trap_done".into(),
        },
        Op::Label("mbox_wakeup".into()),
        Op::Li {
            rd: T1,
            imm: i64::from(MBOX_RSP_WAKE),
        },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: MBOX_OFF_RSP as i32,
        },
        Op::Li { rd: T1, imm: 4 },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: MBOX_OFF_LENGTH as i32,
        },
        Op::Li {
            rd: T1,
            imm: i64::from(MBOX_ST_RSP),
        },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: MBOX_OFF_STATUS as i32,
        },
        Op::Jal {
            rd: X0,
            to: "trap_done".into(),
        },
        Op::Label("mbox_file".into()),
        Op::Li {
            rd: T1,
            imm: i64::from(MBOX_RSP_FILE),
        },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: MBOX_OFF_RSP as i32,
        },
        Op::Li { rd: T1, imm: 4 },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: MBOX_OFF_LENGTH as i32,
        },
        Op::Li {
            rd: T1,
            imm: i64::from(MBOX_ST_RSP),
        },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: MBOX_OFF_STATUS as i32,
        },
        Op::Jal {
            rd: X0,
            to: "trap_done".into(),
        },
        Op::Label("mbox_get".into()),
        Op::Comment("GET /ui/ui.wasm — RSP = \\0asm + size (not a netdev)".into()),
        Op::La {
            rd: T2,
            addr: Addr::UiBlob,
        },
        Op::Lw {
            rd: T1,
            rs: T2,
            off: 24,
        },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: MBOX_OFF_RSP as i32,
        },
        Op::Lw {
            rd: T1,
            rs: T2,
            off: 4,
        },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: (MBOX_OFF_RSP as i32) + 4,
        },
        Op::Li { rd: T1, imm: 8 },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: MBOX_OFF_LENGTH as i32,
        },
        Op::Li {
            rd: T1,
            imm: i64::from(MBOX_ST_RSP),
        },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: MBOX_OFF_STATUS as i32,
        },
        Op::Jal {
            rd: X0,
            to: "trap_done".into(),
        },
        Op::Label("mbox_ui".into()),
        Op::Li {
            rd: T1,
            imm: i64::from(MBOX_RSP_UI),
        },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: MBOX_OFF_RSP as i32,
        },
        Op::Li { rd: T1, imm: 3 },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: MBOX_OFF_LENGTH as i32,
        },
        Op::Li {
            rd: T1,
            imm: i64::from(MBOX_ST_RSP),
        },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: MBOX_OFF_STATUS as i32,
        },
        Op::Comment(
            "Mailbox Ui is the same operator dump as UART Ui (svelte-d WebFeed \
             + VioPaint), then trap_done."
                .into(),
        ),
        Op::Jal {
            rd: X0,
            to: "uart_ui".into(),
        },
        Op::Label("mbox_reboot".into()),
        Op::Li {
            rd: A7,
            imm: SBI_SRST_EID,
        },
        Op::Li { rd: A6, imm: 0 },
        Op::Li { rd: A0, imm: 1 },
        Op::Li { rd: A1, imm: 0 },
        Op::Ecall,
        Op::Jal {
            rd: X0,
            to: "trap_done".into(),
        },
        Op::Label("mbox_shutdown".into()),
        Op::Li {
            rd: A7,
            imm: SBI_SRST_EID,
        },
        Op::Li { rd: A6, imm: 0 },
        Op::Li { rd: A0, imm: 0 },
        Op::Li { rd: A1, imm: 0 },
        Op::Ecall,
        Op::Jal {
            rd: X0,
            to: "trap_done".into(),
        },
    ]);
    if spec.wants_virtio_input() {
        // `K` doorbell → drain the key queue over serial (KEY <hex> lines via
        // InpPoll) and answer RSP = `KEYS`.
        ops.extend([
            Op::Label("mbox_keys".into()),
            Op::Jal {
                rd: RA,
                to: "InpPoll".into(),
            },
        ]);
        if spec.kernel.wasm.jit {
            if faces_share_plane(spec) {
                ops.extend(face_is(crate::FACE_WEB, "mbox_keys_dom_done"));
            }
            ops.extend([
                Op::Jal {
                    rd: RA,
                    to: "DomNav".into(),
                },
                Op::Jal {
                    rd: RA,
                    to: "DomKey".into(),
                },
            ]);
        }
        if spec.kernel.wasm.jit && faces_share_plane(spec) {
            ops.push(Op::Label("mbox_keys_dom_done".into()));
        }
        ops.extend([
            Op::Li {
                rd: T0,
                imm: base as i64,
            },
            Op::Li {
                rd: T1,
                imm: i64::from(MBOX_RSP_KEYS),
            },
            Op::Sw {
                rs2: T1,
                rs1: T0,
                off: MBOX_OFF_RSP as i32,
            },
            Op::Li { rd: T1, imm: 4 },
            Op::Sw {
                rs2: T1,
                rs1: T0,
                off: MBOX_OFF_LENGTH as i32,
            },
            Op::Li {
                rd: T1,
                imm: i64::from(MBOX_ST_RSP),
            },
            Op::Sw {
                rs2: T1,
                rs1: T0,
                off: MBOX_OFF_STATUS as i32,
            },
            Op::Jal {
                rd: X0,
                to: "trap_done".into(),
            },
        ]);
    }
    ops
}

fn putc_ops(ch: i64) -> Vec<Op> {
    vec![
        Op::Li { rd: A0, imm: ch },
        Op::Li {
            rd: A7,
            imm: SBI_PUTCHAR,
        },
        Op::Ecall,
    ]
}

fn hex_loop_ops(label: &str, nibble_shamt: u32, nibbles: i64) -> Vec<Op> {
    vec![
        Op::Li {
            rd: A2,
            imm: nibbles,
        },
        Op::Label(label.into()),
        Op::Srli {
            rd: T2,
            rs: T0,
            shamt: nibble_shamt,
        },
        Op::Andi {
            rd: T2,
            rs: T2,
            imm: 0xf,
        },
        Op::Slli {
            rd: T0,
            rs: T0,
            shamt: 4,
        },
        Op::La {
            rd: A6,
            addr: Addr::Label("hexdig".into()),
        },
        Op::Add {
            rd: A6,
            rs1: A6,
            rs2: T2,
        },
        Op::Lbu {
            rd: A0,
            rs: A6,
            off: 0,
        },
        Op::Li {
            rd: A7,
            imm: SBI_PUTCHAR,
        },
        Op::Ecall,
        Op::Addi {
            rd: A2,
            rs: A2,
            imm: -1,
        },
        Op::Bne {
            rs1: A2,
            rs2: X0,
            to: label.into(),
        },
    ]
}

/// INT_FAULT rewrite: dump `TRAP-<scause>-<sepc>` then WFI (no sret loop) —
/// except inside a declared probe window: a load/store access fault (scause
/// 5/7) whose `stval` lands in the UART1 or loopback-mbox MMIO window marks
/// the device absent (`__uart_line` flag) and resumes at `sepc+4`, so a
/// BoardSpec that declares peripherals the platform lacks (stock QEMU virt
/// has no g6lc-bios-mbox / second ns16550) still boots instead of parking.
fn trap_fault_ops(xlen: u32, spec: &BoardSpec) -> Vec<Op> {
    let shamt = xlen.saturating_sub(4);
    let nibbles = i64::from(xlen / 4);
    let u1 = uart1_base(spec);
    let mbox = parse_hex(&spec.loopback.base).unwrap_or(0);
    let mut ops = vec![
        Op::Label("trap_fault".into()),
        Op::Comment(
            "recoverable probe: scause 5/7 + stval in UART1/mbox window → \
             absent flag + sepc+4; everything else is the TRAP dump + park"
                .into(),
        ),
        // T0 = scause, T1 = sepc (from the trap entry reads).
        Op::Srli {
            rd: T2,
            rs: T0,
            shamt: xlen.saturating_sub(1),
        },
        Op::Bne {
            rs1: T2,
            rs2: X0,
            to: "tf_dump".into(),
        },
        Op::Andi {
            rd: T2,
            rs: T0,
            imm: 0x1f,
        },
        Op::Li {
            rd: A2,
            imm: i64::from(SCAUSE_LOAD_ACCESS),
        },
        Op::Beq {
            rs1: T2,
            rs2: A2,
            to: "tf_probe".into(),
        },
        Op::Li {
            rd: A2,
            imm: i64::from(SCAUSE_STORE_ACCESS),
        },
        Op::Bne {
            rs1: T2,
            rs2: A2,
            to: "tf_dump".into(),
        },
        Op::Label("tf_probe".into()),
        Op::Csrrs {
            rd: A2,
            csr: crate::encode::CSR_STVAL,
            rs: X0,
        },
        Op::La {
            rd: T2,
            addr: Addr::Abs(u1),
        },
        Op::Sub {
            rd: T2,
            rs1: A2,
            rs2: T2,
        },
        Op::Srli {
            rd: T2,
            rs: T2,
            shamt: 4, // [u1, u1+0x10)
        },
        Op::Beq {
            rs1: T2,
            rs2: X0,
            to: "tf_u1".into(),
        },
    ];
    if mbox != 0 {
        ops.extend([
            Op::La {
                rd: T2,
                addr: Addr::Abs(mbox),
            },
            Op::Sub {
                rd: T2,
                rs1: A2,
                rs2: T2,
            },
            Op::Srli {
                rd: T2,
                rs: T2,
                shamt: 5, // [mbox, mbox+0x20)
            },
            Op::Beq {
                rs1: T2,
                rs2: X0,
                to: "tf_mb".into(),
            },
        ]);
    }
    ops.extend([
        Op::Jal {
            rd: X0,
            to: "tf_dump".into(),
        },
        Op::Label("tf_u1".into()),
        Op::La {
            rd: T2,
            addr: Addr::UartLine,
        },
        Op::Li { rd: A0, imm: 1 },
        Op::Sb {
            rs2: A0,
            rs1: T2,
            off: UART1_DEAD_OFF as i32,
        },
        Op::Jal {
            rd: X0,
            to: "tf_skip".into(),
        },
        Op::Label("tf_mb".into()),
        Op::La {
            rd: T2,
            addr: Addr::UartLine,
        },
        Op::Li { rd: A0, imm: 1 },
        Op::Sb {
            rs2: A0,
            rs1: T2,
            off: MBOX_DEAD_OFF as i32,
        },
        Op::Label("tf_skip".into()),
        Op::Addi {
            rd: T1,
            rs: T1,
            imm: 4,
        },
        Op::Csrrw {
            rd: X0,
            csr: CSR_SEPC,
            rs: T1,
        },
        Op::Jal {
            rd: X0,
            to: "trap_done".into(),
        },
        Op::Label("tf_dump".into()),
    ]);
    ops.extend(putc_ops(b'T' as i64));
    ops.extend(putc_ops(b'R' as i64));
    ops.extend(putc_ops(b'A' as i64));
    ops.extend(putc_ops(b'P' as i64));
    ops.extend(putc_ops(b'-' as i64));
    ops.extend(hex_loop_ops("hex_scause", shamt, nibbles));
    ops.extend(putc_ops(b'-' as i64));
    ops.push(Op::Addi {
        rd: T0,
        rs: T1,
        imm: 0,
    });
    ops.extend(hex_loop_ops("hex_sepc", shamt, nibbles));
    ops.extend(putc_ops(b'-' as i64));
    // stval — the faulting address for access faults (0 for illegal insn).
    ops.push(Op::Csrrs {
        rd: T0,
        csr: crate::encode::CSR_STVAL,
        rs: X0,
    });
    ops.extend(hex_loop_ops("hex_stval", shamt, nibbles));
    ops.extend(putc_ops(b'\n' as i64));
    ops.extend([
        Op::Label("trap_halt".into()),
        Op::Wfi,
        Op::Jal {
            rd: X0,
            to: "trap_halt".into(),
        },
        Op::Label("hexdig".into()),
        Op::Word(0x3332_3130),
        Op::Word(0x3736_3534),
        Op::Word(0x6261_3938),
        Op::Word(0x6665_6463),
    ]);
    ops
}

/// KStart through `stvec`, then an illegal word so smoke can exercise `trap_fault`.
pub fn illegal_probe(spec: &BoardSpec) -> Module {
    let mut m = kstart(spec);
    for n in &mut m.nodes {
        if n.purpose == Purpose::BootLog {
            n.ops = vec![
                Op::Comment("INT_FAULT probe — illegal insn (not a sret loop)".into()),
                Op::Bne {
                    rs1: TP,
                    rs2: X0,
                    to: "park".into(),
                },
                Op::Word(0),
            ];
        }
    }
    m
}

fn timer_init_node(o: Object, spec: &BoardSpec) -> Node {
    let mut ops = vec![
        Op::Comment(o.why.into()),
        Op::Glob("TimerInit".into()),
        Op::Label("TimerInit".into()),
        Op::Li {
            rd: T0,
            imm: SIE_STIE,
        },
        Op::Csrrs {
            rd: X0,
            csr: CSR_SIE,
            rs: T0,
        },
        Op::Li {
            rd: T0,
            imm: SSTATUS_SIE,
        },
        Op::Csrrs {
            rd: X0,
            csr: CSR_SSTATUS,
            rs: T0,
        },
        Op::Csrrs {
            rd: A0,
            csr: CSR_TIME,
            rs: X0,
        },
    ];
    if spec.isa.xlen == 32 {
        ops.push(Op::Li { rd: A1, imm: 0 });
    }
    ops.extend([
        Op::Li {
            rd: T0,
            imm: timer_interval(spec),
        },
        Op::Add {
            rd: A0,
            rs1: A0,
            rs2: T0,
        },
        Op::Li { rd: A6, imm: 0 },
        Op::Li {
            rd: A7,
            imm: SBI_TIME_EID,
        },
        Op::Ecall,
        Op::Jalr {
            rd: X0,
            rs: RA,
            imm: 0,
        },
    ]);
    Node {
        purpose: Purpose::Timer,
        ops,
    }
}

fn gr_call_node(o: Object) -> Node {
    Node {
        purpose: Purpose::DisplayProxy,
        ops: vec![
            Op::Comment(format!("{} — jal GrInit (SysGrInit rewrite)", o.why)),
            Op::Jal {
                rd: RA,
                to: "GrInit".into(),
            },
        ],
    }
}

fn gl_call_node(o: Object) -> Node {
    Node {
        purpose: Purpose::GlAdapter,
        ops: vec![
            Op::Comment(format!("{} — jal ProxyScale", o.why)),
            Op::Jal {
                rd: RA,
                to: "ProxyScale".into(),
            },
        ],
    }
}

/// Boot-time `jal BlkInit` — probe and bring up the block device.
fn blk_call_node(o: Object) -> Node {
    Node {
        purpose: Purpose::VirtioBlk,
        ops: vec![
            Op::Comment(format!("{} — jal BlkInit, then name the medium", o.why)),
            Op::Jal {
                rd: RA,
                to: "BlkInit".into(),
            },
            // Identify what is attached at power-on: two sector reads, and the
            // answer belongs in the boot log next to every other probe result.
            Op::Jal {
                rd: RA,
                to: "BlkSig".into(),
            },
            // If BlkSig latched a filesystem it knows, a file reader picks it up:
            // FAT keeps the BPB cached, ext4 keeps the superblock cached.
            Op::Jal {
                rd: RA,
                to: "FatRead".into(),
            },
            Op::Jal {
                rd: RA,
                to: "Ext4Read".into(),
            },
        ],
    }
}

fn vio_net_call_node(o: Object) -> Node {
    Node {
        purpose: Purpose::VirtioNet,
        ops: vec![
            Op::Comment(format!("{} — jal VioNetProbe", o.why)),
            Op::Jal {
                rd: RA,
                to: "VioNetProbe".into(),
            },
        ],
    }
}

fn vio_call_node(o: Object, spec: &BoardSpec) -> Node {
    let mut ops = vec![
        Op::Comment(format!("{} — jal VioProbe / VioInit", o.why)),
        Op::Jal {
            rd: RA,
            to: "VioProbe".into(),
        },
        Op::Jal {
            rd: RA,
            to: "VioInit".into(),
        },
    ];
    if spec.wants_virtio_input() {
        ops.push(Op::Comment(
            "InpInit — virtio-keyboard eventq (8 posted event buffers)".into(),
        ));
        ops.push(Op::Jal {
            rd: RA,
            to: "InpInit".into(),
        });
        ops.push(Op::Comment(
            "TabInit — virtio-tablet eventq (second DeviceID 18)".into(),
        ));
        ops.push(Op::Jal {
            rd: RA,
            to: "TabInit".into(),
        });
    }
    Node {
        purpose: Purpose::Virtio,
        ops,
    }
}

fn vio_scan_call_node(o: Object) -> Node {
    Node {
        purpose: Purpose::Virtio,
        ops: vec![
            Op::Comment(format!(
                "{} — jal VioScan (after DispSel; scanout rect from __disp)",
                o.why
            )),
            Op::Jal {
                rd: RA,
                to: "VioScan".into(),
            },
        ],
    }
}

fn vio_gl_call_node(o: Object) -> Node {
    Node {
        purpose: Purpose::Virtio,
        ops: vec![
            Op::Comment(format!(
                "{} — jal VioVirgl (virgl CAPSET→CTX_CREATE→SUBMIT_3D→TRANSFER→FLUSH)",
                o.why
            )),
            Op::Jal {
                rd: RA,
                to: "VioVirgl".into(),
            },
        ],
    }
}

fn vio_paint_call_node(o: Object) -> Node {
    Node {
        purpose: Purpose::Virtio,
        ops: vec![
            Op::Comment(format!(
                "{} — jal VioPaint (__gr_plane → __scan_fb → TRANSFER+FLUSH)",
                o.why
            )),
            Op::Jal {
                rd: RA,
                to: "VioPaint".into(),
            },
        ],
    }
}

fn pci_paint_call_node(o: Object) -> Node {
    Node {
        purpose: Purpose::PciScan,
        ops: vec![
            Op::Comment(format!(
                "{} — jal PciPaint (__disp.fb = accepted BAR; FbExpandSel paints in place)",
                o.why
            )),
            Op::Jal {
                rd: RA,
                to: "PciPaint".into(),
            },
        ],
    }
}

fn pci_call_node(o: Object) -> Node {
    Node {
        purpose: Purpose::PciScan,
        ops: vec![
            Op::Comment(format!("{} — jal PciProbe (read-only ECAM walk)", o.why)),
            Op::Jal {
                rd: RA,
                to: "PciProbe".into(),
            },
        ],
    }
}

fn disp_sel_call_node(o: Object) -> Node {
    Node {
        purpose: Purpose::DisplayMux,
        ops: vec![
            Op::Comment(format!("{} — jal DispSel (after every probe)", o.why)),
            Op::Jal {
                rd: RA,
                to: "DispSel".into(),
            },
        ],
    }
}

fn disp_paint_call_node(o: Object) -> Node {
    Node {
        purpose: Purpose::DispScan,
        ops: vec![
            Op::Comment(format!(
                "{} — jal DispPaint (__gr_plane → __scan_fb → uncore commit + G6FB)",
                o.why
            )),
            Op::Jal {
                rd: RA,
                to: "DispPaint".into(),
            },
        ],
    }
}

/// Virtio-mmio slot scan: QEMU virt exposes 8 transports at
/// `VIO_MMIO_BASE + VIO_MMIO_STEP*i`; MagicValue "virt" + DeviceID 16 = GPU.
/// Prints `VIRTIO-GPU <slot>` on a match, else `VIRTIO-GPU-NONE`. Leaf, t-regs
/// only — enumeration evidence, not a virtqueue, DMA or scanout command.
fn vio_probe_node(o: Object) -> Node {
    let mut ops = vec![
        Op::Comment(format!("{} — read-only slot scan", o.why)),
        Op::Glob("VioProbe".into()),
        Op::Label("VioProbe".into()),
        Op::La {
            rd: T0,
            addr: Addr::Abs(VIO_MMIO_BASE),
        },
        Op::Li {
            rd: T1,
            imm: VIO_MMIO_SLOTS,
        },
        // The 0x1000 slot stride does not fit an addi immediate.
        Op::Li {
            rd: T4,
            imm: VIO_MMIO_STEP as i64,
        },
        Op::Label("vio_slot".into()),
        Op::Lw {
            rd: T2,
            rs: T0,
            off: 0,
        },
        Op::Li {
            rd: T3,
            imm: i64::from(VIO_MAGIC),
        },
        Op::Bne {
            rs1: T2,
            rs2: T3,
            to: "vio_next".into(),
        },
        Op::Lw {
            rd: T2,
            rs: T0,
            off: 8,
        },
        Op::Li {
            rd: T3,
            imm: i64::from(VIO_DEV_GPU),
        },
        Op::Beq {
            rs1: T2,
            rs2: T3,
            to: "vio_gpu".into(),
        },
        Op::Label("vio_next".into()),
        Op::Add {
            rd: T0,
            rs1: T0,
            rs2: T4,
        },
        Op::Addi {
            rd: T1,
            rs: T1,
            imm: -1,
        },
        Op::Bne {
            rs1: T1,
            rs2: X0,
            to: "vio_slot".into(),
        },
    ];
    for ch in b"VIRTIO-GPU-NONE\n" {
        ops.extend(putc_ops(i64::from(*ch)));
    }
    ops.extend([
        Op::Jalr {
            rd: X0,
            rs: RA,
            imm: 0,
        },
        Op::Label("vio_gpu".into()),
    ]);
    for ch in b"VIRTIO-GPU " {
        ops.extend(putc_ops(i64::from(*ch)));
    }
    ops.extend([
        Op::Comment("slot index = VIO_MMIO_SLOTS - remaining".into()),
        Op::Li {
            rd: T2,
            imm: VIO_MMIO_SLOTS,
        },
        Op::Sub {
            rd: T2,
            rs1: T2,
            rs2: T1,
        },
        Op::Addi {
            rd: T2,
            rs: T2,
            imm: i32::from(b'0'),
        },
        Op::Addi {
            rd: A0,
            rs: T2,
            imm: 0,
        },
        Op::Li {
            rd: A7,
            imm: SBI_PUTCHAR,
        },
        Op::Ecall,
    ]);
    ops.extend(putc_ops(i64::from(b'\n')));
    ops.push(Op::Jalr {
        rd: X0,
        rs: RA,
        imm: 0,
    });
    Node {
        purpose: Purpose::Virtio,
        ops,
    }
}

/// Virtio-mmio slot scan for DeviceID 1 (virtio-net). Prints `VIRTIO-NET <slot>`
/// or `VIRTIO-NET-NONE`. Enumeration only — no virtqueue, no QEMU `-netdev`.
fn vio_net_probe_node(o: Object) -> Node {
    let mut ops = vec![
        Op::Comment(format!("{} — read-only virtio-net slot scan", o.why)),
        Op::Glob("VioNetProbe".into()),
        Op::Label("VioNetProbe".into()),
        Op::La {
            rd: T0,
            addr: Addr::Abs(VIO_MMIO_BASE),
        },
        Op::Li {
            rd: T1,
            imm: VIO_MMIO_SLOTS,
        },
        Op::Li {
            rd: T4,
            imm: VIO_MMIO_STEP as i64,
        },
        Op::Label("vn_slot".into()),
        Op::Lw {
            rd: T2,
            rs: T0,
            off: 0,
        },
        Op::Li {
            rd: T3,
            imm: i64::from(VIO_MAGIC),
        },
        Op::Bne {
            rs1: T2,
            rs2: T3,
            to: "vn_next".into(),
        },
        Op::Lw {
            rd: T2,
            rs: T0,
            off: 8,
        },
        Op::Li {
            rd: T3,
            imm: i64::from(VIO_DEV_NET),
        },
        Op::Beq {
            rs1: T2,
            rs2: T3,
            to: "vn_hit".into(),
        },
        Op::Label("vn_next".into()),
        Op::Add {
            rd: T0,
            rs1: T0,
            rs2: T4,
        },
        Op::Addi {
            rd: T1,
            rs: T1,
            imm: -1,
        },
        Op::Bne {
            rs1: T1,
            rs2: X0,
            to: "vn_slot".into(),
        },
    ];
    for ch in b"VIRTIO-NET-NONE\n" {
        ops.extend(putc_ops(i64::from(*ch)));
    }
    ops.extend([
        Op::Jalr {
            rd: X0,
            rs: RA,
            imm: 0,
        },
        Op::Label("vn_hit".into()),
        Op::La {
            rd: T5,
            addr: Addr::VioBss,
        },
        Op::Sw {
            rs2: T0,
            rs1: T5,
            off: crate::vio::VIO_NET_OFF,
        },
    ]);
    for ch in b"VIRTIO-NET " {
        ops.extend(putc_ops(i64::from(*ch)));
    }
    ops.extend([
        Op::Li {
            rd: T2,
            imm: VIO_MMIO_SLOTS,
        },
        Op::Sub {
            rd: T2,
            rs1: T2,
            rs2: T1,
        },
        Op::Addi {
            rd: T2,
            rs: T2,
            imm: i32::from(b'0'),
        },
        Op::Addi {
            rd: A0,
            rs: T2,
            imm: 0,
        },
        Op::Li {
            rd: A7,
            imm: SBI_PUTCHAR,
        },
        Op::Ecall,
    ]);
    ops.extend(putc_ops(i64::from(b'\n')));
    ops.push(Op::Jalr {
        rd: X0,
        rs: RA,
        imm: 0,
    });
    Node {
        purpose: Purpose::VirtioNet,
        ops,
    }
}

fn ui_call_node(o: Object) -> Node {
    Node {
        purpose: Purpose::FileServe,
        ops: vec![
            Op::Comment(format!("{} — jal UiInit (guest G6UI blob)", o.why)),
            Op::Jal {
                rd: RA,
                to: "UiInit".into(),
            },
        ],
    }
}

fn file_call_node(o: Object) -> Node {
    Node {
        purpose: Purpose::FileServe,
        ops: vec![
            Op::Comment(format!("{} — jal FileServe (HolyC /ui listing)", o.why)),
            Op::Jal {
                rd: RA,
                to: "FileServe".into(),
            },
        ],
    }
}

fn get_call_node(o: Object) -> Node {
    Node {
        purpose: Purpose::Http,
        ops: vec![
            Op::Comment(format!("{} — jal GetFile (GET /ui/ui.wasm)", o.why)),
            Op::Jal {
                rd: RA,
                to: "GetFile".into(),
            },
        ],
    }
}

fn get_file_node(spec: &BoardSpec) -> Node {
    let mut ops = vec![
        Op::Comment("GetFile — HTTP GET /ui/ui.wasm (guest blob; not a netdev, not a VFS)".into()),
        Op::Glob("GetFile".into()),
        Op::Label("GetFile".into()),
        Op::Comment("GET /ui/ui.wasm".into()),
    ];
    if spec.kernel.http.enable {
        for ch in b"HTTP/1.1 200\n" {
            ops.extend(putc_ops(i64::from(*ch)));
        }
    }
    for ch in b"GET /ui/ui.wasm\n" {
        ops.extend(putc_ops(i64::from(*ch)));
    }
    ops.push(Op::Jalr {
        rd: X0,
        rs: RA,
        imm: 0,
    });
    Node {
        purpose: Purpose::Http,
        ops,
    }
}

fn ui_file_paths(spec: &BoardSpec) -> Vec<&'static str> {
    let mut p = Vec::new();
    if spec.kernel.http.files.html {
        p.push("/ui/index.html");
    }
    if spec.kernel.http.files.js {
        p.push("/ui/app.js");
    }
    if spec.kernel.wasm.enable || spec.kernel.http.files.wasm {
        p.push("/ui/ui.wasm");
    }
    // Host FileServe (`g6b-http::files::mount`) may list `/ui/pglite/*` when
    // `pglite.files` and dist bytes are live. The guest advert is hardcoded
    // here and grows only for `pglite.embed` (bytes already in `.rodata`).
    // Do not call `mount()` — that would bake host `.tools/` into every ELF.
    if spec.kernel.store.pglite_embed {
        p.push("/ui/pglite/pglite.wasm");
        p.push("/ui/pglite/initdb.wasm");
        p.push("/ui/pglite/pglite.data");
        if spec.kernel.store.pglite_js {
            p.push("/ui/pglite/index.js");
        }
    }
    p
}

fn file_list_ops(spec: &BoardSpec) -> Vec<Op> {
    let paths = ui_file_paths(spec);
    let mut ops = vec![Op::Comment(format!("FILE {}", paths.join(" ")))];
    for ch in b"FILE\n" {
        ops.extend(putc_ops(i64::from(*ch)));
    }
    for path in paths {
        for ch in path.bytes() {
            ops.extend(putc_ops(i64::from(ch)));
        }
        ops.extend(putc_ops(i64::from(b'\n')));
    }
    ops
}

fn file_serve_node(spec: &BoardSpec) -> Node {
    let nfiles = ui_file_paths(spec).len() as i64;
    let live = spec.kernel.wasm.enable || spec.kernel.http.files.enable;
    let mut ops = vec![
        Op::Comment(
            "FileServe — echo \\0asm at G6UI+24, nfiles at +28; print /ui paths (not a VFS)".into(),
        ),
        Op::Glob("FileServe".into()),
        Op::Label("FileServe".into()),
    ];
    if live {
        ops.push(Op::La {
            rd: T0,
            addr: Addr::UiBlob,
        });
        if spec.isa.xlen == 64 {
            ops.push(Op::Ld {
                rd: T1,
                rs: T0,
                off: 16,
            });
        } else {
            ops.push(Op::Lw {
                rd: T1,
                rs: T0,
                off: 16,
            });
        }
        ops.extend([
            Op::Beq {
                rs1: T1,
                rs2: X0,
                to: "fileserve_list".into(),
            },
            Op::Lw {
                rd: T2,
                rs: T1,
                off: 0,
            },
            Op::Sw {
                rs2: T2,
                rs1: T0,
                off: 24,
            },
            Op::Label("fileserve_list".into()),
            Op::Li {
                rd: T1,
                imm: nfiles,
            },
            Op::Sw {
                rs2: T1,
                rs1: T0,
                off: 28,
            },
        ]);
    }
    ops.extend(file_list_ops(spec));
    ops.push(Op::Jalr {
        rd: X0,
        rs: RA,
        imm: 0,
    });
    Node {
        purpose: Purpose::FileServe,
        ops,
    }
}

fn ui_wasm_bytes(spec: &BoardSpec) -> &'static [u8] {
    if spec.kernel.wasm.enable || spec.kernel.http.files.wasm {
        // Guest GET `/ui/ui.wasm` is the LDC cell when present. The MVP
        // encoder blob remains the input to `start_ops` (VGA glyph demo).
        if BIOS_UI_LIBWASM.starts_with(b"\0asm\x01") {
            BIOS_UI_LIBWASM
        } else {
            BIOS_UI_WASM
        }
    } else {
        &[]
    }
}

fn ui_wasm_len(spec: &BoardSpec) -> i64 {
    ui_wasm_bytes(spec).len() as i64
}

fn ui_flags(spec: &BoardSpec) -> i64 {
    let mut f = 0i64;
    if spec.kernel.wasm.enable {
        f |= 1;
    }
    if spec.kernel.http.files.js {
        f |= 2;
    }
    if spec.kernel.http.files.html {
        f |= 4;
    }
    if spec.kernel.proxy.gl {
        f |= 8;
    }
    match spec.proxy_accel() {
        g6b_spec::ProxyAccel::Rvv => f |= 16,
        g6b_spec::ProxyAccel::AiIsland => f |= 32,
        g6b_spec::ProxyAccel::Off => {}
    }
    if spec.kernel.wasm.jit {
        f |= 64;
    }
    f
}

fn wasm_jit_call_node(o: Object) -> Node {
    Node {
        purpose: Purpose::WasmJit,
        ops: vec![
            Op::Comment(format!("{} — jal WasmJit (i32.add leaf)", o.why)),
            Op::Jal {
                rd: RA,
                to: "WasmJit".into(),
            },
        ],
    }
}

fn jit_call_node() -> Node {
    Node {
        purpose: Purpose::WasmJit,
        ops: vec![
            Op::Comment("guest JIT — jal JitRun (translate __jit_in → run)".into()),
            Op::Jal {
                rd: RA,
                to: "JitRun".into(),
            },
        ],
    }
}

/// `jal DomtBoot; jal DomtLayout; jal DomtRaster` — seed the M2 demo DOM tree
/// (no-op when the cell already populated `__dom`), compute the block-flow
/// rects, and raster the dirty nodes into `__scan_fb`. Runs in normal boot
/// context; the s-regs the raster pass uses are caller-saved here.
fn domt_boot_call_node(spec: &BoardSpec) -> Node {
    // `DomtBoot` always runs — it seeds the demo tree when the cell left
    // `__dom` empty. The raster is different: on a board whose picker shares
    // the plane (`faces_share_plane`), the picker is the power-on face and the
    // browser must not paint over it — the face-gated timer tick lays out and
    // rasters `__dom` only once the browser owns the plane. On a
    // browser-owns-the-plane build there is no picker, so the raster runs here
    // to put the DOM on the power-on frame.
    let mut ops = vec![
        Op::Comment("guest DOM — DomtBoot seeds __dom; raster is face-gated".into()),
        Op::Jal {
            rd: RA,
            to: "DomtBoot".into(),
        },
    ];
    if !faces_share_plane(spec) {
        // The packed scene is the power-on frame when one is installed —
        // `WebPaint` paints it (or reports the canvas already live) and the
        // text rasterizer stays out of its surface.
        ops.push(Op::Jal {
            rd: RA,
            to: "WebPaint".into(),
        });
        ops.push(Op::Bne {
            rs1: A0,
            rs2: X0,
            to: "domt_boot_pk".into(),
        });
        ops.push(Op::Jal {
            rd: RA,
            to: "DomtLayout".into(),
        });
        ops.push(Op::Jal {
            rd: RA,
            to: "DomtRaster".into(),
        });
        ops.push(Op::Label("domt_boot_pk".into()));
    }
    let _ = spec;
    Node {
        purpose: Purpose::UiDom,
        ops,
    }
}

/// True when the guest paints the `g6b-zealcli` container itself: a CLI face and a
/// plane to paint it on.
///
/// **The web engine is not an exclusion.** `kernel.cli.boot=auto` means the
/// minimally dependent face boots *first* even on a build that carries wasm, JS,
/// DOM and CSS — the operator gets the boot picker at power-on, and the browser
/// takes the plane only when the picker's "BIOS UI" entry is taken (or `LoadUI`
/// runs). Excluding the container under `wasm.jit`, as this predicate used to, meant
/// a complete build had no picker at all in the guest: the screen went straight to
/// the web UI and the CLI-first rule held only in the host log.
/// [`crate::FACE_OWNER_OFF`] is what keeps the two faces off each other's plane.
pub fn wants_cli_face(spec: &BoardSpec) -> bool {
    spec.kernel.cli.enable && (spec.kernel.gr.enable || spec.kernel.proxy.enable)
}

/// True when both faces are compiled, so ownership has to be decided at runtime.
pub fn faces_share_plane(spec: &BoardSpec) -> bool {
    wants_cli_face(spec) && spec.kernel.wasm.jit
}

/// `if FACE_OWNER != want { goto skip }` — the runtime ownership test.
fn face_is(want: i64, skip: &str) -> Vec<Op> {
    vec![
        Op::La {
            rd: T0,
            addr: Addr::UartLine,
        },
        Op::Lw {
            rd: T1,
            rs: T0,
            off: crate::FACE_OWNER_OFF,
        },
        Op::Li { rd: T2, imm: want },
        Op::Bne {
            rs1: T1,
            rs2: T2,
            to: skip.to_string(),
        },
    ]
}

/// The scanout commits that follow a plane paint: whichever backends this board
/// actually has. Shared by the timer tick and the band-line path so a frame is
/// presented the same way however it was triggered.
fn paint_commit_ops(spec: &BoardSpec) -> Vec<Op> {
    let plane = spec.kernel.gr.enable || spec.kernel.proxy.enable;
    let mut ops = Vec::new();
    if spec.wants_virtio_gpu() && plane {
        ops.push(Op::Jal {
            rd: RA,
            to: "VioPaint".into(),
        });
    }
    if spec.wants_disp_scan() {
        ops.push(Op::Jal {
            rd: RA,
            to: "DispPaint".into(),
        });
    }
    if spec.wants_pci_scan() && plane {
        ops.push(Op::Jal {
            rd: RA,
            to: "PciPaint".into(),
        });
    }
    ops
}

fn cli_call_node() -> Node {
    Node {
        purpose: Purpose::UiDom,
        ops: vec![
            Op::Comment("zealcli face — jal CliInit (container rows → DomPaint)".into()),
            Op::Jal {
                rd: RA,
                to: "CliInit".into(),
            },
        ],
    }
}

fn wasm_ui_call_node(o: Object, spec: &BoardSpec) -> Node {
    let mut ops = vec![Op::Comment(format!(
        "{} — jal WasmUi (DOM rows + paint)",
        o.why
    ))];
    if faces_share_plane(spec) {
        // Both faces are compiled: at power-on the container owns the plane, so
        // this rung does nothing until the picker (or `LoadUI`) flips the latch.
        // Skipping the *call* rather than the paint keeps `WasmStart` from
        // publishing rows over the picker's frame.
        ops.push(Op::Comment(
            "the container owns the plane at power-on; the browser waits for FACE_WEB".into(),
        ));
        ops.extend(face_is(crate::FACE_WEB, "wasm_ui_skip"));
    }
    if spec.kernel.wasm.guest_jit {
        // A live packed scene owns the surface: `WebPaint` paints the carry
        // (a0=1) and the row-table `WasmUi` paint is the fallback for a build
        // with no pack — e.g. the bounded `test` cell.
        ops.push(Op::Jal {
            rd: RA,
            to: "WebPaint".into(),
        });
        ops.push(Op::Bne {
            rs1: A0,
            rs2: X0,
            to: "wasm_ui_skip".into(),
        });
    }
    ops.push(Op::Jal {
        rd: RA,
        to: "WasmUi".into(),
    });
    if faces_share_plane(spec) || spec.kernel.wasm.guest_jit {
        ops.push(Op::Label("wasm_ui_skip".into()));
    }
    Node {
        purpose: Purpose::WasmJit,
        ops,
    }
}

fn wasm_jit_node(o: Object) -> Node {
    Node {
        purpose: Purpose::WasmJit,
        ops: vec![
            Op::Comment(format!(
                "{} — WASM-JIT i32.add → add a0, a0, a1 (not wasmtime)",
                o.why
            )),
            Op::Glob("WasmJit".into()),
            Op::Label("WasmJit".into()),
            Op::Add {
                rd: A0,
                rs1: A0,
                rs2: A1,
            },
            Op::Jalr {
                rd: X0,
                rs: RA,
                imm: 0,
            },
        ],
    }
}

fn ui_init_node(o: Object, spec: &BoardSpec) -> Node {
    let mut ops = vec![
        Op::Comment(format!(
            "{} — G6UI magic + wasm size/ptr at __ui_blob (not a VFS)",
            o.why
        )),
        Op::Glob("UiInit".into()),
        Op::Label("UiInit".into()),
        Op::La {
            rd: T0,
            addr: Addr::UiBlob,
        },
        Op::Li {
            rd: T1,
            imm: i64::from(UI_MAGIC),
        },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: 0,
        },
        Op::Li {
            rd: T1,
            imm: ui_wasm_len(spec),
        },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: 4,
        },
        Op::Li {
            rd: T1,
            imm: ui_flags(spec),
        },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: 8,
        },
        Op::Li {
            rd: T1,
            imm: i64::from(spec.proxy_accel().code()),
        },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: 12,
        },
    ];
    if ui_wasm_bytes(spec).is_empty() {
        ops.push(Op::Li { rd: T1, imm: 0 });
    } else {
        ops.push(Op::La {
            rd: T1,
            addr: Addr::UiWasm,
        });
    }
    if spec.isa.xlen == 64 {
        ops.push(Op::Sd {
            rs2: T1,
            rs1: T0,
            off: 16,
        });
    } else {
        ops.push(Op::Sw {
            rs2: T1,
            rs1: T0,
            off: 16,
        });
    }
    ops.push(Op::Jalr {
        rd: X0,
        rs: RA,
        imm: 0,
    });
    Node {
        purpose: Purpose::FileServe,
        ops,
    }
}

fn gr_init_node(o: Object, spec: &BoardSpec) -> Node {
    let p = g6b_spec_proxy(spec);
    let colors = spec.kernel.gr.colors.max(16);
    let stride = gr_stride(p.0, colors);
    let mut ops = vec![
        Op::Comment(format!(
            "{} — GR16 header + 4bpp scanline @ __gr_plane (not VGA ports)",
            o.why
        )),
        Op::Glob("GrInit".into()),
        Op::Label("GrInit".into()),
        Op::La {
            rd: T0,
            addr: Addr::GrPlane,
        },
        Op::Li {
            rd: T1,
            imm: i64::from(GR16_MAGIC),
        },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: 0,
        },
        Op::Li {
            rd: T1,
            imm: i64::from(p.0),
        },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: 4,
        },
        Op::Li {
            rd: T1,
            imm: i64::from(p.1),
        },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: 8,
        },
        Op::Li {
            rd: T1,
            imm: i64::from(colors),
        },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: 12,
        },
        Op::Li {
            rd: T1,
            imm: i64::from(p.2),
        },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: 16,
        },
        Op::Li {
            rd: T1,
            imm: i64::from(p.3),
        },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: 20,
        },
        Op::Li {
            rd: T1,
            imm: i64::from(p.4),
        },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: 24,
        },
        Op::Li {
            rd: T1,
            imm: i64::from(p.5),
        },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: 28,
        },
        Op::Li {
            rd: T1,
            imm: i64::from(p.7),
        },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: 32,
        },
        Op::Li {
            rd: T1,
            imm: i64::from(stride),
        },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: 36,
        },
        Op::Li {
            rd: T1,
            imm: i64::from(GR_HEADER_BYTES as u32),
        },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: 40,
        },
        Op::Addi {
            rd: T2,
            rs: T0,
            imm: GR_HEADER_BYTES as i32,
        },
        Op::Li {
            rd: T1,
            imm: i64::from(stride),
        },
        Op::Li {
            rd: A2,
            imm: i64::from(GR_FILL_WORD),
        },
        Op::Label("gr_fill".into()),
        Op::Beq {
            rs1: T1,
            rs2: X0,
            to: "gr_fill_done".into(),
        },
        Op::Sw {
            rs2: A2,
            rs1: T2,
            off: 0,
        },
        Op::Addi {
            rd: T2,
            rs: T2,
            imm: 4,
        },
        Op::Addi {
            rd: T1,
            rs: T1,
            imm: -4,
        },
        Op::Jal {
            rd: X0,
            to: "gr_fill".into(),
        },
        Op::Label("gr_fill_done".into()),
    ];
    ops.extend(gr_blit_g6lc_ops(stride));
    ops.push(Op::Jalr {
        rd: X0,
        rs: RA,
        imm: 0,
    });
    Node {
        purpose: Purpose::DisplayProxy,
        ops,
    }
}

/// Same 8×8 bits as `g6b-gr::glyph_row` for G/6/L/C (banner; not VGA ROM).
fn font_g6lc() -> [[u8; 8]; 4] {
    [
        [0x3C, 0x66, 0x60, 0x6E, 0x66, 0x66, 0x3C, 0], // G
        [0x1C, 0x30, 0x60, 0x7C, 0x66, 0x66, 0x3C, 0], // 6
        [0x60, 0x60, 0x60, 0x60, 0x60, 0x66, 0x7E, 0], // L
        [0x3C, 0x66, 0x60, 0x60, 0x60, 0x66, 0x3C, 0], // C
    ]
}

/// Pack one 8-pixel font row into a little-endian 4bpp word (high nibble = left).
fn pack_glyph_row_4bpp(bits: u8, fg: u8, bg: u8) -> u32 {
    crate::font::pack_row_4bpp(bits, fg, bg)
}

/// Blit `G6LC` at (0, 8) in colour 15 on black (below the boot scanline).
fn gr_blit_g6lc_ops(stride: u32) -> Vec<Op> {
    let font = font_g6lc();
    let row0 = i64::from(stride.saturating_mul(8));
    let mut ops = vec![
        Op::Comment("8x8 blit G6LC @ (0,8) 4bpp (same bits as g6b-gr; not VGA)".into()),
        Op::Label("gr_blit".into()),
        Op::La {
            rd: T0,
            addr: Addr::GrPlane,
        },
        Op::Addi {
            rd: T0,
            rs: T0,
            imm: GR_HEADER_BYTES as i32,
        },
        Op::Li { rd: T1, imm: row0 },
        Op::Add {
            rd: T0,
            rs1: T0,
            rs2: T1,
        },
        Op::Li {
            rd: A2,
            imm: i64::from(stride),
        },
        Op::Addi {
            rd: T2,
            rs: T0,
            imm: 0,
        },
    ];
    for row in 0..8 {
        if row > 0 {
            ops.push(Op::Add {
                rd: T2,
                rs1: T2,
                rs2: A2,
            });
        }
        for (g, glyph) in font.iter().enumerate() {
            let packed = pack_glyph_row_4bpp(glyph[row], 0xF, 0);
            ops.push(Op::Li {
                rd: T1,
                imm: i64::from(packed),
            });
            ops.push(Op::Sw {
                rs2: T1,
                rs1: T2,
                off: (g as i32) * 4,
            });
        }
    }
    ops
}

fn proxy_geom_node(o: Object, spec: &BoardSpec) -> Node {
    let p = g6b_spec_proxy(spec);
    let mut ops = vec![
        Op::Comment(format!(
            "{} — {}x{}→{}x{} dpi={} fps={} mode={} scale={} accel={}",
            o.why,
            p.0,
            p.1,
            p.2,
            p.3,
            p.4,
            p.5,
            p.6,
            p.7,
            spec.proxy_accel().as_str()
        )),
        Op::Label("proxy_geom".into()),
    ];
    for w in [p.0, p.1, p.2, p.3, p.4, p.5, p.7, spec.proxy_accel().code()] {
        ops.push(Op::Word(w));
    }
    // Output table, appended after the eight legacy geometry words so existing
    // readers keep their fixed offsets. Header is
    // `{count, default_idx, default_surface}`, then one 6-word record per
    // candidate output: `{class_code, priority, w, h, stride, surface}`.
    // These are the *declared* candidates — `DispSel` resolves which one is
    // actually present at boot and latches the answer in `__disp`.
    let outs = spec.display_outputs();
    let default_surface = spec.default_surface();
    ops.push(Op::Comment(format!(
        "proxy_outputs — {} candidate(s), default {} surface={}",
        outs.len(),
        outs.first().map(|o| o.id.as_str()).unwrap_or("none"),
        default_surface.as_str()
    )));
    ops.push(Op::Label("proxy_outputs".into()));
    for w in [outs.len() as u32, 0, default_surface.code()] {
        ops.push(Op::Word(w));
    }
    for o in &outs {
        ops.push(Op::Comment(format!(
            "  {} {} pri={} {}x{} surface={}",
            o.id,
            o.class.as_str(),
            o.class.priority(),
            o.w,
            o.h,
            o.surface.as_str()
        )));
        for w in [
            o.class.code(),
            o.class.priority(),
            o.w,
            o.h,
            o.stride(),
            o.surface.code(),
        ] {
            ops.push(Op::Word(w));
        }
    }
    Node {
        purpose: Purpose::DisplayProxy,
        ops,
    }
}

/// Words per `proxy_outputs` record: `{class, priority, w, h, stride, surface}`.
pub const PROXY_OUT_WORDS: usize = 6;
/// Header words before the first record: `{count, default_idx, surface}`.
pub const PROXY_OUT_HEADER: usize = 3;

pub(crate) fn g6b_spec_proxy(spec: &BoardSpec) -> (u32, u32, u32, u32, u32, u32, String, u32) {
    let g = &spec.kernel.gr;
    let p = &spec.kernel.proxy;
    let lw = if g.enable { g.w.max(8) } else { 640 };
    let lh = if g.enable { g.h.max(8) } else { 480 };
    let hw = if p.enable { p.high_w.max(lw) } else { lw };
    let hh = if p.enable { p.high_h.max(lh) } else { lh };
    let dpi = if p.enable { p.dpi } else { 96 };
    let fps = p.refresh_hz();
    let mode = if p.scale_mode.is_empty() {
        "fit".into()
    } else {
        p.scale_mode.clone()
    };
    let sx = hw / lw;
    let sy = hh / lh;
    let fit = sx.min(sy).max(1);
    let scale = match mode.as_str() {
        "fill" => sx.max(sy).max(1),
        "dpi" => (dpi / 96).max(1).min(fit),
        _ => fit,
    };
    (lw, lh, hw, hh, dpi, fps, mode, scale)
}

fn gl_adapter_node(o: Object, spec: &BoardSpec) -> Node {
    let accel = spec.proxy_accel();
    let mut ops = vec![
        Op::Comment(format!(
            "{} — GLES2 high-DPI composite accel={}",
            o.why,
            accel.as_str()
        )),
        Op::Glob("ProxyScale".into()),
        Op::Label("ProxyScale".into()),
    ];
    match accel {
        g6b_spec::ProxyAccel::Rvv => {
            ops.push(Op::Comment(
                "RVV scale blit: vsetvli e8 m1; plane stays __gr_plane".into(),
            ));
            ops.push(Op::Vsetvli {
                rd: T0,
                rs1: A2,
                vtype: VTYPE_E8_M1_TA_MA,
            });
            ops.push(Op::Vle8 { vd: 0, rs1: A1 });
            ops.push(Op::Vse8 { vs3: 0, rs1: A0 });
        }
        g6b_spec::ProxyAccel::AiIsland => {
            ops.push(Op::Comment(
                "ai-island 16x16 tiles; GEMM MMIO 0x40000000 is not the GR plane".into(),
            ));
        }
        g6b_spec::ProxyAccel::Off => {
            ops.push(Op::Comment("scalar nearest-neighbour scale".into()));
        }
    }
    ops.push(Op::Jalr {
        rd: X0,
        rs: RA,
        imm: 0,
    });
    Node {
        purpose: Purpose::GlAdapter,
        ops,
    }
}

fn memcpy_node(xlen: u32, rvv: bool) -> Node {
    let marker = if rvv { "ISEL-RVV" } else { "ISEL-SCALAR" };
    let mut ops = vec![
        Op::Comment(format!(
            "{marker} MemCpy — ISel rewrite of Compiler/Back* (xlen={xlen})"
        )),
        Op::Glob("MemCpy".into()),
        Op::Label("MemCpy".into()),
        Op::Beq {
            rs1: A2,
            rs2: X0,
            to: "memcpy_done".into(),
        },
        Op::Label("memcpy_loop".into()),
    ];
    if rvv {
        ops.extend([
            Op::Vsetvli {
                rd: T0,
                rs1: A2,
                vtype: VTYPE_E8_M1_TA_MA,
            },
            Op::Vle8 { vd: 0, rs1: A1 },
            Op::Vse8 { vs3: 0, rs1: A0 },
            Op::Add {
                rd: A0,
                rs1: A0,
                rs2: T0,
            },
            Op::Add {
                rd: A1,
                rs1: A1,
                rs2: T0,
            },
            Op::Sub {
                rd: A2,
                rs1: A2,
                rs2: T0,
            },
        ]);
    } else {
        ops.extend([
            Op::Lbu {
                rd: T0,
                rs: A1,
                off: 0,
            },
            Op::Sb {
                rs2: T0,
                rs1: A0,
                off: 0,
            },
            Op::Addi {
                rd: A0,
                rs: A0,
                imm: 1,
            },
            Op::Addi {
                rd: A1,
                rs: A1,
                imm: 1,
            },
            Op::Addi {
                rd: A2,
                rs: A2,
                imm: -1,
            },
        ]);
    }
    ops.extend([
        Op::Bne {
            rs1: A2,
            rs2: X0,
            to: "memcpy_loop".into(),
        },
        Op::Label("memcpy_done".into()),
        Op::Jalr {
            rd: X0,
            rs: RA,
            imm: 0,
        },
    ]);
    Node {
        purpose: Purpose::MemCpy,
        ops,
    }
}

fn reboot_node() -> Node {
    Node {
        purpose: Purpose::Reboot,
        ops: vec![
            Op::Comment(
                "Reboot — SBI SRST (eid 0x53525354); not a PC keyboard-controller reset".into(),
            ),
            Op::Glob("Reboot".into()),
            Op::Label("Reboot".into()),
            Op::Li {
                rd: A7,
                imm: SBI_SRST_EID,
            },
            Op::Li { rd: A6, imm: 0 },
            Op::Li { rd: A0, imm: 1 },
            Op::Li { rd: A1, imm: 0 },
            Op::Ecall,
            Op::Jalr {
                rd: X0,
                rs: RA,
                imm: 0,
            },
        ],
    }
}

fn parse_hex(s: &str) -> Option<u64> {
    let t = s
        .trim()
        .trim_start_matches("0x")
        .trim_start_matches("0X")
        .replace('_', "");
    u64::from_str_radix(&t, 16).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::encode;

    fn spec_json(s: &str) -> BoardSpec {
        BoardSpec::from_json_str(s).unwrap()
    }

    #[test]
    fn objects_tag_homes() {
        let spec = spec_json(
            r#"{"schema_version":1,"isa":{"xlen":64,"march":"rv64imac"},"holyc":{"dual_band":{"tcp":{"enable":false}}},"postboot":{"enable":"never"}}"#,
        );
        let objs = objects(&spec);
        let hart = objs.iter().find(|o| o.purpose == Purpose::HartId).unwrap();
        assert!(hart.live);
        assert_eq!(hart.home(), "tp");
        let uart = objs
            .iter()
            .find(|o| o.purpose == Purpose::Uart1Repl)
            .unwrap();
        assert!(!uart.live);
        let memcpy = objs.iter().find(|o| o.purpose == Purpose::MemCpy).unwrap();
        assert_eq!(memcpy.home(), "a0,a1,a2");
    }

    #[test]
    fn timer_and_trap_are_sbi_time_not_pit() {
        let spec = spec_json(r#"{"schema_version":1,"isa":{"xlen":64}}"#);
        let t = timer(&spec).to_asm();
        assert!(t.contains("purpose=timer"), "{t}");
        assert!(t.contains("sie"), "{t}");
        assert!(t.contains("sstatus"), "{t}");
        assert!(t.contains("rdtime"), "{t}");
        assert!(t.contains("0x54494d45"), "{t}");
        let k = kints(&spec).to_asm();
        assert!(k.contains("trap_timer"), "{k}");
        assert!(k.contains("trap_ssi"), "{k}");
        assert!(k.contains("trap_sei"), "{k}");
        assert!(k.contains("trap_uart"), "{k}");
        assert!(k.contains("uart_line_go"), "{k}");
        assert!(k.contains("uart_view"), "{k}");
        assert!(k.contains("uart_ui"), "{k}");
        assert!(k.contains("uart_file"), "{k}");
        assert!(k.contains("uart_get"), "{k}");
        assert!(k.contains("FileServe"), "{k}");
        assert!(k.contains("GetFile"), "{k}");
        assert!(k.contains("view_findq"), "{k}");
        assert!(k.contains("view_copy"), "{k}");
        assert!(k.contains("0x77656956") || k.contains("View"), "{k}");
        assert!(!k.contains("trap_mbox"), "{k}");
        assert!(k.contains("trap_fault"), "{k}");
        assert!(k.contains("trap_halt"), "{k}");
        assert!(k.contains("hexdig"), "{k}");
        assert!(k.contains("scause"), "{k}");
        assert!(k.contains("srli"), "{k}");
        assert!(k.contains("rdtime"), "{k}");
        assert!(!k.contains("IRET"), "{k}");
    }

    #[test]
    fn kstart_calls_mboxinit_and_trap_mbox() {
        let spec = spec_json(
            r#"{"schema_version":1,"isa":{"xlen":64},"uncore":{"plic":true},"loopback":{"enable":true},"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        );
        let s = kstart(&spec).to_asm();
        let jal = s.find("jal\tra, MboxInit").unwrap_or(usize::MAX);
        let park = s.find("\npark:").unwrap_or(0);
        let body = s.find("\nMboxInit:").unwrap_or(0);
        assert!(jal < park, "MboxInit must be called before park:\n{s}");
        assert!(park < body, "MboxInit body must sit after park:\n{s}");
        assert!(s.contains("KSTART-MBOX"), "{s}");
        assert!(s.contains("trap_mbox"), "{s}");
        assert!(s.contains("mbox_view"), "{s}");
        assert!(s.contains("mbox_ui"), "{s}");
        assert!(s.contains("mbox_file"), "{s}");
        assert!(s.contains("mbox_get"), "{s}");
        assert!(s.contains("mbox_reboot"), "{s}");
        assert!(!s.contains("LAPIC"), "{s}");
        let k = kints(&spec).to_asm();
        assert!(k.contains("trap_mbox"), "{k}");
        assert!(k.contains("mbox_view"), "{k}");
    }

    #[test]
    fn kstart_probes_virtio_gpu_only_when_argv_would_attach() {
        let spec = spec_json(
            r#"{"schema_version":1,"isa":{"xlen":64},"kernel":{"gr":{"enable":true,"w":640,"h":480,"colors":16,"backend":"virtio-gpu"}}}"#,
        );
        assert!(live_objects(&spec)
            .iter()
            .any(|o| o.purpose == Purpose::Virtio));
        let s = kstart(&spec).to_asm();
        let jal = s.find("jal\tra, VioProbe").unwrap_or(usize::MAX);
        let park = s.find("\npark:").unwrap_or(0);
        let body = s.find("\nVioProbe:").unwrap_or(0);
        assert!(jal < park, "VioProbe must be called before park:\n{s}");
        assert!(park < body, "VioProbe body must sit after park:\n{s}");
        // Marker text is emitted as `li` immediates; the magic is literal.
        assert!(s.contains("0x74726976"), "{s}"); // "virt" MagicValue
        assert!(s.contains("0x10001000"), "{s}");
        // No GPU backend → no probe object, no marker.
        let spec_off = spec_json(r#"{"schema_version":1,"isa":{"xlen":64}}"#);
        assert!(!live_objects(&spec_off)
            .iter()
            .any(|o| o.purpose == Purpose::Virtio));
        let s_off = kstart(&spec_off).to_asm();
        assert!(!s_off.contains("VioProbe"), "{s_off}");
    }

    #[test]
    fn kstart_probes_virtio_net_without_qemu_netdev() {
        let spec = spec_json(
            r#"{"schema_version":1,"isa":{"xlen":64},"kernel":{"hw":{"enable":true,"virtio_net":true}}}"#,
        );
        assert!(spec.wants_virtio_net());
        assert!(live_objects(&spec)
            .iter()
            .any(|o| o.purpose == Purpose::VirtioNet));
        let s = kstart(&spec).to_asm();
        let jal = s.find("jal\tra, VioNetProbe").unwrap_or(usize::MAX);
        let park = s.find("\npark:").unwrap_or(0);
        let body = s.find("\nVioNetProbe:").unwrap_or(0);
        assert!(jal < park, "VioNetProbe must be called before park:\n{s}");
        assert!(park < body, "VioNetProbe body must sit after park:\n{s}");
        assert!(s.contains("0x74726976"), "{s}");
        let spec_off = spec_json(r#"{"schema_version":1,"isa":{"xlen":64}}"#);
        assert!(!spec_off.wants_virtio_net());
        let s_off = kstart(&spec_off).to_asm();
        assert!(!s_off.contains("VioNetProbe"), "{s_off}");
    }

    #[test]
    fn kstart_calls_timerinit_before_park() {
        let spec = spec_json(r#"{"schema_version":1,"isa":{"xlen":64}}"#);
        let s = kstart(&spec).to_asm();
        let jal = s.find("jal\tra, TimerInit").unwrap_or(usize::MAX);
        let park = s.find("\npark:").unwrap_or(0);
        let body = s.find("\nTimerInit:").unwrap_or(0);
        assert!(jal < park, "TimerInit must be called before park:\n{s}");
        assert!(park < body, "TimerInit body must sit after park:\n{s}");
        assert!(s.contains("rdtime"), "{s}");
    }

    #[test]
    fn proxy_geom_words_in_payload() {
        let spec = spec_json(
            r#"{"schema_version":1,"isa":{"xlen":64},"kernel":{"gr":{"enable":true,"w":640,"h":480},"proxy":{"enable":true,"link":"hdmi","high_w":1920,"high_h":1080,"dpi":192,"scale_mode":"dpi"}}}"#,
        );
        let s = kstart(&spec).to_asm();
        let jal = s.find("jal\tra, GrInit").unwrap_or(usize::MAX);
        let park = s.find("\npark:").unwrap_or(0);
        let body = s.find("\nGrInit:").unwrap_or(0);
        assert!(jal < park, "GrInit must be called before park:\n{s}");
        assert!(park < body, "GrInit body must sit after park:\n{s}");
        assert!(s.contains("KSTART-GR"), "{s}");
        assert!(s.contains("KSTART-GR-PLANE"), "{s}");
        assert!(s.contains("__gr_plane"), "{s}");
        assert!(s.contains("gr_fill"), "{s}");
        assert!(s.contains("gr_blit"), "{s}");
        assert!(s.contains("KSTART-GR-FONT"), "{s}");
        assert!(!s.contains("VGAM"), "{s}");
        assert_eq!(
            pack_glyph_row_4bpp(0x3C, 0xF, 0),
            0x00FF_FF00,
            "G row0 4bpp pack"
        );
        let m = payload(&spec, b"x\0");
        assert_eq!(m.gr_bytes, gr_bss_len(640, 480, 16));
        let (w, _) = m.to_words(0x8020_0000).unwrap();
        let needle = [640u32, 480, 1920, 1080];
        assert!(
            w.windows(4).any(|s| s == needle),
            "missing proxy_geom words in payload"
        );
    }

    #[test]
    fn kstart_calls_uiinit_and_embeds_wasm() {
        let spec = spec_json(
            r#"{"schema_version":1,"isa":{"xlen":64},"kernel":{"wasm":{"enable":true,"jit":true},"proxy":{"enable":true,"link":"hdmi","high_w":1920,"high_h":1080,"dpi":192,"gl":true}},"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        );
        let m = kstart(&spec);
        let s = m.to_asm();
        let jal_ui = s.find("jal\tra, UiInit").unwrap_or(usize::MAX);
        let jal_file = s.find("jal\tra, FileServe").unwrap_or(usize::MAX);
        let jal_get = s.find("jal\tra, GetFile").unwrap_or(usize::MAX);
        let jal_gl = s.find("jal\tra, ProxyScale").unwrap_or(usize::MAX);
        let jal_jit = s.find("jal\tra, WasmJit").unwrap_or(usize::MAX);
        let park = s.find("\npark:").unwrap_or(0);
        let body = s.find("\nUiInit:").unwrap_or(0);
        let file_body = s.find("\nFileServe:").unwrap_or(0);
        let get_body = s.find("\nGetFile:").unwrap_or(0);
        assert!(jal_gl < park, "ProxyScale must be called before park:\n{s}");
        assert!(jal_ui < park, "UiInit must be called before park:\n{s}");
        assert!(
            jal_file < park,
            "FileServe must be called before park:\n{s}"
        );
        assert!(jal_get < park, "GetFile must be called before park:\n{s}");
        assert!(jal_jit < park, "WasmJit must be called before park:\n{s}");
        assert!(park < body, "UiInit body must sit after park:\n{s}");
        assert!(park < file_body, "FileServe body must sit after park:\n{s}");
        assert!(park < get_body, "GetFile body must sit after park:\n{s}");
        assert!(s.contains("KSTART-UI"), "{s}");
        assert!(s.contains("KSTART-FILE"), "{s}");
        assert!(s.contains("KSTART-GET"), "{s}");
        assert!(s.contains("GET /ui/ui.wasm"), "{s}");
        assert!(s.contains("KSTART-PROXY-SCALE"), "{s}");
        assert!(s.contains("KSTART-WASM-JIT"), "{s}");
        assert!(s.contains("/ui/ui.wasm"), "{s}");
        assert!(s.contains("__ui_blob"), "{s}");
        assert!(s.contains("__ui_wasm"), "{s}");
        assert_eq!(m.ui_bytes, UI_HEADER_BYTES);
        assert_eq!(m.ui_wasm, ui_wasm_bytes(&spec));
        assert!(!s.contains("/ui/pglite/pglite.wasm"), "{s}");
        let embed = spec_json(
            r#"{"schema_version":1,"isa":{"xlen":64},"kernel":{"wasm":{"enable":true},"store":{"pglite":{"embed":true}}}}"#,
        );
        let embed_asm = kstart(&embed).to_asm();
        assert!(embed_asm.contains("/ui/pglite/pglite.wasm"), "{embed_asm}");
        assert!(embed_asm.contains("/ui/pglite/initdb.wasm"), "{embed_asm}");
        assert!(!embed_asm.contains("/ui/pglite/index.js"), "{embed_asm}");
        let (_, ro) = payload(&spec, b"x\0").to_words(0x8020_0000).unwrap();
        assert!(
            ro.windows(4).any(|w| w == b"\0asm"),
            "guest ELF rodata must embed the UI wasm cell"
        );
    }

    #[test]
    fn uart1_live_when_tcp() {
        let spec = spec_json(
            r#"{"schema_version":1,"isa":{"xlen":64,"march":"rv64imac"},"holyc":{"dual_band":{"tcp":{"enable":true,"host_port":2222}}}}"#,
        );
        assert!(live_objects(&spec)
            .iter()
            .any(|o| o.purpose == Purpose::Uart1Repl));
        // QEMU virt instantiates all 8 virtio-mmio transports (0x1000 stride)
        // whether or not a device is attached — the modeled UART1 sits above
        // the window either way.
        assert_eq!(uart1_base(&spec), 0x1000_9000);
        let spec_gpu = spec_json(
            r#"{"schema_version":1,"isa":{"xlen":64},"kernel":{"gr":{"enable":true,"backend":"virtio-gpu"}},"holyc":{"dual_band":{"tcp":{"enable":true,"host_port":2222}}}}"#,
        );
        assert!(spec_gpu.wants_virtio_gpu());
        assert_eq!(uart1_base(&spec_gpu), 0x1000_9000);
        let s = kstart(&spec).to_asm();
        assert!(s.contains("IER.ERBFI"), "{s}");
        assert!(!s.contains("uart1_poll"), "{s}");
        let ier = s.find("IER.ERBFI").expect(&s);
        let park = s.find("\npark:").expect(&s);
        assert!(ier < park, "UART1 IER must be set before park:\n{s}");
    }

    #[test]
    fn kstart_asm_has_state() {
        let spec = spec_json(r#"{"schema_version":1,"isa":{"xlen":64,"march":"rv64imac"}}"#);
        let s = kstart(&spec).to_asm();
        assert!(s.contains("purpose=hart-id"), "{s}");
        assert!(s.contains("mv\ttp, a0"), "{s}");
        assert!(s.contains("csrw\tstvec"), "{s}");
        assert!(s.contains("csrw\tsatp"), "{s}");
        assert!(s.contains("sfence.vma"), "{s}");
        assert!(s.contains("KSTART-SATP-BARE"), "{s}");
        assert!(s.contains("KSTART-UART0"), "{s}");
        assert!(s.contains("uart0_tx"), "{s}");
        assert!(s.contains("KSTART-UART0-8N1"), "{s}");
        assert!(s.contains("8N1"), "{s}");
        assert!(s.contains("la\tt2, __stacks_end"), "{s}");
        assert!(s.contains("slli"), "{s}");
        assert!(s.contains("KSTART-XLEN-64"), "{s}");
        assert!(s.contains("KSTART-TIMER"), "{s}");
        assert!(s.contains("KSTART-UART-IRQ"), "{s}");
        assert!(s.contains("KSTART-UART-LINE"), "{s}");
        assert!(s.contains("KSTART-UART-CMD"), "{s}");
        assert!(s.contains("KSTART-UART-VIEWSEC"), "{s}");
        assert!(s.contains("KSTART-UART-UI"), "{s}");
        assert!(s.contains("KSTART-UART-FILE"), "{s}");
        assert!(s.contains("KSTART-UART-GET"), "{s}");
        assert!(s.contains("view_findq"), "{s}");
        assert!(s.contains("__uart_line"), "{s}");
        assert!(s.contains("trap_uart"), "{s}");
        assert!(s.contains("purpose=timer"), "{s}");
        assert!(!s.contains("EFER") && !s.contains("CR0"));
    }

    /// An unhandled virtio-mmio source must be acked **at the device**, not only
    /// completed at the PLIC.
    ///
    /// This is a starvation bug that was found on QEMU: with two
    /// `virtio-blk-device`s next to the GPU and keyboard, keystrokes stopped
    /// arriving while both devices still probed `OK`. A virtio-mmio interrupt is
    /// level-triggered, so completing the claim does not lower the line — a device
    /// this BIOS has no driver for re-asserted immediately and the hart never left
    /// `trap_sei`.
    #[test]
    fn an_unhandled_virtio_source_is_acked_at_the_device() {
        let spec = spec_json(
            r#"{"schema_version":1,"isa":{"xlen":64},"uncore":{"plic":true},"kernel":{"gr":{"enable":true,"backend":"virtio-gpu"}}}"#,
        );
        let s = kints(&spec).to_asm();
        // The *label*, not the branch that targets it.
        let ack = s.find("\ntrap_vio_ack").expect(&s);
        let done = s[ack..]
            .find("\ntrap_done")
            .map(|i| i + ack)
            .unwrap_or(s.len());
        assert!(
            ack < done,
            "the ack path comes before the shared exit:\n{s}"
        );
        // It reads InterruptStatus and writes InterruptACK on the *computed*
        // device base, so a slot with no driver still gets its line lowered.
        let tail = &s[ack..done];
        // Offsets are printed in decimal by the listing writer.
        assert!(
            tail.contains(&format!("{}(t1)", crate::encode::VIO_REG_ISR_STATUS)),
            "reads InterruptStatus:\n{tail}"
        );
        assert!(
            tail.contains(&format!("{}(t1)", crate::encode::VIO_REG_ISR_ACK)),
            "writes InterruptACK:\n{tail}"
        );
        assert!(
            tail.contains("mul"),
            "derives the device base from the irq:\n{tail}"
        );
        // A source outside the virtio window is never poked.
        assert!(
            tail.matches("trap_done").count() >= 2,
            "two range guards leave for trap_done:\n{tail}"
        );
    }

    #[test]
    fn all_harts_set_stvec_before_park_split() {
        let spec = spec_json(
            r#"{"schema_version":1,"isa":{"xlen":64},"harts":{"count":2,"cores":1,"threads":2}}"#,
        );
        let s = kstart(&spec).to_asm();
        let stvec = s.find("csrw\tstvec").expect(&s);
        let split = s.find("beqz\ts1, park").expect(&s);
        let park = s.find("\npark:").expect(&s);
        assert!(stvec < split, "stvec must be set on every hart:\n{s}");
        assert!(split < park, "secondaries park after stvec:\n{s}");
        assert!(s.contains("KSTART-STACKS-2"), "{s}");
        assert!(!s.contains("LAPIC"), "{s}");
    }

    #[test]
    fn payload_words_start_with_hartid() {
        let spec = spec_json(
            r#"{"schema_version":1,"isa":{"xlen":64,"march":"rv64imac"},"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        );
        let log = b"KMAIN\0";
        let (w, ro) = payload(&spec, log).to_words(0x8020_0000).unwrap();
        assert_eq!(w[0], encode::addi(TP, A0, 0));
        assert_eq!(ro, log);
        assert!(w.contains(&encode::wfi()));
        assert!(!w.contains(&encode::vsetvli(T0, A2, VTYPE_E8_M1_TA_MA)));
    }

    #[test]
    fn memcpy_rvv_gated() {
        let scalar = memcpy(64, false).to_asm();
        assert!(scalar.contains("lbu"), "{scalar}");
        assert!(scalar.contains("ISEL-SCALAR"), "{scalar}");
        assert!(!scalar.contains("vsetvli"), "{scalar}");
        let vec = memcpy(64, true);
        let s = vec.to_asm();
        assert!(s.contains("vsetvli"), "{s}");
        assert!(s.contains("ISEL-RVV"), "{s}");
        let (w, _) = vec.to_words(0).unwrap();
        assert!(w.contains(&encode::vsetvli(T0, A2, VTYPE_E8_M1_TA_MA)));
    }

    #[test]
    fn reboot_is_sbi() {
        let s = reboot().to_asm();
        assert!(s.contains("0x53525354"), "{s}");
        assert!(s.contains("SRST"), "{s}");
        assert!(!s.to_lowercase().contains("cf9"), "{s}");
    }
}
