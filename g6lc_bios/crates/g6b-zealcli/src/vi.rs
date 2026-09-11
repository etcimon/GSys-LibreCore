// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! A light **read-only** vi, in its own module.
//!
//! Firmware setup has to show a config file, a boot policy, a manual page or a
//! staged image header without becoming an editor: an editor in a BIOS is a way
//! to corrupt a volume with one stray key. So this viewer implements the motions
//! (`h j k l`, `0 $`, `gg G`, `Ctrl-F/B`, `/` + `n N`), `:set number`, and
//! `:q`, and answers every mutating key with vi's own read-only refusal instead
//! of pretending to edit. It borrows the container geometry: the last row is the
//! status/command line, which is the same bottom line the shell prompt uses.

use crate::input::Key;
use crate::screen::truncate;

/// Where keys currently go.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Mode {
    Normal,
    /// `:` command line.
    Command,
    /// `/` search line.
    Search,
    /// `i`/`a`/`o` — typing into the buffer. Only reachable on a writable file.
    Insert,
}

/// What the session should do after one key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ViAction {
    /// Stay in the viewer.
    Stay,
    /// `:q` — return to the shell.
    Quit,
    /// `:w` / `:wq` — save this text, then quit if `quit`.
    Write { text: String, quit: bool },
}

/// One open buffer, view-only.
#[derive(Debug, Clone)]
pub struct Vi {
    name: String,
    lines: Vec<String>,
    /// First visible line.
    top: usize,
    /// Cursor line.
    cur: usize,
    /// Cursor column (cell).
    col: usize,
    cols: usize,
    rows: usize,
    numbers: bool,
    msg: String,
    entry: String,
    mode: Mode,
    last_search: String,
    /// `g` seen, waiting for the second `g`.
    pending_g: bool,
    /// The buffer may be written back (`:w`). False keeps vi's own refusal.
    writable: bool,
    /// Why the file is read-only, when it is — a dirty ext journal, a read-only
    /// mount, the BIOS-local tree after handoff.
    why_ro: String,
    /// Edited since it was opened.
    dirty: bool,
    /// The file's own line ending, restored on save.
    ///
    /// A BIOS edits files other systems wrote: `extlinux.conf` from a Windows
    /// installer, `boot.ini`-shaped things on FAT32 and NTFS. Saving CRLF text as
    /// LF rewrites *every* line of the file, which turns a one-line repair into a
    /// whole-file diff — and for a loader that parses strictly, into a new bug.
    crlf: bool,
    /// The file began with a UTF-8 BOM, which is preserved for the same reason.
    bom: bool,
    /// The file did not end with a newline; adding one changes it.
    no_final_newline: bool,
    /// Largest content the filesystem will accept for this path, when bounded.
    /// Checked before a save so the refusal costs nothing.
    max_bytes: Option<u64>,
    /// The filesystem's terms, shown in the status line (`ext4 rw <=4096B in place`).
    terms: String,
    /// The buffer holds only the first part of a larger file. Saving would truncate
    /// it, so such a buffer is never writable.
    partial: bool,
}

const READONLY: &str = "E45: 'readonly' option is set — this BIOS viewer never writes";

impl Vi {
    /// Open `text` under `name` in a `cols`×`rows` container, read-only.
    pub fn open(name: &str, text: &str, cols: usize, rows: usize) -> Self {
        // The file's own conventions are recorded here and restored by `text()`.
        // An editor that silently normalizes them is not editing the file, it is
        // rewriting it.
        let bom = text.starts_with('\u{feff}');
        let body = text.strip_prefix('\u{feff}').unwrap_or(text);
        let crlf = body.contains("\r\n");
        let no_final_newline = !body.is_empty() && !body.ends_with('\n');
        let normalized = body.replace("\r\n", "\n");
        let lines: Vec<String> = if normalized.is_empty() {
            Vec::new()
        } else {
            normalized
                .trim_end_matches('\n')
                .split('\n')
                .map(expand_tabs)
                .collect()
        };
        let bytes: usize = lines.iter().map(|l| l.len() + 1).sum();
        Self {
            name: name.into(),
            msg: format!(
                "\"{}\" [readonly] {}L, {}B{}",
                name,
                lines.len(),
                bytes,
                if crlf { " [dos]" } else { "" }
            ),
            lines,
            top: 0,
            cur: 0,
            col: 0,
            cols: cols.max(20),
            rows: rows.max(4),
            numbers: false,
            entry: String::new(),
            mode: Mode::Normal,
            last_search: String::new(),
            pending_g: false,
            writable: false,
            why_ro: String::new(),
            dirty: false,
            crlf,
            bom,
            no_final_newline,
            max_bytes: None,
            terms: String::new(),
            partial: false,
        }
    }

