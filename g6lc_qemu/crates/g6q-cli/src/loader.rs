// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// loader.rs — U-Boot / EDK2 build-only scaffolding for `g6lc-qemu fw`.
//
// U0/E0 are build-time gates; E1 wraps upstream OvmfPkg/RiscVVirt rather than
// inventing an empty DSC. This module clones pinned upstream source, generates a
// target-specific board package from `TargetModel`, and attempts the loader build.
// It writes the scaffolding and a build script, reports what is missing, and never
// claims green when the host cannot run the build.

use std::path::{Path, PathBuf};
use std::process::Command;

use crate::args::Args;
use crate::pins::Pins;
use g6q_core::json::Json;
use g6q_core::model::{Peripheral, Profile, TargetModel};

/// Which second-stage loader is being staged.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Loader {
    Uboot,
    Edk2,
}

impl Loader {
    pub fn as_str(&self) -> &'static str {
        match self {
            Loader::Uboot => "u-boot",
            Loader::Edk2 => "edk2",
        }
    }

    fn pins_table(&self) -> &'static str {
        match self {
            Loader::Uboot => "u_boot",
            Loader::Edk2 => "edk2",
        }
    }

    fn default_src(&self) -> &'static str {
        match self {
            Loader::Uboot => "out/loader-src/u-boot",
            Loader::Edk2 => "out/loader-src/edk2",
        }
    }

    fn default_out(&self, target: &str, machine: &str) -> String {
        match self {
            Loader::Uboot => format!("out/loader-build/u-boot-{target}-{machine}"),
            Loader::Edk2 => format!("out/loader-build/edk2-{target}-{machine}"),
        }
    }

    fn build_script_name(&self) -> &'static str {
        match self {
            Loader::Uboot => "u-boot-build.sh",
            Loader::Edk2 => "edk2-build.sh",
        }
    }

    /// Parse the `--loader` option value.
    pub fn from_arg(s: &str) -> Option<Self> {
        match s {
            "u-boot" | "u_boot" | "uboot" => Some(Loader::Uboot),
            "edk2" => Some(Loader::Edk2),
            _ => None,
        }
    }
}

/// Return the loader selected by `--loader`, if any.
pub fn from_args(args: &Args) -> Option<Loader> {
    args.value("loader").and_then(Loader::from_arg)
}

/// `g6q fw fetch --loader <u-boot|edk2>` — clone the pinned upstream source.
pub fn fetch(args: &Args) -> Result<(), String> {
    let loader = from_args(args).ok_or("--loader u-boot|edk2 is required")?;
    let pins = load_pins()?;
    let src = src_dir(args, loader);

    if src.is_dir() && std::fs::read_dir(&src).map(|d| d.count()).unwrap_or(0) > 0 {
        return Err(format!(
            "loader source directory already exists and is not empty: {}",
            src.display()
        ));
    }

    let (url, rev) = pin_url(&pins, loader)?;
    let dry_run = args.flag("dry-run");

    match loader {
        Loader::Uboot => {
            if dry_run {
                print_fetch_plan(loader, url, rev, &src);
                return Ok(());
            }
            git_clone(url, rev, &src)?;
        }
        Loader::Edk2 => {
            if dry_run {
                print_fetch_plan(loader, url, rev, &src);
                let platforms_src = edk2_platforms_src(args, &pins);
                let (purl, prev) = edk2_platforms_pin(&pins)?;
                print_fetch_plan(Loader::Edk2, purl, prev, &platforms_src);
                return Ok(());
            }
            git_clone(url, rev, &src)?;
            let platforms_src = edk2_platforms_src(args, &pins);
            let (purl, prev) = edk2_platforms_pin(&pins)?;
            git_clone(purl, prev, &platforms_src)?;
        }
    }

    let j = Json::obj([
        ("loader", Json::str(loader.as_str())),
        ("url", Json::str(url)),
        ("ref", Json::str(rev)),
        ("src", Json::str(&*src.to_string_lossy())),
        ("status", Json::str("fetched")),
    ]);
    print!("{}", j.to_pretty());
    Ok(())
}

/// `g6q fw build --loader <u-boot|edk2> --target <id> [--machine g6lc-virt]`
///
/// Build-only scaffolding: writes a generated board package and a build script, then
/// attempts the build when the source and a cross-toolchain are present. Dry-run only
/// writes the package and prints the plan; it does not invoke the loader build.
pub fn build(args: &Args) -> Result<(), String> {
    let loader = from_args(args).ok_or("--loader u-boot|edk2 is required")?;
    let pins = load_pins()?;
    let src = src_dir(args, loader);
    let out = out_dir(args, loader)?;
    let machine = args.value_or("machine", "g6lc-soc");
    let target = args.value_or("target", "g6lc64_smt2");
    let dry_run = args.flag("dry-run");

    let model = resolve_model(args)?;

    // In dry-run we do not probe the host; otherwise a cross-toolchain is required.
    let (cross, use_wsl) = if dry_run {
        let wsl = cfg!(windows) && crate::wsl_available();
        ("riscv64-unknown-elf-".to_string(), wsl)
    } else {
        crate::detect_cross_compile(args)?
    };

    std::fs::create_dir_all(&out)
        .map_err(|e| format!("cannot create output directory {}: {e}", out.display()))?;

    let board_pkg = out.join("board-package");
    std::fs::create_dir_all(&board_pkg).map_err(|e| {
        format!(
            "cannot create board package dir {}: {e}",
            board_pkg.display()
        )
    })?;

    let mut missing: Vec<String> = Vec::new();
    if !dry_run {
        if !src.is_dir() {
            missing.push(format!(
                "loader source not found at {}; run `fw fetch --loader {}` first",
                src.display(),
                loader.as_str()
            ));
        } else if !source_ready(&src, loader) {
            missing.push(format!(
                "loader source at {} does not look like a {} tree",
                src.display(),
                loader.as_str()
            ));
        }
    }

    let plan = match loader {
        Loader::Uboot => uboot_generate_package(
            args,
            &pins,
            &model,
            &src,
            &board_pkg,
            &cross,
            use_wsl,
            dry_run,
            &mut missing,
        )?,
        Loader::Edk2 => edk2_generate_package(
            args,
            &pins,
            &model,
            &src,
            &board_pkg,
            &cross,
            use_wsl,
            dry_run,
            &mut missing,
        )?,
    };

    if !missing.is_empty() {
        let note = Json::obj([
            ("loader", Json::str(loader.as_str())),
            ("target", Json::str(target)),
            ("machine", Json::str(machine)),
            ("status", Json::str("missing-prerequisites")),
            ("missing", Json::arr(missing.into_iter().map(Json::str))),
        ]);
        if dry_run {
            print!("{}", note.to_pretty());
            return Ok(());
        }
        return Err(format!(
            "loader build is missing prerequisites:\n  {}",
            note.to_pretty()
        ));
    }

    if dry_run {
        print!("{}", plan.to_pretty());
        return Ok(());
    }

    // Real build: run the generated script.
    let script = board_pkg.join(loader.build_script_name());
    if !script.is_file() {
        return Err(format!(
            "generated build script not found: {}",
            script.display()
        ));
    }

    let status = if use_wsl {
        Command::new("wsl")
            .arg("bash")
            .arg(&crate::make_path_arg(&script, true)?)
            .status()
    } else {
        Command::new("bash").arg(&script).status()
    }
    .map_err(|e| format!("failed to invoke build script {}: {e}", script.display()))?;

    if !status.success() {
        return Err(format!(
            "{} build failed with status {status:?}; see the build script and output under {}",
            loader.as_str(),
            out.display()
        ));
    }

    let done = Json::obj([
        ("loader", Json::str(loader.as_str())),
        ("target", Json::str(target)),
        ("machine", Json::str(machine)),
        ("src", Json::str(&*script_path(&src, use_wsl))),
        ("build", Json::str(&*script_path(&out, use_wsl))),
        ("cross_compile", Json::str(&cross)),
        ("wsl", Json::str(if use_wsl { "yes" } else { "no" })),
        ("status", Json::str("built")),
    ]);
    print!("{}", done.to_pretty());
    Ok(())
}

// --------------------------------------------------------------------- helpers ---

fn load_pins() -> Result<Pins, String> {
    let path = Pins::find(std::env::current_dir().unwrap_or_default().as_path())
        .ok_or("cannot find pins.toml; run from inside the package")?;
    Pins::from_file(&path).map_err(|e| format!("cannot read pins.toml: {e}"))
}

fn pin_url(pins: &Pins, loader: Loader) -> Result<(&str, &str), String> {
    let table = loader.pins_table();
    let url = pins
        .get(table, "url")
        .ok_or_else(|| format!("pins.toml [{table}] is missing 'url'"))?;
    let rev = pins
        .get(table, "ref")
        .ok_or_else(|| format!("pins.toml [{table}] is missing 'ref'"))?;
    Ok((url, rev))
}

fn edk2_platforms_pin(pins: &Pins) -> Result<(&str, &str), String> {
    let url = pins
        .get("edk2_platforms", "url")
        .ok_or("pins.toml [edk2_platforms] is missing 'url'")?;
    let rev = pins
        .get("edk2_platforms", "ref")
        .ok_or("pins.toml [edk2_platforms] is missing 'ref'")?;
    Ok((url, rev))
}

fn src_dir(args: &Args, loader: Loader) -> PathBuf {
    args.value("loader-src")
        .map(PathBuf::from)
        .or_else(|| {
            load_pins()
                .ok()
                .and_then(|pins| pins.get(loader.pins_table(), "src").map(PathBuf::from))
        })
        .unwrap_or_else(|| PathBuf::from(loader.default_src()))
}

fn edk2_platforms_src(args: &Args, pins: &Pins) -> PathBuf {
    args.value("edk2-platforms-src")
        .map(PathBuf::from)
        .or_else(|| pins.get("edk2_platforms", "src").map(PathBuf::from))
        .unwrap_or_else(|| PathBuf::from("out/loader-src/edk2-platforms"))
}

fn out_dir(args: &Args, loader: Loader) -> Result<PathBuf, String> {
    if let Some(p) = args.value("loader-out") {
        return Ok(PathBuf::from(p));
    }
    let target = args.value_or("target", "g6lc64_smt2");
    let machine = args.value_or("machine", "g6lc-soc");
    Ok(PathBuf::from(loader.default_out(target, machine)))
}

fn resolve_model(args: &Args) -> Result<TargetModel, String> {
    let has_inputs = args.value("target").is_some()
        || args.value("repo-root").is_some()
        || args.value("config-pkg").is_some()
        || args.value("dts").is_some();

    if has_inputs {
        let resolved = crate::resolve::resolve(args)?;
        let mut model = g6q_ingest::assemble(&resolved.sources);
        if let Some(machine) = args.value("machine") {
            model.profile = if machine == "g6lc-virt" {
                Profile::Virt
            } else {
                Profile::Soc
            };
        }
        Ok(model)
    } else {
        Ok(minimal_model(args))
    }
}

fn minimal_model(args: &Args) -> TargetModel {
    let mut m = TargetModel::new(args.value_or("target", "g6lc64_smt2"));
    m.soc.dram = Some((0x8000_0000, 0x4000_0000));
    m.soc.harts_total = 2;
    m.soc.cores = Some(1);
    m.soc.threads_per_core = Some(2);
    m.soc.contexts_per_hart = 1;
    m.soc.intc_sources = 16;
    m.soc.intc_targets = 16;
    m.soc.peripherals.push(Peripheral {
        id: "clint".into(),
        base: 0x0200_0000,
        len: 0x10000,
        ..Default::default()
    });
    m.soc.peripherals.push(Peripheral {
        id: "plic".into(),
        base: 0x0c00_0000,
        len: 0x40_0000,
        ..Default::default()
    });
    m.soc.peripherals.push(Peripheral {
        id: "uart".into(),
        base: 0x1000_0000,
        len: 0x100,
        ..Default::default()
    });
    m.isa.xlen = 64;
    m.isa.base = "rv64i".into();
    m.isa.isa_string = "rv64imac".into();
    m
}

fn source_ready(src: &Path, loader: Loader) -> bool {
    match loader {
        Loader::Uboot => src.join("Makefile").is_file(),
        Loader::Edk2 => src.join("edksetup.sh").is_file(),
    }
}

fn git_clone(url: &str, rev: &str, dst: &Path) -> Result<(), String> {
    std::fs::create_dir_all(dst.parent().unwrap_or(Path::new("")))
        .map_err(|e| format!("cannot create parent of {}: {e}", dst.display()))?;
    let status = Command::new("git")
        .args([
            "clone",
            "--depth",
            "1",
            "--branch",
            rev,
            url,
            &dst.to_string_lossy(),
        ])
        .status()
        .map_err(|e| format!("failed to run git: {e}"))?;
    if !status.success() {
        return Err(format!("git clone failed with status {status:?}"));
    }
    Ok(())
}

