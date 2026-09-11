// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! btrfs — read, plus a deliberately narrow write.
//!
//! btrfs is a copy-on-write B-tree filesystem: nothing is where the table of
//! contents said it was last time, and every block answers for itself with a
//! checksum. The on-disk contract (fs/btrfs/btrfs_tree.h, docs "On-disk
//! Format"):
//!
//! * The superblock sits at 0x10000, magic `"_BHRfS_M"` at +0x40. It names the
//!   node size, the chunk tree root, the root tree root, and carries a bootstrap
//!   `sys_chunk_array` of chunk items so the chunk tree itself can be found.
//! * Everything is addressed **logically**; a chunk item maps
//!   `[logical, logical+len)` to a stripe on a device. Only single-stripe
//!   chunks are mapped — a RAID profile is refused rather than half-read.
//! * A node (nodesize bytes) is `{csum[32], fsid[16], bytenr, flags,
//!   chunk_tree_uuid, generation, owner, nritems, level}` — 101 bytes — then a
//!   leaf holds `item[n]` headers `{key(17), offset u32, size u32}` with the
//!   data packed **downward from the end of the node in key order**; an interior
//!   node holds `keyptr[n]` `{key, blockptr, generation}`.
//! * `csum` = raw `crc32c(seed=0, node[32..nodesize])` — the lib `crc32c`
//!   convention, no pre/post inversion — stored in the first four csum bytes.
//!   A node that fails it is reported corrupt, not silently parsed.
//! * The **root tree** holds `ROOT_ITEM`s naming where every other tree's root
//!   lives — the FS tree (objectid 5, the default subvolume) and the csum tree
//!   (objectid `-10`) among them. The FS tree then keys everything by
//!   `(objectid, type, offset)`: inodes are `INODE_ITEM`, name→inode is
//!   `DIR_ITEM` keyed by `crc32c(~1, name)` plus a `DIR_INDEX` for ordering, and
//!   file content is `EXTENT_DATA` — inline (the bytes live in the leaf) or
//!   regular (a `(disk_bytenr, disk_num_bytes, offset, num_bytes)` run).
//!
//! **Writing.** Even narrower than ext4's, because the cost of a wrong btrfs
//! write is a *tree*, not a file. Three operations, all leaf-level:
//!
//! * an existing regular file is overwritten **in place** inside the regular
//!   extents it already has — each written sector's entry in the **csum tree**
//!   is refreshed (an unchecksummed write is a filesystem error the moment the
//!   OS reads it back) and the inode's `i_size` is updated in its leaf;
//! * a file whose data lives in an **inline extent** is rewritten by replacing
//!   the extent item in its leaf — bounded by the inline cap and the leaf's
//!   free space;
//! * **create** (`write` on a missing path, `mkdir`) inserts the inode, inode
//!   ref, dir item/index and — for a file — an inline extent, the way btrfs
//!   creates small files anyway.
//!
//! What is *not* done: growing a file past its extents (that is extent-tree
//! allocation and backrefs — the OS's job), `remove` (unlink needs the same
//! bookkeeping in reverse), and anything on a multi-device or zoned volume.

#[cfg(test)]
use crate::block::MemBlock;
use crate::block::{le16, le32, le64, read_vec, BlockDev};
use crate::ext4::crc32c;
use crate::{split_path, DirEnt, EditBudget, Error, FileSystem, FsKind, Result, Stat};

/// Superblock location and the fields this driver uses.
const SB_OFF: u64 = 0x10000;
const MAGIC: &[u8; 8] = b"_BHRfS_M";
/// Node header: csum(32) fsid(16) bytenr flags uuid generation owner nritems level.
const HDR: usize = 101;
const ITEM_LEN: usize = 25; // key(17) + offset(4) + size(4)
const KEYPTR_LEN: usize = 33; // key(17) + blockptr(8) + generation(8)

// Object ids (fs/btrfs/btrfs_tree.h).
const FS_TREE: u64 = 5;
const CSUM_TREE: u64 = (-10i64) as u64; // BTRFS_EXTENT_CSUM_TREE_OBJECTID
const EXTENT_CSUM_OBJ: u64 = (-7i64) as u64; // BTRFS_EXTENT_CSUM_OBJECTID
const FIRST_FREE: u64 = 256; // first inode a subvolume hands out

// Item types.
const T_INODE: u8 = 1;
const T_INODE_REF: u8 = 12;
const T_DIR_ITEM: u8 = 84;
const T_DIR_INDEX: u8 = 96;
const T_EXTENT_DATA: u8 = 108;
const T_EXTENT_CSUM: u8 = 128;
const T_ROOT_ITEM: u8 = 132;
const T_DEV_EXTENT: u8 = 204;
const T_CHUNK_ITEM: u8 = 228;

// Dir-item file types (DT_*).
const FT_REG: u8 = 1;
const FT_DIR: u8 = 2;
const FT_LNK: u8 = 7;

// File extent types.
const EXT_INLINE: u8 = 0;
const EXT_REGULAR: u8 = 1;

const S_IFMT: u32 = 0xF000;
const S_IFDIR: u32 = 0o040000;
const S_IFREG: u32 = 0o100000;
const S_IFLNK: u32 = 0o120000;

/// `BTRFS_INODE_NODATASUM` — a nodatacow file carries no csum entries, so
/// updating them would mean *creating* structure the OS did not put there.
const INODE_NODATASUM: u64 = 0x01;

/// Incompat flags that make writing here unsafe: anything that changes where
/// bytes may live (zoned, extent-tree v2, the RAID stripe tree, raid1c3/4) or
/// what the fsid means (metadata_uuid).
const INCOMPAT_NO_WRITE: u64 = 0x400 | 0x800 | 0x1000 | 0x2000 | 0x4000;

/// Inline extents cap — `max_inline` defaults to 2048 and never exceeds half
/// the leaf's free space; both bounds are checked before a create.
const INLINE_CAP: usize = 2048;

/// btrfs checksum convention: lib `crc32c(seed, data)` unfinalized; the fs
/// writes `crc32c(0, …)` for nodes, superblock and data csums.
fn csum32(data: &[u8]) -> u32 {
    crc32c(0, data)
}

/// `btrfs_name_hash` — `crc32c(~1, name)`, the key offset every DIR_ITEM uses.
fn name_hash(name: &str) -> u64 {
    u64::from(crc32c(!1u32, name.as_bytes()))
}

/// A btrfs key: `(objectid, type, offset)` — the tree's sort order.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
struct Key {
    objectid: u64,
    ty: u8,
    offset: u64,
}

impl Key {
    fn parse(b: &[u8]) -> Self {
        Self {
            objectid: le64(b, 0),
            ty: b[8],
            offset: le64(b, 9),
        }
    }
    fn write(&self, b: &mut [u8]) {
        b[0..8].copy_from_slice(&self.objectid.to_le_bytes());
        b[8] = self.ty;
        b[9..17].copy_from_slice(&self.offset.to_le_bytes());
    }
}

/// One logical→physical window from a chunk item.
#[derive(Debug, Clone)]
struct Chunk {
    logical: u64,
    len: u64,
    phys: u64,
    stripes: u16,
}

/// `btrfs_inode_item` (160 bytes) with the fields a BIOS write touches.
fn inode_item(dir: bool, size: u64, nlink: u32) -> Vec<u8> {
    let mut d = vec![0u8; 160];
    d[0..8].copy_from_slice(&1u64.to_le_bytes()); // generation
    d[8..16].copy_from_slice(&1u64.to_le_bytes()); // transid
    d[16..24].copy_from_slice(&size.to_le_bytes());
    d[24..32].copy_from_slice(&size.to_le_bytes()); // nbytes
    d[40..44].copy_from_slice(&nlink.to_le_bytes());
    d[52..56].copy_from_slice(
        &(if dir {
            S_IFDIR | 0o755
        } else {
            S_IFREG | 0o644
        })
        .to_le_bytes(),
    );
    d
}

/// `btrfs_dir_item` — location key, transid, name. Shared by DIR_ITEM and
/// DIR_INDEX (same layout; the key differs).
fn dir_item(name: &str, child: u64, ft: u8) -> Vec<u8> {
    let mut d = vec![0u8; 30 + name.len()];
    Key {
        objectid: child,
        ty: 0,
        offset: 0,
    }
    .write(&mut d[0..17]);
    d[17..25].copy_from_slice(&1u64.to_le_bytes()); // transid
    d[27..29].copy_from_slice(&(name.len() as u16).to_le_bytes());
    d[29] = ft;
    d[30..].copy_from_slice(name.as_bytes());
    d
}

