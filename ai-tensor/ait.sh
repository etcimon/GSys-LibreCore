#!/usr/bin/env bash
# Thin wrapper → tools/ait.py
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$ROOT/tools/ait.py" "$@"
