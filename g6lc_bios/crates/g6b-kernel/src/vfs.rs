// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! The kernel's block/filesystem service: [`g6b_vfs`] behind
//! [`g6b_zealcli::ports::MountPort`], shared by every face — the setup shell, the
//! boot picker, HolyC builtins and (through the router) the browser UI.
//!
//! Ownership is the design problem. A `g6b-vfs` filesystem *borrows* its device for
//! as long as it lives: right for a driver, wrong for a mount table that outlives
//! any single call. So this service owns the **devices** and mounts on demand —
//! every operation opens the partition, does its work, and drops the driver. A BIOS
//! performs a handful of filesystem operations per keystroke, and the cost buys a
//! mount table that cannot hold a dangling borrow.
//!
//! What persists between calls is the *mount decision*: which drive, which
//! partition, which name, and whether write was granted. That is what an operator
//! asked for, and what `mount` has to be able to show them.

use g6b_vfs::{BlockDev, FileBlock, FileSystem, MemBlock, SubDev};
use g6b_zealcli::ports::{DriveInfo, EditTerms, Entry, MountInfo, MountPort, VolumeSlot};

/// Where a drive's bytes come from.
enum Source {
    /// A host file: an image, or a raw device the OS lets us open.
    File(String),
    /// An in-memory image — a test, or bytes a caller handed us. Writes land in
    /// the vector, so the caller sees them.
    Mem(Vec<u8>),
}

struct Drive {
    id: String,
    model: String,
    bytes: u64,
    source: Source,
}

/// A remembered mount decision.
#[derive(Clone, Debug)]
struct Mount {
    name: String,
    drive: String,
    index: u32,
    fs: String,
    label: String,
    rw: bool,
    why_ro: Option<String>,
    os: Option<String>,
}

/// Block/filesystem service.
#[derive(Default)]
pub struct VfsService {
    drives: Vec<Drive>,
    mounts: Vec<Mount>,
}

impl std::fmt::Debug for VfsService {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("VfsService")
            .field("drives", &self.drives.len())
            .field("mounts", &self.mounts.len())
            .finish()
    }
}

impl VfsService {
    pub fn new() -> Self {
        Self::default()
    }

    /// Attach a host file (image or raw disk) as a drive.
    pub fn add_file(mut self, id: &str, path: &str, model: &str) -> Result<Self, String> {
        let bytes = std::fs::metadata(path)
            .map_err(|e| format!("{path}: {e}"))?
            .len();
        self.drives.push(Drive {
            id: id.to_string(),
            model: model.to_string(),
            bytes,
            source: Source::File(path.to_string()),
        });
        Ok(self)
    }

    /// Attach an in-memory image as a drive.
    pub fn add_image(mut self, id: &str, bytes: Vec<u8>, model: &str) -> Self {
        self.drives.push(Drive {
            id: id.to_string(),
            model: model.to_string(),
            bytes: bytes.len() as u64,
            source: Source::Mem(bytes),
        });
        self
    }

    pub fn drive_ids(&self) -> Vec<String> {
        self.drives.iter().map(|d| d.id.clone()).collect()
    }

    /// The bytes of an in-memory drive, so a caller can see what a write did.
    pub fn image(&self, id: &str) -> Option<&[u8]> {
        self.drives
            .iter()
            .find(|d| d.id == id)
            .and_then(|d| match &d.source {
                Source::Mem(b) => Some(b.as_slice()),
                Source::File(_) => None,
            })
    }

    /// Run `f` with the drive open as a block device.
    ///
    /// The in-memory case takes the vector out and puts it back, which is what
    /// keeps this free of self-borrow problems while still letting a write stick.
    fn with_dev<T>(
        &mut self,
        id: &str,
        rw: bool,
        f: impl FnOnce(&mut dyn BlockDev) -> Result<T, String>,
    ) -> Result<T, String> {
        let d = self
            .drives
            .iter_mut()
            .find(|d| d.id == id)
            .ok_or_else(|| format!("no drive `{id}`"))?;
        match &mut d.source {
            Source::File(path) => {
                let mut dev = FileBlock::open_rw(path, rw).map_err(|e| e.to_string())?;
                f(&mut dev)
            }
            Source::Mem(bytes) => {
                let taken = std::mem::take(bytes);
                let mut dev = if rw {
                    MemBlock::new(taken)
                } else {
                    MemBlock::read_only(taken)
                };
                let out = f(&mut dev);
                *bytes = dev.into_bytes();
                out
            }
        }
    }

    /// Run `f` with partition `index` of `drive` open as a device of its own.
    fn with_part<T>(
        &mut self,
        drive: &str,
        index: u32,
        rw: bool,
        f: impl FnOnce(&mut dyn BlockDev) -> Result<T, String>,
    ) -> Result<T, String> {
        self.with_dev(drive, rw, |dev| {
            let table = g6b_vfs::part::read_table(dev).map_err(|e| e.to_string())?;
            let p = table
                .parts
                .into_iter()
                .find(|p| p.index == index)
                .ok_or_else(|| format!("{drive} has no partition {index}"))?;
            let mut sub = SubDev::new(dev, p.start, p.len, rw).map_err(|e| e.to_string())?;
            f(&mut sub)
        })
    }

    /// Run `f` with a mounted filesystem on the named mount.
    fn with_fs<T>(
        &mut self,
        name: &str,
        want_rw: bool,
        f: impl FnOnce(&mut dyn FileSystem) -> Result<T, String>,
    ) -> Result<T, String> {
        let m = self
            .mounts
            .iter()
            .find(|m| m.name == name)
            .cloned()
            .ok_or_else(|| format!("`{name}` is not mounted"))?;
        if want_rw && !m.rw {
            let why = m
                .why_ro
                .clone()
                .unwrap_or_else(|| "mounted read-only".to_string());
            return Err(format!("{name} is read-only: {why}"));
        }
        let rw = m.rw && want_rw;
        self.with_part(&m.drive, m.index, rw, |dev| {
            let (mut fs, _probe) = g6b_vfs::mount(dev, rw).map_err(|e| e.to_string())?;
            f(fs.as_mut())
        })
    }

    /// What OS is installed on a mounted filesystem, read from the volume.
    ///
    /// The evidence is the file: `/etc/os-release` (`PRETTY_NAME`),
    /// `/etc/openwrt_release` (`DISTRIB_DESCRIPTION`), a `casper` live tree, an
    /// EFI loader, a Windows layout. No file, no claim.
    fn detect_os(fs: &mut dyn FileSystem) -> Option<String> {
        let text = |fs: &mut dyn FileSystem, path: &str| -> Option<String> {
            fs.read_window(path, 0, 4096)
                .ok()
                .map(|b| String::from_utf8_lossy(&b).to_string())
        };
        let field = |body: &str, key: &str| -> Option<String> {
            body.lines()
                .find(|l| l.starts_with(key))
                .and_then(|l| l.split_once('='))
                .map(|(_, v)| v.trim().trim_matches('"').to_string())
                .filter(|v| !v.is_empty())
        };
        for (path, key, fallback) in [
            ("/etc/os-release", "PRETTY_NAME", "Linux"),
            ("/usr/lib/os-release", "PRETTY_NAME", "Linux"),
            ("/etc/openwrt_release", "DISTRIB_DESCRIPTION", "OpenWrt"),
        ] {
            if let Some(body) = text(fs, path) {
                return Some(field(&body, key).unwrap_or_else(|| fallback.to_string()));
            }
        }
        // A live/installer tree names itself in `.disk/info`.
        if let Some(info) = text(fs, "/.disk/info") {
            if let Some(line) = info.lines().next() {
                if !line.trim().is_empty() {
                    return Some(format!("{} (live)", line.trim()));
                }
            }
        }
        // Otherwise, the layout: a loader, a Windows install, a kernel.
        if fs.stat("/EFI/BOOT/BOOTRISCV64.EFI").is_ok() {
            return Some("UEFI loader (removable path)".into());
        }
        if fs.stat("/Windows/System32").is_ok() || fs.stat("/bootmgr").is_ok() {
            return Some("Windows".into());
        }
        if fs.stat("/etc").is_ok() && fs.stat("/boot").is_ok() {
            return Some("Linux (no os-release)".into());
        }
        None
    }
}

impl MountPort for VfsService {
    fn drives(&mut self) -> Vec<DriveInfo> {
        let ids: Vec<(String, String, u64)> = self
            .drives
            .iter()
            .map(|d| (d.id.clone(), d.model.clone(), d.bytes))
            .collect();
        ids.into_iter()
            .map(|(id, model, bytes)| {
                let (scheme, warnings) = self
                    .with_dev(&id, false, |dev| {
                        let t = g6b_vfs::part::read_table(dev).map_err(|e| e.to_string())?;
                        Ok((t.scheme.as_str().to_string(), t.warnings))
                    })
                    .unwrap_or_else(|e| ("?".to_string(), vec![e]));
                DriveInfo {
                    id,
                    model,
                    bytes,
                    scheme,
                    warnings,
                }
            })
            .collect()
    }

    fn volumes(&mut self, drive: &str) -> Result<Vec<VolumeSlot>, String> {
        let drive = drive.to_string();
        let scan = self.with_dev(&drive, false, |dev| {
            g6b_vfs::scan(dev).map_err(|e| e.to_string())
        })?;
        Ok(scan
            .volumes
            .into_iter()
            .map(|v| VolumeSlot {
                drive: drive.clone(),
                index: v.part.index,
                name: v.name,
                fs: v.probe.kind.as_str().to_string(),
                label: v.probe.label,
                kind: v.part.kind,
                bytes: v.part.len,
                mountable: v.probe.kind.readable(),
                write_block: v.probe.write_block,
                evidence: v.probe.evidence,
            })
            .collect())
    }

    fn mounts(&mut self) -> Vec<MountInfo> {
        self.mounts
            .iter()
            .map(|m| MountInfo {
                name: m.name.clone(),
                drive: m.drive.clone(),
                index: m.index,
                fs: m.fs.clone(),
                label: m.label.clone(),
                rw: m.rw,
                why_ro: m.why_ro.clone(),
                os: m.os.clone(),
            })
            .collect()
    }

    fn mount(
        &mut self,
        drive: &str,
        index: u32,
        name: &str,
        rw: bool,
    ) -> Result<MountInfo, String> {
        if name.is_empty()
            || !name
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
        {
            return Err(format!("`{name}` is not a usable mount name"));
        }
        if self.mounts.iter().any(|m| m.name == name) {
            return Err(format!("`{name}` is already mounted (umount it first)"));
        }
        // Mount once here to learn what we actually got, then remember it.
        let (fs_kind, label, granted_rw, why_ro, os) = self.with_part(drive, index, rw, |dev| {
            let probe = g6b_vfs::probe::probe(dev).map_err(|e| e.to_string())?;
            // The device's own writability has to be read before the driver
            // borrows it — and it is half the answer to "why is this ro?".
            let dev_rw = dev.writable();
            let (mut fs, _) = g6b_vfs::mount(dev, rw).map_err(|e| e.to_string())?;
            let granted = fs.writable();
            let why = if rw && !granted {
                Some(probe.write_block.clone().unwrap_or_else(|| {
                    if dev_rw {
                        "the driver does not write this filesystem".to_string()
                    } else {
                        "the device is read-only".to_string()
                    }
                }))
            } else {
                None
            };
            let os = Self::detect_os(fs.as_mut());
            Ok((fs.kind().as_str().to_string(), fs.label(), granted, why, os))
        })?;
        let m = Mount {
            name: name.to_string(),
            drive: drive.to_string(),
            index,
            fs: fs_kind,
            label,
            rw: granted_rw,
            why_ro,
            os,
        };
        self.mounts.push(m.clone());
        Ok(MountInfo {
            name: m.name,
            drive: m.drive,
            index: m.index,
            fs: m.fs,
            label: m.label,
            rw: m.rw,
            why_ro: m.why_ro,
            os: m.os,
        })
    }

