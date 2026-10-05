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

### 6c. Memory and queue attach (increment 3c; interface of record 2026-10-05)

Everything above runs against TB word ports. 3c replaces those with the two memory domains
the real device has, without touching the concurrently edited `g6lc_apu_sys`/
`virtio_mmio`/`cfg_pkg` until the final attach step:

- **Two domains, one AXI master.** *Guest RAM* (virtqueue descriptor table, avail/used
  rings, control-command bodies, `SUBMIT_3D` payloads) is reached through the existing
  checked DMA pair `g6lc_apu_dma_read`/`g6lc_apu_dma_write` with one static mapping
  `{base, bytes}` = the guest-RAM window (the IOMMU-less virtio contract: the driver may
  point the device anywhere in its RAM; the window bounds it). The *aperture* (ring,
  reply, device memory: `APU_VG_SHM_BASE`, `APU_SHM_BYTES`) is a device-owned DRAM window
  reached through the same master with a fixed-window bounds check; it is what the guest
  maps via SHM id 1. Both are **exposed as the single `dma_req_o/dma_rsp_i` AXI master**
  of the composition.
- **`g6lc_apu_apmem`** — aperture word adapter: `N` requesters (pump ring/reply words,
  `shcore` memory port, vgctl blob fill) × one 64-bit word port each with `req/ready` and
  `rsp_valid` (variable latency), fixed-priority arbitration, bounds check against the
  window (`out of window → response with error bit; counted; the requester faults`),
  burst-of-one AXI beats in 3c (stability; bursts are a later optimisation). `shwave`'s
  LSU moves from the fixed `W_LS1→W_LS2` to wait-on-`rsp_valid` with `WaitBound`.
- **`g6lc_apu_vqwalk`** — generic virtqueue walker: inputs `vq_state {desc, avail, used,
  num, ready}` and `notify_i` per queue; reads `avail.idx`, walks `ring[last_avail %
  num]` → descriptor chain with bounded `NEXT` (≤ 16 descriptors, loop/out-of-range index
  → chain fault, element published with `len 0`), `INDIRECT` refused unless negotiated
  (never, in 3c), copies readable descriptors into the control command RAM through
  `dma_read`, hands `{chain, write window}` to `vgctl`, then writes the response into the
  WRITE descriptors and the used element and `used.idx` through `dma_write` **in that
  order**, then pulses `used_valid_o {qid, len}` — the exact seam `g6lc_apu_virtio_mmio`
  already consumes for the ISR. Driver-index wrap and batching (several avail entries per
  notify) are handled; the walker is the generalisation the plan's §4 asks for, and
  replaces `avn/avu/uir` for this path (those leaves stay as diagnostics).
- **`g6lc_apu_vgsys`** (`Enable`) — composition: `vqwalk + vgtop + apmem + dma_read +
  dma_write`, ports: `vq_state_i[]`, `queue_enable_i[]`, `notify_i[]`, `used_valid_o/
  qid/len/ready_i`, `reset_req_i/reset_done_o`, `idle_o`, `dma_req_o/dma_rsp_i`,
  `guest_window_i {base, bytes}`. It is the **backend** of the virtio-MMIO front: the
  attach step (3c-ii) connects it to `g6lc_apu_top`'s existing backend seam behind a new
  `ApuCfg.VenusEn` field (illegal together with `FeatureVirgl`), and only then does the
  capset become reachable from a guest. `NumCapsets` stays 0 until that step.

**Settled for implementation (2026-10-05, supersedes the two bullets above where they
differ).** One adapter serves *both* windows; the checked DMA pair is reserved for bulk
transfers (Xfer, increment 5) where bursts matter:

- **Word-port protocol `apu_mp`** (`g6lc_apu_mp_pkg`, tier R), one per requester:
  `req_valid_o/req_ready_i/req_o`, `rsp_valid_i/rsp_i` with
  `apu_mp_req_t {dom, we, addr[63:0], wdata[63:0], wstrb[7:0]}` and
  `apu_mp_rsp_t {rdata[63:0], err}`. `dom=0` is an absolute guest byte address, `dom=1`
  an aperture-relative byte offset (the aperture base is a composition-level input,
  so no engine imports `APU_SHM_BASE`). A requester holds `req_valid` until
  `req_ready`, has **at most one request outstanding**, and receives exactly one
  `rsp_valid` per accepted request — for writes too (after AXI `B`), so "write complete"
  is observable and publication order (elem → `used.idx` → `used_valid`) holds by
  construction. 32-bit requesters use `addr[2]` + `wstrb`. `err=1` (outside both windows,
  or AXI `SLVERR/DECERR`) returns zero data, performs no beat, and is counted.
- **`g6lc_apu_apmem`** is that adapter: `N = 5` ports (`vgtop` exposes three — vgctl,
  pump, shcore; `vqwalk` owns publication and is the fourth; port 0 is reserved for the
  Xfer engine of increment 5), fixed priority `xfer > vqwalk > vgctl > pump > shcore`, window classification `{guest_base, guest_bytes}` /
  `{ap_base, ap_bytes}`, one outstanding 64-bit single-beat AXI transaction (`MaxOut=1`
  in 3c; read-ahead for sequential CS fetch is a later optimisation), `outstanding_o`
  for the reset sequence, `fault_cnt_o`.
- **Consumer conversion** is mechanical: every `*Fire` state that today assumes
  next-cycle data (`vgctl` `StRdFire/StWrFire`, `vnpump` poll/transfer/write fires and
  the shared `cs_re`/`rep_we` lanes, `vndec` `StOp→StW1`, `vnfront`/`vnrep` CS and
  reply words, `shwave` `W_LS1→W_LS2`) holds the request until `req_ready` and then
  waits in a sibling `*Wait` state for `rsp_valid`; no FSM gains new behaviour. The
  conversion is proven in three steps before any AXI is involved: (1) TB `mp` memory at
  latency 1 / always ready → all 31 sessions pass with **identical** results and cycle
  counts within the one added wait cycle per access; (2) randomised latency 1–20 and
  random `req_ready` backpressure → identical results; (3) the AXI slave model.
- **`vqwalk`** publishes directly through its `mp` port: the used element `{id,len}` at
  `used + 4 + 8·(idx mod num)` as two 32-bit strobed writes, then `used.idx` as a
  **16-bit strobed write at `used + 2`** (never a 32-bit write over `flags`), then
  `used_valid_o {qid, len}` once that write's `rsp_valid` has returned. Queue 1 (cursor)
  elements are consumed and published with `len 0` without entering `vgctl`. The
  per-queue `last_avail`/`used_idx` counters clear on `reset_req_i` and on
  `queue_enable_i[q]` falling.
- **Reset.** `apmem` and `vqwalk` sit on `rst_ni` and drop state on `reset_req_i`; the
  engines inside `vgtop` are reset through a registered `eng_rst_n = rst_ni & ~soft_q`
  asserted for ≥ 4 cycles once `outstanding_o == 0`, then `reset_done_o`. This is a
  same-clock-domain reset request (no new clock, no new asynchronous source); it is the
  only sanctioned way to make ObjTab/CmdRec/objpay/vgpages/shader slots drain in bounded
  time without a per-engine drain protocol.
- **ISR.** `vgtop`'s `irq/isr/isr_ack` TB path is replaced by the `used_valid/ready`
  pulse; the ISR register stays in `g6lc_apu_virtio_mmio`, which already raises bit 0 on
  `used_valid_i && used_ready_o`.

**Exit for 3c-i (standalone).** `tb_g6lc_apu_vgsys` with one AXI slave memory model
holding both windows: the TB lays out a virtqueue in guest RAM, sets `vq_state`,
kicks `notify`, and the **same 29 compute/transport sessions** of 5a-ii/4b plus the 3b
init/teardown run through descriptors → DMA → engines → aperture, with the used ring
and `used.idx` checked in memory and the ISR pulse order checked; the shader outputs are
read back from the aperture under the §7a gates. Negative arms: NEXT loop, descriptor
beyond `num`, buffer outside the guest window (DMA `BOUNDS` → element `len 0`, no stray
AXI beat — checked by the slave model), aperture access outside the window from a
shader (robust fault, no AXI beat), `used` ring address outside the window (walker halts
the queue, `bus_fault_o`), reset mid-session (all tables drain, no AXI beat after
`reset_done`).

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

### 7a. ShaderCore interface of record (increment 4; geometry decided 2026-10-04: 8 lanes × 4-wide vec4)

