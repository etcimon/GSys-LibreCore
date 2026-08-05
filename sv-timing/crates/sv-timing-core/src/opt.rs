// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Optimization level surface: GCC-style presets that only set explicit dials.

//! Optimization levels and dials.
//!
//! A level (`-O0`…`-O3`, `-Os`, `-Oz`) is **only** a preset over the ten dials in
//! [`OptOptions`]; it has no behavior of its own, and it never relaxes a safety
//! gate (allowlist, refuse lists, `--allow-latency`, dry-run, emit containment).
//!
//! Authoritative spec: `architecture/OPTIMIZATION-LEVELS.md` §3–§4 (KD20).

use std::fmt;

/// Optimization level preset.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OptLevel {
    /// Analyze only; transforms hard-off.
    O0,
    /// Latency-neutral restructuring only.
    O1,
    /// One cost-balanced `InsertReg` per over-budget path (default when correcting).
    O2,
    /// Multi-cut pipelining to budget + wider worklist.
    O3,
    /// Maximize FO4 gain per added flop (area/power first).
    Os,
    /// Zero new state: combinational restructuring only.
    Oz,
}

impl OptLevel {
    /// Parse `0|1|2|3|s|z` with optional leading `-O` / `O`.
    pub fn parse(s: &str) -> Option<Self> {
        let t = s.trim();
        let t = t.strip_prefix("-O").or_else(|| t.strip_prefix("-o")).unwrap_or(t);
        let t = t.strip_prefix('O').or_else(|| t.strip_prefix('o')).unwrap_or(t);
        match t.to_ascii_lowercase().as_str() {
            "0" => Some(OptLevel::O0),
            "1" => Some(OptLevel::O1),
            "2" => Some(OptLevel::O2),
            "3" => Some(OptLevel::O3),
            "s" => Some(OptLevel::Os),
            "z" => Some(OptLevel::Oz),
            _ => None,
        }
    }

    /// Canonical label (`O2`, `Os`, …).
    pub fn as_str(&self) -> &'static str {
        match self {
            OptLevel::O0 => "O0",
            OptLevel::O1 => "O1",
            OptLevel::O2 => "O2",
            OptLevel::O3 => "O3",
            OptLevel::Os => "Os",
            OptLevel::Oz => "Oz",
        }
    }
}

impl fmt::Display for OptLevel {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Dial 3 — how a pipeline cut site is chosen.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum CutStrategy {
    /// Legacy index midpoint (cost-blind); kept for A/B comparison only.
    MidNode,
    /// Prefix-sum bisection: balance the two segment delays.
    CostBalanced,
    /// Greedy fill: cut whenever the running segment would exceed the budget.
    BudgetFit,
}

impl CutStrategy {
    /// Parse `mid-node|cost-balanced|budget-fit`.
    pub fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().replace('_', "-").as_str() {
            "mid-node" | "mid" => Some(CutStrategy::MidNode),
            "cost-balanced" | "balanced" => Some(CutStrategy::CostBalanced),
            "budget-fit" | "budget" => Some(CutStrategy::BudgetFit),
            _ => None,
        }
    }

    /// Canonical label.
    pub fn as_str(&self) -> &'static str {
        match self {
            CutStrategy::MidNode => "mid-node",
            CutStrategy::CostBalanced => "cost-balanced",
            CutStrategy::BudgetFit => "budget-fit",
        }
    }
}

/// Dial 9 — analysis depth (independent of transform strength).
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OptEffort {
    /// Per-module paths only; no cross-module stitch.
    Fast,
    /// Default: local paths + cross-module stitch.
    Balanced,
    /// Full enumeration + stitch with bridge nets.
    Thorough,
}

impl OptEffort {
    /// Parse `fast|balanced|thorough`.
    pub fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "fast" => Some(OptEffort::Fast),
            "balanced" => Some(OptEffort::Balanced),
            "thorough" => Some(OptEffort::Thorough),
            _ => None,
        }
    }

    /// Canonical label.
    pub fn as_str(&self) -> &'static str {
        match self {
            OptEffort::Fast => "fast",
            OptEffort::Balanced => "balanced",
            OptEffort::Thorough => "thorough",
        }
    }

    /// Whether cross-module stitching runs at this effort.
    pub fn stitch_cross_module(&self) -> bool {
        !matches!(self, OptEffort::Fast)
    }
}

