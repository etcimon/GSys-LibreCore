// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Semantic extraction: the device-tree facts the model consumes.
//!
//! The tree carries far more than the model needs. This module pulls out the properties
//! that make a *claim about the hardware* — what software will be told exists — and
//! leaves the rest in the tree for a later consumer.

use crate::tree::{Node, Prop};
use crate::Extensions;

/// One memory-mapped device the tree advertises.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceFact {
    /// Node base name, e.g. `uart`.
    pub name: String,
    /// First `compatible` string, when present.
    pub compatible: Option<String>,
    /// Base address from `reg`, when it can be read.
    pub base: Option<u64>,
    /// Window length from `reg`, when it can be read.
    pub len: Option<u64>,
    /// First interrupt number, when present.
    pub irq: Option<u32>,
    /// `reg-shift` for 16550-style UARTs, in bytes.
    pub reg_shift: Option<u32>,
    /// `reg-io-width` for 16550-style UARTs, in bytes.
    pub reg_io_width: Option<u32>,
    /// `clock-frequency` for peripheral baud-rate generation.
    pub clock_frequency: Option<u64>,
    /// `current-speed` for 16550-style UARTs, in baud.
    pub current_speed: Option<u64>,
}

/// What the tree says about the machine.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Facts {
    /// ISA extension tokens advertised to software.
    pub extensions: Extensions,
    /// The `riscv,isa` string, when present.
    pub isa_string: Option<String>,
    /// The `riscv,isa-base` string, when present.
    pub isa_base: Option<String>,
    /// Address-translation mode, e.g. `sv39`.
    pub mmu_mode: Option<String>,
    /// Number of `cpu@N` nodes: the harts software is told about.
    pub cpu_count: u32,
    /// Whether a `cpu-map` topology node is present.
    pub has_cpu_map: bool,
    /// Threads per core read from the topology, when it is expressed.
    pub threads_per_core: Option<u32>,
    /// Cores read from the topology, when it is expressed.
    pub cores: Option<u32>,
    /// Main memory base and length.
    pub memory: Option<(u64, u64)>,
    /// External interrupt sources from `riscv,ndev`.
    pub intc_sources: Option<u32>,
    /// Interrupt contexts actually **wired** to the external controller, counted from
    /// its `interrupts-extended` list.
    ///
    /// This is not the controller's hardware capacity — that lives in the design's SoC
    /// package, not in the tree. It is how many contexts this board connects, which is
    /// the number a guest can actually use.
    pub intc_contexts_wired: Option<u32>,
    /// Devices under the system bus.
    pub devices: Vec<DeviceFact>,
    /// Kernel boot arguments from `chosen`.
    pub bootargs: Option<String>,
    /// Console path from `chosen/stdout-path`.
    pub stdout_path: Option<String>,
    /// Whether a performance-monitor mapping is present.
    pub has_pmu_map: bool,
    /// `timebase-frequency` from `cpus`, in Hz.
    pub timebase_hz: u64,
}

impl Facts {
    /// Whether the tree advertises an extension token.
    pub fn declares(&self, token: &str) -> bool {
        self.extensions.has(token)
    }

    /// Whether a device with the given base name is advertised.
    pub fn has_device(&self, base_name: &str) -> bool {
        self.devices.iter().any(|d| d.name == base_name)
    }

    /// A device by base name.
    pub fn device(&self, base_name: &str) -> Option<&DeviceFact> {
        self.devices.iter().find(|d| d.name == base_name)
    }
}

/// Read `reg = <addr-hi addr-lo size-hi size-lo>` or `<addr size>`.
///
/// Cell widths come from the enclosing node's `#address-cells` / `#size-cells`, which is
/// why this takes them explicitly rather than assuming the common `2, 2`.
fn read_reg(prop: &Prop, address_cells: usize, size_cells: usize) -> (Option<u64>, Option<u64>) {
    let Some(cells) = prop.cells() else {
        return (None, None);
    };
    if cells.len() < address_cells + size_cells {
        return (None, None);
    }
    let combine = |slice: &[u64]| -> u64 {
        slice
            .iter()
            .fold(0u64, |acc, c| (acc << 32) | (c & 0xffff_ffff))
    };
    let base = combine(&cells[..address_cells]);
    let len = combine(&cells[address_cells..address_cells + size_cells]);
    (Some(base), Some(len))
}

fn cells_of(node: &Node, prop: &str, default: usize) -> usize {
    node.prop(prop)
        .and_then(Prop::u64)
        .map(|v| v as usize)
        .unwrap_or(default)
}

fn cell_u32_of(node: &Node, prop: &str) -> Option<u32> {
    node.prop(prop).and_then(Prop::u64).map(|v| v as u32)
}

