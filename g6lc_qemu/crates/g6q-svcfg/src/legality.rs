// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Configuration legality, mirrored from the design's own elaboration-time assertions.
//!
//! A configuration the RTL would refuse to elaborate must not produce a running
//! emulator. Without this, "it works under emulation" can be reported for a design that
//! does not build.
//!
//! # The distinction that makes this correct
//!
//! The design's assertions run on the **derived** configuration, after a build step has
//! filled in inferred fields. Several rules are therefore *not* checkable against the
//! source package, and naively mirroring them produces false failures. The clearest
//! example: an assertion that an enabled second-level cache has a non-zero size is
//! correct *after* inference, but real packages legitimately write size `0` meaning
//! "infer it" — asserting that rule on the source would fail a perfectly valid package.
//!
//! So rules are split:
//!
//! * [`Rule::User`] — checkable against the source package as written. Enforced.
//! * [`Rule::Derived`] — needs the build step's inference. Reported as **unchecked**,
//!   never as a pass and never as a failure.
//!
//! Claiming to have checked a derived rule would be worse than not checking it.

use crate::parse::Package;

/// Which configuration a rule can be evaluated against.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Rule {
    /// Evaluable against the source package.
    User,
    /// Requires inferred fields; not evaluable here.
    Derived,
}

/// Outcome for one legality rule.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Finding {
    /// Short rule name.
    pub rule: String,
    /// Whether it is a user-level or derived rule.
    pub kind: Rule,
    /// `Some(message)` when violated; `None` when satisfied or unchecked.
    pub violation: Option<String>,
}

impl Finding {
    fn ok(rule: &str) -> Self {
        Finding {
            rule: rule.into(),
            kind: Rule::User,
            violation: None,
        }
    }
    fn bad(rule: &str, msg: String) -> Self {
        Finding {
            rule: rule.into(),
            kind: Rule::User,
            violation: Some(msg),
        }
    }
    fn derived(rule: &str) -> Self {
        Finding {
            rule: rule.into(),
            kind: Rule::Derived,
            violation: None,
        }
    }
}

/// The result of validating a package.
#[derive(Debug, Clone, Default)]
pub struct Report {
    /// Every rule considered.
    pub findings: Vec<Finding>,
}

impl Report {
    /// Rules that were violated.
    pub fn violations(&self) -> Vec<&Finding> {
        self.findings
            .iter()
            .filter(|f| f.violation.is_some())
            .collect()
    }

    /// Whether the configuration is legal as far as source-level rules can tell.
    pub fn is_legal(&self) -> bool {
        self.violations().is_empty()
    }

    /// Rules that could not be evaluated without the design's own inference step.
    pub fn unchecked(&self) -> Vec<&str> {
        self.findings
            .iter()
            .filter(|f| f.kind == Rule::Derived)
            .map(|f| f.rule.as_str())
            .collect()
    }
}

fn is_pow2(n: i64) -> bool {
    n > 0 && (n & (n - 1)) == 0
}

/// Issue width after the design's own inference.
///
/// A source value of `0` means **auto**: two ports when superscalar issue is enabled,
/// otherwise one. Checking the raw field instead of the inferred one reports a violation
/// on packages that are perfectly valid — a real package writes `SuperscalarEn: 1` with
/// `NrIssuePorts: 0` and relies on exactly this rule.
pub fn effective_issue_ports(pkg: &Package) -> i64 {
    let raw = pkg.int_or("NrIssuePorts", 0);
    if raw != 0 {
        return raw;
    }
    if pkg.flag("SuperscalarEn") {
        2
    } else {
        1
    }
}

/// Commit width after the design's own inference.
///
/// Under superscalar issue an explicit width of two or more is kept as written — commit
/// narrower than issue is deliberately allowed — and only a width below two is raised.
pub fn effective_commit_ports(pkg: &Package) -> i64 {
    let raw = pkg.int_or("NrCommitPorts", 1);
    if !pkg.flag("SuperscalarEn") {
        return raw;
    }
    if raw >= 2 {
        return raw;
    }
    effective_issue_ports(pkg).max(2)
}

