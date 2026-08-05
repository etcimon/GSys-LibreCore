# DTS validation + SMT Linux boot (from Linux-provided sources)

This document **does not invent** device-tree shapes. It validates CVA6 DTS files
against the **fetched Linux kernel** sparse tree and records what Linux requires
that CVA6 still cannot satisfy without larger RTL or upstream changes.

## 1. Linux source (minimal pull — subdirectory only)

| Item | Path |
|------|------|
| Fetch | `build-platform/scripts/fetch-linux-dts.ps1` (sparse + blobless; **not** full kernel) |
| Tree | `build-platform/workspace/linux-dts/` (**gitignored**) |
| Manifest | `…/linux-dts/.cva6-dts-manifest` (`url` / `ref` / `sha`) |
| Bindings | `Documentation/devicetree/bindings/riscv/{cpus,extensions}.yaml` |
| CLINT | `Documentation/devicetree/bindings/timer/sifive,clint.yaml` |
| PLIC | `Documentation/devicetree/bindings/interrupt-controller/sifive,plic-1.0.0.yaml` |
| Reference multi-hart | `arch/riscv/boot/dts/sifive/fu540-c000.dtsi` |
| CLINT multi-hart list | `arch/riscv/boot/dts/microchip/mpfs.dtsi` |

Validate:

```powershell
.\build-platform\scripts\fetch-linux-dts.ps1   # once / refresh
.\build-platform\scripts\validate-cva6-dts.ps1
.\verif\regress\smt-linux-boot-path.ps1        # full in-repo boot-path gate
```

## 2. CVA6 DTS files (role)

| File | Role | Linux boot? |
|------|------|-------------|
| `corev_apu/bootrom/ariane.dts` | Tandem / bare bring-up | **No** (PLIC commented) |
| `corev_apu/bootrom/ariane-linux.dts` | Single-hart Linux-oriented | **Yes** (target) |
| `corev_apu/bootrom/ariane-smt2.dts` | Dual-hart SMT (`NrHarts=2`) | **Yes** (RTL IRQ path landed) |
| `corev_apu/fpga/src/bootrom/cv64a6*.dts.in` | FPGA templates | Board-specific |

## 3. Validation results (adjustable vs unfixable)

### 3.1 Adjustable (done — minimal diffs from Linux shape)

| Issue | Linux expectation | CVA6 action |
|-------|-------------------|-------------|
| `riscv,isa-base` missing | `cpus.yaml` / modern practice (`fu540`) | **Fixed** in linux/smt2/tandem/FPGA templates |
| Incomplete `riscv,isa-extensions` | Letter + `zicntr`/`zicsr`/`zifencei`/`zihpm` | **Fixed**; smt2 lists package tokens only if in `extensions.yaml` |
| Invalid `compatible = "eth, ariane"` | Space + not in `cpus.yaml` enum | **Fixed** → `"riscv"` |
| CLINT list form | `<&intc 3>, <&intc 7>` per hart (`mpfs`) | **Fixed** dual-hart pairs in `ariane-smt2.dts` |
| CLINT/PLIC cell count vs `cpu@` | 2× MSIP/MTIP; 2× M/S external | **Validator enforces** |
| PLIC for Linux | `sifive,plic-1.0.0` + M/S contexts | **In** `ariane-linux.dts` / `ariane-smt2.dts` |
| Multi-hart topology | `cpu@N` + `cpu-map` | **In** smt2: `thread0`/`thread1` under `core0` |
| CBO block size | `riscv,cboz/cbom-block-size` | **In** smt2 (64 B CMO; L1 line remains 16 B) |
| L1 `*-cache-block-size` | Honest line size | **16** (LineWidth=128), not 64 |
| Package extras on smt2 | RVB/Zicbo*/Zicond/Zawrs/… | **Listed** only when token is in `extensions.yaml` |

### 3.2 Unfixable from CVA6-only (document; need Linux upstream or larger RTL)

