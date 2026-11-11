# CPU51 — C0 exit: gate-level proof + pinned strict diagnostics

Scope: verification-only closure of the C0 exit criterion — a full-core
gate-level SCC/latch proof (`core-scc`) plus a strict full-CPU Verilator
`UNOPTFLAT` diagnostic (`cpu-strict-pins`) whose residual identities are
pinned by name against that proof. **No production RTL under `core/`,
`corev_apu/`, or `g6lc_storamic/rtl/` was modified. No `UNOPTFLAT`/warning
suppression flags, no `-Wno-UNOPTFLAT`, no FP disabling.** All tool runs are
on the remote testharness (`ovh_calltorch`) through `run_remote.py` with the
owned Verilator runtime (`storamic-tools35-8e064f51`, runtime header sha256
`e900ec451629715860e4faffdce5127f5f118ddcaa433125b79f12d3cbb718f8`) and the
owned Yosys (`storamic-sigmap-repair-20-r3/owned-install/bin/yosys`, sha256
`c2e67033f6e0d864b7ec56907a8b73175d5e9c432e6d7033562b62e5dc660bcd`, the same
binary CPU41 used).

Local Python suite: **179 tests, all OK** (`python -m unittest discover`,
`verif/tb/storamic`).

## What was added (all verification-side)

- `run_core_scc.py` — whole-`cva6` gate-level SCC/latch stage (Yosys-only).
  Reconstructs the cpu-origin source tree under `g6lc_core_scc_top.sv`
  (OriginEnabled=1, cv64a6 config, all 48 `cva6` ports tied off), runs
  `read_slang → hierarchy -check → proc → flatten → techmap → scc`, and
  asserts zero latches via `select -assert-none t:$dlatch t:$_DLATCH_*`.
  Requires `SCC=0`, `latches=0`, `pass=true`; writes `core-scc-result.json`
  plus `manifest["core_scc"]` with the source-manifest hash.
- `run_cpu_strict_pins.py` — strict diagnostic stage. Reproduces the
  CPU45/46 flow on the cpu-origin closure in both origin modes
  (`-GOriginEnabled=0/1 -GIntegerDiagnostic=0`) and both diagnostic
  representations, parses every `UNOPTFLAT` into a verbatim hierarchical
  identity, and evaluates it against `cpu_strict_pins.json`.
- `cpu_strict_pins.json` — the pinned identity sets (below), each with a
  `basis` field referencing the `core-scc` proof.
