#!/bin/bash
# PGO-independent dynamic-instruction A/B: baseline-PGO vs dev-noPGO model.
# Same ELF + args as ab_timing.sh; perf counts retired instructions (deterministic
# under --seed=1), so delta isolates the case-table transform from PGO layout.
set -u
B=/opt/testharness/runs/hyp8-rfix131a-phantomprobe-aggregate-t2/output/model/Variane_testharness
D=/opt/testharness/runs/devcase-ab/model/Variane_testharness.nopgo
E=/opt/testharness/runs/hyp8-firmware-r116/output/build-linux-mc/platform/generic/firmware/fw_payload.elf
OUT=/tmp/perf-ab.txt
: > "$OUT"
for i in 1 2; do
  for m in B D; do
    M=$B; [ "$m" = D ] && M=$D
    echo "=== REP $m $i $(date +%T) ===" >> "$OUT"
    perf stat -e instructions,cycles,branches,branch-misses -- "$M" \
      +debug_disable +quiet_axi +max-cycles=40000 +time_out=40000 \
      +tohost_addr=0xdeadbeef "$E" >/dev/null 2>>"$OUT"
  done
done
echo DONE >> "$OUT"