fn print_fetch_plan(loader: Loader, url: &str, rev: &str, dst: &Path) {
    let j = Json::obj([
        ("loader", Json::str(loader.as_str())),
        ("url", Json::str(url)),
        ("ref", Json::str(rev)),
        ("dst", Json::str(&*dst.to_string_lossy())),
        (
            "command",
            Json::str(format!(
                "git clone --depth 1 --branch {rev} {url} {}",
                dst.display()
            )),
        ),
    ]);
    print!("{}", j.to_pretty());
}

fn script_path(p: &Path, use_wsl: bool) -> String {
    if use_wsl {
        crate::make_path_arg(p, true).unwrap_or_else(|_| p.to_string_lossy().replace('\\', "/"))
    } else {
        p.to_string_lossy().replace('\\', "/")
    }
}

fn json_files(dir: &Path) -> Json {
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .ok()
        .into_iter()
        .flat_map(|rd| {
            rd.filter_map(|e| e.ok()).map(|e| {
                let p = e.path();
                if p.is_file() {
                    p.file_name().map(|n| n.to_string_lossy().into_owned())
                } else {
                    None
                }
            })
        })
        .flatten()
        .collect();
    names.sort();
    Json::arr(names.into_iter().map(Json::str))
}

// ------------------------------------------------------------------ U-Boot U0 ---

#[allow(clippy::too_many_arguments)]
fn uboot_generate_package(
    args: &Args,
    pins: &Pins,
    model: &TargetModel,
    src: &Path,
    board_pkg: &Path,
    cross: &str,
    use_wsl: bool,
    dry_run: bool,
    missing: &mut Vec<String>,
) -> Result<Json, String> {
    let (dram_base, dram_len) = model.soc.dram.unwrap_or((0x8000_0000, 0x4000_0000));
    let target = args.value_or("target", "g6lc64_smt2");
    let machine = args.value_or("machine", "g6lc-soc");
    let safe_target = target.replace(|c: char| !c.is_alphanumeric(), "_");

    let base_defconfig = pins
        .get("u_boot", "defconfig_base")
        .unwrap_or("qemu-riscv64_smode_defconfig");
    let text_offset = pins
        .get("u_boot", "text_base_offset")
        .and_then(parse_hex)
        .unwrap_or(0x200000);
    let text_base = dram_base + text_offset;

    // Read the upstream base defconfig if the source is present.
    let defconfig_path = src.join("configs").join(base_defconfig);
    let defconfig_body = if defconfig_path.is_file() {
        let base = std::fs::read_to_string(&defconfig_path)
            .map_err(|e| format!("cannot read {}: {e}", defconfig_path.display()))?;
        apply_uboot_overrides(&base, text_base, text_base, &safe_target)
    } else if dry_run {
        format!(
            "# Base defconfig {base_defconfig} not present in source tree (dry-run).\n\
             # This fragment will be merged with the base defconfig at build time.\n"
        )
    } else {
        missing.push(format!(
            "base defconfig not found: {}; run `fw fetch --loader u-boot` first",
            defconfig_path.display()
        ));
        String::new()
    };

    let config_fragment = uboot_config_fragment(text_base, dram_base, dram_len, machine);
    let board_header = uboot_board_header(&safe_target, text_base, dram_base, dram_len);
    let its = uboot_fit_its(model, &safe_target, text_base);
    let script = uboot_build_script(
        &script_path(src, use_wsl),
        &script_path(board_pkg.parent().unwrap_or(Path::new("out")), use_wsl),
        cross,
        &script_path(board_pkg, use_wsl),
        base_defconfig,
    );
    let readme = uboot_readme(&safe_target);

    crate::write_out(
        board_pkg
            .join(format!("{safe_target}_defconfig"))
            .to_str()
            .unwrap(),
        &defconfig_body,
    )?;
    crate::write_out(
        board_pkg.join("config-fragment").to_str().unwrap(),
        &config_fragment,
    )?;
    crate::write_out(
        board_pkg.join(format!("{safe_target}.h")).to_str().unwrap(),
        &board_header,
    )?;
    crate::write_out(board_pkg.join("g6lc.its").to_str().unwrap(), &its)?;
    crate::write_out(
        board_pkg
            .join(Loader::Uboot.build_script_name())
            .to_str()
            .unwrap(),
        &script,
    )?;
    crate::write_out(board_pkg.join("README.txt").to_str().unwrap(), &readme)?;

    Ok(Json::obj([
        ("loader", Json::str("u-boot")),
        ("target", Json::str(target)),
        ("machine", Json::str(machine)),
        ("src", Json::str(&*script_path(src, use_wsl))),
        ("build", Json::str(&*script_path(board_pkg.parent().unwrap_or(Path::new("out")), use_wsl))),
        ("cross_compile", Json::str(cross)),
        ("wsl", Json::str(if use_wsl { "yes" } else { "no" })),
        ("base_defconfig", Json::str(base_defconfig)),
        ("text_base", Json::addr(text_base)),
        ("dram_base", Json::addr(dram_base)),
        ("dram_len", Json::addr(dram_len)),
        ("board_package", json_files(board_pkg)),
        (
            "command",
            Json::str(format!(
                "bash {} {}",
                script_path(&board_pkg.join(Loader::Uboot.build_script_name()), use_wsl),
                script_path(src, use_wsl)
            )),
        ),
        ("status", Json::str(if dry_run { "dry-run" } else { "planned" })),
        (
            "note",
            Json::str("U0 scaffolding: a generated defconfig + board header + FIT source + build script. \
                       The script uses the qemu-riscv64_smode base defconfig and merges the fragment; \
                       a full g6lc board Kconfig integration is not yet implemented."),
        ),
    ]))
}

fn apply_uboot_overrides(base: &str, text_base: u64, load_addr: u64, _target: &str) -> String {
    let mut out = String::new();
    for line in base.lines() {
        let trim = line.trim();
        if trim.starts_with("CONFIG_SYS_TEXT_BASE=") {
            out.push_str(&format!("CONFIG_SYS_TEXT_BASE={text_base:#x}\n"));
        } else if trim.starts_with("CONFIG_SYS_LOAD_ADDR=") {
            out.push_str(&format!("CONFIG_SYS_LOAD_ADDR={load_addr:#x}\n"));
        } else {
            out.push_str(line);
            out.push('\n');
        }
    }
    out
}

fn uboot_config_fragment(text_base: u64, dram_base: u64, dram_len: u64, machine: &str) -> String {
    let mut s = format!(
        "# Generated config fragment for g6lc_qemu U-Boot build\n\
         CONFIG_SYS_TEXT_BASE={text_base:#x}\n\
         CONFIG_SYS_LOAD_ADDR={text_base:#x}\n\
         CONFIG_NR_DRAM_BANKS=1\n\
         CONFIG_SYS_SDRAM_BASE={dram_base:#x}\n\
         CONFIG_SYS_BOOTMAPSZ={dram_len:#x}\n\
         # CONFIG_TOOLS_MKEFICAPSULE is not set\n",
    );
    if machine == "g6lc-soc" {
        // No virtio/SD. Payload is SPI NOR (`n25q256a`); U-Boot `sf read`s it
        // to kernel_addr_r. ${fdtcontroladdr} expands at runtime.
        s.push_str("CONFIG_BOOTDELAY=0\n");
        s.push_str("CONFIG_SPI=y\n");
        s.push_str("CONFIG_DM_SPI=y\n");
        s.push_str("CONFIG_XILINX_SPI=y\n");
        s.push_str("CONFIG_SPI_FLASH=y\n");
        s.push_str("CONFIG_DM_SPI_FLASH=y\n");
        s.push_str("CONFIG_SPI_FLASH_STMICRO=y\n");
        s.push_str("CONFIG_CMD_SF=y\n");
        // g6lc-soc has no display, PCI, or USB. qemu-riscv64_smode turns
        // those on for virt; probing them from EFI ConnectAll hangs Shell.
        s.push_str("# CONFIG_VIDEO is not set\n");
        s.push_str("# CONFIG_PCI is not set\n");
        s.push_str("# CONFIG_USB is not set\n");
        // 0x1800000 = 24 MiB covers the ~21 MiB EFI FIT in a 32 MiB n25q256a.
        // stdout/stderr serial: g6lc-soc has no display; vidconsole/GOP can
        // swallow EFI ConOut. Empty bootargs so Shell.efi LoadOptions is not
        // the Linux cmdline. bootm of a FIT (OpenWrt or Shell) is the happy
        // path; bootefi hello is an ASCII EFI witness; bootefi addr:size is
        // the raw-PE fallback. FDT /chosen/bootargs still feeds the kernel.
        s.push_str(&format!(
            "CONFIG_BOOTCOMMAND=\"sf probe 0:0 && echo SPI-PROBE-DONE && sf read {UBOOT_SOC_EFI_ADDR:#x} 0 0x1800000 && echo SPI-READ-DONE; setenv stdout serial; setenv stderr serial; setenv bootargs; fdt addr ${{fdtcontroladdr}}; fdt set /chosen bootargs \\\"earlycon=sbi console=ttyS0,115200n8\\\"; bootm {UBOOT_SOC_EFI_ADDR:#x}; echo HELLO-EFI; bootefi hello; bootefi {UBOOT_SOC_EFI_ADDR:#x}:0x2000000 ${{fdtcontroladdr}}\"\n"
        ));
    }
    s
}

fn uboot_board_header(target: &str, text_base: u64, dram_base: u64, dram_len: u64) -> String {
    let guard = target.to_uppercase();
    format!(
        "/* SPDX-License-Identifier: GPL-2.0-or-later */\n\
         /* Generated by g6lc-qemu; do not edit. */\n\
         #ifndef __{guard}_H\n\
         #define __{guard}_H\n\n\
         #define CONFIG_SYS_TEXT_BASE\t{text_base:#x}\n\
         #define CONFIG_SYS_LOAD_ADDR\t{text_base:#x}\n\
         #define CONFIG_NR_DRAM_BANKS\t1\n\
         #define PHYS_SDRAM_0\t\t{dram_base:#x}\n\
         #define PHYS_SDRAM_0_SIZE\t{dram_len:#x}\n\n\
         #endif /* __{guard}_H */\n",
    )
}

fn uboot_fit_its(_model: &TargetModel, target: &str, load_addr: u64) -> String {
    format!(
        "/dts-v1/;\n\
         \n\
         / {{\n\
         \tdescription = \"G6LC FIT for {target}\";\n\
         \t#address-cells = <2>;\n\
         \t#size-cells = <2>;\n\
         \n\
         \timages {{\n\
         \t\tkernel {{\n\
         \t\t\tdescription = \"Linux kernel\";\n\
         \t\t\tdata = /incbin/(\"Image\");\n\
         \t\t\ttype = \"kernel\";\n\
         \t\t\tarch = \"riscv\";\n\
         \t\t\tos = \"linux\";\n\
         \t\t\tcompression = \"none\";\n\
         \t\t\tload = <0x0 {load_addr:#x}>;\n\
         \t\t\tentry = <0x0 {load_addr:#x}>;\n\
         \t\t}};\n\
         \t\tfdt {{\n\
         \t\t\tdescription = \"Flattened device tree\";\n\
         \t\t\tdata = /incbin/(\"g6lc-virt.dtb\");\n\
         \t\t\ttype = \"flat_dt\";\n\
         \t\t\tarch = \"riscv\";\n\
         \t\t\tcompression = \"none\";\n\
         \t\t}};\n\
         \t\tramdisk {{\n\
         \t\t\tdescription = \"initramfs\";\n\
         \t\t\tdata = /incbin/(\"initrd.img\");\n\
         \t\t\ttype = \"ramdisk\";\n\
         \t\t\tarch = \"riscv\";\n\
         \t\t\tos = \"linux\";\n\
         \t\t\tcompression = \"none\";\n\
         \t\t\tload = <0x0 {load_addr:#x}>;\n\
         \t\t}};\n\
         \t}};\n\
         \n\
         \tconfigurations {{\n\
         \t\tdefault = \"g6lc\";\n\
         \t\tg6lc {{\n\
         \t\t\tdescription = \"g6lc-virt configuration\";\n\
         \t\t\tkernel = \"kernel\";\n\
         \t\t\tfdt = \"fdt\";\n\
         \t\t\tramdisk = \"ramdisk\";\n\
         \t\t}};\n\
         \t}};\n\
         }};\n",
    )
}

