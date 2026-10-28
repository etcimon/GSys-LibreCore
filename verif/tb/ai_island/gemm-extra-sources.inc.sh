# SPDX-License-Identifier: MIT
# Copyright 2026 Etienne Cimon
# Hyp GEMM's functional leaves; the production tree has no dependency on them.
GEMM_EXTRA_SOURCES=()
for gemm_leaf in g6lc_ai_gemm_fp32_add g6lc_ai_gemm_span g6lc_ai_gemm_store_plan; do
  if [[ -f "$AI_RTL/$gemm_leaf.sv" ]]; then
    GEMM_EXTRA_SOURCES+=("$AI_RTL/$gemm_leaf.sv")
  fi
done
unset gemm_leaf
