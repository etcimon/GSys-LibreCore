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
mod pins;
mod resolve;

use args::Args;
use g6q_core::model::Profile;
use g6q_core::{Inputs, Json, Report, Row, TargetModel, Verdict, SCHEMA_VERSION, STAGE};
use g6q_diag::ai_tensor::{TensorArtifact, TensorTrace};
use g6q_vm::device::{AiIsland, Clint, Plic, Uart};
use g6q_vm::mem::{Device, DeviceKind, PhysMem, Region};
use g6q_vm::{Halt, Hart};
use pins::Pins;
use std::path::{Path, PathBuf};

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
            // Reflect what the binary itself knows, then overlay the authoritative
            // pins.toml so external revisions and consumed contracts are visible.
            let built_in = Json::obj([
                ("tool", Json::str("g6lc-qemu")),
                ("version", Json::str(VERSION)),
                ("stage", Json::str(STAGE)),
                ("model_schema_version", Json::str(SCHEMA_VERSION)),
                ("emitted_c_spdx", Json::str(g6q_emit_qemu::EMITTED_SPDX)),
            ]);

            let mut j = built_in.clone();
            if let Some(path) = Pins::find(std::env::current_dir().unwrap_or_default().as_path()) {
                match Pins::from_file(&path) {
                    Ok(pins) => {
                        j = Json::obj([
                            ("built_in", built_in),
                            ("pins_file", Json::str(&*path.to_string_lossy())),
                            ("pins", pins.to_json()),
                        ]);
                    }
                    Err(e) => {
                        eprintln!("g6lc-qemu: warning: cannot parse pins file: {e}");
                    }
                }
            }

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
        "dts" => cmd_dts(args),
        "fw" => cmd_fw(args),
        "tandem" => cmd_tandem(args),
        "diag" => cmd_diag(args),
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
    let mut model = g6q_ingest::assemble(&resolved.sources);

    if let Some(v) = args.value("virtio-mmio") {
        model.soc.virtio_mmio = v
            .parse::<u32>()
            .map_err(|_| "--virtio-mmio must be a non-negative integer".to_string())?;
    } else if model.profile == Profile::Virt && model.soc.virtio_mmio == 0 {
        // A virt profile needs at least a few virtio-mmio transports for block,
        // network, console and rng. This is a machine-profile default, not an RTL
        // constant, and is reported in the model JSON.
        model.soc.virtio_mmio = 8;
    }

    if let Some(v) = args.value("bootrom") {
        model.soc.bootrom = Some(parse_bootrom(v)?);
    }

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
        "qemu-machine" => return emit_qemu_machine(args, &model),
        "qemu" => return emit_qemu_all(args, &model),
        "qemu-plugin" => return emit_qemu_plugin(args, &model),
        "qemu-pmu-plugin" => return emit_qemu_pmu_plugin(args, &model),
        "matrix" => return emit_matrix(args, &resolved),
        "dts" | "dtb" => return emit_device_tree(args, &resolved, emit),
        other => {
            return Err(format!(
                "`--emit {other}` is specified in architecture/CLI.md but lands at a later \
                 stage; available now: model, conformance, args, matrix, dts, dtb, qemu, \
                 qemu-machine, qemu-plugin, qemu-pmu-plugin"
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
    let mut boot = resolve::boot_options(args);
    g6q_emit_args::check_profile(model, &boot)?;
    if args.flag("plugin") || args.value("plugin").is_some() {
        boot.plugin = Some(plugin_path(args, model));
    }

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
        // No capability row for this token: it is either a base MISA letter (i, m)
        // or a non-QEMU property. Stock `-cpu rv64` already carries the base ISA,
        // so emit nothing rather than an invalid property.
        Vec::new()
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

/// `--emit qemu-machine` — generate the B1 QEMU machine, CPU, FDT and build wiring.
fn emit_qemu_machine(args: &Args, model: &TargetModel) -> Result<(), String> {
    let digest = resolve::digest(&model.to_json().to_pretty());
    let mut emission = g6q_emit_qemu::machine::emit_machine(model, VERSION, &digest);
    let cpu_emission = g6q_emit_qemu::cpu::emit_cpu(model, VERSION, &digest);
    for f in &cpu_emission.files {
        emission.push(f.clone());
    }
    let dtb_emission = g6q_emit_qemu::dts::emit_dtb(model, VERSION, &digest);
    for f in &dtb_emission.files {
        emission.push(f.clone());
    }
    let build_emission = g6q_emit_qemu::build::emit_build_wiring(model, VERSION, &digest);
    for f in &build_emission.files {
        emission.push(f.clone());
    }
    g6q_emit_qemu::trans::emit(model, VERSION, &digest, &mut emission);

    let base = args
        .value("emit-dir")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::path::PathBuf::from(format!("out/emit/{}", model.target_id)));

    for f in &emission.files {
        let path = base.join(&f.path);
        let text = &f.contents;
        write_out(path.to_str().unwrap_or(&f.path), text)?;
        eprintln!("g6lc-qemu: wrote {}", path.display());
    }

    Ok(())
}

/// `--emit qemu-plugin` — generate the B2 QEMU TCG plugin.
fn emit_qemu_plugin(args: &Args, model: &TargetModel) -> Result<(), String> {
    let digest = resolve::digest(&model.to_json().to_pretty());
    let emission = g6q_emit_qemu::plugin::emit_plugin(model, VERSION, &digest);

    let base = args
        .value("emit-dir")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::path::PathBuf::from(format!("out/emit/{}", model.target_id)));

    for f in &emission.files {
        let path = base.join(&f.path);
        let text = &f.contents;
        write_out(path.to_str().unwrap_or(&f.path), text)?;
        eprintln!("g6lc-qemu: wrote {}", path.display());
    }

    Ok(())
}

/// `--emit qemu-pmu-plugin` — generate the B2 QEMU PMU counter plugin.
fn emit_qemu_pmu_plugin(args: &Args, model: &TargetModel) -> Result<(), String> {
    let digest = resolve::digest(&model.to_json().to_pretty());
    let emission = g6q_emit_qemu::pmu::emit_pmu_plugin(model, VERSION, &digest);

    let base = args
        .value("emit-dir")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::path::PathBuf::from(format!("out/emit/{}", model.target_id)));

    for f in &emission.files {
        let path = base.join(&f.path);
        let text = &f.contents;
        write_out(path.to_str().unwrap_or(&f.path), text)?;
        eprintln!("g6lc-qemu: wrote {}", path.display());
    }

    Ok(())
}

/// `--emit matrix` — print the capability matrix (input probes + verdicts) as JSON.
fn emit_matrix(args: &Args, resolved: &resolve::Resolved) -> Result<(), String> {
    let matrix = g6q_ingest::matrix::build(&resolved.sources);
    let text = matrix.to_pretty();

    match args.value("emit-model").or_else(|| args.value("json-out")) {
        Some(path) => {
            write_out(path, &text)?;
            eprintln!("g6lc-qemu: wrote {path}");
        }
        None => print!("{text}"),
    }

    Ok(())
}

