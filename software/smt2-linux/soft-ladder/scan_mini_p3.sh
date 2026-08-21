#!/bin/bash
# Scan compiled mini for 0xB7010100 and show load_be32 / nm.
set -uo pipefail
export PATH="/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin:${PATH}"
ELF=/tmp/cva6-mini-p3split/mini_fdt_a0_is_fdt.elf
echo "---- nm ----"
riscv-none-elf-nm "$ELF"
echo "---- load_be32 ----"
riscv-none-elf-objdump -d "$ELF" | awk '/<load_be32>:/,/<offset_ptr>:/'
echo "---- python scan ----"
python3 - <<'PY'
d=open('/tmp/cva6-mini-p3split/mini_fdt_a0_is_fdt.elf','rb').read()
need=bytes([0xb7,0x01,0x01,0x00])
need_le=bytes([0x00,0x01,0x01,0xb7])
hits=[i for i in range(len(d)-3) if d[i:i+4]==need]
hits_le=[i for i in range(len(d)-3) if d[i:i+4]==need_le]
print('be_hits', [hex(h) for h in hits])
print('le_hits', [hex(h) for h in hits_le])
# also show first 0x200 bytes at typical load VAs (ELF is linked 0x80000000)
# file offset of .text is not 0; just print a window around 0x50 if present
print('len', hex(len(d)))
PY
echo DONE
