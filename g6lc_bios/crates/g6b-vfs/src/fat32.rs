// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! FAT32 — read **and write**. This is the filesystem a BIOS must be able to
//! change: firmware images, settings exports, an `extlinux.conf` on an ESP.
//!
//! On-disk contract (Microsoft FAT32 specification):
//!
//! * BPB at sector 0: `bytes_per_sector` (11), `sectors_per_cluster` (13),
//!   `reserved_sectors` (14), `num_fats` (16), `sectors_per_fat32` (36),
//!   `root_cluster` (44), `fsinfo_sector` (48).
//! * Data area starts at `reserved + num_fats * sectors_per_fat`; cluster *n*
//!   lives at `data + (n - 2) * sectors_per_cluster`.
//! * The FAT is a `u32` array; only the low 28 bits are the value. `0` free,
//!   `0x0FFFFFF7` bad, `>= 0x0FFFFFF8` end of chain.
//! * A directory is a cluster chain of 32-byte entries: `name[11]`, `attr` (11),
//!   `cluster_hi` (20), `cluster_lo` (26), `size` (28). `0x00` ends the
//!   directory, `0xE5` is a deleted entry, `attr == 0x0F` is a long-name (VFAT)
//!   fragment whose UTF-16 pieces precede the short entry they name.
//!
//! Writes keep the two FAT copies and the FSInfo free-count in step, because the
//! next thing to mount this volume is an OS that trusts them.

use crate::block::{le16, le32, read_vec, BlockDev, MemBlock};
use crate::{DirEnt, Error, FileSystem, FsKind, Result, Stat};

const ATTR_READ_ONLY: u8 = 0x01;
const ATTR_HIDDEN: u8 = 0x02;
const ATTR_SYSTEM: u8 = 0x04;
const ATTR_VOLUME_ID: u8 = 0x08;
const ATTR_DIR: u8 = 0x10;
const ATTR_LFN: u8 = 0x0F;
const EOC: u32 = 0x0FFF_FFF8;
const FREE: u32 = 0;

/// A mounted FAT32 volume.
pub struct Fat32<'a> {
    dev: &'a mut dyn BlockDev,
    bytes_per_sector: u32,
    sectors_per_cluster: u32,
    reserved: u32,
    num_fats: u32,
    sectors_per_fat: u32,
    root_cluster: u32,
    fsinfo_sector: u32,
    total_clusters: u32,
    label: String,
    rw: bool,
}

/// One resolved entry: where its directory record is, and what it says.
#[derive(Debug, Clone, Copy)]
struct Found {
    /// Byte offset of the 32-byte short entry on the device.
    entry_at: u64,
    first_cluster: u32,
    size: u32,
    attr: u8,
}

impl Found {
    fn is_dir(&self) -> bool {
        self.attr & ATTR_DIR != 0
    }
}

impl<'a> Fat32<'a> {
    /// Parse the BPB and take the volume.
    pub fn mount(dev: &'a mut dyn BlockDev, rw: bool) -> Result<Self> {
        let boot = read_vec(dev, 0, 512)?;
        if le16(&boot, 510) != 0xAA55 {
            return Err(Error::Corrupt("fat32: no 0xAA55 boot signature"));
        }
        let bytes_per_sector = u32::from(le16(&boot, 11));
        let sectors_per_cluster = u32::from(boot[13]);
        let reserved = u32::from(le16(&boot, 14));
        let num_fats = u32::from(boot[16]);
        let sectors_per_fat = le32(&boot, 36);
        let root_cluster = le32(&boot, 44);
        let fsinfo_sector = u32::from(le16(&boot, 48));
        let total_sectors = match le16(&boot, 19) {
            0 => le32(&boot, 32),
            n => u32::from(n),
        };
        if !matches!(bytes_per_sector, 512 | 1024 | 2048 | 4096)
            || sectors_per_cluster == 0
            || !sectors_per_cluster.is_power_of_two()
            || num_fats == 0
            || sectors_per_fat == 0
            || root_cluster < 2
        {
            return Err(Error::Corrupt("fat32: implausible BPB"));
        }
        let data_start = reserved + num_fats * sectors_per_fat;
        let data_sectors = total_sectors.saturating_sub(data_start);
        let total_clusters = data_sectors / sectors_per_cluster;
        let rw = rw && dev.writable();
        let mut fs = Self {
            dev,
            bytes_per_sector,
            sectors_per_cluster,
            reserved,
            num_fats,
            sectors_per_fat,
            root_cluster,
            fsinfo_sector,
            total_clusters,
            label: String::new(),
            rw,
        };
        // The label in the BPB is a copy; the root directory's volume-id entry
        // is the one a formatter updates, so prefer it when present.
        fs.label = fs.volume_label().unwrap_or_default();
        if fs.label.is_empty() {
            fs.label = crate::probe::probe(fs.dev)?.label;
        }
        Ok(fs)
    }

    fn cluster_bytes(&self) -> u64 {
        u64::from(self.bytes_per_sector) * u64::from(self.sectors_per_cluster)
    }

    fn cluster_off(&self, cluster: u32) -> Result<u64> {
        if cluster < 2 {
            return Err(Error::Corrupt("fat32: cluster < 2"));
        }
        let data_start = u64::from(self.reserved + self.num_fats * self.sectors_per_fat)
            * u64::from(self.bytes_per_sector);
        Ok(data_start + u64::from(cluster - 2) * self.cluster_bytes())
    }

    fn fat_entry_off(&self, cluster: u32, copy: u32) -> u64 {
        (u64::from(self.reserved) + u64::from(copy) * u64::from(self.sectors_per_fat))
            * u64::from(self.bytes_per_sector)
            + u64::from(cluster) * 4
    }

    fn fat_get(&mut self, cluster: u32) -> Result<u32> {
        let at = self.fat_entry_off(cluster, 0);
        let b = read_vec(self.dev, at, 4)?;
        Ok(le32(&b, 0) & 0x0FFF_FFFF)
    }

