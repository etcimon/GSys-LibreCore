// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! ASM IR for the ZealOS rewrite. Analyze BoardSpec objects → purpose-tagged
//! nodes → assembly text and machine words. See `architecture/CODEGEN.md`.

#![allow(missing_docs)]

pub mod analyze;
pub mod crypto;
pub mod dlp;
pub mod dom;
pub mod domt;
pub mod encode;
pub mod exec;
pub mod ext4file;
pub mod fatfile;
pub mod font;
pub mod jfmt;
pub mod jitr;
pub mod kget;
pub mod task;
pub mod vio;
pub mod virgl;
pub mod webp;

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
    /// virtio-net DeviceID 1 probe (`VioNetProbe`). Not a QEMU `-netdev`.
    VirtioNet,
    /// virtio-blk DeviceID 2 driver (`BlkInit`/`BlkRead`/`BlkSig`) — the payload
    /// reading sectors itself, which is what the autoboot handoff waits on.
    VirtioBlk,
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
            Self::VirtioNet => "virtio-net",
            Self::VirtioBlk => "virtio-blk",
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
            Self::VirtioNet => "vio-mmio-net",
            Self::VirtioBlk => "vio-mmio-blk",
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
    /// UI wasm in `.rodata` after the boot log (LDC libwasm cell when live).
    UiWasm,
    /// Decoded wasm data image (`__wasm_data`) in `.rodata` after `__ui_wasm`.
    WasmData,
    /// First-party 8x8 font (`__font`) in `.rodata` after `__wasm_data`.
    UiFont,
    /// Bounded guest DOM row table (`__ui_dom`) in BSS after `__ui_blob`.
    UiDom,
    /// Compact web-engine persist (`__ui_cap`) after `__ui_dom`: dirty tiles +
    /// node count. Not the 48-row table and not `start_ops` `Object_Call`.
    UiCap,
    /// Virtio-mmio virtqueue + request/response area (`__vio`) after `__ui_cap`.
    VioBss,
    /// Linear X8R8G8B8 scanout surface (`__scan_fb`) after `__vio` —
    /// backend-agnostic: the virtio-gpu TRANSFER or the uncore display
    /// engine's `DispCommit` both scan this same buffer.
    ScanFb,
    /// Predecoded wasm bytecode image (`__jit_in`) in `.rodata` after
    /// `__g6b_store_dump` — the guest JIT's input, produced host-side by
    /// `g6b_wasm::jcode::encode` (not raw wasm: sections/LEB are already
    /// resolved to a flat record stream).
    JitIn,
    /// JIT state header (`__jit`) in BSS after `__scan_fb`: magic/state/fuel/
    /// counters, function table, constant pool, globals.
    JitHdr,
    /// JIT runtime stack (`__jit_stk`) after `__jit` — wasm value stack +
    /// call frames.
    JitStk,
    /// JIT code arena (`__jit_code`) after `__jit_stk` — the translator writes
    /// RISC-V words here, `fence.i`, then jumps in.
    JitCode,
    /// Wasm linear memory (`__wasm_mem`) after `__jit_code`.
    WasmMem,
    /// Guest DOM tree arena (`__dom`) after `__wasm_mem` — the M2 bounded
    /// node store: a header + a fixed node pool, index handles.
    DomT,
    /// Guest DOM string pool (`__dom_str`) after `__dom` — bump-allocated
    /// text/id bytes the node records point into.
    DomS,
    /// Guest DOM per-node element-id table (`__dom_id`) after `__dom_str` —
    /// `u8`-length + up to 28 inline bytes per node, so `add_event_listener`
    /// can resolve its string target to a node without a second string pool.
    DomId,
    /// Bounded guest event record (`__ev_obj`) — `DomtKey` fills it
    /// (`type`/`code`/`value`/`clientX`/`clientY`/`target`) before `JitCall`
    /// re-enters a `N_LISTEN >= 0x100` wasm listener, passing its address as
    /// the event handle.
    EvObj,
    /// Bounded guest promise/object table (`__prom`) — the last BSS region
    /// (after `__ev_obj`). Each record is a Promise (`pending`/`fulfilled`/
    /// `rejected` + value/reason span) or an `i32` handle-array (the
    /// combinator input `libasync_promise_*` reads); `fetch`/`await`/`then`
    /// address it by a `handle = index+1`. This is the guest-side correlate
    /// of the interpreter's `ObjectTable<LibwasmValue>` promise subset.
    Prom,
    /// virgl execbuffer (`__virgl_cmd`) in `.rodata` after `__jit_in` — the
    /// static virgl command stream `VioVirgl` hands to `SUBMIT_3D` (OUT desc),
    /// produced host-side by `crate::virgl::execbuf` (M4).
    VirglCmd,
    /// virgl ctrlq request table (`__virgl_req`) in `.rodata` after
    /// `__virgl_cmd` — the CAPSET→CTX_CREATE→SUBMIT_3D→TRANSFER→FLUSH record
    /// sequence `VioVirgl` walks, produced host-side by `crate::virgl::reqtab`.
    VirglReq,
    /// `__virgl_out` — guest-RAM readback target (BSS, after `__dom_id`) for
    /// the virgl `TRANSFER_FROM_HOST_3D`; `VioVirgl` attaches it as `RES_RT`
    /// backing then reads the rendered quad back into guest memory (M4b).
    VirglOut,
    /// Packed web present (`__web_pk`) in `.rodata` after `__virgl_req` — the
    /// host-rendered `Canvas32` scene (RLE word stream, B8G8R8X8) the guest
    /// `WebBlit` decodes into the `__disp`-latched scanout surface.
    WebPk,
    /// Packed display list (`__web_dl`) in `.rodata` after `__web_pk` — the
    /// same scene as an op stream + glyph atlas the guest `DlPaint` replays;
    /// per-menu state lists and `TEXTREF` live-text anchors ride along.
    WebDl,
    /// Kernel-GET table (`__kget`) in `.rodata` after `__web_dl` — the
    /// `{url → body}` map `KernelGet`/`LwFetch` resolve `env.fetch` against.
    KGet,
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
    /// `divu rd, rs1, rs2` — unsigned divide. `FbExpand` computes the
    /// runtime fit/fill scale as `__disp.w / low_w`; the IR has no other
    /// way to derive a per-output scale and a gen-time constant cannot
    /// follow `DispSel`'s latch.
    Divu {
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
    /// `fence.i` — icache sync between guest codegen into `__jit_code` and the
    /// first `jalr` into the arena (Zifencei).
    FenceI,
    /// `and rd, rs, rs2` — register AND.
    And {
        rd: u32,
        rs: u32,
        rs2: u32,
    },
    /// `or rd, rs, rs2`.
    Or {
        rd: u32,
        rs: u32,
        rs2: u32,
    },
    /// `sll rd, rs, rs2` — register shift-left.
    Sll {
        rd: u32,
        rs: u32,
        rs2: u32,
    },
    /// `srl rd, rs, rs2`.
    Srl {
        rd: u32,
        rs: u32,
        rs2: u32,
    },
    /// `sra rd, rs, rs2`.
    Sra {
        rd: u32,
        rs: u32,
        rs2: u32,
    },
    /// `slt rd, rs, rs2` — signed compare.
    Slt {
        rd: u32,
        rs: u32,
        rs2: u32,
    },
    /// `slti rd, rs, imm`.
    Slti {
        rd: u32,
        rs: u32,
        imm: i32,
    },
    /// `sltiu rd, rs, imm` — `sltiu rd, rs, 1` is `seqz`.
    Sltiu {
        rd: u32,
        rs: u32,
        imm: i32,
    },
    /// `srai rd, rs, shamt`.
    Srai {
        rd: u32,
        rs: u32,
        shamt: u32,
    },
    /// `div rd, rs, rs2` — signed divide.
    Div {
        rd: u32,
        rs: u32,
        rs2: u32,
    },
    /// `rem rd, rs, rs2` — signed remainder.
    Rem {
        rd: u32,
        rs: u32,
        rs2: u32,
    },
    /// `remu rd, rs, rs2`.
    Remu {
        rd: u32,
        rs: u32,
        rs2: u32,
    },
    /// `blt rs, rs2, label` — signed <.
    Blt {
        rs1: u32,
        rs2: u32,
        to: String,
    },
    /// `bge rs, rs2, label`.
    Bge {
        rs1: u32,
        rs2: u32,
        to: String,
    },
    /// `bltu rs, rs2, label` — unsigned <.
    Bltu {
        rs1: u32,
        rs2: u32,
        to: String,
    },
    /// `bgeu rs, rs2, label`.
    Bgeu {
        rs1: u32,
        rs2: u32,
        to: String,
    },
    /// `lb rd, off(rs)` — sign-extended byte load.
    Lb {
        rd: u32,
        rs: u32,
        off: i32,
    },
    /// `lh rd, off(rs)` — sign-extended halfword load.
    Lh {
        rd: u32,
        rs: u32,
        off: i32,
    },
    /// `lhu rd, off(rs)`.
    Lhu {
        rd: u32,
        rs: u32,
        off: i32,
    },
    /// `lwu rd, off(rs)` — RV64 zero-extended word load.
    Lwu {
        rd: u32,
        rs: u32,
        off: i32,
    },
    /// `sh rs2, off(rs)` — halfword store.
    Sh {
        rs2: u32,
        rs1: u32,
        off: i32,
    },
    // ---- RV64 word ops (sign-extended 32-bit results; guest wasm i32 ops).
    /// `addw rd, rs, rs2`.
    Addw {
        rd: u32,
        rs: u32,
        rs2: u32,
    },
    /// `subw rd, rs, rs2`.
    Subw {
        rd: u32,
        rs: u32,
        rs2: u32,
    },
    /// `mulw rd, rs, rs2`.
    Mulw {
        rd: u32,
        rs: u32,
        rs2: u32,
    },
    /// `divw rd, rs, rs2`.
    Divw {
        rd: u32,
        rs: u32,
        rs2: u32,
    },
    /// `divuw rd, rs, rs2`.
    Divuw {
        rd: u32,
        rs: u32,
        rs2: u32,
    },
    /// `remw rd, rs, rs2`.
    Remw {
        rd: u32,
        rs: u32,
        rs2: u32,
    },
    /// `remuw rd, rs, rs2`.
    Remuw {
        rd: u32,
        rs: u32,
        rs2: u32,
    },
    /// `sllw rd, rs, rs2`.
    Sllw {
        rd: u32,
        rs: u32,
        rs2: u32,
    },
    /// `srlw rd, rs, rs2`.
    Srlw {
        rd: u32,
        rs: u32,
        rs2: u32,
    },
    /// `sraw rd, rs, rs2`.
    Sraw {
        rd: u32,
        rs: u32,
        rs2: u32,
    },
    /// `addiw rd, rs, imm`.
    Addiw {
        rd: u32,
        rs: u32,
        imm: i32,
    },
    /// `slliw rd, rs, shamt` (5-bit).
    Slliw {
        rd: u32,
        rs: u32,
        shamt: u32,
    },
    /// `srliw rd, rs, shamt` (5-bit).
    Srliw {
        rd: u32,
        rs: u32,
        shamt: u32,
    },
    /// `sraiw rd, rs, shamt` (5-bit).
    Sraiw {
        rd: u32,
        rs: u32,
        shamt: u32,
    },
    /// Data doubleword in the payload resolving an [`Addr`] — 2 machine words,
    /// little-endian. Dispatch tables (`jit_disp`) carry routine addresses this
    /// way; never executed.
    Dw64 {
        addr: Addr,
    },
    /// Scalar-FP R-type (opcode `0x53`, OP-FP). `rd`/`rs1`/`rs2` index the FP
    /// register file (`f0`-`f31`); `funct7`/`funct3`/`rs2` select the op —
    /// covers `fadd.s`, `fle.s`, `fcvt.s.wu`, `fmv.w.x`, … . M3b exec-model FPU.
    FpR {
        funct7: u32,
        rs2: u32,
        rs1: u32,
        funct3: u32,
        rd: u32,
    },
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
    /// Guest copy of the UI wasm (LDC cell when live; rodata after the boot log; not a VFS).
    pub ui_wasm: Vec<u8>,
    /// Decoded wasm data image (`__wasm_data`) — the linear-memory snapshot the
    /// lowered `WasmStart` resolves string pointers against.
    pub wasm_data: Vec<u8>,
    /// First-party 8x8 font bytes (`__font`) for `DomPaint` glyph lookup.
    pub font: Vec<u8>,
    /// Optional Electric dist wasm (`__pglite_wasm`) when `pglite.embed`.
    pub pglite_wasm: Vec<u8>,
    /// Optional Electric `initdb.wasm` (`__pglite_initdb`) when `pglite.embed`.
    pub pglite_initdb: Vec<u8>,
    /// Optional Electric `pglite.data` (`__pglite_data`) when `pglite.embed`.
    pub pglite_data: Vec<u8>,
    /// First-party registry dump (`__g6b_store_dump`) when `persist.elf`.
    pub store_dump: Vec<u8>,
    /// Bounded guest DOM row table BSS (`__ui_dom`) when `kernel.wasm.jit`.
    pub dom_bytes: u64,
    /// Compact persist BSS (`__ui_cap`) when a scanout path is live (B91).
    pub cap_bytes: u64,
    /// Virtio virtqueue/request BSS (`__vio`) when `wants_virtio_gpu`.
    pub vio_bytes: u64,
    /// Linear X8R8G8B8 scanout BSS (`__scan_fb`) when a display path is
    /// live (`wants_virtio_gpu` or `wants_disp_scan`).
    pub vio_fb_bytes: u64,
    /// Predecoded guest-JIT bytecode image (`__jit_in`) in `.rodata` —
    /// `g6b_wasm::jcode::encode` output, not raw wasm.
    pub jit_in: Vec<u8>,
    /// JIT state header BSS (`__jit`): magic/state/fuel/counters/func table/
    /// const pool/globals.
    pub jit_bytes: u64,
    /// JIT value/call stack BSS (`__jit_stk`).
    pub jit_stk_bytes: u64,
    /// JIT code arena BSS (`__jit_code`) — executable by policy (bare satp);
    /// `fence.i` between write and first jump.
    pub jit_code_bytes: u64,
    /// Wasm linear memory BSS (`__wasm_mem`).
    pub wasm_mem_bytes: u64,
    /// virgl execbuffer (`__virgl_cmd`) in `.rodata` after `__jit_in` — the
    /// `SUBMIT_3D` command stream `VioVirgl` submits under `proxy.gl` (M4).
    pub virgl_cmd: Vec<u8>,
    /// virgl ctrlq request table (`__virgl_req`) after `__virgl_cmd` — the
    /// CAPSET→CTX_CREATE→SUBMIT_3D→TRANSFER→FLUSH records `VioVirgl` walks.
    pub virgl_req: Vec<u8>,
    /// Guest DOM tree arena BSS (`__dom`) when `kernel.wasm.jit` — the M2
    /// bounded node store (header + fixed node pool).
    pub domt_bytes: u64,
    /// Guest DOM string pool BSS (`__dom_str`) — bump-allocated text/id bytes.
    pub doms_bytes: u64,
    /// `__dom_id` BSS bytes (per-node element-id table).
    pub domid_bytes: u64,
    /// `__ev_obj` BSS bytes — the bounded event record `DomtKey` fills before
    /// `JitCall` re-enters a `N_LISTEN >= 0x100` wasm listener. The delegate
    /// receives its address as the event handle; field layout is `domt::EV_*`.
    /// 0 when no guest-DOM/JIT lane.
    pub evobj_bytes: u64,
    /// `__prom` BSS bytes — the bounded promise/object table (`PromAlloc`/
    /// `PromDrain`, the `libwasm_await_*`/`libasync_promise_*` lane). Record
    /// layout is `domt::PROM_*`. 0 when no guest-DOM/JIT lane.
    pub prom_bytes: u64,
    /// `__virgl_out` BSS bytes — the guest-RAM readback target for
    /// `TRANSFER_FROM_HOST_3D` under `proxy.gl` (the offscreen `RES_RT`
    /// render pulled back into guest memory). 0 when no virgl lane.
    pub virgl_out_bytes: u64,
    /// Packed web present (`__web_pk`) in `.rodata` after `__virgl_req` —
    /// the host-rendered `Canvas32` scene (`g6b_kernel::web_pk_pack` RLE word
    /// stream) `WebBlit` decodes into the `__disp`-latched surface. Empty ⇒
    /// `__web_pk` aliases `boot_log` so the guest magic check fails cleanly.
    pub web_pk: Vec<u8>,
    /// Packed display list (`__web_dl`) in `.rodata` after `__web_pk` —
    /// `g6b_kernel::dl_pack`'s op stream + glyph atlas + state/tref/hit
    /// tables `DlPaint` replays. Empty ⇒ `__web_dl` aliases `boot_log` like
    /// `__web_pk` (non-magic ⇒ `DlPaint` yields to `WebBlit`).
    pub web_dl: Vec<u8>,
    /// Kernel-GET table (`__kget`) in `.rodata` after `__web_dl` —
    /// `g6b_kernel::kget_pack`'s `{url → body}` map `KernelGet` resolves
    /// `env.fetch` against. Empty ⇒ `__kget` aliases `boot_log` (non-magic
    /// ⇒ `KernelGet` yields `0` — no resolved body).
    pub kget: Vec<u8>,
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

/// Guest `g6b-zealcli` container: edit line, page dispatch, keymap.
pub mod cli;

/// UART line: 128 data bytes + u32 length + probe-absent flags.
pub const UART_LINE_CAP: u32 = 128;
/// `__uart_line+132` — set by `trap_fault` when an MMIO access fault hits
/// the UART1 probe window (absent second ns16550, e.g. stock QEMU virt).
pub const UART1_DEAD_OFF: u32 = 132;
/// `__uart_line+133` — set by `trap_fault` for the loopback mailbox window.
pub const MBOX_DEAD_OFF: u32 = 133;
/// `__uart_line+136` — the `g6b-zealcli` **edit line**: the prompt prefix
/// followed by what the operator has typed. It is a DOM-row text buffer (the
/// container's bottom row points at it), so a keystroke changes what the next
/// paint shows without republishing anything.
pub const CLI_LINE_OFF: i32 = 136;
/// Bytes the edit line may hold, prompt prefix included.
pub const CLI_LINE_CAP: i32 = 120;
/// `__uart_line+256` — u32 live length of [`CLI_LINE_OFF`] (prefix + typed).
pub const CLI_LINE_LEN_OFF: i32 = 256;
/// `__uart_line+260` — u32 edit counter. `CliKey` bumps it; the timer tick
/// repaints when it moved, so nothing paints from IRQ context.
pub const CLI_DIRTY_OFF: i32 = 260;
/// `__uart_line+264` — u32 painted watermark for [`CLI_DIRTY_OFF`].
pub const CLI_PAINTED_OFF: i32 = 264;
/// `__uart_line+268` — u32 length of the prompt prefix, so backspace knows
/// where the typed text starts.
pub const CLI_PROMPT_LEN_OFF: i32 = 268;
/// `__uart_line+272` — u32 length of the UART line at the newline. The band
/// dispatcher zeroes the live length word before it compares commands, so the
/// CLI hook needs the value stashed to know how much of the line to run.
pub const CLI_UART_LEN_OFF: i32 = 272;
/// `__uart_line+276` — u32: the autoboot picker owns the screen (1) or not (0).
pub const AUTO_ON_OFF: i32 = 276;
/// `__uart_line+280` — u32 selected entry index.
pub const AUTO_SEL_OFF: i32 = 280;
/// `__uart_line+284` — u32 timer ticks left in the countdown; `0` means the
/// countdown is off (expired, stopped by a keypress, or never armed).
pub const AUTO_TICKS_OFF: i32 = 284;
/// `__uart_line+288` — u32 whole seconds left, so the header is only
/// republished when the digit an operator reads actually changes.
pub const AUTO_SECS_OFF: i32 = 288;
/// `__uart_line+292` — u32: the picker already had its turn. The boot menu is a
/// power-on question, so once it is answered (Enter, Esc, or the countdown) the
/// prompt must not ask again — `CliInit` is also the "back to the prompt" path.
pub const AUTO_DONE_OFF: i32 = 292;
/// `__uart_line+296` — the `DomPaint` re-entrancy guard.
///
/// It lives here rather than in `__vio` because **this block always exists**: a
/// board with no virtio device has no `__vio`, and a guard that writes into
/// whatever follows an absent block is worse than no guard at all. The trap frame
/// saves `ra`, `t0..t6` and `a0..a7` but *not* `s0..s5`, which `DomPaint` uses, so
/// a timer tick landing inside a normal-context paint would repaint with the
/// interrupted call's registers. The interrupting call returns instead; the next
/// tick repaints, because the dirty watermark is still ahead of the painted one.
pub const PAINT_BUSY_OFF: i32 = 296;
/// `__uart_line+300` — **which face owns the screen**: `0` the zealcli container
/// (and the boot picker), `1` the web engine.
///
/// A build that carries the whole engine still boots the minimally dependent face
/// first, so both are compiled and one plane is shared. The latch is what keeps
/// them from fighting over it: while the CLI owns the screen the wasm UI does not
/// paint and keys edit the prompt; taking the picker's "BIOS UI" entry (or running
/// `LoadUI`) flips it, and from then on keys are the browser's and the tick paints
/// the browser's DOM. Without a latch the two faces would publish rows into the
/// same `__ui_dom` and blit over each other every tick.
pub const FACE_OWNER_OFF: i32 = 300;
/// `__uart_line+304` — u32: the guest painted `__web_pk` into the latched
/// output surface and it is still authoritative there.
///
/// `WebBlit` sets it after a successful blit; `CliInit` clears it when the CLI
/// face takes the plane back from the web face (the web→CLI transition), and
/// the `FbExpandSel` commit rungs (`DispPaint`/`PciPaint`) skip the plane
/// expand while it is set so they do not paint the 4bpp container over the
/// packed canvas. It lives in `__uart_line` for the same reason `PAINT_BUSY`
/// does — this block exists on every board, so the flag cannot write into an
/// absent `__vio`/`__ui_cap` on a pcie-only build.
pub const WEB_STAMPED_OFF: i32 = 304;
/// Face codes for [`FACE_OWNER_OFF`].
pub const FACE_CLI: i64 = 0;
pub const FACE_WEB: i64 = 1;
pub const CLI_VOLUME_OFF: i32 = 308;
pub const CLI_FILES_OFF: i32 = 320;
pub const UART_LINE_BSS: u64 = 832;
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
            .saturating_add(self.pglite_wasm.len() as u64)
            .saturating_add(self.pglite_initdb.len() as u64)
            .saturating_add(self.pglite_data.len() as u64)
            .saturating_add(self.store_dump.len() as u64)
            .saturating_add(self.jit_in.len() as u64)
            .saturating_add(self.virgl_cmd.len() as u64)
            .saturating_add(self.virgl_req.len() as u64)
            .saturating_add(self.web_pk.len() as u64)
            .saturating_add(self.web_dl.len() as u64)
            .saturating_add(self.kget.len() as u64)
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

    /// BSS after stacks: Gr + UART line + G6UI + DOM + compact cap + virtio + scanout.
    pub fn extra_bss(&self) -> u64 {
        self.gr_bytes
            .saturating_add(self.line_bytes)
            .saturating_add(self.ui_bytes)
            .saturating_add(self.dom_bytes)
            .saturating_add(self.cap_bytes)
            .saturating_add(self.vio_bytes)
            .saturating_add(self.vio_fb_bytes)
            .saturating_add(self.jit_bytes)
            .saturating_add(self.jit_stk_bytes)
            .saturating_add(self.jit_code_bytes)
            .saturating_add(self.wasm_mem_bytes)
            .saturating_add(self.domt_bytes)
            .saturating_add(self.doms_bytes)
            .saturating_add(self.domid_bytes)
            .saturating_add(self.virgl_out_bytes)
            .saturating_add(self.evobj_bytes)
            .saturating_add(self.prom_bytes)
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
            || !self.pglite_wasm.is_empty()
            || !self.pglite_initdb.is_empty()
            || !self.pglite_data.is_empty()
            || !self.store_dump.is_empty()
            || !self.virgl_cmd.is_empty()
            || !self.virgl_req.is_empty()
            || !self.web_pk.is_empty()
            || !self.web_dl.is_empty()
            || !self.kget.is_empty()
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
            if !self.pglite_wasm.is_empty() {
                s.push_str("__pglite_wasm:\n");
                s.push_str(&rodata_listing(&self.pglite_wasm));
            }
            if !self.pglite_initdb.is_empty() {
                s.push_str("__pglite_initdb:\n");
                s.push_str(&rodata_listing(&self.pglite_initdb));
            }
            if !self.pglite_data.is_empty() {
                s.push_str("__pglite_data:\n");
                s.push_str(&rodata_listing(&self.pglite_data));
            }
            if !self.store_dump.is_empty() {
                s.push_str("__g6b_store_dump:\n");
                s.push_str(&rodata_listing(&self.store_dump));
            }
            if !self.jit_in.is_empty() {
                s.push_str("__jit_in:\n");
                s.push_str(&rodata_listing(&self.jit_in));
            }
            if !self.virgl_cmd.is_empty() {
                s.push_str("__virgl_cmd:\n");
                s.push_str(&rodata_listing(&self.virgl_cmd));
            }
            if !self.virgl_req.is_empty() {
                s.push_str("__virgl_req:\n");
                s.push_str(&rodata_listing(&self.virgl_req));
            }
            if !self.web_pk.is_empty() {
                s.push_str("__web_pk:\n");
                s.push_str(&rodata_listing(&self.web_pk));
            } else if !self.rodata.is_empty() {
                // No pack installed: alias the magic slot onto `boot_log`
                // (whose 'KSTA' first word never matches 'G6PK') so `la
                // __web_pk` still resolves and `WebBlit` reads "no pack".
                s.push_str(".set __web_pk, boot_log\n");
            } else {
                // Degenerate hand-built module with no rodata at all: give
                // `la __web_pk` a real word so the magic slot reads 0 rather
                // than whatever follows `.rodata`.
                s.push_str("__web_pk:\n\t.word\t0\n");
            }
            if !self.web_dl.is_empty() {
                s.push_str("__web_dl:\n");
                s.push_str(&rodata_listing(&self.web_dl));
            } else if !self.rodata.is_empty() {
                // Same alias trick as `__web_pk`: 'KSTA' never matches
                // 'G6DL', so `DlPaint` reads "no list" and yields to
                // `WebBlit`/the text-face paths.
                s.push_str(".set __web_dl, boot_log\n");
            } else {
                s.push_str("__web_dl:\n\t.word\t0\n");
            }
            if !self.kget.is_empty() {
                s.push_str("__kget:\n");
                s.push_str(&rodata_listing(&self.kget));
            } else if !self.rodata.is_empty() {
                // Same `boot_log` alias: 'KSTA' never matches 'G6KG', so
                // `KernelGet` resolves no entry and `LwFetch` yields 0.
                s.push_str(".set __kget, boot_log\n");
            } else {
                s.push_str("__kget:\n\t.word\t0\n");
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
        if self.cap_bytes > 0 {
            if !self.nodes.iter().any(|n| n.purpose == Purpose::Stack)
                && self.line_bytes == 0
                && self.ui_bytes == 0
                && self.dom_bytes == 0
            {
                s.push_str("\n.section .bss\n");
            }
            s.push_str(&format!("__ui_cap:\n.space {:#x}\n", self.cap_bytes));
        }
        if self.vio_bytes > 0 {
            if !self.nodes.iter().any(|n| n.purpose == Purpose::Stack)
                && self.line_bytes == 0
                && self.ui_bytes == 0
                && self.dom_bytes == 0
                && self.cap_bytes == 0
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
                && self.cap_bytes == 0
                && self.vio_bytes == 0
            {
                s.push_str("\n.section .bss\n");
            }
            s.push_str(&format!("__scan_fb:\n.space {:#x}\n", self.vio_fb_bytes));
        }
        let jit_bss =
            self.jit_bytes + self.jit_stk_bytes + self.jit_code_bytes + self.wasm_mem_bytes;
        if jit_bss > 0
            && !self.nodes.iter().any(|n| n.purpose == Purpose::Stack)
            && self.line_bytes == 0
            && self.ui_bytes == 0
            && self.dom_bytes == 0
            && self.cap_bytes == 0
            && self.vio_bytes == 0
            && self.vio_fb_bytes == 0
        {
            s.push_str("\n.section .bss\n");
        }
        if self.jit_bytes > 0 {
            s.push_str(&format!("__jit:\n.space {:#x}\n", self.jit_bytes));
        }
        if self.jit_stk_bytes > 0 {
            s.push_str(&format!("__jit_stk:\n.space {:#x}\n", self.jit_stk_bytes));
        }
        if self.jit_code_bytes > 0 {
            s.push_str(&format!("__jit_code:\n.space {:#x}\n", self.jit_code_bytes));
        }
        if self.wasm_mem_bytes > 0 {
            s.push_str(&format!("__wasm_mem:\n.space {:#x}\n", self.wasm_mem_bytes));
        }
        if (self.domt_bytes > 0 || self.doms_bytes > 0)
            && !self.nodes.iter().any(|n| n.purpose == Purpose::Stack)
            && self.line_bytes == 0
            && self.ui_bytes == 0
            && self.dom_bytes == 0
            && self.cap_bytes == 0
            && self.vio_bytes == 0
            && self.vio_fb_bytes == 0
            && jit_bss == 0
        {
            s.push_str("\n.section .bss\n");
        }
        if self.domt_bytes > 0 {
            s.push_str(&format!("__dom:\n.space {:#x}\n", self.domt_bytes));
        }
        if self.doms_bytes > 0 {
            s.push_str(&format!("__dom_str:\n.space {:#x}\n", self.doms_bytes));
        }
        if self.domid_bytes > 0 {
            s.push_str(&format!("__dom_id:\n.space {:#x}\n", self.domid_bytes));
        }
        if self.virgl_out_bytes > 0 {
            if !self.nodes.iter().any(|n| n.purpose == Purpose::Stack)
                && self.line_bytes == 0
                && self.ui_bytes == 0
                && self.dom_bytes == 0
                && self.cap_bytes == 0
                && self.vio_bytes == 0
                && self.vio_fb_bytes == 0
                && jit_bss == 0
                && self.domt_bytes == 0
                && self.doms_bytes == 0
                && self.domid_bytes == 0
            {
                s.push_str("\n.section .bss\n");
            }
            s.push_str(&format!(
                "__virgl_out:\n.space {:#x}\n",
                self.virgl_out_bytes
            ));
        }
        if self.evobj_bytes > 0 {
            if !self.nodes.iter().any(|n| n.purpose == Purpose::Stack)
                && self.line_bytes == 0
                && self.ui_bytes == 0
                && self.dom_bytes == 0
                && self.cap_bytes == 0
                && self.vio_bytes == 0
                && self.vio_fb_bytes == 0
                && jit_bss == 0
                && self.domt_bytes == 0
                && self.doms_bytes == 0
                && self.domid_bytes == 0
                && self.virgl_out_bytes == 0
            {
                s.push_str("\n.section .bss\n");
            }
            s.push_str(&format!("__ev_obj:\n.space {:#x}\n", self.evobj_bytes));
        }
        if self.prom_bytes > 0 {
            if !self.nodes.iter().any(|n| n.purpose == Purpose::Stack)
                && self.line_bytes == 0
                && self.ui_bytes == 0
                && self.dom_bytes == 0
                && self.cap_bytes == 0
                && self.vio_bytes == 0
                && self.vio_fb_bytes == 0
                && jit_bss == 0
                && self.domt_bytes == 0
                && self.doms_bytes == 0
                && self.domid_bytes == 0
                && self.virgl_out_bytes == 0
                && self.evobj_bytes == 0
            {
                s.push_str("\n.section .bss\n");
            }
            s.push_str(&format!("__prom:\n.space {:#x}\n", self.prom_bytes));
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
                .wrapping_add(self.dom_bytes)
                .wrapping_add(self.cap_bytes),
        )
    }

    /// Resolved `__ui_cap` BSS address, or `None` when the module has no cap.
    pub fn cap_addr(&self, entry: u64) -> Option<u64> {
        if self.cap_bytes == 0 {
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

    /// BSS base of the first jit block (`__jit`) — `None` when no jit regions.
    fn jit_base(&self, entry: u64) -> Option<u64> {
        let (words, _) = self.to_words(entry).ok()?;
        let code_bytes = (words.len() * 4) as u64;
        let filesz = self.image_filesz(code_bytes);
        let stacks = entry.wrapping_add(stack_memsz(filesz, self.n_harts()));
        Some(
            stacks
                .wrapping_add(self.gr_bytes)
                .wrapping_add(self.line_bytes)
                .wrapping_add(self.ui_bytes)
                .wrapping_add(self.dom_bytes)
                .wrapping_add(self.cap_bytes)
                .wrapping_add(self.vio_bytes)
                .wrapping_add(self.vio_fb_bytes),
        )
    }

    /// Resolved `__jit` state-header address, or `None` when not allocated.
    pub fn jit_hdr_addr(&self, entry: u64) -> Option<u64> {
        if self.jit_bytes == 0 {
            return None;
        }
        self.jit_base(entry)
    }

    /// Resolved `__jit_code` arena address, or `None` when not allocated.
    pub fn jit_code_addr(&self, entry: u64) -> Option<u64> {
        if self.jit_code_bytes == 0 {
            return None;
        }
        self.jit_base(entry).map(|b| {
            b.wrapping_add(self.jit_bytes)
                .wrapping_add(self.jit_stk_bytes)
        })
    }

    /// Resolved `__wasm_mem` address, or `None` when not allocated.
    pub fn wasm_mem_addr(&self, entry: u64) -> Option<u64> {
        if self.wasm_mem_bytes == 0 {
            return None;
        }
        self.jit_base(entry).map(|b| {
            b.wrapping_add(self.jit_bytes)
                .wrapping_add(self.jit_stk_bytes)
                .wrapping_add(self.jit_code_bytes)
        })
    }

    /// Resolved `__dom` (DomT) arena address, or `None` when not allocated.
    ///
    /// `Addr::DomT` chains immediately after `__wasm_mem`, so the base is the
    /// wasm-memory top. Exposed so the exec model can scan the live DOM for
    /// node/listener bookkeeping in regression checks.
    pub fn domt_addr(&self, entry: u64) -> Option<u64> {
        if self.domt_bytes == 0 {
            return None;
        }
        self.wasm_mem_addr(entry)
            .map(|b| b.wrapping_add(self.wasm_mem_bytes))
    }

    /// Resolved `__scan_fb` BSS address for a module loaded at `entry`.
    ///
    /// Same arithmetic `to_words` uses for `Addr::ScanFb`; exposed so the exec
    /// model can read the native 32bpp scanout for regression checks. `None`
    /// when the module allocates no `__scan_fb`.
    pub fn scan_fb_addr(&self, entry: u64) -> Option<u64> {
        if self.vio_fb_bytes == 0 {
            return None;
        }
        let vio = self.vio_bss_addr(entry)?;
        Some(vio.wrapping_add(self.vio_bytes))
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
                    let a = resolve_addr(addr, rodata_addr, stacks, entry, &labels, self)?;
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
                Op::Dw64 { addr } => {
                    let filesz = self.image_filesz(code_bytes);
                    let stacks = entry.wrapping_add(stack_memsz(filesz, self.n_harts()));
                    let a = resolve_addr(addr, rodata_addr, stacks, entry, &labels, self)?;
                    words.push(a as u32);
                    words.push((a >> 32) as u32);
                    i += 2;
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
        rod.extend_from_slice(&self.pglite_wasm);
        rod.extend_from_slice(&self.pglite_initdb);
        rod.extend_from_slice(&self.pglite_data);
        rod.extend_from_slice(&self.store_dump);
        rod.extend_from_slice(&self.jit_in);
        rod.extend_from_slice(&self.virgl_cmd);
        rod.extend_from_slice(&self.virgl_req);
        rod.extend_from_slice(&self.web_pk);
        rod.extend_from_slice(&self.web_dl);
        rod.extend_from_slice(&self.kget);
        Ok((words, rod))
    }

    /// Load address of a code label (`uart_ui`, `VioPaint`, …). `None` if
    /// the payload never emitted that label.
    pub fn label_addr(&self, entry: u64, name: &str) -> Option<u64> {
        let flat: Vec<&Op> = self.nodes.iter().flat_map(|n| n.ops.iter()).collect();
        let mut idx = 0usize;
        for op in &flat {
            match op {
                Op::Label(l) if l == name => {
                    return Some(entry.wrapping_add((idx * 4) as u64));
                }
                Op::Label(_) | Op::Comment(_) | Op::Glob(_) | Op::Directive(_) => {}
                other => idx += op_nwords(other),
            }
        }
        None
    }
}

/// Resolve an [`Addr`] to its absolute guest address. Shared by `La` (which
/// emits `auipc`+`addi` of the *delta*) and `Dw64` (which emits the address
/// itself as data).
fn resolve_addr(
    addr: &Addr,
    rodata_addr: u64,
    stacks: u64,
    entry: u64,
    labels: &BTreeMap<String, usize>,
    m: &Module,
) -> Result<u64, String> {
    Ok(match addr {
        Addr::Abs(v) => *v,
        Addr::Rodata => rodata_addr,
        Addr::UiWasm => rodata_addr.wrapping_add(m.rodata.len() as u64),
        Addr::WasmData => rodata_addr
            .wrapping_add(m.rodata.len() as u64)
            .wrapping_add(m.ui_wasm.len() as u64),
        Addr::UiFont => rodata_addr
            .wrapping_add(m.rodata.len() as u64)
            .wrapping_add(m.ui_wasm.len() as u64)
            .wrapping_add(m.wasm_data.len() as u64),
        Addr::JitIn => rodata_addr
            .wrapping_add(m.rodata.len() as u64)
            .wrapping_add(m.ui_wasm.len() as u64)
            .wrapping_add(m.wasm_data.len() as u64)
            .wrapping_add(m.font.len() as u64)
            .wrapping_add(m.pglite_wasm.len() as u64)
            .wrapping_add(m.pglite_initdb.len() as u64)
            .wrapping_add(m.pglite_data.len() as u64)
            .wrapping_add(m.store_dump.len() as u64),
        Addr::StacksEnd | Addr::StackTop | Addr::GrPlane => stacks,
        Addr::UartLine => stacks.wrapping_add(m.gr_bytes),
        Addr::UiBlob => stacks.wrapping_add(m.gr_bytes).wrapping_add(m.line_bytes),
        Addr::UiDom => stacks
            .wrapping_add(m.gr_bytes)
            .wrapping_add(m.line_bytes)
            .wrapping_add(m.ui_bytes),
        Addr::UiCap => stacks
            .wrapping_add(m.gr_bytes)
            .wrapping_add(m.line_bytes)
            .wrapping_add(m.ui_bytes)
            .wrapping_add(m.dom_bytes),
        Addr::VioBss => stacks
            .wrapping_add(m.gr_bytes)
            .wrapping_add(m.line_bytes)
            .wrapping_add(m.ui_bytes)
            .wrapping_add(m.dom_bytes)
            .wrapping_add(m.cap_bytes),
        Addr::ScanFb => stacks
            .wrapping_add(m.gr_bytes)
            .wrapping_add(m.line_bytes)
            .wrapping_add(m.ui_bytes)
            .wrapping_add(m.dom_bytes)
            .wrapping_add(m.cap_bytes)
            .wrapping_add(m.vio_bytes),
        Addr::JitHdr => stacks
            .wrapping_add(m.gr_bytes)
            .wrapping_add(m.line_bytes)
            .wrapping_add(m.ui_bytes)
            .wrapping_add(m.dom_bytes)
            .wrapping_add(m.cap_bytes)
            .wrapping_add(m.vio_bytes)
            .wrapping_add(m.vio_fb_bytes),
        Addr::JitStk => stacks
            .wrapping_add(m.gr_bytes)
            .wrapping_add(m.line_bytes)
            .wrapping_add(m.ui_bytes)
            .wrapping_add(m.dom_bytes)
            .wrapping_add(m.cap_bytes)
            .wrapping_add(m.vio_bytes)
            .wrapping_add(m.vio_fb_bytes)
            .wrapping_add(m.jit_bytes),
        Addr::JitCode => stacks
            .wrapping_add(m.gr_bytes)
            .wrapping_add(m.line_bytes)
            .wrapping_add(m.ui_bytes)
            .wrapping_add(m.dom_bytes)
            .wrapping_add(m.cap_bytes)
            .wrapping_add(m.vio_bytes)
            .wrapping_add(m.vio_fb_bytes)
            .wrapping_add(m.jit_bytes)
            .wrapping_add(m.jit_stk_bytes),
        Addr::WasmMem => stacks
            .wrapping_add(m.gr_bytes)
            .wrapping_add(m.line_bytes)
            .wrapping_add(m.ui_bytes)
            .wrapping_add(m.dom_bytes)
            .wrapping_add(m.cap_bytes)
            .wrapping_add(m.vio_bytes)
            .wrapping_add(m.vio_fb_bytes)
            .wrapping_add(m.jit_bytes)
            .wrapping_add(m.jit_stk_bytes)
            .wrapping_add(m.jit_code_bytes),
        Addr::DomT => stacks
            .wrapping_add(m.gr_bytes)
            .wrapping_add(m.line_bytes)
            .wrapping_add(m.ui_bytes)
            .wrapping_add(m.dom_bytes)
            .wrapping_add(m.cap_bytes)
            .wrapping_add(m.vio_bytes)
            .wrapping_add(m.vio_fb_bytes)
            .wrapping_add(m.jit_bytes)
            .wrapping_add(m.jit_stk_bytes)
            .wrapping_add(m.jit_code_bytes)
            .wrapping_add(m.wasm_mem_bytes),
        Addr::DomS => stacks
            .wrapping_add(m.gr_bytes)
            .wrapping_add(m.line_bytes)
            .wrapping_add(m.ui_bytes)
            .wrapping_add(m.dom_bytes)
            .wrapping_add(m.cap_bytes)
            .wrapping_add(m.vio_bytes)
            .wrapping_add(m.vio_fb_bytes)
            .wrapping_add(m.jit_bytes)
            .wrapping_add(m.jit_stk_bytes)
            .wrapping_add(m.jit_code_bytes)
            .wrapping_add(m.wasm_mem_bytes)
            .wrapping_add(m.domt_bytes),
        Addr::DomId => stacks
            .wrapping_add(m.gr_bytes)
            .wrapping_add(m.line_bytes)
            .wrapping_add(m.ui_bytes)
            .wrapping_add(m.dom_bytes)
            .wrapping_add(m.cap_bytes)
            .wrapping_add(m.vio_bytes)
            .wrapping_add(m.vio_fb_bytes)
            .wrapping_add(m.jit_bytes)
            .wrapping_add(m.jit_stk_bytes)
            .wrapping_add(m.jit_code_bytes)
            .wrapping_add(m.wasm_mem_bytes)
            .wrapping_add(m.domt_bytes)
            .wrapping_add(m.doms_bytes),
        Addr::VirglOut => stacks
            .wrapping_add(m.gr_bytes)
            .wrapping_add(m.line_bytes)
            .wrapping_add(m.ui_bytes)
            .wrapping_add(m.dom_bytes)
            .wrapping_add(m.cap_bytes)
            .wrapping_add(m.vio_bytes)
            .wrapping_add(m.vio_fb_bytes)
            .wrapping_add(m.jit_bytes)
            .wrapping_add(m.jit_stk_bytes)
            .wrapping_add(m.jit_code_bytes)
            .wrapping_add(m.wasm_mem_bytes)
            .wrapping_add(m.domt_bytes)
            .wrapping_add(m.doms_bytes)
            .wrapping_add(m.domid_bytes),
        Addr::EvObj => stacks
            .wrapping_add(m.gr_bytes)
            .wrapping_add(m.line_bytes)
            .wrapping_add(m.ui_bytes)
            .wrapping_add(m.dom_bytes)
            .wrapping_add(m.cap_bytes)
            .wrapping_add(m.vio_bytes)
            .wrapping_add(m.vio_fb_bytes)
            .wrapping_add(m.jit_bytes)
            .wrapping_add(m.jit_stk_bytes)
            .wrapping_add(m.jit_code_bytes)
            .wrapping_add(m.wasm_mem_bytes)
            .wrapping_add(m.domt_bytes)
            .wrapping_add(m.doms_bytes)
            .wrapping_add(m.domid_bytes)
            .wrapping_add(m.virgl_out_bytes),
        Addr::Prom => stacks
            .wrapping_add(m.gr_bytes)
            .wrapping_add(m.line_bytes)
            .wrapping_add(m.ui_bytes)
            .wrapping_add(m.dom_bytes)
            .wrapping_add(m.cap_bytes)
            .wrapping_add(m.vio_bytes)
            .wrapping_add(m.vio_fb_bytes)
            .wrapping_add(m.jit_bytes)
            .wrapping_add(m.jit_stk_bytes)
            .wrapping_add(m.jit_code_bytes)
            .wrapping_add(m.wasm_mem_bytes)
            .wrapping_add(m.domt_bytes)
            .wrapping_add(m.doms_bytes)
            .wrapping_add(m.domid_bytes)
            .wrapping_add(m.virgl_out_bytes)
            .wrapping_add(m.evobj_bytes),
        Addr::VirglCmd => rodata_addr
            .wrapping_add(m.rodata.len() as u64)
            .wrapping_add(m.ui_wasm.len() as u64)
            .wrapping_add(m.wasm_data.len() as u64)
            .wrapping_add(m.font.len() as u64)
            .wrapping_add(m.pglite_wasm.len() as u64)
            .wrapping_add(m.pglite_initdb.len() as u64)
            .wrapping_add(m.pglite_data.len() as u64)
            .wrapping_add(m.store_dump.len() as u64)
            .wrapping_add(m.jit_in.len() as u64),
        Addr::VirglReq => rodata_addr
            .wrapping_add(m.rodata.len() as u64)
            .wrapping_add(m.ui_wasm.len() as u64)
            .wrapping_add(m.wasm_data.len() as u64)
            .wrapping_add(m.font.len() as u64)
            .wrapping_add(m.pglite_wasm.len() as u64)
            .wrapping_add(m.pglite_initdb.len() as u64)
            .wrapping_add(m.pglite_data.len() as u64)
            .wrapping_add(m.store_dump.len() as u64)
            .wrapping_add(m.jit_in.len() as u64)
            .wrapping_add(m.virgl_cmd.len() as u64),
        // No pack → `__web_pk` aliases `boot_log` (see `.set` in `to_asm`):
        // its 'KSTA' first word never matches `WEB_PK_MAGIC`, so `WebBlit`
        // reads a clean "no pack" without a sentinel word in `.rodata`.
        Addr::WebPk if m.web_pk.is_empty() => rodata_addr,
        Addr::WebPk => rodata_addr
            .wrapping_add(m.rodata.len() as u64)
            .wrapping_add(m.ui_wasm.len() as u64)
            .wrapping_add(m.wasm_data.len() as u64)
            .wrapping_add(m.font.len() as u64)
            .wrapping_add(m.pglite_wasm.len() as u64)
            .wrapping_add(m.pglite_initdb.len() as u64)
            .wrapping_add(m.pglite_data.len() as u64)
            .wrapping_add(m.store_dump.len() as u64)
            .wrapping_add(m.jit_in.len() as u64)
            .wrapping_add(m.virgl_cmd.len() as u64)
            .wrapping_add(m.virgl_req.len() as u64),
        // Same `boot_log` alias as `WebPk` (see `.set` in `to_asm`).
        Addr::WebDl if m.web_dl.is_empty() => rodata_addr,
        Addr::WebDl => rodata_addr
            .wrapping_add(m.rodata.len() as u64)
            .wrapping_add(m.ui_wasm.len() as u64)
            .wrapping_add(m.wasm_data.len() as u64)
            .wrapping_add(m.font.len() as u64)
            .wrapping_add(m.pglite_wasm.len() as u64)
            .wrapping_add(m.pglite_initdb.len() as u64)
            .wrapping_add(m.pglite_data.len() as u64)
            .wrapping_add(m.store_dump.len() as u64)
            .wrapping_add(m.jit_in.len() as u64)
            .wrapping_add(m.virgl_cmd.len() as u64)
            .wrapping_add(m.virgl_req.len() as u64)
            .wrapping_add(m.web_pk.len() as u64),
        // Same `boot_log` alias as `WebDl` (see `.set` in `to_asm`).
        Addr::KGet if m.kget.is_empty() => rodata_addr,
        Addr::KGet => rodata_addr
            .wrapping_add(m.rodata.len() as u64)
            .wrapping_add(m.ui_wasm.len() as u64)
            .wrapping_add(m.wasm_data.len() as u64)
            .wrapping_add(m.font.len() as u64)
            .wrapping_add(m.pglite_wasm.len() as u64)
            .wrapping_add(m.pglite_initdb.len() as u64)
            .wrapping_add(m.pglite_data.len() as u64)
            .wrapping_add(m.store_dump.len() as u64)
            .wrapping_add(m.jit_in.len() as u64)
            .wrapping_add(m.virgl_cmd.len() as u64)
            .wrapping_add(m.virgl_req.len() as u64)
            .wrapping_add(m.web_pk.len() as u64)
            .wrapping_add(m.web_dl.len() as u64),
        Addr::Label(l) => {
            let at = *labels.get(l).ok_or_else(|| format!("unknown label {l}"))?;
            entry.wrapping_add((at * 4) as u64)
        }
    })
}

/// Machine words an [`Op`] assembles to — `La`/`Dw64` are 2, `Li` varies with
/// the immediate width, everything else is 1. Used by `to_words`/`label_addr`
/// to keep the label index ↔ code-offset map exact.
pub fn op_nwords(op: &Op) -> usize {
    match op {
        Op::Label(_) | Op::Comment(_) | Op::Glob(_) | Op::Directive(_) => 0,
        Op::La { .. } | Op::Dw64 { .. } => 2,
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
        Op::Divu { rd, rs1, rs2 } => encode::divu(*rd, *rs1, *rs2),
        Op::Xor { rd, rs1, rs2 } => encode::xor(*rd, *rs1, *rs2),
        Op::Beq { rs1, rs2, to } => encode::beq(*rs1, *rs2, rel(to)?),
        Op::Bne { rs1, rs2, to } => encode::bne(*rs1, *rs2, rel(to)?),
        Op::Blt { rs1, rs2, to } => encode::blt(*rs1, *rs2, rel(to)?),
        Op::Bge { rs1, rs2, to } => encode::bge(*rs1, *rs2, rel(to)?),
        Op::Bltu { rs1, rs2, to } => encode::bltu(*rs1, *rs2, rel(to)?),
        Op::Bgeu { rs1, rs2, to } => encode::bgeu(*rs1, *rs2, rel(to)?),
        Op::And { rd, rs, rs2 } => encode::and_(*rd, *rs, *rs2),
        Op::Or { rd, rs, rs2 } => encode::or_(*rd, *rs, *rs2),
        Op::Sll { rd, rs, rs2 } => encode::sll(*rd, *rs, *rs2),
        Op::Srl { rd, rs, rs2 } => encode::srl(*rd, *rs, *rs2),
        Op::Sra { rd, rs, rs2 } => encode::sra(*rd, *rs, *rs2),
        Op::Slt { rd, rs, rs2 } => encode::slt(*rd, *rs, *rs2),
        Op::Slti { rd, rs, imm } => encode::slti(*rd, *rs, *imm),
        Op::Sltiu { rd, rs, imm } => encode::sltiu(*rd, *rs, *imm),
        Op::Srai { rd, rs, shamt } => encode::srai(*rd, *rs, *shamt),
        Op::Div { rd, rs, rs2 } => encode::div(*rd, *rs, *rs2),
        Op::Rem { rd, rs, rs2 } => encode::rem(*rd, *rs, *rs2),
        Op::Remu { rd, rs, rs2 } => encode::remu(*rd, *rs, *rs2),
        Op::Lb { rd, rs, off } => encode::lb(*rd, *rs, *off),
        Op::Lh { rd, rs, off } => encode::lh(*rd, *rs, *off),
        Op::Lhu { rd, rs, off } => encode::lhu(*rd, *rs, *off),
        Op::Lwu { rd, rs, off } => encode::lwu(*rd, *rs, *off),
        Op::Sh { rs2, rs1, off } => encode::sh(*rs2, *rs1, *off),
        Op::FenceI => encode::fence_i(),
        Op::Addw { rd, rs, rs2 } => encode::addw(*rd, *rs, *rs2),
        Op::Subw { rd, rs, rs2 } => encode::subw(*rd, *rs, *rs2),
        Op::Mulw { rd, rs, rs2 } => encode::mulw(*rd, *rs, *rs2),
        Op::Divw { rd, rs, rs2 } => encode::divw(*rd, *rs, *rs2),
        Op::Divuw { rd, rs, rs2 } => encode::divuw(*rd, *rs, *rs2),
        Op::Remw { rd, rs, rs2 } => encode::remw(*rd, *rs, *rs2),
        Op::Remuw { rd, rs, rs2 } => encode::remuw(*rd, *rs, *rs2),
        Op::Sllw { rd, rs, rs2 } => encode::sllw(*rd, *rs, *rs2),
        Op::Srlw { rd, rs, rs2 } => encode::srlw(*rd, *rs, *rs2),
        Op::Sraw { rd, rs, rs2 } => encode::sraw(*rd, *rs, *rs2),
        Op::Addiw { rd, rs, imm } => encode::addiw(*rd, *rs, *imm),
        Op::Slliw { rd, rs, shamt } => encode::slliw(*rd, *rs, *shamt),
        Op::Srliw { rd, rs, shamt } => encode::srliw(*rd, *rs, *shamt),
        Op::Sraiw { rd, rs, shamt } => encode::sraiw(*rd, *rs, *shamt),
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
        Op::FpR {
            funct7,
            rs2,
            rs1,
            funct3,
            rd,
        } => encode::fpr(*funct7, *rs2, *rs1, *funct3, *rd),
        Op::Label(_)
        | Op::Comment(_)
        | Op::Glob(_)
        | Op::Directive(_)
        | Op::La { .. }
        | Op::Li { .. }
        | Op::Dw64 { .. }
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
        Op::Divu { rd, rs1, rs2 } => format!(
            "\tdivu\t{}, {}, {}",
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
            Addr::UiCap => format!("\tla\t{}, __ui_cap", reg_name(*rd)),
            Addr::VioBss => format!("\tla\t{}, __vio", reg_name(*rd)),
            Addr::ScanFb => format!("\tla\t{}, __scan_fb", reg_name(*rd)),
            Addr::JitIn => format!("\tla\t{}, __jit_in", reg_name(*rd)),
            Addr::JitHdr => format!("\tla\t{}, __jit", reg_name(*rd)),
            Addr::JitStk => format!("\tla\t{}, __jit_stk", reg_name(*rd)),
            Addr::JitCode => format!("\tla\t{}, __jit_code", reg_name(*rd)),
            Addr::WasmMem => format!("\tla\t{}, __wasm_mem", reg_name(*rd)),
            Addr::DomT => format!("\tla\t{}, __dom", reg_name(*rd)),
            Addr::DomS => format!("\tla\t{}, __dom_str", reg_name(*rd)),
            Addr::DomId => format!("\tla\t{}, __dom_id", reg_name(*rd)),
            Addr::VirglOut => format!("\tla\t{}, __virgl_out", reg_name(*rd)),
            Addr::EvObj => format!("\tla\t{}, __ev_obj", reg_name(*rd)),
            Addr::Prom => format!("\tla\t{}, __prom", reg_name(*rd)),
            Addr::VirglCmd => format!("\tla\t{}, __virgl_cmd", reg_name(*rd)),
            Addr::VirglReq => format!("\tla\t{}, __virgl_req", reg_name(*rd)),
            Addr::WebPk => format!("\tla\t{}, __web_pk", reg_name(*rd)),
            Addr::WebDl => format!("\tla\t{}, __web_dl", reg_name(*rd)),
            Addr::KGet => format!("\tla\t{}, __kget", reg_name(*rd)),
        },
        Op::Dw64 { addr } => match addr {
            Addr::Label(l) => format!("\t.dword\t{l}"),
            Addr::Abs(a) => format!("\t.dword\t{a:#x}"),
            Addr::Rodata => "\t.dword\tboot_log".into(),
            Addr::StacksEnd | Addr::StackTop => "\t.dword\t__stacks_end".into(),
            Addr::GrPlane => "\t.dword\t__gr_plane".into(),
            Addr::UartLine => "\t.dword\t__uart_line".into(),
            Addr::UiBlob => "\t.dword\t__ui_blob".into(),
            Addr::UiWasm => "\t.dword\t__ui_wasm".into(),
            Addr::WasmData => "\t.dword\t__wasm_data".into(),
            Addr::UiFont => "\t.dword\t__font".into(),
            Addr::UiDom => "\t.dword\t__ui_dom".into(),
            Addr::UiCap => "\t.dword\t__ui_cap".into(),
            Addr::VioBss => "\t.dword\t__vio".into(),
            Addr::ScanFb => "\t.dword\t__scan_fb".into(),
            Addr::JitIn => "\t.dword\t__jit_in".into(),
            Addr::JitHdr => "\t.dword\t__jit".into(),
            Addr::JitStk => "\t.dword\t__jit_stk".into(),
            Addr::JitCode => "\t.dword\t__jit_code".into(),
            Addr::WasmMem => "\t.dword\t__wasm_mem".into(),
            Addr::DomT => "\t.dword\t__dom".into(),
            Addr::DomS => "\t.dword\t__dom_str".into(),
            Addr::DomId => "\t.dword\t__dom_id".into(),
            Addr::VirglOut => "\t.dword\t__virgl_out".into(),
            Addr::EvObj => "\t.dword\t__ev_obj".into(),
            Addr::Prom => "\t.dword\t__prom".into(),
            Addr::VirglCmd => "\t.dword\t__virgl_cmd".into(),
            Addr::VirglReq => "\t.dword\t__virgl_req".into(),
            Addr::WebPk => "\t.dword\t__web_pk".into(),
            Addr::WebDl => "\t.dword\t__web_dl".into(),
            Addr::KGet => "\t.dword\t__kget".into(),
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
        Op::FenceI => "\tfence.i".into(),
        Op::Blt { rs1, rs2, to } => {
            format!("\tblt\t{}, {}, {to}", reg_name(*rs1), reg_name(*rs2))
        }
        Op::Bge { rs1, rs2, to } => {
            format!("\tbge\t{}, {}, {to}", reg_name(*rs1), reg_name(*rs2))
        }
        Op::Bltu { rs1, rs2, to } => {
            format!("\tbltu\t{}, {}, {to}", reg_name(*rs1), reg_name(*rs2))
        }
        Op::Bgeu { rs1, rs2, to } => {
            format!("\tbgeu\t{}, {}, {to}", reg_name(*rs1), reg_name(*rs2))
        }
        Op::And { rd, rs, rs2 } => {
            format!(
                "\tand\t{}, {}, {}",
                reg_name(*rd),
                reg_name(*rs),
                reg_name(*rs2)
            )
        }
        Op::Or { rd, rs, rs2 } => {
            format!(
                "\tor\t{}, {}, {}",
                reg_name(*rd),
                reg_name(*rs),
                reg_name(*rs2)
            )
        }
        Op::Sll { rd, rs, rs2 } => {
            format!(
                "\tsll\t{}, {}, {}",
                reg_name(*rd),
                reg_name(*rs),
                reg_name(*rs2)
            )
        }
        Op::Srl { rd, rs, rs2 } => {
            format!(
                "\tsrl\t{}, {}, {}",
                reg_name(*rd),
                reg_name(*rs),
                reg_name(*rs2)
            )
        }
        Op::Sra { rd, rs, rs2 } => {
            format!(
                "\tsra\t{}, {}, {}",
                reg_name(*rd),
                reg_name(*rs),
                reg_name(*rs2)
            )
        }
        Op::Slt { rd, rs, rs2 } => {
            format!(
                "\tslt\t{}, {}, {}",
                reg_name(*rd),
                reg_name(*rs),
                reg_name(*rs2)
            )
        }
        Op::Slti { rd, rs, imm } => {
            format!("\tslti\t{}, {}, {imm}", reg_name(*rd), reg_name(*rs))
        }
        Op::Sltiu { rd, rs, imm } => {
            format!("\tsltiu\t{}, {}, {imm}", reg_name(*rd), reg_name(*rs))
        }
        Op::Srai { rd, rs, shamt } => {
            format!("\tsrai\t{}, {}, {shamt}", reg_name(*rd), reg_name(*rs))
        }
        Op::Div { rd, rs, rs2 } => {
            format!(
                "\tdiv\t{}, {}, {}",
                reg_name(*rd),
                reg_name(*rs),
                reg_name(*rs2)
            )
        }
        Op::Rem { rd, rs, rs2 } => {
            format!(
                "\trem\t{}, {}, {}",
                reg_name(*rd),
                reg_name(*rs),
                reg_name(*rs2)
            )
        }
        Op::Remu { rd, rs, rs2 } => {
            format!(
                "\tremu\t{}, {}, {}",
                reg_name(*rd),
                reg_name(*rs),
                reg_name(*rs2)
            )
        }
        Op::Lb { rd, rs, off } => {
            format!("\tlb\t{}, {off}({})", reg_name(*rd), reg_name(*rs))
        }
        Op::Lh { rd, rs, off } => {
            format!("\tlh\t{}, {off}({})", reg_name(*rd), reg_name(*rs))
        }
        Op::Lhu { rd, rs, off } => {
            format!("\tlhu\t{}, {off}({})", reg_name(*rd), reg_name(*rs))
        }
        Op::Lwu { rd, rs, off } => {
            format!("\tlwu\t{}, {off}({})", reg_name(*rd), reg_name(*rs))
        }
        Op::Sh { rs2, rs1, off } => {
            format!("\tsh\t{}, {off}({})", reg_name(*rs2), reg_name(*rs1))
        }
        Op::Addw { rd, rs, rs2 } => {
            format!(
                "\taddw\t{}, {}, {}",
                reg_name(*rd),
                reg_name(*rs),
                reg_name(*rs2)
            )
        }
        Op::Subw { rd, rs, rs2 } => {
            format!(
                "\tsubw\t{}, {}, {}",
                reg_name(*rd),
                reg_name(*rs),
                reg_name(*rs2)
            )
        }
        Op::Mulw { rd, rs, rs2 } => {
            format!(
                "\tmulw\t{}, {}, {}",
                reg_name(*rd),
                reg_name(*rs),
                reg_name(*rs2)
            )
        }
        Op::Divw { rd, rs, rs2 } => {
            format!(
                "\tdivw\t{}, {}, {}",
                reg_name(*rd),
                reg_name(*rs),
                reg_name(*rs2)
            )
        }
        Op::Divuw { rd, rs, rs2 } => {
            format!(
                "\tdivuw\t{}, {}, {}",
                reg_name(*rd),
                reg_name(*rs),
                reg_name(*rs2)
            )
        }
        Op::Remw { rd, rs, rs2 } => {
            format!(
                "\tremw\t{}, {}, {}",
                reg_name(*rd),
                reg_name(*rs),
                reg_name(*rs2)
            )
        }
        Op::Remuw { rd, rs, rs2 } => {
            format!(
                "\tremuw\t{}, {}, {}",
                reg_name(*rd),
                reg_name(*rs),
                reg_name(*rs2)
            )
        }
        Op::Sllw { rd, rs, rs2 } => {
            format!(
                "\tsllw\t{}, {}, {}",
                reg_name(*rd),
                reg_name(*rs),
                reg_name(*rs2)
            )
        }
        Op::Srlw { rd, rs, rs2 } => {
            format!(
                "\tsrlw\t{}, {}, {}",
                reg_name(*rd),
                reg_name(*rs),
                reg_name(*rs2)
            )
        }
        Op::Sraw { rd, rs, rs2 } => {
            format!(
                "\tsraw\t{}, {}, {}",
                reg_name(*rd),
                reg_name(*rs),
                reg_name(*rs2)
            )
        }
        Op::Addiw { rd, rs, imm } => {
            format!("\taddiw\t{}, {}, {imm}", reg_name(*rd), reg_name(*rs))
        }
        Op::Slliw { rd, rs, shamt } => {
            format!("\tslliw\t{}, {}, {shamt}", reg_name(*rd), reg_name(*rs))
        }
        Op::Srliw { rd, rs, shamt } => {
            format!("\tsrliw\t{}, {}, {shamt}", reg_name(*rd), reg_name(*rs))
        }
        Op::Sraiw { rd, rs, shamt } => {
            format!("\tsraiw\t{}, {}, {shamt}", reg_name(*rd), reg_name(*rs))
        }
        Op::FpR {
            funct7,
            rs2,
            rs1,
            funct3,
            rd,
        } => format!("\tfp\tf{rd} <- f{rs1} f{rs2} f7={funct7:#x} f3={funct3}"),
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
