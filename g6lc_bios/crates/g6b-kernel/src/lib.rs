// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! BIOS kernel host path: TempleOS/ZealOS services rewritten onto BoardSpec.
//!
//! HolyC init, HTML+JS viewport, optional Gr (SysGrInit), dual-band REPL.

#![allow(missing_docs)]

use g6b_css::Engine;
use g6b_dom::{Event, EventHost, EventInit, Node};
use g6b_holyc::{eval_src, Program, ReplResult};
use g6b_html::{parse, script_sources, to_uart_lines};
use g6b_http::Router;
use g6b_js::{HostDispatch, JsValue, LodashError, LodashParam, Op};
use g6b_spec::{parse_json, stringify_json, BoardSpec, Json};
use g6b_wasm::{Host, Ldexec, LdexecInit, LibwasmValue, ObjectKind, ObjectTable};
use std::collections::BTreeMap;

pub mod browser;
pub mod task_services;
pub mod tasks;
pub mod timers;
pub use browser::{RouterPort, WasmUi};
pub use g6b_iframe::{
    FilesAppView, FrameEngine, HostNeed, IframeSession, SessionCaps, SessionContext,
    SessionDocument, SessionIntern, SessionLoad, SessionVar, SessionVars, MAX_HISTORY,
    MAX_SESSIONS, MAX_TABS_PER_WINDOW, MAX_WINDOWS, SHELL_CONTEXT_ID,
};
pub use g6b_zealcli::{Action as ZealAction, Session as ZealCli, PROMPT as ZEAL_PROMPT};
pub use task_services::{TaskServices, Work, WorkResponse};
pub use timers::{frame_period_ns, TimerHeap};

/// VGA zealcli boots first; GPU announce + `LoadUI` hand off to browser-ui.
pub fn wants_zealcli(spec: &BoardSpec, gpu_ready: bool) -> bool {
    spec.wants_zealcli(gpu_ready)
}

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
    store: Option<&'a mut g6b_pglite::StoreRegistry>,
    pglite_handle: Option<i32>,
    spec: &'a BoardSpec,
    diagnostics: Vec<String>,
    handles: Vec<Node>,
    /// Child path from `dom` to the node the guest sees as handle 1 (the
    /// libwasm mount). Empty means `dom` itself is the root mount, which is
    /// what the small `bios-ui.wasm` lane and `run_with_fuel` re-entry use.
    mount_path: Vec<usize>,
    /// DOM child handle -> parent DOM handle, recorded by `appendChild` /
    /// `insertBefore` so `parentNode`/sibling getters can answer inside the
    /// staging tree.
    placements: BTreeMap<i32, i32>,
    /// DOM parent handle -> ordered child DOM handles. `0` marks a tree child
    /// that has no handle yet; it is materialized lazily as a snapshot handle
    /// when the guest indexes into it (see `child_dom_handle`).
    child_handles: BTreeMap<i32, Vec<i32>>,
    pending_slot: Option<i32>,
    /// Bounded `env.await` / `env.throw` / `env.catch` slots (same Host
    /// import set as the VGA `start_ops` face). 0 idle, 1 pending, 2 resolved,
    /// 3 rejected. The LDC cell's D await uses `libwasm_await__void` instead.
    await_slots: [u8; 4],
    objects: ObjectTable<LibwasmValue>,
    /// Event listeners registered by the libwasm `_start` call and collected
    /// after `run_start` returns so `BrowserSession` can own them.
    pending_event_listeners: Vec<(String, String, u64, bool)>,
    pending_event_removals: Vec<u64>,
    /// D `Object_Call_EventHandler__void` listeners (`onclick` → `jsCallback`).
    pending_event_delegates: Vec<(String, String, i32, i32, bool)>,
    /// `(handle, prop) → (ctx, ptr)` for `Object_Getter__EventHandler`.
    event_handlers: BTreeMap<(i32, String), (i32, i32)>,
    last_await_failed: bool,
    last_await_error: String,
    last_await_value: String,
    /// svelte-engine `window.__svelteD.ts` — not a kernel type table.
    js_exports: g6b_wasm::JsExports,
    /// Live paths from the session document (`self.dom`) for handles interned
    /// by `document.querySelector` / `getElementById` / `libwasm_global`.
    session_paths: BTreeMap<i32, Vec<usize>>,
    window_handle: Option<i32>,
    document_handle: Option<i32>,
    console_handle: Option<i32>,
    /// Set when a wasm listener calls `event.preventDefault()`.
    last_prevent_default: bool,
    timers: &'a mut crate::timers::TimerHeap,
    now_ns: u64,
    /// Named D delegates from `libwasm_set__function` (`exportDelegate`).
    named_delegates: BTreeMap<String, (i32, i32)>,
    /// Post-boot `g6b-hw` session. None during `_start` (hw stays lazy).
    hw: Option<&'a mut g6b_hw::HwSession>,
    /// Interned `platform` (ObjectKind::Platform). Shell only; not iframe.
    platform_handle: Option<i32>,
    /// Interned `platform.hw` (ObjectKind::Hw). Lazy; intern does not listen.
    hw_handle: Option<i32>,
    hw_net_handle: Option<i32>,
    hw_display_handle: Option<i32>,
    hw_tcp_handle: Option<i32>,
    hw_udp_handle: Option<i32>,
    hw_gl_handle: Option<i32>,
}

fn event_type_from_handler_prop(prop: &str) -> &str {
    prop.strip_prefix("on")
        .filter(|s| !s.is_empty())
        .unwrap_or(prop)
}

fn is_input_event_type(ty: &str) -> bool {
    matches!(
        ty,
        "click"
            | "keydown"
            | "keyup"
            | "mousemove"
            | "mouseover"
            | "pointermove"
            | "pointerdown"
            | "pointerup"
            | "pointerclick"
    ) || g6b_hw::is_hw_event_type(ty)
}

fn named_delegate_matches_event(name: &str, event_type: &str) -> bool {
    let ty = event_type_from_handler_prop(name);
    is_input_event_type(ty) && ty.eq_ignore_ascii_case(event_type)
}

/// Node at `path` below `root` (each element is a `children` index).
fn node_at<'a>(mut node: &'a Node, path: &[usize]) -> Option<&'a Node> {
    for &i in path {
        node = node.children.get(i)?;
    }
    Some(node)
}

/// Mutable [`node_at`].
fn node_at_mut<'a>(mut node: &'a mut Node, path: &[usize]) -> Option<&'a mut Node> {
    for &i in path {
        node = node.children.get_mut(i)?;
    }
    Some(node)
}

/// DFS path from `root` to the node whose `id` is `id`.
fn path_from_root(root: &Node, id: &str) -> Option<Vec<usize>> {
    fn walk(node: &Node, id: &str, path: &mut Vec<usize>) -> bool {
        if node.id.as_deref() == Some(id) {
            return true;
        }
        for (i, child) in node.children.iter().enumerate() {
            path.push(i);
            if walk(child, id, path) {
                return true;
            }
            path.pop();
        }
        false
    }
    let mut path = Vec::new();
    if walk(root, id, &mut path) {
        Some(path)
    } else {
        None
    }
}

/// DFS path from `root` to the first element whose tag name is `name`.
fn path_from_name(root: &Node, name: &str) -> Option<Vec<usize>> {
    fn walk(node: &Node, name: &str, path: &mut Vec<usize>) -> bool {
        if node.name.eq_ignore_ascii_case(name) {
            return true;
        }
        for (i, child) in node.children.iter().enumerate() {
            path.push(i);
            if walk(child, name, path) {
                return true;
            }
            path.pop();
        }
        false
    }
    let mut path = Vec::new();
    if walk(root, name, &mut path) {
        Some(path)
    } else {
        None
    }
}

/// A resolved libwasm receiver: a staging DOM node, a DOM proxy wrapper
/// (`classList`/`style`/`dataset`/`childNodes`), or a plain object-table value.
enum LibwasmReceiver {
    Dom(i32),
    Proxy(i32, String),
    Value(LibwasmValue),
}

/// `data-foo-bar` / `background-color` spelling of a camelCase JS name.
fn camel_to_kebab(s: &str) -> String {
    let mut out = String::new();
    for c in s.chars() {
        if c.is_ascii_uppercase() {
            out.push('-');
            out.push(c.to_ascii_lowercase());
        } else {
            out.push(c);
        }
    }
    out
}

/// A `LibwasmValue::Object` with `ObjectKind::Array` and numeric string keys —
/// the libwasm array/NodeList/HTMLCollection exchange form.
fn array_object(items: Vec<LibwasmValue>) -> LibwasmValue {
    let len = items.len() as u32;
    let mut props = std::collections::HashMap::new();
    for (i, v) in items.into_iter().enumerate() {
        props.insert(i.to_string(), v);
    }
    props.insert("length".to_string(), LibwasmValue::U32(len));
    LibwasmValue::Object {
        kind: ObjectKind::Array,
        props,
    }
}

/// `innerHTML` for the staging DOM: text + attributes, escaped.
fn node_inner_html(n: &Node) -> String {
    fn emit(n: &Node, out: &mut String) {
        if n.name == "#text" {
            out.push_str(&g6b_html::escape_text(&n.text));
            return;
        }
        out.push('<');
        out.push_str(&n.name);
        if let Some(id) = &n.id {
            out.push_str(" id=\"");
            out.push_str(&g6b_html::escape_text(id));
            out.push('"');
        }
        for (k, v) in &n.attributes {
            if k == "id" {
                continue;
            }
            out.push(' ');
            out.push_str(k);
            out.push_str("=\"");
            out.push_str(&g6b_html::escape_text(v));
            out.push('"');
        }
        out.push('>');
        for c in &n.children {
            emit(c, out);
        }
        out.push_str("</");
        out.push_str(&n.name);
        out.push('>');
    }
    let mut out = String::new();
    for c in &n.children {
        emit(c, &mut out);
    }
    out
}

const VOID_TAGS: &[&str] = &[
    "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source",
    "track", "wbr",
];

/// Serialize a `Node` tree back to HTML. Hidden nodes are skipped, text and
/// attribute values are escaped, and void tags are emitted without a closing
/// tag so the CSS parser can read the resulting string back in.
pub fn dom_to_html(node: &Node) -> String {
    fn emit(n: &Node, out: &mut String) {
        if n.hidden {
            return;
        }
        if n.name == "#text" {
            out.push_str(&g6b_html::escape_text(&n.text));
            return;
        }
        if n.name == "document" {
            for c in &n.children {
                emit(c, out);
            }
            return;
        }
        if n.name == "style" {
            out.push_str("<style>");
            for c in &n.children {
                if c.name == "#text" {
                    out.push_str(&c.text);
                }
            }
            out.push_str("</style>");
            return;
        }
        if n.name == "script" && n.children.is_empty() {
            out.push('<');
            out.push_str(&n.name);
            if let Some(id) = &n.id {
                out.push_str(" id=\"");
                out.push_str(&g6b_html::escape_text(id));
                out.push('"');
            }
            for (k, v) in &n.attributes {
                if k == "id" {
                    continue;
                }
                out.push(' ');
                out.push_str(k);
                out.push_str("=\"");
                out.push_str(&g6b_html::escape_text(v));
                out.push('"');
            }
            out.push_str("></script>");
            return;
        }
        out.push('<');
        out.push_str(&n.name);
        if let Some(id) = &n.id {
            out.push_str(" id=\"");
            out.push_str(&g6b_html::escape_text(id));
            out.push('"');
        }
        for (k, v) in &n.attributes {
            if k == "id" {
                continue;
            }
            out.push(' ');
            out.push_str(k);
            out.push_str("=\"");
            out.push_str(&g6b_html::escape_text(v));
            out.push('"');
        }
        out.push('>');
        if !VOID_TAGS.contains(&n.name.as_str()) {
            for c in &n.children {
                emit(c, out);
            }
            out.push_str("</");
            out.push_str(&n.name);
            out.push('>');
        }
    }
    let mut out = String::new();
    emit(node, &mut out);
    out
}

/// DFS path from `node` to the first descendant matching `sel`.
/// `Ok(false)` = no match; `Err` = invalid selector (fail-closed to no match).
fn find_matching_path(node: &Node, sel: &str, path: &mut Vec<usize>) -> Result<bool, String> {
    g6b_dom::validate_selector(sel)?;
    fn walk(n: &Node, sel: &str, path: &mut Vec<usize>) -> bool {
        for (i, c) in n.children.iter().enumerate() {
            path.push(i);
            if c.matches_selector(sel).unwrap_or(false) || walk(c, sel, path) {
                return true;
            }
            path.pop();
        }
        false
    }
    Ok(walk(node, sel, path))
}

/// DFS path from `node` to the descendant whose `id` matches (descendants
/// only, matching `getElementById` on a document/element receiver).
fn find_by_id_path(node: &Node, id: &str, path: &mut Vec<usize>, top: bool) -> bool {
    if !top && node.id.as_deref() == Some(id) {
        return true;
    }
    for (i, c) in node.children.iter().enumerate() {
        path.push(i);
        if find_by_id_path(c, id, path, false) {
            return true;
        }
        path.pop();
    }
    false
}

/// Immutable lookup of the first descendant with `id`. Used by the CSS scanout
/// path to locate the libwasm panel without mutating the `BrowserSession` DOM.
fn each_id<F>(node: &mut Node, id: &str, f: &mut F) -> Result<(), String>
where
    F: FnMut(&mut Node) -> Result<(), String>,
{
    if node.id.as_deref() == Some(id) {
        f(node)?;
    }
    let n = node.children.len();
    for i in 0..n {
        each_id(&mut node.children[i], id, f)?;
    }
    Ok(())
}

fn session_slot_on_path(dom: &Node, path: &[usize]) -> Option<usize> {
    let mut n = dom;
    let mut slot = None;
    for &i in path {
        n = n.children.get(i)?;
        if let Some(s) = n.id.as_deref().and_then(g6b_iframe::session_stage_slot) {
            slot = Some(s);
        }
    }
    slot
}

fn find_node_by_id<'a>(node: &'a Node, id: &str) -> Option<&'a Node> {
    if node.id.as_deref() == Some(id) {
        return Some(node);
    }
    for c in &node.children {
        if let Some(n) = find_node_by_id(c, id) {
            return Some(n);
        }
    }
    None
}

/// First descendant whose element name matches `name` (depth-first).
fn first_descendant_by_name<'a>(node: &'a Node, name: &str) -> Option<&'a Node> {
    if node.name.eq_ignore_ascii_case(name) {
        return Some(node);
    }
    for c in &node.children {
        if let Some(n) = first_descendant_by_name(c, name) {
            return Some(n);
        }
    }
    None
}

/// DFS paths of every descendant matching a `getElementsBy*`/`querySelectorAll`
/// selector, in document order.
fn collect_matching(node: &Node, method: &str, want: &str, out: &mut Vec<Vec<usize>>) {
    fn matches(n: &Node, method: &str, want: &str) -> bool {
        if n.name == "#text" {
            return false;
        }
        match method {
            "getElementsByTagName" => want == "*" || n.name.eq_ignore_ascii_case(want),
            "getElementsByClassName" => {
                let classes = n.get_attribute("class").unwrap_or("");
                want.split_ascii_whitespace()
                    .all(|c| classes.split_ascii_whitespace().any(|t| t == c))
            }
            "getElementsByName" => n.get_attribute("name") == Some(want),
            _ => n.matches_selector(want).unwrap_or(false),
        }
    }
    fn walk(n: &Node, method: &str, want: &str, path: &mut Vec<usize>, out: &mut Vec<Vec<usize>>) {
        for (i, c) in n.children.iter().enumerate() {
            path.push(i);
            if matches(c, method, want) {
                out.push(path.clone());
            }
            walk(c, method, want, path, out);
            path.pop();
        }
    }
    walk(node, method, want, &mut Vec::new(), out);
}

/// JavaScript `String.prototype` subset for `LibwasmValue::String` receivers.
/// `None` = method not implemented (the caller logs WASM-OBJECT-CALL-MISSING).
fn string_call(s: &str, method: &str, args: &[LibwasmValue]) -> Option<LibwasmValue> {
    let sarg = |i: usize| -> Option<String> {
        args.get(i)
            .and_then(|v| v.as_string().ok().map(String::from))
    };
    let iarg = |i: usize| args.get(i).map(|v| v.to_i32()).unwrap_or(0);
    let chars: Vec<char> = s.chars().collect();
    let len = chars.len() as i32;
    Some(match method {
        "length" => LibwasmValue::U32(chars.len() as u32),
        "concat" => {
            let mut out = s.to_string();
            for a in args {
                out.push_str(&a.to_js_string());
            }
            LibwasmValue::String(out)
        }
        "slice" => {
            let norm = |v: i32| if v < 0 { (len + v).max(0) } else { v.min(len) };
            let start = norm(iarg(0));
            let end = if args.len() > 1 { norm(iarg(1)) } else { len };
            LibwasmValue::String(
                chars[start as usize..end.max(start) as usize]
                    .iter()
                    .collect(),
            )
        }
        "substring" | "substr" => {
            let start = iarg(0).clamp(0, len) as usize;
            let end = if args.len() > 1 {
                if method == "substr" {
                    (start as i32 + iarg(1).max(0)).clamp(0, len) as usize
                } else {
                    (iarg(1).clamp(0, len) as usize).max(start)
                }
            } else {
                chars.len()
            };
            LibwasmValue::String(chars[start..end].iter().collect())
        }
        "charAt" | "at" => {
            let i = iarg(0);
            LibwasmValue::String(
                chars
                    .get(i.max(0) as usize)
                    .map(|c| c.to_string())
                    .unwrap_or_default(),
            )
        }
        "charCodeAt" | "codePointAt" => {
            let i = iarg(0);
            match chars.get(i.max(0) as usize) {
                Some(c) => LibwasmValue::U32(*c as u32),
                None => LibwasmValue::None,
            }
        }
        "indexOf" => {
            let needle = sarg(0).unwrap_or_default();
            LibwasmValue::I32(
                s.find(&needle)
                    .map(|p| s[..p].chars().count() as i32)
                    .unwrap_or(-1),
            )
        }
        "lastIndexOf" => {
            let needle = sarg(0).unwrap_or_default();
            LibwasmValue::I32(
                s.rfind(&needle)
                    .map(|p| s[..p].chars().count() as i32)
                    .unwrap_or(-1),
            )
        }
        "includes" => LibwasmValue::Bool(s.contains(&sarg(0).unwrap_or_default())),
        "startsWith" => LibwasmValue::Bool(s.starts_with(&sarg(0).unwrap_or_default())),
        "endsWith" => LibwasmValue::Bool(s.ends_with(&sarg(0).unwrap_or_default())),
        "split" => {
            let sep = sarg(0).unwrap_or_default();
            let parts: Vec<LibwasmValue> = if sep.is_empty() {
                s.chars()
                    .map(|c| LibwasmValue::String(c.to_string()))
                    .collect()
            } else {
                s.split(&sep)
                    .map(|p| LibwasmValue::String(p.to_string()))
                    .collect()
            };
            array_object(parts)
        }
        "trim" => LibwasmValue::String(s.trim().into()),
        "trimStart" | "trimLeft" => LibwasmValue::String(s.trim_start().into()),
        "trimEnd" | "trimRight" => LibwasmValue::String(s.trim_end().into()),
        "toUpperCase" => LibwasmValue::String(s.to_uppercase()),
        "toLowerCase" => LibwasmValue::String(s.to_lowercase()),
        "repeat" => LibwasmValue::String(s.repeat(iarg(0).max(0) as usize)),
        "replace" => {
            let from = sarg(0).unwrap_or_default();
            let to = sarg(1).unwrap_or_default();
            LibwasmValue::String(s.replacen(&from, &to, 1))
        }
        "padStart" | "padEnd" => {
            let target = iarg(0).max(0) as usize;
            let pad = sarg(1)
                .filter(|p| !p.is_empty())
                .unwrap_or_else(|| " ".into());
            let mut out = s.to_string();
            while out.chars().count() < target {
                if method == "padStart" {
                    out = format!("{pad}{out}");
                } else {
                    out.push_str(&pad);
                }
                if out.chars().count() > target + pad.chars().count() + 1 {
                    break; // non-terminating pad guard
                }
            }
            LibwasmValue::String(out.chars().take(target.max(chars.len())).collect())
        }
        "toString" | "valueOf" => LibwasmValue::String(s.to_string()),
        _ => return None,
    })
}

/// Persisted wasm host tables between `_start` and UI-thread re-entry.
pub(crate) struct WasmPersist {
    handles: Vec<Node>,
    mount_path: Vec<usize>,
    placements: BTreeMap<i32, i32>,
    child_handles: BTreeMap<i32, Vec<i32>>,
    objects: ObjectTable<LibwasmValue>,
    session_paths: BTreeMap<i32, Vec<usize>>,
    window_handle: Option<i32>,
    document_handle: Option<i32>,
    console_handle: Option<i32>,
    named_delegates: BTreeMap<String, (i32, i32)>,
    event_handlers: BTreeMap<(i32, String), (i32, i32)>,
}

impl Default for WasmPersist {
    fn default() -> Self {
        Self {
            handles: Vec::new(),
            mount_path: Vec::new(),
            placements: BTreeMap::new(),
            child_handles: BTreeMap::new(),
            objects: ObjectTable::new(),
            session_paths: BTreeMap::new(),
            window_handle: None,
            document_handle: None,
            console_handle: None,
            named_delegates: BTreeMap::new(),
            event_handlers: BTreeMap::new(),
        }
    }
}

impl<'a> KernelHost<'a> {
    fn attach(
        dom: &'a mut Node,
        router: &'a Router,
        spec: &'a BoardSpec,
        persist: WasmPersist,
        timers: &'a mut crate::timers::TimerHeap,
        now_ns: u64,
        store: Option<&'a mut g6b_pglite::StoreRegistry>,
    ) -> Self {
        Self {
            dom,
            router,
            store,
            pglite_handle: None,
            spec,
            diagnostics: Vec::new(),
            handles: persist.handles,
            mount_path: persist.mount_path,
            placements: persist.placements,
            child_handles: persist.child_handles,
            pending_slot: None,
            await_slots: [0; 4],
            objects: persist.objects,
            pending_event_listeners: Vec::new(),
            pending_event_removals: Vec::new(),
            pending_event_delegates: Vec::new(),
            event_handlers: persist.event_handlers,
            last_await_failed: false,
            last_await_error: String::new(),
            last_await_value: String::new(),
            js_exports: g6b_wasm::JsExports::bios_app(),
            session_paths: persist.session_paths,
            window_handle: persist.window_handle,
            document_handle: persist.document_handle,
            console_handle: persist.console_handle,
            last_prevent_default: false,
            timers,
            now_ns,
            named_delegates: persist.named_delegates,
            hw: None,
            platform_handle: None,
            hw_handle: None,
            hw_net_handle: None,
            hw_display_handle: None,
            hw_tcp_handle: None,
            hw_udp_handle: None,
            hw_gl_handle: None,
        }
    }

    fn attach_fresh(
        dom: &'a mut Node,
        router: &'a Router,
        spec: &'a BoardSpec,
        mount_path: Vec<usize>,
        timers: &'a mut crate::timers::TimerHeap,
        now_ns: u64,
        store: Option<&'a mut g6b_pglite::StoreRegistry>,
    ) -> Self {
        Self::attach(
            dom,
            router,
            spec,
            WasmPersist {
                mount_path,
                ..WasmPersist::default()
            },
            timers,
            now_ns,
            store,
        )
    }

    /// Resolve the live storage of a DOM handle. A handle with a `placements`
    /// entry lives inside its parent's `children` (the canonical tree node —
    /// the `handles` slot only holds the staging copy while unplaced). The
    /// chain bottoms out at an anchor: `1` (the mount in `self.dom`) or an
    /// unplaced staging node in `self.handles`. Returns the anchor handle and
    /// the child indices descending from it.
    fn handle_anchor(&self, h: i32) -> Result<(i32, Vec<usize>), String> {
        let mut idxs = Vec::new();
        let mut cur = h;
        let mut hops = 0;
        while let Some(&p) = self.placements.get(&cur) {
            let idx = self
                .child_handles
                .get(&p)
                .and_then(|v| v.iter().position(|&x| x == cur))
                .ok_or_else(|| "libwasm placement table desync".to_string())?;
            idxs.push(idx);
            cur = p;
            hops += 1;
            if hops > 4096 {
                return Err("libwasm placement chain loop".into());
            }
        }
        idxs.reverse();
        Ok((cur, idxs))
    }

    fn anchor_node(&self, anchor: i32) -> Result<&Node, String> {
        if let Some(path) = self.session_paths.get(&anchor) {
            return node_at(self.dom, path)
                .ok_or_else(|| "libwasm session path is stale".to_string());
        }
        match anchor {
            1 => node_at(self.dom, &self.mount_path)
                .ok_or_else(|| "libwasm mount path is stale".to_string()),
            h if (2..g6b_wasm::OBJECT_BASE).contains(&h) => self
                .handles
                .get((h - 2) as usize)
                .ok_or_else(|| format!("invalid dom handle {h}")),
            _ => Err(format!("invalid dom handle {anchor}")),
        }
    }

    fn anchor_node_mut(&mut self, anchor: i32) -> Result<&mut Node, String> {
        if self.session_paths.contains_key(&anchor) {
            let path = self.session_paths[&anchor].clone();
            return node_at_mut(self.dom, &path)
                .ok_or_else(|| "libwasm session path is stale".to_string());
        }
        match anchor {
            1 => node_at_mut(self.dom, &self.mount_path)
                .ok_or_else(|| "libwasm mount path is stale".to_string()),
            h if (2..g6b_wasm::OBJECT_BASE).contains(&h) => self
                .handles
                .get_mut((h - 2) as usize)
                .ok_or_else(|| format!("invalid dom handle {h}")),
            _ => Err(format!("invalid dom handle {anchor}")),
        }
    }

    fn node(&self, h: i32) -> Result<&Node, String> {
        if let Some(path) = self.session_paths.get(&h) {
            return node_at(self.dom, path)
                .ok_or_else(|| "libwasm session path is stale".to_string());
        }
        let (anchor, idxs) = self.handle_anchor(h)?;
        let mut n = self.anchor_node(anchor)?;
        for &i in &idxs {
            n = n
                .children
                .get(i)
                .ok_or_else(|| "libwasm child index desync".to_string())?;
        }
        Ok(n)
    }

    fn node_mut(&mut self, h: i32) -> Result<&mut Node, String> {
        if self.session_paths.contains_key(&h) {
            let path = self.session_paths[&h].clone();
            return node_at_mut(self.dom, &path)
                .ok_or_else(|| "libwasm session path is stale".to_string());
        }
        let (anchor, idxs) = self.handle_anchor(h)?;
        let mut n = self.anchor_node_mut(anchor)?;
        for &i in &idxs {
            n = n
                .children
                .get_mut(i)
                .ok_or_else(|| "libwasm child index desync".to_string())?;
        }
        Ok(n)
    }

    /// Intern a live node of the session document (`self.dom`) so wasm
    /// `querySelector` / `getElementById` mutate the UI thread tree, not a
    /// detached snapshot.
    fn intern_session_node(&mut self, path: Vec<usize>) -> Result<i32, String> {
        for (&h, p) in &self.session_paths {
            if *p == path {
                return Ok(h);
            }
        }
        let _ = node_at(self.dom, &path).ok_or("libwasm session path is stale")?;
        if self.handles.len() + 2 >= g6b_wasm::MAX_OBJECTS {
            return Err("WASM DOM handle budget exceeded".into());
        }
        let h = self.handles.len() as i32 + 2;
        self.handles.push(Node::elem("#session"));
        self.session_paths.insert(h, path);
        Ok(h)
    }

    fn ensure_js_globals(&mut self) -> Result<(i32, i32, i32), String> {
        if let (Some(w), Some(d), Some(c)) = (
            self.window_handle,
            self.document_handle,
            self.console_handle,
        ) {
            return Ok((w, d, c));
        }
        let doc_live = self.intern_session_node(Vec::new())?;
        let document = self.intern_value(
            LibwasmValue::empty(ObjectKind::Document)
                .with_prop("__dom", LibwasmValue::I32(doc_live)),
        )?;
        let window = self.intern_value(
            LibwasmValue::empty(ObjectKind::Window)
                .with_prop("document", LibwasmValue::I32(document)),
        )?;
        let console = self.intern_value(LibwasmValue::empty(ObjectKind::Empty))?;
        self.document_handle = Some(document);
        self.window_handle = Some(window);
        self.console_handle = Some(console);
        self.diagnostics
            .push("WASM-JS-GLOBAL window/document/console".into());
        Ok((window, document, console))
    }

    /// Intern a live DOM `Event` for wasm listener re-entry.
    /// `hw*` types intern as [`ObjectKind::HwEvent`] (BIOS UI, like MouseEvent).
    fn intern_event(&mut self, event: &Event) -> Result<i32, String> {
        self.last_prevent_default = event.default_prevented;
        let hw = g6b_hw::is_hw_event_type(&event.event_type);
        let kind = if hw {
            ObjectKind::HwEvent
        } else {
            ObjectKind::Event
        };
        let ctor = if hw { "HWEvent" } else { "Event" };
        self.intern_value(LibwasmValue::Object {
            kind,
            props: [
                (
                    "type".into(),
                    LibwasmValue::String(event.event_type.clone()),
                ),
                (
                    "target".into(),
                    LibwasmValue::String(event.target.clone().unwrap_or_default()),
                ),
                ("detail".into(), LibwasmValue::String(event.detail.clone())),
                ("clientX".into(), LibwasmValue::I32(event.client_x)),
                ("clientY".into(), LibwasmValue::I32(event.client_y)),
                ("cancelable".into(), LibwasmValue::Bool(event.cancelable)),
                (
                    "defaultPrevented".into(),
                    LibwasmValue::Bool(event.default_prevented),
                ),
                ("bubbles".into(), LibwasmValue::Bool(event.bubbles)),
                ("constructor".into(), LibwasmValue::String(ctor.into())),
            ]
            .into(),
        })
    }

    fn get_object(&self, h: i32) -> Result<&LibwasmValue, String> {
        self.objects.get(h)
    }

    fn record_await(&mut self, h: i32) -> Result<(), String> {
        let s = if h <= 0 {
            String::new()
        } else {
            g6b_wasm::string_of(self.get_object(h)?)
        };
        let failed = h > 0 && matches!(self.get_object(h)?, LibwasmValue::Error(_));
        self.record_await_from_string(s, failed);
        Ok(())
    }

    // ---- B63 typed object-getter/call surface (merged handle space) ----
    //
    // Handles `1..g6b_wasm::OBJECT_BASE` name staging DOM nodes; handles
    // `>= OBJECT_BASE` name `self.objects` entries. A DOM node reaches the
    // guest as a "DOM wrapper":
    // `Object { kind: Element, props: { "__dom": I32(h) } }`. DOM proxies
    // (`classList`, `style`, `dataset`, `childNodes`) add `__role: String`.

    fn dom_wrapper(h: i32) -> LibwasmValue {
        LibwasmValue::Object {
            kind: ObjectKind::Element,
            props: [("__dom".to_string(), LibwasmValue::I32(h))].into(),
        }
    }

    fn dom_proxy(h: i32, role: &str) -> LibwasmValue {
        LibwasmValue::Object {
            kind: ObjectKind::Element,
            props: [
                ("__dom".to_string(), LibwasmValue::I32(h)),
                ("__role".to_string(), LibwasmValue::String(role.to_string())),
            ]
            .into(),
        }
    }

    /// The DOM handle behind a `Handle` call argument (a DOM wrapper).
    fn dom_handle_of(value: &LibwasmValue) -> Option<i32> {
        match value {
            LibwasmValue::Object { props, .. } => match props.get("__dom") {
                Some(LibwasmValue::I32(h)) => Some(*h),
                Some(LibwasmValue::U32(h)) => i32::try_from(*h).ok(),
                _ => None,
            },
            _ => None,
        }
    }

    fn resolve_receiver(&self, handle: i32) -> Result<LibwasmReceiver, String> {
        if (1..g6b_wasm::OBJECT_BASE).contains(&handle) {
            self.node(handle)?;
            return Ok(LibwasmReceiver::Dom(handle));
        }
        let value = self.objects.get(handle)?.clone();
        if let LibwasmValue::Object { props, .. } = &value {
            if let Some(h) = Self::dom_handle_of(&value) {
                let role = match props.get("__role") {
                    Some(LibwasmValue::String(s)) => s.clone(),
                    _ => String::new(),
                };
                return Ok(if role.is_empty() {
                    LibwasmReceiver::Dom(h)
                } else {
                    LibwasmReceiver::Proxy(h, role)
                });
            }
        }
        Ok(LibwasmReceiver::Value(value))
    }

    /// True when `ancestor` reaches `h` by walking `placements` upward.
    /// Guards `appendChild`/`insertBefore` against a cycle (`c.contains(p)`
    /// in the reference host).
    fn handle_is_ancestor(&self, ancestor: i32, mut h: i32) -> bool {
        let mut hops = 0;
        while let Some(&p) = self.placements.get(&h) {
            if p == ancestor {
                return true;
            }
            h = p;
            hops += 1;
            if hops > 4096 {
                return true; // refuse: placement chain loop
            }
        }
        h == ancestor
    }

    /// Insert (or append) DOM handle `child` under `parent`, keeping the
    /// parallel handle table in `child_handles` aligned with `Node.children`.
    fn place_child(
        &mut self,
        parent: i32,
        child: i32,
        index: Option<usize>,
    ) -> Result<usize, String> {
        if child == parent || self.handle_is_ancestor(child, parent) {
            // Node.webidl appendChild [Throws] → DOMException.HIERARCHY_REQUEST_ERR.
            return Err(g6b_wasm::hierarchy_request_append_child());
        }
        if self.handles.len() + 2 >= g6b_wasm::MAX_OBJECTS {
            return Err("WASM DOM handle budget exceeded".into());
        }
        // DOM `appendChild` moves a node: when `child` is already placed,
        // detach it so its canonical node is back in `handles` before we
        // copy it into the new parent.
        if let Some(&old_parent) = self.placements.get(&child) {
            self.detach_child(old_parent, child)?;
        }
        let child_node = self.node(child)?.clone();
        let idx = {
            let p = self.node_mut(parent)?;
            let idx = index.unwrap_or(p.children.len()).min(p.children.len());
            p.children.insert(idx, child_node);
            p.dirty = true;
            idx
        };
        let len = self.node(parent)?.children.len();
        let entry = self.child_handles.entry(parent).or_default();
        while entry.len() < len.saturating_sub(1) {
            entry.push(0);
        }
        if idx >= entry.len() {
            entry.push(child);
        } else {
            entry.insert(idx, child);
        }
        self.placements.insert(child, parent);
        Ok(idx)
    }

    /// Detach DOM handle `child` from `parent`. Returns `Err` when the
    /// placement table has no such child (fail-closed, like the reference
    /// host's `s.parentNode !== p` check).
    fn detach_child(&mut self, parent: i32, child: i32) -> Result<(), String> {
        let idx = self
            .child_handles
            .get(&parent)
            .and_then(|v| v.iter().position(|&h| h == child))
            .ok_or_else(|| "WASM removeChild on an unplaced child".to_string())?;
        let detached = {
            let p = self.node_mut(parent)?;
            if idx < p.children.len() {
                let n = p.children.remove(idx);
                p.dirty = true;
                Some(n)
            } else {
                None
            }
        };
        if let Some(v) = self.child_handles.get_mut(&parent) {
            v.remove(idx);
        }
        self.placements.remove(&child);
        // The detached node carried all mutations made while it was placed;
        // move it back into the staging slot so `node(child)` keeps reading
        // canonical state now that the handle is unplaced.
        if let (Some(n), true) = (detached, child >= 2) {
            if let Some(slot) = self.handles.get_mut((child - 2) as usize) {
                *slot = n;
            }
        }
        Ok(())
    }

