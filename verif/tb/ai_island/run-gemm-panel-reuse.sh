#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# One class-0 channel, reuse elaborated, panel M/N bounds.
# Not the live package: VaTurboEn stays 0 there.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"
export AI_ISLAND_DRAM_CHANNELS=1
export MAX_M=1024
export MAX_N=512
export MAX_K=16
export REUSE_EN=1
export PE_LANES=8
export AI_GEMM_PANEL_REUSE=1
export AI_GEMM_BACKEND_OUT="${AI_GEMM_PANEL_OUT:-/tmp/g6lc-ai-gemm-panel}"
exec bash "$here/run-gemm-backend.sh"