/// Dial 10b — cache tier selection (see `architecture/PERF-CACHE.md`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum CacheMode {
    /// Bypass SQLite entirely.
    Off,
    /// Design + module IR tiers (shipped v1 behavior).
    Ir,
    /// Reserved (P17): pre-compiled per-file units. Falls back to `Ir` until built.
    Unit,
    /// Reserved (P17): units + design blob.
    Full,
}

impl CacheMode {
    /// Parse `off|ir|unit|full`.
    pub fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "off" | "none" => Some(CacheMode::Off),
            "ir" => Some(CacheMode::Ir),
            "unit" | "units" => Some(CacheMode::Unit),
            "full" => Some(CacheMode::Full),
            _ => None,
        }
    }

    /// Canonical label.
    pub fn as_str(&self) -> &'static str {
        match self {
            CacheMode::Off => "off",
            CacheMode::Ir => "ir",
            CacheMode::Unit => "unit",
            CacheMode::Full => "full",
        }
    }

    /// Whether the SQLite cache is consulted at all.
    pub fn uses_sqlite(&self) -> bool {
        !matches!(self, CacheMode::Off)
    }
}

/// The ten dials, fully resolved (preset + explicit overrides).
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct OptOptions {
    /// Preset this set was derived from.
    pub level: OptLevel,
    /// Dial 1 — transform iterations.
    pub max_passes: u32,
    /// Dial 2 — work items **applied** per pass.
    pub worklist_width: usize,
    /// Dial 3 — cut site selection.
    pub cut_strategy: CutStrategy,
    /// Dial 4 — multi-cut depth per region.
    pub max_stages_per_region: u32,
    /// Dial 5 — reject edits whose predicted FO4 gain is below this.
    pub min_gain_fo4: f64,
    /// Dial 6 — stop when worst slack reaches this (may be negative for `-Os`).
    pub slack_target_fo4: f64,
    /// Dial 7 — penalty per added flop when ordering candidates.
    pub area_weight: f64,
    /// Dial 8 — allow equivalence-unverified algebraic reshaping.
    pub allow_reassoc: bool,
    /// Dial 9 — analysis depth.
    pub effort: OptEffort,
    /// Dial 10a — parallel degree (`None` = auto).
    pub jobs: Option<usize>,
    /// Dial 10b — cache tier.
    pub cache_mode: CacheMode,
}

impl Default for OptOptions {
    fn default() -> Self {
        Self::preset(OptLevel::O2)
    }
}

impl OptOptions {
    /// Dial values for a preset (the §3.1 matrix; this is the single source of truth).
    pub fn preset(level: OptLevel) -> Self {
        let (max_passes, worklist_width, cut_strategy, max_stages_per_region) = match level {
            OptLevel::O0 => (0, 0, CutStrategy::CostBalanced, 0),
            OptLevel::O1 => (2, 1, CutStrategy::CostBalanced, 0),
            OptLevel::O2 => (4, 1, CutStrategy::CostBalanced, 1),
            OptLevel::O3 => (16, 4, CutStrategy::BudgetFit, 8),
            // Budget-fit is the **flop-minimal** strategy: filling each stage to the
            // budget reaches closure with the fewest registers, which is exactly what an
            // area-first level wants. What distinguishes `-Os` from `-O3` is the high
            // `min_gain`, the tolerated residual overage, and area-weighted ordering.
            OptLevel::Os => (4, 2, CutStrategy::BudgetFit, 2),
            OptLevel::Oz => (2, 1, CutStrategy::CostBalanced, 0),
        };
        let (min_gain_fo4, slack_target_fo4, area_weight) = match level {
            OptLevel::O0 => (0.0, 0.0, 0.0),
            OptLevel::O1 => (1.0, 0.0, 0.0),
            OptLevel::O2 => (2.0, 0.0, 0.0),
            OptLevel::O3 => (1.0, 0.0, 0.0),
            OptLevel::Os => (4.0, -4.0, 1.0),
            OptLevel::Oz => (1.0, 0.0, 0.0),
        };
        let effort = match level {
            OptLevel::O0 => OptEffort::Fast,
            OptLevel::O3 => OptEffort::Thorough,
            _ => OptEffort::Balanced,
        };
        Self {
            level,
            max_passes,
            worklist_width,
            cut_strategy,
            max_stages_per_region,
            min_gain_fo4,
            slack_target_fo4,
            area_weight,
            allow_reassoc: false,
            effort,
            jobs: None,
            cache_mode: CacheMode::Unit,
        }
    }

