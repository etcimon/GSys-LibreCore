# APU Vulkan engine — consolidated structure (2026-10-03)

Controlling plan: `C:\Users\etcim\.devin\plans\plan-5ddc97674e5bf9b0.md` (steps 3–5, 8).
Lane map: `apu-graphics.md`. Module graph: `corev_apu/apu/AGENTS-impl-interplays.md` §15.
This file owns the **engine decomposition** the stock-client (hardware Venus) route is
built on, the generated-decoder methodology, and the interfaces the consolidation
increments implement. It does not promote any fixture result to qualification.

## 1. Review of the catalog structure (what this consolidates)

Measured on `E:\cva6` 2026-10-03 (uncommitted work of the parallel session included):

| Item | Value |
|---|---|
| `corev_apu/apu/*.sv` | 582 files / 112.7 k lines; `verif/tb/apu/*.sv` 364 / 112.0 k lines |
| `g6lc_apu_cfg_pkg.sv` | 564 `*En` fields (plan §3 asks for a small number of engine gates) |
| `g6lc_apu_pkg.sv` | 13.5 k lines, one constant block per command |
| `g6lc_apu_bru.sv` | 14,620 lines, one FSM with ~190 Fire/Wait states, >100 per-command flag registers, ~30 six-word reply arrays; last remote screen 246,341 generic cells / 59,751 flops — larger than a CVA6 core, renders nothing |
| Per-command leaves `g6lc_apu_v??` | ≈120 modules; each accepts one shape (e.g. `vdw`: `vertexCount==3`, `instanceCount==1`, `first*==0`; `vxi`: 64×64 2D STORAGE linear R8G8B8A8; `vbm` publishes constant size 4096/align 256) |
| Doorbell stack | `qty/qta/qtb`, `vct/vca/vcb`, `qpu/qpa/qpb`, `ntk/nta/ntb`, `vqt/vqa/vqb`, `vax/vaa/vab` — the same stack cloned three times instead of parameterized |
| Catalog fold cost | one remote pass (4 commands + bru/qbn/qtb re-synthesis) ≈ 66 min |

Classification, in the plan's vocabulary:

- **Reusable production primitive**: checked DMA read/write, SG table, `chain`/`cdma`
  NEXT walker, `vnring` layout, `avu`/`uir`/`qdn` publication order (elem → `used.idx`
  → ISR), `ShmEn` SHM id 1, `hvis` HOST_VISIBLE blob map + `context_init`, `vcap`
  160-byte Venus capset wire, `tdma` testharness `slave[2]` join.
- **Generalizable prototype**: `spirv` (direct SSA interpreter, add/mul, one invocation),
  `gnh` (generational handle semantics, 32 flop slots), `cover` (edge-function sample),
  `vgpu_ftx` (one-texel validator).
- **Fixed-shape diagnostic**: every `g6lc_apu_v??` command leaf, `bru`/`qbn`/`qtb`,
  `aru`/`qal`/`qta`, the three doorbell stacks. Their value is the **wire facts** they
  encode (type ids, sType ids, word positions, reply positions); those become generated
  test vectors, not RTL.
- **Not present**: command *recording* (Cmd* set flags at decode time; two draws are
  unrepresentable), SRAM-backed object/state tables, any shader stage beyond scalar
  integer add/mul, any raster/ROP/sampler beyond one sample, a connected
  queue→decode→execute→surface→completion path.

The parallel session keeps folding into `bru/qbn/qtb` (user decision 2026-10-03). Nothing
in this file edits those modules; the engines below are built beside them and the catalog
becomes frozen diagnostic/vector material once the generated path is regression-equivalent.

## 2. Methodological fix: the wire format is generated, so generate the decoder

Mesa's Venus ICD does not hand-write `vn_encode_vk*`: `venus-protocol` (MIT,
`https://gitlab.freedesktop.org/virgl/venus-protocol`) generates them from `xmls/vk.xml`
plus `xmls/VK_EXT_command_serialization.xml` (command type ids) with fixed rules in
`vn_protocol.py` / `templates/types_*.h`:

| Element | Wire |
|---|---|
| command | `u32 VkCommandTypeEXT`, `u32 VkCommandFlagsEXT` (bit0 = GENERATE_REPLY), then parameters in declaration order |
| scalar / enum / `VkBool32` / `float` | 4 bytes; 8-byte scalars (`u64`, `size_t`, `VkDeviceSize`, `VkDeviceAddress`) 8 bytes |
| handle | `u64` object id chosen by the **driver** (`vn_cs_handle_load_id`); the renderer keys its object table by that id |
| pointer | `u64` presence (`vn_encode_simple_pointer`), then the pointee if non-zero |
| dynamic array | `u64 array_size`, then elements; `<4`-byte element arrays padded to 4 |
| struct | fields in order; `sType` 4 bytes; `pNext` as pointer presence + extending struct, chained |
| reply | `u32 type`, then `VkResult` if any, then out-parameters in order |

Pins (verified 2026-10-03 against Mesa tags):

| Baseline | Mesa headers banner | vk.xml | Public venus-protocol commit |
|---|---|---|---|
| Ubuntu 26.04.1 (Mesa 26.0.x, vendored `src/virtio/venus-protocol/`) | `git-307d2d0b` (not on the public repo) | 1.4.334, wire format 1 | `9fa07f3cf7810df293abe0ff6a96032192f960d3` (2025-12-01; last public commit at 1.4.334 before the 1.4.343 uprev) — to be validated by regenerating and diffing against the vendored `mesa-26.0.8` headers |
| Ubuntu 24.04 (Mesa 24.0.x) | `git-bfa3ebfb` | 1.3.269, wire format 1 | `bfa3ebfbb3e8c5894accc9c81c323a24f2a89b17` (2023-11-14) |

