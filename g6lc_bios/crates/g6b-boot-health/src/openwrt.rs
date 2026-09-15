// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Thin OpenWrt adapter: files only, no ubus/UCI/procd crate.

use crate::{Readiness, WatchdogDevice, WatchdogStamp};
use g6b_bootctl::LinuxReadiness;
use std::path::{Path, PathBuf};

/// File-based OpenWrt readiness. The core never talks to procd.
pub struct OpenWrtAdapter {
    root: PathBuf,
}

impl OpenWrtAdapter {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    fn exists(&self, rel: &str) -> bool {
        self.root.join(rel).is_file()
    }

    /// Read-only root is allowed: `/etc/openwrt_release` or an overlay stamp.
    fn root_ready(root: &Path) -> bool {
        root.join("etc/openwrt_release").is_file() || root.join("overlay/.fs_state").is_file()
    }
}

impl Readiness for OpenWrtAdapter {
    fn report(&self) -> LinuxReadiness {
        LinuxReadiness {
            selected_root_ready: Self::root_ready(&self.root),
            required_services_ready: self.exists("run/g6b-boot-health.services"),
            watchdog_owned: {
                let dev = self.root.join("dev/watchdog");
                if dev.is_file() {
                    WatchdogDevice::inspect(&dev).is_ok_and(|s| s.owned())
                } else {
                    WatchdogStamp::from_path(&self.root.join("run/g6b-boot-health.watchdog"))
                        .is_some_and(WatchdogStamp::owned)
                }
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn tree() -> std::path::PathBuf {
        let path = std::env::temp_dir().join(format!(
            "g6b-owrt-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(path.join("etc")).unwrap();
        fs::create_dir_all(path.join("run")).unwrap();
        fs::create_dir_all(path.join("overlay")).unwrap();
        path
    }

    #[test]
    fn missing_release_is_not_root_ready() {
        let root = tree();
        let report = OpenWrtAdapter::new(&root).report();
        assert!(!report.selected_root_ready);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn release_or_overlay_counts_as_readonly_root() {
        let root = tree();
        fs::write(root.join("etc/openwrt_release"), "DISTRIB_ID='OpenWrt'\n").unwrap();
        assert!(OpenWrtAdapter::new(&root).report().selected_root_ready);
        fs::remove_file(root.join("etc/openwrt_release")).unwrap();
        fs::write(root.join("overlay/.fs_state"), "ready\n").unwrap();
        assert!(OpenWrtAdapter::new(&root).report().selected_root_ready);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn services_and_watchdog_are_explicit_stamps() {
        let root = tree();
        fs::write(root.join("etc/openwrt_release"), "ok\n").unwrap();
        let adapter = OpenWrtAdapter::new(&root);
        assert!(!adapter.report().required_services_ready);
        assert!(!adapter.report().watchdog_owned);
        fs::write(root.join("run/g6b-boot-health.services"), "ok\n").unwrap();
        fs::write(root.join("run/g6b-boot-health.watchdog"), "ok\n").unwrap();
        assert!(!adapter.report().watchdog_owned, "stamp without nowayout");
        fs::write(
            root.join("run/g6b-boot-health.watchdog"),
            "nowayout=1\nkeepalive=1\n",
        )
        .unwrap();
        let ready = adapter.report();
        assert!(ready.selected_root_ready && ready.required_services_ready && ready.watchdog_owned);
        fs::write(
            root.join("run/g6b-boot-health.watchdog"),
            "nowayout=0\nmagic_close=1\nkeepalive=1\n",
        )
        .unwrap();
        assert!(!adapter.report().watchdog_owned);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn openwrt_dev_watchdog_requires_nowayout_and_running() {
        let root = tree();
        fs::write(root.join("etc/openwrt_release"), "ok\n").unwrap();
        fs::write(root.join("run/g6b-boot-health.services"), "ok\n").unwrap();
        let path = root.join("dev/watchdog");
        WatchdogDevice::create_mock(&path, true).unwrap();
        let adapter = OpenWrtAdapter::new(&root);
        assert!(
            !adapter.report().watchdog_owned,
            "stopped nowayout mock is not armed"
        );
        {
            let mut wd = WatchdogDevice::open_path(&path).unwrap();
            wd.ioctl(crate::WdIoctl::Keepalive).unwrap();
            wd.close().unwrap();
        }
        assert!(adapter.report().watchdog_owned);
        WatchdogDevice::create_mock(&path, false).unwrap();
        {
            let mut wd = WatchdogDevice::open_path(&path).unwrap();
            wd.write(b"V").unwrap();
            wd.close().unwrap();
        }
        assert!(!adapter.report().watchdog_owned);
        let _ = fs::remove_dir_all(root);
    }
}