    fn umount(&mut self, name: &str) -> Result<(), String> {
        let before = self.mounts.len();
        self.mounts.retain(|m| m.name != name);
        if self.mounts.len() == before {
            return Err(format!("`{name}` is not mounted"));
        }
        Ok(())
    }

    fn list(&mut self, mount: &str, path: &str) -> Result<Vec<Entry>, String> {
        let path = path.to_string();
        self.with_fs(mount, false, |fs| {
            let ents = fs.list(&path).map_err(|e| e.to_string())?;
            Ok(ents
                .into_iter()
                .map(|e| Entry {
                    name: e.name,
                    dir: e.dir,
                    size: e.size,
                })
                .collect())
        })
    }

    fn read(&mut self, mount: &str, path: &str) -> Result<Vec<u8>, String> {
        let path = path.to_string();
        self.with_fs(mount, false, |fs| fs.read(&path).map_err(|e| e.to_string()))
    }

    fn read_window(
        &mut self,
        mount: &str,
        path: &str,
        off: u64,
        len: usize,
    ) -> Result<Vec<u8>, String> {
        let path = path.to_string();
        self.with_fs(mount, false, |fs| {
            fs.read_window(&path, off, len).map_err(|e| e.to_string())
        })
    }

    fn edit_budget(&mut self, mount: &str, path: &str) -> Result<EditTerms, String> {
        let path = path.to_string();
        // With the mount's **granted** mode, not a read-only borrow: a driver
        // reports its terms relative to how it was mounted, so probing a writable
        // mount read-only would answer "0 bytes, read-only" for a file the operator
        // can in fact save. (That is exactly what the end-to-end `vi` test caught.)
        let granted_rw = self
            .mounts
            .iter()
            .find(|m| m.name == mount)
            .map(|m| m.rw)
            .unwrap_or(false);
        self.with_fs(mount, granted_rw, |fs| {
            let b = fs.edit_budget(&path).map_err(|e| e.to_string())?;
            Ok(EditTerms {
                fs: b.fs.as_str().to_string(),
                exists: b.exists,
                size: b.size,
                writable: b.writable,
                max_bytes: b.max_bytes,
                can_create: b.can_create,
                can_grow: b.can_grow,
                why: b.why.clone(),
                summary: b.summary(),
            })
        })
        .map(|mut t| {
            // The mount's own mode is part of the terms: a read-only mount over a
            // writable filesystem is still read-only, and the reason belongs here
            // rather than surfacing only when `:w` fails.
            if let Some(m) = self.mounts.iter().find(|m| m.name == mount) {
                if !m.rw && t.writable {
                    t.writable = false;
                    t.why = Some(
                        m.why_ro
                            .clone()
                            .unwrap_or_else(|| "mounted read-only (`mount -w` to write)".into()),
                    );
                    t.summary = format!("{} ro", t.fs);
                }
            }
            t
        })
    }

    fn write(&mut self, mount: &str, path: &str, data: &[u8]) -> Result<(), String> {
        let path = path.to_string();
        let data = data.to_vec();
        self.with_fs(mount, true, |fs| {
            fs.write(&path, &data).map_err(|e| e.to_string())
        })
    }

    fn mkdir(&mut self, mount: &str, path: &str) -> Result<(), String> {
        let path = path.to_string();
        self.with_fs(mount, true, |fs| fs.mkdir(&path).map_err(|e| e.to_string()))
    }

    fn remove(&mut self, mount: &str, path: &str) -> Result<(), String> {
        let path = path.to_string();
        self.with_fs(mount, true, |fs| {
            fs.remove(&path).map_err(|e| e.to_string())
        })
    }

    fn os_info(&mut self, mount: &str) -> Option<String> {
        self.with_fs(mount, false, |fs| Ok(Self::detect_os(fs)))
            .ok()
            .flatten()
    }
}

/// One [`VfsService`] with two owners.
///
/// The setup shell holds a `MountPort` and the store holds a
/// [`g6b_pglite::StoreVolume`], and they have to be the **same** mount table: a
/// dump the browser UI writes to a key must be the file the shell's `cat` shows,
/// and a key the operator mounts by hand must be the one the store persists to.
/// Two services over one device would be two views of it, and the second writer
/// would be working from a stale read.
///
/// `Rc<RefCell<…>>` because this is a single-threaded firmware host: the borrow is
/// taken for the length of one operation, and every method here is one operation.
#[derive(Clone)]
pub struct SharedVfs {
    inner: std::rc::Rc<std::cell::RefCell<VfsService>>,
}

impl std::fmt::Debug for SharedVfs {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "SharedVfs({:?})", self.inner.borrow())
    }
}

impl SharedVfs {
    pub fn new(svc: VfsService) -> Self {
        Self {
            inner: std::rc::Rc::new(std::cell::RefCell::new(svc)),
        }
    }

    /// Run `f` against the service — how a caller reaches anything not on the
    /// `MountPort`/`StoreVolume` seams (attaching drives, reading an image back).
    pub fn with<T>(&self, f: impl FnOnce(&mut VfsService) -> T) -> T {
        f(&mut self.inner.borrow_mut())
    }
}

/// Resolve the store's idea of a volume to a mount.
///
/// The two namespaces differ on purpose and both are useful: the store names a
/// **filesystem kind** (`fat32` / `ntfs` / `ext4` — "my key is the FAT32 one",
/// which is what `kernel.store.persist.volume` declares), while the mount table
/// names *instances* (`key`, `root`). A mount name is accepted first, then the kind.
///
/// Ambiguity is refused rather than guessed, the same discipline `mount` follows:
/// with two FAT32 volumes mounted, picking one for the operator's database is a
/// decision this code has no basis to make.
fn resolve_store_mount(svc: &mut VfsService, volume: &str) -> Result<String, String> {
    let want = volume.trim().to_ascii_lowercase();
    let mounts = svc.mounts();
    if mounts.iter().any(|m| m.name == want) {
        return Ok(want);
    }
    let matches_kind = |fs: &str| -> bool {
        let fs = fs.to_ascii_lowercase();
        match want.as_str() {
            "fat32" => fs.starts_with("fat"),
            "ntfs" => fs == "ntfs",
            "ext4" => fs.starts_with("ext"),
            "btrfs" => fs == "btrfs",
            _ => false,
        }
    };
    let hits: Vec<&MountInfo> = mounts.iter().filter(|m| matches_kind(&m.fs)).collect();
    match hits.as_slice() {
        [one] => Ok(one.name.clone()),
        [] => Err(format!(
            "no mounted {want} volume for the store — mount the key first (`mount -w disk:N as \
             key`); mounted: {}",
            if mounts.is_empty() {
                "nothing".to_string()
            } else {
                mounts
                    .iter()
                    .map(|m| format!("{} ({})", m.name, m.fs))
                    .collect::<Vec<_>>()
                    .join(", ")
            }
        )),
        many => Err(format!(
            "{} mounted {want} volumes ({}) — name the one the store should use",
            many.len(),
            many.iter()
                .map(|m| m.name.clone())
                .collect::<Vec<_>>()
                .join(", ")
        )),
    }
}

/// The store's persistence, on the shell's mount table.
impl g6b_pglite::StoreVolume for SharedVfs {
    fn write(&mut self, volume: &str, rel: &str, bytes: &[u8]) -> Result<(), String> {
        let mut svc = self.inner.borrow_mut();
        let volume = resolve_store_mount(&mut svc, volume)?;
        let volume = volume.as_str();
        let path = normalize_store_path(rel);
        // Create the directory the dump lives in when the filesystem can: a store
        // path is `/g6lc/store.json`-shaped and a fresh key has no `/g6lc`.
        // Create the **whole** chain, not just the immediate parent: a store's
        // default path is `stores/<purpose>/<uuid>.g6bstore`, two levels deep, and
        // `mkdir` is one level at a time by design (it mirrors the syscall, not the
        // shell). A fresh key has none of it.
        if let Some((dir, _)) = path.rsplit_once('/') {
            let mut so_far = String::new();
            for part in dir.split('/').filter(|p| !p.is_empty()) {
                so_far.push('/');
                so_far.push_str(part);
                // An existing directory is the expected case on every persist after
                // the first, so only a *write* failure is worth reporting.
                let _ = svc.mkdir(volume, &so_far);
            }
        }
        svc.write(volume, &path, bytes)
    }

    fn read(&mut self, volume: &str, rel: &str) -> Result<Option<Vec<u8>>, String> {
        let mut svc = self.inner.borrow_mut();
        // A read before the first write is the normal case, so an unresolvable
        // volume is "nothing there yet" rather than an error that would block a
        // store from opening at all.
        let Ok(volume) = resolve_store_mount(&mut svc, volume) else {
            return Ok(None);
        };
        let volume = volume.as_str();
        let path = normalize_store_path(rel);
        match svc.read(volume, &path) {
            Ok(b) => Ok(Some(b)),
            // "Not there yet" is not an error: a first persist writes it.
            Err(e) if e.contains("no such file") => Ok(None),
            Err(e) => Err(e),
        }
    }
}

/// A store `rel` is a volume-relative name (`registry.json`, `g6lc/store.json`);
/// the filesystem wants an absolute path.
fn normalize_store_path(rel: &str) -> String {
    let rel = rel.trim();
    if rel.is_empty() {
        return "/g6lc-store.json".to_string();
    }
    // The leading slash matters: `normalize("stores/registry")` keeps it relative
    // and the filesystem then looks for it nowhere in particular. The store's
    // default rel (`stores/<purpose>`) is exactly that shape.
    let abs = if rel.starts_with('/') {
        rel.to_string()
    } else {
        format!("/{rel}")
    };
    g6b_vfs::normalize(&abs)
}

impl MountPort for SharedVfs {
    fn drives(&mut self) -> Vec<DriveInfo> {
        self.inner.borrow_mut().drives()
    }

    fn volumes(&mut self, drive: &str) -> Result<Vec<VolumeSlot>, String> {
        self.inner.borrow_mut().volumes(drive)
    }

    fn mounts(&mut self) -> Vec<MountInfo> {
        self.inner.borrow_mut().mounts()
    }

    fn mount(
        &mut self,
        drive: &str,
        index: u32,
        name: &str,
        rw: bool,
    ) -> Result<MountInfo, String> {
        self.inner.borrow_mut().mount(drive, index, name, rw)
    }

    fn umount(&mut self, name: &str) -> Result<(), String> {
        self.inner.borrow_mut().umount(name)
    }

    fn list(&mut self, mount: &str, path: &str) -> Result<Vec<Entry>, String> {
        self.inner.borrow_mut().list(mount, path)
    }

    fn read(&mut self, mount: &str, path: &str) -> Result<Vec<u8>, String> {
        self.inner.borrow_mut().read(mount, path)
    }

    fn read_window(
        &mut self,
        mount: &str,
        path: &str,
        off: u64,
        len: usize,
    ) -> Result<Vec<u8>, String> {
        self.inner.borrow_mut().read_window(mount, path, off, len)
    }

    fn edit_budget(&mut self, mount: &str, path: &str) -> Result<EditTerms, String> {
        self.inner.borrow_mut().edit_budget(mount, path)
    }

