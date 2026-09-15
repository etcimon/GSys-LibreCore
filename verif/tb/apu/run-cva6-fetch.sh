#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# One CVA6 fetches preloaded apu_fw.hex from g6lc_apu_fwram.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# stream8: DcacheIdWidth=3 covers NrLoadBufEntries=8. imafdc DcacheIdWidth=1
# fires load_unit.sv:745 at time 0.
export TARGET_CFG="${TARGET_CFG:-g6lc64_stream8}"
OUT="${APU_VIRTIO_OUT:-/tmp/g6lc-apu-virtio-mmio}/cva6_fetch_${TARGET_CFG}"
VERILATOR="${VERILATOR:-verilator}"
if ! command -v "$VERILATOR" >/dev/null 2>&1 && \
   [ -x /opt/testharness/toolchains/verilator-v5.008/bin/verilator ]; then
  VERILATOR=/opt/testharness/toolchains/verilator-v5.008/bin/verilator
fi
export CVA6_REPO_DIR="$ROOT"
export HPDCACHE_DIR="${HPDCACHE_DIR:-$ROOT/core/cache_subsystem/hpdcache}"
mkdir -p "$OUT"
cp "$ROOT/verif/tb/apu/apu_fw.hex" "$OUT/apu_fw.hex"
"$VERILATOR" --binary --timing --assert --unroll-count 256 -Wno-fatal \
  -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-BLKSEQ -Wno-SYNCASYNCNET \
  -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY -Wno-UNOPTFLAT -Wno-BLKANDNBLK \
  -Wno-CMPCONST -Wno-IMPLICIT -Wno-VARHIDDEN -Wno-LITENDIAN \
  -Wno-PINMISSING -Wno-CASEINCOMPLETE -Wno-UNSIGNED -Wno-style \
  "$ROOT/verif/tb/apu/apu_axi.vlt" "$ROOT/verilator_config.vlt" \
  -f "$ROOT/core/Flist.cva6" \
  +incdir+"$ROOT/corev_apu/include" \
  +incdir+"$ROOT/corev_apu/register_interface/include" \
  +incdir+"$ROOT/vendor/pulp-platform/register_interface/include" \
  "$ROOT/corev_apu/tb/ariane_axi_pkg.sv" \
  "$ROOT/corev_apu/include/g6lc_apu_cfg_pkg.sv" \
  "$ROOT/corev_apu/apu/include/g6lc_apu_bus_pkg.sv" \
  "$ROOT/corev_apu/src/ariane.sv" \
  "$ROOT/corev_apu/apu/g6lc_apu_fwram.sv" \
  "$ROOT/verif/tb/apu/tb_g6lc_apu_cva6_fetch.sv" \
  "$ROOT/verif/tb/apu/g6lc_dram_peek64_stub.cpp" \
  --top-module tb_g6lc_apu_cva6_fetch \
  -Mdir "$OUT" -o tb_g6lc_apu_cva6_fetch \
  2>&1 | tee "$OUT/build.log"
"$OUT/tb_g6lc_apu_cva6_fetch" "+APU_FW_HEX=$ROOT/verif/tb/apu/apu_fw.hex" \
  2>&1 | tee "$OUT/sim.log"
