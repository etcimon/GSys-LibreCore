#!/bin/bash
# devcv rebuild v2: CCACHE_DISABLE=1 forces every TU to recompile against
# the NEW cv header -- eliminates stale-ODR objects that segfaulted v1.
set -u
D=/opt/testharness/runs/devcv-ab/model
FW=/opt/testharness/runs/hyp8-firmware-r116/output/build-linux-mc/platform/generic/firmware/fw_payload.elf
cd "$D" || exit 1
rm -f *.o *.a Variane_testharness Variane_testharness.nopgo
echo "DEVCV2_BUILD_START $(date -u +%FT%TZ)"
CCACHE_DISABLE=1 make -f Vg6lc_testharness.mk -j10 CXX=g++ CC=gcc LINK=g++ \
  OPT_FAST=-O2 OPT_SLOW=-O1 OPT_GLOBAL=-O2 > /tmp/devcv-make2.log 2>&1 \
&& [ -x Variane_testharness ] && {
   echo "DEVCV2_BUILD_OK"
   env G6LC_METRICS_SIDECAR=/tmp/m-cv150.json perf stat -e instructions:u,cycles:u -x, -- \
     "$D/Variane_testharness" +debug_disable +quiet_axi +max-cycles=150000 +time_out=150000 "$FW" \
     > /tmp/fw-cv150-out.log 2> /tmp/fw-cv150-perf.log
   echo "PROBE_cv150: $(cat /tmp/m-cv150.json 2>/dev/null)"
   grep -E "instructions:u|cycles:u" /tmp/fw-cv150-perf.log | tail -2
 } || { echo DEVCV2_BUILD_FAIL; tail -15 /tmp/devcv-make2.log; }
echo "DEVCV2_DONE $(date -u +%FT%TZ)"
