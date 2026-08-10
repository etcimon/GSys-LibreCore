#!/bin/bash
set -uo pipefail
export PATH="/root/tools/verilator-v5.008/bin:/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin:$PATH"
export VERILATOR_ROOT=/root/tools/verilator-v5.008/share/verilator
cd /mnt/e/cva6

# Rebuild with current WIP (null ptr_done + WriteCompletion store)
AI_MATRIX_VERI_REBUILD=1 AI_MATRIX_VERI_TESTS="ai_irq_plic_smoke" bash verif/regress/ai-matrix-veri.sh 2>&1 | tail -12

COMMON=verif/tests/custom/common
CC="riscv-none-elf-gcc -march=rv64imafdc_zicsr -mabi=lp64d -nostdlib -nostartfiles -T $COMMON/link_verilator.ld -I$COMMON"
H=./work-ver-ai/Variane_testharness

# Test A: poll claim until ID 8 or timeout
python3 <<'PY'
from pathlib import Path
src = Path("verif/tests/custom/ai/ai_irq_plic_smoke.S").read_text()
old = """  # Claim → ID 8 (clears IP; ia holds until complete)
  li   t1, PLIC_CC0
  lw   t0, 0(t1)
  li   t2, PLIC_ID_AI
  bne  t0, t2, fail_cl
"""
new = """  # Poll claim until ID 8 (up to 64 tries)
  li   t3, 64
  li   t2, PLIC_ID_AI
1:
  li   t1, PLIC_CC0
  lw   t0, 0(t1)
  beq  t0, t2, 2f
  # if non-zero wrong id, fail immediately
  bnez t0, fail_cl
  addi t3, t3, -1
  bnez t3, 1b
  j    fail_cl
2:
"""
Path("/tmp/claim_poll.S").write_text(src.replace(old, new, 1))
# Test B: ptr_done via .data symbol + fence after done
src2 = src
# replace hardcoded ptr_done with la done_word; expand region; add data section
src2 = src2.replace(
"""  li   t0, 0x80013000
  sw   t0, AI_DESC+0x38(s0)
  sw   zero, AI_DESC+0x3C(s0)
""",
"""  la   t0, done_word
  sw   t0, AI_DESC+0x38(s0)
  srli t1, t0, 32
  sw   t1, AI_DESC+0x3C(s0)
""")
src2 = src2.replace(
"""  li   t0, 0x80010000
  sw   t0, AI_REG0+0x0(s0)
  sw   zero, AI_REG0+0x4(s0)
  li   t0, 0x80014000
  sw   t0, AI_REG0+0x8(s0)
""",
"""  li   t0, 0x80000000
  sw   t0, AI_REG0+0x0(s0)
  sw   zero, AI_REG0+0x4(s0)
  li   t0, 0x80100000
  sw   t0, AI_REG0+0x8(s0)
""")
if ".section .data" not in src2:
    src2 = src2.replace(
"""  .section .tohost,"aw",@progbits
""",
"""  .section .data
  .align 3
done_word:
  .dword 0

  .section .tohost,"aw",@progbits
""")
Path("/tmp/claim_data.S").write_text(src2)
# Test C: null ptr_done (skip write entirely)
src3 = src.replace(
"""  li   t0, 0x80013000
  sw   t0, AI_DESC+0x38(s0)
  sw   zero, AI_DESC+0x3C(s0)
""",
"""  sw   zero, AI_DESC+0x38(s0)
  sw   zero, AI_DESC+0x3C(s0)
""")
Path("/tmp/claim_null.S").write_text(src3)
print("ok")
PY

run() {
  local elf=$1 name=$2
  th=$(riscv-none-elf-nm "$elf" | awk '$3=="tohost"{print $1; exit}')
  out=$($H +time_out=200000 +debug_disable +tohost_addr=0x$th "$elf" 2>&1 | grep -E "SUCCESS|FAILED")
  echo "$name: $out"
}

$CC -o work-ver-ai/ai_elfs/claim_poll.elf /tmp/claim_poll.S
$CC -o work-ver-ai/ai_elfs/claim_data.elf /tmp/claim_data.S
$CC -o work-ver-ai/ai_elfs/claim_null.elf /tmp/claim_null.S
run work-ver-ai/ai_elfs/claim_poll.elf claim_poll
run work-ver-ai/ai_elfs/claim_data.elf claim_data
run work-ver-ai/ai_elfs/claim_null.elf claim_null