    /// Open a file that **can** be written back (a writable mount).
    ///
    /// This is the difference between a viewer and a repair tool: the same motions
    /// and the same screen, plus `i`/`a`/`o`/`x`/`dd` and `:w`. Read-only stays the
    /// default everywhere else, and the refusal names the reason.
    pub fn open_rw(name: &str, text: &str, cols: usize, rows: usize) -> Self {
        let mut v = Self::open(name, text, cols, rows);
        v.writable = true;
        let bytes: usize = v.lines.iter().map(|l| l.len() + 1).sum();
        v.msg = format!(
            "\"{}\" {}L, {}B{}",
            name,
            v.lines.len(),
            bytes,
            if v.crlf { " [dos]" } else { "" }
        );
        v
    }

    /// Record the filesystem's terms for this path: the byte ceiling a save must
    /// respect and the summary shown in the status line.
    ///
    /// The ceiling is checked at `:w` time *before* anything is written, so an
    /// operator who cannot save learns it from a refusal that costs nothing rather
    /// than from a half-applied write.
    pub fn with_terms(mut self, summary: &str, max_bytes: Option<u64>) -> Self {
        self.terms = summary.to_string();
        self.max_bytes = max_bytes;
        let bytes = self.text().len();
        self.msg = if self.writable {
            format!(
                "\"{}\" {}L, {}B{} [{summary}]",
                self.name,
                self.lines.len(),
                bytes,
                if self.crlf { " [dos]" } else { "" }
            )
        } else {
            format!(
                "\"{}\" [readonly: {summary}] {}L",
                self.name,
                self.lines.len()
            )
        };
        self
    }

    /// Mark the buffer as only the first part of a larger file.
    ///
    /// Such a buffer is **never** writable: saving it would truncate the file to
    /// what happened to fit on screen, which is data loss disguised as an edit.
    pub fn partial(mut self, total: u64, shown: u64) -> Self {
        self.partial = true;
        self.writable = false;
        self.why_ro = format!(
            "only the first {shown} of {total} bytes are open; saving would truncate the file"
        );
        self.msg = format!(
            "\"{}\" [readonly: first {shown} of {total} bytes] {}L",
            self.name,
            self.lines.len()
        );
        self
    }

    /// Read-only with a stated reason, so `i` explains itself.
    pub fn open_ro(name: &str, text: &str, cols: usize, rows: usize, why: &str) -> Self {
        let mut v = Self::open(name, text, cols, rows);
        v.why_ro = why.to_string();
        v.msg = format!("\"{}\" [readonly: {why}] {}L", name, v.lines.len());
        v
    }

    pub fn name(&self) -> &str {
        &self.name
    }

    /// The buffer as text, **in the file's own conventions**.
    ///
    /// The BOM, the CRLF line ending and a missing final newline are all restored,
    /// so a one-line repair to a file another system wrote stays a one-line change.
    pub fn text(&self) -> String {
        if self.lines.is_empty() {
            return if self.bom {
                "\u{feff}".into()
            } else {
                String::new()
            };
        }
        let mut body = self.lines.join("\n");
        if !self.no_final_newline {
            body.push('\n');
        }
        if self.crlf {
            body = body.replace('\n', "\r\n");
        }
        if self.bom {
            body.insert(0, '\u{feff}');
        }
        body
    }

    /// True when the file uses CRLF endings (and a save will keep them).
    pub fn dos(&self) -> bool {
        self.crlf
    }

