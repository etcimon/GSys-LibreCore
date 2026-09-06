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
    A0, A1, A2, A6, A7, CMD_FILE, CMD_GET, CMD_REBO, CMD_SHUT, CMD_UI, CMD_VIEW, CMD_WAKE,
    CSR_SATP, CSR_SCAUSE, CSR_SEPC, CSR_SIE, CSR_SSTATUS, CSR_STVEC, CSR_TIME, GR16_MAGIC,
    GR_FILL_WORD, MBOX_MAGIC, MBOX_OFF_CMD, MBOX_OFF_DOORBELL, MBOX_OFF_IRQ_EN, MBOX_OFF_LENGTH,
    MBOX_OFF_RSP, MBOX_OFF_STATUS, MBOX_RSP_FILE, MBOX_RSP_UI, MBOX_RSP_VIEW, MBOX_RSP_WAKE,
    MBOX_ST_BUSY, MBOX_ST_RSP, PLIC_BASE, PLIC_CTXT_BASE, PLIC_ENABLE_BASE, RA, S1, SBI_HSM_EID,
    SBI_IPI_EID, SBI_PUTCHAR, SBI_SRST_EID, SBI_TIME_EID, SIE_SEIE, SIE_SSIE, SIE_STIE, SP,
    SSTATUS_SIE, T0, T1, T2, T3, T4, TP, UART_IER_RX, UART_IRQ, UART_LSR_DR, UI_MAGIC, VIO_DEV_GPU,
    VIO_MAGIC, VIO_MMIO_BASE, VIO_MMIO_SLOTS, VIO_MMIO_STEP, VTYPE_E8_M1_TA_MA, X0,
};
use crate::{
    gr_bss_len, gr_stride, Addr, Module, Node, Op, Purpose, BIOS_UI_WASM, GR_HEADER_BYTES,
    STACK_BYTES, STACK_SHIFT, UART_LINE_BSS, UART_LINE_CAP, UI_HEADER_BYTES,
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
            purpose: Purpose::DispScan,
            live: spec.wants_disp_scan(),
            why: "uncore display-engine commit (architecture/uncore/hdmi-display.md) — __scan_fb is the BIOS+Linux simplefb handoff",
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
    let mut m = kstart(spec);
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
    let mut disp = None;
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
            Purpose::DispScan => disp = Some(o),
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
    if vio.is_some() || disp.is_some() {
        m.vio_bytes = crate::vio::VIO_BSS;
        let gp = g6b_spec_proxy(spec);
        // The scanout surface is the high-res proxy target (gp.2×gp.3) —
        // `FbExpand` scale-expands the low-res `__gr_plane` into it and each
        // backend commits it (virtio TRANSFER+FLUSH or the uncore display
        // engine's DispPaint).
        let fb = u64::from(gp.2)
            .saturating_mul(u64::from(gp.3))
            .saturating_mul(4)
            .min(crate::vio::VIO_FB_MAX);
        m.vio_fb_bytes = fb;
    }
    if let Some(o) = vio {
        m.push(vio_call_node(o));
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
        m.push(wasm_ui_call_node(o));
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
    if let Some(o) = uart {
        m.push(uart1_node(o, spec));
    }
    if let Some(o) = park {
        m.push(park_node(o));
    }
    if let Some(o) = trap {
        m.push(trap_node(o, spec));
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
    if (vio.is_some() || disp.is_some()) && (spec.kernel.gr.enable || spec.kernel.proxy.enable) {
        m.push(crate::vio::expand_node(spec));
    }
    if let Some(o) = vio {
        m.push(vio_probe_node(o));
        m.push(crate::vio::init_node(o));
        m.push(crate::vio::cmd_node());
        m.push(crate::vio::scan_node(spec));
        if spec.kernel.gr.enable || spec.kernel.proxy.enable {
            m.push(crate::vio::paint_node(spec));
        }
    }
    if disp.is_some() {
        m.push(crate::vio::disp_paint_node(spec));
    }
    if let Some(o) = ui {
        m.push(ui_init_node(o, spec));
    }
    m.push(file_serve_node(spec));
    m.push(get_file_node(spec));
    if let Some(o) = wasm_jit {
        m.push(wasm_jit_node(o));
        crate::dom::attach(&mut m, spec);
    }
    if m.rodata.is_empty() {
        m.rodata = kstart_msg(spec);
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

fn stack_node(o: Object) -> Node {
    Node {
        purpose: Purpose::Stack,
        ops: vec![
            Op::Comment(format!(
                "{} ({} bytes each; slli hartid, not a shared MEM_ADAM_STK)",
                o.why, STACK_BYTES
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
            Op::Li {
                rd: T0,
                imm: STACK_BYTES as i64,
            },
            Op::Add {
                rd: T1,
                rs1: T1,
                rs2: T0,
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
    Node {
        purpose: Purpose::Uart1Repl,
        ops: vec![
            Op::Comment(format!(
                "{} @ {base:#x} — IER.ERBFI then WFI (not a poll, not a NIC)",
                o.why
            )),
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
        ],
    }
}

fn park_node(o: Object) -> Node {
    Node {
        purpose: Purpose::Park,
        ops: vec![
            Op::Comment(o.why.into()),
            Op::Label("park".into()),
            Op::Wfi,
            Op::Jal {
                rd: X0,
                to: "park".into(),
            },
        ],
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
    Node {
        purpose: Purpose::Mailbox,
        ops: vec![
            Op::Comment(format!("{} @ {base:#x} irq {}", o.why, spec.loopback.irq)),
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
            Op::Sw {
                rs2: T1,
                rs1: T0,
                off: MBOX_OFF_DOORBELL as i32,
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
            Op::Jalr {
                rd: X0,
                rs: RA,
                imm: 0,
            },
        ],
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
    let vio_irqs = if spec.wants_virtio_gpu() {
        0xFFi64 << 1
    } else {
        0
    };
    let enable = (1i64 << uart_irq) | (1i64 << mbox_irq) | vio_irqs;
    // A PLIC source with priority 0 never asserts — QEMU reset value is 0,
    // so every enabled source needs an explicit nonzero priority.
    let mut prio: Vec<i64> = vec![uart_irq, mbox_irq];
    if spec.wants_virtio_gpu() {
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

fn trap_node(o: Object, spec: &BoardSpec) -> Node {
    let irq = spec.loopback.irq;
    let xlen = spec.isa.xlen;
    let shamt = xlen.saturating_sub(1);
    let slot = if xlen == 64 { 8i32 } else { 4i32 };
    let frame = slot * 8;
    let saves = [
        (T0, 0i32),
        (T1, 1),
        (T2, 2),
        (A0, 3),
        (A1, 4),
        (A2, 5),
        (A6, 6),
        (A7, 7),
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
                to: "trap_done".into(),
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
        Op::Jal {
            rd: X0,
            to: "trap_done".into(),
        },
    ]);
    ops.extend(trap_fault_ops(xlen));
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
        Op::Label("uart_view".into()),
    ]);
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
    if spec.kernel.wasm.enable && spec.kernel.wasm.jit {
        ops.push(Op::Comment(
            "Ui → DomPaint: re-dump live __ui_dom rows (bounded)".into(),
        ));
        ops.push(Op::Jal {
            rd: RA,
            to: "DomPaint".into(),
        });
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
    vec![
        Op::Label("trap_mbox".into()),
        Op::Comment("mailbox kick — View/Reboot/Shutdown/Wakeup/Ui/File/Get; not a netdev".into()),
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
        Op::Jal {
            rd: X0,
            to: "trap_done".into(),
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
    ]
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

/// INT_FAULT rewrite: dump `TRAP-<scause>-<sepc>` then WFI (no sret loop).
fn trap_fault_ops(xlen: u32) -> Vec<Op> {
    let shamt = xlen.saturating_sub(4);
    let nibbles = i64::from(xlen / 4);
    let mut ops = vec![Op::Label("trap_fault".into())];
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

fn vio_call_node(o: Object) -> Node {
    Node {
        purpose: Purpose::Virtio,
        ops: vec![
            Op::Comment(format!("{} — jal VioProbe / VioInit / VioScan", o.why)),
            Op::Jal {
                rd: RA,
                to: "VioProbe".into(),
            },
            Op::Jal {
                rd: RA,
                to: "VioInit".into(),
            },
            Op::Jal {
                rd: RA,
                to: "VioScan".into(),
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
        BIOS_UI_WASM
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

fn wasm_ui_call_node(o: Object) -> Node {
    Node {
        purpose: Purpose::UiDom,
        ops: vec![
            Op::Comment(format!(
                "{} — jal WasmUi (lowered wasm _start → DOM → DomPaint)",
                o.why
            )),
            Op::Jal {
                rd: RA,
                to: "WasmUi".into(),
            },
        ],
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
    let mut w = 0u32;
    for i in 0..8u32 {
        let on = ((bits >> (7 - i)) & 1) == 1;
        let n = if on { fg & 0xf } else { bg & 0xf };
        let shift = (i / 2) * 8 + if i % 2 == 0 { 4 } else { 0 };
        w |= u32::from(n) << shift;
    }
    w
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
    Node {
        purpose: Purpose::DisplayProxy,
        ops,
    }
}

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
        assert_eq!(m.ui_wasm, BIOS_UI_WASM);
        let (_, ro) = payload(&spec, b"x\0").to_words(0x8020_0000).unwrap();
        assert!(
            ro.windows(4).any(|w| w == b"\0asm"),
            "guest ELF rodata must embed bios-ui.wasm"
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
