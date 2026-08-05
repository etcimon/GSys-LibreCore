// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// SQLite-backed IR-only cache (no CST blobs).

//! SQLite store matching `architecture/DESIGN.md` § Cache design (schema v1).

use std::path::{Path, PathBuf};

use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use sv_timing_core::{
    CoreError, CoreResult, TimingModule, TimingPath, IR_VERSION, PARSER_PIN_HINT,
};

use crate::crc::{FileDigest, CRC_ALGO};
use crate::fingerprint::{module_crc_set, pp_fingerprint};

/// Cache schema version (meta.schema_version).
pub const CACHE_SCHEMA_VERSION: &str = "1";

/// Cached module payload (IR + paths belonging to that module).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModuleIrBlob {
    /// Module IR (nodes, regions, costs).
    pub module: TimingModule,
    /// Paths extracted for this module at lower time.
    pub paths: Vec<TimingPath>,
}

/// Configuration for opening a cache DB.
#[derive(Debug, Clone)]
pub struct CacheConfig {
    /// SQLite database file path.
    pub db_path: PathBuf,
    /// Retention: keep last N analyze runs.
    pub keep_last_n: u32,
}

impl CacheConfig {
    /// Default path under `./.sv-timing-cache/ir.sqlite`.
    pub fn default_path() -> PathBuf {
        PathBuf::from(".sv-timing-cache").join("ir.sqlite")
    }

    /// Config with default path and keep=10.
    pub fn new() -> Self {
        Self {
            db_path: Self::default_path(),
            keep_last_n: 10,
        }
    }

    /// Config for an explicit DB path.
    pub fn at(path: impl Into<PathBuf>) -> Self {
        Self {
            db_path: path.into(),
            keep_last_n: 10,
        }
    }
}

impl Default for CacheConfig {
    fn default() -> Self {
        Self::new()
    }
}

/// Open SQLite timing IR cache.
pub struct TimingCache {
    conn: Connection,
    config: CacheConfig,
}

/// Stats for one analyze-with-cache invocation.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct CacheStats {
    /// Module IR hits.
    pub module_hits: u32,
    /// Module IR misses (forced full rebuild path when any miss).
    pub module_misses: u32,
    /// Design-level short-circuit hit (no parse).
    pub design_hit: bool,
    /// Files whose CRC matched a prior row.
    pub files_content_stable: u32,
    /// Files new or CRC-changed.
    pub files_changed: u32,
    /// pp_fingerprint used.
    pub pp_fingerprint: String,
    /// Design cache key (if computed).
    pub design_key: String,
}

impl TimingCache {
    /// Open or create the database at `config.db_path`.
    pub fn open(config: CacheConfig) -> CoreResult<Self> {
        if let Some(parent) = config.db_path.parent() {
            std::fs::create_dir_all(parent).map_err(|source| CoreError::Io {
                path: parent.to_path_buf(),
                source,
            })?;
        }
        let conn = Connection::open(&config.db_path).map_err(map_sql)?;
        let cache = Self { conn, config };
        cache.init_schema()?;
        Ok(cache)
    }

    /// Database path.
    pub fn path(&self) -> &Path {
        &self.config.db_path
    }

    /// Keep policy.
    pub fn keep_last_n(&self) -> u32 {
        self.config.keep_last_n
    }

