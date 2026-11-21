#!/bin/bash
# devnoassert verilate-only: feasibility check for the --assert tax
# experiment. Generates the model .cpp/.h WITHOUT --assert (keeps
# -DVL_DEBUG absent like devnodebug) so we can grep whether hyp8_tb's
# __PVT__ internal accesses survive before committing to a full build.
set -u
T=/opt/testharness/toolchains/verilator-v5.008-g6lc-dev
SRC=/opt/testharness/runs/hyp8-rfix131a-phantomprobe-aggregate-t2/output/source
SPIKE=/opt/testharness/toolchains/spike
RISCV=/opt/testharness/toolchains/xpack-riscv-none-elf-gcc-14.2.0-3
D=/opt/testharness/runs/devnoassert-ab/model
mkdir -p "$D"
cd "$SRC" || exit 1
echo "NOASSERT_VERILATE_START $(date -u +%FT%TZ)"
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
  && echo "NOASSERT_VERILATE_OK files=$(ls "$D"/*.cpp 2>/dev/null | wc -l)" \
  || echo "NOASSERT_VERILATE_FAIL"
