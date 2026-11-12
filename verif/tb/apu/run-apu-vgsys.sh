#!/usr/bin/env bash
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
# §6c-i Venus system test (g6lc_apu_vgsys: vqwalk + vgtop + apmem on one
# AXI4 master) — Verilator sim replaying the generated guest-script
# tapes through real split virtqueues, plus the §6c negative arms;
# VGSYS_SYNTH=1 adds the yosys Enable=0/1 screens.
# Vectors are generated — regenerate after a model/contract change with
#   bash verif/tb/apu/vn_vectors/regen_vectors.sh   (WSL python3)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
export CVA6_REPO_DIR="$ROOT"
source "$ROOT/verif/tb/apu/local-verilator.sh"
OUT="${APU_VGSYS_OUT:-$APU_BUILD_CACHE/vgsys}"
apu_select_verilator
YOSYS="${YOSYS:-yosys}"
if ! command -v "$YOSYS" >/dev/null 2>&1; then
  if [ -x /opt/testharness/toolchains/yosys-g6lc/bin/yosys ]; then
    YOSYS=/opt/testharness/toolchains/yosys-g6lc/bin/yosys
  elif [ -x /opt/testharness/toolchains/formal/bin/yosys ]; then
    YOSYS=/opt/testharness/toolchains/formal/bin/yosys
  fi
fi
if ! command -v "$YOSYS" >/dev/null 2>&1 && [ -x /usr/local/bin/yosys ]; then
  YOSYS=/usr/local/bin/yosys
fi
mkdir -p "$OUT"
apu_record_verilator
VLTS=("$ROOT/verif/tb/apu/apu_axi.vlt"
      "$ROOT/verif/tb/apu/apu_exec.vlt")
vver="$("$VERILATOR" --version | grep -o '[0-9][0-9.]*' | head -1)"
if awk -v v="$vver" 'BEGIN{split(v,a,"."); exit !(a[1]>5||(a[1]==5&&a[2]>=16))}'; then
  VLTS+=("$ROOT/verif/tb/apu/apu_vn.vlt")
fi
if ! "$VERILATOR" --binary --timing --assert -Wall -j "$APU_BUILD_JOBS" \
  "${APU_VERILATOR_FLAGS[@]}" \
  -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  -Wno-BLKSEQ \
  -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
  "${VLTS[@]}" \
  -f "$ROOT/corev_apu/apu/Flist.apu_vgsys" \
  "$ROOT/verif/tb/apu/tb_g6lc_apu_vgsys.sv" \
  --top-module tb_g6lc_apu_vgsys \
  -Mdir "$OUT/sim" -o tb_g6lc_apu_vgsys \
  > "$OUT/build.log" 2>&1; then
  echo "VERILATOR BUILD FAILED"
  tail -n 80 "$OUT/build.log"
  exit 1
fi
echo "VERILATOR BUILD OK"

