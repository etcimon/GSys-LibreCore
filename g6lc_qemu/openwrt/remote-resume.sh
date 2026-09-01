#!/usr/bin/env bash
# Re-apply virt overlay (CMDLINE_BOOL) and resume OpenWrt world.
# Toolchain is already built; only target/linux should rebuild.
set -euo pipefail
OVERLAY=/opt/testharness/cache/openwrt-overlay
SRC=/opt/testharness/cache/openwrt
test -f "$SRC/Makefile"
test -f "$OVERLAY/build.sh"

# Overlay files were rsync'd; re-run the overlay half then make.
export OPENWRT_SRC="$SRC"
# Apply overlay only (source the kernel-patch logic by running python from build.sh).
bash -c '
set -euo pipefail
SRC=/opt/testharness/cache/openwrt
FRAG=/opt/testharness/cache/openwrt-overlay/kernel-virt.config
CFG="$SRC/target/linux/sifiveu/config-6.6"
for sym in SOC_VIRT VIRTIO SERIAL_8250 SERIAL_8250_CONSOLE EFI_STUB CMDLINE_BOOL CMDLINE_EXTEND CMDLINE_FORCE CMDLINE_FALLBACK; do
  sed -i "/# CONFIG_${sym} is not set/d" "$CFG"
done
python3 - "$CFG" "$FRAG" << "PY"
from pathlib import Path
import sys
cfg, frag = Path(sys.argv[1]), Path(sys.argv[2])
text = cfg.read_text()
begin, end = "# BEGIN G6LC-VIRT-OVERLAY\n", "# END G6LC-VIRT-OVERLAY\n"
block = begin + frag.read_text().rstrip() + "\n" + end
if begin in text and end in text:
    pre, rest = text.split(begin, 1)
    _, post = rest.split(end, 1)
    text = pre.rstrip() + "\n" + block + post
elif "CONFIG_SOC_VIRT=y" in text:
    text = text.split("CONFIG_SOC_VIRT=y", 1)[0].rstrip() + "\n" + block
else:
    text = text.rstrip() + "\n" + block
cfg.write_text(text)
print("overlay applied")
PY
grep -n "CMDLINE_BOOL\|CMDLINE_EXTEND\|SOC_VIRT\|BEGIN G6LC" "$CFG" | tail -20
'

# Force kernel reconfigure (old .configured would skip syncconfig).
rm -f "$SRC/build_dir/target-riscv64_riscv64_musl/linux-sifiveu_generic/linux-6.6.93/.configured"
rm -f "$SRC/build_dir/target-riscv64_riscv64_musl/linux-sifiveu_generic/linux-6.6.93/.modules"
rm -f "$SRC/staging_dir/target-riscv64_riscv64_musl/stamp/.target_compile"
rm -f "$SRC/tmp/.targetinfo" 2>/dev/null || true

mkdir -p /opt/testharness/runs
if [ -f /opt/testharness/runs/openwrt-e3.pid ]; then
  old=$(cat /opt/testharness/runs/openwrt-e3.pid)
  if kill -0 "$old" 2>/dev/null; then
    echo STILL_RUNNING pid=$old
    exit 1
  fi
fi
cd "$SRC"
nohup env OPENWRT_JOBS="$(nproc)" bash -lc '
set -euo pipefail
cd /opt/testharness/cache/openwrt
echo "[openwrt-e3] resume make -j$(nproc) after CMDLINE_BOOL fix"
make -j"$(nproc)"
echo OPENWRT_E3_BUILD_READY
ls -l --time-style=long-iso bin/targets/sifiveu/generic/* 2>/dev/null || true
' >> /opt/testharness/runs/openwrt-e3.log 2>&1 &
echo $! > /opt/testharness/runs/openwrt-e3.pid
echo RESUMED_PID=$!
sleep 2
tail -n 15 /opt/testharness/runs/openwrt-e3.log