    /// Put a message on the status line (what a save reports).
    pub fn note(&mut self, msg: &str) {
        self.msg = msg.to_string();
        self.dirty = false;
    }

    pub fn writable(&self) -> bool {
        self.writable
    }

    pub fn dirty(&self) -> bool {
        self.dirty
    }

    /// The refusal an operator sees for a mutating key.
    fn refusal(&self) -> String {
        if self.why_ro.is_empty() {
            READONLY.to_string()
        } else {
            format!("E45: 'readonly' — {}", self.why_ro)
        }
    }

    /// Text rows available above the status line.
    fn body(&self) -> usize {
        self.rows - 1
    }

    pub fn key(&mut self, k: Key) -> ViAction {
        match self.mode {
            Mode::Normal => self.normal(k),
            Mode::Insert => self.insert_key(k),
            Mode::Command | Mode::Search => self.entry_key(k),
        }
    }

    /// Insert mode: printable characters, Enter splits, Backspace joins, Esc back
    /// to normal. Deliberately small — this edits a boot config, not prose.
    fn insert_key(&mut self, k: Key) -> ViAction {
        if self.lines.is_empty() {
            self.lines.push(String::new());
        }
        let line_count = self.lines.len();
        let cur = self.cur.min(line_count - 1);
        match k {
            Key::Esc => {
                self.mode = Mode::Normal;
                self.col = self.col.min(self.line_len());
                self.msg.clear();
            }
            Key::Char('\t') => {
                let at = self.col.min(self.lines[cur].len());
                self.lines[cur].insert_str(at, "    ");
                self.col = at + 4;
                self.dirty = true;
            }
            Key::Char(c) if !c.is_control() => {
                let at = self.col.min(self.lines[cur].len());
                self.lines[cur].insert(at, c);
                self.col = at + 1;
                self.dirty = true;
            }
            Key::Enter => {
                let at = self.col.min(self.lines[cur].len());
                let tail = self.lines[cur].split_off(at);
                self.lines.insert(cur + 1, tail);
                self.cur = cur + 1;
                self.col = 0;
                self.dirty = true;
                self.keep_in_view();
            }
            Key::Backspace => {
                let at = self.col.min(self.lines[cur].len());
                if at > 0 {
                    self.lines[cur].remove(at - 1);
                    self.col = at - 1;
                    self.dirty = true;
                } else if cur > 0 {
                    // Join with the previous line, cursor at the seam.
                    let tail = self.lines.remove(cur);
                    self.cur = cur - 1;
                    self.col = self.lines[self.cur].len();
                    self.lines[self.cur].push_str(&tail);
                    self.dirty = true;
                    self.keep_in_view();
                }
            }
            Key::Left => self.col = self.col.saturating_sub(1),
            Key::Right => self.col = (self.col + 1).min(self.line_len()),
            Key::Up => self.goto(self.cur.saturating_sub(1)),
            Key::Down => self.goto(self.cur + 1),
            _ => {}
        }
        ViAction::Stay
    }

