#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# 3d-b stage 1: verilate the RTL bridge server — the real g6lc_apu_sys
# (ApuVenus, or ApuP1Transport in the venusoff binary) driven
# cycle-by-cycle from bridge_main.cpp, which serves the
# length-prefixed unix-socket protocol consumed by the QEMU bridge
# device and by bridge_selftest.py.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
export CVA6_REPO_DIR="$ROOT"
export TARGET_CFG="${TARGET_CFG:-g6lc64_stream8}"
OUT="${APU_BRIDGE_OUT:-/tmp/g6lc-apu-bridge}"
BR="$ROOT/verif/tb/apu/bridge"
VERILATOR="${VERILATOR:-verilator}"
# same pin as run-cva6-venus.sh / run-apu-sys-venus.sh: 5.008
if [ "$("$VERILATOR" --version 2>/dev/null | cut -d" " -f2)" != "5.008" ]; then
  for c in /opt/testharness/toolchains/verilator-v5.008/bin/verilator \
           /root/verilator-build/bin/verilator; do
    [ -x "$c" ] && { VERILATOR="$c"; break; }
  done
fi
case "$VERILATOR" in /root/verilator-build/*) export VERILATOR_ROOT=/root/verilator-build ;; esac
mkdir -p "$OUT"

# generated map — bridge_main.cpp consumes bridge_map.h (never typed)
CFG_PKG="$ROOT/core/include/${TARGET_CFG}_config_pkg.sv"
python3 "$ROOT/software/apu-venus-probe/tools/gen_venus_map.py" \
  "$OUT/bridge_map.h" "$OUT/vn_map.svh" "$CFG_PKG"
grep -E "VN_MMIO_BASE|VN_MMIO_LEN|VN_DMA_BASE|VN_SHM_BASE" \
  "$OUT/bridge_map.h" | tee "$OUT/map.log"

VLTS=("$ROOT/verif/tb/apu/apu_axi.vlt" "$ROOT/verif/tb/apu/apu_exec.vlt")
WNO="-Wall -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-WIDTHEXPAND \
-Wno-WIDTHTRUNC -Wno-BLKSEQ -Wno-SYNCASYNCNET -Wno-DECLFILENAME \
-Wno-PINCONNECTEMPTY -Wno-UNOPTFLAT -Wno-BLKANDNBLK -Wno-CMPCONST \
-Wno-IMPLICIT -Wno-VARHIDDEN -Wno-LITENDIAN -Wno-PINMISSING \
-Wno-CASEINCOMPLETE -Wno-UNSIGNED -Wno-style"

build_one() { # name, extra-verilator-args
  local name="$1"; shift
  t0=$SECONDS
  if ! "$VERILATOR" --cc --exe --build --assert -j "$(nproc)" \
      -O2 -CFLAGS "-O2 -I$OUT" --trace-fst \
      $WNO "${VLTS[@]}" \
      -f "$ROOT/corev_apu/apu/Flist.apu_soc" \
      "$BR/tb_g6lc_apu_bridge.sv" "$BR/bridge_main.cpp" \
      --top-module tb_g6lc_apu_bridge "$@" \
      -Mdir "$OUT/obj_$name" -o apu_bridge \
      > "$OUT/build-$name.log" 2>&1; then
    echo "VERILATOR BUILD FAILED ($name)"
    tail -n 80 "$OUT/build-$name.log"
    exit 1
  fi
  echo "BUILD OK ($name) ${SECONDS}s -> $OUT/obj_$name/apu_bridge"
  echo "$SECONDS" >> "$OUT/times.log"
}

build_one venus    -GVenusOff=0
build_one venusoff -GVenusOff=1

# idle-speed measurement
BENCH="${BENCH:-500000}"
t0=$SECONDS
"$OUT/obj_venus/apu_bridge" --bench "$BENCH" 2>&1 | tee "$OUT/bench.log"
echo "[build-bridge] done; binaries: $OUT/obj_{venus,venusoff}/apu_bridge"
