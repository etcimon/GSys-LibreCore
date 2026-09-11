// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//!
//! UI-thread host adapter. svelte-engine owns `{1: document, 2: window}` and
//! `window.__svelteD.ts`. This module is the KernelPort (fetch / HolyC /
//! register) the browser host is allowed to call — not a kernel type table
//! for DOM/JS globals.

use g6b_http::Router;
use g6b_spec::BoardSpec;
use g6b_wasm::{JsExports, KernelPort, Module};

use super::{local_ui_url, KernelHost, WasmPersist};
use crate::timers::TimerHeap;

/// The svelte-d LDC cell loaded into the browser. This is the UI *application*:
/// one persistent wasm instance with live DOM handles, interned
/// `window`/`document`/`console`, and `JsExports`. Not a kernel type, not
/// guest `WasmStart`.
pub struct WasmUi {
    /// Decoded LDC module; kept for event re-entry.
    pub module: Module,
    /// svelte-engine `window.__svelteD.ts` registry.
    pub js_exports: JsExports,
    pub(crate) persist: WasmPersist,
}

impl WasmUi {
    pub(crate) fn from_host(module: Module, host: &mut KernelHost<'_>) -> Self {
        Self {
            module,
            js_exports: host.js_exports.clone(),
            persist: WasmPersist {
                handles: std::mem::take(&mut host.handles),
                mount_path: std::mem::take(&mut host.mount_path),
                placements: std::mem::take(&mut host.placements),
                child_handles: std::mem::take(&mut host.child_handles),
                objects: std::mem::take(&mut host.objects),
                session_paths: std::mem::take(&mut host.session_paths),
                window_handle: host.window_handle,
                document_handle: host.document_handle,
                console_handle: host.console_handle,
                named_delegates: std::mem::take(&mut host.named_delegates),
                event_handlers: std::mem::take(&mut host.event_handlers),
            },
        }
    }

    /// Take persist tables for a UI-thread `KernelHost::attach` re-entry.
    pub(crate) fn take_persist(&mut self) -> WasmPersist {
        std::mem::take(&mut self.persist)
    }

    pub(crate) fn restore(&mut self, host: &mut KernelHost<'_>) {
        self.persist = WasmPersist {
            handles: std::mem::take(&mut host.handles),
            mount_path: std::mem::take(&mut host.mount_path),
            placements: std::mem::take(&mut host.placements),
            child_handles: std::mem::take(&mut host.child_handles),
            objects: std::mem::take(&mut host.objects),
            session_paths: std::mem::take(&mut host.session_paths),
            window_handle: host.window_handle,
            document_handle: host.document_handle,
            console_handle: host.console_handle,
            named_delegates: std::mem::take(&mut host.named_delegates),
            event_handlers: std::mem::take(&mut host.event_handlers),
        };
        self.js_exports = host.js_exports.clone();
    }

    /// Interned `window` handle (`libwasm_global("window")`), if `_start` or a
    /// later tick interned the browser globals.
    pub fn window(&self) -> Option<i32> {
        self.persist.window_handle
    }

    /// True when `App_svelte.fetchBios` (print-ts) is registered.
    pub fn has_fetch_bios(&self) -> bool {
        self.js_exports.lookup("App_svelte.fetchBios").is_some()
    }

    /// One re-entry into the persistent cell. `KernelHost` is a borrow of
    /// this instance plus the live DOM for the duration of the call — tables
    /// are not reconstructed empty. Timers (B89) use this; listeners use
    /// [`Self::call_listener`].
    pub(crate) fn call(
        &mut self,
        ui: UiBorrow<'_>,
        function_index: u32,
        args: &[i32],
    ) -> Result<WasmCall, String> {
        let persist = self.take_persist();
        let mut host = KernelHost::attach(
            ui.dom, ui.router, ui.spec, persist, ui.timers, ui.now_ns, ui.store,
        );
        host.js_exports = self.js_exports.clone();
        host.hw = ui.hw;
        let results = g6b_wasm::run_with_fuel_mut(
            &mut self.module,
            function_index,
            args,
            &mut host,
            g6b_wasm::DEFAULT_FUEL,
        );
        let default_prevented = host.last_prevent_default;
        let diagnostics = std::mem::take(&mut host.diagnostics);
        self.restore(&mut host);
        Ok(WasmCall {
            results: results?,
            default_prevented,
            diagnostics,
        })
    }

