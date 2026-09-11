# g6b-zealcli — the minimally dependent BIOS face

**Status:** B94/B95 landed. Green: `python tools/g6b.py check`. Crate
`g6b-zealcli` depends only on `g6b-holyc` + `g6b-spec` — **not** `g6b-hw`, not
the web stack, not browser-ui.

A ZealOS-shaped shell in a fixed text container: output scrolls above, the
command prompt is the **bottom row**, and everything an operator needs — adjust
settings, browse a USB key, read a file, update firmware, choose the next boot
stage — is reachable with a keyboard alone. Bash spellings and the ZealOS names
are the same commands (`ls`/`Dir`, `cat`/`Type`, `rm`/`Del`), and any *registered*
HolyC builtin can be called from the prompt.

## Boot order: CLI first, always

`kernel.cli.enable` (default on). `kernel.cli.boot`:

| value | Face |
|---|---|
| `cli` | always the VGA container (barebone builds) |
| `auto` | container first, browser-ui after the GPU probe (`LoadUI`) |
| `ui` | **refused** while the web stack is compiled — drop the CLI with `cli.enable=false` instead |

`BoardSpec::wants_zealcli(gpu_ready)` / `cli_before_web()` /
`g6b_kernel::wants_zealcli`. A build that carries the whole engine still reaches
*this* prompt first: the generated `KMain` calls `CliBoot()` before `UiBoot()`,
the boot log prints `ZEALCLI-READY …` before `UI-BOOT`, and `LoadUI()` returns
`Action::LoadUi` so the kernel can hand the screen over.

## The container (`screen.rs`)

`kernel.cli.rows` × `cols` (VGA text 25×80), `scrollback` lines in a bounded
ring that reports what it dropped. Content is **bottom-aligned**, so the newest
line sits directly above the prompt. `PgUp`/`PgDn` page, `scroll top|tail`
jumps; while scrolled back the row above the prompt states the range, and any
new output snaps back to live. `kernel.cli.mouse` (default **off**) adds wheel
scrolling and click-to-live; every pointer action has a key equivalent.

## Input (`input.rs`)

One alphabet: **Linux `KEY_*` codes**. A USB HID keyboard (the primary source on
real hardware), virtio-keyboard (`g6b_asm::vio::VIO_KEY_*`, QEMU `sendkey`) and
the UART band all decode the same way, so `Session::keycode(code, pressed)` is
the whole seam. `BoardSpec::keyboard_kind()` reports which one this board has.

## Capabilities are ports, not dependencies (`ports.rs`)

The kernel owns the adapters and lends poll-shaped interfaces:
`VolumePort` (drives/dirs/files), `NetPort` (`get` + `poll` + `cancel`),
`FlashPort` (`stage` → digest, `commit`). `g6b-kernel::zealcli` implements them
over `g6b-hw` TCP, `g6b-http`, `g6b-tls` and the flash backend. A missing
capability is **absent**, and the prompt says which BoardSpec flag is off.

## Modules

| Module | What |
|---|---|
| `screen` | container, scrollback, scrolling, bottom prompt |
| `input` | Linux keycodes, line editor, history, mouse |
| `cmd` | the one command table behind dispatch, `help` and `man` |
| `settings` | writable-row overlay → BoardSpec JSON patch |
| `fsview` | ZealOS drives (`KEY-FAT:/backup`), listings, text reads |
| `vi` | light **read-only** vi (motions, `/`, `:set number`, `:q`) |
| `fw` | poll-driven firmware update, HTTPS or USB key |
| `boot` | edk2 / u-boot / payload selector, presence **probed** |
| `man` | the printed manual generated for this board |

## `autoboot` — the countdown boot picker

The power-on face on a board that compiled it (`kernel.cli.autoboot`). A short
list of what is **actually attached**, arrows with wraparound, `1`-`9` to pick
directly, Enter to take one, Esc to stay in setup, and a countdown that takes the
first entry if nobody is watching. Compile-time policy, writable from setup:

| field | default | meaning |
|---|---|---|
| `enable` | on | compile the picker |
| `timeout_ms` | `2000` | countdown; `0` waits for the operator |
| `order` | `live-first` | `live-first` / `os-first` / `payload-first` |
| `bios_ui` | on | offer the browser UI as the **last** entry (needs the web stack) |

`live-first` leads with recovery media — a live USB or an installer ISO — because
that is what you reach for when the installed OS is the broken thing.
`os-first` leads with an installed system. Setup is always reachable, and it is
the fallback in every order. Settings rows: `boot.autoboot_timeout`,
`boot.autoboot_order`.

### Detection names its evidence

A boot menu gets acted on, so [`detect`](../crates/g6b-zealcli/src/detect.rs)
never guesses: each row carries the file or header field that identified it, and
anything unrecognized stays `unknown` instead of being labelled hopefully.