fn uboot_build_script(
    src: &str,
    build: &str,
    cross: &str,
    board_pkg: &str,
    base_defconfig: &str,
) -> String {
    format!(
        "#!/usr/bin/env bash\n\
         # Generated by g6lc-qemu fw build --loader u-boot.\n\
         set -euo pipefail\n\
         SRC=\"{src}\"\n\
         BUILD=\"{build}/u-boot\"\n\
         CROSS_COMPILE=\"{cross}\"\n\
         BOARD_PKG=\"{board_pkg}\"\n\
         BASE_DEFCONFIG=\"{base_defconfig}\"\n\n\
         if [ ! -f \"$SRC/Makefile\" ]; then\n\
         \techo \"U-Boot source not found at $SRC\" >&2\n\
         \texit 2\n\
         fi\n\n\
         if ! command -v \"${{CROSS_COMPILE}}gcc\" >/dev/null 2>&1; then\n\
         \techo \"RISC-V cross-toolchain not found: ${{CROSS_COMPILE}}gcc\" >&2\n\
         \texit 2\n\
         fi\n\n\
         if [ ! -f \"$SRC/configs/$BASE_DEFCONFIG\" ]; then\n\
         \techo \"Base defconfig not found: $SRC/configs/$BASE_DEFCONFIG\" >&2\n\
         \texit 2\n\
         fi\n\n\
         mkdir -p \"$BUILD\"\n\
         make -C \"$SRC\" O=\"$BUILD\" CROSS_COMPILE=\"$CROSS_COMPILE\" \"$BASE_DEFCONFIG\"\n\n\
         # Merge the generated config fragment on top of the base defconfig.\n\
         # -m: fragment only (olddefconfig runs next). -O: stay in BUILD so a\n\
         # relative SRC path does not break after cd.\n\
         if [ -x \"$SRC/scripts/kconfig/merge_config.sh\" ]; then\n\
         \tbash \"$SRC/scripts/kconfig/merge_config.sh\" -m -O \"$BUILD\" \"$BUILD/.config\" \"$BOARD_PKG/config-fragment\"\n\
         else\n\
         \tcat \"$BOARD_PKG/config-fragment\" >> \"$BUILD/.config\"\n\
         fi\n\n\
         make -C \"$BUILD\" CROSS_COMPILE=\"$CROSS_COMPILE\" olddefconfig\n\
         make -C \"$BUILD\" CROSS_COMPILE=\"$CROSS_COMPILE\" -j\"$(nproc 2>/dev/null || echo 4)\"\n\n\
         # Attempt a FIT image when mkimage is available and the expected blobs exist.\n\
         if [ -x \"$BUILD/tools/mkimage\" ] && [ -f \"$BOARD_PKG/g6lc.its\" ]; then\n\
         \t( cd \"$BUILD\" && \"$BUILD/tools/mkimage\" -f \"$BOARD_PKG/g6lc.its\" \"$BUILD/g6lc.itb\" ) || \\\n\
         \t\techo \"FIT build skipped (missing Image/initrd/dtb or mkimage errors)\"\n\
         fi\n",
    )
}

fn uboot_readme(target: &str) -> String {
    format!(
        "U-Boot U0 board package for {target}\n\
         ================================\n\n\
         This is a generated, build-only scaffolding package.\n\
         Files:\n\
         * {target}_defconfig — generated full defconfig (base + g6lc overrides).\n\
         * config-fragment — small Kconfig fragment with text/load/DRAM overrides.\n\
         * {target}.h — generated board header with DRAM and text base.\n\
         * g6lc.its — FIT source skeleton (Image/initrd/dtb placeholders).\n\
         * u-boot-build.sh — script that builds with the upstream qemu-riscv64_smode base.\n\n\
         To attempt the build:\n\
         1. g6q fw fetch --loader u-boot\n\
         2. g6q fw build --loader u-boot --target {target} --machine g6lc-virt\n\n\
         A full g6lc board Kconfig integration (MACH_G6LC, custom DTS) is not yet implemented.\n",
    )
}

// --------------------------------------------------------------------- EDK2 E0 ---

#[allow(clippy::too_many_arguments)]
fn edk2_generate_package(
    args: &Args,
    _pins: &Pins,
    model: &TargetModel,
    src: &Path,
    board_pkg: &Path,
    cross: &str,
    use_wsl: bool,
    dry_run: bool,
    missing: &mut Vec<String>,
) -> Result<Json, String> {
    let (dram_base, dram_len) = model.soc.dram.unwrap_or((0x8000_0000, 0x4000_0000));
    let target = args.value_or("target", "g6lc64_smt2");
    let machine = args.value_or("machine", "g6lc-soc");
    let harts = model.soc.harts_total.max(1);

    // E1: wrap upstream OvmfPkg/RiscVVirt (PEI-less S-mode payload for
    // OpenSBI). edk2-platforms is not required for the virt path.
    let virt_dsc = src.join("OvmfPkg/RiscVVirt/RiscVVirtQemu.dsc");
    if !dry_run {
        if !src.join("edksetup.sh").is_file() {
            missing.push(format!(
                "edk2 source not found at {}; run `fw fetch --loader edk2` first",
                src.display()
            ));
        }
        if !virt_dsc.is_file() {
            missing.push(format!(
                "upstream RiscVVirtQemu.dsc not found at {}; the pinned edk2 ref must contain OvmfPkg/RiscVVirt",
                virt_dsc.display()
            ));
        }
    }

    std::fs::create_dir_all(board_pkg.join("G6lcPlatformPkg"))
        .map_err(|e| format!("cannot create G6lcPlatformPkg dir: {e}"))?;

    let header = edk2_header(dram_base, dram_len, harts);
    let overlay = edk2_pcd_overlay(target, dram_base, dram_len, harts);
    let script = edk2_build_script(&script_path(src, use_wsl), cross);
    let readme = edk2_readme(target);
    let copied_patches = copy_edk2_patches(board_pkg)?;

    crate::write_out(
        board_pkg
            .join("G6lcPlatformPkg/G6lcPlatformPkg.h")
            .to_str()
            .unwrap(),
        &header,
    )?;
    crate::write_out(
        board_pkg
            .join("G6lcPlatformPkg/G6lcPcds.dsc.inc")
            .to_str()
            .unwrap(),
        &overlay,
    )?;
    crate::write_out(
        board_pkg
            .join(Loader::Edk2.build_script_name())
            .to_str()
            .unwrap(),
        &script,
    )?;
    crate::write_out(board_pkg.join("README.txt").to_str().unwrap(), &readme)?;

    Ok(Json::obj([
        ("loader", Json::str("edk2")),
        ("target", Json::str(target)),
        ("machine", Json::str(machine)),
        ("src", Json::str(&*script_path(src, use_wsl))),
        ("upstream_dsc", Json::str("OvmfPkg/RiscVVirt/RiscVVirtQemu.dsc")),
        ("build", Json::str(&*script_path(board_pkg.parent().unwrap_or(Path::new("out")), use_wsl))),
        ("cross_compile", Json::str(cross)),
        ("wsl", Json::str(if use_wsl { "yes" } else { "no" })),
        ("dram_base", Json::addr(dram_base)),
        ("dram_len", Json::addr(dram_len)),
        ("board_package", json_files(board_pkg)),
        (
            "command",
            Json::str(format!(
                "bash {}",
                script_path(&board_pkg.join(Loader::Edk2.build_script_name()), use_wsl)
            )),
        ),
        ("status", Json::str(if dry_run { "dry-run" } else { "planned" })),
        (
            "note",
            Json::str("E1: wrap upstream OvmfPkg/RiscVVirt/RiscVVirtQemu.dsc (PEI-less S-mode \
                       payload for OpenSBI). Generated G6lcPcds.dsc.inc records TargetModel DRAM/hart \
                       constants; the build script invokes the upstream DSC. edk2-platforms is not \
                       required for g6lc-virt. First-party patches (sstatus SIE / trap-frame) are \
                       copied into board-package/patches and applied to the official edk2 tree."),
        ),
        (
            "patches",
            Json::arr(copied_patches.iter().map(Json::str)),
        ),
    ]))
}

/// Copy `g6lc_qemu/patches/edk2-*.patch` into the generated board package.
/// Compile still uses official tianocore/edk2; these files are the patchworks.
fn copy_edk2_patches(board_pkg: &Path) -> Result<Vec<String>, String> {
    let dest = board_pkg.join("patches");
    std::fs::create_dir_all(&dest).map_err(|e| format!("cannot create {}: {e}", dest.display()))?;
    let src_dirs = [PathBuf::from("patches"), PathBuf::from("g6lc_qemu/patches")];
    let names = [
        "edk2-riscv-sstatus-no-stack.patch",
        "edk2-riscv-trap-frame-width.patch",
    ];
    let mut copied = Vec::new();
    for name in names {
        let src = src_dirs.iter().map(|d| d.join(name)).find(|p| p.is_file());
        let Some(src) = src else {
            continue;
        };
        let dst = dest.join(name);
        std::fs::copy(&src, &dst)
            .map_err(|e| format!("cannot copy {} -> {}: {e}", src.display(), dst.display()))?;
        copied.push(name.to_string());
    }
    Ok(copied)
}

fn edk2_pcd_overlay(target: &str, dram_base: u64, dram_len: u64, harts: u32) -> String {
    format!(
        "# Generated by g6lc-qemu from TargetModel ({target}).\n\
         # Record of DRAM/hart constants. RiscVVirt is PEI-less and reads the\n\
         # FDT from a1 at SEC; these values are the model the FDT must match.\n\
         # Do not hand-type CONFIG_SYS_TEXT_BASE equivalents — regenerate.\n\
         #\n\
         # G6LC_DRAM_BASE  = {dram_base:#x}\n\
         # G6LC_DRAM_SIZE  = {dram_len:#x}\n\
         # G6LC_HARTS      = {harts}\n"
    )
}

fn edk2_header(dram_base: u64, dram_len: u64, harts: u32) -> String {
    format!(
        "/* SPDX-License-Identifier: BSD-2-Clause-Patent */\n\
         /* Generated by g6lc-qemu; do not edit. */\n\
         #ifndef __G6LC_PLATFORM_PKG_H__\n\
         #define __G6LC_PLATFORM_PKG_H__\n\n\
         #define G6LC_DRAM_BASE  {dram_base:#x}ULL\n\
         #define G6LC_DRAM_SIZE  {dram_len:#x}ULL\n\
         #define G6LC_HARTS      {harts}U\n\
         #define G6LC_FLASH_BASE 0x22000000ULL\n\
         #define G6LC_FLASH_SIZE 0x02000000ULL\n\n\
         #endif\n",
    )
}

