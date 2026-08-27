// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! `g6lc-qemu` — the command-line tool.
//!
//! The full option surface is specified in `architecture/CLI.md`. At stage Q0 the verbs
//! are registered and self-describing but not implemented: each one reports the stage
//! that will deliver it rather than pretending to work. That is deliberate — a verb that
//! silently does nothing is worse than one that says it is not built yet.

#![forbid(unsafe_code)]
#![allow(clippy::items_after_test_module)]

mod args;
mod resolve;

use args::Args;
use g6q_core::model::Profile;
use g6q_core::{Inputs, Json, Report, Row, TargetModel, Verdict, SCHEMA_VERSION, STAGE};
use g6q_vm::device::{Clint, Plic, Uart};
use g6q_vm::mem::{Device, DeviceKind, PhysMem, Region};
use g6q_vm::Hart;

/// Package version, from Cargo.
const VERSION: &str = env!("CARGO_PKG_VERSION");

/// A verb the tool accepts.
struct Verb {
    /// Name as typed.
    name: &'static str,
    /// One-line summary.
    summary: &'static str,
    /// The stage that implements it.
    stage: &'static str,
}

const VERBS: &[Verb] = &[
    Verb {
        name: "gen",
        summary: "ingest a design and emit model / argv / device tree / C",
        stage: "Q1",
    },
    Verb {
        name: "conform",
        summary: "report where configuration, manifest and device tree disagree",
        stage: "Q1",
    },
    Verb {
        name: "dts",
        summary: "read, overlay, mutate, validate and emit a device tree",
        stage: "Q1",
    },
    Verb {
        name: "run",
        summary: "build a machine and execute it",
        stage: "Q2",
    },
    Verb {
        name: "fw",
        summary: "fetch, build or inspect firmware",
        stage: "Q2",
    },
    Verb {
        name: "tandem",
        summary: "lockstep against a reference and report first divergence",
        stage: "Q3",
    },
    Verb {
        name: "diag",
        summary: "run with the diagnosis layer and emit reports",
        stage: "Q5",
    },
    Verb {
        name: "pins",
        summary: "show pinned revisions and consumed contracts",
        stage: "Q0",
    },
    Verb {
        name: "doctor",
        summary: "probe host tooling",
        stage: "Q0",
    },
];

fn main() -> std::process::ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let args = Args::parse(argv);

    if args.flag("version") || args.flag("V") {
        println!("g6lc-qemu {VERSION} (stage {STAGE}, model schema {SCHEMA_VERSION})");
        return std::process::ExitCode::SUCCESS;
    }

    let Some(verb) = args.verb() else {
        print_help();
        return std::process::ExitCode::SUCCESS;
    };

    if verb == "help" || args.flag("help") || args.flag("h") {
        print_help();
        return std::process::ExitCode::SUCCESS;
    }

    match dispatch(verb, &args) {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(msg) => {
            eprintln!("g6lc-qemu: {msg}");
            std::process::ExitCode::FAILURE
        }
    }
}

fn dispatch(verb: &str, args: &Args) -> Result<(), String> {
    match verb {
        "pins" => {
            // Reflect what the binary itself knows. The pins file is authoritative for
            // external revisions; this reports the built-in contract versions.
            let j = Json::obj([
                ("tool", Json::str("g6lc-qemu")),
                ("version", Json::str(VERSION)),
                ("stage", Json::str(STAGE)),
                ("model_schema_version", Json::str(SCHEMA_VERSION)),
                ("emitted_c_spdx", Json::str(g6q_emit_qemu::EMITTED_SPDX)),
            ]);
            print!("{}", j.to_pretty());
            Ok(())
        }
        "doctor" => {
            println!("g6lc-qemu {VERSION}, stage {STAGE}");
            println!("  model schema : {SCHEMA_VERSION}");
            println!(
                "  profiles     : {} (diagnosable), {}",
                Profile::Soc.as_str(),
                Profile::Virt.as_str()
            );
            println!("  emitted C    : {}", g6q_emit_qemu::EMITTED_SPDX);
            println!();
            println!("Host tooling probing lives in `python tools/g6q.py doctor`;");
            println!("this verb reports what the binary itself was built with.");
            Ok(())
        }
        "gen" => cmd_gen(args),
        "conform" => cmd_conform(args),
        "run" => cmd_run(args),
        "tandem" => cmd_tandem(args),
        v if VERBS.iter().any(|x| x.name == v) => {
            let stage = VERBS.iter().find(|x| x.name == v).map_or("?", |x| x.stage);
            // Demonstrate the model plumbing so the skeleton is visibly wired, then be
            // honest about what is not implemented.
            if args.flag("demo") {
                print!("{}", demo_model(args).to_json().to_pretty());
                return Ok(());
            }
            let target = args.value_or("target", "<none>");
            Err(format!(
                "`{v}` is specified in architecture/CLI.md but lands at stage {stage}; \
                 the tool is at stage {STAGE}. \
                 (parsed: target={target}, {} flist(s), profile={}) \
                 Run with --demo to see the model plumbing.",
                args.values("flist").len(),
                args.value_or("machine", Profile::Soc.as_str()),
            ))
        }
        other => Err(format!("unknown verb `{other}`; try `g6lc-qemu help`")),
    }
}

