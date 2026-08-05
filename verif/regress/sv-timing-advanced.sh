#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Advanced host gate: multi-flist sparse screen + auto-correct emit + optional
# pyslang/slang smoke on emitted tree (realistic workspace out-dir).

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
# shellcheck source=../sv-timing-tests/scripts/common.sh
source "$ROOT/verif/sv-timing-tests/scripts/common.sh"

svt_need_bun
OUT="$(svt_out_base "$ROOT")/advanced"
svt_ensure_dir "$OUT"
MHZ="${SVT_TARGET_MHZ:-1250}"

# 1) Fixture always — compile + correct emit into dedicated --output packages
echo "[sv-timing-advanced] fixture compile + correct emit"
svt_timings "$ROOT" compile \
  --flist verif/sv-timing-tests/flists/fixture_project_mini.f \
  --all-modules \
  --target-mhz "$MHZ" \
  --output "$OUT/fixture"
svt_timings "$ROOT" correct \
  --flist verif/sv-timing-tests/flists/fixture_project_mini.f \
  --all-modules \
  --target-mhz 2500 \
  --allow-latency --assume-clk --emit \
  --output "$OUT/fixture-corrected"

# 2) Sparse frontend + EX flists (soft on analyze fail)
for name in sparse_frontend sparse_ex_units; do
  fl="verif/sv-timing-tests/flists/${name}.f"
  echo "[sv-timing-advanced] screen $name → --output $OUT/$name"
  set +e
  svt_timings "$ROOT" compile \
    --flist "$fl" \
    --all-modules \
    --target-mhz "$MHZ" \
    --output "$OUT/$name"
  set -e
done

# 3) Optional APU glue if ariane.sv exists
if [[ -f corev_apu/src/ariane.sv ]]; then
  echo "[sv-timing-advanced] sparse apu glue (soft)"
  set +e
  svt_timings "$ROOT" flist \
    --flist verif/sv-timing-tests/flists/sparse_apu_glue.f \
    --out "$OUT/apu-portable.f"
  set -e
fi

# 4) Optional pyslang smoke on fixture emit
EMIT_F="$OUT/fixture-corrected/svt_corrected.f"
if [[ -f "$EMIT_F" ]]; then
  if [[ -x "$ROOT/sv-timing/.tools/python-venv/Scripts/python.exe" ]]; then
    VPY="$ROOT/sv-timing/.tools/python-venv/Scripts/python.exe"
  elif [[ -x "$ROOT/sv-timing/.tools/python-venv/bin/python" ]]; then
    VPY="$ROOT/sv-timing/.tools/python-venv/bin/python"
  else
    VPY=""
  fi
  if [[ -n "$VPY" ]]; then
    echo "[sv-timing-advanced] pyslang smoke on emit (if installed)"
    set +e
    "$VPY" - <<'PY' "$OUT/fixture-corrected"
import sys
from pathlib import Path
root = Path(sys.argv[1])
files = list(root.rglob("*.sv"))
print(f"[pyslang-smoke] {len(files)} sv files under {root}")
try:
    import pyslang
except ImportError:
    print("[pyslang-smoke] pyslang not installed — skip")
    sys.exit(0)
ok = 0
for f in files[:20]:
    try:
        tree = pyslang.SyntaxTree.fromFile(str(f))
        ok += 1
    except Exception as e:
        print(f"[pyslang-smoke] warn {f.name}: {e}")
print(f"[pyslang-smoke] parsed_ok={ok}")
sys.exit(0)
PY
    set -e
  fi
fi

test -f "$OUT/fixture-analyze.json"
echo "[sv-timing-advanced] PASS"
