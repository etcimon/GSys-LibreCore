#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# Run a tracedb report on the remote testharness (the database stays next to
# the logs it indexes).
#   tq.sh runs
#   tq.sh classes -r r127m -r r128b
#   tq.sh around -r r129-deep -e assert
#   tq.sh --ingest TAG [TAG ...]      (re)ingest runs, then list them
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../../../.." && pwd)"
DB="${HYP8_TRACEDB:-/opt/testharness/tracedb/hyp8-trace.sqlite}"
PROXY="python3 $ROOT/verif/regress/remote/testharness_proxy.py"
push() {  # one script, content-addressed so an edit is always picked up
  local f="$1" b64
  b64=$(base64 -w0 "$HERE/$f")
  $PROXY shell --allow-overlap "mkdir -p \$(dirname $DB) && echo $b64 | base64 -d > \$(dirname $DB)/$f" >/dev/null 2>&1
}
if [[ "${1:-}" == "--ingest" ]]; then
  shift
  push ingest.py
  $PROXY --timeout "${TQ_TIMEOUT:-3000}" shell --allow-overlap \
    "python3 \$(dirname $DB)/ingest.py --db $DB ${TQ_INGEST_ARGS:-} $*" 2>&1 | grep -v 'th-proxy\]'
  exit 0
fi
push query.py
args=""
for a in "$@"; do args+=" $(printf '%q' "$a")"; done
$PROXY --timeout "${TQ_TIMEOUT:-300}" shell --allow-overlap \
  "python3 \$(dirname $DB)/query.py --db $DB $args" 2>&1 | grep -v 'th-proxy\]'
