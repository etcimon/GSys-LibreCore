// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! BoardSpec — the only customisation surface for `g6lc_bios`.
//!
//! No crate here reads the SoC RTL tree. A host may *emit* JSON that this
//! parser consumes.

#![allow(missing_docs)]

mod json;
pub mod menu;
mod profile;

pub use json::{parse_json, quote_json, stringify_json, Json};
pub use menu::{Menu, MenuItem, SettingKind, Writable, WRITABLE};
pub use profile::BiosProfile;

/// How an ISA extension is present in the spec.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExtStatus {
    /// Generator may emit the corresponding instructions.
    Live,
    /// Must not emit (stub in the design).
    Stub,
    /// Must not emit.
    Absent,
}

impl ExtStatus {
    fn parse(s: &str) -> Self {
        match s {
            "live" => ExtStatus::Live,
            "stub" => ExtStatus::Stub,
            _ => ExtStatus::Absent,
        }
    }
}

/// ISA slice of a BoardSpec.
#[derive(Debug, Clone)]
pub struct Isa {
    pub xlen: u32,
    pub march: String,
    pub mmu: String,
    pub v: ExtStatus,
    pub c: ExtStatus,
    pub zba: ExtStatus,
    pub zbb: ExtStatus,
    pub zicboz: ExtStatus,
    pub zacas: ExtStatus,
    pub f: ExtStatus,
    pub d: ExtStatus,
    /// Privileged hypervisor extension (H). BIOS stays S-mode; H is next-stage KVM.
    pub h: ExtStatus,
}

impl Default for Isa {
    fn default() -> Self {
        Self {
            xlen: 64,
            march: "rv64imac".into(),
            mmu: "sv39".into(),
            v: ExtStatus::Absent,
            c: ExtStatus::Live,
            zba: ExtStatus::Absent,
            zbb: ExtStatus::Absent,
            zicboz: ExtStatus::Absent,
            zacas: ExtStatus::Absent,
            f: ExtStatus::Absent,
            d: ExtStatus::Absent,
            h: ExtStatus::Absent,
        }
    }
}

/// Pipeline geometry pulled from the RTL config package (NrIssuePorts, OoO, stream).
#[derive(Debug, Clone, Default)]
pub struct CoreGeo {
    /// 0 = unset (inferred to 1). SMT2 dual-issue is 2.
    pub issue_ports: u32,
    pub ooo: bool,
    /// Stream plane (independent issue pipes) vs SMT-shared pipeline.
    pub stream: bool,
}

/// Uncore / standard interfaces advertised in BIOS setup (not a Linux driver).
#[derive(Debug, Clone, Default)]
pub struct Uncore {
    pub clint: bool,
    pub plic: bool,
    pub ddr: bool,
    pub pcie: bool,
    pub ethernet: bool,
    pub storage: bool,
    pub hdmi: bool,
}

/// Graphics / framebuffer request.
#[derive(Debug, Clone)]
pub struct Gr {
    pub enable: bool,
    pub w: u32,
    pub h: u32,
    pub colors: u32,
    pub backend: String,
}

impl Default for Gr {
    fn default() -> Self {
        Self {
            enable: false,
            w: 640,
            h: 480,
            colors: 16,
            backend: "uart".into(),
        }
    }
}

/// Low-res ZealOS plane → high-res HDMI/DP / host-GL scanout.
#[derive(Debug, Clone)]
pub struct DisplayProxy {
    pub enable: bool,
    pub link: String,
    pub dpi: u32,
    /// 0 = auto from `detected_hz`; else 30, 60, or 120.
    pub fps: u32,
    pub detected_hz: u32,
    pub high_w: u32,
    pub high_h: u32,
    pub gl: bool,
    /// `fit` (letterbox), `fill` (stretch to high-res), or `dpi` (dpi/96, capped by fit).
    pub scale_mode: String,
    /// Optional GL/scale accel: `off` | `auto` | `rvv` | `ai-island`.
    pub accel: String,
    /// Forced scanout surface: `vga` | `gpu`. Empty = follow the active
    /// output's class (`BoardSpec::default_surface`).
    pub surface: String,
}

impl Default for DisplayProxy {
    fn default() -> Self {
        Self {
            enable: false,
            link: "uart".into(),
            dpi: 96,
            fps: 0,
            detected_hz: 0,
            high_w: 1920,
            high_h: 1080,
            gl: false,
            scale_mode: "fit".into(),
            accel: "off".into(),
            surface: String::new(),
        }
    }
}

/// A display *output* the BIOS may scan out to, in priority order.
///
/// The ladder is over **validated linear framebuffers**, never over vendors:
/// a PCIe display controller outranks the others only when it actually yields
/// a usable pre-initialized framebuffer. See `architecture/DISPLAY.md`
/// "Display outputs and surface selection".
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum OutputClass {
    /// No accelerated output — the low-res Gr plane over UART only.
    None,
    /// virtio-gpu over virtio-mmio (the QEMU-virt transport).
    VirtioGpu,
    /// Declared uncore scanout engine behind an HDMI/DP PHY
    /// (`architecture/uncore/hdmi-display.md`).
    UncoreScanout,
    /// PCIe display controller exposing a pre-initialized linear framebuffer.
    /// **Not** a modesetting driver: AMD AtomBIOS/DCN and NVIDIA GSP devinit
    /// are vendor firmware this package does not carry, so an uninitialized
    /// part is demoted rather than driven.
    PcieLinearFb,
}

impl OutputClass {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::VirtioGpu => "virtio-gpu",
            Self::UncoreScanout => "uncore-scanout",
            Self::PcieLinearFb => "pcie-linear-fb",
        }
    }

    /// Priority rung; higher wins when the output yields a validated
    /// framebuffer. Matches the `DispSel` runtime ladder.
    pub fn priority(self) -> u32 {
        match self {
            Self::None => 0,
            Self::VirtioGpu => 1,
            Self::UncoreScanout => 2,
            Self::PcieLinearFb => 3,
        }
    }

    pub fn code(self) -> u32 {
        self.priority()
    }

    /// True when this class is GPU-grade — i.e. the default surface is the
    /// native-resolution one, not the upscaled low-res plane.
    pub fn is_accelerated(self) -> bool {
        !matches!(self, Self::None)
    }
}

/// Which UI surface feeds the scanout.
///
/// This is the split the display-proxy toggle flips. The default follows the
/// active [`OutputClass`]: an accelerated output gets [`Surface::Gpu`], so the
/// low-res plane is **never** upscaled onto a GPU-class output unless the user
/// asks for it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Surface {
    /// The 4bpp `__gr_plane` (ZealOS Gr intent, 8x8 font, UART cells),
    /// scaled and letterboxed by the display-proxy.
    Vga,
    /// Native-resolution rendering at the output's own geometry, no upscale.
    Gpu,
}

impl Surface {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Vga => "vga",
            Self::Gpu => "gpu",
        }
    }

    pub fn code(self) -> u32 {
        match self {
            Self::Vga => 0,
            Self::Gpu => 1,
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "vga" => Some(Self::Vga),
            "gpu" => Some(Self::Gpu),
            _ => None,
        }
    }

    pub fn toggled(self) -> Self {
        match self {
            Self::Vga => Self::Gpu,
            Self::Gpu => Self::Vga,
        }
    }
}

/// One candidate scanout output with its geometry and default surface.
///
/// Geometry here is what BoardSpec *declares*; the runtime `DispSel` mux is
/// what decides which candidate is live, because presence (a virtio DeviceID,
/// a `G6DS` magic, an HPD bit, a PCIe class code) is only knowable at boot.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DisplayOutput {
    pub class: OutputClass,
    /// Stable id for menus, diagnostics and the `/bios/display` endpoint.
    pub id: String,
    /// Register-window or ECAM base when the class has one.
    pub base: Option<u64>,
    pub w: u32,
    pub h: u32,
    /// Default surface for this output.
    pub surface: Surface,
    /// Why this output exists / what still gates it. Never a capability claim.
    pub why: String,
}

impl DisplayOutput {
    pub fn stride(&self) -> u32 {
        self.w.saturating_mul(4)
    }

    /// Bytes a full X8R8G8B8 surface needs at this geometry.
    pub fn fb_bytes(&self) -> u64 {
        u64::from(self.w)
            .saturating_mul(u64::from(self.h))
            .saturating_mul(4)
    }
}

/// PCIe host-bridge windows the BIOS may enumerate. Read-only: this package
/// never *assigns* a BAR, it only accepts one firmware already programmed.
#[derive(Debug, Clone, Default)]
pub struct Pcie {
    /// ECAM config-space base (QEMU virt: `0x30000000`).
    pub ecam: String,
    /// 32-bit MMIO window base (QEMU virt: `0x40000000`).
    pub mmio: String,
    pub mmio_len: String,
    /// Scan the config space for a class-0x03 display controller.
    pub scan_display: bool,
}

/// Resolved display-proxy scale/GL accelerator (optional build).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProxyAccel {
    /// Scalar nearest-neighbour (default; every profile).
    Off,
    /// RVV `vle8`/`vse8` scale blit when `isa.v` is live and xlen=64.
    Rvv,
    /// Tile offload toward the AI island (GEMM MMIO stays at `0x40000000`; not the GR plane).
    AiIsland,
}

impl ProxyAccel {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::Rvv => "rvv",
            Self::AiIsland => "ai-island",
        }
    }

    pub fn code(self) -> u32 {
        match self {
            Self::Off => 0,
            Self::Rvv => 1,
            Self::AiIsland => 2,
        }
    }
}

impl DisplayProxy {
    /// 30 / 60 / 100 / 120 / 144 from pin or EDID/DPCD-style detection.
    pub fn refresh_hz(&self) -> u32 {
        match self.fps {
            30 | 60 | 100 | 120 | 144 => self.fps,
            _ => {
                let d = if self.detected_hz == 0 {
                    60
                } else {
                    self.detected_hz
                };
                if d >= 144 {
                    144
                } else if d >= 90 {
                    120
                } else if d >= 45 {
                    60
                } else {
                    30
                }
            }
        }
    }
}

/// Software TLS / HTTPS for the BIOS browser (not OpenSSL).
#[derive(Debug, Clone, Default)]
pub struct Tls {
    pub enable: bool,
    pub https: bool,
    /// TLS 1.2 ServerHello path for HTTPS file serve (not only ClientHello).
    pub serve: bool,
    pub rsa: bool,
    pub ecdsa: bool,
    pub certificates: bool,
}

/// WASM MVP JIT for the BIOS browser (svelte-d `_start`).
#[derive(Debug, Clone, Default)]
pub struct Wasm {
    pub enable: bool,
    pub jit: bool,
    /// Guest JIT substrate (`architecture/WASM.md`): predecoded `__jit_in`
    /// image + `__jit`/`__jit_stk`/`__jit_code`/`__wasm_mem` BSS + the emitted
    /// translator routines. `jit_cell`: "" / "auto" = the shipped UI cell;
    /// "test" = the bounded `g6b_wasm::jcode::test_module` smoke cell.
    pub guest_jit: bool,
    pub jit_cell: String,
}

/// Hardware adapters compiled into the BIOS (`g6b-hw`).
///
/// `virtio_net` arms guest `VioNetProbe` (DeviceID 1) and the host adapter
/// catalog. BIOS `qemu-args` still never emits `-netdev` / `virtio-net`.
#[derive(Debug, Clone, Default)]
pub struct Hw {
    pub enable: bool,
    /// virtio-net DeviceID 1 probe + host adapter. Not a QEMU NIC.
    pub virtio_net: bool,
    /// SoC ethernet MAC (verilog-ethernet / liteeth / …) from HwSpec.
    pub ethernet: bool,
    /// SoC wifi (catalog; off until a vendor id is named).
    pub wifi: bool,
}

/// Compiled HTTP stack for kernel endpoints (not SvelteKit, not Chromium).
#[derive(Debug, Clone)]
pub struct Http {
    pub enable: bool,
    pub http1: bool,
    pub http2: bool,
    /// JS `fetch` / WASM `Object_Call_*` proxy into the kernel router.
    pub proxy_js: bool,
    /// Serve HTTP(S) on the adapter (recovery / BIOS UI), not a Linux netdev.
    pub serve: bool,
    /// Iframe `http(s):` GET. Adapter `HttpsGet` / host `fetch`, never QEMU `-netdev`.
    pub outbound: bool,
    /// HolyC kernel-backed static files (html/js/wasm).
    pub files: HttpFiles,
}

impl Default for Http {
    fn default() -> Self {
        Self {
            enable: false,
            http1: true,
            http2: true,
            proxy_js: true,
            serve: false,
            outbound: false,
            files: HttpFiles::default(),
        }
    }
}

/// Static UI files the kernel HTTP(S) server may emit.
#[derive(Debug, Clone)]
pub struct HttpFiles {
    pub enable: bool,
    pub html: bool,
    pub js: bool,
    pub wasm: bool,
    /// Wrap file bodies in TLS records after ServerHello (`files.https`).
    pub https: bool,
    /// Serve bundled PNG/SVG under `{root}/` for `<img src>` / `fetch("/ui/…")`.
    pub assets: bool,
    /// URL prefix, default `/ui`.
    pub root: String,
}

impl Default for HttpFiles {
    fn default() -> Self {
        Self {
            enable: false,
            html: false,
            js: false,
            wasm: false,
            https: false,
            assets: false,
            root: "/ui".into(),
        }
    }
}

/// BIOS parameter endpoints, each a compile gate.
#[derive(Debug, Clone)]
pub struct BiosParams {
    pub clocks: bool,
    pub edk2: bool,
    pub uboot: bool,
    pub bootloader: bool,
    pub cpu_hz: u32,
    pub uart_baud: u32,
    pub edk2_enable: bool,
    pub uboot_enable: bool,
    /// Next-stage name: `opensbi` (this payload), `edk2`, or `u-boot`.
    pub next: String,
}

impl Default for BiosParams {
    fn default() -> Self {
        Self {
            clocks: false,
            edk2: false,
            uboot: false,
            bootloader: false,
            cpu_hz: 1_000_000_000,
            uart_baud: 115_200,
            edk2_enable: false,
            uboot_enable: false,
            next: "opensbi".into(),
        }
    }
}

/// SPI NOR / mailbox / USB image flash (OpenWrt, BIOS self, Linux).
#[derive(Debug, Clone)]
pub struct Flash {
    pub enable: bool,
    pub openwrt: bool,
    pub self_update: bool,
    /// `spi-nor` | `mailbox` | `usb`
    pub backend: String,
    /// `openwrt` | `bios` | `linux`
    pub image: String,
    /// Default firmware-update location. **HTTPS only** — a firmware image is
    /// never taken over plain HTTP. Empty = USB key / operator-supplied URL.
    pub url: String,
}

impl Default for Flash {
    fn default() -> Self {
        Self {
            enable: false,
            openwrt: false,
            self_update: false,
            backend: "spi-nor".into(),
            image: "bios".into(),
            url: String::new(),
        }
    }
}

/// Export/import BIOS settings with UART, mailbox, and/or USB key.
#[derive(Debug, Clone)]
pub struct Settings {
    pub enable: bool,
    pub export: bool,
    pub import: bool,
    pub uart: bool,
    pub mailbox: bool,
    pub usb_key: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            enable: false,
            export: false,
            import: false,
            uart: true,
            mailbox: true,
            usb_key: false,
        }
    }
}

/// USB host: FAT32 flashing is always on; the key file manager is extra.
#[derive(Debug, Clone)]
pub struct Usb {
    pub enable: bool,
    /// FAT32 MSC stick for firmware images (always compiled when `enable`).
    pub flash_fat32: bool,
    /// Elaborate file manager on a USB key (FAT32/NTFS/ext4/btrfs).
    pub key: bool,
    pub fs_fat32: bool,
    pub fs_ntfs: bool,
    pub fs_ext4: bool,
    pub fs_btrfs: bool,
}

impl Default for Usb {
    fn default() -> Self {
        Self {
            enable: true,
            flash_fat32: true,
            key: false,
            fs_fat32: true,
            fs_ntfs: false,
            fs_ext4: false,
            fs_btrfs: false,
        }
    }
}

/// Kernel / display slice.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Tasking {
    pub enable: bool,
    pub ui_hart: u32,
    pub max_tasks: u32,
    pub max_workers: u32,
    pub stack_bytes: u32,
}

impl Default for Tasking {
    fn default() -> Self {
        Self {
            enable: false,
            ui_hart: 0,
            max_tasks: 128,
            max_workers: 0,
            stack_bytes: 32768,
        }
    }
}

