#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Stock-guest and CTS runs on the remote testharness.
#
# The bridge is verilated on ovh_calltorch with verilator-v5.008-g6lc
# (the optimized fork). The Ubuntu image and ctsdata disk stay in
# /opt/testharness/cache and are rsynced only when they differ.
#
#   run-guest-remote.sh
#   G6LC_CTS=1 G6LC_ONLY=cts \
#     G6LC_CTS_CASELIST=caselists/cts-a-image-clear-1d3d.txt \
#     run-guest-remote.sh
#
# G6LC_CTS_SHARDS=N runs the list as N concurrent guest+bridge pairs
# (deqp --deqp-fraction), clamped to the builder's free-CPU budget.
#
# Extra arguments are passed to testharness_proxy.py apu-leaf
# (for example --detach, --suite-timeout N).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
PROXY="$ROOT/verif/regress/remote/testharness_proxy.py"
GUEST_CACHE="${GUEST_CACHE:-$ROOT/.cache/apu-guest}"
CTS_IMG="${G6LC_CTSDATA:-${G6LC_CTS_CACHE:-$ROOT/.cache/cts}/ctsdata.img}"

REMOTE_GUEST=/opt/testharness/cache/apu-guest
# keyed by the local image name, so a differently named image (new
# caselists) never replaces one a live leaf is reading
REMOTE_CTS=/opt/testharness/cache/cts/$(basename "$CTS_IMG")
# The builder's packaged g6lc-qemu has no stream8 machine. The Oct 11
# stream8 binary boots with a silent UART. This is the local v10.0.0-dirty
# binary that boots the stock image, copied to the builder cache.
# Firmware blobs stay with the Oct 11 build (opensbi fw_dynamic).
QEMU=/opt/testharness/cache/qemu-stream8/qemu-system-riscv64
QLIB=/opt/testharness/runs/apu-qemu-stream8-20261011T054522/build/qemu/qemu-bundle/usr/local/share/qemu

args=(
  apu-leaf "$ROOT"
  --stages guest
  --sync-guest "$GUEST_CACHE"
  --env "G6LC_QEMU=$QEMU"
  --env "G6LC_QLIB=$QLIB"
  --env "G6LC_GUEST_CACHE=$REMOTE_GUEST"
  --env G6LC_VENUS_ONLY=1
)
if [ -n "${G6LC_CTS:-}" ]; then
  if [ ! -f "$CTS_IMG" ]; then
    echo "G6LC_CTS=1 but $CTS_IMG is missing" >&2
    exit 2
  fi
  args+=(--sync-cts "$CTS_IMG" --env "G6LC_CTSDATA=$REMOTE_CTS" --env G6LC_CTS=1)
fi
for key in G6LC_ONLY G6LC_SKIP_APT G6LC_VN_DEBUG G6LC_CTS_CASELIST \
           G6LC_CTS_CASE G6LC_CTS_TIMEOUT G6LC_CTS_LOG_FLUSH \
           G6LC_CTS_SHARDS G6LC_CTS_FRACTION G6LC_GUEST_MEM \
           G6LC_CTS_LOG_IMAGES G6LC_CTS_LOG_SHADERS; do
  if [ -n "${!key:-}" ]; then
    args+=(--env "$key=${!key}")
  fi
done

set +e
python3 "$PROXY" "${args[@]}" "$@"
rc=$?
set -e
# apu-leaf --detach returns 4: the remote job is running, collect later.
if [ "$rc" = 4 ]; then
  exit 0
fi
exit "$rc"