`VkCommandTypeEXT` values are explicit in `VK_EXT_command_serialization.xml`, so the two
baselines share ids for the commands both support. Reference lives as a lazy sparse
submodule `specs/venus-protocol` (`update = none`, `shallow = true`, tier U), like the UE
and kernel references; the generated SystemVerilog is first-party (tier R) and carries the
generator name, pin and vk.xml version in its banner.

**Generator** `corev_apu/apu/tools/gen_vn_tables.py` (tier T, MIT) imports the pinned
`vkxml.py`, takes a checked-in command set (`vn_command_set.txt`) and a device profile
(`vn_device_profile.toml`: truthful limits/features/formats/memory types), and emits:

1. `corev_apu/apu/include/g6lc_apu_vn_pkg.sv` — type ids, kinds, decode/reply micro-program
   ROMs, chain tables, constant pool, profile constants;
2. `verif/tb/apu/vn_vectors/*.hex` — randomized valid streams and mutations encoded by a
   Python golden encoder that follows the same rules (`vn_golden.py`), with the expected
   decode record for each command.

Adding a command means adding one line to the command set and regenerating; no RTL edit.

## 3. Engine decomposition and config gates

Few gates, each an engine, each default-off, each with an `Enable=0 → no cells` screen:

```text
 virtio transport (mmio now, pci later)  ShmEn          [exists: virtio_mmio, hvis, vcap]
   -> virtq walker  (chain/cdma/avn)                    [exists]
   -> vn_ring reader (vnring)                            [exists]
   -> VnDec   g6lc_apu_vndec   generated table decoder   [increment 2]
   -> ObjTab  g6lc_apu_objtab  tc_sram generational objects + id directory [increment 2]
   -> CmdRec  g6lc_apu_cmdrec  recorded command buffers in tc_sram          [increment 3]
   -> Exec    g6lc_apu_cmdexec submit-time walker: draws/dispatches/copies/barriers/fences
        -> ShaderCore  direct-SPIR-V SIMT waves  (+ MatHelper port to AI dot PEs)
        -> Raster      TBDR binning, tile raster/interp/early-Z, ROP, tile buffer
        -> Xfer        copies/clears/blits via checked DMA
   -> Reply builder (generated reply ROM) -> response bytes -> used elem -> used.idx -> ISR  [exists: avu/uir/qdn]
```

Config fields (to be added to `ApuCfg` at `g6lc_apu_sys` integration, not before —
`g6lc_apu_cfg_pkg.sv` is under concurrent edit): `VnFrontEn`, `ObjTabSlots`,
`CmdRecWords`, `ShaderWaves`, `ShaderLanes`, `RasterTile`, `TileMrt`, `MatHelperEn`.
Until integration every engine is `parameter bit Enable` standalone with its own private
flist, exactly like the existing leaves. `FeatureVirgl`/Venus advertisement stays illegal
until the end-to-end path exists (plan §3).

## 4. VnDec — table-driven decode micro-program (interface of record)

One module replaces the per-command leaves. CS access is one SRAM read port
(`cs_addr_o`/`cs_rdata_i`, word addressed, one-cycle), bounded by `cs_len_i`.

Architectural registers: `pc` (CS word), `mpc` (ROM address), `q[0..7]` 64-bit (handles,
pointers, sizes), `imm[0..15]` 32-bit, `cnt[0..3]` 32-bit array counts, `pres[0..7]`
pointer presence, two-deep loop stack `{mpc_start, remaining}`, `blob[0..1]`
`{cs_word_offset, words}`.

ROM word: `{op[7:0], a[7:0], b[31:0]}` (48 bits). Micro-ops:

| op | semantics |
|---|---|
| `U32 a=slot` | read one word into `imm[a]`; `a=0xFF` discards |
| `U64 a=slot` | read two words (lo, hi) into `q[a]` |
| `HANDLE a={role[2:0],slot[4:0]} b=kind` | read `u64` id into `q[slot]`; role `LOOKUP` (must exist as `kind`), `NEW` (must not exist; this command allocates it), `RETIRE`, `OPTIONAL` (zero allowed). Zero id with non-OPTIONAL role faults |
| `PTR a=slot b=skip` | read `u64` presence into `pres[a]`; if zero, `mpc += skip` (generator computes the pointee program length) |
| `STYPE b=constidx` | read one word; fault unless equal to `const[b]` |
| `PNEXT b=chaintbl` | Venus encodes a chain recursively (`types_chain.h`): `presence, sType, <rest of chain>, body` — so the wire carries all `{presence, sType}` headers first, a zero presence, then the bodies in **reverse** order. The decoder reads headers while presence ≠ 0, looks each sType up in chain table `b` (pairs `{sType const, mpc}` terminated by 0), appends the entry index to `chain[0..7]` (ordered, for reply echo), then runs the collected body programs last-in-first-out via a return stack (`RET` ends a body). Unknown sType → `FAULT_PNEXT` carrying the sType; more than 8 headers → `BOUND`. Chain tables list every `structextends` candidate of the advertised core version and extensions. (Corrected 2026-10-03 after the Mesa C differential; the first draft here described a header+body interleave that is not the wire format.) |
| `ARRAY a=cntslot b=elem_len` | read `u64` count into `cnt[a]`; fault if above the profile bound; push loop; run the element program `cnt` times (`ENDARR` pops/loops) |
| `BLOB a=slot b=elem_bytes` | read `u64` count; record `blob[a] = {pc, ceil(count*elem_bytes/4)}`; `pc +=` that many words (used for `pCode`, `pData`, strings) |
| `FLAGS a=slot b=constidx` | read one word into `imm[a]`; fault if `word & ~const[b]` (unsupported usage/flag bits are refused, never silently accepted) |
| `SKIPW b=n` | `pc += n` (parsed but unconsumed fields) |
| `CHECK a=slot b=constidx` | fault unless `imm[a] == const[b]` (e.g. `VK_STRUCTURE_TYPE_*` inside unions, `sharingMode`) |
| `OBJ b=kind` | declares the object kind this command allocates/retires |
| `END a=replyprog` | record valid; `reply_prog_o = a` |

