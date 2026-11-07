# Runnable Native Control Backend

GSys LibreCore now has an executable native control backend on the existing
local G6LC bridge protocol. This is verification software, not a firmware
renderer or replacement for the APU RTL. It deliberately advertises zero
Vulkan capsets. Bounded linear execution and memory-backed ownership are now
implemented as recorded in `apu-native-linear-implementation.md`. Ring
scheduling/retirement follows `apu-native-ring-implementation.md`; budgeted
GPU work execution remains open.

## Implemented

- `vn_blobs.py`: bounded lazy HOST3D blob ownership, guest aperture maps,
  overlap-safe relocation, private backing on unmap, explicit unref,
  generated mapping capabilities and pins. Failed collision/geometry/private
  allocation checks retain ownership; pinned mappings cannot move or retire.
- `vn_blob_control.py`: CREATE_BLOB/MAP/UNMAP/UNREF replies, variable32-byte
  MAP_INFO response, idempotent membership, context-independent blob lifetime
  and reset revocation. The NativeDevice execution service now resolves nonzero
  VkDeviceMemory blob IDs; standalone control-only instances still refuse them.
- `vn_control_queue.py`: side-effect-free response-size planning authorizes
  all actual MAP_INFO bytes before dispatch, not only the24-byte header.
- `vn_split_queue.py`: direct split descriptors, cycle/index/chain budgets,
  rejection of unnegotiated indirect/reserved flags, bounded available-index
  distance and16-bit wrap. Used-ring writes are authorized before control
  changes, published before IRQ, and respect NO_INTERRUPT.
- `vn_native_device.py`: MMIO identity, feature selection/negotiation,
  monotonic driver status, queue configuration immutability, notification,
  negotiated queue reset, IRQ ACK, shared-memory discovery and full reset.
  Guest-visible aperture bytes alias peer DRAM; private bytes remain private.
  DMA/chain failures latch NEEDS_RESET/config IRQ instead of false completion.
- `vn_native_bridge.py`: executable Unix-socket endpoint with the existing
  length/type/flags/sequence framing, bounded partial receive/send, finite
  timeouts and chunked DMA callbacks. MMIO arriving during DMA is queued,
  never reentered. DMA replies must match type, sequence and payload size.
  Existing socket paths are refused, and cleanup checks the created inode.

Run against a local bridge client using a NEW socket path:

```sh
python3 -B corev_apu/apu/tools/vn_native_bridge.py \
  --sock /tmp/g6lc-native-unique.sock \
  --map software/apu-venus-probe/venus_map.h
```

The map must be a generated header. Standard used-ring lengths count response
bytes; explicit `--rtl-used-length` selects the legacy consumed+written G6LC
vector accounting. Queue1/cursor, display scanouts and Vulkan capsets are not
advertised. No unsafe network or automatic socket-path deletion is introduced.

## Verification And Limits

The first isolated integrated cohort passes52 checks. The first real CLI/
existing RTL-client cohort passes58 in1.244s, using20 frozen source/assets
under `~/.cache/librecore/apu/native-bridge.ytdrBp`, with unchanged hashes.
It exercises full MMIO->ring->control->DMA->used/IRQ, overlap/private blob
content retention, wrap/reset, MMIO queued during DMA, peer DMA faults and
preservation of preexisting files. Final warning-strict rerun passes58 checks
in0.868s under `~/.cache/librecore/apu/native-bridge-final.DwlJgF`;20 input
hashes match. Default-PGO --check passes without builds. Scoped MIT tier/
header/ASCII/syntax/whitespace audit passes9 source files.

This is not a sampled CTS, native Venus, RTL equivalence or conformance pass.
Private retention of blob-owned bytes on unmap is a native behavioral contract;
current RTL blob-owned unmap drops backing to lazy rather than retaining it.
Cross-check and resolve that difference before promoting RTL equivalence.
Remote write failure can alter already-written bytes: metadata is not
published as success and the device requires reset; no async bus rollback
claim is made. Pin draining is synchronous and global, not complete
context-owned asynchronous job retirement.

No functional RTL, ISA/CSR/DTS/config/discovery, clock/reset/SRAM/DFT/PMU
or timing cone changes. No silicon timing/area/power promotion. Legacy golden
fixtures and user Storamic work remain untouched. New tooling is MIT tier,
upstream notices remain intact, and no RTL link sets change. Compiler and
simulator PGO policies/cache recipes remain unchanged; default-PGO
presence-only preflight passes without build/training/simulation.

## Remaining Work

Linear decode/reply and borrowed VkDeviceMemory ownership are implemented in
`apu-native-linear-implementation.md`. Ring scheduling/retirement follows
`apu-native-ring-implementation.md`. Budgeted GPU work execution, executor
retirement and capability/profile integration remain open.
Never advertise a Venus capset until these are wired
and truthfully checked. Full sampled CTS/remote RTL, aggregate/compliance/
formal/synthesis/physical qualification are separate gates.

## Next Integration Boundary

The existing golden decoder, FrontModel and TransportModel already perform
decode/execute/reply operations, but use trusted word dictionaries. A native
adapter must route their aperture reads/writes through the current shared/
private memory view rather than accidentally creating a disconnected shadow.
It must also bound stream work, isolate reply/ring state by context and
validate mapping generations during reply publication.

Memory-backed blobs resolve a VkDeviceMemory64-bit ID through the front
object table, including its generation, logical/page-rounded size, lazy
UNBACKED sentinel and actual aperture ownership. A borrowed alias must not
free its owner's pages. Resolve these lifetime/pin/relocation contracts before
enabling that path; merely accepting nonzero blob_id would be incorrect.