    /// Write a FAT slot in **every** copy: an OS that reads the second FAT must
    /// not see a different chain than the one we wrote.
    fn fat_set(&mut self, cluster: u32, value: u32) -> Result<()> {
        for copy in 0..self.num_fats {
            let at = self.fat_entry_off(cluster, copy);
            let mut b = read_vec(self.dev, at, 4)?;
            let keep = le32(&b, 0) & 0xF000_0000;
            b.copy_from_slice(&(keep | (value & 0x0FFF_FFFF)).to_le_bytes());
            self.dev.write_at(at, &b)?;
        }
        Ok(())
    }

    fn chain(&mut self, first: u32) -> Result<Vec<u32>> {
        let mut out = Vec::new();
        let mut c = first;
        // Bounded by the cluster count: a cyclic FAT must not spin forever.
        while (2..EOC).contains(&c) && out.len() as u32 <= self.total_clusters + 2 {
            out.push(c);
            c = self.fat_get(c)?;
        }
        if out.len() as u32 > self.total_clusters + 1 {
            return Err(Error::Corrupt("fat32: cluster chain loops"));
        }
        Ok(out)
    }

    /// Allocate `n` free clusters, chained, returning the first.
    fn alloc_chain(&mut self, n: u32) -> Result<Vec<u32>> {
        if n == 0 {
            return Ok(Vec::new());
        }
        let mut found = Vec::new();
        // Cluster numbers run 2..total_clusters+2.
        for c in 2..self.total_clusters + 2 {
            if self.fat_get(c)? == FREE {
                found.push(c);
                if found.len() as u32 == n {
                    break;
                }
            }
        }
        if (found.len() as u32) < n {
            return Err(Error::NoSpace);
        }
        for i in 0..found.len() {
            let next = if i + 1 == found.len() {
                0x0FFF_FFFF
            } else {
                found[i + 1]
            };
            self.fat_set(found[i], next)?;
        }
        self.fsinfo_spend(n)?;
        Ok(found)
    }

    fn free_chain(&mut self, first: u32) -> Result<u32> {
        let chain = self.chain(first)?;
        for c in &chain {
            self.fat_set(*c, FREE)?;
        }
        self.fsinfo_return(chain.len() as u32)?;
        Ok(chain.len() as u32)
    }

    /// Keep the FSInfo free-cluster hint honest, or invalidate it. A stale count
    /// is a filesystem-check finding on the next OS boot.
    fn fsinfo_adjust(&mut self, delta: i64) -> Result<()> {
        if self.fsinfo_sector == 0 {
            return Ok(());
        }
        let at = u64::from(self.fsinfo_sector) * u64::from(self.bytes_per_sector);
        let b = read_vec(self.dev, at, 512)?;
        if le32(&b, 0) != 0x4161_5252 || le32(&b, 484) != 0x6141_7272 {
            return Ok(());
        }
        let free = le32(&b, 488);
        let next = if free == u32::MAX {
            u32::MAX
        } else {
            let v = i64::from(free) + delta;
            if v < 0 {
                u32::MAX
            } else {
                v as u32
            }
        };
        self.dev.write_at(at + 488, &next.to_le_bytes())
    }

    fn fsinfo_spend(&mut self, n: u32) -> Result<()> {
        self.fsinfo_adjust(-i64::from(n))
    }

    fn fsinfo_return(&mut self, n: u32) -> Result<()> {
        self.fsinfo_adjust(i64::from(n))
    }

    /// Read a whole cluster chain into memory, truncated to `limit` bytes.
    fn read_chain(&mut self, first: u32, limit: u64) -> Result<Vec<u8>> {
        let mut out = Vec::new();
        for c in self.chain(first)? {
            if out.len() as u64 >= limit {
                break;
            }
            let off = self.cluster_off(c)?;
            let want = (limit - out.len() as u64).min(self.cluster_bytes()) as usize;
            out.extend_from_slice(&read_vec(self.dev, off, want)?);
        }
        Ok(out)
    }

    /// Directory entries of the directory whose chain starts at `first`, plus the
    /// device offset of each short entry (writes need to find the record again).
    fn read_dir(&mut self, first: u32) -> Result<Vec<(DirEnt, Found)>> {
        let clusters = self.chain(first)?;
        let mut out = Vec::new();
        let mut lfn: Vec<(u8, String)> = Vec::new();
        for c in clusters {
            let base = self.cluster_off(c)?;
            let csize = self.cluster_bytes() as usize;
            let buf = read_vec(self.dev, base, csize)?;
            for (i, e) in buf.chunks_exact(32).enumerate() {
                let at = base + (i as u64) * 32;
                match e[0] {
                    0x00 => return Ok(out), // end of directory
                    0xE5 => {
                        lfn.clear();
                        continue;
                    }
                    _ => {}
                }
                if e[11] == ATTR_LFN {
                    // Long-name fragment: sequence number in the low 5 bits.
                    let seq = e[0] & 0x1F;
                    lfn.push((seq, lfn_fragment(e)));
                    continue;
                }
                if e[11] & ATTR_VOLUME_ID != 0 {
                    lfn.clear();
                    continue;
                }
                let name = if lfn.is_empty() {
                    short_name(e)
                } else {
                    lfn.sort_by_key(|(s, _)| *s);
                    let joined: String = lfn.iter().map(|(_, s)| s.as_str()).collect();
                    joined.trim_end_matches('\u{ffff}').trim().to_string()
                };
                lfn.clear();
                if name == "." || name == ".." || name.is_empty() {
                    continue;
                }
                let first_cluster = (u32::from(le16(e, 20)) << 16) | u32::from(le16(e, 26));
                let size = le32(e, 28);
                let found = Found {
                    entry_at: at,
                    first_cluster,
                    size,
                    attr: e[11],
                };
                out.push((
                    DirEnt {
                        name,
                        dir: found.is_dir(),
                        size: u64::from(size),
                        read_only: e[11] & ATTR_READ_ONLY != 0,
                        hidden: e[11] & (ATTR_HIDDEN | ATTR_SYSTEM) != 0,
                    },
                    found,
                ));
            }
        }
        Ok(out)
    }

