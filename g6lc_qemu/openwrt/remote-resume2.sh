#!/usr/bin/env bash
set -euo pipefail
SRC=/opt/testharness/cache/openwrt
K=/opt/testharness/cache/openwrt/build_dir/target-riscv64_riscv64_musl/linux-sifiveu_generic/linux-6.6.93
echo '===== config-6.6 CMDLINE ====='
grep -n "CMDLINE" "$SRC/target/linux/sifiveu/config-6.6" | tail -20
echo '===== linux .config CMDLINE ====='
grep -n "CMDLINE" "$K/.config" 2>/dev/null | head -20 || echo "no .config"
# Drop generated kernel configs so OpenWrt rebuilds from config-6.6.
rm -f "$K/.config" "$K/.config.set" "$K/.config.prev" "$K/.config.old" \
      "$K/.configured" "$K/.modules" "$K/.vermagic" \
      "$SRC/staging_dir/target-riscv64_riscv64_musl/stamp/.target_compile"
mkdir -p /opt/testharness/runs
if [ -f /opt/testharness/runs/openwrt-e3.pid ]; then
  old=$(cat /opt/testharness/runs/openwrt-e3.pid)
  if kill -0 "$old" 2>/dev/null; then
    echo STILL_RUNNING pid=$old
    exit 1
  fi
fi
cd "$SRC"
# Isolate linux compile first (verbose) then world.
nohup bash -lc '
set -euo pipefail
cd /opt/testharness/cache/openwrt
echo "[openwrt-e3] target/linux/compile V=s after wiping kernel .config"
make target/linux/compile -j"$(nproc)" V=s
echo "[openwrt-e3] linux compile ok; continuing world"
make -j"$(nproc)"
echo OPENWRT_E3_BUILD_READY
ls -l --time-style=long-iso bin/targets/sifiveu/generic/* 2>/dev/null || true
' >> /opt/testharness/runs/openwrt-e3.log 2>&1 &
echo $! > /opt/testharness/runs/openwrt-e3.pid
echo RESUMED2_PID=$!
sleep 8
tail -n 25 /opt/testharness/runs/openwrt-e3.log
