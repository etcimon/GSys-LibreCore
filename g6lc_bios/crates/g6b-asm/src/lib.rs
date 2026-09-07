// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! ASM IR for the ZealOS rewrite. Analyze BoardSpec objects → purpose-tagged
//! nodes → assembly text and machine words. See `architecture/CODEGEN.md`.

#![allow(missing_docs)]

pub mod analyze;
pub mod crypto;
pub mod dom;
pub mod encode;
pub mod exec;
pub mod font;
pub mod task;
pub mod vio;

use std::collections::BTreeMap;

use encode::{reg_name, CSR_SCAUSE, CSR_SEPC, CSR_STVEC, CSR_TIME};

/// Per-hart TaskInit stack (grows down). Must stay `1 << STACK_SHIFT`.
pub const STACK_BYTES: u64 = 0x8000;
/// `slli` amount for `hartid * STACK_BYTES` (avoids RV32M).
pub const STACK_SHIFT: u32 = 15;

/// Why a node exists — the state it owns or the service it performs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Purpose {
    HartId,
    Dtb,
    Satp,
    Stack,
    TrapVec,
    BootLog,
    Uart1Repl,
    Park,
    Trap,
    Timer,
    MemCpy,
    Reboot,
    DisplayProxy,
    GlAdapter,
    Tls,
    Https,
    WasmJit,
    SvelteUi,
    Rsa,
    Ecdsa,
    Cert,
    Hmac,
    Http,
    Endpoint,
    BiosParam,
    Flash,
    Settings,
    Usb,
    Topology,
    Hypervisor,
    Uncore,
    Mailbox,
    Menu,
    FileServe,
    UiDom,
    Virtio,
    /// Uncore display-engine scanout (HDMI/DP — `architecture/uncore/hdmi-display.md`).
    DispScan,
    /// Read-only PCIe ECAM scan for a class-0x03 display controller with a
    /// pre-initialized linear framebuffer (`architecture/DISPLAY.md`).
    PciScan,
    /// Runtime display-output arbitration: pick the highest-priority output
    /// that is actually present and latch its surface (`DispSel`).
    DisplayMux,
}

impl Purpose {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::HartId => "hart-id",
            Self::Dtb => "dtb",
            Self::Satp => "satp",
            Self::Stack => "stack",
            Self::TrapVec => "trap-vec",
            Self::BootLog => "boot-log",
            Self::Uart1Repl => "uart1-repl",
            Self::Park => "park",
            Self::Trap => "trap",
            Self::Timer => "timer",
            Self::MemCpy => "memcpy",
            Self::Reboot => "reboot",
            Self::DisplayProxy => "display-proxy",
            Self::GlAdapter => "gl-adapter",
            Self::Tls => "tls",
            Self::Https => "https",
            Self::WasmJit => "wasm-jit",
            Self::SvelteUi => "svelte-ui",
            Self::Rsa => "rsa",
            Self::Ecdsa => "ecdsa",
            Self::Cert => "cert",
            Self::Hmac => "hmac",
            Self::Http => "http",
            Self::Endpoint => "endpoint",
            Self::BiosParam => "bios-param",
            Self::Flash => "flash",
            Self::Settings => "settings",
            Self::Usb => "usb",
            Self::Topology => "topology",
            Self::Hypervisor => "hypervisor",
            Self::Uncore => "uncore",
            Self::Mailbox => "mailbox",
            Self::Menu => "menu",
            Self::FileServe => "file-serve",
            Self::UiDom => "ui-dom",
            Self::Virtio => "virtio",
            Self::DispScan => "disp-scan",
            Self::PciScan => "pci-scan",
            Self::DisplayMux => "display-mux",
        }
    }

    /// Architectural home of this state (register, CSR, or memory).
    pub fn home(self) -> &'static str {
        match self {
            Self::HartId => "tp",
            Self::Dtb => "s1",
            Self::Satp => "satp",
            Self::Stack => "sp",
            Self::TrapVec => "stvec",
            Self::BootLog => "sbi+uart0",
            Self::Uart1Repl => "t0=uart1",
            Self::Park => "wfi",
            Self::Trap => "scause",
            Self::Timer => "sie+sstatus+SBI-TIME",
            Self::MemCpy => "a0,a1,a2",
            Self::Reboot => "a7=SRST",
            Self::DisplayProxy => "gr-plane→scanout",
            Self::GlAdapter => "gles2",
            Self::Tls => "sha256+aes128",
            Self::Https => "a0=url",
            Self::WasmJit => "wasm MVP",
            Self::SvelteUi => "nodedef",
            Self::Rsa => "a0=n,a1=e,a2=sig",
            Self::Ecdsa => "p256",
            Self::Cert => "der",
            Self::Hmac => "sha256",
            Self::Http => "h1+h2 parse",
            Self::Endpoint => "router",
            Self::BiosParam => "json /bios/*",
            Self::Flash => "spi-nor|mailbox|usb",
            Self::Settings => "export/import",
            Self::Usb => "msc-fat32|key-fm",
            Self::Topology => "cores×threads×issue",
            Self::Hypervisor => "H/HS next-stage",
            Self::Uncore => "clint|plic|ddr|pcie",
            Self::Mailbox => "mbox-mmio",
            Self::Menu => "setup tree",
            Self::FileServe => "g6ui+html|js|wasm",
            Self::UiDom => "__ui_dom→__gr_plane",
            Self::Virtio => "vio-mmio",
            Self::DispScan => "disp-mmio",
            Self::PciScan => "pcie-ecam",
            Self::DisplayMux => "__disp sel",
        }
    }
}

