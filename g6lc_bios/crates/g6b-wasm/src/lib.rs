// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! WASM MVP decoder, host interpreter (BIOS UI JIT), and RISC-V lower.
//! Spec: `kernel-spec/svelte-d` libwasm imports. No wasmtime / wasmi.

#![allow(missing_docs)]

mod binary;
mod interp;
mod jit;

pub use binary::{decode, encode_ui_module, Module};
pub use interp::{run, run_start, DomHost, Host};
pub use jit::jit_add_i32;

/// Boot / generated-source marker.
pub const MARKER: &str = "WASM-JIT";

/// browser-ui compile products (svelte-d → svelte-engine-ws → Bun/TS).
pub const BIOS_UI_WASM: &[u8] = g6b_asm::BIOS_UI_WASM;
pub const BIOS_UI_JS: &str = include_str!("../../../browser-ui/out/bios-ui.js");
pub const BIOS_UI_CATALOG: &str = include_str!("../../../browser-ui/out/catalog.json");

/// Bytes of `browser-ui/out/bios-ui.wasm`.
pub fn bios_ui_wasm() -> &'static [u8] {
    BIOS_UI_WASM
}

/// `SVELTE-LIVE` / `SVELTE-STUB` / `SVELTE-REFUSED` markers from catalog.json.
pub fn svelte_live_markers() -> Vec<String> {
    json_str_array(BIOS_UI_CATALOG, "live")
        .into_iter()
        .map(|c| format!("SVELTE-LIVE {c}"))
        .collect()
}

/// Stub construct markers (`SVELTE-STUB {#await}`, …).
pub fn svelte_stub_markers() -> Vec<String> {
    json_str_array(BIOS_UI_CATALOG, "stub")
        .into_iter()
        .map(|c| format!("SVELTE-STUB {c}"))
        .collect()
}

fn json_str_array(s: &str, key: &str) -> Vec<String> {
    let pat = format!("\"{key}\"");
    let Some(i) = s.find(&pat) else {
        return Vec::new();
    };
    let rest = &s[i + pat.len()..];
    let Some(b) = rest.find('[') else {
        return Vec::new();
    };
    let Some(e) = rest[b..].find(']') else {
        return Vec::new();
    };
    rest[b + 1..b + e]
        .split(',')
        .filter_map(|p| {
            let p = p.trim().trim_matches('"');
            if p.is_empty() {
                None
            } else {
                Some(p.to_string())
            }
        })
        .collect()
}

/// Import name matching the svelte-d / libwasm handle-table subset.
pub const IMPORT_SET_INNER_TEXT: &str = "set_inner_text";
pub const IMPORT_LOG: &str = "console_log";
pub const IMPORT_SET_VISIBLE: &str = "set_visible";
/// libwasm `Object_Call_string__Handle` / `fetch` → kernel HTTP router.
pub const IMPORT_FETCH: &str = "fetch";
pub const IMPORT_OBJECT_CALL: &str = "Object_Call_string__Handle";

#[cfg(test)]
mod tests {
    use super::*;
    use g6b_dom::Node;

    #[test]
    fn ui_module_sets_dom() {
        let bytes = encode_ui_module("status", "UI-BOOT");
        let m = decode(&bytes).unwrap();
        let mut root = Node::elem("body");
        let mut p = Node::elem("p");
        p.id = Some("status".into());
        p.set_inner_text("boot");
        root.children.push(p);
        run_start(&m, &mut DomHost { dom: &mut root }).unwrap();
        assert_eq!(
            root.get_element_by_id("status").unwrap().inner_text(),
            "UI-BOOT"
        );
    }

    #[test]
    fn jit_add_lowers_to_add() {
        let m = jit_add_i32();
        let s = m.to_asm();
        assert!(s.contains("purpose=wasm-jit"), "{s}");
        assert!(s.contains("\tadd\t"), "{s}");
        let (w, _) = m.to_words(0).unwrap();
        assert!(w.len() >= 2);
    }

    #[test]
    fn rejects_bad_magic() {
        assert!(decode(b"XXXX").is_err());
    }

    #[test]
    fn bios_ui_wasm_starts_and_catalog_live() {
        assert_eq!(&BIOS_UI_WASM[..4], b"\0asm");
        let m = decode(BIOS_UI_WASM).unwrap();
        assert!(m.exports.iter().any(|e| e.name == "_start"));
        assert!(m.imports.iter().any(|i| i.name == IMPORT_SET_INNER_TEXT));
        let live = svelte_live_markers();
        assert!(live.iter().any(|s| s.contains("FileMgr")), "{live:?}");
        assert!(live.iter().any(|s| s.contains("NodeDef")), "{live:?}");
        assert!(live.iter().any(|s| s.contains("Settings")), "{live:?}");
        assert!(BIOS_UI_JS.contains("UI-BOOT"));
        assert!(BIOS_UI_JS.contains("kernel.holyc"));
        assert!(BIOS_UI_JS.contains("/bios/menu/settings"));
        let mut root = Node::elem("body");
        let mut p = Node::elem("p");
        p.id = Some("status".into());
        root.children.push(p);
        struct SkipMissing<'a> {
            dom: &'a mut Node,
        }
        impl Host for SkipMissing<'_> {
            fn set_inner_text(&mut self, id: &str, val: &str) -> Result<(), String> {
                if let Some(n) = self.dom.get_element_by_id(id) {
                    n.set_inner_text(val);
                }
                Ok(())
            }
            fn log(&mut self, _msg: &str) {}
            fn set_visible(&mut self, _id: &str, _on: bool) -> Result<(), String> {
                Ok(())
            }
        }
        run_start(&m, &mut SkipMissing { dom: &mut root }).unwrap();
        assert_eq!(
            root.get_element_by_id("status").unwrap().inner_text(),
            "UI-BOOT"
        );
    }
}
