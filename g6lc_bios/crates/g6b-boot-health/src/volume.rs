// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Volume discovery. No jump.
//!
//! Walks GPT/MBR (or the whole-disk fallback) and classifies the first bytes
//! of each partition. When a partition is a readable FAT/ext/NTFS/btrfs
//! filesystem, also lists `/`, `/boot` and `/efi/boot` and classifies those
//! files. A squashfs/UBI payload or file is a rootfs, not a kernel. Table
//! type GUIDs and file names are claims; the payload is evidence. This does
//! not recurse the whole tree and does not load Linux.

use crate::bundle::{classify, Kind, Refuse};
use g6b_vfs::part::{read_table, Scheme};
use g6b_vfs::{mount, BlockDev, Error as VfsError, FileBlock, FileSystem, SubDev};

/// What a classified partition or file is *for*.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    Kernel,
    Rootfs,
    DeviceTree,
    Loader,
    Config,
    Unknown,
}

impl From<Kind> for Role {
    fn from(kind: Kind) -> Self {
        match kind {
            Kind::RiscvImage => Self::Kernel,
            Kind::Squashfs | Kind::Ubi => Self::Rootfs,
            Kind::Fdt => Self::DeviceTree,
            Kind::Unknown => Self::Unknown,
        }
    }
}

fn role_for(kind: Kind, name: &str) -> Role {
    match Role::from(kind) {
        Role::Unknown => {
            let n = name.to_ascii_lowercase();
            if n == "bootriscv64.efi" || n.ends_with(".itb") {
                Role::Loader
            } else if n == "extlinux.conf" || n == "boot.scr" {
                Role::Config
            } else {
                Role::Unknown
            }
        }
        other => other,
    }
}

/// A file found on a mountable partition. Content decides the role.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Artifact {
    pub path: String,
    pub payload: Kind,
    pub role: Role,
    pub size: u64,
}

impl Artifact {
    /// Only a RISC-V `Image` file is a potential jump target.
    pub fn executable(&self) -> bool {
        self.payload == Kind::RiscvImage
    }
}

/// One discovered partition and what its first bytes — and files — proved.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Volume {
    pub index: u32,
    pub start: u64,
    pub len: u64,
    pub scheme: Scheme,
    pub table_kind: String,
    pub name: String,
    pub payload: Kind,
    pub role: Role,
    pub artifacts: Vec<Artifact>,
}

impl Volume {
    /// A RISC-V `Image` at the partition start or as a discovered file.
    pub fn executable(&self) -> bool {
        self.payload == Kind::RiscvImage || self.artifacts.iter().any(Artifact::executable)
    }

    /// Why this volume is not a kernel, when it is not.
    pub fn refuse_reason(&self) -> Option<Refuse> {
        if self.executable() {
            return None;
        }
        if self.payload == Kind::Squashfs
            || self.artifacts.iter().any(|a| a.payload == Kind::Squashfs)
        {
            return Some(Refuse::SquashfsNotExecutable);
        }
        if self.payload == Kind::Ubi || self.artifacts.iter().any(|a| a.payload == Kind::Ubi) {
            return Some(Refuse::UbiNotExecutable);
        }
        Some(Refuse::MissingImage)
    }
}

fn volume_role(payload: Kind, artifacts: &[Artifact]) -> Role {
    let from_payload = Role::from(payload);
    if from_payload != Role::Unknown {
        return from_payload;
    }
    for want in [
        Role::Kernel,
        Role::Rootfs,
        Role::DeviceTree,
        Role::Loader,
        Role::Config,
    ] {
        if artifacts.iter().any(|a| a.role == want) {
            return want;
        }
    }
    Role::Unknown
}

const WALK_DIRS: &[&str] = &["/", "/boot", "/efi/boot"];

fn walk_fs(fs: &mut dyn FileSystem) -> Vec<Artifact> {
    let mut out = Vec::new();
    for dir in WALK_DIRS {
        let Ok(ents) = fs.list(dir) else {
            continue;
        };
        for ent in ents {
            if ent.dir {
                continue;
            }
            let path = if *dir == "/" {
                format!("/{}", ent.name)
            } else {
                format!("{}/{}", dir, ent.name)
            };
            let head = fs.read_window(&path, 0, 64).unwrap_or_default();
            let payload = classify(&head);
            let role = role_for(payload, &ent.name);
            if role == Role::Unknown && payload == Kind::Unknown {
                continue;
            }
            out.push(Artifact {
                path,
                payload,
                role,
                size: ent.size,
            });
        }
    }
    out
}

