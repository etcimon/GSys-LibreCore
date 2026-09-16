// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Session pool. Window/tab chrome is Svelte (`plan-iframe.md` §3–§4).
//! Hosts register hooks and fulfill [`HostNeed`] fetches.

use crate::{
    child_path_allowed, match_hook, plan_navigate_gated, plan_srcdoc, replace_history, AppHook,
    EmbedGrant, FilesAppView, FilesVolume, HookKind, IframeSession, LoadPlan, PageView,
    SessionCaps, SessionDocument, SessionIntern, SessionLoad, SessionVars, MAX_SESSIONS,
};

/// What the kernel (or JS host) must fetch. No I/O here.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum HostNeed {
    None,
    /// GET a FileServe HTML document.
    Html {
        slot: usize,
        path: String,
        gen: u32,
    },
    /// GET FileMgr index + volume listings (registered `app:files` only).
    Files {
        slot: usize,
        index: String,
        /// `(volume name, GET path)`.
        volumes: Vec<(String, String)>,
    },
    /// Gated outbound `http(s):` GET. Never `/bios/*`, never HolyC.
    RemoteHtml {
        slot: usize,
        url: String,
        gen: u32,
    },
}

/// Diagnostic token for the host log.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FrameNote {
    pub text: String,
}

/// Session pool. Slots are chosen by Svelte chrome (tab index, inline iframe).
#[derive(Clone, Debug)]
pub struct FrameEngine {
    sessions: [Option<IframeSession>; MAX_SESSIONS],
    hooks: Vec<AppHook>,
    outbound: bool,
    grant: Option<EmbedGrant>,
}

impl Default for FrameEngine {
    fn default() -> Self {
        Self::new()
    }
}

impl FrameEngine {
    pub fn new() -> Self {
        Self {
            sessions: std::array::from_fn(|_| None),
            hooks: Vec::new(),
            outbound: false,
            grant: None,
        }
    }

    pub fn set_grant(&mut self, grant: EmbedGrant) {
        self.grant = Some(grant);
    }

    pub fn set_outbound(&mut self, armed: bool) {
        self.outbound = armed;
    }

    pub fn outbound(&self) -> bool {
        self.outbound
    }

    /// Slots that stored an `http(s):` location while outbound was unarmed.
    /// Kernel re-navigates these when `g6b-hw` announces net support.
    pub fn outbound_waiters(&self) -> Vec<(usize, String)> {
        self.sessions
            .iter()
            .enumerate()
            .filter_map(|(slot, s)| {
                let s = s.as_ref()?;
                let remote =
                    s.location.starts_with("http://") || s.location.starts_with("https://");
                let waiting = matches!(
                    &s.load,
                    SessionLoad::Error(e) if e.contains("outbound fetch disabled")
                );
                if remote && waiting {
                    Some((slot, s.location.clone()))
                } else {
                    None
                }
            })
            .collect()
    }

    pub fn register_hook(&mut self, hook: AppHook) {
        if !self.hooks.iter().any(|h| h.prefix == hook.prefix) {
            self.hooks.push(hook);
        }
    }

    pub fn session(&self, slot: usize) -> Option<&IframeSession> {
        self.sessions.get(slot).and_then(|s| s.as_ref())
    }

    pub fn occupied(&self) -> usize {
        self.sessions.iter().filter(|s| s.is_some()).count()
    }

    /// Intern token for `contentWindow` / `contentDocument`. None if no session.
    pub fn content_window(&self, slot: usize) -> Option<SessionIntern> {
        self.session(slot).map(IframeSession::intern)
    }

    pub fn content_document(&self, slot: usize) -> Option<SessionIntern> {
        self.content_window(slot)
    }

    /// Create a blank session at `slot`. Idempotent if that slot is live.
    /// Svelte owns whether a tab chip or inline mount is shown.
    pub fn ensure(&mut self, slot: usize) -> FrameNote {
        if slot >= MAX_SESSIONS {
            return FrameNote {
                text: format!("SESSION-BUDGET {slot}"),
            };
        }
        if self.sessions[slot].is_none() {
            self.sessions[slot] = Some(IframeSession::blank_in(slot));
        }
        FrameNote {
            text: format!("SESSION-ENSURE {slot}"),
        }
    }

    pub fn drop(&mut self, slot: usize) -> FrameNote {
        if slot < MAX_SESSIONS {
            self.sessions[slot] = None;
        }
        FrameNote {
            text: format!("SESSION-DROP {slot}"),
        }
    }

