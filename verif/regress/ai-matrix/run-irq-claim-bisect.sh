#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Bisect: ai_irq_plic_smoke claim-id-0 after WriteCompletion DMA store.
# Compares WC=0 (no store) vs full path. Expect WC=0 PASS, WC=1 FAIL until fixed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
export PATH="/root/tools/verilator-v5.008/bin:/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin:${PATH:-}"
export VERILATOR_ROOT="${VERILATOR_ROOT:-/root/tools/verilator-v5.008/share/verilator}"

ISL=corev_apu/ai_island/g6lc_ai_island_top.sv
cp "$ISL" /tmp/g6lc_ai_island_top.sv.bak

run_suite() {
  local tag=$1
  echo "======== $tag ========"
  AI_MATRIX_VERI_REBUILD=1 AI_MATRIX_VERI_TESTS="ai_irq_plic_smoke ai_ptr_done_smoke" \
    bash verif/regress/ai-matrix-veri.sh 2>&1 | tee "/tmp/ai-bisect-${tag}.log" | \
    grep -E 'PASS|FAIL|SUCCESS|FAILED|SUMMARY' || true
}

# A: WriteCompletion forced off
python3 - <<'PY'
from pathlib import Path
p = Path("corev_apu/ai_island/g6lc_ai_island_top.sv")
t = p.read_text()
t2 = t.replace(".WriteCompletion (EnableDmaFetch)", ".WriteCompletion (1'b0) /*bisect*/")
if t2 == t:
    raise SystemExit("WriteCompletion patch site missing")
p.write_text(t2)
print("patched WC=0")
PY
run_suite wc0

# B: restore full path
cp /tmp/g6lc_ai_island_top.sv.bak "$ISL"
run_suite wc1

echo "Logs: /tmp/ai-bisect-wc0.log /tmp/ai-bisect-wc1.log"
