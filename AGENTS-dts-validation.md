# AGENTS-dts-validation.md — Linux device-tree ⇄ CVA6 cross-validation

The Linux **device tree** is the SoC-visible contract of what a RISC-V core implements: every
`compatible` string and property is a promise the hardware and its `.dts` must jointly keep. This file
lets an agent writing SystemVerilog **cross-validate** a change against the *actual upstream Linux
bindings and DTS*, so a new CSR, interrupt path, cache attribute, or memory region is expressed the way
Linux will actually probe it — not an invented shape.

The three artifacts kept aligned are: **Linux DT** (binding YAML + reference DTS) ⇄ **RISC-V spec**
(`agents/spec/`) ⇄ **CVA6 RTL** (`core/**`, `corev_apu/**`) and CVA6's own `.dts`. This extends
`AGENTS.md` §6 (`.dts` linkage) with fine-grained, file-level references and a working procedure.

> **Standing discipline (see `AGENTS.md` §0.6 and `AGENTS-coding-philosophy.md`).** When you change RTL
> that is device-tree visible (ISA string, CSRs, interrupt controller, timer, cache geometry, memory
> map, MMU mode), cross-validate against the Linux binding + a reference DTS and update the matching row
> here.

---

## 1. Obtaining the Linux DT source (no submodule)

The Linux kernel is **not** added as a git submodule: it is multi-GB and contains case-colliding paths
that fail to check out on case-insensitive filesystems (Windows NTFS, default macOS APFS). Instead, a
**cone-mode sparse + blobless** checkout fetches only the RISC-V DTS tree and the relevant bindings (a
few MB):

```sh
# Linux / macOS / WSL / Git-Bash
./build-platform/scripts/fetch-linux-dts.sh
```
```powershell
# Windows PowerShell / pwsh
.\build-platform\scripts\fetch-linux-dts.ps1
```

- **Destination**: `build-platform/workspace/linux-dts/` (git-ignored; `workspace/` is fully managed).
- **Pin**: the fetch records `url`/`ref`/`sha`/`fetched` in
  `build-platform/workspace/linux-dts/.cva6-dts-manifest` for reproducibility. Re-run to refresh to the
  latest `master`; pass `--ref v6.12` (or `-Ref`) to pin a release, `--dir`/`--url` to relocate/mirror.
- **Fetched paths**: `arch/riscv/boot/dts/**` and `Documentation/devicetree/bindings/{riscv,interrupt-controller,timer,cache}/**`.
  Add more with `--path` / `-Path`.

All paths below are relative to `build-platform/workspace/linux-dts/` (abbreviated `«dts»/`).

### 1.1 Automated check (binding tokens + structural)

```powershell
.\build-platform\scripts\fetch-linux-dts.ps1
.\build-platform\scripts\validate-cva6-dts.ps1
```

Reports **FAIL** (schema/token mistakes we can fix), **WARN** (style), and **GAP**
(unfixable without Linux upstream or RTL — see
`architecture/multi-threading/dts-linux-smt.md` §3.2).

CVA6 DTS under validation:

