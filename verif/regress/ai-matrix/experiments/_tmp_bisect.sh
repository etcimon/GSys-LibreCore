#!/bin/bash
set -uo pipefail
export PATH="/root/tools/verilator-v5.008/bin:/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin:$PATH"
export VERILATOR_ROOT=/root/tools/verilator-v5.008/share/verilator
cd /mnt/e/cva6

cp corev_apu/ai_island/g6lc_ai_desc_engine.sv /tmp/eng.sv

# Patch: ST_WR_DONE is no-op complete (no AXI)
python3 <<'PY'
from pathlib import Path
p = Path("corev_apu/ai_island/g6lc_ai_desc_engine.sv")
t = p.read_text()
old = """      ST_WR_DONE: begin
        // One-shot start when store unit is ready; wait for done
        if (!wr_issued_q && wr_ready_i) begin
          wr_start_n  = 1'b1;
          wr_issued_d = 1'b1;
        end
        if (wr_issued_q && wr_done_i) begin
          if (wr_err_i) status_d = ST_ERR;
          state_d = ST_COMPLETE;
        end
      end
"""
new = """      ST_WR_DONE: begin
        state_d = ST_COMPLETE; // TMP bisect: no AXI
      end
"""
p.write_text(t.replace(old,new))
print("patched skip axi")
PY

AI_MATRIX_VERI_REBUILD=1 bash -c '
  export AI_MATRIX_VERI_TESTS="ai_irq_plic_smoke"
  bash verif/regress/ai-matrix-veri.sh
' 2>&1 | tail -8

COMMON=verif/tests/custom/common
CC="riscv-none-elf-gcc -march=rv64imafdc_zicsr -mabi=lp64d -nostdlib -nostartfiles -T $COMMON/link_verilator.ld -I$COMMON"
H=./work-ver-ai/Variane_testharness
run() {
  $CC -o /tmp/$1.elf $2
  th=$(riscv-none-elf-nm /tmp/$1.elf | awk '$3=="tohost"{print $1; exit}')
  echo -n "$1: "
  $H +time_out=200000 +debug_disable +tohost_addr=0x$th /tmp/$1.elf 2>&1 | grep -E "SUCCESS|FAILED"
}

# null on same harness
python3 <<'PY'
from pathlib import Path
src = Path("verif/tests/custom/ai/ai_irq_plic_smoke.S").read_text()
src = src.replace(
"  li   t0, 0x80013000\n  sw   t0, AI_DESC+0x38(s0)\n  sw   zero, AI_DESC+0x3C(s0)\n",
"  sw   zero, AI_DESC+0x38(s0)\n  sw   zero, AI_DESC+0x3C(s0)\n")
Path("/tmp/null.S").write_text(src)
PY
run orig verif/tests/custom/ai/ai_irq_plic_smoke.S
run null /tmp/null.S

cp /tmp/eng.sv corev_apu/ai_island/g6lc_ai_desc_engine.sv
echo restored