fn edk2_build_script(edk2: &str, cross: &str) -> String {
    format!(
        "#!/usr/bin/env bash\n\
         # Generated by g6lc-qemu fw build --loader edk2.\n\
         # E1: build upstream OvmfPkg/RiscVVirt/RiscVVirtQemu.dsc\n\
         # (PEI-less S-mode payload; OpenSBI fw_dynamic is the previous stage).\n\
         set -euo pipefail\n\
         WORKSPACE=\"{edk2}\"\n\
         CROSS_COMPILE=\"{cross}\"\n\
         DSC=\"OvmfPkg/RiscVVirt/RiscVVirtQemu.dsc\"\n\
         NPROC=\"$(nproc 2>/dev/null || echo 4)\"\n\n\
         export WORKSPACE\n\
         export PACKAGES_PATH=\"$WORKSPACE\"\n\
         export EDK_TOOLS_PATH=\"$WORKSPACE/BaseTools\"\n\
         export GCC5_RISCV64_PREFIX=\"$CROSS_COMPILE\"\n\
         export GCC_RISCV64_PREFIX=\"$CROSS_COMPILE\"\n\n\
         if [ ! -f \"$WORKSPACE/edksetup.sh\" ]; then\n\
         \techo \"edk2 source not found at $WORKSPACE\" >&2\n\
         \texit 2\n\
         fi\n\
         if [ ! -f \"$WORKSPACE/$DSC\" ]; then\n\
         \techo \"upstream $DSC not found in $WORKSPACE\" >&2\n\
         \texit 2\n\
         fi\n\
         if ! command -v \"${{CROSS_COMPILE}}gcc\" >/dev/null 2>&1; then\n\
         \techo \"RISC-V cross-toolchain not found: ${{CROSS_COMPILE}}gcc\" >&2\n\
         \texit 2\n\
         fi\n\
         export PATH=\"$HOME/.local/bin:$PATH\"\n\
         if ! command -v iasl >/dev/null 2>&1; then\n\
         \techo \"iasl not found; build ACPICA into \\$HOME/.local/bin (RamDiskDxe needs it)\" >&2\n\
         \texit 2\n\
         fi\n\n\
         ( cd \"$WORKSPACE\" && git submodule update --init --depth 1 )\n\
         make -C \"$WORKSPACE/BaseTools\" -j\"$NPROC\"\n\
         # shellcheck disable=SC1091\n\
         . \"$WORKSPACE/edksetup.sh\" BaseTools\n\
         # xpack `riscv-none-elf-ld` rejects `-z notext` (binutils 2.42+ flag).\n\
         # Drop it in the *generated* Conf/tools_def.txt only; do not patch edk2 source.\n\
         if [ -f \"$WORKSPACE/Conf/tools_def.txt\" ]; then\n\
         \tsed -i 's/-Wl,-z,notext//g; s/-z,notext//g; s/-z notext//g' \"$WORKSPACE/Conf/tools_def.txt\"\n\
         \t# xpack gcc PP defaults to rv32/ilp32. GCC5_RISCV64_PP_FLAGS omitted\n\
         \t# -mabi=lp64 (ASM_FLAGS has it; LoongArch PP_FLAGS already passes\n\
         \t# -mabi). __SIZEOF_POINTER__=4 made SupervisorModeTrap `addi sp,-140`\n\
         \t# against a UINT64[35] C struct (280). sret then restored garbage sepc.\n\
         \tpython3 - <<'PY'\n\
from pathlib import Path\n\
import os\n\
p = Path(os.environ['WORKSPACE']) / 'Conf' / 'tools_def.txt'\n\
t = p.read_text()\n\
abi = ' -march=rv64gc -mabi=lp64'\n\
out = []\n\
n = 0\n\
for line in t.splitlines(True):\n\
    if ('GCC5_RISCV64_PP_FLAGS' in line or 'GCC_RISCV64_PP_FLAGS' in line) and '-mabi=lp64' not in line:\n\
        line = line.rstrip('\\n\\r') + abi + '\\n'\n\
        n += 1\n\
    out.append(line)\n\
if n:\n\
    p.write_text(''.join(out))\n\
    print('tools_def PP_FLAGS +lp64', n)\n\
PY\n\
         fi\n\
         # First-party EDK2 patches (official tianocore tree + patchworks, same\n\
         # idea as g6lc_qemu/openwrt/patches). Copied next to this script.\n\
         HERE=\"$(cd \"$(dirname \"$0\")\" && pwd)\"\n\
         for f in \\\n\
         \t\"$WORKSPACE/MdePkg/Library/BaseLib/RiscV64/RiscVInterrupt.S\" \\\n\
         \t\"$WORKSPACE/UefiCpuPkg/Library/CpuExceptionHandlerLib/RiscV/ExceptionHandler.h\"; do\n\
         \t[ -f \"$f\" ] && sed -i 's/\\r$//' \"$f\"\n\
         done\n\
         shopt -s nullglob\n\
         for p in \"$HERE/patches\"/edk2-*.patch ${{G6Q_EDK2_PATCH:-}} ${{G6Q_EDK2_PATCH2:-}}; do\n\
         \t[ -f \"$p\" ] || continue\n\
         \techo \"applying $(basename \"$p\")\"\n\
         \t( cd \"$WORKSPACE\" && patch -p1 --forward --fuzz=3 --ignore-whitespace --reject-file=- < \"$p\" ) || true\n\
         done\n\
         build -a RISCV64 -t GCC5 -p \"$DSC\" -b RELEASE -n \"$NPROC\"\n\
         echo \"EDK2 E1 products under $WORKSPACE/Build/RiscVVirtQemu/RELEASE_GCC5/FV/\"\n\
         ls -l \"$WORKSPACE/Build/RiscVVirtQemu/RELEASE_GCC5/FV/\"*.fd 2>/dev/null || true\n",
    )
}

fn edk2_readme(target: &str) -> String {
    format!(
        "EDK2 E1 platform wrap for {target}\n\
         =================================\n\n\
         Wraps upstream OvmfPkg/RiscVVirt/RiscVVirtQemu.dsc (PEI-less S-mode\n\
         payload for OpenSBI fw_dynamic). edk2-platforms is not required.\n\n\
         Files:\n\
         * G6lcPlatformPkg.h — TargetModel DRAM/hart constants.\n\
         * G6lcPcds.dsc.inc — same constants as a comment overlay.\n\
         * edk2-build.sh — BaseTools + `build -p OvmfPkg/RiscVVirt/RiscVVirtQemu.dsc`.\n\
         * patches/edk2-*.patch — applied to the official edk2 tree at build\n\
           (sstatus SIE stack smash; SupervisorModeTrap frame width).\n\n\
         Products: RISCV_VIRT_CODE.fd and RISCV_VIRT_VARS.fd (32 MiB pflash).\n\
         Those FDs are a QEMU-virt witness. Variane testharness cannot boot a\n\
         pflash image; the RTL witness is verif/tests/custom/multicore/mini_edk2_sec.S.\n\n\
         1. g6q fw fetch --loader edk2\n\
         2. g6q fw build --loader edk2 --target {target} --machine g6lc-virt\n",
    )
}

// --------------------------------------------------------------------- utility ---

fn parse_hex(s: &str) -> Option<u64> {
    if s.starts_with("0x") || s.starts_with("0X") {
        u64::from_str_radix(&s[2..], 16).ok()
    } else {
        u64::from_str_radix(s, 16).ok()
    }
}

/// Pad an EDK2 FD to the QEMU virt pflash size (32 MiB) without altering the source.
pub const PFLASH_BYTES: u64 = 32 * 1024 * 1024;
/// OvmfPkg/RiscVVirt README test command uses `-m 4096`.
pub const EDK2_MIN_MEMORY_BYTES: u64 = 4 * 1024 * 1024 * 1024;
/// OpenSBI `PLATFORM=generic` with no `FW_FDT_PATH`. A g6lc-FDT
/// `fw_dynamic` hangs silent on QEMU virt (baked `example,mini-board` DTB).
pub const EDK2_GENERIC_OPENSBI: &str = "out/fw/fw_dynamic-generic-virt.bin";

fn ensure_edk2_memory(boot: &mut g6q_emit_args::BootOptions) {
    if boot.memory_bytes.unwrap_or(0) < EDK2_MIN_MEMORY_BYTES {
        boot.memory_bytes = Some(EDK2_MIN_MEMORY_BYTES);
    }
}

/// QEMU virt EDK2 must not inherit a g6lc-targeted `fw_dynamic`.
/// `--fw` still wins. Missing generic binary → QEMU's bundled OpenSBI.
fn prefer_virt_opensbi(args: &Args, boot: &mut g6q_emit_args::BootOptions) {
    if args.value("fw").is_some() {
        return;
    }
    let virt = PathBuf::from(EDK2_GENERIC_OPENSBI);
    boot.firmware = if virt.is_file() {
        g6q_emit_args::Firmware::File(virt.to_string_lossy().into_owned())
    } else {
        g6q_emit_args::Firmware::Default
    };
}

fn default_uboot_bin(args: &Args) -> PathBuf {
    let target = args.value_or("target", "g6lc64_smt2");
    let machine = if args.value("machine") == Some("g6lc-soc") {
        "g6lc-soc"
    } else {
        "g6lc-virt"
    };
    PathBuf::from(format!(
        "out/loader-build/u-boot-{target}-{machine}/u-boot/u-boot.bin"
    ))
}

fn distro_os(args: &Args) -> bool {
    matches!(
        args.value("os"),
        Some("openwrt" | "ubuntu" | "debian" | "fedora" | "buildroot")
    )
}

/// Wire `--loader u-boot` as OpenSBI's next-stage payload (`-kernel u-boot.bin`).
/// qemu-riscv64_smode TEXT_BASE is DRAM+2MiB (0x80200000), matching QEMU virt `-kernel`.
/// `--kernel` is the OS image when `--os` is a distro; U-Boot itself is `--loader-image`.
pub fn apply_uboot_payload(
    args: &Args,
    boot: &mut g6q_emit_args::BootOptions,
) -> Result<(), String> {
    if from_args(args) != Some(Loader::Uboot) {
        return Ok(());
    }
    let img = args
        .value("loader-image")
        .map(PathBuf::from)
        .or_else(|| {
            if distro_os(args) {
                None
            } else {
                args.value("kernel").map(PathBuf::from)
            }
        })
        .unwrap_or_else(|| default_uboot_bin(args));
    let dry = args.flag("dry-run") || args.value("backend") == Some("args");
    if !img.is_file() && !dry {
        return Err(format!(
            "--loader u-boot needs u-boot.bin at {} (g6q fw build --loader u-boot)",
            img.display()
        ));
    }
    boot.kernel = Some(img.to_string_lossy().replace('\\', "/"));
    prefer_virt_opensbi(args, boot);
    Ok(())
}

/// OpenWrt EFI stub + initramfs wants more than the model's 256 MiB window.
/// U-Boot qemu-riscv env also parks FDT/ramdisk above 0x8c000000 (~192 MiB).
pub const UBOOT_OPENWRT_MIN_MEMORY_BYTES: u64 = 1024 * 1024 * 1024;

fn ensure_uboot_openwrt_memory(boot: &mut g6q_emit_args::BootOptions) {
    if boot.memory_bytes.unwrap_or(0) < UBOOT_OPENWRT_MIN_MEMORY_BYTES {
        boot.memory_bytes = Some(UBOOT_OPENWRT_MIN_MEMORY_BYTES);
    }
}

/// U2: `--loader u-boot --os openwrt` keeps `-kernel u-boot.bin` and attaches a
/// partitioned FAT ESP (`EFI/BOOT/BOOTRISCV64.EFI`) on virtio-blk. Distro boot
/// (`run distro_bootcmd`) loads that PE via `bootefi`.
pub fn apply_uboot_os_esp(
    args: &Args,
    boot: &mut g6q_emit_args::BootOptions,
) -> Result<(), String> {
    if from_args(args) != Some(Loader::Uboot) {
        return Ok(());
    }
    if boot.os == "efi-shell" {
        return apply_uboot_efi_shell(args, boot);
    }
    if boot.os != "openwrt" {
        return Ok(());
    }
    // Faithful g6lc-soc has no virtio. U3-SPI places the PE/FIT on NOR.
    if args.value("machine") == Some("g6lc-soc") {
        return apply_uboot_soc_pe(args, boot);
    }
    let dry = args.flag("dry-run") || args.value("backend") == Some("args");
    let img = PathBuf::from("out/loader-run/esp-uboot.img");
    let esp = PathBuf::from("out/loader-run/esp-openwrt");
    match find_openwrt_pe(args, boot) {
        Some(pe) if pe.is_file() => {
            stage_openwrt_esp(&pe, &esp)?;
            let payload =
                std::fs::read(&pe).map_err(|e| format!("cannot read {}: {e}", pe.display()))?;
            crate::esp_fat::write_esp_disk_image(&payload, "BOOTRISCV64.EFI", &img)?;
        }
        _ if dry => {}
        _ => {
            return Err(
                "--os openwrt with --loader u-boot needs the OpenWrt EFI-stub PE at \
                 out/loader-run/openwrt/initramfs-Image (gzip -dc the \
                 *-initramfs-kernel.bin, or run g6lc_qemu/openwrt/pull-products.py)"
                    .into(),
            );
        }
    }
    if boot.drives.is_empty() {
        boot.drives.push(img.to_string_lossy().replace('\\', "/"));
    }
    boot.initrd = None;
    ensure_uboot_openwrt_memory(boot);
    Ok(())
}

/// qemu-riscv64 `kernel_addr_r`. The OpenWrt EFI stub is loaded here on g6lc-soc.
pub const UBOOT_SOC_EFI_ADDR: u64 = 0x8400_0000;

fn find_shell_efi(args: &Args) -> Option<PathBuf> {
    if let Some(k) = args.value("kernel") {
        let p = PathBuf::from(k);
        if p.is_file() {
            return Some(p);
        }
    }
    for p in [
        "out/loader-run/esp/Shell.efi",
        "out/loader-run/esp-openwrt/EFI/BOOT/BOOTRISCV64.EFI",
        "out/loader-build/edk2-g6lc64_smt2-g6lc-virt/Build/RiscVVirtQemu/RELEASE_GCC5/AARCH64/Shell.efi",
        "out/loader-build/edk2-g6lc64_smt2-g6lc-virt/Build/RiscVVirtQemu/RELEASE_GCC5/RISCV64/Shell.efi",
    ] {
        let p = PathBuf::from(p);
        if p.is_file() {
            return Some(p);
        }
    }
    None
}

