// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! `g6b-vfs` — real block devices, partition tables and filesystems behind one
//! mount table.
//!
//! This is the layer the whole BIOS shares. The setup shell (`g6b-zealcli`) walks
//! it with `cd`/`ls`/`cat`/`vi`, the boot picker probes it to say what a medium
//! holds, HolyC reaches it through builtins, and the browser UI reaches the same
//! mounts over the kernel's router (JS/WASM) — one implementation, so what the
//! text face shows and what the graphical face shows cannot disagree.
//!
//! ```text
//!   Vfs (mount table, friendly names, path resolution)
//!     └── FileSystem  ── fat32 (rw) · ext4 (ro + guarded rw) · ntfs (ro)
//!           └── BlockDev ── FileBlock (host image / raw disk) · SubDev (partition) · MemBlock
//! ```
//!
//! Three rules hold everywhere in here, because this code can destroy an
//! operator's system:
//!
//! 1. **Evidence over claims.** A partition type says what a table *claims*; the
//!    superblock says what is *there* ([`probe`]). The superblock wins.
//! 2. **Read-only is the default, and a refusal is explicit.** Writability comes
//!    from the device, then the mount, then the filesystem's own state (a dirty
//!    ext journal blocks a write mount and says so). No path silently downgrades.
//! 3. **No half-writes.** An allocation that cannot fit fails before anything is
//!    written, and every metadata copy (both FATs, the FSInfo count) is updated.

#![allow(missing_docs)]

pub mod block;
pub mod btrfs;
pub mod ext4;
pub mod fat32;
pub mod ntfs;
pub mod part;
pub mod probe;

pub use block::{BlockDev, FileBlock, MemBlock, SubDev};
pub use part::{Partition, Scheme, Table};
pub use probe::{FsKind, Probe};

/// Everything that can go wrong, named so the shell can print it verbatim.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    /// Host I/O.
    Io(String),
    /// A read or write outside the device/partition.
    OutOfRange,
    /// The device is too small to hold what was asked for.
    TooSmall,
    /// Structure that cannot be what it claims to be.
    Corrupt(&'static str),
    /// No such table/filesystem/feature here.
    NotFound,
    /// No such path on this filesystem.
    NotFoundPath(String),
    /// A path component that must be a directory is not one.
    NotADir(String),
    /// A directory where a file was needed.
    IsADir(String),
    /// The path already exists.
    Exists(String),
    /// A directory that still has children.
    NotEmpty(String),
    /// Out of space on the volume.
    NoSpace,
    /// The name cannot be represented on this filesystem.
    BadName(String),
    /// Writing is refused, and this is what refused it.
    ReadOnly(&'static str),
    /// The driver exists but this operation is not implemented for it; the text
    /// says what would be needed.
    Unsupported(String),
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(m) => write!(f, "io: {m}"),
            Self::OutOfRange => write!(f, "read/write outside the device"),
            Self::TooSmall => write!(f, "device is too small for that structure"),
            Self::Corrupt(m) => write!(f, "corrupt: {m}"),
            Self::NotFound => write!(f, "not found"),
            Self::NotFoundPath(p) => write!(f, "{p}: no such file or directory"),
            Self::NotADir(p) => write!(f, "{p}: not a directory"),
            Self::IsADir(p) => write!(f, "{p}: is a directory"),
            Self::Exists(p) => write!(f, "{p}: already exists"),
            Self::NotEmpty(p) => write!(f, "{p}: directory is not empty"),
            Self::NoSpace => write!(f, "no space left on the volume"),
            Self::BadName(m) => write!(f, "{m}"),
            Self::ReadOnly(what) => write!(f, "read-only: {what}"),
            Self::Unsupported(m) => write!(f, "unsupported: {m}"),
        }
    }
}

pub type Result<T> = std::result::Result<T, Error>;

/// One directory entry, filesystem-independent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DirEnt {
    pub name: String,
    pub dir: bool,
    pub size: u64,
    pub read_only: bool,
    pub hidden: bool,
}

/// What `stat` answers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Stat {
    pub dir: bool,
    pub size: u64,
    pub read_only: bool,
}

