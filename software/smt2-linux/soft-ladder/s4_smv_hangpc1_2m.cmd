set -euo pipefail
H=/opt/testharness/work/work-ver-server-math-v-B/Variane_testharness
ELF=/opt/testharness/runs/linux-g6lc64_server_math_v/fw_payload.elf
OUT=/opt/testharness/runs/s4-smv-hangpc1-2m
mkdir -p "$OUT"
unset CVA6_TRACE CVA6_TRACE_SPEC CVA6_TRACE_FILE CVA6_COOKIE_EXIT CVA6_SOAK_EXIT
export CVA6_WFI_EXIT=0 CVA6_TRAP_DUMP=1
ls -l "$H" "$ELF"
"$H" +time_out=2000000 +max-cycles=2000000 +debug_disable +quiet_axi \
  +tohost_addr=0x80041730 "$ELF" >"$OUT/run-B.log" 2>&1
echo rc=$?
grep -E "hangpc|SUCCESS|FAILED|tohost" "$OUT/run-B.log" | tail -n 20
