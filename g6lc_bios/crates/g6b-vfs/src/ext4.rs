// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! ext2/3/4 — read, plus a **narrow, guarded** write.
//!
//! This is the driver that makes `cd /etc` and `cat /etc/fstab` work on a real
//! Linux root, which is the whole point of a repair shell.
//!
//! On-disk contract (`fs/ext4/ext4.h`):
//!
//! * Superblock at byte 1024: `s_inodes_count` (0), `s_blocks_count_lo` (4),
//!   `s_first_data_block` (20), `s_log_block_size` (24), `s_inodes_per_group`
//!   (40), `s_magic` (56), `s_state` (58), `s_inode_size` (88),
//!   `s_feature_incompat` (96), `s_desc_size` (254).
//! * Group descriptors follow the superblock's block: `bg_inode_table_lo` at +8
//!   (32 or 64 bytes per descriptor).
//! * An inode's `i_mode` (0), `i_size_lo` (4), `i_flags` (32), `i_block[60]`
//!   (40), `i_size_high` (108).
//! * `EXT4_EXTENTS_FL` (0x80000) in `i_flags` means `i_block` holds an extent
//!   tree: header `{magic 0xF30A, entries, max, depth}` then either index nodes
//!   (depth > 0) or 12-byte leaves `{ee_block, ee_len, ee_start_hi, ee_start_lo}`.
//!   Without that flag, `i_block[0..12]` are direct blocks and 12/13/14 are the
//!   single/double/triple indirect blocks.
//! * A directory is a chain of `{inode, rec_len, name_len, file_type, name[]}`.
//!
//! **Writing.** A journalling filesystem is not something a BIOS should rewrite
//! casually, so the write path is deliberately small: an *existing* regular file
//! can be overwritten **in place**, only when the new content fits the blocks
//! already allocated to it, and only when the superblock says the filesystem is
//! clean and needs no recovery. No allocation, no journal, no metadata beyond the
//! size field. Anything else is refused with the reason. That is enough to fix a
//! boot (`/etc/fstab`, `/boot/extlinux/extlinux.conf`, a kernel command line) and
//! far short of a filesystem implementation pretending to be safe.

use crate::block::{le16, le32, read_vec, BlockDev, MemBlock};
use crate::{DirEnt, Error, FileSystem, FsKind, Result, Stat};

const EXT4_MAGIC: u16 = 0xEF53;
const ROOT_INO: u32 = 2;
const S_IFMT: u16 = 0xF000;
const S_IFDIR: u16 = 0x4000;
const S_IFREG: u16 = 0x8000;
const S_IFLNK: u16 = 0xA000;
const EXTENTS_FL: u32 = 0x0008_0000;
const INLINE_DATA_FL: u32 = 0x1000_0000;
const EXTENT_MAGIC: u16 = 0xF30A;
const INCOMPAT_FILETYPE: u32 = 0x0002;
const INCOMPAT_RECOVER: u32 = 0x0004;
const INCOMPAT_EXTENTS: u32 = 0x0040;
const INCOMPAT_64BIT: u32 = 0x0080;
/// `EXT4_INDEX_FL` — a hashed (dir_index) directory. Adding an entry means
/// updating the hash tree too, which is the OS's job: refused, named.
const INDEX_FL: u32 = 0x0000_1000;
/// `file_type` of the fake dirent an ext4 dir block carries when
/// `metadata_csum` is on: `{inode:0, rec_len:12, name_len:0, ft:0xDE}` at the
/// block's last 12 bytes, holding `ext4_dirblock_csum`.
const DIR_CSUM_FT: u8 = 0xDE;
/// The ceiling on one extent's `ee_len` — 32768 marks *uninitialized*, so a
/// real extent must stay under it.
const EXTENT_MAX_LEN: u16 = 32768;
/// `EXT4_FEATURE_INCOMPAT_CSUM_SEED` — the seed is in the superblock rather than
/// derived from the UUID.
const INCOMPAT_CSUM_SEED: u32 = 0x2000;
/// `EXT4_FEATURE_RO_COMPAT_METADATA_CSUM` — inodes carry a crc32c, and an
/// unchecksummed write is a filesystem error even when the data is right.
const RO_COMPAT_METADATA_CSUM: u32 = 0x0400;

/// CRC-32C (Castagnoli, reflected) *continuation* — no pre/post inversion, which
/// is what `crc32c(seed, data, len)` means in the kernel and therefore what ext4's
/// checksum chain is built from.
pub fn crc32c(mut crc: u32, data: &[u8]) -> u32 {
    for b in data {
        crc ^= u32::from(*b);
        for _ in 0..8 {
            let mask = (crc & 1).wrapping_neg();
            crc = (crc >> 1) ^ (0x82F6_3B78 & mask);
        }
    }
    crc
}

/// A mounted ext volume.
pub struct Ext4<'a> {
    dev: &'a mut dyn BlockDev,
    block_size: u64,
    inodes_per_group: u32,
    inode_size: u64,
    first_data_block: u32,
    desc_size: u64,
    groups: u32,
    kind: FsKind,
    label: String,
    rw: bool,
    /// Why writes are refused, when they are.
    refusal: Option<String>,
    /// `metadata_csum`: every inode carries a crc32c that a write must refresh.
    csum: bool,
    /// The seed every metadata checksum chains from.
    csum_seed: u32,
    /// `s_blocks_per_group` — how the group bitmaps divide the device.
    blocks_per_group: u64,
    /// `s_blocks_count` — the low word; the hi word lives past 2^32 blocks,
    /// which no volume this driver writes is going to have.
    total_blocks: u64,
    /// The filesystem allocates through extents (`INCOMPAT_EXTENTS`).
    has_extents: bool,
    /// Dirent `file_type` bytes are live (`INCOMPAT_FILETYPE`).
    has_filetype: bool,
}

/// The inode fields this driver uses.
#[derive(Debug, Clone)]
struct Inode {
    mode: u16,
    size: u64,
    flags: u32,
    block: [u8; 60],
}

impl Inode {
    fn is_dir(&self) -> bool {
        self.mode & S_IFMT == S_IFDIR
    }

    fn is_reg(&self) -> bool {
        self.mode & S_IFMT == S_IFREG
    }

    fn is_link(&self) -> bool {
        self.mode & S_IFMT == S_IFLNK
    }
}

impl<'a> Ext4<'a> {
    pub fn mount(dev: &'a mut dyn BlockDev, rw: bool) -> Result<Self> {
        let sb = read_vec(dev, 1024, 1024)?;
        if le16(&sb, 56) != EXT4_MAGIC {
            return Err(Error::Corrupt("ext: superblock magic"));
        }
        let log_bs = le32(&sb, 24);
        if log_bs > 6 {
            return Err(Error::Corrupt("ext: implausible block size"));
        }
        let block_size = 1024u64 << log_bs;
        let inodes_per_group = le32(&sb, 40);
        let inode_size = u64::from(le16(&sb, 88));
        let incompat = le32(&sb, 96);
        let needs_recovery = incompat & INCOMPAT_RECOVER != 0;
        let desc_size = if incompat & INCOMPAT_64BIT != 0 {
            u64::from(le16(&sb, 254)).max(64)
        } else {
            32
        };
        let inodes_count = le32(&sb, 0);
        if inodes_per_group == 0 || inode_size < 128 || inodes_count == 0 {
            return Err(Error::Corrupt("ext: implausible inode geometry"));
        }
        let groups = inodes_count.div_ceil(inodes_per_group);
        // `metadata_csum`: the seed is `s_checksum_seed` when the fs carries one,
        // otherwise crc32c over the UUID. Getting this wrong writes an inode that
        // `e2fsck` will call an error even though the data is right.
        let ro_compat = le32(&sb, 100);
        let csum = ro_compat & RO_COMPAT_METADATA_CSUM != 0;
        let csum_seed = if incompat & INCOMPAT_CSUM_SEED != 0 {
            le32(&sb, 624)
        } else {
            crc32c(!0u32, &sb[104..120])
        };
        let probe = crate::probe::probe(dev)?;
        // The probe already refuses a dirty volume; checking the flag here too
        // means a driver change cannot quietly outvote it.
        let refusal = probe
            .write_block
            .clone()
            .or_else(|| needs_recovery.then(|| "ext journal needs recovery".to_string()));
        let rw = rw && refusal.is_none() && dev.writable();
        Ok(Self {
            dev,
            block_size,
            inodes_per_group,
            inode_size,
            first_data_block: le32(&sb, 20),
            desc_size,
            groups,
            kind: probe.kind,
            label: probe.label,
            rw,
            refusal,
            csum,
            csum_seed,
            blocks_per_group: u64::from(le32(&sb, 32)),
            total_blocks: u64::from(le32(&sb, 4)),
            has_extents: incompat & INCOMPAT_EXTENTS != 0,
            has_filetype: incompat & INCOMPAT_FILETYPE != 0,
        })
    }

    /// Recompute and store an inode's `metadata_csum`.
    ///
    /// `ext4_inode_csum`: chain the fs seed with the inode number and the inode's
    /// `i_generation`, then the whole record with the two checksum fields zeroed.
    /// `i_checksum_hi` only exists when `i_extra_isize` reaches it.
    fn write_inode_csum(&mut self, ino: u32) -> Result<()> {
        if !self.csum {
            return Ok(());
        }
        let at = self.inode_off(ino)?;
        let size = self.inode_size as usize;
        let mut raw = read_vec(self.dev, at, size)?;
        let generation = le32(&raw, 100);
        let extra = if size > 128 { le16(&raw, 128) } else { 0 };
        let has_hi = size > 128 && usize::from(extra) >= 4;
        // The fields being computed must read as zero while computing them.
        raw[0x7C..0x7E].fill(0);
        if has_hi {
            raw[0x82..0x84].fill(0);
        }
        let mut crc = crc32c(self.csum_seed, &ino.to_le_bytes());
        crc = crc32c(crc, &generation.to_le_bytes());
        crc = crc32c(crc, &raw);
        self.dev.write_at(at + 0x7C, &(crc as u16).to_le_bytes())?;
        if has_hi {
            self.dev
                .write_at(at + 0x82, &((crc >> 16) as u16).to_le_bytes())?;
        }
        self.refresh_group_after_inode_change(ino)
    }

