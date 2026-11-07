# Native Venus Rings And Retirement

GSys LibreCore's native verification endpoint now schedules bounded Venus
ring streams. This extends the linear/borrowed-memory milestone, not the
APU hardware capability surface. No firmware renderer, GPU submission or
Vulkan capset is enabled by this work.

## Implementation

- `vn_rings.py` owns ring geometry, the64-ring catalogue, nonoverlapping
  windows, persistent generation-checked mapping pins and context identity.
  Create validates alignment, field separation, zero initial counters and
  complete extents before publishing ALIVE. Destroy/teardown release pins
  without head/status writes to retired memory.
- Each ring has its own reply cursor but shares its context's frontend object
  namespace. A reused context ID cannot revive an old ring or its work.
- `vn_ring_scheduler.py` runs round-robin turns with a16-command per-ring
  quantum and shared256-command/64KiB execution budget. Ring snapshots share
  a separate64KiB read budget, including faulting rings. Nested source bytes
  are checked before DMA and charged to the execution budget, so command-data
  reads are bounded by128KiB per turn plus bounded metadata/reply traffic.
- Wrapped ring buffers and32-bit producer/head publication use a logical
  64-bit progress counter. Producer overruns, unaligned tails, corrupt heads
  and command faults set FATAL at the last committed head. Replies and command
  side effects precede head publication. A cut snapshot yields at a command
  boundary instead of treating a valid next command as corrupt.
- Direct ring waits park without replaying earlier commands or preventing
  another ring's progress. Ring sequence waits and native control timeline0
  waits are implemented; linear/nested blocking waits explicitly refused at
  this milestone now follow `apu-native-continuation-implementation.md`.
  Extra writes and notify
  are bounded. GPU queue submission remains refused on every path.
- Optional nested reply positions preserve the cursor when absent, including
  multistream packets. Nonempty stream-dependency arrays are explicitly refused
  before execution until continuation/dependency ordering is implemented.
- IDLE publication is followed by a tail recheck to close the lost-wakeup
  window. Notify clears IDLE; active polls refresh ALIVE. The host clock/poll
  heartbeat is cooperative, not a hard-real-time monitor guarantee.
- The bridge services ring turns between MMIO frames and on1ms readiness
  polling while rings are active. Partial frames retain their full deadline;
  MMIO received during DMA remains queued, never reentrant.
- Context destruction, self-destroy, device reset and peer disconnect retire
  ring work without stale publication. Full reset drains its owned ring pins
  but refuses external job pins before mutation. No GPU job-drain claim:
  that executor is still disabled.

## Verification

```sh
python3 -B verif/tb/apu/apu_native_verify.py --check
python3 -B verif/tb/apu/apu_native_verify.py --timeout 60
```

93 checks pass in4.745s from
`~/.cache/librecore/apu/native-execution._gwicsil`.
All55 frozen input hashes remain unchanged; no fixture corpus, generated RTL
or kernel header is required to import/run this native model.

The20 new cases include18 directed ring tests and two real CLI/existing
bridge-client cases. They cover geometry and monitor-chain decoding, pins,
wrap, overrun, fatal progress, round-robin/read budgets, parked waits,
timeline wakeup, stale replies, context overlap/reuse, self-destroy, IDLE
tail races, optional nested reply positions, polling without new MMIO,
cancellation on CTX_DESTROY and full device reset with live rings.

Default-PGO layout presence preflight passes without compilation/training.
Scoped10-file MIT tier/header/ASCII/syntax/whitespace audit passes.
Compiler/simulator PGO policy and cache receipts remain unchanged; these
host-model durations are not generated-simulator throughput measurements.

## Review And Remaining Gates

Host verification tooling only: no functional RTL, config/ISA/CSR/DTS,
discovery, clock/reset, SRAM/DFT/PMU, synthesis, power, area or silicon
timing-cone changes. Spec-index statuses remain unchanged. No upstream
notice/header or RTL link set changes. User Storamic work is untouched.

Continuation-backed linear/nested waits now follow
`apu-native-continuation-implementation.md`. Next are explicitly budgeted
GPU/shader/transfer execution, executor-owned asynchronous retirement, complete
timeline/profile admission and sampled hardware cross-checks. Blob-owned
private retention on unmap still differs from current RTL. Display/WSI,
remote/aggregate/CTS/compliance/formal/synthesis/physical qualification stay
separate. Zero Vulkan capsets remain mandatory until the native path is
complete and truthfully validated.