/// `--emit qemu` — generate all B1/B2 QEMU artifacts (machine, CPU, FDT, build wiring, plugin).
fn emit_qemu_all(args: &Args, model: &TargetModel) -> Result<(), String> {
    let digest = resolve::digest(&model.to_json().to_pretty());
    let mut emission = g6q_emit_qemu::machine::emit_machine(model, VERSION, &digest);
    let cpu_emission = g6q_emit_qemu::cpu::emit_cpu(model, VERSION, &digest);
    for f in &cpu_emission.files {
        emission.push(f.clone());
    }
    let dtb_emission = g6q_emit_qemu::dts::emit_dtb(model, VERSION, &digest);
    for f in &dtb_emission.files {
        emission.push(f.clone());
    }
    let build_emission = g6q_emit_qemu::build::emit_build_wiring(model, VERSION, &digest);
    for f in &build_emission.files {
        emission.push(f.clone());
    }
    let plugin_emission = g6q_emit_qemu::plugin::emit_plugin(model, VERSION, &digest);
    for f in &plugin_emission.files {
        emission.push(f.clone());
    }
    let pmu_emission = g6q_emit_qemu::pmu::emit_pmu_plugin(model, VERSION, &digest);
    for f in &pmu_emission.files {
        emission.push(f.clone());
    }
    g6q_emit_qemu::trans::emit(model, VERSION, &digest, &mut emission);

    let base = args
        .value("emit-dir")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::path::PathBuf::from(format!("out/emit/{}", model.target_id)));

    for f in &emission.files {
        let path = base.join(&f.path);
        let text = &f.contents;
        write_out(path.to_str().unwrap_or(&f.path), text)?;
        eprintln!("g6lc-qemu: wrote {}", path.display());
    }

    Ok(())
}

/// Build the resolved device tree as a DTB blob, applying overlays and mutations.
fn resolved_dts_blob(args: &Args, resolved: &resolve::Resolved) -> Result<Vec<u8>, String> {
    let Some(path) = &resolved.dts_path else {
        return Err("no device tree was resolved; supply --dts or --repo-root".into());
    };
    let text = std::fs::read_to_string(path)
        .map_err(|e| format!("cannot read {}: {e}", path.display()))?;
    let mut tree = g6q_dts::parse(&text);

    // Apply overlays first, then per-property mutations.
    for overlay in args.values("dts-overlay") {
        let otext = std::fs::read_to_string(overlay)
            .map_err(|e| format!("cannot read overlay {overlay}: {e}"))?;
        let otree = g6q_dts::parse(&otext);
        g6q_dts::merge(&mut tree, &otree);
    }

    for spec in args.values("dts-set") {
        let Some((path, value)) = spec.split_once('=') else {
            return Err(format!("--dts-set requires PATH=VALUE, got {spec}"));
        };
        g6q_dts::set_prop(&mut tree, path, value).map_err(|e| format!("--dts-set {spec}: {e}"))?;
    }
    for spec in args.values("dts-del") {
        g6q_dts::del_prop(&mut tree, spec).map_err(|e| format!("--dts-del {spec}: {e}"))?;
    }

    // Written here rather than shelled out to a device-tree compiler: requiring one
    // would make the package's standalone claim conditional on another toolchain.
    Ok(g6q_dts::to_blob(&tree, 0, &[]))
}

/// Derive the logical hart count for an OpenSBI build when the caller points at a
/// design or a device tree. This makes the firmware's `PLATFORM_HART_COUNT` match
/// the processor-node count in the generated FDT.
fn fw_build_hart_count(args: &Args) -> Option<u32> {
    if args.value("target").is_none()
        && args.value("config-pkg").is_none()
        && args.value("repo-root").is_none()
        && args.value("dts").is_none()
    {
        return None;
    }
    let resolved = resolve::resolve(args).ok()?;
    if resolved.sources.config.is_none() && resolved.sources.dts.is_none() {
        return None;
    }
    let model = g6q_ingest::assemble(&resolved.sources);
    Some(model.soc.harts_total.max(1))
}