/// Immediate or relocatable address.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Addr {
    Abs(u64),
    Label(String),
    Rodata,
    /// End of per-hart BSS stacks (`__stacks_end`). `sp = end - (hartid+1)*STACK`.
    StacksEnd,
    /// SysGrInit header + 4bpp plane at `__stacks_end` (`__gr_plane`).
    GrPlane,
    /// UART command line (128 bytes + length word) after the Gr plane.
    UartLine,
    /// Guest file-serve / WASM header after the UART line (`G6UI`).
    UiBlob,
    /// `browser-ui/out/bios-ui.wasm` in `.rodata` after the boot log.
    UiWasm,
    /// Decoded wasm data image (`__wasm_data`) in `.rodata` after `__ui_wasm`.
    WasmData,
    /// First-party 8x8 font (`__font`) in `.rodata` after `__wasm_data`.
    UiFont,
    /// Bounded guest DOM row table (`__ui_dom`) in BSS after `__ui_blob`.
    UiDom,
    /// Virtio-mmio virtqueue + request/response area (`__vio`) after `__ui_dom`.
    VioBss,
    /// Linear X8R8G8B8 scanout surface (`__scan_fb`) after `__vio` —
    /// backend-agnostic: the virtio-gpu TRANSFER or the uncore display
    /// engine's `DispCommit` both scan this same buffer.
    ScanFb,
    /// Deprecated alias of [`Addr::StacksEnd`] (hart0-only layout).
    StackTop,
}

/// One RISC-V op or assembler directive. Branches name labels, not byte offsets.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Op {
    Label(String),
    Comment(String),
    Glob(String),
    /// Assembler directive (`.section`, `.option`); zero machine words.
    Directive(String),
    Lui {
        rd: u32,
        imm20: u32,
    },
    Addi {
        rd: u32,
        rs: u32,
        imm: i32,
    },
    Andi {
        rd: u32,
        rs: u32,
        imm: i32,
    },
    Lbu {
        rd: u32,
        rs: u32,
        off: i32,
    },
    Sb {
        rs2: u32,
        rs1: u32,
        off: i32,
    },
    Add {
        rd: u32,
        rs1: u32,
        rs2: u32,
    },
    Sub {
        rd: u32,
        rs1: u32,
        rs2: u32,
    },
    /// `sltu rd, rs1, rs2` — unsigned less-than. Needed for real range checks
    /// (a BAR inside a window); the sign-bit tricks elsewhere in this IR are
    /// signed and would mis-classify a high address.
    Sltu {
        rd: u32,
        rs1: u32,
        rs2: u32,
    },
    Mul {
        rd: u32,
        rs1: u32,
        rs2: u32,
    },
    Xor {
        rd: u32,
        rs1: u32,
        rs2: u32,
    },
    Beq {
        rs1: u32,
        rs2: u32,
        to: String,
    },
    Bne {
        rs1: u32,
        rs2: u32,
        to: String,
    },
    Jal {
        rd: u32,
        to: String,
    },
    Jalr {
        rd: u32,
        rs: u32,
        imm: i32,
    },
    Csrrw {
        rd: u32,
        csr: u32,
        rs: u32,
    },
    Csrrs {
        rd: u32,
        csr: u32,
        rs: u32,
    },
    Csrrc {
        rd: u32,
        csr: u32,
        rs: u32,
    },
    /// `lui`+`addi` of an address into `rd` (lowered after layout).
    La {
        rd: u32,
        addr: Addr,
    },
    /// `li rd, imm` — one `addi` or `lui`+`addi`.
    Li {
        rd: u32,
        imm: i64,
    },
    Ecall,
    Wfi,
    Sret,
    Vsetvli {
        rd: u32,
        rs1: u32,
        vtype: u32,
    },
    Vle8 {
        vd: u32,
        rs1: u32,
    },
    Vse8 {
        vs3: u32,
        rs1: u32,
    },
    /// Logical right shift (scause interrupt bit is XLEN-1).
    Srli {
        rd: u32,
        rs: u32,
        shamt: u32,
    },
    /// Logical left shift (`hartid * STACK_BYTES`).
    Slli {
        rd: u32,
        rs: u32,
        shamt: u32,
    },
    Lw {
        rd: u32,
        rs: u32,
        off: i32,
    },
    Ld {
        rd: u32,
        rs: u32,
        off: i32,
    },
    Sw {
        rs2: u32,
        rs1: u32,
        off: i32,
    },
    Sd {
        rs2: u32,
        rs1: u32,
        off: i32,
    },
    /// Data word in the payload (display-proxy geom; not an instruction).
    Word(u32),
    /// `sfence.vma` (satp bare; not `invlpg`).
    SfenceVma,
    /// `fence` (`fence iorw,iorw`) — required between virtqueue descriptor/ring
    /// writes and the avail-idx / doorbell update.
    Fence,
}

