// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Keyboard and (optional) pointer input.
//!
//! The primary source is a **USB keyboard**: the HID boot protocol is
//! translated to Linux `KEY_*` codes by the HID layer, and virtio-input
//! carries the very same codes (`g6b_asm::vio::VIO_KEY_*`, QEMU `sendkey`).
//! So the CLI decodes one alphabet — Linux keycodes — and works on a real USB
//! HID keyboard, on virtio-keyboard, and on the UART band alike.
//!
//! The pointer is optional (`kernel.cli.mouse`) and only ever scrolls the
//! container or places the caret; the CLI is keyboard-complete without it.

/// A decoded key press.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Key {
    Char(char),
    Enter,
    Backspace,
    Delete,
    Tab,
    Esc,
    Up,
    Down,
    Left,
    Right,
    Home,
    End,
    PageUp,
    PageDown,
    /// Function key 1..=12.
    Fn(u8),
}

/// Pointer event, only consumed when `kernel.cli.mouse` is compiled.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mouse {
    /// Wheel notches: positive scrolls the scrollback up (back in time).
    Wheel(i32),
    /// Primary press at a container cell.
    Press { col: u16, row: u16 },
}

/// Linux `KEY_*` codes the decoder understands. Kept as literals next to their
/// names so the table reads like `include/uapi/linux/input-event-codes.h`.
const KEY_ESC: u16 = 1;
const KEY_BACKSPACE: u16 = 14;
const KEY_TAB: u16 = 15;
const KEY_ENTER: u16 = 28;
const KEY_SPACE: u16 = 57;
const KEY_KPENTER: u16 = 96;
const KEY_HOME: u16 = 102;
const KEY_UP: u16 = 103;
const KEY_PAGEUP: u16 = 104;
const KEY_LEFT: u16 = 105;
const KEY_RIGHT: u16 = 106;
const KEY_END: u16 = 107;
const KEY_DOWN: u16 = 108;
const KEY_PAGEDOWN: u16 = 109;
const KEY_DELETE: u16 = 111;

/// Row-order US layout, unshifted then shifted, for the printable block.
const ROW_DIGITS: &[(u16, char, char)] = &[
    (2, '1', '!'),
    (3, '2', '@'),
    (4, '3', '#'),
    (5, '4', '$'),
    (6, '5', '%'),
    (7, '6', '^'),
    (8, '7', '&'),
    (9, '8', '*'),
    (10, '9', '('),
    (11, '0', ')'),
    (12, '-', '_'),
    (13, '=', '+'),
];

const ROW_Q: &[(u16, char)] = &[
    (16, 'q'),
    (17, 'w'),
    (18, 'e'),
    (19, 'r'),
    (20, 't'),
    (21, 'y'),
    (22, 'u'),
    (23, 'i'),
    (24, 'o'),
    (25, 'p'),
];

const ROW_A: &[(u16, char)] = &[
    (30, 'a'),
    (31, 's'),
    (32, 'd'),
    (33, 'f'),
    (34, 'g'),
    (35, 'h'),
    (36, 'j'),
    (37, 'k'),
    (38, 'l'),
];

const ROW_Z: &[(u16, char)] = &[
    (44, 'z'),
    (45, 'x'),
    (46, 'c'),
    (47, 'v'),
    (48, 'b'),
    (49, 'n'),
    (50, 'm'),
];

const PUNCT: &[(u16, char, char)] = &[
    (26, '[', '{'),
    (27, ']', '}'),
    (39, ';', ':'),
    (40, '\'', '"'),
    (41, '`', '~'),
    (43, '\\', '|'),
    (51, ',', '<'),
    (52, '.', '>'),
    (53, '/', '?'),
];

