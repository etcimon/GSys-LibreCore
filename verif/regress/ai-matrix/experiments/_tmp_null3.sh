#!/bin/bash
set -uo pipefail
export PATH="/root/tools/verilator-v5.008/bin:/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin:$PATH"
export VERILATOR_ROOT=/root/tools/verilator-v5.008/share/verilator
cd /mnt/e/cva6
COMMON=verif/tests/custom/common
CC="riscv-none-elf-gcc -march=rv64imafdc_zicsr -mabi=lp64d -nostdlib -nostartfiles -T $COMMON/link_verilator.ld -I$COMMON"
H=./work-ver-ai/Variane_testharness

# Create IRQ test with ptr_done=0
python3 <<'PY'
from pathlib import Path
src = Path("verif/tests/custom/ai/ai_irq_plic_smoke.S").read_text()
old = """  li   t0, 0x80013000
  sw   t0, AI_DESC+0x38(s0)
  sw   zero, AI_DESC+0x3C(s0)
"""
new = """  sw   zero, AI_DESC+0x38(s0)
  sw   zero, AI_DESC+0x3C(s0)
"""
if old not in src:
    raise SystemExit("pattern not found")
Path("/tmp/irq_null3.S").write_text(src.replace(old, new))
print("created null3")
PY

$CC -o work-ver-ai/ai_elfs/irq_null3.elf /tmp/irq_null3.S
# disassemble around desc setup to confirm zeros
riscv-none-elf-objdump -d work-ver-ai/ai_elfs/irq_null3.elf | sed -n '70,120p'

th=$(riscv-none-elf-nm work-ver-ai/ai_elfs/irq_null3.elf | awk '$3=="tohost"{print $1; exit}')
echo "RUN null3 tohost=$th"
$H +time_out=200000 +debug_disable +tohost_addr=0x$th work-ver-ai/ai_elfs/irq_null3.elf 2>&1 | grep -E "SUCCESS|FAILED|tohost"

# Control: original
$CC -o work-ver-ai/ai_elfs/irq_orig.elf verif/tests/custom/ai/ai_irq_plic_smoke.S
th=$(riscv-none-elf-nm work-ver-ai/ai_elfs/irq_orig.elf | awk '$3=="tohost"{print $1; exit}')
echo "RUN orig tohost=$th"
$H +time_out=200000 +debug_disable +tohost_addr=0x$th work-ver-ai/ai_elfs/irq_orig.elf 2>&1 | grep -E "SUCCESS|FAILED|tohost"
