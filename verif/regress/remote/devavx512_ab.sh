#!/bin/bash
# devavx512: rebuild devclean's EXACT .cpp sources with -march=native
# -DVL_SIMD_PREFER_512 -> activates the 16-word AVX-512 SIMD tier
# (VL_SIMD_WORDS 8->16) + VPOPCNTDQ. Control = devclean-ab binary
# (x86-64-v3 / AVX2 / WORDS=8). Only delta = march + SIMD tier width.
set -u
exec >>/tmp/devavx512-build.log 2>&1
SRC=/opt/testharness/runs/devclean-ab/model
RSRC=/opt/testharness/runs/hyp8-rfix131a-phantomprobe-aggregate-t2/output/source
DST=/opt/testharness/runs/devavx512-ab/model
VROOT=/opt/testharness/toolchains/verilator-v5.008-g6lc-dev/runtime
FW=/opt/testharness/runs/hyp8-firmware-r116/output/build-linux-mc/platform/generic/firmware/fw_payload.elf
mkdir -p /opt/testharness/runs/devavx512-ab
if [ ! -f "$DST/Vg6lc_testharness.mk" ]; then
  mkdir -p "$DST"
  rsync -a --exclude='*.o' --exclude='*.a' --exclude='*.gcno' --exclude='*.gcda' \
        --exclude='Variane_testharness*' "$SRC/" "$DST/" || { echo RSYNC_FAIL; exit 1; }
fi
cd "$DST" || { echo CD_FAIL; exit 1; }
ln -sfn "$RSRC/corev_apu" corev_apu
ln -sfn "$RSRC/verif" verif
rm -f *.o *.a *.gcno *.gcda Variane_testharness
export CCACHE_DIR=/opt/testharness/runs/devavx512-ab/ccache
mkdir -p "$CCACHE_DIR"
echo "AVX512_BUILD_START $(date -u +%FT%TZ)"
grep -q VL_SIMD_PREFER_512 "$VROOT/include/verilated_types.h" || { echo VROOT_NO_SIMD_TIER; exit 1; }
nice -n 10 make -f Vg6lc_testharness.mk VERILATOR_ROOT=$VROOT -j8 -B \
  CXX=g++ CC=gcc LINK=g++ \
  OPT_FAST="-O2 -march=native -DVL_SIMD_PREFER_512" OPT_SLOW="-O1 -march=native -DVL_SIMD_PREFER_512" OPT_GLOBAL="-O2 -march=native" \
  || { echo AVX512_BUILD_FAIL; tail -30 /tmp/devavx512-build.log; exit 1; }
[ -x Variane_testharness ] || { echo AVX512_NO_BINARY; exit 1; }
echo "AVX512_BUILD_OK $(date -u +%FT%TZ)"
echo "=== confirm zmm/avx512 codegen present ==="
objdump -d Variane_testharness 2>/dev/null | grep -cE "zmm[0-9]|vpopcnt" | head -1
env G6LC_METRICS_SIDECAR=/tmp/m-avx150.json perf stat -e instructions:u,cycles:u -x, -- \
  "$DST/Variane_testharness" +debug_disable +quiet_axi +max-cycles=150000 +time_out=150000 "$FW" \
  > /tmp/fw-avx150-out.log 2> /tmp/fw-avx150-perf.log
echo "PROBE_avx150: $(cat /tmp/m-avx150.json 2>/dev/null)"
grep -E "instructions:u|cycles:u" /tmp/fw-avx150-perf.log | tail -2
echo AVX512_DONE $(date -u +%FT%TZ)