/// Decode one Linux keycode. `None` for codes with no CLI meaning (modifiers,
/// media keys, pointer buttons) — the caller drops them instead of guessing.
pub fn from_linux_keycode(code: u16, shift: bool) -> Option<Key> {
    match code {
        KEY_ESC => return Some(Key::Esc),
        KEY_BACKSPACE => return Some(Key::Backspace),
        KEY_TAB => return Some(Key::Tab),
        KEY_ENTER | KEY_KPENTER => return Some(Key::Enter),
        KEY_SPACE => return Some(Key::Char(' ')),
        KEY_HOME => return Some(Key::Home),
        KEY_UP => return Some(Key::Up),
        KEY_PAGEUP => return Some(Key::PageUp),
        KEY_LEFT => return Some(Key::Left),
        KEY_RIGHT => return Some(Key::Right),
        KEY_END => return Some(Key::End),
        KEY_DOWN => return Some(Key::Down),
        KEY_PAGEDOWN => return Some(Key::PageDown),
        KEY_DELETE => return Some(Key::Delete),
        59..=68 => return Some(Key::Fn((code - 58) as u8)),
        87 => return Some(Key::Fn(11)),
        88 => return Some(Key::Fn(12)),
        _ => {}
    }
    for (c, lo, hi) in ROW_DIGITS.iter().chain(PUNCT.iter()) {
        if *c == code {
            return Some(Key::Char(if shift { *hi } else { *lo }));
        }
    }
    for (c, ch) in ROW_Q.iter().chain(ROW_A.iter()).chain(ROW_Z.iter()) {
        if *c == code {
            return Some(Key::Char(if shift { ch.to_ascii_uppercase() } else { *ch }));
        }
    }
    None
}

/// Linux `KEY_LEFTSHIFT` / `KEY_RIGHTSHIFT` — the caller tracks the modifier.
pub fn is_shift_keycode(code: u16) -> bool {
    code == 42 || code == 54
}

/// The command line: one row of editable text plus a bounded history.
#[derive(Debug, Clone)]
pub struct Editor {
    buf: String,
    cursor: usize,
    history: Vec<String>,
    /// Position while walking history; `None` = editing a fresh line.
    walk: Option<usize>,
    max_history: usize,
    max_len: usize,
}

impl Default for Editor {
    fn default() -> Self {
        Self {
            buf: String::new(),
            cursor: 0,
            history: Vec::new(),
            walk: None,
            max_history: 64,
            max_len: 512,
        }
    }
}

/// What the container should do after one key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Edit {
    /// Nothing visible changed.
    Ignored,
    /// The line changed; repaint the prompt row.
    Changed,
    /// Enter: run this line.
    Submit(String),
    /// Scroll the container instead of editing.
    Scroll(i32),
    /// Page the container (±1 page).
    Page(i32),
}

impl Editor {
    pub fn line(&self) -> &str {
        &self.buf
    }

    pub fn cursor(&self) -> usize {
        self.cursor
    }

    pub fn history(&self) -> &[String] {
        &self.history
    }

    pub fn clear(&mut self) {
        self.buf.clear();
        self.cursor = 0;
        self.walk = None;
    }

    pub fn set(&mut self, text: &str) {
        self.buf = text.chars().take(self.max_len).collect();
        self.cursor = self.buf.chars().count();
    }

    pub fn key(&mut self, k: Key) -> Edit {
        match k {
            Key::Char(c) if !c.is_control() => {
                if self.buf.chars().count() >= self.max_len {
                    return Edit::Ignored;
                }
                let at = self.byte_at(self.cursor);
                self.buf.insert(at, c);
                self.cursor += 1;
                Edit::Changed
            }
            Key::Char(_) => Edit::Ignored,
            Key::Backspace => {
                if self.cursor == 0 {
                    return Edit::Ignored;
                }
                let from = self.byte_at(self.cursor - 1);
                let to = self.byte_at(self.cursor);
                self.buf.replace_range(from..to, "");
                self.cursor -= 1;
                Edit::Changed
            }
            Key::Delete => {
                let n = self.buf.chars().count();
                if self.cursor >= n {
                    return Edit::Ignored;
                }
                let from = self.byte_at(self.cursor);
                let to = self.byte_at(self.cursor + 1);
                self.buf.replace_range(from..to, "");
                Edit::Changed
            }
            Key::Left => {
                if self.cursor == 0 {
                    Edit::Ignored
                } else {
                    self.cursor -= 1;
                    Edit::Changed
                }
            }
            Key::Right => {
                if self.cursor >= self.buf.chars().count() {
                    Edit::Ignored
                } else {
                    self.cursor += 1;
                    Edit::Changed
                }
            }
            Key::Home => {
                self.cursor = 0;
                Edit::Changed
            }
            Key::End => {
                self.cursor = self.buf.chars().count();
                Edit::Changed
            }
            Key::Up => self.walk_history(-1),
            Key::Down => self.walk_history(1),
            Key::PageUp => Edit::Page(-1),
            Key::PageDown => Edit::Page(1),
            Key::Esc => {
                self.clear();
                Edit::Changed
            }
            Key::Enter => {
                let line = std::mem::take(&mut self.buf);
                self.cursor = 0;
                self.walk = None;
                let trimmed = line.trim();
                if !trimmed.is_empty() && self.history.last().map(String::as_str) != Some(trimmed) {
                    self.history.push(trimmed.to_string());
                    if self.history.len() > self.max_history {
                        self.history.remove(0);
                    }
                }
                Edit::Submit(line)
            }
            Key::Tab | Key::Fn(_) => Edit::Ignored,
        }
    }

