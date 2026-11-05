#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build-only twin of run-apu-vgsys.sh (generated prefix: keep in sync).
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
OUT="${APU_VGSYS_OUT:-/tmp/g6lc-apu-vgsys}"
VERILATOR="${VERILATOR:-verilator}"
YOSYS="${YOSYS:-yosys}"
if ! command -v "$VERILATOR" >/dev/null 2>&1 && \
   [ -x /opt/testharness/toolchains/verilator-v5.008/bin/verilator ]; then
  VERILATOR=/opt/testharness/toolchains/verilator-v5.008/bin/verilator
fi
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
