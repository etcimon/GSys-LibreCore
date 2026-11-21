#!/bin/bash
# Collect all A/B probe results into /tmp/all-results.txt as they land.
# Waits up to ~4h. Each result: sidecar json + perf insns/cycles + wallclock.
declare -A TAGS=( [t4wc]="threads4-baseline" [t2_150]="threads2" [pf150]="pubflat-noassert" [cv150]="cv-sleep(reverted)" [g16]="gcc16" [dc150]="devclean-baseline" )
OUT=/tmp/all-results.txt
: > "$OUT"
end=$((SECONDS + 14400))
while [ $SECONDS -lt $end ]; do
  alldone=1
  for t in "${!TAGS[@]}"; do
    if [ -f "/tmp/m-$t.json" ] && ! grep -q "^=== $t ===" "$OUT" 2>/dev/null; then
      {
        echo "=== $t (${TAGS[$t]}) ==="
        echo "sidecar: $(cat /tmp/m-$t.json 2>/dev/null)"
        grep -E "instructions:u|cycles:u" "/tmp/fw-$t-perf.log" 2>/dev/null | tail -2
        [ -f "/tmp/fw-$t-time.txt" ] && cat "/tmp/fw-$t-time.txt"
        echo ""
      } >> "$OUT"
    fi
    [ -f "/tmp/m-$t.json" ] || alldone=0
  done
  [ $alldone -eq 1 ] && break
  sleep 30
done
echo "COLLECT_DONE $(date -u +%FT%TZ)" >> "$OUT"
cat "$OUT"