impl Tasking {
    fn parse(value: &Json) -> Result<Self, String> {
        let mut config = Self::default();
        if matches!(value, Json::Null) {
            return Ok(config);
        }
        let Json::Obj(fields) = value else {
            return Err("kernel.tasking must be an object".into());
        };
        for (name, value) in fields {
            match name.as_str() {
                "enable" => {
                    config.enable = value.as_bool().ok_or("tasking.enable must be boolean")?
                }
                "ui_hart" | "max_tasks" | "max_workers" | "stack_bytes" => {
                    let number = value
                        .as_u32()
                        .ok_or_else(|| format!("tasking.{name} must be u32"))?;
                    match name.as_str() {
                        "ui_hart" => config.ui_hart = number,
                        "max_tasks" => config.max_tasks = number,
                        "max_workers" => config.max_workers = number,
                        _ => config.stack_bytes = number,
                    }
                }
                _ => return Err(format!("unknown tasking setting {name}")),
            }
        }
        Ok(config)
    }
}

/// BIOS structured store (`g6b-pglite`). Default **on**; overlay `enable: false`
/// to compile it out. Identity is UUID; `purposes` is the BIOS-UI allow-list.
/// See `architecture/g6b-pglite.md` and `architecture/g6b-store-instances.md`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoreCfg {
    pub enable: bool,
    pub persist_memory: bool,
    pub persist_elf: bool,
    pub persist_usb: bool,
    /// Live USB key volume (`fat32` / `ntfs` / `ext4` / `btrfs`). Empty = snapshot export only.
    pub usb_volume: String,
    pub pglite_files: bool,
    pub pglite_js: bool,
    pub pglite_embed: bool,
    pub max_stores: u32,
    pub max_tables: u32,
    pub max_columns: u32,
    pub max_rows: u32,
    pub max_sql_bytes: u32,
    pub max_param_bytes: u32,
    pub max_result_bytes: u32,
    pub max_tx: u32,
    pub max_open: u32,
    pub max_per_purpose: u32,
    /// Allow-listed purposes. JSON `names` is an alias. Filled with
    /// `["registry"]` when `enable` and empty.
    pub purposes: Vec<String>,
}

impl Default for StoreCfg {
    fn default() -> Self {
        Self {
            enable: true,
            persist_memory: true,
            persist_elf: false,
            persist_usb: false,
            usb_volume: String::new(),
            pglite_files: false,
            pglite_js: false,
            pglite_embed: false,
            max_stores: 4,
            max_tables: 32,
            max_columns: 16,
            max_rows: 4096,
            max_sql_bytes: 64 * 1024,
            max_param_bytes: 16 * 1024,
            max_result_bytes: 256 * 1024,
            max_tx: 1,
            max_open: 4,
            max_per_purpose: 2,
            purposes: vec!["registry".into()],
        }
    }
}

/// Purpose alphabet: `^[a-z][a-z0-9_]{0,31}$`.
pub fn store_purpose_ok(s: &str) -> bool {
    let b = s.as_bytes();
    if b.is_empty() || b.len() > 32 {
        return false;
    }
    b[0].is_ascii_lowercase()
        && b[1..]
            .iter()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == b'_')
}

#[derive(Debug, Clone)]
pub struct Kernel {
    pub shape: String,
    pub gr: Gr,
    pub display: String,
    pub js: String,
    pub start_menu: String,
    pub tasking: Tasking,
    /// `html-js` or `svelte-d`. Never `sveltekit`.
    pub ui: String,
    pub proxy: DisplayProxy,
    pub tls: Tls,
    pub wasm: Wasm,
    pub http: Http,
    pub params: BiosParams,
    pub profile: BiosProfile,
    pub flash: Flash,
    pub settings: Settings,
    pub usb: Usb,
    pub store: StoreCfg,
    /// Host/guest hardware adapters (`g6b-hw`). Not a QEMU `-netdev`.
    pub hw: Hw,
    /// VGA mouse-less ZealOS-shaped CLI (`g6b-zealcli`). Boots before browser-ui.
    pub cli: Cli,
    /// The web stack as **one** bundle: WASM + JS + DOM + DOM rendering + CSS.
    pub web: Web,
}

/// The BIOS web stack. WASM, JS, the DOM object graph, DOM rendering and CSS
/// are **one** compile unit: a build either carries the whole engine or none of
/// it. `check()` refuses splitting the slices (`kernel.wasm` / `kernel.js`
/// without `kernel.web.enable`), because a half-compiled engine has no face and
/// no verification story. Excluding it leaves the kernel, the HolyC band, the
/// hw network adapter and `g6b-zealcli` — the barebone BIOS.
#[derive(Debug, Clone)]
pub struct Web {
    pub enable: bool,
}

impl Default for Web {
    fn default() -> Self {
        Self { enable: true }
    }
}

/// Slice names the [`Web`] bundle carries together (never separately).
pub const WEB_SLICES: &[&str] = &["wasm", "js", "dom", "render", "css"];

/// VGA CLI (`g6b-zealcli`). Does not require `g6b-hw`.
#[derive(Debug, Clone)]
pub struct Cli {
    /// Compile the CLI (default on).
    pub enable: bool,
    /// `cli` always VGA prompt; `ui` no CLI at all (needs `enable: false`);
    /// `auto` CLI first, then browser-ui once a GPU is announced.
    pub boot: String,
    /// Optional pointer (wheel scroll / click focus) from `g6b-hw` HID.
    /// Off by default: the CLI is keyboard-complete.
    pub mouse: bool,
    /// Container rows, prompt included (VGA text is 25).
    pub rows: u32,
    /// Container columns (VGA text is 80).
    pub cols: u32,
    /// Scrollback ring lines held above the viewport.
    pub scrollback: u32,
    /// `man` — the printed manual generated for this board.
    pub manual: bool,
    /// Read-only vi viewer module.
    pub vi: bool,
    /// ZealOS-shaped volume/file exploration (USB key included).
    pub fs: bool,
    /// Firmware update from HTTPS or a USB key.
    pub fw: bool,
    /// `autoboot` — the countdown boot picker.
    pub autoboot: Autoboot,
}

impl Default for Cli {
    fn default() -> Self {
        Self {
            enable: true,
            boot: "auto".into(),
            mouse: false,
            rows: 25,
            cols: 80,
            scrollback: 512,
            manual: true,
            vi: true,
            fs: true,
            fw: true,
            autoboot: Autoboot::default(),
        }
    }
}

/// The countdown boot picker (`autoboot`).
///
/// A boot menu is a *policy* decision, so the policy is compiled in and named:
/// how long to wait, what to try first, and whether the BIOS UI is offered as a
/// last entry. The list itself is discovered — what is actually on the volumes —
/// never assumed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Autoboot {
    /// Compile the picker (default on).
    pub enable: bool,
    /// Milliseconds before the first entry is taken. `0` waits forever, which is
    /// the right choice for a bench board and the wrong one for an appliance.
    pub timeout_ms: u32,
    /// [`BootOrder`] spelling.
    pub order: String,
    /// Offer "BIOS UI" as the last entry when the web stack is compiled.
    pub bios_ui: bool,
}

impl Default for Autoboot {
    fn default() -> Self {
        Self {
            enable: true,
            timeout_ms: 2000,
            order: "live-first".into(),
            bios_ui: true,
        }
    }
}

/// What the picker puts first.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BootOrder {
    /// Recovery / live media first — the order you want when a board is being
    /// repaired, and the reason a live USB exists.
    LiveFirst,
    /// An installed, working OS first; live media stays reachable below it.
    OsFirst,
    /// Stay in this payload: setup first, everything else below.
    PayloadFirst,
}

impl BootOrder {
    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "live-first" | "live" | "recovery" => Self::LiveFirst,
            "os-first" | "os" | "installed" => Self::OsFirst,
            "payload-first" | "payload" | "setup" => Self::PayloadFirst,
            _ => return None,
        })
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::LiveFirst => "live-first",
            Self::OsFirst => "os-first",
            Self::PayloadFirst => "payload-first",
        }
    }
}

/// Accepted `kernel.cli.autoboot.order` values, for `set` and the manual.
pub const BOOT_ORDERS: &[&str] = &["live-first", "os-first", "payload-first"];

impl BoardSpec {
    /// VGA zealcli is the face until GPU is announced (`boot=auto`).
    pub fn wants_zealcli(&self, gpu_ready: bool) -> bool {
        if !self.kernel.cli.enable {
            return false;
        }
        match self.kernel.cli.boot.as_str() {
            "ui" => false,
            "cli" => true,
            _ => !gpu_ready,
        }
    }

    /// True when the whole web engine (wasm+js+dom+render+css) is compiled.
    pub fn web_stack(&self) -> bool {
        self.kernel.web.enable
    }

    /// The compiled boot-order policy.
    pub fn boot_order(&self) -> BootOrder {
        BootOrder::parse(&self.kernel.cli.autoboot.order).unwrap_or(BootOrder::LiveFirst)
    }

    /// True when the picker offers the browser-UI as its last entry: the web
    /// stack has to be compiled for there to be a UI to hand over to.
    pub fn autoboot_offers_bios_ui(&self) -> bool {
        self.kernel.cli.autoboot.bios_ui && self.web_stack()
    }

    /// True when the CLI must reach its prompt before the web engine loads.
    /// Any build that carries the web stack still boots the minimally
    /// dependent zealcli first; `LoadUI` hands over afterwards.
    pub fn cli_before_web(&self) -> bool {
        self.kernel.cli.enable && self.web_stack()
    }
}

impl Default for Kernel {
    fn default() -> Self {
        Self {
            shape: "zeal".into(),
            gr: Gr::default(),
            display: "html-js".into(),
            js: "aot".into(),
            start_menu: "main".into(),
            tasking: Tasking::default(),
            ui: "html-js".into(),
            proxy: DisplayProxy::default(),
            tls: Tls::default(),
            wasm: Wasm::default(),
            http: Http::default(),
            params: BiosParams::default(),
            profile: BiosProfile::Custom,
            flash: Flash::default(),
            settings: Settings::default(),
            usb: Usb::default(),
            store: StoreCfg::default(),
            hw: Hw::default(),
            cli: Cli::default(),
            web: Web::default(),
        }
    }
}

/// Dual-band HolyC transport: UART console plus an SSH-like TCP REPL.
#[derive(Debug, Clone)]
pub struct HolycTcp {
    pub enable: bool,
    pub host_port: u16,
    pub guest_port: u16,
    pub proto: String,
}

impl Default for HolycTcp {
    fn default() -> Self {
        Self {
            enable: true,
            host_port: 2222,
            guest_port: 22,
            proto: "holyc-repl".into(),
        }
    }
}

/// UART + TCP HolyC bands.
#[derive(Debug, Clone)]
pub struct DualBand {
    pub uart: bool,
    pub tcp: HolycTcp,
}

impl Default for DualBand {
    fn default() -> Self {
        Self {
            uart: true,
            tcp: HolycTcp::default(),
        }
    }
}

/// Fast HolyC init and dual-band REPL (generated ZealOS).
#[derive(Debug, Clone)]
pub struct Holyc {
    pub fast_init: bool,
    pub dual_band: DualBand,
}

impl Default for Holyc {
    fn default() -> Self {
        Self {
            fast_init: true,
            dual_band: DualBand::default(),
        }
    }
}

/// How the BIOS stays reachable after Linux is the S-mode payload.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PostbootMode {
    /// BIOS is gone after handoff.
    Never,
    /// Relocate into reserved DRAM; Linux maps it view-only + management port.
    Runtime,
    /// A dedicated hart never leaves the BIOS kernel.
    MgmtHart,
    /// Always-on uncore island (BMC-shaped).
    BmcIsland,
}

impl PostbootMode {
    fn parse(s: &str) -> Self {
        match s {
            "runtime" => Self::Runtime,
            "mgmt-hart" => Self::MgmtHart,
            "bmc-island" => Self::BmcIsland,
            _ => Self::Never,
        }
    }

    /// BoardSpec spelling.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Never => "never",
            Self::Runtime => "runtime",
            Self::MgmtHart => "mgmt-hart",
            Self::BmcIsland => "bmc-island",
        }
    }
}

/// Post-boot BIOS access (server-KVM / IPMI-shaped), parameterized.
#[derive(Debug, Clone)]
pub struct Postboot {
    pub enable: PostbootMode,
    pub access: String,
    pub immutable: Vec<String>,
    pub power: Vec<String>,
    pub reserved_dram: String,
    pub always_on_domain: bool,
    /// KVM faces: `html-js` and/or `ssh-holyc` (ZealOS CLI). Both by default.
    pub backends: Vec<String>,
}

impl Default for Postboot {
    fn default() -> Self {
        Self {
            enable: PostbootMode::Never,
            access: "view".into(),
            immutable: vec!["config".into(), "keys".into(), "boot-policy".into()],
            power: vec!["reboot".into(), "shutdown".into(), "wakeup".into()],
            reserved_dram: "0x100000".into(),
            always_on_domain: false,
            backends: vec!["html-js".into(), "ssh-holyc".into()],
        }
    }
}

/// How long the OS NIC may carry BIOS gateway/web/SSH+HolyC.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NetExposeMode {
    /// Never bind the OS adapter.
    Never,
    /// BIOS may use the adapter until `LinuxHandoff`, then drops it.
    UntilDelegate,
    /// Keep a management MAC forever (bmc-island only).
    Always,
}

impl NetExposeMode {
    fn parse(s: &str) -> Self {
        match s {
            "until-delegate" | "until_delegate" => Self::UntilDelegate,
            "always" => Self::Always,
            _ => Self::Never,
        }
    }

    /// BoardSpec spelling.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Never => "never",
            Self::UntilDelegate => "until-delegate",
            Self::Always => "always",
        }
    }
}

/// Optional adapter expose (gateway/web + SSH+HolyC) before NIC delegate.
#[derive(Debug, Clone)]
pub struct NetExpose {
    pub mode: NetExposeMode,
    pub via: String,
    pub web: bool,
    pub ssh_holyc: bool,
    /// HTTPS for the BIOS browser (pre-delegate adapter).
    pub bios_https_port: u16,
    /// SSH+HolyC KVM face on the adapter (chardev stand-in until OpenSSH).
    pub ssh_holyc_port: u16,
}

impl Default for NetExpose {
    fn default() -> Self {
        Self {
            mode: NetExposeMode::Never,
            via: "adapter".into(),
            web: true,
            ssh_holyc: true,
            bios_https_port: 443,
            ssh_holyc_port: 2222,
        }
    }
}

/// Post-delegate firmware loopback: mailbox + IRQ, never a netdev.
#[derive(Debug, Clone)]
pub struct Loopback {
    pub enable: bool,
    pub transport: String,
    pub compatible: String,
    pub base: String,
    pub len: String,
    pub irq: u32,
    pub chardev: String,
}

impl Default for Loopback {
    fn default() -> Self {
        Self {
            enable: false,
            transport: "mbox".into(),
            compatible: "gsys,g6lc-bios-mbox".into(),
            base: "0x10100000".into(),
            len: "0x1000".into(),
            irq: 3,
            chardev: "/dev/g6lc-bios".into(),
        }
    }
}

/// A named MMIO peripheral.
#[derive(Debug, Clone)]
pub struct Peripheral {
    pub id: String,
    pub class: String,
    pub model: String,
    pub base: String,
}

/// Setup entry policy.
#[derive(Debug, Clone)]
pub struct Entry {
    pub hotkey: String,
    pub timeout_ms: u32,
}

impl Default for Entry {
    fn default() -> Self {
        Self {
            hotkey: "DEL".into(),
            timeout_ms: 2000,
        }
    }
}

/// Connector planes.
#[derive(Debug, Clone, Default)]
pub struct Connectors {
    pub core: Vec<String>,
    pub apu: Vec<String>,
    pub uncore: Vec<String>,
}

/// The BoardSpec document.
#[derive(Debug, Clone)]
pub struct BoardSpec {
    pub schema_version: u32,
    pub product: String,
    pub isa: Isa,
    pub kernel: Kernel,
    pub holyc: Holyc,
    pub postboot: Postboot,
    pub loopback: Loopback,
    pub net_expose: NetExpose,
    pub connectors: Connectors,
    pub peripherals: Vec<Peripheral>,
    pub entry: Entry,
    pub dram_base: String,
    pub dram_len: String,
    pub text_offset: String,
    /// Logical harts (cores × threads).
    pub harts: u32,
    /// Physical cores (`NrCores`). 0 = unset, inferred.
    pub cores: u32,
    /// Hardware threads per core (`NrHarts` in SMT packages). 0 = unset.
    pub threads: u32,
    pub geo: CoreGeo,
    pub uncore: Uncore,
    /// PCIe host-bridge windows for the read-only display-controller scan.
    pub pcie: Pcie,
}

