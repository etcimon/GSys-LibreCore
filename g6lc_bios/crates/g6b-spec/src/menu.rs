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
                    "{{\"id\":\"{}\",\"label\":\"{}\",\"value\":\"{}\",\"writable\":{}}}",
                    i.id,
                    i.label,
                    i.value,
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

impl BoardSpec {
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

    /// Setup tree inferred from ISA / topology / uncore / boot. Shared by both UIs.
    pub fn menus(&self) -> Vec<Menu> {
        vec![
            menu_main(self),
            menu_cpu(self),
            menu_memory(self),
            menu_uncore(self),
            menu_devices(self),
            menu_boot(self),
            menu_settings(self),
        ]
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
            MenuItem::row("export", "Export", yn(spec.kernel.settings.export)),
            MenuItem::row("import", "Import", yn(spec.kernel.settings.import)),
            MenuItem::row("uart", "via UART", yn(spec.kernel.settings.uart)),
            MenuItem::row("mailbox", "via mailbox", yn(spec.kernel.settings.mailbox)),
            MenuItem::row("usb_key", "via USB key", yn(spec.kernel.settings.usb_key)),
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
