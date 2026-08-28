// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Configuration derivation — mirroring the design's own build step.
//!
//! A configuration package is **not** the configuration the design elaborates. The design
//! passes the written package through a build step that fills in inferred widths, forces
//! dependent flags, masks illegal combinations and raises floors. Everything downstream of
//! that step sees the *derived* values.
//!
//! That makes reading a package literally a correctness bug, not a simplification:
//!
//! * a package may enable an extension whose dependency is off, and the build step masks
//!   the extension away — an emulator that believed the package would execute instructions
//!   the elaborated hardware traps;
//! * a package may leave a width at `0` meaning "infer it", and an emulator that believed
//!   the package would model a machine with no issue ports at all;
//! * a package may imply an extension through another one, and an emulator that believed
//!   the package would refuse to emulate something the hardware really has.
//!
//! So this module applies the derivations the design documents, and **records every one it
//! applied** so the change is visible rather than silent. A derivation this module cannot
//! reproduce is not guessed: it stays absent and the corresponding legality rule is
//! already reported as unchecked by [`crate::legality`].
//!
//! The derivations are named after the fields they write, and each carries the reason, so
//! a reader can check them against the design's build step one by one.
//!
//! # Scope
//!
//! This module reproduces **corrections**: fields the package writes that the build step
//! then masks, implies, infers or raises. It deliberately does *not* add the build step's
//! **computed-only** fields — ones the package never writes, calculated from others —
//! because nothing downstream reads them yet and unconsumed fields are scaffolding. The
//! list of those omissions is in `architecture/INGEST.md` §2.0a so the gap is explicit.

use crate::parse::Package;
use crate::value::Value;

/// One derivation that was applied to a package.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Derivation {
    /// Field that was written.
    pub field: String,
    /// Value as the package wrote it, rendered for reporting.
    pub from: String,
    /// Value the design's build step produces.
    pub to: String,
    /// Why the build step changes it.
    pub reason: String,
}

fn set_bool(pkg: &mut Package, name: &str, value: bool) {
    if let Some(main) = pkg
        .struct_order
        .iter()
        .find(|n| pkg.structs.contains_key(*n))
    {
        let main = main.clone();
        // Write into whichever struct actually holds the configuration.
        let target = pkg
            .struct_order
            .iter()
            .filter(|n| pkg.structs.contains_key(*n))
            .max_by_key(|n| pkg.structs.get(*n).map_or(0, |s| s.len()))
            .cloned()
            .unwrap_or(main);
        if let Some(s) = pkg.structs.get_mut(&target) {
            s.insert(name.to_string(), Value::Bool(value));
        }
    }
}

fn set_int(pkg: &mut Package, name: &str, value: i64) {
    let target = pkg
        .struct_order
        .iter()
        .filter(|n| pkg.structs.contains_key(*n))
        .max_by_key(|n| pkg.structs.get(*n).map_or(0, |s| s.len()))
        .cloned();
    if let Some(target) = target {
        if let Some(s) = pkg.structs.get_mut(&target) {
            s.insert(name.to_string(), Value::Int(value));
        }
    }
}