impl Default for BoardSpec {
    fn default() -> Self {
        Self {
            schema_version: 1,
            product: "iot".into(),
            isa: Isa::default(),
            kernel: Kernel::default(),
            holyc: Holyc::default(),
            postboot: Postboot::default(),
            loopback: Loopback::default(),
            net_expose: NetExpose::default(),
            connectors: Connectors::default(),
            peripherals: Vec::new(),
            entry: Entry::default(),
            dram_base: "0x80000000".into(),
            dram_len: "0x40000000".into(),
            text_offset: "0x200000".into(),
            harts: 1,
            cores: 1,
            threads: 1,
            geo: CoreGeo {
                issue_ports: 1,
                ooo: false,
                stream: false,
            },
            uncore: Uncore::default(),
            pcie: Pcie::default(),
        }
    }
}

impl BoardSpec {
    /// Parse a BoardSpec JSON document.
    pub fn from_json_str(s: &str) -> Result<Self, String> {
        let v = parse_json(s)?;
        Self::from_json(&v)
    }

    #[allow(clippy::field_reassign_with_default)]
    fn from_json(v: &Json) -> Result<Self, String> {
        let mut spec = BoardSpec::default();
        spec.cores = 0;
        spec.threads = 0;
        spec.geo.issue_ports = 0;
        spec.schema_version = v.get("schema_version").as_u32().unwrap_or(1);
        let pname = v
            .get("profile")
            .as_str()
            .or_else(|| v.get("kernel").get("profile").as_str());
        if let Some(s) = pname {
            spec.apply_profile(BiosProfile::parse(s)?);
        }
        if let Some(p) = v.get("product").as_str() {
            spec.product = p.to_string();
        }
        if let Json::Obj(_) = v.get("isa") {
            spec.isa = parse_isa(v.get("isa"));
        }
        if let Json::Obj(_) = v.get("kernel") {
            apply_kernel(&mut spec.kernel, v.get("kernel"));
            spec.kernel.tasking = Tasking::parse(v.get("kernel").get("tasking"))?;
        }
        if let Json::Obj(_) = v.get("proxy") {
            apply_proxy(&mut spec.kernel.proxy, v.get("proxy"));
        }
        if let Json::Obj(_) = v.get("tls") {
            apply_tls(&mut spec.kernel.tls, v.get("tls"));
        }
        if let Json::Obj(_) = v.get("wasm") {
            apply_wasm(&mut spec.kernel.wasm, v.get("wasm"));
        }
        if let Json::Obj(_) = v.get("http") {
            apply_http(&mut spec.kernel.http, v.get("http"));
        }
        if let Json::Obj(_) = v.get("params") {
            apply_params(&mut spec.kernel.params, v.get("params"));
        }
        if let Some(s) = v.get("ui").as_str() {
            spec.kernel.ui = s.to_string();
        }
        if let Json::Obj(_) = v.get("connectors") {
            spec.connectors.core = string_list(v.get("connectors").get("core"));
            spec.connectors.apu = string_list(v.get("connectors").get("apu"));
            spec.connectors.uncore = string_list(v.get("connectors").get("uncore"));
        }
        if let Json::Arr(items) = v.get("peripherals") {
            spec.peripherals = items
                .iter()
                .filter_map(|p| {
                    Some(Peripheral {
                        id: p.get("id").as_str()?.to_string(),
                        class: p.get("class").as_str().unwrap_or("").to_string(),
                        model: p.get("model").as_str().unwrap_or("").to_string(),
                        base: p.get("base").as_str().unwrap_or("").to_string(),
                    })
                })
                .collect();
        }
        if let Json::Obj(_) = v.get("entry") {
            if let Some(h) = v.get("entry").get("hotkey").as_str() {
                spec.entry.hotkey = h.to_string();
            }
            if let Some(t) = v.get("entry").get("timeout_ms").as_u32() {
                spec.entry.timeout_ms = t;
            }
        }
        if let Json::Obj(_) = v.get("memory") {
            if let Some(b) = v.get("memory").get("dram_base").as_str() {
                spec.dram_base = b.to_string();
            }
            if let Some(l) = v.get("memory").get("dram_len").as_str() {
                spec.dram_len = l.to_string();
            }
            if let Some(t) = v.get("memory").get("text_offset").as_str() {
                spec.text_offset = t.to_string();
            }
        }
        if let Json::Obj(_) = v.get("harts") {
            let h = v.get("harts");
            if let Some(n) = h.get("count").as_u32() {
                spec.harts = n;
            }
            if let Some(n) = h.get("cores").as_u32() {
                spec.cores = n;
            }
            if let Some(n) = h.get("threads").as_u32() {
                spec.threads = n;
            }
        }
        if let Json::Obj(_) = v.get("core") {
            apply_geo(&mut spec.geo, v.get("core"));
        }
        if let Json::Obj(_) = v.get("uncore") {
            apply_uncore(&mut spec.uncore, v.get("uncore"));
        }
        if let Json::Obj(_) = v.get("pcie") {
            apply_pcie(&mut spec.pcie, v.get("pcie"));
        }
        spec.infer_geo()?;
        spec.infer_uncore();
        if let Json::Obj(_) = v.get("holyc") {
            spec.holyc = parse_holyc(v.get("holyc"));
        } else if let Json::Obj(_) = v.get("kernel").get("holyc") {
            spec.holyc = parse_holyc(v.get("kernel").get("holyc"));
        }
        if let Json::Obj(_) = v.get("postboot") {
            spec.postboot = parse_postboot(v.get("postboot"));
        } else if let Json::Obj(_) = v.get("kernel").get("postboot") {
            spec.postboot = parse_postboot(v.get("kernel").get("postboot"));
        }
        let loopback_present = matches!(v.get("loopback"), Json::Obj(_));
        if loopback_present {
            spec.loopback = parse_loopback(v.get("loopback"));
        } else if spec.postboot.enable != PostbootMode::Never {
            spec.loopback.enable = true;
        }
        let net_present = matches!(v.get("net_expose"), Json::Obj(_));
        if net_present {
            spec.net_expose = parse_net_expose(v.get("net_expose"));
        } else if spec.postboot.access == "kvm" && spec.postboot.enable != PostbootMode::Never {
            spec.net_expose.mode = NetExposeMode::UntilDelegate;
        }
        spec.check()?;
        Ok(spec)
    }

    /// Legality: XLEN, RVV, GPIO vs AI island, post-boot architecture.
    pub fn worker_limit(&self) -> u32 {
        if !self.kernel.tasking.enable {
            return 0;
        }
        let available = self.harts.saturating_sub(1).max(1);
        let requested = if self.kernel.tasking.max_workers == 0 {
            available
        } else {
            self.kernel.tasking.max_workers
        };
        requested
            .min(available)
            .min(self.kernel.tasking.max_tasks.saturating_sub(2))
    }

    pub fn check(&self) -> Result<(), String> {
        if self.isa.xlen != 32 && self.isa.xlen != 64 {
            return Err(format!("isa.xlen must be 32 or 64, got {}", self.isa.xlen));
        }
        if self.isa.v == ExtStatus::Live && self.isa.xlen != 64 {
            return Err("extensions.v=live is illegal on xlen=32".into());
        }
        if self.isa.h == ExtStatus::Live && self.isa.xlen != 64 {
            return Err("extensions.h=live is illegal on xlen=32".into());
        }
        if self.cores == 0 || self.threads == 0 {
            return Err("cores and threads must be inferred or set (>= 1)".into());
        }
        if self.cores.saturating_mul(self.threads) != self.harts {
            return Err(format!(
                "harts.count {} must equal cores {} × threads {}",
                self.harts, self.cores, self.threads
            ));
        }
        if self.geo.issue_ports == 0 {
            return Err("core.issue_ports must be inferred or set (>= 1)".into());
        }
        let ai = self.peripherals.iter().any(|p| p.class == "ai-island");
        let gpio_clash = self.peripherals.iter().any(|p| {
            p.class == "gpio"
                && (p.base.eq_ignore_ascii_case("0x40000000") || p.base == "0x4000_0000")
        });
        if ai && gpio_clash {
            return Err(
                "gpio strap must not sit at 0x40000000 when an ai-island peripheral is live".into(),
            );
        }
        self.check_display()?;
        if self.postboot.enable == PostbootMode::MgmtHart && self.harts < 2 {
            return Err("postboot.enable=mgmt-hart needs harts.count >= 2".into());
        }
        if self.postboot.access == "kvm"
            && !self.loopback.enable
            && !self.holyc.dual_band.tcp.enable
        {
            return Err(
                "postboot.access=kvm needs loopback.mbox or dual_band.tcp (pre-delegate SSH+HolyC)"
                    .into(),
            );
        }
        if self.net_expose.mode == NetExposeMode::Always
            && self.postboot.enable != PostbootMode::BmcIsland
        {
            return Err(
                "net_expose.mode=always keeps a MAC after Linux; only legal with postboot.enable=bmc-island"
                    .into(),
            );
        }
        if self.kernel.gr.enable {
            match self.kernel.gr.backend.as_str() {
                "uart" | "virtio-gpu" | "hdmi" | "displayport" | "host-gl" => {}
                other => {
                    return Err(format!(
                        "kernel.gr.backend `{other}` refused (VGA ports are not a backend); use uart, virtio-gpu, hdmi, displayport, or host-gl"
                    ));
                }
            }
        }
        if self.kernel.proxy.enable {
            match self.kernel.proxy.link.as_str() {
                "uart" | "virtio-gpu" | "hdmi" | "displayport" | "host-gl" => {}
                other => {
                    return Err(format!(
                        "kernel.proxy.link `{other}` refused; use uart, virtio-gpu, hdmi, displayport, or host-gl"
                    ));
                }
            }
            if !matches!(self.kernel.proxy.fps, 0 | 30 | 60 | 100 | 120 | 144) {
                return Err("kernel.proxy.fps must be 0 (auto), 30, 60, 100, 120, or 144".into());
            }
            if !(72..=384).contains(&self.kernel.proxy.dpi) {
                return Err("kernel.proxy.dpi must be 72..=384".into());
            }
            match self.kernel.proxy.scale_mode.as_str() {
                "fit" | "fill" | "dpi" | "" => {}
                other => {
                    return Err(format!(
                        "kernel.proxy.scale_mode `{other}` refused; use fit, fill, or dpi"
                    ));
                }
            }
            if self.kernel.proxy.high_w < 640 || self.kernel.proxy.high_w > 7680 {
                return Err("kernel.proxy.high_w must be 640..=7680".into());
            }
            if self.kernel.proxy.high_h < 480 || self.kernel.proxy.high_h > 4320 {
                return Err("kernel.proxy.high_h must be 480..=4320".into());
            }
            match self.kernel.proxy.accel.as_str() {
                "" | "off" | "auto" => {}
                "rvv" => {
                    if !self.rvv_live() {
                        return Err("kernel.proxy.accel=rvv needs isa.v live and xlen=64".into());
                    }
                }
                "ai-island" => {
                    if !self.has_ai_island() {
                        return Err(
                            "kernel.proxy.accel=ai-island needs a peripheral class=ai-island"
                                .into(),
                        );
                    }
                }
                other => {
                    return Err(format!(
                        "kernel.proxy.accel `{other}` refused; use off, auto, rvv, or ai-island"
                    ));
                }
            }
        }
        if self.loopback.enable {
            if self.loopback.transport != "mbox" {
                return Err(format!(
                    "loopback.transport must be mbox (not a netdev), got {}",
                    self.loopback.transport
                ));
            }
            if let Some(base) = parse_hex(&self.loopback.base) {
                const FORBIDDEN: &[u64] = &[
                    0x0200_0000, // clint
                    0x0c00_0000, // plic
                    0x1000_0000, // uart0
                    0x1800_0000, // apb timer
                    0x2000_0000, // spi
                    0x4000_0000, // ai-island
                ];
                if FORBIDDEN.contains(&base) {
                    return Err(format!(
                        "loopback.base {} collides with a core/APU device",
                        self.loopback.base
                    ));
                }
                for p in &self.peripherals {
                    if parse_hex(&p.base) == Some(base) {
                        return Err(format!(
                            "loopback.base {} collides with peripheral {}",
                            self.loopback.base, p.id
                        ));
                    }
                }
            }
            if self.loopback.irq == 1 {
                return Err("loopback.irq 1 is the UART; pick a dedicated PLIC line".into());
            }
        }
        for b in &self.postboot.backends {
            if b != "html-js" && b != "ssh-holyc" {
                return Err(format!("unknown postboot.backend `{b}`"));
            }
        }
        if self.postboot.enable != PostbootMode::Never
            && self.postboot.power.iter().any(|p| p == "wakeup")
            && !self.postboot.always_on_domain
            && self.postboot.enable == PostbootMode::Runtime
        {
            return Err(
                "postboot power wakeup with enable=runtime needs always_on_domain, mgmt-hart, or bmc-island"
                    .into(),
            );
        }
        if self.kernel.ui == "sveltekit" || self.kernel.ui.contains("svelte-kit") {
            return Err(
                "kernel.ui sveltekit refused; BIOS UI is svelte-d NodeDef (no kit load/hooks)"
                    .into(),
            );
        }
        if !matches!(self.kernel.ui.as_str(), "html-js" | "svelte-d" | "cli") {
            return Err(format!(
                "kernel.ui `{}` refused; use html-js, svelte-d, or cli (not sveltekit)",
                self.kernel.ui
            ));
        }
        if !matches!(self.kernel.js.as_str(), "aot" | "off" | "none") {
            return Err("kernel.browser.js must be aot or off (none is an alias)".into());
        }
        self.check_web()?;
        if self.menu(&self.kernel.start_menu).is_none() {
            return Err(format!(
                "unknown kernel.browser.start_menu `{}`",
                self.kernel.start_menu
            ));
        }
        let root = self.kernel.http.files.root.as_str();
        if !root.starts_with('/')
            || root.starts_with("//")
            || root.contains(['?', '#', '\\'])
            || root.chars().any(|c| c.is_control() || c.is_whitespace())
            || root.split('/').any(|s| matches!(s, "." | ".."))
            || root
                .chars()
                .any(|c| !c.is_ascii_alphanumeric() && !matches!(c, '/' | '-' | '_' | '.'))
        {
            return Err(
                "kernel.http.files.root must be a local absolute path without traversal".into(),
            );
        }
        let tasking = &self.kernel.tasking;
        if tasking.ui_hart >= self.harts
            || tasking.ui_hart >= 64
            || !(3..=256).contains(&tasking.max_tasks)
            || tasking.max_workers > tasking.max_tasks - 2
            || !(4096..=1048576).contains(&tasking.stack_bytes)
            || tasking.stack_bytes % 16 != 0
            || (tasking.enable && self.harts > 64)
        {
            return Err(
                "invalid kernel.tasking: UI hart, task/worker limit, or aligned stack budget"
                    .into(),
            );
        }
        if self.kernel.wasm.jit && !self.kernel.wasm.enable {
            return Err("kernel.wasm.jit needs kernel.wasm.enable".into());
        }
        if self.kernel.wasm.guest_jit {
            if !self.kernel.wasm.jit {
                return Err("kernel.wasm.guest_jit needs kernel.wasm.jit".into());
            }
            if self.isa.xlen != 64 {
                // The guest JIT emits RV64 word ops (addw/lwu/…) for wasm i32.
                return Err("kernel.wasm.guest_jit needs isa.xlen=64".into());
            }
            match self.kernel.wasm.jit_cell.as_str() {
                "" | "auto" | "test" | "delegate" | "delegate-click" => {}
                c => return Err(format!("kernel.wasm.jit_cell {c:?} unknown")),
            }
        } else if !self.kernel.wasm.jit_cell.is_empty() {
            return Err("kernel.wasm.jit_cell needs kernel.wasm.guest_jit".into());
        }
        if self.kernel.http.serve && !self.kernel.http.enable {
            return Err("kernel.http.serve needs kernel.http.enable".into());
        }
        if self.kernel.http.outbound && !self.kernel.http.enable {
            return Err("kernel.http.outbound needs kernel.http.enable".into());
        }
        if (self.kernel.hw.virtio_net || self.kernel.hw.ethernet || self.kernel.hw.wifi)
            && !self.kernel.hw.enable
        {
            return Err("kernel.hw.virtio_net/ethernet/wifi need kernel.hw.enable".into());
        }
        self.check_cli()?;
        if self.kernel.http.files.enable && !self.kernel.http.enable {
            return Err("kernel.http.files needs kernel.http.enable".into());
        }
        if self.kernel.http.files.enable && !self.kernel.http.serve {
            return Err("kernel.http.files needs kernel.http.serve (adapter or mailbox)".into());
        }
        if self.kernel.http.files.wasm && !self.kernel.wasm.enable {
            return Err("kernel.http.files.wasm needs kernel.wasm.enable".into());
        }
        if self.kernel.http.files.https && !self.kernel.tls.https {
            return Err("kernel.http.files.https needs kernel.tls.https".into());
        }
        if self.kernel.tls.serve && !self.kernel.tls.enable {
            return Err("kernel.tls.serve needs kernel.tls.enable".into());
        }
        if self.kernel.http.files.assets && !self.kernel.http.files.enable {
            return Err("kernel.http.files.assets needs kernel.http.files.enable".into());
        }
        if self.kernel.http.files.enable
            && !self.kernel.http.files.html
            && !self.kernel.http.files.js
            && !self.kernel.http.files.wasm
            && !self.kernel.http.files.assets
        {
            return Err("kernel.http.files.enable needs html, js, wasm, or assets".into());
        }
        if self.kernel.settings.usb_key && !self.kernel.usb.enable {
            return Err("settings.usb_key needs kernel.usb.enable".into());
        }
        if self.kernel.usb.key && !self.kernel.usb.enable {
            return Err("kernel.usb.key file manager needs kernel.usb.enable".into());
        }
        if self.kernel.usb.enable && !self.kernel.usb.flash_fat32 && !self.kernel.usb.key {
            return Err(
                "kernel.usb.enable needs flash_fat32 (always-on FAT32 flash) or key".into(),
            );
        }
        self.check_store()?;
        if self.kernel.flash.enable {
            match self.kernel.flash.backend.as_str() {
                "spi-nor" | "mailbox" | "usb" => {}
                other => {
                    return Err(format!(
                        "kernel.flash.backend `{other}` refused; use spi-nor, mailbox, or usb"
                    ));
                }
            }
            if self.kernel.flash.backend == "usb" && !self.kernel.usb.enable {
                return Err("flash.backend=usb needs kernel.usb.enable".into());
            }
        }
        Ok(())
    }

