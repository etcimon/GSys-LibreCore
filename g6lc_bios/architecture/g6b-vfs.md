# g6b-vfs — real block devices, partitions and filesystems

**Status:** B106 landed. 38 crate tests, plus kernel-side mount-table tests, plus
verification against images produced by `mkfs.vfat` / `mkfs.ext4` and checked by
`fsck.vfat` / `e2fsck` / `debugfs` / `mtools`. The store (g6b-pglite) persists
through the mount table now — see *The store is a volume client* below — and it
does so on **btrfs** as well as FAT32.

One implementation of "what is on this disk", shared by every face:

```text
  Vfs / MountPort (mount table, friendly names, path resolution)
    ├── g6b-zealcli   cd · ls · cat · vi + :w · mount · drives
    ├── g6b-holyc     Mount · Mounts · Drives · VfsLs · VfsCat · VfsWrite · OsDetect
    ├── browser UI    the same answers as JSON (kernel router / WASM host)
    └── g6b-pglite    StoreVolume → export/import dumps onto a real volume
          │
          FileSystem ── fat32 (rw) · ext4 (ro + guarded rw) · ntfs (ro) · btrfs (ro + leaf rw)
            └── BlockDev ── FileBlock (image / raw disk) · SubDev (partition) · MemBlock
```

## Three rules, because this code can destroy a system

1. **Evidence over claims.** A partition type is what a table *claims*; the
   superblock is what is *there*. `probe` decides, and every answer carries the
   field that decided it.
2. **Read-only is the default and a refusal is explicit.** Writability comes from
   the device, then the mount, then the filesystem's own state — a dirty ext
   journal blocks a write mount and says so. No path silently downgrades.
3. **No half-writes.** An allocation that cannot fit fails before anything is
   written, and every metadata copy (both FATs, the FSInfo free count, the ext4
   inode checksum) is updated.

## Partition tables

**GPT** (UEFI 2.10 §5.3): header at LBA 1 with `"EFI PART"`, 128-byte entries,
and **both CRC32s checked** — a bad CRC is reported as a warning, not hidden, and
the table is still usable. Type GUIDs are decoded to name a partition (`esp`,
`linux-root-riscv64`, `ms-basic-data`…); an unknown GUID is kept verbatim, which
is more useful than "unknown". **MBR** is the fallback (`0xEE` defers to the GPT),
and a device with no table gets one synthetic whole-disk partition, so callers have
exactly one code path.

## Filesystems

| | read | write | proof |
|---|---|---|---|
| **FAT32** | yes, incl. VFAT long names | **yes** — create, overwrite, grow, shrink, `mkdir`, `remove`, **long-name creation** | `fsck.vfat` clean, `mtools` reads it |
| **ext2/3/4** | yes — extents *and* classic direct/indirect, fast symlinks | **yes** — in-place overwrite, tail growth by allocation, file/dir creation, `metadata_csum` re-sealed | `e2fsck -fn` clean, `debugfs` reads it |
| **NTFS** | yes — `$MFT` walk, fixups, resident + run-list `$DATA` | **resident $DATA in place** — `write` updates the MFT record and re-stamps `$LogFile` as clean; non-resident and new files refused | tested against a hand-built spec-shaped volume |
| **btrfs** | yes — chunk map, tree walk, dir/file/inline extents | **leaf-level** — in-place in existing extents, inline-extent replace, create+mkdir | hand-built spec-shaped volume; csums and key order exercised |
| exFAT / FAT16 / ISO 9660 | identified | no | named and refused, not mistaken for FAT32 |

### FAT32 writing

Both FAT copies and the FSInfo free count are kept in step, because the next thing
to mount the volume is an OS that trusts them. Long names matter for one concrete
reason: the removable-media UEFI path is `\EFI\BOOT\BOOTRISCV64.EFI` — 11
characters of basename — so an 8.3-only writer could not repair an ESP at all. The
driver writes the LFN chain with a `BOOTRI~1.EFI` alias and the name checksum, the
same convention `mkfs`/Windows use. A name of only dots is refused: a file called
`..` would make the tree unwalkable.

