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
  out=$($H +time_out=200000 +debug_disable +tohost_addr=0x$th "$elf" 2>&1 | grep -E "SUCCESS|FAILED")
  echo "$name: $out"
}

python3 <<'PY'
from pathlib import Path
src = Path("verif/tests/custom/ai/ai_irq_plic_smoke.S").read_text()
variants = {
  "csrr_mip": "  csrr s1, mip\n",
  "csrr_mstatus": "  csrr s1, mstatus\n",
  "csrr_mcycle": "  csrr s1, mcycle\n",
  "nop3": "  nop\n  nop\n  nop\n",
  "lw_prio": "  li t1, PLIC_PRIO8\n  lw s1, 0(t1)\n",
  "lw_ie": "  li t1, PLIC_IE0\n  lw s1, 0(t1)\n",
  "lw_thr": "  li t1, PLIC_THR0\n  lw s1, 0(t1)\n",
  "lw_ip2": "  li t1, PLIC_IP\n  lw s1, 0(t1)\n",
}
old = """  # Claim → ID 8 (clears IP; ia holds until complete)
  li   t1, PLIC_CC0
  lw   t0, 0(t1)
"""
for name, ins in variants.items():
    new = "  # Claim → ID 8 (clears IP; ia holds until complete)\n" + ins + "  li   t1, PLIC_CC0\n  lw   t0, 0(t1)\n"
    if old not in src:
        raise SystemExit("old missing")
    Path(f"/tmp/var_{name}.S").write_text(src.replace(old, new, 1))
print("variants", len(variants))
PY

for v in csrr_mip csrr_mstatus csrr_mcycle nop3 lw_prio lw_ie lw_thr lw_ip2; do
  $CC -o work-ver-ai/ai_elfs/var_$v.elf /tmp/var_$v.S
  run work-ver-ai/ai_elfs/var_$v.elf $v
done
