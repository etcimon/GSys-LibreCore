#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# FSE S1–S3 path gate + real lint commands.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

if command -v pwsh >/dev/null 2>&1; then
  pwsh -NoProfile -File verif/regress/spec-deep-path.ps1
  exit $?
fi

# Minimal bash fallback of artifact checks + lint
test -f core/include/cv64a6_spec_deep_config_pkg.sv
test -f core/frontend/g6lc_bp_ckpt.sv
test -f core/ooo/g6lc_memdep.sv
test -f architecture/out-of-order/recovery-timeline.md
grep -q "DeepSpecEn: bit'(1)" core/include/cv64a6_spec_deep_config_pkg.sv

if command -v bun >/dev/null 2>&1; then
  bun build-platform/src/cli/index.ts verify --lint --target cv64a6_spec_deep
  bun build-platform/src/cli/index.ts verify --lint --target g6lc64_ooo
fi
echo "[spec-deep-path] PASS"
exit 0
