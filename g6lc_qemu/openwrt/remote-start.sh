#!/usr/bin/env bash
set -euo pipefail
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  bison flex gettext libssl-dev libelf-dev python3-dev quilt time xsltproc swig \
  || true
ls -l /opt/testharness/cache/openwrt-overlay/
if [ ! -f /opt/testharness/cache/openwrt/Makefile ]; then
  git clone --depth 1 --branch v24.10.2 https://github.com/openwrt/openwrt.git /opt/testharness/cache/openwrt
fi
mkdir -p /opt/testharness/runs
# If a previous compile is running, leave it.
if pgrep -f "openwrt-overlay/build.sh" >/dev/null 2>&1; then
  echo ALREADY_RUNNING
  pgrep -af openwrt-overlay/build.sh || true
  tail -n 15 /opt/testharness/runs/openwrt-e3.log || true
  exit 0
fi
nohup env OPENWRT_SRC=/opt/testharness/cache/openwrt OPENWRT_JOBS="$(nproc)" \
  bash /opt/testharness/cache/openwrt-overlay/build.sh \
  > /opt/testharness/runs/openwrt-e3.log 2>&1 &
echo STARTED_PID=$!
sleep 2
head -n 30 /opt/testharness/runs/openwrt-e3.log || true
