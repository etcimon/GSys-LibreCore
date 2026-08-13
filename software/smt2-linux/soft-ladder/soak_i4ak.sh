#!/bin/bash
# I4ak: FLU ALU0 result pairs with port0 trans_id.
set -uo pipefail
H=/mnt/e/cva6/work-ver-smt2-slfix/Variane_testharness
PIN=/mnt/e/cva6/software/smt2-linux/soft-ladder/build/fw_payload_r3a_c15_plat_skip.pin-bc7ed11d.elf
HELD=/mnt/e/cva6/software/smt2-linux/soft-ladder/build/fw_payload_r3a_c15_plat_skip.held-nobyoff.elf
if [[ ! -f "$HELD" ]]; then
  HELD=/mnt/e/cva6/software/smt2-linux/soft-ladder/build/fw_payload_r3a_c15_plat_skip.held.elf
fi
OUT=/tmp/cva6-i4ak-soak
mkdir -p "$OUT"
export CVA6_TRAP_DUMP=1
run() {
  local tag="$1" elf="$2"
  echo "=== $tag ==="
  set +e
  "$H" +time_out=6000000 +max-cycles=6000000 +debug_disable +tohost_addr=0x80041730 \
    "$elf" >"$OUT/veri_$tag.log" 2>&1
  local rc=$?
  set -e
  if grep -qE '\[1000\]=[0-9a-fA-F]*51b1babe' "$OUT/veri_$tag.log"; then
    echo "CLASSIFY=SUCCESS $tag rc=$rc"
  else
    echo "CLASSIFY=FAIL $tag rc=$rc"
  fi
  grep -E '\[first0\]|\[hangpc\]|\[trapdump\]' "$OUT/veri_$tag.log" | tail -8 || true
  echo
}
run hold "$HELD"
run nat "$PIN"
echo DONE
