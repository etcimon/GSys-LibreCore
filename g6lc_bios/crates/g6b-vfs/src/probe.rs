// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! What filesystem is on a partition, decided by its own superblock.
//!
//! The partition table's type byte or GUID is a *claim*; this is the evidence.
//! Getting that order wrong is how a tool formats the wrong thing.
//!
//! * **FAT32** — the BPB at offset 0: 512-byte-multiple `bytes_per_sector`, a
//!   power-of-two `sectors_per_cluster`, `root_entries == 0` and
//!   `sectors_per_fat16 == 0` (that is what makes it FAT32 rather than FAT16),
//!   `0xAA55` at 510, and `"FAT32   "` in the FAT32 type field at 82. The label
//!   is at 71, or the root directory's volume-label entry.
//! * **ext2/3/4** — the superblock at byte 1024: magic `0xEF53` at +56. The
//!   feature flags say which of the three it is, `s_volume_name` at +120 is the
//!   label, and `s_state`/`needs_recovery` say whether writing is safe.
//! * **NTFS** — the boot sector: OEM ID `"NTFS    "` at 3, `0xAA55` at 510.
//! * **btrfs** — the superblock at 0x10000: magic `"_BHRfS_M"` at +0x40, label
//!   at +0x12B. Multi-device and zoned/stripe-tree layouts refuse writes.
//! * **ISO 9660** — `CD001` at 0x8001 (a CD image handed over as a partition).
//! * **exFAT** — `"EXFAT   "` at 3, recognized so it can be *named* and refused
//!   rather than mistaken for FAT32.

use crate::block::{le16, le32, le64, read_array, BlockDev};
use crate::{Error, Result};

/// The on-disk families this layer can identify.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FsKind {
    Fat32,
    Fat16,
    ExFat,
    Ext2,
    Ext3,
    Ext4,
    Ntfs,
    Btrfs,
    Iso9660,
    Unknown,
}

impl FsKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Fat32 => "fat32",
            Self::Fat16 => "fat16",
            Self::ExFat => "exfat",
            Self::Ext2 => "ext2",
            Self::Ext3 => "ext3",
            Self::Ext4 => "ext4",
            Self::Ntfs => "ntfs",
            Self::Btrfs => "btrfs",
            Self::Iso9660 => "iso9660",
            Self::Unknown => "unknown",
        }
    }

    /// The ext family shares one superblock and one driver.
    pub fn is_ext(self) -> bool {
        matches!(self, Self::Ext2 | Self::Ext3 | Self::Ext4)
    }

    /// A driver in this crate can read it.
    pub fn readable(self) -> bool {
        self.is_ext() || matches!(self, Self::Fat32 | Self::Ntfs | Self::Btrfs)
    }
}

/// What the superblock said.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Probe {
    pub kind: FsKind,
    /// Volume label, empty when the filesystem has none set.
    pub label: String,
    /// The field that identified it, for the operator and for bug reports.
    pub evidence: String,
    /// Set when the filesystem says it was not cleanly unmounted (ext `s_state`
    /// bit 0 clear, or `needs_recovery`) — a *reason to refuse* a write mount.
    pub dirty: bool,
    /// Why writing is refused, when it is.
    pub write_block: Option<String>,
}

impl Probe {
    fn unknown() -> Self {
        Self {
            kind: FsKind::Unknown,
            label: String::new(),
            evidence: "no known superblock".into(),
            dirty: false,
            write_block: None,
        }
    }
}

/// Identify the filesystem at the start of `dev`.
pub fn probe(dev: &mut dyn BlockDev) -> Result<Probe> {
    if dev.len() < 2048 {
        return Err(Error::TooSmall);
    }
    let boot = read_array::<512>(dev, 0)?;
    // NTFS and exFAT both look like a BPB, so they are checked by OEM ID first.
    if &boot[3..11] == b"NTFS    " {
        return Ok(Probe {
            kind: FsKind::Ntfs,
            label: String::new(),
            evidence: "OEM ID \"NTFS    \" at 3".into(),
            dirty: false,
            write_block: Some("ntfs is mounted read-only by this BIOS".into()),
        });
    }
    if &boot[3..11] == b"EXFAT   " {
        return Ok(Probe {
            kind: FsKind::ExFat,
            label: String::new(),
            evidence: "OEM ID \"EXFAT   \" at 3".into(),
            dirty: false,
            write_block: Some("exfat has no driver in this BIOS".into()),
        });
    }
    if let Some(p) = fat_probe(&boot) {
        return Ok(p);
    }
    // ext superblock lives at byte 1024, so it survives a FAT BPB check.
    let sb = read_array::<264>(dev, 1024)?;
    if le16(&sb, 56) == 0xEF53 {
        return Ok(ext_probe(&sb));
    }
    // btrfs's superblock sits at 0x10000 — far enough out that no boot sector
    // can collide with it.
    if dev.len() >= 0x11000 {
        let bsb = read_array::<560>(dev, 0x10000)?;
        if &bsb[0x40..0x48] == b"_BHRfS_M" {
            let multi = le64(&bsb, 0x88) > 1;
            let incompat = le64(&bsb, 0xBC);
            let raw = &bsb[0x12B..0x12B + 256];
            let label = ascii_label(raw);
            return Ok(Probe {
                kind: FsKind::Btrfs,
                label,
                evidence: "btrfs magic \"_BHRfS_M\" at 0x10040".into(),
                dirty: false,
                write_block: if multi {
                    Some("multi-device btrfs — this BIOS writes single-device volumes".into())
                } else if incompat & (0x400 | 0x800 | 0x1000 | 0x2000 | 0x4000) != 0 {
                    Some(format!(
                        "btrfs incompat {incompat:#x} (zoned/extent-tree-v2/stripe-tree/metadata-uuid)"
                    ))
                } else {
                    None
                },
            });
        }
    }
    if dev.len() >= 0x8800 {
        let pvd = read_array::<8>(dev, 0x8000)?;
        if pvd[0] == 1 && &pvd[1..6] == b"CD001" {
            return Ok(Probe {
                kind: FsKind::Iso9660,
                label: String::new(),
                evidence: "ISO 9660 PVD at sector 16".into(),
                dirty: false,
                write_block: Some("iso9660 is a read-only format".into()),
            });
        }
    }
    Ok(Probe::unknown())
}