/// What a write to one path *could* do on this filesystem — answered **before** a
/// write is attempted.
///
/// An editor needs this. The alternative is letting an operator retype a boot
/// config, press `:w`, and only then learn that this driver cannot grow an ext4
/// file: the work is lost and the reason arrives too late to act on. So every
/// driver states its terms up front, and the editor shows them in the status line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EditBudget {
    pub fs: FsKind,
    /// The path exists.
    pub exists: bool,
    pub size: u64,
    /// A write to this path can succeed at all.
    pub writable: bool,
    /// Largest content the path can hold. `None` means "bounded only by the
    /// volume", which is what a driver that can allocate reports.
    pub max_bytes: Option<u64>,
    /// The driver can create a path that is not there yet (so an editor can offer
    /// `:w newfile`, and a repair can keep a backup).
    pub can_create: bool,
    /// The driver can make an existing file longer than it is.
    pub can_grow: bool,
    /// Why writing is refused or bounded, in terms an operator can act on.
    pub why: Option<String>,
}

impl EditBudget {
    /// A refusal with a reason — the shape every driver without a writer returns.
    pub fn refused(fs: FsKind, size: u64, exists: bool, why: impl Into<String>) -> Self {
        Self {
            fs,
            exists,
            size,
            writable: false,
            max_bytes: Some(0),
            can_create: false,
            can_grow: false,
            why: Some(why.into()),
        }
    }

    /// Would `len` bytes be accepted? The message is the refusal an editor prints.
    pub fn accepts(&self, len: u64) -> std::result::Result<(), String> {
        if !self.writable {
            return Err(self
                .why
                .clone()
                .unwrap_or_else(|| format!("{} is not writable here", self.fs.as_str())));
        }
        if let Some(max) = self.max_bytes {
            if len > max {
                return Err(format!(
                    "{len} bytes exceeds the {max} this {} path can hold{}",
                    self.fs.as_str(),
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
                self.fs.as_str(),
                self.why
                    .as_ref()
                    .map(|w| format!(" — {w}"))
                    .unwrap_or_default()
            ));
        }
        Ok(())
    }

    /// A short status-line form: `fat32 rw` / `ext4 rw ≤4096B in place` / `ntfs ro`.
    pub fn summary(&self) -> String {
        if !self.writable {
            return format!("{} ro", self.fs.as_str());
        }
        match self.max_bytes {
            Some(max) if !self.can_grow => format!("{} rw <={max}B in place", self.fs.as_str()),
            Some(max) => format!("{} rw <={max}B", self.fs.as_str()),
            None => format!("{} rw", self.fs.as_str()),
        }
    }
}

/// A mounted filesystem. Drivers borrow their device, so a mount lives as long as
/// the device it reads.
pub trait FileSystem {
    fn kind(&self) -> FsKind;
    fn label(&self) -> String;
    /// True when writes can succeed on this mount.
    fn writable(&self) -> bool;
    fn list(&mut self, path: &str) -> Result<Vec<DirEnt>>;
    fn stat(&mut self, path: &str) -> Result<Stat>;
    fn read(&mut self, path: &str) -> Result<Vec<u8>>;

    /// `len` bytes at `off`. Reading a 4 KiB header out of a 4 GiB file must not
    /// mean reading the file.
    fn read_window(&mut self, path: &str, off: u64, len: usize) -> Result<Vec<u8>> {
        let all = self.read(path)?;
        let start = usize::try_from(off).unwrap_or(usize::MAX).min(all.len());
        let end = start.saturating_add(len).min(all.len());
        Ok(all[start..end].to_vec())
    }

    /// What a write to `path` could do — asked before one is attempted.
    ///
    /// The default is the honest one for a driver with no writer: refused, with the
    /// driver named. Drivers that *can* write state their terms.
    fn edit_budget(&mut self, path: &str) -> Result<EditBudget> {
        let (exists, size) = match self.stat(path) {
            Ok(s) => (true, s.size),
            Err(Error::NotFoundPath(_)) => (false, 0),
            Err(e) => return Err(e),
        };
        Ok(EditBudget::refused(
            self.kind(),
            size,
            exists,
            format!(
                "the {} driver in this BIOS reads only",
                self.kind().as_str()
            ),
        ))
    }

    fn write(&mut self, path: &str, data: &[u8]) -> Result<()> {
        let _ = data;
        Err(Error::Unsupported(format!(
            "{}: writing {path} is not implemented by the {} driver",
            self.kind().as_str(),
            self.kind().as_str()
        )))
    }

