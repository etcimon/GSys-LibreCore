// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Partition tables: GPT first, MBR as the fallback, and "the whole disk is one
//! filesystem" as the last resort — which is what a formatted USB key usually is.
//!
//! The on-disk contracts:
//!
//! * **GPT** (UEFI 2.10 §5.3): the protective MBR is LBA 0, the header is LBA 1
//!   with signature `"EFI PART"`, and the entry array it points at holds
//!   128-byte entries `{type GUID, unique GUID, first LBA, last LBA, flags,
//!   UTF-16LE name[36]}`. The header carries a CRC32 of itself (with the field
//!   zeroed) and of the entry array; both are checked, because a boot menu built
//!   on a corrupt table is worse than one that says the table is corrupt.
//! * **MBR** (LBA 0): `0x55AA` at 510, four 16-byte entries at 446 with
//!   `{status, chs, type, chs, first LBA, sectors}`. Type `0xEE` means "look at
//!   the GPT", `0xEF` is an ESP, `0x83` Linux, `0x07` NTFS/exFAT, `0x0B/0x0C`
//!   FAT32.
//!
//! Type GUIDs are recognized only to *name* a partition for the operator; what a
//! partition actually holds is decided by [`crate::probe`] reading its superblock.

use crate::block::{le16, le32, le64, read_array, read_vec, BlockDev, MemBlock, SECTOR};
use crate::{Error, Result};

/// A partition as the operator will see it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Partition {
    /// 1-based index, the way every partition tool numbers them.
    pub index: u32,
    /// Byte offset of the partition on its device.
    pub start: u64,
    /// Length in bytes.
    pub len: u64,
    /// What the table claims it is (`esp`, `linux`, `ms-basic-data`, `0x83`…).
    pub kind: String,
    /// GPT partition name, when the table carried one.
    pub name: String,
    /// True for a GPT ESP or an MBR type `0xEF` — where a loader lives.
    pub esp: bool,
    /// MBR "active"/bootable flag.
    pub bootable: bool,
}

impl Partition {
    pub fn sectors(&self) -> u64 {
        self.len / SECTOR
    }
}

/// Which table a device carried.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scheme {
    Gpt,
    Mbr,
    /// No table: the filesystem starts at byte 0 (a "superfloppy" key).
    None,
}

impl Scheme {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Gpt => "gpt",
            Self::Mbr => "mbr",
            Self::None => "none",
        }
    }
}

/// The partitions on a device, and which scheme described them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Table {
    pub scheme: Scheme,
    pub parts: Vec<Partition>,
    /// Notes worth showing an operator: a bad CRC, a table that points outside
    /// the device, an ignored entry.
    pub warnings: Vec<String>,
}

/// Read the partition table.
///
/// A device with no recognizable table gets a single synthetic partition
/// covering it, so callers have exactly one code path.
pub fn read_table(dev: &mut dyn BlockDev) -> Result<Table> {
    if dev.len() < SECTOR * 2 {
        return Err(Error::TooSmall);
    }
    let mut warnings = Vec::new();
    match read_gpt(dev, &mut warnings) {
        Ok(parts) if !parts.is_empty() => {
            return Ok(Table {
                scheme: Scheme::Gpt,
                parts,
                warnings,
            })
        }
        Ok(_) => {}
        Err(Error::NotFound) => {}
        Err(e) => warnings.push(format!("gpt: {e}")),
    }
    match read_mbr(dev, &mut warnings) {
        Ok(parts) if !parts.is_empty() => {
            return Ok(Table {
                scheme: Scheme::Mbr,
                parts,
                warnings,
            })
        }
        Ok(_) => {}
        Err(Error::NotFound) => {}
        Err(e) => warnings.push(format!("mbr: {e}")),
    }
    Ok(Table {
        scheme: Scheme::None,
        parts: vec![Partition {
            index: 1,
            start: 0,
            len: dev.len(),
            kind: "whole-disk".into(),
            name: String::new(),
            esp: false,
            bootable: false,
        }],
        warnings,
    })
}

const GPT_SIG: &[u8; 8] = b"EFI PART";