    /// The inode-table checksum covers the record just written: refresh it in
    /// the group descriptor after every inode change.
    fn refresh_group_after_inode_change(&mut self, ino: u32) -> Result<()> {
        if !self.csum || self.desc_size < 64 {
            return Ok(());
        }
        let group = (ino - 1) / self.inodes_per_group;
        let mut gd = self.gd(group)?;
        self.itable_csum(group, &mut gd)?;
        self.write_gd(group, &mut gd)
    }

    /// Why a write mount was refused (a dirty journal, a read-only device).
    pub fn refusal(&self) -> Option<&str> {
        self.refusal.as_deref()
    }

    fn block_off(&self, block: u64) -> u64 {
        block * self.block_size
    }

    /// Byte offset of inode `ino`'s record.
    fn inode_off(&mut self, ino: u32) -> Result<u64> {
        if ino == 0 {
            return Err(Error::Corrupt("ext: inode 0"));
        }
        let group = (ino - 1) / self.inodes_per_group;
        if group >= self.groups {
            return Err(Error::Corrupt("ext: inode past the last group"));
        }
        let index = u64::from((ino - 1) % self.inodes_per_group);
        // Descriptors start in the block after the superblock's block.
        let gd_block = if self.block_size == 1024 {
            2
        } else {
            u64::from(self.first_data_block) + 1
        };
        let gd_at = self.block_off(gd_block) + u64::from(group) * self.desc_size;
        let gd = read_vec(self.dev, gd_at, self.desc_size as usize)?;
        let mut table = u64::from(le32(&gd, 8));
        if self.desc_size >= 64 {
            table |= u64::from(le32(&gd, 40)) << 32;
        }
        Ok(self.block_off(table) + index * self.inode_size)
    }

    fn inode(&mut self, ino: u32) -> Result<Inode> {
        let at = self.inode_off(ino)?;
        let raw = read_vec(self.dev, at, 128)?;
        let mut block = [0u8; 60];
        block.copy_from_slice(&raw[40..100]);
        let size = u64::from(le32(&raw, 4)) | (u64::from(le32(&raw, 108)) << 32);
        Ok(Inode {
            mode: le16(&raw, 0),
            size,
            flags: le32(&raw, 32),
            block,
        })
    }

    /// The file's **logical → physical** block map.
    ///
    /// Logical numbers matter: a sparse file (one with holes) has fewer mapped
    /// blocks than its size covers, and an extent carries the logical block it
    /// starts at (`ee_block`). A mapper that returned physical blocks in order
    /// would read a hole by shifting every later block into it — the file would
    /// come back rearranged rather than merely missing a range. `ee_block` is what
    /// prevents that, so it is carried here instead of being dropped.
    fn blocks_of(&mut self, ino: &Inode) -> Result<Vec<(u64, u64)>> {
        if ino.flags & INLINE_DATA_FL != 0 {
            return Err(Error::Unsupported(
                "ext4 inline_data: the file body is inside the inode (not implemented)".into(),
            ));
        }
        if ino.flags & EXTENTS_FL != 0 {
            let mut out = Vec::new();
            self.walk_extents(ino.block.as_ref(), &mut out, 0)?;
            out.sort_by_key(|(logical, _)| *logical);
            Ok(out)
        } else {
            self.walk_indirect(ino)
        }
    }

    /// How many logical blocks a file of `size` covers, and how many are mapped.
    /// A difference means holes.
    fn hole_check(&mut self, ino: &Inode) -> Result<(u64, u64)> {
        let covered = ino.size.div_ceil(self.block_size);
        let mapped = self.blocks_of(ino)?.len() as u64;
        Ok((covered, mapped))
    }

    fn walk_extents(
        &mut self,
        node: &[u8],
        out: &mut Vec<(u64, u64)>,
        depth_guard: u32,
    ) -> Result<()> {
        if depth_guard > 8 {
            return Err(Error::Corrupt("ext4: extent tree too deep"));
        }
        if node.len() < 12 || le16(node, 0) != EXTENT_MAGIC {
            return Err(Error::Corrupt("ext4: extent header magic"));
        }
        let entries = le16(node, 2) as usize;
        let depth = le16(node, 6);
        for i in 0..entries {
            let at = 12 + i * 12;
            if at + 12 > node.len() {
                return Err(Error::Corrupt("ext4: extent entry past the node"));
            }
            let e = &node[at..at + 12];
            if depth == 0 {
                // Leaf: ee_block (the *logical* start), ee_len, ee_start_hi/lo.
                let logical = u64::from(le32(e, 0));
                let len = le16(e, 4);
                // A length above 32768 marks an uninitialized extent: allocated
                // but never written, so it reads as zeros. It is mapped — but it
                // must not be *written* in place, because the OS still has to
                // convert it, so it is left out of the map entirely.
                if len > 32768 {
                    continue;
                }
                let start = (u64::from(le16(e, 6)) << 32) | u64::from(le32(e, 8));
                for b in 0..u64::from(len) {
                    out.push((logical + b, start + b));
                }
            } else {
                let child = (u64::from(le16(e, 8)) << 32) | u64::from(le32(e, 4));
                let at = self.block_off(child);
                let bs = self.block_size as usize;
                let buf = read_vec(self.dev, at, bs)?;
                self.walk_extents(&buf, out, depth_guard + 1)?;
            }
        }
        Ok(())
    }

    /// One level of the classic indirect-block chain. `deeper` walks the blocks
    /// it points at as pointer blocks in turn (the double-indirect case).
    ///
    /// `first_logical` is the logical block the level starts at, so a zero pointer
    /// (a hole) leaves a gap in the map instead of shifting what follows it.
    fn indirect_level(
        &mut self,
        block: u64,
        deeper: bool,
        first_logical: u64,
        out: &mut Vec<(u64, u64)>,
    ) -> Result<()> {
        if block == 0 {
            return Ok(());
        }
        let per = self.block_size / 4;
        let at = self.block_off(block);
        let bs = self.block_size as usize;
        let buf = read_vec(self.dev, at, bs)?;
        for i in 0..per as usize {
            let b = u64::from(le32(&buf, i * 4));
            if b == 0 {
                continue;
            }
            if deeper {
                let inner_at = self.block_off(b);
                let inner = read_vec(self.dev, inner_at, bs)?;
                let base = first_logical + i as u64 * per;
                for j in 0..per as usize {
                    let bb = u64::from(le32(&inner, j * 4));
                    if bb != 0 {
                        out.push((base + j as u64, bb));
                    }
                }
            } else {
                out.push((first_logical + i as u64, b));
            }
        }
        Ok(())
    }

    fn walk_indirect(&mut self, ino: &Inode) -> Result<Vec<(u64, u64)>> {
        let mut out = Vec::new();
        for i in 0..12u64 {
            let b = u64::from(le32(&ino.block, i as usize * 4));
            if b != 0 {
                out.push((i, b));
            }
        }
        let per = self.block_size / 4;
        let single = u64::from(le32(&ino.block, 48));
        let double = u64::from(le32(&ino.block, 52));
        // Logical layout: 0..12 direct, then `per` single-indirect, then
        // `per*per` double-indirect.
        self.indirect_level(single, false, 12, &mut out)?;
        self.indirect_level(double, true, 12 + per, &mut out)?;
        // Triple-indirect means a file above ~4 GiB with 1 KiB blocks. A BIOS
        // repair shell does not need it, and pretending would truncate silently.
        if le32(&ino.block, 56) != 0 {
            return Err(Error::Unsupported(
                "ext: triple-indirect blocks (file too large for this driver)".into(),
            ));
        }
        Ok(out)
    }

    /// Read up to `limit` bytes, placing each mapped block at its **logical**
    /// offset. Unmapped ranges stay zero — that is what a hole *is*. Concatenating
    /// mapped blocks instead would hand back a sparse file rearranged rather than
    /// merely missing a range, which is the worse failure of the two.
    fn read_inode_data(&mut self, ino: &Inode, limit: u64) -> Result<Vec<u8>> {
        let blocks = self.blocks_of(ino)?;
        let len = usize::try_from(limit).map_err(|_| Error::OutOfRange)?;
        let mut out = vec![0u8; len];
        let bs = self.block_size;
        for (logical, physical) in blocks {
            let at = logical * bs;
            if at >= limit {
                continue;
            }
            let want = (limit - at).min(bs) as usize;
            let from = self.block_off(physical);
            let bytes = read_vec(self.dev, from, want)?;
            let start = at as usize;
            out[start..start + want].copy_from_slice(&bytes);
        }
        Ok(out)
    }

    fn dir_entries(&mut self, ino: &Inode) -> Result<Vec<(String, u32, u8)>> {
        if !ino.is_dir() {
            return Err(Error::NotADir("inode".into()));
        }
        let data = self.read_inode_data(ino, ino.size)?;
        let mut out = Vec::new();
        let mut at = 0usize;
        while at + 8 <= data.len() {
            let inode = le32(&data, at);
            let rec_len = le16(&data, at + 4) as usize;
            let name_len = data[at + 6] as usize;
            let file_type = data[at + 7];
            if rec_len < 8 || at + rec_len > data.len() {
                break;
            }
            if inode != 0 && name_len > 0 && at + 8 + name_len <= data.len() {
                let name = String::from_utf8_lossy(&data[at + 8..at + 8 + name_len]).to_string();
                if name != "." && name != ".." {
                    out.push((name, inode, file_type));
                }
            }
            at += rec_len;
        }
        Ok(out)
    }

