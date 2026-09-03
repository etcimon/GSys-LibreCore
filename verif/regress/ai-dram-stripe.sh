#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Class-0 SRAM DramChannels (cores + L2 + island). Not LiteDRAM, not Variane.
# Invoked by `cva6-build test --ai --channels 4`. Honors AI_ISLAND_DRAM_CHANNELS.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
"$ROOT/verif/tb/ai_island/run-dram-stripe.sh"
exec "$ROOT/verif/tb/ai_island/run-gemm-backend.sh"
