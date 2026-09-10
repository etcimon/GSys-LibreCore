// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! BIOS iframe session controller (`architecture/plan-iframe.md` §5).
//!
//! libwasm `HTMLIFrameElement` `src` / `srcdoc` navigate an existing
//! [`IframeSession`]. Not a goosie replaced CSS box. Fetch and KernelPort stay
//! in `g6b-kernel` / `g6b-http`; this crate is location dispatch, history,
//! load phase, hooks, caps, and session **data** (no DOM nodes, no HTML strings).
//!
//! Nested `createBrowserContext` / interned `contentWindow` is B92e
//! ([`SessionContext`] / [`SessionIntern`]; kernel maps tokens to a guest
//! object table. Nested `/ui/*.wasm` cells are still later in B92e).
//!
//! Window/tab chrome is Svelte (`plan-iframe.md` §3–§4). This crate is a
//! **session pool**: [`FrameEngine::ensure`] / [`FrameEngine::drop`] /
//! navigate. Kernel interaction is registration
//! ([`FrameEngine::register_hook`]) and fulfilling [`HostNeed`] GETs.

#![allow(missing_docs)]

mod engine;
mod vars;
pub use engine::{FrameEngine, FrameNote, HostNeed};
pub use vars::{
    parse_vars_attr, session_var_name_allowed, SessionVar, SessionVars, VarsAttr, MAX_SESSION_VARS,
    PROP_VARS, RESERVED_VAR_NAMES,
};

/// Fail-closed budgets (`plan-iframe.md` §3). `MAX_WINDOWS` / `MAX_TABS_PER_WINDOW`
/// are Svelte chrome limits; this crate enforces [`MAX_SESSIONS`] slots.
pub const MAX_WINDOWS: usize = 4;
pub const MAX_TABS_PER_WINDOW: usize = 8;
pub const MAX_SESSIONS: usize = 8;
pub const MAX_HISTORY: usize = 32;

/// libwasm `HTMLIFrameElement` property names (Object_Call / Object_Getter).
pub const PROP_SRC: &str = "src";
pub const PROP_SRCDOC: &str = "srcdoc";
pub const PROP_CONTENT_WINDOW: &str = "contentWindow";
pub const PROP_CONTENT_DOCUMENT: &str = "contentDocument";

/// Shell `createBrowserContext` id. Iframe sessions never use this.
pub const SHELL_CONTEXT_ID: &str = "main";

/// True when `id` is the BIOS UI context (`plan-iframe.md` §5.1).
pub fn is_shell_context_id(id: &str) -> bool {
    id == SHELL_CONTEXT_ID
}

/// Native imports a nested cell must not get without a cap (B92i).
pub const NATIVE_IMPORTS: &[&str] = &[
    "env.holyc",
    "holyc",
    "holycEval",
    "register_endpoint",
    "registerEndpoint",
    "env.register_endpoint",
    "platform",
    "hw",
    "env.platform",
];

/// Verifier: native imports fail closed unless the session cap is set.
pub fn session_import_allowed(name: &str, caps: SessionCaps) -> bool {
    match name {
        "env.holyc" | "holyc" | "holycEval" => caps.holyc,
        "register_endpoint" | "registerEndpoint" | "env.register_endpoint" => {
            caps.register_endpoint
        }
        "platform" | "hw" | "env.platform" | "window.platform" | "window.hw" => false,
        _ => true,
    }
}

pub fn session_import_reject(name: &str, caps: SessionCaps) -> Option<&'static str> {
    if session_import_allowed(name, caps) {
        None
    } else {
        Some("verifier reject: native import without cap")
    }
}

/// `#bios-session-N` stage id → tab slot. None for shell chrome.
pub fn session_stage_slot(id: &str) -> Option<usize> {
    let rest = id.strip_prefix("bios-session-")?;
    rest.parse().ok().filter(|&s| s < MAX_TABS_PER_WINDOW)
}

/// Per-session JS environment identity. Never [`SHELL_CONTEXT_ID`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionContext {
    pub slot: usize,
    pub generation: u32,
}

impl SessionContext {
    pub fn new(slot: usize) -> Self {
        Self {
            slot,
            generation: 1,
        }
    }

