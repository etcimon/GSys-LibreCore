#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Build-platform wrapper: class-0 Cas=14 page-timing TB.
# Invoked by `cva6-build test --ai --ai-ghz 1.25` / `--from-timing`. Not STA.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec "$ROOT/verif/tb/ai_island/run-dram-timing.sh"