**Compute subset (4a straight-line + memory, 4b control flow/barriers/matrix).** Accepted
at commit, everything else faults the module with the offending opcode (`vkCreate*Pipelines`
then fails; we report `VK_ERROR_UNKNOWN`):

- Header: magic `0x07230203`, version 1.0–1.6, bound ≤ `ShaderIds` (default 1024 ids);
  `OpCapability Shader` (`Int64`/`Float64`/`Int16`/`Float16`/16-bit storage etc. fault);
  `OpMemoryModel Logical GLSL450`; one `OpEntryPoint GLCompute`; `OpExecutionMode
  LocalSize x y z` (product ≤ 64 in the profile).
- Types: `Void, Bool, Int 32 (signed/unsigned), Float 32, Vector 2–4, Matrix 2–4 columns,
  Array (constant length), RuntimeArray, Struct, Pointer {Input, Uniform, StorageBuffer,
  PushConstant, Workgroup, Function, Private}, Function (void, no params)`.
- Decorations: `Block, BufferBlock, Binding, DescriptorSet, Offset, ArrayStride,
  MatrixStride, ColMajor/RowMajor, BuiltIn {GlobalInvocationId, LocalInvocationId,
  WorkgroupId, LocalInvocationIndex, NumWorkgroups, WorkgroupSize}, NonWritable,
  NonReadable, Restrict, Aliased, RelaxedPrecision (ignored), NoContraction (honoured: §8)`.
- Constants: `OpConstant{,True,False,Null,Composite}`; `OpSpecConstant*` accepted with
  defaults, and `vkCreateComputePipelines` with `pSpecializationInfo ≠ NULL` is refused
  until specialization is implemented.