### ext4 writes allocate and re-seal metadata checksums

A journalling filesystem is not something a BIOS should rewrite casually, so the
write surface is still bounded: an **existing regular file** can be overwritten in
place and grown at the tail by allocating fresh blocks, a **new file or directory**
can be created, and **sparse files are left untouched** (writing into an unmapped
hole in the middle of a file is refused rather than leaving a half-built extent
tree). The superblock must still be clean and the journal must not need recovery;
otherwise the mount is read-only and says so.

Allocation walks the block and inode bitmaps, updates the group descriptor free
counts, and re-seals every checksum the filesystem checks:

* **superblock** — `crc32c(~0, sb[0..1020])` (the `s_checksum` field is zeroed
  while computing).
* **group descriptors** — `crc32c(s_csum_seed, gd)` with the 16-bit `bg_checksum`
  field zeroed.
* **block / inode bitmaps** — `crc32c(s_csum_seed, bitmap)`; only the bytes that
  carry bits are checksummed (`per_group/8`, capped at one block).
* **inodes** — seed = `s_csum_seed` chained with the inode number and
  `i_generation`; the record is checksummed with `i_checksum_lo` / `i_checksum_hi`
  zeroed.
* **directory blocks** — `i_csum_seed` over the block *before* the 12-byte
  checksum tail (`{inode:0, rec_len:12, name_len:0, file_type:0xDE, csum}`).

`map_grow` appends to the 60-byte in-inode extent tree, merging contiguous runs,
re-read the tree from the device between calls so multiple growth steps do not
overwrite each other, and falls back to the 12 direct blocks for classic ext2/3.
`e2fsck -fn` is clean after creating and growing a file on the real
`out/media/real-ext4.img` produced by `tools/mkfs_fixtures.sh`. A filesystem driver
validated only against its own fixture is validated against its own misunderstanding
— `tools/mkfs_fixtures.sh` exists so that cannot happen again.

### btrfs is copy-on-write — leaf-level BIOS writes (B105)

The btrfs driver and its deliberately narrow write surface are documented in
[`architecture/g6b-btrfs.md`](g6b-btrfs.md). In short: every node checksum and
`bytenr` are verified on read; writes are in-place inside existing regular
extents, inline-extent replacement, or create/mkdir bounded by leaf free space;
and everything past a leaf (extent allocation, `remove`, multi-device/RAID,
zoned profiles) is refused with a reason.

### Guest file-level reads (B108)

The S-mode payload now reads its own sectors and, when the medium is FAT32 or
ext4, a named file from the root directory (`g6b-asm::vio`:
`BlkInit`/`BlkRead`/`BlkSig`; `g6b-asm::fatfile`: `FatRead`;
`g6b-asm::ext4file`: `Ext4Read`).

`BlkSig` names the medium and latches it into a `BLK_SIG` kind word
(`0 none, 1 fat, 2 gpt, 3 mbr, 4 ext4, 5 raw`). It detects a plausible FAT32 BPB
from LBA 0 (512 BPS, non-zero SPC, zero `RootEntCnt`, zero `FATSz16`, non-zero
`TotSec32`, non-zero `FATSz32`) and reports `BLK-SIG fat` without reading LBA 1;
a medium with no `0x55AA` boot signature is probed at LBA 2 for the ext4
superblock magic `0xEF53` and reports `BLK-SIG ext4`, keeping the superblock
cached. Each file reader gates on `BLK_SIG` rather than re-parsing the buffer —
`BLK_CUR_SECTOR` alone cannot say *why* a sector is cached — so a reader for a
filesystem that is not present returns silently and costs nothing.

The bounded FAT32 reader:

* reads the BPB from the cached sector;
* computes `data_start = rsvd + num_fats * fatsz32` and `root_lba`;
* walks the root directory for an 8.3 filename (hard-coded `HELLO.TXT` for the
  smoke target; `FILE-NOTFOUND` if missing);
