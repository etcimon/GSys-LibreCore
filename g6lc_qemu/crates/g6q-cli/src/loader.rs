// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// loader.rs — U-Boot / EDK2 build-only scaffolding for `g6lc-qemu fw`.
//
// U0/E0 are build-time gates: this module clones pinned upstream source, generates a
// target-specific board package from `TargetModel`, and attempts the loader build. It is
// intentionally not a full port; it writes the scaffolding and a build script, reports
// what is missing, and never claims green when the host cannot run the build.

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

    let config_fragment = uboot_config_fragment(text_base, dram_base, dram_len);
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

fn uboot_config_fragment(text_base: u64, dram_base: u64, dram_len: u64) -> String {
    format!(
        "# Generated config fragment for g6lc_qemu U-Boot build\n\
         CONFIG_SYS_TEXT_BASE={text_base:#x}\n\
         CONFIG_SYS_LOAD_ADDR={text_base:#x}\n\
         CONFIG_NR_DRAM_BANKS=1\n\
         CONFIG_SYS_SDRAM_BASE={dram_base:#x}\n\
         CONFIG_SYS_BOOTMAPSZ={dram_len:#x}\n",
    )
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
         if [ -x \"$SRC/scripts/kconfig/merge_config.sh\" ]; then\n\
         \t( cd \"$BUILD\" && bash \"$SRC/scripts/kconfig/merge_config.sh\" \".config\" \"$BOARD_PKG/config-fragment\" )\n\
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

    let platforms_src = if dry_run {
        PathBuf::from("out/loader-src/edk2-platforms")
    } else {
        // EDK2 source is the `edk2` repo; platforms live in `edk2-platforms`.
        src.with_file_name("edk2-platforms")
    };

    if !dry_run {
        if !src.join("edksetup.sh").is_file() {
            missing.push(format!(
                "edk2 source not found at {}; run `fw fetch --loader edk2` first",
                src.display()
            ));
        }
        if !platforms_src.is_dir() {
            missing.push(format!(
                "edk2-platforms source not found at {}; run `fw fetch --loader edk2` first",
                platforms_src.display()
            ));
        }
    }

    std::fs::create_dir_all(board_pkg.join("G6lcPlatformPkg"))
        .map_err(|e| format!("cannot create G6lcPlatformPkg dir: {e}"))?;

    let dec = edk2_dec(dram_base, dram_len);
    let dsc = edk2_dsc(target, dram_base, dram_len);
    let fdf = edk2_fdf(dram_base, dram_len);
    let header = edk2_header(dram_base, dram_len);
    let script = edk2_build_script(
        &script_path(src, use_wsl),
        &script_path(&platforms_src, use_wsl),
        &script_path(board_pkg, use_wsl),
        cross,
    );
    let readme = edk2_readme(target);

    crate::write_out(
        board_pkg
            .join("G6lcPlatformPkg/G6lcPlatformPkg.dec")
            .to_str()
            .unwrap(),
        &dec,
    )?;
    crate::write_out(
        board_pkg
            .join("G6lcPlatformPkg/G6lcPlatformPkg.dsc")
            .to_str()
            .unwrap(),
        &dsc,
    )?;
    crate::write_out(
        board_pkg
            .join("G6lcPlatformPkg/G6lcPlatformPkg.fdf")
            .to_str()
            .unwrap(),
        &fdf,
    )?;
    crate::write_out(
        board_pkg
            .join("G6lcPlatformPkg/G6lcPlatformPkg.h")
            .to_str()
            .unwrap(),
        &header,
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
        ("edk2_platforms", Json::str(&*script_path(&platforms_src, use_wsl))),
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
            Json::str("E0 scaffolding: a generated EDK2 platform package (DEC/DSC/FDF/h) and build script. \
                       This is not a complete, buildable RISC-V platform; the BaseTools, submodules, \
                       and RiscVPlatformPkg integration are missing."),
        ),
    ]))
}

