#!/bin/bash
set -euo pipefail
export PATH="/root/tools/verilator-v5.008/bin:/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin:$PATH"
export VERILATOR_ROOT=/root/tools/verilator-v5.008/share/verilator
cd /mnt/e/cva6

# Rebuild with WriteCompletion ON (current RTL)
AI_MATRIX_VERI_REBUILD=1 AI_MATRIX_VERI_TESTS="ai_irq_plic_smoke" bash verif/regress/ai-matrix-veri.sh 2>&1 | tail -15

# Experiment: IRQ test that re-programs PLIC after done, before claim
python3 - <<'PY'
from pathlib import Path
src = Path("verif/tests/custom/ai/ai_irq_plic_smoke.S").read_text()
old = """  # IP bit 8 must be set
  li   t1, PLIC_IP
  lw   t0, 0(t1)
  li   t2, PLIC_BIT_AI
  and  t0, t0, t2
  beqz t0, fail_ip0

  # Claim ? ID 8 (clears IP; ia holds until complete)
  li   t1, PLIC_CC0
  lw   t0, 0(t1)
  li   t2, PLIC_ID_AI
  bne  t0, t2, fail_cl
"""
new = """  # IP bit 8 must be set
  li   t1, PLIC_IP
  lw   t0, 0(t1)
  li   t2, PLIC_BIT_AI
  and  t0, t0, t2
  beqz t0, fail_ip0

  # Re-arm PLIC after DMA completion write (probe whether setup was lost)
  li   t0, 1
  li   t1, PLIC_PRIO8
  sw   t0, 0(t1)
  li   t1, PLIC_THR0
  sw   zero, 0(t1)
  li   t0, PLIC_BIT_AI
  li   t1, PLIC_IE0
  sw   t0, 0(t1)
  fence

  # Claim ? ID 8 (clears IP; ia holds until complete)
  li   t1, PLIC_CC0
  lw   t0, 0(t1)
  li   t2, PLIC_ID_AI
  bne  t0, t2, fail_cl
"""
if old not in src:
    raise SystemExit("pattern missing")
Path("/tmp/ai_irq_rearm.S").write_text(src.replace(old, new))
print("wrote rearm")
PY
riscv-none-elf-gcc -march=rv64imafdc_zicsr -mabi=lp64d -nostdlib -nostartfiles \
  -T verif/tests/custom/common/link_verilator.ld -I verif/tests/custom/common \
  -o work-ver-ai/ai_elfs/ai_irq_rearm.elf /tmp/ai_irq_rearm.S
th=$(riscv-none-elf-nm work-ver-ai/ai_elfs/ai_irq_rearm.elf | awk '$3=="tohost"{print $1; exit}')
echo "rearm tohost=$th"
./work-ver-ai/Variane_testharness +time_out=200000 +debug_disable +tohost_addr=0x$th \
  work-ver-ai/ai_elfs/ai_irq_rearm.elf 2>&1 | grep -E "SUCCESS|FAILED|tohost"

# Experiment: ptr_done at different address 0x80020000 (expand region)
python3 - <<'PY'
from pathlib import Path
src = Path("verif/tests/custom/ai/ai_irq_plic_smoke.S").read_text()
src2 = src.replace("0x80014000", "0x80030000").replace("0x80013000", "0x80020000")
Path("/tmp/ai_irq_ptr2.S").write_text(src2)
print("wrote ptr2")
PY
riscv-none-elf-gcc -march=rv64imafdc_zicsr -mabi=lp64d -nostdlib -nostartfiles \
  -T verif/tests/custom/common/link_verilator.ld -I verif/tests/custom/common \
  -o work-ver-ai/ai_elfs/ai_irq_ptr2.elf /tmp/ai_irq_ptr2.S
th=$(riscv-none-elf-nm work-ver-ai/ai_elfs/ai_irq_ptr2.elf | awk '$3=="tohost"{print $1; exit}')
./work-ver-ai/Variane_testharness +time_out=200000 +debug_disable +tohost_addr=0x$th \
  work-ver-ai/ai_elfs/ai_irq_ptr2.elf 2>&1 | grep -E "SUCCESS|FAILED|tohost"