    pub fn drop_all(&mut self) -> FrameNote {
        self.sessions = std::array::from_fn(|_| None);
        FrameNote {
            text: "SESSION-DROP-ALL".into(),
        }
    }

    /// Parent `vars` map for this slot. Survives navigate (including remote fail).
    pub fn set_vars(&mut self, slot: usize, vars: SessionVars) -> FrameNote {
        if let Some(s) = self.sessions.get_mut(slot).and_then(|s| s.as_mut()) {
            let n = vars.len();
            s.vars = vars;
            return FrameNote {
                text: format!("SESSION-VARS {slot} {n}"),
            };
        }
        FrameNote {
            text: format!("SESSION-VARS {slot} idle"),
        }
    }

    /// Apply a `src` navigation. Fetch work is returned as [`HostNeed`].
    pub fn navigate(&mut self, slot: usize, url: &str) -> (HostNeed, FrameNote) {
        if slot >= MAX_SESSIONS || self.sessions.get(slot).is_none_or(Option::is_none) {
            return (
                HostNeed::None,
                FrameNote {
                    text: format!("FRAME-NAV {slot} idle"),
                },
            );
        }
        if url.contains('@') || url.contains("password=") {
            return (
                HostNeed::None,
                FrameNote {
                    text: format!("FRAME-NAV {slot} error: credentials in url"),
                },
            );
        }
        if let Some(g) = &self.grant {
            if crate::nested_nav_allowed(g, url).is_err() {
                let path = url.split(['?', '#']).next().unwrap_or(url);
                if child_path_allowed(path).is_err() || url.starts_with("https://") {
                    return (
                        HostNeed::None,
                        FrameNote {
                            text: format!(
                                "FRAME-NAV {slot} error: child must not target parent /bios/*"
                            ),
                        },
                    );
                }
            }
        }
        match plan_navigate_gated(url, &self.hooks, self.outbound) {
            LoadPlan::Blank => {
                self.repopulate_slot(slot);
                self.apply_doc(slot, "about:blank", SessionLoad::Ok, SessionDocument::Blank);
                (
                    HostNeed::None,
                    FrameNote {
                        text: format!("FRAME-NAV {slot} about:blank"),
                    },
                )
            }
            LoadPlan::Srcdoc { html } => {
                self.repopulate_slot(slot);
                self.apply_doc(
                    slot,
                    "about:srcdoc",
                    SessionLoad::Ok,
                    SessionDocument::Srcdoc { text: html },
                );
                (
                    HostNeed::None,
                    FrameNote {
                        text: format!("FRAME-SRCDOC {slot}"),
                    },
                )
            }
            LoadPlan::FetchHtml { path } => {
                self.begin_load(slot, &path, SessionCaps::deny());
                let gen = self.slot_gen(slot);
                (
                    HostNeed::Html {
                        slot,
                        path: path.clone(),
                        gen,
                    },
                    FrameNote {
                        text: format!("FRAME-NAV {slot} {path} fetch"),
                    },
                )
            }
            LoadPlan::FetchRemote { url: loc } => {
                self.begin_load(slot, &loc, SessionCaps::deny());
                let gen = self.slot_gen(slot);
                (
                    HostNeed::RemoteHtml {
                        slot,
                        url: loc.clone(),
                        gen,
                    },
                    FrameNote {
                        text: format!("FRAME-NAV {slot} {loc} outbound"),
                    },
                )
            }
            LoadPlan::Hook { prefix, url: loc } => self.hook_need(slot, &prefix, &loc),
            LoadPlan::Fail { location, error } => {
                self.repopulate_slot(slot);
                if let Some(s) = self.sessions[slot].as_mut() {
                    replace_history(s, location);
                    s.load = SessionLoad::Error(error.clone());
                    s.document = SessionDocument::Blank;
                    s.caps = SessionCaps::deny();
                }
                (
                    HostNeed::None,
                    FrameNote {
                        text: format!("FRAME-NAV {slot} error: {error}"),
                    },
                )
            }
        }
    }

    pub fn srcdoc(&mut self, slot: usize, html: &str) -> FrameNote {
        if slot >= MAX_SESSIONS || self.sessions.get(slot).is_none_or(Option::is_none) {
            return FrameNote {
                text: format!("FRAME-SRCDOC {slot} idle"),
            };
        }
        match plan_srcdoc(html) {
            LoadPlan::Srcdoc { html } => {
                self.repopulate_slot(slot);
                self.apply_doc(
                    slot,
                    "about:srcdoc",
                    SessionLoad::Ok,
                    SessionDocument::Srcdoc { text: html },
                );
                FrameNote {
                    text: format!("FRAME-SRCDOC {slot}"),
                }
            }
            _ => FrameNote {
                text: format!("FRAME-SRCDOC {slot} idle"),
            },
        }
    }

