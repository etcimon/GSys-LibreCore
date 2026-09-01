// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Minimal MBR + FAT16 ESP image writer. QEMU `fat:rw:<dir>` has no partition
// table; U-Boot distro boot (`part list` → `virtio 0:1`) needs one. No extra
// crates — g6lc_qemu first-party path deps only.

use std::path::Path;

const SECTOR: usize = 512;
const PART_LBA: u32 = 2048;
const IMG_BYTES: usize = 64 * 1024 * 1024;
const SPC: u32 = 8; // 4 KiB clusters
const RESERVED: u32 = 1;
const NUM_FATS: u32 = 2;
const ROOT_ENT: u32 = 512;
const ATTR_DIR: u8 = 0x10;
const ATTR_ARCHIVE: u8 = 0x20;
const ATTR_LFN: u8 = 0x0F;
const FAT16_EOF: u16 = 0xFFFF;

/// Write a 64 MiB MBR disk whose first partition is a FAT16 ESP containing
/// `EFI/BOOT/<efi_name>` with the payload bytes.
pub fn write_esp_disk_image(payload: &[u8], efi_name: &str, img: &Path) -> Result<(), String> {
    let bytes = build_mbr_fat16_esp(efi_name, payload)?;
    if let Some(parent) = img.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("cannot create {}: {e}", parent.display()))?;
    }
    std::fs::write(img, bytes).map_err(|e| format!("cannot write {}: {e}", img.display()))?;
    Ok(())
}

fn build_mbr_fat16_esp(efi_name: &str, payload: &[u8]) -> Result<Vec<u8>, String> {
    let part_sectors = (IMG_BYTES / SECTOR) as u32 - PART_LBA;
    let root_secs = (ROOT_ENT * 32).div_ceil(SECTOR as u32);
    let data_hint = part_sectors
        .saturating_sub(RESERVED)
        .saturating_sub(root_secs);
    let fat_secs = fat16_sectors_per_fat(data_hint, SPC)?;
    let data_secs = data_hint.saturating_sub(NUM_FATS * fat_secs);
    let clusters = data_secs / SPC;
    if !(4085..=65524).contains(&clusters) {
        return Err(format!("FAT16 cluster count {clusters} is out of range"));
    }
    let cluster_bytes = SPC as usize * SECTOR;
    // Two directory clusters (EFI/, BOOT/) plus the payload.
    let need = 2 + payload.len().div_ceil(cluster_bytes) as u32;
    if need > clusters {
        return Err(format!(
            "ESP payload {} bytes does not fit in the 64 MiB image",
            payload.len()
        ));
    }

    let mut img = vec![0u8; IMG_BYTES];
    write_mbr(&mut img, part_sectors);
    write_boot_sector(&mut img, part_sectors, fat_secs);

    let fat_off = (PART_LBA + RESERVED) as usize * SECTOR;
    fat16_set(&mut img, fat_off, fat_secs, 0, 0xFFF8);
    fat16_set(&mut img, fat_off, fat_secs, 1, FAT16_EOF);

    let first_data_lba = PART_LBA + RESERVED + NUM_FATS * fat_secs + root_secs;
    let mut next = 2u16;

    let efi_cluster = alloc_one(&mut img, fat_off, fat_secs, &mut next)?;
    let boot_cluster = alloc_one(&mut img, fat_off, fat_secs, &mut next)?;
    let file_first = alloc_chain(
        &mut img,
        fat_off,
        fat_secs,
        &mut next,
        payload.len().div_ceil(cluster_bytes).max(1) as u16,
    )?;

    let efi_off = cluster_off(first_data_lba, efi_cluster);
    let boot_off = cluster_off(first_data_lba, boot_cluster);
    let file_off = cluster_off(first_data_lba, file_first);
    img[file_off..file_off + payload.len()].copy_from_slice(payload);

    let mut efi_dir: Vec<[u8; 32]> = Vec::new();
    dir_dot(&mut efi_dir, efi_cluster, 0);
    dir_short(&mut efi_dir, dos83("BOOT"), ATTR_DIR, boot_cluster, 0);
    write_dir(&mut img, efi_off, cluster_bytes, &efi_dir)?;

    let mut boot_dir: Vec<[u8; 32]> = Vec::new();
    dir_dot(&mut boot_dir, boot_cluster, efi_cluster);
    dir_lfn_file(&mut boot_dir, efi_name, file_first, payload.len() as u32)?;
    write_dir(&mut img, boot_off, cluster_bytes, &boot_dir)?;

    let root_off = (PART_LBA + RESERVED + NUM_FATS * fat_secs) as usize * SECTOR;
    let mut root: Vec<[u8; 32]> = Vec::new();
    dir_short(&mut root, dos83("EFI"), ATTR_DIR, efi_cluster, 0);
    write_dir(&mut img, root_off, root_secs as usize * SECTOR, &root)?;
    Ok(img)
}

