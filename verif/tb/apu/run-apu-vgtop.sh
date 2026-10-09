#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Venus transport session test (g6lc_apu_vgtop: vgctl + vnpump +
# vnfront + objtab + cmdrec + cmdexec) — Verilator sim replaying the
# generated guest-script tape; VGTOP_SYNTH=1 adds the yosys
# Enable=0/1 screens.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
export CVA6_REPO_DIR="$ROOT"
OUT="${APU_VGTOP_OUT:-/tmp/g6lc-apu-vgtop}"
VERILATOR="${VERILATOR:-verilator}"
YOSYS="${YOSYS:-yosys}"
if ! command -v "$VERILATOR" >/dev/null 2>&1 && \
   [ -x /opt/testharness/toolchains/verilator-v5.008/bin/verilator ]; then
  VERILATOR=/opt/testharness/toolchains/verilator-v5.008/bin/verilator
fi
if ! command -v "$YOSYS" >/dev/null 2>&1 && \
   [ -x /opt/testharness/toolchains/formal/bin/yosys ]; then
  YOSYS=/opt/testharness/toolchains/formal/bin/yosys
fi
if ! command -v "$YOSYS" >/dev/null 2>&1 && [ -x /usr/local/bin/yosys ]; then
  YOSYS=/usr/local/bin/yosys
fi
rm -rf "$OUT"
mkdir -p "$OUT"
# GENUNNAMED does not exist before Verilator 5.016; gate the waiver.
# apu_exec.vlt waives the vendored FPnew lint noise (ShaderCore is in
# the flist since §7b/5a-ii).
VLTS=("$ROOT/verif/tb/apu/apu_axi.vlt"
      "$ROOT/verif/tb/apu/apu_exec.vlt")
vver="$("$VERILATOR" --version | grep -o '[0-9][0-9.]*' | head -1)"
if awk -v v="$vver" 'BEGIN{split(v,a,"."); exit !(a[1]>5||(a[1]==5&&a[2]>=16))}'; then
  VLTS+=("$ROOT/verif/tb/apu/apu_vn.vlt")
fi
if ! "$VERILATOR" --binary --timing --assert -Wall \
  -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  -Wno-BLKSEQ \
  -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
  "${VLTS[@]}" \
  -f "$ROOT/corev_apu/apu/Flist.apu_vgtop" \
  "$ROOT/verif/tb/apu/tb_apu_mp_mem.sv" \
  "$ROOT/verif/tb/apu/tb_g6lc_apu_vgtop.sv" \
  --top-module tb_g6lc_apu_vgtop \
  -Mdir "$OUT/sim" -o tb_g6lc_apu_vgtop \
  > "$OUT/build.log" 2>&1; then
  echo "VERILATOR BUILD FAILED"
  tail -n 80 "$OUT/build.log"
  exit 1
fi
echo "VERILATOR BUILD OK"

# §6c-i mp gate: step 1 is the zero-jitter reference (lat 1, ready
# 100% — the old 1-cycle-port shape); step 2 randomizes request-grant
# and response latency (+mp_lat_min=1 +mp_lat_max=20
# +mp_ready_pct=60) and must produce identical result words.  Both
# steps run the transport session plus the 35-session compute arm.
# VGTOP_STEP=1|2 runs a single step; VGTOP_NOCOMPUTE=1 skips the arm.
SESSIONS="ue_cpos_arrlen_1 ue_cpos_bufcopy_1 ue_cpos_bufscale_1 \
ue_cpos_builtin_gid_1 ue_cpos_builtin_lid_1 \
ue_cpos_builtin_lindex_1 ue_cpos_compare_1 \
ue_cpos_composite_1 ue_cpos_intmix_1 ue_cpos_localsize32_1 \
ue_cpos_localsize64_1 ue_cpos_math450_1 ue_cpos_math450_2 \
ue_cpos_math450_3 ue_cpos_oob_1 ue_cpos_pushscale_1 \
ue_cpos_vec4arith_1 \
ue_cpos_loopfor_1 ue_cpos_barrier_reduce_1 \
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
ue_cpos_memsplit_1 ue_cneg_unbacked_1"

