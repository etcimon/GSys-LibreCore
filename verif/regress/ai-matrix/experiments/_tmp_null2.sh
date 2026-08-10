#!/bin/bash
set -uo pipefail
export PATH="/root/tools/verilator-v5.008/bin:/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin:$PATH"
export VERILATOR_ROOT=/root/tools/verilator-v5.008/share/verilator
cd /mnt/e/cva6

# Ensure WIP has WC=EnableDmaFetch and null ptr_done
grep WriteCompletion corev_apu/ai_island/g6lc_ai_island_top.sv
grep -A6 "ST_CHK_DONE" corev_apu/ai_island/g6lc_ai_desc_engine.sv | head -20

AI_MATRIX_VERI_REBUILD=1 AI_MATRIX_VERI_TESTS="ai_ptr_done_smoke" bash verif/regress/ai-matrix-veri.sh 2>&1 | tail -10

COMMON=verif/tests/custom/common
CC="riscv-none-elf-gcc -march=rv64imafdc_zicsr -mabi=lp64d -nostdlib -nostartfiles -T $COMMON/link_verilator.ld -I$COMMON"
H=./work-ver-ai/Variane_testharness

# Build null ptr_done IRQ test cleanly
python3 <<'PY'
from pathlib import Path
src = Path("verif/tests/custom/ai/ai_irq_plic_smoke.S").read_text()
# Zero ptr_done
src = src.replace(
"  li   t0, 0x80013000\n  sw   t0, AI_DESC+0x38(s0)\n  sw   zero, AI_DESC+0x3C(s0)\n",
"  # null ptr_done: no completion DMA write\n  sw   zero, AI_DESC+0x38(s0)\n  sw   zero, AI_DESC+0x3C(s0)\n",
)
Path("/tmp/irq_null.S").write_text(src)
print("null test lines around desc:")
for i,l in enumerate(src.splitlines(),1):
    if "ptr_done" in l or "0x38" in l or "0x3C" in l or "DESC+0x38" in l:
        print(f"{i}: {l}")
PY
$CC -o work-ver-ai/ai_elfs/irq_null.elf /tmp/irq_null.S
th=$(riscv-none-elf-nm work-ver-ai/ai_elfs/irq_null.elf | awk '$3=="tohost"{print $1; exit}')
echo "tohost=$th"
$H +time_out=200000 +debug_disable +tohost_addr=0x$th work-ver-ai/ai_elfs/irq_null.elf 2>&1 | grep -E "SUCCESS|FAILED|tohost"

# Also original IRQ
th=$(riscv-none-elf-nm work-ver-ai/ai_elfs/ai_irq_plic_smoke.elf | awk '$3=="tohost"{print $1; exit}')
# recompile original
$CC -o work-ver-ai/ai_elfs/ai_irq_plic_smoke.elf verif/tests/custom/ai/ai_irq_plic_smoke.S
th=$(riscv-none-elf-nm work-ver-ai/ai_elfs/ai_irq_plic_smoke.elf | awk '$3=="tohost"{print $1; exit}')
$H +time_out=200000 +debug_disable +tohost_addr=0x$th work-ver-ai/ai_elfs/ai_irq_plic_smoke.elf 2>&1 | grep -E "SUCCESS|FAILED|tohost"
