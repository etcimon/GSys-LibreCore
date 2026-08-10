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
# After done, before IP: fence + load back completion word at 0x80013000
old = """2:
  # IP bit 8 must be set
  li   t1, PLIC_IP
  lw   t0, 0(t1)
"""
new = """2:
  # Drain DMA store (load-back completion word) before PLIC claim
  fence
  li   t1, 0x80013000
  ld   t0, 0(t1)
  fence
  # IP bit 8 must be set
  li   t1, PLIC_IP
  lw   t0, 0(t1)
"""
Path("/tmp/irq_drain.S").write_text(src.replace(old, new, 1))
print("ok")
PY
$CC -o /tmp/irq_drain.elf /tmp/irq_drain.S
th=$(riscv-none-elf-nm /tmp/irq_drain.elf | awk '$3=="tohost"{print $1; exit}')
$H +time_out=200000 +debug_disable +tohost_addr=0x$th /tmp/irq_drain.elf 2>&1 | grep -E "SUCCESS|FAILED|tohost"

# Also try: dummy load from DRAM base
python3 <<'PY'
from pathlib import Path
src = Path("verif/tests/custom/ai/ai_irq_plic_smoke.S").read_text()
old = """2:
  # IP bit 8 must be set
  li   t1, PLIC_IP
  lw   t0, 0(t1)
"""
new = """2:
  fence
  li   t1, 0x80000000
  ld   t0, 0(t1)
  fence
  # IP bit 8 must be set
  li   t1, PLIC_IP
  lw   t0, 0(t1)
"""
Path("/tmp/irq_dram.S").write_text(src.replace(old, new, 1))
PY
$CC -o /tmp/irq_dram.elf /tmp/irq_dram.S
th=$(riscv-none-elf-nm /tmp/irq_dram.elf | awk '$3=="tohost"{print $1; exit}')
$H +time_out=200000 +debug_disable +tohost_addr=0x$th /tmp/irq_dram.elf 2>&1 | grep -E "SUCCESS|FAILED|tohost"