    fn check_store(&self) -> Result<(), String> {
        let s = &self.kernel.store;
        let range = |n: u32, lo: u32, hi: u32, name: &str| {
            if n < lo || n > hi {
                Err(format!("kernel.store.{name} must be {lo}..={hi}, got {n}"))
            } else {
                Ok(())
            }
        };
        range(s.max_stores, 1, 16, "max_stores")?;
        range(s.max_per_purpose, 1, 8, "max_per_purpose")?;
        range(s.max_tables, 1, 64, "max_tables")?;
        range(s.max_columns, 1, 32, "max_columns")?;
        range(s.max_rows, 1, 16384, "max_rows")?;
        range(s.max_sql_bytes, 1, 256 * 1024, "max_sql_bytes")?;
        range(s.max_param_bytes, 1, 64 * 1024, "max_param_bytes")?;
        range(s.max_result_bytes, 1, 1024 * 1024, "max_result_bytes")?;
        if s.max_tx != 1 {
            return Err("kernel.store.max_tx must be 1".into());
        }
        range(s.max_open, 1, 8, "max_open")?;
        if s.pglite_files
            && !(s.enable && self.kernel.http.files.enable && self.kernel.http.files.wasm)
        {
            return Err(
                "kernel.store.pglite.files needs store.enable, kernel.http.files, and files.wasm"
                    .into(),
            );
        }
        if s.pglite_js && !(s.pglite_files && self.kernel.http.files.js) {
            return Err(
                "kernel.store.pglite.js needs pglite.files and kernel.http.files.js".into(),
            );
        }
        if s.pglite_embed && !s.enable {
            return Err("kernel.store.pglite.embed needs store.enable".into());
        }
        if s.persist_usb && !(s.enable && self.kernel.usb.key) {
            return Err("kernel.store.persist.usb needs store.enable and kernel.usb.key".into());
        }
        if !s.usb_volume.is_empty() {
            if !s.persist_usb {
                return Err("kernel.store.persist.volume needs persist.usb".into());
            }
            if !matches!(s.usb_volume.as_str(), "fat32" | "ntfs" | "ext4" | "btrfs") {
                return Err(
                    "kernel.store.persist.volume must be fat32, ntfs, ext4, or btrfs".into(),
                );
            }
        }
        if s.persist_elf && !s.enable {
            return Err("kernel.store.persist.elf needs store.enable".into());
        }
        if s.enable {
            if s.purposes.is_empty() || s.purposes.len() as u32 > s.max_stores {
                return Err(
                    "kernel.store.purposes must have 1..=max_stores entries when enable".into(),
                );
            }
            for p in &s.purposes {
                if !store_purpose_ok(p) {
                    return Err(format!("kernel.store.purpose `{p}` refused"));
                }
            }
        }
        Ok(())
    }

    /// True when the generator may emit RVV encodings.
    pub fn rvv_live(&self) -> bool {
        self.isa.v == ExtStatus::Live && self.isa.xlen == 64
    }

    /// True when an `ai-island` peripheral is in the BoardSpec (MMIO `0x40000000`).
    pub fn has_ai_island(&self) -> bool {
        self.peripherals.iter().any(|p| p.class == "ai-island")
    }

    /// Native scanout engine (uncore display port) when a `display`-class
    /// peripheral is declared — the MMIO contract of
    /// `architecture/uncore/hdmi-display.md` (TMDS/PHY bring-up is SoC
    /// vendor IP; the BIOS programs FB_BASE/W/H/STRIDE/COMMIT). Returns the
    /// register-window base.
    pub fn display_ctrl(&self) -> Option<u64> {
        self.peripherals
            .iter()
            .find(|p| p.class == "display")
            .and_then(|p| parse_hex(&p.base))
    }

    /// True when the guest should drive the declared native display engine —
    /// a `display` peripheral plus a graphics plane or display proxy. The
    /// scanout surface is the same scaled X8R8G8B8 `__scan_fb` the
    /// virtio-gpu path uses, so the blit is backend-agnostic; the descriptor
    /// is also the `simple-framebuffer`-shaped handoff a Linux `simplefb`/
    /// `simpledrm` node consumes (works for the BIOS and Linux).
    pub fn wants_disp_scan(&self) -> bool {
        self.display_ctrl().is_some() && (self.kernel.gr.enable || self.kernel.proxy.enable)
    }

    /// Web-stack legality. WASM, JS, DOM, DOM rendering and CSS are one
    /// bundle ([`WEB_SLICES`]): a build carries the engine or it does not.
    /// With the engine excluded the kernel, HolyC band, hw network adapter
    /// and `g6b-zealcli` still stand on their own.
    fn check_web(&self) -> Result<(), String> {
        let js_live = matches!(self.kernel.js.as_str(), "aot");
        if self.kernel.web.enable {
            // The engine never preempts the CLI: a build that carries both
            // reaches the zealcli prompt first and hands over on `LoadUI`.
            if self.kernel.cli.enable && self.kernel.cli.boot == "ui" {
                return Err(
                    "kernel.cli.boot=ui refused while the web stack is compiled: zealcli boots \
                     first (use auto, or cli.enable=false to drop the CLI entirely)"
                        .into(),
                );
            }
            if self.kernel.ui == "cli" {
                return Err(
                    "kernel.ui=cli needs kernel.web.enable=false (that is the barebone face)"
                        .into(),
                );
            }
            return Ok(());
        }
        if !self.kernel.cli.enable {
            return Err(
                "kernel.web.enable=false leaves no face: kernel.cli.enable must stay on".into(),
            );
        }
        if self.kernel.ui != "cli" {
            return Err(format!(
                "kernel.ui `{}` needs the web stack; with kernel.web.enable=false use cli",
                self.kernel.ui
            ));
        }
        for (slice, live) in [
            ("wasm", self.kernel.wasm.enable),
            ("js", js_live),
            ("dom/render/css", self.kernel.http.files.html),
        ] {
            if live {
                return Err(format!(
                    "kernel.web.enable=false excludes the whole engine ({}); \
                     `{slice}` cannot be compiled on its own",
                    WEB_SLICES.join("+")
                ));
            }
        }
        if self.kernel.http.files.js || self.kernel.http.files.wasm {
            return Err("kernel.http.files.js/wasm need the web stack (kernel.web.enable)".into());
        }
        if self.kernel.store.pglite_js || self.kernel.store.pglite_embed {
            return Err("kernel.store.pglite.js/embed need the web stack".into());
        }
        // An inert backend list (postboot never) is not a compiled face.
        if self.postboot.enable != PostbootMode::Never
            && self.postboot.backends.iter().any(|b| b == "html-js")
        {
            return Err(
                "postboot.backends html-js needs the web stack; barebone keeps ssh-holyc".into(),
            );
        }
        Ok(())
    }

    /// CLI container legality: boot order, geometry, and the capability gates
    /// that need a device behind them (pointer, USB, flash).
    fn check_cli(&self) -> Result<(), String> {
        let c = &self.kernel.cli;
        if !matches!(c.boot.as_str(), "cli" | "ui" | "auto" | "") {
            return Err("kernel.cli.boot must be cli, ui, or auto".into());
        }
        if !c.enable {
            return Ok(());
        }
        if !(10..=60).contains(&c.rows) || !(40..=200).contains(&c.cols) {
            return Err(
                "kernel.cli.rows must be 10..=60 and cols 40..=200 (VGA text is 25x80)".into(),
            );
        }
        if c.scrollback < c.rows || c.scrollback > 8192 {
            return Err("kernel.cli.scrollback must be rows..=8192 lines".into());
        }
        if c.mouse && !self.kernel.hw.enable {
            return Err(
                "kernel.cli.mouse needs kernel.hw.enable (pointer HID lives in g6b-hw)".into(),
            );
        }
        if c.fw && !(self.kernel.usb.flash_fat32 || self.kernel.flash.enable) {
            return Err(
                "kernel.cli.fw needs a firmware sink: kernel.usb.flash_fat32 or kernel.flash"
                    .into(),
            );
        }
        let ab = &c.autoboot;
        if BootOrder::parse(&ab.order).is_none() {
            return Err(format!(
                "kernel.cli.autoboot.order `{}` refused; use {}",
                ab.order,
                BOOT_ORDERS.join(", ")
            ));
        }
        if ab.timeout_ms > 60_000 {
            return Err(
                "kernel.cli.autoboot.timeout_ms must be 0..=60000 (0 waits for the operator)"
                    .into(),
            );
        }
        let url = self.kernel.flash.url.as_str();
        if !url.is_empty() {
            if !url.starts_with("https://") {
                return Err(
                    "kernel.flash.url must be https:// — a firmware image is never taken over \
                     plain HTTP"
                        .into(),
                );
            }
            if url.len() > 200
                || url
                    .chars()
                    .any(|ch| ch.is_control() || ch.is_whitespace() || ch == '"' || ch == '\\')
            {
                return Err("kernel.flash.url must be a plain URL under 200 chars".into());
            }
            if !self.kernel.tls.https {
                return Err("kernel.flash.url needs kernel.tls.https (HTTPS client)".into());
            }
        }
        Ok(())
    }

    /// Display-output legality: surface names, PCIe windows, and the address
    /// overlaps that would make a scanned BAR unusable.
    fn check_display(&self) -> Result<(), String> {
        let s = &self.kernel.proxy.surface;
        if !s.is_empty() && Surface::parse(s).is_none() {
            return Err(format!(
                "proxy.surface must be vga or gpu (empty = follow the output class), got {s}"
            ));
        }
        if !self.pcie.scan_display {
            return Ok(());
        }
        let ecam = parse_hex(&self.pcie.ecam)
            .ok_or("pcie.scan_display needs pcie.ecam (the config-space base)")?;
        let (mmio, len) = self
            .pcie_mmio_window()
            .ok_or("pcie.scan_display needs pcie.mmio (the 32-bit BAR window)")?;
        if len == 0 {
            return Err("pcie.mmio_len must be nonzero".into());
        }
        let end = mmio.saturating_add(len);
        // A BAR the firmware assigned inside this window must be readable
        // memory, so anything else claiming the same range makes every
        // scanned framebuffer unusable. QEMU virt puts the 32-bit PCIe MMIO
        // window at 0x40000000..0x80000000, which is exactly where the
        // ai-island GEMM block lives — the two cannot coexist.
        for p in &self.peripherals {
            if let Some(base) = parse_hex(&p.base) {
                if base >= mmio && base < end {
                    return Err(format!(
                        "peripheral {} at {} sits inside the PCIe MMIO window {}..{:#x}; \
                         every scanned BAR would overlap it — move the peripheral or \
                         drop pcie.scan_display",
                        p.id, p.base, self.pcie.mmio, end
                    ));
                }
            }
        }
        if let Some(dram) = parse_hex(&self.dram_base) {
            if dram >= mmio && dram < end {
                return Err(format!(
                    "dram_base {} sits inside the PCIe MMIO window {}..{:#x}",
                    self.dram_base, self.pcie.mmio, end
                ));
            }
        }
        if ecam >= mmio && ecam < end {
            return Err(format!(
                "pcie.ecam {} must not sit inside the PCIe MMIO window {}..{:#x}",
                self.pcie.ecam, self.pcie.mmio, end
            ));
        }
        Ok(())
    }

    /// ECAM config-space base when a PCIe display scan is asked for.
    pub fn pcie_ecam(&self) -> Option<u64> {
        if !self.pcie.scan_display {
            return None;
        }
        parse_hex(&self.pcie.ecam)
    }

    /// 32-bit PCIe MMIO window (`base`, `len`) a BAR must land inside for the
    /// framebuffer to be accepted. `None` when unset — a BAR outside a known
    /// window is refused rather than trusted.
    pub fn pcie_mmio_window(&self) -> Option<(u64, u64)> {
        let base = parse_hex(&self.pcie.mmio)?;
        let len = parse_hex(&self.pcie.mmio_len).unwrap_or(0x4000_0000);
        Some((base, len))
    }

    /// True when the guest should run the read-only PCIe display-controller
    /// scan (`PciProbe`). Requires an ECAM base *and* a graphics plane to
    /// paint — scanning for a framebuffer nobody will use is pointless.
    pub fn wants_pci_scan(&self) -> bool {
        self.pcie_ecam().is_some() && (self.kernel.gr.enable || self.kernel.proxy.enable)
    }

    /// High-res target the accelerated outputs scan out at, i.e. the
    /// display-proxy geometry when enabled, else the Gr plane geometry.
    fn high_geometry(&self) -> (u32, u32) {
        let g = &self.kernel.gr;
        let p = &self.kernel.proxy;
        let (lw, lh) = if g.enable {
            (g.w.max(8), g.h.max(8))
        } else {
            (640, 480)
        };
        if p.enable {
            (p.high_w.max(lw), p.high_h.max(lh))
        } else {
            (lw, lh)
        }
    }

    /// Candidate scanout outputs, **highest priority first**.
    ///
    /// This is the declared candidate set, not a detection result: whether a
    /// virtio DeviceID, a `G6DS` magic, an HPD bit or a PCIe class code is
    /// actually present is only knowable at boot, which is what the runtime
    /// `DispSel` mux resolves. `OutputClass::None` is always last so the
    /// ladder can never come up empty.
    pub fn display_outputs(&self) -> Vec<DisplayOutput> {
        let (hw, hh) = self.high_geometry();
        let mut outs = Vec::new();
        if self.wants_pci_scan() {
            outs.push(DisplayOutput {
                class: OutputClass::PcieLinearFb,
                id: "pcie0".into(),
                base: self.pcie_ecam(),
                w: hw,
                h: hh,
                surface: Surface::Gpu,
                why: "PCIe class-0x03 controller with a pre-initialized linear framebuffer; \
                      no AMD AtomBIOS/DCN or NVIDIA GSP modeset — an uninitialized part is demoted"
                    .into(),
            });
        }
        if self.wants_disp_scan() {
            outs.push(DisplayOutput {
                class: OutputClass::UncoreScanout,
                id: "disp0".into(),
                base: self.display_ctrl(),
                w: hw,
                h: hh,
                surface: Surface::Gpu,
                why: "uncore scanout engine (architecture/uncore/hdmi-display.md); \
                      HPD/EDID is a contract-revision ask, not implemented"
                    .into(),
            });
        }
        if self.wants_virtio_gpu() {
            outs.push(DisplayOutput {
                class: OutputClass::VirtioGpu,
                id: "vio0".into(),
                base: None,
                w: hw,
                h: hh,
                surface: Surface::Gpu,
                why: "virtio-gpu over virtio-mmio (QEMU virt transport)".into(),
            });
        }
        let (lw, lh) = if self.kernel.gr.enable {
            (self.kernel.gr.w.max(8), self.kernel.gr.h.max(8))
        } else {
            (640, 480)
        };
        outs.push(DisplayOutput {
            class: OutputClass::None,
            id: "vga0".into(),
            base: None,
            w: lw,
            h: lh,
            surface: Surface::Vga,
            why: "low-res Gr plane over UART cells; the fallback that always exists".into(),
        });
        outs.sort_by(|a, b| b.class.priority().cmp(&a.class.priority()));
        outs
    }

