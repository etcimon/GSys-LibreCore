#!/usr/bin/env bash
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# build.sh — Top-level bootstrap entry (Linux/macOS/Git-Bash/WSL).
#
# Ensures Bun is available (installing it if necessary), then delegates every
# argument to the GSys LibreCore build platform. Examples:
#
#   ./build.sh probe              # capability boxes + install playbook
#   ./build.sh tools install sim  # or dual-hart / all / spike
#   ./build.sh diag run           # compartmentalized diagnostics
#   ./build.sh doctor
#   ./build.sh setup
#   ./build.sh build --iss verilator
#   ./build.sh test --suite smoke-cv64a6
#   ./build.sh config --json

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
platform_entry="$here/build-platform/src/cli/index.ts"

if ! command -v bun >/dev/null 2>&1; then
  echo "[build.sh] Bun not found; installing from https://bun.sh/install ..."
  curl -fsSL https://bun.sh/install | bash
  export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
  export PATH="$BUN_INSTALL/bin:$PATH"
fi

if ! command -v bun >/dev/null 2>&1; then
  echo "[build.sh] ERROR: Bun installation failed or is not on PATH." >&2
  echo "[build.sh] Install manually from https://bun.sh and re-run." >&2
  exit 1
fi

exec bun "$platform_entry" "$@"
