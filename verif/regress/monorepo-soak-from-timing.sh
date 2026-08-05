#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Package-first monorepo soak → from-timing package → optional OpenSTA handoff.
# Does NOT require bun for analyze/correct; bun only for optional sta-handoff.
#
#   bash verif/regress/monorepo-soak-from-timing.sh
#   SVT_EMIT=1 SVT_STA_HANDOFF=1 bash verif/regress/monorepo-soak-from-timing.sh
#
# Fix priority: sv-timing package first (AGENTS-coding-philosophy §2.8).

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SVT="$ROOT/sv-timing"
OUT="${SVT_SOAK_OUT:-$ROOT/build-platform/workspace/build/sv-timing/monorepo-soak}"
PROFILE="${SVT_PROFILE:-sparse_ex}"
EMIT="${SVT_EMIT:-1}"
HANDOFF="${SVT_STA_HANDOFF:-0}"
ALLOW="${SVT_ALLOW_LATENCY:-1}"

if [[ ! -d "$SVT" ]]; then
  echo "[soak-from-timing] sv-timing/ missing"
  exit 1
fi

export CVA6_REPO_DIR="${CVA6_REPO_DIR:-$ROOT}"
export SVT_MONOREPO_ROOT="${SVT_MONOREPO_ROOT:-$ROOT}"

echo "[soak-from-timing] monorepo-soak profile=$PROFILE out=$OUT"
ARGS=(--profile "$PROFILE" --out-dir "$OUT" --correct)
if [[ "$ALLOW" == "1" ]]; then
  ARGS+=(--allow-latency)
fi
if [[ "$EMIT" == "1" ]]; then
  ARGS+=(--emit)
fi
if [[ "$HANDOFF" == "1" ]]; then
  ARGS+=(--sta-handoff --try-tools)
  if [[ "$EMIT" == "1" ]]; then
    ARGS+=(--use-emit)
  fi
fi

# Prefer WSL/system cargo when Windows MSVC link.exe is absent.
cd "$SVT"
if command -v python3 >/dev/null 2>&1; then
  PY=python3
else
  PY=python
fi
set +e
$PY tools/svt.py monorepo-soak "${ARGS[@]}"
RC=$?
set -e

PKG="$OUT/$PROFILE"
if [[ ! -f "$PKG/portable.f" ]]; then
  echo "[soak-from-timing] package missing at $PKG (analyze may have failed; fix package first)"
  exit "${RC:-1}"
fi

echo "[soak-from-timing] package: $PKG"
if [[ -f "$PKG/from-timing-recipe.json" ]]; then
  echo "[soak-from-timing] recipe: $PKG/from-timing-recipe.json"
fi
if [[ -f "$OUT/soak-summary.md" ]]; then
  head -n 40 "$OUT/soak-summary.md" || true
fi

# Optional host validate via build-platform when bun present
if command -v bun >/dev/null 2>&1 && [[ -d "$ROOT/build-platform" ]]; then
  echo "[soak-from-timing] timings validate --from-timing"
  set +e
  (cd "$ROOT/build-platform" && bun run src/cli/index.ts timings validate --from-timing "$PKG")
  VRC=$?
  set -e
  if [[ $VRC -ne 0 ]]; then
    echo "[soak-from-timing] validate failed — package layout incomplete"
    exit 1
  fi
  if [[ "$HANDOFF" != "1" ]]; then
    echo "[soak-from-timing] (set SVT_STA_HANDOFF=1 for sta-handoff)"
  fi
else
  echo "[soak-from-timing] bun/build-platform absent — skip host validate"
fi

if [[ $RC -ne 0 ]]; then
  echo "[soak-from-timing] FAIL (see soak-summary; fix sv-timing first)"
  exit $RC
fi
echo "[soak-from-timing] PASS"
exit 0
