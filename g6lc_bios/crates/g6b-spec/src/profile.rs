// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Named BIOS build profiles: embedded/router → full browser-UI.

#![allow(missing_docs)]

use crate::{
    BiosParams, BoardSpec, DualBand, Flash, Holyc, HolycTcp, Http, HttpFiles, NetExpose,
    NetExposeMode, PostbootMode, Settings, Tls, Usb, Wasm,
};

/// Compile-time BIOS shape. JSON overlay still wins on explicit fields.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum BiosProfile {
    /// No bundle; BoardSpec fields as written.
    #[default]
    Custom,
    /// UART-only, SPI NOR flash, no browser-UI (low-res SoC).
    Embedded,
    /// Embedded + OpenWrt image flash + settings over UART/mailbox.
    Router,
    /// HTML+JS + HTTPS serve + settings (USB key optional).
    Appliance,
    /// Display-proxy + svelte-d + TLS client (current desktop).
    Desktop,
    /// All compiled features: browser-UI, HTTPS serve, USB key, flash, settings.
    Full,
}

impl BiosProfile {
    /// BoardSpec spelling.
    pub fn parse(s: &str) -> Result<Self, String> {
        Ok(match s {
            "custom" | "" => Self::Custom,
            "embedded" | "lowres" => Self::Embedded,
            "router" => Self::Router,
            "appliance" => Self::Appliance,
            "desktop" => Self::Desktop,
            "full" => Self::Full,
            other => {
                return Err(format!(
                    "unknown profile `{other}`; use embedded, router, appliance, desktop, or full"
                ))
            }
        })
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Custom => "custom",
            Self::Embedded => "embedded",
            Self::Router => "router",
            Self::Appliance => "appliance",
            Self::Desktop => "desktop",
            Self::Full => "full",
        }
    }
}

impl BoardSpec {
    /// Apply a named profile as the baseline (JSON overlay happens after).
    pub fn apply_profile(&mut self, p: BiosProfile) {
        self.kernel.profile = p;
        match p {
            BiosProfile::Custom => {}
            BiosProfile::Embedded => apply_embedded(self),
            BiosProfile::Router => {
                apply_embedded(self);
                apply_router(self);
            }
            BiosProfile::Appliance => apply_appliance(self),
            BiosProfile::Desktop => apply_desktop(self),
            BiosProfile::Full => {
                apply_desktop(self);
                apply_full_extras(self);
            }
        }
    }

    /// Every compiled feature flag (for `/bios/features` and planning).
    pub fn compiled_features(&self) -> Vec<(&'static str, bool)> {
        vec![
            ("gr", self.kernel.gr.enable),
            ("proxy", self.kernel.proxy.enable),
            ("gl", self.kernel.proxy.gl),
            (
                "proxy_accel_rvv",
                self.proxy_accel() == crate::ProxyAccel::Rvv,
            ),
            (
                "proxy_accel_ai",
                self.proxy_accel() == crate::ProxyAccel::AiIsland,
            ),
            ("tls", self.kernel.tls.enable),
            ("https_client", self.kernel.tls.https),
            (
                "https_serve",
                self.kernel.http.serve && self.kernel.tls.https,
            ),
            ("http_files", self.kernel.http.files.enable),
            ("http_files_html", self.kernel.http.files.html),
            ("http_files_js", self.kernel.http.files.js),
            ("http_files_wasm", self.kernel.http.files.wasm),
            ("http_files_assets", self.kernel.http.files.assets),
            (
                "https_files",
                self.kernel.http.files.enable && self.kernel.http.files.https,
            ),
            ("tls_serve", self.kernel.tls.serve),
            ("rsa", self.kernel.tls.rsa),
            ("ecdsa", self.kernel.tls.ecdsa),
            ("certificates", self.kernel.tls.certificates),
            ("http", self.kernel.http.enable),
            ("http1", self.kernel.http.http1),
            ("http2", self.kernel.http.http2),
            ("proxy_js", self.kernel.http.proxy_js),
            ("http_serve", self.kernel.http.serve),
            ("wasm", self.kernel.wasm.enable),
            ("wasm_jit", self.kernel.wasm.jit),
            ("ui_svelte", self.kernel.ui == "svelte-d"),
            ("clocks", self.kernel.params.clocks),
            ("edk2", self.kernel.params.edk2),
            ("uboot", self.kernel.params.uboot),
            ("bootloader", self.kernel.params.bootloader),
            ("flash", self.kernel.flash.enable),
            ("flash_openwrt", self.kernel.flash.openwrt),
            ("flash_self", self.kernel.flash.self_update),
            ("settings", self.kernel.settings.enable),
            ("settings_export", self.kernel.settings.export),
            ("settings_import", self.kernel.settings.import),
            ("settings_uart", self.kernel.settings.uart),
            ("settings_mailbox", self.kernel.settings.mailbox),
            ("settings_usb", self.kernel.settings.usb_key),
            ("usb", self.kernel.usb.enable),
            ("usb_flash_fat32", self.kernel.usb.flash_fat32),
            ("usb_key", self.kernel.usb.key),
            ("fs_fat32", self.kernel.usb.fs_fat32),
            ("fs_ntfs", self.kernel.usb.fs_ntfs),
            ("fs_ext4", self.kernel.usb.fs_ext4),
            ("dual_band_uart", self.holyc.dual_band.uart),
            ("dual_band_tcp", self.holyc.dual_band.tcp.enable),
            ("postboot", self.postboot.enable != PostbootMode::Never),
            ("loopback", self.loopback.enable),
            ("net_expose", self.net_expose.mode != NetExposeMode::Never),
            (
                "kvm_html",
                self.postboot.backends.iter().any(|b| b == "html-js"),
            ),
            (
                "kvm_ssh_holyc",
                self.postboot.backends.iter().any(|b| b == "ssh-holyc"),
            ),
            ("rvv", self.rvv_live()),
            ("hypervisor", self.hypervisor_live()),
            ("smt", self.smt()),
            ("multi_core", self.multi_core()),
            ("multi_issue", self.geo.issue_ports > 1),
            ("ooo", self.geo.ooo),
            ("stream", self.geo.stream),
            ("uncore_clint", self.uncore.clint),
            ("uncore_plic", self.uncore.plic),
            ("uncore_ddr", self.uncore.ddr),
            ("uncore_pcie", self.uncore.pcie),
            ("uncore_eth", self.uncore.ethernet),
            ("uncore_storage", self.uncore.storage),
            ("uncore_hdmi", self.uncore.hdmi),
        ]
    }