    fn normal(&mut self, k: Key) -> ViAction {
        let g = std::mem::take(&mut self.pending_g);
        match k {
            Key::Char('g') if g => {
                self.goto(0);
                self.msg.clear();
            }
            Key::Char('g') => self.pending_g = true,
            Key::Char('G') => self.goto(self.lines.len().saturating_sub(1)),
            Key::Char('j') | Key::Down => self.goto(self.cur + 1),
            Key::Char('k') | Key::Up => self.goto(self.cur.saturating_sub(1)),
            Key::Char('h') | Key::Left => self.col = self.col.saturating_sub(1),
            Key::Char('l') | Key::Right => self.col = (self.col + 1).min(self.line_len()),
            Key::Char('0') | Key::Home => self.col = 0,
            Key::Char('$') | Key::End => self.col = self.line_len(),
            Key::Char('\u{6}') | Key::PageDown => self.scroll_page(1),
            Key::Char('\u{2}') | Key::PageUp => self.scroll_page(-1),
            Key::Char('n') => self.search_again(1),
            Key::Char('N') => self.search_again(-1),
            Key::Char('Z') => {
                // `ZZ`: write when there is something to write, else just quit.
                return if self.writable && self.dirty {
                    ViAction::Write {
                        text: self.text(),
                        quit: true,
                    }
                } else {
                    ViAction::Quit
                };
            }
            Key::Char('q') => return ViAction::Quit,
            Key::Char(':') => {
                self.mode = Mode::Command;
                self.entry = ":".into();
                self.msg.clear();
            }
            Key::Char('/') => {
                self.mode = Mode::Search;
                self.entry = "/".into();
                self.msg.clear();
            }
            Key::Esc => self.msg.clear(),
            // ---- editing, when the file can actually be written back --------
            Key::Char('i') if self.writable => self.enter_insert(false),
            Key::Char('a') if self.writable => self.enter_insert(true),
            Key::Char('I') if self.writable => {
                self.col = 0;
                self.enter_insert(false);
            }
            Key::Char('A') if self.writable => {
                self.col = self.line_len();
                self.enter_insert(false);
            }
            Key::Char('o') if self.writable => {
                let at = (self.cur + 1).min(self.lines.len());
                self.lines.insert(at, String::new());
                self.cur = at;
                self.col = 0;
                self.dirty = true;
                self.keep_in_view();
                self.enter_insert(false);
            }
            Key::Char('O') if self.writable => {
                let at = self.cur.min(self.lines.len());
                self.lines.insert(at, String::new());
                self.cur = at;
                self.col = 0;
                self.dirty = true;
                self.keep_in_view();
                self.enter_insert(false);
            }
            Key::Char('x') if self.writable => {
                if let Some(line) = self.lines.get_mut(self.cur) {
                    if self.col < line.len() {
                        line.remove(self.col);
                        self.dirty = true;
                    }
                }
            }
            Key::Char('d') if self.writable && g => {
                // `dd` — the one delete a config edit needs.
                if !self.lines.is_empty() {
                    self.lines.remove(self.cur.min(self.lines.len() - 1));
                    self.cur = self.cur.min(self.lines.len().saturating_sub(1));
                    self.col = 0;
                    self.dirty = true;
                    self.msg = "1 line deleted".into();
                }
            }
            Key::Char('d') if self.writable => self.pending_g = true,
            // Every mutating key on a read-only buffer: vi's own refusal, with
            // the reason when there is one — never a silent no-op.
            Key::Char(c) if "iIaAoOcCsSdDxXrRpPJu".contains(c) => self.msg = self.refusal(),
            Key::Backspace | Key::Delete => self.msg = self.refusal(),
            _ => {}
        }
        ViAction::Stay
    }

    fn entry_key(&mut self, k: Key) -> ViAction {
        match k {
            Key::Char(c) if !c.is_control() => {
                self.entry.push(c);
                ViAction::Stay
            }
            Key::Backspace => {
                self.entry.pop();
                if self.entry.is_empty() {
                    self.mode = Mode::Normal;
                }
                ViAction::Stay
            }
            Key::Esc => {
                self.entry.clear();
                self.mode = Mode::Normal;
                ViAction::Stay
            }
            Key::Enter => {
                let text = std::mem::take(&mut self.entry);
                let mode = self.mode;
                self.mode = Mode::Normal;
                match mode {
                    Mode::Search => {
                        self.last_search = text.trim_start_matches('/').to_string();
                        self.search_again(1);
                        ViAction::Stay
                    }
                    _ => self.command(text.trim_start_matches(':').trim()),
                }
            }
            _ => ViAction::Stay,
        }
    }

    /// Enter insert mode, optionally after the cursor (`a`).
    fn enter_insert(&mut self, after: bool) {
        if after {
            self.col = (self.col + 1).min(self.line_len());
        }
        self.mode = Mode::Insert;
        self.msg = "-- INSERT --".into();
    }