run_step() {
  local step="$1"; shift
  local mpa=("$@")
  echo "=== GATE STEP $step (${mpa[*]:-lat=1 ready=100%}) ==="
  set +e
  (cd "$ROOT/verif/tb/apu" && \
   stdbuf -o0 -e0 "$OUT/sim/tb_g6lc_apu_vgtop" "${mpa[@]}") \
    > "$OUT/sim-step$step.log" 2>&1
  rc=$?
  set -e
  echo "SIM step$step rc=$rc"
  cat "$OUT/sim-step$step.log"
  if ! grep -q '^PASS tb_g6lc_apu_vgtop ' "$OUT/sim-step$step.log"; then
    echo "SIM FAILED (step $step)"
    exit 1
  fi
  if [ "$rc" -ne 0 ]; then
    echo "SIM rc=$rc despite PASS (step $step)"
    exit 1
  fi
  if [ "${VGTOP_NOCOMPUTE:-0}" = 1 ]; then return 0; fi
  : > "$OUT/compute-step$step.log"
  local cfail=0
  for v in $SESSIONS; do
    set +e
    (cd "$ROOT/verif/tb/apu" && \
     stdbuf -o0 -e0 "$OUT/sim/tb_g6lc_apu_vgtop" +vec="$v" \
       "${mpa[@]}") \
      > "$OUT/compute-s$step-$v.log" 2>&1
    vrc=$?
    set -e
    grep -E '^(PASS-COMPUTE|PASS|FAIL)' "$OUT/compute-s$step-$v.log" \
      | sed "s/^/[s$step $v] /" | tee -a "$OUT/compute-step$step.log"
    if ! grep -q '^PASS tb_g6lc_apu_vgtop ' "$OUT/compute-s$step-$v.log" \
       || [ "$vrc" -ne 0 ]; then
      cfail=1
    fi
  done
  if [ "$cfail" -ne 0 ]; then
    echo "COMPUTE ARM FAILED (step $step)"
    exit 1
  fi
  echo "COMPUTE ARM OK step$step (39 sessions)"
}

# gate step 1: defaults (lat 1/1, ready 100%)
if [ "${VGTOP_STEP:-0}" != "2" ]; then
  run_step 1
fi
# gate step 2: randomized grant/latency, identical results
if [ "${VGTOP_STEP:-0}" != "1" ]; then
  run_step 2 +mp_lat_min=1 +mp_lat_max=20 +mp_ready_pct=60
fi
if [ "${VGTOP_SYNTH:-0}" != 1 ]; then
  exit 0
fi
for en in 0; do
  cat > "$OUT/vgtop-synth$en.ys" <<EOF
read_slang --unroll-limit 32768 -f $ROOT/corev_apu/apu/Flist.apu_vgtop --top g6lc_apu_vgtop_fixture -GEnable=$en
hierarchy -top g6lc_apu_vgtop_fixture
flatten
proc
opt
memory_collect
check -assert
stat
synth -top g6lc_apu_vgtop_fixture -noabc
check -assert
stat
select -assert-none t:\$dlatch t:\$_DLATCH_*
EOF
  if ! "$YOSYS" -Q -T "$OUT/vgtop-synth$en.ys" > "$OUT/synth-$en.log" 2>&1; then
    echo "SYNTH FAILED Enable=$en"
    tail -n 40 "$OUT/synth-$en.log"
    exit 1
  fi
  echo "SYNTH OK Enable=$en"