/// `gen` — ingest the three inputs and emit the model.
fn cmd_gen(args: &Args) -> Result<(), String> {
    let resolved = resolve::resolve(args)?;
    if args.flag("verbose") {
        for n in &resolved.notes {
            eprintln!("  {n}");
        }
    }
    let model = g6q_ingest::assemble(&resolved.sources);

    // Legality is a separate question from conformance: an illegal configuration is one
    // the design would refuse to elaborate, and emulating it would be reporting on a
    // machine that does not build.
    if let Some(pkg) = &resolved.sources.config {
        let legality = g6q_ingest::validate_config(pkg);
        for v in legality.violations() {
            eprintln!(
                "g6lc-qemu: illegal configuration: {} -- {}",
                v.rule,
                v.violation.as_deref().unwrap_or("")
            );
        }
        if !legality.is_legal() && args.value_or("conform", "warn") == "strict" {
            return Err("configuration is illegal; refusing under --conform strict".into());
        }
    }

    let emit = args.value_or("emit", "model");
    let text = match emit {
        "model" => model.to_json().to_pretty(),
        "conformance" => model.conformance.to_json().to_pretty(),
        "args" => emit_args(args, &resolved, &model)?,
        "dts" | "dtb" => return emit_device_tree(args, &resolved, emit),
        other => {
            return Err(format!(
                "`--emit {other}` is specified in architecture/CLI.md but lands at a later \
                 stage; available now: model, conformance, args, dts, dtb"
            ))
        }
    };

    match args.value("emit-model").or_else(|| args.value("json-out")) {
        Some(path) => {
            write_out(path, &text)?;
            eprintln!("g6lc-qemu: wrote {path}");
        }
        None => print!("{text}"),
    }

    enforce_conformance(args, &model)
}

/// `--emit args` — the stock-emulator invocation plus what it does not cover.
fn emit_args(
    args: &Args,
    resolved: &resolve::Resolved,
    model: &TargetModel,
) -> Result<String, String> {
    let boot = resolve::boot_options(args);
    g6q_emit_args::check_profile(model, &boot)?;

    let stock = g6q_emit_args::StockTarget {
        machine: args.value_or("stock-machine", "virt").to_string(),
        cpu_base: args.value_or("stock-cpu", "rv64").to_string(),
    };

    // The property mapping is table data, not tool knowledge.
    let table = resolved
        .sources
        .table
        .clone()
        .unwrap_or_else(g6q_ingest::capability::Table::default_table);
    let properties_for = |token: &str| -> Vec<String> {
        for cap in &table.entries {
            if cap.dts_tokens.iter().any(|t| t == token) {
                return cap.qemu_properties().to_vec();
            }
        }
        vec![token.to_string()]
    };

    let argv = g6q_emit_args::build_argv(model, &stock, &boot, &properties_for);

    // Everything the stock model cannot express. Reporting it is the point of B0: it
    // says precisely what an early boot is *not* testing.
    let mut delta: Vec<String> = Vec::new();
    for cap in &table.entries {
        let live = model
            .conformance
            .rows
            .iter()
            .any(|r| r.capability == cap.name && r.verdict == Verdict::Live);
        if live && !cap.expressible_in_stock_qemu() {
            delta.push(cap.name.clone());
        }
    }
    if model.soc.hart_topology_agrees() == Some(false) {
        delta.push("hart-topology".into());
    }
    delta.push(format!(
        "memory-map ({} peripherals)",
        model.soc.peripherals.len()
    ));
    delta.sort();

    let j = Json::obj([
        ("binary", Json::str("qemu-system-riscv64")),
        ("argv", Json::arr(argv.iter().map(Json::str))),
        ("command_line", Json::str(argv.join(" "))),
        ("profile", Json::str(model.profile.as_str())),
        (
            "capability_delta",
            Json::obj([
                ("stock_machine", Json::str(&stock.machine)),
                ("not_expressible", Json::arr(delta.iter().map(Json::str))),
            ]),
        ),
        ("evidence", Json::Bool(false)),
    ]);
    Ok(j.to_pretty())
}