/// `--emit dts|dtb` — write the resolved device tree.
fn emit_device_tree(args: &Args, resolved: &resolve::Resolved, form: &str) -> Result<(), String> {
    let out = args
        .value("emit-model")
        .or_else(|| args.value("json-out"))
        .map(str::to_string)
        .unwrap_or_else(|| format!("out/emit/{form}.{form}"));

    if form == "dts" {
        let Some(path) = &resolved.dts_path else {
            return Err("no device tree was resolved; supply --dts or --repo-root".into());
        };
        let text = std::fs::read_to_string(path)
            .map_err(|e| format!("cannot read {}: {e}", path.display()))?;
        let mut tree = g6q_dts::parse(&text);

        for overlay in args.values("dts-overlay") {
            let otext = std::fs::read_to_string(overlay)
                .map_err(|e| format!("cannot read overlay {overlay}: {e}"))?;
            let otree = g6q_dts::parse(&otext);
            g6q_dts::merge(&mut tree, &otree);
        }

        for spec in args.values("dts-set") {
            let Some((path, value)) = spec.split_once('=') else {
                return Err(format!("--dts-set requires PATH=VALUE, got {spec}"));
            };
            g6q_dts::set_prop(&mut tree, path, value)
                .map_err(|e| format!("--dts-set {spec}: {e}"))?;
        }
        for spec in args.values("dts-del") {
            g6q_dts::del_prop(&mut tree, spec).map_err(|e| format!("--dts-del {spec}: {e}"))?;
        }

        write_out(&out, &tree.to_dts(""))?;
    } else {
        let blob = resolved_dts_blob(args, resolved)?;
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

/// `dts` — read, overlay, mutate, validate and emit a device tree.
///
/// This is the standalone device-tree verb; `gen --emit dts|dtb` uses the same emitter.
fn cmd_dts(args: &Args) -> Result<(), String> {
    let resolved = resolve::resolve(args)?;
    let form = if args.value_or("emit", "dts") == "dtb" {
        "dtb"
    } else {
        "dts"
    };
    if args.flag("validate") {
        // Parsing already happened inside emit_device_tree; if we get here the tree is valid.
        println!("valid");
        return Ok(());
    }
    emit_device_tree(args, &resolved, form)
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
    report.profile = m.profile;
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
    fn fw_build_rejects_missing_source() {
        let args = Args::parse(["fw", "build", "--target", "x"]);
        let err = dispatch("fw", &args).unwrap_err();
        assert!(err.contains("no OpenSBI source"), "{err}");
    }

    #[test]
    fn fw_build_rejects_invalid_fw_make() {
        let args = Args::parse(["fw", "build", "--dry-run", "--fw-make", "NOEQUALS"]);
        let err = dispatch("fw", &args).unwrap_err();
        assert!(err.contains("must be VAR=VAL"), "{err}");
    }

    #[test]
    fn fw_build_fw_fdt_auto_sets_fw_fdt_path() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .and_then(|p| p.parent())
            .expect("g6q-cli is nested under crates/");
        let dts = root.join("fixtures/mini/board.dts");
        let args = Args::parse([
            "fw",
            "build",
            "--dry-run",
            "--fw-fdt",
            "auto",
            "--target",
            "fixtures/mini",
            "--dts",
            &*dts.to_string_lossy(),
            "--fw-out",
            "out/fw-test",
        ]);
        dispatch("fw", &args).unwrap();
    }

    #[test]
    fn fw_build_hart_count_matches_the_resolved_model() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .and_then(|p| p.parent())
            .expect("g6q-cli is nested under crates/");
        let dts = root.join("fixtures/mini/board.dts");
        let args = Args::parse([
            "fw",
            "build",
            "--dry-run",
            "--fw-fdt",
            "auto",
            "--target",
            "fixtures/mini",
            "--dts",
            &*dts.to_string_lossy(),
        ]);
        assert_eq!(fw_build_hart_count(&args), Some(1));
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
        let args = Args::parse(["gen", "--target", "t", "--emit", "qemu-cpu"]);
        let err = dispatch("gen", &args).unwrap_err();
        assert!(
            err.contains("model") && err.contains("conformance"),
            "{err}"
        );
    }

    #[test]
    fn gen_qemu_emit_writes_all_qemu_artifacts() {
        let args = Args::parse(["gen", "--target", "t", "--emit", "qemu"]);
        assert!(dispatch("gen", &args).is_ok());
    }

    #[test]
    fn gen_qemu_pmu_plugin_is_available() {
        let args = Args::parse(["gen", "--target", "t", "--emit", "qemu-pmu-plugin"]);
        assert!(dispatch("gen", &args).is_ok());
    }

    #[test]
    fn gen_matrix_is_available() {
        let args = Args::parse(["gen", "--target", "t", "--emit", "matrix"]);
        assert!(dispatch("gen", &args).is_ok());
    }

    #[test]
    fn diag_emits_uarch_counters_without_reporting_a_future_stage() {
        let mut tmp = std::env::temp_dir();
        tmp.push("g6q-diag-test");
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();
        let out = tmp.join("uarch.json");
        let path = out.to_str().unwrap();
        let args = Args::parse(["diag", "--target", "t", "--uarch-out", path]);
        assert!(dispatch("diag", &args).is_ok());
        let text = std::fs::read_to_string(&out).unwrap();
        assert!(text.starts_with('['), "{text}");
    }

    #[test]
    fn diag_measured_dram_gbps_x1000_closes_the_roofline() {
        let mut tmp = std::env::temp_dir();
        tmp.push("g6q-diag-measured-test");
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();

        // Build a tiny repo root that has an AI island so the roofline counters are emitted.
        let cfg_dir = tmp.join("core").join("include");
        std::fs::create_dir_all(&cfg_dir).unwrap();
        let config_pkg = cfg_dir.join("mini_config_pkg.sv");
        std::fs::write(
            &config_pkg,
            r#"package mini_config_pkg;
typedef struct packed {
  int unsigned XLEN;
  bit RVC;
  bit RVM;
  bit RVA;
  int unsigned NrHarts;
  int unsigned NrCores;
} mini_cfg_t;
localparam mini_cfg_t cva6_cfg = '{
  XLEN: 64,
  RVC: 1'b1,
  RVM: 1'b1,
  RVA: 1'b1,
  NrHarts: 1,
  NrCores: 1
};
endpackage
"#,
        )
        .unwrap();

        let flist = tmp.join("Flist.ariane");
        std::fs::write(
            &flist,
            "${CVA6_REPO_DIR}/g6lc_ai_island_cfg_pkg.sv\n\
             ${CVA6_REPO_DIR}/g6lc_ai_desc_pkg.sv\n\
             ${CVA6_REPO_DIR}/g6lc_ai_instr_pkg.sv\n",
        )
        .unwrap();

        std::fs::write(
            tmp.join("g6lc_ai_island_cfg_pkg.sv"),
            include_str!("../../../fixtures/ai/g6lc_ai_island_cfg_pkg.sv"),
        )
        .unwrap();
        std::fs::write(
            tmp.join("g6lc_ai_desc_pkg.sv"),
            include_str!("../../../fixtures/ai/g6lc_ai_desc_pkg.sv"),
        )
        .unwrap();
        std::fs::write(
            tmp.join("g6lc_ai_instr_pkg.sv"),
            include_str!("../../../fixtures/ai/g6lc_ai_instr_pkg.sv"),
        )
        .unwrap();

        let dts_dir = tmp.join("corev_apu").join("bootrom");
        std::fs::create_dir_all(&dts_dir).unwrap();
        let dts = dts_dir.join("ariane-mini.dts");
        std::fs::write(
            &dts,
            "/dts-v1/;\n\
             / {\n\
               #address-cells = <2>;\n\
               #size-cells = <2>;\n\
               cpus {\n\
                 #address-cells = <1>;\n\
                 #size-cells = <0>;\n\
                 timebase-frequency = <32768>;\n\
                 cpu@0 {\n\
                   device_type = \"cpu\";\n\
                   compatible = \"riscv\";\n\
                   reg = <0>;\n\
                   status = \"okay\";\n\
                   riscv,isa-base = \"rv64i\";\n\
                   riscv,isa-extensions = \"i\", \"m\", \"a\", \"c\";\n\
                   mmu-type = \"riscv,sv39\";\n\
                   interrupt-controller {\n\
                     #interrupt-cells = <1>;\n\
                     interrupt-controller;\n\
                     compatible = \"riscv,cpu-intc\";\n\
                   };\n\
                 };\n\
               };\n\
               memory@80000000 {\n\
                 device_type = \"memory\";\n\
                 reg = <0x0 0x80000000 0x0 0x10000000>;\n\
               };\n\
             };\n",
        )
        .unwrap();

        let out = tmp.join("uarch.json");
        let repo = tmp.to_str().unwrap();
        let path = out.to_str().unwrap();
        let args = Args::parse([
            "diag",
            "--repo-root",
            repo,
            "--target",
            "mini",
            "--measured-dram-gbps-x1000",
            "320500",
            "--uarch-out",
            path,
        ]);
        assert!(
            dispatch("diag", &args).is_ok(),
            "diag with measured DRAM should succeed"
        );

        let text = std::fs::read_to_string(&out).unwrap();
        assert!(
            text.contains("ai.island.measured_dram_gbps_x1000"),
            "measured counter missing: {text}"
        );
        assert!(
            text.contains("ai.roofline.balance_mac_per_byte"),
            "roofline balance should close with a measured bandwidth: {text}"
        );
    }

    #[test]
    fn diag_merges_tensor_trace_counters() {
        let mut tmp = std::env::temp_dir();
        tmp.push("g6q-diag-tensor-test");
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();

        let tensor_path = tmp.join("tensor.json");
        let out_path = tmp.join("uarch.json");
        let ev = g6q_diag::ai_tensor::AiTensorEvent {
            order: 0,
            hart: 0,
            descriptor_addr: 0x8000_0000,
            op: 1,
            version: 1,
            flags: 0,
            m: 4,
            n: 4,
            k: 4,
            ld_ab: 4,
            ptr_a: 0x9000_0000,
            ptr_b: 0x9000_1000,
            ptr_c: 0x9000_2000,
            ptr_scale: 0,
            ptr_done: 0xa000_0000,
            dtype: 0,
            cluster: 0,
            ticket: 1,
            status: 0,
            done: true,
            ..Default::default()
        };
        let trace = g6q_diag::ai_tensor::TensorTrace {
            events: vec![ev],
            flags_layout: None,
        };
        std::fs::write(&tensor_path, trace.to_json().to_pretty()).unwrap();

        let args = Args::parse([
            "diag",
            "--target",
            "t",
            "--tensor",
            tensor_path.to_str().unwrap(),
            "--uarch-out",
            out_path.to_str().unwrap(),
        ]);
        assert!(dispatch("diag", &args).is_ok());

        let text = std::fs::read_to_string(&out_path).unwrap();
        assert!(text.contains("ai.tensor.ops"), "{text}");
        assert!(text.contains("ai.tensor.macs"), "{text}");
    }

    #[test]
    fn diag_compares_two_tensor_artifacts() {
        let mut tmp = std::env::temp_dir();
        tmp.push("g6q-diag-compare-test");
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();

        let left_path = tmp.join("left.json");
        let right_path = tmp.join("right.json");
        let out_path = tmp.join("uarch.json");

        let ev = g6q_diag::ai_tensor::AiTensorEvent {
            order: 0,
            hart: 0,
            descriptor_addr: 0x8000_0000,
            op: 1,
            version: 1,
            flags: 0,
            m: 4,
            n: 4,
            k: 4,
            ld_ab: 4,
            ptr_a: 0x9000_0000,
            ptr_b: 0x9000_1000,
            ptr_c: 0x9000_2000,
            ptr_scale: 0,
            ptr_done: 0xa000_0000,
            dtype: 0,
            cluster: 0,
            ticket: 1,
            status: 0,
            done: true,
            ..Default::default()
        };
        let header = g6q_diag::ArtifactHeader {
            profile: "g6lc-soc".into(),
            tainted: false,
        };
        let left = g6q_diag::ai_tensor::TensorArtifact::new(
            header.clone(),
            g6q_diag::ai_tensor::TensorTrace {
                events: vec![ev],
                flags_layout: None,
            },
        );
        let mut ev2 = ev;
        ev2.done = false;
        let right = g6q_diag::ai_tensor::TensorArtifact::new(
            header,
            g6q_diag::ai_tensor::TensorTrace {
                events: vec![ev2],
                flags_layout: None,
            },
        );
        std::fs::write(&left_path, left.to_json().to_pretty()).unwrap();
        std::fs::write(&right_path, right.to_json().to_pretty()).unwrap();

        let args = Args::parse([
            "diag",
            "--target",
            "t",
            "--tensor",
            left_path.to_str().unwrap(),
            "--tensor",
            right_path.to_str().unwrap(),
            "--uarch-out",
            out_path.to_str().unwrap(),
        ]);
        let err = dispatch("diag", &args).unwrap_err();
        assert!(err.contains("divergence"), "{err}");
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
    fn run_args_backend_builds_stock_qemu_argv() {
        let args = Args::parse(["run", "--backend", "args", "--target", "t"]);
        assert!(cmd_run(&args).is_ok());
    }

    #[test]
    fn run_args_with_plugin_includes_plugin_path() {
        let args = Args::parse(["run", "--backend", "args", "--target", "t", "--plugin"]);
        assert!(cmd_run(&args).is_ok());
    }

    #[test]
    fn run_args_with_fw_and_payload_emits_bios_and_kernel() {
        let mut tmp = std::env::temp_dir();
        tmp.push("g6q-run-fw-args.json");
        let _ = std::fs::remove_file(&tmp);
        let args = Args::parse([
            "run",
            "--backend",
            "args",
            "--target",
            "t",
            "--fw",
            "out/fw/smoke.bin",
            "--fw-payload",
            "out/fw/Image",
            "--json-out",
            tmp.to_str().unwrap(),
        ]);
        dispatch("run", &args).unwrap();
        let text = std::fs::read_to_string(&tmp).unwrap();
        assert!(text.contains("-bios"), "{text}");
        assert!(text.contains("out/fw/smoke.bin"), "{text}");
        assert!(text.contains("-kernel"), "{text}");
        assert!(text.contains("out/fw/Image"), "{text}");
    }

    #[test]
    fn run_qemu_dry_run_does_not_require_a_binary() {
        let args = Args::parse([
            "run",
            "--backend",
            "qemu",
            "--target",
            "t",
            "--dry-run",
            "--qemu-path",
            "/nonexistent/qemu",
        ]);
        assert!(cmd_run(&args).is_ok());
    }

    #[test]
    fn run_qemu_record_sets_plugin_and_trace_arg() {
        let args = Args::parse([
            "run",
            "--backend",
            "qemu",
            "--target",
            "t",
            "--record",
            "/tmp/run.rec",
            "--dry-run",
        ]);
        assert!(cmd_run(&args).is_ok());
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
            cause: 0,
            prv: 0,
            halt: false,
            rd_addr: 0,
            rd_wdata: 0,
            frd_addr: 0,
            frd_wdata: 0,
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

    #[test]
    fn tandem_accepts_record_file_objects() {
        use std::io::Write;
        let mut tmp = std::env::temp_dir();
        tmp.push("g6q-tandem-rf-test");
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();
        let lhs = tmp.join("lhs.json");
        let rhs = tmp.join("rhs.json");
        let mut m = g6q_core::TargetModel::new("mini");
        m.target_id = "mini".to_string();
        let records = vec![g6q_diag::CommitRecord {
            order: 0,
            hart: 0,
            pc_rdata: 0x8000_0000,
            pc_wdata: 0x8000_0004,
            insn: 0x1234_5678,
            trap: false,
            cause: 0,
            prv: 0,
            halt: false,
            rd_addr: 0,
            rd_wdata: 0,
            frd_addr: 0,
            frd_wdata: 0,
        }];
        let file = g6q_diag::RecordFile::from_model_and_records(&m, records);
        let text = file.to_json().to_pretty();
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

    #[test]
    fn tandem_loads_dasm_under_test() {
        use std::io::Write;
        let mut tmp = std::env::temp_dir();
        tmp.push("g6q-tandem-dasm-test");
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();
        let dasm = tmp.join("trace_rvfi_hart_0.dasm");
        let json = tmp.join("ref.json");

        let dasm_text = "core   0: 0x1000 (0x00000293) DASM(0x00000293)\n\
                         3 0x1000 (0x00000293) x5 0x0000000000000001\n";
        std::fs::File::create(&dasm)
            .unwrap()
            .write_all(dasm_text.as_bytes())
            .unwrap();

        let mut m = g6q_core::TargetModel::new("mini");
        m.target_id = "mini".to_string();
        let records = vec![g6q_diag::CommitRecord {
            order: 0,
            hart: 0,
            pc_rdata: 0x1000,
            pc_wdata: 0x1004,
            insn: 0x0000_0293,
            trap: false,
            cause: 0,
            prv: 3,
            halt: false,
            rd_addr: 5,
            rd_wdata: 1,
            frd_addr: 0,
            frd_wdata: 0,
        }];
        let file = g6q_diag::RecordFile::from_model_and_records(&m, records);
        let text = file.to_json().to_pretty();
        std::fs::File::create(&json)
            .unwrap()
            .write_all(text.as_bytes())
            .unwrap();

        let args = Args::parse([
            "tandem",
            "--under-test",
            dasm.to_str().unwrap(),
            "--reference",
            json.to_str().unwrap(),
        ]);
        assert!(cmd_tandem(&args).is_ok());
    }
}

/// `fw` — fetch, build or inspect firmware wiring.
///
/// `fw fetch` clones the pinned OpenSBI source into `out/fw-src/opensbi` (or `--fw-src`).
/// `fw build` compiles it with the requested cross-toolchain.
fn cmd_fw(args: &Args) -> Result<(), String> {
    match args.positionals.get(1).map(String::as_str) {
        Some("fetch") => return fw_fetch(args),
        Some("build") => return fw_build(args),
        _ => {}
    }

    if args.flag("fw-print-region") {
        let path = args
            .value("fw")
            .or_else(|| args.value("elf"))
            .or_else(|| args.value("fw-payload"))
            .ok_or("--fw-print-region needs one of --fw, --elf or --fw-payload")?;
        let bytes = std::fs::read(path).map_err(|e| format!("cannot read {path}: {e}"))?;
        let j = Json::obj(vec![
            ("path", Json::str(path)),
            ("bytes", Json::Int(bytes.len() as i64)),
            (
                "note",
                Json::str("raw size; ELF parsing and segment layout are a later Q2 pass"),
            ),
        ]);
        print!("{}", j.to_pretty());
    }

    let boot = resolve::boot_options(args);
    print!("{}", boot.to_json().to_pretty());
    Ok(())
}

/// `fw fetch` — clone the pinned OpenSBI source into the requested source directory.
fn fw_fetch(args: &Args) -> Result<(), String> {
    let pins_path = Pins::find(std::env::current_dir().unwrap_or_default().as_path())
        .ok_or("cannot find pins.toml; run from inside the package")?;
    let pins = Pins::from_file(&pins_path).map_err(|e| format!("cannot read pins.toml: {e}"))?;

    let url = pins
        .get("opensbi", "url")
        .ok_or("pins.toml [opensbi] is missing 'url'")?;
    let rev = pins
        .get("opensbi", "ref")
        .ok_or("pins.toml [opensbi] is missing 'ref'")?;

    let src = args
        .value("fw-src")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::path::PathBuf::from("out/fw-src/opensbi"));

    if src.is_dir() && std::fs::read_dir(&src).map(|d| d.count()).unwrap_or(0) > 0 {
        return Err(format!(
            "firmware source directory already exists and is not empty: {}",
            src.display()
        ));
    }

    if args.flag("dry-run") {
        let j = Json::obj([
            ("url", Json::str(url)),
            ("ref", Json::str(rev)),
            ("dst", Json::str(&*src.to_string_lossy())),
            (
                "command",
                Json::str(format!(
                    "git clone --depth 1 --branch {rev} {url} {}",
                    src.display()
                )),
            ),
        ]);
        print!("{}", j.to_pretty());
        return Ok(());
    }

    let git = std::process::Command::new("git")
        .args([
            "clone",
            "--depth",
            "1",
            "--branch",
            rev,
            url,
            &src.to_string_lossy(),
        ])
        .status()
        .map_err(|e| format!("failed to run git: {e}"))?;

    if !git.success() {
        return Err(format!("git clone failed with status {git:?}"));
    }

    let j = Json::obj([
        ("url", Json::str(url)),
        ("ref", Json::str(rev)),
        ("dst", Json::str(&*src.to_string_lossy())),
        ("status", Json::str("fetched")),
    ]);
    print!("{}", j.to_pretty());
    Ok(())
}

/// `fw build` — compile the fetched OpenSBI source with a cross-toolchain.
fn fw_build(args: &Args) -> Result<(), String> {
    let pins_path = Pins::find(std::env::current_dir().unwrap_or_default().as_path())
        .ok_or("cannot find pins.toml; run from inside the package")?;
    let pins = Pins::from_file(&pins_path).map_err(|e| format!("cannot read pins.toml: {e}"))?;

    let src = args
        .value("fw-src")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::path::PathBuf::from("out/fw-src/opensbi"));
    if !args.flag("dry-run") && !src.join("Makefile").is_file() {
        return Err(format!(
            "no OpenSBI source at {}; run `fw fetch` first",
            src.display()
        ));
    }

    let platform = args
        .value("fw-platform")
        .or_else(|| pins.get("opensbi", "platform"))
        .unwrap_or("generic");
    let text_start = args
        .value("fw-text-start")
        .or_else(|| pins.get("opensbi", "fw_text_start"))
        .unwrap_or("0x80000000");

    let (cross, use_wsl) = detect_cross_compile(args)?;

    let mode = args.value_or("fw-mode", "dynamic");
    let mut make_args = vec![
        format!("CROSS_COMPILE={cross}"),
        format!("PLATFORM={platform}"),
        format!("FW_TEXT_START={text_start}"),
    ];

    // Match the firmware's hart count to the model or device tree when available.
    // OpenSBI's generic platform uses this to size its internal hart arrays.
    let platform_hart_count = fw_build_hart_count(args);
    if let Some(harts) = platform_hart_count {
        make_args.push(format!("PLATFORM_HART_COUNT={harts}"));
    }

    match mode {
        "dynamic" => make_args.push("FW_DYNAMIC=y".into()),
        "jump" => {
            make_args.push("FW_JUMP=y".into());
            let addr = args
                .value("fw-jump-addr")
                .ok_or("--fw-mode jump requires --fw-jump-addr")?;
            make_args.push(format!("FW_JUMP_ADDR={addr}"));
        }
        "payload" => {
            make_args.push("FW_PAYLOAD=y".into());
            let payload = args
                .value("fw-payload")
                .ok_or("--fw-mode payload requires --fw-payload")?;
            make_args.push(format!(
                "FW_PAYLOAD_PATH={}",
                make_path_arg(&PathBuf::from(payload), use_wsl)?
            ));
        }
        other => return Err(format!("unsupported fw mode `{other}`")),
    }

    for extra in args.values("fw-make") {
        if extra.contains('=') {
            make_args.push(extra.clone());
        } else {
            return Err(format!("--fw-make value must be VAR=VAL: `{extra}`"));
        }
    }

    let fw_out = args
        .value("fw-out")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::path::PathBuf::from("out/fw"));

    let mut fdt_path: Option<PathBuf> = None;
    let mut fdt_auto_blob: Option<Vec<u8>> = None;
    if let Some(fdt) = args.value("fw-fdt") {
        if fdt == "auto" {
            let resolved = resolve::resolve(args)?;
            fdt_auto_blob = Some(resolved_dts_blob(args, &resolved)?);
            let dtb_out = fw_out.join("fdt_auto.dtb");
            make_args.push(format!("FW_FDT_PATH={}", make_path_arg(&dtb_out, use_wsl)?));
            fdt_path = Some(dtb_out);
        } else {
            let fdt_path_buf = PathBuf::from(fdt);
            make_args.push(format!(
                "FW_FDT_PATH={}",
                make_path_arg(&fdt_path_buf, use_wsl)?
            ));
            fdt_path = Some(fdt_path_buf);
        }
    }

    if args.flag("dry-run") {
        let src_arg = make_path_arg(&src, use_wsl)?;
        let command = if use_wsl {
            format!("wsl make -C {src_arg} {}", make_args.join(" "))
        } else {
            format!("make -C {src_arg} {}", make_args.join(" "))
        };
        let j = Json::obj([
            ("src", Json::str(&*src.to_string_lossy())),
            ("mode", Json::str(mode)),
            ("platform", Json::str(platform)),
            ("cross_compile", Json::str(&cross)),
            ("fw_out", Json::str(&*fw_out.to_string_lossy())),
            (
                "fw_fdt",
                Json::str(
                    &*fdt_path
                        .as_ref()
                        .map_or_else(|| "none".to_string(), |p| p.to_string_lossy().into_owned()),
                ),
            ),
            (
                "platform_hart_count",
                platform_hart_count.map_or(Json::Null, |h| Json::Int(h as i64)),
            ),
            ("wsl", Json::str(if use_wsl { "yes" } else { "no" })),
            ("command", Json::str(command)),
        ]);
        print!("{}", j.to_pretty());
        return Ok(());
    }

    if let Some(blob) = fdt_auto_blob {
        let dtb_out = fdt_path
            .as_ref()
            .expect("fdt_path set when fdt_auto_blob is set");
        std::fs::create_dir_all(&fw_out)
            .map_err(|e| format!("cannot create {}: {e}", fw_out.display()))?;
        std::fs::write(dtb_out, &blob)
            .map_err(|e| format!("cannot write {}: {e}", dtb_out.display()))?;
    }

    let src_arg = make_path_arg(&src, use_wsl)?;
    let make = if use_wsl {
        std::process::Command::new("wsl")
            .arg("make")
            .arg("-C")
            .arg(&src_arg)
            .args(&make_args)
            .status()
    } else {
        std::process::Command::new("make")
            .arg("-C")
            .arg(&src)
            .args(&make_args)
            .status()
    }
    .map_err(|e| format!("failed to run make: {e}"))?;

    if !make.success() {
        return Err(format!("OpenSBI build failed with status {make:?}"));
    }

    let built_dir = src.join(format!("build/platform/{platform}/firmware/"));
    std::fs::create_dir_all(&fw_out)
        .map_err(|e| format!("cannot create output directory {}: {e}", fw_out.display()))?;
    let mut staged: Vec<String> = Vec::new();
    for ext in ["bin", "elf"] {
        let src_file = built_dir.join(format!("fw_{mode}.{ext}"));
        if src_file.is_file() {
            let dst_file = fw_out.join(format!("fw_{mode}.{ext}"));
            std::fs::copy(&src_file, &dst_file).map_err(|e| {
                format!(
                    "cannot copy {} to {}: {e}",
                    src_file.display(),
                    dst_file.display()
                )
            })?;
            staged.push(dst_file.to_string_lossy().into_owned());
        }
    }

    let j = Json::obj([
        ("src", Json::str(&*src.to_string_lossy())),
        ("mode", Json::str(mode)),
        ("platform", Json::str(platform)),
        ("cross_compile", Json::str(&cross)),
        ("built_dir", Json::str(&*built_dir.to_string_lossy())),
        ("fw_out", Json::str(&*fw_out.to_string_lossy())),
        (
            "fw_fdt",
            Json::str(
                &*fdt_path
                    .as_ref()
                    .map_or_else(|| "none".to_string(), |p| p.to_string_lossy().into_owned()),
            ),
        ),
        (
            "platform_hart_count",
            platform_hart_count.map_or(Json::Null, |h| Json::Int(h as i64)),
        ),
        ("staged", Json::arr(staged.into_iter().map(Json::str))),
        ("status", Json::str("built")),
    ]);
    print!("{}", j.to_pretty());
    Ok(())
}