    fn init_schema(&self) -> CoreResult<()> {
        self.conn
            .execute_batch(
                r#"
CREATE TABLE IF NOT EXISTS meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS files (
  path TEXT NOT NULL,
  crc TEXT NOT NULL,
  size INTEGER NOT NULL,
  mtime_ns INTEGER,
  pp_fingerprint TEXT NOT NULL,
  parser_version TEXT NOT NULL,
  parsed_at TEXT NOT NULL,
  PRIMARY KEY (path, pp_fingerprint, parser_version)
);
CREATE TABLE IF NOT EXISTS file_modules (
  path TEXT NOT NULL,
  module_name TEXT NOT NULL,
  PRIMARY KEY (path, module_name)
);
CREATE TABLE IF NOT EXISTS modules (
  module_name TEXT NOT NULL,
  file_path TEXT NOT NULL,
  crc_set TEXT NOT NULL,
  ir_blob BLOB NOT NULL,
  ir_version TEXT NOT NULL,
  PRIMARY KEY (module_name, crc_set, ir_version)
);
CREATE TABLE IF NOT EXISTS module_deps (
  module_name TEXT NOT NULL,
  depends_on TEXT NOT NULL,
  PRIMARY KEY (module_name, depends_on)
);
CREATE TABLE IF NOT EXISTS paths (
  path_id TEXT NOT NULL,
  module_name TEXT,
  start_json TEXT NOT NULL,
  end_json TEXT NOT NULL,
  total_fo4 REAL NOT NULL,
  slack_fo4 REAL NOT NULL,
  primary_loc TEXT NOT NULL,
  multi_cycle INTEGER NOT NULL DEFAULT 0,
  run_id TEXT NOT NULL,
  PRIMARY KEY (path_id, run_id)
);
CREATE TABLE IF NOT EXISTS reports (
  run_id TEXT PRIMARY KEY,
  created_at TEXT NOT NULL,
  target_mhz REAL NOT NULL,
  fo4_ps REAL NOT NULL,
  report_json BLOB,
  config_fingerprint TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS runs (
  run_id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  started_at TEXT,
  finished_at TEXT,
  status TEXT,
  modules_json TEXT
);
CREATE TABLE IF NOT EXISTS designs (
  design_key TEXT NOT NULL,
  ir_version TEXT NOT NULL,
  cost_model TEXT NOT NULL,
  design_blob BLOB NOT NULL,
  stored_at TEXT NOT NULL,
  PRIMARY KEY (design_key, ir_version, cost_model)
);
CREATE TABLE IF NOT EXISTS path_class (
  design_key TEXT NOT NULL,
  path_id INTEGER NOT NULL,
  module_name TEXT NOT NULL,
  signature TEXT NOT NULL,
  path_class TEXT NOT NULL,
  raw_fo4 REAL NOT NULL,
  adjusted_fo4 REAL NOT NULL,
  confidence REAL NOT NULL,
  evidence TEXT NOT NULL,
  attempted_json TEXT NOT NULL,
  stored_at TEXT NOT NULL,
  PRIMARY KEY (design_key, path_id)
);
CREATE INDEX IF NOT EXISTS idx_path_class_sig ON path_class(signature);
CREATE INDEX IF NOT EXISTS idx_path_class_module ON path_class(module_name, path_class);
CREATE TABLE IF NOT EXISTS module_path_profile (
  design_key TEXT NOT NULL,
  module_name TEXT NOT NULL,
  n_paths INTEGER NOT NULL,
  n_exclusive INTEGER NOT NULL,
  n_atomic INTEGER NOT NULL,
  n_plain INTEGER NOT NULL,
  n_under_budget INTEGER NOT NULL,
  max_raw_fo4 REAL NOT NULL,
  max_adjusted_fo4 REAL NOT NULL,
  summary_json TEXT NOT NULL,
  stored_at TEXT NOT NULL,
  PRIMARY KEY (design_key, module_name)
);
CREATE INDEX IF NOT EXISTS idx_files_crc ON files(crc);
CREATE INDEX IF NOT EXISTS idx_file_modules_module ON file_modules(module_name);
CREATE INDEX IF NOT EXISTS idx_paths_run ON paths(run_id);
"#,
            )
            .map_err(map_sql)?;

        self.meta_set("schema_version", CACHE_SCHEMA_VERSION)?;
        self.meta_set("ir_version", IR_VERSION)?;
        self.meta_set("parser_version", PARSER_PIN_HINT)?;
        self.meta_set("crc_algo", CRC_ALGO)?;
        self.meta_set(
            "keep_last_n_runs",
            &self.config.keep_last_n.to_string(),
        )?;
        if self.meta_get("created_at")?.is_none() {
            self.meta_set("created_at", &now_rfc3339())?;
        }
        self.meta_set("last_opened_at", &now_rfc3339())?;
        Ok(())
    }

    /// Read meta key.
    pub fn meta_get(&self, key: &str) -> CoreResult<Option<String>> {
        self.conn
            .query_row(
                "SELECT value FROM meta WHERE key = ?1",
                params![key],
                |row| row.get(0),
            )
            .optional()
            .map_err(map_sql)
    }

    /// Write meta key.
    pub fn meta_set(&self, key: &str, value: &str) -> CoreResult<()> {
        self.conn
            .execute(
                "INSERT INTO meta(key, value) VALUES(?1, ?2)
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                params![key, value],
            )
            .map_err(map_sql)?;
        Ok(())
    }

    /// Reconcile file digests against `files` table; update stats.
    pub fn reconcile_files(
        &self,
        digests: &[FileDigest],
        pp_fp: &str,
        stats: &mut CacheStats,
    ) -> CoreResult<()> {
        for d in digests {
            let existing: Option<String> = self
                .conn
                .query_row(
                    "SELECT crc FROM files WHERE path = ?1 AND pp_fingerprint = ?2 AND parser_version = ?3",
                    params![d.path, pp_fp, PARSER_PIN_HINT],
                    |row| row.get(0),
                )
                .optional()
                .map_err(map_sql)?;
            match existing {
                Some(crc) if crc == d.crc => stats.files_content_stable += 1,
                Some(_) => {
                    stats.files_changed += 1;
                    self.conn
                        .execute(
                            "DELETE FROM files WHERE path = ?1 AND pp_fingerprint = ?2 AND parser_version = ?3",
                            params![d.path, pp_fp, PARSER_PIN_HINT],
                        )
                        .map_err(map_sql)?;
                }
                None => stats.files_changed += 1,
            }
        }
        Ok(())
    }

    /// Upsert file metadata rows after a successful analyze.
    pub fn upsert_files(&self, digests: &[FileDigest], pp_fp: &str) -> CoreResult<()> {
        let now = now_rfc3339();
        for d in digests {
            self.conn
                .execute(
                    "INSERT INTO files(path, crc, size, mtime_ns, pp_fingerprint, parser_version, parsed_at)
                     VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)
                     ON CONFLICT(path, pp_fingerprint, parser_version) DO UPDATE SET
                       crc = excluded.crc,
                       size = excluded.size,
                       mtime_ns = excluded.mtime_ns,
                       parsed_at = excluded.parsed_at",
                    params![
                        d.path,
                        d.crc,
                        d.size as i64,
                        d.mtime_ns,
                        pp_fp,
                        PARSER_PIN_HINT,
                        now
                    ],
                )
                .map_err(map_sql)?;
        }
        Ok(())
    }

