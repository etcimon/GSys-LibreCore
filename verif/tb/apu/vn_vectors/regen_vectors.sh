#!/usr/bin/env bash
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
# Regenerate the vn_vectors sessions affected by the §12.3 3d-d record
# change (record +0 = {gen,slot} handle, +28 = resource offset), the
# §5a G3b-iii command-record redesign (chunked record/payload chains,
# descriptor blocks, events, indirect operands, secondaries,
# DispatchBase) and the new arms.  Deterministic (seeded) — unchanged
# sessions regen byte-identical.  Run under the repo's WSL python3:
#   bash verif/tb/apu/vn_vectors/regen_vectors.sh
set -e
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
cd "$ROOT"
G=corev_apu/apu/tools/vn_golden.py

python3 $G --transport ue_sm5_transport 1
# decoder/reply vectors: keep-list and profile changes alter payw/rep
# --count 17 is the largest batch that still fits the 64 Ki-word
# decoder stream window for this vector set (18 overflows).
python3 $G --vectors ue_sm5_core 1 --count 17
python3 $G --reply-vectors ue_sm5_reply 1
python3 $G --session ue_sm5_session 1
python3 $G --payfull-session ue_sm5_payfull 1 --paywords 512
# §12.3 3d-d: vnfront bind-time ALLOC_HI-FULL arm
python3 $G --bindfull-session ue_sm5_bindfull 1
# W3.5 wedge-3 arm: CbBufs=16 exhaustion -> OOM alloc reply, phantom-
# handle submit -> VK_ERROR_UNKNOWN with no executor push
python3 $G --cbfull-session ue_sm5_cbfull 1

# pure positive sessions: ue_cpos_<v>_<n> <- shvec <v>_<n>
for v in arrlen arroob barrier_reduce barrier_reduce_opt bufcopy \
         bufscale builtin_gid builtin_lid builtin_lindex compare \
         composite descarr intmix localsize32 localsize64 loopfor \
         loopfor_opt math450 multiset oob pushscale vec4arith; do
  for n in 1 2 3; do
    python3 $G --compute-session ue_cpos_${v}_${n} ${v}_${n}
  done
done

# positive variants on bufcopy_1
python3 $G --compute-session ue_cpos_multiwr_1  bufcopy_1 --variant multiwr
python3 $G --compute-session ue_cpos_xfer_copy_1 bufcopy_1 --variant xfer_copy
# vkUpdateDescriptorSets COPIES (dcopy): writes land in staging twins and
# pDescriptorCopies moves every element into the real sets — the first
# vectors with descriptorCopyCount > 0 (array binds -> non-zero offsets)
python3 $G --compute-session ue_cpos_dcopy_bufcopy_1 bufcopy_1 --variant dcopy
python3 $G --compute-session ue_cpos_dcopy_descarr_1 descarr_1 --variant dcopy
python3 $G --compute-session ue_cpos_dcopy_multiset_1 multiset_1 --variant dcopy
# T4: one-region whole-buffer copy of 1 MiB + 1 bytes (dEQP buffer_1048577)
python3 $G --compute-session ue_cpos_xfer_big_1 bufcopy_1 --variant xfer_big
python3 $G --compute-session ue_cpos_xfer_update_1 bufcopy_1 --variant xfer_update
# §12.3 D/C new positives
python3 $G --compute-session ue_cpos_dslcompat_1 bufcopy_1 --variant dslcompat
python3 $G --compute-session ue_cpos_emptylayout_1 bufcopy_1 --variant emptylayout
python3 $G --compute-session ue_cpos_imm_texlod_1 texlod_lin_1 --variant immutable
python3 $G --compute-session ue_cpos_imm_copy_1 texlod_lin_1 --variant immutable_copy
python3 $G --compute-session ue_cpos_imm_array_1 texarr_1 --variant immutable
python3 $G --compute-session ue_cpos_memsplit_1  bufcopy_1 --variant memsplit
python3 $G --compute-session ue_cpos_poolreset_1 bufcopy_1 --variant poolreset