/// `--emit dts|dtb` — write the resolved device tree.
fn emit_device_tree(args: &Args, resolved: &resolve::Resolved, form: &str) -> Result<(), String> {
    let Some(path) = &resolved.dts_path else {
        return Err("no device tree was resolved; supply --dts or --repo-root".into());
    };
    let text = std::fs::read_to_string(path)
        .map_err(|e| format!("cannot read {}: {e}", path.display()))?;
    let tree = g6q_dts::parse(&text);

    let out = args
        .value("emit-model")
        .or_else(|| args.value("json-out"))
        .map(str::to_string)
        .unwrap_or_else(|| format!("out/emit/{form}.{form}"));

    if form == "dts" {
        write_out(&out, &text)?;
    } else {
        // Written here rather than shelled out to a device-tree compiler: requiring one
        // would make the package's standalone claim conditional on another toolchain.
        let blob = g6q_dts::to_blob(&tree, 0, &[]);
        if let Some(parent) = std::path::Path::new(&out).parent() {
            if !parent.as_os_str().is_empty() {
                std::fs::create_dir_all(parent)
                    .map_err(|e| format!("cannot create {}: {e}", parent.display()))?;
            }
        }
        std::fs::write(&out, &blob).map_err(|e| format!("cannot write {out}: {e}"))?;
        eprintln!("g6lc-qemu: wrote {out} ({} bytes)", blob.len());
        return Ok(());
    }
    eprintln!("g6lc-qemu: wrote {out}");
    Ok(())
}

/// Write an output file, creating its directory.
///
/// Output paths routinely name a directory that does not exist yet (`out/…` is the
/// default emission root and is gitignored, so a fresh clone has no such directory).
/// Failing there would look like a tool error for what is a perfectly ordinary request.
fn write_out(path: &str, text: &str) -> Result<(), String> {
    if let Some(parent) = std::path::Path::new(path).parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent)
                .map_err(|e| format!("cannot create {}: {e}", parent.display()))?;
        }
    }
    std::fs::write(path, text).map_err(|e| format!("cannot write {path}: {e}"))
}

/// `conform` — report where the three inputs disagree.
fn cmd_conform(args: &Args) -> Result<(), String> {
    let resolved = resolve::resolve(args)?;
    let model = g6q_ingest::assemble(&resolved.sources);

    if args.flag("json") || args.value("json-out").is_some() {
        let text = model.conformance.to_json().to_pretty();
        match args.value("json-out") {
            Some(p) => write_out(p, &text)?,
            None => print!("{text}"),
        }
        return enforce_conformance(args, &model);
    }

    println!(
        "target: {}  profile: {}",
        model.target_id,
        model.profile.as_str()
    );
    for n in &resolved.notes {
        println!("  {n}");
    }
    println!();

    let width = model
        .conformance
        .rows
        .iter()
        .map(|r| r.capability.len())
        .max()
        .unwrap_or(10);

    let mut counts = std::collections::BTreeMap::new();
    for row in &model.conformance.rows {
        *counts.entry(row.verdict.as_str()).or_insert(0usize) += 1;
        // Quiet mode shows only the rows that mean something is wrong.
        let interesting = row.verdict != Verdict::Live && row.verdict != Verdict::Absent;
        if args.flag("quiet") && !interesting {
            continue;
        }
        let mark = if row.verdict.refused_under_strict() {
            "!"
        } else {
            " "
        };
        let also = if row.also.is_empty() {
            String::new()
        } else {
            format!(
                " (+{})",
                row.also
                    .iter()
                    .map(|v| v.as_str())
                    .collect::<Vec<_>>()
                    .join(",")
            )
        };
        println!(
            "{mark} {:<width$}  {:<13}{}",
            row.capability,
            row.verdict.as_str(),
            also,
            width = width
        );
        if interesting && args.flag("verbose") {
            println!("    {}", row.note);
        }
    }

    // Hart topology is a count, not a capability, so it gets its own line rather than a
    // capability row -- but it is exactly the kind of config/tree disagreement this
    // command exists to surface.
    if let Some(agrees) = model.soc.hart_topology_agrees() {
        let declared = model.soc.harts_declared.unwrap_or(0);
        if !agrees {
            println!(
                "! topology: design has {} logical hart(s), device tree declares {} -- \
                 software will see {}",
                model.soc.harts_total, declared, declared
            );
        } else if !args.flag("quiet") {
            println!(
                "  topology: {} logical hart(s), matching the device tree",
                model.soc.harts_total
            );
        }
    }

    println!();
    let summary: Vec<String> = counts.iter().map(|(k, v)| format!("{v} {k}")).collect();
    println!("{}", summary.join(", "));
    println!(
        "strict conformance: {}",
        if model.conformance.passes_strict() {
            "pass"
        } else {
            "FAIL"
        }
    );
    println!("\nnot verification evidence; a hypothesis and a checkpoint only");

    enforce_conformance(args, &model)
}