    fn command(&mut self, cmd: &str) -> ViAction {
        match cmd {
            // `:q` on an edited buffer refuses, the way vi does — losing an edit
            // silently is worse than an error.
            "q" | "quit" | "qa" if self.dirty => {
                self.msg = "E37: No write since last change (add ! to override)".into();
                ViAction::Stay
            }
            "q" | "q!" | "quit" | "qa" | "x" => ViAction::Quit,
            "set number" | "set nu" => {
                self.numbers = true;
                ViAction::Stay
            }
            "set nonumber" | "set nonu" => {
                self.numbers = false;
                ViAction::Stay
            }
            "$" => {
                self.goto(self.lines.len().saturating_sub(1));
                ViAction::Stay
            }
            "w" | "wq" | "w!" | "x!" | "wq!" if self.writable => {
                // The filesystem's ceiling is checked here, before a byte is
                // written: an ext4 file that cannot grow must refuse *now*, while
                // the operator still has the buffer, not after a partial write.
                let text = self.text();
                if let Some(max) = self.max_bytes {
                    if text.len() as u64 > max {
                        self.msg = format!(
                            "E212: {} bytes will not fit — {max} is the limit here ({})",
                            text.len(),
                            self.terms
                        );
                        return ViAction::Stay;
                    }
                }
                ViAction::Write {
                    text,
                    quit: matches!(cmd, "wq" | "x!" | "wq!"),
                }
            }
            "w" | "wq" | "w!" | "x!" | "wq!" => {
                self.msg = self.refusal();
                ViAction::Stay
            }
            other => {
                if let Ok(n) = other.parse::<usize>() {
                    self.goto(n.saturating_sub(1));
                } else {
                    self.msg = format!("E492: Not an editor command: {other}");
                }
                ViAction::Stay
            }
        }
    }

    fn search_again(&mut self, dir: i32) {
        if self.last_search.is_empty() {
            self.msg = "E35: No previous regular expression".into();
            return;
        }
        let n = self.lines.len();
        if n == 0 {
            return;
        }
        let needle = self.last_search.clone();
        for step in 1..=n {
            let idx = if dir >= 0 {
                (self.cur + step) % n
            } else {
                (self.cur + n - (step % n)) % n
            };
            if self.lines[idx].contains(&needle) {
                self.goto(idx);
                self.msg = format!("/{needle}");
                return;
            }
        }
        self.msg = format!("E486: Pattern not found: {needle}");
    }

    /// Scroll so the cursor line is visible, without moving the cursor.
    fn keep_in_view(&mut self) {
        let body = self.body();
        if self.cur < self.top {
            self.top = self.cur;
        } else if self.cur >= self.top + body {
            self.top = self.cur + 1 - body;
        }
    }

    fn goto(&mut self, line: usize) {
        if self.lines.is_empty() {
            return;
        }
        self.cur = line.min(self.lines.len() - 1);
        self.col = self.col.min(self.line_len());
        let body = self.body();
        if self.cur < self.top {
            self.top = self.cur;
        } else if self.cur >= self.top + body {
            self.top = self.cur + 1 - body;
        }
    }

    fn scroll_page(&mut self, pages: i32) {
        let body = self.body().max(2) - 1;
        let delta = pages * body as i32;
        let target = self.cur as i64 + i64::from(delta);
        self.goto(target.max(0) as usize);
        self.top = self
            .cur
            .saturating_sub(if pages > 0 { 0 } else { body.saturating_sub(1) });
        self.goto(self.cur);
    }

    fn line_len(&self) -> usize {
        self.lines
            .get(self.cur)
            .map(|l| l.chars().count().saturating_sub(1))
            .unwrap_or(0)
    }

    /// The visible frame: `rows` lines, status/command line last.
    pub fn render(&self) -> Vec<String> {
        let body = self.body();
        let width = if self.numbers {
            self.cols.saturating_sub(6)
        } else {
            self.cols
        };
        let mut out: Vec<String> = Vec::with_capacity(self.rows);
        for i in 0..body {
            let idx = self.top + i;
            match self.lines.get(idx) {
                Some(l) if self.numbers => {
                    out.push(truncate(&format!("{:>4}  {}", idx + 1, l), self.cols))
                }
                Some(l) => out.push(truncate(l, width)),
                // vi marks past-the-end rows with `~`.
                None => out.push("~".into()),
            }
        }
        out.push(truncate(&self.status(), self.cols));
        out
    }

