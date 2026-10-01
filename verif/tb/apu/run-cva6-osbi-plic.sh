#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# CVA6 hart 0 at DRAM lo stores priority=1 to PLIC 0x0C000004 through the
# compositor. Hart 1 stays on firmware RAM. Stub PLIC, not a real interrupt
# controller, not L2, not a real OpenSBI ELF, not SMT2, not TEX.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
export TARGET_CFG="${TARGET_CFG:-g6lc64_stream8}"
OUT="${APU_VIRTIO_OUT:-/tmp/g6lc-apu-virtio-mmio}/cva6_osbi_plic_${TARGET_CFG}"
VERILATOR="${VERILATOR:-verilator}"
if ! command -v "$VERILATOR" >/dev/null 2>&1 && \
   [ -x /opt/testharness/toolchains/verilator-v5.008/bin/verilator ]; then
  VERILATOR=/opt/testharness/toolchains/verilator-v5.008/bin/verilator
fi
export CVA6_REPO_DIR="$ROOT"
export HPDCACHE_DIR="${HPDCACHE_DIR:-$ROOT/core/cache_subsystem/hpdcache}"
mkdir -p "$OUT"
HOSTCC="${HOSTCC:-gcc}"
"$HOSTCC" -I"$ROOT/software/apu-fw/include" -o "$OUT/osbi_check" \
  "$ROOT/software/apu-fw/test/osbi_check.c"
"$OUT/osbi_check" "$ROOT" 2>&1 | tee "$OUT/osbi_check.log"
cp "$ROOT/verif/tb/apu/apu_fw.hex" "$OUT/apu_fw.hex"
cp "$ROOT/verif/tb/apu/rom_spin.hex" "$OUT/rom_spin.hex"
cp "$ROOT/verif/tb/apu/osbi_plic.hex" "$OUT/osbi_plic.hex"
"$VERILATOR" --binary --timing --assert --unroll-count 256 -Wno-fatal \
  -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-BLKSEQ -Wno-SYNCASYNCNET \
  -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY -Wno-UNOPTFLAT -Wno-BLKANDNBLK \
  -Wno-CMPCONST -Wno-IMPLICIT -Wno-VARHIDDEN -Wno-LITENDIAN \
  -Wno-PINMISSING -Wno-CASEINCOMPLETE -Wno-UNSIGNED -Wno-style \
  "$ROOT/verif/tb/apu/apu_axi.vlt" "$ROOT/verilator_config.vlt" \
  -f "$ROOT/core/Flist.cva6" \
  +incdir+"$ROOT/corev_apu/include" \
  +incdir+"$ROOT/corev_apu/src" \
  +incdir+"$ROOT/corev_apu/apu/include" \
  +incdir+"$ROOT/corev_apu/register_interface/include" \
  +incdir+"$ROOT/vendor/pulp-platform/register_interface/include" \
  "$ROOT/corev_apu/tb/ariane_axi_pkg.sv" \
  "$ROOT/corev_apu/include/g6lc_apu_cfg_pkg.sv" \
  "$ROOT/corev_apu/apu/include/g6lc_apu_bus_pkg.sv" \
  "$ROOT/corev_apu/coherence/g6lc_coherence_pkg.sv" \
  "$ROOT/corev_apu/coherence/g6lc_inval_bus.sv" \
  "$ROOT/corev_apu/coherence/g6lc_snoop_filter.sv" \
  "$ROOT/corev_apu/coherence/g6lc_lr_sc_tracker.sv" \
  "$ROOT/corev_apu/coherence/g6lc_l1_inv_adapter.sv" \
  "$ROOT/corev_apu/coherence/g6lc_coherence_hub.sv" \
  "$ROOT/corev_apu/l3_cache/g6lc_server_prefetcher.sv" \
  "$ROOT/corev_apu/l3_cache/g6lc_l3_inclusive_inv.sv" \
  "$ROOT/corev_apu/src/ariane.sv" \
  "$ROOT/corev_apu/src/g6lc_cluster.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_enq_arb.sv" \
  "$ROOT/corev_apu/apu/g6lc_apu_fwram.sv" \
  "$ROOT/verif/tb/apu/tb_g6lc_apu_cva6_osbi_plic.sv" \
  "$ROOT/verif/tb/apu/g6lc_dram_peek64_stub.cpp" \
  --top-module tb_g6lc_apu_cva6_osbi_plic \
  -Mdir "$OUT" -o tb_g6lc_apu_cva6_osbi_plic \
  2>&1 | tee "$OUT/build.log"
( cd "$OUT" && ./tb_g6lc_apu_cva6_osbi_plic ) 2>&1 | tee "$OUT/sim.log"
if [[ "${APU_SYNTH:-1}" == 1 ]]; then
  YOSYS="${YOSYS:-/opt/testharness/toolchains/formal/bin/yosys}"
  for enabled in 0 1; do
    "$VERILATOR" --lint-only --timing --assert -Wall -Wno-TIMESCALEMOD \
      -Wno-UNUSED -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
      -Wno-WIDTHEXPAND -Wno-LITENDIAN \
      "$ROOT/verif/tb/apu/apu_axi.vlt" -f "$ROOT/corev_apu/apu/Flist.apu_soc" \
      "$ROOT/verif/tb/apu/tb_g6lc_apu_th_load.sv" \
      --top-module g6lc_apu_th_load_fixture \
      "-GEnable=1'b$enabled" -GRamBytes=4096 \
      2>&1 | tee "$OUT/lint-th_load-$enabled.log"
    "$YOSYS" -Q -T -p "read_slang -f $ROOT/corev_apu/apu/Flist.apu_soc $ROOT/verif/tb/apu/tb_g6lc_apu_th_load.sv --top g6lc_apu_th_load_fixture -GEnable=$enabled -GRamBytes=4096; hierarchy -top g6lc_apu_th_load_fixture; flatten; proc; opt; memory_collect; check -assert; stat; synth -top g6lc_apu_th_load_fixture -noabc; check -assert; stat; select -assert-none t:\$dlatch t:\$_DLATCH_*" \
      2>&1 | tee "$OUT/synth-th_load-$enabled.log"
  done
fi
