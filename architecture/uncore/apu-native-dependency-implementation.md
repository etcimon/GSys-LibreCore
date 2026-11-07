# Native Command-Stream Dependencies

GSys LibreCore's native verification endpoint now accepts bounded dependency
graphs in vkExecuteCommandStreamsMESA. This extends continuation scheduling,
not APU RTL or the advertised Vulkan capability surface.

## Contract And Implementation

The pinned `VK_MESA_venus_protocol.xml` defines dependencies by
`srcCommandStream` and `dstCommandStream`, alongside stream descriptions and
optional reply positions. The native model treats each edge as source
completion before destination execution. This conservative completion order
is a host-model contract, not evidence of equivalence to a stock renderer or
hardware scheduler. No network/upstream source update was needed.

- `vn_stream_group.py` validates every index, rejects self-dependencies and
  cycles, and deduplicates redundant edges. Validation completes before child
  mappings are pinned or child bytes read. At most256 nodes and1024 raw edges
  are accepted with the default execution budgets.
- A FIFO ready set releases a destination only after all predecessors finish.
  With no dependencies and no waits, array order remains unchanged.
- A parked child retains its frame, command reservation and reply view.
  Another ready child can run, including one that signals the parked child's
  control timeline. A dependent child cannot bypass a blocked predecessor.
- Child reply cursors are isolated across suspension/sibling switches. Explicit
  reply positions still apply; the enclosing stream inherits the last completed
  child's cursor when the group completes.
- Existing per-task, per-ring and per-poll byte/command/read bounds remain.
  All children share their task's source leases, context epoch and cancellation.
  The enclosing ring head or control used entry advances only after the whole
  group completes. Invalid groups never return false success.

Dependencies do not create host worker threads, GPU submissions or a new
firmware renderer. Scheduling is cooperative and deterministic under the
bounded native poll loop. Indefinite application waits remain pending, not
successful completions.

## Short Verification

```sh
python3 -B verif/tb/apu/apu_native_verify.py --check
python3 -B verif/tb/apu/apu_native_verify.py --timeout 60
```

119 checks pass in8.762s from
`~/.cache/librecore/apu/native-execution.2x0auuf8`.
All60 frozen input hashes remain unchanged.

Nine new directed cases cover reverse edges, fan-in, duplicate edges, cycles,
invalid indices/limits, pre-read rejection, independent sibling progress,
blocked-predecessor ordering, reply isolation and cancellation. One real
CLI/existing bridge-client case executes a destination query using an object
created by its higher-index source and checks separate reply positions.

Default-PGO layout presence preflight passes without installation, compilation
or training. Source audit covers the five changed/new MIT tooling sources.
These host-model durations do not establish generated-simulator performance,
hardware correctness or Vulkan conformance.

## Review And Remaining Gates

Timing/config alignment: host verification software only. No functional RTL,
Cfg/ISA/CSR/DTS/discovery, clock/reset, SRAM, PMU/DFT, area/power or silicon
timing-cone changes. No upstream header/notice or RTL link-set edits.
Spec-index statuses and mandatory compiler/simulator PGO policy are unchanged.
User core/Storamic work is untouched; changes remain uncommitted.

Next are explicitly budgeted GPU/shader/transfer execution and executor-owned
retirement, complete timeline/profile/capset admission, RTL blob-unmap
reconciliation and sampled hardware/stock-renderer cross-checks. Display/WSI,
remote/aggregate/CTS/compliance/formal/synthesis/physical qualification remain
separate. Zero Vulkan capsets remain advertised.

The internal bounded transfer/lease foundation now follows
`apu-native-transfer-implementation.md`. Wire GPU submission and its complete
shader/feedback/admission contract remain disabled.
