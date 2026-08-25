#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# One-shot remote shell helper for testharness_proxy.py.
#
# Running the proxy directly from PowerShell needs three nested quoting levels
# (pwsh -> wsl bash -c -> proxy shell "..."), and a single unbalanced quote
# leaves the local shell on a continuation prompt with no output. This wrapper
# collapses that to one level: everything after the script name is forwarded
# verbatim as the remote command.
#
# Usage:
#   wsl -e bash /mnt/e/cva6/verif/regress/remote/thsh.sh tail -n 20 /path/log
#   wsl -e bash /mnt/e/cva6/verif/regress/remote/thsh.sh 'tmux ls; echo ---; date'
#
# Env:
#   TH_SHELL_TIMEOUT   seconds before the proxy kills the remote command (default 60)

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"

if [[ $# -eq 0 ]]; then
  echo "usage: $0 <remote command...>" >&2
  exit 2
fi

if [[ $# -eq 1 ]]; then
  CMD="$1"
else
  CMD="$(printf '%q ' "$@")"
fi

exec python3 verif/regress/remote/testharness_proxy.py shell --no-hang "$CMD"
