// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! `g6b-zealcli` — the minimally dependent BIOS face.
//!
//! A ZealOS-shaped shell in a fixed text container: output scrolls above, the
//! command prompt is the **bottom row**, and everything an operator needs to
//! adjust settings, browse a USB key, read a file and update firmware is
//! reachable with a keyboard alone. Bash spellings and the ZealOS names are the
//! same commands (`ls`/`Dir`, `cat`/`Type`), and any registered HolyC builtin can
//! be called from the prompt.
//!
//! **Dependencies are the point.** This crate takes `g6b-spec` and `g6b-holyc`
//! and nothing else — not `g6b-hw`, not the web stack. Adapters reach it as the
//! poll-shaped [`ports`] the kernel lends, so a build with the whole web engine
//! compiled still boots *this* prompt first (`kernel.cli.boot=auto`) and only
//! hands the screen to browser-ui when `LoadUI` runs after a GPU is announced.
//! A build without the engine (`profile=barebone`) is complete on its own.
//!
//! Modules: [`screen`] the container, [`input`] USB/virtio keycodes and the line
//! editor, [`cmd`] the command table, [`settings`] the writable-row overlay,
//! [`fsview`] drive exploration, [`vi`] the read-only viewer, [`fw`] the
//! poll-driven firmware update, [`boot`] the edk2/u-boot selector, [`man`] the
//! generated manual.

#![allow(missing_docs)]

use std::collections::BTreeMap;
use std::fmt;

use g6b_holyc::{is_holyc_builtin, Program, ReplResult};
use g6b_spec::BoardSpec;

pub mod autoboot;
pub mod boot;
pub mod cmd;
pub mod detect;
pub mod fsview;
pub mod fw;
pub mod input;
pub mod man;
pub mod mounts;
pub mod ports;
pub mod screen;
pub mod settings;
pub mod vi;

pub use autoboot::{AutoBoot, Entry as BootEntry, Pick, Target as BootTargetKind};
pub use cmd::{help_text, Command};
pub use detect::{Found, Medium};
pub use fsview::Location;
pub use fw::{Phase, Source, Update};
pub use input::{Edit, Key, Mouse};
pub use ports::{Entry, FlashPort, NetPort, Ports, Progress, VolumeInfo, VolumePort};
pub use screen::Screen;
pub use settings::Overlay;
pub use vi::{Vi, ViAction};

/// ZealOS `CmdLinePrompt` prints `>` after the cwd.
pub const PROMPT: &str = ">";
/// Largest file the editor opens in full.
///
/// A BIOS has no swap and a fixed heap; a 4 GiB file must not become a 4 GiB
/// buffer. Beyond this the first window is shown **read-only**, because saving a
/// prefix would truncate the file to it.
pub const VI_MAX_BYTES: u64 = 256 * 1024;
/// VGA text geometry, the default container size.
pub const VGA_COLS: usize = 80;
pub const VGA_ROWS: usize = 25;

/// What the kernel should do after one line.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    Continue,
    Exit,
    LoadUi,
    Reboot,
    Shutdown,
    Wakeup,
    LinuxHandoff,
    /// The autoboot picker took an entry: [`Session::picked`] names it, and the
    /// next-stage choice is already in the settings overlay.
    Boot,
}

/// Where keys currently go.
#[derive(Debug)]
enum Mode {
    Shell,
    Viewer(Vi),
    Picker(AutoBoot),
}

/// One CLI session.
pub struct Session {
    spec: BoardSpec,
    screen: Screen,
    editor: input::Editor,
    cwd: Location,
    files: BTreeMap<String, String>,
    program: Program,
    ports: Ports,
    overlay: Overlay,
    update: Option<Update>,
    mode: Mode,
    shift: bool,
    /// Ctrl held. Ctrl+C / Ctrl+V use [`Self::clipboard`], not the host OS.
    ctrl: bool,
    /// Session clipboard. Never the host clipboard.
    clipboard: String,
    /// The entry the picker took, kept for the kernel after `Action::Boot`.
    picked: Option<BootEntry>,
    /// The path the open viewer came from, so `:w` knows where to save.
    viewer_path: Option<String>,
}

impl fmt::Debug for Session {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Session")
            .field("cwd", &self.cwd.display())
            .field("rows", &self.screen.rows())
            .field("cols", &self.screen.cols())
            .field("ports", &self.ports)
            .field("pending_settings", &self.overlay.len())
            .field("update", &self.update.as_ref().map(|u| u.phase()))
            .finish()
    }
}

impl Session {
    /// A session with no adapters: the CLI still runs, and every capability
    /// that needs a device says so.
    pub fn new(spec: &BoardSpec) -> Self {
        Self::with_ports(spec, Ports::default())
    }

    /// A session with the ports the kernel lends (volumes, net, flash).
    pub fn with_ports(spec: &BoardSpec, ports: Ports) -> Self {
        let cli = &spec.kernel.cli;
        let mut files = BTreeMap::new();
        files.insert("/config".into(), "{}".into());
        files.insert("/keys".into(), String::new());
        files.insert(
            "/boot-policy".into(),
            format!("next={}\n", spec.kernel.params.next),
        );
        let mut s = Self {
            screen: Screen::new(
                cli.cols as usize,
                cli.rows as usize,
                cli.scrollback as usize,
            ),
            editor: input::Editor::default(),
            cwd: Location::Bios("/".into()),
            files,
            program: Program::default(),
            ports,
            overlay: Overlay::default(),
            update: None,
            mode: Mode::Shell,
            shift: false,
            ctrl: false,
            clipboard: String::new(),
            picked: None,
            viewer_path: None,
            spec: spec.clone(),
        };
        s.banner();
        s
    }

    fn banner(&mut self) {
        let cli = &self.spec.kernel.cli;
        // ASCII only: this banner is also `.rodata` in the guest ELF and is
        // blitted by an 8x8 glyph face that has no em dash.
        self.screen.push(&format!(
            "G6LC-BIOS zealcli - {} {}x{}{}",
            self.spec.product,
            cli.cols,
            cli.rows,
            if cli.mouse { " (mouse)" } else { " (keyboard)" }
        ));
        let hint = if self.spec.web_stack() {
            "Type help. web stack compiled: LoadUI hands over after the GPU probe."
        } else {
            "Type help. barebone build: no wasm/js/dom/css compiled."
        };
        self.screen.push(hint);
        if self.spec.kernel.cli.manual {
            self.screen.push("`man` prints the manual for this board.");
        }
    }

    pub fn spec(&self) -> &BoardSpec {
        &self.spec
    }

    pub fn ports_mut(&mut self) -> &mut Ports {
        &mut self.ports
    }

    /// `cwd>` — ZealOS prompt, with the pending-write and transfer state the
    /// operator needs to see before typing the next command.
    pub fn prompt(&self) -> String {
        let mut p = self.cwd.display();
        if !self.overlay.is_empty() {
            p.push_str(&format!(" [{}*]", self.overlay.len()));
        }
        if let Some(u) = &self.update {
            if !matches!(u.phase(), Phase::Applied | Phase::Cancelled) {
                p.push_str(&format!(" [fw {}]", u.phase().as_str()));
            }
        }
        p.push_str(PROMPT);
        p
    }

    pub fn cwd(&self) -> String {
        self.cwd.display()
    }

    /// The visible frame: `rows` lines, prompt (or viewer status) last.
    pub fn render(&self) -> Vec<String> {
        match &self.mode {
            Mode::Viewer(v) => v.render(),
            Mode::Picker(p) => p.render(self.screen.cols(), self.screen.rows()),
            Mode::Shell => {
                let line = format!("{}{}", self.prompt(), self.editor.line());
                self.screen.render(&line)
            }
        }
    }

    /// The capability ports this session was wired with.
    pub fn ports(&self) -> &Ports {
        &self.ports
    }

    /// Pending setup writes, same document the page and the console share.
    pub fn pending_json(&self) -> String {
        self.overlay.pending_json(&self.spec)
    }

    /// Install a saved patch into this session and remember it as `/settings.json`.
    pub fn import_settings_patch(&mut self, patch: &str) -> Result<usize, String> {
        let n = self.overlay.load_patch(&self.spec, patch)?;
        self.files
            .insert("/settings.json".into(), patch.to_string());
        Ok(n)
    }

    /// The autoboot picker, while it owns the screen.
    pub fn picker(&self) -> Option<&AutoBoot> {
        match &self.mode {
            Mode::Picker(p) => Some(p),
            _ => None,
        }
    }

    /// The entry the picker took (valid after [`Action::Boot`]).
    pub fn picked(&self) -> Option<&BootEntry> {
        self.picked.as_ref()
    }

    /// The frame as one text block — the VGA text face.
    pub fn vga_text(&self) -> String {
        self.render().join("\n")
    }

    pub fn screen(&self) -> &Screen {
        &self.screen
    }

    pub fn in_viewer(&self) -> bool {
        matches!(self.mode, Mode::Viewer(_))
    }

    pub fn pending_settings(&self) -> &Overlay {
        &self.overlay
    }

    pub fn update(&self) -> Option<&Update> {
        self.update.as_ref()
    }