fn walk_partition(dev: &mut dyn BlockDev, start: u64, len: u64) -> Vec<Artifact> {
    let mut sub = match SubDev::new(dev, start, len, false) {
        Ok(sub) => sub,
        Err(_) => return Vec::new(),
    };
    let (mut fs, _) = match mount(&mut sub, false) {
        Ok(mounted) => mounted,
        Err(_) => return Vec::new(),
    };
    walk_fs(fs.as_mut())
}

/// Classify every partition on `dev`. Does not write and does not jump.
pub fn scan(dev: &mut dyn BlockDev) -> Result<Vec<Volume>, VfsError> {
    let table = read_table(dev)?;
    let mut out = Vec::with_capacity(table.parts.len());
    for part in &table.parts {
        let n = core::cmp::min(part.len, 64) as usize;
        let mut head = [0u8; 64];
        if n > 0 {
            dev.read_at(part.start, &mut head[..n])?;
        }
        let payload = classify(&head[..n]);
        let artifacts = walk_partition(dev, part.start, part.len);
        let role = volume_role(payload, &artifacts);
        out.push(Volume {
            index: part.index,
            start: part.start,
            len: part.len,
            scheme: table.scheme,
            table_kind: part.kind.clone(),
            name: part.name.clone(),
            payload,
            role,
            artifacts,
        });
    }
    Ok(out)
}

/// Open a disk image read-only and classify its partitions.
pub fn scan_path(path: &str) -> Result<Vec<Volume>, VfsError> {
    let mut dev = FileBlock::open(path)?;
    scan(&mut dev)
}

#[cfg(test)]
mod tests {
    use super::*;
    use g6b_vfs::part::gpt_fixture;
    use g6b_vfs::MemBlock;

    const LINUX_GUID: [u8; 16] = [
        0xAF, 0x3D, 0xC6, 0x0F, 0x83, 0x84, 0x72, 0x47, 0x8E, 0x79, 0x3D, 0x69, 0xD8, 0x47, 0x7D,
        0xE4,
    ];
    const ROOT_RISCV64_GUID: [u8; 16] = [
        0xA6, 0x70, 0xEC, 0x72, 0x74, 0xCF, 0xE6, 0x40, 0xBD, 0x49, 0x4B, 0xDA, 0x08, 0xE8, 0xF2,
        0x24,
    ];

    fn image(size: u64) -> Vec<u8> {
        let mut b = vec![0u8; 0x40];
        b[0x10..0x18].copy_from_slice(&size.to_le_bytes());
        b[0x20..0x24].copy_from_slice(&2u32.to_le_bytes());
        b[0x30..0x38].copy_from_slice(b"RISCV\0\0\0");
        b[0x38..0x3c].copy_from_slice(b"RSC\x05");
        b
    }

    fn plant(raw: &mut [u8], lba: u64, bytes: &[u8]) {
        let off = (lba * 512) as usize;
        raw[off..off + bytes.len()].copy_from_slice(bytes);
    }

    fn gpt_disk() -> MemBlock {
        let mut raw = gpt_fixture(
            &[
                (34, 63, LINUX_GUID, "kernel"),
                (64, 93, ROOT_RISCV64_GUID, "root"),
                (94, 127, LINUX_GUID, "dtb"),
            ],
            256,
        )
        .into_bytes();
        plant(&mut raw, 34, &image(0x40));
        plant(&mut raw, 64, b"hsqs....");
        plant(&mut raw, 94, &[0xd0, 0x0d, 0xfe, 0xed]);
        MemBlock::new(raw)
    }