    fn write(&mut self, mount: &str, path: &str, data: &[u8]) -> Result<(), String> {
        self.inner.borrow_mut().write(mount, path, data)
    }

    fn mkdir(&mut self, mount: &str, path: &str) -> Result<(), String> {
        self.inner.borrow_mut().mkdir(mount, path)
    }

    fn remove(&mut self, mount: &str, path: &str) -> Result<(), String> {
        self.inner.borrow_mut().remove(mount, path)
    }

    fn os_info(&mut self, mount: &str) -> Option<String> {
        self.inner.borrow_mut().os_info(mount)
    }
}

/// Answer a `VFS-REQUEST <verb> <args…>` — the band HolyC, the shell and the
/// browser UI share.
///
/// One entry point for three faces is the whole point: a HolyC script that lists
/// `/etc`, the VGA `ls`, and a `fetch('/bios/vfs/list?…')` from the browser UI all
/// end up in the same driver on the same bytes, so they cannot disagree about
/// what is on a disk.
pub fn vfs_request(svc: &mut VfsService, verb: &str, args: &[&str]) -> String {
    let arg = |n: usize| args.get(n).copied().unwrap_or("");
    match verb {
        "Drives" => {
            let mut out = String::new();
            for d in svc.drives() {
                out.push_str(&format!(
                    "DRIVE {} model={:?} bytes={} scheme={}\n",
                    d.id, d.model, d.bytes, d.scheme
                ));
                for v in svc.volumes(&d.id).unwrap_or_default() {
                    out.push_str(&format!(
                        "VOL {}:{} name={} fs={} label={:?} kind={} bytes={} mountable={}\n",
                        v.drive, v.index, v.name, v.fs, v.label, v.kind, v.bytes, v.mountable
                    ));
                }
            }
            if out.is_empty() {
                "VFS-NONE no drives\n".into()
            } else {
                out
            }
        }
        "Mounts" => {
            let ms = svc.mounts();
            if ms.is_empty() {
                return "VFS-NONE nothing mounted\n".into();
            }
            let mut out = String::new();
            for m in &ms {
                out.push_str(&format!(
                    "MOUNT {} at {} fs={} mode={} os={:?}\n",
                    m.name,
                    m.mnt(),
                    m.fs,
                    if m.rw { "rw" } else { "ro" },
                    m.os.clone().unwrap_or_default()
                ));
            }
            out
        }
        // `Mount("disk0", 2, "root", "rw")`
        "Mount" => {
            let index: u32 = arg(1).parse().unwrap_or(1);
            let rw = arg(3).eq_ignore_ascii_case("rw");
            let name = if arg(2).is_empty() { "vol" } else { arg(2) };
            match svc.mount(arg(0), index, name, rw) {
                Ok(m) => format!(
                    "MOUNT-OK {} at {} fs={} mode={}{}\n",
                    m.name,
                    m.mnt(),
                    m.fs,
                    if m.rw { "rw" } else { "ro" },
                    m.why_ro
                        .map(|w| format!(" ro_reason={w:?}"))
                        .unwrap_or_default()
                ),
                Err(e) => format!("MOUNT-REFUSED {e}\n"),
            }
        }
        "VfsLs" => match svc.list(arg(0), if arg(1).is_empty() { "/" } else { arg(1) }) {
            Ok(ents) => {
                if ents.is_empty() {
                    "VFS-EMPTY\n".into()
                } else {
                    let mut out = String::new();
                    for e in &ents {
                        out.push_str(&format!(
                            "{} {} {}\n",
                            if e.dir { "d" } else { "-" },
                            e.size,
                            e.name
                        ));
                    }
                    out
                }
            }
            Err(e) => format!("VFS-REFUSED {e}\n"),
        },
        "VfsCat" => match svc.read(arg(0), arg(1)) {
            Ok(b) => String::from_utf8_lossy(&b).to_string(),
            Err(e) => format!("VFS-REFUSED {e}\n"),
        },
        "VfsWrite" => match svc.write(arg(0), arg(1), arg(2).as_bytes()) {
            Ok(()) => format!(
                "VFS-WROTE {} bytes to {}:{}\n",
                arg(2).len(),
                arg(0),
                arg(1)
            ),
            Err(e) => format!("VFS-REFUSED {e}\n"),
        },
        "OsDetect" => match svc.os_info(arg(0)) {
            Some(os) => format!("OS {os}\n"),
            None => "OS-UNKNOWN nothing on that volume names itself\n".into(),
        },
        other => format!("VFS-REFUSED unknown verb {other}\n"),
    }
}