    pub fn id(&self) -> String {
        format!("frame-{}-g{}", self.slot, self.generation)
    }

    pub fn intern(&self) -> SessionIntern {
        SessionIntern {
            slot: self.slot,
            generation: self.generation,
        }
    }

    pub fn repopulate(&mut self) {
        self.generation = self.generation.saturating_add(1);
        if self.generation == 0 {
            self.generation = 1;
        }
    }
}

/// Opaque intern token. Kernel maps this to a **guest** object table.
/// Missing session → no `contentWindow` (never invent one).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SessionIntern {
    pub slot: usize,
    pub generation: u32,
}

/// Load phase shown in the BIOS status bar (`plan-iframe.md` §6.5).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SessionLoad {
    Idle,
    Loading,
    Ok,
    /// FileServe GET status for a local document.
    Http(u16),
    Error(String),
}

impl SessionLoad {
    pub fn status_word(&self) -> String {
        match self {
            Self::Idle => "idle".into(),
            Self::Loading => "loading".into(),
            Self::Ok => "ok".into(),
            Self::Http(n) => n.to_string(),
            Self::Error(e) => format!("error: {e}"),
        }
    }
}

/// Default-deny native access for an iframe session (`plan-iframe.md` §6.3).
/// HolyC / `registerEndpoint` / `/bios/menu` stay off until B92i. A registered
/// files hook may set [`SessionCaps::files_get`] only.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SessionCaps {
    pub holyc: bool,
    pub register_endpoint: bool,
    pub bios_menu: bool,
    /// GET `/bios/files/*` — [`HookKind::Files`] only.
    pub files_get: bool,
}

impl SessionCaps {
    pub const fn deny() -> Self {
        Self {
            holyc: false,
            register_endpoint: false,
            bios_menu: false,
            files_get: false,
        }
    }

    pub const fn files() -> Self {
        Self {
            holyc: false,
            register_endpoint: false,
            bios_menu: false,
            files_get: true,
        }
    }

    pub const fn is_deny(self) -> bool {
        !self.holyc && !self.register_endpoint && !self.bios_menu && !self.files_get
    }
}

/// FileMgr listing for a registered `app:files` hook.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FilesVolume {
    pub name: String,
    pub listing: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FilesAppView {
    pub listing: String,
    pub volumes: Vec<FilesVolume>,
}

/// Local FileServe / srcdoc page as extracted title + text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PageView {
    pub title: Option<String>,
    pub text: String,
}

/// Session document. Data only — the host paints chrome from this.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SessionDocument {
    Blank,
    Srcdoc { text: String },
    Page(PageView),
    Files(FilesAppView),
}

impl SessionDocument {
    pub fn title(&self) -> Option<&str> {
        match self {
            Self::Page(p) => p.title.as_deref(),
            Self::Files(_) => Some("Files"),
            Self::Blank | Self::Srcdoc { .. } => None,
        }
    }

    pub fn paint_text(&self) -> String {
        match self {
            Self::Blank => "about:blank".into(),
            Self::Srcdoc { text } => text.clone(),
            Self::Page(p) => p.text.clone(),
            Self::Files(f) => {
                let mut out = f.listing.clone();
                for v in &f.volumes {
                    out.push('\n');
                    out.push_str(&v.name);
                    out.push('\n');
                    out.push_str(&v.listing);
                }
                out
            }
        }
    }
}

/// One tab's iframe session instance.
#[derive(Clone, Debug)]
pub struct IframeSession {
    pub location: String,
    pub history: Vec<String>,
    pub load: SessionLoad,
    pub document: SessionDocument,
    pub caps: SessionCaps,
    pub context: SessionContext,
    pub vars: SessionVars,
}

impl IframeSession {
    pub fn blank() -> Self {
        Self::blank_in(0)
    }

    pub fn blank_in(slot: usize) -> Self {
        Self {
            location: "about:blank".into(),
            history: vec!["about:blank".into()],
            load: SessionLoad::Ok,
            document: SessionDocument::Blank,
            caps: SessionCaps::deny(),
            context: SessionContext::new(slot),
            vars: SessionVars::new(),
        }
    }

