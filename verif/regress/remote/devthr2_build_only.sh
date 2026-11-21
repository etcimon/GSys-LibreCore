#!/bin/bash
# devthr2 build+probe ONLY: the .cpp/makefile were already emitted by
# devthr2_verilate_only.sh into devthr2-ab/model (--threads 2, standard
# VERILATOR_ROOT = original headers, so the ONLY delta vs devcase is the
# thread count). Waits for the devsimd build+probe to finish first so the two
# -j builds don't oversubscribe the box, then builds with ccache and probes.
set -u
T=/opt/testharness/toolchains/verilator-v5.008-g6lc-dev
D=/opt/testharness/runs/devthr2-ab/model
FW=/opt/testharness/runs/hyp8-firmware-r116/output/build-linux-mc/platform/generic/firmware/fw_payload.elf
export CCACHE_DIR=/opt/testharness/runs/devthr2-ab/ccache
mkdir -p "$CCACHE_DIR"
cd "$D" || exit 1

# Gate: wait for the SIMD probe to land (or its build proc to vanish) so we
# don't run two heavy C++ builds at once. Cap the wait at ~8h.
for i in $(seq 1 960); do
  [ -f /tmp/m-simd150.json ] && break
  pgrep -f "devsimd-ab/model.*Variane_testharness|make -f Vg6lc_testharness.mk" >/dev/null || \
    pgrep -f "devsimd" >/dev/null || break
  sleep 30
done
echo "THR2_BUILD_START $(date -u +%FT%TZ) CCACHE_DIR=$CCACHE_DIR"
nice -n 10 make -f Vg6lc_testharness.mk VERILATOR_ROOT=$T/share/verilator -j8 -B \
  CXX=g++ CC=gcc LINK=g++ \
  OPT_FAST=-O2 OPT_SLOW=-O1 OPT_GLOBAL=-O2 \
  || { echo THR2_BUILD_FAIL; exit 1; }
[ -x Variane_testharness ] || { echo THR2_NO_BINARY; exit 1; }
echo "THR2_BUILD_OK $(date -u +%FT%TZ)"
env G6LC_METRICS_SIDECAR=/tmp/m-t2_150.json perf stat -e instructions:u,cycles:u -x, -- \
  "$D/Variane_testharness" +debug_disable +quiet_axi +max-cycles=150000 +time_out=150000 "$FW" \
  > /tmp/fw-t2_150-out.log 2> /tmp/fw-t2_150-perf.log
echo "PROBE_t2_150: $(cat /tmp/m-t2_150.json 2>/dev/null)"
grep -E "instructions:u|cycles:u" /tmp/fw-t2_150-perf.log | tail -2
echo "CONTROL devclean: insns=5293790536311 cycles=31103517181261"
echo THR2_DONE $(date -u +%FT%TZ)
