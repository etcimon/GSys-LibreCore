# Native Stream Continuations And Deferred Completion

GSys LibreCore's native verification endpoint now parks and resumes linear
and nested Venus streams without replaying completed prefixes. This completes
the transport-wait continuation boundary left by the ring increment. It does
not implement GPU work or promote the endpoint to a Vulkan implementation.

## Implementation

- `vn_stream_task.py` uses explicit frame/position stacks, not recursive retry.
  Wait retries retain their command reservation and only resume the blocked
  instruction. Nested streams remain one level deep. Nonempty dependency
  graphs now follow `apu-native-dependency-implementation.md`.
- Each task has a64KiB aggregate root/nested-source budget,256-command budget
  and bounded child frames; at most128 tasks are retained. A shared64KiB
  nested-read allowance bounds each poll lane before DMA, in addition to ring
  snapshot limits. Rings receive16-command turn quanta; pending control tasks
  share256-command/64KiB execution turns with16-command per-task quanta.
- Nested source windows are validated, snapshotted and generation-pinned.
  Multiple windows in one mapping share a lease. Pins drain on completion,
  fault, context destruction, queue/device reset or disconnect. A withdrawn/
  overrun tail cancels parked ring work before resuming its effects.
- Task contexts retain the exact parent identity and frontend, not merely the
  wire context ID. A stale view cannot start work under a reused ID.
- Linear tasks own reply views inherited from the latest committed context
  cursor. A late completion cannot replace a newer committed cursor; streams
  requiring concurrent replies must provide their own reply windows/positions.
  Mapping generations are still checked before reply-producing execution.
- `vn_deferred.py` and `vn_control_queue.py` retain the response targets and
  generate no final control reply before task completion. Reply permissions are
  rechecked before resumption, not only when the descriptor was accepted.
- `vn_split_queue.py` retains bounded in-flight heads and publishes used entries
  only when ready. Out-of-order completion lets a later timeline/control packet
  wake or cancel a parked SUBMIT_3D. Reused heads and queue-capacity overruns are
  rejected. Actual used-slot/index permissions are checked before advancing work.
  Standard and optional legacy used-length accounting remain distinct.
- Context cancellation returns an error through a still-live control queue;
  queue/device reset discards the old completion without reply/used writes.
  Full reset first rejects external pins, then drains its own jobs/rings.
  Queue reset releases its pending task sources while preserving context/blob
  lifetime, and now permits negotiated queue reconfiguration under DRIVER_OK.
- Existing bridge housekeeping polls pending control work even with no active
  ring or new MMIO. DMA callbacks still cannot reenter MMIO dispatch.

## Short Verification Lane

```sh
python3 -B verif/tb/apu/apu_native_verify.py --check
python3 -B verif/tb/apu/apu_native_verify.py --timeout 60
```

The frozen cohort covers delayed replies/used entries, out-of-order wakeup,
context cancellation/reuse, nested-prefix non-replay, source pins, independent
reply views, read budgets, tail withdrawal, response/used permission revocation
before side effects, head reuse and queue/device reset with parked sources.
Real CLI/existing bridge-client traffic exercises the deferred completion path.
109 checks pass in6.868s from
`~/.cache/librecore/apu/native-execution.27u7iguv`; all58 frozen input hashes
remain unchanged. Includes13 directed continuation cases and three new real
IPC cases (the reset case covers queue and full-device reset).

Negative timeout receipt `native-execution.d_3rpdab` correctly reports
INCOMPLETE/rc4. Default-PGO layout presence preflight passes without builds
or training. Scoped12-file MIT tier/header/ASCII/syntax/whitespace audit passes.

Presence-only checks do not install, build, train or simulate. Native host tests
remain separate from pinned Verilator compiler/simulator PGO-enabled RTL lanes.
Timeouts remain INCOMPLETE/fail-closed, never PASS.

## Review And Remaining Gates

Timing-impact/config alignment: host verification tooling only. No functional
RTL, Cfg/ISA/CSR/DTS/discovery, clock/reset, SRAM, DFT/PMU, synthesis, area, power
or silicon timing-cone change. No upstream notice/header or RTL link-set change.
Spec-index statuses and mandatory compiler/simulator PGO policy are unchanged.
User core/Storamic edits remain untouched. Changes remain uncommitted.

GPU/shader/transfer execution still needs explicit work budgets and executor-owned
retirement. Dependency ordering now follows the dependency increment; complete
timeline/profile admission, RTL
blob-unmap reconciliation, display/WSI, remote/aggregate/CTS/compliance/formal/
synthesis/physical qualification remain open. Zero Vulkan capsets are advertised;
neither host task completion nor these short tests establish hardware conformance.
