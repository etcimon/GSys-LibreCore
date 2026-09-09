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
use g6b_js::JsValue;
use g6b_js::Op;
use g6b_spec::BoardSpec;
use g6b_wasm::{Host, Ldexec, LdexecInit, LibwasmValue, ObjectKind, ObjectTable};
use std::collections::BTreeMap;

pub mod browser;
pub mod task_services;
pub mod tasks;
pub mod timers;
pub use browser::{RouterPort, WasmUi};
pub use task_services::{TaskServices, Work, WorkResponse};
pub use timers::{frame_period_ns, TimerHeap};

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
    objects: ObjectTable<LibwasmValue>,
    /// Event listeners registered by the libwasm `_start` call and collected
    /// after `run_start` returns so `BrowserSession` can own them.
    pending_event_listeners: Vec<(String, String, u64, bool)>,
    pending_event_removals: Vec<u64>,
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
    ) -> Self {
        Self {
            dom,
            router,
            spec,
            diagnostics: Vec::new(),
            handles: persist.handles,
            mount_path: persist.mount_path,
            placements: persist.placements,
            child_handles: persist.child_handles,
            pending_slot: None,
            objects: persist.objects,
            pending_event_listeners: Vec::new(),
            pending_event_removals: Vec::new(),
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
        }
    }

    fn attach_fresh(
        dom: &'a mut Node,
        router: &'a Router,
        spec: &'a BoardSpec,
        mount_path: Vec<usize>,
        timers: &'a mut crate::timers::TimerHeap,
        now_ns: u64,
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
    fn intern_event(&mut self, event: &Event) -> Result<i32, String> {
        self.last_prevent_default = event.default_prevented;
        self.intern_value(LibwasmValue::Object {
            kind: ObjectKind::Event,
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
            return Err("WASM invalid DOM hierarchy".into());
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
                "location" | "origin" => Ok(LibwasmValue::String("bios://g6lc".into())),
                _ => value.clone_prop(name),
            },
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
            LibwasmValue::Object { kind, .. } if *kind == ObjectKind::Event => match method {
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
            },
            LibwasmValue::Object { kind, .. } if *kind == ObjectKind::Window => {
                if method == "fetch" {
                    let url = args.first().map(|v| v.to_js_string()).unwrap_or_default();
                    let handle = self.fetch(&url)?;
                    return Ok(LibwasmValue::I32(handle));
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
        let value = g6b_js::lodash_execute(init, &commands, None).map_err(|e| e.to_string())?;
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

/// Drive a libwasm module's `_start` against `host`. Mirrors
/// `g6b_wasm::run_start` but keeps a larger bounded Asyncify step budget so
/// artifacts that still carry the control exports can suspend per awaited
/// fetch; the shipped kernel module is decoded through `decode_libwasm`,
/// which strips them, so the lane normally runs `_start` in one
/// `run_with_fuel_mut` pass with synchronous await resolution.
fn run_libwasm_start(module: &g6b_wasm::Module, host: &mut KernelHost<'_>) -> Result<(), String> {
    const ASYNCIFY_STACK_SIZE: u32 = 4096;
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
        let data = heap_base as u32;
        let stack_end = data + ASYNCIFY_STACK_SIZE;
        let needed = (stack_end as usize).saturating_sub(m.memory.len());
        if needed > 0 {
            let pages = needed.div_ceil(65536) as u32;
            m.mem_pages += pages;
            m.memory
                .resize(m.memory.len() + (pages as usize) * 65536, 0);
        }
        let mut step = a.step(&mut m, idx, &args, data, stack_end, host)?;
        for _ in 0..ASYNCIFY_STEP_LIMIT {
            match step {
                g6b_wasm::Step::Done(_) => return Ok(()),
                g6b_wasm::Step::Sleeping { slot, .. } => {
                    host.resolve_slot(slot)?;
                    step = a.resume(&mut m, idx, &args, data, stack_end, host)?;
                }
            }
        }
        return Err("asyncify step limit".into());
    }

    g6b_wasm::run_with_fuel_mut(&mut m, idx, &args, host, g6b_wasm::MAX_FUEL).map(|_| ())
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
        // The kernel lane resolves awaits synchronously: `libwasm_module`
        // strips the `asyncify_*` exports so the interpreter runs `_start`
        // in a single pass and never unwinds (the interpreter forces
        // `STATE_UNWINDING` after every `libwasm_await__void` call, so a
        // suspend/resolve/resume drive would re-suspend the replayed call
        // forever).  Settle the slot now; the guest reads the value through
        // `libwasm_await_value` / `libwasm_await_failed` immediately after.
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
        // svelte-engine: addObject(document.querySelector('#root')).
        // Prefer #libwasm-root (BIOS mount), then #root, else the Spa mount.
        for id in ["libwasm-root", "root"] {
            if let Some(p) = path_from_root(self.dom, id) {
                return self.intern_session_node(p);
            }
        }
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

    /// The kernel lane resolves awaits in place (see `decode_libwasm`), so
    /// the guest's `if (libwasm_await_supported())` blocks run synchronously.
    fn await_supported(&self) -> i32 {
        1
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
            LibwasmReceiver::Value(v) => self.value_getter(&v, name),
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

/// Decode the shipped libwasm cell for the kernel lane. The `asyncify_*`
/// control exports are stripped: the interpreter forces `STATE_UNWINDING`
/// after every `libwasm_await__void` call, so a suspend/resolve/resume
/// drive would re-suspend the replayed import forever (the guest re-issues
/// the call on rewind and there is no host-visible way to settle it
/// without another unwind). With the exports gone the runtime reports
/// `await_supported` from the host and `KernelHost::libwasm_await_void`
/// settles each promise in place — `_start` then runs to completion in a
/// single pass.
fn decode_libwasm() -> Result<g6b_wasm::Module, String> {
    let mut m = g6b_wasm::decode(g6b_wasm::bios_ui_libwasm())?;
    m.exports.retain(|e| !e.name.starts_with("asyncify_"));
    Ok(m)
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
    /// Cell-owned click (`g6b_listen` with listener 0): tab navigate or refresh.
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
            surface: spec.default_surface(),
            selected_menu: spec.kernel.start_menu.clone(),
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
        let module = decode_libwasm()?;
        let mut host = KernelHost::attach_fresh(
            &mut self.dom,
            &self.program.router,
            spec,
            mount_path,
            &mut self.timers,
            self.now_ns,
        );
        run_libwasm_start(&module, &mut host)?;
        if spec.kernel.http.files.assets {
            let css = {
                let mut port = crate::browser::RouterPort {
                    router: host.router,
                    spec: host.spec,
                };
                g6b_wasm::KernelPort::fetch_text(&mut port, "/ui/bios-ui.css")
            };
            if let Ok((200, body)) = css {
                let _ = host.add_css(&body);
            }
        }
        let _ = host.ensure_js_globals();
        let diagnostics = std::mem::take(&mut host.diagnostics);
        let pending = std::mem::take(&mut host.pending_event_listeners);
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
                },
                func,
                &[t.ctx],
            );
            self.wasm_ui = Some(ui);
            match fired {
                Ok(call) => {
                    self.diagnostics.extend(call.diagnostics);
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
        event.client_x = x;
        event.client_y = y;
        let hover_id = hit.id.clone();
        let allowed = Node::dispatch_event(body, &hit.path, &mut event, &mut self.event_host);
        if event_type == "mousemove"
            || event_type == "mouseover"
            || event_type == "pointermove"
            || event_type == "click"
        {
            set_hover_attr(&mut self.dom, hover_id.as_deref());
        }
        let wasm_prevented = self.run_triggered();
        if allowed && !wasm_prevented && event_type == "click" {
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
        Ok(allowed && !wasm_prevented)
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
                        },
                        function_index,
                        handle,
                        &event,
                    ) {
                        Ok(call) => {
                            self.diagnostics.extend(call.diagnostics);
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
            Some(Listener::Cell) => {
                self.cell_click(&event)?;
                self.diagnostics.push(format!("EVENT-CELL-TRIGGERED {id}"));
                Ok(true)
            }
            None => Ok(false),
        }
    }

    /// Cell protocol for tab/refresh clicks (B87). preventDefault is implied
    /// so href navigation and the Rust default `select_menu` do not double-run.
    fn cell_click(&mut self, event: &Event) -> Result<(), String> {
        let Some(id) = event.target.as_deref() else {
            return Ok(());
        };
        if id == "refresh" {
            self.refresh()?;
            if let Some(n) = self.dom.get_element_by_id("status") {
                n.set_inner_text("UI-BOOT: values refreshed; read-only setup");
            }
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
        if let Some(n) = self.dom.get_element_by_id("status") {
            n.set_inner_text(&format!("UI-BOOT: {menu} menu; read-only setup"));
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
/// (`#disp-toggle` / `#disp-status`), matching the old HTML wrap.
fn live_paint_targets(dom: &Node) -> Vec<&Node> {
    let root = live_paint_root(dom);
    let mut out = vec![root];
    for id in ["disp-toggle", "disp-status"] {
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

/// HTML and CSS to feed the CSS raster from a live DOM (the Svelte tree
/// after `_start` when the libwasm lane is live). Track-B 4bpp `ui_ppm`
/// still uses this; the 32-bit session path is `Engine::paint(&Node)`.
fn live_render_html(dom: &Node, spec: &BoardSpec) -> Result<(String, String), String> {
    let shell = if libwasm_lane(spec) {
        g6b_ui::setup_html_libwasm(spec, "/ui/ui-libwasm.wasm")
    } else {
        g6b_ui::setup_html(spec)
    };
    let mut css = extract_style(&shell);
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
    if !libwasm_lane(spec) {
        return Ok((shell, css));
    }
    let spa = find_node_by_id(dom, "libwasm-spa").ok_or("libwasm-spa missing from executed DOM")?;
    let main =
        first_descendant_by_name(spa, "main").ok_or("libwasm main missing from libwasm-spa")?;
    let mut main_html = dom_to_html(main);
    // Shell chrome that the Svelte tree does not yet own (display toggle)
    // still has to participate in hit-testing on the live session.
    for id in ["disp-toggle", "disp-status"] {
        if main_html.contains(&format!("id=\"{id}\"")) {
            continue;
        }
        if let Some(n) = find_node_by_id(dom, id) {
            main_html.push_str(&dom_to_html(n));
        }
    }
    let html = format!(
        "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\">\
         <title>G6LC-BIOS</title><style>{}</style></head><body>{}</body></html>",
        css, main_html
    );
    Ok((html, css))
}

/// HTML and CSS to feed the CSS raster. Uses the executed `BrowserSession`
/// DOM so the Svelte tree, not the static shell, is painted.
fn renderable_setup_html(spec: &BoardSpec) -> Result<(String, String), String> {
    live_render_html(&rendered_dom(spec), spec)
}

/// Host PPM of the setup page (SysGrInit rewrite).
pub fn gr_ppm(spec: &BoardSpec) -> Vec<u8> {
    let mut frame = g6b_gr::Frame::from_spec(spec);
    let dom = rendered_dom(spec);
    frame.paint_lines(&to_uart_lines(&dom, frame.cols as usize));
    frame.to_ppm()
}

/// CSS-raster PPM of the setup page. Parses the stylesheet embedded in the
/// executed or static HTML and renders the body with colour, background and text.
/// This is the track-B "real UI" output from architecture/RENDER-VALIDATION.md.
pub fn ui_ppm(spec: &BoardSpec) -> Result<Vec<u8>, String> {
    let (html, css) = renderable_setup_html(spec)?;
    let w = spec.kernel.gr.w.max(320);
    let h = spec.kernel.gr.h.max(200);
    let out = g6b_css::render::render_ui_to_output(&html, &css, w, h)?;
    Ok(out.canvas.to_ppm())
}

/// CSS-raster output of the setup page including the hit boxes for event
/// dispatch.
pub fn ui_ppm_output(spec: &BoardSpec) -> Result<g6b_css::render::RenderOutput, String> {
    let (html, css) = renderable_setup_html(spec)?;
    let w = spec.kernel.gr.w.max(320);
    let h = spec.kernel.gr.h.max(200);
    g6b_css::render::render_ui_to_output(&html, &css, w, h)
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
/// as `BrowserSession`, not `start_ops` `Object_Call`.
pub struct GuestCellScanout {
    pub present: g6b_asm::exec::GuestWebPresent,
    pub wasm_executed: bool,
    pub diagnostics: Vec<String>,
}

/// Pack the live BrowserSession canvas + dirty tiles for guest `__ui_cap`.
/// The guest `VioPaint` TRANSFERs those rects; `start_ops` is not grown.
/// Canvas is placed at (0,0) in the output-stride `__scan_fb` so a 640×480
/// engine raster still TRANSFERs correctly into a 1920×1080 resource.
pub fn guest_web_present(spec: &BoardSpec) -> Result<g6b_asm::exec::GuestWebPresent, String> {
    Ok(guest_cell_scanout(spec)?.present)
}

/// Run the LDC cell through [`KernelHost`] (same `Host` import set as the
/// UI thread), then pack scanout. Fails if the cell did not execute.
pub fn guest_cell_scanout(spec: &BoardSpec) -> Result<GuestCellScanout, String> {
    let mut session = BrowserSession::new(spec)?;
    if !session.wasm_executed {
        return Err("LDC libwasm cell did not run on KernelHost".into());
    }
    let _ = session.paint_css()?;
    let _ = session.present_scanout()?;
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
    Ok(GuestCellScanout {
        present: g6b_asm::exec::GuestWebPresent {
            scan_fb: packed,
            tiles: session
                .last_tiles()
                .iter()
                .map(|t| g6b_asm::exec::DirtyTile {
                    x: t.x,
                    y: t.y,
                    w: t.w,
                    h: t.h,
                })
                .collect(),
            node_count: count_dom_nodes(&session.dom),
        },
        wasm_executed: session.wasm_executed,
        diagnostics: session.diagnostics.clone(),
    })
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
fn set_hover_attr(root: &mut Node, id: Option<&str>) {
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
        mark(root, id);
    }
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
        );
        let window = host.libwasm_global("window").unwrap();
        let document = host.libwasm_global("document").unwrap();
        let console = host.libwasm_global("console").unwrap();
        assert!(window >= g6b_wasm::OBJECT_BASE, "{window}");
        assert_ne!(window, document);
        assert_ne!(window, console);
        assert_eq!(host.libwasm_global("window").unwrap(), window);
        assert_eq!(host.libwasm_global("eval").unwrap(), 0);
        let root = host.get_root().unwrap();
        assert!(root >= 2, "getRoot is a new handle, not BoardSpec: {root}");
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
                .any(|d| d.contains("WASM-CELL-LISTEN")),
            "cell-owned tab/refresh listeners: {:?}",
            session.diagnostics
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
        let program = load_program(&spec).unwrap();
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
