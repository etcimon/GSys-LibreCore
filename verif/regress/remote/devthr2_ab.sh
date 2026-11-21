#!/bin/bash
# devthr2: re-verilate hyp8 with --threads 2 (was 4) keeping ALL other
# baseline flags identical (--assert, -DVL_DEBUG, split-loops vlt, etc).
# Motivation: devcase stats show MTask parallelism factor = 2 on 4 threads
# (59 mtasks, 149 edges, critical path = 62% of total graph cost). If the
# dep-graph only yields ~2x parallelism, threads=4 may oversubscribe: extra
# workers mostly spin on mtask_done masks. threads=2 could keep ~the same
# wall-clock with far less sync spin -> fewer instructions:u AND cycles:u.
# Metric: fw150 with perf instructions:u/cycles:u + wall-clock seconds.
set -u
T=/opt/testharness/toolchains/verilator-v5.008-g6lc-dev
SRC=/opt/testharness/runs/hyp8-rfix131a-phantomprobe-aggregate-t2/output/source
SPIKE=/opt/testharness/toolchains/spike
RISCV=/opt/testharness/toolchains/xpack-riscv-none-elf-gcc-14.2.0-3
D=/opt/testharness/runs/devthr2-ab/model
FW=/opt/testharness/runs/hyp8-firmware-r116/output/build-linux-mc/platform/generic/firmware/fw_payload.elf
mkdir -p "$D"
cp /opt/testharness/runs/devcase-ab/model/verilator-split-loops-hyp8.vlt "$D/" 2>/dev/null || \
cp /opt/testharness/runs/devnodebug-ab/model/verilator-split-loops-hyp8.vlt "$D/"
cd "$SRC" || exit 1
echo "THR2_START $(date -u +%FT%TZ)"
ulimit -s unlimited 2>/dev/null
VERILATOR_ROOT=$T/share/verilator CVA6_REPO_DIR=$SRC LD_LIBRARY_PATH=$SPIKE/lib:${LD_LIBRARY_PATH:-} \
perl $T/bin/verilator --no-timing verilator_config.vlt --assert \
  -DG6LC_HYP8_MC -f verif/regress/remote/hyp8/Flist.hyp8_mc_sim --threads 2 \
  --unroll-count 256 --unroll-stmts 131072 -Wall -Werror-PINMISSING -Werror-IMPLICIT \
  -Wno-fatal -Wno-PINCONNECTEMPTY -Wno-ASSIGNDLY -Wno-DECLFILENAME -Wno-UNUSED \
  -Wno-UNOPTFLAT -Wno-BLKANDNBLK -Wno-style --converge-limit 100000 \
  --x-assign 0 --x-initial 0 --x-initial-edge \
  -LDFLAGS "-L$RISCV/lib -L$SPIKE/lib -Wl,-rpath,$RISCV/lib -Wl,-rpath,$SPIKE/lib -lfesvr -lriscv -ldisasm -lyaml-cpp -lpthread" \
  -CFLAGS "-DVL_DEBUG -I$SPIKE -I$SPIKE/include -I$SRC/corev_apu/tb -I$SRC/corev_apu/tb/dpi -DG6LC_TB_BANKED -DG6LC_TB_OOO -march=x86-64-v3" \
  --cc --vpi --threads-dpi none --top-module g6lc_testharness --Mdir "$D" -O3 \
  --exe verif/regress/remote/hyp8/hyp8_tb.cpp corev_apu/tb/dpi/SimDTM.cc \
  corev_apu/tb/dpi/SimJTAG.cc corev_apu/tb/dpi/remote_bitbang.cc corev_apu/tb/dpi/msim_helper.cc \
  "$D/verilator-split-loops-hyp8.vlt" --stats +define+G6LC_SIM_NO_HIER_TRACE -o Variane_testharness \
  && cd "$D" && ln -sfn "$SRC/corev_apu" corev_apu && ln -sfn "$SRC/verif" verif \
  && grep -E "MTask graph, final, (mtask count|edge count|parallelism)" Vg6lc_testharness__stats.txt \
  && nice -n 19 make -f Vg6lc_testharness.mk -j6 -B CXX=g++ CC=gcc LINK=g++ \
     OPT_FAST=-O2 OPT_SLOW=-O1 OPT_GLOBAL=-O2 \
  && [ -x Variane_testharness ] && {
     T0=$(date +%s.%N)
     env G6LC_METRICS_SIDECAR=/tmp/m-t2_150.json perf stat -e instructions:u,cycles:u -x, -- \
       "$D/Variane_testharness" +debug_disable +quiet_axi +max-cycles=150000 +time_out=150000 "$FW" \
       > /tmp/fw-t2_150-out.log 2> /tmp/fw-t2_150-perf.log
     T1=$(date +%s.%N)
     echo "WALLCLOCK_t2_150: $(echo "$T1 - $T0" | bc)s"
     echo "PROBE_t2_150: $(cat /tmp/m-t2_150.json 2>/dev/null)"
     grep -E "instructions:u|cycles:u" /tmp/fw-t2_150-perf.log | tail -2
   } || echo THR2_FAIL
 echo "THR2_DONE $(date -u +%FT%TZ)"