/// Extract the facts the model consumes from a parsed tree.
pub fn extract(root: &Node) -> Facts {
    let mut f = Facts::default();
    let root_addr_cells = cells_of(root, "#address-cells", 2);
    let root_size_cells = cells_of(root, "#size-cells", 2);

    // --- CPUs -------------------------------------------------------------------
    if let Some(cpus) = root.child("cpus") {
        let cpu_nodes = cpus.children_named("cpu");
        f.cpu_count = cpu_nodes.len() as u32;

        if let Some(cpu) = cpu_nodes.first() {
            if let Some(p) = cpu.prop("riscv,isa-extensions") {
                f.extensions = Extensions::from_tokens(p.strings().unwrap_or(&[]));
            }
            f.isa_string = cpu
                .prop("riscv,isa")
                .and_then(Prop::first_string)
                .map(str::to_string);
            f.isa_base = cpu
                .prop("riscv,isa-base")
                .and_then(Prop::first_string)
                .map(str::to_string);
            f.mmu_mode = cpu.prop("mmu-type").and_then(Prop::first_string).map(|s| {
                // "riscv,sv39" -> "sv39"
                s.rsplit(',').next().unwrap_or(s).to_string()
            });
            f.has_pmu_map = cpu
                .child("pmu")
                .map(|p| p.has("riscv,event-to-mhpmevent"))
                .unwrap_or(false);
        }

        f.timebase_hz = cpus
            .prop("timebase-frequency")
            .and_then(Prop::u64)
            .unwrap_or(1_000_000);

        // Topology: cpu-map / clusterN / coreN / threadN
        if let Some(map) = cpus.child("cpu-map") {
            f.has_cpu_map = true;
            let mut cores = 0u32;
            let mut threads = 0u32;
            for cluster in &map.children {
                for core in &cluster.children {
                    if core.base_name().starts_with("core") {
                        cores += 1;
                        let t = core
                            .children
                            .iter()
                            .filter(|c| c.base_name().starts_with("thread"))
                            .count() as u32;
                        threads = threads.max(t);
                    }
                }
            }
            if cores > 0 {
                f.cores = Some(cores);
            }
            // A core that lists no thread nodes has one implicit thread.
            f.threads_per_core = Some(threads.max(1));
        }
    }

    // --- memory -----------------------------------------------------------------
    for node in &root.children {
        if node.base_name() == "memory" {
            if let Some(reg) = node.prop("reg") {
                let (b, l) = read_reg(reg, root_addr_cells, root_size_cells);
                if let (Some(b), Some(l)) = (b, l) {
                    f.memory = Some((b, l));
                }
            }
        }
    }

    // --- system bus devices ------------------------------------------------------
    if let Some(soc) = root.child("soc") {
        let a = cells_of(soc, "#address-cells", root_addr_cells);
        let s = cells_of(soc, "#size-cells", root_size_cells);
        for node in &soc.children {
            let (base, len) = node
                .prop("reg")
                .map(|p| read_reg(p, a, s))
                .unwrap_or((None, None));
            let irq = node
                .prop("interrupts")
                .and_then(Prop::u64)
                .map(|v| v as u32);
            if node.has("riscv,ndev") {
                f.intc_sources = node
                    .prop("riscv,ndev")
                    .and_then(Prop::u64)
                    .map(|v| v as u32);
                // Each `interrupts-extended` entry is one hart context. The phandle is
                // dropped by the parser, so the surviving cells count them directly.
                f.intc_contexts_wired = node
                    .prop("interrupts-extended")
                    .and_then(Prop::cells)
                    .map(|c| c.len() as u32);
            }
            f.devices.push(DeviceFact {
                name: node.base_name().to_string(),
                compatible: node.compatible().map(str::to_string),
                base,
                len,
                irq,
                reg_shift: cell_u32_of(node, "reg-shift"),
                reg_io_width: cell_u32_of(node, "reg-io-width"),
                clock_frequency: cell_u32_of(node, "clock-frequency")
                    .map(|v| v as u64)
                    .or_else(|| {
                        node.prop("clock-frequency")
                            .and_then(Prop::first_string)
                            .and_then(|s| s.parse::<u64>().ok())
                    }),
                current_speed: cell_u32_of(node, "current-speed").map(|v| v as u64),
            });
        }
    }

    // --- chosen ------------------------------------------------------------------
    if let Some(chosen) = root.child("chosen") {
        f.bootargs = chosen
            .prop("bootargs")
            .and_then(Prop::first_string)
            .map(str::to_string);
        f.stdout_path = chosen
            .prop("stdout-path")
            .and_then(Prop::first_string)
            .map(str::to_string);
    }

    f
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tree::parse;

    const SRC: &str = r#"
/dts-v1/;
/ {
  #address-cells = <2>;
  #size-cells = <2>;
  chosen {
    bootargs = "console=ttyS0";
    stdout-path = "/soc/uart";
  };
  cpus {
    #address-cells = <1>;
    #size-cells = <0>;
    CPU0: cpu@0 {
      device_type = "cpu";
      reg = <0>;
      riscv,isa = "rv64imafdc_zacas";
      riscv,isa-base = "rv64i";
      riscv,isa-extensions = "i", "m", "a", "f", "d", "c", "zacas";
      mmu-type = "riscv,sv39";
      tlb-split;
      pmu { compatible = "riscv,pmu"; riscv,event-to-mhpmevent = <0x01 0x0 0x1>; };
    };
    CPU1: cpu@1 { device_type = "cpu"; reg = <1>; };
    cpu-map {
      cluster0 {
        core0 { thread0 { cpu = <&CPU0>; }; thread1 { cpu = <&CPU1>; }; };
      };
    };
  };
  memory@80000000 {
    device_type = "memory";
    reg = <0x0 0x80000000 0x0 0x40000000>;
  };
  soc {
    #address-cells = <2>;
    #size-cells = <2>;
    clint@2000000 { compatible = "example,clint0"; reg = <0x0 0x2000000 0x0 0xc0000>; };
    INTC0: interrupt-controller@c000000 {
      compatible = "example,intc0";
      reg = <0x0 0xc000000 0x0 0x4000000>;
      riscv,ndev = <30>;
    };
    uart@10000000 {
      compatible = "ns16550a";
      reg = <0x0 0x10000000 0x0 0x1000>;
      interrupts = <1>;
    };
  };
};
"#;

    fn facts() -> Facts {
        extract(&parse(SRC))
    }

    #[test]
    fn extension_tokens_are_extracted() {
        let f = facts();
        assert!(f.declares("zacas"));
        assert!(f.declares("c"));
        assert!(!f.declares("v"));
        assert!(!f.declares("h"));
        assert_eq!(f.isa_base.as_deref(), Some("rv64i"));
        assert_eq!(f.isa_string.as_deref(), Some("rv64imafdc_zacas"));
    }

    #[test]
    fn mmu_mode_drops_the_vendor_prefix() {
        assert_eq!(facts().mmu_mode.as_deref(), Some("sv39"));
    }

    #[test]
    fn cpu_count_and_topology_are_read() {
        let f = facts();
        assert_eq!(f.cpu_count, 2, "software is told about two harts");
        assert!(f.has_cpu_map);
        assert_eq!(f.cores, Some(1));
        assert_eq!(f.threads_per_core, Some(2));
    }

    #[test]
    fn memory_reg_combines_high_and_low_cells() {
        assert_eq!(facts().memory, Some((0x8000_0000, 0x4000_0000)));
    }

    #[test]
    fn vendor_prefixed_compatibles_survive_intact() {
        let f = facts();
        assert_eq!(
            f.device("clint").unwrap().compatible.as_deref(),
            Some("example,clint0")
        );
    }

    #[test]
    fn devices_carry_base_length_and_interrupt() {
        let f = facts();
        assert!(f.has_device("clint"));
        let uart = f.device("uart").expect("uart");
        assert_eq!(uart.base, Some(0x1000_0000));
        assert_eq!(uart.len, Some(0x1000));
        assert_eq!(uart.irq, Some(1));
        assert_eq!(uart.compatible.as_deref(), Some("ns16550a"));
    }

    #[test]
    fn interrupt_source_count_is_read_from_the_controller() {
        assert_eq!(facts().intc_sources, Some(30));
    }

    #[test]
    fn chosen_and_pmu_are_noticed() {
        let f = facts();
        assert_eq!(f.bootargs.as_deref(), Some("console=ttyS0"));
        assert_eq!(f.stdout_path.as_deref(), Some("/soc/uart"));
        assert!(f.has_pmu_map);
    }

    #[test]
    fn timebase_frequency_is_read_from_cpus() {
        let f = facts();
        assert_eq!(
            f.timebase_hz, 1_000_000,
            "timebase-frequency defaults to 1 MHz"
        );
    }

    #[test]
    fn a_tree_with_no_cpus_yields_zero_rather_than_panicking() {
        let f = extract(&parse("/dts-v1/;\n/ { };"));
        assert_eq!(f.cpu_count, 0);
        assert!(f.memory.is_none());
        assert!(f.devices.is_empty());
    }

    #[test]
    fn extraction_is_deterministic() {
        assert_eq!(facts(), facts());
    }
}
