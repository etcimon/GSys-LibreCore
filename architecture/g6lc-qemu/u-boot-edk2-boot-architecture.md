# U-Boot / EDK2 boot architecture for `g6lc_qemu`

**Status:** U0/U1/U2 green on QEMU virt; **U3a/U3b/U3-FIT/U3-SPI green** on generated `g6lc-soc` (OpenWrt EFI FIT from SPI NOR via `sf read`+`bootm`, no DRAM loader; `/proc/cpuinfo` via QEMU `-initrd` overlay). E0–E3 green as below. E1 RTL SEC-ABI green (`mini_edk2_sec` PASS on `work-ver-smt2-fw64-B-slwfix`). E1 FD wraps `OvmfPkg/RiscVVirt/RiscVVirtQemu.dsc`. E2 QEMU virt **green**: Shell v2.2 **and** virtio-blk ESP (`FS0:`, `EFI/BOOT/BOOTRISCV64.EFI` via `startup.nsh` → `E2-VIRTIO-ESP`). E3 Image is a **custom OpenWrt v24.10.2 compile** (`g6lc_qemu/openwrt/`, sifiveu + virtio/EFI overlay); `g6q run --loader edk2 --os openwrt` stages that PE as `BOOTRISCV64.EFI`. See `g6lc_qemu/AGENTS-todo.md` and `g6lc_qemu/pins.toml`. This file is
`architecture/` tier **T** (MIT), `.md` only, not compiled.

Parent: [`architecture/g6lc-qemu/README.md`](README.md) · OS/firmware semantics:
[`architecture/g6lc-qemu/os-linux-matrix.md`](os-linux-matrix.md) · Boot ladder:
[`architecture/multi-threading/smt-linux-rootfs.md`](../multi-threading/smt-linux-rootfs.md) ·
Heuristics: [`architecture/AGENTS-g6lc-opensbi-dev-heuristics.md`](../AGENTS-g6lc-opensbi-dev-heuristics.md).

---

## 0. Why this matters

The present Linux path is `bootrom → OpenSBI (fw_payload) → Linux Image`. It is correct for the
faithful `g6lc-soc` profile and for FPGA bring-up, but it is not the only boot shape the project
must support. Two additional shapes are needed:

1. **U-Boot + FIT** (`cva6-sdk` route, current R3c) — a second-stage loader that can carry its own
   device tree, initramfs, and kernel in one signed or verified blob. Needed for SD-card boot and
   for any board that expects a loader to set up DRAM, ethernet, or `chosen` bootargs at runtime.
2. **EDK2 / UEFI** — a UEFI PI/DXE environment that can boot from virtio, an `ISO`, or an `EFI`
   application. Needed for distribution installers and for the `g6lc-virt` profile where a real
   distro (Ubuntu/Fedora/Debian) expects UEFI runtime services.

Both loaders are **firmware witnesses** in the sense of
[`architecture/multi-threading/AGENTS-SMT2-opensbi-reasoning-pattern-workflow.md`](../multi-threading/AGENTS-SMT2-opensbi-reasoning-pattern-workflow.md)
P1: they demonstrate that the core and SoC package satisfy a general boot contract, not a special
OpenSBI-shaped one. The `g6lc_qemu` package is the right place to stage them because it already
generates firmware, emits DTB, and distinguishes the `g6lc-soc` (hardware-faithful) and `g6lc-virt`
(virtio-enabled) machine profiles.

---

## 1. The blocker

### B1 · Fetch/instruction-queue program order

I6 clause 1 is implemented in `instr_queue.sv` (O7p age-select) and the supporting FIFO
insertion-order contract is proven (`cva6_fifo_v3_order.sby` PASS). `mini_fdt_next_tag_lbu` and
`mini_stq_flush_fwd` **PASS** on `work-ver-smt2-fw64-B-slwfix` (`slw-fdt-regress` /
`slw-gate6-noprop`; keep-on-miss did not hang FDT). Gate-6 no longer blocks E2.

**E2 QEMU virt is green** (not Variane). OpenSBI hands off to pflash `0x20000000` S-mode.
Two assembler-preprocessor ABI bugs (xpack gcc defaults to rv32/ilp32; EDK2
`GCC5_RISCV64_PP_FLAGS` omitted `-mabi=lp64` while `ASM_FLAGS` had it):

1. `RiscVDisableSupervisorModeInterrupts` did `addi sp,-4` / `sd a1,(sp)` and
   smashed the caller's saved `s0`. Patch:
   `g6lc_qemu/patches/edk2-riscv-sstatus-no-stack.patch` (use `t0`, no stack).
   CpuDxe then prints `SATP mode 10 successfully configured`.
