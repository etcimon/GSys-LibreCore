#!/bin/bash
set -uo pipefail
export PATH="/root/tools/verilator-v5.008/bin:/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin:$PATH"
export VERILATOR_ROOT=/root/tools/verilator-v5.008/share/verilator
cd /mnt/e/cva6
COMMON=verif/tests/custom/common
CC="riscv-none-elf-gcc -march=rv64imafdc_zicsr -mabi=lp64d -nostdlib -nostartfiles -T $COMMON/link_verilator.ld -I$COMMON"
H=./work-ver-ai/Variane_testharness
run() {
  local elf=$1 name=$2
  th=$(riscv-none-elf-nm "$elf" | awk '$3=="tohost"{print $1; exit}')
  echo "=== $name ==="
  $H +time_out=200000 +debug_disable +tohost_addr=0x$th "$elf" 2>&1 | grep -E "SUCCESS|FAILED|tohost"
}

# 1) original (should fail with WC on)
$CC -o work-ver-ai/ai_elfs/ai_irq_plic_smoke.elf verif/tests/custom/ai/ai_irq_plic_smoke.S
run work-ver-ai/ai_elfs/ai_irq_plic_smoke.elf original

# 2) fence between done and PLIC
python3 - <<'PY'
from pathlib import Path
src = Path("verif/tests/custom/ai/ai_irq_plic_smoke.S").read_text()
old = """2:
  # IP bit 8 must be set
  li   t1, PLIC_IP
  lw   t0, 0(t1)
"""
new = """2:
  fence
  # IP bit 8 must be set
  li   t1, PLIC_IP
  lw   t0, 0(t1)
"""
Path("/tmp/ai_irq_fence.S").write_text(src.replace(old,new,1))
# also fence before claim only
src2 = Path("verif/tests/custom/ai/ai_irq_plic_smoke.S").read_text()
old2 = """  # Claim ? ID 8 (clears IP; ia holds until complete)
  li   t1, PLIC_CC0
  lw   t0, 0(t1)
"""
new2 = """  # Claim ? ID 8 (clears IP; ia holds until complete)
  fence
  li   t1, PLIC_CC0
  lw   t0, 0(t1)
"""
Path("/tmp/ai_irq_fence2.S").write_text(src2.replace(old2,new2,1))
print("ok")
PY
$CC -o work-ver-ai/ai_elfs/f1.elf /tmp/ai_irq_fence.S
$CC -o work-ver-ai/ai_elfs/f2.elf /tmp/ai_irq_fence2.S
run work-ver-ai/ai_elfs/f1.elf fence_before_ip
run work-ver-ai/ai_elfs/f2.elf fence_before_claim

# 3) nops delay
python3 - <<'PY'
from pathlib import Path
src = Path("verif/tests/custom/ai/ai_irq_plic_smoke.S").read_text()
old = """2:
  # IP bit 8 must be set
"""
new = """2:
  li   t3, 50
1:
  addi t3, t3, -1
  bnez t3, 1b
  # IP bit 8 must be set
"""
Path("/tmp/ai_irq_delay.S").write_text(src.replace(old,new,1))
print("delay ok")
PY
$CC -o work-ver-ai/ai_elfs/delay.elf /tmp/ai_irq_delay.S
run work-ver-ai/ai_elfs/delay.elf delay50

# 4) re-run mip test for consistency
$CC -o work-ver-ai/ai_elfs/mip.elf /tmp/ai_irq_mip.S 2>/dev/null || true
if [[ -f /tmp/ai_irq_mip.S ]]; then run work-ver-ai/ai_elfs/mip.elf mip_again; fi