    pub fn intern(&self) -> SessionIntern {
        self.context.intern()
    }
}

/// Declared I/O for a registered hook. Kernel only GETs these paths.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum HookKind {
    Files { volumes: Vec<String> },
}

/// Registered virtual-app hook (`plan-iframe.md` §7). Not an HTTP route.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AppHook {
    pub prefix: String,
    pub title: String,
    pub kind: HookKind,
}

impl AppHook {
    pub fn files() -> Self {
        Self::files_volumes(["fat32", "ntfs", "ext4"])
    }

    pub fn files_volumes(volumes: impl IntoIterator<Item = impl Into<String>>) -> Self {
        Self {
            prefix: "app:files".into(),
            title: "Files".into(),
            kind: HookKind::Files {
                volumes: volumes.into_iter().map(Into::into).collect(),
            },
        }
    }

    pub fn matches(&self, url: &str) -> bool {
        canonicalize_app_url(url).as_deref() == Some(self.prefix.as_str())
    }
}

/// `app:files` / `/apps/files` → `app:files`.
pub fn canonicalize_app_url(url: &str) -> Option<String> {
    let u = url.trim();
    let name = if let Some(rest) = u.strip_prefix("app:") {
        rest.split('/').next().unwrap_or("")
    } else if let Some(rest) = u.strip_prefix("/apps/") {
        rest.split('/').next().unwrap_or("")
    } else {
        return None;
    };
    if name.is_empty()
        || !name.starts_with(|c: char| c.is_ascii_lowercase())
        || !name
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
    {
        return None;
    }
    Some(format!("app:{name}"))
}

pub fn match_hook<'a>(url: &str, hooks: &'a [AppHook]) -> Option<&'a AppHook> {
    hooks.iter().find(|h| h.matches(url))
}

/// Dispatch of a tab location string. Never guess.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FrameLocation {
    AboutBlank,
    Srcdoc,
    /// Local FileServe HTML (`/ui/*.html`).
    UiHtml(String),
    /// Virtual app (`app:files`, `/apps/files`). Hook registry decides load.
    App(String),
    /// `http:` / `https:` — B92g; fetch only when outbound is armed.
    Remote(String),
    Refused(&'static str),
}

/// What the host must do after `src` / `srcdoc` on an existing session.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LoadPlan {
    Blank,
    /// Parse `html` locally; do not fetch.
    Srcdoc {
        html: String,
    },
    /// KernelPort GET of a FileServe HTML path (not `/bios/*`).
    FetchHtml {
        path: String,
    },
    /// Gated outbound `http(s):` GET (`plan-iframe.md` §6.2). Not `/bios/*`.
    FetchRemote {
        url: String,
    },
    /// Registered virtual-app hook.
    Hook {
        prefix: String,
        url: String,
    },
    Fail {
        location: String,
        error: String,
    },
}

/// True when `tag` is an iframe controller node.
pub fn is_iframe_tag(tag: &str) -> bool {
    tag.eq_ignore_ascii_case("iframe")
}

/// Parse a location for an existing [`IframeSession`]. `srcdoc` is a
/// separate loader (no URL fetch).
pub fn parse_frame_location(url: &str) -> FrameLocation {
    let url = url.trim();
    if url.is_empty() || url == "about:blank" {
        return FrameLocation::AboutBlank;
    }
    if url == "about:srcdoc" {
        return FrameLocation::Srcdoc;
    }
    let scheme = url.split_once(':').map(|(s, _)| s);
    match scheme {
        Some("javascript") | Some("file") | Some("data") => {
            return FrameLocation::Refused("javascript:/file:/data: documents refused");
        }
        Some("http") | Some("https") => return FrameLocation::Remote(url.into()),
        _ => {}
    }
    if canonicalize_app_url(url).is_some() {
        return FrameLocation::App(url.into());
    }
    if url.contains(':') && !url.starts_with('/') {
        return FrameLocation::Refused("unknown location scheme");
    }
    if url.starts_with("/bios/") {
        return FrameLocation::Refused("iframe cannot load /bios");
    }
    match local_html_url(url) {
        Some(path) => FrameLocation::UiHtml(path.into()),
        None => FrameLocation::Refused("not a local /ui HTML document"),
    }
}