/// U3-Shell: EDK2 `Shell.efi`. On `g6lc-soc` the PE is an EFI FIT on SPI NOR
/// so `bootm` uses the real size. On `g6lc-virt` it is `BOOTRISCV64.EFI` on a
/// partitioned ESP (same distro `bootefi` as U2, with a file device path).
fn apply_uboot_efi_shell(args: &Args, boot: &mut g6q_emit_args::BootOptions) -> Result<(), String> {
    let dry = args.flag("dry-run") || args.value("backend") == Some("args");
    if args.value("machine") == Some("g6lc-soc") {
        if dry {
            boot.mtd.push("out/loader-run/esp/spi-nor.img".into());
            boot.initrd = None;
            return Ok(());
        }
        match find_shell_efi(args) {
            Some(efi) if efi.is_file() => {
                let load = stage_efi_fit(&efi, "g6lc-shell", "EDK2 Shell")?;
                let mtd = stage_spi_nor_image(&load)?;
                boot.mtd.push(mtd.to_string_lossy().replace('\\', "/"));
            }
            _ => {
                return Err(
                    "--os efi-shell needs EDK2 Shell.efi at out/loader-run/esp/Shell.efi \
                     (or pass --kernel)"
                        .into(),
                );
            }
        }
        boot.initrd = None;
        return Ok(());
    }
    let img = PathBuf::from("out/loader-run/esp-shell.img");
    if dry {
        if boot.drives.is_empty() {
            boot.drives.push(img.to_string_lossy().replace('\\', "/"));
        }
        boot.initrd = None;
        ensure_uboot_openwrt_memory(boot);
        return Ok(());
    }
    match find_shell_efi(args) {
        Some(efi) if efi.is_file() => {
            let payload =
                std::fs::read(&efi).map_err(|e| format!("cannot read {}: {e}", efi.display()))?;
            crate::esp_fat::write_esp_disk_image(&payload, "BOOTRISCV64.EFI", &img)?;
        }
        _ => {
            return Err(
                "--os efi-shell needs EDK2 Shell.efi at out/loader-run/esp/Shell.efi \
                 (or pass --kernel)"
                    .into(),
            );
        }
    }
    if boot.drives.is_empty() {
        boot.drives.push(img.to_string_lossy().replace('\\', "/"));
    }
    boot.initrd = None;
    ensure_uboot_openwrt_memory(boot);
    Ok(())
}

fn apply_uboot_soc_pe(args: &Args, boot: &mut g6q_emit_args::BootOptions) -> Result<(), String> {
    let dry = args.flag("dry-run") || args.value("backend") == Some("args");
    match find_openwrt_pe(args, boot) {
        Some(pe) if pe.is_file() => {
            let load =
                stage_efi_fit(&pe, "g6lc-efi", "OpenWrt EFI stub").unwrap_or_else(|_| pe.clone());
            let dir = pe.parent().unwrap_or(Path::new("out/loader-run/openwrt"));
            if let Ok(cpio) = stage_cpuinfo_overlay_cpio(dir) {
                boot.initrd = Some(cpio.to_string_lossy().replace('\\', "/"));
            }
            if let Ok(mtd) = stage_spi_nor_image(&load) {
                boot.mtd.push(mtd.to_string_lossy().replace('\\', "/"));
            }
        }
        _ if dry => {
            boot.initrd = Some("out/loader-run/openwrt/cpuinfo-init.cpio".into());
            boot.mtd.push("out/loader-run/openwrt/spi-nor.img".into());
        }
        _ => {
            return Err(
                "--os openwrt with --loader u-boot --machine g6lc-soc needs the OpenWrt \
                 EFI-stub PE at out/loader-run/openwrt/initramfs-Image"
                    .into(),
            );
        }
    }
    Ok(())
}

fn find_mkimage() -> Option<PathBuf> {
    for p in [
        "out/loader-build/u-boot-g6lc64_smt2-g6lc-soc/u-boot/tools/mkimage",
        "out/loader-build/u-boot-g6lc64_smt2-g6lc-virt/u-boot/tools/mkimage",
    ] {
        let p = PathBuf::from(p);
        if p.is_file() {
            return Some(p);
        }
    }
    None
}

/// Userspace `/init` overlay. OpenWrt `CMDLINE_EXTEND` appends `console=hvc0`, so
/// `/dev/console` is not the UART on g6lc-soc. Print via `/dev/kmsg` (printk
/// reaches ttyS0); do not open `/dev/ttyS0` (open waits for DCD and hangs).
const CPUINFO_INIT: &str = "\
#!/bin/sh\n\
mkdir -p /proc /dev\n\
mount -t proc proc /proc 2>/dev/null\n\
[ -e /dev/kmsg ] || mknod /dev/kmsg c 1 11 2>/dev/null\n\
echo \"=== /proc/cpuinfo ===\" > /dev/kmsg\n\
cat /proc/cpuinfo > /dev/kmsg\n\
echo CPUINFO-DONE > /dev/kmsg\n\
exec /sbin/init\n";

const CPIO_NEWC_MAGIC: &[u8] = b"070701";

fn pad4(n: usize) -> usize {
    (4 - (n % 4)) % 4
}

fn push_newc_header(out: &mut Vec<u8>, ino: u32, mode: u32, nlink: u32, filesize: u32, name: &str) {
    let name_b = name.as_bytes();
    let namesize = (name_b.len() + 1) as u32;
    out.extend_from_slice(CPIO_NEWC_MAGIC);
    for v in [ino, mode, 0, 0, nlink, 0, filesize, 0, 1, 0, 0, namesize, 0] {
        out.extend_from_slice(format!("{v:08x}").as_bytes());
    }
    out.extend_from_slice(name_b);
    out.push(0);
    out.resize(out.len() + pad4(out.len()), 0);
}

/// ASCII newc archive: `init` (0755) then `TRAILER!!!`. No extra crate.
fn cpuinfo_overlay_cpio() -> Vec<u8> {
    let data = CPUINFO_INIT.as_bytes();
    let mut out = Vec::with_capacity(512);
    push_newc_header(&mut out, 1, 0o040_755, 2, 0, ".");
    push_newc_header(&mut out, 2, 0o100_755, 1, data.len() as u32, "init");
    out.extend_from_slice(data);
    out.resize(out.len() + pad4(data.len()), 0);
    push_newc_header(&mut out, 0, 0, 1, 0, "TRAILER!!!");
    out
}

/// Micron n25q256a (QEMU `n25q256a`): 512 × 64 KiB.
pub const SPI_NOR_BYTES: u64 = 32 * 1024 * 1024;

fn stage_spi_nor_image(payload: &Path) -> Result<PathBuf, String> {
    let dir = payload
        .parent()
        .unwrap_or(Path::new("out/loader-run/openwrt"));
    let img = dir.join("spi-nor.img");
    let data =
        std::fs::read(payload).map_err(|e| format!("cannot read {}: {e}", payload.display()))?;
    if data.len() as u64 > SPI_NOR_BYTES {
        return Err(format!(
            "SPI NOR payload {} is {} bytes; n25q256a is {SPI_NOR_BYTES}",
            payload.display(),
            data.len()
        ));
    }
    let mut buf = vec![0xffu8; SPI_NOR_BYTES as usize];
    buf[..data.len()].copy_from_slice(&data);
    std::fs::write(&img, &buf).map_err(|e| format!("cannot write {}: {e}", img.display()))?;
    Ok(img)
}

fn stage_cpuinfo_overlay_cpio(dir: &Path) -> Result<PathBuf, String> {
    let path = dir.join("cpuinfo-init.cpio");
    std::fs::write(&path, cpuinfo_overlay_cpio())
        .map_err(|e| format!("cannot write {}: {e}", path.display()))?;
    Ok(path)
}

/// Wrap a PE32+ EFI binary in a FIT (`os = "efi"`, `type = kernel_noload`)
/// for U-Boot `bootm`. `stem` is the `.its`/`.itb` basename in `pe`'s directory.
///
/// The cpuinfo `/init` overlay is *not* a FIT ramdisk: Linux 6.6 RISC-V
/// disables an EFI LoadFile2 initrd with `overlaps in-use memory region`.
/// QEMU `-initrd` + FDT `linux,initrd-*` is the path that survives.
fn stage_efi_fit(pe: &Path, stem: &str, description: &str) -> Result<PathBuf, String> {
    let mkimage = find_mkimage().ok_or("mkimage not found")?;
    let mkimage = std::fs::canonicalize(&mkimage)
        .map_err(|e| format!("cannot resolve {}: {e}", mkimage.display()))?;
    let dir = pe.parent().unwrap_or(Path::new("."));
    let pe_name = pe
        .file_name()
        .and_then(|s| s.to_str())
        .ok_or("EFI PE path is not UTF-8")?;
    let its_name = format!("{stem}.its");
    let itb_name = format!("{stem}.itb");
    let its = dir.join(&its_name);
    let itb = dir.join(&itb_name);
    let body = format!(
        "/dts-v1/;\n\
         \n\
         / {{\n\
         \tdescription = \"G6LC {description} FIT\";\n\
         \t#address-cells = <2>;\n\
         \t#size-cells = <2>;\n\
         \timages {{\n\
         \t\tefi {{\n\
         \t\t\tdescription = \"{description}\";\n\
         \t\t\tdata = /incbin/(\"{pe_name}\");\n\
         \t\t\ttype = \"kernel_noload\";\n\
         \t\t\tarch = \"riscv\";\n\
         \t\t\tos = \"efi\";\n\
         \t\t\tcompression = \"none\";\n\
         \t\t\tload = <0x0 0x0>;\n\
         \t\t\tentry = <0x0 0x0>;\n\
         \t\t}};\n\
         \t}};\n\
         \tconfigurations {{\n\
         \t\tdefault = \"g6lc\";\n\
         \t\tg6lc {{\n\
         \t\t\tdescription = \"g6lc-soc EFI\";\n\
         \t\t\tkernel = \"efi\";\n\
         \t\t}};\n\
         \t}};\n\
         }};\n"
    );
    std::fs::write(&its, body).map_err(|e| format!("cannot write {}: {e}", its.display()))?;
    let status = Command::new(&mkimage)
        .current_dir(dir)
        .args(["-f", &its_name, &itb_name])
        .status()
        .map_err(|e| format!("mkimage: {e}"))?;
    if !status.success() || !itb.is_file() {
        return Err(format!("mkimage failed for {}", its.display()));
    }
    Ok(itb)
}

fn default_edk2_code_fd() -> PathBuf {
    let built = PathBuf::from("out/loader-build/edk2-g6lc64_smt2-g6lc-virt/RISCV_VIRT_CODE.fd");
    if built.is_file() {
        return built;
    }
    PathBuf::from("out/loader-run/src/RISCV_VIRT_CODE.fd")
}

/// Wire `--loader edk2` pflash paths into `BootOptions`.
///
/// Dry-run accepts missing files (argv still names them). A real run copies and
/// pads CODE/VARS to 32 MiB in `out/loader-run/` so QEMU's pflash devices accept them.
pub fn apply_edk2_pflash(args: &Args, boot: &mut g6q_emit_args::BootOptions) -> Result<(), String> {
    if from_args(args) != Some(Loader::Edk2) {
        return Ok(());
    }
    let code_src = args
        .value("loader-image")
        .map(PathBuf::from)
        .unwrap_or_else(default_edk2_code_fd);
    let vars_src = args
        .value("loader-vars")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            let mut p = code_src.clone();
            p.set_file_name("RISCV_VIRT_VARS.fd");
            p
        });
    let dry = args.flag("dry-run") || args.value("backend") == Some("args");
    if dry && !code_src.is_file() {
        boot.pflash_code = Some(code_src.to_string_lossy().into_owned());
        boot.pflash_vars = Some(vars_src.to_string_lossy().into_owned());
        ensure_edk2_memory(boot);
        prefer_virt_opensbi(args, boot);
        return Ok(());
    }
    if !code_src.is_file() {
        return Err(format!(
            "--loader edk2 needs a CODE.fd at {} (pass --loader-image)",
            code_src.display()
        ));
    }
    if !vars_src.is_file() {
        return Err(format!(
            "--loader edk2 needs a VARS.fd at {} (pass --loader-vars)",
            vars_src.display()
        ));
    }
    let run_dir = PathBuf::from("out/loader-run");
    std::fs::create_dir_all(&run_dir)
        .map_err(|e| format!("cannot create {}: {e}", run_dir.display()))?;
    let code_dst = run_dir.join("RISCV_VIRT_CODE.fd");
    let vars_dst = run_dir.join("RISCV_VIRT_VARS.fd");
    pad_pflash(&code_src, &code_dst)?;
    pad_pflash(&vars_src, &vars_dst)?;
    boot.pflash_code = Some(code_dst.to_string_lossy().into_owned());
    boot.pflash_vars = Some(vars_dst.to_string_lossy().into_owned());
    ensure_edk2_memory(boot);
    prefer_virt_opensbi(args, boot);
    Ok(())
}

