// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//! Adjusted FO4: mapped path delay expressed in the platform's own FO4 unit.
//!
//! Structural FO4 is a screening estimate over source operators. A mapped
//! delay from a static timing tool is physical but bound to one library.
//! Dividing a mapped delay by that library's measured FO4 (a minimum-size
//! inverter driving four copies of itself, from the same liberty) gives a
//! platform-independent reading that the frequency budget already uses:
//!
//! ```text
//! budget_fo4      = (1e6 / target_mhz / fo4_ps) * (1 - margin)
//! adjusted_fo4    = mapped_ns * 1000 / platform_fo4_ps
//! closes(budget)  = max adjusted_fo4 <= budget_fo4
//! f_mhz(fo4_ps)   = 1e6 * (1 - margin) / (max adjusted_fo4 * fo4_ps)
//! ```
//!
//! `f_mhz` is the frequency at which the budget equals the worst adjusted
//! path on any process characterised by `fo4_ps`. It is a pre-layout,
//! library-level projection — wires, clock uncertainty and placement are not
//! inside it — so it bounds what the logic can reach, not what a design
//! closes at. A module without a mapped row gets an *estimated* adjusted FO4
//! from the median adjusted/structural ratio of the measured modules, and is
//! labelled as such; estimated values never decide closure.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// Platform FO4 as measured on its liberty.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PlatformFo4 {
    /// Platform / library name.
    pub name: String,
    /// Measured FO4 delay in picoseconds.
    pub fo4_ps: f64,
    /// How `fo4_ps` was obtained (for example `inverter-chain-8-4`).
    pub method: String,
    /// Inverter cell the probe used, when known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cell: Option<String>,
}

/// A module's worst mapped path from a per-module board.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct MappedPath {
    /// Worst path of any kind through the module's own logic (ns).
    pub worst_ns: f64,
    /// Worst register-to-register path (ns), when reported.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reg2reg_ns: Option<f64>,
    /// Cells on the worst reg→reg path, when reported.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cells: Option<u32>,
}

/// A module's worst structural (single-cycle) path from a report.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct StructuralModule {
    /// Module name.
    pub name: String,
    /// Worst single-cycle structural FO4, when the module has a path.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worst_fo4: Option<f64>,
    /// Kind of that path (`regtoreg`, `intoreg`, …).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worst_kind: Option<String>,
}

/// Where a module's adjusted value comes from.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum AdjustedSource {
    /// From a mapped delay on this platform.
    Measured,
    /// From the structural value times the fitted ratio; never decides closure.
    Estimated,
}

/// One module's adjusted reading.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AdjustedModule {
    /// Module name.
    pub module: String,
    /// Delay in platform FO4 units.
    pub adjusted_fo4: f64,
    /// Measured from a mapped delay, or estimated from the fit.
    pub source: AdjustedSource,
    /// Mapped worst delay (ns) for measured rows.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mapped_ns: Option<f64>,
    /// Structural worst FO4 from the report, when present.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub structural_fo4: Option<f64>,
    /// Kind of the structural path.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub structural_kind: Option<String>,
    /// adjusted / structural for measured modules with a structural value.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ratio: Option<f64>,
    /// `adjusted_fo4 > budget_fo4`.
    pub over_budget: bool,
}

/// Median and quartiles of adjusted/structural over measured modules.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AdjustedFit {
    /// Measured modules with a structural value.
    pub n: usize,
    /// Median adjusted/structural.
    pub ratio_median: f64,
    /// Lower quartile.
    pub ratio_p25: f64,
    /// Upper quartile.
    pub ratio_p75: f64,
}

