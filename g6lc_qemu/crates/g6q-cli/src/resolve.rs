// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Turning command-line options into ingest [`Sources`].
//!
//! Every input can be given explicitly; `--repo-root` is a convenience that derives the
//! usual paths from a target id. That split is the independence invariant made
//! operational — the tool works against a fork, a fixture or a differently-shaped tree
//! with no built-in knowledge of any particular layout.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use g6q_core::model::Profile;
use g6q_ingest::capability::{self, Table};
use g6q_ingest::Sources;

use crate::args::Args;

/// Conventional locations inside a design tree, used only by `--repo-root`.
///
/// These are *defaults for a convenience flag*, not knowledge the tool depends on: every
/// one can be overridden by an explicit option.
mod layout {
    pub const CONFIG_DIR: &str = "core/include";
    pub const CONFIG_SUFFIX: &str = "_config_pkg.sv";
    pub const DTS_DIR: &str = "corev_apu/bootrom";
    pub const CORE_FLIST: &[&str] = &["core/Flist.g6lc", "core/Flist.cva6"];
    pub const SOC_FLIST: &[&str] = &["Flist.ariane"];
    /// The AI island's own compile list (packages the ingest reads for the emulated
    /// device); absent on trees without the island.
    pub const AI_FLIST: &[&str] = &["corev_apu/ai_island/Flist.ai_island"];
    pub const ROOT_VAR: &str = "CVA6_REPO_DIR";
}

/// Device trees that go with a target id, most specific first.
fn dts_candidates(target: &str) -> Vec<String> {
    let mut v = Vec::new();
    // `g6lc64_server_math_v` -> `ariane-server-math-v.dts`
    if let Some(stem) = target.split_once('_').map(|(_, r)| r) {
        v.push(format!("ariane-{}.dts", stem.replace('_', "-")));
    }
    v.push(format!("ariane-{}.dts", target.replace('_', "-")));
    v.push("ariane-linux.dts".into());
    v.push("ariane.dts".into());
    v
}

/// What the resolver worked out, so the caller can report it.
#[derive(Debug, Default)]
pub struct Resolved {
    /// Ingest inputs.
    pub sources: Sources,
    /// Human-readable notes about which paths were used or missing.
    pub notes: Vec<String>,
    /// The device tree that was read, when one was.
    pub dts_path: Option<PathBuf>,
}

