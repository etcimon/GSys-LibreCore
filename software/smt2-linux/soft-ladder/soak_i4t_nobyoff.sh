#!/bin/bash
# I4t extra: hold = I4s peels only (SOFT_HART_INIT+PLAT, no by_offset stub).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
BUILD=software/smt2-linux/soft-ladder/build
PIN_GOOD="$BUILD/fw_payload_r3a_c15_plat_skip.pin-bc7ed11d.elf"
OUT_ELF="$BUILD/fw_payload_r3a_c15_plat_skip.held-nobyoff.elf"
WANT=bc7ed11dab17454fd147e4927ba07fef
got=$(md5sum "$PIN_GOOD" | awk '{print $1}')
if [[ "$got" != "$WANT" ]]; then
  echo "ERROR: pin md5 $got != $WANT"
  exit 1
fi
python3 - "$PIN_GOOD" "$OUT_ELF" <<'PY'
import struct, sys
from pathlib import Path
pin, held = Path(sys.argv[1]), Path(sys.argv[2])
data = bytearray(pin.read_bytes())
e_phoff = struct.unpack_from("<Q", data, 32)[0]
e_phentsize = struct.unpack_from("<H", data, 54)[0]
e_phnum = struct.unpack_from("<H", data, 56)[0]
segs = []
for i in range(e_phnum):
    o = e_phoff + i * e_phentsize
    if struct.unpack_from("<I", data, o)[0] != 1:
        continue
    p_offset, p_vaddr, _, p_filesz, _, _ = struct.unpack_from("<QQQQQQ", data, o + 8)
    segs.append((p_offset, p_vaddr, p_filesz))

def vf(va):
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

struct.pack_into("<I", data, vf(0x8000CCCC), addi(10, 0, 0))
struct.pack_into("<I", data, vf(0x8000CCD0), jalr(0, 1, 0))
for va in (
    0x800017E0, 0x800016A8, 0x80001778, 0x800017C2,
    0x80005424, 0x80005492, 0x800054AE, 0x80005AD0, 0x80005B70,
):
    struct.pack_into("<H", data, vf(va), 0x4501)
held.write_bytes(data)
print("wrote", held, "md5", __import__("hashlib").md5(data).hexdigest())
PY

H=/mnt/e/cva6/work-ver-smt2-slfix/Variane_testharness
OUT=/tmp/cva6-i4t-nobyoff
mkdir -p "$OUT"
export CVA6_TRAP_DUMP=1
echo "=== hold-nobyoff ==="
set +e
"$H" +time_out=6000000 +max-cycles=6000000 +debug_disable +tohost_addr=0x80041730 \
  "$OUT_ELF" >"$OUT/veri_hold.log" 2>&1
rc=$?
set -e
if grep -qE '\[1000\]=[0-9a-fA-F]*51b1babe' "$OUT/veri_hold.log"; then
  echo "CLASSIFY=SUCCESS hold-nobyoff rc=$rc"
else
  echo "CLASSIFY=FAIL hold-nobyoff rc=$rc"
fi
grep -E '\[first0\]|\[hangpc\]|\[trapdump\]' "$OUT/veri_hold.log" | tail -8 || true
echo DONE
