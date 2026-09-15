#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# APU DMA initiator through compositor DRAM-hole map (DRAM lo, not fw RAM).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="${APU_VIRTIO_OUT:-/tmp/g6lc-apu-virtio-mmio}/dma_init"
VERILATOR="${VERILATOR:-verilator}"
if ! command -v "$VERILATOR" >/dev/null 2>&1 && \
   [ -x /opt/testharness/toolchains/verilator-v5.008/bin/verilator ]; then
  VERILATOR=/opt/testharness/toolchains/verilator-v5.008/bin/verilator
fi
export CVA6_REPO_DIR="$ROOT"
mkdir -p "$OUT"
cp "$ROOT/verif/tb/apu/dram_dma.hex" "$OUT/dram_dma.hex"
"$VERILATOR" --binary --timing --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
  -Wno-WIDTHEXPAND -Wno-BLKSEQ -Wno-SYNCASYNCNET -Wno-DECLFILENAME \
  -Wno-PINCONNECTEMPTY \
  "$ROOT/verif/tb/apu/apu_axi.vlt" \
  -f "$ROOT/corev_apu/apu/Flist.apu_axi" \
  "$ROOT/vendor/pulp-platform/tech_cells_generic/src/rtl/tc_sram.sv" \
  "$ROOT/corev_apu/apu/g6lc_apu_fwram.sv" \
  "$ROOT/verif/tb/apu/tb_g6lc_apu_dma_init.sv" \
  --top-module tb_g6lc_apu_dma_init \
  -Mdir "$OUT" -o tb_g6lc_apu_dma_init \
  2>&1 | tee "$OUT/build.log"
( cd "$OUT" && ./tb_g6lc_apu_dma_init ) 2>&1 | tee "$OUT/sim.log"