fn read_gpt(dev: &mut dyn BlockDev, warnings: &mut Vec<String>) -> Result<Vec<Partition>> {
    let head = read_array::<92>(dev, SECTOR)?;
    if &head[0..8] != GPT_SIG {
        return Err(Error::NotFound);
    }
    // The header CRC covers `header_size` bytes with the CRC field zeroed.
    let header_size = le32(&head, 12) as usize;
    if !(92..=512).contains(&header_size) {
        return Err(Error::Corrupt("gpt header size"));
    }
    let mut hdr = read_vec(dev, SECTOR, header_size)?;
    let want = le32(&hdr, 16);
    hdr[16..20].fill(0);
    if crc32(&hdr) != want {
        warnings.push("gpt header crc32 mismatch".into());
    }
    let entry_lba = le64(&head, 72);
    let count = le32(&head, 80);
    let size = le32(&head, 84);
    if !(128..=4096).contains(&size) || count > 512 {
        return Err(Error::Corrupt("gpt entry geometry"));
    }
    let array_bytes = (count as usize).saturating_mul(size as usize);
    let array = read_vec(dev, entry_lba.saturating_mul(SECTOR), array_bytes)?;
    if crc32(&array) != le32(&head, 88) {
        warnings.push("gpt entry-array crc32 mismatch".into());
    }
    let mut out = Vec::new();
    for i in 0..count as usize {
        let e = &array[i * size as usize..i * size as usize + 128];
        // An all-zero type GUID is an unused entry.
        if e[0..16].iter().all(|b| *b == 0) {
            continue;
        }
        let first = le64(e, 32);
        let last = le64(e, 40);
        if last < first {
            warnings.push(format!("gpt entry {} ends before it starts", i + 1));
            continue;
        }
        let start = first.saturating_mul(SECTOR);
        let len = (last - first + 1).saturating_mul(SECTOR);
        if start.saturating_add(len) > dev.len() {
            warnings.push(format!("gpt entry {} runs past the device", i + 1));
            continue;
        }
        let guid = guid_str(&e[0..16]);
        let (kind, esp) = gpt_kind(&guid);
        out.push(Partition {
            index: (i + 1) as u32,
            start,
            len,
            kind: kind.to_string(),
            name: utf16le_name(&e[56..128]),
            esp,
            bootable: false,
        });
    }
    Ok(out)
}

fn read_mbr(dev: &mut dyn BlockDev, warnings: &mut Vec<String>) -> Result<Vec<Partition>> {
    let mbr = read_array::<512>(dev, 0)?;
    if le16(&mbr, 510) != 0xAA55 {
        return Err(Error::NotFound);
    }
    let mut out = Vec::new();
    for i in 0..4 {
        let e = &mbr[446 + i * 16..446 + i * 16 + 16];
        let ty = e[4];
        if ty == 0 {
            continue;
        }
        if ty == 0xEE {
            // Protective MBR: the GPT is the truth and we already looked.
            continue;
        }
        let first = u64::from(le32(e, 8));
        let sectors = u64::from(le32(e, 12));
        if first == 0 || sectors == 0 {
            continue;
        }
        let start = first * SECTOR;
        let len = sectors * SECTOR;
        if start.saturating_add(len) > dev.len() {
            warnings.push(format!("mbr entry {} runs past the device", i + 1));
            continue;
        }
        out.push(Partition {
            index: (i + 1) as u32,
            start,
            len,
            kind: mbr_kind(ty).to_string(),
            name: String::new(),
            esp: ty == 0xEF,
            bootable: e[0] == 0x80,
        });
    }
    Ok(out)
}

/// GPT type GUID → an operator-facing name. Unknown GUIDs keep the GUID, which
/// is more useful than "unknown".
fn gpt_kind(guid: &str) -> (&'static str, bool) {
    match guid {
        "C12A7328-F81F-11D2-BA4B-00A0C93EC93B" => ("esp", true),
        "0FC63DAF-8483-4772-8E79-3D69D8477DE4" => ("linux-filesystem", false),
        "4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709" => ("linux-root-x86-64", false),
        "72EC70A6-CF74-40E6-BD49-4BDA08E8F224" => ("linux-root-riscv64", false),
        "0657FD6D-A4AB-43C4-84E5-0933C84B4F4F" => ("linux-swap", false),
        "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7" => ("ms-basic-data", false),
        "DE94BBA4-06D1-4D40-A16A-BFD50179D6AC" => ("windows-recovery", false),
        "21686148-6449-6E6F-744E-656564454649" => ("bios-boot", false),
        "BC13C2FF-59E6-4262-A352-B275FD6F7172" => ("extended-boot", false),
        other => (leak_kind(other), false),
    }
}

/// An unknown GUID is still information, so it is kept verbatim. The set of
/// unknown GUIDs a BIOS meets is bounded by the disks it is shown, and this
/// leaks at most one small string per new GUID for the life of the process.
fn leak_kind(guid: &str) -> &'static str {
    Box::leak(guid.to_string().into_boxed_str())
}

