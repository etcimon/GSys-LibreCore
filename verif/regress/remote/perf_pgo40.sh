#!/bin/bash
# Steady-state core-cycle A/B at 40K cap (where the case-table insn win lives).
# One rep per binary — counts are deterministic enough; wall noise irrelevant.
set -u
B=/opt/testharness/runs/hyp8-rfix131a-phantomprobe-aggregate-t2/output/model/Variane_testharness
D=/opt/testharness/runs/devcase-ab/model/Variane_testharness
E=/opt/testharness/runs/hyp8-firmware-r116/output/build-linux-mc/platform/generic/firmware/fw_payload.elf
OUT=/tmp/perf-pgo40.txt
: > "$OUT"
for m in B D; do
  M=$B; [ "$m" = D ] && M=$D
  echo "=== REP $m 40K $(date +%T) ===" >> "$OUT"
  perf stat -e instructions,cycles,branches,branch-misses -- "$M" \
    +debug_disable +quiet_axi +max-cycles=40000 +time_out=40000 \
    +tohost_addr=0xdeadbeef "$E" >/dev/null 2>>"$OUT"
done
echo DONE >> "$OUT"
