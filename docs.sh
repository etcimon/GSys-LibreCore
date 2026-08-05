#!/usr/bin/env bash
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# docs.sh — Bootstrap entry for the CVA6 Next.js documentation site.
#
# Ensures Bun is available (installing it if necessary), then runs the docs site
# under docs/website. Passes all arguments to the Next.js CLI.
#
#   ./docs.sh dev          # start local dev server
#   ./docs.sh build        # static export
#   ./docs.sh start        # serve the previously exported build

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
docs_dir="$here/docs/website"

if ! command -v bun >/dev/null 2>&1; then
  echo "[docs.sh] Bun not found; installing from https://bun.sh/install ..."
  curl -fsSL https://bun.sh/install | bash
  export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
  export PATH="$BUN_INSTALL/bin:$PATH"
fi

if ! command -v bun >/dev/null 2>&1; then
  echo "[docs.sh] ERROR: Bun installation failed or is not on PATH." >&2
  echo "[docs.sh] Install manually from https://bun.sh and re-run." >&2
  exit 1
fi

if [ ! -d "$docs_dir/node_modules" ]; then
  echo "[docs.sh] Installing docs dependencies in $docs_dir ..."
  (cd "$docs_dir" && bun install)
fi

cd "$docs_dir"
exec bun run "$@"
