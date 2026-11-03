# Configuration and capability grants

The native host owns a default-zero `CVA6Cfg.StoramicEn` flag, copied from the user
configuration. Standalone Storamic owns its independent geometry/configuration
types. The attachment projects the host flag into the selected subsystem profile;
two independently authoritative enable settings are forbidden.

## Selection

Exactly one backend owns a primary-memory aperture. Enabling Storamic conflicts
with explicit direct DDR4/LPDDR/simulation-backend selections, including legacy AI
class/channel flags. Dormant default simulation settings do not instantiate a
second memory. Conflicts must fail at host configuration and RTL elaboration;
precedence must not silently discard a request.

When disabled, preserve existing memory instance behavior and source ordering.
Minimal upstream targets must continue to elaborate. Native core pipeline logic
does not select stick channels.

## Structural versus discovered state

Compile-time: maximum sticks, physical slot profile, controller/slot mapping,
supported chip-select count, bus widths, outstanding credits, region capacity,
ECC mode, and requested capability mask.

Runtime: presence, identity, validated capacities, training, health, committed
mapping and persistence readiness. These cannot create pads or controllers.

Initial maximum-stick envelope is 1..8 with default 1 when enabled; test
1/2/3/4/8. Slot count need not be a power of two. Internal safe vector widths
avoid zero-width declarations; board-level disabled profiles omit ports.

The [general-purpose review](general-purpose-review.md) proposes candidate
controls (media channels, queue geometry, role selection and related knobs).
They are proposals, not accepted fields: any control enters only through the
single normalized config authority plus `CVA6Cfg`/native/host validation —
never speculative boolean proliferation.

No requested capability may exceed its implementation grant. M0 supports only
an explicit skeleton profile: no RAM capacity, no PMEM, no block transport, no
host-transport device and no trained physical link. `init_done` remains false. Selecting the
skeleton as native primary memory is intentionally not a successful Linux boot.

Native physical-address limits, integer overflow, overlap, profile voltage,
capacity maxima and per-slot geometry are legality checks, not silent truncations.
Host tooling and RTL consume the same published values; unresolved values remain
unresolved in emulation.

## Foundation selection and attachment

The first implementation publishes `g6lc_storamic_cfg_pkg::StoramicOff` and
`StoramicSkeleton`. In a native build, use either the user-package flag or the
`G6LC_STORAMIC` overlay, with explicit `G6LC_STORAMIC_SKELETON` and optional
`G6LC_STORAMIC_MAX_STICKS=N`. The SoC projection is
`corev_apu/include/g6lc_storamic_soc_cfg_pkg.sv`.

Build-platform configuration is `soc.storamic`:

```typescript
storamic: { enable: true, profile: "skeleton", maxSticks: 3 }
```

It resolves to `G6LC_STORAMIC_DEFINES` for Makefile consumers. Test/verify/remote
gateways reject conflicting explicit direct-memory flags. Raw RTL configurations
also have time-zero fatal guards for invalid geometry/profile/backend combinations.
Do not describe a simulation-start guard as electrical or device qualification.

The default `i_dram_backend.gen_sim_axi` hierarchy is preserved. Selection occurs
inside `g6lc_ai_dram_backend`, whose added parameter defaults to zero. The M0
attachment preserves the complete AW/W/AR payload with interface-shape
validation, ties off the standalone AXI-Lite port, and exposes no new
MMIO/IRQ/DTS node. The native projection remains off/refuse only: the typed
model profile is standalone and never selectable through `StoramicEn`. Physical
read data has no successful-media interpretation yet.

`check_cfg` validates the enabled frontend's nonzero address/ID geometry and
power-of-two 8..1024-bit AXI data width. Backend/profile conflicts are checked at
the SoC projection, which owns the memory selection. Xilinx, Altera and OpenPiton
wrappers reject the flag until they gain a Storamic binding; they must not keep
using their old memory path while silently ignoring an enabled feature. Their
static rejection guards are not board elaboration or physical qualification.

M0 native evidence covers the backend seam, not a complete enabled CPU boot
simulation. Existing ELF preload helpers address the legacy SRAM hierarchy;
use the Storamic RTL leaf rather than those boot drivers. A full enabled
CPU/atomic-wrapper simulation and a non-bypassing preload/initialization contract
remain integration gates before executable media can be claimed.
