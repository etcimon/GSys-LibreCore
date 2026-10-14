# `ray-query` (38,509) and `ray-tracing-pipeline` (18,681) — acceleration structures, ray queries, ray pipelines

Source: `specs/VK-GL-CTS` @ `f6a29701`; must-pass `vk-default/ray-query.txt`,
`vk-default/ray-tracing-pipeline.txt`; tests in `external/vulkancts/modules/vulkan/
ray_query/vktRayQuery*.cpp`, `ray_tracing/vktRayTracing*.cpp`. Owner W7 (plan features
0.97/0.94/0.93/0.90/0.86). All NotSupported by truthful absence until W7; gate CTS-4. This
file fixes the acceptance structure W7's design must target.

## Inventory (top sub-groups; regenerate with `cts_ledger.py tree`)

`ray_query`: acceleration structures (build/update/copy/serialize/compaction/indirect
builds, host and device builds), traversal control (flags, cull masks, opacity, instance
masks/transforms, watertightness), builtins per stage (ray queries from compute,
graphics stages incl. fragment, and ray pipelines), misc (non-uniform args, barycentrics,
trace-ray-indirect), opacity micromaps (EXT, gated), position fetch (KHR, gated).

`ray_tracing_pipeline`: shader binding tables (strides, offsets, records, callables),
recursion depth, pipeline libraries, traversal flags, builtins (launch id/size, hit kind,
instance custom index, object/world transforms), any-hit/closest-hit/miss/intersection
semantics, acceleration-structure builds in every form, large shader counts,
capture/replay, pipeline binaries (gated), watertightness, misc (indirect, callable
nesting, payload sizes), opacity micromap interactions.

## Architectural logic

```text
LOGIC RT-L1 · Acceleration structures: build, update, copy, compaction, serialization — device-side
  CLAIM       BLAS from triangle geometry (every vertex format/stride/index type,
              transforms) and AABBs; TLAS from instances (transforms, masks, flags,
              custom indices, SBT offsets); device builds (vkCmdBuildAccelerationStructures
              with scratch, batched, indirect) and host builds (if advertised); update
              (refit), copy, compaction with size queries, serialization/deserialization
              with versioning; the structures are opaque device memory the shaders
              traverse by device address.
  SOURCE      ray_query.acceleration_structures.*, ray_tracing_pipeline.acceleration_
              structures.*, build.*, misc.* (both groups).
  MECHANISM   Plan W7.1: a hardware build controller (BVH over triangles/AABBs — binned
              SAH or LBVH; the choice is a Pareto item), refit, copy/compact/serialize as
              Xfer-class work with a defined serialized format; structures live at
              stable device addresses (W5 VA) — the queries/pipelines reference them by
              VkDeviceAddress.
  REQUIRES    W5 stable addresses; scratch allocation sizes reported truthfully
              (vkGetAccelerationStructureBuildSizes); no firmware builder (strict
              endpoint).
  FORBIDS     Building on the host CPU (not stock-visible on the device path; the
              hostAccelerationStructureCommands feature is a *separate* optional path).
  CHECK       acceleration_structures.flags/format/indirect/… (CTS-4).
  COST        the builder — the largest W7 block.
  FEEDS       RT-L2/L3; CTS-4.
  STATUS      not-run (NotSupported)

LOGIC RT-L2 · Ray queries (inline) from any stage
  CLAIM       rayQueryEXT traversal with proceed/confirm/terminate, candidate and
              committed intersection queries (type, t, barycentrics, instance/geometry/
              primitive ids, transforms, front face, object-ray origin/direction),
              flags (opaque/no-opaque/terminate-on-first/cull), cull masks, t ranges,
              watertight triangle intersection (no cracks along shared edges), from
              compute, fragment, vertex (and ray) stages; nested/multiple queries.
  SOURCE      ray_query.{builtin,traversal_control,misc,watertightness,…}.*.
  MECHANISM   Plan W7.2: a shared traversal unit (BVH node fetch, box/triangle
              intersection with a watertight algorithm, stack/spill) exposed to shwave as
              a long-latency instruction family (the wave yields — W3.6 blocking ops);
              candidate/committed state in per-lane registers.
  REQUIRES    RT-L1; the yield/park mechanism; per-lane traversal state (a ray is a
              lane).
  FORBIDS     A software traversal in the shader core only (legal but the plan requires
              hardware traversal — a performance choice; correctness-wise both pass).
  CHECK       ray_query.builtin.*, traversal_control.* (CTS-4).
  COST        the traversal unit + stack memory per ray.
  FEEDS       plan "inline ray queries"; CTS-4.
  STATUS      not-run (NotSupported)

LOGIC RT-L3 · Ray tracing pipelines, SBTs, recursion, execution reordering, micromaps
  CLAIM       raygen/miss/closest-hit/any-hit/intersection/callable stages scheduled by
              traversal with shader binding table records (handles, strides, data),
              recursion up to maxRayRecursionDepth, payloads/attributes, pipeline
              libraries, trace-rays indirect (+count), shader-group handle capture/
              replay, large pipelines; (EXT) shader execution reordering (hit objects,
              reorder calls) and opacity micromaps (per-triangle opacity, special
              indices, any-hit skipping) — plan features 0.90/0.86.
  SOURCE      ray_tracing_pipeline.* (18,681); ray_query opacity-micromap subsets.
  MECHANISM   Plan W7.3–7.5: the traversal unit returns hits to a scheduler that
              launches the SBT-selected shader waves with payload storage; continuation
              state per ray for recursion; reorder = regroup continuations by hit
              shader/material (bounded window); micromaps = per-triangle opacity lookup
              in the intersection path.
  REQUIRES    RT-L1/L2; the W3 scheduler's checkpointable waves (W3.6).
  FORBIDS     Lowering ray pipelines to a host-generated megakernel at pipeline creation
              (not stock-visible; also forbidden by the plan's "no firmware compiler").
  CHECK       ray_tracing_pipeline.{shader_binding_table,recursion,builtin,…}.* (CTS-4).
  COST        the continuation store — the W7 Pareto core.
  FEEDS       plan W7; CTS-4.
  STATUS      not-run (NotSupported)
```