2. `SupervisorModeTrap` allocated `addi sp,sp,-140` (35×4) against a C
   `UINT64[35]` struct (280, sepc at 256). `sd`/`ld` at 4-byte strides overlapped
   sepc/sstatus; after CpuTimer `s_timer` this was `INST_ACCESS_PAGE_FAULT` at
   DRAM size (`0x100000000` with `-m 4096`). Patch:
   `g6lc_qemu/patches/edk2-riscv-trap-frame-width.patch` (offset ×8) plus
   `-march=rv64gc -mabi=lp64` on `*_GCC5_RISCV64_PP_FLAGS` (LoongArch already
   did this). Linked CpuDxe: `addi sp,sp,-280`.

DEBUG and RELEASE both reach Bds and **UEFI Interactive Shell v2.2**
(`Shell>`). Virtio-blk ESP (`fat:rw:out/loader-run/esp` with
`EFI/BOOT/BOOTRISCV64.EFI` = RELEASE `Shell.efi`) maps as `FS0:`/`HD0b:`;
Shell runs `startup.nsh` and prints `E2-VIRTIO-ESP` then launches that EFI
app. `g6q run --backend qemu --loader edk2 --machine g6lc-virt --wsl
--drive fat:rw:out/loader-run/esp --expect E2-VIRTIO-ESP` is green on
in-tree QEMU 10.0.0. Default CODE/VARS:
`out/loader-run/src/RISCV_VIRT_{CODE,VARS}.fd` (RELEASE, trap-frame ×8).
`ProtectUefiImage` still warns `Image Section Alignment(0x40) vs 0x1000` on
DEBUG Shell.efi; that is non-fatal. Distro 8.2 rejects g6q's `zacas=` CPU
property — use in-tree 10.0.0 for `g6q run`. E3 Image is OpenWrt v24.10.2 custom-compiled (`g6lc_qemu/openwrt/build.sh`,
sifiveu + `kernel-virt.config` EFI stub/virtio/8250). Not Variane.

**Decision rule (H1, H2, H3 from heuristics):**

```text
JUDGEMENT
  GIVEN    OpenSBI fw_payload is the smallest real supervisor witness
  AND      `mini_stq_flush_fwd` and `mini_fdt_next_tag_lbu` PASS on slwfix
  AND      QEMU virt DEBUG EDK2 prints UEFI Interactive Shell v2.2
  THEN     E2 is closed as a QEMU-virt firmware witness, not an RTL gate
  BECAUSE  P1 (workload is a witness) — the remaining 0x40 vs 0x1000 warning is non-fatal
```

### B2 · No `g6lc_qemu` loader build profile

`g6lc_qemu` currently has `fetch-fw` / `build-fw` for OpenSBI (`fw_payload`, `fw_jump`, `fw_dynamic`
modes). There is no loader profile, no FIT/FV emit path, and no machine profile that advertises the
peripherals U-Boot or EDK2 expect (SDHCI, `g6lc-virt` UEFI flash variable store, etc.). This is a
secondary blocker because it is smaller and can be scaffolded in parallel once the RTL issue is
owned.

---

## 2. Architectural approach

### 2.1 Loaders are first-class boot objects, not one-off scripts

Do not add a `build-uboot.sh` and `build-edk2.sh` to the repo and call it done. The path must
inherit the same `g6lc_qemu` invariants: inputs are the design's own config package, flist, SoC
package, and DTS; outputs are generated and stamped; no hard-coded memory map.

```text
PROPOSITION  P-A1 · Loader inputs are the same three as OpenSBI
  CLAIM      U-Boot and EDK2 must boot from the same TargetModel that OpenSBI does.
  EVIDENCE   g6lc_qemu's design thesis is that an emulator has one IR (TargetModel) and
             every backend reads it. Upstream cva6-sdk already builds U-Boot with a board
             defconfig and a hard-coded load address; we replace that with a generated
             defconfig and a generated .its / .fdf.
  FORBIDS    Hand-typed `CONFIG_SYS_TEXT_BASE`, `FDT_ADDR`, `DRAM_SIZE`, or `VIRTIO_MMIO_*`.
  REQUIRES   g6lc_qemu emits a loader-specific board package from TargetModel.
  FEEDS      H1 (archetype lift) · build-platform §4.2 (add a managed tool) · g6q `fw` verb
```