    fn slot_gen(&self, slot: usize) -> u32 {
        self.sessions
            .get(slot)
            .and_then(|s| s.as_ref())
            .map(|s| s.context.generation)
            .unwrap_or(0)
    }

    /// FileServe GET result for [`HostNeed::Html`]. Stale generation is refused.
    pub fn provide_html(&mut self, slot: usize, path: &str, status: u16, body: &str) -> FrameNote {
        self.provide_html_gen(slot, self.slot_gen(slot), path, status, body)
    }

    pub fn provide_html_gen(
        &mut self,
        slot: usize,
        gen: u32,
        path: &str,
        status: u16,
        body: &str,
    ) -> FrameNote {
        if self.slot_gen(slot) != gen {
            return FrameNote {
                text: format!("FRAME-NAV {slot} stale generation"),
            };
        }
        if status != 200 {
            if let Some(s) = self.sessions.get_mut(slot).and_then(|s| s.as_mut()) {
                replace_history(s, path.into());
                s.load = SessionLoad::Error(format!("HTTP {status}"));
            }
            return FrameNote {
                text: format!("FRAME-NAV {slot} {path} {status}"),
            };
        }
        let page = PageView::from_markup(body);
        self.apply_doc(
            slot,
            path,
            SessionLoad::Http(status),
            SessionDocument::Page(page),
        );
        FrameNote {
            text: format!("FRAME-NAV {slot} {path} {status}"),
        }
    }

    /// FileMgr GET results for [`HostNeed::Files`].
    pub fn provide_files(
        &mut self,
        slot: usize,
        listing: String,
        volumes: Vec<FilesVolume>,
    ) -> FrameNote {
        self.apply_doc(
            slot,
            "app:files",
            SessionLoad::Ok,
            SessionDocument::Files(FilesAppView { listing, volumes }),
        );
        FrameNote {
            text: format!("HOOK-FILES {slot} app:files"),
        }
    }

    pub fn provide_files_error(&mut self, slot: usize, status: u16) -> FrameNote {
        if let Some(s) = self.sessions.get_mut(slot).and_then(|s| s.as_mut()) {
            replace_history(s, "app:files".into());
            s.load = SessionLoad::Error(format!("HTTP {status}"));
            s.document = SessionDocument::Blank;
            s.caps = SessionCaps::deny();
        }
        FrameNote {
            text: format!("HOOK-FILES {slot} {status}"),
        }
    }

    fn hook_need(&mut self, slot: usize, prefix: &str, loc: &str) -> (HostNeed, FrameNote) {
        let kind = match_hook(loc, &self.hooks)
            .or_else(|| self.hooks.iter().find(|h| h.prefix == prefix))
            .map(|h| h.kind.clone());
        match kind {
            Some(HookKind::Files { volumes }) => {
                let vols = volumes
                    .iter()
                    .map(|n| (n.clone(), format!("/bios/files/{n}")))
                    .collect();
                self.begin_load(slot, "app:files", SessionCaps::files());
                (
                    HostNeed::Files {
                        slot,
                        index: "/bios/files".into(),
                        volumes: vols,
                    },
                    FrameNote {
                        text: format!("HOOK-FILES {slot} {loc}"),
                    },
                )
            }
            None => {
                self.repopulate_slot(slot);
                if let Some(s) = self.sessions[slot].as_mut() {
                    replace_history(s, loc.into());
                    s.load = SessionLoad::Error("app: hook not registered".into());
                    s.document = SessionDocument::Blank;
                    s.caps = SessionCaps::deny();
                }
                (
                    HostNeed::None,
                    FrameNote {
                        text: format!("FRAME-NAV {slot} error: app: hook not registered"),
                    },
                )
            }
        }
    }

    fn begin_load(&mut self, slot: usize, location: &str, caps: SessionCaps) {
        self.repopulate_slot(slot);
        if let Some(s) = self.sessions.get_mut(slot).and_then(|s| s.as_mut()) {
            replace_history(s, location.into());
            s.load = SessionLoad::Loading;
            s.document = SessionDocument::Blank;
            s.caps = caps;
        }
    }

    fn repopulate_slot(&mut self, slot: usize) {
        if let Some(s) = self.sessions.get_mut(slot).and_then(|s| s.as_mut()) {
            s.context.repopulate();
        }
    }

