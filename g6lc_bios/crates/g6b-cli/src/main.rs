// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Host CLI: generate ZealOS, boot HolyC+DOM+JS, dual-band HolyC REPL.

#![allow(missing_docs)]

use std::env;
use std::fs;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::{Duration, Instant};

use g6b_holyc::ReplResult;
use g6b_img::{load_assets, AssetMap};

fn main() -> ExitCode {
    let mut args = env::args().skip(1).collect::<Vec<_>>();
    if args.is_empty() {
        eprintln!(
            "usage: g6b <design-compile|display|boot|tohtml|holyc-eval|holyc-serve|http-serve|loopback|qemu-args|elf|smoke|gr|display-proxy|display-proxy-32|ui-ppm32|css-paint|css-render|ppm-diff|zealcli|man> \
             [--spec FILE] [--out DIR|FILE] [--port N] [--once] [--script FILE|-] [--keys CODES] [--frames] [--section NAME] [--cols N]"
        );
        return ExitCode::from(2);
    }
    let cmd = args.remove(0);
    let spec_path = flag_value(&args, "--spec").map(PathBuf::from);
    match cmd.as_str() {
        "design-compile" => match load_spec(spec_path.as_deref()) {
            Err(c) => c,
            Ok(spec) => {
                let out = g6b_design::compile(&spec);
                if let Some(dir) = flag_value(&args, "--out") {
                    if let Err(e) = g6b_design::write_to_dir(&out, Path::new(dir)) {
                        eprintln!("g6b: {e}");
                        return ExitCode::from(1);
                    }
                    eprintln!("g6b: wrote {dir}/zeal/Config.ZC");
                } else {
                    print!("{}", out.config_zc);
                }
                ExitCode::SUCCESS
            }
        },
        "display" | "boot" => match load_spec(spec_path.as_deref()) {
            Err(c) => c,
            Ok(spec) => {
                let vols = match attached_volumes(&args) {
                    Ok(v) => v,
                    Err(e) => {
                        eprintln!("g6b: {e}");
                        return ExitCode::from(2);
                    }
                };
                println!("{}", g6b_kernel::boot_with_volumes(&spec, vols));
                ExitCode::SUCCESS
            }
        },
        "qemu-args" => match load_spec(spec_path.as_deref()) {
            Err(c) => c,
            Ok(spec) => {
                let mut argv = g6b_kernel::qemu_dual_band_argv(&spec);
                // --vnc N: host-side display frontend on 5900+N — the QEMU
                // console (BIOS scanout, and whatever a later OS puts on it)
                // is exported over VNC; composes with -nographic since the
                // command console is the TCP serial backend.
                if let Some(v) = flag_value(&args, "--vnc") {
                    argv.push("-vnc".into());
                    argv.push(format!("127.0.0.1:{v}"));
                }
                // --no-gl: host has no DRM render node → 2D virtio-gpu
                // fallback (identical guest commands; no virgl).
                if flag_present(&args, "--no-gl") {
                    let mut i = 0;
                    while i < argv.len() {
                        if argv[i] == "-display" {
                            argv.drain(i..=i + 1);
                        } else {
                            i += 1;
                        }
                    }
                    for a in argv.iter_mut() {
                        if a == "virtio-gpu-gl-device" {
                            *a = "virtio-gpu-device".into();
                        }
                    }
                }
                println!("{}", argv.join(" "));
                ExitCode::SUCCESS
            }
        },
        "holyc-eval" => match load_spec(spec_path.as_deref()) {
            Err(c) => c,
            Ok(spec) => match g6b_kernel::load_program(&spec) {
                Err(e) => {
                    eprintln!("g6b: {e}");
                    ExitCode::from(1)
                }
                Ok(mut p) => match p.start() {
                    Ok(out) => {
                        print!("{out}");
                        if !out.ends_with('\n') {
                            println!();
                        }
                        ExitCode::SUCCESS
                    }
                    Err(e) => {
                        eprintln!("g6b: {e}");
                        ExitCode::from(1)
                    }
                },
            },
        },
        "holyc-serve" => match load_spec(spec_path.as_deref()) {
            Err(c) => c,
            Ok(spec) => serve_holyc(&spec, &args, false),
        },
        "http-serve" => match load_spec(spec_path.as_deref()) {
            Err(c) => c,
            Ok(spec) => serve_http(&spec, &args),
        },
        "loopback" => match load_spec(spec_path.as_deref()) {
            Err(c) => c,
            Ok(spec) => serve_holyc(&spec, &args, true),
        },
        "display-proxy" => match load_spec(spec_path.as_deref()) {
            Err(c) => c,
            Ok(spec) => {
                let ppm = g6b_kernel::proxy_ppm(&spec);
                let out = flag_value(&args, "--out").unwrap_or("out/proxy.ppm");
                if let Some(parent) = Path::new(out).parent() {
                    if !parent.as_os_str().is_empty() {
                        let _ = fs::create_dir_all(parent);
                    }
                }
                if let Err(e) = fs::write(out, ppm) {
                    eprintln!("g6b: display-proxy: {e}");
                    return ExitCode::from(1);
                }
                let gl_path = Path::new(out).with_extension("glsl");
                let _ = fs::write(&gl_path, g6b_kernel::gl_listing(&spec));
                eprintln!("g6b: wrote {out} and {}", gl_path.display());
                ExitCode::SUCCESS
            }
        },
        "display-proxy-32" => match load_spec(spec_path.as_deref()) {
            Err(c) => c,
            Ok(spec) => {
                let out = flag_value(&args, "--out").unwrap_or("out/proxy32.ppm");
                match g6b_kernel::proxy_ppm32(&spec) {
                    Ok(ppm) => {
                        if let Some(parent) = Path::new(out).parent() {
                            if !parent.as_os_str().is_empty() {
                                let _ = fs::create_dir_all(parent);
                            }
                        }
                        if let Err(e) = fs::write(out, ppm) {
                            eprintln!("g6b: display-proxy-32: {e}");
                            return ExitCode::from(1);
                        }
                        eprintln!("g6b: wrote {out}");
                        ExitCode::SUCCESS
                    }
                    Err(e) => {
                        eprintln!("g6b: display-proxy-32: {e}");
                        ExitCode::from(1)
                    }
                }
            }
        },
        "ui-ppm32" => match load_spec(spec_path.as_deref()) {
            Err(c) => c,
            Ok(spec) => {
                let out = flag_value(&args, "--out").unwrap_or("out/setup32.ppm");
                match g6b_kernel::ui_ppm32(&spec) {
                    Ok(ppm) => {
                        if let Some(parent) = Path::new(out).parent() {
                            if !parent.as_os_str().is_empty() {
                                let _ = fs::create_dir_all(parent);
                            }
                        }
                        if let Err(e) = fs::write(out, ppm) {
                            eprintln!("g6b: ui-ppm32: {e}");
                            return ExitCode::from(1);
                        }
                        eprintln!("g6b: wrote {out}");
                        ExitCode::SUCCESS
                    }
                    Err(e) => {
                        eprintln!("g6b: ui-ppm32: {e}");
                        ExitCode::from(1)
                    }
                }
            }
        },
        "gr" => match load_spec(spec_path.as_deref()) {
            Err(c) => c,
            Ok(spec) => {
                let ppm = g6b_kernel::gr_ppm(&spec);
                let out = flag_value(&args, "--out").unwrap_or("out/setup.ppm");
                if let Some(parent) = Path::new(out).parent() {
                    if !parent.as_os_str().is_empty() {
                        let _ = fs::create_dir_all(parent);
                    }
                }
                if let Err(e) = fs::write(out, ppm) {
                    eprintln!("g6b: gr: {e}");
                    return ExitCode::from(1);
                }
                eprintln!("g6b: wrote {out}");
                ExitCode::SUCCESS
            }
        },
        "zealcli" | "cli" => match load_spec(spec_path.as_deref()) {
            Err(c) => c,
            Ok(spec) => run_zealcli(&spec, &args),
        },
        "man" => match load_spec(spec_path.as_deref()) {
            Err(c) => c,
            Ok(spec) => {
                let cols = flag_value(&args, "--cols")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(spec.kernel.cli.cols as usize);
                let section = flag_value(&args, "--section").unwrap_or("");
                print!("{}", g6b_zealcli::man::manual(&spec, cols, section));
                ExitCode::SUCCESS
            }
        },
        "css-paint" => css_paint(&args),
        "css-render" => css_render(&args),
        "ppm-diff" => ppm_diff(&args),
        "smoke" => match load_spec(spec_path.as_deref()) {
            Err(c) => c,
            Ok(spec) => match g6b_elf::smoke(&spec) {
                Ok(s) => {
                    print!("{}", s.console);
                    if !s.console.ends_with('\n') {
                        println!();
                    }
                    eprintln!(
                        "g6b: smoke halt={:?} steps={} satp={:#x} dom_rows={} dom_pix0={:#x} \
                         vio={:#x}/{:#x}/{:#x} scanout={} flushes={} irqs={}",
                        s.halt,
                        s.steps,
                        s.satp,
                        s.dom_rows,
                        s.dom_pix0,
                        s.vio_status,
                        s.vio_last_cmd,
                        s.vio_last_resp,
                        s.vio_scanout,
                        s.vio_flushes,
                        s.vio_irqs
                    );
                    // --out FILE: executed __gr_plane (incl. DomPaint) → PPM.
                    if let Some(out) = flag_value(&args, "--out") {
                        match g6b_kernel::frame_ppm(&s.gr_frame) {
                            Some(ppm) => {
                                if let Some(parent) = Path::new(out).parent() {
                                    if !parent.as_os_str().is_empty() {
                                        let _ = fs::create_dir_all(parent);
                                    }
                                }
                                if let Err(e) = fs::write(out, ppm) {
                                    eprintln!("g6b: smoke --out: {e}");
                                    return ExitCode::from(1);
                                }
                                eprintln!("g6b: wrote {out}");
                            }
                            None => eprintln!("g6b: smoke: no live GR16 plane to export"),
                        }
                    }
                    // --out-vio FILE: device-side virtio-gpu scanout → PPM.
                    if let Some(out) = flag_value(&args, "--out-vio") {
                        match g6b_kernel::scanout_ppm(s.vio_fb_w, s.vio_fb_h, &s.vio_fb) {
                            Some(ppm) => {
                                if let Some(parent) = Path::new(out).parent() {
                                    if !parent.as_os_str().is_empty() {
                                        let _ = fs::create_dir_all(parent);
                                    }
                                }
                                if let Err(e) = fs::write(out, ppm) {
                                    eprintln!("g6b: smoke --out-vio: {e}");
                                    return ExitCode::from(1);
                                }
                                eprintln!("g6b: wrote {out}");
                            }
                            None => eprintln!("g6b: smoke: no virtio scanout surface to export"),
                        }
                    }
                    ExitCode::SUCCESS
                }
                Err(e) => {
                    eprintln!("g6b: smoke: {e}");
                    ExitCode::from(1)
                }
            },
        },
        "elf" => match load_spec(spec_path.as_deref()) {
            Err(c) => c,
            Ok(spec) => {
                let out = flag_value(&args, "--out").unwrap_or("out/g6lc_bios.elf");
                let path = PathBuf::from(out);
                let path = if path.extension().and_then(|s| s.to_str()) == Some("elf") {
                    path
                } else {
                    path.join("g6lc_bios.elf")
                };
                let vols = match attached_volumes(&args) {
                    Ok(v) => v,
                    Err(e) => {
                        eprintln!("g6b: {e}");
                        return ExitCode::from(2);
                    }
                };
                match g6b_elf::write_elf_with_volumes(&spec, &path, vols) {
                    Ok(()) => {
                        eprintln!("g6b: wrote {}", path.display());
                        ExitCode::SUCCESS
                    }
                    Err(e) => {
                        eprintln!("g6b: elf: {e}");
                        ExitCode::from(1)
                    }
                }
            }
        },
        // Real block devices, partition tables and filesystems — the same
        // `g6b-vfs` drivers the setup shell and the browser UI use.
        //   g6b vfs scan  --disk PATH
        //   g6b vfs ls    --disk PATH [--part N] [--path /etc]
        //   g6b vfs cat   --disk PATH [--part N] --path /etc/fstab
        //   g6b vfs write --disk PATH [--part N] --path /etc/fstab --in FILE
        //   g6b vfs os    --disk PATH [--part N]
        "vfs" => run_vfs(&args),
        "tohtml" => {
            let src = if let Some(p) = flag_value(&args, "--in") {
                fs::read_to_string(p).unwrap_or_default()
            } else {
                "$FG,BLUE$G6LC-BIOS$FG$".into()
            };
            let spans = g6b_doldoc::parse(&src);
            print!("{}", g6b_doldoc::to_html("G6LC-BIOS", &spans));
            ExitCode::SUCCESS
        }
        other => {
            eprintln!("g6b: unknown command {other}");
            ExitCode::from(2)
        }
    }
}