    /// Re-enter a wasm listener with an interned DOM `Event` (`clientX` /
    /// `preventDefault`).
    pub(crate) fn call_listener(
        &mut self,
        ui: UiBorrow<'_>,
        function_index: u32,
        listener_handle: i32,
        event: &g6b_dom::Event,
    ) -> Result<WasmCall, String> {
        let persist = self.take_persist();
        let mut host = KernelHost::attach(
            ui.dom, ui.router, ui.spec, persist, ui.timers, ui.now_ns, ui.store,
        );
        host.js_exports = self.js_exports.clone();
        host.hw = ui.hw;
        let event_handle = host.intern_event(event)?;
        let args = if listener_handle != 0 {
            vec![listener_handle, event_handle]
        } else {
            vec![event_handle]
        };
        let results = g6b_wasm::run_with_fuel_mut(
            &mut self.module,
            function_index,
            &args,
            &mut host,
            g6b_wasm::DEFAULT_FUEL,
        );
        let default_prevented = host.last_prevent_default;
        let diagnostics = std::mem::take(&mut host.diagnostics);
        self.restore(&mut host);
        Ok(WasmCall {
            results: results?,
            default_prevented,
            diagnostics,
        })
    }

    /// Re-enter a D delegate the way svelte-engine does: export
    /// `jsCallback(ctx, fun, argHandle)`, else `table.get(ptr)(ctx, handle)`.
    pub(crate) fn call_js_callback(
        &mut self,
        ui: UiBorrow<'_>,
        ctx: i32,
        ptr: i32,
        event: &g6b_dom::Event,
    ) -> Result<WasmCall, String> {
        let persist = self.take_persist();
        let mut host = KernelHost::attach(
            ui.dom, ui.router, ui.spec, persist, ui.timers, ui.now_ns, ui.store,
        );
        host.js_exports = self.js_exports.clone();
        host.hw = ui.hw;
        let event_handle = host.intern_event(event)?;
        let results = if let Some(idx) = g6b_wasm::export_func(&self.module, "jsCallback") {
            g6b_wasm::run_with_fuel_mut(
                &mut self.module,
                idx,
                &[ctx, ptr, event_handle],
                &mut host,
                g6b_wasm::DEFAULT_FUEL,
            )
        } else {
            let func = g6b_wasm::table_funcref(&self.module, ptr)?;
            g6b_wasm::run_with_fuel_mut(
                &mut self.module,
                func,
                &[ctx, event_handle],
                &mut host,
                g6b_wasm::DEFAULT_FUEL,
            )
        };
        let default_prevented = host.last_prevent_default;
        let diagnostics = std::mem::take(&mut host.diagnostics);
        self.restore(&mut host);
        Ok(WasmCall {
            results: results?,
            default_prevented,
            diagnostics,
        })
    }
}

/// Live session borrows for one wasm re-entry (B89).
pub(crate) struct UiBorrow<'a> {
    pub dom: &'a mut g6b_dom::Node,
    pub router: &'a Router,
    pub spec: &'a BoardSpec,
    pub timers: &'a mut TimerHeap,
    pub now_ns: u64,
    pub store: Option<&'a mut g6b_pglite::StoreRegistry>,
    /// Post-boot hw session. None only if a caller has no `BrowserSession`.
    pub hw: Option<&'a mut g6b_hw::HwSession>,
}

