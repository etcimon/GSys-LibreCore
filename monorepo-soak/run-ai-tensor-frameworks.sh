#!/bin/bash
# SPDX-License-Identifier: MIT
# PyTorch/TF/numpy frameworks regress through ai-tensor Device backends.
# Default: virt-ai-pcie virt-card (hostless soft UIO / virtual PCIe).
#
# Usage:
#   bash monorepo-soak/run-ai-tensor-frameworks.sh
#   AI_TENSOR_BOARD_ID=virt-ai-pcie AI_TENSOR_BACKEND=virt-card \
#     bash monorepo-soak/run-ai-tensor-frameworks.sh --tcp
#   bash monorepo-soak/run-ai-tensor-frameworks.sh --backend sim --suites torch,tf
#
# Env (set by build-platform tensor frameworks):
#   AI_TENSOR_DIR, AI_TENSOR_BOARD_ID, AI_TENSOR_BACKEND, AI_TENSOR_CORE
#   AI_TENSOR_UIO, AI_TENSOR_VIRT_MODE, CVA6_FROM_TIMING / FROM_TIMING
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="${AI_TENSOR_DIR:-$ROOT/ai-tensor}"
REG="$PKG/tools/frameworks_regress.py"
if [[ ! -f "$REG" ]]; then
  echo "frameworks_regress missing: $REG"
  exit 1
fi
export AI_TENSOR_MONOREPO="${AI_TENSOR_MONOREPO:-$ROOT}"
export AI_TENSOR_BOARD_ID="${AI_TENSOR_BOARD_ID:-virt-ai-pcie}"
export AI_TENSOR_BACKEND="${AI_TENSOR_BACKEND:-virt-card}"
export PYTHONPATH="${PKG}/python:${PKG}/tools${PYTHONPATH:+:$PYTHONPATH}"
cd "$PKG"
# shellcheck disable=SC2086
python3 "$REG" \
  --backend "${AI_TENSOR_BACKEND}" \
  --board "${AI_TENSOR_BOARD_ID}" \
  ${AI_TENSOR_CORE:+--core "$AI_TENSOR_CORE"} \
  ${AI_TENSOR_VIRT_MODE:+--virt-mode "$AI_TENSOR_VIRT_MODE"} \
  "$@"
echo "run-ai-tensor-frameworks: ok"
