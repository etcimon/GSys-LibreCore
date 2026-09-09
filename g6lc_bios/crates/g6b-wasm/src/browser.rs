// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//!
//! Browser-side libwasm host seams. The kernel is **not** the place to hook
//! libwasm types: svelte-engine `src-ts/modules/libwasm.ts` owns
//! `{1: document, 2: window}` and `window.__svelteD.ts`. The kernel only
//! supplies fetch / HolyC / endpoint registration through [`KernelPort`].

use std::collections::BTreeMap;

/// Kernel I/O the browser host is allowed to call. Implemented by
/// `g6b-kernel` (router + HolyC), never by the wasm interpreter.
pub trait KernelPort {
    /// GET a local `/bios/` or `/ui/` URL. Status + body text.
    fn fetch_text(&mut self, url: &str) -> Result<(u16, String), String>;
    /// One HolyC REPL line.
    fn holyc(&mut self, line: &str) -> Result<String, String>;
    /// Register a JS/D endpoint under `/bios/custom`.
    fn register_endpoint(&mut self, path: &str, method: &str) -> Result<(), String>;
}

/// One `window.__svelteD.ts[mod][name]` entry (svelte-d cross-calling).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JsExportKind {
    /// `fetchBios(url)` — kernel GET.
    FetchBios,
    /// `holycEval(line)`.
    HolycEval,
    /// `registerEndpoint(path, method)`.
    RegisterEndpoint,
}

/// Bounded `__svelteD.ts` registry. Keys are module-mangled like
/// `App_svelte.fetchBios` (`identFromRel("src/App.svelte")`).
#[derive(Debug, Clone, Default)]
pub struct JsExports {
    ts: BTreeMap<String, BTreeMap<String, JsExportKind>>,
}

impl JsExports {
    /// BIOS App.svelte lang=ts exports printed by `print-ts.ts`.
    pub fn bios_app() -> Self {
        let mut app = BTreeMap::new();
        app.insert("fetchBios".into(), JsExportKind::FetchBios);
        app.insert("holycEval".into(), JsExportKind::HolycEval);
        app.insert("registerEndpoint".into(), JsExportKind::RegisterEndpoint);
        let mut ts = BTreeMap::new();
        ts.insert("App_svelte".into(), app);
        Self { ts }
    }

    /// Look up `mod.name` or `mod.name` from an invoke path.
    pub fn lookup(&self, path: &str) -> Option<JsExportKind> {
        let path = path.trim().trim_start_matches("window.__svelteD.ts.");
        if let Some((mod_name, fn_name)) = path.rsplit_once('.') {
            return self.ts.get(mod_name).and_then(|m| m.get(fn_name)).copied();
        }
        self.ts.values().find_map(|m| m.get(path).copied())
    }

    /// Nested `{mod: {name: "mod.name"}}` for Lodash `get`/`invoke`.
    pub fn as_nested_strings(&self) -> BTreeMap<String, BTreeMap<String, String>> {
        let mut root = BTreeMap::new();
        for (mod_name, fns) in &self.ts {
            let mut inner = BTreeMap::new();
            for name in fns.keys() {
                inner.insert(name.clone(), format!("{mod_name}.{name}"));
            }
            root.insert(mod_name.clone(), inner);
        }
        root
    }

    /// Names `libwasm_global` intern as the live browser instance.
    pub fn is_browser_global(name: &str) -> bool {
        matches!(name, "window" | "document" | "console")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bios_app_exports_match_print_ts() {
        let j = JsExports::bios_app();
        assert_eq!(
            j.lookup("App_svelte.fetchBios"),
            Some(JsExportKind::FetchBios)
        );
        assert_eq!(j.lookup("fetchBios"), Some(JsExportKind::FetchBios));
        assert!(j.lookup("eval").is_none());
    }
}
