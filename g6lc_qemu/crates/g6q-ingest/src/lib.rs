// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! `g6q-ingest` — assembles a [`TargetModel`] from the three readers.
//!
//! This is where the package's thesis becomes executable:
//!
//! > The manifest decides what is **real**. The configuration decides what is
//! > **enabled**. The device tree decides what **software is told**.
//!
//! Ingest reads all three, compares them capability by capability against a
//! [data-driven table](capability), and produces the model plus the conformance report
//! over their disagreements. Everything downstream reads only the model.
//!
//! The crate sits above the readers and above the IR so that [`g6q_core`] stays
//! dependency-free: an emitter or an external consumer can use the model without pulling
//! in a SystemVerilog reader.

#![forbid(unsafe_code)]

pub mod capability;
pub mod matrix;

use capability::{Capability, ConfigProbe, FlistProbe, Table};
use g6q_core::conform::{Inputs as ConformInputs, Row};
use g6q_core::model::{Isa, Peripheral, Profile, Soc, TargetModel, Uarch};
use g6q_core::{parse_pmu_table, PmuTable};
use g6q_dts::Facts;
use g6q_flist::{Expansion, Presence};
use g6q_svcfg::{legality, Package, Value};

/// Everything ingest needs to build a model.
#[derive(Debug, Default)]
pub struct Sources {
    /// Target identifier.
    pub target_id: String,
    /// Which planes were read.
    pub plane: String,
    /// Machine profile.
    pub profile: Profile,
    /// Parsed configuration package.
    pub config: Option<Package>,
    /// Expanded build manifest.
    pub flist: Option<Expansion>,
    /// Device-tree facts.
    pub dts: Option<Facts>,
    /// Capability table; the default is used when absent.
    pub table: Option<Table>,
    /// `(path, sha256-or-marker)` provenance entries.
    pub sources: Vec<(String, String)>,
    /// Command-line overrides as `(field, value, origin)`.
    pub overrides: Vec<(String, String, String)>,
}

/// Whether the configuration enables a capability.
///
/// Returns `None` when the field is absent — which is *not* the same as disabled for
/// reporting purposes, but is treated as disabled, since a design without the field
/// genuinely lacks the capability.
pub(crate) fn config_enabled(pkg: &Package, probe: &ConfigProbe) -> (bool, bool) {
    let value = match probe {
        ConfigProbe::Field(f) => pkg.field(f),
        ConfigProbe::Nested(o, i) => pkg.nested(o, i),
    };
    match value {
        Some(v) if v.is_unresolved() => (false, true),
        Some(v) => (v.as_bool().unwrap_or(false), false),
        None => (false, false),
    }
}

/// Whether the implementing RTL is compiled, and the evidence for the answer.
pub(crate) fn flist_present(
    exp: Option<&Expansion>,
    probe: &FlistProbe,
    enabled: bool,
) -> (Presence, String) {
    match probe {
        // No separate compilation unit: the capability is as present as its enable bit.
        FlistProbe::Intrinsic => (
            if enabled {
                Presence::Present
            } else {
                Presence::Absent
            },
            "no separate compilation unit".to_string(),
        ),
        FlistProbe::Unit {
            implementing,
            stubs,
        } => {
            let Some(exp) = exp else {
                // Without a manifest there is no evidence either way. Say so rather than
                // letting the configuration stand in for the build.
                return (
                    Presence::Unknown,
                    "no manifest supplied; compilation cannot be confirmed".into(),
                );
            };
            let refs: Vec<&str> = implementing.iter().map(String::as_str).collect();
            let stub_refs: Vec<&str> = stubs.iter().map(String::as_str).collect();
            let m = g6q_flist::membership(exp, "", &refs, &stub_refs);
            (m.presence, m.evidence)
        }
    }
}