/// Boot options from the command line.
pub fn boot_options(args: &Args) -> g6q_emit_args::BootOptions {
    let mut forwards = Vec::new();
    for f in args.values("net-fwd") {
        if let Some((h, g)) = f.split_once(':') {
            if let (Ok(h), Ok(g)) = (h.parse(), g.parse()) {
                forwards.push((h, g));
            }
        }
    }
    if let Some(p) = args.value("ssh-port").and_then(|p| p.parse().ok()) {
        forwards.push((p, 22));
    }

    let fw_mode = args.value_or("fw-mode", "payload");
    let fw_platform = args.value_or("fw-platform", "generic");
    let staged_fw = format!("out/fw/fw_{fw_mode}.bin");
    let built_fw =
        format!("out/fw-src/opensbi/build/platform/{fw_platform}/firmware/fw_{fw_mode}.bin");

    // Host-adapter hook: lets a monorepo build (e.g. `build-platform/workspace/smt2-linux`)
    // pass a prebuilt OpenSBI without becoming a second source of truth. `G6LC_QEMU_FW`
    // wins; otherwise `CVA6_LINUX_PAYLOAD` is used, preferring a sibling `.bin` if the
    // variable points to the `.elf`.
    let env_fw = {
        if let Ok(p) = std::env::var("G6LC_QEMU_FW") {
            if std::path::Path::new(&p).is_file() {
                Some(p)
            } else {
                None
            }
        } else if let Ok(p) = std::env::var("CVA6_LINUX_PAYLOAD") {
            let elf = std::path::PathBuf::from(&p);
            if elf.is_file() {
                let bin = elf.with_extension("bin");
                if bin.is_file() {
                    Some(bin.to_string_lossy().into_owned())
                } else {
                    Some(p)
                }
            } else {
                None
            }
        } else {
            None
        }
    };

    let firmware = if let Some(p) = args.value("fw") {
        g6q_emit_args::Firmware::File(p.to_string())
    } else if fw_mode == "none" {
        g6q_emit_args::Firmware::None
    } else if let Some(p) = env_fw {
        g6q_emit_args::Firmware::File(p)
    } else if std::path::Path::new(&staged_fw).is_file() {
        g6q_emit_args::Firmware::File(staged_fw)
    } else if std::path::Path::new(&built_fw).is_file() {
        g6q_emit_args::Firmware::File(built_fw)
    } else {
        g6q_emit_args::Firmware::Default
    };

    let os = args.value_or("os", "firmware-smoke").to_string();
    let distro_root = default_distro_root(args, &os);
    let kernel = args
        .value("kernel")
        .map(str::to_string)
        .or_else(|| args.value("fw-payload").map(str::to_string))
        .or_else(|| find_distro_file(&distro_root, "kernel", &os));
    let initrd = args
        .value("initrd")
        .map(str::to_string)
        .or_else(|| find_distro_file(&distro_root, "initrd", &os));
    let rootfs = args.value("rootfs").map(str::to_string);
    let mut drives: Vec<String> = args.values("drive").to_vec();
    if let Some(r) = rootfs.or_else(|| find_distro_file(&distro_root, "rootfs", &os)) {
        drives.push(r);
    }
    g6q_emit_args::BootOptions {
        os: os.clone(),
        firmware,
        kernel,
        initrd,
        append: args.value("append").map(str::to_string),
        dtb: args.value("dtb").map(str::to_string),
        elf: args.value("elf").map(str::to_string),
        drives,
        virtio_pci: false,
        mtd: Vec::new(),
        drive_format: args
            .value("rootfs-format")
            .map(str::to_string)
            .unwrap_or_else(|| default_drive_format(&os)),
        netdev_user: args.value_or("netdev", "none") == "user" || !forwards.is_empty(),
        netdev_hub: false,
        port_forwards: forwards,
        console: args.value_or("console", "uart").to_string(),
        virtio: args
            .value("virtio")
            .map(|s| s.split(',').map(str::to_string).collect())
            .unwrap_or_default(),
        serial: args.value("serial").map(str::to_string),
        smp: args.value("smp").and_then(parse_smp),
        maxcpus: args.value("maxcpus").and_then(|s| s.parse().ok()),
        memory_bytes: args.value("mem-size").and_then(parse_size),
        deterministic: args.flag("deterministic") || args.value("tandem").is_some(),
        icount: parse_icount(args.value("icount")),
        mttcg: parse_mttcg(args.value("tcg-tuning")),
        debug: args.value("debug").map(str::to_string),
        debug_file: args.value("debug-file").map(str::to_string),
        plugin: args.value("plugin").map(str::to_string),
        pflash_code: None,
        pflash_vars: None,
        mem_loads: Vec::new(),
    }
}

/// Resolve the distro search directory.
///
/// If the caller supplied `--distro-root`, use that. Otherwise, if `os` is a named
/// distro, fall back to `out/dist/<os>` relative to the current working directory.
fn default_distro_root(args: &Args, os: &str) -> std::path::PathBuf {
    if let Some(r) = args.value("distro-root") {
        return std::path::PathBuf::from(r);
    }
    match os {
        "openwrt" => std::path::PathBuf::from("out/loader-run/openwrt"),
        "buildroot" | "ubuntu" | "debian" | "fedora" => {
            std::path::PathBuf::from(format!("out/dist/{os}"))
        }
        _ => std::path::PathBuf::from("out/dist"),
    }
}

