#!/usr/bin/env bash
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
# Build twin of run-apu-vgsys.sh; default PGO setup includes bounded training.
# Run one session: (cd verif/tb/apu && $OUT/sim/tb_g6lc_apu_vgsys +vec=<session>)
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