fn fat_probe(boot: &[u8; 512]) -> Option<Probe> {
    if le16(boot, 510) != 0xAA55 {
        return None;
    }
    let bps = le16(boot, 11);
    let spc = boot[13];
    if !matches!(bps, 512 | 1024 | 2048 | 4096) || spc == 0 || !spc.is_power_of_two() {
        return None;
    }
    let root_entries = le16(boot, 17);
    let fat16_sectors = le16(boot, 22);
    if root_entries == 0 && fat16_sectors == 0 && le32(boot, 36) != 0 {
        // FAT32: the type string is advisory, the geometry is what decides.
        let label = ascii_label(&boot[71..82]);
        let ty = ascii_label(&boot[82..90]);
        return Some(Probe {
            kind: FsKind::Fat32,
            label,
            evidence: format!(
                "FAT32 BPB (root_entries=0, fat16_sectors=0, type={:?})",
                ty.trim()
            ),
            dirty: false,
            write_block: None,
        });
    }
    if root_entries > 0 && fat16_sectors > 0 {
        return Some(Probe {
            kind: FsKind::Fat16,
            label: ascii_label(&boot[43..54]),
            evidence: "FAT16 BPB (root_entries>0)".into(),
            dirty: false,
            write_block: Some("fat16 has no driver in this BIOS (fat32 does)".into()),
        });
    }
    None
}

/// ext2/3/4 from the feature flags: a journal makes it ext3, and any of the
/// ext4-only incompat features (extents, 64bit, flex_bg…) makes it ext4.
fn ext_probe(sb: &[u8]) -> Probe {
    const HAS_JOURNAL: u32 = 0x0004;
    const RECOVER: u32 = 0x0004;
    const EXTENTS: u32 = 0x0040;
    const SIXTY_FOUR_BIT: u32 = 0x0080;
    const FLEX_BG: u32 = 0x0200;
    const META_BG: u32 = 0x0010;
    let compat_ro = le32(sb, 100);
    let incompat = le32(sb, 96);
    let feature_compat_journal = le32(sb, 92) & HAS_JOURNAL != 0 || incompat & HAS_JOURNAL != 0;
    let ext4_ish = incompat & (EXTENTS | SIXTY_FOUR_BIT | FLEX_BG | META_BG) != 0
        || compat_ro & 0x0008 != 0 // huge_file
        || compat_ro & 0x0010 != 0; // gdt_csum
    let kind = if ext4_ish {
        FsKind::Ext4
    } else if feature_compat_journal {
        FsKind::Ext3
    } else {
        FsKind::Ext2
    };
    let state = le16(sb, 58);
    let needs_recovery = incompat & RECOVER != 0;
    let dirty = state & 1 == 0 || needs_recovery;
    let write_block = if needs_recovery {
        Some("ext journal needs recovery — mount it read-only or replay it first".into())
    } else if state & 1 == 0 {
        Some("ext superblock is not marked clean — read-only until it is".into())
    } else {
        None
    };
    Probe {
        kind,
        label: ascii_label(&sb[120..136]),
        evidence: format!(
            "ext superblock magic 0xEF53 (incompat={incompat:#x}, ro_compat={compat_ro:#x})"
        ),
        dirty,
        write_block,
    }
}

