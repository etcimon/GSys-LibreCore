#!/bin/bash
# Wall-clock + perf probe of an EXISTING model binary (no rebuild).
# Usage: probe_wc.sh <binary> <tag> [maxcycles]
set -u
BIN="$1"; TAG="$2"; MC="${3:-150000}"
FW=/opt/testharness/runs/hyp8-firmware-r116/output/build-linux-mc/platform/generic/firmware/fw_payload.elf
T0=$(date +%s.%N)
env G6LC_METRICS_SIDECAR=/tmp/m-${TAG}.json perf stat -e instructions:u,cycles:u -x, -- \
  "$BIN" +debug_disable +quiet_axi +max-cycles=$MC +time_out=$MC "$FW" \
  > /tmp/fw-${TAG}-out.log 2> /tmp/fw-${TAG}-perf.log
T1=$(date +%s.%N)
echo "WALLCLOCK_${TAG}: $(echo "$T1 - $T0" | bc)s" | tee /tmp/fw-${TAG}-time.txt
echo "SIDECAR_${TAG}: $(cat /tmp/m-${TAG}.json 2>/dev/null)"
grep -E "instructions:u|cycles:u" /tmp/fw-${TAG}-perf.log | tail -2