    /// One raw Linux keycode (USB HID or virtio-input). `pressed=false` is
    /// tracked only for the shift modifier.
    pub fn keycode(&mut self, code: u16, pressed: bool) -> Action {
        if input::is_shift_keycode(code) {
            self.shift = pressed;
            return Action::Continue;
        }
        if input::is_ctrl_keycode(code) {
            self.ctrl = pressed;
            return Action::Continue;
        }
        if !pressed {
            return Action::Continue;
        }
        match input::from_linux_keycode(code, self.shift, self.ctrl) {
            Some(k) => self.key(k),
            None => Action::Continue,
        }
    }

    /// One decoded key.
    pub fn key(&mut self, k: Key) -> Action {
        if k == Key::Copy {
            self.clipboard = match &self.mode {
                Mode::Viewer(v) => v.copy_line(),
                _ => self.editor.line().to_string(),
            };
            return Action::Continue;
        }
        if k == Key::Paste {
            let clip = self.clipboard.clone();
            if let Mode::Viewer(v) = &mut self.mode {
                if !v.paste_text(&clip) {
                    v.note("E45: 'readonly' — paste refused");
                }
            } else {
                self.editor.insert_text(&clip);
            }
            return Action::Continue;
        }
        if let Mode::Viewer(v) = &mut self.mode {
            match v.key(k) {
                ViAction::Stay => {}
                ViAction::Quit => {
                    self.mode = Mode::Shell;
                    self.viewer_path = None;
                }
                ViAction::Write { text, quit } => {
                    // The save happens here, in the session that owns the ports —
                    // the editor never touches a device itself.
                    let msg = match self.viewer_save(&text) {
                        Ok(m) => m,
                        Err(e) => format!("vi: {e}"),
                    };
                    self.screen.push(&msg);
                    if quit {
                        self.mode = Mode::Shell;
                        self.viewer_path = None;
                    } else if let Mode::Viewer(v) = &mut self.mode {
                        v.note(&msg);
                    }
                }
            }
            return Action::Continue;
        }
        if let Mode::Picker(p) = &mut self.mode {
            let pick = p.key(k);
            return self.settle_pick(pick);
        }
        match self.editor.key(k) {
            Edit::Submit(line) => self.eval(&line).0,
            Edit::Page(p) => {
                self.screen.page(p);
                Action::Continue
            }
            Edit::Scroll(d) => {
                self.screen.scroll(d);
                Action::Continue
            }
            Edit::Changed | Edit::Ignored => Action::Continue,
        }
    }

    /// A pointer event. Refused unless `kernel.cli.mouse` was compiled — the
    /// CLI never depends on a pointer being there.
    pub fn mouse(&mut self, m: Mouse) -> Action {
        if !self.spec.kernel.cli.mouse {
            return Action::Continue;
        }
        match m {
            Mouse::Wheel(n) => self.screen.scroll(-n),
            Mouse::Press { row, .. } => {
                // A click on the prompt row re-attaches to live output; a click
                // in the scrollback freezes the viewport where it is.
                if usize::from(row) + 1 >= self.screen.rows() {
                    self.screen.to_tail();
                }
            }
        }
        Action::Continue
    }

    /// Advance the autoboot countdown by `ms` — the shell loop and the guest
    /// timer tick both call this, so the clock is the caller's, not a thread's.
    pub fn tick_ms(&mut self, ms: u32) -> Action {
        let Mode::Picker(p) = &mut self.mode else {
            return Action::Continue;
        };
        let pick = p.tick(ms);
        self.settle_pick(pick)
    }

    /// Turn a picker decision into a kernel action, writing the next-stage
    /// choice into the settings overlay the way `boot <id>` does.
    fn settle_pick(&mut self, pick: Pick) -> Action {
        match pick {
            Pick::Waiting => Action::Continue,
            Pick::Cancelled => {
                self.mode = Mode::Shell;
                self.screen.push("AUTOBOOT-CANCEL (staying in setup)");
                Action::Continue
            }
            Pick::Taken(e) => {
                self.mode = Mode::Shell;
                self.screen.push(&format!(
                    "AUTOBOOT-PICK {} stage={} {} <- {}",
                    e.id, e.stage, e.name, e.evidence
                ));
                if e.stage != "linux" {
                    if let Ok(msg) = self.overlay.set(&self.spec, "boot.next", &e.stage) {
                        self.screen.push(&msg);
                    }
                }
                if !e.volume.is_empty() {
                    if let Ok(msg) = self.overlay.set(&self.spec, "boot.volume", "usb") {
                        self.screen.push(&msg);
                    }
                }
                let action = match e.target {
                    BootTargetKind::BiosUi => Action::LoadUi,
                    BootTargetKind::Payload => Action::Continue,
                    BootTargetKind::Volume => Action::Boot,
                };
                self.picked = Some(e);
                action
            }
        }
    }

    /// Advance background work one bounded step. Called from the shell loop and
    /// from the guest timer tick; never blocks, never spawns.
    pub fn tick(&mut self) {
        let Some(mut up) = self.update.take() else {
            return;
        };
        let before = up.phase();
        let after = up.poll(&mut self.ports);
        if after != before {
            let line = up.status();
            self.screen.push(&line);
        }
        self.update = Some(up);
    }

    /// Run one command line. Kept as the stable entry point for the kernel and
    /// the UART band.
    pub fn eval(&mut self, line: &str) -> (Action, String) {
        let line = line.trim();
        if line.is_empty() {
            return (Action::Continue, String::new());
        }
        self.screen.push(&format!("{}{line}", self.prompt()));
        let (action, out) = self.dispatch(line);
        if !out.is_empty() {
            self.screen.push(out.trim_end_matches('\n'));
        }
        (action, out)
    }

    fn dispatch(&mut self, line: &str) -> (Action, String) {
        // A HolyC setup builtin that this shell really implements is *run*, not
        // reported: `FwUpdate("https://…")` drives the same state machine as
        // `fw update https://…`. Names without an implementation here stay on
        // the interpreter's own path.
        if let Some(cmd) = holyc_shell_command(line) {
            return self.dispatch(&cmd);
        }
        let (word, rest) = split_cmd(line);
        let Some(c) = Command::find(word) else {
            if looks_like_holyc(word) {
                return self.holyc(line);
            }
            return (
                Action::Continue,
                format!("unknown command `{word}`; try help\n"),
            );
        };
        if !c.gate.compiled(&self.spec) {
            return (
                Action::Continue,
                format!(
                    "`{}` is not in this build ({} is off)\n",
                    c.name,
                    c.gate.because()
                ),
            );
        }
        let out = match c.name {
            "help" => return (Action::Continue, self.help(rest)),
            "man" => man::manual(&self.spec, self.screen.cols(), rest),
            "clear" => {
                self.screen.clear();
                String::new()
            }
            "scroll" => self.scroll(rest),
            "pwd" => format!("{}\n", self.cwd.display()),
            "ls" => self.list(rest),
            "cd" => self.cd(rest),
            "cat" => self.cat(rest),
            "vi" => return (Action::Continue, self.open_viewer(rest)),
            "write" => self.write_file(rest),
            "rm" => self.rm(rest),
            "cp" => self.copy(rest, false),
            "mv" => self.copy(rest, true),
            "mkdir" => self.mkdir(rest),
            "echo" => format!("{rest}\n"),
            "drv" => {
                // Both worlds: the BoardSpec-modelled volumes and the real
                // drives/partitions a block reader found.
                let modelled = fsview::drives_text(&self.ports);
                let real = crate::mounts::drives_table(&mut self.ports);
                if real.contains("no block reader") {
                    modelled
                } else {
                    format!("{modelled}{real}")
                }
            }
            "mount" => crate::mounts::mount_cmd(&mut self.ports, rest),
            "umount" => crate::mounts::umount_cmd(&mut self.ports, rest),
            "menu" => self.menu(rest),
            "set" => self.set(rest),
            "get" => self.get(rest),
            "save" => self.save(rest),
            "load" => self.load(rest),
            "boot" => self.boot(rest),
            "autoboot" => return self.autoboot(rest),
            "fw" => self.fw(rest),
            "net" => self.net(),
            "loadui" => return self.load_ui(),
            "holyc" => return self.holyc(rest),
            "reboot" => return (Action::Reboot, "REBOOT\n".into()),
            "shutdown" => return (Action::Shutdown, "SHUTDOWN\n".into()),
            "wakeup" => return (Action::Wakeup, "WAKEUP\n".into()),
            "linux" => return (Action::LinuxHandoff, "LINUX-HANDOFF\n".into()),
            "exit" => return (Action::Exit, String::new()),
            other => format!("`{other}` has no handler\n"),
        };
        (Action::Continue, out)
    }

    fn help(&self, topic: &str) -> String {
        if topic.is_empty() {
            return help_text(&self.spec);
        }
        match Command::find(topic) {
            Some(c) if c.gate.compiled(&self.spec) => {
                format!("{}\n    {}\n", c.usage, c.help)
            }
            Some(c) => format!(
                "{} is not in this build ({} is off)\n",
                c.name,
                c.gate.because()
            ),
            None => format!("no command `{topic}`\n"),
        }
    }

    fn scroll(&mut self, arg: &str) -> String {
        match arg.trim() {
            "up" | "u" | "" => self.screen.page(-1),
            "down" | "d" => self.screen.page(1),
            "top" | "home" => self.screen.to_top(),
            "tail" | "end" | "live" => self.screen.to_tail(),
            other => return format!("scroll: up|down|top|tail (not `{other}`)\n"),
        }
        String::new()
    }

