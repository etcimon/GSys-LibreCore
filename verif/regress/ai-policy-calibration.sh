#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec python3 -B -m unittest discover -s "$ROOT/verif/tb/ai_island" -p 'test_*policy*.py' "$@"
