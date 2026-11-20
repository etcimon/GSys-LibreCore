#!/bin/bash
# Alternating A/B timing: baseline vs dev model, same ELF, same cycle cap
set -u
B=/opt/testharness/runs/hyp8-rfix131a-phantomprobe-aggregate-t2/output/model/Variane_testharness
D=/opt/testharness/runs/devcase-ab/model/Variane_testharness
E=/opt/testharness/runs/hyp8-firmware-r116/output/build-linux-mc/platform/generic/firmware/fw_payload.elf
cd /tmp
: > /tmp/rep.done
for i in 1 2 3 4 5 6; do
  for m in B D; do
    M=$B; [ "$m" = D ] && M=$D
    /usr/bin/time -f "REP $m $i %e" "$M" +debug_disable +quiet_axi +max-cycles=40000 +time_out=40000 +tohost_addr=0xdeadbeef "$E" > /dev/null 2>>/tmp/rep-all.time
  done
done
echo DONE >> /tmp/rep.done