/// `g6b zealcli` — drive the setup shell in its container.
///
/// The container is the product, so the harness prints it: `--frames` after
/// every line (what an operator would have seen), otherwise the final frame.
/// Input is a `--script` file, `-` for stdin, or an interactive stdin; `--keys`
/// feeds raw Linux keycodes so the USB-keyboard path can be exercised without a
/// keyboard. Ports come from the kernel, so volumes / net / flash are exactly
/// what the BoardSpec compiled.
/// `g6b vfs <scan|ls|cat|write|os>` — drive the real filesystem drivers from the
/// host, against an image or a raw disk. This is the same code path the BIOS uses,
/// which is what makes it a useful check: if `g6b vfs ls` cannot read a volume,
/// neither can the setup shell.
fn run_vfs(args: &[String]) -> ExitCode {
    let sub = args.first().map(String::as_str).unwrap_or("scan");
    // `emit-fs` writes a hand-laid fixture to a file so QEMU can attach it as
    // a virtio-blk device. No --disk needed. `emit-btrfs` is the original,
    // btrfs-only spelling and stays as an alias so existing scripts keep
    // working.
    if sub == "emit-fs" || sub == "emit-btrfs" {
        let kinds = g6b_vfs::FIXTURE_KINDS.join("|");
        let fs_name = match flag_value(args, "--fs") {
            Some(f) => f,
            // `emit-btrfs` implies its filesystem; `emit-fs` must be told.
            None if sub == "emit-btrfs" => "btrfs",
            None => {
                eprintln!("g6b: emit-fs: --fs <{kinds}> is required");
                return ExitCode::from(2);
            }
        };
        // btrfs is the only fixture with a variant, and `--with-data` lays a
        // regular-extent file. It costs FS-tree leaf space, so it is off by
        // default: a store export needs that headroom.
        let with_data = flag_present(args, "--with-data");
        let img = if fs_name.eq_ignore_ascii_case("btrfs") {
            Some(g6b_vfs::btrfs::fixture::image(with_data))
        } else {
            if with_data {
                eprintln!("g6b: emit-fs: --with-data applies to btrfs only");
                return ExitCode::from(2);
            }
            g6b_vfs::fixture_image_named(fs_name).map(|(_, b)| b)
        };
        let Some(img) = img else {
            eprintln!("g6b: emit-fs: no fixture for `{fs_name}` (have: {kinds})");
            return ExitCode::from(2);
        };
        let default_out = format!("out/{}-key.img", fs_name.to_ascii_lowercase());
        let out = flag_value(args, "--out").unwrap_or(&default_out);
        if let Some(parent) = Path::new(out).parent() {
            if !parent.as_os_str().is_empty() {
                let _ = fs::create_dir_all(parent);
            }
        }
        match fs::write(out, &img) {
            Ok(()) => {
                let variant = if fs_name.eq_ignore_ascii_case("btrfs") {
                    format!(", with_data={with_data}")
                } else {
                    String::new()
                };
                eprintln!(
                    "g6b: wrote {} bytes ({fs_name} fixture{variant}) to {out}",
                    img.len()
                );
                ExitCode::SUCCESS
            }
            Err(e) => {
                eprintln!("g6b: {sub}: {e}");
                ExitCode::from(1)
            }
        }
    } else {
        run_vfs_disk(args)
    }
}