/// Purpose-tagged sequence of ops (one analyzed object).
#[derive(Debug, Clone)]
pub struct Node {
    pub purpose: Purpose,
    pub ops: Vec<Op>,
}

/// A payload module: ordered nodes plus rodata (boot log, not code).
#[derive(Debug, Clone, Default)]
pub struct Module {
    pub nodes: Vec<Node>,
    pub rodata: Vec<u8>,
    /// BoardSpec hart count; stacks are `n_harts() * STACK_BYTES` after the image.
    pub nharts: u32,
    /// SysGrInit BSS after stacks (header + 4bpp plane when Gr/proxy is live).
    pub gr_bytes: u64,
    /// UART line buffer BSS (always; View/Reboot over irq-driven RX).
    pub line_bytes: u64,
    /// Guest UI header BSS (`G6UI` + size/flags/accel/ptr/wasm-magic/nfiles) when live.
    pub ui_bytes: u64,
    /// Guest copy of `browser-ui/out/bios-ui.wasm` (rodata after the boot log; not a VFS).
    pub ui_wasm: Vec<u8>,
    /// Decoded wasm data image (`__wasm_data`) — the linear-memory snapshot the
    /// lowered `WasmStart` resolves string pointers against.
    pub wasm_data: Vec<u8>,
    /// First-party 8x8 font bytes (`__font`) for `DomPaint` glyph lookup.
    pub font: Vec<u8>,
    /// Bounded guest DOM row table BSS (`__ui_dom`) when `kernel.wasm.jit`.
    pub dom_bytes: u64,
    /// Virtio virtqueue/request BSS (`__vio`) when `wants_virtio_gpu`.
    pub vio_bytes: u64,
    /// Linear X8R8G8B8 scanout BSS (`__scan_fb`) when a display path is
    /// live (`wants_virtio_gpu` or `wants_disp_scan`).
    pub vio_fb_bytes: u64,
}

/// BSS after the payload: 16-byte aligned image + one stack per hart.
pub fn stack_memsz(filesz: u64, nharts: u32) -> u64 {
    let aligned = (filesz + 15) & !15;
    aligned.saturating_add(STACK_BYTES.saturating_mul(u64::from(nharts.max(1))))
}

/// `GR16` ident + geom words (plane pixels follow in BSS).
pub const GR_HEADER_BYTES: u64 = 64;

/// Bytes per row: 4bpp when `colors <= 16`, else 8-bit indexed.
pub fn gr_stride(w: u32, colors: u32) -> u32 {
    let w = w.max(8);
    if colors <= 16 {
        w.saturating_add(1) / 2
    } else {
        w
    }
}

/// Pixel BSS after the header (`stride * h`).
pub fn gr_plane_len(w: u32, h: u32, colors: u32) -> u64 {
    u64::from(gr_stride(w, colors).saturating_mul(h.max(8)))
}

/// Header + plane. 0 when Gr/proxy is off.
pub fn gr_bss_len(w: u32, h: u32, colors: u32) -> u64 {
    GR_HEADER_BYTES.saturating_add(gr_plane_len(w, h, colors))
}

/// UART line: 128 data bytes + u32 length + probe-absent flags.
pub const UART_LINE_CAP: u32 = 128;
/// `__uart_line+132` — set by `trap_fault` when an MMIO access fault hits
/// the UART1 probe window (absent second ns16550, e.g. stock QEMU virt).
pub const UART1_DEAD_OFF: u32 = 132;
/// `__uart_line+133` — set by `trap_fault` for the loopback mailbox window.
pub const MBOX_DEAD_OFF: u32 = 133;
pub const UART_LINE_BSS: u64 = 136;
/// `G6UI` magic + size + flags + accel + wasm pointer + magic echo + nfiles.
pub const UI_HEADER_BYTES: u64 = 32;

/// First-party `browser-ui/out/bios-ui.wasm` (host include; guest copies when live).
pub const BIOS_UI_WASM: &[u8] = include_bytes!("../../../browser-ui/out/bios-ui.wasm");