/// `btrfs_inode_ref` — the backref naming an inode inside a parent dir.
fn inode_ref(index: u64, name: &str) -> Vec<u8> {
    let mut d = vec![0u8; 10 + name.len()];
    d[0..8].copy_from_slice(&index.to_le_bytes());
    d[8..10].copy_from_slice(&(name.len() as u16).to_le_bytes());
    d[10..].copy_from_slice(name.as_bytes());
    d
}

/// A mounted btrfs volume.
pub struct Btrfs<'a> {
    dev: &'a mut dyn BlockDev,
    rw: bool,
    refusal: Option<String>,
    nodesize: usize,
    sectorsize: u64,
    chunks: Vec<Chunk>,
    /// FS tree root (logical) and its root-dir inode.
    fs_root: u64,
    root_dir: u64,
    /// Csum tree root (logical) — needed by every data write.
    csum_root: Option<u64>,
    label: String,
}

impl<'a> Btrfs<'a> {
    pub fn mount(dev: &'a mut dyn BlockDev, rw: bool) -> Result<Self> {
        if dev.len() < SB_OFF + 4096 {
            return Err(Error::TooSmall);
        }
        let sb = read_vec(dev, SB_OFF, 4096)?;
        if &sb[0x40..0x48] != MAGIC {
            return Err(Error::Corrupt("btrfs: superblock magic"));
        }
        if csum32(&sb[0x20..4096]) != le32(&sb, 0) {
            return Err(Error::Corrupt("btrfs: superblock csum"));
        }
        let nodesize = le32(&sb, 0x94) as usize;
        let sectorsize = u64::from(le32(&sb, 0x90));
        if !(4096..=65536).contains(&nodesize)
            || !(512..=65536).contains(&sectorsize)
            || nodesize < sectorsize as usize
            || !nodesize.is_power_of_two()
        {
            return Err(Error::Corrupt("btrfs: implausible node/sector size"));
        }
        let num_devices = le64(&sb, 0x88);
        let incompat = le64(&sb, 0xBC);
        let label = {
            let raw = &sb[0x12B..0x12B + 256];
            let end = raw.iter().position(|c| *c == 0).unwrap_or(256);
            String::from_utf8_lossy(&raw[..end]).trim().to_string()
        };

        let dev_rw = dev.writable();
        let mut fs = Self {
            dev,
            rw: false,
            refusal: None,
            nodesize,
            sectorsize,
            chunks: Vec::new(),
            fs_root: 0,
            root_dir: 6,
            csum_root: None,
            label,
        };
        // Bootstrap the logical→physical map from the superblock's chunk array,
        // then pick up every remaining chunk from the chunk tree.
        fs.read_sys_chunks(&sb)?;
        fs.read_chunk_tree(le64(&sb, 0x58))?;
        fs.chunks.sort_by_key(|c| c.logical);
        if fs.chunks.is_empty() {
            return Err(Error::Corrupt("btrfs: no chunk map"));
        }
        // The root tree says where the FS tree and the csum tree live.
        let mut multi_stripe = false;
        for c in &fs.chunks {
            if c.stripes > 1 {
                multi_stripe = true;
            }
        }
        fs.read_root_tree(le64(&sb, 0x50))?;
        if fs.fs_root == 0 {
            return Err(Error::Corrupt("btrfs: no FS tree root item"));
        }

        let mut refusal: Option<String> = None;
        if num_devices > 1 || multi_stripe {
            refusal = Some(
                "multi-device/raid btrfs — this BIOS writes single-device volumes only".into(),
            );
        } else if incompat & INCOMPAT_NO_WRITE != 0 {
            refusal = Some(format!(
                "btrfs incompat {incompat:#x} (zoned/extent-tree-v2/stripe-tree/metadata-uuid) — read-only here"
            ));
        }
        fs.refusal = refusal;
        fs.rw = rw && fs.refusal.is_none() && fs.csum_root.is_some() && dev_rw;
        if rw && fs.csum_root.is_none() && fs.refusal.is_none() {
            fs.refusal = Some("no csum tree found — writes would go unchecked".into());
            fs.rw = false;
        }
        Ok(fs)
    }

    /// `sys_chunk_array` at 0x32B: a flat sequence of `{key, item}` where a
    /// chunk item's size is `48 + 32*stripes` and a dev-extent item is 48.
    fn read_sys_chunks(&mut self, sb: &[u8]) -> Result<()> {
        let want = le32(sb, 0xA0) as usize;
        let array = &sb[0x32B..0x32B + want.min(2048).min(sb.len() - 0x32B)];
        let mut at = 0usize;
        while at + 17 <= array.len() {
            let key = Key::parse(&array[at..]);
            at += 17;
            match key.ty {
                T_CHUNK_ITEM => {
                    if at + 48 > array.len() {
                        return Err(Error::Corrupt("btrfs: short sys chunk"));
                    }
                    let stripes = le16(array, at + 44);
                    let c = self.parse_chunk(key, &array[at..])?;
                    self.chunks.push(c);
                    at += 48 + 32 * stripes.max(1) as usize;
                }
                T_DEV_EXTENT => {
                    at += 48;
                }
                _ => return Err(Error::Corrupt("btrfs: sys_chunk_array type")),
            }
        }
        Ok(())
    }

    fn parse_chunk(&self, key: Key, b: &[u8]) -> Result<Chunk> {
        let stripes = le16(b, 44);
        if stripes != 1 {
            // Recorded so writes are refused; the stripe is still parsed so the
            // read map stays complete for the (single) devices we do support.
            if stripes == 0 {
                return Err(Error::Corrupt("btrfs: chunk with no stripes"));
            }
        }
        Ok(Chunk {
            logical: key.offset,
            len: le64(b, 0),
            phys: le64(b, 56), // first stripe's physical offset
            stripes,
        })
    }

    fn read_chunk_tree(&mut self, root: u64) -> Result<()> {
        let mut items = Vec::new();
        self.each_item(root, &mut |key, data| {
            if key.ty == T_CHUNK_ITEM {
                items.push((key, data.to_vec()));
            }
            true
        })?;
        for (key, data) in items {
            let c = self.parse_chunk(key, &data)?;
            if !self.chunks.iter().any(|o| o.logical == c.logical) {
                self.chunks.push(c);
            }
        }
        Ok(())
    }

    fn read_root_tree(&mut self, root: u64) -> Result<()> {
        let mut roots = Vec::new();
        self.each_item(root, &mut |key, data| {
            if key.ty == T_ROOT_ITEM && data.len() >= 240 {
                roots.push((key.objectid, le64(data, 176), le64(data, 168)));
            }
            true
        })?;
        for (objectid, bytenr, dirid) in roots {
            match objectid {
                FS_TREE => {
                    self.fs_root = bytenr;
                    self.root_dir = if dirid != 0 { dirid } else { 6 };
                }
                CSUM_TREE => self.csum_root = Some(bytenr),
                _ => {}
            }
        }
        Ok(())
    }

    /// Logical → physical through the chunk map.
    fn phys(&self, logical: u64) -> Result<u64> {
        for c in &self.chunks {
            if logical >= c.logical && logical < c.logical + c.len {
                return Ok(c.phys + (logical - c.logical));
            }
        }
        Err(Error::Corrupt("btrfs: logical address outside every chunk"))
    }

    /// Read and verify a node. `bytenr` in the header must be the logical
    /// address asked for and the crc32c must hold — a node is either both or
    /// corrupt, never "close enough".
    fn node(&mut self, logical: u64) -> Result<Vec<u8>> {
        let phys = self.phys(logical)?;
        let buf = read_vec(self.dev, phys, self.nodesize)?;
        if le64(&buf, 0x30) != logical {
            return Err(Error::Corrupt("btrfs: node bytenr mismatch"));
        }
        if csum32(&buf[32..]) != le32(&buf, 0) {
            return Err(Error::Corrupt("btrfs: node csum mismatch"));
        }
        Ok(buf)
    }

    /// Walk every item in a tree, in key order. `cb` returning false stops.
    fn each_item(&mut self, root: u64, cb: &mut dyn FnMut(Key, &[u8]) -> bool) -> Result<()> {
        let buf = self.node(root)?;
        let level = buf[0x5C];
        let n = le32(&buf, 0x58) as usize;
        if level == 0 {
            for i in 0..n {
                let h = HDR + i * ITEM_LEN;
                let key = Key::parse(&buf[h..]);
                let off = le32(&buf, h + 17) as usize;
                let size = le32(&buf, h + 21) as usize;
                if off + size > buf.len() {
                    return Err(Error::Corrupt("btrfs: item data outside its leaf"));
                }
                if !cb(key, &buf[off..off + size]) {
                    return Ok(());
                }
            }
            return Ok(());
        }
        for i in 0..n {
            let h = HDR + i * KEYPTR_LEN;
            let child = le64(&buf, h + 17);
            self.each_item(child, cb)?;
        }
        Ok(())
    }

