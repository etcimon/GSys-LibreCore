# CTS-guided architecture of the LibreCore APU — method and index

**Purpose.** From 2026-10-14 the Khronos Vulkan CTS (`specs/VK-GL-CTS`, pinned at
`vulkan-cts-1.4.6.2` = `f6a29701220f34dd1407513bfe80d74ca7b392ce`) is the acceptance
oracle of the APU (`architecture/uncore/apu-vulkan-engine.md` §13). This folder turns the
must-pass lists into **architecture**: one file per must-pass group family, in the order
of `external/vulkancts/mustpass/main/vk-default.txt`, each breaking the group down into
the **architectural logic** the RTL must implement and the **exceptions** it must take —
error results, truthful `NotSupported`, undefined-behaviour latitude, device limits,
device-lost — before any engine is extended. RTL increments cite these cards; the
generated ledger (`architecture/uncore/apu-cts-ledger.md`) reports their status.

## Method

The notation adapts `AGENTS-rt-learning-philosophy-AGI.md` (proposition / thought /
pattern cards, the segment card, provisional ordinal heuristics) and reads it through
`AGENTS-coding-philosophy.md` (§0 weigh cause-to-effect links before changing RTL; §2.1
correctness before performance and never silently sacrificed; §2.2 timing first-class;
§2.3 modularity through configuration; §2.4 verification parity; §2.6 explicit over
implicit; §3.7 the timing-impact note). Three card kinds:

```text
LOGIC <GROUP>-L<n> · <name>
  CLAIM       the semantic contract the tests check, stated from the Vulkan spec,
              independently of any test shape
  SOURCE      CTS test ids (prefixes) and the vkt*Tests.cpp that build them; spec clause
  MECHANISM   which engine/module of this design owns it and the dataflow it needs
  REQUIRES    identity, lifetime and ordering preconditions; configuration legality
  FORBIDS     the shortcuts that would pass the test wrongly — value-based suppression,
              test-shape special cases, a proxy for the required work, a fabricated no-op
  CHECK       the must-pass caselist (exact subset via cts_ledger.py select) and the local
              engine vector; the negative control that must fail when the mechanism is removed
  COST        timing/area/scalability note (cone, stage, fan-out, memory, the config knobs)
  FEEDS       dependent LOGIC/EXCEPTION ids and the gate (CTS-0…CTS-5) that closes it
  STATUS      not-run | failing | passing — copied from the ledger with its evidence tag

EXCEPTION <GROUP>-X<n> · <name>
  CONDITION   the input/state under which the exception applies
  RESULT      the required outcome: VkResult, NotSupported-by-absence, undefined latitude
              taken (with the clause that grants it), or device-lost
  TRUTH       what makes the outcome honest — the profile line that makes NotSupported
              truthful, or the reason an error is a real refusal rather than a hidden no-op
  MECHANISM   where this design decides it
  CHECK       the CTS cases that exercise it and the local negative vector
  FORBIDS     the illegal rescue — a waiver, a trimmed caselist, de-advertising a required
              capability to dodge a test, a silent success
```

Each file also carries: the **inventory** (prefix tree with case counts, rendered by
`cts_ledger.py tree`, never typed by hand), an **implementation-order heuristics table**
(trigger / priority / smallest useful action / reject-or-defer when — ordinal, not
weights), a **segment card** for the current state (question, envelope, inputs,
contract, observations, hypotheses, discriminator, result, limits, next artifact), and a
**performance / area / scalability** section: what in the group is throughput-sensitive,
which configuration variables govern it, and which optimizations are correctness-
preserving (the `FORBIDS` lines bound them — a tile engine may reorder, it may not drop).

Rules of the folder:

- A card's `CLAIM` comes from the specification; the test is evidence that the claim is
  checked, not the definition of the claim (RT-P1: the instrument is part of the
  observation; RT-P3: a hypothesis owes a discriminating prediction — the `CHECK` line).
- `STATUS` is copied from the generated ledger, never asserted here. "Smoke green" on a
  self-authored vector is not a status for a card.
- `NotSupported` must be truthful by absence (the profile line is quoted in `TRUTH`);
  advertising a capability pulls its cards into the obligation set. Removing an
  advertised, required capability to make a group `NotSupported` is a `FORBIDS` item.
- Device limits are architecture, not bugs: a `max_concurrent` or residency failure maps
  to a LOGIC card (what must scale) and an EXCEPTION card (what the spec allows to fail,
  e.g. `VK_ERROR_OUT_OF_DEVICE_MEMORY`), never to a waiver.
- Performance work follows correctness (coding philosophy §2.1, RT-T5 compare local and
  aggregate benefit): a faster path is admissible only with the same checked work and no
  regression of a `CHECK`.
- Files are written in `vk-default.txt` order; nested groups (`image/*`, `pipeline/*`,
  `shader-object/*`) fold into one file per module.

