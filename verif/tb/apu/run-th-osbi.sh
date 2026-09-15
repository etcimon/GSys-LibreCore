#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Testharness G6LC_APU OpenSBI-visible 14-rule map + opt-in domain DTS.
# Not a full testharness OpenSBI firmware boot. TEX still rejected.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="${APU_VIRTIO_OUT:-/tmp/g6lc-apu-virtio-mmio}/th_osbi"
VERILATOR="${VERILATOR:-verilator}"
if ! command -v "$VERILATOR" >/dev/null 2>&1 && \
   [ -x /opt/testharness/toolchains/verilator-v5.008/bin/verilator ]; then
  VERILATOR=/opt/testharness/toolchains/verilator-v5.008/bin/verilator
fi
export CVA6_REPO_DIR="$ROOT"
mkdir -p "$OUT"
HOSTCC="${HOSTCC:-gcc}"
"$HOSTCC" -I"$ROOT/software/apu-fw/include" -o "$OUT/osbi_check" \
  "$ROOT/software/apu-fw/test/osbi_check.c"
"$OUT/osbi_check" "$ROOT" 2>&1 | tee "$OUT/osbi_check.log"
"$VERILATOR" --binary --timing --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
  -Wno-WIDTHEXPAND -Wno-BLKSEQ -Wno-SYNCASYNCNET -Wno-DECLFILENAME \
  -Wno-PINCONNECTEMPTY \
  "$ROOT/verif/tb/apu/apu_axi.vlt" \
  -f "$ROOT/corev_apu/apu/Flist.apu_soc" \
  "$ROOT/verif/tb/apu/tb_g6lc_apu_th_osbi.sv" \
  --top-module tb_g6lc_apu_th_osbi \
  -Mdir "$OUT" -o tb_g6lc_apu_th_osbi \
  2>&1 | tee "$OUT/build.log"
"$OUT/tb_g6lc_apu_th_osbi" 2>&1 | tee "$OUT/sim.log"
"$VERILATOR" --lint-only --timing --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
  -Wno-WIDTHEXPAND -Wno-BLKSEQ -Wno-SYNCASYNCNET -Wno-DECLFILENAME \
  -Wno-PINCONNECTEMPTY \
  "$ROOT/verif/tb/apu/apu_axi.vlt" -f "$ROOT/corev_apu/apu/Flist.apu_soc" \
  "$ROOT/verif/tb/apu/tb_g6lc_apu_th_osbi.sv" --top-module tb_g6lc_apu_th_osbi \
  2>&1 | tee "$OUT/lint.log"
if [[ "${APU_SYNTH:-1}" == 1 ]]; then
  YOSYS="${YOSYS:-/opt/testharness/toolchains/formal/bin/yosys}"
  for enabled in 0 1; do
    "$VERILATOR" --lint-only --timing --assert -Wall -Wno-TIMESCALEMOD \
      -Wno-UNUSED -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
      "$ROOT/verif/tb/apu/apu_axi.vlt" -f "$ROOT/corev_apu/apu/Flist.apu_soc" \
      "$ROOT/verif/tb/apu/tb_g6lc_apu_th_load.sv" \
      --top-module g6lc_apu_th_load_fixture \
      "-GEnable=1'b$enabled" -GRamBytes=4096 \
      2>&1 | tee "$OUT/lint-th_load-$enabled.log"
    "$YOSYS" -Q -T -p "read_slang -f $ROOT/corev_apu/apu/Flist.apu_soc $ROOT/verif/tb/apu/tb_g6lc_apu_th_load.sv --top g6lc_apu_th_load_fixture -GEnable=$enabled -GRamBytes=4096; hierarchy -top g6lc_apu_th_load_fixture; flatten; proc; opt; memory_collect; check -assert; stat; synth -top g6lc_apu_th_load_fixture -noabc; check -assert; stat; select -assert-none t:\$dlatch t:\$_DLATCH_*" \
      2>&1 | tee "$OUT/synth-th_load-$enabled.log"
  done
fi
