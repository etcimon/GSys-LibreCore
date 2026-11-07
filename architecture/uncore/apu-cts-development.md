# APU CTS Development Contracts

GSys LibreCore uses source-derived mechanism probes and sampled CTS confirmation
to advance the functional APU without waiting for long-running remote jobs.

## Evidence Boundaries

The pinned `sample-v1` contains 32,706 cases (about 1% of must-pass). Its
prefix-tree selection is intentionally not uniform random sampling. Pass rates
and the existing report's Wilson intervals describe the executed cohort; they
do not establish a population pass probability or validate the other 99%.
Unsupported-feature exits also do not exercise the shader or raster mechanism.
Complete pinned groups remain the closure criterion.

`cts_prefilter.py wave` now separates:

- **Confirmation:** cases with no detected gap (`predicted-pass`), not cases
  proved correct by static inspection.
- **Discovery:** cases with a contract gap, untested path, shader refusal,
  speculative NotSupported prediction, or module-level risk. Selection rotates
  through verdict/module buckets. These cases are not silently excluded.

The `.txt.json` sidecar records the two cohorts, seed, input scan and prior result
paths. `--control 0` disables discovery; an entirely uncertain module can still
produce a discovery cohort. This is not a runtime-cost model: large cases need
separate scheduling budgets.

Source-string coverage probes remain weak hints. Finding one graphics bind or a
`VkCopyDescriptorSet` constructor in the generator cannot qualify every shader
stage, descriptor type, layout, array offset, or lifetime.

## Descriptor Copy: Discriminating Local Probe

`ue_gpos_fsubocopy_1` extends the existing `fsubo` transport session:

1. Create a two-element UBO descriptor-array layout and two descriptor sets.
2. Initialize both destination elements red.
3. Initialize source element 0 green and source element 1 red.
4. Copy source element 0 into destination element 1.
5. Bind the destination at the graphics bind point and read element 1 in the
   fragment shader (`fs_ubo_array.frag`).
6. Check all 4,096 framebuffer words against the independent coverage/color
   expectation; free the pool/layout/buffer and check resource drain.

UBO offsets are 0 and 256, respecting the profile's
`minUniformBufferOffsetAlignment`; the descriptor range is 16 bytes. A missing
copy or wrong source/destination array element yields red instead of green.

The initial local vgtop run passed 17,088 checks, zero transfer faults. This
establishes only the probe above. It does not prove that the remaining
`descriptor_copy.graphics` failures originate in a graphics-stage defect.
Both the original `fsubo` and the new copy-array session join the vgtop/vgsys
lists; only the new session needs vector regeneration.

Local follow-up used installed Verilator 5.020, not pinned qualification
Verilator 5.008. Results retained in `.cache/apu-dev-vgtop/`:

| Session | Checks | Cycles |
| --- | ---: | ---: |
| `ue_gpos_fsubo_1` | 17,084 | 589,523 |
| `ue_gpos_tri_1` | 17,017 | 634,890 |
| `ue_cpos_dcopy_descarr_1` | 1,188 | 456,577 |
| `ue_gpos_fsubocopy_1` | 17,088 | 591,518 |
| `ue_gpos_fsubocopy_1`, randomized memory | 17,088 | 2,123,547 |

All five passed. Randomized memory uses latency 1..20 and 60% ready.
Eight host pre-filter policy tests, SPIR-V validation and shell syntax checks
also passed. No vgsys execution, pinned-toolchain gate or aggregate
lint/formal/synthesis qualification was run for this tooling-only pass.

## Immutable Samplers: Architectural Gap

Scope clarification: this is baseline Vulkan compatibility, not a requirement
introduced by the 1% CTS sample. The local registry
`specs/venus-protocol/xmls/vk.xml` includes `VkDescriptorSetLayoutBinding` in
the 1.0 compute/core definitions. `pImmutableSamplers` has no enabling device
feature bit; its `optional="true"` annotation permits a NULL application
pointer, not unsupported non-NULL immutable samplers on the device.
Vulkan 1.4 retains this core behavior. Optional sampler/descriptor extensions
and test combinations still require their own capability/feature analysis.

Sampling changes execution breadth and development priority, not the API
contract. Keep this as a required compatibility gap for the stated stock
Vulkan goal; it need not gate unrelated development increments or trigger
every immutable-sampler CTS variant on each change. A deliberately narrower
workload-only implementation can defer it, but remains an incomplete Vulkan
implementation. Excluding cases from confirmation must not relabel the gap
as optional, NotSupported, or completed.

CTS `vktBindingShaderAccessTests.cpp` builds sampler layouts using
`addSingleSamplerBinding(..., &samplers[n])`. For standalone immutable samplers,
`writeSamplerDescriptorSet` deliberately omits the sampler descriptor write.
The sampler must already be initialized by descriptor-set allocation.