    fn volume_label(&mut self) -> Result<String> {
        let root = self.root_cluster;
        for c in self.chain(root)? {
            let base = self.cluster_off(c)?;
            let csize = self.cluster_bytes() as usize;
            let buf = read_vec(self.dev, base, csize)?;
            for e in buf.chunks_exact(32) {
                if e[0] == 0 {
                    return Ok(String::new());
                }
                if e[0] != 0xE5 && e[11] & ATTR_VOLUME_ID != 0 && e[11] != ATTR_LFN {
                    return Ok(String::from_utf8_lossy(&e[0..11]).trim().to_string());
                }
            }
        }
        Ok(String::new())
    }

    /// Resolve a path to its directory record. `None` = the root directory.
    fn find(&mut self, path: &str) -> Result<Option<Found>> {
        let parts = crate::split_path(path);
        if parts.is_empty() {
            return Ok(None);
        }
        let mut dir = self.root_cluster;
        let mut cur: Option<Found> = None;
        for (i, part) in parts.iter().enumerate() {
            let ents = self.read_dir(dir)?;
            let hit = ents
                .into_iter()
                .find(|(d, _)| d.name.eq_ignore_ascii_case(part))
                .map(|(_, f)| f)
                .ok_or_else(|| Error::NotFoundPath(path.to_string()))?;
            let last = i + 1 == parts.len();
            if !last {
                if !hit.is_dir() {
                    return Err(Error::NotADir(part.to_string()));
                }
                dir = hit.first_cluster;
            }
            cur = Some(hit);
        }
        Ok(cur)
    }

    /// [`find`](Self::find) where "no such path" is `None` rather than an error —
    /// what a create needs to know.
    fn find_opt(&mut self, path: &str) -> Result<Option<Found>> {
        match self.find(path) {
            Ok(f) => Ok(f),
            Err(Error::NotFoundPath(_)) => Ok(None),
            Err(e) => Err(e),
        }
    }

    /// The directory a path lives in, as a starting cluster.
    fn parent_cluster(&mut self, path: &str) -> Result<u32> {
        let parts = crate::split_path(path);
        if parts.len() <= 1 {
            return Ok(self.root_cluster);
        }
        let parent = parts[..parts.len() - 1].join("/");
        match self.find(&parent)? {
            Some(f) if f.is_dir() => Ok(f.first_cluster),
            Some(_) => Err(Error::NotADir(parent)),
            None => Ok(self.root_cluster),
        }
    }

    /// Point a directory record at a new chain and size.
    fn set_record(&mut self, at: u64, first_cluster: u32, size: u32) -> Result<()> {
        self.dev
            .write_at(at + 20, &((first_cluster >> 16) as u16).to_le_bytes())?;
        self.dev
            .write_at(at + 26, &((first_cluster & 0xFFFF) as u16).to_le_bytes())?;
        self.dev.write_at(at + 28, &size.to_le_bytes())
    }

    /// Write `data` into an allocated chain, zero-filling the tail cluster.
    fn fill_chain(&mut self, clusters: &[u32], data: &[u8]) -> Result<()> {
        let csize = self.cluster_bytes() as usize;
        for (i, c) in clusters.iter().enumerate() {
            let off = self.cluster_off(*c)?;
            let start = i * csize;
            let end = (start + csize).min(data.len());
            let mut buf = vec![0u8; csize];
            if start < data.len() {
                buf[..end - start].copy_from_slice(&data[start..end]);
            }
            self.dev.write_at(off, &buf)?;
        }
        Ok(())
    }

    /// Every 32-byte slot of a directory, as `(offset, first byte)`.
    fn dir_slots(&mut self, dir_first: u32) -> Result<Vec<(u64, u8)>> {
        let csize = self.cluster_bytes() as usize;
        let mut out = Vec::new();
        for c in self.chain(dir_first)? {
            let base = self.cluster_off(c)?;
            let buf = read_vec(self.dev, base, csize)?;
            for (i, e) in buf.chunks_exact(32).enumerate() {
                out.push((base + (i as u64) * 32, e[0]));
            }
        }
        Ok(out)
    }

    /// Add a directory record, with a VFAT long-name chain when the name is not
    /// an 8.3 one.
    ///
    /// Long names matter here for one concrete reason: the removable-media UEFI
    /// path is `\EFI\BOOT\BOOTRISCV64.EFI`, which is 11 characters of basename. A
    /// driver that can only write 8.3 cannot create the file edk2 looks for, so it
    /// could not repair an ESP at all.
    fn add_record(&mut self, dir_first: u32, name: &str, attr: u8) -> Result<u64> {
        if !name.is_ascii() || name.is_empty() {
            return Err(Error::BadName(format!(
                "`{name}`: this driver writes ASCII names"
            )));
        }
        let short = match to_short_name(name) {
            Ok(s) => s,
            Err(_) => {
                let existing: Vec<String> = self
                    .read_dir(dir_first)?
                    .into_iter()
                    .map(|(d, _)| d.name)
                    .collect();
                short_alias(name, &existing)?
            }
        };
        // How many LFN entries: 13 UTF-16 units each, and none at all when the
        // short name *is* the name.
        let long = short_name(&{
            let mut probe = [0u8; 12];
            probe[..11].copy_from_slice(&short);
            probe
        }) != name.to_lowercase();
        let units: Vec<u16> = name.encode_utf16().collect();
        let lfn_count = if long { units.len().div_ceil(13) } else { 0 };
        let need = lfn_count + 1;
        // A run of `need` free slots, in one directory (contiguity is what the
        // LFN chain requires — the entries must precede their short entry).
        let slots = self.dir_slots(dir_first)?;
        let mut start: Option<usize> = None;
        let mut run = 0usize;
        for (i, (_, first)) in slots.iter().enumerate() {
            if *first == 0x00 || *first == 0xE5 {
                run += 1;
                if run == need {
                    start = Some(i + 1 - need);
                    break;
                }
            } else {
                run = 0;
            }
        }
        let base_slots: Vec<u64> = match start {
            Some(s) => slots[s..s + need].iter().map(|(off, _)| *off).collect(),
            None => {
                // Grow the directory by a cluster; a fresh cluster is all free, so
                // the run fits as long as a cluster holds `need` slots.
                let csize = self.cluster_bytes() as usize;
                if need * 32 > csize {
                    return Err(Error::BadName(format!(
                        "`{name}` needs {need} directory slots, more than one cluster holds"
                    )));
                }
                let extra = self.alloc_chain(1)?;
                let clusters = self.chain(dir_first)?;
                let last = *clusters.last().ok_or(Error::Corrupt("fat32: empty dir"))?;
                self.fat_set(last, extra[0])?;
                let base = self.cluster_off(extra[0])?;
                self.dev.write_at(base, &vec![0u8; csize])?;
                (0..need).map(|i| base + (i as u64) * 32).collect()
            }
        };
        // LFN entries come first, in reverse order, then the short entry.
        let checksum = lfn_checksum(&short);
        for (i, slot_at) in base_slots.iter().enumerate().take(lfn_count) {
            let seq = lfn_count - i; // 1-based, and the *last* chunk is written first
            let chunk = &units[(seq - 1) * 13..(seq * 13).min(units.len())];
            let mut e = [0xFFu8; 32];
            e[0] = seq as u8 | if i == 0 { 0x40 } else { 0 };
            e[11] = ATTR_LFN;
            e[12] = 0;
            e[13] = checksum;
            e[26] = 0;
            e[27] = 0;
            let mut put = |slot: usize, v: u16| {
                let at = match slot {
                    0..=4 => 1 + slot * 2,
                    5..=10 => 14 + (slot - 5) * 2,
                    _ => 28 + (slot - 11) * 2,
                };
                e[at..at + 2].copy_from_slice(&v.to_le_bytes());
            };
            for slot in 0..13 {
                match chunk.get(slot) {
                    Some(u) => put(slot, *u),
                    // One NUL terminator, then 0xFFFF padding — what a formatter
                    // writes, and what readers expect to stop at.
                    None if slot == chunk.len() => put(slot, 0),
                    None => put(slot, 0xFFFF),
                }
            }
            self.dev.write_at(*slot_at, &e)?;
        }
        let at = base_slots[need - 1];
        let mut rec = [0u8; 32];
        rec[0..11].copy_from_slice(&short);
        rec[11] = attr;
        stamp(&mut rec);
        self.dev.write_at(at, &rec)?;
        Ok(at)
    }