    fn apply_doc(
        &mut self,
        slot: usize,
        location: &str,
        load: SessionLoad,
        document: SessionDocument,
    ) {
        let caps = match &document {
            SessionDocument::Files(_) => SessionCaps::files(),
            _ => SessionCaps::deny(),
        };
        if let Some(s) = self.sessions.get_mut(slot).and_then(|s| s.as_mut()) {
            replace_history(s, location.into());
            s.load = load;
            s.document = document;
            s.caps = caps;
        }
    }
}

impl PageView {
    /// Title + visible text from a served markup string. No DOM crate.
    pub fn from_markup(html: &str) -> Self {
        let title = tag_inner(html, "title");
        let text = tag_inner(html, "body").unwrap_or_else(|| strip_tags(html));
        Self { title, text }
    }
}

fn tag_inner(html: &str, tag: &str) -> Option<String> {
    let lower = html.to_ascii_lowercase();
    let open = format!("<{tag}");
    let close = format!("</{tag}>");
    let start = lower.find(&open)?;
    let after = html[start..].find('>')? + start + 1;
    let end_rel = lower[after..].find(&close)?;
    let inner = html[after..after + end_rel].trim();
    let stripped = strip_tags(inner);
    if stripped.is_empty() {
        None
    } else {
        Some(stripped)
    }
}