    /// True when the level permits inserting registers at all.
    ///
    /// `-O0` runs no transform; `-O1` / `-Oz` are latency-neutral by construction
    /// (`max_stages_per_region == 0`). This is **independent** of `--allow-latency`,
    /// which remains a hard gate that a level can never relax.
    pub fn allows_new_state(&self) -> bool {
        self.max_stages_per_region > 0 && self.max_passes > 0
    }

    /// Digest of only the dials that can change an **analyze** result.
    ///
    /// This is what belongs in a cache key. `jobs` is pure scheduling (verified: parallel
    /// and serial analyze produce byte-identical reports), and the transform dials
    /// (1, 2, 3, 4, 5, 6, 7, 8) only affect `correct`, so none of them may invalidate a
    /// cached design. `effort` **is** included because it changes what is analyzed
    /// (`fast` skips the cross-module stitch), and `cache_mode` because it selects the
    /// tier the entry belongs to.
    pub fn analysis_digest(&self) -> String {
        format!(
            "e{ef}:k{cm}",
            ef = self.effort.as_str(),
            cm = self.cache_mode.as_str(),
        )
    }

    /// Stable digest of **all** dials, for report banners and provenance.
    pub fn digest(&self) -> String {
        format!(
            "{lvl}:p{mp}:w{ww}:c{cs}:s{ms}:g{mg:.3}:t{st:.3}:a{aw:.3}:r{ra}:e{ef}:j{jb}:k{cm}",
            lvl = self.level.as_str(),
            mp = self.max_passes,
            ww = self.worklist_width,
            cs = self.cut_strategy.as_str(),
            ms = self.max_stages_per_region,
            mg = self.min_gain_fo4,
            st = self.slack_target_fo4,
            aw = self.area_weight,
            ra = u8::from(self.allow_reassoc),
            ef = self.effort.as_str(),
            jb = self.jobs.map(|j| j.to_string()).unwrap_or_else(|| "auto".into()),
            cm = self.cache_mode.as_str(),
        )
    }

    /// One-line human summary for the CLI banner.
    pub fn summary(&self) -> String {
        format!(
            "-{lvl} (max_passes={mp} worklist_width={ww} cut={cs} stages={ms} \
             min_gain={mg} slack_target={st} area_weight={aw} reassoc={ra} \
             effort={ef} cache={cm})",
            lvl = self.level.as_str(),
            mp = self.max_passes,
            ww = self.worklist_width,
            cs = self.cut_strategy.as_str(),
            ms = self.max_stages_per_region,
            mg = self.min_gain_fo4,
            st = self.slack_target_fo4,
            aw = self.area_weight,
            ra = self.allow_reassoc,
            ef = self.effort.as_str(),
            cm = self.cache_mode.as_str(),
        )
    }
}

/// Explicit per-dial overrides; `None` = keep the preset value.
#[derive(Debug, Clone, Default)]
pub struct OptOverrides {
    /// Dial 1.
    pub max_passes: Option<u32>,
    /// Dial 2.
    pub worklist_width: Option<usize>,
    /// Dial 3.
    pub cut_strategy: Option<CutStrategy>,
    /// Dial 4.
    pub max_stages_per_region: Option<u32>,
    /// Dial 5.
    pub min_gain_fo4: Option<f64>,
    /// Dial 6.
    pub slack_target_fo4: Option<f64>,
    /// Dial 7.
    pub area_weight: Option<f64>,
    /// Dial 8.
    pub allow_reassoc: Option<bool>,
    /// Dial 9.
    pub effort: Option<OptEffort>,
    /// Dial 10a.
    pub jobs: Option<usize>,
    /// Dial 10b.
    pub cache_mode: Option<CacheMode>,
}

