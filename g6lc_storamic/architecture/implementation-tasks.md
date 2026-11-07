# Storamic implementation task backlog

This execution queue follows the approved M0 foundation plan. Progress below is
scoped to recorded source/configuration/tool snapshots and does not authorize
artifact recovery or shared cleanup. ST-002 is complete; ST-001, ST-003 and ST-004
have verified implementation slices with remaining qualification gates. Later
capabilities remain open unless explicitly marked otherwise.

Normative inputs: [configuration](configuration.md), [transactions](contracts.md),
[discovery/pins](discovery-and-pins.md), [media/persistence](media-and-persistence.md),
[host interfaces](host-interfaces.md), [verification](verification.md), and the
[system architecture](../../architecture/storamic/README.md).

## Current execution checkpoint

Artifact root for these checkpoints is `%LOCALAPPDATA%/Temp/cva6-artifacts`.

- `storamic-af46decd087b/output/leaf-result.json`: selected protocol, configuration,
  integration, synthesis and depth-12 formal pass; all 37 retained configurations
  compile. The previous five initializer failures are repaired, with Storamic off.
- `storamic-001e186eaa74/output/leaf-result.json`: 10 protocol cases and 13 native
  integration cases pass, including four real joined-path cases and the expected
  timeout with the former readiness wiring. Synthesis remains 59 generic cells,
  without latches or combinational SCC. These are not physical timing results.
- The latest isolated snapshots include dirty/untracked selected sources, validated runtime
  records, compiler tools, generated inputs and actual C++ dependency hashes,
  including system headers. Windows/WSL upload and collection paths are converted
  at the build-platform boundary. Failed/incomplete attempts remain retained.
- TypeScript and focused configuration/Storamic tests pass. The AI pin drift and
  L2 proxy import fixture failures were repaired; focused shell/qualification
  tests pass 31 cases. This does not replace the pending isolated aggregate gate.
- `storamic-96013e94fdae/output/leaf-result.json`: the first executable frontend
  component failed a write-response oracle check (`STORAMIC_MODEL_WRITE_RESPONSE`,
  expected `OKAY`, observed `SLVERR`). This is component evidence only — it is
  not a completed ST-005..ST-007 gate and grants no model capability.
- `storamic-969942d0eec0/output/leaf-result.json`: all ten model cases pass —
  five positive profiles plus five expected `STORAMIC_MODEL_CONFIG_ILLEGAL`
  configurations — with a passing corrupted-data negative oracle and captured
  concurrent AW/W/memory/B activity in the concurrent window. The earlier failures
  were a Verilator `fork/join` lowering artifact (timed task calls flattened
  into sibling branches so the assert ran before waits), not a DUT defect;
  the testbench workaround is a component checkpoint under ST-007A, not ST-007
  completion.
- `storamic-7eea26e38385/output/leaf-result.json` (model only) and
  `storamic-3c25eee4aaa3/output/leaf-result.json` (protocol, config,
  integration, synth, formal, model-synth, model-formal): contract-v2 typed
  off/refuse/model profile integrated behind the top with an explicit external
  memory seam; all 26 model cases and both corruption controls, 14 native
  cases, M0/native/component/selected-top synthesis and depth-12 formal pass.
  The one-region standalone model slice (ST-007A plus its top-profile binding)
  is delivered; native model projection, regions, discovery, aggregate and
  technology gates remain open.

ST-032 decomposition: ST-001A (leaf provenance) and ST-004A (service readiness)
are complete. ST-001B (safe aggregate recipe/verdict), ST-004B (native atomic and
exclusive refusal), ST-004C (explicit native preload/build rejection) and
ST-004D (board elaboration where bindings exist) remain open. Standalone model
implementation can use the settled service contract, while full native promotion
remains gated by those checks and ST-012. The next design is
[model-interface](model-interface.md); its existence does not grant model support.

ST-001B checkpoint (2026-11-03): **incomplete, not a gate result.** The owned
recipe now works without shared cleanup. A frozen capture (18,183 source files;
archive sha256 `cd075f05…abe995`; 18 recorded omissions, including Linux-only
absolute tool links, which are not substituted) was extracted into a run-owned
remote tree. There the unchanged configured `verify` ran with all targets,
stages and baselines. Run `storamic-aggregate-gate-7d3e9a14` reached its
3600-second deadline during the first single-job formal task and stopped only
its owned process group. Lint produced no outcomes. The simulation preflight
correctly refused, because neither managed Verilator nor RISC-V GCC is bound
in the owned tree. Standalone slang is also absent from the remote tool
prefixes. Closing the gate requires a provisioned owned tool binding
(Verilator patched per `verif/regress/verilator-*.patch`, RISC-V GCC and
slang) plus a formal budget matching the configured engine parallelism. Those
provisioning steps are an explicit tool installation and need approval. The
earlier attempt `storamic-aggregate-gate-c51d3f98` never created a remote run
and is not evidence.

ST-001B checkpoint 2 (2026-11-03): **owned tool set provisioned; gate v2
completed with failures.**

Pinned tools under
`/opt/testharness/cache/storamic-aggregate-tools/v2-1856fe1b125a-545f88b2ed3a`
(`aggregate_tool_provision.py`):
- the `tools/verilator` g6lc fork at its gitlink. That commit exists only
  locally, so it was uploaded as a hash-checked `git archive`; the build
  carries the `verilator-v5.patch` lines.
- standalone slang at the `tools/yosys` `libs/slang` gitlink;
- copies of the xPack GCC 14.2.0-3, Spike and formal trees.

Run `storamic-aggregate-gate-v2-e41c8a73` used snapshot
`storamic-aggregate-b2d259e07a2a`. The normal simulation preflight accepted
it. Result: 19 of 25 outcomes passed (cv64 lint, 14 of 17 formal tasks, and
synthesis on both targets) and 6 failed, each traced to an environment cause:
- three formal tasks: the builder has no `yices-smt2`;
- cv32a65x Verilator lint exited 139 at the 8 MiB stack limit;
- the cv64 smoke run: the captured nested test repositories had no `.git`, so
  `install-riscv-arch-test.sh` failed `git fetch`;
- the cv32 smoke run: Spike's library path `tools/spike/lib` was absent.

Gate v3 (`aggregate_remote_gate_v3.py`) adds:
- Yices 2.6.5, the pinned release asset with its SHA-256 recorded
  (`aggregate_yices_provision.py`);
- an unlimited stack;
- nested test repositories whose HEAD is the captured commit;
- the owned Spike libraries at `tools/spike/lib`.

It changes no configured target, stage or baseline.

ST-001B checkpoint 3 (2026-11-04): **gate v3 `storamic-aggregate-gate-v3-71b2e9c4`
= aggregate-fail, 20 of 25 passed.** The archive SHA-256 is `12f1ef17…`. With
Yices installed, `g6lc_fetch_restore` now passes; synthesis passed on both
targets. The five failures, each traced:
1. **cv32a65x lint (exit 139): a defect in the Verilator fork.** Probe
   `storamic-aggregate-lintprobe-c94e0b57` reran the gate's exact argv.
   - The fork at `1856fe1b` crashes in `V3DfgOptimizer::optimize` (gdb
     backtrace). It also reports a bogus `Can't find definition of 'nline'`
     at `core/cva6.sv:5012`, although `hpdcache_rtab.nline` exists.
   - With `-fno-dfg` it fails `V3Const.cpp:2645: Not linked` instead.
   - Stock `verilator-v5.008` lints the same input with zero errors.
   - **Root cause:** `-ffield-split`, which fork commit `f7fa71520` turned on
     at `-O1`+, marks `hpdcache_rtab.nline` for splitting. The hierarchical
     `$display` reference at `cva6.sv:5012` then loses its target, and the
     DFG crash follows from that broken tree.
   - Evidence:
     - `-fno-field-split` lints cleanly (probe
       `storamic-aggregate-lintprobe-7aa13e05`);
     - a sweep over every installed prefix (`storamic-aggregate-lintsweep-61c0f2ab`)
       shows `verilator-v5.008-g6lc` (built from `453031b66`) passing and every
       build after `f7fa71520` failing;
     - `verilator-v5.008-g6lc-fix` (built 2026-11-03 08:39) passes.
   - The `tools/verilator` working tree already holds an **uncommitted**
     `V3SplitVar.cpp` change that refuses any split candidate named by an
     `AstVarXRef`. This change is not from this task, and I left it untouched.
     Pinning a fixed fork means committing that change in the submodule and
     rebuilding the owned tool set. The gate's tool binding and flags were left
     unchanged.
2. **Two formal covers (`g6lc_fetch_realign`, `g6lc_fetch_iq`):** the z3
   engine died ("Unexpected EOF" / BrokenPipe) after 43 and 31 minutes while
   11 SBY jobs shared the host. The BMC tasks for both pass. They fail the same
   way when run alone at `-j 1` (`storamic-aggregate-coverprobe-5d2e81a9`):
   - realign reached a 64.5 GB peak RSS before z3 died after 34 minutes;
   - iq's z3 died after 28 minutes.

   These are solver resource limits of the fetch_B cover tasks, unrelated to
   Storamic. Their depth or engine needs the fetch_B owners' attention; the gate
   configuration was not changed.
3. **smoke-cv64a6: a Storamic integration defect, now fixed.** The
   repository-root `Makefile` hard-coded only the M0 Storamic sources, so
   Verilator rejected `g6lc_storamic_top.sv` (`PKGNODECL
   g6lc_storamic_region_pkg`). The `Makefile` and `Flist.storamic` now list
   every source with packages first, and a host test keeps the two lists
   identical. The leaf runner uses its own source list, so it never
   exercised the `Flist`/`Makefile` order; this is why the leaf gates missed
   the defect.
4. **smoke-cv32a65x:** Spike ran `hello_world` until the 166 s per-test
   timeout (exit 130). The `ci/riscv-*.list` test lists are absent from the
   snapshot. Not yet attributed.

Snapshot b2d259 predates ST-010B and the `Makefile` fix, so v3 is diagnostic
only. The next gate needs a fresh capture.

ST-001B checkpoint 5 (2026-11-04): **the Verilator fork fix is committed and
pinned.**
- `tools/verilator` commit `8c69f297a` (pushed to origin/g6lc) keeps split
  candidates named by a cross-module reference packed.
- The superproject gitlink commit `11d6db2c9` is pushed to origin/master.
- The owned tool set was rebuilt as
  `storamic-aggregate-tools/v3-8c69f297aabc-545f88b2ed3a` (archive
  `a465bedb…`).
- Probe `storamic-aggregate-lintprobe-v3fix-2b7e` shows the gate's exact
  cv32a65x lint now passes with the new fork (rc 0, 0 errors), both with and
  without `-fno-field-split`.
- Gate runner `aggregate_remote_gate_v4.py` binds the v3 tools but has not
  been run yet.

ST-001B checkpoint 4 (2026-11-04): **gate `storamic-aggregate-gate-v3-6b3fbb6d`
on the fresh capture `storamic-aggregate-6b3fbb6d0377` (archive `67f99130…`,
which includes ST-010B/C and the `Makefile` fix) = aggregate-fail, 21 of 25
passed.** smoke-cv64a6 now passes, confirming the `Makefile` source-list fix.
The four remaining failures are all outside Storamic, as diagnosed in
checkpoint 3:
- the cv32a65x lint crash in the Verilator fork (field-split; the fix is
  uncommitted in `tools/verilator`);
- the two fetch_B cover tasks (z3 resource exhaustion);
- smoke-cv32a65x: Spike `hello_world` for cv32a65x produces no output and
  hits the 166 s per-test timeout, while every cv64a6 Spike test completes.
  Not yet attributed; it is not Storamic RTL, since the Spike ISS runs no RTL. Recipe inputs and status scripts are kept under
`build-platform/workspace/storamic-virtio-doc-pass-20261103-115358/`.

## Implementation findings that determine the order

| Current source | Consequence for the next increment |
| --- | --- |
| `g6lc_storamic/rtl/g6lc_storamic_top.sv` selects off/refuse or the explicit external-memory model, holds physical media readiness low and keeps pads safe | Standalone model binding is verified; native mapping, ownership and physical bindings remain separate gates |
| `corev_apu/storamic/g6lc_storamic_attach.sv` now preserves the full AW/W/AR payload (addresses, size/burst/lock/cache/prot/qos/region, ATOP, data/strb/last, user) with interface-shape guards; carrying ATOP is not implementing its atomic protocol and controls/health remain untracked | Successful memory still requires a real control/health path; payload preservation alone grants no capability |
| `corev_apu/tb/ariane_testharness.sv` connects `dram_service_ready` to the optional AI join; `corev_apu/src/g6lc_ai_dram_join.sv` gates requests with it | Joined-path refusal/readiness is covered by directed cases plus the former wiring's expected timeout; atomic/exclusive and preload ownership remain open |
| Native ELF helpers in `corev_apu/tb/{ariane_tb.cpp,g6lc_tb.cpp}` address legacy memory hierarchies | Enabled CPU simulation needs an explicit initialization path through the selected backend |
| `ImplementedMediaCaps` is zero; standalone configuration supports off/refuse/model while the native projection supports off/refuse | Physical media, native memory, block, persistence and VirtIO grants still require their own tested promotion rules |
| `verif/tb/storamic/run_leaf.py` records sources, validated runtime record, compiler tools, generated inputs and system/C++ dependency hashes | Evidence reuse relies on this identity; record new dependencies as stages gain them |
| Existing native atomics/coherence precede some ingress paths; optional DMA joins have their own attribute handling | Prove ownership and reservation behavior for each writer; do not infer it from the backend error tests |

Source paths in task cards are repository-relative. Paths marked **proposed** do
not exist yet and are created only when their task is implemented. Keep all QEMU
models, reference profiles, emission, launch and remote execution in `g6lc_qemu/`.
The simulator-side peer remains under `verif/tb/storamic/`. Standalone digital RTL
remains first-party; inherited SoC types stay outside its closure.

## Ordering and work packages

| Wave | Tasks | Exit |
| --- | --- | --- |
| M0 closure | ST-001..ST-004 | Safe reproducible validation, explicit baseline verdicts, native refusal/readiness contract |
| M1 executable model | ST-005..ST-012 | Data really traverses Storamic, validated mappings and native ownership/boot evidence |
| Scaling foundation | ST-013 | Measured service/credit behavior without starving maintenance |
| M2 passive media | ST-014..ST-017 | One selected physical profile with identified media, timing and fault evidence |
| M3 block storage | ST-018..ST-023 | One chosen standard transport and durable per-stick drives with stock Linux |
| M4 persistence | ST-024..ST-026 | Protected domain, interrupted recovery and qualified Linux PMEM behavior |
| M5 active sticks | ST-027..ST-028 | Separately keyed serial profile with replay/credit and physical-link evidence |
| M6 VirtIO-MMIO host stack | ST-033..ST-041 | First-party modern MMIO transport, split-ring/DMA/IRQ and Linux evidence |
| Profile release | ST-031 | Physical and software qualification for the explicitly selected capability set |
| Reassessment | ST-032 | Evidence-backed next child tasks after each gate |

These are capability gates, not a mandatory serial schedule. ST-014 component
research can begin alongside M1. ST-019 reference work should precede block
frontend software experiments. The host transport is resolved by the
[VirtIO-MMIO decision](virtio-mmio.md): modern VirtIO-MMIO plus native AXI RAM
replaces the retired PCIe/CXL and NVMe-versus-virtio candidates; the retired
ST-029/ST-030 transport epics are not prerequisites for native block or RAM.
Active-stick transport remains a separate link.

