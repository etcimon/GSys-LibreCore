#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# Dispatch leaf with the early IQ steer profile (IqSteerStages=2).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$HERE/run_hyp8_leaf_local.sh" dispatch "${1:-steer2}" -DG6LC_HYP8_IQSTEER2 > "$HERE/leaf-dispatch-steer2.log" 2>&1
echo LEAF_DONE >> "$HERE/leaf-dispatch-steer2.log"
