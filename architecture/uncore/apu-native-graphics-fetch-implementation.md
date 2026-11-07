# Native graphics vertex/index fetch stage

Status: implemented, host-native-model evidence only.  No draw submission,
shader execution, rasterization, framebuffer write, capset advertisement,
RTL, CTS, Linux or physical qualification is claimed or enabled.  The
transfer-only wire path is unchanged; `vkCmdDraw*` records still fail replay
admission atomically.

## Scope

`corev_apu/apu/tools/vn_graphics_fetch.py` adds the first draw-pipeline stage
as an executor runtime operation, mirroring the `Compute`/`ShaderRuntime`
contract:

- `Fetch` — frozen operation carrying the resolved operand set for one draw:
  `indexed` flag, optional index `BufferOperand`, up to 8 `FetchVertex`
  attribute rows `(location, VkFormat, offset, stride, rate, span)`, and
  exactly one of a direct `(count, instances, first, vertex_offset,
  first_instance)` tuple or an indirect `BufferOperand`.
- `FetchRuntime` — cooperative `advance(budget)` that performs live reads
  through `execution.state.aperture` at `owner.base + operand.offset`,
  exactly like the compute indirect-argument path.  Reads are ordered after
  earlier queued writes in the same job and across jobs by executor FIFO.
- `TransferExecutor.enqueue` accepts `Fetch` beside `Compute` (same runtime
  table, owner pinning and byte-budget accounting); `_turn` dispatches it and
  records `job.fetch_stats[op] = {records, robust, steps}` on retirement.

## Record image

Each fetched `(instance, vertex)` pair emits one 144-byte VS-in record
(`ATTR_STRIDE`, mirroring `g6lc_apu_sh_pkg` / `spirv_model`):

- slots 0–7 (locations 0–7): four u32 words per location.  Component decode
  covers exactly the `VATTR_OK` admitted set — R/RG/RGB/RGBA at 8/16/32-bit
  UNORM, SNORM, UINT, SINT and SFLOAT (f16 promoted to f32; unorm/snorm
  converted to float; int classes passed through).
- slot 8 (+128): `{VertexIndex, InstanceIndex, 0, 0}`.  `VertexIndex` is the
  post-`vertexOffset` index for indexed draws and `firstVertex + i` for
  non-indexed; `InstanceIndex` is `firstInstance + instance`.

Instance-rate attributes (`rate=1`) are indexed by `InstanceIndex`;
vertex-rate attributes by `VertexIndex`.

## Bounds and robustness

- `MAX_RECORDS = 1024` vertex×instance records per operation; overflow is a
  `MemoryError` at admission, never a partial allocation.
- `MAX_ATTRS = 8` attribute rows, matching the vnfront `na <= 8` gather bound.
- Index/attribute reads outside their admitted operand extents return zero
  and increment `robust`; they never fault the job and never read outside the
  pinned owner extent.
- Indirect `DrawIndirectCommand`/`DrawIndexedIndirectCommand` words are read
  at execution time (16/20 bytes), so earlier queued writes are observed;
  argument counts are re-validated against `MAX_RECORDS` before allocation.
- Zero-attribute fetches are legal: builtin-only vertex shaders still receive
  correct `VertexIndex`/`InstanceIndex` records.

## Evidence

- `test_vn_graphics_fetch.py`: 11 tests — format decode (unorm/uint/sint/f16/
  f32), indexed reorder + `vertexOffset`, instance-rate indexing,
  indirect-argument live reads after a prior transfer in the same job,
  indexed-indirect layout, robust OOB (index and attribute), lease
  hold/release and context cancellation, record/argument budgets, partial
  budget advance/resume, builtin-only records.
- Remote frozen cohort `native-execution.s1isdnb1` on `ovh_calltorch`:
  **579 tests PASS in 16.193 s**, `sources_unchanged: true`, pulled to
  `remote-runs/native-fetch-01/output/`.
- Audit: 3-source MIT tier/header/ASCII/syntax/whitespace pass
  (`vn_graphics_fetch.py`, `test_vn_graphics_fetch.py`,
  `vn_transfer_executor.py`).

## Not done here

- `DrawPlan` → `Fetch` op conversion and `vkCmdDraw*` replay dispatch: draws
  remain refused until the VS, raster, fragment and writeback stages exist,
  so a fence can never retire having performed only a prefix of a draw.
- Vertex-shader stage execution, primitive assembly, rasterization,
  interpolation, fragment shading and attachment writeback.
- Indirect `drawCount > 1` / multi-record strides (single-record profile).
- Any capability or qualification promotion; zero capsets remain.
