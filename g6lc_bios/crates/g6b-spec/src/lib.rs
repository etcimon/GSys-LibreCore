// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! BoardSpec — the only customisation surface for `g6lc_bios`.
//!
//! No crate here reads the SoC RTL tree. A host may *emit* JSON that this
//! parser consumes.

#![allow(missing_docs)]

mod json;
mod menu;
mod profile;

pub use json::{parse_json, Json};
pub use menu::{Menu, MenuItem};
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
        }
    }
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
    /// 30 / 60 / 120 from pin or EDID/DPCD-style detection.
    pub fn refresh_hz(&self) -> u32 {
        match self.fps {
            30 | 60 | 120 => self.fps,
            _ => {
                let d = if self.detected_hz == 0 {
                    60
                } else {
                    self.detected_hz
                };
                if d >= 90 {
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
}

impl Default for Flash {
    fn default() -> Self {
        Self {
            enable: false,
            openwrt: false,
            self_update: false,
            backend: "spi-nor".into(),
            image: "bios".into(),
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
    /// Elaborate file manager on a USB key (FAT32/NTFS/ext4).
    pub key: bool,
    pub fs_fat32: bool,
    pub fs_ntfs: bool,
    pub fs_ext4: bool,
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
        }
    }
}

/// Kernel / display slice.
#[derive(Debug, Clone)]
pub struct Kernel {
    pub shape: String,
    pub gr: Gr,
    pub display: String,
    pub js: String,
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
}

impl Default for Kernel {
    fn default() -> Self {
        Self {
            shape: "zeal".into(),
            gr: Gr::default(),
            display: "html-js".into(),
            js: "aot".into(),
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
            if !matches!(self.kernel.proxy.fps, 0 | 30 | 60 | 120) {
                return Err("kernel.proxy.fps must be 0 (auto), 30, 60, or 120".into());
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
        if self.kernel.ui != "html-js" && self.kernel.ui != "svelte-d" {
            return Err(format!(
                "kernel.ui `{}` refused; use html-js or svelte-d (not sveltekit)",
                self.kernel.ui
            ));
        }
        if self.kernel.wasm.jit && !self.kernel.wasm.enable {
            return Err("kernel.wasm.jit needs kernel.wasm.enable".into());
        }
        if self.kernel.http.serve && !self.kernel.http.enable {
            return Err("kernel.http.serve needs kernel.http.enable".into());
        }
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
        if self.kernel.http.files.enable
            && !self.kernel.http.files.html
            && !self.kernel.http.files.js
            && !self.kernel.http.files.wasm
        {
            return Err("kernel.http.files.enable needs html, js, or wasm".into());
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

    /// True when the generator may emit RVV encodings.
    pub fn rvv_live(&self) -> bool {
        self.isa.v == ExtStatus::Live && self.isa.xlen == 64
    }

    /// True when an `ai-island` peripheral is in the BoardSpec (MMIO `0x40000000`).
    pub fn has_ai_island(&self) -> bool {
        self.peripherals.iter().any(|p| p.class == "ai-island")
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
                req.push("QEMU virt: -device virtio-gpu-device; serial stays -nographic".into());
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
        if self.kernel.http.enable {
            req.push(format!(
                "kernel HTTP endpoints http1={} http2={} js-proxy={} serve={} (not SvelteKit, not a netdev)",
                self.kernel.http.http1, self.kernel.http.http2, self.kernel.http.proxy_js, self.kernel.http.serve
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
                "USB host MSC FAT32 flash={} key-fm={} ntfs={} ext4={} (not a netdev)",
                self.kernel.usb.flash_fat32,
                self.kernel.usb.key,
                self.kernel.usb.fs_ntfs,
                self.kernel.usb.fs_ext4
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
}

fn apply_wasm(w: &mut Wasm, v: &Json) {
    w.enable = v.get("enable").as_bool().unwrap_or(true);
    w.jit = v.get("jit").as_bool().unwrap_or(w.enable);
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
        assert!(spec.kernel.ui == "svelte-d");
        assert!(spec
            .compiled_features()
            .iter()
            .any(|(k, v)| *k == "https_serve" && *v));
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
        let req = spec.inferred_arch().join("\n");
        assert!(req.contains("display-proxy"), "{req}");
        assert!(req.contains("HDMI"), "{req}");
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