    fn mkdir(&mut self, path: &str) -> Result<()> {
        Err(Error::Unsupported(format!(
            "{}: mkdir {path} is not implemented",
            self.kind().as_str()
        )))
    }

    fn remove(&mut self, path: &str) -> Result<()> {
        Err(Error::Unsupported(format!(
            "{}: remove {path} is not implemented",
            self.kind().as_str()
        )))
    }
}

/// Split a slash path into its components, ignoring `.` and refusing `..` by
/// resolving it — a shell must not be able to walk out of a mount.
pub fn split_path(path: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for part in path.split(['/', '\\']) {
        match part {
            "" | "." => {}
            ".." => {
                out.pop();
            }
            s => out.push(s.to_string()),
        }
    }
    out
}

/// Normalize to a leading-slash path with no `.`/`..`.
pub fn normalize(path: &str) -> String {
    let parts = split_path(path);
    if parts.is_empty() {
        "/".to_string()
    } else {
        format!("/{}", parts.join("/"))
    }
}

/// A filesystem-friendly mount name from what the volume actually says.
///
/// The label is what an operator recognizes, so it leads; then the GPT partition
/// name; then the partition kind; and only then a positional fallback. The result
/// is lowercase, `[a-z0-9_-]`, and never empty — it is going to be typed.
pub fn friendly_name(label: &str, part_name: &str, kind: &str, index: u32) -> String {
    let pick = [label, part_name, kind]
        .into_iter()
        .map(str::trim)
        .find(|s| !s.is_empty())
        .unwrap_or("");
    let mut out = String::new();
    for c in pick.chars() {
        let c = c.to_ascii_lowercase();
        if c.is_ascii_alphanumeric() {
            out.push(c);
        } else if matches!(c, ' ' | '_' | '-' | '.') && !out.ends_with('-') {
            out.push('-');
        }
    }
    let out = out.trim_matches('-').to_string();
    if out.is_empty() {
        format!("part{index}")
    } else {
        out.chars().take(16).collect()
    }
}

/// Mount a partition (or a whole device) with whatever driver its superblock
/// calls for.
///
/// `rw` is a *request*: the returned filesystem reports what it actually got, and
/// [`Probe::write_block`] says why when it is less.
pub fn mount<'a>(dev: &'a mut dyn BlockDev, rw: bool) -> Result<(Box<dyn FileSystem + 'a>, Probe)> {
    let p = probe::probe(dev)?;
    let want_rw = rw && p.write_block.is_none();
    let fs: Box<dyn FileSystem + 'a> = match p.kind {
        FsKind::Fat32 => Box::new(fat32::Fat32::mount(dev, want_rw)?),
        k if k.is_ext() => Box::new(ext4::Ext4::mount(dev, want_rw)?),
        FsKind::Ntfs => Box::new(ntfs::Ntfs::mount(dev)?),
        FsKind::Btrfs => Box::new(btrfs::Btrfs::mount(dev, want_rw)?),
        other => {
            return Err(Error::Unsupported(format!(
                "{}: no driver in this BIOS ({})",
                other.as_str(),
                p.evidence
            )))
        }
    };
    Ok((fs, p))
}

/// A mountable single-volume image for `kind` — one entry point for tests,
/// `g6b vfs emit-fs` and the QEMU filesystem matrix.
///
/// The per-driver fixtures are hand-laid and each has its own shape and
/// minimum size (`fat32::fixture(sectors)`, `ntfs::fixture::image()`,
/// `btrfs::fixture::image(with_data)`, `ext4::tests_image_with_os_release()`).
/// A matrix caller should not have to know any of that to ask for "an ext4
/// key", so the sizes and flags are chosen here.
///
/// `None` for a kind this crate has no fixture for — `Fat16`, `ExFat`,
/// `Iso9660` and `Unknown` are identified by [`probe`] so they can be *named*
/// and refused, and inventing an image for them would imply a driver.
pub fn fixture_image(kind: FsKind) -> Option<Vec<u8>> {
    Some(match kind {
        // 4096 sectors = 2 MiB: enough clusters to be a legal FAT32 for this
        // driver, small enough to stay a cheap fixture.
        FsKind::Fat32 => fat32::fixture(4096).into_bytes(),
        // The ext fixture that carries /etc/os-release, so OS detection and
        // the `vi /etc/fstab`-shaped repair flows have something to read.
        k if k.is_ext() => ext4::tests_image_with_os_release(),
        FsKind::Ntfs => ntfs::fixture::image(),
        // `with_data=false`: no regular-extent file, so the FS-tree leaf keeps
        // its headroom for a store export (see `btrfs::fixture::NODE`).
        FsKind::Btrfs => btrfs::fixture::image(false),
        _ => return None,
    })
}