## Exceptions

```text
EXCEPTION RT-X1 · Not advertised until W7
  CONDITION   VK_KHR_acceleration_structure / ray_query / ray_tracing_pipeline /
              ray_tracing_maintenance1 / EXT_opacity_micromap / NV reorder.
  RESULT      NotSupported for all 57,190 cases.
  TRUTH       profile; the plan keeps them release blockers (W7) while the stock Venus
              passthrough for the chosen extension revisions is a W1 ledger item.
  MECHANISM   Profile ROM.
  CHECK       ledger (0 fail).
  FORBIDS     Advertising KHR_ray_query before watertightness passes.

EXCEPTION RT-X2 · Host acceleration-structure commands
  CONDITION   accelerationStructureHostCommands.
  RESULT      NotSupported (we will not advertise host builds — they run on the CPU in
              the Venus guest? No: host commands execute in the *renderer* on the host
              CPU in the virglrenderer model, which is exactly a software builder; keep
              it off).
  TRUTH       feature false.
  MECHANISM   Profile ROM.
  CHECK       ledger.
  FORBIDS     —
```

## Implementation-order heuristics

| Heuristic | Trigger | Priority | Smallest useful action | Reject / defer when |
|---|---|---:|---|---|
| RT-H1 Watertight intersection first | W7 start | precondition | the triangle intersector against the CTS watertightness tests in isolation (unit vectors from `vktRayQueryWatertightnessTests`) | — |
| RT-H2 Builder choice | W7.1 | high | measure LBVH vs binned SAH build cost/quality on the CTS geometry sets before committing area | — |
| RT-H3 Queries before pipelines | W7.2 | high | ray_query from compute end to end | — |

## Performance / area / scalability

The W7 block is the largest discretionary area in the product; its Pareto study (plan
W1.6/W7) uses `ray_query.watertightness`/`traversal_control` as the correctness fence and
the UE/CS2 RT content as the workload. Knobs: traversal units, stack depth/spill,
reorder window, micromap support. Correctness-preserving: any-hit invocation rules under
opacity flags and micromaps (W7.5) are not optimisable away.
