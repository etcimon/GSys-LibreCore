#!/bin/bash
# devsimd: rebuild devcase's EXACT .cpp sources against a PATCHED runtime
# include (/tmp/vroot-simd = share/verilator + half-width SIMD tier in
# verilated_types.h). Control = devclean-ab (original header, clean rebuild,
# 5.294e12 insns / 3.110e13 cycles on fw150). Only delta = the header.
# Header-only static-inline change -> no class layout change -> ccache safe,
# but we CCACHE_DISABLE anyway for a uniform clean build matching devclean.
set -u
exec >>/tmp/devsimd-build.log 2>&1
SRC=/opt/testharness/runs/devcase-ab/model
RSRC=/opt/testharness/runs/hyp8-rfix131a-phantomprobe-aggregate-t2/output/source
DST=/opt/testharness/runs/devsimd-ab/model
VROOT=/tmp/vroot-simd
FW=/opt/testharness/runs/hyp8-firmware-r116/output/build-linux-mc/platform/generic/firmware/fw_payload.elf
mkdir -p /opt/testharness/runs/devsimd-ab
# rsync sources only (skip 5.3GB of objects/binaries/profiles)
if [ ! -f "$DST/Vg6lc_testharness.mk" ]; then
  mkdir -p "$DST"
  rsync -a --exclude='*.o' --exclude='*.a' --exclude='*.gcno' --exclude='*.gcda' \
        --exclude='Variane_testharness*' "$SRC/" "$DST/" || { echo DEVSIMD_RSYNC_FAIL; exit 1; }
fi
cd "$DST" || { echo DEVSIMD_CD_FAIL; exit 1; }
ln -sfn "$RSRC/corev_apu" corev_apu
ln -sfn "$RSRC/verif" verif
rm -f *.o *.a *.gcno *.gcda Variane_testharness Variane_testharness.nopgo
# Dedicated cache dir: the shared ~/.ccache is 99.96% full (5.0/5.0 GiB), so
# writing 2535 fresh simd objects there would evict useful entries. A
# run-local cache still exercises ccache normally without thrashing it.
export CCACHE_DIR=/opt/testharness/runs/devsimd-ab/ccache
mkdir -p "$CCACHE_DIR"
echo "DEVSIMD_BUILD_START $(date -u +%FT%TZ) VERILATOR_ROOT=$VROOT CCACHE_DIR=$CCACHE_DIR"
# sanity: the patched header must be the one picked up
grep -q VL_SIMD_HALF_WORDS "$VROOT/include/verilated_types.h" || { echo VROOT_BAD; exit 1; }
nice -n 10 make -f Vg6lc_testharness.mk VERILATOR_ROOT=$VROOT -j8 -B \
  CXX=g++ CC=gcc LINK=g++ \
  OPT_FAST=-O2 OPT_SLOW=-O1 OPT_GLOBAL=-O2 \
  || { echo DEVSIMD_BUILD_FAIL; tail -30 /tmp/devsimd-build.log; exit 1; }
[ -x Variane_testharness ] || { echo DEVSIMD_NO_BINARY; exit 1; }
echo "DEVSIMD_BUILD_OK $(date -u +%FT%TZ)"
env G6LC_METRICS_SIDECAR=/tmp/m-simd150.json perf stat -e instructions:u,cycles:u -x, -- \
  "$DST/Variane_testharness" +debug_disable +quiet_axi +max-cycles=150000 +time_out=150000 "$FW" \
  > /tmp/fw-simd150-out.log 2> /tmp/fw-simd150-perf.log
echo "PROBE_simd150: $(cat /tmp/m-simd150.json 2>/dev/null)"
grep -E "instructions:u|cycles:u" /tmp/fw-simd150-perf.log | tail -2
echo "CONTROL devclean: insns=5293790536311 cycles=31103517181261"
echo DEVSIMD_DONE $(date -u +%FT%TZ)
