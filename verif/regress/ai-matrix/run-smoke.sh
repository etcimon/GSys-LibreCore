#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Thin wrapper around ai-matrix-veri.sh with the monorepo-proven Verilator
# 5.008 path. Usage:
#   bash verif/regress/ai-matrix/run-smoke.sh
#   bash verif/regress/ai-matrix/run-smoke.sh ai_irq_plic_smoke ai_ptr_done_smoke
#   AI_MATRIX_VERI_REBUILD=1 bash verif/regress/ai-matrix/run-smoke.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
export PATH="/root/tools/verilator-v5.008/bin:${PATH:-}"
export VERILATOR_ROOT="${VERILATOR_ROOT:-/root/tools/verilator-v5.008/share/verilator}"
[[ -d /opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin ]] && \
  export PATH="/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin:$PATH"

if [[ $# -gt 0 ]]; then
  export AI_MATRIX_VERI_TESTS="$*"
fi
exec bash "$ROOT/verif/regress/ai-matrix-veri.sh"