    /// JSON object of [`compiled_features`].
    pub fn compiled_features_json(&self) -> String {
        let parts: Vec<String> = self
            .compiled_features()
            .iter()
            .map(|(k, v)| format!("\"{k}\":{}", if *v { "true" } else { "false" }))
            .collect();
        format!("{{{}}}", parts.join(","))
    }
}

fn apply_embedded(spec: &mut BoardSpec) {
    spec.product = "iot".into();
    spec.kernel.ui = "html-js".into();
    spec.kernel.display = "html-js".into();
    spec.kernel.js = "aot".into();
    spec.kernel.gr.enable = false;
    spec.kernel.proxy.enable = false;
    spec.kernel.proxy.gl = false;
    spec.kernel.wasm = Wasm::default();
    spec.kernel.tls = Tls::default();
    spec.kernel.http = Http {
        enable: true,
        http1: true,
        http2: false,
        proxy_js: false,
        serve: false,
        files: HttpFiles::default(),
    };
    spec.kernel.params = BiosParams {
        clocks: true,
        bootloader: true,
        uart_baud: 115_200,
        next: "opensbi".into(),
        ..BiosParams::default()
    };
    spec.kernel.flash = Flash {
        enable: true,
        openwrt: false,
        self_update: true,
        backend: "spi-nor".into(),
        image: "bios".into(),
    };
    spec.kernel.settings = Settings {
        enable: true,
        export: true,
        import: true,
        uart: true,
        mailbox: true,
        usb_key: false,
    };
    spec.kernel.usb = usb_flash_always();
    spec.holyc = Holyc {
        fast_init: true,
        dual_band: DualBand {
            uart: true,
            tcp: HolycTcp {
                enable: false,
                ..HolycTcp::default()
            },
        },
    };
    spec.postboot.enable = PostbootMode::Never;
    spec.net_expose.mode = NetExposeMode::Never;
    spec.loopback.enable = false;
}

fn apply_router(spec: &mut BoardSpec) {
    spec.product = "router".into();
    spec.kernel.flash.openwrt = true;
    spec.kernel.flash.image = "openwrt".into();
    spec.kernel.params.uboot = true;
    spec.kernel.http.serve = true;
    spec.kernel.http.files = files_html_only();
    spec.net_expose = NetExpose {
        mode: NetExposeMode::UntilDelegate,
        via: "adapter".into(),
        web: true,
        ssh_holyc: false,
        bios_https_port: 80,
        ssh_holyc_port: 2222,
    };
}