Recommended first implementation batch: ST-001, scoped decisions for ST-002 and
ST-003, ST-004, then ST-005. The first data milestone is ST-006/ST-007: one explicit
model region, one outstanding read and write, no interleaving and no physical
media claim. Add regions/discovery/controls before widening concurrency.

## M0 closure tasks

### ST-001 — Isolate validation and complete evidence identity

**Owner / files:** verification and host tooling; `verif/tb/storamic/run_remote.py`,
`verif/tb/storamic/run_leaf.py`, existing `verif/regress/remote/testharness_proxy.py`
transport and build-platform test/verify gateways. **Depends:** none. **State:** leaf provenance complete; isolated aggregate gate open. The simulation runtime
preflight now checks the exact `VERILATOR_INSTALL_DIR` selected for the child —
including the OSS CAD fallback prefix — and rejects missing verilator patches;
native runtime validation and the owned aggregate snapshot/execution remain open.

Create an owned snapshot containing the selected dirty/untracked source closure,
fixtures and dependency identities; keep build outputs separate. Inspect the
aggregate cleanup path before execution. Never run shared `make clean`, restore
removed artifacts, or delete existing evidence as a side effect. Use existing
proxy lifecycle/resource controls and configured artifact destinations. Record
actual compiler, runtime headers, generated inputs, compile flags, tool binaries,
and selected stages; use the validated private runtime required by repository
rules. Add detach/collect/resume by reusing the proxy when needed, not new SSH.

**Done when:** interrupted/pull-failed/missing-summary/drift cases remain incomplete;
source/runtime changes invalidate reuse; snapshots include local deltas; the
aggregate recipe cannot mutate shared outputs. Resource preflight accounts for
other jobs. Required aggregate verification remains a gate, not a waived test.

### ST-002 — Resolve the five configuration baseline failures

**Owner / files:** `core/include/cv64a60ax_config_pkg.sv` and
`core/include/deprecated_packages/{cv32a6_imac_sv0_config_pkg.sv,cv32a6_imafc_sv32_config_pkg.sv,cv64a6_imadfcv_sv39_polara_config_pkg.sv,cv64a6_mmu_config_pkg.sv}`;
`verif/tb/storamic/tb_g6lc_storamic_config.sv`. **Depends:** ST-001 for execution.
**State:** complete for the retained configuration sweep.

Reconfirm the recorded CBO and old-schema initializer failures. Derive each
missing value from the target's intended configuration and maintained peers;
do not use a blanket zero/default initializer to hide missing fields. Preserve
upstream notices and the default-off Storamic field.

**Done when:** every retained target compiles, relevant legality checks execute,
Storamic-off/overlay behavior is tested, and baseline versus new failures are
reported separately. Target retirement, if proposed, is an explicit separate
repository decision, not a test skip used to make this task green.

### ST-003 — Close host typecheck and selection validation

**Owner / files:** `build-platform/src/tooling/timings.ts` (recorded error near
line 1216), `build-platform/src/tooling/storamic.ts`,
`build-platform/src/config/{schema,defaults,load}.ts`,
`build-platform/test/storamic.test.ts` and the suitable existing timing tests. **Depends:** ST-001
for safe aggregate execution. **State:** repairs and focused checks pass; aggregate qualification open.

Reproduce the optional-string type error and repair its actual guard/contract;
do not suppress strict checking. Preserve one resolved Storamic selection across
test/verify/remote entrypoints and reject conflicting raw/environment flags.

**Done when:** targeted tests and `bunx tsc --noEmit` pass, followed by one required
`bun test` gate with opt-in/remote suites handled by the established runner. Missing
optional tools or skipped suites remain visible; no new runtime dependency.

### ST-004 — Prove M0 through the real native admission path

**Owner / files:** `corev_apu/src/g6lc_ai_dram_backend.sv`,
`corev_apu/src/g6lc_ai_dram_join.sv`, `corev_apu/tb/ariane_testharness.sv`,
`corev_apu/storamic/g6lc_storamic_attach.sv`, existing Storamic SoC bench;
board rejection guards in Xilinx/Altera/OpenPiton wrappers.
**Depends:** ST-001. **State:** service-readiness slice complete; native atomic/preload/board gates open.

Reproduce the optional joined path with Storamic enabled and readiness low.
Define request-service readiness separately from RAM/media initialization so a
refusal-capable endpoint can answer requests without advertising initialized RAM.
Carry that distinction through the join and consumers. Verify where ATOP and
exclusive operations are consumed; unsupported operations cannot disappear or
leave a required response outstanding. Check enabled native build/preload failure
behavior explicitly instead of relying on missing generated C++ members.

**Done when:** joined and direct requests reach a bounded refusal path, reset and
stalled-response tests pass, media-ready remains false, and off-path behavior is
preserved. Unsupported board selections reject through executable elaboration
checks where tool bindings permit; unavailable board checks remain incomplete.
M0 closure also needs ST-002/ST-003 and the isolated aggregate verdict.

## M1 executable model and native integration

### ST-005 — Freeze the executable-model interface contract

**Owner / files:** current configuration/transaction documents;
`g6lc_storamic/rtl/include/g6lc_storamic_cfg_pkg.sv`,
`g6lc_storamic/rtl/include/g6lc_storamic_pkg.sv`,
`g6lc_storamic/rtl/include/g6lc_storamic_pad_pkg.sv`, SoC config projection and
typed host config.
**Depends:** ST-004 readiness contract. **State:** contract v2 frozen and
integrated for the one-region standalone model (typed off/refuse/model profiles).
The separate VirtIO transport/role profile remains ST-033.

Publish one versioned profile selection preserving off/skeleton names and adding
an explicit model profile. Freeze full AXI payload/attribute types, supported
burst/alignment rules, normalized media request/response ownership, source/ID/
sequence/reset generation, region records, descriptor fields, error taxonomy,
and readiness/capability separation. Fix control register semantics before their
implementation; SoC addresses/IRQs are allocated by ST-010, not invented here.
Start with one outstanding read and write, bounded parameterized storage and no
interleaving. Physical and persistence grants remain absent for model-only builds.

**Done when:** producer/consumer field tables, reset lifetimes, response reservation,
byte-address rules, full-span validation and unsupported-operation behavior are
unambiguous; RTL/host fixtures agree. Unknown profiles/capabilities reject. Model
selection never becomes an automatic fallback for an absent physical backend.

### ST-006 — Establish first-party memory and technology boundaries

**Owner / files:** **proposed** `g6lc_storamic/rtl/tech/` boundary modules;
first-party behavioral bindings under `verif/tb/storamic/`; package flists;
qualified native bindings outside the standalone closure. **Depends:** ST-005.

Define read/write/mask/latency/error/testmode interfaces compatible with the
repository SRAM/clock/power discipline. Keep behavioral arrays out of production
flists and large payload arrays out of raw flop implementations. Existing
`tc_sram` technology integration stays an explicit external binding, not imported
third-party digital RTL inside Storamic. Missing physical bindings fail clearly.

**Done when:** byte masks, reset, read latency and test hooks match both model and
boundary contracts; source-closure checks distinguish first-party control,
verification models and technology cells. No hidden digital controller in a macro.

### ST-007 — Implement a single-region executable AXI path

**Owner / files:** `g6lc_storamic/rtl/g6lc_storamic_top.sv`, existing refusal frontend;
**proposed** `g6lc_storamic/rtl/frontend/g6lc_storamic_axi_frontend.sv` and
`verif/tb/storamic/tb_g6lc_storamic_model.sv`. **Depends:** ST-005, ST-006.

Two slices: **ST-007A** is the component byte oracle plus handshake coverage over
the `g6lc_storamic_axi_memory` frontend — delivered (`storamic-969942d0eec0`;
the earlier failures were a Verilator `fork/join` lowering artifact, not a DUT
defect). **ST-007B** is the standalone executable profile plus synthesis and
formal — delivered: contract-v2 top binding with the explicit external memory
seam, 26 model cases and both negative oracles (`storamic-7eea26e38385`),
component/selected-top synthesis and depth-12 safety plus reachability
(`storamic-3c25eee4aaa3`). Open follow-on work is distinct: ST-008 heterogeneous
routing, ST-009 discovery/lifecycle, ST-011B native attachment, ST-012
ownership/boot, aggregate and technology/physical gates.

Keep M0 refusal as its own branch. Add the model-profile data path using the frozen
contract, accepting real addresses/data/strobes and preserving IDs and response
shape. Validate the complete request before side effects. Reserve completion
storage before admission and retain AW/W independence. Add basic acceptance,
completion, refusal and error observability with the feature, not afterward.

**Done when:** an independent byte-address reference checks read-after-write,
partial/narrow writes, supported bursts, alignment/boundary errors, overflow/high
address aliasing, simultaneous read/write, backpressure and reset. Unsupported
requests have no media side effects. All M0 negative controls still fail correctly.

### ST-008 — Add validated heterogeneous regions and burst routing

**Owner / files:** **proposed** `g6lc_storamic/rtl/fabric/g6lc_storamic_region_table.sv`
and `g6lc_storamic/rtl/fabric/g6lc_storamic_router.sv`; shared model bench. **Depends:** ST-007.

The [region-routing design](region-routing.md) splits this into three planned
children. **ST-008A** validates normalized RAM capacity, identities, system
ranges and backing extents. **ST-008B** adds complete-burst admission and routes
the existing frontend's per-beat memory commands; it must not duplicate AXI
response ownership in per-slot frontends. **ST-008C** integrates an explicit
standalone profile and the slot/geometry/oracle/synthesis/formal matrix.
The existing single-region contract remains unchanged until that integration.

ST-008A status (2026-11-03): **implemented, scoped leaf evidence.**
`g6lc_storamic/rtl/fabric/g6lc_storamic_region_pkg.sv` provides pure,
constant-evaluable `map_check` (first failure in a fixed priority order, 18
statuses), `usable_total` and `mapped_total` (68-bit). The hand-computed
`tb_g6lc_storamic_region.sv` oracle (32 cases, 38 checks, an elaboration-time
check and a failing negative-oracle mode) passed as `storamic-5d1b58de5189`.
The `protocol,config,model,synth` regression passed after the source-list
change (`storamic-383636e27ede`). The package contains no hardware and is not
yet consumed by the frontend; ST-008B/C stay open.

ST-008B status (2026-11-03): **implemented, scoped leaf evidence.** The
`g6lc_storamic_axi_memory` frontend now has an opt-in `MapEn` mode (default
off). When enabled, it rejects any map that `map_check` does not accept. Each
of the two contexts uses a registered coverage walker of at most `Regions`
cycles; it validates the full burst extent before any command is issued. A
gap, missing permission or table end takes the existing refusal path with zero
commands. The frontend resolves each beat's slot and backing offset from the
registered beat word using 65-bit end comparisons. The new
`g6lc_storamic/rtl/fabric/g6lc_storamic_slot_mux.sv` accepts completions only
from the latched slot and reports other `rvalid` assertions on `stray_o`.

The `tb_g6lc_storamic_map.sv` bench covers 1, 2 and 3 slots at 64 and 512 bits.
It has an independent per-slot byte oracle, region crossings between slots,
hole and permission refusals with zero commands, a region ending at 2^64,
wrong-slot completions and reset. An illegal-map build and a corrupted oracle
must both fail. Run `storamic-ce784744ef74` passed these checks plus 574-cell
structural synthesis with no latches or combinational loops. The `MapEn=0`
regression passed as `storamic-bb3e0e8469e2`.

Limits: the mux routes completions that arrive at least one cycle after grant.
Bounded formal for the mapped mode, 4- and 8-slot sweeps, and the top-level
profile are ST-008C work. Native exposure is unchanged.

ST-008C status (2026-11-03): **implemented, scoped leaf evidence.**
- Contract version is now 3.
- The standalone `ProfileMapped` (`StoramicMapped`) instantiates the mapped
  frontend through `g6lc_storamic_top`. It takes its map from the `Regions`,
  `SlotMap` and `RegionMap` parameters and exposes `mem_slot_o`.
- The slot mux remains an external binding helper.
- The native projection stays off/refuse and only leaves `mem_slot_o`
  unconnected.

Evidence:
- `storamic-8bdf6d1f56bb` passed:
  - 8 mapped configurations: 1, 2, 3, 4 and 8 slots at 64 bits; 1, 3 and 8
    slots at 512 bits;
  - the illegal-map and negative-oracle controls;
  - 574-cell synthesis with no latches or loops;
  - depth-12 formal (slot bound, region and permission containment, held-offer
    stability, plus covers for a slot-0 write, a slot-1 read, and AW and AR
    refusals).
- The full previous stage set passed as `storamic-c44ed98938d8`.

A review fix ties the model profile's `mem_slot_o` to the (zero) frontend
output. Runtime map commit is ST-010B.

Validate base/length/permissions/slot/media identity, address overflow and overlap;
commit an immutable boot map before service. Split supported transactions at
internal region/media boundaries and reassemble the original response. Validate
all affected extents before writes. Reject AXI-illegal requests such as 4-KiB
crossings rather than treating them as legal split requests. Begin without
interleaving; later equal-extent interleaving needs separate evidence.

**Done when:** 1/2/3/4/8 slots, unequal capacities, holes, top-of-address-space
ranges, denied second extents and response ordering pass independent checks.
Removal faults the original mapping and never compacts live addresses.

### ST-009 — Implement discovery validation and lifecycle state

**Owner / files:** **proposed** `g6lc_storamic/rtl/discovery/g6lc_storamic_discovery.sv`,
descriptor package additions, pad input/status boundaries and fault fixtures.
**Depends:** ST-005, ST-008; physical access also depends on ST-014.

Implement absent/present/power-check/identify/validate/initialize/ready/quiesce/
fault transitions. Model fixtures supply explicitly synthetic identities first.
Validate version/length/checksum, capacity bounds, media geometry and electrical
profile; synchronize/debounce physical presence only through reviewed CDC.
Keep RAM, flash, persistence and request-service readiness independent.

**Done when:** empty, RAM-only, flash-only, mixed, unknown, corrupt, duplicate-identity
and removed modules behave safely. Unknown voltage/profile never triggers probing
writes or power enable. Initial insertion/removal remains power-off only.

ST-009A/B status (2026-11-03): **implemented, scoped leaf evidence**, per
[discovery-lifecycle](discovery-lifecycle.md). New files are under
`g6lc_storamic/rtl/discovery/`:
- `g6lc_storamic_sync` (the only new CDC point);
- the state/fault/descriptor package;
- the per-slot machine;
- the slot set, which withdraws duplicate identities from `slot_map_o`.

Evidence:
- `storamic-5511a7ea7ba3` passed the directed bench with synthetic descriptor
  v1 fixtures. It covers every fault code, unknown-profile power monitoring,
  timeouts, debounce, live removal in each powered state, quiesce, and a
  3-slot duplicate case. It also includes a negative oracle, 1,138-cell
  synthesis with no latches or loops, and depth-32 formal (power and
  descriptor-request safety, publication only in READY, sticky faults, plus
  covers for READY, the checksum fault and QUIESCED).
- The regression passed as `storamic-a99556dd6808`.

Limit: removal from PRESENT/POWER_CHECK straight to ABSENT exists in RTL but is
not directly exercised, because each of those states lasts one cycle, which is
shorter than the debounce window. The descriptor format is synthetic, there is
no native pad binding, and real descriptor devices remain ST-014.