/// Whether the device tree advertises a capability.
pub(crate) fn dts_declared(facts: Option<&Facts>, cap: &Capability) -> Option<bool> {
    let facts = facts?;
    if cap.dts_tokens.is_empty() && cap.dts_node.is_none() {
        return None; // nothing the tree could say
    }
    let by_token = cap.dts_tokens.iter().any(|t| facts.declares(t));
    let by_node = cap
        .dts_node
        .as_deref()
        .map(|n| facts.has_device(n))
        .unwrap_or(false);
    Some(by_token || by_node)
}

/// Build the model.
pub fn assemble(src: &Sources) -> TargetModel {
    let table = src.table.clone().unwrap_or_else(Table::default_table);
    let mut model = TargetModel::new(&src.target_id);
    model.plane = if src.plane.is_empty() {
        "soc".into()
    } else {
        src.plane.clone()
    };
    model.profile = src.profile;

    model.provenance.sources = src.sources.clone();
    for (field, value, origin) in &src.overrides {
        model
            .provenance
            .overrides
            .push((field.clone(), value.clone(), origin.clone()));
        model.mark_unfaithful();
    }
    if let Some(exp) = &src.flist {
        model.provenance.defines = exp.defines.clone();
    }

    // Elaborate the configuration before anything reads it.
    //
    // The written package is not the configuration the design builds: dependent flags are
    // masked or implied, zero widths are inferred, and floors are raised. Reading the
    // package literally would model a machine the design does not elaborate -- in the
    // worst case advertising an extension whose dependency is off, which is a
    // guest-visible lie. See `g6q_svcfg::derive`.
    let elaborated = src.config.clone().map(|mut pkg| {
        let applied = g6q_svcfg::derive(&mut pkg);
        (pkg, applied)
    });
    let config = elaborated.as_ref().map(|(pkg, _)| pkg);
    if let Some((_, applied)) = &elaborated {
        for d in applied {
            // Recorded, not treated as an override: a derivation is the design's own
            // behaviour and does not make the machine unfaithful.
            model.provenance.derivations.push((
                d.field.clone(),
                format!("{} -> {}", d.from, d.to),
                d.reason.clone(),
            ));
        }
    }

    if let Some(pkg) = config {
        model.isa = build_isa(Some(pkg), src.dts.as_ref(), &table);
        model.soc = build_soc(pkg, src.dts.as_ref(), src.flist.as_ref());
        model.uarch = build_uarch(pkg);
        model.pmu = build_pmu(src.flist.as_ref());
    } else if let Some(facts) = &src.dts {
        // Device tree only: still worth a model, but nothing to cross-check against.
        model.isa = build_isa(None, Some(facts), &table);
        model.soc = soc_from_dts(facts);
    }

    // --- conformance ------------------------------------------------------------
    for cap in &table.entries {
        let Some(pkg) = config else {
            continue;
        };
        let (enabled, unresolved) = config_enabled(pkg, &cap.config);
        let (presence, evidence) = flist_present(src.flist.as_ref(), &cap.flist, enabled);
        let present = presence == Presence::Present;
        let declared = dts_declared(src.dts.as_ref(), cap);

        // A capability the tree cannot express is not "undeclared"; it is simply not a
        // device-tree matter. Treat the tree as agreeing so the verdict reflects the two
        // inputs that do have an opinion.
        let declared_for_verdict = declared.unwrap_or(enabled && present);

        let mut row = Row::classify(
            &cap.name,
            ConformInputs::new(enabled, present, declared_for_verdict),
        );
        row.note = format!(
            "{} | config {} = {} | flist: {} | dts: {}",
            row.note,
            cap.config.describe(),
            if unresolved {
                "unresolved".to_string()
            } else {
                enabled.to_string()
            },
            evidence,
            match declared {
                Some(true) => "advertised",
                Some(false) => "not advertised",
                None => "not expressible",
            }
        );
        if unresolved {
            row.verdict = g6q_core::Verdict::Unresolved;
            row.note = format!("configuration field could not be read; {}", row.note);
        } else if presence == Presence::Unknown && enabled {
            // Not found, but the manifest could not be fully read. "Could not tell" must
            // never render as "is a stub": one is a gap in the inputs, the other is a
            // claim about the design, and confusing them is how a tooling problem gets
            // reported as a hardware finding.
            row.verdict = g6q_core::Verdict::Unresolved;
        }
        for (field, _, _) in &src.overrides {
            if cap.config.describe().contains(field.as_str()) {
                row = row.synthetic("--cfg-override");
            }
        }
        model.conformance.push(row);
    }

    // Topology findings come last so a reader sees capability disagreements first, then
    // the arithmetic ones. They are derived from the assembled model rather than from a
    // reader, because they are a comparison *between* inputs.
    for row in model.topology_rows() {
        model.conformance.push(row);
    }

    model
}

