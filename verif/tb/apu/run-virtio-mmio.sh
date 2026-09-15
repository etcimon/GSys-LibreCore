#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Standalone Verilator smoke for the P1 APU virtio-mmio transport state.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="${APU_VIRTIO_OUT:-/tmp/g6lc-apu-virtio-mmio}"
VERILATOR="${VERILATOR:-verilator}"
if ! command -v "$VERILATOR" >/dev/null 2>&1 && \
   [ -x /opt/testharness/toolchains/verilator-v5.008/bin/verilator ]; then
  VERILATOR=/opt/testharness/toolchains/verilator-v5.008/bin/verilator
fi
mkdir -p "$OUT"
export CVA6_REPO_DIR="$ROOT"
for width in 12 16 64; do
  "$VERILATOR" --lint-only --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
    -Wno-SYNCASYNCNET -GAddrWidth="$width" \
    -f "$ROOT/corev_apu/apu/Flist.apu" --top-module g6lc_apu_virtio_mmio \
    2>&1 | tee "$OUT/lint-$width.log"
done
"$VERILATOR" --lint-only -Wall -Wno-UNUSED \
  -f "$ROOT/corev_apu/apu/Flist.apu" --top-module g6lc_apu_top \
  2>&1 | tee "$OUT/lint-off.log"
"$VERILATOR" --binary --timing --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
  -Wno-WIDTHEXPAND -Wno-BLKSEQ -Wno-SYNCASYNCNET \
  -f "$ROOT/corev_apu/apu/Flist.apu" \
  "$ROOT/verif/tb/apu/tb_g6lc_apu_virtio_mmio.sv" \
  --top-module tb_g6lc_apu_virtio_mmio \
  -Mdir "$OUT" -o tb_g6lc_apu_virtio_mmio 2>&1 | tee "$OUT/build.log"
"$OUT/tb_g6lc_apu_virtio_mmio" 2>&1 | tee "$OUT/sim.log"
if [[ "${APU_AXI:-0}" == 1 ]]; then
  mkdir -p "$OUT/axi"
  "$VERILATOR" --binary --timing --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
    -Wno-WIDTHEXPAND -Wno-BLKSEQ -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
    "$ROOT/verif/tb/apu/apu_axi.vlt" -f "$ROOT/corev_apu/apu/Flist.apu_axi" \
    "$ROOT/verif/tb/apu/tb_g6lc_apu_axi_lite.sv" \
    --top-module tb_g6lc_apu_axi_lite -Mdir "$OUT/axi" -o tb_g6lc_apu_axi_lite \
    2>&1 | tee "$OUT/axi/build.log"
  "$OUT/axi/tb_g6lc_apu_axi_lite" ${APU_AXI_ARGS:-} 2>&1 | tee "$OUT/axi/sim.log"
fi
if [[ "${APU_DMA:-0}" == 1 ]]; then
  for profile in "0 16" "1 1" "1 256"; do
    read -r high burst <<< "$profile"
    dma_out="$OUT/dma-$high-$burst"
    mkdir -p "$dma_out"
    "$VERILATOR" --binary --timing --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
      -Wno-WIDTHEXPAND -Wno-BLKSEQ -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
      "$ROOT/verif/tb/apu/apu_axi.vlt" -f "$ROOT/corev_apu/apu/Flist.apu_axi" \
      "$ROOT/verif/tb/apu/tb_g6lc_apu_dma_read.sv" --top-module tb_g6lc_apu_dma_read \
      "-GHighAddress=1'b$high" -GBurstBeats="$burst" \
      -Mdir "$dma_out" -o tb_g6lc_apu_dma_read 2>&1 | tee "$dma_out/build.log"
    "$dma_out/tb_g6lc_apu_dma_read" 2>&1 | tee "$dma_out/sim.log"
  done
fi
if [[ "${APU_DMA_WRITE:-0}" == 1 ]]; then
  for profile in "0 8" "1 3"; do
    read -r high packet <<< "$profile"
    write_out="$OUT/write-$high-$packet"
    mkdir -p "$write_out"
    "$VERILATOR" --binary --timing --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
      -Wno-WIDTHEXPAND -Wno-BLKSEQ -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
      "$ROOT/verif/tb/apu/apu_axi.vlt" -f "$ROOT/corev_apu/apu/Flist.apu_axi" \
      "$ROOT/verif/tb/apu/tb_g6lc_apu_dma_write.sv" --top-module tb_g6lc_apu_dma_write \
      "-GHighAddress=1'b$high" -GPacketBytes="$packet" \
      -Mdir "$write_out" -o tb_g6lc_apu_dma_write 2>&1 | tee "$write_out/build.log"
    "$write_out/tb_g6lc_apu_dma_write" 2>&1 | tee "$write_out/sim.log"
  done
