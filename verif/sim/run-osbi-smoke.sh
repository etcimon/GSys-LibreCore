#!/usr/bin/env bash
# Quick dual-hart OpenSBI smoke (log_commits=0 fast path).
set +e
pkill -9 -f 'tooling/spike/bin/spike' 2>/dev/null || true
sleep 1

ROOT="${ROOT:-/mnt/e/cva6}"
SPIKE="${SPIKE:-$ROOT/build-platform/workspace/tooling/spike/bin/spike}"
FW="${FW:-$ROOT/build-platform/workspace/smt2-linux/fw_payload.elf}"
DTB="${DTB:-$ROOT/build-platform/workspace/smt2-linux/ariane-smt2.dtb}"
ISA="${ISA:-rv64imafdc_zicsr_zifencei}"
LOG="${LOG:-/tmp/osbi-smoke2.log}"
TIMEOUT_S="${TIMEOUT_S:-180}"

rm -f "$LOG"
echo "starting dual-hart boot $(date -Is)"
echo "  spike=$SPIKE"
echo "  fw=$FW"
echo "  dtb=$DTB"

timeout "$TIMEOUT_S" stdbuf -oL -eL "$SPIKE" -p2 --isa="$ISA" --dtb="$DTB" \
  --param /top/log_commits:bool=false "$FW" >"$LOG" 2>&1 &
SPID=$!

for i in $(seq 1 60); do
  sleep 3
  if grep -aq 'SMT2-OSBI-OK' "$LOG" 2>/dev/null; then
    echo "GOT OK at poll $i ($(date -Is))"
    sleep 2
    break
  fi
  if ! kill -0 "$SPID" 2>/dev/null; then
    echo "spike exited at poll $i"
    break
  fi
  SZ=$(wc -c <"$LOG" 2>/dev/null || echo 0)
  LAST=$(grep -aE 'G6LC_|OpenSBI|SMT2|Platform |error' "$LOG" 2>/dev/null | tail -1)
  echo "poll $i size=$SZ last=$LAST"
done

wait "$SPID" 2>/dev/null
RC=$?
echo "RC=$RC"
echo "=== markers ==="
grep -aE 'OpenSBI|G6LC_|SMT2|Platform |Boot HART|Domain0|Firmware|error|panic' "$LOG" || true
echo "=== log size ==="
wc -c "$LOG"
if grep -aq 'SMT2-OSBI-OK' "$LOG"; then
  echo "SMOKE PASS"
  exit 0
fi
echo "SMOKE FAIL"
exit 1
