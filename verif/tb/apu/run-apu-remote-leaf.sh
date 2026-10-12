#!/usr/bin/env bash
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
# run-apu-remote-leaf — run the entire APU/Venus regression launcher on an
# isolated remote source snapshot through the testharness proxy.
#
#   run-apu-remote-leaf.sh
#
# APU_LEAF_STAGES (default unit,top,soc,bridge,synth) selects the stages;
# APU_LEAF_TIMEOUT (default 21600) bounds the proxy's overall poll budget.
# Selected-stage evidence on an isolated snapshot, not device qualification.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
exec python3 "$ROOT/verif/regress/remote/testharness_proxy.py" \
  --timeout "${APU_LEAF_TIMEOUT:-21600}" \
  apu-leaf "$ROOT" --stages "${APU_LEAF_STAGES:-unit,top,soc,bridge,synth}"
