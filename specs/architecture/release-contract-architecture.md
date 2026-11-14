# Release-contract families and throughput: what the CTS checks, and how they attach to the present design

Scope: the families the release contract requires but Vulkan 1.4 conformance does not
(pipeline libraries, shader objects, transform feedback, sparse, protected, YCbCr, mesh,
ray tracing, shading rate, cooperative matrix), plus the throughput path. Written
2026-11-10 from the pinned must-pass lists, the pinned Venus protocol
(`specs/venus-protocol/vn_protocol.py`), and the RTL as it stands. No CTS case of these
families has been run. Counts are list sizes at the pin; "validates" is read from the test
names and list structure, not from executing them.

## 1. Transport first: what the pinned Venus protocol can carry

The device is reached only through Venus. A family the protocol cannot encode cannot be
advertised, whatever the RTL does.

| Family | In the pinned protocol's extension list | Consequence |
|---|---|---|
| Pipeline libraries (`KHR_pipeline_library`, `EXT_graphics_pipeline_library`) | yes | buildable |
| Transform feedback, primitives-generated query | yes | buildable |
| Mesh shader | yes | buildable |
| Ray tracing pipeline, ray query, acceleration structure | yes | buildable |
| Fragment shading rate, interlock, barycentric | yes | buildable |
| Cooperative matrix | yes | buildable |
| YCbCr conversion | yes | buildable |
| Dynamic rendering, synchronization2, host image copy, push descriptor, maintenance5/6 | yes | buildable |
| Sparse binding | `vkQueueBindSparse` is in the command set | check the feature path |
| Protected memory | only `EXT_pipeline_protected_access` | not carried as a feature; stays NotSupported |
| **Shader objects** | **no** | 645,404 cases across `pipeline/shader-object-*`, `shader-object/*`, `compute.shader_object_*` cannot be reached at this pin |
| Opacity micromap | no | the release row "opacity micromaps" has no transport |
| Shader execution reordering | no | same |
| Device-generated commands | no | same |
| Descriptor buffer | no | same |
| Cooperative vector | no | same (already decided NotSupported) |

This is the protocol's list. The driver's own pass-through table was then read from
Mesa 25.2.8 `src/virtio/vulkan/vn_physical_device.c` (upstream source, not run):

- passed through when the renderer has them: `KHR_sampler_ycbcr_conversion`,
  `KHR_pipeline_library`, `EXT_graphics_pipeline_library` (unless `VN_DEBUG=no_gpl`),
  `EXT_extended_dynamic_state3`, `EXT_transform_feedback`, `KHR_fragment_shading_rate`,
  `EXT_fragment_shader_interlock`, and `KHR_acceleration_structure` / `KHR_ray_query` /
  `KHR_ray_tracing_pipeline` (unless `VN_DEBUG=no_ray_tracing`);
- **not in that file at all**: mesh shader, cooperative matrix, shader object, opacity
  micromap. So at this Mesa pin the mesh list (28,012) and cooperative matrix are
  unreachable too, although the protocol could carry them;
- sparse binding is passed through only if the device has a queue family that is not
  sparse-only; protected-memory features are queried. Four release rows (shader objects, micromaps,
reordering, device-generated commands) therefore depend on upstream protocol work, which
the plan already names as "official uptake of generic Venus support".

## 2. What each family's tests validate

