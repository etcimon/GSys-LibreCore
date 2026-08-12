#!/bin/bash
# Soaks on known-good pin bc7ed11d + held (SOFT_HART_INIT peels). No mk from diag.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
H="${SOFT_LADDER_HARNESS_BIN:-$ROOT/work-ver-smt2-slfix/Variane_testharness}"
OUT="${SOFT_LADDER_SOAK_OUT:-/tmp/cva6-i4s-pin}"
mkdir -p "$OUT"
export CVA6_TRAP_DUMP=1
TOHOST=0x80041730
BUILD="$ROOT/software/smt2-linux/soft-ladder/build"
WANT=bc7ed11dab17454fd147e4927ba07fef

bash "$ROOT/software/smt2-linux/soft-ladder/rebuild_held_from_pin.sh" | tee "$OUT/rebuild_held.log"
PIN="$BUILD/fw_payload_r3a_c15_plat_skip.elf"
HELD="$BUILD/fw_payload_r3a_c15_plat_skip.held.elf"
got=$(md5sum "$PIN" | awk '{print $1}')
if [[ "$got" != "$WANT" ]]; then
  echo "abort bad pin"
  exit 1
fi

# PEEL getprop: start from good pin, clear soft getprop stubs (restore natural)
# Soft getprop is at fdt_getprop_namelen @136f0 and fdt_get_property_namelen @3622
# as ret0 (c.li a0,0; c.jr ra) — PEEL means leave stock body from pin.
# The good pin already HAS soft getprop. PEEL requires un-patching or using
# original OpenSBI body. For PEEL we binary-restore from diag at those VAs only
# if diag matches; else mark PEEL as "use pin as soft; PEEL needs matching diag".
# Practical PEEL on good pin: run pin as soft-getprop baseline; for PEEL use
# mk only if we can verify. For now: soak hold dual + pin (soft getprop stock).

run_soak() {
  local tag="$1" elf="$2" cycles="${3:-6000000}"
  echo "=== RUN $tag cycles=$cycles ==="
  set +e
  "$H" +time_out="$cycles" +max-cycles="$cycles" +debug_disable \
    +tohost_addr="$TOHOST" "$elf" >"$OUT/veri_$tag.log" 2>&1
  local rc=$?
  set -e
  # Match full suite: word may be wider than 32b ([1000]=…51b1babe)
  if grep -qE '\[1000\]=[0-9a-fA-F]*51b1babe' "$OUT/veri_$tag.log"; then
    echo "CLASSIFY=SUCCESS $tag rc=$rc"
  else
    echo "CLASSIFY=FAIL $tag rc=$rc"
  fi
  grep -E '\[trapdump\]|\[hangpc\]|51b1|coldboot|plat_hc' "$OUT/veri_$tag.log" | tail -14 || true
  echo
}

echo "H=$H"
run_soak hold1 "$HELD" 6000000
run_soak hold2 "$HELD" 6000000
run_soak pin_softgetprop1 "$PIN" 8000000

# Natural hart_init on pin: pin already has natural hart_init (soft only getprop)
# Hold peels hart_init; pin path is the stock residual path for SL-A next.

echo "=== SUMMARY ==="
for t in hold1 hold2 pin_softgetprop1; do
  log="$OUT/veri_$t.log"
  if grep -qE '\[1000\]=[0-9a-fA-F]*51b1babe' "$log" 2>/dev/null; then
    echo "$t SUCCESS"
  else
    mepc=$(grep -oE 'mepc=0x[0-9a-f]+' "$log" 2>/dev/null | head -1 || true)
    mcause=$(grep -oE 'mcause=0x[0-9a-f]+' "$log" 2>/dev/null | head -1 || true)
    mtval=$(grep -oE 'mtval=0x[0-9a-f]+' "$log" 2>/dev/null | head -1 || true)
    echo "$t FAIL $mepc $mcause $mtval"
  fi
done
echo DONE