    /// All items `(objectid, ty)` with `offset >= off_min`, as
    /// `(key, data_offset_in_node)` on the leaf — for callers that need the leaf
    /// position too. Collects `Vec<(Key, Vec<u8>)>` style instead.
    fn items(&mut self, root: u64, objectid: u64, ty: u8) -> Result<Vec<(Key, Vec<u8>)>> {
        let mut out = Vec::new();
        self.each_item(root, &mut |key, data| {
            if key.objectid > objectid {
                return false; // keys are sorted — past the objectid, stop.
            }
            if key.objectid == objectid && key.ty == ty {
                out.push((key, data.to_vec()));
            }
            true
        })?;
        out.sort_by(|a, b| a.0.cmp(&b.0));
        Ok(out)
    }

    fn item(&mut self, root: u64, key: Key) -> Result<Option<Vec<u8>>> {
        let mut found = None;
        self.each_item(root, &mut |k, data| {
            if k == key {
                found = Some(data.to_vec());
                return false;
            }
            k.objectid <= key.objectid
        })?;
        Ok(found)
    }

    /// The inode record (`INODE_ITEM`, 160 bytes) fields used here.
    fn inode(
        &mut self,
        ino: u64,
    ) -> Result<(
        u32, /*mode*/
        u64, /*size*/
        u64, /*flags*/
        u32, /*nlink*/
    )> {
        let data = self
            .item(
                self.fs_root,
                Key {
                    objectid: ino,
                    ty: T_INODE,
                    offset: 0,
                },
            )?
            .ok_or_else(|| Error::NotFoundPath(format!("inode {ino}")))?;
        if data.len() < 72 {
            return Err(Error::Corrupt("btrfs: short inode item"));
        }
        Ok((
            le32(&data, 52),
            le64(&data, 16),
            le64(&data, 64),
            le32(&data, 40),
        ))
    }

    /// Directory children, in DIR_INDEX order: `(name, child_ino, ft)`.
    fn dir_entries(&mut self, dir: u64) -> Result<Vec<(String, u64, u8)>> {
        let mut out = Vec::new();
        for (key, data) in self.items(self.fs_root, dir, T_DIR_INDEX)? {
            if data.len() < 30 {
                return Err(Error::Corrupt("btrfs: short dir index"));
            }
            let name_len = le16(&data, 27) as usize;
            if 30 + name_len > data.len() {
                return Err(Error::Corrupt("btrfs: dir index name overruns its item"));
            }
            let name = String::from_utf8_lossy(&data[30..30 + name_len]).to_string();
            out.push((name, le64(&data, 0), data[29]));
            let _ = key;
        }
        if out.is_empty() {
            // A directory populated only via DIR_ITEMs still lists.
            for (_key, data) in self.items(self.fs_root, dir, T_DIR_ITEM)? {
                if data.len() < 30 {
                    continue;
                }
                let name_len = le16(&data, 27) as usize;
                if 30 + name_len > data.len() {
                    continue;
                }
                out.push((
                    String::from_utf8_lossy(&data[30..30 + name_len]).to_string(),
                    le64(&data, 0),
                    data[29],
                ));
            }
        }
        Ok(out)
    }

    /// One named child of `dir`, via its DIR_ITEMs (name-compared, so a hash
    /// collision cannot send a lookup to the wrong inode).
    fn dir_lookup(&mut self, dir: u64, name: &str) -> Result<Option<(u64, u8)>> {
        for (_key, data) in self.items(self.fs_root, dir, T_DIR_ITEM)? {
            if data.len() < 30 {
                return Err(Error::Corrupt("btrfs: short dir item"));
            }
            let name_len = le16(&data, 27) as usize;
            if 30 + name_len > data.len() {
                return Err(Error::Corrupt("btrfs: dir item name overruns its item"));
            }
            if &data[30..30 + name_len] == name.as_bytes() {
                return Ok(Some((le64(&data, 0), data[29])));
            }
        }
        Ok(None)
    }

    /// Path → inode, following symlinks (inline extents) up to 8 deep.
    fn resolve(&mut self, path: &str) -> Result<u64> {
        let mut cur = self.root_dir;
        let mut parts = split_path(path);
        let mut depth = 0;
        while let Some(name) = parts.first().cloned() {
            parts.remove(0);
            let (child, ft) = self
                .dir_lookup(cur, &name)?
                .ok_or_else(|| Error::NotFoundPath(path.to_string()))?;
            let (mode, _, _, _) = self.inode(child)?;
            if mode & S_IFMT == S_IFLNK || ft == FT_LNK {
                depth += 1;
                if depth > 8 {
                    return Err(Error::Corrupt("btrfs: symlink chain too deep"));
                }
                let target = self.file_data(child)?;
                let target = String::from_utf8_lossy(&target).to_string();
                if target.starts_with('/') {
                    cur = self.root_dir;
                }
                parts = split_path(&target)
                    .into_iter()
                    .chain(parts.into_iter())
                    .collect();
                continue;
            }
            cur = child;
        }
        Ok(cur)
    }

    /// A file's byte content from its EXTENT_DATA items, in offset order.
    fn file_data(&mut self, ino: u64) -> Result<Vec<u8>> {
        let (mode, size, _, _) = self.inode(ino)?;
        if mode & S_IFMT == S_IFDIR {
            return Err(Error::IsADir(format!("inode {ino}")));
        }
        let mut out = Vec::with_capacity(size as usize);
        for (key, data) in self.items(self.fs_root, ino, T_EXTENT_DATA)? {
            if data.len() < 21 {
                return Err(Error::Corrupt("btrfs: short extent item"));
            }
            let ty = data[20];
            if ty == EXT_INLINE {
                out.extend_from_slice(&data[21..]);
            } else if ty == EXT_REGULAR {
                if data.len() < 53 {
                    return Err(Error::Corrupt("btrfs: short regular extent"));
                }
                let disk_bytenr = le64(&data, 21);
                let ext_off = le64(&data, 37);
                let num = le64(&data, 45);
                let phys = self.phys(disk_bytenr + ext_off)?;
                out.extend_from_slice(&read_vec(self.dev, phys, num as usize)?);
            }
            // prealloc (2) contributes no bytes.
            let _ = key;
        }
        out.truncate(size as usize);
        Ok(out)
    }

    // ---- writing -----------------------------------------------------------

    fn want_write(&mut self) -> Result<()> {
        if !self.rw {
            let why = self
                .refusal
                .clone()
                .unwrap_or_else(|| "mounted read-only (`mount -w` to write)".to_string());
            return Err(Error::Unsupported(format!("btrfs: {why}")));
        }
        Ok(())
    }

    /// The leaf holding `key` (or where it would insert), as `(logical, buf)`.
    fn find_leaf(&mut self, root: u64, key: Key) -> Result<(u64, Vec<u8>)> {
        let mut cur = root;
        loop {
            let buf = self.node(cur)?;
            if buf[0x5C] == 0 {
                return Ok((cur, buf));
            }
            let n = le32(&buf, 0x58) as usize;
            if n == 0 {
                return Err(Error::Corrupt("btrfs: empty interior node"));
            }
            // Largest keyptr with key <= target (first when all exceed it).
            let mut pick = 0;
            for i in 0..n {
                let h = HDR + i * KEYPTR_LEN;
                if Key::parse(&buf[h..]) <= key {
                    pick = i;
                } else {
                    break;
                }
            }
            cur = le64(&buf, HDR + pick * KEYPTR_LEN + 17);
        }
    }

    /// Rewrite a verified-modified leaf: refresh the csum and put it back.
    fn put_node(&mut self, logical: u64, buf: &[u8]) -> Result<()> {
        let mut out = buf.to_vec();
        let c = csum32(&out[32..]);
        out[0..4].copy_from_slice(&c.to_le_bytes());
        let phys = self.phys(logical)?;
        self.dev.write_at(phys, &out)
    }