Faults: `UNKNOWN_TYPE`, `STYPE`, `PNEXT(sType)`, `FLAGS(word)`, `BOUND` (`pc > len`,
count above bound, loop depth), `HANDLE_ZERO`. Every fault leaves `pc` at the offending
word for the diagnostic record and the command produces no side effect.

Outputs (`apu_vn_op_t`): `type`, `flags`, `q[8]` + `kind[8]` + `role[8]`, `imm[16]`,
`cnt[4]`, `blob[2]`, `pres[8]`, `reply_prog`, `fault`, `fault_word`. Throughput target one
CS word per cycle; the module is a few thousand cells, the ROM scales with the command set.

Reply program ROM (same word shape): `RTYPE`, `RRESULT` (from the executor), `RU32 src`,
`RU64 src`, `RHANDLE slot`, `RCONST b=constidx,count` (profile structs), `RCHAIN b=tbl`
(replays the recorded `chain[]` in the same recursive wire shape the driver's
`vn_decode_*_pnext` expects: all `{presence=1, sType}` headers in chain order, a zero
presence, then each struct's profile-constant body in reverse order — this is how
`vkGetPhysicalDevice{Properties,Features,MemoryProperties}2` answer exactly the structs
the driver chained), `RBLOB`, `REND`. Replies are built into the WRITE
descriptor window exactly where Mesa's `vn_decode_vk*_reply` reads them; GENERATE_REPLY
absent → no reply bytes.

## 5. ObjTab — generational object table with id directory

Replaces `gnh` flops and the ad-hoc `*_q` state flags of `bru`. Entry SRAM (`tc_sram`,
`ObjTabSlots` default 256, one port) holds `{live, kind[5:0], gen[15:0], parent_slot,
refcnt, pins[7:0], state[31:0], bind_mem_slot, bind_offset[63:0], size[63:0],
aux[63:0]}`. A directory SRAM (`2×slots` buckets, linear probe ≤ 8) maps the driver's
64-bit object id → slot, because every later command names the object by that id.

Ops (ready/valid request, one completion): `ALLOC(kind, id, parent)` → `{gen,slot}` or
`DUP`/`FULL`; `LOOKUP(id, kind)` → entry or `MISS`/`KIND`/`GEN`; `PIN`/`UNPIN`;
`RETIRE(id)` refused while `pins≠0` or `refcnt≠0` (children alive); `SETSTATE(id, mask,
value)`; `SETBIND(id, mem_slot, offset)`; `RESET_CTX(ctx)` retires every object of a
context in bounded time. Handle `{gen[15:0], slot}`; `gen` wraps past 0, so a stale handle
after 65,535 reuses of one slot still misses. Parent `refcnt` keeps a DEVICE alive while
its BUFFERs exist (Vulkan validity, enforced in hardware rather than trusted).

### 4b. Reply builder `g6lc_apu_vnrep` (interface of record, increment 3)

Runs `APU_VN_REPLY_ROM` from `APU_VN_REPLY_ENTRY[op.reply_prog]` and writes words into
the command's WRITE window through one write port (`rep_we_o`, `rep_addr_o`,
`rep_wdata_o`, word-addressed from `rep_base_i`, bounded by `rep_len_i`). Inputs:
`op_i` (the decoded record; `RHANDLE`/`RBLOB`/`RPTR` echo `q[]`, blobs and presence
from it — Venus replies echo the driver-chosen ids), `result_i` (`VkResult` from the
sequencer), and an **exec word buffer** `exec_w_i[0..63]` filled by the sequencer for
`SRC=EXEC` fields (memory requirements, fence status, query counts). Ops: `RTYPE`,
`RRESULT`, `RU32/RU64 src` (`CONST` pool or `EXEC` buffer, sequential cursor), `RHANDLE
slot`, `RPTR pres,skip` (presence echo; absent → skip the pointee program), `RCONST
idx,count` (profile block), `RCHAIN tbl` (recursive headers-then-reversed-bodies shape of
§4), `RBLOB slot` (echo the CS blob words through a CS read port), `REXBUF` (words from
the exec buffer, count from `exec_n_i`), `REXEC n` (n struct words from the exec buffer),
`RRET`, `REND`. `GENERATE_REPLY` clear → no bytes, `rep_words_o = 0`. Overrun of
`rep_len_i` → `fault_o` and the command fails with `VK_ERROR_UNKNOWN`-class result,
never a partial reply. Exit for the increment: a Mesa **C decode harness**
(`vn_decode_vk*_reply` from the vendored headers) decodes the golden reply bytes of
every replying command in the set to the expected values, and the RTL matches the
golden words.