fn mbr_kind(ty: u8) -> &'static str {
    match ty {
        0x01 | 0x04 | 0x06 | 0x0E => "fat16",
        0x0B | 0x0C => "fat32",
        0x07 => "ntfs/exfat",
        0x83 => "linux",
        0x82 => "linux-swap",
        0x8E => "linux-lvm",
        0xEF => "esp",
        0x05 | 0x0F => "extended",
        0xFD => "linux-raid",
        _ => "unknown",
    }
}

/// Mixed-endian GUID text, the way every partition tool prints it.
fn guid_str(b: &[u8]) -> String {
    let hex = |v: &[u8]| -> String {
        v.iter()
            .map(|x| format!("{x:02X}"))
            .collect::<Vec<_>>()
            .join("")
    };
    format!(
        "{}-{}-{}-{}-{}",
        hex(&[b[3], b[2], b[1], b[0]]),
        hex(&[b[5], b[4]]),
        hex(&[b[7], b[6]]),
        hex(&b[8..10]),
        hex(&b[10..16])
    )
}

/// GPT names are UTF-16LE, NUL-padded. Non-ASCII becomes `?` because the 8x8
/// glyph face has no code point for it.
fn utf16le_name(b: &[u8]) -> String {
    let mut s = String::new();
    for pair in b.chunks_exact(2) {
        let c = u16::from_le_bytes([pair[0], pair[1]]);
        if c == 0 {
            break;
        }
        match char::from_u32(u32::from(c)) {
            Some(ch) if ch.is_ascii_graphic() || ch == ' ' => s.push(ch),
            _ => s.push('?'),
        }
    }
    s.trim().to_string()
}

/// CRC-32 (IEEE 802.3, reflected) — the one GPT uses.
pub fn crc32(data: &[u8]) -> u32 {
    let mut crc = !0u32;
    for b in data {
        crc ^= u32::from(*b);
        for _ in 0..8 {
            let mask = (crc & 1).wrapping_neg();
            crc = (crc >> 1) ^ (0xEDB8_8320 & mask);
        }
    }
    !crc
}

/// A GPT with `parts` entries, CRCs computed the way a real tool writes them.
pub fn gpt_fixture(parts: &[(u64, u64, [u8; 16], &str)], sectors: u64) -> MemBlock {
    let mut d = vec![0u8; (sectors * SECTOR) as usize];
    // Protective MBR.
    d[446 + 4] = 0xEE;
    d[510] = 0x55;
    d[511] = 0xAA;
    // Entry array at LBA 2.
    let entries_at = 2 * SECTOR as usize;
    let count = 128u32;
    let size = 128u32;
    for (i, (first, last, ty, name)) in parts.iter().enumerate() {
        let e = entries_at + i * size as usize;
        d[e..e + 16].copy_from_slice(ty);
        d[e + 16..e + 32].copy_from_slice(&[0x11; 16]);
        d[e + 32..e + 40].copy_from_slice(&first.to_le_bytes());
        d[e + 40..e + 48].copy_from_slice(&last.to_le_bytes());
        for (j, ch) in name.encode_utf16().enumerate().take(36) {
            let at = e + 56 + j * 2;
            d[at..at + 2].copy_from_slice(&ch.to_le_bytes());
        }
    }
    let array_len = (count * size) as usize;
    let array_crc = crc32(&d[entries_at..entries_at + array_len]);
    // Header at LBA 1.
    let h = SECTOR as usize;
    d[h..h + 8].copy_from_slice(GPT_SIG);
    d[h + 8..h + 12].copy_from_slice(&0x0001_0000u32.to_le_bytes());
    d[h + 12..h + 16].copy_from_slice(&92u32.to_le_bytes());
    d[h + 24..h + 32].copy_from_slice(&1u64.to_le_bytes());
    d[h + 32..h + 40].copy_from_slice(&(sectors - 1).to_le_bytes());
    d[h + 40..h + 48].copy_from_slice(&34u64.to_le_bytes());
    d[h + 48..h + 56].copy_from_slice(&(sectors - 34).to_le_bytes());
    d[h + 72..h + 80].copy_from_slice(&2u64.to_le_bytes());
    d[h + 80..h + 84].copy_from_slice(&count.to_le_bytes());
    d[h + 84..h + 88].copy_from_slice(&size.to_le_bytes());
    d[h + 88..h + 92].copy_from_slice(&array_crc.to_le_bytes());
    let hdr_crc = crc32(&d[h..h + 92]);
    d[h + 16..h + 20].copy_from_slice(&hdr_crc.to_le_bytes());
    MemBlock::new(d)
}

