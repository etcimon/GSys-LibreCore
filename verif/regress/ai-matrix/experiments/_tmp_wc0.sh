#!/bin/bash
set -euo pipefail
export PATH="/root/tools/verilator-v5.008/bin:/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin:$PATH"
export VERILATOR_ROOT=/root/tools/verilator-v5.008/share/verilator
cd /mnt/e/cva6

# A) Force WriteCompletion=0, rebuild, run irq
python3 - <<'PY'
from pathlib import Path
p = Path("corev_apu/ai_island/g6lc_ai_island_top.sv")
t = p.read_text()
if ".WriteCompletion (EnableDmaFetch)" not in t:
    raise SystemExit(f"unexpected content: { [l for l in t.splitlines() if 'WriteCompletion' in l] }")
p.write_text(t.replace(".WriteCompletion (EnableDmaFetch)", ".WriteCompletion (1'b0) /*TMP*/"))
print("patched off")
PY

set +e
AI_MATRIX_VERI_REBUILD=1 AI_MATRIX_VERI_TESTS="ai_irq_plic_smoke" bash verif/regress/ai-matrix-veri.sh
rc=$?
set -e
echo "suite_rc=$rc"

# restore always
python3 - <<'PY'
from pathlib import Path
p = Path("corev_apu/ai_island/g6lc_ai_island_top.sv")
t = p.read_text()
p.write_text(t.replace(".WriteCompletion (1'b0) /*TMP*/", ".WriteCompletion (EnableDmaFetch)"))
print("restored")
print([l for l in p.read_text().splitlines() if "WriteCompletion" in l])
PY