/// The adjusted reading of a design on one platform.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AdjustedReport {
    /// `adjusted-fo4.v1`.
    pub schema_version: String,
    /// What this reading is and is not.
    pub disclaimer: String,
    /// The platform the delays were mapped and probed on.
    pub platform: PlatformFo4,
    /// Budget in FO4.
    pub budget_fo4: f64,
    /// Budget margin 0..1.
    pub margin: f64,
    /// Process FO4 the frequency projection is also quoted at (ps).
    pub target_fo4_ps: f64,
    /// Every module, worst first (measured and estimated).
    pub modules: Vec<AdjustedModule>,
    /// Modules with a mapped row (including those that folded to no path).
    pub measured_modules: usize,
    /// Mapped rows that linked with a clock but had no timing path.
    pub measured_no_path: usize,
    /// Modules estimated from the fit.
    pub estimated_modules: usize,
    /// Worst measured module, or `None` when nothing was measured.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worst: Option<AdjustedModule>,
    /// Measured worst within the budget (estimated rows never decide).
    pub closes: bool,
    /// Measured modules over the budget.
    pub measured_over_budget: usize,
    /// Frequency at which the budget equals the measured worst, on this platform.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub implied_mhz_on_platform: Option<f64>,
    /// Same reading quoted at `target_fo4_ps`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub implied_mhz_at_target_fo4: Option<f64>,
    /// Mapped ns the budget allows on this platform.
    pub budget_ns_on_platform: f64,
    /// Adjusted/structural fit over measured modules, when any.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fit: Option<AdjustedFit>,
}

/// Schema identifier of [`AdjustedReport`].
pub const ADJUSTED_SCHEMA: &str = "adjusted-fo4.v1";

/// Frequency (MHz) at which `budget_fo4` equals `adjusted_fo4` for a process
/// with `fo4_ps`; `None` when the inputs cannot form a frequency.
pub fn implied_mhz(adjusted_fo4: f64, fo4_ps: f64, margin: f64) -> Option<f64> {
    if !(adjusted_fo4 > 0.0) || !(fo4_ps > 0.0) || !(0.0..1.0).contains(&margin) {
        return None;
    }
    Some(1e6 * (1.0 - margin) / (adjusted_fo4 * fo4_ps))
}

fn quantile(sorted: &[f64], q: f64) -> f64 {
    if sorted.is_empty() {
        return f64::NAN;
    }
    let pos = q * (sorted.len() - 1) as f64;
    let lo = pos.floor() as usize;
    let hi = pos.ceil() as usize;
    if lo == hi {
        sorted[lo]
    } else {
        sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo as f64)
    }
}

