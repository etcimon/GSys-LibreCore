// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! BIOS kernel host path: TempleOS/ZealOS services rewritten onto BoardSpec.
//!
//! HolyC init, HTML+JS viewport, optional Gr (SysGrInit), dual-band REPL.

#![allow(missing_docs)]

use g6b_dom::{Event, EventHost, EventInit, Node};
use g6b_holyc::{eval_src, Program, ReplResult};
use g6b_html::{parse, script_sources, to_uart_lines};
use g6b_http::Router;
use g6b_js::JsValue;
use g6b_js::Op;
use g6b_spec::BoardSpec;
use g6b_wasm::{Host, Ldexec, LdexecInit, LibwasmValue, ObjectKind, ObjectTable};
use std::collections::BTreeMap;

pub mod task_services;
pub mod tasks;
pub use task_services::{TaskServices, Work, WorkResponse};

/// Banner OpenSBI-next-stage QEMU eval greps for (`--expect G6LC-BIOS`).
pub const BANNER: &str = "G6LC-BIOS";

/// Fast-init marker printed by generated `HolycInit`.
pub const HOLYC_READY: &str = "HOLYC-READY";

/// DOM+JS UI boot marker.
pub const UI_BOOT: &str = "UI-BOOT";

/// Dual-band HolyC REPL banner (SSH-like TCP band / SSH+HolyC KVM face).
pub const REPL_BANNER: &str = "G6LC-BIOS HOLYC-REPL proto=holyc-repl backend=ssh-holyc";

/// Post-delegate mailbox loopback (not a netdev).
pub const LOOPBACK_BANNER: &str = "G6LC-BIOS LOOPBACK-MBOX proto=holyc-repl not_netdev=1";

/// g6b-wasm Host: DOM + kernel HTTP router (browser-ui `_start` imports).
struct KernelHost<'a> {
    dom: &'a mut Node,
    router: &'a Router,
    spec: &'a BoardSpec,
    diagnostics: Vec<String>,
    handles: Vec<Node>,
    pending_slot: Option<i32>,
    objects: ObjectTable<LibwasmValue>,
    /// Event listeners registered by the libwasm `_start` call and collected
    /// after `run_start` returns so `BrowserSession` can own them.
    pending_event_listeners: Vec<(String, String, u64, bool)>,
    pending_event_removals: Vec<u64>,
    last_await_failed: bool,
    last_await_error: String,
    last_await_value: String,
}

impl KernelHost<'_> {
    fn node(&self, h: i32) -> Result<&Node, String> {
        match h {
            1 => Ok(self.dom),
            h if h >= 2 => self
                .handles
                .get((h - 2) as usize)
                .ok_or_else(|| format!("invalid dom handle {h}")),
            _ => Err(format!("invalid dom handle {h}")),
        }
    }

    fn node_mut(&mut self, h: i32) -> Result<&mut Node, String> {
        match h {
            1 => Ok(self.dom),
            h if h >= 2 => self
                .handles
                .get_mut((h - 2) as usize)
                .ok_or_else(|| format!("invalid dom handle {h}")),
            _ => Err(format!("invalid dom handle {h}")),
        }
    }

    fn get_object(&self, h: i32) -> Result<&LibwasmValue, String> {
        self.objects.get(h)
    }

    fn record_await(&mut self, h: i32) -> Result<(), String> {
        let s = g6b_wasm::string_of(self.get_object(h)?);
        let failed = matches!(self.get_object(h)?, LibwasmValue::Error(_));
        self.record_await_from_string(s, failed);
        Ok(())
    }

    fn libwasm_value_to_js(value: &LibwasmValue, handle: i32) -> JsValue {
        match value {
            LibwasmValue::Object { .. } => JsValue::Handle(handle),
            LibwasmValue::String(s) | LibwasmValue::Error(s) => JsValue::Str(s.clone()),
            LibwasmValue::Bool(b) => JsValue::Bool(*b),
            LibwasmValue::I8(v) => JsValue::Num(f64::from(*v)),
            LibwasmValue::U8(v) => JsValue::Num(f64::from(*v)),
            LibwasmValue::I16(v) => JsValue::Num(f64::from(*v)),
            LibwasmValue::U16(v) => JsValue::Num(f64::from(*v)),
            LibwasmValue::I32(v) => JsValue::Num(f64::from(*v)),
            LibwasmValue::U32(v) => JsValue::Num(f64::from(*v)),
            LibwasmValue::I64(v) => JsValue::Num(*v as f64),
            LibwasmValue::U64(v) => JsValue::Num(*v as f64),
            LibwasmValue::F32(v) => JsValue::Num(f64::from(*v)),
            LibwasmValue::F64(v) => JsValue::Num(*v),
            LibwasmValue::I32Vec(items) => JsValue::Str(
                items
                    .iter()
                    .map(|v| v.to_string())
                    .collect::<Vec<_>>()
                    .join(","),
            ),
            LibwasmValue::U32Vec(items) => JsValue::Str(
                items
                    .iter()
                    .map(|v| v.to_string())
                    .collect::<Vec<_>>()
                    .join(","),
            ),
            LibwasmValue::None => JsValue::Null,
        }
    }

    fn libwasm_value_from_js(value: &JsValue) -> LibwasmValue {
        match value {
            JsValue::Undefined | JsValue::Null => LibwasmValue::empty(ObjectKind::Empty),
            JsValue::Bool(b) => LibwasmValue::Bool(*b),
            JsValue::Num(n) if n.is_nan() || n.is_infinite() => LibwasmValue::F64(*n),
            JsValue::Num(n) if n.fract() == 0.0 && n.abs() <= i64::MAX as f64 => {
                LibwasmValue::I64(*n as i64)
            }
            JsValue::Num(n) => LibwasmValue::F64(*n),
            JsValue::Str(s) => LibwasmValue::String(s.clone()),
            other => LibwasmValue::String(other.to_js_string()),
        }
    }

    fn intern_value(&mut self, value: LibwasmValue) -> Result<i32, String> {
        self.objects.add(value)
    }

    /// Run one Lodash chain through the first-party JS backend (`g6b-js`).
    ///
    /// The kernel host cannot re-enter the wasm instance to run a D iteratee —
    /// that is the B66 re-entrancy seam — so a chain carrying a callback fails
    /// closed here with a precise diagnostic rather than silently dropping the
    /// predicate and returning a wrong answer.
    fn run_lodash(&mut self, call: Ldexec<'_>) -> Result<JsValue, String> {
        let init = match &call.init {
            LdexecInit::Handle(0) => JsValue::Null,
            LdexecInit::Handle(h) => match self.get_object(*h) {
                Ok(v) => Self::libwasm_value_to_js(v, *h),
                Err(e) => return Err(e),
            },
            // `VarType.eval` means "evaluate this JS to seed the chain".
            // There is no host evaluator; BoardSpec scope lookup is B63.
            LdexecInit::Str { text, eval: true } => {
                return Err(format!(
                    "WASM lodash refuses an eval seed {text:?}: no host JS evaluator"
                ))
            }
            LdexecInit::Str { text, eval: false } => JsValue::Str(text.clone()),
            LdexecInit::Long(v) => JsValue::Num(*v as f64),
        };
        let commands = g6b_js::lodash_parse(call.commands).map_err(|e| e.to_string())?;
        let value = g6b_js::lodash_execute(init, &commands, None).map_err(|e| e.to_string())?;
        self.diagnostics
            .push(format!("WASM-LODASH {} steps", commands.len()));
        Ok(value)
    }

    fn record_await_from_string(&mut self, s: String, failed: bool) {
        if failed {
            self.last_await_failed = true;
            self.last_await_error = s;
            self.last_await_value.clear();
        } else {
            self.last_await_failed = false;
            self.last_await_error.clear();
            self.last_await_value = s;
        }
    }
}

impl Host for KernelHost<'_> {
    fn libwasm_objects(&self) -> Option<&ObjectTable<LibwasmValue>> {
        Some(&self.objects)
    }
    fn libwasm_objects_mut(&mut self) -> Option<&mut ObjectTable<LibwasmValue>> {
        Some(&mut self.objects)
    }

    fn set_inner_text(&mut self, id: &str, val: &str) -> Result<(), String> {
        if let Some(n) = self.dom.get_element_by_id(id) {
            if n.get_attribute("data-preserve") != Some("true") {
                n.set_inner_text(val);
            }
            Ok(())
        } else if optional_ui_id(self.spec, id) {
            Ok(())
        } else {
            Err(format!("WASM missing element {id}"))
        }
    }

    fn log(&mut self, msg: &str) {
        self.diagnostics.push(format!("WASM-LOG {msg}"));
    }

    fn set_visible(&mut self, id: &str, on: bool) -> Result<(), String> {
        if let Some(n) = self.dom.get_element_by_id(id) {
            n.set_visible(on);
            Ok(())
        } else if optional_ui_id(self.spec, id) {
            Ok(())
        } else {
            Err(format!("WASM missing element {id}"))
        }
    }

    fn fetch(&mut self, url: &str) -> Result<i32, String> {
        let path = url.split(['?', '#']).next().unwrap_or(url);
        let path = match path {
            "/bios/cpu" => "/bios/menu/cpu",
            "/bios/uncore" => "/bios/menu/uncore",
            other => other,
        };
        if !self.spec.kernel.http.enable
            || !self.spec.kernel.http.proxy_js
            || !g6b_ui::setup_reads(self.spec).contains(&path)
        {
            self.diagnostics
                .push(format!("WASM-SKIP-FETCH {url}: disabled or unavailable"));
            return Ok(0);
        }
        let resp = self.router.fetch_get(path);
        self.diagnostics
            .push(format!("WASM-FETCH {url} {}", resp.status));
        if resp.status != 200 {
            let msg = format!("WASM fetch {url}: HTTP {}", resp.status);
            return self.intern_value(LibwasmValue::Error(msg));
        }
        paint_response(self.dom, path, &resp.body_str())?;
        self.intern_value(LibwasmValue::String(resp.body_str()))
    }

    fn create_element(&mut self, tag: &str) -> Result<i32, String> {
        let idx = self.handles.len() as i32;
        self.handles.push(Node::elem(tag));
        Ok(idx + 2)
    }

    fn append_child(&mut self, parent: i32, child: i32) -> Result<(), String> {
        let child = self.node(child)?.clone();
        self.node_mut(parent)?.children.push(child);
        Ok(())
    }

    fn set_property(&mut self, obj: i32, key: &str, value: &str) -> Result<(), String> {
        let n = self.node_mut(obj)?;
        match key {
            "innerText" | "textContent" => n.set_inner_text(value),
            _ => {
                n.attributes.insert(key.into(), value.into());
                n.dirty = true;
            }
        }
        Ok(())
    }

    fn libwasm_await_void(&mut self, slot: i32) -> Result<(), String> {
        self.diagnostics
            .push(format!("WASM-AWAIT-VOID slot={slot}"));
        self.pending_slot = Some(slot);
        Ok(())
    }

    fn take_slot(&mut self) -> Option<i32> {
        self.pending_slot.take()
    }

    fn resolve_slot(&mut self, slot: i32) -> Result<(), String> {
        self.diagnostics
            .push(format!("WASM-AWAIT-RESOLVED slot={slot}"));
        self.record_await(slot)
    }

    fn holyc(&mut self, _ptr: i32, _len: i32) -> Result<i32, String> {
        self.diagnostics.push("WASM-HOLYC".into());
        Ok(0)
    }

    fn register_endpoint(&mut self, _a: i32, _b: i32, _c: i32, _d: i32) -> Result<i32, String> {
        self.diagnostics.push("WASM-REGISTER-ENDPOINT".into());
        Ok(0)
    }

    fn add_event_listener(
        &mut self,
        target_id: &str,
        event_type: &str,
        listener_id: u64,
        capture: bool,
    ) -> Result<(), String> {
        self.diagnostics.push(format!(
            "WASM-ADD-EVENT-LISTENER {target_id} {event_type} {listener_id} capture={capture}"
        ));
        self.pending_event_listeners.push((
            target_id.into(),
            event_type.into(),
            listener_id,
            capture,
        ));
        Ok(())
    }

    fn remove_event_listener(&mut self, listener_id: u64) -> Result<(), String> {
        self.diagnostics
            .push(format!("WASM-REMOVE-EVENT-LISTENER {listener_id}"));
        self.pending_event_removals.push(listener_id);
        Ok(())
    }

    fn await_failed(&self) -> i32 {
        i32::from(self.last_await_failed)
    }

    fn await_error(&self) -> String {
        self.last_await_error.clone()
    }

    fn await_value(&self) -> String {
        self.last_await_value.clone()
    }

    fn note_await_fail(&mut self, handle: i32) -> Result<(), String> {
        let s = if handle == 0 {
            String::new()
        } else {
            g6b_wasm::string_of(self.get_object(handle)?)
        };
        self.record_await_from_string(s, true);
        Ok(())
    }

    fn note_await_ok(&mut self, handle: i32) -> Result<(), String> {
        let s = if handle == 0 {
            String::new()
        } else {
            g6b_wasm::string_of(self.get_object(handle)?)
        };
        self.record_await_from_string(s, false);
        Ok(())
    }

    fn ldexec_string(&mut self, call: Ldexec<'_>) -> Result<String, String> {
        Ok(self.run_lodash(call)?.to_js_string())
    }

    fn ldexec_long(&mut self, call: Ldexec<'_>) -> Result<i64, String> {
        let n = self.run_lodash(call)?.to_number();
        Ok(if n.is_finite() { n as i64 } else { 0 })
    }

    fn ldexec_double(&mut self, call: Ldexec<'_>) -> Result<f64, String> {
        Ok(self.run_lodash(call)?.to_number())
    }

    fn ldexec_handle(&mut self, call: Ldexec<'_>) -> Result<i32, String> {
        let value = self.run_lodash(call)?;
        match value {
            JsValue::Handle(h) => Ok(h),
            JsValue::Undefined | JsValue::Null => Ok(0),
            _ => self.intern_value(Self::libwasm_value_from_js(&value)),
        }
    }
}

