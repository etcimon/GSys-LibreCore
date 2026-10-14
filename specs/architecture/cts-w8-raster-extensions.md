# W8 raster extensions — `fragment-shading-rate` (110,363), `fragment-shading-barycentric` (20,991), `fragment-shader-interlock` (576), `mesh-shader` (28,012)

Source: `specs/VK-GL-CTS` @ `f6a29701`; must-pass lists `vk-default/{fragment-shading-rate,
fragment-shading-barycentric,fragment-shader-interlock,mesh-shader}.txt`; tests in
`external/vulkancts/modules/vulkan/{fragment_shading_rate,fragment_shading_barycentric,
fragment_shader_interlock,mesh_shader}/`. Owner W8 — all four are requested release
features (plan matrix: VRS 0.87, mesh 0.92, barycentrics 0.82, interlock 0.78). All
NotSupported by truthful absence today; gate CTS-4. Each gets its own file when its
increment opens; this file fixes what the cards must contain so the engines are designed
for them now (tile/ROP ordering, per-primitive attributes, rate sources).

## Inventory

| group | cases | structure |
|---|---:|---|
| `fragment_shading_rate` | 110363 | `renderpass2` 57686 (`monolithic` 43762, `pipeline_library`/`fast_linked_library` 6962 each), `dynamic_rendering` 52677 (`primary_cmd_buff` 51633, secondaries 522 ×2): pipeline/primitive/attachment rate sources × combiners × sample counts × formats |
| `fragment_shading_barycentric` | 20991 | `data` 6625 (provoking first/last 3240 each, shader_combos 144), `weights` 372, each repeated for pipeline_library / fast_linked_library |
| `fragment_shader_interlock` | 576 | `basic.{discard,nodiscard}` 288 each: pixel/sample/shading-rate interlock × ordered/unordered × resource (image/SSBO) × dimensions |
| `mesh_shader` | 28012 | `ext` 26889 (`query` 24680!, `api` 540, `in_out` 560, `conditional_rendering` 792, `misc` 83, `smoke` 67, `synchronization` 81, `builtin` 37), `nv` 1123 |

## Architectural logic

