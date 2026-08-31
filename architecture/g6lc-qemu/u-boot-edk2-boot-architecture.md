# U-Boot / EDK2 boot architecture for `g6lc_qemu`

**Status:** scaffold / plan of record. U0 (U-Boot build-only scaffolding) and E0 (EDK2 build-only scaffolding) are now started in `g6lc_qemu`; see `g6lc_qemu/AGENTS-todo.md` and `g6lc_qemu/pins.toml`. Runtime stages U1–U3 and E1–E3 remain gated until the O7p `core/fetch_B/instr_queue` residual is closed: `mini_fdt_next_tag_lbu` still fails because the third caller loads `nextoff` from `0x80007fcc` and gets 0x4 instead of the 0x8 just stored. This is the S1/SL-W L1-stale store-to-load class, not a queue-order bug. Build-only Stage U0/E0 scaffolding can proceed in parallel. This file is
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

`core/fetch_B/instr_queue.sv` can issue instructions out of program order when multiple FIFOs hold
entries from different fetch windows. The current O7p logic (global `push_seq` age + oldest-first output
pointer) keeps the queue live, and a 2-bit `shamt` width bug that caused pseq collisions was fixed. RVFI shows the
fail is now a store-to-load stale read: the second `next_tag_lbu` call stores `nextoff=0x8` to `0x80007fcc`, the third
caller immediately loads the same address and gets `0x4`. This is the S1/SL-W L1-stale class, not I6 clause 1.

**Do not extend the boot ladder past OpenSBI until this is closed.** A second-stage loader is larger
and more branch/dcache-sensitive than the OpenSBI payload. If the queue can invert a return path
(F0/F1/F2/F3 head order), it can also invert a U-Boot `relocate` loop or an EDK2 PEI dispatcher.
The same failure would appear as a silent hang or a corrupted `.data` segment, and the diagnosis
would move through 10–100 M cycles instead of the current 6.5 M.

**Decision rule (H1, H2, H3 from heuristics):**

```text
JUDGEMENT
  GIVEN    OpenSBI fw_payload is the smallest real supervisor witness
  AND      the O7p residual is the S1/SL-W store-to-load stale read
  THEN     U-Boot/EDK2 run stages are gated until SL-W gate-6 is green, but build-only U0/E0 can proceed
  UNLESS   the `g6lc_qemu` OpenSBI boot witness and `mini_fdt_next_tag_lbu` both pass
  BECAUSE  P1 (workload is a witness) + P4 (a broken promise is discovered at a third module)
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
| U2 | U-Boot loads the FIT and starts the kernel on `g6lc-virt` with virtio | `g6q run` + kernel console | Fast, minutes |
| U3 | Same on `g6lc-soc` with SD image (or SPI flash) | `g6q run` + kernel console | Hardware-faithful |
| U4 | Tandem with RTL trace for U1–U3 selected steps | `--diag d1` | Only after SL-W gate-6 green |

Stage U0 (build-loader) can start before the RTL residual is fully closed because it is a build step.
U1–U2 run on `g6lc-virt` with stock QEMU and are independent of the RTL queue order, but boot
validation must not claim green until `mini_fdt_next_tag_lbu` and the I6 clause 1 proof are green.
U3 and U4 are gated on `g6lc-soc` and on the queue fix.

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
variable store in a flash file. `g6lc-soc` EDK2 would need a real NOR/SPI flash model and is
explicitly deferred.

### 4.5 Validation ladder

| Stage | What | Gate |
|---|---|---|
| E0 | `build-loader` succeeds and emits a `.fd` | `g6q check` |
| E1 | SEC/PEI reaches DXE on `g6lc-virt` | `g6q run` + EDK2 serial output |
| E2 | BDS enumerates virtio block and loads an `EFI/boot/bootriscv64.efi` | `g6q run` |
| E3 | Linux starts under UEFI on `g6lc-virt` | `g6q run` + kernel console |
| E4 | Tandem with RTL trace | `--diag d1` (gated on SL-W gate-6 green) |

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

`g6q run --loader u-boot|edk2` is *not* implemented yet; it is part of U1/E1 and is gated on the RTL residual.

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
| **U2** | U1 green | `g6q run` U-Boot FIT → Linux on `g6lc-virt` | Distro boot in emulator |
| **U3** | U2 green + SL-W gate-6 green + I6 clause 1 proven | `g6lc-soc` U-Boot with SD/SPI, tandem D1 | Hardware-faithful boot |
| **E0** | Now (build-only scaffolding, in parallel with U0) | Pin EDK2 + edk2-platforms revs; implement `g6q fw build --loader edk2` for `g6lc-virt`; generate DEC/DSC/FDF/h + build script; expected to fail at runtime because the RISC-V SEC/PEI/DXE/BDS platform is not yet wired | Build scaffolding and dry-run green; no runtime claim |
| **E1** | E0 green + U2 green | `g6q run` EDK2 SEC/PEI to DXE on `g6lc-virt` | EDK2 FD witness in QEMU |
| **E2** | E1 green | `g6q run` EDK2 → Linux on `g6lc-virt` | UEFI distro boot |
| **E3** | E2 green + SL-W gate-6 green + I6 clause 1 proven | Tandem with RTL on selected U-Boot/EDK2 stages | Evidence |

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