| medium | proof |
|---|---|
| RISC-V Linux `Image` | `magic = "RISCV\0\0\0"` at 0x30 and `magic2 = "RSC\x05"` at 0x38 (`arch/riscv/include/asm/image.h`); `MZ`/`PE\0\0` is the EFI stub |
| install ISO | ISO 9660 primary volume descriptor at sector 16 (`CD001`, type 1) → the volume label; El Torito boot record in the next sector |
| Ubuntu / Debian live | `casper/vmlinuz` / `live/vmlinuz`, release string from `.disk/info` |
| OpenWrt | `openwrt-*.manifest` (the `base-files` revision names the build) or `etc/openwrt_release` |
| installed Linux | `/etc/os-release` (`PRETTY_NAME` then `NAME`), then `/usr/lib/os-release` |
| UEFI / U-Boot | `EFI/BOOT/BOOTRISCV64.EFI`, `u-boot.itb`, `*.itb` |
| Windows | `bootmgr` / `Windows\` |

The device column is the transport's reported vendor/product, and **blank when
the device did not answer** — a made-up vendor on a boot menu is worse than a gap.

### Where the list comes from

Probing media needs a block reader, and the S-mode payload has none. So the list
is discovered **on the host** — over the volumes the build was given
(`g6b … --volume ID=PATH[:role[:vendor]]`, real directories or image files) — and
packed into the payload as `CLI-AB-HEAD|` / `CLI-AB-ENTRY|` / `CLI-AB-FOOT|` /
`CLI-AB-TICKS|`. What stays live in the guest is the part that must be:
`AutoDraw` (republish the frame), `AutoKey` (wraparound, digits, Enter, Esc — and
**any navigation stops the countdown**), `AutoTick` (count timer ticks, redraw when
the second changes, expire to entry 0), `AutoPick`. The countdown is expressed in
**timer ticks** because that is the only clock the payload has.

Taking a medium prints `AUTOBOOT-PICK <id>`, then — on a board that compiled
the virtio-blk driver — actually reads it: `BlkSig` names the medium from its
own bytes (`BLK-SIG gpt`/`fat`/`ext4`/`mbr`/`raw`) and `FatRead`/`Ext4Read`
report the file a superfloppy reader reaches (`FILE-FOUND`/`FILE-NOTFOUND`). The
line that follows, `AUTOBOOT-HANDOFF medium read; payload image load staged
(B98)`, names what is still open: loading a payload *image* by name — including
into a partition the table points at, which the bounded readers deliberately do
not address — and jumping to it. A board with no block driver still prints
`AUTOBOOT-HANDOFF no block reader in this payload yet (B98)`.

### QEMU evidence (real media, real OpenWrt)

`tools/mkmedia.sh` builds the media from the OpenWrt artifacts `g6lc_qemu`
produced — `xorriso` writes a genuine ISO 9660 + El Torito image whose
`EFI/BOOT/BOOTRISCV64.EFI` is the real riscv64 kernel (its EFI stub makes that a
legal loader path). `tools/qemu_autoboot.sh` drives the picker;
`tools/qemu_openwrt_chain.sh` runs both stages.

| Evidence | Result |
|---|---|
| picker on the 640×480 plane | `AUTOBOOT ORDER=LIVE-FIRST BOOTING FIRST ENTRY IN 20S` + 4 rows |
| the install ISO | `> 1. G6LC-OPENWRT-INST [INSTALLER] QEMU DVD-ROM` — label read from the PVD |
| the OpenWrt key | `2. OpenWrt sifiveu-generic-sifive_unleashed (1~d9340319c6) [firmware] SanDisk Ultra Fit` — revision read from the manifest |
| countdown | `20s` → `19s` → `18s` on the real SBI timer |
| `sendkey down`, `up`, `up` | marker `> 1.` → `> 2.` → `> 1.` → `> 4.` (**wraparound** past the top) |
| `sendkey ret` | `AUTOBOOT-PICK payload` → the setup prompt |
| unattended (2 s build) | `AUTOBOOT-PICK install@CD` — the policy's first entry |
| stage 2: the picked image | `Linux version 6.6.93 … OpenWrt … r28739-d9340319c6` → `procd: - init -` → `OPENWRT-BOOT-OK` |

The revision in stage 2 (`d9340319c6`) is the revision the picker read out of the
manifest in stage 1 — the BIOS chose *that* image, and that image boots.

**Known interaction:** attaching extra virtio-mmio devices (`virtio-blk-device`
for the ISO/key) stops keystrokes from reaching the guest, while the GPU and the
keyboard still probe `OK`. The interactive runs therefore use `DRIVES=0`. This is
a device-slot/irq interaction outside the picker and is logged as a B98 item.

## Settings: view, write, export

Setup rows are a view of compiled RTL; the writable set is
`g6b_spec::menu::WRITABLE`, and each entry names the BoardSpec path it lands on.
`set` validates against the row's alphabet and stores into an overlay; `save`
exports a BoardSpec **patch** the next build/boot picks up. The running image is
never rewritten under the operator, and `menu <id>` marks writable rows with `*`.

## Firmware update without a worker thread

`fw update https://…` or `fw update DRIVE:/image` arms a state machine:
`fetch → verify → stage → ready`, then an explicit `fw apply`. Each `poll` does
one bounded step and returns, driven by the shell loop or the guest timer tick —
no thread, and the prompt stays live. Plain HTTP is refused for firmware.
Verification is what the BIOS can prove: image magic and size envelope, plus the
sha256 the kernel reports on `stage` (`g6b-tls`), for the operator to compare.
The HTTPS *record layer* is still B54: the kernel reports
`https via=hw-tcp tls=handshake … not implemented yet (B54)` instead of faking
crypto, so the USB-key path is the working remote-image route today.

