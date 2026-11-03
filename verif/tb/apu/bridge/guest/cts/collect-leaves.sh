#!/usr/bin/env bash
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
# Collect detached CTS apu-leaf runs as they finish, then harvest every
# retained TestResults.qpa and re-render the generated CTS ledger.
#
#   collect-leaves.sh [--max-seconds N] <apu-leaf-tag>...
#
# Polls the remote every 120 s for each tag's rc.txt (read-only), runs
# `apu-leaf-collect` once it exists, and re-renders
# architecture/uncore/apu-cts-ledger.md after each collection. Run it
# where rsync exists (WSL or Linux); stdin is detached from the proxy
# because its ssh would otherwise consume the tag list.
set -u
ROOT="$(cd "$(dirname "$0")/../../../../../.." && pwd)"
cd "$ROOT"
P=verif/regress/remote/testharness_proxy.py
L=corev_apu/apu/tools/cts_ledger.py
G=.cache/cts/groups.json
max=14400
if [ "${1:-}" = "--max-seconds" ]; then max="$2"; shift 2; fi
[ "$#" -gt 0 ] || { echo "usage: $0 [--max-seconds N] <apu-leaf-tag>..." >&2; exit 2; }
for t in "$@"; do
  [[ "$t" =~ ^apu-leaf-[0-9T]+-[0-9a-f]+$ ]] || { echo "not a leaf tag: $t" >&2; exit 2; }
done
deadline=$(( $(date +%s) + max ))
pending=("$@")

render() {
  python3 "$L" harvest --groups "$G" > /dev/null
  python3 "$L" render --groups "$G" \
    $(for f in .cache/cts/runs/*.json; do printf -- '--results %s ' "$f"; done) \
    --out architecture/uncore/apu-cts-ledger.md | tail -1
}

while [ "${#pending[@]}" -gt 0 ] && [ "$(date +%s)" -lt "$deadline" ]; do
  q=""
  for t in "${pending[@]}"; do q+="echo $t \$(cat runs/$t/rc.txt 2>/dev/null); "; done
  finished=$(timeout 90 python3 "$P" --timeout 60 shell "$q" < /dev/null 2>/dev/null \
             | awk 'NF == 2 { print $1 }')
  for t in $finished; do
    echo "$(date +%H:%M:%S) collect $t"
    timeout 300 python3 "$P" apu-leaf-collect "$t" < /dev/null 2>&1 | grep 'APU leaf'
    render
    keep=()
    for p in "${pending[@]}"; do [ "$p" = "$t" ] || keep+=("$p"); done
    pending=("${keep[@]}")
  done
  if [ "${#pending[@]}" -gt 0 ]; then sleep 120; fi
done
echo "COLLECT-END pending=${pending[*]:-none}"
[ "${#pending[@]}" -eq 0 ]
