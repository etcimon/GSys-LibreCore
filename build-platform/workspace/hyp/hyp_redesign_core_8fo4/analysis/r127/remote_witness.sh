#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# Launch a DETACHED OpenSBI/Linux witness on an r127 integration model (the r126
# recipe: same frozen fw_payload.elf, same plusargs). Never touches other runs.
#   bash analysis/r127/remote_witness.sh <integration-tag> <witness-tag>
# e.g. remote_witness.sh hyp8-r127d-aggregate-t1 hyp8-osbi-scalar-r127d
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../../../../.." && pwd)"
INT="${1:?integration tag}"; WIT="${2:?witness tag}"
L="$ROOT/build-platform/workspace/build/r127-remote"; mkdir -p "$L"
cd "$ROOT"
python3 verif/regress/remote/testharness_proxy.py --timeout 0 py --tag "$WIT" --threads 1 \
  --env HYP8_INT_TAG="$INT" \
  --env HYP8_FW_SHA256=30e1311e494000032d3db67e771c4878ea16aaabb0810a489b3da1bda2c77545 \
  --env HYP8_TOHOST=0x80041730 --env HYP8_MAX_CYCLES=3000000000 \
  --env "HYP8_PLUSARGS=+time_out=3000000000 +stall_census +hang_dump=2000 +equiv_report +rvfi_cycle_stamp +seq_gap_trace +seq_gap_limit=200" \
  verif/regress/remote/run_hyp8_witness.py > "$L/$WIT.launch.log" 2>&1
echo "launch rc=$? $(grep -m1 'launched pid' "$L/$WIT.launch.log" | cut -c1-160)"
grep -m3 -E 'ERROR|refusing|Traceback|AssertionError' "$L/$WIT.launch.log" | cut -c1-200
