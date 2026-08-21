#!/bin/bash
# SPDX-License-Identifier: MIT
# Generic forced rebuild of work-ver-smt2-slfix (unlink generated model).
# Usage: bash rebuild_slfix.sh [tag]
#   tag is only for the log name (default: slfix).
set -uo pipefail
export PATH="/root/tools/verilator-v5.008/bin:/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin:/root/tools/spike/bin:${PATH}"
export LD_LIBRARY_PATH="/root/tools/spike/lib:${LD_LIBRARY_PATH:-}"
export SPIKE_INSTALL_DIR=/root/tools/spike
export RISCV=/root/tools/spike
export CVA6_REPO_DIR=/mnt/e/cva6
export CROSS_COMPILE=riscv-none-elf-
TAG="${1:-slfix}"
cd /mnt/e/cva6
LOG=/mnt/e/cva6/software/smt2-linux/soft-ladder/build/rb_slfix_${TAG}.log
echo "rebuild $TAG start $(date)" | tee "$LOG"
rm -f work-ver-smt2-slfix/Variane_testharness \
      work-ver-smt2-slfix/V*__ALL.a \
      work-ver-smt2-slfix/*.o
rm -f work-ver-smt2-slfix/Variane_testharness*.cpp \
      work-ver-smt2-slfix/Variane_testharness*.h \
      work-ver-smt2-slfix/Variane_testharness.mk \
      work-ver-smt2-slfix/Variane_testharness__verFiles.dat \
      work-ver-smt2-slfix/*.d
echo "forced unlink generated model $(date)" | tee -a "$LOG"
make verilate verilator="verilator --no-timing" target=g6lc64_smt2 \
  ver-library=work-ver-smt2-slfix CVA6_REPO_DIR=/mnt/e/cva6 \
  RISCV=/root/tools/spike SPIKE_INSTALL_DIR=/root/tools/spike >>"$LOG" 2>&1
rc=$?
echo "rebuild rc=$rc $(date)" | tee -a "$LOG"
file work-ver-smt2-slfix/Variane_testharness | tee -a "$LOG"
md5sum work-ver-smt2-slfix/Variane_testharness | tee -a "$LOG"
exit $rc
