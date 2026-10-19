// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//! Measured calibration: structural FO4 in a platform's own FO4 unit.
//!
//! The adjusted reading ([`crate::adjusted`]) divides a mapped delay by the
//! platform's measured FO4. A calibration profile fits, over the measured
//! modules of one board, the line that maps a module's worst structural FO4
//! onto its adjusted FO4:
//!
//! ```text
//! calibrated_fo4 = slope · structural_fo4 + launch_fo4 · [path launches at a register]
//! ```
//!
//! `slope` absorbs what the operator table does not price on that library
//! (minimum-size cells, slew, stacks); `launch_fo4` the clock-to-Q of the
//! launching flop, which the structural cone excludes and a path from an
//! ideal input port does not have (the board's arrival time has no setup
//! term). The fit minimises the median |log(calibrated/adjusted)| over a
//! grid of launch values, the slope being the median ratio at each — so a
//! few modules the model reads wrong do not set the line — and it reports
//! the residual spread that remains: the model error per module.
//!
//! A profile is bound to the measurement semantics the structural values
//! were produced under: applying it to a report of another `delay-vNN` is
//! refused, never silently mixed. Calibrated values are an estimate in
//! platform FO4 units, not STA; measured (adjusted) rows still decide.

use serde::{Deserialize, Serialize};

use crate::adjusted::{implied_mhz, AdjustedReport, AdjustedSource, PlatformFo4};

/// Schema identifier of [`CalibrationProfile`].
pub const CALIBRATION_SCHEMA: &str = "fo4-calibration.v1";

/// Fewest measured modules a profile is fitted from.
pub const MIN_CALIBRATION_POINTS: usize = 8;

/// One fitted module: structural, measured adjusted, and the line's value.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CalibrationPoint {
    /// Module name.
    pub module: String,
    /// Worst single-cycle structural FO4.
    pub structural_fo4: f64,
    /// Kind of that structural path (`regtoreg`, `intoout`, …).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub structural_kind: Option<String>,
    /// Measured adjusted FO4 on the platform.
    pub adjusted_fo4: f64,
    /// `slope · structural (+ launch)`.
    pub calibrated_fo4: f64,
    /// `calibrated / adjusted` (1 = the line reads this module exactly).
    pub residual_ratio: f64,
}

/// Residual spread of the fit, as calibrated/adjusted ratios.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CalibrationFit {
    /// Fit method.
    pub method: String,
    /// Points fitted.
    pub n: usize,
    /// Median calibrated/adjusted.
    pub residual_median: f64,
    /// Lower quartile.
    pub residual_p25: f64,
    /// Upper quartile.
    pub residual_p75: f64,
    /// Median |ln(calibrated/adjusted)|: typical per-module model error
    /// (0.1 ≈ 10 %).
    pub log_mad: f64,
    /// Spearman rank correlation of structural with adjusted.
    pub rank_correlation: f64,
}

/// A fitted structural → platform-FO4 calibration.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CalibrationProfile {
    /// [`CALIBRATION_SCHEMA`].
    pub schema_version: String,
    /// What this profile is and is not.
    pub disclaimer: String,
    /// Platform the adjusted values were measured on.
    pub platform: PlatformFo4,
    /// Measurement semantics of the structural values (`delay-vNN`).
    pub measurement: String,
    /// Cost table id of the structural values.
    pub cost_model: String,
    /// Platform FO4 per structural FO4.
    pub slope: f64,
    /// Platform FO4 a register-launched path adds (clock-to-Q).
    pub launch_fo4: f64,
    /// Residual spread.
    pub fit: CalibrationFit,
    /// Fitted modules, worst adjusted first.
    pub points: Vec<CalibrationPoint>,
}

/// True for path kinds that launch at a register (`regtoreg`, `regtoout`).
pub fn reg_launched(kind: &str) -> bool {
    kind.to_ascii_lowercase().starts_with("regto")
}

impl CalibrationProfile {
    /// Calibrated (platform-FO4) value of a structural FO4 of path `kind`.
    pub fn calibrate(&self, structural_fo4: f64, kind: &str) -> f64 {
        if structural_fo4 <= 0.0 {
            return 0.0;
        }
        self.slope * structural_fo4
            + if reg_launched(kind) {
                self.launch_fo4
            } else {
                0.0
            }
    }

