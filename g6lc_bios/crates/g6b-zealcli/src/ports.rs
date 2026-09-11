// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Capability ports. The CLI must not depend on `g6b-hw`
//! (`architecture/g6b-zealcli.md`), so the kernel — which owns the adapters,
//! the TLS record layer and the flash backend — lends these narrow interfaces
//! instead. Every one of them is **poll-shaped**: a call returns immediately
//! and the CLI drives progress from its own loop, so a firmware download never
//! needs a worker thread and never stalls the prompt.

use std::fmt;

/// One entry on a volume. Mirrors `g6b_fs::DirEnt` without taking the dep.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    pub name: String,
    pub dir: bool,
    pub size: u64,
}

impl Entry {
    pub fn file(name: &str, size: u64) -> Self {
        Self {
            name: name.into(),
            dir: false,
            size,
        }
    }

    pub fn dir(name: &str) -> Self {
        Self {
            name: name.into(),
            dir: true,
            size: 0,
        }
    }
}

/// A mounted volume. `id` is the ZealOS-shaped drive name used in paths
/// (`KEY-FAT:/backup`); `role` is `flash` (firmware stick), `key`, or `cdrom`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VolumeInfo {
    pub id: String,
    pub label: String,
    pub fs: String,
    pub role: String,
    /// USB/ATA inquiry vendor + product, when the device reported one. Empty is
    /// honest: not every transport answers, and a made-up vendor on a boot menu
    /// is worse than a blank.
    pub vendor: String,
}

impl VolumeInfo {
    /// Vendor for display, or the volume label when the device said nothing.
    pub fn vendor_or_label(&self) -> &str {
        if self.vendor.is_empty() {
            &self.label
        } else {
            &self.vendor
        }
    }
}

/// A physical device the board can see.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DriveInfo {
    /// Short id used in commands (`disk0`, `usb0`).
    pub id: String,
    /// Vendor/product the transport reported, empty when it reported none.
    pub model: String,
    pub bytes: u64,
    /// `gpt`, `mbr`, `none`.
    pub scheme: String,
    /// Table problems worth showing (a bad CRC, an entry past the end).
    pub warnings: Vec<String>,
}

/// One candidate volume on a drive — a partition, or the whole device.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VolumeSlot {
    pub drive: String,
    /// 1-based partition index.
    pub index: u32,
    /// Filesystem-friendly name it would mount as (`esp`, `root`, `openwrt`).
    pub name: String,
    /// `fat32`, `ext4`, `ntfs`, `iso9660`, `unknown`.
    pub fs: String,
    pub label: String,
    /// What the partition table claimed (`esp`, `linux-filesystem`, `0x83`).
    pub kind: String,
    pub bytes: u64,
    /// A driver here can read it.
    pub mountable: bool,
    /// Why it cannot be mounted read-write, when it cannot.
    pub write_block: Option<String>,
    /// The field that identified the filesystem.
    pub evidence: String,
}

/// A live mount.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MountInfo {
    pub name: String,
    pub drive: String,
    pub index: u32,
    pub fs: String,
    pub label: String,
    pub rw: bool,
    /// Why it is read-only, when it is.
    pub why_ro: Option<String>,
    /// The OS detected on it, when one was.
    pub os: Option<String>,
}

impl MountInfo {
    /// `/mnt/<name>` — the path the shell walks.
    pub fn mnt(&self) -> String {
        format!("/mnt/{}", self.name)
    }
}

/// A filesystem's write terms for one path, as the shell/editor sees them.
///
/// This is `g6b_vfs::EditBudget` restated without the dependency, so the CLI stays
/// a text face over ports rather than a filesystem client.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EditTerms {
    /// `fat32` / `ext4` / `ntfs` …
    pub fs: String,
    pub exists: bool,
    pub size: u64,
    pub writable: bool,
    /// Largest content the path can hold; `None` = bounded only by the volume.
    pub max_bytes: Option<u64>,
    pub can_create: bool,
    pub can_grow: bool,
    /// Why writing is refused or bounded.
    pub why: Option<String>,
    /// `fat32 rw` / `ext4 rw <=4096B in place` / `ntfs ro` — the status line.
    pub summary: String,
}

impl EditTerms {
    /// Would `len` bytes be accepted? The `Err` is the refusal to print.
    pub fn accepts(&self, len: u64) -> Result<(), String> {
        if !self.writable {
            return Err(self
                .why
                .clone()
                .unwrap_or_else(|| format!("{} is not writable here", self.fs)));
        }
        if let Some(max) = self.max_bytes {
            if len > max {
                return Err(format!(
                    "{len} bytes exceeds the {max} this {} path can hold{}",
                    self.fs,
                    self.why
                        .as_ref()
                        .map(|w| format!(" — {w}"))
                        .unwrap_or_default()
                ));
            }
        }
        if !self.exists && !self.can_create {
            return Err(format!(
                "{} cannot create files in this BIOS{}",
                self.fs,
                self.why
                    .as_ref()
                    .map(|w| format!(" — {w}"))
                    .unwrap_or_default()
            ));
        }
        Ok(())
    }
}

