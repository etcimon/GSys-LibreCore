#!/usr/bin/env bash
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Thin wrapper -> tools/g6q.py. NO BUSINESS LOGIC HERE (AGENTS.md §4).
# If you are about to add a branch to this file, port it to tools/g6q.py instead.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for py in python3 python; do
  if command -v "$py" >/dev/null 2>&1; then
    exec "$py" "$here/tools/g6q.py" "$@"
  fi
done

echo "g6q: no python3/python on PATH" >&2
exit 1