### 4c. Action table `APU_VN_ACT[type]` (generated classification)

The sequencer needs one small per-command record, emitted by the generator from
names and vk.xml, not hand-written per command:

| Class | Rule | Sequencer behaviour |
|---|---|---|
| `ALLOC` | `vkCreate*`, `vkAllocateMemory`, `vkAllocateCommandBuffers`, `vkAllocateDescriptorSets`, `vkGetDeviceQueue*` | `ObjTab.ALLOC(OBJ kind, NEW id, parent = first LOOKUP handle)`; `DUP`→`VK_ERROR_UNKNOWN`, `FULL`→`VK_ERROR_OUT_OF_DEVICE_MEMORY` |
| `RETIRE` | `vkDestroy*`, `vkFree*` | `ObjTab.RETIRE`; `PINNED`/`BUSY_CHILDREN` → `VK_ERROR_UNKNOWN` (validity violation, never silently ignored) |
| `BIND` | `vkBind{Buffer,Image}Memory*` | `ObjTab.SETBIND(resource, memory, offset)` |
| `QUERY` | `vkGetPhysicalDevice*`, `vkEnumerate*`, `vkGet*Requirements*`, `vkGetDeviceMemoryCommitment`, `vkGetRenderAreaGranularity`, `vkGetImageSubresourceLayout` | LOOKUPs only; reply from profile/exec buffer |
| `CB_BEGIN` / `CB_END` / `CB_RESET` | `vkBeginCommandBuffer`, `vkEndCommandBuffer`, `vkResetCommandBuffer` | `CmdRec.BEGIN/END/RESET`; `ObjTab.SETSTATE` lifecycle bits (`INITIAL→RECORDING→EXECUTABLE→PENDING`) |
| `RECORD` | `vkCmd*` | requires `RECORDING`; `CmdRec.APPEND(resolved record)`; a `vkCmd*` on a non-recording buffer → `VK_ERROR_UNKNOWN` and the buffer becomes `INVALID` |
| `SUBMIT` | `vkQueueSubmit` | every listed buffer must be `EXECUTABLE`; `PIN` them, enqueue `{fence, buffers}` to the executor |
| `WAIT` | `vkQueueWaitIdle`, `vkDeviceWaitIdle`, `vkWaitForFences`, `vkGetFenceStatus`, `vkResetFences` | read/clear fence state; waits complete only when the executor's `done_seq` has passed the submit's seq |
| `POOL_RESET` | `vkResetCommandPool`, `vkResetDescriptorPool` | `CmdRec.RESET` for every buffer of the pool (pool = parent in `ObjTab`) |
| `MAP` | `vkMapMemory` (excluded), `vkUnmapMemory`, `vkFlush/InvalidateMappedMemoryRanges` | LOOKUP + no-op on a HOST_COHERENT type; the aperture is HOST_VISIBLE SHM |
| `NOP_OK` | `vkCreatePipelineCache`-class, `vkDestroyPipelineCache` | ALLOC/RETIRE of a stateless object |

Everything not classified is `UNSUPPORTED` → `VK_ERROR_FEATURE_NOT_PRESENT` and a
diagnostic record; the generator lists the fallout so the set is tightened, never
widened by accident. Generated membership (2026-10-04, 120 commands): ALLOC 25, RETIRE
21, BIND 4, QUERY 17, CB_BEGIN/END/RESET 1/1/1, RECORD 35, SUBMIT 1, WAIT 5, POOL_RESET
2, MAP 3, NOP_OK 2, `UPDATE` 1 (`vkUpdateDescriptorSets` — LOOKUPs of the set and the
written buffers/views; descriptor contents are consumed by the shader core in increment
4), UNSUPPORTED 1 (`vkGetQueryPoolResults` — needs executor query data; stays refused
until queries execute).

## 6. CmdRec and the submit-time executor

`vkCmd*` are **recorded**, not executed, at decode. Increment-3 interfaces:

- **`g6lc_apu_cmdrec`** (`Enable`, `NumBufs` default 16, `RecsPerBuf` default 64): one
  `tc_sram` arena of `NumBufs × RecsPerBuf` fixed 16-word records, each the resolved
  decode `{type, flags, slot[0..3] (ObjTab slots of the first four handles, with kinds),
  imm[0..7]}` — the record *is* the decoded op, so the executor dispatches by `type`
  without a second encoding. Ops: `BEGIN(buf)`, `APPEND(buf, record)` → `FULL` at
  `RecsPerBuf`, `END(buf)` seals, `RESET(buf)`, `READ(buf, idx)` for the executor,
  `COUNT(buf)`. Per-buffer region table in flops `{count[7:0], recording, sealed}`.
  The buffer index lives in the CMDBUF's `ObjTab.aux`.