/// Real drives, partitions, mounts and files — the seam every face shares.
///
/// The CLI walks it with `cd`/`ls`/`cat`/`vi`, the boot picker asks it what a
/// medium holds, HolyC reaches it through builtins and the browser UI through the
/// kernel's router. One implementation ([`g6b-vfs`](https://docs.rs) behind
/// `g6b-kernel`), so the text face and the graphical face cannot disagree about
/// what is on a disk.
pub trait MountPort {
    fn drives(&mut self) -> Vec<DriveInfo>;
    /// Candidate volumes on `drive`, whether or not they can be mounted.
    fn volumes(&mut self, drive: &str) -> Result<Vec<VolumeSlot>, String>;
    fn mounts(&mut self) -> Vec<MountInfo>;
    /// Mount `drive`'s partition `index` as `name`. `rw` is a request: the
    /// returned [`MountInfo`] says what was actually granted, and `why_ro` why.
    fn mount(&mut self, drive: &str, index: u32, name: &str, rw: bool)
        -> Result<MountInfo, String>;
    fn umount(&mut self, name: &str) -> Result<(), String>;
    fn list(&mut self, mount: &str, path: &str) -> Result<Vec<Entry>, String>;
    fn read(&mut self, mount: &str, path: &str) -> Result<Vec<u8>, String>;
    /// `len` bytes at `off` — how an editor opens a file without loading a
    /// multi-gigabyte one into a BIOS's memory.
    fn read_window(
        &mut self,
        mount: &str,
        path: &str,
        off: u64,
        len: usize,
    ) -> Result<Vec<u8>, String> {
        let all = self.read(mount, path)?;
        let start = usize::try_from(off).unwrap_or(usize::MAX).min(all.len());
        let end = start.saturating_add(len).min(all.len());
        Ok(all[start..end].to_vec())
    }
    /// What a write to this path could do, **before** one is attempted: the
    /// filesystem's own terms, which differ per driver and which an editor has to
    /// show an operator up front rather than after the work is typed.
    fn edit_budget(&mut self, mount: &str, path: &str) -> Result<EditTerms, String>;
    fn write(&mut self, mount: &str, path: &str, data: &[u8]) -> Result<(), String>;
    fn mkdir(&mut self, mount: &str, path: &str) -> Result<(), String>;
    fn remove(&mut self, mount: &str, path: &str) -> Result<(), String>;
    /// What OS is installed on a mount, read from the mount itself
    /// (`/etc/os-release`, `/etc/openwrt_release`, a Windows layout…).
    fn os_info(&mut self, mount: &str) -> Option<String>;
}

/// Volume/file exploration (USB key included).
pub trait VolumePort {
    fn volumes(&self) -> Vec<VolumeInfo>;
    fn list(&self, volume: &str, path: &str) -> Result<Vec<Entry>, String>;
    fn read(&self, volume: &str, path: &str) -> Result<Vec<u8>, String>;

    /// `len` bytes at `off`. Media probing reads a header out of a multi-gigabyte
    /// image, so the window matters: the default implementation slices [`read`],
    /// and a port with a real block reader overrides it to seek instead.
    fn read_window(
        &self,
        volume: &str,
        path: &str,
        off: u64,
        len: usize,
    ) -> Result<Vec<u8>, String> {
        let all = self.read(volume, path)?;
        let start = usize::try_from(off).unwrap_or(usize::MAX).min(all.len());
        let end = start.saturating_add(len).min(all.len());
        Ok(all[start..end].to_vec())
    }
}

/// One bounded step of a transfer. `Pending` is the normal answer: the CLI
/// polls again on the next key or timer tick.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Progress {
    Pending { done: u64, total: u64 },
    Done(Vec<u8>),
    Failed(String),
}

/// Outbound HTTP(S) GET. The kernel plans the URL (`g6b-http`), writes the
/// ClientHello (`g6b-tls`) and owns the socket (`g6b-hw` TCP); the CLI only
/// starts and polls. No thread is created on either side.
pub trait NetPort {
    fn get(&mut self, url: &str) -> Result<u32, String>;
    fn poll(&mut self, handle: u32) -> Progress;
    fn cancel(&mut self, handle: u32);
    /// One-line adapter/link status for `net` and the manual.
    fn status(&self) -> String;
}

