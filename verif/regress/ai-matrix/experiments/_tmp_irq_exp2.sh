#!/bin/bash
set -euo pipefail
export PATH="/root/tools/verilator-v5.008/bin:/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin:$PATH"
export VERILATOR_ROOT=/root/tools/verilator-v5.008/share/verilator
cd /mnt/e/cva6
H=./work-ver-ai/Variane_testharness
run() {
  local elf=$1 name=$2
  local th; th=$(riscv-none-elf-nm "$elf" | awk '$3=="tohost"{print $1; exit}')
  echo "=== $name ==="
  $H +time_out=200000 +debug_disable +tohost_addr=0x$th "$elf" 2>&1 | grep -E "SUCCESS|FAILED|tohost"
}
COMMON=verif/tests/custom/common
CC="riscv-none-elf-gcc -march=rv64imafdc_zicsr -mabi=lp64d -nostdlib -nostartfiles -T $COMMON/link_verilator.ld -I$COMMON"

# rearm
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

  # Re-arm PLIC after DMA completion write
  li   t0, 1
  li   t1, PLIC_PRIO8
  sw   t0, 0(t1)
  li   t1, PLIC_THR0
  sw   zero, 0(t1)
  li   t0, PLIC_BIT_AI
  li   t1, PLIC_IE0
  sw   t0, 0(t1)
  fence

  li   t1, PLIC_CC0
  lw   t0, 0(t1)
  li   t2, PLIC_ID_AI
  bne  t0, t2, fail_cl
"""
Path("/tmp/ai_irq_rearm.S").write_text(src.replace(old,new))
# only IP check, no claim compare - just dump claim via fail always
src3 = src.replace(old, """  li   t1, PLIC_IP
  lw   s1, 0(t1)
  li   t1, PLIC_CC0
  lw   t0, 0(t1)
  # Always go to fail_cl to report claim/ip
  j    fail_cl
""").replace("""fail_cl:
  # encode claimed id: a0 = ((id+20)<<1)|1
  addi a0, t0, 20
  slli a0, a0, 1
  ori  a0, a0, 1
  j    fe
""", """fail_cl:
  # display a0>>1: put claim in low 8, ip in next 16
  andi a0, t0, 0xff
  slli t1, s1, 8
  or   a0, a0, t1
  slli a0, a0, 1
  ori  a0, a0, 1
  j    fe
""")
Path("/tmp/ai_irq_dump.S").write_text(src3)
print("ok")
PY
$CC -o work-ver-ai/ai_elfs/ai_irq_rearm.elf /tmp/ai_irq_rearm.S
$CC -o work-ver-ai/ai_elfs/ai_irq_dump.elf /tmp/ai_irq_dump.S
run work-ver-ai/ai_elfs/ai_irq_rearm.elf rearm
run work-ver-ai/ai_elfs/ai_irq_dump.elf dump

# ptr_done smoke still pass?
AI_MATRIX_VERI_REBUILD=0 AI_MATRIX_VERI_TESTS="ai_ptr_done_smoke ai_desc_fetch_smoke" bash verif/regress/ai-matrix-veri.sh 2>&1 | tail -20
