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

## Why this coupling

1. **Soft-ladder SL-C** is the gate for “two software harts are real” (`plat_hc==2`, `/proc/cpuinfo`).
2. **ai-tensor P6 / pytorch** already has a **soft** path (`tensor pytorch --board virt-ai-pcie`)
   and a **HARD** path (`tensor virt-impl --impl hard --suite narrow`).
3. Multi-threading is only proven for AI if **two Linux CPUs** can drive concurrent host
   workers (or concurrent island queues) without corrupting FDT/OpenSBI under DI.

Do **not** treat PyTorch success on a single-hart package as SMT2 green.

## Staged gates

| Stage | Prerequisite | Command / check |
|------:|--------------|-----------------|
| **T0** | Soft-ladder holding | `soft-ladder-osbi` cookie `51b1babe` (soft getprop OK) |
| **T1** | SL-A PEEL | `PEEL_FDT_GETPROP=1` no longer traps at `0x12eb2`; rebuild harness with iter-012 RTL |
| **T2** | SL-B/C | Natural getprop; `plat_hc==2`; R3/R3b dual-hart |
| **T3** | Linux `maxcpus=2` | `cat /proc/cpuinfo` → 2 processors; `taskset -c 0,1` |
| **T4** | ai-tensor soft | `cva6-build tensor pytorch --board virt-ai-pcie --core g6lc64_ai` (or smt2-class board when profiled) |
| **T5** | Multi-thread host | Two processes/threads with `taskset` 0 and 1 submitting GEMM / eventfd waits |
| **T6** | HARD optional | `tensor virt-impl --impl hard --suite narrow` under dual-hart DTS if/when island + smt2 SoC share a board package |

## SMT RTL invariants (must not regress for AI)

| Mechanism | File | Rule |
|-----------|------|------|
| Younger cancel | `core/scoreboard.sv` | Same-hart only when `NrHarts>1`; DI cancels LOADs under `SuperscalarEn` (iter-012) |
| CF / CSR / SP issue stalls | `core/issue_stage.sv` | **Per-hart** — peer thread keeps issuing |
| Banked RF | `g6lc_smt_regfile` | Commit `whart` never hardwired 0 |
| Banked CSR + AI sideband | `g6lc_smt_csr_bank` | `ai_aicfg`/`ai_ais` mux by **active** hart; dirty/setcfg gated to **commit** hart |

AI island MMIO / DMA is a **SoC** resource; concurrent hart access must use the island’s queue
isolation (descriptor flags / QoS in `isa-encoding.md` §7.1), not shared CSR banks.

## Suggested lab loop (after T1 rebuild)

```text
# Soft-ladder residual (DI OpenSBI)
SOFT_LADDER_HARNESS=work-ver-smt2-slfix bash verif/regress/soft-ladder-opensbi-soak.sh
PEEL_FDT_GETPROP=1 SOFT_LADDER_HARNESS=work-ver-smt2-slfix bash verif/regress/soft-ladder-opensbi-soak.sh

# Dual-hart Linux path (external Image when available)
# verif/regress/smt-linux-rootfs.sh / r3b-linux-image

# ai-tensor soft pytorch (host)
cva6-build tensor pytorch --board virt-ai-pcie --core g6lc64_ai
cva6-build tensor virt-impl --impl hard --suite narrow --require-hard
```

## Status

| Item | State |
|------|--------|
| Soft-ladder P0 suites | Done |
| iter-012 RTL (LOAD cancel DI + sp barrier) | **Landed on master** (soak pending rebuild) |
| SMT AI CSR bank sideband | **Landed** (AI-1 / live green path) |
| Soft pytorch suite | **Live** (`e509428d4` / HARD maps) |
| Dual-hart Linux + dual pytorch workers | **Not started** — blocked on SL-A PEEL + SL-C |

Update `AGENTS-todo.md` SL-T and AI-S3 when T5 first greened.
