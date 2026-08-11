# SMT2 × ai-tensor / PyTorch — multi-thread Linux test track

Cross-map of **dual-hart soft-ladder/OpenSBI/Linux bring-up** with the **ai-tensor** host
backend (PyTorch / virt-ai-pcie / HARD RTL). Goal: once FDT topology is trusted under DI
(`soft-ladder` SL-A/B → SL-C), multi-threading is exercised not only by `cpuinfo`/`stress-ng`
but by **parallel tensor work** on the AI card/island.

| Layer | Artifact | Role |
|-------|----------|------|
| Soft-ladder DI residual | `architecture/multi-threading/soft-ladder/` | B1 RTL so OpenSBI FDT / `plat_hc` is honest under `g6lc64_smt2` |
| SMT topology | `fdt-topology-soft-ladder.md` | `S = NrCores × NrHarts`; smt2 = 1×2 |
| Linux/OpenSBI | `smt2-bringup.md`, `software/smt2-linux/` | Dual-hart boot, R3/R3b |
| AI host | `ai-tensor/` · `cva6-build tensor` | PyTorch + soft/HARD virt-impl |
| Board / UIO | `virt-ai-pcie`, `ariane-ai.dts`, board-uio-eventfd | Linux userspace doorbell path |
| **Fast track driver** | `verif/regress/smt2-ai-tensor-track.sh` · suite `smt2-ai-tensor-track` | Staged profiles for iteration speed |

**Branch of record for this track:** `smt2-ai-tensor-linux` (from `E:\cva6` master).

### AI attunement (one paragraph)

SMT2 attunes to AI by guaranteeing **two trustworthy software harts** and **per-hart AI
CSR banks**, then exercising the **same** ai-tensor ABI (virt-card soft → HARD narrow) under
dual-CPU affinity once Linux is up. Island GEMM/CPL/queues are shared SoC resources;
attunement does **not** mean “two copies of the island,” it means concurrent host
submission and multi-queue isolation without OpenSBI/FDT corruption under DI.

Do **not** treat PyTorch success on a single-hart package as SMT2 green.

---

## 0. Iteration-speed contract (read first)

Development loops must stay on the **narrowest plane that can fail for the change under test**.

| Rule | Meaning |
|------|---------|
| **Default = `fast`** | Paths + dual-hart artifacts + soft-ladder **COMPILE_ONLY** — seconds, no Verilator run |
| **Never rebuild by default** | `SMT2_REBUILD=0`; use prebuilt `work-ver-smt2-slfix` / `fw64` / `smt2` |
| **Reuse OpenSBI ELF** | `SOFT_LADDER_SKIP_BUILD=1` for hold/peel when `build/` exists |
| **Short sim budgets** | di: `SOFT_LADDER_MAX_CYCLES=80000`; hold/peel: 2–3e6 cycles (not 12e6) |
| **FDT-first mini set** | di defaults to FDT shape minis (+ dual_cmv), not full history suite |
| **Skip R3 Linux by default** | `DUAL_HART_SKIP_R3=1` / `SMT2_SKIP_R3=1` |
| **HARD = narrow only** | Never `peak`/`full` in the iteration track |
| **Tensor soft before HARD** | Host pytorch without Variane |
| **Climb only on failure class** | See isolation table below |

### Isolation ladder (narrow → wide)

```text
fast     paths + dual-hart artifacts + assemble soft-ladder minis     [seconds]
  ↓
di       soft-ladder-di FDT subset on prebuilt harness                [minutes]
  ↓
hold     soft-ladder-osbi cookie (soft getprop holding)               [long sim]
  ↓
peel     PEEL_FDT_GETPROP=1 (SL-A only)                               [long sim]
  ↓
dual     dual-hart-ci (+ optional LIVE dual-park)                     [minutes+]
  ↓
tensor   tensor pytorch soft (virt-ai-pcie)                           [host]
  ↓
mt-soft  dual sequential pytorch invoke (T5 stand-in)                 [host]
  ↓
hard     tensor virt-impl --impl hard --suite narrow                  [RTL HARD]
```

---

## 1. Staged gates (T0–T6) ↔ profiles

| Stage | Profile | Prerequisite | Command | Budget |
|------:|---------|--------------|---------|--------|
| **T0a** | `fast` | — | `bash verif/regress/smt2-ai-tensor-track.sh` | seconds |
| **T0b** | `di` | harness optional | `…/smt2-ai-tensor-track.sh di` | minutes |
| **T0** | `hold` | harness + oracle ELF | `… hold` | long |
| **T1** | `peel` | iter-012 RTL harness | `… peel` | long |
| **T2–T3** | `dual` | packages/DTS | `… dual` (`DUAL_HART_LIVE=1` for Variane) | minutes+ |
| **T4** | `tensor` | bun + ai-tensor | `… tensor` | host |
| **T5** | `mt-soft` | T4 green | `… mt-soft` | host |
| **T6** | `hard` | HARD suite | `… hard` | RTL |
| compose | `full` | — | di + hold + dual + tensor (**no** peel/hard/rebuild) | long |

