#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Mini-hart executes the separate apu_tgsi.hex image (not apu_fw.hex).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="${APU_VIRTIO_OUT:-/tmp/g6lc-apu-virtio-mmio}/tgsi-fw"
VERILATOR="${VERILATOR:-verilator}"
if ! command -v "$VERILATOR" >/dev/null 2>&1 && \
   [ -x /opt/testharness/toolchains/verilator-v5.008/bin/verilator ]; then
  VERILATOR=/opt/testharness/toolchains/verilator-v5.008/bin/verilator
fi
export CVA6_REPO_DIR="$ROOT"
mkdir -p "$OUT"
cp "$ROOT/verif/tb/apu/apu_tgsi.hex" "$OUT/apu_tgsi.hex"
"$VERILATOR" --binary --timing --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
  -Wno-WIDTHEXPAND -Wno-BLKSEQ -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
  -Wno-BLKANDNBLK -Wno-UNOPTFLAT -Wno-LITENDIAN \
  "$ROOT/verif/tb/apu/apu_axi.vlt" "$ROOT/verif/tb/apu/apu_exec.vlt" \
  -f "$ROOT/corev_apu/apu/Flist.apu_fw" \
  "$ROOT/vendor/pulp-platform/tech_cells_generic/src/rtl/tc_sram.sv" \
  "$ROOT/corev_apu/apu/g6lc_apu_fwram.sv" \
  "$ROOT/verif/tb/apu/g6lc_apu_lite_to_axi4.sv" \
  "$ROOT/verif/tb/apu/g6lc_apu_mini_hart.sv" \
  "$ROOT/verif/tb/apu/g6lc_apu_minihart_sys.sv" \
  "$ROOT/verif/tb/apu/tb_g6lc_apu_tgsi_fw.sv" --top-module tb_g6lc_apu_tgsi_fw \
  -Mdir "$OUT" -o tb_g6lc_apu_tgsi_fw 2>&1 | tee "$OUT/build.log"
"$OUT/tb_g6lc_apu_tgsi_fw" "+HEX=$ROOT/verif/tb/apu/apu_tgsi.hex" \
  2>&1 | tee "$OUT/sim.log"