    /// The DOM handle of `parent`'s child at `idx`, materializing a snapshot
    /// handle for a tree child that never had one. Snapshot handles are
    /// clones: mutations through them do not propagate back into the tree
    /// (a staging-model limit, not a guest-visible lie — the reference host
    /// hands out live nodes).
    fn child_dom_handle(&mut self, parent: i32, idx: usize) -> Result<Option<i32>, String> {
        let len = self.node(parent)?.children.len();
        if idx >= len {
            return Ok(None);
        }
        if self.handles.len() + 2 >= g6b_wasm::MAX_OBJECTS {
            return Err("WASM DOM handle budget exceeded".into());
        }
        let entry = self.child_handles.entry(parent).or_default();
        while entry.len() < len {
            entry.push(0);
        }
        let mut h = entry[idx];
        if h == 0 {
            let clone = self.node(parent)?.children[idx].clone();
            h = self.handles.len() as i32 + 2;
            self.handles.push(clone);
            if let Some(v) = self.child_handles.get_mut(&parent) {
                v[idx] = h;
            }
            self.placements.insert(h, parent);
        }
        Ok(Some(h))
    }

    fn sibling_dom_handle(&mut self, h: i32, delta: i64) -> Result<Option<i32>, String> {
        let Some(&parent) = self.placements.get(&h) else {
            return Ok(None);
        };
        let Some(idx) = self
            .child_handles
            .get(&parent)
            .and_then(|v| v.iter().position(|&c| c == h))
        else {
            return Ok(None);
        };
        let target = idx as i64 + delta;
        if target < 0 {
            return Ok(None);
        }
        self.child_dom_handle(parent, target as usize)
    }

    /// Wrap the child at `idx` (or `LibwasmValue::None` when absent) — the
    /// `firstChild`/`childNodes[i]`/`item(i)` shape.
    fn child_wrapper(&mut self, parent: i32, idx: usize) -> Result<LibwasmValue, String> {
        Ok(match self.child_dom_handle(parent, idx)? {
            Some(h) => Self::dom_wrapper(h),
            None => LibwasmValue::None,
        })
    }

    /// `prop = value` on a `LibwasmValue::Object` stored in the table.
    fn object_set(&mut self, handle: i32, name: &str, value: LibwasmValue) -> Result<(), String> {
        self.objects.get_mut(handle)?.set_prop(name, value)
    }

    /// `class` attribute tokens of a DOM node.
    fn class_tokens(&self, h: i32) -> Vec<String> {
        self.node(h)
            .ok()
            .and_then(|n| n.get_attribute("class").map(String::from))
            .unwrap_or_default()
            .split_ascii_whitespace()
            .map(String::from)
            .collect()
    }

    fn set_class_tokens(&mut self, h: i32, tokens: &[String]) -> Result<(), String> {
        let n = self.node_mut(h)?;
        let joined = tokens.join(" ");
        if joined.is_empty() {
            n.remove_attribute("class");
        } else {
            n.set_attribute("class", &joined)?;
        }
        Ok(())
    }

    /// `style` attribute declarations of a DOM node.
    fn style_decls(&self, h: i32) -> Vec<(String, String)> {
        self.node(h)
            .ok()
            .and_then(|n| n.get_attribute("style").map(String::from))
            .unwrap_or_default()
            .split(';')
            .filter_map(|decl| {
                let (k, v) = decl.split_once(':')?;
                let k = k.trim().to_string();
                if k.is_empty() {
                    return None;
                }
                Some((k, v.trim().to_string()))
            })
            .collect()
    }

    fn set_style_decls(&mut self, h: i32, decls: &[(String, String)]) -> Result<(), String> {
        let text = decls
            .iter()
            .map(|(k, v)| format!("{k}: {v};"))
            .collect::<Vec<_>>()
            .join(" ");
        let n = self.node_mut(h)?;
        if text.is_empty() {
            n.remove_attribute("style");
        } else {
            n.set_attribute("style", &text)?;
        }
        Ok(())
    }

    /// Materialize a detached snapshot of `node` and return its DOM handle.
    fn snapshot_handle(&mut self, node: &Node, parent: i32) -> Result<i32, String> {
        if self.handles.len() + 2 >= g6b_wasm::MAX_OBJECTS {
            return Err("WASM DOM handle budget exceeded".into());
        }
        let h = self.handles.len() as i32 + 2;
        self.handles.push(node.clone());
        if parent > 0 {
            self.placements.insert(h, parent);
        }
        Ok(h)
    }

    /// `getElementById`/`querySelector` support: materialize a handle for the
    /// descendant of `h` found at `path` (empty `path` = `h` itself).
    fn descendant_handle(&mut self, h: i32, path: &[usize]) -> Result<Option<i32>, String> {
        let mut cur = h;
        for &i in path {
            match self.child_dom_handle(cur, i)? {
                Some(next) => cur = next,
                None => return Ok(None),
            }
        }
        Ok(Some(cur))
    }

    /// The `Node`/`Element`/`HTMLElement`/`Document` getter allow-list.
    /// Unknown getters fail closed like the reference host (`prop in obj`
    /// is false): the runtime maps this error to `Optional`/`None` results.
    fn dom_getter(&mut self, h: i32, name: &str) -> Result<LibwasmValue, String> {
        match name {
            "nodeName" => {
                let n = self.node(h)?;
                Ok(LibwasmValue::String(if n.name == "#text" {
                    "#text".into()
                } else {
                    n.name.to_ascii_uppercase()
                }))
            }
            "tagName" => {
                let n = self.node(h)?;
                Ok(LibwasmValue::String(if n.name == "#text" {
                    String::new()
                } else {
                    n.name.to_ascii_uppercase()
                }))
            }
            "localName" => Ok(LibwasmValue::String(self.node(h)?.name.clone())),
            "nodeType" => Ok(LibwasmValue::U32(if self.node(h)?.name == "#text" {
                3
            } else {
                1
            })),
            "id" => Ok(LibwasmValue::String(
                self.node(h)?.id.clone().unwrap_or_default(),
            )),
            "className" => Ok(LibwasmValue::String(
                self.node(h)?
                    .get_attribute("class")
                    .unwrap_or("")
                    .to_string(),
            )),
            "innerText" | "textContent" => Ok(LibwasmValue::String(self.node(h)?.inner_text())),
            "nodeValue" => {
                let n = self.node(h)?;
                Ok(if n.name == "#text" {
                    LibwasmValue::String(n.text.clone())
                } else {
                    LibwasmValue::None
                })
            }
            "innerHTML" => Ok(LibwasmValue::String(node_inner_html(self.node(h)?))),
            "hidden" => Ok(LibwasmValue::Bool(self.node(h)?.hidden)),
            "isConnected" => Ok(LibwasmValue::Bool(true)),
            "hasChildNodes" => Ok(LibwasmValue::Bool(!self.node(h)?.children.is_empty())),
            "childElementCount" => Ok(LibwasmValue::U32(
                self.node(h)?
                    .children
                    .iter()
                    .filter(|c| c.name != "#text")
                    .count() as u32,
            )),
            "length" => Ok(LibwasmValue::U32(self.node(h)?.children.len() as u32)),
            "classList" => Ok(Self::dom_proxy(h, "classList")),
            "style" => Ok(Self::dom_proxy(h, "style")),
            "dataset" => Ok(Self::dom_proxy(h, "dataset")),
            "children" | "childNodes" => Ok(Self::dom_proxy(h, "nodelist")),
            "firstChild" => self.child_wrapper(h, 0),
            "lastChild" => {
                let len = self.node(h)?.children.len();
                if len == 0 {
                    Ok(LibwasmValue::None)
                } else {
                    self.child_wrapper(h, len - 1)
                }
            }
            "firstElementChild" | "lastElementChild" => {
                let node = self.node(h)?;
                let idx = if name == "firstElementChild" {
                    node.children.iter().position(|c| c.name != "#text")
                } else {
                    node.children.iter().rposition(|c| c.name != "#text")
                };
                match idx {
                    Some(i) => self.child_wrapper(h, i),
                    None => Ok(LibwasmValue::None),
                }
            }
            "nextSibling" => Ok(match self.sibling_dom_handle(h, 1)? {
                Some(s) => Self::dom_wrapper(s),
                None => LibwasmValue::None,
            }),
            "previousSibling" => Ok(match self.sibling_dom_handle(h, -1)? {
                Some(s) => Self::dom_wrapper(s),
                None => LibwasmValue::None,
            }),
            "parentNode" | "parentElement" => Ok(match self.placements.get(&h) {
                Some(&p) => Self::dom_wrapper(p),
                None => LibwasmValue::None,
            }),
            "ownerDocument" | "documentElement" | "getRootNode" => Ok(Self::dom_wrapper(1)),
            "cloneNode" => {
                let n = self.node(h)?.clone();
                Ok(Self::dom_wrapper(self.snapshot_handle(&n, 0)?))
            }
            "baseURI"
            | "nodePrincipal"
            | "baseURIObject"
            | "flattenedTreeParentNode"
            | "parentFlexElement"
            | "attributes"
            | "getAttributeNames"
            | "sheet" => Ok(LibwasmValue::None),
            _ => {
                self.diagnostics
                    .push(format!("WASM-OBJECT-GETTER-MISSING {name}"));
                Err(format!("libwasm object has no property {name}"))
            }
        }
    }

    fn dom_proxy_getter(&mut self, h: i32, role: &str, name: &str) -> Result<LibwasmValue, String> {
        match role {
            "nodelist" => match name {
                "length" => Ok(LibwasmValue::U32(self.node(h)?.children.len() as u32)),
                _ => {
                    self.diagnostics
                        .push(format!("WASM-OBJECT-GETTER-MISSING nodelist.{name}"));
                    Err(format!("libwasm object has no property {name}"))
                }
            },
            "classList" => match name {
                "length" => Ok(LibwasmValue::U32(self.class_tokens(h).len() as u32)),
                "value" => Ok(LibwasmValue::String(
                    self.node(h)?
                        .get_attribute("class")
                        .unwrap_or("")
                        .to_string(),
                )),
                _ => {
                    self.diagnostics
                        .push(format!("WASM-OBJECT-GETTER-MISSING classList.{name}"));
                    Err(format!("libwasm object has no property {name}"))
                }
            },
            "style" => match name {
                "cssText" => Ok(LibwasmValue::String(
                    self.node(h)?
                        .get_attribute("style")
                        .unwrap_or("")
                        .to_string(),
                )),
                "length" => Ok(LibwasmValue::U32(self.style_decls(h).len() as u32)),
                other => {
                    // CSSStyleDeclaration property read: `style.width` etc.
                    let prop = camel_to_kebab(other);
                    Ok(LibwasmValue::String(
                        self.style_decls(h)
                            .into_iter()
                            .find(|(k, _)| *k == prop)
                            .map(|(_, v)| v)
                            .unwrap_or_default(),
                    ))
                }
            },
            "dataset" => {
                let attr = format!("data-{}", camel_to_kebab(name));
                Ok(match self.node(h)?.get_attribute(&attr) {
                    Some(v) => LibwasmValue::String(v.to_string()),
                    None => LibwasmValue::None,
                })
            }
            _ => {
                self.diagnostics
                    .push(format!("WASM-OBJECT-GETTER-MISSING {role}.{name}"));
                Err(format!("libwasm object has no property {name}"))
            }
        }
    }

    /// Object-table (non-DOM) getter: `clone_prop` for real objects, `length`
    /// for strings and vectors, fail-closed `None` otherwise.
    fn value_getter(&self, value: &LibwasmValue, name: &str) -> Result<LibwasmValue, String> {
        match value {
            LibwasmValue::Object { kind, .. } if *kind == ObjectKind::Window => match name {
                "document" => {
                    if let Some(h) = self.document_handle {
                        Ok(LibwasmValue::I32(h))
                    } else {
                        value.clone_prop(name)
                    }
                }
                "platform" => value.clone_prop("platform"),
                "location" | "origin" => Ok(LibwasmValue::String("bios://g6lc".into())),
                _ => value.clone_prop(name),
            },
            LibwasmValue::Object { kind, .. } if *kind == ObjectKind::Hw => {
                let role = Self::hw_role(value);
                if let Some(v) = self.hw_live_str(role, name) {
                    Ok(v)
                } else {
                    value.clone_prop(name)
                }
            }
            LibwasmValue::Object { kind, .. } if *kind == ObjectKind::Document => match name {
                "defaultView" => Ok(self
                    .window_handle
                    .map(LibwasmValue::I32)
                    .unwrap_or(LibwasmValue::None)),
                _ => value.clone_prop(name),
            },
            LibwasmValue::Object { .. } => value.clone_prop(name),
            LibwasmValue::String(s) if name == "length" => {
                Ok(LibwasmValue::U32(s.chars().count() as u32))
            }
            LibwasmValue::I32Vec(v) if name == "length" => Ok(LibwasmValue::U32(v.len() as u32)),
            LibwasmValue::U32Vec(v) if name == "length" => Ok(LibwasmValue::U32(v.len() as u32)),
            _ => Err(format!("libwasm object has no property {name}")),
        }
    }

    /// `Object_Call_*` / `Object_VarArgCall__*` on a DOM receiver.
    fn dom_call(
        &mut self,
        h: i32,
        method: &str,
        args: &[LibwasmValue],
    ) -> Result<LibwasmValue, String> {
        let sarg = |i: usize| -> Option<String> {
            args.get(i)
                .and_then(|v| v.as_string().ok().map(String::from))
        };
        match method {
            "setAttribute" | "setAttributeNS" => {
                let (name, value) = if method == "setAttribute" {
                    (sarg(0), sarg(1))
                } else {
                    (sarg(1), sarg(2))
                };
                let name = name.ok_or("setAttribute name arg")?;
                let value = value.ok_or("setAttribute value arg")?;
                self.node_mut(h)?.set_attribute(&name, &value)?;
                Ok(LibwasmValue::None)
            }
            "getAttribute" | "getAttributeNS" => {
                let i = usize::from(method == "getAttributeNS");
                let name = sarg(i).ok_or("getAttribute name arg")?;
                Ok(match self.node(h)?.get_attribute(&name) {
                    Some(v) => LibwasmValue::String(v.to_string()),
                    None => LibwasmValue::None,
                })
            }
            "removeAttribute" | "removeAttributeNS" => {
                let i = usize::from(method == "removeAttributeNS");
                let name = sarg(i).ok_or("removeAttribute name arg")?;
                self.node_mut(h)?.remove_attribute(&name);
                Ok(LibwasmValue::None)
            }
            "hasAttribute" | "hasAttributeNS" => {
                let i = usize::from(method == "hasAttributeNS");
                let name = sarg(i).ok_or("hasAttribute name arg")?;
                Ok(LibwasmValue::Bool(
                    self.node(h)?.get_attribute(&name).is_some(),
                ))
            }
            "toggleAttribute" => {
                let name = sarg(0).ok_or("toggleAttribute name arg")?;
                let n = self.node_mut(h)?;
                let now = if n.get_attribute(&name).is_some() {
                    n.remove_attribute(&name);
                    false
                } else {
                    n.set_attribute(&name, "")?;
                    true
                };
                Ok(LibwasmValue::Bool(now))
            }
            "getAttributeNames" => {
                let names: Vec<LibwasmValue> = self
                    .node(h)?
                    .attributes
                    .keys()
                    .map(|k| LibwasmValue::String(k.clone()))
                    .collect();
                Ok(array_object(names))
            }
            // Property assignments arrive as calls named by the property.
            "id" | "className" | "title" | "value" | "href" | "name" | "type" | "placeholder"
            | "role" | "tabIndex" | "accessKey" | "slot" => {
                let value = args.first().map(|v| v.to_js_string()).unwrap_or_default();
                let attr = if method == "className" {
                    "class"
                } else {
                    method
                };
                self.node_mut(h)?.set_attribute(attr, &value)?;
                Ok(LibwasmValue::None)
            }
            "innerText" | "textContent" | "nodeValue" => {
                let value = args
                    .first()
                    .map(|v| match v {
                        LibwasmValue::None => String::new(),
                        other => other.to_js_string(),
                    })
                    .unwrap_or_default();
                self.node_mut(h)?.set_inner_text(&value);
                Ok(LibwasmValue::None)
            }
            "innerHTML" | "outerHTML" | "src" | "onclick" | "__proto__" | "constructor" => {
                self.diagnostics
                    .push(format!("WASM-SET-PROPERTY-REFUSED {method}"));
                Err(format!("WASM unsupported DOM property: {method}"))
            }
            "hidden" => {
                let on = args.first().map(|v| v.truthy()).unwrap_or(false);
                self.node_mut(h)?.set_visible(!on);
                Ok(LibwasmValue::None)
            }
            "appendChild" => {
                let child = Self::dom_handle_of(args.first().ok_or("appendChild node arg")?)
                    .ok_or("appendChild arg is not a DOM node")?;
                self.place_child(h, child, None)?;
                Ok(Self::dom_wrapper(child))
            }
            "append" | "prepend" => {
                let at_start = method == "prepend";
                for (i, arg) in args.iter().enumerate() {
                    if let Some(child) = Self::dom_handle_of(arg) {
                        let idx = if at_start { Some(i) } else { None };
                        self.place_child(h, child, idx)?;
                    } else if let Ok(s) = arg.as_string() {
                        let text = self.snapshot_handle(&Node::text_node(s), h)?;
                        let idx = if at_start { Some(i) } else { None };
                        self.place_child(h, text, idx)?;
                    }
                }
                Ok(LibwasmValue::None)
            }
            "removeChild" => {
                let child = Self::dom_handle_of(args.first().ok_or("removeChild node arg")?)
                    .ok_or("removeChild arg is not a DOM node")?;
                self.detach_child(h, child)?;
                Ok(Self::dom_wrapper(child))
            }
            "insertBefore" => {
                let new = Self::dom_handle_of(args.first().ok_or("insertBefore node arg")?)
                    .ok_or("insertBefore arg is not a DOM node")?;
                let reference = args.get(1).and_then(Self::dom_handle_of);
                let idx = reference.and_then(|r| {
                    self.child_handles
                        .get(&h)
                        .and_then(|v| v.iter().position(|&c| c == r))
                });
                if reference.is_some() && idx.is_none() {
                    return Err("WASM insertBefore reference is not a child".into());
                }
                self.place_child(h, new, idx)?;
                Ok(Self::dom_wrapper(new))
            }
            "replaceChild" => {
                let new = Self::dom_handle_of(args.first().ok_or("replaceChild node arg")?)
                    .ok_or("replaceChild arg is not a DOM node")?;
                let old = Self::dom_handle_of(args.get(1).ok_or("replaceChild child arg")?)
                    .ok_or("replaceChild old arg is not a DOM node")?;
                let idx = self
                    .child_handles
                    .get(&h)
                    .and_then(|v| v.iter().position(|&c| c == old))
                    .ok_or("WASM replaceChild on an unplaced child")?;
                self.detach_child(h, old)?;
                self.place_child(h, new, Some(idx))?;
                Ok(Self::dom_wrapper(old))
            }
            "cloneNode" => {
                let deep = args.first().map(|v| v.truthy()).unwrap_or(false);
                let n = if deep {
                    self.node(h)?.clone()
                } else {
                    let mut shallow = self.node(h)?.clone();
                    shallow.children.clear();
                    shallow
                };
                Ok(Self::dom_wrapper(self.snapshot_handle(&n, 0)?))
            }
            "isSameNode" | "isEqualNode" => Ok(LibwasmValue::Bool(
                args.first().and_then(Self::dom_handle_of) == Some(h),
            )),
            "contains" => {
                let Some(other) = args.first().and_then(Self::dom_handle_of) else {
                    return Ok(LibwasmValue::Bool(false));
                };
                Ok(LibwasmValue::Bool(self.handle_is_ancestor(h, other)))
            }
            "matches" => {
                let sel = sarg(0).ok_or("matches selector arg")?;
                let matched = self.node(h)?.matches_selector(&sel).unwrap_or(false);
                Ok(LibwasmValue::Bool(matched))
            }
            "closest" => {
                let sel = sarg(0).ok_or("closest selector arg")?;
                let mut cur = Some(h);
                let mut hops = 0;
                while let Some(c) = cur {
                    if self.node(c)?.matches_selector(&sel).unwrap_or(false) {
                        return Ok(Self::dom_wrapper(c));
                    }
                    cur = self.placements.get(&c).copied();
                    hops += 1;
                    if hops > 4096 {
                        break;
                    }
                }
                Ok(LibwasmValue::None)
            }
            "querySelector" => {
                let sel = sarg(0).ok_or("querySelector selector arg")?;
                let found = {
                    let mut path = Vec::new();
                    match find_matching_path(self.node(h)?, &sel, &mut path) {
                        Ok(true) => Some(path),
                        Ok(false) => None,
                        Err(e) => {
                            self.diagnostics
                                .push(format!("WASM-QUERY-SELECTOR-ERR {e}"));
                            None
                        }
                    }
                };
                match found {
                    Some(rel) => {
                        if let Some(root) = self.session_paths.get(&h).cloned() {
                            let mut full = root;
                            full.extend(rel);
                            Ok(Self::dom_wrapper(self.intern_session_node(full)?))
                        } else {
                            Ok(match self.descendant_handle(h, &rel)? {
                                Some(dh) => Self::dom_wrapper(dh),
                                None => LibwasmValue::None,
                            })
                        }
                    }
                    None => Ok(LibwasmValue::None),
                }
            }
            "querySelectorAll"
            | "getElementsByTagName"
            | "getElementsByClassName"
            | "getElementsByName" => {
                let want = sarg(0).unwrap_or_default();
                let mut out = Vec::new();
                let mut found = Vec::new();
                collect_matching(self.node(h)?, method, &want, &mut found);
                for path in found {
                    if let Some(dh) = self.descendant_handle(h, &path)? {
                        out.push(Self::dom_wrapper(dh));
                    }
                }
                Ok(array_object(out))
            }
            "getElementById" => {
                let id = sarg(0).ok_or("getElementById arg")?;
                let mut path = Vec::new();
                if find_by_id_path(self.node(h)?, &id, &mut path, true) {
                    if let Some(root) = self.session_paths.get(&h).cloned() {
                        let mut full = root;
                        full.extend(path);
                        Ok(Self::dom_wrapper(self.intern_session_node(full)?))
                    } else {
                        Ok(match self.descendant_handle(h, &path)? {
                            Some(dh) => Self::dom_wrapper(dh),
                            None => LibwasmValue::None,
                        })
                    }
                } else {
                    Ok(LibwasmValue::None)
                }
            }
            "createElement" | "createElementNS" | "createCustomElement" => {
                let i = usize::from(method == "createElementNS");
                let tag = sarg(i).unwrap_or_else(|| "div".into());
                let nh = self.create_element(&tag)?;
                Ok(Self::dom_wrapper(nh))
            }
            "createTextNode" | "createComment" => {
                let data = sarg(0).unwrap_or_default();
                if self.handles.len() + 2 >= g6b_wasm::MAX_OBJECTS {
                    return Err("WASM DOM handle budget exceeded".into());
                }
                let nh = self.handles.len() as i32 + 2;
                self.handles.push(Node::text_node(&data));
                Ok(Self::dom_wrapper(nh))
            }
            "getRootNode" => Ok(Self::dom_wrapper(1)),
            "addEventListener" | "removeEventListener" | "dispatchEvent" => {
                self.diagnostics
                    .push(format!("WASM-EVENT-OBJECT-CALL {method} h={h}"));
                Ok(LibwasmValue::I32(0))
            }
            "normalize"
            | "click"
            | "focus"
            | "blur"
            | "scrollIntoView"
            | "scroll"
            | "scrollTo"
            | "scrollBy"
            | "requestFullscreen"
            | "releasePointerCapture"
            | "setPointerCapture"
            | "insertAdjacentText" => Ok(LibwasmValue::I32(0)),
            "remove" => {
                if let Some(&parent) = self.placements.get(&h) {
                    let _ = self.detach_child(parent, h);
                }
                Ok(LibwasmValue::None)
            }
            "hasPointerCapture" => Ok(LibwasmValue::Bool(false)),
            "getBoundingClientRect"
            | "getClientRects"
            | "animate"
            | "getAnimations"
            | "computedStyleMap"
            | "attachShadow" => {
                self.diagnostics
                    .push(format!("WASM-OBJECT-CALL-EMPTY {method}"));
                Ok(LibwasmValue::empty(ObjectKind::Empty))
            }
            "insertAdjacentHTML" | "insertAdjacentElement" => {
                self.diagnostics
                    .push(format!("WASM-OBJECT-CALL-EMPTY {method}"));
                Ok(LibwasmValue::None)
            }
            "toString" => Ok(LibwasmValue::String("[object Element]".into())),
            _ => {
                self.diagnostics
                    .push(format!("WASM-OBJECT-CALL-MISSING {method}"));
                Ok(LibwasmValue::String(String::new()))
            }
        }
    }

    /// `Object_Call_*` on a DOM proxy (`classList`/`style`/`dataset`/list).
    fn dom_proxy_call(
        &mut self,
        h: i32,
        role: &str,
        method: &str,
        args: &[LibwasmValue],
    ) -> Result<LibwasmValue, String> {
        match role {
            "classList" => self.class_list_call(h, method, args),
            "style" => self.style_call(h, method, args),
            "dataset" => self.dataset_call(h, method, args),
            "nodelist" => match method {
                "item" | "at" => {
                    let idx = args.first().map(|v| v.to_i32()).unwrap_or(0);
                    if idx < 0 {
                        return Ok(LibwasmValue::None);
                    }
                    self.child_wrapper(h, idx as usize)
                }
                "forEach" | "entries" | "keys" | "values" | "iterator" => {
                    // Iteratee delegates cannot re-enter the running cell.
                    Ok(LibwasmValue::None)
                }
                "length" => Ok(LibwasmValue::U32(self.node(h)?.children.len() as u32)),
                _ => {
                    self.diagnostics
                        .push(format!("WASM-OBJECT-CALL-MISSING nodelist.{method}"));
                    Ok(LibwasmValue::String(String::new()))
                }
            },
            _ => {
                self.diagnostics
                    .push(format!("WASM-OBJECT-CALL-MISSING {role}.{method}"));
                Ok(LibwasmValue::String(String::new()))
            }
        }
    }

    fn class_list_call(
        &mut self,
        h: i32,
        method: &str,
        args: &[LibwasmValue],
    ) -> Result<LibwasmValue, String> {
        let tokens = self.class_tokens(h);
        match method {
            "add" => {
                let mut next = tokens;
                for arg in args {
                    if let Ok(c) = arg.as_string() {
                        for c in c.split_ascii_whitespace() {
                            if !next.iter().any(|t| t == c) {
                                next.push(c.to_string());
                            }
                        }
                    }
                }
                self.set_class_tokens(h, &next)?;
                Ok(LibwasmValue::None)
            }
            "remove" => {
                let drop: Vec<String> = args
                    .iter()
                    .filter_map(|a| a.as_string().ok().map(String::from))
                    .collect();
                let next: Vec<String> = tokens
                    .into_iter()
                    .filter(|t| !drop.iter().any(|d| d == t))
                    .collect();
                self.set_class_tokens(h, &next)?;
                Ok(LibwasmValue::None)
            }
            "toggle" => {
                let c = args
                    .first()
                    .and_then(|a| a.as_string().ok().map(String::from))
                    .ok_or("classList.toggle arg")?;
                let mut next = tokens;
                let on = if let Some(i) = next.iter().position(|t| *t == c) {
                    next.remove(i);
                    false
                } else {
                    next.push(c);
                    true
                };
                self.set_class_tokens(h, &next)?;
                Ok(LibwasmValue::Bool(on))
            }
            "contains" => {
                let c = args
                    .first()
                    .and_then(|a| a.as_string().ok().map(String::from))
                    .unwrap_or_default();
                Ok(LibwasmValue::Bool(tokens.iter().any(|t| *t == c)))
            }
            "replace" => {
                let a = args
                    .first()
                    .and_then(|a| a.as_string().ok().map(String::from))
                    .ok_or("classList.replace arg")?;
                let b = args
                    .get(1)
                    .and_then(|a| a.as_string().ok().map(String::from))
                    .ok_or("classList.replace arg")?;
                let mut next = tokens;
                let found = if let Some(i) = next.iter().position(|t| *t == a) {
                    next[i] = b;
                    true
                } else {
                    false
                };
                self.set_class_tokens(h, &next)?;
                Ok(LibwasmValue::Bool(found))
            }
            "item" => {
                let idx = args.first().map(|v| v.to_i32()).unwrap_or(0);
                Ok(match tokens.get(idx.max(0) as usize) {
                    Some(t) => LibwasmValue::String(t.clone()),
                    None => LibwasmValue::None,
                })
            }
            "length" => Ok(LibwasmValue::U32(tokens.len() as u32)),
            "toString" => Ok(LibwasmValue::String(tokens.join(" "))),
            _ => {
                self.diagnostics
                    .push(format!("WASM-OBJECT-CALL-MISSING classList.{method}"));
                Ok(LibwasmValue::String(String::new()))
            }
        }
    }

    fn style_call(
        &mut self,
        h: i32,
        method: &str,
        args: &[LibwasmValue],
    ) -> Result<LibwasmValue, String> {
        match method {
            "setProperty" => {
                let prop = args
                    .first()
                    .and_then(|a| a.as_string().ok().map(String::from))
                    .ok_or("style.setProperty name arg")?;
                let value = args
                    .get(1)
                    .and_then(|a| a.as_string().ok().map(String::from))
                    .unwrap_or_default();
                let mut decls = self.style_decls(h);
                match decls.iter_mut().find(|(k, _)| *k == prop) {
                    Some(slot) => slot.1 = value,
                    None => decls.push((prop, value)),
                }
                self.set_style_decls(h, &decls)?;
                Ok(LibwasmValue::None)
            }
            "removeProperty" => {
                let prop = args
                    .first()
                    .and_then(|a| a.as_string().ok().map(String::from))
                    .ok_or("style.removeProperty name arg")?;
                let mut decls = self.style_decls(h);
                let old = decls
                    .iter()
                    .position(|(k, _)| *k == prop)
                    .map(|i| decls.remove(i).1)
                    .unwrap_or_default();
                self.set_style_decls(h, &decls)?;
                Ok(LibwasmValue::String(old))
            }
            "getPropertyValue" | "getPropertyPriority" => {
                let prop = args
                    .first()
                    .and_then(|a| a.as_string().ok().map(String::from))
                    .ok_or("style.getPropertyValue name arg")?;
                let decls = self.style_decls(h);
                Ok(LibwasmValue::String(
                    decls
                        .into_iter()
                        .find(|(k, _)| *k == prop)
                        .map(|(_, v)| v)
                        .unwrap_or_default(),
                ))
            }
            "cssText" => {
                let value = args
                    .first()
                    .and_then(|a| a.as_string().ok().map(String::from))
                    .unwrap_or_default();
                let n = self.node_mut(h)?;
                if value.is_empty() {
                    n.remove_attribute("style");
                } else {
                    n.set_attribute("style", &value)?;
                }
                Ok(LibwasmValue::None)
            }
            "item" => {
                let idx = args.first().map(|v| v.to_i32()).unwrap_or(0);
                let decls = self.style_decls(h);
                Ok(LibwasmValue::String(
                    decls
                        .get(idx.max(0) as usize)
                        .map(|(k, _)| k.clone())
                        .unwrap_or_default(),
                ))
            }
            "length" => Ok(LibwasmValue::U32(self.style_decls(h).len() as u32)),
            "toString" => Ok(LibwasmValue::String(
                self.node(h)?
                    .get_attribute("style")
                    .unwrap_or("")
                    .to_string(),
            )),
            other => {
                // `style.backgroundColor = "x"` arrives as a one-string call
                // named by the camelCase property.
                if args.len() == 1 {
                    if let Ok(v) = args[0].as_string() {
                        let prop = camel_to_kebab(other);
                        let mut decls = self.style_decls(h);
                        match decls.iter_mut().find(|(k, _)| *k == prop) {
                            Some(slot) => slot.1 = v.to_string(),
                            None => decls.push((prop, v.to_string())),
                        }
                        self.set_style_decls(h, &decls)?;
                        return Ok(LibwasmValue::None);
                    }
                }
                self.diagnostics
                    .push(format!("WASM-OBJECT-CALL-MISSING style.{other}"));
                Ok(LibwasmValue::String(String::new()))
            }
        }
    }

    fn dataset_call(
        &mut self,
        h: i32,
        method: &str,
        args: &[LibwasmValue],
    ) -> Result<LibwasmValue, String> {
        let attr = format!("data-{}", camel_to_kebab(method));
        match args.len() {
            0 => Ok(match self.node(h)?.get_attribute(&attr) {
                Some(v) => LibwasmValue::String(v.to_string()),
                None => LibwasmValue::None,
            }),
            _ => {
                let value = args[0].to_js_string();
                if matches!(args[0], LibwasmValue::None) {
                    self.node_mut(h)?.remove_attribute(&attr);
                } else {
                    self.node_mut(h)?.set_attribute(&attr, &value)?;
                }
                Ok(LibwasmValue::None)
            }
        }
    }

