#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# U2 virtio ESP, or U3b g6lc-soc DRAM PE / U3-FIT + QEMU -initrd overlay / U3-SPI:
#   SMP=2 EXPECT='procd: - init -' bash .../smoke-uboot.sh
#   MACHINE=g6lc-soc SMP=2 EXPECT='procd: - init -' TIMEOUT=120 bash .../smoke-uboot.sh
#   MACHINE=g6lc-soc SMP=2 EXPECT=CPUINFO-DONE TIMEOUT=90 bash .../smoke-uboot.sh
#   MACHINE=g6lc-soc SMP=2 EXPECT=SPI-PROBE-DONE TIMEOUT=45 bash .../smoke-uboot.sh
#   MACHINE=g6lc-soc SMP=2 EXPECT=SPI-READ-DONE TIMEOUT=120 bash .../smoke-uboot.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
G6Q="$ROOT/g6lc_qemu"
cd "$G6Q"
cargo run -q -p g6q-cli -- run \
  --backend qemu \
  --loader u-boot \
  --os openwrt \
  --machine "${MACHINE:-g6lc-virt}" \
  --smp "${SMP:-1}" \
  --timeout "${TIMEOUT:-120}" \
  --expect "${EXPECT:-Linux version 6.6}" \
  --target g6lc64_smt2 \
  --repo-root "$ROOT"
echo U2-OPENWRT-SMOKE-PASS