SESSIONS="ue_sm5_transport \
ue_cpos_arrlen_1 ue_cpos_bufcopy_1 ue_cpos_bufscale_1 \
ue_cpos_builtin_gid_1 ue_cpos_builtin_lid_1 \
ue_cpos_builtin_lindex_1 ue_cpos_compare_1 \
ue_cpos_composite_1 ue_cpos_intmix_1 ue_cpos_localsize32_1 \
ue_cpos_localsize64_1 ue_cpos_localsize128_1 ue_cpos_math450_1 ue_cpos_math450_2 \
ue_cpos_math450_3 ue_cpos_oob_1 ue_cpos_pushscale_1 \
ue_cpos_vec4arith_1 \
ue_cpos_loopfor_1 ue_cpos_barrier_reduce_1 ue_cpos_barrier_reduce128_1 \
ue_cpos_loopfor_opt_1 ue_cpos_barrier_reduce_opt_1 \
ue_cpos_descarr_1 ue_cpos_multiset_1 ue_cpos_arroob_1 \
ue_cneg_badmod_1 ue_cneg_modgone_1 ue_cneg_lostbuf_1 \
ue_cneg_spec_1 ue_cneg_baddesc_1 ue_cneg_nopipe_1 \
ue_cneg_pgfull_1 ue_cneg_badmem_1 ue_cneg_bindoob_1 \
ue_cneg_descoob_1 ue_cneg_updoob_1 ue_cneg_layoutmix_1 \
ue_cneg_deadpool_1 ue_cneg_poolfull_1 \
ue_cpos_xfer_copy_1 ue_cpos_xfer_update_1 \
ue_cneg_xfer_oob_1 ue_cneg_xfer_overlap_1 \
ue_cpos_poolreset_1 ue_cpos_dslcompat_1 \
ue_cpos_memsplit_1 ue_cneg_unbacked_1 \
ue_cpos_texfetch_1 ue_cpos_texfetch_mip_1 ue_cpos_texarr_1 \
ue_cpos_texlod_lin_1 ue_cpos_texlod_mip_1 ue_cpos_texquery_1 \
ue_cpos_texsrgb_1 ue_cpos_imgloadstore_1 ue_cpos_imgatom_1 \
ue_cneg_texfetch_bad_1 ue_cneg_texlod_lin_bad_1 \
ue_cneg_imgloadstore_bad_1 ue_cneg_texquery_bad_1 \
ue_cneg_badfmt_1 ue_cneg_viewoob_1 ue_cneg_kindmix_1 \
ue_cneg_xfer_img_oob_1 ue_cneg_unnorm_1 \
ue_cpos_clear_rgba8_1 ue_cpos_clear_r32f_1 ue_cpos_clear_r32u_1 \
ue_cpos_clear_srgb_1 ue_cpos_clear_rgba16f_1 \
ue_cneg_clear_oob_1 ue_cpos_ctxkill_reuse_1 \
ue_cpos_rb_mapafter_1 ue_cpos_ubo_bindfirst_1 \
ue_cpos_evict_1 ue_cpos_reloc_hold_1 \
ue_cneg_evict_full_1 ue_cneg_bind_full_1 ue_cneg_stale_mem_1 ue_cneg_blit_scaled_1 ue_cpos_blit_id_1 ue_cpos_xfer_big_1 \
ue_cpos_dcopy_bufcopy_1 ue_cpos_dcopy_descarr_1 ue_cpos_dcopy_multiset_1 \
ue_gpos_tri_1 ue_gpos_vbwide_1 ue_gpos_statvp_1 ue_gpos_blend_1 ue_gpos_ptsrg8_1 ue_gpos_ptsrg8x_1 ue_gpos_ptsvidx_1 ue_gpos_fsubo_1 ue_gpos_fsubocopy_1 ue_gpos_inst_1 ue_gpos_vtex_1 ue_gpos_ftex_1 ue_gpos_ftexb_1 ue_gpos_ftexa_1 ue_gpos_ftexg_1 ue_gpos_ftexn_1 ue_gpos_ftexl_1 ue_gpos_ftexr_1 ue_gpos_ftexmir_1 ue_gpos_ftexc_1 ue_gpos_ftexc2_1 ue_gpos_ftexcb_1 ue_gpos_ftexct_1 ue_gpos_ftexs_1 ue_gpos_ftexls_1 ue_gpos_ftex_gath_1 ue_gpos_ftexh_1 ue_gpos_ftex_lod_1 ue_gpos_ftexi_1 ue_gpos_ftexq_1 ue_gpos_ftexpj_1 ue_gpos_ftexpi_1 ue_gpos_ftex_ary_1 ue_gpos_ftex_dref_1 ue_gpos_ftex_dri_1 ue_gpos_ftex_dpi_1 ue_gpos_ftex_dg_1 ue_gpos_ftex_dpe_1 ue_gpos_ftexfetch_1 ue_gpos_ftex_u32_1 ue_gpos_ftex_rgba32_1 ue_gpos_ftex_bias_1 ue_gpos_mrt_1 ue_gpos_mrtb_1 ue_gpos_mrt3_1 ue_gpos_mrt4_1 ue_gpos_mrt4depth_1 ue_gpos_mrtlop_1 ue_gpos_mrt3lop_1 ue_gpos_mrt4lop_1 ue_gpos_stencil_1 ue_gpos_stencil_df_1 ue_gpos_stencil_f_1 ue_gpos_stencil_inv_1 ue_gpos_stencil_clr_1 ue_gpos_stencil_msk_1 ue_gpos_secnd_1 ue_gpos_msub_1 ue_gpos_kill_1 ue_gpos_killfn_1 ue_gpos_fncall_1 ue_gpos_line_1 ue_gpos_lstrip_1 ue_gpos_polyln_1 ue_gpos_polypnt_1 ue_gpos_depth_1 ue_gpos_dtest_1 ue_gpos_dtoff_1 ue_gpos_dgreat_1 ue_gpos_dgtoff_1 ue_gpos_deq_1 ue_gpos_deqoff_1 ue_gpos_dne_1 ue_gpos_dneoff_1 ue_gpos_dleq_1 ue_gpos_dleqoff_1 ue_gpos_dgeq_1 ue_gpos_dgeqoff_1 ue_gpos_dalw_1 ue_gpos_dalwoff_1 ue_gpos_dnever_1 ue_gpos_dneveroff_1 ue_gpos_scis_1 ue_gpos_scio_1 ue_gpos_rdiscard_1 ue_gpos_dbnd_1 ue_gpos_dbndoff_1 ue_gpos_dbias_1 ue_gpos_dw0_1 ue_gpos_grad_1 ue_gpos_fcolor_1 ue_gpos_deriv_1 ue_gpos_deriv2_1 ue_gpos_demdrv_1 ue_gpos_persp_1 ue_gpos_lopx_1 ue_gpos_lopor_1 ue_gpos_lopset_1 ue_gpos_lopand_1 ue_gpos_lopinvert_1 ue_gpos_lopnor_1 ue_gpos_lopnand_1 ue_gpos_lopandrev_1 ue_gpos_lopcopy_1 ue_gpos_lopandinv_1 ue_gpos_lopnoop_1 ue_gpos_lopequiv_1 ue_gpos_loporrev_1 ue_gpos_lopinv2_1 ue_gpos_loporinv_1 ue_gpos_lopclear_1 ue_gpos_dclamp_1 ue_gpos_dclampoff_1 ue_gpos_bopadd_1 ue_gpos_bopsub_1 ue_gpos_boprsub_1 ue_gpos_bopmin_1 ue_gpos_bopmax_1 ue_gpos_bfacdst_1 ue_gpos_bfacsrc_1 ue_gpos_bfacdc_1 ue_gpos_bfacsc_1 ue_gpos_bfomsc_1 ue_gpos_bfacal_1 ue_gpos_bfomdc_1 ue_gpos_bfomsa_1 ue_gpos_bfomda_1 ue_gpos_bfzero_1 ue_gpos_bfacsat_1 ue_gpos_bfaccc_1 ue_gpos_bfac1mcc_1 ue_gpos_cwm_1 ue_gpos_bloff_1 \
ue_cpos_maxconc_1 ue_cpos_defer2_1 \
ue_cpos_modres_1 ue_cpos_rerec_1 \
ue_cpos_zerodisp_1 ue_cpos_shared1_1 ue_cpos_atomic1_1 \
ue_cpos_arrlen1_1 ue_cpos_ctsb2b_1 \
ue_cpos_dispind_1 ue_cpos_dispbase_1 ue_cpos_exec2nd_1 \
ue_cpos_events_1 ue_gpos_drawind_1 ue_gpos_drawindx_1 \
ue_cpos_recmany_1 ue_cpos_allocmany_1 ue_cpos_cbpoolreset_1 \
ue_cpos_xstreams_1 ue_cpos_submit101_1"
# G3b-i: the *full* negatives also run on a small-geometry build of
# the same RTL (ObjEntries=256, 256 KiB PayMem) so the FULL paths
# stay covered while the default geometry is the big one
SMALL_SESSIONS="ue_cneg_bind_full_1 ue_cneg_evict_full_1"
SMALL_OBJ=256
SMALL_PAY=262144
NEGATIVES="neg_next_loop neg_desc_oob neg_buf_oob neg_aperture \
neg_used_oob neg_reset neg_cursor neg_batch neg_flush neg_qdrop \
neg_drainkick neg_resp_oob neg_worksink0 epoch_reuse"

