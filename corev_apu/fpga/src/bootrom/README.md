# First Stage Bootloader (GSys LibreCore FPGA zero-stage bootrom)

> Historically the "Ariane" first stage bootloader. Retained name for continuity
> with upstream CVA6 / PULP Platform.

## Licensing — read before building or redistributing

**This directory is a SEPARATE WORK from GSys LibreCore.** It is not offered
under `CERN-OHL-S-2.0` and it is not covered by the GSys Commercial License.
It is tier F in `.licensing-tiers`.

It is a mixed-licence directory:

| Files | Licence | Rights holder |
|---|---|---|
| `src/main.c`, `uart.*`, `spi.*`, `sd.*`, `gpt.*` | `Apache-2.0` | OpenHW Group contributors |
| `src/bootrom_*.h`, `src/mmc.h` | `Apache-2.0 WITH SHL-2.1` | Thales Research and Technology |
| `src/dw_mmc.c`, `src/dwmmc.h`, `src/bouncebuf.*`, `src/cache.h`, `src/memalign.h` | `GPL-2.0-or-later` | U-Boot contributors (Samsung, Marek Vasut, Andes, Google) |
| `src/dma-mapping.h` | **`GPL-2.0-only`** | U-Boot contributors |

`src/LICENSE` is the Apache-2.0 text and applies to the Apache-licensed files
above. `LICENSE.GPL-2.0-or-later` is the GPL text and applies to the GPL files.

### The default build is GPL-free

`src/dma-mapping.h` is **GPL-2.0-only**. GPL-2.0-only cannot lawfully be
combined into a single linked binary with Apache-2.0 code, because Apache-2.0's
patent and indemnity terms are additional restrictions under GPLv2 §6. Since the
bootrom ELF is converted by `gen_rom.py` into `bootrom_*.sv` and instantiated as
a ROM inside the bitstream, that combination would propagate into a hardware
artifact.

`src/dma-mapping.h` is reachable only from `src/bouncebuf.c`, and the GPL headers
generally only from `src/bouncebuf.c` and `src/dw_mmc.c`. **Both are dead code** —
`src/main.c` contains no reference to `dwmmc`, `mmc_` or `bounce`. They are
therefore excluded from `SRCS_C` by default (see `Makefile`, `WITH_DWMMC`), so
the default bootrom, and every bitstream built from it, contains no GPL code.

### If you need DesignWare MMC support

```
make WITH_DWMMC=1
```

This re-adds the GPL sources. The resulting `bootrom_*.elf`, `bootrom_*.sv` and
any bitstream containing them become a **GPL derivative work** and must be
conveyed under GPL terms, including provision of corresponding source. Do not
enable this in a product intended to ship under a closed licence.

To get DWMMC without the GPL obligation, `src/dma-mapping.h` and `src/memalign.h`
would need a clean-room reimplementation — their functional content is nearly
all commented out already (`dma_map_single` merely returns the address). This is
tracked in `AGENTS-todo.md`.

## How-To prepare SD card
The bootloader requires a GPT partition table so you first have to create one with gdisk.

```bash
$ sudo fdisk -l # search for the corresponding disk label (e.g. /dev/sdb)
$ sudo sgdisk --clear --new=1:2048:67583 --new=2 --typecode=1:3000 --typecode=2:8300 /dev/sdb # create a new gpt partition table and two partitions: 1st partition: 32mb (ONIE boot), second partition: rest (Linux root)
```

Now you have to make the linux kernel with the [ariane-sdk](https://github.com/pulp-platform/ariane-sdk):
```bash
$ cd /path/to/ariane-sdk
$ make bbl.bin # make the linux kernel with the ariane-sdk repository
```

Then the bbl+linux kernel image can get copied to the sd card with `dd`. __Careful:__  use the same disk label that you found before with `fdisk -l` but with a 1 in the end, e.g. `/dev/sdb` -> `/dev/sdb1`.
```bash
$ sudo dd if=bbl.bin of=/dev/sdb1 status=progress oflag=sync bs=1M
```

## Features

- uart
- spi
- sd card reading
- GPT partitions

## TODO

- file systems (fat16/fat32)
- elf loader
- zeroing of the `.bss` section of the second stage boot loader