/// LDC 1.43 / libwasm wasm-eh cell (`browser-ui/out/bios-ui-libwasm.wasm`).
/// Empty when the `G6B_DUB_WASM=1` dub cell has never run on this checkout.
/// The g6b-wasm interpreter cannot execute it (i64/memory ops/EH tags);
/// it is served for the browser-side DOM-kernel host only.
pub const BIOS_UI_LIBWASM: &[u8] = include_bytes!("../../../browser-ui/out/bios-ui-libwasm.wasm");

/// ELF `p_memsz`: stacks, then Gr plane + UART line + G6UI header BSS.
pub fn payload_memsz(filesz: u64, nharts: u32, extra: u64) -> u64 {
    stack_memsz(filesz, nharts).saturating_add(extra)
}

impl Module {
    fn image_filesz(&self, code_bytes: u64) -> u64 {
        code_bytes
            .saturating_add(self.rodata.len() as u64)
            .saturating_add(self.ui_wasm.len() as u64)
            .saturating_add(self.wasm_data.len() as u64)
            .saturating_add(self.font.len() as u64)
    }

    pub fn push(&mut self, n: Node) {
        self.nodes.push(n);
    }

    pub fn purposes(&self) -> Vec<Purpose> {
        self.nodes.iter().map(|n| n.purpose).collect()
    }

    pub fn n_harts(&self) -> u32 {
        self.nharts.max(1)
    }

    /// GNU as text. Comments include purpose and state home.
    pub fn to_asm(&self) -> String {
        let mut s =
            String::from("/* generated from g6b-asm IR — do not hand-edit */\n.option norvc\n");
        for n in &self.nodes {
            s.push_str(&format!(
                "\n/* purpose={} home={} */\n",
                n.purpose.as_str(),
                n.purpose.home()
            ));
            for op in &n.ops {
                s.push_str(&op_to_asm(op));
                s.push('\n');
            }
        }
        if !self.rodata.is_empty()
            || !self.ui_wasm.is_empty()
            || !self.wasm_data.is_empty()
            || !self.font.is_empty()
        {
            s.push_str("\n.section .rodata\n");
            if !self.rodata.is_empty() {
                s.push_str("boot_log:\n");
                s.push_str(&rodata_listing(&self.rodata));
            }
            if !self.ui_wasm.is_empty() {
                s.push_str("__ui_wasm:\n");
                s.push_str(&rodata_listing(&self.ui_wasm));
            }
            if !self.wasm_data.is_empty() {
                s.push_str("__wasm_data:\n");
                s.push_str(&rodata_listing(&self.wasm_data));
            }
            if !self.font.is_empty() {
                s.push_str("__font:\n");
                s.push_str(&rodata_listing(&self.font));
            }
        }
        if self.nodes.iter().any(|n| n.purpose == Purpose::Stack) {
            let bytes = STACK_BYTES.saturating_mul(u64::from(self.n_harts()));
            s.push_str(&format!(
                "\n.section .bss\n.align 4\n.space {bytes:#x}\n__stacks_end:\n"
            ));
            if self.gr_bytes > 0 {
                s.push_str(&format!("__gr_plane:\n.space {:#x}\n", self.gr_bytes));
            }
        }
        if self.line_bytes > 0 {
            if !self.nodes.iter().any(|n| n.purpose == Purpose::Stack) {
                s.push_str("\n.section .bss\n");
            }
            s.push_str(&format!("__uart_line:\n.space {:#x}\n", self.line_bytes));
        }
        if self.ui_bytes > 0 {
            if !self.nodes.iter().any(|n| n.purpose == Purpose::Stack) && self.line_bytes == 0 {
                s.push_str("\n.section .bss\n");
            }
            s.push_str(&format!("__ui_blob:\n.space {:#x}\n", self.ui_bytes));
        }
        if self.dom_bytes > 0 {
            if !self.nodes.iter().any(|n| n.purpose == Purpose::Stack)
                && self.line_bytes == 0
                && self.ui_bytes == 0
            {
                s.push_str("\n.section .bss\n");
            }
            s.push_str(&format!("__ui_dom:\n.space {:#x}\n", self.dom_bytes));
        }
        if self.vio_bytes > 0 {
            if !self.nodes.iter().any(|n| n.purpose == Purpose::Stack)
                && self.line_bytes == 0
                && self.ui_bytes == 0
                && self.dom_bytes == 0
            {
                s.push_str("\n.section .bss\n");
            }
            s.push_str(&format!("__vio:\n.space {:#x}\n", self.vio_bytes));
        }
        if self.vio_fb_bytes > 0 {
            if !self.nodes.iter().any(|n| n.purpose == Purpose::Stack)
                && self.line_bytes == 0
                && self.ui_bytes == 0
                && self.dom_bytes == 0
                && self.vio_bytes == 0
            {
                s.push_str("\n.section .bss\n");
            }
            s.push_str(&format!("__scan_fb:\n.space {:#x}\n", self.vio_fb_bytes));
        }
        s
    }