cfail=0
: > "$OUT/sessions.log"
for v in $SESSIONS; do
  set +e
  (cd "$ROOT/verif/tb/apu" && \
   stdbuf -o0 -e0 "$OUT/sim/tb_g6lc_apu_vgsys" +vec="$v") \
    > "$OUT/session-$v.log" 2>&1
  vrc=$?
  set -e
  grep -E '^(PASS-COMPUTE|PASS|FAIL)' "$OUT/session-$v.log" \
    | sed "s/^/[$v] /" | tee -a "$OUT/sessions.log"
  if ! grep -q '^PASS tb_g6lc_apu_vgsys ' "$OUT/session-$v.log" \
     || [ "$vrc" -ne 0 ]; then
    cfail=1
  fi
done
if [ "$cfail" -ne 0 ]; then
  echo "SESSIONS FAILED"
  exit 1
fi
echo "SESSIONS OK (40 incl. transport)"

if [ "${VGSYS_NONEG:-0}" != 1 ]; then
  : > "$OUT/negatives.log"
  nfail=0
  for v in $NEGATIVES; do
    set +e
    (cd "$ROOT/verif/tb/apu" && \
     stdbuf -o0 -e0 "$OUT/sim/tb_g6lc_apu_vgsys" +vec="$v") \
      > "$OUT/neg-$v.log" 2>&1
    vrc=$?
    set -e
    grep -E '^(PASS|FAIL)' "$OUT/neg-$v.log" \
      | sed "s/^/[$v] /" | tee -a "$OUT/negatives.log"
    if ! grep -q '^PASS tb_g6lc_apu_vgsys ' "$OUT/neg-$v.log" \
       || [ "$vrc" -ne 0 ]; then
      nfail=1
    fi
  done
  if [ "$nfail" -ne 0 ]; then
    echo "NEGATIVE ARMS FAILED"
    exit 1
  fi
  echo "NEGATIVE ARMS OK (11 arms)"
