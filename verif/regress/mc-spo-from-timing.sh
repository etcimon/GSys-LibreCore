#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Auto-correct sparse core package → FO4 before/after report → mc-spo-soak + diag
# with --from-timing (and --use-emit when corrected/ exists).
#
#   bash verif/regress/mc-spo-from-timing.sh
#   SVT_EMIT=0 bash verif/regress/mc-spo-from-timing.sh   # dry-run correct only
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export CVA6_REPO_DIR="${CVA6_REPO_DIR:-$ROOT}"
export SVT_MONOREPO_ROOT="${SVT_MONOREPO_ROOT:-$ROOT}"
PKG="${SVT_PKG:-$ROOT/build-platform/workspace/build/sv-timing/monorepo-soak/sparse_ex}"
OUT_PARENT="$(dirname "$PKG")"
PROFILE="${SVT_PROFILE:-sparse_ex}"
DO_EMIT="${SVT_EMIT:-1}"
DO_SPO="${SVT_RUN_SPO:-1}"
DO_DIAG="${SVT_RUN_DIAG:-1}"

echo "[mc-spo-from-timing] ROOT=$ROOT"
echo "[mc-spo-from-timing] PKG=$PKG profile=$PROFILE emit=$DO_EMIT"

# Prefer WSL/system cargo for sv-timing CLI
if [[ -f "$HOME/.cargo/env" ]]; then
  # shellcheck disable=SC1091
  source "$HOME/.cargo/env"
fi

cd "$ROOT/sv-timing"
ARGS=(--profile "$PROFILE" --out-dir "$OUT_PARENT" --correct --allow-latency)
if [[ "$DO_EMIT" == "1" ]]; then
  ARGS+=(--emit)
fi
set +e
python3 tools/monorepo_soak.py "${ARGS[@]}"
SOAK_RC=$?
set -e
echo "[mc-spo-from-timing] monorepo-soak exit=$SOAK_RC"

python3 - "$PKG" <<'PY'
import json, sys
from pathlib import Path
pkg = Path(sys.argv[1])
print("=== PACKAGE ===", pkg)
c = {}
a = {}
if (pkg / "correct.json").is_file():
    c = json.loads((pkg / "correct.json").read_text(encoding="utf-8"))
if (pkg / "analyze.json").is_file():
    a = json.loads((pkg / "analyze.json").read_text(encoding="utf-8"))
print("=== FO4 BEFORE / AFTER ===")
print("max_path_fo4_before:", c.get("max_path_fo4_before"))
print("max_path_fo4_after:", c.get("max_path_fo4_after"))
print("edits:", len(c.get("edits") or []))
print("dry_run:", c.get("dry_run"))
print("integrity:", c.get("integrity"))
pc = c.get("post_closure") or {}
print("post_closes:", pc.get("closes"))
print("post_max_freq_mhz:", pc.get("max_freq_mhz"))
print("post_worst_fo4:", pc.get("worst_path_fo4"))
print("density_score:", (c.get("density") or {}).get("score"))
print("=== EDITS (manual verification anchors) ===")
for i, e in enumerate(c.get("edits") or [], 1):
    if isinstance(e, dict):
        loc = e.get("location") or e.get("loc") or e.get("file") or ""
        kind = e.get("kind") or e.get("pass") or e.get("op") or ""
        detail = e.get("detail") or e.get("message") or e.get("summary") or ""
        print(f"  [{i}] kind={kind} loc={loc} {detail}"[:240])
        # dump compact json for remaining keys
        print(f"       raw={json.dumps(e, ensure_ascii=False)[:280]}")
    else:
        print(f"  [{i}] {e}")
print("=== KEY PACKAGE PATHS ===")
for name in (
    "portable.f",
    "portable.host.f",
    "analyze.json",
    "correct.json",
    "stamp.json",
    "param-map.json",
    "from-timing-recipe.json",
    "corrected/svt_corrected.f",
    "corrected/svt_emit_manifest.json",
):
    p = pkg / name
    print(("OK      " if p.is_file() else "MISSING "), p)
