# USB host — FAT32 flash always, key file manager extra

USB is a **compiled host**, not a netdev and not a Linux VFS. QEMU BIOS argv
still never grows `-netdev`. TempleOS/ZealOS `FileMgr` (`kernel-spec/**/FileMgr.*`)
is the spec of *intent* (pick a file, walk a tree) — not RedSea, not a port.

```
BoardSpec kernel.usb
        │
        ├─ enable + flash_fat32   ── always compiled ──► FAT32 MSC stick
        │         GET  /bios/usb
        │         GET  /bios/usb/ls          openwrt.bin / g6lc_bios.elf / linux.img
        │         POST /bios/usb/flash       firmware only (FAT32)
        │         HolyC UsbLs("flash") / UsbFlash("openwrt.bin")
        │
        └─ key + fs_{fat32,ntfs,ext4}  ── extra ──► USB-key file manager
                  GET  /bios/files
                  GET  /bios/files/{fat32,ntfs,ext4}
                  HolyC UsbKey / UsbLs("ntfs")
                  svelte-d FileMgr (not SvelteKit)
```

`g6b-fs` is a **canned host listing**. It does not parse on-disk FAT/NTFS/ext4
and does not mount Linux. Guest MSC is a later QEMU `-device usb-storage`
hypothesis (still not a NIC).

## Always-on FAT32 flash

Every named profile (`embedded` … `full`) and the `Usb` default compile
`kernel.usb.enable` + `flash_fat32`. A router with no browser-UI still lists
firmware on a FAT32 stick and can `POST /bios/usb/flash`. Disabling USB
entirely is an explicit JSON overlay (`usb.enable=false`) and is illegal
together with `settings.usb_key` or `usb.key`.

Firmware names the BIOS will flash from FAT32:

| File | Role |
|---|---|
| `openwrt.bin` | OpenWrt / router image (`kernel.flash.openwrt`) |
| `g6lc_bios.elf` | BIOS self-update |
| `linux.img` | next-stage payload |

NTFS and ext4 **never** participate in flashing. A `.bin` on an NTFS key is
visible in the file manager; flash still copies it onto the FAT32 stick first
(or the operator uses SPI/mailbox). That split keeps the embedded/router path
small: one FAT32 directory of images, no NTFS/ext4 decoder in those builds.

Compiled gates:

| `#define` / feature | Meaning |
|---|---|
| `G6LC_USB` / `usb` | host compiled |
| `G6LC_USB_FAT32` / `usb_flash_fat32` | FAT32 flash stick (default on) |
| `G6LC_USB_KEY` / `usb_key` | elaborate file manager |
| `G6LC_FS_FAT32` / `fs_fat32` | key volume FAT32 |
| `G6LC_FS_NTFS` / `fs_ntfs` | key volume NTFS |
| `G6LC_FS_EXT4` / `fs_ext4` | key volume ext4 |

Boot markers: `USB-FAT32` always when the host is on; `USB-FILES fat32/ntfs/ext4`
only with `usb.key`.

## USB-key file manager

`kernel.usb.key` (profiles `appliance` and `full`, or JSON overlay) adds a
three-family browser: FAT32 + NTFS + ext4. Settings import/export on the key
(`kernel.settings.usb_key`) rides the same host; it is not a second USB stack.
Structured **store** dumps (`kernel.store.persist.usb`) are a sibling
tree `{volume}/stores/{purpose}/{uuid}.g6bstore` on the **key**, never on
FAT32 flash. Live persist is `UsbLive` (auto-flush G6BS). Poll
`GET /bios/store/{uuid}/stat` until `live && ready` for a dialog that
requires the stick. Svelte: [`g6b-pglite-svelte.md`](g6b-pglite-svelte.md).
Identity: [`g6b-store-instances.md`](g6b-store-instances.md).

Canned trees (`g6b-fs::list_key`):

| FS | `/` | deeper |
|---|---|---|
| FAT32 | `settings.json`, `backup/` | `backup/settings.bak`; `stores/` when `persist.usb` |
| NTFS | `Windows/`, `bios-settings.json` | `stores/` when `persist.usb` |
| ext4 | `home/`, `etc/` | `home/config.json`; `stores/` when `persist.usb` |

ZealOS FileMgr pick-file / pick-dir is the UI contract. The rewrite is
svelte-d `Construct::FileMgr` + kernel `fetch`, not `kernel-spec` FileMgr.ZC
and not SvelteKit `+page` routing.

## Profiles

| Profile | FAT32 flash | Key file manager |
|---|---|---|
| `embedded` | yes | no |
| `router` | yes (OpenWrt `.bin`) | no |
| `desktop` | yes | no (settings UART/mailbox) |
| `appliance` | yes | yes (FAT32/NTFS/ext4) |
| `full` | yes | yes |

JSON overlay still wins: `"usb":{"key":true}` on a desktop spec turns the
file manager on and defaults NTFS+ext4 unless those flags are set false after.

## Not this package

Linux VFS, FUSE, NTFS write, ext4 journal replay, compiling Botan/svelte-d,
Chromium file inputs, SvelteKit, a BIOS **netdev**, QEMU `-netdev`. USB after
`NET-DELEGATE` is the same mailbox `/dev/g6lc-bios` path as every other BIOS
verb — the stick is gone; listings stay view-only if the OS kept the MSC.

Browser layout: [`BROWSER.md`](BROWSER.md). Endpoints: [`KERNEL-API.md`](KERNEL-API.md).
