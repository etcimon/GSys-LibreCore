// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Inferred BIOS setup menus. One model, two presentations:
//! HolyC-UI (CLI `Menu*`) and browser-UI (svelte-d `fetch /bios/menu/*`).

#![allow(missing_docs)]

use crate::{BoardSpec, ExtStatus};

/// One setup screen inferred from BoardSpec (CPU, uncore, boot, …).
#[derive(Debug, Clone)]
pub struct Menu {
    pub id: &'static str,
    pub title: &'static str,
    pub items: Vec<MenuItem>,
}

/// One row on a setup screen.
#[derive(Debug, Clone)]
pub struct MenuItem {
    pub id: String,
    pub label: String,
    pub value: String,
    /// Firmware setup is mostly a view of compiled RTL; writable is rare.
    pub writable: bool,
}

impl MenuItem {
    fn row(id: &str, label: &str, value: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            label: label.into(),
            value: value.into(),
            writable: false,
        }
    }
}

impl Menu {
    pub fn json(&self) -> String {
        let items: Vec<String> = self
            .items
            .iter()
            .map(|i| {
                format!(
                    "{{\"id\":{},\"label\":{},\"value\":{},\"writable\":{}}}",
                    crate::quote_json(&i.id),
                    crate::quote_json(&i.label),
                    crate::quote_json(&i.value),
                    if i.writable { "true" } else { "false" }
                )
            })
            .collect();
        format!(
            "{{\"id\":\"{}\",\"title\":\"{}\",\"items\":[{}]}}",
            self.id,
            self.title,
            items.join(",")
        )
    }
}

/// What a writable setup row accepts. Firmware setup is mostly a view of
/// compiled RTL, so the writable set is small and every entry names the
/// BoardSpec path an exported patch writes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SettingKind {
    Bool,
    U32 { min: u32, max: u32 },
    Enum(&'static [&'static str]),
    Text { max: usize },
}

/// One writable setup row: menu, row id, BoardSpec path, accepted values.
#[derive(Debug, Clone, Copy)]
pub struct Writable {
    pub menu: &'static str,
    pub id: &'static str,
    /// Dotted BoardSpec path an exported settings patch writes.
    pub path: &'static str,
    pub kind: SettingKind,
}

const NEXT_STAGES: &[&str] = &["opensbi", "edk2", "u-boot"];
const HOTKEYS: &[&str] = &["DEL", "F2", "ESC", "F10"];
const CLI_BOOT: &[&str] = &["cli", "auto"];
const START_MENUS: &[&str] = &[
    "main", "cpu", "memory", "uncore", "devices", "boot", "settings",
];

/// The writable BIOS settings. Everything else on a setup screen is a view of
/// what was compiled, and saying otherwise would be a lie to the operator.
pub const WRITABLE: &[Writable] = &[
    Writable {
        menu: "boot",
        id: "next",
        path: "kernel.params.next",
        kind: SettingKind::Enum(NEXT_STAGES),
    },
    Writable {
        menu: "boot",
        id: "hotkey",
        path: "entry.hotkey",
        kind: SettingKind::Enum(HOTKEYS),
    },
    Writable {
        menu: "boot",
        id: "timeout_ms",
        path: "entry.timeout_ms",
        kind: SettingKind::U32 {
            min: 0,
            max: 60_000,
        },
    },
    Writable {
        menu: "boot",
        id: "volume",
        path: "kernel.flash.backend",
        kind: SettingKind::Enum(&["spi-nor", "mailbox", "usb"]),
    },
    Writable {
        menu: "boot",
        id: "autoboot_timeout",
        path: "kernel.cli.autoboot.timeout_ms",
        kind: SettingKind::U32 {
            min: 0,
            max: 60_000,
        },
    },
    Writable {
        menu: "boot",
        id: "autoboot_order",
        path: "kernel.cli.autoboot.order",
        kind: SettingKind::Enum(crate::BOOT_ORDERS),
    },
    Writable {
        menu: "cpu",
        id: "cpu_hz",
        path: "kernel.params.cpu_hz",
        kind: SettingKind::U32 {
            min: 1_000_000,
            max: 4_000_000_000,
        },
    },
    Writable {
        menu: "devices",
        id: "uart_baud",
        path: "kernel.params.uart_baud",
        kind: SettingKind::Enum(&["9600", "19200", "38400", "57600", "115200", "921600"]),
    },
    Writable {
        menu: "settings",
        id: "start_menu",
        path: "kernel.browser.start_menu",
        kind: SettingKind::Enum(START_MENUS),
    },
    Writable {
        menu: "settings",
        id: "cli_boot",
        path: "kernel.cli.boot",
        kind: SettingKind::Enum(CLI_BOOT),
    },
    Writable {
        menu: "settings",
        id: "cli_mouse",
        path: "kernel.cli.mouse",
        kind: SettingKind::Bool,
    },
    Writable {
        menu: "settings",
        id: "cli_rows",
        path: "kernel.cli.rows",
        kind: SettingKind::U32 { min: 10, max: 60 },
    },
    Writable {
        menu: "settings",
        id: "cli_cols",
        path: "kernel.cli.cols",
        kind: SettingKind::U32 { min: 40, max: 200 },
    },
    Writable {
        menu: "settings",
        id: "cli_scrollback",
        path: "kernel.cli.scrollback",
        kind: SettingKind::U32 { min: 10, max: 8192 },
    },
    Writable {
        menu: "settings",
        id: "fw_url",
        path: "kernel.flash.url",
        kind: SettingKind::Text { max: 200 },
    },
];

