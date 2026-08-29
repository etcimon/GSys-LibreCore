// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! B1 device-tree emission.
//!
//! Generates a flattened device tree from `TargetModel` and emits it as an
//! embedded `uint8_t` array inside a GPL C file, plus a matching header.
//!
//! The tree is built directly in `g6q_dts::Node` form rather than via a DTS
//! source string, so there is no intermediate source parse and phandle numbers
//! stay under the emitter's control.

use crate::{machine::merged_peripherals, Emission, EmittedFile};
use g6q_core::model::{Peripheral, TargetModel};
use g6q_dts::{Node, Prop};
use std::fmt::Write as _;

/// Convert a 64-bit physical address or size into the two 32-bit cells used
/// when `#address-cells` and `#size-cells` are both 2.
fn hi_lo(v: u64) -> [u64; 2] {
    [v >> 32, v & 0xffff_ffff]
}

/// Build a `reg` property for a device under the root or `soc` bus.
fn addr_size_reg(base: u64, len: u64) -> Prop {
    let b = hi_lo(base);
    let l = hi_lo(len);
    Prop::Cells(vec![b[0], b[1], l[0], l[1]])
}

/// A single string property.
fn s(v: &str) -> Prop {
    Prop::Strings(vec![v.to_string()])
}

/// A single-cell numeric property.
fn cell(v: u64) -> Prop {
    Prop::Cells(vec![v])
}

/// Convert live ISA extension tokens into a canonical `riscv,isa` string.
///
/// If the model already carries an explicit `isa_string`, that is used.
/// Otherwise the string is assembled from `base` and the live extensions.
fn isa_string(model: &TargetModel) -> String {
    if !model.isa.isa_string.is_empty() {
        return model.isa.isa_string.clone();
    }

    // RISC-V canonical order for standard single-letter extensions.
    const ORDER: &[&str] = &[
        "m", "a", "f", "d", "g", "q", "l", "c", "b", "j", "k", "t", "p", "v", "h", "s", "u", "n",
    ];

    let base = model.isa.base.as_str();
    let (xlen, base_letter) = if let Some(b) = base.strip_prefix("rv32") {
        ("rv32", b)
    } else if let Some(b) = base.strip_prefix("rv64") {
        ("rv64", b)
    } else {
        ("rv64", "i")
    };

    let mut single: Vec<&str> = Vec::new();
    let mut multi: Vec<&str> = Vec::new();

    for (token, verdict) in &model.isa.extensions {
        if verdict != "live" {
            continue;
        }
        let t = token.as_str();
        if t == base_letter {
            continue;
        }
        if ORDER.contains(&t) {
            if !single.contains(&t) {
                single.push(t);
            }
        } else if t.len() > 1 && !multi.contains(&t) {
            multi.push(t);
        }
    }

    single.sort_by_key(|a| ORDER.iter().position(|o| *o == *a).unwrap_or(ORDER.len()));
    multi.sort();

    let mut out = format!("{xlen}{base_letter}");
    for t in &single {
        out.push_str(t);
    }
    if !multi.is_empty() {
        out.push('_');
        out.push_str(&multi.join("_"));
    }
    out
}

/// Live multi-letter ISA extension tokens, for `riscv,isa-extensions`.
fn isa_extensions(model: &TargetModel) -> Prop {
    let mut tokens: Vec<String> = model
        .isa
        .extensions
        .iter()
        .filter(|(_, v)| v == "live")
        .map(|(t, _)| t.clone())
        .collect();
    tokens.sort();
    tokens.dedup();
    Prop::Strings(tokens)
}