/// E3: `--loader edk2 --os openwrt` boots the OpenWrt EFI-stub Image from a
/// virtio ESP (`BOOTRISCV64.EFI`), not QEMU `-kernel`. Compile still uses
/// official OpenWrt + `g6lc_qemu/openwrt/patches`; this only stages the PE.
///
/// E2-PCI: `--loader edk2 --os efi-shell` keeps the FD Shell and stages a
/// virtio ESP whose `startup.nsh` runs Shell `pci` (QEMU virt GPEX root
/// complex). That is the host-side PCI witness. The AI *card* is a PCIe
/// **endpoint** (`architecture/uncore/pcie-endpoint.md`); its stand-in is
/// `ai-tensor/tools/virt_ai_card/`. Do not invent BAR sizes while
/// `contracts.ai_host_transport` is unpinned.
pub fn apply_edk2_os_esp(args: &Args, boot: &mut g6q_emit_args::BootOptions) -> Result<(), String> {
    if from_args(args) != Some(Loader::Edk2) {
        return Ok(());
    }
    if boot.os == "efi-shell" {
        return apply_edk2_pci_shell(args, boot);
    }
    if boot.os != "openwrt" {
        return Ok(());
    }
    let dry = args.flag("dry-run") || args.value("backend") == Some("args");
    let img = find_openwrt_pe(args, boot);
    let esp = PathBuf::from("out/loader-run/esp-openwrt");
    match img {
        Some(pe) if pe.is_file() => {
            stage_openwrt_esp(&pe, &esp)?;
        }
        _ if dry => {
            // Argv still names the ESP; the real run fails if the PE is missing.
        }
        _ => {
            return Err(
                "--os openwrt with --loader edk2 needs the OpenWrt EFI-stub PE at \
                 out/loader-run/openwrt/initramfs-Image (gzip -dc the \
                 *-initramfs-kernel.bin, or run g6lc_qemu/openwrt/pull-products.py)"
                    .into(),
            );
        }
    }
    if boot.drives.is_empty() {
        boot.drives.push(format!(
            "fat:rw:{}",
            esp.to_string_lossy().replace('\\', "/")
        ));
    }
    // EDK2 BDS loads FS0:\\EFI\\BOOT\\BOOTRISCV64.EFI; -kernel would skip that.
    boot.kernel = None;
    boot.initrd = None;
    Ok(())
}

const EDK2_PCI_CARD_TXT: &str = "\
stand-in: virt-ai-pcie\r\n\
tops_def: 100e12 dense INT8 ops/s peak; MAC=2 ops; no sparsity/INT4 (scaling-100tops.md s2)\r\n\
transport: contracts.ai_host_transport unpinned\r\n\
edk2: GPEX root complex; card is virt_ai_card TCP endpoint stand-in\r\n\
desc: DESC.BIN packed OP_GEMM from ingested desc_layout (m=n=k=2); not a BAR\r\n\
cap: CAP.TXT ingested island geometry + modelled peak; not a measurement\r\n\
cpl: CPL.TXT ingested completion-word bit ranges; not a BAR\r\n\
plane: PLANE.TXT island throughput vs core latency; TOPS on island\r\n\
join: JOIN.TXT ESP DESC/CPL images match the card stand-in\r\n\
roof: ROOF.TXT class vs SKU DRAM BW from ingested T; not a measurement\r\n\
queue: QUEUE.TXT ingested rings/QoS; doorbell qid 0\r\n\
ptr: PTR.TXT null ptr_*; bulk BAR4 names A/B/C; not a BAR address\r\n\
flags: FLAGS.TXT ingested irq_bit; isa-encoding s7 bit 2; dense INT8 s8s8\r\n\
ld: DESC.TXT lda/ldb packed from n,k; not a BAR\r\n\
cluster: QUEUE.TXT qid to cluster from ingested map\r\n\
sched: SCHED.TXT stand-in k vs work_quantum_k; qos from qid\r\n\
stat: STAT.TXT qid < queues; oob rejected; desc version=1\r\n\
op: OP.TXT ingested OP_GEMM; unknown ops rejected\r\n\
ctl: CTL.TXT enable; wr_cpl_en=0; disable reject; re-enable ok\r\n\
tops_not_evidence: true\r\n";

const EDK2_PCI_STARTUP_NSH: &str = "\
@echo -off\n\
echo E2-PCI-BEGIN\n\
pci\n\
echo E2-PCI-ENUM\n\
devices\n\
echo E2-PCI-DEV\n\
ls fs0:\\\n\
type fs0:\\CARD.TXT\n\
type fs0:\\CAP.TXT\n\
type fs0:\\PLANE.TXT\n\
type fs0:\\ROOF.TXT\n\
type fs0:\\QUEUE.TXT\n\
type fs0:\\SCHED.TXT\n\
type fs0:\\STAT.TXT\n\
type fs0:\\PTR.TXT\n\
type fs0:\\FLAGS.TXT\n\
type fs0:\\JOIN.TXT\n\
type fs0:\\CPL.TXT\n\
type fs0:\\CPL.HEX\n\
type fs0:\\DESC.TXT\n\
type fs0:\\CTL.TXT\n\
type fs0:\\OP.TXT\n\
type fs0:\\DESC.HEX\n\
echo E2-PCI-CARD\n";

/// E2-PCI: FD Shell + virtio ESP `startup.nsh` that runs `pci`.
/// QEMU virt is a *root complex* (GPEX). LibreCore-as-AI-card is the inverse
/// (endpoint); that path stays `virt_ai_card` until the transport pin.
fn apply_edk2_pci_shell(args: &Args, boot: &mut g6q_emit_args::BootOptions) -> Result<(), String> {
    if args.value("machine") != Some("g6lc-virt") {
        return Err(
            "--os efi-shell with --loader edk2 needs --machine g6lc-virt \
             (QEMU GPEX root complex + EDK2 PciHostBridgeDxe). g6lc-soc has no PCI. \
             The AI card endpoint stand-in is ai-tensor/tools/virt_ai_card/ \
             until contracts.ai_host_transport is pinned"
                .into(),
        );
    }
    let dry = args.flag("dry-run") || args.value("backend") == Some("args");
    let esp = PathBuf::from("out/loader-run/esp-edk2-pci");
    if !dry {
        std::fs::create_dir_all(&esp)
            .map_err(|e| format!("cannot create {}: {e}", esp.display()))?;
        std::fs::write(esp.join("startup.nsh"), EDK2_PCI_STARTUP_NSH.as_bytes())
            .map_err(|e| format!("cannot write startup.nsh: {e}"))?;
        std::fs::write(esp.join("CARD.TXT"), EDK2_PCI_CARD_TXT.as_bytes())
            .map_err(|e| format!("cannot write CARD.TXT: {e}"))?;
        let _ = stage_packed_desc_bin(&esp);
    }
    if boot.drives.is_empty() {
        boot.drives.push(format!(
            "fat:rw:{}",
            esp.to_string_lossy().replace('\\', "/")
        ));
    }
    boot.kernel = None;
    boot.initrd = None;
    // GPEX must see PCI functions, not virtio-mmio. Stock virtio-blk +
    // virtio-net (pcie-endpoint.md control plane). Hubport avoids slirp.
    boot.virtio_pci = true;
    boot.netdev_hub = true;
    Ok(())
}

/// Walk up from CWD to `pins.toml` (package root), then also try CWD and
/// `cwd/g6lc_qemu` so `g6q` works from the monorepo or the crate dir.
fn resolve_pkg_file(rel: &str) -> Option<PathBuf> {
    let mut dirs = Vec::new();
    if let Ok(cwd) = std::env::current_dir() {
        if let Some(pins) = Pins::find(&cwd) {
            if let Some(root) = pins.parent() {
                dirs.push(root.to_path_buf());
            }
        }
        dirs.push(cwd.clone());
        dirs.push(cwd.join("g6lc_qemu"));
    }
    for dir in dirs {
        let p = dir.join(rel);
        if p.is_file() {
            return Some(p);
        }
    }
    None
}

/// The paths one bridge `pack` invocation reads and writes.
///
/// Grouped rather than passed positionally: six same-typed `&str` in a row is a call site
/// where a transposed pair compiles and then writes the capability dump over the
/// descriptor.
struct BridgePackPaths<'a> {
    script: &'a str,
    model: &'a str,
    dst: &'a str,
    decode: &'a str,
    cap: &'a str,
    cpl: &'a str,
}

/// Lowercase hex, built without a `format!` per byte.
fn hex_string(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    bytes
        .iter()
        .fold(String::with_capacity(bytes.len() * 2), |mut s, b| {
            let _ = write!(s, "{b:02x}");
            s
        })
}

fn run_bridge_pack(program: &str, extra: &[&str], p: &BridgePackPaths<'_>) -> bool {
    let BridgePackPaths {
        script,
        model,
        dst,
        decode,
        cap,
        cpl,
    } = *p;
    let mut cmd = Command::new(program);
    cmd.args(extra);
    cmd.args([
        script,
        "pack",
        "--model",
        model,
        "--op",
        "OP_GEMM",
        "--set",
        "version=1",
        "--set",
        "m=2",
        "--set",
        "n=2",
        "--set",
        "k=2",
        "--out",
        dst,
        "--decode-out",
        decode,
        "--cap-out",
        cap,
        "--cpl-out",
        cpl,
    ]);
    matches!(cmd.status(), Ok(st) if st.success())
}

fn stage_packed_desc_bin(esp: &Path) -> Result<(), String> {
    let model =
        resolve_pkg_file("out/ai_soc_model.json").or_else(|| resolve_pkg_file("out/ai_model.json"));
    let Some(model) = model else {
        return Ok(());
    };
    let Some(script) = resolve_pkg_file("tools/ai_tensor_bridge.py") else {
        return Ok(());
    };
    let dst = esp.join("DESC.BIN");
    let txt = esp.join("DESC.TXT");
    let cap = esp.join("CAP.TXT");
    let cpl = esp.join("CPL.TXT");
    let script_s = script.to_string_lossy().to_string();
    let model_s = model.to_string_lossy().to_string();
    let dst_s = dst.to_string_lossy().to_string();
    let txt_s = txt.to_string_lossy().to_string();
    let cap_s = cap.to_string_lossy().to_string();
    let cpl_s = cpl.to_string_lossy().to_string();
    let paths = BridgePackPaths {
        script: &script_s,
        model: &model_s,
        dst: &dst_s,
        decode: &txt_s,
        cap: &cap_s,
        cpl: &cpl_s,
    };
    let packed = if cfg!(windows) {
        run_bridge_pack("python", &[], &paths)
            || run_bridge_pack("python3", &[], &paths)
            || run_bridge_pack("py", &["-3"], &paths)
    } else {
        run_bridge_pack("python3", &[], &paths) || run_bridge_pack("python", &[], &paths)
    } || {
        let script_w = crate::make_path_arg(&script, true).ok();
        let model_w = crate::make_path_arg(&model, true).ok();
        let dst_w = crate::make_path_arg(&dst, true).ok();
        let txt_w = crate::make_path_arg(&txt, true).ok();
        let cap_w = crate::make_path_arg(&cap, true).ok();
        let cpl_w = crate::make_path_arg(&cpl, true).ok();
        match (script_w, model_w, dst_w, txt_w, cap_w, cpl_w) {
            (Some(s), Some(m), Some(d), Some(t), Some(ca), Some(cp)) => run_bridge_pack(
                "wsl",
                &["-e", "python3"],
                &BridgePackPaths {
                    script: &s,
                    model: &m,
                    dst: &d,
                    decode: &t,
                    cap: &ca,
                    cpl: &cp,
                },
            ),
            _ => false,
        }
    };
    if packed && dst.is_file() {
        if let Ok(bytes) = std::fs::read(&dst) {
            let _ = std::fs::write(esp.join("DESC.HEX"), hex_string(&bytes).as_bytes());
        }
        let cpl_bin = esp.join("CPL.BIN");
        if let Ok(bytes) = std::fs::read(&cpl_bin) {
            let _ = std::fs::write(esp.join("CPL.HEX"), hex_string(&bytes).as_bytes());
        }
    }
    Ok(())
}

