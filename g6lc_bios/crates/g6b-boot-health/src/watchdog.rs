// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Linux-generic watchdog ownership stamp.
//!
//! `nowayout` must be set before the helper claims `watchdog_owned`. A
//! magic-close (`V`) of a disarmable watchdog is an unmonitored gap and
//! is not ownership. Keepalive alone is not an acknowledgement.

use std::path::Path;

/// Parsed `run/g6b-boot-health.watchdog` (or an equivalent sysfs/file probe).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct WatchdogStamp {
    pub nowayout: bool,
    pub magic_close: bool,
    pub keepalive: bool,
}

impl WatchdogStamp {
    /// `key=value` lines. Unknown keys are ignored. Missing file is `None`.
    pub fn parse(text: &str) -> Self {
        let mut stamp = Self::default();
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let Some((key, value)) = line.split_once('=') else {
                continue;
            };
            let on = matches!(value.trim(), "1" | "true" | "yes");
            match key.trim() {
                "nowayout" => stamp.nowayout = on,
                "magic_close" => stamp.magic_close = on,
                "keepalive" => stamp.keepalive = on,
                _ => {}
            }
        }
        stamp
    }

    pub fn from_path(path: &Path) -> Option<Self> {
        let text = std::fs::read_to_string(path).ok()?;
        Some(Self::parse(&text))
    }

    /// Owned only when nowayout is armed. Magic-close of a non-nowayout
    /// device disarms it. Keepalive without nowayout is not ownership.
    pub fn owned(self) -> bool {
        if self.magic_close && !self.nowayout {
            return false;
        }
        self.nowayout
    }
}

/// Linux `linux/watchdog.h` `WDIOC_KEEPALIVE` (`_IOR('W', 5, int)`).
/// Documented only: this host does not call `ioctl(2)`.
pub const WDIOC_KEEPALIVE: u32 = 0x8004_5705;
/// `WDIOF_SETTIMEOUT`
pub const WDIOF_SETTIMEOUT: u32 = 0x0080;
/// `WDIOF_MAGICCLOSE`
pub const WDIOF_MAGICCLOSE: u32 = 0x0100;
/// `WDIOF_KEEPALIVEPING`
pub const WDIOF_KEEPALIVEPING: u32 = 0x8000;
/// `WDIOS_DISABLECARD`
pub const WDIOS_DISABLECARD: u32 = 0x0001;
/// `WDIOS_ENABLECARD`
pub const WDIOS_ENABLECARD: u32 = 0x0002;

const MOCK_OPTIONS: u32 = WDIOF_SETTIMEOUT | WDIOF_MAGICCLOSE | WDIOF_KEEPALIVEPING;
const MOCK_IDENTITY: &str = "g6b-watchdog-mock";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WdError {
    Missing,
    Busy,
    NotOpen,
    Nowayout,
    Unsupported,
    Args,
    Io,
}

impl core::fmt::Display for WdError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.write_str(match self {
            Self::Missing => "watchdog device missing",
            Self::Busy => "watchdog already open",
            Self::NotOpen => "watchdog is not open",
            Self::Nowayout => "nowayout refuses disable",
            Self::Unsupported => "watchdog ioctl unsupported",
            Self::Args => "watchdog argument refused",
            Self::Io => "watchdog I/O error",
        })
    }
}

/// `struct watchdog_info` fields the mock reports for `WDIOC_GETSUPPORT`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WatchdogInfo {
    pub options: u32,
    pub firmware_version: u32,
    pub identity: String,
}

/// Operations matching `linux/watchdog.h` ioctls. Applied to a state file;
/// `ioctl(2)` is not issued.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WdIoctl {
    GetSupport,
    GetStatus,
    GetBootStatus,
    SetOptions(u32),
    Keepalive,
    SetTimeout(u32),
    GetTimeout,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WdReply {
    None,
    Info(WatchdogInfo),
    Int(i32),
}

/// Snapshot of a mock `/dev/watchdog` without taking the fd.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct WatchdogStatus {
    pub nowayout: bool,
    pub running: bool,
    pub opened: bool,
    pub magic_close: bool,
    pub keepalive: bool,
    pub timeout: u32,
}