    fn need_rw(&self) -> Result<()> {
        if self.rw {
            Ok(())
        } else {
            Err(Error::ReadOnly("mount"))
        }
    }
}

impl FileSystem for Fat32<'_> {
    fn kind(&self) -> FsKind {
        FsKind::Fat32
    }

    fn label(&self) -> String {
        self.label.clone()
    }

    fn writable(&self) -> bool {
        self.rw
    }

    fn list(&mut self, path: &str) -> Result<Vec<DirEnt>> {
        let first = match self.find(path)? {
            None => self.root_cluster,
            Some(f) if f.is_dir() => f.first_cluster,
            Some(_) => return Err(Error::NotADir(path.to_string())),
        };
        let mut out: Vec<DirEnt> = self.read_dir(first)?.into_iter().map(|(d, _)| d).collect();
        out.sort_by(|a, b| (b.dir, a.name.to_lowercase()).cmp(&(a.dir, b.name.to_lowercase())));
        Ok(out)
    }

    fn stat(&mut self, path: &str) -> Result<Stat> {
        match self.find(path)? {
            None => Ok(Stat {
                dir: true,
                size: 0,
                read_only: false,
            }),
            Some(f) => Ok(Stat {
                dir: f.is_dir(),
                size: u64::from(f.size),
                read_only: f.attr & ATTR_READ_ONLY != 0,
            }),
        }
    }

    fn read_window(&mut self, path: &str, off: u64, len: usize) -> Result<Vec<u8>> {
        let f = self
            .find(path)?
            .ok_or_else(|| Error::NotFoundPath(path.to_string()))?;
        if f.is_dir() {
            return Err(Error::IsADir(path.to_string()));
        }
        let end = off.saturating_add(len as u64).min(u64::from(f.size));
        if off >= u64::from(f.size) {
            return Ok(Vec::new());
        }
        let all = self.read_chain(f.first_cluster, end)?;
        let start = off as usize;
        Ok(all[start.min(all.len())..].to_vec())
    }

    fn read(&mut self, path: &str) -> Result<Vec<u8>> {
        let f = self
            .find(path)?
            .ok_or_else(|| Error::NotFoundPath(path.to_string()))?;
        if f.is_dir() {
            return Err(Error::IsADir(path.to_string()));
        }
        if f.first_cluster == 0 || f.size == 0 {
            return Ok(Vec::new());
        }
        self.read_chain(f.first_cluster, u64::from(f.size))
    }

    /// FAT32 can create, grow and shrink, so the bound is the volume: what the file
    /// already holds plus what is free. The free count is *counted*, not taken from
    /// the FSInfo hint — that hint is advisory and an OS is allowed to leave it
    /// stale, and a budget an editor trusts must not be a guess.
    fn edit_budget(&mut self, path: &str) -> Result<crate::EditBudget> {
        let found = self.find_opt(path)?;
        let (exists, size, own) = match found {
            Some(f) if f.is_dir() => {
                return Ok(crate::EditBudget::refused(
                    FsKind::Fat32,
                    0,
                    true,
                    format!("{path} is a directory"),
                ))
            }
            Some(f) if f.attr & ATTR_READ_ONLY != 0 => {
                return Ok(crate::EditBudget::refused(
                    FsKind::Fat32,
                    u64::from(f.size),
                    true,
                    format!("{path} has the FAT read-only attribute"),
                ))
            }
            Some(f) => {
                let clusters = if f.first_cluster >= 2 {
                    self.chain(f.first_cluster)?.len() as u64
                } else {
                    0
                };
                (true, u64::from(f.size), clusters * self.cluster_bytes())
            }
            None => (false, 0, 0),
        };
        if !self.rw {
            return Ok(crate::EditBudget::refused(
                FsKind::Fat32,
                size,
                exists,
                "mounted read-only (`mount -w` to write)",
            ));
        }
        let mut free = 0u64;
        for c in 2..self.total_clusters + 2 {
            if self.fat_get(c)? == FREE {
                free += 1;
            }
        }
        Ok(crate::EditBudget {
            fs: FsKind::Fat32,
            exists,
            size,
            writable: true,
            max_bytes: Some(own + free * self.cluster_bytes()),
            can_create: true,
            can_grow: true,
            why: None,
        })
    }

    fn write(&mut self, path: &str, data: &[u8]) -> Result<()> {
        self.need_rw()?;
        let csize = self.cluster_bytes();
        let need =
            u32::try_from(data.len().div_ceil(csize as usize)).map_err(|_| Error::NoSpace)?;
        // A path that is not there yet is the create case, not a failure.
        match self.find_opt(path)? {
            Some(f) if f.is_dir() => Err(Error::IsADir(path.to_string())),
            Some(f) => {
                if f.attr & ATTR_READ_ONLY != 0 {
                    return Err(Error::ReadOnly("file has the read-only attribute"));
                }
                // Replace the contents: free the old chain, allocate the new one.
                // Doing it in this order keeps the free count right even if the
                // new size is larger than what is free elsewhere.
                if f.first_cluster >= 2 {
                    self.free_chain(f.first_cluster)?;
                }
                let clusters = self.alloc_chain(need)?;
                self.fill_chain(&clusters, data)?;
                let first = clusters.first().copied().unwrap_or(0);
                self.set_record(f.entry_at, first, data.len() as u32)?;
                self.dev.flush()
            }
            None => {
                let parts = crate::split_path(path);
                let name = parts.last().ok_or(Error::IsADir("/".into()))?.clone();
                let dir = self.parent_cluster(path)?;
                let clusters = self.alloc_chain(need)?;
                self.fill_chain(&clusters, data)?;
                let at = self.add_record(dir, &name, 0x20)?;
                let first = clusters.first().copied().unwrap_or(0);
                self.set_record(at, first, data.len() as u32)?;
                self.dev.flush()
            }
        }
    }

    fn mkdir(&mut self, path: &str) -> Result<()> {
        self.need_rw()?;
        if self.find_opt(path)?.is_some() {
            return Err(Error::Exists(path.to_string()));
        }
        let parts = crate::split_path(path);
        let name = parts.last().ok_or(Error::IsADir("/".into()))?.clone();
        let parent = self.parent_cluster(path)?;
        let clusters = self.alloc_chain(1)?;
        let base = self.cluster_off(clusters[0])?;
        let csize = self.cluster_bytes() as usize;
        let mut buf = vec![0u8; csize];
        // `.` and `..`, as every FAT directory must have.
        buf[0..11].copy_from_slice(b".          ");
        buf[11] = ATTR_DIR;
        buf[20..22].copy_from_slice(&((clusters[0] >> 16) as u16).to_le_bytes());
        buf[26..28].copy_from_slice(&((clusters[0] & 0xFFFF) as u16).to_le_bytes());
        buf[32..43].copy_from_slice(b"..         ");
        buf[43] = ATTR_DIR;
        let up = if parent == self.root_cluster {
            0
        } else {
            parent
        };
        buf[52..54].copy_from_slice(&((up >> 16) as u16).to_le_bytes());
        buf[58..60].copy_from_slice(&((up & 0xFFFF) as u16).to_le_bytes());
        self.dev.write_at(base, &buf)?;
        let at = self.add_record(parent, &name, ATTR_DIR)?;
        self.set_record(at, clusters[0], 0)?;
        self.dev.flush()
    }

    fn remove(&mut self, path: &str) -> Result<()> {
        self.need_rw()?;
        let f = self
            .find(path)?
            .ok_or_else(|| Error::NotFoundPath(path.to_string()))?;
        if f.is_dir() {
            // Only an empty directory: silently orphaning a subtree is how a
            // repair tool destroys a system.
            if !self.read_dir(f.first_cluster)?.is_empty() {
                return Err(Error::NotEmpty(path.to_string()));
            }
        }
        if f.first_cluster >= 2 {
            self.free_chain(f.first_cluster)?;
        }
        self.dev.write_at(f.entry_at, &[0xE5])?;
        self.dev.flush()
    }
}