/// Default setup page: HTML + AOT JS painted on the BIOS viewport.
/// Always includes the FAT32 flash picker; FileMgr is added by [`setup_html`].
pub const SETUP_HTML: &str = r#"<!DOCTYPE html>
<html><head><title>G6LC-BIOS</title></head>
<body>
<h1 id="banner">G6LC-BIOS</h1>
<p>Hold DEL to stay. Esc or timeout continues boot.</p>
<p id="opp">opp: idle</p>
<p id="status">boot</p>
<section id="usb-flash">
<h2 id="usb-title">USB-FAT32</h2>
<p id="usb-list">openwrt.bin g6lc_bios.elf linux.img</p>
</section>
<script>
document.getElementById("status").innerText = "UI-BOOT";
document.getElementById("opp").innerText = "opp: idle";
fetch("/bios/clocks");
fetch("/bios/usb/ls");
fetch("/bios/menu");
</script>
</body></html>
"#;

/// Spec-shaped setup page: FAT32 flash always; USB-key FileMgr when `usb.key`.
pub fn setup_html(spec: &BoardSpec) -> String {
    let html = g6b_ui::setup_html(spec);
    let script = g6b_ui::setup_script(spec);
    html.replace("</body>", &format!("<script>{script}</script></body>"))
}

fn optional_ui_id(spec: &BoardSpec, id: &str) -> bool {
    match id {
        "fm-list" | "fm-tabs" => !spec.kernel.usb.enable || !spec.kernel.usb.key,
        "usb-title" | "usb-list" => !spec.kernel.usb.enable || !spec.kernel.usb.flash_fat32,
        _ => false,
    }
}

/// A registered event listener. AOT listeners carry a `DomProgram`; libwasm
/// listeners carry a guest function index / object handle.
#[derive(Clone)]
pub enum Listener {
    Aot(Vec<Op>),
    Wasm { function_index: u32, handle: i32 },
}

/// Host-side callback table for DOM listeners. Kept separate from `Node` so
/// `Node` stays `Clone` and so AOT/libwasm callbacks can be owned by the
/// `BrowserSession`.
pub struct BrowserEventHost {
    next_id: u64,
    listeners: BTreeMap<u64, Listener>,
    /// Listeners triggered during an in-progress `dispatch_event`. Processed
    /// after propagation completes so the DOM is not borrowed twice.
    triggered: Vec<(u64, Event)>,
}

impl Default for BrowserEventHost {
    fn default() -> Self {
        Self {
            next_id: 1,
            listeners: BTreeMap::new(),
            triggered: Vec::new(),
        }
    }
}

impl BrowserEventHost {
    pub fn register(&mut self, listener: Listener) -> u64 {
        let id = self.next_id;
        self.next_id += 1;
        self.listeners.insert(id, listener);
        id
    }

    pub fn remove(&mut self, id: u64) {
        self.listeners.remove(&id);
    }

    pub fn take_triggered(&mut self) -> Vec<(u64, Event)> {
        std::mem::take(&mut self.triggered)
    }
}

impl EventHost for BrowserEventHost {
    fn invoke(&mut self, listener_id: u64, event: &mut Event) {
        // Record for deferred execution; the concrete AOT/WASM callback runs
        // after `dispatch_event` returns, when the DOM borrow is free.
        self.triggered.push((listener_id, event.clone()));
    }
}

pub struct BrowserSession {
    pub dom: Node,
    pub program: Program,
    pub diagnostics: Vec<String>,
    pub wasm_executed: bool,
    pub task_services: Option<task_services::TaskServices>,
    pub hit_boxes: Vec<g6b_css::render::HitBox>,
    pub event_host: BrowserEventHost,
    /// Decoded libwasm module; kept for listener re-entry.
    pub wasm_module: Option<g6b_wasm::Module>,
    /// libwasm object table persisted from `_start`.
    pub wasm_objects: Option<ObjectTable<LibwasmValue>>,
    /// libwasm DOM handles persisted from `_start`.
    pub wasm_handles: Option<Vec<Node>>,
    /// Which UI surface feeds the scanout. Starts at the BoardSpec default
    /// (which follows the highest-priority output's class) and is flipped by
    /// the `#disp-toggle` control or `DisplaySurface` in the HolyC lane.
    pub surface: g6b_spec::Surface,
    selected_menu: String,
    async_scripts: g6b_js::AsyncScheduler,
    spec: BoardSpec,
}

impl BrowserSession {
    pub fn new(spec: &BoardSpec) -> Result<Self, String> {
        Self::from_program(spec, load_program(spec)?)
    }

    fn from_program(spec: &BoardSpec, program: Program) -> Result<Self, String> {
        let mut session = Self {
            dom: g6b_html::parse_checked(&setup_html(spec))?,
            program,
            diagnostics: Vec::new(),
            wasm_executed: false,
            task_services: if spec.kernel.tasking.enable {
                Some(task_services::TaskServices::new(spec).map_err(|error| error.to_string())?)
            } else {
                None
            },
            hit_boxes: Vec::new(),
            event_host: BrowserEventHost::default(),
            wasm_module: None,
            wasm_objects: None,
            wasm_handles: None,
            surface: spec.default_surface(),
            selected_menu: spec.kernel.start_menu.clone(),
            async_scripts: g6b_js::AsyncScheduler::default(),
            spec: spec.clone(),
        };
        if spec.kernel.js == "aot" {
            for src in script_sources(&session.dom) {
                session.execute_script(&src)?;
            }
        }
        if spec.kernel.wasm.enable {
            let module = g6b_wasm::decode(g6b_wasm::bios_ui_wasm())?;
            let mut host = KernelHost {
                dom: &mut session.dom,
                router: &session.program.router,
                spec,
                diagnostics: Vec::new(),
                handles: Vec::new(),
                pending_slot: None,
                objects: ObjectTable::new(),
                pending_event_listeners: Vec::new(),
                pending_event_removals: Vec::new(),
                last_await_failed: false,
                last_await_error: String::new(),
                last_await_value: String::new(),
            };
            g6b_wasm::run_start(&module, &mut host)?;
            session.wasm_executed = true;
            session
                .diagnostics
                .extend(std::mem::take(&mut host.diagnostics));
            session.diagnostics.push("WASM-INTERPRETER _start".into());
            let pending = std::mem::take(&mut host.pending_event_listeners);
            let removals = std::mem::take(&mut host.pending_event_removals);
            let objects = std::mem::take(&mut host.objects);
            let handles = std::mem::take(&mut host.handles);
            drop(host);
            session.wasm_module = Some(module);
            session.wasm_objects = Some(objects);
            session.wasm_handles = Some(handles);
            session.apply_pending_wasm_listeners(&pending)?;
            for id in &removals {
                session.remove_event_listener(*id);
            }
            session.refresh()?;
        }
        session.select_menu(&spec.kernel.start_menu)?;
        Ok(session)
    }

    pub fn execute_script(&mut self, source: &str) -> Result<(), String> {
        if self.spec.kernel.js != "aot" {
            return Err("JavaScript is disabled by BoardSpec".into());
        }
        for op in g6b_js::compile(source)? {
            match op {
                Op::Fetch { method, url } => {
                    if !self.spec.kernel.http.enable || !self.spec.kernel.http.proxy_js {
                        return Err(format!("JS fetch disabled by BoardSpec: {url}"));
                    }
                    let resp = self.program.router.fetch(&method, &url);
                    self.diagnostics
                        .push(format!("JS-FETCH {url} {}", resp.status));
                    if resp.status != 200 {
                        return Err(format!("JS fetch {url}: HTTP {}", resp.status));
                    }
                    paint_response(&mut self.dom, &url, &resp.body_str())?;
                }
                Op::RegisterEndpoint { method, path } => {
                    if !self.spec.kernel.http.enable || !self.spec.kernel.http.proxy_js {
                        return Err("JS endpoint registration is disabled".into());
                    }
                    if !path.starts_with("/bios/custom/") && path != "/bios/custom" {
                        return Err("JS endpoints must be under /bios/custom".into());
                    }
                    self.program.router.insert(
                        &method,
                        &path,
                        "js",
                        format!(
                            "{{\"origin\":\"js\",\"path\":{}}}",
                            g6b_spec::quote_json(&path)
                        ),
                    );
                }
                Op::HolycEval { line } => match self.holyc_request(&line)? {
                    ReplResult::Output(out) => self
                        .diagnostics
                        .push(format!("HOLYC-EVAL {}", out.trim_end())),
                    ReplResult::Exit => return Err("HolyC session exited".into()),
                },
                Op::GetContext { .. }
                    if !self.spec.kernel.proxy.enable || !self.spec.kernel.proxy.gl =>
                {
                    return Err("GL adapter disabled by BoardSpec".into());
                }
                Op::Log { value } => self.diagnostics.push(format!("JS-LOG {value}")),
                other => g6b_js::run(&[other], &mut self.dom)?,
            }
        }
        Ok(())
    }