    // ---- files: the BIOS-local tree and the volumes ----

    fn list(&mut self, arg: &str) -> String {
        let loc = self.locate(arg);
        if let Location::Mount { name, path } = &loc {
            let (name, path) = (name.clone(), path.clone());
            let note = match self.touch_mount(&name) {
                Ok(n) => n.map(|n| format!("{n}\n")).unwrap_or_default(),
                Err(e) => return format!("ls: {e}\n"),
            };
            let mp = self.ports.mounts.as_mut().expect("checked above");
            return match mp.list(&name, &path) {
                Ok(ents) => format!("{note}{}", crate::mounts::list_rows(&ents)),
                Err(e) => format!("ls: {e}\n"),
            };
        }
        match &loc {
            Location::Volume { .. } => match fsview::list_text(&self.ports, &loc) {
                Ok(s) => s,
                Err(e) => format!("{e}\n"),
            },
            Location::Mount { .. } => unreachable!("handled above"),
            Location::Bios(dir) => {
                let mut names: Vec<&str> = self
                    .files
                    .keys()
                    .filter(|p| fsview::parent_of(p) == *dir)
                    .map(|p| p.rsplit('/').next().unwrap_or(p.as_str()))
                    .collect();
                names.sort_unstable();
                if names.is_empty() {
                    return format!("({dir} is empty)\n");
                }
                let mut s = String::new();
                for n in names {
                    s.push_str(n);
                    s.push('\n');
                }
                s
            }
        }
    }

    /// Resolve a path argument, understanding real mounts as well as modelled
    /// volumes and the BIOS-local tree.
    fn locate(&mut self, arg: &str) -> Location {
        // Which names are real mounts has to be known *before* the path is
        // resolved, because `root:/etc` is a mount and `KEY-FAT:/x` is not.
        let names: Vec<String> = match self.ports.mounts.as_mut() {
            Some(mp) => {
                let mut n: Vec<String> = mp.mounts().into_iter().map(|m| m.name).collect();
                // A known-but-unmounted volume is also a mount name: `cd root:/etc`
                // should mount it, not fail.
                for d in mp.drives() {
                    for v in mp.volumes(&d.id).unwrap_or_default() {
                        if v.mountable && !n.contains(&v.name) {
                            n.push(v.name);
                        }
                    }
                }
                n
            }
            None => Vec::new(),
        };
        Location::resolve_with(&self.cwd, arg, &|name| names.iter().any(|n| n == name))
    }

    /// Make sure a mount is live before walking it, mounting read-only if needed.
    fn touch_mount(&mut self, name: &str) -> Result<Option<String>, String> {
        crate::mounts::ensure_mounted(&mut self.ports, name).map(|(_, note)| note)
    }

    fn cd(&mut self, arg: &str) -> String {
        if arg.is_empty() || arg == "~" {
            self.cwd = Location::Bios("/".into());
            return String::new();
        }
        if arg == ".." {
            self.cwd = self.cwd.parent();
            return String::new();
        }
        let loc = self.locate(arg);
        if let Location::Mount { name, path } = &loc {
            let (name, path) = (name.clone(), path.clone());
            let note = match self.touch_mount(&name) {
                Ok(n) => n,
                Err(e) => return format!("cd: {e}\n"),
            };
            let mp = self.ports.mounts.as_mut().expect("checked above");
            return match mp.list(&name, &path) {
                Ok(_) => {
                    self.cwd = loc;
                    note.map(|n| format!("{n}\n")).unwrap_or_default()
                }
                Err(e) => format!("cd: {e}\n"),
            };
        }
        match &loc {
            Location::Volume { .. } => match fsview::list_text(&self.ports, &loc) {
                Ok(_) => {
                    self.cwd = loc;
                    String::new()
                }
                Err(e) => format!("{e}\n"),
            },
            Location::Bios(p) => {
                let known = p == "/"
                    || p == crate::mounts::MNT
                    || self
                        .files
                        .keys()
                        .any(|f| fsview::parent_of(f) == *p || f == p);
                if known {
                    self.cwd = loc;
                    String::new()
                } else {
                    format!("Cd: no such directory {arg}\n")
                }
            }
            Location::Mount { .. } => unreachable!("handled above"),
        }
    }

    /// File body for `cat` / the viewer, from wherever the path points.
    fn read(&mut self, arg: &str) -> Result<(String, String), String> {
        if arg.is_empty() {
            return Err("expected a file name".into());
        }
        let loc = self.locate(arg);
        match &loc {
            Location::Mount { name, path } => {
                let (name, path) = (name.clone(), path.clone());
                self.touch_mount(&name)?;
                let mp = self.ports.mounts.as_mut().expect("checked above");
                let bytes = mp.read(&name, &path)?;
                // A repair shell shows text. Binary is named, not spilled onto a
                // VGA container as control characters.
                match String::from_utf8(bytes) {
                    Ok(s)
                        if !s
                            .chars()
                            .any(|c| c.is_control() && !matches!(c, '\n' | '\r' | '\t')) =>
                    {
                        Ok((loc.display(), s))
                    }
                    Ok(s) => Err(format!("{}: binary ({} bytes)", loc.display(), s.len())),
                    Err(e) => Err(format!(
                        "{}: binary ({} bytes)",
                        loc.display(),
                        e.into_bytes().len()
                    )),
                }
            }
            Location::Volume { .. } => {
                fsview::read_text(&self.ports, &loc).map(|b| (loc.display(), b))
            }
            Location::Bios(p) => self
                .files
                .get(p)
                .cloned()
                .map(|b| (p.clone(), b))
                .ok_or_else(|| format!("no such file {arg}")),
        }
    }

    fn cat(&mut self, arg: &str) -> String {
        match self.read(arg) {
            Ok((_, body)) if body.ends_with('\n') || body.is_empty() => body,
            Ok((_, body)) => format!("{body}\n"),
            Err(e) => format!("Type: {e}\n"),
        }
    }

    fn open_viewer(&mut self, arg: &str) -> String {
        let loc = self.locate(arg);
        // On a writable mount this is an editor: same motions, plus `i`/`o`/`dd`
        // and `:w`. Everywhere else it stays the read-only viewer and says why.
        let editable = match &loc {
            Location::Mount { name, .. } => {
                let name = name.clone();
                match self.touch_mount(&name) {
                    Ok(_) => match self.ports.mounts.as_mut() {
                        Some(mp) => mp.mounts().into_iter().find(|m| m.name == name).map(|m| {
                            (m.rw, m.why_ro.unwrap_or_else(|| "mounted read-only".into()))
                        }),
                        None => None,
                    },
                    Err(e) => return format!("vi: {e}\n"),
                }
            }
            _ => None,
        };
        // The filesystem's own terms for this path, and how much of the file the
        // editor is willing to hold.
        let terms = match &loc {
            Location::Mount { name, path } => {
                let (name, path) = (name.clone(), path.clone());
                self.ports
                    .mounts
                    .as_mut()
                    .and_then(|mp| mp.edit_budget(&name, &path).ok())
            }
            _ => None,
        };
        let big = terms.as_ref().map(|t| t.size).unwrap_or(0);
        match self.read(arg) {
            Ok((name, body)) => {
                let (cols, rows) = (self.screen.cols(), self.screen.rows());
                let mut vi = match editable {
                    Some((true, _)) => Vi::open_rw(&name, &body, cols, rows),
                    Some((false, why)) => Vi::open_ro(&name, &body, cols, rows, &why),
                    None => Vi::open(&name, &body, cols, rows),
                };
                if let Some(t) = &terms {
                    vi = vi.with_terms(&t.summary, t.max_bytes);
                }
                // A file larger than the editor's window is opened read-only: a
                // save would truncate it to whatever fit.
                if big > VI_MAX_BYTES && body.len() as u64 >= VI_MAX_BYTES {
                    vi = vi.partial(big, body.len() as u64);
                }
                self.viewer_path = Some(arg.to_string());
                self.mode = Mode::Viewer(vi);
                String::new()
            }
            Err(e) => format!("vi: {e}\n"),
        }
    }

    /// Save the buffer the viewer is holding, back where it came from.
    fn viewer_save(&mut self, text: &str) -> Result<String, String> {
        let arg = self
            .viewer_path
            .clone()
            .ok_or("vi: this buffer has no file behind it")?;
        let loc = self.locate(&arg);
        match loc {
            Location::Mount { name, path } => {
                let mp = self
                    .ports
                    .mounts
                    .as_mut()
                    .ok_or("no block reader in this build")?;
                // Terms first: refuse before writing, not halfway through.
                let terms = mp.edit_budget(&name, &path)?;
                terms.accepts(text.len() as u64)?;
                mp.write(&name, &path, text.as_bytes())?;
                // Then **read it back**. A BIOS write is the last thing to touch a
                // volume before an operator reboots into it, so "the driver
                // returned Ok" is not enough evidence: the bytes have to be there.
                let back = mp.read(&name, &path)?;
                if back != text.as_bytes() {
                    return Err(format!(
                        "/mnt/{name}{path}: wrote {} bytes but read back {} — the volume does not \
                         hold what was saved",
                        text.len(),
                        back.len()
                    ));
                }
                Ok(format!(
                    "\"/mnt/{name}{path}\" {}L, {}B written and verified",
                    text.lines().count(),
                    text.len()
                ))
            }
            Location::Bios(p) => {
                if self.immutable(&p) {
                    return Err(format!("{p} is immutable after handoff"));
                }
                self.files.insert(p.clone(), text.to_string());
                Ok(format!("\"{p}\" {}B written", text.len()))
            }
            Location::Volume { volume, path } => Err(format!(
                "{volume}:{path} is a modelled volume — mount a real one to write"
            )),
        }
    }

