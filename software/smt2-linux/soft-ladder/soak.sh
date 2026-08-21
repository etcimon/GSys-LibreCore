#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Generic slfix OpenSBI soak. Future increments: bash soak.sh
# (no per-increment soak_<id>.sh).
#   SOAK_WHAT=hold            # hold only (hygiene)
#   SOAK_WHAT=hold,nat        # skip peel
#   SOAK_PARALLEL=0           # serial
#   CVA6_COOKIE_EXIT=0        # burn full SOAK_CYCLES
set -uo pipefail
# shellcheck source=soak_common.sh
. "$(cd "$(dirname "$0")" && pwd)/soak_common.sh"
soft_ladder_soak_main "$@"