    /// Insert `data` under `key` in the leaf found under `root` — in place,
    /// which is legal precisely because the leaf is rewritten whole and its own
    /// csum refreshed. Refused when the leaf's free space cannot take it; a
    /// split is the OS's machinery, not a BIOS write's.
    fn insert(&mut self, root: u64, key: Key, data: &[u8]) -> Result<()> {
        let (logical, mut buf) = self.find_leaf(root, key)?;
        let n = le32(&buf, 0x58) as usize;
        let mut offs = Vec::with_capacity(n);
        for i in 0..n {
            let h = HDR + i * ITEM_LEN;
            offs.push((Key::parse(&buf[h..]), le32(&buf, h + 17) as usize));
        }
        let k = offs.iter().position(|(ok, _)| *ok >= key).unwrap_or(n);
        if k < n && offs[k].0 == key {
            return Err(Error::Exists(format!(
                "btrfs: item ({:#x},{},{:#x}) already present",
                key.objectid, key.ty, key.offset
            )));
        }
        let data_low = if n == 0 { self.nodesize } else { offs[n - 1].1 };
        let data_end = if k == 0 { self.nodesize } else { offs[k - 1].1 };
        let free = data_low.saturating_sub(HDR + ITEM_LEN * n);
        if free < ITEM_LEN + data.len() {
            return Err(Error::Unsupported(format!(
                "btrfs: leaf has {free} free bytes, needs {} — splitting a node is the OS's job",
                ITEM_LEN + data.len()
            )));
        }
        // Data of items k..n-1 moves down by the new size; their recorded
        // offsets follow it.
        buf.copy_within(data_low..data_end, data_low - data.len());
        for it in offs.iter_mut().skip(k) {
            it.1 -= data.len();
        }
        // Item headers k.. shift up one slot; each moved item lands at i+1 and
        // its recorded data offset follows the data shift.
        buf.copy_within(
            HDR + k * ITEM_LEN..HDR + n * ITEM_LEN,
            HDR + (k + 1) * ITEM_LEN,
        );
        for (i, (ok, off)) in offs.iter().enumerate().skip(k) {
            let h = HDR + (i + 1) * ITEM_LEN;
            ok.write(&mut buf[h..]);
            buf[h + 17..h + 21].copy_from_slice(&(*off as u32).to_le_bytes());
            // size fields unchanged
        }
        let at = data_end - data.len();
        buf[at..at + data.len()].copy_from_slice(data);
        let h = HDR + k * ITEM_LEN;
        key.write(&mut buf[h..]);
        buf[h + 17..h + 21].copy_from_slice(&(at as u32).to_le_bytes());
        buf[h + 21..h + 25].copy_from_slice(&(data.len() as u32).to_le_bytes());
        buf[0x58..0x5C].copy_from_slice(&((n as u32 + 1).to_le_bytes()));
        self.put_node(logical, &buf)
    }

    /// Replace an existing item's data in place — the mirror of [`insert`]:
    /// the data block below the item shifts up (shrink) or down (grow), the
    /// lower items' offsets follow, and the leaf is rewritten with a fresh
    /// csum. How an inline extent gets overwritten, and how a persisted store
    /// dump keeps landing in the same file.
    fn item_replace(&mut self, root: u64, key: Key, data: &[u8]) -> Result<()> {
        let (logical, mut buf) = self.find_leaf(root, key)?;
        let n = le32(&buf, 0x58) as usize;
        let mut offs = Vec::with_capacity(n);
        for i in 0..n {
            let h = HDR + i * ITEM_LEN;
            offs.push((
                Key::parse(&buf[h..]),
                le32(&buf, h + 17) as usize,
                le32(&buf, h + 21) as usize,
            ));
        }
        let i = offs
            .iter()
            .position(|(ok, _, _)| *ok == key)
            .ok_or(Error::NotFound)?;
        let old_off = offs[i].1;
        let old_sz = offs[i].2;
        let ns = data.len();
        let low = offs[n - 1].1;
        match ns.cmp(&old_sz) {
            std::cmp::Ordering::Greater => {
                let need = ns - old_sz;
                let free = low.saturating_sub(HDR + ITEM_LEN * n);
                if need > free {
                    return Err(Error::Unsupported(format!(
                        "btrfs: leaf has {free} free bytes, needs {need} more — growing past it is a node split, the OS's job"
                    )));
                }
                buf.copy_within(low..old_off, low - need);
                for it in offs.iter_mut().skip(i + 1) {
                    it.1 -= need;
                }
                offs[i].1 = old_off - need;
            }
            std::cmp::Ordering::Less => {
                let shrink = old_sz - ns;
                buf.copy_within(low..old_off, low + shrink);
                for it in offs.iter_mut().skip(i + 1) {
                    it.1 += shrink;
                }
                offs[i].1 = old_off + shrink;
            }
            std::cmp::Ordering::Equal => {}
        }
        let at = offs[i].1;
        buf[at..at + ns].copy_from_slice(data);
        // Rewrite the affected headers: item i's offset+size, lower items' offsets.
        for (j, (ok, off, sz)) in offs.iter().enumerate().skip(i) {
            let h = HDR + j * ITEM_LEN;
            ok.write(&mut buf[h..]);
            buf[h + 17..h + 21].copy_from_slice(&(*off as u32).to_le_bytes());
            buf[h + 21..h + 25].copy_from_slice(&(*sz as u32).to_le_bytes());
        }
        buf[HDR + i * ITEM_LEN + 21..HDR + i * ITEM_LEN + 25]
            .copy_from_slice(&(ns as u32).to_le_bytes());
        self.put_node(logical, &buf)
    }

    /// Patch `patch` bytes at `data_off` inside the item `key` names — the
    /// in-place edit every write boils down to.
    fn patch_item(&mut self, root: u64, key: Key, data_off: usize, patch: &[u8]) -> Result<()> {
        let (logical, mut buf) = self.find_leaf(root, key)?;
        let n = le32(&buf, 0x58) as usize;
        for i in 0..n {
            let h = HDR + i * ITEM_LEN;
            if Key::parse(&buf[h..]) == key {
                let off = le32(&buf, h + 17) as usize + data_off;
                buf[off..off + patch.len()].copy_from_slice(patch);
                return self.put_node(logical, &buf);
            }
        }
        Err(Error::NotFound)
    }

    /// Refresh one sector's entry in the csum tree. The item keyed
    /// `(EXTENT_CSUM_OBJ, 128, first_bytenr)` covers a run of sectors; its data
    /// is one u32 each.
    fn write_csum(&mut self, data_logical: u64) -> Result<()> {
        let root = self.csum_root.ok_or(Error::ReadOnly("no csum tree"))?;
        let want = Key {
            objectid: EXTENT_CSUM_OBJ,
            ty: T_EXTENT_CSUM,
            offset: data_logical,
        };
        let sectorsize = self.sectorsize;
        let mut hit: Option<(u64, Vec<u8>)> = None;
        // The covering item is the greatest key.offset <= our sector.
        self.each_item(root, &mut |key, data| {
            if key.objectid != EXTENT_CSUM_OBJ || key.ty != T_EXTENT_CSUM {
                return key.objectid <= EXTENT_CSUM_OBJ;
            }
            if key.offset <= data_logical
                && data_logical < key.offset + (data.len() as u64 / 4) * sectorsize
            {
                hit = Some((key.offset, data.to_vec()));
                return false;
            }
            key <= want
        })?;
        let (first, _data) = hit.ok_or(Error::Corrupt(
            "btrfs: csum tree has no item covering a written extent",
        ))?;
        // Recompute from the bytes on the medium (post-write state).
        let phys = self.phys(data_logical)?;
        let sector = read_vec(self.dev, phys, self.sectorsize as usize)?;
        let idx = ((data_logical - first) / self.sectorsize) as usize;
        self.patch_item(
            root,
            Key {
                objectid: EXTENT_CSUM_OBJ,
                ty: T_EXTENT_CSUM,
                offset: first,
            },
            idx * 4,
            &csum32(&sector).to_le_bytes(),
        )
    }