/// [`fixture_image`] by name, for CLI flags and build scripts.
///
/// Accepts the [`FsKind::as_str`] spellings plus `ext` as an alias for `ext4`.
/// Returns the parsed kind alongside the bytes so a caller can report what it
/// actually built.
pub fn fixture_image_named(name: &str) -> Option<(FsKind, Vec<u8>)> {
    let kind = match name.trim().to_ascii_lowercase().as_str() {
        "fat32" | "fat" => FsKind::Fat32,
        "ext4" | "ext" => FsKind::Ext4,
        "ntfs" => FsKind::Ntfs,
        "btrfs" => FsKind::Btrfs,
        _ => return None,
    };
    Some((kind, fixture_image(kind)?))
}

/// The kinds [`fixture_image_named`] accepts, for help text and matrix loops.
pub const FIXTURE_KINDS: [&str; 4] = ["fat32", "ext4", "ntfs", "btrfs"];

/// What a device offers, without mounting anything: the table plus a probe of
/// each partition. This is what a "select a volume in this drive" list is made of.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceScan {
    pub scheme: Scheme,
    pub warnings: Vec<String>,
    pub volumes: Vec<VolumeScan>,
}

/// One candidate volume on a device.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VolumeScan {
    pub part: Partition,
    pub probe: Probe,
    /// The name it would be mounted under.
    pub name: String,
}

impl VolumeScan {
    /// True when a driver here can read it.
    pub fn mountable(&self) -> bool {
        self.probe.kind.readable()
    }
}