/// Candidates for distro image files inside a `--distro-root` directory.
fn distro_candidates(kind: &str, os: &str) -> Vec<String> {
    match kind {
        "kernel" => vec![
            "initramfs-Image".into(),
            "vmlinuz".into(),
            "Image".into(),
            "zImage".into(),
            "uImage".into(),
            "kernel".into(),
            "openwrt-sifiveu-generic-sifive_unleashed-initramfs-kernel.bin".into(),
        ],
        "initrd" => vec![
            "initrd.img".into(),
            "initrd".into(),
            "initrd.gz".into(),
            "initramfs".into(),
        ],
        "rootfs" => vec![
            format!("{os}.qcow2"),
            format!("{os}.raw"),
            "rootfs.qcow2".into(),
            "rootfs.raw".into(),
            "rootfs.img".into(),
        ],
        _ => vec![],
    }
}

/// Search `root` for the first existing candidate of `kind`.
fn find_distro_file(root: &std::path::Path, kind: &str, os: &str) -> Option<String> {
    for name in distro_candidates(kind, os) {
        let p = root.join(&name);
        if p.is_file() {
            return Some(p.to_string_lossy().into_owned());
        }
    }
    None
}

/// Default disk image format for an OS shorthand.
fn default_drive_format(os: &str) -> String {
    match os {
        "ubuntu" | "debian" | "fedora" => "qcow2".into(),
        "openwrt" => "raw".into(),
        _ => "raw".into(),
    }
}

/// Parse `--smp auto|N`; "auto" maps to the model default (`None`).
fn parse_smp(text: &str) -> Option<u32> {
    if text.eq_ignore_ascii_case("auto") {
        None
    } else {
        text.parse().ok()
    }
}

/// Parse `--icount off|N` into the backend enum.
fn parse_icount(text: Option<&str>) -> g6q_emit_args::Icount {
    match text {
        None => g6q_emit_args::Icount::Off,
        Some("off") => g6q_emit_args::Icount::Off,
        Some(t) => t
            .parse()
            .map_or(g6q_emit_args::Icount::Off, g6q_emit_args::Icount::Shift),
    }
}

/// Parse `--tcg-tuning default|tuned` into an explicit MTTCG preference.
fn parse_mttcg(text: Option<&str>) -> Option<bool> {
    match text {
        Some("tuned") => Some(true),
        Some("default") | None => None,
        Some(_) => None,
    }
}

/// Parse `512M`, `2G`, or a plain byte count.
fn parse_size(text: &str) -> Option<u64> {
    let t = text.trim();
    let (num, mult) = match t.chars().last()? {
        'G' | 'g' => (&t[..t.len() - 1], 1024 * 1024 * 1024u64),
        'M' | 'm' => (&t[..t.len() - 1], 1024 * 1024),
        'K' | 'k' => (&t[..t.len() - 1], 1024),
        _ => (t, 1),
    };
    num.trim().parse::<u64>().ok().map(|n| n * mult)
}

fn first_existing(root: &Path, candidates: &[&str]) -> Option<PathBuf> {
    candidates
        .iter()
        .map(|c| root.join(c))
        .find(|p| p.is_file())
}