    /// The output `DispSel` would pick if every candidate were present — the
    /// declared default, used for gen-time geometry and menus.
    pub fn default_output(&self) -> DisplayOutput {
        self.display_outputs()
            .into_iter()
            .next()
            .expect("display_outputs always yields the None fallback")
    }

    /// Surface that feeds the scanout by default.
    ///
    /// An explicit `kernel.proxy.surface` wins; otherwise the default follows
    /// the highest-priority output's class, so the low-res plane is never
    /// upscaled onto a GPU-class output unless the user asks.
    pub fn default_surface(&self) -> Surface {
        Surface::parse(&self.kernel.proxy.surface).unwrap_or(self.default_output().surface)
    }

    /// True when both surfaces are reachable, so the display-proxy should
    /// offer the VGA/GPU toggle.
    pub fn surface_toggle(&self) -> bool {
        self.display_outputs()
            .iter()
            .any(|o| o.class.is_accelerated())
    }

    /// Optional high-DPI GL/scale accelerator. Default `off`.
    pub fn proxy_accel(&self) -> ProxyAccel {
        match self.kernel.proxy.accel.as_str() {
            "rvv" => ProxyAccel::Rvv,
            "ai-island" => ProxyAccel::AiIsland,
            "auto" => {
                if self.rvv_live() {
                    ProxyAccel::Rvv
                } else if self.has_ai_island() {
                    ProxyAccel::AiIsland
                } else {
                    ProxyAccel::Off
                }
            }
            _ => ProxyAccel::Off,
        }
    }

    /// True when the QEMU argv should attach `virtio-gpu-device` — single
    /// predicate shared by argv emission, payload probing and host device
    /// models so they cannot drift.
    pub fn wants_virtio_gpu(&self) -> bool {
        self.kernel.gr.enable
            && (self.kernel.gr.backend == "virtio-gpu"
                || self.kernel.proxy.enable
                    // A declared native display engine takes the link —
                    // virtio-gpu is the QEMU-virt transport fallback.
                    && self.display_ctrl().is_none()
                    && matches!(
                        self.kernel.proxy.link.as_str(),
                        "virtio-gpu" | "hdmi" | "displayport" | "host-gl"
                    ))
    }

    /// True when the QEMU argv should attach `virtio-keyboard-device` plus
    /// `virtio-tablet-device` and the guest should probe DeviceID 18
    /// (`InpProbe`/`InpInit`/`InpDrain`). Keyboard is the first DeviceID 18
    /// slot (guest `INP_KQ` / VGA `DomNav`); tablet is the next slot (QEMU
    /// pointer; B91b WebFeed maps `EV_ABS`/`BTN_*`). The probe is
    /// fail-closed (`VIRTIO-INPUT-NONE`) when QEMU has no device.
    /// A text face that consumes keys is what needs the device: the DOM lane
    /// (`kernel.wasm`) or the `g6b-zealcli` container. A keyboard-first CLI
    /// needs it *more* than the web UI does, so gating this on wasm alone left
    /// a barebone build with no way to type.
    pub fn wants_virtio_input(&self) -> bool {
        self.wants_virtio_gpu() && (self.kernel.wasm.enable || self.kernel.cli.enable)
    }

    /// True when the payload compiles a **virtio-blk** driver, so it can read
    /// sectors itself instead of asking a host for them.
    ///
    /// Two conditions, and both are honest requirements rather than taste:
    /// `uncore.storage` because a block driver without a storage controller is a
    /// claim about hardware that is not there, and the boot picker
    /// (`kernel.cli.autoboot`) because that is what needs to *load* a medium
    /// rather than merely list one. A board with storage but no picker still gets
    /// the driver when the CLI is compiled — `drives` on the guest side is the
    /// same read.
    pub fn wants_virtio_blk(&self) -> bool {
        self.uncore.storage
            && (self.kernel.cli.autoboot.enable || self.kernel.cli.enable)
            // Same transport question as the GPU: this is the QEMU-virt /
            // virtio-mmio bus, not a native SATA/NVMe controller.
            && self.wants_virtio_gpu()
    }

    /// True when the pointer device should be attached as well. The CLI is
    /// keyboard-complete, so a tablet is only justified by the web UI or by an
    /// explicit `kernel.cli.mouse`.
    pub fn wants_virtio_tablet(&self) -> bool {
        self.wants_virtio_input() && (self.kernel.wasm.enable || self.kernel.cli.mouse)
    }

    /// Guest `VioNetProbe` for virtio-net DeviceID 1. **Not** QEMU `-netdev`.
    pub fn wants_virtio_net(&self) -> bool {
        self.kernel.hw.enable && self.kernel.hw.virtio_net
    }

    /// Dual-band HolyC TCP host port when that band is live.
    pub fn holyc_tcp_port(&self) -> Option<u16> {
        if self.holyc.dual_band.tcp.enable {
            Some(self.holyc.dual_band.tcp.host_port)
        } else {
            None
        }
    }

    /// Architecture requirements inferred from post-boot / dual-band parameters.
    pub fn inferred_arch(&self) -> Vec<String> {
        let mut req = Vec::new();
        match self.postboot.enable {
            PostbootMode::Never => {}
            PostbootMode::Runtime => {
                req.push(format!(
                    "reserved DRAM carve-out {} for runtime BIOS (Linux maps view-only)",
                    self.postboot.reserved_dram
                ));
                req.push(
                    "SBI SRST (or equivalent) for reboot/shutdown from the management port".into(),
                );
            }
            PostbootMode::MgmtHart => {
                req.push("dedicated management hart that never leaves the BIOS kernel".into());
                req.push("SBI HSM: Linux harts start; mgmt hart stays in S-mode BIOS".into());
            }
            PostbootMode::BmcIsland => {
                req.push("always-on uncore BMC-shaped island with its own MAC/UART".into());
                req.push("management port is not the OS NIC".into());
            }
        }
        if self.postboot.access == "kvm" {
            if self.postboot.backends.iter().any(|b| b == "html-js") {
                req.push(
                    "KVM face HTML+JS: in-kernel viewport (UART/Gr, then mailbox ToHtml)".into(),
                );
            }
            if self.postboot.backends.iter().any(|b| b == "ssh-holyc") {
                req.push(
                    "KVM face SSH+HolyC: ZealOS CLI backend (holyc-repl); OpenSSH is B13".into(),
                );
            }
        }
        match self.net_expose.mode {
            NetExposeMode::UntilDelegate => {
                req.push(
                    "NIC until-delegate: BIOS may bind adapter for gateway/web and SSH+HolyC"
                        .into(),
                );
                req.push(format!(
                    "adapter ports: BIOS HTTPS :{} SSH+HolyC :{} (not a netdev after NET-DELEGATE)",
                    self.net_expose.bios_https_port, self.net_expose.ssh_holyc_port
                ));
                req.push(
                    "LinuxHandoff drops the adapter (NET-DELEGATE); Linux owns eth/wifi".into(),
                );
            }
            NetExposeMode::Always => {
                req.push("bmc-island keeps its own MAC; OS NIC is untouched".into());
            }
            NetExposeMode::Never => {}
        }
        if self.kernel.gr.enable {
            req.push(format!(
                "SysGrInit rewrite: {}x{}x{} backend={} (8x8 font; not VGA ports)",
                self.kernel.gr.w, self.kernel.gr.h, self.kernel.gr.colors, self.kernel.gr.backend
            ));
            if self.kernel.gr.backend == "virtio-gpu" {
                req.push(
                    "QEMU virt: -global virtio-mmio.force-legacy=false -device virtio-gpu-device; \
                     serial stays -nographic"
                        .into(),
                );
            }
        }
        if self.kernel.proxy.enable {
            let p = &self.kernel.proxy;
            req.push(format!(
                "display-proxy {}x{} → {}x{} dpi={} fps={} link={} gl={}",
                self.kernel.gr.w,
                self.kernel.gr.h,
                p.high_w,
                p.high_h,
                p.dpi,
                p.refresh_hz(),
                p.link,
                p.gl
            ));
            match p.link.as_str() {
                "hdmi" => req.push(
                    "uncore HDMI TMDS scanout (architecture/uncore/hdmi-display.md); EDID refresh"
                        .into(),
                ),
                "displayport" => {
                    req.push("uncore DisplayPort scanout; DPCD refresh 30/60/120".into())
                }
                "host-gl" => req.push(
                    "host OpenGL-ES2 adapter listing (no libGL, no Chromium) for BIOS UI".into(),
                ),
                _ => {}
            }
        }
        let outs = self.display_outputs();
        req.push(format!(
            "display outputs (priority order): {} — active surface {} by default",
            outs.iter()
                .map(|o| format!("{}={}", o.id, o.class.as_str()))
                .collect::<Vec<_>>()
                .join(" "),
            self.default_surface().as_str()
        ));
        if outs.iter().any(|o| o.class == OutputClass::UncoreScanout) {
            req.push(
                "uncore display engine must add HPD + EDID mode registers to the \
                 hdmi-display.md window before hot-plug output selection is possible; \
                 the BIOS cannot infer a connected cable today"
                    .into(),
            );
        }
        if outs.iter().any(|o| o.class == OutputClass::PcieLinearFb) {
            req.push(format!(
                "PCIe root complex with ECAM at {} and BAR window {} must present \
                 firmware-assigned BARs; the BIOS enumerates read-only and accepts only a \
                 pre-initialized linear framebuffer — no AMD AtomBIOS/DCN and no NVIDIA GSP \
                 devinit is carried, so an uninitialized adapter is demoted, not driven",
                self.pcie.ecam, self.pcie.mmio
            ));
        }
        if self.kernel.ui == "svelte-d" {
            req.push(
                "BIOS UI designed in svelte-d (kernel-spec/svelte-d); NodeDef live, not LDC/Binaryen"
                    .into(),
            );
        }
        if self.kernel.wasm.enable {
            req.push(
                "WASM MVP JIT (g6b-wasm): env.set_inner_text; svelte-d _start; not wasmtime".into(),
            );
        }
        if self.kernel.profile != BiosProfile::Custom {
            req.push(format!("BIOS profile {}", self.kernel.profile.as_str()));
        }
        if self.kernel.hw.enable {
            req.push(format!(
                "g6b-hw adapters virtio-net={} ethernet={} wifi={} (VioNetProbe DeviceID 1; never QEMU -netdev)",
                self.kernel.hw.virtio_net, self.kernel.hw.ethernet, self.kernel.hw.wifi
            ));
        }
        if self.kernel.http.enable {
            req.push(format!(
                "kernel HTTP endpoints http1={} http2={} js-proxy={} serve={} outbound={} (not SvelteKit, not a netdev)",
                self.kernel.http.http1, self.kernel.http.http2, self.kernel.http.proxy_js, self.kernel.http.serve, self.kernel.http.outbound
            ));
            if self.kernel.http.files.enable {
                req.push(format!(
                    "HolyC file server root={} html={} js={} wasm={} https={} (adapter until NET-DELEGATE)",
                    self.kernel.http.files.root,
                    self.kernel.http.files.html,
                    self.kernel.http.files.js,
                    self.kernel.http.files.wasm,
                    self.kernel.http.files.https
                ));
            }
            if self.kernel.params.clocks {
                req.push(format!(
                    "BIOS clocks cpu_hz={} uart_baud={}",
                    self.kernel.params.cpu_hz, self.kernel.params.uart_baud
                ));
            }
            if self.kernel.params.edk2 {
                req.push(
                    "BIOS param /bios/edk2 (view-only; EDK2 is a loader, not this payload)".into(),
                );
            }
            if self.kernel.params.uboot {
                req.push("BIOS param /bios/u-boot (view-only)".into());
            }
            if self.kernel.params.bootloader {
                req.push(format!(
                    "BIOS param /bios/bootloader next={}",
                    self.kernel.params.next
                ));
            }
        }
        if self.kernel.flash.enable {
            req.push(format!(
                "BIOS flash image={} backend={} openwrt={} self_update={}",
                self.kernel.flash.image,
                self.kernel.flash.backend,
                self.kernel.flash.openwrt,
                self.kernel.flash.self_update
            ));
        }
        if self.kernel.settings.enable {
            req.push(format!(
                "BIOS settings export={} import={} uart={} mailbox={} usb_key={}",
                self.kernel.settings.export,
                self.kernel.settings.import,
                self.kernel.settings.uart,
                self.kernel.settings.mailbox,
                self.kernel.settings.usb_key
            ));
        }
        if self.kernel.usb.enable {
            req.push(format!(
                "USB host MSC FAT32 flash={} key-fm={} ntfs={} ext4={} btrfs={} (not a netdev)",
                self.kernel.usb.flash_fat32,
                self.kernel.usb.key,
                self.kernel.usb.fs_ntfs,
                self.kernel.usb.fs_ext4,
                self.kernel.usb.fs_btrfs
            ));
        }
        if self.kernel.tls.enable {
            req.push(
                "HolyC TLS (Botan spec): SHA-256, AES-128, HMAC, RSA PKCS#1, ECDSA P-256, X.509; not OpenSSL"
                    .into(),
            );
            if self.kernel.tls.https {
                req.push(
                    "HttpsGet on pre-delegate NIC or mailbox after NET-DELEGATE; never a netdev"
                        .into(),
                );
            }
        }
        if self.loopback.enable {
            req.push(format!(
                "APU mailbox {} irq {} compatible={} → {} (not a netdev; MEI/SMC/IPMI-BT shape)",
                self.loopback.base,
                self.loopback.irq,
                self.loopback.compatible,
                self.loopback.chardev
            ));
            req.push(
                "PMA device region; dedicated PLIC line; Linux miscdriver, no alloc_netdev".into(),
            );
        }
        if self.postboot.power.iter().any(|p| p == "wakeup") {
            req.push(
                "always-on domain or Wake-on-LAN on the management path (not the OS NIC after delegate)"
                    .into(),
            );
        }
        if !self.postboot.immutable.is_empty() && self.postboot.enable != PostbootMode::Never {
            req.push(format!(
                "PMP/PMA lock of immutable sections after handoff: {}",
                self.postboot.immutable.join(",")
            ));
        }
        if self.holyc.dual_band.tcp.enable {
            req.push(format!(
                "QEMU UART1 -serial tcp:127.0.0.1:{},server,nowait (ssh-like HolyC REPL)",
                self.holyc.dual_band.tcp.host_port
            ));
        }
        req.push(
            "S-mode timer: sie.STIE + sstatus.SIE + SBI TIME (Priv ch3 / SBI TIME); not PIT".into(),
        );
        if self.kernel.proxy.enable {
            req.push(format!(
                "display-proxy scale_mode={} {}x{}→{}x{} dpi={} fps={}",
                if self.kernel.proxy.scale_mode.is_empty() {
                    "fit"
                } else {
                    self.kernel.proxy.scale_mode.as_str()
                },
                self.kernel.gr.w,
                self.kernel.gr.h,
                self.kernel.proxy.high_w,
                self.kernel.proxy.high_h,
                self.kernel.proxy.dpi,
                self.kernel.proxy.refresh_hz()
            ));
        }
        if self.rvv_live() {
            req.push("HolyC ISel MemCpy uses RVV vsetvli/vle8.v/vse8.v (xlen=64, v=live)".into());
        } else {
            req.push("HolyC ISel MemCpy is scalar (RVV not live)".into());
        }
        if self.kernel.proxy.enable && self.kernel.proxy.gl {
            match self.proxy_accel() {
                ProxyAccel::Rvv => req.push(
                    "display-proxy GLES2 scale blit uses RVV (G6LC_PROXY_ACCEL_RVV); not a GPU driver"
                        .into(),
                ),
                ProxyAccel::AiIsland => req.push(
                    "display-proxy GLES2 tiles optionally offload to ai-island GEMM @ 0x40000000 (plane stays GR; not a netdev)"
                        .into(),
                ),
                ProxyAccel::Off => req.push(
                    "display-proxy GLES2 scale is scalar nearest-neighbour (proxy.accel=off)".into(),
                ),
            }
        }
        req.push(format!(
            "CPU topology {} cores={} threads={} harts={} issue={} ooo={} (BIOS Adam on hart 0; others WFI)",
            self.topology_kind(),
            self.cores,
            self.threads,
            self.harts,
            self.geo.issue_ports,
            self.geo.ooo
        ));
        if self.hypervisor_live() {
            req.push(
                "Hypervisor H live: next-stage KVM/HS; this BIOS payload stays S-mode under OpenSBI"
                    .into(),
            );
        }
        req.push(format!(
            "uncore clint={} plic={} ddr={} pcie={} eth={} storage={} hdmi={} (setup menus; not Linux drivers)",
            self.uncore.clint,
            self.uncore.plic,
            self.uncore.ddr,
            self.uncore.pcie,
            self.uncore.ethernet,
            self.uncore.storage,
            self.uncore.hdmi
        ));
        req
    }
}

