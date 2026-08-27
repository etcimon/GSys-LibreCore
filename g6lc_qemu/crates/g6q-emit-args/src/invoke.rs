// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Building a stock-QEMU invocation from a [`TargetModel`].
//!
//! B0 emits no code. It composes an invocation of an unmodified emulator and, just as
//! importantly, states what that invocation does **not** cover.

use g6q_core::model::{Profile, TargetModel};

/// Firmware wiring for the guest.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub enum Firmware {
    /// No machine-mode firmware: a bare image supplied by the caller.
    None,
    /// Let the emulator use its built-in default.
    #[default]
    Default,
    /// An explicit firmware image.
    File(String),
}

/// What to boot and how.
#[derive(Debug, Clone, Default)]
pub struct BootOptions {
    /// Machine-mode firmware.
    pub firmware: Firmware,
    /// Kernel image.
    pub kernel: Option<String>,
    /// Initial ramdisk.
    pub initrd: Option<String>,
    /// Kernel command line.
    pub append: Option<String>,
    /// Device tree blob to hand the guest.
    pub dtb: Option<String>,
    /// Bare ELF, for harness-style runs.
    pub elf: Option<String>,
    /// Disk images; each implies a virtio transport.
    pub drives: Vec<String>,
    /// Whether to attach user-mode networking.
    pub netdev_user: bool,
    /// Host-to-guest port forwards as `(host, guest)`.
    pub port_forwards: Vec<(u16, u16)>,
    /// Serial destination.
    pub serial: Option<String>,
    /// Override the processor count; otherwise the model's hart total is used.
    pub smp: Option<u32>,
    /// Override memory size in bytes; otherwise the model's memory window is used.
    pub memory_bytes: Option<u64>,
    /// Emit a deterministic instruction-counted clock.
    pub deterministic: bool,
}

/// The stock machine an invocation targets.
#[derive(Debug, Clone)]
pub struct StockTarget {
    /// Machine name passed to `-M`.
    pub machine: String,
    /// Base processor model that properties are applied to.
    pub cpu_base: String,
}

impl Default for StockTarget {
    fn default() -> Self {
        // A generic virtual machine and a generic 64-bit processor: the widest thing a
        // stock build is guaranteed to have. Overridable, and every way it differs from
        // the design is reported by the delta rather than hidden.
        StockTarget {
            machine: "virt".into(),
            cpu_base: "rv64".into(),
        }
    }
}

/// Build the `-cpu` argument from the model's extension verdicts and a property mapping.
///
/// Only capabilities that are **live** are turned on. A capability whose RTL is a stub,
/// or whose status could not be determined, is deliberately left off: enabling it would
/// mean the guest exercises a feature the design under test does not actually provide.
pub fn cpu_argument(
    model: &TargetModel,
    base: &str,
    properties_for: &dyn Fn(&str) -> Vec<String>,
) -> String {
    let mut props: Vec<String> = Vec::new();
    for (token, verdict) in &model.isa.extensions {
        if verdict != "live" {
            continue;
        }
        for p in properties_for(token) {
            let entry = format!("{p}=on");
            if !props.contains(&entry) {
                props.push(entry);
            }
        }
    }
    props.sort();
    if props.is_empty() {
        base.to_string()
    } else {
        format!("{base},{}", props.join(","))
    }
}

/// Render a byte count the way an emulator's `-m` expects.
fn memory_argument(bytes: u64) -> String {
    const M: u64 = 1024 * 1024;
    const G: u64 = 1024 * M;
    if bytes >= G && bytes % G == 0 {
        format!("{}G", bytes / G)
    } else if bytes >= M && bytes % M == 0 {
        format!("{}M", bytes / M)
    } else {
        format!("{bytes}")
    }
}