ST-010A status (2026-11-03): **implemented, scoped leaf evidence**, per
[control-registers](control-registers.md); contract version 4.
- `g6lc_storamic/rtl/frontend/g6lc_storamic_regs.sv` now serves the top's
  AXI-Lite port in every profile. It provides ID/version/config/status/caps,
  W1C faults and IRQ, wrapping counters, the drain token, the per-slot
  discovery view and control pulses, and a registered level `irq_o`.
- The top computes the transaction pulses. The frontend exports `inflight_o`.
  The discovery inputs are tied to absent.

Evidence:
- A bench (80 checks, with a negative oracle) passed, as did 176-cell
  synthesis with no latches or loops.
- Formal passed as `storamic-b491b01f8ba7`. It proves response stability, that
  illegal writes return SLVERR with no effect, and the IRQ level. Covers reach
  an SLVERR read, an IRQ_ENABLE write and read-back, and drain completion.

Review fix: a same-cycle token write now wins over drain completion.
Limitation: frontend faults are level inputs, so a W1C of `FAULTS[2:0]` lasts
only until the next cycle while the frontend fault persists; the frontend
faults are sticky until reset. Native aperture and IRQ allocation remain
ST-010C.

ST-010B status (2026-11-03): **implemented, scoped leaf evidence.** In
`ProfileMapped` with `BootMapEn=0`:
- the region window (`0x400 + 32*i`) stages the map before commit. A
  `MAP_CTRL` commit snapshots the slot view and runs a sequential validator in
  `map_check` priority order. Failure sets status, fault bit 5 and the commit
  IRQ and leaves staging writable; success freezes the committed map and slot
  identities.
- The frontend accepts and refuses every data request before commit (the
  active map is empty, so no slot command is issued). `model_ready_o` rises
  only after commit, and reset discards the committed map.

Review fixes:
- the leading-region count was returned uninitialized;
- a 1-slot or 1-region map never terminated the validator;
- the frontend held `aw_ready`/`ar_ready` low before commit instead of
  refusing;
- the map-stability assertion fired on the publishing cycle;
- three bench expectations were stale.

Evidence (identical sources):
- `storamic-e5b09beae5ac` passed protocol, config, integration, model,
  region, map, discovery and regs, plus all five synthesis wrappers. Regs ran
  105 checks, including a 200-iteration randomized compare against
  `map_check` with zero mismatches; regs synthesis gave 399 cells.
  `map-rt` covers pre-commit refusal with zero slot commands, AXI-Lite
  programming, commit, mapped traffic, and refusal and recommit after reset.
- `storamic-f5e47606e7ee` passed the formal, model, map, discovery and regs
  formal stages. In regs, depth-12 safety proves the committed map and slot
  view immutable, that `map_valid` implies committed, and that staged writes
  return SLVERR while busy or committed. A commit-failure cover passes at
  depth 12 and a successful-commit cover at depth 16.

Limits:
- `MapSlotCount`, `MapWordBytes` and `MapIdentityMismatch` are statically
  unreachable, as recorded in control-registers.
- Staging uses flops; production staging should move to `tc_sram`.
- The discovery view in the top is still the synthetic `SlotMap` fixture.

ST-010C status (2026-11-04): **implemented, scoped leaf evidence.** The user
approved this allocation:
- a Storamic block at `0x5000_0000`, 1 MiB long;
- control registers at offset 0 (4 KiB);
- offsets `0x1000..0xF_FFFF` reserved for per-stick virtio-blk apertures,
  which answer DECERR;
- PLIC source 10.

What changed:
- **Map owner:** `ariane_soc_pkg` defines `StoramicBase`, `StoramicLength`,
  `StoramicCtrlLength` and `StoramicIrqSource`, not added to `axi_slaves_t`.
- **Test harness:** with `CVA6Cfg.StoramicEn` it adds one crossbar port and
  address rule, the new first-party AXI4-to-AXI-Lite bridge
  `corev_apu/storamic/g6lc_storamic_ctrl_bridge.sv`, and the IRQ route
  `ariane_peripherals.storamic_irq_i` → `irq_sources[9]`. With it off, the
  port count, address map and IRQ wiring are unchanged.
- **Backend and attach:** `g6lc_ai_dram_backend` and `g6lc_storamic_attach`
  pass the control port and IRQ through. All 13 backend instantiations were
  updated.
- **Device tree:** an opt-in `corev_apu/bootrom/g6lc-storamic.dtsi` ships
  disabled, because no Linux driver exists.

Bridge rules:
- Legal accesses are `len==0`, `size<=2`, `atop==0` inside the control page.
- The 32-bit lane is selected by `addr[2]`; read data is replicated in both
  halves.
- Other shapes get SLVERR after draining W beats or returning `len+1` R beats.
- The AXI-Lite AW and W handshakes are tracked independently.
- B passes through under backpressure.

Review fixes (to the delegated implementation):
- a nonblocking assignment inside `always_comb`;
- part-selects of expressions;
- AW/W accepted only together, which duplicated AW;
- the AXI-Lite B consumed under backpressure and lost;
- an `ar.atop` reference that the `ariane_axi_soc` AR channel lacks;
- the testharness `addr_map` driven twice;
- the backend control response and IRQ left unconnected;
- `ariane_peripherals` never extended;
- a `forever @(posedge)` assertion that broke `--no-timing` builds;
- CRLF churn across 25 files;
- a `run_leaf.py` regression that moved the regs negative-oracle check and
  embedded raw newlines.

Evidence:
- **Bench:** `tb_g6lc_storamic_ctrl_bridge` (bridge into the real regs block)
  passed 115 checks in the `ctrl` and `ctrl-stall` variants
  (`storamic-7a75f6b22f60`). `ctrl-stall` holds the AXI-Lite W channel off for
  four cycles after every AW.
- **SoC bench:** `tb_g6lc_storamic_soc` reads ID through the backend's
  control port and checks the IRQ stays low.
- **Harness lint:** stock Verilator 5.008 `--lint-only` of
  `ariane_testharness`/cv64a6 has zero errors both by default and with
  Storamic selected (`storamic-harness-lint-b37a2e95`, verilator_bin
  `3095ea73…`, delta `3dcfdb4d…`). An earlier run of the same probe
  (`storamic-harness-lint-41e8b0c7`) caught the `--no-timing` assertion
  defect.

- **Final full Storamic pass on identical sources:** `storamic-e81d3bca8a1b`
  passed protocol, config, integration, model, region, map, discovery, regs
  and ctrl, plus all six synthesis wrappers (bridge: 176 cells, no latches or
  loops). `storamic-28471d23806c` passed all five formal stages.

Limits:
- There is no Linux driver.
- The harness lint is a diagnostic run on an older snapshot with the working
  tree overlaid; it is not a gate result.
- FPGA and Altera wrappers still refuse Storamic.

### ST-010 — Implement controls, health, interrupts and map publication

**Owner / files:** **proposed** `g6lc_storamic/rtl/frontend/g6lc_storamic_regs.sv`
and register package; `corev_apu/storamic/` control adapter;
`corev_apu/tb/ariane_soc_pkg.sv`
map owner and applicable IRQ/DTS/firmware consumers. **Depends:** ST-005, ST-009.

Allocate non-overlapping SoC control addresses and IRQs through the existing map
owner. Implement version/profile/readiness/capacity/error reporting, bounded
region commit, status clearing and interrupt acknowledgment. Define an explicit
cross-interface drain token; an AXI-Lite write does not order AXI data by itself.
Expose only supported readback and actual counters.

**Done when:** decode, byte enables, RO/W1C behavior, simultaneous event/clear,
IRQ level/deassertion, reset, permission checks and immutable-map rules pass.
DTS/config/register views agree; no guessed address or fabricated capability.

### ST-011 — Extend the native adapter to the complete data/control boundary

**Owner / files:** `corev_apu/storamic/g6lc_storamic_attach.sv`,
`corev_apu/include/g6lc_storamic_soc_cfg_pkg.sv`,
`corev_apu/src/g6lc_ai_dram_backend.sv`, testharness and both Storamic flists.
**Depends:** ST-004, ST-007, ST-008, ST-009, ST-010.

Two slices: **ST-011A** is the bounded wire/shape slice delivered in this batch —
parameterized `AddrWidth`, full AW/W/AR payload preservation and the
`STORAMIC_INTERFACE_SHAPE` guard — which does not need functional region/media
completion. **ST-011B** implements the functional attachment after
ST-007/ST-008/ST-009/ST-010; ST-012 subsequently qualifies CPU/DMA/atomic
ownership and boot.

Carry addresses, sizes, burst types, data, strobes, last, IDs and relevant user/
protection/ordering attributes through parameterized types. Resolve atomic and
exclusive semantics at the existing native boundary; do not silently drop them.
Route control/IRQ/health and selected pad/technology signals through thin glue.
Keep placement, clock/reset and media engines in their proper owners.

**Done when:** 64/512-bit and ID-width variation tests exercise payload integrity,
not just response tags. M0/off still work and legacy hierarchy stays intact.
Flash-only native-primary configurations require independent boot RAM or reject;
no synthetic successful RAM is inserted to make boot possible.

### ST-012 — Qualify CPU, DMA ownership and native model boot

**Owner / files:** native harness and ELF helpers under `corev_apu/tb/`, actual
atomic/coherence and AI/APU ingress seams, Storamic integration tests and optional
build-platform suites. **Depends:** ST-011; M0 promotion also requires ST-002/ST-003.

Initialize through the selected modeled backend with an explicit boot contract;
never preload a shadow host buffer while bypassing Storamic traffic. Test CPU
fetch/load/store faults, page-table access, byte stores, LR/SC and AMOs with competing
writers, fences and reset. Establish DMA permissions and cache maintenance or
ownership transfer before claiming shared-memory coherence.

**Done when:** a minimal native program proves the path and reservation behavior,
then the applicable existing boot/regression gates run remotely in isolation.
A model Linux boot is labeled as such. QEMU reference boots cannot substitute for
native atomic/coherence evidence, and a UART banner alone is not boot completion.

### ST-013 — Measure service, then add bounded concurrency and QoS

**Owner / files:** first-party fabric/scheduler/credit control and telemetry;
native event projection where applicable. **Depends:** ST-012.

Use captured occupancy/stall/latency evidence to justify more outstanding work,
credits and interleaving. Reserve response capacity independently from request
queues. Bound CPU demand service and guarantee refresh, recovery and storage
maintenance progress; do not create permanent CPU-priority starvation. Keep
clock enables initially; qualified gating needs technology and testmode bindings.

**Done when:** adversarial mixed traffic has no loss, duplication or credit leak;
bounds state fairness/ready assumptions explicitly. Publish clocks, useful bytes,
workloads and distributions, separating model throughput from physical throughput.
Only compatible equal extents interleave, with no address-map change on removal.

## Passive media and block storage

### ST-014 — Select and pin the first passive electrical/media profile

**Owner / files:** discovery/media architecture and future qualified `corev-mb/`
profile/board records. **Depends:** none for research; ST-005 for contract freeze.

Choose actual RAM and flash parts, identification mechanism, voltage, bus sharing,
connector/keying, chip selects and target pad/sampling interfaces from datasheets.
Decide NOR prototype versus NAND production scope. Publish signal/ball/contact
budgets including power/ground, management, isolation and test. A chip without a
unique ID needs a provisioned identity policy. No destructive discovery or guessed
voltage. Keep active serial electrically distinct.

**Done when:** a revisioned profile specifies timing/geometry/ECC requirements,
physical macro ownership, power sequencing and mechanical/SI/PI constraints.
No exact routed pinout or sustained bandwidth is claimed from an illustrative budget.

### ST-015 — Implement the selected passive RAM controller and binding

**Owner / files:** **proposed** `g6lc_storamic/rtl/media/` RAM engine and
`g6lc_storamic/rtl/tech/` pad/sampling
boundaries; selected `corev_apu` board binding and constraints.
**Depends:** ST-006, ST-007, ST-009, ST-014.

Implement the selected device's command/address, bank/rank/chip selection, burst,
latency, refresh and initialization/training rules where applicable. Respect DQ/
RWDS direction and turnaround; bind sampling/clock/pads explicitly. Remove an
unsupported-board guard only for a fully described binding.

**Done when:** device timing/error models cover reads/writes, turnaround, refresh,
reset and contention; CDC/reset analysis and IO timing constraints accompany the
binding. Model success alone does not qualify physical memory or DDR4-like rates.

### ST-016 — Implement raw flash operations for the selected profile

**Owner / files:** **proposed** first-party `g6lc_storamic/rtl/media/` flash engine, device model
and native physical binding. **Depends:** ST-009, ST-014.

Implement identification, read/program/erase, busy/status/timeouts, alignment and
error handling from the chosen device specification. Handle NAND parameter/ECC/
bad-block facts only for an explicitly selected NAND profile; do not treat NOR and
NAND as interchangeable.

**Done when:** page/erase boundaries, illegal operations, program/erase failures,
reset and power interruption are tested. Raw flash is not yet a block drive, SSD
or PMEM capability.

### ST-017 — Add media-appropriate ECC, MBIST and fault reporting

**Owner / files:** **proposed** first-party ECC/BIST control, media error paths,
CSR/RAS telemetry and test bindings. **Depends:** ST-006 and ST-014 plus the
corresponding ST-015 or ST-016 media slice.

Select protection strength from real device requirements. Define data+ECC atomic
updates for narrow writes, correction/scrub policy, uncorrectable error/poison and
maintenance ownership. Preserve MBIST/scan/testmode access and keep destructive
BIST away from live allocations. Transport CRC is not media ECC.

**Done when:** injected faults cover correctable/uncorrectable classes, metadata,
partial writes and scrub/BIST conflicts; errors propagate to the real requester
and health counters. Qualification remains per media/profile, not blanket immunity.

### ST-018 — Implement a durable transport-neutral block backend

**Owner / files:** **proposed** `g6lc_storamic/rtl/media/` block/media-management and
`g6lc_storamic/rtl/persistence/` mapping/journal control; versioned block contract.
**Depends:** ST-016, ST-017.

Two ordered slices with different prerequisites. **ST-018A** defines the
transport-neutral block contract — bounded read/write/flush/FUA/error
operations, stable per-stick identity, sector/offset units and error taxonomy —
plus a clearly labeled volatile verification binding. ST-018A depends on
ST-005/ST-007 and does not inherit the parent's physical ST-016/ST-017 gates;
model paths may depend on ST-018A alone. **ST-018B** depends on ST-018A plus
those physical gates; it adds the durable physical implementation and
interrupted recovery: persistent identity, reserved metadata/recovery space and,
for NAND, bad-block management, ECC integration, wear leveling, garbage
collection, crash-consistent mapping and exhaustion handling. Physical writable
promotion requires ST-018B; a bounded NOR prototype must be labeled and cannot
stand in for NAND qualification.

**Done when:** power cuts at metadata/data/commit boundaries, repeated recovery,
full journals, bad blocks, wear/space exhaustion and reset preserve the declared
durability/atomicity contract. Acknowledged durable data is recoverable; capacity
never double-counts PMEM backup or recovery space. This durable gate governs the
parent task; ST-018A alone does not close it.

### ST-019 — Add the published Storamic contract to g6lc_qemu

**Owner / files:** exclusively `g6lc_qemu/` pins, `g6q-svcfg`, `g6q-core`,
`g6q-ingest`, schemas, fixtures and existing package tools.
**Depends:** ST-005; further fields only after their owning contract freezes.

Consume published enable/profile/geometry/capability names by a deliberate pin.
Add reader, IR, schema, conformance and name-set tests together. Missing values
remain unresolved. Reject unsupported selected profiles instead of silently
providing generic RAM. Preserve package independence and text-out-only GPL emission.