#[cfg(test)]
mod tests {
    use super::*;

    const ESP_GUID: [u8; 16] = [
        0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11, 0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9,
        0x3B,
    ];
    const LINUX_GUID: [u8; 16] = [
        0xAF, 0x3D, 0xC6, 0x0F, 0x83, 0x84, 0x72, 0x47, 0x8E, 0x79, 0x3D, 0x69, 0xD8, 0x47, 0x7D,
        0xE4,
    ];

    #[test]
    fn gpt_is_read_with_names_and_checked_crcs() {
        let mut d = gpt_fixture(
            &[
                (2048, 4095, ESP_GUID, "EFI System"),
                (4096, 8191, LINUX_GUID, "root"),
            ],
            16384,
        );
        let t = read_table(&mut d).unwrap();
        assert_eq!(t.scheme, Scheme::Gpt);
        assert!(t.warnings.is_empty(), "{:?}", t.warnings);
        assert_eq!(t.parts.len(), 2);
        assert_eq!(t.parts[0].kind, "esp");
        assert!(t.parts[0].esp);
        assert_eq!(t.parts[0].name, "EFI System");
        assert_eq!(t.parts[0].start, 2048 * 512);
        assert_eq!(t.parts[0].len, 2048 * 512);
        assert_eq!(t.parts[1].kind, "linux-filesystem");
        assert_eq!(t.parts[1].name, "root");
        assert_eq!(t.parts[1].index, 2);
    }

    #[test]
    fn a_corrupt_gpt_crc_is_reported_not_hidden() {
        let mut d = gpt_fixture(&[(2048, 4095, ESP_GUID, "EFI System")], 16384);
        // Flip a byte inside the entry array.
        let mut bytes = d.bytes().to_vec();
        bytes[2 * 512 + 60] ^= 0xFF;
        d = MemBlock::new(bytes);
        let t = read_table(&mut d).unwrap();
        assert_eq!(t.scheme, Scheme::Gpt, "the table is still usable");
        assert!(
            t.warnings.iter().any(|w| w.contains("entry-array crc32")),
            "{:?}",
            t.warnings
        );
    }

    #[test]
    fn mbr_types_and_the_active_flag() {
        let mut d = vec![0u8; 4096 * 512];
        // Entry 1: bootable FAT32 at LBA 2048, 8 sectors.
        d[446] = 0x80;
        d[446 + 4] = 0x0C;
        d[446 + 8..446 + 12].copy_from_slice(&2048u32.to_le_bytes());
        d[446 + 12..446 + 16].copy_from_slice(&8u32.to_le_bytes());
        // Entry 2: Linux, past the end of the device — must be refused.
        d[462 + 4] = 0x83;
        d[462 + 8..462 + 12].copy_from_slice(&8192u32.to_le_bytes());
        d[462 + 12..462 + 16].copy_from_slice(&8u32.to_le_bytes());
        d[510] = 0x55;
        d[511] = 0xAA;
        let mut dev = MemBlock::new(d);
        let t = read_table(&mut dev).unwrap();
        assert_eq!(t.scheme, Scheme::Mbr);
        assert_eq!(t.parts.len(), 1);
        assert_eq!(t.parts[0].kind, "fat32");
        assert!(t.parts[0].bootable);
        assert!(t.warnings.iter().any(|w| w.contains("past the device")));
    }

    #[test]
    fn no_table_means_one_whole_disk_partition() {
        let mut d = MemBlock::zeroed(64 * 512);
        let t = read_table(&mut d).unwrap();
        assert_eq!(t.scheme, Scheme::None);
        assert_eq!(t.parts.len(), 1);
        assert_eq!(t.parts[0].start, 0);
        assert_eq!(t.parts[0].len, 64 * 512);
        assert_eq!(t.parts[0].kind, "whole-disk");
        // Too small to hold a table at all.
        let mut tiny = MemBlock::zeroed(512);
        assert!(matches!(read_table(&mut tiny), Err(Error::TooSmall)));
    }

    #[test]
    fn crc32_matches_the_known_vector() {
        // The standard check value for "123456789".
        assert_eq!(crc32(b"123456789"), 0xCBF4_3926);
        assert_eq!(crc32(b""), 0);
    }
}
