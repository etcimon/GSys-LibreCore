#!/bin/bash
# SPDX-License-Identifier: MIT
# S2 / SL-B: restore natural sbi_printf prologue on pin-bc7ed11d.
# Pin already has PEEL getprop (by_offset/namelen_ jal to probe) + natural
# next_tag + namelen addi-sp. Remaining soft is A980 jal → BANR cave @2C98.
# Do NOT run mk_plat_skip from diag.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
BUILD="$ROOT/software/smt2-linux/soft-ladder/build"
PIN="$BUILD/fw_payload_r3a_c15_plat_skip.pin-bc7ed11d.elf"
DIAG="$BUILD/fw_payload_diag.elf"
OUT="$BUILD/fw_payload_r3a_c15_plat_skip.peel-printf.elf"
WANT=bc7ed11dab17454fd147e4927ba07fef
got=$(md5sum "$PIN" | awk '{print $1}')
if [[ "$got" != "$WANT" ]]; then
  echo "ERROR: pin md5 $got != $WANT"
  exit 1
fi
python3 - "$PIN" "$DIAG" "$OUT" <<'PY'
import hashlib, struct, sys
from pathlib import Path

pin, diag, dst = (Path(p) for p in sys.argv[1:])
pdata = bytearray(pin.read_bytes())
ddata = diag.read_bytes()

def segs_of(data):
    e_phoff = struct.unpack_from("<Q", data, 32)[0]
    e_phentsize = struct.unpack_from("<H", data, 54)[0]
    e_phnum = struct.unpack_from("<H", data, 56)[0]
    segs = []
    for i in range(e_phnum):
        o = e_phoff + i * e_phentsize
        if struct.unpack_from("<I", data, o)[0] != 1:
            continue
        p_offset, p_vaddr, _, p_filesz, _, _ = struct.unpack_from(
            "<QQQQQQ", data, o + 8
        )
        segs.append((p_offset, p_vaddr, p_filesz))
    return segs

def vf(segs, va):
    for off, v, fs in segs:
        if v <= va < v + fs:
            return off + (va - v)
    raise ValueError(hex(va))

PRINTF = 0x8000A980
ps, ds = segs_of(pdata), segs_of(ddata)
old = bytes(pdata[vf(ps, PRINTF) : vf(ps, PRINTF) + 4])
nat = ddata[vf(ds, PRINTF) : vf(ds, PRINTF) + 4]
if nat != bytes.fromhex("597106f4"):
    raise SystemExit(f"unexpected diag printf prologue {nat.hex()}")
print("sbi_printf before", old.hex(), "after", nat.hex())
pdata[vf(ps, PRINTF) : vf(ps, PRINTF) + 4] = nat
dst.write_bytes(pdata)
print("wrote", dst, hashlib.md5(pdata).hexdigest())
PY
md5sum "$PIN" "$OUT"