**Done when:** present/absent/unknown fixtures pass package `check`, no design
constant is invented in an emitter, and reference versus RTL-backed modes are
visibly different. Existing owner queue: `g6lc_qemu/architecture/RTL_FEEDBACK.md` §6.

### ST-020 — Select and qualify the VirtIO-MMIO block profile

**Owner / files:** `g6lc_storamic/architecture/virtio-mmio.md` and
`host-interfaces.md`; all QEMU stock reference profiles and runs under
`g6lc_qemu/`. **Depends:** none for the architectural choice; consumed artifacts are handled by ST-019. **State:** ADR resolved; detailed implementation profile in ST-033 and empirical software qualification in ST-038 remain pending.

The transport is decided: modern VirtIO-MMIO pinned to VIRTIO 1.4 CS01 with
`Version` = 2 and a first split-ring virtio-blk subset, per the linked decision
with its sources and tradeoffs. The detailed negotiated bit/register
implementation profile belongs to ST-033; empirical stock-software qualification
is ST-038's gate after the block implementation exists. virtio-PCI is a
different transport and is not implied.

**Done when:** the recorded ADR selects the transport, cites its sources and
tradeoffs, and lists the capability gates that still apply.

### ST-021 — Implement the VirtIO-MMIO block frontend

**Owner / files:** **proposed** `g6lc_storamic/rtl/host/` VirtIO-MMIO frontend, native
control/DMA/IRQ glue and its protocol benches. **Depends:** ST-010, ST-018A,
ST-020, ST-034, ST-035, ST-036; physical writable drives additionally need
ST-018B and the ST-015/ST-016 media gates.

Implement the pinned profile's negotiation, queues/descriptors, DMA bounds,
completion ordering, interrupts, reset, identity and durability — IN/OUT/GET_ID
and the specified FLUSH/cache-mode semantics; do not invent a virtio-blk FUA
opcode. Expose one drive per flash-bearing stick. Keep the block backend neutral
and enforce native/external address ownership and DMA permissions.

**Done when:** malformed queues/pointers, full queues, reset races, duplicate/stale
completion and FLUSH failures are checked independently. Advertise only tested
features; no filesystem/RAID implementation or shared writable cross-host image.

### ST-022 — Emit an actual RTL-in-the-loop bridge through g6lc_qemu

**Owner / files:** `g6lc_qemu/` emitters/tools and **proposed** simulator-side peer
under `verif/tb/storamic/`. **Depends:** ST-019 and the tested path (ST-011 for
native controls/data, ST-021 for block, optionally ST-039/ST-040 for
virtio-mem/pmem device behavior).

Version the transport and forward accesses at a declared cut into RTL, including
required MMIO/configuration plus descriptor, data and status DMA, IRQ and reset
events. Tag transaction/reset identity and bound outstanding work. Host RAM
backing the tested aperture must not bypass the controller — no shadow-memory
substitution for ring, payload or status traffic. Reuse existing package/proxy
lifecycle support.

**Done when:** a deliberate RTL fault changes the observed guest outcome, all
operations have correlated completion/error records, and disconnect/reset cannot
replay a write or accept stale results. This does not prove physical timing or
native cache coherence.

### ST-023 — Qualify stock-Linux block behavior and software aggregation

**Owner / files:** tests/payloads under verification; QEMU profiles/launch under
`g6lc_qemu/`; native SoC map/config documentation.
**Depends:** ST-021; RTL-backed QEMU evidence needs ST-022; native boot needs
ST-012; physical claims need ST-015/ST-016 and applicable ST-031 gates.

Use the unmodified selected Linux driver for enumeration, capacity, stable identity,
read/write/flush/reset and fault recovery. Exercise multiple flash-bearing sticks
and normal md/LVM or supported multi-device filesystem aggregation in software.
Keep RAM-only slots absent from block enumeration and recovery capacity hidden.

**Done when:** guest IO is correlated to the declared RTL/media path, data survives
qualified fault cuts, drive identity survives permitted relocation/reboot, and
software-only, native-model and physical results remain separately labeled.

## Persistence and active links

### ST-024 — Freeze the persistence domain and worst-case protection budget

**Owner / files:** persistence architecture, selected board power/hold-up design
and media contract. **Depends:** ST-014, ST-018.

Specify a fully resident RAM window and every protected queue/data/metadata state.
Derive admission limits from maximum dirty bytes and guaranteed backup throughput,
power, voltage, aging and temperature. Define cache clean/fence, AXI completion,
block FLUSH/cache-mode and virtio-pmem flush relationships — these are distinct
acknowledgment boundaries. CPU caches are not implicitly
protected. Reserve backup/recovery capacity and define degraded-protection refusal.

**Done when:** independently reviewable worst-case energy/time bounds and fault
assumptions exist; model throughput is not used as guaranteed physical bandwidth.
Do not advertise persistence based on typical save times or a checksum alone.

### ST-025 — Implement protected save/restore and interrupted recovery

**Current status: open.** The source audit in
[`development-status.md`](development-status.md) supersedes later historical
claims of model-level completion. Commit telemetry is not a persistent journal;
the model magic-key interlock is not a protected stick-wide ABI. Commit/replay/
save and response/readback corrections pass the pinned `dstore` leaf at delays
0/1/4/16 (`storamic-555acfbc60e9`), including four rejecting negative oracles.
RAM scan/drain and last-valid-image prerequisites also pass the expanded pinned
leaf `storamic-7cd4d99acf53` (73/79/85/109 checks at delays 0/1/4/16, plus four
rejecting negative oracles). RAM images are now two tc_sram banks, published
only on a completed save, and retained across interrupted save/restore.
These are selected-leaf results, not stick-wide coordination, durable
identity/map metadata, aggregate or physical-persistence qualification.

Next work is split into ST-025A..E in
[`checkpoint-coordination.md`](checkpoint-coordination.md). ST-025A's AXI
quiesce/drain primitive is implemented and locally component-validated, including
depth-12 safety/reachability and synthesis. Native bindings keep it tied low.
ST-025B now implements the VirtIO producer's job pause/drain and distinguishes
job idle from per-port idle; its 137-check device bench and standalone positive/
negative local simulations pass. Other enabled writers still need real drain
acknowledgements. ST-025C1 implements external RAM prepare/publish/abort; 139
checks at delays 0/1/4/16, four rejecting oracles, external-mode synthesis and
legacy delay-16 dstore pass locally. C2 still must coordinate RAM with flash.
The external selected-bank/validity test fixture is not persistent metadata.
Identity/map-bound
reset recovery (D) and physical protection/health admission (E/ST-024) stay open.
Remote rerun `storamic-cd8cf2d11ad4` is incomplete after its tool prefix
disappeared between builds; local results do not promote that receipt.

**Owner / files:** **proposed** `g6lc_storamic/rtl/persistence/` journal/checkpoint/recovery
engines and health/admission controls. **Depends:** ST-008, ST-009, ST-017,
ST-018, ST-024.

Commit data and metadata generations in a defined order, retain the last valid
checkpoint, and recover with persistent module identity and mapping generation.
Drain all relevant interfaces explicitly. Refuse new durability promises when
protection is degraded; do not silently turn PMEM into volatile memory.

**Done when:** repeated power loss during save, restore and recovery, torn records,
full journals, bad blocks, resets and degraded energy satisfy the declared contract.
Recovery never exposes ambiguous generations or aliases block backup space.

### ST-026 — Qualify Linux PMEM, LIBNVDIMM and DAX behavior

**Owner / files:** native firmware/DTS integration and stock-Linux tests; all QEMU
firmware/discovery generation and launches under `g6lc_qemu/`.
**Depends:** ST-025, ST-012, ST-019; virtio-pmem additionally needs ST-040.

Expose only qualified protected ranges through supported native or virtio-pmem
discovery. Test LIBNVDIMM, Device DAX and Filesystem DAX with actual ordering and
crash recovery semantics — Device DAX and filesystem DAX are separate
compatibility gates. DAX is an access mechanism, not proof of durability or
application transaction atomicity, and never a generic durability claim.

**Done when:** cache-to-protected-domain flush/fence behavior and interrupted
recovery are proven at the declared boundary; volatile RAM, PMEM and block
capacity remain disjoint and accurately advertised.

### ST-027 — Freeze a separately keyed active-stick protocol

**Owner / files:** link/discovery architecture and **proposed** first-party link
contract package. **Depends:** ST-005, ST-013, ST-014.

Specify framing, CRC, credits, transaction/reset epochs, response reservation,
replay limits, timeout/error semantics and management. Set local stick controller
ownership and physical SerDes/clock boundaries. Use measured latency-bandwidth
requirements to size buffers; passive connector similarity is not qualification.

**Done when:** both endpoint contracts and negative/replay scenarios are complete;
a reset/retry cannot duplicate a committed operation. Pin geometry and electrical
keying stay elaboration/board properties, not runtime reallocations.

### ST-028 — Implement and qualify active carrier/stick endpoints

**Owner / files:** **proposed** `g6lc_storamic/rtl/link/` first-party endpoints and stick-side
composition of existing media engines; target SerDes bindings.
**Depends:** ST-006, ST-017, ST-027 and the selected ST-015/ST-016 media engines.

Reuse media and discovery contracts rather than duplicating controllers. Implement
credit/replay state, CDC/reset handling, errors and diagnostic counters; bind the
physical link separately. Reserve progress for responses and maintenance.

**Done when:** corruption, loss, replay, reconnect, asymmetric reset and saturated
traffic are tested; physical link training/BER/SI and measured service claims use
separate evidence. No automatic live hotplug or new persistence guarantee.

### ST-029 — Retired PCIe foundation target

Retired by the VirtIO-MMIO architecture decision. The former PCIe/CXL transport
work is not an active Storamic prerequisite. Replacement implementation is
ST-033..ST-041. Independent LibreCore PCIe users are unaffected.

### ST-030 — Retired CXL Type-3 target

Retired by the VirtIO-MMIO architecture decision. The former PCIe/CXL transport
work is not an active Storamic prerequisite. Replacement implementation is
ST-033..ST-041. Independent LibreCore PCIe users are unaffected.

### ST-031 — Close physical integration and capability release per profile

**Owner / files:** qualified `corev_apu`/`corev-mb` bindings, constraints, technology
artifacts, source/licensing closure, software manifests and capability grants.
**Depends:** the complete task/evidence chain for the selected released profile,
not every optional feature in this backlog.

Close target synthesis, STA/IO timing, CDC/reset, SRAM/macro mapping, scan/MBIST,
power/hold-up and SI/PI/connector requirements. Check configured slot/package
variants, default-off identity, and the required isolated aggregate regression.
Include FPGA/ASIC distinctions and any physically unavailable gates explicitly.

**Done when:** each advertised capability has an implementation, configuration,
software view, fault test, exact evidence identity and applicable physical result.
Unresolved black boxes/assumptions cannot count as qualified digital behavior;
qualified technology macros retain their actual views and boundaries. No model
or generic-cell area result becomes a fabricated-process or transport compliance claim.

### ST-032 — Re-evaluate after every milestone and create the next child tasks

**Owner / files:** this backlog, normative architecture, root traceability/todo,
and owner-specific queues such as `g6lc_qemu/AGENTS-todo.md`.
**Depends:** each milestone's captured results; repeats rather than waiting until M6.

Compare delivered behavior with the profile ledger and dependencies. Record
actual blockers, source/configuration/tool drift and remaining uncertainty. Split
the next epic into bounded child tasks with exact interfaces/files and independent
oracles before implementing it. Update this record rather than maintaining
competing task lists. Reuse frozen evidence for analysis; rerun only when a relevant
input changed or a required gate has not been executed.

**Done for each checkpoint when:** completed tasks cite their artifacts and limits,
failed/incomplete tasks stay open, the next small implementation batch is chosen,
and any new architecture decision is explicit. A roadmap checkbox is never evidence
that media, Linux durability, physical timing or transport compliance exists.
The current reassessed transport plan is ST-033..ST-041 below; the retired
ST-029/ST-030 epics are not prerequisites. The ten items in
`general-purpose-review.md` map onto existing owners — capacity/config
(ST-003/ST-033), payload/native (ST-011/ST-037), media (ST-018), queues/service
(ST-041), verification (ST-001/ST-032) and the VirtIO follow-ups — rather than
duplicating ten new epics.

## Modern VirtIO-MMIO transport and host tasks

These tasks are planned, not completed. They follow the settled
[VirtIO-MMIO decision](virtio-mmio.md): VIRTIO 1.4 CS01, modern `Version` = 2,
per-device MMIO apertures, split-ring DMA and native AXI RAM. No MMIO address,
IRQ, feature bit or boot support is granted by their presence.

### ST-033 — Pin the modern VirtIO-MMIO profile and role/config contract

**Owner / files:** `g6lc_storamic/architecture/virtio-mmio.md` normative contract;
**proposed** `core/` and `corev_apu` config projections plus the package-consumed
ABI. **Depends:** ST-005, ST-020.

Pin the 1.4 CS01 feature-negotiation set, modern `Version` = 2 transport, the
primary/peripheral role legality (proposed `StoramicIoEn`), aperture/IRQ
ownership, ring and resource limits, the DMA/protection/cache contract and reset
scope. Every mandatory/optional bit gets an implementation owner and tests;
unimplemented bits stay off. Invent no platform addresses or device IDs.

**Done when:** the profile and role contract is recorded, each negotiated bit
maps to an implementation owner plus negative tests, and the actual config
schema/default-off propagation is tested before any field is accepted.

ST-033 status (2026-11-04): **standalone contracts pinned. The role and config
contract is still open.** `virtio-mmio.md` now pins three contracts:
- ST-033A, the transport and register profile;
- the ST-035 split-ring engine: its DMA seam and window, processing order,
  fault-on-malformed policy, reset/epoch handling and formal obligations;
- the ST-036 virtio-blk backend: request layout, IN/OUT/GET_ID and UNSUPP for
  everything else, IOERR rules with no store side effect, ordering, and the
  volatile-store label.

`StoramicIoEn`, the native aperture and IRQ for virtio devices, and the
`compatible = "virtio,mmio"` DTS entry remain ST-033B/ST-037. The
`0x5000_1000+` pages and PLIC sources 11 and up are reserved for them (ST-010C).
The VendorID value is an open question.

### ST-034 — Implement modern MMIO transport state

**Owner / files:** **proposed** `g6lc_storamic/rtl/host/virtio/` register module and
its protocol benches. **Depends:** ST-033.

Implement AW/W-independent AXI-Lite register service, the feature/status
sequence (reset, ACKNOWLEDGE, DRIVER, FEATURES_OK, queue setup, DRIVER_OK),
feature selector banks, queue geometry/64-bit address registers, ConfigGeneration,
interrupt status/ACK races and reset quiescence. A register-only leaf advertises
no DMA and no usable device.

**Done when:** normative register/negative/reset tests pass with synthesis and
bounded safety evidence; inconsistent feature negotiation cannot start work and
reset cannot leak stale completions into reused queue state.

ST-034 status (2026-11-04): **implemented, scoped leaf evidence.**
`g6lc_storamic/rtl/host/virtio/g6lc_storamic_virtio_mmio.sv` implements the
ST-033A profile plus `reset_pending_o`.

Review fixes:
- a QueueNotify accepted on the same edge as a ring fault no longer pulses
  `notify_o`, because DEVICE_NEEDS_RESET gates it;
- the bench used do-while waits that hung after AR/AW handshakes, and its
  negative oracle did not fail;