Data flow at the original gap identification (superseded by the RTL increment
in `apu-immutable-implementation.md`):

- `vn_device_profile.toml` keeps only binding/type/count/stage flags for layout
  creation. `pBindings.pImmutableSamplers` is discarded.
- `vnfront` `StDslRd` consumes fixed four-word binding records and emits
  two-word layout rows with no immutable sampler identity.
- `StDSetZero` initializes the descriptor arena to zero.
- Descriptor updates and copies operate on those records; shader access cannot
  recover sampler state that never entered the layout.

This was a source-supported contract gap, independent of vertex/fragment stage.
The retained state path is now implemented in RTL and model. The pre-filter's
capture-gap rule switches off, but that alone is not validation.

### Implemented State Path And Remaining Evidence

The current increment implements immutable state through the existing seam:

1. Decode retains array counts and per-element handles only for immutable
   arrays; unrelated kept handle-array payload formats remain unchanged.
2. Resolved packed sampler state is stored in the layout's existing ObjPay
   extent, not a dangling source slot. Its retirement frees the full extent.
3. Set allocation initializes standalone samplers without writes. Combined
   descriptors preserve sampler bytes while updating image/view state.
4. Copies preserve destination immutable state, including a mutable source
   with a deliberately different sampler in the focused copy fixture.
5. `FrontModel` mirrors the path; three selected RTL probes cover standalone
   initialization, combined updates, array elements and copy preservation.
   Extended pool-reset/lifetime and failure-injection coverage remain open.
6. Confirm one focused CTS case per semantic distinction before wider sampled
   cases; retain a discovery cohort across shader stages and set-layout shapes.

The three new fixtures pass with repository-built 5.008, alongside layout
compatibility controls and the graphics-copy baseline. Full sampler creation
identity is not represented by the existing content hash; stage-aware layout
compatibility also remains incomplete. Do not claim the two CTS vertex failures
fixed, full Vulkan compatibility, or a changed advertised feature set.

## Fast Model Backend

T2 state extraction is now underway, not a working native CTS backend. The existing
`FrontModel` consumes decoded operations and uses shared object/payload/aperture
state; `TransportModel` supplies the virtio resource model. The bridge socket
alone is insufficient: MMIO ring processing, DMA replies, reply serialization,
interrupt/fence behavior and guest-visible memory aliasing must all agree.

Keep the initial extraction limited to the object/memory path, guarding it with
byte-identical existing vectors. Then run bridge protocol tests and stock guest
enumeration before compute or raster. Do not substitute lavapipe execution for
device execution or call shader commit scanning a functional shader result.

`vn_objects.py` now owns object-table handles, generations, directory/lifetime
bookkeeping and masked state updates. `vn_model.py` exposes that state plus
ObjPay next-fit allocation and sparse contents. `FrontModel` inherits the
extracted behavior; the new modules do not import the generator, shader scanner
or vector encoder. Allocation order and existing error behavior are deliberately
unchanged in this extraction.

Ten standalone state tests cover generations, parents/pins, zombie lookup,
child retirement/reuse order, masks, allocator cursor/wrap/fragmentation and
1,000 seeded allocation/free operations against a scalar bitmap search.
Sixteen checked artifacts (hex/exp/json/pay as applicable) regenerated
byte-identically for the triangle, direct FS UBO, FS array-copy, descriptor-array
copy and payload-exhaustion probes. This is sampled extraction evidence, not
byte-identity evidence for every vector. That evidence predates the further
aperture/DMA extraction below; it must not be attributed to the newer code.
Decoded-operation dispatch, reply transport and bridge serving remain pending.

### Aperture And DMA Implementation Increment (Not Yet Executed)

`vn_memory.py` now owns `ApertureState` and `SparseMemory`, re-exported through
`vn_model.py`. `TransportModel` inherits the aperture state rather than
implementing its own allocator and RAM/blob dictionaries.

- First-fit guest/private allocation, kernel-selected extents, top-down
  exclusion-aware allocation, page freeing and mapped-blob lookup are moved
  behind geometry parameters. The golden transport still passes the existing
  72 MiB total / 64 MiB guest / 4 KiB page geometry.
- `ap`, `ap_pages`, `gmem` and `blobs` retain their existing dictionary/list
  interfaces, so frontend descriptor accesses and fixture resource construction
  still share the same storage. Blob creation/mapping policy remains in the
  transport fixture; owning the metadata is not implementing its control queue.