| Family (cases) | Where the cases are | Behaviour under test | Smallest mechanism that satisfies it |
|---|---|---|---|
| Fast-linked + pipeline library (247,028) | stencil 58,496; blend 12,210; multisample 10,594; vertex input 10,574; depth 8,515 in the fast-linked list alone | The same fixed-function results as monolithic pipelines when state arrives as up to four library parts | Library parts write disjoint field groups of one draw record; link is a field merge at create time |
| Shader objects (645,404) | `rendering.color_attachment_count_{0,1,4,8}` 240,672 | Stage code bound per stage, all state dynamic, up to 8 colour attachments | Same draw record with every field dynamic; blocked by transport |
| Transform feedback (133,695) | `primitives_generated_query` 107,866; fuzz 1,920 | Mostly the primitives-generated counter under every draw path; then capture of vertex-stage outputs to buffers with pause/resume | A per-draw primitive counter after assembly, read as a query; then a capture writer on the vertex-output record stream |
| Fragment shading rate (110,363) | dynamic rendering 52,677; renderpass2 57,686 | Pipeline, primitive and attachment rate sources, the two combiners, coverage and shading at 1×1 to 4×4 | Rate resolved per 2×2 quad group before fragment batches are formed; one shaded sample replicated |
| YCbCr (62,333) | `copy.*` 42,752; conversion 11,088 | Per-plane copies of multi-planar formats; sampler conversion (model, range, chroma siting and filter) | Planes as layers of the existing image address function for copies; a fixed-function matrix after the texel fetch for conversion |
| Ray query (38,509) | `acceleration_structures.flags` 27,858; micromap 3,552 | Build/copy/compact/serialize flags and geometry formats give the same hits; then traversal results | A build path and a traversal engine with a software-visible structure; the CTS checks results, not structure layout |
| Mesh shader (28,012) | `ext.query` 24,680 | Mostly pipeline-statistics and primitives-generated queries with mesh draws | Query counters on the mesh path first; the mesh stage itself is a compute-like wave that emits vertex and primitive records |
| Sparse (19,078) | binding 2,619 + device-group variants; residency 3,600+ | Memory bound per page range after creation; unbound residency reads | A page table between the image address function and the aperture |
| Ray tracing pipeline (18,681) | `acceleration_structures.flags` 9,288 | As ray query, plus the shader binding table and recursion | Ray query engine plus a stage dispatcher |
| Protected (6,000) | YCbCr interaction 4,000 | Access rules for protected resources | none planned |

Two patterns recur. First, the two largest families (library and shader-object pipelines)
test no new rendering behaviour. Second, three families are dominated by **query
counters** (107,866 of transform feedback, 24,680 of mesh): the counter is worth building
before the feature it counts.

## 3. Attachment to the implemented design

What exists (read from the RTL):

- `apu_rast_draw_t` (`include/g6lc_apu_rast_pkg.sv`) is already one record per draw:
  shader slots, topology, polygon mode, cull and front face, 16 vertex bindings, index
  buffer, viewport and scissor, four colour attachments, depth, stencil front and back,
  depth bias and bounds, logic op, blend constants, draw parameters.
- `g6lc_apu_cmdexec` fills it at draw time from the pipeline object's kept words (w25…w54)
  and from command-buffer state. Only blend constants have a dynamic/static selector
  (`dr_bcdyn_q`); viewport and scissor arrive by command.
- `g6lc_apu_vnfront` stages `vkCreateGraphicsPipelines` through generated keep-lists.
- `g6lc_apu_rast` forms vertex batches (63) and fragment batches (64) as records in the
  private arena and runs them as shader waves on one `g6lc_apu_shcore`.

Extrapolated architecture, in build order:

1. **Draw record with a per-field source mask.** Generalise `dr_bcdyn_q` to one bit per
   field group: 0 = pipeline word, 1 = command-buffer shadow. The 1.3 dynamic states and
   `extended_dynamic_state3` then need shadow registers and decode entries, not executor
   logic. This is the same change that pipeline libraries need (a part = a field group)
   and that shader objects would need (all bits 1). Gate: `dynamic_state`, then
   `pipeline.monolithic` unchanged, then the fast-linked list.
2. **Counters on the draw path.** Primitives generated, and the pipeline-statistics set,
   counted in `rast` after assembly and clipping, stored in a query-pool object, copied
   by the transfer engine. Closes most of transform feedback and mesh by count and is a
   prerequisite of `query_pool` (conformance).
3. **Colour attachments 4 → 8** in the record and the output stage (shader-object
   rendering and core `maxColorAttachments`).
4. **Capture writer** on the vertex-output record stream for transform feedback proper.
5. **Planes as layers** for YCbCr copies, then the conversion matrix in the sampler.
6. **Rate resolve before fragment batching** for shading rate.
7. **Page table under the image address function** for sparse.
8. **Mesh stage** as a wave kind that writes the records the vertex stage writes today.
9. **Ray engine** (W7), last: it shares nothing above except the shader core.

Items 1–3 are extensions of mechanisms that are already in the tree. Items 4–8 each add
one stage at an existing record boundary. Only item 9 is a new engine.

### 3a. Query-pool contract (from the native model — the RTL spec)

`corev_apu/apu/tools/vn_query_replay.py` + `vn_golden.py` already define the bounded
semantics the RTL must mirror; this is the implementation contract, not a claim of RTL
support:

- **Pool kinds:** `OCCLUSION(0)`, `PIPELINE_STATISTICS(1)`, `TIMESTAMP(2)` only;
  `queryCount ≤ 4096`; unknown types refuse at create. Statistics pools admit mask
  `0x87` = spec bits {0 IA-vertices, 1 IA-primitives, 2 VS-invocations, 7
  FS-invocations}; other statistic bits refuse at create.
