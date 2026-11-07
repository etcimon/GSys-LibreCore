# APU Native Subpass Dependency Foundation

Date: 2026-11-06. Scope: `corev_apu/apu/tools/` host-model only.

## What changed

`vkCreateRenderPass` (v1) admission in `vn_native_rendering.capture()` now
accepts bounded multi-subpass render passes and `VkSubpassDependency`
records instead of requiring `subpassCount == 1` and
`dependencyCount == 0`.

- `subpassCount` is admitted in `1..4`; `dependencyCount` in `0..8`.
- Per-subpass scalar/array fields (`pipelineBindPoint`,
  `inputAttachmentCount`, `pInputAttachments`, `colorAttachmentCount`,
  `pColorAttachments`, `pResolveAttachments`, `pDepthStencilAttachment`,
  `preserveAttachmentCount`, `pPreserveAttachments`) must each appear once
  per subpass element and every restricted member stays refused inside
  every subpass — input, resolve, depth/stencil and preserve attachments
  remain outside the profile exactly as they were for the single-subpass
  case.
- Each subpass's `colorAttachmentCount` (0..4) must equal its
  `pColorAttachments` array count; the concatenated `attachment`/`layout`
  reference lists are sliced per subpass in decode order. The existing
  per-subpass checks (attachment index `< attachmentCount`, no duplicate
  used index inside one subpass, reference layout in `{1, 2}`) now apply
  per subpass — an attachment may legitimately appear in several subpasses.
- `VkSubpassDependency` fields are retained and validated: `srcSubpass`/
  `dstSubpass` must be a subpass index or `VK_SUBPASS_EXTERNAL`
  (`0xFFFFFFFF`), not both external; `srcStageMask`/`dstStageMask` must
  stay inside the graphics stage bound mirrored from
  `vn_image_barriers.scope()` (`0x17001 | 0x78E`);
  `srcAccessMask`/`dstAccessMask` inside the coherent access bound
  (`0x1F98F`); `dependencyFlags` admits only `BY_REGION` (bit 0).
