// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Host CLI: generate ZealOS, boot HolyC+DOM+JS, dual-band HolyC REPL.

#![allow(missing_docs)]

use std::env;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use g6b_holyc::ReplResult;

fn main() -> ExitCode {
    let mut args = env::args().skip(1).collect::<Vec<_>>();
    if args.is_empty() {
        eprintln!(
            "usage: g6b <design-compile|display|boot|tohtml|holyc-eval|holyc-serve|http-serve|loopback|qemu-args|elf|smoke|gr|display-proxy> \
             [--spec FILE] [--out DIR|FILE] [--port N] [--once]"
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
                println!("{}", g6b_kernel::boot(&spec));
                ExitCode::SUCCESS
            }
        },
        "qemu-args" => match load_spec(spec_path.as_deref()) {
            Err(c) => c,
            Ok(spec) => {
                println!("{}", g6b_kernel::qemu_dual_band_argv(&spec).join(" "));
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
        "smoke" => match load_spec(spec_path.as_deref()) {
            Err(c) => c,
            Ok(spec) => match g6b_elf::smoke(&spec) {
                Ok(s) => {
                    print!("{}", s.console);
                    if !s.console.ends_with('\n') {
                        println!();
                    }
                    eprintln!(
                        "g6b: smoke halt={:?} steps={} satp={:#x}",
                        s.halt, s.steps, s.satp
                    );
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
                match g6b_elf::write_elf(&spec, &path) {
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
    let once = flag_present(args, "--once");
    loop {
        let (mut stream, _) = match listener.accept() {
            Ok(s) => s,
            Err(e) => {
                eprintln!("g6b: accept: {e}");
                return ExitCode::from(1);
            }
        };
        let mut buf = vec![0u8; 8192];
        match std::io::Read::read(&mut stream, &mut buf) {
            Ok(0) => {}
            Ok(n) => match router.handle_bytes(&buf[..n]) {
                Ok(resp) => {
                    let _ = stream.write_all(&resp);
                }
                Err(e) => eprintln!("g6b: http: {e}"),
            },
            Err(e) => eprintln!("g6b: read: {e}"),
        }
        if once {
            break;
        }
    }
    ExitCode::SUCCESS
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