fn run_vfs_disk(args: &[String]) -> ExitCode {
    use g6b_zealcli::ports::MountPort;
    let sub = args.first().map(String::as_str).unwrap_or("scan");
    let Some(disk) = flag_value(args, "--disk") else {
        eprintln!("g6b: vfs wants --disk PATH (an image file or a raw device)");
        return ExitCode::from(2);
    };
    let rw = flag_present(args, "--rw");
    let part: Option<u32> = flag_value(args, "--part").and_then(|v| v.parse().ok());
    let path = flag_value(args, "--path").unwrap_or("/");
    let mut svc = match g6b_kernel::VfsService::new().add_file("disk0", disk, "host image") {
        Ok(s) => s,
        Err(e) => {
            eprintln!("g6b: vfs: {e}");
            return ExitCode::from(1);
        }
    };
    // `scan` needs no mount: it is what tells you what could be mounted.
    if sub == "scan" {
        for d in svc.drives() {
            println!("{} {} {} bytes scheme={}", d.id, d.model, d.bytes, d.scheme);
            for w in &d.warnings {
                println!("  ! {w}");
            }
        }
        match svc.volumes("disk0") {
            Ok(vols) => {
                for v in vols {
                    println!(
                        "  {}:{} name={} fs={} label={:?} kind={} bytes={} mountable={}",
                        v.drive, v.index, v.name, v.fs, v.label, v.kind, v.bytes, v.mountable
                    );
                    println!("      evidence: {}", v.evidence);
                    if let Some(why) = v.write_block {
                        println!("      read-only: {why}");
                    }
                }
                return ExitCode::SUCCESS;
            }
            Err(e) => {
                eprintln!("g6b: vfs: {e}");
                return ExitCode::from(1);
            }
        }
    }
    // Everything else works on one volume: the named partition, or the only
    // mountable one.
    let index = match part {
        Some(n) => n,
        None => match svc.volumes("disk0") {
            Ok(vols) => {
                let usable: Vec<_> = vols.iter().filter(|v| v.mountable).collect();
                match usable.len() {
                    1 => usable[0].index,
                    0 => {
                        eprintln!("g6b: vfs: nothing on {disk} has a driver here (try `vfs scan`)");
                        return ExitCode::from(1);
                    }
                    _ => {
                        eprintln!("g6b: vfs: {disk} has several volumes; pick one with --part N:");
                        for v in usable {
                            eprintln!("  --part {} ({} {})", v.index, v.name, v.fs);
                        }
                        return ExitCode::from(2);
                    }
                }
            }
            Err(e) => {
                eprintln!("g6b: vfs: {e}");
                return ExitCode::from(1);
            }
        },
    };
    let m = match svc.mount("disk0", index, "vol", rw) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("g6b: vfs: {e}");
            return ExitCode::from(1);
        }
    };
    eprintln!(
        "g6b: mounted {}:{} as {} ({}, {}{})",
        m.drive,
        m.index,
        m.fs,
        if m.label.is_empty() { "-" } else { &m.label },
        if m.rw { "rw" } else { "ro" },
        m.why_ro.map(|w| format!(", {w}")).unwrap_or_default()
    );
    match sub {
        "ls" => match svc.list("vol", path) {
            Ok(ents) => {
                for e in ents {
                    println!(
                        "{} {:>10} {}",
                        if e.dir { "d" } else { "-" },
                        e.size,
                        e.name
                    );
                }
                ExitCode::SUCCESS
            }
            Err(e) => {
                eprintln!("g6b: vfs: {e}");
                ExitCode::from(1)
            }
        },
        "cat" => match svc.read("vol", path) {
            Ok(bytes) => {
                io::stdout().write_all(&bytes).ok();
                ExitCode::SUCCESS
            }
            Err(e) => {
                eprintln!("g6b: vfs: {e}");
                ExitCode::from(1)
            }
        },
        "write" => {
            let data = match flag_value(args, "--in") {
                Some(f) => match fs::read(f) {
                    Ok(b) => b,
                    Err(e) => {
                        eprintln!("g6b: {f}: {e}");
                        return ExitCode::from(1);
                    }
                },
                None => {
                    let mut b = Vec::new();
                    io::stdin().read_to_end(&mut b).ok();
                    b
                }
            };
            match svc.write("vol", path, &data) {
                Ok(()) => {
                    eprintln!("g6b: wrote {} bytes to {path}", data.len());
                    ExitCode::SUCCESS
                }
                Err(e) => {
                    eprintln!("g6b: vfs: {e}");
                    ExitCode::from(1)
                }
            }
        }
        "os" => {
            match svc.os_info("vol") {
                Some(os) => println!("{os}"),
                None => println!("(no installed system identified on this volume)"),
            }
            ExitCode::SUCCESS
        }
        other => {
            eprintln!("g6b: vfs: unknown subcommand `{other}` (scan|ls|cat|write|os)");
            ExitCode::from(2)
        }
    }
}

