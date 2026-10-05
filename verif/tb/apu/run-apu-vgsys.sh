#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# §6c-i Venus system test (g6lc_apu_vgsys: vqwalk + vgtop + apmem on one
# AXI4 master) — Verilator sim replaying the generated guest-script
# tapes through real split virtqueues, plus the §6c negative arms;
# VGSYS_SYNTH=1 adds the yosys Enable=0/1 screens.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
export CVA6_REPO_DIR="$ROOT"
OUT="${APU_VGSYS_OUT:-/tmp/g6lc-apu-vgsys}"
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
ue_cpos_localsize64_1 ue_cpos_math450_1 ue_cpos_math450_2 \
ue_cpos_math450_3 ue_cpos_oob_1 ue_cpos_pushscale_1 \
ue_cpos_vec4arith_1 \
ue_cpos_loopfor_1 ue_cpos_barrier_reduce_1 \
ue_cpos_loopfor_opt_1 ue_cpos_barrier_reduce_opt_1 \
ue_cneg_badmod_1 ue_cneg_modgone_1 ue_cneg_lostbuf_1 \
ue_cneg_spec_1 ue_cneg_baddesc_1 ue_cneg_nopipe_1 \
ue_cneg_pgfull_1 ue_cneg_badmem_1 ue_cneg_bindoob_1 \
ue_cneg_descoob_1"
NEGATIVES="neg_next_loop neg_desc_oob neg_buf_oob neg_aperture \
neg_used_oob neg_reset neg_cursor neg_batch neg_flush neg_qdrop \
neg_resp_oob"

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
echo "SESSIONS OK (32 incl. transport)"

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
read_slang --unroll-limit 8192 -f $ROOT/corev_apu/apu/Flist.apu_vgsys --top g6lc_apu_vgsys_fixture -GEnable=1 -GRings=1 -GFences=4 -GPayWords=512 -GShaderRegs=16 -GMaxWaves=1 -GSlabBytes=1024 -GScratchBytes=64 -GShaderSlots=2 -GShaderIds=64 -GShaderWords=64 -GShaderMembers=16 -GShaderInit=8
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
