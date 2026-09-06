#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Canonical regression: multi-job policy walk through the DMA island.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
bash "$ROOT/verif/tb/ai_island/run-ai-island-policy-walk.sh"
