#!/bin/bash
# SPDX-License-Identifier: MIT
# Hostless smoke: virtual PCIe AI card (soft UIO/eventfd, no kernel, no real PCIe).
# Usage: bash monorepo-soak/run-virt-ai-card.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SMOKE="$ROOT/ai-tensor/tools/virt_ai_card/smoke.py"
if [[ ! -f "$SMOKE" ]]; then
  echo "virt_ai_card smoke missing: $SMOKE"
  exit 1
fi
export PYTHONPATH="${ROOT}/ai-tensor/tools${PYTHONPATH:+:$PYTHONPATH}"
python3 "$SMOKE"
echo "run-virt-ai-card: ok"
