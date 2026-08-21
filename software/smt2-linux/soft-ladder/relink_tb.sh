#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# TB-only relink of work-ver-smt2-slfix (g6lc_tb.cpp soak fork).
# Does NOT delete the Verilator model — use rebuild_slfix.sh after RTL.
set -uo pipefail
export PATH="/root/tools/verilator-v5.008/bin:/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin:/root/tools/spike/bin:${PATH}"
export LD_LIBRARY_PATH="/root/tools/spike/lib:${LD_LIBRARY_PATH:-}"
export SPIKE_INSTALL_DIR=/root/tools/spike
export RISCV=/root/tools/spike
export CVA6_REPO_DIR=/mnt/e/cva6
export CROSS_COMPILE=riscv-none-elf-
cd /mnt/e/cva6
LOG=/mnt/e/cva6/software/smt2-linux/soft-ladder/build/relink_tb.log
echo "relink_tb start $(date)" | tee "$LOG"
make verilate verilator="verilator --no-timing" target=g6lc64_smt2 \
  ver-library=work-ver-smt2-slfix CVA6_REPO_DIR=/mnt/e/cva6 \
  RISCV=/root/tools/spike SPIKE_INSTALL_DIR=/root/tools/spike >>"$LOG" 2>&1
rc=$?
echo "relink rc=$rc $(date)" | tee -a "$LOG"
file work-ver-smt2-slfix/Variane_testharness | tee -a "$LOG"
md5sum work-ver-smt2-slfix/Variane_testharness | tee -a "$LOG"
exit $rc