- **`g6lc_apu_cmdexec`** (`Enable`, `Fences` default 16): submit FIFO `{seq, fence_slot,
  buf list ≤ 4}`; walks each buffer's records in order; state records (`BindPipeline`,
  `BindDescriptorSets`, `BindVertexBuffers`, `BindIndexBuffer`, `SetViewport`,
  `SetScissor`, `PushConstants`, `Begin/End/NextSubpass`) update the executor's state
  registers; work records (`Draw*`, `Dispatch*`, `Copy*`, `Fill/Update/Clear*`,
  `Blit/Resolve`) are issued on one **work port** `work_valid_o/ready_i/work_o
  {type, state snapshot, record}` with a completion `work_done_i` — the shader core,
  raster and Xfer engines of increments 4–5 attach there; `PipelineBarrier` waits for
  `work_done` of everything issued; every record's handles are re-resolved through
  `ObjTab.LOOKUP` at execution time, so a destroyed object between record and submit
  faults the submission (`done_seq` advances with `status = DEVICE_LOST` recorded on the
  fence) instead of using stale state. `done_seq_o` and per-fence `signaled` bits feed
  the `WAIT` class. `PIN` at submit, `UNPIN` when the buffer's records have all
  completed.
- **`g6lc_apu_vnfront`**: the sequencer tying `vndec → ACT → ObjTab → CmdRec/cmdexec →
  vnrep`: `start(cs_base, cs_len, rep_base, rep_len)` → `done(result, rep_words,
  fault)`. One command at a time; the queue path (`avn`/`qdn`, existing) feeds it and
  publishes the used element after `done`.

Exit for the increment: a **generated session** (Python: valid Vulkan ordering —
instance → physical device queries → device → queue → memory/buffers → shader module
→ layouts/pipeline → descriptor pool/set/update → command pool → allocate → begin →
bind/dispatch/draw → end → submit → wait → destroys in reverse) runs through
`vnfront` with every reply decoded by the Mesa C harness, `ObjTab` ending empty, the
executor having issued exactly the recorded work in order, plus the negative arms:
`vkCmd*` before begin, submit of an unsealed buffer, destroy of a pinned (submitted)
buffer, destroy of a device with live children, stale handle after destroy.

## 6b. Transport: virtio-gpu control processor and the Venus ring pump (increment 3b)

Source of truth, read for this section: Mesa 26.0.8 `src/virtio/vulkan/vn_renderer_virtgpu.c`,
`vn_ring.c`, `src/virtio/virtio-gpu/venus_hw.h`; the pinned Resolute
`include/uapi/linux/virtio_gpu.h`; venus-protocol `xmls/VK_MESA_venus_protocol.xml`.

**What the stock driver does at init** (`virtgpu_init_*`): requires kernel params
`3D_FEATURES`, `CAPSET_QUERY_FIX`, `RESOURCE_BLOB`, `CONTEXT_INIT`, and `HOST_VISIBLE`
(or `GUEST_VRAM`); `GET_CAPS` for capset 4 (Venus) into `struct
virgl_renderer_capset_venus`; `CONTEXT_INIT(capset 4)`; shmem = `RESOURCE_CREATE_BLOB
(blob_mem HOST3D, flags MAPPABLE, blob_id 0, size)` + `RESOURCE_MAP_BLOB` → mmap. The
capset must carry `wire_format_version 1`, the generator's `vk_xml_version`,
`vk_ext_command_serialization_spec_version`, `vk_mesa_venus_protocol_spec_version`,
`supports_blob_id_0 = 1`, `vk_extension_mask1[0] bit0 = 1` with the claimed renderer
extensions, `allow_vk_wait_syncs = 1`, `supports_multiple_timelines = 1` (asserted by the
driver), `use_guest_vram = 0` (blobs live in the device aperture). The capset is **profile
data**, generated into the package, not hand-coded words; the existing `vcap` leaf's
constants (`vk_xml 1.1.0`, protocol spec 1, `supports_multiple_timelines 0`,
`use_guest_vram 1`) do not satisfy this driver and are superseded.

**Ring protocol** (`vn_ring.c`): the driver creates a ring with `vkCreateRingMESA(ring_id,
{resourceId, offset, size, idleTimeout, headOffset, tailOffset, statusOffset,
bufferOffset, bufferSize, extraOffset, extraSize, pNext: RingMonitorInfo
[RingPriorityInfo]})` sent as a `SUBMIT_3D` execbuffer; `bufferSize` is a power of two.
Commands are written contiguously into `buffer[(cur & mask)…]` with wrap, then `tail` is
stored (seq_cst) as the running byte count `cur` (u32, wraps); if `status & IDLE` the
driver sends `vkNotifyRingMESA(ring, seqno, 0)` through `SUBMIT_3D`. The device consumes
`[head, tail)` as one command stream — each command's length is whatever `vndec`
consumed (`words`) — and stores `head = consumed byte count` with release semantics
**after** that command's side effects and reply bytes are visible; the driver waits on
`head ≥ seqno` (`vn_ring_wait_seqno`). Status bits: `IDLE` (bit0, set by the device when
it parks after `idleTimeout`; cleared when it resumes), `FATAL` (bit1), `ALIVE` (bit2,
watchdog, period from `RingMonitorInfo`). Before every replying command the driver sends
`vkSetReplyCommandStreamMESA({resourceId, offset, size})` on the same ring; the reply is
written at that window's start (`vkSeekReplyCommandStreamMESA(position)` moves the
cursor). Large streams arrive by `vkExecuteCommandStreamsMESA(streams[], replyPositions[],
deps, flags)`: each stream is a `{resourceId, offset, size}` window executed in order with
the reply cursor seeked to `pReplyPositions[i]`. `vkWriteRingExtraMESA(ring, offset,
value)` writes into the extra region. `vkSubmitVirtqueueSeqnoMESA` /
`vkWaitVirtqueueSeqnoMESA` / `vkWaitRingSeqnoMESA` order the virtqueue and ring timelines.

