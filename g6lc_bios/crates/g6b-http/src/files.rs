// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Kernel-backed static files: generated HTML/JS/WASM, not a Linux VFS.

#![allow(missing_docs)]

use std::collections::BTreeMap;

use g6b_spec::BoardSpec;

/// One file the HolyC HTTP(S) server may emit.
#[derive(Debug, Clone)]
pub struct StaticFile {
    pub path: String,
    pub content_type: String,
    pub body: Vec<u8>,
}

/// Mount UI files for this BoardSpec. Empty when `http.files` is off.
pub fn mount(spec: &BoardSpec) -> BTreeMap<String, StaticFile> {
    let f = &spec.kernel.http.files;
    if !f.enable {
        return BTreeMap::new();
    }
    let root = f.root.trim_end_matches('/');
    let root = if root.is_empty() { "" } else { root };
    let libwasm = f.wasm
        && spec.kernel.wasm.enable
        && spec.kernel.ui == "svelte-d"
        && g6b_wasm::bios_ui_libwasm_live();
    let mut out = BTreeMap::new();
    if f.html {
        let html = if libwasm {
            g6b_ui::setup_html_libwasm(spec, &format!("{root}/ui-libwasm.wasm"))
        } else {
            g6b_ui::setup_html(spec)
        }
        .into_bytes();
        put(
            &mut out,
            &format!("{root}/index.html"),
            "text/html; charset=utf-8",
            html.clone(),
        );
        put(
            &mut out,
            &format!("{root}/"),
            "text/html; charset=utf-8",
            html.clone(),
        );
        put(&mut out, "/", "text/html; charset=utf-8", html);
    }
    if f.js && spec.kernel.js == "aot" {
        put(
            &mut out,
            &format!("{root}/app.js"),
            "application/javascript; charset=utf-8",
            app_js(spec, f.wasm, root).into_bytes(),
        );
        if spec.worker_limit() > 0 {
            put(
                &mut out,
                &format!("{root}/worker.js"),
                "application/javascript; charset=utf-8",
                include_bytes!("../../../browser-ui/src/worker.ts").to_vec(),
            );
        }
    }
    if f.wasm {
        // `/ui/ui.wasm` is the UI application: the LDC cell when the
        // svelte-d lane is live, otherwise the MVP encoder demonstration.
        let ui_wasm = if libwasm {
            g6b_wasm::bios_ui_libwasm()
        } else {
            g6b_wasm::bios_ui_wasm()
        };
        put(
            &mut out,
            &format!("{root}/ui.wasm"),
            "application/wasm",
            ui_wasm.to_vec(),
        );
        if libwasm {
            put(
                &mut out,
                &format!("{root}/ui-libwasm.wasm"),
                "application/wasm",
                g6b_wasm::bios_ui_libwasm().to_vec(),
            );
        }
    }
    if f.assets {
        put(
            &mut out,
            &format!("{root}/g6lc.svg"),
            "image/svg+xml",
            include_bytes!("../../../fixtures/ui-assets/g6lc.svg").to_vec(),
        );
        put(
            &mut out,
            &format!("{root}/bios-ui.css"),
            "text/css; charset=utf-8",
            include_str!("../../../browser-ui/out/bios-ui.css")
                .as_bytes()
                .to_vec(),
        );
    }
    let listing = listing_json(&out);
    let listing_path = if root.is_empty() { "/files.json" } else { root };
    put(
        &mut out,
        listing_path,
        "application/json",
        listing.into_bytes(),
    );
    out
}

/// PNG/SVG bodies keyed by their served path, for the CSS `AssetMap`.
pub fn image_files(spec: &BoardSpec) -> Vec<(String, Vec<u8>)> {
    mount(spec)
        .into_iter()
        .filter(|(path, file)| {
            file.content_type.starts_with("image/")
                || path.ends_with(".svg")
                || path.ends_with(".png")
        })
        .map(|(path, file)| (path, file.body))
        .collect()
}

fn put(map: &mut BTreeMap<String, StaticFile>, path: &str, ct: &str, body: Vec<u8>) {
    let path = if path.is_empty() { "/" } else { path };
    map.insert(
        path.to_string(),
        StaticFile {
            path: path.to_string(),
            content_type: ct.into(),
            body,
        },
    );
}

fn app_js(spec: &BoardSpec, wasm: bool, _root: &str) -> String {
    let mut s = include_str!("../../../browser-ui/src/kernel.ts").to_string();
    if !s.ends_with('\n') {
        s.push('\n');
    }
    s.push_str(&format!(
        "// profile={} wasm={}\n",
        spec.kernel.profile.as_str(),
        wasm as u8
    ));
    s
}

