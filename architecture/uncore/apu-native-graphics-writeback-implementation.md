# Native graphics fragment writeback (ROP slice)

Status: implemented, host-native-model evidence only.  No blend, depth/
stencil, logic-op, multi-attachment or `vkCmdDraw*` submission is claimed
or enabled.  Draw records still fail replay admission atomically; zero
capsets remain advertised.

## Scope

`corev_apu/apu/tools/vn_graphics_writeback.py` adds the first ROP slice as
an executor runtime operation:

- `Writeback` — frozen operation carrying the FS-in record image
  (`inputs`, FragCoord slot 0), the FS-out color record image (`colors`,
  `ATTR_STRIDE` layout, color `Location l` at `16*l`), the fragment
  `count`, the destination `owner`/`offset`/`pitch`/`width`/`height`, the
  device `fmt` id and the color `location` selector.
- `WritebackRuntime` — cooperative `advance(budget)`:
  1. validates record shapes (`count * 144` bytes each, count within
     `MAX_FRAGMENTS`), attachment geometry (positive pitch/width/height,
     bounded 4096) and format (device id 0..15 with nonzero bpp);
  2. resolves the destination span through `executor._extent` —
     generation-checked owner capability, retired/unbacked/oversize
     refusal before any work is published — and pins the owner;
  3. per fragment decodes `FragCoord` to pixel coordinates, drops
     negative or out-of-attachment fragments (`dropped` stat), unpacks the
     selected color location's vec4 and converts it with the same
     `vn_golden.img_clear_texel` encoder the render-pass clear path uses
     (uint/flt raw, f32->f16, sRGB LUT, UNORM8, BGRA swap);
  4. writes the packed texel at `base + py*pitch + px*bpp` through the
     shared aperture, `WRITE_QUANTUM` (4096) fragments per turn, resuming
     by cursor; context retirement is checked every fragment.
- `TransferExecutor` accepts `Writeback` beside the other runtime ops;
  `_turn` retires it with
  `job.writeback_stats[op] = {records, dropped, steps}`.

## Budgets and faults

- `count <= MAX_FRAGMENTS` (32768); inputs/colors byte images are bounded
  by the executor aggregate byte budget at enqueue.
- Single color attachment, single color location; no blending (fixed-state
  profile already rejects blendEnable), no depth/stencil, no scissors
  beyond the attachment bounds check, no MRT.
- Out-of-range fragments are dropped, not faulted; aperture/context faults
  fault the job through the standard path.

## Evidence

- `test_vn_graphics_writeback.py` (5 tests): RGBA32F raw-texel placement
  and untouched-neighbor zero, RGBA8UNORM conversion + out-of-bounds
  drops, color-location slot selection, multi-turn completion and
  end-of-owner extent refusal, admission refusals.
- Frozen native cohort `native-writeback-01`: 608 tests PASS in 17.9 s,
  `sources_unchanged: true`; `PASS: host-native-model; no RTL/CTS
  qualification`.

## Not claimed

Blend/depth/stencil/logic-op, MRT, per-fragment ordering guarantees vs.
other attachments, `DrawPlan` -> operation conversion, `vkCmdDraw*`
replay, descriptor bindings, synchronization, capsets, CTS, RTL and
physical qualification all remain open.  This stage is reachable only as
an executor runtime operation from native tests; no wire command produces
it yet.
