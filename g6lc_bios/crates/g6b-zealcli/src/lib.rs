// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! VGA, mouse-less ZealOS-shaped command line. Imitates bash (`ls`/`cd`/`cat`)
//! with ZealOS names (`Dir`/`Cd`/`Type`/`Ed`, prompt `>` from `CmdLinePrompt`).
//! Depends on HolyC + BoardSpec only — **not** `g6b-hw`, not browser-ui.
//!
//! `LoadUI()` asks the kernel to start browser-ui when that face is compiled.
//! `BoardSpec::wants_zealcli(gpu_ready)` is false once a GPU is announced
//! (`kernel.cli.boot=auto`).

#![allow(missing_docs)]

use std::collections::BTreeMap;

use g6b_holyc::{is_holyc_builtin, Program, ReplResult, HOLYC_BUILTIN_NAMES};
use g6b_spec::BoardSpec;

/// ZealOS `CmdLinePrompt` prints `>` after the cwd.
pub const PROMPT: &str = ">";
/// VGA text geometry (mouse-less).
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
}

/// In-memory VGA CLI. Edits BIOS sections without a pointer device.
#[derive(Debug)]
pub struct Session {
    cwd: String,
    files: BTreeMap<String, String>,
    program: Program,
    screen: Vec<String>,
}

impl Session {
    pub fn new(spec: &BoardSpec) -> Self {
        let mut files = BTreeMap::new();
        files.insert("/config".into(), "{}".into());
        files.insert("/keys".into(), String::new());
        files.insert("/boot-policy".into(), "next=opensbi\n".into());
        files.insert(
            "/help".into(),
            "ZealOS CLI: Dir Cd Type Ed Cls Help LoadUI. Bash: ls cd pwd cat edit clear.\n".into(),
        );
        let _ = spec;
        let mut s = Self {
            cwd: "/".into(),
            files,
            program: Program::default(),
            screen: Vec::new(),
        };
        s.push_line("G6LC-BIOS zealcli (VGA, no mouse)");
        s.push_line("Type Help. LoadUI() starts browser-ui when compiled.");
        s
    }

    pub fn prompt(&self) -> String {
        format!("{}{}", self.cwd, PROMPT)
    }

    pub fn cwd(&self) -> &str {
        &self.cwd
    }

    /// 80×25 VGA text, no pointer. Oldest lines scroll off.
    pub fn vga_text(&self) -> String {
        let start = self.screen.len().saturating_sub(VGA_ROWS);
        let mut rows: Vec<String> = self.screen[start..]
            .iter()
            .map(|l| truncate_cols(l, VGA_COLS))
            .collect();
        while rows.len() < VGA_ROWS {
            rows.push(String::new());
        }
        rows.join("\n")
    }

    pub fn eval(&mut self, line: &str) -> (Action, String) {
        let line = line.trim();
        if line.is_empty() {
            return (Action::Continue, String::new());
        }
        self.push_line(&format!("{}{line}", self.prompt()));
        let (action, out) = self.dispatch(line);
        if !out.is_empty() {
            for l in out.lines() {
                self.push_line(l);
            }
        }
        (action, out)
    }