fn edk2_dec(dram_base: u64, dram_len: u64) -> String {
    format!(
        "[Defines]\n\
         DEC_SPECIFICATION = 0x00010005\n\
         PACKAGE_NAME = G6lcPlatformPkg\n\
         PACKAGE_GUID = 6C1B2A3C-4D5E-6F7A-8B9C-0D1E2F3A4B5C\n\
         PACKAGE_VERSION = 0.1\n\n\
         [Guids]\n\
         gG6lcPlatformPkgTokenSpaceGuid = {{ 0x6C1B2A3C, 0x4D5E, 0x6F7A, {{ 0x8B, 0x9C, 0x0D, 0x1E, 0x2F, 0x3A, 0x4B, 0x5C }} }}\n\n\
         [PcdsFixedAtBuild]\n\
         gG6lcPlatformPkgTokenSpaceGuid.PcdSystemMemoryBase|{dram_base:#x}|UINT64|0x00000001\n\
         gG6lcPlatformPkgTokenSpaceGuid.PcdSystemMemorySize|{dram_len:#x}|UINT64|0x00000002\n\
         gG6lcPlatformPkgTokenSpaceGuid.PcdFlashBase|0x22000000|UINT64|0x00000003\n",
    )
}

fn edk2_dsc(target: &str, dram_base: u64, dram_len: u64) -> String {
    format!(
        "[Defines]\n\
         PLATFORM_NAME = G6lc{target}\n\
         PLATFORM_GUID = 6C1B2A3C-4D5E-6F7A-8B9C-0D1E2F3A4B5D\n\
         PLATFORM_VERSION = 0.1\n\
         DSC_SPECIFICATION = 0x00010005\n\
         OUTPUT_DIRECTORY = Build/G6lc{target}\n\
         SUPPORTED_ARCHITECTURES = RISCV64\n\
         BUILD_TARGETS = RELEASE|DEBUG\n\
         SKUID_IDENTIFIER = DEFAULT\n\
         FLASH_DEFINITION = G6lcPlatformPkg.fdf\n\n\
         [PcdsFixedAtBuild]\n\
         gG6lcPlatformPkgTokenSpaceGuid.PcdSystemMemoryBase|{dram_base:#x}\n\
         gG6lcPlatformPkgTokenSpaceGuid.PcdSystemMemorySize|{dram_len:#x}\n\n\
         [LibraryClasses]\n\
         PcdLib|MdePkg/Library/BasePcdLibNull/BasePcdLibNull.inf\n\
         BaseLib|MdePkg/Library/BaseLib/BaseLib.inf\n\
         UefiBootServicesTableLib|MdePkg/Library/UefiBootServicesTableLib/UefiBootServicesTableLib.inf\n\
         UefiRuntimeServicesTableLib|MdePkg/Library/UefiRuntimeServicesTableLib/UefiRuntimeServicesTableLib.inf\n\
         RiscVPlatformLib|RiscVPlatformPkg/Library/RiscVPlatformLib/RiscVPlatformLib.inf\n\n\
         [Components]\n\
         # Placeholder: a real g6lc platform needs a SEC, PEI, DXE core, and BDS.\n\
         # MdeModulePkg/Core/Dxe/DxeMain.inf\n\
         # MdeModulePkg/Universal/PCD/Pei/Pcd.inf\n",
    )
}

fn edk2_fdf(dram_base: u64, dram_len: u64) -> String {
    let fv_base = dram_base + 0x200000;
    format!(
        "[Defines]\n\
         FDF_SPECIFICATION = 0x00010005\n\n\
         [FD.G6lc]\n\
         BaseAddress = {dram_base:#x}|RISCV64\n\
         Size = {dram_len:#x}\n\
         ErasePolarity = 1\n\
         BlockSize = 0x1000\n\
         NumBlocks = {blocks:#x}\n\n\
         [FV.FVMAIN]\n\
         FvNameGuid = 6C1B2A3C-4D5E-6F7A-8B9C-0D1E2F3A4B5E\n\
         BlockSize = 0x1000\n\
         FvBaseAddress = {fv_base:#x}\n\
         FvSize = 0x200000\n\n\
         # Placeholder: add SEC, PEI, DXE, and BDS modules here.\n",
        blocks = dram_len / 0x1000,
    )
}