fi
if [[ "${APU_EXEC:-0}" == 1 ]]; then
  exec_out="$OUT/exec"
  mkdir -p "$exec_out"
  "$VERILATOR" --binary --timing --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
    -Wno-WIDTHEXPAND -Wno-BLKSEQ -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
    -Wno-BLKANDNBLK -Wno-UNOPTFLAT -Wno-LITENDIAN \
    "$ROOT/verif/tb/apu/apu_axi.vlt" "$ROOT/verif/tb/apu/apu_exec.vlt" \
    -f "$ROOT/corev_apu/apu/Flist.apu_exec" \
    "$ROOT/verif/tb/apu/tb_g6lc_apu_exec.sv" --top-module tb_g6lc_apu_exec \
    -Mdir "$exec_out" -o tb_g6lc_apu_exec 2>&1 | tee "$exec_out/build.log"
  "$exec_out/tb_g6lc_apu_exec" 2>&1 | tee "$exec_out/sim.log"
  fw_out="$OUT/fw"
  mkdir -p "$fw_out"
  "$VERILATOR" --binary --timing --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
    -Wno-WIDTHEXPAND -Wno-BLKSEQ -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
    -Wno-BLKANDNBLK -Wno-UNOPTFLAT -Wno-LITENDIAN \
    "$ROOT/verif/tb/apu/apu_axi.vlt" "$ROOT/verif/tb/apu/apu_exec.vlt" \
    -f "$ROOT/corev_apu/apu/Flist.apu_fw" \
    "$ROOT/verif/tb/apu/tb_g6lc_apu_fw.sv" --top-module tb_g6lc_apu_fw \
    -Mdir "$fw_out" -o tb_g6lc_apu_fw 2>&1 | tee "$fw_out/build.log"
  "$fw_out/tb_g6lc_apu_fw" 2>&1 | tee "$fw_out/sim.log"
  res_out="$OUT/resident"
  mkdir -p "$res_out"
  HOSTCC="${HOSTCC:-gcc}"
  "$HOSTCC" -I"$ROOT/software/apu-fw/include" -o "$res_out/enc_check" \
    "$ROOT/software/apu-fw/test/enc_check.c"
  "$res_out/enc_check" 2>&1 | tee "$res_out/enc_check.log"
  "$HOSTCC" -I"$ROOT/software/apu-fw/include" -o "$res_out/tgsi_check" \
    "$ROOT/software/apu-fw/test/tgsi_check.c" \
    "$ROOT/software/apu-fw/src/g6lc_apu_tgsi.c"
  "$res_out/tgsi_check" 2>&1 | tee "$res_out/tgsi_check.log"
  "$HOSTCC" -I"$ROOT/software/apu-fw/include" -o "$res_out/tgsi_fw_check" \
    "$ROOT/software/apu-fw/test/tgsi_fw_check.c" \
    "$ROOT/software/apu-fw/src/g6lc_apu_tgsi.c" \
    "$ROOT/software/apu-fw/src/g6lc_apu_tgsi_job.c"
  "$res_out/tgsi_fw_check" 2>&1 | tee "$res_out/tgsi_fw_check.log"
  "$HOSTCC" -I"$ROOT/software/apu-fw/include" -o "$res_out/map_check" \
    "$ROOT/software/apu-fw/test/map_check.c"
  "$res_out/map_check" 2>&1 | tee "$res_out/map_check.log"
  "$HOSTCC" -I"$ROOT/software/apu-fw/include" -o "$res_out/boot_check" \
    "$ROOT/software/apu-fw/test/boot_check.c"
  "$res_out/boot_check" \
    "$ROOT/verif/tb/apu/apu_fw.hex" \
    "$ROOT/software/apu-fw/apu_fw.elf" \
    "$ROOT/corev_apu/bootrom/g6lc-apu-domain.dtsi" \
    2>&1 | tee "$res_out/boot_check.log"
  "$HOSTCC" -I"$ROOT/software/apu-fw/include" -o "$res_out/load_check" \
    "$ROOT/software/apu-fw/test/load_check.c"
  "$res_out/load_check" 2>&1 | tee "$res_out/load_check.log"
  "$VERILATOR" --binary --timing --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
    -Wno-WIDTHEXPAND -Wno-BLKSEQ -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
    -Wno-BLKANDNBLK -Wno-UNOPTFLAT -Wno-LITENDIAN \
    "$ROOT/verif/tb/apu/apu_axi.vlt" "$ROOT/verif/tb/apu/apu_exec.vlt" \
    -f "$ROOT/corev_apu/apu/Flist.apu_fw" \
    "$ROOT/verif/tb/apu/tb_g6lc_apu_resident.sv" --top-module tb_g6lc_apu_resident \
    -Mdir "$res_out" -o tb_g6lc_apu_resident 2>&1 | tee "$res_out/build.log"
  "$res_out/tb_g6lc_apu_resident" 2>&1 | tee "$res_out/sim.log"
  CROSS=""
  if command -v riscv-none-elf-gcc >/dev/null 2>&1; then CROSS=riscv-none-elf-
  elif command -v riscv64-unknown-elf-gcc >/dev/null 2>&1; then CROSS=riscv64-unknown-elf-
  elif [ -x /opt/testharness/toolchains/riscv-none-elf-gcc/bin/riscv-none-elf-gcc ]; then
    CROSS=/opt/testharness/toolchains/riscv-none-elf-gcc/bin/riscv-none-elf-
  fi
  if [[ -n "$CROSS" ]]; then
    make -C "$ROOT/software/apu-fw" firmware CROSS_COMPILE="$CROSS" \
      2>&1 | tee "$res_out/firmware-build.log"
  else
    echo "skip firmware cross-compile (no RISC-V gcc)" | tee "$res_out/firmware-build.log"
  fi
  hart_out="$OUT/hart"
  mkdir -p "$hart_out"
  cp "$ROOT/verif/tb/apu/apu_fw.hex" "$hart_out/apu_fw.hex"
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
    "$ROOT/verif/tb/apu/tb_g6lc_apu_hart.sv" --top-module tb_g6lc_apu_hart \
    -Mdir "$hart_out" -o tb_g6lc_apu_hart 2>&1 | tee "$hart_out/build.log"
  "$hart_out/tb_g6lc_apu_hart" "+HEX=$ROOT/verif/tb/apu/apu_fw.hex" \
    2>&1 | tee "$hart_out/sim.log"
  tgsi_out="$OUT/tgsi-fw"
  mkdir -p "$tgsi_out"
  if [[ -f "$ROOT/verif/tb/apu/apu_tgsi.hex" ]]; then
    cp "$ROOT/verif/tb/apu/apu_tgsi.hex" "$tgsi_out/apu_tgsi.hex"
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
      -Mdir "$tgsi_out" -o tb_g6lc_apu_tgsi_fw 2>&1 | tee "$tgsi_out/build.log"
    "$tgsi_out/tb_g6lc_apu_tgsi_fw" "+HEX=$ROOT/verif/tb/apu/apu_tgsi.hex" \
      2>&1 | tee "$tgsi_out/sim.log"
  else
    echo "skip tb_g6lc_apu_tgsi_fw (no apu_tgsi.hex)" | tee "$tgsi_out/sim.log"
  fi