- `RenderPass` gains `subpasses` (every subpass's color-reference tuple)
  and `dependencies` (the validated 7-tuples). `colors` keeps subpass-0's
  references — the only executable profile — so `compatible()`,
  framebuffer identity, clear-attachment resolution, layout replay and
  draw-state consumers are unchanged.

## Execution boundary (unchanged, made explicit)

Multi-subpass render passes are *described* but not yet *executed*:

- `vn_render_pass_commands.capture()` refuses `vkCmdBeginRenderPass` /
  `vkCmdBeginRenderPass2` on a pass with `len(rp.subpasses) > 1` with a
  clean `ValueError` at capture time — before the command is recorded, so
  no `DEVICE_LOST` trap and no partial render-pass state. Single-subpass
  passes are unaffected.
- `vkCmdNextSubpass`/`vkCmdNextSubpass2` remain refused by the same
  single-subpass profile guard.
- The ObjPay keep-format, RTL `StBrpPayCpl` cursor walk, the
  `vn_golden.py` submission parse and per-subpass layout publication are
  unchanged — they still model one subpass. Extending them is the next
  increment and must land together (ObjPay format + RTL FSM + Python
  mirror + replay + directed tb) to avoid mirror drift.

Dependency records are validated and retained on the snapshot for that
follow-up; they do not yet influence execution ordering (the executor is
serial, so ordering is trivially satisfied) or layout transitions
(per-subpass reference layouts are retained in `subpasses` but only
subpass-0 layouts publish today).

## Evidence

697 frozen checks pass in 18.6s from remote cohort
`native-subpass-exec-02` (`native-execution.nfbjcmrg`, ovh_calltorch,
`sources_unchanged: true`, returncode 0) — five net new cases over the
692-check `native-subpass-02` cohort: multi-subpass Begin/NextSubpass/End
execution with layout publication and clear writeback, NextSubpass
scope/count refusals (no active pass, past-last, single-subpass),
draw-state subpass indexing (subpass-1 pipeline draws after
`vkCmdNextSubpass`; subpass-0 pipeline refused inside subpass 1), and
Begin→End without NextSubpass keeping the entered-subpass layout set at
end-validation. Prior cohort `native-subpass-exec-01`
(`native-execution.4b9jy72_`): 696 checks pre-EndPass-subpass-fix.
Local focused runs: `test_vn_native_rendering.py` +
`test_vn_render_pass_commands.py` + `test_vn_graphics_draws.py` +
`test_vn_graphics_draw_replay.py` + `test_vn_render_pass_clear.py` all
pass; the full local `test_vn_*` sweep (669 tests) shows only the known
Windows-socket bridge failures (remote cohort authoritative).

## Next increment: multi-subpass execution (design of record)

The execution follow-up must land ObjPay format + `vn_golden.py` mirror +
RTL `StBrpPayCpl` + replay + directed tb **together** — the keep-fields
emit one fixed word layout per command, so any format change breaks the
single-subpass parse in both mirrors if not synced. Agreed format:

```
{A, {fmt,loadOp,storeOp}*A, S,
  per-subpass i in 0..S-1:
    {C_i, {att,lay}*C_i, ptrDepth_i(2w), [datt_i, dlay_i]},
  D, per-dep j in 0..D-1: {srcSub,dstSub,srcStage,dstStage,srcAccess,dstAccess,depFlags}}
```

- `ptrDepth_i` is the kept `pSubpasses.pDepthStencilAttachment` PTR op —
  always 2 words (0 when null), giving an unambiguous block boundary;
  `datt_i`/`dlay_i` follow only when nonzero (existing
  `pSubpasses.attachment`/`pSubpasses.layout` body keeps).
- Color refs keep `.layout` too (`pSubpasses.pColorAttachments.layout`)
  so per-subpass layout transitions have data.
- Deps append last (`dependencyCount` + seven `pDependencies.*` keeps);
  serial executor needs them for validation only, not ordering.
- Keep-fields additions: `pSubpasses.pColorAttachments.layout`,
  `pSubpasses.pDepthStencilAttachment`, `pSubpasses.layout`,
  `dependencyCount`, `pDependencies.{srcSubpass,dstSubpass,srcStageMask,
  dstStageMask,srcAccessMask,dstAccessMask,dependencyFlags}` — for both
  `vkCreateRenderPass` and `vkCreateRenderPass2` (same member names).

RTL `StBrpPayCpl` (g6lc_apu_cmdexec.sv ~L2695-2756): phase 2 currently
requires `subpassCount==1`; extend to `1..4`, then walk S blocks storing
per-subpass `{ncl[2:0], cref[4]x4b, dref[3:0]}` in a small table
(`brp_sp_*` regs, S<=4). `snap_q.subpass` already increments on
`VK_CMD_NEXT_SUBPASS_EXT` (L1566); `ca_q`/`da_q`/`brp_cref_q` snapshot
must index `table[snap_q.subpass]` instead of the single parsed block,
and NextSubpass re-snapshots + (native-side) publishes layout
transitions. Clears iterate the ACTIVE subpass's loadOp attachments.
Bound: subpassCount<=4, depCount<=8, ptrDepth presence flag.

`vn_golden.py` `_disp_assembly_lost` (L3129-3176): replace the
`subpassCount!=1` reject + flat cref/dref read with the block walk above;
`ca_ok`/clear `wk` items use subpass-0 refs (only subpass that can run
until NextSubpass lands); dep words are skipped/validated.

`vn_render_pass_commands.py`: admit `vkCmdNextSubpass`/`2` inside an
active pass when `subpass+1 < len(rp.subpasses)` — emit a NextSubpass op
carrying the new index; keep refusing out-of-range.

`vn_render_pass_replay.py`: Begin publishes subpass-0 ref layouts;
NextSubpass publishes the entered subpass's ref layouts (each ref's
`layout` must equal the attachment's current tracked layout or
UNDEFINED-discard semantics per the layout-tracking rules); End
publishes `finalLayout` for all attachments. Draw-state consumers
(`vn_graphics_state.py:47`, `vn_graphics_interfaces.py:113`,
`vn_graphics_pipelines.py:83`) index `rp.subpasses[active]` instead of
`rp.colors`.