    /// `Object_Call_*` on an object-table value (string/vector/Map/JSON).
    fn value_call(
        &mut self,
        handle: i32,
        value: LibwasmValue,
        method: &str,
        args: &[LibwasmValue],
    ) -> Result<LibwasmValue, String> {
        match &value {
            LibwasmValue::Object { kind, .. }
                if *kind == ObjectKind::Event || *kind == ObjectKind::HwEvent =>
            {
                match method {
                    "preventDefault" => {
                        self.last_prevent_default = true;
                        if let LibwasmValue::Object { props, .. } = self.objects.get_mut(handle)? {
                            props.insert("defaultPrevented".into(), LibwasmValue::Bool(true));
                        }
                        self.diagnostics.push("WASM-EVENT-PREVENT-DEFAULT".into());
                        return Ok(LibwasmValue::None);
                    }
                    "stopPropagation" | "stopImmediatePropagation" => {
                        self.diagnostics.push(format!("WASM-EVENT-{method}"));
                        return Ok(LibwasmValue::None);
                    }
                    _ => {}
                }
            }
            LibwasmValue::Object { kind, .. } if *kind == ObjectKind::Window => {
                if method == "fetch" {
                    let url = args.first().map(|v| v.to_js_string()).unwrap_or_default();
                    let handle = self.fetch(&url)?;
                    return Ok(LibwasmValue::I32(handle));
                }
            }
            LibwasmValue::Object { kind, .. } if *kind == ObjectKind::Hw => {
                let role = Self::hw_role(&value);
                let mut argv: Vec<String> = args.iter().map(|v| v.to_js_string()).collect();
                let needs_id = matches!(
                    (role, method),
                    (
                        "net",
                        "ifconfig"
                            | "route"
                            | "link"
                            | "dns"
                            | "proto"
                            | "inetStat"
                            | "tcpListen"
                            | "tcpConnect"
                            | "udpBind"
                            | "hostApply"
                    ) | ("tcp", "listen" | "connect" | "tcpListen" | "tcpConnect")
                        | ("udp", "bind" | "udpBind")
                );
                if needs_id {
                    let id = self
                        .hw
                        .as_deref()
                        .and_then(|s| s.spec.primary_net())
                        .map(|a| a.id.clone())
                        .unwrap_or_else(|| "net0".into());
                    argv.insert(0, id);
                }
                let refs: Vec<&str> = argv.iter().map(String::as_str).collect();
                let name = match (role, method) {
                    ("root", "stat") => "hwStat",
                    ("root", "listen") => "hwListen",
                    ("root", "wake") => "hwWake",
                    ("root", "cable") => "hwCable",
                    ("root", "config") => "hwConfig",
                    ("root", "natMode" | "setNat") => "hwNat",
                    ("root", "hostList") => "hwHostList",
                    ("root", "hostRevert") => "hwHostRevert",
                    ("root" | "net", "ifconfig") => "hwIfconfig",
                    ("root" | "net", "route") => "hwRoute",
                    ("root" | "net", "link") => "hwLink",
                    ("root" | "net", "dns") => "hwDns",
                    ("root" | "net", "proto") => "hwProto",
                    ("root" | "net", "inetStat") => "hwInetStat",
                    ("root" | "net", "hostApply") => "hwHostApply",
                    ("root", "tcpListen") => "hwTcpListen",
                    ("net" | "tcp", "tcpListen" | "listen") => "hwTcpListen",
                    ("root", "tcpConnect") => "hwTcpConnect",
                    ("net" | "tcp", "tcpConnect" | "connect") => "hwTcpConnect",
                    ("root", "tcpAccept") => "hwTcpAccept",
                    ("tcp", "tcpAccept" | "accept") => "hwTcpAccept",
                    ("root", "tcpSend") => "hwTcpSend",
                    ("tcp", "tcpSend" | "send") => "hwTcpSend",
                    ("root", "tcpRecv") => "hwTcpRecv",
                    ("tcp", "tcpRecv" | "recv") => "hwTcpRecv",
                    ("root", "udpBind") => "hwUdpBind",
                    ("net" | "udp", "udpBind" | "bind") => "hwUdpBind",
                    ("root", "udpSend") => "hwUdpSend",
                    ("udp", "udpSend" | "send") => "hwUdpSend",
                    ("root", "udpRecv") => "hwUdpRecv",
                    ("udp", "udpRecv" | "recv") => "hwUdpRecv",
                    ("root", "sockClose") => "hwSockClose",
                    ("tcp" | "udp", "close" | "sockClose") => "hwSockClose",
                    ("root", "dispStat") => "hwDispStat",
                    ("display", "stat" | "dispStat") => "hwDispStat",
                    ("root", "dispLink") => "hwDispLink",
                    ("display", "link" | "dispLink") => "hwDispLink",
                    ("root" | "display", "dispMode" | "mode") => "hwDispMode",
                    ("root" | "display", "dispSurface") => "hwDispSurface",
                    ("root" | "display", "gl") => "hwGl",
                    ("gl", "mode") => "hwGl",
                    ("root", "glList") => "hwGlList",
                    ("gl", "list") => "hwGlList",
                    ("root", "glApply") => "hwGlApply",
                    ("gl", "apply") => "hwGlApply",
                    ("root", "glRevert") => "hwGlRevert",
                    ("gl", "revert") => "hwGlRevert",
                    _ => "",
                };
                if !name.is_empty() {
                    if matches!(
                        name,
                        "hwStat"
                            | "hwListen"
                            | "hwInetStat"
                            | "hwHostList"
                            | "hwTcpRecv"
                            | "hwUdpRecv"
                            | "hwDispStat"
                            | "hwGlList"
                    ) {
                        let hw = self.hw_session()?;
                        let body = g6b_hw::call_instant(hw, name, &refs);
                        return Ok(LibwasmValue::String(body));
                    }
                    let hw = self.hw_session()?;
                    match g6b_hw::call(hw, name, &refs) {
                        Ok(body) => {
                            self.record_await_from_string(body.clone(), false);
                            return Ok(LibwasmValue::String(body));
                        }
                        Err(e) => {
                            self.record_await_from_string(e.message.clone(), true);
                            return Err(e.message);
                        }
                    }
                }
            }
            LibwasmValue::Object { kind, .. }
                if *kind == ObjectKind::Empty && self.console_handle == Some(handle) =>
            {
                if matches!(method, "log" | "info" | "warn" | "error" | "debug") {
                    let msg = args
                        .iter()
                        .map(|v| v.to_js_string())
                        .collect::<Vec<_>>()
                        .join(" ");
                    self.diagnostics
                        .push(format!("WASM-CONSOLE-{method} {msg}"));
                    return Ok(LibwasmValue::None);
                }
            }
            LibwasmValue::Object { kind, .. } if *kind == ObjectKind::Document => {
                if let Some(h) = Self::dom_handle_of(&value) {
                    return self.dom_call(h, method, args);
                }
            }
            LibwasmValue::String(s) => {
                if let Some(v) = string_call(s, method, args) {
                    return Ok(v);
                }
            }
            LibwasmValue::I32Vec(_) | LibwasmValue::U32Vec(_) => {
                if let Some(v) = self.vec_call(handle, method, args)? {
                    return Ok(v);
                }
            }
            LibwasmValue::Object { .. } => {
                if let Some(v) = self.object_value_call(handle, method, args)? {
                    return Ok(v);
                }
            }
            scalar => {
                if method == "toString" {
                    return Ok(LibwasmValue::String(scalar.to_js_string()));
                }
                if method == "valueOf" {
                    return Ok(scalar.clone());
                }
            }
        }
        self.diagnostics
            .push(format!("WASM-OBJECT-CALL-MISSING {method}"));
        Ok(LibwasmValue::String(String::new()))
    }

    /// In-place `Vec` methods on `I32Vec`/`U32Vec` table entries.
    fn vec_call(
        &mut self,
        handle: i32,
        method: &str,
        args: &[LibwasmValue],
    ) -> Result<Option<LibwasmValue>, String> {
        let arg_i32 = |i: usize| args.get(i).map(|v| v.to_i32()).unwrap_or(0);
        let is_i32 = matches!(self.objects.get(handle), Ok(LibwasmValue::I32Vec(_)));
        let len = match self.objects.get(handle) {
            Ok(LibwasmValue::I32Vec(v)) => v.len(),
            Ok(LibwasmValue::U32Vec(v)) => v.len(),
            _ => 0,
        };
        let out = match method {
            "length" => Some(LibwasmValue::U32(len as u32)),
            "push" => {
                for a in args {
                    match self.objects.get_mut(handle)? {
                        LibwasmValue::I32Vec(v) => v.push(a.to_i32()),
                        LibwasmValue::U32Vec(v) => v.push(a.to_u32()),
                        _ => {}
                    }
                }
                Some(LibwasmValue::U32((len + args.len()) as u32))
            }
            "pop" => {
                let v = match self.objects.get_mut(handle)? {
                    LibwasmValue::I32Vec(v) => v.pop().map(LibwasmValue::I32),
                    LibwasmValue::U32Vec(v) => v.pop().map(LibwasmValue::U32),
                    _ => None,
                };
                Some(v.unwrap_or(LibwasmValue::None))
            }
            "shift" => {
                let v = match self.objects.get_mut(handle)? {
                    LibwasmValue::I32Vec(v) if !v.is_empty() => {
                        Some(LibwasmValue::I32(v.remove(0)))
                    }
                    LibwasmValue::U32Vec(v) if !v.is_empty() => {
                        Some(LibwasmValue::U32(v.remove(0)))
                    }
                    _ => None,
                };
                Some(v.unwrap_or(LibwasmValue::None))
            }
            "unshift" => {
                for a in args.iter().rev() {
                    match self.objects.get_mut(handle)? {
                        LibwasmValue::I32Vec(v) => v.insert(0, a.to_i32()),
                        LibwasmValue::U32Vec(v) => v.insert(0, a.to_u32()),
                        _ => {}
                    }
                }
                Some(LibwasmValue::U32((len + args.len()) as u32))
            }
            "splice" => {
                let start = arg_i32(0).clamp(0, len as i32) as usize;
                let del = arg_i32(1).clamp(0, len as i32 - start as i32) as usize;
                let mut removed_i = Vec::new();
                let mut removed_u = Vec::new();
                match self.objects.get_mut(handle)? {
                    LibwasmValue::I32Vec(v) => {
                        for _ in 0..del.min(v.len() - start) {
                            removed_i.push(v.remove(start));
                        }
                        for (i, a) in args.iter().skip(2).enumerate() {
                            v.insert((start + i).min(v.len()), a.to_i32());
                        }
                    }
                    LibwasmValue::U32Vec(v) => {
                        for _ in 0..del.min(v.len() - start) {
                            removed_u.push(v.remove(start));
                        }
                        for (i, a) in args.iter().skip(2).enumerate() {
                            v.insert((start + i).min(v.len()), a.to_u32());
                        }
                    }
                    _ => {}
                }
                Some(if is_i32 {
                    LibwasmValue::I32Vec(removed_i)
                } else {
                    LibwasmValue::U32Vec(removed_u)
                })
            }
            "slice" => {
                let start = arg_i32(0).clamp(0, len as i32) as usize;
                let end = if args.len() > 1 {
                    arg_i32(1).clamp(start as i32, len as i32) as usize
                } else {
                    len
                };
                let v = match self.objects.get(handle)? {
                    LibwasmValue::I32Vec(v) => LibwasmValue::I32Vec(v[start..end].to_vec()),
                    LibwasmValue::U32Vec(v) => LibwasmValue::U32Vec(v[start..end].to_vec()),
                    _ => LibwasmValue::None,
                };
                Some(v)
            }
            "at" => {
                let idx = arg_i32(0);
                let v = match self.objects.get(handle)? {
                    LibwasmValue::I32Vec(v) => {
                        v.get(idx.max(0) as usize).copied().map(LibwasmValue::I32)
                    }
                    LibwasmValue::U32Vec(v) => {
                        v.get(idx.max(0) as usize).copied().map(LibwasmValue::U32)
                    }
                    _ => None,
                };
                Some(v.unwrap_or(LibwasmValue::None))
            }
            "indexOf" => {
                let needle = args.first().map(|v| v.to_i64()).unwrap_or(0);
                let pos = match self.objects.get(handle)? {
                    LibwasmValue::I32Vec(v) => v.iter().position(|x| i64::from(*x) == needle),
                    LibwasmValue::U32Vec(v) => v.iter().position(|x| i64::from(*x) == needle),
                    _ => None,
                };
                Some(LibwasmValue::I32(pos.map(|p| p as i32).unwrap_or(-1)))
            }
            "includes" => {
                let needle = args.first().map(|v| v.to_i64()).unwrap_or(0);
                let has = match self.objects.get(handle)? {
                    LibwasmValue::I32Vec(v) => v.iter().any(|x| i64::from(*x) == needle),
                    LibwasmValue::U32Vec(v) => v.iter().any(|x| i64::from(*x) == needle),
                    _ => false,
                };
                Some(LibwasmValue::Bool(has))
            }
            "join" => {
                let sep = args
                    .first()
                    .and_then(|a| a.as_string().ok().map(String::from))
                    .unwrap_or_else(|| ",".into());
                let joined = match self.objects.get(handle)? {
                    LibwasmValue::I32Vec(v) => v
                        .iter()
                        .map(|x| x.to_string())
                        .collect::<Vec<_>>()
                        .join(&sep),
                    LibwasmValue::U32Vec(v) => v
                        .iter()
                        .map(|x| x.to_string())
                        .collect::<Vec<_>>()
                        .join(&sep),
                    _ => String::new(),
                };
                Some(LibwasmValue::String(joined))
            }
            _ => None,
        };
        Ok(out)
    }

    /// Map/JSON object methods (`set`/`get`/`has`/`delete`/`clear`/`keys`/
    /// `values`/`entries`) plus property-as-method get/set for plain objects.
    fn object_value_call(
        &mut self,
        handle: i32,
        method: &str,
        args: &[LibwasmValue],
    ) -> Result<Option<LibwasmValue>, String> {
        let key_of = |i: usize| -> Option<String> { args.get(i).map(|v| v.to_js_string()) };
        match method {
            "set" => {
                let key = key_of(0).ok_or("map.set key arg")?;
                let value = args.get(1).cloned().unwrap_or(LibwasmValue::None);
                self.object_set(handle, &key, value.clone())?;
                return Ok(Some(value));
            }
            "get" => {
                let key = key_of(0).ok_or("map.get key arg")?;
                return Ok(Some(
                    self.objects
                        .get(handle)?
                        .clone_prop(&key)
                        .unwrap_or(LibwasmValue::None),
                ));
            }
            "has" => {
                let key = key_of(0).ok_or("map.has key arg")?;
                return Ok(Some(LibwasmValue::Bool(
                    self.objects.get(handle)?.get_prop(&key).is_ok(),
                )));
            }
            "delete" => {
                let key = key_of(0).ok_or("map.delete key arg")?;
                let removed = match self.objects.get_mut(handle)? {
                    LibwasmValue::Object { props, .. } => props.remove(&key).is_some(),
                    _ => false,
                };
                return Ok(Some(LibwasmValue::Bool(removed)));
            }
            "clear" => {
                if let LibwasmValue::Object { props, .. } = self.objects.get_mut(handle)? {
                    props.clear();
                }
                return Ok(Some(LibwasmValue::None));
            }
            "keys" | "values" | "entries" => {
                let props = match self.objects.get(handle)? {
                    LibwasmValue::Object { props, .. } => props,
                    _ => return Ok(Some(LibwasmValue::None)),
                };
                let mut keys: Vec<&String> = props.keys().collect();
                keys.sort();
                let items: Vec<LibwasmValue> = match method {
                    "keys" => keys
                        .iter()
                        .map(|k| LibwasmValue::String((*k).clone()))
                        .collect(),
                    "values" => keys.iter().map(|k| props[*k].clone()).collect(),
                    _ => keys
                        .iter()
                        .map(|k| {
                            array_object(vec![
                                LibwasmValue::String((*k).clone()),
                                props[*k].clone(),
                            ])
                        })
                        .collect(),
                };
                return Ok(Some(array_object(items)));
            }
            "forEach" => return Ok(Some(LibwasmValue::None)),
            "toString" => return Ok(Some(LibwasmValue::String("[object Object]".into()))),
            _ => {}
        }
        // Property-as-method fallback: `obj.field` arrives as a zero-arg call
        // when the binding spells it as a call; `obj.field(v)` is a setter.
        let is_prop = matches!(
            self.objects.get(handle),
            Ok(LibwasmValue::Object { props, .. }) if props.contains_key(method)
        );
        if args.is_empty() && is_prop {
            return Ok(Some(self.objects.get(handle)?.clone_prop(method)?));
        }
        if args.len() == 1 {
            self.object_set(handle, method, args[0].clone())?;
            return Ok(Some(args[0].clone()));
        }
        Ok(None)
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

    fn ensure_pglite_factory(&mut self) -> Result<i32, LodashError> {
        if let Some(h) = self.pglite_handle {
            return Ok(h);
        }
        let h = self
            .intern_value(LibwasmValue::empty(ObjectKind::StoreFactory))
            .map_err(LodashError::Thrown)?;
        self.pglite_handle = Some(h);
        Ok(h)
    }

    fn intern_store_uuid(&mut self, uuid: g6b_pglite::StoreUuid) -> Result<i32, LodashError> {
        let mut props = std::collections::HashMap::new();
        props.insert("uuid".into(), LibwasmValue::String(uuid.hyphenated()));
        self.intern_value(LibwasmValue::Object {
            kind: ObjectKind::Store,
            props,
        })
        .map_err(LodashError::Thrown)
    }

    fn object_kind(&self, handle: i32) -> Option<ObjectKind> {
        match self.get_object(handle).ok()? {
            LibwasmValue::Object { kind, .. } => Some(*kind),
            _ => None,
        }
    }

    fn store_uuid_of(&self, handle: i32) -> Result<g6b_pglite::StoreUuid, LodashError> {
        match self.get_object(handle) {
            Ok(LibwasmValue::Object {
                kind: ObjectKind::Store,
                props,
            }) => {
                let s = match props.get("uuid") {
                    Some(LibwasmValue::String(s)) => s.clone(),
                    _ => return Err(LodashError::UnsupportedMethod("store".into())),
                };
                g6b_pglite::StoreUuid::parse(&s).map_err(|e| LodashError::Thrown(e.to_string()))
            }
            _ => Err(LodashError::UnsupportedMethod("store".into())),
        }
    }

    fn store_reg(&mut self) -> Result<&mut g6b_pglite::StoreRegistry, LodashError> {
        self.store
            .as_deref_mut()
            .ok_or_else(|| LodashError::EvalRefused("window.pglite".into()))
    }

    fn param_js_str(params: &[LodashParam], i: usize) -> Option<String> {
        match params.get(i) {
            Some(LodashParam::Value(JsValue::Str(s))) => Some(s.clone()),
            Some(LodashParam::Value(JsValue::Undefined | JsValue::Null)) => None,
            Some(LodashParam::Value(v)) => Some(v.to_js_string()),
            _ => None,
        }
    }

    fn json_result(j: Json) -> JsValue {
        JsValue::Str(stringify_json(&j))
    }

    fn store_err(e: g6b_pglite::StoreError) -> JsValue {
        Self::json_result(e.to_json())
    }

    fn store_query_result(r: Result<g6b_pglite::QueryResult, g6b_pglite::StoreError>) -> JsValue {
        match r {
            Ok(q) => Self::json_result(q.to_json()),
            Err(e) => Self::store_err(e),
        }
    }

    fn open_store(&mut self, data_dir: Option<&str>) -> Result<JsValue, LodashError> {
        let opened = match data_dir {
            None | Some("") => self.store_reg()?.open_purpose("registry"),
            Some(s) => self.store_reg()?.open(s),
        };
        match opened {
            Ok(u) => Ok(JsValue::Handle(self.intern_store_uuid(u)?)),
            Err(e) => Ok(Self::store_err(e)),
        }
    }

    fn factory_attempt(&mut self, params: &[LodashParam]) -> Result<JsValue, LodashError> {
        const METHODS: &[&str] = &[
            "query",
            "queryAsync",
            "exec",
            "begin",
            "commit",
            "rollback",
            "close",
            "waitReady",
            "dump",
            "load",
            "stat",
            "statAsync",
            "listen",
            "unlisten",
            "notifies",
            "export",
            "sql",
            "transaction",
        ];
        let first = Self::param_js_str(params, 0);
        let method = first.as_deref();
        if let Some(m) = method.filter(|m| {
            METHODS.contains(m)
                && (params.len() > 1
                    || matches!(
                        *m,
                        "begin"
                            | "commit"
                            | "rollback"
                            | "close"
                            | "waitReady"
                            | "dump"
                            | "stat"
                            | "statAsync"
                            | "notifies"
                    ))
        }) {
            let opened = self.open_store(None)?;
            let JsValue::Handle(h) = opened else {
                return Ok(opened);
            };
            return self.store_method(h, m, &params[1..]);
        }
        self.open_store(method)
    }

    fn store_method(
        &mut self,
        handle: i32,
        method: &str,
        params: &[LodashParam],
    ) -> Result<JsValue, LodashError> {
        let uuid = self.store_uuid_of(handle)?;
        Ok(match method {
            "query" | "queryAsync" => {
                let sql = Self::param_js_str(params, 0).unwrap_or_default();
                let raw = Self::param_js_str(params, 1).unwrap_or_else(|| "[]".into());
                let parsed = match parse_json(&raw) {
                    Ok(v) => v,
                    Err(e) => return Ok(Self::store_err(g6b_pglite::StoreError::syntax(e))),
                };
                let binds = match g6b_pglite::params_from_json(&parsed) {
                    Ok(b) => b,
                    Err(e) => return Ok(Self::store_err(e)),
                };
                Self::store_query_result(self.store_reg()?.query(uuid, &sql, &binds))
            }
            "exec" => {
                let sql = Self::param_js_str(params, 0).unwrap_or_default();
                Self::store_query_result(self.store_reg()?.exec(uuid, &sql))
            }
            "begin" => Self::store_query_result(self.store_reg()?.begin(uuid)),
            "commit" => Self::store_query_result(self.store_reg()?.commit(uuid)),
            "rollback" => Self::store_query_result(self.store_reg()?.rollback(uuid)),
            "close" => match self.store_reg()?.close(uuid) {
                Ok(()) => Self::store_query_result(Ok(g6b_pglite::QueryResult::empty())),
                Err(e) => Self::store_err(e),
            },
            "waitReady" | "stat" | "statAsync" => match self.store_reg()?.stat(uuid) {
                Ok(j) => Self::json_result(j),
                Err(e) => Self::store_err(e),
            },
            "dump" => match self.store_reg()?.dump(uuid) {
                Ok(j) => Self::json_result(j),
                Err(e) => Self::store_err(e),
            },
            "load" => {
                let raw = Self::param_js_str(params, 0).unwrap_or_else(|| "null".into());
                let blob = match parse_json(&raw) {
                    Ok(v) => v,
                    Err(e) => return Ok(Self::store_err(g6b_pglite::StoreError::syntax(e))),
                };
                match self.store_reg()?.load(uuid, &blob) {
                    Ok(()) => Self::store_query_result(Ok(g6b_pglite::QueryResult::empty())),
                    Err(e) => Self::store_err(e),
                }
            }
            "listen" => {
                let ch = Self::param_js_str(params, 0).unwrap_or_default();
                Self::store_query_result(self.store_reg()?.listen(uuid, &ch))
            }
            "unlisten" => {
                let ch = Self::param_js_str(params, 0);
                Self::store_query_result(self.store_reg()?.unlisten(uuid, ch.as_deref()))
            }
            "notifies" => match self.store_reg()?.notifies(uuid) {
                Ok(j) => Self::json_result(j),
                Err(e) => Self::store_err(e),
            },
            "export" => {
                let volume = Self::param_js_str(params, 0).unwrap_or_default();
                let rel = Self::param_js_str(params, 1);
                match self.store_reg()?.export(uuid, &volume, rel.as_deref()) {
                    Ok(()) => Self::json_result({
                        let mut m = BTreeMap::new();
                        m.insert("ok".into(), Json::Bool(true));
                        m.insert("uuid".into(), Json::Str(uuid.to_string()));
                        Json::Obj(m)
                    }),
                    Err(e) => Self::store_err(e),
                }
            }
            "sql" | "transaction" => {
                Self::store_err(g6b_pglite::StoreError::NotImplemented("callback"))
            }
            _ => return Err(LodashError::UnsupportedMethod(method.into())),
        })
    }

    fn acc_store_handle(acc: &JsValue, op: &str) -> Result<i32, LodashError> {
        match acc {
            JsValue::Handle(h) if *h != 0 => Ok(*h),
            _ => Err(LodashError::UnsupportedMethod(op.into())),
        }
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
                // svelte-d callTs seeds with eval("window.__svelteD.ts").
                // That is the JS export registry, not a general evaluator.
                if text == "window.__svelteD.ts"
                    || text == "window.__svelteD"
                    || text == "__svelteD.ts"
                {
                    self.js_exports_js_value()
                } else {
                    return Err(format!(
                        "WASM lodash refuses an eval seed {text:?}: no host JS evaluator"
                    ));
                }
            }
            LdexecInit::Str { text, eval: false } => JsValue::Str(text.clone()),
            LdexecInit::Long(v) => JsValue::Num(*v as f64),
        };
        let commands = g6b_js::lodash_parse(call.commands).map_err(|e| e.to_string())?;
        if let Some((path, args)) = invoke_export(&commands) {
            if let Some(kind) = self.js_exports.lookup(&path) {
                let value = self.call_js_export(kind, &args)?;
                self.diagnostics.push(format!("WASM-JS-EXPORT {path}"));
                return Ok(value);
            }
        }
        let value = g6b_js::lodash_execute_host(init, &commands, None, Some(self))
            .map_err(|e| e.to_string())?;
        self.diagnostics
            .push(format!("WASM-LODASH {} steps", commands.len()));
        Ok(value)
    }

    fn js_exports_js_value(&self) -> JsValue {
        let nested = self.js_exports.as_nested_strings();
        let mut root = BTreeMap::new();
        for (mod_name, fns) in nested {
            let mut inner = BTreeMap::new();
            for (name, path) in fns {
                inner.insert(name, JsValue::Str(path));
            }
            root.insert(mod_name, JsValue::Obj(inner));
        }
        JsValue::Obj(root)
    }

    fn call_js_export(
        &mut self,
        kind: g6b_wasm::JsExportKind,
        args: &[JsValue],
    ) -> Result<JsValue, String> {
        match kind {
            g6b_wasm::JsExportKind::FetchBios => {
                let url = args.first().map(|v| v.to_js_string()).unwrap_or_default();
                let handle = self.fetch(&url)?;
                Ok(JsValue::Handle(handle))
            }
            g6b_wasm::JsExportKind::HolycEval => {
                let line = args.first().map(|v| v.to_js_string()).unwrap_or_default();
                self.diagnostics.push(format!("WASM-JS-HOLYC {line}"));
                if g6b_hw::is_hw_invoke(&line) {
                    let hw = self.hw_session()?;
                    return Ok(JsValue::Str(g6b_hw::eval_instant(hw, &line)));
                }
                Ok(JsValue::Str(String::new()))
            }
            g6b_wasm::JsExportKind::RegisterEndpoint => {
                let path = args.first().map(|v| v.to_js_string()).unwrap_or_default();
                let method = args
                    .get(1)
                    .map(|v| v.to_js_string())
                    .unwrap_or_else(|| "GET".into());
                self.diagnostics
                    .push(format!("WASM-JS-REGISTER {method} {path}"));
                Ok(JsValue::Undefined)
            }
            g6b_wasm::JsExportKind::HwStat => self.hw_js_instant("hwStat", args),
            g6b_wasm::JsExportKind::HwListen => self.hw_js_instant("hwListen", args),
            g6b_wasm::JsExportKind::HwWake => self.hw_js_await("hwWake", args),
            g6b_wasm::JsExportKind::HwCable => self.hw_js_await("hwCable", args),
            g6b_wasm::JsExportKind::HwConfig => self.hw_js_await("hwConfig", args),
        }
    }

    fn hw_js_args(args: &[JsValue]) -> Vec<String> {
        args.iter().map(|v| v.to_js_string()).collect()
    }

    fn hw_session(&mut self) -> Result<&mut g6b_hw::HwSession, String> {
        self.hw
            .as_deref_mut()
            .ok_or_else(|| "hw session unavailable during _start".into())
    }

    /// Intern `platform` on the shell window. Never an iframe global.
    fn ensure_platform_global(&mut self) -> Result<i32, String> {
        if let Some(h) = self.platform_handle {
            return Ok(h);
        }
        if let Some(w) = self.window_handle {
            if let Ok(LibwasmValue::I32(h)) =
                self.get_object(w).and_then(|v| v.clone_prop("platform"))
            {
                self.platform_handle = Some(h);
                return Ok(h);
            }
        }
        let h = self.intern_value(LibwasmValue::empty(ObjectKind::Platform))?;
        self.platform_handle = Some(h);
        if let Some(w) = self.window_handle {
            if let Ok(obj) = self.objects.get_mut(w) {
                let _ = obj.set_prop("platform", LibwasmValue::I32(h));
            }
        }
        self.diagnostics
            .push(format!("WASM-JS-GLOBAL platform -> {h}"));
        Ok(h)
    }

    /// Intern `platform.hw` without starting the listen worker.
    fn ensure_hw_global(&mut self) -> Result<i32, String> {
        if let Some(h) = self.hw_handle {
            return Ok(h);
        }
        let platform = self.ensure_platform_global()?;
        if let Ok(LibwasmValue::I32(h)) = self.get_object(platform).and_then(|v| v.clone_prop("hw"))
        {
            self.hw_handle = Some(h);
            return Ok(h);
        }
        let h = self.intern_value(
            LibwasmValue::empty(ObjectKind::Hw)
                .with_prop("__role", LibwasmValue::String("root".into())),
        )?;
        self.hw_handle = Some(h);
        if let Ok(obj) = self.objects.get_mut(platform) {
            let _ = obj.set_prop("hw", LibwasmValue::I32(h));
        }
        self.diagnostics
            .push(format!("WASM-JS-GLOBAL platform.hw -> {h}"));
        Ok(h)
    }

    fn ensure_hw_child(&mut self, role: &str) -> Result<i32, String> {
        let existing = match role {
            "net" => self.hw_net_handle,
            "display" => self.hw_display_handle,
            "tcp" => self.hw_tcp_handle,
            "udp" => self.hw_udp_handle,
            "gl" => self.hw_gl_handle,
            other => return Err(format!("unknown hw child {other}")),
        };
        if let Some(h) = existing {
            return Ok(h);
        }
        let parent = if role == "tcp" || role == "udp" {
            self.ensure_hw_child("net")?
        } else if role == "gl" {
            self.ensure_hw_child("display")?
        } else {
            self.ensure_hw_global()?
        };
        if let Ok(LibwasmValue::I32(h)) = self.get_object(parent).and_then(|v| v.clone_prop(role)) {
            match role {
                "net" => self.hw_net_handle = Some(h),
                "display" => self.hw_display_handle = Some(h),
                "tcp" => self.hw_tcp_handle = Some(h),
                "udp" => self.hw_udp_handle = Some(h),
                "gl" => self.hw_gl_handle = Some(h),
                _ => {}
            }
            return Ok(h);
        }
        let h = self.intern_value(
            LibwasmValue::empty(ObjectKind::Hw)
                .with_prop("__role", LibwasmValue::String(role.into())),
        )?;
        match role {
            "net" => self.hw_net_handle = Some(h),
            "display" => self.hw_display_handle = Some(h),
            "tcp" => self.hw_tcp_handle = Some(h),
            "udp" => self.hw_udp_handle = Some(h),
            "gl" => self.hw_gl_handle = Some(h),
            _ => {}
        }
        if let Ok(obj) = self.objects.get_mut(parent) {
            let _ = obj.set_prop(role, LibwasmValue::I32(h));
        }
        Ok(h)
    }

    fn hw_role(value: &LibwasmValue) -> &'static str {
        match value.clone_prop("__role") {
            Ok(LibwasmValue::String(s)) if s == "net" => "net",
            Ok(LibwasmValue::String(s)) if s == "display" => "display",
            Ok(LibwasmValue::String(s)) if s == "tcp" => "tcp",
            Ok(LibwasmValue::String(s)) if s == "udp" => "udp",
            Ok(LibwasmValue::String(s)) if s == "gl" => "gl",
            _ => "root",
        }
    }

    fn hw_live_str(&self, role: &str, name: &str) -> Option<LibwasmValue> {
        let spec = g6b_hw::HwSpec::from_board(self.spec);
        let (listening, idle, nat, phase, cable, src, queued, line, env, scanout) =
            if let Some(s) = self.hw.as_deref() {
                (
                    s.listening(),
                    s.idle(),
                    s.mode().as_str().to_string(),
                    s.phase().as_str().to_string(),
                    s.cable().as_str().to_string(),
                    s.status_line(),
                    s.queued() as u32,
                    s.status_line(),
                    s.env_untouched(),
                    s.scanout().to_string(),
                )
            } else {
                (
                    false,
                    true,
                    "minimal".into(),
                    "idle".into(),
                    "unplugged".into(),
                    "hw nat=minimal phase=idle cable=unplugged src=idle q=0 env=untouched".into(),
                    0,
                    "hw nat=minimal phase=idle cable=unplugged src=idle q=0 env=untouched".into(),
                    true,
                    "vga".into(),
                )
            };
        let net = if let Some(s) = self.hw.as_deref() {
            s.spec.primary_net().map(|a| {
                let cfg = s.device(&a.id).cloned().unwrap_or_default();
                (
                    a.id.clone(),
                    a.kind.as_str().to_string(),
                    cfg.addressing.as_str().to_string(),
                    cfg.ip,
                )
            })
        } else {
            spec.primary_net().map(|a| {
                (
                    a.id.clone(),
                    a.kind.as_str().to_string(),
                    "nat".into(),
                    String::new(),
                )
            })
        };
        let disp = if let Some(s) = self.hw.as_deref() {
            s.spec
                .adapters
                .iter()
                .find(|a| a.class == g6b_hw::AdapterClass::Display)
                .map(|a| (a.id.clone(), a.kind.as_str().to_string()))
        } else {
            spec.adapters
                .iter()
                .find(|a| a.class == g6b_hw::AdapterClass::Display)
                .map(|a| (a.id.clone(), a.kind.as_str().to_string()))
        };
        match (role, name) {
            ("root", "nat") => Some(LibwasmValue::String(nat)),
            ("root", "phase") => Some(LibwasmValue::String(phase)),
            ("root", "cable") => Some(LibwasmValue::String(cable)),
            ("root", "src") => Some(LibwasmValue::String(src)),
            ("root", "line") => Some(LibwasmValue::String(line)),
            ("root", "listening") => Some(LibwasmValue::Bool(listening)),
            ("root", "idle") => Some(LibwasmValue::Bool(idle)),
            ("root", "env_untouched") => Some(LibwasmValue::Bool(env)),
            ("root", "host_adapter") => Some(LibwasmValue::String(
                self.hw
                    .as_deref()
                    .map(|s| s.host_adapter().to_string())
                    .unwrap_or_default(),
            )),
            ("root", "socks") => Some(LibwasmValue::String(
                self.hw
                    .as_deref()
                    .map(|s| s.socks_json())
                    .unwrap_or_else(|| "[]".into()),
            )),
            ("root", "queued") => Some(LibwasmValue::U32(queued)),
            ("root", "stat") => Some(LibwasmValue::String(if let Some(s) = self.hw.as_deref() {
                s.stat_json()
            } else {
                "{\"ready\":true,\"listening\":false,\"env_untouched\":true}".into()
            })),
            ("net", "id") => Some(LibwasmValue::String(
                net.as_ref().map(|n| n.0.clone()).unwrap_or_default(),
            )),
            ("net", "kind") => Some(LibwasmValue::String(
                net.as_ref().map(|n| n.1.clone()).unwrap_or_default(),
            )),
            ("net", "addressing") => Some(LibwasmValue::String(
                net.as_ref()
                    .map(|n| n.2.clone())
                    .unwrap_or_else(|| "nat".into()),
            )),
            ("net", "ip") => Some(LibwasmValue::String(
                net.as_ref().map(|n| n.3.clone()).unwrap_or_default(),
            )),
            ("net", "addr") => Some(LibwasmValue::String(
                self.hw
                    .as_deref()
                    .and_then(|s| s.spec.primary_net().and_then(|a| s.device(&a.id)))
                    .map(|c| c.inet.addr.clone())
                    .unwrap_or_default(),
            )),
            ("net", "prefix") => Some(LibwasmValue::U32(
                self.hw
                    .as_deref()
                    .and_then(|s| s.spec.primary_net().and_then(|a| s.device(&a.id)))
                    .map(|c| u32::from(c.inet.prefix))
                    .unwrap_or(24),
            )),
            ("net", "gateway") => Some(LibwasmValue::String(
                self.hw
                    .as_deref()
                    .and_then(|s| s.spec.primary_net().and_then(|a| s.device(&a.id)))
                    .map(|c| c.inet.gateway.clone())
                    .unwrap_or_default(),
            )),
            ("net", "mtu") => Some(LibwasmValue::U32(
                self.hw
                    .as_deref()
                    .and_then(|s| s.spec.primary_net().and_then(|a| s.device(&a.id)))
                    .map(|c| u32::from(c.inet.mtu))
                    .unwrap_or(1500),
            )),
            ("net", "link") => Some(LibwasmValue::String(
                self.hw
                    .as_deref()
                    .and_then(|s| s.spec.primary_net().and_then(|a| s.device(&a.id)))
                    .map(|c| c.inet.link.as_str().to_string())
                    .unwrap_or_else(|| "down".into()),
            )),
            ("tcp", "enabled") => Some(LibwasmValue::Bool(
                self.hw
                    .as_deref()
                    .and_then(|s| s.spec.primary_net().and_then(|a| s.device(&a.id)))
                    .map(|c| c.inet.tcp.enabled)
                    .unwrap_or(true),
            )),
            ("udp", "enabled") => Some(LibwasmValue::Bool(
                self.hw
                    .as_deref()
                    .and_then(|s| s.spec.primary_net().and_then(|a| s.device(&a.id)))
                    .map(|c| c.inet.udp.enabled)
                    .unwrap_or(true),
            )),
            ("display", "id") => Some(LibwasmValue::String(
                self.hw
                    .as_deref()
                    .map(|s| s.disp().winner_id.clone())
                    .or_else(|| disp.as_ref().map(|d| d.0.clone()))
                    .unwrap_or_default(),
            )),
            ("display", "kind") => Some(LibwasmValue::String(
                self.hw
                    .as_deref()
                    .map(|s| s.disp().winner_kind.clone())
                    .or_else(|| disp.as_ref().map(|d| d.1.clone()))
                    .unwrap_or_else(|| "vga".into()),
            )),
            ("display", "surface") => Some(LibwasmValue::String(scanout)),
            ("display", "probed") => Some(LibwasmValue::Bool(
                self.hw.as_deref().map(|s| s.disp().probed).unwrap_or(false),
            )),
            ("display", "present") => Some(LibwasmValue::String(
                self.hw
                    .as_deref()
                    .map(|s| s.disp().present.as_str().to_string())
                    .unwrap_or_else(|| "none".into()),
            )),
            ("display", "vendor") => Some(LibwasmValue::String(
                self.hw
                    .as_deref()
                    .map(|s| s.disp().vendor.clone())
                    .unwrap_or_default(),
            )),
            ("display", "link") => Some(LibwasmValue::String(
                self.hw
                    .as_deref()
                    .map(|s| s.disp().link.as_str().to_string())
                    .unwrap_or_else(|| "down".into()),
            )),
            ("display", "w") => Some(LibwasmValue::U32(
                self.hw.as_deref().map(|s| s.disp().w).unwrap_or(640),
            )),
            ("display", "h") => Some(LibwasmValue::U32(
                self.hw.as_deref().map(|s| s.disp().h).unwrap_or(480),
            )),
            ("gl", "enabled") => Some(LibwasmValue::Bool(
                self.hw
                    .as_deref()
                    .map(|s| s.disp().gl != g6b_hw::GlMode::Off)
                    .unwrap_or(false),
            )),
            ("gl", "mode") => Some(LibwasmValue::String(
                self.hw
                    .as_deref()
                    .map(|s| s.disp().gl.as_str().to_string())
                    .unwrap_or_else(|| "off".into()),
            )),
            _ => None,
        }
    }

    /// HolyC-style instant snapshot (status getters).
    fn hw_js_instant(&mut self, name: &str, args: &[JsValue]) -> Result<JsValue, String> {
        let argv = Self::hw_js_args(args);
        let refs: Vec<&str> = argv.iter().map(String::as_str).collect();
        let hw = self.hw_session()?;
        let body = g6b_hw::call_instant(hw, name, &refs);
        self.diagnostics.push(format!("WASM-JS-HW {name}"));
        Ok(JsValue::Str(body))
    }

    /// JS/wasm await: throw [`g6b_hw::HwError`] without exiting the worker.
    fn hw_js_await(&mut self, name: &str, args: &[JsValue]) -> Result<JsValue, String> {
        let argv = Self::hw_js_args(args);
        let refs: Vec<&str> = argv.iter().map(String::as_str).collect();
        let hw = self.hw_session()?;
        match g6b_hw::call(hw, name, &refs) {
            Ok(body) => {
                self.record_await_from_string(body.clone(), false);
                self.diagnostics.push(format!("WASM-JS-HW {name}"));
                Ok(JsValue::Str(body))
            }
            Err(e) => {
                self.record_await_from_string(e.message.clone(), true);
                self.diagnostics.push(format!("WASM-JS-HW-THROW {name}"));
                Err(e.message)
            }
        }
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

impl HostDispatch for KernelHost<'_> {
    fn intern_name(&mut self, name: &str) -> Result<JsValue, LodashError> {
        match name {
            "window.pglite" | "pglite" => {
                if !self.spec.kernel.store.enable {
                    return Err(LodashError::EvalRefused(name.into()));
                }
                Ok(JsValue::Handle(self.ensure_pglite_factory()?))
            }
            "window.platform" | "platform" => Ok(JsValue::Handle(
                self.ensure_platform_global().map_err(LodashError::Thrown)?,
            )),
            "window.hw" | "hw" => Err(LodashError::EvalRefused(
                "hw is platform.hw, not a window global".into(),
            )),
            "moment" | "window.moment" => Err(LodashError::UnsupportedMethod(name.into())),
            other => Err(LodashError::EvalRefused(other.into())),
        }
    }

    fn attempt(&mut self, acc: &JsValue, params: &[LodashParam]) -> Result<JsValue, LodashError> {
        let handle = Self::acc_store_handle(acc, "attempt")?;
        match self.object_kind(handle) {
            Some(ObjectKind::StoreFactory) => self.factory_attempt(params),
            Some(ObjectKind::Store) => {
                let method = match params.first() {
                    Some(LodashParam::Value(JsValue::Str(s))) => s.clone(),
                    _ => return Err(LodashError::UnsupportedMethod("attempt".into())),
                };
                self.store_method(handle, &method, &params[1..])
            }
            _ => Err(LodashError::UnsupportedMethod("attempt".into())),
        }
    }

    fn invoke(
        &mut self,
        acc: &JsValue,
        path: &str,
        params: &[LodashParam],
    ) -> Result<JsValue, LodashError> {
        let handle = Self::acc_store_handle(acc, "invoke")?;
        match self.object_kind(handle) {
            Some(ObjectKind::Store) => self.store_method(handle, path, params),
            _ => Err(LodashError::UnsupportedMethod("invoke".into())),
        }
    }
}