### 2.2 Two profiles, two loader uses

| Machine profile | Loader | What it proves |
|---|---|---|
| `g6lc-soc` | U-Boot SPL + FIT | Hardware boot: real SoC map, SPI/SDHCI, no virtio. Tandem/D1 valid here. |
| `g6lc-virt` | U-Boot proper / EDK2 | Distro boot: virtio block/net/9p, UEFI vars, bigger RAM. Tandem refused unless `--allow-virt-diag`; boot is the question, not hardware. |

This is the same `g6lc-soc`/`g6lc-virt` split already in `g6lc_qemu`.

### 2.3 OpenSBI source reference

OpenSBI is the M-mode witness. Both loaders are launched by it:

- **U-Boot**: OpenSBI `fw_dynamic` hands the next-stage info struct to U-Boot SPL, which then loads
  the FIT (`kernel + fdt + initramfs`) from the SD or SPI flash. The cva6-sdk uses this shape.
- **EDK2**: OpenSBI `fw_dynamic` passes control to the `RiscVPlatformPei` SEC/PEI entry; EDK2 owns
  S-mode handoff to the UEFI-aware OS.

OpenSBI v1.5 source (`build-platform/workspace/smt2-linux/opensbi`, commit `455de672`) is the
reference. The relevant files are:

- `firmware/fw_base.S` — the M-mode entry, `next_arg1` (`a1` = FDT), `next_addr` (`a0` = next stage).
- `firmware/fw_dynamic.c` — `fw_dynamic_info_init`, `next_mode` setup.
- `lib/utils/libfdt/` — the FDT helpers U-Boot/EDK2 also use.
- `include/sbi/riscv_asm.h` and `sbi/sbi_platform.h` — the SBI extension surface the loaders see.

The project does **not** write a new OpenSBI platform. `PLATFORM=generic` + an FDT-driven loader is
the preserved path (already used for the payload route).

---

## 3. U-Boot plan

### 3.1 Why U-Boot first

U-Boot is lower-effort than EDK2 and has an upstream RISC-V `cva6` / `sifive` board defconfig
ecosystem. It is also the cva6-sdk path, so it is the natural next rung on the boot ladder.

### 3.2 Target model → U-Boot board package

`g6lc_qemu` already has `g6q-emit-qemu` (B1/B2). Add a new emitter or a new profile inside the
existing `fw` verb:

```text
# B0: generate a U-Boot defconfig + .its from the TargetModel
g6q fw --target g6lc64_smt2 \
       --loader u-boot \
       --machine g6lc-soc \
       --out out/u-boot-g6lc64_smt2/
```

Outputs:

| File | Role |
|---|---|
| `g6lc.h` | board header: `CONFIG_SYS_TEXT_BASE`, `CONFIG_SYS_LOAD_ADDR`, `CONFIG_NR_DRAM_BANKS`, `PHYS_SDRAM_0`, `PHYS_SDRAM_0_SIZE` from `TargetModel.memory` |
| `g6lc_defconfig` | Kconfig fragment selecting `RISCV`, `MACH_G6LC`, `OF_CONTROL`, `FIT`, `DM_*`, `CMD_`*` |
| `g6lc.its` | FIT source: kernel fdt + initramfs, with load/entry addresses from model |
| `Kconfig.g6lc` | board Kconfig snip |
| `Makefile` | build wrapper calling the pinned U-Boot source |

All numeric values are derived from `TargetModel.memory[]`, `TargetModel.soc.irq[]`, and
`TargetModel.soc.mmio[]`. The SoC package `ariane_soc_pkg` and `corev_apu/tb/ariane_soc_pkg.sv` are
the source of truth.

### 3.3 Build flow

```text
g6q fetch-loader --loader u-boot   # clone pinned U-Boot into out/loader-src/u-boot/
g6q build-loader --loader u-boot --target g6lc64_smt2
# product: out/u-boot-g6lc64_smt2/u-boot-spl.bin
#          out/u-boot-g6lc64_smt2/u-boot.itb
```

The build uses the managed RISC-V cross-toolchain (`tools/g6q.py setup-riscv` / build-platform
`tools install riscv-gcc`) and a pinned U-Boot revision in `g6lc_qemu/pins.toml`. OpenSBI is still
fetched and built separately, because U-Boot SPL expects an M-mode firmware to hand off to it.

### 3.4 Run flow

```text
# g6lc-soc, boot from SD image
g6q run --target g6lc64_smt2 --machine g6lc-soc \
        --fw-mode dynamic \
        --loader u-boot --loader-image out/u-boot-g6lc64_smt2/u-boot.itb \
        --sd-image .../rootfs.img \
        --to out/runs/u-boot-g6lc64_smt2/

