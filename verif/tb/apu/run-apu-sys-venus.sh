#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# §6c-ii Venus SoC-facing system test (g6lc_apu_sys behind ApuVenus):
# the stock virtio-mmio/virtio-gpu probe register for register, then
# the vn_golden guest-script tapes through real split virtqueues with
# QUEUE_NOTIFY doorbells and INTERRUPT_STATUS/ACK completions; plus the
# dev_reset / q_reset / venusoff / worksink0 / legality arms.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
export CVA6_REPO_DIR="$ROOT"
OUT="${APU_SYSVENUS_OUT:-/tmp/g6lc-apu-sys-venus}"
VERILATOR="${VERILATOR:-verilator}"
if ! command -v "$VERILATOR" >/dev/null 2>&1 && \
   [ -x /opt/testharness/toolchains/verilator-v5.008/bin/verilator ]; then
  VERILATOR=/opt/testharness/toolchains/verilator-v5.008/bin/verilator
fi
rm -rf "$OUT"
mkdir -p "$OUT"
VLTS=("$ROOT/verif/tb/apu/apu_axi.vlt"
      "$ROOT/verif/tb/apu/apu_exec.vlt")
vver="$("$VERILATOR" --version | grep -o '[0-9][0-9.]*' | head -1)"
if awk -v v="$vver" 'BEGIN{split(v,a,"."); exit !(a[1]>5||(a[1]==5&&a[2]>=16))}'; then
  VLTS+=("$ROOT/verif/tb/apu/apu_vn.vlt")
fi
if ! "$VERILATOR" --binary --timing --assert -Wall -j "$(nproc)" \
  -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  -Wno-BLKSEQ \
  -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
  "${VLTS[@]}" \
  -f "$ROOT/corev_apu/apu/Flist.apu_soc" \
  "$ROOT/verif/tb/apu/tb_g6lc_apu_sys_venus.sv" \
  --top-module tb_g6lc_apu_sys_venus \
  -Mdir "$OUT/sim" -o tb_g6lc_apu_sys_venus \
  > "$OUT/build.log" 2>&1; then
  echo "VERILATOR BUILD FAILED"
  tail -n 80 "$OUT/build.log"
  exit 1
fi
echo "VERILATOR BUILD OK"

# transport tape + seven compute sessions (incl. the §5a Xfer copy)
# + four negative compute sessions (the full list lives in
# run-apu-vgsys.sh and is unchanged; these cover the SoC-seam path).
SESSIONS="ue_sm5_transport \
ue_cpos_bufcopy_1 ue_cpos_math450_1 ue_cpos_loopfor_1 \
ue_cpos_barrier_reduce_1 ue_cpos_oob_1 ue_cpos_loopfor_opt_1 \
ue_cpos_xfer_copy_1 \
ue_cneg_baddesc_1 ue_cneg_badmem_1 ue_cneg_badmod_1 \
ue_cneg_nopipe_1"
ARMS="dev_reset q_reset venusoff worksink0 legality"

cfail=0
: > "$OUT/sessions.log"
for v in $SESSIONS; do
  set +e
  (cd "$ROOT/verif/tb/apu" && \
   stdbuf -o0 -e0 "$OUT/sim/tb_g6lc_apu_sys_venus" +vec="$v") \
    > "$OUT/session-$v.log" 2>&1
  vrc=$?
  set -e
  grep -E '^(PASS-COMPUTE|PASS|FAIL)' "$OUT/session-$v.log" \
    | sed "s/^/[$v] /" | tee -a "$OUT/sessions.log"
  if ! grep -q '^PASS tb_g6lc_apu_sys_venus ' "$OUT/session-$v.log" \
     || [ "$vrc" -ne 0 ]; then
    cfail=1
  fi
done
: > "$OUT/arms.log"
for v in $ARMS; do
  set +e
  (cd "$ROOT/verif/tb/apu" && \
   stdbuf -o0 -e0 "$OUT/sim/tb_g6lc_apu_sys_venus" +vec="$v") \
    > "$OUT/arm-$v.log" 2>&1
  vrc=$?
  set -e
  grep -E '^(PASS-COMPUTE|PASS|FAIL)' "$OUT/arm-$v.log" \
    | sed "s/^/[$v] /" | tee -a "$OUT/arms.log"
  if ! grep -q '^PASS tb_g6lc_apu_sys_venus ' "$OUT/arm-$v.log" \
     || [ "$vrc" -ne 0 ]; then
    cfail=1
  fi
done
exit "$cfail"