/// Firmware sink. `stage` returns the digest the kernel computed over the
/// staged bytes so the operator can compare it before `commit`.
pub trait FlashPort {
    fn stage(&mut self, image: &str, bytes: &[u8]) -> Result<String, String>;
    fn commit(&mut self, image: &str) -> Result<String, String>;
}

/// What the kernel lent this session. `None` means the capability was not
/// compiled (or no device answered), and the CLI says so instead of pretending.
#[derive(Default)]
pub struct Ports {
    pub volumes: Option<Box<dyn VolumePort>>,
    pub net: Option<Box<dyn NetPort>>,
    pub flash: Option<Box<dyn FlashPort>>,
    /// Real drives/partitions/mounts, when this build has a block reader.
    pub mounts: Option<Box<dyn MountPort>>,
}

impl fmt::Debug for Ports {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Ports")
            .field("volumes", &self.volumes.is_some())
            .field("net", &self.net.is_some())
            .field("flash", &self.flash.is_some())
            .field("mounts", &self.mounts.is_some())
            .finish()
    }
}

impl Ports {
    pub fn with_volumes(mut self, v: impl VolumePort + 'static) -> Self {
        self.volumes = Some(Box::new(v));
        self
    }

    pub fn with_mounts(mut self, m: impl MountPort + 'static) -> Self {
        self.mounts = Some(Box::new(m));
        self
    }

    pub fn with_net(mut self, n: impl NetPort + 'static) -> Self {
        self.net = Some(Box::new(n));
        self
    }

    pub fn with_flash(mut self, fl: impl FlashPort + 'static) -> Self {
        self.flash = Some(Box::new(fl));
        self
    }
}

/// In-memory volumes for host tests and `g6b zealcli` on a workstation.
#[derive(Debug, Default, Clone)]
pub struct MemVolumes {
    vols: Vec<VolumeInfo>,
    files: Vec<(String, String, Vec<u8>)>,
}

impl MemVolumes {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn volume(mut self, id: &str, fs: &str, role: &str) -> Self {
        self.vols.push(VolumeInfo {
            id: id.into(),
            label: id.into(),
            fs: fs.into(),
            role: role.into(),
            vendor: String::new(),
        });
        self
    }

    /// Same with the device's reported vendor/product string.
    pub fn volume_vendor(mut self, id: &str, fs: &str, role: &str, vendor: &str) -> Self {
        self.vols.push(VolumeInfo {
            id: id.into(),
            label: id.into(),
            fs: fs.into(),
            role: role.into(),
            vendor: vendor.into(),
        });
        self
    }

    pub fn file(mut self, volume: &str, path: &str, body: impl Into<Vec<u8>>) -> Self {
        self.files
            .push((volume.into(), normalize(path), body.into()));
        self
    }
}

fn normalize(p: &str) -> String {
    let mut out: Vec<&str> = Vec::new();
    for part in p.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                out.pop();
            }
            s => out.push(s),
        }
    }
    format!("/{}", out.join("/"))
}

fn parent_of(path: &str) -> String {
    let trimmed = path.trim_end_matches('/');
    match trimmed.rsplit_once('/') {
        Some(("", _)) | None => "/".into(),
        Some((p, _)) => p.to_string(),
    }
}

impl VolumePort for MemVolumes {
    fn volumes(&self) -> Vec<VolumeInfo> {
        self.vols.clone()
    }

    fn list(&self, volume: &str, path: &str) -> Result<Vec<Entry>, String> {
        if !self.vols.iter().any(|v| v.id == volume) {
            return Err(format!("no volume {volume}"));
        }
        let dir = normalize(path);
        let mut out: Vec<Entry> = Vec::new();
        for (vol, file, body) in &self.files {
            if vol != volume {
                continue;
            }
            if parent_of(file) == dir {
                out.push(Entry::file(
                    file.rsplit('/').next().unwrap_or(file),
                    body.len() as u64,
                ));
            } else if let Some(rest) = file.strip_prefix(&format!("{}/", dir.trim_end_matches('/')))
            {
                if let Some((child, _)) = rest.split_once('/') {
                    if !out.iter().any(|e| e.name == child) {
                        out.push(Entry::dir(child));
                    }
                }
            }
        }
        out.sort_by(|a, b| (b.dir, &a.name).cmp(&(a.dir, &b.name)));
        Ok(out)
    }

    fn read(&self, volume: &str, path: &str) -> Result<Vec<u8>, String> {
        let want = normalize(path);
        self.files
            .iter()
            .find(|(v, f, _)| v == volume && *f == want)
            .map(|(_, _, b)| b.clone())
            .ok_or_else(|| format!("no file {volume}:{want}"))
    }
}
