#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Variane testharness builder for g6lc64_ai (I3 S4 / CLASS1 / timing).
# Used by testharness_proxy.py flavour ai | ai-dt | ai-d1 | ai-d2 | ai-d4 | ai-d8
# (and class-0 stripe ai-sc2/4/8). Not SMT2 B/legacy.
#
#   bash verif/regress/ai-matrix-build-harness.sh ai-dt
#   AI_MATRIX_VERLIB=/opt/testharness/work/work-ver-ai-dt bash ... ai-dt
#
# Flavours:
#   ai     work-ver-ai     class 0, MaxAROut=2 (live default)
#   ai-dt  work-ver-ai-dt  class 0 SRAM + Cas=14 + MaxAROut=8  (S4 vehicle)
#   ai-d1  work-ver-ai-d1  LiteDRAM N=1, MaxAROut=8 (needs generated core)
#   ai-d2  work-ver-ai-d2  LiteDRAM N=2 (G6LC_AI_DRAM_CHANS_2)
#   ai-d4  work-ver-ai-d4  LiteDRAM N=4 (G6LC_AI_DRAM_CHANS_4)
#   ai-d8  work-ver-ai-d8  LiteDRAM N=8 (G6LC_AI_DRAM_CHANS_8)
#   ai-sc2/4/8  class-0 SRAM stripe (G6LC_AI_DRAM_SIM_CHANS_{2,4,8})
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

FLAV="${1:-${AI_MATRIX_FLAVOUR:-ai-dt}}"
case "$FLAV" in
  ai)     DEF_VERLIB=work-ver-ai;     DEF_DEFINES="" ;;
  ai-dt)  DEF_VERLIB=work-ver-ai-dt;  DEF_DEFINES="G6LC_AI_DRAM_TIMING" ;;
  ai-d1)  DEF_VERLIB=work-ver-ai-d1;  DEF_DEFINES="G6LC_AI_DRAM_CLASS1" ;;
  ai-d2)  DEF_VERLIB=work-ver-ai-d2;  DEF_DEFINES="G6LC_AI_DRAM_CHANS_2" ;;
  ai-d4)  DEF_VERLIB=work-ver-ai-d4;  DEF_DEFINES="G6LC_AI_DRAM_CHANS_4" ;;
  ai-d8)  DEF_VERLIB=work-ver-ai-d8;  DEF_DEFINES="G6LC_AI_DRAM_CHANS_8" ;;
  ai-sc2) DEF_VERLIB=work-ver-ai-sc2; DEF_DEFINES="G6LC_AI_DRAM_SIM_CHANS_2" ;;
  ai-sc4) DEF_VERLIB=work-ver-ai-sc4; DEF_DEFINES="G6LC_AI_DRAM_SIM_CHANS_4" ;;
  ai-sc8) DEF_VERLIB=work-ver-ai-sc8; DEF_DEFINES="G6LC_AI_DRAM_SIM_CHANS_8" ;;
  *) echo "usage: $0 <ai|ai-dt|ai-d1|ai-d2|ai-d4|ai-d8|ai-sc2|ai-sc4|ai-sc8>" >&2; exit 2 ;;
esac

VERLIB="${AI_MATRIX_VERLIB:-$DEF_VERLIB}"
DEFINES="${AI_MATRIX_DEFINES:-$DEF_DEFINES}"
TARGET="${AI_MATRIX_TARGET:-g6lc64_ai}"
# C++ compile (make -j / cc1plus) OOMs at -j2 on the 30 Gi builder
# (one DepSet_*.cpp is huge; Makefile -O3/-Os overrides -CFLAGS -O1).
# Keep JOBS=1. Runtime threads are separate (VTHREADS below) and may
# equal nproc so one Variane_testharness saturates the host.
# Override compile cap: AI_MATRIX_ALLOW_HIGH_JOBS=1.
JOBS="${AI_MATRIX_BUILD_JOBS:-1}"
if [[ "$JOBS" == "\$(nproc)" ]] || [[ "$JOBS" == "$(nproc)" ]]; then
  JOBS=1
fi
if [[ "${AI_MATRIX_ALLOW_HIGH_JOBS:-0}" != "1" ]] && [[ "$JOBS" =~ ^[0-9]+$ ]] && [[ "$JOBS" -gt 1 ]]; then
  echo "[ai-matrix-build] capping C++ jobs $JOBS -> 1 (OOM at -j2 on 30Gi; set AI_MATRIX_ALLOW_HIGH_JOBS=1 to override)"
  JOBS=1