/// Apply the design's documented configuration derivations in place.
///
/// Returns the list of derivations that changed something. A field the package already
/// states correctly produces no entry, so an empty result means the package as written
/// already matches what the design would elaborate.
pub fn derive(pkg: &mut Package) -> Vec<Derivation> {
    let mut applied = Vec::new();

    // --- dependent extensions, masked or implied ---------------------------------
    //
    // These are the ones that change the guest-visible ISA, so they matter most: an
    // emulator that gets them wrong either executes instructions the hardware traps, or
    // refuses instructions the hardware has.

    // Zacas depends on the atomics extension; without it the build step masks it away.
    if pkg.flag("RVZacas") && !pkg.flag("RVA") {
        set_bool(pkg, "RVZacas", false);
        applied.push(Derivation {
            field: "RVZacas".into(),
            from: "true".into(),
            to: "false".into(),
            reason: "Zacas requires the atomics extension; the build step masks it off \
                     when RVA is absent, so the elaborated design does not have it"
                .into(),
        });
    }

    // The design's performance-counter unit is the unprivileged HPM extension.
    if pkg.flag("PerfCounterEn") && !pkg.flag("RVZihpm") {
        set_bool(pkg, "RVZihpm", true);
        applied.push(Derivation {
            field: "RVZihpm".into(),
            from: "unset".into(),
            to: "true".into(),
            reason: "PerfCounterEn enables the HPM counter unit, which implies RVZihpm".into(),
        });
    }

    // The scalar-crypto extension implies the bit-manipulation extension.
    if pkg.flag("ZKN") && !pkg.flag("RVB") {
        set_bool(pkg, "RVB", true);
        applied.push(Derivation {
            field: "RVB".into(),
            from: "false".into(),
            to: "true".into(),
            reason: "ZKN requires the bit-manipulation extension, so the build step \
                     enables RVB even when the package leaves it off"
                .into(),
        });
    }

    // The accelerator seam is switched on by the vector extension, not independently.
    let rvv = pkg.flag("RVV");
    if rvv != pkg.flag("EnableAccelerator") {
        set_bool(pkg, "EnableAccelerator", rvv);
        applied.push(Derivation {
            field: "EnableAccelerator".into(),
            from: (!rvv).to_string(),
            to: rvv.to_string(),
            reason: "the accelerator seam is derived from the vector extension rather \
                     than configured on its own"
                .into(),
        });
    }

    // --- inferred widths ---------------------------------------------------------
    //
    // Zero means "infer" in a written package. Believing the zero would model a machine
    // that cannot issue anything, which is why `legality` refuses to treat these as
    // user-level rules.

    let superscalar = pkg.flag("SuperscalarEn");
    let issue_written = pkg.int_or("NrIssuePorts", 0);
    let issue = if issue_written == 0 {
        let inferred = if superscalar { 2 } else { 1 };
        set_int(pkg, "NrIssuePorts", inferred);
        applied.push(Derivation {
            field: "NrIssuePorts".into(),
            from: "0 (infer)".into(),
            to: inferred.to_string(),
            reason: "zero means infer; the build step derives the width from \
                     SuperscalarEn"
                .into(),
        });
        inferred
    } else {
        issue_written
    };

    // The arithmetic-unit count follows the issue width, and is forced to one when the
    // machine is not superscalar regardless of what the package asked for.
    let alus_written = pkg.int_or("NrALUs", 0);
    let alus = if superscalar {
        if issue >= 4 {
            4
        } else if issue >= 2 {
            2
        } else {
            1
        }
    } else {
        1
    };
    if alus_written != alus {
        set_int(pkg, "NrALUs", alus);
        applied.push(Derivation {
            field: "NrALUs".into(),
            from: alus_written.to_string(),
            to: alus.to_string(),
            reason: "the arithmetic-unit count is derived from the issue width, and is \
                     one on a non-superscalar machine"
                .into(),
        });
    }

    // The commit width is only corrected on a superscalar machine, and only when the
    // package asks for fewer than two ports. A package that writes a commit width
    // narrower than its issue width is left alone: the design permits that deliberately,
    // so "fixing" it here would model a machine the design does not build.
    if superscalar {
        let commit_written = pkg.int_or("NrCommitPorts", 0);
        if commit_written < 2 {
            let derived = if issue > 2 { issue } else { 2 };
            set_int(pkg, "NrCommitPorts", derived);
            applied.push(Derivation {
                field: "NrCommitPorts".into(),
                from: commit_written.to_string(),
                to: derived.to_string(),
                reason: "a superscalar machine commits at least two instructions; the \
                         build step raises a narrower request to the issue width or two, \
                         whichever is larger"
                    .into(),
            });
        }
    }

    // Bypass is only meaningful on a superscalar machine.
    if pkg.flag("ALUBypass") && !superscalar {
        set_bool(pkg, "ALUBypass", false);
        applied.push(Derivation {
            field: "ALUBypass".into(),
            from: "true".into(),
            to: "false".into(),
            reason: "bypass is forced off when the machine is not superscalar".into(),
        });
    }

    // The speculative store buffer is implied by any of the speculation modes.
    let spec = pkg.flag("SliceOoOEn") || pkg.flag("OoOEn") || pkg.flag("DeepSpecEn");
    if spec != pkg.flag("SpeculativeSb") {
        set_bool(pkg, "SpeculativeSb", spec);
        applied.push(Derivation {
            field: "SpeculativeSb".into(),
            from: (!spec).to_string(),
            to: spec.to_string(),
            reason: "the speculative store buffer is implied by the speculation mode \
                     rather than configured separately"
                .into(),
        });
    }

    // --- raised floors -----------------------------------------------------------

    // Deep speculation needs enough load buffering to keep several accesses in flight,
    // so the build step raises the entry count to a floor derived from the issue width.
    if pkg.flag("DeepSpecEn") {
        let written = pkg.int_or("NrLoadBufEntries", 0);
        let floor = (issue * 4).max(8);
        if written > 0 && written < floor {
            set_int(pkg, "NrLoadBufEntries", floor);
            applied.push(Derivation {
                field: "NrLoadBufEntries".into(),
                from: written.to_string(),
                to: floor.to_string(),
                reason: "deep speculation raises the load-buffer floor to four entries \
                         per issue port, minimum eight"
                    .into(),
            });
        }
    }

    // Accumulator banks are raised to the thread count so an accelerator-heavy thread
    // cannot starve the control thread.
    let harts = pkg.int_or("NrHarts", 1).max(1);
    let banks = pkg.int_or("AccBanks", 0);
    if banks > 0 && banks < harts {
        set_int(pkg, "AccBanks", harts);
        applied.push(Derivation {
            field: "AccBanks".into(),
            from: banks.to_string(),
            to: harts.to_string(),
            reason: "the build step raises accumulator banks to the thread count so an \
                     accelerator-heavy thread cannot starve the control thread"
                .into(),
        });
    }

    applied
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parse::read_package;

    fn pkg_from(fields: &str) -> Package {
        let text =
            format!("package p; localparam cva6_user_cfg_t Cfg = '{{ {fields} }};\nendpackage\n");
        read_package(&text)
    }

    fn names(d: &[Derivation]) -> Vec<&str> {
        d.iter().map(|x| x.field.as_str()).collect()
    }

    #[test]
    fn a_package_that_already_matches_the_build_step_is_left_alone() {
        // Single-issue, non-superscalar, one ALU, nothing implied: no derivation fires.
        let mut p = pkg_from("XLEN: 64, NrIssuePorts: 1, NrALUs: 1, NrHarts: 1");
        let d = derive(&mut p);
        assert!(d.is_empty(), "{d:?}");
    }

    #[test]
    fn an_extension_whose_dependency_is_absent_is_masked_off() {
        // Believing the package here would execute atomics the hardware traps.
        let mut p = pkg_from("RVZacas: bit'(1), RVA: bit'(0), NrIssuePorts: 1, NrALUs: 1");
        assert!(p.flag("RVZacas"), "written as enabled");
        let d = derive(&mut p);
        assert!(names(&d).contains(&"RVZacas"));
        assert!(
            !p.flag("RVZacas"),
            "the elaborated design does not have Zacas"
        );
    }

    #[test]
    fn a_dependency_is_kept_when_it_is_present() {
        let mut p = pkg_from("RVZacas: bit'(1), RVA: bit'(1), NrIssuePorts: 1, NrALUs: 1");
        let d = derive(&mut p);
        assert!(!names(&d).contains(&"RVZacas"));
        assert!(p.flag("RVZacas"));
    }

    #[test]
    fn an_implied_extension_is_enabled() {
        // Believing the package here would refuse instructions the hardware has.
        let mut p = pkg_from("ZKN: bit'(1), RVB: bit'(0), NrIssuePorts: 1, NrALUs: 1");
        let d = derive(&mut p);
        assert!(names(&d).contains(&"RVB"));
        assert!(p.flag("RVB"), "ZKN implies the bit-manipulation extension");
    }

    #[test]
    fn performance_counters_imply_zihpm() {
        let mut p =
            pkg_from("PerfCounterEn: bit'(1), SscofpmfEn: bit'(0), NrIssuePorts: 1, NrALUs: 1");
        let d = derive(&mut p);
        assert!(names(&d).contains(&"RVZihpm"));
        assert!(
            p.flag("RVZihpm"),
            "the counter unit implies the unprivileged HPM extension"
        );
    }

    #[test]
    fn a_zero_width_is_inferred_not_believed() {
        let mut p = pkg_from("SuperscalarEn: bit'(1), NrIssuePorts: 0");
        let d = derive(&mut p);
        assert!(names(&d).contains(&"NrIssuePorts"));
        assert_eq!(p.int_or("NrIssuePorts", 0), 2);
        // And the ALU count follows it.
        assert!(names(&d).contains(&"NrALUs"));
        assert_eq!(p.int_or("NrALUs", 0), 2);

        // Without superscalar the inference is one, not two.
        let mut p = pkg_from("NrIssuePorts: 0");
        derive(&mut p);
        assert_eq!(p.int_or("NrIssuePorts", 0), 1);
        assert_eq!(p.int_or("NrALUs", 0), 1);
    }

    #[test]
    fn a_wide_issue_width_raises_the_arithmetic_units() {
        let mut p = pkg_from("SuperscalarEn: bit'(1), NrIssuePorts: 4, NrALUs: 1");
        let d = derive(&mut p);
        assert!(names(&d).contains(&"NrALUs"));
        assert_eq!(p.int_or("NrALUs", 0), 4);
    }

    #[test]
    fn bypass_is_forced_off_without_superscalar() {
        let mut p = pkg_from("ALUBypass: bit'(1), NrIssuePorts: 1, NrALUs: 1");
        let d = derive(&mut p);
        assert!(names(&d).contains(&"ALUBypass"));
        assert!(!p.flag("ALUBypass"));
    }

    #[test]
    fn the_speculative_store_buffer_follows_the_speculation_mode() {
        let mut p = pkg_from("OoOEn: bit'(1), NrIssuePorts: 1, NrALUs: 1");
        let d = derive(&mut p);
        assert!(names(&d).contains(&"SpeculativeSb"));
        assert!(p.flag("SpeculativeSb"));
    }

    #[test]
    fn the_accelerator_seam_follows_the_vector_extension() {
        let mut p = pkg_from("RVV: bit'(1), NrIssuePorts: 1, NrALUs: 1");
        let d = derive(&mut p);
        assert!(names(&d).contains(&"EnableAccelerator"));
        assert!(p.flag("EnableAccelerator"));
    }

    #[test]
    fn accumulator_banks_are_raised_to_the_thread_count() {
        let mut p = pkg_from("NrHarts: 2, AccBanks: 1, NrIssuePorts: 1, NrALUs: 1");
        let d = derive(&mut p);
        assert!(names(&d).contains(&"AccBanks"));
        assert_eq!(p.int_or("AccBanks", 0), 2);

        // An absent field is not invented: zero means the package does not size it.
        let mut p = pkg_from("NrHarts: 2, NrIssuePorts: 1, NrALUs: 1");
        let d = derive(&mut p);
        assert!(!names(&d).contains(&"AccBanks"));
    }

    #[test]
    fn a_narrow_commit_width_is_raised_only_under_superscalar() {
        let mut p = pkg_from("SuperscalarEn: bit'(1), NrIssuePorts: 4, NrCommitPorts: 1");
        let d = derive(&mut p);
        assert!(names(&d).contains(&"NrCommitPorts"));
        assert_eq!(p.int_or("NrCommitPorts", 0), 4);

        // Not superscalar: the written value stands.
        let mut p = pkg_from("NrIssuePorts: 1, NrALUs: 1, NrCommitPorts: 1");
        let d = derive(&mut p);
        assert!(!names(&d).contains(&"NrCommitPorts"));
        assert_eq!(p.int_or("NrCommitPorts", 0), 1);
    }

    #[test]
    fn a_commit_width_narrower_than_issue_is_deliberate_and_left_alone() {
        // The design permits commit < issue when at least two, so correcting it here
        // would model a machine the design does not build.
        let mut p = pkg_from("SuperscalarEn: bit'(1), NrIssuePorts: 4, NrCommitPorts: 2");
        let d = derive(&mut p);
        assert!(!names(&d).contains(&"NrCommitPorts"), "{d:?}");
        assert_eq!(p.int_or("NrCommitPorts", 0), 2);
    }

    #[test]
    fn deep_speculation_raises_the_load_buffer_floor() {
        let mut p = pkg_from(
            "DeepSpecEn: bit'(1), SuperscalarEn: bit'(1), NrIssuePorts: 4, \
             NrCommitPorts: 4, NrLoadBufEntries: 2",
        );
        let d = derive(&mut p);
        assert!(names(&d).contains(&"NrLoadBufEntries"));
        assert_eq!(p.int_or("NrLoadBufEntries", 0), 16, "four per issue port");

        // The minimum floor applies to a narrow machine.
        let mut p = pkg_from("DeepSpecEn: bit'(1), NrIssuePorts: 1, NrLoadBufEntries: 2");
        derive(&mut p);
        assert_eq!(p.int_or("NrLoadBufEntries", 0), 8, "minimum of eight");

        // Without deep speculation the written value stands.
        let mut p = pkg_from("NrIssuePorts: 1, NrALUs: 1, NrLoadBufEntries: 2");
        let d = derive(&mut p);
        assert!(!names(&d).contains(&"NrLoadBufEntries"));
    }

    #[test]
    fn every_derivation_records_a_reason() {
        let mut p = pkg_from(
            "RVZacas: bit'(1), RVA: bit'(0), ZKN: bit'(1), RVB: bit'(0), \
             SuperscalarEn: bit'(1), NrIssuePorts: 0, NrHarts: 2, AccBanks: 1",
        );
        let d = derive(&mut p);
        assert!(d.len() >= 4, "{d:?}");
        for x in &d {
            assert!(!x.reason.is_empty(), "{x:?} has no reason");
            assert!(!x.field.is_empty());
            assert_ne!(x.from, x.to, "a recorded derivation must change something");
        }
    }

    #[test]
    fn derivation_is_idempotent() {
        // Applying it twice must not report changes the second time, or a caller could
        // not tell "already elaborated" from "needs elaborating".
        let mut p = pkg_from("SuperscalarEn: bit'(1), NrIssuePorts: 0, ZKN: bit'(1)");
        let first = derive(&mut p);
        assert!(!first.is_empty());
        let second = derive(&mut p);
        assert!(second.is_empty(), "{second:?}");
    }
}
