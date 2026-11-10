#!/usr/bin/env bash
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
# Coverage-tiered Storamic CI gate (build-platform suite storamic-ci); see run_ci.py.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
exec python3 -B "$ROOT/verif/tb/storamic/run_ci.py" "$@"