impl SettingKind {
    /// Accepted-value spelling for `man` / `set` diagnostics.
    pub fn describe(self) -> String {
        match self {
            Self::Bool => "yes|no".into(),
            Self::U32 { min, max } => format!("{min}..={max}"),
            Self::Enum(list) => list.join("|"),
            Self::Text { max } => format!("text (<= {max} chars)"),
        }
    }

    /// Canonical value, or why it was refused. Fail closed: firmware never
    /// stores a value it could not parse.
    pub fn canonical(self, value: &str) -> Result<String, String> {
        let v = value.trim();
        match self {
            Self::Bool => match v.to_ascii_lowercase().as_str() {
                "yes" | "true" | "on" | "1" => Ok("yes".into()),
                "no" | "false" | "off" | "0" => Ok("no".into()),
                _ => Err("expected yes or no".into()),
            },
            Self::U32 { min, max } => {
                let n: u32 = v.parse().map_err(|_| format!("expected {min}..={max}"))?;
                if (min..=max).contains(&n) {
                    Ok(n.to_string())
                } else {
                    Err(format!("expected {min}..={max}"))
                }
            }
            Self::Enum(list) => list
                .iter()
                .find(|o| o.eq_ignore_ascii_case(v))
                .map(|o| (*o).to_string())
                .ok_or_else(|| format!("expected one of {}", list.join(", "))),
            Self::Text { max } => {
                if v.is_empty() {
                    return Err("expected a value".into());
                }
                if v.chars().count() > max {
                    return Err(format!("longer than {max} chars"));
                }
                if v.chars().any(|c| c.is_control() || c == '"' || c == '\\') {
                    return Err("control characters and quotes are refused".into());
                }
                Ok(v.to_string())
            }
        }
    }
}