/// Apply `--conform strict`.
fn enforce_conformance(args: &Args, model: &TargetModel) -> Result<(), String> {
    let mode = args.value_or("conform", "warn");
    if mode != "strict" || model.conformance.passes_strict() {
        return Ok(());
    }
    let blocking: Vec<String> = model
        .conformance
        .blocking()
        .iter()
        .map(|r| format!("{} ({})", r.capability, r.verdict.as_str()))
        .collect();
    Err(format!(
        "refusing under --conform strict: {}",
        blocking.join(", ")
    ))
}

/// A tiny model that exercises the crate wiring end to end.
///
/// It reflects back whatever the caller passed, so that `--demo` is also a check that the
/// option surface parsed the way the caller intended.
fn demo_model(args: &Args) -> TargetModel {
    let mut m = TargetModel::new(args.value_or("target", "demo"));
    if let Some(plane) = args.value("plane") {
        m.plane = plane.to_string();
    }
    if args.value_or("machine", Profile::Soc.as_str()) == Profile::Virt.as_str() {
        m.profile = Profile::Virt;
    }
    // Anything the caller forced makes the machine non-faithful, and the flag travels
    // with every artifact from here on.
    for ov in args.values("cfg-override") {
        let (field, value) = ov.split_once('=').unwrap_or((ov.as_str(), ""));
        m.provenance.overrides.push((
            field.to_string(),
            value.to_string(),
            "--cfg-override".to_string(),
        ));
        m.mark_unfaithful();
    }
    m.provenance.defines = args.values("define").to_vec();
    m.isa.xlen = 64;
    m.isa.base = "rv64i".to_string();
    let mut report = Report::new();
    // The canonical disagreement this package exists to surface: enabled in
    // configuration, absent from the manifest, still advertised to software.
    report.push(Row::classify("vector", Inputs::new(true, false, true)));
    report.push(Row::classify("atomics", Inputs::new(true, true, true)));
    m.conformance = report;
    m
}

