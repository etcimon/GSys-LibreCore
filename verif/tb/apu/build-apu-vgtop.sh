#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build-only twin of run-apu-vgtop.sh: elaborates tb_g6lc_apu_vgtop into
# $APU_VGTOP_OUT/sim (default /tmp/g6lc-apu-vgtop) without running any
# session, for single-vector local iteration:
#   bash verif/tb/apu/build-apu-vgtop.sh
#   (cd verif/tb/apu && $OUT/sim/tb_g6lc_apu_vgtop +vec=<session> [+eng_trace])
# Keep the flag set identical to run-apu-vgtop.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
export CVA6_REPO_DIR="$ROOT"
OUT="${APU_VGTOP_OUT:-/tmp/g6lc-apu-vgtop}"
VERILATOR="${VERILATOR:-verilator}"
if ! command -v "$VERILATOR" >/dev/null 2>&1 && \
   [ -x /opt/testharness/toolchains/verilator-v5.008/bin/verilator ]; then
  VERILATOR=/opt/testharness/toolchains/verilator-v5.008/bin/verilator
fi
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
