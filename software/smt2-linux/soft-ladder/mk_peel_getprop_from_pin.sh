#!/bin/bash
# I4bo: PEEL fdt_get_property_by_offset_ prologue on pin bc7ed11d.
# Pin has jal@12e26 (soft skip). Restore natural c.addi16sp/c.sdsp from
# diag text (same 4B as namelen_ @136f0). Do NOT run full mk_plat_skip
# on drifted diag 8169b747.
set -euo pipefail
BUILD=/mnt/e/cva6/software/smt2-linux/soft-ladder/build
PIN="$BUILD/fw_payload_r3a_c15_plat_skip.pin-bc7ed11d.elf"
OUT="$BUILD/fw_payload_r3a_c15_plat_skip.peel-getprop.elf"
WANT=bc7ed11dab17454fd147e4927ba07fef
got=$(md5sum "$PIN" | awk '{print $1}')
if [[ "$got" != "$WANT" ]]; then
  echo "ERROR: pin md5 $got != $WANT"
  exit 1
fi
python3 - "$PIN" "$OUT" <<'PY'
import struct, hashlib, sys
from pathlib import Path
pin, dst = Path(sys.argv[1]), Path(sys.argv[2])
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

BYOFF = 0x80012E26
old = data[vf(BYOFF):vf(BYOFF)+4]
# Natural prologue (diag / namelen_): c.addi16sp; c.sdsp s0
nat = bytes.fromhex("797122f0")
print("by_offset before", old.hex(), "after", nat.hex())
data[vf(BYOFF):vf(BYOFF)+4] = nat
dst.write_bytes(data)
print("wrote", dst, hashlib.md5(data).hexdigest())
PY
md5sum "$PIN" "$OUT"