impl WatchdogStatus {
    /// A mock device is owned only while it is running with nowayout.
    pub fn owned(self) -> bool {
        self.running && self.nowayout
    }

    pub fn stamp(self) -> WatchdogStamp {
        WatchdogStamp {
            nowayout: self.nowayout,
            magic_close: self.magic_close,
            keepalive: self.keepalive,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct DeviceState {
    identity: String,
    nowayout: bool,
    timeout: u32,
    options: u32,
    running: bool,
    opened: bool,
    expect_close: bool,
    magic_close: bool,
    keepalive: u32,
}

impl DeviceState {
    fn mock(nowayout: bool) -> Self {
        Self {
            identity: MOCK_IDENTITY.into(),
            nowayout,
            timeout: 60,
            options: MOCK_OPTIONS,
            running: false,
            opened: false,
            expect_close: false,
            magic_close: false,
            keepalive: 0,
        }
    }

    fn parse(text: &str) -> Self {
        let mut state = Self::mock(false);
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let Some((key, value)) = line.split_once('=') else {
                continue;
            };
            let value = value.trim();
            let on = matches!(value, "1" | "true" | "yes");
            match key.trim() {
                "identity" => state.identity = value.chars().take(32).collect(),
                "nowayout" => state.nowayout = on,
                "timeout" => {
                    if let Ok(n) = value.parse() {
                        state.timeout = n;
                    }
                }
                "options" => {
                    if let Ok(n) = parse_u32(value) {
                        state.options = n;
                    }
                }
                "running" => state.running = on,
                "opened" => state.opened = on,
                "expect_close" => state.expect_close = on,
                "magic_close" => state.magic_close = on,
                "keepalive" => {
                    if let Ok(n) = value.parse() {
                        state.keepalive = n;
                    } else if on {
                        state.keepalive = 1;
                    }
                }
                _ => {}
            }
        }
        state
    }

    fn encode(&self) -> String {
        format!(
            "identity={}\nnowayout={}\ntimeout={}\noptions=0x{:x}\nrunning={}\nopened={}\nexpect_close={}\nmagic_close={}\nkeepalive={}\n",
            self.identity,
            u8::from(self.nowayout),
            self.timeout,
            self.options,
            u8::from(self.running),
            u8::from(self.opened),
            u8::from(self.expect_close),
            u8::from(self.magic_close),
            self.keepalive,
        )
    }

    fn load(path: &Path) -> Result<Self, WdError> {
        let text = std::fs::read_to_string(path).map_err(|_| {
            if path.exists() {
                WdError::Io
            } else {
                WdError::Missing
            }
        })?;
        Ok(Self::parse(&text))
    }

    fn save(&self, path: &Path) -> Result<(), WdError> {
        std::fs::write(path, self.encode()).map_err(|_| WdError::Io)
    }

    fn status(&self) -> WatchdogStatus {
        WatchdogStatus {
            nowayout: self.nowayout,
            running: self.running,
            opened: self.opened,
            magic_close: self.magic_close,
            keepalive: self.keepalive > 0,
            timeout: self.timeout,
        }
    }

    fn ping(&mut self) {
        self.keepalive = self.keepalive.saturating_add(1);
        self.running = true;
    }
}

fn parse_u32(value: &str) -> Result<u32, core::num::ParseIntError> {
    if let Some(hex) = value
        .strip_prefix("0x")
        .or_else(|| value.strip_prefix("0X"))
    {
        u32::from_str_radix(hex, 16)
    } else {
        value.parse()
    }
}

/// File-backed `/dev/watchdog` mock. Linux close/nowayout/magic-close
/// semantics; not a hardware ioctl and not `ioctl(2)` on this host.
pub struct WatchdogDevice {
    path: std::path::PathBuf,
    state: DeviceState,
}

impl WatchdogDevice {
    /// Create a stopped mock node. Does not open the watchdog.
    pub fn create_mock(path: &Path, nowayout: bool) -> Result<Self, WdError> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|_| WdError::Io)?;
        }
        let state = DeviceState::mock(nowayout);
        state.save(path)?;
        Ok(Self {
            path: path.to_path_buf(),
            state,
        })
    }

    pub fn open_path(path: &Path) -> Result<Self, WdError> {
        let mut state = DeviceState::load(path)?;
        if state.opened {
            return Err(WdError::Busy);
        }
        state.opened = true;
        state.running = true;
        state.expect_close = false;
        state.save(path)?;
        Ok(Self {
            path: path.to_path_buf(),
            state,
        })
    }

    /// Read the node without taking the fd.
    pub fn inspect(path: &Path) -> Result<WatchdogStatus, WdError> {
        Ok(DeviceState::load(path)?.status())
    }

    pub fn open(&mut self) -> Result<(), WdError> {
        if self.state.opened {
            return Err(WdError::Busy);
        }
        self.state.opened = true;
        self.state.running = true;
        self.state.expect_close = false;
        self.save()
    }

    pub fn ioctl(&mut self, req: WdIoctl) -> Result<WdReply, WdError> {
        if matches!(
            req,
            WdIoctl::Keepalive | WdIoctl::SetTimeout(_) | WdIoctl::SetOptions(_)
        ) && !self.state.opened
        {
            return Err(WdError::NotOpen);
        }
        let reply = match req {
            WdIoctl::GetSupport => WdReply::Info(WatchdogInfo {
                options: self.state.options,
                firmware_version: 0,
                identity: self.state.identity.clone(),
            }),
            WdIoctl::GetStatus | WdIoctl::GetBootStatus => WdReply::Int(0),
            WdIoctl::Keepalive => {
                if self.state.options & WDIOF_KEEPALIVEPING == 0 {
                    return Err(WdError::Unsupported);
                }
                self.state.ping();
                WdReply::None
            }
            WdIoctl::SetTimeout(seconds) => {
                if self.state.options & WDIOF_SETTIMEOUT == 0 {
                    return Err(WdError::Unsupported);
                }
                if seconds == 0 {
                    return Err(WdError::Args);
                }
                self.state.timeout = seconds;
                WdReply::Int(seconds as i32)
            }
            WdIoctl::GetTimeout => WdReply::Int(self.state.timeout as i32),
            WdIoctl::SetOptions(opts) => {
                if opts & WDIOS_DISABLECARD != 0 {
                    if self.state.nowayout {
                        return Err(WdError::Nowayout);
                    }
                    self.state.running = false;
                }
                if opts & WDIOS_ENABLECARD != 0 {
                    self.state.running = true;
                }
                WdReply::None
            }
        };
        self.save()?;
        Ok(reply)
    }

    /// Write to the node. Any byte pings; `'V'` latches magic close.
    pub fn write(&mut self, bytes: &[u8]) -> Result<usize, WdError> {
        if !self.state.opened {
            return Err(WdError::NotOpen);
        }
        if bytes.is_empty() {
            return Ok(0);
        }
        self.state.expect_close = false;
        if bytes.contains(&b'V') {
            self.state.expect_close = true;
            self.state.magic_close = true;
        }
        self.state.ping();
        self.save()?;
        Ok(bytes.len())
    }

    /// Close the fd. Magic `'V'` stops the timer only when `nowayout` is off.
    pub fn close(&mut self) -> Result<(), WdError> {
        if !self.state.opened {
            return Err(WdError::NotOpen);
        }
        self.state.opened = false;
        if self.state.expect_close && !self.state.nowayout {
            self.state.running = false;
        }
        self.state.expect_close = false;
        self.save()
    }

    pub fn status(&self) -> WatchdogStatus {
        self.state.status()
    }

    fn save(&self) -> Result<(), WdError> {
        self.state.save(&self.path)
    }
}