impl BoardSpec {
    /// Keyboard the CLI reads. A USB HID keyboard is the primary source on
    /// real hardware; virtio-keyboard is the virtual stand-in; the UART band
    /// is the always-there fallback.
    pub fn keyboard_kind(&self) -> &'static str {
        if self.kernel.hw.enable && self.kernel.usb.enable {
            "usb-hid"
        } else if self.wants_virtio_input() {
            "virtio-keyboard"
        } else {
            "uart"
        }
    }

    /// The writable row `menu.id`, if that row can be written at all.
    pub fn writable(&self, menu: &str, id: &str) -> Option<&'static Writable> {
        WRITABLE.iter().find(|w| w.menu == menu && w.id == id)
    }

    /// Writable rows the compiled feature set actually exposes.
    pub fn writables(&self) -> Vec<&'static Writable> {
        WRITABLE
            .iter()
            .filter(|w| {
                self.menu(w.menu)
                    .is_some_and(|m| m.items.iter().any(|i| i.id == w.id))
            })
            .collect()
    }

    /// Topology spelling for menus / boot log: smt, stream, smt-stream, or unicore.
    pub fn topology_kind(&self) -> &'static str {
        match (self.smt(), self.geo.stream) {
            (true, true) => "smt-stream",
            (true, false) => "smt",
            (false, true) => "stream",
            (false, false) => "unicore",
        }
    }

    pub fn smt(&self) -> bool {
        self.threads > 1
    }

    pub fn multi_core(&self) -> bool {
        self.cores > 1
    }

    pub fn hypervisor_live(&self) -> bool {
        self.isa.h == ExtStatus::Live && self.isa.xlen == 64
    }

    /// Setup tree inferred from ISA / topology / uncore / boot. Shared by both
    /// UIs. `writable` is stamped from [`WRITABLE`] in one place so the CLI
    /// `set` path and the browser-UI rows can never disagree.
    pub fn menus(&self) -> Vec<Menu> {
        let mut menus = vec![
            menu_main(self),
            menu_cpu(self),
            menu_memory(self),
            menu_uncore(self),
            menu_devices(self),
            menu_boot(self),
            menu_settings(self),
        ];
        for m in &mut menus {
            for item in &mut m.items {
                item.writable = WRITABLE.iter().any(|w| w.menu == m.id && w.id == item.id);
            }
        }
        menus
    }

    pub fn menu(&self, id: &str) -> Option<Menu> {
        self.menus().into_iter().find(|m| m.id == id)
    }

    pub fn menus_index_json(&self) -> String {
        let parts: Vec<String> = self
            .menus()
            .iter()
            .map(|m| format!("{{\"id\":\"{}\",\"title\":\"{}\"}}", m.id, m.title))
            .collect();
        format!("{{\"menus\":[{}]}}", parts.join(","))
    }

    /// The `{url → body}` read set the shipped UI cell fetches during boot —
    /// `/bios/menu/<id>` per menu (body = the `items[]` row array the guest
    /// parses, not the envelope) plus `/bios/store`. Single source for the
    /// `__kget` packer (`g6b_kernel::kget_pack`) and the guest-JIT exec test,
    /// so the baked table matches the live `KernelGet` router byte-for-byte.
    pub fn kget_fetch_entries(&self) -> Vec<(String, String)> {
        let mut entries: Vec<(String, String)> = Vec::new();
        for m in self.menus() {
            let url = format!("/bios/menu/{}", m.id);
            let body = crate::parse_json(&m.json())
                .ok()
                .and_then(|j| match j.get("items") {
                    crate::Json::Arr(_) => Some(crate::stringify_json(j.get("items"))),
                    _ => None,
                })
                .unwrap_or_else(|| m.json());
            entries.push((url, body));
        }
        entries.push(("/bios/store".to_string(), "[]".to_string()));
        entries
    }
}

fn live(st: ExtStatus) -> &'static str {
    match st {
        ExtStatus::Live => "live",
        ExtStatus::Stub => "stub",
        ExtStatus::Absent => "absent",
    }
}

fn yn(b: bool) -> &'static str {
    if b {
        "yes"
    } else {
        "no"
    }
}

fn menu_main(spec: &BoardSpec) -> Menu {
    Menu {
        id: "main",
        title: "Main",
        items: vec![
            MenuItem::row("product", "Product", &spec.product),
            MenuItem::row("profile", "BIOS profile", spec.kernel.profile.as_str()),
            MenuItem::row("xlen", "XLEN", spec.isa.xlen.to_string()),
            MenuItem::row("march", "ISA", &spec.isa.march),
            MenuItem::row("mmu", "MMU", &spec.isa.mmu),
        ],
    }
}

fn menu_cpu(spec: &BoardSpec) -> Menu {
    Menu {
        id: "cpu",
        title: "CPU",
        items: vec![
            MenuItem::row("cores", "Cores", spec.cores.to_string()),
            MenuItem::row("threads", "Threads/core", spec.threads.to_string()),
            MenuItem::row("harts", "Logical harts", spec.harts.to_string()),
            MenuItem::row("topology", "Topology", spec.topology_kind()),
            MenuItem::row("smt", "SMT", yn(spec.smt())),
            MenuItem::row("stream", "Stream plane", yn(spec.geo.stream)),
            MenuItem::row("issue", "Issue ports", spec.geo.issue_ports.to_string()),
            MenuItem::row("ooo", "Out-of-order", yn(spec.geo.ooo)),
            MenuItem::row("hypervisor", "Hypervisor (H)", live(spec.isa.h)),
            MenuItem::row("rvv", "RVV", live(spec.isa.v)),
            MenuItem::row("zkne", "Zkne (AES)", live(spec.isa.zkne)),
            MenuItem::row("zknh", "Zknh (SHA)", live(spec.isa.zknh)),
            MenuItem::row("zbkc", "Zbkc (clmul)", live(spec.isa.zbkc)),
            MenuItem::row("cpu_hz", "CPU Hz", spec.kernel.params.cpu_hz.to_string()),
            MenuItem::row("gl_accel", "GL accel", spec.proxy_accel().as_str()),
        ],
    }
}

