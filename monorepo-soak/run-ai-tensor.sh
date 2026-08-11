#!/bin/bash
# SPDX-License-Identifier: MIT
# Thin monorepo adapter: spawn ai-tensor package tests without linking crates into RTL.
# Usage: bash monorepo-soak/run-ai-tensor.sh [check|test|golden|cosim|queue-soak|event-fd-soak|rtl|virt-card|frameworks|pytorch|regress]
#
# Env:
#   AI_TENSOR_DIR          package root (default: $ROOT/ai-tensor)
#   AI_TENSOR_COSIM_CMD    override external harness (default: python3 tools/cosim_harness.py)
#   AI_TENSOR_RUN_RTL=1    soft-probe monorepo island soak scripts (cosim only)
#   AI_TENSOR_RTL_CMD      override RTL smoke (default: monorepo-soak/run-ai-tensor-rtl.sh)
#   AI_TENSOR_RTL_HARD=1   live ai-matrix-veri subset (long; needs work-ver-ai)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="${AI_TENSOR_DIR:-$ROOT/ai-tensor}"
if [[ ! -d "$PKG" ]]; then
  echo "ai-tensor not found at $PKG (set AI_TENSOR_DIR)"
  exit 1
fi
export PATH="${PATH:-/usr/bin}"
export AI_TENSOR_MONOREPO="${AI_TENSOR_MONOREPO:-$ROOT}"
# Default lab RTL adapter (soft unless AI_TENSOR_RTL_HARD=1)
export AI_TENSOR_RTL_CMD="${AI_TENSOR_RTL_CMD:-bash $ROOT/monorepo-soak/run-ai-tensor-rtl.sh}"
cd "$PKG"
CMD="${1:-test}"
HARNESS_CMD="${AI_TENSOR_COSIM_CMD:-python3 tools/cosim_harness.py}"

case "$CMD" in
  check)
    python3 tools/check_independence.py
    ;;
  golden)
    export AI_TENSOR_COSIM_CMD="$HARNESS_CMD"
    cargo run -q -p ai-tensor-cli -- golden-check
    ;;
  cosim)
    export AI_TENSOR_COSIM_CMD="$HARNESS_CMD"
    python3 tools/cosim_harness.py <<'JSON'
{"op":"suite"}
JSON
    cargo run -q -p ai-tensor-cli -- golden-check
    ;;
  queue-soak)
    cargo run -q -p ai-tensor-cli -- queue-soak --backend sim
    cargo run -q -p ai-tensor-cli -- queue-soak --backend mmio
    cargo run -q -p ai-tensor-cli -- irq-soak --backend sim
    cargo run -q -p ai-tensor-cli -- irq-soak --backend mmio
    cargo run -q -p ai-tensor-cli -- depth-soak --depth 4 --mode latch --backend sim
    cargo run -q -p ai-tensor-cli -- depth-soak --depth 3 --mode fetch --backend mmio
    cargo run -q -p ai-tensor-cli -- history-soak --n 4 --backend mmio
    cargo run -q -p ai-tensor-cli -- event-fd-soak --backend sim
    cargo run -q -p ai-tensor-cli -- event-fd-soak --backend mmio
    ;;
  event-fd-soak)
    cargo run -q -p ai-tensor-cli -- event-fd-soak --backend sim
    cargo run -q -p ai-tensor-cli -- event-fd-soak --backend mmio
    ;;
  rtl)
    # Soft by default; hard when AI_TENSOR_RTL_HARD=1
    bash "$ROOT/monorepo-soak/run-ai-tensor-rtl.sh"
    ;;
  virt-card)
    # Hostless virtual PCIe AI card (soft UIO/eventfd; no kernel / real PCIe)
    bash "$ROOT/monorepo-soak/run-virt-ai-card.sh"
    ;;
  frameworks)
    # PyTorch/TF/numpy via Device (default backend virt-card / board virt-ai-pcie)
    bash "$ROOT/monorepo-soak/run-ai-tensor-frameworks.sh"
    ;;
  pytorch)
    # Structured PyTorch unittest: ai_island features through virt-ai-pcie
    bash "$ROOT/monorepo-soak/run-ai-tensor-pytorch.sh"
    ;;
  regress)
    # virt-card smoke + frameworks (local + tcp device) for build-platform tensor regress
    bash "$ROOT/monorepo-soak/run-ai-tensor-regress.sh"
    ;;
  test)
    python3 tools/check_independence.py
    cargo test --workspace --exclude ai-tensor-py
    export AI_TENSOR_COSIM_CMD="$HARNESS_CMD"
    cargo run -q -p ai-tensor-cli -- golden-check
    cargo run -q -p ai-tensor-cli -- queue-soak --backend sim
    cargo run -q -p ai-tensor-cli -- doctor --profile profiles/island-p3-v1.toml
    ;;
  *)
    echo "usage: $0 [check|test|golden|cosim|queue-soak|event-fd-soak|rtl|virt-card|frameworks|pytorch|regress]"
    exit 2
    ;;
esac
echo "run-ai-tensor: ok ($CMD)"
