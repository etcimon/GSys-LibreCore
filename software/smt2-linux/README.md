# CVA6 SMT2 OpenSBI + rootfs software stack

In-tree **software profile** for dual-hart (`NrHarts=2`) Linux bring-up on
`g6lc64_smt2`. Uses OpenSBI **`PLATFORM=generic`** with the repo DTB
`corev_apu/bootrom/ariane-smt2.dts` (same approach as upstream OpenSBI
“Ariane FPGA” docs — no vendor platform C required).

| Piece | Path |
|-------|------|
| OpenSBI make env | `opensbi/g6lc64_smt2.env` |
| Dual-hart S-mode payload | `payload/smt2_sbi_dual.S` |
| Build / fetch scripts | `scripts/` |
| DTS of record | `../../corev_apu/bootrom/ariane-smt2.dts` |
| Plan | `../../architecture/multi-threading/smt-linux-rootfs.md` |

Outputs land under **gitignored** `build-platform/workspace/smt2-linux/` (or
`SMT2_LINUX_OUT`).

---

## Quick start

### Linux / WSL / MSYS2 (recommended for full OpenSBI firmware)

OpenSBI’s kconfig + PIE probe expect a **Unix** shell and a toolchain whose
linker supports `-pie` (e.g. `riscv64-unknown-linux-gnu-`) **or** apply the
in-tree non-PIE Makefile patch for `riscv-none-elf-` (`OPENSBI_ALLOW_NO_PIE=y`).

```bash
export CROSS_COMPILE=riscv64-unknown-linux-gnu-   # or riscv-none-elf- + non-PIE patch
./software/smt2-linux/scripts/fetch-opensbi.sh
./software/smt2-linux/scripts/build-opensbi-smt2.sh
export CVA6_LINUX_PAYLOAD=$PWD/build-platform/workspace/smt2-linux/fw_payload.elf
./verif/regress/smt-linux-rootfs.sh
```

### Windows (native)

| Step | Status |
|------|--------|
| Dual-hart S-mode payload (`smt2_sbi_dual`) | **Works** with managed xPack (`workspace/tooling/riscv`) |
| DTB (`dts_to_dtb.py` / `pip install fdt`) | **Works** without system `dtc` |
| OpenSBI `fw_payload.elf` | **Works** with **Cygwin bash+make** + xPack via path-translating wrappers (`scripts/riscv-none-elf-gcc-cygwrap.sh`); Git Bash alone lacks `make` |
| Suite preflight | **Works**; R3a firmware auto-detected; R3 cosim auto-dispatches to **WSL** via `verif/regress/smt-linux-r3-cosim.sh` |

```powershell
# 1) Observe what is missing (never invent install steps)
.\build.ps1 probe
.\build.ps1 probe install

# 2) Provision residual stack (profiles from probe install)
.\build.ps1 tools install dual-hart    # riscv-gcc + OpenSBI SMT2 scripts
.\build.ps1 tools install spike        # Spike ISS via WSL → workspace/tooling/spike

# 3) Compartmentalized SMT2 diagnostics (own Verilator target=g6lc64_smt2)
.\build.ps1 diag status
.\build.ps1 diag run smt2 --all

# products: build-platform/workspace/smt2-linux/fw_payload.elf
$env:CVA6_LINUX_PAYLOAD = (Resolve-Path build-platform\workspace\smt2-linux\fw_payload.elf)
# R0–R3a preflight + auto WSL R3 cosim (Verilator default):
.\verif\regress\smt-linux-rootfs.ps1
# Or R3 only under WSL:
wsl -e bash verif/regress/smt-linux-r3-cosim.sh
# ISS-only (faster smoke):
wsl -e bash -lc 'export DV_SIMULATORS=spike; bash verif/regress/smt-linux-r3-cosim.sh'
```

Manual equivalent:

```powershell
.\software\smt2-linux\scripts\fetch-opensbi.ps1
.\software\smt2-linux\scripts\build-opensbi-smt2.ps1
```

---

## OpenSBI SMT2 contract

| Item | Value |
|------|--------|
| Platform | `generic` (FDT-driven) |
| `FW_TEXT_START` | `0x80000000` (DRAM) |
| FDT | `ariane-smt2.dtb` — 2× `cpu@`, CLINT IPI+timer, PLIC, UART, `chosen` |
| Harts | Discovered from DTB (`reg` 0 and 1); **not** hard-coded to 1 |
| Cold boot | Both software harts enter OpenSBI; lottery + HSM park secondary |
| Payload default | `payload/smt2_sbi_dual` — SBI dual-hart smoke (R3a) |
| Payload Linux | `FW_PAYLOAD_PATH=$Image` + DTB bootargs / built-in initramfs (R3b) |

OpenSBI **≥ 1.4** recommended (Sstc discovery per `AGENTS-configuration.md`).

---

## Build products

| File | Role |
|------|------|
| `…/fw_payload.elf` | Primary sim/FPGA guest ELF |
| `…/fw_payload.bin` | Raw binary |
| `…/fw_jump.elf` | Jump firmware (optional) |
| `…/ariane-smt2.dtb` | Compiled DTB used at build |
| `…/smt2_sbi_dual.elf` | Standalone S-mode payload (also embedded) |

---

## Rootfs levels

| Level | Content | Gate |
|-------|---------|------|
| **R3a** | OpenSBI + dual-hart SBI payload | `build-opensbi-smt2` + sim |
| **R3** | Verilator RTL boot of `fw_payload.elf` | `verif/regress/smt-linux-r3-cosim.sh` (WSL/Linux) |
| **R3b** | OpenSBI + Linux `Image` (+ initramfs) | `-Linux` / `LINUX_IMAGE=` |
| **R3c** | Full cva6-sdk SD card (U-Boot + FIT) | Lab FPGA |

**R3 status (WSL):** with OSS CAD Suite Verilator + mamba g++/dtc + managed Spike libs,
`make verilate target=g6lc64_smt2` builds `work-ver/Variane_testharness`, and

```bash
./work-ver/Variane_testharness build-platform/workspace/smt2-linux/fw_payload.elf \
  +time_out=100000000 +debug_disable=1
# → *** SUCCESS *** (tohost = 0) after ~6.5M cycles
```

Windows `smt-linux-rootfs.ps1` auto-dispatches R3 to WSL when `wsl` is available.

---

## Env vars

| Var | Default / meaning |
|-----|-------------------|
| `SMT2_LINUX_OUT` | `build-platform/workspace/smt2-linux` |
| `OPENSBI_SRC` | Checkout path (fetched under OUT) |
| `OPENSBI_VERSION` | `v1.5` (tag/branch) |
| `CROSS_COMPILE` | e.g. `riscv64-unknown-elf-` or `riscv-none-elf-` |
| `LINUX_IMAGE` | Path to kernel Image for R3b |
| `CVA6_LINUX_PAYLOAD` | Override guest for `smt-linux-rootfs` suite |
