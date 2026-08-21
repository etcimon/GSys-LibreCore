# FDT topology × threads-per-core × soft ladder

Plan for how **device tree**, **Linux `/proc/cpuinfo`**, and **OpenSBI platform
discovery** behave as LibreCore is parameterized by:

| Knob | Config field | Meaning |
|------|--------------|---------|
| **N** physical cores | `NrCores` | Cluster instances / AXI core ports |
| **T** threads per core | `NrHarts` | SMT banks per core (legal 1 or 2 today) |
| **I** issue width | `NrIssuePorts` / `SuperscalarEn` | Microarch only — **not** a Linux hart |
| Stream plane | `g6lc64_stream8` (etc.) | Multi-core, typically `T=1` |
| SMT plane | `g6lc64_smt2` | Single core, `T=2` |

Cross-refs: `dts-linux-smt.md`, `smt2-bringup.md`, `soft-ladder/`,
`AGENTS-dts-validation.md`, `software/smt2-linux/README.md`.

---

## 1. Software-visible identity (harts), not issue ports

**Linux and OpenSBI only see software harts** — each `cpu@M` node with a unique
`reg = <mhartid>`.

```text
  total_software_harts  S  =  NrCores × NrHarts
  mhartid(core c, thread t) = c × NrHarts + t     // c ∈ [0,N), t ∈ [0,T)
```

RTL already implements this:

- Cluster: `hart_id_i = c * NrHarts` (`corev_apu/src/g6lc_cluster.sv`)
- Per-bank CSR adds local thread id → architectural `mhartid`
- CLINT/PLIC: `NR_HARTS = NR_CORES × NR_HARTS_PER_CORE` (`ariane_testharness.sv`)

| Parameter | In FDT / cpuinfo? | Why |
|-----------|-------------------|-----|
| `NrCores` | **Indirect** — shape of `cpu-map` cores | Topology |
| `NrHarts` (threads/core) | **Indirect** — threads under each core | Topology |
| `NrIssuePorts` / dual-issue | **No** | Pipeline width; not a hart; no DT property |
| Caches / ISA / CMO | **Yes** | Per-cpu properties |

**Do not** invent a DTS property for issue width. If software ever needs it,
expose via PMU/debug only, never as `cpu@`.

---

## 2. `cpu-map` shapes (threads per core)

Linux `cpus.yaml`: a **hart** is an execution context. `cpu-map` describes
package → cluster → **core** → **thread** → phandle to `cpu@`.

### 2.1 SMT plane — `N=1`, `T=2` (`ariane-smt2.dts`, `g6lc64_smt2`)

```text
cpu-map {
  cluster0 {
    core0 {
      thread0 { cpu = <&CPU0>; };   // mhartid 0
      thread1 { cpu = <&CPU1>; };   // mhartid 1
    };
  };
};
```

| Field | Value |
|-------|--------|
| `cpu@0` / `cpu@1` | Both `status = "okay"`, identical ISA/cache props |
| `chosen.bootargs` | `maxcpus=2` |
| CLINT `interrupts-extended` | 2 × (MSIP, MTIP) |
| PLIC contexts | 2 × (M-ext, S-ext) = 4 |

**`/proc/cpuinfo`:** two processors (`processor : 0/1`), same `hart` and features;
topology may show one core, two threads (scheduler SMT siblings) once topology
parsing is healthy.

### 2.2 Stream plane — `N=2`, `T=1` (`ariane-stream8.dts`, `g6lc64_stream8`)

```text
cpu-map {
  cluster0 {
    core0 { thread0 { cpu = <&CPU0>; }; };  // mhartid 0
    core1 { thread0 { cpu = <&CPU1>; }; };  // mhartid 1
  };
};
```

Same two `cpu@` nodes as SMT in *count*, **different** `cpu-map`: two cores ×
one thread. Linux treats them as two cores (no SMT sibling pair). Issue width on
stream8 is currently **1** (`SuperscalarEn=0`).

### 2.3 Future hybrid — `N≥2`, `T=2` (not a default package yet)

```text
S = N×T harts
cpu@0 .. cpu@(S-1)
cpu-map:
  cluster0 {
    core0 { thread0 → cpu@0; thread1 → cpu@1; }
    core1 { thread0 → cpu@2; thread1 → cpu@3; }
    ...
  }
```

| Constraint | Source |
|------------|--------|
| `S ≤ 8` | PLIC `NumTargets=16` → 2 contexts × 8 harts (`dts-linux-smt.md` §3.2) |
| `NrHarts ∈ {1,2}` | `check_cfg` today; wider SMT needs RF/CSR bank + DTS generator work |
| CLINT reg size | Already scaled by `NR_HARTS` in harness |

### 2.4 Single-issue vs dual-issue (I) on the same topology

| Package | N | T | I | DTS of record |
|---------|---|---|---|---------------|
| Default app packages | 1 | 1 | 1 | `ariane-linux.dts` |
| `g6lc64_smt2` | 1 | 2 | **2** | `ariane-smt2.dts` |
| `g6lc64_stream8` | 2 | 1 | **1** | `ariane-stream8.dts` |