fi

# ---- G3b-i small-geometry arm -------------------------------------------
# Same RTL at ObjEntries=256 / 256 KiB PayMem so the *full* negatives
# exercise the FULL paths on a small table while the default stays big.
if [ "${VGSYS_SMALL:-1}" = 1 ]; then
  if ! "$VERILATOR" --binary --timing --assert -Wall -j "$(nproc)" \
    -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
    -Wno-BLKSEQ \
    -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
    "${VLTS[@]}" \
    -f "$ROOT/corev_apu/apu/Flist.apu_vgsys" \
    "$ROOT/verif/tb/apu/tb_g6lc_apu_vgsys.sv" \
    --top-module tb_g6lc_apu_vgsys \
    -GObjEntries="$SMALL_OBJ" -GPayMemBytes="$SMALL_PAY" \
    -Mdir "$OUT/sim-small" -o tb_g6lc_apu_vgsys \
    > "$OUT/build-small.log" 2>&1; then
    echo "VERILATOR BUILD FAILED (small)"
    tail -n 80 "$OUT/build-small.log"
    exit 1
  fi
  echo "VERILATOR BUILD OK (small ObjEntries=$SMALL_OBJ PayMemBytes=$SMALL_PAY)"
  sfail=0
  for v in $SMALL_SESSIONS; do
    set +e
    (cd "$ROOT/verif/tb/apu" && \
     stdbuf -o0 -e0 "$OUT/sim-small/tb_g6lc_apu_vgsys" +vec="$v") \
      > "$OUT/small-$v.log" 2>&1
    vrc=$?
    set -e
    grep -E '^(PASS|FAIL)' "$OUT/small-$v.log" \
      | sed "s/^/[small $v] /"
    if ! grep -q '^PASS tb_g6lc_apu_vgsys ' "$OUT/small-$v.log" \
       || [ "$vrc" -ne 0 ]; then
      sfail=1
    fi
  done
  if [ "$sfail" -ne 0 ]; then
    echo "SMALL-GEOMETRY ARMS FAILED"
    exit 1
  fi
  echo "SMALL-GEOMETRY ARMS OK"