impl Drop for WatchdogDevice {
    fn drop(&mut self) {
        if self.state.opened {
            self.state.opened = false;
            let _ = self.save();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keepalive_alone_is_not_ownership() {
        let stamp = WatchdogStamp::parse("keepalive=1\n");
        assert!(stamp.keepalive);
        assert!(!stamp.owned());
    }

    #[test]
    fn magic_close_without_nowayout_is_an_unmonitored_gap() {
        let stamp = WatchdogStamp::parse("magic_close=1\nnowayout=0\n");
        assert!(!stamp.owned());
    }

    #[test]
    fn nowayout_is_ownership_even_if_magic_close_was_attempted() {
        let stamp = WatchdogStamp::parse("nowayout=1\nmagic_close=1\nkeepalive=1\n");
        assert!(stamp.owned());
    }

    #[test]
    fn nowayout_without_keepalive_is_still_owned() {
        assert!(WatchdogStamp::parse("nowayout=1\n").owned());
    }

    #[test]
    fn empty_or_unknown_is_not_owned() {
        assert!(!WatchdogStamp::parse("").owned());
        assert!(!WatchdogStamp::parse("ok\n").owned());
        assert!(!WatchdogStamp::parse("nowayout=false\n").owned());
    }

    fn scratch() -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "g6b-wd-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }

    #[test]
    fn keepalive_ioctl_number_is_linux_ior() {
        assert_eq!(WDIOC_KEEPALIVE, 0x8004_5705);
    }

    #[test]
    fn keepalive_ioctl_without_nowayout_is_not_ownership() {
        let path = scratch();
        let mut wd = WatchdogDevice::create_mock(&path, false).unwrap();
        wd.open().unwrap();
        wd.ioctl(WdIoctl::Keepalive).unwrap();
        let status = wd.status();
        assert!(status.running && status.keepalive);
        assert!(!status.owned());
        assert!(!status.stamp().owned());
        drop(wd);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn magic_close_without_nowayout_disarms() {
        let path = scratch();
        let mut wd = WatchdogDevice::create_mock(&path, false).unwrap();
        wd.open().unwrap();
        wd.write(b"V").unwrap();
        wd.close().unwrap();
        let status = WatchdogDevice::inspect(&path).unwrap();
        assert!(!status.running);
        assert!(status.magic_close);
        assert!(!status.owned());
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn nowayout_refuses_magic_close_and_disable() {
        let path = scratch();
        let mut wd = WatchdogDevice::create_mock(&path, true).unwrap();
        wd.open().unwrap();
        wd.ioctl(WdIoctl::Keepalive).unwrap();
        assert_eq!(
            wd.ioctl(WdIoctl::SetOptions(WDIOS_DISABLECARD)),
            Err(WdError::Nowayout)
        );
        wd.write(b"V").unwrap();
        wd.close().unwrap();
        let status = WatchdogDevice::inspect(&path).unwrap();
        assert!(status.running);
        assert!(status.magic_close);
        assert!(status.owned());
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn drop_without_magic_keeps_watchdog_running() {
        let path = scratch();
        {
            let mut wd = WatchdogDevice::create_mock(&path, false).unwrap();
            wd.open().unwrap();
            wd.ioctl(WdIoctl::Keepalive).unwrap();
        }
        let status = WatchdogDevice::inspect(&path).unwrap();
        assert!(status.running);
        assert!(!status.opened);
        assert!(!status.owned());
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn settimeout_round_trips_and_zero_is_refused() {
        let path = scratch();
        let mut wd = WatchdogDevice::create_mock(&path, true).unwrap();
        wd.open().unwrap();
        assert_eq!(wd.ioctl(WdIoctl::SetTimeout(15)).unwrap(), WdReply::Int(15));
        assert_eq!(wd.ioctl(WdIoctl::GetTimeout).unwrap(), WdReply::Int(15));
        assert_eq!(wd.ioctl(WdIoctl::SetTimeout(0)), Err(WdError::Args));
        let info = match wd.ioctl(WdIoctl::GetSupport).unwrap() {
            WdReply::Info(info) => info,
            other => panic!("{other:?}"),
        };
        assert_eq!(info.identity, MOCK_IDENTITY);
        assert_eq!(info.options & WDIOF_MAGICCLOSE, WDIOF_MAGICCLOSE);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn missing_device_is_not_owned() {
        assert_eq!(
            WatchdogDevice::inspect(Path::new("no-such-g6b-watchdog")),
            Err(WdError::Missing)
        );
    }
}