fn strip_tags(s: &str) -> String {
    let mut out = String::new();
    let mut in_tag = false;
    for c in s.chars() {
        match c {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ if !in_tag => out.push(c),
            _ => {}
        }
    }
    out.trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{SessionCaps, SessionDocument, SessionLoad, SessionVar, SessionVars};

    #[test]
    fn ensure_drop_and_slot_budget() {
        let mut e = FrameEngine::new();
        assert_eq!(e.occupied(), 0);
        assert_eq!(e.ensure(0).text, "SESSION-ENSURE 0");
        assert_eq!(e.ensure(0).text, "SESSION-ENSURE 0");
        assert_eq!(e.session(0).unwrap().location, "about:blank");
        assert_eq!(
            e.ensure(MAX_SESSIONS).text,
            format!("SESSION-BUDGET {MAX_SESSIONS}")
        );
        assert!(e.session(1).is_none());
        assert_eq!(e.drop(0).text, "SESSION-DROP 0");
    }

    #[test]
    fn nested_grant_blocks_parent_bios_path() {
        let mut e = FrameEngine::new();
        e.ensure(0);
        let g = EmbedGrant::issue(
            "https://parent.example/",
            "https://child.example/",
            "n".repeat(16),
            1,
            100,
        )
        .unwrap();
        e.set_grant(g);
        let (_, note) = e.navigate(0, "/bios/flash");
        assert!(note.text.contains("bios"), "{}", note.text);
        let (_, note) = e.navigate(0, "https://parent.example/bios/login");
        assert!(note.text.contains("bios"), "{}", note.text);
        let (_, note) = e.navigate(0, "https://child.example/bios/login");
        assert!(
            !note.text.contains("parent /bios"),
            "child BIOS login is nested, {}",
            note.text
        );
        let (_, note) = e.navigate(0, "https://user:pass@h/");
        assert!(note.text.contains("credentials"), "{}", note.text);
    }

    #[test]
    fn navigate_blank_and_html_need() {
        let mut e = FrameEngine::new();
        let _ = e.ensure(0);
        let (need, _) = e.navigate(0, "/ui/help.html");
        assert_eq!(
            need,
            HostNeed::Html {
                slot: 0,
                path: "/ui/help.html".into(),
                gen: 2,
            }
        );
        let loading = e.session(0).unwrap();
        assert_eq!(loading.load, SessionLoad::Loading);
        assert_eq!(loading.location, "/ui/help.html");
        assert!(loading.caps.is_deny());
        let note = e.provide_html(
            0,
            "/ui/help.html",
            200,
            "<html><head><title>Help</title></head><body><p>G6LC-BIOS help</p></body></html>",
        );
        assert!(note.text.contains("200"));
        let s = e.session(0).unwrap();
        assert_eq!(s.document.title(), Some("Help"));
        assert!(s.document.paint_text().contains("G6LC-BIOS help"));
        assert!(s.caps.is_deny());
        let _ = e.ensure(0);
        assert_eq!(e.session(0).unwrap().document.title(), Some("Help"));
        let (need, _) = e.navigate(0, "/ui/help.html");
        let stale_gen = match need {
            HostNeed::Html { gen, .. } => gen,
            other => panic!("{other:?}"),
        };
        let _ = e.navigate(0, "/ui/other.html");
        let note = e.provide_html_gen(
            0,
            stale_gen,
            "/ui/help.html",
            200,
            "<html><body>stale</body></html>",
        );
        assert!(note.text.contains("stale generation"));
        assert!(!e
            .session(0)
            .unwrap()
            .document
            .paint_text()
            .contains("stale"));
    }

    #[test]
    fn files_hook_emits_fetch_need() {
        let mut e = FrameEngine::new();
        e.register_hook(AppHook::files());
        let _ = e.ensure(0);
        let (need, _) = e.navigate(0, "app:files");
        match need {
            HostNeed::Files { index, volumes, .. } => {
                assert_eq!(index, "/bios/files");
                assert!(volumes
                    .iter()
                    .any(|(n, p)| n == "fat32" && p == "/bios/files/fat32"));
            }
            other => panic!("{other:?}"),
        }
        let loading = e.session(0).unwrap();
        assert_eq!(loading.load, SessionLoad::Loading);
        assert_eq!(loading.caps, SessionCaps::files());
        let _ = e.provide_files(0, "{}".into(), vec![]);
        assert_eq!(e.session(0).unwrap().location, "app:files");
        assert_eq!(e.session(0).unwrap().caps, SessionCaps::files());
        let intern = e.content_window(0).unwrap();
        assert_ne!(intern.generation, 1);
        assert!(!crate::is_shell_context_id(
            &e.session(0).unwrap().context.id()
        ));
        let (need, note) = e.navigate(0, "app:ssh");
        assert_eq!(need, HostNeed::None);
        assert!(note.text.contains("not registered"));
        assert!(e.session(0).unwrap().caps.is_deny());
        assert_eq!(e.session(0).unwrap().document, SessionDocument::Blank);
        let _ = e.drop_all();
        assert!(e.content_window(0).is_none());
        assert!(e.content_document(0).is_none());
    }

    #[test]
    fn vars_survive_remote_fail() {
        let mut e = FrameEngine::new();
        let _ = e.ensure(0);
        let mut vars = SessionVars::new();
        assert!(vars.insert("greeting".into(), SessionVar::String("hello".into())));
        assert!(!vars.insert("eval".into(), SessionVar::String("nope".into())));
        assert!(e.set_vars(0, vars).text.contains("SESSION-VARS 0 1"));
        let (need, note) = e.navigate(0, "https://example/path");
        assert_eq!(need, HostNeed::None);
        assert!(note.text.contains("outbound"));
        let s = e.session(0).unwrap();
        assert_eq!(
            s.vars.get("greeting"),
            Some(&SessionVar::String("hello".into()))
        );
        assert!(s.load.status_word().contains("outbound"));
    }

    #[test]
    fn outbound_waiters_retry_after_arm() {
        let mut e = FrameEngine::new();
        let _ = e.ensure(0);
        let (need, note) = e.navigate(0, "https://example/path");
        assert_eq!(need, HostNeed::None);
        assert!(note.text.contains("outbound"));
        assert_eq!(
            e.outbound_waiters(),
            vec![(0, "https://example/path".into())]
        );
        e.set_outbound(true);
        let waiters = e.outbound_waiters();
        assert_eq!(waiters.len(), 1);
        let (need, _) = e.navigate(waiters[0].0, &waiters[0].1);
        assert_eq!(
            need,
            HostNeed::RemoteHtml {
                slot: 0,
                url: "https://example/path".into(),
                gen: 3,
            }
        );
    }

    #[test]
    fn outbound_remote_emits_fetch_need() {
        let mut e = FrameEngine::new();
        e.set_outbound(true);
        let _ = e.ensure(0);
        let (need, note) = e.navigate(0, "https://example/path");
        assert!(note.text.contains("outbound"));
        assert_eq!(
            need,
            HostNeed::RemoteHtml {
                slot: 0,
                url: "https://example/path".into(),
                gen: 2,
            }
        );
        assert_eq!(e.session(0).unwrap().load, SessionLoad::Loading);
        assert!(e.session(0).unwrap().caps.is_deny());
        let _ = e.provide_html(
            0,
            "https://example/path",
            200,
            "<html><head><title>Ex</title></head><body><p>remote</p></body></html>",
        );
        let s = e.session(0).unwrap();
        assert_eq!(s.document.title(), Some("Ex"));
        assert!(s.caps.is_deny());
        let (need, note) = e.navigate(0, "https://example/app.wasm");
        assert_eq!(need, HostNeed::None);
        assert!(note.text.contains("remote wasm"));
    }
}