    /// In-place write inside the extents a file already has — or, for a file
    /// whose only extent is inline, a leaf-level item replacement.
    fn write_inplace(&mut self, ino: u64, data: &[u8]) -> Result<()> {
        let (_, size, flags, _) = self.inode(ino)?;
        let exts = self.items(self.fs_root, ino, T_EXTENT_DATA)?;
        if exts.is_empty()
            || exts
                .iter()
                .all(|(_, d)| d.len() > 20 && d[20] == EXT_INLINE)
        {
            // A single inline extent: the file *is* leaf data, so the write is
            // an item replace — bounded by the inline cap and the leaf's room.
            if data.len() > INLINE_CAP {
                return Err(Error::Unsupported(format!(
                    "btrfs: {} bytes over the {INLINE_CAP} inline cap — this file's data lives in a leaf",
                    data.len()
                )));
            }
            let mut e = vec![0u8; 21 + data.len()];
            e[0..8].copy_from_slice(&1u64.to_le_bytes());
            e[8..16].copy_from_slice(&(data.len() as u64).to_le_bytes());
            e[20] = EXT_INLINE;
            e[21..].copy_from_slice(data);
            if let Some((key, _)) = exts.first() {
                self.item_replace(self.fs_root, *key, &e)?;
            } else {
                // An empty file has no extent item yet — create it inline.
                self.insert(
                    self.fs_root,
                    Key {
                        objectid: ino,
                        ty: T_EXTENT_DATA,
                        offset: 0,
                    },
                    &e,
                )?;
            }
            if data.len() as u64 != size {
                self.patch_item(
                    self.fs_root,
                    Key {
                        objectid: ino,
                        ty: T_INODE,
                        offset: 0,
                    },
                    16,
                    &(data.len() as u64).to_le_bytes(),
                )?;
            }
            return self.dev.flush();
        }
        let mut spans: Vec<(u64, u64, u64, u64)> = Vec::new(); // (file_off, phys, len, disk_logical)
        for (key, d) in &exts {
            if d.len() < 21 {
                return Err(Error::Corrupt("btrfs: short extent item"));
            }
            let ty = d[20];
            if ty == EXT_REGULAR {
                if d[16] != 0 || d[17] != 0 {
                    return Err(Error::Unsupported(
                        "btrfs: compressed/encrypted extents are not written here".into(),
                    ));
                }
                let disk = le64(d, 21);
                let ext_off = le64(d, 37);
                let num = le64(d, 45);
                spans.push((key.offset, self.phys(disk + ext_off)?, num, disk + ext_off));
            }
        }
        let covered: u64 = spans.iter().map(|s| s.2).sum();
        if data.len() as u64 > covered {
            return Err(Error::Unsupported(format!(
                "btrfs: {} bytes will not fit the {covered} this file's extents hold — growing needs the OS",
                data.len()
            )));
        }
        // Write each span, then refresh the csum tree for every touched sector.
        let mut written_sectors: Vec<u64> = Vec::new();
        let mut done = 0usize;
        for (foff, phys, num, disk_logical) in &spans {
            let take = ((data.len() - done) as u64).min(*num) as usize;
            if take == 0 {
                break;
            }
            let _ = foff;
            self.dev.write_at(*phys, &data[done..done + take])?;
            let mut s = *disk_logical;
            while s < disk_logical + take as u64 {
                written_sectors.push(s);
                s += self.sectorsize;
            }
            done += take;
        }
        if flags & INODE_NODATASUM == 0 {
            for s in written_sectors {
                self.write_csum(s)?;
            }
        }
        // i_size follows — a shorter write leaves the tail unreadable.
        if data.len() as u64 != size {
            self.patch_item(
                self.fs_root,
                Key {
                    objectid: ino,
                    ty: T_INODE,
                    offset: 0,
                },
                16,
                &(data.len() as u64).to_le_bytes(),
            )?;
        }
        self.dev.flush()
    }

    /// Highest inode objectid + 1 — scanned, not cached.
    fn next_ino(&mut self) -> Result<u64> {
        let mut max = FIRST_FREE - 1;
        self.each_item(self.fs_root, &mut |key, _| {
            if key.ty == T_INODE
                && (FIRST_FREE..(1 << 62)).contains(&key.objectid)
                && key.objectid > max
            {
                max = key.objectid;
            }
            true
        })?;
        Ok(max + 1)
    }

    /// Next DIR_INDEX offset in a directory.
    fn next_dir_index(&mut self, dir: u64) -> Result<u64> {
        let mut max: Option<u64> = None;
        for (key, _) in self.items(self.fs_root, dir, T_DIR_INDEX)? {
            max = Some(max.map_or(key.offset, |m| m.max(key.offset)));
        }
        Ok(max.map(|m| m + 1).unwrap_or(0))
    }

    /// Create `name` in `dir_ino` — a file with inline data, or a directory.
    fn create(&mut self, dir_ino: u64, name: &str, data: &[u8], dir: bool) -> Result<()> {
        if name.is_empty() || name == "." || name == ".." || name.contains('/') {
            return Err(Error::BadName(format!("`{name}` is not a usable name")));
        }
        if self.dir_lookup(dir_ino, name)?.is_some() {
            return Err(Error::Exists(name.into()));
        }
        if !dir && data.len() > INLINE_CAP {
            return Err(Error::Unsupported(format!(
                "btrfs: create lands data inline — {} bytes over the {INLINE_CAP} cap; write it via the OS or overwrite an existing file",
                data.len()
            )));
        }
        let ino = self.next_ino()?;
        let index = self.next_dir_index(dir_ino)?;
        let ft = if dir { FT_DIR } else { FT_REG };
        self.insert(
            self.fs_root,
            Key {
                objectid: ino,
                ty: T_INODE,
                offset: 0,
            },
            &inode_item(dir, data.len() as u64, if dir { 2 } else { 1 }),
        )?;
        if !dir {
            let mut e = vec![0u8; 21 + data.len()];
            e[0..8].copy_from_slice(&1u64.to_le_bytes()); // generation
            e[8..16].copy_from_slice(&(data.len() as u64).to_le_bytes()); // ram_bytes
            e[20] = EXT_INLINE;
            e[21..].copy_from_slice(data);
            self.insert(
                self.fs_root,
                Key {
                    objectid: ino,
                    ty: T_EXTENT_DATA,
                    offset: 0,
                },
                &e,
            )?;
        }
        self.insert(
            self.fs_root,
            Key {
                objectid: ino,
                ty: T_INODE_REF,
                offset: dir_ino,
            },
            &inode_ref(index, name),
        )?;
        self.insert(
            self.fs_root,
            Key {
                objectid: dir_ino,
                ty: T_DIR_ITEM,
                offset: name_hash(name),
            },
            &dir_item(name, ino, ft),
        )?;
        self.insert(
            self.fs_root,
            Key {
                objectid: dir_ino,
                ty: T_DIR_INDEX,
                offset: index,
            },
            &dir_item(name, ino, ft),
        )?;
        if dir {
            // A subdir's `..` costs the parent a link.
            let (_, _, _, nlink) = self.inode(dir_ino)?;
            self.patch_item(
                self.fs_root,
                Key {
                    objectid: dir_ino,
                    ty: T_INODE,
                    offset: 0,
                },
                40,
                &(nlink + 1).to_le_bytes(),
            )?;
        }
        Ok(())
    }
}