- a hand-copied `run_leaf.py` splice dropped the `synth`, `formal` and
  `model-formal` stages. I restored them from the runner of
  `storamic-28471d23806c`; its SHA-256 matches that run's manifest;
- the formal wrapper's response-hold check and protocol assumptions compared
  the wrong cycles. They are now immediate checks of the current step against
  previous-step shadows.

Evidence: `storamic-17bd4896751f` passed the bench (89 checks, including the
negative oracle) and synthesis (265 cells, no latches or loops).
`storamic-c52b8eb1ac76` passed formal: depth-12 safety, plus covers for
DRIVER_OK (20), notify (24) and reset completion (20).

**Toolchain finding:** yosys `sat` ignores SystemVerilog `assume` without
`-set-assumes`. The virtio and vring formal stages now pass that flag.
- The older map, regs, model and discovery formal stages never did.
- Their safety proofs ran without assumptions. That is unconstrained and
  therefore still sound.
- Their covers may have been reached by traces that break the bus protocol.
  Re-running them with `-set-assumes` is open work.
- **Resolved 2026-11-04:** every Storamic formal stage now passes
  `-set-assumes`. `storamic-c3b6fcfda430` re-passed the formal, model, map,
  discovery and regs formal stages with assumptions active, safety and every
  cover included.

ST-035 status (2026-11-04): **implemented, scoped leaf evidence.**
`g6lc_storamic/rtl/host/virtio/g6lc_storamic_virtio_ring.sv` follows the
pinned contract:
- the window check is per aligned 8-byte beat, and per segment over
  `[addr, addr+len)`;
- the used element is written as one beat, or as two beats when it is 4 mod 8,
  before the `used.idx` write, and only then is `used_event` pulsed;
- `avail.idx` is re-read after every completion;
- reset withdraws an ungranted request and drains the outstanding beat;
- a fault enters a dead state until the epoch changes.

Evidence:
- **Bench:** `storamic-04eebb6de2f1` passed `tb_g6lc_storamic_virtio_ring`,
  47 checks over 255 DMA beats. An independent byte memory serves the DMA port
  with random grant and response latency and checks the window on every beat.
  Cases:
  - single request, back-to-back requests, ring wrap with N = 4,
    notify-while-busy;
  - eight fault kinds (cycle, `next >= N`, INDIRECT, readable after writable,
    `len = 0`, segment past the window, more than MaxSegs descriptors, ring
    outside the window), each with no DMA afterwards and no used write;
  - a backend fault;
  - reset during a walk with a slow response, then restarted indices;
  - a stale backend response after reset;
  - no DMA before DRIVER_OK or QueueReady;
  - the negative oracle.
- **Synthesis:** 385 cells, no latches or loops.
- **Formal** (`storamic-c52b8eb1ac76`, with assumptions active and
  QueueNumMax = 4): depth-12 safety proves that every beat stays inside the
  window, at most one beat is outstanding, a request is issued only while
  active, the used element precedes `used.idx`, the event follows `used.idx`,
  the walk count stays at most N, and idle means nothing is outstanding.
  Covers: a completed request (22), a fault (12), a reset during a walk (12).

Limits:
- 16-bit index wrap is not exercised; only the N = 4 slot wrap is.
- `VIRTQ_AVAIL_F_NO_INTERRUPT` is ignored, as the contract permits.
- The ring is not yet integrated with ST-034 or the native SoC (ST-037).

ST-036 status (2026-11-04): **first implementation, scoped leaf evidence.**
`g6lc_storamic/rtl/host/virtio/g6lc_storamic_virtio_blk.sv` implements:
- a header at any byte alignment;
- IN, OUT and GET_ID (20-byte `serial_i`), and UNSUPP for everything else,
  including FLUSH;
- IOERR checks before any store write: capacity, a non-sector-multiple
  length, direction, data alignment (a profile limit) and store readiness. A
  store error during a transfer still gives IOERR;
- a status byte written with a single byte enable after every data beat;
- `rsp_fault`, with no status write, when the status segment is not writable
  or the header is too short.

Evidence: `storamic-443baaaf708b` passed `tb_g6lc_storamic_virtio_blk` with
51 checks and synthesis (590 cells, no latches or loops). The bench uses
independent guest-RAM and store byte models with random latency. It covers:
- OUT of 1024 bytes at sector 3, then IN of the same data back to a different
  buffer;
- GET_ID with an unaligned header and an odd status address;
- FLUSH returning UNSUPP;
- six IOERR cases, five of which leave the store unchanged;
- two fault cases;
- reset in mid-transfer, then recovery;
- the negative oracle.

Limits:
- There is no ST-036 formal stage yet.
- A failed OUT is not rolled back.
- The store is the labelled volatile model.
- There is no integration with the ring, the transport or the SoC yet
  (ST-037).

### ST-035 — Implement split-ring execution and bounded AXI DMA

**Owner / files:** **proposed** first-party ring and DMA modules under
`g6lc_storamic/rtl/host/virtio/`. **Depends:** ST-006, ST-010, ST-033, ST-034.

First profile: one queue, one request in flight, queue maximum 128, split
virtqueues. Descriptor tables and buffers live in external shared RAM through
the explicit memory seam — never truncated into local SRAM. Enforce chain
bounds/cycle detection, direction/length/address-range validation including
full-width overflow, reserved completion/status storage before side effects, and
payload/status/used/IRQ ordering with reset epochs.

**Done when:** an independent DMA/byte oracle plus malicious descriptors, stalls,
index wrap and reset tests show zero unsafe memory accesses, with synthesis and
bounded safety/formal evidence. Unimplemented optional ring features stay off.

### ST-036 — Bind the virtio-blk request engine

**Owner / files:** **proposed** first-party block frontend/backend and model under
`g6lc_storamic/rtl/host/virtio/` and media path. **Depends:** ST-007, ST-018A,
ST-020, ST-035.

512-byte sector units for capacity and request offsets; IN, OUT, GET_ID and the
qualified FLUSH/cache-mode contract; stable per-stick identity across allowed
relocation; specified IOERR/UNSUPP status without capacity aliasing. The model
binds to ST-018A's volatile verification contract — physical flash need not
exist yet — while a labeled model media stays distinguished from qualified
physical media promoted only through ST-018B.

**Done when:** byte/block oracle, geometry/overflow/error/flush cuts and
one-drive-per-flash-stick evidence pass. No invented FUA opcode and no hardware
filesystem or automatic RAID.

ST-037A status (2026-11-04): **standalone device assembled, scoped leaf
evidence.** `g6lc_storamic/rtl/host/virtio/g6lc_storamic_virtio_dev.sv`
connects the transport, the ring engine and the backend:
- one AXI-Lite window, one level IRQ, one block-store seam;
- one shared DMA port: the backend has priority, one beat is outstanding, and
  each response is routed to the owner recorded at grant;
- transport `dma_idle` = both engines idle and nothing outstanding on the port.

Review fix to ST-034: before the driver starts (Status 0) the capacity
snapshot follows `capacity_i`. Previously it was latched only on
`capacity_update_i`, so a freshly booted device reported capacity 0.

Evidence: `storamic-f95d9b2d936b` passed `tb_g6lc_storamic_virtio_dev` with
75 checks over 411 DMA beats, plus synthesis (1,268 cells, no latches or
loops). The bench is an AXI-Lite driver model running the full VirtIO 1.4
MMIO initialization and split rings in an independent RAM model. It covers:
- OUT of 1 KiB, then IN back, compared byte for byte;
- GET_ID against `serial_i`;
- FLUSH returning UNSUPP;
- IOERR past capacity;
- interrupt and ACK on every request;
- device reset and re-initialization, then I/O again;
- a capacity event raising the configuration interrupt and ConfigGeneration;
- the negative oracle.

The same run re-passed the ST-034 bench.

Still open (ST-037B):
- native integration: a crossbar DMA master, a virtio page at
  `0x5000_1000+` instead of DECERR, PLIC source 11, and a
  `virtio,mmio` DTS node;
- `StoramicIoEn` role selection;
- a real store binding.

ST-037B status (2026-11-04): **native register presence, no media and no
DMA.**
- **Bridge:** `g6lc_storamic_ctrl_bridge` now demultiplexes two AXI-Lite
  pages. Page 0 is the control registers; page 1, `StoramicBase + 0x1000`, is
  the first virtio-blk transport. Offsets `0x2000..0xF_FFFF` still answer
  DECERR.
- **Test harness:** with `StoramicEn` it instantiates
  `g6lc_storamic_virtio_dev` with:
  - `device_usable_i = 0`, so DeviceID is 0 and Linux skips the device;
  - capacity 0 and a store that is never ready;
  - an unconnected DMA port (no grant), so no request can reach memory;
  - its IRQ routed to PLIC source 11 (`irq_sources[10]`), with
    `ariane_soc::StoramicVirtioIrqSource`/`StoramicVirtioOffset`.
- **Device tree:** `g6lc-storamic.dtsi` adds a disabled
  `virtio@50001000` node (`compatible = "virtio,mmio"`, interrupt 11).

Evidence:
- `storamic-c96c67bc1a59` passed `ctrl`/`ctrl-stall` with page-1 checks
  (virtio magic, version 2, DeviceID 0, a Status write and read-back, page 0
  still the regs block), synthesis of the bridge (191 cells), and integration.
- Harness lint `storamic-harness-lint-st037b-4c1e` (stock Verilator 5.008,
  delta `74e6e1b1…`) has zero errors with and without Storamic.

**Full Storamic suite (2026-11-04), on the same RTL and benches:**
- simulation: `storamic-0488fc89d360` passed protocol, integration, model,
  region, map, discovery, regs, ctrl, virtio, vring, vblk and vdev;
- config: `storamic-18d46d25e56e` passed config and ctrl, but its artifact
  pull returned rsync rc 11, so run_remote marked it incomplete;
- synthesis: `storamic-8473ef3a64a3` passed all ten wrappers;
- formal: `storamic-6dc81e63c935` passed all seven stages.

Between these runs only the runner changed: the source manifest now travels
as an uploaded file, because the inline `--env` JSON plus the config sweep
exceeded the Windows command-line limit and the launch failed without a run.
`bun test test/storamic.test.ts` (6/6) and `tsc` pass.

ST-037C step 1 (2026-11-04): **DMA adapter implemented, standalone
evidence.** `corev_apu/storamic/g6lc_storamic_dma_axi.sv` turns the virtio
single-beat DMA seam into single-beat INCR AXI4 transactions with a fixed ID.
It time-shares one crossbar slave port with an upstream master, the AI DMA:
- new upstream AW/AR are held off and every accepted upstream transaction
  completes before a Storamic beat is granted;
- upstream W beats and responses pass through;
- a request withdrawn by device reset returns the port to the upstream
  master.

`storamic-2ccb13cf22b5` passed `tb_g6lc_storamic_dma_axi`. An AXI4 slave
memory with random ready/latency serves 12 concurrent upstream 4-beat
write/read-back bursts and 50 Storamic beats. It checks:
- Storamic writes land byte for byte, including partial strobes;
- the upstream data is correct;
- zero Storamic transactions appear while an upstream transaction is in
  flight;
- the negative oracle fails as required.

It is not yet instantiated in the testharness.

ST-037C step 2 (2026-11-04): **native binding to the labelled volatile
model store (user-approved).** With `StoramicEn`, the testharness now binds
the virtio device to:
- `corev_apu/storamic/g6lc_storamic_model_store.sv`: 64 KiB of SRAM behind
  `tc_sram`, 128 sectors. Out-of-range accesses complete with an error and
  change nothing. It is not a persistence claim;
- `device_usable = 1`, capacity 128, serial `G6LC-STORAMIC-MODEL0`;
- `g6lc_storamic_dma_axi` sharing crossbar port 2 with the AI DMA (the
  `ai_dma_sh_*` signals feed both the APU TDMA join and the plain path), with
  the DMA window confined to DRAM.

Under `G6LC_AI_DRAM_ISLAND_PORT` the wide island DMA owns port 2, so the
device is reported unusable (DeviceID 0) and has no DMA. The opt-in DTS
fragment's `virtio@50001000` node is now `status = "okay"`.

Evidence: harness lint `storamic-harness-lint-st037c-91a3` (stock Verilator
5.008, delta `6d279408…`) has zero errors with and without Storamic.

Remaining:
- a native RTL test that drives the device through the CPU path;
- a stock-Linux boot with this DTS (ST-038);
- qualified media (ST-018) to replace the model store.

ST-037C step 3 (2026-11-04): **`StoramicIoEn` peripheral role.**
- `cva6_cfg_t` gains a derived `StoramicIoEn` field (not added to
  `cva6_user_cfg_t`, so no config-package literal changes).
  `build_config_pkg` sets it from `StoramicEn` or `G6LC_STORAMIC_IO`;
  `check_cfg` applies the AXI-geometry assert under either role and asserts
  `StoramicEn ⇒ StoramicIoEn` (`STORAMIC_ROLE_NORMALIZE`).
- `g6lc_storamic_ctrl_bridge` gains `CtrlPageEn`: with it low, page 0
  answers DECERR (W beats drained, len+1 R beats, no AXI-Lite traffic) and
  `ctrl_req_o` stays idle; page 1 is unaffected.
- The testharness keys the extra master port, rule and bridge on
  `StoramicIoEn` and passes `CtrlPageEn = StoramicEn`; the backend remains
  parameterised by `StoramicEn` (its control request is constant '0 in
  IO-only, which its legacy path requires). Board wrappers refuse either
  role; the DTS fragment notes the control node is primary-role only.
- Bench: a `ctrl-ioonly` variant checks page-0 DECERR with drained beats and
  echoed IDs, zero page-0 AXI-Lite activity for the whole run, a working
  page-1 virtio magic read, and `0x2000` still DECERR; `ctrl-synth` also
  synthesizes the `CtrlPageEn=0` wrapper.

Evidence: `storamic-b2d70c5715cd` passed `ctrl`, `ctrl-stall` and the new
`ctrl-ioonly` variant (23 checks, zero page-0 AXI-Lite handshakes) plus the
negative oracle; `ctrl-synth` gives 191 cells and the `CtrlPageEn=0` wrapper
192 cells, no latches or loops. `storamic.test.ts` and `tsc --noEmit` pass.
The three-config harness lint (default / skeleton / `G6LC_STORAMIC_IO`)
then ran as `storamic-harness-lint-st037c-io3` (delta `789abe85…`): zero
errors in all three.

ST-037C step 4 (2026-11-04): **CPU-driven native VirtIO test passes.**
`verif/tests/custom/storamic/storamic_virtio_blk.c` runs on the full
`ariane_testharness` (`cv64a6_imafdc_sv39`, `G6LC_STORAMIC_IO`, Verilator
fork `8c69f297a`), launched by `verif/tb/storamic/run_native_virtio.py` on
the gate-v3 snapshot plus the working-tree delta. The CPU:
- reads the VirtIO identity and capacity (128 sectors);
- performs the full status/feature/queue initialisation;
- writes 1 KiB at sector 5 and reads it back into a separate buffer;
- sees InterruptStatus and PLIC source 11 pending, and the ack clears it;
- checks GET_ID (`G6LC-STORAMIC-MODEL0`), and that a past-capacity read
  returns IOERR with the buffer untouched, followed by a valid read;
- resets the device, re-initialises, does a further round trip, and
  re-reads sector 5 (the model store is not reset with the transport).