    fn dispatch(&mut self, line: &str) -> (Action, String) {
        let (cmd, rest) = split_cmd(line);
        match cmd {
            "help" | "Help" | "?" => (Action::Continue, help_text()),
            "clear" | "cls" | "Cls" => {
                self.screen.clear();
                (Action::Continue, String::new())
            }
            "pwd" => (Action::Continue, format!("{}\n", self.cwd)),
            "ls" | "dir" | "Dir" => (Action::Continue, self.list(rest)),
            "cd" | "Cd" => match self.cd(rest) {
                Ok(()) => (Action::Continue, String::new()),
                Err(e) => (Action::Continue, format!("{e}\n")),
            },
            "cat" | "type" | "Type" => (Action::Continue, self.cat(rest)),
            "ed" | "edit" | "Ed" => (Action::Continue, self.ed(rest)),
            "mkdir" | "DirMk" => (Action::Continue, self.mkdir(rest)),
            "rm" | "del" | "Del" => (Action::Continue, self.rm(rest)),
            "cp" | "Copy" => (Action::Continue, self.cp(rest)),
            "mv" | "Move" => (Action::Continue, self.mv(rest)),
            "echo" => (Action::Continue, format!("{rest}\n")),
            "exit" | "Exit" | "quit" => (Action::Exit, String::new()),
            "reboot" | "Reboot" => (Action::Reboot, "REBOOT\n".into()),
            "shutdown" | "Shutdown" => (Action::Shutdown, "SHUTDOWN\n".into()),
            "wakeup" | "Wakeup" => (Action::Wakeup, "WAKEUP\n".into()),
            "linux" | "LinuxHandoff" => (Action::LinuxHandoff, "LINUX-HANDOFF\n".into()),
            "loadui" | "LoadUI" => self.load_ui(),
            "holyc" => self.holyc(rest),
            other if looks_like_holyc(other) => self.holyc(line),
            other => (
                Action::Continue,
                format!("unknown command `{other}`; try Help\n"),
            ),
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

    fn list(&self, arg: &str) -> String {
        let dir = if arg.is_empty() {
            self.cwd.clone()
        } else {
            self.resolve(arg)
        };
        let mut names: Vec<&str> = self
            .files
            .keys()
            .filter(|p| parent_of(p) == dir)
            .map(|p| p.rsplit('/').next().unwrap_or(p.as_str()))
            .collect();
        names.sort();
        if names.is_empty() {
            format!("(empty {dir})\n")
        } else {
            let mut s = String::new();
            for n in names {
                s.push_str(n);
                s.push('\n');
            }
            s
        }
    }

    fn cd(&mut self, arg: &str) -> Result<(), String> {
        if arg.is_empty() || arg == "~" || arg == "/" {
            self.cwd = "/".into();
            return Ok(());
        }
        if arg == ".." {
            self.cwd = parent_of(&self.cwd);
            return Ok(());
        }
        let p = self.resolve(arg);
        if p == "/" || self.files.keys().any(|f| parent_of(f) == p || f == &p) {
            self.cwd = p;
            Ok(())
        } else {
            Err(format!("Cd: no such directory {arg}"))
        }
    }

    fn cat(&self, arg: &str) -> String {
        if arg.is_empty() {
            return "Type: filename\n".into();
        }
        let p = self.resolve(arg);
        match self.files.get(&p) {
            Some(b) => {
                if b.ends_with('\n') {
                    b.clone()
                } else {
                    format!("{b}\n")
                }
            }
            None => format!("Type: no such file {arg}\n"),
        }
    }

    fn ed(&mut self, rest: &str) -> String {
        let mut parts = rest.splitn(2, ' ');
        let name = parts.next().unwrap_or("");
        let body = parts.next().unwrap_or("");
        if name.is_empty() {
            return "Ed: filename [text]\n".into();
        }
        let p = self.resolve(name);
        if body.is_empty() {
            return self.cat(name);
        }
        self.files.insert(p, body.replace("\\n", "\n"));
        "ED-OK\n".into()
    }

    fn mkdir(&mut self, arg: &str) -> String {
        if arg.is_empty() {
            return "DirMk: name\n".into();
        }
        let p = self.resolve(arg);
        let keep = format!("{p}/.keep");
        self.files.entry(keep).or_default();
        "DIRMK-OK\n".into()
    }

    fn rm(&mut self, arg: &str) -> String {
        if arg.is_empty() {
            return "Del: name\n".into();
        }
        let p = self.resolve(arg);
        if self.files.remove(&p).is_some() {
            "DEL-OK\n".into()
        } else {
            format!("Del: no such file {arg}\n")
        }
    }

    fn cp(&mut self, rest: &str) -> String {
        let mut it = rest.split_whitespace();
        let (Some(src), Some(dst)) = (it.next(), it.next()) else {
            return "Copy: src dst\n".into();
        };
        let s = self.resolve(src);
        let d = self.resolve(dst);
        match self.files.get(&s).cloned() {
            Some(b) => {
                self.files.insert(d, b);
                "COPY-OK\n".into()
            }
            None => format!("Copy: no such file {src}\n"),
        }
    }

    fn mv(&mut self, rest: &str) -> String {
        let mut it = rest.split_whitespace();
        let (Some(src), Some(dst)) = (it.next(), it.next()) else {
            return "Move: src dst\n".into();
        };
        let s = self.resolve(src);
        let d = self.resolve(dst);
        match self.files.remove(&s) {
            Some(b) => {
                self.files.insert(d, b);
                "MOVE-OK\n".into()
            }
            None => format!("Move: no such file {src}\n"),
        }
    }

    fn resolve(&self, arg: &str) -> String {
        if arg.starts_with('/') {
            normalize_path(arg)
        } else if self.cwd == "/" {
            normalize_path(&format!("/{arg}"))
        } else {
            normalize_path(&format!("{}/{arg}", self.cwd))
        }
    }

    fn push_line(&mut self, line: &str) {
        for chunk in wrap_cols(line, VGA_COLS) {
            self.screen.push(chunk);
        }
        let max = VGA_ROWS * 4;
        if self.screen.len() > max {
            let drop = self.screen.len() - max;
            self.screen.drain(..drop);
        }
    }
}

fn looks_like_holyc(cmd: &str) -> bool {
    is_holyc_builtin(cmd) || cmd.contains('(')
}

fn help_text() -> String {
    let mut s = String::from(
        "zealcli (VGA, no mouse). ZealOS: Dir Cd Type Ed Cls Help LoadUI. Bash: ls cd pwd cat edit rm cp mv echo clear exit.\nHolyC builtins:\n",
    );
    for (i, n) in HOLYC_BUILTIN_NAMES.iter().enumerate() {
        if i > 0 && i % 6 == 0 {
            s.push('\n');
        }
        s.push_str(n);
        s.push(' ');
    }
    s.push('\n');
    s
}

fn split_cmd(line: &str) -> (&str, &str) {
    match line.split_once(char::is_whitespace) {
        Some((a, b)) => (a, b.trim()),
        None => (line, ""),
    }
}

fn parent_of(path: &str) -> String {
    let path = path.trim_end_matches('/');
    match path.rsplit_once('/') {
        Some(("", _)) | None => "/".into(),
        Some((p, _)) => p.to_string(),
    }
}

fn normalize_path(p: &str) -> String {
    let mut out: Vec<&str> = Vec::new();
    for part in p.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                out.pop();
            }
            s => out.push(s),
        }
    }
    if out.is_empty() {
        "/".into()
    } else {
        format!("/{}", out.join("/"))
    }
}