# g6lc-virt, boot from virtio block
g6q run --target g6lc64_smt2 --machine g6lc-virt \
        --loader u-boot --loader-image out/u-boot-g6lc64_smt2/u-boot.itb \
        --block-image .../rootfs.img
```

`--fw-mode dynamic` means OpenSBI `fw_dynamic` is used and the next-stage info is set to the
U-Boot entry. The FDT is the one `g6q` generated for the target, optionally overlaid with loader
`chosen` bootargs.

### 3.5 Validation ladder

| Stage | What | Gate | Why sparse |
|---|---|---|---|
| U0 | `build-loader` succeeds; `u-boot-spl.bin` and `.itb` emitted | `g6q check` | Build-time gate; no RTL |
| U1 | U-Boot SPL reaches `board_init_f`/`board_init_r` on `g6lc-virt` | `g6q run` + string match | Fast, ~seconds |
| U2 | U-Boot distro-boot `bootefi` of the OpenWrt EFI-stub PE from a partitioned virtio ESP (`esp-uboot.img`) | `g6q run --loader u-boot --os openwrt` + kernel console | Fast, minutes. FIT remains a later `g6lc-soc` path; the E3 product is PE32+ |
| U3a | U-Boot banner on generated `g6lc-<target>` (`--machine g6lc-soc`) | `g6q run --loader u-boot --machine g6lc-soc --expect U-Boot` | Fast. B1 reset stays at OpenSBI; `-kernel` at DRAM+2MiB |
| U3b | Linux + procd on `g6lc-soc` via U-Boot `bootefi` of a DRAM-resident OpenWrt PE (no virtio/SD) | `g6q run --loader u-boot --os openwrt --machine g6lc-soc --expect "procd: - init -"` | Fast |
| U3-FIT | Same machine, `bootm` of `g6lc-efi.itb` (`os = efi`) plus QEMU `-initrd cpuinfo-init.cpio` | `--expect CPUINFO-DONE` (or `procd: - init -`) | Fast |
| U3-SPI | Same machine, `sf probe` + `sf read` + `bootm` of the EFI FIT from NOR (`n25q256a`, `-drive if=mtd`; no DRAM loader) | `--expect SPI-READ-DONE` or `CPUINFO-DONE` | Fast |
| U3-Shell | U-Boot `bootefi` of EDK2 `Shell.efi` | virt: `--os efi-shell --machine g6lc-virt --expect "UEFI Interactive Shell"`; soc SPI FIT still StartImage-hangs (`bootefi hello` ASCII is green there) | Fast |
| U4 | Tandem with RTL trace for U1–U3 selected steps | `--diag d1` | Only after SL-W gate-6 green |

Stage U0 (build-loader) can start before the RTL residual is fully closed because it is a build step.
U1–U2 run on `g6lc-virt` with stock QEMU. U3a runs on the generated B1 `g6lc-soc` machine.
U3b, U3-FIT, and U3-SPI (`sf read` + `bootm` of the FIT from NOR, then `CPUINFO-DONE`) are green.
U3-Shell is green on virt (distro `bootefi` of `Shell.efi` from `esp-shell.img`). On `g6lc-soc` the same PE is a FIT on NOR: `bootm` transfers to EFI then hangs; `bootefi hello` prints `Hello, world!`. U4 remains later.

---

## 4. EDK2 plan

### 4.1 Why EDK2 second

EDK2 is larger and UEFI runtime services touch more of the core (SBI HSM, timer, IPI, `stimcmp`,
machine/H/virt extensions). It is the right target once U-Boot is green because EDK2's PEI/DXE
phases are a stricter witness of the SBI and exception surface.

### 4.2 Target model → EDK2 board package

EDK2 is built from a platform DSC/FDF. `g6lc_qemu` emits:

| File | Role |
|---|---|
| `G6lcPlatformPkg.dsc` | top-level DSC selecting `MdePkg`, `MdeModulePkg`, `UefiCpuPkg`, `PlatformSecLib`, `OpenSbiProcessorBindPkg` |
| `G6lcPlatformPkg.fdf` | flash layout, FVMAIN, DXE core, BDS |
| `G6lcPlatform.h` | `PcdFvBaseAddress`, `PcdSystemMemoryBase`, `PcdSystemMemorySize` from `TargetModel` |
| `AcpiTables.inf` (stub) | reserved; ACPI is not in scope for the first pass |
| `VarStore.fdf.inc` | emulated variable store for `g6lc-virt` (virtio-pci or mmio flash) |

The DSC uses the standard `RiscVPkg` and `RiscVPlatformPkg` from upstream edk2-platforms when they
exist; otherwise a minimal `G6lcPkg` that mirrors the SoC package.

### 4.3 Build flow

```text
g6q fetch-loader --loader edk2   # clone pinned edk2 + edk2-platforms
g6q build-loader --loader edk2 --target g6lc64_smt2
# product: out/edk2-g6lc64_smt2/G6lcPlatformPkg.fd
```

EDK2 uses `gcc` cross-build with `build.sh` (BaseTools); the toolchain is the managed RISC-V
linux-gnu or the in-tree xPack bare-metal with PIE.

### 4.4 Run flow

```text
g6q run --target g6lc64_smt2 --machine g6lc-virt \
        --loader edk2 --loader-image out/edk2-g6lc64_smt2/G6lcPlatformPkg.fd \
        --block-image .../rootfs.img