fn ascii_label(b: &[u8]) -> String {
    let s: String = b
        .iter()
        .take_while(|c| **c != 0)
        .map(|c| {
            let c = *c;
            if c.is_ascii_graphic() || c == b' ' {
                c as char
            } else {
                '?'
            }
        })
        .collect();
    s.trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::block::MemBlock;

    /// A FAT32 BPB the way `mkfs.vfat` lays one out.
    pub(crate) fn fat32_boot(label: &str, spc: u8) -> Vec<u8> {
        let mut d = vec![0u8; 64 * 1024];
        d[0..3].copy_from_slice(&[0xEB, 0x58, 0x90]);
        d[3..11].copy_from_slice(b"mkfs.fat");
        d[11..13].copy_from_slice(&512u16.to_le_bytes());
        d[13] = spc;
        d[14..16].copy_from_slice(&32u16.to_le_bytes()); // reserved sectors
        d[16] = 2; // FATs
        d[36..40].copy_from_slice(&64u32.to_le_bytes()); // sectors per FAT
        d[44..48].copy_from_slice(&2u32.to_le_bytes()); // root cluster
        let mut l = [b' '; 11];
        for (i, c) in label.bytes().take(11).enumerate() {
            l[i] = c;
        }
        d[71..82].copy_from_slice(&l);
        d[82..90].copy_from_slice(b"FAT32   ");
        d[510] = 0x55;
        d[511] = 0xAA;
        d
    }

    /// An ext superblock with the given feature words.
    fn ext_sb(label: &str, incompat: u32, ro_compat: u32, state: u16) -> Vec<u8> {
        let mut d = vec![0u8; 8192];
        let sb = 1024;
        d[sb + 56..sb + 58].copy_from_slice(&0xEF53u16.to_le_bytes());
        d[sb + 58..sb + 60].copy_from_slice(&state.to_le_bytes());
        d[sb + 92..sb + 96].copy_from_slice(&4u32.to_le_bytes()); // has_journal
        d[sb + 96..sb + 100].copy_from_slice(&incompat.to_le_bytes());
        d[sb + 100..sb + 104].copy_from_slice(&ro_compat.to_le_bytes());
        for (i, c) in label.bytes().take(16).enumerate() {
            d[sb + 120 + i] = c;
        }
        d
    }

    #[test]
    fn fat32_is_identified_by_geometry_not_by_the_type_string() {
        let mut d = MemBlock::new(fat32_boot("G6LCKEY", 8));
        let p = probe(&mut d).unwrap();
        assert_eq!(p.kind, FsKind::Fat32);
        assert_eq!(p.label, "G6LCKEY");
        assert!(p.write_block.is_none(), "fat32 is the writable one");
        assert!(p.evidence.contains("root_entries=0"), "{p:?}");
        // A lying type string does not make FAT16 into FAT32.
        let mut bytes = fat32_boot("X", 8);
        bytes[17..19].copy_from_slice(&512u16.to_le_bytes()); // root entries
        bytes[22..24].copy_from_slice(&64u16.to_le_bytes()); // fat16 sectors
        let mut d = MemBlock::new(bytes);
        let p = probe(&mut d).unwrap();
        assert_eq!(p.kind, FsKind::Fat16);
        assert!(p.write_block.is_some());
    }

    #[test]
    fn ext_family_and_write_refusals_come_from_the_superblock() {
        // extents + 64bit → ext4, clean.
        let mut d = MemBlock::new(ext_sb("root", 0x0040 | 0x0080, 0, 1));
        let p = probe(&mut d).unwrap();
        assert_eq!(p.kind, FsKind::Ext4);
        assert_eq!(p.label, "root");
        assert!(!p.dirty && p.write_block.is_none(), "{p:?}");
        // needs_recovery → refuse to write, and say why.
        let mut d = MemBlock::new(ext_sb("root", 0x0040 | 0x0004, 0, 1));
        let p = probe(&mut d).unwrap();
        assert!(p.dirty, "{p:?}");
        assert!(p.write_block.unwrap().contains("needs recovery"));
        // Not clean → refuse.
        let mut d = MemBlock::new(ext_sb("root", 0x0040, 0, 0));
        let p = probe(&mut d).unwrap();
        assert!(p.dirty);
        assert!(p.write_block.unwrap().contains("not marked clean"));
        // No ext4 features but a journal → ext3.
        let mut d = MemBlock::new(ext_sb("old", 0, 0, 1));
        assert_eq!(probe(&mut d).unwrap().kind, FsKind::Ext3);
    }

    #[test]
    fn ntfs_exfat_iso_and_nothing() {
        let mut boot = vec![0u8; 4096];
        boot[3..11].copy_from_slice(b"NTFS    ");
        boot[510] = 0x55;
        boot[511] = 0xAA;
        let mut d = MemBlock::new(boot.clone());
        let p = probe(&mut d).unwrap();
        assert_eq!(p.kind, FsKind::Ntfs);
        assert!(p.write_block.unwrap().contains("read-only"));
        boot[3..11].copy_from_slice(b"EXFAT   ");
        let mut d = MemBlock::new(boot);
        assert_eq!(probe(&mut d).unwrap().kind, FsKind::ExFat);
        let mut iso = vec![0u8; 0x9000];
        iso[0x8000] = 1;
        iso[0x8001..0x8006].copy_from_slice(b"CD001");
        let mut d = MemBlock::new(iso);
        assert_eq!(probe(&mut d).unwrap().kind, FsKind::Iso9660);
        let mut blank = MemBlock::zeroed(4096);
        let p = probe(&mut blank).unwrap();
        assert_eq!(p.kind, FsKind::Unknown);
        assert!(!p.kind.readable());
    }
}
