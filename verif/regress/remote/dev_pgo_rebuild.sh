#!/bin/bash
# Dev-model PGO rebuild, manual 2-phase on the existing verilated dir.
# Phase1: instrumented build -> training runs -> phase2: -fprofile-use rebuild.
# Log: /tmp/devpgo-build.log ; done marker: /tmp/devpgo.done
set -u
D=/opt/testharness/runs/devcase-ab/model
SRC=/opt/testharness/runs/hyp8-rfix131a-phantomprobe-aggregate-t2/output/source
VROOT=/opt/testharness/toolchains/verilator-v5.008-g6lc-dev/share/verilator
PGO=$D/pgo
TRAIN=$D/pgo-train
LOG=/tmp/devpgo-build.log
JOBS=12
NM=/opt/testharness/toolchains/xpack-riscv-none-elf-gcc-14.2.0-3/bin/riscv-none-elf-nm
# Host compiler selection, mirrors hyp8-build-harness.sh: an install-gcc.sh
# prefix (e.g. /opt/testharness/toolchains/gcc-16.2.0-znver4) via
# DEV_PGO_TOOLCHAIN (SOFT_LADDER_BUILD_TOOLCHAIN fallback); explicit
# CC/CXX still wins. Bare gcc/g++ defaults count as unset.
TOOLCHAIN="${DEV_PGO_TOOLCHAIN:-${SOFT_LADDER_BUILD_TOOLCHAIN:-}}"
if [[ -n "$TOOLCHAIN" && -x "$TOOLCHAIN/bin/gcc" && -x "$TOOLCHAIN/bin/g++" ]]; then
  [[ -z "${CC:-}" || "${CC:-}" == "gcc" ]] && CC="$TOOLCHAIN/bin/gcc"
  [[ -z "${CXX:-}" || "${CXX:-}" == "g++" ]] && CXX="$TOOLCHAIN/bin/g++"
fi
CXX="${CXX:-g++}"; CC="${CC:-gcc}"
export VPATH="$SRC:$VROOT/include"
export VERILATOR_ROOT="$VROOT"
export CVA6_REPO_DIR="$SRC"
export LD_LIBRARY_PATH="/opt/testharness/toolchains/spike/lib:${LD_LIBRARY_PATH:-}"
mkdir -p "$PGO" "$TRAIN"
cd "$D" || exit 1
exec >>"$LOG" 2>&1
set -x

cp -a "$D/Variane_testharness" "$D/Variane_testharness.nopgo" 2>/dev/null || true

GEN="-fprofile-generate=$PGO -fprofile-update=atomic"
USE="-fprofile-use=$PGO -fprofile-correction -fprofile-partial-training -Wno-missing-profile -Wno-coverage-mismatch"

# ---------- phase 1: instrumented ----------
rm -f "$D"/*.o "$D"/*.a "$D/Variane_testharness"
make -f Vg6lc_testharness.mk -j"$JOBS" CXX="$CXX" CC="$CC" LINK="$CXX" \
  "OPT_FAST=-O2 $GEN" "OPT_SLOW=-O1 $GEN" "OPT_GLOBAL=-O2 $GEN" \
  "USER_LDFLAGS=-fprofile-generate=$PGO" || { echo "PHASE1_BUILD_FAIL"; exit 1; }
[ -x "$D/Variane_testharness" ] || { echo "PHASE1_NO_BINARY"; exit 1; }
cp -a "$D/Variane_testharness" "$TRAIN/Variane_testharness.instrumented"
echo "PHASE1_OK $(date -u +%FT%TZ)"

# ---------- training ----------
INPUTS=/opt/testharness/runs/hyp8-rfix131a-phantomprobe-aggregate-t2/output/inputs
FW=/opt/testharness/runs/hyp8-firmware-r116/output/build-linux-mc/platform/generic/firmware/fw_payload.elf
TRAIN_LIST=""
for e in hyp8_zkn_kat.elf hyp8_zicclsm.elf hyp8_wrs.elf hyp8_amo_store_order.elf hyp8_lrsc_store.elf hyp8_sv39_load.elf; do
  [ -f "$INPUTS/$e" ] && TRAIN_LIST="$TRAIN_LIST $INPUTS/$e"
done
[ -f "$FW" ] && TRAIN_LIST="$TRAIN_LIST $FW"
n=0
for elf in $TRAIN_LIST; do
  [ -f "$elf" ] || continue
  n=$((n+1))
  tohost=$("$NM" "$elf" 2>/dev/null | awk '$3=="tohost"{print "0x"$1; exit}')
  cap=400000
  [ "$elf" = "$FW" ] && cap=1500000
  echo "TRAIN $n $elf tohost=${tohost:-none} cap=$cap"
  ( cd "$TRAIN" && "$TRAIN/Variane_testharness.instrumented" +debug_disable +quiet_axi \
      +max-cycles=$cap +time_out=$cap ${tohost:+tohost_addr=$tohost} "$elf" \
      > "train$n.log" 2>&1 ) || true
done
nprof=$(find "$PGO" -name '*.gcda' 2>/dev/null | wc -l)
echo "PGO_PROFILES=$nprof"
[ "$nprof" -eq 0 ] && { echo "PGO_NO_PROFILES"; exit 1; }

# ---------- phase 2: profile-use rebuild ----------
rm -f "$D"/*.o "$D"/*.a "$D/Variane_testharness"
make -f Vg6lc_testharness.mk -j"$JOBS" CXX="$CXX" CC="$CC" LINK="$CXX" \
  "OPT_FAST=-O2 $USE" "OPT_SLOW=-O1 $USE" "OPT_GLOBAL=-O2 $USE" \
  "USER_LDFLAGS=-fprofile-use=$PGO" || { echo "PHASE2_BUILD_FAIL"; exit 1; }
[ -x "$D/Variane_testharness" ] || { echo "PHASE2_NO_BINARY"; exit 1; }
echo "PHASE2_OK $(date -u +%FT%TZ)"
echo "DEVPGO_DONE" > /tmp/devpgo.done
