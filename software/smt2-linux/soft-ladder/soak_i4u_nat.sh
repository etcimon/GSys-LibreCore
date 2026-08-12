#!/bin/bash
set -uo pipefail
H=/mnt/e/cva6/work-ver-smt2-slfix/Variane_testharness
PIN=/mnt/e/cva6/software/smt2-linux/soft-ladder/build/fw_payload_r3a_c15_plat_skip.pin-bc7ed11d.elf
OUT=/tmp/cva6-i4u-nat
mkdir -p "$OUT"
export CVA6_TRAP_DUMP=1
echo "=== nat ==="
set +e
"$H" +time_out=6000000 +max-cycles=6000000 +debug_disable +tohost_addr=0x80041730 \
  "$PIN" >"$OUT/veri_nat.log" 2>&1
rc=$?
set -e
if grep -qE '\[1000\]=[0-9a-fA-F]*51b1babe' "$OUT/veri_nat.log"; then
  echo "CLASSIFY=SUCCESS nat rc=$rc"
else
  echo "CLASSIFY=FAIL nat rc=$rc"
fi
grep -E '\[first0\]|\[hangpc\]|\[trapdump\]' "$OUT/veri_nat.log" | tail -8 || true
echo DONE