    /// Resolve a path to `(inode number, inode)`.
    fn resolve(&mut self, path: &str) -> Result<(u32, Inode)> {
        let mut ino_no = ROOT_INO;
        let mut ino = self.inode(ROOT_INO)?;
        for part in crate::split_path(path) {
            if !ino.is_dir() {
                return Err(Error::NotADir(part));
            }
            let ents = self.dir_entries(&ino)?;
            let hit = ents
                .into_iter()
                .find(|(n, _, _)| *n == part)
                .ok_or_else(|| Error::NotFoundPath(path.to_string()))?;
            ino_no = hit.1;
            ino = self.inode(ino_no)?;
        }
        Ok((ino_no, ino))
    }

    // --- allocation: group descriptors, bitmaps, and their checksums ----------
    //
    // ext4 keeps free-space truth in two places — the per-group bitmaps (with
    // `bg_free_*` counts) and the superblock totals — and under `metadata_csum`
    // every one of those structures carries its own checksum *plus* the group
    // descriptor's `bg_checksum` over all of it. A write that updates a bitmap
    // but not the descriptor is an `e2fsck` error even when the allocation is
    // right. So the helpers below write a group descriptor only through
    // `gd_write`, which re-seals `bg_checksum` last, and each bitmap write is
    // followed by its own csum field inside the same descriptor update.

    /// Byte offset of group `group`'s descriptor.
    fn gd_at(&self, group: u32) -> u64 {
        let gd_block = if self.block_size == 1024 {
            2
        } else {
            u64::from(self.first_data_block) + 1
        };
        self.block_off(gd_block) + u64::from(group) * self.desc_size
    }

    fn gd(&mut self, group: u32) -> Result<Vec<u8>> {
        let at = self.gd_at(group);
        read_vec(self.dev, at, self.desc_size as usize)
    }

    /// Write a group descriptor back, re-sealing `bg_checksum` first when
    /// `metadata_csum` is on. `bg_checksum` is crc32c over the descriptor with
    /// its own field zeroed — `ext4_group_desc_csum` — chained from the fs seed
    /// and the group number.
    fn write_gd(&mut self, group: u32, gd: &mut [u8]) -> Result<()> {
        if self.csum {
            let n = (self.desc_size as usize).min(64).min(gd.len());
            gd[0x1E..0x20].fill(0);
            let mut c = crc32c(self.csum_seed, &group.to_le_bytes());
            c = crc32c(c, &gd[..n]);
            gd[0x1E..0x20].copy_from_slice(&(c as u16).to_le_bytes());
        }
        self.dev.write_at(self.gd_at(group), gd)
    }

    /// `(bg_block_bitmap, bg_inode_bitmap, bg_inode_table)` as absolute blocks.
    fn gd_triple(&self, gd: &[u8]) -> (u64, u64, u64) {
        let mut out = (
            u64::from(le32(gd, 0)),
            u64::from(le32(gd, 4)),
            u64::from(le32(gd, 8)),
        );
        if self.desc_size >= 64 {
            out.0 |= u64::from(le32(gd, 0x20)) << 32;
            out.1 |= u64::from(le32(gd, 0x24)) << 32;
            out.2 |= u64::from(le32(gd, 0x28)) << 32;
        }
        out
    }

    /// `bg_free_blocks_count` / `bg_free_inodes_count` / `bg_used_dirs_count`
    /// (lo + hi halves).
    fn gd_counts(&self, gd: &[u8], which: usize) -> u64 {
        let lo = u64::from(le16(gd, which));
        let hi = if self.desc_size >= 64 {
            u64::from(le16(gd, which + 0x20))
        } else {
            0
        };
        lo | (hi << 16)
    }

    fn gd_set_count(&self, gd: &mut [u8], which: usize, v: u64) {
        gd[which..which + 2].copy_from_slice(&(v as u16).to_le_bytes());
        if self.desc_size >= 64 {
            gd[which + 0x20..which + 0x22].copy_from_slice(&((v >> 16) as u16).to_le_bytes());
        }
    }

    /// The superblock's `s_free_blocks_count` / `s_free_inodes_count` — low word
    /// only; the hi word is for filesystems above 4 Gi-blocks, and a borrow from
    /// it never happens on a volume this size. Under `metadata_csum` the
    /// superblock itself carries `s_checksum` at 0x3FC, crc32c(seed, sb[..1020])
    /// — re-sealed after every counter write.
    fn sb_free(&mut self, off: u64, delta: i64) -> Result<()> {
        let at = 1024 + off;
        let cur = u64::from(le32(&read_vec(self.dev, at, 4)?, 0));
        let new = (cur as i64 + delta) as u64;
        self.dev.write_at(at, &(new as u32).to_le_bytes())?;
        if self.csum {
            // The superblock checksum chains from ~0, not from the UUID-derived
            // metadata seed. Kernel: ext4_superblock_csum = ext4_chksum(~0, es,
            // offsetof(s_checksum)) = 1020 bytes with the csum field zeroed.
            let sb = read_vec(self.dev, 1024, 1020)?;
            let c = crc32c(!0u32, &sb);
            self.dev.write_at(1024 + 1020, &c.to_le_bytes())?;
        }
        Ok(())
    }

    /// Recompute a bitmap's checksum field inside its (already loaded) group
    /// descriptor — `ext4_block_bitmap_csum` / `ext4_inode_bitmap_csum`: the
    /// fs seed, then the bitmap bytes. `ext4_chksum(s_csum_seed, bh->b_data, sz)`
    /// where `sz` is `per_group/8` capped to one block.
    fn bitmap_csum(&mut self, group: u32, gd: &mut [u8], inode_bitmap: bool) -> Result<()> {
        let _ = group;
        if !self.csum {
            return Ok(());
        }
        let (bb, ib, _) = self.gd_triple(gd);
        let bs = self.block_size as usize;
        let (blk, len) = if inode_bitmap {
            let l = ((self.inodes_per_group / 8) as usize).min(bs);
            (ib, l)
        } else {
            let l = ((self.blocks_per_group / 8) as usize).min(bs);
            (bb, l)
        };
        let off = self.block_off(blk);
        let map = read_vec(self.dev, off, len)?;
        let c = crc32c(self.csum_seed, &map);
        let (lo_at, hi_at) = if inode_bitmap {
            (0x1A, 0x3A)
        } else {
            (0x18, 0x38)
        };
        gd[lo_at..lo_at + 2].copy_from_slice(&(c as u16).to_le_bytes());
        if self.desc_size >= 64 {
            gd[hi_at..hi_at + 2].copy_from_slice(&((c >> 16) as u16).to_le_bytes());
        }
        Ok(())
    }

    /// The 64-byte `ext4_group_desc` ends at 0x3C with `bg_reserved`; it does
    /// not contain an inode-table checksum field, so nothing to update here.
    /// The inode table changes are covered by the per-inode `i_checksum`
    /// instead. Keep the seam if a future descriptor size exposes it.
    fn itable_csum(&mut self, _group: u32, _gd: &mut [u8]) -> Result<()> {
        Ok(())
    }

    /// How many real blocks group `group` actually has — the last group is
    /// usually short.
    fn blocks_in_group(&self, group: u32) -> u64 {
        let start = u64::from(group) * self.blocks_per_group + u64::from(self.first_data_block);
        self.total_blocks.saturating_sub(start)
    }

    /// Allocate one zeroed data block, preferring `hint` group's bitmap and
    /// falling back across the groups. Updates the bitmap, both free counts,
    /// and every checksum that covers them.
    fn alloc_block(&mut self, hint: u32) -> Result<u64> {
        for off in 0..self.groups {
            let group = (hint + off) % self.groups;
            let mut gd = self.gd(group)?;
            if self.gd_counts(&gd, 0x0C) == 0 {
                continue;
            }
            let (bb, _, _) = self.gd_triple(&gd);
            let map_at = self.block_off(bb);
            let mut map = read_vec(self.dev, map_at, self.block_size as usize)?;
            let n = self.blocks_in_group(group);
            for bit in 0..n {
                let (byte, mask) = ((bit / 8) as usize, 1u8 << (bit % 8));
                if map[byte] & mask == 0 {
                    map[byte] |= mask;
                    self.dev.write_at(map_at, &map)?;
                    let free = self.gd_counts(&gd, 0x0C) - 1;
                    self.gd_set_count(&mut gd, 0x0C, free);
                    self.bitmap_csum(group, &mut gd, false)?;
                    self.write_gd(group, &mut gd)?;
                    self.sb_free(12, -1)?;
                    let block = u64::from(group) * self.blocks_per_group
                        + u64::from(self.first_data_block)
                        + bit;
                    self.dev
                        .write_at(self.block_off(block), &vec![0u8; self.block_size as usize])?;
                    return Ok(block);
                }
            }
        }
        Err(Error::Unsupported(
            "ext: no free blocks — the volume is full".into(),
        ))
    }

