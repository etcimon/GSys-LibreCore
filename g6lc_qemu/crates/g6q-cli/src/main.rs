// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! `g6lc-qemu` — the command-line tool.
//!
//! The full option surface is specified in `architecture/CLI.md`. At stage Q0 the verbs
//! are registered and self-describing but not implemented: each one reports the stage
//! that will deliver it rather than pretending to work. That is deliberate — a verb that
//! silently does nothing is worse than one that says it is not built yet.

#![forbid(unsafe_code)]

mod args;

use args::Args;
use g6q_core::model::Profile;
use g6q_core::{Inputs, Json, Report, Row, TargetModel, SCHEMA_VERSION, STAGE};

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
        let args = Args::parse(["gen", "--target", "x"]);
        let err = dispatch("gen", &args).unwrap_err();
        assert!(err.contains("stage Q1"), "{err}");
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
}