fn print_help() {
    println!("g6lc-qemu {VERSION} — generate emulation from a design description");
    println!("stage {STAGE}; full option surface in architecture/CLI.md");
    println!();
    println!("usage: g6lc-qemu <verb> [options]");
    println!();
    let width = VERBS.iter().map(|v| v.name.len()).max().unwrap_or(8);
    for v in VERBS {
        println!(
            "  {:<width$}  {}  [{}]",
            v.name,
            v.summary,
            v.stage,
            width = width
        );
    }
    println!();
    println!("  --version           print version and stage");
    println!("  --help              this message");
    println!("  --demo              print a demonstration target model");
    println!();
    println!("Package automation (build, test, check) lives in `python tools/g6q.py`.");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_verb_declares_a_stage() {
        for v in VERBS {
            assert!(!v.stage.is_empty(), "{} has no stage", v.name);
            assert!(!v.summary.is_empty(), "{} has no summary", v.name);
        }
    }

    #[test]
    fn verb_names_are_unique() {
        let mut names: Vec<_> = VERBS.iter().map(|v| v.name).collect();
        names.sort_unstable();
        let before = names.len();
        names.dedup();
        assert_eq!(before, names.len(), "duplicate verb name");
    }

    #[test]
    fn an_unimplemented_verb_says_so_rather_than_succeeding_silently() {
        // `run` is now implemented; use a verb that is still stubbed.
        let args = Args::parse(["diag", "--target", "x"]);
        let err = dispatch("diag", &args).unwrap_err();
        assert!(err.contains("stage Q5"), "{err}");
    }

    #[test]
    fn gen_and_conform_are_implemented_and_do_not_report_a_future_stage() {
        // They must fail for a real reason (no inputs), never with "lands at stage ...".
        for verb in ["gen", "conform"] {
            let args = Args::parse([verb, "--target", "nonexistent-target"]);
            if let Err(e) = dispatch(verb, &args) {
                assert!(!e.contains("lands at stage"), "{verb}: {e}");
            }
        }
    }

    #[test]
    fn an_unsupported_emit_names_what_is_available() {
        let args = Args::parse(["gen", "--target", "t", "--emit", "qemu-machine"]);
        let err = dispatch("gen", &args).unwrap_err();
        assert!(
            err.contains("model") && err.contains("conformance"),
            "{err}"
        );
    }

    #[test]
    fn an_unknown_verb_is_rejected() {
        let args = Args::parse(["frobnicate"]);
        assert!(dispatch("frobnicate", &args).is_err());
    }

    #[test]
    fn implemented_verbs_succeed() {
        assert!(dispatch("pins", &Args::parse(["pins"])).is_ok());
        assert!(dispatch("doctor", &Args::parse(["doctor"])).is_ok());
    }

    #[test]
    fn the_demo_model_exercises_the_crate_wiring() {
        let m = demo_model(&Args::parse(["gen"]));
        let text = m.to_json().to_pretty();
        assert!(text.contains("\"profile\": \"g6lc-soc\""), "{text}");
        assert!(text.contains("\"verdict\": \"stub\""), "{text}");
        assert!(
            !m.conformance.passes_strict(),
            "a stub capability must block strict conformance"
        );
    }

    #[test]
    fn the_demo_model_reflects_the_parsed_options() {
        let args = Args::parse([
            "gen",
            "--target",
            "abc",
            "--plane",
            "core",
            "--machine",
            "g6lc-virt",
        ]);
        let m = demo_model(&args);
        assert_eq!(m.target_id, "abc");
        assert_eq!(m.plane, "core");
        assert_eq!(m.profile, Profile::Virt);
        assert!(!m.diagnosable(), "the virt profile must not be diagnosable");
    }

    #[test]
    fn an_override_marks_the_machine_unfaithful() {
        let args = Args::parse(["gen", "--cfg-override", "HartsPerCore=2"]);
        let m = demo_model(&args);
        assert!(!m.faithful, "a forced field must clear faithfulness");
        assert_eq!(m.provenance.overrides.len(), 1);
        assert_eq!(m.provenance.overrides[0].0, "HartsPerCore");
        assert!(!m.diagnosable());
    }

    #[test]
    fn native_run_rejects_run_without_image() {
        let args = Args::parse(["run"]);
        assert!(cmd_run(&args).is_err());
    }

    #[test]
    fn tandem_rejects_missing_reference() {
        let args = Args::parse(["tandem", "--under-test", "x"]);
        assert!(cmd_tandem(&args).is_err());
    }

    #[test]
    fn tandem_reports_no_divergence_for_identical_records() {
        use std::io::Write;
        let mut tmp = std::env::temp_dir();
        tmp.push("g6q-tandem-test");
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();
        let lhs = tmp.join("lhs.json");
        let rhs = tmp.join("rhs.json");
        let records = g6q_diag::records_to_json(&[g6q_diag::CommitRecord {
            order: 0,
            hart: 0,
            pc_rdata: 0x8000_0000,
            pc_wdata: 0x8000_0004,
            insn: 0x1234_5678,
            trap: false,
            rd_addr: 0,
            rd_wdata: 0,
        }]);
        let text = records.to_pretty();
        let mut f = std::fs::File::create(&lhs).unwrap();
        f.write_all(text.as_bytes()).unwrap();
        let mut f = std::fs::File::create(&rhs).unwrap();
        f.write_all(text.as_bytes()).unwrap();

        let args = Args::parse([
            "tandem",
            "--under-test",
            lhs.to_str().unwrap(),
            "--reference",
            rhs.to_str().unwrap(),
        ]);
        assert!(cmd_tandem(&args).is_ok());
    }
}

