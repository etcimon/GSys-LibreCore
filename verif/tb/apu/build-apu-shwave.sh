#!/usr/bin/env bash
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
# Build twin of run-apu-shwave.sh; default PGO setup includes bounded training.
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
source "$ROOT/verif/tb/apu/local-verilator.sh"
OUT="${APU_SHWAVE_OUT:-$APU_BUILD_CACHE/shwave}"
apu_select_verilator
YOSYS="${YOSYS:-yosys}"
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
mkdir -p "$OUT"
apu_record_verilator
VLTS=("$ROOT/verif/tb/apu/apu_axi.vlt"
      "$ROOT/verif/tb/apu/apu_exec.vlt")
vver="$("$VERILATOR" --version | grep -o '[0-9][0-9.]*' | head -1)"
# GENUNNAMED does not exist before Verilator 5.016; gate the waiver.
if awk -v v="$vver" 'BEGIN{split(v,a,"."); exit !(a[1]>5||(a[1]==5&&a[2]>=16))}'; then
  VLTS+=("$ROOT/verif/tb/apu/apu_vn.vlt")
fi
if ! "$VERILATOR" --binary --timing --assert -Wall -j "$APU_BUILD_JOBS" \
  "${APU_VERILATOR_FLAGS[@]}" \
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