| Gap | Why Linux cares | Why we cannot fix here alone |
|-----|-----------------|------------------------------|
| **Vendor CPU `compatible` ID** | Production SoCs use `sifive,u54-mc`, … then `"riscv"` | `"eth,ariane"` is **not** in `cpus.yaml` enum. Needs Linux binding patch. Schema-safe: plain `"riscv"`. |
| **Chip-specific CLINT first string** | `sifive,fu540-c000-clint`, … | Bare platform has no product SKU. Dual `"sifive,clint0"`, `"riscv,clint0"` is the **deprecated QEMU** form (still accepted). |
| **Chip-specific PLIC first string** | `sifive,fu540-c000-plic` + `sifive,plic-1.0.0` | Same: use `sifive,plic-1.0.0` + `riscv,plic0`. |
| **Tandem bare DTS without PLIC** | Linux needs external IRQ for UART | `ariane.dts` keeps PLIC **commented**. Use `ariane-linux.dts` / `ariane-smt2.dts` for boot. |
| **PLIC target budget** | 2 contexts × total harts | `ariane_soc::NumTargets=16` ⇒ ≤ **8** software harts. Larger → regenerate PLIC regmap. |
| ~~Per-hart CLINT/PLIC wiring~~ | was blocking | **Landed:** CLINT `NR_HARTS=NrCores×NrHarts`; per-bank IRQ; active-hart mux for decode. |
| **L1 block size = 64** | Many boards advertise 64 B lines | CVA6 L1 is often **16 B**. Advertising 64 would **lie**. CMO uses separate properties. |
| **OpenSBI platform** | Matching DTB + hart count | Lab: pin OpenSBI `expected_harts` and embed DTB (out of default verify). |
| **`riscv,pmu` binding** | Full schema may be outside sparse set | Keep map optional; validator WARNs. |

### 3.3 Feature exposure matrix (misa / DTS / package)

| Feature | `misa` / CSR | `riscv,isa-extensions` | Package example |
|---------|--------------|------------------------|-----------------|
| IMAFDC | I,M,A,F,D,C | `i,m,a,f,d,c` + zic* | all app-class |
| B / Zba Zbb Zbs | `misa.B` when `RVB` | `b`, `zba`, `zbb`, `zbs` | smt2, server_math |
| Zicond / Zcb | package bits | `zicond`, `zcb` | smt2 |
| Zicbo* | envcfg | `zicbom`, `zicboz`, `zicbop` + cbo*-block-size | smt2 |
| Zkn | `ZKN` | `zkn` | smt2 |
| Sstc / Sscofpmf / Zihintpause / Svpbmt / Zawrs | package enables | matching tokens | smt2 |

Source of truth: `core/csr_regfile.sv` `IsaCode`; `core/include/cv64a6_*_config_pkg.sv`.

## 4. SMT Linux boot sequence (complete path)

### 4.1 In-repo automated gate

```powershell
.\build-platform\scripts\fetch-linux-dts.ps1   # sparse Linux DTS (once)
.\verif\regress\smt-linux-boot-path.ps1        # DTS + RTL path checks  → PASS required
.\build.ps1 verify --lint --target g6lc64_smt2 # optional elaborate SMT package
# Optional suite id (not default verify): smt-linux-boot-path / dual-hart-ci
```

Gates: package `NrHarts=2`, harness CLINT `NR_HARTS`, CSR bank per-hart timer/IPI,
`irq_active` mux, cluster `hart_id_base`, `ariane-smt2.dts` topology, `validate-cva6-dts` FAIL=0.

### 4.2 Lab boot (outside default CI)

1. DTB: `dtc -I dts -O dtb -o ariane-smt2.dtb corev_apu/bootrom/ariane-smt2.dts`  
2. Config: `g6lc64_smt2_config_pkg` (`NrHarts=2`, `NrCores=1` → mhartid 0 and 1)  
3. RTL (in tree):  
   - CLINT slots = `NR_HARTS` in `ariane_testharness`  
   - Cluster `hart_id_base = core × NrHarts`  
   - Per-bank `time_irq` / `ipi` / PLIC `{MEIP,SEIP}` into `g6lc_smt_csr_bank`  
   - Decode/RVFI: `irq_active = irq_i[smt_active_hart]`  
4. OpenSBI: `expected_harts=2`, embed or jump with DTB  
5. Linux: `maxcpus=2`; `/proc/cpuinfo` shows two harts  

### 4.3 Rootfs track (next after this gate)

See **`smt-linux-rootfs.md`**. In-repo:

```powershell
.\verif\regress\smt-linux-rootfs.ps1          # R1–R2 preflight (+ R0)
# R3 when images exist:
$env:CVA6_LINUX_PAYLOAD = "path\to\opensbi_linux.elf"
.\verif\regress\smt-linux-rootfs.ps1
```

`ariane-smt2.dts` carries `chosen.bootargs` with `maxcpus=2` and `root=/dev/ram`.  
Build DTB: `make -C corev_apu/bootrom linux-dtbs`.  
Full image CI remains optional (cva6-sdk / external payload).

## 5. Related

- Standing map: `AGENTS-dts-validation.md`  
- L2/L3 DT: `architecture/l2-l3-cache/dts-l3-prefetch.md`  
- SMT RTL: `architecture/multi-threading/smt2-bringup.md`  
- Rootfs path: `architecture/multi-threading/smt-linux-rootfs.md`  

