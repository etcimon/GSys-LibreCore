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
            "settings" => "settings-title",
            "settings-usb" => "settings-usb-value",
            "clocks" => "clocks-value",
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

pub fn menu_for_key(current: &str, key: &str) -> Option<&'static str> {
    let index = MENUS.iter().position(|face| face.id == current)?;
    let next = match key {
        "ArrowLeft" => (index + MENUS.len() - 1) % MENUS.len(),
        "ArrowRight" => (index + 1) % MENUS.len(),
        "Home" => 0,
        "End" => MENUS.len() - 1,
        _ => return None,
    };
    Some(MENUS[next].id)
}

/// `MENU-{id}` boot markers for every setup screen.
pub fn menu_markers() -> Vec<String> {
    MENUS.iter().map(|f| format!("MENU-{}", f.id)).collect()
}

/// Faces shown for this BoardSpec (FileMgr only when `usb.key`).
pub fn faces_for(spec: &BoardSpec) -> Vec<&'static Face> {
    let mut out: Vec<&'static Face> = MENUS.iter().collect();
    if spec.kernel.params.clocks {
        out.push(&UTILITIES[0]); // clocks
    }
    if spec.kernel.usb.enable && spec.kernel.usb.flash_fat32 {
        out.push(&UTILITIES[1]); // flash
    }
    if spec.kernel.usb.enable && spec.kernel.usb.key {
        out.push(&UTILITIES[2]); // filemgr
    }
    if spec.kernel.settings.enable
        && spec.kernel.settings.usb_key
        && spec.kernel.usb.enable
        && spec.kernel.usb.key
    {
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
                out.push_str(&format!(
                    "\tPrint(\"  {}={}\\n\");\n",
                    escape_holyc_string(&it.id),
                    escape_holyc_string(&it.value)
                ));
            }
        }
        out.push_str(&format!("\tKernelGet(\"{}\");\n}}\n", f.fetch));
    }
    out.push_str("U0 ClocksPrint()\n{\n\tKernelGet(\"/bios/clocks\");\n}\n");
    if spec.kernel.settings.enable {
        out.push_str("U0 SettingsUsbPrint()\n{\n\tKernelGet(\"/bios/settings/usb\");\n}\n");
    }
    // Display outputs and the surface split, same router path the browser
    // toggle uses — HolyC prints, browser-UI fetches, one endpoint.
    let out_active = spec.default_output();
    out.push_str(&format!(
        "U0 DisplayPrint()\n{{\n\tPrint(\"DISP {} {} {}x{}\\n\");\n",
        escape_holyc_string(&out_active.id),
        out_active.class.as_str(),
        out_active.w,
        out_active.h
    ));
    for o in spec.display_outputs() {
        out.push_str(&format!(
            "\tPrint(\"  {}={} pri={}\\n\");\n",
            escape_holyc_string(&o.id),
            o.class.as_str(),
            o.class.priority()
        ));
    }
    out.push_str(&format!(
        "\tPrint(\"  surface={}\\n\");\n\tKernelGet(\"/bios/display\");\n}}\n",
        spec.default_surface().as_str()
    ));
    if spec.surface_toggle() {
        out.push_str(&format!(
            "U0 DisplayToggle()\n{{\n\tDisplaySurface(\"{}\");\n}}\n",
            spec.default_surface().toggled().as_str()
        ));
    }
    out
}

fn escape_holyc_string(value: &str) -> String {
    let mut out = String::new();
    for c in value.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\0' => out.push_str("\\0"),
            c if c.is_ascii_control() => out.push_str(&format!("\\x{:02x}", c as u32)),
            _ => out.push(c),
        }
    }
    out
}

pub fn setup_reads(spec: &BoardSpec) -> Vec<&'static str> {
    if !spec.kernel.http.enable {
        return Vec::new();
    }
    let mut reads = vec!["/bios/menu"];
    reads.extend(faces_for(spec).iter().map(|face| face.fetch));
    if spec.kernel.params.bootloader {
        reads.push("/bios/bootloader");
    }
    if spec.surface_toggle() {
        reads.push("/bios/display");
    }
    if spec.kernel.settings.enable {
        reads.push("/bios/settings");
    }
    let usb = &spec.kernel.usb;
    if usb.enable && usb.key {
        for (enabled, path) in [
            (usb.fs_fat32, "/bios/files/fat32"),
            (usb.fs_ntfs, "/bios/files/ntfs"),
            (usb.fs_ext4, "/bios/files/ext4"),
        ] {
            if enabled {
                reads.push(path);
            }
        }
    }
    reads
}