/// Every `--disk ID=PATH[:model]` on the command line, as one block service.
fn attached_disks(args: &[String]) -> Result<Option<g6b_kernel::VfsService>, String> {
    let mut svc = g6b_kernel::VfsService::new();
    let mut any = false;
    let mut it = args.iter();
    while let Some(a) = it.next() {
        if a != "--disk" {
            continue;
        }
        let spec = it.next().ok_or("--disk wants ID=PATH[:model]")?;
        let (id, rest) = spec
            .split_once('=')
            .ok_or_else(|| format!("--disk wants ID=PATH[:model], got `{spec}`"))?;
        // Only a `:` past a drive letter separates the model.
        let (path, model) = match rest.char_indices().find(|(i, c)| *c == ':' && *i > 1) {
            Some((i, _)) => (&rest[..i], &rest[i + 1..]),
            None => (rest, ""),
        };
        svc = svc.add_file(id, path, model)?;
        any = true;
    }
    Ok(any.then_some(svc))
}

/// Every `--volume ID=PATH[:role[:vendor]]` on the command line.
fn attached_volumes(args: &[String]) -> Result<Option<g6b_kernel::DirVolumes>, String> {
    let mut vols = g6b_kernel::DirVolumes::new();
    let mut any = false;
    let mut it = args.iter();
    while let Some(a) = it.next() {
        if a != "--volume" {
            continue;
        }
        let spec = it.next().ok_or("--volume wants ID=PATH[:role[:vendor]]")?;
        vols.parse_mount(spec)?;
        any = true;
    }
    Ok(any.then_some(vols))
}

fn run_zealcli(spec: &g6b_spec::BoardSpec, args: &[String]) -> ExitCode {
    if !spec.kernel.cli.enable {
        eprintln!("g6b: kernel.cli.enable is false in this BoardSpec");
        return ExitCode::from(1);
    }
    // `--volume ID=PATH[:role[:vendor]]` declares media the operator (or the
    // QEMU harness) attached, so the boot picker probes the same bytes the
    // machine was given instead of a table of hopes.
    let mut cli = match attached_volumes(args) {
        Ok(Some(vols)) => g6b_kernel::zealcli_session_with_volumes(spec, vols),
        Ok(None) => g6b_kernel::zealcli_session(spec),
        Err(e) => {
            eprintln!("g6b: {e}");
            return ExitCode::from(2);
        }
    };
    // `--disk ID=PATH[:model]` attaches a real block device (an image or a raw
    // disk), so `drv`, `mount`, `cd`, `vi` and `:w` work on actual partitions.
    match attached_disks(args) {
        Ok(Some(svc)) => cli.ports_mut().mounts = Some(Box::new(svc)),
        Ok(None) => {}
        Err(e) => {
            eprintln!("g6b: {e}");
            return ExitCode::from(2);
        }
    }
    let frames = flag_present(args, "--frames");
    let show = |cli: &g6b_kernel::ZealCli| {
        println!("{}", cli.render().join("\n"));
        println!();
    };
    // `--tick MS` advances the autoboot countdown before anything is typed, so
    // the unattended path is testable without waiting in real time.
    if let Some(ms) = flag_value(args, "--tick").and_then(|v| v.parse::<u32>().ok()) {
        cli.tick_ms(ms);
        if frames {
            show(&cli);
        }
    }
    if let Some(codes) = flag_value(args, "--keys") {
        for code in codes.split(',').filter(|c| !c.trim().is_empty()) {
            match code.trim().parse::<u16>() {
                Ok(c) => {
                    cli.keycode(c, true);
                    cli.keycode(c, false);
                }
                Err(_) => {
                    eprintln!("g6b: --keys wants Linux keycodes, not `{code}`");
                    return ExitCode::from(2);
                }
            }
            if frames {
                show(&cli);
            }
        }
    }
    let script: Option<Box<dyn BufRead>> = match flag_value(args, "--script") {
        Some("-") => Some(Box::new(BufReader::new(io::stdin()))),
        Some(path) => match fs::File::open(path) {
            Ok(f) => Some(Box::new(BufReader::new(f))),
            Err(e) => {
                eprintln!("g6b: {path}: {e}");
                return ExitCode::from(1);
            }
        },
        None => {
            if flag_present(args, "--keys") {
                None
            } else {
                Some(Box::new(BufReader::new(io::stdin())))
            }
        }
    };
    if let Some(reader) = script {
        for line in reader.lines() {
            let line = match line {
                Ok(l) => l,
                Err(e) => {
                    eprintln!("g6b: read: {e}");
                    return ExitCode::from(1);
                }
            };
            let (action, _) = cli.eval(&line);
            // Background work (a firmware transfer) advances one bounded step
            // per line, the way the timer tick advances it in the guest.
            cli.tick();
            if frames {
                show(&cli);
            }
            match action {
                g6b_kernel::ZealAction::Exit => break,
                g6b_kernel::ZealAction::LoadUi => {
                    println!("LOAD-UI (browser-ui takes the screen)");
                    break;
                }
                g6b_kernel::ZealAction::Reboot
                | g6b_kernel::ZealAction::Shutdown
                | g6b_kernel::ZealAction::LinuxHandoff => break,
                _ => {}
            }
        }
    }
    if !frames {
        show(&cli);
    }
    ExitCode::SUCCESS
}