Regeneration: `python3 corev_apu/apu/tools/cts_ledger.py groups --cts specs/VK-GL-CTS --out
.cache/cts/groups.json`; per file `… tree --cts specs/VK-GL-CTS --group <group> --depth 3`;
caselists `… select --prefix …`; status `… render`.

## Index (vk-default.txt order; 98 groups, 3,247,552 cases at the pin)

| must-pass group | module dir | cases | owner | file |
|---|---|---:|---|---|
| `api` | `api` | 327795 | W0/W2 lifetime+memory (G3b residency) | `cts-api.md` |
| `binding-model` | `binding_model` | 146920 | W2 (G3b) | `cts-binding-model.md` |
| `clipping` | `clipping` | 308 | W4 | `cts-clipping.md` |
| `compute` | `compute` | 60838 | W3 shader (G3a) | `cts-compute.md` |
| `conditional-rendering` | `conditional_rendering` | 1030 | W4 | `cts-optional-extensions.md` |
| `cooperative-vector` | `cooperative_vector` | 53562 | W6 | `cts-optional-extensions.md` |
| `data-graph` | `data_graph` | 10176 | optional (NotSupported by absence) | `cts-optional-extensions.md` |
| `depth` | `draw (depth)` | 8 | W4 (G3c) | `cts-draw.md` |
| `descriptor-indexing` | `descriptor_indexing` | 110 | W2/W5 | `cts-descriptor-indexing.md` |
| `device-group` | `device_group` | 18 | W2 | `cts-device-group.md` |
| `dgc` | `device_generated_commands` | 4473 | W8 | `cts-optional-extensions.md` |
| `draw` | `draw` | 29392 | W4 (G3c) | `cts-draw.md` |
| `drm-format-modifiers` | `modifiers` | 1572 | W9 | `cts-wsi-presentation.md` |
| `dynamic-state` | `dynamic_state` | 671 | W4 | `cts-dynamic-state.md` |
| `fragment-operations` | `fragment_ops` | 151 | W4 (G3c) | `cts-fragment-operations.md` |
| `fragment-shader-interlock` | `fragment_shader_interlock` | 576 | W8 | `cts-w8-raster-extensions.md` |
| `fragment-shading-barycentric` | `fragment_shading_barycentric` | 20991 | W8 | `cts-w8-raster-extensions.md` |
| `fragment-shading-rate` | `fragment_shading_rate` | 110363 | W8 | `cts-w8-raster-extensions.md` |
| `geometry` | `geometry` | 199 | W8 | `cts-geometry-tessellation.md` |
| `glsl` | `shaderexecutor + shaderrender` | 26763 | W3 shader (G3a) | `cts-glsl.md` |
| `graphicsfuzz` | `amber` | 757 | W3 | `cts-glsl.md` |
| `image/*` (30 lists) | `image` | 136,625 | W4 (G3d) | `cts-image.md` |
| `image-processing` | `image_processing` | 611 | optional (NotSupported by absence) | `cts-optional-extensions.md` |
| `imageless-framebuffer` | `imageless_framebuffer` | 6 | W4 | `cts-renderpasses.md` |
| `info` | `api (vktInfoTests)` | 21 | W0 | `cts-info.md` |
| `memory` | `memory` | 6279 | W2 | `cts-memory.md` |
| `memory-model` | `memory_model` | 17300 | W3/W5 | `cts-memory-model.md` |
| `mesh-shader` | `mesh_shader` | 28012 | W8 | `cts-w8-raster-extensions.md` |
| `multiview` | `multiview` | 694 | W8 | `cts-multiview.md` |
| `pipeline/*` (8 lists) | `pipeline` | 1,186,094 | W4 raster (G3c/G3d) | `cts-pipeline.md` |
| `protected-memory` | `protected_memory` | 6000 | W5 | `cts-sparse-protected.md` |
| `query-pool` | `query_pool` | 18270 | W4 (G3c) | `cts-query-pool.md` |
| `rasterization` | `rasterization` | 15079 | W4 (G3c) | `cts-rasterization.md` |
| `ray-query` | `ray_query` | 38509 | W7 | `cts-ray-tracing.md` |
| `ray-tracing-pipeline` | `ray_tracing` | 18681 | W7 | `cts-ray-tracing.md` |
| `reconvergence` | `reconvergence` | 6253 | W3 | `cts-subgroups-reconvergence.md` |
| `renderpasses` | `renderpass` | 79748 | W4 (G3c) | `cts-renderpasses.md` |
| `robustness` | `robustness` | 96843 | W2/W3 | `cts-robustness.md` |
| `shader-object/*` (9 lists) | `shader_object` | 242,382 | W3/W4 | `cts-wsi-presentation.md` (optional family) |
| `sparse-resources` | `sparse_resources` | 19078 | W5 | `cts-sparse-protected.md` |
| `spirv-assembly` | `spirv_assembly` | 68563 | W3 | `cts-spirv-assembly.md` |
| `ssbo` | `ssbo` | 12225 | W2/W3 | `cts-ubo-ssbo.md` |
| `subgroups` | `subgroups` | 48621 | W3 | `cts-subgroups-reconvergence.md` |
| `synchronization` | `synchronization` | 64871 | W2 | `cts-synchronization.md` |
| `synchronization2` | `synchronization` | 81616 | W2 | `cts-synchronization.md` |
| `tensor` | `tensor` | 844 | optional (NotSupported by absence) | `cts-optional-extensions.md` |
| `tessellation` | `tessellation` | 1103 | W8 | `cts-geometry-tessellation.md` |
| `texture` | `texture` | 27301 | W4 (G3d) | `cts-texture.md` |
| `transform-feedback` | `transform_feedback` | 133695 | W8 | `cts-wsi-presentation.md` |
| `ubo` | `ubo` | 13240 | W2/W3 | `cts-ubo-ssbo.md` |
| `video` | `video` | 9301 | optional (NotSupported by absence) | `cts-optional-extensions.md` |
| `wsi` | `wsi` | 35481 | W9 | `cts-wsi-presentation.md` |
| `ycbcr` | `ycbcr` | 62333 | W4 | `cts-wsi-presentation.md` |