# negatives
python3 $G --compute-session ue_cneg_badmod_1 bufcopy_bad_0
for var in modgone lostbuf spec baddesc nopipe pgfull badmem bindoob \
           descoob updoob layoutmix deadpool poolfull xfer_oob \
           xfer_overlap unbacked; do
  python3 $G --compute-session ue_cneg_${var}_1 bufcopy_1 --variant $var
done

python3 $G --compute-session ue_ws0_texfetch_1 texfetch_1 --variant worksink

# §12.3 C/5b image sessions + negatives (descriptor records change)
for v in texfetch_1 texfetch_2 texfetch_3 \
         texfetch_mip_1 texfetch_mip_2 texfetch_mip_3 \
         texarr_1 texarr_2 texarr_3 \
         texlod_lin_1 texlod_lin_2 texlod_lin_3 \
         texlod_mip_1 texlod_mip_2 texlod_mip_3 \
         texquery_1 texquery_2 texquery_3 \
         texsrgb_1 texsrgb_2 texsrgb_3 \
         imgloadstore_1 imgloadstore_2 imgloadstore_3 \
         imgatom_1 imgatom_2 imgatom_3; do
  python3 $G --compute-session ue_cpos_$v $v
done
for va in badfmt viewoob kindmix xfer_img_oob unnorm; do
  python3 $G --compute-session ue_cneg_${va}_1 texfetch_1 --variant $va
done
for v in texfetch_bad_0 texlod_lin_bad_0 imgloadstore_bad_0 \
         texquery_bad_0; do
  python3 $G --compute-session ue_cneg_${v%_0}_1 $v
done

# §12.3 C/5b-r2 clear sessions + ctx-kill reuse (all on bufcopy_1)
for v in clear_rgba8 clear_r32f clear_r32u clear_srgb clear_rgba16f; do
  python3 $G --compute-session ue_cpos_${v}_1 bufcopy_1 --variant $v
done
python3 $G --compute-session ue_cneg_clear_oob_1 bufcopy_1 --variant clear_oob
# T1: a scaled blit is refused before any write (unscaled blits run as I2I)
python3 $G --compute-session ue_cneg_blit_scaled_1 texfetch_1 --variant blit_scaled
python3 $G --compute-session ue_cpos_blit_id_1 texfetch_1 --variant blit_id
python3 $G --compute-session ue_cpos_ctxkill_reuse_1 bufcopy_1 \
    --variant ctxkill_reuse

# §12.3 3d-d host-visible-before-map arms (DEVBACKED bind backing,
# MAP_BLOB relocation + squatter eviction)
python3 $G --compute-session ue_cpos_rb_mapafter_1  bufcopy_1 --variant rb_mapafter
python3 $G --compute-session ue_cpos_ubo_bindfirst_1 bufcopy_1 --variant ubo_bindfirst
python3 $G --compute-session ue_cpos_evict_1        bufcopy_1 --variant evict
python3 $G --compute-session ue_cpos_reloc_hold_1   bufcopy_1 --variant reloc_hold
python3 $G --compute-session ue_cneg_evict_full_1   bufcopy_1 --variant evict_full
python3 $G --compute-session ue_cneg_bind_full_1    bufcopy_1 --variant bind_full
python3 $G --compute-session ue_cneg_stale_mem_1    bufcopy_1 --variant stale_mem
# §7b/5a-ii directed done-queue collision arm (generic record +
# dispatch in one submit; the vgtop TB collides the two completions)
python3 $G --compute-session ue_donecol_1 bufcopy_1 --variant donecol
# G3b-ii: 12 modules + 12 pipelines (> 8 residency slots), all
# dispatched twice incl. a zombie-module pipeline
python3 $G --compute-session ue_cpos_modres_1 bufcopy_1 --variant modres
# §6.1 implicit reset: re-record + resubmit the same cb (CTS
# device-local readback shape)
python3 $G --compute-session ue_cpos_rerec_1 bufcopy_1 --variant rerec

