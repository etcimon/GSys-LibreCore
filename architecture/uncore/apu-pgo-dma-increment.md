# APU Compiler PGO, Unroll And DMA Boundary Increment

Compiler-PGO and DMA-boundary implementation is validated locally. No new
remote execution or simulation-throughput claim. The later simulator-PGO
increment turns generated simulator PGO ON; its current policy/evidence is in
`apu-simulator-pgo-implementation.md`.

## Current Request And Boundaries

User: ensure testharness Verilator build uses loop unroll and PGO, then continue
implementation. Preserve user's ongoing Storamic checkpoint controller RTL
and bench changes. No network access or shared cleanup has been performed.
This increment changes T tooling/model code, not functional device RTL.

## Implemented

- New `verif/tb/apu/apu_vlt_policy.py`: fixed bounded unroll 256 iterations /
  131072 statements, --stats; shared recipe ID hashes policy, PGO builder,
  wrapper and fixed training SV. `pgo.json` validation requires profile-use,
  matching source/recipe/binary hash, profiles, both training thread modes and
  positive measured unrolled-loop counts.
- New `apu_verilator_pgo.py`: fresh retained private build attempt, GCC-only
  two-pass build, same object paths, force rebuild via make -B (no clean).
  Ccache explicitly disabled, including recursive make OBJCACHE=.
  Fixed full --cc training (not lint) in threads 1 and 2, 60s per training run.
  Requires gcda data for Verilator/V3Unroll/V3Order/V3SplitVar. Captures actual
  wrapper profile-use invocations and final binary SHA. No fallback on failure.
  Parent timeout SIGTERM triggers cleanup of only its own child process group.
- New `verilator-pgo-cxx.sh`: GCC wrapper switches generate/use in same build
  tree. Skips conftest so configure profiles do not pollute compiler data.
  Coverage mismatch is fatal; missing-profile warnings are retained/reported.
- New `vlt_pgo_train.sv`: MIT verification-only standalone loop/split workload.
  It is not functional APU RTL and does not represent qualification.
- `local-verilator.sh`: PGO required by default; strict receipt needed for a
  warm cache. Explicit APU_VERILATOR_PGO=0 is only local opt-out, reported
  unverified. This preserves old plain local cache for compile-only diagnostics.
  New flags helper sets actual fork environment overrides (including narrow
  rolling off) and emits common CLI flags. 3 build and 3 run scripts carry the
  CLI flags too. Toolchain.txt includes unroll limits and actual PGO receipt;
  the original compiler-only increment left generated simulator PGO off.
  This is superseded by `apu-simulator-pgo-implementation.md`.
- `testharness_proxy.py`: all APU RTL leaf stages (dev/unit/top/soc/bridge/guest)
  now provision repository compiler, not just dev. Compiler-only source digest
  and PGO recipe digest key the cache. Four policy/training files must exist
  in snapshot. APU_VERILATOR_PGO=1 is internal and not user-env allowlisted.
- `run-apu-regress.sh`: when snapshot tool source ID is supplied, ensure and
  record compiler before capturing source manifest and executing any suites.
  Missing/failed setup blocks with exit3, no false PASS.
- New `corev_apu/apu/tools/vn_dma.py`: initially deny-all DmaPolicy, immutable
  nonoverlapping grants, exact revocation, read/write distinction, u64 bounds,
  validation of the entire transfer before mutation, adjacent grants support.
  GuestDma facade wraps SparseMemory. Caller serializes mapping/access.
- ApertureState and TransportModel accept optional dma_policy. Explicit policy
  gates DMA byte methods and stream gmem_slice (strict word alignment there).
  Legacy None preserves generator behavior. Raw dictionaries are trusted
  fixture/device-state interfaces, NOT protected guest APIs. Bridge lifecycle
  registration, DMA error translation and complete backend remain pending.

## Validation Already Done

Background shell `13f4a3` FINISHED PASS:
- 23 harness/policy tests in 4.440s (fake tools, no C++ compiler build).
- 31 model tests in 0.035s, including eight new DMA cases.
- 38 scoped proxy/manifest/gate tests in 8.048s.
No full proxy rerun (previous broad run had six unrelated fixture failures).

## Real Cold Compiler Validation

Reproduction:
```
APU_VERILATOR_HOME=$HOME/.cache/librecore/apu-verilator-pgo-v1
APU_VERILATOR_PGO=1 APU_BUILD_JOBS=4
timeout --kill-after=10 1200 bash verif/tb/apu/local-verilator.sh
```
WSL source `/mnt/e/cva6`, no downloads/elevation. Actual attempt:
`/root/.cache/librecore/apu-verilator-pgo-v1/pgo-build-bhv5zz96/`.
Generate/train/use completed: 132 profiles, training thread modes1/2,
three unrolled loops in both modes. Validated compiler SHA:
`e9989b8927ac48b46d9bce3c8a41d6a33ea8c61f9cea384ff01c0755e217c252`.
Warm source/receipt reuse and presence-only checks exit0 in about1.3-1.4s.
The initial long-running shell wrapper was edited during execution; explicit
CLI termination and a regression now prevent reading an appended file tail.
Fresh wrapper invocation and the PGO receipt both validate.

## Follow-Up

Boolean permission validation and nine sampled byte-identical golden artifacts
are complete. The next increment adds resource-owned, scoped DMA leases and
automatic generated simulator PGO; it runs tests on immutable snapshots while
implementation continues separately. See `apu-simulator-pgo-implementation.md`.
Bridge registration/fault translation, complete T2 transport and real
RTL/aggregate/CTS qualification remain separate open gates.