Soft ladder **targets smt2**: dual-issue + dual-thread. FDT walk bugs under DI
block OpenSBI from finishing `fw_platform_init` → `hart_count` stays `0x80`
(ELF default) → `cpuinfo`/HSM never see real topology.

Living G1\* sibling recover is gated `SuperscalarEn && NrHarts>1` — **off** on
stream8. Enabling stream dual-issue (`I=2`, still `T=1`) is a **present-at-npc
/ catalog-keep** class (`CONTRACT.md` §6), not SMT recover. Do not copy smt2
OpenSBI peels onto stream8. `v` / `zve*` stay off `ariane-stream8.dts` unless
a `_v` package sets `RVV=1` (`AGENTS-dts-validation.md`).

---

## 3. OpenSBI FDT walk → `hart_count` → HSM

```text
  Embedded DTB (ariane-smt2.dtb)
        │
        ▼
  fdt_path_offset / fdt_getprop / next_tag  ◄── soft-ladder B1 residual
        │
        ▼
  platform.hart_count = |cpu@ okay|
  platform.hart_index2id[]
        │
        ▼
  coldboot lottery, HSM park secondary, domain, payload
        │
        ▼
  Linux smp_init → /proc/cpuinfo, sched topology from cpu-map
```

| Symptom | Meaning | Soft-ladder link |
|---------|---------|------------------|
| `plat_hc=0x80` | `fw_platform_init` never wrote real count | FDT walk / soft getprop |
| `plat_hc=1` with 2× `cpu@` | Walk truncated / single-hart soft | Partial peel |
| `plat_hc=2`, cookie `51b1babe` | Discovery OK for smt2 | Soft ladder green |
| PEEL_FDT_GETPROP mepc=`0x129f8` | `offset_ptr` load a0=9 (iter-012 live) | B1 open — `COMPLETION.md` G0 |
| historic PEEL mepc=`0x12eb2` | `lenp` store residual (R2 after G0) | B1 after stage 1 |

**Critical:** Soft `fdt_getprop*` → NULL unblocks cookie with **incomplete**
property reads. That can leave platform with stub/default hart topology.
Retiring soft getprop is required before trusting `cpuinfo` under RTL.

---

## 4. `/proc/cpuinfo` contract (what “correct” looks like)

After full OpenSBI + Linux boot with matching DTB and `S` online harts:

| Line / concept | SMT (`N=1,T=2`) | Stream (`N=2,T=1`) | Hybrid (`N=2,T=2`) |
|----------------|-----------------|--------------------|--------------------|
| `processor` lines | 2 | 2 | 4 |
| `hart` | 0, 1 | 0, 1 | 0..3 |
| ISA string | Match `riscv,isa` / extensions | same | same |
| Core siblings | One physical core, 2 threads | Two cores | Two cores × 2 threads |
| `maxcpus=` bootarg | ≥ S | ≥ S | ≥ S |

Gates (lab):

```text
cat /proc/cpuinfo | grep -c '^processor'   # == S
# optional: lscpu / sysfs topology for core_id vs thread
taskset -c 0,1 ...                         # smt2 / stream
```

---

## 5. Soft-ladder sequencing (topology-aware)

Do **not** jump to multi-core topology soaks until DI FDT walk is honest.

```text
Phase A — Soft ladder B1 (current)
  A1. Default cookie green (soft getprop OK)          [x]
  A2. PEEL_FDT_GETPROP natural getprop green          [ ]  COMPLETION.md G0–G1
  A3. Real printf (drop BANR)                         [ ]  COMPLETION.md G2
  A4. Domain / switch_mode peels                      [ ]  COMPLETION.md G4
  A5. plat_hc sticky == 2 on smt2 without soft getprop [ ]  stage 3–4

Phase B — Topology truth (smt2 first)
  B1. OpenSBI stock generic + ariane-smt2.dtb
      hart_count==2, both harts HSM-visible
  B2. R3a dual-hart payload / R3 cosim
  B3. R3b Linux: cpuinfo processor count == 2
  B4. cpu-map SMT siblings (thread0/1 under core0) observed in sysfs if exposed

Phase C — Stream plane (orthogonal)
  C1. Soft-ladder or dual-core residual on g6lc64_stream8 (I=1, N=2, T=1)
  C2. ariane-stream8.dtb: plat_hc==2, cpu-map core0/core1
  C3. Linux cpuinfo: 2 processors, 2 cores, 1 thread each

Phase D — Parameterized generator (optional, tape-out hygiene)
  D1. Generate DTS from (NrCores, NrHarts, IsaCode, cache geom)
      — single template, no hand-synced ariane-{smt2,stream8,...}.dts drift
  D2. validate-cva6-dts for generated product
  D3. Hybrid N×T package only after S≤8 and soft ladder green on smt2+stream
      Core scale + all-feature: `soft-ladder/CONTRACT.md` §8 (union soak;
      recover is per-core, not a cluster port)
```

### B1 residual note (iter-012)

