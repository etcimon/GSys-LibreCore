#!/bin/bash
# Force relink of g6lc_tb.cpp into work-ver-server-math-v-B.
set -euo pipefail
W=/opt/testharness/work/work-ver-server-math-v-B
echo "before:"
ls -l "$W/Variane_testharness" "$W"/*g6lc_tb* 2>/dev/null || true
find "$W" -name '*g6lc_tb*' -print 2>/dev/null | head
# Verilator names the TB sim_main / testharness.
find "$W" -name '*testharness*.o' -o -name '*g6lc_tb*' -o -name '*sim_main*' | head -40
rm -f "$W"/Variane_testharness
# Delete TB objects so make cannot skip.
find "$W" -name '*.o' -print | while read f; do
  case "$f" in
    *tb*|*testharness*|*g6lc_tb*|*sim_main*) echo "rm $f"; rm -f "$f" ;;
  esac
done
echo "objects removed, rebuild via proxy next"