    /// Refuse a profile fitted under other measurement semantics.
    pub fn check_measurement(&self, measurement: &str) -> Result<(), String> {
        if self.schema_version != CALIBRATION_SCHEMA {
            return Err(format!(
                "calibration schema {} (expected {CALIBRATION_SCHEMA})",
                self.schema_version
            ));
        }
        if self.measurement != measurement {
            return Err(format!(
                "calibration was fitted under {} but this report is {measurement}; refit it from a board and a {measurement} report",
                self.measurement
            ));
        }
        Ok(())
    }
}

fn median(v: &mut [f64]) -> f64 {
    v.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    quantile_sorted(v, 0.5)
}

fn quantile_sorted(sorted: &[f64], q: f64) -> f64 {
    if sorted.is_empty() {
        return f64::NAN;
    }
    let pos = q * (sorted.len() - 1) as f64;
    let lo = pos.floor() as usize;
    let hi = pos.ceil() as usize;
    sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo as f64)
}

fn ranks(v: &[f64]) -> Vec<f64> {
    let mut idx: Vec<usize> = (0..v.len()).collect();
    idx.sort_by(|&a, &b| v[a].partial_cmp(&v[b]).unwrap_or(std::cmp::Ordering::Equal));
    let mut r = vec![0.0; v.len()];
    let mut i = 0;
    while i < idx.len() {
        let mut j = i;
        while j + 1 < idx.len() && v[idx[j + 1]] == v[idx[i]] {
            j += 1;
        }
        let avg = (i + j) as f64 / 2.0;
        for k in i..=j {
            r[idx[k]] = avg;
        }
        i = j + 1;
    }
    r
}

fn pearson(a: &[f64], b: &[f64]) -> f64 {
    let n = a.len() as f64;
    if a.len() < 2 {
        return f64::NAN;
    }
    let ma = a.iter().sum::<f64>() / n;
    let mb = b.iter().sum::<f64>() / n;
    let mut num = 0.0;
    let mut da = 0.0;
    let mut db = 0.0;
    for (x, y) in a.iter().zip(b) {
        num += (x - ma) * (y - mb);
        da += (x - ma) * (x - ma);
        db += (y - mb) * (y - mb);
    }
    if da <= 0.0 || db <= 0.0 {
        return f64::NAN;
    }
    num / (da * db).sqrt()
}

/// Largest register-launch overhead a fit may assign, in platform FO4: a
/// minimum-size flop's clock-to-Q is a handful of FO4 (Nangate45 `DFFR_X1`
/// 0.09–0.15 ns ≈ 4–7 FO4 in the A144 path reports). A larger value would
/// be the fit absorbing model error into a constant.
pub const MAX_LAUNCH_FO4: f64 = 12.0;

/// Robust fit of `y ≈ slope · x + launch · r` (`r` = register-launched):
/// for each launch on a 0.25-FO4 grid up to [`MAX_LAUNCH_FO4`], the slope is
/// the median of `(y − launch·r) / x`; the pair with the smallest median
/// |log| residual wins (ties to the smaller launch). `None` when nothing
/// positive fits.
pub fn fit_scale_and_launch(points: &[(f64, f64, bool)]) -> Option<(f64, f64)> {
    let pts: Vec<&(f64, f64, bool)> = points.iter().filter(|p| p.0 > 1e-9 && p.1 > 0.0).collect();
    if pts.len() < 2 {
        return None;
    }
    let mut best: Option<(f64, f64, f64)> = None;
    let steps = (MAX_LAUNCH_FO4 / 0.25).round() as u32;
    for step in 0..=steps {
        let launch = step as f64 * 0.25;
        let mut ratios: Vec<f64> = pts
            .iter()
            .map(|(x, y, r)| (y - if *r { launch } else { 0.0 }) / x)
            .collect();
        let slope = median(&mut ratios);
        if !slope.is_finite() || slope <= 0.0 {
            continue;
        }
        let mut res: Vec<f64> = pts
            .iter()
            .map(|(x, y, r)| ((slope * x + if *r { launch } else { 0.0 }) / y).ln().abs())
            .collect();
        let score = median(&mut res);
        if best.is_none_or(|(_, _, s)| score + 1e-12 < s) {
            best = Some((slope, launch, score));
        }
    }
    best.map(|(s, l, _)| (s, l))
}