    /// Rebuild file_modules for a path list (delete then insert).
    pub fn replace_file_modules(&self, pairs: &[(String, String)]) -> CoreResult<()> {
        // pairs: (path, module_name)
        let paths: std::collections::BTreeSet<&str> =
            pairs.iter().map(|(p, _)| p.as_str()).collect();
        for p in paths {
            self.conn
                .execute("DELETE FROM file_modules WHERE path = ?1", params![p])
                .map_err(map_sql)?;
        }
        for (path, module) in pairs {
            self.conn
                .execute(
                    "INSERT OR IGNORE INTO file_modules(path, module_name) VALUES(?1, ?2)",
                    params![path, module],
                )
                .map_err(map_sql)?;
        }
        Ok(())
    }

    /// List `(path, module_name)` rows for paths in the current analyze set.
    pub fn list_file_modules_for_paths(
        &self,
        paths: &[String],
    ) -> CoreResult<Vec<(String, String)>> {
        if paths.is_empty() {
            return Ok(Vec::new());
        }
        let mut out = Vec::new();
        for p in paths {
            let mut stmt = self
                .conn
                .prepare("SELECT path, module_name FROM file_modules WHERE path = ?1")
                .map_err(map_sql)?;
            let rows = stmt
                .query_map(params![p], |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
                })
                .map_err(map_sql)?;
            for r in rows {
                out.push(r.map_err(map_sql)?);
            }
        }
        Ok(out)
    }

    /// Known primary definition file for a module (latest stored row).
    pub fn module_primary_file(&self, module_name: &str) -> CoreResult<Option<String>> {
        self.conn
            .query_row(
                "SELECT file_path FROM modules WHERE module_name = ?1 LIMIT 1",
                params![module_name],
                |row| row.get(0),
            )
            .optional()
            .map_err(map_sql)
    }

    /// Lookup module IR by name + crc_set.
    pub fn get_module(
        &self,
        module_name: &str,
        crc_set: &str,
    ) -> CoreResult<Option<ModuleIrBlob>> {
        let blob: Option<Vec<u8>> = self
            .conn
            .query_row(
                "SELECT ir_blob FROM modules WHERE module_name = ?1 AND crc_set = ?2 AND ir_version = ?3",
                params![module_name, crc_set, IR_VERSION],
                |row| row.get(0),
            )
            .optional()
            .map_err(map_sql)?;
        match blob {
            None => Ok(None),
            Some(b) => {
                let m: ModuleIrBlob =
                    serde_json::from_slice(&b).map_err(|e| CoreError::InvalidOptions(e.to_string()))?;
                Ok(Some(m))
            }
        }
    }

    /// Store module IR.
    pub fn put_module(
        &self,
        module_name: &str,
        file_path: &str,
        crc_set: &str,
        blob: &ModuleIrBlob,
    ) -> CoreResult<()> {
        let bytes =
            serde_json::to_vec(blob).map_err(|e| CoreError::InvalidOptions(e.to_string()))?;
        self.conn
            .execute(
                "INSERT INTO modules(module_name, file_path, crc_set, ir_blob, ir_version)
                 VALUES(?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(module_name, crc_set, ir_version) DO UPDATE SET
                   file_path = excluded.file_path,
                   ir_blob = excluded.ir_blob",
                params![module_name, file_path, crc_set, bytes, IR_VERSION],
            )
            .map_err(map_sql)?;
        Ok(())
    }

    /// Full design blob (short-circuit when all inputs unchanged).
    pub fn get_design(
        &self,
        design_key: &str,
        cost_model: &str,
    ) -> CoreResult<Option<sv_timing_core::TimingDesign>> {
        let blob: Option<Vec<u8>> = self
            .conn
            .query_row(
                "SELECT design_blob FROM designs WHERE design_key = ?1 AND ir_version = ?2 AND cost_model = ?3",
                params![design_key, IR_VERSION, cost_model],
                |row| row.get(0),
            )
            .optional()
            .map_err(map_sql)?;
        match blob {
            None => Ok(None),
            Some(b) => {
                let d = serde_json::from_slice(&b)
                    .map_err(|e| CoreError::InvalidOptions(e.to_string()))?;
                Ok(Some(d))
            }
        }
    }

    /// Store design blob and denormalized path_class / module profiles.
    pub fn put_design(
        &self,
        design_key: &str,
        cost_model: &str,
        design: &sv_timing_core::TimingDesign,
    ) -> CoreResult<()> {
        let bytes =
            serde_json::to_vec(design).map_err(|e| CoreError::InvalidOptions(e.to_string()))?;
        self.conn
            .execute(
                "INSERT INTO designs(design_key, ir_version, cost_model, design_blob, stored_at)
                 VALUES(?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(design_key, ir_version, cost_model) DO UPDATE SET
                   design_blob = excluded.design_blob,
                   stored_at = excluded.stored_at",
                params![design_key, IR_VERSION, cost_model, bytes, now_rfc3339()],
            )
            .map_err(map_sql)?;
        self.put_path_classes(design_key, design)?;
        Ok(())
    }

    /// Persist path exceptions for cache-assisted reclassify / algorithm short-circuit.
    pub fn put_path_classes(
        &self,
        design_key: &str,
        design: &sv_timing_core::TimingDesign,
    ) -> CoreResult<()> {
        let now = now_rfc3339();
        self.conn
            .execute(
                "DELETE FROM path_class WHERE design_key = ?1",
                params![design_key],
            )
            .map_err(map_sql)?;
        self.conn
            .execute(
                "DELETE FROM module_path_profile WHERE design_key = ?1",
                params![design_key],
            )
            .map_err(map_sql)?;

        for ex in &design.path_exceptions {
            let attempted = serde_json::to_string(&ex.attempted).unwrap_or_else(|_| "[]".into());
            let class = format!("{:?}", ex.path_class);
            self.conn
                .execute(
                    "INSERT INTO path_class(
                       design_key, path_id, module_name, signature, path_class,
                       raw_fo4, adjusted_fo4, confidence, evidence, attempted_json, stored_at)
                     VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)",
                    params![
                        design_key,
                        ex.path_id as i64,
                        ex.module_name,
                        ex.signature,
                        class,
                        ex.raw_fo4,
                        ex.adjusted_fo4,
                        ex.confidence,
                        ex.evidence,
                        attempted,
                        now,
                    ],
                )
                .map_err(map_sql)?;
        }

        // Module profiles — simplify later passes (which modules need exclusive/atomic care).
        use std::collections::BTreeMap;
        let mut per_mod: BTreeMap<String, (u32, u32, u32, u32, u32, f64, f64)> = BTreeMap::new();
        for ex in &design.path_exceptions {
            let e = per_mod
                .entry(ex.module_name.clone())
                .or_insert((0, 0, 0, 0, 0, 0.0, 0.0));
            e.0 += 1;
            match ex.path_class {
                sv_timing_core::PathClassKind::ExclusiveCaseMux
                | sv_timing_core::PathClassKind::ExclusiveIfChain
                | sv_timing_core::PathClassKind::IndependentLhsBundle
                | sv_timing_core::PathClassKind::DenseControlCone => e.1 += 1,
                sv_timing_core::PathClassKind::AtomicOverBudget => e.2 += 1,
                sv_timing_core::PathClassKind::Plain => e.3 += 1,
                sv_timing_core::PathClassKind::UnderBudget => e.4 += 1,
                _ => {}
            }
            e.5 = e.5.max(ex.raw_fo4);
            e.6 = e.6.max(ex.adjusted_fo4);
        }
        let summary = sv_timing_core::path_class_summary(design);
        let summary_json =
            serde_json::to_string(&summary).unwrap_or_else(|_| "{}".into());
        for (mod_name, (n, n_ex, n_at, n_pl, n_ub, max_r, max_a)) in per_mod {
            self.conn
                .execute(
                    "INSERT INTO module_path_profile(
                       design_key, module_name, n_paths, n_exclusive, n_atomic, n_plain,
                       n_under_budget, max_raw_fo4, max_adjusted_fo4, summary_json, stored_at)
                     VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)",
                    params![
                        design_key,
                        mod_name,
                        n as i64,
                        n_ex as i64,
                        n_at as i64,
                        n_pl as i64,
                        n_ub as i64,
                        max_r,
                        max_a,
                        summary_json,
                        now,
                    ],
                )
                .map_err(map_sql)?;
        }
        Ok(())
    }

    /// Load path-class hints by signature (any design_key or exact).
    pub fn get_path_class_hints(
        &self,
        design_key: &str,
    ) -> CoreResult<std::collections::BTreeMap<String, sv_timing_core::PathClassHint>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT signature, path_class, raw_fo4, adjusted_fo4, confidence, evidence
                 FROM path_class WHERE design_key = ?1",
            )
            .map_err(map_sql)?;
        let rows = stmt
            .query_map(params![design_key], |row| {
                let signature: String = row.get(0)?;
                let class_s: String = row.get(1)?;
                let path_class = parse_path_class(&class_s);
                Ok((
                    signature.clone(),
                    sv_timing_core::PathClassHint {
                        signature,
                        path_class,
                        raw_fo4: row.get(2)?,
                        adjusted_fo4: row.get(3)?,
                        confidence: row.get(4)?,
                        evidence: row.get(5)?,
                    },
                ))
            })
            .map_err(map_sql)?;
        let mut map = std::collections::BTreeMap::new();
        for r in rows {
            let (k, v) = r.map_err(map_sql)?;
            if !k.is_empty() {
                map.insert(k, v);
            }
        }
        Ok(map)
    }

    /// True if module profile says only under-budget/plain paths (skip exclusive pipeline).
    pub fn module_is_simple(&self, design_key: &str, module_name: &str) -> CoreResult<bool> {
        let row: Option<(i64, i64)> = self
            .conn
            .query_row(
                "SELECT n_exclusive, n_atomic FROM module_path_profile
                 WHERE design_key = ?1 AND module_name = ?2",
                params![design_key, module_name],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()
            .map_err(map_sql)?;
        Ok(match row {
            Some((ex, at)) => ex == 0 && at == 0,
            None => false,
        })
    }

    /// Record a run and optionally prune.
    pub fn record_run(
        &self,
        run_id: &str,
        kind: &str,
        status: &str,
        modules: &[String],
    ) -> CoreResult<()> {
        let mods = serde_json::to_string(modules).unwrap_or_else(|_| "[]".into());
        let now = now_rfc3339();
        self.conn
            .execute(
                "INSERT INTO runs(run_id, kind, started_at, finished_at, status, modules_json)
                 VALUES(?1, ?2, ?3, ?4, ?5, ?6)
                 ON CONFLICT(run_id) DO UPDATE SET
                   finished_at = excluded.finished_at,
                   status = excluded.status,
                   modules_json = excluded.modules_json",
                params![run_id, kind, now, now, status, mods],
            )
            .map_err(map_sql)?;
        self.prune_runs()?;
        Ok(())
    }

    /// Delete older runs beyond keep_last_n (and their paths/reports).
    pub fn prune_runs(&self) -> CoreResult<()> {
        let n = self.config.keep_last_n as i64;
        let old: Vec<String> = {
            let mut stmt = self
                .conn
                .prepare(
                    "SELECT run_id FROM runs ORDER BY finished_at DESC LIMIT -1 OFFSET ?1",
                )
                .map_err(map_sql)?;
            let rows = stmt
                .query_map(params![n], |row| row.get(0))
                .map_err(map_sql)?;
            let mut v = Vec::new();
            for r in rows {
                v.push(r.map_err(map_sql)?);
            }
            v
        };
        for id in old {
            self.conn
                .execute("DELETE FROM paths WHERE run_id = ?1", params![id])
                .map_err(map_sql)?;
            self.conn
                .execute("DELETE FROM reports WHERE run_id = ?1", params![id])
                .map_err(map_sql)?;
            self.conn
                .execute("DELETE FROM runs WHERE run_id = ?1", params![id])
                .map_err(map_sql)?;
        }
        Ok(())
    }

    /// Count rows for status.
    pub fn counts(&self) -> CoreResult<CacheCounts> {
        Ok(CacheCounts {
            files: self.count("files")?,
            modules: self.count("modules")?,
            designs: self.count("designs")?,
            runs: self.count("runs")?,
        })
    }

    fn count(&self, table: &str) -> CoreResult<u64> {
        // table names are internal only
        let q = format!("SELECT COUNT(*) FROM {table}");
        let n: i64 = self.conn.query_row(&q, [], |row| row.get(0)).map_err(map_sql)?;
        Ok(n as u64)
    }
}