fi
if [[ "${APU_SG:-0}" == 1 ]]; then
  for entries in 64 128; do
    sg_out="$OUT/sg-$entries"
    mkdir -p "$sg_out"
    "$VERILATOR" --binary --timing --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
      -Wno-WIDTHEXPAND -Wno-BLKSEQ -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
      "$ROOT/verif/tb/apu/apu_axi.vlt" -f "$ROOT/corev_apu/apu/Flist.apu_sg" \
      "$ROOT/verif/tb/apu/tb_g6lc_apu_sg.sv" --top-module tb_g6lc_apu_sg -GEntries="$entries" \
      -Mdir "$sg_out" -o tb_g6lc_apu_sg 2>&1 | tee "$sg_out/build.log"
    "$sg_out/tb_g6lc_apu_sg" 2>&1 | tee "$sg_out/sim.log"
  done
fi
if [[ "${APU_MEM:-0}" == 1 ]]; then
  mem_out="$OUT/storage"
  mkdir -p "$mem_out"
  "$VERILATOR" --binary --timing --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
    -Wno-WIDTHEXPAND -Wno-BLKSEQ -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
    "$ROOT/verif/tb/apu/apu_axi.vlt" -f "$ROOT/corev_apu/apu/Flist.apu_mem" \
    "$ROOT/verif/tb/apu/tb_g6lc_apu_storage.sv" --top-module tb_g6lc_apu_storage \
    -Mdir "$mem_out" -o tb_g6lc_apu_storage 2>&1 | tee "$mem_out/build.log"
  "$mem_out/tb_g6lc_apu_storage" 2>&1 | tee "$mem_out/sim.log"
  queue_out="$OUT/queue"
  mkdir -p "$queue_out"
  "$VERILATOR" --binary --timing --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
    -Wno-WIDTHEXPAND -Wno-BLKSEQ -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
    "$ROOT/verif/tb/apu/apu_axi.vlt" -f "$ROOT/corev_apu/apu/Flist.apu_mem" \
    "$ROOT/verif/tb/apu/tb_g6lc_apu_queue.sv" --top-module tb_g6lc_apu_queue \
    -Mdir "$queue_out" -o tb_g6lc_apu_queue 2>&1 | tee "$queue_out/build.log"
  "$queue_out/tb_g6lc_apu_queue" 2>&1 | tee "$queue_out/sim.log"
  bind_out="$OUT/bind"
  mkdir -p "$bind_out"
  "$VERILATOR" --binary --timing --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
    -Wno-WIDTHEXPAND -Wno-BLKSEQ -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
    "$ROOT/verif/tb/apu/apu_axi.vlt" -f "$ROOT/corev_apu/apu/Flist.apu_mem" \
    "$ROOT/verif/tb/apu/tb_g6lc_apu_mem.sv" --top-module tb_g6lc_apu_mem \
    -Mdir "$bind_out" -o tb_g6lc_apu_mem 2>&1 | tee "$bind_out/build.log"
  "$bind_out/tb_g6lc_apu_mem" 2>&1 | tee "$bind_out/sim.log"
  sys_out="$OUT/sys"
  mkdir -p "$sys_out"
  "$VERILATOR" --binary --timing --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
    -Wno-WIDTHEXPAND -Wno-BLKSEQ -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
    "$ROOT/verif/tb/apu/apu_axi.vlt" -f "$ROOT/corev_apu/apu/Flist.apu_mem" \
    "$ROOT/verif/tb/apu/tb_g6lc_apu_sys.sv" --top-module tb_g6lc_apu_sys \
    -Mdir "$sys_out" -o tb_g6lc_apu_sys 2>&1 | tee "$sys_out/build.log"
  "$sys_out/tb_g6lc_apu_sys" 2>&1 | tee "$sys_out/sim.log"
