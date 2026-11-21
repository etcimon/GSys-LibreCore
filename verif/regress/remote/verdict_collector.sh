#!/bin/bash
# verdict_collector: watch for the pending A/B probes, compute deltas vs the
# devclean control (5.294e12 insns / 3.110e13 cycles, retired [4835,0]), and
# append one verdict line per result to /tmp/verdicts.txt. Lets the agent
# check a single small file instead of re-parsing perf logs each turn.
set -u
BASE_I=5293790536311
BASE_C=31103517181261
declare -A DONE
OUT=/tmp/verdicts.txt
declare -A SPEC=( [simd150]=/tmp/fw-simd150-perf.log [t2_150]=/tmp/fw-t2_150-perf.log )
for i in $(seq 1 720); do   # ~6h at 30s
  alldone=1
  for tag in simd150 t2_150; do
    [ "${DONE[$tag]:-0}" = 1 ] && continue
    jf=/tmp/m-${tag}.json
    [ -f "$jf" ] || { alldone=0; continue; }
    pf=${SPEC[$tag]}
    ins=$(grep 'instructions:u' "$pf" 2>/dev/null | tail -1 | cut -d, -f1)
    cyc=$(grep 'cycles:u' "$pf" 2>/dev/null | tail -1 | cut -d, -f1)
    ret=$(grep -oE '"retired":\[[0-9,]+\]' "$jf" 2>/dev/null | head -1)
    if [ -n "$ins" ] && [ -n "$cyc" ]; then
      di=$(awk -v a="$ins" -v b="$BASE_I" 'BEGIN{printf "%.2f",(a-b)/b*100}')
      dc=$(awk -v a="$cyc" -v b="$BASE_C" 'BEGIN{printf "%.2f",(a-b)/b*100}')
      echo "$(date -u +%FT%TZ) $tag insns=$ins (${di}%) cycles=$cyc (${dc}%) $ret" >> "$OUT"
      DONE[$tag]=1
    else
      alldone=0
    fi
  done
  [ "$alldone" = 1 ] && break
  sleep 30
done
echo "VERDICT_COLLECTOR_DONE $(date -u +%FT%TZ)" >> "$OUT"
