# Native Transfer Work And Retirement

GSys LibreCore now has a bounded host-native transfer executor. This is an
internal verification API, not wire-level GPU admission or a firmware renderer.
`vkQueueSubmit` remains refused by default and zero Vulkan capsets remain advertised.
Opt-in transfer-only wire submission follows `apu-native-submit-implementation.md`.

## Implemented Boundary

`vn_transfer_executor.py` accepts immutable fill/update/copy operations over
generation-checked `MemoryOwner` capabilities. The whole job is checked before
leases or writes: context identity, logical allocation bounds (not page padding),
backing presence, immutable payloads, fill/update alignment and copy overlap.
Acquiring multiple owners is transactional; repeated owners share one job lease.

Default bounds are128 pending jobs,256 operations per job and16MiB aggregate
reserved transfer bytes. One poll serves at most16 context turns and64KiB of
logical transfer bytes, with at most4KiB per turn. Copies require at most twice
that byte I/O for read plus write. Context queues are FIFO; other contexts get
round-robin turns. Fills never consume fractional words from a budget left by
a byte-sized copy.

Progress is explicit: queued/running/done/faulted/cancelled, operation index,
byte position and bounded error text. Polls write actual shared/private memory,
not a shadow result. Earlier prefixes are never replayed. An I/O failure releases
all job leases without claiming rollback or success. Cancellation during a copy
read prevents a subsequent stale destination write.

`MemoryOwner.work_refs` is separate from blob references. Work pins prevent
relocation, and deferred VkDeviceMemory free waits for both kinds of owner.
After free/retirement, old capabilities cannot mint new references.
Context destruction/reset and stream fault cancellation drain executor leases.
`ExecutionService.active/poll` includes transfer work, so device polling can
progress it without an extra MMIO request.

## Why Queue Submission Remains Off

The existing reference `FrontModel` SUBMIT path eagerly assembles command
buffers, and WAIT can retire its outstanding records without executing payload
writes. Enabling it would manufacture completion evidence.

Transfer-only command-buffer replay now follows
`apu-native-replay-implementation.md`. Semaphores and shader/image work remain
unimplemented; the executor does not publish Vulkan fences or transport syncobjs. Its job
failure policy is not the stock Mesa feedback contract: GPU execution faults
must not silently discard the trailing feedback CB. That integration must follow
`specs/architecture/venus-fence-contract.md` before wire admission.

## Short Frozen Evidence

```sh
python3 -B verif/tb/apu/apu_native_verify.py --check
python3 -B verif/tb/apu/apu_native_verify.py --timeout 60
```

133 checks pass in7.101s from
`~/.cache/librecore/apu/native-execution.hmerj572`, including14 new transfer
checks. Coverage includes chunked real writes, FIFO update/copy, context
fairness, mixed byte/word budgets, logical bounds/overlap rejection, queue and
byte limits, transactional pin rollback, generation/context rejection,
relocation exclusion, deferred free, I/O failure and reset during a source read.
Reset also drains multiple context queues without stale iterator lookups.
The existing wire-submission refusal regression remains enabled.
All62 frozen hashes remain unchanged and current inputs match the receipt.
Five-source MIT tier/header/ASCII/syntax/whitespace audit passes. Negative
timeout receipt `native-execution.ytzr9vkh` returns4/INCOMPLETE, never PASS.

This is host-model evidence, not RTL/CTS, shader correctness, generated-simulator
throughput, Vulkan conformance or silicon qualification. Compiler and simulator
PGO remain mandatory for applicable RTL lanes; default-PGO presence preflight
passes without installation/build/training.

## Unmap Reconciliation And Next Tasks

RTL `g6lc_apu_vgctl.sv` currently frees backing on UNMAP and `StUnmapPriv`
publishes `APU_MEM_UNBACKED`; the native implementation retains backing.
The RTL comment claiming private re-basing does not match those transitions.
This difference is not cleared by native transfer tests.

Reconciliation requires authoritative backing/alias lifetime, consumer
quiescence, a retention-capacity policy, bounded relocation and publication only
after copy success. Private-capacity exhaustion or failed copies must not
silently release live backing or report success. Dead-context and exported
memory lifetime must be resolved alongside that policy, not hidden by a model
compatibility switch.

Remaining session tasks: command-buffer semantics beyond transfer replay, shader/image
execution, semaphores and executor-owned fence/feedback retirement; unmap
reconciliation; truthful profile/capset admission; stock-software and sampled
hardware cross-checks. Remote/aggregate/CTS/compliance/formal/synthesis/physical/
WSI, timing/area/power and silicon gates remain open.

Review: host tooling only; no functional RTL/config/ISA/CSR/DTS/discovery,
clock/reset/SRAM/DFT/PMU or timing-cone change. No spec-index status promotion.
MIT tooling licensing and upstream notices/link-set boundaries are preserved.
User core/Storamic changes remain untouched; changes remain uncommitted.
