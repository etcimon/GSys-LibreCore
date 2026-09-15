#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Testharness compositor ExecEn mailbox bind. ApuHarness.ExecEn stays 0.
# Not OpenSBI, not TEX.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="${APU_VIRTIO_OUT:-/tmp/g6lc-apu-virtio-mmio}/th_exec"
VERILATOR="${VERILATOR:-verilator}"
if ! command -v "$VERILATOR" >/dev/null 2>&1 && \
   [ -x /opt/testharness/toolchains/verilator-v5.008/bin/verilator ]; then
  VERILATOR=/opt/testharness/toolchains/verilator-v5.008/bin/verilator
fi
export CVA6_REPO_DIR="$ROOT"
mkdir -p "$OUT"
"$VERILATOR" --binary --timing --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
  -Wno-WIDTHEXPAND -Wno-BLKSEQ -Wno-SYNCASYNCNET -Wno-DECLFILENAME \
  -Wno-PINCONNECTEMPTY -Wno-BLKANDNBLK -Wno-UNOPTFLAT -Wno-LITENDIAN \
  "$ROOT/verif/tb/apu/apu_axi.vlt" "$ROOT/verif/tb/apu/apu_exec.vlt" \
  -f "$ROOT/corev_apu/apu/Flist.apu_soc" \
  "$ROOT/verif/tb/apu/tb_g6lc_apu_th_exec.sv" \
  --top-module tb_g6lc_apu_th_exec \
  -Mdir "$OUT" -o tb_g6lc_apu_th_exec \
  2>&1 | tee "$OUT/build.log"
"$OUT/tb_g6lc_apu_th_exec" 2>&1 | tee "$OUT/sim.log"
if [[ "${APU_SYNTH:-1}" == 1 ]]; then
  YOSYS="${YOSYS:-/opt/testharness/toolchains/formal/bin/yosys}"
  for enabled in 0 1; do
    exec_en="$enabled"
    "$VERILATOR" --lint-only --timing --assert -Wall -Wno-TIMESCALEMOD \
      -Wno-UNUSED -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
      -Wno-BLKANDNBLK -Wno-UNOPTFLAT -Wno-LITENDIAN \
      "$ROOT/verif/tb/apu/apu_axi.vlt" "$ROOT/verif/tb/apu/apu_exec.vlt" \
      -f "$ROOT/corev_apu/apu/Flist.apu_soc" \
      "$ROOT/verif/tb/apu/tb_g6lc_apu_th_exec.sv" \
      --top-module g6lc_apu_th_exec_fixture \
      "-GEnable=1'b$enabled" "-GExecEn=1'b$exec_en" -GRamBytes=4096 \
      2>&1 | tee "$OUT/lint-$enabled.log"
    "$YOSYS" -Q -T -p "read_slang -f $ROOT/corev_apu/apu/Flist.apu_soc $ROOT/verif/tb/apu/tb_g6lc_apu_th_exec.sv --top g6lc_apu_th_exec_fixture -GEnable=$enabled -GExecEn=$exec_en -GRamBytes=4096; hierarchy -top g6lc_apu_th_exec_fixture; flatten; proc; opt; memory_collect; check -assert; stat; synth -top g6lc_apu_th_exec_fixture -noabc; check -assert; stat; select -assert-none t:\$dlatch t:\$_DLATCH_*" \
      2>&1 | tee "$OUT/synth-$enabled.log"
  done
fi