    fn write_file(&mut self, rest: &str) -> String {
        let (name, body) = match rest.split_once(' ') {
            Some((n, b)) => (n, b),
            None => return "write: file text\n".into(),
        };
        let loc = self.locate(name);
        // A real mount is the one place `write` can actually change a disk.
        if let Location::Mount { name, path } = &loc {
            let (mount, path, body) = (name.clone(), path.clone(), body.to_string());
            if let Err(e) = self.touch_mount(&mount) {
                return format!("write: {e}\n");
            }
            let mp = self.ports.mounts.as_mut().expect("checked above");
            return match mp.write(&mount, &path, body.as_bytes()) {
                Ok(()) => format!("WRITE-OK {} bytes -> /mnt/{mount}{path}\n", body.len()),
                Err(e) => format!("write: {e}\n"),
            };
        }
        match loc {
            Location::Volume { volume, path } => format!(
                "write: {volume}:{path} is read-only from setup (use `fw update` for images)\n"
            ),
            Location::Mount { .. } => unreachable!("handled above"),
            Location::Bios(p) => {
                if self.immutable(&p) {
                    return format!("write: {p} is immutable after handoff\n");
                }
                self.files.insert(p, body.replace("\\n", "\n"));
                "WRITE-OK\n".into()
            }
        }
    }

    fn immutable(&self, path: &str) -> bool {
        let name = path.trim_start_matches('/');
        self.spec.postboot.immutable.iter().any(|i| i == name)
            && self.spec.postboot.enable != g6b_spec::PostbootMode::Never
    }

    fn rm(&mut self, arg: &str) -> String {
        if arg.is_empty() {
            return "rm: file\n".into();
        }
        let loc = self.locate(arg);
        if let Location::Mount { name, path } = &loc {
            let (mount, path) = (name.clone(), path.clone());
            if let Err(e) = self.touch_mount(&mount) {
                return format!("rm: {e}\n");
            }
            let mp = self.ports.mounts.as_mut().expect("checked above");
            return match mp.remove(&mount, &path) {
                Ok(()) => format!("RM-OK /mnt/{mount}{path}\n"),
                Err(e) => format!("rm: {e}\n"),
            };
        }
        match loc {
            Location::Volume { volume, path } => {
                format!("rm: {volume}:{path} is read-only from setup\n")
            }
            Location::Mount { .. } => unreachable!("handled above"),
            Location::Bios(p) => {
                if self.immutable(&p) {
                    return format!("rm: {p} is immutable\n");
                }
                if self.files.remove(&p).is_some() {
                    "DEL-OK\n".into()
                } else {
                    format!("rm: no such file {arg}\n")
                }
            }
        }
    }

    fn copy(&mut self, rest: &str, remove: bool) -> String {
        let mut it = rest.split_whitespace();
        let (Some(src), Some(dst)) = (it.next(), it.next()) else {
            return "expected src dst\n".into();
        };
        let body = match self.read(src) {
            Ok((_, b)) => b,
            Err(e) => return format!("{e}\n"),
        };
        let loc = self.locate(dst);
        if let Location::Mount { name, path } = &loc {
            let (mount, path) = (name.clone(), path.clone());
            if let Err(e) = self.touch_mount(&mount) {
                return format!("cp: {e}\n");
            }
            let mp = self.ports.mounts.as_mut().expect("checked above");
            return match mp.write(&mount, &path, body.as_bytes()) {
                Ok(()) => format!("COPY-OK {} bytes -> /mnt/{mount}{path}\n", body.len()),
                Err(e) => format!("cp: {e}\n"),
            };
        }
        match loc {
            Location::Volume { volume, path } => {
                format!("{volume}:{path} is read-only from setup\n")
            }
            Location::Mount { .. } => unreachable!("handled above"),
            Location::Bios(p) => {
                self.files.insert(p, body);
                if remove {
                    if let Location::Bios(s) = Location::resolve(&self.cwd, src) {
                        self.files.remove(&s);
                    }
                    "MOVE-OK\n".into()
                } else {
                    "COPY-OK\n".into()
                }
            }
        }
    }

    fn mkdir(&mut self, arg: &str) -> String {
        if arg.is_empty() {
            return "mkdir: name\n".into();
        }
        let loc = self.locate(arg);
        if let Location::Mount { name, path } = &loc {
            let (mount, path) = (name.clone(), path.clone());
            if let Err(e) = self.touch_mount(&mount) {
                return format!("mkdir: {e}\n");
            }
            let mp = self.ports.mounts.as_mut().expect("checked above");
            return match mp.mkdir(&mount, &path) {
                Ok(()) => format!("DIRMK-OK /mnt/{mount}{path}\n"),
                Err(e) => format!("mkdir: {e}\n"),
            };
        }
        match loc {
            Location::Volume { volume, .. } => format!("mkdir: {volume}: is read-only\n"),
            Location::Mount { .. } => unreachable!("handled above"),
            Location::Bios(p) => {
                self.files.entry(format!("{p}/.keep")).or_default();
                "DIRMK-OK\n".into()
            }
        }
    }

    // ---- settings, boot, firmware, net ----

    fn menu(&self, arg: &str) -> String {
        if arg.is_empty() {
            let mut s = String::from("setup screens:\n");
            for m in self.spec.menus() {
                s.push_str(&format!("  {:<10} {}\n", m.id, m.title));
            }
            return s;
        }
        match self.spec.menu(arg.trim()) {
            Some(m) => {
                let mut s = format!("{} ({})\n", m.title, m.id);
                for i in m.items {
                    s.push_str(&format!(
                        "  {}{:<22} {}\n",
                        if i.writable { "*" } else { " " },
                        i.label,
                        i.value
                    ));
                }
                s.push_str("  (* writable: set <row> <value>)\n");
                s
            }
            None => format!("menu: no screen `{arg}`\n"),
        }
    }

    fn set(&mut self, rest: &str) -> String {
        if rest.trim().is_empty() {
            return settings::writable_table(&self.spec);
        }
        let (key, value) = match rest.split_once(char::is_whitespace) {
            Some((k, v)) => (k, v.trim()),
            None => return format!("set: {} <value>\n", rest.trim()),
        };
        match self.overlay.set(&self.spec, key, value) {
            Ok(msg) => {
                // Container geometry is the one setting that also applies now:
                // the operator has to see what they chose.
                if key.ends_with("cli_rows") || key.ends_with("cli_cols") {
                    let rows = self
                        .overlay
                        .get("settings.cli_rows")
                        .and_then(|v| v.parse().ok())
                        .unwrap_or(self.screen.rows());
                    let cols = self
                        .overlay
                        .get("settings.cli_cols")
                        .and_then(|v| v.parse().ok())
                        .unwrap_or(self.screen.cols());
                    self.screen.resize(cols, rows);
                }
                format!("{msg}\n")
            }
            Err(e) => format!("{e}\n"),
        }
    }

    fn get(&self, key: &str) -> String {
        if key.trim().is_empty() {
            return "get: name\n".into();
        }
        match self.overlay.effective(&self.spec, key) {
            Ok(v) => format!("{v}\n"),
            Err(e) => format!("{e}\n"),
        }
    }

    fn save(&mut self, via: &str) -> String {
        if !self.spec.kernel.settings.export {
            return "save: kernel.settings.export is off\n".into();
        }
        let via = if via.trim().is_empty() {
            "uart"
        } else {
            via.trim()
        };
        if !self.settings_via(via) {
            return format!("save: `{via}` is not a compiled transport\n");
        }
        let patch = self.overlay.patch_json(&self.spec);
        self.files.insert("/settings.json".into(), patch.clone());
        format!(
            "SETTINGS-EXPORT via={via} rows={}\n{}{patch}\n",
            self.overlay.len(),
            self.overlay.summary(&self.spec)
        )
    }

    fn load(&mut self, via: &str) -> String {
        if !self.spec.kernel.settings.import {
            return "load: kernel.settings.import is off\n".into();
        }
        let via = if via.trim().is_empty() {
            "uart"
        } else {
            via.trim()
        };
        if !self.settings_via(via) {
            return format!("load: `{via}` is not a compiled transport\n");
        }
        // The running image is not re-parameterized. The patch stored by
        // `save` is loaded into the overlay for the next boot/build.
        let Some(patch) = self.files.get("/settings.json").cloned() else {
            return format!("SETTINGS-IMPORT-REFUSED via={via} no /settings.json\n");
        };
        match self.overlay.load_patch(&self.spec, &patch) {
            Ok(n) => format!(
                "SETTINGS-IMPORT via={via} rows={n} (applies on the next boot; nothing live is rewritten)\n"
            ),
            Err(e) => format!("SETTINGS-IMPORT-REFUSED via={via} {e}\n"),
        }
    }

