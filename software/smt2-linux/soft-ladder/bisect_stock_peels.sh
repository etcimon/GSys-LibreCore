#!/bin/bash
# Bisect stock residual on good pin bc7ed11d: hart_init vs plat ops peels.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
H="${SOFT_LADDER_HARNESS_BIN:-$ROOT/work-ver-smt2-slfix/Variane_testharness}"
OUT=/tmp/cva6-i4s-bisect
mkdir -p "$OUT"
export CVA6_TRAP_DUMP=1
TOHOST=0x80041730
BUILD=software/smt2-linux/soft-ladder/build
PIN_GOOD="$BUILD/fw_payload_r3a_c15_plat_skip.pin-bc7ed11d.elf"
PIN="$BUILD/fw_payload_r3a_c15_plat_skip.elf"
WANT=bc7ed11dab17454fd147e4927ba07fef

if [[ -f "$PIN_GOOD" ]]; then cp "$PIN_GOOD" "$PIN"; fi
got=$(md5sum "$PIN" | awk '{print $1}')
if [[ "$got" != "$WANT" ]]; then
  echo "bad pin $got"; exit 1
fi
echo "pin ok $got"

python3 - <<'PY'
import struct
from pathlib import Path

pin = Path("software/smt2-linux/soft-ladder/build/fw_payload_r3a_c15_plat_skip.elf")
base = pin.read_bytes()
e_phoff = struct.unpack_from("<Q", base, 32)[0]
e_phentsize = struct.unpack_from("<H", base, 54)[0]
e_phnum = struct.unpack_from("<H", base, 56)[0]
segs = []
for i in range(e_phnum):
    o = e_phoff + i * e_phentsize
    if struct.unpack_from("<I", base, o)[0] != 1:
        continue
    p_offset, p_vaddr, _, p_filesz, _, _ = struct.unpack_from("<QQQQQQ", base, o + 8)
    segs.append((p_offset, p_vaddr, p_filesz))

def vf(data, va):
    for off, v, fs in segs:
        if v <= va < v + fs:
            return off + (va - v)
    raise ValueError(hex(va))

def addi(rd, rs1, imm12):
    if imm12 < 0:
        imm12 = (1 << 12) + imm12
    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (rd << 7) | 0x13

def jalr(rd, rs1, imm12=0):
    if imm12 < 0:
        imm12 = (1 << 12) + imm12
    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (rd << 7) | 0x67

PLAT = (
    0x800017E0, 0x800016A8, 0x80001778, 0x800017C2,
    0x80005424, 0x80005492, 0x800054AE, 0x80005AD0, 0x80005B70,
)

def build(name, hart_init=False, plat=False, irqchip_only=False):
    data = bytearray(base)
    if hart_init:
        struct.pack_into("<I", data, vf(data, 0x8000CCCC), addi(10, 0, 0))
        struct.pack_into("<I", data, vf(data, 0x8000CCD0), jalr(0, 1, 0))
    if plat:
        for va in PLAT:
            struct.pack_into("<H", data, vf(data, va), 0x4501)
    elif irqchip_only:
        struct.pack_into("<H", data, vf(data, 0x800017E0), 0x4501)
    out = Path(f"/tmp/cva6-i4s-bisect/elf_{name}.elf")
    out.write_bytes(data)
    print("wrote", out, "hart_init", hart_init, "plat", plat, "irqchip_only", irqchip_only)

# A: stock pin (soft getprop only) — already FAIL IAF @129f4
# B: SOFT_HART_INIT only
build("hart_only", hart_init=True, plat=False)
# C: SOFT_PLAT_OPS only (natural hart_init)
build("plat_only", hart_init=False, plat=True)
# D: SOFT_HART_INIT + irqchip only
build("hart_irqchip", hart_init=True, plat=False, irqchip_only=True)
# E: full hold peels
build("hold_full", hart_init=True, plat=True)
print("elfs ready")
PY

run_soak() {
  local tag="$1" elf="$2" cycles="${3:-7000000}"
  echo "=== RUN $tag ==="
  set +e
  "$H" +time_out="$cycles" +max-cycles="$cycles" +debug_disable \
    +tohost_addr="$TOHOST" "$elf" >"$OUT/veri_$tag.log" 2>&1
  local rc=$?
  set -e
  if grep -qE '\[1000\]=[0-9a-fA-F]*51b1babe' "$OUT/veri_$tag.log"; then
    echo "CLASSIFY=SUCCESS $tag rc=$rc"
  else
    echo "CLASSIFY=FAIL $tag rc=$rc"
  fi
  grep -E '\[trapdump\]|\[hangpc\]|51b1|coldboot|plat_hc' "$OUT/veri_$tag.log" | tail -8 || true
  echo
}

# Stock pin already logged as pin_softgetprop1; re-run briefly only if needed
run_soak stock "$PIN" 7000000
run_soak hart_only "$OUT/elf_hart_only.elf" 7000000
run_soak plat_only "$OUT/elf_plat_only.elf" 7000000
run_soak hart_irqchip "$OUT/elf_hart_irqchip.elf" 7000000
run_soak hold_full "$OUT/elf_hold_full.elf" 6000000

echo "=== SUMMARY ==="
for t in stock hart_only plat_only hart_irqchip hold_full; do
  log="$OUT/veri_$t.log"
  if grep -qE '\[1000\]=[0-9a-fA-F]*51b1babe' "$log" 2>/dev/null; then
    echo "$t SUCCESS"
  else
    mepc=$(grep -oE 'mepc=0x[0-9a-fA-F]+' "$log" 2>/dev/null | head -1 || true)
    mcause=$(grep -oE 'mcause=0x[0-9a-fA-F]+' "$log" 2>/dev/null | head -1 || true)
    phc=$(grep -oE 'plat_hc=[0-9]+' "$log" 2>/dev/null | head -1 || true)
    echo "$t FAIL $mepc $mcause $phc"
  fi
done
echo DONE
