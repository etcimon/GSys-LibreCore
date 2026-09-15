// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Linux userspace helper. Acknowledges one pending G6BH Linux attempt.
//! It never enables autoboot or writes firmware slots.

#![allow(missing_docs)]

use g6b_boot_health::{
    acknowledge, decode_handoff, scan_path, HealthHandoff, JournalFile, OpenWrtAdapter,
    StaticReadiness, WatchdogDevice,
};
use g6b_bootctl::LinuxReadiness;
use std::env;
use std::path::Path;
use std::process::ExitCode;

fn flag(args: &[String], name: &str) -> bool {
    args.iter().any(|a| a == name)
}

fn opt<'a>(args: &'a [String], name: &str) -> Option<&'a str> {
    args.windows(2)
        .find(|w| w[0] == name)
        .map(|w| w[1].as_str())
}

fn open_journal(journal: &str, args: &[String]) -> Result<JournalFile, String> {
    if opt(args, "--dtb").is_some() && opt(args, "--dt-root").is_some() {
        return Err("use only one of --dtb or --dt-root".into());
    }
    if let Some(dtb) = opt(args, "--dtb") {
        let bytes = std::fs::read(dtb).map_err(|e| format!("dtb: {e}"))?;
        let handoff = decode_handoff(&bytes).map_err(|e| format!("dtb: {e:?}"))?;
        return JournalFile::from_handoff(journal, handoff).map_err(|e| format!("journal: {e:?}"));
    }
    if let Some(root) = opt(args, "--dt-root") {
        let handoff =
            HealthHandoff::from_dt_root(Path::new(root)).map_err(|e| format!("dt-root: {e:?}"))?;
        return JournalFile::from_handoff(journal, handoff).map_err(|e| format!("journal: {e:?}"));
    }
    JournalFile::bios_window(journal).map_err(|e| format!("journal: {e}"))
}

fn main() -> ExitCode {
    let args: Vec<String> = env::args().skip(1).collect();
    if args.is_empty() || flag(&args, "--help") {
        eprintln!(
            "g6b-boot-health --journal PATH [--dtb FILE|--dt-root DIR] [--openwrt-root DIR] [--root-ready] [--services-ready] [--watchdog-owned|--watchdog FILE]"
        );
        eprintln!("g6b-boot-health --scan DISK");
        return ExitCode::from(2);
    }
    if let Some(disk) = opt(&args, "--scan") {
        return match scan_path(disk) {
            Ok(vols) => {
                for vol in vols {
                    eprintln!(
                        "part {} start={} len={} table={} name={} payload={:?} role={:?} executable={}",
                        vol.index,
                        vol.start,
                        vol.len,
                        vol.table_kind,
                        vol.name,
                        vol.payload,
                        vol.role,
                        vol.executable()
                    );
                    for file in &vol.artifacts {
                        eprintln!(
                            "  file {} payload={:?} role={:?} executable={}",
                            file.path,
                            file.payload,
                            file.role,
                            file.executable()
                        );
                    }
                }
                ExitCode::SUCCESS
            }
            Err(error) => {
                eprintln!("g6b-boot-health: scan: {error}");
                ExitCode::from(1)
            }
        };
    }
    let Some(journal) = opt(&args, "--journal") else {
        eprintln!("g6b-boot-health: --journal is required");
        return ExitCode::from(2);
    };
    let mut storage = match open_journal(journal, &args) {
        Ok(storage) => storage,
        Err(message) => {
            eprintln!("g6b-boot-health: {message}");
            return ExitCode::from(1);
        }
    };
    let result = if let Some(root) = opt(&args, "--openwrt-root") {
        acknowledge(&mut storage, &OpenWrtAdapter::new(root))
    } else {
        if flag(&args, "--watchdog-owned") && opt(&args, "--watchdog").is_some() {
            eprintln!("g6b-boot-health: use only one of --watchdog-owned or --watchdog");
            return ExitCode::from(2);
        }
        let watchdog_owned = if let Some(path) = opt(&args, "--watchdog") {
            match WatchdogDevice::inspect(Path::new(path)) {
                Ok(status) => status.owned(),
                Err(error) => {
                    eprintln!("g6b-boot-health: watchdog: {error}");
                    return ExitCode::from(1);
                }
            }
        } else {
            flag(&args, "--watchdog-owned")
        };
        acknowledge(
            &mut storage,
            &StaticReadiness {
                inner: LinuxReadiness {
                    selected_root_ready: flag(&args, "--root-ready"),
                    required_services_ready: flag(&args, "--services-ready"),
                    watchdog_owned,
                },
            },
        )
    };
    match result {
        Ok(()) => {
            eprintln!("g6b-boot-health: acknowledged pending Linux attempt");
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("g6b-boot-health: {error:?}");
            ExitCode::from(1)
        }
    }
}