pub fn setup_script(spec: &BoardSpec) -> String {
    if spec.kernel.js != "aot" {
        return String::new();
    }
    let mut out = String::from("document.getElementById(\"status\").innerText = \"UI-BOOT\";\n");
    out.push_str(&format!(
        "document.getElementById(\"bios-nav\").innerText = {};\n",
        g6b_spec::quote_json(&nav_label())
    ));
    if spec.kernel.http.proxy_js {
        for path in setup_reads(spec) {
            out.push_str(&format!("fetch({});\n", g6b_spec::quote_json(path)));
        }
    }
    out
}

fn escape_html(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

pub fn setup_html(spec: &BoardSpec) -> String {
    setup_html_ext(spec, None)
}

/// `setup_html` with the libwasm lane mounted: `data-libwasm-url` plus a
/// `#libwasm-spa` panel the browser adapter drives from `ui-libwasm.wasm`.
pub fn setup_html_libwasm(spec: &BoardSpec, libwasm_url: &str) -> String {
    setup_html_ext(spec, Some(libwasm_url))
}

fn setup_html_ext(spec: &BoardSpec, libwasm_url: Option<&str>) -> String {
    let files = &spec.kernel.http.files;
    let root = escape_html(files.root.trim_end_matches('/'));
    let js = files.enable && files.js && spec.kernel.js == "aot";
    let libwasm = libwasm_url
        .filter(|_| js && files.wasm && spec.kernel.wasm.enable && spec.kernel.ui == "svelte-d");
    let effects = libwasm.is_some() && spec.kernel.proxy.enable && spec.kernel.proxy.gl;
    let workers = if js && spec.worker_limit() > 0 {
        format!(
            " data-worker-url=\"{root}/worker.js\" data-worker-limit=\"{}\"",
            spec.worker_limit()
        )
    } else {
        String::new()
    };
    let css = include_str!("../../../browser-ui/out/bios-ui.css");
    let backdrop = if effects {
        "<canvas id=\"bios-fx\" aria-hidden=\"true\" hidden></canvas>"
    } else {
        ""
    };
    let wasm = if js && files.wasm {
        let mut attr = format!(" data-wasm-url=\"{root}/ui.wasm\"");
        if let Some(url) = libwasm {
            attr.push_str(&format!(" data-libwasm-url=\"{}\"", escape_html(url)));
        }
        if effects {
            let proxy = &spec.kernel.proxy;
            attr.push_str(&format!(" data-fx-gl=\"true\" data-fx-width=\"{}\" data-fx-height=\"{}\" data-fx-dpi=\"{}\" data-fx-fps=\"{}\"", proxy.high_w, proxy.high_h, proxy.dpi, proxy.refresh_hz()));
        }
        attr
    } else {
        String::new()
    };
    let reads = setup_reads(spec);
    let fetch_attr = |url: &str| {
        if js && spec.kernel.http.proxy_js && reads.contains(&url) {
            format!(" data-fetch=\"{url}\"")
        } else {
            String::new()
        }
    };
    // Top-right display surface toggle. Only rendered when both surfaces are
    // reachable, so the control can never promise a switch the board cannot do.
    // It is absolutely positioned with no positioned ancestor, so its
    // containing block is the initial one — the viewport in a browser, the
    // canvas in the CSS raster — which puts it in the top-right corner in both
    // lanes without disturbing the in-flow menu layout.
    let disp_toggle = if spec.surface_toggle() {
        let surface = spec.default_surface();
        let out = spec.default_output();
        format!(
            "<button type=\"button\" id=\"disp-toggle\" data-surface=\"{}\" data-output=\"{}\"{}>{}</button>\n\
             <p id=\"disp-status\" role=\"status\">{} {} {}x{}</p>\n",
            surface.as_str(),
            escape_html(&out.id),
            fetch_attr("/bios/display"),
            // The label names the surface the click switches *to*.
            if surface == g6b_spec::Surface::Gpu {
                "VGA view"
            } else {
                "GPU view"
            },
            out.class.as_str(),
            surface.as_str(),
            out.w,
            out.h
        )
    } else {
        String::new()
    };
    // `width`/`height` are explicit because the raster refuses shrink-to-fit
    // on an out-of-flow box (see g6b_css::computed_absolute_box).
    let disp_css = if spec.surface_toggle() {
        "#disp-toggle{position:absolute;top:0;right:0;width:12ch;height:24px;\
         background-color:#00aaaa;color:#ffffff;border:1px solid #00ffff}"
    } else {
        ""
    };
    let mut html = format!(
        "<!DOCTYPE html>\n<html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>G6LC-BIOS</title>\n\
         <style>body{{font:16px \"Courier New\",monospace;background:#0000aa;color:#c8c8c8;margin:0;padding:1ch}}#bios-ui{{max-width:80ch;margin:auto}}h1#banner{{background:#00aaaa;color:#ffffff;text-align:center;padding:0 1ch;margin:0;font-weight:bold}}h2{{color:#ffffff;margin:.5ch 0}}a{{color:#ffff55}}nav a,button{{margin:0 .5ch;display:inline-block}}a[aria-current=page]{{background:#00aaaa;color:#ffffff}}table{{border-collapse:collapse;width:100%;border:1px solid #00aaaa}}th,td{{text-align:left;padding:0 1ch;border-bottom:1px solid #000077;overflow-wrap:anywhere}}th{{color:#00ffff}}tr[data-writable=\"true\"] th{{color:#ffff55}}pre{{white-space:pre-wrap}}[hidden]{{display:none!important}}button{{font:inherit;background:#00aaaa;color:#ffffff;border:1px outset #00ffff}}section{{margin-block:1ch;border:1px solid #00aaaa;padding:0 1ch}}#status{{color:#ffff55}}#bios-nav{{color:#00ffff}}footer,#libwasm-status{{color:#00ffff}}{disp_css}{css}</style></head>\n\
         <body>{backdrop}{disp_toggle}<main id=\"bios-ui\" data-start-menu=\"{}\"{wasm}{workers}><h1 id=\"banner\">G6LC-BIOS | GSys LibreCore</h1>\n\
         <p id=\"status\" role=\"status\">Static BoardSpec view</p><p id=\"profile\">{}</p>\n\
         <p id=\"bios-nav\">{}</p><nav id=\"bios-menu\" aria-label=\"Setup menus\"{}><p id=\"menu-title\">Setup menus</p>\n",
        escape_html(&spec.kernel.start_menu),
        spec.kernel.profile.as_str(),
        nav_label(),
        fetch_attr("/bios/menu")
    );
    for menu in spec.menus() {
        html.push_str(&format!(
            "<a href=\"#menu-{}\" data-menu-link=\"{}\">{}</a>\n",
            menu.id, menu.id, menu.title
        ));
    }
    html.push_str("</nav><p>Compiled settings are a read-only view. Editing, settings import, and flashing are unavailable here.</p>\n");
    if js && spec.kernel.http.proxy_js && !reads.is_empty() {
        html.push_str("<button type=\"button\" id=\"refresh\">Refresh values</button>\n");
    }
    for menu in spec.menus() {
        html.push_str(&format!(
            "<section id=\"menu-{}\" data-menu=\"{}\" aria-labelledby=\"{}-title\"{}><h2 id=\"{}-title\">{}</h2><table><thead><tr><th>Setting</th><th>Value</th><th>Access</th></tr></thead><tbody>\n",
            menu.id,
            menu.id,
            menu.id,
            fetch_attr(&format!("/bios/menu/{}", menu.id)),
            menu.id,
            menu.title
        ));
        for item in menu.items {
            let id = escape_html(&item.id);
            html.push_str(&format!(
                "<tr data-item=\"{id}\" data-writable=\"{}\"><th scope=\"row\" id=\"label-{}-{id}\">{}</th><td id=\"row-{}-{id}\">{}</td><td id=\"access-{}-{id}\">{}</td></tr>\n",
                item.writable,
                menu.id,
                escape_html(&item.label),
                menu.id,
                escape_html(&item.value),
                menu.id,
                if item.writable { "Writable in spec; editing unavailable" } else { "Read-only" }
            ));
        }
        html.push_str("</tbody></table></section>\n");
    }
    for face in faces_for(spec)
        .into_iter()
        .filter(|face| face.kind == Kind::Utility)
    {
        let (section, title, body, initial) = match face.id {
            "clocks" => (
                "clocks",
                "clocks-title",
                "clocks-value",
                format!(
                    "CPU {} Hz; UART {} baud",
                    spec.kernel.params.cpu_hz, spec.kernel.params.uart_baud
                ),
            ),
            "flash" => (
                "usb-flash",
                "usb-title",
                "usb-list",
                "USB-FAT32: read-only image listing; no flashing operation".into(),
            ),
            "filemgr" => (
                "filemgr",
                "fm-title",
                "fm-list",
                "USB-FILES: read-only volume listing".into(),
            ),
            "settings-usb" => (
                "settings-usb",
                "settings-usb-title",
                "settings-usb-value",
                "USB settings key configured; import/export unavailable here".into(),
            ),
            _ => continue,
        };
        html.push_str(&format!(
            "<section id=\"{section}\"><h2 id=\"{title}\">{}</h2><pre id=\"{body}\"{}>{}</pre>\n",
            face.title,
            fetch_attr(face.fetch),
            escape_html(&initial)
        ));
        if face.id == "filemgr" {
            let mut names = Vec::new();
            for (enabled, name, path) in [
                (spec.kernel.usb.fs_fat32, "fat32", "/bios/files/fat32"),
                (spec.kernel.usb.fs_ntfs, "ntfs", "/bios/files/ntfs"),
                (spec.kernel.usb.fs_ext4, "ext4", "/bios/files/ext4"),
            ] {
                if enabled {
                    names.push(name);
                    html.push_str(&format!(
                        "<pre id=\"fm-{name}\"{}>{name}: not refreshed</pre>\n",
                        fetch_attr(path)
                    ));
                }
            }
            html.push_str(&format!(
                "<p id=\"fm-tabs\" data-preserve=\"true\">{}</p>\n",
                names.join(" ")
            ));
        }
        html.push_str("</section>\n");
    }
    for (enabled, path, id, initial) in [
        (spec.kernel.params.bootloader, "/bios/bootloader", "bootloader-info", format!("Next bootloader: {}", spec.kernel.params.next)),
        (spec.kernel.settings.enable, "/bios/settings", "settings-info", format!("Settings capabilities: export={} import={} uart={} mailbox={} usb_key={}; no mutation operations", spec.kernel.settings.export, spec.kernel.settings.import, spec.kernel.settings.uart, spec.kernel.settings.mailbox, spec.kernel.settings.usb_key)),
    ] {
        if enabled {
            html.push_str(&format!("<pre id=\"{id}\"{}>{}</pre>\n", fetch_attr(path), escape_html(&initial)));
        }
    }
    if !workers.is_empty() {
        html.push_str("<button type=\"button\" id=\"worker-check\">Verify compute worker</button><p id=\"worker-status\" role=\"status\">Dedicated workers ready on demand; ServiceWorker registration unavailable</p>\n");
    }
    if effects {
        html.push_str("<button type=\"button\" id=\"fx-motion\">Pause background</button><p id=\"fx-status\" role=\"status\">D/WASM background pending</p>\n");
    }
    if libwasm.is_some() {
        html.push_str(
            "<section id=\"libwasm-spa\"><h2 id=\"libwasm-title\">LDC component scaffold</h2><div id=\"libwasm-root\"></div><p id=\"libwasm-status\">LDC cell: pending</p></section>\n",
        );
    }
    html.push_str("<footer><p id=\"bios-hint\">G6LC-BIOS setup — Left/Right: menu; Home/End: first/last; F10: refresh (not save); read-only</p></footer>\n");
    html.push_str("</main>\n");
    if js {
        html.push_str(&format!(
            "<script type=\"module\" src=\"{root}/app.js\"></script>\n"
        ));
    }
    html.push_str("</body></html>\n");
    html
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn holyc_menu_values_are_escaped_as_one_string_literal() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"product":"Board \"α\" https://local\nnext\\n\t\r\u0001\u0000\"); Reboot(); //"}"#).unwrap();
        let source = holyc_print_src(&spec);
        let row = source
            .lines()
            .find(|line| line.contains("product="))
            .unwrap();
        assert_eq!(row, "\tPrint(\"  product=Board \\\"α\\\" https://local\\nnext\\\\n\\t\\r\\x01\\0\\\"); Reboot(); //\\n\");");
        assert!(!source.lines().any(|line| line.starts_with("next")));
    }

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
    fn setup_script_is_bounded_aot_and_all_text_targets_exist() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let mut dom = g6b_html::parse(&setup_html(&spec));
        let ops = g6b_js::compile(&setup_script(&spec)).unwrap();
        assert!(ops.len() < 32);
        for op in &ops {
            match op {
                g6b_js::Op::SetInnerText { id, .. } => assert!(dom.get_element_by_id(id).is_some()),
                g6b_js::Op::Fetch { method, url } => {
                    assert_eq!(method, "GET");
                    assert!(setup_reads(&spec).contains(&url.as_str()));
                }
                other => panic!("unexpected setup operation {other:?}"),
            }
        }
        for op in g6b_js::compile(include_str!("../../../browser-ui/out/bios-ui.js")).unwrap() {
            if let g6b_js::Op::SetInnerText { id, .. } = op {
                assert!(
                    dom.get_element_by_id(&id).is_some(),
                    "missing compile-product target {id}"
                );
            }
        }
        for menu in spec.menus() {
            for item in menu.items {
                assert_eq!(
                    dom.get_element_by_id(&format!("row-{}-{}", menu.id, item.id))
                        .unwrap()
                        .inner_text(),
                    item.value
                );
            }
        }
    }

    #[test]
    fn particle_display_uses_existing_proxy_gates_and_keeps_static_rows() {
        let mut spec =
            BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        spec.kernel.proxy.enable = true;
        spec.kernel.proxy.gl = true;
        spec.kernel.proxy.high_w = 3840;
        spec.kernel.proxy.high_h = 2160;
        spec.kernel.proxy.dpi = 192;
        spec.kernel.proxy.fps = 120;
        let html = setup_html_libwasm(&spec, "/ui/ui-libwasm.wasm");
        for attr in [
            "id=\"bios-fx\"",
            "data-fx-width=\"3840\"",
            "data-fx-height=\"2160\"",
            "data-fx-dpi=\"192\"",
            "data-fx-fps=\"120\"",
            "id=\"fx-motion\"",
            "id=\"row-cpu-cores\"",
        ] {
            assert!(html.contains(attr), "{attr}");
        }
        assert!(html.contains("prefers-reduced-motion"));
        assert!(html.contains("rgba(0, 0, 64, .74)"));
        spec.kernel.proxy.gl = false;
        let html = setup_html_libwasm(&spec, "/ui/ui-libwasm.wasm");
        assert!(!html.contains("<canvas"));
        assert!(!html.contains("data-fx-gl="));
        assert!(html.contains("id=\"libwasm-root\""));
        spec.kernel.js = "off".into();
        let html = setup_html_libwasm(&spec, "/ui/ui-libwasm.wasm");
        assert!(!html.contains("data-libwasm-url="));
        assert!(html.contains("id=\"row-cpu-cores\""));
    }

    #[test]
    fn setup_renders_every_spec_row_with_access_flags() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let html = setup_html(&spec);
        for menu in spec.menus() {
            assert!(html.contains(&format!("id=\"menu-{}\"", menu.id)));
            for item in menu.items {
                assert!(html.contains(&format!("id=\"row-{}-{}\"", menu.id, item.id)));
                assert!(html.contains(&escape_html(&item.label)));
                assert!(html.contains(&escape_html(&item.value)));
                assert!(html.contains(&format!("data-writable=\"{}\"", item.writable)));
            }
        }
        for id in [
            "status",
            "bios-nav",
            "menu-title",
            "usb-title",
            "usb-list",
            "fm-tabs",
            "fm-list",
        ] {
            assert!(html.contains(&format!("id=\"{id}\"")), "{id}");
        }
        assert!(html.contains("Read-only"));
        assert!(!html.contains("onclick="));
    }

    #[test]
    fn setup_utilities_and_fetches_follow_capabilities() {
        let mut spec =
            BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        spec.kernel.params.clocks = false;
        spec.kernel.usb.flash_fat32 = false;
        spec.kernel.usb.fs_ntfs = false;
        spec.kernel.usb.fs_ext4 = false;
        spec.kernel.settings.usb_key = false;
        let script = setup_script(&spec);
        for absent in [
            "/bios/clocks",
            "/bios/usb/ls",
            "/bios/files/ntfs",
            "/bios/files/ext4",
            "/bios/settings/usb",
        ] {
            assert!(!script.contains(absent), "{absent}");
        }
        assert!(script.contains("fetch(\"/bios/files/fat32\")"));
        assert!(script.contains("fetch(\"/bios/menu/settings\")"));
        assert!(!script.contains("kernel."));
        assert!(!script.contains("/bios/flash"));
        assert!(!script.contains("/bios/settings/import"));
        assert!(!setup_html(&spec).contains("id=\"usb-flash\""));
        spec.kernel.usb.enable = false;
        assert!(!setup_html(&spec).contains("id=\"filemgr\""));
        assert!(!setup_script(&spec).contains("/bios/files"));
        spec.kernel.js = "none".into();
        assert!(setup_script(&spec).is_empty());
    }

    #[test]
    fn static_html_escapes_spec_values_and_honors_asset_flags() {
        let mut spec =
            BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        spec.kernel.params.next = "<img src=x onerror=alert(1)>\"&".into();
        spec.kernel.http.files.root = "/custom/setup/".into();
        let html = setup_html(&spec);
        assert!(html.contains("&lt;img src=x onerror=alert(1)&gt;&quot;&amp;"));
        assert!(html.contains("src=\"/custom/setup/app.js\""));
        assert!(html.contains("data-wasm-url=\"/custom/setup/ui.wasm\""));
        spec.kernel.http.files.js = false;
        let html = setup_html(&spec);
        assert!(!html.contains("<script"));
        assert!(!html.contains("data-wasm-url"));
    }

    #[test]
    fn browser_start_menu_and_proxy_gate_keep_static_rows() {
        let mut spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"full","kernel":{"browser":{"start_menu":"cpu"}}}"#,
        )
        .unwrap();
        let html = setup_html(&spec);
        assert!(html.contains("data-start-menu=\"cpu\""));
        assert!(html.contains("data-fetch=\"/bios/menu/cpu\""));
        spec.kernel.http.proxy_js = false;
        assert!(setup_reads(&spec).contains(&"/bios/menu/cpu"));
        assert!(!setup_script(&spec).contains("fetch("));
        let html = setup_html(&spec);
        assert!(!html.contains("data-fetch="));
        assert!(!html.contains("id=\"refresh\""));
        assert!(html.contains("src=\"/ui/app.js\""));
        assert!(html.contains("id=\"menu-cpu\""));
        for js in ["off", "none"] {
            spec.kernel.js = js.into();
            spec.kernel.http.proxy_js = true;
            let html = setup_html(&spec);
            assert!(!html.contains("<script"));
            assert!(!html.contains("data-wasm-url="));
            assert!(!html.contains("data-fetch="));
            assert!(setup_script(&spec).is_empty());
            for item in spec.menu("cpu").unwrap().items {
                assert!(html.contains(&format!("id=\"row-cpu-{}\"", item.id)));
            }
        }
    }

    #[test]
    fn disabled_settings_and_selective_usb_files_keep_menu_and_preserved_tabs() {
        let mut spec =
            BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        spec.kernel.settings.enable = false;
        spec.kernel.usb.fs_ntfs = false;
        spec.kernel.usb.fs_ext4 = false;
        let html = setup_html(&spec);
        assert!(html.contains("id=\"menu-settings\""));
        assert!(!html.contains("id=\"settings-info\""));
        assert!(!html.contains("id=\"settings-usb\""));
        assert!(html.contains("id=\"fm-tabs\" data-preserve=\"true\">fat32</p>"));
        assert!(html.contains("data-fetch=\"/bios/files/fat32\""));
        for path in [
            "/bios/settings",
            "/bios/settings/usb",
            "/bios/files/ntfs",
            "/bios/files/ext4",
        ] {
            assert!(!setup_reads(&spec).contains(&path));
            assert!(!html.contains(&format!("data-fetch=\"{path}\"")));
        }
    }

    #[test]
    fn fetch_paints_cpu_title() {
        let f = face_for_fetch("/bios/menu/cpu").unwrap();
        assert_eq!(f.paint_id(), "cpu-title");
        assert_eq!(paint_body("{\"id\":\"cpu\",\"title\":\"CPU\"}"), "CPU");
        assert_eq!(face_for_fetch("/bios/cpu").unwrap().id, "cpu");
    }
}