```

`g6lc-virt` is the natural first profile for EDK2 because it provides virtio storage and a UEFI
variable store in a flash file. SPI NOR (`n25q256a` on FPGA Xilinx AXI SPI) now exists on
`g6lc-soc` (U3-SPI). Full EDK2 FD still needs 32 MiB pflash and stays deferred. U-Boot can
`bootefi` EDK2 `Shell.efi` from a virtio ESP (U3-Shell virt green); the soc SPI FIT path
loads that PE then hangs in `StartImage`.

### 4.5 Validation ladder

| Stage | What | Gate |
|---|---|---|
| E0 | `build-loader` succeeds and emits a `.fd` | `g6q check` |
| E1 | SEC ABI on RTL (`mini_edk2_sec`); FD from `RiscVVirtQemu.dsc` | remote Variane + `g6q fw build --loader edk2` |
| E2 | BDS enumerates virtio block and loads an `EFI/boot/bootriscv64.efi` | `g6q run` |
| E2-PCI | EDK2 Shell `pci` on QEMU virt GPEX + a stock virtio-blk **PCI function** (host **root complex**; not the AI card endpoint) | `--expect 1AF4`: `1B36:0008` GPEX and `1AF4:1001` SCSI virtio-blk at `PciRoot(0x0)/Pci(0x1,0x0)`. ESP also carries packed `DESC.BIN` (ingested OP_GEMM, not a BAR). Card stand-in remains `virt_ai_card` until `contracts.ai_host_transport` is pinned |
| E3 | Linux starts under UEFI on `g6lc-virt` | `g6q run --loader edk2 --os openwrt --smp 2` → `Brought up 1 node, 2 CPUs` and `procd: - init -` |
| E4 | Tandem with RTL trace | Variane cannot boot 32 MiB pflash. RTL witness stays `mini_edk2_sec`. Official edk2 + `g6lc_qemu/patches/edk2-*.patch` (etcimon fork is extract-only). |

---

## 5. `g6lc_qemu` changes

### 5.1 CLI additions

Extend `g6q fw` per the existing `architecture/g6lc-qemu/cli.md` style. The current U0/E0 scaffolding uses:

```text
g6q fw fetch --loader u-boot|edk2 [--loader-src PATH] [--dry-run]
g6q fw build --loader u-boot|edk2 --target g6lc64_smt2 --machine g6lc-virt
             [--loader-src PATH] [--loader-out PATH]
             [--cross-compile PREFIX] [--dry-run]