Suite id: **`smt2-ai-tensor-track`** (`optional: true`, not `defaultSuites`).

```text
# Preferred entry
bash verif/regress/smt2-ai-tensor-track.sh              # = fast
bash verif/regress/smt2-ai-tensor-track.sh di
SMT2_TRACK=hold bash verif/regress/smt2-ai-tensor-track.sh

# Host catalog
bun build-platform/src/cli/index.ts test smt2-ai-tensor-track
bun build-platform/src/cli/index.ts diag run diag-smt2-ai-tensor-track
```

### Env knobs (speed)

| Knob | Default | Purpose |
|------|---------|---------|
| `SMT2_TRACK` / `$1` | `fast` | Profile |
| `SOFT_LADDER_HARNESS` | auto: slfix→fw64→smt2 | Prebuilt Variane dir |
| `SOFT_LADDER_SKIP_BUILD` | `1` (hold/peel) | Reuse patched OpenSBI ELF |
| `SOFT_LADDER_MAX_CYCLES` | `80000` (di) | Mini sim budget |
| `SOFT_LADDER_TIME_OUT` | `3e6` hold / `2e6` peel | OpenSBI soak budget |
| `SOFT_LADDER_TESTS` | FDT shape subset | Override di list |
| `DUAL_HART_LIVE` | `0` | Variane dual-park |
| `DUAL_HART_SKIP_R3` | `1` | Skip Linux Image cosim |
| `SMT2_REBUILD` | `0` | `make verilate … work-ver-smt2-slfix` |
| `SMT2_TENSOR_BOARD` | `virt-ai-pcie` | tensor host board |
| `SMT2_TENSOR_CORE` | `g6lc64_ai` | tensor core package |
| `SMT2_REQUIRE_ALL` | `0` | Treat skips as fail |

---

## 2. Why this coupling

1. **Soft-ladder SL-C** is the gate for “two software harts are real” (`plat_hc==2`, `/proc/cpuinfo`).
2. **ai-tensor** already has soft pytorch and HARD narrow virt-impl.
3. Multi-threading is only proven for AI if **two Linux CPUs** can drive concurrent host
   workers without OpenSBI/FDT corruption under DI.

---

## 3. SMT RTL invariants (must not regress for AI)

| Mechanism | File | Rule |
|-----------|------|------|
| Younger cancel | `core/scoreboard.sv` | Same-hart only when `NrHarts>1`; DI cancels LOADs under `SuperscalarEn` (iter-012) |
| CF / CSR / SP issue stalls | `core/issue_stage.sv` | **Per-hart** — peer thread keeps issuing |
| Banked RF | `g6lc_smt_regfile` | Commit `whart` never hardwired 0 |
| Banked CSR + AI sideband | `g6lc_smt_csr_bank` | `ai_aicfg`/`ai_ais` mux by **active** hart; dirty/setcfg gated to **commit** hart |

AI island MMIO / DMA is a **SoC** resource; concurrent hart access uses island queue isolation
(`isa-encoding.md` §7.1), not shared CSR banks.

---

## 4. Feature checklist for a Linux build (when leaving `fast`)

Only enable when the corresponding stage is green:

| Feature | Package / config | Needed for |
|---------|------------------|------------|
| `NrHarts=2`, SMT_HYBRID | `g6lc64_smt2` | dual software harts |
| DI + FETCH_WIDTH≥64 | smt2 + fw64/slfix harness | soft-ladder DI residual |
| Soft-ladder iter-012 RTL | scoreboard LOAD cancel + sp barrier | PEEL FDT / honest topology |
| Dual-hart DTS | `ariane-smt2.dts` | OpenSBI/Linux topology |
| R3b Image (lab) | `CVA6_LINUX_PAYLOAD` / external Image | real `/proc/cpuinfo` |
| AI island / card | `g6lc64_ai` + island or virt-ai-pcie soft | tensor path |
| UIO/eventfd | board package / driver | Linux userspace doorbell |
| PyTorch soft | `ai-tensor` + `tensor pytorch` | T4 without RTL |

**Dev default package for residual:** `g6lc64_smt2` + prebuilt harness.  
**Dev default for tensor soft:** `g6lc64_ai` + `virt-ai-pcie` (no smt2 required until T5 on real dual-hart Linux).

---

## 5. Suggested loops