/// Row counts for status.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CacheCounts {
    /// files table.
    pub files: u64,
    /// modules table.
    pub modules: u64,
    /// designs table.
    pub designs: u64,
    /// runs table.
    pub runs: u64,
}

/// Build pp fingerprint helpers for callers.
pub fn compute_pp_fingerprint(
    digests: &[FileDigest],
    incdirs: &[impl AsRef<str>],
    defines: &[(String, Option<String>)],
    nested: &[(String, String)],
    cost_model: &str,
) -> String {
    let incs: Vec<String> = incdirs.iter().map(|s| s.as_ref().to_string()).collect();
    pp_fingerprint(
        digests,
        &incs,
        defines,
        nested,
        PARSER_PIN_HINT,
        IR_VERSION,
        cost_model,
    )
}

/// crc_set for a single definition file.
pub fn crc_set_for_file(path: &str, crc: &str) -> String {
    module_crc_set(&[(path.to_string(), crc.to_string())])
}

/// design key helper.
pub fn compute_design_key(
    pp_fp: &str,
    filter: &[String],
    digests: &[FileDigest],
) -> String {
    compute_design_key_with_params(pp_fp, filter, digests, &[])
}

/// Design key including host param-map keys (order-insensitive).
pub fn compute_design_key_with_params(
    pp_fp: &str,
    filter: &[String],
    digests: &[FileDigest],
    param_map_keys: &[String],
) -> String {
    let crcs: Vec<(String, String)> = digests
        .iter()
        .map(|d| (d.path.clone(), d.crc.clone()))
        .collect();
    crate::fingerprint::design_cache_key_ex(pp_fp, filter, &crcs, param_map_keys)
}

