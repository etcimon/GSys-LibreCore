#!/usr/bin/env bash
set -euo pipefail
export ROOT=/mnt/e/cva6
export SPIKE_INSTALL_DIR=$ROOT/build-platform/workspace/tooling/spike
export LD_LIBRARY_PATH=$SPIKE_INSTALL_DIR/lib:${LD_LIBRARY_PATH:-}
export CVA6_MC_PC_PROBE=1
H=$ROOT/work-ver/Variane_testharness
ELF=$ROOT/build-platform/workspace/smt2-linux/fw_payload.elf
LOG=$ROOT/monorepo-soak/hang6-nralu1.log
echo "[hang6-nralu1] start $(date) harness=$(ls -la $H | awk '{print $5,$6,$7,$8,$9}')"
# 400k cycles: hang-6 historically ~125k
"$H" +time_out=400000 +debug_disable +tohost_addr=0x80041730 "$ELF" 2>&1 | tee "$LOG"
echo "[hang6-nralu1] done exit=${PIPESTATUS[0]}"
echo "=== summary ==="
grep -E "0x800074e|SUCCESS|FAILED" "$LOG" | head -20 || true
echo "=== last non-platform-wfi samples ==="
grep "\[mc_pc\]" "$LOG" | grep -v "0x800074e" | tail -8 || true
echo "=== first platform WFI ==="
grep "0x800074e" "$LOG" | head -2 || true
echo "=== outcome ==="
grep -E "FAILED|SUCCESS" "$LOG" | tail -5 || true