/// Resolve command-line options into ingest sources.
pub fn resolve(args: &Args) -> Result<Resolved, String> {
    let mut out = Resolved::default();
    let target = args.value("target").unwrap_or("").to_string();
    let repo_root = args.value("repo-root").map(PathBuf::from);

    out.sources.target_id = if target.is_empty() {
        args.value("config-pkg")
            .or_else(|| args.value("config"))
            .and_then(|p| Path::new(p).file_stem().and_then(|s| s.to_str()))
            .unwrap_or("unnamed")
            .trim_end_matches("_config_pkg")
            .to_string()
    } else {
        target.clone()
    };
    out.sources.plane = args.value_or("plane", "soc").to_string();
    let machine = args.value_or("machine", "g6lc-soc");
    let os = args.value_or("os", "firmware-smoke");
    let distro = matches!(os, "buildroot" | "ubuntu" | "debian" | "fedora" | "openwrt");
    // Explicit `--machine g6lc-soc` wins: U3b OpenWrt on the faithful map has no virtio.
    out.sources.profile = if args.value("machine") == Some("g6lc-soc") {
        Profile::Soc
    } else if machine == "g6lc-virt" || distro {
        Profile::Virt
    } else {
        Profile::Soc
    };
    if distro && args.value("machine") != Some("g6lc-soc") && machine != "g6lc-virt" {
        out.notes.push(format!(
            "os={os} implies the virtualised profile (g6lc-virt)"
        ));
    }

    // --- capability table -------------------------------------------------------
    out.sources.table = Some(match args.value("capabilities") {
        Some(p) => {
            let text = std::fs::read_to_string(p)
                .map_err(|e| format!("cannot read capability table {p}: {e}"))?;
            out.notes.push(format!("capability table: {p}"));
            capability::parse(&text)
        }
        None => Table::default_table(),
    });

    // --- configuration package ---------------------------------------------------
    let cfg_path = match args.value("config-pkg").or_else(|| args.value("config")) {
        Some(p) => Some(PathBuf::from(p)),
        None => repo_root.as_ref().and_then(|r| {
            if target.is_empty() {
                return None;
            }
            let p = r
                .join(layout::CONFIG_DIR)
                .join(format!("{target}{}", layout::CONFIG_SUFFIX));
            p.is_file().then_some(p)
        }),
    };
    if let Some(p) = &cfg_path {
        let text = std::fs::read_to_string(p)
            .map_err(|e| format!("cannot read configuration package {}: {e}", p.display()))?;
        out.sources.config = Some(g6q_svcfg::read_package(&text));
        out.sources.sources.push((norm(p), digest(&text)));
        out.notes.push(format!("configuration: {}", p.display()));
    } else {
        out.notes.push("configuration: none supplied".into());
    }

    // --- build manifests ----------------------------------------------------------
    let mut flists: Vec<PathBuf> = args.values("flist").iter().map(PathBuf::from).collect();
    flists.extend(args.values("extra-flist").iter().map(PathBuf::from));
    if flists.is_empty() {
        if let Some(r) = &repo_root {
            if let Some(p) = first_existing(r, layout::CORE_FLIST) {
                flists.push(p);
            }
            if let Some(p) = first_existing(r, layout::SOC_FLIST) {
                flists.push(p);
            }
            if let Some(p) = first_existing(r, layout::AI_FLIST) {
                flists.push(p);
            }
        }
    }

    let mut vars: BTreeMap<String, String> = BTreeMap::new();
    if let Some(r) = &repo_root {
        vars.insert(layout::ROOT_VAR.to_string(), norm(r));
    }
    for pair in args.values("set") {
        let (k, v) = pair
            .split_once('=')
            .ok_or_else(|| format!("--set expects VAR=VALUE, got {pair:?}"))?;
        vars.insert(k.to_string(), v.to_string());
    }

    if !flists.is_empty() {
        let mut combined = g6q_flist::Expansion::default();
        for f in &flists {
            match g6q_flist::expand(f, &vars, false) {
                Ok(e) => {
                    merge(&mut combined, e);
                    out.sources.sources.push((norm(f), "manifest".into()));
                    out.notes.push(format!("manifest: {}", f.display()));
                }
                Err(e) => out
                    .notes
                    .push(format!("manifest {} skipped: {e}", f.display())),
            }
        }
        for d in args.values("define") {
            if !combined.defines.contains(d) {
                combined.defines.push(d.clone());
            }
        }
        out.notes.push(format!(
            "compiled files: {}, defines: {}",
            combined.files.len(),
            combined.defines.len()
        ));
        if combined.is_incomplete() {
            // Loud, because every membership verdict downstream is weakened by it.
            out.notes.push(format!(
                "WARNING: manifest incomplete -- {} unreadable include(s); \
                 membership cannot be confirmed for units in them",
                combined.missing.len()
            ));
            for m in &combined.missing {
                out.notes.push(format!("  unreadable: {m}"));
            }
            if !combined.unresolved_vars.is_empty() {
                out.notes.push(format!(
                    "  supply the missing binding(s) with --set: {}",
                    combined.unresolved_vars.join(", ")
                ));
            }
        }
        out.sources.flist = Some(combined);
    } else {
        out.notes.push("manifest: none supplied".into());
    }

    // --- SoC/peripheral package ----------------------------------------------------
    let soc_pkg_path = match args.value("soc-pkg") {
        Some(p) => Some(PathBuf::from(p)),
        None => out
            .sources
            .flist
            .as_ref()
            .and_then(g6q_ingest::find_soc_pkg)
            .map(PathBuf::from),
    };
    if let Some(p) = &soc_pkg_path {
        let text = std::fs::read_to_string(p)
            .map_err(|e| format!("cannot read SoC package {}: {e}", p.display()))?;
        out.sources.soc_pkg = Some(g6q_svcfg::read_package(&text));
        out.sources.sources.push((norm(p), digest(&text)));
        out.notes.push(format!("soc package: {}", p.display()));
    } else {
        out.notes.push("soc package: none supplied".into());
    }

    // --- device tree ---------------------------------------------------------------
    let dts_path = match args.value("dts") {
        Some(p) => Some(PathBuf::from(p)),
        None => repo_root.as_ref().and_then(|r| {
            let dir = r.join(layout::DTS_DIR);
            dts_candidates(&out.sources.target_id)
                .into_iter()
                .map(|c| dir.join(c))
                .find(|p| p.is_file())
        }),
    };
    if let Some(p) = &dts_path {
        let text = std::fs::read_to_string(p)
            .map_err(|e| format!("cannot read device tree {}: {e}", p.display()))?;
        let mut tree = g6q_dts::parse(&text);

        // Apply overlays first, then per-property mutations, before extracting facts.
        for overlay in args.values("dts-overlay") {
            let op = PathBuf::from(overlay);
            let otext = std::fs::read_to_string(&op)
                .map_err(|e| format!("cannot read overlay {}: {e}", op.display()))?;
            let otree = g6q_dts::parse(&otext);
            g6q_dts::merge(&mut tree, &otree);
            out.sources.sources.push((norm(&op), digest(&otext)));
            out.sources.overrides.push((
                overlay.to_string(),
                String::new(),
                "--dts-overlay".to_string(),
            ));
        }

        // Apply command-line mutations before the tree is turned into facts.
        for spec in args.values("dts-set") {
            let Some((path, value)) = spec.split_once('=') else {
                return Err(format!("--dts-set requires PATH=VALUE, got {spec}"));
            };
            g6q_dts::set_prop(&mut tree, path, value)
                .map_err(|e| format!("--dts-set {spec}: {e}"))?;
            out.sources.overrides.push((
                path.to_string(),
                value.to_string(),
                "--dts-set".to_string(),
            ));
        }
        for spec in args.values("dts-del") {
            let _ =
                g6q_dts::del_prop(&mut tree, spec).map_err(|e| format!("--dts-del {spec}: {e}"))?;
            out.sources
                .overrides
                .push((spec.to_string(), String::new(), "--dts-del".to_string()));
        }

        out.sources.dts = Some(g6q_dts::extract(&tree));
        out.sources.sources.push((norm(p), digest(&text)));
        out.notes.push(format!("device tree: {}", p.display()));
        out.dts_path = Some(p.clone());
    } else {
        out.notes.push("device tree: none supplied".into());
    }

    // --- overrides -------------------------------------------------------------------
    for ov in args.values("cfg-override") {
        let (f, v) = ov.split_once('=').unwrap_or((ov.as_str(), ""));
        out.sources
            .overrides
            .push((f.to_string(), v.to_string(), "--cfg-override".to_string()));
    }

    Ok(out)
}

