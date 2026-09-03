#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Build-platform wrapper: class-1 LiteDRAM AXI→native wrap TB.
# Invoked by `cva6-build test --suite ai-litedram-wrap` / `test --ai --ai-dram 1`.
# Not Variane. Soft-skips without Verilator or generated litedram_core.v.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec "$ROOT/verif/tb/ai_island/run-litedram-wrap.sh"