* follows the cluster chain from `DIR_FstClus` and reads the first cluster;
* prints `FILE-FOUND <first 15 bytes>` as evidence.

The bounded ext4 reader (`ext4 superfloppy` — the superblock at byte 1024 sits
at LBA 2):

* parses the superblock from the cached sector: `s_log_block_size` (block size =
  `1024 << n`, sectors/block = size/512), `s_inode_size`,
  `s_inodes_per_group`;
* locates the group-0 descriptor table (block 2 for 1 KiB blocks, block 1
  otherwise) and reads `bg_inode_table_lo`;
* reads inode 2 (the root), requires a directory `i_mode` and **refuses an
  extent tree** (`EXT4_EXTENTS_FL`) — the reader understands classic
  direct-block `i_block` maps only;
* walks the root directory's first sector for a fixed name (`hello.txt`);
* resolves the entry's inode through the same table, requires a regular-file
  `i_mode` and no extents, reads `i_block[0]`, and prints
  `FILE-FOUND <first 15 bytes>`.

Both are **deliberately small** implementations that duplicate only the minimum
on-disk structures needed for boot-time reads, not a second VFS — no extent
trees, no multi-sector directories, no path traversal, no writes. The host VFS
(`crates/g6b-vfs/src/fat32.rs`, `crates/g6b-vfs/src/ext4.rs`) remains the
reference for on-disk layout.

**Status:** FAT32 and ext4 guest reads landed and tested in `g6b-asm::exec` with
modelled 64-sector superfloppies (`modelled_fat32_image`,
`modelled_ext4_image`). Loading a payload by name — e.g. `cd`-into-`/` +
payload `BOOT` — remains open, as does wiring these reads into the boot
selector.

### NTFS writing is bounded to resident $DATA (B107)

NTFS expects every metadata change to be logged in `$LogFile` so a Windows boot or
`chkdsk` can roll it forward or back. A minimal, honest BIOS write therefore stays
inside the **resident** `$DATA` attribute of an existing file, rewrites the MFT
record with the new bytes (and a fresh update-sequence fixup), and re-stamps the
first two `$LogFile` restart pages as `CleanDismount`. Non-resident files, new
files, directories, and growth are refused with the reason. The `$LogFile` is also
checked at mount: if it is missing or does not parse as clean, the whole volume is
treated as read-only. This is not a full NTFS transaction log, but it keeps a
small Windows file editable by the BIOS without leaving the volume structurally
unmountable.

## Mount table (`g6b-kernel::VfsService`)

A `g6b-vfs` filesystem *borrows* its device: right for a driver, wrong for a mount
table that outlives a call. So the service owns the **devices** and mounts on
demand — each operation opens the partition, works, drops the driver. What persists
is the *mount decision* (drive, partition, name, granted mode), because that is
what an operator asked for and what `mount` must show. A BIOS does a handful of
filesystem operations per keystroke, and that cost buys a mount table that cannot
hold a dangling borrow.

## In the shell

Three path shapes reach the same place, because operators arrive from three habits:

| shape | example |
|---|---|
| unix mount point | `cd /mnt/root/etc` |
| ZealOS drive | `cd root:/etc` |
| relative | `cd etc` · `cat fstab` · `vi fstab` |

A name that is a **known but unmounted** volume is mounted on the spot, read-only,
and says so — walking into a directory should not need a ceremony, and read-only
cannot damage anything. Writing needs `mount -w`. `drives` lists every drive, its
table, every volume with what it holds and what state it is in; `mount` with two
candidates **lists them and refuses to guess**, because a BIOS picking the wrong
partition to write is the worst outcome available to it.

`vi` becomes an editor exactly where the file can be written back: same motions,
plus `i`/`I`/`a`/`A`/`o`/`O`/`x`/`dd`, `:w`, `:wq`, `ZZ`, and `:q` refusing to
discard an unsaved edit. Everywhere else it stays the read-only viewer, and the
refusal names the reason (`E45: 'readonly' — ext journal needs recovery`).