fn serve_http(spec: &g6b_spec::BoardSpec, args: &[String]) -> ExitCode {
    if !spec.kernel.http.files.enable && !spec.kernel.http.serve {
        eprintln!("g6b: http-serve needs kernel.http.serve or http.files");
        return ExitCode::from(1);
    }
    let port: u16 = flag_value(args, "--port")
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    let listener = match TcpListener::bind(("127.0.0.1", port)) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("g6b: bind: {e}");
            return ExitCode::from(1);
        }
    };
    let bound = listener.local_addr().map(|a| a.port()).unwrap_or(port);
    {
        let mut err = std::io::stderr();
        let _ = writeln!(err, "HTTP-PORT {bound}");
        let _ = err.flush();
    }
    let router = g6b_http::Router::from_spec(spec);
    let mut store = g6b_pglite::StoreRegistry::from_spec(spec);
    let once = flag_present(args, "--once");
    loop {
        let (stream, _) = match listener.accept() {
            Ok(s) => s,
            Err(e) => {
                eprintln!("g6b: accept: {e}");
                return ExitCode::from(1);
            }
        };
        if let Err(e) = handle_http_conn(stream, &router, spec, Some(&mut store)) {
            eprintln!("g6b: http: {e}");
        }
        if once {
            break;
        }
    }
    ExitCode::SUCCESS
}

const HTTP_REQUEST_LIMIT: usize = 8192;
const HTTP_IO_TIMEOUT: Duration = Duration::from_secs(1);

fn http_invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

fn store_http_limit(spec: &g6b_spec::BoardSpec) -> usize {
    if !spec.kernel.store.enable {
        return HTTP_REQUEST_LIMIT;
    }
    let s = &spec.kernel.store;
    let body = s
        .max_sql_bytes
        .saturating_add(s.max_param_bytes)
        .max(s.max_result_bytes)
        .saturating_add(1024) as usize;
    body.max(HTTP_REQUEST_LIMIT)
}

fn path_is_store(raw: &[u8]) -> bool {
    if raw.is_empty() {
        return false;
    }
    if raw.starts_with(g6b_http::h2::PREFACE) || raw[0] == 0 {
        return raw.windows(12).any(|w| w == b"/bios/store");
    }
    let line = raw.split(|&b| b == b'\n').next().unwrap_or(&[]);
    let s = std::str::from_utf8(line)
        .unwrap_or("")
        .trim_end_matches('\r');
    s.split_whitespace()
        .nth(1)
        .is_some_and(|p| p.starts_with("/bios/store"))
}

fn request_limit(raw: &[u8], spec: Option<&g6b_spec::BoardSpec>) -> usize {
    match spec {
        Some(spec) if path_is_store(raw) => store_http_limit(spec),
        _ => HTTP_REQUEST_LIMIT,
    }
}

fn bounded_http_len(len: usize, limit: usize) -> io::Result<Option<usize>> {
    if len > limit {
        Err(http_invalid(&format!("request exceeds {limit} bytes")))
    } else {
        Ok(Some(len))
    }
}

#[cfg(test)]
fn http_request_len(raw: &[u8]) -> io::Result<Option<usize>> {
    http_request_len_at(raw, HTTP_REQUEST_LIMIT)
}

fn http_request_len_at(raw: &[u8], limit: usize) -> io::Result<Option<usize>> {
    if raw.is_empty() {
        return Ok(None);
    }
    if matches!(raw[0], 0x16 | 0x17) {
        if raw.len() < 5 {
            return Ok(None);
        }
        if raw[1] != 3 {
            return Err(http_invalid("unsupported TLS record version"));
        }
        return bounded_http_len(5 + usize::from(u16::from_be_bytes([raw[3], raw[4]])), limit);
    }
    let preface = g6b_http::h2::PREFACE;
    if raw.len() < preface.len() && preface.starts_with(raw) {
        return Ok(None);
    }
    if raw.starts_with(preface) || raw[0] == 0 {
        return http2_request_len(raw, limit);
    }
    let Some(end) = raw.windows(4).position(|w| w == b"\r\n\r\n") else {
        return Ok(None);
    };
    let head = std::str::from_utf8(&raw[..end]).map_err(|_| http_invalid("http1 header utf8"))?;
    let mut content_len = None;
    for line in head.split("\r\n").skip(1) {
        let (name, value) = line
            .split_once(':')
            .ok_or_else(|| http_invalid("http1 header"))?;
        if name.trim().eq_ignore_ascii_case("transfer-encoding") {
            return Err(http_invalid("transfer-encoding is unsupported"));
        }
        if name.trim().eq_ignore_ascii_case("content-length") {
            let value = value.trim();
            if content_len.is_some()
                || value.is_empty()
                || !value.bytes().all(|b| b.is_ascii_digit())
            {
                return Err(http_invalid("invalid or duplicate content-length"));
            }
            content_len = Some(
                value
                    .parse::<usize>()
                    .map_err(|_| http_invalid("invalid content-length"))?,
            );
        }
    }
    let len = (end + 4)
        .checked_add(content_len.unwrap_or(0))
        .ok_or_else(|| http_invalid("content-length overflow"))?;
    bounded_http_len(len, limit)
}

fn http2_request_len(raw: &[u8], limit: usize) -> io::Result<Option<usize>> {
    let mut offset = if raw.starts_with(g6b_http::h2::PREFACE) {
        g6b_http::h2::PREFACE.len()
    } else {
        0
    };
    let mut stream = None;
    let mut headers_done = false;
    let mut stream_done = false;
    while raw.len() >= offset + 9 {
        let frame = &raw[offset..];
        let len =
            (usize::from(frame[0]) << 16) | (usize::from(frame[1]) << 8) | usize::from(frame[2]);
        let end = offset + 9 + len;
        bounded_http_len(end, limit)?;
        if raw.len() < end {
            return Ok(None);
        }
        let id = u32::from_be_bytes([frame[5], frame[6], frame[7], frame[8]]) & 0x7fff_ffff;
        match frame[3] {
            1 => {
                if id == 0 || stream.is_some() {
                    return Err(http_invalid("http2 expects one request stream"));
                }
                stream = Some(id);
                headers_done = frame[4] & 4 != 0;
                stream_done = frame[4] & 1 != 0;
            }
            9 => {
                if stream != Some(id) || headers_done {
                    return Err(http_invalid("unexpected http2 continuation"));
                }
                headers_done = frame[4] & 4 != 0;
            }
            0 => {
                if stream != Some(id) || !headers_done || stream_done {
                    return Err(http_invalid("unexpected http2 data"));
                }
                stream_done = frame[4] & 1 != 0;
            }
            _ => {}
        }
        if headers_done && stream_done {
            return Ok(Some(end));
        }
        offset = end;
    }
    Ok(None)
}

fn http_time_left(deadline: Instant) -> io::Result<Duration> {
    deadline
        .checked_duration_since(Instant::now())
        .filter(|d| !d.is_zero())
        .ok_or_else(|| io::Error::new(io::ErrorKind::TimedOut, "HTTP I/O deadline exceeded"))
}