impl FileSystem for Btrfs<'_> {
    fn kind(&self) -> FsKind {
        FsKind::Btrfs
    }

    fn label(&self) -> String {
        self.label.clone()
    }

    fn writable(&self) -> bool {
        self.rw
    }

    fn list(&mut self, path: &str) -> Result<Vec<DirEnt>> {
        let ino = self.resolve(path)?;
        let (mode, _, _, _) = self.inode(ino)?;
        if mode & S_IFMT != S_IFDIR {
            return Err(Error::NotADir(path.into()));
        }
        Ok(self
            .dir_entries(ino)?
            .into_iter()
            .filter(|(n, _, _)| n != "." && n != "..")
            .map(|(name, child, ft)| {
                let dir = ft == FT_DIR
                    || self
                        .inode(child)
                        .map(|(m, _, _, _)| m & S_IFMT == S_IFDIR)
                        .unwrap_or(false);
                let size = self.inode(child).map(|(_, s, _, _)| s).unwrap_or(0);
                DirEnt {
                    name,
                    dir,
                    size,
                    read_only: !self.rw,
                    hidden: false,
                }
            })
            .collect())
    }

    fn stat(&mut self, path: &str) -> Result<Stat> {
        let ino = self.resolve(path)?;
        let (mode, size, _, _) = self.inode(ino)?;
        Ok(Stat {
            dir: mode & S_IFMT == S_IFDIR,
            size,
            read_only: !self.rw,
        })
    }

    fn read(&mut self, path: &str) -> Result<Vec<u8>> {
        let ino = self.resolve(path)?;
        self.file_data(ino)
    }

    fn read_window(&mut self, path: &str, off: u64, len: usize) -> Result<Vec<u8>> {
        // Per-extent reads: a header out of a large file must not mean reading
        // the file.
        let ino = self.resolve(path)?;
        let (mode, size, _, _) = self.inode(ino)?;
        if mode & S_IFMT == S_IFDIR {
            return Err(Error::IsADir(path.into()));
        }
        let mut out = Vec::new();
        let end = off.saturating_add(len as u64).min(size);
        if off >= end {
            return Ok(out);
        }
        for (key, d) in self.items(self.fs_root, ino, T_EXTENT_DATA)? {
            if d.len() < 21 {
                return Err(Error::Corrupt("btrfs: short extent item"));
            }
            let eoff = key.offset;
            if d[20] == EXT_INLINE {
                let bytes = &d[21..];
                let elen = bytes.len() as u64;
                if eoff < end && eoff + elen > off {
                    let s = (off - eoff) as usize;
                    let t = (end - eoff).min(elen) as usize;
                    out.extend_from_slice(&bytes[s..t]);
                }
            } else if d[20] == EXT_REGULAR {
                let num = le64(&d, 45);
                if eoff < end && eoff + num > off {
                    let phys = self.phys(le64(&d, 21) + le64(&d, 37))?;
                    let s = off - eoff;
                    let t = (end - eoff).min(num);
                    out.extend_from_slice(&read_vec(self.dev, phys + s, (t - s) as usize)?);
                }
            }
        }
        Ok(out)
    }

    fn edit_budget(&mut self, path: &str) -> Result<EditBudget> {
        match self.stat(path) {
            Ok(s) if s.dir => Ok(EditBudget::refused(
                FsKind::Btrfs,
                s.size,
                true,
                "a directory, not a file",
            )),
            Ok(s) => {
                // In-place: bounded by the extents the file already has.
                let ino = self.resolve(path)?;
                let mut covered = 0u64;
                let mut inline = false;
                for (_key, d) in self.items(self.fs_root, ino, T_EXTENT_DATA)? {
                    if d.len() > 20 && d[20] == EXT_REGULAR {
                        covered += le64(&d, 45);
                    } else if d.len() > 20 && d[20] == EXT_INLINE {
                        inline = true;
                    }
                }
                if !self.rw {
                    return Ok(EditBudget::refused(
                        FsKind::Btrfs,
                        s.size,
                        true,
                        self.refusal
                            .clone()
                            .unwrap_or_else(|| "mounted read-only (`mount -w` to write)".into()),
                    ));
                }
                if inline {
                    return Ok(EditBudget {
                        fs: FsKind::Btrfs,
                        exists: true,
                        size: s.size,
                        writable: true,
                        max_bytes: Some(INLINE_CAP as u64),
                        can_create: false,
                        can_grow: false,
                        why: Some(format!(
                            "inline extent — replaceable in the leaf, ≤{INLINE_CAP}B"
                        )),
                    });
                }
                Ok(EditBudget {
                    fs: FsKind::Btrfs,
                    exists: true,
                    size: s.size,
                    writable: true,
                    max_bytes: Some(covered),
                    can_create: false,
                    can_grow: false,
                    why: Some("in place, inside the extents it already has".into()),
                })
            }
            Err(Error::NotFoundPath(_)) => {
                if !self.rw {
                    return Ok(EditBudget::refused(
                        FsKind::Btrfs,
                        0,
                        false,
                        self.refusal
                            .clone()
                            .unwrap_or_else(|| "mounted read-only (`mount -w` to write)".into()),
                    ));
                }
                Ok(EditBudget {
                    fs: FsKind::Btrfs,
                    exists: false,
                    size: 0,
                    writable: true,
                    max_bytes: Some(INLINE_CAP as u64),
                    can_create: true,
                    can_grow: false,
                    why: Some(format!("create lands data inline (≤{INLINE_CAP}B)")),
                })
            }
            Err(e) => Err(e),
        }
    }

    fn write(&mut self, path: &str, data: &[u8]) -> Result<()> {
        self.want_write()?;
        let mut parts = split_path(path);
        let name = parts.pop().ok_or(Error::NotFoundPath(path.into()))?;
        let dir_path = parts.join("/");
        let dir_ino = if dir_path.is_empty() {
            self.root_dir
        } else {
            self.resolve(&dir_path)?
        };
        match self.dir_lookup(dir_ino, &name)? {
            Some((child, ft)) => {
                if ft == FT_DIR {
                    return Err(Error::IsADir(path.into()));
                }
                self.write_inplace(child, data)
            }
            None => self.create(dir_ino, &name, data, false),
        }
    }

    fn mkdir(&mut self, path: &str) -> Result<()> {
        self.want_write()?;
        let mut parts = split_path(path);
        let name = parts.pop().ok_or(Error::NotFoundPath(path.into()))?;
        let dir_path = parts.join("/");
        let dir_ino = if dir_path.is_empty() {
            self.root_dir
        } else {
            self.resolve(&dir_path)?
        };
        let (mode, _, _, _) = self.inode(dir_ino)?;
        if mode & S_IFMT != S_IFDIR {
            return Err(Error::NotADir(dir_path));
        }
        self.create(dir_ino, &name, &[], true)
    }

    fn remove(&mut self, path: &str) -> Result<()> {
        Err(Error::Unsupported(format!(
            "btrfs: remove {path} needs unlink + backref bookkeeping — the OS's machinery"
        )))
    }
}

/// A hand-laid btrfs volume shaped the way `mkfs.btrfs` lays one out — single
/// device, single-stripe chunks, nodesize 4096 — small enough for a test and
/// real enough that every checksum and key ordering is exercised. `pub`
/// because the kernel's tests mount it too, the same way `fat32::fixture` is.
pub mod fixture {
    use super::*;

    /// Real btrfs defaults to a 16 KiB nodesize, and so does this fixture.
    ///
    /// It used to be 4096, which is legal but left the single FS-tree leaf
    /// essentially full: `g6lc/store.json` fitted with **one byte** to spare,
    /// so whether a store export succeeded depended on how long the file name
    /// was. `g6lc/wasm-store-btrfs.json` — eleven characters longer — failed
    /// with `leaf has 1 free bytes, needs 76`, which reads like a driver bug
    /// and is really a fixture that was tuned to one test's name.
    ///
    /// The driver deliberately refuses to split a node ("splitting a node is
    /// the OS's job"), so leaf headroom is the fixture's responsibility. At
    /// 16 KiB the leaf has room for realistic names and the refusal path is
    /// still reachable on purpose by filling it.
    const NODE: usize = 16384;
    /// Metadata blocks, `NODE` apart, all inside the 4 MiB metadata chunk
    /// mapped at `CHUNK_TREE_AT` (`chunk_item(0x40_0000, …)`).
    const CHUNK_TREE_AT: u64 = 0x40_0000;
    const ROOT_TREE_AT: u64 = CHUNK_TREE_AT + NODE as u64;
    const FS_TREE_AT: u64 = ROOT_TREE_AT + NODE as u64;
    const EXTENT_TREE_AT: u64 = FS_TREE_AT + NODE as u64;
    const CSUM_TREE_AT: u64 = EXTENT_TREE_AT + NODE as u64;
    /// The dev tree (root objectid 4). Was written as a bare `0x40_5000` in
    /// two places, which is exactly the kind of duplication that breaks when
    /// the nodesize changes.
    const DEV_TREE_AT: u64 = CSUM_TREE_AT + NODE as u64;
    const DATA_AT: u64 = 0x80_0000;

    fn node(fsid: &[u8; 16], bytenr: u64, owner: u64, level: u8) -> Vec<u8> {
        let mut b = vec![0u8; NODE];
        b[0x20..0x30].copy_from_slice(fsid);
        b[0x30..0x38].copy_from_slice(&bytenr.to_le_bytes());
        b[0x48..0x50].copy_from_slice(&1u64.to_le_bytes()); // generation
        b[0x50..0x58].copy_from_slice(&owner.to_le_bytes());
        b[0x5C] = level;
        b
    }

    fn key_bytes(k: Key) -> [u8; 17] {
        let mut b = [0u8; 17];
        k.write(&mut b);
        b
    }

    /// Insert `(key, data)` into a leaf under construction — the same layout
    /// the driver's in-place insert produces: items sorted by key, data packed
    /// downward from the leaf end in that order.
    fn push(leaf: &mut [u8], items: &mut Vec<(Key, usize, usize)>, key: Key, data: &[u8]) {
        let n = items.len();
        let k = items.iter().position(|(ok, _, _)| *ok >= key).unwrap_or(n);
        let data_low = if n == 0 { NODE } else { items[n - 1].1 };
        let data_end = if k == 0 { NODE } else { items[k - 1].1 };
        leaf.copy_within(data_low..data_end, data_low - data.len());
        for it in items.iter_mut().skip(k) {
            it.1 -= data.len();
        }
        let at = data_end - data.len();
        leaf[at..at + data.len()].copy_from_slice(data);
        items.insert(k, (key, at, data.len()));
        for (i, (k, off, sz)) in items.iter().enumerate() {
            let h = HDR + i * ITEM_LEN;
            leaf[h..h + 17].copy_from_slice(&key_bytes(*k));
            leaf[h + 17..h + 21].copy_from_slice(&(*off as u32).to_le_bytes());
            leaf[h + 21..h + 25].copy_from_slice(&(*sz as u32).to_le_bytes());
        }
        leaf[0x58..0x5C].copy_from_slice(&(items.len() as u32).to_le_bytes());
        let c = csum32(&leaf[32..]);
        leaf[0..4].copy_from_slice(&c.to_le_bytes());
    }

    fn root_item(bytenr: u64, dirid: u64, level: u8) -> Vec<u8> {
        let mut d = vec![0u8; 439];
        d[52..56].copy_from_slice(&(S_IFDIR | 0o755).to_le_bytes()); // inode.mode
        d[160..168].copy_from_slice(&1u64.to_le_bytes()); // generation
        d[168..176].copy_from_slice(&dirid.to_le_bytes());
        d[176..184].copy_from_slice(&bytenr.to_le_bytes());
        d[216..220].copy_from_slice(&1u32.to_le_bytes()); // refs
        d[238] = level;
        d
    }

