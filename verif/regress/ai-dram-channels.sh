#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Build-platform wrapper: DramChannels stripe N=1/2/4/8 (class-1 LiteDRAM).
# Invoked by `cva6-build test --ai --channels 4`. Not Variane.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec "$ROOT/verif/tb/ai_island/run-dram-channels.sh"
