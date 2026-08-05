#!/usr/bin/env bash
# Recompile only ariane_tb.cpp + relink Variane_testharness (no full verilate).
set -euo pipefail
export ROOT=/mnt/e/cva6
cd "$ROOT/work-ver"
export SPIKE_INSTALL_DIR="$ROOT/build-platform/workspace/tooling/spike"
export LD_LIBRARY_PATH="$SPIKE_INSTALL_DIR/lib:${LD_LIBRARY_PATH:-}"
# Match prior build flags from Variane_testharness.mk if present
if [[ -f Variane_testharness.mk ]]; then
  echo "[tb-only] make -f Variane_testharness.mk (incremental)"
  make -f Variane_testharness.mk -j"$(nproc)" 2>&1 | tee "$ROOT/monorepo-soak/rebuild-tb-only.log"
else
  echo "[tb-only] no Variane_testharness.mk; full baseline rebuild required" >&2
  exit 1
fi
test -x "$ROOT/work-ver/Variane_testharness"
echo "[tb-only] OK $(ls -la "$ROOT/work-ver/Variane_testharness")"