fn listing_json(files: &BTreeMap<String, StaticFile>) -> String {
    let parts: Vec<String> = files
        .values()
        .map(|f| {
            format!(
                "{{\"path\":{},\"type\":{},\"bytes\":{}}}",
                g6b_spec::quote_json(&f.path),
                g6b_spec::quote_json(f.content_type.split(';').next().unwrap_or(&f.content_type)),
                f.body.len()
            )
        })
        .collect();
    format!("{{\"files\":[{}]}}", parts.join(","))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn served_html_is_shared_and_adapter_is_not_host_aot() {
        let mut spec =
            BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        spec.kernel.http.files.root = "/setup/".into();
        let files = mount(&spec);
        let expected = if g6b_wasm::bios_ui_libwasm_live() {
            g6b_ui::setup_html_libwasm(&spec, "/setup/ui-libwasm.wasm")
        } else {
            g6b_ui::setup_html(&spec)
        };
        assert_eq!(files["/setup/index.html"].body, expected.as_bytes());
        let js = String::from_utf8_lossy(&files["/setup/app.js"].body);
        assert!(js.contains("createWasmHost"));
        assert!(js.contains("exports._start()"));
        assert!(!js.contains("declare const kernel"));
        assert!(!js.contains("kernel.register(\"/bios/custom\")"));
        spec.kernel.http.files.js = false;
        spec.kernel.http.files.wasm = false;
        let files = mount(&spec);
        assert!(!files.contains_key("/setup/app.js"));
        assert!(!files.contains_key("/setup/ui.wasm"));
        spec.kernel.http.files.root = "/".into();
        let files = mount(&spec);
        assert!(String::from_utf8_lossy(&files["/"].body).starts_with("<!DOCTYPE html>"));
    }

    #[test]
    fn js_off_omits_adapter_but_leaves_static_html_and_wasm_file() {
        let mut spec =
            BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        for js in ["off", "none"] {
            spec.kernel.js = js.into();
            let files = mount(&spec);
            assert!(!files.contains_key("/ui/app.js"));
            assert!(files.contains_key("/ui/ui.wasm"));
            let html = String::from_utf8_lossy(&files["/ui/index.html"].body);
            assert!(!html.contains("<script"));
            assert!(!html.contains("data-wasm-url="));
            assert!(html.contains("id=\"menu-cpu\""));
        }
        spec.kernel.js = "aot".into();
        spec.kernel.http.proxy_js = false;
        let files = mount(&spec);
        assert!(files.contains_key("/ui/app.js"));
        let html = String::from_utf8_lossy(&files["/ui/index.html"].body);
        assert!(!html.contains("data-fetch="));
        assert!(html.contains("data-wasm-url=\"/ui/ui.wasm\""));
    }

    #[test]
    fn compute_worker_script_is_local_and_explicitly_tasking_gated() {
        let mut spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full","harts":{"cores":4,"threads":1},"kernel":{"tasking":{"enable":true,"max_workers":2}}}"#).unwrap();
        spec.kernel.http.files.root = "/setup".into();
        let files = mount(&spec);
        assert_eq!(
            files["/setup/worker.js"].body,
            include_bytes!("../../../browser-ui/src/worker.ts")
        );
        let html = String::from_utf8_lossy(&files["/"].body);
        assert!(html.contains("data-worker-url=\"/setup/worker.js\""));
        assert!(html.contains("data-worker-limit=\"2\""));
        assert!(html.contains("id=\"worker-check\""));
        spec.kernel.tasking.enable = false;
        let files = mount(&spec);
        assert!(!files.contains_key("/setup/worker.js"));
        assert!(!String::from_utf8_lossy(&files["/"].body).contains("data-worker-url="));
        spec.kernel.tasking.enable = true;
        spec.kernel.js = "off".into();
        assert!(!mount(&spec).contains_key("/setup/worker.js"));
    }

    #[test]
    fn libwasm_serving_respects_ui_files_and_js_gates() {
        let mut spec =
            BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        spec.kernel.http.files.root = "/custom".into();
        for ui in ["svelte-d", "html-js"] {
            spec.kernel.ui = ui.into();
            for wasm in [true, false] {
                spec.kernel.http.files.wasm = wasm;
                for js in ["aot", "off", "none"] {
                    spec.kernel.js = js.into();
                    let files = mount(&spec);
                    let live = ui == "svelte-d" && wasm && g6b_wasm::bios_ui_libwasm_live();
                    assert_eq!(files.contains_key("/custom/ui-libwasm.wasm"), live);
                    let html = String::from_utf8_lossy(&files["/"].body);
                    assert_eq!(html.contains("data-libwasm-url="), live && js == "aot");
                    assert_eq!(html.contains("id=\"libwasm-root\""), live && js == "aot");
                    assert!(html.contains("id=\"row-cpu-cores\""));
                    if live {
                        let file = &files["/custom/ui-libwasm.wasm"];
                        assert_eq!(file.content_type, "application/wasm");
                        assert_eq!(file.body, g6b_wasm::bios_ui_libwasm());
                        assert!(String::from_utf8_lossy(&files["/custom"].body)
                            .contains("ui-libwasm.wasm"));
                    }
                }
            }
        }
        spec.kernel.http.files.enable = false;
        assert!(mount(&spec).is_empty());
    }

    #[test]
    fn full_profile_mounts_html_js_wasm() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let m = mount(&spec);
        let html = String::from_utf8_lossy(&m.get("/ui/index.html").unwrap().body);
        assert!(html.contains("G6LC-BIOS"), "{html}");
        assert!(m.contains_key("/ui/app.js"));
        let wasm = &m.get("/ui/ui.wasm").unwrap().body;
        assert_eq!(&wasm[..4], b"\0asm");
        let mark = m.get("/ui/g6lc.svg").expect("bundled UI mark");
        assert_eq!(mark.content_type, "image/svg+xml");
        assert!(mark.body.windows(4).any(|w| w == b"<svg"), "svg body");
        if g6b_wasm::bios_ui_libwasm_live() {
            assert_eq!(
                wasm.as_slice(),
                g6b_wasm::bios_ui_libwasm(),
                "/ui/ui.wasm is the LDC cell when live"
            );
        }
    }
}