/// The UTF-16 pieces of one long-name fragment (5 + 6 + 2 code units).
fn lfn_fragment(e: &[u8]) -> String {
    let mut s = String::new();
    let mut push = |lo: usize, hi: usize| {
        for pair in e[lo..hi].chunks_exact(2) {
            let c = u16::from_le_bytes([pair[0], pair[1]]);
            if c == 0 || c == 0xFFFF {
                return;
            }
            s.push(char::from_u32(u32::from(c)).unwrap_or('?'));
        }
    };
    push(1, 11);
    push(14, 26);
    push(28, 32);
    s
}

/// `NAME    EXT` → `name.ext`.
fn short_name(e: &[u8]) -> String {
    let base = String::from_utf8_lossy(&e[0..8]).trim_end().to_string();
    let ext = String::from_utf8_lossy(&e[8..11]).trim_end().to_string();
    let name = if ext.is_empty() {
        base
    } else {
        format!("{base}.{ext}")
    };
    // A leading 0x05 stands for 0xE5 in the first byte (KANJI escape).
    name.replace('\u{5}', "\u{e5}").to_lowercase()
}

/// Creation/write/access date on a new directory record.
///
/// A BIOS has no wall clock it can trust: OpenSBI gives it a monotonic counter,
/// not a date. So rather than leave the field zero — which `mdir` prints as
/// `1980-00-00` and some tools reject — the record carries the **epoch of the
/// format itself**, 1980-01-01, which is the honest "unknown date" for FAT. When a
/// board gains an RTC this is the one place to change.
fn stamp(rec: &mut [u8; 32]) {
    // FAT date: bits 15..9 year-1980, 8..5 month, 4..0 day. Time: 15..11 hour,
    // 10..5 minute, 4..0 seconds/2. 1980-01-01 00:00:00 is year 0, month 1, day 1
    // → 0x0021, and time 0.
    const DATE_1980_01_01: u16 = (1 << 5) | 1;
    rec[13] = 0; // creation time, 10ms units
    rec[14..16].copy_from_slice(&0u16.to_le_bytes()); // creation time
    rec[16..18].copy_from_slice(&DATE_1980_01_01.to_le_bytes()); // creation date
    rec[18..20].copy_from_slice(&DATE_1980_01_01.to_le_bytes()); // access date
    rec[22..24].copy_from_slice(&0u16.to_le_bytes()); // write time
    rec[24..26].copy_from_slice(&DATE_1980_01_01.to_le_bytes()); // write date
}

