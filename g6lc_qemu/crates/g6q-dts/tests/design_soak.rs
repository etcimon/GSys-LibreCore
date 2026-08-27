// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Opt-in soak against the device trees of a real design tree.
//!
//! Skips itself unless `G6Q_DESIGN_ROOT` points at a checkout, so the package's own tests
//! stay standalone (KD0). Nothing from that tree is copied into fixtures.
//!
//! ```text
//! G6Q_DESIGN_ROOT=/path/to/design cargo test -p g6q-dts -- --nocapture
//! ```

use std::path::{Path, PathBuf};

use g6q_dts::{extract, parse};

fn design_root() -> Option<PathBuf> {
    let p = PathBuf::from(std::env::var("G6Q_DESIGN_ROOT").ok()?);
    p.is_dir().then_some(p)
}

fn board_trees(root: &Path) -> Vec<PathBuf> {
    let dir = root.join("corev_apu").join("bootrom");
    let Ok(entries) = std::fs::read_dir(&dir) else {
        return Vec::new();
    };
    let mut out: Vec<PathBuf> = entries
        .filter_map(Result::ok)
        .map(|e| e.path())
        .filter(|p| p.extension().and_then(|s| s.to_str()) == Some("dts"))
        .collect();
    out.sort();
    out
}

#[test]
fn every_board_tree_parses_and_yields_facts() {
    let Some(root) = design_root() else {
        eprintln!("skipped: set G6Q_DESIGN_ROOT to a design checkout to run this soak");
        return;
    };
    let trees = board_trees(&root);
    assert!(
        !trees.is_empty(),
        "no device trees found under {}",
        root.display()
    );

    let mut failures = Vec::new();
    for path in &trees {
        let name = path.file_name().unwrap().to_string_lossy().to_string();
        let text = std::fs::read_to_string(path).expect("readable");
        let facts = extract(&parse(&text));

        println!(
            "{name:<32} cpus={:<2} cores={:<5} threads={:<5} ext={:<3} mmu={:<6} mem={:<24} devs={:<2} ndev={:?}",
            facts.cpu_count,
            facts.cores.map(|c| c.to_string()).unwrap_or_else(|| "-".into()),
            facts.threads_per_core.map(|t| t.to_string()).unwrap_or_else(|| "-".into()),
            facts.extensions.tokens().len(),
            facts.mmu_mode.as_deref().unwrap_or("-"),
            facts
                .memory
                .map(|(b, l)| format!("{b:#x}+{l:#x}"))
                .unwrap_or_else(|| "-".into()),
            facts.devices.len(),
            facts.intc_sources,
        );

        // A board tree must describe at least one hart and one device.
        if facts.cpu_count == 0 {
            failures.push(format!("{name}: no cpu nodes parsed"));
        }
        if facts.devices.is_empty() {
            failures.push(format!("{name}: no system-bus devices parsed"));
        }
        // Vendor-prefixed compatibles must survive intact, not be split on the comma.
        for d in &facts.devices {
            if let Some(c) = &d.compatible {
                if c.starts_with(',') || c.ends_with(',') {
                    failures.push(format!("{name}: mangled compatible {c:?} on {}", d.name));
                }
            }
        }
    }

    println!("\n{} device tree(s) read", trees.len());
    assert!(
        failures.is_empty(),
        "soak failures:\n  {}",
        failures.join("\n  ")
    );
}

#[test]
fn reading_a_real_tree_is_deterministic() {
    let Some(root) = design_root() else {
        return;
    };
    for path in board_trees(&root).into_iter().take(4) {
        let text = std::fs::read_to_string(&path).expect("readable");
        assert_eq!(extract(&parse(&text)), extract(&parse(&text)));
    }
}