```text
LOGIC VRS-L1 · Variable-rate shading: pipeline, primitive and attachment rates with combiners
  CLAIM       A fragment shader invocation may cover a 1×1…4×4 (advertised set) block of
              pixels; the rate is combined from the pipeline rate, the primitive rate
              (gl_PrimitiveShadingRateEXT from the last pre-raster stage) and the
              attachment rate (a fragment-shading-rate attachment with texel size in the
              advertised range) through the two combiner ops; coverage, depth/stencil
              tests, sample positions, derivatives (per coarse fragment), gl_FragCoord
              (center of the coarse fragment), interpolation (per the spec's rules for
              coarse fragments) and MSAA interact exactly as specified; the
              fragmentShadingRateWithShaderDepthStencilWrites/… properties state the
              interactions we support.
  SOURCE      fragment_shading_rate.renderpass2.monolithic.* (43,762 — the core matrix),
              dynamic_rendering.primary_cmd_buff.*; vktFragmentShadingRateBasic.cpp,
              …PixelConsistency, …Attachment, …Misc.
  MECHANISM   The rast scan already produces 2×2 quads; VRS generalises the fragment
              footprint: one FS lane per coarse fragment covering an r_x × r_y block,
              with the ROP replicating the result to the covered samples that pass
              per-sample coverage/depth/stencil (tests run per sample, shading per
              coarse fragment). Rate sources: pipeline (draw record), primitive (VS-out
              record slot), attachment (a fetch keyed by the coarse-fragment position /
              texel size); combiners are 2 small tables. Derivatives use the coarse
              quad; gl_FragCoord is the block center.
  REQUIRES    MSAA (RAST-L4) first — VRS is defined over samples; layered attachments
              for the rate image per layer; the property set truthfully derived from the
              implementation (which interactions with depth writes / sample mask /
              interlock we allow).
  FORBIDS     Implementing VRS by shading at full rate and discarding (the shader's
              side effects and invocation count are observable: tests count
              invocations); honouring only the pipeline rate while advertising the
              primitive/attachment sources.
  CHECK       renderpass2.monolithic.<rate>.{pipeline,primitive,attachment}.* (CTS-4).
  COST        ROP replication (write combining — a win), coarse-fragment interpolation
              logic; the rate attachment fetch per tile (cheap in a tile engine).
  FEEDS       UE (VRS), W4.5 tile engine design; CTS-4.
  STATUS      not-run (NotSupported)

LOGIC BARY-L1 · Shader barycentrics and per-vertex attribute access
  CLAIM       gl_BaryCoordEXT / gl_BaryCoordNoPerspEXT give the perspective-correct /
              linear barycentric weights of the fragment within its primitive (points
              and lines per the spec's definitions); `pervertexEXT` inputs read the
              three vertices' unweighted values in provoking-vertex order (first or last
              per VK_EXT_provoking_vertex); works with all topologies, MSAA sample
              shading and clipping (weights of clipped primitives refer to the original
              vertices).
  SOURCE      fragment_shading_barycentric.{data,weights}.{provoking_first,
              provoking_last}.*, shader_combos.
  MECHANISM   The rast setup already has the edge functions = barycentrics (16.8 fixed →
              the λ path); expose them as a builtin FS input (two vec3 slots: perspective
              and linear); per-vertex attributes = the FS reads the VS-out records of the
              primitive's three vertices directly (the varying cache var_q[3][8][4] is
              exactly that data) — so `pervertexEXT` is a record read without
              interpolation; clipping must keep the *original* vertices' barycentric
              frame (clipped vertices carry their barycentrics w.r.t. the source
              triangle — compute λ for clipped vertices and interpolate).
  REQUIRES    Provoking-vertex control (EXT_provoking_vertex — Zink needs it too);
              per-vertex record access from FS waves (a third pointer in the FS dispatch).
  FORBIDS     Recomputing barycentrics in the shader from gl_FragCoord (precision and
              clipping differ).
  CHECK       data.provoking_first.* then weights.* (CTS-4).
  COST        two more interpolated slots; per-vertex record reads per fragment (bandwidth
              — cache per primitive).
  FEEDS       UE (Nanite-style visibility buffer resolve uses barycentrics), CTS-4.
  STATUS      not-run (NotSupported)

LOGIC FSI-L1 · Fragment shader interlock
  CLAIM       Between beginInvocationInterlock/endInvocationInterlock, fragment
              invocations that overlap (pixel or sample interlock; shading-rate
              interlock per coarse fragment) execute the critical section mutually
              exclusively and, with ordered interlock, in primitive order; memory
              accesses inside are coherent across the section; discard variants must
              still release the lock.
  SOURCE      fragment_shader_interlock.basic.{discard,nodiscard}.<kind>.<order>.
              <resource>.<size>.*.
  MECHANISM   The serialized engine satisfies exclusion trivially today; a parallel FS
              pipeline needs a per-pixel/sample lock table scoped to the tile (W4.5) and,
              for the ordered variant, a primitive-sequence ticket per pixel (the tile
              engine's per-pixel primitive order — CTS-P3's ordering point); begin/end
              are two instructions (OpBeginInvocationInterlockEXT 5364 / OpEnd 5365) and
              the execution modes PixelInterlockOrdered/Unordered etc. are recorded.
  REQUIRES    FS waves may stall mid-shader → the wave scheduler's blocking-op yield
              (W3.6); the lock table sized by tile pixels × samples.
  FORBIDS     Granting the lock by wave order instead of primitive order in the ordered
              modes; losing the lock on discard.
  CHECK       basic.nodiscard.pixel_ordered.* first (CTS-4); a serialized-engine run can
              pass today only as a control — the parallel engine must pass with the
              lock.
  COST        the lock table and the stall; programmable blending (plan W8) rides on it.
  FEEDS       plan "programmable blending", "visibility buffers"; CTS-4.
  STATUS      not-run (NotSupported)

LOGIC MESH-L1 · Task and mesh shaders (EXT)
  CLAIM       Task shaders emit payloads and launch mesh workgroups; mesh shaders write
              vertices/primitives (points/lines/triangles) with per-vertex and
              per-primitive outputs (incl. gl_PrimitiveID, Layer, ViewportIndex,
              CullPrimitive, shading rate) into the raster pipeline; builtins, in/out
              limits (maxMeshOutputVertices/Primitives…), indirect/count draws,
              queries (mesh/task invocation statistics — 24,680 cases), synchronization
              with other stages, conditional rendering.
  SOURCE      mesh_shader.ext.{smoke,api,builtin,in_out,misc,query,synchronization,
              conditional_rendering}.*.
  MECHANISM   Task/mesh waves are compute-like dispatches whose output records feed the
              rast primitive assembler directly (the VS-out record format with a
              per-primitive record alongside) — the amplification is a second dispatch
              level with a payload slab; the rast consumes "meshlet" batches instead of
              VS batches; culling by CullPrimitive is a setup skip.
  REQUIRES    Per-primitive attribute records in the FS input path (shared with BARY-L1);
              pipeline statistics queries for mesh/task invocations (QUERY-POOL-L*);
              the W3 wave engine's workgroup scheduling.
  FORBIDS     Lowering mesh shaders to vertex shaders host-side (not stock-visible; and
              the per-primitive outputs do not map).
  CHECK       mesh_shader.ext.smoke.* then in_out.* and builtin.* (CTS-4); queries last.
  COST        meshlet output buffers (slab per workgroup), second dispatch level.
  FEEDS       plan "mesh/amplification", UE Nanite path; CTS-4.
  STATUS      not-run (NotSupported)
```

## Exceptions

```text
EXCEPTION W8-X1 · Not advertised until each card is green
  CONDITION   All four extensions (and mesh_shader.nv, which is not planned).
  RESULT      NotSupported.
  TRUTH       profile lines; adoption order = interlock (needs the tile lock anyway) →
              barycentrics (cheap on this setup) → VRS (after MSAA) → mesh (after W3
              scheduling).
  MECHANISM   Profile ROM.
  CHECK       ledger (0 fail expected).
  FORBIDS     Advertising a property (e.g. fragmentShadingRateWithShaderSampleMask) the
              implementation does not honour.
```

## Implementation-order heuristics

| Heuristic | Trigger | Priority | Smallest useful action | Reject / defer when |
|---|---|---:|---|---|
| W8-H1 Design the tile ordering point now | W4.5 tile engine design | precondition | per-pixel primitive tickets in the tile engine (serves interlock, VRS replication, ordered attachment access) | — |
| W8-H2 Barycentrics early | CTS-4 | medium | expose setup λ + per-vertex record reads | provoking-vertex control missing |
| W8-H3 VRS after MSAA | RAST-L4 green | medium | coarse fragment footprint + combiners | — |
| W8-H4 Mesh after W3 scheduler | W3.3/3.6 | later | meshlet record path | — |

## Performance / area / scalability

These are the features whose *area* must be justified by the Pareto study (plan W1.6): VRS
and mesh shaders reduce work (a win when content uses them); interlock and barycentrics
add ordering/bandwidth cost. Knobs: tile lock table size, meshlet slab bytes, rate
attachment cache. Correctness-preserving: ordered interlock and VRS replication both sit
on the per-pixel primitive order — one mechanism, designed once (CTS-P3).