    /// Allocate an inode: set its bitmap bit, update the group counters and
    /// `itable_unused`, zero + write the fresh record, and re-seal every csum.
    /// Returns the inode number.
    fn alloc_inode(&mut self, dir: bool, hint: u32) -> Result<u32> {
        for off in 0..self.groups {
            let group = (hint + off) % self.groups;
            let mut gd = self.gd(group)?;
            if self.gd_counts(&gd, 0x0E) == 0 {
                continue;
            }
            let (_, ib, it) = self.gd_triple(&gd);
            let map_at = self.block_off(ib);
            let mut map = read_vec(self.dev, map_at, self.block_size as usize)?;
            let mut picked = None;
            for bit in 0..self.inodes_per_group {
                let (byte, mask) = ((bit / 8) as usize, 1u8 << (bit % 8));
                if map[byte] & mask == 0 {
                    map[byte] |= mask;
                    picked = Some(bit);
                    break;
                }
            }
            let Some(bit) = picked else { continue };
            self.dev.write_at(map_at, &map)?;
            let free = self.gd_counts(&gd, 0x0E) - 1;
            self.gd_set_count(&mut gd, 0x0E, free);
            if dir {
                let used = self.gd_counts(&gd, 0x10) + 1;
                self.gd_set_count(&mut gd, 0x10, used);
            }
            // `bg_itable_unused` counts inodes past the highest allocated index;
            // allocating anywhere below it leaves it unchanged.
            let unused = self.gd_counts(&gd, 0x1C);
            let highest = u64::from(self.inodes_per_group) - unused - 1;
            if u64::from(bit) > highest {
                let new_unused = u64::from(self.inodes_per_group) - u64::from(bit) - 1;
                self.gd_set_count(&mut gd, 0x1C, new_unused);
            }
            self.bitmap_csum(group, &mut gd, true)?;
            // The record itself: zeroed, then the fields this driver sets.
            let ino = group * self.inodes_per_group + bit + 1;
            let rec_at = self.block_off(it) + u64::from(bit) * self.inode_size;
            let rec = vec![0u8; self.inode_size as usize];
            self.dev.write_at(rec_at, &rec)?;
            self.itable_csum(group, &mut gd)?;
            self.write_gd(group, &mut gd)?;
            self.sb_free(16, -1)?;
            return Ok(ino);
        }
        Err(Error::Unsupported(
            "ext: no free inodes — the volume cannot take a new file".into(),
        ))
    }

    /// Initialize a freshly allocated inode's record: mode, flags, the empty
    /// extent tree (or clean direct blocks), links, a generation, then the csum.
    /// `i_blocks` stays 0 — `grow` accounts for what it allocates.
    fn init_inode(&mut self, ino: u32, mode: u16) -> Result<()> {
        let at = self.inode_off(ino)?;
        let mut rec = vec![0u8; self.inode_size as usize];
        rec[0..2].copy_from_slice(&mode.to_le_bytes());
        rec[26..28].copy_from_slice(&1u16.to_le_bytes()); // i_links_count
        if self.has_extents {
            rec[32..36].copy_from_slice(&EXTENTS_FL.to_le_bytes());
            // i_block: an empty extent root — {magic, 0 entries, max 4, depth 0}.
            rec[40..42].copy_from_slice(&EXTENT_MAGIC.to_le_bytes());
            rec[44..46].copy_from_slice(&4u16.to_le_bytes());
        }
        // A deterministic generation is as good as a random one here — it feeds
        // the inode checksum chain, nothing more.
        rec[100..104].copy_from_slice(&ino.to_le_bytes());
        if self.inode_size > 128 {
            rec[128..130].copy_from_slice(&32u16.to_le_bytes()); // i_extra_isize
        }
        self.dev.write_at(at, &rec)?;
        self.write_inode_csum(ino)
    }

    /// Add `len` blocks at logical `logical`, physical `phys`, to an inode's
    /// block map. Extent-mapped inodes merge into a contiguous last extent or
    /// append a new one — the 60-byte `i_block` root holds four, and a full
    /// root is a split the OS owns. Classic inodes take free direct slots.
    fn map_grow(
        &mut self,
        ino_no: u32,
        ino: &Inode,
        logical: u64,
        phys: u64,
        len: u16,
    ) -> Result<()> {
        if ino.flags & EXTENTS_FL != 0 {
            // Read i_block from the device: `grow_blocks` may call us several
            // times and the borrowed `Inode` carries the tree as it was at the
            // start of the write, not after the last append.
            let at = self.inode_off(ino_no)? + 40;
            let mut blk = read_vec(self.dev, at, 60)?;
            if blk.len() < 60 {
                blk.resize(60, 0);
            }
            if le16(&blk, 0) != EXTENT_MAGIC || le16(&blk, 6) != 0 {
                return Err(Error::Unsupported(
                    "ext4: the extent tree is deeper than its root — growing it needs the OS"
                        .into(),
                ));
            }
            let entries = le16(&blk, 2);
            if entries > 0 {
                let i = usize::from(entries - 1);
                let e = &mut blk[12 + i * 12..12 + i * 12 + 12];
                let e_len = le16(e, 4);
                let e_start = (u64::from(le16(e, 6)) << 32) | u64::from(le32(e, 8));
                let e_block = le32(e, 0);
                if u64::from(e_block) + u64::from(e_len) == logical
                    && e_start + u64::from(e_len) == phys
                    && e_len.saturating_add(len) <= EXTENT_MAX_LEN
                {
                    e[4..6].copy_from_slice(&(e_len + len).to_le_bytes());
                    let at = self.inode_off(ino_no)?;
                    self.dev.write_at(at + 40, &blk)?;
                    return self.write_inode_csum(ino_no);
                }
            }
            if entries >= 4 {
                return Err(Error::Unsupported(
                    "ext4: the inode's 4-slot extent root is full and a split is the OS's job"
                        .into(),
                ));
            }
            let e = &mut blk[12 + usize::from(entries) * 12..12 + usize::from(entries) * 12 + 12];
            e[0..4].copy_from_slice(&(logical as u32).to_le_bytes());
            e[4..6].copy_from_slice(&len.to_le_bytes());
            e[6..8].copy_from_slice(&((phys >> 32) as u16).to_le_bytes());
            e[8..12].copy_from_slice(&(phys as u32).to_le_bytes());
            blk[2..4].copy_from_slice(&(entries + 1).to_le_bytes());
            let at = self.inode_off(ino_no)?;
            self.dev.write_at(at + 40, &blk)?;
            self.write_inode_csum(ino_no)
        } else {
            // Classic direct blocks: a free i_block slot takes one new block.
            if logical >= 12 {
                return Err(Error::Unsupported(
                    "ext: growing past the 12 direct blocks needs indirect blocks — the OS's job"
                        .into(),
                ));
            }
            let at = self.inode_off(ino_no)?;
            self.dev
                .write_at(at + 40 + logical * 4, &(phys as u32).to_le_bytes())?;
            self.write_inode_csum(ino_no)
        }
    }

    /// Release one allocated block — clear its bitmap bit, restore the counts,
    /// re-seal the checksums. Used when an allocation run overshot.
    fn free_block(&mut self, block: u64) -> Result<()> {
        let group = ((block - u64::from(self.first_data_block)) / self.blocks_per_group) as u32;
        let bit =
            block - u64::from(self.first_data_block) - u64::from(group) * self.blocks_per_group;
        let mut gd = self.gd(group)?;
        let (bb, _, _) = self.gd_triple(&gd);
        let map_at = self.block_off(bb);
        let mut map = read_vec(self.dev, map_at, self.block_size as usize)?;
        map[(bit / 8) as usize] &= !(1u8 << (bit % 8));
        self.dev.write_at(map_at, &map)?;
        let free = self.gd_counts(&gd, 0x0C) + 1;
        self.gd_set_count(&mut gd, 0x0C, free);
        self.bitmap_csum(group, &mut gd, false)?;
        self.write_gd(group, &mut gd)?;
        self.sb_free(12, 1)
    }

    /// Allocate `n` fresh blocks and append them to the inode's map starting at
    /// logical `at_logical`. Blocks are taken from the inode's own group first,
    /// which is how a real allocator keeps a file contiguous — and contiguous
    /// allocation is what lets `map_grow` merge rather than burn extent slots.
    /// A non-adjacent allocation ends the current run and starts the next one,
    /// so extents always append in logical order.
    fn grow_blocks(
        &mut self,
        ino_no: u32,
        ino: &Inode,
        at_logical: u64,
        n: u64,
    ) -> Result<Vec<(u64, u64)>> {
        let group = (ino_no - 1) / self.inodes_per_group;
        let mut new = Vec::new();
        let mut got = 0u64;
        let mut pending: Option<u64> = None;
        while got < n {
            let want = (n - got).min(u64::from(EXTENT_MAX_LEN)) as u16;
            let first = match pending.take() {
                Some(b) => b,
                None => self.alloc_block(group)?,
            };
            let mut run = 1u16;
            while run < want {
                match self.alloc_block(group) {
                    Ok(b) if b == first + u64::from(run) => run += 1,
                    // A non-adjacent block begins the next run — keep it, do
                    // not leak it.
                    Ok(b) => {
                        pending = Some(b);
                        break;
                    }
                    Err(e) => {
                        if run == 0 {
                            return Err(e);
                        }
                        break;
                    }
                }
            }
            self.map_grow(ino_no, ino, at_logical + got, first, run)?;
            for i in 0..u64::from(run) {
                new.push((at_logical + got + i, first + i));
            }
            got += u64::from(run);
        }
        // An extra block carried past the need is given back, not leaked.
        if let Some(b) = pending {
            self.free_block(b)?;
        }
        Ok(new)
    }

    // --- directory entry insertion --------------------------------------------
    //
    // An ext4 dirent's `rec_len` is what it *occupies*; its live size is
    // `8 + align4(name_len)`. Inserting splits the last entry's tail space:
    // the existing entry shrinks to its live size and the new entry owns the
    // remainder up to the block end — minus the 12-byte checksum tail a
    // `metadata_csum` directory carries.

    /// Write a directory's data block, maintaining its `ext4_dirblock_csum`
    /// tail when the filesystem checksums metadata. The tail is a 12-byte fake
    /// dirent `{inode:0, rec_len:12, name_len:0, ft:0xDE}` at the block end;
    /// its 4-byte `reserved` area holds the checksum. The csum seed for the
    /// block is the filesystem `s_csum_seed` chained with the directory's inode
    /// number and generation, and the checksum covers the block *before* the
    /// tail (the tail itself is not included; the csum field is zeroed while
    /// computing).
    fn dir_block_write(&mut self, dir_ino: u32, block: u64, data: &mut [u8]) -> Result<()> {
        if self.csum {
            let bs = self.block_size as usize;
            let tail = bs - 12;
            let at = self.inode_off(dir_ino)?;
            let raw = read_vec(self.dev, at, 128)?;
            let gen = le32(&raw, 100);
            data[tail..tail + 4].copy_from_slice(&0u32.to_le_bytes());
            data[tail + 4..tail + 6].copy_from_slice(&12u16.to_le_bytes());
            data[tail + 6] = 0;
            data[tail + 7] = DIR_CSUM_FT;
            let mut c = crc32c(self.csum_seed, &dir_ino.to_le_bytes());
            c = crc32c(c, &gen.to_le_bytes());
            data[tail + 8..tail + 12].fill(0);
            c = crc32c(c, &data[..tail]);
            data[tail + 8..tail + 12].copy_from_slice(&c.to_le_bytes());
        }
        self.dev.write_at(self.block_off(block), data)
    }