fn parse_isa(v: &Json) -> Isa {
    let mut isa = Isa::default();
    if let Some(x) = v.get("xlen").as_u32() {
        isa.xlen = x;
    }
    if let Some(m) = v.get("march").as_str() {
        isa.march = m.to_string();
    }
    if let Some(m) = v.get("mmu").as_str() {
        isa.mmu = m.to_string();
    }
    let ext = v.get("extensions");
    isa.v = ExtStatus::parse(ext.get("v").as_str().unwrap_or("absent"));
    isa.c = ExtStatus::parse(ext.get("c").as_str().unwrap_or("absent"));
    isa.zba = ExtStatus::parse(ext.get("zba").as_str().unwrap_or("absent"));
    isa.zbb = ExtStatus::parse(ext.get("zbb").as_str().unwrap_or("absent"));
    isa.zicboz = ExtStatus::parse(ext.get("zicboz").as_str().unwrap_or("absent"));
    isa.zacas = ExtStatus::parse(ext.get("zacas").as_str().unwrap_or("absent"));
    isa.f = ExtStatus::parse(ext.get("f").as_str().unwrap_or("absent"));
    isa.d = ExtStatus::parse(ext.get("d").as_str().unwrap_or("absent"));
    isa.h = ExtStatus::parse(ext.get("h").as_str().unwrap_or("absent"));
    isa
}

fn apply_geo(g: &mut CoreGeo, v: &Json) {
    if let Some(n) = v.get("issue_ports").as_u32() {
        g.issue_ports = n;
    }
    if let Some(b) = v.get("ooo").as_bool() {
        g.ooo = b;
    }
    if let Some(b) = v.get("stream").as_bool() {
        g.stream = b;
    }
}

fn apply_pcie(p: &mut Pcie, v: &Json) {
    if let Some(s) = v.get("ecam").as_str() {
        p.ecam = s.to_string();
    }
    if let Some(s) = v.get("mmio").as_str() {
        p.mmio = s.to_string();
    }
    if let Some(s) = v.get("mmio_len").as_str() {
        p.mmio_len = s.to_string();
    }
    if let Some(b) = v.get("scan_display").as_bool() {
        p.scan_display = b;
    }
}

fn apply_uncore(u: &mut Uncore, v: &Json) {
    if let Some(b) = v.get("clint").as_bool() {
        u.clint = b;
    }
    if let Some(b) = v.get("plic").as_bool() {
        u.plic = b;
    }
    if let Some(b) = v.get("ddr").as_bool() {
        u.ddr = b;
    }
    if let Some(b) = v.get("pcie").as_bool() {
        u.pcie = b;
    }
    if let Some(b) = v.get("ethernet").as_bool() {
        u.ethernet = b;
    }
    if let Some(b) = v.get("storage").as_bool() {
        u.storage = b;
    }
    if let Some(b) = v.get("hdmi").as_bool() {
        u.hdmi = b;
    }
}

impl BoardSpec {
    fn infer_geo(&mut self) -> Result<(), String> {
        let cores_set = self.cores != 0;
        let threads_set = self.threads != 0;
        if !cores_set {
            self.cores = 1;
        }
        if !threads_set {
            if self.cores > 0 && self.harts % self.cores == 0 {
                self.threads = self.harts / self.cores;
            } else {
                self.threads = 1;
            }
        }
        if cores_set && threads_set {
            self.harts = self.cores.saturating_mul(self.threads);
        } else if self.cores.saturating_mul(self.threads) != self.harts {
            return Err(format!(
                "harts.count {} must equal cores {} × threads {}",
                self.harts, self.cores, self.threads
            ));
        }
        if self.geo.issue_ports == 0 {
            self.geo.issue_ports = 1;
        }
        if self.product.contains("stream") {
            self.geo.stream = true;
        }
        if self.product.contains("ooo") {
            self.geo.ooo = true;
        }
        Ok(())
    }

    fn infer_uncore(&mut self) {
        if self.isa.xlen == 64 {
            self.uncore.clint = true;
            self.uncore.plic = true;
        }
        for name in self
            .connectors
            .uncore
            .iter()
            .chain(self.connectors.apu.iter())
            .chain(self.connectors.core.iter())
        {
            match name.as_str() {
                "ddr" | "litedram" | "dram" => self.uncore.ddr = true,
                "pcie" | "pci" => self.uncore.pcie = true,
                "eth" | "ethernet" | "net" => self.uncore.ethernet = true,
                "sata" | "nvme" | "sd" | "storage" => self.uncore.storage = true,
                "hdmi" | "displayport" | "dp" => self.uncore.hdmi = true,
                "clint" | "aclint" => self.uncore.clint = true,
                "plic" => self.uncore.plic = true,
                _ => {}
            }
        }
        for p in &self.peripherals {
            let key = format!("{} {} {}", p.id, p.class, p.model).to_ascii_lowercase();
            if key.contains("ddr") || key.contains("dram") {
                self.uncore.ddr = true;
            }
            if key.contains("pcie") || key.contains("pci") {
                self.uncore.pcie = true;
            }
            if key.contains("eth") || key.contains("gmac") {
                self.uncore.ethernet = true;
            }
            if key.contains("sata") || key.contains("nvme") || key.contains("sdcard") {
                self.uncore.storage = true;
            }
            if key.contains("hdmi") || key.contains("displayport") {
                self.uncore.hdmi = true;
            }
            if key.contains("clint") {
                self.uncore.clint = true;
            }
            if key.contains("plic") {
                self.uncore.plic = true;
            }
        }
        match self.kernel.proxy.link.as_str() {
            "hdmi" | "displayport" => self.uncore.hdmi = true,
            _ => {}
        }
        if self.kernel.gr.backend == "hdmi" || self.kernel.gr.backend == "displayport" {
            self.uncore.hdmi = true;
        }
    }
}

fn apply_kernel(k: &mut Kernel, v: &Json) {
    if let Some(s) = v.get("shape").as_str() {
        k.shape = s.to_string();
    }
    if let Some(s) = v.get("display").as_str() {
        k.display = s.to_string();
    }
    if let Json::Obj(_) = v.get("browser") {
        if let Some(js) = v.get("browser").get("js").as_str() {
            k.js = js.to_string();
        }
        if let Some(ui) = v.get("browser").get("ui").as_str() {
            k.ui = ui.to_string();
        }
        if let Some(menu) = v.get("browser").get("start_menu").as_str() {
            k.start_menu = menu.to_string();
        }
        if let Json::Obj(_) = v.get("browser").get("wasm") {
            apply_wasm(&mut k.wasm, v.get("browser").get("wasm"));
        }
    }
    if let Json::Obj(_) = v.get("gr") {
        let g = v.get("gr");
        k.gr.enable = g.get("enable").as_bool().unwrap_or(false);
        if let Some(w) = g.get("w").as_u32() {
            k.gr.w = w;
        }
        if let Some(h) = g.get("h").as_u32() {
            k.gr.h = h;
        }
        if let Some(c) = g.get("colors").as_u32() {
            k.gr.colors = c;
        }
        if let Some(b) = g.get("backend").as_str() {
            k.gr.backend = b.to_string();
        }
    }
    if let Json::Obj(_) = v.get("proxy") {
        apply_proxy(&mut k.proxy, v.get("proxy"));
    } else if let Json::Obj(_) = v.get("display_proxy") {
        apply_proxy(&mut k.proxy, v.get("display_proxy"));
    }
    if let Json::Obj(_) = v.get("tls") {
        apply_tls(&mut k.tls, v.get("tls"));
    }
    if let Some(s) = v.get("ui").as_str() {
        k.ui = s.to_string();
    }
    if let Json::Obj(_) = v.get("wasm") {
        apply_wasm(&mut k.wasm, v.get("wasm"));
    }
    if let Json::Obj(_) = v.get("http") {
        apply_http(&mut k.http, v.get("http"));
    }
    if let Json::Obj(_) = v.get("params") {
        apply_params(&mut k.params, v.get("params"));
    }
    if let Some(s) = v.get("profile").as_str() {
        if let Ok(p) = BiosProfile::parse(s) {
            k.profile = p;
        }
    }
    if let Json::Obj(_) = v.get("flash") {
        apply_flash(&mut k.flash, v.get("flash"));
    }
    if let Json::Obj(_) = v.get("settings") {
        apply_settings(&mut k.settings, v.get("settings"));
    }
    if let Json::Obj(_) = v.get("usb") {
        apply_usb(&mut k.usb, v.get("usb"));
    }
    if let Json::Obj(_) = v.get("store") {
        apply_store(&mut k.store, v.get("store"));
    }
    if let Json::Obj(_) = v.get("hw") {
        apply_hw(&mut k.hw, v.get("hw"));
    }
    if let Json::Obj(_) = v.get("cli") {
        apply_cli(&mut k.cli, v.get("cli"));
    }
    if let Json::Obj(_) = v.get("web") {
        apply_web(&mut k.web, v.get("web"));
    }
}

fn apply_cli(c: &mut Cli, v: &Json) {
    if let Some(b) = v.get("enable").as_bool() {
        c.enable = b;
    }
    if let Some(s) = v.get("boot").as_str() {
        c.boot = s.to_string();
    }
    if let Some(b) = v.get("mouse").as_bool() {
        c.mouse = b;
    }
    if let Some(n) = v.get("rows").as_u32() {
        c.rows = n;
    }
    if let Some(n) = v.get("cols").as_u32() {
        c.cols = n;
    }
    if let Some(n) = v.get("scrollback").as_u32() {
        c.scrollback = n;
    }
    if let Some(b) = v.get("manual").as_bool() {
        c.manual = b;
    }
    if let Some(b) = v.get("vi").as_bool() {
        c.vi = b;
    }
    if let Some(b) = v.get("fs").as_bool() {
        c.fs = b;
    }
    if let Some(b) = v.get("fw").as_bool() {
        c.fw = b;
    }
    if let Json::Obj(_) = v.get("autoboot") {
        apply_autoboot(&mut c.autoboot, v.get("autoboot"));
    }
}

fn apply_autoboot(a: &mut Autoboot, v: &Json) {
    if let Some(b) = v.get("enable").as_bool() {
        a.enable = b;
    }
    if let Some(n) = v
        .get("timeout_ms")
        .as_u32()
        .or_else(|| v.get("timeout").as_u32())
    {
        a.timeout_ms = n;
    }
    if let Some(s) = v.get("order").as_str() {
        a.order = s.to_string();
    }
    if let Some(b) = v.get("bios_ui").as_bool() {
        a.bios_ui = b;
    }
}

fn apply_web(w: &mut Web, v: &Json) {
    if let Some(b) = v.get("enable").as_bool() {
        w.enable = b;
    }
}

fn apply_hw(h: &mut Hw, v: &Json) {
    if let Some(b) = v.get("enable").as_bool() {
        h.enable = b;
    }
    if let Some(b) = v.get("virtio_net").as_bool() {
        h.virtio_net = b;
    }
    if let Some(b) = v.get("ethernet").as_bool() {
        h.ethernet = b;
    }
    if let Some(b) = v.get("wifi").as_bool() {
        h.wifi = b;
    }
}

fn apply_store(s: &mut StoreCfg, v: &Json) {
    if let Some(b) = v.get("enable").as_bool() {
        s.enable = b;
    }
    if let Json::Obj(_) = v.get("persist") {
        let p = v.get("persist");
        if let Some(b) = p.get("memory").as_bool() {
            s.persist_memory = b;
        }
        if let Some(b) = p.get("elf").as_bool() {
            s.persist_elf = b;
        }
        if let Some(b) = p.get("usb").as_bool() {
            s.persist_usb = b;
        }
        if let Some(v) = p.get("volume").as_str() {
            s.usb_volume = v.to_ascii_lowercase();
        }
    }
    if let Json::Obj(_) = v.get("pglite") {
        let p = v.get("pglite");
        if let Some(b) = p.get("files").as_bool() {
            s.pglite_files = b;
        }
        if let Some(b) = p.get("js").as_bool() {
            s.pglite_js = b;
        }
        if let Some(b) = p.get("embed").as_bool() {
            s.pglite_embed = b;
        }
    }
    if let Some(n) = v
        .get("max_stores")
        .as_u32()
        .or_else(|| v.get("max_instances").as_u32())
    {
        s.max_stores = n;
    }
    if let Some(n) = v.get("max_tables").as_u32() {
        s.max_tables = n;
    }
    if let Some(n) = v.get("max_columns").as_u32() {
        s.max_columns = n;
    }
    if let Some(n) = v.get("max_rows").as_u32() {
        s.max_rows = n;
    }
    if let Some(n) = v.get("max_sql_bytes").as_u32() {
        s.max_sql_bytes = n;
    }
    if let Some(n) = v.get("max_param_bytes").as_u32() {
        s.max_param_bytes = n;
    }
    if let Some(n) = v.get("max_result_bytes").as_u32() {
        s.max_result_bytes = n;
    }
    if let Some(n) = v.get("max_tx").as_u32() {
        s.max_tx = n;
    }
    if let Some(n) = v.get("max_open").as_u32() {
        s.max_open = n;
    }
    if let Some(n) = v.get("max_per_purpose").as_u32() {
        s.max_per_purpose = n;
    }
    let names = match v.get("purposes") {
        Json::Arr(a) => Some(a),
        _ => match v.get("names") {
            Json::Arr(a) => Some(a),
            _ => None,
        },
    };
    if let Some(a) = names {
        s.purposes = a
            .iter()
            .filter_map(|x| x.as_str().map(str::to_string))
            .collect();
    }
    if s.enable && s.purposes.is_empty() {
        s.purposes.push("registry".into());
    }
}

fn apply_wasm(w: &mut Wasm, v: &Json) {
    w.enable = v.get("enable").as_bool().unwrap_or(true);
    w.jit = v.get("jit").as_bool().unwrap_or(w.enable);
    if let Some(b) = v.get("guest_jit").as_bool() {
        w.guest_jit = b;
    }
    if let Some(s) = v.get("jit_cell").as_str() {
        w.jit_cell = s.to_string();
    }
}

fn apply_http(h: &mut Http, v: &Json) {
    if let Some(b) = v.get("enable").as_bool() {
        h.enable = b;
    }
    if let Some(b) = v.get("http1").as_bool() {
        h.http1 = b;
    } else if v.get("enable").as_bool() == Some(true) {
        h.http1 = true;
    }
    if let Some(b) = v.get("http2").as_bool() {
        h.http2 = b;
    }
    if let Some(b) = v.get("proxy_js").as_bool() {
        h.proxy_js = b;
    }
    if let Some(b) = v.get("serve").as_bool() {
        h.serve = b;
    }
    if let Some(b) = v.get("outbound").as_bool() {
        h.outbound = b;
    }
    if let Json::Obj(_) = v.get("files") {
        apply_http_files(&mut h.files, v.get("files"));
    }
}

fn apply_http_files(f: &mut HttpFiles, v: &Json) {
    if let Some(b) = v.get("enable").as_bool() {
        f.enable = b;
        if b {
            f.html = true;
        }
    }
    if let Some(b) = v.get("html").as_bool() {
        f.html = b;
    }
    if let Some(b) = v.get("js").as_bool() {
        f.js = b;
    }
    if let Some(b) = v.get("wasm").as_bool() {
        f.wasm = b;
    }
    if let Some(b) = v.get("https").as_bool() {
        f.https = b;
    }
    if let Some(b) = v.get("assets").as_bool() {
        f.assets = b;
    }
    if let Some(s) = v.get("root").as_str() {
        f.root = if s.starts_with('/') {
            s.to_string()
        } else {
            format!("/{s}")
        };
    }
}