    pub fn holyc_request(&mut self, line: &str) -> Result<ReplResult, String> {
        if line
            .split('(')
            .next()
            .is_some_and(|name| name.trim() == "ThreadCreate")
        {
            let services = self
                .task_services
                .as_mut()
                .ok_or("Task services disabled by BoardSpec")?;
            let id = services
                .thread_command(&self.program, line)
                .map_err(|error| error.to_string())?;
            let info = services.task(id).map_err(|error| error.to_string())?;
            return Ok(ReplResult::Output(format!(
                "THREAD-CREATED {}:{} hart={} queued\n",
                id.slot(),
                id.generation(),
                info.hart
            )));
        }
        self.program.repl(line)
    }

    pub fn enqueue_async_script(&mut self, source: &str) -> Result<g6b_js::TaskId, String> {
        if self.spec.kernel.js != "aot" {
            return Err("JavaScript is disabled by BoardSpec".into());
        }
        let program = g6b_js::compile_async_with_limits(source, self.async_scripts.limits())
            .map_err(|error| error.to_string())?;
        self.async_scripts
            .spawn(program)
            .map_err(|error| error.to_string())
    }

    pub fn cancel_async_script(&mut self, task: g6b_js::TaskId) -> bool {
        self.async_scripts.cancel(task)
    }

    pub fn poll_async(&mut self) -> g6b_js::AsyncTick {
        let mut tick = self.async_scripts.tick(&mut self.dom);
        let reads = g6b_ui::setup_reads(&self.spec);
        for event in &tick.events {
            if let g6b_js::AsyncEvent::Request {
                token, method, url, ..
            } = event
            {
                let result = if !self.spec.kernel.http.proxy_js
                    || method != "GET"
                    || !reads.contains(&url.as_str())
                {
                    Err(format!("async kernel read unavailable: {url}"))
                } else {
                    let response = self.program.router.fetch_get(url);
                    if response.status == 200 {
                        let limit = self.async_scripts.limits().max_response_bytes;
                        Ok(String::from_utf8_lossy(
                            &response.body[..response.body.len().min(limit + 1)],
                        )
                        .into_owned())
                    } else {
                        Err(format!("async kernel read HTTP {}: {url}", response.status))
                    }
                };
                self.async_scripts.complete(*token, result);
            }
        }
        tick.ready = self.async_scripts.ready_tasks();
        tick.pending = self.async_scripts.pending_tasks();
        tick
    }

    pub fn refresh(&mut self) -> Result<(), String> {
        if self.spec.kernel.http.enable && self.spec.kernel.http.proxy_js {
            for url in g6b_ui::setup_reads(&self.spec) {
                let response = self.program.router.fetch_get(url);
                if response.status != 200 {
                    return Err(format!("refresh {url}: HTTP {}", response.status));
                }
                paint_response(&mut self.dom, url, &response.body_str())?;
            }
        }
        Ok(())
    }

    /// Flip the scanout surface through the shared `/bios/display` route.
    ///
    /// Fail-closed: a board with no accelerated output has no POST route, so
    /// the router answers non-200 and the surface is left alone. On success the
    /// status line and the toggle's `data-surface` are repainted, so the DOM,
    /// the router and `Proxy` agree without a second source of truth.
    pub fn toggle_surface(&mut self) -> Result<g6b_spec::Surface, String> {
        if !self.spec.surface_toggle() {
            return Err("no accelerated display output to toggle to".into());
        }
        let response = self.program.router.fetch("POST", "/bios/display");
        if response.status != 200 {
            return Err(format!("display toggle HTTP {}", response.status));
        }
        let want = self.surface.toggled();
        self.surface = want;
        let out = self.spec.default_output();
        if let Some(node) = self.dom.get_element_by_id("disp-status") {
            node.set_inner_text(&format!(
                "{} {} {}",
                out.class.as_str(),
                want.as_str(),
                out.id
            ));
        }
        if let Some(node) = self.dom.get_element_by_id("disp-toggle") {
            node.set_attribute("data-surface", want.as_str())?;
            node.set_inner_text(if want == g6b_spec::Surface::Gpu {
                "VGA view"
            } else {
                "GPU view"
            });
        }
        self.diagnostics
            .push(format!("DISP-SURFACE {}", want.as_str()));
        Ok(want)
    }

    /// A `Proxy` reflecting this session's live surface, for the host PPM
    /// paths. Keeps `BrowserSession` and `g6b_gr::proxy` on one decision.
    pub fn proxy(&self) -> g6b_gr::proxy::Proxy {
        let mut p = g6b_gr::proxy::Proxy::from_spec(&self.spec);
        // A refused surface leaves the proxy default rather than lying.
        let _ = p.set_surface(self.surface);
        p
    }

    pub fn select_menu(&mut self, id: &str) -> Result<(), String> {
        if !g6b_ui::MENUS.iter().any(|face| face.id == id) {
            return Err(format!("unknown menu {id}"));
        }
        for face in g6b_ui::MENUS {
            let panel = self
                .dom
                .get_element_by_id(&format!("menu-{}", face.id))
                .ok_or_else(|| format!("missing menu {}", face.id))?;
            panel.set_visible(face.id == id);
        }
        if self.selected_menu != id {
            self.async_scripts.cancel_all();
        }
        self.selected_menu = id.into();
        Ok(())
    }

    pub fn handle_key(&mut self, key: &str) -> Result<bool, String> {
        if key == "F10" {
            self.refresh()?;
            return Ok(true);
        }
        if let Some(id) = g6b_ui::menu_for_key(&self.selected_menu, key) {
            self.select_menu(id)?;
            return Ok(true);
        }
        Ok(false)
    }

    pub fn lines(&self, width: usize) -> Vec<String> {
        to_uart_lines(&self.dom, width)
    }

    /// Refresh the CSS-raster output and update the hit boxes for this session.
    pub fn render_hit_boxes(&mut self) -> Result<(), String> {
        let html = setup_html(&self.spec);
        let css = extract_style(&html);
        let w = self.spec.kernel.gr.w.max(320);
        let h = self.spec.kernel.gr.h.max(200);
        let out = g6b_css::render::render_ui_to_output(&html, &css, w, h)?;
        self.hit_boxes = out.hit_boxes;
        Ok(())
    }

    /// Register a listener on the node at `target_path` and return its id.
    /// The `listener` closure is invoked when an event of `event_type` reaches
    /// the node in the given phase.
    /// Register a listener on the node whose `id` attribute is `target_id`.
    pub fn add_event_listener_by_id(
        &mut self,
        target_id: &str,
        event_type: &str,
        capture: bool,
        listener: Listener,
    ) -> Result<u64, String> {
        let path = path_to_id(&self.dom, target_id).ok_or_else(|| format!("no id={target_id}"))?;
        self.add_event_listener(&path, event_type, capture, listener)
    }

    pub fn add_event_listener(
        &mut self,
        target_path: &[usize],
        event_type: &str,
        capture: bool,
        listener: Listener,
    ) -> Result<u64, String> {
        let body = body_node(&mut self.dom).ok_or("no body node")?;
        let mut node = body;
        for &i in target_path {
            if i >= node.children.len() {
                return Err("hit box path out of range".into());
            }
            node = &mut node.children[i];
        }
        let id = self.event_host.register(listener);
        node.add_event_listener(event_type, capture, id);
        Ok(id)
    }

    /// Register listeners recorded by `KernelHost` during libwasm `_start`.
    pub fn apply_pending_wasm_listeners(
        &mut self,
        pending: &[(String, String, u64, bool)],
    ) -> Result<(), String> {
        for (target_id, event_type, listener_id, capture) in pending {
            self.add_event_listener_by_id(
                target_id,
                event_type,
                *capture,
                Listener::Wasm {
                    function_index: *listener_id as u32,
                    handle: 0,
                },
            )
            .unwrap_or_else(|e| {
                self.diagnostics.push(format!(
                    "WASM-EVENT-REGISTER-FAILED {target_id} {event_type}: {e}"
                ));
                0
            });
        }
        Ok(())
    }

    /// Remove a listener from both the host table and from any DOM node.
    pub fn remove_event_listener(&mut self, id: u64) {
        self.event_host.remove(id);
        remove_listener_from_node(&mut self.dom, id);
    }

    /// Dispatch a pointer event at the first hit box containing `(x, y)`.
    /// Returns `true` if the default action may run.
    pub fn dispatch_pointer(
        &mut self,
        x: i32,
        y: i32,
        event_type: &str,
        detail: &str,
    ) -> Result<bool, String> {
        let body = body_node(&mut self.dom).ok_or("no body node")?;
        let hit = self
            .hit_boxes
            .iter()
            .rev()
            .find(|h| x >= h.x && x < h.x + h.w && y >= h.y && y < h.y + h.h)
            .ok_or("no hit target")?;
        let mut event = Event::new(
            event_type,
            EventInit {
                bubbles: true,
                cancelable: true,
                composed: true,
                detail: detail.into(),
            },
        );
        event.target = hit.id.clone();
        let allowed = Node::dispatch_event(body, &hit.path, &mut event, &mut self.event_host);
        self.run_triggered();
        Ok(allowed)
    }

    /// Dispatch a keyboard event to the currently focused target. If no target
    /// is provided, the selected menu row is used.
    pub fn dispatch_key(
        &mut self,
        target_path: &[usize],
        key: &str,
        event_type: &str,
    ) -> Result<bool, String> {
        let body = body_node(&mut self.dom).ok_or("no body node")?;
        let mut node = &mut *body;
        for &i in target_path {
            if i >= node.children.len() {
                return Err("key dispatch path out of range".into());
            }
            node = &mut node.children[i];
        }
        let mut event = Event::new(
            event_type,
            EventInit {
                bubbles: true,
                cancelable: true,
                composed: true,
                detail: key.into(),
            },
        );
        event.target = node.id.clone();
        let path: Vec<usize> = target_path.to_vec();
        let allowed = Node::dispatch_event(body, &path, &mut event, &mut self.event_host);
        self.run_triggered();
        Ok(allowed)
    }

