# Bounded Native Transfer Command-Buffer Replay

GSys LibreCore now connects real Venus command-buffer recording to the internal
native transfer executor. This is a host verification API, not wire GPU admission,
a firmware renderer, stock-renderer equivalence or Vulkan qualification.
`vkQueueSubmit` remains refused by default; zero Vulkan capsets remain advertised.
Opt-in transfer-only wire submission follows `apu-native-submit-implementation.md`.

## Implementation

`LinearExecution.replay.enqueue(context_id, command_buffers)` snapshots bounded
transfer work from executable command buffers and returns a `TransferJob`.

- Accept fill/update/copy and one-level secondary execution only. Check sealed
  state, primary/secondary level, descriptor address/count, object generations,
  parent/context identity and buffer-memory binding generations before pinning.
  Unsupported commands, nested/repeated buffers and simultaneous/render-pass
  continuation profiles reject rather than silently become no-ops.
- Bound each plan at16 primary IDs,16 children per ExecuteCommands,256 expanded
  records and64KiB payload snapshots with default execution budgets. Transfer
  regions also share the existing256-operation and16MiB aggregate byte limits.
  Validate cross-region source/destination overlap before execution.
- Fill patterns come from record `imm[0]`, matching the pinned keep schema and
  RTL transfer descriptor. Offset/size operands and update bytes come from
  ObjPay. Update payloads are immutable snapshots; copies observe prior work's
  actual writes. WHOLE_SIZE is resolved against the buffer, not memory padding.
- Acquire generation leases for command buffers, command pools, referenced
  buffers and their parents. Mark admitted buffers PENDING. A failed memory/job
  admission rolls back all object pins and original states.
- A trusted retirement callback releases object leases before memory leases.
  Ordinary buffers return to EXECUTABLE; admitted one-time buffers become
  INVALID. Empty buffers still retire through the bounded executor, not an
  eager fake completion.
- Native begin/reset/free, pool reset/destruction, buffer mutation/destruction
  and idle paths park while relevant work holds leases. Continuations retry
  after actual executor retirement instead of letting the eager reference
  frontend normalize PENDING or reclaim records prematurely.

Context retirement/reset, stream cancellation and I/O faults use the same
executor retirement path. No work callback publishes Vulkan fences, feedback
slots, transport syncobjs or a successful wire submission.

## Short Frozen Evidence

```sh
python3 -B verif/tb/apu/apu_native_verify.py --check
python3 -B verif/tb/apu/apu_native_verify.py --timeout 60
```

146 checks pass in10.797s from
`~/.cache/librecore/apu/native-execution.u3hmeyk8`; all64 frozen hashes remain
unchanged and current inputs match. Thirteen new directed cases record commands
through the actual Venus encoder/decoder/frontend, then replay into real memory.

Cases cover fill/update/copy ordering, payload snapshots, secondary pinning,
empty/one-time buffers, pending begin/free/reset/idle, stale bindings/descriptors,
cross-region overlap, unsupported work, nesting, record/payload/operation budgets,
transactional pin rollback, pending resubmit, cancellation and WHOLE_SIZE bounds.
Existing IPC regressions and wire-GPU refusal remain enabled.

Default-PGO presence checks pass without installation, builds or training.
Five-source MIT tier/header/ASCII/syntax/whitespace audit passes. These host
durations are not generated-simulator performance, PGO speedup or RTL evidence.

## Review And Remaining Gates

Host-only tooling: no functional RTL/config/ISA/CSR/DTS/discovery, clock/reset,
SRAM/DFT/PMU or timing-cone change. No upstream headers/notices or link-set
changes. Compiler/simulator PGO requirements and spec-index statuses remain
unchanged. User core/Storamic work is untouched; changes are uncommitted.

Remaining: full command-buffer semantics beyond the transfer-only profile,
shader/image execution, semaphore-aware wire admission, executor-owned
fence/feedback retirement and error continuation under the stock Mesa contract.
Barriers are not falsely accepted as no-ops. RTL unmap retention/capacity/alias
lifetime reconciliation, profile/capset admission, stock-software/hardware
cross-checks, WSI and remote/aggregate/CTS/compliance/formal/synthesis/physical/
timing/area/power/silicon qualification remain separate/open.
