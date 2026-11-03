#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Engine completion queue (g6lc_apu_doneq): multi-source collisions +
# seeded random stream vs a reference FIFO; DONEQ_SYNTH=1 adds a yosys
# latch/check screen.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
export CVA6_REPO_DIR="$ROOT"
OUT="${APU_DONEQ_OUT:-/tmp/g6lc-apu-doneq}"
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
rm -rf "$OUT"
mkdir -p "$OUT"
if ! "$VERILATOR" --binary --timing --assert -Wall \
  -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-WIDTHEXPAND -Wno-BLKSEQ \
  -Wno-SYNCASYNCNET -Wno-DECLFILENAME \
  "$ROOT/corev_apu/apu/g6lc_apu_doneq.sv" \
  "$ROOT/verif/tb/apu/tb_g6lc_apu_doneq.sv" \
  --top-module tb_g6lc_apu_doneq \
  -Mdir "$OUT/sim" -o tb_g6lc_apu_doneq \
  > "$OUT/build.log" 2>&1; then
  echo "VERILATOR BUILD FAILED"
  tail -n 80 "$OUT/build.log"
  exit 1
fi
echo "VERILATOR BUILD OK"
set +e
stdbuf -o0 -e0 "$OUT/sim/tb_g6lc_apu_doneq" > "$OUT/sim.log" 2>&1
rc=$?
set -e
echo "SIM rc=$rc"
cat "$OUT/sim.log"
if ! grep -q '^PASS tb_g6lc_apu_doneq ' "$OUT/sim.log"; then
  echo "SIM FAILED"
  exit 1
fi
if [ "$rc" -ne 0 ]; then
  echo "SIM rc=$rc despite PASS"
  exit 1
fi
if [ "${DONEQ_SYNTH:-0}" != 1 ]; then
  exit 0
fi
yp="read_slang $ROOT/corev_apu/apu/g6lc_apu_doneq.sv --top g6lc_apu_doneq; hierarchy -top g6lc_apu_doneq; proc; opt; memory_collect; check -assert; synth -top g6lc_apu_doneq -noabc; check -assert; stat; select -assert-none t:\$dlatch t:\$_DLATCH_*"
if ! "$YOSYS" -Q -T -p "$yp" > "$OUT/synth.log" 2>&1; then
  echo "SYNTH FAILED"
  tail -n 40 "$OUT/synth.log"
  exit 1
fi
echo "SYNTH OK"