fn build_isa(pkg: Option<&Package>, facts: Option<&Facts>, table: &Table) -> Isa {
    let xlen = pkg.map_or(64, |p| p.int_or("XLEN", 64)) as u32;
    let mut isa = Isa {
        xlen,
        base: format!("rv{xlen}i"),
        isa_string: facts.and_then(|f| f.isa_string.clone()).unwrap_or_default(),
        mmu_mode: facts.and_then(|f| f.mmu_mode.clone()),
        timebase_hz: facts.map_or(1_000_000, |f| f.timebase_hz),
        extensions: Vec::new(),
        ..Default::default()
    };
    if let Some(b) = facts.and_then(|f| f.isa_base.clone()) {
        isa.base = b;
    }
    // One entry per capability that has a device-tree token: this is the ISA surface.
    for cap in &table.entries {
        if cap.dts_tokens.is_empty() {
            continue;
        }
        let (enabled, unresolved) = pkg
            .map(|p| config_enabled(p, &cap.config))
            .unwrap_or((false, false));
        let verdict = if unresolved {
            "unresolved"
        } else if enabled {
            "live"
        } else {
            "absent"
        };
        for token in &cap.dts_tokens {
            isa.extensions.push((token.clone(), verdict.to_string()));
        }
    }

    // Tokens the device tree actually advertises to software are also part of the ISA
    // surface, even if no capability row names them yet. This keeps base extensions such
    // as `i`/`m`/`zicsr` in the model and avoids an empty MISA mask in generated QEMU CPUs.
    if let Some(facts) = facts {
        for token in facts.extensions.tokens() {
            if let Some((_, verdict)) = isa.extensions.iter_mut().find(|(t, _)| t == token) {
                if verdict == "absent" || verdict == "unresolved" {
                    *verdict = "live".to_string();
                }
            } else {
                isa.extensions.push((token.clone(), "live".to_string()));
            }
        }
    }

    // C10: derive MMU geometry from the advertised mode and xlen. If the design has an
    // address-translation mode, the page-table walk is fully determined by the spec; if
    // not, the MMU is bare and all geometry fields stay at zero.
    derive_mmu_geometry(&mut isa);

    // An MMU in sv39/sv48 mode implies S-mode for software-visible MISA.
    if let Some(mmu) = isa.mmu_mode.as_deref() {
        if (mmu == "sv39" || mmu == "sv48") && !isa.extensions.iter().any(|(t, _)| t == "s") {
            isa.extensions.push(("s".to_string(), "live".to_string()));
        }
    }

    isa.extensions.sort();
    isa.extensions.dedup_by(|a, b| a.0 == b.0);
    isa
}

/// C10: set the MMU geometry fields from the advertised `mmu_mode` and `xlen`.
///
/// The values are those defined by the RISC-V privileged spec: Sv32, Sv39, and Sv48.
/// A bare or unknown mode leaves the geometry at zero so callers see "no MMU".
fn derive_mmu_geometry(isa: &mut Isa) {
    let Some(mmu) = isa.mmu_mode.as_deref() else {
        return;
    };
    match mmu {
        "sv32" if isa.xlen == 32 => {
            isa.satp_mode = 1;
            isa.vaddr_bits = 32;
            isa.paddr_bits = 34;
            isa.page_table_levels = 2;
            isa.vpn_bits = 10;
        }
        "sv39" if isa.xlen == 64 => {
            isa.satp_mode = 8;
            isa.vaddr_bits = 39;
            isa.paddr_bits = 56;
            isa.page_table_levels = 3;
            isa.vpn_bits = 9;
        }
        "sv48" if isa.xlen == 64 => {
            isa.satp_mode = 9;
            isa.vaddr_bits = 48;
            isa.paddr_bits = 56;
            isa.page_table_levels = 4;
            isa.vpn_bits = 9;
        }
        _ => {
            // Unknown or mismatched mode: leave geometry zero and preserve the name as
            // unresolved rather than inventing numbers.
        }
    }
}