- **Slot state** (`qslots[index]`): `None` = unavailable; integer = occlusion/timestamp
  value; list-of-int = statistics per-counter array in spec bit order.
- **Ops:** `vkCmdResetQueryPool` → slots `None`; `vkCmdBeginQuery`/`Indexed` opens an
  accumulator (occlusion = fragment-sample count; statistics = per-counter list);
  `vkCmdEndQuery` publishes the accumulated value(s); `vkCmdWriteTimestamp(2)` stamps
  `0` (timestampPeriod is 0 in the bounded profile — honest, not a fabricated clock);
  `vkCmdCopyQueryPoolResults` writes each result as `counters` × (8 B if flags&1 else
  4 B) + optional 4 B availability (flags&8) padded to `stride` into the destination
  buffer extent; unstamped slots copy as 0 / availability 0.
- **Counters the stages must produce:** four monotonic counters for the
  statistics mask `0x87` — IA-vertices and IA-primitives (input-assembly
  counts in `g6lc_apu_rast`, taken at fetch/assembly *before* clip/cull so
  they match the spec's pre-rasterisation meaning), VS-invocations and
  FS-invocations (shader-dispatch counts on the `shwave`/`shcore` path,
  one per launched wave-lane group) — plus a fragment-sample counter for
  occlusion (post depth/stencil, pre-colour-write, in the ROP).  The
  existing `stat_o` `{pix,prim,busy}` triple is the export pattern, not
  these values; see the counter-source note in §3a-i.
- **Storage (decision):** slot state lives in a per-pool **ObjPay result
  extent**, *separate* from the small create-parameter `pay_words` extent the
  generic `is_pay_kind` path already allocates.  Two distinct extents are
  needed and must not be conflated: `pay_words` holds the staged
  `VkQueryPoolCreateInfo` words (consumed once at create), while the result
  extent holds the live `qslots` and persists for the pool's life.  At
  `CREATE_QUERY_POOL`, after parsing `{queryType, queryCount,
  pipelineStatistics}`, vnfront issues a second `APU_OBJPAY_OP_ALLOC` of
  `queryCount × stride` bytes where `stride = counters×8 + availBytes`
  (`counters` = 1 for occlusion/timestamp, mask-popcount for statistics;
  `availBytes` = 1 — the bounded profile always allows the availability
  bit).  Slot `i`'s counters sit at `i × stride`.  The pool's ObjTab entry
  keeps `{type, queryCount, counters, stride, resultPayBase}` — the
  `resultPayBase` is the second extent's base (the first/param extent is
  freed after create, exactly like the pipeline-module param extent).  `paymem`
  is 16 MiB so bounded 4096-slot pools fit with no new macro.
  `cmdexec` writes the result extent through its `op_req` client (Begin/End
  accumulate then publish; Reset/Copy iterate); `vnfront` reads the same
  extent through its `op_req` client to answer `vkGetQueryPoolResults`.
  Caveat to verify at implementation: `op_req` is currently used for
  record-payload walks at `imm[7]` bases — confirm it can address an
  arbitrary held ObjPay base, else the result store needs an
  aperture-backed fallback.
- **Ordering:** `EndQuery` must drain outstanding draw work before snapshotting
  (the same wait `PIPELINE_BARRIER` already performs), then publish.  Because
  the drain is per-record-stream, `Begin/End` bracket the draw records between
  them; the counter is the cumulative `stat_o` value latched at `Begin` and
  differenced at `End` (counters are free-running, monotonic).

#### 3a-i. Implementation map (verified against the RTL this pass)

The action table `APU_VN_ACT[type]` (`g6lc_apu_vn_pkg.sv:5074`) already routes
the object lifecycle — no table regeneration needed for the pool itself:

| Venus type | Action | obj_kind | Status today |
|---|---|---|---|
| 47 `CREATE_QUERY_POOL` | `ALLOC` | 26 `VK_QUERY_POOL` | routed; needs param parse + result-extent alloc + validation |
| 48 `DESTROY_QUERY_POOL` | `RETIRE` | 26 | routed; needs `is_auxret_kind`/extent free for the result store |
| 49 `GET_QUERY_POOL_RESULTS` | `UNSUPPORTED` | — | **not implemented** — needs a new act class or QUERY-kind reply |
| 127/128 `BEGIN/END_QUERY` | STATE (cmdexec) | — | classified, hits `default:` no-op |
| 129 `RESET_QUERY_POOL` | STATE (cmdexec) | — | classified, no-op |
| 130/205 `WRITE_TIMESTAMP(2)` | STATE (cmdexec) | — | classified, no-op |
| 131 `COPY_QUERY_POOL_RESULTS` | **not classified** → NOP | — | add to `rec_cls` + executor |
| 184/185 `BEGIN/END_QUERY_INDEXED` | not classified → NOP | — | add if the bounded profile keeps them |

