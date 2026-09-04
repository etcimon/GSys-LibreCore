// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! One setup model, two presentations (`architecture/MENUS.md`).
//! HolyC-UI prints; browser-UI `fetch`s the same `/bios/menu/*` JSON.

#![allow(missing_docs)]

use g6b_spec::BoardSpec;

/// Menu vs USB/clocks utility. Same BoardSpec tree either way.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// Inferred setup screen (`spec.menus()`).
    Menu,
    /// Flash / FileMgr / clocks — KERNEL-API utilities.
    Utility,
}

/// One face shown by both HolycUi.ZC and `browser-ui/src/*.svelte`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Face {
    pub id: &'static str,
    pub title: &'static str,
    pub fetch: &'static str,
    pub holyc: &'static str,
    pub holyc_print: &'static str,
    pub svelte: &'static str,
    pub kind: Kind,
}

impl Face {
    /// DOM id the kernel paints after `fetch(self.fetch)`. Empty = skip (keep UI-BOOT).
    pub fn paint_id(self) -> &'static str {
        match self.id {
            "main" => "main-title",
            "cpu" => "cpu-title",
            "memory" => "memory-title",
            "uncore" => "uncore-title",
            "devices" => "devices-title",
            "boot" => "boot-title",
            "settings" | "settings-usb" => "settings-title",
            "flash" => "usb-list",
            "filemgr" => "fm-list",
            _ => "",
        }
    }
}

/// Face whose `fetch` path matches `url` (including `/bios/cpu` aliases).
pub fn face_for_fetch(url: &str) -> Option<&'static Face> {
    match url {
        "/bios/cpu" => MENUS.iter().find(|f| f.id == "cpu"),
        "/bios/uncore" => MENUS.iter().find(|f| f.id == "uncore"),
        _ => MENUS
            .iter()
            .chain(UTILITIES.iter())
            .find(|f| f.fetch == url),
    }
}

/// Compact body for a title node (JSON `title` or a short prefix).
pub fn paint_body(json: &str) -> String {
    if let Some(t) = json_field(json, "title") {
        return t;
    }
    json.chars().filter(|c| *c != '\n').take(80).collect()
}

fn json_field(s: &str, key: &str) -> Option<String> {
    let pat = format!("\"{key}\"");
    let i = s.find(&pat)?;
    let rest = s.get(i + pat.len()..)?;
    let q = rest.find('"')?;
    let rest = rest.get(q + 1..)?;
    let e = rest.find('"')?;
    Some(rest[..e].to_string())
}

/// Setup menus from MENUS.md (main … settings).
pub const MENUS: &[Face] = &[
    Face {
        id: "main",
        title: "Main",
        fetch: "/bios/menu/main",
        holyc: "Menu(\"main\")",
        holyc_print: "MenuMainPrint",
        svelte: "Main.svelte",
        kind: Kind::Menu,
    },
    Face {
        id: "cpu",
        title: "CPU",
        fetch: "/bios/menu/cpu",
        holyc: "MenuCpu()",
        holyc_print: "MenuCpuPrint",
        svelte: "Cpu.svelte",
        kind: Kind::Menu,
    },
    Face {
        id: "memory",
        title: "Memory",
        fetch: "/bios/menu/memory",
        holyc: "Menu(\"memory\")",
        holyc_print: "MenuMemoryPrint",
        svelte: "Memory.svelte",
        kind: Kind::Menu,
    },
    Face {
        id: "uncore",
        title: "Uncore",
        fetch: "/bios/menu/uncore",
        holyc: "MenuUncore()",
        holyc_print: "MenuUncorePrint",
        svelte: "Uncore.svelte",
        kind: Kind::Menu,
    },
    Face {
        id: "devices",
        title: "Devices",
        fetch: "/bios/menu/devices",
        holyc: "Menu(\"devices\")",
        holyc_print: "MenuDevicesPrint",
        svelte: "Devices.svelte",
        kind: Kind::Menu,
    },
    Face {
        id: "boot",
        title: "Boot",
        fetch: "/bios/menu/boot",
        holyc: "Menu(\"boot\")",
        holyc_print: "MenuBootPrint",
        svelte: "Boot.svelte",
        kind: Kind::Menu,
    },
    Face {
        id: "settings",
        title: "Settings",
        fetch: "/bios/menu/settings",
        holyc: "Menu(\"settings\")",
        holyc_print: "MenuSettingsPrint",
        svelte: "Settings.svelte",
        kind: Kind::Menu,
    },
];

