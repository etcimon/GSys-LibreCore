// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Building a stock-QEMU invocation from a [`TargetModel`].
//!
//! B0 emits no code. It composes an invocation of an unmodified emulator and, just as
//! importantly, states what that invocation does **not** cover.

use g6q_core::model::{Profile, TargetModel};
use g6q_core::Json;

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

impl Firmware {
    /// Render as a JSON string.
    pub fn to_json(&self) -> Json {
        match self {
            Self::None => Json::str("none"),
            Self::Default => Json::str("default"),
            Self::File(p) => Json::str(p),
        }
    }
}

/// Virtual instruction-counter mode.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub enum Icount {
    /// No `-icount` option.
    #[default]
    Off,
    /// `-icount shift=N,align=off,sleep=off`.
    Shift(u32),
}

impl Icount {
    /// Whether the counter is active.
    pub fn is_on(&self) -> bool {
        !matches!(self, Icount::Off)
    }
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
    /// OS shorthand (`firmware-smoke`, `baremetal`, `buildroot`, `ubuntu`, ...).
    pub os: String,
    /// Kernel command line.
    pub append: Option<String>,
    /// Device tree blob to hand the guest.
    pub dtb: Option<String>,
    /// Bare ELF, for harness-style runs.
    pub elf: Option<String>,
    /// Disk images; each implies a virtio transport.
    pub drives: Vec<String>,
    /// Attach drives as `virtio-blk-pci` (GPEX endpoint) instead of
    /// `virtio-blk-device` (virtio-mmio). EDK2 PciBus enumeration needs PCI;
    /// U-Boot U2 keeps mmio. Not an AI BAR map.
    pub virtio_pci: bool,
    /// SPI NOR images (`-drive if=mtd`). Valid on `g6lc-soc` (Xilinx AXI SPI).
    pub mtd: Vec<String>,
    /// Disk image format for the drives. Empty means `raw` for every drive.
    pub drive_format: String,
    /// Whether to attach user-mode networking.
    pub netdev_user: bool,
    /// Hubport netdev (no slirp) so `virtio-net-pci` can enumerate.
    pub netdev_hub: bool,
    /// Host-to-guest port forwards as `(host, guest)`.
    pub port_forwards: Vec<(u16, u16)>,
    /// Serial destination.
    pub serial: Option<String>,
    /// Console transport: `uart` or `virtio`.
    pub console: String,
    /// Extra virtio devices to attach: `rng` enables `virtio-rng-device`;
    /// `console` is implied by `console=virtio`.
    pub virtio: Vec<String>,
    /// Override the processor count; `None` uses the model's hart total.
    pub smp: Option<u32>,
    /// Override the processor hotplug ceiling; `None` follows `smp`.
    pub maxcpus: Option<u32>,
    /// Override memory size in bytes; otherwise the model's memory window is used.
    pub memory_bytes: Option<u64>,
    /// Emit a deterministic instruction-counted clock.
    pub deterministic: bool,
    /// Explicit `-icount` setting. If `Off`, `--deterministic` forces `Shift(0)`.
    pub icount: Icount,
    /// Request multi-threaded TCG. `None` leaves the default, `Some(true)` forces
    /// multi-thread, `Some(false)` forces single-thread.
    pub mttcg: Option<bool>,
    /// QEMU `-d` debug log categories, if any.
    pub debug: Option<String>,
    /// QEMU `-D` debug log file, if any.
    pub debug_file: Option<String>,
    /// Path to a TCG plugin `.so` to load, if any.
    pub plugin: Option<String>,
    /// EDK2 code pflash (`RISCV_VIRT_CODE.fd`). Implies QEMU virt pflash0/1.
    pub pflash_code: Option<String>,
    /// EDK2 variable pflash (`RISCV_VIRT_VARS.fd`).
    pub pflash_vars: Option<String>,
    /// Raw images loaded at a fixed physical address (`-device loader`).
    /// Used on `g6lc-soc` where there is no virtio disk (U3b DRAM PE).
    pub mem_loads: Vec<(String, u64)>,
}