/// Scan a device: partitions, then what each one holds.
pub fn scan(dev: &mut dyn BlockDev) -> Result<DeviceScan> {
    let table = part::read_table(dev)?;
    let mut volumes = Vec::new();
    for p in table.parts {
        let probe = {
            let mut sub = SubDev::new(dev, p.start, p.len, false)?;
            match probe::probe(&mut sub) {
                Ok(pr) => pr,
                // A partition too small or unreadable is still listed: an
                // operator needs to see the thing that is wrong.
                Err(e) => Probe {
                    kind: FsKind::Unknown,
                    label: String::new(),
                    evidence: format!("probe failed: {e}"),
                    dirty: false,
                    write_block: Some("unreadable".into()),
                },
            }
        };
        let name = friendly_name(&probe.label, &p.name, &p.kind, p.index);
        volumes.push(VolumeScan {
            part: p,
            probe,
            name,
        });
    }
    // Two partitions can carry the same label; the names still have to differ.
    let mut seen: Vec<String> = Vec::new();
    for v in volumes.iter_mut() {
        if seen.contains(&v.name) {
            v.name = format!("{}{}", v.name, v.part.index);
        }
        seen.push(v.name.clone());
    }
    Ok(DeviceScan {
        scheme: table.scheme,
        warnings: table.warnings,
        volumes,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every advertised fixture must probe as the kind it claims and mount
    /// with a real driver. The fs matrix loops over `FIXTURE_KINDS`, so a
    /// fixture that no longer mounts has to fail here — named — rather than as
    /// a confusing per-filesystem failure further downstream.
    #[test]
    fn every_fixture_kind_probes_and_mounts_as_itself() {
        for name in FIXTURE_KINDS {
            let (kind, bytes) = fixture_image_named(name).unwrap_or_else(|| {
                panic!(
                    "{name}: FIXTURE_KINDS advertises a fixture that fixture_image_named refuses"
                )
            });
            assert_eq!(kind.as_str(), name, "{name}: parsed to a different kind");
            assert!(kind.readable(), "{name}: no driver in this BIOS");
            let mut dev = crate::block::MemBlock::new(bytes);
            let (fs, probe) = mount(&mut dev, true)
                .unwrap_or_else(|e| panic!("{name}: fixture does not mount: {e}"));
            assert_eq!(probe.kind, kind, "{name}: probed as {:?}", probe.kind);
            let mut fs = fs;
            assert_eq!(fs.kind(), kind, "{name}: driver reports another kind");
            // `edit_budget` is what `vi` puts in its status line *before* the
            // operator types, so every fixture must be able to answer it for
            // its own root, and the answer must name the filesystem.
            let budget = fs
                .edit_budget("/")
                .unwrap_or_else(|e| panic!("{name}: no edit budget for the root: {e}"));
            assert!(
                budget.summary().starts_with(name),
                "{name}: summary {:?} does not lead with the fs",
                budget.summary()
            );
        }
        // Kinds we identify but have no driver for must not pretend to have a
        // fixture; that is what keeps "recognised" and "supported" distinct.
        for kind in [
            FsKind::Fat16,
            FsKind::ExFat,
            FsKind::Iso9660,
            FsKind::Unknown,
        ] {
            assert!(fixture_image(kind).is_none(), "{kind:?} has no driver");
        }
        assert!(fixture_image_named("zfs").is_none());
        // `ext` is an accepted alias, `fat` likewise.
        assert_eq!(
            fixture_image_named("ext").map(|(k, _)| k),
            Some(FsKind::Ext4)
        );
        assert_eq!(
            fixture_image_named("fat").map(|(k, _)| k),
            Some(FsKind::Fat32)
        );
    }

    #[test]
    fn paths_normalize_and_cannot_escape_a_mount() {
        assert_eq!(split_path("/etc/fstab"), ["etc", "fstab"]);
        assert_eq!(split_path("etc//./fstab/"), ["etc", "fstab"]);
        assert_eq!(split_path("\\EFI\\BOOT"), ["EFI", "BOOT"]);
        // `..` is resolved, and it stops at the mount root.
        assert_eq!(split_path("/etc/../boot"), ["boot"]);
        assert!(split_path("/../../..").is_empty());
        assert_eq!(normalize("/../.."), "/");
        assert_eq!(normalize("etc/../etc/fstab"), "/etc/fstab");
    }

    #[test]
    fn friendly_names_are_typeable_and_unique() {
        assert_eq!(
            friendly_name("Ubuntu 24.04", "", "linux", 2),
            "ubuntu-24-04"
        );
        assert_eq!(friendly_name("", "EFI System", "esp", 1), "efi-system");
        assert_eq!(
            friendly_name("", "", "linux-filesystem", 3),
            "linux-filesystem"
        );
        assert_eq!(friendly_name("", "", "", 4), "part4");
        // Nothing typeable survives → positional, never empty.
        assert_eq!(friendly_name("///", "", "", 1), "part1");
        // Long labels are cut to something a person will type.
        assert_eq!(friendly_name(&"x".repeat(40), "", "", 1).len(), 16);
    }

    #[test]
    fn scan_lists_every_partition_with_what_it_holds() {
        // A GPT disk whose first partition is a real FAT32 volume and whose
        // second is unformatted: both must be listed, one mountable.
        let fat = fat32::fixture(2048);
        let mut disk = vec![0u8; 8192 * 512];
        // Protective MBR + GPT with two entries.
        let esp: [u8; 16] = [
            0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11, 0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E,
            0xC9, 0x3B,
        ];
        let linux: [u8; 16] = [
            0xAF, 0x3D, 0xC6, 0x0F, 0x83, 0x84, 0x72, 0x47, 0x8E, 0x79, 0x3D, 0x69, 0xD8, 0x47,
            0x7D, 0xE4,
        ];
        let gpt = part::gpt_fixture(
            &[
                (2048, 2048 + 2047, esp, "EFI System"),
                (4096, 4096 + 2047, linux, "root"),
            ],
            8192,
        );
        disk[..gpt.bytes().len()].copy_from_slice(gpt.bytes());
        disk[2048 * 512..2048 * 512 + fat.bytes().len()].copy_from_slice(fat.bytes());
        let mut dev = MemBlock::new(disk);
        let s = scan(&mut dev).unwrap();
        assert_eq!(s.scheme, Scheme::Gpt);
        assert_eq!(s.volumes.len(), 2);
        // The FAT32 volume: named from its label, mountable, writable.
        assert_eq!(s.volumes[0].probe.kind, FsKind::Fat32);
        assert_eq!(s.volumes[0].name, "g6lctest");
        assert!(s.volumes[0].mountable());
        // The empty one: listed, named from the GPT name, not mountable.
        assert_eq!(s.volumes[1].probe.kind, FsKind::Unknown);
        assert_eq!(s.volumes[1].name, "root");
        assert!(!s.volumes[1].mountable());
    }

    /// Every driver states its write terms *before* an edit, and the terms differ
    /// because the filesystems differ. This is what an editor puts in its status
    /// line so an operator is not told "no" only after retyping a boot config.
    #[test]
    fn each_driver_states_its_edit_terms_up_front() {
        // FAT32: creates, grows, bounded by the volume.
        let mut dev = fat32::fixture(4096);
        {
            let mut fs = fat32::Fat32::mount(&mut dev, true).unwrap();
            fs.write("/GRUB.CFG", b"menuentry\n").unwrap();
            let b = fs.edit_budget("/grub.cfg").unwrap();
            assert!(b.writable && b.can_create && b.can_grow, "{b:?}");
            assert_eq!(b.size, 10);
            assert!(b.max_bytes.unwrap() > 10, "{b:?}");
            assert!(b.accepts(4096).is_ok(), "{b:?}");
            assert!(b.summary().starts_with("fat32 rw"), "{}", b.summary());
            // A path that does not exist is still writable, because it can create.
            let n = fs.edit_budget("/NEW.CFG").unwrap();
            assert!(!n.exists && n.can_create && n.accepts(16).is_ok(), "{n:?}");
            // Over the volume's capacity is refused with both numbers.
            let err = b.accepts(1 << 30).unwrap_err();
            assert!(err.contains("exceeds"), "{err}");
        }
        // A read-only mount says which knob changes that.
        {
            let mut fs = fat32::Fat32::mount(&mut dev, false).unwrap();
            let b = fs.edit_budget("/grub.cfg").unwrap();
            assert!(!b.writable);
            assert!(b.why.unwrap().contains("mount -w"));
        }
        // ext4: in place inside mapped blocks, tail growth by allocation, and
        // create — no fixed ceiling, so max_bytes is unbounded.
        let mut dev = ext4::fixture(true, false);
        {
            let mut fs = ext4::Ext4::mount(&mut dev, true).unwrap();
            let b = fs.edit_budget("/etc/fstab").unwrap();
            assert!(b.writable && b.can_grow && b.can_create, "{b:?}");
            assert!(b.accepts(4096).is_ok(), "{b:?}");
            assert!(b.summary().contains("ext4 rw"), "{}", b.summary());
            // A path that does not exist is still writable, because it can
            // create.
            let n = fs.edit_budget("/etc/new.conf").unwrap();
            assert!(!n.exists && n.can_create, "{n:?}");
        }
        // NTFS: never, and the refusal names the obstacle.
        let mut dev = MemBlock::read_only({
            let mut d = vec![0u8; 8192];
            d[3..11].copy_from_slice(b"NTFS    ");
            d[11..13].copy_from_slice(&512u16.to_le_bytes());
            d[13] = 1;
            d[64] = 0xF6;
            d[510] = 0x55;
            d[511] = 0xAA;
            d
        });
        // A hand-made boot sector with no $MFT will not mount; the *probe* still
        // carries the same refusal, which is what a caller sees first.
        let p = probe::probe(&mut dev).unwrap();
        assert_eq!(p.kind, FsKind::Ntfs);
        assert!(p.write_block.unwrap().contains("read-only"));
    }

    #[test]
    fn mount_picks_the_driver_from_the_superblock_and_reports_what_it_got() {
        let mut dev = fat32::fixture(2048);
        let (fs, p) = mount(&mut dev, true).unwrap();
        assert_eq!(fs.kind(), FsKind::Fat32);
        assert!(fs.writable());
        assert!(p.write_block.is_none());
        drop(fs);
        // An unknown filesystem is refused with its evidence, not mounted empty.
        let mut blank = MemBlock::zeroed(4096);
        let err = match mount(&mut blank, false) {
            Ok(_) => panic!("an unknown filesystem must not mount"),
            Err(e) => e,
        };
        assert!(matches!(err, Error::Unsupported(_)), "{err:?}");
        assert!(err.to_string().contains("no driver"), "{err}");
    }
}