    #[test]
    fn gpt_image_squashfs_and_fdt_are_distinct_roles() {
        let mut disk = gpt_disk();
        let vols = scan(&mut disk).unwrap();
        assert_eq!(vols.len(), 3);
        assert_eq!(vols[0].scheme, Scheme::Gpt);
        assert_eq!(vols[0].name, "kernel");
        assert_eq!(vols[0].payload, Kind::RiscvImage);
        assert_eq!(vols[0].role, Role::Kernel);
        assert!(vols[0].executable());
        assert_eq!(vols[0].refuse_reason(), None);

        assert_eq!(vols[1].table_kind, "linux-root-riscv64");
        assert_eq!(vols[1].name, "root");
        assert_eq!(vols[1].payload, Kind::Squashfs);
        assert_eq!(vols[1].role, Role::Rootfs);
        assert!(!vols[1].executable());
        assert_eq!(vols[1].refuse_reason(), Some(Refuse::SquashfsNotExecutable));

        assert_eq!(vols[2].payload, Kind::Fdt);
        assert_eq!(vols[2].role, Role::DeviceTree);
        assert!(!vols[2].executable());
        assert_eq!(vols[2].refuse_reason(), Some(Refuse::MissingImage));
    }

    #[test]
    fn squashfs_partition_is_not_a_jump_target() {
        let mut disk = gpt_disk();
        let vols = scan(&mut disk).unwrap();
        let root = vols.iter().find(|v| v.role == Role::Rootfs).unwrap();
        assert_eq!(root.payload, Kind::Squashfs);
        assert!(!root.executable());
        assert_eq!(
            crate::validate(&crate::Bundle {
                image: b"hsqs....",
                initrd: Some(b"i"),
                dtb: Some(&[0xd0, 0x0d, 0xfe, 0xed]),
                root: Some("/dev/vda2"),
                bootargs: Some("console=ttyS0"),
            }),
            Err(Refuse::SquashfsNotExecutable)
        );
    }

    #[test]
    fn table_claim_does_not_override_squashfs_payload() {
        let mut disk = gpt_disk();
        let vols = scan(&mut disk).unwrap();
        let root = &vols[1];
        assert_eq!(root.table_kind, "linux-root-riscv64");
        assert_ne!(root.role, Role::Kernel);
        assert_eq!(root.role, Role::Rootfs);
    }

    #[test]
    fn whole_disk_image_is_a_kernel() {
        let mut raw = vec![0u8; 4 * 512];
        let img = image(0x40);
        raw[..img.len()].copy_from_slice(&img);
        let mut disk = MemBlock::new(raw);
        let vols = scan(&mut disk).unwrap();
        assert_eq!(vols.len(), 1);
        assert_eq!(vols[0].scheme, Scheme::None);
        assert_eq!(vols[0].payload, Kind::RiscvImage);
        assert_eq!(vols[0].role, Role::Kernel);
        assert!(vols[0].executable());
    }

    #[test]
    fn empty_partition_is_unknown_not_a_kernel() {
        let mut disk = gpt_fixture(&[(34, 63, LINUX_GUID, "empty")], 128);
        let vols = scan(&mut disk).unwrap();
        assert_eq!(vols.len(), 1);
        assert_eq!(vols[0].payload, Kind::Unknown);
        assert_eq!(vols[0].role, Role::Unknown);
        assert!(!vols[0].executable());
        assert_eq!(vols[0].refuse_reason(), Some(Refuse::MissingImage));
    }

    #[test]
    fn scan_does_not_write() {
        let before = gpt_disk().into_bytes();
        let mut disk = MemBlock::new(before.clone());
        let _ = scan(&mut disk).unwrap();
        assert_eq!(disk.into_bytes(), before);
    }