fn find_openwrt_pe(args: &Args, boot: &g6q_emit_args::BootOptions) -> Option<PathBuf> {
    // After apply_uboot_payload, boot.kernel is u-boot.bin (not a PE). Prefer
    // an explicit --kernel, then the distro-root products, and only then a
    // boot.kernel that still looks like gzip/PE32+.
    if let Some(k) = args.value("kernel") {
        let p = PathBuf::from(k);
        if p.is_file() {
            return ensure_openwrt_pe(&p).ok();
        }
    }
    let root = args
        .value("distro-root")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("out/loader-run/openwrt"));
    for name in [
        "initramfs-Image",
        "Image",
        "openwrt-sifiveu-generic-sifive_unleashed-initramfs-kernel.bin",
    ] {
        let p = root.join(name);
        if p.is_file() {
            return ensure_openwrt_pe(&p).ok();
        }
    }
    if let Some(k) = boot.kernel.as_deref() {
        let p = PathBuf::from(k);
        if p.is_file() && looks_like_pe_or_gzip(&p) {
            return ensure_openwrt_pe(&p).ok();
        }
    }
    None
}

fn looks_like_pe_or_gzip(path: &Path) -> bool {
    let mut hdr = [0u8; 2];
    if let Ok(mut f) = std::fs::File::open(path) {
        use std::io::Read;
        let _ = f.read(&mut hdr);
    }
    hdr == [0x1f, 0x8b] || hdr == [b'M', b'Z']
}

/// OpenWrt's `*-initramfs-kernel.bin` is gzip(PE32+). Leave a raw PE as-is.
fn ensure_openwrt_pe(src: &Path) -> Result<PathBuf, String> {
    let mut hdr = [0u8; 2];
    if let Ok(mut f) = std::fs::File::open(src) {
        use std::io::Read;
        let _ = f.read(&mut hdr);
    }
    if hdr != [0x1f, 0x8b] {
        return Ok(src.to_path_buf());
    }
    let dst = src.with_file_name("initramfs-Image");
    if dst.is_file() && dst != src {
        return Ok(dst);
    }
    decompress_gzip(src, &dst)?;
    Ok(dst)
}

fn decompress_gzip(src: &Path, dst: &Path) -> Result<(), String> {
    let src_s = src.to_string_lossy();
    let attempts: Vec<std::process::Command> = {
        let mut v = Vec::new();
        let mut c = Command::new("gzip");
        c.args(["-dc", src_s.as_ref()]);
        v.push(c);
        let mut w = Command::new("wsl");
        w.args(["-e", "gzip", "-dc", src_s.as_ref()]);
        v.push(w);
        v
    };
    for mut cmd in attempts {
        match cmd.output() {
            Ok(out) if out.status.success() && out.stdout.len() > 2 => {
                std::fs::write(dst, &out.stdout)
                    .map_err(|e| format!("cannot write {}: {e}", dst.display()))?;
                return Ok(());
            }
            _ => {}
        }
    }
    Err(format!(
        "cannot gunzip {} (need gzip or wsl gzip)",
        src.display()
    ))
}

fn stage_openwrt_esp(pe: &Path, esp: &Path) -> Result<(), String> {
    let bootdir = esp.join("EFI").join("BOOT");
    std::fs::create_dir_all(&bootdir)
        .map_err(|e| format!("cannot create {}: {e}", bootdir.display()))?;
    let dst = bootdir.join("BOOTRISCV64.EFI");
    std::fs::copy(pe, &dst)
        .map_err(|e| format!("cannot copy {} -> {}: {e}", pe.display(), dst.display()))?;
    std::fs::write(
        esp.join("startup.nsh"),
        b"@echo -off\necho E3-OPENWRT-EFI\nfs0:\\EFI\\BOOT\\BOOTRISCV64.EFI\n",
    )
    .map_err(|e| format!("cannot write startup.nsh: {e}"))?;
    Ok(())
}