    /// Does a dir block already carry the checksum tail?
    fn dir_has_tail(&self, block: &[u8]) -> bool {
        let tail = self.block_size as usize - 12;
        le32(block, tail) == 0
            && le16(block, tail + 4) == 12
            && block[tail + 6] == 0
            && block[tail + 7] == DIR_CSUM_FT
    }

    /// Insert `{name → child}` into directory `dir`. Splits tail space in an
    /// existing block when it can; otherwise allocates the directory a new
    /// block. Refuses a `dir_index` (hashed) directory: its hash tree would
    /// need the same insert and that is the OS's machinery.
    fn dir_add(
        &mut self,
        dir_no: u32,
        dir: &Inode,
        name: &str,
        child: u32,
        ftype: u8,
    ) -> Result<()> {
        if dir.flags & INDEX_FL != 0 {
            return Err(Error::Unsupported(
                "ext4: hashed directory (dir_index) — adding an entry needs the hash tree, the OS's job".into(),
            ));
        }
        let name_len = name.len();
        if name_len == 0 || name_len > 255 {
            return Err(Error::Unsupported(
                "ext: a directory entry name must be 1..255 bytes".into(),
            ));
        }
        let need = (8 + name_len + 3) & !3;
        let bs = self.block_size as usize;
        let tail_rsv = if self.csum { 12 } else { 0 };
        let blocks = self.blocks_of(dir)?;
        for (_logical, phys) in &blocks {
            let at = self.block_off(*phys);
            let mut blk = read_vec(self.dev, at, bs)?;
            let has_tail = self.csum && self.dir_has_tail(&blk);
            // Scanning ends where the last entry's rec_len ends — the tail is
            // inside it when present. Writing always reserves the tail's 12
            // bytes under metadata_csum, whether the block carried one or not.
            let scan_limit = bs - if has_tail { 12 } else { 0 };
            let write_limit = bs - tail_rsv;
            let mut off = 0usize;
            while off + 8 <= scan_limit {
                let rec_len = le16(&blk, off + 4) as usize;
                let name_l = blk[off + 6] as usize;
                if rec_len < 8 || off + rec_len > scan_limit {
                    break;
                }
                let live = (8 + name_l + 3) & !3;
                // Space this entry could yield. When the block has no tail yet,
                // making room for one costs 12 more bytes of that same slack.
                let avail = rec_len - live;
                let wants = need + if !has_tail && self.csum { 12 } else { 0 };
                if off + rec_len == scan_limit && avail >= wants {
                    // Shrink the tail entry, insert ours right after it.
                    blk[off + 4..off + 6].copy_from_slice(&(live as u16).to_le_bytes());
                    let n_off = off + live;
                    let n_rec = write_limit - n_off;
                    blk[n_off..n_off + 4].copy_from_slice(&child.to_le_bytes());
                    blk[n_off + 4..n_off + 6].copy_from_slice(&(n_rec as u16).to_le_bytes());
                    blk[n_off + 6] = name_len as u8;
                    blk[n_off + 7] = ftype;
                    blk[n_off + 8..n_off + 8 + name_len].copy_from_slice(name.as_bytes());
                    self.dir_block_write(dir_no, *phys, &mut blk)?;
                    return Ok(());
                }
                off += rec_len;
            }
        }
        // No block had room: allocate the directory a fresh block and put the
        // entry there as the block's only record (spanning to the tail).
        let group = (dir_no - 1) / self.inodes_per_group;
        let phys = self.alloc_block(group)?;
        self.map_grow(dir_no, dir, dir.size.div_ceil(self.block_size), phys, 1)?;
        let mut blk = vec![0u8; bs];
        let n_rec = bs - tail_rsv;
        blk[0..4].copy_from_slice(&child.to_le_bytes());
        blk[4..6].copy_from_slice(&(n_rec as u16).to_le_bytes());
        blk[6] = name_len as u8;
        blk[7] = ftype;
        blk[8..8 + name_len].copy_from_slice(name.as_bytes());
        self.dir_block_write(dir_no, phys, &mut blk)?;
        // The directory grew: i_size by one block, i_blocks by its 512-byte
        // sectors — then the checksum, like every inode write.
        let at = self.inode_off(dir_no)?;
        let size = dir.size + self.block_size;
        self.dev.write_at(at + 4, &(size as u32).to_le_bytes())?;
        let cur = le32(&read_vec(self.dev, at + 28, 4)?, 0);
        self.dev.write_at(
            at + 28,
            &(cur + (self.block_size / 512) as u32).to_le_bytes(),
        )?;
        self.write_inode_csum(dir_no)
    }

    /// Create `{dir}/{name}` as an empty regular file or directory and return
    /// its inode number.
    fn create_child(
        &mut self,
        dir_no: u32,
        dir: &Inode,
        name: &str,
        make_dir: bool,
    ) -> Result<u32> {
        let group = (dir_no - 1) / self.inodes_per_group;
        let child = self.alloc_inode(make_dir, group)?;
        if make_dir {
            self.init_inode(child, S_IFDIR | 0o755)?;
            // The directory data block: `.` `..` and the csum tail.
            let phys = self.alloc_block(group)?;
            let mut blk = vec![0u8; self.block_size as usize];
            let limit = self.block_size as usize - if self.csum { 12 } else { 0 };
            let put = |blk: &mut [u8], off: usize, ino: u32, rec: usize, ty: u8, nm: &[u8]| {
                blk[off..off + 4].copy_from_slice(&ino.to_le_bytes());
                blk[off + 4..off + 6].copy_from_slice(&(rec as u16).to_le_bytes());
                blk[off + 6] = nm.len() as u8;
                blk[off + 7] = ty;
                blk[off + 8..off + 8 + nm.len()].copy_from_slice(nm);
            };
            put(&mut blk, 0, child, 12, 2, b".");
            put(&mut blk, 12, dir_no, limit - 12, 2, b"..");
            self.dir_block_write(child, phys, &mut blk)?;
            // links: 2 (`/` and parent's entry count comes through dir_add).
            let at = self.inode_off(child)?;
            self.dev.write_at(at + 26, &2u16.to_le_bytes())?;
            // i_size = one block, i_blocks, the first extent.
            self.dev
                .write_at(at + 4, &(self.block_size as u32).to_le_bytes())?;
            self.dev
                .write_at(at + 28, &((self.block_size / 512) as u32).to_le_bytes())?;
            if self.has_extents {
                self.dev.write_at(at + 32, &EXTENTS_FL.to_le_bytes())?;
                let mut blk = [0u8; 60];
                blk[0..2].copy_from_slice(&EXTENT_MAGIC.to_le_bytes());
                blk[2..4].copy_from_slice(&1u16.to_le_bytes());
                blk[4..6].copy_from_slice(&4u16.to_le_bytes());
                blk[12 + 4..12 + 6].copy_from_slice(&1u16.to_le_bytes());
                blk[12 + 8..12 + 12].copy_from_slice(&(phys as u32).to_le_bytes());
                self.dev.write_at(at + 40, &blk)?;
            } else {
                self.dev.write_at(at + 40, &(phys as u32).to_le_bytes())?;
            }
            self.write_inode_csum(child)?;
            self.refresh_group_after_inode_change(child)?;
        } else {
            self.init_inode(child, S_IFREG | 0o644)?;
        }
        let ftype = if self.has_filetype {
            if make_dir {
                2
            } else {
                1
            }
        } else {
            0
        };
        self.dir_add(dir_no, dir, name, child, ftype)?;
        if make_dir {
            // The parent's `..` back-link: links_count goes up by one.
            let at = self.inode_off(dir_no)?;
            let links = u16::from_le_bytes({
                let r = read_vec(self.dev, at + 26, 2)?;
                [r[0], r[1]]
            });
            self.dev.write_at(at + 26, &(links + 1).to_le_bytes())?;
            self.write_inode_csum(dir_no)?;
        }
        Ok(child)
    }
}

