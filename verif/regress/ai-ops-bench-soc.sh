#!/usr/bin/env bash
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# SoC-level AI ops bench matrix on the bench SKU model (work-ver-ai-bench, built with
# `G6LC_AI_TB_BENCH_SKU`: island VaTurboEn + IslandFpEn + every executable format granted):
#   GEMM  x {int8 int4 fp8e4m3 fp8e5m2 fp16 bf16 fp32} x MxNxK shapes x {mmio doorbell, ai.enq/ai.poll}
#         x {cold, reuse_a, reuse_b}          (verif/tests/custom/ai/ai_bench_gemm.S)
#   T0/T1 {dot4.s8 dot4a.s8 mma.s8 mvta+mvacc} (verif/tests/custom/ai/ai_bench_t0.S)
# Records: island +ai_pmu_trace AI_JOB lines and rdcycle counts, reduced by
# verif/regress/remote/ai_bench_report.py --soc into cycles per operation, MAC/cycle,
# cold-vs-resident speedup. Thin wrapper over ai-matrix-veri.sh AI_MATRIX_BENCH=1.
#   AI_MATRIX_BENCH_FMTS="0 1 3 4 5 6 7"  AI_MATRIX_BENCH_SHAPES="1x512x512 1x256x1024 64x512x512 64x256x1024"
#   AI_MATRIX_BENCH_PATHS="0 1"  AI_MATRIX_BENCH_REUSE="0 1 2"  AI_MATRIX_BENCH_T0="0 1 2 3"
#   AI_MATRIX_VERI_REBUILD=1 rebuilds the bench SKU library first.
# Cycles of the built geometry on the simulated memory; not silicon timing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AI_MATRIX_BENCH=1 AI_MATRIX_BENCH_SKU=1 exec bash "$ROOT/verif/regress/ai-matrix-veri.sh"