Tests: multi-subpass begin/next/end layout chains, dep-word walk,
out-of-range NextSubpass refusal, per-subpass attachment-set swap,
RTL tb cases for the block walk + synth screens.

## Native multi-subpass execution (landed)

The native host-model execution path now walks all retained subpasses;
the wire ObjPay/RTL path still admits only `subpassCount==1` (see
Boundaries). No ObjPay format change was needed: the keep-fields already
emit per-subpass `{colorAttachmentCount, refs}` blocks in struct order,
and the bounded profile refuses depth/input/resolve/preserve per subpass,
so a multi-subpass payload is an unambiguous sequence of
`{C_i, C_i refs}` blocks.

- `vn_native_rendering.RenderPass` gains `subpass_count` /
  `subpass_colors(index)` accessors over `subpasses` (subpass-0 remains
  `colors` for compatibility).
- `vn_render_pass_commands.py`: `vkCmdBeginRenderPass` no longer refuses
  multi-subpass passes; new `NextPass` recording + `_capture_next`
  admits `vkCmdNextSubpass` inside an active pass while
  `index+1 < subpass_count` (out-of-range and no-pass refuse at capture,
  faulting the stream like other admission faults). `_subpass_index`
  counts `NextPass` records bound to the active `BeginPass`;
  `ClearAttachments` and `EndPass` record the active subpass index, and
  `ClearAttachments` validates targets against that subpass's color refs.
- `vn_render_pass_replay.py`: `_layouts` begin publishes only subpass-0
  reference layouts (later-first attachments keep `initialLayout`); end
  validates/publishes against the last referencing subpass layout among
  the subpasses *actually entered* (`EndPass.subpass`), so trailing
  unentered subpasses never transition — via `_last_subpass_layout`.
  New `_enter_subpass` performs
  the boundary transition: each attachment referenced by the entered
  subpass must hold the layout of the subpass that last referenced it
  (or `initialLayout` when first referenced; `UNDEFINED` discards),
  resolved two-phase before any publish.
- `vn_graphics_draws.py`: `GraphicsDraws` tracks the active subpass
  (`_next` validates `NextPass.begin`/`subpass` ordering), `DrawPlan`
  carries `subpass`, and `_draw` requires `pipeline.subpass ==
  active subpass`.
- `vn_graphics_pipelines.py`/`_state`/`_interfaces`: `VkGraphicsPipeline
  CreateInfo.subpass` is admitted in `0..subpass_count-1`, bounds-checked
  against the render pass, stored on `GraphicsPipeline`, and threaded
  into fixed-state/interface validation so blend/attachment counts and
  fragment outputs validate against the *target* subpass's refs.
- `vn_transfer_replay.py`: `vkCmdNextSubpass` joins the render-pass
  record set so both the draw consumer (subpass tracking) and
  `replay_render_pass` (layout transition) observe it.

Dependency records remain create-time metadata: the serial executor
trivially satisfies their ordering, and per-subpass layouts now come from
the reference tuples rather than the dependency list.

## Multi-subpass wire path (landed)

The serialized wire path now mirrors the native semantics: the ObjPay
payload is unchanged (per-subpass `{colorAttachmentCount, refs}` blocks
were already emitted by the keep-fields), and both the golden model and
the RTL walk every block.

- `vn_golden._disp_assembly_lost`: `subpassCount` is read as 1..4; the
  S==1 path is bit-identical to the old parse (optional trailing depth
  word gated by `rp_w`). For S>1 each `{C_i, refs_i}` block is walked
  with per-ref bounds checks and *exact* payload consumption required —
  a depth word per subpass would be ambiguous with the next block's
  `colorAttachmentCount`, so multi-subpass payloads are depth-free by
  contract. `ca_ok` keys on subpass-0's refs only (draws are
  subpass-0-only until pipeline-subpass admission). The model also
  tracks `rp_on`/`sp_act`/`sp_n`: `vkCmdNextSubpass` refuses outside an
  active pass or past the last subpass, `vkCmdEndRenderPass*` clears
  `rp_on`, and the draw guard refuses `sp_act != 0` — matching RTL.
