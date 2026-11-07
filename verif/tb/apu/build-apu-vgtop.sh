#!/usr/bin/env bash
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
# Build twin of run-apu-vgtop.sh: elaborates tb_g6lc_apu_vgtop into
# $APU_VGTOP_OUT/sim (default ~/.cache/librecore/apu/vgtop). PGO setup runs
# bounded training sessions, not validation; then one vector can be run:
#   bash verif/tb/apu/build-apu-vgtop.sh
#   (cd verif/tb/apu && $OUT/sim/tb_g6lc_apu_vgtop +vec=<session> [+eng_trace])
# Keep the flag set identical to run-apu-vgtop.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
export CVA6_REPO_DIR="$ROOT"
source "$ROOT/verif/tb/apu/local-verilator.sh"
OUT="${APU_VGTOP_OUT:-$APU_BUILD_CACHE/vgtop}"
apu_select_verilator
mkdir -p "$OUT"
apu_record_verilator
debug_flags=()
if [[ "${APU_DEBUG_LOST:-0}" == 1 ]]; then
  debug_flags+=(-DG6LC_APU_DBG_LOST)
fi
printf 'debug_lost=%s\n' "${APU_DEBUG_LOST:-0}" >> "$OUT/toolchain.txt"
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
  "${debug_flags[@]}" \
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
