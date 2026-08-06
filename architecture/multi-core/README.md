# Extension point: multi-core (1…8)

**U6.2.** Shared L2 (U6.0) in `../../corev_apu/l2_cache/`. Cluster size is
`cva6_cfg_t.NrCores` ∈ {1..`CVA6_MAX_CORES`} (default max **8**; override with
`` `define CVA6_MAX_CORES N ``). SMT threads **per core** remain `NrHarts` ≤ 2.

Guides: `../../agents/guides/AGENTS-l2l3-cache.md`, `../../agents/guides/AGENTS-soc-readiness.md`.
Sequence: `../remaining-upgrade-sequence.md`.

## Intent
N coherent CVA6 cores: shared LLC, write-invalidate coherence, scaled CLINT/PLIC,
unique `mhartid`, SMP Linux. Not dual-only — **parameterized 2–8**.

## Current state
| Item | Status |
|------|--------|
| Shared L2 (U6.0) | `corev_apu/l2_cache/` |
| L3 + stream PF | `corev_apu/l3_cache/` + `g6lc_server_prefetcher` (ooo_server / server_math PF) |
| Inclusive L3→L2/L1 | **Live** — L2 `l2_back_inval_*` + L1 `g6lc_l3_inclusive_inv`; TB `INCLUSIVE_L3=L3En` |
| `NrCores` 1…8 | **Live** in `config_pkg` / packages (default 1) |
| Snoop filter / inv bus / hub | **Live** under `corev_apu/coherence/` |
| SoC N-core wrapper | **`corev_apu/src/g6lc_cluster.sv`** (N×ariane + hub + L2/L3/PF) |
| L1 inv adapter | **`g6lc_l1_inv_adapter.sv`** + core `l1_inval_*` → **WT and HPDCACHE** |
| Testharness | **`ariane_testharness`** uses cluster + CLINT `NR_CORES=NrCores` |
| CLINT | Scaled to `NrCores` |
| PLIC | Multi-context 16 targets (8×M/S) |
| Tests | **`mc-stream-tests`** + **`mc-spo-soak`** (stream × Zacas/spo/CF narrow); `dual-hart-ci`, `ooo-l3-tests` |
| Zacas (AMOCAS) | **W/D/Q** — `RVZacas` on server_math / ooo_server / imafdc; hard golden `zacas-policy` + `mc-mini-veri`; suite under `verif/tests/custom/multicore/` |
| Spo/CF soak | **`mc-spo-soak`**: multi-round assemble + dual-target lint; CF×stream, CAS×stream, mispred×stream |

## Contention optimisations
Snoop filter · inv coalesce · multi-master AXI RR + anti-starve · NC bypass · N=1 identity.

## Sanctioned seam
Cluster size at **SoC** (`corev_apu`); core stays single-hart-instance + `mhartid`.
Hub sits between core AXI masters and shared L2.

## `.dts`
N× `cpu@`, PLIC contexts, CLINT extents, `next-level-cache = <&l2>`.

## Invariants
RVWMO across harts · cluster-wide LR/SC+AMO · MMIO never cached · precise traps per hart.