    fn run_triggered(&mut self) {
        for (id, _event) in self.event_host.take_triggered() {
            let _ = self.listeners_run(id, _event);
        }
    }

    fn listeners_run(&mut self, id: u64, event: Event) -> Result<(), String> {
        match self.event_host.listeners.get(&id).cloned() {
            Some(Listener::Aot(ops)) => {
                // AOT listener programs run in a follow-up pass once the DOM
                // borrow from `dispatch_event` is released. The event detail is
                // substituted for the literal string "{detail}" inside string
                // payload fields so simple handlers can echo it.
                let ops = substitute_detail(&ops, &event.detail);
                if let Err(e) = g6b_js::run(&ops, &mut self.dom) {
                    self.diagnostics.push(format!("EVENT-AOT-ERROR {id}: {e}"));
                } else {
                    self.diagnostics.push(format!("EVENT-AOT-TRIGGERED {id}"));
                }
            }
            Some(Listener::Wasm {
                function_index,
                handle,
            }) => {
                // libwasm re-entry: the host calls the guest listener function
                // with `handle` as its first argument.
                match self.wasm_module {
                    Some(ref mut module) => {
                        let objects = self.wasm_objects.take().unwrap_or_default();
                        let handles = self.wasm_handles.take().unwrap_or_default();
                        let mut host = KernelHost {
                            dom: &mut self.dom,
                            router: &self.program.router,
                            spec: &self.spec,
                            diagnostics: Vec::new(),
                            handles,
                            pending_slot: None,
                            objects,
                            pending_event_listeners: Vec::new(),
                            pending_event_removals: Vec::new(),
                            last_await_failed: false,
                            last_await_error: String::new(),
                            last_await_value: String::new(),
                        };
                        // Build an event object handle and pass the original
                        // `handle` as a second argument for libwasm delegates.
                        let event_handle = host
                            .objects
                            .add(LibwasmValue::Object {
                                kind: g6b_wasm::ObjectKind::Element,
                                props: [
                                    ("type".into(), LibwasmValue::String(event.event_type)),
                                    ("detail".into(), LibwasmValue::String(event.detail)),
                                ]
                                .into(),
                            })
                            .map_err(|e| e.to_string())?;
                        let args = if handle != 0 {
                            vec![handle, event_handle]
                        } else {
                            vec![event_handle]
                        };
                        let fuel = g6b_wasm::DEFAULT_FUEL;
                        match g6b_wasm::run_with_fuel_mut(
                            module,
                            function_index,
                            &args,
                            &mut host,
                            fuel,
                        ) {
                            Ok(_) => self.diagnostics.push(format!("EVENT-WASM-TRIGGERED {id}")),
                            Err(e) => self.diagnostics.push(format!("EVENT-WASM-ERROR {id}: {e}")),
                        }
                        self.diagnostics.extend(host.diagnostics);
                        self.wasm_objects = Some(host.objects);
                        self.wasm_handles = Some(host.handles);
                    }
                    None => {
                        self.diagnostics.push(format!(
                            "EVENT-WASM-NO-MODULE {id} fn={function_index} h={handle}"
                        ));
                    }
                }
            }
            None => {}
        }
        Ok(())
    }
}

fn substitute_detail(ops: &[Op], detail: &str) -> Vec<Op> {
    let sub = |s: &str| s.replace("{detail}", detail);
    let mutate = |m: &g6b_js::Mutation| match m.clone() {
        g6b_js::Mutation::SetInnerText { value } => {
            g6b_js::Mutation::SetInnerText { value: sub(&value) }
        }
        g6b_js::Mutation::SetAttribute { name, value } => g6b_js::Mutation::SetAttribute {
            name,
            value: sub(&value),
        },
        g6b_js::Mutation::AppendText { value } => {
            g6b_js::Mutation::AppendText { value: sub(&value) }
        }
        other => other,
    };
    ops.iter()
        .map(|op| match op.clone() {
            Op::SetInnerText { id, value } => Op::SetInnerText {
                id,
                value: sub(&value),
            },
            Op::Log { value } => Op::Log { value: sub(&value) },
            Op::HolycEval { line } => Op::HolycEval { line: sub(&line) },
            Op::SetAttribute { id, name, value } => Op::SetAttribute {
                id,
                name,
                value: sub(&value),
            },
            Op::AppendText { id, value } => Op::AppendText {
                id,
                value: sub(&value),
            },
            Op::QuerySelector { selector, mutation } => Op::QuerySelector {
                selector,
                mutation: mutate(&mutation),
            },
            Op::DomTransaction { program } => Op::DomTransaction { program },
            other => other,
        })
        .collect()
}

fn body_node(node: &mut Node) -> Option<&mut Node> {
    if node.name.eq_ignore_ascii_case("body") {
        return Some(node);
    }
    for child in &mut node.children {
        if let Some(n) = body_node(child) {
            return Some(n);
        }
    }
    None
}

fn path_to_id(root: &Node, id: &str) -> Option<Vec<usize>> {
    fn walk(node: &Node, id: &str, path: &mut Vec<usize>) -> Option<Vec<usize>> {
        if node.id.as_deref() == Some(id) {
            return Some(path.clone());
        }
        for (i, child) in node.children.iter().enumerate() {
            path.push(i);
            if let Some(p) = walk(child, id, path) {
                return Some(p);
            }
            path.pop();
        }
        None
    }
    // Locate the <body> node and return the path from there, matching the
    // CSS hit-box convention used by `BrowserSession`.
    fn find_body<'a>(node: &'a Node, path: &mut Vec<usize>) -> Option<&'a Node> {
        if node.name.eq_ignore_ascii_case("body") {
            return Some(node);
        }
        for (i, child) in node.children.iter().enumerate() {
            path.push(i);
            if let Some(b) = find_body(child, path) {
                return Some(b);
            }
            path.pop();
        }
        None
    }
    if let Some(body) = find_body(root, &mut Vec::new()) {
        return walk(body, id, &mut Vec::new());
    }
    walk(root, id, &mut Vec::new())
}

fn remove_listener_from_node(node: &mut Node, id: u64) {
    node.remove_event_listener(id);
    for child in &mut node.children {
        remove_listener_from_node(child, id);
    }
}

fn paint_response(dom: &mut Node, url: &str, body: &str) -> Result<(), String> {
    let url = url.split('?').next().unwrap_or(url);
    if let Some(face) = g6b_ui::face_for_fetch(url) {
        if face.kind == g6b_ui::Kind::Menu {
            let menu = g6b_spec::parse_json(body)?;
            if menu.get("id").as_str() != Some(face.id) {
                return Err(format!("menu response id mismatch for {url}"));
            }
            let title = menu.get("title").as_str().ok_or("menu missing title")?;
            let g6b_spec::Json::Arr(items) = menu.get("items") else {
                return Err("menu missing items".into());
            };
            let panel = dom
                .get_element_by_id(&format!("menu-{}", face.id))
                .ok_or("menu missing panel")?;
            let expected: std::collections::BTreeSet<String> = panel
                .query_selector_all("[data-item]")?
                .iter()
                .filter_map(|row| row.get_attribute("data-item").map(String::from))
                .collect();
            let mut seen = std::collections::BTreeSet::new();
            let mut updates = Vec::new();
            for item in items {
                let id = item.get("id").as_str().ok_or("menu row missing id")?;
                let value = item.get("value").as_str().ok_or("menu row missing value")?;
                let label = item.get("label").as_str().ok_or("menu row missing label")?;
                let writable = item
                    .get("writable")
                    .as_bool()
                    .ok_or("menu row missing writable flag")?;
                if !expected.contains(id) || !seen.insert(id.to_string()) {
                    return Err(format!("unknown or duplicate menu row {id}"));
                }
                updates.push((id, value, label, writable));
            }
            if seen != expected {
                return Err("menu response row set mismatch".into());
            }
            for (id, _, _, _) in &updates {
                for prefix in ["row", "label", "access"] {
                    let target = format!("{prefix}-{}-{id}", face.id);
                    if dom.get_element_by_id(&target).is_none() {
                        return Err(format!("missing menu cell {target}"));
                    }
                }
            }
            dom.get_element_by_id(face.paint_id())
                .ok_or("missing menu title")?
                .set_inner_text(title);
            for (id, value, label, writable) in updates {
                for (prefix, text) in [
                    ("row", value),
                    ("label", label),
                    (
                        "access",
                        if writable {
                            "Writable in spec; editing unavailable"
                        } else {
                            "Read-only"
                        },
                    ),
                ] {
                    if let Some(node) = dom.get_element_by_id(&format!("{prefix}-{}-{id}", face.id))
                    {
                        node.set_inner_text(text);
                    }
                }
            }
        } else if let Some(node) = dom.get_element_by_id(face.paint_id()) {
            node.set_inner_text(body);
        }
    } else if url == "/bios/display" {
        // Compact summary rather than raw JSON: the status line is read by a
        // human and by the UART/Gr lanes, and it must agree with `DISP-SEL`.
        let v = g6b_spec::parse_json(body)?;
        let class = v.get("class").as_str().ok_or("display missing class")?;
        let surface = v.get("surface").as_str().ok_or("display missing surface")?;
        let active = v.get("active").as_str().ok_or("display missing active")?;
        if let Some(node) = dom.get_element_by_id("disp-status") {
            node.set_inner_text(&format!("{class} {surface} {active}"));
        }
        if let Some(node) = dom.get_element_by_id("disp-toggle") {
            node.set_attribute("data-surface", surface)?;
            node.set_attribute("data-output", active)?;
        }
    } else {
        let id = match url {
            "/bios/files/fat32" => "fm-fat32",
            "/bios/files/ntfs" => "fm-ntfs",
            "/bios/files/ext4" => "fm-ext4",
            "/bios/settings" => "settings-info",
            "/bios/bootloader" => "bootloader-info",
            _ => return Ok(()),
        };
        if let Some(node) = dom.get_element_by_id(id) {
            node.set_inner_text(body);
        }
    }
    Ok(())
}

/// QEMU extra argv: `-smp` from BoardSpec harts, UART1 chardev for SSH+HolyC.
/// Never a guest netdev. `virtio-gpu-device` when Gr/proxy wants a high-res stand-in.
/// Default host TCP port for the BIOS command console when `dual_band.tcp`
/// is off — the UART0/`trap_uart` path (View/Ui/File/Get) needs a
/// bidirectional backend; `-serial file:` would make commands unreachable.
pub const G6B_UART_CONSOLE_PORT: u16 = 4567;