Evidence: `storamic-native-virtio-09b` (delta `2d72c750…`): positive ELF
`*** SUCCESS ***` after 84,657 cycles; the `-DORACLE_NEGATIVE` ELF fails at
FAIL_IN_DATA (16) as required; no AXI error responses. Sim-only register and
DMA traces (`+g6lc_virtio_mmio_trace`, translate_off) are in
`g6lc_storamic_virtio_mmio.sv` / `g6lc_storamic_virtio_dev.sv`; the plusarg is
registered in `corev_apu/tb/g6lc_tb.cpp`.

Two core-level findings from this test, outside Storamic, that block a
Linux driver (ST-038) until resolved:
1. **MMIO ordering on this core.** With plain volatile accesses, three
   32-bit stores to adjacent registers (0x020/0x024) left the core as one
   errored write (SLVERR: the bridge accepts only single ≤32-bit beats), and a
   load of Status right after a store to it was answered without reaching the
   device. This matches the write-buffer same-word coalescing in
   `wt_dcache_wbuffer.sv` and the R3a store→load forwarding in
   `store_buffer.sv`/`load_unit.sv` (the forward is not gated by region).
   `cv64a6_imafdc_sv39` also declares no non-idempotent region. The test
   fences around every MMIO access; Linux `writel`/`readl` do not, so this
   needs a core fix (I/O must neither coalesce nor forward) by the LSU owners.
2. **DMA is not coherent with the L1 D-cache.** The D-cache is write-through,
   `fence` does not invalidate it (`DcacheFlushOnFence = 0`) and the config has
   no Zicbom, so a line the CPU has read stays stale after a device write
   (seen on the second completion's `used.idx`). The test reads
   device-written memory with `amoor.w x0`, which goes to memory. Linux needs
   a coherent DMA path (device writes invalidating or updating L1) or Zicbom
   with a `dma-noncoherent` device tree.

The primary-memory role (`G6LC_STORAMIC`) cannot run this test: it replaces
the simulation DRAM that `g6lc_tb.cpp` preloads through a fixed hierarchy,
so the Verilator build fails to compile (`storamic-native-virtio-02`). That is
ST-011B/ST-012.

Remote-host note: on 2026-11-04 every `/opt/testharness/runs` entry older than
two days was removed at the user's request (1,607 directories; list in
`/tmp/th-runs-deleted-20261104.txt` on the host). The patched Verilator runtime
was recreated at its pinned path by
`verif/regress/remote/rebuild_private_runtime.py`
(`private-runtime-rebuild-20261104`: header `dfbc2c4a…`, canary original
rc=1 / fixed rc=0). Run IDs cited above from before that date no longer have
remote directories; their pulled artifacts remain local.

ST-011B step 1 (2026-11-04): **primary-memory role runs programs on a
simulation model memory.**
- `G6LC_STORAMIC_MODEL` (only with `G6LC_STORAMIC`; the Makefile rejects it
  alone or with `G6LC_STORAMIC_SKELETON`, and attach `$fatal`s
  `STORAMIC_PROFILE_CONFLICT`) selects `ProfileModel` in
  `g6lc_storamic_soc_cfg_pkg::make_cfg`, with the window
  `[DRAMBase, DRAMBase + NUM_WORDS*8)` passed from the harness through
  `g6lc_ai_dram_backend` (`StoramicModelBase`) to `g6lc_storamic_attach`.
- New `corev_apu/storamic/g6lc_storamic_sim_mem.sv` binds the frontend's
  `mem_*` seam to the pulp `sram` (behind `tc_sram`): one command
  outstanding, completion one cycle after grant with the tag echoed,
  out-of-window or misaligned commands complete with an error and no write.
  It is a simulation binding — not a qualified memory controller, no
  persistence or physical-media claim.
- `g6lc_tb.cpp` preloads through
  `i_dram_backend.gen_storamic.i_storamic.gen_model_mem.i_sim_mem.i_sram…`
  under `-DG6LC_STORAMIC_MODEL_TB` (added by the Makefile); MEM_USER is
  compiled out (the model seam carries no user bits).
- The frontend refuses W beats with nonzero user bits and exclusive (lock)
  bursts. In the harness `axi_riscv_lrsc` drives `aw_lock = 0`
  (`axi_riscv_lrsc.sv:288`), so LR/SC and AMOs are resolved before Storamic,
  and the CPU's W user bits were zero in every run below.

Evidence:
- `storamic-0d8a136286ac` (integration): new `model` case through attach +
  sim mem — INCR and WRAP write/read bursts with partial strobes against an
  independent byte model, read-after-write at the top word, out-of-window
  SLVERR with memory unchanged (84 checks) — plus `model-conflict` and the
  negative oracle; all earlier integration cases still pass. The bench's
  model tasks first sampled ready in the same timestep as the valid
  assignment and missed the handshake, and drove nonzero W user bits; both
  fixed in the bench.
- `storamic-29c201f6d4c3` (config, synth): `g6lc_storamic_sim_mem` 10 cells
  (array behind `tc_sram`), no latches or loops.
- `storamic-native-primary-01` (`G6LC_STORAMIC+G6LC_STORAMIC_MODEL`, delta
  `98dc25ec…`): every instruction fetch, load, store and AMO goes to the
  Storamic model memory. The VirtIO test passes (control ID read at
  `0x5000_0000` included), its negative oracle fails at code 16, and
  `hello_world` exits 0.
- `storamic-native-io-10`: the peripheral-only run still passes on the same
  delta.
- `storamic-harness-lint-st011b-01`: zero errors for default, skeleton,
  `G6LC_STORAMIC_IO` and `G6LC_STORAMIC+G6LC_STORAMIC_MODEL`.
- `storamic.test.ts` (7 tests, including the new Makefile-rule test) and
  `tsc --noEmit` pass.

Timing/review note: no change to any synthesized production path. The model
profile adds the frontend's existing single-beat command path in front of the
memory; one command outstanding means one beat per two cycles, so this is a
functional, not a performance, binding.

ST-037C step 5 (2026-11-04): **coherent VirtIO DMA writes.**
- `g6lc_storamic_dma_axi` gains `InvalEn`: after a write's B response it asks
  the cluster CMO engine to invalidate the 64-byte block (L1 broadcast plus
  L2/L3 tags) and reports the write complete only after `done`.
- `g6lc_cluster` gains a Storamic writer port on that engine
  (`storamic_dma_inval_*`, present when `StoramicIoEn`; indices chosen at
  generate time). The harness enables it; the other cluster instantiations
  tie it off.
- The VirtIO test reads device-written memory with plain loads under
  `-DSTORAMIC_COHERENT_DMA` (the runner sets it).

Evidence:
- `storamic-8e25a7cbfe2f`: `vdma` and the new `vdma-inval` variant pass
  (129 checks each: one inval per write at the block address, completion
  only after done, none for reads or AI-DMA traffic); `vdev` passes.
- `storamic-native-io-coh-01` / `-02` (IO role, plain loads): PASS.
  Without the invalidation, the same plain-load test failed on the second
  completion (`storamic-native-virtio-07`).
- `storamic-harness-lint-coh-01`: zero errors in all four configurations.
- No synthesis check of the adapter yet: it has no standalone synth stage.

Timing note: each Storamic DMA write now waits for a CMO-engine block
invalidation, and StoramicIoEn builds instantiate the CMO engine.

**Open defect found by this step (core, not Storamic):** on the primary role
(`G6LC_STORAMIC+G6LC_STORAMIC_MODEL`) a CPU-only read-after-write check fails:
1 KiB of byte stores, read back (lines cached), then overwritten with zeros,
reads back the old data from the L1 (`storamic-native-primary-coh-04/-05`,
FAIL_CPU_RAW code 23, before any VirtIO activity). The AXI trace
(`+g6lc_storamic_mem_trace`, `g6lc_storamic_attach.sv`) shows every write
reaching the model memory with OKAY responses, and no read issued after the
zeroing stores, so the write-through L1 was not updated by stores whose write
acknowledgements arrived with Storamic's longer latency.
- The same test passes on the simulation DRAM (`storamic-native-io-coh-02`).
- It still fails with the Storamic CMO writer port removed
  (`storamic-native-primary-exp-noinv`), so the invalidation path is not the
  cause.

The likely location is the write-buffer ack/cache-update path in
`core/cache_subsystem/wt_dcache_wbuffer.sv`. That is a hypothesis: the
discriminating check is the same test on the simulation DRAM with added
write-response latency. Until this is fixed the primary role is not correct
for general software. `storamic-native-primary-01` passed only because its
access pattern did not hit this case.

Resolution (2026-11-04): **root cause found and fixed in the core.** The
`+smt_mem_watch` trace of `wt_dcache_wbuffer.sv` showed that a byte store
merging into a write-buffer entry whose earlier transaction was still in
flight cleared the entry's `checked` flag. The in-flight transaction then
acknowledged as unchecked (`wt_ack ... checked=0 hit=01`), so its bytes were
never written to the L1 and the line kept the old byte
(`storamic-native-primary-wt-01`). Storamic's write-response latency makes
that merge window common.
- Fix: a merge into a live entry for the same word keeps its tag-check
  result. Invalidations and refills still clear it.
- `G6LC_SIM_DRAM_DELAY=<n>` (new, default off) puts the pulp `axi_delayer`
  in front of the simulation DRAM for latency stress.

Evidence:
- `storamic-native-primary-fix-02`: the primary role passes the CPU-only RAW
  check, the VirtIO test with plain loads, the negative oracle and
  `hello_world`.
- `storamic-native-io-fix-01`: the IO role passes.
- `core-directed-*` (12 directed `verif/tests/custom/*.S` programs,
  `cv64a6_imafdc_sv39`):

  | Run | Fix | Result |
  | --- | --- | --- |
  | `core-directed-base-01` | without | `hyp8_h35_subword` hangs; `hyp8_amo_ready_order` hangs |
  | `core-directed-fix-01` | with | `hyp8_h35_subword` passes; `hyp8_amo_ready_order` still hangs |
  | `core-directed-delay-01` | with, `G6LC_SIM_DRAM_DELAY=10` | same as `core-directed-fix-01` |

  `hyp8_amo_ready_order` times out with and without the fix, so it is
  pre-existing and not attributable to this change.

The change has not yet been through the hyp8 aggregate or a repository-wide
gate.

Repository-wide gate v4 (`storamic-aggregate-gate-v4-55ae04ba`, snapshot
taken before the coherence and core fixes): 22 of 25 steps pass, including
lint on both targets (the Verilator fork fix is confirmed) and cv64a6
smoke. The 3 failures are outside Storamic:
- the `g6lc_fetch_realign` and `g6lc_fetch_iq` formal tasks, solver failure
  (as in v3);
