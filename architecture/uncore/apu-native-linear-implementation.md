# Native Linear Venus And Borrowed Memory

GSys LibreCore's native verification endpoint now accepts bounded SUBMIT_3D
linear Venus streams. This is host verification software, not a firmware
renderer, a complete Vulkan implementation or RTL qualification.

## Implementation

- `vn_native_execution.py` lazily loads the pinned decoder/profile, reuses
  Sim/FrontModel/ReplySim, and isolates frontend objects/reply cursors by
  context. All aperture words route through the live shared/private memory
  view, not a disconnected sparse shadow.
- Linear streams have a64KiB aggregate byte budget,256-command budget and
  one ExecuteCommandStreams nesting level. Reply mappings are generation
  checked and pinned. A failed stream faults its context; earlier completed
  commands are not rolled back or silently replayed.
- Supported transport controls are SetReplyCommandStream, SeekReply and
  ExecuteCommandStreams. Ring operations are added by the subsequent
  `apu-native-ring-implementation.md` increment. GPU queue submission and
  explicitly unsupported actions remain refused, not acknowledged as working.
- `vn_borrowed_memory.py` resolves VkDeviceMemory IDs to current frontend
  generations and host owner capabilities. Page-rounded size, lazy UNBACKED,
  eager private placement, pin saturation, relocation and foreign/forged
  capabilities are checked.
- `vn_memory_blobs.py` pins borrowed owners, moves their full extents and
  retains data through guest/private relocation. Simultaneously mapped aliases
  must share one guest base; conflicting placement is rejected before mutation.
  RESOURCE_UNREF drops a reference, never independently frees owner pages.
- Vulkan free while exported is deferred until the last alias release.
  Context destruction retires unpinned frontend state but retains exported
  backing; last unref finishes old-context cleanup. Reused context/memory IDs
  cannot authorize an old capability.
- BlobController/NativeDevice compose these paths into the existing real
  bridge endpoint. No Vulkan capsets are advertised yet.

Native model import no longer reads shader fixtures, generated transport
kind tags or the pinned kernel UAPI. Those checks/reads remain in the
appropriate CLI/vector-generation paths. No upstream header is edited or
added to an RTL link set. The command-list reader now closes its file.

## Reproducible Checks

From WSL at the repository:

```sh
python3 -B verif/tb/apu/apu_native_verify.py --check
python3 -B verif/tb/apu/apu_native_verify.py --timeout 60
```

Presence check performs no snapshot, build, training or tests. Existing
Python3.11+ and Mako are required; no downloads occur. The runner freezes its
repository input closure, generated map and existing bridge client, retains
manifest/log/summary, and checks before/after hashes. A timeout kills its
owned process group, removes only its owned temporary IPC workspace and
returns4/INCOMPLETE, never PASS.

73 checks pass in2.882s under
`~/.cache/librecore/apu/native-execution.qtxr0bwv`. Includes15 new execution/
memory cases and an actual CLI/existing bridge-client Vulkan query/allocation,
memory-blob export/map/unmap/free/context-reuse sequence. Timeout negative
receipt: `native-execution.9vymhv0s`, correctly INCOMPLETE/rc4.

Eleven sampled session/payfull/transport artifacts regenerate byte-identically
before/after the lazy-import and file-reader changes:
`~/.cache/librecore/apu/native-golden-equivalence.vrhb133o`.
Default-PGO layout presence preflight passes without compilation/training.
Scoped11-file MIT tier/header/syntax/whitespace audit passes; emitted license
strings and upstream notices are retained.

## Review And Remaining Gates

Host-only: no functional RTL, config/ISA/CSR/DTS/discovery, clock/reset,
SRAM/DFT/PMU or silicon timing/area/power changes. Spec-index statuses
unchanged. Compiler/simulator PGO policy remains mandatory for RTL lanes.
User Storamic work remains untouched.

Ring scheduling/retirement now follows `apu-native-ring-implementation.md`.
Shader/transfer execution with explicit work budgets, executor-owned
asynchronous retirement, capset/profile admission,
display/WSI and aggregate Vulkan qualification remain open. Device-private
retention of blob-owned backing differs from current RTL unmap behavior;
resolve and cross-check before claiming equivalence. No remote RTL/CTS,
formal, synthesis, physical or Vulkan conformance pass is claimed here.