fn read_http_request(
    stream: &mut TcpStream,
    timeout: Duration,
    spec: Option<&g6b_spec::BoardSpec>,
) -> io::Result<Vec<u8>> {
    let deadline = Instant::now() + timeout;
    let mut cap = HTTP_REQUEST_LIMIT;
    let mut buf = vec![0u8; cap];
    let mut used = 0;
    loop {
        let limit = request_limit(&buf[..used], spec);
        if limit > cap {
            cap = limit;
            buf.resize(cap, 0);
        }
        if let Some(len) = http_request_len_at(&buf[..used], limit)? {
            if used >= len {
                return Ok(buf[..len].to_vec());
            }
        }
        if used == buf.len() {
            return Err(http_invalid(&format!("request exceeds {limit} bytes")));
        }
        stream.set_read_timeout(Some(http_time_left(deadline)?))?;
        match stream.read(&mut buf[used..]) {
            Ok(0) => {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "incomplete request",
                ));
            }
            Ok(n) => used += n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
}

fn write_http_response(
    stream: &mut TcpStream,
    mut response: &[u8],
    timeout: Duration,
) -> io::Result<()> {
    let deadline = Instant::now() + timeout;
    while !response.is_empty() {
        stream.set_write_timeout(Some(http_time_left(deadline)?))?;
        match stream.write(response) {
            Ok(0) => {
                return Err(io::Error::new(
                    io::ErrorKind::WriteZero,
                    "HTTP write stalled",
                ))
            }
            Ok(n) => response = &response[n..],
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    Ok(())
}

fn handle_http_conn(
    mut stream: TcpStream,
    router: &g6b_http::Router,
    spec: &g6b_spec::BoardSpec,
    store: Option<&mut dyn g6b_pglite::StorePort>,
) -> Result<(), String> {
    let request =
        read_http_request(&mut stream, HTTP_IO_TIMEOUT, Some(spec)).map_err(|e| e.to_string())?;
    let mut response = router.handle_bytes_store(&request, store)?;
    if response.starts_with(b"HTTP/1.") {
        if let Some(end) = response.windows(2).position(|w| w == b"\r\n") {
            response.splice(end + 2..end + 2, b"Connection: close\r\n".iter().copied());
        }
    }
    write_http_response(&mut stream, &response, HTTP_IO_TIMEOUT).map_err(|e| e.to_string())
}

fn serve_holyc(spec: &g6b_spec::BoardSpec, args: &[String], loopback: bool) -> ExitCode {
    let mut prog = match g6b_kernel::load_program(spec) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("g6b: {e}");
            return ExitCode::from(1);
        }
    };
    if spec.holyc.fast_init {
        if let Ok(out) = prog.call("HolycInit") {
            eprint!("{out}");
        }
    }
    let default_port = spec.holyc_tcp_port().unwrap_or(2222);
    let port: u16 = flag_value(args, "--port")
        .and_then(|s| s.parse().ok())
        .unwrap_or(default_port);
    let listener = match TcpListener::bind(("127.0.0.1", port)) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("g6b: bind: {e}");
            return ExitCode::from(1);
        }
    };
    let bound = listener.local_addr().map(|a| a.port()).unwrap_or(port);
    {
        let mut err = std::io::stderr();
        let _ = writeln!(err, "HOLYC-PORT {bound}");
        if loopback {
            let _ = writeln!(err, "LOOPBACK-PORT {bound}");
        }
        let _ = err.flush();
    }
    let banner = if loopback {
        g6b_kernel::loopback_banner(spec)
    } else {
        g6b_kernel::repl_banner(spec)
    };
    let once = flag_present(args, "--once");
    loop {
        let (stream, _) = match listener.accept() {
            Ok(s) => s,
            Err(e) => {
                eprintln!("g6b: accept: {e}");
                return ExitCode::from(1);
            }
        };
        let mut session = prog.clone();
        if let Err(e) = handle_conn(stream, &mut session, &banner) {
            eprintln!("g6b: session: {e}");
        }
        if once {
            break;
        }
    }
    ExitCode::SUCCESS
}

fn handle_conn(
    stream: std::net::TcpStream,
    prog: &mut g6b_holyc::Program,
    banner: &str,
) -> Result<(), String> {
    stream.set_nodelay(true).map_err(|e| e.to_string())?;
    let mut writer = stream.try_clone().map_err(|e| e.to_string())?;
    writeln!(writer, "{banner}").map_err(|e| e.to_string())?;
    writer.flush().map_err(|e| e.to_string())?;
    let reader = BufReader::new(stream);
    for line in reader.lines() {
        let line = line.map_err(|e| e.to_string())?;
        match g6b_kernel::repl_line(prog, &line).map_err(|e| e.to_string())? {
            ReplResult::Exit => break,
            ReplResult::Output(s) => {
                write!(writer, "{s}").map_err(|e| e.to_string())?;
                if !s.ends_with('\n') {
                    writeln!(writer).map_err(|e| e.to_string())?;
                }
                writer.flush().map_err(|e| e.to_string())?;
            }
        }
    }
    Ok(())
}

fn flag_present(args: &[String], name: &str) -> bool {
    args.iter().any(|a| a == name)
}

fn flag_value<'a>(args: &'a [String], name: &str) -> Option<&'a str> {
    let mut i = 0;
    while i < args.len() {
        if args[i] == name {
            return args.get(i + 1).map(String::as_str);
        }
        if let Some(v) = args[i].strip_prefix(&format!("{name}=")) {
            return Some(v);
        }
        i += 1;
    }
    None
}

fn load_spec(path: Option<&Path>) -> Result<g6b_spec::BoardSpec, ExitCode> {
    let Some(p) = path else {
        return Ok(g6b_spec::BoardSpec::default());
    };
    let s = fs::read_to_string(p).map_err(|e| {
        eprintln!("g6b: read {}: {e}", p.display());
        ExitCode::from(1)
    })?;
    g6b_spec::BoardSpec::from_json_str(&s).map_err(|e| {
        eprintln!("g6b: spec {}: {e}", p.display());
        ExitCode::from(1)
    })
}

fn css_paint(args: &[String]) -> ExitCode {
    let out = flag_value(args, "--out").unwrap_or("out/ui.ppm");
    let spec_path = flag_value(args, "--spec").map(Path::new);
    let spec = match load_spec(spec_path) {
        Ok(s) => s,
        Err(c) => return c,
    };
    match g6b_kernel::ui_ppm(&spec) {
        Ok(ppm) => {
            if let Some(parent) = Path::new(out).parent() {
                if !parent.as_os_str().is_empty() {
                    let _ = fs::create_dir_all(parent);
                }
            }
            if let Err(e) = fs::write(out, ppm) {
                eprintln!("g6b css-paint: write {out}: {e}");
                return ExitCode::from(1);
            }
            eprintln!("g6b: wrote {out}");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("g6b css-paint: {e}");
            ExitCode::from(1)
        }
    }
}

