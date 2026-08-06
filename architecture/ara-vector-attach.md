# Ara / RVV attach seam (U10ᵇ)

Integration contract for attaching a **RISC-V Vector (RVV 1.0)** unit
([PULP Ara](https://github.com/pulp-platform/ara)) to CVA6V-EC for AVX-like
memcpy/memset and bulk math.

**Status (2026-08):** Ara is **vendored** under `vendor/ara/upstream` with
`Flist.ara` + `cva6_shim/`; SoC glue is `corev_apu/src/g6lc_ara_attach.sv` (live
under `` `define CVA6_ARA_ATTACH ``, else stub) and `g6lc_axi_2to1_mux.sv`. Live
Verilator lint is green for `g6lc64_server_math_v`. Software contract: purpose guide
`agents/guides/AGENTS-vector.md`, DTS `ariane-server-math-v.dts`, directed
`testlist_ara_vector.yaml`. Cosim/VRF **gate**: `software/vector/` + `ara-vector-cosim` (soft path green; live lmul opt-in). Spec status:
`agents/spec/riscv-spec-I-9-vector.html` + `AGENTS-specs-to-impl.md` (Vector / Ara rows).

## Spec / config identity

| Knob | Location | Meaning |
|------|----------|---------|
| `RVV` / `CVA6ConfigVExtEn` | `cva6_cfg_t` / packages | ISA `misa.V`, decode of vector ops |
| `EnableAccelerator` | `build_config_pkg` ← `CVA6Cfg.RVV` | Scoreboard + `acc_dispatcher` path |
| `CvxifEn` | package | **Mutually exclusive** with accelerator (`core/cva6.sv` assert) |
| `NonIdemPotenceEn` | cfg (Ara note in `config_pkg`) | Used by V path for non-idempotent regions |

## Packages

| Package | V | CVXIF | Use |
|---------|---|-------|-----|
| `g6lc64_server_math_config_pkg.sv` | 0 | 1 | Default server/H/CBO math (no vector IP) |
| `g6lc64_server_math_v_config_pkg.sv` | **1** | **0** | Server + RVV when Ara is linked |
| `cv64a6_imafdcv_sv39_config_pkg.sv` | 1 | 0 | Legacy vector-oriented profile |

Select the `_v` package as the active `cva6_config_pkg` only after the flist step below.

## Pipeline seam (existing RTL)

1. Decode / issue treat vector ops as accelerator FU when `RVV` / `EnableAccelerator`.
2. `core/acc_dispatcher.sv` + scoreboard long-latency path.
3. Cache invalidation from accelerator side already ORed with multi-core inv
   (`core/cva6.sv` — Ara/CVXIF inv comment near inv merge).
4. Prefer **not** inventing a second vector datapath inside execute; keep Ara
   behind the accelerator interface.

## Flist / vendor steps (when IP is available)

```
# 1. Vendor Ara (or pin a known-good commit under vendor/ or build-platform vendor)
# 2. Add Ara + deps to the target flist (Verilator / VCS / synth)
# 3. Wire Ara AXI/memory port to SoC xbar or tightly-coupled SRAM in corev_apu
# 4. Switch package to g6lc64_server_math_v_config_pkg (RVV=1, CvxifEn=0)
# 5. Linux: use corev_apu/bootrom/ariane-server-math-v.dts ("v" token);
#    OpenSBI VRF/context switch (see agents/guides/AGENTS-vector.md §5)
# 6. Directed: verif/tests/testlist_ara_vector.yaml + compliance vector suite
```

Suggested flist fragment location (create when IP lands):

```
core/Flist.cva6          # already lists core; do not hardcode Ara paths here
vendor/ara/...           # git-ignored or vendored — not committed if NDA
# or build-platform flist append:
#   +vendor/ara/src/ara_dispatcher.sv
#   +vendor/ara/src/ara.sv
#   ...
```

## SoC readiness notes

- **Timing**: vector unit is a placement island; separate clock-gate/power region.
- **DFT**: propagate `test_en_i` / `testmode_i` through Ara wrapper.
- **Observability**: RVFI may need accelerator retire hooks; PMU event for V busy.
- **`.dts`**: keep `riscv,isa-extensions` aligned with package (`v`, `h`, `sstc`, …).

## Status

| Item | Status |
|------|--------|
| Config scaffold (`_v` package) | **Done** |
| Accelerator seam in core | Pre-existing |
| Vendor drop-in + flist example | **Done** — `vendor/ara/README.md`, `Flist.ara.example` |
| Catalog / code-agent | **Done** — `agents/vendor/AGENTS-vendor-ara.md`, catalog id `ara` |
| `vendor sync ara` | **Done** — tree at `vendor/ara/upstream/` |
| `vendor/ara/Flist.ara` | **Done** (src + lane/masku/sldu/vlsu; no TB) |
| Append flist to sim/synth top | **Done (opt-in)** — `verify.extraFlistsByTarget.g6lc64_server_math_v` → `vendor/ara/Flist.ara` |
| Lint `g6lc64_server_math_v` | **PASS** — top `g6lc_ara_lint_top` → **ariane** EnableAccelerator path + attach |
| SoC glue | **Done** — `g6lc_ara_attach` + `ariane` gen_acc (typed intf, optional AXI dwc+mux) |
| Live Ara IP (`CVA6_ARA_ATTACH=1`) | **PASS (Verilator)** — deps on Flist.ara; `cva6_shim/vmfpu`+`lane_sequencer`+`vlsu` for OpenHW cvfpu / pulp axi; slang skipped |
| Purpose guide | **Done** — `agents/guides/AGENTS-vector.md` |
| Linux DTS (`v` token) | **Done** — `corev_apu/bootrom/ariane-server-math-v.dts` (only for `_v` package) |
| Linux/SBI vector context | **Partial** — DTS + `software/vector/opensbi-vrf.md` + `linux.config-fragment`; full SBI/kernel lab |
| Directed vector memcpy | **Done (directed)** — `v_memcpy_skip` / `v_misa_v` / `v_memcpy_lmul` + `testlist_ara_vector.yaml`; functional LMUL needs live Ara cosim |

### Live Ara IP (operator)

```bash
# Typed RVV attach path (stub Ara — default):
cva6-build verify --lint --target g6lc64_server_math_v

# Full live Ara RTL (Verilator gate; shims under vendor/ara/cva6_shim/):
# Windows PowerShell:
$env:CVA6_ARA_ATTACH = "1"
cva6-build verify --lint --target g6lc64_server_math_v
# Unix:
CVA6_ARA_ATTACH=1 cva6-build verify --lint --target g6lc64_server_math_v
```

Shims (CVA6 OpenHW cvfpu / current pulp AXI):
- `vendor/ara/cva6_shim/vmfpu.sv` — 5 formats / 4 opgroups, no `hart_id_i`
- `vendor/ara/cva6_shim/lane_sequencer.sv` — enum-safe assignment patterns
- `vendor/ara/cva6_shim/vlsu.sv` — `axi_cut` `.req_t`/`.resp_t` names

Cluster already instantiates `ariane`; with `RVV=1` / `EnableAccelerator` the attach path
elaborates. Live IP needs `CVA6_ARA_ATTACH` + Ara on the flist.