/// Compose the argument vector, excluding the emulator binary itself.
pub fn build_argv(
    model: &TargetModel,
    stock: &StockTarget,
    boot: &BootOptions,
    properties_for: &dyn Fn(&str) -> Vec<String>,
) -> Vec<String> {
    let mut a: Vec<String> = vec![
        "-M".into(),
        stock.machine.clone(),
        "-cpu".into(),
        cpu_argument(model, &stock.cpu_base, properties_for),
    ];

    let smp = boot.smp.unwrap_or(model.soc.harts_total.max(1));
    a.push("-smp".into());
    a.push(smp.to_string());

    let mem = boot
        .memory_bytes
        .or_else(|| model.soc.dram.map(|(_, len)| len))
        .unwrap_or(128 * 1024 * 1024);
    a.push("-m".into());
    a.push(memory_argument(mem));

    match &boot.firmware {
        Firmware::None => {
            a.push("-bios".into());
            a.push("none".into());
        }
        Firmware::File(p) => {
            a.push("-bios".into());
            a.push(p.clone());
        }
        Firmware::Default => {}
    }

    for (flag, value) in [
        ("-kernel", boot.kernel.as_ref().or(boot.elf.as_ref())),
        ("-initrd", boot.initrd.as_ref()),
        ("-dtb", boot.dtb.as_ref()),
    ] {
        if let Some(v) = value {
            a.push(flag.into());
            a.push(v.clone());
        }
    }
    if let Some(append) = &boot.append {
        a.push("-append".into());
        a.push(append.clone());
    }

    for (i, drive) in boot.drives.iter().enumerate() {
        a.push("-drive".into());
        a.push(format!("file={drive},format=raw,if=none,id=hd{i}"));
        a.push("-device".into());
        a.push(format!("virtio-blk-device,drive=hd{i}"));
    }

    if boot.netdev_user {
        let mut spec = String::from("user,id=net0");
        for (host, guest) in &boot.port_forwards {
            spec.push_str(&format!(",hostfwd=tcp::{host}-:{guest}"));
        }
        a.push("-netdev".into());
        a.push(spec);
        a.push("-device".into());
        a.push("virtio-net-device,netdev=net0".into());
    }

    a.push("-serial".into());
    a.push(boot.serial.clone().unwrap_or_else(|| "stdio".into()));

    if boot.deterministic {
        // Instruction-counted time; required before any tandem or replay run.
        a.push("-icount".into());
        a.push("shift=0,align=off,sleep=off".into());
    }

    a.push("-nographic".into());
    a
}

/// Whether the requested boot needs facilities the faithful profile does not have.
///
/// Disks and networking do not exist on the faithful machine; asking for them silently
/// would produce a result that looks like a hardware answer and is not one.
pub fn requires_virt_profile(boot: &BootOptions) -> bool {
    !boot.drives.is_empty() || boot.netdev_user
}