/// The same answers as JSON, for the browser UI's `fetch`/WASM path.
///
/// JSON rather than the line format because that side has a parser; the *data* is
/// identical, which is what keeps the two faces honest.
pub fn vfs_json(svc: &mut VfsService, verb: &str, args: &[&str]) -> String {
    let esc = |s: &str| s.replace('\\', "\\\\").replace('"', "\\\"");
    match verb {
        "drives" => {
            let mut out = String::from("{\"drives\":[");
            let drives = svc.drives();
            for (i, d) in drives.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                out.push_str(&format!(
                    "{{\"id\":\"{}\",\"model\":\"{}\",\"bytes\":{},\"scheme\":\"{}\",\"volumes\":[",
                    esc(&d.id),
                    esc(&d.model),
                    d.bytes,
                    esc(&d.scheme)
                ));
                let vols = svc.volumes(&d.id).unwrap_or_default();
                for (j, v) in vols.iter().enumerate() {
                    if j > 0 {
                        out.push(',');
                    }
                    out.push_str(&format!(
                        "{{\"index\":{},\"name\":\"{}\",\"fs\":\"{}\",\"label\":\"{}\",\"kind\":\"{}\",\"bytes\":{},\"mountable\":{},\"evidence\":\"{}\"}}",
                        v.index,
                        esc(&v.name),
                        esc(&v.fs),
                        esc(&v.label),
                        esc(&v.kind),
                        v.bytes,
                        v.mountable,
                        esc(&v.evidence)
                    ));
                }
                out.push_str("]}");
            }
            out.push_str("]}");
            out
        }
        "mounts" => {
            let ms = svc.mounts();
            let items: Vec<String> = ms
                .iter()
                .map(|m| {
                    format!(
                        "{{\"name\":\"{}\",\"at\":\"{}\",\"fs\":\"{}\",\"rw\":{},\"os\":\"{}\"}}",
                        esc(&m.name),
                        esc(&m.mnt()),
                        esc(&m.fs),
                        m.rw,
                        esc(m.os.as_deref().unwrap_or(""))
                    )
                })
                .collect();
            format!("{{\"mounts\":[{}]}}", items.join(","))
        }
        "list" => {
            let mount = args.first().copied().unwrap_or("");
            let path = args.get(1).copied().unwrap_or("/");
            match svc.list(mount, path) {
                Ok(ents) => {
                    let items: Vec<String> = ents
                        .iter()
                        .map(|e| {
                            format!(
                                "{{\"name\":\"{}\",\"dir\":{},\"size\":{}}}",
                                esc(&e.name),
                                e.dir,
                                e.size
                            )
                        })
                        .collect();
                    format!(
                        "{{\"mount\":\"{}\",\"path\":\"{}\",\"entries\":[{}]}}",
                        esc(mount),
                        esc(path),
                        items.join(",")
                    )
                }
                Err(e) => format!("{{\"error\":\"{}\"}}", esc(&e)),
            }
        }
        "read" => {
            let mount = args.first().copied().unwrap_or("");
            let path = args.get(1).copied().unwrap_or("");
            match svc.read(mount, path) {
                Ok(b) => format!(
                    "{{\"path\":\"{}\",\"text\":\"{}\"}}",
                    esc(path),
                    esc(&String::from_utf8_lossy(&b))
                ),
                Err(e) => format!("{{\"error\":\"{}\"}}", esc(&e)),
            }
        }
        other => format!("{{\"error\":\"unknown vfs verb {}\"}}", esc(other)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A GPT disk with a real FAT32 ESP holding an EFI loader path.
    fn disk_with_esp() -> Vec<u8> {
        let mut disk = vec![0u8; 8192 * 512];
        // GPT: protective MBR + header + one ESP entry at LBA 2048.
        let esp_guid: [u8; 16] = [
            0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11, 0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E,
            0xC9, 0x3B,
        ];
        disk[446 + 4] = 0xEE;
        disk[510] = 0x55;
        disk[511] = 0xAA;
        let entries_at = 2 * 512;
        disk[entries_at..entries_at + 16].copy_from_slice(&esp_guid);
        disk[entries_at + 32..entries_at + 40].copy_from_slice(&2048u64.to_le_bytes());
        disk[entries_at + 40..entries_at + 48].copy_from_slice(&6143u64.to_le_bytes());
        for (j, ch) in "EFI System".encode_utf16().enumerate() {
            let at = entries_at + 56 + j * 2;
            disk[at..at + 2].copy_from_slice(&ch.to_le_bytes());
        }
        let array_crc = g6b_vfs::part::crc32(&disk[entries_at..entries_at + 128 * 128]);
        let h = 512;
        disk[h..h + 8].copy_from_slice(b"EFI PART");
        disk[h + 12..h + 16].copy_from_slice(&92u32.to_le_bytes());
        disk[h + 24..h + 32].copy_from_slice(&1u64.to_le_bytes());
        disk[h + 72..h + 80].copy_from_slice(&2u64.to_le_bytes());
        disk[h + 80..h + 84].copy_from_slice(&128u32.to_le_bytes());
        disk[h + 84..h + 88].copy_from_slice(&128u32.to_le_bytes());
        disk[h + 88..h + 92].copy_from_slice(&array_crc.to_le_bytes());
        let hdr_crc = g6b_vfs::part::crc32(&disk[h..h + 92]);
        disk[h + 16..h + 20].copy_from_slice(&hdr_crc.to_le_bytes());
        // A FAT32 volume inside the partition, formatted through our own driver.
        let mut part = MemBlock::zeroed(4096 * 512);
        format_fat32(&mut part);
        {
            let mut fs = g6b_vfs::fat32::Fat32::mount(&mut part, true).unwrap();
            fs.mkdir("/EFI").unwrap();
            fs.mkdir("/EFI/BOOT").unwrap();
            fs.write("/EFI/BOOT/BOOTRISCV64.EFI", b"MZ...loader...")
                .unwrap();
            fs.write("/STARTUP.NSH", b"fs0:\\EFI\\BOOT\\BOOTRISCV64.EFI\n")
                .unwrap();
        }
        let bytes = part.into_bytes();
        disk[2048 * 512..2048 * 512 + bytes.len()].copy_from_slice(&bytes);
        disk
    }

    /// Lay a FAT32 BPB + FATs + FSInfo into `dev`, the way `mkfs.vfat` would.
    fn format_fat32(dev: &mut MemBlock) {
        let sectors = (dev.len() / 512) as u32;
        let bps = 512u32;
        let reserved = 32u32;
        let fats = 2u32;
        let fat_sectors = (sectors / 128).clamp(1, 64);
        let mut d = vec![0u8; dev.len() as usize];
        d[0..3].copy_from_slice(&[0xEB, 0x58, 0x90]);
        d[3..11].copy_from_slice(b"g6lcbios");
        d[11..13].copy_from_slice(&(bps as u16).to_le_bytes());
        d[13] = 1;
        d[14..16].copy_from_slice(&(reserved as u16).to_le_bytes());
        d[16] = fats as u8;
        d[32..36].copy_from_slice(&sectors.to_le_bytes());
        d[36..40].copy_from_slice(&fat_sectors.to_le_bytes());
        d[44..48].copy_from_slice(&2u32.to_le_bytes());
        d[48..50].copy_from_slice(&1u16.to_le_bytes());
        d[71..82].copy_from_slice(b"G6LCESP    ");
        d[82..90].copy_from_slice(b"FAT32   ");
        d[510] = 0x55;
        d[511] = 0xAA;
        let fsi = bps as usize;
        d[fsi..fsi + 4].copy_from_slice(&0x4161_5252u32.to_le_bytes());
        d[fsi + 484..fsi + 488].copy_from_slice(&0x6141_7272u32.to_le_bytes());
        let data_sectors = sectors - (reserved + fats * fat_sectors);
        d[fsi + 488..fsi + 492].copy_from_slice(&(data_sectors - 1).to_le_bytes());
        for copy in 0..fats {
            let at = ((reserved + copy * fat_sectors) * bps) as usize;
            d[at..at + 4].copy_from_slice(&0x0FFF_FFF8u32.to_le_bytes());
            d[at + 4..at + 8].copy_from_slice(&0xFFFF_FFFFu32.to_le_bytes());
            d[at + 8..at + 12].copy_from_slice(&0x0FFF_FFFFu32.to_le_bytes());
        }
        dev.write_at(0, &d).unwrap();
    }

    #[test]
    fn drives_volumes_and_a_read_only_mount() {
        let mut svc = VfsService::new().add_image("disk0", disk_with_esp(), "QEMU HARDDISK");
        let drives = svc.drives();
        assert_eq!(drives.len(), 1);
        assert_eq!(drives[0].scheme, "gpt");
        assert!(drives[0].warnings.is_empty(), "{:?}", drives[0].warnings);
        let vols = svc.volumes("disk0").unwrap();
        assert_eq!(vols.len(), 1);
        assert_eq!(vols[0].fs, "fat32");
        assert_eq!(vols[0].kind, "esp");
        assert_eq!(vols[0].label, "G6LCESP");
        assert_eq!(vols[0].name, "g6lcesp");
        assert!(vols[0].mountable);
        // Mount read-only and walk it.
        let m = svc.mount("disk0", 1, "esp", false).unwrap();
        assert!(!m.rw);
        assert_eq!(m.fs, "fat32");
        assert_eq!(m.os.as_deref(), Some("UEFI loader (removable path)"));
        let root = svc.list("esp", "/").unwrap();
        let names: Vec<&str> = root.iter().map(|e| e.name.as_str()).collect();
        assert!(names.contains(&"efi"), "{names:?}");
        assert!(names.contains(&"startup.nsh"), "{names:?}");
        assert!(svc
            .read("esp", "/EFI/BOOT/BOOTRISCV64.EFI")
            .unwrap()
            .starts_with(b"MZ"));
        // A read-only mount refuses the write, and says which mount refused.
        let err = svc.write("esp", "/startup.nsh", b"x").unwrap_err();
        assert!(err.contains("read-only"), "{err}");
        // Unknown things are named, not guessed.
        assert!(svc.list("nope", "/").unwrap_err().contains("not mounted"));
        assert!(svc.volumes("disk9").unwrap_err().contains("no drive"));
    }

    #[test]
    fn a_write_mount_edits_the_volume_and_the_bytes_change() {
        let mut svc = VfsService::new().add_image("disk0", disk_with_esp(), "");
        let m = svc.mount("disk0", 1, "esp", true).unwrap();
        assert!(m.rw, "a clean fat32 on a writable image mounts rw");
        assert!(m.why_ro.is_none());
        svc.write("esp", "/startup.nsh", b"fs0:\\EFI\\BOOT\\OTHER.EFI\n")
            .unwrap();
        assert_eq!(
            svc.read("esp", "/startup.nsh").unwrap(),
            b"fs0:\\EFI\\BOOT\\OTHER.EFI\n"
        );
        // The change is in the image this service holds — not a cache.
        let img = svc.image("disk0").unwrap();
        let needle = b"OTHER.EFI";
        assert!(
            img.windows(needle.len()).any(|w| w == needle),
            "the edit reached the disk image"
        );
        // mkdir/remove work through the same seam.
        svc.mkdir("esp", "/G6LC").unwrap();
        assert!(svc
            .list("esp", "/")
            .unwrap()
            .iter()
            .any(|e| e.name == "g6lc" && e.dir));
        svc.remove("esp", "/G6LC").unwrap();
        // Mount bookkeeping.
        assert_eq!(svc.mounts().len(), 1);
        assert!(svc
            .mount("disk0", 1, "esp", false)
            .unwrap_err()
            .contains("already"));
        svc.umount("esp").unwrap();
        assert!(svc.mounts().is_empty());
        assert!(svc.umount("esp").unwrap_err().contains("not mounted"));
    }

    /// The repair an operator came for, through the shell: walk into a real
    /// Linux `/etc`, open the file in vi, edit it, `:w`, and see the change on the
    /// volume. Nothing here is modelled — it is a real ext4 image and the real
    /// drivers.
    #[test]
    fn the_shell_cds_into_etc_edits_fstab_and_saves_it() {
        use g6b_zealcli::input::Key;
        let spec =
            g6b_spec::BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"barebone"}"#)
                .unwrap();
        let svc = VfsService::new().add_image(
            "disk0",
            g6b_vfs::ext4::tests_image_with_os_release(),
            "QEMU HARDDISK",
        );
        let ports = crate::zealcli::ports(&spec).with_mounts(svc);
        let mut cli = g6b_zealcli::Session::with_ports(&spec, ports);
        // `drives` shows the real drive, its table and what the volume holds.
        let drv = cli.eval("drv").1;
        assert!(drv.contains("disk0"), "{drv}");
        assert!(drv.contains("ext4"), "{drv}");
        // Mount it read-write by name, then walk in. `cd` auto-mounts read-only,
        // so the explicit `-w` is what makes the edit possible.
        let mounted = cli.eval("mount -w disk0:1 as root").1;
        assert!(mounted.contains("mounted root at /mnt/root"), "{mounted}");
        assert!(mounted.contains("rw"), "{mounted}");
        assert!(mounted.contains("G6LC Linux"), "the OS is named: {mounted}");
        assert!(cli.eval("cd /mnt/root/etc").1.is_empty(), "cd into /etc");
        assert_eq!(cli.prompt().trim_end(), "/mnt/root/etc>");
        let ls = cli.eval("ls").1;
        assert!(ls.contains("fstab"), "{ls}");
        assert!(ls.contains("os-release"), "{ls}");
        let cat = cli.eval("cat fstab").1;
        assert!(cat.contains("ext4"), "{cat}");
        // Open it in vi: on a writable mount this is an editor, not a viewer.
        assert!(cli.eval("vi fstab").1.is_empty());
        // Type over the first line: `dd` then `i` + text, then `:w`.
        for k in [Key::Char('d'), Key::Char('d'), Key::Char('i')] {
            cli.key(k);
        }
        for c in "/dev/vda9 / ext4 ro 0 1".chars() {
            cli.key(Key::Char(c));
        }
        cli.key(Key::Esc);
        for c in ":wq".chars() {
            cli.key(Key::Char(c));
        }
        cli.key(Key::Enter);
        // Back at the prompt, and the volume has the new text.
        let frame = cli.render().join("\n");
        assert!(frame.contains("written"), "{frame}");
        let after = cli.eval("cat /mnt/root/etc/fstab").1;
        assert!(after.contains("/dev/vda9 / ext4 ro 0 1"), "{after}");
        // A read-only mount refuses the same edit, and names the reason.
        cli.eval("umount root");
        let ro = cli.eval("mount disk0:1 as ro-root").1;
        assert!(ro.contains("ro"), "{ro}");
        let refused = cli.eval("write /mnt/ro-root/etc/fstab nope").1;
        assert!(refused.contains("read-only"), "{refused}");
    }

    /// One seam, three faces: the HolyC band and the browser UI's JSON must
    /// describe the same disk, because they are the same call underneath.
    /// The edk2/u-boot selector offers a loader because it **read** the file off
    /// a real ESP, and its note says where from — not because a partition type
    /// claimed it.
    #[test]
    fn the_boot_selector_finds_edk2_by_reading_a_real_esp() {
        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"barebone","kernel":{"params":{"edk2":true,"uboot":true}}}"#,
        )
        .unwrap();
        let svc = VfsService::new().add_image("disk0", disk_with_esp(), "QEMU HARDDISK");
        let mut ports = crate::zealcli::ports(&spec).with_mounts(svc);
        let targets = g6b_zealcli::boot::targets(&spec, &mut ports);
        let edk2 = targets
            .iter()
            .find(|t| t.stage == "edk2" && t.present)
            .expect("a present edk2 target from the real ESP");
        assert_eq!(edk2.file, "/EFI/BOOT/BOOTRISCV64.EFI");
        assert!(edk2.note.contains("read from disk0:1"), "{edk2:?}");
        assert!(edk2.note.contains("fat32"), "{edk2:?}");
        assert_eq!(edk2.volume, "g6lcesp");
        // u-boot is enabled but nothing on the volume is u-boot's, so it is not
        // offered as present — a selector that offers an absent loader is a trap.
        assert!(
            !targets
                .iter()
                .any(|t| t.stage == "u-boot" && t.present && t.volume == "g6lcesp"),
            "{targets:#?}"
        );
        // The probe left nothing mounted behind it.
        let mp = ports.mounts.as_mut().unwrap();
        assert!(mp.mounts().is_empty(), "a probe must not hold a mount");
    }

    #[test]
    fn holyc_and_the_browser_ui_see_the_same_filesystem() {
        let mut svc = VfsService::new().add_image("disk0", disk_with_esp(), "QEMU HARDDISK");
        // HolyC band.
        let drives = vfs_request(&mut svc, "Drives", &[]);
        assert!(drives.contains("DRIVE disk0"), "{drives}");
        assert!(drives.contains("fs=fat32"), "{drives}");
        let mounted = vfs_request(&mut svc, "Mount", &["disk0", "1", "esp", "rw"]);
        assert!(mounted.starts_with("MOUNT-OK esp at /mnt/esp"), "{mounted}");
        let ls = vfs_request(&mut svc, "VfsLs", &["esp", "/EFI/BOOT"]);
        assert!(ls.contains("BOOTRISCV64.EFI"), "{ls}");
        assert!(vfs_request(&mut svc, "VfsCat", &["esp", "/startup.nsh"]).contains("EFI"));
        let wrote = vfs_request(&mut svc, "VfsWrite", &["esp", "/notes.txt", "hello"]);
        assert!(wrote.starts_with("VFS-WROTE 5"), "{wrote}");
        assert_eq!(
            vfs_request(&mut svc, "VfsCat", &["esp", "/notes.txt"]),
            "hello"
        );
        assert!(vfs_request(&mut svc, "OsDetect", &["esp"]).starts_with("OS UEFI loader"));
        // Unknown verbs are refused, not guessed.
        assert!(vfs_request(&mut svc, "Format", &[]).contains("unknown verb"));
        // Browser-UI JSON: the same facts, machine-readable.
        let json = vfs_json(&mut svc, "drives", &[]);
        assert!(json.starts_with("{\"drives\":["), "{json}");
        assert!(json.contains("\"fs\":\"fat32\""), "{json}");
        assert!(json.contains("\"mountable\":true"), "{json}");
        let mounts = vfs_json(&mut svc, "mounts", &[]);
        assert!(mounts.contains("\"name\":\"esp\""), "{mounts}");
        assert!(mounts.contains("\"rw\":true"), "{mounts}");
        let list = vfs_json(&mut svc, "list", &["esp", "/EFI/BOOT"]);
        assert!(list.contains("\"name\":\"BOOTRISCV64.EFI\""), "{list}");
        let read = vfs_json(&mut svc, "read", &["esp", "/notes.txt"]);
        assert!(read.contains("\"text\":\"hello\""), "{read}");
        // An error is data too, not a silent empty list.
        assert!(vfs_json(&mut svc, "read", &["esp", "/nope"]).contains("\"error\""));
    }

    /// Editing a file another system wrote must not rewrite the whole file.
    ///
    /// A CRLF `extlinux.conf` on an ESP is the normal case, not an exotic one: the
    /// installer that produced it ran on Windows. If `:w` normalizes the endings,
    /// every line changes, a strict loader can break, and a one-line repair becomes
    /// unreviewable. The BOM is preserved for the same reason.
    #[test]
    fn vi_preserves_crlf_and_a_bom_through_an_edit() {
        use g6b_zealcli::input::Key;
        let spec =
            g6b_spec::BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"barebone"}"#)
                .unwrap();
        // A FAT32 ESP holding a CRLF config with a BOM, as a Windows tool writes.
        let mut part = MemBlock::zeroed(4096 * 512);
        format_fat32(&mut part);
        {
            let mut fs = g6b_vfs::fat32::Fat32::mount(&mut part, true).unwrap();
            fs.write("/BOOT.CFG", "\u{feff}default 0\r\ntimeout 5\r\n".as_bytes())
                .unwrap();
        }
        let svc = VfsService::new().add_image("disk0", part.into_bytes(), "");
        let ports = crate::zealcli::ports(&spec).with_mounts(svc);
        let mut cli = g6b_zealcli::Session::with_ports(&spec, ports);
        assert!(cli.eval("mount -w disk0:1 as esp").1.contains("rw"));
        // The status line says what the file is and what the filesystem allows.
        assert!(cli.eval("vi /mnt/esp/boot.cfg").1.is_empty());
        let frame = cli.render().join("\n");
        assert!(
            frame.contains("[dos]"),
            "the CRLF file is named as such: {frame}"
        );
        assert!(frame.contains("fat32 rw"), "the terms are shown: {frame}");
        // Change the second line's value: `j` then `$` then `x` then `i5`… keep it
        // simple — append a line instead, which is the common repair.
        for k in [Key::Char('G'), Key::Char('o')] {
            cli.key(k);
        }
        for c in "append 1".chars() {
            cli.key(Key::Char(c));
        }
        cli.key(Key::Esc);
        for c in ":wq".chars() {
            cli.key(Key::Char(c));
        }
        cli.key(Key::Enter);
        let out = cli.render().join("\n");
        assert!(out.contains("written and verified"), "{out}");
        // The bytes on the volume: still CRLF, still a BOM, with the new line.
        let raw = cli
            .ports_mut()
            .mounts
            .as_mut()
            .unwrap()
            .read("esp", "/boot.cfg")
            .unwrap();
        let text = String::from_utf8(raw).unwrap();
        assert!(text.starts_with('\u{feff}'), "the BOM survived: {text:?}");
        assert!(text.contains("default 0\r\n"), "CRLF survived: {text:?}");
        assert!(
            text.contains("append 1\r\n"),
            "and the edit landed: {text:?}"
        );
        assert!(
            !text.contains("default 0\n\r"),
            "no mangled pairs: {text:?}"
        );
        assert_eq!(text.matches('\n').count(), text.matches("\r\n").count());
    }

    /// The shell walks a btrfs volume the same way it walks ext4 — `drives`
    /// names the filesystem, mount names the OS it found, and `vi` on a new
    /// file creates it (inline, the way btrfs creates small files anyway).
    #[test]
    fn the_shell_walks_btrfs_and_vi_creates_a_file_on_it() {
        use g6b_zealcli::input::Key;
        let spec =
            g6b_spec::BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"barebone"}"#)
                .unwrap();
        let svc = VfsService::new().add_image(
            "disk0",
            g6b_vfs::btrfs::fixture::image(true),
            "QEMU HARDDISK",
        );
        let ports = crate::zealcli::ports(&spec).with_mounts(svc);
        let mut cli = g6b_zealcli::Session::with_ports(&spec, ports);
        let drv = cli.eval("drv").1;
        assert!(drv.contains("btrfs"), "{drv}");
        let mounted = cli.eval("mount -w disk0:1 as key").1;
        assert!(mounted.contains("rw"), "{mounted}");
        assert!(mounted.contains("G6LC btrfs Linux"), "{mounted}");
        assert!(cli.eval("cd /mnt/key/etc").1.is_empty());
        assert!(cli.eval("cat os-release").1.contains("G6LC btrfs"));
        // In-place: data.bin has real extents — a shorter save stays inside
        // them and the csum tree is refreshed (the driver test checks the
        // checksums). Growing it would be refused: that is extent allocation.
        let b = cli.eval("vi /mnt/key/data.bin").1;
        assert!(b.is_empty(), "{b}");
        let frame = cli.render().join("\n");
        assert!(frame.contains("btrfs rw"), "the terms are shown: {frame}");
        // Replace the file's content: `gg` top, `dd` kills the one long line,
        // `i` + text, `:wq` writes it back inside the same extents.
        for k in [
            Key::Char('g'),
            Key::Char('g'),
            Key::Char('d'),
            Key::Char('d'),
        ] {
            cli.key(k);
        }
        cli.key(Key::Char('i'));
        for c in "repaired=1".chars() {
            cli.key(Key::Char(c));
        }
        cli.key(Key::Esc);
        for c in ":wq".chars() {
            cli.key(Key::Char(c));
        }
        cli.key(Key::Enter);
        let out = cli.render().join("\n");
        assert!(out.contains("written and verified"), "{out}");
        let raw = cli
            .ports_mut()
            .mounts
            .as_mut()
            .unwrap()
            .read("key", "/data.bin")
            .unwrap();
        assert_eq!(raw, b"repaired=1", "shorter in-place write + i_size update");
    }

    /// The ext4 driver now grows a file at the tail by allocating blocks, so a
    /// save that overflows the original block succeeds and the file is larger on
    /// the volume. The editor shows the `ext4 rw` terms up front, and the write
    /// is atomic (all metadata is checksummed) so `e2fsck` would find it clean.
    #[test]
    fn vi_grows_an_ext4_file_past_its_original_block() {
        use g6b_zealcli::input::Key;
        let spec =
            g6b_spec::BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"barebone"}"#)
                .unwrap();
        let svc =
            VfsService::new().add_image("disk0", g6b_vfs::ext4::tests_image_with_os_release(), "");
        let ports = crate::zealcli::ports(&spec).with_mounts(svc);
        let mut cli = g6b_zealcli::Session::with_ports(&spec, ports);
        cli.eval("mount -w disk0:1 as root");
        assert!(cli.eval("vi /mnt/root/etc/fstab").1.is_empty());
        let frame = cli.render().join("\n");
        assert!(
            frame.contains("ext4 rw"),
            "the ext4 terms are visible before typing: {frame}"
        );
        // Type past the one allocated block (1 KiB), then save.
        cli.key(Key::Char('o'));
        for _ in 0..40 {
            for c in "0123456789abcdefghijklmnopqrstuvwxyz".chars() {
                cli.key(Key::Char(c));
            }
            cli.key(Key::Enter);
        }
        cli.key(Key::Esc);
        for c in ":w".chars() {
            cli.key(Key::Char(c));
        }
        cli.key(Key::Enter);
        let frame = cli.render().join("\n");
        assert!(
            frame.contains("written and verified"),
            "save grew the file: {frame}"
        );
        // The file on the volume kept its first line and now has the new bytes.
        let body = cli
            .ports_mut()
            .mounts
            .as_mut()
            .unwrap()
            .read("root", "/etc/fstab")
            .unwrap();
        let text = String::from_utf8_lossy(&body);
        assert!(text.starts_with("/dev/vda2"), "original line preserved");
        assert!(
            body.len() > 1024,
            "file grew past 1 KiB: {} bytes",
            body.len()
        );
    }

    /// **The store round-trips through a real volume.**
    ///
    /// The BIOS UI's SQL goes through the kernel router (`/bios/store/…`), the dump
    /// lands on a **FAT32 USB key** as JSON — which is the point: a key an operator
    /// pulls out must carry something their own OS can read, not a format only this
    /// firmware understands — and a *fresh* registry restores the rows from that
    /// file. Before this, "USB persistence" was a `BTreeMap` in the registry's own
    /// memory: it survived nothing and no other program could read it.
    #[test]
    fn a_store_round_trips_through_a_real_usb_key() {
        use crate::Router;
        use g6b_pglite::StoreRegistry;
        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"barebone","kernel":{"usb":{"key":true},"store":{"enable":true,"persist":{"usb":true,"volume":"fat32"}}}}"#,
        )
        .unwrap();
        // A real FAT32 key: formatted by our own driver, mounted read-write.
        let mut part = MemBlock::zeroed(4096 * 512);
        format_fat32(&mut part);
        let shared =
            SharedVfs::new(VfsService::new().add_image("usb0", part.into_bytes(), "SanDisk"));
        {
            let mut mp: Box<dyn MountPort> = Box::new(shared.clone());
            let m = mp.mount("usb0", 1, "key", true).unwrap();
            assert!(m.rw, "the key is writable: {m:?}");
        }
        let sink: std::rc::Rc<std::cell::RefCell<dyn g6b_pglite::StoreVolume>> =
            std::rc::Rc::new(std::cell::RefCell::new(shared.clone()));

        // ---- the UI's path: SQL over the router, with the store attached --------
        let router = Router::from_spec(&spec);
        let mut reg = StoreRegistry::from_spec(&spec);
        reg.attach_volume(sink.clone());
        assert!(reg.volume_attached(), "a medium, not a memory map");
        let uuid = reg.open_purpose("registry").unwrap();
        let id = uuid.hyphenated();
        let post = |reg: &mut StoreRegistry, path: &str, body: &str| -> (u16, String) {
            let r = router.fetch_with_body("POST", path, body.as_bytes(), Some(reg));
            (r.status, r.body_str())
        };
        let (st, out) = post(
            &mut reg,
            &format!("/bios/store/{id}/exec"),
            r#"{"sql":"CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)"}"#,
        );
        assert_eq!(st, 200, "CREATE TABLE: {out}");
        for (n, body) in [(1, "first boot"), (2, "second boot")] {
            let (st, out) = post(
                &mut reg,
                &format!("/bios/store/{id}/exec"),
                &format!(r#"{{"sql":"INSERT INTO notes (id, body) VALUES ({n}, '{body}')"}}"#),
            );
            assert_eq!(st, 200, "INSERT {n}: {out}");
        }
        let (st, rows) = post(
            &mut reg,
            &format!("/bios/store/{id}/query"),
            r#"{"sql":"SELECT id, body FROM notes"}"#,
        );
        assert_eq!(st, 200, "{rows}");
        assert!(
            rows.contains("first boot") && rows.contains("second boot"),
            "{rows}"
        );

        // ---- persist to the key -------------------------------------------------
        let (st, out) = post(
            &mut reg,
            &format!("/bios/store/{id}/export"),
            r#"{"volume":"fat32","rel":"g6lc/store.json"}"#,
        );
        assert_eq!(st, 200, "export: {out}");

        // ---- the file is on the volume, as JSON, readable without pglite --------
        let mut mp: Box<dyn MountPort> = Box::new(shared.clone());
        let dir = mp.list("key", "/g6lc").unwrap();
        assert!(
            dir.iter()
                .any(|e| e.name.eq_ignore_ascii_case("store.json")),
            "the dump is a file on the key: {dir:?}"
        );
        let raw = mp.read("key", "/g6lc/store.json").unwrap();
        let text = String::from_utf8(raw).expect("JSON text, not a private format");
        assert!(text.starts_with('{'), "{text}");
        assert!(text.contains("notes"), "the table name is in it: {text}");
        assert!(text.contains("second boot"), "and the rows: {text}");

        // ---- a fresh registry restores from the key -----------------------------
        let mut fresh = StoreRegistry::from_spec(&spec);
        fresh.attach_volume(sink);
        let restored = fresh
            .import("fat32", "g6lc/store.json")
            .expect("import from the key");
        let (st, rows) = {
            let r = router.fetch_with_body(
                "POST",
                &format!("/bios/store/{}/query", restored.hyphenated()),
                br#"{"sql":"SELECT id, body FROM notes"}"#,
                Some(&mut fresh),
            );
            (r.status, r.body_str())
        };
        assert_eq!(st, 200, "{rows}");
        assert!(
            rows.contains("first boot") && rows.contains("second boot"),
            "the rows came back off the medium: {rows}"
        );
    }

    /// The filesystem matrix: one store insert/query per driver, with the
    /// expectation that each driver actually offers.
    ///
    /// This exists because a matrix that asserted the *same* outcome for all
    /// four would be asserting something false. `architecture/g6b-vfs.md`
    /// "Editing: the filesystem's terms" is the contract:
    ///
    /// * **fat32 / ext4 / btrfs** create files, so the whole round trip runs:
    ///   insert, query, export, and a *fresh* registry imports the dump off
    ///   the medium and queries the rows back.
    /// * **NTFS** writes *resident `$DATA` in place* and nothing else —
    ///   `can_grow: false`, non-resident and new files refused. With
    ///   `persist.usb` armed the store writes
    ///   `/stores/<purpose>/<uuid>.g6bstore` on **every statement**, so NTFS
    ///   cannot back a persisted store at all and the refusal lands on the
    ///   first `CREATE TABLE`, earlier than "export is refused" would suggest.
    ///   That refusal is the pass condition, not a skipped case — silently
    ///   treating NTFS as "export works" is the mirror of the mistake that put
    ///   "NTFS is read-only" into this repo's notes.
    ///
    /// The SQL text is identical across all four, which is the point: the
    /// store does not care what is underneath until it writes.
    #[test]
    fn the_store_matrix_insert_and_query_per_filesystem() {
        use crate::Router;
        use g6b_pglite::StoreRegistry;

        for fs in g6b_vfs::FIXTURE_KINDS {
            let creates = fs != "ntfs";
            let spec = g6b_spec::BoardSpec::from_json_str(&format!(
                r#"{{"schema_version":1,"profile":"barebone","kernel":{{"usb":{{"key":true,"fs_{fs}":true}},"store":{{"enable":true,"persist":{{"usb":true,"volume":"{fs}"}}}}}}}}"#
            ))
            .unwrap_or_else(|e| panic!("{fs}: spec: {e:?}"));
            let (_, bytes) =
                g6b_vfs::fixture_image_named(fs).unwrap_or_else(|| panic!("{fs}: no fixture"));
            let shared =
                SharedVfs::new(VfsService::new().add_image("usb0", bytes, &format!("{fs} key")));
            {
                let mut mp: Box<dyn MountPort> = Box::new(shared.clone());
                let m = mp
                    .mount("usb0", 1, "key", true)
                    .unwrap_or_else(|e| panic!("{fs}: mount: {e:?}"));
                assert_eq!(m.fs, fs, "{fs}: mounted as {}", m.fs);
            }
            let sink: std::rc::Rc<std::cell::RefCell<dyn g6b_pglite::StoreVolume>> =
                std::rc::Rc::new(std::cell::RefCell::new(shared.clone()));

            let router = Router::from_spec(&spec);
            let mut reg = StoreRegistry::from_spec(&spec);
            reg.attach_volume(sink.clone());
            let id = reg.open_purpose("registry").unwrap().hyphenated();
            let post = |reg: &mut StoreRegistry, path: &str, body: &str| -> (u16, String) {
                let r = router.fetch_with_body("POST", path, body.as_bytes(), Some(reg));
                (r.status, r.body_str())
            };

            // ---- SQL ----
            let (st, out) = post(
                &mut reg,
                &format!("/bios/store/{id}/exec"),
                r#"{"sql":"CREATE TABLE matrix (id INTEGER PRIMARY KEY, body TEXT)"}"#,
            );
            if !creates {
                // NTFS refuses *here*, not at export: with `persist.usb`
                // armed the store writes `/stores/<purpose>/<uuid>.g6bstore`
                // on every statement, and a driver that cannot create a file
                // cannot back a persisted store at all. So the honest
                // statement for NTFS is stronger than "export is refused":
                // the first statement is.
                assert_ne!(
                    st, 200,
                    "{fs}: a persisted store must be refused - this driver cannot create files: {out}"
                );
                // The refusal has to name the path or the medium, or an
                // operator cannot tell it from a broken store engine.
                assert!(
                    out.contains("volume write") || out.contains(fs),
                    "{fs}: refusal is unnamed: {out}"
                );
                continue;
            }
            assert_eq!(st, 200, "{fs}: CREATE TABLE: {out}");
            let (st, out) = post(
                &mut reg,
                &format!("/bios/store/{id}/exec"),
                &format!(r#"{{"sql":"INSERT INTO matrix (id, body) VALUES (1, '{fs} row')"}}"#),
            );
            assert_eq!(st, 200, "{fs}: INSERT: {out}");
            let (st, rows) = post(
                &mut reg,
                &format!("/bios/store/{id}/query"),
                r#"{"sql":"SELECT id, body FROM matrix"}"#,
            );
            assert_eq!(st, 200, "{fs}: SELECT: {rows}");
            assert!(rows.contains(&format!("{fs} row")), "{fs}: {rows}");

            // ---- export to the medium ----
            let rel = "g6lc/store.json";
            let (st, out) = post(
                &mut reg,
                &format!("/bios/store/{id}/export"),
                &format!(r#"{{"volume":"{fs}","rel":"{rel}"}}"#),
            );
            assert_eq!(st, 200, "{fs}: export: {out}");

            // The dump is really on the medium, as JSON a reader can open.
            let mut mp: Box<dyn MountPort> = Box::new(shared.clone());
            let raw = mp
                .read("key", &format!("/{rel}"))
                .unwrap_or_else(|e| panic!("{fs}: read back {rel}: {e:?}"));
            let text = String::from_utf8(raw).unwrap_or_else(|_| panic!("{fs}: JSON text"));
            assert!(
                text.contains("matrix") && text.contains(&format!("{fs} row")),
                "{fs}: {text}"
            );

            // A fresh registry imports it and the rows come back — the half
            // that proves the export was a database and not just bytes.
            let mut fresh = StoreRegistry::from_spec(&spec);
            fresh.attach_volume(sink);
            let restored = fresh
                .import(fs, rel)
                .unwrap_or_else(|e| panic!("{fs}: import: {e:?}"));
            let r = router.fetch_with_body(
                "POST",
                &format!("/bios/store/{}/query", restored.hyphenated()),
                br#"{"sql":"SELECT id, body FROM matrix"}"#,
                Some(&mut fresh),
            );
            assert_eq!(r.status, 200, "{fs}: restored query: {}", r.body_str());
            assert!(
                r.body_str().contains(&format!("{fs} row")),
                "{fs}: restored rows: {}",
                r.body_str()
            );
        }
    }

    /// **The same store round-trips through btrfs** — the proof that pglite
    /// persistence rides the shared VFS seam, not a FAT32-only path: the dump is
    /// created (inline extent) on the volume, readable as JSON off the medium,
    /// and a fresh registry imports it back.
    #[test]
    fn a_store_round_trips_through_btrfs() {
        use crate::Router;
        use g6b_pglite::StoreRegistry;
        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"barebone","kernel":{"usb":{"key":true,"fs_btrfs":true},"store":{"enable":true,"persist":{"usb":true,"volume":"btrfs"}}}}"#,
        )
        .unwrap();
        let shared = SharedVfs::new(VfsService::new().add_image(
            "usb0",
            g6b_vfs::btrfs::fixture::image(false),
            "btrfs key",
        ));
        {
            let mut mp: Box<dyn MountPort> = Box::new(shared.clone());
            let m = mp.mount("usb0", 1, "key", true).unwrap();
            assert!(m.rw, "single-device btrfs mounts rw: {m:?}");
            assert_eq!(m.fs, "btrfs");
            // The fixture's /etc/os-release is read through the new driver.
            assert_eq!(m.os.as_deref(), Some("G6LC btrfs Linux"));
        }
        let sink: std::rc::Rc<std::cell::RefCell<dyn g6b_pglite::StoreVolume>> =
            std::rc::Rc::new(std::cell::RefCell::new(shared.clone()));

        let router = Router::from_spec(&spec);
        let mut reg = StoreRegistry::from_spec(&spec);
        reg.attach_volume(sink.clone());
        let uuid = reg.open_purpose("registry").unwrap();
        let id = uuid.hyphenated();
        let post = |reg: &mut StoreRegistry, path: &str, body: &str| -> (u16, String) {
            let r = router.fetch_with_body("POST", path, body.as_bytes(), Some(reg));
            (r.status, r.body_str())
        };
        let (st, out) = post(
            &mut reg,
            &format!("/bios/store/{id}/exec"),
            r#"{"sql":"CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)"}"#,
        );
        assert_eq!(st, 200, "CREATE TABLE: {out}");
        let (st, out) = post(
            &mut reg,
            &format!("/bios/store/{id}/exec"),
            r#"{"sql":"INSERT INTO notes (id, body) VALUES (1, 'btrfs boot')"}"#,
        );
        assert_eq!(st, 200, "INSERT: {out}");
        let (st, out) = post(
            &mut reg,
            &format!("/bios/store/{id}/export"),
            r#"{"volume":"btrfs","rel":"g6lc/store.json"}"#,
        );
        assert_eq!(st, 200, "export to btrfs: {out}");

        // The file is on the medium — created inline, JSON a reader can open.
        let mut mp: Box<dyn MountPort> = Box::new(shared.clone());
        let raw = mp.read("key", "/g6lc/store.json").unwrap();
        let text = String::from_utf8(raw).expect("JSON text");
        assert!(
            text.contains("notes") && text.contains("btrfs boot"),
            "{text}"
        );

        let mut fresh = StoreRegistry::from_spec(&spec);
        fresh.attach_volume(sink);
        let restored = fresh
            .import("btrfs", "g6lc/store.json")
            .expect("import from the btrfs key");
        let (st, rows) = {
            let r = router.fetch_with_body(
                "POST",
                &format!("/bios/store/{}/query", restored.hyphenated()),
                br#"{"sql":"SELECT id, body FROM notes"}"#,
                Some(&mut fresh),
            );
            (r.status, r.body_str())
        };
        assert_eq!(st, 200, "{rows}");
        assert!(rows.contains("btrfs boot"), "{rows}");
    }

    /// **The wasm UI's own host seam runs the SQL** — the write side a Svelte page
    /// uses, not a Rust-side shortcut.
    ///
    /// `WasmUi`'s host could only GET, so a page could read settings and never touch
    /// the store: `CREATE TABLE` from the UI was impossible whatever the engine
    /// supported. This drives `fetch_post` exactly as the libwasm cell's
    /// `Object_Call_string__Handle("fetch_post", url, body)` does, and checks the
    /// gate: the store answers, everything else is refused.
    #[test]
    fn the_ui_host_posts_sql_to_the_store_and_nowhere_else() {
        use crate::Router;
        use g6b_pglite::StoreRegistry;
        use g6b_wasm::KernelPort;
        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"full","kernel":{"usb":{"key":true},"http":{"enable":true,"proxy_js":true},"store":{"enable":true,"persist":{"usb":true,"volume":"fat32"}}}}"#,
        )
        .unwrap();
        let mut part = MemBlock::zeroed(4096 * 512);
        format_fat32(&mut part);
        let shared = SharedVfs::new(VfsService::new().add_image("usb0", part.into_bytes(), "Key"));
        {
            let mut mp: Box<dyn MountPort> = Box::new(shared.clone());
            mp.mount("usb0", 1, "key", true).unwrap();
        }
        let mut reg = StoreRegistry::from_spec(&spec);
        reg.attach_volume(std::rc::Rc::new(std::cell::RefCell::new(shared.clone())));
        let uuid = reg.open_purpose("registry").unwrap();
        let router = Router::from_spec(&spec);
        let mut port = crate::browser::RouterPort {
            router: &router,
            spec: &spec,
            store: Some(&mut reg),
        };
        let id = uuid.hyphenated();
        let (st, out) = port
            .fetch_post(
                &format!("/bios/store/{id}/exec"),
                r#"{"sql":"CREATE TABLE ui_notes (id INTEGER PRIMARY KEY, body TEXT)"}"#,
            )
            .unwrap();
        assert_eq!(st, 200, "the UI created a table: {out}");
        let (st, out) = port
            .fetch_post(
                &format!("/bios/store/{id}/exec"),
                r#"{"sql":"INSERT INTO ui_notes (id, body) VALUES (7, 'from svelte')"}"#,
            )
            .unwrap();
        assert_eq!(st, 200, "{out}");
        let (st, rows) = port
            .fetch_post(
                &format!("/bios/store/{id}/query"),
                r#"{"sql":"SELECT body FROM ui_notes"}"#,
            )
            .unwrap();
        assert_eq!(st, 200, "{rows}");
        assert!(rows.contains("from svelte"), "{rows}");
        // Persisting is a UI action too, and it reaches the medium.
        let (st, out) = port
            .fetch_post(
                &format!("/bios/store/{id}/export"),
                r#"{"volume":"fat32","rel":"g6lc/ui.json"}"#,
            )
            .unwrap();
        assert_eq!(st, 200, "{out}");
        // The gate: a POST anywhere else is refused, by path, before the router.
        for path in ["/bios/power", "/bios/flash", "/bios/menu/cpu", "/ui/app.js"] {
            let err = port.fetch_post(path, "{}").unwrap_err();
            assert!(
                err.contains("/bios/store only"),
                "{path} must be refused by the gate: {err}"
            );
        }
        // And the bytes are on the key, as JSON.
        let mut mp: Box<dyn MountPort> = Box::new(shared);
        let text = String::from_utf8(mp.read("key", "/g6lc/ui.json").unwrap()).unwrap();
        assert!(
            text.contains("ui_notes") && text.contains("from svelte"),
            "{text}"
        );
    }

    /// **A libwasm `_start` runs the whole `fetch_post` import chain.**
    ///
    /// This is the shape a generated Svelte/libwasm cell emits:
    /// `libwasm_global("window")` for the host object, then
    /// `Object_Call_string_string__Handle(window, "fetch_post", url, body)` for
    /// every store verb, with `libwasm_get__string` reading each response body
    /// back into linear memory. The cell opens the `registry` store, creates a
    /// table, inserts, selects — the SELECT response is painted into `#status`
    /// the way a page would show it — and exports to the FAT32 key. Afterwards
    /// the dump is a file on the volume a *fresh* registry can import.
    ///
    /// The uuid in the op URLs is the one `open_purpose` minted: a real cell
    /// parses it out of the `open` response; hand-encoding a JSON parse in wasm
    /// would test the parser, not this path, so the test learns it beforehand.
    #[test]
    fn a_libwasm_cell_posts_sql_through_fetch_post_to_a_usb_key() {
        use g6b_wasm::{Export, FuncType, Import, Instr, Module, ValType};

        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"full","kernel":{"usb":{"key":true},"http":{"enable":true,"proxy_js":true},"store":{"enable":true,"persist":{"usb":true,"volume":"fat32"}}}}"#,
        )
        .unwrap();
        let mut part = MemBlock::zeroed(4096 * 512);
        format_fat32(&mut part);
        let shared = SharedVfs::new(VfsService::new().add_image("usb0", part.into_bytes(), "Key"));
        {
            let mut mp: Box<dyn MountPort> = Box::new(shared.clone());
            mp.mount("usb0", 1, "key", true).unwrap();
        }
        let mut session = crate::BrowserSession::new(&spec).unwrap();
        session
            .program
            .store
            .attach_volume(std::rc::Rc::new(std::cell::RefCell::new(shared.clone())));
        let uuid = session
            .program
            .store
            .open_purpose("registry")
            .unwrap()
            .hyphenated();

        // ---- the cell -----------------------------------------------------
        const SRET: i32 = 8192;
        let mut mem = vec![0u8; 65536];
        let mut at = 256usize;
        let intern = |mem: &mut [u8], at: &mut usize, s: &str| {
            let off = *at;
            mem[off..off + s.len()].copy_from_slice(s.as_bytes());
            *at = (*at + s.len() + 3) & !3;
            (off as i32, s.len() as i32)
        };
        let (win_ptr, win_len) = intern(&mut mem, &mut at, "window");
        let (fp_ptr, fp_len) = intern(&mut mem, &mut at, "fetch_post");
        let (st_ptr, st_len) = intern(&mut mem, &mut at, "status");
        let (open_url_ptr, open_url_len) = intern(&mut mem, &mut at, "/bios/store/open");
        let (open_ptr, open_len) = intern(&mut mem, &mut at, r#"{"dataDir":"registry"}"#);
        let exec_url = format!("/bios/store/{uuid}/exec");
        let (exec_ptr_, exec_len_) = intern(&mut mem, &mut at, &exec_url);
        let (create_ptr, create_len) = intern(
            &mut mem,
            &mut at,
            r#"{"sql":"CREATE TABLE ui_boot (id INTEGER PRIMARY KEY, body TEXT)"}"#,
        );
        let (ins_ptr, ins_len) = intern(
            &mut mem,
            &mut at,
            r#"{"sql":"INSERT INTO ui_boot (id, body) VALUES (1, 'written by the ui')"}"#,
        );
        let q_url = format!("/bios/store/{uuid}/query");
        let (q_ptr, q_len) = intern(&mut mem, &mut at, &q_url);
        let (sel_ptr, sel_len) = intern(
            &mut mem,
            &mut at,
            r#"{"sql":"SELECT id, body FROM ui_boot"}"#,
        );
        let exp_url = format!("/bios/store/{uuid}/export");
        let (exp_ptr_, exp_len_) = intern(&mut mem, &mut at, &exp_url);
        let (expb_ptr, expb_len) = intern(
            &mut mem,
            &mut at,
            r#"{"volume":"fat32","rel":"g6lc/wasm-store.json"}"#,
        );

        // fetch_post(win, url_ptr/len, body_ptr/len) -> LocalSet(1)
        let post = |u: (i32, i32), b: (i32, i32)| -> Vec<Instr> {
            vec![
                Instr::LocalGet(0),
                Instr::I32Const(fp_len),
                Instr::I32Const(fp_ptr),
                Instr::I32Const(u.1),
                Instr::I32Const(u.0),
                Instr::I32Const(b.1),
                Instr::I32Const(b.0),
                Instr::Call(1),
                Instr::LocalSet(1),
            ]
        };
        // Paint the interned response handle into #status.
        let paint = |body: &mut Vec<Instr>| {
            body.extend([
                Instr::I32Const(SRET),
                Instr::LocalGet(1),
                Instr::Call(2),
                Instr::I32Const(st_ptr),
                Instr::I32Const(st_len),
                Instr::I32Const(SRET),
                Instr::I32Load {
                    align: 0,
                    offset: 4,
                },
                Instr::I32Const(SRET),
                Instr::I32Load {
                    align: 0,
                    offset: 0,
                },
                Instr::Call(3),
            ]);
        };
        let mut body = vec![
            // win = libwasm_global("window")
            Instr::I32Const(win_len),
            Instr::I32Const(win_ptr),
            Instr::Call(0),
            Instr::LocalSet(0),
        ];
        body.extend(post((open_url_ptr, open_url_len), (open_ptr, open_len)));
        paint(&mut body);
        body.extend(post((exec_ptr_, exec_len_), (create_ptr, create_len)));
        body.extend(post((exec_ptr_, exec_len_), (ins_ptr, ins_len)));
        body.extend(post((q_ptr, q_len), (sel_ptr, sel_len)));
        paint(&mut body);
        body.extend(post((exp_ptr_, exp_len_), (expb_ptr, expb_len)));
        body.push(Instr::End);

        let m = Module {
            types: vec![
                FuncType {
                    params: vec![ValType::I32; 2],
                    results: vec![ValType::I32],
                },
                FuncType {
                    params: vec![ValType::I32; 7],
                    results: vec![ValType::I32],
                },
                FuncType {
                    params: vec![ValType::I32; 2],
                    results: vec![],
                },
                FuncType {
                    params: vec![ValType::I32; 4],
                    results: vec![],
                },
                FuncType {
                    params: vec![],
                    results: vec![],
                },
            ],
            imports: vec![
                Import {
                    module: "env".into(),
                    name: "libwasm_global".into(),
                    typeidx: 0,
                },
                Import {
                    module: "env".into(),
                    name: "Object_Call_string_string__Handle".into(),
                    typeidx: 1,
                },
                Import {
                    module: "env".into(),
                    name: "libwasm_get__string".into(),
                    typeidx: 2,
                },
                Import {
                    module: "env".into(),
                    name: g6b_wasm::IMPORT_SET_INNER_TEXT.into(),
                    typeidx: 3,
                },
            ],
            func_types: vec![4],
            mem_pages: 1,
            max_mem_pages: None,
            exports: vec![Export {
                name: "_start".into(),
                kind: 0,
                idx: 4,
            }],
            bodies: vec![body],
            memory: mem,
            locals: vec![2],
            has_memory: true,
            tags: vec![],
            globals: vec![],
            tables: vec![],
            elements: vec![],
            data_count: None,
            data_segments: vec![],
        };

        let mut host = crate::KernelHost::attach_fresh(
            &mut session.dom,
            &session.program.router,
            &spec,
            Vec::new(),
            &mut session.timers,
            0,
            Some(&mut session.program.store),
        );
        crate::run_libwasm_start(&m, &mut host).unwrap_or_else(|e| {
            panic!(
                "fetch_post _start: {e}\ndiagnostics: {:?}",
                host.diagnostics
            )
        });
        for want in [
            "WASM-POST /bios/store/open 200".to_string(),
            format!("WASM-POST {exec_url} 200"),
            format!("WASM-POST {q_url} 200"),
            format!("WASM-POST {exp_url} 200"),
        ] {
            assert!(
                host.diagnostics.iter().any(|d| d == &want),
                "missing {want}: {:?}",
                host.diagnostics
            );
        }
        drop(host);
        // The SELECT response the cell painted into the page carries the row.
        let status = session
            .dom
            .get_element_by_id("status")
            .unwrap()
            .inner_text();
        assert!(status.contains("written by the ui"), "{status}");

        // And the dump is JSON on the key, importable by a fresh registry.
        let mut mp: Box<dyn MountPort> = Box::new(shared.clone());
        let text = String::from_utf8(mp.read("key", "/g6lc/wasm-store.json").unwrap()).unwrap();
        assert!(
            text.contains("ui_boot") && text.contains("written by the ui"),
            "{text}"
        );
        let mut fresh = g6b_pglite::StoreRegistry::from_spec(&spec);
        fresh.attach_volume(std::rc::Rc::new(std::cell::RefCell::new(shared)));
        let restored = fresh.import("fat32", "g6lc/wasm-store.json").unwrap();
        let out = fresh
            .query(restored, "SELECT body FROM ui_boot", &[])
            .unwrap();
        assert_eq!(out.rows.len(), 1);
    }

    /// **The same libwasm `_start` shape, but the USB key is btrfs.**
    ///
    /// A Svelte/libwasm cell opens the registry on the btrfs volume, creates a
    /// table, inserts two rows, selects them back, paints the JSON into `#status`,
    /// and exports the dump to the key. A fresh registry then imports the dump and
    /// queries it, proving the whole pglite → shared VFS → btrfs r/w path.
    #[test]
    fn a_libwasm_cell_posts_sql_through_fetch_post_to_a_btrfs_key() {
        use g6b_wasm::{Export, FuncType, Import, Instr, Module, ValType};

        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"full","kernel":{"usb":{"key":true,"fs_btrfs":true},"http":{"enable":true,"proxy_js":true},"store":{"enable":true,"persist":{"usb":true,"volume":"btrfs"}}}}"#,
        )
        .unwrap();
        let shared = SharedVfs::new(VfsService::new().add_image(
            "usb0",
            g6b_vfs::btrfs::fixture::image(false),
            "btrfs key",
        ));
        {
            let mut mp: Box<dyn MountPort> = Box::new(shared.clone());
            let m = mp.mount("usb0", 1, "key", true).unwrap();
            assert!(m.rw, "single-device btrfs mounts rw: {m:?}");
            assert_eq!(m.fs, "btrfs");
        }
        let mut session = crate::BrowserSession::new(&spec).unwrap();
        session
            .program
            .store
            .attach_volume(std::rc::Rc::new(std::cell::RefCell::new(shared.clone())));
        let uuid = session
            .program
            .store
            .open_purpose("registry")
            .unwrap()
            .hyphenated();

        // ---- the cell -----------------------------------------------------
        const SRET: i32 = 8192;
        let mut mem = vec![0u8; 65536];
        let mut at = 256usize;
        let intern = |mem: &mut [u8], at: &mut usize, s: &str| {
            let off = *at;
            mem[off..off + s.len()].copy_from_slice(s.as_bytes());
            *at = (*at + s.len() + 3) & !3;
            (off as i32, s.len() as i32)
        };
        let (win_ptr, win_len) = intern(&mut mem, &mut at, "window");
        let (fp_ptr, fp_len) = intern(&mut mem, &mut at, "fetch_post");
        let (st_ptr, st_len) = intern(&mut mem, &mut at, "status");
        let (open_url_ptr, open_url_len) = intern(&mut mem, &mut at, "/bios/store/open");
        let (open_ptr, open_len) = intern(&mut mem, &mut at, r#"{"dataDir":"registry"}"#);
        let exec_url = format!("/bios/store/{uuid}/exec");
        let (exec_ptr_, exec_len_) = intern(&mut mem, &mut at, &exec_url);
        let (create_ptr, create_len) = intern(
            &mut mem,
            &mut at,
            r#"{"sql":"CREATE TABLE ui_btrfs (id INTEGER PRIMARY KEY, body TEXT)"}"#,
        );
        let (ins1_ptr, ins1_len) = intern(
            &mut mem,
            &mut at,
            r#"{"sql":"INSERT INTO ui_btrfs (id, body) VALUES (1, 'btrfs row one')"}"#,
        );
        let (ins2_ptr, ins2_len) = intern(
            &mut mem,
            &mut at,
            r#"{"sql":"INSERT INTO ui_btrfs (id, body) VALUES (2, 'btrfs row two')"}"#,
        );
        let q_url = format!("/bios/store/{uuid}/query");
        let (q_ptr, q_len) = intern(&mut mem, &mut at, &q_url);
        let (sel_ptr, sel_len) = intern(
            &mut mem,
            &mut at,
            r#"{"sql":"SELECT id, body FROM ui_btrfs"}"#,
        );
        let exp_url = format!("/bios/store/{uuid}/export");
        let (exp_ptr_, exp_len_) = intern(&mut mem, &mut at, &exp_url);
        let (expb_ptr, expb_len) = intern(
            &mut mem,
            &mut at,
            r#"{"volume":"btrfs","rel":"g6lc/wasm-store-btrfs.json"}"#,
        );

        // fetch_post(win, url_ptr/len, body_ptr/len) -> LocalSet(1)
        let post = |u: (i32, i32), b: (i32, i32)| -> Vec<Instr> {
            vec![
                Instr::LocalGet(0),
                Instr::I32Const(fp_len),
                Instr::I32Const(fp_ptr),
                Instr::I32Const(u.1),
                Instr::I32Const(u.0),
                Instr::I32Const(b.1),
                Instr::I32Const(b.0),
                Instr::Call(1),
                Instr::LocalSet(1),
            ]
        };
        // Paint the interned response handle into #status.
        let paint = |body: &mut Vec<Instr>| {
            body.extend([
                Instr::I32Const(SRET),
                Instr::LocalGet(1),
                Instr::Call(2),
                Instr::I32Const(st_ptr),
                Instr::I32Const(st_len),
                Instr::I32Const(SRET),
                Instr::I32Load {
                    align: 0,
                    offset: 4,
                },
                Instr::I32Const(SRET),
                Instr::I32Load {
                    align: 0,
                    offset: 0,
                },
                Instr::Call(3),
            ]);
        };
        let mut body = vec![
            // win = libwasm_global("window")
            Instr::I32Const(win_len),
            Instr::I32Const(win_ptr),
            Instr::Call(0),
            Instr::LocalSet(0),
        ];
        body.extend(post((open_url_ptr, open_url_len), (open_ptr, open_len)));
        paint(&mut body);
        body.extend(post((exec_ptr_, exec_len_), (create_ptr, create_len)));
        body.extend(post((exec_ptr_, exec_len_), (ins1_ptr, ins1_len)));
        body.extend(post((exec_ptr_, exec_len_), (ins2_ptr, ins2_len)));
        body.extend(post((q_ptr, q_len), (sel_ptr, sel_len)));
        paint(&mut body);
        body.extend(post((exp_ptr_, exp_len_), (expb_ptr, expb_len)));
        body.push(Instr::End);

        let m = Module {
            types: vec![
                FuncType {
                    params: vec![ValType::I32; 2],
                    results: vec![ValType::I32],
                },
                FuncType {
                    params: vec![ValType::I32; 7],
                    results: vec![ValType::I32],
                },
                FuncType {
                    params: vec![ValType::I32; 2],
                    results: vec![],
                },
                FuncType {
                    params: vec![ValType::I32; 4],
                    results: vec![],
                },
                FuncType {
                    params: vec![],
                    results: vec![],
                },
            ],
            imports: vec![
                Import {
                    module: "env".into(),
                    name: "libwasm_global".into(),
                    typeidx: 0,
                },
                Import {
                    module: "env".into(),
                    name: "Object_Call_string_string__Handle".into(),
                    typeidx: 1,
                },
                Import {
                    module: "env".into(),
                    name: "libwasm_get__string".into(),
                    typeidx: 2,
                },
                Import {
                    module: "env".into(),
                    name: g6b_wasm::IMPORT_SET_INNER_TEXT.into(),
                    typeidx: 3,
                },
            ],
            func_types: vec![4],
            mem_pages: 1,
            max_mem_pages: None,
            exports: vec![Export {
                name: "_start".into(),
                kind: 0,
                idx: 4,
            }],
            bodies: vec![body],
            memory: mem,
            locals: vec![2],
            has_memory: true,
            tags: vec![],
            globals: vec![],
            tables: vec![],
            elements: vec![],
            data_count: None,
            data_segments: vec![],
        };

        let mut host = crate::KernelHost::attach_fresh(
            &mut session.dom,
            &session.program.router,
            &spec,
            Vec::new(),
            &mut session.timers,
            0,
            Some(&mut session.program.store),
        );
        crate::run_libwasm_start(&m, &mut host).unwrap_or_else(|e| {
            panic!(
                "fetch_post _start (btrfs): {e}\ndiagnostics: {:?}",
                host.diagnostics
            )
        });
        for want in [
            "WASM-POST /bios/store/open 200".to_string(),
            format!("WASM-POST {exec_url} 200"),
            format!("WASM-POST {q_url} 200"),
            format!("WASM-POST {exp_url} 200"),
        ] {
            assert!(
                host.diagnostics.iter().any(|d| d == &want),
                "missing {want}: {:?}",
                host.diagnostics
            );
        }
        drop(host);
        // The SELECT response the cell painted into the page carries both rows.
        let status = session
            .dom
            .get_element_by_id("status")
            .unwrap()
            .inner_text();
        assert!(status.contains("btrfs row one"), "{status}");
        assert!(status.contains("btrfs row two"), "{status}");

        // And the dump is JSON on the key, importable by a fresh registry.
        let mut mp: Box<dyn MountPort> = Box::new(shared.clone());
        let text =
            String::from_utf8(mp.read("key", "/g6lc/wasm-store-btrfs.json").unwrap()).unwrap();
        assert!(
            text.contains("ui_btrfs")
                && text.contains("btrfs row one")
                && text.contains("btrfs row two"),
            "{text}"
        );
        let mut fresh = g6b_pglite::StoreRegistry::from_spec(&spec);
        fresh.attach_volume(std::rc::Rc::new(std::cell::RefCell::new(shared)));
        let restored = fresh.import("btrfs", "g6lc/wasm-store-btrfs.json").unwrap();
        let out = fresh
            .query(restored, "SELECT body FROM ui_btrfs", &[])
            .unwrap();
        assert_eq!(out.rows.len(), 2);
    }

    #[test]
    fn os_detection_reads_the_volume_not_a_table() {
        // An ext4 root with `/etc/os-release` is named by that file.
        let img = g6b_vfs::ext4::tests_image_with_os_release();
        let mut svc = VfsService::new().add_image("disk1", img, "");
        // No partition table → the whole disk is partition 1.
        let vols = svc.volumes("disk1").unwrap();
        assert_eq!(vols.len(), 1);
        assert_eq!(vols[0].fs, "ext4");
        let m = svc.mount("disk1", 1, "root", false).unwrap();
        assert_eq!(m.os.as_deref(), Some("G6LC Linux 1.0"));
        assert_eq!(svc.os_info("root").as_deref(), Some("G6LC Linux 1.0"));
        // And the repair path an operator came for.
        let fstab = svc.read("root", "/etc/fstab").unwrap();
        assert!(String::from_utf8_lossy(&fstab).contains("ext4"));
    }
}