fn menu_memory(spec: &BoardSpec) -> Menu {
    Menu {
        id: "memory",
        title: "Memory",
        items: vec![
            MenuItem::row("dram_base", "DRAM base", &spec.dram_base),
            MenuItem::row("dram_len", "DRAM length", &spec.dram_len),
            MenuItem::row("ddr", "DDR controller", yn(spec.uncore.ddr)),
            MenuItem::row("text_offset", "Text offset", &spec.text_offset),
        ],
    }
}

fn menu_uncore(spec: &BoardSpec) -> Menu {
    Menu {
        id: "uncore",
        title: "Uncore",
        items: vec![
            MenuItem::row("clint", "CLINT/ACLINT", yn(spec.uncore.clint)),
            MenuItem::row("plic", "PLIC", yn(spec.uncore.plic)),
            MenuItem::row("ddr", "DDR", yn(spec.uncore.ddr)),
            MenuItem::row("pcie", "PCIe RC", yn(spec.uncore.pcie)),
            MenuItem::row(
                "display_out",
                "Display output",
                spec.default_output().class.as_str(),
            ),
            MenuItem::row(
                "display_surface",
                "UI surface",
                spec.default_surface().as_str(),
            ),
            MenuItem::row("ethernet", "Ethernet MAC", yn(spec.uncore.ethernet)),
            MenuItem::row("storage", "Storage (SATA/NVMe/SD)", yn(spec.uncore.storage)),
            MenuItem::row("hdmi", "HDMI/DP", yn(spec.uncore.hdmi)),
            MenuItem::row("usb", "USB host", yn(spec.kernel.usb.enable)),
        ],
    }
}

fn menu_devices(spec: &BoardSpec) -> Menu {
    let mut items = vec![
        MenuItem::row(
            "sbi",
            "SBI",
            yn(spec.connectors.core.iter().any(|c| c == "sbi")),
        ),
        MenuItem::row("uart", "UART", yn(has_class(spec, "uart"))),
        MenuItem::row(
            "spi",
            "SPI",
            yn(has_class(spec, "blk") || spec.connectors.apu.iter().any(|c| c == "spi")),
        ),
        MenuItem::row("gpio", "GPIO", yn(has_class(spec, "gpio"))),
        MenuItem::row(
            "pmu",
            "PMU",
            yn(spec.connectors.core.iter().any(|c| c == "pmu")),
        ),
        MenuItem::row(
            "uart_baud",
            "UART baud",
            spec.kernel.params.uart_baud.to_string(),
        ),
        MenuItem::row("keyboard", "Keyboard", spec.keyboard_kind()),
        MenuItem::row(
            "pointer",
            "Pointer",
            if spec.kernel.cli.mouse {
                "optional (CLI mouse on)"
            } else {
                "keyboard-only"
            },
        ),
    ];
    for p in &spec.peripherals {
        items.push(MenuItem::row(
            &p.id,
            &format!("{} {}", p.class, p.model),
            &p.base,
        ));
    }
    Menu {
        id: "devices",
        title: "Devices",
        items,
    }
}