fn truncate_cols(s: &str, cols: usize) -> String {
    s.chars().take(cols).collect()
}

fn wrap_cols(s: &str, cols: usize) -> Vec<String> {
    if s.is_empty() {
        return vec![String::new()];
    }
    let chars: Vec<char> = s.chars().collect();
    chars.chunks(cols).map(|c| c.iter().collect()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sess() -> Session {
        let spec =
            BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"embedded"}"#).unwrap();
        Session::new(&spec)
    }

    #[test]
    fn prompt_is_zealos_gt() {
        let s = sess();
        assert!(s.prompt().ends_with(PROMPT));
        assert_eq!(PROMPT, ">");
    }

    #[test]
    fn help_tracks_holyc_builtins() {
        let mut s = sess();
        let (_, out) = s.eval("Help");
        assert!(out.contains("LoadUI"), "{out}");
        assert!(out.contains("Print"), "{out}");
        for n in HOLYC_BUILTIN_NAMES {
            assert!(out.contains(n), "missing {n} in {out}");
        }
        assert!(out.contains("no mouse"), "{out}");
    }

    #[test]
    fn bash_and_zeal_file_ops() {
        let mut s = sess();
        let (_, out) = s.eval("ls");
        assert!(out.contains("config"), "{out}");
        s.eval("cd /");
        let (_, out) = s.eval("cat /boot-policy");
        assert!(out.contains("opensbi"), "{out}");
        let (_, out) = s.eval("Ed notes hello\\nworld");
        assert!(out.contains("ED-OK"), "{out}");
        let (_, out) = s.eval("Type notes");
        assert!(out.contains("hello"), "{out}");
        s.eval("Copy notes notes2");
        s.eval("rm notes2");
        let (a, _) = s.eval("LoadUI");
        assert_eq!(a, Action::LoadUi);
        let (a, _) = s.eval("Reboot");
        assert_eq!(a, Action::Reboot);
    }

    #[test]
    fn vga_text_is_fixed_geometry_no_pointer() {
        let mut s = sess();
        for i in 0..40 {
            s.eval(&format!("echo line{i}"));
        }
        let t = s.vga_text();
        assert_eq!(t.lines().count(), VGA_ROWS);
        assert!(t.lines().all(|l| l.chars().count() <= VGA_COLS));
    }

    #[test]
    fn auto_boot_yields_to_gpu() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        assert!(spec.wants_zealcli(false));
        assert!(!spec.wants_zealcli(true));
        let emb = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"embedded"}"#).unwrap();
        assert!(emb.wants_zealcli(true), "embedded stays on CLI");
    }

    #[test]
    fn holyc_print_passthrough() {
        let mut s = sess();
        let (_, out) = s.eval(r#"Print("hi");"#);
        assert!(out.contains("hi"), "{out}");
    }
}