/// Join structural and mapped readings into adjusted FO4 per module.
pub fn adjust(
    structural: &[StructuralModule],
    board: &BTreeMap<String, MappedPath>,
    platform: &PlatformFo4,
    budget_fo4: f64,
    margin: f64,
    target_fo4_ps: f64,
) -> AdjustedReport {
    let fo4_ps = platform.fo4_ps;
    let scale = if fo4_ps > 0.0 {
        1000.0 / fo4_ps
    } else {
        f64::NAN
    };
    let structural_by_name: BTreeMap<&str, &StructuralModule> =
        structural.iter().map(|s| (s.name.as_str(), s)).collect();

    let mut modules = Vec::new();
    let mut ratios = Vec::new();
    let mut measured_no_path = 0usize;
    for (name, mapped) in board {
        if !scale.is_finite() || !mapped.worst_ns.is_finite() || mapped.worst_ns < 0.0 {
            continue;
        }
        let st = structural_by_name.get(name.as_str());
        if mapped.worst_ns == 0.0 {
            // Linked and clocked, but no timing path after mapping: the
            // module's logic folded away (parameter-dead at this
            // configuration). Measured as zero; never estimated from the
            // structural value, which cannot see the folding.
            measured_no_path += 1;
            modules.push(AdjustedModule {
                module: name.clone(),
                adjusted_fo4: 0.0,
                source: AdjustedSource::Measured,
                mapped_ns: Some(0.0),
                structural_fo4: st.and_then(|s| s.worst_fo4),
                structural_kind: st.and_then(|s| s.worst_kind.clone()),
                ratio: None,
                over_budget: false,
            });
            continue;
        }
        let adjusted = mapped.worst_ns * scale;
        let structural_fo4 = st.and_then(|s| s.worst_fo4).filter(|v| *v > 0.0);
        let ratio = structural_fo4.map(|s| adjusted / s);
        if let Some(r) = ratio {
            ratios.push(r);
        }
        modules.push(AdjustedModule {
            module: name.clone(),
            adjusted_fo4: adjusted,
            source: AdjustedSource::Measured,
            mapped_ns: Some(mapped.worst_ns),
            structural_fo4,
            structural_kind: st.and_then(|s| s.worst_kind.clone()),
            ratio,
            over_budget: adjusted > budget_fo4,
        });
    }
    ratios.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let fit = (!ratios.is_empty()).then(|| AdjustedFit {
        n: ratios.len(),
        ratio_median: quantile(&ratios, 0.5),
        ratio_p25: quantile(&ratios, 0.25),
        ratio_p75: quantile(&ratios, 0.75),
    });
    if let Some(f) = &fit {
        for s in structural {
            if board.contains_key(&s.name) {
                continue;
            }
            let Some(st) = s.worst_fo4.filter(|v| *v > 0.0) else {
                continue;
            };
            let adjusted = st * f.ratio_median;
            modules.push(AdjustedModule {
                module: s.name.clone(),
                adjusted_fo4: adjusted,
                source: AdjustedSource::Estimated,
                mapped_ns: None,
                structural_fo4: Some(st),
                structural_kind: s.worst_kind.clone(),
                ratio: None,
                over_budget: adjusted > budget_fo4,
            });
        }
    }
    modules.sort_by(|a, b| {
        b.adjusted_fo4
            .partial_cmp(&a.adjusted_fo4)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.module.cmp(&b.module))
    });
    let measured: Vec<&AdjustedModule> = modules
        .iter()
        .filter(|m| m.source == AdjustedSource::Measured)
        .collect();
    let worst = measured.first().cloned().cloned();
    let measured_over_budget = measured.iter().filter(|m| m.over_budget).count();
    let closes = worst.is_some() && measured_over_budget == 0;
    let worst_fo4 = worst.as_ref().map(|w| w.adjusted_fo4);
    AdjustedReport {
        schema_version: ADJUSTED_SCHEMA.into(),
        disclaimer: "mapped delay in platform FO4 units — pre-layout library projection, not sign-off; estimated rows never decide closure".into(),
        platform: platform.clone(),
        budget_fo4,
        margin,
        target_fo4_ps,
        measured_modules: measured.len(),
        measured_no_path,
        estimated_modules: modules.len() - measured.len(),
        implied_mhz_on_platform: worst_fo4.and_then(|a| implied_mhz(a, fo4_ps, margin)),
        implied_mhz_at_target_fo4: worst_fo4.and_then(|a| implied_mhz(a, target_fo4_ps, margin)),
        budget_ns_on_platform: budget_fo4 * fo4_ps / 1000.0,
        worst,
        closes,
        measured_over_budget,
        fit,
        modules,
    }
}

/// Module name as the board writes it, without a derived-parameter suffix
/// (`name$...` from elaboration), keeping names a report would use.
pub fn board_module_name(raw: &str) -> &str {
    let t = raw.trim().trim_start_matches('\\');
    t.split('$').next().unwrap_or(t)
}