fn fat16_sectors_per_fat(data_hint: u32, spc: u32) -> Result<u32, String> {
    let mut fat_secs = 1u32;
    for _ in 0..64 {
        let data = data_hint.saturating_sub(NUM_FATS * fat_secs);
        let clusters = data / spc;
        let needed = ((clusters + 2) * 2).div_ceil(SECTOR as u32);
        if needed <= fat_secs {
            return Ok(fat_secs.max(1));
        }
        fat_secs = needed;
    }
    Err("cannot size the FAT16 table".into())
}

fn write_mbr(img: &mut [u8], part_sectors: u32) {
    img[0x1BE] = 0x80;
    img[0x1C2] = 0x0E; // FAT16 LBA
    img[0x1C6..0x1CA].copy_from_slice(&PART_LBA.to_le_bytes());
    img[0x1CA..0x1CE].copy_from_slice(&part_sectors.to_le_bytes());
    img[0x1FE] = 0x55;
    img[0x1FF] = 0xAA;
}

fn write_boot_sector(img: &mut [u8], part_sectors: u32, fat_secs: u32) {
    let off = PART_LBA as usize * SECTOR;
    let b = &mut img[off..off + SECTOR];
    b[0..3].copy_from_slice(&[0xEB, 0x3C, 0x90]);
    b[3..11].copy_from_slice(b"G6LCQEMU");
    b[11..13].copy_from_slice(&(SECTOR as u16).to_le_bytes());
    b[13] = SPC as u8;
    b[14..16].copy_from_slice(&(RESERVED as u16).to_le_bytes());
    b[16] = NUM_FATS as u8;
    b[17..19].copy_from_slice(&(ROOT_ENT as u16).to_le_bytes());
    b[21] = 0xF8;
    b[22..24].copy_from_slice(&(fat_secs as u16).to_le_bytes());
    b[24..26].copy_from_slice(&63u16.to_le_bytes());
    b[26..28].copy_from_slice(&255u16.to_le_bytes());
    b[28..32].copy_from_slice(&PART_LBA.to_le_bytes());
    if part_sectors < 0x10000 {
        b[19..21].copy_from_slice(&(part_sectors as u16).to_le_bytes());
    } else {
        b[32..36].copy_from_slice(&part_sectors.to_le_bytes());
    }
    b[36] = 0x80;
    b[38] = 0x29;
    b[39..43].copy_from_slice(&0xC6_1C_E5_10u32.to_le_bytes());
    b[43..54].copy_from_slice(b"G6LC ESP   ");
    b[54..62].copy_from_slice(b"FAT16   ");
    b[510] = 0x55;
    b[511] = 0xAA;
}

fn cluster_off(first_data_lba: u32, cluster: u16) -> usize {
    (first_data_lba + u32::from(cluster - 2) * SPC) as usize * SECTOR
}

fn fat16_set(img: &mut [u8], fat_off: usize, fat_secs: u32, cluster: u16, val: u16) {
    let le = val.to_le_bytes();
    let a = fat_off + cluster as usize * 2;
    img[a..a + 2].copy_from_slice(&le);
    let b = fat_off + fat_secs as usize * SECTOR + cluster as usize * 2;
    img[b..b + 2].copy_from_slice(&le);
}

fn alloc_one(img: &mut [u8], fat_off: usize, fat_secs: u32, next: &mut u16) -> Result<u16, String> {
    let c = *next;
    *next = next.checked_add(1).ok_or("FAT16 cluster overflow")?;
    fat16_set(img, fat_off, fat_secs, c, FAT16_EOF);
    Ok(c)
}

fn alloc_chain(
    img: &mut [u8],
    fat_off: usize,
    fat_secs: u32,
    next: &mut u16,
    count: u16,
) -> Result<u16, String> {
    let first = *next;
    for i in 0..count {
        let c = *next;
        *next = next.checked_add(1).ok_or("FAT16 cluster overflow")?;
        let val = if i + 1 == count { FAT16_EOF } else { *next };
        fat16_set(img, fat_off, fat_secs, c, val);
    }
    Ok(first)
}

fn dos83(name: &str) -> [u8; 11] {
    let mut out = [b' '; 11];
    let (stem, ext) = match name.rsplit_once('.') {
        Some((s, e)) => (s, e),
        None => (name, ""),
    };
    let stem_up = stem.to_ascii_uppercase();
    let ext_up = ext.to_ascii_uppercase();
    if stem_up.len() <= 8 && ext_up.len() <= 3 && stem_up.bytes().all(|b| b.is_ascii_alphanumeric())
    {
        out[..stem_up.len()].copy_from_slice(stem_up.as_bytes());
        out[8..8 + ext_up.len()].copy_from_slice(ext_up.as_bytes());
        return out;
    }
    let take = stem_up.len().min(6);
    out[..take].copy_from_slice(&stem_up.as_bytes()[..take]);
    out[take..take + 2].copy_from_slice(b"~1");
    let elen = ext_up.len().min(3);
    out[8..8 + elen].copy_from_slice(&ext_up.as_bytes()[..elen]);
    out
}