impl FileSystem for Ext4<'_> {
    fn kind(&self) -> FsKind {
        self.kind
    }

    fn label(&self) -> String {
        self.label.clone()
    }

    fn writable(&self) -> bool {
        self.rw
    }

    fn list(&mut self, path: &str) -> Result<Vec<DirEnt>> {
        let (_, ino) = self.resolve(path)?;
        if !ino.is_dir() {
            return Err(Error::NotADir(path.to_string()));
        }
        let ents = self.dir_entries(&ino)?;
        let mut out = Vec::new();
        for (name, child, ty) in ents {
            // `file_type` is authoritative when the feature is on; fall back to
            // the child's mode otherwise.
            let (dir, size) = match ty {
                2 => (true, 0),
                1 => {
                    let c = self.inode(child)?;
                    (false, c.size)
                }
                _ => {
                    let c = self.inode(child)?;
                    (c.is_dir(), c.size)
                }
            };
            out.push(DirEnt {
                name,
                dir,
                size,
                read_only: false,
                hidden: false,
            });
        }
        out.sort_by(|a, b| (b.dir, a.name.to_lowercase()).cmp(&(a.dir, b.name.to_lowercase())));
        Ok(out)
    }

    fn stat(&mut self, path: &str) -> Result<Stat> {
        let (_, ino) = self.resolve(path)?;
        Ok(Stat {
            dir: ino.is_dir(),
            size: ino.size,
            read_only: !self.rw,
        })
    }

    fn read(&mut self, path: &str) -> Result<Vec<u8>> {
        let (_, ino) = self.resolve(path)?;
        if ino.is_dir() {
            return Err(Error::IsADir(path.to_string()));
        }
        if ino.is_link() && ino.size < 60 {
            // A fast symlink keeps its target in `i_block`.
            return Ok(ino.block[..ino.size as usize].to_vec());
        }
        self.read_inode_data(&ino, ino.size)
    }

    fn read_window(&mut self, path: &str, off: u64, len: usize) -> Result<Vec<u8>> {
        let (_, ino) = self.resolve(path)?;
        if ino.is_dir() {
            return Err(Error::IsADir(path.to_string()));
        }
        let end = off.saturating_add(len as u64).min(ino.size);
        if off >= ino.size {
            return Ok(Vec::new());
        }
        let all = self.read_inode_data(&ino, end)?;
        Ok(all[off as usize..].to_vec())
    }

    /// ext4's terms, stated before an edit rather than after: an existing
    /// regular file writes in place inside its mapped prefix, and can **grow**
    /// at its tail by block allocation (extent merge or root-slot append —
    /// a full 4-slot root is a split the OS owns). Creating a file is inode +
    /// dirent insertion; a `dir_index` parent is refused because its hash tree
    /// would need updating too. No journal transactions are written — the
    /// metadata is left consistent, which is what `e2fsck` verifies.
    fn edit_budget(&mut self, path: &str) -> Result<crate::EditBudget> {
        let (_, ino) = match self.resolve(path) {
            Ok(v) => v,
            Err(Error::NotFoundPath(_)) => {
                let writable = self.rw;
                return Ok(crate::EditBudget {
                    fs: self.kind,
                    exists: false,
                    size: 0,
                    writable,
                    max_bytes: None,
                    can_create: writable,
                    can_grow: false,
                    why: Some(if writable {
                        "creates: inode + dirent, data blocks allocated on write".to_string()
                    } else {
                        self.refusal.clone().unwrap_or_else(|| {
                            "mounted read-only (`mount -w` to write)".to_string()
                        })
                    }),
                });
            }
            Err(e) => return Err(e),
        };
        if ino.is_dir() {
            return Ok(crate::EditBudget::refused(
                self.kind,
                0,
                true,
                format!("{path} is a directory"),
            ));
        }
        if !ino.is_reg() {
            return Ok(crate::EditBudget::refused(
                self.kind,
                ino.size,
                true,
                format!("{path} is not a regular file ({:#o})", ino.mode),
            ));
        }
        if !self.rw {
            let why = self
                .refusal
                .clone()
                .unwrap_or_else(|| "mounted read-only (`mount -w` to write)".to_string());
            return Ok(crate::EditBudget::refused(self.kind, ino.size, true, why));
        }
        let blocks = self.blocks_of(&ino)?;
        let prefix = blocks
            .iter()
            .enumerate()
            .take_while(|(i, (logical, _))| *logical == *i as u64)
            .count() as u64;
        let (covered, mapped) = self.hole_check(&ino)?;
        let sparse = mapped < covered;
        // Growing is possible unless the inode's extent root is already full of
        // non-mergeable entries — checked conservatively at write time.
        let can_grow =
            ino.flags & EXTENTS_FL != 0 || covered < 12 && ino.flags & INLINE_DATA_FL == 0;
        Ok(crate::EditBudget {
            fs: self.kind,
            exists: true,
            size: ino.size,
            writable: true,
            max_bytes: None,
            can_create: true,
            can_grow: !sparse && can_grow,
            why: Some(if sparse {
                format!(
                    "sparse file: {mapped} of {covered} logical blocks are mapped, and only the \
                     first {prefix} are contiguous — writes stay in place and cannot fill a hole"
                )
            } else {
                "writes in place, and grows at the tail by allocating blocks".to_string()
            }),
        })
    }

    /// Write a file: in place inside the blocks it already has, growing at the
    /// tail by allocation when it must, or creating it — inode, dirent, then
    /// data blocks. Everything else is refused, with the reason.
    fn write(&mut self, path: &str, data: &[u8]) -> Result<()> {
        if !self.rw {
            let why = self
                .refusal
                .clone()
                .unwrap_or_else(|| "mounted read-only".to_string());
            return Err(Error::Unsupported(format!("{path}: {why}")));
        }
        let (ino_no, ino) = match self.resolve(path) {
            Ok(v) => v,
            Err(Error::NotFoundPath(_)) => {
                // Create: parent must resolve and be a directory; the file is
                // inode + dirent + (on the way below) data blocks.
                let (parent, leaf) = match path.rsplit_once('/') {
                    Some((p, l)) if !l.is_empty() => (if p.is_empty() { "/" } else { p }, l),
                    _ if !path.is_empty() => ("/", path.trim_start_matches('/')),
                    _ => return Err(Error::NotFoundPath(path.to_string())),
                };
                let (dir_no, dir) = self.resolve(parent)?;
                if !dir.is_dir() {
                    return Err(Error::NotADir(parent.to_string()));
                }
                let child = self.create_child(dir_no, &dir, leaf, false)?;
                (child, self.inode(child)?)
            }
            Err(e) => return Err(e),
        };
        if ino.is_dir() {
            return Err(Error::IsADir(path.to_string()));
        }
        if !ino.is_reg() {
            return Err(Error::Unsupported(format!(
                "{path}: not a regular file ({:#o})",
                ino.mode
            )));
        }
        let blocks = self.blocks_of(&ino)?;
        let needed = (data.len() as u64).div_ceil(self.block_size);
        let contiguous_prefix = blocks
            .iter()
            .enumerate()
            .take_while(|(i, (logical, _))| *logical == *i as u64)
            .count() as u64;
        // Every logical block the write needs must be mapped — holes in the
        // middle stay the OS's business; a short tail is allocated.
        let covered = ino.size.div_ceil(self.block_size);
        let mid_hole = (0..needed.min(covered)).any(|l| !blocks.iter().any(|(b, _)| *b == l));
        if mid_hole {
            return Err(Error::Unsupported(format!(
                "{path}: sparse file — only logical blocks 0..{contiguous_prefix} are mapped \
                 and {} bytes need {needed}. Filling a hole mid-file needs extent insertion the \
                 OS owns; tail growth is what this driver does",
                data.len()
            )));
        }
        let mut map = blocks;
        if needed > covered {
            let grown = self.grow_blocks(ino_no, &ino, covered, needed - covered)?;
            map.extend(grown);
        }
        if map.iter().filter(|(l, _)| *l < needed).count() < needed as usize {
            return Err(Error::Unsupported(format!(
                "{path}: could not map all {} bytes — extent root is full or blocks ran out",
                data.len()
            )));
        }
        // Write the content at logical offsets, zero-filling the rest of the last
        // touched block, then the size. Size last: a reader that races us sees the
        // old length over new bytes, never a length over bytes never written.
        for (i, (logical, physical)) in map.iter().enumerate() {
            if *logical >= needed {
                break;
            }
            let start = *logical as usize * self.block_size as usize;
            if start >= data.len() {
                break;
            }
            let n = (data.len() - start).min(self.block_size as usize);
            let mut buf = vec![0u8; self.block_size as usize];
            buf[..n].copy_from_slice(&data[start..start + n]);
            let at = self.block_off(*physical);
            self.dev.write_at(at, &buf)?;
            let _ = i;
        }
        let at = self.inode_off(ino_no)?;
        let size = data.len() as u64;
        self.dev.write_at(at + 4, &(size as u32).to_le_bytes())?;
        self.dev
            .write_at(at + 108, &((size >> 32) as u32).to_le_bytes())?;
        // i_blocks counts 512-byte sectors over every mapped block.
        let sectors = (map.len() as u64) * (self.block_size / 512);
        self.dev
            .write_at(at + 28, &(sectors as u32).to_le_bytes())?;
        // Last: the inode's own checksum, over the record we just changed. An
        // unchecksummed inode is a filesystem error to `e2fsck` even when every
        // byte of data is right.
        self.write_inode_csum(ino_no)?;
        self.dev.flush()
    }

    /// Create a directory: inode, `.`/`..` block, and a dirent in the parent —
    /// plus the parent's link count, which a reader trusts.
    fn mkdir(&mut self, path: &str) -> Result<()> {
        if !self.rw {
            let why = self
                .refusal
                .clone()
                .unwrap_or_else(|| "mounted read-only".to_string());
            return Err(Error::Unsupported(format!("{path}: {why}")));
        }
        let (parent, leaf) = match path.rsplit_once('/') {
            Some((p, l)) if !l.is_empty() => (if p.is_empty() { "/" } else { p }, l),
            _ if !path.is_empty() => ("/", path.trim_start_matches('/')),
            _ => return Err(Error::NotFoundPath(path.to_string())),
        };
        if self.resolve(path).is_ok() {
            return Err(Error::Unsupported(format!("{path}: already exists")));
        }
        let (dir_no, dir) = self.resolve(parent)?;
        if !dir.is_dir() {
            return Err(Error::NotADir(parent.to_string()));
        }
        self.create_child(dir_no, &dir, leaf, true)?;
        self.dev.flush()
    }
}

/// A spec-shaped ext4 image with `/etc/fstab` and an `/os-release`, for tests in
/// this crate *and* in the kernel that owns the mount table.
///
/// It is built by the same code the reader is tested against, which is the point:
/// if the layout knowledge is wrong, both sides are wrong together and the
/// against-a-real-`mkfs.ext4`-image check (`tools/mkmedia.sh`) catches it.
pub fn tests_image_with_os_release() -> Vec<u8> {
    fixture(true, false).into_bytes()
}

