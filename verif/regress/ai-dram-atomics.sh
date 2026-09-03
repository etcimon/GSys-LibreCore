#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Testharness exclusive-monitor write MLP. CLI: test --ai.
# Not Variane. Not LiteDRAM.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec "$ROOT/verif/tb/ai_island/run-dram-atomics.sh"
