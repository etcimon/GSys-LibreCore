#!/bin/bash
set -uo pipefail
export PATH="/root/tools/verilator-v5.008/bin:/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin:/root/tools/spike/bin:${PATH}"
export LD_LIBRARY_PATH="/root/tools/spike/lib:${LD_LIBRARY_PATH:-}"
export SPIKE_INSTALL_DIR=/root/tools/spike
export RISCV=/root/tools/spike
export CVA6_REPO_DIR=/mnt/e/cva6
cd /mnt/e/cva6/work-ver-smt2-slfix
rm -f Variane_testharness
echo "linking..."
make -f Variane_testharness.mk Variane_testharness 2>&1 | tail -30
file Variane_testharness
ls -la Variane_testharness
if ! file Variane_testharness | grep -q ELF; then
  echo "link failed"; exit 1
fi

H=/mnt/e/cva6/work-ver-smt2-slfix/Variane_testharness
PIN=/mnt/e/cva6/software/smt2-linux/soft-ladder/build/fw_payload_r3a_c15_plat_skip.pin-bc7ed11d.elf
OUT=/tmp/cva6-i4l-peelnt
mkdir -p "$OUT"
export CVA6_TRAP_DUMP=1
echo "=== natural next_tag soak ==="
set +e
"$H" +time_out=7000000 +max-cycles=7000000 +debug_disable +tohost_addr=0x80041730 \
  "$PIN" >"$OUT/veri_nat_nt.log" 2>&1
rc=$?
set -e
if grep -qE '\[1000\]=[0-9a-fA-F]*51b1babe' "$OUT/veri_nat_nt.log"; then
  echo "CLASSIFY=SUCCESS nat_nt rc=$rc"
else
  echo "CLASSIFY=FAIL nat_nt rc=$rc"
fi
grep -E '\[trapdump\]|\[hangpc\]|51b1|plat_hc|coldboot' "$OUT/veri_nat_nt.log" | tail -12 || true
echo DONE
