set -uo pipefail
echo "start"
. /opt/testharness/env.sh || echo "env.sh fail $?"
MDIR=/opt/testharness/work/work-ver-server-math-v-B
SRC=/opt/testharness/repo/corev_apu/tb/g6lc_tb.cpp
ls -l "$SRC" "$MDIR/Variane_testharness.mk"
grep -n hangpc1 "$SRC" | head
VLT="${VERILATOR_ROOT:-}"
echo "VERILATOR_ROOT=$VERILATOR_ROOT VLT_HOME=${VLT_HOME:-}"
if [[ -z "$VLT" && -n "${VLT_HOME:-}" ]]; then
  VLT="$VLT_HOME/share/verilator"
fi
echo "VLT=$VLT"
g++ -std=c++17 -O0 -c "$SRC" -o /tmp/g6lc_tb_hangpc1.o \
  -DG6LC_CVA6_GEN_ACC \
  -I"$MDIR" \
  -I"$VLT/include" \
  -I"$VLT/include/vltstd" \
  -I/opt/testharness/repo/corev_apu/tb \
  -I/opt/testharness/repo/corev_apu/tb/dpi \
  -I/opt/testharness/toolchains/spike/include \
  -DVL_DEBUG
echo g++_rc=$?
ls -l /tmp/g6lc_tb_hangpc1.o
pgrep -af "work-ver-server-math-v-B/Variane_testharness" | head