- `smoke-cv32a65x`: the Spike reference simulation of `hello_world` produced
  no log within its 166 s limit before any RTL simulation ran (its `.iss`
  file holds only make's kill messages).

ST-037C step 6 (2026-11-04): **I/O access shape fixed in the core; Linux-
shaped accessors.**
- `core/store_buffer.sv`: no store-to-load forward for a load outside the
  cacheable regions.
- `core/cache_subsystem/wt_dcache_wbuffer.sv`: a non-cacheable store never
  merges into a live entry; a second store to the same word waits until the
  first drains.
- The VirtIO test now fences only before each register write and after each
  read (the Linux `writel`/`readl` shape). It also issues unfenced
  back-to-back 32-bit stores to `DriverFeaturesSel`/`DriverFeatures` (one
  8-byte word) and reads Status straight after writing it.
- `g6lc-storamic.dtsi`: the virtio node is `dma-coherent` (step 5 makes
  device writes coherent; the write-through L1 makes CPU stores visible
  before the doorbell).

Evidence:
- `storamic-native-io-mmio-01` (IO role): PASS, with no AXI error responses
  (before the fix the same register pattern produced a SLVERR and a lost
  FEATURES_OK).
- `storamic-native-primary-mmio-01` (primary role): PASS, with `hello_world`.
- `core-directed-mmio-01`: all 13 directed core tests pass.

The hyp tree does not have these two gates yet (AGENTS-todo).

Still open for ST-011B/ST-012: CPU/DMA ownership and atomics qualification
beyond these bare-metal programs, preload/boot of OpenSBI and Linux on the
primary role, a production memory binding (the DDR/LPDDR controller seams),
and board wrappers (they still refuse both roles).

During this step a cp1252 read/write in my edit script double-encoded the 12
non-ASCII characters in `ariane_testharness.sv`; they are restored, with byte
counts matching HEAD. Separately, `virtio-mmio.md` had picked up raw cp1252
bytes from an earlier edit; the file is now valid UTF-8 again.

ST-036 formal (2026-11-04): **done (bounded).**
`formal_g6lc_storamic_virtio_blk.sv` and the `vblk-formal` stage exist. The
first counterexample (`storamic-f11f6f3dce44`) found a real defect: after a
reset abandoned an outstanding beat, the backend accepted a new request and
issued a second beat while the first was still outstanding. `req_ready_o` now
also requires both ports to be idle. The `vblk` and `vdev` benches re-passed
(`storamic-153c3a20c6cf`).

Three further counterexamples were real RTL defects against the contract's
"no DMA outside the window" obligation, all fixed:
- data segment addresses were never window-checked
  (`storamic-51f3df1748c8`: an OUT read past the window end);
- an empty data segment still moved one beat, out of bounds
  (`storamic-ccf8d38d2a63`);
- a window whose end exceeds 2^64 let a GET_ID beat wrap to address 0
  (`storamic-f1537ca03a60`). The window end is now clipped at 2^64 and header
  addresses are formed in 65 bits.
The data-length sum is also 40 bits wide, so a wrapped 32-bit total cannot
pass the capacity check.

Evidence after the fixes:
- `storamic-2c518918edf5`: safety passes at bounded depth 12 with
  `-set-assumes`; the successful-response (depth 16) and status-write
  (depth 14) covers are reached. This is bounded checking from reset, not an
  unbounded proof.
- `storamic-55caff9fa689`: `vblk` (51 checks) and `vdev` (75 checks) benches and
  their negative oracles pass; synthesis gives 657 cells (`vblk`) and 1,335
  cells (`vdev`), with no latches or loops.
- `storamic-82fd1491065b`: the `vblk` bench now has directed IOERR cases for a
  data segment past the window end and an empty data segment (55 checks).
  The negative oracle still fails as intended. The wrapping-window case is
  covered only by formal, because the bench's window is fixed.

**ST-037C remains:**
- a first-party single-beat-to-AXI4 DMA master sharing the AI-DMA crossbar
  port without widening IDs;
- a qualified (or explicitly labelled model) store and identity;
- `device_usable_i` driven from discovery;
- enabling the DTS node only once the path is usable.

### ST-037 — Integrate native MMIO, DMA, IRQ and role selection

**Owner / files:** `corev_apu/storamic/` attachment plus SoC map/config/DTS
projection. **Depends:** ST-011, ST-012, ST-034, ST-035; the full block path
additionally needs ST-036.

Wire the MMIO transport, DMA master, interrupts, configuration projection and
reset-domain integration natively. The proposed `StoramicIoEn` peripheral role
must not relax `StoramicEn` primary-memory conflicts; one shared controller owns
the slots when both roles are enabled. Establish a coherent DMA path or a proven
DMA-API/cache-maintenance path and enforce the DMA domain — no `dma-coherent`
DTS on an unproven path.

**Done when:** full native data movement, IRQ/reset/config propagation and
default-off preservation are shown; no fake DTS device or capacity is emitted.

### ST-038 — Qualify stock Linux and package-owned RTL block bridge

**Owner / files:** `g6lc_qemu/` exclusively for generation/launch/reference;
`verif/` simulator-side peer. **Depends:** ST-019, ST-022, ST-023, ST-036, ST-037.

Use stock `virtio_mmio`/`virtio_blk` for enumeration, IO, FLUSH, configuration
changes and multi-drive software aggregation against the RTL bridge. A deliberate
injected RTL fault must change the guest result. Record exact kernel/QEMU/SBI/
profile/bridge identities per run.

**Done when:** guest results correlate to the declared RTL/media path with
fault-cut evidence; model and reference results stay distinctly labeled and never
establish physical media or coherence.

### ST-039 — Implement optional virtio-mem lifecycle

**Owner / files:** **proposed** region lifecycle manager under
`g6lc_storamic/rtl/host/virtio/` plus native integration. **Depends:** ST-008,
ST-009, ST-012, ST-033, ST-035, ST-037.

Reserved address windows only, with actual RAM backing and ordinary RAM
semantics. Implement PLUG/UNPLUG/UNPLUG_ALL/STATE over the control queue with
page/block alignment and OS offline cooperation. No duplicate boot-RAM
publication, no live remap or forced shrink; a device control reset is distinct
from system reset and must not destroy live RAM. `g6lc_qemu/` owns any missing
MMIO memory-device proxy for the pinned QEMU.

**Done when:** source-pinned kernel/platform support plus failed/offline/
pinned-page/removal tests pass — not merely a `requested_size` register.

### ST-040 — Implement optional virtio-pmem persistence interface

**Owner / files:** **proposed** virtio-pmem device under
`g6lc_storamic/rtl/host/virtio/` plus persistence integration. **Depends:**
ST-024, ST-025, ST-033, ST-035, ST-037.

Expose a genuinely byte-addressable mapped range and an asynchronous flush queue;
completion must mean preceding writes reached the declared persistence domain
across reset and power failure. No raw-NAND-as-RAM fiction. Separately qualify
LIBNVDIMM, filesystem DAX and Device DAX against the kernel and transport. The
missing QEMU MMIO memory-device support is an explicit `g6lc_qemu/`-owned gap.

**Done when:** power/reset recovery and flush cuts plus software mappings are
proven at the declared boundaries; DAX alone establishes none of them.

### ST-041 — Scale queues, channels and measured service

**Owner / files:** queue/channel resource design plus measured evidence.
**Depends:** ST-013, ST-036, ST-037; Linux results additionally need ST-038.

Separate `MaxMediaChannels`/channel allocation from
`MaxQueuesPerDrive`/`QueueSizeMax`/in-flight/DMA-credit controls. Add fairness,
completion-progress guarantees, capacity-grow notifications via
ConfigGeneration, no live remap and no initial online shrink.

**Done when:** same-workload bytes/latency/occupancy/errors/fairness evidence
plus synthesis/resource and applicable physical results exist; queue count is
never reported as a bandwidth claim.

## Common completion rule and development efficiency

Every RTL task carries config legality/default-off checks, first-party dependency
closure and licensing/attribution, synthesizability/timing/CDC notes, bounded
ownership/reset/error tests, testmode/DFT hooks, observable events/counters and
software/map alignment where applicable. Keep first-party portable digital RTL
separate from physical macros and from verification-only behavioral models.

Use the smallest faithful leaf first, then its native integration seam, then stock
software and physical gates. Reuse the existing benches/runner and add a shared
model bench rather than a file per test case. Keep independent reference models
and mechanism-specific negative controls; a scoreboard must not simply copy the
RTL routing implementation. Expand burst/width/slot/fault coverage at the stage
where the behavior first exists. Do not defer all verification until integration.

Parallelize disjoint work after contracts freeze: baseline fixes versus contract
writing; physical profile research versus model RTL; QEMU reference/ADR work versus
media engines. Serialize edits to shared packages/top/flists and budget all remote
workers against available resources. Cache only with complete dependency identity;
reuse binaries for runtime-only cases, never across changed elaboration geometry.
Avoid broad cleanup-prone regressions on each edit, but execute required aggregate
gates in isolated snapshots before milestone promotion. Preserve failed evidence
and collect existing jobs instead of retrying or launching duplicates.

## Evaluation of the original plan

The original layering and M0 refusal-first choice remain sound. The next useful
increment is a real one-region model through a complete adapter, not transport
registers or successful responses backed by a shadow host buffer. Preserve the skeleton
regression as a separate profile while growing the executable path.

Four refinements are required: split request-service readiness from media readiness;
make native preload/atomic/DMA ownership a concrete gate; strengthen runtime and
dependency identity; and decide the block transport early — now resolved by the
VirtIO-MMIO decision rather than a PCIe dependency.
The model and physical SRAM seams must be explicit so M1 does not become a silent
production fallback. Map/discovery/control contracts must precede Linux-facing
capacity publication. Persistence and the host transport remain independent
advertised capability gates, not consequences of having RAM plus flash or an
MMIO aperture.

M0 is not retrospectively marked fully qualified: the five configuration
failures, the timing-tool type error and selected ST-001..ST-004 gates now have
current evidence, but the interrupted aggregate run remains open. ST-029/ST-030
are retired by the VirtIO-MMIO decision rather than decomposed.
ST-032 is the mechanism for creating further tasks from measured outcomes rather
than pretending today can fix every future queue size, register or PHY detail.
Sequence exhaustion in the model profile is intentionally fail-safe; before
long-running native RAM, ST-009/ST-012 must define and prove quiescent sequence
renewal — stop admission, drain contexts and binding, advance the reset
generation, then reuse sequence space without clearing RAM. Widening or silently
wrapping the counter is not the lifecycle protocol.

## ST-032 reassessment (2026-11-04, after ST-037C step 6)

### Delivered, with evidence (selected-stage, not aggregate qualification)

| Area | Tasks | State | Evidence (latest) |
| --- | --- | --- | --- |
| Standalone refusal, profiles, model frontend | ST-001A, ST-002, ST-004A, ST-005..ST-007 | done | `storamic-be8f643dc369` (sim), `storamic-fac26aab948c` (synth+formal) |
| Region map, routing, runtime map | ST-008A..C, ST-010B | done | same suite |
| Discovery lifecycle (synthetic fixture) | ST-009A/B | done; real pad binding is ST-014 | same suite |
| Control registers, native control page | ST-010A, ST-010C | done | `storamic-b2d70c5715cd` |
| VirtIO-MMIO transport, split ring, virtio-blk backend | ST-034..ST-036 | done (bounded formal) | `storamic-2c518918edf5` |
| Native VirtIO device, DMA, coherent writes, roles | ST-037A..C (steps 1-6) | done on the labelled volatile model store | `storamic-native-io-mmio-01`, `storamic-native-primary-mmio-01` |
| Primary-memory role on a simulation memory | ST-011B step 1 | functional for bare-metal programs | `storamic-native-primary-mmio-01` |
| Core defects found by Storamic bring-up | — | fixed in `core/`: WT merge `checked`, LR/SC window, I/O forward, I/O merge | `core-directed-mmio-01` (13/13) |

### Not delivered; ranked by what unblocks the most

1. **Aggregate gate on current sources** (ST-001B/ST-003). Gate v5 (22/25)
   predates the issue-stage and I/O fixes. Its three failures (two fetch
   formal solver failures, a cv32a65x Spike-only timeout) are outside
   Storamic. Next: rerun on a fresh snapshot.
2. **Linux on RTL** (ST-038, ST-023). Device side is ready: `virtio,mmio`
   node `dma-coherent`, Linux-shaped register accesses pass. Blockers: the
   Linux payload directory was deleted with the old runs and must be
   rebuilt; a bounded boot budget on the IO role is the first target.
3. **Primary role beyond bare metal** (ST-011B/ST-012). Next: OpenSBI to
   `sbi_init` on `G6LC_STORAMIC+G6LC_STORAMIC_MODEL`, then atomics
   qualification across CPU and DMA, then sequence-space renewal before
   long runs (fail-safe today).
4. **Persistence contract before media** (ST-018, ST-024). Next bounded
   batch, implementable without physical media: plumb VIRTIO_BLK_F_FLUSH
   end to end behind a store-reported durability capability. The capability
   stays 0 for the model store, so FLUSH stays unoffered and nothing is
   claimed.
5. **Multiple devices** (one VirtIO page per stick, PLIC 11+n) and
   discovery-driven `device_usable_i`/capacity (ST-037 remainder, ST-014).
6. **Physical media and PHY** (ST-014..ST-017, ST-027/028, ST-031): blocked
   on a selected electrical/media profile; no change.
7. **Optional VirtIO memory devices** (ST-039 virtio-mem, ST-040 virtio-pmem)
   and queue scaling (ST-041): after 2-4.

### Architecture decisions recorded in this checkpoint

- Device writes are made coherent by the cluster CMO engine (block
  invalidate before completion); device reads rely on the write-through L1.
  A write-back L1 configuration must add clean-before-read or drop
  `dma-coherent`.
- I/O accesses are never merged or forwarded in the core; drivers may use
  the Linux `readl`/`writel` shape.
- The primary role's simulation memory is a binding, not a controller; the
  production binding is the DDR/LPDDR seam (ST-015).

### Next batch (chosen)

- ST-037D: FLUSH plumbing (item 4). Interfaces:
  - store seam gains `st_durable_i` (capability), `st_flush_req_o`,
    `st_flush_ack_i`, `st_flush_err_i`;
  - the transport offers feature bit 9 only when `st_durable_i`;
  - the backend executes type 4 only when the driver accepted bit 9
    (otherwise UNSUPP as today);
  - status OK after `st_flush_ack_i`, IOERR on `st_flush_err_i`.
  Oracle: the `vblk`/`vdev` benches with a durable fixture and the
  existing non-durable cases unchanged.
- ST-001B rerun on a fresh snapshot (item 1).

ST-037D (2026-11-04): **FLUSH plumbing behind a durability capability.**
- `g6lc_storamic_virtio_mmio`: `flush_cap_i` offers VIRTIO_BLK_F_FLUSH
  (feature bit 9, `DeviceFeaturesSel` 0). FEATURES_OK accepts only offered
  bits.
- `g6lc_storamic_virtio_blk`: new seam `flush_en_i`, `st_flush_req_o`,
  `st_flush_ack_i`, `st_flush_err_i`.
  - With FLUSH negotiated, type 4 raises a held flush request after every
    earlier store write has completed: status OK on ack, IOERR on err.
    Without FLUSH it answers UNSUPP as before.
  - A flush in progress keeps `idle_o` low across a device reset until the
    store answers.
- `g6lc_storamic_virtio_dev`: `st_durable_i` drives the capability; the
  harness ties it to 0 (the model store is volatile), so nothing new is
  advertised.

Evidence: `storamic-a08362cc7b07` — the `vblk` bench passes 60 checks,
including the new flush cases: OK after the store ack, exactly one request
after earlier writes, IOERR on store error, UNSUPP when not negotiated, no
store write. `virtio`, `vdev` and `ctrl` pass, as do the virtio/vblk/vdev
synthesis and the virtio/vblk formal stages (formal ties the new inputs
to 0, so it does not cover the flush path yet).
`storamic-native-io-flush-02`: the native VirtIO test still passes, and its
negative oracle fails at code 16. `storamic-harness-lint-flush-02`: zero
errors in all four configurations. The `-01` runs used a delta that left
out the files committed in `d465cc28c` (the remote snapshot predates them);
the delta builder now includes everything changed since `f2b70d219`.

Still open for persistence: a durable store binding (ST-018) that can drive
`st_durable_i` honestly; flush formal coverage; FUA/write-cache-toggle
features stay unoffered.

ST-037D formal coverage (2026-11-04, in flight):
- `formal_g6lc_storamic_virtio_blk.sv` gains `FlushEn`, a free
  `st_flush_ack_i`/`st_flush_err_i` environment (assumed only while a
  flush request is held), a `cover_flush_o` cover point, and a
  `flreq |-> !dreq && !sreq` safety property. A `..._blk_flush` variant
  binds `FlushEn=1`; the new `vblk-flush-formal` stage runs it at
  depth 14/16.
- The base `vblk-formal` safety depth was raised 12->14 so both variants
  search the same space.
- **Latent wrapper defect found at depth 14:** `status_inflight` was not
  cleared on `reset_pending_i`, so a status write abandoned by a device
  reset credited `status_wr_done` when its response returned later; a
  subsequent request's fault response then violated
  `rs_valid && rs_fault |-> !status_wr_done`
  (`storamic-66fd7055dcc4`, `storamic-4ea37ce761bf`). Fixed in the
  wrapper; the RTL itself is unchanged. `dout`/`sout` were removed from
  the flush property since abandoned beats may legally linger.
- Reruns: `vff4` (vblk-formal + vblk-flush-formal at the new depths).
- `storamic-aggregate-gate-v6` launched on the current tree (in flight).

## ST-032 reassessment checkpoint (2026-11-04, inferred-decision pass)

Two implementation gaps closed by inference from the pinned contracts
(see g6lc_storamic/architecture/decisions.md for the full register):

- **Sequence renewal (D1).** `g6lc_storamic_axi_memory.sv`: exhaustion
  (allocated == SeqLimit) already stopped admission; now a full drain
  (!inflight_o) clears `allocated` and advances an 8-bit `epoch` stamped
  in `txn_id_t`, so reused seq numbers cannot alias stale completions.
  Epoch saturation is a documented fail-stop, never a wrap. RAM contents
  untouched. `events_o.seq_renew` pulses for observability; a renewal IRQ
  is a contract-v5 candidate.
- **Durable backend + stick composition (D2/D3).**
  `corev_apu/storamic/g6lc_storamic_durable_store.sv` models the flash
  chip's commit boundary (write-back staging, flush drains to tc_sram,
  spill-on-full, read-own-writes). `g6lc_storamic_model_stick.sv` owns the
  flash chip and publishes one identity/geometry to both transports; the
  harness derives device_usable/capacity/serial/durable from it. FLUSH is
  now offered and exercised by storamic_virtio_blk.c (negotiates bank-0
  bit 9, issues T_FLUSH). Still a model: no power-loss domain or journal
  replay (ST-024/025).
- Formal rerun at depth 14/16 passed after the wrapper shadow fix:
  `storamic-ae7ba275f8bb`. Aggregate gate v6 in flight.

Open asks (nothing internal blocked): VendorID allocation, ST-014
electrical/media profile, ST-015-017 physical media, ST-024-026
persistence domain, discovery-driven device_usable (needs ST-014),
multi-queue after a measured baseline, contract-v5 bit candidates.
- `storamic-native-io-stick-04` PASS: positive ELF completes the full
  VirtIO sequence including negotiated FLUSH (T_FLUSH returns OK);
  negative oracle fails at FAIL_IN_DATA (16) as required.

## Bandwidth + persistence seam (2026-11-04)

- `g6lc_storamic_sim_mem` `RspDelay` (plumbed `g6lc_ai_dram_backend` →
  attach): RAM-channel bandwidth, 1 beat per RspDelay+1 cycles, default 0.
- `g6lc_storamic_durable_store` `RspCycles` (interface stretch) +
  `CommitCycles` (media program time per staged entry) + `power_cut_i`
  (drops uncommitted staging, errors in-flight completion; committed
  contents survive — the ST-024 persistence domain boundary).
- `g6lc_storamic_model_stick` publishes FlashRspCycles/FlashCommitCycles/
  StageEntries and exposes `power_cut_i`; the tb ties power_cut 0 pending
  ST-025.
- decisions.md gains the media/persistence track decomposition (slices
  A–D): commit boundary DONE, bandwidth knobs DONE, power-loss domain seam
  in place, recovery/media external.
- `storamic-native-io-stick-05` PASS: same verdict after the bandwidth
  knobs and power-cut seam (defaults preserve the prior behavior).
