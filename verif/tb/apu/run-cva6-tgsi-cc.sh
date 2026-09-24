#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# CVA6 hart 1 runs apu_tgsi_cc.hex (resident TGSI compile + MOV job) to
# cookie 0x600D000B through compositor th_load gen_exec. Not apu_fw.elf.
# TEX still rejected. ApuHarness.ExecEn stays 0.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
export TARGET_CFG="${TARGET_CFG:-g6lc64_stream8}"
OUT="${APU_VIRTIO_OUT:-/tmp/g6lc-apu-virtio-mmio}/cva6_tgsi_cc_${TARGET_CFG}"
VERILATOR="${VERILATOR:-verilator}"
if ! command -v "$VERILATOR" >/dev/null 2>&1 && \
   [ -x /opt/testharness/toolchains/verilator-v5.008/bin/verilator ]; then
  VERILATOR=/opt/testharness/toolchains/verilator-v5.008/bin/verilator
fi
export CVA6_REPO_DIR="$ROOT"
export HPDCACHE_DIR="${HPDCACHE_DIR:-$ROOT/core/cache_subsystem/hpdcache}"
mkdir -p "$OUT"
make -C "$ROOT/software/apu-fw" tgsi-fw-check
if [[ "${SKIP_FW_REBUILD:-0}" != 1 ]]; then
  CROSS=""
  if command -v riscv-none-elf-gcc >/dev/null 2>&1; then CROSS=riscv-none-elf-
  elif command -v riscv64-unknown-elf-gcc >/dev/null 2>&1; then CROSS=riscv64-unknown-elf-
  elif [ -x /opt/testharness/toolchains/xpack-riscv-none-elf-gcc-14.2.0-3/bin/riscv-none-elf-gcc ]; then
    CROSS=/opt/testharness/toolchains/xpack-riscv-none-elf-gcc-14.2.0-3/bin/riscv-none-elf-
  elif [ -x /opt/testharness/toolchains/riscv-none-elf-gcc/bin/riscv-none-elf-gcc ]; then
    CROSS=/opt/testharness/toolchains/riscv-none-elf-gcc/bin/riscv-none-elf-
  fi
  if [[ -z "$CROSS" ]]; then
    echo "FAIL no RISC-V gcc for firmware-tgsi-cc"
    exit 1
  fi
  make -C "$ROOT/software/apu-fw" firmware-tgsi-cc CROSS_COMPILE="$CROSS"
