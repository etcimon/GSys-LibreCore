#!/usr/bin/env bash
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Thin wrapper — all logic lives in tools/svt.py (see AGENTS-toolchain.md).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if command -v python3 >/dev/null 2>&1; then
  exec python3 "$HERE/tools/svt.py" "$@"
elif command -v python >/dev/null 2>&1; then
  exec python "$HERE/tools/svt.py" "$@"
else
  echo "[svt.sh] ERROR: need python3/python on PATH" >&2
  exit 1
fi