    fn walk_history(&mut self, delta: i32) -> Edit {
        if self.history.is_empty() {
            return Edit::Ignored;
        }
        let last = self.history.len() - 1;
        let next = match (self.walk, delta) {
            (None, -1) => Some(last),
            (None, _) => None,
            (Some(0), -1) => Some(0),
            (Some(i), -1) => Some(i - 1),
            (Some(i), _) if i >= last => None,
            (Some(i), _) => Some(i + 1),
        };
        self.walk = next;
        match next {
            Some(i) => {
                let text = self.history[i].clone();
                self.set(&text);
                self.walk = Some(i);
                Edit::Changed
            }
            None => {
                self.clear();
                Edit::Changed
            }
        }
    }

    fn byte_at(&self, chars: usize) -> usize {
        self.buf
            .char_indices()
            .nth(chars)
            .map(|(i, _)| i)
            .unwrap_or(self.buf.len())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn usb_and_virtio_share_one_keycode_alphabet() {
        // QEMU `sendkey a` / `ret` / `down` — the same codes a USB HID
        // keyboard produces through the HID layer.
        assert_eq!(from_linux_keycode(30, false), Some(Key::Char('a')));
        assert_eq!(from_linux_keycode(30, true), Some(Key::Char('A')));
        assert_eq!(from_linux_keycode(28, false), Some(Key::Enter));
        assert_eq!(from_linux_keycode(108, false), Some(Key::Down));
        assert_eq!(from_linux_keycode(104, false), Some(Key::PageUp));
        assert_eq!(from_linux_keycode(2, true), Some(Key::Char('!')));
        assert_eq!(from_linux_keycode(53, false), Some(Key::Char('/')));
        assert_eq!(from_linux_keycode(59, false), Some(Key::Fn(1)));
        // Modifiers and pointer buttons are not keys.
        assert!(is_shift_keycode(42) && is_shift_keycode(54));
        assert_eq!(from_linux_keycode(42, false), None);
        assert_eq!(from_linux_keycode(0x110, false), None);
    }

    /// The guest container decodes the same alphabet from the same codes. If
    /// these drift, a key does one thing on the host CLI and another on the
    /// board — so the two tables are pinned to each other here.
    #[test]
    fn host_and_guest_keymaps_agree() {
        for code in 0u16..128 {
            let guest = g6b_asm::cli::keycode_ascii(code as u8);
            match from_linux_keycode(code, false) {
                Some(Key::Char(c)) if c.is_ascii() => assert_eq!(
                    guest, c as u8,
                    "keycode {code}: host types {c:?}, guest types {:?}",
                    guest as char
                ),
                // Control keys are commands in both places, not text.
                Some(_) | None => assert_eq!(
                    guest, 0,
                    "keycode {code} is not text on the host but the guest types {:?}",
                    guest as char
                ),
            }
        }
    }

    #[test]
    fn editor_edits_history_and_delegates_scrolling() {
        let mut e = Editor::default();
        for c in "Dir".chars() {
            assert_eq!(e.key(Key::Char(c)), Edit::Changed);
        }
        assert_eq!(e.line(), "Dir");
        assert_eq!(e.key(Key::Backspace), Edit::Changed);
        assert_eq!(e.line(), "Di");
        assert_eq!(e.key(Key::Home), Edit::Changed);
        assert_eq!(e.key(Key::Char('!')), Edit::Changed);
        assert_eq!(e.line(), "!Di");
        assert_eq!(e.key(Key::Enter), Edit::Submit("!Di".into()));
        assert_eq!(e.history(), ["!Di"]);
        assert_eq!(e.key(Key::Up), Edit::Changed);
        assert_eq!(e.line(), "!Di");
        assert_eq!(e.key(Key::Down), Edit::Changed);
        assert_eq!(e.line(), "");
        // Paging is the container's job, not the line's.
        assert_eq!(e.key(Key::PageUp), Edit::Page(-1));
        assert_eq!(e.key(Key::PageDown), Edit::Page(1));
    }
}