/// Check the boot request against the model's profile.
pub fn check_profile(model: &TargetModel, boot: &BootOptions) -> Result<(), String> {
    if requires_virt_profile(boot) && model.profile != Profile::Virt {
        return Err(
            "a disk or network was requested, which the faithful machine does not have; \
             select the virtualised profile (results are then software-valid only)"
                .into(),
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use g6q_core::model::{Isa, Soc};

    fn model_with(exts: &[(&str, &str)], harts: u32, dram: Option<(u64, u64)>) -> TargetModel {
        let mut m = TargetModel::new("t");
        m.isa = Isa {
            xlen: 64,
            base: "rv64i".into(),
            extensions: exts
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect(),
            ..Isa::default()
        };
        m.soc = Soc {
            harts_total: harts,
            dram,
            ..Soc::default()
        };
        m
    }

    /// Identity mapping, the common case.
    fn ident(t: &str) -> Vec<String> {
        vec![t.to_string()]
    }

    #[test]
    fn only_live_capabilities_are_enabled() {
        // A stub must not be turned on: the guest would exercise a feature the design
        // under test does not provide.
        let m = model_with(
            &[
                ("zacas", "live"),
                ("v", "stub"),
                ("h", "absent"),
                ("zbb", "unresolved"),
            ],
            1,
            None,
        );
        let cpu = cpu_argument(&m, "rv64", &ident);
        assert!(cpu.contains("zacas=on"));
        assert!(!cpu.contains("v=on"), "{cpu}");
        assert!(!cpu.contains("h=on"), "{cpu}");
        assert!(!cpu.contains("zbb=on"), "{cpu}");
    }

    #[test]
    fn properties_are_sorted_and_deduplicated() {
        let m = model_with(&[("zbb", "live"), ("zba", "live"), ("b", "live")], 1, None);
        // `b` maps to the same three properties as the individual tokens.
        let map = |t: &str| -> Vec<String> {
            match t {
                "b" => vec!["zba".into(), "zbb".into(), "zbs".into()],
                other => vec![other.to_string()],
            }
        };
        let cpu = cpu_argument(&m, "rv64", &map);
        assert_eq!(cpu, "rv64,zba=on,zbb=on,zbs=on");
    }

    #[test]
    fn a_capability_the_stock_model_cannot_express_adds_nothing() {
        let m = model_with(&[("xg6lcai", "live")], 1, None);
        let cpu = cpu_argument(&m, "rv64", &|_| Vec::new());
        assert_eq!(
            cpu, "rv64",
            "an inexpressible capability must not be invented"
        );
    }

    #[test]
    fn processor_count_and_memory_come_from_the_model() {
        let m = model_with(&[], 8, Some((0x8000_0000, 0x4000_0000)));
        let argv = build_argv(&m, &StockTarget::default(), &BootOptions::default(), &ident);
        let joined = argv.join(" ");
        assert!(joined.contains("-smp 8"), "{joined}");
        assert!(joined.contains("-m 1G"), "{joined}");
    }

    #[test]
    fn memory_renders_in_the_largest_exact_unit() {
        assert_eq!(memory_argument(1024 * 1024 * 1024), "1G");
        assert_eq!(memory_argument(512 * 1024 * 1024), "512M");
        assert_eq!(memory_argument(1536 * 1024 * 1024), "1536M");
        assert_eq!(memory_argument(1234), "1234");
    }

    #[test]
    fn firmware_modes_render_distinctly() {
        let m = model_with(&[], 1, None);
        let bare = BootOptions {
            firmware: Firmware::None,
            ..BootOptions::default()
        };
        assert!(build_argv(&m, &StockTarget::default(), &bare, &ident)
            .join(" ")
            .contains("-bios none"));

        let explicit = BootOptions {
            firmware: Firmware::File("fw.elf".into()),
            ..BootOptions::default()
        };
        assert!(build_argv(&m, &StockTarget::default(), &explicit, &ident)
            .join(" ")
            .contains("-bios fw.elf"));

        // The default asks for nothing, letting the emulator choose.
        let dflt = BootOptions::default();
        assert!(!build_argv(&m, &StockTarget::default(), &dflt, &ident)
            .join(" ")
            .contains("-bios"));
    }

    #[test]
    fn a_disk_brings_its_own_transport() {
        let m = model_with(&[], 1, None);
        let boot = BootOptions {
            drives: vec!["rootfs.img".into()],
            ..BootOptions::default()
        };
        let joined = build_argv(&m, &StockTarget::default(), &boot, &ident).join(" ");
        assert!(joined.contains("file=rootfs.img"), "{joined}");
        assert!(joined.contains("virtio-blk-device"), "{joined}");
    }

    #[test]
    fn port_forwards_attach_to_user_networking() {
        let m = model_with(&[], 1, None);
        let boot = BootOptions {
            netdev_user: true,
            port_forwards: vec![(2222, 22)],
            ..BootOptions::default()
        };
        let joined = build_argv(&m, &StockTarget::default(), &boot, &ident).join(" ");
        assert!(joined.contains("hostfwd=tcp::2222-:22"), "{joined}");
        assert!(joined.contains("virtio-net-device"), "{joined}");
    }

    #[test]
    fn a_disk_or_network_is_refused_on_the_faithful_machine() {
        // The faithful machine has neither; allowing it silently would produce a result
        // that reads as a hardware answer.
        let m = model_with(&[], 1, None);
        let boot = BootOptions {
            drives: vec!["rootfs.img".into()],
            ..BootOptions::default()
        };
        assert!(check_profile(&m, &boot).is_err());

        let mut virt = m.clone();
        virt.profile = Profile::Virt;
        assert!(check_profile(&virt, &boot).is_ok());
    }

    #[test]
    fn a_plain_boot_is_allowed_on_the_faithful_machine() {
        let m = model_with(&[], 1, None);
        assert!(check_profile(&m, &BootOptions::default()).is_ok());
    }

    #[test]
    fn deterministic_time_is_requested_explicitly() {
        let m = model_with(&[], 1, None);
        let boot = BootOptions {
            deterministic: true,
            ..BootOptions::default()
        };
        assert!(build_argv(&m, &StockTarget::default(), &boot, &ident)
            .join(" ")
            .contains("-icount"));
    }

    #[test]
    fn argv_construction_is_deterministic() {
        let m = model_with(&[("zbb", "live"), ("zba", "live")], 2, Some((0, 1 << 30)));
        let b = BootOptions {
            kernel: Some("Image".into()),
            append: Some("console=ttyS0".into()),
            ..BootOptions::default()
        };
        let one = build_argv(&m, &StockTarget::default(), &b, &ident);
        let two = build_argv(&m, &StockTarget::default(), &b, &ident);
        assert_eq!(one, two);
    }
}