    fn status(&self) -> String {
        if matches!(self.mode, Mode::Command | Mode::Search) {
            return self.entry.clone();
        }
        if !self.msg.is_empty() {
            return self.msg.clone();
        }
        let pct = if self.lines.len() <= self.body() {
            "All".to_string()
        } else if self.top == 0 {
            "Top".to_string()
        } else if self.top + self.body() >= self.lines.len() {
            "Bot".to_string()
        } else {
            format!("{}%", self.top * 100 / self.lines.len().max(1))
        };
        format!(
            "\"{}\" [readonly] {},{}  {}   :q to close",
            self.name,
            self.cur + 1,
            self.col + 1,
            pct
        )
    }
}

fn expand_tabs(s: &str) -> String {
    s.replace('\t', "    ")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn body(n: usize) -> String {
        (1..=n)
            .map(|i| format!("row {i}"))
            .collect::<Vec<_>>()
            .join("\n")
    }

    #[test]
    fn opens_readonly_with_status_and_tilde_rows() {
        let v = Vi::open("/config", "a\nb", 80, 10);
        let frame = v.render();
        assert_eq!(frame.len(), 10);
        assert_eq!(frame[0], "a");
        assert_eq!(frame[1], "b");
        assert_eq!(frame[2], "~", "past-the-end rows are vi tildes");
        assert!(frame[9].contains("readonly"), "{}", frame[9]);
        assert!(frame[9].contains("2L") || frame[9].contains("/config"));
    }

    #[test]
    fn motions_scroll_and_search() {
        let mut v = Vi::open("/log", &body(100), 80, 10);
        assert_eq!(v.key(Key::Char('G')), ViAction::Stay);
        assert!(v.render()[8].contains("row 100"));
        v.key(Key::Char('g'));
        v.key(Key::Char('g'));
        assert_eq!(v.render()[0], "row 1");
        v.key(Key::PageDown);
        assert_ne!(v.render()[0], "row 1");
        v.key(Key::Char('g'));
        v.key(Key::Char('g'));
        // `/row 42` then `n` wraps forward through the buffer.
        for c in "/row 42".chars() {
            v.key(Key::Char(c));
        }
        v.key(Key::Enter);
        assert!(
            v.render().iter().any(|l| l == "row 42"),
            "search should reveal the hit: {:?}",
            v.render()
        );
        for c in "/nope".chars() {
            v.key(Key::Char(c));
        }
        v.key(Key::Enter);
        assert!(v.render()[9].contains("E486"), "{}", v.render()[9]);
    }

    #[test]
    fn every_mutating_key_is_refused_read_only() {
        let mut v = Vi::open("/config", "{}", 80, 10);
        for c in ['i', 'a', 'o', 'x', 'd', 'p', 'u'] {
            v.key(Key::Char(c));
            assert!(
                v.render()[9].contains("readonly"),
                "key {c} must be refused: {}",
                v.render()[9]
            );
        }
        // `:w` too — the viewer has nothing to write.
        for c in ":w".chars() {
            v.key(Key::Char(c));
        }
        v.key(Key::Enter);
        assert!(v.render()[9].contains("readonly"));
        assert_eq!(v.key(Key::Char('q')), ViAction::Quit);
    }

    #[test]
    fn line_numbers_and_goto_line() {
        let mut v = Vi::open("/log", &body(30), 80, 10);
        for c in ":set number".chars() {
            v.key(Key::Char(c));
        }
        v.key(Key::Enter);
        assert!(
            v.render()[0].starts_with("   1  row 1"),
            "{:?}",
            v.render()[0]
        );
        for c in ":20".chars() {
            v.key(Key::Char(c));
        }
        v.key(Key::Enter);
        assert!(
            v.render().iter().any(|l| l.contains("  20  row 20")),
            "{:?}",
            v.render()
        );
        for c in ":bogus".chars() {
            v.key(Key::Char(c));
        }
        v.key(Key::Enter);
        assert!(v.render()[9].contains("E492"));
    }
}
