#!/bin/bash
FW=/opt/testharness/runs/hyp8-firmware-r116/output/build-linux-mc/platform/generic/firmware/fw_payload.elf
A=/opt/testharness/runs/devctrlz-ab/model
B=/opt/testharness/runs/devdeadz-ab/model
LOG=/tmp/deadz_ab2_results.log
: > $LOG
for rep in 1 2 3; do
  for m in A B; do
    d=$A; [ $m = B ] && d=$B
    ins=$(cd $d && perf stat -e instructions:u -x, -- ./Variane_testharness +debug_disable +quiet_axi +max-cycles=50000 +time_out=50000 $FW 2>&1 | grep -oE '^[0-9]+' | head -1)
    echo "$m rep$rep insns=$ins $(date +%H:%M)" >> $LOG
  done
done
echo AB2_DONE >> $LOG