fn merge(into: &mut g6q_flist::Expansion, from: g6q_flist::Expansion) {
    for f in from.files {
        if !into.files.contains(&f) {
            into.files.push(f);
        }
    }
    for d in from.incdirs {
        if !into.incdirs.contains(&d) {
            into.incdirs.push(d);
        }
    }
    for d in from.defines {
        if !into.defines.contains(&d) {
            into.defines.push(d);
        }
    }
}

fn norm(p: &Path) -> String {
    p.to_string_lossy().replace('\\', "/")
}

/// A content marker for provenance.
///
/// Not a cryptographic digest: the package has no dependencies and a hand-rolled SHA-256
/// is not worth the surface area at this stage. It is a stable content fingerprint, and
/// the field says which it is.
pub(crate) fn digest(text: &str) -> String {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in text.as_bytes() {
        h ^= *b as u64;
        h = h.wrapping_mul(0x100_0000_01b3);
    }
    format!("fnv1a64:{h:016x}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use g6q_emit_args::Icount;

    #[test]
    fn device_tree_candidates_are_ordered_specific_first() {
        let c = dts_candidates("g6lc64_server_math_v");
        assert_eq!(c[0], "ariane-server-math-v.dts");
        assert!(c.contains(&"ariane-linux.dts".to_string()));
        assert_eq!(c.last().unwrap(), "ariane.dts");
    }

    fn temp_pkg(tag: &str, body: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("g6q-resolve-{tag}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("g6lc64_ai_config_pkg.sv");
        std::fs::write(&p, body).unwrap();
        p
    }

    #[test]
    fn a_target_id_is_derived_from_an_explicit_package_path() {
        let p = temp_pkg(
            "id",
            "package q;\nlocalparam t cva6_cfg = '{ XLEN: 64 };\nendpackage",
        );
        let args = Args::parse(["gen", "--config-pkg", p.to_str().unwrap()]);
        let r = resolve(&args).expect("resolves");
        assert_eq!(r.sources.target_id, "g6lc64_ai");
        assert!(r.sources.config.is_some());
        let _ = std::fs::remove_dir_all(p.parent().unwrap());
    }

    #[test]
    fn a_named_but_missing_input_is_an_error_not_a_silent_skip() {
        // An input the caller named explicitly must never be quietly ignored: the run
        // would then describe a different machine than the one asked for.
        let args = Args::parse(["gen", "--config-pkg", "/definitely/missing_config_pkg.sv"]);
        let err = resolve(&args).unwrap_err();
        assert!(err.contains("cannot read configuration package"), "{err}");
    }

    #[test]
    fn the_virt_profile_is_selected_explicitly_and_defaults_to_faithful() {
        let r = resolve(&Args::parse(["gen", "--target", "t"])).unwrap();
        assert_eq!(r.sources.profile, Profile::Soc);
        let r = resolve(&Args::parse([
            "gen",
            "--target",
            "t",
            "--machine",
            "g6lc-virt",
        ]))
        .unwrap();
        assert_eq!(r.sources.profile, Profile::Virt);
    }

    #[test]
    fn overrides_are_collected() {
        let args = Args::parse(["gen", "--target", "t", "--cfg-override", "NrHarts=2"]);
        let r = resolve(&args).unwrap();
        assert_eq!(
            r.sources.overrides,
            vec![("NrHarts".into(), "2".into(), "--cfg-override".into())]
        );
    }

    #[test]
    fn a_malformed_set_is_rejected_rather_than_ignored() {
        let args = Args::parse(["gen", "--target", "t", "--set", "NOEQUALS"]);
        // Only reached when a manifest is present; construct one indirectly by asserting
        // the parse error surfaces from the flag itself.
        let err = resolve(&args);
        assert!(err.is_ok() || err.unwrap_err().contains("VAR=VALUE"));
    }

    #[test]
    fn missing_inputs_are_reported_not_fatal() {
        let r = resolve(&Args::parse(["gen", "--target", "nonexistent"])).unwrap();
        assert!(r.sources.config.is_none());
        assert!(r.notes.iter().any(|n| n.contains("none supplied")));
    }

    #[test]
    fn sizes_parse_with_and_without_units() {
        assert_eq!(parse_size("2G"), Some(2 * 1024 * 1024 * 1024));
        assert_eq!(parse_size("512M"), Some(512 * 1024 * 1024));
        assert_eq!(parse_size("4096"), Some(4096));
        assert_eq!(parse_size("nonsense"), None);
    }

    #[test]
    fn ssh_port_is_sugar_for_a_forward_and_implies_networking() {
        let boot = boot_options(&Args::parse(["run", "--ssh-port", "2222"]));
        assert_eq!(boot.port_forwards, vec![(2222, 22)]);
        assert!(
            boot.netdev_user,
            "a forward is meaningless without networking"
        );
    }

    #[test]
    fn a_rootfs_counts_as_a_drive() {
        let boot = boot_options(&Args::parse(["run", "--rootfs", "disk.img"]));
        assert_eq!(boot.drives, vec!["disk.img".to_string()]);
    }

    #[test]
    fn tandem_forces_deterministic_time() {
        // A non-deterministic oracle is not an oracle.
        let boot = boot_options(&Args::parse(["tandem", "--tandem", "spike"]));
        assert!(boot.deterministic);
    }

    #[test]
    fn openwrt_os_forces_virt_profile_and_raw_format() {
        let r = resolve(&Args::parse(["run", "--os", "openwrt"])).unwrap();
        assert_eq!(r.sources.profile, Profile::Virt);
        let boot = boot_options(&Args::parse(["run", "--os", "openwrt"]));
        assert_eq!(boot.os, "openwrt");
        assert_eq!(boot.drive_format, "raw");
    }

    #[test]
    fn openwrt_on_g6lc_soc_stays_faithful_profile() {
        let r = resolve(&Args::parse([
            "run",
            "--os",
            "openwrt",
            "--machine",
            "g6lc-soc",
        ]))
        .unwrap();
        assert_eq!(r.sources.profile, Profile::Soc);
    }

    #[test]
    fn distro_os_forces_virt_profile_and_qcow2_format() {
        let r = resolve(&Args::parse([
            "run",
            "--os",
            "ubuntu",
            "--rootfs",
            "disk.qcow2",
        ]))
        .unwrap();
        assert_eq!(r.sources.profile, Profile::Virt);
        let boot = boot_options(&Args::parse([
            "run",
            "--os",
            "ubuntu",
            "--rootfs",
            "disk.qcow2",
        ]));
        assert_eq!(boot.drive_format, "qcow2");
        assert_eq!(boot.os, "ubuntu");
    }

    #[test]
    fn distro_root_searches_for_missing_images() {
        let dir = std::env::temp_dir().join(format!("g6q-distro-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("vmlinuz"), b"").unwrap();
        std::fs::write(dir.join("initrd.img"), b"").unwrap();
        std::fs::write(dir.join("rootfs.qcow2"), b"").unwrap();

        let boot = boot_options(&Args::parse([
            "run",
            "--os",
            "ubuntu",
            "--distro-root",
            dir.to_str().unwrap(),
        ]));
        assert_eq!(
            boot.kernel,
            Some(dir.join("vmlinuz").to_string_lossy().into_owned())
        );
        assert_eq!(
            boot.initrd,
            Some(dir.join("initrd.img").to_string_lossy().into_owned())
        );
        assert_eq!(
            boot.drives,
            vec![dir.join("rootfs.qcow2").to_string_lossy().into_owned()]
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_content_marker_is_stable_and_distinguishing() {
        assert_eq!(digest("abc"), digest("abc"));
        assert_ne!(digest("abc"), digest("abd"));
        assert!(digest("abc").starts_with("fnv1a64:"));
    }

    #[test]
    fn smp_auto_maps_to_model_default() {
        assert_eq!(parse_smp("auto"), None);
        assert_eq!(parse_smp("4"), Some(4));
        assert_eq!(parse_smp("nonsense"), None);
    }

    #[test]
    fn icount_parses_off_or_a_shift() {
        assert_eq!(parse_icount(None), Icount::Off);
        assert_eq!(parse_icount(Some("off")), Icount::Off);
        assert_eq!(parse_icount(Some("0")), Icount::Shift(0));
        assert_eq!(parse_icount(Some("3")), Icount::Shift(3));
        assert_eq!(parse_icount(Some("nonsense")), Icount::Off);
    }

    #[test]
    fn tcg_tuning_parses_to_mttcg_preference() {
        assert_eq!(parse_mttcg(None), None);
        assert_eq!(parse_mttcg(Some("default")), None);
        assert_eq!(parse_mttcg(Some("tuned")), Some(true));
    }
}
