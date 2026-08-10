#!/bin/bash
# SPDX-License-Identifier: MIT
# Thin monorepo adapter: spawn ai-tensor package tests without linking crates into RTL.
# Usage: bash monorepo-soak/run-ai-tensor.sh [check|test|golden]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="${AI_TENSOR_DIR:-$ROOT/ai-tensor}"
if [[ ! -d "$PKG" ]]; then
  echo "ai-tensor not found at $PKG (set AI_TENSOR_DIR)"
  exit 1
fi
export PATH="${PATH:-/usr/bin}"
cd "$PKG"
CMD="${1:-test}"
case "$CMD" in
  check)
    python3 tools/check_independence.py
    ;;
  golden)
    cargo run -q -p ai-tensor-cli -- golden-check
    ;;
  test)
    python3 tools/check_independence.py
    cargo test --workspace --exclude ai-tensor-py
    cargo run -q -p ai-tensor-cli -- golden-check
    cargo run -q -p ai-tensor-cli -- doctor --profile profiles/island-p3-v1.toml
    ;;
  *)
    echo "usage: $0 [check|test|golden]"
    exit 2
    ;;
esac
echo "run-ai-tensor: ok ($CMD)"