# G3b compute.pipeline.basic repro corpus (vgsys level only)
python3 $G --compute-session ue_cpos_zerodisp_1 bufcopy_1 --variant zerodisp
python3 $G --compute-session ue_cpos_shared1_1  cts_shared1_1
python3 $G --compute-session ue_cpos_atomic1_1  cts_atomic1_1
python3 $G --compute-session ue_cpos_arrlen1_1  cts_arrlen1_1
python3 $G --compute-session ue_cpos_ctsb2b_1   cts_b2b_1

# §5a G3b-iii executor paths (F8 smoke vectors)
# DispatchIndirect: blob-staged operands {0,0,0} no-op then {gx,gy,gz}
python3 $G --compute-session ue_cpos_dispind_1  bufcopy_1 --variant dispind
# DispatchBase: baseGroup offsets WorkgroupId/GlobalInvocationId
python3 $G --compute-session ue_cpos_dispbase_1 dispbase_0 --variant dispbase
# ExecuteCommands: two secondaries (one empty) then a post record
python3 $G --compute-session ue_cpos_exec2nd_1  bufcopy_1 --variant exec2nd
# SetEvent/WaitEvents in-buffer + host vkSetEvent releasing a stalled
# submission + vkGetEventStatus/vkResetEvent
python3 $G --compute-session ue_cpos_events_1   bufcopy_1 --variant events
# record_many shape: 5 000 CmdSetEvent/CmdResetEvent pairs in one
# primary (~160 record chunks — cursor/prefetch at every boundary)
python3 $G --compute-session ue_cpos_recmany_1  bufcopy_1 --variant recmany
# allocate_many shape: 10 000 live command buffers, 2 500 freed
# singly, vkDestroyCommandPool sweeps the remaining 7 500
# (--objslots = the RTL ObjEntries, not the 256 default)
python3 $G --compute-session ue_cpos_allocmany_1 bufcopy_1 \
    --variant allocmany --objslots 16384
python3 $G --compute-session ue_cpos_cbpoolreset_1 bufcopy_1 \
    --variant cbpoolreset
# ExecuteCommandStreams cursor: ONE record, streamCount=8 (the profile bound, over the
# retired Streams/TBUF caps) — per-stream reply positions
python3 $G --compute-session ue_cpos_xstreams_1 bufcopy_1 \
    --variant xstreams
# chunked submission: ONE VkSubmitInfo with 101 CBs (>4 chunk cap)
# on 10 shared events — every event must reply SET
python3 $G --compute-session ue_cpos_submit101_1 bufcopy_1 \
    --variant submit101