- `dma_read`/`dma_write` provide byte-addressed guest RAM access; aperture
  read/write methods provide a separately bounded device-domain view.
  Little-endian partial-word writes preserve untouched byte lanes, unaligned
  accesses cross word boundaries, and a write checks its complete range before
  changing storage. Empty sparse locations read as zero.
- Guest DMA is a functional 64-bit sparse address-space mirror, not registered
  guest-RAM authorization. A future bridge must enforce actual guest RAM regions,
  request bounds and DMA fault/response behavior before using this view.
  Aperture byte access includes the private arena for device engines; it is not
  permission for a guest to MAP_BLOB that arena.

Source review also identified a relocation-shadow defect: after copying in the
correct direction, the old mover removed every source word, including any word
in the destination overlap. Cleanup now removes only source words outside the
destination. An identity move keeps its contents. The existing whole-word
granularity and caller-owned page allocation/freeing remain unchanged; no new
byte-tail or RTL mover claim is made.

This is an implementation-only increment. No suites, vector regeneration,
simulation builds or remote jobs were run after these changes. Prior passes
remain historical evidence, not validation of this increment. Deferred narrow
checks are byte-lane preservation, crossing-word access, bounds/no partial
write, shared legacy/byte views, relocation in both directions and identity,
followed by sampled vector parity and the existing four-mechanism runner with
the repository Verilator build. Do not mark the native backend functional yet.

## RTL Increment: Canonical Descriptor Layout Rows

The frontend previously emitted descriptor rows directly in `pBindings` order.
That made descriptor record offsets, dynamic-offset bases and the layout
content hash depend on how the application ordered the array. Vulkan consumes
dynamic offsets by increasing set/binding/array element; a permutation alone
must not make equivalent layouts incompatible.

`g6lc_apu_vnfront` now serially selects the next lowest binding, then uses the
existing row-write/ObjPay handshake. Each output row scans all staged quads.
The existing `APU_DESC_BND` admission bound limits this to 16 rows and 1,024
staged-word reads (4*N*N); no variable-sized hardware sorter or new SRAM is
introduced. Two FSM states and 73 scalar state bits are added under the existing
`Enable` generate and asynchronous-active-low reset. New ordering/scan assertions
are simulation/formal instrumentation, fenced with `translate_off`.

This trades bounded layout-creation latency and SRAM read activity for short
comparison/mux cones. Draw/dispatch consumption and record format do not change.
No new clock, reset, memory macro, power domain, test-mode port, ISA feature,
configuration bit, Vulkan advertisement or device-tree property is introduced.
It is a correction to existing descriptor support, not an optional new feature.
The scalar state follows the current module's DFT boundary; scan/ATPG, mapped
area/power, physical timing and aggregate qualification have not been established.

The golden helper `vn_layout.py` sorts full stored 16-bit binding identities
before assigning offsets/dynamic bases. Row packing/lookup now preserves high
binding bits without confusing them with record offsets. Stage flags and
immutable sampler identities are still outside the existing compatibility hash;
hash equality is not claimed to implement the complete Vulkan compatibility
definition, nor is the row format extended to arbitrary 32-bit binding numbers.

The old `layoutmix` oracle wrongly classified a binding-order permutation as an
incompatibility. It now changes descriptor count; `dslcompat` deliberately
permutes bindings and expects success. Only these two transport fixtures were
regenerated. Four standalone tests cover all six mixed static/dynamic binding
permutations, distinct bindings with equal low bytes, highest stored binding,
dynamic-count limits, duplicate rejection and empty layouts.

Verification is a separate evidence boundary. Repository-built 5.008 build with
fatal lint warnings passes, including the new assertions. Selected vgtop results:
`ue_cpos_dslcompat_1` 877 checks / 441,255 cycles; `ue_cneg_layoutmix_1`
685 checks / 438,820 cycles. The negative fixture passes by observing the expected
DEVICE_LOST, not by treating it as successful rendering. Twenty-two Python tests
pass, including four new layout tests. Logs and input hashes are under
`$HOME/.cache/librecore/apu/vgtop/layout-order/`.
Full `verify` was invoked only with `--dry-run`: 25 configured steps were planned,
none executed. Its managed simulation preflight reports missing Verilator
patches on a different tool binding; this does not invalidate the explicit local
fork identity or qualify that managed binding. Shared-tree smoke cleanup was not
authorized or run. Full lint/formal/simulation/synthesis, adversarial
backpressure, maximum-row RTL and RTL dynamic-offset consumption remain open.

Licensing: the existing tier-R notice is retained; new helpers/tests are MIT.
The recorded Etienne Cimon tier-R authorization in `AGENTS-todo.md` is used, not
a claim that a signed CLA was discovered. No upstream notices, license controls
or link sets change. RISC-V spec-index statuses are unaffected.

