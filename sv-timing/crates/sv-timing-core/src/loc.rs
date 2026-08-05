// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Source location adapter: map parser offsets to file:line:column.
//!
//! Design prefers an **adapter** over deep-forking every syntax node (KD14).
//! Upstream leaf `Locate` is a byte offset into the preprocessed buffer; we
//! convert that to line/col via a line index built for each file.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// Whether the location maps back to original user source or expanded text.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum OriginKind {
    /// Original user `.sv` / package path.
    UserFile,
    /// Macro expansion region.
    ExpandedMacro,
    /// Text from an include expansion without a finer map.
    IncludeExpanded,
    /// Origin map missing; coordinates refer to the buffer we indexed.
    #[default]
    Unknown,
}

/// Precise source span for IR nodes and reports.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SourceLoc {
    /// Preferred path shown in reports (user path when known).
    pub file: String,
    /// 1-based start line.
    pub start_line: u32,
    /// 1-based start column.
    pub start_col: u32,
    /// 1-based end line (inclusive region end).
    pub end_line: u32,
    /// 1-based end column.
    pub end_col: u32,
    /// Byte offset start in the indexed buffer.
    pub byte_start: u32,
    /// Byte offset end (exclusive) in the indexed buffer.
    pub byte_end: u32,
    /// Origin classification.
    pub origin: OriginKind,
}

impl SourceLoc {
    /// Format as `file:line:col` (start).
    pub fn display(&self) -> String {
        format!("{}:{}:{}", self.file, self.start_line, self.start_col)
    }

    /// Zero-width location at the start of a file (fallback).
    pub fn file_start(path: impl AsRef<Path>) -> Self {
        let file = path.as_ref().to_string_lossy().into_owned();
        Self {
            file,
            start_line: 1,
            start_col: 1,
            end_line: 1,
            end_col: 1,
            byte_start: 0,
            byte_end: 0,
            origin: OriginKind::UserFile,
        }
    }
}

/// Line index over a UTF-8 buffer (byte offsets → line/col).
#[derive(Debug, Clone)]
pub struct LineIndex {
    /// Absolute path for display.
    pub path: PathBuf,
    /// Byte offset of the start of each 1-based line (index 0 unused / line 1 at [1]).
    line_starts: Vec<u32>,
    /// Total buffer length in bytes.
    len: u32,
}

impl LineIndex {
    /// Build a line index from file bytes (UTF-8 lossy is fine for offsets).
    pub fn from_bytes(path: impl Into<PathBuf>, bytes: &[u8]) -> Self {
        let mut line_starts = Vec::with_capacity(bytes.len() / 32 + 2);
        line_starts.push(0); // dummy so line 1 is at index 1
        line_starts.push(0); // line 1 starts at 0
        for (i, &b) in bytes.iter().enumerate() {
            if b == b'\n' {
                let next = (i + 1) as u32;
                line_starts.push(next);
            }
        }
        Self {
            path: path.into(),
            line_starts,
            len: bytes.len() as u32,
        }
    }

    /// Convert a byte offset into 1-based (line, col).
    pub fn line_col(&self, byte: u32) -> (u32, u32) {
        let byte = byte.min(self.len);
        // binary search last line_start <= byte
        let mut lo = 1usize;
        let mut hi = self.line_starts.len() - 1;
        while lo < hi {
            let mid = (lo + hi + 1) / 2;
            if self.line_starts[mid] <= byte {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }
        let line = lo as u32;
        let col = byte - self.line_starts[lo] + 1;
        (line, col)
    }

    /// Map a half-open byte span to [`SourceLoc`].
    pub fn span(&self, start: u32, end: u32, origin: OriginKind) -> SourceLoc {
        let start = start.min(self.len);
        let end = end.min(self.len).max(start);
        let (start_line, start_col) = self.line_col(start);
        let (end_line, end_col) = if end > start {
            self.line_col(end.saturating_sub(1))
        } else {
            (start_line, start_col)
        };
        let file = self.path.to_string_lossy().into_owned();
        SourceLoc {
            file,
            start_line,
            start_col,
            end_line,
            end_col,
            byte_start: start,
            byte_end: end,
            origin,
        }
    }

    /// Map a single offset (zero-width span).
    pub fn at(&self, byte: u32, origin: OriginKind) -> SourceLoc {
        self.span(byte, byte, origin)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn line_index_basic() {
        let text = b"abc\ndef\n\nghi";
        let idx = LineIndex::from_bytes("t.sv", text);
        assert_eq!(idx.line_col(0), (1, 1));
        assert_eq!(idx.line_col(3), (1, 4)); // '\n' of line 1
        assert_eq!(idx.line_col(4), (2, 1)); // 'd'
        assert_eq!(idx.line_col(8), (3, 1)); // empty line
        assert_eq!(idx.line_col(9), (4, 1)); // 'g'
        let loc = idx.span(4, 7, OriginKind::UserFile);
        assert_eq!(loc.start_line, 2);
        assert_eq!(loc.display(), "t.sv:2:1");
    }
}