/// Resolve a level plus explicit overrides into final dial values.
///
/// Explicit dials always win over the preset (`architecture/OPTIMIZATION-LEVELS.md` §3).
/// Multi-cut implies a budget-fit strategy unless the caller asked for something else.
pub fn resolve(level: OptLevel, ov: &OptOverrides) -> OptOptions {
    let mut o = OptOptions::preset(level);
    if let Some(v) = ov.max_passes {
        o.max_passes = v;
    }
    if let Some(v) = ov.worklist_width {
        o.worklist_width = v;
    }
    if let Some(v) = ov.cut_strategy {
        o.cut_strategy = v;
    }
    if let Some(v) = ov.max_stages_per_region {
        o.max_stages_per_region = v;
    }
    if let Some(v) = ov.min_gain_fo4 {
        o.min_gain_fo4 = v;
    }
    if let Some(v) = ov.slack_target_fo4 {
        o.slack_target_fo4 = v;
    }
    if let Some(v) = ov.area_weight {
        o.area_weight = v;
    }
    if let Some(v) = ov.allow_reassoc {
        o.allow_reassoc = v;
    }
    if let Some(v) = ov.effort {
        o.effort = v;
    }
    if ov.jobs.is_some() {
        o.jobs = ov.jobs;
    }
    if let Some(v) = ov.cache_mode {
        o.cache_mode = v;
    }
    // Dial 4 > 1 needs a strategy that can place several cuts.
    if o.max_stages_per_region > 1
        && ov.cut_strategy.is_none()
        && o.cut_strategy != CutStrategy::BudgetFit
    {
        o.cut_strategy = CutStrategy::BudgetFit;
    }
    // A level that forbids new state must not carry a stage budget.
    if matches!(level, OptLevel::Oz) && ov.max_stages_per_region.is_none() {
        o.max_stages_per_region = 0;
    }
    o
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn level_parse_accepts_common_spellings() {
        assert_eq!(OptLevel::parse("-O3"), Some(OptLevel::O3));
        assert_eq!(OptLevel::parse("O2"), Some(OptLevel::O2));
        assert_eq!(OptLevel::parse("2"), Some(OptLevel::O2));
        assert_eq!(OptLevel::parse("s"), Some(OptLevel::Os));
        assert_eq!(OptLevel::parse("-Oz"), Some(OptLevel::Oz));
        assert_eq!(OptLevel::parse("fast"), None);
    }

    /// The §3.1 preset matrix, encoded as the fixture it is.
    #[test]
    fn preset_matrix_matches_spec() {
        // (level, max_passes, worklist_width, stages, min_gain, slack_target, area_weight)
        let rows = [
            (OptLevel::O0, 0u32, 0usize, 0u32, 0.0, 0.0, 0.0),
            (OptLevel::O1, 2, 1, 0, 1.0, 0.0, 0.0),
            (OptLevel::O2, 4, 1, 1, 2.0, 0.0, 0.0),
            (OptLevel::O3, 16, 4, 8, 1.0, 0.0, 0.0),
            (OptLevel::Os, 4, 2, 2u32, 4.0, -4.0, 1.0),
            (OptLevel::Oz, 2, 1, 0, 1.0, 0.0, 0.0),
        ];
        for (lvl, mp, ww, ms, mg, st, aw) in rows {
            let o = OptOptions::preset(lvl);
            assert_eq!(o.max_passes, mp, "{lvl} max_passes");
            assert_eq!(o.worklist_width, ww, "{lvl} worklist_width");
            assert_eq!(o.max_stages_per_region, ms, "{lvl} stages");
            assert!((o.min_gain_fo4 - mg).abs() < 1e-9, "{lvl} min_gain");
            assert!((o.slack_target_fo4 - st).abs() < 1e-9, "{lvl} slack_target");
            assert!((o.area_weight - aw).abs() < 1e-9, "{lvl} area_weight");
            assert!(!o.allow_reassoc, "{lvl} must not enable reassoc by preset");
        }
        assert_eq!(OptOptions::preset(OptLevel::O3).cut_strategy, CutStrategy::BudgetFit);
        assert_eq!(OptOptions::preset(OptLevel::O2).cut_strategy, CutStrategy::CostBalanced);
        // `-Os` is flop-minimal, so it also fills stages to the budget.
        assert_eq!(OptOptions::preset(OptLevel::Os).cut_strategy, CutStrategy::BudgetFit);
        assert_eq!(OptOptions::preset(OptLevel::O3).effort, OptEffort::Thorough);
        assert_eq!(OptOptions::preset(OptLevel::O0).effort, OptEffort::Fast);
    }

    #[test]
    fn only_o2_o3_os_allow_new_state() {
        assert!(!OptOptions::preset(OptLevel::O0).allows_new_state());
        assert!(!OptOptions::preset(OptLevel::O1).allows_new_state());
        assert!(OptOptions::preset(OptLevel::O2).allows_new_state());
        assert!(OptOptions::preset(OptLevel::O3).allows_new_state());
        assert!(OptOptions::preset(OptLevel::Os).allows_new_state());
        assert!(!OptOptions::preset(OptLevel::Oz).allows_new_state());
    }

    #[test]
    fn explicit_dial_overrides_preset() {
        let ov = OptOverrides {
            max_passes: Some(7),
            min_gain_fo4: Some(0.5),
            allow_reassoc: Some(true),
            ..Default::default()
        };
        let o = resolve(OptLevel::O2, &ov);
        assert_eq!(o.max_passes, 7);
        assert!((o.min_gain_fo4 - 0.5).abs() < 1e-9);
        assert!(o.allow_reassoc);
        // Untouched dials keep the preset.
        assert_eq!(o.worklist_width, 1);
        assert_eq!(o.cut_strategy, CutStrategy::CostBalanced);
    }

    #[test]
    fn multi_cut_implies_budget_fit_unless_asked_otherwise() {
        let o = resolve(
            OptLevel::O2,
            &OptOverrides {
                max_stages_per_region: Some(4),
                ..Default::default()
            },
        );
        assert_eq!(o.cut_strategy, CutStrategy::BudgetFit);
        let o2 = resolve(
            OptLevel::O2,
            &OptOverrides {
                max_stages_per_region: Some(4),
                cut_strategy: Some(CutStrategy::MidNode),
                ..Default::default()
            },
        );
        assert_eq!(o2.cut_strategy, CutStrategy::MidNode, "explicit dial wins");
    }

    #[test]
    fn oz_stays_stateless_unless_overridden() {
        assert_eq!(resolve(OptLevel::Oz, &OptOverrides::default()).max_stages_per_region, 0);
        let forced = resolve(
            OptLevel::Oz,
            &OptOverrides {
                max_stages_per_region: Some(2),
                ..Default::default()
            },
        );
        assert_eq!(forced.max_stages_per_region, 2, "explicit override is honored");
    }

    #[test]
    fn digest_is_stable_and_level_sensitive() {
        let a = OptOptions::preset(OptLevel::O2);
        let b = OptOptions::preset(OptLevel::O2);
        assert_eq!(a.digest(), b.digest());
        assert_ne!(a.digest(), OptOptions::preset(OptLevel::O3).digest());
        let mut c = a.clone();
        c.min_gain_fo4 = 9.0;
        assert_ne!(a.digest(), c.digest(), "dial change must change the digest");
    }

    #[test]
    fn analysis_digest_ignores_operational_and_transform_dials() {
        let base = OptOptions::preset(OptLevel::O2);
        // Thread count cannot change a result ⇒ must not invalidate a cache entry.
        let mut jobs = base.clone();
        jobs.jobs = Some(8);
        assert_eq!(base.analysis_digest(), jobs.analysis_digest());
        assert_ne!(base.digest(), jobs.digest(), "reporting digest still records it");
        // Transform-only dials likewise.
        let mut transform = base.clone();
        transform.max_passes = 99;
        transform.min_gain_fo4 = 42.0;
        transform.cut_strategy = CutStrategy::MidNode;
        assert_eq!(base.analysis_digest(), transform.analysis_digest());
        // Effort changes what is analyzed ⇒ must invalidate.
        let mut effort = base.clone();
        effort.effort = OptEffort::Fast;
        assert_ne!(base.analysis_digest(), effort.analysis_digest());
        // … which is why -O2 vs -O3 still differ (balanced vs thorough).
        assert_ne!(
            OptOptions::preset(OptLevel::O2).analysis_digest(),
            OptOptions::preset(OptLevel::O3).analysis_digest()
        );
    }

    #[test]
    fn enum_parsers_roundtrip() {
        for s in ["mid-node", "cost-balanced", "budget-fit"] {
            assert_eq!(CutStrategy::parse(s).unwrap().as_str(), s);
        }
        for s in ["fast", "balanced", "thorough"] {
            assert_eq!(OptEffort::parse(s).unwrap().as_str(), s);
        }
        for s in ["off", "ir", "unit", "full"] {
            assert_eq!(CacheMode::parse(s).unwrap().as_str(), s);
        }
        assert!(CutStrategy::parse("nonsense").is_none());
        assert!(!CacheMode::Off.uses_sqlite());
        assert!(CacheMode::Ir.uses_sqlite());
        assert!(!OptEffort::Fast.stitch_cross_module());
        assert!(OptEffort::Thorough.stitch_cross_module());
    }
}