    /// Resolved `__vio` BSS address for a module loaded at `entry`.
    ///
    /// Same arithmetic `to_words` uses for `Addr::VioBss`; exposed so the exec
    /// model can read the `DispSel`/`PciProbe` result block out of RAM without
    /// duplicating (and eventually diverging from) the layout. `None` when the
    /// module allocates no `__vio`.
    pub fn vio_bss_addr(&self, entry: u64) -> Option<u64> {
        if self.vio_bytes == 0 {
            return None;
        }
        let (words, _) = self.to_words(entry).ok()?;
        let code_bytes = (words.len() * 4) as u64;
        let filesz = self.image_filesz(code_bytes);
        let stacks = entry.wrapping_add(stack_memsz(filesz, self.n_harts()));
        Some(
            stacks
                .wrapping_add(self.gr_bytes)
                .wrapping_add(self.line_bytes)
                .wrapping_add(self.ui_bytes)
                .wrapping_add(self.dom_bytes),
        )
    }

    /// Machine words then rodata. `entry` is the load address of the first insn.
    pub fn to_words(&self, entry: u64) -> Result<(Vec<u32>, Vec<u8>), String> {
        let flat: Vec<&Op> = self.nodes.iter().flat_map(|n| n.ops.iter()).collect();
        let mut labels = BTreeMap::new();
        let mut idx = 0usize;
        for op in &flat {
            match op {
                Op::Label(l) => {
                    labels.insert(l.clone(), idx);
                }
                Op::Comment(_) | Op::Glob(_) | Op::Directive(_) => {}
                other => idx += op_nwords(other),
            }
        }
        let code_bytes = (idx * 4) as u64;
        let rodata_addr = entry.wrapping_add(code_bytes);

        let mut words = Vec::new();
        let mut i = 0usize;
        for op in &flat {
            match op {
                Op::Label(_) | Op::Comment(_) | Op::Glob(_) | Op::Directive(_) => {}
                Op::La { rd, addr } => {
                    let filesz = self.image_filesz(code_bytes);
                    let stacks = entry.wrapping_add(stack_memsz(filesz, self.n_harts()));
                    let a = match addr {
                        Addr::Abs(v) => *v,
                        Addr::Rodata => rodata_addr,
                        Addr::UiWasm => rodata_addr.wrapping_add(self.rodata.len() as u64),
                        Addr::WasmData => rodata_addr
                            .wrapping_add(self.rodata.len() as u64)
                            .wrapping_add(self.ui_wasm.len() as u64),
                        Addr::UiFont => rodata_addr
                            .wrapping_add(self.rodata.len() as u64)
                            .wrapping_add(self.ui_wasm.len() as u64)
                            .wrapping_add(self.wasm_data.len() as u64),
                        Addr::StacksEnd | Addr::StackTop | Addr::GrPlane => stacks,
                        Addr::UartLine => stacks.wrapping_add(self.gr_bytes),
                        Addr::UiBlob => stacks
                            .wrapping_add(self.gr_bytes)
                            .wrapping_add(self.line_bytes),
                        Addr::UiDom => stacks
                            .wrapping_add(self.gr_bytes)
                            .wrapping_add(self.line_bytes)
                            .wrapping_add(self.ui_bytes),
                        Addr::VioBss => stacks
                            .wrapping_add(self.gr_bytes)
                            .wrapping_add(self.line_bytes)
                            .wrapping_add(self.ui_bytes)
                            .wrapping_add(self.dom_bytes),
                        Addr::ScanFb => stacks
                            .wrapping_add(self.gr_bytes)
                            .wrapping_add(self.line_bytes)
                            .wrapping_add(self.ui_bytes)
                            .wrapping_add(self.dom_bytes)
                            .wrapping_add(self.vio_bytes),
                        Addr::Label(l) => {
                            let at = *labels.get(l).ok_or_else(|| format!("unknown label {l}"))?;
                            entry.wrapping_add((at * 4) as u64)
                        }
                    };
                    // PC-relative: RV64 `lui` of 0x8xxx_xxxx sign-extends (not QEMU DRAM).
                    let pc = entry.wrapping_add((i * 4) as u64);
                    let (hi, lo) = encode::hi_lo(a.wrapping_sub(pc));
                    words.push(encode::auipc(*rd, hi));
                    words.push(encode::addi(*rd, *rd, lo));
                    i += 2;
                }
                Op::Li { rd, imm } => {
                    let ws = encode::li_words(*rd, *imm);
                    i += ws.len();
                    words.extend(ws);
                }
                Op::Word(w) => {
                    words.push(*w);
                    i += 1;
                }
                other => {
                    let pc = i;
                    words.push(encode_op(other, pc, &labels)?);
                    i += 1;
                }
            }
        }
        let mut rod = self.rodata.clone();
        rod.extend_from_slice(&self.ui_wasm);
        rod.extend_from_slice(&self.wasm_data);
        rod.extend_from_slice(&self.font);
        Ok((words, rod))
    }
}