- 4a instructions: `OpVariable` (Function/Private/Workgroup → scratch/slab allocation at
  commit; Input builtins), `OpLoad`, `OpStore`, `OpAccessChain`/`OpInBoundsAccessChain`
  (constant and dynamic indices, strides/offsets from decorations for Uniform/StorageBuffer/
  PushConstant; natural layout for Function/Private/Workgroup), `OpArrayLength` (from the
  bound buffer's size), `OpF{Add,Sub,Mul,Div,Negate}`, `OpI{Add,Sub,Mul}`, `OpS{Div,Rem,
  Mod,Negate}`, `OpU{Div,Mod}`, `OpBitwise{And,Or,Xor}`, `OpNot`, `OpShift{LeftLogical,
  RightLogical,RightArithmetic}`, `OpFOrd{Equal,NotEqual,LessThan,GreaterThan,
  LessThanEqual,GreaterThanEqual}`, `OpFUnordNotEqual`, `OpIEqual`, `OpINotEqual`,
  `Op{S,U}{LessThan,GreaterThan,LessThanEqual,GreaterThanEqual}`, `OpLogical{And,Or,Not,
  Equal,NotEqual}`, `OpSelect`, `OpConvert{FToS,FToU,SToF,UToF}`, `OpBitcast`,
  `OpCompositeConstruct`, `OpCompositeExtract`, `OpCompositeInsert`, `OpVectorShuffle`,
  `OpVectorTimesScalar`, `OpDot` (lane ALU form), `OpExtInst GLSL.std.450 {FAbs, FSign,
  Floor, Ceil, Fract, Round, RoundEven, Trunc, FMin, FMax, FClamp, FMix, Step, SmoothStep,
  Fma, SAbs, SSign, SMin, SMax, UMin, UMax, SClamp, UClamp, Sqrt, InverseSqrt, Length,
  Normalize, Distance, Cross}`, `OpReturn`, `OpFunctionEnd`, `OpNop`, `OpLabel`,
  `OpBranch` (uniform forward only in 4a). Transcendentals (`Sin, Cos, Pow, Exp, Log,
  Exp2, Log2`), atomics, `OpFunctionCall`, images and 64-bit are later increments.
- 4b instructions: `OpBranchConditional`, `OpSelectionMerge`, `OpLoopMerge`, `OpPhi`,
  `OpSwitch`, `OpUnreachable`, `OpControlBarrier`, `OpMemoryBarrier`, `OpMatrixTimes
  {Scalar,Vector,Matrix}`, `OpVectorTimesMatrix`, `OpOuterProduct`, `OpTranspose`.

**Commit scanner** (`g6lc_apu_shmod`, one module slot per committed `VkShaderModule`,
`ShaderSlots` default 8): copies the words into program SRAM (immutable until retire),
walks the module once and writes `tc_sram` tables: type table (id → `{kind[3:0],
width, comps[2:0], cols[2:0], elem_id, length, size_bytes[15:0], stride[15:0], storage[3:0]}`),
constant table (id → up to 16 words), decoration table (id/member → `{set, binding,
offset, array_stride, matrix_stride, builtin, flags}`), variable table (id → `{storage,
set, binding, scratch_off[15:0], builtin, type_id}`), **register map** (every
value-producing result id → compact register index; `ShaderRegs` default 256 vec4
registers per invocation, more → commit fault `TOO_MANY_VALUES`), block table (label id
→ word offset; 4b), entry record `{entry word offset, local size x y z, scratch bytes,
workgroup slab bytes}` and a fault record `{opcode, word}`.

**Wave engine** (`g6lc_apu_shwave`): `ShaderLanes = 8` invocations × `ShaderVec = 4`
components per issue; a workgroup is `ceil(product/8)` waves resident together (register
file `tc_sram`: `ShaderRegs × waves × 8 lanes × 128 b` = 256 × 8 × 8 × 128 b = 2 Mbit
default — SRAM, parameterizable), executed round-robin at instruction granularity so
`OpControlBarrier` is a wave-count rendezvous (4b). Per lane: `exec mask`, `prev_block`
(for `OpPhi`), private scratch region in a `tc_sram` slab (`ScratchBytes` per invocation
from the entry record). Pipeline: fetch (program SRAM, variable-length instruction by word
count) → decode (opcode table + type lookups) → operand read (2 RF ports) → execute
(8 × vec4 FP32/int32 ALU: FPnew add/mul/fma/compare/convert lanes, integer ALU, shifts)
→ writeback. Memory instructions go to the **LSU**: address per lane = descriptor
`{set, binding}` → bound buffer (resolved once per dispatch from the executor's
descriptor-set state through `ObjTab`, cached in a 16-entry binding table) → `base +
offset`; `robustBufferAccess`: out-of-range loads return zero, stores are dropped, and
the fault is counted (not fatal); 8-lane gather/scatter on a 64-bit word port (TB memory
model now, checked DMA later); Workgroup slab `tc_sram` 16 KiB; push constants a
128-byte register block loaded from the recorded `vkCmdPushConstants` data. Budget:
`ShaderBudget` instructions per wave (default 2^20) → `DEVICE_LOST` on the submission.

**Dispatch port** (from `cmdexec` work port): `{type = vkCmdDispatch{,Indirect}, gx gy gz,
pipeline handle → module slot + entry, descriptor-set handles[4], push-constant words
[32]}`; the core iterates workgroups sequentially (one core in increment 4; `ShaderCores`
later), sets builtins per lane, runs the waves, raises `work_done` with `{ok | fault
{code, wave, pc}}` and the robustness fault count.

**Verification of record for increment 4.** Shaders are **stock GLSL compiled by
glslang** (`glslangValidator -V`, pinned package version recorded) into SPIR-V vectors;
the oracle is **independent**: the same SPIR-V dispatched on Mesa **lavapipe** in WSL by a
small C harness (`vk_compute_oracle.c`: one device, one buffer per binding, push
constants, dispatch, readback) — a software renderer used only as a test oracle, never as
acceptance pixels. Corpus (4a): buffer copy/scale, vec4 arithmetic chain, integer/bitwise
mix, composite construct/extract/shuffle, dynamic `AccessChain` into a runtime array with
out-of-range indices (robustness), push-constant scaling, `GLSL.std.450` math set, three
builtin-derived index patterns, `LocalSize` 8/32/64; each run with ≥ 3 random input sets
and the metamorphic rules of §10 (same module, different data → oracle-equal; mutated
module → different output; `Enable=0` → no output). Two gates, both hard (decided
2026-10-04 after the first pass showed a blanket 1-ULP compare hides rounding bugs):
**Gate 1** — the RTL equals `spirv_model.py` (a reference interpreter of this subset, FP32
by double-then-round, every composite spelled as the micro-sequence listed in the tables
doc "ShaderCore arithmetic definitions") **bit-exact on every word and on the robustness
count**; **Gate 2** — against lavapipe, integer/bool words bit-exact and float words
within 2 ULP, with the per-shader maximum reported. The composite sequences follow Mesa's
NIR lowering so that Gate 2 is tight rather than tolerant (`OpDot` = products then a
right-leaning add fold; `FMix` = `x·(1−t) + y·t`; `SmoothStep` = `t·(t·(3−2t))`; GLSL
`fma()` = `r(r(a·b)+c)`, lavapipe lowers `ffma` and does **not** contract `a*b+c` — probed
and confirmed). Consequence for 4b: under `NoContraction`, and whenever MatHelper is on,
`Fma`/dot must be re-specified as single-rounded and the model/RTL changed together; the
Mesa-matching forms are a test alignment, not a Vulkan requirement.

### 7b. Compute pipeline state and payload retention (increment 5a; interface of record 2026-10-04)

What 4a leaves open between the Venus stream and the ShaderCore is **where structured
arguments live after decode**. The decode record keeps only top-scope slots; array
elements (`pBindings[]`, `pDescriptorWrites[]`, `pCreateInfos[]`, `pValues`) are
discarded, and the ring bytes are transient. 5a closes that with generated capture, not
per-command RTL:

- **`KEEP` ops in the decode ROM.** `vn_device_profile.toml` gains per-command keep-lists
  (`[keep.vkCreateDescriptorSetLayout] fields = ["pBindings.binding",
  "pBindings.descriptorType", "pBindings.descriptorCount", "pBindings.stageFlags"]`,
  likewise `vkCreatePipelineLayout {pSetLayouts[], pPushConstantRanges.{stageFlags,
  offset,size}}`, `vkCreateComputePipelines {pCreateInfos.{layout, stage.module,
  stage.pSpecializationInfo presence}}`, `vkAllocateDescriptorSets {pSetLayouts[]}`,
  `vkUpdateDescriptorSets {pDescriptorWrites.{dstSet, dstBinding, dstArrayElement,
  descriptorCount, descriptorType, pBufferInfo.{buffer, offset, range}}}`,
  `vkCmdBindDescriptorSets {pDescriptorSets[], pDynamicOffsets[]}`, `vkCmdPushConstants
  {offset, size, pValues}`). The generator marks the matching `U32/U64/HANDLE/BLOB` ops
  with a `KEEP` flag; `g6lc_apu_vndec` emits each kept word in stream order on a new
  **payload port** `pay_valid_o/pay_data_o[31:0]` and counts them in the record
  (`pay_words`). `vn_golden.py` produces the expected payload words per instance, so the
  Mesa differential now also covers capture. Layouts are documented in the tables doc per
  keep-list, never hand-maintained in RTL.
- **`g6lc_apu_objpay`** (`Enable`, `PayWords` default 16 384 = 64 KiB `tc_sram`):
  object payload store. Allocation is first-fit over 64-word chunks (256-bit chunk
  bitmap in flops, like `vgctl`'s page allocator); `alloc(words) → {ok, base}`,
  `free(base, words)`, word write/read ports (1-cycle). The owning object records
  `{base[15:0], words[15:0]}` in `ObjTab.aux[63:32]`; `RETIRE` frees. `FULL` →
  `VK_ERROR_OUT_OF_DEVICE_MEMORY` on the creating command.
- **Objects and what they retain.**
  `VkShaderModule`: `pCode` streams from the CS into a free `g6lc_apu_shmod` slot via
  `wr_*` (no scan yet; `ObjTab.aux[2:0] = slot`, `aux[31:16] = nwords`; no slot →
  `VK_ERROR_OUT_OF_DEVICE_MEMORY`). `VkDescriptorSetLayout`: payload `{bindingCount,
  per binding {binding, type, count, stageFlags}}`; `descriptorCount > 1` and types other
  than `UNIFORM_BUFFER(6)`/`STORAGE_BUFFER(7)` are accepted at layout creation but mark
  the binding `unsupported`. `VkPipelineLayout`: payload `{setLayout handles[≤4],
  pushRanges}`. `VkPipeline` (compute): `shmod.commit(slot)` runs the §7a scan at
  **pipeline** creation — a scan fault, a `pSpecializationInfo`, or an unsupported entry
  returns `VK_ERROR_UNKNOWN` for that pipeline and the reply echoes `VK_NULL_HANDLE` in
  `pPipelines[i]` (vnrep zeroes the blob echo for failed ids); on success `aux =
  {slot[2:0], layout handle[31:0]}`. Slot ownership is a per-slot `users` count in
  `shcore` (module +1, each pipeline +1; destroys decrement; 0 → `retire`), because Vulkan
  allows destroying the module while pipelines live. `VkDescriptorSet`: storage `nbind ×
  4 words {buffer handle {gen,slot}, offset, range, type|flags}` allocated from objpay at
  `vkAllocateDescriptorSets` from the layout payload; `vkUpdateDescriptorSets` resolves
  each written `buffer` id through `ObjTab` at update time and stores the generational
  handle (a destroyed-and-recreated buffer with the same id is caught at dispatch), the
  `unsupported` flag propagates. `vkCmdPushConstants` and `vkCmdBindDescriptorSets`
  payloads go to a **cmdrec payload arena** (`PayWordsPerBuf` default 256 words per
  command buffer, bump-allocated, freed by `RESET`; overflow → `VK_ERROR_UNKNOWN` and the
  buffer `INVALID`); the record's `imm[7]` holds the payload base.
- **Executor state** grows `dset[3:0]` (four bound sets; `BindDescriptorSets` writes
  `firstSet..`) and `push_base` (payload base of the last `PushConstants`, merged into a
  128-byte shadow at dispatch assembly in record order).
- **Dispatch assembly in `cmdexec`** (per `Dispatch` work record, before issuing on the
  work port): `LOOKUP pipeline → {slot, layout}`; for each bound set `LOOKUP set → storage
  base`; for each binding read `{handle, offset, range, type}` → `LOOKUP buffer` →
  `{bind_mem_slot, bind_offset, size}` → `READSLOT memory` (new `ObjTab` op: entry by slot,
  must be `live && kind == MEMORY`) → `aux = aperture base` → binding-table entry `{set,
  binding, base = aperture + bind_offset + offset, size = min(range, buffer.size − offset),
  valid}`; any miss/stale/unsupported/unbound → the submission is `DEVICE_LOST` (no
  partial dispatch). Then `work` to `shcore` with `{slot, gx gy gz, binds[16], push[32]}`
  and `work_ready` honoured.
- **Device memory in the aperture.** `vkAllocateMemory` allocates aperture pages with
  the `vgctl` page allocator (shared module `g6lc_apu_vgpages`; `aux = base`), so
  `RESOURCE_CREATE_BLOB` with `blob_id = memory id` (Mesa's mappable-memory path) maps the
  resource onto that window instead of being refused; `vkFreeMemory` frees the pages
  after the blob is unreferenced. The TB aperture model is one memory for ring, replies
  and device memory; the real DRAM-backed aperture stays 3c.

**Exit for 5a.** `vn_golden.py --compute-session <vector>` builds the Mesa-shaped
stream for a 4a corpus vector (module words, buffers, descriptor set, push constants,
dispatch) and the expected payload words; `tb_g6lc_apu_vgtop` runs it through the
control queue and ring with `shcore` on the work port, then compares aperture memory
against the oracle under the §7a gates. Negative arms: unsupported module →
`VK_ERROR_UNKNOWN` + null handle; module destroyed before dispatch (legal) → still
executes; buffer destroyed after update → `DEVICE_LOST`; `pSpecializationInfo` → refused;
unsupported descriptor type → `DEVICE_LOST`; `pValues` over 128 B → buffer `INVALID`;
dispatch without a bound pipeline → `DEVICE_LOST`. This is the plan's feasibility
prototype minus a real guest: stock-shaped bytes in, hardware execution of a
runtime-selected module, data-dependent output, failure when disabled.

### 7c. Control flow, barriers and matrix ops (increment 4b; interface of record 2026-10-05)

Stability-first divergence model for the one-instruction-at-a-time wave engine. glslang
without optimization keeps locals in `Function` variables, so `OpPhi` appears only from
`?:`/`&&`/`||`; `if`/`switch` arrive as `OpSelectionMerge` + `OpBranchConditional`/
`OpSwitch`, loops as `OpLoopMerge M C` with a header, a continue block and a back-edge.
The scanner's block table (label → pc, already built) is the only metadata needed.

- **Per-wave control state** (flops, `MaxWaves` copies): `pc`, `mask[LAN]`, `prev_blk[LAN]`
  (label of the block each lane came from, for `OpPhi`), `target[LAN]` (per-lane branch
  target pc at a divergent branch), and a **reconvergence stack** of depth `CfDepth`
  (default 8; overflow → `APU_SH_DONE_FAULT`) with entries `{kind: SEL|LOOP, merge_pc,
  resume_mask, pending_mask, cont_pc}`.
- **Divergent branch** (`OpBranchConditional`/`OpSwitch` under an `OpSelectionMerge M`):
  compute each active lane's `target`; if all equal → uniform jump. Otherwise push `{SEL,
  M, resume = mask, pending = mask}` and fall into the **pending-lane rule**: pick the lowest
  pending lane, `mask = pending lanes with the same target`, `pending &= ~mask`, `pc =
  target`. Reaching the label `M` with a `SEL` entry on top re-applies the rule until
  `pending == 0`, then pops and `mask = resume`. One rule serves if/else and n-way switch.
- **Loops** (`OpLoopMerge M C`): push `{LOOP, M, resume = mask, cont_mask = 0, cont_pc =
  C}`. Any branch whose target is `M` (a `break` or the header's exit test) removes those
  lanes from `mask` — they wait at the merge, still recorded in `resume`. Any branch whose
  target is `C` from **inside a nested construct** (`if (x) continue;`) parks those lanes in
  `cont_mask` and removes them from `mask` and from the nested entries' `pending/resume`,
  so they cannot run ahead of the loop; reaching the label `C` with the active lanes merges
  `cont_mask` back (`mask |= cont_mask; cont_mask = 0`). A uniform branch to `C` or the
  header just proceeds. When `mask` becomes zero at a branch: if `cont_mask ≠ 0` → `pc = C`,
  `mask = cont_mask`, `cont_mask = 0` (the parked lanes take their turn through the continue
  block and the back-edge); else → `pc = M`, `mask = resume`, pop. `OpBranch` to the header
  is the back-edge; no iteration limit beyond `ShaderBudget`. **Commit rule**: a
  `BranchConditional`/`Switch` without its own merge instruction is accepted only when one
  of its targets is the innermost loop's `M` or `C` (glslang's condition block); any other
  unstructured divergent branch faults the module (`APU_SH_FAULT_BRANCH`).
- **`OpReturn` under divergence**: clears the returning lanes from `mask` and from every
  stack entry's `resume`/`pending`; when `mask == 0`, unwind to the first entry with work,
  else the wave is done. `OpKill`/`OpUnreachable` fault in compute.
- **`OpPhi`**: per lane, select the operand whose parent label equals `prev_blk[lane]`;
  `prev_blk` is written for the active lanes at every taken branch. Phi operands are read
  through the regular register map (values from the predecessor are final there because
  blocks execute to completion before the mask switches).
- **Barriers**: `OpControlBarrier` makes the wave yield; a per-workgroup scheduler runs the
  workgroup's waves round-robin at instruction granularity (each wave has its own control
  state and RF rows; the RF is already wave-indexed). The barrier releases when every live
  wave of the workgroup has arrived (`arrived` bitmask); a wave that finishes (`OpReturn`
  of all lanes) counts as arrived forever. `OpMemoryBarrier` is a no-op in the
  one-core, write-through 4b model (recorded; revisit with caches). Workgroup slab accesses
  are already ordered by the single LSU.
- **Matrix ops** without MatHelper: `OpMatrixTimesScalar` (per column), `OpVectorTimesMatrix`,
  `OpMatrixTimesVector`, `OpMatrixTimesMatrix`, `OpOuterProduct`, `OpTranspose` as
  micro-sequences over the §7a `OpDot` definition (products then right-leaning fold), so
  Gate 1 stays bit-exact against `spirv_model.py` with the same sequences. Matrices live
  as `cols` consecutive vec4 registers (regmap allocates `cols` slots per matrix id).
- **MatHelper (§8)**: `MatHelperEn` adds a dot-product port to the lane ALU backed by
  `g6lc_ai_pe_dot_float_pipe`. Policy: a result id decorated `NoContraction` **never** uses
  the helper; otherwise `OpDot`/matrix ops may. Verification per §8: helper off is the
  Gate-1 reference; helper on must be bit-identical to helper off for `NoContraction`
  ids and within a documented ULP bound (measured, per op) elsewhere; `MatrixEn=0`/
  `MatHelperEn=0` elaborates no AI cells in the shader core.
- **Corpus 4b** (stock GLSL, no optimizer): if/else chains, nested if in loop, `for` with
  `break`/`continue`, `while` with data-dependent trip counts, `switch` with fallthrough and
  `default`, `?:`/`&&`/`||` (phi), early `return` under divergence, `barrier()` with
  `shared` prefix sum and reduction (LocalSize 32/64), mat2/mat3/mat4 × vector/matrix,
  `outerProduct`, `transpose`, plus `precise` (`NoContraction`) variants of the dot/matrix
  shaders. Gates as §7a; model extended with the same reconvergence semantics (it is an
  interpreter, so it executes lanes independently — the test is that lockstep execution
  reproduces independent-lane results).

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
| 3c-i (RTL done 2026-10-05, standalone) | §6c Settled block landed: `g6lc_apu_mp_pkg` (`apu_mp_req_t{dom,we,addr,wdata,wstrb}`/`apu_mp_rsp_t{rdata,err}` — `req_valid` held until `req_ready`, ≤1 outstanding per requester, exactly one `rsp_valid` per accepted request, writes only after AXI `B`; `dom` selects guest-absolute vs aperture-relative), `g6lc_apu_apmem` (the one adapter for both windows, `N=5` ports fixed priority `pub>vq>ctl>pump>sh`, single-beat `MaxOut=1` AXI4, wrap-safe subtractive window checks, out-of-window → `err` + `fault_cnt_o` with no beat, `flush_i` drops non-issued requests — but never a transaction whose AW/W/AR beat is being accepted this cycle, which runs to completion, `outstanding_o`), `g6lc_apu_vqwalk` (split-ring walker on queues 0/1: avail head → descriptor chain (≤`APU_VG_MAX_DESC`, NEXT-loop/idx≥num/INDIRECT rejected, visited list) → `chain_*` hand-off → `cpl_valid_i`/`cpl_ready_o` held handshake → used element as two 32-bit strobed writes + 16-bit `used.idx` write at `used+2`, `used_valid_o` only after that write's `rsp_valid`; queue 1 cursor publishes `len 0` without entering vgctl; `avail.idx` re-read for batching; ring `err` → `bus_fault_o`, queue halted until `reset_req_i`; `mp_pend_q` tracks an accepted-but-unanswered request and `StAbort` drains it — and the held completion — before re-idling on a queue drop, `reset_req_i` clears it outright since apmem's flush may drop an accepted-but-unissued request silently), `g6lc_apu_vgsys` composition (registered `eng_rst_n` soft reset for 4 cycles once `outstanding==0`, `reset_done_o`, aggregated `idle_o`, `bus_fault_o` = walker ring fault | vgtop `mem_fault_o`), `Flist.apu_vgsys`; consumer conversion: `vgtop` (`mem_*`/`ap_*`/`sh_mem_*`/`irq_o`/`isr_*` → three mp ports `CTL/PUMP/SH` + `cpl_valid_o` held until `cpl_ready_i`/`cpl_len_o` + `mem_fault_o`, reset through vgsys's `eng_rst_n`; the publication FSM is deleted — vqwalk owns the used ring), `vgctl` (`StRdFire/StWrFire` → `*Wait` siblings, sticky `mem_fault_o` until `rst_ni`, truthful per-word `used_len` when a chain has no write descriptor or a response write faults), `vnpump` (all `ap_*`/`gm_*`/execbuffer lanes + the shared `cs`/`rep` arbiters on one mp port), `vndec`/`vnrep`/`vnfront` (cs/rep ready+rvalid+err), `shwave`/`shcore` (mem handshake; `WaitBound`/`ShaderBudget` faults unchanged), `cmdexec` `busy_o` | `tb_apu_mp_mem` (`+mp_lat_min/max`, `+mp_ready_pct`) + `tb_g6lc_apu_vgsys` (AXI4 slave over both windows, hard-asserts every AW/AR in-window; real q0 `num=64` / q1 `num=16` split rings in guest RAM; every `TP_CHAIN` becomes descriptors + avail entry + `avail.idx++` + `notify_i[0]`; used `{id,len}`/`used.idx` checked in memory, the idx `B` proven to precede `used_valid`, `notify_clear_o` checked). **Gate step 1** (lat 1, ready 100%): vgtop transport **32 / 1,812** + 31/31 compute sessions, all result words and ULPs identical; per-session cycles +2,849…+7,811 (max `ue_cpos_math450_*`; transport +8,639 — the budgeted ~+1 wait cycle/access plus ~1/chain for the held completion handshake); per-session checks −364 — the ISR/used-ring checks moved to the vgsys TB which observes the real ring. **Gate step 2** (lat 1–20, ready 60%): identical results, 35–178 k cycles/session. Narrow suites unchanged counts: vndec 2,641/182,958; vndec_rep 499/10,496; vnfront 179/2,257 + payfull 11/442; vgctl 15/73; vnpump 28/89; shwave 213/35,267 (ulp1=52, maxulp=1, ouw=7,872, oum=0); shcore 9/18,533. `vgsys`: 32/32 sessions PASS (transport 32/2,006; compute 580–5,425 checks each) and **11/11 negative arms** (NEXT loop 20 c; desc idx ≥ num 11 c; buffer outside guest window → `len 0` publish, no beat 11 c; aperture OOB → robust fault count, no beat 18 c; used ring outside window → `bus_fault_o` + halt + nothing published 6 c; mid-compute `reset_req_i` → bounded `reset_done_o`, zero post-reset AXI beats, ObjTab empty, fresh session passes 2,011 c; cursor queue → `len 0`, vgctl never sees it 12 c; 3 avail entries + 1 notify → 3 in-order publications 31 c; **flush race** `reset_req_i` in the same cycle a stalled AW+W / AR is accepted → complete AW+W+B / AR+R, no orphan beat 11 c; **queue drop** mid-wait with an R in flight → `StAbort` drains, no new beat before the pending R, counters restart at 0 and the session passes 12 c; **response write OOB** → `bus_fault_o` via vgctl `mem_fault_o`, no beat to the bad address, truthful header-only used len 13 c). The slave model asserts ≤1 outstanding on the master and AW=W=B / AR=R balance at the end of every arm and session. Lint `Flist.apu_vgsys` clean (0 warnings, existing waivers). `Enable=0` 0 cells on both fixtures; `Enable=1` small screen (`-GRings=1 -GFences=4 -GPayWords=512` + shader small params): vgtop 4,033,985 / 979,640 ff; vgsys 4,042,684 / 980,833 ff (38 `$mem_v2` pre-synth, pre-review-fix baseline — the finding fixes add ~60 flops; the Enable=1 re-screen exceeded the 30-minute bound twice and was skipped per the review plan); no latches; default-geometry screen deferred. Found by the TBs: `vgctl` overstated `used_len` on chains without a write descriptor — only the vgsys cursor/batch arms reach that shape, the vgtop tapes always have one; `vnfront` needed a declaration hoist for yosys slang. `vgtop` carries three mp ports (`CTL=0/PUMP=1/SH=2`); apmem port 0 is tied off (reserved for Xfer). Follow-ups: 3c-ii attach (`g6lc_apu_sys`/`g6lc_apu_virtio_mmio` doorbell, notify, ISR, cfg fields), Xfer bulk DMA, read-ahead CS fetch |
| 4a (RTL done 2026-10-04, standalone) | `g6lc_apu_sh_pkg`, `g6lc_apu_shmod` (commit scanner: program + type/const/member/decor/var/regmap/init/block/entry `tc_sram` tables, §7a fault rules), `g6lc_apu_shwave` (8 lanes × vec4, one wave / one instruction multi-cycle FSM, `fpnew_fma` ×32, `fpnew_divsqrt_multi`/`cast_multi`/`noncomp` ×8, shared integer divider per lane, lane-serial LSU with robustBufferAccess, `WaitBound` + `ShaderBudget` faults), `g6lc_apu_shcore` (composition on the cmdexec work-record format, `work_ready`, `DispatchIndirect` → `UNSUPPORTED`); tier-T `tools/shader/`: 15 stock GLSL 4.60 compute shaders compiled by `glslang` 15.1.0 (`-V --target-env vulkan1.1`, no optimizer), `spirv_scan.py` (scanner model), `spirv_model.py` (reference interpreter), `vk_compute_oracle.c` (lavapipe, Mesa 25.2.8), `shader_vectors.py` → 75 vectors (15 × 3 seeds + 15 mutated + 15 unsupported-opcode) | Remote 5.008 + local 5.020 identical: `shmod` **38 / 384,389** (tables vs model; MAGIC/CAP/BOUND/TWO_ENTRY/LOCALSIZE/REGS/OPCODE faults), `shwave` **75 / 13,457, ulp1=26 ulp2=0 maxulp=1** (Gate 1 bit-exact incl. robust counts; Gate 2: 14 shaders exact, `math450` 1 ULP on `normalize.x` only — lavapipe rsqrt refinement vs `1/√`), `shcore` 7 / 1,974 (unsupported record, held work, re-commit after retire, commit fault through the port, continuous `Enable=0` monitor). Real glslang output: 1,650 instructions, 75 distinct opcodes, all inside §7a. `Enable=0` 0 cells; small screen (`-GShaderRegs=16 -GMaxWaves=1 -GSlabBytes=1024 -GScratchBytes=64 …`): shmod 385,217 / 112,532 (16 `$mem_v2`), shwave 957,502 / 50,709 (14), shcore 1,283,832 / 144,512 (29); no latches; default-geometry synth deferred (>60 min remote). Throughput ~10–40 cycles/instruction (by design in 4a). Found by the TBs: the first-pass blanket 1-ULP compare masked three composite sequences that differed from Mesa's lowering (`OpDot`, `FMix`, `Fma`, `SmoothStep`) — fixed in RTL + model together. Follow-ups: memory port is fixed 1-cycle with no ready/valid (needs the checked-DMA handshake before 3c/5); one wave at a time (4b round-robin + barriers); `DispatchIndirect`; `NoContraction`/MatHelper single-rounded forms; default-geometry synthesis and the register-file area (256 × 8 × 8 × 128 b) |
| 4b (RTL done 2026-10-05, standalone) | §7c: `spirv_scan.py`/`g6lc_apu_shmod` accept the 4b opcode set (incl. `OpTypeMatrix` cols regmap slots, `OpPhi` parent table, `OpControlBarrier`/`OpMemoryBarrier`, `OpUnreachable`, all six matrix ops), structured-branch commit rule (`APU_SH_FAULT_BRANCH`); `g6lc_apu_shwave` per-wave control state + `CfDepth=8` reconvergence stack (overflow → `APU_SH_DONE_FAULT`), pending-lane rule, loop `cont_mask` parking, `OpReturn` under divergence, `OpPhi` via `prev_blk`, round-robin wave scheduler at instruction granularity, `OpControlBarrier` workgroup rendezvous (finished waves count as arrived), `OpMemoryBarrier` recorded no-op, matrix ops as lane micro-sequences over the `OpDot` definition with right-leaning fold, `MatHelperEn` present but 0 (no helper instantiated — deferred to 4c); `spirv_model.py` independent-lane semantics (each invocation sequential to barrier/end, workgroup memory the only shared state, no lockstep) — Gate 1 bit-exact RTL ≡ model is the proof that lockstep reconvergence reproduces independent-lane results; corpus 4b: `ifelse`, `loopfor`, `loopwhile`, `switchcase`, `shortcircuit`, `earlyret`, `barrier_prefix` (LocalSize 32), `barrier_reduce` (LocalSize 64), `matvec`, `matmat`, `precise_dot`, `phiflow`, 3 seeds + mutated + merge-removal `APU_SH_FAULT_BRANCH` bad arm each | Remote 5.008 + local identical: `shmod` **62 / 830,163** (phi table, P-records, `.exp`-driven expected faults), `shwave` **135 / 19,133, ulp1=26 ulp2=0 maxulp=1** (all 4a+4b vectors both gates; all 4b shaders maxulp=0; wave-switch check: every multi-wave case switches, `barrier_prefix` wsw=912/4 waves, `barrier_reduce` wsw=1,380/8 waves, `loopwhile` wsw=3,732/4 waves), `shcore` **9 / 18,533** (incl. `loopfor_1`), `vgtop` compute arm +2 sessions: `loopfor_1` g1=g2=32 (34,694 cyc), `barrier_reduce_1` g1=g2=128 (63,576 cyc) — 29 sessions total. `precise_dot` `NoContraction` decorations (×3) accepted at commit, results equal non-precise (no helper yet). glslang observation: `?:`/`&&`/`||` and `switch` compile to memory (`OpVariable`/`OpLoad`/`OpStore`) not SSA — the corpus has exactly one `OpPhi` (`phiflow`); phi coverage is `phiflow` + the model/RTL table-parity checks. `Enable=0` 0 cells; no latches. Small screen (`-GShaderRegs=16 -GMaxWaves=1 -GSlabBytes=1024 -GScratchBytes=64 -GShaderSlots=2 -GShaderIds=64 -GShaderWords=64 -GShaderMembers=16 -GShaderInit=8`): shmod 496,374 / 132,169; shwave 1,053,368 / 56,124; shcore 1,463,954 / 160,540; vgtop small (Rings=1 Fences=4 PayWords=512 + shader small params) 4,024,209 / 978,962; vgtop default-geometry synth still skipped. Found by the TBs: scanner flags-packing collided with the builtin field (`flags<<27`→`<<28`), `sz_q` stale across `OpTypeStruct` entry — both fixed in scan/model together. Follow-ups: MatHelper (4c); checked-DMA memory handshake (3c) |
| 4b-opt (done 2026-10-05) | Optimizer-emitted corpus: `spirv-opt -O` (SPIRV-Tools v2025.1) over all 26 4a+4b shaders → `*_opt.spv`, 3 seeds each with inputs identical to the unoptimized build; third hard check **unopt == opt bit-exact** | Opcode delta vs glslang: scalar `OpPhi` in 7 shaders, scalar `OpSelect`, two-index matrix `OpCompositeExtract`, an if-chain turned into `OpSwitch` — **nothing outside the §7a/§7c subset**; `OpCopyObject`/`OpUndef`/vector `OpSelect`/bool-vector `OpPhi` did not appear (vector/bool phi is implemented but unproven by compiler output). Real finding: the two-index `OpCompositeExtract %float %m col row` form was unimplemented in both model and RTL — fixed together. Remote: `shmod` 88 / 1,629,285, `shwave` **213 / 35,267, ouw=7,872 oum=0** (optimized output bit-identical to unoptimized), `maxulp=1` (math450 only), two `_opt` sessions through `vgtop` (31 sessions). shwave small screen 1,060,264 / 56,124 (+6.9 k cells for the extract states) |
| 5a-i (RTL done 2026-10-05, standalone) | §7b capture half: `[keep.*]` lists in `vn_device_profile.toml` → `KEEP = a[7]` on `U32/U64/HANDLE/BLOB/PTR` ROM ops (generator asserts bit 7 free; discard marker now `0x7F`), `vndec` payload port `pay_valid/pay_data` + `pay_words` (fault-gated emission), generated "Payload layouts" doc section; `g6lc_apu_objpay` (16 384-word `tc_sram`, 64-word chunks, first-fit bitmap); `vnfront` staging `tc_sram` (1 024 words, overflow → `APU_VN_FAULT_PAYLOAD` FATAL), layout/pipeline-layout/pipeline payloads parked in objpay via `aux[63:32]`, descriptor-set storage `{handle{gen,slot}, offset, range, type \| unsupported<<31}` filled by `vkUpdateDescriptorSets` with record-time `LOOKUP`, `cmdrec` payload arena (`PayWordsPerBuf` 256) for `PushConstants`/`BindDescriptorSets` (resolved set handles), `cmdexec` state `dset[3:0]` + `push_base/len`; `vn_golden.py` payload expectations + `.pay` checkpoint vectors | Mesa C differential request **524/524**, reply session **97/97**, transport **29/29** (unchanged by capture — device-side only). Remote: `vndec` 2,641 / 182,958 (payload word-for-word), `objpay` 5 / 2,419, `cmdrec` 2,141 / 2,132, `cmdexec` 7 / 29, `vnfront` **172 / 2,213** (`ue_sm5_session`: 11 sub-sessions, objpay drained to zero at teardown) + 11 / 442 (`ue_sm5_payfull`, `ObjPayWords=512`: FULL → `OUT_OF_DEVICE_MEMORY`, staging overflow → FATAL, destroyed-buffer / out-of-range `dstBinding` → unsupported entry, `pValues` > 128 B → `VK_ERROR_UNKNOWN` + INVALID), `vgctl`/`vnpump`/`vgtop` unchanged counts. `Enable=0` 0 cells; no latches. Enable=1: objpay 52,156 / 16,539 (1 retained mem); vnfront 172,409 / 42,538 (small screen 72,543 / 10,858); cmdrec small screen 18,235 / 6,283; vgtop 4,154,838 / 1,325,072 (generic flop-mapped arenas; small screen 2,576,862 / 815,925). Notes: a single `vkCreateDescriptorSetLayout` cannot exceed 257 payload words under the 64-binding profile bound, so staging overflow is driven by multi-write updates; `vgtop` needs `read_slang --unroll-limit 8192`. Follow-ups: 5a-ii below; `vgtop` default geometry is now dominated by four flop-mapped SRAM arenas — the memory-macro mapping, not logic, decides its area |
| 5a-ii (RTL done 2026-10-05, standalone) | §7b execution half: `shcore` slot manager (`ALLOC/REF/UNREF`, module +1 / pipeline +1, retire at 0), `vkCreateShaderModule` streams `pCode` into a `shmod` slot, `vkCreateComputePipelines` consumes the parked payload → `commit` scan (fault or `pSpecializationInfo` → `VK_ERROR_UNKNOWN` + `VK_NULL_HANDLE` echo via `vnrep.rep_null_mask_i`), `ObjTab.READSLOT`, `g6lc_apu_vgpages` factored out of `vgctl` (ctl + front grants in `vgtop`), `vkAllocateMemory` → aperture pages in `aux[63:32]`, `RESOURCE_CREATE_BLOB blob_id ≠ 0` → `LOOKUP(DEVICE_MEMORY)` → mapped onto its extent (oversize → `ERR_PARAM`, unknown → `ERR_RID`), `cmdexec` dispatch assembly (pipeline → sets → entries → buffer → memory → bind table `{set, pos, base, size = min(range, buffer − off, memory − off)}`, push words from the payload arena; any MISS/GEN/unsupported/unbound/no-pipeline or shcore `code ≠ OK` → `DEVICE_LOST`, work not issued), `vnfront` BIND refuses `memoryOffset + size > memory.size` (wrap-safe subtractive form), `shcore` instantiated in `vgtop` with its memory port exposed as `sh_mem_*`; `vn_golden.py --compute-session` (three segments: allocate/map, submit/wait, teardown with real `RESOURCE_UNREF`) | **First stock-shaped bytes → hardware execution → oracle match**: 17 positive compute sessions through the control queue and ring (`tb_g6lc_apu_vgtop --compute`), **Gate 1 bit-exact and Gate 2 max 1 ULP** on all, 18–81 k cycles per session; 10 negative sessions all refuse as specified (bad module, module destroyed before dispatch still executes, buffer destroyed after update → `DEVICE_LOST`, spec info, unsupported descriptor type, no pipeline, pages FULL, unknown `blob_id`, bind past memory → `VK_ERROR_UNKNOWN`, descriptor range past buffer → clamped + robust, model-only oracle). ObjTab, objpay and vgpages all drain to zero at teardown. Mesa differentials 524/524, 100/100, 29/29. Remote: `vgtop` 32 / 2,216 + 27 sessions, `vnfront` 179 / 2,257, `vgpages` 5 / 1,448, `objtab` 8 / 2,225. `Enable=0` 0 cells; no latches. Enable=1: cmdexec 25,169 / 4,868; vgpages 1,641 / 85; vnpump 245,115 / 49,083; vgtop small screen 3,880,719 / 963,785 (default geometry deferred). Review finding fixed before commit: the first bind-table clamp ignored the memory extent. Still standalone: TB aperture model, fixed-latency shader memory port, one wave at a time, no control flow, `DispatchIndirect` unsupported — not Vulkan or graphics qualification |
| 3c-ii (RTL done 2026-10-05, SoC attach) | `ApuCfg.VenusEn` + `ApuVenus` literal with the §12.1 F1 legality split (Venus requires `FeatureVirgl`, `NumCapsets=1`, `NumScanouts=0`, `ShmEn`, `FirmwareHart=UNASSIGNED`, no exec/memory/SG/DMA clients, nonzero DMA window — the alignment/overlap block now also fires under `VenusEn`); `apu_impl_features(cfg)` = `APU_IMPL_FEATURES | (VenusEn ? VIRGL|RESOURCE_BLOB|CONTEXT_INIT)` and the legality check masks desired against it — non-Venus configs produce bit-identical feature words (`ApuP1Transport`/`ApuHarness`/`ApuSchedBoth` all `64'h0000_0101_0000_0000`; `ApuVenus` `64'h0000_0101_0000_0019`); `g6lc_apu_axi_lite` gains the backend seam ports `be_notify_pending_o`/`be_notify_clear_i`/`be_reset_ack_i`/`be_queue_stop_ack_i` — under `VenusEn`, notify_pending→vgsys, acks from vgsys, `g6lc_apu_control` not elaborated (control window answers SLVERR, fw IRQ tied low); `g6lc_apu_sys.gen_venus` instantiates `g6lc_apu_vgsys #(.Enable(1), .WorkSink(0))` on the existing seam with the sys port list **byte-identical** — notify/used/reset are registered in both directions, no new combinational path across the seam; `WorkSink=0` refuses non-dispatch work records truthfully (one-outstanding refusal → `APU_SH_DONE_UNSUPPORTED` → `DEVICE_LOST`, external `work_valid_o` held low); `Flist.apu_soc` closes on `Flist.apu_vgsys`; `g6lc_apu_fw` ties the new seam off; `vn_golden.py` `worksink` variant emits `vkCmdDispatchIndirect` (type 111) with truthful `DEVICE_LOST` expectations | `tb_g6lc_apu_sys_venus` + `run-apu-sys-venus.sh`: the Linux `virtio_mmio`+`virtio_gpu` probe register-for-register (MAGIC/VERSION/DEVICE_ID/VENDOR, ACKNOWLEDGE→DRIVER→FEATURES_OK write-back-exact, feature word 0 bits {0,3,4} + word 1 bits {0=VERSION_1,8=RING_RESET}, SHM id 1 = the 1 MiB DRAM aperture at `APU_SHM_BASE` and id 0 all-ones, `num_capsets=1`, `num_scanouts=0`, queue 0 `num=64` + queue 1 `num=16` split rings, DRIVER_OK; doorbell = `QUEUE_NOTIFY` write, completion = `guest_irq_o` → `INTERRUPT_STATUS` bit0 → `INTERRUPT_ACK` → line drops; used `{id,len}`/`used.idx` checked in guest memory with the `used.idx` B-beat ordering proven). 11/11 sessions PASS through the real SoC seam (transport 33/2,199; `bufcopy_1` 29/1,101, `math450_1` 30/5,606 g1=g2=1152 maxulp=1, `loopfor_1` 29/1,101, `barrier_reduce_1` 29/1,485, `oob_1` 29/1,229, `loopfor_opt_1` 29/1,101, `baddesc_1` 29/973, `badmem_1` 30/1,118, `badmod_1` 21/725, `nopipe_1` 29/973) and **5/5 arms**: device reset mid-session (STATUS←0 completes only after `backend_reset_req_o` rise/fall, no post-reset DMA beat, re-probe + transport session, `used.idx` restarts at 0) 35/2,273; queue reset (`QUEUE_RESET←1` → `backend_queue_stop_req_o[0]` acked, state cleared, re-ready + session) 2/118; VenusOff fixture (capsets 0, feature bits 0/3/4 clear, SHM all-ones, notify → no DMA/no IRQ for 2,000 cycles) 2/55; **worksink0** (`ue_ws0_bufcopy_1` — DispatchIndirect refused → guest-visible `DEVICE_LOST` wait replies via CK_REPLY, chains still publish, reset+re-probe recovery, transport session passes) 63/3,174; legality (`ApuVenus` legal, `ApuBadVirglGrant` + three Venus mutations illegal) 1/7. vgsys suite re-run: 32/32 sessions + **12/12** negative arms (incl. `neg_worksink0` 61/2,805). Non-Venus `run-virtio-mmio.sh` (APU_MEM=1 APU_SOC=1, synth OFF) suite counts unchanged — the storage/sys/etc. suites needed `-Wno-GENUNNAMED -Wno-EOFNEWLINE -Wno-UNSIGNED` appended under Verilator 5.020 (the script's flag set was tuned for 5.008; the baseline fails identically — pre-existing environment issue). Lint: `Flist.apu_soc` top `g6lc_apu_th_load` `--timing` — 28 warnings, all vendor/pre-existing (10 more than the 18-warning baseline = the fpnew files newly pulled in by `Flist.apu_vgsys`; zero new warnings in `g6lc_*`); the sys-venus TB flist lints clean (0). Yosys `Enable=0`-style identity on `ApuP1Transport` sys fixtures vs `git worktree` baseline `32668990c`: **69,404 → 69,412 cells (+8 `$_AND_` backend-seam wiring), DFF 15,213 → 15,213**; `ApuVenus` Enable=1 synth skipped (the 3c-i vgsys screen already exceeded 30 min twice). Found by the TBs: fence-lost state persists across a fence slot destroy+recreate until engine reset — model and RTL agree (Vulkan-correct), so the worksink arm's "next session" runs after the driver-level STATUS←0 re-probe. Follow-ups: ApuVenus Enable=1 synth screen, Xfer bulk DMA, read-ahead CS fetch |
| 5 | Raster TBDR + Xfer + sampler | G0 64×64 readback through the stock client; UE SM5 profile queries answered from the profile ROM |