fi
if [[ "${APU_SOC:-0}" == 1 ]]; then
  grant_out="$OUT/grant"
  mkdir -p "$grant_out"
  "$VERILATOR" --binary --timing --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
    -Wno-WIDTHEXPAND -Wno-BLKSEQ -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
    "$ROOT/verif/tb/apu/apu_axi.vlt" -f "$ROOT/corev_apu/apu/Flist.apu_soc" \
    "$ROOT/verif/tb/apu/tb_g6lc_apu_grant.sv" --top-module tb_g6lc_apu_grant \
    -Mdir "$grant_out" -o tb_g6lc_apu_grant 2>&1 | tee "$grant_out/build.log"
  "$grant_out/tb_g6lc_apu_grant" 2>&1 | tee "$grant_out/sim.log"
  soc_out="$OUT/soc"
  mkdir -p "$soc_out"
  "$VERILATOR" --binary --timing --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
    -Wno-WIDTHEXPAND -Wno-BLKSEQ -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
    "$ROOT/verif/tb/apu/apu_axi.vlt" -f "$ROOT/corev_apu/apu/Flist.apu_soc" \
    "$ROOT/verif/tb/apu/tb_g6lc_apu_soc.sv" --top-module tb_g6lc_apu_soc \
    -Mdir "$soc_out" -o tb_g6lc_apu_soc 2>&1 | tee "$soc_out/build.log"
  "$soc_out/tb_g6lc_apu_soc" 2>&1 | tee "$soc_out/sim.log"
  attach_out="$OUT/attach"
  mkdir -p "$attach_out"
  "$VERILATOR" --binary --timing --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
    -Wno-WIDTHEXPAND -Wno-BLKSEQ -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
    "$ROOT/verif/tb/apu/apu_axi.vlt" -f "$ROOT/corev_apu/apu/Flist.apu_soc" \
    "$ROOT/verif/tb/apu/tb_g6lc_apu_attach.sv" --top-module tb_g6lc_apu_attach \
    -Mdir "$attach_out" -o tb_g6lc_apu_attach 2>&1 | tee "$attach_out/build.log"
  "$attach_out/tb_g6lc_apu_attach" 2>&1 | tee "$attach_out/sim.log"
  th_out="$OUT/th"
  mkdir -p "$th_out"
  "$VERILATOR" --binary --timing --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
    -Wno-WIDTHEXPAND -Wno-BLKSEQ -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
    "$ROOT/verif/tb/apu/apu_axi.vlt" -f "$ROOT/corev_apu/apu/Flist.apu_soc" \
    "$ROOT/verif/tb/apu/tb_g6lc_apu_th.sv" --top-module tb_g6lc_apu_th \
    -Mdir "$th_out" -o tb_g6lc_apu_th 2>&1 | tee "$th_out/build.log"
  "$th_out/tb_g6lc_apu_th" 2>&1 | tee "$th_out/sim.log"
  xbar_out="$OUT/xbar"
  mkdir -p "$xbar_out"
  "$VERILATOR" --binary --timing --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
    -Wno-WIDTHEXPAND -Wno-BLKSEQ -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
    "$ROOT/verif/tb/apu/apu_axi.vlt" -f "$ROOT/corev_apu/apu/Flist.apu_soc" \
    "$ROOT/verif/tb/apu/tb_g6lc_apu_xbar.sv" --top-module tb_g6lc_apu_xbar \
    -Mdir "$xbar_out" -o tb_g6lc_apu_xbar 2>&1 | tee "$xbar_out/build.log"
  "$xbar_out/tb_g6lc_apu_xbar" 2>&1 | tee "$xbar_out/sim.log"
  load_out="$OUT/th_load"
  mkdir -p "$load_out"
  cp "$ROOT/verif/tb/apu/apu_fw.hex" "$load_out/apu_fw.hex"
  "$VERILATOR" --binary --timing --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
    -Wno-WIDTHEXPAND -Wno-BLKSEQ -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
    "$ROOT/verif/tb/apu/apu_axi.vlt" -f "$ROOT/corev_apu/apu/Flist.apu_soc" \
    "$ROOT/verif/tb/apu/tb_g6lc_apu_th_load.sv" --top-module tb_g6lc_apu_th_load \
    -Mdir "$load_out" -o tb_g6lc_apu_th_load 2>&1 | tee "$load_out/build.log"
  "$load_out/tb_g6lc_apu_th_load" "+APU_FW_HEX=$ROOT/verif/tb/apu/apu_fw.hex" \
    2>&1 | tee "$load_out/sim.log"
  fwram_out="$OUT/fwram"
  mkdir -p "$fwram_out"
  cp "$ROOT/verif/tb/apu/apu_fw.hex" "$fwram_out/apu_fw.hex"
  "$VERILATOR" --binary --timing --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
    -Wno-WIDTHEXPAND -Wno-BLKSEQ -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
    "$ROOT/verif/tb/apu/apu_axi.vlt" -f "$ROOT/corev_apu/apu/Flist.apu_soc" \
    "$ROOT/verif/tb/apu/tb_g6lc_apu_fwram.sv" --top-module tb_g6lc_apu_fwram \
    -Mdir "$fwram_out" -o tb_g6lc_apu_fwram 2>&1 | tee "$fwram_out/build.log"
  "$fwram_out/tb_g6lc_apu_fwram" "+HEX=$ROOT/verif/tb/apu/apu_fw.hex" \
    2>&1 | tee "$fwram_out/sim.log"
  domain_out="$OUT/domain"
  mkdir -p "$domain_out"
  "$VERILATOR" --binary --timing --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
    -Wno-WIDTHEXPAND -Wno-BLKSEQ -Wno-DECLFILENAME \
    -f "$ROOT/corev_apu/apu/Flist.apu" \
    "$ROOT/verif/tb/apu/tb_g6lc_apu_domain.sv" --top-module tb_g6lc_apu_domain \
    -Mdir "$domain_out" -o tb_g6lc_apu_domain 2>&1 | tee "$domain_out/build.log"
  "$domain_out/tb_g6lc_apu_domain" 2>&1 | tee "$domain_out/sim.log"
