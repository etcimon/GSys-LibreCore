#!/bin/bash
# devclean: rebuild devcase's EXACT .cpp sources uniformly (CCACHE_DISABLE)
# to test whether devcase.nopgo's instruction count was contaminated.
# devnodebug (clean rebuild, -DVL_DEBUG off) measured 4.11e12 insns vs
# devcase.nopgo 5.25e12 — but -DVL_DEBUG is provably ~0.2% on sampled TUs,
# so a ~22% gap implies devcase.nopgo was NOT a clean nopgo build.
# This rebuild uses devcase's own .cpp + .mk (-DVL_DEBUG already in
# CPPFLAGS) => the intended devcase config, clean objects.
set -u
exec >>/tmp/devclean-build.log 2>&1
TC=gcc-13            # match devcase compiler (Ubuntu 13.3.0)
SRC=/opt/testharness/runs/devcase-ab/model
RSRC=/opt/testharness/runs/hyp8-rfix131a-phantomprobe-aggregate-t2/output/source
DST=/opt/testharness/runs/devclean-ab/model
FW=/opt/testharness/runs/hyp8-firmware-r116/output/build-linux-mc/platform/generic/firmware/fw_payload.elf
mkdir -p /opt/testharness/runs/devclean-ab
if [ ! -f "$DST/Vg6lc_testharness.mk" ]; then
  cp -a "$SRC" "$DST" || { echo DEVCLEAN_CP_FAIL; exit 1; }
fi
cd "$DST" || { echo DEVCLEAN_CD_FAIL; exit 1; }
ln -sfn "$RSRC/corev_apu" corev_apu
ln -sfn "$RSRC/verif" verif
# strip ALL prior objects/profiles/binaries for a uniform clean build
rm -f *.o *.a *.gcno *.gcda Variane_testharness Variane_testharness.nopgo
echo "DEVCLEAN_BUILD_START $(date -u +%FT%TZ)"
nice -n 19 make -f Vg6lc_testharness.mk -j6 -B \
  CXX=g++ CC=gcc LINK=g++ \
  OPT_FAST=-O2 OPT_SLOW=-O1 OPT_GLOBAL=-O2 \
  || { echo DEVCLEAN_BUILD_FAIL; exit 1; }
[ -x Variane_testharness ] || { echo DEVCLEAN_NO_BINARY; exit 1; }
echo "DEVCLEAN_BUILD_OK $(date -u +%FT%TZ)"
env G6LC_METRICS_SIDECAR=/tmp/m-dc150.json perf stat -e instructions:u,cycles:u -x, -- \
  "$DST/Variane_testharness" +debug_disable +quiet_axi +max-cycles=150000 +time_out=150000 "$FW" \
  > /tmp/fw-dc150-out.log 2> /tmp/fw-dc150-perf.log
echo "PROBE_dc150: $(cat /tmp/m-dc150.json 2>/dev/null)"
grep -E "instructions:u|cycles:u" /tmp/fw-dc150-perf.log | tail -2
echo DEVCLEAN_DONE > /tmp/devclean.done
cat /tmp/devclean.done
# report comparison anchors
echo "ANCHORS: devcase.nopgo=5.252e12 devnodebug=4.115e12 thr1=2.305e12"
cat /tmp/m-dc150.json 2>/dev/null
 grep -E "instructions:u|cycles:u" /tmp/fw-dc150-perf.log 2>/dev/null | tail -2
 echo DEVCLEAN_DONE $(date -u +%FT%TZ)
