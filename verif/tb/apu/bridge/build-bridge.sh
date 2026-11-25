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
# prod_opt path: the same repo PGO Verilator + shared codegen flags +
# simulator-PGO wrapper the vgtop/vgsys benches use.  apu_select_verilator
# resolves the content-addressed toolchain (the remote leaf supplies
# APU_VERILATOR_HOME) and, with APU_SIM_PGO=1, points VERILATOR at
# apu-verilator.sh so --build provisions a profile-use image.  This replaces
# the old stock-verilator -O2 build whose generated makefile defaulted to
# OPT_FAST=-Os (size-optimised, slow for the CTS/guest hot loops).
source "$ROOT/verif/tb/apu/local-verilator.sh"
apu_select_verilator
mkdir -p "$OUT"
apu_record_verilator

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

DBGDEF=()
if [ -n "${G6LC_APU_DBG_LOST:-}" ]; then DBGDEF=(-DG6LC_APU_DBG_LOST); fi
if [ -n "${G6LC_APU_DBG_TRACE:-}" ]; then DBGDEF+=(-DG6LC_APU_DEBUG); fi

build_one() { # name, extra-verilator-args
  local name="$1"; shift
  local mdir="$OUT/obj_$name"
  t0=$SECONDS
  mkdir -p "$mdir"
  # Stage the generated map headers inside this build's -Mdir and point -I
  # there.  The simulator-PGO request identity canonicalises paths under
  # -Mdir to @model@/*, so the key stays stable across per-run output dirs;
  # a plain -I$OUT would embed the unique leaf timestamp and force a full
  # PGO rebuild on every guest/CTS leaf.  ($OUT keeps its own copies for
  # bridge_selftest --map and the map.log audit below.)
  cp "$OUT/bridge_map.h" "$OUT/vn_map.svh" "$mdir/"
  if ! "$VERILATOR" --cc --exe --build --assert -j "${G6LC_BRIDGE_JOBS:-$(nproc)}" \
      "${APU_VERILATOR_FLAGS[@]}" \
      -CFLAGS "-I$mdir" --trace-fst \
      $WNO "${VLTS[@]}" "${DBGDEF[@]}" \
      -f "$ROOT/corev_apu/apu/Flist.apu_soc" \
      "$BR/tb_g6lc_apu_bridge.sv" "$BR/bridge_main.cpp" \
      --top-module tb_g6lc_apu_bridge "$@" \
      -Mdir "$mdir" -o apu_bridge \
      > "$OUT/build-$name.log" 2>&1; then
    echo "VERILATOR BUILD FAILED ($name)"
    tail -n 80 "$OUT/build-$name.log"
    exit 1
  fi
  echo "BUILD OK ($name) ${SECONDS}s -> $OUT/obj_$name/apu_bridge"
  echo "$SECONDS" >> "$OUT/times.log"
}

rm -f "$OUT/venus-only-build"
build_one venus    -GVenusOff=0
# APU_BRIDGE_VENUS_ONLY=1: a venus-only guest leaf never starts the
# venusoff control server; the marker tells the regression verdict.
if [ -n "${APU_BRIDGE_VENUS_ONLY:-}" ]; then
  echo "venusoff build not requested (venus-only)"
  touch "$OUT/venus-only-build"
else
  build_one venusoff -GVenusOff=1
fi

# idle-speed measurement
BENCH="${BENCH:-500000}"
t0=$SECONDS
"$OUT/obj_venus/apu_bridge" --bench "$BENCH" 2>&1 | tee "$OUT/bench.log"
echo "[build-bridge] done; binaries: $OUT/obj_{venus,venusoff}/apu_bridge"