**Engines (interfaces of record):**

- **`g6lc_apu_vgctl`** — virtio-gpu control-queue processor. Input: one descriptor chain
  (header words + optional payload + WRITE response window) from the existing `avn` walker
  through checked DMA; output: response written to the WRITE window, then the existing
  elem → `used.idx` → ISR publication. Handles exactly: `GET_CAPSET_INFO` (`RESP_OK_CAPSET_INFO`
  for index 0 → id 4, max_version 0, max_size = capset bytes), `GET_CAPSET` (`RESP_OK_CAPSET`
  with the generated capset words), `CTX_CREATE` (`context_init & 0xff` must be 4, else
  `RESP_ERR_INVALID_PARAMETER`; `ObjTab.ALLOC(kind CONTEXT, ctx_id)`), `CTX_DESTROY`
  (`RESET_CTX`), `CTX_ATTACH/DETACH_RESOURCE`, `RESOURCE_CREATE_BLOB` (HOST3D + MAPPABLE +
  blob_id 0 → aperture allocation `ObjTab.ALLOC(kind BLOB, resource_id)` with
  `bind_offset/size` in the SHM window; any other `blob_mem`/`blob_id` →
  `RESP_ERR_INVALID_PARAMETER` until exported memory exists), `RESOURCE_MAP_BLOB`
  (`RESP_OK_MAP_INFO`, `map_info = VIRTIO_GPU_MAP_CACHE_WC`), `RESOURCE_UNMAP_BLOB`,
  `RESOURCE_UNREF` (RETIRE), `SUBMIT_3D` (`size` bytes of execbuffer → the pump's
  **transport stream** path). Header `flags & FENCE` → response `fence_id` echoed and
  the fence retired on the `ring_idx` timeline after completion; `ctx_id` scopes blob and
  ring lookups. Struct layouts are the UAPI ones (`ctrl_hdr` 24 bytes: type, flags,
  fence_id, ctx_id, ring_idx, pad). Unknown type → `RESP_ERR_UNSPEC`; truncated chain →
  no response bytes beyond the header, used length truthful.
- **`g6lc_apu_vnpump`** — Venus stream executor. Owns ≤ 4 ring descriptors (geometry
  from `vkCreateRingMESA`; `DestroyRing` frees), the reply-stream state `{blob slot,
  base, size, pos}`, and a word port into the aperture memory (`ap_re/we/addr/rdata/
  wdata`). Executes a **stream** `{base, bytes}` by running `vnfront` per command with
  the CS port translated through `base + ((cur + i) & mask)` for rings (linear for
  execbuffers and `ExecuteCommandStreams` windows); transport-class commands
  (`APU_VN_ACT_TRANSPORT`: the eleven MESA commands above) are executed by the pump
  itself, not by `vnfront`. Per ring: poll `tail` while active, park with `IDLE` after
  `idleTimeout` cycles of no work, wake on `NotifyRing`, store `head` after each command,
  `FATAL` on a decode fault (the ring is then dead until `DestroyRing`). Virtqueue seqno
  counter for `Submit/WaitVirtqueueSeqno`; `WaitRingSeqno` blocks the transport stream
  until that ring's `head ≥ seqno`.
- Aperture: the `ShmEn` window (`APU_SHM_BASE`, 1 MiB today) backed in the TB by a
  `tc_sram`-style word model; blob allocation is a first-fit over 4 KiB pages with a
  bitmap (`ObjTab` holds offset/size). The DRAM-backed aperture is a later increment.

Exit for 3b: a TB **guest model** that performs exactly Mesa's init on the control
queue (capset → context init → two blobs → map → `SUBMIT_3D[vkCreateRingMESA]`), then
drives the increment-3 session **through the ring** the way `vn_ring_submit_command`
does (`SetReplyCommandStream` before each replying command, tail store, `NotifyRing`
when idle, wait on `head`), checks every reply in the reply blob with the Mesa decode
harness, checks `head == tail` and `IDLE` at the end, every virtqueue element published
in order with truthful lengths, and the negative arms: wrong capset id on `CTX_CREATE`,
blob with `blob_id ≠ 0`, ring command stream with a decode fault → `FATAL` and no head
advance past it, `SUBMIT_3D` with `size` larger than the chain.

## 7. ShaderCore — direct SPIR-V execution, SIMT

The strict endpoint forbids a software compiler, so the hardware executes SPIR-V itself.
`g6lc_apu_spirv` already proves the shape: result ids index a register file. The engine:

- **Module commit** (`vkCreateShaderModule`): the module bytes are copied immutably into
  program SRAM; a one-pass hardware scanner builds the **type table** (id → scalar/vector
  width, component type, pointer storage class), **constant table**, **decoration table**
  (Location, Binding, DescriptorSet, BuiltIn, Offset), and entry-point table. Unsupported
  capabilities/opcodes fault at commit, so `vkCreate*Pipelines` can return
  `VK_ERROR_*` truthfully instead of failing at draw time.
- **Waves**: `ShaderLanes` invocations (default 8; UE SM5 fragment work wants 16–32 later)
  execute one instruction stream in lockstep with a divergence mask stack (SPIR-V
  structured control flow: `OpSelectionMerge`/`OpLoopMerge` give reconvergence points
  without a compiler). Result ids map to a wave register file in banked `tc_sram`
  (`ids × lanes × 32 bit`; id space bounded per module at commit, spilled ids fault at
  commit — no spilling in hardware).