## Repository Verilator Development Loop

The source launcher in `tools/verilator/bin/verilator` can silently find a
system `verilator_bin` when no matching binary exists. A launcher path alone
therefore does not establish tool provenance.

The local vgtop/vgsys/shwave build and run scripts now default to
`local-verilator.sh` selection. Build the repository fork once:

```bash
bash verif/tb/apu/local-verilator.sh
bash verif/tb/apu/run-apu-dev.sh
bash verif/tb/apu/run-apu-dev.sh --session ue_gpos_fsubocopy_1 --jitter
```

The helper performs an out-of-tree release-only build from `tools/verilator`,
without downloading, installing system-wide or editing upstream source.
It checks the source commit and tracked-diff fingerprint before reusing the
binary. Missing/stale local tools fail with a build instruction instead of
falling back to PATH. An explicit `VERILATOR` remains available for controlled
remote/alternate-tool runs and is recorded as an override.

Persistent tool and simulator outputs default to
`${XDG_CACHE_HOME:-$HOME/.cache}/librecore/`, on WSL's native filesystem rather
than the Windows source drive. `APU_VERILATOR_HOME`, `APU_BUILD_CACHE` and the
existing per-suite `APU_*_OUT` variables override these locations.
`APU_BUILD_JOBS` defaults to four; source Verilator compilation uses configured
ccache when available. Build-only scripts and their full-run twins no longer
delete output trees before compilation. Make retains unchanged compiled objects.

`toolchain.txt` records the selected launcher/root, jobs, version, repository
source fingerprint and local binary SHA-256. The development runner selects
four vgtop mechanism probes (triangle control, direct FS UBO, FS UBO-array copy,
descriptor-array copy), checks exit status and the PASS marker, and retains
logs/cohort names. It does not run the full suite, change CTS coverage or claim
qualification. The full-run scripts retain their full session lists.

Six tool-selection regressions cover missing binary, stale source, explicit
override, inherited repository selection, invalid parallelism and provenance
with paths containing spaces.
The two line-specific UNSIGNED waivers in `apu_exec.vlt` cover Verilator 5.008's
unrolled index-zero inclusive comparisons in shwave/objmem; other warnings stay
fatal. The repository fork built here is
`8c69f297aabc751dbd906ccf67365b9825213248` (Verilator 5.008 plus project patches).

### Compiler Correction Found By The Pinned Loop

The first real 5.008 C++ build exposed an emitter defect: unpacked-struct ports
were declared using one-bit `VL_IN8` / `VL_OUT8` even though generated
expressions accessed their struct members. An unpacked struct has a synthetic
`basicp()` for size queries; that does not make it a scalar C++ port type.

`tools/verilator/src/V3EmitCBase.cpp` now excludes compound dtypes from the
scalar IO macro branch, using the existing typed declaration path instead.
The old tool failed the standalone `tb_verilator_unpacked_port.sv` compile;
the rebuilt fork passes it, including input/output structs, arrays of structs,
packed-struct and scalar-array controls, and hierarchical member access.
No APU ports or assertions were removed to accommodate the compiler.

This correction is an uncommitted change inside the Verilator submodule,
not a new source commit. The source-diff fingerprint and binary hash in
`toolchain.txt` identify the tested patched build.

After the correction, all four development probes pass with the repository
5.008 build, with the same checks/cycles listed in the earlier table.
The graphics copy probe also passes randomized memory at 2,123,547 cycles.
Initial compilation plus the four probes took 239.60 seconds; a subsequent
unchanged build-only invocation took 0.56 seconds. These timings describe
different workloads, not a simulator-throughput speedup.
Evidence is under `$HOME/.cache/librecore/apu/vgtop/` (`toolchain.txt`,
`build.log`, `dev/`); the compiler reproducer's before/after logs are under
`$HOME/.cache/librecore/apu/`.
Eighteen model/prefilter tests and six tool-selector tests pass.
vgsys/shwave selection and shell syntax were checked, but their simulations
and the aggregate lint/formal/synthesis gates were not run in this pass.

## Change Review

This pass adds host tooling and test stimulus, not RTL state or ports. There is
no new clock/reset, SRAM, synthesis timing cone, DFT hook, config feature, device
tree or advertised Vulkan capability. Functional RTL stays on `corev_apu/apu`,
not the timing-reworked hyp output. A future immutable-state implementation
needs SRAM/lifetime accounting, multi-cycle FSM timing notes, generator audit
and the configured lint/formal/sim/synthesis gates.

New host code follows tier T (MIT), preserving Etienne Cimon attribution.
The compiler correction retains the upstream LGPL/Artistic SPDX and copyright
verbatim with a `Modified by:` note. No new linkage boundary is introduced.