pub fn qemu_dual_band_argv(spec: &BoardSpec) -> Vec<String> {
    let mut a = vec!["-nographic".to_string()];
    a.push("-smp".into());
    a.push(spec.harts.max(1).to_string());
    // UART0 command console — always bidirectional (tcp server) so the
    // trap_uart command lane works on QEMU for every spec, not only
    // dual_band.tcp.
    let port = spec.holyc_tcp_port().unwrap_or(G6B_UART_CONSOLE_PORT);
    a.push("-serial".into());
    a.push(format!("tcp:127.0.0.1:{port},server,nowait"));
    if spec.wants_virtio_gpu() {
        // QEMU virt creates all virtio-mmio transports with force-legacy=1
        // (Version reg reads 1); the payload uses the non-legacy v2 register
        // map (QueueDesc/Avail/Used/Ready at 0x80/0x90/0xa0/0x44).
        a.push("-global".into());
        a.push("virtio-mmio.force-legacy=false".into());
        if spec.kernel.proxy.enable && spec.kernel.proxy.gl {
            // `proxy.gl` → virgl host-GL scanout: the gl device + an EGL
            // display context. Requires a host DRM render node
            // (`egl-headless`/`gtk`/`sdl` with gl=on); on a host without
            // one QEMU refuses the device (`opengl is not available`) —
            // run `qemu-args --no-gl` for the 2D fallback (the guest path
            // is identical: CREATE_2D/ATTACH/SCANOUT/TRANSFER/FLUSH).
            a.push("-display".into());
            a.push("egl-headless,gl=on".into());
            a.push("-device".into());
            a.push("virtio-gpu-gl-device".into());
        } else {
            a.push("-device".into());
            a.push("virtio-gpu-device".into());
        }
        if spec.wants_virtio_input() {
            // virtio-input keyboard on its own mmio slot → the guest probes
            // DeviceID 18, posts eventq buffers and drains EV_KEY events
            // (`Keys`/`K` over the UART console; QEMU `sendkey` on the
            // monitor feeds the device). Fail-closed: a spec without this
            // device prints `VIRTIO-INPUT-NONE`.
            a.push("-device".into());
            a.push("virtio-keyboard-device".into());
        }
    }
    a
}

/// Dual-band / SSH+HolyC REPL greeting.
pub fn repl_banner(spec: &BoardSpec) -> String {
    let port = spec.holyc_tcp_port().unwrap_or(0);
    format!(
        "{REPL_BANNER} port={port} postboot={} access={} backends={}",
        spec.postboot.enable.as_str(),
        spec.postboot.access,
        spec.postboot.backends.join(",")
    )
}

/// Post-delegate mailbox loopback greeting (host stand-in for `/dev/g6lc-bios`).
pub fn loopback_banner(spec: &BoardSpec) -> String {
    format!(
        "{LOOPBACK_BANNER} base={} irq={} chardev={} backends={}",
        spec.loopback.base,
        spec.loopback.irq,
        spec.loopback.chardev,
        spec.postboot.backends.join(",")
    )
}

/// Load generated ZealOS (KMain + Adam + PostBoot) into an interpreter.
pub fn load_program(spec: &BoardSpec) -> Result<Program, String> {
    let d = g6b_design::compile(spec);
    let src = format!(
        "{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}",
        d.kmain_zc,
        d.adam_zc,
        d.postboot_zc,
        d.loopback_zc,
        d.browser_zc,
        d.tls_zc,
        d.https_zc,
        d.svelte_zc,
        d.endpoints_zc,
        d.holyc_ui_zc
    );
    let mut p = Program::parse(&src)?;
    p.immutable = spec.postboot.immutable.clone();
    p.net_delegates = spec.net_expose.mode == g6b_spec::NetExposeMode::UntilDelegate;
    p.loopback = spec.loopback.enable;
    p.ssh_holyc = spec.postboot.backends.iter().any(|b| b == "ssh-holyc");
    p.router = Router::from_spec(spec);
    Ok(p)
}

/// Full host boot: HolyC fast init, then HTML parse + JS AOT, then UART paint.
pub fn boot(spec: &BoardSpec) -> String {
    let d = g6b_design::compile(spec);
    let holyc_src = format!(
        "{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}",
        d.kmain_zc,
        d.adam_zc,
        d.postboot_zc,
        d.loopback_zc,
        d.browser_zc,
        d.tls_zc,
        d.https_zc,
        d.svelte_zc,
        d.endpoints_zc,
        d.holyc_ui_zc
    );
    let mut prog = match Program::parse(&holyc_src) {
        Ok(mut p) => {
            p.immutable = spec.postboot.immutable.clone();
            p.net_delegates = spec.net_expose.mode == g6b_spec::NetExposeMode::UntilDelegate;
            p.loopback = spec.loopback.enable;
            p.ssh_holyc = spec.postboot.backends.iter().any(|b| b == "ssh-holyc");
            p.router = Router::from_spec(spec);
            p
        }
        Err(e) => {
            let _ = e;
            Program::default()
        }
    };
    let holyc_out = prog
        .start()
        .or_else(|_| eval_src(&holyc_src))
        .unwrap_or_else(|e| format!("HOLYC-ERR {e}\n"));

    let session = BrowserSession::from_program(spec, prog);
    let (dom, diagnostics, wasm_executed) = match session {
        Ok(session) => (session.dom, session.diagnostics, session.wasm_executed),
        Err(error) => (
            parse(&setup_html(spec)),
            vec![format!("BROWSER-ERROR {error}")],
            false,
        ),
    };

    let mut lines = Vec::new();
    let holyc = holyc_out.trim_end();
    if holyc.is_empty() {
        lines.push(BANNER.to_string());
    } else {
        lines.push(holyc.to_string());
    }
    lines.push(format!(
        "xlen={} march={} product={}",
        spec.isa.xlen, spec.isa.march, spec.product
    ));
    lines.extend(to_uart_lines(&dom, 80));
    if spec.kernel.gr.enable {
        let mut frame = g6b_gr::Frame::from_spec(spec);
        frame.paint_lines(&to_uart_lines(&dom, frame.cols as usize));
        lines.push(frame.init_line());
    }
    if spec.entry.timeout_ms > 0 {
        lines.push(format!(
            "entry {} timeout {} ms",
            spec.entry.hotkey, spec.entry.timeout_ms
        ));
    }
    if let Some(port) = spec.holyc_tcp_port() {
        let uart = if spec.holyc.dual_band.uart {
            "uart+"
        } else {
            ""
        };
        lines.push(format!("dual-band {uart}tcp:{port}"));
    }
    if spec.postboot.enable != g6b_spec::PostbootMode::Never {
        lines.push(format!(
            "postboot {} access={} backends={} immutable={}",
            spec.postboot.enable.as_str(),
            spec.postboot.access,
            spec.postboot.backends.join(","),
            spec.postboot.immutable.join(",")
        ));
    }
    if spec.net_expose.mode != g6b_spec::NetExposeMode::Never {
        lines.push(format!(
            "net-expose {} via={} web={} ssh-holyc={}",
            spec.net_expose.mode.as_str(),
            spec.net_expose.via,
            spec.net_expose.web,
            spec.net_expose.ssh_holyc
        ));
    }
    if spec.loopback.enable {
        lines.push(format!(
            "loopback mbox {} irq {} {}",
            spec.loopback.base, spec.loopback.irq, spec.loopback.chardev
        ));
    }
    lines.push(if spec.rvv_live() {
        "ISEL-RVV".into()
    } else {
        "ISEL-SCALAR".into()
    });
    lines.push("TIMER-READY SBI-TIME".into());
    if spec.kernel.proxy.enable {
        let p = g6b_gr::proxy::Proxy::from_spec(spec);
        lines.push(p.init_line());
        if p.gl {
            lines.push("GL-ADAPTER opengl-es2".into());
        }
    }
    if spec.kernel.tls.enable {
        lines.push("TLS-READY".into());
    }
    if spec.kernel.tls.https {
        lines.push("HTTPS-READY".into());
    }
    if spec.kernel.tls.rsa {
        lines.push("TLS-RSA PKCS1-SHA256".into());
    }
    if spec.kernel.tls.ecdsa {
        lines.push("TLS-ECDSA P256-SHA256".into());
    }
    if spec.kernel.tls.certificates {
        lines.push("TLS-CERT X509".into());
    }
    if spec.net_expose.mode != g6b_spec::NetExposeMode::Never {
        lines.push(format!(
            "adapter-ports bios-https={} ssh-holyc={}",
            spec.net_expose.bios_https_port, spec.net_expose.ssh_holyc_port
        ));
    }
    if spec.kernel.profile != g6b_spec::BiosProfile::Custom {
        lines.push(format!("PROFILE-{}", spec.kernel.profile.as_str()));
    }
    if spec.kernel.http.enable {
        lines.push("HTTP-READY".into());
        if spec.kernel.http.http1 {
            lines.push("HTTP/1.1".into());
        }
        if spec.kernel.http.http2 {
            lines.push("HTTP/2".into());
        }
        if spec.kernel.http.serve {
            lines.push(if spec.kernel.tls.https {
                "HTTPS-SERVE".into()
            } else {
                "HTTP-SERVE".into()
            });
        }
        if spec.kernel.http.files.enable {
            lines.push("FILES-SERVE".into());
            if spec.kernel.http.files.html {
                lines.push("FILES-HTML".into());
            }
            if spec.kernel.http.files.js {
                lines.push("FILES-JS".into());
            }
            if spec.kernel.http.files.wasm {
                lines.push("FILES-WASM".into());
            }
            if spec.kernel.http.files.https {
                lines.push("HTTPS-FILES".into());
            }
        }
    }
    if spec.kernel.flash.enable {
        lines.push(format!(
            "FLASH-READY image={} backend={}",
            spec.kernel.flash.image, spec.kernel.flash.backend
        ));
    }
    if spec.kernel.settings.enable {
        lines.push("SETTINGS-READY".into());
    }
    if spec.kernel.usb.enable {
        lines.push("USB-FAT32".into());
        if spec.kernel.usb.key {
            lines.push("USB-FILES fat32/ntfs/ext4".into());
        }
    }
    lines.push(format!(
        "CPU-{} cores={} threads={} issue={}",
        spec.topology_kind().to_ascii_uppercase(),
        spec.cores,
        spec.threads,
        spec.geo.issue_ports
    ));
    if spec.hypervisor_live() {
        lines.push("CPU-H".into());
    }
    if spec.uncore.clint {
        lines.push("UNCORE-CLINT".into());
    }
    if spec.uncore.plic {
        lines.push("UNCORE-PLIC".into());
    }
    if spec.uncore.ddr {
        lines.push("UNCORE-DDR".into());
    }
    if spec.uncore.pcie {
        lines.push("UNCORE-PCIE".into());
    }
    lines.push("HOLYC-UI".into());
    for m in g6b_ui::menu_markers() {
        lines.push(m);
    }
    if spec.kernel.ui == "svelte-d" {
        for m in g6b_wasm::svelte_live_markers() {
            if m.contains("FileMgr") && !spec.kernel.usb.key {
                continue;
            }
            lines.push(m);
        }
    }
    if wasm_executed {
        lines.push(g6b_wasm::MARKER.into());
        if spec.kernel.wasm.jit {
            lines.push("WASM-JIT-RV numeric-leaves; UI host interpreter".into());
        }
    }
    lines.extend(diagnostics);
    lines.join("\n")
}

