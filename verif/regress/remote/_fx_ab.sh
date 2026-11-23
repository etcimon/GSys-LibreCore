#!/bin/bash
FW=/opt/testharness/runs/hyp8-firmware-r116/output/build-linux-mc/platform/generic/firmware/fw_payload.elf
D=/opt/testharness/runs/devdeadz-ab/model
LOG=/tmp/fx_ab_results.log
: > $LOG
for rep in 1 2 3; do
  for m in OLD NEW; do
    bin=/tmp/Variane_deadz_nofx; [ $m = NEW ] && bin=$D/Variane_testharness
    ins=$(cd $D && perf stat -e instructions:u -x, -- $bin +debug_disable +quiet_axi +max-cycles=50000 +time_out=50000 $FW 2>&1 | grep -oE '^[0-9]+' | head -1)
    echo "$m rep$rep insns=$ins $(date +%H:%M)" >> $LOG
  done
done
echo FX_AB_DONE >> $LOG