/// Build the device-tree `Node` tree directly from the model.
fn build_dts(model: &TargetModel) -> Node {
    let mut root = Node {
        name: "/".into(),
        ..Node::default()
    };
    root.props.insert("#address-cells".into(), cell(2));
    root.props.insert("#size-cells".into(), cell(2));
    root.props.insert(
        "compatible".into(),
        s(&format!("g6lc,{}", sanitize(&model.target_id))),
    );
    root.props.insert(
        "model".into(),
        s(&format!("GSys LibreCore {}", model.target_id)),
    );

    // chosen
    let mut chosen = Node {
        name: "chosen".into(),
        ..Node::default()
    };
    if let Some(path) = &model.soc.stdout_path {
        chosen.props.insert("stdout-path".into(), s(path));
    } else if let Some(uart) = model.soc.peripherals.iter().find(is_uart) {
        chosen.props.insert(
            "stdout-path".into(),
            s(&format!("/soc/{}", node_name(uart))),
        );
    }
    if let Some(bootargs) = &model.soc.bootargs {
        chosen.props.insert("bootargs".into(), s(bootargs));
    }
    root.children.push(chosen);

    // cpus
    let harts = model.soc.harts_total.max(1);
    let mut cpus = Node {
        name: "cpus".into(),
        ..Node::default()
    };
    cpus.props.insert("#address-cells".into(), cell(1));
    cpus.props.insert("#size-cells".into(), cell(0));
    cpus.props
        .insert("timebase-frequency".into(), cell(model.isa.timebase_hz));

    for h in 0..harts {
        let mut cpu = Node {
            name: format!("cpu@{h}"),
            ..Node::default()
        };
        cpu.props.insert("device_type".into(), s("cpu"));
        cpu.props.insert("reg".into(), cell(h as u64));
        cpu.props.insert("status".into(), s("okay"));
        cpu.props.insert("compatible".into(), s("riscv"));
        cpu.props.insert("riscv,isa".into(), s(&isa_string(model)));
        cpu.props
            .insert("riscv,isa-base".into(), s(&model.isa.base));
        cpu.props
            .insert("riscv,isa-extensions".into(), isa_extensions(model));
        if let Some(mmu) = &model.isa.mmu_mode {
            cpu.props
                .insert("mmu-type".into(), s(&format!("riscv,{mmu}")));
        }

        let mut intc = Node {
            name: "interrupt-controller".into(),
            ..Node::default()
        };
        intc.props.insert("#interrupt-cells".into(), cell(1));
        intc.props.insert("compatible".into(), s("riscv,cpu-intc"));
        intc.props.insert("phandle".into(), cell(h as u64 + 2));
        intc.props.insert("interrupt-controller".into(), Prop::Flag);
        cpu.children.push(intc);
        cpus.children.push(cpu);
    }

    // cpu-map, only when the model expresses it without guessing.
    if let (Some(cores), Some(threads)) = (model.soc.cores, model.soc.threads_per_core) {
        if cores > 0 && threads > 0 && cores * threads <= harts {
            let mut cpu_map = Node {
                name: "cpu-map".into(),
                ..Node::default()
            };
            let mut cluster = Node {
                name: "cluster0".into(),
                ..Node::default()
            };
            let mut h = 0;
            for c in 0..cores {
                let mut core = Node {
                    name: format!("core{c}"),
                    ..Node::default()
                };
                for t in 0..threads {
                    if h < harts {
                        core.props.insert(
                            format!("thread{t}"),
                            cell(h as u64 + 2), // CPU{h}_intc phandle
                        );
                        h += 1;
                    }
                }
                cluster.children.push(core);
            }
            cpu_map.children.push(cluster);
            cpus.children.push(cpu_map);
        }
    }

    root.children.push(cpus);

    // memory
    if let Some((base, len)) = model.soc.dram {
        let mut mem = Node {
            name: format!("memory@{base:x}"),
            ..Node::default()
        };
        mem.props.insert("device_type".into(), s("memory"));
        mem.props.insert("reg".into(), addr_size_reg(base, len));
        root.children.push(mem);
    }

    // soc
    let mut soc = Node {
        name: "soc".into(),
        ..Node::default()
    };
    soc.props.insert("#address-cells".into(), cell(2));
    soc.props.insert("#size-cells".into(), cell(2));
    soc.props.insert("compatible".into(), s("simple-bus"));
    soc.props.insert("ranges".into(), Prop::Flag);

    // phandle 1 is reserved for the first interrupt controller.
    let plic_phandle = 1u64;
    let ctxs = model.soc.contexts_per_hart.max(1) as usize;

    if let Some(plic) = model.soc.peripherals.iter().find(|p| is_intc(p)) {
        let mut plic_node = Node {
            name: node_name(plic),
            ..Node::default()
        };
        plic_node.props.insert("#interrupt-cells".into(), cell(1));
        plic_node.props.insert("#address-cells".into(), cell(0));
        plic_node.props.insert("#size-cells".into(), cell(0));
        plic_node
            .props
            .insert("interrupt-controller".into(), Prop::Flag);
        plic_node
            .props
            .insert("compatible".into(), s(plic_compatible(&plic)));
        plic_node
            .props
            .insert("reg".into(), addr_size_reg(plic.base, plic.len));
        plic_node
            .props
            .insert("riscv,ndev".into(), cell(model.soc.intc_sources as u64));
        plic_node.props.insert("phandle".into(), cell(plic_phandle));

        // Context ordering: M-mode external (11), then S-mode external (9).
        let mut ie: Vec<u64> = Vec::new();
        for h in 0..harts {
            let ph = h as u64 + 2;
            for ctx in 0..ctxs {
                let irq = if ctx % 2 == 0 { 11 } else { 9 };
                ie.push(ph);
                ie.push(irq);
            }
        }
        plic_node
            .props
            .insert("interrupts-extended".into(), Prop::Cells(ie));
        soc.children.push(plic_node);
    }

    for p in merged_peripherals(model) {
        if is_intc(&p) {
            continue;
        }
        let mut dev = Node {
            name: node_name(&p),
            ..Node::default()
        };
        let compatible = if is_clint(&p) {
            "sifive,clint0"
        } else if is_virtio_mmio(&p) {
            "virtio,mmio"
        } else {
            p.model.as_deref().unwrap_or("")
        };
        dev.props.insert("compatible".into(), s(compatible));

        if is_virtio_mmio(&p) {
            dev.props.insert("dma-coherent".into(), Prop::Flag);
        }
        dev.props.insert("reg".into(), addr_size_reg(p.base, p.len));

        if is_clint(&p) {
            // RISC-V CLINT wires M-mode software (3) and M-mode timer (7)
            // to each hart's CPU interrupt controller.
            let mut ie: Vec<u64> = Vec::new();
            for h in 0..harts {
                let ph = h as u64 + 2;
                ie.push(ph);
                ie.push(3);
                ie.push(ph);
                ie.push(7);
            }
            dev.props
                .insert("interrupts-extended".into(), Prop::Cells(ie));
        } else if let Some(irq) = p.irq {
            dev.props.insert("interrupts".into(), cell(irq as u64));
            dev.props
                .insert("interrupt-parent".into(), cell(plic_phandle));
        }

        // NS16550a-specific descriptors that stock firmware expects.
        if is_ns16550(&p) {
            if let Some(clock) = p.clock_frequency {
                dev.props.insert("clock-frequency".into(), cell(clock));
            }
            if let Some(speed) = p.current_speed {
                dev.props.insert("current-speed".into(), cell(speed));
            }
            if let Some(width) = p.reg_io_width {
                dev.props.insert("reg-io-width".into(), cell(width as u64));
            }
            if let Some(shift) = p.reg_shift {
                dev.props.insert("reg-shift".into(), cell(shift as u64));
            }
        }

        soc.children.push(dev);
    }

    root.children.push(soc);

    if let Some(pmu) = build_pmu_node(model) {
        root.children.push(pmu);
    }

    root
}

