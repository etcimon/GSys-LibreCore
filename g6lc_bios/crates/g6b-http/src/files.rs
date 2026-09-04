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
    let mut out = BTreeMap::new();
    if f.html {
        let html = index_html(spec, f.js, f.wasm, root).into_bytes();
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
    if f.js {
        put(
            &mut out,
            &format!("{root}/app.js"),
            "application/javascript; charset=utf-8",
            app_js(spec, f.wasm, root).into_bytes(),
        );
    }
    if f.wasm {
        put(
            &mut out,
            &format!("{root}/ui.wasm"),
            "application/wasm",
            g6b_wasm::bios_ui_wasm().to_vec(),
        );
    }
    let listing = listing_json(&out);
    put(&mut out, root, "application/json", listing.into_bytes());
    out
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

fn index_html(spec: &BoardSpec, js: bool, wasm: bool, root: &str) -> String {
    let script = if js {
        format!("<script src=\"{root}/app.js\"></script>\n")
    } else {
        String::new()
    };
    let wasm_note = if wasm {
        format!("<p id=\"wasm\">{root}/ui.wasm</p>\n")
    } else {
        String::new()
    };
    format!(
        "<!DOCTYPE html>\n\
<html><head><title>G6LC-BIOS</title></head>\n\
<body>\n\
<h1 id=\"banner\">G6LC-BIOS</h1>\n\
<p id=\"status\">boot</p>\n\
<p id=\"profile\">{}</p>\n\
{wasm_note}{script}\
</body></html>\n",
        spec.kernel.profile.as_str()
    )
}

fn app_js(spec: &BoardSpec, wasm: bool, root: &str) -> String {
    let mut s = g6b_wasm::BIOS_UI_JS.to_string();
    if !s.ends_with('\n') {
        s.push('\n');
    }
    if wasm {
        s.push_str(&format!("fetch(\"{root}/ui.wasm\");\n"));
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
                "{{\"path\":\"{}\",\"type\":\"{}\",\"bytes\":{}}}",
                f.path,
                f.content_type.split(';').next().unwrap_or(&f.content_type),
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
    fn full_profile_mounts_html_js_wasm() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let m = mount(&spec);
        let html = String::from_utf8_lossy(&m.get("/ui/index.html").unwrap().body);
        assert!(html.contains("G6LC-BIOS"), "{html}");
        assert!(m.contains_key("/ui/app.js"));
        let wasm = &m.get("/ui/ui.wasm").unwrap().body;
        assert_eq!(&wasm[..4], b"\0asm");
    }
}
