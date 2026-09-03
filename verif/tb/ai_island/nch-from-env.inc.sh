# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Sourced by island TBs. Sets NCH_LIST from AI_ISLAND_DRAM_CHANNELS when it is
# a legal DramChannels value {1,2,4,8}; otherwise uses the caller defaults.
# Usage:
#   DEFAULT_NCHS=(1 2 4 8)
#   # shellcheck source=nch-from-env.inc.sh
#   . "$(dirname "$0")/nch-from-env.inc.sh"
if [[ "${AI_ISLAND_DRAM_CHANNELS:-}" =~ ^(1|2|4|8)$ ]]; then
  NCH_LIST=("${AI_ISLAND_DRAM_CHANNELS}")
else
  NCH_LIST=("${DEFAULT_NCHS[@]}")
fi
if [[ -n "${CVA6_FROM_TIMING:-}${FROM_TIMING:-}" ]]; then
  echo "[nch-from-env] from-timing=${CVA6_FROM_TIMING:-$FROM_TIMING} (FO4; not STA)"
fi
if [[ -n "${AI_ISLAND_GHZ:-}" ]]; then
  echo "[nch-from-env] ai-ghz=${AI_ISLAND_GHZ}"
fi
echo "[nch-from-env] class=${AI_ISLAND_DRAM_CLASS:-?} channels=${NCH_LIST[*]} flavour=${AI_MATRIX_FLAVOUR:-}"
