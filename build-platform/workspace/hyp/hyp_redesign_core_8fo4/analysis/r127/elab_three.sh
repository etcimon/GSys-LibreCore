#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# Elaborate the hyp8 core under the default binding, the staged-MMU define and
# the deep define; report fatal diagnostics per variant. Outputs under
# build-platform/workspace/build/hyp8-elab-<tag>{,-staged,-deep}.
#   bash analysis/r127/elab_three.sh <tag>
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../../../../.." && pwd)"
TAG="${1:?usage: elab_three.sh <tag>}"
B="$ROOT/build-platform/workspace/build"
bash "$HERE/elab_hierarchy.sh" "$B/hyp8-elab-$TAG" | tail -1
ELAB_DEFINES=+define+G6LC_HYP8_MMU_STAGED bash "$HERE/elab_hierarchy.sh" "$B/hyp8-elab-$TAG-staged" | tail -1
ELAB_DEFINES=+define+G6LC_HYP8_DEEP bash "$HERE/elab_hierarchy.sh" "$B/hyp8-elab-$TAG-deep" | tail -1
for d in "hyp8-elab-$TAG" "hyp8-elab-$TAG-staged" "hyp8-elab-$TAG-deep"; do
  echo "== $d errors=$(grep -c '%Error' "$B/$d/elab.log") fatal-class=$(grep -cE '%Warning-(WIDTH|IMPLICIT|MULTIDRIVEN|LATCH):' "$B/$d/elab.log")"
  grep '%Error' "$B/$d/elab.log" | head -3 | cut -c1-220
done