## 12. Re-evaluated roadmap (2026-10-05) — controlling sequence from here

Re-planned against HEAD `a91f9deb8` plus the catalog freeze commit, the Devin plan
`plan-5ddc97674e5bf9b0.md` (A0–A7, acceptance matrix), the Grok session plan (G0–G4),
`AGENTS-impl-interplays.md` §15, the AI-island tree, and the pinned Resolute kernel. This
section owns sequencing; the two older plans keep their gate names and their status rows
point here. Nothing below promotes a fixture result to qualification.

### 12.1 Findings that change the sequence

| # | Finding | Consequence |
|---|---|---|
| F1 | The stock kernel enables *any* 3D (capsets, `CONTEXT_INIT`, blobs) only when `VIRTIO_GPU_F_VIRGL` (bit 0) is negotiated (`virtgpu_kms.c`: `has_virgl_3d` gates `virtio_gpu_get_capsets` and context creation). `num_scanouts = 0` is accepted ("KMS disabled", render node only). | `FeatureVirgl` must be **published** on the Venus route while capset 1 (virgl) stays refused. `apu_cfg_legal` splits: `VenusEn ⇒ FeatureVirgl ∧ NumCapsets == 1 ∧ NumScanouts == 0 ∧ ShmEn ∧ DmaWindowBytes ≠ 0 (the guest window) ∧ FirmwareHart == UNASSIGNED ∧ no mailbox client (ExecEn, MaxResources, MaxCmdBytes, SgEn, DmaReadEn, DmaWriteEn all 0)`; the firmware-virgl shape (`NumCapsets == 2`, hart, firmware RAM) stays legal only with `VenusEn = 0`. The aperture (`APU_SHM_BASE`) lives inside DRAM and must be carved out of Linux RAM by a `reserved-memory` node — a DTS obligation, not a hardware overlap rule, because `apmem` classifies by domain. `APU_IMPL_FEATURES` gains `VIRGL \| RESOURCE_BLOB \| CONTEXT_INIT` under `VenusEn`. |
| F2 | The virgl/TGSI/`gles2-min` lane (`bru`, `fet`/`buf` spines, `tgsi_compile`, resident firmware) serves Mesa-virgl, a second protocol + shader IR. Stock Mesa ships Zink (GL on Vulkan). | G0/A5 ("unchanged Mesa client's `glReadPixels(0,0,64,64)`") is **retargeted to Zink → Venus → this device**. Capset 1 is never advertised. The catalog is frozen as vector material (freeze commit). |
| F3 | 5a-ii is the plan-§3 feasibility exit minus a real guest: stock-shaped bytes in, runtime-selected module executed in hardware, data-dependent output, refusal when disabled. | The next gate is a **real guest**: stock `virtio_gpu` + stock Venus ICD on the RTL. |
| F4 | UE Linux targets x86-64/ARM64 only; CS2 is x86-64 only. RISC-V Ubuntu proves the driver contract (vkcube, Zink, CTS subsets), not those workloads. | The **virtio-pci endpoint function** (PCI `1af4:1050`, five virtio-pci capabilities + the shared-memory capability over a BAR into the aperture) is on the critical path before UE, and belongs on the multi-function virtio-pci endpoint already proposed in `pcie-endpoint.md`. Invariant: the `vgsys` front/back seam (`vq_state[]`, `queue_enable[]`, `notify[]`, `used_valid/qid/len/ready`, `reset_req/done`, `idle`, SHM window) is transport-agnostic — 3c-ii must not let MMIO specifics leak below it. |
| F5 | The 5a-ii dispatch assembly resolves descriptor sets into a 16-entry flop binding table. UE SM5 needs ≥ 4 bound sets with image/sampler arrays; Source 2 is reported to need descriptor-indexing-class bindless (to be pinned from the binary with a Vulkan layer trace, dev-only). | Increment 5's texture unit fetches descriptors from **device memory** (objpay/aperture) with dynamic indices through the LSU; ObjTab validation moves to descriptor-write time plus a generation check. The flop table is a compute-prototype shape, not extended. |
| F6 | The TBs model flat memory. Two coherence contracts exist: guest RAM through the kernel DMA API (`dma-coherent` or Zicbom CMO in the DT, both stock) and the aperture, which must be **CPU-uncached** (`APU_SHM_BASE` outside the core's cached PMA regions) so WC mappings are coherent by construction. | Plan-§4 "cached input visibility and output/fence ordering on the composed L1/L2/L3" is a 3c-ii exit arm. The island's `DmaInvalEn → CMO writer` and multi-client enqueue arbiter are the patterns to reuse for publication, not a flat-memory TB. |
| F7 | Capacity: 32 FP32 FMA units at ~20 cycles/instruction ≈ 1.6 FMA/cycle. A CS2-playable floor (1080p low, ~60 fps) is a ~1 TFLOPS-class device ≈ 500 FMA/cycle at 1 GHz: ~20× from pipelining `shwave` to one instruction/cycle/wave, ~16× from `ShaderCores`. TBDR keeps 1080p60 deferred traffic at single-digit GB/s, inside the SoC DRAM slave's 8–19 GB/s at `DramChannels = 1`. | ASIC-class silicon for the workload gates; FPGA proves correctness at small resolution. Capacity work (12.3 D) starts only after a frame profile names the stall, per the Grok plan's rule. |
| F8 | Each catalog fold cost ~66 min remote synth and kept the four attach files dirty. 5a-ii covers strictly more than `bru/qbn/qtb`. | Folds stop at the freeze commit; the leaves' wire facts are already covered by the generated Mesa differential (524/524), so nothing is ported. |

### 12.2 AI island → graphics (plan §8, made concrete)

| Island mechanism | Graphics use | Discriminator before reuse |
|---|---|---|
| `g6lc_ai_cluster_dispatch` (N engines, one AXI master) | `ShaderCores > 1`; raster tile workers | Same image at 1 vs N cores; backpressure and response-ID order under the `apmem` arbiter |
| `g6lc_ai_axi_cut` registered DMA boundary | `apmem`'s AXI master | Slave model: no beat outside either window; LSU latency tolerance |
| `g6lc_ai_tile_sram` dual-port `tc_sram` banks | Raster tile buffer (16×16 × MRTs + depth), banked shader RF | Capacity/overflow; two-buffer overlap |
| `DmaInvalEn → CMO writer`, `ai.enq` arbiter | Used-ring/reply/fence publication order; multi-queue | Fails-if-removed test on the composed caches |
| `DramChannels` 1/2/4/8 | Frame bandwidth | A frame profile showing the stall before N moves |
| `g6lc_ai_pe_dot_float_pipe` as MatHelper (4c) | `OpDot`/matrix ops, single-rounded | Helper on/off bit-identical under `NoContraction`, measured ULP elsewhere. ~115 k generic cells at `Lanes = 4` versus four FPnew FMAs: a precision/multi-format option, **not** an area win — optional, behind raster in priority |
| Dot PEs via `VK_KHR_cooperative_matrix` | The only API-legal way stock applications (including Vulkan AI runtimes) reach the matrix hardware | Later gate; not needed by UE SM5 or CS2 |

Not transferable: VA-Turbo/policy steer, Desc64 as a graphics ABI, UIO/ai-tensor daemons,
and neural upscaling of an unmodified game's frames (CS2's FSR option is a game shader pass
and runs on the shader core; intercepting it is the heuristic substitution plan §8 forbids).

