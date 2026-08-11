#!/bin/bash
# SPDX-License-Identifier: MIT
# Full ai-tensor hostless regress suitable for build-platform `tensor regress`:
#   1) virt-ai-pcie soft UIO/eventfd smoke (TCP + local)
#   2) frameworks regress (device + numpy + torch/tf if installed) via virt-card
#   3) optional package golden-check (set AI_TENSOR_REGRESS_GOLDEN=1)
#
# Usage:
#   bash monorepo-soak/run-ai-tensor-regress.sh
#   AI_TENSOR_BOARD_ID=virt-ai-pcie AI_TENSOR_CORE=g6lc64_ai \
#     bash monorepo-soak/run-ai-tensor-regress.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="${AI_TENSOR_DIR:-$ROOT/ai-tensor}"
export AI_TENSOR_DIR="$PKG"
export AI_TENSOR_MONOREPO="${AI_TENSOR_MONOREPO:-$ROOT}"
export AI_TENSOR_BOARD_ID="${AI_TENSOR_BOARD_ID:-virt-ai-pcie}"
export AI_TENSOR_BACKEND="${AI_TENSOR_BACKEND:-virt-card}"
export AI_TENSOR_CORE="${AI_TENSOR_CORE:-g6lc64_ai}"

echo "run-ai-tensor-regress: board=${AI_TENSOR_BOARD_ID} backend=${AI_TENSOR_BACKEND} core=${AI_TENSOR_CORE}"
if [[ -n "${CVA6_FROM_TIMING:-${FROM_TIMING:-}}" ]]; then
  echo "run-ai-tensor-regress: from-timing=${CVA6_FROM_TIMING:-$FROM_TIMING}"
fi

bash "$ROOT/monorepo-soak/run-virt-ai-card.sh"
bash "$ROOT/monorepo-soak/run-ai-tensor-frameworks.sh" --virt-mode local
# Also exercise TCP CardAgent path (virtual PCIe link) for device suite
bash "$ROOT/monorepo-soak/run-ai-tensor-frameworks.sh" --tcp --suites device
# Structured PyTorch suite (Device always; torch cases if installed)
bash "$ROOT/monorepo-soak/run-ai-tensor-pytorch.sh"

if [[ "${AI_TENSOR_REGRESS_GOLDEN:-0}" == "1" ]]; then
  bash "$ROOT/monorepo-soak/run-ai-tensor.sh" golden
fi

echo "run-ai-tensor-regress: PASS"