fn build_soc(pkg: &Package, facts: Option<&Facts>, flist: Option<&g6q_flist::Expansion>) -> Soc {
    let mut soc = facts.map(soc_from_dts).unwrap_or_default();
    let harts = pkg.int_or("NrHarts", 1).max(1) as u32;
    let cores = pkg.int_or("NrCores", 1).max(1) as u32;
    // What the design has, versus what the tree tells software it has.
    soc.harts_declared = facts.map(|f| f.cpu_count);
    soc.harts_total = harts * cores;
    if soc.cores.is_none() {
        soc.cores = Some(cores);
    }
    if soc.threads_per_core.is_none() {
        soc.threads_per_core = Some(harts);
    }
    if soc.contexts_per_hart == 0 {
        // Two contexts per hart (machine and supervisor) is the shape every interrupt
        // controller in this family uses; the tree does not state it directly.
        soc.contexts_per_hart = 2;
    }
    soc.ai_island = flist.and_then(build_ai_island_model);
    soc
}

fn build_ai_island_model(flist: &g6q_flist::Expansion) -> Option<g6q_core::model::AiIslandModel> {
    let cfg_path = flist
        .files
        .iter()
        .find(|f| f.ends_with("g6lc_ai_island_cfg_pkg.sv"))?;
    let desc_path = flist
        .files
        .iter()
        .find(|f| f.ends_with("g6lc_ai_desc_pkg.sv"))?;
    let instr_path = flist
        .files
        .iter()
        .find(|f| f.ends_with("g6lc_ai_instr_pkg.sv"))?;

    let cfg_text = std::fs::read_to_string(cfg_path).ok()?;
    let desc_text = std::fs::read_to_string(desc_path).ok()?;
    let instr_text = std::fs::read_to_string(instr_path).ok()?;

    let config = g6q_diag::ai_cfg::parse_ai_island_cfg_pkg(&cfg_text).ok()?;
    let desc_layout = g6q_diag::ai_desc::parse_ai_desc_pkg(&desc_text).ok()?;
    let instr_set = g6q_diag::ai_instr::parse_ai_instr_pkg(&instr_text).ok()?;

    Some(g6q_core::model::AiIslandModel {
        config,
        desc_layout,
        instr_set,
    })
}

fn build_uarch(pkg: &Package) -> Uarch {
    let mut uarch = Uarch::default();
    let Some((_, cfg)) = pkg.main_config() else {
        return uarch;
    };
    for (name, value) in cfg {
        let json = match value {
            Value::Int(i) => g6q_core::Json::Int(*i),
            Value::Bool(b) => g6q_core::Json::Bool(*b),
            Value::Enum(s) => g6q_core::Json::Str(s.clone()),
            _ => continue,
        };
        uarch.raw.insert(name.clone(), json);
    }
    uarch
}

fn build_pmu(flist: Option<&Expansion>) -> PmuTable {
    let Some(flist) = flist else {
        return PmuTable::default();
    };
    let perf_path = find_file(flist, "perf_counters.sv");
    let ariane_path = find_file(flist, "ariane_pkg.sv");
    let perf_text = perf_path
        .and_then(|p| std::fs::read_to_string(p).ok())
        .unwrap_or_default();
    let ariane_text = ariane_path
        .and_then(|p| std::fs::read_to_string(p).ok())
        .unwrap_or_default();
    parse_pmu_table(&perf_text, &ariane_text)
}