/// Build the `/pmu` node consumed by OpenSBI's SBI PMU extension.
///
/// The node is only emitted when the model exposes at least one programmable
/// counter. It carries the design's own `mhpmevent` → counter bitmap mapping
/// as `riscv,raw-event-to-mhpmcounters` and a fixed mapping for the generic
/// `cycles` / `instructions` SBI events.
fn build_pmu_node(model: &TargetModel) -> Option<Node> {
    if model.pmu.counter_count == 0 {
        return None;
    }

    let harts = model.soc.harts_total.max(1);
    let mut pmu = Node {
        name: "pmu".into(),
        ..Node::default()
    };
    pmu.props.insert("compatible".into(), s("riscv,pmu"));

    // Sscofpmf: a local counter-overflow interrupt (number 13) wired to the
    // CPU INTC of every hart. OpenSBI removes this property if the extension
    // is absent, so including it is safe when the model declares sscofpmf live.
    if model
        .isa
        .extensions
        .iter()
        .any(|(t, v)| t == "sscofpmf" && v == "live")
    {
        let mut ie: Vec<u64> = Vec::new();
        for h in 0..harts {
            ie.push(h as u64 + 2); // cpu hart h intc phandle
            ie.push(13); // LCOFIP
        }
        pmu.props
            .insert("interrupts-extended".into(), Prop::Cells(ie));
    }

    // Generic SBI events can use the fixed mcycle (0) and minstret (1) counters.
    let event_to_mhpmcounters: Vec<u64> = vec![
        0x01, 0x01, 0x1, // SBI_PMU_HW_CPU_CYCLES   -> mcycle
        0x02, 0x02, 0x2, // SBI_PMU_HW_INSTRUCTIONS -> minstret
    ];
    pmu.props.insert(
        "riscv,event-to-mhpmcounters".into(),
        Prop::Cells(event_to_mhpmcounters),
    );

    // Raw design events. The `mhpmevent` value the guest writes is both the
    // event selector and the 64-bit raw ID; the mask is all ones so the event
    // is an exact 1:1 match.
    let counter_mask = model.pmu.counter_mask() as u64;
    let mut raw: Vec<u64> = Vec::new();
    for e in &model.pmu.events {
        if e.name.ends_with("_reserved") || e.name == "reserved" {
            continue;
        }
        raw.push(0); // selector high
        raw.push(e.mhpmevent as u64); // selector low
        raw.push(0xffff_ffff); // select_mask high
        raw.push(0xffff_ffff); // select_mask low
        raw.push(counter_mask); // counter bitmap
    }
    if !raw.is_empty() {
        pmu.props
            .insert("riscv,raw-event-to-mhpmcounters".into(), Prop::Cells(raw));
    }

    Some(pmu)
}