    fn chunk_item(len: u64, phys: u64, ty: u64) -> Vec<u8> {
        let mut d = vec![0u8; 80];
        d[0..8].copy_from_slice(&len.to_le_bytes());
        d[8..16].copy_from_slice(&2u64.to_le_bytes()); // owner = extent tree
        d[16..24].copy_from_slice(&65536u64.to_le_bytes()); // stripe_len
        d[24..32].copy_from_slice(&ty.to_le_bytes());
        d[32..36].copy_from_slice(&4096u32.to_le_bytes());
        d[36..40].copy_from_slice(&4096u32.to_le_bytes());
        d[40..44].copy_from_slice(&4096u32.to_le_bytes());
        d[44..46].copy_from_slice(&1u16.to_le_bytes()); // num_stripes
        d[48..56].copy_from_slice(&1u64.to_le_bytes()); // devid
        d[56..64].copy_from_slice(&phys.to_le_bytes()); // physical offset
        d
    }

    /// `with_file`: also lay a regular-extent file `data.bin` (two sectors at
    /// `DATA_AT`) plus the csum tree items covering it.
    pub fn image(with_data: bool) -> Vec<u8> {
        let fsid: [u8; 16] = *b"G6LC-VFS-BTRFS!!";
        let mut img = vec![0u8; 16 * 1024 * 1024];

        // ---- chunk tree ----
        let mut chunk_leaf = node(&fsid, CHUNK_TREE_AT, 3, 0);
        let mut ci = Vec::new();
        push(
            &mut chunk_leaf,
            &mut ci,
            Key {
                objectid: 3,
                ty: T_CHUNK_ITEM,
                offset: CHUNK_TREE_AT,
            },
            &chunk_item(0x40_0000, CHUNK_TREE_AT, 4),
        ); // metadata
        push(
            &mut chunk_leaf,
            &mut ci,
            Key {
                objectid: 3,
                ty: T_CHUNK_ITEM,
                offset: DATA_AT,
            },
            &chunk_item(0x40_0000, DATA_AT, 1),
        ); // data

        // ---- root tree ----
        let mut root_leaf = node(&fsid, ROOT_TREE_AT, 1, 0);
        let mut ri = Vec::new();
        for (objectid, at) in [
            (2u64, EXTENT_TREE_AT),
            (4, DEV_TREE_AT),
            (FS_TREE, FS_TREE_AT),
            (CSUM_TREE, CSUM_TREE_AT),
        ] {
            push(
                &mut root_leaf,
                &mut ri,
                Key {
                    objectid,
                    ty: T_ROOT_ITEM,
                    offset: 0,
                },
                &root_item(at, 6, 0),
            );
        }

        // ---- FS tree ----
        let mut fs_leaf = node(&fsid, FS_TREE_AT, FS_TREE, 0);
        let mut fi = Vec::new();
        // root dir inode 6
        push(
            &mut fs_leaf,
            &mut fi,
            Key {
                objectid: 6,
                ty: T_INODE,
                offset: 0,
            },
            &inode_item(true, 0, 1),
        );
        // /etc dir inode 258 with os-release inside
        push(
            &mut fs_leaf,
            &mut fi,
            Key {
                objectid: 6,
                ty: T_DIR_ITEM,
                offset: name_hash("etc"),
            },
            &dir_item("etc", 258, FT_DIR),
        );
        push(
            &mut fs_leaf,
            &mut fi,
            Key {
                objectid: 6,
                ty: T_DIR_INDEX,
                offset: 0,
            },
            &dir_item("etc", 258, FT_DIR),
        );
        push(
            &mut fs_leaf,
            &mut fi,
            Key {
                objectid: 6,
                ty: T_DIR_ITEM,
                offset: name_hash("hello.txt"),
            },
            &dir_item("hello.txt", 257, FT_REG),
        );
        push(
            &mut fs_leaf,
            &mut fi,
            Key {
                objectid: 6,
                ty: T_DIR_INDEX,
                offset: 1,
            },
            &dir_item("hello.txt", 257, FT_REG),
        );
        push(
            &mut fs_leaf,
            &mut fi,
            Key {
                objectid: 257,
                ty: T_INODE,
                offset: 0,
            },
            &inode_item(false, 6, 1),
        );
        push(
            &mut fs_leaf,
            &mut fi,
            Key {
                objectid: 257,
                ty: T_INODE_REF,
                offset: 6,
            },
            &inode_ref(1, "hello.txt"),
        );
        let mut inline = vec![0u8; 21 + 6];
        inline[8..16].copy_from_slice(&6u64.to_le_bytes());
        inline[21..].copy_from_slice(b"hello\n");
        push(
            &mut fs_leaf,
            &mut fi,
            Key {
                objectid: 257,
                ty: T_EXTENT_DATA,
                offset: 0,
            },
            &inline,
        );
        // /etc dir inode 258
        push(
            &mut fs_leaf,
            &mut fi,
            Key {
                objectid: 258,
                ty: T_INODE,
                offset: 0,
            },
            &inode_item(true, 0, 2),
        );
        push(
            &mut fs_leaf,
            &mut fi,
            Key {
                objectid: 258,
                ty: T_INODE_REF,
                offset: 6,
            },
            &inode_ref(0, "etc"),
        );
        let osrel = b"PRETTY_NAME=\"G6LC btrfs Linux\"\nID=g6lc\n";
        push(
            &mut fs_leaf,
            &mut fi,
            Key {
                objectid: 258,
                ty: T_DIR_ITEM,
                offset: name_hash("os-release"),
            },
            &dir_item("os-release", 259, FT_REG),
        );
        push(
            &mut fs_leaf,
            &mut fi,
            Key {
                objectid: 258,
                ty: T_DIR_INDEX,
                offset: 0,
            },
            &dir_item("os-release", 259, FT_REG),
        );
        push(
            &mut fs_leaf,
            &mut fi,
            Key {
                objectid: 259,
                ty: T_INODE,
                offset: 0,
            },
            &inode_item(false, osrel.len() as u64, 1),
        );
        push(
            &mut fs_leaf,
            &mut fi,
            Key {
                objectid: 259,
                ty: T_INODE_REF,
                offset: 258,
            },
            &inode_ref(0, "os-release"),
        );
        let mut osx = vec![0u8; 21 + osrel.len()];
        osx[8..16].copy_from_slice(&(osrel.len() as u64).to_le_bytes());
        osx[21..].copy_from_slice(osrel);
        push(
            &mut fs_leaf,
            &mut fi,
            Key {
                objectid: 259,
                ty: T_EXTENT_DATA,
                offset: 0,
            },
            &osx,
        );
        if with_data {
            // /data.bin inode 300 — two 4 KiB sectors at DATA_AT.
            let content = b"HEAD".repeat(1024); // 4096 in sector 1
            img[DATA_AT as usize..DATA_AT as usize + 4096].copy_from_slice(&content);
            img[DATA_AT as usize + 4096..DATA_AT as usize + 8192]
                .copy_from_slice(&b"TAIL".repeat(1024));
            push(
                &mut fs_leaf,
                &mut fi,
                Key {
                    objectid: 6,
                    ty: T_DIR_ITEM,
                    offset: name_hash("data.bin"),
                },
                &dir_item("data.bin", 300, FT_REG),
            );
            push(
                &mut fs_leaf,
                &mut fi,
                Key {
                    objectid: 6,
                    ty: T_DIR_INDEX,
                    offset: 2,
                },
                &dir_item("data.bin", 300, FT_REG),
            );
            push(
                &mut fs_leaf,
                &mut fi,
                Key {
                    objectid: 300,
                    ty: T_INODE,
                    offset: 0,
                },
                &inode_item(false, 8192, 1),
            );
            push(
                &mut fs_leaf,
                &mut fi,
                Key {
                    objectid: 300,
                    ty: T_INODE_REF,
                    offset: 6,
                },
                &inode_ref(2, "data.bin"),
            );
            let mut x = vec![0u8; 53];
            x[0..8].copy_from_slice(&1u64.to_le_bytes());
            x[8..16].copy_from_slice(&8192u64.to_le_bytes()); // ram_bytes
            x[20] = EXT_REGULAR;
            x[21..29].copy_from_slice(&DATA_AT.to_le_bytes()); // disk_bytenr
            x[29..37].copy_from_slice(&8192u64.to_le_bytes()); // disk_num_bytes
            x[45..53].copy_from_slice(&8192u64.to_le_bytes()); // num_bytes
            push(
                &mut fs_leaf,
                &mut fi,
                Key {
                    objectid: 300,
                    ty: T_EXTENT_DATA,
                    offset: 0,
                },
                &x,
            );
        }

        // ---- extent + dev trees: empty leaves ----
        let extent_leaf = node(&fsid, EXTENT_TREE_AT, 2, 0);
        let dev_leaf = node(&fsid, DEV_TREE_AT, 4, 0);

        // ---- csum tree ----
        let mut csum_leaf = node(&fsid, CSUM_TREE_AT, CSUM_TREE, 0);
        if with_data {
            let mut ci2 = Vec::new();
            let mut cs = Vec::new();
            cs.extend_from_slice(
                &csum32(&img[DATA_AT as usize..DATA_AT as usize + 4096]).to_le_bytes(),
            );
            cs.extend_from_slice(
                &csum32(&img[DATA_AT as usize + 4096..DATA_AT as usize + 8192]).to_le_bytes(),
            );
            push(
                &mut csum_leaf,
                &mut ci2,
                Key {
                    objectid: EXTENT_CSUM_OBJ,
                    ty: T_EXTENT_CSUM,
                    offset: DATA_AT,
                },
                &cs,
            );
        }

        // ---- superblock ----
        let mut sb = vec![0u8; 4096];
        sb[0x20..0x30].copy_from_slice(&fsid);
        sb[0x30..0x38].copy_from_slice(&SB_OFF.to_le_bytes());
        sb[0x40..0x48].copy_from_slice(MAGIC);
        sb[0x48..0x50].copy_from_slice(&1u64.to_le_bytes()); // generation
        sb[0x50..0x58].copy_from_slice(&ROOT_TREE_AT.to_le_bytes());
        sb[0x58..0x60].copy_from_slice(&CHUNK_TREE_AT.to_le_bytes());
        sb[0x70..0x78].copy_from_slice(&(img.len() as u64).to_le_bytes());
        sb[0x80..0x88].copy_from_slice(&6u64.to_le_bytes()); // root_dir_objectid
        sb[0x88..0x90].copy_from_slice(&1u64.to_le_bytes()); // num_devices
        sb[0x90..0x94].copy_from_slice(&4096u32.to_le_bytes()); // sectorsize
        sb[0x94..0x98].copy_from_slice(&(NODE as u32).to_le_bytes()); // nodesize
        sb[0x98..0x9C].copy_from_slice(&(NODE as u32).to_le_bytes()); // leafsize
        sb[0x9C..0xA0].copy_from_slice(&4096u32.to_le_bytes()); // stripesize
        sb[0xC4..0xC6].copy_from_slice(&0u16.to_le_bytes()); // csum_type = crc32c
                                                             // dev_item
        sb[0xC9..0xD1].copy_from_slice(&1u64.to_le_bytes()); // devid
        sb[0xD1..0xD9].copy_from_slice(&(img.len() as u64).to_le_bytes());
        sb[0xE9..0xED].copy_from_slice(&4096u32.to_le_bytes()); // sector_size
        let label = b"G6LCBTRFS";
        sb[0x12B..0x12B + label.len()].copy_from_slice(label);
        // sys_chunk_array: the metadata chunk bootstrap.
        let mut sys = Vec::new();
        sys.extend_from_slice(&key_bytes(Key {
            objectid: 3,
            ty: T_CHUNK_ITEM,
            offset: CHUNK_TREE_AT,
        }));
        sys.extend_from_slice(&chunk_item(0x40_0000, CHUNK_TREE_AT, 4));
        sb[0xA0..0xA4].copy_from_slice(&(sys.len() as u32).to_le_bytes());
        sb[0x32B..0x32B + sys.len()].copy_from_slice(&sys);
        let sc = csum32(&sb[0x20..]);
        sb[0..4].copy_from_slice(&sc.to_le_bytes());

        img[SB_OFF as usize..SB_OFF as usize + 4096].copy_from_slice(&sb);
        img[CHUNK_TREE_AT as usize..CHUNK_TREE_AT as usize + NODE].copy_from_slice(&chunk_leaf);
        img[ROOT_TREE_AT as usize..ROOT_TREE_AT as usize + NODE].copy_from_slice(&root_leaf);
        img[FS_TREE_AT as usize..FS_TREE_AT as usize + NODE].copy_from_slice(&fs_leaf);
        img[EXTENT_TREE_AT as usize..EXTENT_TREE_AT as usize + NODE].copy_from_slice(&extent_leaf);
        img[DEV_TREE_AT as usize..DEV_TREE_AT as usize + NODE].copy_from_slice(&dev_leaf);
        img[CSUM_TREE_AT as usize..CSUM_TREE_AT as usize + NODE].copy_from_slice(&csum_leaf);
        img
    }
}