## OS detection

Read from the volume, never from the table: `/etc/os-release` (`PRETTY_NAME`),
`/etc/openwrt_release` (`DISTRIB_DESCRIPTION`), `.disk/info` for live media, then
layout (`/EFI/BOOT/BOOTRISCV64.EFI`, a Windows install, `/etc`+`/boot`). No file,
no claim. It feeds the boot picker's rows and the browser UI's device panel from
one place.

## Verified against the distro's own tools

`tools/mkfs_fixtures.sh` builds `real-fat32.img`, `real-ext4.img` and a
`real-gpt.img` holding both. Then:

```
$ g6b vfs scan --disk out/media/real-gpt.img
disk0:1 name=g6lcfat  fs=fat32 label="G6LCFAT"  kind=esp               mountable=true
disk0:2 name=g6lcroot fs=ext4  label="g6lcroot" kind=linux-filesystem  mountable=true

$ g6b vfs ls  --disk … --part 1 --path /EFI/BOOT   → BOOTRISCV64.EFI (19 MB), startup.nsh
$ g6b vfs cat --disk … --part 2 --path /etc/fstab  → the real file
$ g6b vfs os  --disk … --part 2                    → G6LC Real Linux 24.04
```

and through the shell itself, on the same disk:

```
/> mount -w disk0:2 as root      mounted root at /mnt/root (ext4, rw)
                                   installed: G6LC Real Linux 24.04
/mnt/root/etc> write fstab /dev/vda7 / ext4 errors=remount-ro 0 1
WRITE-OK 38 bytes -> /mnt/root/etc/fstab
/mnt/root/etc> write biosmade.cfg debug=1
WRITE-OK 11 bytes -> /mnt/root/etc/biosmade.cfg
```

after which `debugfs -R 'cat /etc/fstab'` and `debugfs -R 'cat /etc/biosmade.cfg'`
show the new files and `e2fsck -fn` reports no errors. The FAT32 side is checked
the same way with `mtools` + `fsck.vfat`, including a newly created long-named
file.

## Editing: the filesystem's terms, stated first (B102)

An editor in a BIOS is only useful if a save either happens or is refused *before*
the work is typed. So every driver answers `edit_budget(path)` up front, and `vi`
puts the answer in its status line:

| filesystem | terms |
|---|---|
| **FAT32** | `fat32 rw` — creates, grows, shrinks; the ceiling is the file's own clusters plus the free ones, **counted** rather than taken from the advisory FSInfo hint |
| **ext4** | `ext4 rw` — in-place overwrite and tail growth by block allocation; file and directory creation; sparse mid-hole writes refused |
| **btrfs** | `btrfs rw` — in place inside existing extents (csum tree refreshed), inline extents replaceable ≤2048B, create lands data inline |
| **NTFS** | `ntfs rw <=N B in place` — resident $DATA only; the MFT record is rewritten and `$LogFile` re-stamped clean; non-resident and new files refused |

`:w` checks the ceiling before writing (e.g. `E212: 6712 bytes will not fit — 1024
is the limit here (fat32 rw)`), the buffer stays open so the operator can shorten
it, and the file on the volume is untouched. After a successful write the session
**reads the bytes back and compares** — a BIOS write is the last thing to touch a
volume before a reboot, so "the driver returned `Ok`" is not evidence.

Three fidelity rules, because a BIOS edits files *other systems wrote*:

* **CRLF is preserved.** A DOS-ending `extlinux.conf` is the normal case (the
  installer ran on Windows). Normalizing on save rewrites every line, which turns a
  one-line repair into an unreviewable diff and can break a strict loader. The
  status line says `[dos]`.
* **A UTF-8 BOM is preserved**, and so is a missing final newline.
* **A file larger than 256 KiB opens read-only**, naming both sizes. Saving a
  prefix would truncate the file to whatever fit on screen — data loss disguised as
  an edit.

### The sparse-file bug this pass found