Concrete insertion points:
- **Create:** `g6lc_apu_vnfront.sv` `StAllocCpl`-adjacent create path — add a
  `act_q.obj_kind == VK_QUERY_POOL` arm that (a) validates `queryType ∈
  {0,1,2}`, `1 ≤ queryCount ≤ 4096`, statistics mask ⊆ `0x87`; (b) issues the
  second `APU_OBJPAY_OP_ALLOC` for `queryCount × stride`; (c) stores
  `{type,count,counters,stride,resultPayBase}` into the ObjTab entry `aux`/
  `state`.  `is_pay_kind` must **not** blindly include kind 26 (that would
  size the param extent wrong) — the result extent is a separate alloc.
- **Get results:** vnfront `APU_VN_ACT_QUERY` reply path (the `Exec*` kinds at
  `g6lc_apu_vnfront.sv:1552`) is the model for a computed reply — add a
  `GET_QUERY_POOL_RESULTS` exec kind that walks the pool's result extent via
  `op_req` and streams the requested slots.
- **Execute:** `g6lc_apu_cmdexec.sv` STATE case (`:1449`) — add arms for
  RESET/BEGIN/END/WRITE_TIMESTAMP/COPY that resolve the pool handle, then
  walk the result extent via the executor's `op_req`/`mp_req`.
- **Counter source (verified this pass):** `g6lc_apu_rast.stat_o` is
  `{n_pix, n_prim, n_busy}` — pixel writes at `S_ROP_WR`, primitives
  reaching `S_PR_W` (all topologies, once, pre-cull), and busy cycles.
  **None of these equal the Vulkan statistics counters**: `n_prim` is
  post-clipping/post-cull assembly, not IA-primitives; `n_pix` is colour
  writes, not FS-invocations (a shader can run and write nothing —
  discard, depth-only, multisample); `n_busy` is a utilization metric,
  not a query counter.  The statistics mask `0x87` needs four *new*
  monotonic counters — IA-vertices (vertex-fetch count), IA-primitives
  (assembled pre-clip), VS-invocations and FS-invocations (shader-wave
  dispatch counts) — and occlusion needs a fragment-sample (post
  depth/stencil, pre-colour) count.  `stat_o` is the *pattern* to copy
  (free-running `always_ff` counters behind `PerfCountersEn`, exported
  as a packed bus), not the values.  `vgtop` wires `i_rast.stat_o` to a
  new `cmdexec` `qry_stat_i` port once the real counters exist; enabling
  `PerfCountersEn` before then is dead logic.
- **Model parity:** `vn_golden.py` `qslots` + `vn_query_replay.py` already
  define the semantics — the RTL must match slot-for-slot.

#### 3a-ii. `CREATE_QUERY_POOL` field contract (from `vn_golden.py:4230`)

The record immediates the create arm must read (all `& 0xFFFFFFFF`):

| imm | Field | Rule |
|---|---|---|
| `imm[0]` | reserved/flags | must be `0` |
| `imm[1]` | `queryType` | ∈ `{0 OCCLUSION, 1 PIPELINE_STATISTICS, 2 TIMESTAMP}` |
| `imm[2]` | `queryCount` | `≤ 4096` (0 allowed → empty pool) |
| `imm[3]` | `pipelineStatistics` | qtype 1 → mask ⊆ `0x87`; else must be `0` |

Any violation → `VK_ERR_FEATURE_NOT_PRESENT` **before** the ObjTab alloc.
On success the entry carries `size = queryCount`, the slot store, and
`aux = queryType | (pipelineStatistics << 8)` — the RTL packs the same
fields plus `stride`/`resultPayBase` into the fields §3a reserves.

#### 3a-iii. Command operand contract (from `vn_query_replay.py:255`)

Record `imm[]` layout the `cmdexec` arms must read (pool handle rides the
record `handle[]`, resolved by ObjTab LOOKUP to `aux`/`size`):

