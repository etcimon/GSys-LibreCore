#!/bin/bash
# Compile grown mini (P3 inner split) and run on current G1g slfix.
set -uo pipefail
export PATH="/root/tools/verilator-v5.008/bin:/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin:/root/tools/spike/bin:${PATH}"
export LD_LIBRARY_PATH="/root/tools/spike/lib:${LD_LIBRARY_PATH:-}"
H=/mnt/e/cva6/work-ver-smt2-slfix/Variane_testharness
ROOT=/mnt/e/cva6
OUT=/mnt/e/cva6/software/smt2-linux/soft-ladder/_mini_out
mkdir -p "$OUT"
echo "harness $(md5sum "$H")"
file "$H"
COMMON="$ROOT/verif/tests/custom/common"
LD="$COMMON/link_verilator.ld"
SRC="$ROOT/verif/tests/custom/multicore/mini_fdt_a0_is_fdt.S"
ELF="$OUT/mini_fdt_a0_is_fdt.elf"
riscv-none-elf-gcc -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
  -I"$ROOT/verif/tests/custom/env" -I"$COMMON" \
  "$SRC" -T "$LD" -o "$ELF" -march=rv64imafdc_zicsr_zifencei -mabi=lp64d
echo "mini elf $(md5sum "$ELF")"
echo "---- nm ----"
riscv-none-elf-nm "$ELF" | awk '$3=="fdt_blob" || $3=="tohost" || $3=="offset_ptr" || $3=="_start"'
set +e
timeout 90s spike --isa=rv64imafdc_zicsr_zifencei --steps=400000 "$ELF" >"$OUT/spike.log" 2>&1
echo "spike rc=$?"
grep -E 'mem 0x0000000080001000 0x00000001' "$OUT/spike.log" && echo SPIKE_PASS || echo SPIKE_FAIL
TH=$(riscv-none-elf-nm "$ELF" | awk '$3=="tohost"{print $1; exit}')
echo "tohost=0x${TH}"
export CVA6_TRAP_DUMP=1
"$H" +max-cycles=400000 +time_out=400000 +debug_disable \
  +tohost_addr="0x${TH}" "$ELF" >"$OUT/veri_mini.log" 2>&1
echo "mini rc=$?"
grep -E 'SUCCESS|FAILED|tohost|BuildID|trapdump' "$OUT/veri_mini.log" | tail -20 || true
echo '---- decode printed tohost ----'
python3 - <<'PY'
import re
p="/mnt/e/cva6/software/smt2-linux/soft-ladder/_mini_out/veri_mini.log"
text=open(p,errors="replace").read()
m=re.search(r"tohost\s*=\s*(\d+)", text)
if not m:
    print("no tohost")
else:
    n=int(m.group(1))
    print("printed", n, "hex", hex(n))
    print("if phase: 0x%x" % n)
    print("if leftover (a0|1)>>1: a0_lo", hex(n<<1), "or", hex((n<<1)|1))
PY
echo '---- objdump offset_ptr ----'
riscv-none-elf-objdump -d "$ELF" | awk '/<offset_ptr>:/,/<next_tag>:/'
echo '---- objdump _start..load_be32 (P6 window) ----'
riscv-none-elf-objdump -d "$ELF" | awk '/<_start>:/,/<load_be32>:/'
echo DONE