/// Fit a profile from an adjusted report's measured modules that carry a
/// structural value. `measurement` / `cost_model` identify the report the
/// structural values came from.
pub fn fit_profile(
    adjusted: &AdjustedReport,
    measurement: &str,
    cost_model: &str,
) -> Result<CalibrationProfile, String> {
    let rows: Vec<(&str, f64, f64, Option<String>)> = adjusted
        .modules
        .iter()
        .filter(|m| m.source == AdjustedSource::Measured && m.adjusted_fo4 > 0.0)
        .filter_map(|m| {
            m.structural_fo4.filter(|s| *s > 0.0).map(|s| {
                (
                    m.module.as_str(),
                    s,
                    m.adjusted_fo4,
                    m.structural_kind.clone(),
                )
            })
        })
        .collect();
    if rows.len() < MIN_CALIBRATION_POINTS {
        return Err(format!(
            "{} measured modules with a structural value; a calibration needs at least {MIN_CALIBRATION_POINTS}",
            rows.len()
        ));
    }
    let xyr: Vec<(f64, f64, bool)> = rows
        .iter()
        .map(|(_, s, a, k)| (*s, *a, k.as_deref().is_some_and(reg_launched)))
        .collect();
    let (slope, launch_fo4) = fit_scale_and_launch(&xyr)
        .ok_or_else(|| "degenerate structural values: no line to fit".to_string())?;
    let mut points: Vec<CalibrationPoint> = rows
        .iter()
        .map(|(m, s, a, k)| {
            let launched = k.as_deref().is_some_and(reg_launched);
            let c = slope * s + if launched { launch_fo4 } else { 0.0 };
            CalibrationPoint {
                module: (*m).to_string(),
                structural_fo4: *s,
                structural_kind: k.clone(),
                adjusted_fo4: *a,
                calibrated_fo4: c,
                residual_ratio: c / a,
            }
        })
        .collect();
    points.sort_by(|a, b| {
        b.adjusted_fo4
            .partial_cmp(&a.adjusted_fo4)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.module.cmp(&b.module))
    });
    let mut ratios: Vec<f64> = points.iter().map(|p| p.residual_ratio).collect();
    ratios.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let mut abs_log: Vec<f64> = ratios.iter().map(|r| r.ln().abs()).collect();
    let xs: Vec<f64> = rows.iter().map(|r| r.1).collect();
    let ys: Vec<f64> = rows.iter().map(|r| r.2).collect();
    let fit = CalibrationFit {
        method: "median-ratio scale + register launch (grid, min median |log|)".into(),
        n: points.len(),
        residual_median: quantile_sorted(&ratios, 0.5),
        residual_p25: quantile_sorted(&ratios, 0.25),
        residual_p75: quantile_sorted(&ratios, 0.75),
        log_mad: median(&mut abs_log),
        rank_correlation: pearson(&ranks(&xs), &ranks(&ys)),
    };
    Ok(CalibrationProfile {
        schema_version: CALIBRATION_SCHEMA.into(),
        disclaimer: "structural FO4 mapped onto measured platform FO4 by a robust line fit — an estimate between boards, not STA; measured rows decide closure".into(),
        platform: adjusted.platform.clone(),
        measurement: measurement.to_string(),
        cost_model: cost_model.to_string(),
        slope,
        launch_fo4,
        fit,
        points,
    })
}