fi
cp "$ROOT/verif/tb/apu/apu_tgsi_cc.hex" "$OUT/apu_tgsi_cc.hex"
cp "$ROOT/verif/tb/apu/rom_spin.hex" "$OUT/rom_spin.hex"
"$VERILATOR" --binary --timing --assert --unroll-count 256 -Wno-fatal \
  -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-BLKSEQ -Wno-SYNCASYNCNET \
  -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY -Wno-UNOPTFLAT -Wno-BLKANDNBLK \
  -Wno-CMPCONST -Wno-IMPLICIT -Wno-VARHIDDEN -Wno-LITENDIAN \
  -Wno-PINMISSING -Wno-CASEINCOMPLETE -Wno-UNSIGNED -Wno-style \
  "$ROOT/verif/tb/apu/apu_axi.vlt" "$ROOT/verif/tb/apu/apu_exec.vlt" \
  "$ROOT/verilator_config.vlt" \
  -f "$ROOT/core/Flist.cva6" \
  +incdir+"$ROOT/corev_apu/include" \
  +incdir+"$ROOT/corev_apu/src" \
  +incdir+"$ROOT/corev_apu/apu/include" \
  +incdir+"$ROOT/corev_apu/register_interface/include" \
  +incdir+"$ROOT/vendor/pulp-platform/register_interface/include" \
  "$ROOT/corev_apu/tb/ariane_axi_pkg.sv" \
  "$ROOT/corev_apu/include/g6lc_apu_cfg_pkg.sv" \
  "$ROOT/corev_apu/apu/include/g6lc_apu_pkg.sv" \
  "$ROOT/corev_apu/apu/include/g6lc_apu_bus_pkg.sv" \
  "$ROOT/corev_apu/register_interface/src/reg_intf.sv" \
  "$ROOT/corev_apu/register_interface/src/axi_lite_to_reg.sv" \
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
  "$ROOT/vendor/pulp-platform/tech_cells_generic/src/rtl/tc_clk.sv" \
  "$ROOT/corev_apu/apu/g6lc_apu_virtio_mmio.sv" \
  "$ROOT/corev_apu/apu/g6lc_apu_top.sv" \
  "$ROOT/corev_apu/apu/g6lc_apu_control.sv" \
  "$ROOT/corev_apu/apu/g6lc_apu_axi_lite.sv" \
  "$ROOT/corev_apu/apu/g6lc_apu_dma_read.sv" \
  "$ROOT/corev_apu/apu/g6lc_apu_dma_write.sv" \
  "$ROOT/corev_apu/apu/g6lc_apu_sg.sv" \
  "$ROOT/corev_apu/apu/g6lc_apu_storage.sv" \
  "$ROOT/corev_apu/apu/g6lc_apu_queue.sv" \
  "$ROOT/corev_apu/apu/g6lc_apu_mem.sv" \
  "$ROOT/corev_apu/apu/g6lc_apu_mbox.sv" \
  "$ROOT/corev_apu/apu/g6lc_apu_exec.sv" \
  "$ROOT/corev_apu/apu/g6lc_apu_exec_bind.sv" \
  "$ROOT/corev_apu/apu/g6lc_apu_sys.sv" \
  "$ROOT/corev_apu/apu/g6lc_apu_grant.sv" \
  "$ROOT/corev_apu/apu/g6lc_apu_soc.sv" \
  "$ROOT/corev_apu/apu/g6lc_apu_attach.sv" \
  "$ROOT/corev_apu/apu/g6lc_apu_axi4_lite.sv" \
  "$ROOT/corev_apu/apu/g6lc_apu_th.sv" \
  "$ROOT/corev_apu/apu/g6lc_apu_xbar.sv" \
  "$ROOT/corev_apu/apu/g6lc_apu_fwram.sv" \
  "$ROOT/corev_apu/apu/g6lc_apu_th_load.sv" \
  "$ROOT/verif/tb/apu/tb_g6lc_apu_cva6_tgsi.sv" \
  "$ROOT/verif/tb/apu/g6lc_dram_peek64_stub.cpp" \
  --top-module tb_g6lc_apu_cva6_tgsi \
  -GHexFile='"apu_tgsi_cc.hex"' \
  -Mdir "$OUT" -o tb_g6lc_apu_cva6_tgsi_cc \
  2>&1 | tee "$OUT/build.log"
# Do not pass +APU_FW_HEX= — that plusarg would override the ROM image too.
( cd "$OUT" && ./tb_g6lc_apu_cva6_tgsi_cc ) 2>&1 | tee "$OUT/sim.log"
if [[ "${APU_SYNTH:-1}" == 1 ]]; then
  YOSYS="${YOSYS:-/opt/testharness/toolchains/formal/bin/yosys}"
  for enabled in 0 1; do
    "$VERILATOR" --lint-only --timing --assert -Wall -Wno-TIMESCALEMOD \
      -Wno-UNUSED -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
      -Wno-BLKANDNBLK -Wno-UNOPTFLAT -Wno-LITENDIAN \
      "$ROOT/verif/tb/apu/apu_axi.vlt" "$ROOT/verif/tb/apu/apu_exec.vlt" \
      -f "$ROOT/corev_apu/apu/Flist.apu_soc" \
      "$ROOT/verif/tb/apu/tb_g6lc_apu_th_exec.sv" \
      --top-module g6lc_apu_th_exec_fixture \
      "-GEnable=1'b$enabled" "-GExecEn=1'b$enabled" -GRamBytes=4096 \
      2>&1 | tee "$OUT/lint-$enabled.log"
    "$YOSYS" -Q -T -p "read_slang -f $ROOT/corev_apu/apu/Flist.apu_soc $ROOT/verif/tb/apu/tb_g6lc_apu_th_exec.sv --top g6lc_apu_th_exec_fixture -GEnable=$enabled -GExecEn=$enabled -GRamBytes=4096; hierarchy -top g6lc_apu_th_exec_fixture; flatten; proc; opt; memory_collect; check -assert; stat; synth -top g6lc_apu_th_exec_fixture -noabc; check -assert; stat; select -assert-none t:\$dlatch t:\$_DLATCH_*" \
      2>&1 | tee "$OUT/synth-$enabled.log"
  done
fi