#[cfg(test)]
mod tests {
    use super::fixture;
    use super::*;

    #[test]
    fn a_hand_laid_btrfs_volume_reads_back() {
        let mut dev = MemBlock::new(fixture::image(true));
        let p = crate::probe::probe(&mut dev).unwrap();
        assert_eq!(p.kind, FsKind::Btrfs);
        let mut fs = Btrfs::mount(&mut dev, false).unwrap();
        assert_eq!(fs.label(), "G6LCBTRFS");
        let root = fs.list("/").unwrap();
        let names: Vec<&str> = root.iter().map(|e| e.name.as_str()).collect();
        assert!(
            names.contains(&"etc") && names.contains(&"hello.txt"),
            "{names:?}"
        );
        assert_eq!(fs.read("/hello.txt").unwrap(), b"hello\n");
        assert!(
            String::from_utf8_lossy(&fs.read("/etc/os-release").unwrap())
                .contains("G6LC btrfs Linux")
        );
        // The regular-extent file: both sectors, logical order.
        let d = fs.read("/data.bin").unwrap();
        assert_eq!(d.len(), 8192);
        assert!(d.starts_with(b"HEAD") && d[4096..].starts_with(b"TAIL"));
        // And a window into it doesn't read the whole file.
        let w = fs.read_window("/data.bin", 4096, 4).unwrap();
        assert_eq!(&w, b"TAIL");
    }

    #[test]
    fn in_place_write_updates_data_csum_and_size() {
        let mut dev = MemBlock::new(fixture::image(true));
        let mut fs = Btrfs::mount(&mut dev, true).unwrap();
        assert!(fs.writable(), "{:?}", fs.refusal);
        fs.write("/data.bin", &[0x5A; 8192]).unwrap();
        assert_eq!(fs.read("/data.bin").unwrap(), vec![0x5A; 8192]);
        // The csum tree now says what the medium says.
        let mut fs = Btrfs::mount(&mut dev, true).unwrap();
        let (_, size, _, _) = fs.inode(300).unwrap();
        assert_eq!(size, 8192);
        // Shrink: only i_size moves.
        fs.write("/data.bin", b"short").unwrap();
        let (_, size, _, _) = fs.inode(300).unwrap();
        assert_eq!(size, 5);
        assert_eq!(fs.read("/data.bin").unwrap(), b"short");
        // Past the coverage is refused with the numbers.
        let err = fs.write("/data.bin", &vec![0u8; 8193]).unwrap_err();
        assert!(err.to_string().contains("8193"), "{err}");
    }

    #[test]
    fn create_and_mkdir_land_inline() {
        let mut dev = MemBlock::new(fixture::image(false));
        let mut fs = Btrfs::mount(&mut dev, true).unwrap();
        fs.mkdir("/boot").unwrap();
        fs.write("/boot/grub.cfg", b"set default=0\n").unwrap();
        let root = fs.list("/").unwrap();
        assert!(root.iter().any(|e| e.name == "boot" && e.dir), "{root:?}");
        assert_eq!(fs.read("/boot/grub.cfg").unwrap(), b"set default=0\n");
        // Remount: the structures persist.
        let mut fs = Btrfs::mount(&mut dev, true).unwrap();
        assert_eq!(fs.read("/boot/grub.cfg").unwrap(), b"set default=0\n");
        // Over the inline cap is refused, naming the cap.
        let err = fs
            .write("/big.bin", &vec![0u8; INLINE_CAP + 1])
            .unwrap_err();
        assert!(err.to_string().contains("inline"), "{err}");
    }

    #[test]
    fn read_only_mount_and_remove_are_named_refusals() {
        let mut dev = MemBlock::new(fixture::image(true));
        let mut fs = Btrfs::mount(&mut dev, false).unwrap();
        let err = fs.write("/data.bin", b"x").unwrap_err();
        assert!(err.to_string().contains("read-only"), "{err}");
        let err = fs.remove("/hello.txt").unwrap_err();
        assert!(err.to_string().contains("unlink"), "{err}");
        // The edit terms are stated before the work.
        let b = fs.edit_budget("/data.bin").unwrap();
        assert!(!b.writable);
        let mut fs = Btrfs::mount(&mut dev, true).unwrap();
        let b = fs.edit_budget("/data.bin").unwrap();
        assert_eq!(b.max_bytes, Some(8192));
        assert!(b.summary().contains("btrfs rw"), "{}", b.summary());
        let n = fs.edit_budget("/new.cfg").unwrap();
        assert!(
            n.can_create && n.max_bytes == Some(INLINE_CAP as u64),
            "{n:?}"
        );
    }
}