    fn settings_via(&self, via: &str) -> bool {
        let s = &self.spec.kernel.settings;
        match via {
            "uart" => s.uart,
            "mailbox" => s.mailbox,
            "usb" | "usb_key" => s.usb_key,
            _ => false,
        }
    }

    fn boot(&mut self, arg: &str) -> String {
        // The selector reads real volumes as well as the modelled ones, so an ESP
        // that actually holds `\EFI\BOOT\BOOTRISCV64.EFI` is offered because it
        // was *read*, not because a table claimed it.
        let spec = self.spec.clone();
        if arg.trim().is_empty() {
            return boot::table(&spec, &mut self.ports);
        }
        let picked = boot::select(&spec, &mut self.ports, &mut self.overlay, arg.trim());
        match picked {
            Ok(s) => s,
            Err(e) => format!("{e}\n"),
        }
    }

    /// `autoboot` opens the picker; `autoboot now` takes the first entry without
    /// waiting; `autoboot <id>` takes a named one. The list is discovered every
    /// time, because media come and go.
    fn autoboot(&mut self, rest: &str) -> (Action, String) {
        let picker = AutoBoot::new(&self.spec, &self.ports);
        let arg = rest.trim();
        if picker.entries().is_empty() {
            return (
                Action::Continue,
                "autoboot: nothing bootable was detected\n".into(),
            );
        }
        if !arg.is_empty() {
            // A named entry (or `now`) is a decision, not a menu.
            let pick = match arg {
                "now" | "first" => Pick::Taken(picker.entries()[0].clone()),
                id => match picker
                    .entries()
                    .iter()
                    .find(|e| e.id.eq_ignore_ascii_case(id))
                {
                    Some(e) => Pick::Taken(e.clone()),
                    None => {
                        let ids: Vec<&str> =
                            picker.entries().iter().map(|e| e.id.as_str()).collect();
                        return (
                            Action::Continue,
                            format!("autoboot: no entry `{id}`; have {}\n", ids.join(", ")),
                        );
                    }
                },
            };
            let action = self.settle_pick(pick);
            return (action, String::new());
        }
        // The picker owns the screen until it decides.
        let head = picker
            .render(self.screen.cols(), self.screen.rows())
            .join("\n");
        self.mode = Mode::Picker(picker);
        (Action::Continue, format!("{head}\n"))
    }

    fn fw(&mut self, rest: &str) -> String {
        let (verb, arg) = split_cmd(rest);
        match verb {
            "" | "status" => match &self.update {
                Some(u) => {
                    let mut s = format!("{}\n", u.status());
                    for l in u.log() {
                        s.push_str(&format!("  {l}\n"));
                    }
                    s
                }
                None => format!(
                    "no update armed. `fw update {}`\n",
                    if self.spec.kernel.flash.url.is_empty() {
                        "https://… | DRIVE:/image".to_string()
                    } else {
                        self.spec.kernel.flash.url.clone()
                    }
                ),
            },
            "update" | "fetch" => {
                let target = if arg.trim().is_empty() {
                    self.spec.kernel.flash.url.clone()
                } else {
                    arg.trim().to_string()
                };
                if target.is_empty() {
                    return "fw update: expected https://… or DRIVE:/image\n".into();
                }
                if let Some(u) = &self.update {
                    if !u.phase().done() {
                        return format!("fw: {} already in flight (fw cancel first)\n", u.status());
                    }
                }
                let src = match Source::parse(&target) {
                    Ok(s) => s,
                    Err(e) => return format!("{e}\n"),
                };
                let image = self.spec.kernel.flash.image.clone();
                match Update::start(src, &image, &mut self.ports) {
                    Ok(u) => {
                        let s = format!("{}\n", u.status());
                        self.update = Some(u);
                        s
                    }
                    Err(e) => format!("{e}\n"),
                }
            }
            "poll" => {
                let Some(mut u) = self.update.take() else {
                    return "fw: nothing armed\n".into();
                };
                u.poll(&mut self.ports);
                let s = format!("{}\n", u.status());
                self.update = Some(u);
                s
            }
            "run" => {
                // Drive to a terminal phase with bounded polling: the same
                // steps the timer tick would take, without a thread.
                let Some(mut u) = self.update.take() else {
                    return "fw: nothing armed\n".into();
                };
                let mut steps = 0;
                while !u.phase().done() && steps < fw::MAX_POLLS {
                    u.poll(&mut self.ports);
                    steps += 1;
                }
                let mut s = format!("{}\n", u.status());
                for l in u.log() {
                    s.push_str(&format!("  {l}\n"));
                }
                self.update = Some(u);
                s
            }
            "apply" | "commit" => {
                let Some(mut u) = self.update.take() else {
                    return "fw: nothing staged\n".into();
                };
                let out = if arg.trim().is_empty() {
                    match u.apply(&mut self.ports) {
                        Ok(o) => format!("{o}\n"),
                        Err(e) => format!("{e}\n"),
                    }
                } else {
                    match u.confirm(&mut self.ports, arg.trim()) {
                        Ok(o) => format!("{o}\n"),
                        Err(e) => format!("{e}\n"),
                    }
                };
                self.update = Some(u);
                out
            }
            "cancel" | "abort" => {
                let Some(mut u) = self.update.take() else {
                    return "fw: nothing armed\n".into();
                };
                u.cancel(&mut self.ports);
                let s = format!("{}\n", u.status());
                self.update = Some(u);
                s
            }
            other => format!("fw: `{other}`? use update|poll|run|apply|cancel\n"),
        }
    }

    fn net(&self) -> String {
        match self.ports.net.as_ref() {
            Some(n) => format!("{}\n", n.status()),
            None => "no adapter session (kernel.hw is on but nothing was lent)\n".into(),
        }
    }

    fn load_ui(&mut self) -> (Action, String) {
        match self.program.repl("LoadUI();") {
            Ok(ReplResult::Output(s)) if s.contains("LOAD-UI") => (Action::LoadUi, s),
            Ok(ReplResult::Output(s)) => (Action::Continue, s),
            Ok(ReplResult::Exit) => (Action::Exit, String::new()),
            Err(e) => (Action::Continue, format!("{e}\n")),
        }
    }

    fn holyc(&mut self, line: &str) -> (Action, String) {
        let line = line.trim();
        if line.is_empty() {
            return (Action::Continue, "holyc: expected a statement\n".into());
        }
        let invoke = if line.contains('(') {
            line.to_string()
        } else {
            format!("{line}();")
        };
        match self.program.repl(&invoke) {
            Ok(ReplResult::Output(s)) => {
                if s.contains("LOAD-UI") {
                    (Action::LoadUi, s)
                } else {
                    (Action::Continue, s)
                }
            }
            Ok(ReplResult::Exit) => (Action::Exit, String::new()),
            Err(e) => (Action::Continue, format!("{e}\n")),
        }
    }
}

fn looks_like_holyc(cmd: &str) -> bool {
    is_holyc_builtin(cmd) || cmd.contains('(')
}

/// HolyC setup builtins this shell implements, mapped onto their command line.
/// `None` leaves the statement to the interpreter.
fn holyc_shell_command(line: &str) -> Option<String> {
    let (name, args) = parse_call(line)?;
    let cmd = match name.as_str() {
        "Drv" => "drv".to_string(),
        "CliMan" => format!("man {}", args.first().cloned().unwrap_or_default()),
        "SettingSet" => format!(
            "set {} {}",
            args.first().cloned().unwrap_or_default(),
            args.get(1).cloned().unwrap_or_default()
        ),
        "BootSelect" => format!("boot {}", args.first().cloned().unwrap_or_default()),
        "FwUpdate" => format!("fw update {}", args.first().cloned().unwrap_or_default()),
        "FwStatus" => "fw".to_string(),
        "FwPoll" => "fw poll".to_string(),
        "FwApply" => {
            let digest = args.first().cloned().unwrap_or_default();
            if digest.is_empty() {
                "fw apply".to_string()
            } else {
                format!("fw apply {digest}")
            }
        }
        "FwCancel" => "fw cancel".to_string(),
        _ => return None,
    };
    Some(cmd.trim_end().to_string())
}

/// `Name("a", "b");` → `("Name", ["a", "b"])`. Only string/bare arguments; a
/// statement this cannot parse is not claimed.
fn parse_call(line: &str) -> Option<(String, Vec<String>)> {
    let line = line.trim().trim_end_matches(';').trim();
    let (name, rest) = line.split_once('(')?;
    let inner = rest.strip_suffix(')')?;
    let name = name.trim();
    if name.is_empty() || !name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
        return None;
    }
    let args = inner
        .split(',')
        .map(|a| a.trim().trim_matches('"').trim().to_string())
        .filter(|a| !a.is_empty())
        .collect();
    Some((name.to_string(), args))
}