fi
if [[ "${APU_SYNTH:-0}" == 1 ]]; then
  YOSYS="${YOSYS:-/opt/testharness/toolchains/formal/bin/yosys}"
  if [[ "${APU_MEM:-0}" == 1 ]]; then
    for enabled in 0 1; do
      mem_out="$OUT/storage"
      "$VERILATOR" --lint-only --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
        -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
        "$ROOT/verif/tb/apu/apu_axi.vlt" -f "$ROOT/corev_apu/apu/Flist.apu_mem" \
        "$ROOT/verif/tb/apu/tb_g6lc_apu_storage.sv" --top-module g6lc_apu_storage_fixture \
        "-GEnable=1'b$enabled" 2>&1 | tee "$mem_out/lint-$enabled.log"
      extra_check=""
      if [[ "$enabled" == 0 ]]; then extra_check="; select -assert-none t:*"; fi
      # Enabled storage uses sanctioned tc_clk_gating latches; mapping/command
      # arrays are proven in simulation. Do not require a flattened $mem_v2 count.
      "$YOSYS" -Q -T -p "read_slang -f $ROOT/corev_apu/apu/Flist.apu_mem $ROOT/verif/tb/apu/tb_g6lc_apu_storage.sv --top g6lc_apu_storage_fixture -GEnable=$enabled; hierarchy -top g6lc_apu_storage_fixture; flatten; proc; opt; memory_collect; check -assert; stat; synth -top g6lc_apu_storage_fixture -noabc; check -assert; stat $extra_check" \
        2>&1 | tee "$mem_out/synth-$enabled.log"
      queue_out="$OUT/queue"
      "$VERILATOR" --lint-only --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
        -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
        "$ROOT/verif/tb/apu/apu_axi.vlt" -f "$ROOT/corev_apu/apu/Flist.apu_mem" \
        "$ROOT/verif/tb/apu/tb_g6lc_apu_queue.sv" --top-module g6lc_apu_queue_fixture \
        "-GEnable=1'b$enabled" 2>&1 | tee "$queue_out/lint-$enabled.log"
      extra_check=""
      if [[ "$enabled" == 0 ]]; then extra_check="; select -assert-none t:*"; fi
      "$YOSYS" -Q -T -p "read_slang -f $ROOT/corev_apu/apu/Flist.apu_mem $ROOT/verif/tb/apu/tb_g6lc_apu_queue.sv --top g6lc_apu_queue_fixture -GEnable=$enabled; synth -top g6lc_apu_queue_fixture -flatten -noabc; check -assert; stat; select -assert-none t:\$dlatch t:\$_DLATCH_* $extra_check" \
        2>&1 | tee "$queue_out/synth-$enabled.log"
      bind_out="$OUT/bind"
      mkdir -p "$bind_out"
      "$VERILATOR" --lint-only --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
        -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
        "$ROOT/verif/tb/apu/apu_axi.vlt" -f "$ROOT/corev_apu/apu/Flist.apu_mem" \
        "$ROOT/verif/tb/apu/tb_g6lc_apu_mem.sv" --top-module g6lc_apu_mem_fixture \
        "-GEnable=1'b$enabled" 2>&1 | tee "$bind_out/lint-$enabled.log"
      extra_check=""
      if [[ "$enabled" == 0 ]]; then extra_check="; select -assert-none t:*"; fi
      "$YOSYS" -Q -T -p "read_slang -f $ROOT/corev_apu/apu/Flist.apu_mem $ROOT/verif/tb/apu/tb_g6lc_apu_mem.sv --top g6lc_apu_mem_fixture -GEnable=$enabled; hierarchy -top g6lc_apu_mem_fixture; flatten; proc; opt; memory_collect; check -assert; stat; synth -top g6lc_apu_mem_fixture -noabc; check -assert; stat $extra_check" \
        2>&1 | tee "$bind_out/synth-$enabled.log"
      sys_out="$OUT/sys"
      mkdir -p "$sys_out"
      "$VERILATOR" --lint-only --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
        -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
        "$ROOT/verif/tb/apu/apu_axi.vlt" -f "$ROOT/corev_apu/apu/Flist.apu_mem" \
        "$ROOT/verif/tb/apu/tb_g6lc_apu_sys.sv" --top-module g6lc_apu_sys_fixture \
        "-GEnable=1'b$enabled" 2>&1 | tee "$sys_out/lint-$enabled.log"
      # Disabled sys keeps AXI-lite response bookkeeping; enabled storage uses
      # sanctioned tc_clk_gating latches. Do not require zero cells or no-dlatch.
      "$YOSYS" -Q -T -p "read_slang -f $ROOT/corev_apu/apu/Flist.apu_mem $ROOT/verif/tb/apu/tb_g6lc_apu_sys.sv --top g6lc_apu_sys_fixture -GEnable=$enabled; hierarchy -top g6lc_apu_sys_fixture; flatten; proc; opt; memory_collect; check -assert; stat; synth -top g6lc_apu_sys_fixture -noabc; check -assert; stat" \
        2>&1 | tee "$sys_out/synth-$enabled.log"
    done
  fi
  if [[ "${APU_SG:-0}" == 1 ]]; then
    for profile in "0 64" "1 64" "1 128"; do
      read -r enabled entries <<< "$profile"
      sg_out="$OUT/sg-$entries"
      "$VERILATOR" --lint-only --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
        -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
        "$ROOT/verif/tb/apu/apu_axi.vlt" -f "$ROOT/corev_apu/apu/Flist.apu_sg" \
        "$ROOT/verif/tb/apu/tb_g6lc_apu_sg.sv" --top-module g6lc_sg_fixture \
        "-GEnable=1'b$enabled" -GEntries="$entries" 2>&1 | tee "$sg_out/lint-$enabled.log"
      extra_check=""
      if [[ "$enabled" == 0 ]]; then extra_check="; select -assert-none t:*"; fi
      "$YOSYS" -Q -T -p "read_slang -f $ROOT/corev_apu/apu/Flist.apu_sg $ROOT/verif/tb/apu/tb_g6lc_apu_sg.sv --top g6lc_sg_fixture -GEnable=$enabled -GEntries=$entries; hierarchy -top g6lc_sg_fixture; flatten; proc; opt; memory_collect; check -assert; stat; select -assert-count $enabled t:\$mem_v2; synth -top g6lc_sg_fixture -noabc; check -assert; stat; select -assert-none t:\$dlatch t:\$_DLATCH_* $extra_check" \
        2>&1 | tee "$sg_out/synth-$enabled.log"
    done
  fi
  if [[ "${APU_DMA_WRITE:-0}" == 1 ]]; then
    for profile in "0 0 8" "1 0 8" "1 1 3"; do
      read -r enabled high packet <<< "$profile"
      write_out="$OUT/write-$high-$packet"
      "$VERILATOR" --lint-only --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
        -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
        "$ROOT/verif/tb/apu/apu_axi.vlt" -f "$ROOT/corev_apu/apu/Flist.apu_axi" \
        "$ROOT/verif/tb/apu/tb_g6lc_apu_dma_write.sv" --top-module g6lc_apu_dma_write_fixture \
        "-GEnable=1'b$enabled" "-GHighAddress=1'b$high" \
        2>&1 | tee "$write_out/lint-$enabled.log"
      extra_check=""
      if [[ "$enabled" == 0 ]]; then extra_check="; select -assert-none t:*"; fi
      "$YOSYS" -Q -T -p "read_slang -f $ROOT/corev_apu/apu/Flist.apu_axi $ROOT/verif/tb/apu/tb_g6lc_apu_dma_write.sv --top g6lc_apu_dma_write_fixture -GEnable=$enabled -GHighAddress=$high; synth -top g6lc_apu_dma_write_fixture -flatten -noabc; check -assert; stat; select -assert-none t:\$dlatch t:\$_DLATCH_* $extra_check" \
        2>&1 | tee "$write_out/synth-$enabled.log"
    done
  fi
  if [[ "${APU_DMA:-0}" == 1 ]]; then
    for profile in "0 0 16" "1 0 16" "1 1 1" "1 1 256"; do
      read -r enabled high burst <<< "$profile"
      dma_out="$OUT/dma-$high-$burst"
      "$VERILATOR" --lint-only --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
        -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
        "$ROOT/verif/tb/apu/apu_axi.vlt" -f "$ROOT/corev_apu/apu/Flist.apu_axi" \
        "$ROOT/verif/tb/apu/tb_g6lc_apu_dma_read.sv" --top-module g6lc_apu_dma_fixture \
        "-GEnable=1'b$enabled" "-GHighAddress=1'b$high" -GBurstBeats="$burst" \
        2>&1 | tee "$dma_out/lint-$enabled.log"
      extra_check=""
      if [[ "$enabled" == 0 ]]; then extra_check="; select -assert-none t:*"; fi
      "$YOSYS" -Q -T -p "read_slang -f $ROOT/corev_apu/apu/Flist.apu_axi $ROOT/verif/tb/apu/tb_g6lc_apu_dma_read.sv --top g6lc_apu_dma_fixture -GEnable=$enabled -GHighAddress=$high -GBurstBeats=$burst; synth -top g6lc_apu_dma_fixture -flatten -noabc; check -assert; stat; select -assert-none t:\$dlatch t:\$_DLATCH_* $extra_check" \
        2>&1 | tee "$dma_out/synth-$enabled.log"
    done
  fi
  if [[ "${APU_AXI:-0}" == 1 ]]; then
    for enabled in 0 1; do
      "$VERILATOR" --lint-only --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
        -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
        "$ROOT/verif/tb/apu/apu_axi.vlt" -f "$ROOT/corev_apu/apu/Flist.apu_axi" \
        "$ROOT/verif/tb/apu/tb_g6lc_apu_axi_lite.sv" \
        --top-module g6lc_apu_axi_fixture "-GEnable=1'b$enabled" \
        2>&1 | tee "$OUT/axi/lint-$enabled.log"
      "$YOSYS" -Q -T -p "read_slang -f $ROOT/corev_apu/apu/Flist.apu_axi $ROOT/verif/tb/apu/tb_g6lc_apu_axi_lite.sv --top g6lc_apu_axi_fixture -GEnable=$enabled; synth -top g6lc_apu_axi_fixture -flatten -noabc; check -assert; stat; select -assert-none t:\$dlatch t:\$_DLATCH_*" \
        2>&1 | tee "$OUT/axi/synth-$enabled.log"
    done
  fi
  if [[ "${APU_SOC:-0}" == 1 ]]; then
    for enabled in 0 1; do
      grant_out="$OUT/grant"
      mkdir -p "$grant_out"
      "$VERILATOR" --lint-only --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
        -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
        "$ROOT/verif/tb/apu/apu_axi.vlt" -f "$ROOT/corev_apu/apu/Flist.apu_soc" \
        "$ROOT/verif/tb/apu/tb_g6lc_apu_grant.sv" --top-module g6lc_apu_grant_fixture \
        "-GEnable=1'b$enabled" 2>&1 | tee "$grant_out/lint-$enabled.log"
      extra_check=""
      if [[ "$enabled" == 0 ]]; then extra_check="; select -assert-none t:*"; fi
      "$YOSYS" -Q -T -p "read_slang -f $ROOT/corev_apu/apu/Flist.apu_soc $ROOT/verif/tb/apu/tb_g6lc_apu_grant.sv --top g6lc_apu_grant_fixture -GEnable=$enabled; synth -top g6lc_apu_grant_fixture -flatten -noabc; check -assert; stat; select -assert-none t:\$dlatch t:\$_DLATCH_* $extra_check" \
        2>&1 | tee "$grant_out/synth-$enabled.log"
      soc_out="$OUT/soc"
      mkdir -p "$soc_out"
      "$VERILATOR" --lint-only --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
        -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
        "$ROOT/verif/tb/apu/apu_axi.vlt" -f "$ROOT/corev_apu/apu/Flist.apu_soc" \
        "$ROOT/verif/tb/apu/tb_g6lc_apu_soc.sv" --top-module g6lc_apu_soc_fixture \
        "-GEnable=1'b$enabled" 2>&1 | tee "$soc_out/lint-$enabled.log"
      # Disabled SoC keeps AXI-lite response bookkeeping.
      "$YOSYS" -Q -T -p "read_slang -f $ROOT/corev_apu/apu/Flist.apu_soc $ROOT/verif/tb/apu/tb_g6lc_apu_soc.sv --top g6lc_apu_soc_fixture -GEnable=$enabled; synth -top g6lc_apu_soc_fixture -flatten -noabc; check -assert; stat; select -assert-none t:\$dlatch t:\$_DLATCH_*" \
        2>&1 | tee "$soc_out/synth-$enabled.log"
      attach_out="$OUT/attach"
      mkdir -p "$attach_out"
      "$VERILATOR" --lint-only --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
        -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
        "$ROOT/verif/tb/apu/apu_axi.vlt" -f "$ROOT/corev_apu/apu/Flist.apu_soc" \
        "$ROOT/verif/tb/apu/tb_g6lc_apu_attach.sv" --top-module g6lc_apu_attach_fixture \
        "-GEnable=1'b$enabled" 2>&1 | tee "$attach_out/lint-$enabled.log"
      # Disabled attach keeps AXI-lite response bookkeeping plus irq passthrough.
      "$YOSYS" -Q -T -p "read_slang -f $ROOT/corev_apu/apu/Flist.apu_soc $ROOT/verif/tb/apu/tb_g6lc_apu_attach.sv --top g6lc_apu_attach_fixture -GEnable=$enabled; synth -top g6lc_apu_attach_fixture -flatten -noabc; check -assert; stat; select -assert-none t:\$dlatch t:\$_DLATCH_*" \
        2>&1 | tee "$attach_out/synth-$enabled.log"
      th_out="$OUT/th"
      mkdir -p "$th_out"
      "$VERILATOR" --lint-only --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
        -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
        "$ROOT/verif/tb/apu/apu_axi.vlt" -f "$ROOT/corev_apu/apu/Flist.apu_soc" \
        "$ROOT/verif/tb/apu/tb_g6lc_apu_th.sv" --top-module g6lc_apu_th_fixture \
        "-GEnable=1'b$enabled" 2>&1 | tee "$th_out/lint-$enabled.log"
      # Disabled th is AXI4 error slaves plus attach AXI-lite bookkeeping.
      "$YOSYS" -Q -T -p "read_slang -f $ROOT/corev_apu/apu/Flist.apu_soc $ROOT/verif/tb/apu/tb_g6lc_apu_th.sv --top g6lc_apu_th_fixture -GEnable=$enabled; synth -top g6lc_apu_th_fixture -flatten -noabc; check -assert; stat; select -assert-none t:\$dlatch t:\$_DLATCH_*" \
        2>&1 | tee "$th_out/synth-$enabled.log"
      xbar_out="$OUT/xbar"
      mkdir -p "$xbar_out"
      "$VERILATOR" --lint-only --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
        -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
        "$ROOT/verif/tb/apu/apu_axi.vlt" -f "$ROOT/corev_apu/apu/Flist.apu_soc" \
        "$ROOT/verif/tb/apu/tb_g6lc_apu_xbar.sv" --top-module g6lc_apu_xbar_fixture \
        "-GEnable=1'b$enabled" 2>&1 | tee "$xbar_out/lint-$enabled.log"
      "$YOSYS" -Q -T -p "read_slang -f $ROOT/corev_apu/apu/Flist.apu_soc $ROOT/verif/tb/apu/tb_g6lc_apu_xbar.sv --top g6lc_apu_xbar_fixture -GEnable=$enabled; synth -top g6lc_apu_xbar_fixture -flatten -noabc; check -assert; stat; select -assert-none t:\$dlatch t:\$_DLATCH_*" \
        2>&1 | tee "$xbar_out/synth-$enabled.log"
      fwram_out="$OUT/fwram"
      mkdir -p "$fwram_out"
      "$VERILATOR" --lint-only --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
        -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
        "$ROOT/verif/tb/apu/apu_axi.vlt" -f "$ROOT/corev_apu/apu/Flist.apu_soc" \
        "$ROOT/verif/tb/apu/tb_g6lc_apu_fwram.sv" --top-module g6lc_apu_fwram_fixture \
        "-GEnable=1'b$enabled" -GRamBytes=4096 2>&1 | tee "$fwram_out/lint-$enabled.log"
      # Screening synth uses 4 KiB; sim uses the 256 KiB ApuHarness window.
      # Disabled fwram is an AXI4 error slave.
      "$YOSYS" -Q -T -p "read_slang -f $ROOT/corev_apu/apu/Flist.apu_soc $ROOT/verif/tb/apu/tb_g6lc_apu_fwram.sv --top g6lc_apu_fwram_fixture -GEnable=$enabled -GRamBytes=4096; hierarchy -top g6lc_apu_fwram_fixture; flatten; proc; opt; memory_collect; check -assert; stat; synth -top g6lc_apu_fwram_fixture -noabc; check -assert; stat; select -assert-none t:\$dlatch t:\$_DLATCH_*" \
        2>&1 | tee "$fwram_out/synth-$enabled.log"
      load_out="$OUT/th_load"
      mkdir -p "$load_out"
      "$VERILATOR" --lint-only --timing --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
        -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
        "$ROOT/verif/tb/apu/apu_axi.vlt" -f "$ROOT/corev_apu/apu/Flist.apu_soc" \
        "$ROOT/verif/tb/apu/tb_g6lc_apu_th_load.sv" --top-module g6lc_apu_th_load_fixture \
        "-GEnable=1'b$enabled" -GRamBytes=4096 2>&1 | tee "$load_out/lint-$enabled.log"
      "$YOSYS" -Q -T -p "read_slang -f $ROOT/corev_apu/apu/Flist.apu_soc $ROOT/verif/tb/apu/tb_g6lc_apu_th_load.sv --top g6lc_apu_th_load_fixture -GEnable=$enabled -GRamBytes=4096; hierarchy -top g6lc_apu_th_load_fixture; flatten; proc; opt; memory_collect; check -assert; stat; synth -top g6lc_apu_th_load_fixture -noabc; check -assert; stat; select -assert-none t:\$dlatch t:\$_DLATCH_*" \
        2>&1 | tee "$load_out/synth-$enabled.log"
    done
  fi
  if [[ "${APU_EXEC:-0}" == 1 ]]; then
    for enabled in 0 1; do
      exec_out="$OUT/exec"
      mkdir -p "$exec_out"
      "$VERILATOR" --lint-only --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
        -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
        -Wno-BLKANDNBLK -Wno-UNOPTFLAT -Wno-LITENDIAN -Wno-WIDTHTRUNC \
        "$ROOT/verif/tb/apu/apu_axi.vlt" "$ROOT/verif/tb/apu/apu_exec.vlt" \
        -f "$ROOT/corev_apu/apu/Flist.apu_exec" \
        "$ROOT/verif/tb/apu/tb_g6lc_apu_exec.sv" --top-module g6lc_apu_exec_fixture \
        "-GEnable=1'b$enabled" 2>&1 | tee "$exec_out/lint-$enabled.log"
      extra_check=""
      if [[ "$enabled" == 0 ]]; then extra_check="; select -assert-none t:*"; fi
      "$YOSYS" -Q -T -p "read_slang -f $ROOT/corev_apu/apu/Flist.apu_exec $ROOT/verif/tb/apu/tb_g6lc_apu_exec.sv --top g6lc_apu_exec_fixture -GEnable=$enabled; synth -top g6lc_apu_exec_fixture -flatten -noabc; check -assert; stat; select -assert-none t:\$dlatch t:\$_DLATCH_* $extra_check" \
        2>&1 | tee "$exec_out/synth-$enabled.log"
      fw_out="$OUT/fw"
      mkdir -p "$fw_out"
      "$VERILATOR" --lint-only --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
        -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
        -Wno-BLKANDNBLK -Wno-UNOPTFLAT -Wno-LITENDIAN -Wno-WIDTHTRUNC \
        "$ROOT/verif/tb/apu/apu_axi.vlt" "$ROOT/verif/tb/apu/apu_exec.vlt" \
        -f "$ROOT/corev_apu/apu/Flist.apu_fw" \
        "$ROOT/verif/tb/apu/tb_g6lc_apu_fw.sv" --top-module g6lc_apu_fw_fixture \
        "-GEnable=1'b$enabled" 2>&1 | tee "$fw_out/lint-$enabled.log"
      # Disabled fw keeps AXI-lite response bookkeeping; FPnew is not instantiated.
      "$YOSYS" -Q -T -p "read_slang -f $ROOT/corev_apu/apu/Flist.apu_fw $ROOT/verif/tb/apu/tb_g6lc_apu_fw.sv --top g6lc_apu_fw_fixture -GEnable=$enabled; synth -top g6lc_apu_fw_fixture -flatten -noabc; check -assert; stat; select -assert-none t:\$dlatch t:\$_DLATCH_*" \
        2>&1 | tee "$fw_out/synth-$enabled.log"
    done
  fi
  for top in g6lc_apu_virtio_mmio g6lc_apu_top; do
    extra_check=""
    if [[ "$top" == g6lc_apu_top ]]; then extra_check="; select -assert-none t:*"; fi
    "$YOSYS" -Q -T -p "read_slang -f $ROOT/corev_apu/apu/Flist.apu --top $top; synth -top $top -noabc; check -assert; stat; select -assert-none t:\$dlatch t:\$_DLATCH_* $extra_check" \
      2>&1 | tee "$OUT/synth-$top.log"
  done
fi
