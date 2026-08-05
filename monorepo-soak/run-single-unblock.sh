#!/usr/bin/env bash
set -euo pipefail
export ROOT=/mnt/e/cva6
export SPIKE_INSTALL_DIR=$ROOT/build-platform/workspace/tooling/spike
export LD_LIBRARY_PATH=$SPIKE_INSTALL_DIR/lib:${LD_LIBRARY_PATH:-}
export CVA6_MC_PC_PROBE=1
H=$ROOT/work-ver/Variane_testharness
ELF=$ROOT/build-platform/workspace/smt2-linux/fw_payload.elf
LOG=$ROOT/monorepo-soak/hang6-single-unblock.log
echo "[single-unblock] start $(date) size=$(stat -c%s $H)"
# 2M cycles: past hang-6 (~125k) toward later hang / SUCCESS
"$H" +time_out=2000000 +debug_disable +tohost_addr=0x80041730 "$ELF" 2>&1 | tee "$LOG"
echo "[single-unblock] done"
echo "=== platform WFI (hang-6)? ==="
grep -c "0x800074e" "$LOG" || true
echo "=== first platform WFI sample ==="
grep "0x800074e" "$LOG" | head -1 || echo "(none)"
echo "=== last non-wfi samples ==="
grep "\[mc_pc\]" "$LOG" | grep -v "0x800074e" | tail -8 || true
echo "=== end state ==="
grep "\[mc_pc\]" "$LOG" | tail -3
echo "=== outcome ==="
grep -E "FAILED|SUCCESS" "$LOG" | tail -5