| Command | imm | Validation (bounded) |
|---|---|---|
| `RESET_QUERY_POOL` | `[0]=first, [1]=count` | `first+count ≤ size`; `count==0` is a no-op |
| `BEGIN_QUERY`/`INDEXED` | `[0]=query, [1]=flags` | `query<size`; occlusion/statistics flags ⊆ `1` (PRECISE); indexed `index==0` only |
| `END_QUERY`/`INDEXED` | `[0]=query` | must have an open begin on `(pool,query)` |
| `WRITE_TIMESTAMP(2)` | `[0]=stage/scope, [1]=query` | TIMESTAMP pool only; `query<size`; value is honest `0` |
| `COPY_QUERY_POOL_RESULTS` | `[0]=first,[1]=count,[2]=flags,[3:4]=dstOff u64,[5:6]=stride u64` | range/stride/capacity checks; `counters` from pool type; `flags&1`→8B else 4B, `flags&8`→+4B avail |

Slot addressing: slot `i` result record at `resultBase + i×8` words
(uniform 8-word slot).  `resultBase = (aux[63:48] << 6)` words,
`words = aux[47:32]`.  `aux[7:0]` = queryType, `aux[31:8]` =
pipelineStatistics mask.  Counters-per-slot: 1 for occlusion/timestamp,
`popcount(aux[31:8])` for statistics pools.

## 4. Throughput: measured state and the next structure

Counters (`PerfCountersEn`, wave engine, local bench, one dispatch, 8 lanes):

| Vector | Cycles before | Cycles now | Instructions | Cycles per wave-instruction | Share in load/store |
|---|---:|---:|---:|---:|---:|
| `bufcopy_1` | 2,302 | 1,942 | 52 | 37 | 31% |
| `vec4arith_1` | 13,538 | 10,590 | 160 | 66 | 56% |
| `math450_1` | 58,550 | 47,950 | 1,012 | 47 | 39% |
| `agg_local_1` | 23,470 | 18,714 | 232 | 81 | 59% |
| `cts_b2b_1` | 50,738 | 46,748 | 1,721 | 27 | 25% |
| whole suite (516 cases) | 5,839,342 | 5,173,971 | | | |

Five control-path changes gave −11.4% with identical results: streamed operand fetch,
overlapped operand lookups, descriptor reuse within an instruction, read-beat reuse, and
the load/store advance folded into the access completion.

What the numbers say about structure:

- A wave-instruction costs 27–81 cycles for 8 lanes. The fixed part (fetch, type and
  regmap lookups, write-back) is about 20–25 cycles even with no memory access
  (`cts_b2b`). That part is what predecoded rows remove: one table read per instruction
  instead of one per SPIR-V word, id, and type.
- The memory part is lane-serial: `vec4arith` makes 264 requests for 160 instructions and
  spends 56% of its time there, about 23 cycles per request including descriptor checks.
  Eight lanes' addresses differ only by a stride in the common case, so one bounds check
  and a burst can replace eight checks and eight single beats. This needs more than one
  request in flight on the memory port, which today serves one beat for the whole device.
- Neither change alters results. Both are local to one core, which is why they come
  before a second core.

Order: predecoded rows; lane-burst memory with a multi-beat port; then shader cores with
the fragment batch (later the tile) as the unit of work; then raster setup and output
width. Each is admitted by the same bench results and a counter delta, as in
`performance-area-scalability.md` §1.

Refined 2026-11-12 in `performance-area-scalability.md` §8 (passes TP0–TP9, gates
G-T1…G-T3). Three things change the order above: a baseline and an access-shape counter
come first (TP0); pipelined issue and a register file inside the SRAM envelope come before
any second core (TP3, TP3a); and the graphics path gets an on-chip record store and vertex
reuse early (TP4, TP5), because every vertex and fragment record crosses DRAM twice today.
The stages outside the shader core (submission, draw assembly, clears, vertex fetch, setup,
interpolation, texturing, output merge, transfers, presentation) are read and ordered in
§9 of the same file (passes FP0–FP13, gates G-F1…G-F3). The families of §3 above attach to
that order: transform feedback and the query-dominated lists need FP0's counters as real
query sources; multisampling, resolve, interlock and programmable blending attach to the
tile stage of FP10; filtered blit and YCbCr sampling to the texture unit of FP9.

## 5. Not established here

- No case of these families has run; every "validates" line is an inference from names.
- Mesa's advertisement of each extension through Venus at 25.2.8 is unchecked.
- No synthesis result exists for any change in this file's throughput table.
- The IP review of the ray, shading-rate and deferred-raster mechanisms (plan §6) is not
  done; build order above is engineering order only.