| File | Intent |
|------|--------|
| `corev_apu/bootrom/ariane.dts` | Tandem bare (PLIC off) |
| `corev_apu/bootrom/ariane-linux.dts` | Single-hart Linux |
| `corev_apu/bootrom/ariane-smt2.dts` | Dual-hart SMT Linux topology |
| `corev_apu/bootrom/ariane-stream8.dts` | Dual-core stream8 residual package topology |
| `corev_apu/bootrom/ariane-ooo-int2.dts` | Two-core × two-hart integer OoO (`g6lc64_ooo_int2`): 4 `cpu@`, cpu-map core0/core1 × thread0/1, 4-hart CLINT/PLIC, shared L2 node, no f/d, zawrs unadvertised; `dts_to_dtb.py` maps it to `g6lc64_ooo_int2_config_pkg.sv` (plat_hc 4). Isolated OpenSBI strict-payload qualification only, not a Linux SKU. |
| `corev_apu/bootrom/ariane-ooo-int2-l3.dts` | Two-core × two-hart OoO + non-inclusive L3 (`g6lc64_ooo_int2_l3`): same topology as `ariane-ooo-int2.dts` plus the L3 `cache-level=<3>` node and L2→L3 `next-level-cache`; **f/d advertised** since T9g/M4 (`riscv,isa = rv64imafdc_zba_zbb_zbs_zicbom_zicboz_zacas`, extensions include `f`/`d`), `smt,fp-register-banking=<0>` kept (drained handoff switches the whole FS context); `dts_to_dtb.py` maps it to `g6lc64_ooo_int2_l3_config_pkg.sv` (plat_hc 4). Validator: FAIL=0, WARN/GAP=1 (pre-existing dual CLINT binding). Isolated OpenSBI strict-payload qualification only. |
| `corev_apu/bootrom/ariane-stream8-l3.dts` | Dual-core in-order stream8 + non-inclusive L3 (`g6lc64_stream8_l3`): `ariane-stream8.dts` topology plus the L3 `cache-level=<3>` node (1 MiB, 16-way, 64 B lines, 1024 sets) and L2→L3 `next-level-cache`; `dts_to_dtb.py` maps it to `g6lc64_stream8_l3_config_pkg.sv` (plat_hc 2). Validator: FAIL=0, WARN/GAP=2 (pre-existing dual CLINT binding + `riscv,max-priority`, same as the base stream8 tree). |
| `corev_apu/bootrom/ariane-server-math-l3.dts` | Dual-core in-order server_math + non-inclusive L3 (`g6lc64_server_math_l3`): same L3 additions as `ariane-stream8-l3.dts`; `dts_to_dtb.py` maps it to `g6lc64_server_math_l3_config_pkg.sv` (plat_hc 2). Validator: FAIL=0, WARN/GAP=2 (same pre-existing GAPs). |
| `gpu@40001000` (`virtio,mmio`) | LibreCore APU guest window; `status = "disabled"` until a `G6LC_APU` testharness build instantiates `g6lc_apu_xbar`. PLIC source 9. Control `0x40002000` is firmware-only and omitted. Default testharness topology is unchanged. |
| `g6lc-apu-domain.dtsi` | OpenSBI domain overlay for firmware hart 1; **not included** in default DTBs. Do not apply to `ariane-smt2.dts`. |

---

## 2. Reference (generic) DTS — what CVA6 mirrors

CVA6's SoC device trees model a single- (or few-) hart RV64GC machine with a hart-local interrupt
controller, a CLINT (timer/soft IRQ), a PLIC (external IRQ), and a RAM region. The upstream Linux files
that embody the same generic shape — the best study/validation references — are:

| Linux reference DTS (`«dts»/…`) | Why it is the generic reference | CVA6 counterpart |
|---|---|---|
| `arch/riscv/boot/dts/sifive/fu540-c000.dtsi` | Canonical RV64GC Linux SoC (4×U54 + E51), PLIC + CLINT + L2 | `corev_apu/bootrom/ariane.dts`, `corev_apu/fpga/src/bootrom/cv64a6.dts.in` |
| `arch/riscv/boot/dts/sifive/fu740-c000.dtsi` | Successor (HiFive Unmatched); adds PCIe/ccache | `corev_apu/fpga/src/bootrom/cv64a6_agilex.dts.in` |
| `arch/riscv/boot/dts/microchip/mpfs.dtsi` | PolarFire SoC; multi-hart, MMU, clint/plic | multi-core target → `architecture/multi-core/` |
| `arch/riscv/boot/dts/starfive/jh7100.dtsi` | Consumer RV64GC SoC | (integration reference) |

