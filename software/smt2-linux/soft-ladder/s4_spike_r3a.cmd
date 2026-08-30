set -euo pipefail
. /opt/testharness/env.sh
SPIKE=/opt/testharness/toolchains/spike/bin/spike
ELF=/opt/testharness/runs/linux-g6lc64_server_math_v/fw_payload.elf
DTB2=/opt/testharness/repo/build-platform/workspace/smt2-linux/ariane-smt2.dtb
DTB4=/opt/testharness/repo/build-platform/workspace/smt2-linux/ariane-server-math-v.dtb
ISA=rv64imafdc_zicsr_zifencei
OUT=/opt/testharness/runs/s4-spike-r3a
mkdir -p "$OUT"
echo "=== spike -p2 smt2 dtb (30s) ==="
timeout 30 stdbuf -oL -eL "$SPIKE" -p2 --isa="$ISA" --dtb="$DTB2" \
  --param /top/log_commits:bool=false "$ELF" >"$OUT/p2.log" 2>&1 || echo "p2 rc=$?"
echo "--- p2 grep ---"
grep -aE 'OpenSBI|SMT2-OSBI|tohost|error|panic|FAIL|SUCCESS|Boot HART|hart' "$OUT/p2.log" | head -40
echo "p2 bytes=$(wc -c < "$OUT/p2.log")"
echo "=== spike -p4 server-math-v dtb (30s) ==="
timeout 30 stdbuf -oL -eL "$SPIKE" -p4 --isa="$ISA" --dtb="$DTB4" \
  --param /top/log_commits:bool=false "$ELF" >"$OUT/p4.log" 2>&1 || echo "p4 rc=$?"
echo "--- p4 grep ---"
grep -aE 'OpenSBI|SMT2-OSBI|tohost|error|panic|FAIL|SUCCESS|Boot HART|hart' "$OUT/p4.log" | head -40
echo "p4 bytes=$(wc -c < "$OUT/p4.log")"
