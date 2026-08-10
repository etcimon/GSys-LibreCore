#!/bin/bash
# SPDX-License-Identifier: MIT
# Thin monorepo adapter: spawn ai-tensor package tests without linking crates into RTL.
# Usage: bash monorepo-soak/run-ai-tensor.sh [check|test|golden|cosim]
#
# Env:
#   AI_TENSOR_DIR          package root (default: $ROOT/ai-tensor)
#   AI_TENSOR_COSIM_CMD    override external harness (default: python3 tools/cosim_harness.py)
#   AI_TENSOR_RUN_RTL=1    soft-probe monorepo island soak scripts (cosim only)
#   AI_TENSOR_RTL_CMD      optional long TB command when RUN_RTL=1
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="${AI_TENSOR_DIR:-$ROOT/ai-tensor}"
if [[ ! -d "$PKG" ]]; then
  echo "ai-tensor not found at $PKG (set AI_TENSOR_DIR)"
  exit 1
fi
export PATH="${PATH:-/usr/bin}"
export AI_TENSOR_MONOREPO="${AI_TENSOR_MONOREPO:-$ROOT}"
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
  test)
    python3 tools/check_independence.py
    cargo test --workspace --exclude ai-tensor-py
    export AI_TENSOR_COSIM_CMD="$HARNESS_CMD"
    cargo run -q -p ai-tensor-cli -- golden-check
    cargo run -q -p ai-tensor-cli -- doctor --profile profiles/island-p3-v1.toml
    ;;
  *)
    echo "usage: $0 [check|test|golden|cosim]"
    exit 2
    ;;
esac
echo "run-ai-tensor: ok ($CMD)"
