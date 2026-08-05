#!/usr/bin/env bash
set -uo pipefail
export LD_LIBRARY_PATH=/mnt/e/cva6/build-platform/workspace/tooling/spike/lib:${LD_LIBRARY_PATH:-}
cd /mnt/e/cva6
H=/mnt/e/cva6/work-ver/Variane_testharness
P=/mnt/e/cva6/build-platform/workspace/smt2-linux/fw_payload.elf
LOG=/mnt/e/cva6/monorepo-soak/emit-2p5ghz-opensbi-mc-20260804-133937.log
echo "[emit-opensbi] start $(date -Is)" | tee "$LOG"
echo "[emit-opensbi] harness=$H" | tee -a "$LOG"
echo "[emit-opensbi] payload=$P" | tee -a "$LOG"
echo "[emit-opensbi] +time_out=20000000 +debug_disable +tohost_addr=0x80041730" | tee -a "$LOG"
set +e
"$H" +time_out=20000000 +debug_disable +tohost_addr=0x80041730 "$P" 2>&1 | tee -a "$LOG"
rc=${PIPESTATUS[0]}
set -e
echo "[emit-opensbi] exit=$rc $(date -Is)" | tee -a "$LOG"
# Classify result
if grep -qE 'SUCCESS|PASS|tohost=0*1\b' "$LOG" 2>/dev/null; then
  echo "[emit-opensbi] CLASSIFY=SUCCESS"
elif grep -qiE 'timeout|TIMED.?OUT|Simulation timeout' "$LOG" 2>/dev/null; then
  echo "[emit-opensbi] CLASSIFY=TIMEOUT"
else
  echo "[emit-opensbi] CLASSIFY=OTHER rc=$rc"
fi
exit $rc