/// Calibrated closure reading of a set of single-cycle structural path FO4s.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CalibratedClosure {
    /// Profile schema.
    pub schema_version: String,
    /// Platform name of the profile.
    pub platform: String,
    /// Platform FO4 (ps).
    pub platform_fo4_ps: f64,
    /// Line slope.
    pub slope: f64,
    /// Register-launch overhead.
    pub launch_fo4: f64,
    /// Budget in FO4 the calibrated values are compared with.
    pub budget_fo4: f64,
    /// Worst calibrated FO4 over single-cycle paths.
    pub worst_calibrated_fo4: f64,
    /// Path id of the worst.
    pub worst_path_id: Option<u32>,
    /// Paths whose calibrated FO4 exceeds the budget.
    pub failing_paths: usize,
    /// Calibrated worst within the budget.
    pub closes: bool,
    /// Frequency at which the budget equals the calibrated worst on the platform.
    pub implied_mhz_on_platform: Option<f64>,
    /// Same at the report's process FO4.
    pub implied_mhz_at_fo4_ps: Option<f64>,
    /// Typical per-module model error of the profile (`log_mad`).
    pub profile_log_mad: f64,
    /// Note.
    pub note: String,
}

/// Calibrated closure over `(path_id, structural_fo4, path_kind)`
/// single-cycle paths.
pub fn calibrated_closure<'a>(
    profile: &CalibrationProfile,
    paths: impl IntoIterator<Item = (u32, f64, &'a str)>,
    budget_fo4: f64,
    margin: f64,
    fo4_ps: f64,
) -> CalibratedClosure {
    let mut worst = 0.0_f64;
    let mut worst_id = None;
    let mut failing = 0usize;
    for (id, s, kind) in paths {
        let c = profile.calibrate(s, kind);
        if c > budget_fo4 {
            failing += 1;
        }
        if c > worst {
            worst = c;
            worst_id = Some(id);
        }
    }
    CalibratedClosure {
        schema_version: CALIBRATION_SCHEMA.into(),
        platform: profile.platform.name.clone(),
        platform_fo4_ps: profile.platform.fo4_ps,
        slope: profile.slope,
        launch_fo4: profile.launch_fo4,
        budget_fo4,
        worst_calibrated_fo4: worst,
        worst_path_id: worst_id,
        failing_paths: failing,
        closes: worst_id.is_some() && worst <= budget_fo4,
        implied_mhz_on_platform: implied_mhz(worst, profile.platform.fo4_ps, margin),
        implied_mhz_at_fo4_ps: implied_mhz(worst, fo4_ps, margin),
        profile_log_mad: profile.fit.log_mad,
        note: "structural × measured line fit, in platform FO4 — an estimate, not STA; the board's measured rows decide".into(),
    }
}

