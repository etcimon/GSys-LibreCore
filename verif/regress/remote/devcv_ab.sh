#!/bin/bash
# devcv-ab: devcase generated sources rebuilt with cv-sleep verilated_threads.h
# Isolates the scheduler-spin -> condition-variable change vs devcase .nopgo.
set -u
T=/opt/testharness/toolchains/verilator-v5.008-g6lc-dev
SRC=/opt/testharness/runs/hyp8-rfix131a-phantomprobe-aggregate-t2/output/source
SPIKE=/opt/testharness/toolchains/spike
D=/opt/testharness/runs/devcv-ab/model
FW=/opt/testharness/runs/hyp8-firmware-r116/output/build-linux-mc/platform/generic/firmware/fw_payload.elf
OLD=/opt/testharness/runs/devcase-ab/model

mkdir -p "$D"
# Copy generated sources + makefiles, drop objects/archive/binary -> full rebuild
cd "$OLD" || exit 1
for f in *.cpp *.h *.mk *.d; do [ -e "$f" ] && cp -a "$f" "$D/"; done
cd "$D" || exit 1
rm -f *.o *.a Variane_testharness Variane_testharness.nopgo
# DPI/TB relative source paths need these symlinks (same trick as devnodebug)
ln -sfn "$SRC/corev_apu" corev_apu
ln -sfn "$SRC/verif" verif

echo "DEVCV_BUILD_START $(date -u +%FT%TZ) files=$(ls *.cpp | wc -l)"
make -f Vg6lc_testharness.mk -j10 CXX=g++ CC=gcc LINK=g++ \
  OPT_FAST=-O2 OPT_SLOW=-O1 OPT_GLOBAL=-O2 > /tmp/devcv-make.log 2>&1 \
&& [ -x Variane_testharness ] && {
   env G6LC_METRICS_SIDECAR=/tmp/m-cv150.json perf stat -e instructions:u,cycles:u -x, -- \
     "$D/Variane_testharness" +debug_disable +quiet_axi +max-cycles=150000 +time_out=150000 "$FW" \
     > /tmp/fw-cv150-out.log 2> /tmp/fw-cv150-perf.log
   echo "PROBE_cv150: $(cat /tmp/m-cv150.json 2>/dev/null)"
   grep -E "instructions:u|cycles:u" /tmp/fw-cv150-perf.log | tail -2
 } || { echo DEVCV_BUILD_FAIL; tail -15 /tmp/devcv-make.log; }
echo "DEVCV_DONE $(date -u +%FT%TZ)"