print("=== EMIT TREE (precompiled review-only) ===")
corr = pkg / "corrected"
emit_files = []
if corr.is_dir():
    for p in sorted(corr.rglob("*")):
        if p.is_file():
            emit_files.append(str(p))
            print("  ", p)
else:
    print("  (no corrected/ — dry-run only)")
print("=== ANALYZE HOTTEST (before correct) ===")
paths = [x for x in (a.get("paths") or []) if isinstance(x, dict)]

def tf(p):
    return float(p.get("total_fo4") or p.get("totalFo4") or 0)

for p in sorted(paths, key=tf, reverse=True)[:12]:
    print(f"  fo4={tf(p):7.1f}  {p.get('kind')}  {p.get('start')} -> {p.get('end')}")
rep = {
    "package": str(pkg),
    "fo4_before": c.get("max_path_fo4_before"),
    "fo4_after": c.get("max_path_fo4_after"),
    "edits_count": len(c.get("edits") or []),
    "edits": c.get("edits"),
    "integrity": c.get("integrity"),
    "post_closure": pc,
    "density": c.get("density"),
    "emit_files": emit_files,
    "analyze_hot": [
        {
            "total_fo4": tf(p),
            "kind": p.get("kind"),
            "start": p.get("start"),
            "end": p.get("end"),
        }
        for p in sorted(paths, key=tf, reverse=True)[:12]
    ],
}
out = pkg / "spo-from-timing-report.json"
out.write_text(json.dumps(rep, indent=2) + "\n", encoding="utf-8")
print("wrote", out)
PY

if [[ ! -f "$PKG/portable.f" && ! -f "$PKG/portable.host.f" ]]; then
  echo "[mc-spo-from-timing] no package portable.f — abort"
  exit 1
fi

# Ensure Windows-host portable when we have WSL native paths only
if [[ -f "$PKG/portable.f" ]] && grep -q '/mnt/c/' "$PKG/portable.f" 2>/dev/null; then
  if [[ ! -f "$PKG/portable.host.f" ]]; then
    sed 's|/mnt/c/|C:/|g; s|/mnt/C/|C:/|g' "$PKG/portable.f" > "$PKG/portable.host.f"
    echo "[mc-spo-from-timing] wrote portable.host.f from WSL paths"
  fi
fi

cd "$ROOT/build-platform"
echo "[mc-spo-from-timing] timings validate + summary"
bun run src/cli/index.ts timings validate --from-timing "$PKG"
bun run src/cli/index.ts timings summary --from-timing "$PKG" || true

if [[ "$DO_SPO" == "1" ]]; then
  echo "[mc-spo-from-timing] === mc-spo-soak --from-timing (live RTL + package gate) ==="
  set +e
  bun run src/cli/index.ts test mc-spo-soak --from-timing "$PKG"
  SPO_RC=$?
  set -e
  echo "[mc-spo-from-timing] mc-spo-soak exit=$SPO_RC"

  if [[ -f "$PKG/corrected/svt_corrected.f" ]]; then
    echo "[mc-spo-from-timing] === mc-spo-soak --from-timing --use-emit ==="
    set +e
    bun run src/cli/index.ts test mc-spo-soak --from-timing "$PKG" --use-emit
    SPO_EMIT_RC=$?
    set -e
    echo "[mc-spo-from-timing] mc-spo-soak --use-emit exit=$SPO_EMIT_RC"
    echo "[mc-spo-from-timing] NOTE: --use-emit exports CVA6_TIMINGS_EMIT_FLIST; mc-spo-soak lint still uses live RTL unless consumers read emit flist."
  fi
fi

if [[ "$DO_DIAG" == "1" ]]; then
  echo "[mc-spo-from-timing] === diag --from-timing ==="
  set +e
  bun run src/cli/index.ts diag status --from-timing "$PKG"
  bun run src/cli/index.ts diag run core --from-timing "$PKG"
  DIAG_RC=$?
  set -e
  echo "[mc-spo-from-timing] diag exit=$DIAG_RC"
fi

echo "[mc-spo-from-timing] DONE"
echo "  package: $PKG"
echo "  report:  $PKG/spo-from-timing-report.json"
echo "  FO4: see report (before/after)"
echo "  manual:  $PKG/corrected/  (review-only; do not merge to core/)"
exit 0
