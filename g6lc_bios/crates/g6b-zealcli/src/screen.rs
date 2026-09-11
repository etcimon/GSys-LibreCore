// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! The text container: a bounded scrollback ring, a viewport over it, and the
//! command prompt pinned to the **bottom row**.
//!
//! Geometry comes from `kernel.cli.rows` / `cols` (VGA text is 25×80), so the
//! container is the same object whether it is scanned onto the VGA plane, blitted
//! by `DomPaint`, or printed on the UART band. Output is always exactly `rows`
//! lines of at most `cols` columns — a fixed cell grid, never a reflowing
//! terminal — and the ring drops the oldest line instead of growing.

use std::collections::VecDeque;

/// Fixed-geometry scrollback container.
#[derive(Debug, Clone)]
pub struct Screen {
    cols: usize,
    rows: usize,
    limit: usize,
    lines: VecDeque<String>,
    /// `None` follows the tail; `Some(top)` is a frozen scroll position.
    view: Option<usize>,
    dropped: u64,
}

impl Screen {
    pub fn new(cols: usize, rows: usize, scrollback: usize) -> Self {
        let cols = cols.clamp(40, 200);
        let rows = rows.clamp(10, 60);
        Self {
            cols,
            rows,
            limit: scrollback.max(rows),
            lines: VecDeque::new(),
            view: None,
            dropped: 0,
        }
    }

    pub fn cols(&self) -> usize {
        self.cols
    }

    pub fn rows(&self) -> usize {
        self.rows
    }

    /// Rows available to output; the last row belongs to the prompt.
    pub fn body_rows(&self) -> usize {
        self.rows - 1
    }

    /// Lines currently held in the ring.
    pub fn len(&self) -> usize {
        self.lines.len()
    }

    pub fn is_empty(&self) -> bool {
        self.lines.is_empty()
    }

    /// Lines the ring has dropped since boot (an honest overflow count).
    pub fn dropped(&self) -> u64 {
        self.dropped
    }

    /// True when the viewport is following new output.
    pub fn at_tail(&self) -> bool {
        self.view.is_none()
    }

    pub fn clear(&mut self) {
        self.lines.clear();
        self.view = None;
    }

    /// Append text, wrapping at `cols` and honoring embedded newlines. New
    /// output snaps the viewport back to the tail: the operator should never
    /// miss a result because they were reading scrollback.
    pub fn push(&mut self, text: &str) {
        for line in text.split('\n') {
            for row in wrap(line, self.cols) {
                self.lines.push_back(row);
                if self.lines.len() > self.limit {
                    self.lines.pop_front();
                    self.dropped += 1;
                }
            }
        }
        self.view = None;
    }

    /// Scroll by whole lines: negative goes back in time, positive forward.
    /// Reaching the end re-attaches to the tail.
    pub fn scroll(&mut self, delta: i32) {
        if delta == 0 || self.lines.len() <= self.body_rows() {
            return;
        }
        let max_top = self.lines.len() - self.body_rows();
        let top = self.view.unwrap_or(max_top) as i64 + i64::from(delta);
        if top >= max_top as i64 {
            self.view = None;
        } else {
            self.view = Some(top.max(0) as usize);
        }
    }

    /// Scroll by pages (`body_rows` minus one line of overlap).
    pub fn page(&mut self, pages: i32) {
        let step = (self.body_rows().max(2) - 1) as i32;
        self.scroll(pages.saturating_mul(step));
    }

    pub fn to_top(&mut self) {
        if self.lines.len() > self.body_rows() {
            self.view = Some(0);
        }
    }

    pub fn to_tail(&mut self) {
        self.view = None;
    }

    /// The visible frame: `rows` lines, `prompt` always last.
    ///
    /// Content is **bottom-aligned**: a screen that is not full pads at the top,
    /// so the newest line always sits directly above the prompt instead of
    /// leaving a gap over it.
    pub fn render(&self, prompt: &str) -> Vec<String> {
        let body = self.body_rows();
        let top = match self.view {
            Some(t) => t,
            None => self.lines.len().saturating_sub(body),
        };
        let visible: Vec<String> = self
            .lines
            .iter()
            .skip(top)
            .take(body)
            .map(|l| truncate(l, self.cols))
            .collect();
        let mut out: Vec<String> = vec![String::new(); body.saturating_sub(visible.len())];
        out.extend(visible);
        // Scrolled back: the last body row states it, so the frame is never
        // mistaken for live output.
        if let Some(t) = self.view {
            let end = (t + body).min(self.lines.len());
            out[body - 1] = truncate(
                &format!(
                    "-- scrollback {}-{} of {} (PgDn/End) --",
                    t + 1,
                    end,
                    self.lines.len()
                ),
                self.cols,
            );
        }
        out.push(truncate(prompt, self.cols));
        out
    }

    /// The frame as text, one `\n`-separated block (the VGA text face).
    pub fn text(&self, prompt: &str) -> String {
        self.render(prompt).join("\n")
    }

    /// Re-geometry (a `set cli_rows`/`cli_cols` write). Content is re-wrapped
    /// from the ring, so nothing is lost and nothing is reflowed twice.
    pub fn resize(&mut self, cols: usize, rows: usize) {
        let cols = cols.clamp(40, 200);
        let rows = rows.clamp(10, 60);
        if cols == self.cols && rows == self.rows {
            return;
        }
        let old: Vec<String> = self.lines.drain(..).collect();
        self.cols = cols;
        self.rows = rows;
        self.limit = self.limit.max(rows);
        self.view = None;
        for line in old {
            for row in wrap(&line, self.cols) {
                self.lines.push_back(row);
                if self.lines.len() > self.limit {
                    self.lines.pop_front();
                    self.dropped += 1;
                }
            }
        }
    }
}

