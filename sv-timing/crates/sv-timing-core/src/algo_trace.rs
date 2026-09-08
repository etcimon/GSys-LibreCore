// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// JSONL algorithm trace for timing-adjust diagnosis (not STA).

//! Streaming trace of path_class / relocation / correct-loop decisions.
//!
//! One JSON object per line. Disabled by default (no-op). Enable with
//! [`AlgoTrace::to_file`] / CLI `--trace-log`. See
//! `architecture/AUTO-CORRECT-CORE-API.md` §3.10.

use std::fs::{File, OpenOptions};
use std::io::{BufWriter, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Instant;

use serde::Serialize;
use serde_json::{Map, Value};

use crate::error::{CoreError, CoreResult};

/// One JSONL algorithm-trace event.
#[derive(Debug, Clone, Serialize)]
pub struct AlgoTraceEvent {
    /// Monotonic sequence in this run.
    pub seq: u64,
    /// Milliseconds since tracer construction.
    pub t_ms: u64,
    /// Event kind (`measure`, `scale`, `pass.start`, `apply`, `refuse`, …).
    pub kind: String,
    /// Correct-loop pass index (0 = pre-loop / analyze).
    pub pass: u32,
    /// Optional path id.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path_id: Option<u32>,
    /// Optional module name.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub module: Option<String>,
    /// Kind-specific fields.
    #[serde(flatten)]
    pub fields: Map<String, Value>,
}

struct AlgoTraceInner {
    writer: BufWriter<File>,
    path: PathBuf,
    seq: u64,
    start: Instant,
}

/// Optional JSONL sink for timing-algorithm decisions.
///
/// Cheap when disabled (`inner` is `None`).
pub struct AlgoTrace {
    inner: Option<Mutex<AlgoTraceInner>>,
}

impl std::fmt::Debug for AlgoTrace {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AlgoTrace")
            .field("enabled", &self.inner.is_some())
            .finish()
    }
}

impl Default for AlgoTrace {
    fn default() -> Self {
        Self::disabled()
    }
}

impl AlgoTrace {
    /// No-op tracer.
    pub fn disabled() -> Self {
        Self { inner: None }
    }

    /// Append JSONL to `path` (created/truncated).
    pub fn to_file(path: impl AsRef<Path>) -> CoreResult<Self> {
        let path = path.as_ref();
        if let Some(parent) = path.parent() {
            if !parent.as_os_str().is_empty() {
                std::fs::create_dir_all(parent).map_err(|source| CoreError::Io {
                    path: parent.to_path_buf(),
                    source,
                })?;
            }
        }
        let file = OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open(path)
            .map_err(|source| CoreError::Io {
                path: path.to_path_buf(),
                source,
            })?;
        Ok(Self {
            inner: Some(Mutex::new(AlgoTraceInner {
                writer: BufWriter::new(file),
                path: path.to_path_buf(),
                seq: 0,
                start: Instant::now(),
            })),
        })
    }

    /// Whether events are recorded.
    pub fn is_enabled(&self) -> bool {
        self.inner.is_some()
    }

    /// Path being written, if any.
    pub fn path(&self) -> Option<PathBuf> {
        self.inner
            .as_ref()
            .and_then(|m| m.lock().ok().map(|g| g.path.clone()))
    }

    /// Emit one event. No-op when disabled. Never panics on poison.
    pub fn emit(&self, kind: &str, pass: u32, fields: Map<String, Value>) {
        self.emit_full(kind, pass, None, None, fields);
    }

    /// Emit with path/module identity.
    pub fn emit_path(
        &self,
        kind: &str,
        pass: u32,
        path_id: Option<u32>,
        module: Option<String>,
        fields: Map<String, Value>,
    ) {
        self.emit_full(kind, pass, path_id, module, fields);
    }

    fn emit_full(
        &self,
        kind: &str,
        pass: u32,
        path_id: Option<u32>,
        module: Option<String>,
        fields: Map<String, Value>,
    ) {
        let Some(lock) = self.inner.as_ref() else {
            return;
        };
        let Ok(mut g) = lock.lock() else {
            return;
        };
        g.seq += 1;
        let ev = AlgoTraceEvent {
            seq: g.seq,
            t_ms: g.start.elapsed().as_millis() as u64,
            kind: kind.to_string(),
            pass,
            path_id,
            module,
            fields,
        };
        if let Ok(line) = serde_json::to_string(&ev) {
            let _ = writeln!(g.writer, "{line}");
            let _ = g.writer.flush();
        }
    }

    /// Convenience: object fields from an iterator of `(k, v)`.
    pub fn kv<I, K>(pairs: I) -> Map<String, Value>
    where
        I: IntoIterator<Item = (K, Value)>,
        K: Into<String>,
    {
        let mut m = Map::new();
        for (k, v) in pairs {
            m.insert(k.into(), v);
        }
        m
    }
}

impl Drop for AlgoTrace {
    fn drop(&mut self) {
        if let Some(lock) = self.inner.as_ref() {
            if let Ok(mut g) = lock.lock() {
                let _ = g.writer.flush();
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn disabled_is_silent() {
        let t = AlgoTrace::disabled();
        assert!(!t.is_enabled());
        t.emit("measure", 0, AlgoTrace::kv([("n", json!(1))]));
    }

    #[test]
    fn file_writes_jsonl() {
        let dir = std::env::temp_dir().join(format!(
            "svt-algo-trace-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("algo-trace.jsonl");
        {
            let t = AlgoTrace::to_file(&path).expect("create");
            assert!(t.is_enabled());
            t.emit(
                "run.start",
                0,
                AlgoTrace::kv([("target_mhz", json!(4000.0))]),
            );
            t.emit_path(
                "apply",
                1,
                Some(7),
                Some("alu".into()),
                AlgoTrace::kv([("kind", json!("balance_mux"))]),
            );
        }
        let text = std::fs::read_to_string(&path).expect("read");
        let lines: Vec<&str> = text.lines().filter(|l| !l.is_empty()).collect();
        assert_eq!(lines.len(), 2, "{text}");
        let v: Value = serde_json::from_str(lines[0]).unwrap();
        assert_eq!(v["kind"], "run.start");
        assert_eq!(v["target_mhz"], 4000.0);
        let v2: Value = serde_json::from_str(lines[1]).unwrap();
        assert_eq!(v2["path_id"], 7);
        assert_eq!(v2["module"], "alu");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