done
# §7b/5a-ii: vgtop at Enable=1 default geometry now includes the
# full-geometry ShaderCore (32 FPnew lanes + tables); the screen is
# skipped — the small screen below covers the logic.  Enable it via
# VGTOP_SYNTH_FULL=1 when needed.
if [ "${VGTOP_SYNTH_FULL:-0}" = 1 ]; then
  cat > "$OUT/vgtop-synth1.ys" <<EOF
read_slang --unroll-limit 32768 -f $ROOT/corev_apu/apu/Flist.apu_vgtop --top g6lc_apu_vgtop_fixture -GEnable=1
hierarchy -top g6lc_apu_vgtop_fixture
flatten
proc
opt
memory_collect
check -assert
stat
synth -top g6lc_apu_vgtop_fixture -noabc
check -assert
stat
select -assert-none t:\$dlatch t:\$_DLATCH_*
EOF
  if ! "$YOSYS" -Q -T "$OUT/vgtop-synth1.ys" > "$OUT/synth-1.log" 2>&1; then
    echo "SYNTH FAILED Enable=1"
    tail -n 40 "$OUT/synth-1.log"
    exit 1
  fi
  echo "SYNTH OK Enable=1"
else
  echo "SYNTH SKIPPED Enable=1 default geometry (ShaderCore; VGTOP_SYNTH_FULL=1 to run)"
fi
# §7b small screen: exposes logic apart from the ObjPay/CS/shader SRAMs
cat > "$OUT/vgtop-synth-small.ys" <<EOF
read_slang --unroll-limit 8192 -f $ROOT/corev_apu/apu/Flist.apu_vgtop --top g6lc_apu_vgtop_fixture -GEnable=1 -GRings=1 -GFences=4 -GPayWords=512 -GShaderRegs=16 -GMaxWaves=1 -GSlabBytes=1024 -GScratchBytes=64 -GShaderSlots=2 -GShaderIds=64 -GShaderWords=64 -GShaderMembers=16 -GShaderInit=8
hierarchy -top g6lc_apu_vgtop_fixture
flatten
proc
opt
memory_collect
check -assert
stat
synth -top g6lc_apu_vgtop_fixture -noabc
check -assert
stat
select -assert-none t:\$dlatch t:\$_DLATCH_*
EOF
if ! "$YOSYS" -Q -T "$OUT/vgtop-synth-small.ys" > "$OUT/synth-small.log" 2>&1; then
  echo "SYNTH FAILED Enable=1 Rings=1 Fences=4 PayWords=512"
  tail -n 40 "$OUT/synth-small.log"
  exit 1
fi
echo "SYNTH OK Enable=1 Rings=1 Fences=4 PayWords=512"
python3 - "$OUT" <<'PY'
import re, sys, pathlib
out = pathlib.Path(sys.argv[1])
ens = [0] + ([1] if (out / "synth-1.log").exists() else [])
for en in ens:
    text = pathlib.Path(f"{out}/synth-{en}.log").read_text(errors="replace")
    stats = re.split(r"\d+\. Printing statistics\.", text)
    gate = stats[-1]
    cells = re.search(r"Number of cells:\s+(\d+)", gate) or \
            re.search(r"^\s+(\d+) cells\b", gate, re.M)
    ffs = sum(int(n) for n, _ in
              re.findall(r"^\s+(\d+)\s+(\$_DFF\w*)", gate, re.M))
    print(f"Enable={en}: cells={cells.group(1) if cells else '?'} "
          f"ffs={ffs}")
text = pathlib.Path(f"{out}/synth-small.log").read_text(errors="replace")
gate = re.split(r"\d+\. Printing statistics\.", text)[-1]
cells = re.search(r"Number of cells:\s+(\d+)", gate) or \
        re.search(r"^\s+(\d+) cells\b", gate, re.M)
ffs = sum(int(n) for n, _ in
          re.findall(r"^\s+(\d+)\s+(\$_DFF\w*)", gate, re.M))
print(f"Enable=1 small: cells={cells.group(1) if cells else '?'} "
      f"ffs={ffs}")
PY
