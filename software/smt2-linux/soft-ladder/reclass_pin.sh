#!/bin/bash
set -uo pipefail
OUT=/tmp/cva6-i4s-pin
echo "=== reclass pin soaks ==="
for t in hold1 hold2 pin_softgetprop1; do
  log="$OUT/veri_$t.log"
  if [[ ! -f "$log" ]]; then
    echo "$t MISSING"
    continue
  fi
  if grep -qE '\[1000\]=[0-9a-fA-F]*51b1babe' "$log" || grep -qE '\[1000\]=0*51b1babe' "$log"; then
    echo "$t SUCCESS"
  else
    echo "$t FAIL"
  fi
  grep -E 'plat_hc=|coldboot|\[1000\]=|\[1068\]=|hangpc|51b1' "$log" | tail -8
  echo
done
echo "=== outer log tail ==="
tail -20 /tmp/i4s_pin_soaks.log
echo "=== processes ==="
pgrep -af Variane || true
pgrep -af run_i4s_pin || true
