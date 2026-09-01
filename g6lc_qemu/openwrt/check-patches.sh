#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Dry-run seed patches against official OpenWrt v24.10.2 blobs (two files).
# Does not use etcimon forks.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIN="${OPENWRT_REF:-v24.10.2}"
URL="https://raw.githubusercontent.com/openwrt/openwrt/${PIN}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/include" "$TMP/target/linux/sifiveu"
echo "# stub" > "$TMP/Makefile"
curl -fsSL "$URL/include/kernel-defaults.mk" \
  -o "$TMP/include/kernel-defaults.mk"
curl -fsSL "$URL/target/linux/sifiveu/config-6.6" \
  -o "$TMP/target/linux/sifiveu/config-6.6"
export OPENWRT_SRC="$TMP"
bash "$HERE/apply-patches.sh"
grep -q G6LC_OLDDEFCONFIG "$TMP/include/kernel-defaults.mk"
grep -q "BEGIN G6LC-VIRT-OVERLAY" "$TMP/target/linux/sifiveu/config-6.6"
grep -q "CONFIG_SOC_VIRT=y" "$TMP/target/linux/sifiveu/config-6.6"
grep -q "CONFIG_RISCV_ISA_ZBA=y" "$TMP/target/linux/sifiveu/config-6.6"
echo CHECK_PATCHES_OK pin="$PIN"