- `cpu_strict_fields.vlt` — the frozen `fields` diagnostic controls
  (identical to CPU46's `diagnostic.vlt`).
- `g6lc_strict_pins_canary.sv` + `g6lc_core_scc_top.sv` — testbench-side
  wrapper/canary; the canary instantiates the real core and adds a
  deliberately looped `g6lc_strict_pins_canary_comb`.
- `test_cpu_strict_pins.py`, `test_run_remote.py` — unit tests.
- Registered `cpu-strict-pins` (simulation stage) and `core-scc`
  (non-simulation stage) in `run_remote.py`/`run_leaf.py`, with source
  collection for the CPU closure, wrapper, canary, pins, controls, and both
  runners.

## Strict diagnostic options (exact, per variant — recorded in the manifest)

Base (both variants): `--lint-only --timing --assert --threads 1 -Wno-fatal
-Werror-LATCH -Werror-UNOPTFLAT -Werror-PINMISSING --error-limit 0` plus the
runtime `--unroll-count 256 --unroll-stmts 131072`. The `lint_(off|on)
(UNOPTFLAT|LATCH)` comment waivers are stripped before compile so no warning
class is suppressed. Generics: `-GOriginEnabled={0,1} -GIntegerDiagnostic=0`.

- `fields`: control file `cpu_strict_fields.vlt` (frozen CPU46
  `diagnostic.vlt`). Baseline **4** UNOPTFLAT identities.
- `fp`: inline `split_var -module "fpnew_*" -var "*_pipe_*_q"` (FP-controls
  only). Baseline **21** UNOPTFLAT identities.

## HEAD re-baseline vs CPU46

Counts are unchanged (fields 4, fp 21, both origins). The only identity
difference vs the CPU46 archive (`storamic-cpu46core-f62bf710`) is the
I-cache `dreq_o` bit index `366 → 365`, caused by the ready-field split
documented in `cpu-icache-ready-interface.md`. Pins were re-baselined to the
observed HEAD set rather than copied blindly.

## Pinned identities (`cpu_strict_pins.json`)

`fields` origin0 = origin1 (4 each):
`cpu.csr_regfile_i.gen_single.i_csr.update_access_exception`,
`cpu.ex_stage_i.lsu_i.__Vcellout__i_load_unit__req_port_o`,
`cpu.flush_ctrl_id`,
`cpu.gen_cache_wt.i_cache_subsystem.i_g6lc_icache.dreq_o[365]`.

`fp` origin0 = origin1 (21 each): the four `fields` identities plus 17
FP-new/fpnew-pipe, lsu `ldbuf` lzc, wt_dcache forward-lane/arbiter/wbuffer,
and frontend tage-lzc identities (full list in `cpu_strict_pins.json`).

## Verdict semantics

PASS iff the observed identity set ⊆ the pinned set per variant+origin and no
other warning class the strict flow treats as an error appears. An unpinned
identity fails and is named; a pinned identity that disappears passes but is
reported `stale-pin` (pins may only shrink). `cpu-strict-pins` is `incomplete`
unless `core-scc` passed (`SCC=0`, `latches=0`) on the identical source
manifest (`sources_sha256` match).

## Negative oracles

- **Canary:** `g6lc_strict_pins_canary` injected under
  `g6lc_strict_pins_canary_top` produces an unpinned
  `…g6lc_strict_pins_canary_comb` identity → the diagnostic fails naming the
  canary. Verified.
- **CSR mutant:** reverting the `csr_regfile` mask/`DirVecOnly` fix is the
  existing `csr-scc` admission-mutant; `core-scc`/`csr-scc` fail on it.

## Runs

- `storamic-14027ce366ba` — first discovery run; exposed a `NameError`
  (`canary_hits`) and a false-positive canary prefix match (fixed by renaming
  the looped signal to `…_comb` and matching non-CPU-prefix identities).
  Non-qualifying history.
- `storamic-d3f6c13851a6` — `cpu-strict-pins` alone: all four diagnostics
  (fields/fp × origin0/1) pass against the HEAD pins, canary names the loop,
  correctly `incomplete` without `core-scc`. Item-level evidence.
- `storamic-2dd777a4bea5` — coupled attempt aborted at launch: a wrong
  `--yosys` path (`toolchains/yosys-g6lc`, which does not exist on the
  host). Non-qualifying history.
- **`storamic-57367da76c0c` — QUALIFYING coupled run** `cpu-strict-pins,
  core-scc` on a frozen snapshot, `--timeout 5400`. `run_remote.py` exited
  **0**: remote `py rc=0` (2123.8 s), auto-pull `rc=0`, and the post-run
  source/stage identity check passed before `Storamic selected stages
  passed` → `leaf-result.json`. `leaf-result.json`: `status: pass`,
  `error: none`; `run_leaf.log` ends `STORAMIC_REMOTE_SELECTED_STAGES_PASS`.

### `storamic-57367da76c0c` results

- **`core-scc`**: `sccs=0`, `latches=0`, `rc=0`, `pass=true`, 2111 s, on
  `g6lc_core_scc_top` (OriginEnabled=1, 264 files). `sources_sha256`
  `76c5212981b4a1ae9339720033f9c1eb3800c58166bafb2364425509332429fe`;
  yosys `c2e67033…` (owned-install).
- **`cpu-strict-pins`**: `verdict: pass`, `core_scc_coupled: true` (its
  `sources_sha256` equals core-scc's — identical source manifest). All four
  diagnostics pass with `observed == pinned`, `stale_pins: []`,
  `other_errors: []`: fields-origin0/1 (4/4), fp-origin0/1 (21/21). The
  `rc:1` on each diagnostic is the expected `-Werror-UNOPTFLAT` signal (the
  warnings fired and were parsed), not a failure.
- **Canary oracle**: `pass`, `canary_hits`
  `["g6lc_strict_pins_canary_top.canary.g6lc_strict_pins_canary_comb"]` —
  the deliberately looped canary is named.
- **CSR-mutant oracle**: the `csr_regfile` mask/`DirVecOnly` revert remains
  the existing `csr-scc` admission-mutant (unchanged); `core-scc`/`csr-scc`
  fail on it.

C0 is therefore closed under the pinned-diagnostic rule: the gate-level
proof reports zero combinational SCCs and zero latches on the full core, and
every residual `UNOPTFLAT` identity the strict compile still reports is
pinned by name against that proof — a new identity would fail, a disappeared
one is only a `stale-pin`.