fn apply_params(p: &mut BiosParams, v: &Json) {
    if let Some(b) = v.get("clocks").as_bool() {
        p.clocks = b;
    }
    if let Some(b) = v.get("edk2").as_bool() {
        p.edk2 = b;
    }
    if let Some(b) = v
        .get("uboot")
        .as_bool()
        .or_else(|| v.get("u-boot").as_bool())
    {
        p.uboot = b;
    }
    if let Some(b) = v.get("bootloader").as_bool() {
        p.bootloader = b;
    }
    if let Some(n) = v.get("cpu_hz").as_u32() {
        p.cpu_hz = n;
    }
    if let Some(n) = v.get("uart_baud").as_u32() {
        p.uart_baud = n;
    }
    if let Some(b) = v.get("edk2_enable").as_bool() {
        p.edk2_enable = b;
    }
    if let Some(b) = v.get("uboot_enable").as_bool() {
        p.uboot_enable = b;
    }
    if let Some(s) = v.get("next").as_str() {
        p.next = s.to_string();
    }
}

fn apply_flash(f: &mut Flash, v: &Json) {
    if let Some(b) = v.get("enable").as_bool() {
        f.enable = b;
    }
    if let Some(b) = v.get("openwrt").as_bool() {
        f.openwrt = b;
    }
    if let Some(b) = v.get("self_update").as_bool() {
        f.self_update = b;
    }
    if let Some(s) = v.get("backend").as_str() {
        f.backend = s.to_string();
    }
    if let Some(s) = v.get("image").as_str() {
        f.image = s.to_string();
    }
    if let Some(s) = v.get("url").as_str() {
        f.url = s.to_string();
    }
}

fn apply_settings(s: &mut Settings, v: &Json) {
    if let Some(b) = v.get("enable").as_bool() {
        s.enable = b;
    }
    if let Some(b) = v.get("export").as_bool() {
        s.export = b;
    }
    if let Some(b) = v.get("import").as_bool() {
        s.import = b;
    }
    if let Some(b) = v.get("uart").as_bool() {
        s.uart = b;
    }
    if let Some(b) = v.get("mailbox").as_bool() {
        s.mailbox = b;
    }
    if let Some(b) = v.get("usb_key").as_bool() {
        s.usb_key = b;
    }
}

fn apply_usb(u: &mut Usb, v: &Json) {
    if let Some(b) = v.get("enable").as_bool() {
        u.enable = b;
    }
    if let Some(b) = v.get("flash_fat32").as_bool() {
        u.flash_fat32 = b;
    }
    if let Some(b) = v.get("key").as_bool() {
        u.key = b;
        if b {
            u.fs_fat32 = true;
            u.fs_ntfs = true;
            u.fs_ext4 = true;
            u.fs_btrfs = true;
        }
    }
    if let Some(b) = v.get("fs_fat32").as_bool() {
        u.fs_fat32 = b;
    }
    if let Some(b) = v.get("fs_ntfs").as_bool() {
        u.fs_ntfs = b;
    }
    if let Some(b) = v.get("fs_ext4").as_bool() {
        u.fs_ext4 = b;
    }
    if let Some(b) = v.get("fs_btrfs").as_bool() {
        u.fs_btrfs = b;
    }
}

fn apply_proxy(p: &mut DisplayProxy, v: &Json) {
    p.enable = v.get("enable").as_bool().unwrap_or(true);
    if let Some(s) = v.get("link").as_str() {
        p.link = s.to_string();
    }
    if let Some(n) = v.get("dpi").as_u32() {
        p.dpi = n;
    }
    if let Some(n) = v.get("fps").as_u32() {
        p.fps = n;
    }
    if let Some(n) = v.get("detected_hz").as_u32() {
        p.detected_hz = n;
    }
    if let Some(n) = v.get("high_w").as_u32().or_else(|| v.get("w").as_u32()) {
        p.high_w = n;
    }
    if let Some(n) = v.get("high_h").as_u32().or_else(|| v.get("h").as_u32()) {
        p.high_h = n;
    }
    if let Some(b) = v.get("gl").as_bool() {
        p.gl = b;
    }
    if let Some(s) = v
        .get("scale_mode")
        .as_str()
        .or_else(|| v.get("scale").as_str())
    {
        p.scale_mode = s.to_string();
    }
    if let Some(s) = v.get("accel").as_str() {
        p.accel = s.to_string();
    }
    if let Some(s) = v.get("surface").as_str() {
        p.surface = s.to_string();
    }
}

fn apply_tls(t: &mut Tls, v: &Json) {
    t.enable = v.get("enable").as_bool().unwrap_or(true);
    t.https = v.get("https").as_bool().unwrap_or(t.enable);
    t.serve = v.get("serve").as_bool().unwrap_or(t.https);
    t.rsa = v.get("rsa").as_bool().unwrap_or(t.enable);
    t.ecdsa = v.get("ecdsa").as_bool().unwrap_or(t.enable);
    t.certificates = v.get("certificates").as_bool().unwrap_or(t.enable);
}

fn string_list(v: &Json) -> Vec<String> {
    match v {
        Json::Arr(a) => a
            .iter()
            .filter_map(|x| x.as_str().map(str::to_string))
            .collect(),
        _ => Vec::new(),
    }
}

fn parse_holyc(v: &Json) -> Holyc {
    let mut h = Holyc::default();
    if let Some(b) = v.get("fast_init").as_bool() {
        h.fast_init = b;
    }
    if let Json::Obj(_) = v.get("dual_band") {
        let d = v.get("dual_band");
        if let Some(b) = d.get("uart").as_bool() {
            h.dual_band.uart = b;
        }
        let tcp = if let Json::Obj(_) = d.get("tcp") {
            d.get("tcp")
        } else {
            d
        };
        if let Some(b) = tcp.get("enable").as_bool() {
            h.dual_band.tcp.enable = b;
        }
        if let Some(p) = tcp.get("host_port").as_u32() {
            h.dual_band.tcp.host_port = p as u16;
        } else if let Some(p) = tcp.get("port").as_u32() {
            h.dual_band.tcp.host_port = p as u16;
        }
        if let Some(p) = tcp.get("guest_port").as_u32() {
            h.dual_band.tcp.guest_port = p as u16;
        }
        if let Some(s) = tcp.get("proto").as_str() {
            h.dual_band.tcp.proto = s.to_string();
        }
    }
    h
}

fn parse_postboot(v: &Json) -> Postboot {
    let mut p = Postboot::default();
    if let Some(s) = v.get("enable").as_str() {
        p.enable = PostbootMode::parse(s);
    }
    if let Some(s) = v.get("access").as_str() {
        p.access = s.to_string();
    }
    let imm = string_list(v.get("immutable"));
    if !imm.is_empty() {
        p.immutable = imm;
    }
    let power = string_list(v.get("power"));
    if !power.is_empty() {
        p.power = power;
    }
    if let Some(s) = v.get("reserved_dram").as_str() {
        p.reserved_dram = s.to_string();
    }
    if let Some(b) = v.get("always_on_domain").as_bool() {
        p.always_on_domain = b;
    }
    if let Json::Obj(_) = v.get("requires") {
        let r = v.get("requires");
        if let Some(s) = r.get("reserved_dram").as_str() {
            p.reserved_dram = s.to_string();
        }
        if let Some(b) = r.get("always_on_domain").as_bool() {
            p.always_on_domain = b;
        }
    }
    let backends = string_list(v.get("backends"));
    if !backends.is_empty() {
        p.backends = backends;
    }
    p
}

fn parse_loopback(v: &Json) -> Loopback {
    let mut l = Loopback::default();
    if let Some(b) = v.get("enable").as_bool() {
        l.enable = b;
    } else {
        l.enable = true;
    }
    if let Some(s) = v.get("transport").as_str() {
        l.transport = s.to_string();
    }
    if let Some(s) = v.get("compatible").as_str() {
        l.compatible = s.to_string();
    }
    if let Some(s) = v.get("base").as_str() {
        l.base = s.to_string();
    }
    if let Some(s) = v.get("len").as_str() {
        l.len = s.to_string();
    }
    if let Some(n) = v.get("irq").as_u32() {
        l.irq = n;
    }
    if let Some(s) = v.get("chardev").as_str() {
        l.chardev = s.to_string();
    }
    l
}

