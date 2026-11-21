#!/bin/bash
# devnoassert: phase2_retry minus --assert. Isolates the --assert
# match-detection tax (parallel_case/full_case multi-match vectors that
# run every execution regardless of assertOn) vs devnodebug (--assert,
# no -DVL_DEBUG). Both no-debug -> only delta is --assert.
# RISK: hyp8_tb.cpp accesses __PVT__ internals that may be optimized away
# without --assert -> compile may fail on missing members; if so, add
# /*verilator public*/ or --public-flat-rw keep-alives for those signals.
set -u
T=/opt/testharness/toolchains/verilator-v5.008-g6lc-dev
SRC=/opt/testharness/runs/hyp8-rfix131a-phantomprobe-aggregate-t2/output/source
SPIKE=/opt/testharness/toolchains/spike
RISCV=/opt/testharness/toolchains/xpack-riscv-none-elf-gcc-14.2.0-3
D=/opt/testharness/runs/devnoassert-ab/model
FW=/opt/testharness/runs/hyp8-firmware-r116/output/build-linux-mc/platform/generic/firmware/fw_payload.elf
mkdir -p "$D"
cd "$SRC" || exit 1
echo "NOASSERT_START $(date -u +%FT%TZ)"
ulimit -s unlimited 2>/dev/null
VERILATOR_ROOT=$T/share/verilator CVA6_REPO_DIR=$SRC LD_LIBRARY_PATH=$SPIKE/lib:${LD_LIBRARY_PATH:-} \
perl $T/bin/verilator --no-timing verilator_config.vlt \
  -DG6LC_HYP8_MC -f verif/regress/remote/hyp8/Flist.hyp8_mc_sim --threads 4 \
  --unroll-count 256 --unroll-stmts 131072 -Wall -Werror-PINMISSING -Werror-IMPLICIT \
  -Wno-fatal -Wno-PINCONNECTEMPTY -Wno-ASSIGNDLY -Wno-DECLFILENAME -Wno-UNUSED \
  -Wno-UNOPTFLAT -Wno-BLKANDNBLK -Wno-style --converge-limit 100000 \
  --x-assign 0 --x-initial 0 --x-initial-edge \
  -LDFLAGS "-L$RISCV/lib -L$SPIKE/lib -Wl,-rpath,$RISCV/lib -Wl,-rpath,$SPIKE/lib -lfesvr -lriscv -ldisasm -lyaml-cpp -lpthread" \
  -CFLAGS "-I$SPIKE -I$SPIKE/include -I$SRC/corev_apu/tb -I$SRC/corev_apu/tb/dpi -DG6LC_TB_BANKED -DG6LC_TB_OOO -march=x86-64-v3" \
  --cc --vpi --threads-dpi none --top-module g6lc_testharness --Mdir "$D" -O3 \
  --exe verif/regress/remote/hyp8/hyp8_tb.cpp corev_apu/tb/dpi/SimDTM.cc \
  corev_apu/tb/dpi/SimJTAG.cc corev_apu/tb/dpi/remote_bitbang.cc corev_apu/tb/dpi/msim_helper.cc \
  "$D/verilator-split-loops-hyp8.vlt" --stats +define+G6LC_SIM_NO_HIER_TRACE -o Variane_testharness \
  && cd "$D" && ln -sfn "$SRC/corev_apu" corev_apu && ln -sfn "$SRC/verif" verif \
  && make -f Vg6lc_testharness.mk -j10 CXX=g++ CC=gcc LINK=g++ \
     OPT_FAST=-O2 OPT_SLOW=-O1 OPT_GLOBAL=-O2 \
  && [ -x Variane_testharness ] && {
     env G6LC_METRICS_SIDECAR=/tmp/m-na150.json perf stat -e instructions:u,cycles:u -x, -- \
       "$D/Variane_testharness" +debug_disable +quiet_axi +max-cycles=150000 +time_out=150000 "$FW" \
       > /tmp/fw-na150-out.log 2> /tmp/fw-na150-perf.log
     echo "PROBE_na150: $(cat /tmp/m-na150.json 2>/dev/null)"
     grep -E "instructions:u|cycles:u" /tmp/fw-na150-perf.log | tail -2
   } || echo NOASSERT_FAIL
 echo "NOASSERT_DONE $(date -u +%FT%TZ)"
