#!/bin/bash
# Probe: stock pin + soft fdt_next_tag ret0 only (natural hart_init).
# If SUCCESS or new hang → next_tag path is on the stock residual critical path.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
H="$ROOT/work-ver-smt2-slfix/Variane_testharness"
OUT=/tmp/cva6-i4s-ntsoft
mkdir -p "$OUT"
export CVA6_TRAP_DUMP=1
TOHOST=0x80041730
BUILD=software/smt2-linux/soft-ladder/build
PIN_GOOD="$BUILD/fw_payload_r3a_c15_plat_skip.pin-bc7ed11d.elf"
WANT=bc7ed11dab17454fd147e4927ba07fef
cp "$PIN_GOOD" "$OUT/base.elf"
got=$(md5sum "$OUT/base.elf" | awk '{print $1}')
[[ "$got" == "$WANT" ]] || { echo bad pin; exit 1; }

python3 - <<'PY'
import struct
from pathlib import Path
data = bytearray(Path("/tmp/cva6-i4s-ntsoft/base.elf").read_bytes())
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

# soft_ret0 at fdt_next_tag: c.li a0,0; c.jr ra
struct.pack_into("<H", data, vf(0x800129D4), 0x4501)
struct.pack_into("<H", data, vf(0x800129D6), 0x8082)
Path("/tmp/cva6-i4s-ntsoft/elf_soft_nt.elf").write_bytes(data)
print("wrote soft next_tag ret0")
PY

set +e
"$H" +time_out=7000000 +max-cycles=7000000 +debug_disable +tohost_addr="$TOHOST" \
  "$OUT/elf_soft_nt.elf" >"$OUT/veri_soft_nt.log" 2>&1
rc=$?
set -e
if grep -qE '\[1000\]=[0-9a-fA-F]*51b1babe' "$OUT/veri_soft_nt.log"; then
  echo "CLASSIFY=SUCCESS soft_nt rc=$rc"
else
  echo "CLASSIFY=FAIL soft_nt rc=$rc"
fi
grep -E '\[trapdump\]|\[hangpc\]|51b1|coldboot|plat_hc' "$OUT/veri_soft_nt.log" | tail -10 || true
echo DONE
