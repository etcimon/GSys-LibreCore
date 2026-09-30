#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Shallow-clone the etcimon *development* forks into linux-dist/openwrt-*.
# These are NOT used by g6lc_qemu/openwrt/build.sh. Compile uses official
# github.com/openwrt/* + g6lc_qemu/openwrt/patches.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$HERE"

clone_one() {
  local dir="$1" url="$2" branch="$3"
  local path="g6lc_qemu/linux-dist/$dir"
  if [ -d "$dir/.git" ] || [ -f "$dir/.git" ]; then
    echo "present $dir"
    return 0
  fi
  if git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if git -C "$REPO" config -f .gitmodules --get "submodule.$path.path" >/dev/null 2>&1; then
      # Already declared. These forks are `update = none` in .gitmodules (a
      # recursive checkout skips ~1.9 GB it never compiles), so the explicit
      # init here must say --checkout to override that.
      echo "submodule update --init --checkout --depth 1 -> $path"
      git -C "$REPO" submodule update --init --checkout --depth 1 -- "$path"
      return 0
    fi
    echo "submodule add --depth 1 -b $branch $url -> $path"
    git -C "$REPO" submodule add --depth 1 --branch "$branch" --force \
      "$url" "$path" || git clone --depth 1 --branch "$branch" "$url" "$dir"
  else
    echo "clone --depth 1 -b $branch $url -> $dir"
    git clone --depth 1 --branch "$branch" "$url" "$dir"
  fi
}

clone_one openwrt              https://github.com/etcimon/openwrt.git              openwrt-24.10
clone_one openwrt-packages     https://github.com/etcimon/openwrt-packages.git     openwrt-24.10
clone_one openwrt-luci         https://github.com/etcimon/openwrt-luci.git         openwrt-24.10
clone_one openwrt-routing      https://github.com/etcimon/openwrt-routing.git      openwrt-24.10
clone_one openwrt-telephony    https://github.com/etcimon/openwrt-telephony.git    openwrt-24.10
# EDK2 pin is a tag; clone master then fetch the pin if the fork exists.
clone_one edk2                 https://github.com/etcimon/edk2.git                  master
echo "dev forks ready under $HERE"
echo "after customizing OpenWrt: bash ../openwrt/extract-patches.sh"
echo "after customizing EDK2:    bash ../edk2/extract-patches.sh"
