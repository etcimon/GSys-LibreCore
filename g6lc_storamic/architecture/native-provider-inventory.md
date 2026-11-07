# Native Checkpoint Provider Inventory

This is a source inventory, not a native qualification result. It is bounded
to the current ariane testharness and its compile-time branches, not every
board, FPGA or private SoC topology.

## Physical Sources And Queues

`corev_apu/tb/ariane_soc_pkg.sv` declares three crossbar initiators:
CPU/cluster, debug master, and the shared device/AI port. The native harness
crossbar uses `NB_MST = NB_PERIPHERALS + APU_NB_EXTRA + STORAMIC_NB_EXTRA`,
with eight outstanding slots and NO_LATENCY. APU adds three targets and one
extra address rule; Storamic IO adds one target/rule. The protected-route
3x2 component bench therefore does not establish this full target topology.

`corev_apu/tb/ariane_testharness.sv` has distinct device-source branches:
- Ordinary 64-bit path: AI DMA time-shares with Storamic DMA. With G6LC_APU,
  the APU TDMA join combines APU DMA and that shared stream before slave[2].
- G6LC_AI_DRAM_ISLAND_PORT: the island has a separate 512-bit DRAM join; APU
  DMA takes slave[2], or that port is idle without APU.
- G6LC_AI_DRAM_WIDE_CH changes the DRAM channel width and adds upsizing/join
  ownership outside the 64-bit crossbar.

The current Storamic VirtIO instantiation ties DMA pause and control seal low,
and discards quiesced/error/inflight observations. The shared DMA adapter's
inflight output is also unconnected. Its corrected AXI ownership alone cannot
supply producer pause acknowledgement from upstream AI/APU queues.

CPU/cluster request queues, store buffers, WT cache state, debug-origin traffic,
AI queued submissions/descriptor fetch and APU/device queues must be inventoried
and stopped at their admission boundaries, not merely at the memory slave.
An AXI-empty observation is not proof that those producers cannot issue later.
Independent APU alias-unmap changes are unrelated and remain untouched.

## Synchronization And Authority

The harness routes Storamic DMA block invalidation request/ready/done into
the cluster CMO path. That is useful existing hardware, but a DMA-write block
invalidation is not a complete checkpoint-wide clean/invalidate/reservation/
device-resume protocol. `corev_apu/src/ariane.sv` exports L1 invalidation and
CMO sidebands; no checkpoint pause/resume acknowledgement is bound there.

`g6lc_storamic_attach` still maps CheckpointRequested to StoramicOff and
emits STORAMIC_CHECKPOINT_NATIVE_BINDING_REQUIRED in simulation. There are
no native bound immutable descriptor/module-identity/mapping-generation/
protection providers or a complete policy/route/owner composition.

The candidate checkpoint route is AW-first: its control bridge backpressures
W until AW is accepted. Thus W-before-AW is not an additional uncounted route
owner. Its post-crossbar master prefix still cannot identify every physical
source hidden behind joins or establish hart/debug authority on its own.

## Next Implementable Composition

Bind the existing policy manager to the real model writer's pause, separate
control seal and complete endpoint/DMA ownership. Keep upstream presence,
upstream queue hold/pause, route/maintenance ownership, provider readiness,
authorization and resume safety external. Retain old epoch/payload while
accepted jobs, store flush, command result and control responses drain.

This narrows C3/C4 orchestration without claiming native facts. An opaque
policy payload is not a native descriptor or authorization provider. Pending
replacement must not invent a flush: dirty staging requires an already
admitted checkpoint/flush or a genuine platform maintenance owner. Missing
drain legitimately retains the old epoch indefinitely; no timeout discards it.

Next native work still requires branch-specific source identity/queue drains,
qualified platform fact capture and full CPU/cache/reservation/device resume.
C0/C1 strict scheduling/remaining instruction cases, C2 full topology, C3-C6,
physical P0/P1, aggregate/compliance/DFT/PPA V0 and Linux L0/L1 remain open.
