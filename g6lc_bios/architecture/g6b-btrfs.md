# btrfs — copy-on-write B-tree BIOS writes

Btrfs is the most complex filesystem `g6b-vfs` supports, because *nothing* lives at a fixed
offset for long. This document describes the host-side driver, the deliberately narrow write
surface a BIOS may use, and the fixture that exercises every checksum and key ordering without
relying on distro `mkfs.btrfs`/`btrfs check` being present on the build host.

## On-disk contract

The canonical references are `fs/btrfs/btrfs_tree.h` and the "On-disk Format" documentation.

* The **superblock** sits at `0x10000`, magic `"_BHRfS_M"` at `+0x40`. It names the node size,
  the chunk tree root, the root tree root, and carries a bootstrap `sys_chunk_array` of chunk
  items so the chunk tree itself can be found.
* Everything is addressed **logically**; a chunk item maps `[logical, logical+len)` to a
  stripe on a device. Only single-stripe chunks are mapped — a RAID profile is refused rather
  than half-read.
* A **node** (`nodesize` bytes) is `{csum[32], fsid[16], bytenr, flags, chunk_tree_uuid,
  generation, owner, nritems, level}` — 101 bytes — then a leaf holds `item[n]` headers
  `{key(17), offset u32, size u32}` with the data packed **downward from the end of the node
  in key order**; an interior node holds `keyptr[n]` `{key, blockptr, generation}`.
* `csum` = raw `crc32c(seed=0, node[32..nodesize])` — the lib `crc32c` convention, no pre/post
  inversion — stored in the first four csum bytes. A node that fails it is reported corrupt,
  not silently parsed.
* The **root tree** holds `ROOT_ITEM`s naming where every other tree's root lives — the FS tree
  (objectid 5, the default subvolume) and the csum tree (objectid `-10`) among them. The FS
  tree then keys everything by `(objectid, type, offset)`: inodes are `INODE_ITEM`, name→inode
  is `DIR_ITEM` keyed by `crc32c(~1, name)` plus a `DIR_INDEX` for ordering, and file content
  is `EXTENT_DATA` — inline (the bytes live in the leaf) or regular (a
  `(disk_bytenr, disk_num_bytes, offset, num_bytes)` run).

## BIOS write surface (leaf-level only)

Even narrower than ext4, because the cost of a wrong btrfs write is a *tree*, not a file.
The driver performs three operations, all leaf-level:

* **in-place data write** — an existing regular file, inside the extents it already has,
  *with the csum tree refreshed for every written sector*. A btrfs write that skips the csum
  is a filesystem error the next time the OS reads the file — `btrfs check` would find it even
  when the data is right.
* **inline-extent replace** — a file whose bytes live in the leaf is rewritten by replacing
  the item in place (data shifts, offsets follow, csum re-sealed). That is how the store's
  repeated `store.json` flushes land on one path.
* **create / mkdir** — the inode + inode-ref + dir-item + dir-index + (for a file) inline-extent
  inserts, bounded by `max_inline` (2048) and the leaf's measured free space, which is checked
  before a byte moves.

## Refused and named

Everything past a leaf is refused with an explicit reason:

* extent allocation and backrefs (that is the OS's allocator, not a BIOS write's);
* `remove` (unlink + backrefs in reverse);
* multi-device/RAID and zoned/extent-tree-v2/stripe-tree volumes.

## Verification limit

`mkfs.btrfs` and `btrfs check` are not on this host, so the fixture is hand-laid to the
on-disk spec — every checksum and key ordering is real. A `btrfs check` run belongs on a host
that has one; the fixture is the gate for the unit tests, and the pglite store round-trip in
`crates/g6b-kernel` is the gate for real file-level r/w through the shared VFS.

## File locations

| Concern | File |
|---|---|
| Driver + fixture + unit tests | `crates/g6b-vfs/src/btrfs.rs` |
| Superblock/magic probe | `crates/g6b-vfs/src/probe.rs` |
| pglite store r/w through btrfs | `crates/g6b-kernel/src/vfs.rs` (`a_store_round_trips_through_btrfs`, `a_libwasm_cell_posts_sql_through_fetch_post_to_a_btrfs_key`) |
| Autoboot os-release detection (btrfs root) | `crates/g6b-zealcli/src/detect.rs` |