/// USB flash, USB-key FileMgr, clocks (KERNEL-API).
pub const UTILITIES: &[Face] = &[
    Face {
        id: "clocks",
        title: "Clocks",
        fetch: "/bios/clocks",
        holyc: "KernelGet(\"clocks\")",
        holyc_print: "ClocksPrint",
        svelte: "App.svelte",
        kind: Kind::Utility,
    },
    Face {
        id: "flash",
        title: "USB-FAT32",
        fetch: "/bios/usb/ls",
        holyc: "UsbLs(\"fat32\")",
        holyc_print: "UsbFlash",
        svelte: "Flash.svelte",
        kind: Kind::Utility,
    },
    Face {
        id: "filemgr",
        title: "USB-FILES",
        fetch: "/bios/files",
        holyc: "UsbKey(\"present\")",
        holyc_print: "UsbLs",
        svelte: "FileMgr.svelte",
        kind: Kind::Utility,
    },
    Face {
        id: "settings-usb",
        title: "Settings USB",
        fetch: "/bios/settings/usb",
        holyc: "KernelGet(\"/bios/settings/usb\")",
        holyc_print: "SettingsUsbPrint",
        svelte: "Settings.svelte",
        kind: Kind::Utility,
    },
];

/// Nav labels painted on `#bios-menu` (HolyC Print order).
pub fn nav_label() -> String {
    MENUS.iter().map(|f| f.title).collect::<Vec<_>>().join(" ")
}

/// `MENU-{id}` boot markers for every setup screen.
pub fn menu_markers() -> Vec<String> {
    MENUS.iter().map(|f| format!("MENU-{}", f.id)).collect()
}

/// Faces shown for this BoardSpec (FileMgr only when `usb.key`).
pub fn faces_for(spec: &BoardSpec) -> Vec<&'static Face> {
    let mut out: Vec<&'static Face> = MENUS.iter().collect();
    out.push(&UTILITIES[0]); // clocks
    if spec.kernel.usb.enable {
        out.push(&UTILITIES[1]); // flash
    }
    if spec.kernel.usb.key {
        out.push(&UTILITIES[2]); // filemgr
    }
    if spec.kernel.settings.enable {
        out.push(&UTILITIES[3]); // settings-usb
    }
    out
}

/// Generated HolyC print bodies from `spec.menus()` (same JSON as fetch).
pub fn holyc_print_src(spec: &BoardSpec) -> String {
    let mut out = String::from(
        "// Generated HolycUi.ZC — CLI setup (not the browser viewport)\n\
         // Separation: HolyC-UI prints menus; browser-UI fetches the same JSON.\n",
    );
    out.push_str(&format!(
        "// topology={} cores={} threads={} issue={} ooo={} stream={} H={} V={}\n",
        spec.topology_kind(),
        spec.cores,
        spec.threads,
        spec.geo.issue_ports,
        spec.geo.ooo as u8,
        spec.geo.stream as u8,
        spec.hypervisor_live() as u8,
        spec.rvv_live() as u8
    ));
    out.push_str("U0 HolycUiInit()\n{\n\tPrint(\"HOLYC-UI\\n\");\n");
    for f in MENUS {
        out.push_str(&format!("\tPrint(\"MENU {} {}\\n\");\n", f.id, f.title));
    }
    out.push_str("}\n");
    for f in MENUS {
        out.push_str(&format!("U0 {}()\n{{\n", f.holyc_print));
        if let Some(m) = spec.menu(f.id) {
            for it in &m.items {
                out.push_str(&format!("\tPrint(\"  {}={}\\n\");\n", it.id, it.value));
            }
        }
        out.push_str(&format!("\tKernelGet(\"{}\");\n}}\n", f.fetch));
    }
    out.push_str("U0 ClocksPrint()\n{\n\tKernelGet(\"/bios/clocks\");\n}\n");
    if spec.kernel.settings.enable {
        out.push_str("U0 SettingsUsbPrint()\n{\n\tKernelGet(\"/bios/settings/usb\");\n}\n");
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn menus_md_ids_match_boardspec() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let ids: Vec<_> = spec.menus().iter().map(|m| m.id).collect();
        let face_ids: Vec<_> = MENUS.iter().map(|f| f.id).collect();
        assert_eq!(ids, face_ids);
        assert!(nav_label().contains("Settings"));
        let faces = faces_for(&spec);
        assert!(faces.iter().any(|f| f.id == "filemgr"));
        assert!(faces.iter().any(|f| f.id == "flash"));
        let src = holyc_print_src(&spec);
        assert!(src.contains("HOLYC-UI"));
        assert!(src.contains("MenuSettingsPrint"));
        assert!(src.contains("/bios/menu/settings"));
        assert!(src.contains("KernelGet(\"/bios/clocks\")"));
    }

    #[test]
    fn embedded_omits_filemgr() {
        let spec =
            BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"embedded"}"#).unwrap();
        let faces = faces_for(&spec);
        assert!(!faces.iter().any(|f| f.id == "filemgr"));
        assert!(faces.iter().any(|f| f.id == "flash"));
    }

    #[test]
    fn fetch_paints_cpu_title() {
        let f = face_for_fetch("/bios/menu/cpu").unwrap();
        assert_eq!(f.paint_id(), "cpu-title");
        assert_eq!(paint_body("{\"id\":\"cpu\",\"title\":\"CPU\"}"), "CPU");
        assert_eq!(face_for_fetch("/bios/cpu").unwrap().id, "cpu");
    }
}