fn css_render(args: &[String]) -> ExitCode {
    let html = flag_value(args, "--html");
    let css = flag_value(args, "--css");
    let fixture = flag_value(args, "--fixture");
    let (html, css) = match (html, css, fixture) {
        (Some(h), Some(c), None) => (fs::read_to_string(h), fs::read_to_string(c)),
        (None, None, Some(f)) => load_render_fixture(f),
        _ => {
            eprintln!("g6b css-render: --html + --css, or --fixture; [--modern] [--assets DIR] [--w N] [--h N] [--out FILE]");
            return ExitCode::from(2);
        }
    };
    let html = match html {
        Ok(s) => s,
        Err(e) => {
            eprintln!("g6b css-render: read html: {e}");
            return ExitCode::from(1);
        }
    };
    let css = match css {
        Ok(s) => s,
        Err(e) => {
            eprintln!("g6b css-render: read css: {e}");
            return ExitCode::from(1);
        }
    };

    let w = flag_value(args, "--w")
        .and_then(|s| s.parse().ok())
        .unwrap_or(128);
    let h = flag_value(args, "--h")
        .and_then(|s| s.parse().ok())
        .unwrap_or(96);

    if flag_present(args, "--modern") {
        let fonts = match g6b_ttf::FontSet::default_set() {
            Ok(f) => f,
            Err(e) => {
                eprintln!("g6b css-render: fonts: {e:?}");
                return ExitCode::from(1);
            }
        };
        let assets = match load_asset_dir(args) {
            Ok(a) => a,
            Err(e) => {
                eprintln!("g6b css-render: assets: {e}");
                return ExitCode::from(1);
            }
        };
        match g6b_css::render32::render32(&html, &css, w, h, &assets, &fonts) {
            Ok(out) => {
                let path = flag_value(args, "--out").unwrap_or("out/css-render.ppm");
                if let Some(parent) = Path::new(path).parent() {
                    if !parent.as_os_str().is_empty() {
                        let _ = fs::create_dir_all(parent);
                    }
                }
                if let Err(e) = fs::write(path, out.canvas.to_ppm()) {
                    eprintln!("g6b css-render: write {path}: {e}");
                    return ExitCode::from(1);
                }
                eprintln!("g6b: wrote {path}");
                ExitCode::SUCCESS
            }
            Err(e) => {
                eprintln!("g6b css-render: {e}");
                ExitCode::from(1)
            }
        }
    } else {
        match g6b_css::render::render_to_canvas(&html, &css, w, h) {
            Ok(canvas) => {
                let out = flag_value(args, "--out").unwrap_or("out/css-render.ppm");
                if let Some(parent) = Path::new(out).parent() {
                    if !parent.as_os_str().is_empty() {
                        let _ = fs::create_dir_all(parent);
                    }
                }
                if let Err(e) = fs::write(out, canvas.to_ppm()) {
                    eprintln!("g6b css-render: write {out}: {e}");
                    return ExitCode::from(1);
                }
                eprintln!("g6b: wrote {out}");
                ExitCode::SUCCESS
            }
            Err(e) => {
                eprintln!("g6b css-render: {e}");
                ExitCode::from(1)
            }
        }
    }
}

fn load_render_fixture(
    f: &str,
) -> (
    Result<String, std::io::Error>,
    Result<String, std::io::Error>,
) {
    // A fixture is a JSON file with { html, css } or a directory containing
    // `fixture.html` and `fixture.css`.
    let path = Path::new(f);
    let (html_path, css_path) = if path.is_dir() {
        (path.join("fixture.html"), path.join("fixture.css"))
    } else {
        (path.with_extension("html"), path.with_extension("css"))
    };
    (fs::read_to_string(html_path), fs::read_to_string(css_path))
}

fn load_asset_dir(args: &[String]) -> Result<AssetMap, String> {
    let Some(dir) = flag_value(args, "--assets") else {
        return Ok(AssetMap::new());
    };
    let mut items = Vec::new();
    for entry in fs::read_dir(dir).map_err(|e| format!("read assets dir {dir}: {e}"))? {
        let entry = entry.map_err(|e| e.to_string())?;
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        let ext = path.extension().and_then(|s| s.to_str()).unwrap_or("");
        if !matches!(ext, "png" | "svg") {
            continue;
        }
        let name = path
            .file_name()
            .and_then(|s| s.to_str())
            .ok_or_else(|| "bad asset filename".to_string())?
            .to_string();
        let bytes = fs::read(&path).map_err(|e| format!("read {name}: {e}"))?;
        items.push((name, bytes));
    }
    load_assets(items)
}

