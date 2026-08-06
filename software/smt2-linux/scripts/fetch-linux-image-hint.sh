#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Operator hint for R3b Linux Image (external; never committed).
# Does not download multi-GB trees by default — prints the supported paths.
#
# Usage:
#   bash software/smt2-linux/scripts/fetch-linux-image-hint.sh
#   CVA6_FETCH_IMAGE=1 bash software/smt2-linux/scripts/fetch-linux-image-hint.sh
#     (optional: only if CVA6_LINUX_IMAGE_URL is set)

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="${SMT2_LINUX_OUT:-$ROOT/build-platform/workspace/smt2-linux}"
mkdir -p "$OUT"

cat <<EOF
[r3b-image-hint] R3b needs a RISC-V 64-bit Linux kernel Image for OpenSBI FW_PAYLOAD.

Preferred sources (pick one):

  1) openhwgroup/cva6-sdk Buildroot (upstream)
       git clone https://github.com/openhwgroup/cva6-sdk.git
       # follow cva6-sdk README → produce images/Image (or similar)
       cp <sdk>/.../Image  $OUT/Image

  2) Distro / custom Buildroot / Yocto
       produce arch/riscv Image (not vmlinux ELF unless you know FW_PAYLOAD accepts it)
       place at:  $OUT/Image
       or export LINUX_IMAGE=/absolute/path/to/Image

  3) Prebuilt lab artifact
       export LINUX_IMAGE=/lab/path/Image

Then:

  # Contract only (soft-skip without Image):
  bash verif/regress/r3b-linux-image.sh

  # Build OpenSBI with Linux payload:
  LINUX_IMAGE=$OUT/Image CVA6_R3B_BUILD=1 bash verif/regress/r3b-linux-image.sh
  # or:
  make -C software/smt2-linux opensbi-linux

  # Optional RTL cosim (g6lc64_smt2 TB; long):
  CVA6_R3B_BUILD=1 CVA6_R3B_COSIM=1 LINUX_IMAGE=$OUT/Image \\
    bash verif/regress/r3b-linux-image.sh

Notes:
  - Images stay gitignored under build-platform/workspace/smt2-linux/
  - Dual-hart DTB is ariane-smt2.dts (embedded via FW_FDT_PATH)
  - Pass criteria R3b: shell + /proc/cpuinfo two processors (lab/manual or cosim UART)
  - Plan: architecture/multi-threading/smt-linux-rootfs.md
EOF

if [[ "${CVA6_FETCH_IMAGE:-0}" == "1" ]]; then
  url="${CVA6_LINUX_IMAGE_URL:-}"
  if [[ -z "$url" ]]; then
    echo "[r3b-image-hint] CVA6_FETCH_IMAGE=1 but CVA6_LINUX_IMAGE_URL unset — not fetching" >&2
    exit 2
  fi
  dest="$OUT/Image"
  echo "[r3b-image-hint] fetching $url -> $dest"
  curl -fL --retry 3 -o "$dest" "$url"
  ls -la "$dest"
  echo "[r3b-image-hint] set LINUX_IMAGE=$dest"
fi