- `g6lc_apu_cmdexec.sv` `StBrpPayCpl`: phase 2 admits `subpassCount`
  1..4 into `brp_nsp_q`; phases 3/4 walk each subpass's
  `{C, refs*C}` block into the new bounded table `sp_ncl_q[4]`,
  `sp_cref_q[4][4]`, `sp_dref_q[4]` (depth ref stored only for the
  S==1 tail, phase 5). `brp_pi_q` widened 5→6 bits (worst-case payload
  1+15+1+4·5 = 37 words). The block tail distinguishes next-subpass
  (`sp+1 < nsp` → phase 3), S==1 optional depth (words-remain → phase
  5), and last-subpass exact consumption (`pi+1 == rp_w`, else lost).
  The cref done-check was also fixed for `colorAttachmentCount==4`
  (the old `cj+1 >= ncl` wrapped in 2 bits and could never terminate).
- `StBrpClrN` snapshots `ca_q`/`da_q` from `sp_*[snap_q.subpass]` —
  subpass 0 at BeginRenderPass, exactly as before for S==1.
- `VK_CMD_NEXT_SUBPASS_EXT` dispatch: refuses when `!rp_active` or
  `subpass+1 >= nsp`, else re-snapshots `ca_q`/`ca_valid_q`/`da_q`/
  `da_valid_q` from the table row of the *new* index (same two-phase
  resolve-then-publish shape as `StBrpClrN`, incl. malformed-ref
  `lost_q`).
- Draw guards (direct + indirect) now also require `snap_q.subpass ==
  0`: with only subpass-0 pipelines admissible (`g6lc_apu_vgp` decode
  still gates `subpass==0`), a draw in subpass ≥1 would bind a
  mismatched pipeline — refused honestly rather than mis-rendered.