fn parse_net_expose(v: &Json) -> NetExpose {
    let mut n = NetExpose::default();
    if let Some(s) = v.get("mode").as_str() {
        n.mode = NetExposeMode::parse(s);
    } else if let Some(s) = v.get("enable").as_str() {
        n.mode = NetExposeMode::parse(s);
    }
    if let Some(s) = v.get("via").as_str() {
        n.via = s.to_string();
    }
    if let Some(b) = v.get("web").as_bool() {
        n.web = b;
    }
    if let Some(b) = v.get("ssh_holyc").as_bool() {
        n.ssh_holyc = b;
    }
    if let Some(p) = v.get("bios_https_port").as_u32() {
        n.bios_https_port = p as u16;
    }
    if let Some(p) = v.get("ssh_holyc_port").as_u32() {
        n.ssh_holyc_port = p as u16;
    } else if let Some(p) = v.get("ssh_port").as_u32() {
        n.ssh_holyc_port = p as u16;
    }
    n
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

    #[test]
    fn rv32_fixture_rejects_rvv() {
        let err = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":32,"extensions":{"v":"live"}}}"#,
        )
        .unwrap_err();
        assert!(err.contains("xlen=32"), "{err}");
    }

    #[test]
    fn gpio_ai_collision() {
        let err = BoardSpec::from_json_str(
            r#"{
            "peripherals": [
              {"id":"ai0","class":"ai-island","model":"g6lc","base":"0x40000000"},
              {"id":"gpio0","class":"gpio","model":"mmio","base":"0x40000000"}
            ]
        }"#,
        )
        .unwrap_err();
        assert!(err.contains("0x40000000"), "{err}");
    }

    #[test]
    fn mgmt_hart_needs_two_harts() {
        let err = BoardSpec::from_json_str(
            r#"{"schema_version":1,"harts":{"count":1},"postboot":{"enable":"mgmt-hart"}}"#,
        )
        .unwrap_err();
        assert!(err.contains("mgmt-hart"), "{err}");
    }

    #[test]
    fn runtime_wakeup_needs_always_on() {
        let err = BoardSpec::from_json_str(
            r#"{"schema_version":1,"postboot":{"enable":"runtime","power":["wakeup"]}}"#,
        )
        .unwrap_err();
        assert!(err.contains("always_on"), "{err}");
    }

    #[test]
    fn kvm_runtime_infers_reserved_dram() {
        let spec = BoardSpec::from_json_str(
            r#"{
            "schema_version":1,
            "harts":{"count":2},
            "holyc":{"dual_band":{"tcp":{"enable":true,"host_port":2222}}},
            "postboot":{"enable":"runtime","access":"kvm","always_on_domain":true}
        }"#,
        )
        .unwrap();
        let req = spec.inferred_arch().join("\n");
        assert!(req.contains("reserved DRAM"), "{req}");
        assert!(req.contains("HTML+JS"), "{req}");
        assert!(req.contains("SSH+HolyC"), "{req}");
        assert!(req.contains("until-delegate"), "{req}");
        assert!(req.contains("mailbox"), "{req}");
        assert!(spec.holyc_tcp_port() == Some(2222));
        assert!(spec.loopback.enable);
        assert_eq!(spec.net_expose.mode, NetExposeMode::UntilDelegate);
    }

    #[test]
    fn gr_vga_backend_refused() {
        let err = BoardSpec::from_json_str(
            r#"{"schema_version":1,"kernel":{"gr":{"enable":true,"backend":"vga"}}}"#,
        )
        .unwrap_err();
        assert!(err.contains("virtio-gpu") || err.contains("uart"), "{err}");
    }

    #[test]
    fn svelte_wasm_infers() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
            "kernel":{"ui":"svelte-d","wasm":{"enable":true,"jit":true}}}"#,
        )
        .unwrap();
        assert_eq!(spec.kernel.ui, "svelte-d");
        assert!(spec.kernel.wasm.jit);
        let req = spec.inferred_arch().join("\n");
        assert!(req.contains("svelte-d"), "{req}");
        assert!(req.contains("WASM MVP"), "{req}");
    }

    #[test]
    fn profile_router_infers_flash() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"router","isa":{"xlen":32,"march":"rv32imac"}}"#,
        )
        .unwrap();
        assert_eq!(spec.kernel.profile, BiosProfile::Router);
        assert!(spec.kernel.flash.openwrt);
        assert!(spec.kernel.http.enable && spec.kernel.http.http1);
        assert!(!spec.kernel.http.http2);
        assert!(!spec.kernel.wasm.enable);
        assert_eq!(spec.kernel.ui, "html-js");
        assert!(spec.kernel.settings.uart && !spec.kernel.settings.usb_key);
        assert!(spec.kernel.usb.enable && spec.kernel.usb.flash_fat32 && !spec.kernel.usb.key);
        let feat = spec.compiled_features_json();
        assert!(feat.contains("\"flash_openwrt\":true"), "{feat}");
        assert!(feat.contains("\"usb_flash_fat32\":true"), "{feat}");
        assert!(feat.contains("\"fs_ntfs\":false"), "{feat}");
        let req = spec.inferred_arch().join("\n");
        assert!(req.contains("profile router"), "{req}");
        assert!(req.contains("openwrt"), "{req}");
    }

    #[test]
    fn profile_full_usb_settings() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        assert!(spec.kernel.usb.key && spec.kernel.settings.usb_key);
        assert!(spec.kernel.usb.flash_fat32 && spec.kernel.usb.fs_ntfs && spec.kernel.usb.fs_ext4);
        assert!(spec.kernel.http.serve && spec.kernel.tls.https);
        assert!(spec.kernel.http.outbound);
        assert!(spec.kernel.hw.enable && spec.kernel.hw.virtio_net);
        assert!(spec.wants_virtio_net());
        assert!(spec.kernel.ui == "svelte-d");
        assert!(spec
            .compiled_features()
            .iter()
            .any(|(k, v)| *k == "https_serve" && *v));
        assert!(spec
            .compiled_features()
            .iter()
            .any(|(k, v)| *k == "http_outbound" && *v));
        let off = BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"full","kernel":{"http":{"outbound":false}}}"#,
        )
        .unwrap();
        assert!(!off.kernel.http.outbound);
        assert!(off.kernel.http.enable && off.kernel.http.serve);
    }

    #[test]
    fn barebone_profile_excludes_the_whole_web_stack() {
        let spec =
            BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"barebone"}"#).unwrap();
        assert_eq!(spec.kernel.profile, BiosProfile::Barebone);
        assert!(!spec.web_stack());
        assert!(!spec.kernel.wasm.enable && !spec.kernel.wasm.jit);
        assert_eq!(spec.kernel.js, "off");
        assert_eq!(spec.kernel.ui, "cli");
        assert!(!spec.kernel.http.files.enable);
        assert!(!spec.kernel.store.enable);
        // What survives: kernel + HolyC band + hw NIC + USB key + HTTPS client.
        assert!(spec.kernel.http.enable && spec.kernel.http.outbound);
        assert!(spec.kernel.tls.https && !spec.kernel.tls.serve);
        assert!(spec.kernel.hw.enable && spec.kernel.hw.virtio_net);
        assert!(spec.kernel.usb.key && spec.kernel.usb.flash_fat32);
        assert!(spec.holyc.dual_band.uart);
        assert!(
            spec.kernel.gr.enable,
            "the VGA text container needs a plane"
        );
        assert!(!spec.kernel.proxy.enable, "no display proxy on barebone");
        let feat = spec.compiled_features_json();
        for off in [
            "\"web\":false",
            "\"web_dom\":false",
            "\"web_render\":false",
            "\"web_css\":false",
            "\"web_js\":false",
            "\"wasm\":false",
        ] {
            assert!(feat.contains(off), "{off} in {feat}");
        }
        for on in [
            "\"cli\":true",
            "\"cli_vi\":true",
            "\"cli_fw\":true",
            "\"cli_manual\":true",
            "\"cli_fs_volumes\":true",
            "\"hw\":true",
        ] {
            assert!(feat.contains(on), "{on} in {feat}");
        }
        assert!(!spec.cli_before_web(), "no web stack to come after the CLI");
    }

    #[test]
    fn web_slices_are_one_bundle_and_never_preempt_the_cli() {
        // A slice cannot be compiled without the bundle.
        for src in [
            r#"{"schema_version":1,"profile":"barebone","kernel":{"wasm":{"enable":true}}}"#,
            r#"{"schema_version":1,"profile":"barebone","kernel":{"browser":{"js":"aot"}}}"#,
            r#"{"schema_version":1,"kernel":{"web":{"enable":false}}}"#,
            r#"{"schema_version":1,"kernel":{"web":{"enable":false},"ui":"cli","cli":{"enable":false}}}"#,
        ] {
            let err = BoardSpec::from_json_str(src).unwrap_err();
            assert!(
                err.contains("web") || err.contains("face"),
                "{src} -> {err}"
            );
        }
        // With the engine compiled, zealcli still reaches its prompt first.
        let full = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        assert!(full.web_stack() && full.cli_before_web());
        assert_eq!(full.kernel.cli.boot, "auto");
        assert!(full.wants_zealcli(false), "CLI is the face until GPU");
        assert!(!full.wants_zealcli(true), "then LoadUI hands over");
        let err = BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"full","kernel":{"cli":{"boot":"ui"}}}"#,
        )
        .unwrap_err();
        assert!(err.contains("zealcli boots"), "{err}");
        assert!(full
            .compiled_features()
            .iter()
            .any(|(k, v)| *k == "cli_first" && *v));
    }

    #[test]
    fn cli_container_geometry_and_capability_gates() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"full","kernel":{"cli":{"rows":48,"cols":132,"scrollback":2048,"mouse":true}}}"#,
        )
        .unwrap();
        assert_eq!((spec.kernel.cli.rows, spec.kernel.cli.cols), (48, 132));
        assert_eq!(spec.kernel.cli.scrollback, 2048);
        assert!(spec.kernel.cli.mouse);
        for src in [
            r#"{"schema_version":1,"kernel":{"cli":{"rows":9}}}"#,
            r#"{"schema_version":1,"kernel":{"cli":{"cols":39}}}"#,
            r#"{"schema_version":1,"kernel":{"cli":{"scrollback":10}}}"#,
            r#"{"schema_version":1,"kernel":{"cli":{"scrollback":9000}}}"#,
            r#"{"schema_version":1,"kernel":{"cli":{"mouse":true}}}"#,
            r#"{"schema_version":1,"kernel":{"cli":{"fw":true},"usb":{"enable":true,"flash_fat32":false}}}"#,
        ] {
            assert!(BoardSpec::from_json_str(src).is_err(), "{src}");
        }
    }

    #[test]
    fn smt2_two_harts_is_one_core_two_threads() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"harts":{"count":2}}"#,
        )
        .unwrap();
        assert_eq!(spec.cores, 1);
        assert_eq!(spec.threads, 2);
        assert_eq!(spec.harts, 2);
        assert!(spec.smt());
        assert!(spec.uncore.clint && spec.uncore.plic);
        assert_eq!(spec.geo.issue_ports, 1);
    }

    #[test]
    fn server_geo_hypervisor_rvv_uncore() {
        let spec = BoardSpec::from_json_str(
            r#"{
            "schema_version":1,
            "product":"g6lc64-server",
            "isa":{"xlen":64,"march":"rv64imafdcvh","extensions":{"v":"live","h":"live","f":"live","d":"live"}},
            "harts":{"cores":2,"threads":2},
            "core":{"issue_ports":2,"ooo":true,"stream":true},
            "uncore":{"ddr":true,"pcie":true,"ethernet":true,"storage":true,"hdmi":true}
        }"#,
        )
        .unwrap();
        assert_eq!(spec.harts, 4);
        assert!(spec.multi_core() && spec.smt() && spec.geo.stream && spec.geo.ooo);
        assert!(spec.hypervisor_live() && spec.rvv_live());
        assert!(spec.uncore.ddr && spec.uncore.pcie && spec.uncore.ethernet);
        let feat = spec.compiled_features_json();
        assert!(feat.contains("\"hypervisor\":true"), "{feat}");
        assert!(feat.contains("\"stream\":true"), "{feat}");
        let cpu = spec.menu("cpu").unwrap();
        assert!(cpu
            .items
            .iter()
            .any(|i| i.id == "hypervisor" && i.value == "live"));
    }

    #[test]
    fn files_wasm_needs_wasm() {
        let err = BoardSpec::from_json_str(
            r#"{"schema_version":1,"kernel":{"http":{"enable":true,"serve":true,"files":{"enable":true,"wasm":true}}}}"#,
        )
        .unwrap_err();
        assert!(err.contains("files.wasm"), "{err}");
    }

    #[test]
    fn profile_full_file_server() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        assert!(spec.kernel.http.files.enable && spec.kernel.http.files.wasm);
        assert!(spec.kernel.http.files.https && spec.kernel.tls.serve);
        let feat = spec.compiled_features_json();
        assert!(feat.contains("\"http_files_wasm\":true"), "{feat}");
        assert!(feat.contains("\"https_files\":true"), "{feat}");
    }

    #[test]
    fn usb_key_needs_usb() {
        let err = BoardSpec::from_json_str(
            r#"{"schema_version":1,"kernel":{"settings":{"enable":true,"usb_key":true},"usb":{"enable":false}}}"#,
        )
        .unwrap_err();
        assert!(err.contains("usb_key"), "{err}");
    }

    #[test]
    fn sveltekit_refused() {
        let err = BoardSpec::from_json_str(r#"{"schema_version":1,"kernel":{"ui":"sveltekit"}}"#)
            .unwrap_err();
        assert!(err.contains("sveltekit"), "{err}");
    }

    #[test]
    fn store_defaults_on_with_registry_purpose() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1}"#).unwrap();
        assert!(spec.kernel.store.enable);
        assert_eq!(spec.kernel.store.purposes, ["registry"]);
        assert!(spec.kernel.store.persist_memory);
        assert!(!spec.kernel.store.pglite_files);
        let feat = spec.compiled_features_json();
        assert!(feat.contains("\"store\":true"), "{feat}");
        let settings = spec.menu("settings").unwrap();
        assert!(settings
            .items
            .iter()
            .any(|i| i.id == "store" && i.value == "yes"));
    }

    #[test]
    fn store_enable_fills_registry_when_purposes_empty() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"kernel":{"store":{"enable":true,"purposes":[]}}}"#,
        )
        .unwrap();
        assert_eq!(spec.kernel.store.purposes, ["registry"]);
    }

    #[test]
    fn store_names_alias_and_flag_to_flag_check() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"kernel":{"store":{"enable":true,"names":["setup"],"persist":{"elf":true},"pglite":{"embed":true}}}}"#,
        )
        .unwrap();
        assert_eq!(spec.kernel.store.purposes, ["setup"]);
        assert!(spec.kernel.store.persist_elf);
        assert!(spec.kernel.store.pglite_embed);
        assert!(!spec.kernel.store.pglite_files);
        let off = BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"embedded","kernel":{"store":{"enable":false}}}"#,
        )
        .unwrap();
        assert!(!off.kernel.store.enable);
        let err = BoardSpec::from_json_str(
            r#"{"schema_version":1,"kernel":{"usb":{"enable":true,"key":false,"flash_fat32":true},"store":{"persist":{"usb":true}}}}"#,
        )
        .unwrap_err();
        assert!(err.contains("persist.usb"), "{err}");
        let files = BoardSpec::from_json_str(
            r#"{"schema_version":1,"kernel":{"store":{"pglite":{"files":true}}}}"#,
        )
        .unwrap_err();
        assert!(files.contains("pglite.files"), "{files}");
        let bad = BoardSpec::from_json_str(
            r#"{"schema_version":1,"kernel":{"store":{"enable":true,"purposes":["Registry"]}}}"#,
        )
        .unwrap_err();
        assert!(bad.contains("purpose"), "{bad}");
    }

    #[test]
    fn botan_tls_and_adapter_ports() {
        let spec = BoardSpec::from_json_str(
            r#"{
            "schema_version":1,
            "kernel":{"tls":{"enable":true,"https":true}},
            "net_expose":{"mode":"until-delegate","bios_https_port":443,"ssh_holyc_port":2222}
        }"#,
        )
        .unwrap();
        assert!(spec.kernel.tls.rsa && spec.kernel.tls.ecdsa && spec.kernel.tls.certificates);
        assert_eq!(spec.net_expose.bios_https_port, 443);
        assert_eq!(spec.net_expose.ssh_holyc_port, 2222);
        let req = spec.inferred_arch().join("\n");
        assert!(req.contains("RSA PKCS#1"), "{req}");
        assert!(req.contains("ECDSA P-256"), "{req}");
        assert!(req.contains("BIOS HTTPS :443"), "{req}");
        assert!(req.contains("SSH+HolyC :2222"), "{req}");
    }

    #[test]
    fn display_proxy_auto_fps() {
        let spec = BoardSpec::from_json_str(
            r#"{
            "schema_version":1,
            "isa":{"xlen":64,"march":"rv64imac"},
            "kernel":{"gr":{"enable":true,"backend":"hdmi"},
                      "proxy":{"enable":true,"link":"hdmi","dpi":192,"fps":0,"detected_hz":120,"gl":true}}
        }"#,
        )
        .unwrap();
        assert_eq!(spec.kernel.proxy.refresh_hz(), 120);
        assert!(spec.kernel.proxy.gl);
        let hz144 = BoardSpec::from_json_str(
            r#"{"schema_version":1,"kernel":{"proxy":{"enable":true,"link":"host-gl","fps":144}}}"#,
        )
        .unwrap();
        assert_eq!(hz144.kernel.proxy.refresh_hz(), 144);
        let hz100 = BoardSpec::from_json_str(
            r#"{"schema_version":1,"kernel":{"proxy":{"enable":true,"link":"host-gl","fps":100}}}"#,
        )
        .unwrap();
        assert_eq!(hz100.kernel.proxy.refresh_hz(), 100);
        let auto144 = BoardSpec::from_json_str(
            r#"{"schema_version":1,"kernel":{"proxy":{"enable":true,"link":"hdmi","fps":0,"detected_hz":144}}}"#,
        )
        .unwrap();
        assert_eq!(auto144.kernel.proxy.refresh_hz(), 144);
        let req = spec.inferred_arch().join("\n");
        assert!(req.contains("display-proxy"), "{req}");
        assert!(req.contains("HDMI"), "{req}");
    }

    #[test]
    fn display_outputs_rank_pcie_over_uncore_over_virtio_over_none() {
        let spec = BoardSpec::from_json_str(
            r#"{
            "schema_version":1,
            "isa":{"xlen":64,"march":"rv64imac"},
            "kernel":{"gr":{"enable":true,"backend":"hdmi"},
                      "proxy":{"enable":true,"link":"hdmi","dpi":192,"high_w":1920,"high_h":1080}},
            "pcie":{"scan_display":true,"ecam":"0x30000000","mmio":"0x60000000","mmio_len":"0x10000000"},
            "peripherals":[{"id":"hdmi0","class":"display","model":"g6lc-scanout","base":"0x40003000"}]
        }"#,
        )
        .unwrap();
        let ids: Vec<_> = spec
            .display_outputs()
            .iter()
            .map(|o| (o.id.clone(), o.class))
            .collect();
        assert_eq!(
            ids,
            vec![
                ("pcie0".into(), OutputClass::PcieLinearFb),
                ("disp0".into(), OutputClass::UncoreScanout),
                ("vga0".into(), OutputClass::None),
            ],
            "a declared uncore engine takes the link from virtio-gpu"
        );
        assert_eq!(spec.default_output().class, OutputClass::PcieLinearFb);
        assert_eq!(spec.default_surface(), Surface::Gpu);
        assert!(spec.surface_toggle());
        assert!(spec.wants_pci_scan());
        let req = spec.inferred_arch().join("\n");
        assert!(req.contains("pcie0=pcie-linear-fb"), "{req}");
        // Both refusals must be stated, not implied.
        assert!(req.contains("AtomBIOS"), "{req}");
        assert!(req.contains("HPD"), "{req}");
    }

    #[test]
    fn pcie_scan_refuses_a_bar_window_that_swallows_a_peripheral() {
        // QEMU virt puts the 32-bit PCIe MMIO window at 0x40000000, which is
        // exactly where the ai-island GEMM block lives. The two cannot
        // coexist, and that must be a refusal rather than a runtime surprise.
        let err = BoardSpec::from_json_str(
            r#"{
            "schema_version":1,
            "isa":{"xlen":64,"march":"rv64imac"},
            "kernel":{"gr":{"enable":true,"backend":"virtio-gpu"}},
            "pcie":{"scan_display":true,"ecam":"0x30000000","mmio":"0x40000000","mmio_len":"0x40000000"},
            "peripherals":[{"id":"ai0","class":"ai-island","model":"g6lc","base":"0x40000000"}]
        }"#,
        )
        .unwrap_err();
        assert!(err.contains("ai0"), "{err}");
        assert!(err.contains("PCIe MMIO window"), "{err}");
        // Moving the window off the ai-island makes it legal again.
        let spec = BoardSpec::from_json_str(
            r#"{
            "schema_version":1,
            "isa":{"xlen":64,"march":"rv64imac"},
            "kernel":{"gr":{"enable":true,"backend":"virtio-gpu"}},
            "pcie":{"scan_display":true,"ecam":"0x30000000","mmio":"0x60000000","mmio_len":"0x10000000"},
            "peripherals":[{"id":"ai0","class":"ai-island","model":"g6lc","base":"0x40000000"}]
        }"#,
        )
        .unwrap();
        assert_eq!(spec.pcie_mmio_window(), Some((0x6000_0000, 0x1000_0000)));
    }

    #[test]
    fn pcie_scan_and_surface_fail_closed_on_incomplete_input() {
        for (json, want) in [
            (
                r#"{"schema_version":1,"isa":{"xlen":64},"kernel":{"gr":{"enable":true}},"pcie":{"scan_display":true}}"#,
                "pcie.ecam",
            ),
            (
                r#"{"schema_version":1,"isa":{"xlen":64},"kernel":{"gr":{"enable":true}},"pcie":{"scan_display":true,"ecam":"0x30000000"}}"#,
                "pcie.mmio",
            ),
            (
                r#"{"schema_version":1,"isa":{"xlen":64},"kernel":{"proxy":{"enable":true,"surface":"opengl"}}}"#,
                "proxy.surface",
            ),
        ] {
            let err = BoardSpec::from_json_str(json).unwrap_err();
            assert!(err.contains(want), "expected {want} in {err}");
        }
    }

    #[test]
    fn explicit_surface_overrides_the_output_default() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
            "kernel":{"gr":{"enable":true,"backend":"virtio-gpu"},
                      "proxy":{"enable":true,"link":"virtio-gpu","surface":"vga"}}}"#,
        )
        .unwrap();
        assert_eq!(spec.default_output().class, OutputClass::VirtioGpu);
        assert_eq!(
            spec.default_surface(),
            Surface::Vga,
            "an explicit surface wins over the class default"
        );
    }

    #[test]
    fn proxy_accel_rvv_and_ai_island_are_optional() {
        assert!(BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"kernel":{"proxy":{"enable":true,"link":"host-gl","gl":true,"accel":"rvv"}}}"#
        )
        .is_err());
        let rvv = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64,"extensions":{"v":"live"}},
            "kernel":{"proxy":{"enable":true,"link":"host-gl","gl":true,"accel":"rvv"}}}"#,
        )
        .unwrap();
        assert_eq!(rvv.proxy_accel(), ProxyAccel::Rvv);
        let ai = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
            "peripherals":[{"id":"ai0","class":"ai-island","model":"g6","base":"0x40000000"}],
            "kernel":{"proxy":{"enable":true,"link":"host-gl","gl":true,"accel":"ai-island"}}}"#,
        )
        .unwrap();
        assert_eq!(ai.proxy_accel(), ProxyAccel::AiIsland);
        assert!(ai.has_ai_island());
        let req = ai.inferred_arch().join("\n");
        assert!(req.contains("ai-island"), "{req}");
        let auto = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64,"extensions":{"v":"live"}},
            "kernel":{"proxy":{"enable":true,"link":"host-gl","gl":true,"accel":"auto"}}}"#,
        )
        .unwrap();
        assert_eq!(auto.proxy_accel(), ProxyAccel::Rvv);
    }

    #[test]
    fn net_expose_always_needs_bmc_island() {
        let err = BoardSpec::from_json_str(
            r#"{
            "schema_version":1,
            "postboot":{"enable":"runtime","access":"kvm","always_on_domain":true},
            "net_expose":{"mode":"always"}
        }"#,
        )
        .unwrap_err();
        assert!(err.contains("bmc-island"), "{err}");
    }
}
