#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Custom OpenWrt compile for E3 (UEFI Linux on QEMU virt).
# Compile pin: official github.com/openwrt/openwrt @ v24.10.2
# plus g6lc_qemu/openwrt/patches (never the etcimon linux-dist forks).
#
# Usage (remote testharness or any Linux host):
#   OPENWRT_SRC=/opt/testharness/cache/openwrt bash g6lc_qemu/openwrt/build.sh
# Products:
#   $OPENWRT_SRC/bin/targets/sifiveu/generic/openwrt-*-initramfs-kernel.bin
#   $OPENWRT_SRC/build_dir/target-riscv64_*/linux-sifiveu_generic/Image

set -euo pipefail
PIN_REF="${OPENWRT_REF:-v24.10.2}"
PIN_URL="${OPENWRT_URL:-https://github.com/openwrt/openwrt.git}"
SRC="${OPENWRT_SRC:-/opt/testharness/cache/openwrt}"
JOBS="${OPENWRT_JOBS:-$(nproc 2>/dev/null || echo 4)}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "[openwrt-e3] $*"; }

if [ ! -f "$SRC/Makefile" ]; then
  log "clone official $PIN_URL $PIN_REF -> $SRC"
  git clone --depth 1 --branch "$PIN_REF" "$PIN_URL" "$SRC"
fi
test -f "$SRC/Makefile"

export OPENWRT_SRC="$SRC"
bash "$HERE/apply-patches.sh"
cd "$SRC"
if [ -f feeds.conf ]; then
  log "updating pinned feeds"
  ./scripts/feeds update -a
  ./scripts/feeds install -a -p packages
  ./scripts/feeds install -a -p video
fi
make defconfig
log "building -j$JOBS (toolchain + kernel + initramfs)"
make -j"$JOBS" V=s
log "products:"
ls -l --time-style=long-iso bin/targets/sifiveu/generic/*kernel* \
  bin/targets/sifiveu/generic/*rootfs* \
  bin/targets/sifiveu/generic/*Image* 2>/dev/null || true
find build_dir -path '*linux-sifiveu_generic/Image' -type f | head
echo OPENWRT_E3_BUILD_READY
