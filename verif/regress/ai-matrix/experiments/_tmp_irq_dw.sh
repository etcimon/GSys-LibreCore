#!/bin/bash
set -uo pipefail
export PATH="/root/tools/verilator-v5.008/bin:/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin:$PATH"
export VERILATOR_ROOT=/root/tools/verilator-v5.008/share/verilator
cd /mnt/e/cva6
COMMON=verif/tests/custom/common
CC="riscv-none-elf-gcc -march=rv64imafdc_zicsr -mabi=lp64d -nostdlib -nostartfiles -T $COMMON/link_verilator.ld -I$COMMON"
H=./work-ver-ai/Variane_testharness

python3 <<'PY'
from pathlib import Path
src = Path("verif/tests/custom/ai/ai_irq_plic_smoke.S").read_text()
src = src.replace(
"""  # Region q0 [0x80010000, 0x80014000) RW
  li   t0, 0x80010000
  sw   t0, AI_REG0+0x0(s0)
  sw   zero, AI_REG0+0x4(s0)
  li   t0, 0x80014000
  sw   t0, AI_REG0+0x8(s0)
  sw   zero, AI_REG0+0xC(s0)
  li   t0, 0x3
  sw   t0, AI_REG0+0x10(s0)
""",
"""  # Region q0 covers DRAM incl. completion word
  li   t0, 0x80000000
  sw   t0, AI_REG0+0x0(s0)
  sw   zero, AI_REG0+0x4(s0)
  li   t0, 0x80100000
  sw   t0, AI_REG0+0x8(s0)
  sw   zero, AI_REG0+0xC(s0)
  li   t0, 0x3
  sw   t0, AI_REG0+0x10(s0)
""")
src = src.replace(
"""  li   t0, 0x80013000
  sw   t0, AI_DESC+0x38(s0)
  sw   zero, AI_DESC+0x3C(s0)
""",
"""  la   t0, done_word
  sw   t0, AI_DESC+0x38(s0)
  srli t1, t0, 32
  sw   t1, AI_DESC+0x3C(s0)
""")
if ".section .data" not in src:
    src = src.replace(
"""  .section .tohost,"aw",@progbits
""",
"""  .section .data
  .align 3
done_word:
  .dword 0

  .section .tohost,"aw",@progbits
""")
Path("/tmp/irq_dw.S").write_text(src)
print("written")
PY
$CC -o /tmp/irq_dw.elf /tmp/irq_dw.S
riscv-none-elf-nm /tmp/irq_dw.elf | grep -E "done_word|tohost"
th=$(riscv-none-elf-nm /tmp/irq_dw.elf | awk '$3=="tohost"{print $1; exit}')
echo "tohost=$th"
$H +time_out=200000 +debug_disable +tohost_addr=0x$th /tmp/irq_dw.elf 2>&1 | grep -E "SUCCESS|FAILED|tohost"