## Guest container (`g6b_asm::cli`)

On a build with no web engine the guest owns the screen, and the container is
**interactive** in the ELF — not a static splash.

What the guest can honestly do is the boundary the module draws. It has no
interpreter, allocator or filesystem, so the *pages* an operator reaches are
rendered on the host at build time (`g6b_kernel::boot` tags them `CLI:<name>| …`
next to the boot container's `CLI| …`) and packed into the payload, while the
*edit line* and the dispatch that switches pages are real guest code. That is the
division a shipping BIOS makes — setup screens are build-time data, the input
loop is firmware — and the text has one source of truth: what the boot log shows
is what the screen shows.

| Node | What |
|---|---|
| `CliInit` | seed the edit line with the prompt, publish the container rows + the live prompt row, paint (`ZEALCLI-PAINT n`) |
| `CliKey` | drain `INP_KQ` past its own `CLI_SEEN` watermark: printable keycodes append, `KEY_BACKSPACE` shrinks, `KEY_ENTER` dispatches |
| `CliEnter` | compare the typed word against the bounded table (`clear`, `reboot`, `shutdown`, one verb per packed page), act, reset the line |
| `CliSync` | prompt row `text_len` = live edit-line length |
| `cli_keymap` | 128-byte Linux-keycode → ASCII table, pinned to the host decoder by a `g6b-zealcli` test |

The edit line lives at `__uart_line + CLI_LINE_OFF` and the container's bottom
row points at it, so a keystroke changes the next frame without republishing
rows. **Nothing paints in IRQ context**: `CliKey` bumps `CLI_DIRTY` and the timer
tick paints when the watermark moved (the same split `DomKey`/`DomNav` use). A
line typed on the **serial band** that no builtin command claims is the same
container — copied into the edit line and dispatched — and that path paints
inside the trap, exactly like the existing `Ui` command.

`wants_virtio_input` now follows the *text face*, not wasm: a keyboard-first CLI
needs the device more than the web UI does. The pointer is separate
(`wants_virtio_tablet`), so a mouse-less build gets no tablet it would not read.

**QEMU-verified** (8.2, OpenSBI 1.3, stock virt, 2D `virtio-gpu-device`,
`tools/qemu_zealcli.sh`):

| Evidence | Result |
|---|---|
| `fixtures/g6lc64-zealcli.json` boot | `ZEALCLI-READY … web=absent`, container legible at 640×480, no `UI-BOOT`/`WASM`/`\0asm` in the image |
| `help` on the serial band | `CLI-CMD help` → `CLI-PAGE help` → the page painted |
| `sendkey m e n u` | the letters appear on the prompt row (`/>MENU`) |
| `sendkey ret` | `CLI-CMD menu` → `CLI-PAGE menu` → the setup index painted |
| unknown verb | `CLI-CMD?` — reported, never guessed at |
| `fixtures/g6lc64-web-hd.json` | the same CLI first, then browser-UI on a 1920×1080 scanout |

Three guest bugs were found by painting long mixed-case text and switching pages;
all three are fixed with regression tests:

1. `sp` was set to the **bottom** of a hart's stack slot, so on a single-hart
   image the first push clobbered the tail of `.rodata` — the `__font` table.
2. The mirrored font pairs `( ) [ ] { } < > / \` were authored the wrong way
   round (`/>` printed as `\<`).
3. `DomPaint` never erased: a glyph blit only writes the cells it paints, so a
   shorter row (backspace, or a page with fewer rows) left the previous text
   behind and the screen showed both at once. It now clears the text band first.

## Not in this crate

Mouse/tablet/USB HID transport and USB-key media live in **`g6b-hw`**
(`virtio-tablet`, `usb-hid`, `usb-key`, `HwPointer` / `HwUsbLs`). HTTPS records,
sockets and the flash backend are the **kernel**'s. The CLI never opens a socket
and never links crypto.

## Real volumes (B99/B100)

The shell walks actual partitions through `g6b-vfs` — see
[`g6b-vfs.md`](g6b-vfs.md). `drives` lists drives, tables and volumes with what
each one holds; `mount [-w]` and `umount` manage them; `cd`, `ls`, `cat`, `write`,
`rm` and `mkdir` work over `/mnt/<name>`, `<name>:/path` or relative paths; and
`vi` becomes an editor with `:w`/`:wq` where the file can be written back, staying
the read-only viewer with a *stated reason* everywhere else.

Reaching a known volume auto-mounts it **read-only** and prints that it did;
writing needs an explicit `mount -w`, and `mount` with two candidates lists them
and refuses to guess. The autoboot picker pages when its list is taller than the
container (`-- 1-6 of 10 (up/down scrolls) --`), and the EDK2/U-Boot selector
offers a loader only when it actually *read* the file off a volume.