/// High-res display-proxy PPM (ZealOS plane scaled + DOM status strip).
pub fn proxy_ppm(spec: &BoardSpec) -> Vec<u8> {
    let mut frame = g6b_gr::Frame::from_spec(spec);
    let dom = rendered_dom(spec);
    frame.paint_lines(&to_uart_lines(&dom, frame.cols as usize));
    let p = g6b_gr::proxy::Proxy::from_spec(spec);
    let mut dom = dom;
    let status = dom
        .get_element_by_id("status")
        .map(|n| n.inner_text())
        .unwrap_or_default();
    p.to_ppm(&frame, &format!("DOM status={status}"))
}

/// OpenGL-ES2 adapter listing for the display-proxy.
pub fn gl_listing(spec: &BoardSpec) -> String {
    let p = g6b_gr::proxy::Proxy::from_spec(spec);
    g6b_gr::gl::listing(&p)
}

/// Host-side stand-in for `_start`.
pub fn host_start(spec: &BoardSpec) -> String {
    boot(spec)
}

/// UART-only display helper (HTML without HolyC). Prefer [`boot`].
pub fn uart_display(spec: &BoardSpec, html: &str) -> String {
    let dom = parse(html);
    let mut lines = vec![BANNER.to_string()];
    lines.push(format!(
        "xlen={} march={} product={}",
        spec.isa.xlen, spec.isa.march, spec.product
    ));
    lines.extend(to_uart_lines(&dom, 80));
    lines.join("\n")
}

/// Drive one HolyC REPL line (dual-band / bios-regress).
pub fn repl_line(prog: &mut Program, line: &str) -> Result<ReplResult, String> {
    prog.repl(line)
}

/// Host PPM of the setup page (SysGrInit rewrite).
pub fn gr_ppm(spec: &BoardSpec) -> Vec<u8> {
    let mut frame = g6b_gr::Frame::from_spec(spec);
    let dom = rendered_dom(spec);
    frame.paint_lines(&to_uart_lines(&dom, frame.cols as usize));
    frame.to_ppm()
}

/// CSS-raster PPM of the setup page. Parses the stylesheet embedded in
/// `g6b_ui::setup_html` and renders the body with colour, background and text.
/// This is the track-B "real UI" output from architecture/RENDER-VALIDATION.md.
pub fn ui_ppm(spec: &BoardSpec) -> Result<Vec<u8>, String> {
    let html = g6b_ui::setup_html(spec);
    let css = extract_style(&html);
    let w = spec.kernel.gr.w.max(320);
    let h = spec.kernel.gr.h.max(200);
    let out = g6b_css::render::render_ui_to_output(&html, &css, w, h)?;
    Ok(out.canvas.to_ppm())
}

/// CSS-raster output of the setup page including the hit boxes for event
/// dispatch.
pub fn ui_ppm_output(spec: &BoardSpec) -> Result<g6b_css::render::RenderOutput, String> {
    let html = g6b_ui::setup_html(spec);
    let css = extract_style(&html);
    let w = spec.kernel.gr.w.max(320);
    let h = spec.kernel.gr.h.max(200);
    g6b_css::render::render_ui_to_output(&html, &css, w, h)
}

fn extract_style(html: &str) -> String {
    if let (Some(start), Some(end)) = (html.find("<style>"), html.find("</style>")) {
        if end > start {
            return html[start + "<style>".len()..end].to_string();
        }
    }
    String::new()
}

/// PPM of an *executed* `__gr_plane` (`exec::Smoke::gr_frame` — GR16 + 4bpp
/// as the payload left it, including `DomPaint` glyphs). `None` when the run
/// had no live Gr plane or the header is invalid.
pub fn frame_ppm(plane: &[u8]) -> Option<Vec<u8>> {
    g6b_gr::plane_to_ppm(plane)
}

/// PPM of the device-side virtio-gpu scanout surface (`exec::Smoke::vio_fb`
/// as `TRANSFER_TO_HOST_2D` left it — B8G8R8X8 LE). `None` when the run had
/// no virtio-gpu device. Host-modelled scanout, not a QEMU capture.
pub fn scanout_ppm(w: u32, h: u32, fb: &[u8]) -> Option<Vec<u8>> {
    g6b_gr::x8r8_to_ppm(w, h, fb)
}