Live PEEL pin: `c.lw@129f8` mcause=4 mtval=9 (`a0` is FDT offset/tag/`strlen`,
not `fdt+offset`). Historic `12eb2` (`s2` = `check_node→next_tag` ra) is R2
after G0. I4x and fdt `c.mv` increment families are **closed** at I4cf. Next
work is `soft-ladder/COMPLETION.md` (one mini with fail-codes, then generic
pointer-liveness), not another register keep. Soft getprop remains the
production default until A2 is green. See `ITERATION.md` and `AGENTS-todo.md`
SL-B.

---

## 6. RTL / codebase adjustment map

### 6.1 Already correct (keep aligned)

| Area | Locus | Rule |
|------|-------|------|
| mhartid base | `g6lc_cluster.sv` | `c * NrHarts` |
| CLINT scale | `ariane_testharness.sv` | `NR_HARTS = N×T` |
| IRQ fan-out | harness + `g6lc_smt_csr_bank` | per global hart index |
| SMT banks | `core/smt/*` | depth `NrHarts` |
| DTS smt2 / stream8 | `corev_apu/bootrom/` | Hand-written shapes above |
| Soft-ladder oracle | `software/smt2-linux/soft-ladder/` | FDT peels only; not topology |

### 6.2 Must stay consistent (triple)

```text
  config_pkg (NrCores, NrHarts, ISA, caches)
       ⇄  DTS (cpu@ count, cpu-map, CLINT/PLIC lists, isa-extensions)
       ⇄  OpenSBI expected_harts / embedded DTB
```

Any change to `N` or `T` without updating **all three** yields:
wrong `plat_hc`, CLINT write to missing slot, or Linux offline CPUs.

### 6.3 Soft-ladder → RTL (FDT path, blocking topology)

| Work | Files | Exit criterion |
|------|-------|----------------|
| Stack spill / STQ / lenp | `store_buffer.sv`, `load_unit.sv`, possibly `issue_*` | `PEEL_FDT_GETPROP` cookie `51b1babe` |
| Directed FDT nest | `verif/tests/custom/multicore/mini_fdt_*.S` | PASS on smt2 DI harness |
| Peel soft getprop | `mk_plat_skip.py` | Default natural getprop |
| Real printf | B1 then B2 | Drop BANR soft |

### 6.4 Topology scale-up (after A5)

| Work | Files | Exit criterion |
|------|-------|----------------|
| Optional DTS generator | `software/smt2-linux/scripts/` or `build-platform` | Emit smt2/stream/hybrid from knobs |
| `check_cfg` / docs for N×T | `config_pkg.sv`, `dts-linux-smt.md` | S≤8 documented |
| Hybrid package (later) | new `g6lc64_*_config_pkg` | Lint + CLINT + mini dual-core+SMT |
| Stream soft ladder (if needed) | separate inventory ids | Stream cookie / Linux path |

### 6.5 Explicit non-goals

- Advertising `NrIssuePorts` in DTS or cpuinfo  
- Faking `cpu@` count higher than real harts  
- Growing `NrHarts` beyond 2 without banked RF/CSR/CLINT plan  
- Using soft FDT stubs as silicon policy once ladder peels them  

---

## 7. Parameter cheat-sheet

| Profile | N | T | S | I | cpu-map | Soft ladder focus |
|---------|---|---|---|---|---------|-------------------|
| linux single | 1 | 1 | 1 | 1 | core0/thread0 | Baseline |
| **smt2** | 1 | 2 | 2 | 2 | core0/{t0,t1} | **Active** DI FDT |
| **stream8** | 2 | 1 | 2 | 1 | core0,core1 / t0 | Multi-core residual |
| hybrid (future) | 2 | 2 | 4 | 1–2 | 2 cores × 2 threads | After smt2+stream green |

---

## 8. Acceptance matrix (working implementation)

| # | Check | smt2 | stream |
|---|--------|------|--------|
| 1 | Soft-ladder default cookie | required | optional |
| 2 | Natural FDT getprop (no soft) | required | required if DI |
| 3 | `plat_hc == S` sticky | 2 | 2 |
| 4 | CLINT IPI both harts | yes | yes |
| 5 | Dual-hart SBI / park | yes | yes |
| 6 | Linux `processor` count | 2 | 2 |
| 7 | cpu-map topology class | SMT siblings | 2 cores |
| 8 | `validate-cva6-dts` FAIL=0 | yes | yes |

---

## 9. Immediate next steps (implementation order)

1. **Close iter-012 FDT lenp** (B1) — natural getprop; keep soft default until green.  
2. **Prove `plat_hc=2`** on smt2 without soft getprop (Phase A5).  
3. **R3 / R3b** dual-hart Linux path; document `/proc/cpuinfo` once.  
4. **Stream plane** residual only after smt2 FDT walk is trusted (same libfdt code).  
5. **DTS generator** when a third topology (hybrid) would otherwise triple-maintain hand DTS.

This document is the topology contract for soft-ladder and Linux bring-up; update
it when `NrHarts` legality or PLIC target caps change.