/// Hard wrap at `cols` cells. An empty line stays one row.
pub fn wrap(s: &str, cols: usize) -> Vec<String> {
    if s.is_empty() {
        return vec![String::new()];
    }
    let chars: Vec<char> = s.chars().collect();
    chars
        .chunks(cols.max(1))
        .map(|c| c.iter().collect())
        .collect()
}

/// Cut at `cols` cells (no ellipsis: a cell grid has no room to lie).
pub fn truncate(s: &str, cols: usize) -> String {
    s.chars().take(cols).collect()
}

/// Wrap on word boundaries, falling back to a hard cut for a word longer than
/// the line. Used for prose (the manual); output rows use [`wrap`].
pub fn wrap_words(s: &str, cols: usize) -> Vec<String> {
    let cols = cols.max(1);
    if s.trim().is_empty() {
        return vec![s.to_string()];
    }
    // Leading indentation is part of the layout, so it is preserved on the
    // first row and dropped on continuations.
    let indent: String = s.chars().take_while(|c| *c == ' ').collect();
    let mut out: Vec<String> = Vec::new();
    let mut line = indent.clone();
    for word in s.split_whitespace() {
        let room = cols.saturating_sub(line.chars().count());
        let need = word.chars().count() + usize::from(!line.trim().is_empty());
        if need > room && !line.trim().is_empty() {
            out.push(line);
            line = indent.clone();
        }
        if word.chars().count() > cols {
            for chunk in wrap(word, cols) {
                if !line.trim().is_empty() {
                    out.push(std::mem::take(&mut line));
                }
                out.push(chunk);
            }
            continue;
        }
        if !line.trim().is_empty() {
            line.push(' ');
        }
        line.push_str(word);
    }
    if !line.trim().is_empty() {
        out.push(line);
    }
    if out.is_empty() {
        out.push(String::new());
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frame_is_fixed_geometry_with_the_prompt_last() {
        let mut s = Screen::new(80, 25, 512);
        for i in 0..100 {
            s.push(&format!("line{i}"));
        }
        let frame = s.render("/>");
        assert_eq!(frame.len(), 25);
        assert!(frame.iter().all(|l| l.chars().count() <= 80));
        assert_eq!(frame[24], "/>", "prompt owns the bottom row");
        assert_eq!(frame[23], "line99", "newest output sits above the prompt");
    }

    #[test]
    fn scrolling_freezes_then_re_attaches() {
        let mut s = Screen::new(80, 25, 512);
        for i in 0..100 {
            s.push(&format!("line{i}"));
        }
        assert!(s.at_tail());
        s.page(-1);
        assert!(!s.at_tail());
        let frame = s.render("/>");
        assert_eq!(frame.len(), 25);
        assert_eq!(frame[24], "/>", "prompt stays at the bottom while scrolled");
        assert!(frame[23].contains("scrollback"), "{:?}", frame[23]);
        assert!(frame[0].starts_with("line"));
        s.to_top();
        assert_eq!(s.render("/>")[0], "line0");
        for _ in 0..8 {
            s.page(1);
        }
        assert!(s.at_tail(), "paging past the end re-attaches");
        // New output always snaps back to live.
        s.page(-2);
        s.push("fresh");
        assert!(s.at_tail());
        assert_eq!(s.render("/>")[23], "fresh");
    }

    #[test]
    fn ring_drops_oldest_and_counts_it() {
        let mut s = Screen::new(40, 10, 12);
        for i in 0..30 {
            s.push(&format!("l{i}"));
        }
        assert_eq!(s.len(), 12);
        assert_eq!(s.dropped(), 18);
        assert_eq!(s.render(">")[8], "l29");
    }

    #[test]
    fn long_lines_wrap_to_cells_and_resize_rewraps() {
        let mut s = Screen::new(40, 10, 64);
        s.push(&"x".repeat(95));
        assert_eq!(s.len(), 3, "95 cells is three 40-cell rows");
        // Resize re-wraps the rows it holds; it does not rejoin them, because
        // the ring stores display rows and cannot know which were one logical
        // line. Every row still fits the new width.
        s.resize(80, 25);
        assert_eq!(s.cols(), 80);
        assert!(s.render(">").iter().all(|l| l.chars().count() <= 80));
        assert_eq!(s.render(">").len(), 25);
        let mut narrow = Screen::new(80, 10, 64);
        narrow.push(&"y".repeat(95));
        assert_eq!(narrow.len(), 2);
        narrow.resize(40, 10);
        assert_eq!(narrow.len(), 3, "80+15 cells re-wrap to 40+40+15");
    }

    #[test]
    fn prose_wraps_on_word_boundaries() {
        let rows = wrap_words("the quick brown fox jumps over the lazy dog", 16);
        assert!(rows.iter().all(|r| r.chars().count() <= 16), "{rows:?}");
        assert!(rows.iter().all(|r| !r.starts_with(' ')), "{rows:?}");
        assert_eq!(rows[0], "the quick brown");
        // A word longer than the line still has to be cut somewhere.
        let long = wrap_words("prefix supercalifragilistic", 10);
        assert!(long.iter().all(|r| r.chars().count() <= 10), "{long:?}");
        assert!(long.join(" ").contains("supercalif"));
        // Indentation survives on the first row.
        let indented = wrap_words("    two words here", 12);
        assert!(indented[0].starts_with("    "), "{indented:?}");
    }
}