/// Plan a `src` navigation on an existing session (no virtual-app hooks).
pub fn plan_navigate(url: &str) -> LoadPlan {
    plan_navigate_gated(url, &[], false)
}

/// Plan navigation against a registered hook list (`plan-iframe.md` §7).
pub fn plan_navigate_with_hooks(url: &str, hooks: &[AppHook]) -> LoadPlan {
    plan_navigate_gated(url, hooks, false)
}

/// `outbound` arms `http(s):` (`kernel.http.outbound`). Remote wasm is refused.
pub fn plan_navigate_gated(url: &str, hooks: &[AppHook], outbound: bool) -> LoadPlan {
    match parse_frame_location(url) {
        FrameLocation::AboutBlank => LoadPlan::Blank,
        FrameLocation::Srcdoc => LoadPlan::Fail {
            location: "about:srcdoc".into(),
            error: "srcdoc requires the srcdoc attribute".into(),
        },
        FrameLocation::UiHtml(path) => LoadPlan::FetchHtml { path },
        FrameLocation::App(requested) => {
            if let Some(h) = match_hook(&requested, hooks) {
                LoadPlan::Hook {
                    prefix: h.prefix.clone(),
                    url: requested,
                }
            } else {
                LoadPlan::Fail {
                    location: requested,
                    error: "app: hook not registered".into(),
                }
            }
        }
        FrameLocation::Remote(location) => {
            if remote_wasm_url(&location) {
                LoadPlan::Fail {
                    location,
                    error: "remote wasm cells refused".into(),
                }
            } else if outbound {
                LoadPlan::FetchRemote { url: location }
            } else {
                LoadPlan::Fail {
                    location,
                    error: "outbound fetch disabled".into(),
                }
            }
        }
        FrameLocation::Refused(error) => LoadPlan::Fail {
            location: url.trim().into(),
            error: error.into(),
        },
    }
}

fn remote_wasm_url(url: &str) -> bool {
    let path = url.split(['?', '#']).next().unwrap_or(url);
    path.rsplit('/')
        .next()
        .is_some_and(|n| n.ends_with(".wasm"))
}

/// Plan a `srcdoc` load: parse the attribute, skip fetch.
pub fn plan_srcdoc(html: &str) -> LoadPlan {
    LoadPlan::Srcdoc { html: html.into() }
}

/// `/ui/*.html` (or `/ui/` directory page). Same path hygiene as kernel fetch.
pub fn local_html_url(url: &str) -> Option<&str> {
    let path = url.split(['?', '#']).next().unwrap_or(url);
    if !path.starts_with("/ui/")
        || path.starts_with("//")
        || path.contains('\\')
        || path.contains(':')
        || path.chars().any(char::is_control)
        || path.split('/').any(|p| matches!(p, "." | ".."))
    {
        return None;
    }
    if path.ends_with(".html") || path == "/ui/" {
        Some(path)
    } else {
        None
    }
}

