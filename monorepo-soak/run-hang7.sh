#!/usr/bin/env bash
set -euo pipefail
export ROOT=/mnt/e/cva6
export SPIKE_INSTALL_DIR=$ROOT/build-platform/workspace/tooling/spike
export LD_LIBRARY_PATH=$SPIKE_INSTALL_DIR/lib:${LD_LIBRARY_PATH:-}
export CVA6_MC_PC_PROBE=1
H=$ROOT/work-ver/Variane_testharness
ELF=$ROOT/build-platform/workspace/smt2-linux/fw_payload.elf
LOG=$ROOT/monorepo-soak/hang7.log
echo "[hang7] start $(date)"
# 400k: past platform (~100k) into sbi_init / hang-7
"$H" +time_out=400000 +debug_disable +tohost_addr=0x80041730 "$ELF" 2>&1 | tee "$LOG"
echo "[hang7] done"
echo "=== platform WFI count ==="
grep -c "0x800074e" "$LOG" || true
echo "=== hart_cnt progression ==="
grep -oE "hart_cnt=0x[0-9a-f]+ hid0=0x[0-9a-f]+ hid1=0x[0-9a-f]+" "$LOG" | sort | uniq -c | head -20
echo "=== sbi_init / hang samples ==="
grep -E "c0.npc=0x800006e|c0.npc=0x8000ee|c0.npc=0x800003c8|mcause=0x[1-9]" "$LOG" | head -20
echo "=== last 5 mc_pc ==="
grep "\[mc_pc\]" "$LOG" | tail -5
echo "=== outcome ==="
grep -E "FAILED|SUCCESS" "$LOG" | tail -3