Per-list counts for the folded families are in `.cache/cts/groups.json` (regenerable) and
in each family file's inventory. Every group now has a file (2026-10-14: 27 files; nested lists and decided-optional
families are folded as shown). The ledger reports every group as `not-run` until its first
submission-shaped run; `STATUS` lines in the cards are copied from it.

## Limits ledger

`limits-ledger.md`: every `VkPhysicalDeviceLimits` field the CTS found below the minimum
(39 at CTS-0), with the actual value, the 1.0/1.1 and 1.4 minima, the owning mechanism card
and its class (mechanism / verify / profile-only) — a value is raised only with its
mechanism and a vector that exercises the maximum.

## Performance, area and scalability

`performance-area-scalability.md` defines the program that follows the cards: admissibility of a
throughput change (ledger diff empty incl. the fails-if-removed controls, Gate 1 across
geometries, no `FORBIDS` crossed, identical checked work), the counters (W1.5), the frozen
baseline on checked work (W1.6), the knob table per card, and the scaling order behind the
CTS fence.

## Cross-cutting pattern cards (apply to every file)

```text
PATTERN CTS-P1 · Advertisement is obligation
  MECHANISM   A feature/extension/format/limit in vn_device_profile.toml selects the
              tests whose NotSupported becomes Fail; the generated profile is therefore
              part of the architecture, not a marketing table.
  APPLIES     Every checkSupport() in the CTS reads the enumerated capabilities.
  PREDICTS    Raising a capability without its mechanism turns a NotSupported group red
              in the next ledger; lowering a *required* one turns api.info/info red.
  COUNTERCASE Required core features (Vulkan 1.0 mandatory formats/limits) cannot be
              de-advertised — their cards have no NotSupported exception.
  STATUS      locally tested (G1c profile audit 19 → 7 findings; G2c/G3a-i guest runs)

PATTERN CTS-P2 · Limits are architecture
  MECHANISM   Fixed on-chip counts (8 shader slots, 16 command buffers, 4 sets, 16
              binding rows) surface in the CTS as OUT_OF_*_MEMORY on object-management
              and binding tests, and as phantom-handle wedges through Venus's async path.
  APPLIES     Any test that creates more objects than a slot count or allocates more
              than the private arena.
  PREDICTS    api.object_management.max_concurrent.* and pipeline.*.cache/early_destroy
              fail until residency virtualization (G3b) replaces slots with caches.
  COUNTERCASE A truthful VK_ERROR_OUT_OF_DEVICE_MEMORY on the private arena is allowed by
              the spec; the CTS tolerates it only where it tests exhaustion deliberately.
  STATUS      candidate (G2c cbfull evidence; CTS-0 pending)

PATTERN CTS-P3 · Reorder, never drop
  MECHANISM   Throughput structures (tile binning, wave scheduling, multiple LSUs, write
              coalescing) change order and timing of required work; the CTS checks results
              and ordering only where the spec orders them (primitive order per sample,
              atomics, barriers, queries).
  APPLIES     Every performance change from W4.5 on.
  PREDICTS    A reordering that respects the spec's ordering points keeps every CHECK
              green at any configuration; one that drops or merges required work fails a
              fails-if-removed control.
  COUNTERCASE Fragment interlock, ordered attachment access and query counting are
              ordering points that look like performance detail — they are not.
  STATUS      candidate (no tile engine yet)
```