/// The VFAT long-name checksum over the 11-byte short name. Readers use it to
/// tell whether an LFN chain still belongs to the short entry behind it.
fn lfn_checksum(short: &[u8; 11]) -> u8 {
    let mut sum = 0u8;
    for b in short {
        sum = ((sum & 1) << 7).wrapping_add(sum >> 1).wrapping_add(*b);
    }
    sum
}

/// A `BOOTRI~1.EFI`-style alias for a long name, unique among `existing`.
fn short_alias(name: &str, existing: &[String]) -> Result<[u8; 11]> {
    let (base, ext) = match name.rsplit_once('.') {
        Some((b, e)) => (b, e),
        None => (name, ""),
    };
    let keep = |s: &str, n: usize| -> Vec<u8> {
        s.bytes()
            .filter(|c| c.is_ascii_alphanumeric() || matches!(c, b'-' | b'_'))
            .map(|c| c.to_ascii_uppercase())
            .take(n)
            .collect()
    };
    let stem = keep(base, 6);
    if stem.is_empty() {
        return Err(Error::BadName(format!("`{name}` has no usable characters")));
    }
    let e = keep(ext, 3);
    for n in 1..=9u8 {
        let mut out = [b' '; 11];
        out[..stem.len()].copy_from_slice(&stem);
        out[stem.len()] = b'~';
        out[stem.len() + 1] = b'0' + n;
        for (i, c) in e.iter().enumerate() {
            out[8 + i] = *c;
        }
        let as_name = {
            let mut probe = [0u8; 12];
            probe[..11].copy_from_slice(&out);
            short_name(&probe)
        };
        if !existing.iter().any(|x| x.eq_ignore_ascii_case(&as_name)) {
            return Ok(out);
        }
    }
    Err(Error::BadName(format!(
        "`{name}`: no free ~N short alias in this directory"
    )))
}

/// Build an 8.3 record name. A longer name is *not* an error here — the caller
/// falls back to a long-name chain with a `~N` alias — but silently truncating
/// into a different file than the operator typed would be.
fn to_short_name(name: &str) -> Result<[u8; 11]> {
    // `.` and `..` are the directory's own entries; a file called `..` would make
    // the tree unwalkable, and a name of only dots/spaces is not a name.
    if name.chars().all(|c| c == '.' || c == ' ') {
        return Err(Error::BadName(format!(
            "`{name}` is not a usable file name"
        )));
    }
    let (base, ext) = match name.rsplit_once('.') {
        Some((b, e)) => (b, e),
        None => (name, ""),
    };
    if base.is_empty() || base.len() > 8 || ext.len() > 3 || !name.is_ascii() {
        return Err(Error::BadName(format!(
            "`{name}` is not an 8.3 name; this driver writes short names only"
        )));
    }
    let mut out = [b' '; 11];
    for (i, c) in base.bytes().enumerate() {
        out[i] = c.to_ascii_uppercase();
    }
    for (i, c) in ext.bytes().enumerate() {
        out[8 + i] = c.to_ascii_uppercase();
    }
    Ok(out)
}