fn find_file<'a>(flist: &'a Expansion, name: &str) -> Option<&'a str> {
    flist
        .files
        .iter()
        .find(|f| std::path::Path::new(f).file_name().and_then(|s| s.to_str()) == Some(name))
        .map(|s| s.as_str())
}

fn soc_from_dts(facts: &Facts) -> Soc {
    let mut soc = Soc {
        dram: facts.memory,
        intc_sources: facts.intc_sources.unwrap_or(0),
        // Contexts the board actually wires. The controller's hardware capacity lives in
        // the design's SoC package, which this plane does not read; leaving it at zero
        // makes the model say "unknown" rather than invent a limit.
        intc_targets: facts.intc_contexts_wired.unwrap_or(0),
        contexts_per_hart: 2,
        harts_total: facts.cpu_count,
        cores: facts.cores,
        threads_per_core: facts.threads_per_core,
        bootargs: facts.bootargs.clone(),
        stdout_path: facts.stdout_path.clone(),
        ..Soc::default()
    };
    for d in &facts.devices {
        soc.peripherals.push(Peripheral {
            id: d.name.clone(),
            base: d.base.unwrap_or(0),
            len: d.len.unwrap_or(0),
            model: d.compatible.clone(),
            irq: d.irq,
            reg_shift: d.reg_shift,
            reg_io_width: d.reg_io_width,
            clock_frequency: d.clock_frequency,
            current_speed: d.current_speed,
        });
    }
    soc.peripherals
        .sort_by(|a, b| a.base.cmp(&b.base).then(a.id.cmp(&b.id)));
    soc
}

/// Validate a configuration package against the source-level legality rules.
///
/// Re-exported so a caller does not need to depend on the reader crate directly.
pub fn validate_config(pkg: &Package) -> legality::Report {
    legality::validate(pkg)
}

/// Effective issue and commit widths after the design's own inference.
pub fn effective_widths(pkg: &Package) -> (i64, i64) {
    (
        legality::effective_issue_ports(pkg),
        legality::effective_commit_ports(pkg),
    )
}