Verification (remote `ovh_calltorch`, Verilator 5.008 PGO + Yosys
`g6lc-formal`): `PASS tb_g6lc_apu_cmdexec cases=13 checks=74` — new
directed cases cover Begin/End snapshot (ca w=64), Begin/NextSubpass/
End re-snapshot (ca w=32 = subpass-1's attachment), past-last
NEXT_SUBPASS loss, and subpass-1 draw loss; the pre-existing
single-subpass case still passes. `SYNTH OK Enable=0/1` —
114671 cells / 20647 ff, no latches, no retained memory, 0 problems.
Native cohort `native-subpass-wire-01`: 697 checks PASS in 18.6 s,
`sources_unchanged: true` (host-model regression only — the Python
wire-submission path had no dedicated ns>1 fixture yet).

Wire-path coverage landed in `test_vn_graphics_draw_replay.py`
(cohort `native-subpass-wirecov-01`: **700 checks PASS in 18.7 s**,
`sources_unchanged: true`, cohort `native-execution.47rnt9_i`): a real
two-subpass `VkRenderPass`/`VkFramebuffer` recorded through Venus wire
commands exercises Begin→`vkCmdNextSubpass`→End end-to-end (ObjPay
block walk + re-snapshot + replay boundary layouts → `done`); a second
`vkCmdNextSubpass` past the last subpass faults the stream at record
time (`StreamFault`); and a wire-recorded draw inside subpass 1 with a
subpass-0 pipeline is refused at enqueue (`ValueError` from the draw
consumer's `pipeline.subpass != active subpass` check).

## Pipeline-subpass admission (wire path)

The last multi-subpass gap — a pipeline's declared
`VkGraphicsPipelineCreateInfo.subpass` now travels the wire end-to-end
and is matched against the active render-pass subpass at draw
assembly, in both the Python mirror and the RTL.

- `vn_device_profile.toml` `[keep.vkCreateGraphicsPipelines]` gains
  `pCreateInfos.subpass` as the last keep word (after the 2-word
  layout id, matching vk.xml decode order). `gen_vn_tables.py
  --audit-profile` clean (commands 155, unfit 0); the regenerated
  `g6lc_apu_vn_pkg.sv` diff is exactly one ROM entry — the subpass
  field flips KEEP (`48'h01FF…`). Every graphics-pipeline staged
  payload grows by one word.
- `g6lc_apu_vnfront.sv`: new `gp_sp_q[1:0]` register; the staged parse
  gains phase `7'd91` after layout-id hi (`6'd45`) — a subpass word
  `>3` fails the create (`StPipeFail`), else it parks and the VS
  module LOOKUP proceeds exactly as before. `StGpObjC` packs it into
  the pipeline object's `aux[31:0]` as `{chunk[15:0], 6'h0,
  subpass[1:0]@9:8, 1'h0, gfx=1@6, 6'h0}` — aux[9:8] is the new field,
  aux[6] graphics bit and the ObjPay chunk are unchanged, so no
  ObjPay/consumer offset moved.
- `g6lc_apu_vgp.sv`: `decode_ok` relaxes `subpass==0` to
  `subpass[31:2]==0` — the control-space subpass admits the bounded
  0..3 range (the render pass admits `subpassCount` 1..4). The value
  itself is not carried on `apu_vgp_t`; admission is re-bounded on
  the authoritative keep word by vnfront.
- `g6lc_apu_cmdexec.sv`: the early draw guards drop the blanket
  `snap_q.subpass != 0` clause (direct + indirect); `StDsPipeCpl`
  gains the real check — for draw records
  (`rec_is_draw`, covering direct and both indirect types) the
  resolved pipeline's `aux[9:8]` must equal `snap_q.subpass`, else
  `lost_q` like a dead pipeline. Compute pipelines skip it
  (`rec_is_draw` qualifier) and the `aux[6]` graphics check still
  runs first.
- `vn_golden.py` mirror: `_gpipe_build` consumes the new trailing
  keep word (`sp = nx()`, `>3` fails), validates it, and packs
  `aux[31:0]` identically (`… | (sp & 3) << 8 | 0x40`); the
  `_disp_assembly_lost` draw guard moves the subpass test after
  pipeline resolution — `sp_act != ((pe['aux'] >> 8) & 3)` loses the
  submission, covering direct and indirect draws alike.

Verification: local `test_vn_graphics_draw_replay` 17/17 — a
subpass-1 pipeline draws after `vkCmdNextSubpass` and drains `done`
(full wire path: keep word → `_gpipe_build` aux → assembly match →
replay), a subpass-0 pipeline in subpass 1 refuses at enqueue, and a
subpass-1 pipeline in subpass 0 refuses symmetrically; the full local
`test_vn_*` sweep shows only the known Windows socket-bridge failures
(remote authoritative). Remote native cohort `native-pipesub-01`:
**702 checks PASS in 18.2 s**, `sources_unchanged: true`, cohort
`native-execution.ncg5bl_7`. Remote leaf `apu-leaf-20261107T062540-
af420eedd4e7` (stages unit,synth, Verilator PGO + Yosys): the changed
modules pass — `PASS tb_g6lc_apu_vnfront cases=47 checks=563` and
`PASS tb_g6lc_apu_cmdexec cases=14 checks=80` (new directed cases: a
subpass-1 pipeline object shares the ObjPay block and draws cleanly in
subpass 1; the same pipeline in subpass 0 loses; the subpass-0
pipeline in subpass 1 still loses via the aux[9:8] mismatch). xfer and
shwave leaves report INCOMPLETE on simulator-PGO provisioning timeouts
(infra, unrelated to the diff — same failure mode as the previous
leaf); the synth stage verdict was still running at record time.

## Boundaries

Host-model + leaf-RTL evidence only. No capsets, no stock Mesa/CTS/
physical/WSI or silicon qualification. Multi-subpass is implemented
end-to-end in both the **native replay path** and the **wire path**,
including pipeline-subpass admission: the declared subpass rides the
keep stream into `aux[9:8]` and draw assembly requires
`pipeline.subpass == active subpass` (direct + indirect). Remaining
open: external semaphore import/export, deeper stock Mesa fault
depth and the independent qualification gates.