fn pad_pflash(src: &Path, dst: &Path) -> Result<(), String> {
    std::fs::copy(src, dst).map_err(|e| format!("cannot copy {}: {e}", src.display()))?;
    let f = std::fs::OpenOptions::new()
        .write(true)
        .open(dst)
        .map_err(|e| format!("cannot pad {}: {e}", dst.display()))?;
    f.set_len(PFLASH_BYTES)
        .map_err(|e| format!("cannot set {} to 32 MiB: {e}", dst.display()))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::args::Args;

    /// Serialises the tests that stage the OpenWrt ESP.
    ///
    /// Both exercise a product path that writes the fixed `out/loader-run/esp-openwrt`
    /// tree, so running them concurrently is a file race, not a flaky assertion — on
    /// Windows the loser gets `os error 32`. The location is part of the loader's
    /// contract, so the tests are serialised rather than the product being changed to
    /// suit them.
    static ESP_OPENWRT: std::sync::Mutex<()> = std::sync::Mutex::new(());

    /// Take the ESP lock, ignoring poisoning: a panic in one test must fail that test,
    /// not cascade into every other test that touches the same directory.
    fn lock_esp() -> std::sync::MutexGuard<'static, ()> {
        ESP_OPENWRT.lock().unwrap_or_else(|e| e.into_inner())
    }

    #[test]
    fn edk2_openwrt_stages_esp_and_drops_kernel() {
        let _guard = lock_esp();
        let dir = std::env::temp_dir().join(format!("g6q-ow-pe-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let pe = dir.join("initramfs-Image");
        std::fs::write(&pe, b"MZ fake-pe").unwrap();
        let args = Args::parse([
            "run",
            "--loader",
            "edk2",
            "--os",
            "openwrt",
            "--kernel",
            pe.to_str().unwrap(),
            "--dry-run",
        ]);
        let mut boot = g6q_emit_args::BootOptions {
            os: "openwrt".into(),
            kernel: Some(pe.to_string_lossy().into_owned()),
            ..g6q_emit_args::BootOptions::default()
        };
        apply_edk2_os_esp(&args, &mut boot).unwrap();
        assert!(boot.kernel.is_none(), "EDK2 path must not pass -kernel");
        assert!(
            boot.drives.iter().any(|d| d.contains("esp-openwrt")),
            "expected fat ESP drive, got {:?}",
            boot.drives
        );
        assert!(Path::new("out/loader-run/esp-openwrt/EFI/BOOT/BOOTRISCV64.EFI").is_file());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn edk2_efi_shell_on_virt_stages_pci_startup_nsh() {
        let args = Args::parse([
            "run",
            "--loader",
            "edk2",
            "--os",
            "efi-shell",
            "--machine",
            "g6lc-virt",
            "--dry-run",
        ]);
        let mut boot = g6q_emit_args::BootOptions {
            os: "efi-shell".into(),
            ..g6q_emit_args::BootOptions::default()
        };
        apply_edk2_os_esp(&args, &mut boot).unwrap();
        assert!(boot.kernel.is_none());
        assert!(
            boot.drives.iter().any(|d| d.contains("esp-edk2-pci")),
            "expected EDK2 PCI ESP, got {:?}",
            boot.drives
        );
        assert!(boot.virtio_pci, "EDK2 PCI enum needs virtio-blk-pci");
        assert!(!boot.netdev_user, "do not require slirp user netdev");
        assert!(boot.netdev_hub, "EDK2 PCI net uses hubport, not slirp");
        assert!(EDK2_PCI_STARTUP_NSH.contains("type fs0:\\CARD.TXT"));
        assert!(EDK2_PCI_STARTUP_NSH.contains("type fs0:\\CAP.TXT"));
        assert!(EDK2_PCI_STARTUP_NSH.contains("type fs0:\\PLANE.TXT"));
        assert!(EDK2_PCI_STARTUP_NSH.contains("type fs0:\\ROOF.TXT"));
        assert!(EDK2_PCI_STARTUP_NSH.contains("type fs0:\\QUEUE.TXT"));
        assert!(EDK2_PCI_STARTUP_NSH.contains("type fs0:\\SCHED.TXT"));
        assert!(EDK2_PCI_STARTUP_NSH.contains("type fs0:\\STAT.TXT"));
        assert!(EDK2_PCI_STARTUP_NSH.contains("type fs0:\\PTR.TXT"));
        assert!(EDK2_PCI_STARTUP_NSH.contains("type fs0:\\FLAGS.TXT"));
        assert!(EDK2_PCI_STARTUP_NSH.contains("type fs0:\\JOIN.TXT"));
        assert!(EDK2_PCI_STARTUP_NSH.contains("type fs0:\\CPL.TXT"));
        assert!(EDK2_PCI_STARTUP_NSH.contains("type fs0:\\CPL.HEX"));
        assert!(EDK2_PCI_STARTUP_NSH.contains("type fs0:\\DESC.TXT"));
        assert!(EDK2_PCI_STARTUP_NSH.contains("type fs0:\\CTL.TXT"));
        assert!(EDK2_PCI_STARTUP_NSH.contains("type fs0:\\OP.TXT"));
        assert!(EDK2_PCI_STARTUP_NSH.contains("type fs0:\\DESC.HEX"));
        assert!(EDK2_PCI_STARTUP_NSH.contains("ls fs0:\\"));
        assert!(EDK2_PCI_CARD_TXT.contains("100e12"));
        assert!(EDK2_PCI_CARD_TXT.contains("virt-ai-pcie"));
        assert!(EDK2_PCI_CARD_TXT.contains("DESC.BIN"));
        assert!(EDK2_PCI_CARD_TXT.contains("CAP.TXT"));
        assert!(EDK2_PCI_CARD_TXT.contains("CPL.TXT"));
        assert!(EDK2_PCI_CARD_TXT.contains("PLANE.TXT"));
        assert!(EDK2_PCI_CARD_TXT.contains("JOIN.TXT"));
        assert!(EDK2_PCI_CARD_TXT.contains("ROOF.TXT"));
        assert!(EDK2_PCI_CARD_TXT.contains("QUEUE.TXT"));
        assert!(EDK2_PCI_CARD_TXT.contains("PTR.TXT"));
        assert!(EDK2_PCI_CARD_TXT.contains("FLAGS.TXT"));
        assert!(EDK2_PCI_CARD_TXT.contains("lda/ldb"));
        assert!(EDK2_PCI_CARD_TXT.contains("cluster"));
        assert!(EDK2_PCI_CARD_TXT.contains("SCHED.TXT"));
        assert!(EDK2_PCI_CARD_TXT.contains("STAT.TXT"));
        assert!(EDK2_PCI_CARD_TXT.contains("OP.TXT"));
        assert!(EDK2_PCI_CARD_TXT.contains("CTL.TXT"));
        assert!(EDK2_PCI_CARD_TXT.contains("not a BAR"));
    }

    #[test]
    fn edk2_pci_esp_stages_packed_desc_when_model_exists() {
        let Some(model) = resolve_pkg_file("out/ai_soc_model.json")
            .or_else(|| resolve_pkg_file("out/ai_model.json"))
        else {
            return;
        };
        if resolve_pkg_file("tools/ai_tensor_bridge.py").is_none() {
            return;
        }
        let tmp = std::env::temp_dir().join(format!("g6q-edk2-desc-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();
        stage_packed_desc_bin(&tmp).unwrap();
        let bin = tmp.join("DESC.BIN");
        assert!(
            bin.is_file(),
            "pack DESC.BIN from {} via ai_tensor_bridge.py",
            model.display()
        );
        let bytes = std::fs::read(&bin).unwrap();
        assert!(
            bytes.len() >= 16,
            "descriptor too small: {} bytes",
            bytes.len()
        );
        // version=1, op=OP_GEMM=1, little-endian at the model's offsets 0 and 2.
        assert_eq!(&bytes[0..4], &[0x01, 0x00, 0x01, 0x00]);
        // flags[2] raise IRQ (isa-encoding.md §7 / ingested irq_bit).
        assert_eq!(&bytes[4..8], &[0x04, 0x00, 0x00, 0x00]);
        // ld_ab = k | (n << 16) = 2 | (2 << 16) at ingested offset 20.
        assert!(
            bytes.len() >= 24,
            "descriptor missing ld_ab: {} bytes",
            bytes.len()
        );
        assert_eq!(&bytes[20..24], &[0x02, 0x00, 0x02, 0x00]);
        let hex = std::fs::read_to_string(tmp.join("DESC.HEX")).unwrap();
        assert!(hex.starts_with("01000100"), "DESC.HEX={hex}");
        let txt = std::fs::read_to_string(tmp.join("DESC.TXT")).unwrap();
        assert!(txt.contains("OP_GEMM"), "DESC.TXT={txt}");
        assert!(txt.contains("m=2"), "DESC.TXT={txt}");
        assert!(txt.contains("lda=2"), "DESC.TXT={txt}");
        assert!(txt.contains("ld_ab_ok=true"), "DESC.TXT={txt}");
        let cap = std::fs::read_to_string(tmp.join("CAP.TXT")).unwrap();
        assert!(cap.contains("tops_not_evidence=true"), "CAP.TXT={cap}");
        assert!(
            cap.contains("macs_per_cycle=") || cap.contains("clusters="),
            "CAP.TXT={cap}"
        );
        assert!(
            cap.contains("class_need_macs_per_cycle=") || cap.contains("class_def_tops=100"),
            "CAP.TXT={cap}"
        );
        let cpl = std::fs::read_to_string(tmp.join("CPL.TXT")).unwrap();
        assert!(cpl.contains("layout=completion"), "CPL.TXT={cpl}");
        assert!(
            cpl.contains("ticket_bit") || cpl.contains("st_ok="),
            "CPL.TXT={cpl}"
        );
        let cpl_bin = tmp.join("CPL.BIN");
        assert!(cpl_bin.is_file(), "CPL.BIN next to CPL.TXT");
        let cpl_bytes = std::fs::read(&cpl_bin).unwrap();
        assert!(cpl_bytes.len() >= 8, "completion word too small");
        assert_eq!(cpl_bytes[0], 1, "example ticket=1 little-endian");
        let cpl_hex = std::fs::read_to_string(tmp.join("CPL.HEX")).unwrap();
        assert!(cpl_hex.starts_with("01"), "CPL.HEX={cpl_hex}");
        assert!(cpl.contains("example_hex="), "CPL.TXT={cpl}");
        let plane = std::fs::read_to_string(tmp.join("PLANE.TXT")).unwrap();
        assert!(plane.contains("split=two_plane"), "PLANE.TXT={plane}");
        assert!(plane.contains("tops_on=island"), "PLANE.TXT={plane}");
        assert!(plane.contains("core_plane=latency"), "PLANE.TXT={plane}");
        let join = std::fs::read_to_string(tmp.join("JOIN.TXT")).unwrap();
        assert!(join.contains("join=firmware_and_card"), "JOIN.TXT={join}");
        assert!(join.contains("irq=wait_then_claim_done"), "JOIN.TXT={join}");
        assert!(join.contains("desc_sha256="), "JOIN.TXT={join}");
        let roof = std::fs::read_to_string(tmp.join("ROOF.TXT")).unwrap();
        assert!(roof.contains("tops_not_evidence=true"), "ROOF.TXT={roof}");
        assert!(
            roof.contains("blocking_t=") || roof.contains("class_dram_gbps="),
            "ROOF.TXT={roof}"
        );
        let queue = std::fs::read_to_string(tmp.join("QUEUE.TXT")).unwrap();
        assert!(queue.contains("window=queues"), "QUEUE.TXT={queue}");
        assert!(
            queue.contains("doorbell_qid=0") || queue.contains("queues="),
            "QUEUE.TXT={queue}"
        );
        assert!(
            queue.contains("doorbell_qid_last=") || queue.contains("queue_depth="),
            "QUEUE.TXT={queue}"
        );
        assert!(
            queue.contains("cluster_from_map=true") || queue.contains("qid0_cluster="),
            "QUEUE.TXT={queue}"
        );
        assert!(
            queue.contains("qos_from_qid=true") || queue.contains("qid0_qos="),
            "QUEUE.TXT={queue}"
        );
        let sched = std::fs::read_to_string(tmp.join("SCHED.TXT")).unwrap();
        assert!(sched.contains("within_quantum=true"), "SCHED.TXT={sched}");
        assert!(sched.contains("standin_k=2"), "SCHED.TXT={sched}");
        let stat = std::fs::read_to_string(tmp.join("STAT.TXT")).unwrap();
        assert!(stat.contains("qid_bound=true"), "STAT.TXT={stat}");
        assert!(stat.contains("oob_rejected=true"), "STAT.TXT={stat}");
        assert!(stat.contains("version_ok=true"), "STAT.TXT={stat}");
        let op = std::fs::read_to_string(tmp.join("OP.TXT")).unwrap();
        assert!(op.contains("op_ok=true"), "OP.TXT={op}");
        assert!(op.contains("OP_GEMM=1"), "OP.TXT={op}");
        let ctl = std::fs::read_to_string(tmp.join("CTL.TXT")).unwrap();
        assert!(ctl.contains("wr_cpl_en=0"), "CTL.TXT={ctl}");
        assert!(ctl.contains("disabled_rejected=true"), "CTL.TXT={ctl}");
        assert!(ctl.contains("reenable_ok=true"), "CTL.TXT={ctl}");
        let ptr = std::fs::read_to_string(tmp.join("PTR.TXT")).unwrap();
        assert!(ptr.contains("ptr_null=true"), "PTR.TXT={ptr}");
        assert!(ptr.contains("bar4_a=A"), "PTR.TXT={ptr}");
        assert!(ptr.contains("ptr_done_path=mmio_cpl"), "PTR.TXT={ptr}");
        assert!(
            !ptr.contains("0x9000"),
            "PTR.TXT must not invent DRAM addrs: {ptr}"
        );
        let flags = std::fs::read_to_string(tmp.join("FLAGS.TXT")).unwrap();
        assert!(flags.contains("irq_bit=2"), "FLAGS.TXT={flags}");
        assert!(flags.contains("irq_bit_ok=true"), "FLAGS.TXT={flags}");
        assert!(flags.contains("dtype_s8s8=true"), "FLAGS.TXT={flags}");
        assert!(
            flags.contains("int4_not_in_headline=true"),
            "FLAGS.TXT={flags}"
        );
        assert!(flags.contains("fence_clear=true"), "FLAGS.TXT={flags}");
        assert!(flags.contains("priority_default=true"), "FLAGS.TXT={flags}");
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn edk2_efi_shell_rejects_g6lc_soc() {
        let args = Args::parse([
            "run",
            "--loader",
            "edk2",
            "--os",
            "efi-shell",
            "--machine",
            "g6lc-soc",
            "--dry-run",
        ]);
        let mut boot = g6q_emit_args::BootOptions {
            os: "efi-shell".into(),
            ..g6q_emit_args::BootOptions::default()
        };
        let err = apply_edk2_os_esp(&args, &mut boot).unwrap_err();
        assert!(
            err.contains("g6lc-virt"),
            "expected virt-only PCI error, got {err}"
        );
    }

    #[test]
    fn uboot_payload_sets_kernel_and_generic_opensbi_on_dry_run() {
        let args = Args::parse([
            "run",
            "--loader",
            "u-boot",
            "--dry-run",
            "--loader-image",
            "out/u-boot.bin",
        ]);
        let mut boot = g6q_emit_args::BootOptions::default();
        apply_uboot_payload(&args, &mut boot).unwrap();
        assert_eq!(boot.kernel.as_deref(), Some("out/u-boot.bin"));
    }

    #[test]
    fn uboot_openwrt_on_g6lc_soc_skips_virtio_esp() {
        let args = Args::parse([
            "run",
            "--loader",
            "u-boot",
            "--os",
            "openwrt",
            "--machine",
            "g6lc-soc",
            "--dry-run",
        ]);
        let mut boot = g6q_emit_args::BootOptions {
            os: "openwrt".into(),
            ..g6q_emit_args::BootOptions::default()
        };
        apply_uboot_os_esp(&args, &mut boot).unwrap();
        assert!(boot.drives.is_empty());
        assert!(
            boot.mem_loads.is_empty(),
            "U3-SPI boots from NOR, not a DRAM loader: {:?}",
            boot.mem_loads
        );
        assert!(
            boot.initrd
                .as_deref()
                .is_some_and(|p| p.contains("cpuinfo-init.cpio")),
            "expected cpuinfo overlay initrd, got {:?}",
            boot.initrd
        );
        assert!(
            boot.mtd.iter().any(|p| p.contains("spi-nor.img")),
            "expected SPI NOR image, got {:?}",
            boot.mtd
        );
    }

    #[test]
    fn uboot_efi_shell_on_g6lc_soc_stages_mtd_not_virtio() {
        let args = Args::parse([
            "run",
            "--loader",
            "u-boot",
            "--os",
            "efi-shell",
            "--machine",
            "g6lc-soc",
            "--dry-run",
        ]);
        let mut boot = g6q_emit_args::BootOptions {
            os: "efi-shell".into(),
            ..g6q_emit_args::BootOptions::default()
        };
        apply_uboot_os_esp(&args, &mut boot).unwrap();
        assert!(boot.drives.is_empty());
        assert!(boot.mem_loads.is_empty());
        assert!(boot.initrd.is_none());
        assert!(
            boot.mtd.iter().any(|p| p.contains("spi-nor.img")),
            "expected Shell FIT on SPI NOR, got {:?}",
            boot.mtd
        );
    }

    #[test]
    fn uboot_efi_shell_on_virt_stages_esp_not_mtd() {
        let args = Args::parse([
            "run",
            "--loader",
            "u-boot",
            "--os",
            "efi-shell",
            "--machine",
            "g6lc-virt",
            "--dry-run",
        ]);
        let mut boot = g6q_emit_args::BootOptions {
            os: "efi-shell".into(),
            ..g6q_emit_args::BootOptions::default()
        };
        apply_uboot_os_esp(&args, &mut boot).unwrap();
        assert!(
            boot.mtd.is_empty(),
            "virt Shell uses ESP not NOR: {:?}",
            boot.mtd
        );
        assert!(
            boot.drives.iter().any(|p| p.contains("esp-shell.img")),
            "expected Shell ESP, got {:?}",
            boot.drives
        );
        assert!(boot.initrd.is_none());
    }

    #[test]
    fn soc_bootcommand_serial_only_and_hello_fallback() {
        let s = uboot_config_fragment(0x8020_0000, 0x8000_0000, 0x1000_0000, "g6lc-soc");
        assert!(s.contains("setenv stdout serial"), "{s}");
        assert!(s.contains("setenv bootargs"), "{s}");
        assert!(s.contains("bootefi hello"), "{s}");
        assert!(s.contains("HELLO-EFI"), "{s}");
        assert!(s.contains("bootm 0x84000000"), "{s}");
    }

    #[test]
    fn cpuinfo_overlay_cpio_is_newc_with_init() {
        let blob = cpuinfo_overlay_cpio();
        assert!(blob.starts_with(CPIO_NEWC_MAGIC));
        let s = String::from_utf8_lossy(&blob);
        assert!(s.contains("init\0") || s.contains("init"), "{s:?}");
        assert!(s.contains("TRAILER!!!"));
        assert!(s.contains("CPUINFO-DONE"));
        assert!(s.contains("#!/bin/sh"));
        assert_eq!(blob.len() % 4, 0);
    }

    #[test]
    fn uboot_openwrt_keeps_uboot_kernel_and_attaches_esp_img() {
        let _guard = lock_esp();
        let dir = std::env::temp_dir().join(format!("g6q-uboot-ow-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let pe = dir.join("initramfs-Image");
        std::fs::write(&pe, b"MZ uboot-openwrt-pe").unwrap();
        let args = Args::parse([
            "run",
            "--loader",
            "u-boot",
            "--os",
            "openwrt",
            "--kernel",
            pe.to_str().unwrap(),
            "--loader-image",
            "out/u-boot.bin",
            "--dry-run",
        ]);
        let mut boot = g6q_emit_args::BootOptions {
            os: "openwrt".into(),
            kernel: Some(pe.to_string_lossy().into_owned()),
            ..g6q_emit_args::BootOptions::default()
        };
        apply_uboot_os_esp(&args, &mut boot).unwrap();
        apply_uboot_payload(&args, &mut boot).unwrap();
        assert_eq!(boot.kernel.as_deref(), Some("out/u-boot.bin"));
        assert!(boot.initrd.is_none());
        assert!(
            boot.drives.iter().any(|d| d.contains("esp-uboot.img")),
            "expected partitioned ESP image, got {:?}",
            boot.drives
        );
        assert_eq!(boot.memory_bytes, Some(UBOOT_OPENWRT_MIN_MEMORY_BYTES));
        let img = Path::new("out/loader-run/esp-uboot.img");
        assert!(img.is_file(), "missing {}", img.display());
        let bytes = std::fs::read(img).unwrap();
        assert_eq!(&bytes[0x1FE..0x200], &[0x55, 0xAA]);
        assert!(bytes.windows(19).any(|w| w == b"MZ uboot-openwrt-pe"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