/// Validate a package against the source-level subset of the design's legality rules.
///
/// The `!(enabled && !prerequisite)` shape below is deliberate and is kept even though it
/// can be written more tersely: it mirrors the design's own assertions one for one, so a
/// reviewer can put the two side by side and check the transcription. Losing that
/// correspondence would make the rules unauditable, which matters more here than
/// brevity.
#[allow(clippy::nonminimal_bool)]
pub fn validate(pkg: &Package) -> Report {
    let mut r = Report::default();

    // --- sizes that must be powers of two (0 means "absent", which is legal) ---
    for field in [
        "BTBEntries",
        "BHTEntries",
        "BPTageTableEntries",
        "BPIndirectEntries",
        "SnoopFilterEntries",
        "CohInvalDepth",
        "L2MshrDepth",
        "L2DataBanks",
    ] {
        let v = pkg.int_or(field, 0);
        if v != 0 && !is_pow2(v) {
            r.findings.push(Finding::bad(
                field,
                format!("{field} = {v} is not a power of two"),
            ));
        } else {
            r.findings.push(Finding::ok(field));
        }
    }

    // --- predictor prerequisites ---
    let bp = pkg.enum_of("BPType").unwrap_or("").to_string();
    check(
        &mut r,
        "BPIndirectEn requires a BTB",
        !(pkg.flag("BPIndirectEn") && pkg.int_or("BTBEntries", 0) == 0),
        "indirect prediction is enabled but BTBEntries is 0",
    );
    check(
        &mut r,
        "TAGE requires tagged tables",
        !(bp == "TAGE_LITE" && pkg.int_or("BPTageTables", 0) == 0),
        "BPType is TAGE_LITE but BPTageTables is 0",
    );
    check(
        &mut r,
        "GSHARE requires history",
        !(bp == "GSHARE" && pkg.int_or("BHTEntries", 0) == 0),
        "BPType is GSHARE but BHTEntries is 0",
    );
    check(
        &mut r,
        "RASDepth > 0",
        pkg.int_or("RASDepth", 0) > 0,
        "RASDepth must be greater than zero",
    );
    check(
        &mut r,
        "BPGhistLen <= 64",
        pkg.int_or("BPGhistLen", 0) <= 64,
        "global history length exceeds 64",
    );
    check(
        &mut r,
        "BPTageTables <= 8",
        pkg.int_or("BPTageTables", 0) <= 8,
        "more than 8 tagged predictor components",
    );

    // --- issue width, evaluated after the documented `0 = auto` inference ---
    let raw_issue = pkg.int_or("NrIssuePorts", 0);
    let issue = effective_issue_ports(pkg);
    let commit = effective_commit_ports(pkg);
    let superscalar = pkg.flag("SuperscalarEn");
    check(
        &mut r,
        "explicit multi-issue requires SuperscalarEn",
        !(raw_issue > 1 && !superscalar),
        format!("NrIssuePorts = {raw_issue} with SuperscalarEn = 0"),
    );
    check(
        &mut r,
        "inferred issue width is at least one",
        issue >= 1,
        format!("inferred issue width {issue}"),
    );
    check(
        &mut r,
        "inferred commit width is at least one",
        commit >= 1,
        format!("inferred commit width {commit}"),
    );
    // Only meaningful when the scoreboard depth is stated; 0 means inferred.
    let sb = pkg.int_or("NrScoreboardEntries", 0);
    check(
        &mut r,
        "issue ports fit the scoreboard",
        sb == 0 || issue <= sb,
        format!("inferred issue width {issue} exceeds NrScoreboardEntries {sb}"),
    );

    // --- privilege and extension dependencies ---
    let rvs = pkg.flag("RVS");
    check(
        &mut r,
        "supervisor needs software interrupts",
        !(rvs && !pkg.flag("SoftwareInterruptEn")),
        "RVS = 1 with SoftwareInterruptEn = 0",
    );
    check(
        &mut r,
        "hypervisor needs supervisor",
        !(pkg.flag("RVH") && !rvs),
        "RVH = 1 with RVS = 0",
    );
    check(
        &mut r,
        "Sstc needs supervisor",
        !(pkg.flag("SstcEn") && !rvs),
        "SstcEn = 1 with RVS = 0",
    );
    check(
        &mut r,
        "Sscofpmf needs counters",
        !(pkg.flag("SscofpmfEn") && !pkg.flag("PerfCounterEn")),
        "SscofpmfEn = 1 with PerfCounterEn = 0",
    );
    check(
        &mut r,
        "Sscofpmf needs supervisor",
        !(pkg.flag("SscofpmfEn") && !rvs),
        "SscofpmfEn = 1 with RVS = 0",
    );
    check(
        &mut r,
        "Zacas needs atomics",
        !(pkg.flag("RVZacas") && !pkg.flag("RVA")),
        "RVZacas = 1 with RVA = 0",
    );
    check(
        &mut r,
        "Svpbmt needs an MMU",
        !(pkg.flag("SvpbmtEn") && !pkg.flag("MmuPresent")),
        "SvpbmtEn = 1 with MmuPresent = 0",
    );
    check(
        &mut r,
        "Svpbmt needs 64-bit",
        !(pkg.flag("SvpbmtEn") && pkg.int_or("XLEN", 64) == 32),
        "SvpbmtEn = 1 with XLEN = 32",
    );
    check(
        &mut r,
        "Zcmt needs an MMU",
        !(pkg.flag("RVZCMT") && !pkg.flag("MmuPresent")),
        "RVZCMT = 1 with MmuPresent = 0",
    );

    // --- threads and cores ---
    let harts = pkg.int_or("NrHarts", 1);
    let cores = pkg.int_or("NrCores", 1);
    check(
        &mut r,
        "NrHarts >= 1",
        harts >= 1,
        format!("NrHarts = {harts}"),
    );
    check(
        &mut r,
        "NrCores >= 1",
        cores >= 1,
        format!("NrCores = {cores}"),
    );
    check(
        &mut r,
        "multi-hart needs supervisor",
        !(harts > 1 && !rvs),
        "NrHarts > 1 with RVS = 0",
    );
    check(
        &mut r,
        "multi-hart needs an MMU",
        !(harts > 1 && !pkg.flag("MmuPresent")),
        "NrHarts > 1 with MmuPresent = 0",
    );
    check(
        &mut r,
        "multi-hart needs a fetch quantum",
        !(harts > 1 && pkg.int_or("SmtFetchQuantum", 0) == 0),
        "NrHarts > 1 with SmtFetchQuantum = 0",
    );
    check(
        &mut r,
        "multi-core needs supervisor",
        !(cores > 1 && !rvs),
        "NrCores > 1 with RVS = 0",
    );
    check(
        &mut r,
        "multi-core needs an MMU",
        !(cores > 1 && !pkg.flag("MmuPresent")),
        "NrCores > 1 with MmuPresent = 0",
    );
    let smt_policy = pkg.enum_of("SmtPolicy").unwrap_or("SMT_RR").to_string();
    check(
        &mut r,
        "SMT policy is legal",
        matches!(
            smt_policy.as_str(),
            "SMT_RR" | "SMT_SWITCH_ON_MISS" | "SMT_HYBRID"
        ),
        format!("unknown SmtPolicy {smt_policy}"),
    );
    let coh = pkg
        .enum_of("CohPolicy")
        .unwrap_or("COH_WRITE_INVAL")
        .to_string();
    check(
        &mut r,
        "coherence policy is legal",
        matches!(
            coh.as_str(),
            "COH_WRITE_INVAL" | "COH_BROADCAST" | "COH_FILTERED"
        ),
        format!("unknown CohPolicy {coh}"),
    );

    // --- mutually exclusive speculation planes ---
    check(
        &mut r,
        "slice and full out-of-order are exclusive",
        !(pkg.flag("SliceOoOEn") && pkg.flag("OoOEn")),
        "SliceOoOEn and OoOEn are both set",
    );

    // --- rules that need the design's own inference step (never claimed as checked) ---
    for rule in [
        "cache sizes after inference (0 means infer)",
        "fetch width legality",
        "scoreboard depth after derivation",
        "checkpoint depth vs in-flight window",
        "second-level line width vs first-level",
        "snoop filter entries after auto-sizing",
        "ALU count after derivation",
    ] {
        r.findings.push(Finding::derived(rule));
    }

    r
}

