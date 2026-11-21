#!/bin/bash
# gcc16 model build: recompile the SAME devcase verilated sources with
# GCC 16.2 -> clean compiler-only A/B vs devcase .nopgo (gcc13).
# Flags come from the model .mk: -march=x86-64-v3 (CPPFLAGS), -O2/-O1/-O2,
# -DVL_DEBUG, --assert sources. Only CC/CXX/LINK change to gcc16.
# Runs nice'd at -j6 so it fills spare CPU without starving the
# priority devcv-v2 / probe jobs on the oversubscribed box.
set -u
exec >>/tmp/gcc16-build.log 2>&1
TC=/opt/testharness/toolchains/gcc-16.2.0-znver4
SRC=/opt/testharness/runs/devcase-ab/model
RSRC=/opt/testharness/runs/hyp8-rfix131a-phantomprobe-aggregate-t2/output/source
DST=/opt/testharness/runs/devgcc16-ab/model
mkdir -p /opt/testharness/runs/devgcc16-ab
if [ ! -f "$DST/Vg6lc_testharness.mk" ]; then
  cp -a "$SRC" "$DST" || { echo GCC16_CP_FAIL; exit 1; }
fi
cd "$DST" || { echo GCC16_CD_FAIL; exit 1; }
# DPI/TB sources are reached via relative paths -> need the source-tree
# symlinks the verilate scripts create (cp -a does not fabricate them).
ln -sfn "$RSRC/corev_apu" corev_apu
ln -sfn "$RSRC/verif" verif
rm -f *.o *.a Variane_testharness Variane_testharness.nopgo
echo "GCC16_BUILD_START $(date -u +%FT%TZ)"
nice -n 19 make -f Vg6lc_testharness.mk -j6 -B \
  CXX=$TC/bin/g++ CC=$TC/bin/gcc LINK=$TC/bin/g++ \
  OPT_FAST=-O2 OPT_SLOW=-O1 OPT_GLOBAL=-O2 \
  || { echo GCC16_BUILD_FAIL; exit 1; }
[ -x Variane_testharness ] || { echo GCC16_NO_BINARY; exit 1; }
echo "GCC16_BUILD_OK $(date -u +%FT%TZ)"
$TC/bin/g++ --version | head -1
ls -la Variane_testharness
echo GCC16_DONE > /tmp/gcc16.done