fn lfn_checksum(name11: &[u8; 11]) -> u8 {
    let mut sum: u8 = 0;
    for b in name11 {
        sum = sum.rotate_right(1).wrapping_add(*b);
    }
    sum
}

fn dir_short(dir: &mut Vec<[u8; 32]>, name: [u8; 11], attr: u8, cluster: u16, size: u32) {
    let mut e = [0u8; 32];
    e[..11].copy_from_slice(&name);
    e[11] = attr;
    e[26..28].copy_from_slice(&cluster.to_le_bytes());
    e[28..32].copy_from_slice(&size.to_le_bytes());
    dir.push(e);
}

fn dir_dot(dir: &mut Vec<[u8; 32]>, cluster: u16, parent: u16) {
    let mut dot = [b' '; 11];
    dot[0] = b'.';
    dir_short(dir, dot, ATTR_DIR, cluster, 0);
    let mut dotdot = [b' '; 11];
    dotdot[0] = b'.';
    dotdot[1] = b'.';
    dir_short(dir, dotdot, ATTR_DIR, parent, 0);
}

fn dir_lfn_file(
    dir: &mut Vec<[u8; 32]>,
    name: &str,
    cluster: u16,
    size: u32,
) -> Result<(), String> {
    let short = dos83(name);
    let chk = lfn_checksum(&short);
    let utf16: Vec<u16> = name.encode_utf16().collect();
    let chunks = utf16.len().div_ceil(13);
    if chunks == 0 || chunks > 20 {
        return Err(format!("cannot encode LFN {name}"));
    }
    for seq in (1..=chunks).rev() {
        let mut e = [0u8; 32];
        let n = seq as u8;
        e[0] = if seq == chunks { n | 0x40 } else { n };
        e[11] = ATTR_LFN;
        e[13] = chk;
        let start = (seq - 1) * 13;
        put_lfn_chars(&mut e, &utf16, start);
        dir.push(e);
    }
    dir_short(dir, short, ATTR_ARCHIVE, cluster, size);
    Ok(())
}

fn put_lfn_chars(e: &mut [u8; 32], utf16: &[u16], start: usize) {
    // Offsets of the 13 UTF-16 slots in an LFN entry.
    const SLOTS: [usize; 13] = [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30];
    for (i, slot) in SLOTS.iter().enumerate() {
        let unit = match (start + i).cmp(&utf16.len()) {
            std::cmp::Ordering::Less => utf16[start + i],
            std::cmp::Ordering::Equal => 0x0000,
            std::cmp::Ordering::Greater => 0xFFFF,
        };
        e[*slot..*slot + 2].copy_from_slice(&unit.to_le_bytes());
    }
}

fn write_dir(img: &mut [u8], off: usize, bytes: usize, entries: &[[u8; 32]]) -> Result<(), String> {
    if entries.len() * 32 > bytes {
        return Err("directory does not fit in its cluster".into());
    }
    for (i, e) in entries.iter().enumerate() {
        let o = off + i * 32;
        img[o..o + 32].copy_from_slice(e);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mbr_fat16_esp_holds_pe_and_lfn() {
        let pe = b"MZ-g6lc-openwrt-efi-stub";
        let img = build_mbr_fat16_esp("BOOTRISCV64.EFI", pe).unwrap();
        assert_eq!(img.len(), IMG_BYTES);
        assert_eq!(&img[0x1FE..0x200], &[0x55, 0xAA]);
        assert_eq!(img[0x1C2], 0x0E);
        assert_eq!(&img[0x1C6..0x1CA], &PART_LBA.to_le_bytes());
        let part = PART_LBA as usize * SECTOR;
        assert_eq!(&img[part + 54..part + 62], b"FAT16   ");
        assert!(img.windows(pe.len()).any(|w| w == pe));
        // 8.3 alias BOOTRI~1.EFI; LFN first five UCS-2 chars sit contiguously.
        assert!(
            img.windows(11).any(|w| w == b"BOOTRI~1EFI"),
            "missing 8.3 alias BOOTRI~1.EFI"
        );
        let lfn5: Vec<u8> = "BOOTR"
            .encode_utf16()
            .flat_map(|u| u.to_le_bytes())
            .collect();
        assert!(
            img.windows(lfn5.len()).any(|w| w == lfn5),
            "missing LFN prefix for BOOTRISCV64.EFI"
        );
    }
}
