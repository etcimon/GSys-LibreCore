#!/bin/bash
# Short PGO-vs-PGO core-cycle A/B: baseline-PGO vs dev-PGO (case-table).
# cycles:u is a count (CPI-inclusive), immune to wall-clock scheduling noise.
# 15K-cycle cap keeps each run ~2-3 min; insn counts stay >> noise floor.
set -u
B=/opt/testharness/runs/hyp8-rfix131a-phantomprobe-aggregate-t2/output/model/Variane_testharness
D=/opt/testharness/runs/devcase-ab/model/Variane_testharness
E=/opt/testharness/runs/hyp8-firmware-r116/output/build-linux-mc/platform/generic/firmware/fw_payload.elf
OUT=/tmp/perf-pgo-ab.txt
: > "$OUT"
for i in 1 2; do
  for m in B D; do
    M=$B; [ "$m" = D ] && M=$D
    echo "=== REP $m $i $(date +%T) ===" >> "$OUT"
    perf stat -e instructions,cycles,branches,branch-misses -- "$M" \
      +debug_disable +quiet_axi +max-cycles=15000 +time_out=15000 \
      +tohost_addr=0xdeadbeef "$E" >/dev/null 2>>"$OUT"
  done
done
echo DONE >> "$OUT"