```

- `--loader-src` overrides the pinned source directory (`out/loader-src/<loader>` by default).
- `--loader-out` overrides the generated board package / build root.
- `--machine g6lc-virt` is the first supported profile; `g6lc-soc` is accepted but not yet runtime-validated.
- Dry-run writes the generated board package and build script and prints the planned command without invoking the loader build.

`g6q run --backend args|qemu --loader edk2` is implemented: it forces stock `-M virt`
pflash0/pflash1 (`acpi=off`), pads CODE/VARS to 32 MiB, and emits `-blockdev` nodes.
`--loader-image` / `--loader-vars` select the FDs. The RTL witness remains
`verif/tests/custom/multicore/mini_edk2_sec.S` (remote Variane).

### 5.2 IR additions

`TargetModel` already has `memory`, `soc.mmio`, `soc.irq`. Add loader-relevant fields if missing:

- `TargetModel.loader`:
  - `u_boot.text_base` (computed from DRAM base + reserved M-mode region)
  - `edk2.pcd_system_memory_base`
  - `edk2.pcd_flash_base` (only for `g6lc-virt`)
- `TargetModel.soc` may need `sdhci`, `spi`, or `virtio` capabilities; these must come from the
  actual flist/SoC package or be marked `synthetic` if injected.

### 5.3 Conformance rules

Add two conformance findings:

1. If `--loader u-boot` and `machine == g6lc-soc` but the SoC package has no SDHCI or SPI,
   `conform` emits `GAP` (not `FAIL`) because the loader cannot load a kernel from a real device.
2. If `--loader edk2` and `machine == g6lc-virt` but the target advertises no virtio, `conform`
   emits `FAIL` because the distro boot is impossible.

---

## 6. `build-platform` integration

### 6.1 Suites and diagnostics

Added **optional build suites** in `build-platform/src/config/defaults.ts`:

| Suite id | Group | Target | What |
|---|---|---|---|
| `u-boot-build` | `linux` | `g6lc64_smt2` | `g6q fw build --loader u-boot --target g6lc64_smt2 --machine g6lc-virt --dry-run` |
| `edk2-build` | `linux` | `g6lc64_smt2` | `g6q fw build --loader edk2 --target g6lc64_smt2 --machine g6lc-virt --dry-run` |

The runtime suites `u-boot-boot-virt` and `edk2-boot-virt` are **deferred** until U1/U2 and E1/E2 are green. All four are **not** in `tests.defaultSuites` until the loader is green. The build suites are surfaced by `bun run src/cli/index.ts test --list`.

### 6.2 Managed tools

Added two source recipes to `build-platform/src/tooling/recipes.ts` and wired them through
`installProfiles.ts` / `cli/commands/tools.ts`:

- `u-boot-src` — calls `g6lc_qemu/tools/g6q.py fetch-fw --loader u-boot --loader-src <workspace/tooling/loader-src/u-boot>`.
- `edk2-src` — calls `g6q.py fetch-fw --loader edk2 --loader-src <.../edk2> --edk2-platforms-src <.../edk2-platforms>`.

Both install into `build-platform/workspace/tooling/loader-src/` (gitignored). They reuse the pins in
`g6lc_qemu/pins.toml` rather than duplicating them. `--edk2-platforms-src` was added to `tools/g6q.py`
to support the separate `edk2-platforms` tree.

**Status:** wired and `tsc --noEmit` + `bun test` green (same pre-existing `branding-g6lc.test.ts`
failure as before). `bun run src/cli/index.ts tools install u-boot-src --dry-run` and
`edk2-src --dry-run` both plan the expected `g6q.py fetch-fw` commands.

### 6.3 `--formal-remote` based on `.sby`

The loader work is **not** RTL, so `--formal-remote` applies to the RTL preconditions, not the
loader build. The plan is:

1. Run `bun run src/cli/index.ts verify --formal --formal-remote` against `g6lc_fetch_iq.sby` and
   any new bounded properties for the boot path (e.g. `g6lc_fetch_iq_order` for I6 clause 1).
2. Only after the formal gate is green, run `u-boot-build` and `edk2-build` in CI.
3. Use `g6lc_qemu` as the sparse firmware/Linux boot validator; Verilator soaks are kept minimal and
   timed (the user asked for lessened testing focus with validation where necessary).

---

## 7. RTL / tandem gate

### 7.1 What must be proven before U-Boot/EDK2 on RTL

The `g6lc-soc` profile is the only one that may be used for RTL diagnosis. The U-Boot/EDK2 boot
must not be used as a soak until:

- `g6lc_fetch_iq.sby` or a new `g6lc_fetch_iq_order.sby` proves I6 clause 1 (program order) for the
  SMT2 geometry (`N=1, T=2, I=2, FW=64, RVC`).
- The directed mini battery (`mini_fdt_next_tag_lbu`, `mini_fdt_nt_stock`, etc.) is green or
  explained.
- `mini_must_pass` passes and `mini_must_fail` fails correctly.

This is the same architecture-first discipline in `AGENTS-coding-philosophy.md` §2.4.

### 7.2 Tandem with `g6q`

Once the RTL is green, `g6q run --diag d1 --machine g6lc-soc --loader u-boot` can lock-step the
RTL trace against the native Rust VM (B3) for selected boot stages. The D1 record format in
`g6lc_qemu/architecture/DIAG.md` is the vehicle.

---

## 8. Core configurability

Every knob must be `CVA6Cfg`-gated and reflected in `TargetModel`.

| Knob | Effect on loader |
|---|---|
| `NrHarts` | FDT `cpu-map` and U-Boot/EDK2 secondary-hart startup (SBI HSM) |
| `NrCores` | Multi-core topology in `cpu-map`, PLIC `num-targets` |
| `RVC` | U-Boot `CONFIG_RISCV_ISA_C` and EDK2 `PcdRiscVFeatureC` |
| `RVV` | EDK2 vector PEI (deferred); U-Boot `CONFIG_RISCV_ISA_V` (deferred) |
| `RVH` | EDK2 hypervisor DXE (deferred) |
| `EnableAccelerator` / `AiAccelEn` | `ai_island` MMIO window in FDT; EDK2 would see it as an EFI protocol later |
| `L2En` / `L3En` | DRAM/cache topology in `chosen`/ACPI (EDK2 only) |

The loader build must refuse a configuration it does not yet support (`conform` FAIL) rather than
silently produce a broken image.

---

## 9. Staging — when to do what

| Phase | Trigger | Work | Outcome |
|---|---|---|---|
| **U0** | Now (build-only scaffolding) | Pin U-Boot/EDK2 revs in `g6lc_qemu/pins.toml` as `planned`; implement `g6q fw build --loader u-boot` for `g6lc-virt`; generate board package + build script; do **not** claim a green build until host cross-toolchain/network validated | Build scaffolding and dry-run green; no runtime claim |
| **U1** | U0 green | `g6q run` U-Boot SPL to `board_init_r` on `g6lc-virt` with virtio | U-Boot loader witness in QEMU |
| **U2** | U1 green | `g6q run --loader u-boot --os openwrt` on `g6lc-virt`: OpenSBI → U-Boot `bootefi` → OpenWrt EFI stub `Linux version 6.6.93` (`efi: EFI v2.11 by Das U-Boot`). `--smp 2` green: `HARTs 0*,1*`, `Brought up 1 node, 2 CPUs`, `procd: - init -`. ESP is MBR+FAT16 `out/loader-run/esp-uboot.img` (QEMU `fat:rw:<dir>` has no partition table). | Distro boot in emulator |
| **U3a** | U2 green | `g6q run --loader u-boot --machine g6lc-soc`: generated `g6lc-g6lc64_smt2`, OpenSBI next `0x80200000`, **`U-Boot 2025.07`**, `Model: GSys LibreCore g6lc64_smt2`. B1 fix: reset vector stays at `-bios`; `-kernel` loads at DRAM+2MiB (S-mode U-Boot cannot run from M-mode reset). Generated machine `min_cpus` is NrHarts (2); `--smp 1` is floored. | U-Boot on the faithful machine |
| **U3b** | U3a green | `g6q run --loader u-boot --os openwrt --machine g6lc-soc --smp 2 --expect "procd: - init -"`: DRAM PE at `0x84000000`, soc U-Boot `bootefi` + `earlycon=sbi`. **`Linux version 6.6.93`**, 2 CPUs, **`procd: - init -`**. | Kernel + userspace on the faithful machine |
| **U3-FIT** | U3b green | `mkimage` FIT `g6lc-efi.itb` (`kernel_noload` / `os = efi`). `bootm 0x84000000` → EFI stub → **`Linux version 6.6.93`**. Cpuinfo witness is QEMU `-initrd cpuinfo-init.cpio`. | cva6-sdk FIT shape on the faithful machine |
| **U3-SPI** | U3-FIT green | FPGA `xlnx_axi_quad_spi` at `0x20000000` (PLIC 2) + QEMU `n25q256a` (`-drive if=mtd`). No DRAM loader. **`SPI-PROBE-DONE`** → **`SPI-READ-DONE`** (24 MiB) → `bootm` → **`Linux version 6.6.93`** / **`CPUINFO-DONE`**. | Hardware SPI window, not virtio |
| **U3-Shell** | U3-SPI green | `g6q run --loader u-boot --os efi-shell --machine g6lc-virt --expect "UEFI Interactive Shell"`: distro `bootefi` of EDK2 `Shell.efi` from MBR+FAT16 `esp-shell.img`. Banner **`UEFI Interactive Shell v2.2`**, `UEFI v2.110 (Das U-Boot)`, `FS0:`. Soc SPI FIT `bootm` of the same PE transfers to EFI then hangs after `Booting <NULL>`; soc `bootefi hello` prints **`Hello, world!`**. | EDK2 Shell via U-Boot, not a 32 MiB pflash FD |
| **E0** | Done (build-only wrap) | Pin EDK2 `edk2-stable202511`; `g6q fw build --loader edk2` for `g6lc-virt` wraps upstream `OvmfPkg/RiscVVirt/RiscVVirtQemu.dsc` (PEI-less S-mode payload). edk2-platforms is not required for virt. | Dry-run green; generated script invokes the upstream DSC |
| **E1** | FD green; RTL SEC-ABI green on slwfix B | Remote Verilator `mini_edk2_sec` **PASS** on `work-ver-smt2-fw64-B-slwfix` (oracle green). FD **PASS** (CODE 8 MiB / VARS 768 KiB). Post-sync SIGSEGV isolated to SL-W `wbuffer_all`/signed `%` (not IQ casts); crash-fix in tree. WSL QEMU 8.2.2 virt pflash: OpenSBI hands off to `0x20000000` S-mode, then EDK2 `STORE_ACCESS_PAGE_FAULT` — SEC/DXE banner not reached. | FD + RTL SEC-ABI green; QEMU SEC fault is an E1 residual |
| **E2** | E1 green | `g6q run` EDK2 Bds + Shell; virtio-blk ESP `FS0:` + `BOOTRISCV64.EFI` (`E2-VIRTIO-ESP`) | UEFI loader + virtio witness |
| **E2-PCI** | E2 green | GPEX `1B36:0008`; virtio-blk `1AF4:1001`; virtio-net `1AF4:1000` (VirtioNetDxe **`Virtio Network Device`** bound); virtio-serial `1AF4:1003`. Hubport: no slirp, no `ifconfig` addresses. ESP `DESC.BIN`/`DESC.HEX`/`DESC.TXT` is a packed OP_GEMM from ingested `desc_layout` (`--expect OP_GEMM`). `CAP.TXT` is ingested island geometry plus modelled peak (`--expect modelled_peak_gops`; fixture 512 GOPS, not 100 TOPS). virt_ai_card BAR4 name `DESC` loads that image into UIO DESC@0x140; CAP window is seeded from the same model. **Root-complex** firmware. Transport pin unpinned. | EDK2 PciBus + stock virtio blk/net/console roles + packed-desc file + existing ai-tensor TCP card, not a fused AI BAR |
| **E3** | E2 green + OpenWrt custom Image | `g6q run` EDK2 → OpenWrt EFI stub on `g6lc-virt` | UEFI OpenWrt boot |
| **E4** | E3 green + SL-W gate-6 green + I6 clause 1 proven | Tandem with RTL on selected U-Boot/EDK2 stages | Evidence |

The staging is deliberately **not** a test plan. It is a feature promotion ladder: each phase is a
build-platform suite or `g6q` command, and the decision to enter the next phase is a green gate, not
a soak count.

---

## 10. Open questions to resolve before code

1. Does the SoC package already define an SDHCI or SPI base? If not, the `g6lc-soc` U-Boot profile
   must be synthetic until the uncore controller is vendored.
2. Which upstream U-Boot defconfig is the closest starting point? `sifive_fu540`, `qemu-riscv64`,
   or a new `g6lc_*` board?
3. Is `g6lc-virt` UEFI variable store a flat file (pflash) or `virtio-rng`/MMIO? This affects the
   FDF and the QEMU B0/B1 invocation.
4. Which EDK2 package contains a `RiscVPlatformPkg` that compiles with the project's RISC-V
   cross-toolchain? The pin must be validated.

---

## 11. References

- `architecture/g6lc-qemu/README.md` — generator status and invariants
- `architecture/g6lc-qemu/os-linux-matrix.md` — OpenSBI modes and OS profiles
- `architecture/g6lc-qemu/cli.md` — `g6q` command surface
- `architecture/multi-threading/smt-linux-rootfs.md` — R3a–R3c boot ladder
- `architecture/multi-threading/linux-boot-scale.md` — Linux-cap reference points
- `architecture/AGENTS-g6lc-opensbi-dev-heuristics.md` — H1–H7 heuristics
- `architecture/multi-threading/AGENTS-SMT2-opensbi-reasoning-pattern-workflow.md` — P1–P7
- `AGENTS-coding-philosophy.md` — config gating, timing, verification parity
- `g6lc_qemu/AGENTS.md` — package invariants and extension playbook
- `build-platform/AGENTS.md` — suite/tool extension playbook