fn check(r: &mut Report, rule: &str, ok: bool, msg: impl Into<String>) {
    if ok {
        r.findings.push(Finding::ok(rule));
    } else {
        r.findings.push(Finding::bad(rule, msg.into()));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parse::read_package;

    fn pkg_from(members: &str) -> Package {
        read_package(&format!(
            "package p;\nlocalparam t cva6_cfg = '{{ {members} }};\nendpackage"
        ))
    }

    #[test]
    fn a_sane_configuration_is_legal() {
        let p = pkg_from(
            "XLEN: 64, RASDepth: 2, BTBEntries: 32, BHTEntries: 128, \
             BPType: config_pkg::TAGE_LITE, BPTageTables: 3, \
             NrIssuePorts: 1, NrCommitPorts: 1, NrScoreboardEntries: 16, \
             RVS: bit'(1), SoftwareInterruptEn: bit'(1), MmuPresent: bit'(1), \
             NrHarts: 1, NrCores: 1",
        );
        let r = validate(&p);
        assert!(r.is_legal(), "{:?}", r.violations());
    }

    #[test]
    fn a_non_power_of_two_table_is_rejected() {
        let p = pkg_from("RASDepth: 2, BTBEntries: 33");
        let r = validate(&p);
        assert!(!r.is_legal());
        assert!(r.violations().iter().any(|f| f.rule == "BTBEntries"));
    }

    #[test]
    fn zero_sized_tables_are_legal_because_zero_means_absent() {
        let p = pkg_from("RASDepth: 2, BTBEntries: 0, BHTEntries: 0, BPType: config_pkg::BHT");
        let r = validate(&p);
        assert!(r.is_legal(), "{:?}", r.violations());
    }

    #[test]
    fn indirect_prediction_without_a_btb_is_rejected() {
        let p = pkg_from("RASDepth: 2, BPIndirectEn: bit'(1), BTBEntries: 0");
        assert!(!validate(&p).is_legal());
    }

    #[test]
    fn tage_without_tagged_tables_is_rejected() {
        let p = pkg_from("RASDepth: 2, BPType: config_pkg::TAGE_LITE, BPTageTables: 0");
        let r = validate(&p);
        assert!(r.violations().iter().any(|f| f.rule.contains("TAGE")));
    }

    #[test]
    fn explicit_multi_issue_without_superscalar_is_rejected() {
        let p = pkg_from("RASDepth: 2, NrIssuePorts: 2, SuperscalarEn: bit'(0)");
        let r = validate(&p);
        assert!(r
            .violations()
            .iter()
            .any(|f| f.rule.contains("multi-issue")));
    }

    #[test]
    fn issue_width_zero_means_auto_and_is_not_a_violation() {
        // A real package writes SuperscalarEn=1 with NrIssuePorts=0 and NrCommitPorts=1
        // and relies on inference. Checking the raw fields fails a valid design.
        let p = pkg_from(
            "RASDepth: 2, SuperscalarEn: bit'(1), NrIssuePorts: 0, NrCommitPorts: 1, \
             NrScoreboardEntries: 8",
        );
        assert_eq!(effective_issue_ports(&p), 2);
        assert_eq!(effective_commit_ports(&p), 2);
        let r = validate(&p);
        assert!(r.is_legal(), "{:?}", r.violations());
    }

    #[test]
    fn commit_narrower_than_issue_is_kept_when_at_least_two() {
        // Deliberately allowed by the design; the reader must not "helpfully" raise it.
        let p = pkg_from("RASDepth: 2, SuperscalarEn: bit'(1), NrIssuePorts: 4, NrCommitPorts: 2");
        assert_eq!(effective_issue_ports(&p), 4);
        assert_eq!(effective_commit_ports(&p), 2);
        assert!(validate(&p).is_legal());
    }

    #[test]
    fn single_issue_infers_one_port() {
        let p = pkg_from("RASDepth: 2, SuperscalarEn: bit'(0), NrIssuePorts: 0");
        assert_eq!(effective_issue_ports(&p), 1);
    }

    #[test]
    fn extension_dependencies_are_enforced() {
        let p = pkg_from("RASDepth: 2, RVZacas: bit'(1), RVA: bit'(0)");
        assert!(validate(&p)
            .violations()
            .iter()
            .any(|f| f.rule.contains("Zacas")));

        let p = pkg_from("RASDepth: 2, RVH: bit'(1), RVS: bit'(0)");
        assert!(validate(&p)
            .violations()
            .iter()
            .any(|f| f.rule.contains("hypervisor")));

        let p = pkg_from("RASDepth: 2, SstcEn: bit'(1), RVS: bit'(0)");
        assert!(validate(&p)
            .violations()
            .iter()
            .any(|f| f.rule.contains("Sstc")));
    }

    #[test]
    fn multi_hart_without_supervisor_is_rejected() {
        let p = pkg_from("RASDepth: 2, NrHarts: 2, RVS: bit'(0), SmtFetchQuantum: 4");
        let r = validate(&p);
        assert!(r
            .violations()
            .iter()
            .any(|f| f.rule.contains("multi-hart needs supervisor")));
    }

    #[test]
    fn an_enabled_cache_with_size_zero_is_not_a_violation() {
        // Size 0 means "infer" in the source. Mirroring the post-inference assertion
        // here would fail real, valid packages -- the whole reason the rule split exists.
        let p = pkg_from("RASDepth: 2, L2En: bit'(1), L2ByteSize: 0, L2SetAssoc: 0");
        let r = validate(&p);
        assert!(r.is_legal(), "{:?}", r.violations());
        assert!(
            r.unchecked().iter().any(|u| u.contains("infer")),
            "the derived rule must be declared unchecked, not silently passed"
        );
    }

    #[test]
    fn derived_rules_are_reported_as_unchecked_never_as_passes() {
        let p = pkg_from("RASDepth: 2");
        let r = validate(&p);
        assert!(!r.unchecked().is_empty());
        for f in &r.findings {
            if f.kind == Rule::Derived {
                assert!(
                    f.violation.is_none(),
                    "a derived rule must never claim a failure"
                );
            }
        }
    }
}
