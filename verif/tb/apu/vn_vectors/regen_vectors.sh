#!/usr/bin/env bash
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
python3 $G --compute-session ue_cpos_xfer_update_1 bufcopy_1 --variant xfer_update
# §12.3 D/C new positives
python3 $G --compute-session ue_cpos_dslcompat_1 bufcopy_1 --variant dslcompat
python3 $G --compute-session ue_cpos_memsplit_1  bufcopy_1 --variant memsplit
python3 $G --compute-session ue_cpos_poolreset_1 bufcopy_1 --variant poolreset

# negatives
python3 $G --compute-session ue_cneg_badmod_1 bufcopy_bad_0
for var in modgone lostbuf spec baddesc nopipe pgfull badmem bindoob \
           descoob updoob layoutmix deadpool poolfull xfer_oob \
           xfer_overlap unbacked; do
  python3 $G --compute-session ue_cneg_${var}_1 bufcopy_1 --variant $var
done

python3 $G --compute-session ue_ws0_bufcopy_1 bufcopy_1 --variant worksink

# §12.3 C/5b image sessions + negatives (descriptor records change)
for v in texfetch_1 texfetch_2 texfetch_3 \
         texfetch_mip_1 texfetch_mip_2 texfetch_mip_3 \
         texarr_1 texarr_2 texarr_3 \
         texlod_lin_1 texlod_lin_2 texlod_lin_3 \
         texlod_mip_1 texlod_mip_2 texlod_mip_3 \
         texquery_1 texquery_2 texquery_3 \
         texsrgb_1 texsrgb_2 texsrgb_3 \
         imgloadstore_1 imgloadstore_2 imgloadstore_3; do
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
# ExecuteCommandStreams cursor: ONE record, streamCount=9 (over the
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
