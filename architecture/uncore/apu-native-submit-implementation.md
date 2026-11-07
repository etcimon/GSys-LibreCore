# Opt-In Native Transfer Submission

GSys LibreCore now has an explicitly enabled host-native transfer-only
`vkQueueSubmit` path. This is a diagnostic backend, not a firmware renderer,
stock Vulkan implementation, RTL equivalence or capset admission. The default
endpoint continues to refuse GPU submission. Both modes advertise zero Vulkan
capsets.

## Implemented

- `vn_native_submit.py` validates the complete pinned submit packet, including
  declared/encoded array counts, sType, empty extension chains, queue/fence
  generations, common device and unsignaled fence state. Default bounds are
  four batches and16 aggregate command-buffer IDs. Nonzero semaphore arrays
  reject explicitly; no synchronization fields are silently discarded.
- Follow-up: plain binary semaphore scheduling is implemented under
  `apu-native-binary-semaphore-implementation.md`; timeline/external chains
  and semaphore-bearing multi-batch submissions still reject.
- Admitted buffers use the bounded transfer replay/executor, not the reference
  frontend's eager SUBMIT/WAIT path. Work remains serialized within a context.
  Stock-style flags-zero submits return after enqueue, before actual writes.
  Empty submissions still enqueue retirement work.
- Queue and fence objects stay pinned until a separate completion callback runs
  after object and memory retirement. Only then does the fence arena signal.
  Pending reset/destruction/resubmit parks; teardown cancels without signaling
  a retired context or reusing an old fence generation.
- Fence waits implement all/any masks, VK_TIMEOUT for timeout-zero, saved
  monotonic finite deadlines and cooperative infinite waits. Idle handles are
  validated. Signaled fence creation is honored in this explicit mode.
  I/O failure retires leases and marks the fence lost; context diagnostics stay
  sticky until teardown.
- Classic memory-only pipeline barriers are supported by the serial, coherent
  transfer profile's full operation ordering. Buffer/image ownership/layout
  transitions and nonzero dependency flags reject. This is not general GPU
  barrier implementation.

Enable only for isolated host diagnostics:

```sh
python3 -B corev_apu/apu/tools/vn_native_bridge.py \
  --sock /tmp/g6lc-transfer-unique.sock \
  --map software/apu-venus-probe/venus_map.h --transfer-submit
```

The socket path must be new. No network service, Mesa patch, software renderer
fallback, tool installation or capability promotion is introduced.

## Frozen Evidence

159 checks pass in8.150s from
`~/.cache/librecore/apu/native-execution.jo5vhdn5`; all66 frozen hashes remain
unchanged. Thirteen added cases include12 directed submission/fence checks and
one real CLI/existing bridge-client sequence: allocate/export/map Vulkan memory,
record barrier/fill/barrier work, submit asynchronously, wait for executor fence
retirement and observe the expected bytes in shared backing.

Coverage includes pending reset/destruction/resubmit, finite/infinite/zero waits,
empty submit, signaled-fence reset requirements, malformed counts, explicit
semaphore refusal, I/O failure, reset cancellation and default-mode refusal.
Ten-source MIT tier/header/ASCII/syntax/whitespace audit and default-PGO presence
preflight pass. Presence checks perform no build/install/training.

## Admission And Remaining Gates

This opt-in profile does not implement shaders, image work, timeline/external semaphores,
multi-queue scheduling or the full stock Mesa fault-feedback contract.
In particular, a transfer I/O failure can stop remaining job operations; a lost
host fence arena does not prove that Mesa's trailing shared feedback CB executed.
That gap must be resolved under `specs/architecture/venus-fence-contract.md`
before any stock-software/capset admission. Healthy feedback-shaped transfers
are not proof of execution-error continuation.

Next are semaphore-aware scheduling, shader/image execution, complete barrier/
feedback/error semantics, RTL unmap retention/capacity/alias reconciliation and
truthful profile admission. Stock-software/RTL/CTS/aggregate/compliance/formal/
synthesis/physical/WSI/timing/area/power/silicon gates remain open.

Review: host-only tooling; no functional RTL/config/ISA/CSR/DTS/discovery,
clock/reset/SRAM/DFT/PMU or timing-cone change. No upstream notice or link-set
edits. Compiler/simulator PGO policy and spec-index statuses are unchanged.
User core/Storamic work remains untouched; changes are uncommitted.