fn split_cmd(line: &str) -> (&str, &str) {
    match line.trim().split_once(char::is_whitespace) {
        Some((a, b)) => (a, b.trim()),
        None => (line.trim(), ""),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fw::MemFlash;
    use crate::ports::MemVolumes;
    use g6b_holyc::HOLYC_BUILTIN_NAMES;

    fn spec(profile: &str) -> BoardSpec {
        BoardSpec::from_json_str(&format!(r#"{{"schema_version":1,"profile":"{profile}"}}"#))
            .unwrap()
    }

    fn sess() -> Session {
        Session::new(&spec("barebone"))
    }

    fn elf(n: usize) -> Vec<u8> {
        let mut b = b"\x7fELF".to_vec();
        b.resize(n, 7);
        b
    }

    /// The kernel's stand-in: two volumes, a stepping HTTPS fetch, a flash sink.
    fn wired(profile: &str) -> Session {
        struct Net {
            body: Vec<u8>,
            left: u32,
        }
        impl NetPort for Net {
            fn get(&mut self, url: &str) -> Result<u32, String> {
                if url.starts_with("https://") {
                    Ok(1)
                } else {
                    Err("https only".into())
                }
            }
            fn poll(&mut self, _h: u32) -> Progress {
                if self.left > 0 {
                    self.left -= 1;
                    return Progress::Pending {
                        done: 0,
                        total: self.body.len() as u64,
                    };
                }
                Progress::Done(self.body.clone())
            }
            fn cancel(&mut self, _h: u32) {}
            fn status(&self) -> String {
                "HW-NET up 10.0.2.15/24 gw 10.0.2.2 dns 10.0.2.3".into()
            }
        }
        let vols = MemVolumes::new()
            .volume("KEY-FAT", "fat32", "key")
            .file("KEY-FAT", "/settings.json", b"{}".to_vec())
            .file("KEY-FAT", "/notes.txt", b"hello key\n".to_vec())
            .file("KEY-FAT", "/fw/g6lc_bios.elf", elf(4096))
            .file("KEY-FAT", "/EFI/BOOT/BOOTRISCV64.EFI", vec![0; 2048]);
        let ports = Ports::default()
            .with_volumes(vols)
            .with_net(Net {
                body: elf(8192),
                left: 2,
            })
            .with_flash(MemFlash::default());
        Session::with_ports(&spec(profile), ports)
    }

    #[test]
    fn vi_writes_a_fat32_mount_and_refuses_the_same_file_read_only() {
        use crate::input::Key;
        use crate::ports::{DriveInfo, EditTerms, Entry, MountInfo, MountPort, VolumeSlot};
        use std::collections::BTreeMap;
        struct Fat {
            files: BTreeMap<String, Vec<u8>>,
            rw: bool,
            live: bool,
        }
        impl MountPort for Fat {
            fn drives(&mut self) -> Vec<DriveInfo> {
                vec![DriveInfo {
                    id: "disk0".into(),
                    model: "fixture".into(),
                    bytes: 8 * 1024 * 1024,
                    scheme: "gpt".into(),
                    warnings: Vec::new(),
                }]
            }
            fn volumes(&mut self, drive: &str) -> Result<Vec<VolumeSlot>, String> {
                if drive != "disk0" {
                    return Ok(Vec::new());
                }
                Ok(vec![VolumeSlot {
                    drive: "disk0".into(),
                    index: 1,
                    name: "fat".into(),
                    fs: "fat32".into(),
                    label: "KEY".into(),
                    kind: "linux-filesystem".into(),
                    bytes: 8 * 1024 * 1024,
                    mountable: true,
                    write_block: None,
                    evidence: "FAT32".into(),
                }])
            }
            fn mounts(&mut self) -> Vec<MountInfo> {
                if !self.live {
                    return Vec::new();
                }
                vec![MountInfo {
                    name: "fat".into(),
                    drive: "disk0".into(),
                    index: 1,
                    fs: "fat32".into(),
                    label: "KEY".into(),
                    rw: self.rw,
                    why_ro: if self.rw {
                        None
                    } else {
                        Some("mounted read-only".into())
                    },
                    os: None,
                }]
            }
            fn mount(
                &mut self,
                drive: &str,
                index: u32,
                _name: &str,
                rw: bool,
            ) -> Result<MountInfo, String> {
                if drive != "disk0" || index != 1 {
                    return Err("no such partition".into());
                }
                self.live = true;
                self.rw = rw;
                Ok(self.mounts().remove(0))
            }
            fn umount(&mut self, name: &str) -> Result<(), String> {
                if name != "fat" || !self.live {
                    return Err("not mounted".into());
                }
                self.live = false;
                Ok(())
            }
            fn list(&mut self, _mount: &str, _path: &str) -> Result<Vec<Entry>, String> {
                Ok(self
                    .files
                    .keys()
                    .map(|p| Entry::file(p.trim_start_matches('/'), self.files[p].len() as u64))
                    .collect())
            }
            fn read(&mut self, _mount: &str, path: &str) -> Result<Vec<u8>, String> {
                self.files
                    .get(path)
                    .cloned()
                    .ok_or_else(|| format!("no such file {path}"))
            }
            fn edit_budget(&mut self, _mount: &str, path: &str) -> Result<EditTerms, String> {
                let exists = self.files.contains_key(path);
                Ok(EditTerms {
                    fs: "fat32".into(),
                    exists,
                    size: self.files.get(path).map(|b| b.len() as u64).unwrap_or(0),
                    writable: self.rw,
                    max_bytes: Some(4096),
                    can_create: self.rw,
                    can_grow: self.rw,
                    why: if self.rw {
                        None
                    } else {
                        Some("mounted read-only".into())
                    },
                    summary: if self.rw {
                        "fat32 rw <=4096B".into()
                    } else {
                        "fat32 ro".into()
                    },
                })
            }
            fn write(&mut self, _mount: &str, path: &str, data: &[u8]) -> Result<(), String> {
                if !self.rw {
                    return Err("mounted read-only".into());
                }
                if data.len() > 4096 {
                    return Err("4096 byte fat32 cap".into());
                }
                self.files.insert(path.to_string(), data.to_vec());
                Ok(())
            }
            fn mkdir(&mut self, _: &str, _: &str) -> Result<(), String> {
                Err("mkdir not in this fixture".into())
            }
            fn remove(&mut self, _: &str, _: &str) -> Result<(), String> {
                Err("remove not in this fixture".into())
            }
            fn os_info(&mut self, _: &str) -> Option<String> {
                None
            }
        }
        let mut files = BTreeMap::new();
        files.insert("/notes.txt".into(), b"hello\n".to_vec());
        let fat = Fat {
            files,
            rw: false,
            live: false,
        };
        let mut s = Session::with_ports(&spec("barebone"), Ports::default().with_mounts(fat));
        let mounted = s.eval("mount -w disk0:1 as fat").1;
        assert!(mounted.contains("rw"), "{mounted}");
        assert!(s.eval("vi fat:/notes.txt").1.is_empty());
        assert!(s.in_viewer());
        s.key(Key::Char('A'));
        s.key(Key::Char('!'));
        s.key(Key::Esc);
        for c in ":w".chars() {
            s.key(Key::Char(c));
        }
        s.key(Key::Enter);
        let frame = s.vga_text();
        assert!(frame.contains("written and verified"), "{frame}");
        s.key(Key::Char('q'));
        let back = s.eval("cat fat:/notes.txt").1;
        assert_eq!(back, "hello!\n", "{back}");
        let off = s.eval("umount fat").1;
        assert!(off.contains("umounted"), "{off}");
        let ro = s.eval("mount disk0:1 as fat").1;
        assert!(ro.contains("ro"), "{ro}");
        assert!(s.eval("vi fat:/notes.txt").1.is_empty());
        for c in ":w".chars() {
            s.key(Key::Char(c));
        }
        s.key(Key::Enter);
        let refused = s.vga_text();
        assert!(refused.contains("readonly"), "{refused}");
        s.key(Key::Char('q'));
        assert_eq!(s.eval("cat fat:/notes.txt").1, "hello!\n");
    }

    #[test]
    fn prompt_is_zealos_gt_at_the_bottom_of_the_container() {
        let mut s = sess();
        assert!(s.prompt().ends_with(PROMPT));
        assert_eq!(PROMPT, ">");
        let frame = s.render();
        assert_eq!(frame.len(), VGA_ROWS);
        assert!(frame.iter().all(|l| l.chars().count() <= VGA_COLS));
        assert_eq!(
            frame[VGA_ROWS - 1],
            s.prompt(),
            "prompt owns the bottom row"
        );
        // Typing shows up on that bottom row, not anywhere else.
        for c in "echo hi".chars() {
            s.key(Key::Char(c));
        }
        assert_eq!(s.render()[VGA_ROWS - 1], format!("{}echo hi", s.prompt()));
        s.key(Key::Enter);
        let frame = s.render();
        assert_eq!(frame[VGA_ROWS - 1], s.prompt(), "line ran; prompt is clean");
        assert_eq!(frame[VGA_ROWS - 2], "hi", "output landed above the prompt");
    }

    #[test]
    fn container_scrolls_with_keys_and_optional_mouse() {
        let mut s = sess();
        for i in 0..80 {
            s.eval(&format!("echo row{i}"));
        }
        assert!(s.screen().at_tail());
        s.key(Key::PageUp);
        assert!(!s.screen().at_tail(), "PgUp freezes the viewport");
        assert_eq!(
            s.render()[VGA_ROWS - 1],
            s.prompt(),
            "the prompt stays at the bottom while scrolled back"
        );
        assert!(s.render()[VGA_ROWS - 2].contains("scrollback"));
        s.key(Key::PageDown);
        s.key(Key::PageDown);
        assert!(s.screen().at_tail());
        s.eval("scroll top");
        assert!(!s.screen().at_tail());
        s.eval("scroll tail");
        assert!(s.screen().at_tail());
        // Mouse is off by default: the wheel does nothing at all.
        s.key(Key::PageUp);
        let frozen = s.render();
        s.mouse(Mouse::Wheel(3));
        assert_eq!(s.render(), frozen, "mouse off must be inert");
        // …and on when compiled.
        let on = BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"barebone","kernel":{"cli":{"mouse":true}}}"#,
        )
        .unwrap();
        let mut m = Session::new(&on);
        for i in 0..80 {
            m.eval(&format!("echo row{i}"));
        }
        m.mouse(Mouse::Wheel(2));
        assert!(
            !m.screen().at_tail(),
            "wheel scrolls when mouse is compiled"
        );
        m.mouse(Mouse::Press {
            col: 0,
            row: (VGA_ROWS - 1) as u16,
        });
        assert!(m.screen().at_tail(), "clicking the prompt row goes live");
    }

    #[test]
    fn usb_keycodes_drive_the_line_editor() {
        let mut s = sess();
        // `Dir` typed on a USB HID / virtio keyboard: shift+d, i, r, Enter.
        s.keycode(42, true);
        s.keycode(32, true);
        s.keycode(42, false);
        s.keycode(23, true);
        s.keycode(19, true);
        assert_eq!(s.render()[VGA_ROWS - 1], format!("{}Dir", s.prompt()));
        s.keycode(28, true);
        assert!(
            s.render().iter().any(|l| l.contains("config")),
            "Dir should have listed the BIOS tree: {:?}",
            s.render()
        );
        // Key releases and unmapped codes are not input.
        let before = s.render();
        s.keycode(30, false);
        s.keycode(0x110, true);
        assert_eq!(s.render(), before);
        // History walks with the arrows.
        s.keycode(103, true);
        assert!(s.render()[VGA_ROWS - 1].ends_with("Dir"));
    }

    #[test]
    fn ctrl_c_copies_the_line_and_ctrl_v_pastes_it() {
        let mut s = sess();
        // hello: h e l l o
        for code in [35u16, 18, 38, 38, 24] {
            s.keycode(code, true);
        }
        s.keycode(29, true);
        s.keycode(46, true);
        s.keycode(29, false);
        s.keycode(1, true);
        s.keycode(29, true);
        s.keycode(47, true);
        let row = s.render()[VGA_ROWS - 1].clone();
        assert!(row.contains("hello"), "{row}");
    }

    #[test]
    fn help_and_manual_track_the_compiled_build() {
        let mut s = sess();
        let (_, out) = s.eval("help");
        for n in HOLYC_BUILTIN_NAMES {
            assert!(out.contains(n), "missing builtin {n} in help");
        }
        assert!(
            out.contains("compiled out: loadui (kernel.web.enable)"),
            "{out}"
        );
        let (_, man) = s.eval("man firmware");
        assert!(man.contains("HTTPS-only"), "{man}");
        let (_, bad) = s.eval("loadui");
        assert!(bad.contains("not in this build"), "{bad}");
        // The web build has the command and hands over.
        let mut w = Session::new(&spec("full"));
        let (a, _) = w.eval("LoadUI");
        assert_eq!(a, Action::LoadUi);
        assert!(w.eval("help").1.contains("loadui"));
    }

    #[test]
    fn bash_and_zeal_names_are_the_same_commands() {
        let mut s = sess();
        assert!(s.eval("ls").1.contains("config"));
        assert!(s.eval("Dir").1.contains("config"));
        assert!(s.eval("cat /boot-policy").1.contains("next="));
        assert!(s.eval("Type /boot-policy").1.contains("next="));
        assert!(s.eval("write notes hello\\nworld").1.contains("WRITE-OK"));
        assert!(s.eval("Type notes").1.contains("hello"));
        assert!(s.eval("Copy notes notes2").1.contains("COPY-OK"));
        assert!(s.eval("Del notes2").1.contains("DEL-OK"));
        assert!(s.eval("rm notes2").1.contains("no such file"));
        assert_eq!(s.eval("Reboot").0, Action::Reboot);
        assert_eq!(s.eval("Shutdown").0, Action::Shutdown);
        assert_eq!(s.eval("exit").0, Action::Exit);
        assert!(s.eval(r#"Print("hi");"#).1.contains("hi"));
        assert!(s.eval("nonsense").1.contains("unknown command"));
    }

    #[test]
    fn settings_are_viewed_written_and_exported_as_a_patch() {
        let mut s = sess();
        let menu = s.eval("menu boot").1;
        assert!(menu.contains("Next stage"), "{menu}");
        assert!(menu.contains('*'), "writable rows are marked: {menu}");
        assert!(s.eval("set").1.contains("kernel.params.next"));
        assert!(s
            .eval("set boot.next edk2")
            .1
            .contains("SET boot.next = edk2"));
        assert!(s.eval("get boot.next").1.contains("pending"));
        assert!(s.eval("set cpu.cores 8").1.contains("not a writable"));
        assert!(
            s.prompt().contains("[1*]"),
            "pending writes are visible: {}",
            s.prompt()
        );
        let saved = s.eval("save uart").1;
        assert!(saved.contains("SETTINGS-EXPORT via=uart"), "{saved}");
        assert!(saved.contains("\"next\":\"edk2\""), "{saved}");
        assert!(s.eval("cat /settings.json").1.contains("edk2"));
        assert!(s.eval("set boot.next opensbi").1.contains("opensbi"));
        let loaded = s.eval("load uart").1;
        assert!(loaded.contains("SETTINGS-IMPORT via=uart"), "{loaded}");
        assert!(
            s.eval("get boot.next").1.contains("edk2"),
            "load restores the saved patch"
        );
        assert!(s
            .eval("save carrier-pigeon")
            .1
            .contains("not a compiled transport"));
        // Geometry writes apply to the live container too.
        s.eval("set settings.cli_rows 40");
        assert_eq!(s.render().len(), 40);
    }

    #[test]
    fn volumes_are_explored_and_read_only_from_setup() {
        let mut s = wired("barebone");
        let drv = s.eval("drv").1;
        assert!(drv.contains("KEY-FAT:"), "{drv}");
        assert!(s.eval("cd KEY-FAT:/").1.is_empty());
        assert_eq!(s.cwd(), "KEY-FAT:/");
        assert!(s.prompt().starts_with("KEY-FAT:/"));
        let ls = s.eval("ls").1;
        assert!(ls.contains("notes.txt") && ls.contains("<DIR>"), "{ls}");
        assert!(s.eval("cat notes.txt").1.contains("hello key"));
        assert!(s.eval("write notes.txt x").1.contains("read-only"));
        assert!(s.eval("rm notes.txt").1.contains("read-only"));
        // A firmware image is not text.
        assert!(s.eval("cat fw/g6lc_bios.elf").1.contains("binary"));
        s.eval("cd ..");
        assert_eq!(
            s.cwd(),
            "/",
            "leaving a drive root returns to the BIOS tree"
        );
        assert!(s.eval("cd NOPE:/").1.contains("no volume"));
        // Without ports the same commands refuse instead of faking a listing.
        let mut bare = sess();
        assert!(bare.eval("drv").1.contains("no volumes"));
        assert!(bare.eval("cd KEY-FAT:/").1.contains("no volumes"));
    }

    #[test]
    fn read_only_viewer_opens_over_the_container() {
        let mut s = wired("barebone");
        assert!(!s.in_viewer());
        s.eval("vi /boot-policy");
        assert!(s.in_viewer());
        let frame = s.render();
        assert_eq!(frame.len(), VGA_ROWS);
        assert!(frame[frame.len() - 1].contains("readonly"), "{:?}", frame);
        // Editing keys are refused, not applied.
        s.key(Key::Char('i'));
        assert!(s.render()[VGA_ROWS - 1].contains("readonly"));
        // `:q` returns to the prompt.
        s.key(Key::Char(':'));
        s.key(Key::Char('q'));
        s.key(Key::Enter);
        assert!(!s.in_viewer());
        assert_eq!(s.render()[VGA_ROWS - 1], s.prompt());
        // Volume files open too.
        s.eval("vi KEY-FAT:/notes.txt");
        assert!(s.in_viewer());
        s.key(Key::Char('q'));
        assert!(!s.in_viewer());
        assert!(s.eval("vi /nope").1.contains("no such file"));
    }

    #[test]
    fn firmware_update_over_https_polls_without_a_thread() {
        let mut s = wired("barebone");
        assert!(s.eval("net").1.contains("HW-NET up"));
        assert!(s.eval("fw").1.contains("no update armed"));
        let armed = s.eval("fw update https://fw.gsys.dev/g6lc_bios.elf").1;
        assert!(armed.contains("fw fetch"), "{armed}");
        assert!(s.prompt().contains("[fw"), "{}", s.prompt());
        // A second arm while one is in flight is refused.
        assert!(s
            .eval("fw update https://fw.gsys.dev/other.elf")
            .1
            .contains("already in flight"));
        // The timer tick is what moves it along — one bounded step each.
        for _ in 0..8 {
            s.tick();
        }
        let st = s.eval("fw").1;
        assert!(st.contains("fw ready"), "{st}");
        assert!(st.contains("sha256="), "{st}");
        assert!(st.contains("FW-VERIFY elf"), "{st}");
        let applied = s.eval("fw apply").1;
        assert!(applied.contains("FLASH-COMMIT bios"), "{applied}");
        assert!(s.eval("fw apply").1.contains("not ready"));
        // Plain HTTP is refused before any socket is opened.
        assert!(s
            .eval("fw update http://fw.gsys.dev/x.elf")
            .1
            .contains("refusing plain HTTP"));
    }

    #[test]
    fn firmware_update_from_a_usb_key_and_cancel() {
        let mut s = wired("barebone");
        let out = s.eval("fw update KEY-FAT:/fw/g6lc_bios.elf").1;
        assert!(
            out.contains("fw verify") || out.contains("fw fetch"),
            "{out}"
        );
        let run = s.eval("fw run").1;
        assert!(run.contains("fw ready"), "{run}");
        assert!(run.contains("FW-FETCH usb KEY-FAT"), "{run}");
        s.eval("fw apply");
        // Re-arm then cancel.
        assert!(s
            .eval("fw update KEY-FAT:/fw/g6lc_bios.elf")
            .1
            .contains("fw "));
        assert!(s.eval("fw cancel").1.contains("fw cancelled"));
        assert!(s.eval("fw apply").1.contains("not ready"));
        assert!(s
            .eval("fw nonsense")
            .1
            .contains("update|poll|run|apply|cancel"));
    }

    #[test]
    fn boot_selector_probes_volumes_for_edk2_and_uboot() {
        let mut s = wired("barebone");
        let table = s.eval("boot").1;
        assert!(table.contains("opensbi"), "{table}");
        assert!(table.contains("edk2@KEY-FAT"), "{table}");
        assert!(
            table.contains("present") && table.contains("absent"),
            "{table}"
        );
        let sel = s.eval("boot edk2@KEY-FAT").1;
        assert!(sel.contains("BOOT-SELECT edk2@KEY-FAT"), "{sel}");
        assert_eq!(s.pending_settings().get("boot.next"), Some("edk2"));
        assert!(s.eval("boot u-boot@KEY-FAT").1.contains("absent"));
        assert!(s.eval("boot grub").1.contains("unknown target"));
    }

    #[test]
    fn barebone_and_web_builds_share_one_cli() {
        // The same session code runs with the engine compiled…
        let mut web = Session::new(&spec("full"));
        assert!(web.spec().web_stack() && web.spec().cli_before_web());
        assert!(web.eval("help").1.contains("loadui"));
        assert_eq!(web.eval("loadui").0, Action::LoadUi);
        // …and without it.
        let mut bare = sess();
        assert!(!bare.spec().web_stack());
        assert!(bare.render().len() == VGA_ROWS);
        assert!(bare.eval("menu settings").1.contains("Web stack"));
        // A wider container is honored on both.
        let wide = BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"full","kernel":{"cli":{"rows":48,"cols":132,"scrollback":2048}}}"#,
        )
        .unwrap();
        let w = Session::new(&wide);
        assert_eq!(w.render().len(), 48);
        assert!(w.render().iter().all(|l| l.chars().count() <= 132));
    }

    /// The picker in the container: arrows wrap, the countdown fires, Esc keeps
    /// the operator at the prompt, and a pick lands in the settings overlay.
    #[test]
    fn autoboot_picker_owns_the_screen_until_it_decides() {
        let mut s = wired("barebone");
        let opened = s.eval("autoboot").1;
        assert!(opened.contains("AUTOBOOT"), "{opened}");
        assert!(s.picker().is_some(), "the picker owns the screen");
        let frame = s.render();
        assert_eq!(frame.len(), VGA_ROWS);
        assert!(frame[0].contains("order=live-first"), "{:?}", frame[0]);
        assert!(frame[1].starts_with("> 1."), "{:?}", frame[1]);
        // Wraparound: up from the top lands on the last entry.
        let first = s.picker().unwrap().selected().unwrap().id.clone();
        s.key(Key::Up);
        let last = s.picker().unwrap().selected().unwrap().id.clone();
        assert_ne!(first, last);
        s.key(Key::Down);
        assert_eq!(s.picker().unwrap().selected().unwrap().id, first);
        // Esc returns to the prompt without booting anything.
        assert_eq!(s.key(Key::Esc), Action::Continue);
        assert!(s.picker().is_none());
        assert!(s.picked().is_none());
        assert_eq!(s.render()[VGA_ROWS - 1], s.prompt());
        assert!(
            s.render().iter().any(|r| r.contains("AUTOBOOT-CANCEL")),
            "{:?}",
            s.render()
        );
    }

    #[test]
    fn autoboot_countdown_takes_the_first_entry_and_writes_the_stage() {
        let mut s = wired("barebone");
        s.eval("autoboot");
        assert_eq!(s.picker().unwrap().left_ms(), Some(2000));
        assert_eq!(s.tick_ms(1000), Action::Continue);
        // The compiled countdown is 2 s, so the second tick decides.
        let action = s.tick_ms(1000);
        let picked = s.picked().cloned().expect("the countdown took an entry");
        assert!(s.picker().is_none(), "the picker released the screen");
        assert!(
            s.render().iter().any(|r| r.contains("AUTOBOOT-PICK")),
            "{:?}",
            s.render()
        );
        match picked.target {
            BootTargetKind::Volume => {
                assert_eq!(action, Action::Boot);
                // A volume pick records the medium it came from and the stage it
                // hands off to; a loader stage is latched, `linux` is not (the
                // kernel is the stage).
                assert!(!picked.evidence.is_empty(), "{picked:?}");
                assert_eq!(s.pending_settings().get("boot.volume"), Some("usb"));
                match picked.stage.as_str() {
                    "linux" => assert_eq!(s.pending_settings().get("boot.next"), None),
                    stage => assert_eq!(s.pending_settings().get("boot.next"), Some(stage)),
                }
            }
            other => panic!("expected a volume entry first, got {other:?}"),
        }
    }

    #[test]
    fn autoboot_now_and_named_entries_skip_the_menu() {
        let mut s = wired("barebone");
        let (action, _) = s.eval("autoboot now");
        assert_eq!(action, Action::Boot);
        assert!(s.picked().is_some());
        assert!(s.picker().is_none(), "no menu when the answer was given");
        let bad = s.eval("autoboot nosuchdisk").1;
        assert!(bad.contains("no entry"), "{bad}");
        assert!(bad.contains("@"), "the refusal lists what exists: {bad}");
    }

    #[test]
    fn autoboot_is_compiled_out_when_the_board_says_so() {
        let off = BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"barebone","kernel":{"cli":{"autoboot":{"enable":false}}}}"#,
        )
        .unwrap();
        let mut s = Session::new(&off);
        let out = s.eval("autoboot").1;
        assert!(out.contains("not in this build"), "{out}");
        assert!(out.contains("kernel.cli.autoboot.enable"), "{out}");
        assert!(s
            .eval("help")
            .1
            .contains("autoboot (kernel.cli.autoboot.enable)"));
        // With no ports at all the picker still offers setup, never nothing.
        let mut bare = sess();
        let opened = bare.eval("autoboot").1;
        assert!(opened.contains("Setup"), "{opened}");
    }

    #[test]
    fn holyc_setup_builtins_run_the_real_commands() {
        let mut s = wired("barebone");
        // Registered *and* implemented: these drive the same code the command
        // line does, not a marker string.
        assert!(s.eval("Drv();").1.contains("KEY-FAT:"));
        assert!(s.eval("CliMan(\"firmware\");").1.contains("HTTPS-only"));
        assert!(s
            .eval("SettingSet(\"boot.next\", \"edk2\");")
            .1
            .contains("SET boot.next = edk2"));
        assert_eq!(s.pending_settings().get("boot.next"), Some("edk2"));
        assert!(s
            .eval("BootSelect(\"edk2@KEY-FAT\");")
            .1
            .contains("BOOT-SELECT edk2@KEY-FAT"));
        assert!(s
            .eval("FwUpdate(\"KEY-FAT:/fw/g6lc_bios.elf\");")
            .1
            .contains("fw "));
        assert!(s.eval("FwPoll();").1.contains("fw "));
        assert!(s.eval("FwStatus();").1.contains("fw "));
        s.eval("fw run");
        assert!(s.eval("FwApply();").1.contains("FLASH-COMMIT"));
        assert!(s.eval("FwCancel();").1.contains("fw applied"));
        // Every one of them is a registered builtin, so help/man list them.
        for n in [
            "Drv",
            "CliMan",
            "SettingSet",
            "BootSelect",
            "FwUpdate",
            "FwStatus",
            "FwPoll",
            "FwApply",
            "FwCancel",
        ] {
            assert!(HOLYC_BUILTIN_NAMES.contains(&n), "{n} must be registered");
        }
        // A builtin with no shell implementation still goes to HolyC.
        assert!(s.eval("Print(\"via holyc\");").1.contains("via holyc"));
    }

    #[test]
    fn auto_boot_yields_to_gpu() {
        let full = spec("full");
        assert!(full.wants_zealcli(false));
        assert!(!full.wants_zealcli(true));
        assert!(
            spec("embedded").wants_zealcli(true),
            "embedded stays on CLI"
        );
        assert!(
            spec("barebone").wants_zealcli(true),
            "barebone has no other face"
        );
    }
}