/// True when `wsl` is on the host PATH.
fn wsl_available() -> bool {
    which("wsl")
}

/// Check whether a command exists inside the default WSL distribution.
fn wsl_which(cmd: &str) -> bool {
    std::process::Command::new("wsl")
        .arg("which")
        .arg(cmd)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

/// Convert a path for use as a `make` argument. In WSL mode the path is made absolute,
/// translated to a WSL path, and converted to forward slashes; otherwise backslashes are
/// replaced by forward slashes.
fn make_path_arg(p: &std::path::Path, use_wsl: bool) -> Result<String, String> {
    if use_wsl {
        let abs = if p.is_absolute() {
            p.to_path_buf()
        } else {
            std::env::current_dir()
                .map_err(|e| format!("cannot determine current directory: {e}"))?
                .join(p)
        };
        to_wsl_path(&abs)
    } else {
        Ok(p.to_string_lossy().replace('\\', "/"))
    }
}

/// Convert an absolute Windows path to its WSL equivalent. Relative paths are left as-is
/// (with backslashes replaced by forward slashes so WSL make sees a portable path).
fn to_wsl_path(p: &std::path::Path) -> Result<String, String> {
    let with_slashes = p.to_string_lossy().replace('\\', "/");
    if !p.is_absolute() {
        return Ok(with_slashes);
    }
    let out = std::process::Command::new("wsl")
        .arg("wslpath")
        .arg("-u")
        .arg(&with_slashes)
        .output()
        .map_err(|e| format!("failed to run wsl wslpath -u: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "wsl wslpath -u failed: {}",
            String::from_utf8_lossy(&out.stderr)
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

/// Locate a RISC-V cross-toolchain prefix from `--cross-compile`, `CROSS_COMPILE`, or
/// common names on the PATH.
fn detect_cross_compile(args: &Args) -> Result<(String, bool), String> {
    if let Some(p) = args.value("cross-compile") {
        let wsl = cfg!(windows) && wsl_available() && wsl_which(&format!("{p}gcc"));
        return Ok((p.to_string(), wsl));
    }
    if let Ok(p) = std::env::var("CROSS_COMPILE") {
        let wsl = cfg!(windows) && wsl_available() && wsl_which(&format!("{p}gcc"));
        return Ok((p, wsl));
    }

    // On Windows, OpenSBI's Makefile requires a POSIX shell and a PIE-capable linker.
    // Prefer WSL toolchains in that order before falling back to a native Windows xPack.
    if cfg!(windows) && wsl_available() {
        let wsl_candidates = [
            "riscv64-linux-gnu-",
            "riscv64-unknown-freebsd-",
            "riscv64-unknown-elf-",
            "riscv-none-elf-",
        ];
        for prefix in wsl_candidates {
            let gcc = format!("{prefix}gcc");
            if wsl_which(&gcc) {
                return Ok((prefix.into(), true));
            }
        }
    }

    let native_candidates = [
        "riscv-none-elf-",
        "riscv64-unknown-elf-",
        "riscv64-unknown-linux-gnu-",
        "riscv64-linux-gnu-",
        "riscv64-none-elf-",
    ];
    for prefix in native_candidates {
        let gcc = format!("{prefix}gcc");
        if which(&gcc) {
            return Ok((prefix.into(), false));
        }
    }

    if cfg!(windows) && wsl_available() {
        return Err(
            "no RISC-V cross-toolchain found on Windows PATH or in WSL; \
             install a WSL riscv64-linux-gnu toolchain, or set CROSS_COMPILE"
                .into(),
        );
    }

    Err("no RISC-V cross-toolchain found; set CROSS_COMPILE or --cross-compile".into())
}

fn which(cmd: &str) -> bool {
    std::process::Command::new("where")
        .arg(cmd)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

/// Find the first peripheral whose id or model matches one of the aliases.
fn find_peripheral<'a>(
    model: &'a TargetModel,
    aliases: &[&str],
) -> Option<&'a g6q_core::model::Peripheral> {
    model.soc.peripherals.iter().find(|p| {
        let id = p.id.to_lowercase();
        let model = p.model.as_deref().unwrap_or("").to_lowercase();
        aliases.iter().any(|a| id.contains(a) || model.contains(a))
    })
}

/// `run` — execute a design using the native VM, stock QEMU, or just show argv.
///
/// `run --backend native` is the flat-image Rust VM harness.
/// `run --backend args` prints the B0 stock-QEMU argv.
/// `run --backend qemu` spawns `qemu-system-riscv64` (or `--qemu-path`).
fn cmd_run(args: &Args) -> Result<(), String> {
    let backend = args.value_or("backend", "native");
    match backend {
        "native" => run_native(args),
        "args" => run_args(args),
        "qemu" => run_qemu(args),
        other => Err(format!(
            "`--backend {other}` is not implemented; use native, args or qemu"
        )),
    }
}

fn run_native(args: &Args) -> Result<(), String> {
    let image = args.value("image");
    let restore = args.value("restore");
    if image.is_none() && restore.is_none() {
        return Err("run --backend native needs --image FILE or --restore CHECKPOINT".into());
    }
    let steps = args
        .value_or("steps", "1000000")
        .parse::<u64>()
        .map_err(|_| "--steps must be a positive integer".to_string())?;

    // Resolve what we can from the command line and derive reset / memory / xlen from the
    // model rather than a hard-coded constant.  Native can still run with no target at all,
    // in which case the defaults take over.
    let resolved = resolve::resolve(args)?;
    let model = g6q_ingest::assemble(&resolved.sources);
    if !model.conformance.passes_strict() {
        eprintln!("g6lc-qemu: warning: model does not pass strict conformance");
    }

    let (base, dram_len) = model.soc.dram.unwrap_or((0x8000_0000, 0x1000_0000));
    let base = if let Some(b) = args.value("base") {
        parse_addr(b)?
    } else {
        base
    };
    let xlen = if model.isa.xlen == 0 {
        eprintln!("g6lc-qemu: warning: xlen not in model; defaulting to 64");
        64
    } else if model.isa.xlen != 32 && model.isa.xlen != 64 {
        return Err(format!(
            "unsupported xlen {}; must be 32 or 64",
            model.isa.xlen
        ));
    } else {
        model.isa.xlen
    };

    let mut mem = PhysMem::new();
    mem.add(Region::new(base, dram_len));

    // Place CLINT, PLIC and UART from the model's peripheral list when it provides them;
    // otherwise fall back to the conventional addresses the tests and fixtures use.
    let clint = find_peripheral(&model, &["clint"])
        .map(|p| (p.base, p.len))
        .unwrap_or((0x0200_0000, 0x10000));
    let plic = find_peripheral(&model, &["intc", "plic"])
        .map(|p| (p.base, p.len))
        .unwrap_or((0x0c00_0000, 0x40_0000));
    let uart = find_peripheral(&model, &["uart", "serial"])
        .map(|p| (p.base, p.len))
        .unwrap_or((0x1000_0000, 0x100));

    let harts = model.soc.harts_total.max(1) as usize;
    mem.add_device(Device::new(
        clint.0,
        clint.1,
        DeviceKind::Clint(Clint::new(harts)),
    ));
    let plic_sources = model.soc.intc_sources.max(1);
    let plic_contexts = model.soc.intc_targets.max(1);
    mem.add_device(Device::new(
        plic.0,
        plic.1,
        DeviceKind::Plic(Plic::new(plic_sources, plic_contexts)),
    ));
    mem.add_device(Device::new(uart.0, uart.1, DeviceKind::Uart(Uart::new())));

    let mut hart = Hart::with_isa(base, &model.isa);

    // Wire an AI island when the model exposes one.
    if let Some(ai) = &model.soc.ai_island {
        let ai_base = find_peripheral(&model, &["ai-island"])
            .map(|p| (p.base, p.len))
            .unwrap_or((0x3000_0000, 0x1000));
        let mut ai_island = AiIsland::new();
        ai_island.set_ai_model(ai);
        let unsourced = ai_island.cap_unsourced();
        if !unsourced.is_empty() {
            // Tracked, not silent: a capability the guest reads as zero is
            // indistinguishable from a real answer, so name the ones we cannot source.
            let names: Vec<&str> = unsourced.iter().map(|(n, _)| n.as_str()).collect();
            eprintln!(
                "g6lc-qemu: warning: {} AI capability word(s) cannot be sourced from the \
                 model and are absent from the window: {}",
                names.len(),
                names.join(", ")
            );
        }
        if !ai.config.placement_resolved() {
            // Loud, because a guest cannot address an island whose windows are unplaced,
            // and the failure would otherwise look like a descriptor or driver bug.
            eprintln!(
                "g6lc-qemu: warning: AI-island MMIO placement is unresolved \
                 (capability and descriptor window bases were not found in the design's \
                 configuration package); the descriptor window falls back to offset 0 and \
                 the capability window is not decoded"
            );
        }
        mem.add_device(Device::new(
            ai_base.0,
            ai_base.1,
            DeviceKind::AiIsland(ai_island),
        ));
        hart.ai_instr_set = Some(ai.instr_set.clone());
        hart.ai_model = Some(ai.clone());
    }

    if let Some(image) = image {
        let bytes = std::fs::read(image).map_err(|e| format!("cannot read {image}: {e}"))?;
        for (i, b) in bytes.iter().enumerate() {
            mem.write_le::<1>(base + i as u64, *b as u64)
                .map_err(|e| format!("cannot load binary: {e}"))?;
        }
    }

    hart.csr.mtvec = 0x9000_0000;
    // A default trap handler that self-loops so an unhandled ecall does not run away.
    mem.add(Region::new(0x9000_0000, 0x1000));
    mem.write_le::<4>(0x9000_0000, 0x0000_006f)
        .map_err(|e| format!("trap handler: {e}"))?;

    if let Some(path) = restore {
        let cp = g6q_diag::read_checkpoint(path)
            .map_err(|e| format!("cannot read checkpoint {path}: {e}"))?;
        hart.restore(&mut mem, &cp);
        eprintln!("g6lc-qemu: restored {path}");
    }

    let halt = if let Some(path) = args.value("replay") {
        let file = g6q_diag::read_record_file(path)
            .map_err(|e| format!("cannot read replay {path}: {e}"))?;
        hart.run_replay(&mut mem, xlen as u8, steps, &file.records)
    } else {
        hart.run(&mut mem, xlen as u8, steps)
    };

    if let Some(u) = mem.uart() {
        let out = String::from_utf8_lossy(&u.output);
        if !out.is_empty() {
            print!("{out}");
        }
    }

    if let Halt::ReplayDivergence(idx, diffs) = &halt {
        return Err(format!(
            "replay diverged at record {idx}: {}",
            diffs
                .iter()
                .map(|d| format!("{}: {} != {}", d.field, d.lhs, d.rhs))
                .collect::<Vec<_>>()
                .join("; ")
        ));
    }

    if let Some(path) = args.value("record") {
        let mut m = model.clone();
        m.target_id = args.value("target").unwrap_or("native").to_string();
        let file = g6q_diag::RecordFile::from_model_and_records(&m, hart.records.clone());
        g6q_diag::write_record_file(path, &file)
            .map_err(|e| format!("cannot write {path}: {e}"))?;
        eprintln!("g6lc-qemu: wrote {path}");
    }

    if let Some(path) = args.value("checkpoint") {
        let cp = hart.checkpoint(&mem);
        g6q_diag::write_checkpoint(path, &cp).map_err(|e| format!("cannot write {path}: {e}"))?;
        eprintln!("g6lc-qemu: wrote {path}");
    }

    if let Some(path) = args.value("tensor") {
        if let Some(ai) = mem.ai_island_mut() {
            let mut trace = TensorTrace {
                events: ai.drain_events(),
                flags_layout: None,
            };
            if let Some(island) = model.soc.ai_island.as_ref() {
                trace.flags_layout = island.desc_layout.flags_layout;
            }
            let header = g6q_diag::ArtifactHeader::from_model(&model);
            let artifact = TensorArtifact::new(header, trace);
            std::fs::write(path, artifact.to_json().to_pretty())
                .map_err(|e| format!("cannot write {path}: {e}"))?;
            eprintln!("g6lc-qemu: wrote {path}");
        }
    }

    if args.flag("verbose") {
        eprintln!("g6lc-qemu: native run halted: {halt:?}");
        eprintln!("  instructions retired: {}", hart.instret);
    }

    Ok(())
}

fn run_args(args: &Args) -> Result<(), String> {
    let resolved = resolve::resolve(args)?;
    let model = g6q_ingest::assemble(&resolved.sources);
    if !model.conformance.passes_strict() {
        eprintln!("g6lc-qemu: warning: model does not pass strict conformance");
    }
    let text = emit_args(args, &resolved, &model)?;
    if let Some(path) = args.value("json-out") {
        write_out(path, &text)?;
        eprintln!("g6lc-qemu: wrote {path}");
    } else {
        print!("{text}");
    }
    Ok(())
}

fn run_qemu(args: &Args) -> Result<(), String> {
    let resolved = resolve::resolve(args)?;
    let model = g6q_ingest::assemble(&resolved.sources);
    if !model.conformance.passes_strict() {
        eprintln!("g6lc-qemu: warning: model does not pass strict conformance");
    }

    let mut boot = resolve::boot_options(args);
    g6q_emit_args::check_profile(&model, &boot)?;
    let record = args.value("record").map(str::to_string);
    if let Some(record_path) = &record {
        let plugin_so = args
            .value("plugin")
            .map(str::to_string)
            .unwrap_or_else(|| plugin_path(args, &model));
        let trace_tmp = format!("{record_path}.g6q-trace-tmp");
        boot.plugin = Some(format!("{plugin_so},trace={trace_tmp}"));
    } else if args.flag("plugin") || args.value("plugin").is_some() {
        boot.plugin = Some(plugin_path(args, &model));
    }

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
        // No capability row for this token: it is either a base MISA letter (i, m)
        // or a non-QEMU property. Stock `-cpu rv64` already carries the base ISA,
        // so emit nothing rather than an invalid property.
        Vec::new()
    };

    // Use the generated B1 machine by default; --stock-machine / --stock-cpu select B0 stock QEMU.
    let (machine, cpu_base) =
        if args.value("stock-machine").is_some() || args.value("stock-cpu").is_some() {
            (
                args.value_or("stock-machine", "virt").to_string(),
                args.value_or("stock-cpu", "rv64").to_string(),
            )
        } else {
            (
                format!(
                    "g6lc-{}",
                    g6q_emit_qemu::machine::machine_name(&model.target_id)
                ),
                String::new(),
            )
        };
    let stock = g6q_emit_args::StockTarget { machine, cpu_base };
    let argv = g6q_emit_args::build_argv(&model, &stock, &boot, &properties_for);

    let binary = args.value_or("qemu-path", "qemu-system-riscv64");

    if args.flag("dry-run") {
        println!("{} {}", binary, argv.join(" "));
        return Ok(());
    }

    let mut cmd = std::process::Command::new(binary);
    cmd.args(&argv);
    let status = cmd
        .status()
        .map_err(|e| format!("failed to spawn `{binary}`: {e}"))?;
    if !status.success() {
        return Err(format!("`{binary}` exited with status {status}"));
    }

    if let Some(record_path) = record {
        let trace_tmp = format!("{record_path}.g6q-trace-tmp");
        if std::path::Path::new(&trace_tmp).exists() {
            std::fs::copy(&trace_tmp, &record_path)
                .map_err(|e| format!("cannot copy trace {trace_tmp} to {record_path}: {e}"))?;
            std::fs::remove_file(&trace_tmp)
                .map_err(|e| format!("cannot remove temporary trace {trace_tmp}: {e}"))?;
            eprintln!("g6lc-qemu: wrote {record_path}");
        } else {
            eprintln!("g6lc-qemu: warning: no trace produced at {trace_tmp}; was the plugin loaded and did QEMU exit cleanly?");
        }
    }

    Ok(())
}

/// Default plugin `.so` path, or the user-supplied one after `--plugin`.
fn plugin_path(args: &Args, model: &TargetModel) -> String {
    if let Some(p) = args.value("plugin") {
        return p.to_string();
    }
    let name = g6q_emit_qemu::machine::machine_name(&model.target_id);
    format!(
        "out/emit/{}/contrib/plugins/g6lc-{}.so",
        model.target_id, name
    )
}

fn parse_addr(s: &str) -> Result<u64, String> {
    if let Some(hex) = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")) {
        u64::from_str_radix(hex, 16).map_err(|_| format!("bad hex address `{s}`"))
    } else {
        s.parse::<u64>()
            .map_err(|_| format!("address must be decimal or 0x-prefixed hex: `{s}`"))
    }
}

fn parse_bootrom(s: &str) -> Result<(u64, u64), String> {
    let (base, len) = s
        .split_once(':')
        .or_else(|| s.split_once(','))
        .ok_or_else(|| "--bootrom must be BASE:LEN or BASE,LEN (e.g. 0x1000:0xf000)".to_string())?;
    Ok((parse_addr(base.trim())?, parse_addr(len.trim())?))
}

/// Parse either a plain record array or a `RecordFile` object.
fn load_records(text: &str) -> Result<Vec<g6q_diag::CommitRecord>, String> {
    let j = Json::parse(text).map_err(|e| format!("invalid JSON: {e}"))?;
    if let Some(rf) = g6q_diag::RecordFile::from_json(&j) {
        return Ok(rf.records);
    }
    g6q_diag::records_from_json(&j)
        .ok_or_else(|| "expected a JSON array of records or a record file".to_string())
}

/// `tandem` — compare an under-test record stream with a reference.
fn load_records_from_file(path: &str) -> Result<Vec<g6q_diag::CommitRecord>, String> {
    if path.ends_with(".dasm") {
        return g6q_diag::rvfi::parse_dasm_file(Path::new(path));
    }
    let text = std::fs::read_to_string(path).map_err(|e| format!("cannot read {path}: {e}"))?;
    load_records(&text)
}

/// `tandem` — compare an under-test record stream with a reference.
fn cmd_tandem(args: &Args) -> Result<(), String> {
    let under = args
        .value("under-test")
        .ok_or("tandem needs --under-test FILE")?;
    let reference = args
        .value("reference")
        .ok_or("tandem needs --reference FILE")?;

    let under_test = load_records_from_file(under)?;
    let reference = load_records_from_file(reference)?;

    let report = g6q_diag::tandem_report(&under_test, &reference);
    print!("{}", report.to_pretty());

    if let Json::Obj(o) = &report {
        if let Some(Json::Bool(false)) = o.get("divergence") {
            return Ok(());
        }
    }
    Err("tandem divergence detected".to_string())
}

/// `diag` — emit D2 microarchitectural counters from the resolved target.
fn cmd_diag(args: &Args) -> Result<(), String> {
    let resolved = resolve::resolve(args)?;
    let mut model = g6q_ingest::assemble(&resolved.sources);

    if !model.diagnosable() && !args.flag("allow-virt-diag") {
        return Err(
            "the virt profile is not diagnosable by default; use --allow-virt-diag to taint output"
                .into(),
        );
    }

    // A host-supplied measured DRAM bandwidth closes the roofline even when the design has
    // not yet published one. This is the F11 loop from the host side.
    if let Some(v) = args.value("measured-dram-gbps-x1000") {
        let measured: u32 = v.parse().map_err(|_| {
            format!("--measured-dram-gbps-x1000 must be a non-negative integer, got {v}")
        })?;
        if let Some(ref mut ai) = model.soc.ai_island {
            ai.config.measured_dram_gbps_x1000 = Some(measured);
        }
    }

    let mut counters = g6q_diag::model_counters(&model);

    let tensor_paths: Vec<&str> = args.values("tensor").iter().map(String::as_str).collect();
    match tensor_paths.as_slice() {
        [] => {}
        [path] => {
            let artifact = g6q_diag::ai_tensor::TensorArtifact::from_file(path)?;
            counters.extend(g6q_diag::ai_tensor::tensor_counters(&artifact.trace.events));
        }
        [left, right] => {
            let left = g6q_diag::ai_tensor::TensorArtifact::from_file(left)?;
            let right = g6q_diag::ai_tensor::TensorArtifact::from_file(right)?;
            if let Some(diff) = left.compare(&right) {
                return Err(format!("tensor artifact divergence: {diff}"));
            }
            counters.extend(g6q_diag::ai_tensor::tensor_counters(&left.trace.events));
        }
        _ => return Err("diag --tensor accepts one or two artifacts".into()),
    }

    let arr = Json::arr(counters.iter().map(|c| c.to_json()).collect::<Vec<_>>());
    let text = arr.to_pretty();

    if let Some(path) = args.value("uarch-out") {
        write_out(path, &text)?;
        eprintln!("g6lc-qemu: wrote {path}");
    } else {
        print!("{text}");
    }

    eprintln!("\nnot verification evidence; a hypothesis and a checkpoint only");
    Ok(())
}