fn is_intc(p: &Peripheral) -> bool {
    let id = p.id.to_lowercase();
    if id == "intc" || id == "plic" || id.starts_with("plic") || id == "interrupt-controller" {
        return true;
    }
    if let Some(m) = p.model.as_deref() {
        let m = m.to_lowercase();
        if m.contains("plic") || m.contains("intc") {
            return true;
        }
    }
    false
}

fn is_uart(p: &&Peripheral) -> bool {
    let id = p.id.to_lowercase();
    let model = p.model.as_deref().unwrap_or("").to_lowercase();
    id.contains("uart")
        || id.contains("serial")
        || model.contains("uart")
        || model.contains("ns16550")
}

fn is_clint(p: &Peripheral) -> bool {
    let id = p.id.to_lowercase();
    id == "clint"
        || p.model
            .as_deref()
            .unwrap_or("")
            .to_lowercase()
            .contains("clint")
}

fn is_ns16550(p: &Peripheral) -> bool {
    let model = p.model.as_deref().unwrap_or("").to_lowercase();
    model.contains("ns16550")
}

fn is_virtio_mmio(p: &Peripheral) -> bool {
    p.model
        .as_deref()
        .unwrap_or("")
        .to_lowercase()
        .contains("virtio-mmio")
}

fn plic_compatible(p: &&Peripheral) -> &'static str {
    if let Some(m) = p.model.as_deref() {
        let m = m.to_lowercase();
        if m.contains("plic") || m.contains("intc") {
            return "sifive,plic-1.0.0";
        }
    }
    "riscv,plic0"
}

fn node_name(p: &Peripheral) -> String {
    // Prefer an exact id; fall back to a generic name at the model base.
    if p.id.is_empty() {
        return format!("device@{:x}", p.base);
    }
    format!("{}@{:x}", p.id, p.base)
}

fn sanitize(s: &str) -> String {
    s.chars()
        .map(|c| match c {
            'a'..='z' | 'A'..='Z' | '0'..='9' | '-' | '_' => c,
            _ => '-',
        })
        .collect()
}