/// A short human summary of a configuration field, for reports.
pub fn describe_field(pkg: &Package, name: &str) -> String {
    pkg.field(name)
        .map(Value::describe)
        .unwrap_or_else(|| "<absent>".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use g6q_core::Verdict;
    use g6q_svcfg::read_package;

    fn pkg(members: &str) -> Package {
        read_package(&format!(
            "package p;\nlocalparam t cva6_cfg = '{{ {members} }};\nendpackage"
        ))
    }

    fn facts_from(dts: &str) -> Facts {
        g6q_dts::extract(&g6q_dts::parse(dts))
    }

    fn table() -> Table {
        capability::parse(
            "[vector]\nconfig = RVV\nimpl = vendor/ara/\nstub = decoder_stub\ndts = v\n\
             [hypervisor]\nconfig = RVH\ndts = h\n\
             [cas-atomics]\nconfig = RVZacas\ndts = zacas\n",
        )
    }

    fn verdict(model: &TargetModel, cap: &str) -> Verdict {
        model
            .conformance
            .rows
            .iter()
            .find(|r| r.capability == cap)
            .unwrap_or_else(|| panic!("no row for {cap}"))
            .verdict
    }

    #[test]
    fn all_three_agreeing_is_live() {
        let src = Sources {
            target_id: "t".into(),
            config: Some(pkg("RVZacas: bit'(1), RVA: bit'(1)")),
            flist: Some(Expansion::default()),
            dts: Some(facts_from(
                "/ { cpus { cpu@0 { riscv,isa-extensions = \"zacas\"; }; }; };",
            )),
            table: Some(table()),
            ..Sources::default()
        };
        let m = assemble(&src);
        assert_eq!(verdict(&m, "cas-atomics"), Verdict::Live);
    }

    #[test]
    fn enabled_unit_absent_from_the_manifest_is_a_stub() {
        // The canonical case: the configuration turns the vector unit on, the vector
        // manifest is not in the build, and the tree still advertises it to software.
        let src = Sources {
            target_id: "t".into(),
            config: Some(pkg("RVV: bit'(1)")),
            flist: Some(Expansion {
                files: vec!["/p/core/decoder_stub.sv".into()],
                ..Expansion::default()
            }),
            dts: Some(facts_from(
                "/ { cpus { cpu@0 { riscv,isa-extensions = \"v\"; }; }; };",
            )),
            table: Some(table()),
            ..Sources::default()
        };
        let m = assemble(&src);
        assert_eq!(verdict(&m, "vector"), Verdict::Stub);
        let row = m
            .conformance
            .rows
            .iter()
            .find(|r| r.capability == "vector")
            .unwrap();
        assert!(row.also.contains(&Verdict::Overdeclared), "{row:?}");
        assert!(row.note.contains("stub"), "{}", row.note);
        assert!(!m.conformance.passes_strict());
    }

    #[test]
    fn live_in_rtl_but_absent_from_the_tree_is_undeclared() {
        let src = Sources {
            target_id: "t".into(),
            config: Some(pkg("RVH: bit'(1)")),
            flist: Some(Expansion::default()),
            dts: Some(facts_from(
                "/ { cpus { cpu@0 { riscv,isa-extensions = \"i\"; }; }; };",
            )),
            table: Some(table()),
            ..Sources::default()
        };
        assert_eq!(verdict(&assemble(&src), "hypervisor"), Verdict::Undeclared);
    }

    #[test]
    fn advertised_but_disabled_is_overdeclared_and_blocks() {
        let src = Sources {
            target_id: "t".into(),
            config: Some(pkg("RVH: bit'(0)")),
            flist: Some(Expansion::default()),
            dts: Some(facts_from(
                "/ { cpus { cpu@0 { riscv,isa-extensions = \"h\"; }; }; };",
            )),
            table: Some(table()),
            ..Sources::default()
        };
        let m = assemble(&src);
        assert_eq!(verdict(&m, "hypervisor"), Verdict::Overdeclared);
        assert!(!m.conformance.passes_strict());
    }

    #[test]
    fn an_unreadable_configuration_field_is_unresolved_not_disabled() {
        let src = Sources {
            target_id: "t".into(),
            config: Some(pkg("RVH: Something * 2")),
            flist: Some(Expansion::default()),
            table: Some(table()),
            ..Sources::default()
        };
        let m = assemble(&src);
        assert_eq!(verdict(&m, "hypervisor"), Verdict::Unresolved);
        assert!(!m.conformance.passes_strict());
    }

    #[test]
    fn an_override_taints_the_model_and_its_row() {
        let src = Sources {
            target_id: "t".into(),
            config: Some(pkg("RVH: bit'(1)")),
            flist: Some(Expansion::default()),
            table: Some(table()),
            overrides: vec![("RVH".into(), "1".into(), "--cfg-override".into())],
            ..Sources::default()
        };
        let m = assemble(&src);
        assert!(!m.faithful, "an override must clear faithfulness");
        assert!(!m.diagnosable());
        assert_eq!(verdict(&m, "hypervisor"), Verdict::Synthetic);
    }

    #[test]
    fn the_model_reflects_the_elaborated_configuration_not_the_written_one() {
        // Zacas written as enabled, but its dependency is off. The design's build step
        // masks it away, so the elaborated machine does not have it -- and an emulator
        // that believed the package would execute atomics the hardware traps.
        let src = Sources {
            target_id: "t".into(),
            config: Some(pkg("RVZacas: bit'(1), RVA: bit'(0)")),
            ..Sources::default()
        };
        let m = assemble(&src);

        // The derivation is recorded, with a reason, and does not taint the model.
        let d = &m.provenance.derivations;
        assert!(
            d.iter()
                .any(|(f, c, r)| f == "RVZacas" && c.contains("false") && r.contains("atomics")),
            "{d:?}"
        );
        assert!(
            m.faithful,
            "a derivation is the design's own behaviour, not an override"
        );

        // And it reached the ISA surface: the extension must not be advertised as live.
        let zacas = m
            .isa
            .extensions
            .iter()
            .find(|(t, _)| t == "zacas")
            .map(|(_, v)| v.as_str());
        assert_ne!(
            zacas,
            Some("live"),
            "the elaborated design has no Zacas, so nothing may report it live"
        );
    }

    #[test]
    fn a_package_needing_no_derivation_records_none() {
        let src = Sources {
            target_id: "t".into(),
            config: Some(pkg("NrIssuePorts: 1, NrALUs: 1, NrHarts: 1")),
            ..Sources::default()
        };
        let m = assemble(&src);
        assert!(
            m.provenance.derivations.is_empty(),
            "{:?}",
            m.provenance.derivations
        );
    }

    #[test]
    fn soc_facts_come_from_the_tree_and_hart_count_from_the_configuration() {
        let src = Sources {
            target_id: "t".into(),
            config: Some(pkg("NrHarts: 2, NrCores: 4")),
            dts: Some(facts_from(
                "/ { #address-cells = <2>; #size-cells = <2>; \
                 memory@80000000 { reg = <0x0 0x80000000 0x0 0x40000000>; }; \
                 soc { #address-cells = <2>; #size-cells = <2>; \
                   uart@10000000 { compatible = \"ns16550a\"; reg = <0x0 0x10000000 0x0 0x1000>; }; \
                   intc@c000000 { riscv,ndev = <30>; reg = <0x0 0xc000000 0x0 0x1000>; }; }; };",
            )),
            table: Some(table()),
            ..Sources::default()
        };
        let m = assemble(&src);
        assert_eq!(m.soc.harts_total, 8, "cores times threads per core");
        assert_eq!(m.soc.dram, Some((0x8000_0000, 0x4000_0000)));
        assert_eq!(m.soc.intc_sources, 30);
        assert_eq!(m.soc.peripherals.len(), 2);
        assert!(m.soc.overlapping().is_empty());
    }

    #[test]
    fn an_incomplete_manifest_yields_unresolved_not_stub() {
        // "Could not tell" must never render as "is a stub": one is a gap in the inputs,
        // the other is a claim about the design.
        let src = Sources {
            target_id: "t".into(),
            config: Some(pkg("RVV: bit'(1)")),
            flist: Some(Expansion {
                files: vec!["/p/core/other.sv".into()],
                missing: vec!["/p/nested.f: not found".into()],
                ..Expansion::default()
            }),
            table: Some(table()),
            ..Sources::default()
        };
        let m = assemble(&src);
        assert_eq!(verdict(&m, "vector"), Verdict::Unresolved);
        assert!(!m.conformance.passes_strict());
    }

    #[test]
    fn no_manifest_at_all_is_also_unresolved_for_a_compiled_unit() {
        let src = Sources {
            target_id: "t".into(),
            config: Some(pkg("RVV: bit'(1)")),
            flist: None,
            table: Some(table()),
            ..Sources::default()
        };
        assert_eq!(verdict(&assemble(&src), "vector"), Verdict::Unresolved);
    }

    #[test]
    fn intrinsic_capabilities_are_never_reported_as_stubs() {
        // Extensions living in always-compiled logic must not be judged by manifest
        // membership, or every one of them would look like a stub.
        let src = Sources {
            target_id: "t".into(),
            config: Some(pkg("RVZacas: bit'(1)")),
            flist: Some(Expansion::default()), // empty manifest
            table: Some(table()),
            ..Sources::default()
        };
        assert_ne!(verdict(&assemble(&src), "cas-atomics"), Verdict::Stub);
    }

    #[test]
    fn assembly_is_deterministic() {
        let build = || {
            let src = Sources {
                target_id: "t".into(),
                config: Some(pkg("RVV: bit'(1), RVH: bit'(1)")),
                flist: Some(Expansion::default()),
                table: Some(table()),
                ..Sources::default()
            };
            assemble(&src).to_json().to_pretty()
        };
        assert_eq!(build(), build());
    }
}
