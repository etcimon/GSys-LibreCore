#!/bin/bash
# Rebuild held ELF from known-good pin (bc7ed11d) via SOFT_HART_INIT+PLAT peels.
# Do NOT re-run mk_plat_skip from diag unless pin md5 is re-validated.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
BUILD=software/smt2-linux/soft-ladder/build
PIN_GOOD="$BUILD/fw_payload_r3a_c15_plat_skip.pin-bc7ed11d.elf"
PIN="$BUILD/fw_payload_r3a_c15_plat_skip.elf"
HELD="$BUILD/fw_payload_r3a_c15_plat_skip.held.elf"
WANT=bc7ed11dab17454fd147e4927ba07fef

if [[ -f "$PIN_GOOD" ]]; then
  cp "$PIN_GOOD" "$PIN"
fi
got=$(md5sum "$PIN" | awk '{print $1}')
if [[ "$got" != "$WANT" ]]; then
  echo "ERROR: pin md5 $got != $WANT — abort (do not build held from drifted pin)"
  exit 1
fi
echo "pin ok $got"

# remove stale held so ensure path rebuilds
rm -f "$HELD"

python3 - "$PIN" "$HELD" <<'PY'
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

# SOFT_HART_INIT: sbi_hart_init entry -> li a0,0; ret
struct.pack_into("<I", data, vf(0x8000CCCC), addi(10, 0, 0))
struct.pack_into("<I", data, vf(0x8000CCD0), jalr(0, 1, 0))
# SOFT_PLAT_OPS: c.li a0,0 at platform c.jalr a5 sites
for va in (
    0x800017E0,
    0x800016A8,
    0x80001778,
    0x800017C2,
    0x80005424,
    0x80005492,
    0x800054AE,
    0x80005AD0,
    0x80005B70,
):
    struct.pack_into("<H", data, vf(va), 0x4501)
# I4u: do NOT stub by_offset here. That peel (I4q held c06e9bd3) reached
# domain_dump/spin_lock and wrote incomplete cookie 51b1c001. Hold green is
# SOFT_HART_INIT+PLAT only (md5 8b6b310e).
held.write_bytes(data)
print("wrote", held, "md5", __import__("hashlib").md5(data).hexdigest())
PY

md5sum "$PIN" "$HELD"