- **ALU**: FP32 via FPnew (already in `exec`), int32, vec2/3/4 as lane-serial or 4-wide
  per `ShaderLanes` budget; `OpDot`, `OpMatrixTimesVector`, `OpVectorTimesMatrix`,
  `OpMatrixTimesMatrix`, `OpOuterProduct` go to **MatHelper** (§8). Derivatives
  (`OpDPdx/y`) use 2×2 quad lanes.
- **Memory**: `OpLoad/OpStore/OpAccessChain` resolve through descriptor sets →
  `ObjTab` → bound memory → checked DMA; Uniform/StorageBuffer/PushConstant storage
  classes; `OpImageSample*`/`OpImageFetch`/`OpImageRead/Write` go to the texture unit.
  Workgroup storage class is an on-chip `tc_sram` slab; `OpControlBarrier` is a wave
  barrier within a workgroup.
- Budget: an execution-count budget per dispatch/draw bounds runaway loops; exceeding
  it faults the submission (device lost semantics), never hangs the fabric.

This is a new design effort (plan §5); the 16-word/8-register native leaf is not its
capacity. The first increment that touches it is the commit-time scanner plus a vec4 FP32
compute path, measured against the SPIR-V subset emitted by a stock `glslang`/`dxc`
compute shader from the pinned UE profile.

## 8. MatHelper — AI island arithmetic behind a graphics-owned port

`g6lc_ai_pe_dot_float_pipe` (FP8/FP16/BF16/FP32 lanes, block-floating-point reduction,
one dot per cycle, latency `clog2(P2)+4`) and `g6lc_ai_fp_mac` are instantiated **by the
shader core** (`MatHelperEn`), not borrowed from the island at runtime: the ordinary path
must work with `MatrixEn=0`. Mapping: `mat4×vec4` = four 4-lane dots; `mat4×mat4` = 16;
`OpDot` = one. Precision: Vulkan allows fused/contracted FP32 dot products, and the BFP
single-rounding is at least as accurate as sequential FP32 adds, so this is API-legal;
the discriminator test (plan §8) still compares helper-on/helper-off images bit-for-bit
under `NoContraction` and within ULP bounds otherwise. VA-Turbo/policy approximation stays
off for graphics. Physical sharing of the island (one set of PEs for AI and graphics) is a
later scheduler question; this increment shares the *module*, not the silicon.

## 9. Raster — tile-based deferred rendering

Chosen for area and bandwidth without large caches: UE's deferred GBuffer (4–6 MRTs +
depth) fits a 16×16 tile in on-chip `tc_sram` (6 × 16×16 × 4 B = 6 KiB + 1 KiB depth per
tile buffer; two buffers for overlap). Stages: vertex waves → clip/viewport → binning
(primitive lists per tile in DRAM via checked DMA write) → per tile: edge-function
stamp rasterizer generalized from `cover` (4 samples/clk, top-left rule), perspective
interpolation from the per-vertex outputs, early-Z, fragment waves, ROP (blend modes,
color/write masks, depth/stencil ops) into the tile buffer, resolve/write-out to the
bound image through DMA with the format conversions the profile advertises. Images are
`ObjTab` objects with metadata (format, extent, tiling, layout); 64×64 is a test
rectangle, not a limit. `Xfer` handles copies/clears/blits and MSAA resolve.

## 10. Verification and development-speed rules

- **Generated vectors, not scripts**: every decoder/objtab test consumes `vn_vectors/*.hex`
  from the golden encoder with randomized ids/counts/orderings and the mutation set
  (unknown type, bad sType, unknown pNext, refused flags, truncation, stale generation,
  duplicate id, retire-while-pinned, directory collisions). Fixed happy paths are not
  evidence.
- **Engine-level synthesis only**: one remote `*_SYNTH=1` screen per engine top
  (`vndec`, `objtab`, `cmdrec`, `shader`, `raster`, `mathelper`), never per command.
  Enable=0 must synthesize to no cells.
- **Golden before RTL**: the Python golden model is validated against Mesa's vendored
  generated headers (regenerate at the pin, diff) before RTL consumes it.
- **No catalog growth in the engines**: a new command is a command-set line + regenerate;
  a new object kind is a profile line; a new shader opcode is a ShaderCore change with
  its own metamorphic test.
- **Remote proxy** for every Verilator/yosys run (`verif/regress/remote/testharness_proxy.py`,
  `--timeout` explicit); `--sync` before running.
- Keep `cs_q`-style flop arrays out of engines: command bytes live in the queue/ring SRAM,
  objects in `ObjTab`, records in `CmdRec`.

## 11. Increments

