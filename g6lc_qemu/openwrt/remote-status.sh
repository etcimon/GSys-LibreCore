#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# Progress snapshot for the E3 OpenWrt remote compile.
set -euo pipefail
LOG=/opt/testharness/runs/openwrt-e3.log
SRC=/opt/testharness/cache/openwrt
K="$SRC/build_dir/target-riscv64_riscv64_musl/linux-sifiveu_generic/linux-6.6.93"
BIN="$SRC/bin/targets/sifiveu/generic"
pid=$(cat /opt/testharness/runs/openwrt-e3.pid 2>/dev/null || echo none)
if [ "$pid" != none ] && kill -0 "$pid" 2>/dev/null; then
  echo ALIVE pid=$pid
  ps -p "$pid" -o pid,etime,pcpu,pmem,cmd --no-headers 2>/dev/null || true
else
  echo DEAD pid=$pid
fi
echo "===== children (make/cc) ====="
if [ "$pid" != none ]; then
  ps --ppid "$pid" -o pid,etime,comm --no-headers 2>/dev/null | head -8 || true
fi
echo "openwrt-gcc=$(pgrep -c -f '[r]iscv64-openwrt-linux-musl-gcc' 2>/dev/null || echo 0)  make=$(pgrep -c -f '[m]ake .*/cache/openwrt' 2>/dev/null || echo 0)"
if [ -f "$LOG" ]; then
  echo "===== log ====="
  wc -l "$LOG"
  echo "mtime=$(date -u -r "$LOG" +%Y-%m-%dT%H:%M:%SZ) size=$(stat -c%s "$LOG")"
else
  echo "===== log missing ====="
fi
echo '===== phase (this resume) ====='
python3 - "$LOG" << "PY"
from pathlib import Path
import sys, re
p = Path(sys.argv[1])
t = p.read_text(errors="replace")
idx = t.rfind("olddef resume")
chunk = t[idx:] if idx >= 0 else t[-12000:]
pat = re.compile(
    r"OPENWRT_E3_BUILD_READY|ERROR: target/linux|olddef resume|olddefconfig hook|"
    r"linux ok; world|Collecting package|package/install|target/linux/compile|"
    r"^time: "
)
hits = [ln for ln in chunk.splitlines() if pat.search(ln)]
print("\n".join(hits[-20:]) if hits else "(none this resume)")
PY
# Restrict kconfig/error hits to the latest resume so prior NEW prompts stay noise.
echo '===== kconfig / errors (this resume) ====='
python3 - "$LOG" << "PY"
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text(errors="replace")
idx = t.rfind("olddef resume")
chunk = t[idx:] if idx >= 0 else t[-8000:]
keys = ("OPENWRT_E3_BUILD_READY", "ERROR: target", "(NEW)", "syncconfig",
        "choice[", "Collected errors", "olddefconfig", "linux ok")
hits = [ln for ln in chunk.splitlines() if any(k in ln for k in keys)]
print("\n".join(hits[-25:]) if hits else "(none this resume)")
PY
echo '===== last CC ====='
grep -E "CC (init/|kernel/|arch/riscv|drivers/|fs/)|LD +vmlinux|Kernel: arch/riscv/boot/Image" \
  "$LOG" 2>/dev/null | tail -8 || true
echo '===== products ====='
if [ -d "$BIN" ]; then
  ls -l --time-style=long-iso "$BIN" | tail -20
else
  echo "no bin/ yet"
fi
find "$SRC/build_dir" -path '*linux-sifiveu_generic/Image' -type f 2>/dev/null | head
find "$SRC/build_dir" -path '*linux-sifiveu_generic/linux-*/arch/riscv/boot/Image' -type f 2>/dev/null | head
echo '===== linux .config pins ====='
if [ -f "$K/.config" ]; then
  grep -E "^CONFIG_SOC_VIRT|^CONFIG_GOLDFISH|^# CONFIG_GOLDFISH|^CONFIG_CMDLINE|^# CONFIG_CMDLINE|^CONFIG_VIRTIO=|^CONFIG_VIRTIO_MMIO|^CONFIG_DRM=|^CONFIG_DRM_VIRTIO_GPU|^CONFIG_FB=|^CONFIG_EFI_STUB|^CONFIG_POWER_RESET" \
    "$K/.config" | head -50
else
  echo "no linux .config"
fi
echo '===== openwrt graphics selections ====='
grep -E '^CONFIG_(DISPLAY_SUPPORT|PACKAGE_(libdrm|libmesa|libmesadri-virtio-gpu|g6lc-egl-probe|kmscube))=' \
  "$SRC/.config" 2>/dev/null || true
echo '===== tail ====='
tail -n 12 "$LOG" 2>/dev/null || true