fn menu_boot(spec: &BoardSpec) -> Menu {
    Menu {
        id: "boot",
        title: "Boot",
        items: vec![
            MenuItem::row("next", "Next stage", &spec.kernel.params.next),
            MenuItem::row("edk2", "EDK2 view", yn(spec.kernel.params.edk2)),
            MenuItem::row("uboot", "U-Boot view", yn(spec.kernel.params.uboot)),
            MenuItem::row("flash", "Flash", yn(spec.kernel.flash.enable)),
            MenuItem::row("flash_backend", "Flash backend", &spec.kernel.flash.backend),
            // The edk2/u-boot selector writes this: which volume/device the
            // next stage and a firmware update are taken from.
            MenuItem::row("volume", "Boot volume", &spec.kernel.flash.backend),
            MenuItem::row(
                "autoboot",
                "Autoboot picker",
                yn(spec.kernel.cli.autoboot.enable),
            ),
            MenuItem::row(
                "autoboot_timeout",
                "Autoboot countdown ms",
                spec.kernel.cli.autoboot.timeout_ms.to_string(),
            ),
            MenuItem::row(
                "autoboot_order",
                "Autoboot order",
                spec.boot_order().as_str(),
            ),
            MenuItem::row(
                "autoboot_bios_ui",
                "Autoboot offers BIOS UI",
                yn(spec.autoboot_offers_bios_ui()),
            ),
            MenuItem::row("hotkey", "Setup hotkey", &spec.entry.hotkey),
            MenuItem::row(
                "timeout_ms",
                "Timeout ms",
                spec.entry.timeout_ms.to_string(),
            ),
        ],
    }
}

fn menu_settings(spec: &BoardSpec) -> Menu {
    Menu {
        id: "settings",
        title: "Settings",
        items: vec![
            MenuItem::row("ui", "UI backend", &spec.kernel.ui),
            // One bundle, one row: wasm+js+dom+render+css never split.
            MenuItem::row(
                "web",
                "Web stack (wasm+js+dom+render+css)",
                yn(spec.web_stack()),
            ),
            MenuItem::row("js", "JavaScript", &spec.kernel.js),
            MenuItem::row("start_menu", "Initial menu", &spec.kernel.start_menu),
            MenuItem::row("cli", "ZealOS CLI", yn(spec.kernel.cli.enable)),
            MenuItem::row("cli_boot", "CLI boot order", &spec.kernel.cli.boot),
            MenuItem::row(
                "cli_first",
                "CLI before web stack",
                yn(spec.cli_before_web()),
            ),
            MenuItem::row("cli_mouse", "CLI mouse", yn(spec.kernel.cli.mouse)),
            MenuItem::row("cli_rows", "CLI rows", spec.kernel.cli.rows.to_string()),
            MenuItem::row("cli_cols", "CLI columns", spec.kernel.cli.cols.to_string()),
            MenuItem::row(
                "cli_scrollback",
                "CLI scrollback",
                spec.kernel.cli.scrollback.to_string(),
            ),
            MenuItem::row("cli_manual", "CLI manual", yn(spec.kernel.cli.manual)),
            MenuItem::row(
                "cli_vi",
                "CLI viewer (read-only vi)",
                yn(spec.kernel.cli.vi),
            ),
            MenuItem::row("cli_fs", "CLI volume explorer", yn(spec.kernel.cli.fs)),
            MenuItem::row("cli_fw", "CLI firmware update", yn(spec.kernel.cli.fw)),
            MenuItem::row(
                "fw_url",
                "Firmware update URL (https)",
                if spec.kernel.flash.url.is_empty() {
                    "(usb key)"
                } else {
                    spec.kernel.flash.url.as_str()
                },
            ),
            MenuItem::row("wasm", "WASM", yn(spec.kernel.wasm.enable)),
            MenuItem::row("wasm_jit", "WASM RISC-V lowering", yn(spec.kernel.wasm.jit)),
            MenuItem::row(
                "tasking",
                "Cooperative task services",
                yn(spec.kernel.tasking.enable),
            ),
            MenuItem::row(
                "ui_hart",
                "UI hart",
                spec.kernel.tasking.ui_hart.to_string(),
            ),
            MenuItem::row(
                "task_limit",
                "Task limit",
                spec.kernel.tasking.max_tasks.to_string(),
            ),
            MenuItem::row(
                "worker_limit",
                "Compute worker limit",
                spec.worker_limit().to_string(),
            ),
            MenuItem::row(
                "task_stack",
                "Task stack bytes",
                spec.kernel.tasking.stack_bytes.to_string(),
            ),
            MenuItem::row("export", "Export", yn(spec.kernel.settings.export)),
            MenuItem::row("import", "Import", yn(spec.kernel.settings.import)),
            MenuItem::row("uart", "via UART", yn(spec.kernel.settings.uart)),
            MenuItem::row("mailbox", "via mailbox", yn(spec.kernel.settings.mailbox)),
            MenuItem::row("usb_key", "via USB key", yn(spec.kernel.settings.usb_key)),
            MenuItem::row("store", "Structured store", yn(spec.kernel.store.enable)),
            MenuItem::row(
                "store_memory",
                "Store memory",
                yn(spec.kernel.store.persist_memory),
            ),
            MenuItem::row(
                "store_elf",
                "Store ELF seed",
                yn(spec.kernel.store.persist_elf),
            ),
            MenuItem::row(
                "store_usb",
                "Store USB dump",
                yn(spec.kernel.store.persist_usb),
            ),
        ],
    }
}