### Daily residual (seconds)

```text
bash verif/regress/smt2-ai-tensor-track.sh fast
```

### After RTL touch to issue/scoreboard/SMT (minutes)

```text
bash verif/regress/smt2-ai-tensor-track.sh di
# if harness missing: SOFT_LADDER_COMPILE_ONLY stays forced; schedule rebuild offline
```

### Soft-ladder hold / peel (long; after harness rebuild)

```text
SOFT_LADDER_HARNESS=work-ver-smt2-slfix bash verif/regress/smt2-ai-tensor-track.sh hold
SOFT_LADDER_HARNESS=work-ver-smt2-slfix bash verif/regress/smt2-ai-tensor-track.sh peel
```

### Tensor soft (host, parallelizable with residual)

```text
bash verif/regress/smt2-ai-tensor-track.sh tensor
bash verif/regress/smt2-ai-tensor-track.sh mt-soft
```

### Offline rebuild (do not block edit loop)

```text
SMT2_REBUILD=1 bash verif/regress/smt2-ai-tensor-track.sh paths
# or: make verilate target=g6lc64_smt2 ver-library=work-ver-smt2-slfix XLEN=64
```

---

## 6. Status (branch `smt2-ai-tensor-linux`)

| Item | State |
|------|--------|
| Soft-ladder P0 suites | Done |
| Fast track driver | **`smt2-ai-tensor-track.sh`** — `fast` 21/0; `di` FDT minis **5/5 PASS** |
| Tensor soft (T4) | **PASS** `tensor pytorch` Device virt-card (torch optional; 2 tests) |
| AI CSR SMT banking | **Landed** in `g6lc_smt_csr_bank` (active-hart mux / commit-hart gate) |
| iter-012 harness | **`work-ver-smt2-slfix`** live (banked TB CSR probes) |
| Hold (T0) on slfix | **Holding cookie green** (`SOFT_HART_INIT`+`SOFT_PLAT_OPS` → **`51b1babe`**, `plat_hc=2`, BANR). Stock still red: hart_init CSR probes + platform jalr→FDT. `coldboot_done` is early (pre-hart_init). |
| Oracle ELF | **Pin** md5 `bc7ed11dab17454fd147e4927ba07fef`. **Held** `fw_payload_r3a_c15_plat_skip.held.elf`. `SOFT_LADDER_SKIP_BUILD=1`; optional `SOFT_LADDER_ELF=…held.elf`. |
| fw64 hold bisect | Good ELF @8e6 on pre-iter-012 `fw64` → PEEL pin mepc=`0x12eb2` mcause=6. |
| PEEL (T1) | Pending cookie green on stock (or held) path |
| Dual-hart Linux + dual pytorch workers | **Not started** — blocked on hold cookie + SL-C + Image |

### Package / board attunement

| Use case | Package | Board / harness | Notes |
|----------|---------|-----------------|-------|
| DI residual / soft-ladder | `g6lc64_smt2` | `work-ver-smt2-slfix` (prefer) | FETCH_WIDTH≥64; banked CSR TB; hold/cookie plane |
| PEEL pin reference | `g6lc64_smt2` | `work-ver-smt2-fw64` | pre-iter-012; FDT pin still red |
| Tensor soft / HARD narrow | `g6lc64_ai` | `virt-ai-pcie` / `work-ver-ai` | NrHarts=1 today; not SMT proof |
| Future dual-hart + AI Linux | TBD hybrid / smt2+island board | ariane-smt2 + AI DTS | After SL-C |

### Lab notes (2026-08-11)

```text
bash verif/regress/smt2-ai-tensor-track.sh fast     # green
bash verif/regress/smt2-ai-tensor-track.sh di       # 5/5 FDT minis green
cva6-build tensor pytorch --board virt-ai-pcie --core g6lc64_ai  # green (Device)
# hold (restored good oracle; do NOT cold rebuild):
SOFT_LADDER_HARNESS=work-ver-smt2-slfix SOFT_LADDER_SKIP_BUILD=1 \
  SOFT_LADDER_TIME_OUT=8000000 bash verif/regress/smt2-ai-tensor-track.sh hold
# → plat_hc=2 coldboot_done=1; cookie miss; hang _start_warm / mcause=2
```

**Holding cookie:** `SOFT_HART_INIT=1` (implies `SOFT_PLAT_OPS`) when rebuilding oracle, or use `…/build/fw_payload_r3a_c15_plat_skip.held.elf`.  
**Stock residual:** peel hart_init CSR + platform ops fn-ptrs (irqchip/ipi/timer/tlb) without soft peels.

Update `AGENTS-todo.md` SL-T when T5 first greened on real dual-hart Linux.
