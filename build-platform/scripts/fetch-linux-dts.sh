#!/usr/bin/env bash
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# fetch-linux-dts.sh — Sparse, blobless checkout of the Linux RISC-V device-tree
# sources (arch/riscv/boot/dts) and the relevant devicetree bindings YAML, for
# CVA6 RTL <-> Linux cross-validation. Companion map: ../../AGENTS-dts-validation.md
#
# Why NOT a git submodule: the full kernel is multi-GB and contains
# case-colliding paths that fail to check out on case-insensitive filesystems
# (Windows NTFS, default macOS APFS). A cone-mode sparse checkout combined with
# --filter=blob:none downloads only the few MB we actually need — the RISC-V
# device trees and their bindings — with no case collisions and full history
# omitted.
#
# Runs in bash and zsh. On Windows use fetch-linux-dts.ps1 instead.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: fetch-linux-dts.sh [options]
  --dir DIR    Destination checkout directory
               (default: build-platform/workspace/linux-dts, git-ignored)
  --url URL    Linux git remote (default: https://github.com/torvalds/linux.git)
  --ref REF    Branch or tag to track (default: master)
  --path P     Extra sparse path to include, repeatable
  -h, --help   Show this help

Environment overrides: LINUX_DTS_DIR, LINUX_DTS_URL, LINUX_DTS_REF
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
dest="${LINUX_DTS_DIR:-$script_dir/../workspace/linux-dts}"
url="${LINUX_DTS_URL:-https://github.com/torvalds/linux.git}"
ref="${LINUX_DTS_REF:-master}"

# Default sparse paths: the RISC-V DTS tree plus the bindings that CVA6 SoC
# device trees actually reference (CPU/ISA, interrupt controllers, timers/CLINT,
# caches). Override with --path if you need a different set.
default_paths=(
  "arch/riscv/boot/dts"
  "Documentation/devicetree/bindings/riscv"
  "Documentation/devicetree/bindings/interrupt-controller"
  "Documentation/devicetree/bindings/timer"
  "Documentation/devicetree/bindings/cache"
)
paths=()

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)  dest="$2";      shift 2 ;;
    --url)  url="$2";       shift 2 ;;
    --ref)  ref="$2";       shift 2 ;;
    --path) paths+=("$2");  shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "fetch-linux-dts: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

if [ ${#paths[@]} -eq 0 ]; then
  paths=("${default_paths[@]}")
fi

if ! command -v git >/dev/null 2>&1; then
  echo "fetch-linux-dts: ERROR: git is required but was not found on PATH." >&2
  exit 1
fi

# Cone sparse-checkout + partial clone need git >= 2.27.
ver="$(git --version | awk '{print $3}')"
major="${ver%%.*}"; rest="${ver#*.}"; minor="${rest%%.*}"
if [ "${major:-0}" -lt 2 ] || { [ "${major:-0}" -eq 2 ] && [ "${minor:-0}" -lt 27 ]; }; then
  echo "fetch-linux-dts: WARNING: git $ver is < 2.27; sparse/partial clone may not work." >&2
fi

if [ -d "$dest/.git" ]; then
  echo "fetch-linux-dts: updating existing checkout at '$dest' (ref=$ref)"
  git -C "$dest" sparse-checkout set --cone "${paths[@]}"
  git -C "$dest" fetch --filter=blob:none --depth 1 origin "$ref"
  git -C "$dest" checkout -B "$ref" FETCH_HEAD
else
  echo "fetch-linux-dts: cloning $url (blobless + sparse) into '$dest'"
  mkdir -p "$(dirname "$dest")"
  git clone --filter=blob:none --no-checkout --depth 1 --branch "$ref" "$url" "$dest"
  git -C "$dest" sparse-checkout init --cone
  git -C "$dest" sparse-checkout set "${paths[@]}"
  git -C "$dest" checkout "$ref"
fi

sha="$(git -C "$dest" rev-parse HEAD)"
{
  echo "url=$url"
  echo "ref=$ref"
  echo "sha=$sha"
  echo "fetched=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "paths=${paths[*]}"
} > "$dest/.cva6-dts-manifest"

dts_count="$(find "$dest/arch/riscv/boot/dts" \( -name '*.dts' -o -name '*.dtsi' \) 2>/dev/null | wc -l | tr -d ' ')"
echo "fetch-linux-dts: done."
echo "  dest : $dest"
echo "  sha  : $sha"
echo "  dts  : ${dts_count} RISC-V .dts/.dtsi files"
echo "  next : see AGENTS-dts-validation.md for the DT <-> spec <-> RTL cross-reference."
