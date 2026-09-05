#!/usr/bin/env bash
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
exec python3 "$ROOT/verif/regress/ai-desc-formats.py" "$@"