/// A formatted-from-scratch FAT32 volume: BPB, two FATs, FSInfo, an empty
/// root. Small on purpose (cluster = 1 sector) so chains are easy to reason
/// about, and large enough that the cluster count is a legal FAT32 one for
/// *this driver* (which does not care about the 65525 minimum a formatter
/// would enforce).
pub fn fixture(sectors: u32) -> MemBlock {
    let bps = 512u32;
    let spc = 1u32;
    let reserved = 32u32;
    let num_fats = 2u32;
    // One FAT sector maps 128 clusters; size the FATs to the volume so a
    // small test image is still a legal layout.
    let fat_sectors = (sectors / 128).clamp(1, 64);
    let root_cluster = 2u32;
    let mut d = vec![0u8; (sectors * bps) as usize];
    d[0..3].copy_from_slice(&[0xEB, 0x58, 0x90]);
    d[3..11].copy_from_slice(b"g6lcbios");
    d[11..13].copy_from_slice(&(bps as u16).to_le_bytes());
    d[13] = spc as u8;
    d[14..16].copy_from_slice(&(reserved as u16).to_le_bytes());
    d[16] = num_fats as u8;
    d[32..36].copy_from_slice(&sectors.to_le_bytes());
    d[36..40].copy_from_slice(&fat_sectors.to_le_bytes());
    d[44..48].copy_from_slice(&root_cluster.to_le_bytes());
    d[48..50].copy_from_slice(&1u16.to_le_bytes()); // FSInfo at sector 1
    d[71..82].copy_from_slice(b"G6LCTEST   ");
    d[82..90].copy_from_slice(b"FAT32   ");
    d[510] = 0x55;
    d[511] = 0xAA;
    // FSInfo.
    let fsi = bps as usize;
    d[fsi..fsi + 4].copy_from_slice(&0x4161_5252u32.to_le_bytes());
    d[fsi + 484..fsi + 488].copy_from_slice(&0x6141_7272u32.to_le_bytes());
    let data_sectors = sectors - (reserved + num_fats * fat_sectors);
    d[fsi + 488..fsi + 492].copy_from_slice(&(data_sectors - 1).to_le_bytes());
    // FAT: entries 0 and 1 are reserved, 2 is the root's end-of-chain.
    for copy in 0..num_fats {
        let at = ((reserved + copy * fat_sectors) * bps) as usize;
        d[at..at + 4].copy_from_slice(&0x0FFF_FFF8u32.to_le_bytes());
        d[at + 4..at + 8].copy_from_slice(&0xFFFF_FFFFu32.to_le_bytes());
        d[at + 8..at + 12].copy_from_slice(&0x0FFF_FFFFu32.to_le_bytes());
    }
    MemBlock::new(d)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mount_reads_the_bpb_and_the_label() {
        let mut dev = fixture(4096);
        let fs = Fat32::mount(&mut dev, true).unwrap();
        assert_eq!(fs.kind(), FsKind::Fat32);
        assert_eq!(fs.label(), "G6LCTEST");
        assert!(fs.writable());
        assert_eq!(fs.cluster_bytes(), 512);
        // A garbage device is refused, not half-mounted.
        let mut junk = MemBlock::zeroed(4096);
        assert!(Fat32::mount(&mut junk, true).is_err());
    }

    #[test]
    fn write_read_grow_shrink_and_delete_a_file() {
        let mut dev = fixture(4096);
        let mut fs = Fat32::mount(&mut dev, true).unwrap();
        assert!(fs.list("/").unwrap().is_empty());
        // Create, spanning several clusters (512-byte clusters here).
        let big = vec![b'A'; 1500];
        fs.write("/FSTAB.CFG", &big).unwrap();
        let ents = fs.list("/").unwrap();
        assert_eq!(ents.len(), 1);
        assert_eq!(ents[0].name, "fstab.cfg");
        assert_eq!(ents[0].size, 1500);
        assert_eq!(fs.read("/FSTAB.CFG").unwrap(), big);
        // A window read is a window, not the whole file.
        assert_eq!(fs.read_window("/fstab.cfg", 1000, 8).unwrap().len(), 8);
        // Shrink: the freed clusters come back to the free count.
        fs.write("/fstab.cfg", b"small").unwrap();
        assert_eq!(fs.read("/fstab.cfg").unwrap(), b"small");
        assert_eq!(fs.stat("/fstab.cfg").unwrap().size, 5);
        // Grow again, then delete.
        let bigger = vec![b'B'; 4096];
        fs.write("/fstab.cfg", &bigger).unwrap();
        assert_eq!(fs.read("/fstab.cfg").unwrap().len(), 4096);
        fs.remove("/fstab.cfg").unwrap();
        assert!(fs.list("/").unwrap().is_empty());
        // The FAT copies agree — an OS reading the second FAT sees our chain.
        // The offsets come from the BPB, not from what the fixture happened to
        // choose, so this stays true if the layout changes.
        let bytes = dev.bytes().to_vec();
        let bps = usize::from(le16(&bytes, 11));
        let reserved = usize::from(le16(&bytes, 14));
        let fat_sectors = le32(&bytes, 36) as usize;
        let fat0 = reserved * bps;
        let fat1 = (reserved + fat_sectors) * bps;
        assert_eq!(
            &bytes[fat0..fat0 + 256],
            &bytes[fat1..fat1 + 256],
            "both FAT copies must be written"
        );
    }

    #[test]
    fn directories_nest_and_paths_resolve() {
        let mut dev = fixture(8192);
        let mut fs = Fat32::mount(&mut dev, true).unwrap();
        fs.mkdir("/EFI").unwrap();
        fs.mkdir("/EFI/BOOT").unwrap();
        fs.write(
            "/EFI/BOOT/STARTUP.NSH",
            b"fs0:\\EFI\\BOOT\\BOOTRISCV64.EFI\n",
        )
        .unwrap();
        let root = fs.list("/").unwrap();
        assert_eq!(root.len(), 1);
        assert!(root[0].dir && root[0].name == "efi");
        let boot = fs.list("/efi/boot").unwrap();
        assert_eq!(boot.len(), 1);
        assert_eq!(boot[0].name, "startup.nsh");
        assert!(fs
            .read("/EFI/BOOT/startup.nsh")
            .unwrap()
            .starts_with(b"fs0:"));
        // A file in the middle of a path is not a directory.
        assert!(matches!(
            fs.list("/efi/boot/startup.nsh/x"),
            Err(Error::NotADir(_))
        ));
        // A non-empty directory is not silently orphaned.
        assert!(matches!(fs.remove("/efi/boot"), Err(Error::NotEmpty(_))));
        fs.remove("/efi/boot/startup.nsh").unwrap();
        fs.remove("/efi/boot").unwrap();
        assert!(fs.list("/efi").unwrap().is_empty());
    }

    #[test]
    fn a_read_only_mount_refuses_every_write_path() {
        let mut dev = fixture(4096);
        {
            let mut rw = Fat32::mount(&mut dev, true).unwrap();
            rw.write("/A.TXT", b"x").unwrap();
        }
        let mut fs = Fat32::mount(&mut dev, false).unwrap();
        assert!(!fs.writable());
        assert_eq!(fs.read("/a.txt").unwrap(), b"x");
        for e in [
            fs.write("/a.txt", b"y").unwrap_err(),
            fs.mkdir("/d").unwrap_err(),
            fs.remove("/a.txt").unwrap_err(),
        ] {
            assert!(matches!(e, Error::ReadOnly(_)), "{e:?}");
        }
        // …and the file did not change.
        assert_eq!(fs.read("/a.txt").unwrap(), b"x");
    }

    #[test]
    fn a_full_volume_refuses_rather_than_corrupting() {
        // 40 data sectors → tiny. Ask for more than exists.
        let mut dev = fixture(32 + 2 * 4 + 40);
        let mut fs = Fat32::mount(&mut dev, true).unwrap();
        let err = fs.write("/BIG.BIN", &vec![0u8; 64 * 512]).unwrap_err();
        assert!(matches!(err, Error::NoSpace), "{err:?}");
        // Nothing was left half-written.
        assert!(fs.list("/").unwrap().is_empty());
    }

    /// The name that matters: `\EFI\BOOT\BOOTRISCV64.EFI` is 11 characters of
    /// basename, so an 8.3-only writer could never repair an ESP.
    #[test]
    fn long_names_are_written_with_an_lfn_chain_and_read_back() {
        let mut dev = fixture(8192);
        let mut fs = Fat32::mount(&mut dev, true).unwrap();
        fs.mkdir("/EFI").unwrap();
        fs.mkdir("/EFI/BOOT").unwrap();
        fs.write("/EFI/BOOT/BOOTRISCV64.EFI", b"MZ\x00\x00loader")
            .unwrap();
        let ents = fs.list("/EFI/BOOT").unwrap();
        assert_eq!(ents.len(), 1);
        // A long name keeps the case it was created with; only 8.3 short names
        // are case-folded.
        assert_eq!(ents[0].name, "BOOTRISCV64.EFI", "{ents:?}");
        assert_eq!(
            fs.read("/EFI/BOOT/BOOTRISCV64.EFI").unwrap(),
            b"MZ\x00\x00loader"
        );
        // The short alias behind it is a legal 8.3 name with a ~N tail.
        let raw = {
            let dir = fs.find("/EFI/BOOT").unwrap().unwrap();
            let base = fs.cluster_off(dir.first_cluster).unwrap();
            // Five slots: ., .., two LFN chunks for a 15-character name, then
            // the short entry.
            read_vec(fs.dev, base, 256).unwrap()
        };
        // `.` and `..` come first in any subdirectory; the LFN chain sits after
        // them and immediately before its short entry.
        let lfn_at = raw
            .chunks_exact(32)
            .position(|e| e[11] == ATTR_LFN)
            .expect("an LFN chain precedes the short entry");
        assert_eq!(
            raw[lfn_at * 32] & 0x40,
            0x40,
            "the last chunk carries the end flag and is written first"
        );
        let short_at = raw
            .chunks_exact(32)
            .skip(lfn_at)
            .position(|e| e[11] != ATTR_LFN && e[0] != 0)
            .map(|p| p + lfn_at)
            .expect("a short entry");
        let short = &raw[short_at * 32..short_at * 32 + 11];
        assert!(
            short.starts_with(b"BOOTRI~1"),
            "{:?}",
            String::from_utf8_lossy(short)
        );
        assert_eq!(&short[8..11], b"EFI");
        assert_eq!(
            lfn_checksum(&short.try_into().unwrap()),
            raw[lfn_at * 32 + 13],
            "the LFN checksum must match its short entry"
        );
        // A second long name in the same directory gets ~2, not a collision.
        fs.write("/EFI/BOOT/BOOTRISCV64.EF2", b"x").unwrap();
        let ents = fs.list("/EFI/BOOT").unwrap();
        assert_eq!(ents.len(), 2, "{ents:?}");
        assert!(ents.iter().any(|e| e.name == "BOOTRISCV64.EF2"), "{ents:?}");
        // Overwriting through the long name finds the same file, not a new one.
        fs.write("/EFI/BOOT/BOOTRISCV64.EFI", b"second").unwrap();
        assert_eq!(fs.list("/EFI/BOOT").unwrap().len(), 2);
        assert_eq!(fs.read("/EFI/BOOT/bootriscv64.efi").unwrap(), b"second");
        // A name with nothing usable in it is still refused.
        assert!(matches!(fs.write("/...", b"x"), Err(Error::BadName(_))));
    }

    /// A new record carries a legal date rather than a zero one. The BIOS has no
    /// clock, so it writes the FAT epoch — `1980-01-01` — which is what "unknown"
    /// looks like in this format.
    #[test]
    fn new_records_get_a_legal_date_not_a_zero_one() {
        let mut dev = fixture(4096);
        let mut fs = Fat32::mount(&mut dev, true).unwrap();
        fs.write("/BOOT.CFG", b"x").unwrap();
        let root = fs.cluster_off(2).unwrap();
        let rec = read_vec(fs.dev, root, 32).unwrap();
        let date = le16(&rec, 24);
        assert_ne!(
            date, 0,
            "a zero write date is what tools print as 1980-00-00"
        );
        assert_eq!(date >> 9, 0, "year 1980");
        assert_eq!((date >> 5) & 0xF, 1, "month 1");
        assert_eq!(date & 0x1F, 1, "day 1");
        assert_eq!(le16(&rec, 16), date, "creation date matches");
        assert_eq!(le16(&rec, 18), date, "access date matches");
    }

    #[test]
    fn vfat_long_names_are_read() {
        let mut dev = fixture(4096);
        let mut fs = Fat32::mount(&mut dev, true).unwrap();
        fs.write("/GRUB.CFG", b"menuentry\n").unwrap();
        // Hand-write an LFN pair in front of the short entry, the way Windows
        // and mkfs tools do, and check the long name is what `ls` shows.
        let root = fs.cluster_off(2).unwrap();
        let short = read_vec(fs.dev, root, 32).unwrap();
        let mut lfn = [0u8; 32];
        lfn[0] = 0x41; // sequence 1 | last
        lfn[11] = ATTR_LFN;
        for (i, ch) in "grub.cfg.long".encode_utf16().take(5).enumerate() {
            lfn[1 + i * 2..3 + i * 2].copy_from_slice(&ch.to_le_bytes());
        }
        for (i, ch) in "grub.cfg.long".encode_utf16().skip(5).take(6).enumerate() {
            lfn[14 + i * 2..16 + i * 2].copy_from_slice(&ch.to_le_bytes());
        }
        for (i, ch) in "grub.cfg.long".encode_utf16().skip(11).take(2).enumerate() {
            lfn[28 + i * 2..30 + i * 2].copy_from_slice(&ch.to_le_bytes());
        }
        fs.dev.write_at(root, &lfn).unwrap();
        fs.dev.write_at(root + 32, &short).unwrap();
        let ents = fs.list("/").unwrap();
        assert_eq!(ents.len(), 1);
        assert_eq!(ents[0].name, "grub.cfg.long");
    }
    /// Writing into a **subdirectory** the driver just made: mkdir then a create
    /// one level down. A store keeps its dump at stores/<purpose>, so a writer
    /// that only handles the root would refuse every real persist path.
    #[test]
    fn a_file_can_be_created_inside_a_directory_we_made() {
        let mut dev = fixture(4096);
        let mut fs = Fat32::mount(&mut dev, true).unwrap();
        fs.mkdir("/stores").unwrap();
        fs.write("/stores/registry", b"{}").unwrap();
        assert_eq!(fs.read("/stores/registry").unwrap(), b"{}");
        let names: Vec<String> = fs
            .list("/stores")
            .unwrap()
            .into_iter()
            .map(|e| e.name)
            .collect();
        assert!(
            names.iter().any(|n| n.eq_ignore_ascii_case("registry")),
            "{names:?}"
        );
    }
}