/// Generate a device-tree blob from the model and emit it as a C array plus
/// a matching header.
pub fn emit_dtb(model: &TargetModel, generator_version: &str, model_digest: &str) -> Emission {
    let name = crate::machine::machine_name(&model.target_id);
    let root = build_dts(model);
    let blob = g6q_dts::to_blob(&root, 0, &[]);

    let mut emission = Emission::new();
    let mut c_array = String::new();
    for (i, b) in blob.iter().enumerate() {
        let sep = if i % 12 == 11 { ",\n    " } else { ", " };
        let _ = write!(c_array, "0x{b:02x}{sep}");
    }
    let c_body = format!(
        "#include <stddef.h>\n\
         #include <stdint.h>\n\n\
         const uint8_t g6lc_{name}_dtb[] = {{\n\
            {c_array}\n\
         }};\n\n\
         const size_t g6lc_{name}_dtb_size = sizeof(g6lc_{name}_dtb);\n"
    );
    emission.push(EmittedFile::new(
        format!("hw/riscv/g6lc-{name}-dtb.c"),
        generator_version,
        model_digest,
        &c_body,
    ));

    let h_body = format!(
        "#ifndef G6LC_{}_DTB_H\n\
         #define G6LC_{}_DTB_H\n\n\
         #include <stddef.h>\n\
         #include <stdint.h>\n\n\
         extern const uint8_t g6lc_{name}_dtb[];\n\
         extern const size_t g6lc_{name}_dtb_size;\n\n\
         #endif /* G6LC_{}_DTB_H */\n",
        name.to_uppercase(),
        name.to_uppercase(),
        name.to_uppercase(),
    );
    emission.push(EmittedFile::new(
        format!("hw/riscv/g6lc-{name}-dtb.h"),
        generator_version,
        model_digest,
        &h_body,
    ));

    emission
}

#[cfg(test)]
mod tests {
    use super::*;
    use g6q_core::model::TargetModel;

    #[test]
    fn emitted_dtb_files_are_gpl_and_have_a_header() {
        let m = TargetModel::new("g6lc64_test");
        let e = emit_dtb(&m, "0.1.0", "sha256:abc");
        assert_eq!(e.files.len(), 2);
        for f in &e.files {
            assert!(f.header_is_valid(), "{}", f.path);
        }
        let c = e.files.iter().find(|f| f.path.ends_with(".c")).unwrap();
        assert!(c.contents.contains("const uint8_t g6lc_g6lc64_test_dtb[]"));
        assert!(c
            .contents
            .contains("const size_t g6lc_g6lc64_test_dtb_size"));
        let h = e.files.iter().find(|f| f.path.ends_with(".h")).unwrap();
        assert!(h
            .contents
            .contains("extern const uint8_t g6lc_g6lc64_test_dtb[]"));
        assert!(h.contents.contains("G6LC_G6LC64_TEST_DTB_H"));
    }

    #[test]
    fn dtb_round_trips_through_g6q_dts() {
        let mut m = TargetModel::new("t");
        m.isa.timebase_hz = 10_000_000;
        m.soc.dram = Some((0x8000_0000, 0x1000_0000));
        m.soc.harts_total = 1;
        m.soc.contexts_per_hart = 1;
        m.soc.intc_sources = 4;
        m.soc.intc_targets = 4;
        let e = emit_dtb(&m, "0.1.0", "sha256:abc");
        let c = e.files.iter().find(|f| f.path.ends_with(".c")).unwrap();

        // Parse the blob back out of the C array as a sanity check.
        let blob = extract_blob(&c.contents);
        let root = g6q_dts::from_blob(&blob).expect("valid blob");
        assert!(root.child("cpus").is_some());
        assert!(root.child("soc").is_some());
        assert!(root.child("memory@80000000").is_some());
        let cpus = root.child("cpus").unwrap();
        assert_eq!(
            cpus.prop("timebase-frequency").and_then(|p| p.u64()),
            Some(10_000_000)
        );
    }