| # | Content | Exit |
|---|---|---|
| 1 (done 2026-10-01) | references, source matrix, six-boundary review | plan §2 |
| 2 (RTL done 2026-10-03, uncommitted) | `specs/venus-protocol` lazy pin `9fa07f3` (Mesa 26.0.8 vendored headers regenerate identically except the `70991d4` strict-aliasing cast; `pin-validate.log`); `gen_vn_tables.py`, `vn_golden.py`, `vn_mesa_diff/` (C harness against Mesa's own `vn_encode_vk*`), `g6lc_apu_vn_pkg.sv` for **120 commands** (0 unfit; `vkMapMemory` excluded — `void**` out-param is not serialized); `g6lc_apu_vndec`; `g6lc_apu_objtab` 256 slots + 512-bucket directory | Mesa C differential **480/480 PASS** on two seeds (120 cmds × 4 instances); remote `tb_g6lc_apu_vndec` **2421 cases / 161,074 checks** incl. 7 mutation classes; `tb_g6lc_apu_objtab` **8 cases / 2,222 checks** incl. 2000 random ops vs reference model; `Enable=0` **0 cells** both; `vndec` Enable=1 27,108 cells / 2,383 flops (ROM 1,648×48 b in logic — above the 10 k target, see follow-ups); `objtab` 1,902 control flops + two retained `$mem_v2` (256×entry, 512×82 b; 105,545 flops when flop-mapped by the generic flow); no latches; 0 lint warnings. Found and fixed by the TBs: entry-table index keyed off the flags word, directory bucket clobber on parent resolve, parent entry captured one cycle early. Follow-ups: 2 cycles/word (U32 ops take StOp→StW1), index widths `mpc_q[10:0]`/`scan_q[7:0]`/`rom_b[6:0]` must come from generated `*_AW` params before the ROM grows, ROM → `tc_sram`-initialised or compressed |
| 3 (RTL done 2026-10-04, standalone) | `g6lc_apu_vnrep` reply builder (§4b), `APU_VN_ACT` action table (§4c), `g6lc_apu_cmdrec` (16×64 16-word records in `tc_sram`), `g6lc_apu_cmdexec` (submit FIFO, re-resolution by `{gen,slot}`, PIN/UNPIN, work port, fences), `g6lc_apu_vnfront` sequencer; `vn_golden.py` reply encoder + `--session`; Mesa C **reply-decode** harness | Reply differential against Mesa `vn_decode_vk*_reply`: **248/248** per-command, **64/64** session. Remote TBs: `vndec_rep` 499 / 10,496; `cmdrec` 2,110 / 2,105; `cmdexec` 6 / 22; `vnfront` **104 commands / 1,395 checks** over the §6 positive session plus the five negative arms (Cmd outside recording, submit of unsealed, free of pending CB → PINNED, destroy device with child → BUSY_CHILDREN, stale handle), ObjTab empty at the end. `Enable=0` 0 cells everywhere; no latches; 0 lint. Enable=1: vnrep 15,205 cells / 1,765 ff (316-word ROM in logic); cmdrec 1,578,368 / 525,499 — the 64 KiB arena flop-mapped by the generic flow (one retained `$mem_v2`), control logic not separable until a small-parameter screen is added; cmdexec 4,583 / 1,663; vnfront 63,256 / 8,595; objtab now 384,612 / 124,151 (entry grew). Found by the TBs: `SETBIND` sent kind 0; Verilator 5.008 reads an unpacked-array input port as zeros (flattened). Follow-ups: `REXEC` chain bodies for chained property structs (session only exercises `RCONST` bodies), `vkGetQueryPoolResults`, small-parameter synth screen for cmdrec, wire `vnfront` behind `avn`/`qdn` on the queue path. Not in `g6lc_apu_sys`; no graphics executed — the work port is acked by the TB |
| 3b (RTL done 2026-10-04, standalone) | `g6lc_apu_vgctl` (virtio-gpu control queue: capset/ctx/blob/map/submit per §6b), `g6lc_apu_vnpump` (rings, reply stream, `ExecuteCommandStreams`, seqnos; 11 `TRANSPORT` commands), `g6lc_apu_vgtop` composition with the response → used elem → `used.idx` → ISR order; generated capset (40 words, `vk_xml 1.4.334`, `supports_multiple_timelines 1`, `use_guest_vram 0`); `vn_golden.py --transport` guest script | Mesa encode differential **524/524** (incl. the MESA transport commands), transport reply differential **29/29**. Remote: `vgctl` 15 / 73, `vnpump` 28 / 89 (non-pow2 `bufferSize`, offsets outside the blob, truncated/unknown stream, exec window outside blob, nested `ExecuteCommandStreams`, front fault → `FATAL` with head frozen), `vgtop` **28 / 2,129** (Mesa-shaped init → session through the ring → teardown, ObjTab empty; `context_init ≠ 4`, `blob_id ≠ 0`, unknown ctrl, oversize `SUBMIT_3D`, decode fault, nested exec). `Enable=0` 0 cells everywhere. Enable=1: vgctl 20,403 / 1,815; vnpump 132,640 / 14,626 (contains a `vnfront`); vgtop 2,025,925 / 634,998 (arena + objtab flop-mapped); cmdrec control logic isolated by the `-GNumBufs=2 -GRecsPerBuf=4` screen: **14,789 cells / 5,157 ff**. Port note: descriptor arrays and ring observability are packed vectors because Verilator 5.008 reads unpacked-array ports as zero. Follow-ups: drop the `g6lc_apu_pkg` import (only `APU_SHM_BASE`) so the engines do not depend on the concurrently edited package; record the capset layout and the driver-checked requirement list in the tables doc; real guest-memory AXI path and the DRAM-backed aperture; `g6lc_apu_sys` attach |
| 4 | ShaderCore commit scanner + vec4 FP32 compute path + MatHelper | stock `glslang` compute SPIR-V runs with data mutation; helper on/off identical under `NoContraction` |
| 5 | Raster TBDR + Xfer + sampler | G0 64×64 readback through the stock client; UE SM5 profile queries answered from the profile ROM |