### 12.3 Phases and exits

**A — Consolidate (now).** A1 freeze commit of the catalog lane (done when this section
lands). A2 3c-i per §6c "settled" (one `apu_mp` adapter, `vqwalk`, `vgsys`, three-step
conversion gate, 31 sessions through the AXI slave model). A3 trackers: interplay §2
forest marked frozen and a new §16 engine arborescence (`vgsys --> vqwalk | vgtop(vgctl,
vnpump(vnfront(vndec, vnrep, objtab, objpay, cmdrec, cmdexec)), shcore(shmod, shwave),
vgpages) | apmem`); `apu-graphics.md` census under a "frozen catalog" heading;
`current-stage.md` graphics row ≤ 15 lines; G0/A5 retargeted per F2.

**B — Real guest (the strict-endpoint proof).** 3c-ii: `ApuCfg.VenusEn` with the F1
legality split; `g6lc_apu_sys` instantiates `vgsys` behind the existing backend seam
(`notify_pending → vqwalk`, backend acks sourced from `vgsys`, `g6lc_apu_control` not
elaborated under `VenusEn`); `g6lc_apu_virtio_mmio` reports `num_capsets = 1` and SHM id 1
= the DRAM aperture; `ApuVenus` package; `tb_g6lc_apu_sys` arm that drives the MMIO
registers exactly as the kernel does (feature bits 0/3/4, SHM, queue setup, doorbell) with
the `vn_golden.py --transport` session laid out as real virtqueues in the memory model;
`ApuOff`/`ApuHarness` netlist identity; testharness `G6LC_APU` elaboration. 3d: a
bare-metal probe on the CVA6 hart (kernel probe sequence + Venus init, dev-only) on the
Verilator testharness, then a stock Ubuntu riscv64 kernel + Mesa boot on the proxy:
`vulkaninfo` enumerates, a compute dispatch matches the oracle, `VenusEn = 0` fails.
Exit: plan A3 + the "prove/reject stock-client backend" checkbox in `AGENTS-todo.md`.