    #[test]
    fn clint_emits_interrupts_extended_to_cpu_intc() {
        let mut m = TargetModel::new("t");
        m.soc.dram = Some((0x8000_0000, 0x1000_0000));
        m.soc.harts_total = 2;
        m.soc.contexts_per_hart = 1;
        m.soc.intc_sources = 4;
        m.soc.intc_targets = 4;
        m.soc.peripherals.push(g6q_core::model::Peripheral {
            id: "clint".into(),
            base: 0x0200_0000,
            len: 0x000c_0000,
            model: Some("sifive,clint0".into()),
            irq: None,
            ..g6q_core::model::Peripheral::default()
        });
        let e = emit_dtb(&m, "0.1.0", "sha256:abc");
        let c = e.files.iter().find(|f| f.path.ends_with(".c")).unwrap();
        let blob = extract_blob(&c.contents);
        let root = g6q_dts::from_blob(&blob).expect("valid blob");
        let soc = root.child("soc").expect("soc");
        let clint = soc.child("clint@2000000").expect("clint");
        assert_eq!(
            clint.prop("interrupts-extended").and_then(|p| p.cells()),
            Some(&[2, 3, 2, 7, 3, 3, 3, 7][..])
        );
    }

    #[test]
    fn cpu_map_is_emitted_when_topology_is_known() {
        let mut m = TargetModel::new("t");
        m.soc.dram = Some((0x8000_0000, 0x1000_0000));
        m.soc.harts_total = 4;
        m.soc.cores = Some(2);
        m.soc.threads_per_core = Some(2);
        m.soc.contexts_per_hart = 1;
        m.soc.intc_sources = 4;
        m.soc.intc_targets = 4;
        let e = emit_dtb(&m, "0.1.0", "sha256:abc");
        let c = e.files.iter().find(|f| f.path.ends_with(".c")).unwrap();
        let blob = extract_blob(&c.contents);
        let root = g6q_dts::from_blob(&blob).expect("valid blob");
        let cpus = root.child("cpus").expect("cpus");
        let map = cpus.child("cpu-map").expect("cpu-map");
        let cluster = map.child("cluster0").expect("cluster0");
        let core0 = cluster.child("core0").expect("core0");
        assert_eq!(
            core0.prop("thread0").and_then(|p| p.cells()),
            Some(&[2][..])
        );
        assert_eq!(
            core0.prop("thread1").and_then(|p| p.cells()),
            Some(&[3][..])
        );
        assert_eq!(
            cluster
                .child("core1")
                .unwrap()
                .prop("thread0")
                .and_then(|p| p.cells()),
            Some(&[4][..])
        );
        assert_eq!(
            cluster
                .child("core1")
                .unwrap()
                .prop("thread1")
                .and_then(|p| p.cells()),
            Some(&[5][..])
        );
    }

    #[test]
    fn dtb_cpu_node_count_matches_harts_total() {
        let mut m = TargetModel::new("t");
        m.soc.dram = Some((0x8000_0000, 0x1000_0000));
        m.soc.harts_total = 4;
        m.soc.cores = Some(2);
        m.soc.threads_per_core = Some(2);
        m.soc.contexts_per_hart = 1;
        m.soc.intc_sources = 4;
        m.soc.intc_targets = 4;
        let e = emit_dtb(&m, "0.1.0", "sha256:abc");
        let c = e.files.iter().find(|f| f.path.ends_with(".c")).unwrap();
        let blob = extract_blob(&c.contents);
        let root = g6q_dts::from_blob(&blob).expect("valid blob");
        let cpus = root.child("cpus").expect("cpus");
        let cpu_nodes: Vec<_> = cpus
            .children
            .iter()
            .filter(|n| n.name.starts_with("cpu@"))
            .collect();
        assert_eq!(
            cpu_nodes.len(),
            m.soc.harts_total as usize,
            "FDT must have one processor node per logical hart"
        );
    }

    #[test]
    fn stdout_path_is_derived_from_a_uart_peripheral() {
        let mut m = TargetModel::new("t");
        m.soc.dram = Some((0x8000_0000, 0x1000_0000));
        m.soc.harts_total = 1;
        m.soc.contexts_per_hart = 1;
        m.soc.intc_sources = 4;
        m.soc.intc_targets = 4;
        m.soc.peripherals.push(g6q_core::model::Peripheral {
            id: "uart".into(),
            base: 0x1000_0000,
            len: 0x1000,
            model: Some("ns16550a".into()),
            irq: Some(1),
            ..g6q_core::model::Peripheral::default()
        });
        let e = emit_dtb(&m, "0.1.0", "sha256:abc");
        let c = e.files.iter().find(|f| f.path.ends_with(".c")).unwrap();
        let blob = extract_blob(&c.contents);
        let root = g6q_dts::from_blob(&blob).expect("valid blob");
        let chosen = root.child("chosen").expect("chosen");
        assert_eq!(
            chosen.prop("stdout-path").and_then(|p| p.first_string()),
            Some("/soc/uart@10000000")
        );
    }