/// Result of [`WasmUi::call`].
pub(crate) struct WasmCall {
    pub results: Vec<i32>,
    pub default_prevented: bool,
    pub diagnostics: Vec<String>,
}

/// Kernel I/O the UI-thread wasm host may call. Lives next to `Router` because
/// `g6b-wasm` cannot depend on `g6b-http` (cycle: http already depends on wasm).
pub struct RouterPort<'a> {
    pub router: &'a Router,
    pub spec: &'a BoardSpec,
    pub store: Option<&'a mut dyn g6b_pglite::StorePort>,
}

impl KernelPort for RouterPort<'_> {
    fn fetch_text(&mut self, url: &str) -> Result<(u16, String), String> {
        let path = url.split(['?', '#']).next().unwrap_or(url);
        let path = match path {
            "/bios/cpu" => "/bios/menu/cpu",
            "/bios/uncore" => "/bios/menu/uncore",
            other => other,
        };
        let kernel_read = g6b_ui::setup_reads(self.spec).contains(&path);
        let ui_file = local_ui_url(path).is_some() && self.router.has_file(path);
        if !self.spec.kernel.http.enable
            || !self.spec.kernel.http.proxy_js
            || !(kernel_read || ui_file)
        {
            return Err(format!("disabled or unavailable: {url}"));
        }
        let store = self.store.as_mut().map(|s| {
            let s: &mut dyn g6b_pglite::StorePort = &mut **s;
            s
        });
        let resp = self.router.fetch_with_body("GET", path, &[], store);
        Ok((resp.status, resp.body_str()))
    }

    /// The UI's write side, deliberately narrow: **`/bios/store` only**.
    ///
    /// A BIOS UI needs to run SQL — create a table, insert a row, export to a key —
    /// and none of that is expressible as a GET. It does not need to POST to the
    /// power endpoints, the flash endpoints or a custom handler, so it cannot: the
    /// prefix is checked here rather than left to the router, because "the UI may
    /// write to its database" and "the UI may write anywhere" are different
    /// capabilities and only the first one was asked for.
    fn fetch_post(&mut self, url: &str, body: &str) -> Result<(u16, String), String> {
        let path = url.split(['?', '#']).next().unwrap_or(url);
        if !self.spec.kernel.http.enable || !self.spec.kernel.http.proxy_js {
            return Err(format!("disabled: {url}"));
        }
        if !(path == "/bios/store" || path.starts_with("/bios/store/")) {
            return Err(format!(
                "{path}: the BIOS UI may POST to /bios/store only (read the rest with fetch)"
            ));
        }
        let store = self.store.as_mut().map(|s| {
            let s: &mut dyn g6b_pglite::StorePort = &mut **s;
            s
        });
        let resp = self
            .router
            .fetch_with_body("POST", path, body.as_bytes(), store);
        Ok((resp.status, resp.body_str()))
    }

    fn holyc(&mut self, line: &str) -> Result<String, String> {
        // HolyC REPL is owned by `BrowserSession::holyc_request`. The wasm
        // cell's `holycEval` export is a diagnostic until that re-entry is
        // wired through the same port with a `&mut Program`.
        let _ = line;
        Ok(String::new())
    }

    fn register_endpoint(&mut self, path: &str, method: &str) -> Result<(), String> {
        let _ = (path, method);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use g6b_spec::BoardSpec;

    #[test]
    fn router_port_serves_ui_css_and_bios_menu() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let router = Router::from_spec(&spec);
        let mut port = RouterPort {
            router: &router,
            spec: &spec,
            store: None,
        };
        let (status, body) = port.fetch_text("/ui/bios-ui.css").unwrap();
        assert_eq!(status, 200);
        assert!(body.contains("bios-tab"), "{body}");
        let (status, body) = port.fetch_text("/bios/menu/cpu").unwrap();
        assert_eq!(status, 200);
        assert!(body.contains("cpu") || body.contains("items"), "{body}");
        assert!(port.fetch_text("https://evil").is_err());
    }
}