fi

if [[ "$VERLIB" = /* ]]; then
  VERLIB_DIR="$VERLIB"
else
  VERLIB_DIR="$ROOT/$VERLIB"
fi
STAMP="$VERLIB_DIR/.ai-matrix-flavour"

log() { echo "[ai-matrix-build] $*"; }

export SPIKE_INSTALL_DIR="${SPIKE_INSTALL_DIR:-$ROOT/build-platform/workspace/tooling/spike}"
export RISCV="${RISCV:-/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3}"
export LD_LIBRARY_PATH="${SPIKE_INSTALL_DIR}/lib:${LD_LIBRARY_PATH:-}"
export CVA6_REPO_DIR="${CVA6_REPO_DIR:-$ROOT}"
export CXX="${CXX:-g++}" CC="${CC:-gcc}"

VLT_HOME="${VLT_HOME:-/root/tools/verilator-v5.008}"
if [[ ! -e "$VLT_HOME/bin/verilator" && -d /root/tools/verilator-v5.008 ]]; then
  VLT_HOME=/root/tools/verilator-v5.008
fi
if [[ ! -e "$VLT_HOME/bin/verilator" && -d "${HOME}/tools/verilator-v5.008" ]]; then
  VLT_HOME="${HOME}/tools/verilator-v5.008"
fi

if [[ "${AI_MATRIX_BUILD_CLEAN:-0}" == "1" ]]; then
  log "clean: removing $VERLIB_DIR"
  rm -rf "$VERLIB_DIR"
elif [[ -f "$STAMP" ]]; then
  prev="$(cat "$STAMP")"
  if [[ "$prev" != "$FLAV" ]]; then
    log "REFUSING: $VERLIB_DIR was built as flavour '$prev', requested '$FLAV'"
    exit 3
  fi
  log "resume: $VERLIB_DIR already flavour '$FLAV' (incremental)"
fi

mkdir -p "$VERLIB_DIR"
echo "$FLAV" >"$STAMP"

export VERILATOR_ROOT="${VERILATOR_ROOT:-$VLT_HOME/share/verilator}"
if [[ -e "$VLT_HOME/bin/verilator_bin" ]]; then
  [[ -e "$VERILATOR_ROOT/verilator_bin" ]] || ln -sfn "$VLT_HOME/bin/verilator_bin" "$VERILATOR_ROOT/verilator_bin"
  VLT_WRAP=/tmp/ai-matrix-vlt-wrap
  mkdir -p "$VLT_WRAP"
  cat >"$VLT_WRAP/verilator" <<EOF
#!/usr/bin/env bash
args=()
for a in "\$@"; do
  [[ "\$a" == "-Wno-SIDEEFFECT" ]] && continue
  args+=("\$a")
done
export VERILATOR_ROOT=$VERILATOR_ROOT
exec $VLT_HOME/bin/verilator "\${args[@]}"
EOF
  chmod +x "$VLT_WRAP/verilator"
  export PATH="$VLT_WRAP:$VLT_HOME/bin:/usr/bin:${RISCV}/bin:${SPIKE_INSTALL_DIR}/bin:${PATH}"
fi

# Force -O0 as the last -O: verilated.mk appends -O3/-Os after -CFLAGS.
CXX_WRAP=/tmp/ai-matrix-cxx-wrap
mkdir -p "$CXX_WRAP"
REAL_CXX="$(command -v g++ || echo /usr/bin/g++)"
cat >"$CXX_WRAP/g++" <<EOF
#!/usr/bin/env bash
out=()
for a in "\$@"; do
  case "\$a" in
    -O[0-9]|-Os|-Ofast|-Og|-Oz) continue ;;
  esac
  out+=("\$a")
done
exec $REAL_CXX -O0 "\${out[@]}"
EOF
chmod +x "$CXX_WRAP/g++"
export CXX="$CXX_WRAP/g++"
export PATH="$CXX_WRAP:$PATH"

if [[ -d "${HOME}/tools/oss-cad-suite/bin" ]]; then
  export PATH="${HOME}/tools/oss-cad-suite/bin:${PATH}"
fi
if [[ -f "${HOME}/tools/oss-cad-suite/environment" ]]; then
  # shellcheck disable=SC1091
  source "${HOME}/tools/oss-cad-suite/environment"
fi

# Runtime model threads: saturate the builder. Compile stays JOBS=1
# (OOM is parallel cc1plus, not --threads). Pin 1 with
# AI_MATRIX_VERILATOR_THREADS=1 if a serial cc1plus still OOMs.
VTHREADS="${AI_MATRIX_VERILATOR_THREADS:-}"
if [[ -z "$VTHREADS" || "$VTHREADS" == "\$(nproc)" || "$VTHREADS" == "nproc" ]]; then
  VTHREADS="$( (command -v nproc >/dev/null && nproc) || echo 12)"
fi

export VPATH="$CVA6_REPO_DIR"
BUILD_LOG="${AI_MATRIX_BUILD_LOG:-$VERLIB_DIR/build.log}"
rm -f "$BUILD_LOG"
log "target=$TARGET ver-library=$VERLIB_DIR flavour=$FLAV defines=${DEFINES:-none} jobs=$JOBS vthreads=$VTHREADS cxx=$CXX (O0 wrap)"
log "verilator: $(command -v verilator) ($(verilator --version 2>/dev/null | head -1))"
log "building; full log -> $BUILD_LOG"

MAKE_DEFINES=()
if [[ -n "$DEFINES" ]]; then
  MAKE_DEFINES+=( "defines=${DEFINES}" )
fi

# CLASS1 C++ must not poke gen_sim_axi.i_sram (not elaborated). Makefile also
# adds -DG6LC_HAVE_LITEDRAM; pass it here so TB_CPP sees the native preload.
VLT_CFLAGS="-DG6LC_TB_NO_HIER"
case "$FLAV" in
  ai-d1|ai-d2|ai-d4|ai-d8) VLT_CFLAGS="${VLT_CFLAGS} -DG6LC_HAVE_LITEDRAM" ;;
  ai-sc2) VLT_CFLAGS="${VLT_CFLAGS} -DG6LC_AI_DRAM_SIM_CHANS_2" ;;
  ai-sc4) VLT_CFLAGS="${VLT_CFLAGS} -DG6LC_AI_DRAM_SIM_CHANS_4" ;;
  ai-sc8) VLT_CFLAGS="${VLT_CFLAGS} -DG6LC_AI_DRAM_SIM_CHANS_8" ;;
esac

set +e
if [[ "${AI_MATRIX_SKIP_VERILATE:-0}" == "1" && -f "$VERLIB_DIR/Variane_testharness.mk" ]]; then
  log "SKIP verilate (AI_MATRIX_SKIP_VERILATE=1); C++/link only"
  # Leftover always_comb $display compiled to VL_WRITEF and SIGSEGV'd -O0 at t~2662.
  python3 "$ROOT/verif/regress/ai-strip-leftover-display.py" "$VERLIB_DIR"
  # TB_CPP often sits outside Verilator's depfile; force a rebuild of the harness C++.
  rm -f "$VERLIB_DIR/ariane_tb.o"
  make -C "$VERLIB_DIR" -j"$JOBS" -f Variane_testharness.mk \
    CXX="$CXX" CC="${CC:-gcc}" LINK="$CXX" \
    >"$BUILD_LOG" 2>&1
  rc=$?
else
make verilate \
  verilator="verilator -Wno-MODDUP -CFLAGS ${VLT_CFLAGS}" \
  target="$TARGET" \
  ver-library="$VERLIB_DIR" \
  TB_CPP=corev_apu/tb/ariane_tb.cpp \
  "${MAKE_DEFINES[@]}" \
  verilator_threads="$VTHREADS" \
  VERILATOR_INSTALL_DIR="${VERILATOR_INSTALL_DIR:-$VLT_HOME}" \
  XLEN=64 \
  CVA6_REPO_DIR="$CVA6_REPO_DIR" \
  SPIKE_INSTALL_DIR="$SPIKE_INSTALL_DIR" \
  RISCV="$RISCV" \
  CXX="$CXX" CC="$CC" \
  NUM_JOBS="$JOBS" \
  >"$BUILD_LOG" 2>&1
  rc=$?
fi
set -e

if [[ $rc -ne 0 ]]; then
  log "BUILD FAIL rc=$rc flavour=$FLAV"
  tail -n 80 "$BUILD_LOG"
  exit $rc
fi
if [[ ! -x "$VERLIB_DIR/Variane_testharness" ]]; then
  log "BUILD FAIL: no $VERLIB_DIR/Variane_testharness"
  tail -n 40 "$BUILD_LOG"
  exit 1
fi
log "BUILD OK flavour=$FLAV harness=$VERLIB_DIR/Variane_testharness"
echo "vthreads=$VTHREADS" >>"$BUILD_LOG"