    #[test]
    fn pmu_node_is_emitted_with_raw_events_and_interrupts() {
        let mut m = TargetModel::new("t");
        m.soc.dram = Some((0x8000_0000, 0x1000_0000));
        m.soc.harts_total = 2;
        m.soc.contexts_per_hart = 1;
        m.soc.intc_sources = 4;
        m.soc.intc_targets = 4;
        m.isa.extensions = vec![
            ("zihpm".into(), "live".into()),
            ("sscofpmf".into(), "live".into()),
        ];
        m.pmu.counter_count = 6;
        m.pmu.events = vec![
            g6q_core::pmu::PmuEvent {
                name: "legacy.01_l1_i_cache_misses".into(),
                group: 0,
                index: 1,
                mhpmevent: 1,
            },
            g6q_core::pmu::PmuEvent {
                name: "legacy.00_reserved".into(),
                group: 0,
                index: 0,
                mhpmevent: 0,
            },
        ];

        let e = emit_dtb(&m, "0.1.0", "sha256:abc");
        let c = e.files.iter().find(|f| f.path.ends_with(".c")).unwrap();
        let blob = extract_blob(&c.contents);
        let root = g6q_dts::from_blob(&blob).expect("valid blob");
        let pmu = root.child("pmu").expect("pmu node must exist");
        assert_eq!(
            pmu.prop("compatible").and_then(|p| p.first_string()),
            Some("riscv,pmu")
        );

        // 2 harts × 2 cells
        assert_eq!(
            pmu.prop("interrupts-extended").and_then(|p| p.cells()),
            Some(&[2, 13, 3, 13][..])
        );

        // Reserved event must be filtered out, only one raw event stays.
        let raw = pmu
            .prop("riscv,raw-event-to-mhpmcounters")
            .and_then(|p| p.cells())
            .expect("raw mapping");
        assert_eq!(raw.len(), 5, "one raw event row = 5 cells");
        assert_eq!(raw[0], 0);
        assert_eq!(raw[1], 1); // mhpmevent selector
        assert_eq!(raw[4], 0x1f8); // counter bitmap
    }

    #[test]
    fn virtio_mmio_nodes_use_the_linux_compatible_and_dma_coherent() {
        let mut m = TargetModel::new("t");
        m.soc.dram = Some((0x8000_0000, 0x1000_0000));
        m.soc.harts_total = 1;
        m.soc.contexts_per_hart = 1;
        m.soc.intc_sources = 4;
        m.soc.intc_targets = 4;
        m.soc.virtio_mmio = 2;
        let e = emit_dtb(&m, "0.1.0", "sha256:abc");
        let c = e.files.iter().find(|f| f.path.ends_with(".c")).unwrap();
        let blob = extract_blob(&c.contents);
        let root = g6q_dts::from_blob(&blob).expect("valid blob");
        let soc = root.child("soc").expect("soc");

        // Base is the next 4 KiB after DRAM end (0x90000000).
        let v0 = soc.child("virtio0@90000000").expect("virtio0 node");
        let v1 = soc.child("virtio1@90001000").expect("virtio1 node");

        assert_eq!(
            v0.prop("compatible").and_then(|p| p.first_string()),
            Some("virtio,mmio")
        );
        assert!(v0.prop("dma-coherent").is_some());
        assert!(v0.prop("interrupts").is_some());
        assert!(v0.prop("interrupt-parent").is_some());
        assert_eq!(
            v1.prop("compatible").and_then(|p| p.first_string()),
            Some("virtio,mmio")
        );
    }

    fn extract_blob(c: &str) -> Vec<u8> {
        let mut out = Vec::new();
        for line in c.lines() {
            for tok in line.split([',', ' ', '{', '}', '\n', '\r']) {
                let t = tok.trim();
                if let Some(hex) = t.strip_prefix("0x") {
                    if let Ok(b) = u8::from_str_radix(hex, 16) {
                        out.push(b);
                    }
                }
            }
        }
        out
    }
}