- `storamic-native-io-stick-07` PASS: durability boundary exercised end to
  end — committed+spilled data survives the MMIO-triggered power cut, the
  staged tail drops, and the store keeps serving afterward.
- `storamic-native-io-stick-08` PASS: journal-backed commit semantics
  (entry in-commit survives the cut and replays; uncommitted staging
  drops) — durability test unchanged and green.
- `storamic-native-io-stick-10` PASS (CommitCycles=8): mid-drain power
  cut replays the journaled head, drops the staged tail, and the held
  flush still completes; mid-commit semantics exercised end to end.
- `storamic-native-io-stick-11` PASS (CommitCycles=8): ST-025 recovery
  surface landed — cut_count_o/commit_gen_o counters exported through the
  stick (sim-observable; a real software ABI is a contract-v5 item).

## Stick save/restore + durable-store unit bench (2026-11-04)

- **Stick-level save/restore (ST-025, model).** The stick's RAM chip is
  now honestly volatile: `g6lc_storamic_sim_mem` clears its contents on
  `power_cut_i` (reads report zero — the array is lost) and owns a
  save/restore scan engine — `save_i` walks the array into a behavioral
  shadow (the flash-backed image, ~NumWords+1 cycles through the tc_sram
  port, holding the command seam off) and `restore_i` writes it back only
  when a save completed (`saved_q`; a save torn by a cut invalidates its
  shadow). `restore_done_o` pulses on completion. The flash side got a
  matching stick-owned drain: `durable_store.save_i` latches a drain of
  all staging (same commit path as flush, no requester handshake) and
  `save_done_o` pulses when the last entry commits. Plumbing:
  `sim_mem` → `g6lc_storamic_attach` → `g6lc_ai_dram_backend`
  (`storamic_power_cut_i`/`storamic_save_i`/`storamic_restore_i` →
  `storamic_save_busy_o`/`storamic_restore_done_o`) → testbench.
- **Testbench triggers.** New reserved-region MMIO triggers beside the
  power-cut ones: `StoramicBase+0x3010` (stick save) and `+0x3018`
  (restore). Save/restore/power-cut are top-level pulses wired to both
  the stick (flash staging drain + RAM shadow) and the backend (RAM
  chip), tied off when `StoramicIoEn=0`.
- **`dstore` unit bench** (`verif/tb/storamic/tb_g6lc_storamic_durable_store.sv`,
  `run_leaf.py`/`run_remote.py` `dstore` stage): 30 directed checks over
  the durable store + sim_mem — reset/staging read-own-writes, byte-enable
  merge, OOB grant+error, staging-full oldest-spill, flush drain +
  generation count, `CommitCycles>1` mid-drain cut with journal replay of
  the in-commit head + staged-tail loss + recovery, RAM volatile loss,
  save → cut → restore round-trip, and a torn-save invalidation.
  Result: **PASS 30/30** locally (WSL Verilator v5.008) and remotely on the
  pinned toolchain (`dstore` leaf stage). One bench-side bug found during
  bring-up: the grant is combinational, so the bench holds the request
  until `rvalid` (registered) rather than sampling `gnt` at a clock edge;
  a posedge-resumed task sees a stale `gnt` vs the clocked process.
- `storamic-native-io-stick-12` PASS (CommitCycles=8): end-to-end
  regression unchanged after the save/restore plumbing.
- `storamic-aggregate-gate-v6` verdict: `aggregate-fail` with
  `status_counts {fail: 3, pass: 22}` — all three failures are the
  previously-attributed non-Storamic items: `g6lc_fetch_realign` and
  `g6lc_fetch_iq` covers still die at the z3 resource limit (~64 GB
  solver RSS), and `smoke-cv32a65x` still times out (exit 130) — the
  same three issues recorded for the earlier gates; nothing
  Storamic-related failed.

## ST-012 atomic/ownership evidence (2026-11-04)

- Preload contract review: `g6lc_tb.cpp` pokes
  `gen_storamic.i_sim_mem.i_sram...m_storage` directly for the
  `G6LC_STORAMIC_MODEL_TB` build — that writes the *actual modeled
  backend array* (not a shadow host buffer), and all subsequent CPU
  traffic flows through the Storamic frontend — consistent with
  ST-012's "initialize through the selected modeled backend".
- `storamic_virtio_blk.c` gained `atomics_check()` (new `FAIL_ATOMIC`
  code): an LR/SC spin-increment loop (reservation + store-conditional
  round-trip), an address-keyed SC that must fail on a different
  address without storing, and `amoadd`/`amoswap`/`amoand`/`amoor`
  checks on both the loaded old value and the resulting contents. In
  the primary role every access traverses Storamic through
  `g6lc_axi_atomics_wrap`'s exclusive monitor into `sim_mem`.
- `storamic-primary-atomic-02` PASS — but a later review caught that
  its `native-defines.txt` never reached the run (the `--data` dir
  form is not consumed): it actually ran the default `G6LC_STORAMIC_IO`
  role, so the atomic evidence is valid but NOT on the primary path.
  (`storamic-primary-atomic-01` died at the C compile — `sc.w` needs
  the three-operand `sc.w rd, rs2, (rs1)` form; fixed.) The sweep runs
  below re-deliver defines as files.
- `storamic-io-atomic-02` PASS: peripheral-role regression unchanged —
  positive pass, negative oracle at `FAIL_IN_DATA` (16).
- ST-012 status: CPU fetch/load/store (existing scratch + hello_world),
  preload-through-the-modeled-backend (reviewed — `g6lc_tb.cpp` pokes
  `i_sim_mem`'s array, not a shadow buffer), LR/SC + AMO ownership
  evidence, and DMA-coherent reads all carry evidence now. Remaining:
  a *competing-writer* case (device DMA write to the reserved address
  between LR and SC — needs the DMA side driven mid-sequence), fences/
  reset coverage, and the multi-hart/multi-agent question which the
  single-hart model cannot express.

## ST-012 atomic finding + ST-013 bandwidth sweep (2026-11-04)

- **`storamic-fix-*` run hygiene:** `--data <dir>` is not consumed —
  defines must be passed as files. `storamic-primary-atomic-02` earlier
  ran the IO role by accident; `storamic-primary-atomic-04/05` with the
  defines delivered show the real primary-path result.
- **NEW DEFECT — WT D-cache stale HIT across an AMO (primary path).**
  `atomics_check` deterministically fails at sub-6 (`amoand`) on
  `G6LC_STORAMIC+G6LC_STORAMIC_MODEL` — `tohost=0x6360061A`
  (`FAIL_ATOMIC | (6<<8) | (var<<16) | (lr<<24)`): the AMO itself
  completed correctly (memory=96, old=99), but the immediately
  following plain load returned a stale value once, then 96 — two
  consecutive `volatile` loads disagree. Mechanism (evidence-backed):
  AMOs traverse `wt_dcache_missunit` as `DCACHE_ATOMIC_REQ` — always
  uncached to memory, never touching the tag/data arrays — so a
  previously-cached line keeps its old value until the coherence
  back-invalidate lands. A load in that window hits the stale line.
  `sim_axi`'s shorter write→inval round trip hides it; Storamic's
  slower backend widens the window into a deterministic fail. `hello`
  passes on the same build (only the atomic test sees it).
  The Storamic frontend itself is NOT the cause — it serializes
  `mem_*` commands, so no read/write reordering is possible downstream.
  This is a core-side ordering hole for cache-line invalidation on AMO
  completion — needs the wt_dcache owners' design call (invalidate or
  update the cached line before the AMO retires, or stall hits behind
  the in-flight update). The test is the deterministic repro.
- **FIX attempt + deeper finding:** `wt_dcache_missunit` had the right
  precedent — `cas_inv` drops the L1 line for the AMO paddr on the
  local `AMOCAS.D` completion, "uncached store does not update D$" —
  but the generic ATOP path (`AMO_WAIT → IDLE` on `amo_ack`) lacked
  it. `cas_inv` now fires on the generic `amo_ack` too, and a new
  `amo_paddr_q` latches the paddr at request acceptance in case
  `operand_a` is released before ack. **Still fails identically**
  (`storamic-primary-atomic-07`, `-08`, tohost `0x6360061A`) — so the
  stale copy is NOT (only) in L1: the L1 line is dropped at AMO
  completion yet the post-AMO refill still reads the old value once.
  Conclusion: the stale copy is in the L2/coherence hierarchy — the
  ATOP write reaches `sim_mem` without updating/dropping the L2 line,
  and the L2 back-invalidate lags the AMO retirement on this backend's
  timing. The real fix belongs at the coherence/L2 level (the AMO
  write must invalidate or update the line at every cache level before
  the response retires, or the L2 must treat the ATOP write as a
  line-update) — a cache-team design call. The L1 `cas_inv`
  generalization is kept (correct on its own terms: an L1 hit can no
  longer serve stale data behind the AMO either).
  Deterministic repro: `storamic_virtio_blk.c` `atomics_check` sub-6
  on `G6LC_STORAMIC+G6_STORAMIC_MODEL`.
- **ROOT CAUSE + FIX** (`storamic-primary-atomic-09..25`, traced via
  `[sto-mem]`/`[sto-axi]`/`[sto-awref]`/`[sto-werr]` harness probes):
  `atomics_check` sub-6 was NOT a stale cache line — the post-`amoand`
  load genuinely read the pre-AMO value because **the `amoand` write
  was dropped by the Storamic frontend**. Evidence:
  - `[sto-axi]`: `amoadd`/`amoswap` writes get `B resp=0`; `amoand`'s
    `AW id=3` + `W=0x60` gets `B resp=2` (SLVERR) — never lands.
  - `[sto-werr]`: `w_fault=0 mal=1` with `wuser=ffffffffffffffff` —
    `malformed_w` fired solely on `req_i.w.user != '0`. The AMO's
    converted W beat carries a nonzero user (operand metadata from the
    upstream atomics path — `amo_user`/`axi_wr_user`), and the
    frontend's strict `w.user != '0` clause treats it as a protocol
    violation → SLVERR → silent write drop → the next load reads the
    pre-AMO value. AXI `w.user` is free-form sideband — nonzero is
    legal — so the check was over-strict.
  - **Fix:** removed `|| req_i.w.user != '0` from `malformed_w` in
    `g6lc_storamic_axi_memory.sv` (the `w.last`/`w_left` and
    `strb&~lanes` protocol checks remain). The `cas_inv` +
    `amo_paddr_q` L1 work is kept (correct generalization of the
    CAS.D line drop to all ATOP AMOs).
  - Phantom `a=0` AW accepts (`id=10`/`id=20`, refused correctly by
    `request_legal`) appear upstream of the wrap on the dram channel —
    real other-master/DMI traffic, unrelated to the fault.
  - Verification pending: the remote build stalled on three
    consecutive runs (`storamic-primary-atomic-24/25/26`) — the
    Verilator/make child process dies silently after the
    `commit_stage` latch warning while `run_native_virtio.py` waits on
    the dead child (host memory fine at 114G free, no OOM). The stall
    is byte-identical across runs → build-infra failure, not a code
    verdict. The `malformed_w` fix is proven by the `[sto-werr]`
    diagnostic: it was the *only* clause matching (`strb`/`lanes`/
    `last`/`w_left` all clean, `wuser=FFFF`). `storamic-io-atomic-08`
    PASS proves the shared path is unharmed. To re-verify:
    rerun `storamic-primary-atomic-*` once the remote build host is
    healthy — expect `atomics_check` to pass end-to-end now.
  - Kept changes: `wt_dcache_missunit` `cas_inv` on every ATOP AMO +
    `amo_paddr_q` latch; `g6lc_storamic_axi_memory` `malformed_w`
    drops `w.user != '0`; `storamic_virtio_blk.c` `atomics_check`
    split into granular sub-codes (LR/SC spin, addr-keyed SC,
    AMO add/swap/and/or + a stale-read visibility probe).
- **Historical ST-025 claim -- superseded by the source audit.** The following
  describes an earlier implementation attempt, not qualified persistence or
  a protected ABI; see `development-status.md` for the current gaps. The
  `g6lc_storamic_durable_store` now exports a persistent journal
  record (`journal_gen_o`/`journal_id_o`: the last committed entry's
  address + the epoch it committed under, written atomically with each
  commit-step retire) so a host comparing `journal_gen_o` vs
  `commit_gen_o` distinguishes a committed epoch from a torn write —
  the version-map semantic the overlapping-commit journal area needed.
  `save_i`/`restore_i` are also gated by a protected ABI: honored only
  while `unlock_key_i == 32'h5354524D`, so a stray write to the trigger
  address cannot checkpoint/roll back. Plumbed store → stick
  (`unlock_key_i`/`restore_i`/`restore_done_o`/`stick_journal_*`) → tb
  (new `+0x3020` MMIO key register; AW-pending + W-data latch). The
  `dstore` bench ties `unlock_key_i` to the ABI magic so the save
  path stays exercised; a remote leaf-verify is pending on the build
  host (same infra stall that blocked the atomic verify — syntax is
  clean by inspection). Remaining ST-025 is genuinely design-level:
  a multi-entry persistent journal for *overlapping* commits (the
  current model is sequential, so the single-entry journal record is
  complete for its discipline) and ST-026 Linux PMEM qualification
  against the now-protected ABI.
  - **Remote-verify note** (`storamic-dstore-abi`): the remote build
    host ran out of disk during the AMO/leaf verify — `/opt/testharness`
    was 100% full (833G/878G); the Verilator child dies silently at the
    `commit_stage` latch warning when it can't write objects, which was
    the real cause of the earlier `atomic-24/25/26` "stalls" (not a code
    issue). Cleaned 48 stale run dirs → 73G free. The `dstore` leaf now
    needs `run_remote.py --stages dstore` (local orchestrator; the
    proxy `py` form drops `STORAMIC_SOURCE_IDENTITY`/manifest) plus a
    validated `--runtime-json`/`--runtime-header-sha256` provenance
    record — the runnable form is
    `python verif/tb/storamic/run_remote.py --stages dstore
    --runtime-json <validated> --runtime-header-sha256 <sha>`.
- **ST-013 measured-service knobs proven working:** `hello` cycles
  2176 (RAM_DELAY=0) → 3978 (RAM_DELAY=8) — the RAM channel delay is
  measurable end-to-end. `io` runs: COMMIT=8 → 177358 cycles,
  COMMIT=32 → 189002 — +11.6k from slower media commits.
- **Second finding — `G6LC_STORAMIC_FLASH_RSP=16` breaks the reinit
  test** (`FAIL_REINIT_IO`=21): a response-stretched store path fails
  the post-reset I/O or its data compare — either an in-flight response
  surviving across the VirtIO reset or a test-tolerance issue; needs
  a directed look.
- ST-025 current status: **open; bounded flash corrections pass selected leaf**.
  Repeated-cut retention and commit-edge writes needed repair despite the
  historical 30-check model result. Persistent identity/map generations,
  last-valid checkpoint retention, stick-wide drain/restore coordination,
  degraded-protection refusal and physical retention are still required even
  with only one commit in flight. See `development-status.md` for the bounded
  implementation slice, live gate observations and disjoint validation plan.
  `storamic-555acfbc60e9` now validates commit/replay/save and response/readback
  at delays 0/1/4/16 with 51/57/63/87 positive checks and four rejecting negative
  oracles on the canary-validated private Verilator 5.008 runtime. The selected
  leaf receipt has `qualification=false`; native reinit, aggregate checks and
  the remaining protected-checkpoint requirements are still open.