/// Parse a per-module board: tab-separated with a header naming at least
/// `module` and one of `worst_any_ns` / `worst_ns`; optional
/// `worst_reg2reg_ns` and `cells_on_path`. Rows without a finite delay are
/// skipped; a module appearing twice keeps its worst delay.
pub fn parse_board_tsv(text: &str) -> Result<BTreeMap<String, MappedPath>, String> {
    let mut lines = text.lines().filter(|l| !l.trim().is_empty());
    let header: Vec<&str> = lines
        .next()
        .ok_or("empty board")?
        .split('\t')
        .map(str::trim)
        .collect();
    let col = |names: &[&str]| {
        names
            .iter()
            .find_map(|n| header.iter().position(|h| h == n))
    };
    let module = col(&["module"]).ok_or("board header has no `module` column")?;
    let worst = col(&["worst_any_ns", "worst_ns"])
        .ok_or("board header has no `worst_any_ns`/`worst_ns` column")?;
    let reg2reg = col(&["worst_reg2reg_ns", "reg2reg_ns"]);
    let cells = col(&["cells_on_path", "cells"]);
    let instances = col(&["instances"]);
    let clock = col(&["clock"]);
    let mut out: BTreeMap<String, MappedPath> = BTreeMap::new();
    for line in lines {
        let f: Vec<&str> = line.split('\t').collect();
        let Some(raw) = f.get(module) else { continue };
        let worst_ns = f.get(worst).and_then(|v| v.trim().parse::<f64>().ok());
        let reg2reg_ns = reg2reg
            .and_then(|c| f.get(c))
            .and_then(|v| v.trim().parse::<f64>().ok());
        let worst_ns = match worst_ns.or(reg2reg_ns).filter(|v| v.is_finite()) {
            Some(v) => v,
            None => {
                // A linked, clocked module with no path at all is measured
                // zero; a row without an instance count or a clock (link
                // or tool failure) is unknown and skipped.
                let linked = instances
                    .and_then(|c| f.get(c))
                    .and_then(|v| v.trim().parse::<u64>().ok())
                    .is_some_and(|n| n > 0);
                let clocked = clock.map_or(true, |c| {
                    f.get(c)
                        .is_some_and(|v| v.trim() != "-" && !v.trim().is_empty())
                });
                if !(linked && clocked) {
                    continue;
                }
                0.0
            }
        };
        let cells = cells
            .and_then(|c| f.get(c))
            .and_then(|v| v.trim().parse::<u32>().ok());
        let name = board_module_name(raw).to_string();
        let row = MappedPath {
            worst_ns,
            reg2reg_ns,
            cells,
        };
        match out.get(&name) {
            Some(prev) if prev.worst_ns >= worst_ns => {}
            _ => {
                out.insert(name, row);
            }
        }
    }
    Ok(out)
}

/// Structural worst per live module from an analyze/correct report JSON
/// (`post_analyze` when present). Modules the report lists as uninstantiated
/// are excluded; multi-cycle paths are excluded.
pub fn structural_from_report(report: &serde_json::Value) -> Vec<StructuralModule> {
    let r = report.get("post_analyze").unwrap_or(report);
    let dead: std::collections::BTreeSet<&str> = r
        .pointer("/frequency_closure/uninstantiated_modules")
        .and_then(|v| v.as_array())
        .map(|a| a.iter().filter_map(|v| v.as_str()).collect())
        .unwrap_or_default();
    let mut names: BTreeMap<u64, &str> = BTreeMap::new();
    for m in r
        .get("modules")
        .and_then(|v| v.as_array())
        .into_iter()
        .flatten()
    {
        if let (Some(id), Some(name)) = (
            m.get("id").and_then(|v| v.as_u64()),
            m.get("name").and_then(|v| v.as_str()),
        ) {
            if !dead.contains(name) {
                names.insert(id, name);
            }
        }
    }
    let mut worst: BTreeMap<&str, (f64, Option<String>)> = BTreeMap::new();
    for p in r
        .get("paths")
        .and_then(|v| v.as_array())
        .into_iter()
        .flatten()
    {
        if p.get("multi_cycle")
            .and_then(|v| v.as_bool())
            .unwrap_or(false)
        {
            continue;
        }
        let Some(name) = p
            .get("module_id")
            .and_then(|v| v.as_u64())
            .and_then(|id| names.get(&id))
        else {
            continue;
        };
        let Some(fo4) = p.get("total_fo4").and_then(|v| v.as_f64()) else {
            continue;
        };
        let kind = p
            .get("path_kind")
            .and_then(|v| v.as_str())
            .map(str::to_string);
        match worst.get(name) {
            Some((cur, _)) if *cur >= fo4 => {}
            _ => {
                worst.insert(name, (fo4, kind));
            }
        }
    }
    names
        .values()
        .map(|n| {
            let w = worst.get(n);
            StructuralModule {
                name: n.to_string(),
                worst_fo4: w.map(|(f, _)| *f),
                worst_kind: w.and_then(|(_, k)| k.clone()),
            }
        })
        .collect()
}