fn map_sql(e: rusqlite::Error) -> CoreError {
    CoreError::InvalidOptions(format!("sqlite: {e}"))
}

fn parse_path_class(s: &str) -> sv_timing_core::PathClassKind {
    // Debug {:?} or snake_case
    let t = s.trim();
    if t.contains("ExclusiveCase") || t == "exclusive_case_mux" {
        return sv_timing_core::PathClassKind::ExclusiveCaseMux;
    }
    if t.contains("ExclusiveIf") || t == "exclusive_if_chain" {
        return sv_timing_core::PathClassKind::ExclusiveIfChain;
    }
    if t.contains("IndependentLhs") || t == "independent_lhs_bundle" {
        return sv_timing_core::PathClassKind::IndependentLhsBundle;
    }
    if t.contains("DenseControl") || t == "dense_control_cone" {
        return sv_timing_core::PathClassKind::DenseControlCone;
    }
    if t.contains("Atomic") || t == "atomic_over_budget" {
        return sv_timing_core::PathClassKind::AtomicOverBudget;
    }
    if t.contains("UnderBudget") || t == "under_budget" {
        return sv_timing_core::PathClassKind::UnderBudget;
    }
    if t.contains("MultiCycle") || t == "multi_cycle_tagged" {
        return sv_timing_core::PathClassKind::MultiCycleTagged;
    }
    sv_timing_core::PathClassKind::Plain
}