fn edk2_header(dram_base: u64, dram_len: u64) -> String {
    format!(
        "/* SPDX-License-Identifier: BSD-2-Clause-Patent */\n\
         /* Generated by g6lc-qemu; do not edit. */\n\
         #ifndef __G6LC_PLATFORM_PKG_H__\n\
         #define __G6LC_PLATFORM_PKG_H__\n\n\
         #define G6LC_DRAM_BASE  {dram_base:#x}ULL\n\
         #define G6LC_DRAM_SIZE  {dram_len:#x}ULL\n\
         #define G6LC_FLASH_BASE 0x22000000ULL\n\
         #define G6LC_FLASH_SIZE 0x00400000ULL\n\n\
         #endif\n",
    )
}

fn edk2_build_script(edk2: &str, platforms: &str, board_pkg: &str, cross: &str) -> String {
    format!(
        "#!/usr/bin/env bash\n\
         # Generated by g6lc-qemu fw build --loader edk2.\n\
         set -euo pipefail\n\
         WORKSPACE=\"{edk2}\"\n\
         EDK2_PLATFORMS=\"{platforms}\"\n\
         BOARD_PKG=\"{board_pkg}\"\n\
         CROSS_COMPILE=\"{cross}\"\n\n\
         export WORKSPACE\n\
         export EDK_TOOLS_PATH=\"$WORKSPACE/BaseTools\"\n\
         export PACKAGES_PATH=\"$WORKSPACE:$EDK2_PLATFORMS\"\n\
         export GCC5_RISCV64_PREFIX=\"$CROSS_COMPILE\"\n\n\
         if [ ! -f \"$WORKSPACE/edksetup.sh\" ]; then\n\
         \techo \"edk2 source not found at $WORKSPACE\" >&2\n\
         \texit 2\n\
         fi\n\
         if [ ! -d \"$EDK2_PLATFORMS\" ]; then\n\
         \techo \"edk2-platforms source not found at $EDK2_PLATFORMS\" >&2\n\
         \texit 2\n\
         fi\n\
         if ! command -v \"${{CROSS_COMPILE}}gcc\" >/dev/null 2>&1; then\n\
         \techo \"RISC-V cross-toolchain not found: ${{CROSS_COMPILE}}gcc\" >&2\n\
         \texit 2\n\
         fi\n\n\
         # Initialise edk2 submodules (CryptoPkg, etc.) and BaseTools.\n\
         ( cd \"$WORKSPACE\" && git submodule update --init --recursive )\n\
         make -C \"$WORKSPACE/BaseTools\" -j\"$(nproc 2>/dev/null || echo 4)\"\n\n\
         # Stage the generated platform package.\n\
         mkdir -p \"$EDK2_PLATFORMS/Platform/G6lc\"\n\
         cp -r \"$BOARD_PKG/G6lcPlatformPkg\" \"$EDK2_PLATFORMS/Platform/G6lc/\"\n\n\
         # Setup the build environment.\n\
         . \"$WORKSPACE/edksetup.sh\"\n\n\
         # Attempt the build. This is expected to fail in E0 because the\n\
         # RISC-V platform (SEC/PEI/DXE/BDS) is not yet wired.\n\
         build -a RISCV64 -t GCC5 -p \"$EDK2_PLATFORMS/Platform/G6lc/G6lcPlatformPkg/G6lcPlatformPkg.dsc\" -b RELEASE -n \"$(nproc 2>/dev/null || echo 4)\"\n",
    )
}

fn edk2_readme(target: &str) -> String {
    format!(
        "EDK2 E0 platform package for {target}\n\
         ===================================\n\n\
         This is a generated, build-only scaffolding package.\n\
         Files:\n\
         * G6lcPlatformPkg.dec — package declaration and PCDs.\n\
         * G6lcPlatformPkg.dsc — platform description (library classes, components).\n\
         * G6lcPlatformPkg.fdf — flash device layout.\n\
         * G6lcPlatformPkg.h — generated memory/flash constants.\n\
         * build-edk2.sh — script that stages the package and calls `build`.\n\n\
         To attempt the build:\n\
         1. g6q fw fetch --loader edk2\n\
         2. g6q fw build --loader edk2 --target {target} --machine g6lc-virt\n\n\
         The platform is not complete: BaseTools, submodules, and RiscVPlatformPkg/DXE/BDS\n\
         integration are missing and expected to fail in E0.\n",
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