fn op_nwords(op: &Op) -> usize {
    match op {
        Op::Label(_) | Op::Comment(_) | Op::Glob(_) | Op::Directive(_) => 0,
        Op::La { .. } => 2,
        Op::Li { imm, .. } => encode::li_nwords(*imm),
        _ => 1,
    }
}

fn encode_op(op: &Op, pc: usize, labels: &BTreeMap<String, usize>) -> Result<u32, String> {
    let rel = |to: &str| -> Result<i32, String> {
        let at = *labels
            .get(to)
            .ok_or_else(|| format!("unknown label {to}"))?;
        Ok((at as i32 - pc as i32) * 4)
    };
    Ok(match op {
        Op::Lui { rd, imm20 } => encode::lui(*rd, *imm20),
        Op::Addi { rd, rs, imm } => encode::addi(*rd, *rs, *imm),
        Op::Andi { rd, rs, imm } => encode::andi(*rd, *rs, *imm),
        Op::Lbu { rd, rs, off } => encode::lbu(*rd, *rs, *off),
        Op::Sb { rs2, rs1, off } => encode::sb(*rs2, *rs1, *off),
        Op::Add { rd, rs1, rs2 } => encode::add(*rd, *rs1, *rs2),
        Op::Sub { rd, rs1, rs2 } => encode::sub(*rd, *rs1, *rs2),
        Op::Sltu { rd, rs1, rs2 } => encode::sltu(*rd, *rs1, *rs2),
        Op::Mul { rd, rs1, rs2 } => encode::mul(*rd, *rs1, *rs2),
        Op::Xor { rd, rs1, rs2 } => encode::xor(*rd, *rs1, *rs2),
        Op::Beq { rs1, rs2, to } => encode::beq(*rs1, *rs2, rel(to)?),
        Op::Bne { rs1, rs2, to } => encode::bne(*rs1, *rs2, rel(to)?),
        Op::Jal { rd, to } => encode::jal(*rd, rel(to)?),
        Op::Jalr { rd, rs, imm } => encode::jalr(*rd, *rs, *imm),
        Op::Csrrw { rd, csr, rs } => encode::csrrw(*rd, *csr, *rs),
        Op::Csrrs { rd, csr, rs } => encode::csrrs(*rd, *csr, *rs),
        Op::Csrrc { rd, csr, rs } => encode::csrrc(*rd, *csr, *rs),
        Op::Ecall => encode::ecall(),
        Op::Wfi => encode::wfi(),
        Op::SfenceVma => encode::sfence_vma(),
        Op::Fence => 0x0330_000f,
        Op::Sret => encode::SRET,
        Op::Vsetvli { rd, rs1, vtype } => encode::vsetvli(*rd, *rs1, *vtype),
        Op::Vle8 { vd, rs1 } => encode::vle8(*vd, *rs1),
        Op::Vse8 { vs3, rs1 } => encode::vse8(*vs3, *rs1),
        Op::Srli { rd, rs, shamt } => encode::srli(*rd, *rs, *shamt),
        Op::Slli { rd, rs, shamt } => encode::slli(*rd, *rs, *shamt),
        Op::Lw { rd, rs, off } => encode::lw(*rd, *rs, *off),
        Op::Ld { rd, rs, off } => encode::ld(*rd, *rs, *off),
        Op::Sw { rs2, rs1, off } => encode::sw(*rs2, *rs1, *off),
        Op::Sd { rs2, rs1, off } => encode::sd(*rs2, *rs1, *off),
        Op::Label(_)
        | Op::Comment(_)
        | Op::Glob(_)
        | Op::Directive(_)
        | Op::La { .. }
        | Op::Li { .. }
        | Op::Word(_) => {
            return Err("meta op in encode_op".into());
        }
    })
}

fn rodata_listing(bytes: &[u8]) -> String {
    if let Ok(s) = std::str::from_utf8(bytes) {
        if s.ends_with('\0') && s.bytes().filter(|b| *b == 0).count() == 1 && s.is_ascii() {
            let inner = s
                .trim_end_matches('\0')
                .replace('\\', "\\\\")
                .replace('"', "\\\"");
            let inner = inner.replace('\n', "\\n").replace('\t', "\\t");
            return format!(".asciz \"{inner}\"\n");
        }
    }
    let mut out = String::new();
    for chunk in bytes.chunks(16) {
        out.push_str(".byte ");
        out.push_str(
            &chunk
                .iter()
                .map(|b| format!("0x{b:02x}"))
                .collect::<Vec<_>>()
                .join(", "),
        );
        out.push('\n');
    }
    out
}