`blocks_of` returned physical blocks *in order* and dropped `ee_block`, the logical
block an extent starts at. For a file with a hole that means every later block is
pulled forward into the gap: the file comes back **rearranged**, which is worse than
missing, because it looks like data. The map is now logical→physical, a hole reads as
zeros at its own offset, an uninitialized extent is left unmapped (the OS still has
to convert it), and an in-place write is refused when it would reach past the
contiguously mapped prefix.

Verified against a file the **Linux kernel** made sparse (loop-mounted the real
`mkfs.ext4` image, wrote at 0 and at 12288 — `filefrag` shows logical 0 and 3
mapped):

```
Linux stat: 12292 bytes    ours: 12292 bytes
offset 0     → HEAD        offset 4096 (hole) → zeros
offset 12288 → TAIL        ← at its logical offset, not pulled forward
```

and the write guard on the same file: *“sparse file — only logical blocks 0..1 are
mapped and 8000 bytes need 2”*, with the file unchanged. `e2fsck -fn` stays clean
after in-place writes.

## The boot selector reads volumes now

`boot` (the EDK2/U-Boot selector) probes every mountable volume by **mounting it
read-only and looking**, ESPs first. A target is offered only when the loader file
was actually read, and the row says where from:

```
edk2@g6lcesp   edk2   g6lcesp   /EFI/BOOT/BOOTRISCV64.EFI   read from disk0:1 (fat32, G6LCESP)
```

`\EFI\BOOT\BOOTRISCV64.EFI` is the UEFI removable-media path (UEFI 2.10 §3.5.1.1)
— what makes an ESP bootable with no NVRAM entry. U-Boot is recognized by
`u-boot.itb`/`u-boot.bin` **and** by what it would boot
(`extlinux/extlinux.conf`, `boot.scr`), because "u-boot is here" and "u-boot has
something to boot" are different facts. The probe mount is transient and named
`probe-<drive>-<index>`, so it never occupies a name an operator wanted and never
survives the call.

## The store is a volume client (B104)

`g6b_pglite::StoreVolume` is the seam between the SQL engine and the mount table:
`SharedVfs` (the same `VfsService` the shell mounts with) implements it, and
`StoreRegistry::attach_volume` swaps the registry's in-memory `usb` map for the
medium. Three consequences that are easy to get wrong and were not:

* **The file on the volume is JSON.** `export` writes the dump's JSON text, not
  the packed blob — an operator who pulls the key has to be able to read it with
  the OS they plug it into. (`codec::unpack` already accepts raw JSON, so the
  import side is unchanged.) The packed form stays in the in-memory cache.
* **Collision checks look at the medium, not the cache.** Refusing to overwrite
  *another store's* dump at the same path is the point of the uuid check, and a
  check that only saw this process's map would miss a file written by an earlier
  boot — exactly the clobber that costs an operator their data.
* **`import` reads the medium first**, then the cache. An import is an operator
  plugging a key in and asking what is on it; reading only the process's map made
  it mean "restore what I already had".

`resolve_store_mount` maps the spec's filesystem-kind name (`fat32`, `ntfs`,
`ext4`, `btrfs`) to the one mounted instance and **refuses to guess** when two
exist — same discipline as `mount` in the shell. The btrfs leg is exercised end
to end: `a_store_round_trips_through_btrfs` creates/inserts/exports onto a btrfs
key, reads `store.json` back off the medium, and imports it into a fresh
registry.

The browser side reaches it through `fetch_post`, gated to `/bios/store` only: a
libwasm `_start` cell issues `window.fetch_post("/bios/store/<uuid>/exec", …)`
via `Object_Call_string_string__Handle`, reads the response with
`libwasm_get__string` (an sret `(len, ptr)` the interpreter writes into linear
memory, JS-kernel parity), and the registry exports onto the key. The whole chain
is tested at `_start` level against a real FAT32 image, including the
fresh-registry import on the other side
(`vfs::tests::a_libwasm_cell_posts_sql_through_fetch_post_to_a_usb_key`).