**C — Graphics engines (the mass).** Increment 5 in this order: Xfer (copies/clears/blits
via checked DMA; unlocks vkcube-class tests), images/formats/sampler with memory-resident
descriptors (F5), vertex waves + clip/bin + tile raster generalised from `cover` + early-Z
+ fragment waves + ROP into `tc_sram` tiles, profile-ROM answers for the UE SM5 floor.
G0/A5 via Zink lands here. Shader-stage semantics (Input/Output interfaces, interpolants,
derivatives, `OpKill`, transcendentals, atomics, images) are a parallel increment under
the same two-gate method.

**D — Capacity and transport (before UE).** `shwave` to 1 IPC/wave, `ShaderCores` via the
cluster-dispatch pattern, `DramChannels` by profile; the virtio-pci endpoint function
(F4); scanout + `RESOURCE_UUID`/dma-buf export for WSI (G2).

**E — Workloads.** UE 5.8.3 SM5 packaged project on 26.04.1, then 24.04; CS2 requirement
pin from the binary (bindless, 64-bit atomics, timeline semaphores are the expected
deltas) and SM6-class features as separate gates; physical A7/P5.

### 12.4 Release stack and dev-only ledger (plan §9)

Release = stock Ubuntu kernel (`virtio_mmio` on the SoC DTS node `compatible =
"virtio,mmio"`, or `virtio_pci` on the card) → `virtio_gpu`; stock Mesa
`mesa-vulkan-drivers` (`libvulkan_virtio.so`, present on amd64 and riscv64) → loader;
Zink for GL. Nothing installed, no ICD override, no DKMS, no DTS property beyond the
virtio node.

| Dev-only component | Removal condition |
|---|---|
| TB guest model, `vn_golden.py` tapes, Mesa C differential, lavapipe `vk_compute_oracle.c` | test only; never acceptance pixels |
| Bare-metal virtio-gpu probe program (3d) | replaced by the stock-kernel boot |
| Optional `g6lc_qemu` B1 model of the APU wire contract (fast stock-stack qualification; UE startup cannot run on Verilator) | GPL-out per `g6lc_qemu` rules; a hypothesis, never evidence |
| `software/apu-fw`, firmware RAM, `ExecEn` mailbox lane, TGSI compiler | `VenusEn ⇒ FirmwareHart == UNASSIGNED`; off in release configs |
| Catalog leaves, `bru/qbn/qtb`, doorbell stacks, their `*En` fields | frozen; deletion only with explicit cleanup approval (plan §3) |
| `tdma` testharness join | replaced by the real xbar master (A1) |
| HDMI simplefb leaf | consumer only; WSI comes from virtio-gpu scanout |