/// Human table of the top rows, worst first.
pub fn render_table(report: &AdjustedReport, rows: usize) -> String {
    let mut out = String::new();
    out.push_str(&format!(
        "adjusted FO4 on {} (FO4 {:.2} ps, {}): budget {:.1} FO4 = {:.3} ns; measured {} ({} folded to no path) / estimated {}\n",
        report.platform.name, report.platform.fo4_ps, report.platform.method, report.budget_fo4,
        report.budget_ns_on_platform, report.measured_modules, report.measured_no_path, report.estimated_modules
    ));
    match (&report.worst, report.implied_mhz_on_platform, report.implied_mhz_at_target_fo4) {
        (Some(w), Some(on), Some(at)) => out.push_str(&format!(
            "worst measured {} = {:.1} adjusted FO4 ({:.3} ns) → closes {:.1}: {}; budget-equivalent {:.0} MHz on this platform, {:.0} MHz at fo4_ps={}\n",
            w.module, w.adjusted_fo4, w.mapped_ns.unwrap_or(f64::NAN), report.budget_fo4,
            if report.closes { "yes" } else { "no" }, on, at, report.target_fo4_ps
        )),
        _ => out.push_str("no measured module: closure undetermined\n"),
    }
    if let Some(f) = &report.fit {
        out.push_str(&format!(
            "adjusted/structural over {} measured modules: median {:.2} (p25 {:.2}, p75 {:.2})\n",
            f.n, f.ratio_median, f.ratio_p25, f.ratio_p75
        ));
    }
    out.push_str("module\tadjusted_fo4\tsource\tmapped_ns\tstructural_fo4\tratio\tover_budget\n");
    for m in report.modules.iter().take(rows) {
        out.push_str(&format!(
            "{}\t{:.1}\t{}\t{}\t{}\t{}\t{}\n",
            m.module,
            m.adjusted_fo4,
            match m.source {
                AdjustedSource::Measured => "measured",
                AdjustedSource::Estimated => "estimated",
            },
            m.mapped_ns
                .map(|v| format!("{v:.3}"))
                .unwrap_or_else(|| "-".into()),
            m.structural_fo4
                .map(|v| format!("{v:.1}"))
                .unwrap_or_else(|| "-".into()),
            m.ratio
                .map(|v| format!("{v:.2}"))
                .unwrap_or_else(|| "-".into()),
            if m.over_budget { "yes" } else { "no" },
        ));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn platform(fo4_ps: f64) -> PlatformFo4 {
        PlatformFo4 {
            name: "lib".into(),
            fo4_ps,
            method: "test".into(),
            cell: None,
        }
    }

    #[test]
    fn adjusted_is_mapped_over_platform_fo4_and_frequency_inverts_the_budget() {
        let board = BTreeMap::from([
            (
                "a".to_string(),
                MappedPath {
                    worst_ns: 0.9,
                    reg2reg_ns: None,
                    cells: Some(12),
                },
            ),
            (
                "b".to_string(),
                MappedPath {
                    worst_ns: 0.3,
                    reg2reg_ns: None,
                    cells: Some(4),
                },
            ),
        ]);
        let structural = vec![
            StructuralModule {
                name: "a".into(),
                worst_fo4: Some(20.0),
                worst_kind: Some("regtoreg".into()),
            },
            StructuralModule {
                name: "b".into(),
                worst_fo4: Some(5.0),
                worst_kind: None,
            },
            StructuralModule {
                name: "c".into(),
                worst_fo4: Some(10.0),
                worst_kind: None,
            },
        ];
        let r = adjust(&structural, &board, &platform(30.0), 10.0, 0.2, 20.0);
        let a = r.modules.iter().find(|m| m.module == "a").unwrap();
        assert!((a.adjusted_fo4 - 30.0).abs() < 1e-9);
        assert_eq!(a.source, AdjustedSource::Measured);
        assert!(a.over_budget);
        assert!(!r.closes);
        assert_eq!(r.measured_over_budget, 1);
        // budget_fo4(f) = 1e6 / f / fo4_ps * (1 - margin) == 30 → f = 1e6*0.8/(30*30)
        let f = r.implied_mhz_on_platform.unwrap();
        assert!((f - 1e6 * 0.8 / (30.0 * 30.0)).abs() < 1e-6);
        let budget_at_f = 1e6 / f / 30.0 * (1.0 - 0.2);
        assert!((budget_at_f - 30.0).abs() < 1e-6);
        assert!((r.implied_mhz_at_target_fo4.unwrap() - 1e6 * 0.8 / (30.0 * 20.0)).abs() < 1e-6);
        // c is estimated from the median ratio (a: 1.5, b: 2.0 → 1.75) and never decides closure
        let c = r.modules.iter().find(|m| m.module == "c").unwrap();
        assert_eq!(c.source, AdjustedSource::Estimated);
        assert!((c.adjusted_fo4 - 17.5).abs() < 1e-9);
        assert!(c.over_budget);
        assert_eq!(r.estimated_modules, 1);
        assert_eq!(r.worst.as_ref().unwrap().module, "a");
        assert!((r.budget_ns_on_platform - 0.3).abs() < 1e-12);
    }

    #[test]
    fn closes_only_when_every_measured_module_is_within_budget() {
        let board = BTreeMap::from([(
            "a".to_string(),
            MappedPath {
                worst_ns: 0.19,
                reg2reg_ns: None,
                cells: None,
            },
        )]);
        let r = adjust(&[], &board, &platform(20.0), 10.0, 0.2, 20.0);
        assert!(r.closes);
        assert_eq!(r.estimated_modules, 0);
        assert!(r.fit.is_none());
        let empty = adjust(&[], &BTreeMap::new(), &platform(20.0), 10.0, 0.2, 20.0);
        assert!(!empty.closes && empty.worst.is_none());
        assert!(implied_mhz(10.0, 0.0, 0.2).is_none());
        assert!(implied_mhz(10.0, 20.0, 1.0).is_none());
    }

    #[test]
    fn board_tsv_is_header_driven_and_strips_derived_suffixes() {
        let text =
            "module\tinstances\tclock\tworst_reg2reg_ns\tcells_on_path\tstartpoint\tworst_any_ns\n\
                    iq$top.x\t1\tclk_i\t2.403\t32\t_1_\t2.403\n\
                    iq$top.y\t1\tclk_i\t2.100\t30\t_2_\t2.900\n\
                    folded\t1\tclk_i\t-\t0\t-\t-\n\
                    broken\t-\t-\t-\t-\tlink failed\t-\n\
                    boundary\t1\tclk_i\t-\t-\t-\t1.250\n";
        let b = parse_board_tsv(text).unwrap();
        assert_eq!(b.len(), 3);
        assert_eq!(b["iq"].worst_ns, 2.9);
        assert_eq!(b["iq"].cells, Some(30));
        assert_eq!(b["boundary"].worst_ns, 1.25);
        assert_eq!(b["folded"].worst_ns, 0.0);
        assert!(!b.contains_key("broken"));
        let structural = vec![StructuralModule {
            name: "folded".into(),
            worst_fo4: Some(37.0),
            worst_kind: None,
        }];
        let r = adjust(&structural, &b, &platform(20.0), 10.0, 0.2, 20.0);
        let folded = r.modules.iter().find(|m| m.module == "folded").unwrap();
        assert_eq!(folded.source, AdjustedSource::Measured);
        assert_eq!(folded.adjusted_fo4, 0.0);
        assert!(!folded.over_budget);
        assert_eq!(r.measured_no_path, 1);
        assert_eq!(r.estimated_modules, 0);
        assert!(r.fit.is_none(), "a folded module has no ratio to fit");
        assert!(parse_board_tsv("name\tns\nx\t1\n").is_err());
        assert_eq!(board_module_name("\\g6$cva6.i"), "g6");
    }

    #[test]
    fn structural_report_excludes_uninstantiated_and_multi_cycle() {
        let report = serde_json::json!({
            "post_analyze": {
                "modules": [{"id": 1, "name": "live"}, {"id": 2, "name": "dead"}],
                "paths": [
                    {"module_id": 1, "total_fo4": 12.0, "path_kind": "regtoreg", "multi_cycle": false},
                    {"module_id": 1, "total_fo4": 40.0, "path_kind": "regtoreg", "multi_cycle": true},
                    {"module_id": 2, "total_fo4": 99.0, "path_kind": "regtoreg", "multi_cycle": false}
                ],
                "frequency_closure": {"uninstantiated_modules": ["dead"]}
            }
        });
        let s = structural_from_report(&report);
        assert_eq!(s.len(), 1);
        assert_eq!(s[0].name, "live");
        assert_eq!(s[0].worst_fo4, Some(12.0));
        assert_eq!(s[0].worst_kind.as_deref(), Some("regtoreg"));
    }
}
