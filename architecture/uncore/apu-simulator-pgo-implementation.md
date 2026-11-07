# Simulator PGO And Concurrent Development Increment

GSys LibreCore's APU testharness requires both compiler PGO and generated
simulator PGO. They have independent training, identities and receipts.
This increment also adds resource-owned DMA leases to the T2 verification
model. It does not implement a complete native CTS backend or change silicon.

## Policy

`APU_SIM_PGO=1` is the local default and an internal forced setting for remote
APU RTL leaves, including synth stages that also execute simulations. An
explicit local `APU_SIM_PGO=0` is diagnostic only, not the testharness policy.
`APU_AUTO_INSTALL=0` blocks a missing/stale profile-use image instead of using
an unprofiled fallback. Host prerequisites are detected, never installed with
apt, sudo or downloads.

## Implemented Code

- `verif/tb/apu/apu_sim_pgo.py` auto driver: intercept --binary / --build,
  generate C++ without native build, GCC instrumented native build, bounded
  training, force profile-use native rebuild in identical object paths.
  Requires model-named nonempty gcda, successful positive training markers
  (training is NOT validation), profile-use invocation traces, final binary
  SHA, source/compiler/training/recipe fingerprint and source-drift rejection.
  Receipt validation also recomputes the request hash from the stored request.
  Launcher and compiler source/runtime identity participate even when a
  runtime-only update leaves the compiler executable unchanged.
- `apu_sim_training.py` bounded adapters: vgtop/vgsys/sys-venus two fixed
  compute/graphics copy sessions; shwave one row-major case; vnfront selects
  payfull when -GObjPayWords=512; shader module/core receive absolute vector
  paths; bridge idle 2000 cycles only (explicitly not
  representative of shader/guest speed); cva6 probe both arms; other APU
  directed TBs default self-test. Unknown service blocked. No silent fallback.
- `apu-verilator.sh` launcher. `local-verilator.sh`
  wraps the validated real compiler by default with APU_SIM_PGO=1; unwraps and
  revalidates inherited bindings. Explicit local mode0 stays possible; remote
  APU RTL leaves force1 internally. Source toolchain records simulator required
  and nests compiler report without legacy simulatorPgo:false field.
- The compiler-PGO runtime `verilated.mk` contains
  CXX/LINK pointing at its compiler-PGO wrapper. Simulator driver explicitly
  overrides BOTH CXX/LINK, OBJCACHE=, CCACHE_DISABLE=1, OPT_FAST=-O3,
  OPT_SLOW/OPT_GLOBAL=-O2 so compiler profiles cannot leak into simulator.
  Compiler recipes and their cached proof are independent of this new
  simulator recipe. Gcov output-redirection environment variables are cleared
  in child processes so training profiles remain inside the private attempt.
- Immutable hashed simulator cache; fresh retained attempt on rebuild. Native
  program path never overwritten. Compatibility symlink published atomically.
  Per-run JSON points at immutable image; dev validation reads and verifies
  copied receipt, then executes immutable image, not shared alias.
  Generic logs currently live in cache; per-run receipt records paths+hashes.
  Local cache defaults under `APU_BUILD_CACHE/simulator-pgo`, respecting XDG;
  no automatic cache deletion occurs.
- Proxy internal env: SIM PGO=1, cache=/opt/testharness/cache/apu-sim-pgo and
  source ID=uploaded source SHA. Three timeout knobs allowlisted/validated.
- Budgets: APU_SIM_PGO_TIMEOUT=1800 total setup/lock, APU_SIM_BUILD_TIMEOUT=600
  per generation/native phase, APU_SIM_TRAIN_TIMEOUT=60 per training invocation.
  Compiler setup1200, final test60 unchanged and distinct.
- run-apu-dev build outer timeout uses simulator total budget when enabled.
  regression exports APU_SIM_RECEIPT_DIR into per-run output.
  Remote dev defaults wait4200 / suite2400, DETACHED by default:
  wrapper returns4 INCOMPLETE for launch-only, collect required before PASS.
  APU_LEAF_DETACH=0 restores synchronous operation; existing proxy --detach
  and apu-leaf-collect are reused. No second remote control plane.
- Source manifest configuration keys now record PGO settings.
- Regression classifier recognizes simulator setup BLOCKED/INCOMPLETE ahead of
  legacy "VERILATOR BUILD FAILED", so tool provisioning is not an RTL failure.
  Aggregate summaries require valid, source-matching profile-use receipts when
  simulator PGO is required. A positive simulation line without that evidence
  is INCOMPLETE.

## Two Concurrent Lanes

Implementation edits the live repository. Tests use a checksum-verified frozen
source snapshot, an isolated output directory and immutable keyed simulator
images. Do not edit a running snapshot or its tooling. Same-key setup uses a
lock; accepted images are never rebuilt in place. Before publication, the
driver rejects changed source, tool or training inputs.

```sh
APU_LEAF_STAGES=dev APU_DEV_COHORT=layout \
  bash verif/tb/apu/run-apu-remote-leaf.sh
```