/// Human summary of a profile.
pub fn render_profile(p: &CalibrationProfile, rows: usize) -> String {
    let mut out = format!(
        "calibration on {} (FO4 {:.2} ps) for {} / {}: calibrated = {:.3} × structural (+ {:.2} when launched at a register); {} modules, residual calibrated/adjusted median {:.2} (p25 {:.2}, p75 {:.2}), |log| median {:.3}, rank correlation {:.2}\n",
        p.platform.name,
        p.platform.fo4_ps,
        p.measurement,
        p.cost_model,
        p.slope,
        p.launch_fo4,
        p.fit.n,
        p.fit.residual_median,
        p.fit.residual_p25,
        p.fit.residual_p75,
        p.fit.log_mad,
        p.fit.rank_correlation
    );
    out.push_str("module\tstructural_fo4\tkind\tadjusted_fo4\tcalibrated_fo4\tresidual\n");
    for pt in p.points.iter().take(rows) {
        out.push_str(&format!(
            "{}\t{:.1}\t{}\t{:.1}\t{:.1}\t{:.2}\n",
            pt.module,
            pt.structural_fo4,
            pt.structural_kind.as_deref().unwrap_or("-"),
            pt.adjusted_fo4,
            pt.calibrated_fo4,
            pt.residual_ratio
        ));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::adjusted::{adjust, MappedPath, StructuralModule};
    use std::collections::BTreeMap;

    fn platform() -> PlatformFo4 {
        PlatformFo4 {
            name: "lib".into(),
            fo4_ps: 20.0,
            method: "test".into(),
            cell: None,
        }
    }

    fn report(points: &[(f64, f64)]) -> AdjustedReport {
        report_kinds(
            &points
                .iter()
                .map(|(s, a)| (*s, *a, "regtoreg"))
                .collect::<Vec<_>>(),
        )
    }

    fn report_kinds(points: &[(f64, f64, &str)]) -> AdjustedReport {
        let mut structural = Vec::new();
        let mut board = BTreeMap::new();
        for (i, (s, a, kind)) in points.iter().enumerate() {
            let name = format!("m{i}");
            structural.push(StructuralModule {
                name: name.clone(),
                worst_fo4: Some(*s),
                worst_kind: Some((*kind).into()),
            });
            // adjusted = ns * 1000 / 20 → ns = adjusted * 0.02
            board.insert(
                name,
                MappedPath {
                    worst_ns: a * 0.02,
                    reg2reg_ns: None,
                    cells: None,
                },
            );
        }
        adjust(&structural, &board, &platform(), 10.0, 0.2, 20.0)
    }

    #[test]
    fn fit_recovers_scale_and_register_launch_and_ignores_an_outlier() {
        // register-launched modules carry a 6 FO4 clock-to-Q, ports do not
        let mut pts: Vec<(f64, f64, bool)> = (1..=12)
            .map(|i| {
                let x = i as f64 * 5.0;
                let r = i % 2 == 0;
                (x, 3.0 * x + if r { 6.0 } else { 0.0 }, r)
            })
            .collect();
        pts.push((10.0, 400.0, true)); // one module the model reads wrong
        let (s, l) = fit_scale_and_launch(&pts).unwrap();
        assert!((s - 3.0).abs() < 0.05, "slope {s}");
        assert!((l - 6.0).abs() <= 0.5, "launch {l}");
    }

    #[test]
    fn profile_fits_measured_modules_and_refuses_other_measurements() {
        let pts: Vec<(f64, f64, &str)> = (1..=10)
            .map(|i| {
                let x = i as f64 * 4.0;
                if i % 3 == 0 {
                    (x, 2.5 * x, "intoout")
                } else {
                    (x, 2.5 * x + 5.0, "regtoreg")
                }
            })
            .collect();
        let p = fit_profile(&report_kinds(&pts), "delay-vX", "fo4-v1").unwrap();
        assert!((p.slope - 2.5).abs() < 0.01, "slope {}", p.slope);
        assert!((p.launch_fo4 - 5.0).abs() < 0.3, "launch {}", p.launch_fo4);
        assert!(p.fit.log_mad < 0.01);
        assert!((p.calibrate(10.0, "regtoreg") - 30.0).abs() < 0.5);
        assert!((p.calibrate(10.0, "intoout") - 25.0).abs() < 0.2);
        assert!(p.check_measurement("delay-vX").is_ok());
        assert!(p.check_measurement("delay-vY").is_err());
        let c = calibrated_closure(
            &p,
            [(1, 10.0, "regtoreg"), (2, 1.0, "intoout")],
            10.0,
            0.2,
            20.0,
        );
        assert_eq!(c.worst_path_id, Some(1));
        assert_eq!(c.failing_paths, 1);
        assert!(!c.closes);
    }

    #[test]
    fn too_few_points_is_an_error() {
        let pts: Vec<(f64, f64)> = (1..=3).map(|i| (i as f64, i as f64)).collect();
        assert!(fit_profile(&report(&pts), "d", "c").is_err());
    }

    #[test]
    fn profile_round_trips_through_json() {
        let pts: Vec<(f64, f64)> = (1..=9).map(|i| (i as f64 * 3.0, i as f64 * 7.0)).collect();
        let p = fit_profile(&report(&pts), "delay-vX", "fo4-v1").unwrap();
        let back: CalibrationProfile =
            serde_json::from_str(&serde_json::to_string(&p).unwrap()).unwrap();
        assert!((back.slope - p.slope).abs() < 1e-12);
        assert_eq!(back.launch_fo4, p.launch_fo4);
        assert_eq!(back.measurement, p.measurement);
        assert_eq!(back.points.len(), p.points.len());
        assert!((back.calibrate(10.0, "regtoreg") - p.calibrate(10.0, "regtoreg")).abs() < 1e-9);
    }
}
