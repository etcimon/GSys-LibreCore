#!/bin/bash
# SPDX-License-Identifier: MIT
# Structured PyTorch validation of ai-tensor ↔ ai_island features via virt-ai-pcie.
#
# Preferred entry: build-platform
#   bun run src/cli/index.ts tensor pytorch --board virt-ai-pcie --core g6lc64_ai
#   bun run src/cli/index.ts tensor pytorch --board virt-ai-pcie --core g6lc64_ai --from-timing <dir>
#
# Direct:
#   bash monorepo-soak/run-ai-tensor-pytorch.sh
#   AI_TENSOR_REQUIRE_TORCH=1 bash monorepo-soak/run-ai-tensor-pytorch.sh
#
# Env (from board.json ai{} / --core / --from-timing):
#   AI_TENSOR_BOARD_ID   default virt-ai-pcie
#   AI_TENSOR_BACKEND    default virt-card
#   AI_TENSOR_CORE       default g6lc64_ai  (ai_island package)
#   AI_TENSOR_UIO        virt://virt-ai-pcie/island0
#   AI_TENSOR_VIRT_MODE  auto|local|tcp
#   CVA6_FROM_TIMING / FROM_TIMING  optional preflight export
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="${AI_TENSOR_DIR:-$ROOT/ai-tensor}"
TEST="$PKG/python/tests/test_torch_virt_ai_island.py"
if [[ ! -f "$TEST" ]]; then
  echo "pytorch test missing: $TEST"
  exit 1
fi

export AI_TENSOR_DIR="$PKG"
export AI_TENSOR_MONOREPO="${AI_TENSOR_MONOREPO:-$ROOT}"
export AI_TENSOR_BOARD_ID="${AI_TENSOR_BOARD_ID:-virt-ai-pcie}"
export AI_TENSOR_BACKEND="${AI_TENSOR_BACKEND:-virt-card}"
export AI_TENSOR_CORE="${AI_TENSOR_CORE:-g6lc64_ai}"
export AI_TENSOR_UIO="${AI_TENSOR_UIO:-virt://virt-ai-pcie/island0}"
export PYTHONPATH="${PKG}/python:${PKG}/tools${PYTHONPATH:+:$PYTHONPATH}"

echo "run-ai-tensor-pytorch: board=${AI_TENSOR_BOARD_ID} core=${AI_TENSOR_CORE} backend=${AI_TENSOR_BACKEND}"
if [[ -n "${CVA6_FROM_TIMING:-${FROM_TIMING:-}}" ]]; then
  echo "run-ai-tensor-pytorch: from-timing=${CVA6_FROM_TIMING:-$FROM_TIMING}"
fi

# Prefer AI_TENSOR_PYTHON, else python3 that can import torch, else python3.
PY="${AI_TENSOR_PYTHON:-}"
if [[ -z "$PY" ]]; then
  if command -v python3 >/dev/null 2>&1 && python3 -c "import torch" >/dev/null 2>&1; then
    PY=python3
  elif command -v python >/dev/null 2>&1 && python -c "import torch" >/dev/null 2>&1; then
    PY=python
  else
    PY=python3
  fi
fi
echo "run-ai-tensor-pytorch: python=${PY}"

cd "$PKG"
# shellcheck disable=SC2086
"$PY" "$TEST" \
  --board "${AI_TENSOR_BOARD_ID}" \
  --core "${AI_TENSOR_CORE}" \
  ${AI_TENSOR_VIRT_MODE:+--virt-mode "$AI_TENSOR_VIRT_MODE"} \
  ${AI_TENSOR_REQUIRE_TORCH:+--require-torch} \
  "$@"

echo "run-ai-tensor-pytorch: ok"