fn has_class(spec: &BoardSpec, class: &str) -> bool {
    spec.peripherals.iter().any(|p| p.class == class)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kget_dump() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        for (u, b) in spec.kget_fetch_entries() {
            eprintln!("KGET {u} len={} body={}", b.len(), b);
        }
    }

    #[test]
    fn tasking_limits_are_opt_in_topology_bound_and_shared() {
        let defaults = BoardSpec::default();
        assert_eq!(defaults.worker_limit(), 0);
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"harts":{"cores":4,"threads":2},"kernel":{"tasking":{"enable":true,"ui_hart":1,"max_tasks":16,"max_workers":4,"stack_bytes":8192}}}"#).unwrap();
        assert_eq!(spec.worker_limit(), 4);
        let settings = spec.menu("settings").unwrap();
        assert!(settings
            .items
            .iter()
            .any(|item| item.id == "worker_limit" && item.value == "4"));
        for config in [
            r#"{"ui_hart":8}"#,
            r#"{"max_tasks":2}"#,
            r#"{"max_workers":127,"max_tasks":128}"#,
            r#"{"stack_bytes":4097}"#,
            r#"{"enable":"yes"}"#,
            r#"{"preempt":true}"#,
        ] {
            assert!(BoardSpec::from_json_str(&format!(r#"{{"schema_version":1,"harts":{{"cores":4,"threads":2}},"kernel":{{"tasking":{config}}}}}"#)).is_err(), "{config}");
        }
        let single = BoardSpec::from_json_str(
            r#"{"schema_version":1,"kernel":{"tasking":{"enable":true}}}"#,
        )
        .unwrap();
        assert_eq!(single.worker_limit(), 1);
    }

    #[test]
    fn browser_options_are_shared_and_validated() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"kernel":{"browser":{"js":"off","start_menu":"cpu"}}}"#,
        )
        .unwrap();
        assert_eq!(spec.kernel.start_menu, "cpu");
        let settings = spec.menu("settings").unwrap();
        assert_eq!(
            settings.items.iter().find(|i| i.id == "js").unwrap().value,
            "off"
        );
        for src in [
            r#"{"schema_version":1,"kernel":{"browser":{"js":"goja"}}}"#,
            r#"{"schema_version":1,"kernel":{"browser":{"start_menu":"bad"}}}"#,
            r#"{"schema_version":1,"http":{"files":{"root":"//remote/ui"}}}"#,
            r#"{"schema_version":1,"http":{"files":{"root":"/ui/../bios"}}}"#,
            r#"{"schema_version":1,"http":{"files":{"root":"/ui\""}}}"#,
        ] {
            assert!(BoardSpec::from_json_str(src).is_err(), "{src}");
        }
    }

    #[test]
    fn writable_rows_are_the_only_settable_ones() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        // Every WRITABLE entry must name a row that exists on that screen.
        for w in WRITABLE {
            let menu = spec
                .menu(w.menu)
                .unwrap_or_else(|| panic!("menu {}", w.menu));
            let item = menu
                .items
                .iter()
                .find(|i| i.id == w.id)
                .unwrap_or_else(|| panic!("row {}.{}", w.menu, w.id));
            assert!(item.writable, "{}.{} must be writable", w.menu, w.id);
        }
        // …and a view row stays a view row.
        let cpu = spec.menu("cpu").unwrap();
        assert!(!cpu.items.iter().find(|i| i.id == "cores").unwrap().writable);
        assert!(
            cpu.items
                .iter()
                .find(|i| i.id == "cpu_hz")
                .unwrap()
                .writable
        );
        let boot = spec.menu("boot").unwrap();
        assert!(boot.items.iter().any(|i| i.id == "volume" && i.writable));
        assert!(spec.writable("boot", "next").is_some());
        assert!(spec.writable("cpu", "cores").is_none());
        assert!(spec.writables().len() >= WRITABLE.len() - 1);
    }

    #[test]
    fn setting_kinds_fail_closed() {
        let next = WRITABLE.iter().find(|w| w.id == "next").unwrap();
        assert_eq!(next.kind.canonical("EDK2").unwrap(), "edk2");
        assert!(next.kind.canonical("grub").is_err());
        let t = WRITABLE.iter().find(|w| w.id == "timeout_ms").unwrap();
        assert_eq!(t.kind.canonical(" 3000 ").unwrap(), "3000");
        assert!(t.kind.canonical("90000").is_err());
        assert!(t.kind.canonical("soon").is_err());
        let m = WRITABLE.iter().find(|w| w.id == "cli_mouse").unwrap();
        assert_eq!(m.kind.canonical("on").unwrap(), "yes");
        assert_eq!(m.kind.canonical("0").unwrap(), "no");
        assert!(m.kind.canonical("maybe").is_err());
        let url = WRITABLE.iter().find(|w| w.id == "fw_url").unwrap();
        assert!(url.kind.canonical("https://gsys.dev/fw.elf").is_ok());
        assert!(url.kind.canonical("").is_err());
        assert!(url.kind.canonical("https://a\"b").is_err());
        assert!(!m.kind.describe().is_empty());
    }

    #[test]
    fn firmware_url_is_https_only() {
        let ok = BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"barebone","kernel":{"flash":{"url":"https://fw.gsys.dev/g6lc_bios.elf"}}}"#,
        )
        .unwrap();
        assert!(ok.kernel.flash.url.starts_with("https://"));
        let settings = ok.menu("settings").unwrap();
        assert!(settings
            .items
            .iter()
            .any(|i| i.id == "fw_url" && i.value.contains("fw.gsys.dev") && i.writable));
        let err = BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"barebone","kernel":{"flash":{"url":"http://fw.gsys.dev/x.elf"}}}"#,
        )
        .unwrap_err();
        assert!(err.contains("https"), "{err}");
    }

    #[test]
    fn keyboard_is_usb_first_then_virtio_then_uart() {
        let full = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        assert_eq!(full.keyboard_kind(), "usb-hid");
        let bare =
            BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"barebone"}"#).unwrap();
        assert_eq!(bare.keyboard_kind(), "usb-hid");
        let no_usb = BoardSpec::from_json_str(
            r#"{"schema_version":1,"kernel":{"usb":{"enable":false},"hw":{"enable":true}}}"#,
        )
        .unwrap();
        assert!(matches!(no_usb.keyboard_kind(), "virtio-keyboard" | "uart"));
        let devices = full.menu("devices").unwrap();
        assert!(devices
            .items
            .iter()
            .any(|i| i.id == "keyboard" && i.value == "usb-hid"));
        assert!(devices
            .items
            .iter()
            .any(|i| i.id == "uart_baud" && i.writable));
    }

    #[test]
    fn menu_json_roundtrips_user_strings() {
        let spec = BoardSpec {
            product: "Board \"α\"\\test\n".into(),
            ..BoardSpec::default()
        };
        let json = crate::parse_json(&spec.menu("main").unwrap().json()).unwrap();
        let crate::Json::Arr(items) = json.get("items") else {
            panic!("items")
        };
        assert_eq!(items[0].get("value").as_str(), Some(spec.product.as_str()));
    }

    #[test]
    fn smt2_infers_cpu_menu() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"harts":{"count":2}}"#,
        )
        .unwrap();
        assert!(spec.smt());
        assert_eq!(spec.cores, 1);
        assert_eq!(spec.threads, 2);
        let cpu = spec.menu("cpu").unwrap();
        let smt = cpu.items.iter().find(|i| i.id == "smt").unwrap();
        assert_eq!(smt.value, "yes");
        assert!(spec.menus_index_json().contains("\"id\":\"uncore\""));
    }
}