/// v1 history is replace, not push (`plan-iframe.md` §4).
pub fn replace_history(session: &mut IframeSession, url: String) {
    session.location = url.clone();
    if session.history.is_empty() {
        session.history.push(url);
    } else if let Some(last) = session.history.last_mut() {
        *last = url;
    }
    if session.history.len() > MAX_HISTORY {
        let n = session.history.len() - MAX_HISTORY;
        session.history.drain(..n);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_dispatches_and_refuses() {
        assert_eq!(parse_frame_location(""), FrameLocation::AboutBlank);
        assert_eq!(
            parse_frame_location("about:blank"),
            FrameLocation::AboutBlank
        );
        assert_eq!(
            parse_frame_location("/ui/help.html"),
            FrameLocation::UiHtml("/ui/help.html".into())
        );
        assert_eq!(
            parse_frame_location("https://example/path"),
            FrameLocation::Remote("https://example/path".into())
        );
        assert!(matches!(
            parse_frame_location("javascript:alert(1)"),
            FrameLocation::Refused(_)
        ));
        assert!(matches!(
            parse_frame_location("/bios/menu/cpu"),
            FrameLocation::Refused(_)
        ));
        assert!(matches!(
            parse_frame_location("/ui/g6lc.svg"),
            FrameLocation::Refused(_)
        ));
        assert_eq!(
            parse_frame_location("app:files"),
            FrameLocation::App("app:files".into())
        );
        assert_eq!(
            parse_frame_location("/apps/files"),
            FrameLocation::App("/apps/files".into())
        );
        assert!(canonicalize_app_url("app:1files").is_none());
        assert!(canonicalize_app_url("app:_files").is_none());
        assert_eq!(
            plan_navigate("app:files"),
            LoadPlan::Fail {
                location: "app:files".into(),
                error: "app: hook not registered".into(),
            }
        );
        let hooks = [AppHook::files()];
        assert_eq!(
            plan_navigate_with_hooks("app:files", &hooks),
            LoadPlan::Hook {
                prefix: "app:files".into(),
                url: "app:files".into(),
            }
        );
        assert_eq!(
            plan_navigate_with_hooks("/apps/files", &hooks),
            LoadPlan::Hook {
                prefix: "app:files".into(),
                url: "/apps/files".into(),
            }
        );
        assert!(matches!(
            plan_navigate_with_hooks("app:ssh", &hooks),
            LoadPlan::Fail { .. }
        ));
    }

    #[test]
    fn plan_src_fetch_srcdoc_remote() {
        assert_eq!(plan_navigate("about:blank"), LoadPlan::Blank);
        assert_eq!(
            plan_navigate("/ui/help.html"),
            LoadPlan::FetchHtml {
                path: "/ui/help.html".into()
            }
        );
        assert_eq!(
            plan_navigate("https://example/path"),
            LoadPlan::Fail {
                location: "https://example/path".into(),
                error: "outbound fetch disabled".into(),
            }
        );
        assert_eq!(
            plan_navigate_gated("https://example/path", &[], true),
            LoadPlan::FetchRemote {
                url: "https://example/path".into()
            }
        );
        assert!(matches!(
            plan_navigate_gated("https://example/app.wasm", &[], true),
            LoadPlan::Fail { .. }
        ));
        assert_eq!(
            plan_srcdoc("<p id=\"x\">hi</p>"),
            LoadPlan::Srcdoc {
                html: "<p id=\"x\">hi</p>".into()
            }
        );
        assert!(!matches!(plan_srcdoc("<p>"), LoadPlan::FetchHtml { .. }));
    }

    #[test]
    fn history_replaces_current_entry() {
        let mut s = IframeSession::blank();
        replace_history(&mut s, "/ui/help.html".into());
        assert_eq!(s.location, "/ui/help.html");
        assert_eq!(s.history, vec!["/ui/help.html"]);
        replace_history(&mut s, "/ui/index.html".into());
        assert_eq!(s.history, vec!["/ui/index.html"]);
    }

    #[test]
    fn files_app_view_is_data() {
        let doc = SessionDocument::Files(FilesAppView {
            listing: "{\"volumes\":[\"fat32\"]}".into(),
            volumes: vec![FilesVolume {
                name: "fat32".into(),
                listing: "a.bin".into(),
            }],
        });
        assert_eq!(doc.title(), Some("Files"));
        assert!(doc.paint_text().contains("fat32"));
        assert!(doc.paint_text().contains("a.bin"));
        assert!(is_iframe_tag("iframe"));
        assert!(!is_iframe_tag("img"));
        assert!(!is_shell_context_id(&SessionContext::new(0).id()));
        assert!(is_shell_context_id(SHELL_CONTEXT_ID));
        assert_eq!(session_stage_slot("bios-session-3"), Some(3));
        assert!(session_stage_slot("tab-cpu").is_none());
        assert!(session_import_reject("env.holyc", SessionCaps::deny()).is_some());
        assert!(session_import_reject("env.holyc", SessionCaps::files()).is_some());
        assert!(session_import_allowed(
            "libwasm_global",
            SessionCaps::deny()
        ));
        assert!(NATIVE_IMPORTS.contains(&"env.holyc"));
    }
}