Dev launches detach by default; exit4 means launch-only INCOMPLETE, not a pass.
Continue implementation while that worker runs. Use the returned tag with
`testharness_proxy.py apu-leaf-collect <tag>` before reporting a checked result.
Set `APU_LEAF_DETACH=0` for a synchronous CI invocation. No new remote execution
path is introduced.

Training is calibration, never counted as test coverage. Final selected probes
run separately on the verified profile-use image. Sampling reduces execution
breadth, not Vulkan's API contract; the hand-picked training mechanisms are
not a CTS probability sample or a conformance result. Bridge idle training in
particular supports no shader/guest throughput claim.

## Next Implementation Completed Independently

`corev_apu/apu/tools/vn_dma_resources.py` ResourceDma + immutable DmaLease:
context/resource ownership, monotonic native capability generations, stale or
forged lease rejection, transactional multi-region registration/rollback, exact
revoke, atomic context teardown prevalidation and per-resource scoped reads/
writes (cannot access other owners even if global policy permits the span).
External policy replacement detected by region object identity. Caller
serializes. No wire dispatch, Bridge lifecycle wiring or hardware claim.
Eight tests cover these contracts, including interruption rollback. The manager
is deliberately separate from legacy fixture dictionaries. Blob/context wire
dispatch, object-table coupling and fault translation remain the next backend
integration work.
Registrations own disjoint backing ranges, not Vulkan buffer-binding
semantics. Shared-backing references and final-owner retirement must be
resolved before coupling the registry to guest control dispatch.

## Evidence

Compiler PGO already genuinely completed:
`~/.cache/librecore/apu-verilator-pgo-v1/pgo.json`, 132 profiles, loops[3,3],
binary e9989b8927ac48b46d9bce3c8a41d6a33ea8c61f9cea384ff01c0755e217c252.
Cold compile phase gap ~936.8s. Warm compiler/presence checks1.3-1.4s.
Initial shell wrapper returned2 because it was edited during build; fixed by
explicit CLI exit, regression added, fresh invocation exits0. No C++ PGO
failure. Old missingProfileWarnings=2 is a legacy COUNT BUG (wrapper's
flag string contains "missing-profile" so it counts ALL warnings): inspected
use.log warnings were make -j1 jobserver + V3SplitVar narrowing, NOT missing
profiles. Do not call these missing-profile warnings.

Real frozen simulator PGO smoke:
- Initial attempt `.SVvBeJ` failed warning-fatal BLKSEQ on intentional TB clock.
  Retained; no false pass. New independent snapshot added normal -Wno-BLKSEQ.
- Shell `35b122` FINISHED EXIT0. Work:
  `/root/.cache/librecore/apu/sim-pgo-smoke.8gnjky`.
- Snapshot copied Python driver/modules, wrapper and tiny
  `tb_g6lc_sim_pgo_probe.sv`. Actual infrastructure toy, NOT APU RTL.
- Completed instrument/build/train/profile-use with actual pinned compiler,
  then separately executed profile-use program: PASS checks=1.
- Request/cache ID:
  `9447f29bb2636ed908d996c8eb8ce724334d3ea7253d942d81f61396738dc62a`.
  Immutable binary under cache/<id>/attempt-1b2vwy0c/model/.
  Evidence receipt under work/evidence/tb_g6lc_sim_pgo_probe-<id>.json.
- This ran concurrently with ResourceDma implementation in mutable repo; test
  source/tooling were frozen in separate snapshot. No RTL device qualification.

Final identity-bound frozen infrastructure run:
`/root/.cache/librecore/apu/sim-pgo-identity.K5WPbG`.
Four model/runtime gcov profiles, completed profile-use rebuild, independent
PASS checks=1. Binary SHA:
`4776c710fafff79de3c781b289168a9c95b0917cf690320dcd1e73898fde3baa`.
Recorded arguments include unroll256/131072 and --stats; the simulation-only
testbench fence remains active. Exact-image warm reuse with
`APU_AUTO_INSTALL=0` takes0.08s without rebuilding or training.

112 focused checks pass:33 harness/policy (5.767s),39 model (0.027s),40 scoped
proxy/manifest/gate (6.036s). These are host/mock/model results, not device RTL.
Actual default/inherited wrapper binding reports the pinned repository5.008.
Scoped header/tier/attribution/whitespace audit passes21 MIT source files;
Bash syntax passes. No upstream notice changes or new RTL link inputs.
Presence-only `run-apu-dev.sh --layout --check` passes without installation,
model compilation, training or simulation.

## Integration And Remaining Gates

Review: only tooling, a standalone infrastructure testbench and native model
code change. The testbench is simulation-only under translate_off. No
functional RTL, clock/reset domain, SRAM port, timing cone, config/ISA/CSR,
RVFI/PMU/DFT path, DTS or advertised Vulkan capability changes. Silicon timing,
area/power and RISC-V spec-index statuses are unchanged.

No new remote APU RTL run, complete CTS, full aggregate, formal/compliance,
synthesis or physical qualification is claimed. The managed-simulator patch
gap and shared-cleanup safety requirements still apply; do not interpret an
isolated infrastructure smoke as those gates. No network access, global
installation, shared cleanup or user Storamic edits occur in this increment.
Tooling/model/testbench files are MIT-tier; upstream compiler notices remain
unchanged and compiler sources are not RTL link inputs.