fn ppm_diff(args: &[String]) -> ExitCode {
    let a = flag_value(args, "--actual");
    let g = flag_value(args, "--golden");
    let tol = flag_value(args, "--tolerance")
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    let (Some(a), Some(g)) = (a, g) else {
        eprintln!("g6b ppm-diff: --actual FILE --golden FILE [--tolerance N]");
        return ExitCode::from(2);
    };
    let actual = match fs::read(a) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("g6b ppm-diff: read {a}: {e}");
            return ExitCode::from(1);
        }
    };
    let golden = match fs::read(g) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("g6b ppm-diff: read {g}: {e}");
            return ExitCode::from(1);
        }
    };
    match g6b_gr::canvas::compare_ppm(&actual, &golden, tol) {
        Some(d) if d.same => {
            println!(
                "OK: {} pixels, max_delta={}",
                d.total_pixels, d.max_channel_delta
            );
            ExitCode::SUCCESS
        }
        Some(d) => {
            eprintln!(
                "g6b ppm-diff: FAIL different={}/{} max_delta={} bad={} ratio={:.4}",
                d.different_pixels, d.total_pixels, d.max_channel_delta, d.bad_pixels, d.ratio
            );
            ExitCode::from(1)
        }
        None => {
            eprintln!("g6b ppm-diff: could not parse one of the PPM files");
            ExitCode::from(1)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn socket_pair() -> (TcpStream, TcpStream) {
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let client = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let (server, _) = listener.accept().unwrap();
        (client, server)
    }

    #[test]
    fn http1_framing_waits_for_headers_and_counts_body_bytes() {
        let head = b"GET /bios/menu HTTP/1.1\r\nHost: localhost\r\ncOnTeNt-LeNgTh: 4\r\n\r\n";
        for n in 0..head.len() {
            assert_eq!(http_request_len(&head[..n]).unwrap(), None, "split {n}");
        }
        assert_eq!(http_request_len(head).unwrap(), Some(head.len() + 4));
        let request = [head.as_slice(), b"ABCDignored"].concat();
        assert_eq!(http_request_len(&request).unwrap(), Some(head.len() + 4));
    }

    #[test]
    fn http1_rejects_ambiguous_and_unbounded_bodies() {
        for header in [
            "Content-Length: -1",
            "Content-Length: +1",
            "Content-Length:",
            "Content-Length: 18446744073709551615",
            "Content-Length: 999999999999999999999999",
            "Content-Length: 8192",
            "Content-Length: 1\r\nContent-Length: 1",
            "Content-Length: 1\r\nContent-Length: 2",
            "Transfer-Encoding: chunked",
            "Content-Length: 4\r\nTransfer-Encoding: chunked",
        ] {
            let request = format!("GET /bios/menu HTTP/1.1\r\n{header}\r\n\r\n");
            assert!(http_request_len(request.as_bytes()).is_err(), "{header}");
        }
        let mut request = b"GET /bios/menu HTTP/1.1\r\nX-Padding: ".to_vec();
        request.resize(HTTP_REQUEST_LIMIT - 4, b'x');
        request.extend(b"\r\n\r\n");
        assert_eq!(
            http_request_len(&request).unwrap(),
            Some(HTTP_REQUEST_LIMIT)
        );
        request.insert(request.len() - 4, b'x');
        assert!(http_request_len(&request).is_err());
    }

    #[test]
    fn store_path_accepts_9kib_query_body() {
        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"kernel":{"http":{"enable":true},"store":{"enable":true}}}"#,
        )
        .unwrap();
        let body = vec![b'x'; 9000];
        let mut store_req = format!(
            "POST /bios/store/00000000-0000-4000-8000-000000000001/query HTTP/1.1\r\nContent-Length: {}\r\n\r\n",
            body.len()
        )
        .into_bytes();
        store_req.extend_from_slice(&body);
        let limit = store_http_limit(&spec);
        assert!(limit > HTTP_REQUEST_LIMIT);
        assert_eq!(
            http_request_len_at(&store_req, limit).unwrap(),
            Some(store_req.len())
        );
        let mut menu = format!(
            "POST /bios/menu HTTP/1.1\r\nContent-Length: {}\r\n\r\n",
            body.len()
        )
        .into_bytes();
        menu.extend_from_slice(&body);
        let err = http_request_len(&menu).unwrap_err();
        assert!(err.to_string().contains("8192"), "{err}");
    }

    #[test]
    fn standalone_tls_record_lengths_survive_fragmentation() {
        for kind in [0x16, 0x17] {
            let record = [kind, 3, 3, 0, 4, 1, 0, 0, 0];
            for n in 0..5 {
                assert_eq!(http_request_len(&record[..n]).unwrap(), None);
            }
            for n in 5..=record.len() {
                assert_eq!(http_request_len(&record[..n]).unwrap(), Some(record.len()));
            }
        }
        assert!(http_request_len(&[0x17, 3, 3, 0xff, 0xff]).is_err());
    }

    #[test]
    fn http2_waits_for_preface_frames_and_end_stream() {
        let request = g6b_http::h2::client_get("/bios/menu");
        for raw in [request.as_slice(), &request[g6b_http::h2::PREFACE.len()..]] {
            for n in 0..raw.len() {
                assert_eq!(http_request_len(&raw[..n]).unwrap(), None, "split {n}");
            }
            assert_eq!(http_request_len(raw).unwrap(), Some(raw.len()));
        }
        let mut body_request = request.clone();
        body_request[g6b_http::h2::PREFACE.len() + 4] = 4;
        assert_eq!(http_request_len(&body_request).unwrap(), None);
        body_request.extend([0, 0, 4, 0, 1, 0, 0, 0, 1, b'A', b'B', b'C', b'D']);
        assert_eq!(
            http_request_len(&body_request).unwrap(),
            Some(body_request.len())
        );
        assert!(http_request_len(&[0, 0x20, 0, 1, 5, 0, 0, 0, 1]).is_err());
    }

    #[test]
    fn http2_waits_for_continuation_after_end_stream() {
        let raw = [
            g6b_http::h2::PREFACE,
            &[0, 0, 0, 4, 0, 0, 0, 0, 0],
            &[0, 0, 1, 1, 1, 0, 0, 0, 1, 0x82],
            &[0, 0, 1, 9, 4, 0, 0, 0, 1, 0x84],
        ]
        .concat();
        for n in 0..raw.len() {
            assert_eq!(http_request_len(&raw[..n]).unwrap(), None);
        }
        assert_eq!(http_request_len(&raw).unwrap(), Some(raw.len()));
    }

    #[test]
    fn reader_rejects_eof_and_over_limit_headers() {
        let (mut client, mut server) = socket_pair();
        client.write_all(b"GET /bios/menu HTTP/1.1\r\n").unwrap();
        client.shutdown(std::net::Shutdown::Write).unwrap();
        assert_eq!(
            read_http_request(&mut server, HTTP_IO_TIMEOUT, None)
                .unwrap_err()
                .kind(),
            io::ErrorKind::UnexpectedEof
        );
        let (mut client, mut server) = socket_pair();
        client.write_all(&[b'x'; HTTP_REQUEST_LIMIT]).unwrap();
        assert_eq!(
            read_http_request(&mut server, HTTP_IO_TIMEOUT, None)
                .unwrap_err()
                .kind(),
            io::ErrorKind::InvalidData
        );
    }

    fn assert_timeout(error: io::Error) {
        assert!(
            matches!(
                error.kind(),
                io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
            ),
            "{error}"
        );
    }

    #[test]
    fn idle_socket_has_a_read_deadline() {
        let (_client, mut server) = socket_pair();
        assert_timeout(
            read_http_request(&mut server, Duration::from_millis(100), None).unwrap_err(),
        );
        assert!(server.read_timeout().unwrap().is_some());
    }

    #[test]
    fn slow_headers_cannot_extend_the_read_deadline() {
        let (mut client, mut server) = socket_pair();
        client.set_nodelay(true).unwrap();
        let sender = std::thread::spawn(move || {
            for _ in 0..100 {
                if client.write_all(b"G").is_err() {
                    break;
                }
                std::thread::sleep(Duration::from_millis(20));
            }
        });
        let start = Instant::now();
        assert_timeout(
            read_http_request(&mut server, Duration::from_millis(150), None).unwrap_err(),
        );
        drop(server);
        sender.join().unwrap();
        assert!(start.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn writes_use_timeouts_and_expired_deadlines_send_nothing() {
        let (mut client, mut server) = socket_pair();
        assert_timeout(write_http_response(&mut server, b"expired", Duration::ZERO).unwrap_err());
        write_http_response(&mut server, b"ready", HTTP_IO_TIMEOUT).unwrap();
        assert!(server.write_timeout().unwrap().is_some());
        drop(server);
        client.set_read_timeout(Some(HTTP_IO_TIMEOUT)).unwrap();
        let mut response = Vec::new();
        client.read_to_end(&mut response).unwrap();
        assert_eq!(response, b"ready");
    }
}
