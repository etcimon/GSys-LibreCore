# SMT Linux rootfs path (U6.1 → full image)

**Status:** R0–R3a in-tree; **R3a firmware built on Windows**
(`build-platform/workspace/smt2-linux/fw_payload.elf` via managed xPack + Cygwin OpenSBI wrap).  
**R3 cosim:** run under **Linux/WSL** with native Verilator + `setup-env.sh`.  
Native Windows: `cva6.py` is partially ported (`dv/lib.py` bash `-lc`, xPack GCC parse, `.elf`
tests) but **Cygwin make + Windows Verilator** mixes `/cygdrive` and `C:/` and fails (e.g.
`verilated_std_waiver.vlt`). Suite soft-passes R3a; use `CVA6_FORCE_WIN_CVA6PY=1` to attempt.  
Spike: Linux/WSL only (Cygwin `addr_t` clash). **R3b/R3c** need Linux `Image` / cva6-sdk.  
**Prerequisite gate:** `verif/regress/smt-linux-boot-path.{ps1,sh}` must PASS.

---

## 0. Why this track

`smt-linux-boot-path` proves **RTL + DTS** can describe two software harts
(`NrHarts=2`, CLINT/PLIC, per-bank IRQ). A **rootfs test** also needs:

1. OpenSBI domain with **2 harts** from DTB (`PLATFORM=generic`)  
2. Linux `Image` + initramfs/rootfs that sees `cpu@0` and `cpu@1`  
3. Sim/FPGA load path; secondary parked until HSM start  
4. Pass criteria: UART `SMT2-OSBI-OK` (R3a) or prompt + `/proc/cpuinfo` (R3b)

Images stay out of git under `build-platform/workspace/smt2-linux/` (gitignored).

---

## 1. Phases

| Phase | Deliverable | In-repo? | Gate |
|-------|-------------|----------|------|
| **R0** | Boot-path DTS/RTL | Yes | `smt-linux-boot-path` |
| **R1** | Rootfs plan + `chosen` bootargs + dual-hart park | Yes | `smt-linux-rootfs` preflight |
| **R2** | Image layout contract | Yes | suite id `smt-linux-rootfs` |
| **R3a** | **OpenSBI SMT2 + dual-hart SBI payload** | Yes (`software/smt2-linux/`) | build + optional sim |
| **R3b** | OpenSBI + Linux `Image` (+ initramfs) | Scripts; Image external | `-Linux` / `LINUX_IMAGE` |
| **R3c** | cva6-sdk SD (U-Boot + FIT) | Lab FPGA | manual |
| **R4** | `taskset -c 0,1` stress | Lab | manual / nightly |

Default `verify` never requires R3 images/toolchains.

---

## 2. OpenSBI SMT2 (in-tree software)

| Item | Location |
|------|----------|
| Profile README | `software/smt2-linux/README.md` |
| Make env | `software/smt2-linux/opensbi/cva6_smt2.env` |
| Dual-hart S-mode payload | `software/smt2-linux/payload/smt2_sbi_dual.S` |
| Fetch / build | `software/smt2-linux/scripts/{fetch,build}-opensbi-smt2.{ps1,sh}` |
| Toolchain hint | `software/smt2-linux/scripts/install-toolchain-hint.ps1` |

```powershell
.\software\smt2-linux\scripts\fetch-opensbi.ps1
.\software\smt2-linux\scripts\build-opensbi-smt2.ps1
# products: build-platform/workspace/smt2-linux/fw_payload.elf
$env:CVA6_LINUX_PAYLOAD = (Resolve-Path build-platform\workspace\smt2-linux\fw_payload.elf)
.\verif\regress\smt-linux-rootfs.ps1
```

Contract: `PLATFORM=generic`, `FW_TEXT_START=0x80000000`, `FW_FDT_PATH=ariane-smt2.dtb`,
payload = dual-hart SBI smoke (default) or Linux `Image`. OpenSBI **≥ 1.4** (pin **v1.5**).

Upstream OpenSBI “Ariane FPGA” also uses `PLATFORM=generic` + Linux payload — we add
**explicit dual-hart DTB** and an SBI dual-start smoke before full rootfs.

---

## 3. Software stack shapes

### 3.1 Simulation — FW_PAYLOAD (R3a / R3b)

| Env | Meaning |
|-----|---------|
| `CVA6_LINUX_PAYLOAD` | Guest ELF (default: built `fw_payload.elf`) |
| `DV_TARGET` | `g6lc64_smt2` |
| `LINUX_IMAGE` | Kernel Image for R3b build |
| `SMT2_SKIP_OSBI_BUILD` | Set to skip auto-build in suite |

### 3.2 FPGA / SD — **cva6-sdk**

Upstream: [openhwgroup/cva6-sdk](https://github.com/openhwgroup/cva6-sdk)

Embed **`ariane-smt2.dtb`** in FIT; OpenSBI domain sees 2 harts from DTB.

---

## 4. DTS / memory / bootargs

| File | Role |
|------|------|
| `corev_apu/bootrom/ariane-smt2.dts` | Dual-hart Linux DTS + `chosen.bootargs` |
| `make -C corev_apu/bootrom linux-dtbs` | Emit `.dtb` |

Memory: **256 MiB** at `0x8000_0000` (sim-friendly). Genesys2 may overlay 1 GiB.

---

## 5. Pass criteria

| Level | Pass |
|-------|------|
| R3a | Build `fw_payload.elf`; UART contains `SMT2-OSBI-OK` (or sim completes without trap storm) |
| R3b | Shell / BusyBox; `/proc/cpuinfo` two processors |
| R4 | Dual-hart load without hang |

---

## 6. Related

| Doc / suite | Role |
|-------------|------|
| `software/smt2-linux/README.md` | OpenSBI build operator guide |
| `dts-linux-smt.md` | DTS validation |
| `smt2-bringup.md` | RTL software view |
| `smt-linux-boot-path` / `smt-linux-rootfs` | Gates |

## R3b gate (suite)

| Item | Path |
|------|------|
| Gate script | `verif/regress/r3b-linux-image.sh` (suite id `r3b-linux-image`) |
| Image hint | `software/smt2-linux/scripts/fetch-linux-image-hint.sh` |
| Build FW with Image | `LINUX_IMAGE=...` + `CVA6_R3B_BUILD=1` or `make -C software/smt2-linux opensbi-linux` |

Soft-skips when no Image unless `CVA6_REQUIRE_R3B=1`. Full shell /proc/cpuinfo remains lab criteria when Image is present.

## Residual gate

erif/regress/dual-hart-residual.sh — Spike R3a OpenSBI + R3b contract; optional bare LIVE and R3a RTL (CVA6_R3A_RTL=1).
R3a Spike is the hard dual-hart firmware gate; R3a RTL remains open after mock_uart Verilator elaboration fix.