fn op_to_asm(op: &Op) -> String {
    match op {
        Op::Label(l) => format!("{l}:"),
        Op::Comment(c) => format!("\t/* {c} */"),
        Op::Glob(g) => format!(".globl {g}"),
        Op::Directive(d) => d.clone(),
        Op::Lui { rd, imm20 } => format!("\tlui\t{}, {:#x}", reg_name(*rd), imm20),
        Op::Addi { rd, rs, imm } if *imm == 0 => {
            format!("\tmv\t{}, {}", reg_name(*rd), reg_name(*rs))
        }
        Op::Addi { rd, rs, imm } => {
            format!("\taddi\t{}, {}, {imm}", reg_name(*rd), reg_name(*rs))
        }
        Op::Andi { rd, rs, imm } => {
            format!("\tandi\t{}, {}, {imm}", reg_name(*rd), reg_name(*rs))
        }
        Op::Lbu { rd, rs, off } => {
            format!("\tlbu\t{}, {off}({})", reg_name(*rd), reg_name(*rs))
        }
        Op::Sb { rs2, rs1, off } => {
            format!("\tsb\t{}, {off}({})", reg_name(*rs2), reg_name(*rs1))
        }
        Op::Add { rd, rs1, rs2 } => format!(
            "\tadd\t{}, {}, {}",
            reg_name(*rd),
            reg_name(*rs1),
            reg_name(*rs2)
        ),
        Op::Sub { rd, rs1, rs2 } => format!(
            "\tsub\t{}, {}, {}",
            reg_name(*rd),
            reg_name(*rs1),
            reg_name(*rs2)
        ),
        Op::Sltu { rd, rs1, rs2 } => format!(
            "\tsltu\t{}, {}, {}",
            reg_name(*rd),
            reg_name(*rs1),
            reg_name(*rs2)
        ),
        Op::Mul { rd, rs1, rs2 } => format!(
            "\tmul\t{}, {}, {}",
            reg_name(*rd),
            reg_name(*rs1),
            reg_name(*rs2)
        ),
        Op::Xor { rd, rs1, rs2 } => format!(
            "\txor\t{}, {}, {}",
            reg_name(*rd),
            reg_name(*rs1),
            reg_name(*rs2)
        ),
        Op::Beq { rs1, rs2, to } if *rs2 == 0 => {
            format!("\tbeqz\t{}, {to}", reg_name(*rs1))
        }
        Op::Beq { rs1, rs2, to } => {
            format!("\tbeq\t{}, {}, {to}", reg_name(*rs1), reg_name(*rs2))
        }
        Op::Bne { rs1, rs2, to } if *rs2 == 0 => {
            format!("\tbnez\t{}, {to}", reg_name(*rs1))
        }
        Op::Bne { rs1, rs2, to } => {
            format!("\tbne\t{}, {}, {to}", reg_name(*rs1), reg_name(*rs2))
        }
        Op::Jal { rd, to } if *rd == 0 => format!("\tj\t{to}"),
        Op::Jal { rd, to } => format!("\tjal\t{}, {to}", reg_name(*rd)),
        Op::Jalr { rd, rs, imm } if *rd == 0 && *rs == 1 && *imm == 0 => "\tret".into(),
        Op::Jalr { rd, rs, imm } => {
            format!("\tjalr\t{}, {imm}({})", reg_name(*rd), reg_name(*rs))
        }
        Op::Csrrw { rd, csr, rs } if *rd == 0 && *csr == encode::CSR_SATP => {
            format!("\tcsrw\tsatp, {}", reg_name(*rs))
        }
        Op::Csrrw { rd, csr, rs } if *rd == 0 && *csr == CSR_STVEC => {
            format!("\tcsrw\tstvec, {}", reg_name(*rs))
        }
        Op::Csrrw { rd, csr, rs } => {
            format!("\tcsrrw\t{}, {csr:#x}, {}", reg_name(*rd), reg_name(*rs))
        }
        Op::Csrrs { rd, csr, rs } if *rs == 0 && *csr == CSR_SCAUSE => {
            format!("\tcsrr\t{}, scause", reg_name(*rd))
        }
        Op::Csrrs { rd, csr, rs } if *rs == 0 && *csr == CSR_SEPC => {
            format!("\tcsrr\t{}, sepc", reg_name(*rd))
        }
        Op::Csrrs { rd, csr, rs } if *rs == 0 && *csr == CSR_TIME => {
            format!("\trdtime\t{}", reg_name(*rd))
        }
        Op::Csrrs { rd, csr, rs } if *csr == encode::CSR_SIE => {
            format!("\tcsrrs\t{}, sie, {}", reg_name(*rd), reg_name(*rs))
        }
        Op::Csrrs { rd, csr, rs } if *csr == encode::CSR_SSTATUS => {
            format!("\tcsrrs\t{}, sstatus, {}", reg_name(*rd), reg_name(*rs))
        }
        Op::Csrrs { rd, csr, rs } => {
            format!("\tcsrrs\t{}, {csr:#x}, {}", reg_name(*rd), reg_name(*rs))
        }
        Op::Csrrc { rd, csr, rs } => {
            format!("\tcsrrc\t{}, {csr:#x}, {}", reg_name(*rd), reg_name(*rs))
        }
        Op::La { rd, addr } => match addr {
            Addr::Abs(a) => format!("\tla\t{}, {a:#x}", reg_name(*rd)),
            Addr::Label(l) => format!("\tla\t{}, {l}", reg_name(*rd)),
            Addr::Rodata => format!("\tla\t{}, boot_log", reg_name(*rd)),
            Addr::StacksEnd | Addr::StackTop => {
                format!("\tla\t{}, __stacks_end", reg_name(*rd))
            }
            Addr::GrPlane => format!("\tla\t{}, __gr_plane", reg_name(*rd)),
            Addr::UartLine => format!("\tla\t{}, __uart_line", reg_name(*rd)),
            Addr::UiBlob => format!("\tla\t{}, __ui_blob", reg_name(*rd)),
            Addr::UiWasm => format!("\tla\t{}, __ui_wasm", reg_name(*rd)),
            Addr::WasmData => format!("\tla\t{}, __wasm_data", reg_name(*rd)),
            Addr::UiFont => format!("\tla\t{}, __font", reg_name(*rd)),
            Addr::UiDom => format!("\tla\t{}, __ui_dom", reg_name(*rd)),
            Addr::VioBss => format!("\tla\t{}, __vio", reg_name(*rd)),
            Addr::ScanFb => format!("\tla\t{}, __scan_fb", reg_name(*rd)),
        },
        Op::Li { rd, imm } if *imm > 9 || *imm < 0 => {
            format!("\tli\t{}, {imm:#x}", reg_name(*rd))
        }
        Op::Li { rd, imm } => format!("\tli\t{}, {imm}", reg_name(*rd)),
        Op::Ecall => "\tecall".into(),
        Op::Wfi => "\twfi".into(),
        Op::SfenceVma => "\tsfence.vma".into(),
        Op::Fence => "\tfence".into(),
        Op::Sret => "\tsret".into(),
        Op::Vsetvli { rd, rs1, .. } => {
            format!(
                "\tvsetvli\t{}, {}, e8, m1, ta, ma",
                reg_name(*rd),
                reg_name(*rs1)
            )
        }
        Op::Vle8 { vd, rs1 } => format!("\tvle8.v\tv{vd}, ({})", reg_name(*rs1)),
        Op::Vse8 { vs3, rs1 } => format!("\tvse8.v\tv{vs3}, ({})", reg_name(*rs1)),
        Op::Srli { rd, rs, shamt } => {
            format!("\tsrli\t{}, {}, {shamt}", reg_name(*rd), reg_name(*rs))
        }
        Op::Slli { rd, rs, shamt } => {
            format!("\tslli\t{}, {}, {shamt}", reg_name(*rd), reg_name(*rs))
        }
        Op::Lw { rd, rs, off } => {
            format!("\tlw\t{}, {off}({})", reg_name(*rd), reg_name(*rs))
        }
        Op::Ld { rd, rs, off } => {
            format!("\tld\t{}, {off}({})", reg_name(*rd), reg_name(*rs))
        }
        Op::Sw { rs2, rs1, off } => {
            format!("\tsw\t{}, {off}({})", reg_name(*rs2), reg_name(*rs1))
        }
        Op::Sd { rs2, rs1, off } => {
            format!("\tsd\t{}, {off}({})", reg_name(*rs2), reg_name(*rs1))
        }
        Op::Word(w) => format!("\t.word\t{w}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use encode::{A0, X0};

    #[test]
    fn purposes_drive_homes() {
        assert_eq!(Purpose::HartId.home(), "tp");
        assert_eq!(Purpose::Stack.home(), "sp");
        assert_eq!(Purpose::TrapVec.home(), "stvec");
        assert_eq!(STACK_BYTES, 1u64 << STACK_SHIFT);
    }

    #[test]
    fn branch_resolves() {
        let mut m = Module::default();
        m.push(Node {
            purpose: Purpose::Park,
            ops: vec![
                Op::Label("loop".into()),
                Op::Wfi,
                Op::Jal {
                    rd: X0,
                    to: "loop".into(),
                },
            ],
        });
        let (w, _) = m.to_words(0x8000_0000).unwrap();
        assert_eq!(w.len(), 2);
        assert_eq!(w[0], encode::wfi());
    }

    #[test]
    fn asm_mentions_purpose() {
        let mut m = Module::default();
        m.push(Node {
            purpose: Purpose::HartId,
            ops: vec![Op::Addi {
                rd: encode::TP,
                rs: A0,
                imm: 0,
            }],
        });
        let s = m.to_asm();
        assert!(s.contains("purpose=hart-id"), "{s}");
        assert!(s.contains("home=tp"), "{s}");
        assert!(s.contains("mv\ttp, a0"), "{s}");
    }

    #[test]
    fn addi_a0_x0_1() {
        assert_eq!(encode::addi(A0, X0, 1), 0x0010_0513);
    }
}
