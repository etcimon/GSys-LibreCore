#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# Positive-milestone status of detached hyp8 witnesses (read-only). Console
# milestones are read from the run's uart.txt; fatal classes from run-hyp8.log
# (the harness' "R Response Errored" %Warning lines are not counted).
#   bash analysis/r127/remote_witness_status.sh <witness-tag> [witness-tag ...]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../../../../.." && pwd)"
L="$ROOT/build-platform/workspace/build/r127-remote"; mkdir -p "$L"
{
  echo 'for t in '"$*"'; do'
  echo '  d=/opt/testharness/runs/$t/output; f=$d/run-hyp8.log; u=$d/uart.txt'
  echo '  pid=$(python3 -c "import json;print(json.load(open(\"$d/witness.json\"))[\"pid\"])" 2>/dev/null)'
  echo '  alive=dead; [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && alive=alive'
  echo '  echo "WITNESS $t pid=$pid $alive log_bytes=$(stat -c %s $f 2>/dev/null) uart_bytes=$(stat -c %s $u 2>/dev/null)"'
  echo '  echo "  uart: opensbi=$(grep -a -c -i "opensbi" $u 2>/dev/null) linux_version=$(grep -a -c "Linux version" $u 2>/dev/null) init_up=$(grep -a -c "G6LC_LINUX_INIT_UP" $u 2>/dev/null) shell=$(grep -a -c "G6LC_LINUX_SHELL" $u 2>/dev/null) panic=$(grep -a -c -i "panic\|Oops" $u 2>/dev/null)"'
  echo '  echo "  log: fatal=$(grep -a -c -E "%Fatal|%Error" $f) equiv_err=$(grep -a -c -E "equiv [a-z]|two-phase split" $f) hang=$(grep -a -c "hang-dump\|HANG" $f)"'
  echo '  grep -a -m2 -E "%Fatal|%Error|equiv [a-z]" $f | cut -c1-200'
  echo '  grep -a "stall-census. periodic cyc" $f | grep -a "ret=" | tail -1 | cut -c1-110'
  echo '  tail -c 300 $u 2>/dev/null | tr -d "\r" | tail -3 | cut -c1-160'
  echo 'done'
  echo 'uptime'
} > "$L/witness-status.cmd"
cd "$ROOT"
timeout 260 python3 verif/regress/remote/testharness_proxy.py shell --allow-overlap --no-hang --cmd-file build-platform/workspace/build/r127-remote/witness-status.cmd > "$L/witness-status.out" 2>&1
grep -v 'th-proxy\]' "$L/witness-status.out" | cut -c1-220
