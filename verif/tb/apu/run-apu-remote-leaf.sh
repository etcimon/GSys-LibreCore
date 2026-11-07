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
# Short source-provisioned cohort:
#   APU_LEAF_STAGES=dev APU_DEV_COHORT=layout bash verif/tb/apu/run-apu-remote-leaf.sh
# Dev defaults to detached launch-only exit4; collect its tag before a PASS.
# APU_LEAF_DETACH=0 opts into synchronous CI.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
stages="${APU_LEAF_STAGES:-unit,top,soc,bridge,synth}"
wait=21600
args=()
if [[ "$stages" == dev ]]; then
  wait=4200
  args+=(--suite-timeout "${APU_DEV_SUITE_TIMEOUT:-2400}" --poll-interval 5)
fi
detach="${APU_LEAF_DETACH:-0}"
[[ "$stages" != dev ]] || detach="${APU_LEAF_DETACH:-1}"
[[ "$detach" == 0 || "$detach" == 1 ]] || { echo "APU_LEAF_DETACH must be 0 or 1" >&2; exit 2; }
[[ "$detach" == 0 ]] || args+=(--detach)
if [[ ",$stages," == *,dev,* ]]; then
  for key in APU_DEV_COHORT APU_DEV_TEST_TIMEOUT APU_DEV_BUILD_TIMEOUT \
             APU_TOOL_SETUP_TIMEOUT APU_AUTO_INSTALL APU_SIM_PGO_TIMEOUT \
             APU_SIM_BUILD_TIMEOUT APU_SIM_TRAIN_TIMEOUT; do
    if [[ -n "${!key:-}" ]]; then
      args+=(--env "$key=${!key}")
    fi
  done
fi
rc=0
python3 "$ROOT/verif/regress/remote/testharness_proxy.py" \
  --timeout "${APU_LEAF_TIMEOUT:-$wait}" \
  apu-leaf "$ROOT" --stages "$stages" "${args[@]}" || rc=$?
if [[ "$rc" == 0 && "$detach" == 1 ]]; then
  echo "INCOMPLETE: launch only; apu-leaf-collect <tag> must validate completion"
  exit 4
fi
exit "$rc"
