#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build-only twin of run-apu-shwave.sh (generated prefix: keep in sync).
# Run one case: $OUT/sim/tb_g6lc_apu_shwave +shv=<repo>/verif/tb/apu/sh_vectors +only=<name>[,<name>]
# ShaderCore wave engine (g6lc_apu_shwave via g6lc_apu_shcore) —
# corpus dispatch vectors against the lavapipe oracle.
# SHWAVE_SYNTH=1 adds the yosys Enable=0/1 screens (Enable=0 must
# be empty; Enable=1 small screen -GShaderRegs=16 -GMaxWaves=1
# -GSlabBytes=1024 -GScratchBytes=64 so logic is visible apart from
# the SRAMs and scratch flops; the default geometry screen is
# best-effort via SHWAVE_SYNTH_FULL=1).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
export CVA6_REPO_DIR="$ROOT"
OUT="${APU_SHWAVE_OUT:-/tmp/g6lc-apu-shwave}"
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
# GENUNNAMED does not exist before Verilator 5.016; gate the waiver.
if awk -v v="$vver" 'BEGIN{split(v,a,"."); exit !(a[1]>5||(a[1]==5&&a[2]>=16))}'; then
  VLTS+=("$ROOT/verif/tb/apu/apu_vn.vlt")
fi
if ! "$VERILATOR" --binary --timing --assert -Wall \
  -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  -Wno-BLKSEQ -Wno-SYNCASYNCNET -Wno-DECLFILENAME \
  -Wno-PINCONNECTEMPTY \
  "${VLTS[@]}" \
  -f "$ROOT/corev_apu/apu/Flist.apu_shcore" \
  "$ROOT/vendor/pulp-platform/tech_cells_generic/src/rtl/tc_sram.sv" \
  "$ROOT/verif/tb/apu/tb_g6lc_apu_shwave.sv" \
  --top-module tb_g6lc_apu_shwave \
  -Mdir "$OUT/sim" -o tb_g6lc_apu_shwave \
  > "$OUT/build.log" 2>&1; then
  echo "VERILATOR BUILD FAILED"
  tail -n 80 "$OUT/build.log"
  exit 1
fi
echo "VERILATOR BUILD OK"
