#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# Run several local hyp8 leaves in sequence and keep one log.
#   bash analysis/r127/run_leaves.sh <tag> <leaf> [leaf ...]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAG="${1:?usage: run_leaves.sh <tag> <leaf>...}"; shift
LOG="$HERE/leaves-$TAG.log"
: > "$LOG"
for l in "$@"; do
  bash "$HERE/run_hyp8_leaf_local.sh" "$l" "$TAG" >> "$LOG" 2>&1
done
echo LEAVES_DONE >> "$LOG"