fi

if [ "${VGSYS_SYNTH:-0}" != 1 ]; then
  exit 0
fi
cat > "$OUT/vgsys-synth0.ys" <<EOF
read_slang --unroll-limit 32768 -f $ROOT/corev_apu/apu/Flist.apu_vgsys --top g6lc_apu_vgsys_fixture -GEnable=0
hierarchy -top g6lc_apu_vgsys_fixture
flatten
proc
opt
memory_collect
check -assert
stat
synth -top g6lc_apu_vgsys_fixture -noabc
check -assert
stat
select -assert-none t:\$dlatch t:\$_DLATCH_*
EOF
if ! "$YOSYS" -Q -T "$OUT/vgsys-synth0.ys" > "$OUT/synth-0.log" 2>&1; then
  echo "SYNTH FAILED Enable=0"
  tail -n 40 "$OUT/synth-0.log"
  exit 1
fi
echo "SYNTH OK Enable=0"
# small screen (same -G set as the vgtop screen); the default-geometry
# ShaderCore screen is skipped as in run-apu-vgtop.sh
cat > "$OUT/vgsys-synth-small.ys" <<EOF
read_slang --unroll-limit 8192 -f $ROOT/corev_apu/apu/Flist.apu_vgsys --top g6lc_apu_vgsys_fixture -GEnable=1 -GRings=1 -GFences=4 -GPayWords=512 -GShaderRegs=16 -GMaxWaves=1 -GSlabBytes=1024 -GScratchBytes=64 -GShaderSlots=2 -GShaderIds=64 -GShaderWords=64 -GShaderMembers=16 -GShaderInit=8 -GObjEntries=256 -GPayMemBytes=16384
hierarchy -top g6lc_apu_vgsys_fixture
flatten
proc
opt
memory_collect
check -assert
stat
synth -top g6lc_apu_vgsys_fixture -noabc
check -assert
stat
select -assert-none t:\$dlatch t:\$_DLATCH_*
EOF
if ! "$YOSYS" -Q -T "$OUT/vgsys-synth-small.ys" \
   > "$OUT/synth-small.log" 2>&1; then
  echo "SYNTH FAILED Enable=1 small"
  tail -n 40 "$OUT/synth-small.log"
  exit 1
fi
echo "SYNTH OK Enable=1 small"
python3 - "$OUT" <<'PY'
import re, sys, pathlib
out = pathlib.Path(sys.argv[1])
for name in ("synth-0", "synth-small"):
    text = pathlib.Path(f"{out}/{name}.log").read_text(errors="replace")
    gate = re.split(r"\d+\. Printing statistics\.", text)[-1]
    cells = re.search(r"Number of cells:\s+(\d+)", gate) or \
            re.search(r"^\s+(\d+) cells\b", gate, re.M)
    ffs = sum(int(n) for n, _ in
              re.findall(r"^\s+(\d+)\s+(\$_DFF\w*)", gate, re.M))
    print(f"{name}: cells={cells.group(1) if cells else '?'} ffs={ffs}")
PY