impl BootOptions {
    /// Render as a canonical JSON object.
    pub fn to_json(&self) -> Json {
        let opt_str = |s: Option<&str>| s.map(Json::str).unwrap_or(Json::Null);
        let opt_int = |s: Option<u64>| s.map(|n| Json::Int(n as i64)).unwrap_or(Json::Null);
        Json::obj(vec![
            ("firmware", self.firmware.to_json()),
            ("kernel", opt_str(self.kernel.as_deref())),
            ("initrd", opt_str(self.initrd.as_deref())),
            ("os", Json::str(&self.os)),
            ("append", opt_str(self.append.as_deref())),
            ("dtb", opt_str(self.dtb.as_deref())),
            ("elf", opt_str(self.elf.as_deref())),
            ("drives", Json::arr(self.drives.iter().map(Json::str))),
            ("virtio_pci", Json::Bool(self.virtio_pci)),
            ("mtd", Json::arr(self.mtd.iter().map(Json::str))),
            ("drive_format", Json::str(&self.drive_format)),
            ("netdev_user", Json::Bool(self.netdev_user)),
            ("netdev_hub", Json::Bool(self.netdev_hub)),
            (
                "port_forwards",
                Json::arr(
                    self.port_forwards
                        .iter()
                        .map(|(h, g)| Json::arr([Json::Int(*h as i64), Json::Int(*g as i64)])),
                ),
            ),
            ("serial", opt_str(self.serial.as_deref())),
            ("console", Json::str(&self.console)),
            ("virtio", Json::arr(self.virtio.iter().map(Json::str))),
            ("smp", opt_int(self.smp.map(|n| n as u64))),
            ("maxcpus", opt_int(self.maxcpus.map(|n| n as u64))),
            ("memory_bytes", opt_int(self.memory_bytes)),
            ("deterministic", Json::Bool(self.deterministic)),
            (
                "icount",
                match &self.icount {
                    Icount::Off => Json::str("off"),
                    Icount::Shift(n) => Json::str(format!("shift={n}")),
                },
            ),
            (
                "mttcg",
                match self.mttcg {
                    None => Json::Null,
                    Some(true) => Json::Bool(true),
                    Some(false) => Json::Bool(false),
                },
            ),
            ("debug", opt_str(self.debug.as_deref())),
            ("debug_file", opt_str(self.debug_file.as_deref())),
            ("plugin", opt_str(self.plugin.as_deref())),
            ("pflash_code", opt_str(self.pflash_code.as_deref())),
            ("pflash_vars", opt_str(self.pflash_vars.as_deref())),
            (
                "mem_loads",
                Json::arr(
                    self.mem_loads
                        .iter()
                        .map(|(p, a)| Json::arr([Json::str(p), Json::addr(*a)])),
                ),
            ),
        ])
    }
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

/// Build the `-smp` argument value.
///
/// If the design's core / thread-per-core topology divides `smp` evenly, emit the
/// topology form so the guest sees a plausible socket/core/thread hierarchy.
/// Otherwise emit a flat count, optionally with a hotplug ceiling.
fn smp_argument(
    smp: u32,
    maxcpus: u32,
    cores: Option<u32>,
    threads_per_core: Option<u32>,
) -> String {
    let topology = match (cores, threads_per_core) {
        (Some(c), Some(t)) if c > 0 && t > 0 && (c * t) > 0 => {
            let sockets = smp / (c * t);
            let rem = smp % (c * t);
            if rem == 0 && sockets > 0 {
                if maxcpus == smp {
                    Some(format!("cores={c},threads={t},sockets={sockets}"))
                } else {
                    Some(format!(
                        "cores={c},threads={t},sockets={sockets},maxcpus={maxcpus}"
                    ))
                }
            } else {
                None
            }
        }
        _ => None,
    };

    if let Some(s) = topology {
        s
    } else if maxcpus == smp {
        smp.to_string()
    } else {
        format!("{smp},maxcpus={maxcpus}")
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
    let mut machine = stock.machine.clone();
    if boot.pflash_code.is_some() && !machine.contains("pflash0") {
        // Upstream RiscVVirt is a QEMU-virt pflash payload (acpi=off per README).
        machine.push_str(",pflash0=pflash0,pflash1=pflash1,acpi=off");
    }
    let mut a: Vec<String> = vec!["-M".into(), machine];

    // A generated B1 machine has its own CPU type and must not take a stock -cpu argument.
    if !stock.cpu_base.is_empty() {
        let mut cpu_arg = cpu_argument(model, &stock.cpu_base, properties_for);
        if model.pmu.counter_count > 0
            && model
                .isa
                .extensions
                .iter()
                .any(|(t, v)| t == "zihpm" && v == "live")
        {
            cpu_arg.push_str(&format!(",pmu-mask={:#x}", model.pmu.counter_mask()));
        }
        a.push("-cpu".into());
        a.push(cpu_arg);
    }

    let smp = boot.smp.unwrap_or(model.soc.harts_total.max(1));
    let maxcpus = boot.maxcpus.unwrap_or(smp).max(smp);
    a.push("-smp".into());
    a.push(smp_argument(
        smp,
        maxcpus,
        model.soc.cores,
        model.soc.threads_per_core,
    ));

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

    if let Some(code) = &boot.pflash_code {
        a.push("-blockdev".into());
        a.push(format!(
            "node-name=pflash0,driver=file,read-only=on,filename={code}"
        ));
        let vars = boot.pflash_vars.as_deref().unwrap_or(code);
        a.push("-blockdev".into());
        a.push(format!("node-name=pflash1,driver=file,filename={vars}"));
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
    let append = match &boot.append {
        Some(a) => Some(a.clone()),
        None => os_append(&boot.os),
    };
    if let Some(append) = append {
        a.push("-append".into());
        a.push(append);
    }

    for (i, drive) in boot.drives.iter().enumerate() {
        let fmt = if boot.drive_format.is_empty() {
            "raw"
        } else {
            &boot.drive_format
        };
        a.push("-drive".into());
        a.push(format!("file={drive},format={fmt},if=none,id=hd{i}"));
        a.push("-device".into());
        let blk = if boot.virtio_pci {
            "virtio-blk-pci"
        } else {
            "virtio-blk-device"
        };
        a.push(format!("{blk},drive=hd{i}"));
    }

    for (i, mtd) in boot.mtd.iter().enumerate() {
        a.push("-drive".into());
        a.push(format!("file={mtd},format=raw,if=mtd,id=mtd{i}"));
    }

    let net_dev = if boot.virtio_pci {
        "virtio-net-pci"
    } else {
        "virtio-net-device"
    };
    if boot.netdev_user {
        let mut spec = String::from("user,id=net0");
        for (host, guest) in &boot.port_forwards {
            spec.push_str(&format!(",hostfwd=tcp::{host}-:{guest}"));
        }
        a.push("-netdev".into());
        a.push(spec);
        a.push("-device".into());
        a.push(format!("{net_dev},netdev=net0"));
    } else if boot.netdev_hub {
        a.push("-netdev".into());
        a.push("hubport,id=net0,hubid=0".into());
        a.push("-device".into());
        a.push(format!("{net_dev},netdev=net0"));
    }

    // QEMU's -nographic already redirects serial to stdio; -serial stdio would
    // create a second stdio character device and fail with "cannot use stdio by
    // multiple character devices" on QEMU 10.x. Only emit -serial when the user
    // explicitly requests a non-stdio backend.
    if let Some(serial) = &boot.serial {
        if serial != "stdio" {
            a.push("-serial".into());
            a.push(serial.clone());
        }
    }

    // virtio-serial-pci is the endpoint "virtio-console" role on GPEX.
    // Do not attach virtconsole to serial0 under -nographic (chardev clash).
    if boot.virtio_pci {
        a.push("-device".into());
        a.push("virtio-serial-pci".into());
    }
    if boot.console == "virtio" {
        if !boot.virtio_pci {
            a.push("-device".into());
            a.push("virtio-serial-device".into());
        }
        a.push("-device".into());
        a.push("virtconsole,chardev=serial0".into());
    }

    for v in &boot.virtio {
        if v.as_str() == "rng" {
            a.push("-object".into());
            a.push("rng-random,id=rng0".into());
            a.push("-device".into());
            a.push("virtio-rng-device,rng=rng0".into());
        }
    }

    // icount is incompatible with MTTCG; resolve the combination before either is emitted.
    let icount = match &boot.icount {
        Icount::Off if boot.deterministic => Icount::Shift(0),
        other => other.clone(),
    };
    let mttcg = if icount.is_on() {
        // icount mode runs on a single TCG thread; ignore a conflicting request.
        Some(false)
    } else {
        boot.mttcg
    };

    match mttcg {
        Some(true) if smp > 1 => a.extend(["-accel".into(), "tcg,thread=multi".into()]),
        Some(false) => a.extend(["-accel".into(), "tcg,thread=single".into()]),
        _ => {}
    }

    match icount {
        Icount::Shift(n) => {
            a.push("-icount".into());
            a.push(format!("shift={n},align=off,sleep=off"));
        }
        Icount::Off => {}
    }

    if let Some(debug) = &boot.debug {
        a.push("-d".into());
        a.push(debug.clone());
    }
    if let Some(debug_file) = &boot.debug_file {
        a.push("-D".into());
        a.push(debug_file.clone());
    }

    if let Some(plugin) = &boot.plugin {
        a.push("-plugin".into());
        a.push(plugin.clone());
    }

    for (path, addr) in &boot.mem_loads {
        a.push("-device".into());
        a.push(format!("loader,file={path},addr={addr:#x},force-raw=on"));
    }

    a.push("-nographic".into());
    a
}

/// Default kernel command line for a known OS shorthand.
///
/// These are software conventions, not design constants. They are only used when the user
/// did not supply an explicit `--append`.
fn os_append(os: &str) -> Option<String> {
    match os {
        "buildroot" => Some("root=/dev/vda rw console=ttyS0".into()),
        "ubuntu" | "debian" | "fedora" => Some("root=/dev/vda rw console=ttyS0".into()),
        _ => None,
    }
}

/// Whether the requested boot needs facilities the faithful profile does not have.
///
/// Disks and networking do not exist on the faithful machine; asking for them silently
/// would produce a result that looks like a hardware answer and is not one.
pub fn requires_virt_profile(boot: &BootOptions) -> bool {
    !boot.drives.is_empty()
        || boot.netdev_user
        || boot.netdev_hub
        || boot.console == "virtio"
        || !boot.virtio.is_empty()
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
            timebase_hz: 1_000_000,
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
    fn edk2_pflash_wires_virt_blockdevs() {
        let m = model_with(&[], 2, Some((0x8000_0000, 0x4000_0000)));
        let boot = BootOptions {
            pflash_code: Some("CODE.fd".into()),
            pflash_vars: Some("VARS.fd".into()),
            ..BootOptions::default()
        };
        let joined = build_argv(&m, &StockTarget::default(), &boot, &ident).join(" ");
        assert!(joined.contains("pflash0=pflash0"), "{joined}");
        assert!(joined.contains("acpi=off"), "{joined}");
        assert!(joined.contains("filename=CODE.fd"), "{joined}");
        assert!(joined.contains("filename=VARS.fd"), "{joined}");
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
        assert!(!joined.contains("virtio-blk-pci"), "{joined}");
    }

    #[test]
    fn virtio_pci_emits_blk_pci_not_mmio() {
        let m = model_with(&[], 1, None);
        let boot = BootOptions {
            drives: vec!["esp.img".into()],
            virtio_pci: true,
            ..BootOptions::default()
        };
        let joined = build_argv(&m, &StockTarget::default(), &boot, &ident).join(" ");
        assert!(joined.contains("virtio-blk-pci"), "{joined}");
        assert!(!joined.contains("virtio-blk-device"), "{joined}");
    }

    #[test]
    fn virtio_pci_emits_net_pci_not_mmio() {
        let m = model_with(&[], 1, None);
        let boot = BootOptions {
            netdev_user: true,
            virtio_pci: true,
            ..BootOptions::default()
        };
        let joined = build_argv(&m, &StockTarget::default(), &boot, &ident).join(" ");
        assert!(joined.contains("virtio-net-pci"), "{joined}");
        assert!(!joined.contains("virtio-net-device"), "{joined}");
    }

    #[test]
    fn netdev_hub_emits_hubport_and_virtio_net_pci() {
        let m = model_with(&[], 1, None);
        let boot = BootOptions {
            netdev_hub: true,
            virtio_pci: true,
            ..BootOptions::default()
        };
        assert!(requires_virt_profile(&boot));
        let joined = build_argv(&m, &StockTarget::default(), &boot, &ident).join(" ");
        assert!(joined.contains("hubport,id=net0,hubid=0"), "{joined}");
        assert!(joined.contains("virtio-net-pci"), "{joined}");
        assert!(!joined.contains("-netdev user"), "{joined}");
    }

    #[test]
    fn virtio_pci_emits_serial_pci_without_virtconsole() {
        let m = model_with(&[], 1, None);
        let boot = BootOptions {
            virtio_pci: true,
            ..BootOptions::default()
        };
        let joined = build_argv(&m, &StockTarget::default(), &boot, &ident).join(" ");
        assert!(joined.contains("virtio-serial-pci"), "{joined}");
        assert!(!joined.contains("virtio-serial-device"), "{joined}");
        assert!(!joined.contains("virtconsole"), "{joined}");
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
    fn a_plugin_path_is_emitted_in_argv() {
        let m = model_with(&[], 1, None);
        let boot = BootOptions {
            plugin: Some("out/emit/t/contrib/plugins/g6lc-t.so".into()),
            ..BootOptions::default()
        };
        let joined = build_argv(&m, &StockTarget::default(), &boot, &ident).join(" ");
        assert!(joined.contains("-plugin"), "{joined}");
        assert!(
            joined.contains("out/emit/t/contrib/plugins/g6lc-t.so"),
            "{joined}"
        );
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

    #[test]
    fn pmu_mask_is_appended_when_zihpm_live() {
        let mut m = model_with(&[("zihpm", "live")], 1, None);
        m.pmu.counter_count = 6;
        let argv = build_argv(&m, &StockTarget::default(), &BootOptions::default(), &ident);
        let joined = argv.join(" ");
        assert!(joined.contains("pmu-mask=0x1f8"), "{joined}");
    }

    #[test]
    fn smp_uses_topology_when_the_model_has_one() {
        let mut m = model_with(&[], 4, None);
        m.soc.cores = Some(2);
        m.soc.threads_per_core = Some(2);
        let argv = build_argv(&m, &StockTarget::default(), &BootOptions::default(), &ident);
        let joined = argv.join(" ");
        assert!(
            joined.contains("-smp cores=2,threads=2,sockets=1"),
            "{joined}"
        );
    }

    #[test]
    fn maxcpus_adds_a_hotplug_ceiling() {
        let mut m = model_with(&[], 4, None);
        m.soc.cores = Some(2);
        m.soc.threads_per_core = Some(2);
        let boot = BootOptions {
            maxcpus: Some(8),
            ..BootOptions::default()
        };
        let argv = build_argv(&m, &StockTarget::default(), &boot, &ident);
        let joined = argv.join(" ");
        assert!(
            joined.contains("-smp cores=2,threads=2,sockets=1,maxcpus=8"),
            "{joined}"
        );
    }

    #[test]
    fn deterministic_time_uses_icount_and_single_thread_tcg() {
        let m = model_with(&[], 2, None);
        let boot = BootOptions {
            deterministic: true,
            ..BootOptions::default()
        };
        let joined = build_argv(&m, &StockTarget::default(), &boot, &ident).join(" ");
        assert!(
            joined.contains("-icount shift=0,align=off,sleep=off"),
            "{joined}"
        );
        assert!(joined.contains("-accel tcg,thread=single"), "{joined}");
        assert!(!joined.contains("thread=multi"), "{joined}");
    }

    #[test]
    fn explicit_icount_overrides_shift() {
        let m = model_with(&[], 1, None);
        let boot = BootOptions {
            icount: Icount::Shift(3),
            ..BootOptions::default()
        };
        let joined = build_argv(&m, &StockTarget::default(), &boot, &ident).join(" ");
        assert!(
            joined.contains("-icount shift=3,align=off,sleep=off"),
            "{joined}"
        );
    }

    #[test]
    fn tuned_tuning_requests_mttcg() {
        let m = model_with(&[], 4, None);
        let boot = BootOptions {
            mttcg: Some(true),
            ..BootOptions::default()
        };
        let joined = build_argv(&m, &StockTarget::default(), &boot, &ident).join(" ");
        assert!(joined.contains("-accel tcg,thread=multi"), "{joined}");
    }

    #[test]
    fn icount_suppresses_mttcg_request() {
        let m = model_with(&[], 4, None);
        let boot = BootOptions {
            icount: Icount::Shift(0),
            mttcg: Some(true),
            ..BootOptions::default()
        };
        let joined = build_argv(&m, &StockTarget::default(), &boot, &ident).join(" ");
        assert!(joined.contains("-icount"), "{joined}");
        assert!(joined.contains("-accel tcg,thread=single"), "{joined}");
        assert!(!joined.contains("thread=multi"), "{joined}");
    }

    #[test]
    fn os_default_appends_a_root_argument() {
        let m = model_with(&[], 1, None);
        let boot = BootOptions {
            os: "buildroot".into(),
            drives: vec!["disk.img".into()],
            ..BootOptions::default()
        };
        let joined = build_argv(&m, &StockTarget::default(), &boot, &ident).join(" ");
        assert!(
            joined.contains("root=/dev/vda rw console=ttyS0"),
            "{joined}"
        );
    }

    #[test]
    fn explicit_append_overrides_os_default() {
        let m = model_with(&[], 1, None);
        let boot = BootOptions {
            os: "ubuntu".into(),
            append: Some("root=/dev/vda1".into()),
            ..BootOptions::default()
        };
        let joined = build_argv(&m, &StockTarget::default(), &boot, &ident).join(" ");
        assert!(joined.contains("root=/dev/vda1"), "{joined}");
        assert!(!joined.contains("console=ttyS0"), "{joined}");
    }

    #[test]
    fn mem_loads_emit_device_loader() {
        let m = model_with(&[], 1, None);
        let boot = BootOptions {
            mem_loads: vec![("pe.bin".into(), 0x8400_0000)],
            ..BootOptions::default()
        };
        let joined = build_argv(&m, &StockTarget::default(), &boot, &ident).join(" ");
        assert!(
            joined.contains("-device loader,file=pe.bin,addr=0x84000000,force-raw=on"),
            "{joined}"
        );
        assert!(
            !joined.contains("virtio-blk-device"),
            "DRAM loads must not imply virtio: {joined}"
        );
    }

    #[test]
    fn mtd_drive_is_if_mtd_and_does_not_force_virt() {
        let m = model_with(&[], 2, Some((0x8000_0000, 0x1000_0000)));
        let boot = BootOptions {
            mtd: vec!["spi-nor.img".into()],
            ..BootOptions::default()
        };
        assert!(!requires_virt_profile(&boot));
        let joined = build_argv(&m, &StockTarget::default(), &boot, &ident).join(" ");
        assert!(joined.contains("if=mtd"), "{joined}");
        assert!(joined.contains("file=spi-nor.img"), "{joined}");
        assert!(!joined.contains("virtio-blk"), "{joined}");
    }

    #[test]
    fn rootfs_format_is_used_for_drives() {
        let m = model_with(&[], 1, None);
        let boot = BootOptions {
            drives: vec!["disk.qcow2".into()],
            drive_format: "qcow2".into(),
            ..BootOptions::default()
        };
        let joined = build_argv(&m, &StockTarget::default(), &boot, &ident).join(" ");
        assert!(joined.contains("format=qcow2"), "{joined}");
    }

    #[test]
    fn virtio_console_is_a_virt_transport() {
        let mut virt = model_with(&[], 1, None);
        virt.profile = Profile::Virt;
        let boot = BootOptions {
            console: "virtio".into(),
            ..BootOptions::default()
        };
        assert!(check_profile(&virt, &boot).is_ok());
        let joined = build_argv(&virt, &StockTarget::default(), &boot, &ident).join(" ");
        assert!(joined.contains("virtio-serial-device"), "{joined}");
        assert!(joined.contains("virtconsole"), "{joined}");

        // A faithful machine has no virtio transports.
        let m = model_with(&[], 1, None);
        assert!(check_profile(&m, &boot).is_err());
    }

    #[test]
    fn virtio_rng_emits_a_random_source() {
        let mut virt = model_with(&[], 1, None);
        virt.profile = Profile::Virt;
        let boot = BootOptions {
            virtio: vec!["rng".into()],
            ..BootOptions::default()
        };
        let joined = build_argv(&virt, &StockTarget::default(), &boot, &ident).join(" ");
        assert!(joined.contains("rng-random,id=rng0"), "{joined}");
        assert!(joined.contains("virtio-rng-device"), "{joined}");
    }

    #[test]
    fn nographic_does_not_emit_redundant_serial_stdio() {
        let m = model_with(&[], 1, None);
        let joined =
            build_argv(&m, &StockTarget::default(), &BootOptions::default(), &ident).join(" ");
        assert!(joined.contains("-nographic"), "{joined}");
        assert!(!joined.contains("-serial"), "{joined}");
    }

    #[test]
    fn explicit_non_stdio_serial_is_emitted() {
        let m = model_with(&[], 1, None);
        let boot = BootOptions {
            serial: Some("file:/tmp/serial.log".into()),
            ..BootOptions::default()
        };
        let joined = build_argv(&m, &StockTarget::default(), &boot, &ident).join(" ");
        assert!(joined.contains("-serial file:/tmp/serial.log"), "{joined}");
    }
}