## The guest side: the payload reads its own sectors (B101)

Everything above this section runs on the **host** side of the BIOS. B101 adds the
first piece on the *guest* side: a real virtio-blk driver in the S-mode payload
(`g6b-asm::vio` → `BlkInit` / `BlkRead` / `BlkSig`, gated by
`BoardSpec::wants_virtio_blk()` = `uncore.storage` + a CLI/picker + the virtio
transport).

* **`BlkInit`** scans the virtio-mmio window for DeviceID 2, performs the same
  virtio 1.x handshake every other device here does, and brings up the requestq
  (queue 0) with rings in `__vio+BLK_*`. It accepts `VERSION_1` and **nothing
  else**: an accepted feature the driver does not implement changes the request
  format under a parser that cannot follow it. Prints `VIRTIO-BLK <slot>` and
  `VIRTIO-BLK-OK`, or `-NONE`/`-FAIL`.
* **`BlkRead`** submits the three-descriptor chain virtio-blk mandates (spec
  5.2.6): a read-only 16-byte `{type, reserved, sector}` header, a device-writable
  512-byte landing zone, and a one-byte device-writable status. **The status byte
  decides success, not the used ring** — a device can complete a request and report
  `IOERR`, and a reader that only checks the ring would then parse the *previous*
  sector as the one it asked for.
* **`BlkSig`** reads LBA 0, and LBA 1 when a `0x55AA` boot signature suggests a
  table, then names the medium from its own bytes: `BLK-SIG gpt` when LBA 1 carries
  `"EFI PART"`, else `mbr`, else `raw`. A protective MBR's `0xEE` type byte is a
  claim; the header signature is evidence.

The block layout sits past `__vio`'s 12-bit immediate reach, so the routines form
one **base register** for it — cheaper than an address computation per access, and
the reason the `BLK_*` offsets are relative.

**QEMU 8.2, real images** (`tools/qemu_blk.sh`, read-only drive — a driver on its
first outing has no business being able to write an operator's medium):

```
VIRTIO-BLK 5      VIRTIO-BLK-OK      BLK-SIG gpt    ← real sfdisk GPT (ESP + ext4)
VIRTIO-BLK 5      VIRTIO-BLK-OK      BLK-SIG mbr    ← real mkfs.vfat superfloppy
```

The same ELF distinguishes them, so the LBA-1 check does real work rather than
echoing the boot signature. Two bugs the hardware found that the model had not:
the used-ring poll compared against **zero** instead of the shadow index, so the
second request in a run returned before the device answered (`BLK-ERR` on the LBA 1
read of a real GPT disk); and the 0x1000 slot stride does not fit an `addi`
immediate.

## Not done yet (named, not hidden)

* **The guest can read sectors but not *files*.** `BlkSig` identifies a medium;
  locating `/boot/Image` on it needs a filesystem *in the payload*, and the drivers
  above are host Rust, not ASM IR. So `AUTOBOOT-HANDOFF` is still staged: the
  picker's entries come from host-supplied media, not yet from guest block reads.
  The honest next steps are (a) build picker entries from `BlkSig`/`BlkRead`, and
  (b) decide the split — a minimal guest FAT32 reader for the ESP path versus
  loading a kernel written to a raw partition at a known offset.
* USB mass-storage (the other transport a board will actually have).
* btrfs **extent-tree allocation** (growing past existing extents), `remove`
  (unlink + backrefs), node splits, and anything multi-device/RAID/zoned; a
  `btrfs check`-equivalent run once a host has the tool.
* NTFS writing; exFAT and FAT16 at all.
* Directory-index (`$INDEX_ALLOCATION`) walking for NTFS — the `$MFT` scan is
  used instead, which is simpler and slower.
* FAT32 create timestamps are the **FAT epoch** (1980-01-01), not the real time: a
  BIOS has a monotonic counter from OpenSBI, not a date. That is the honest
  "unknown" for this format, and it is one function (`stamp`) to change when a
  board gains an RTC.