fn rendered_dom(spec: &BoardSpec) -> Node {
    match BrowserSession::new(spec) {
        Ok(session) => session.dom,
        Err(error) => {
            let mut dom = parse(&setup_html(spec));
            if let Some(status) = dom.get_element_by_id("status") {
                status.set_inner_text(&format!("BROWSER-ERROR {error}"));
            }
            dom
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn desktop() -> BoardSpec {
        BoardSpec::from_json_str(
            r#"{
            "schema_version":1,
            "product":"desktop",
            "isa":{"xlen":64,"march":"rv64imac"},
            "harts":{"count":2},
            "holyc":{"fast_init":true,"dual_band":{"uart":true,"tcp":{"enable":true,"host_port":2222}}},
            "postboot":{"enable":"runtime","access":"kvm","always_on_domain":true}
        }"#,
        )
        .unwrap()
    }

    #[test]
    fn banner_is_g6lc_bios() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"product":"desktop","isa":{"xlen":64,"march":"rv64imac"}}"#,
        )
        .unwrap();
        let out = host_start(&spec);
        assert!(out.contains(BANNER), "{out}");
        assert!(out.contains("xlen=64"));
        assert!(out.contains("DEL") || out.contains("timeout"), "{out}");
    }

    #[test]
    fn holyc_then_dom_js_boot() {
        let spec = desktop();
        let out = boot(&spec);
        assert!(out.contains(HOLYC_READY), "{out}");
        assert!(out.contains(UI_BOOT), "{out}");
        assert!(out.contains("dual-band uart+tcp:2222"), "{out}");
        assert!(out.contains("postboot runtime"), "{out}");
        assert!(out.contains("ssh-holyc"), "{out}");
        assert!(out.contains("loopback mbox"), "{out}");
        assert!(out.contains("until-delegate"), "{out}");
        assert!(out.contains("Read-only"), "{out}");
    }

    #[test]
    fn qemu_argv_has_ssh_like_serial() {
        let spec = desktop();
        let argv = qemu_dual_band_argv(&spec).join(" ");
        assert!(argv.contains("-nographic"), "{argv}");
        assert!(argv.contains("-smp"), "{argv}");
        assert!(argv.contains("tcp:127.0.0.1:2222,server,nowait"), "{argv}");
        assert!(
            !argv.contains("-netdev"),
            "BIOS path must not steal a NIC: {argv}"
        );
        assert!(!argv.contains("virtio-net"), "{argv}");
    }

    #[test]
    fn qemu_argv_serial_is_bidirectional_without_dual_band() {
        // The UART0/trap_uart console must accept commands (View/Ui/File/Get)
        // on QEMU for every spec — an output-only backend would strand them.
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let argv = qemu_dual_band_argv(&spec).join(" ");
        assert!(
            argv.contains(&format!(
                "-serial tcp:127.0.0.1:{},server,nowait",
                G6B_UART_CONSOLE_PORT
            )),
            "{argv}"
        );
    }

    #[test]
    fn gr_init_when_enabled() {
        let spec = BoardSpec::from_json_str(
            r#"{
            "schema_version":1,"product":"desktop","isa":{"xlen":64,"march":"rv64imac"},
            "kernel":{"gr":{"enable":true,"w":640,"h":480,"colors":16,"backend":"virtio-gpu"}}
        }"#,
        )
        .unwrap();
        let out = boot(&spec);
        assert!(out.contains("GR-INIT 640x480x16"), "{out}");
        let argv = qemu_dual_band_argv(&spec).join(" ");
        assert!(argv.contains("virtio-gpu-device"), "{argv}");
        assert!(!argv.contains("virtio-net"), "{argv}");
    }

    #[test]
    fn usb_fat32_always_key_filemgr_on_full() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1}"#).unwrap();
        let out = boot(&spec);
        assert!(out.contains("USB-FAT32"), "{out}");
        assert!(!out.contains("USB-FILES"), "{out}");
        let full = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let o = boot(&full);
        assert!(o.contains("USB-FAT32"), "{o}");
        assert!(o.contains("USB-FILES fat32/ntfs/ext4"), "{o}");
        assert!(o.contains("SVELTE-LIVE FileMgr"), "{o}");
        assert!(
            setup_html(&full).contains("id=\"filemgr\""),
            "{}",
            setup_html(&full)
        );
        assert!(
            !setup_html(&spec).contains("id=\"filemgr\""),
            "{}",
            setup_html(&spec)
        );
    }

    #[test]
    fn smt2_boot_exposes_cpu_and_uncore_menus() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"full","isa":{"xlen":64},"harts":{"count":2},"core":{"issue_ports":2}}"#,
        )
        .unwrap();
        let out = boot(&spec);
        assert!(out.contains("CPU-SMT"), "{out}");
        assert!(out.contains("UNCORE-PLIC"), "{out}");
        assert!(out.contains("HOLYC-UI"), "{out}");
        assert!(setup_html(&spec).contains("id=\"bios-menu\""));
        assert!(out.contains("MENU-cpu"), "{out}");
        assert!(out.contains("MENU-settings"), "{out}");
        assert!(out.contains("MENU-uncore"), "{out}");
        assert!(
            out.contains("HOLYC-EVAL") || out.contains("JS-FETCH /bios/menu"),
            "{out}"
        );
        assert!(out.contains("FILES-HTML"), "{out}");
        assert!(out.contains("FILES-WASM"), "{out}");
        assert!(out.contains("HTTPS-FILES"), "{out}");
    }

    #[test]
    fn browser_and_holyc_share_every_menu_row() {
        for profile in ["embedded", "router", "appliance", "desktop", "full"] {
            let spec = BoardSpec::from_json_str(&format!(
                r#"{{"schema_version":1,"profile":"{profile}"}}"#
            ))
            .unwrap();
            let mut session = BrowserSession::new(&spec).unwrap();
            for menu in spec.menus() {
                session.select_menu(menu.id).unwrap();
                let ReplResult::Output(output) = session
                    .program
                    .repl(&format!("Menu(\"{}\");", menu.id))
                    .unwrap()
                else {
                    panic!("menu must print")
                };
                assert!(
                    output.contains(&menu.json()),
                    "{profile} {}: {output}",
                    menu.id
                );
                for item in menu.items {
                    let node = session
                        .dom
                        .get_element_by_id(&format!("row-{}-{}", menu.id, item.id))
                        .unwrap();
                    assert_eq!(node.inner_text(), item.value, "{profile} {}", item.id);
                }
            }
            assert_eq!(session.wasm_executed, spec.kernel.wasm.enable);
        }
    }

    #[test]
    fn browser_switches_menu_without_destroying_rows() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"kernel":{"browser":{"start_menu":"cpu","js":"off"}}}"#,
        )
        .unwrap();
        let mut session = BrowserSession::new(&spec).unwrap();
        assert!(!session.dom.get_element_by_id("menu-cpu").unwrap().hidden);
        assert!(session.dom.get_element_by_id("menu-main").unwrap().hidden);
        assert!(session.execute_script("console.log('disabled')").is_err());
        session.select_menu("settings").unwrap();
        assert_eq!(
            session
                .dom
                .get_element_by_id("row-cpu-cores")
                .unwrap()
                .inner_text(),
            "1"
        );
        session.select_menu("cpu").unwrap();
        assert!(!session.dom.get_element_by_id("menu-cpu").unwrap().hidden);
        assert!(session.select_menu("missing").is_err());
    }

    #[test]
    fn holyc_handler_runs_outside_the_browser_session_and_keeps_ui_available() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"harts":{"cores":2,"threads":1},"kernel":{"tasking":{"enable":true}}}"#).unwrap();
        let program = Program::parse("U0 Compute(U64 value) { Print(value); }").unwrap();
        let mut session = BrowserSession::from_program(&spec, program).unwrap();
        let created = session
            .holyc_request("ThreadCreate(\"Compute\", 42);")
            .unwrap();
        assert!(matches!(created, ReplResult::Output(value) if value.contains("hart=1 queued")));
        let work = session
            .task_services
            .as_mut()
            .unwrap()
            .dispatch(1)
            .unwrap()
            .unwrap();
        let id = work.task();
        session.handle_key("End").unwrap();
        assert!(
            !session
                .dom
                .get_element_by_id("menu-settings")
                .unwrap()
                .hidden
        );
        let response = std::thread::spawn(move || work.run()).join().unwrap();
        let services = session.task_services.as_mut().unwrap();
        services.accept(response).unwrap();
        assert_eq!(services.take_result(id).unwrap().unwrap().unwrap(), b"42");
        assert!(BrowserSession::new(&BoardSpec::default())
            .unwrap()
            .holyc_request("ThreadCreate(\"Compute\", 42);")
            .is_err());
    }

    #[test]
    fn async_kernel_reads_yield_before_resuming_and_navigation_cancels() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let mut session = BrowserSession::new(&spec).unwrap();
        let task = session.enqueue_async_script(r#"document.getElementById("status").textContent="pending"; try { await fetch("/bios/menu/cpu"); document.getElementById("status").textContent="done"; } catch (e) { document.getElementById("status").textContent="failed"; }"#).unwrap();
        let tick = session.poll_async();
        assert!(tick.steps <= 64);
        assert!(tick
            .events
            .iter()
            .any(|event| matches!(event, g6b_js::AsyncEvent::Request { .. })));
        assert_eq!(
            session
                .dom
                .get_element_by_id("status")
                .unwrap()
                .inner_text(),
            "pending"
        );
        assert!(session
            .lines(80)
            .iter()
            .any(|line| line.contains("pending")));
        let tick = session.poll_async();
        assert!(tick
            .events
            .iter()
            .any(|event| matches!(event, g6b_js::AsyncEvent::Finished { result: Ok(()), .. })));
        assert_eq!(
            session
                .dom
                .get_element_by_id("status")
                .unwrap()
                .inner_text(),
            "done"
        );
        assert!(!session.cancel_async_script(task));
        session.enqueue_async_script(r#"await fetch("/bios/menu/cpu"); document.getElementById("status").textContent="stale";"#).unwrap();
        session.poll_async();
        session.handle_key("End").unwrap();
        assert_eq!(session.poll_async().steps, 0);
        assert_eq!(
            session
                .dom
                .get_element_by_id("status")
                .unwrap()
                .inner_text(),
            "done"
        );
    }

    #[test]
    fn async_kernel_disabled_reads_reject_and_catch_without_mutation_routes() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"full","kernel":{"http":{"proxy_js":false}}}"#,
        )
        .unwrap();
        let mut session = BrowserSession::new(&spec).unwrap();
        session.enqueue_async_script(r#"try { await fetch("/bios/menu/cpu"); } catch (e) { document.getElementById("status").textContent="caught"; console.log(e); }"#).unwrap();
        session.poll_async();
        let tick = session.poll_async();
        assert_eq!(
            session
                .dom
                .get_element_by_id("status")
                .unwrap()
                .inner_text(),
            "caught"
        );
        assert!(tick.events.iter().any(|event| matches!(event, g6b_js::AsyncEvent::Log { value, .. } if value.contains("unavailable"))));
        let spec =
            BoardSpec::from_json_str(r#"{"schema_version":1,"kernel":{"browser":{"js":"off"}}}"#)
                .unwrap();
        assert!(BrowserSession::new(&spec)
            .unwrap()
            .enqueue_async_script("throw 'disabled';")
            .is_err());
    }

    #[test]
    fn browser_keyboard_navigation_and_refresh_use_the_same_spec() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"full","kernel":{"browser":{"start_menu":"cpu"}}}"#,
        )
        .unwrap();
        let mut session = BrowserSession::new(&spec).unwrap();
        for (key, expected) in [
            ("ArrowLeft", "main"),
            ("ArrowLeft", "settings"),
            ("ArrowRight", "main"),
            ("End", "settings"),
            ("Home", "main"),
        ] {
            assert!(session.handle_key(key).unwrap());
            assert_eq!(session.selected_menu, expected);
            for face in g6b_ui::MENUS {
                assert_eq!(
                    session
                        .dom
                        .get_element_by_id(&format!("menu-{}", face.id))
                        .unwrap()
                        .hidden,
                    face.id != expected
                );
            }
        }
        session
            .dom
            .get_element_by_id("row-cpu-cores")
            .unwrap()
            .set_inner_text("stale");
        assert!(session.handle_key("F10").unwrap());
        assert_eq!(
            session
                .dom
                .get_element_by_id("row-cpu-cores")
                .unwrap()
                .inner_text(),
            spec.cores.to_string()
        );
        assert!(!session.handle_key("Delete").unwrap());
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full","kernel":{"http":{"proxy_js":false},"browser":{"js":"off"}}}"#).unwrap();
        let mut session = BrowserSession::new(&spec).unwrap();
        let diagnostics = session.diagnostics.clone();
        assert!(session.handle_key("F10").unwrap());
        assert!(session.handle_key("End").unwrap());
        assert_eq!(session.diagnostics, diagnostics);
    }

    #[test]
    fn browser_preserves_fetch_method_and_reports_errors() {
        let spec =
            BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"appliance"}"#).unwrap();
        let mut session = BrowserSession::new(&spec).unwrap();
        session.execute_script(r#"kernel.register("/bios/custom/post", "POST"); fetch("/bios/custom/post", {method:"POST"});"#).unwrap();
        assert!(session
            .diagnostics
            .iter()
            .any(|s| s == "JS-FETCH /bios/custom/post 200"));
        assert!(session
            .execute_script(r#"fetch("/bios/custom/post")"#)
            .is_err());
        assert!(session
            .execute_script(r#"kernel.register("/bios/menu/cpu")"#)
            .is_err());
        assert!(session
            .execute_script(r#"document.getElementById("missing").innerText="x";"#)
            .is_err());
        assert!(session
            .execute_script("console.log('unterminated)")
            .is_err());
    }

    #[test]
    fn wasm_cannot_bypass_disabled_fetch_proxy() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full","kernel":{"http":{"proxy_js":false},"browser":{"js":"off"}}}"#).unwrap();
        let session = BrowserSession::new(&spec).unwrap();
        assert!(session.wasm_executed);
        assert!(!session
            .diagnostics
            .iter()
            .any(|s| s.starts_with("WASM-FETCH")));
    }

    #[test]
    fn browser_session_runs_aot_event_listener() {
        let spec = desktop();
        let mut session = BrowserSession::new(&spec).unwrap();
        let path = path_to_id(&session.dom, "status").expect("status id");
        let listener = Listener::Aot(vec![g6b_js::Op::SetInnerText {
            id: "status".into(),
            value: "AOT-EVENT-OK".into(),
        }]);
        session
            .add_event_listener(&path, "click", false, listener)
            .unwrap();
        let allowed = session.dispatch_key(&path, "Enter", "click").unwrap();
        assert!(allowed);
        assert_eq!(
            session
                .dom
                .get_element_by_id("status")
                .unwrap()
                .inner_text(),
            "AOT-EVENT-OK"
        );
    }

    #[test]
    fn browser_session_pointer_dispatch_uses_css_hit_box() {
        let spec = desktop();
        let mut session = BrowserSession::new(&spec).unwrap();
        session.render_hit_boxes().unwrap();
        eprintln!(
            "hit boxes: {:?}",
            session
                .hit_boxes
                .iter()
                .map(|h| (&h.id, &h.name, h.path.clone()))
                .collect::<Vec<_>>()
        );
        let hit = session
            .hit_boxes
            .iter()
            .find(|h| h.id.as_deref() == Some("status"))
            .expect("status hit box")
            .clone();
        let listener = Listener::Aot(vec![g6b_js::Op::SetInnerText {
            id: "status".into(),
            value: "POINTER-HIT-OK".into(),
        }]);
        session
            .add_event_listener(&hit.path, "click", false, listener)
            .unwrap();
        let x = hit.x + hit.w / 2;
        let y = hit.y + hit.h / 2;
        let allowed = session.dispatch_pointer(x, y, "click", "detail").unwrap();
        assert!(allowed);
        assert_eq!(
            session
                .dom
                .get_element_by_id("status")
                .unwrap()
                .inner_text(),
            "POINTER-HIT-OK"
        );
    }

    #[test]
    fn browser_session_pointer_dispatch_propagates_capture_then_bubble() {
        let spec = desktop();
        let mut session = BrowserSession::new(&spec).unwrap();
        session.render_hit_boxes().unwrap();
        let hit = session
            .hit_boxes
            .iter()
            .find(|h| h.id.as_deref() == Some("status"))
            .expect("status hit box")
            .clone();
        let main = session
            .hit_boxes
            .iter()
            .find(|h| h.id.as_deref() == Some("bios-ui"))
            .expect("main hit box")
            .clone();

        // Capture on main, then target, then bubble on main. The final text
        // on the two different elements proves the three phases fired in order.
        session
            .add_event_listener(
                &main.path,
                "click",
                true,
                Listener::Aot(vec![g6b_js::Op::SetInnerText {
                    id: "status".into(),
                    value: "CAPTURE".into(),
                }]),
            )
            .unwrap();
        session
            .add_event_listener(
                &hit.path,
                "click",
                false,
                Listener::Aot(vec![g6b_js::Op::SetInnerText {
                    id: "status".into(),
                    value: "TARGET".into(),
                }]),
            )
            .unwrap();
        session
            .add_event_listener(
                &main.path,
                "click",
                false,
                Listener::Aot(vec![g6b_js::Op::SetInnerText {
                    id: "profile".into(),
                    value: "BUBBLE".into(),
                }]),
            )
            .unwrap();

        let x = hit.x + hit.w / 2;
        let y = hit.y + hit.h / 2;
        let allowed = session.dispatch_pointer(x, y, "click", "detail").unwrap();
        assert!(allowed);
        assert_eq!(
            session
                .dom
                .get_element_by_id("status")
                .unwrap()
                .inner_text(),
            "TARGET"
        );
        assert_eq!(
            session
                .dom
                .get_element_by_id("profile")
                .unwrap()
                .inner_text(),
            "BUBBLE"
        );
    }

    fn gpu_spec() -> BoardSpec {
        BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"full","isa":{"xlen":64,"march":"rv64imac"},
            "kernel":{"gr":{"enable":true,"w":640,"h":480,"backend":"virtio-gpu"},
                      "proxy":{"enable":true,"link":"virtio-gpu","dpi":192,
                               "high_w":1920,"high_h":1080}}}"#,
        )
        .unwrap()
    }

    #[test]
    fn holyc_and_browser_lanes_share_the_display_route() {
        let spec = gpu_spec();
        let src = g6b_ui::holyc_print_src(&spec);
        // HolyC prints the ladder and reads the same endpoint the browser uses.
        assert!(src.contains("DISP vio0 virtio-gpu 1920x1080"), "{src}");
        assert!(src.contains("vio0=virtio-gpu pri=1"), "{src}");
        assert!(src.contains("vga0=none pri=0"), "{src}");
        assert!(src.contains("surface=gpu"), "{src}");
        assert!(src.contains("KernelGet(\"/bios/display\")"), "{src}");
        assert!(src.contains("DisplaySurface(\"vga\")"), "{src}");

        // And the builtin actually flips through the router, fail-closed.
        let mut prog = load_program(&spec).unwrap();
        prog.router = g6b_http::Router::from_spec(&spec);
        match prog.repl(r#"DisplaySurface("vga");"#).unwrap() {
            ReplResult::Output(s) => assert!(s.contains("DISP-SURFACE vga"), "{s}"),
            other => panic!("{other:?}"),
        }
        assert!(prog.repl(r#"DisplaySurface("opengl");"#).is_err());

        // A board with no accelerated output has no POST route, so the same
        // call reports a refusal instead of claiming success.
        let plain = BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"full","isa":{"xlen":64,"march":"rv64imac"},
            "kernel":{"gr":{"enable":true,"backend":"uart"}}}"#,
        )
        .unwrap();
        assert!(!g6b_ui::holyc_print_src(&plain).contains("DisplaySurface("));
        let mut prog = load_program(&plain).unwrap();
        prog.router = g6b_http::Router::from_spec(&plain);
        match prog.repl(r#"DisplaySurface("gpu");"#).unwrap() {
            ReplResult::Output(s) => assert!(s.contains("DISP-SURFACE-REFUSED"), "{s}"),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn gpu_output_starts_on_the_gpu_surface_and_offers_the_toggle() {
        let spec = gpu_spec();
        assert!(spec.surface_toggle());
        let mut session = BrowserSession::new(&spec).unwrap();
        assert_eq!(session.surface, g6b_spec::Surface::Gpu);
        // The control exists and names the surface a click switches *to*.
        let toggle = session
            .dom
            .get_element_by_id("disp-toggle")
            .expect("toggle button");
        assert_eq!(toggle.get_attribute("data-surface"), Some("gpu"));
        assert_eq!(toggle.inner_text(), "VGA view");
        // And the proxy the host PPM path uses agrees with the session.
        assert_eq!(session.proxy().surface, g6b_spec::Surface::Gpu);
    }

    #[test]
    fn toggling_the_surface_updates_dom_router_and_proxy_together() {
        let spec = gpu_spec();
        let mut session = BrowserSession::new(&spec).unwrap();
        let now = session.toggle_surface().unwrap();
        assert_eq!(now, g6b_spec::Surface::Vga);
        assert_eq!(session.surface, g6b_spec::Surface::Vga);
        assert_eq!(session.proxy().surface, g6b_spec::Surface::Vga);
        assert_eq!(
            session
                .dom
                .get_element_by_id("disp-toggle")
                .unwrap()
                .get_attribute("data-surface"),
            Some("vga")
        );
        assert!(session
            .dom
            .get_element_by_id("disp-status")
            .unwrap()
            .inner_text()
            .contains("vga"));
        assert!(session.diagnostics.iter().any(|d| d == "DISP-SURFACE vga"));
        // Flipping back is symmetric.
        assert_eq!(session.toggle_surface().unwrap(), g6b_spec::Surface::Gpu);
    }

    #[test]
    fn a_board_without_an_accelerated_output_has_no_toggle_at_all() {
        // Gr plane over UART only: no virtio-gpu, no proxy, no display engine.
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"full","isa":{"xlen":64,"march":"rv64imac"},
            "kernel":{"gr":{"enable":true,"w":640,"h":480,"backend":"uart"}}}"#,
        )
        .unwrap();
        assert!(!spec.surface_toggle());
        let mut session = BrowserSession::new(&spec).unwrap();
        assert_eq!(session.surface, g6b_spec::Surface::Vga);
        assert!(session.dom.get_element_by_id("disp-toggle").is_none());
        // Refused, not silently ignored.
        assert!(session.toggle_surface().is_err());
        // And the POST route was never registered.
        assert_ne!(
            session.program.router.fetch("POST", "/bios/display").status,
            200
        );
    }

    #[test]
    fn clicking_the_toggle_hit_box_dispatches_a_surface_event() {
        let spec = gpu_spec();
        let mut session = BrowserSession::new(&spec).unwrap();
        session.render_hit_boxes().unwrap();
        // The absolutely positioned button must have its own hit box, anchored
        // to the top-right of the canvas rather than shoved into the flow.
        let hit = session
            .hit_boxes
            .iter()
            .find(|h| h.id.as_deref() == Some("disp-toggle"))
            .expect("toggle hit box")
            .clone();
        let banner = session
            .hit_boxes
            .iter()
            .find(|h| h.id.as_deref() == Some("banner"))
            .expect("banner hit box");
        assert!(
            hit.x > banner.x + banner.w / 2,
            "toggle sits right of centre: toggle.x={} banner={}..{}",
            hit.x,
            banner.x,
            banner.x + banner.w
        );
        assert_eq!(hit.y, 0, "and at the top");

        // A pointer click on it runs an AOT listener, proving the CSS hit box,
        // the event path and the surface state are one chain.
        let listener = Listener::Aot(vec![g6b_js::Op::SetInnerText {
            id: "status".into(),
            value: "DISP-CLICK".into(),
        }]);
        session
            .add_event_listener(&hit.path, "click", false, listener)
            .unwrap();
        let allowed = session
            .dispatch_pointer(hit.x + hit.w / 2, hit.y + hit.h / 2, "click", "surface")
            .unwrap();
        assert!(allowed);
        assert_eq!(
            session
                .dom
                .get_element_by_id("status")
                .unwrap()
                .inner_text(),
            "DISP-CLICK"
        );
    }

    #[test]
    fn browser_preserves_filesystem_gates_and_surfaces_host_errors() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full","kernel":{"usb":{"fs_ntfs":false,"fs_ext4":false}}}"#).unwrap();
        let mut session = BrowserSession::new(&spec).unwrap();
        assert_eq!(
            session
                .dom
                .get_element_by_id("fm-tabs")
                .unwrap()
                .inner_text(),
            "fat32"
        );
        assert!(session.dom.get_element_by_id("fm-ntfs").is_none());
        let mut host = KernelHost {
            dom: &mut session.dom,
            router: &session.program.router,
            spec: &spec,
            diagnostics: Vec::new(),
            handles: Vec::new(),
            pending_slot: None,
            objects: ObjectTable::new(),
            pending_event_listeners: Vec::new(),
            pending_event_removals: Vec::new(),
            last_await_failed: false,
            last_await_error: String::new(),
            last_await_value: String::new(),
        };
        assert!(host.set_inner_text("not-a-target", "oops").is_err());
        assert!(host.set_visible("not-a-target", false).is_err());
        assert!(host.fetch("/bios/menu/cpu?view=1").is_ok());
        assert!(host.diagnostics.iter().any(|line| line.ends_with(" 200")));
    }

    #[test]
    fn unicode_and_quoted_menu_values_match_holyc_without_source_injection() {
        let mut spec = desktop();
        spec.product = "Board \"α\" https://local\\test\n\"); Reboot(); Print(\"".into();
        let mut program = load_program(&spec).unwrap();
        let output = program.call("MenuMainPrint").unwrap();
        assert!(
            output.contains(&format!("  product={}\n", spec.product)),
            "{output}"
        );
        assert_eq!(program.last_power, None);
        let mut session = BrowserSession::new(&spec).unwrap();
        assert_eq!(
            session
                .dom
                .get_element_by_id("row-main-product")
                .unwrap()
                .inner_text(),
            spec.product
        );
    }

    #[test]
    fn invalid_menu_response_cannot_partially_repaint() {
        let spec = desktop();
        let mut session = BrowserSession::new(&spec).unwrap();
        let original = session
            .dom
            .get_element_by_id("main-title")
            .unwrap()
            .inner_text();
        let body = r#"{"id":"main","title":"WRONG","items":[{"id":"product","value":"changed","label":"Product","writable":false}]}"#;
        assert!(paint_response(&mut session.dom, "/bios/menu/main", body).is_err());
        assert_eq!(
            session
                .dom
                .get_element_by_id("main-title")
                .unwrap()
                .inner_text(),
            original
        );
    }

    #[test]
    fn setup_contains_shared_menu_values() {
        let spec = desktop();
        let html = setup_html(&spec);
        for menu in spec.menus() {
            assert!(
                html.contains(&format!("id=\"{}-title\"", menu.id)),
                "{}",
                menu.id
            );
            for item in menu.items {
                assert!(html.contains(&item.value), "{}: {}", menu.id, item.value);
            }
        }
    }

    #[test]
    fn framebuffer_uses_executed_dom() {
        let spec = desktop();
        let mut frame = g6b_gr::Frame::from_spec(&spec);
        let session = BrowserSession::new(&spec).unwrap();
        frame.paint_lines(&session.lines(frame.cols as usize));
        assert!(
            gr_ppm(&spec) == frame.to_ppm(),
            "preview must paint the executed DOM"
        );
    }

    #[test]
    fn postboot_repl_view_but_not_write() {
        let spec = desktop();
        let mut p = load_program(&spec).unwrap();
        let hand = p.call("LinuxHandoff").unwrap();
        assert!(hand.contains("POSTBOOT-LIVE"), "{hand}");
        assert!(hand.contains("NET-DELEGATE"), "{hand}");
        assert!(hand.contains("LOOPBACK-MBOX"), "{hand}");
        assert!(hand.contains("SSH-HOLYC"), "{hand}");
        match repl_line(&mut p, r#"ViewSection("config");"#).unwrap() {
            ReplResult::Output(s) => assert!(s.contains("VIEW config"), "{s}"),
            other => panic!("{other:?}"),
        }
        match repl_line(&mut p, r#"WriteSection("config");"#).unwrap() {
            ReplResult::Output(s) => assert!(s.contains("IMMUTABLE-DISABLED"), "{s}"),
            other => panic!("{other:?}"),
        }
        match repl_line(&mut p, "Reboot();").unwrap() {
            ReplResult::Output(s) => assert!(s.contains("POWER-REBOOT"), "{s}"),
            other => panic!("{other:?}"),
        }
    }
}