/// `run --backend native` — a raw-image native VM execution.
///
/// This is intentionally minimal: it loads a flat binary, sets up the faithful
/// memory map (DRAM, CLINT, PLIC, UART), and runs one hart. The map is still
/// hard-coded and will be replaced by the resolved `TargetModel` in a later pass.
fn cmd_run(args: &Args) -> Result<(), String> {
    let backend = args.value_or("backend", "native");
    if backend != "native" {
        return Err(format!(
            "`--backend {backend}` is not implemented; use `native`"
        ));
    }
    let image = args
        .value("image")
        .ok_or("run --backend native needs --image FILE")?;
    let steps = args
        .value_or("steps", "1000000")
        .parse::<u64>()
        .map_err(|_| "--steps must be a positive integer".to_string())?;
    let base = parse_addr(args.value_or("base", "0x80000000"))?;

    let mut mem = PhysMem::new();
    mem.add(Region::new(base, 0x1000_0000));
    mem.add_device(Device::new(
        0x0200_0000,
        0x10000,
        DeviceKind::Clint(Clint::new(1)),
    ));
    mem.add_device(Device::new(
        0x0c00_0000,
        0x40_0000,
        DeviceKind::Plic(Plic::new(30, 16)),
    ));
    mem.add_device(Device::new(
        0x1000_0000,
        0x100,
        DeviceKind::Uart(Uart::new()),
    ));

    let bytes = std::fs::read(image).map_err(|e| format!("cannot read {image}: {e}"))?;
    for (i, b) in bytes.iter().enumerate() {
        mem.write_le::<1>(base + i as u64, *b as u64)
            .map_err(|e| format!("cannot load binary: {e}"))?;
    }

    let mut hart = Hart::new(base);
    hart.csr.mtvec = 0x9000_0000;
    // A default trap handler that self-loops so an unhandled ecall does not run away.
    mem.add(Region::new(0x9000_0000, 0x1000));
    mem.write_le::<4>(0x9000_0000, 0x0000_006f)
        .map_err(|e| format!("trap handler: {e}"))?;

    let halt = hart.run(&mut mem, 64, steps);

    if let Some(u) = mem.uart() {
        let out = String::from_utf8_lossy(&u.output);
        if !out.is_empty() {
            print!("{out}");
        }
    }

    if args.flag("record") {
        let records = g6q_diag::records_to_json(&hart.records).to_pretty();
        let path = args.value_or("record-out", "out/records.json");
        std::fs::write(path, records).map_err(|e| format!("cannot write {path}: {e}"))?;
        eprintln!("g6lc-qemu: wrote {path}");
    }

    if args.flag("verbose") {
        eprintln!("g6lc-qemu: native run halted: {halt:?}");
        eprintln!("  instructions retired: {}", hart.instret);
    }

    Ok(())
}

fn parse_addr(s: &str) -> Result<u64, String> {
    if let Some(hex) = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")) {
        u64::from_str_radix(hex, 16).map_err(|_| format!("bad hex address `{s}`"))
    } else {
        s.parse::<u64>()
            .map_err(|_| format!("address must be decimal or 0x-prefixed hex: `{s}`"))
    }
}

/// `tandem` — compare an under-test record stream with a reference.
fn cmd_tandem(args: &Args) -> Result<(), String> {
    let under = args
        .value("under-test")
        .ok_or("tandem needs --under-test FILE")?;
    let reference = args
        .value("reference")
        .ok_or("tandem needs --reference FILE")?;

    let lhs = std::fs::read_to_string(under).map_err(|e| format!("cannot read {under}: {e}"))?;
    let rhs =
        std::fs::read_to_string(reference).map_err(|e| format!("cannot read {reference}: {e}"))?;

    let under_test = g6q_diag::records_from_str(&lhs)?;
    let reference = g6q_diag::records_from_str(&rhs)?;

    let report = g6q_diag::tandem_report(&under_test, &reference);
    print!("{}", report.to_pretty());

    if let Json::Obj(o) = &report {
        if let Some(Json::Bool(false)) = o.get("divergence") {
            return Ok(());
        }
    }
    Err("tandem divergence detected".to_string())
}
