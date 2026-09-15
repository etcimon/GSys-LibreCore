#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Iterate the firmware RAM TB without the rest of APU_SOC.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="${APU_VIRTIO_OUT:-/tmp/g6lc-apu-virtio-mmio}/fwram"
VERILATOR="${VERILATOR:-verilator}"
if ! command -v "$VERILATOR" >/dev/null 2>&1 && \
   [ -x /opt/testharness/toolchains/verilator-v5.008/bin/verilator ]; then
  VERILATOR=/opt/testharness/toolchains/verilator-v5.008/bin/verilator
fi
export CVA6_REPO_DIR="$ROOT"
mkdir -p "$OUT"
cp "$ROOT/verif/tb/apu/apu_fw.hex" "$OUT/apu_fw.hex"
"$VERILATOR" --binary --timing --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
  -Wno-WIDTHEXPAND -Wno-BLKSEQ -Wno-SYNCASYNCNET -Wno-DECLFILENAME \
  -Wno-PINCONNECTEMPTY -Wno-LITENDIAN \
  "$ROOT/verif/tb/apu/apu_axi.vlt" -f "$ROOT/corev_apu/apu/Flist.apu_soc" \
  "$ROOT/verif/tb/apu/tb_g6lc_apu_fwram.sv" --top-module tb_g6lc_apu_fwram \
  -Mdir "$OUT" -o tb_g6lc_apu_fwram 2>&1 | tee "$OUT/build.log"
"$OUT/tb_g6lc_apu_fwram" "+HEX=$ROOT/verif/tb/apu/apu_fw.hex" \
  2>&1 | tee "$OUT/sim.log"
