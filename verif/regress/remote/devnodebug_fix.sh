#!/bin/bash
# Fix devnodebug ODR contamination: 127 .o built with NEW cv header mixed
# with 2416 OLD-header .o. Restore OLD header, kill stragglers, rebuild
# only contaminated objects -> consistent all-old-header binary.
set -u
M=/opt/testharness/runs/devnodebug-ab/model
INC=/opt/testharness/toolchains/verilator-v5.008-g6lc-dev/share/verilator/include

# 1) kill make + any compiler whose cwd is the model dir (orphaned cc1plus too)
for p in /proc/[0-9]*/cwd; do
  [ "$(readlink "$p" 2>/dev/null)" = "$M" ] && kill "$(basename "$(dirname "$p")")" 2>/dev/null
done
sleep 3
# sweep again for anything that respawned or was mid-write
for p in /proc/[0-9]*/cwd; do
  [ "$(readlink "$p" 2>/dev/null)" = "$M" ] && kill -9 "$(basename "$(dirname "$p")")" 2>/dev/null
done

# 2) install OLD (pre-cv) header with an mtime older than all .o so make
#    treats surviving old-header objects as up-to-date
cp /tmp/vt_old.h "$INC/verilated_threads.h"
touch -d "2026-11-20 18:00:00" "$INC/verilated_threads.h"

# 3) delete objects compiled while the NEW header was live (after ~20:44)
#    plus a margin; these are the contaminated ones
find "$M" -maxdepth 1 -name '*.o' -newermt '2026-11-20 20:44:00' -delete
# also drop any partial .o left by killed compilers (zero/tiny size is suspect,
# but safest is to remove .o whose .cpp is newer than the .o won't matter --
# make rebuilds missing only). Remove obviously-truncated .o (<4KB) too:
find "$M" -maxdepth 1 -name '*.o' -size -4k -delete
# drop archives/binary that may be partial from the killed make
rm -f "$M"/*.a "$M"/Variane_testharness "$M"/Variane_testharness.nopgo

echo "REMAINING_OBJS $(ls "$M"/*.o 2>/dev/null | wc -l)"
# 4) rebuild: only missing .o + archive + link
cd "$M" || exit 1
make -f Vg6lc_testharness.mk -j10 CXX=g++ CC=gcc LINK=g++ \
  OPT_FAST=-O2 OPT_SLOW=-O1 OPT_GLOBAL=-O2 > /tmp/devnodebug-make2.log 2>&1 \
&& [ -x Variane_testharness ] && {
   echo "NODEBUG_BUILD_OK"
   env G6LC_METRICS_SIDECAR=/tmp/m-nd150.json perf stat -e instructions:u,cycles:u -x, -- \
     "$M/Variane_testharness" +debug_disable +quiet_axi +max-cycles=150000 +time_out=150000 \
     /opt/testharness/runs/hyp8-firmware-r116/output/build-linux-mc/platform/generic/firmware/fw_payload.elf \
     > /tmp/fw-nd150-out.log 2> /tmp/fw-nd150-perf.log
   echo "PROBE_nd150: $(cat /tmp/m-nd150.json 2>/dev/null)"
   grep -E "instructions:u|cycles:u" /tmp/fw-nd150-perf.log | tail -2
 } || { echo NODEBUG_BUILD_FAIL; tail -15 /tmp/devnodebug-make2.log; }
echo "NODEBUG_FIX_DONE $(date -u +%FT%TZ)"