fn apply_appliance(spec: &mut BoardSpec) {
    spec.product = "appliance".into();
    spec.kernel.ui = "html-js".into();
    spec.kernel.gr.enable = true;
    spec.kernel.gr.backend = "uart".into();
    spec.kernel.proxy.enable = false;
    spec.kernel.wasm = Wasm::default();
    spec.kernel.tls = Tls {
        enable: true,
        https: true,
        serve: true,
        rsa: true,
        ecdsa: true,
        certificates: true,
    };
    spec.kernel.http = Http {
        enable: true,
        http1: true,
        http2: true,
        proxy_js: true,
        serve: true,
        files: files_https_ui(false),
    };
    spec.kernel.params.clocks = true;
    spec.kernel.params.bootloader = true;
    spec.kernel.flash = Flash {
        enable: true,
        openwrt: false,
        self_update: true,
        backend: "mailbox".into(),
        image: "bios".into(),
    };
    spec.kernel.settings = Settings {
        enable: true,
        export: true,
        import: true,
        uart: true,
        mailbox: true,
        usb_key: true,
    };
    spec.kernel.usb = usb_key_fm();
    spec.holyc.dual_band.uart = true;
    spec.holyc.dual_band.tcp.enable = true;
    spec.postboot.enable = PostbootMode::Runtime;
    spec.postboot.access = "kvm".into();
    spec.postboot.always_on_domain = true;
    spec.postboot.backends = vec!["html-js".into()];
    spec.net_expose.mode = NetExposeMode::UntilDelegate;
    spec.net_expose.web = true;
    spec.loopback.enable = true;
}

fn apply_desktop(spec: &mut BoardSpec) {
    spec.product = "desktop".into();
    spec.kernel.ui = "svelte-d".into();
    spec.kernel.gr.enable = true;
    spec.kernel.gr.backend = "virtio-gpu".into();
    spec.kernel.proxy.enable = true;
    spec.kernel.proxy.gl = true;
    spec.kernel.wasm = Wasm {
        enable: true,
        jit: true,
    };
    spec.kernel.tls = Tls {
        enable: true,
        https: true,
        serve: true,
        rsa: true,
        ecdsa: true,
        certificates: true,
    };
    spec.kernel.http = Http {
        enable: true,
        http1: true,
        http2: true,
        proxy_js: true,
        serve: true,
        files: files_https_ui(true),
    };
    spec.kernel.params = BiosParams {
        clocks: true,
        edk2: true,
        uboot: true,
        bootloader: true,
        cpu_hz: 1_000_000_000,
        uart_baud: 115_200,
        edk2_enable: false,
        uboot_enable: false,
        next: "opensbi".into(),
    };
    spec.kernel.flash.self_update = true;
    spec.kernel.flash.enable = true;
    spec.kernel.flash.backend = "mailbox".into();
    spec.kernel.settings = Settings {
        enable: true,
        export: true,
        import: true,
        uart: true,
        mailbox: true,
        usb_key: false,
    };
    spec.kernel.usb = usb_flash_always();
    spec.holyc.dual_band.uart = true;
    spec.holyc.dual_band.tcp.enable = true;
    spec.postboot.enable = PostbootMode::Runtime;
    spec.postboot.access = "kvm".into();
    spec.postboot.always_on_domain = true;
    spec.postboot.backends = vec!["html-js".into(), "ssh-holyc".into()];
    spec.net_expose.mode = NetExposeMode::UntilDelegate;
    spec.net_expose.web = true;
    spec.net_expose.ssh_holyc = true;
    spec.loopback.enable = true;
}

fn apply_full_extras(spec: &mut BoardSpec) {
    spec.kernel.flash.openwrt = true;
    spec.kernel.flash.image = "openwrt".into();
    spec.kernel.settings.usb_key = true;
    spec.kernel.usb = usb_key_fm();
    spec.kernel.http.serve = true;
}

fn files_html_only() -> HttpFiles {
    HttpFiles {
        enable: true,
        html: true,
        js: false,
        wasm: false,
        https: false,
        assets: false,
        root: "/ui".into(),
    }
}

fn files_https_ui(wasm: bool) -> HttpFiles {
    HttpFiles {
        enable: true,
        html: true,
        js: true,
        wasm,
        https: true,
        assets: true,
        root: "/ui".into(),
    }
}

fn usb_flash_always() -> Usb {
    Usb {
        enable: true,
        flash_fat32: true,
        key: false,
        fs_fat32: true,
        fs_ntfs: false,
        fs_ext4: false,
    }
}

fn usb_key_fm() -> Usb {
    Usb {
        enable: true,
        flash_fat32: true,
        key: true,
        fs_fat32: true,
        fs_ntfs: true,
        fs_ext4: true,
    }
}
