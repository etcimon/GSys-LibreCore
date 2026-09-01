#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Close NEW kconfig prompts (olddefconfig hook + overlay), then resume compile.
# Toolchain is already built; only target/linux + remaining world should rebuild.
set -euo pipefail
SRC=/opt/testharness/cache/openwrt
OVERLAY=/opt/testharness/cache/openwrt-overlay
K="$SRC/build_dir/target-riscv64_riscv64_musl/linux-sifiveu_generic/linux-6.6.93"
TC="$SRC/staging_dir/toolchain-riscv64_riscv64_gcc-13.3.0_musl"
export PATH="$TC/bin:$SRC/staging_dir/host/bin:$PATH"
test -d "$K"
test -x "$TC/bin/riscv64-openwrt-linux-musl-gcc"
test -f "$OVERLAY/apply-patches.sh"

# CRLF from Windows rsync would break bash $'\r'.
sed -i 's/\r$//' "$OVERLAY"/*.sh "$OVERLAY"/*.config "$OVERLAY"/patches/*.patch \
  "$OVERLAY"/patches/series 2>/dev/null || true
find "$OVERLAY/patches" -type f -exec sed -i 's/\r$//' {} + 2>/dev/null || true

export OPENWRT_SRC="$SRC"
bash "$OVERLAY/apply-patches.sh"

# Force Kernel/Configure to re-run (hook runs olddefconfig there).
rm -f "$K/.configured" "$K/.config.prev" "$K/.modules" \
  "$SRC/build_dir/target-riscv64_riscv64_musl/linux-sifiveu_generic/.configured" \
  "$SRC/staging_dir/target-riscv64_riscv64_musl/stamp/.target_compile"

# Belt: if a .config is already present, close NEW symbols now so a
# subsequent OpenWrt reconfigure starts from a complete file.
if [ -f "$K/.config" ]; then
  cat "$OVERLAY/kernel-virt.config" >> "$K/.config"
  make -C "$K" ARCH=riscv CROSS_COMPILE=riscv64-openwrt-linux-musl- \
    HOSTCC=gcc olddefconfig
  echo '===== linux .config after explicit olddefconfig ====='
  grep -E "^CONFIG_CMDLINE|^# CONFIG_CMDLINE|^CONFIG_SOC_VIRT|^CONFIG_VIRTIO|^CONFIG_GOLDFISH|^# CONFIG_GOLDFISH|^CONFIG_POWER_RESET" \
    "$K/.config" | head -40
  cp -f "$K/.config" "$K/.config.set"
  cp -f "$K/.config" "$K/.config.prev"
fi

mkdir -p /opt/testharness/runs
if [ -f /opt/testharness/runs/openwrt-e3.pid ]; then
  old=$(cat /opt/testharness/runs/openwrt-e3.pid)
  if kill -0 "$old" 2>/dev/null; then
    echo STILL_RUNNING pid=$old
    exit 1
  fi
fi
cd "$SRC"
echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) olddef resume =====" \
  >> /opt/testharness/runs/openwrt-e3.log
nohup bash -lc '
set -euo pipefail
cd /opt/testharness/cache/openwrt
echo "[openwrt-e3] compile after olddefconfig hook"
make target/linux/compile -j"$(nproc)" V=s
echo "[openwrt-e3] linux ok; world"
make -j"$(nproc)"
echo OPENWRT_E3_BUILD_READY
ls -l --time-style=long-iso bin/targets/sifiveu/generic/* 2>/dev/null || true
' >> /opt/testharness/runs/openwrt-e3.log 2>&1 &
echo $! > /opt/testharness/runs/openwrt-e3.pid
echo OLDDEF_PID=$!
sleep 20
echo '===== early log after kick ====='
if grep -E "\(NEW\)|OPENWRT_E3_BUILD_READY|ERROR: target/linux|CC (init/main|scripts/kconfig)|olddefconfig" \
     /opt/testharness/runs/openwrt-e3.log | tail -20; then
  :
fi
tail -n 15 /opt/testharness/runs/openwrt-e3.log