fn now_rfc3339() -> String {
    // Avoid chrono dep: simple UTC-ish timestamp from system clock.
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("{secs}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use sv_timing_core::loc::{OriginKind, SourceLoc};
    use sv_timing_core::{TimingModule, TimingTarget};

    #[test]
    fn open_put_get_module() {
        let dir = std::env::temp_dir().join(format!(
            "svt_cache_{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_millis()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        let db = dir.join("t.sqlite");
        let cache = TimingCache::open(CacheConfig::at(&db)).expect("open");
        let modu = TimingModule {
            id: 0,
            name: "m".into(),
            file: "m.sv".into(),
            nodes: Default::default(),
            regions: Default::default(),
            localparams: Vec::new(),
            parameters: Vec::new(),
            ports: Vec::new(),
            gen_loops: Vec::new(),
            functions: Vec::new(),
            package_imports: Vec::new(),
            instances: Vec::new(),
            loc: SourceLoc {
                file: "m.sv".into(),
                start_line: 1,
                start_col: 1,
                end_line: 1,
                end_col: 1,
                byte_start: 0,
                byte_end: 0,
                origin: OriginKind::UserFile,
            },
        };
        let blob = ModuleIrBlob {
            module: modu,
            paths: vec![],
        };
        let cs = crc_set_for_file("m.sv", "deadbeef");
        cache.put_module("m", "m.sv", &cs, &blob).unwrap();
        let got = cache.get_module("m", &cs).unwrap().expect("hit");
        assert_eq!(got.module.name, "m");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn design_roundtrip() {
        let dir = std::env::temp_dir().join(format!(
            "svt_cache_d_{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_millis()
        ));
        let db = dir.join("d.sqlite");
        let cache = TimingCache::open(CacheConfig::at(&db)).unwrap();
        let design = sv_timing_core::TimingDesign::empty(TimingTarget::new(1000.0, 20.0, 0.2));
        cache.put_design("key1", "fo4-v1", &design).unwrap();
        let got = cache.get_design("key1", "fo4-v1").unwrap().unwrap();
        assert_eq!(got.target.target_mhz, 1000.0);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
