#!/usr/bin/env bash
set -euo pipefail
test -f /opt/testharness/cache/openwrt/Makefile
mkdir -p /opt/testharness/runs
if [ -f /opt/testharness/runs/openwrt-e3.pid ]; then
  old=$(cat /opt/testharness/runs/openwrt-e3.pid)
  if kill -0 "$old" 2>/dev/null; then
    echo ALREADY_PID=$old
    tail -n 20 /opt/testharness/runs/openwrt-e3.log || true
    exit 0
  fi
fi
nohup env OPENWRT_SRC=/opt/testharness/cache/openwrt OPENWRT_JOBS="$(nproc)" \
  bash /opt/testharness/cache/openwrt-overlay/build.sh \
  > /opt/testharness/runs/openwrt-e3.log 2>&1 &
echo $! > /opt/testharness/runs/openwrt-e3.pid
echo STARTED_PID=$!
sleep 3
head -n 40 /opt/testharness/runs/openwrt-e3.log || true