CVA6's own device trees (the files an edit must keep consistent):
`corev_apu/bootrom/ariane.dts`, `corev_apu/fpga/src/bootrom/{cv32a6,cv64a6,cv32a6_agilex,cv64a6_agilex}.dts.in`,
`corev_apu/openpiton/bootrom/{baremetal,linux}/ariane.dts`, `verif/tb/core/bootrom/cva6.dts`.

> Note: CVA6 uses the **legacy** compatibles/properties (`riscv,isa = "rv64imafdc"`, `riscv,plic0`,
> `riscv,clint0`). Modern Linux prefers the **fine-grained** `riscv,isa-base` + `riscv,isa-extensions`
> (`riscv/extensions.yaml`) and `sifive,plic-1.0.0`. New work should validate against the modern binding
> and, where a feature is newly exposed, prefer the modern property.

---

## 3. DT node ⇄ spec ⇄ CVA6 RTL cross-reference

| DT node / property | `compatible` | Linux binding (`«dts»/Documentation/devicetree/bindings/…`) | RISC-V spec anchor | CVA6 RTL (+ config knob) | CVA6 `.dts` node |
|---|---|---|---|---|---|
| `cpu@N` ISA string — `riscv,isa`, `riscv,isa-base`, `riscv,isa-extensions` | `"riscv"` (vendor IDs need upstream enum) | `riscv/cpus.yaml`, `riscv/extensions.yaml` | Vol I `#base`, extension chapters; Zacas `#ext:zacas` | `core/csr_regfile.sv` (`IsaCode`/`misa`); `RVZacas` on `g6lc64_smt2` / `server_math{,_v}` / `ooo_server` / `stream8` | `ariane.dts` (baseline) / **`ariane-linux.dts`** + **`ariane-smt2.dts`** (full: zba/zbb/zbs/zicbo*/**zacas**) / **`ariane-server-math-v.dts`** (`v` + zacas for `_v` pkg) |
| Multi-hart / SMT `cpu@N` + `cpu-map` `{ threadN { cpu } }` | `"riscv"` | `cpus.yaml` (hart = execution context) | Priv (hart) | `NrHarts`, `cva6_smt_*`, mhartid=`base+h` | `ariane-smt2.dts` (thread0/1 under core0); `ariane-stream8.dts` (core0/core1 × thread0); **`ariane-server-math-v.dts` (2 cores × 2 threads, maxcpus=4)**; `ariane-ooo-server.dts` (4×2); `chosen.bootargs` maxcpus + root=/dev/ram (rootfs track). B1 QEMU FDT (`g6q-emit-qemu` `dts.rs`) now emits the same thread-child shape (cpu-node phandle, not intc); Linux no longer logs `Can't get CPU for leaf core` on `g6lc-soc` |
| `cpu@N` `mmu-type` | `"riscv"` | `riscv/cpus.yaml` | `#sv39` (II-4.4), `#sv32`/`#sv48`/`#sv57` | `core/cva6_mmu/` (`vm_mode_t`) | `mmu-type = "riscv,sv39"` |
| `cpu@N` `tlb-split` | — | `riscv/cpus.yaml` | II-4.x paging / TLB | `core/cva6_mmu/` (`InstrTlbEntries`,`DataTlbEntries`) | `tlb-split;` |
| `cpu@N` `riscv,cbom-block-size` / `riscv,cboz-block-size` | — | `riscv/cpus.yaml` | `#cmo` (I-4.20), `#ext:zic64b` (I-4.15) | `core/cache_subsystem/*` (`RVZiCbom`/`RVZiCboz`) | `ariane-smt2.dts` (`<64>`) when Zicbo* on. B1 QEMU FDT now emits the same 64 B CMO size plus L1 `i-cache-*`/`d-cache-*` from `Icache*`/`Dcache*` (line width is bits) |
| HART local intc `interrupt-controller` | `"riscv,cpu-intc"` | `interrupt-controller/riscv,cpu-intc.yaml` | Priv ch3 (local interrupts: `mie`/`mip`) | `core/csr_regfile.sv` (`mie/mip/mideleg`) | `CPU0_intc` |
| Timer/soft-IRQ `clint@` | chip-id + `"sifive,clint0"` (bare dual form = QEMU/deprecated) | `timer/sifive,clint.yaml` | Priv ch3; `#Sstc` | `corev_apu/clint/` via harness `NR_HARTS=NrCores×NrHarts`; per-bank `time_irq`/`ipi` in `g6lc_smt_csr_bank`. 2026-09-25: MSIP read data uses the addressed 32-bit lane of the 64-bit AXI bus; no register-map, topology, interrupt-routing or DTS-property change. Directed RV32/RV64 lane controls, not a new Linux boot qualification. | `clint@2000000` in linux/smt2 DTS (2× pairs for smt2) |
| External-IRQ PLIC | chip-id + `"sifive,plic-1.0.0"` | `interrupt-controller/sifive,plic-1.0.0.yaml` | Priv ch3 | `corev_apu/rv_plic/` (`NumTargets=16`) | enabled in `ariane-linux.dts` / `ariane-smt2.dts`; **commented** in tandem `ariane.dts` |
| `cpus` `timebase-frequency` / `cpu@N` `clock-frequency` | — | `riscv/cpus.yaml` | Priv (`mtime` rate); Zicntr `#zicntr` | `corev_apu/clint/` (mtime), `core/perf_counters.sv` | `timebase-frequency`, `clock-frequency` |
| L2/LLC `cache-*`, `next-level-cache` | `"cache"`, `"sifive,ccache0"` | `cache/sifive,ccache0.yaml` | `#memorymodel` (I-3.1), `#pma` (II-3.6), `#ext:zic64b` | `corev_apu/l2_cache/*`, `L2En`/`L2ByteSize` (auto in `build_config_pkg`) | board DT sketch: `architecture/l2-l3-cache/dts-l3-prefetch.md` |
| L3 `cache-level=<3>`, `next-level-cache` | `"cache"` | *(generic cache + SiFive LLC patterns)* | `#memorymodel`, `#ext:zic64b` | `corev_apu/l3_cache/*`, `L3En`/`L3ByteSize` (auto) | same sketch (`l3-cache` node); `ariane-ooo-int2-l3.dts` / `ariane-smt2-l3.dts` / `ariane-stream8-l3.dts` / `ariane-server-math-l3.dts` (non-inclusive 1 MiB/16-way L3, L2→L3 `next-level-cache`) |
| `cpu@N` `riscv,cboz-block-size` / `cbom-block-size` | — | `riscv/cpus.yaml` | `#cmo` (I-4.20) | `RVZiCboz`/`RVZiCbom`, store_unit multi-beat | server_math / ooo packages enable CBO |
| Server prefetch (no DT node) | — | — | microarch | `g6lc_server_prefetcher`, `ServerPrefetchEn` | *(not DT-visible; PMU group 2)* |
| Hypervisor / Sstc host | `"riscv"` | `riscv/extensions.yaml` (`h`, `sstc`) | `#hypervisor`, Sstc | `RVH`, `SstcEn`, `csr_regfile` (SMT: per-hart in `g6lc_smt_csr_bank`) | `h` **iff** `RVH=1`: `_v` advertises `h`; **stream8 RTL has `RVH=1` but `ariane-stream8.dts` omits `h` today** (add token when KVM should see H); **smt2 `RVH=0` — do not add `h`** (`CONTRACT.md` §6.5). `sstc` already on smt2/stream |
| Vector RVV 1.0 host (U10ᵇ) | `"riscv"` | `riscv/extensions.yaml` (`v`, `zve64d`) | `#ext:v` (I-9); depends Zve64d+Zvl128b | `RVV` / `EnableAccelerator`, `g6lc_ara_attach` (VLEN=4096) | **only** `ariane-server-math-v.dts` advertises `v`+`zve64d`+`imafdcv…`; smt2 / stream8 / linux / default trees must not (`CONTRACT.md` §6) |
| `memory@<base>` | `device_type="memory"` | *(generic — no vendor binding)* | `#sec:intro-memory` (I-1.4), `#pma` (II-3.6) | `Axi*Width` + cacheable region rules (`check_cfg`) | `memory@80000000` |
| `ai-matrix@40000000` | `"g6lc,ai-matrix"` | *(custom — no upstream binding)* | custom `Xg6lcai` | `g6lc_ai_island_cfg_pkg` (`DramClass`, `DramChannels`, `DramChanShift`, `DramGBps`); CAP window | `ariane-ai.dts`; I3-lite class 0, 8 GB/s, **1 channel**, `g6lc,dram-chan-shift=<6>`; CAP `0x38` packs count+shift (**PASS** `tb_g6lc_ai_cap_occupancy` live 1/6 + CLASS1 N=2 `2/6`). N>1 is still **one** `memory@` (hardware stripe on the shared DRAM slave; cores + island). CLASS1/CHANS_* do not add per-channel `memory@`. |
| `soc` bus | `"simple-bus"` | *(generic)* | `#pma` (region attributes) | `corev_apu/` AXI interconnect | `soc { … "simple-bus"; }` |

For the config-knob ↔ spec side of each row, see `AGENTS-specs-to-impl.md`; for the RTL playbooks, the
`agents/guides/AGENTS-*.md`.

---

## 4. Cross-validation procedure (agent workflow)

When authoring/altering **device-tree-visible** SystemVerilog, before calling the change done:

1. **Fetch/refresh** the DT source (§1) if `build-platform/workspace/linux-dts/` is absent or stale.
2. **Find the node** for the feature in §3 → open the **binding YAML** under `«dts»/Documentation/…`.
   Read its `compatible` enum, `required` properties, and value constraints. This is the upstream
   contract your RTL and CVA6 `.dts` must satisfy.
3. **Study a reference DTS** (§2, e.g. `sifive/fu540-c000.dtsi`) to see the node instantiated in context
   (addresses, `interrupts-extended`, cell counts).
4. **Confirm CVA6's `.dts`** (`corev_apu/…/*.dts*`) carries a matching, binding-valid node. If your RTL
   adds/changes a DT-visible capability, update CVA6's `.dts` to match the binding.
5. **Confirm the RTL** implements the promised behavior (the CVA6 RTL column of §3) and is gated by the
   right `CVA6Cfg` knob (`AGENTS-specs-to-impl.md`).
6. **Confirm the spec anchor** (the spec column) — the DT contract must not contradict the ISA.
7. Any mismatch among {binding, reference DTS, CVA6 `.dts`, RTL, spec} is a **bug to reconcile**, not a
   discrepancy to ignore. Record the resolved mapping in the row above.

Worked example — *widening the ISA string to advertise a new extension*: `riscv/extensions.yaml` lists
the legal `riscv,isa-extensions` tokens → add the token in CVA6's `.dts`, set the corresponding `RV*`
bit in `core/include/config_pkg.sv`, reflect it in `misa` via `core/csr_regfile.sv`, and confirm the
spec chapter in `AGENTS-specs-to-impl.md`. If the token is not yet in `extensions.yaml`, it is not
Linux-discoverable — treat that as a gating fact.

---

## 5. Maintenance contract

- **Refresh**: re-run the fetch script to track upstream; the `.cva6-dts-manifest` records the exact SHA.
- **On DT-visible RTL change**: update the affected §3 row (binding path, CVA6 RTL loci, CVA6 `.dts`
  node) and, if ISA-visible, the matching `AGENTS-specs-to-impl.md` row.
- **On new peripheral/CSR/mode**: add a §3 row and, where relevant, a §2 reference-DTS entry.
- This file is co-equal with the other standing disciplines in `AGENTS.md` §0.6; the cross-validation
  *practice* is codified in `AGENTS-coding-philosophy.md`.