# graphics sessions — the variant is derived from the session name
# ('drawind'/'drawindx'/'vbwide'/'statvp'/'blend' substrings)
python3 $G --graphics-session ue_gpos_tri_1     1
python3 $G --graphics-session ue_gpos_vbwide_1  1
python3 $G --graphics-session ue_gpos_statvp_1  1
# §5a G3b-iii: DrawIndirect/DrawIndexedIndirect produce the direct-
# draw image; the operand sits at a 4-mod-8 byte offset (f_iw/
# ind_base_q[2] arm)
python3 $G --graphics-session ue_gpos_drawind_1  1
python3 $G --graphics-session ue_gpos_drawindx_1 1
python3 $G --graphics-session ue_gpos_blend_1    1
# dEQP-VK.memory.pipeline_barrier vertex-buffer shape: RG8_UNORM stride 2,
# POINT_LIST, CTS shaders verbatim (no varyings, constant-white FS)
python3 $G --graphics-session ue_gpos_ptsrg8_1  1
# same, 512 points (the CTS per-draw count): POINT_LIST over 63-vertex
# batches — before list batching the raster refused it UNSUPPORTED
python3 $G --graphics-session ue_gpos_ptsrg8x_1 1
# no vertex input state (0 bindings, 0 attributes), gl_VertexIndex VS —
# before the vnfront fix the pipeline create was refused
python3 $G --graphics-session ue_gpos_ptsvidx_1 1
# graphics bind point descriptor read: FS colour from a UBO (set 0)
python3 $G --graphics-session ue_gpos_fsubo_1 1
# Copy src array element 0 to dst element 1, then read it in the FS.
python3 $G --graphics-session ue_gpos_fsubocopy_1 1
# instanced draw: vs_inst offsets clip-x by 0.4*gl_InstanceIndex-0.6,
# instanceCount=4 — union coverage over 4 offset triangles, fs_flat
python3 $G --graphics-session ue_gpos_inst_1 1
# vertex-stage texture: vs_texlod samples a 1x1 uniform
# COMBINED_IMAGE_SAMPLER (VERTEX stage) -> constant vcol -> fs_flat;
# the sampler2d_fixed_vertex shape (device fence hang is guest-side)
python3 $G --graphics-session ue_gpos_vtex_1 1
# fragment-stage texture: vs_tex passes uv, fs_tex_implicit samples the
# same 1x1 COMBINED_IMAGE_SAMPLER (FRAGMENT stage, implicit LOD) ->
# constant colour; exercises the FS texture/sampler descriptor path
python3 $G --graphics-session ue_gpos_ftex_1 1
# fragment discard/helper lane: fs_kill drops a FragCoord 8x8
# checkerboard; vs_pos3 keeps vcol constant so tri_w holds on survivors
python3 $G --graphics-session ue_gpos_kill_1 1
# divergent function-call discard: fs_kill_fn sends odd-x lanes into a
# killer() that discards while even-x lanes take other()=vcol*2 then
# +0.25 blue; survivors clamp to (102,204,255,255), mask = x parity
python3 $G --graphics-session ue_gpos_killfn_1 1
# non-divergent function calls: fs_fncall runs a depth-3 chain
# (l2->l3->shade) + inout param (dark) + early return on constant vcol
# -> deterministic (20,78,173,255); no discard
python3 $G --graphics-session ue_gpos_fncall_1 1
# fragment textureBias: fs_tex_bias applies an explicit LOD bias
# (vcol.z==0 -> bias 0) on the same 1x1 CIS — the bias texture path
python3 $G --graphics-session ue_gpos_ftexb_1 1
# fragment sampler2DArray: fs_tex_array samples vec3(vcol.xy,vcol.z) on
# a 2-layer arrayed image + 2D_ARRAY view; vcol.z==0 -> layer 0, the
# uniform texel keeps tri_w while exercising the arrayed fetch path
python3 $G --graphics-session ue_gpos_ftexa_1 1
# fragment textureGather: fs_tex_gather runs OpImageGather (comp0->R,
# comp1->G) + textureGatherOffset on the same 1x1 CIS; every footprint
# corner clamps to the one texel so o=(200,200,80,80), decoupled from
# the texel via out_w
python3 $G --graphics-session ue_gpos_ftexg_1 1
# fragment NEAREST multi-texel: first real W_TX* sample — 4x4 RGBA8 image
# (64B pitch) + per-vertex uv spanning [0,1]; oracle interpolates vcol.xy
# bit-exact then floor(u*w)/floor(v*h)+CLAMP_TO_EDGE selects one texel per
# covered px; RGBA8 UNORM writeback is the identity so px = texel bytes
python3 $G --graphics-session ue_gpos_ftexn_1 1
# fragment LINEAR multi-texel: same 4x4 CIS + uv field, sampler runs
# bilinear — 8.8 coords floor(u*w*256-128) -> texel+frac, four CLAMP
# corners weighted wu*wv (sum 65536) accumulate gw*ch (ch=byte*0x101),
# rr=(acc+0x8000)>>16 -> wb=rr*0x37800080 -> UNORM8
python3 $G --graphics-session ue_gpos_ftexl_1 1
# fragment NEAREST multi-texel + REPEAT wrap: same 4x4 CIS, uv spans
# beyond [0,1] so floor(u*w) lands outside [0,w); integer coord wraps
# mod w (f_twrap REPEAT arm) instead of CLAMP_TO_EDGE
python3 $G --graphics-session ue_gpos_ftexr_1 1
# fragment NEAREST multi-texel + MIRRORED_REPEAT wrap: same 4x4 CIS +
# wide uv, addressMode=1 exercises the f_twrap m=1 mirror-fold arm
# (mm=i|-i-1, r=mm%(2n), reflect r>=n -> 2n-1-r)
python3 $G --graphics-session ue_gpos_ftexmir_1 1
# fragment NEAREST multi-texel + CLAMP_TO_BORDER: same 4x4 CIS + wide
# uv; coords outside [0,dim) raise the f_twrap m=3 border flag ->
# f_bord16(borderColor) border substitute.  ftexc=5 white, ftexc2=2 white
# (regression for the raw-VkBorderColor decode), ftexcb=1 black,
# ftexct=0 transparent — together they pin f_bord16/32 for {0,1,2,5}.
python3 $G --graphics-session ue_gpos_ftexc_1 1
python3 $G --graphics-session ue_gpos_ftexc2_1 1
python3 $G --graphics-session ue_gpos_ftexcb_1 1
python3 $G --graphics-session ue_gpos_ftexct_1 1
# fragment NEAREST multi-texel + RGBA8_SRGB + CLAMP_TO_EDGE: same 4x4 CIS
# but format=43 (vkfmt->device id 3, ATTR srgb); W_TXD decodes RGB via
# APU_SRGB_TO_LIN, alpha stays UNORM, W_TXG0/G1 *1/65535 -> UNORM8 store
python3 $G --graphics-session ue_gpos_ftexs_1 1
# line-list draw: topology=1, vertexCount=2; gfx_line_coverage mirrors the
# RTL S_LN_* integer Bresenham (vxi>>>8 pixel coords, lerr=ldx-ldy) so the
# 1-px line footprint is bit-exact; fs_vcol keeps flat vertex-0 colour
python3 $G --graphics-session ue_gpos_line_1 1
# line-strip draw: topology=2, vertexCount=3; p_q steps by 1 so the
# rasterizer chains two Bresenhams (v0->v1, v1->v2); oracle unions the
# per-segment footprints
python3 $G --graphics-session ue_gpos_lstrip_1 1
# polygon-mode line: polygonMode=1 on the standard triangle; the le_q
# edge cursor walks the perimeter v0->v1->v2->v0 as three Bresenhams
# (runs before S_PR_AREA so no face culling); oracle unions the edges
python3 $G --graphics-session ue_gpos_polyln_1 1
# polygon-mode point: polygonMode=2; l0_w==l1_w so each vertex is a
# degenerate point->itself Bresenham = its pixel, plus the per-vertex
# FS-input re-fetch; oracle unions the three vertex pixels
python3 $G --graphics-session ue_gpos_polypnt_1 1

# deferred-work and capacity arms
python3 $G --compute-session ue_cpos_defer2_1  bufcopy_1 --variant defer2
# G3b-i: 4096 live vkCreateBuffer objects (ObjTab-V virtualization
# target); needs --objslots above the session's own entries
python3 $G --compute-session ue_cpos_maxconc_1 bufcopy_1 \
    --variant maxconc --objslots 8192

# 3d-d probe pair: must run LAST — it rewrites ue_sm5_transport with
# the device state carried over into ue_probe_bufcopy_1
python3 $G --probe-sessions ue_sm5_transport ue_probe_bufcopy_1 bufcopy_1

echo REGEN DONE
