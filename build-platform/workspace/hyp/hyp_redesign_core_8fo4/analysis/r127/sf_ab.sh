#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# A/B of the snoop-filter unit bench: HEAD's file (saved copy) vs the working tree.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../../../../.." && pwd)"
W="$ROOT/build-platform/workspace/build"
bash "$HERE/run_sf_bench.sh" head "$W/r127-whatif/g6lc_snoop_filter.head.sv" > "$W/r127-apu-sf-head.txt" 2>&1
bash "$HERE/run_sf_bench.sh" r127 > "$W/r127-apu-sf-r127.txt" 2>&1
grep '^SF c' "$W/r127-apu-sf-head.txt" > "$W/sf-a.txt"
grep '^SF c' "$W/r127-apu-sf-r127.txt" > "$W/sf-b.txt"
cut -c1-150 "$W/sf-b.txt"
tail -1 "$W/r127-apu-sf-head.txt"; tail -1 "$W/r127-apu-sf-r127.txt"
cmp "$W/sf-a.txt" "$W/sf-b.txt" && echo SF_LINES_IDENTICAL_HEAD_VS_R127