    #[test]
    fn scan_path_opens_a_read_only_image() {
        let path = std::env::temp_dir().join(format!(
            "g6b-vol-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::write(&path, gpt_disk().into_bytes()).unwrap();
        let vols = scan_path(path.to_str().unwrap()).unwrap();
        assert_eq!(vols.len(), 3);
        assert_eq!(vols[0].role, Role::Kernel);
        assert_eq!(vols[1].role, Role::Rootfs);
        assert_eq!(vols[2].role, Role::DeviceTree);
        let _ = std::fs::remove_file(path);
    }

    const ESP_GUID: [u8; 16] = [
        0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11, 0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9,
        0x3B,
    ];

    fn fat_boot_bytes() -> Vec<u8> {
        let mut dev = g6b_vfs::fat32::fixture(4096);
        {
            let (mut fs, _) = g6b_vfs::mount(&mut dev, true).unwrap();
            fs.mkdir("/boot").unwrap();
            fs.write("/boot/Image", &image(0x40)).unwrap();
            fs.write("/boot/root.squashfs", b"hsqs....").unwrap();
            fs.write("/boot/board.dtb", &[0xd0, 0x0d, 0xfe, 0xed])
                .unwrap();
            fs.write("/boot/extlinux.conf", b"TIMEOUT 1\n").unwrap();
        }
        dev.into_bytes()
    }

    fn gpt_fat_disk() -> MemBlock {
        let fat = fat_boot_bytes();
        let fat_sectors = (fat.len() / 512) as u64;
        let first = 34u64;
        let last = first + fat_sectors - 1;
        let mut raw = gpt_fixture(&[(first, last, ESP_GUID, "boot")], 8192).into_bytes();
        let off = (first * 512) as usize;
        raw[off..off + fat.len()].copy_from_slice(&fat);
        MemBlock::new(raw)
    }

    fn artifact(vol: &Volume, role: Role) -> &Artifact {
        vol.artifacts
            .iter()
            .find(|a| a.role == role)
            .unwrap_or_else(|| panic!("missing {role:?} in {:?}", vol.artifacts))
    }

    #[test]
    fn fat_boot_image_is_a_kernel_file() {
        let mut disk = gpt_fat_disk();
        let vols = scan(&mut disk).unwrap();
        assert_eq!(vols.len(), 1);
        assert_eq!(vols[0].payload, Kind::Unknown);
        assert_eq!(vols[0].role, Role::Kernel);
        assert!(vols[0].executable());
        assert_eq!(vols[0].refuse_reason(), None);
        let kernel = artifact(&vols[0], Role::Kernel);
        assert!(kernel.path.contains("image"));
        assert_eq!(kernel.payload, Kind::RiscvImage);
        assert!(kernel.executable());
        let root = artifact(&vols[0], Role::Rootfs);
        assert_eq!(root.payload, Kind::Squashfs);
        assert!(!root.executable());
        let dtb = artifact(&vols[0], Role::DeviceTree);
        assert_eq!(dtb.payload, Kind::Fdt);
        assert!(!dtb.executable());
        let cfg = artifact(&vols[0], Role::Config);
        assert!(cfg.path.contains("extlinux.conf"));
        assert!(!cfg.executable());
    }

    #[test]
    fn fat_squashfs_file_is_not_a_jump_target() {
        let mut dev = g6b_vfs::fat32::fixture(4096);
        {
            let (mut fs, _) = g6b_vfs::mount(&mut dev, true).unwrap();
            fs.write("/root.squashfs", b"hsqs....").unwrap();
        }
        let vols = scan(&mut dev).unwrap();
        assert_eq!(vols.len(), 1);
        assert_eq!(vols[0].scheme, Scheme::None);
        assert_eq!(vols[0].role, Role::Rootfs);
        assert!(!vols[0].executable());
        assert_eq!(vols[0].refuse_reason(), Some(Refuse::SquashfsNotExecutable));
        assert!(!artifact(&vols[0], Role::Rootfs).executable());
    }

    #[test]
    fn fat_scan_does_not_write() {
        let before = gpt_fat_disk().into_bytes();
        let mut disk = MemBlock::new(before.clone());
        let _ = scan(&mut disk).unwrap();
        assert_eq!(disk.into_bytes(), before);
    }

    #[test]
    fn efi_loader_is_not_a_kernel() {
        let mut dev = g6b_vfs::fat32::fixture(4096);
        {
            let (mut fs, _) = g6b_vfs::mount(&mut dev, true).unwrap();
            fs.mkdir("/EFI").unwrap();
            fs.mkdir("/EFI/BOOT").unwrap();
            fs.write("/EFI/BOOT/BOOTRISCV64.EFI", b"MZ not-a-linux-image")
                .unwrap();
        }
        let vols = scan(&mut dev).unwrap();
        assert_eq!(vols[0].role, Role::Loader);
        assert!(!vols[0].executable());
        assert_eq!(vols[0].refuse_reason(), Some(Refuse::MissingImage));
        let loader = artifact(&vols[0], Role::Loader);
        assert!(
            loader.path.to_ascii_lowercase().contains("bootriscv64.efi"),
            "{}",
            loader.path
        );
        assert!(!loader.executable());
    }
}