/// Drive a libwasm module's `_start` against `host`. Mirrors
/// `g6b_wasm::run_start`: when `asyncify_*` exports are present, each
/// `libwasm_await__void` Sleeping is settled (`wrapExportFn`) then rewound.
/// Scratch lives after live linear memory (not at `__heap_base`).
fn run_libwasm_start(
    module: &g6b_wasm::Module,
    host: &mut KernelHost<'_>,
) -> Result<g6b_wasm::Module, String> {
    const ASYNCIFY_STEP_LIMIT: u32 = 256;

    let idx = module
        .exports
        .iter()
        .find(|e| e.name == "_start" && e.kind == 0)
        .map(|e| e.idx)
        .ok_or("no _start export")?;
    let typeidx = {
        let i = idx as usize;
        if i < module.imports.len() {
            module.imports[i].typeidx
        } else {
            *module
                .func_types
                .get(i - module.imports.len())
                .ok_or("_start function index out of range")?
        }
    };
    let ty = module
        .types
        .get(typeidx as usize)
        .ok_or("_start has no type")?;
    let heap_base = module
        .exports
        .iter()
        .find(|e| e.name == "__heap_base" && e.kind == 3)
        .and_then(|e| module.globals.get(e.idx as usize))
        .map(|g| g.value as i32)
        .unwrap_or(0);
    if !(ty.params.is_empty() || ty.params == [g6b_wasm::ValType::I32]) || !ty.results.is_empty() {
        return Err("_start must have signature () -> () or (i32) -> ()".into());
    }
    let args: Vec<i32> = if ty.params == [g6b_wasm::ValType::I32] {
        vec![heap_base]
    } else {
        vec![]
    };

    let mut m = module.clone();
    if let Ok(a) = g6b_wasm::Asyncify::new(&m) {
        let (data, stack_end) = g6b_wasm::reserve_asyncify_scratch(&mut m, heap_base as u32);
        let mut step = a.step(&mut m, idx, &args, data, stack_end, host)?;
        for _ in 0..ASYNCIFY_STEP_LIMIT {
            match step {
                g6b_wasm::Step::Done(_) => return Ok(m),
                g6b_wasm::Step::Sleeping { slot, .. } => {
                    host.resolve_slot(slot)?;
                    step = match a.resume(&mut m, idx, &args, data, stack_end, host) {
                        Ok(s) => s,
                        Err(e) if g6b_wasm::is_unhandled_d_abort(&e) => return Ok(m),
                        Err(e) => return Err(e),
                    };
                }
            }
        }
        return Err("asyncify step limit".into());
    }

    g6b_wasm::run_with_fuel_mut(&mut m, idx, &args, host, g6b_wasm::MAX_FUEL)?;
    Ok(m)
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

    fn add_string(&mut self, value: &str) -> Result<i32, String> {
        let short: String = value.chars().take(120).collect();
        self.diagnostics.push(format!("WASM-ADD-STRING {short:?}"));
        self.objects.add(LibwasmValue::String(value.to_string()))
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
        let fetched = {
            let mut port = crate::browser::RouterPort {
                router: self.router,
                spec: self.spec,
                store: match &mut self.store {
                    Some(s) => Some(&mut **s),
                    None => None,
                },
            };
            g6b_wasm::KernelPort::fetch_text(&mut port, url)
        };
        let (status, body) = match fetched {
            Ok(v) => v,
            Err(e) => {
                self.diagnostics.push(format!("WASM-SKIP-FETCH {url}: {e}"));
                // Never return handle 0 as a "string": the LDC cell treats 0 as a
                // pointer and walks off the wasm memory. An interned empty string
                // is a skipped read, not a successful kernel GET.
                return self.intern_value(LibwasmValue::String(String::new()));
            }
        };
        let path = url.split(['?', '#']).next().unwrap_or(url);
        let path = match path {
            "/bios/cpu" => "/bios/menu/cpu",
            "/bios/uncore" => "/bios/menu/uncore",
            other => other,
        };
        self.diagnostics.push(format!("WASM-FETCH {url} {status}"));
        if status != 200 {
            let msg = format!("WASM fetch {url}: HTTP {status}");
            return self.intern_value(LibwasmValue::Error(msg));
        }
        paint_response(self.dom, path, &body)?;
        // The generated cell iterates a menu fetch body as a top-level JSON
        // array of `{id,label,value,writable}` rows; the router's envelope is
        // `{id,title,items:[...]}`. Hand the guest the row array while the
        // DOM paint above consumes the full envelope.
        let is_menu = g6b_ui::face_for_fetch(path)
            .map(|f| f.kind == g6b_ui::Kind::Menu)
            .unwrap_or(false);
        let guest_body = if is_menu {
            g6b_spec::parse_json(&body)
                .ok()
                .and_then(|j| match j.get("items") {
                    g6b_spec::Json::Arr(_) => Some(g6b_spec::stringify_json(j.get("items"))),
                    _ => None,
                })
                .unwrap_or(body)
        } else {
            body
        };
        self.intern_value(LibwasmValue::String(guest_body))
    }

    fn create_element(&mut self, tag: &str) -> Result<i32, String> {
        if self.handles.len() + 2 >= g6b_wasm::MAX_OBJECTS {
            return Err("WASM DOM handle budget exceeded".into());
        }
        let idx = self.handles.len() as i32;
        self.handles.push(Node::elem(tag));
        let h = idx + 2;
        self.diagnostics
            .push(format!("WASM-CREATE-ELEMENT {tag} -> {h}"));
        Ok(h)
    }

    fn append_child(&mut self, parent: i32, child: i32) -> Result<(), String> {
        self.diagnostics
            .push(format!("WASM-APPEND p={parent} c={child}"));
        self.place_child(parent, child, None)?;
        Ok(())
    }

    fn set_property(&mut self, obj: i32, key: &str, value: &str) -> Result<(), String> {
        // The reference host refuses innerHTML/outerHTML/src/onclick and
        // proto-polluting keys; the kernel lane fails the same way so a
        // guest cannot smuggle markup or handlers into the staging DOM.
        if matches!(
            key,
            "innerHTML" | "outerHTML" | "onclick" | "__proto__" | "constructor"
        ) {
            self.diagnostics
                .push(format!("WASM-SET-PROPERTY-REFUSED {key}"));
            return Err(format!("WASM unsupported DOM property: {key}"));
        }
        if key == "src" && local_src_url(value).is_none() {
            self.diagnostics
                .push("WASM-SET-PROPERTY-REFUSED src".into());
            return Err("WASM src must be a local /ui/ image path".into());
        }
        let n = self.node_mut(obj)?;
        match key {
            "innerText" | "textContent" => n.set_inner_text(value),
            "className" => {
                n.set_attribute("class", value)?;
            }
            "id" => {
                n.set_attribute("id", value)?;
            }
            "src" => {
                n.set_attribute("src", value)?;
            }
            "style" => {
                // Same write as `element.style.cssText` / style_call("cssText"):
                // one style attribute, later CSS invalidation reads it.
                n.set_attribute("style", value)?;
            }
            _ => {
                n.set_attribute(key, value)?;
            }
        }
        Ok(())
    }

    fn libwasm_await_void(&mut self, slot: i32) -> Result<(), String> {
        self.diagnostics
            .push(format!("WASM-AWAIT-VOID slot={slot}"));
        // Record the Promise handle. When asyncify exports are present,
        // `run_libwasm_start` Sleeping/resume (`wrapExportFn`); the
        // interpreter stop_rewinds on the replayed import.
        self.pending_slot = Some(slot);
        self.record_await(slot)
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

    fn libwasm_global(&mut self, name: &str) -> Result<i32, String> {
        if name == "pglite" {
            if !self.spec.kernel.store.enable {
                self.diagnostics
                    .push("WASM-JS-GLOBAL-UNAVAILABLE pglite".into());
                return Ok(0);
            }
            let h = self.ensure_pglite_factory().map_err(|e| e.to_string())?;
            self.diagnostics
                .push(format!("WASM-JS-GLOBAL pglite -> {h}"));
            return Ok(h);
        }
        if name == "hw" {
            self.diagnostics
                .push("WASM-JS-GLOBAL-UNAVAILABLE hw (use platform.hw)".into());
            return Ok(0);
        }
        if name == "platform" {
            let _ = self.ensure_js_globals();
            let h = self.ensure_platform_global()?;
            return Ok(h);
        }
        let (window, document, console) = self.ensure_js_globals()?;
        let handle = match name {
            "window" => window,
            "document" => document,
            "console" => console,
            _ => {
                self.diagnostics
                    .push(format!("WASM-JS-GLOBAL-UNAVAILABLE {name}"));
                return Ok(0);
            }
        };
        self.diagnostics
            .push(format!("WASM-JS-GLOBAL {name} -> {handle}"));
        Ok(handle)
    }

    fn get_root(&mut self) -> Result<i32, String> {
        // Handle 1 is the Spa mount `run_libwasm_start` placed under
        // `#libwasm-root`. Interning `#libwasm-root` itself would parent the
        // Svelte tree beside that mount (empty handle-1 div).
        Ok(1)
    }

    fn add_css(&mut self, css: &str) -> Result<i32, String> {
        let h = self.create_element("style")?;
        self.set_property(h, "type", "text/css")?;
        self.node_mut(h)?.set_inner_text(css);
        if let Some(head_path) = path_from_name(self.dom, "head") {
            let head = self.intern_session_node(head_path)?;
            self.place_child(head, h, None)?;
        } else {
            let doc = self.intern_session_node(Vec::new())?;
            self.place_child(doc, h, None)?;
        }
        self.diagnostics
            .push(format!("WASM-ADD-CSS {}b", css.len()));
        Ok(h)
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

    fn set_function(&mut self, name: &str, ctx: i32, ptr: i32) -> Result<(), String> {
        self.named_delegates.insert(name.to_string(), (ctx, ptr));
        self.diagnostics
            .push(format!("WASM-SET-FUNCTION {name} ctx={ctx} ptr={ptr}"));
        Ok(())
    }
    fn unset_function(&mut self, name: &str) -> Result<(), String> {
        self.named_delegates.remove(name);
        self.diagnostics.push(format!("WASM-UNSET-FUNCTION {name}"));
        Ok(())
    }
    fn get_function(&self, name: &str) -> Option<(i32, i32)> {
        self.named_delegates.get(name).copied()
    }

    fn set_event_handler(
        &mut self,
        handle: i32,
        prop: &str,
        defined: bool,
        ctx: i32,
        ptr: i32,
    ) -> Result<(), String> {
        let ty = event_type_from_handler_prop(prop).to_string();
        if defined {
            self.event_handlers
                .insert((handle, prop.to_string()), (ctx, ptr));
            let id = self.node(handle).ok().and_then(|n| n.id.clone());
            if let Some(id) = id {
                self.pending_event_delegates
                    .push((id.clone(), ty, ctx, ptr, false));
                self.diagnostics.push(format!(
                    "WASM-EVENT-HANDLER {id} {prop} ctx={ctx} ptr={ptr}"
                ));
            } else {
                self.diagnostics.push(format!(
                    "WASM-EVENT-HANDLER h={handle} {prop} ctx={ctx} ptr={ptr}"
                ));
            }
        } else {
            self.event_handlers.remove(&(handle, prop.to_string()));
            self.diagnostics
                .push(format!("WASM-EVENT-HANDLER-CLEAR h={handle} {prop}"));
        }
        Ok(())
    }

    fn get_event_handler(&self, handle: i32, prop: &str) -> Option<(i32, i32)> {
        self.event_handlers
            .get(&(handle, prop.to_string()))
            .copied()
    }

    fn set_timeout(&mut self, ctx: i32, ptr: i32, ms: i32) -> Result<i32, String> {
        let id = self.timers.set_timeout(ctx, ptr, ms, self.now_ns)?;
        self.diagnostics
            .push(format!("WASM-TIMER timeout id={id} ms={ms}"));
        Ok(id)
    }

    fn set_interval(&mut self, ctx: i32, ptr: i32, ms: i32) -> Result<i32, String> {
        let id = self.timers.set_interval(ctx, ptr, ms, self.now_ns)?;
        self.diagnostics
            .push(format!("WASM-TIMER interval id={id} ms={ms}"));
        Ok(id)
    }

    fn clear_timeout(&mut self, id: i32) -> Result<(), String> {
        self.timers.clear(id);
        Ok(())
    }

    fn request_animation_frame(&mut self, ctx: i32, ptr: i32) -> Result<i32, String> {
        let period = crate::timers::frame_period_ns(self.spec);
        let id = self
            .timers
            .request_animation_frame(ctx, ptr, self.now_ns, period)?;
        self.diagnostics.push(format!("WASM-TIMER raf id={id}"));
        Ok(id)
    }

    /// 1 so `if (libwasm_await_supported())` in App.ready runs. With
    /// asyncify exports the interpreter reports 1 from the exports.
    fn await_supported(&self) -> i32 {
        1
    }

    fn await_op(&mut self) -> Result<i32, String> {
        for (i, slot) in self.await_slots.iter_mut().enumerate() {
            if *slot == 0 {
                *slot = 1;
                self.diagnostics.push(format!("WASM-AWAIT pending {i}"));
                return Ok(i as i32);
            }
        }
        self.diagnostics.push("WASM-AWAIT-REJ full".into());
        Ok(-1)
    }

    fn throw_op(&mut self, slot: i32) -> Result<(), String> {
        let i = if slot < 0 {
            self.await_slots.iter().rposition(|&s| s == 1)
        } else {
            let u = slot as usize;
            (u < self.await_slots.len()).then_some(u)
        };
        let Some(i) = i else {
            self.diagnostics.push("WASM-THROW miss".into());
            return Ok(());
        };
        self.await_slots[i] = 3;
        self.diagnostics.push(format!("WASM-THROW {i}"));
        Ok(())
    }

    fn note_throw_stack(&mut self, frames: &[String]) {
        if frames.is_empty() {
            return;
        }
        self.diagnostics
            .push(format!("WASM-THROW-STACK {}", frames.join(" <- ")));
    }

    fn catch_op(&mut self, slot: i32) -> Result<i32, String> {
        let u = slot as usize;
        if u >= self.await_slots.len() {
            return Ok(0);
        }
        let rejected = i32::from(self.await_slots[u] == 3);
        self.diagnostics.push(format!("WASM-CATCH {u}={rejected}"));
        Ok(rejected)
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

    // ---- merged DOM/object handle space (B63) ----
    //
    // `1..OBJECT_BASE` are staging DOM handles; `>= OBJECT_BASE` are object
    // table entries. DOM nodes cross the ABI as `Object{kind:Element,
    // props:{"__dom":I32(h)}}` wrappers, with `__role` for classList/style/
    // dataset/childNodes proxies.

    fn get_libwasm_value(&self, handle: i32) -> Result<LibwasmValue, String> {
        if handle == 0 {
            return Ok(LibwasmValue::None);
        }
        if (1..g6b_wasm::OBJECT_BASE).contains(&handle) {
            return Ok(Self::dom_wrapper(handle));
        }
        self.objects.get(handle).cloned()
    }

    fn get_string(&self, handle: i32) -> Result<String, String> {
        if handle == 0 {
            return Ok(String::new());
        }
        if (1..g6b_wasm::OBJECT_BASE).contains(&handle) {
            return Ok(self.node(handle)?.inner_text());
        }
        self.objects.get(handle)?.as_string().map(String::from)
    }

    fn copy_object_ref(&mut self, handle: i32) -> Result<i32, String> {
        if handle < g6b_wasm::OBJECT_BASE {
            // DOM handles are not refcounted; identity copy.
            return Ok(handle);
        }
        self.objects.copy_ref(handle)
    }

    fn remove_object(&mut self, handle: i32) -> Result<(), String> {
        if handle < g6b_wasm::OBJECT_BASE {
            // A guest `JsHandle` drop of a DOM handle (including the root
            // mount) is a no-op: staging DOM nodes are not refcounted.
            self.diagnostics
                .push(format!("WASM-REMOVE-OBJECT-DOM {handle}"));
            return Ok(());
        }
        self.objects.remove_ref(handle).map(|_| ())
    }

    fn object_getter(&mut self, handle: i32, name: &str) -> Result<LibwasmValue, String> {
        match self.resolve_receiver(handle)? {
            LibwasmReceiver::Dom(h) => self.dom_getter(h, name),
            LibwasmReceiver::Proxy(h, role) => self.dom_proxy_getter(h, &role, name),
            LibwasmReceiver::Value(v) => {
                if matches!(
                    &v,
                    LibwasmValue::Object { kind, .. } if *kind == ObjectKind::Window
                ) && name == "platform"
                {
                    return Ok(LibwasmValue::I32(self.ensure_platform_global()?));
                }
                if matches!(
                    &v,
                    LibwasmValue::Object { kind, .. } if *kind == ObjectKind::Platform
                ) && name == "hw"
                {
                    return Ok(LibwasmValue::I32(self.ensure_hw_global()?));
                }
                if matches!(
                    &v,
                    LibwasmValue::Object { kind, .. } if *kind == ObjectKind::Hw
                ) && Self::hw_role(&v) == "root"
                    && (name == "net" || name == "display")
                {
                    return Ok(LibwasmValue::I32(self.ensure_hw_child(name)?));
                }
                if matches!(
                    &v,
                    LibwasmValue::Object { kind, .. } if *kind == ObjectKind::Hw
                ) && Self::hw_role(&v) == "net"
                    && (name == "tcp" || name == "udp")
                {
                    return Ok(LibwasmValue::I32(self.ensure_hw_child(name)?));
                }
                if matches!(
                    &v,
                    LibwasmValue::Object { kind, .. } if *kind == ObjectKind::Hw
                ) && Self::hw_role(&v) == "display"
                    && name == "gl"
                {
                    return Ok(LibwasmValue::I32(self.ensure_hw_child("gl")?));
                }
                self.value_getter(&v, name)
            }
        }
    }

    fn object_getter_idx(&mut self, handle: i32, idx: u32) -> Result<LibwasmValue, String> {
        match self.resolve_receiver(handle)? {
            LibwasmReceiver::Dom(h) => self.child_wrapper(h, idx as usize),
            LibwasmReceiver::Proxy(h, role) if role == "nodelist" => {
                self.child_wrapper(h, idx as usize)
            }
            LibwasmReceiver::Proxy(..) => Ok(LibwasmValue::None),
            LibwasmReceiver::Value(v) => Ok(match v {
                LibwasmValue::I32Vec(items) => items
                    .get(idx as usize)
                    .copied()
                    .map(LibwasmValue::I32)
                    .unwrap_or(LibwasmValue::None),
                LibwasmValue::U32Vec(items) => items
                    .get(idx as usize)
                    .copied()
                    .map(LibwasmValue::U32)
                    .unwrap_or(LibwasmValue::None),
                LibwasmValue::Object { props, .. } => props
                    .get(&idx.to_string())
                    .cloned()
                    .unwrap_or(LibwasmValue::None),
                LibwasmValue::String(s) => s
                    .chars()
                    .nth(idx as usize)
                    .map(|c| LibwasmValue::String(c.to_string()))
                    .unwrap_or(LibwasmValue::None),
                _ => LibwasmValue::None,
            }),
        }
    }

    fn object_call(
        &mut self,
        handle: i32,
        method: &str,
        args: &[LibwasmValue],
    ) -> Result<LibwasmValue, String> {
        match self.resolve_receiver(handle)? {
            LibwasmReceiver::Dom(h) => self.dom_call(h, method, args),
            LibwasmReceiver::Proxy(h, role) => self.dom_proxy_call(h, &role, method, args),
            LibwasmReceiver::Value(v) => self.value_call(handle, v, method, args),
        }
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

/// True when the shipped LDC/libwasm artifact can run: the BoardSpec marks
/// the `svelte-d` UI with JS+WASM file serving enabled and the artifact is
//  present (mirrors the `libwasm` gate in `g6b_ui::setup_html_libwasm`).
/// Local absolute URL the kernel fetch proxy may serve: `/bios/…` or `/ui/…`.
/// No scheme, no `//`, no traversal.
fn local_ui_url(url: &str) -> Option<&str> {
    let path = url.split(['?', '#']).next().unwrap_or(url);
    if !path.starts_with('/')
        || path.starts_with("//")
        || path.contains('\\')
        || path.contains(':')
        || path.chars().any(char::is_control)
        || path.split('/').any(|p| matches!(p, "." | ".."))
    {
        return None;
    }
    if path.starts_with("/ui/") || path.starts_with("/bios/") {
        Some(path)
    } else {
        None
    }
}

/// `<img src>` / similar: a served UI image, never a remote or script URL.
fn invoke_export(commands: &[g6b_js::LodashCommand]) -> Option<(String, Vec<JsValue>)> {
    for c in commands {
        if let g6b_js::LodashCommand::Func { name, params } = c {
            if name == "invoke" {
                let path = match params.first() {
                    Some(g6b_js::LodashParam::Value(v)) => v.to_js_string(),
                    _ => continue,
                };
                let args = params
                    .iter()
                    .skip(1)
                    .filter_map(|p| match p {
                        g6b_js::LodashParam::Value(v) => Some(v.clone()),
                        _ => None,
                    })
                    .collect();
                return Some((path, args));
            }
        }
    }
    None
}

fn local_src_url(url: &str) -> Option<&str> {
    let path = local_ui_url(url)?;
    if path.starts_with("/ui/")
        && (path.ends_with(".svg")
            || path.ends_with(".png")
            || path.ends_with(".jpg")
            || path.ends_with(".ico"))
    {
        Some(path)
    } else {
        None
    }
}

fn libwasm_lane(spec: &BoardSpec) -> bool {
    spec.kernel.js == "aot"
        && spec.kernel.ui == "svelte-d"
        && spec.kernel.wasm.enable
        && spec.kernel.http.files.enable
        && spec.kernel.http.files.js
        && spec.kernel.http.files.wasm
        && g6b_wasm::bios_ui_libwasm_live()
}

/// The page a `BrowserSession` actually parses: the libwasm-aware variant
/// when the lane is live so `#libwasm-root` exists for the cell to mount on.
fn session_page_html(spec: &BoardSpec) -> String {
    let html = if libwasm_lane(spec) {
        g6b_ui::setup_html_libwasm(spec, "/ui/ui-libwasm.wasm")
    } else {
        g6b_ui::setup_html(spec)
    };
    let script = g6b_ui::setup_script(spec);
    html.replace("</body>", &format!("<script>{script}</script></body>"))
}

/// Decode the shipped libwasm cell. Keep `asyncify_*` so `_start` Sleeping/
/// resume matches `asyncify.ts` wrapExportFn. Scratch is reserved above the
/// D heap (`reserve_asyncify_scratch`).
fn decode_libwasm() -> Result<g6b_wasm::Module, String> {
    g6b_wasm::decode(g6b_wasm::bios_ui_libwasm())
}

fn optional_ui_id(spec: &BoardSpec, id: &str) -> bool {
    match id {
        // The refresh button is part of the Svelte shell but g6b-ui removes it
        // when no JS proxy refresh path is available.
        "refresh" => true,
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
    Wasm {
        function_index: u32,
        handle: i32,
    },
    /// D `EventHandler` / `exportDelegate`: `jsCallback(ctx, ptr, eventHandle)`.
    Delegate {
        ctx: i32,
        ptr: i32,
    },
    /// Cell-owned click (`g6b_listen` with listener 0): tab navigate,
    /// refresh, or B92 window/tab chrome.
    Cell,
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

/// One UI-thread frame from [`BrowserSession::tick`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct UiTick {
    /// The CSS raster / GL present should run.
    pub presented: bool,
    /// The live DOM had dirty nodes or completed async work.
    pub dirty: bool,
}

/// One host blit of Canvas32 dirty tiles into modelled `__scan_fb`.
#[derive(Debug, Clone)]
pub struct ScanoutPresent {
    /// No tiles: skip-if-clean (no `TRANSFER_TO_HOST_2D`).
    pub skipped: bool,
    pub tiles: usize,
    /// Virtio-gpu controlq listing (`TRANSFER_TO_HOST_2D` + `RESOURCE_FLUSH`).
    pub listing: String,
}

/// Guest intern table for one iframe session. Not the shell `WasmUi` table.
struct FrameGuest {
    intern: SessionIntern,
    objects: ObjectTable<LibwasmValue>,
    window: i32,
    document: i32,
    js_exports: g6b_wasm::JsExports,
}

impl FrameGuest {
    fn new(intern: SessionIntern, vars: &SessionVars) -> Result<Self, String> {
        let mut objects = ObjectTable::new();
        let document = objects.add(LibwasmValue::empty(ObjectKind::Document))?;
        let mut window = LibwasmValue::empty(ObjectKind::Window)
            .with_prop("document", LibwasmValue::I32(document))
            .with_prop(
                "contextId",
                LibwasmValue::String(format!("frame-{}-g{}", intern.slot, intern.generation)),
            );
        for (name, var) in vars.iter() {
            if let Some(v) = intern_session_var(var) {
                window = window.with_prop(name, v);
            }
        }
        let window = objects.add(window)?;
        let _console = objects.add(LibwasmValue::empty(ObjectKind::Empty))?;
        Ok(Self {
            intern,
            objects,
            window,
            document,
            js_exports: g6b_wasm::JsExports::default(),
        })
    }

    fn owns(&self, handle: i32) -> bool {
        self.objects.get(handle).is_ok()
    }

    fn window_prop(&self, name: &str) -> Option<&LibwasmValue> {
        match self.objects.get(self.window).ok()? {
            LibwasmValue::Object { props, .. } => props.get(name),
            _ => None,
        }
    }
}

fn intern_session_var(var: &SessionVar) -> Option<LibwasmValue> {
    match var {
        SessionVar::Null => Some(LibwasmValue::empty(ObjectKind::Empty)),
        SessionVar::Bool(b) => Some(LibwasmValue::Bool(*b)),
        SessionVar::Number(n) | SessionVar::String(n) | SessionVar::Json(n) => {
            Some(LibwasmValue::String(n.clone()))
        }
        SessionVar::Function => None,
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
    /// Loaded svelte-d LDC application (persistent instance).
    pub wasm_ui: Option<WasmUi>,
    /// Which UI surface feeds the scanout. Starts at the BoardSpec default
    /// (which follows the highest-priority output's class) and is flipped by
    /// the `#disp-toggle` control or `DisplaySurface` in the HolyC lane.
    pub surface: g6b_spec::Surface,
    selected_menu: String,
    /// B92 session pool (`g6b-iframe`). Window/tab chrome is Svelte.
    /// Kernel registers hooks and fulfills [`HostNeed`] GETs.
    frames: FrameEngine,
    /// Test / adapter bodies for armed outbound `http(s):` (never `/bios`).
    outbound_stubs: BTreeMap<String, (u16, String)>,
    /// Per-tab guest object tables (B92e). Never the shell `WasmUi` table.
    frame_guests: [Option<FrameGuest>; MAX_TABS_PER_WINDOW],
    async_scripts: g6b_js::AsyncScheduler,
    spec: BoardSpec,
    /// Live CSS engine. Parsed once; `paint(&Node)` is the raster (B88).
    css: Option<Engine>,
    timers: crate::timers::TimerHeap,
    now_ns: u64,
    /// Modelled `__scan_fb` (X8R8G8B8). Host blit of Canvas32 dirty tiles (B90).
    pub scan_fb: Vec<u8>,
    scan_fb_w: u32,
    scan_fb_h: u32,
    /// Last virtio-gpu transfer listing (empty tiles → skip-if-clean).
    last_transfer: String,
    last_tiles: Vec<g6b_css::DirtyRegion>,
    /// Post-boot lazy adapter session. Not started from `_start`.
    pub hw: g6b_hw::HwSession,
}

impl BrowserSession {
    pub fn new(spec: &BoardSpec) -> Result<Self, String> {
        Self::from_program(spec, load_program(spec)?)
    }

    fn from_program(spec: &BoardSpec, program: Program) -> Result<Self, String> {
        let mut session = Self {
            dom: g6b_html::parse_checked(&session_page_html(spec))?,
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
            wasm_ui: None,
            surface: g6b_spec::Surface::Vga,
            selected_menu: spec.kernel.start_menu.clone(),
            frames: {
                let mut frames = FrameEngine::new();
                if spec.kernel.usb.enable && spec.kernel.usb.key {
                    let mut vols: Vec<String> = Vec::new();
                    if spec.kernel.usb.fs_fat32 {
                        vols.push("fat32".into());
                    }
                    if spec.kernel.usb.fs_ntfs {
                        vols.push("ntfs".into());
                    }
                    if spec.kernel.usb.fs_ext4 {
                        vols.push("ext4".into());
                    }
                    frames.register_hook(g6b_iframe::AppHook::files_volumes(vols));
                }
                // Outbound stays off until `g6b-hw` announces net support.
                frames.set_outbound(false);
                frames
            },
            hw: g6b_hw::HwSession::from_board(spec),
            frame_guests: std::array::from_fn(|_| None),
            outbound_stubs: BTreeMap::new(),
            async_scripts: g6b_js::AsyncScheduler::default(),
            spec: spec.clone(),
            css: None,
            timers: crate::timers::TimerHeap::new(),
            now_ns: 0,
            scan_fb: Vec::new(),
            scan_fb_w: 0,
            scan_fb_h: 0,
            last_transfer: String::new(),
            last_tiles: Vec::new(),
        };
        if spec.kernel.js == "aot" {
            for src in script_sources(&session.dom) {
                session.execute_script(&src)?;
            }
        }
        if spec.kernel.wasm.enable {
            // The LDC/libwasm cell is the only UI wasm. The MVP encoder
            // artifact is a compiler demonstration and a guest VGA-glyph
            // lowering input — never a silent host fallback.
            if libwasm_lane(spec) {
                session.run_libwasm_start()?;
            } else if spec.kernel.ui == "svelte-d" && spec.kernel.js == "aot" {
                return Err(
                    "svelte-d UI requires the LDC libwasm cell (kernel.wasm + http.files.wasm)"
                        .into(),
                );
            }
            session.refresh()?;
        }
        session.select_menu(&spec.kernel.start_menu)?;
        if let Some(svc) = session.task_services.as_mut() {
            let _ = svc.ensure_ui();
            session.diagnostics.push("UI-HART ready".into());
        }
        Ok(session)
    }

    /// Run the shipped LDC/libwasm cell (`browser-ui/out/bios-ui-libwasm.wasm`)
    /// against a fresh `<div>` mount under `#libwasm-root`. The mount is a
    /// child path inside `self.dom`, so the guest's `fetch` calls can paint
    /// the surrounding setup page while its own tree stages under the mount.
    fn run_libwasm_start(&mut self) -> Result<(), String> {
        let spec = &self.spec;
        let root_path = path_from_root(&self.dom, "libwasm-root")
            .ok_or_else(|| "libwasm-root element missing".to_string())?;
        let mount_path = {
            let root = node_at_mut(&mut self.dom, &root_path)
                .ok_or_else(|| "libwasm-root path is stale".to_string())?;
            root.children.push(Node::elem("div"));
            let mut path = root_path.clone();
            path.push(root.children.len() - 1);
            path
        };
        let decoded = decode_libwasm()?;
        let mut host = KernelHost::attach_fresh(
            &mut self.dom,
            &self.program.router,
            spec,
            mount_path,
            &mut self.timers,
            self.now_ns,
            Some(&mut self.program.store),
        );
        let module = run_libwasm_start(&decoded, &mut host)?;
        if spec.kernel.http.files.assets {
            let css = host.router.fetch_get("/ui/bios-ui.css");
            if css.status == 200 {
                let _ = host.add_css(&css.body_str());
            }
        }
        let _ = host.ensure_js_globals();
        let diagnostics = std::mem::take(&mut host.diagnostics);
        let pending = std::mem::take(&mut host.pending_event_listeners);
        let delegates = std::mem::take(&mut host.pending_event_delegates);
        let removals = std::mem::take(&mut host.pending_event_removals);
        self.wasm_ui = Some(WasmUi::from_host(module, &mut host));
        drop(host);
        self.diagnostics.extend(diagnostics);
        self.diagnostics.push("WASM-INTERPRETER _start".into());
        if let Some(n) = self.dom.get_element_by_id("libwasm-status") {
            n.set_inner_text("LDC cell: mounted");
        }
        self.wasm_executed = true;
        self.apply_pending_wasm_listeners(&pending)?;
        self.apply_pending_event_delegates(&delegates)?;
        for id in &removals {
            self.remove_event_listener(*id);
        }
        if !pending
            .iter()
            .any(|(_, ty, lid, _)| ty == "click" && *lid == 0)
        {
            self.bind_cell_clicks();
        }
        Ok(())
    }

    /// Attach cell-owned click handlers on live `[data-menu-link]` tabs and
    /// `#refresh` when the LDC cell has not yet emitted `g6b_listen`.
    fn bind_cell_clicks(&mut self) {
        let mut ids = vec!["refresh".to_string()];
        for face in g6b_ui::MENUS {
            ids.push(format!("tab-{}", face.id));
        }
        for id in ids {
            let _ = self.add_event_listener_by_id(&id, "click", false, Listener::Cell);
        }
        self.diagnostics
            .push("WASM-CELL-LISTEN tabs+refresh".into());
    }

    fn paint_status(&mut self, fallback: &str) {
        if let Some(n) = self.dom.get_element_by_id("status") {
            n.set_inner_text(fallback);
        }
    }

    /// When `g6b-hw` first listens, announce adapters through the kernel:
    /// net → iframe outbound (if BoardSpec allows); display → GPU priority
    /// instead of the VGA default. Pending `http(s):` tabs then load.
    /// BIOS UI paints nodes from [`g6b_hw::HwEvent`]; the kernel does not
    /// write the DOM by id.
    fn apply_hw_support(&mut self) {
        if !self.hw.listening() {
            return;
        }
        if !self.hw.support_announced() {
            for line in self.hw.support_lines() {
                self.diagnostics.push(line);
            }
            self.hw.mark_announced();
            if self.hw.has_net() && self.spec.kernel.http.outbound {
                let was = self.frames.outbound();
                self.frames.set_outbound(true);
                if !was {
                    self.retry_outbound_iframes();
                }
            }
            if self.hw.display_ready() && self.spec.surface_toggle() {
                let want = g6b_spec::Surface::parse(self.hw.probed_surface())
                    .unwrap_or(g6b_spec::Surface::Gpu);
                if self.surface != want {
                    self.surface = want;
                    self.diagnostics
                        .push(format!("DISP-SURFACE {}", want.as_str()));
                }
            }
            self.hw.set_scanout(self.surface.as_str());
        }
        self.dispatch_hw_events();
    }

    /// Dispatch pending `HWEvent`s on the document body, same intern path as
    /// a pointer `MouseEvent`. No `get_element_by_id` — the BIOS UI owns nodes.
    fn dispatch_hw_events(&mut self) {
        let evs = self.hw.take_events();
        for ev in evs {
            self.diagnostics.push(format!("HW-EVENT {}", ev.event_type));
            let _ = self.dispatch_hw_event(&ev);
        }
    }

    fn dispatch_hw_event(&mut self, ev: &g6b_hw::HwEvent) -> Result<bool, String> {
        let body = body_node(&mut self.dom).ok_or("no body node")?;
        let mut event = Event::new(
            &ev.event_type,
            EventInit {
                bubbles: true,
                cancelable: true,
                composed: true,
                detail: ev.detail.clone(),
            },
        );
        let allowed = Node::dispatch_event(body, &[], &mut event, &mut self.event_host);
        let wasm_prevented = self.run_triggered();
        let named_prevented = self.run_named_input_delegates(&event);
        Ok(allowed && !wasm_prevented && !named_prevented)
    }

    fn retry_outbound_iframes(&mut self) {
        let waiters = self.frames.outbound_waiters();
        for (slot, url) in waiters {
            let (need, note) = self.frames.navigate(slot, &url);
            self.frame_note(note);
            self.fulfill_host_need(need);
        }
    }

    fn frame_note(&mut self, note: g6b_iframe::FrameNote) {
        self.diagnostics.push(note.text);
    }

    fn fulfill_host_need(&mut self, need: HostNeed) {
        match need {
            HostNeed::None => {}
            HostNeed::Html { slot, path } => {
                let resp = self.program.router.fetch_get(&path);
                let note = self
                    .frames
                    .provide_html(slot, &path, resp.status, &resp.body_str());
                self.frame_note(note);
            }
            HostNeed::Files {
                slot,
                index,
                volumes,
            } => {
                let listing = self.program.router.fetch_get(&index);
                if listing.status != 200 {
                    let note = self.frames.provide_files_error(slot, listing.status);
                    self.frame_note(note);
                    return;
                }
                let mut vols = Vec::new();
                for (name, path) in volumes {
                    let r = self.program.router.fetch_get(&path);
                    if r.status == 200 {
                        vols.push(g6b_iframe::FilesVolume {
                            name,
                            listing: r.body_str(),
                        });
                    }
                }
                let note = self.frames.provide_files(slot, listing.body_str(), vols);
                self.frame_note(note);
            }
            HostNeed::RemoteHtml { slot, url } => {
                let (status, body) = self.outbound_get(&url);
                let note = self.frames.provide_html(slot, &url, status, &body);
                self.frame_note(note);
            }
        }
    }

    /// Kernel fetch abstraction. Stubs first; then plan in `g6b-http`,
    /// TLS fingerprint in `g6b-tls`, sockets in `g6b-hw` TCP/IP.
    /// Never KernelPort, never `-netdev`, never HTTPS inside `g6b-hw`.
    fn outbound_get(&mut self, url: &str) -> (u16, String) {
        if let Some((st, body)) = self.outbound_stubs.get(url) {
            return (*st, body.clone());
        }
        match self.outbound_via_hw_tcp(url) {
            Ok(v) => v,
            Err(e) => {
                self.diagnostics.push(format!("KERNEL-FETCH-ERR {url} {e}"));
                (502, e)
            }
        }
    }

    fn prepare_hw_tcp(&mut self) -> Result<String, String> {
        self.hw.ensure();
        if self.hw.mode() == g6b_hw::NatMode::Minimal {
            self.hw.apply_nat("isolated")?;
        }
        let id = self.hw.primary_net_id();
        let link_down = self
            .hw
            .device(&id)
            .map(|d| d.inet.link != g6b_hw::LinkState::Up)
            .unwrap_or(true);
        if link_down {
            self.hw.apply_link(&id, "up")?;
        }
        Ok(id)
    }

    fn hw_tcp_send_all(&mut self, sock: u32, data: &[u8]) -> Result<(), String> {
        let mut off = 0;
        for _ in 0..80 {
            if off >= data.len() {
                return Ok(());
            }
            let n = self.hw.tcp_send_bytes(sock, &data[off..])?;
            off += n;
            if off >= data.len() {
                return Ok(());
            }
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        Err("hw tcp send timeout".into())
    }

    fn hw_tcp_recv_until(&mut self, sock: u32, min: usize, http: bool) -> Result<Vec<u8>, String> {
        let mut acc = Vec::new();
        for _ in 0..80 {
            let chunk = self.hw.tcp_recv_bytes(sock)?;
            if !chunk.is_empty() {
                acc.extend_from_slice(&chunk);
            }
            if http && acc.windows(4).any(|w| w == b"\r\n\r\n") && acc.len() >= min {
                return Ok(acc);
            }
            if !http && acc.len() >= min {
                return Ok(acc);
            }
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        if acc.is_empty() {
            Err("hw tcp recv timeout".into())
        } else {
            Ok(acc)
        }
    }

    fn outbound_via_hw_tcp(&mut self, url: &str) -> Result<(u16, String), String> {
        let req = g6b_http::outbound::plan(url)?;
        let id = self.prepare_hw_tcp()?;
        let sock = self.hw.tcp_connect_sock(&id, &req.host, req.port)?;
        let scheme = if req.https { "https" } else { "http" };
        self.diagnostics.push(format!(
            "KERNEL-FETCH {scheme} {}:{}/ via=hw-tcp sock={sock} dev={id}",
            req.host, req.port
        ));
        let out = if req.https {
            let hello = g6b_tls::client_hello(&req.host);
            self.hw_tcp_send_all(sock, &hello)?;
            let rec = self.hw_tcp_recv_until(sock, 5, false)?;
            let kind = g6b_tls::tls_record_kind(&rec).unwrap_or("unknown");
            self.diagnostics
                .push(format!("KERNEL-FETCH-TLS {kind} via=hw-tcp"));
            (
                501,
                format!("outbound https: adapter TLS (g6b-tls ClientHello) via=hw-tcp tls={kind}"),
            )
        } else {
            let bytes = g6b_http::outbound::http1_get_request(&req);
            self.hw_tcp_send_all(sock, &bytes)?;
            let raw = self.hw_tcp_recv_until(sock, 1, true)?;
            let resp = g6b_http::outbound::parse_http1_response(&raw);
            self.diagnostics
                .push(format!("KERNEL-FETCH-HTTP {} via=hw-tcp", resp.status));
            (resp.status, resp.body_str())
        };
        let _ = self.hw.sock_close(sock);
        Ok(out)
    }

    /// Install a body for an armed outbound URL (tests / adapter).
    pub fn stub_outbound(&mut self, url: &str, status: u16, body: impl Into<String>) {
        self.outbound_stubs
            .insert(url.to_string(), (status, body.into()));
    }

    /// Svelte chrome created a mount; allocate the session if needed.
    pub fn ensure_iframe_session(&mut self, slot: usize) -> Result<(), String> {
        let note = self.frames.ensure(slot);
        self.frame_note(note);
        Ok(())
    }

    pub fn drop_iframe_session(&mut self, slot: usize) -> Result<(), String> {
        let note = self.frames.drop(slot);
        self.frame_note(note);
        if slot < self.frame_guests.len() {
            self.frame_guests[slot] = None;
        }
        Ok(())
    }

    pub fn drop_all_iframe_sessions(&mut self) -> Result<(), String> {
        let note = self.frames.drop_all();
        self.frame_note(note);
        self.frame_guests = std::array::from_fn(|_| None);
        Ok(())
    }

    /// Parent `vars` map. Data interned on the guest window; functions stay host-side.
    pub fn set_iframe_vars(&mut self, slot: usize, vars: SessionVars) -> Result<(), String> {
        let note = self.frames.set_vars(slot, vars);
        self.frame_note(note);
        if slot < self.frame_guests.len() {
            self.frame_guests[slot] = None;
        }
        Ok(())
    }

    pub fn iframe_session(&self, slot: usize) -> Option<&IframeSession> {
        self.frames.session(slot)
    }

    fn sync_frame_guest(&mut self, slot: usize) {
        match self.frames.content_window(slot) {
            None => self.frame_guests[slot] = None,
            Some(token) => {
                let fresh = self.frame_guests[slot]
                    .as_ref()
                    .is_none_or(|g| g.intern != token);
                if fresh {
                    let vars = self
                        .frames
                        .session(slot)
                        .map(|s| s.vars.clone())
                        .unwrap_or_default();
                    self.frame_guests[slot] = FrameGuest::new(token, &vars).ok();
                }
            }
        }
    }

    /// Interned guest `contentWindow`. None when the session does not exist.
    pub fn frame_content_window(&mut self, slot: usize) -> Option<i32> {
        if slot >= MAX_TABS_PER_WINDOW {
            return None;
        }
        self.sync_frame_guest(slot);
        self.frame_guests[slot].as_ref().map(|g| g.window)
    }

    /// Interned guest `contentDocument`. None when the session does not exist.
    pub fn frame_content_document(&mut self, slot: usize) -> Option<i32> {
        if slot >= MAX_TABS_PER_WINDOW {
            return None;
        }
        self.sync_frame_guest(slot);
        self.frame_guests[slot].as_ref().map(|g| g.document)
    }

    /// Guest `window` property interned from parent `vars` (data only).
    pub fn frame_window_prop(&self, slot: usize, name: &str) -> Option<&LibwasmValue> {
        self.frame_guests
            .get(slot)
            .and_then(|g| g.as_ref())
            .and_then(|g| g.window_prop(name))
    }

    /// True when `handle` lives in the guest table, not the shell `WasmUi`.
    pub fn frame_owns_handle(&self, slot: usize, handle: i32) -> bool {
        self.frame_guests
            .get(slot)
            .and_then(|g| g.as_ref())
            .is_some_and(|g| g.owns(handle))
    }

    pub fn frame_js_exports(&self, slot: usize) -> Option<&g6b_wasm::JsExports> {
        self.frame_guests
            .get(slot)
            .and_then(|g| g.as_ref())
            .map(|g| &g.js_exports)
    }

    /// Nested cell native import. Fail closed without a cap.
    pub fn frame_native_import(&self, slot: usize, name: &str) -> Result<(), String> {
        let caps = self
            .frames
            .session(slot)
            .map(|s| s.caps)
            .unwrap_or_else(SessionCaps::deny);
        match g6b_iframe::session_import_reject(name, caps) {
            Some(msg) => Err(msg.into()),
            None => Ok(()),
        }
    }

    /// Navigate an existing session. Kernel only fulfills [`HostNeed`] GETs.
    pub fn navigate_browser_tab(&mut self, slot: usize, url: &str) -> Result<(), String> {
        let (need, note) = self.frames.navigate(slot, url);
        self.frame_note(note);
        self.fulfill_host_need(need);
        Ok(())
    }

    /// `srcdoc`: no fetch.
    pub fn srcdoc_browser_tab(&mut self, slot: usize, html: &str) -> Result<(), String> {
        let note = self.frames.srcdoc(slot, html);
        self.frame_note(note);
        Ok(())
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
                    let resp = self.kernel_fetch(&method, &url);
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
        if g6b_hw::is_hw_invoke(line) {
            let out = g6b_hw::eval_instant(&mut self.hw, line);
            self.apply_hw_support();
            return Ok(ReplResult::Output(out));
        }
        if let Some((name, args)) = g6b_hw::parse_invoke(line) {
            if matches!(name.as_str(), "UsbLs" | "UsbKey" | "UsbFlash") {
                let hw_name = match name.as_str() {
                    "UsbLs" => "hwUsbLs",
                    "UsbKey" => "hwUsbKey",
                    "UsbFlash" => "hwUsbFlash",
                    _ => "hwUsbLs",
                };
                let refs: Vec<&str> = args.iter().map(String::as_str).collect();
                let out = g6b_hw::call_instant(&mut self.hw, hw_name, &refs);
                self.apply_hw_support();
                return Ok(ReplResult::Output(out));
            }
            if matches!(
                name.as_str(),
                "HttpsGet" | "HttpGet" | "httpsGet" | "httpGet"
            ) {
                let url = args.first().cloned().unwrap_or_default();
                let (st, body) = self.outbound_get(&url);
                self.apply_hw_support();
                return Ok(ReplResult::Output(format!("HTTP {st}\n{body}\n")));
            }
        }
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
                    let response = self.kernel_fetch("GET", url);
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

    /// UI-thread frame: drain async JS, restyle hit boxes if the live DOM is
    /// dirty, return whether a GL/virtio present should run. `presented` is
    /// the GLES2 `u_dom` dirty-tile flag (skip-if-clean).
    ///
    /// When `kernel.tasking` is on, this is the body of `Role::Ui` /
    /// `Job::Ui` on `ui_hart`.
    pub fn tick(&mut self, now_ns: u64) -> Result<UiTick, String> {
        self.now_ns = now_ns;
        let dispatch = if self.task_services.is_some() {
            let svc = self.task_services.as_mut().unwrap();
            svc.ensure_ui().map_err(|e| e.to_string())?;
            svc.take_ui_dispatch().map_err(|e| e.to_string())?
        } else {
            None
        };
        let result = self.tick_body(now_ns);
        if let Some(d) = dispatch {
            if let Some(svc) = self.task_services.as_mut() {
                let _ = svc.yield_ui(d);
            }
        }
        result
    }

    fn tick_body(&mut self, now_ns: u64) -> Result<UiTick, String> {
        self.fire_due_timers(now_ns)?;
        let async_tick = self.poll_async();
        let dirty = !self.dom.dirty_union().is_empty() || async_tick.ready > 0;
        if dirty {
            self.render_hit_boxes()?;
            self.present_scanout()?;
            self.dom.clear_dirty();
        } else if self.css.as_ref().and_then(|e| e.last()).is_some() {
            self.present_scanout()?;
        }
        Ok(UiTick {
            presented: dirty,
            dirty,
        })
    }

    fn fire_due_timers(&mut self, now_ns: u64) -> Result<(), String> {
        let due = self
            .timers
            .take_due(now_ns, crate::timers::MAX_FIRES_PER_TICK);
        for t in due {
            if t.ptr <= 0 {
                self.diagnostics.push(format!("TIMER-SKIP id={}", t.id));
                continue;
            }
            let Some(mut ui) = self.wasm_ui.take() else {
                self.diagnostics
                    .push(format!("TIMER-NO-MODULE id={}", t.id));
                continue;
            };
            let func = match g6b_wasm::table_funcref(&ui.module, t.ptr) {
                Ok(f) => f,
                Err(e) => {
                    self.diagnostics
                        .push(format!("TIMER-BAD-PTR id={} ptr={}: {e}", t.id, t.ptr));
                    self.wasm_ui = Some(ui);
                    continue;
                }
            };
            let fired = ui.call(
                crate::browser::UiBorrow {
                    dom: &mut self.dom,
                    router: &self.program.router,
                    spec: &self.spec,
                    timers: &mut self.timers,
                    now_ns,
                    store: Some(&mut self.program.store),
                    hw: Some(&mut self.hw),
                },
                func,
                &[t.ctx],
            );
            self.wasm_ui = Some(ui);
            match fired {
                Ok(call) => {
                    self.diagnostics.extend(call.diagnostics);
                    self.apply_hw_support();
                    self.diagnostics.push(format!("TIMER-FIRE id={}", t.id));
                }
                Err(e) => self
                    .diagnostics
                    .push(format!("TIMER-ERROR id={}: {e}", t.id)),
            }
        }
        Ok(())
    }

    /// GLES2 `u_dom` composite of the live session (CPU raster is truth).
    /// Does not re-force a raster: uses the last paint, then dirty-tile
    /// present into modelled `__scan_fb`.
    pub fn present_gl(&mut self) -> Result<Vec<u8>, String> {
        if self.css.as_ref().and_then(|e| e.last()).is_none() {
            let _ = self.paint_css()?;
        }
        let _ = self.present_scanout()?;
        let proxy = g6b_gr::proxy::Proxy::from_spec(&self.spec);
        let canvas = &self
            .css
            .as_ref()
            .and_then(|e| e.last())
            .ok_or("css engine has no frame")?
            .canvas;
        Ok(g6b_gr::gl::composite_ppm32(&proxy, canvas, "u_dom"))
    }

    /// Blit last-paint dirty tiles into modelled `__scan_fb` and record a
    /// virtio-gpu `TRANSFER_TO_HOST_2D` + `RESOURCE_FLUSH` listing. Empty
    /// tiles are skip-if-clean (no TRANSFER). Guest `VioPaint` stays
    /// full-frame until B91.
    pub fn present_scanout(&mut self) -> Result<ScanoutPresent, String> {
        let (w, h) = self.css.as_ref().map(|e| e.viewport()).unwrap_or_else(|| {
            (
                self.spec.kernel.gr.w.max(320),
                self.spec.kernel.gr.h.max(200),
            )
        });
        self.ensure_engine(w, h)?;
        if self.css.as_ref().and_then(|e| e.last()).is_none() {
            let _ = self.paint_css_at(w, h)?;
        }
        let (w, h) = self.css.as_ref().map(|e| e.viewport()).unwrap_or((w, h));
        self.ensure_scan_fb(w, h);
        let mut engine = self.css.take().ok_or("css engine missing")?;
        let tiles = engine.consume_tiles();
        let gl_tiles: Vec<g6b_gr::gl::Tile> = tiles
            .iter()
            .map(|t| g6b_gr::gl::Tile {
                x: t.x,
                y: t.y,
                w: t.w,
                h: t.h,
            })
            .collect();
        if let Some(last) = engine.last() {
            g6b_gr::gl::blit_tiles_x8r8(&last.canvas, &mut self.scan_fb, &gl_tiles);
        }
        self.css = Some(engine);
        self.last_tiles = tiles;
        let listing = g6b_gr::gl::transfer_listing(&gl_tiles);
        self.last_transfer = listing.clone();
        if gl_tiles.is_empty() {
            self.diagnostics.push("SCAN-SKIP".into());
        } else {
            self.diagnostics
                .push(format!("SCAN-TRANSFER n={}", gl_tiles.len()));
            self.diagnostics.push("SCAN-FLUSH".into());
        }
        Ok(ScanoutPresent {
            skipped: gl_tiles.is_empty(),
            tiles: gl_tiles.len(),
            listing,
        })
    }

    fn ensure_scan_fb(&mut self, w: u32, h: u32) {
        let n = (w as usize).saturating_mul(h as usize).saturating_mul(4);
        if self.scan_fb_w != w || self.scan_fb_h != h || self.scan_fb.len() != n {
            self.scan_fb = vec![0; n];
            self.scan_fb_w = w;
            self.scan_fb_h = h;
        }
    }

    /// PPM of modelled `__scan_fb` (Main→CPU→Memory scanout stand-in).
    pub fn scanout_ppm(&self) -> Option<Vec<u8>> {
        g6b_gr::x8r8_to_ppm(self.scan_fb_w, self.scan_fb_h, &self.scan_fb)
    }

    /// Last virtio-gpu transfer listing from [`Self::present_scanout`].
    pub fn last_transfer(&self) -> &str {
        &self.last_transfer
    }

    /// Dirty tiles from the last present (guest `__ui_cap` pack).
    pub fn last_tiles(&self) -> &[g6b_css::DirtyRegion] {
        &self.last_tiles
    }

    /// Live CSS paint of the Svelte tree. No HTML serialize/parse.
    pub fn paint_css(&mut self) -> Result<g6b_css::render32::Render32Output, String> {
        let w = self.spec.kernel.gr.w.max(320);
        let h = self.spec.kernel.gr.h.max(200);
        self.paint_css_at(w, h)
    }

    /// Live CSS paint at an explicit canvas size (GPU scanout geometry).
    pub fn paint_css_at(
        &mut self,
        w: u32,
        h: u32,
    ) -> Result<g6b_css::render32::Render32Output, String> {
        self.ensure_engine(w, h)?;
        let mut engine = self.css.take().ok_or("css engine missing")?;
        let targets = live_paint_targets(&self.dom);
        let painted = engine.paint_nodes(&targets, false);
        self.css = Some(engine);
        let painted = painted?;
        let mut hits = painted.hit_boxes.clone();
        remap_hit_paths(&self.dom, &mut hits);
        self.hit_boxes = hits.clone();
        Ok(g6b_css::render32::Render32Output {
            canvas: painted.canvas,
            hit_boxes: hits,
        })
    }

    fn ensure_engine(&mut self, w: u32, h: u32) -> Result<(), String> {
        let w = w.max(320);
        let h = h.max(200);
        if self.css.is_none() {
            let css = live_css(&self.dom, &self.spec)?;
            let fonts = g6b_css::FontSet::default_set().map_err(|e| format!("{e:?}"))?;
            let assets = session_assets(&self.spec);
            self.css = Some(Engine::new(&css, w, h, assets, fonts)?);
        } else if let Some(engine) = self.css.as_mut() {
            engine.set_viewport(w, h);
        }
        Ok(())
    }

    fn kernel_fetch(&mut self, method: &str, url: &str) -> g6b_http::Response {
        if url.starts_with("http://") || url.starts_with("https://") {
            if !self.spec.kernel.http.outbound {
                return g6b_http::Response::file(403, "text/plain", "outbound fetch disabled");
            }
            if !method.eq_ignore_ascii_case("GET") {
                return g6b_http::Response::file(405, "text/plain", "outbound GET only");
            }
            let (st, body) = self.outbound_get(url);
            return g6b_http::Response::file(st, "text/plain", body);
        }
        self.program
            .router
            .fetch_with_body(method, url, &[], Some(&mut self.program.store))
    }

    pub fn refresh(&mut self) -> Result<(), String> {
        if self.spec.kernel.http.enable && self.spec.kernel.http.proxy_js {
            for url in g6b_ui::setup_reads(&self.spec) {
                let response = self.kernel_fetch("GET", url);
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
        self.hw.set_scanout(want.as_str());
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
            let mut found = false;
            let show = face.id == id;
            each_id(&mut self.dom, &format!("menu-{}", face.id), &mut |panel| {
                found = true;
                panel.set_visible(show);
                Ok(())
            })?;
            if !found {
                return Err(format!("missing menu {}", face.id));
            }
        }
        if self.selected_menu != id {
            self.async_scripts.cancel_all();
        }
        self.selected_menu = id.into();
        self.paint_live_tabs(id)?;
        Ok(())
    }

    /// Restyle the live Svelte tab strip (`bios-tab-active`, aria) so goosie
    /// plus GLES2 present the selected menu. Every node with that id is
    /// updated (static shell and LDC cell tree).
    fn paint_live_tabs(&mut self, id: &str) -> Result<(), String> {
        for face in g6b_ui::MENUS {
            let active = face.id == id;
            each_id(&mut self.dom, &format!("tab-{}", face.id), &mut |tab| {
                tab.set_attribute(
                    "class",
                    if active {
                        "bios-tab bios-tab-active"
                    } else {
                        "bios-tab"
                    },
                )?;
                tab.set_attribute("aria-selected", if active { "true" } else { "false" })?;
                tab.set_attribute("tabindex", if active { "0" } else { "-1" })?;
                if active {
                    tab.set_attribute("aria-current", "page")?;
                } else {
                    tab.remove_attribute("aria-current");
                }
                Ok(())
            })?;
        }
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
    ///
    /// Pixels and hit boxes come from the **live** `session.dom` (the Svelte
    /// tree after `_start`) via `Engine::paint(&Node)`, not from an HTML string.
    pub fn render_hit_boxes(&mut self) -> Result<(), String> {
        let _ = self.paint_css()?;
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
            let listener = if *listener_id == 0 {
                Listener::Cell
            } else {
                Listener::Wasm {
                    function_index: *listener_id as u32,
                    handle: 0,
                }
            };
            self.add_event_listener_by_id(target_id, event_type, *capture, listener)
                .unwrap_or_else(|e| {
                    self.diagnostics.push(format!(
                        "WASM-EVENT-REGISTER-FAILED {target_id} {event_type}: {e}"
                    ));
                    0
                });
        }
        Ok(())
    }

    /// D `Object_Call_EventHandler__void` → `Listener::Delegate` on the live node.
    pub fn apply_pending_event_delegates(
        &mut self,
        pending: &[(String, String, i32, i32, bool)],
    ) -> Result<(), String> {
        for (target_id, event_type, ctx, ptr, capture) in pending {
            if *ptr <= 0 {
                continue;
            }
            self.add_event_listener_by_id(
                target_id,
                event_type,
                *capture,
                Listener::Delegate {
                    ctx: *ctx,
                    ptr: *ptr,
                },
            )
            .unwrap_or_else(|e| {
                self.diagnostics.push(format!(
                    "WASM-DELEGATE-REGISTER-FAILED {target_id} {event_type}: {e}"
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
        let hit = self
            .hit_boxes
            .iter()
            .rev()
            .find(|h| x >= h.x && x < h.x + h.w && y >= h.y && y < h.y + h.h)
            .ok_or("no hit target")?;
        let hover_id = hit.id.clone();
        let hit_path = hit.path.clone();
        let session_scope = session_slot_on_path(&self.dom, &hit_path);
        let body = body_node(&mut self.dom).ok_or("no body node")?;
        let mut event = Event::new(
            event_type,
            EventInit {
                bubbles: true,
                cancelable: true,
                composed: true,
                detail: detail.into(),
            },
        );
        event.target = hover_id.clone();
        event.client_x = x;
        event.client_y = y;
        let allowed = Node::dispatch_event(body, &hit_path, &mut event, &mut self.event_host);
        if event_type == "mousemove"
            || event_type == "mouseover"
            || event_type == "pointermove"
            || event_type == "click"
        {
            set_hover_attr(&mut self.dom, hover_id.as_deref(), session_scope);
        }
        let wasm_prevented = self.run_triggered();
        let named_prevented = self.run_named_input_delegates(&event);
        if allowed
            && !wasm_prevented
            && !named_prevented
            && event_type == "click"
            && session_scope.is_none()
        {
            if let Some(menu) = hover_id
                .as_deref()
                .and_then(|id| find_node_by_id(&self.dom, id))
                .and_then(|n| n.get_attribute("data-menu-link").map(str::to_string))
            {
                let _ = self.select_menu(&menu);
            }
        }
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
        let wasm_prevented = self.run_triggered();
        let named_prevented = self.run_named_input_delegates(&event);
        Ok(allowed && !wasm_prevented && !named_prevented)
    }

    fn run_triggered(&mut self) -> bool {
        let mut prevented = false;
        for (id, event) in self.event_host.take_triggered() {
            match self.listeners_run(id, event) {
                Ok(p) => prevented |= p,
                Err(e) => self.diagnostics.push(format!("EVENT-RUN-ERROR {id}: {e}")),
            }
        }
        prevented
    }

    fn listeners_run(&mut self, id: u64, event: Event) -> Result<bool, String> {
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
                Ok(false)
            }
            Some(Listener::Wasm {
                function_index,
                handle,
            }) => match self.wasm_ui {
                Some(ref mut ui) => {
                    match ui.call_listener(
                        crate::browser::UiBorrow {
                            dom: &mut self.dom,
                            router: &self.program.router,
                            spec: &self.spec,
                            timers: &mut self.timers,
                            now_ns: self.now_ns,
                            store: Some(&mut self.program.store),
                            hw: Some(&mut self.hw),
                        },
                        function_index,
                        handle,
                        &event,
                    ) {
                        Ok(call) => {
                            self.diagnostics.extend(call.diagnostics);
                            self.apply_hw_support();
                            self.diagnostics.push(format!(
                                "EVENT-WASM-TRIGGERED {id} results={}",
                                call.results.len()
                            ));
                            Ok(call.default_prevented)
                        }
                        Err(e) => {
                            self.diagnostics.push(format!("EVENT-WASM-ERROR {id}: {e}"));
                            Ok(false)
                        }
                    }
                }
                None => {
                    self.diagnostics.push(format!(
                        "EVENT-WASM-NO-MODULE {id} fn={function_index} h={handle}"
                    ));
                    Ok(false)
                }
            },
            Some(Listener::Delegate { ctx, ptr }) => match self.wasm_ui {
                Some(ref mut ui) => {
                    match ui.call_js_callback(
                        crate::browser::UiBorrow {
                            dom: &mut self.dom,
                            router: &self.program.router,
                            spec: &self.spec,
                            timers: &mut self.timers,
                            now_ns: self.now_ns,
                            store: Some(&mut self.program.store),
                            hw: Some(&mut self.hw),
                        },
                        ctx,
                        ptr,
                        &event,
                    ) {
                        Ok(call) => {
                            self.diagnostics.extend(call.diagnostics);
                            self.apply_hw_support();
                            self.diagnostics
                                .push(format!("EVENT-DELEGATE-TRIGGERED {id} ctx={ctx} ptr={ptr}"));
                            Ok(call.default_prevented)
                        }
                        Err(e) => {
                            self.diagnostics
                                .push(format!("EVENT-DELEGATE-ERROR {id}: {e}"));
                            Ok(false)
                        }
                    }
                }
                None => {
                    self.diagnostics
                        .push(format!("EVENT-DELEGATE-NO-MODULE {id} ctx={ctx} ptr={ptr}"));
                    Ok(false)
                }
            },
            Some(Listener::Cell) => {
                self.cell_click(&event)?;
                self.diagnostics.push(format!("EVENT-CELL-TRIGGERED {id}"));
                Ok(true)
            }
            None => Ok(false),
        }
    }

    /// Named `exportDelegate` whose name is an input event (`click`, `onclick`,
    /// `keydown`, …). virtio-input / UI-hart events re-enter through
    /// `jsCallback`. Unknown names (`navigate_to`, `onReady`) stay callNative.
    fn run_named_input_delegates(&mut self, event: &Event) -> bool {
        let names: Vec<(String, i32, i32)> = match self.wasm_ui.as_ref() {
            Some(ui) => ui
                .persist
                .named_delegates
                .iter()
                .filter(|(n, _)| named_delegate_matches_event(n, &event.event_type))
                .map(|(n, &(ctx, ptr))| (n.clone(), ctx, ptr))
                .collect(),
            None => return false,
        };
        let mut prevented = false;
        for (name, ctx, ptr) in names {
            let Some(mut ui) = self.wasm_ui.take() else {
                break;
            };
            let fired = ui.call_js_callback(
                crate::browser::UiBorrow {
                    dom: &mut self.dom,
                    router: &self.program.router,
                    spec: &self.spec,
                    timers: &mut self.timers,
                    now_ns: self.now_ns,
                    store: Some(&mut self.program.store),
                    hw: Some(&mut self.hw),
                },
                ctx,
                ptr,
                event,
            );
            self.wasm_ui = Some(ui);
            match fired {
                Ok(call) => {
                    self.diagnostics.extend(call.diagnostics);
                    self.apply_hw_support();
                    self.diagnostics
                        .push(format!("EVENT-NAMED-DELEGATE {name} ctx={ctx} ptr={ptr}"));
                    prevented |= call.default_prevented;
                }
                Err(e) => self
                    .diagnostics
                    .push(format!("EVENT-NAMED-DELEGATE-ERROR {name}: {e}")),
            }
        }
        prevented
    }

    /// Cell protocol for tab/refresh clicks (B87). preventDefault is implied
    /// so href navigation and the Rust default `select_menu` do not double-run.
    fn cell_click(&mut self, event: &Event) -> Result<(), String> {
        let Some(id) = event.target.as_deref() else {
            return Ok(());
        };
        if id == "refresh" {
            self.refresh()?;
            self.paint_status("UI-BOOT: values refreshed; read-only setup");
            return Ok(());
        }
        let menu = find_node_by_id(&self.dom, id)
            .and_then(|n| n.get_attribute("data-menu-link").map(str::to_string));
        let Some(menu) = menu else {
            return Ok(());
        };
        self.select_menu(&menu)?;
        if self.spec.kernel.http.enable && self.spec.kernel.http.proxy_js {
            let url = format!("/bios/menu/{menu}");
            let response = self.program.router.fetch_get(&url);
            if response.status == 200 {
                paint_response(&mut self.dom, &url, &response.body_str())?;
            }
        }
        self.paint_status(&format!("UI-BOOT: {menu} menu; read-only setup"));
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
            // Tablet is the next DeviceID 18 after the keyboard (QEMU
            // pointer / VNC). Guest `InpInit` takes the first slot for VGA
            // `DomNav`; `TabInit` takes the second. The exec model leaves
            // virtio-mmio slot 2 empty so PLIC irq 3 stays the mailbox.
            a.push("-device".into());
            a.push("virtio-tablet-device".into());
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
    p.store = g6b_pglite::StoreRegistry::from_spec(spec);
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
            p.store = g6b_pglite::StoreRegistry::from_spec(spec);
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

/// High-res RGBA display-proxy PPM: the modern `render32` lane scaled to the
/// proxy output geometry, suitable for a virtio-gpu / high-DPI scanout preview.
pub fn proxy_ppm32(spec: &BoardSpec) -> Result<Vec<u8>, String> {
    let p = g6b_gr::proxy::Proxy::from_spec(spec);
    // On the GPU surface the page is rendered at the scanout geometry, so
    // nothing is magnified; on VGA it keeps the low-res plane and the proxy
    // scales it, matching `proxy_ppm`.
    let out = if p.surface == g6b_spec::Surface::Gpu {
        let o = p.output();
        return Ok(ui_ppm32_output_at(spec, o.w, o.h)?
            .canvas
            .to_ppm_over([0, 0, 0]));
    } else {
        ui_ppm32_output(spec)?
    };
    let mut dom = rendered_dom(spec);
    let status = dom
        .get_element_by_id("status")
        .map(|n| n.inner_text())
        .unwrap_or_default();
    Ok(p.to_ppm32(&out.canvas, &format!("DOM status={status}")))
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

/// Stylesheet for the live engine: shell `<style>` + `/ui/bios-ui.css` +
/// any `<style>` nodes the cell injected via `add_css`. Not an HTML document.
fn live_css(dom: &Node, spec: &BoardSpec) -> Result<String, String> {
    let shell = if libwasm_lane(spec) {
        g6b_ui::setup_html_libwasm(spec, "/ui/ui-libwasm.wasm")
    } else {
        g6b_ui::setup_html(spec)
    };
    let mut css = extract_style(&shell);
    collect_style_text(dom, &mut css);
    if spec.kernel.http.files.enable {
        let css_path = format!(
            "{}/bios-ui.css",
            spec.kernel.http.files.root.trim_end_matches('/')
        );
        let resp = g6b_http::Router::from_spec(spec).fetch_get(&css_path);
        if resp.status == 200 {
            css.push('\n');
            css.push_str(&resp.body_str());
        }
    }
    Ok(css)
}

fn collect_style_text(node: &Node, out: &mut String) {
    if node.name.eq_ignore_ascii_case("style") {
        let text = node.inner_text();
        if !text.is_empty() {
            out.push('\n');
            out.push_str(&text);
        }
    }
    for child in &node.children {
        collect_style_text(child, out);
    }
}

/// Visual root for `Engine::paint`: the LDC cell's `<main>` under
/// `#libwasm-spa` when present, otherwise the document `<body>`.
fn live_paint_root(dom: &Node) -> &Node {
    if let Some(spa) = find_node_by_id(dom, "libwasm-spa") {
        if let Some(main) = first_descendant_by_name(spa, "main") {
            return main;
        }
    }
    first_descendant_by_name(dom, "body").unwrap_or(dom)
}

fn node_has_id(node: &Node, id: &str) -> bool {
    node.id.as_deref() == Some(id) || node.children.iter().any(|c| node_has_id(c, id))
}

/// Cell `<main>` plus shell chrome the Svelte tree does not own yet
/// (`#disp-toggle` / `#disp-status`). Window/tab chrome is Svelte.
fn live_paint_targets(dom: &Node) -> Vec<&Node> {
    let root = live_paint_root(dom);
    let mut out = vec![root];
    for id in ["disp-toggle", "disp-status", "win-open", "bios-window-0"] {
        if node_has_id(root, id) {
            continue;
        }
        if let Some(n) = find_node_by_id(dom, id) {
            out.push(n);
        }
    }
    out
}

fn remap_hit_paths(dom: &Node, hits: &mut [g6b_css::render::HitBox]) {
    for hit in hits {
        if let Some(id) = hit.id.as_deref() {
            if let Some(path) = path_to_id(dom, id) {
                hit.path = path;
            }
        }
    }
}

/// Host PPM of the setup page (SysGrInit rewrite).
pub fn gr_ppm(spec: &BoardSpec) -> Vec<u8> {
    let mut frame = g6b_gr::Frame::from_spec(spec);
    let dom = rendered_dom(spec);
    frame.paint_lines(&to_uart_lines(&dom, frame.cols as usize));
    frame.to_ppm()
}

/// 16-colour PPM of the setup page. Same live [`Engine::paint`] as
/// [`ui_ppm32`]; RGBA flattens over white then nearest-PALETTE. Not an HTML
/// serialize/parse CSS lane. `g6b_css::render` stays for `css_golden` fixtures.
pub fn ui_ppm(spec: &BoardSpec) -> Result<Vec<u8>, String> {
    Ok(ui_ppm_output(spec)?.canvas.to_ppm())
}

/// 16-colour raster plus the Engine hit boxes (same ids as the 32-bit path).
pub fn ui_ppm_output(spec: &BoardSpec) -> Result<g6b_css::render::RenderOutput, String> {
    let out = ui_ppm32_output(spec)?;
    Ok(g6b_css::render::RenderOutput {
        canvas: out.canvas.to_canvas(),
        hit_boxes: out.hit_boxes,
    })
}

/// Modern RGBA CSS-raster PPM of the setup page. Uses `g6b_css::render32`
/// with the default bundled font set and an empty asset map (assets are a
/// future `files.assets` mount). This is the track-A true-colour lane from
/// `architecture/RENDER-VALIDATION.md`.
pub fn ui_ppm32(spec: &BoardSpec) -> Result<Vec<u8>, String> {
    Ok(ui_ppm32_output(spec)?.canvas.to_ppm())
}

/// LDC cell ran on the UI-thread [`Host`] (`KernelHost`), then packed for
/// guest dirty-tile `VioPaint`. Exec-model S-mode stand-in: same import set
/// as `BrowserSession` (DOM, CSS paint, GLES2 `u_dom`, events, throw/await),
/// not `start_ops` `Object_Call`.
pub struct GuestCellScanout {
    pub present: g6b_asm::exec::GuestWebPresent,
    pub wasm_executed: bool,
    pub diagnostics: Vec<String>,
    /// `App_svelte.fetchBios` interned on the persistent `WasmUi`.
    pub fetch_bios: bool,
    /// `libwasm_global("window")` survived `_start`.
    pub window_interned: bool,
    /// GLES2 `u_dom` composite ran (CPU raster remains truth).
    pub gl_presented: bool,
}

/// Pack the live BrowserSession canvas + dirty tiles for guest `__ui_cap`.
/// The guest `VioPaint` TRANSFERs those rects; `start_ops` is not grown.
/// Canvas is placed at (0,0) in the output-stride `__scan_fb` so a 640×480
/// engine raster still TRANSFERs correctly into a 1920×1080 resource.
pub fn guest_web_present(spec: &BoardSpec) -> Result<g6b_asm::exec::GuestWebPresent, String> {
    Ok(guest_cell_scanout(spec)?.present)
}

/// One interactive step on a persistent svelte-d [`BrowserSession`] before
/// packing for guest `VioPaint`. Keyboard / hover / JS await are the BIOS
/// UI contract (`kernel.ts` + `App.svelte`); they must not go through
/// `start_ops`.
#[derive(Clone, Debug)]
pub enum GuestCellAction<'a> {
    Tick(u64),
    ClickMenu(&'a str),
    /// Pointer click on a live node id (`#refresh`, `#disp-toggle`, …).
    ClickId(&'a str),
    HoverMenu(&'a str),
    Key(&'a str),
    /// Bounded JS `await fetch` + `throw`/`catch` on the same session.
    AwaitFetch(&'a str),
}

/// Run the svelte-d LDC cell through [`KernelHost`] (same `Host` import set
/// as the UI thread), drain a UI-hart tick (await / CSS / GLES2 `u_dom`),
/// then pack scanout. Fails if the cell did not execute.
pub fn guest_cell_scanout(spec: &BoardSpec) -> Result<GuestCellScanout, String> {
    guest_cell_drive(spec, &[])
}

/// Same as [`guest_cell_scanout`], then a pointer click on `tab-{menu}` so
/// cell-owned events + JSON + CSS restyle reach guest `VioPaint`.
pub fn guest_cell_click(spec: &BoardSpec, menu: &str) -> Result<GuestCellScanout, String> {
    guest_cell_drive(spec, &[GuestCellAction::ClickMenu(menu)])
}

/// Keyboard (F10 / arrows) on the live svelte-d session, then pack.
pub fn guest_cell_key(spec: &BoardSpec, key: &str) -> Result<GuestCellScanout, String> {
    guest_cell_drive(spec, &[GuestCellAction::Key(key)])
}

/// Persistent svelte-d session the exec model holds across guest UART `Ui`.
/// Implements [`g6b_asm::exec::WebFeed`]: each `Ui` is a UI-hart tick + pack.
pub struct GuestCellLive {
    spec: BoardSpec,
    session: BrowserSession,
    now_ns: u64,
    /// Last tablet/mouse position in CSS canvas pixels (B91b `EV_ABS`/`EV_REL`).
    ptr_x: i32,
    ptr_y: i32,
}

impl GuestCellLive {
    /// Load the LDC cell on [`KernelHost`]. Fails if `_start` did not run.
    pub fn open(spec: &BoardSpec) -> Result<Self, String> {
        let mut session = BrowserSession::new(spec)?;
        if !session.wasm_executed {
            return Err("LDC libwasm cell did not run on KernelHost".into());
        }
        let _ = session.tick(0)?;
        Ok(Self {
            spec: spec.clone(),
            session,
            now_ns: 0,
            ptr_x: 0,
            ptr_y: 0,
        })
    }

    /// Apply BIOS-UI actions on this instance (`_start` is not re-run).
    pub fn apply(&mut self, actions: &[GuestCellAction<'_>]) -> Result<(), String> {
        for action in actions {
            match *action {
                GuestCellAction::Tick(t) => {
                    self.now_ns = t;
                    let _ = self.session.tick(t)?;
                }
                GuestCellAction::ClickMenu(menu) => {
                    let (x, y) = tab_hit(&mut self.session, menu)?;
                    self.ptr_x = x;
                    self.ptr_y = y;
                    let _ = self.session.dispatch_pointer(x, y, "click", menu)?;
                    self.now_ns = self.now_ns.saturating_add(1);
                    let _ = self.session.tick(self.now_ns)?;
                }
                GuestCellAction::ClickId(id) => {
                    let (x, y) = id_hit(&mut self.session, id)?;
                    self.ptr_x = x;
                    self.ptr_y = y;
                    let _ = self.session.dispatch_pointer(x, y, "click", "")?;
                    self.now_ns = self.now_ns.saturating_add(1);
                    let _ = self.session.tick(self.now_ns)?;
                }
                GuestCellAction::HoverMenu(menu) => {
                    let (x, y) = tab_hit(&mut self.session, menu)?;
                    self.ptr_x = x;
                    self.ptr_y = y;
                    let _ = self.session.dispatch_pointer(x, y, "mousemove", "")?;
                }
                GuestCellAction::Key(key) => {
                    let _ = self.session.handle_key(key)?;
                    if let Some(path) = path_to_id(
                        &self.session.dom,
                        &format!("tab-{}", self.session.selected_menu),
                    ) {
                        let _ = self.session.dispatch_key(&path, key, "keydown")?;
                    }
                    self.now_ns = self.now_ns.saturating_add(1);
                    let _ = self.session.tick(self.now_ns)?;
                }
                GuestCellAction::AwaitFetch(url) => {
                    let src = format!(
                        r#"document.getElementById("status").textContent="pending"; try {{ await fetch("{url}"); document.getElementById("status").textContent="done"; }} catch (e) {{ document.getElementById("status").textContent="caught"; }}"#
                    );
                    let _ = self.session.enqueue_async_script(&src)?;
                    self.now_ns = self.now_ns.saturating_add(1);
                    let _ = self.session.tick(self.now_ns)?;
                }
            }
        }
        Ok(())
    }

    /// GLES2 present + pack for guest `__ui_cap`.
    pub fn finish(&mut self) -> Result<GuestCellScanout, String> {
        finish_guest_cell(&self.spec, &mut self.session, self.now_ns)
    }

    fn clamp_ptr(&mut self) {
        let (w, h) = canvas_wh(&self.spec);
        self.ptr_x = self.ptr_x.clamp(0, w.saturating_sub(1));
        self.ptr_y = self.ptr_y.clamp(0, h.saturating_sub(1));
    }

    fn pointer_move(&mut self) -> Option<g6b_asm::exec::GuestWebPresent> {
        let _ = self.session.render_hit_boxes();
        match self
            .session
            .dispatch_pointer(self.ptr_x, self.ptr_y, "mousemove", "")
        {
            Ok(_) => self.finish().ok().map(|c| c.present),
            Err(_) => None,
        }
    }

    fn pointer_click(&mut self) -> Option<g6b_asm::exec::GuestWebPresent> {
        let _ = self.session.render_hit_boxes();
        match self
            .session
            .dispatch_pointer(self.ptr_x, self.ptr_y, "click", "")
        {
            Ok(_) => {
                self.now_ns = self.now_ns.saturating_add(1);
                let _ = self.session.tick(self.now_ns);
                self.finish().ok().map(|c| c.present)
            }
            Err(_) => None,
        }
    }
}

impl g6b_asm::exec::WebFeed for GuestCellLive {
    fn initial(&mut self) -> Option<g6b_asm::exec::GuestWebPresent> {
        self.finish().ok().map(|c| c.present)
    }

    fn on_guest_ui(&mut self) -> Option<g6b_asm::exec::GuestWebPresent> {
        self.now_ns = self.now_ns.saturating_add(1_000_000);
        self.finish().ok().map(|c| c.present)
    }

    fn on_guest_key(&mut self, code: u16, pressed: bool) -> Option<g6b_asm::exec::GuestWebPresent> {
        if !pressed {
            return None;
        }
        use g6b_asm::vio::{
            VIO_BTN_LEFT, VIO_KEY_DOWN, VIO_KEY_END, VIO_KEY_ENTER, VIO_KEY_F10, VIO_KEY_HOME,
            VIO_KEY_LEFT, VIO_KEY_RIGHT, VIO_KEY_UP,
        };
        let code = i64::from(code);
        if code == VIO_BTN_LEFT {
            return self.pointer_click();
        }
        if code == VIO_KEY_ENTER {
            let menu = self.session.selected_menu.clone();
            let _ = self.apply(&[GuestCellAction::ClickMenu(&menu)]);
            return self.finish().ok().map(|c| c.present);
        }
        let key = match code {
            VIO_KEY_LEFT | VIO_KEY_UP => "ArrowLeft",
            VIO_KEY_RIGHT | VIO_KEY_DOWN => "ArrowRight",
            VIO_KEY_HOME => "Home",
            VIO_KEY_END => "End",
            VIO_KEY_F10 => "F10",
            _ => return None,
        };
        let _ = self.apply(&[GuestCellAction::Key(key)]);
        self.finish().ok().map(|c| c.present)
    }

    fn on_guest_abs(&mut self, axis: u16, value: u32) -> Option<g6b_asm::exec::GuestWebPresent> {
        use g6b_asm::vio::{VIO_ABS_X, VIO_ABS_Y};
        let (w, h) = canvas_wh(&self.spec);
        match i64::from(axis) {
            VIO_ABS_X => self.ptr_x = abs_to_px(value, w),
            VIO_ABS_Y => self.ptr_y = abs_to_px(value, h),
            _ => return None,
        }
        self.clamp_ptr();
        self.pointer_move()
    }

    fn on_guest_rel(&mut self, axis: u16, value: i32) -> Option<g6b_asm::exec::GuestWebPresent> {
        use g6b_asm::vio::{VIO_REL_X, VIO_REL_Y};
        match i64::from(axis) {
            VIO_REL_X => self.ptr_x = self.ptr_x.saturating_add(value),
            VIO_REL_Y => self.ptr_y = self.ptr_y.saturating_add(value),
            _ => return None,
        }
        self.clamp_ptr();
        self.pointer_move()
    }

    fn hint_abs(&self) -> Option<(u32, u32)> {
        let skip = format!("tab-{}", self.session.selected_menu);
        let hit = self.session.hit_boxes.iter().find(|h| {
            h.id.as_deref()
                .is_some_and(|id| id.starts_with("tab-") && id != skip)
                && h.w > 0
                && h.h > 0
        })?;
        let (w, h) = canvas_wh(&self.spec);
        Some((
            px_to_abs(hit.x + hit.w / 2, w),
            px_to_abs(hit.y + hit.h / 2, h),
        ))
    }

    fn on_guest_tick(&mut self) -> Option<g6b_asm::exec::GuestWebPresent> {
        self.now_ns = self
            .now_ns
            .saturating_add(crate::timers::frame_period_ns(&self.spec));
        let t = self.session.tick(self.now_ns).ok()?;
        if !t.dirty {
            return None;
        }
        let _ = self.session.present_gl();
        let present = pack_guest_present(&self.spec, &self.session);
        if present.tiles.is_empty() {
            None
        } else {
            Some(present)
        }
    }
}

/// Drive a **persistent** `WasmUi` with BIOS-UI actions, then GLES2 present
/// + pack. One session: `_start` is not re-run between steps.
pub fn guest_cell_drive(
    spec: &BoardSpec,
    actions: &[GuestCellAction<'_>],
) -> Result<GuestCellScanout, String> {
    let mut live = GuestCellLive::open(spec)?;
    live.apply(actions)?;
    live.finish()
}

fn tab_hit(session: &mut BrowserSession, menu: &str) -> Result<(i32, i32), String> {
    id_hit(session, &format!("tab-{menu}"))
}

fn id_hit(session: &mut BrowserSession, id: &str) -> Result<(i32, i32), String> {
    session.render_hit_boxes()?;
    session
        .hit_boxes
        .iter()
        .find(|h| h.id.as_deref() == Some(id) && h.w > 0 && h.h > 0)
        .map(|h| (h.x + h.w / 2, h.y + h.h / 2))
        .ok_or_else(|| format!("no hit box for {id}"))
}

fn canvas_wh(spec: &BoardSpec) -> (i32, i32) {
    (
        spec.kernel.gr.w.max(320) as i32,
        spec.kernel.gr.h.max(200) as i32,
    )
}

/// QEMU tablet: `px = value * (dim-1) / ABS_MAX`.
fn abs_to_px(value: u32, dim: i32) -> i32 {
    let span = dim.max(1).saturating_sub(1).max(1) as u32;
    ((u64::from(value) * u64::from(span)) / u64::from(g6b_asm::vio::VIO_ABS_MAX.max(1))) as i32
}

fn px_to_abs(px: i32, dim: i32) -> u32 {
    let span = dim.max(1).saturating_sub(1).max(1) as u32;
    let px = px.clamp(0, dim.saturating_sub(1)) as u32;
    ((u64::from(px) * u64::from(g6b_asm::vio::VIO_ABS_MAX)) / u64::from(span)) as u32
}

fn finish_guest_cell(
    spec: &BoardSpec,
    session: &mut BrowserSession,
    now_ns: u64,
) -> Result<GuestCellScanout, String> {
    if !session.wasm_executed {
        return Err("LDC libwasm cell did not run on KernelHost".into());
    }
    let _ = session.tick(now_ns)?;
    let _ = session.paint_css()?;
    let gl = session.present_gl()?;
    let gl_presented = gl.starts_with(b"P6\n") || gl.starts_with(b"P3\n");
    let fetch_bios = session
        .wasm_ui
        .as_ref()
        .map(|ui| ui.has_fetch_bios())
        .unwrap_or(false);
    let window_interned = session
        .wasm_ui
        .as_ref()
        .and_then(|ui| ui.window())
        .is_some();
    Ok(GuestCellScanout {
        present: pack_guest_present(spec, session),
        wasm_executed: session.wasm_executed,
        diagnostics: session.diagnostics.clone(),
        fetch_bios,
        window_interned,
        gl_presented,
    })
}

fn pack_guest_present(
    spec: &BoardSpec,
    session: &BrowserSession,
) -> g6b_asm::exec::GuestWebPresent {
    let out = spec.default_output();
    let dw = out.w.max(session.scan_fb_w.max(1));
    let dh = out.h.max(session.scan_fb_h.max(1));
    let mut packed = vec![0u8; (dw as usize).saturating_mul(dh as usize).saturating_mul(4)];
    let sw = session.scan_fb_w.max(1);
    let sh = session.scan_fb_h;
    for y in 0..sh.min(dh) {
        let src = (y.saturating_mul(sw) * 4) as usize;
        let dst = (y.saturating_mul(dw) * 4) as usize;
        let n = (sw.min(dw) as usize).saturating_mul(4);
        if src + n <= session.scan_fb.len() && dst + n <= packed.len() {
            packed[dst..dst + n].copy_from_slice(&session.scan_fb[src..src + n]);
        }
    }
    let mut tiles: Vec<g6b_asm::exec::DirtyTile> = session
        .last_tiles()
        .iter()
        .map(|t| g6b_asm::exec::DirtyTile {
            x: t.x,
            y: t.y,
            w: t.w,
            h: t.h,
        })
        .collect();
    // Skip-if-clean on the host means no *new* dirty rects. A cold guest
    // framebuffer still needs one TRANSFER of the live CSS canvas.
    if tiles.is_empty() && sw > 0 && sh > 0 && packed.iter().any(|&b| b != 0) {
        tiles.push(g6b_asm::exec::DirtyTile {
            x: 0,
            y: 0,
            w: sw.min(dw) as i32,
            h: sh.min(dh) as i32,
        });
    }
    g6b_asm::exec::GuestWebPresent {
        scan_fb: packed,
        tiles,
        node_count: count_dom_nodes(&session.dom),
    }
}

fn count_dom_nodes(n: &Node) -> u32 {
    1 + n.children.iter().map(count_dom_nodes).sum::<u32>()
}

/// Modern RGBA output including hit boxes for event dispatch.
pub fn ui_ppm32_output(spec: &BoardSpec) -> Result<g6b_css::render32::Render32Output, String> {
    ui_ppm32_output_at(spec, spec.kernel.gr.w.max(320), spec.kernel.gr.h.max(200))
}

/// Modern RGBA output at an explicit canvas geometry. The GPU-surface path
/// renders the page **at the scanout's own resolution** instead of upscaling
/// the 640x480 plane, which is the whole point of the surface split.
pub fn ui_ppm32_output_at(
    spec: &BoardSpec,
    w: u32,
    h: u32,
) -> Result<g6b_css::render32::Render32Output, String> {
    let mut session = BrowserSession::new(spec)?;
    session.paint_css_at(w.max(320), h.max(200))
}

/// PNG/SVG files the kernel HTTP mount exposes, keyed by their `/ui/…` path.
fn session_assets(spec: &BoardSpec) -> g6b_css::AssetMap {
    let items = g6b_http::files::image_files(spec);
    g6b_css::load_assets(items.iter().map(|(p, b)| (p.as_str(), b.as_slice()))).unwrap_or_default()
}

/// goosie hover: one `data-hover="1"` marker the CSS `:hover` matcher reads.
/// Every node with that `id` is marked so a duplicate static shell + LDC
/// cell tree both restyle; `Engine::paint` then sees hover on the painted root.
fn set_hover_attr(root: &mut Node, id: Option<&str>, session_scope: Option<usize>) {
    fn clear(n: &mut Node) {
        if n.attributes.contains_key("data-hover") {
            n.remove_attribute("data-hover");
        }
        for c in &mut n.children {
            clear(c);
        }
    }
    fn mark(n: &mut Node, id: &str) {
        if n.id.as_deref() == Some(id) {
            let _ = n.set_attribute("data-hover", "1");
        }
        for c in &mut n.children {
            mark(c, id);
        }
    }
    clear(root);
    if let Some(id) = id {
        if let Some(slot) = session_scope {
            if let Some(stage) = find_node_by_id_mut(root, &format!("bios-session-{slot}")) {
                mark(stage, id);
            }
        } else {
            mark(root, id);
        }
    }
}

fn find_node_by_id_mut<'a>(node: &'a mut Node, id: &str) -> Option<&'a mut Node> {
    if node.id.as_deref() == Some(id) {
        return Some(node);
    }
    let n = node.children.len();
    for i in 0..n {
        // Index then recurse so the borrow of children[i] does not overlap.
        if find_node_by_id(&node.children[i], id).is_some() {
            return find_node_by_id_mut(&mut node.children[i], id);
        }
    }
    None
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
    fn qemu_argv_full_outbound_is_not_netdev() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        assert!(spec.kernel.http.outbound);
        assert!(spec.wants_virtio_net());
        let argv = qemu_dual_band_argv(&spec).join(" ");
        assert!(
            !argv.contains("-netdev"),
            "outbound fetch is not a QEMU NIC: {argv}"
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
    fn interned_event_has_coords_and_prevent_default() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let mut session = BrowserSession::new(&spec).unwrap();
        let mut host = KernelHost::attach_fresh(
            &mut session.dom,
            &session.program.router,
            &spec,
            Vec::new(),
            &mut session.timers,
            0,
            Some(&mut session.program.store),
        );
        let mut ev = Event::new("click", EventInit::default());
        ev.client_x = 12;
        ev.client_y = 34;
        ev.target = Some("tab-cpu".into());
        let h = host.intern_event(&ev).unwrap();
        let v = host.get_libwasm_value(h).unwrap();
        assert_eq!(v.clone_prop("clientX").unwrap(), LibwasmValue::I32(12));
        assert_eq!(v.clone_prop("clientY").unwrap(), LibwasmValue::I32(34));
        assert_eq!(
            v.clone_prop("target").unwrap(),
            LibwasmValue::String("tab-cpu".into())
        );
        host.object_call(h, "preventDefault", &[]).unwrap();
        assert!(host.last_prevent_default);
        let v = host.get_libwasm_value(h).unwrap();
        assert_eq!(
            v.clone_prop("defaultPrevented").unwrap(),
            LibwasmValue::Bool(true)
        );

        let hw = Event::new("hwcable", EventInit::default());
        let h = host.intern_event(&hw).unwrap();
        let v = host.get_libwasm_value(h).unwrap();
        match v {
            LibwasmValue::Object { kind, props } => {
                assert_eq!(kind, ObjectKind::HwEvent);
                assert_eq!(
                    props.get("constructor"),
                    Some(&LibwasmValue::String("HWEvent".into()))
                );
            }
            other => panic!("{other:?}"),
        }
        host.object_call(h, "preventDefault", &[]).unwrap();
        assert!(host.last_prevent_default);
    }

    #[test]
    fn holyc_hw_returns_instantly_and_does_not_write_dom_ids() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let mut session = BrowserSession::new(&spec).unwrap();
        assert!(!session.hw.listening());
        assert!(!session.frames.outbound());
        assert_eq!(session.surface, g6b_spec::Surface::Vga);
        match session
            .holyc_request(r#"HwConfig("net0","static","not-an-ip");"#)
            .unwrap()
        {
            ReplResult::Output(s) => {
                assert!(s.contains("HW-ERR"), "{s}");
                assert!(s.contains("HW-STAT"), "{s}");
            }
            other => panic!("HolyC must return instantly, got {other:?}"),
        }
        assert!(session.hw.listening());
        assert!(
            session.diagnostics.iter().any(|d| d.contains("VIRTIO-NET")),
            "{:?}",
            session.diagnostics
        );
        assert!(
            session.diagnostics.iter().any(|d| d.contains("HW-EVENT")),
            "{:?}",
            session.diagnostics
        );
        // Kernel announced; it does not paint #hw-nat-status itself.
        if let Some(n) = session.dom.get_element_by_id("hw-nat-status") {
            assert!(
                n.inner_text().is_empty() || n.inner_text() == "hw idle",
                "{}",
                n.inner_text()
            );
        }
    }

    fn jscallback_probe_module() -> g6b_wasm::Module {
        use g6b_wasm::{Element, Export, FuncType, Instr, Module, Table, ValType};
        let mut mem = vec![0u8; 65536];
        mem[0..5].copy_from_slice(b"click");
        Module {
            types: vec![
                FuncType {
                    params: vec![ValType::I32, ValType::I32],
                    results: vec![],
                },
                FuncType {
                    params: vec![],
                    results: vec![],
                },
                FuncType {
                    params: vec![ValType::I32; 3],
                    results: vec![],
                },
            ],
            imports: vec![],
            func_types: vec![0, 1, 2],
            mem_pages: 1,
            max_mem_pages: Some(1),
            exports: vec![Export {
                name: "jsCallback".into(),
                kind: 0,
                idx: 2,
            }],
            bodies: vec![
                vec![
                    Instr::I32Const(1024),
                    Instr::I32Const(1),
                    Instr::I32Store {
                        align: 2,
                        offset: 0,
                    },
                    Instr::End,
                ],
                vec![Instr::End],
                vec![
                    Instr::LocalGet(0),
                    Instr::LocalGet(2),
                    Instr::LocalGet(1),
                    Instr::CallIndirect {
                        typeidx: 0,
                        tableidx: 0,
                    },
                    Instr::End,
                ],
            ],
            memory: mem,
            locals: vec![0, 0, 0],
            has_memory: true,
            tags: vec![],
            globals: vec![],
            tables: vec![Table {
                min: 2,
                max: Some(2),
            }],
            elements: vec![Element {
                offset: 1,
                funcs: vec![0],
            }],
            data_count: None,
            data_segments: vec![],
        }
    }

    fn install_jscallback_probe(session: &mut BrowserSession, named_click: bool) {
        let mut persist = session
            .wasm_ui
            .as_mut()
            .map(|ui| ui.take_persist())
            .unwrap_or_default();
        if named_click {
            persist.named_delegates.insert("click".into(), (99, 1));
        }
        session.wasm_ui = Some(crate::browser::WasmUi {
            module: jscallback_probe_module(),
            js_exports: g6b_wasm::JsExports::bios_app(),
            persist,
        });
    }

    #[test]
    fn virtio_click_reenters_jscallback_delegate() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let mut session = BrowserSession::new(&spec).unwrap();
        install_jscallback_probe(&mut session, false);
        session
            .add_event_listener_by_id(
                "tab-cpu",
                "click",
                false,
                Listener::Delegate { ctx: 99, ptr: 1 },
            )
            .unwrap();
        let (x, y) = tab_hit(&mut session, "cpu").unwrap();
        let _ = session.dispatch_pointer(x, y, "click", "cpu").unwrap();
        assert!(
            session
                .diagnostics
                .iter()
                .any(|d| d.contains("EVENT-DELEGATE-TRIGGERED")),
            "{:?}",
            session.diagnostics
        );
        assert!(
            session
                .diagnostics
                .iter()
                .any(|d| d.contains("EVENT-CELL-TRIGGERED")),
            "Listener::Cell fallback still runs: {:?}",
            session.diagnostics
        );
        let flag = i32::from_le_bytes(
            session.wasm_ui.as_ref().unwrap().module.memory[1024..1028]
                .try_into()
                .unwrap(),
        );
        assert_eq!(flag, 1, "jsCallback D delegate stored the event");
    }

    #[test]
    fn virtio_click_reenters_named_export_delegate() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let mut session = BrowserSession::new(&spec).unwrap();
        install_jscallback_probe(&mut session, true);
        let (x, y) = tab_hit(&mut session, "cpu").unwrap();
        let _ = session.dispatch_pointer(x, y, "click", "cpu").unwrap();
        assert!(
            session
                .diagnostics
                .iter()
                .any(|d| d.contains("EVENT-NAMED-DELEGATE click")),
            "{:?}",
            session.diagnostics
        );
        let flag = i32::from_le_bytes(
            session.wasm_ui.as_ref().unwrap().module.memory[1024..1028]
                .try_into()
                .unwrap(),
        );
        assert_eq!(flag, 1);
        assert!(
            session
                .diagnostics
                .iter()
                .any(|d| d.contains("EVENT-CELL-TRIGGERED")),
            "shipped-cell Cell path stays: {:?}",
            session.diagnostics
        );
    }

    #[test]
    fn b92_svelte_chrome_is_hidden_until_the_cell_opens_it() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let session = BrowserSession::new(&spec).unwrap();
        let win = find_node_by_id(&session.dom, "bios-window-0").expect("bios-window-0");
        assert!(win.hidden, "Svelte {{#if winOpen=false}} keeps the desktop");
        assert!(find_node_by_id(&session.dom, "win-open").is_some());
        assert_eq!(
            find_node_by_id(&session.dom, "status")
                .unwrap()
                .inner_text(),
            "UI-BOOT"
        );
        assert!(session.iframe_session(0).is_none());
        assert!(
            session
                .diagnostics
                .iter()
                .all(|d| !d.contains("WASM-WINDOW-LISTEN")),
            "{:?}",
            session.diagnostics
        );
    }

    #[test]
    fn b92_session_pool_ensure_drop_is_not_chrome() {
        assert_eq!(MAX_WINDOWS, 4);
        assert_eq!(MAX_TABS_PER_WINDOW, 8);
        assert_eq!(MAX_SESSIONS, 8);
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let mut session = BrowserSession::new(&spec).unwrap();
        session.ensure_iframe_session(0).unwrap();
        session.ensure_iframe_session(1).unwrap();
        assert_eq!(session.iframe_session(0).unwrap().location, "about:blank");
        assert_eq!(session.iframe_session(1).unwrap().location, "about:blank");
        let win = find_node_by_id(&session.dom, "bios-window-0").unwrap();
        assert!(win.hidden, "ensure does not open Svelte chrome");
        session.drop_iframe_session(0).unwrap();
        assert!(session.iframe_session(0).is_none());
        assert!(session.iframe_session(1).is_some());
        session.drop_all_iframe_sessions().unwrap();
        assert!(session.iframe_session(1).is_none());
        session.ensure_iframe_session(MAX_SESSIONS).unwrap();
        assert!(
            session
                .diagnostics
                .iter()
                .any(|d| d.contains("SESSION-BUDGET")),
            "{:?}",
            session.diagnostics
        );
        assert!(session.iframe_session(MAX_SESSIONS).is_none());
    }

    #[test]
    fn b92c_navigate_ui_html_200() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let mut session = BrowserSession::new(&spec).unwrap();
        session.ensure_iframe_session(0).unwrap();
        session.navigate_browser_tab(0, "/ui/help.html").unwrap();
        let doc = session.iframe_session(0).unwrap().document.clone();
        match &doc {
            SessionDocument::Page(p) => {
                assert_eq!(p.title.as_deref(), Some("Help"));
                assert!(p.text.contains("G6LC-BIOS help"), "{}", p.text);
            }
            other => panic!("expected Page, got {other:?}"),
        }
        let s = session.iframe_session(0).unwrap();
        assert_eq!(s.location, "/ui/help.html");
        assert_eq!(s.history, vec!["/ui/help.html"]);
        assert_eq!(s.load, SessionLoad::Http(200));
        assert!(s.document.paint_text().contains("G6LC-BIOS help"));
        assert_eq!(s.document.title(), Some("Help"));
    }

    #[test]
    fn b92c_srcdoc_skips_fetch_and_refuses_bios_remote() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"full","kernel":{"http":{"outbound":false}}}"#,
        )
        .unwrap();
        assert!(!spec.kernel.http.outbound);
        let mut session = BrowserSession::new(&spec).unwrap();
        session.ensure_iframe_session(0).unwrap();
        session
            .srcdoc_browser_tab(0, "<p id=\"x\">srcdoc</p>")
            .unwrap();
        assert_eq!(session.iframe_session(0).unwrap().location, "about:srcdoc");
        assert!(session
            .iframe_session(0)
            .unwrap()
            .document
            .paint_text()
            .contains("srcdoc"));
        session.navigate_browser_tab(0, "/bios/menu/cpu").unwrap();
        let s = session.iframe_session(0).unwrap();
        assert!(s.location.contains("/bios/menu/cpu"));
        assert!(s.load.status_word().contains("iframe cannot load /bios"));
        session
            .navigate_browser_tab(0, "https://example/path")
            .unwrap();
        let s = session.iframe_session(0).unwrap();
        assert_eq!(s.location, "https://example/path");
        assert!(s.load.status_word().contains("outbound fetch disabled"));
        session
            .navigate_browser_tab(0, "javascript:alert(1)")
            .unwrap();
        assert!(session
            .iframe_session(0)
            .unwrap()
            .load
            .status_word()
            .contains("refused"));
    }

    #[test]
    fn b92d_app_files_hook_mounts_filemgr_listing() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let mut session = BrowserSession::new(&spec).unwrap();
        session.ensure_iframe_session(0).unwrap();
        session.navigate_browser_tab(0, "app:files").unwrap();
        let doc = session.iframe_session(0).unwrap().document.clone();
        match &doc {
            SessionDocument::Files(f) => {
                assert!(!f.listing.is_empty(), "{}", f.listing);
                assert!(f.volumes.iter().any(|v| v.name == "fat32"));
            }
            other => panic!("expected Files, got {other:?}"),
        }
        let s = session.iframe_session(0).unwrap();
        assert_eq!(s.location, "app:files");
        assert_eq!(s.load, SessionLoad::Ok);
        assert_eq!(s.document.title(), Some("Files"));
        session.navigate_browser_tab(0, "/apps/files").unwrap();
        assert_eq!(session.iframe_session(0).unwrap().location, "app:files");
        session.navigate_browser_tab(0, "app:ssh").unwrap();
        assert!(session
            .iframe_session(0)
            .unwrap()
            .load
            .status_word()
            .contains("app: hook not registered"));
        assert!(
            session.diagnostics.iter().any(|d| d.contains("HOOK-FILES")),
            "{:?}",
            session.diagnostics
        );
    }

    #[test]
    fn b92e_guest_intern_is_not_shell() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let mut session = BrowserSession::new(&spec).unwrap();
        assert!(session.frame_content_window(0).is_none());
        assert!(session.frame_content_document(0).is_none());
        session.ensure_iframe_session(0).unwrap();
        let w = session.frame_content_window(0).expect("guest window");
        let d = session.frame_content_document(0).expect("guest document");
        assert_ne!(w, d);
        assert!(session.frame_owns_handle(0, w));
        assert!(session.frame_owns_handle(0, d));
        assert!(session
            .frame_js_exports(0)
            .unwrap()
            .lookup("App_svelte.fetchBios")
            .is_none());
        assert!(session.wasm_ui.as_ref().unwrap().has_fetch_bios());
        let ctx = session.iframe_session(0).unwrap().context.id();
        assert_ne!(ctx, SHELL_CONTEXT_ID);
        assert!(ctx.starts_with("frame-0-g"), "{ctx}");
        let g0 = session.iframe_session(0).unwrap().intern();
        session
            .srcdoc_browser_tab(0, "<p id=\"x\">srcdoc</p>")
            .unwrap();
        let g1 = session.iframe_session(0).unwrap().intern();
        assert_ne!(g0.generation, g1.generation);
        assert!(session.frame_native_import(0, "env.holyc").is_err());
        assert!(session.frame_native_import(0, "registerEndpoint").is_err());
        session.navigate_browser_tab(0, "app:files").unwrap();
        assert!(session.iframe_session(0).unwrap().caps.files_get);
        assert!(session.frame_native_import(0, "env.holyc").is_err());
        session.drop_all_iframe_sessions().unwrap();
        assert!(session.frame_content_window(0).is_none());
        assert!(session.frame_content_document(0).is_none());
    }

    #[test]
    fn b92_vars_map_interns_on_guest_window_including_remote_fail() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"full","kernel":{"http":{"outbound":false}}}"#,
        )
        .unwrap();
        let mut session = BrowserSession::new(&spec).unwrap();
        session.ensure_iframe_session(0).unwrap();
        let mut vars = SessionVars::new();
        assert!(vars.insert("greeting".into(), SessionVar::String("hello".into())));
        assert!(!vars.insert("eval".into(), SessionVar::String("nope".into())));
        session.set_iframe_vars(0, vars).unwrap();
        let w = session.frame_content_window(0).expect("guest window");
        assert!(session.frame_owns_handle(0, w));
        assert_eq!(
            session.frame_window_prop(0, "greeting"),
            Some(&LibwasmValue::String("hello".into()))
        );
        assert!(session.frame_window_prop(0, "eval").is_none());
        session
            .navigate_browser_tab(0, "https://example/path")
            .unwrap();
        assert!(session
            .iframe_session(0)
            .unwrap()
            .load
            .status_word()
            .contains("outbound"));
        assert_eq!(
            session.iframe_session(0).unwrap().vars.get("greeting"),
            Some(&SessionVar::String("hello".into()))
        );
        let _ = session.frame_content_window(0);
        assert_eq!(
            session.frame_window_prop(0, "greeting"),
            Some(&LibwasmValue::String("hello".into()))
        );
    }

    #[test]
    fn b92g_outbound_stubbed_get_is_page_deny_caps() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        assert!(spec.kernel.http.outbound);
        let mut session = BrowserSession::new(&spec).unwrap();
        session.ensure_iframe_session(0).unwrap();
        let mut vars = SessionVars::new();
        assert!(vars.insert("greeting".into(), SessionVar::String("hello".into())));
        session.set_iframe_vars(0, vars).unwrap();
        session.stub_outbound(
            "https://example/path",
            200,
            "<html><head><title>Ex</title></head><body><p>remote</p></body></html>",
        );
        session
            .navigate_browser_tab(0, "https://example/path")
            .unwrap();
        assert!(session
            .iframe_session(0)
            .unwrap()
            .load
            .status_word()
            .contains("outbound fetch disabled"));
        match session.holyc_request("HwStat();").unwrap() {
            ReplResult::Output(s) => assert!(s.contains("VIRTIO-NET"), "{s}"),
            other => panic!("{other:?}"),
        }
        assert!(session.frames.outbound());
        let doc = session.iframe_session(0).unwrap().document.clone();
        match &doc {
            SessionDocument::Page(p) => {
                assert_eq!(p.title.as_deref(), Some("Ex"));
                assert!(p.text.contains("remote"), "{}", p.text);
            }
            other => panic!("expected Page, got {other:?}"),
        }
        let s = session.iframe_session(0).unwrap();
        assert_eq!(s.location, "https://example/path");
        assert_eq!(s.load, SessionLoad::Http(200));
        assert!(s.caps.is_deny());
        assert!(session.frame_native_import(0, "env.holyc").is_err());
        assert!(session.frame_native_import(0, "registerEndpoint").is_err());
        let _ = session.frame_content_window(0);
        assert_eq!(
            session.frame_window_prop(0, "greeting"),
            Some(&LibwasmValue::String("hello".into()))
        );
        assert!(
            session
                .diagnostics
                .iter()
                .any(|d| d.contains("outbound") && d.contains("https://example/path")),
            "{:?}",
            session.diagnostics
        );
        session
            .navigate_browser_tab(0, "https://example/app.wasm")
            .unwrap();
        assert!(session
            .iframe_session(0)
            .unwrap()
            .load
            .status_word()
            .contains("remote wasm"));
        session.stub_outbound(
            "https://example/unstubbed",
            501,
            "outbound https: adapter TLS (g6b-tls ClientHello)",
        );
        session
            .navigate_browser_tab(0, "https://example/unstubbed")
            .unwrap();
        assert!(session
            .iframe_session(0)
            .unwrap()
            .load
            .status_word()
            .contains("HTTP 501"));
        assert!(session.iframe_session(0).unwrap().caps.is_deny());
        let argv = qemu_dual_band_argv(&spec).join(" ");
        assert!(!argv.contains("-netdev"), "{argv}");
        assert!(!argv.contains("virtio-net"), "{argv}");
    }

    fn serve_once(reply: Vec<u8>) -> (u16, std::thread::JoinHandle<()>) {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let handle = std::thread::spawn(move || {
            let Ok((mut s, _)) = listener.accept() else {
                return;
            };
            let mut buf = [0u8; 2048];
            let _ = s.read(&mut buf);
            let _ = s.write_all(&reply);
        });
        (port, handle)
    }

    #[test]
    fn kernel_http_get_lowers_to_hw_tcp() {
        let body =
            b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nhello-hw-tcp";
        let (port, th) = serve_once(body.to_vec());
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let mut session = BrowserSession::new(&spec).unwrap();
        let url = format!("http://127.0.0.1:{port}/hello");
        match session
            .holyc_request(&format!(r#"HttpGet("{url}");"#))
            .unwrap()
        {
            ReplResult::Output(s) => {
                assert!(s.contains("HTTP 200"), "{s}");
                assert!(s.contains("hello-hw-tcp"), "{s}");
            }
            other => panic!("{other:?}"),
        }
        assert!(
            session
                .diagnostics
                .iter()
                .any(|d| d.contains("KERNEL-FETCH http") && d.contains("via=hw-tcp")),
            "{:?}",
            session.diagnostics
        );
        assert!(
            session
                .diagnostics
                .iter()
                .any(|d| d.contains("KERNEL-FETCH-HTTP 200")),
            "{:?}",
            session.diagnostics
        );
        session.ensure_iframe_session(0).unwrap();
        let (port2, th2) = serve_once(body.to_vec());
        let url2 = format!("http://127.0.0.1:{port2}/iframe");
        session.navigate_browser_tab(0, &url2).unwrap();
        let s = session.iframe_session(0).unwrap();
        assert_eq!(s.load, SessionLoad::Http(200));
        assert!(s.document.paint_text().contains("hello-hw-tcp"));
        let _ = th.join();
        let _ = th2.join();
    }

    #[test]
    fn zealcli_vga_until_gpu_then_loadui() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        assert!(wants_zealcli(&spec, false));
        assert!(!wants_zealcli(&spec, true));
        let mut cli = ZealCli::new(&spec);
        assert!(cli.prompt().ends_with(ZEAL_PROMPT));
        let (a, _) = cli.eval("LoadUI");
        assert_eq!(a, ZealAction::LoadUi);
        match session_usb(&spec) {
            ReplResult::Output(s) => assert!(s.contains("USB") || s.contains("ok"), "{s}"),
            other => panic!("{other:?}"),
        }
    }

    fn session_usb(spec: &BoardSpec) -> ReplResult {
        let mut session = BrowserSession::new(spec).unwrap();
        session.holyc_request(r#"UsbKey("present");"#).unwrap()
    }

    #[test]
    fn kernel_https_get_lowers_to_hw_tcp_clienthello() {
        let rec = vec![0x16, 0x03, 0x03, 0x00, 0x01, 0x00];
        let (port, th) = serve_once(rec);
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let mut session = BrowserSession::new(&spec).unwrap();
        let url = format!("https://127.0.0.1:{port}/secure");
        match session
            .holyc_request(&format!(r#"HttpsGet("{url}");"#))
            .unwrap()
        {
            ReplResult::Output(s) => {
                assert!(s.contains("HTTP 501"), "{s}");
                assert!(s.contains("via=hw-tcp"), "{s}");
                assert!(s.contains("tls=handshake"), "{s}");
                assert!(!s.to_ascii_lowercase().contains("openssl"), "{s}");
            }
            other => panic!("{other:?}"),
        }
        assert!(
            session
                .diagnostics
                .iter()
                .any(|d| d.contains("KERNEL-FETCH https") && d.contains("via=hw-tcp")),
            "{:?}",
            session.diagnostics
        );
        assert!(
            session
                .diagnostics
                .iter()
                .any(|d| d.contains("KERNEL-FETCH-TLS handshake")),
            "{:?}",
            session.diagnostics
        );
        let _ = th.join();
    }

    #[test]
    fn shipped_ldc_cell_emits_g6b_listen_and_jscallback() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let mut session = BrowserSession::new(&spec).unwrap();
        let ui = session.wasm_ui.as_ref().expect("LDC WasmUi");
        assert!(
            g6b_wasm::export_func(&ui.module, "jsCallback").is_some(),
            "B91d cell exports jsCallback"
        );
        assert!(
            session
                .diagnostics
                .iter()
                .any(|d| d.contains("getRoot")
                    || d.contains("WASM-ADD-EVENT-LISTENER tab-cpu click")),
            "{:?}",
            session.diagnostics
        );
        assert!(
            session
                .diagnostics
                .iter()
                .any(|d| d.contains("WASM-ADD-EVENT-LISTENER") && d.contains("tab-cpu")),
            "cell g6b_listen: {:?}",
            session.diagnostics
        );
        assert!(
            session
                .diagnostics
                .iter()
                .all(|d| !d.contains("WASM-CELL-LISTEN")),
            "host bind_cell_clicks skipped: {:?}",
            session.diagnostics
        );
        let (x, y) = tab_hit(&mut session, "cpu").unwrap();
        let _ = session.dispatch_pointer(x, y, "click", "cpu").unwrap();
        assert!(
            session
                .diagnostics
                .iter()
                .any(|d| d.contains("EVENT-CELL-TRIGGERED")),
            "g6b_listen listener 0 is Cell: {:?}",
            session.diagnostics
        );
    }

    #[test]
    fn ui_thread_tick_and_js_exports() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let mut session = BrowserSession::new(&spec).unwrap();
        let t = session.tick(0).unwrap();
        let _ = t.presented;
        if let Some(ui) = session.wasm_ui.as_ref() {
            assert!(ui.has_fetch_bios());
        }
        assert_eq!(
            g6b_wasm::JsExports::bios_app().lookup("App_svelte.fetchBios"),
            Some(g6b_wasm::JsExportKind::FetchBios)
        );
        let router = g6b_http::Router::from_spec(&spec);
        assert!(router.has_file("/ui/bios-ui.css"));
        assert!(router
            .fetch_get("/ui/bios-ui.css")
            .body_str()
            .contains("bios-tab"));
        let gl = session.present_gl().unwrap();
        assert!(
            gl.starts_with(b"P6\n") || gl.starts_with(b"P3\n"),
            "GL present"
        );
        let mut host = KernelHost::attach_fresh(
            &mut session.dom,
            &session.program.router,
            &spec,
            Vec::new(),
            &mut session.timers,
            0,
            Some(&mut session.program.store),
        );
        let window = host.libwasm_global("window").unwrap();
        let document = host.libwasm_global("document").unwrap();
        let console = host.libwasm_global("console").unwrap();
        assert!(window >= g6b_wasm::OBJECT_BASE, "{window}");
        assert_ne!(window, document);
        assert_ne!(window, console);
        assert_eq!(host.libwasm_global("window").unwrap(), window);
        assert_eq!(host.libwasm_global("eval").unwrap(), 0);
        host.hw = Some(&mut session.hw);
        assert_eq!(host.libwasm_global("hw").unwrap(), 0);
        let platform = host.libwasm_global("platform").unwrap();
        assert!(platform >= g6b_wasm::OBJECT_BASE, "{platform}");
        assert_eq!(
            host.object_getter(window, "platform").unwrap(),
            LibwasmValue::I32(platform)
        );
        let hw = match host.object_getter(platform, "hw").unwrap() {
            LibwasmValue::I32(h) => h,
            other => panic!("{other:?}"),
        };
        assert!(hw >= g6b_wasm::OBJECT_BASE, "{hw}");
        assert_eq!(
            host.object_getter(hw, "nat").unwrap(),
            LibwasmValue::String("minimal".into())
        );
        assert_eq!(
            host.object_getter(hw, "listening").unwrap(),
            LibwasmValue::Bool(false)
        );
        let net = match host.object_getter(hw, "net").unwrap() {
            LibwasmValue::I32(h) => h,
            other => panic!("{other:?}"),
        };
        assert_eq!(
            host.object_getter(net, "kind").unwrap(),
            LibwasmValue::String("virtio-net".into())
        );
        let tcp = match host.object_getter(net, "tcp").unwrap() {
            LibwasmValue::I32(h) => h,
            other => panic!("{other:?}"),
        };
        assert_eq!(
            host.object_getter(tcp, "enabled").unwrap(),
            LibwasmValue::Bool(true)
        );
        assert_eq!(
            host.object_getter(hw, "host_adapter").unwrap(),
            LibwasmValue::String(String::new())
        );
        let disp = match host.object_getter(hw, "display").unwrap() {
            LibwasmValue::I32(h) => h,
            other => panic!("{other:?}"),
        };
        assert_eq!(
            host.object_getter(disp, "surface").unwrap(),
            LibwasmValue::String("vga".into())
        );
        assert_eq!(
            host.object_getter(disp, "probed").unwrap(),
            LibwasmValue::Bool(false)
        );
        assert_eq!(
            host.object_getter(disp, "kind").unwrap(),
            LibwasmValue::String("vga".into())
        );
        assert_eq!(
            host.object_getter(hw, "listening").unwrap(),
            LibwasmValue::Bool(false),
            "interning platform.hw must not listen"
        );
        let _ = host.object_call(hw, "stat", &[]).unwrap();
        assert_eq!(
            host.object_getter(hw, "listening").unwrap(),
            LibwasmValue::Bool(true)
        );
        assert_eq!(
            host.object_getter(disp, "probed").unwrap(),
            LibwasmValue::Bool(true)
        );
        assert_eq!(
            host.object_getter(disp, "kind").unwrap(),
            LibwasmValue::String("virtio-gpu".into())
        );
        assert_eq!(
            host.object_getter(disp, "surface").unwrap(),
            LibwasmValue::String("vga".into()),
            "scanout stays VGA until announce"
        );
        let root = host.get_root().unwrap();
        assert_eq!(root, 1, "getRoot is the Spa mount, not BoardSpec: {root}");
        let css_h = host.add_css(".bios-tab:hover{color:#fff}").unwrap();
        assert!(css_h >= 2);
        assert!(host
            .diagnostics
            .iter()
            .any(|d| d.contains("WASM-JS-GLOBAL window")),);
    }

    #[test]
    fn ui_files_serve_svg_for_img_src_and_fetch() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        assert!(spec.kernel.http.files.assets);
        let router = g6b_http::Router::from_spec(&spec);
        assert!(router.has_file("/ui/g6lc.svg"));
        let resp = router.fetch_get("/ui/g6lc.svg");
        assert_eq!(resp.status, 200, "{}", resp.body_str());
        assert!(resp.body_str().contains("<svg"));
        let assets = session_assets(&spec);
        assert!(
            assets.contains_key("/ui/g6lc.svg"),
            "CSS AssetMap keys {:?}",
            assets.keys().collect::<Vec<_>>()
        );
        assert!(local_src_url("/ui/g6lc.svg").is_some());
        assert!(local_src_url("https://evil/x.png").is_none());
        assert!(local_src_url("javascript:alert(1)").is_none());
        assert!(local_ui_url("/ui/g6lc.svg").is_some());
        assert!(local_ui_url("/bios/menu/cpu").is_some());
        assert!(local_ui_url("//evil").is_none());
    }

    #[test]
    fn svelte_d_session_runs_libwasm_cell_not_mvp_fallback() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        assert_eq!(spec.kernel.ui, "svelte-d");
        let session = BrowserSession::new(&spec).expect("full profile session");
        assert!(session.wasm_executed);
        assert!(session
            .diagnostics
            .iter()
            .any(|d| d == "WASM-INTERPRETER _start"));
        assert!(
            !session
                .diagnostics
                .iter()
                .any(|d| d.contains("WASM-LIBWASM-FAILED")),
            "{:?}",
            session.diagnostics
        );
        let ui = session.wasm_ui.as_ref().expect("libwasm WasmUi retained");
        assert!(ui.has_fetch_bios(), "live JsExports App_svelte.fetchBios");
        assert!(
            ui.window().is_some(),
            "interned window survives _start on the UI thread"
        );
        let module = &ui.module;
        assert!(
            g6b_wasm::bios_ui_libwasm_live(),
            "full profile must ship the LDC cell"
        );
        assert!(
            module.bodies.len()
                > g6b_wasm::decode(g6b_wasm::bios_ui_wasm())
                    .map(|m| m.bodies.len())
                    .unwrap_or(0),
            "session retained the LDC cell, not the MVP encoder module"
        );
        assert!(
            find_node_by_id(&session.dom, "libwasm-spa").is_some(),
            "LDC cell mounts under #libwasm-spa"
        );
        let mut session = session;
        session.select_menu("cpu").unwrap();
        let cpu = find_node_by_id(&session.dom, "tab-cpu").expect("live tab-cpu");
        let class = cpu.get_attribute("class").unwrap_or("");
        assert!(
            class.contains("bios-tab-active"),
            "cell-owned tab restyle: {class}"
        );
        assert_eq!(cpu.get_attribute("aria-selected"), Some("true"));
        let main = find_node_by_id(&session.dom, "tab-main").expect("live tab-main");
        assert!(!main
            .get_attribute("class")
            .unwrap_or("")
            .contains("bios-tab-active"));
        let t = session.tick(0).unwrap();
        let _ = t.presented;
        assert!(session.wasm_ui.is_some(), "WasmUi survives tick");
        assert!(
            session
                .diagnostics
                .iter()
                .any(|d| d.contains("WASM-ADD-EVENT-LISTENER") && d.contains("tab-cpu")),
            "cell-owned tab/refresh listeners: {:?}",
            session.diagnostics
        );
    }

    #[test]
    fn libwasm_cell_start_awaits_and_catch_survives_dom_event() {
        assert!(
            g6b_wasm::bios_ui_libwasm_live(),
            "full profile must ship the LDC svelte-d cell"
        );
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let mut session = BrowserSession::new(&spec).expect("LDC _start");
        assert!(
            session
                .diagnostics
                .iter()
                .any(|d| d == "WASM-INTERPRETER _start"),
            "{:?}",
            session.diagnostics
        );
        let awaits = session
            .diagnostics
            .iter()
            .filter(|d| d.starts_with("WASM-AWAIT-VOID"))
            .count();
        assert!(
            awaits >= 1,
            "App.ready libwasm_await__void through _start: {:?}",
            session.diagnostics
        );
        let cpu_body = find_node_by_id(&session.dom, "menu-cpu-body").expect("menu-cpu-body");
        assert!(
            !cpu_body.children.is_empty(),
            "awaited /bios/menu/cpu JSON painted rows; catch must not have swallowed _start: children={}",
            cpu_body.children.len()
        );
        session.select_menu("cpu").unwrap();
        let cpu = find_node_by_id(&session.dom, "tab-cpu").expect("tab-cpu");
        assert!(
            cpu.get_attribute("class")
                .unwrap_or("")
                .contains("bios-tab-active"),
            "DOM event after _start await/catch: {:?}",
            cpu.get_attribute("class")
        );
        let ui = session.wasm_ui.as_ref().expect("WasmUi");
        let raw = g6b_wasm::decode(g6b_wasm::bios_ui_libwasm()).expect("raw cell");
        assert!(
            raw.exports.iter().any(|e| e.name == "asyncify_get_state"),
            "svelte-engine wasm-opt --asyncify left control exports on the artifact"
        );
        assert!(
            !ui.module.tags.is_empty(),
            "imported env.__cpp_exception tag for ready() catch"
        );
    }

    #[test]
    fn svelte_d_without_libwasm_cell_is_an_error_not_mvp() {
        let mut spec =
            BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        spec.kernel.http.files.wasm = false;
        match BrowserSession::new(&spec) {
            Ok(_) => panic!("must not fall back to MVP wasm"),
            Err(err) => assert!(err.contains("LDC libwasm cell"), "{err}"),
        }
    }

    #[test]
    fn ui_ppm32_renders_setup_page() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let ppm = ui_ppm32(&spec).unwrap();
        assert!(ppm.starts_with(b"P6\n"));
        // The PPM header includes the requested geometry.
        let header = String::from_utf8_lossy(&ppm[..32]);
        assert!(header.contains("640 480\n255\n"), "{header}");
        // The canvas is not all white: the modern lane paints at least one
        // non-background (non-[255,255,255]) pixel.
        let body = &ppm[ppm.iter().position(|&b| b == b'\n').unwrap() + 1..];
        let body = &body[body.iter().position(|&b| b == b'\n').unwrap() + 1..];
        let body = &body[body.iter().position(|&b| b == b'\n').unwrap() + 1..];
        assert!(body.chunks_exact(3).any(|p| p != [255, 255, 255]));
    }

    #[test]
    fn ui_ppm_is_live_engine_downsample() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let ppm = ui_ppm(&spec).unwrap();
        assert!(ppm.starts_with(b"P6\n"));
        let header = String::from_utf8_lossy(&ppm[..32]);
        assert!(header.contains("640 480\n255\n"), "{header}");
        let out32 = ui_ppm32_output(&spec).unwrap();
        assert_eq!(out32.canvas.to_canvas().to_ppm(), ppm);
        let out4 = ui_ppm_output(&spec).unwrap();
        assert!(out4
            .hit_boxes
            .iter()
            .any(|h| h.id.as_deref() == Some("tab-cpu")));
        let pal = g6b_gr::canvas::Canvas::from_ppm(&ppm).expect("4bpp ppm is exact PALETTE");
        assert!(
            pal.pixels().iter().any(|&p| p != 15),
            "setup page is not a blank white canvas"
        );
    }

    #[test]
    fn ui_tab_cpu_ppm32() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let mut session = BrowserSession::new(&spec).unwrap();
        let main = session.paint_css().unwrap();
        session.select_menu("cpu").unwrap();
        let cpu = session.paint_css().unwrap();
        assert_ne!(
            main.canvas, cpu.canvas,
            "CPU tab classList + JSON rows must change the live raster"
        );
        let tab = find_node_by_id(&session.dom, "tab-cpu").expect("tab-cpu");
        assert!(
            tab.get_attribute("class")
                .unwrap_or("")
                .contains("bios-tab-active"),
            "cpu tab active after select_menu"
        );
        assert!(cpu
            .hit_boxes
            .iter()
            .any(|h| h.id.as_deref() == Some("tab-cpu")));
    }

    #[test]
    fn ui_tab_hover_ppm32() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let mut session = BrowserSession::new(&spec).unwrap();
        session.render_hit_boxes().unwrap();
        let before = session.paint_css().unwrap();
        let (x, y) = session
            .hit_boxes
            .iter()
            .find(|h| h.id.as_deref() == Some("tab-cpu") && h.w > 0 && h.h > 0)
            .map(|h| (h.x + h.w / 2, h.y + h.h / 2))
            .expect("tab-cpu hit box");
        session.dispatch_pointer(x, y, "mousemove", "").unwrap();
        let hovered = find_node_by_id(&session.dom, "tab-cpu").expect("tab-cpu");
        assert_eq!(hovered.get_attribute("data-hover"), Some("1"));
        let after = session.paint_css().unwrap();
        assert_ne!(
            before.canvas, after.canvas,
            ":hover on a non-active tab must restyle the live raster"
        );
    }

    #[test]
    fn ui_tick_skips_clean_frame() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let mut session = BrowserSession::new(&spec).unwrap();
        let first = session.tick(0).unwrap();
        assert!(first.dirty, "new session is dirty");
        assert!(first.presented);
        let transfers = session
            .diagnostics
            .iter()
            .filter(|d| d.starts_with("SCAN-TRANSFER"))
            .count();
        assert!(
            transfers >= 1,
            "first tick must TRANSFER dirty tiles: {:?}",
            session.diagnostics
        );
        assert!(session.last_transfer().contains("TRANSFER_TO_HOST_2D"));
        assert!(session.last_transfer().contains("RESOURCE_FLUSH"));
        let second = session.tick(1).unwrap();
        assert!(!second.dirty, "clean tree must skip the raster");
        assert!(!second.presented);
        assert_eq!(
            session
                .diagnostics
                .iter()
                .filter(|d| d.starts_with("SCAN-TRANSFER"))
                .count(),
            transfers,
            "skip-if-clean must not TRANSFER: {:?}",
            session.diagnostics
        );
        assert!(
            session.diagnostics.iter().any(|d| d == "SCAN-SKIP"),
            "clean present is SCAN-SKIP: {:?}",
            session.diagnostics
        );
        assert!(
            session.last_transfer().contains("SKIP-IF-CLEAN"),
            "{}",
            session.last_transfer()
        );
        assert!(!session.last_transfer().contains("TRANSFER_TO_HOST_2D"));
    }

    #[test]
    fn ui_scan_fb_matches_css_ppm32() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let mut session = BrowserSession::new(&spec).unwrap();
        let painted = session.paint_css().unwrap();
        let present = session.present_scanout().unwrap();
        assert!(!present.skipped, "first present is a full-frame blit");
        assert!(present.tiles > 0);
        let css_ppm = painted.canvas.to_ppm();
        let scan = session.scanout_ppm().expect("modelled __scan_fb");
        assert_eq!(
            css_ppm, scan,
            "Main→CPU→Memory scan_fb PPM must match Canvas32 over white"
        );
    }

    #[test]
    fn ui_tab_cpu_dirties_scanout_tiles() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let mut session = BrowserSession::new(&spec).unwrap();
        session.tick(0).unwrap();
        let before = session.scan_fb.clone();
        assert!(!before.iter().all(|&b| b == 0), "first tick fills scan_fb");
        session.select_menu("cpu").unwrap();
        let t = session.tick(1).unwrap();
        assert!(t.dirty);
        assert!(t.presented);
        assert_ne!(
            before, session.scan_fb,
            "CPU tab must change modelled __scan_fb"
        );
        assert!(
            session.last_transfer().contains("TRANSFER_TO_HOST_2D"),
            "tab switch TRANSFER: {}",
            session.last_transfer()
        );
        let css = session.paint_css().unwrap();
        assert_eq!(
            css.canvas.to_ppm(),
            session.scanout_ppm().expect("scan_fb"),
            "scanout after dirty tiles still matches the CSS golden"
        );
    }

    #[test]
    fn guest_web_present_transfers_css_into_vio_fb() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let web = guest_web_present(&spec).unwrap();
        assert!(!web.tiles.is_empty(), "first present has dirty tiles");
        assert!(web.node_count > 1, "compact persist stores a live tree");
        let m = g6b_asm::analyze::kstart(&spec);
        let s = g6b_asm::exec::run_module_web(&spec, &m, 0x8020_0000, 0, Some(&web)).unwrap();
        assert!(
            s.console.contains("VIRTIO-PAINT\n"),
            "guest VioPaint of Canvas32: {}",
            s.console
        );
        assert_eq!(s.cap_nodes, web.node_count);
        assert_eq!(s.cap_tiles, 0, "guest consumes tiles");
        let n = web.scan_fb.len().min(s.vio_fb.len());
        assert!(n > 4, "scanout bytes");
        // Packed CSS rows sit at the output stride; transferred tiles must
        // match the host engine in those rects.
        for t in &web.tiles {
            let x0 = t.x.max(0) as u32;
            let y0 = t.y.max(0) as u32;
            let x1 = (t.x + t.w).max(0) as u32;
            let y1 = (t.y + t.h).max(0) as u32;
            for y in y0..y1.min(s.vio_fb_h) {
                for x in x0..x1.min(s.vio_fb_w) {
                    let i = ((y * s.vio_fb_w + x) * 4) as usize;
                    if i + 4 <= s.vio_fb.len() && i + 4 <= web.scan_fb.len() {
                        assert_eq!(
                            &s.vio_fb[i..i + 4],
                            &web.scan_fb[i..i + 4],
                            "tile px ({x},{y})"
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn guest_cell_scanout_is_interactive_svelte_engine() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let cell = guest_cell_scanout(&spec).unwrap();
        assert!(cell.wasm_executed);
        assert!(cell.fetch_bios, "JsExports App_svelte.fetchBios");
        assert!(cell.window_interned, "libwasm_global window");
        assert!(cell.gl_presented, "GLES2 u_dom composite");
        assert!(cell.present.node_count > 1);
        assert!(
            !cell.present.tiles.is_empty(),
            "CSS paint dirties tiles for guest TRANSFER"
        );
        assert!(
            cell.diagnostics
                .iter()
                .any(|d| d.contains("WASM-INTERPRETER")),
            "{:?}",
            cell.diagnostics
        );
        assert!(
            cell.diagnostics
                .iter()
                .any(|d| d.contains("SCAN-TRANSFER") || d.contains("SCAN-SKIP")),
            "GLES2 present listing: {:?}",
            cell.diagnostics
        );
    }

    #[test]
    fn guest_cell_click_cpu_transfers_live_css() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let boot = guest_cell_scanout(&spec).unwrap();
        let cpu = guest_cell_click(&spec, "cpu").unwrap();
        assert!(cpu.wasm_executed);
        assert!(cpu.gl_presented);
        assert_ne!(
            boot.present.scan_fb, cpu.present.scan_fb,
            "CPU tab click must change packed Canvas32"
        );
        let m = g6b_asm::analyze::kstart(&spec);
        let s =
            g6b_asm::exec::run_module_web(&spec, &m, 0x8020_0000, 0, Some(&cpu.present)).unwrap();
        assert!(
            s.console.contains("VIRTIO-PAINT\n"),
            "guest VioPaint after click: {}",
            s.console
        );
        assert_eq!(s.cap_nodes, cpu.present.node_count);
        for t in &cpu.present.tiles {
            let x0 = t.x.max(0) as u32;
            let y0 = t.y.max(0) as u32;
            let x1 = (t.x + t.w).max(0) as u32;
            let y1 = (t.y + t.h).max(0) as u32;
            for y in y0..y1.min(s.vio_fb_h) {
                for x in x0..x1.min(s.vio_fb_w) {
                    let i = ((y * s.vio_fb_w + x) * 4) as usize;
                    if i + 4 <= s.vio_fb.len() && i + 4 <= cpu.present.scan_fb.len() {
                        assert_eq!(
                            &s.vio_fb[i..i + 4],
                            &cpu.present.scan_fb[i..i + 4],
                            "click tile px ({x},{y})"
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn guest_cell_key_arrow_right_transfers_live_css() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let boot = guest_cell_scanout(&spec).unwrap();
        let keyed = guest_cell_key(&spec, "ArrowRight").unwrap();
        assert!(keyed.wasm_executed);
        assert!(keyed.gl_presented);
        assert_ne!(
            boot.present.scan_fb, keyed.present.scan_fb,
            "ArrowRight must restyle the packed svelte-d canvas"
        );
        let m = g6b_asm::analyze::kstart(&spec);
        let s =
            g6b_asm::exec::run_module_web(&spec, &m, 0x8020_0000, 0, Some(&keyed.present)).unwrap();
        assert!(
            s.console.contains("VIRTIO-PAINT\n"),
            "guest VioPaint after key: {}",
            s.console
        );
    }

    #[test]
    fn guest_cell_ldc_start_await_catch_then_cpu_click_vio() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let cell = guest_cell_drive(&spec, &[GuestCellAction::ClickMenu("cpu")]).unwrap();
        assert!(cell.wasm_executed);
        assert!(
            cell.diagnostics
                .iter()
                .any(|d| d.starts_with("WASM-AWAIT-VOID")),
            "LDC App.ready awaited through _start: {:?}",
            cell.diagnostics
        );
        assert!(
            cell.diagnostics
                .iter()
                .any(|d| d.contains("EVENT-CELL-TRIGGERED") || d.contains("WASM-CELL-LISTEN")),
            "DOM event after await/catch: {:?}",
            cell.diagnostics
        );
        assert!(cell.gl_presented);
        let m = g6b_asm::analyze::kstart(&spec);
        let s =
            g6b_asm::exec::run_module_web(&spec, &m, 0x8020_0000, 0, Some(&cell.present)).unwrap();
        assert!(
            s.console.contains("VIRTIO-PAINT\n"),
            "B91b+ guest VioPaint after _start await+click: {}",
            s.console
        );
    }

    #[test]
    fn guest_cell_virtio_keydown_maps_to_svelte_tabs() {
        use g6b_asm::exec::WebFeed;
        use g6b_asm::vio::{VIO_KEY_DOWN, VIO_KEY_ENTER};
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let mut live = GuestCellLive::open(&spec).unwrap();
        let boot = live.finish().unwrap();
        let letter = live.on_guest_key(30, true);
        assert!(letter.is_none(), "KEY_A is not a tab key");
        let down = live
            .on_guest_key(VIO_KEY_DOWN as u16, true)
            .expect("KEY_DOWN → ArrowRight");
        assert_ne!(
            boot.present.scan_fb, down.scan_fb,
            "virtio KEY_DOWN must restyle the svelte-d canvas"
        );
        let enter = live
            .on_guest_key(VIO_KEY_ENTER as u16, true)
            .expect("KEY_ENTER → click current tab");
        assert_ne!(
            down.scan_fb, enter.scan_fb,
            "virtio KEY_ENTER must activate the current tab"
        );
        let m = g6b_asm::analyze::kstart(&spec);
        let s = g6b_asm::exec::run_module_web(&spec, &m, 0x8020_0000, 0, Some(&enter)).unwrap();
        assert!(
            s.console.contains("VIRTIO-PAINT\n"),
            "guest VioPaint after INP keys: {}",
            s.console
        );
    }

    #[test]
    fn guest_cell_virtio_tablet_abs_hovers_then_btn_clicks() {
        use g6b_asm::exec::WebFeed;
        use g6b_asm::vio::{VIO_ABS_X, VIO_ABS_Y, VIO_BTN_LEFT};
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let argv = qemu_dual_band_argv(&spec).join(" ");
        assert!(argv.contains("virtio-keyboard-device"), "{argv}");
        assert!(
            argv.contains("virtio-tablet-device"),
            "qemu-args attaches tablet after keyboard: {argv}"
        );
        let mut live = GuestCellLive::open(&spec).unwrap();
        let boot = live.finish().unwrap();
        let (x, y) = tab_hit(&mut live.session, "cpu").unwrap();
        let (w, h) = canvas_wh(&spec);
        let _ = live.on_guest_abs(VIO_ABS_X as u16, px_to_abs(x, w));
        let hovered = live
            .on_guest_abs(VIO_ABS_Y as u16, px_to_abs(y, h))
            .expect("tablet ABS_Y on tab-cpu");
        assert_ne!(
            boot.present.scan_fb, hovered.scan_fb,
            "virtio-tablet ABS must :hover tab-cpu"
        );
        let tab = find_node_by_id(&live.session.dom, "tab-cpu").expect("tab-cpu");
        assert_eq!(tab.get_attribute("data-hover"), Some("1"));
        let clicked = live
            .on_guest_key(VIO_BTN_LEFT as u16, true)
            .expect("BTN_LEFT click at tablet point");
        assert_ne!(
            hovered.scan_fb, clicked.scan_fb,
            "BTN_LEFT must activate tab-cpu"
        );
        let m = g6b_asm::analyze::kstart(&spec);
        let s = g6b_asm::exec::run_module_web(&spec, &m, 0x8020_0000, 0, Some(&clicked)).unwrap();
        assert!(
            s.console.contains("VIRTIO-PAINT\n"),
            "guest VioPaint after tablet click: {}",
            s.console
        );
    }

    #[test]
    fn guest_cell_virtio_tablet_clicks_refresh() {
        use g6b_asm::exec::WebFeed;
        use g6b_asm::vio::{VIO_ABS_X, VIO_ABS_Y, VIO_BTN_LEFT};
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let mut live = GuestCellLive::open(&spec).unwrap();
        let boot = live.finish().unwrap();
        let status0 = find_node_by_id(&live.session.dom, "status")
            .map(|n| n.inner_text())
            .unwrap_or_default();
        let (x, y) = id_hit(&mut live.session, "refresh").expect("refresh hit box");
        let (w, h) = canvas_wh(&spec);
        let _ = live.on_guest_abs(VIO_ABS_X as u16, px_to_abs(x, w));
        let _ = live.on_guest_abs(VIO_ABS_Y as u16, px_to_abs(y, h));
        let clicked = live
            .on_guest_key(VIO_BTN_LEFT as u16, true)
            .expect("BTN_LEFT on #refresh");
        assert_ne!(
            boot.present.scan_fb, clicked.scan_fb,
            "#refresh click must restyle the packed svelte-d canvas"
        );
        let status = find_node_by_id(&live.session.dom, "status")
            .map(|n| n.inner_text())
            .unwrap_or_default();
        assert_ne!(status0, status, "refresh must rewrite #status");
        assert!(
            status.contains("refresh") || status.contains("UI-BOOT"),
            "refresh status: {status}"
        );
        let driven = guest_cell_drive(&spec, &[GuestCellAction::ClickId("refresh")]).unwrap();
        assert!(driven.gl_presented);
        let m = g6b_asm::analyze::kstart(&spec);
        let s = g6b_asm::exec::run_module_web(&spec, &m, 0x8020_0000, 0, Some(&clicked)).unwrap();
        assert!(
            s.console.contains("VIRTIO-PAINT\n"),
            "guest VioPaint after refresh click: {}",
            s.console
        );
    }

    #[test]
    fn guest_cell_virtio_mouse_rel_moves_to_tab() {
        use g6b_asm::exec::WebFeed;
        use g6b_asm::vio::{VIO_REL_X, VIO_REL_Y};
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let mut live = GuestCellLive::open(&spec).unwrap();
        let boot = live.finish().unwrap();
        let (x, y) = tab_hit(&mut live.session, "cpu").unwrap();
        let _ = live.on_guest_rel(VIO_REL_X as u16, x);
        let moved = live
            .on_guest_rel(VIO_REL_Y as u16, y)
            .expect("mouse REL to tab-cpu");
        assert_ne!(
            boot.present.scan_fb, moved.scan_fb,
            "virtio-mouse REL must :hover tab-cpu"
        );
        let tab = find_node_by_id(&live.session.dom, "tab-cpu").expect("tab-cpu");
        assert_eq!(tab.get_attribute("data-hover"), Some("1"));
        assert!(live.on_guest_abs(99, 0).is_none(), "unknown ABS axis");
        assert!(live.on_guest_rel(99, 1).is_none(), "unknown REL axis");
    }

    #[test]
    fn smoke_cell_tablet_slot_pokes_abs_via_webfeed() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let mut live = GuestCellLive::open(&spec).unwrap();
        let _ = live.finish().unwrap();
        let entry = 0x8020_0000u64;
        let m = g6b_asm::analyze::kstart(&spec);
        let s = g6b_asm::exec::run_module_web_feed(&spec, &m, entry, 0, &mut live).unwrap();
        assert!(s.console.contains("VIRTIO-TABLET-OK"), "{}", s.console);
        assert!(
            s.console.matches("TAB\n").count() >= 3,
            "tablet ABS+BTN poke must drain: {}",
            s.console
        );
        assert!(
            s.console.contains("VIRTIO-PAINT\n"),
            "tablet click still VioPaint: {}",
            s.console
        );
        let menus = [
            "main", "cpu", "memory", "uncore", "devices", "boot", "settings",
        ];
        let active: Vec<&str> = menus
            .iter()
            .copied()
            .filter(|menu| {
                find_node_by_id(&live.session.dom, &format!("tab-{menu}"))
                    .and_then(|n| n.get_attribute("class").map(str::to_string))
                    .is_some_and(|c| c.contains("bios-tab-active"))
            })
            .collect();
        assert!(
            active.iter().any(|m| *m != "cpu"),
            "tablet BTN_LEFT must select the hinted tab (not stay on cpu after KEY SEQ): {active:?}"
        );
    }

    #[test]
    fn guest_cell_trap_timer_skip_if_clean_then_hover_dirties() {
        use g6b_asm::exec::WebFeed;
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let mut live = GuestCellLive::open(&spec).unwrap();
        let _ = live.finish().unwrap();
        assert!(
            live.on_guest_tick().is_none(),
            "clean UI-hart tick must not inject tiles"
        );
        live.apply(&[GuestCellAction::HoverMenu("cpu")]).unwrap();
        let dirty = live
            .on_guest_tick()
            .expect("hover marks CSS dirty for trap_timer VioPaint");
        assert!(!dirty.tiles.is_empty());
        let m = g6b_asm::analyze::kstart(&spec);
        let s = g6b_asm::exec::run_module_web(&spec, &m, 0x8020_0000, 0, Some(&dirty)).unwrap();
        assert!(
            s.console.contains("VIRTIO-PAINT\n"),
            "guest VioPaint after timer tick: {}",
            s.console
        );
    }

    #[test]
    fn guest_cell_hover_cpu_transfers_live_css() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let boot = guest_cell_scanout(&spec).unwrap();
        let hovered = guest_cell_drive(&spec, &[GuestCellAction::HoverMenu("cpu")]).unwrap();
        assert!(hovered.gl_presented);
        assert_ne!(
            boot.present.scan_fb, hovered.present.scan_fb,
            ":hover on tab-cpu must change packed Canvas32"
        );
    }

    #[test]
    fn guest_cell_await_fetch_throw_catch_packs_for_vio() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let cell =
            guest_cell_drive(&spec, &[GuestCellAction::AwaitFetch("/bios/menu/cpu")]).unwrap();
        assert!(cell.wasm_executed);
        assert!(cell.gl_presented);
        assert!(
            !cell.present.tiles.is_empty(),
            "await-resolved DOM still TRANSFERs"
        );
        let m = g6b_asm::analyze::kstart(&spec);
        let s =
            g6b_asm::exec::run_module_web(&spec, &m, 0x8020_0000, 0, Some(&cell.present)).unwrap();
        assert!(
            s.console.contains("VIRTIO-PAINT\n"),
            "guest VioPaint after JS await: {}",
            s.console
        );
    }

    #[test]
    fn kernel_host_env_await_throw_catch_are_the_same_import_set() {
        use g6b_wasm::Host;
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let mut session = BrowserSession::new(&spec).unwrap();
        let mut timers = crate::timers::TimerHeap::new();
        let mut host = KernelHost::attach_fresh(
            &mut session.dom,
            &session.program.router,
            &spec,
            Vec::new(),
            &mut timers,
            0,
            Some(&mut session.program.store),
        );
        assert_eq!(host.await_supported(), 1);
        let s0 = host.await_op().unwrap();
        let s1 = host.await_op().unwrap();
        assert_eq!(s0, 0);
        assert_eq!(s1, 1);
        host.throw_op(s0).unwrap();
        assert_eq!(host.catch_op(s0).unwrap(), 1);
        assert_eq!(host.catch_op(s1).unwrap(), 0);
        host.throw_op(-1).unwrap();
        assert_eq!(host.catch_op(s1).unwrap(), 1);
        assert!(
            host.diagnostics
                .iter()
                .any(|d| d.contains("WASM-AWAIT pending")),
            "{:?}",
            host.diagnostics
        );
        assert!(
            host.diagnostics.iter().any(|d| d.contains("WASM-THROW")),
            "{:?}",
            host.diagnostics
        );
    }

    #[test]
    fn ui_thread_dom_event_throws_into_try_await_catch_with_jit_stack() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let mut session = BrowserSession::new(&spec).unwrap();
        let bytes = g6b_wasm::asyncify_wat(g6b_wasm::UI_EVENT_THROW_WAT)
            .expect("forked wasm-opt --asyncify");
        let mut module = g6b_wasm::decode(&bytes).expect("decode");
        let on_click = module
            .exports
            .iter()
            .find(|e| e.name == "on_click" && e.kind == 0)
            .map(|e| e.idx)
            .unwrap();
        let surrounding = module
            .exports
            .iter()
            .find(|e| e.name == "surrounding" && e.kind == 0)
            .map(|e| e.idx)
            .unwrap();
        let mut timers = crate::timers::TimerHeap::new();
        let mut host = KernelHost::attach_fresh(
            &mut session.dom,
            &session.program.router,
            &spec,
            Vec::new(),
            &mut timers,
            0,
            Some(&mut session.program.store),
        );
        let err = g6b_wasm::run_with_fuel_mut(
            &mut module,
            on_click,
            &[],
            &mut host,
            g6b_wasm::DEFAULT_FUEL,
        )
        .expect_err("DOM event export only throws");
        assert!(err.contains("unhandled wasm exception"), "{err}");
        assert!(
            host.diagnostics
                .iter()
                .any(|d| d.contains("WASM-THROW-STACK")
                    && d.contains("thrower")
                    && d.contains("on_click")),
            "event callee stack: {:?}",
            host.diagnostics
        );

        host.diagnostics.clear();
        let ay = g6b_wasm::Asyncify::new(&module).expect("asyncify exports");
        let data = 1024u32;
        let slot = match ay
            .step(&mut module, surrounding, &[], data, 4096, &mut host)
            .expect("await unwind")
        {
            g6b_wasm::Step::Sleeping { slot, .. } => slot,
            other => panic!("expected Sleeping, {other:?}"),
        };
        g6b_wasm::Host::resolve_slot(&mut host, slot).expect("wrapExportFn settle");
        match ay
            .resume(&mut module, surrounding, &[], data, 4096, &mut host)
            .expect("rewind into event throw, caught outside")
        {
            g6b_wasm::Step::Done(v) => assert_eq!(v, vec![1], "try/await/catch returns 1"),
            other => panic!("expected Done(1), {other:?}"),
        }
        assert!(
            host.diagnostics
                .iter()
                .any(|d| d.contains("WASM-THROW-STACK")
                    && d.contains("thrower")
                    && d.contains("on_click")
                    && d.contains("surrounding")),
            "caught outside the event: {:?}",
            host.diagnostics
        );
    }

    fn kernel_host_for_try_table<'a>(
        session: &'a mut BrowserSession,
        spec: &'a BoardSpec,
        timers: &'a mut crate::timers::TimerHeap,
    ) -> KernelHost<'a> {
        KernelHost::attach_fresh(
            &mut session.dom,
            &session.program.router,
            spec,
            Vec::new(),
            timers,
            0,
            Some(&mut session.program.store),
        )
    }

    #[test]
    fn ui_thread_try_table_throw_in_await_has_jit_stack() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let mut session = BrowserSession::new(&spec).unwrap();
        let bytes = g6b_wasm::asyncify_wat(g6b_wasm::TRY_TABLE_AWAIT_WAT)
            .expect("forked wasm-opt --asyncify try_table");
        let mut module = g6b_wasm::decode(&bytes).expect("decode");
        let throw_in_await = module
            .exports
            .iter()
            .find(|e| e.name == "throw_in_await" && e.kind == 0)
            .map(|e| e.idx)
            .unwrap();
        let mut timers = crate::timers::TimerHeap::new();
        let mut host = kernel_host_for_try_table(&mut session, &spec, &mut timers);
        let ay = g6b_wasm::Asyncify::new(&module).expect("asyncify exports");
        let slot = match ay
            .step(&mut module, throw_in_await, &[], 1024, 4096, &mut host)
            .expect("await unwind")
        {
            g6b_wasm::Step::Sleeping { slot, .. } => slot,
            other => panic!("expected Sleeping, {other:?}"),
        };
        g6b_wasm::Host::resolve_slot(&mut host, slot).expect("wrapExportFn settle");
        match ay
            .resume(&mut module, throw_in_await, &[], 1024, 4096, &mut host)
            .expect("rewind then throw lands on try_table dest")
        {
            g6b_wasm::Step::Done(v) => assert_eq!(v, vec![7]),
            other => panic!("expected Done(7), {other:?}"),
        }
        assert!(
            host.diagnostics
                .iter()
                .any(|d| d.contains("WASM-THROW-STACK") && d.contains("throw_in_await")),
            "simple throw in await: {:?}",
            host.diagnostics
        );
    }

    #[test]
    fn ui_thread_async_dom_event_awaits_then_thrower_caught() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let mut session = BrowserSession::new(&spec).unwrap();
        let bytes = g6b_wasm::asyncify_wat(g6b_wasm::TRY_TABLE_AWAIT_WAT)
            .expect("forked wasm-opt --asyncify try_table");
        let mut module = g6b_wasm::decode(&bytes).expect("decode");
        let dom_event = module
            .exports
            .iter()
            .find(|e| e.name == "domEvent" && e.kind == 0)
            .map(|e| e.idx)
            .unwrap();
        let mut timers = crate::timers::TimerHeap::new();
        let mut host = kernel_host_for_try_table(&mut session, &spec, &mut timers);
        let ay = g6b_wasm::Asyncify::new(&module).expect("asyncify exports");
        let slot = match ay
            .step(&mut module, dom_event, &[], 1024, 4096, &mut host)
            .expect("domEvent await unwinds")
        {
            g6b_wasm::Step::Sleeping { slot, .. } => slot,
            other => panic!("expected Sleeping, {other:?}"),
        };
        g6b_wasm::Host::resolve_slot(&mut host, slot).expect("wrapExportFn settle");
        match ay
            .resume(&mut module, dom_event, &[], 1024, 4096, &mut host)
            .expect("rewind into thrower, caught in event try_table")
        {
            g6b_wasm::Step::Done(v) => assert_eq!(v, vec![1]),
            other => panic!("expected Done(1), {other:?}"),
        }
        assert!(
            host.diagnostics
                .iter()
                .any(|d| d.contains("WASM-THROW-STACK")
                    && d.contains("thrower")
                    && (d.contains("on_click") || d.contains("domEvent"))),
            "async DOM event stack: {:?}",
            host.diagnostics
        );
    }

    #[test]
    fn ui_hart_runs_tick_when_tasking_enabled() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"full","harts":{"count":2},"kernel":{"tasking":{"enable":true,"ui_hart":0,"max_tasks":16}}}"#,
        )
        .unwrap();
        let mut session = BrowserSession::new(&spec).unwrap();
        assert!(
            session.diagnostics.iter().any(|d| d.contains("UI-HART")),
            "{:?}",
            session.diagnostics
        );
        let _ = session.tick(0).unwrap();
        let role = session.task_services.as_ref().unwrap().ui_role().unwrap();
        assert_eq!(role, crate::tasks::Role::Ui);
    }

    #[test]
    fn timer_ids_are_nonzero_and_due_timeouts_run_on_tick() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let mut session = BrowserSession::new(&spec).unwrap();
        let id = session.timers.set_timeout(0, 0, 5, 0).unwrap();
        assert!(id > 0, "B66 must not return timer id 0");
        session.tick(0).unwrap();
        assert!(
            !session
                .diagnostics
                .iter()
                .any(|d| d.contains("TIMER-FIRE") || d.contains("TIMER-SKIP")),
            "5ms timer must not fire at t=0"
        );
        session.tick(5_000_000).unwrap();
        assert!(
            session.diagnostics.iter().any(|d| d.contains("TIMER-SKIP")),
            "due timeout with ptr=0 is skipped, not id 0: {:?}",
            session.diagnostics
        );
        session
            .timers
            .request_animation_frame(0, 0, 0, 8_333_333)
            .unwrap();
        session.tick(8_333_333).unwrap();
        assert!(session.diagnostics.iter().any(|d| d.contains("TIMER-SKIP")));
    }

    #[test]
    fn setup_page_renders_a_keyboard_tab_strip_above_aligned_tables() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        // At the GPU scanout geometry, where the strip is meant to be read.
        // A 640px VGA plane legitimately wraps the seven tabs onto two rows.
        let out = ui_ppm32_output_at(&spec, 1280, 720).unwrap();

        let banner = out
            .hit_boxes
            .iter()
            .find(|b| b.id.as_deref() == Some("banner"))
            .expect("banner");
        let tabs: Vec<_> = out
            .hit_boxes
            .iter()
            .filter(|b| b.name == "a" && b.w > 0)
            .collect();
        assert_eq!(tabs.len(), spec.menus().len(), "one tab per menu");

        // The strip sits under the banner and every tab shares one row, which
        // is what "tabs at the top" has to mean in pixels.
        assert!(tabs.iter().all(|t| t.y >= banner.y + banner.h));
        assert!(tabs.iter().all(|t| t.y == tabs[0].y));
        for pair in tabs.windows(2) {
            assert!(pair[0].x < pair[1].x, "tabs run left to right");
            assert!(
                pair[0].x + pair[0].w <= pair[1].x + 1,
                "tabs do not overlap"
            );
        }
        // Shrink-to-fit, not one tab per line and not a full-width block.
        assert!(tabs.iter().all(|t| t.w < 200));

        // Each settings table is a real grid: cells side by side with aligned
        // columns, rather than one cell per line.
        let cells: Vec<_> = out
            .hit_boxes
            .iter()
            .filter(|b| b.name == "th" || b.name == "td")
            .collect();
        assert!(cells.len() >= 6, "settings rows must produce cells");
        let head: Vec<_> = cells.iter().filter(|c| c.y == cells[0].y).collect();
        assert_eq!(head.len(), 3, "Setting / Value / Access share a row");
        assert!(head[0].x < head[1].x && head[1].x < head[2].x);

        // The keyboard contract the tabs advertise is the one the session
        // actually implements.
        let hint = g6b_ui::setup_html(&spec);
        assert!(hint.contains("id=\"bios-hint\""));
        assert!(hint.contains("role=\"tablist\""));
        assert!(hint.contains("role=\"tab\""));
        for key in ["ArrowLeft", "ArrowRight", "Home", "End"] {
            assert!(
                g6b_ui::menu_for_key(&spec.kernel.start_menu, key).is_some(),
                "{key} must move the tab selection"
            );
        }
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
            r#"{"schema_version":1,"profile":"full","kernel":{"wasm":{"enable":false},"http":{"files":{"wasm":false},"proxy_js":false}}}"#,
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
        // js off: no wasm UI (the MVP encoder is not a silent fallback).
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"full","kernel":{"http":{"proxy_js":false},"browser":{"js":"off"}}}"#,
        )
        .unwrap();
        let session = BrowserSession::new(&spec).unwrap();
        assert!(!session.wasm_executed);
        assert!(!session
            .diagnostics
            .iter()
            .any(|s| s.starts_with("WASM-FETCH")));
        // js aot + proxy_js false: the LDC cell must not report a successful
        // kernel GET. `_start` may fail closed (host-incomplete await); that
        // is not an MVP fallback and not a 200.
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"full","kernel":{"http":{"proxy_js":false}}}"#,
        )
        .unwrap();
        match BrowserSession::new(&spec) {
            Ok(session) => {
                assert!(!session
                    .diagnostics
                    .iter()
                    .any(|s| s.starts_with("WASM-FETCH")));
            }
            Err(e) => assert!(
                !e.contains("HTTP 200"),
                "disabled proxy must not look like a fetch success: {e}"
            ),
        }
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
        // Live surface stays VGA until g6b-hw announces display support.
        assert_eq!(session.surface, g6b_spec::Surface::Vga);
        match session.holyc_request("HwStat();").unwrap() {
            ReplResult::Output(s) => {
                assert!(s.contains("HW-STAT"), "{s}");
                assert!(s.contains("HW-DISP"), "{s}");
            }
            other => panic!("{other:?}"),
        }
        assert_eq!(session.surface, g6b_spec::Surface::Gpu);
        assert_eq!(session.hw.scanout(), "gpu");
        assert!(
            session
                .diagnostics
                .iter()
                .any(|d| d.starts_with("HW-EVENT")),
            "{:?}",
            session.diagnostics
        );
        assert!(session.dom.get_element_by_id("disp-toggle").is_some());
        assert_eq!(session.proxy().surface, g6b_spec::Surface::Gpu);
    }

    #[test]
    fn toggling_the_surface_updates_dom_router_and_proxy_together() {
        let spec = gpu_spec();
        let mut session = BrowserSession::new(&spec).unwrap();
        let _ = session.holyc_request("HwStat();").unwrap();
        assert_eq!(session.surface, g6b_spec::Surface::Gpu);
        let now = session.toggle_surface().unwrap();
        assert_eq!(now, g6b_spec::Surface::Vga);
        assert_eq!(session.surface, g6b_spec::Surface::Vga);
        assert_eq!(session.hw.scanout(), "vga");
        assert_eq!(session.proxy().surface, g6b_spec::Surface::Vga);
        assert!(session.diagnostics.iter().any(|d| d == "DISP-SURFACE vga"));
        assert_eq!(session.toggle_surface().unwrap(), g6b_spec::Surface::Gpu);
        assert_eq!(session.hw.scanout(), "gpu");
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
        // Inset from the top so the absolutely positioned button does not touch
        // the canvas edge and risk clipping on small surfaces.
        assert!(
            hit.y > 0 && hit.y <= 10,
            "and near the top with a small inset"
        );

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
        let mut host = KernelHost::attach_fresh(
            &mut session.dom,
            &session.program.router,
            &spec,
            Vec::new(),
            &mut session.timers,
            0,
            Some(&mut session.program.store),
        );
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
    fn lodash_pglite_query_hits_the_same_registry() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1}"#).unwrap();
        let mut session = BrowserSession::new(&spec).unwrap();
        let uuid = session.program.store.open_purpose("registry").unwrap();
        session
            .program
            .store
            .exec(uuid, "CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT)")
            .unwrap();
        session
            .program
            .store
            .exec(uuid, "INSERT INTO kv VALUES ('a', 'b')")
            .unwrap();
        let mut host = KernelHost::attach_fresh(
            &mut session.dom,
            &session.program.router,
            &spec,
            Vec::new(),
            &mut session.timers,
            0,
            Some(&mut session.program.store),
        );
        // One-shot D path: defaultTo(=window.pglite) then attempt("query", sql, "[]")
        // opens the current registry instance and queries it.
        let cmds = g6b_js::lodash_parse(
            r#"[{"func":"defaultTo","params":["=window.pglite"]},{"func":"attempt","params":["query","SELECT * FROM kv","[]"]}]"#,
        )
        .unwrap();
        let out = g6b_js::lodash_execute_host(JsValue::Null, &cmds, None, Some(&mut host)).unwrap();
        let JsValue::Str(s) = out else {
            panic!("expected JSON string, got {out:?}");
        };
        assert!(s.contains("\"ok\":true"), "{s}");
        assert!(s.contains("\"b\""), "{s}");

        let opened = g6b_js::lodash_parse(
            r#"[{"func":"defaultTo","params":["=window.pglite"]},{"func":"attempt","params":["=undefined"]}]"#,
        )
        .unwrap();
        let handle =
            g6b_js::lodash_execute_host(JsValue::Null, &opened, None, Some(&mut host)).unwrap();
        assert!(matches!(handle, JsValue::Handle(h) if h != 0), "{handle:?}");
        let exec_cmds = g6b_js::lodash_parse(
            r#"[{"func":"invoke","params":["exec","INSERT INTO kv VALUES ('c', 'd')"]}]"#,
        )
        .unwrap();
        let exec_out =
            g6b_js::lodash_execute_host(handle.clone(), &exec_cmds, None, Some(&mut host)).unwrap();
        let JsValue::Str(es) = exec_out else {
            panic!("expected JSON string, got {exec_out:?}");
        };
        assert!(es.contains("\"ok\":true"), "{es}");

        let stat_cmds = g6b_js::lodash_parse(r#"[{"func":"invoke","params":["stat"]}]"#).unwrap();
        let stat_out =
            g6b_js::lodash_execute_host(handle.clone(), &stat_cmds, None, Some(&mut host)).unwrap();
        let JsValue::Str(ss) = stat_out else {
            panic!("expected JSON string, got {stat_out:?}");
        };
        assert!(ss.contains("\"ready\":true"), "{ss}");
        let async_cmds =
            g6b_js::lodash_parse(r#"[{"func":"invoke","params":["statAsync"]}]"#).unwrap();
        let async_out =
            g6b_js::lodash_execute_host(handle, &async_cmds, None, Some(&mut host)).unwrap();
        let JsValue::Str(as_) = async_out else {
            panic!("expected JSON string, got {async_out:?}");
        };
        assert!(as_.contains("\"ready\":true"), "{as_}");

        let alert = g6b_js::lodash_parse(r#"[{"func":"defaultTo","params":["=window.alert"]}]"#)
            .unwrap_err();
        assert!(matches!(alert, LodashError::EvalRefused(_)));
    }

    #[test]
    fn libwasm_start_awaits_pglite_sql_insert_select() {
        use g6b_wasm::{Export, FuncType, Import, Instr, Module, ValType};

        let spec = BoardSpec::from_json_str(r#"{"schema_version":1}"#).unwrap();
        let mut session = BrowserSession::new(&spec).unwrap();
        let open =
            r#"[{"func":"defaultTo","params":["=window.pglite"]},{"func":"attempt","params":[]}]"#;
        let exec_sql = "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)";
        let exec = format!(r#"[{{"func":"invoke","params":["exec","{exec_sql}"]}}]"#);
        let insert = r#"[{"func":"invoke","params":["query","INSERT INTO t VALUES ($1, $2)","[1,\"alice\"]"]}]"#;
        let select = r#"[{"func":"invoke","params":["queryAsync","SELECT name FROM t WHERE id = $1","[1]"]}]"#;
        let status = "status";
        let marker = "PGLITE-SQL";

        let mut mem = vec![0u8; 65536];
        let mut at = 256usize;
        let intern = |mem: &mut [u8], at: &mut usize, s: &str| {
            let off = *at;
            mem[off..off + s.len()].copy_from_slice(s.as_bytes());
            *at = (*at + s.len() + 3) & !3;
            (off as i32, s.len() as i32)
        };
        let (open_ptr, open_len) = intern(&mut mem, &mut at, open);
        let (exec_ptr, exec_len) = intern(&mut mem, &mut at, &exec);
        let (ins_ptr, ins_len) = intern(&mut mem, &mut at, insert);
        let (sel_ptr, sel_len) = intern(&mut mem, &mut at, select);
        let (st_ptr, st_len) = intern(&mut mem, &mut at, status);
        let (mk_ptr, mk_len) = intern(&mut mem, &mut at, marker);

        let m = Module {
            types: vec![
                FuncType {
                    params: vec![ValType::I32; 7],
                    results: vec![ValType::I32],
                },
                FuncType {
                    params: vec![ValType::I32; 8],
                    results: vec![],
                },
                FuncType {
                    params: vec![ValType::I32],
                    results: vec![],
                },
                FuncType {
                    params: vec![ValType::I32; 4],
                    results: vec![],
                },
                FuncType {
                    params: vec![],
                    results: vec![],
                },
            ],
            imports: vec![
                Import {
                    module: "env".into(),
                    name: "ldexec_Handle__Handle".into(),
                    typeidx: 0,
                },
                Import {
                    module: "env".into(),
                    name: "ldexec_Handle__string".into(),
                    typeidx: 1,
                },
                Import {
                    module: "env".into(),
                    name: g6b_wasm::IMPORT_LIBWASM_AWAIT_VOID.into(),
                    typeidx: 2,
                },
                Import {
                    module: "env".into(),
                    name: g6b_wasm::IMPORT_LIBWASM_AWAIT_VALUE.into(),
                    typeidx: 2,
                },
                Import {
                    module: "env".into(),
                    name: g6b_wasm::IMPORT_SET_INNER_TEXT.into(),
                    typeidx: 3,
                },
            ],
            func_types: vec![4],
            mem_pages: 1,
            max_mem_pages: None,
            exports: vec![Export {
                name: "_start".into(),
                kind: 0,
                idx: 5,
            }],
            bodies: vec![vec![
                Instr::I32Const(0),
                Instr::I32Const(open_len),
                Instr::I32Const(open_ptr),
                Instr::I32Const(0),
                Instr::I32Const(0),
                Instr::I32Const(0),
                Instr::I32Const(0),
                Instr::Call(0),
                Instr::LocalSet(0),
                Instr::I32Const(64),
                Instr::LocalGet(0),
                Instr::I32Const(exec_len),
                Instr::I32Const(exec_ptr),
                Instr::I32Const(0),
                Instr::I32Const(0),
                Instr::I32Const(0),
                Instr::I32Const(0),
                Instr::Call(1),
                Instr::I32Const(64),
                Instr::LocalGet(0),
                Instr::I32Const(ins_len),
                Instr::I32Const(ins_ptr),
                Instr::I32Const(0),
                Instr::I32Const(0),
                Instr::I32Const(0),
                Instr::I32Const(0),
                Instr::Call(1),
                Instr::LocalGet(0),
                Instr::I32Const(sel_len),
                Instr::I32Const(sel_ptr),
                Instr::I32Const(0),
                Instr::I32Const(0),
                Instr::I32Const(0),
                Instr::I32Const(0),
                Instr::Call(0),
                Instr::LocalSet(1),
                Instr::LocalGet(1),
                Instr::Call(2),
                Instr::I32Const(80),
                Instr::Call(3),
                Instr::I32Const(st_ptr),
                Instr::I32Const(st_len),
                Instr::I32Const(mk_ptr),
                Instr::I32Const(mk_len),
                Instr::Call(4),
                Instr::End,
            ]],
            memory: mem,
            locals: vec![2],
            has_memory: true,
            tags: vec![],
            globals: vec![],
            tables: vec![],
            elements: vec![],
            data_count: None,
            data_segments: vec![],
        };
        let mut timers = TimerHeap::new();
        let mut host = KernelHost::attach_fresh(
            &mut session.dom,
            &session.program.router,
            &spec,
            Vec::new(),
            &mut timers,
            0,
            Some(&mut session.program.store),
        );
        run_libwasm_start(&m, &mut host)
            .unwrap_or_else(|e| panic!("pglite _start: {e}\ndiagnostics: {:?}", host.diagnostics));
        assert!(
            host.last_await_value.contains("alice"),
            "awaited SELECT JSON: {} diagnostics: {:?}",
            host.last_await_value,
            host.diagnostics
        );
        assert!(
            host.diagnostics
                .iter()
                .any(|d| d.contains("WASM-AWAIT-VOID")),
            "await was claimed: {:?}",
            host.diagnostics
        );
        drop(host);
        assert_eq!(
            session
                .dom
                .get_element_by_id("status")
                .unwrap()
                .inner_text(),
            "PGLITE-SQL"
        );
        let uuid = session.program.store.open_purpose("registry").unwrap();
        let out = session
            .program
            .store
            .query(uuid, "SELECT name FROM t WHERE id = $1", &[Json::Int(1)])
            .unwrap();
        assert_eq!(out.rows.len(), 1);
        assert_eq!(out.rows[0].get("name"), Some(&Json::Str("alice".into())));
    }

    #[test]
    fn lodash_pglite_refused_when_store_disabled() {
        let spec =
            BoardSpec::from_json_str(r#"{"schema_version":1,"kernel":{"store":{"enable":false}}}"#)
                .unwrap();
        let mut session = BrowserSession::new(&spec).unwrap();
        let mut host = KernelHost::attach_fresh(
            &mut session.dom,
            &session.program.router,
            &spec,
            Vec::new(),
            &mut session.timers,
            0,
            Some(&mut session.program.store),
        );
        let cmds =
            g6b_js::lodash_parse(r#"[{"func":"defaultTo","params":["=window.pglite"]}]"#).unwrap();
        let err =
            g6b_js::lodash_execute_host(JsValue::Null, &cmds, None, Some(&mut host)).unwrap_err();
        assert!(
            matches!(err, LodashError::EvalRefused(ref s) if s == "window.pglite"),
            "{err}"
        );
        assert_eq!(host.libwasm_global("pglite").unwrap(), 0);
    }

    fn count_dom(n: &Node) -> usize {
        1 + n.children.iter().map(count_dom).sum::<usize>()
    }

    #[test]
    fn libwasm_session_builds_static_tree() {
        if !g6b_wasm::bios_ui_libwasm_live() {
            // The LDC/libwasm artifact is a build-time input; when it is not
            // shipped this check is vacuous rather than a failure.
            return;
        }
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let mut program = load_program(&spec).unwrap();
        let mut dom =
            g6b_html::parse_checked(&g6b_ui::setup_html_libwasm(&spec, "/ui/ui-libwasm.wasm"))
                .unwrap();
        // The guest's handle 1 is a fresh `<div>` mount under `libwasm-root`;
        // `mount_path` keeps handle-1 resolution separate from the page DOM so
        // guest `fetch` paints the setup panels while the Svelte tree stages
        // under the mount.
        let root_path = path_from_root(&dom, "libwasm-root").expect("libwasm-root in libwasm page");
        let mount_path = {
            let root = node_at_mut(&mut dom, &root_path).unwrap();
            root.children.push(Node::elem("div"));
            let mut p = root_path.clone();
            p.push(root.children.len() - 1);
            p
        };
        let module = decode_libwasm().unwrap();
        let mut timers = TimerHeap::new();
        let mut host = KernelHost::attach_fresh(
            &mut dom,
            &program.router,
            &spec,
            mount_path.clone(),
            &mut timers,
            0,
            Some(&mut program.store),
        );
        if let Err(e) = run_libwasm_start(&module, &mut host) {
            panic!(
                "libwasm _start failed: {e}\ndiagnostics: {:?}",
                host.diagnostics
            );
        }
        let diagnostics = host.diagnostics.clone();
        drop(host);
        let mount = node_at(&dom, &mount_path).unwrap();
        let nodes = count_dom(mount);
        assert!(
            nodes >= 80,
            "libwasm tree has {nodes} nodes; diagnostics: {diagnostics:?}"
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
