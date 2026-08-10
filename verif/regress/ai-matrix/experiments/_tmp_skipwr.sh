#!/bin/bash
set -uo pipefail
export PATH="/root/tools/verilator-v5.008/bin:/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin:$PATH"
export VERILATOR_ROOT=/root/tools/verilator-v5.008/share/verilator
cd /mnt/e/cva6

cp corev_apu/ai_island/g6lc_ai_desc_engine.sv /tmp/engine_wip.sv
cp corev_apu/ai_island/g6lc_ai_island_top.sv /tmp/island_wip.sv

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
        // TMP: skip real store — go straight to complete
        state_d = ST_COMPLETE;
      end
"""
if old not in t: raise SystemExit("no match")
p.write_text(t.replace(old,new))
print("ST_WR_DONE skip store")
PY

AI_MATRIX_VERI_REBUILD=1 AI_MATRIX_VERI_TESTS="ai_irq_plic_smoke ai_ptr_done_smoke" \
  bash verif/regress/ai-matrix-veri.sh 2>&1 | tail -25

cp /tmp/engine_wip.sv corev_apu/ai_island/g6lc_ai_desc_engine.sv
cp /tmp/island_wip.sv corev_apu/ai_island/g6lc_ai_island_top.sv
echo restored
grep -A3 "ST_WR_DONE:" corev_apu/ai_island/g6lc_ai_desc_engine.sv | head -6