/// A minimal but *spec-shaped* ext4: 1 KiB blocks, one group, an extent-mapped
/// `/etc/fstab`, a directory `/etc`, and a classic direct-block file so both
/// mapping paths are exercised. Blocks are laid out honestly — superblock at 1,
/// group descriptors at 2, the two bitmaps at 3 and 4, the inode table at 5
/// (32 inodes × 256 B = 8 blocks), then data — so allocation has real bitmaps
/// and counts to walk, the way a `mkfs.ext4` volume does.
pub fn fixture(clean: bool, recover: bool) -> MemBlock {
    let bs = 1024usize;
    let blocks = 512usize;
    let mut d = vec![0u8; bs * blocks];
    let inode_size = 256usize;
    let inodes = 32u32;
    // --- superblock at 1024 -------------------------------------------
    let sb = 1024;
    let put32 = |d: &mut Vec<u8>, at: usize, v: u32| {
        d[at..at + 4].copy_from_slice(&v.to_le_bytes());
    };
    let put16 = |d: &mut Vec<u8>, at: usize, v: u16| {
        d[at..at + 2].copy_from_slice(&v.to_le_bytes());
    };
    put32(&mut d, sb, inodes); // s_inodes_count
    put32(&mut d, sb + 4, blocks as u32); // s_blocks_count_lo
    put32(&mut d, sb + 12, 495); // s_free_blocks_count (511 data blocks, 16 used)
    put32(&mut d, sb + 16, 28); // s_free_inodes_count (32 inodes, 4 used)
    put32(&mut d, sb + 20, 1); // s_first_data_block (1 KiB blocks)
    put32(&mut d, sb + 24, 0); // s_log_block_size → 1024
    put32(&mut d, sb + 32, 8192); // s_blocks_per_group
    put32(&mut d, sb + 40, inodes); // s_inodes_per_group
    put16(&mut d, sb + 56, EXT4_MAGIC);
    put16(&mut d, sb + 58, if clean { 1 } else { 0 }); // s_state
    put16(&mut d, sb + 88, inode_size as u16);
    let incompat = 0x0040 | INCOMPAT_FILETYPE | if recover { INCOMPAT_RECOVER } else { 0 };
    put32(&mut d, sb + 96, incompat); // extents + filetype (+ recover)
    for (i, c) in b"g6lcroot".iter().enumerate() {
        d[sb + 120 + i] = *c;
    }
    // --- group descriptor in block 2 ----------------------------------
    let gd = 2 * bs;
    put32(&mut d, gd, 3); // bg_block_bitmap_lo → block 3
    put32(&mut d, gd + 4, 4); // bg_inode_bitmap_lo → block 4
    put32(&mut d, gd + 8, 5); // bg_inode_table_lo → block 5
    put16(&mut d, gd + 12, 495); // bg_free_blocks_count_lo
    put16(&mut d, gd + 14, 28); // bg_free_inodes_count_lo
    put16(&mut d, gd + 16, 2); // bg_used_dirs_count_lo (/, /etc)
    put16(&mut d, gd + 28, 17); // bg_itable_unused_lo (32 - ino 15)
                                // --- bitmaps --------------------------------------------------------
                                // Block bitmap (block 3): group 0 bit i ↔ block 1+i. Used: 1..16
                                // (sb, gdt, both bitmaps, the 8-block inode table, four data blocks).
    for i in 0..16usize {
        d[3 * bs + i / 8] |= 1 << (i % 8);
    }
    // Inode bitmap (block 4): bit n-1 ↔ inode n. Used: 2, 12, 13, 14.
    for i in [1usize, 11, 12, 13] {
        d[4 * bs + i / 8] |= 1 << (i % 8);
    }
    // --- inode table at block 5 ---------------------------------------
    let itab = 5 * bs;
    let set_inode = |d: &mut Vec<u8>, ino: u32, mode: u16, size: u64, flags: u32, body: &[u8]| {
        let at = itab + ((ino - 1) as usize) * inode_size;
        d[at..at + 2].copy_from_slice(&mode.to_le_bytes());
        d[at + 4..at + 8].copy_from_slice(&(size as u32).to_le_bytes());
        // i_links_count: a directory counts `.` + `..` from each subdir.
        let links: u16 = if mode & S_IFMT == S_IFDIR { 2 } else { 1 };
        d[at + 26..at + 28].copy_from_slice(&links.to_le_bytes());
        d[at + 32..at + 36].copy_from_slice(&flags.to_le_bytes());
        d[at + 40..at + 40 + body.len()].copy_from_slice(body);
        d[at + 108..at + 112].copy_from_slice(&((size >> 32) as u32).to_le_bytes());
    };
    // An extent-mapped file body: header + one leaf.
    let extent = |first_block: u32, len: u16| -> Vec<u8> {
        let mut e = vec![0u8; 60];
        e[0..2].copy_from_slice(&EXTENT_MAGIC.to_le_bytes());
        e[2..4].copy_from_slice(&1u16.to_le_bytes()); // entries
        e[4..6].copy_from_slice(&4u16.to_le_bytes()); // max
        e[6..8].copy_from_slice(&0u16.to_le_bytes()); // depth
        e[12..16].copy_from_slice(&0u32.to_le_bytes()); // ee_block
        e[16..18].copy_from_slice(&len.to_le_bytes()); // ee_len
        e[18..20].copy_from_slice(&0u16.to_le_bytes()); // ee_start_hi
        e[20..24].copy_from_slice(&first_block.to_le_bytes());
        e
    };
    // Root directory (inode 2) → extent block 13.
    set_inode(
        &mut d,
        2,
        S_IFDIR | 0o755,
        bs as u64,
        EXTENTS_FL,
        &extent(13, 1),
    );
    // /etc directory (inode 12) → block 14.
    set_inode(
        &mut d,
        12,
        S_IFDIR | 0o755,
        bs as u64,
        EXTENTS_FL,
        &extent(14, 1),
    );
    // /etc/fstab (inode 13) → block 15, extent-mapped.
    let fstab = b"/dev/vda2 / ext4 defaults 0 1\n";
    set_inode(
        &mut d,
        13,
        S_IFREG | 0o644,
        fstab.len() as u64,
        EXTENTS_FL,
        &extent(15, 1),
    );
    // /os-release (inode 14) → classic direct block 16 (no extents flag).
    let osrel = b"PRETTY_NAME=\"G6LC Linux 1.0\"\nID=g6lc\n";
    let mut direct = vec![0u8; 60];
    direct[0..4].copy_from_slice(&16u32.to_le_bytes());
    set_inode(&mut d, 14, S_IFREG | 0o644, osrel.len() as u64, 0, &direct);
    // --- directory blocks ---------------------------------------------
    let dirent = |d: &mut Vec<u8>, at: usize, ino: u32, ty: u8, name: &str| -> usize {
        let nl = name.len();
        let rec = (8 + nl + 3) & !3;
        d[at..at + 4].copy_from_slice(&ino.to_le_bytes());
        d[at + 4..at + 6].copy_from_slice(&(rec as u16).to_le_bytes());
        d[at + 6] = nl as u8;
        d[at + 7] = ty;
        d[at + 8..at + 8 + nl].copy_from_slice(name.as_bytes());
        rec
    };
    let root_blk = 13 * bs;
    let mut at = root_blk;
    at += dirent(&mut d, at, 2, 2, ".");
    at += dirent(&mut d, at, 2, 2, "..");
    at += dirent(&mut d, at, 12, 2, "etc");
    at += dirent(&mut d, at, 14, 1, "os-release");
    // The last record must span the rest of the block, the way a real ext
    // directory pads its tail.
    let last_rec_at = at - ((8 + "os-release".len() + 3) & !3);
    d[last_rec_at + 4..last_rec_at + 6]
        .copy_from_slice(&((bs - (last_rec_at - root_blk)) as u16).to_le_bytes());
    let etc_blk = 14 * bs;
    let mut at = etc_blk;
    at += dirent(&mut d, at, 12, 2, ".");
    at += dirent(&mut d, at, 2, 2, "..");
    at += dirent(&mut d, at, 13, 1, "fstab");
    // /etc/os-release is what names the installed system, so the fixture has
    // one: it is the file OS detection reads.
    let last_rec = at;
    at += dirent(&mut d, at, 14, 1, "os-release");
    d[last_rec + 4..last_rec + 6]
        .copy_from_slice(&((bs - (last_rec - etc_blk)) as u16).to_le_bytes());
    let _ = at;
    // --- file data ----------------------------------------------------
    d[15 * bs..15 * bs + fstab.len()].copy_from_slice(fstab);
    d[16 * bs..16 * bs + osrel.len()].copy_from_slice(osrel);
    MemBlock::new(d)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The CRC-32C the ext4 checksums chain from. The standard check value for
    /// `"123456789"` is `0xE3069283` with the usual pre/post inversion, so the
    /// continuation form must produce it once inverted.
    #[test]
    fn crc32c_matches_the_castagnoli_check_value() {
        assert_eq!(!crc32c(!0u32, b"123456789"), 0xE306_9283);
        assert_eq!(!crc32c(!0u32, b""), 0);
        // Chaining is the same as one pass — what makes the seeded chain legal.
        let one = crc32c(!0u32, b"abcdef");
        let two = crc32c(crc32c(!0u32, b"abc"), b"def");
        assert_eq!(one, two);
    }

    #[test]
    fn mount_reads_the_superblock_geometry_and_label() {
        let mut dev = fixture(true, false);
        let fs = Ext4::mount(&mut dev, true).unwrap();
        assert_eq!(fs.kind(), FsKind::Ext4);
        assert_eq!(fs.label(), "g6lcroot");
        assert_eq!(fs.block_size, 1024);
        assert!(fs.writable(), "a clean fs on a writable device mounts rw");
        assert!(fs.refusal().is_none());
    }

    #[test]
    fn cd_into_etc_and_read_fstab() {
        let mut dev = fixture(true, false);
        let mut fs = Ext4::mount(&mut dev, false).unwrap();
        let root = fs.list("/").unwrap();
        let names: Vec<&str> = root.iter().map(|e| e.name.as_str()).collect();
        assert!(names.contains(&"etc"), "{names:?}");
        assert!(names.contains(&"os-release"), "{names:?}");
        assert!(root.iter().find(|e| e.name == "etc").unwrap().dir);
        // The directory an operator actually needs.
        let etc = fs.list("/etc").unwrap();
        let etc_names: Vec<&str> = etc.iter().map(|e| e.name.as_str()).collect();
        assert_eq!(etc_names, ["fstab", "os-release"], "{etc:?}");
        assert!(etc.iter().all(|e| !e.dir));
        let text = String::from_utf8(fs.read("/etc/fstab").unwrap()).unwrap();
        assert!(text.starts_with("/dev/vda2 / ext4"), "{text}");
        assert_eq!(fs.stat("/etc/fstab").unwrap().size, text.len() as u64);
        // The classic direct-block path reads too (no extents flag).
        let osrel = String::from_utf8(fs.read("/os-release").unwrap()).unwrap();
        assert!(osrel.contains("G6LC Linux"), "{osrel}");
        // Windows into a file are windows.
        assert_eq!(fs.read_window("/etc/fstab", 10, 4).unwrap(), b"/ ex");
        // Missing paths and misused ones are named.
        assert!(matches!(fs.read("/etc"), Err(Error::IsADir(_))));
        assert!(matches!(fs.list("/nope"), Err(Error::NotFoundPath(_))));
        assert!(matches!(fs.list("/etc/fstab"), Err(Error::NotADir(_))));
    }

    #[test]
    fn in_place_write_fixes_a_boot_file_and_grow_allocates() {
        let mut dev = fixture(true, false);
        let mut fs = Ext4::mount(&mut dev, true).unwrap();
        // The repair an operator came for: rewrite fstab, same block.
        let fixed = b"/dev/vda3 / ext4 ro 0 1\n";
        fs.write("/etc/fstab", fixed).unwrap();
        assert_eq!(fs.read("/etc/fstab").unwrap(), fixed);
        assert_eq!(fs.stat("/etc/fstab").unwrap().size, fixed.len() as u64);
        // Bigger than the allocated blocks → the file **grows** now: blocks are
        // allocated from the inode's group, the extent merges or appends, and
        // the free counts drop by exactly what was taken.
        let grown: Vec<u8> = (0..2600u32).map(|i| b'a' + (i % 26) as u8).collect();
        fs.write("/etc/fstab", &grown).unwrap();
        assert_eq!(fs.read("/etc/fstab").unwrap(), grown);
        // The file got the blocks it needed: 2600 bytes = 3 blocks at 1 KiB.
        let gd = fs.gd(0).unwrap();
        assert_eq!(fs.gd_counts(&gd, 0x0C), 493, "two blocks allocated");
        // The blocks' contents are really there, readable through the map.
        let tail = fs.read_window("/etc/fstab", 2048, 8).unwrap();
        assert_eq!(tail.len(), 8);
        // A directory is not a file.
        assert!(matches!(fs.write("/etc", b"x"), Err(Error::IsADir(_))));
    }

    /// Creating a file is inode + dirent + data blocks — and `mkdir` makes a
    /// directory another system can walk: `.`, `..`, the parent's link count.
    #[test]
    fn create_and_mkdir_write_a_real_inode_and_dirent() {
        let mut dev = fixture(true, false);
        let mut fs = Ext4::mount(&mut dev, true).unwrap();
        // A new file in an existing directory.
        fs.write("/etc/modules", b"sunrpc\n9pnet\n").unwrap();
        assert_eq!(fs.read("/etc/modules").unwrap(), b"sunrpc\n9pnet\n");
        let etc = fs.list("/etc").unwrap();
        assert!(etc.iter().any(|e| e.name == "modules" && !e.dir), "{etc:?}");
        // And a new directory under it, holding a file.
        fs.mkdir("/etc/default").unwrap();
        assert!(fs.list("/").unwrap().iter().any(|e| e.name == "etc"));
        fs.write("/etc/default/grub", b"GRUB_TIMEOUT=2\n").unwrap();
        assert_eq!(fs.read("/etc/default/grub").unwrap(), b"GRUB_TIMEOUT=2\n");
        // Inode and block counters moved by exactly what the creates took:
        // three inodes (two files + one dir) and three data blocks.
        let gd = fs.gd(0).unwrap();
        assert_eq!(fs.gd_counts(&gd, 0x0E), 25, "three inodes allocated");
        assert_eq!(fs.gd_counts(&gd, 0x0C), 492, "three data blocks");
        assert_eq!(fs.gd_counts(&gd, 0x10), 3, "used_dirs went up by one");
        // The superblock's totals agree.
        let sb = read_vec(fs.dev, 1024, 20).unwrap();
        assert_eq!(le32(&sb, 16), 25);
        assert_eq!(le32(&sb, 12), 492);
        // The parent's `..` back-link: /etc's link count went 2 → 3 when
        // `default` was made inside it.
        let etc_ino = fs.inode(12).unwrap();
        assert!(etc_ino.is_dir());
        let at = fs.inode_off(12).unwrap();
        let rec = read_vec(fs.dev, at + 26, 2).unwrap();
        assert_eq!(
            u16::from_le_bytes([rec[0], rec[1]]),
            3,
            "/etc links: . .. default"
        );
        // Freshly created entries are listed where they were put.
        let def = fs.list("/etc/default").unwrap();
        assert!(def.iter().any(|e| e.name == "grub"), "{def:?}");
    }

    /// A **sparse** file reads with its hole where the hole is, and is refused for
    /// in-place writing.
    ///
    /// The bug this pins: an extent carries the logical block it starts at
    /// (`ee_block`), and a mapper that drops it returns physical blocks in order —
    /// so a file with a hole comes back *rearranged*, with later data pulled
    /// forward into the gap. Rearranged is worse than missing, because it looks
    /// like data.
    #[test]
    fn a_sparse_file_reads_with_its_hole_and_refuses_in_place_writes() {
        let bs = 1024usize;
        let mut d = fixture(true, false).into_bytes();
        // Give inode 14 an extent map with a hole: logical 0 → block 20,
        // logical *2* → block 21 (logical 1 is unmapped). Size covers all three
        // blocks. The fixture's data area starts at 17, so 20/21 are free.
        for i in [19usize, 20] {
            d[3 * bs + i / 8] |= 1 << (i % 8); // mark 20,21 used in the bitmap
        }
        let itab = 5 * bs;
        let inode_size = 256usize;
        let at = itab + 13 * inode_size; // inode 14
        let size = 3 * bs as u64;
        d[at..at + 2].copy_from_slice(&(S_IFREG | 0o644u16).to_le_bytes());
        d[at + 4..at + 8].copy_from_slice(&(size as u32).to_le_bytes());
        d[at + 32..at + 36].copy_from_slice(&EXTENTS_FL.to_le_bytes());
        let body = at + 40;
        d[body..body + 60].fill(0);
        d[body..body + 2].copy_from_slice(&EXTENT_MAGIC.to_le_bytes());
        d[body + 2..body + 4].copy_from_slice(&2u16.to_le_bytes()); // entries
        d[body + 4..body + 6].copy_from_slice(&4u16.to_le_bytes()); // max
                                                                    // leaf 0: logical 0, len 1, physical 20
        d[body + 12..body + 16].copy_from_slice(&0u32.to_le_bytes());
        d[body + 16..body + 18].copy_from_slice(&1u16.to_le_bytes());
        d[body + 20..body + 24].copy_from_slice(&20u32.to_le_bytes());
        // leaf 1: logical 2, len 1, physical 21  ← logical 1 is a hole
        d[body + 24..body + 28].copy_from_slice(&2u32.to_le_bytes());
        d[body + 28..body + 30].copy_from_slice(&1u16.to_le_bytes());
        d[body + 32..body + 36].copy_from_slice(&21u32.to_le_bytes());
        d[20 * bs..20 * bs + 5].copy_from_slice(b"FIRST");
        d[21 * bs..21 * bs + 5].copy_from_slice(b"THIRD");
        let mut dev = MemBlock::new(d);
        let mut fs = Ext4::mount(&mut dev, true).unwrap();
        let body = fs.read("/os-release").unwrap();
        assert_eq!(body.len(), 3 * bs, "the size, holes included");
        assert_eq!(&body[..5], b"FIRST");
        assert!(
            body[bs..2 * bs].iter().all(|b| *b == 0),
            "the hole reads as zeros, and does not pull the third block forward"
        );
        assert_eq!(&body[2 * bs..2 * bs + 5], b"THIRD", "at its logical place");
        // Writing it in place is refused with the mapping, not attempted.
        let err = fs.write("/os-release", &vec![b'x'; 2 * bs]).unwrap_err();
        let msg = err.to_string();
        assert!(msg.contains("sparse file"), "{msg}");
        assert!(msg.contains("0..1"), "names the mapped prefix: {msg}");
        // The file is untouched.
        assert_eq!(&fs.read("/os-release").unwrap()[..5], b"FIRST");
        // A write that fits the *contiguous* prefix is still allowed.
        fs.write("/os-release", b"ok").unwrap();
        assert_eq!(fs.read("/os-release").unwrap(), b"ok");
    }

    #[test]
    fn a_dirty_or_journalled_fs_will_not_mount_writable() {
        // needs_recovery → read-only, and the refusal says why.
        let mut dev = fixture(true, true);
        let mut fs = Ext4::mount(&mut dev, true).unwrap();
        assert!(!fs.writable());
        assert!(fs.refusal().unwrap().contains("needs recovery"));
        let err = fs.write("/etc/fstab", b"x").unwrap_err();
        assert!(err.to_string().contains("needs recovery"), "{err}");
        // Still readable — that is the point of a repair shell.
        assert!(!fs.read("/etc/fstab").unwrap().is_empty());
        // Not-clean state → same treatment.
        let mut dev = fixture(false, false);
        let fs = Ext4::mount(&mut dev, true).unwrap();
        assert!(!fs.writable());
        assert!(fs.refusal().unwrap().contains("not marked clean"));
    }
}
