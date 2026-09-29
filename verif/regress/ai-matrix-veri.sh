#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Optional live Variane run of Xg6lcai directed ELFs on g6lc64_ai.
# Rebuilds work-ver-ai if missing or AI_MATRIX_VERI_REBUILD=1.
#
# Usage:
#   bash verif/regress/ai-matrix-veri.sh
#   AI_MATRIX_VERI_REBUILD=1 bash verif/regress/ai-matrix-veri.sh
#   AI_MATRIX_VERI_TESTS="ai_dot4_s8_smoke" bash verif/regress/ai-matrix-veri.sh
#   AI_ISLAND_DRAM_TIMING=1 AI_MATRIX_VERI_REBUILD=1 bash verif/regress/ai-matrix-veri.sh
#     → work-ver-ai-dt, +define+G6LC_AI_DRAM_TIMING (class-0 SRAM + Cas=14).
#     Not LiteDRAM; not 19/400 GB/s. Default library stays Cas=0 identity.
#   AI_ISLAND_DRAM_CLASS1=1 → work-ver-ai-d1, LiteDRAM N=1 (needs generated core).
#   AI_ISLAND_DRAM_CHANS_2=1 → work-ver-ai-d2, LiteDRAM N=2 (38 GB/s nameplate).
#   AI_ISLAND_DRAM_CHANS_4=1 → work-ver-ai-d4, LiteDRAM N=4 (76 GB/s nameplate).
#   AI_ISLAND_DRAM_CHANS_8=1 → work-ver-ai-d8, LiteDRAM N=8 (152 GB/s nameplate).
#   AI_ISLAND_DRAM_SIM_CHANS_2=1 → work-ver-ai-sc2, class-0 SRAM N=2 stripe.
#   AI_ISLAND_DRAM_SIM_CHANS_4=1 → work-ver-ai-sc4, class-0 SRAM N=4.
#   AI_ISLAND_DRAM_SIM_CHANS_8=1 → work-ver-ai-sc8, class-0 SRAM N=8.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# shellcheck source=common-riscv-tools.sh
if [[ -f "$(dirname "$0")/common-riscv-tools.sh" ]]; then
  # shellcheck disable=SC1091
  source "$(dirname "$0")/common-riscv-tools.sh"
fi

export CVA6_REPO_DIR="${CVA6_REPO_DIR:-$ROOT}"
export DV_TARGET="${DV_TARGET:-g6lc64_ai}"
export RISCV="${RISCV:-${HOME}/tools/riscv}"
export VERILATOR_INSTALL_DIR="${VERILATOR_INSTALL_DIR:-${HOME}/tools/oss-cad-suite}"
export CXX="${CXX:-g++}"
export CC="${CC:-gcc}"
[[ -d "${HOME}/tools/oss-cad-suite/bin" ]] && export PATH="${HOME}/tools/oss-cad-suite/bin:${PATH}"
[[ -d "${HOME}/tools/riscv/bin" ]] && export PATH="${HOME}/tools/riscv/bin:${PATH}"
[[ -d "${HOME}/tools/bin" ]] && export PATH="${HOME}/tools/bin:${PATH}"
if [[ -f "${HOME}/tools/oss-cad-suite/environment" ]]; then
  # shellcheck disable=SC1091
  source "${HOME}/tools/oss-cad-suite/environment"
fi
if [[ -z "${SPIKE_INSTALL_DIR:-}" ]]; then
  if [[ -d "$ROOT/build-platform/workspace/tooling/spike" ]]; then
    export SPIKE_INSTALL_DIR="$ROOT/build-platform/workspace/tooling/spike"
  elif [[ -d "${HOME}/tools/spike" ]]; then
    export SPIKE_INSTALL_DIR="${HOME}/tools/spike"
  fi
fi
if [[ -n "${SPIKE_INSTALL_DIR:-}" ]]; then
  export PATH="${SPIKE_INSTALL_DIR}/bin:${PATH}"
  export LD_LIBRARY_PATH="${SPIKE_INSTALL_DIR}/lib:${LD_LIBRARY_PATH:-}"
fi

REBUILD="${AI_MATRIX_VERI_REBUILD:-0}"
TIMING="${AI_ISLAND_DRAM_TIMING:-0}"
CLASS1="${AI_ISLAND_DRAM_CLASS1:-0}"
CHANS2="${AI_ISLAND_DRAM_CHANS_2:-0}"
CHANS4="${AI_ISLAND_DRAM_CHANS_4:-0}"
CHANS8="${AI_ISLAND_DRAM_CHANS_8:-0}"
SIMCH2="${AI_ISLAND_DRAM_SIM_CHANS_2:-0}"
SIMCH4="${AI_ISLAND_DRAM_SIM_CHANS_4:-0}"
SIMCH8="${AI_ISLAND_DRAM_SIM_CHANS_8:-0}"
if [[ "${AI_MATRIX_BENCH_SKU:-0}" == "1" ]]; then
  # Bench SKU model: island-only VaTurboEn + IslandFpEn + all-format grant
  # (ariane_testharness G6LC_AI_TB_BENCH_SKU). Used by AI_MATRIX_BENCH=1.
  VER_LIBRARY="${AI_MATRIX_VER_LIBRARY:-work-ver-ai-bench}"
  TIMING_DEFINES="defines=G6LC_AI_TB_BENCH_SKU"
elif [[ "$CHANS8" == "1" ]]; then
  VER_LIBRARY="${AI_MATRIX_VER_LIBRARY:-work-ver-ai-d8}"
  TIMING_DEFINES="defines=G6LC_AI_DRAM_CHANS_8"
elif [[ "$CHANS4" == "1" ]]; then
  VER_LIBRARY="${AI_MATRIX_VER_LIBRARY:-work-ver-ai-d4}"
  TIMING_DEFINES="defines=G6LC_AI_DRAM_CHANS_4"
elif [[ "$CHANS2" == "1" ]]; then
  VER_LIBRARY="${AI_MATRIX_VER_LIBRARY:-work-ver-ai-d2}"
  TIMING_DEFINES="defines=G6LC_AI_DRAM_CHANS_2"
elif [[ "$CLASS1" == "1" ]]; then
  VER_LIBRARY="${AI_MATRIX_VER_LIBRARY:-work-ver-ai-d1}"
  TIMING_DEFINES="defines=G6LC_AI_DRAM_CLASS1"
elif [[ "$SIMCH8" == "1" ]]; then
  VER_LIBRARY="${AI_MATRIX_VER_LIBRARY:-work-ver-ai-sc8}"
  TIMING_DEFINES="defines=G6LC_AI_DRAM_SIM_CHANS_8"
elif [[ "$SIMCH4" == "1" ]]; then
  VER_LIBRARY="${AI_MATRIX_VER_LIBRARY:-work-ver-ai-sc4}"
  TIMING_DEFINES="defines=G6LC_AI_DRAM_SIM_CHANS_4"
elif [[ "$SIMCH2" == "1" ]]; then
  VER_LIBRARY="${AI_MATRIX_VER_LIBRARY:-work-ver-ai-sc2}"
  TIMING_DEFINES="defines=G6LC_AI_DRAM_SIM_CHANS_2"
elif [[ "$TIMING" == "1" ]]; then
  VER_LIBRARY="${AI_MATRIX_VER_LIBRARY:-work-ver-ai-dt}"
  TIMING_DEFINES="defines=G6LC_AI_DRAM_TIMING"
else
  VER_LIBRARY="${AI_MATRIX_VER_LIBRARY:-work-ver-ai}"
  TIMING_DEFINES=""
fi
DEFAULT_TESTS="ai_csr_aistatus_xs ai_setcfg_readback ai_illegal_when_off ai_dot4_s8_smoke ai_mma_s8_golden ai_requant_rhe_golden ai_pmu_group4_smoke ai_queue_doorbell ai_aiperm_umode ai_island_mmio_smoke ai_cpl_fifo_multi_claim ai_enq_sideband_smoke ai_dual_enq_poll ai_irq_plic_smoke ai_desc_fetch_smoke ai_enq_fetch_smoke ai_ptr_done_smoke ai_gemm_s8_smoke ai_gemm_s8_lda_smoke ai_gemm_dim_err_smoke ai_gemm_s8_4x4_smoke ai_gemm_s8_8x8_smoke ai_gemm_s8_16x16_smoke ai_gemm_s8_32x32_smoke ai_gemm_s8_64x64_smoke ai_gemm_s8_128x128_smoke ai_gemm_s8_256x256_smoke ai_bw_pmu_smoke ai_cap_bringup_smoke ai_gemm_tile_2x2_smoke"
# shellcheck disable=SC2206
tests=( ${AI_MATRIX_VERI_TESTS:-$DEFAULT_TESTS} )
# 256x256 GEMM ~0.3M cy; MaxBurst=64 + I3 PMU; headroom for suite.
TIME_OUT="${AI_MATRIX_TIME_OUT:-8000000}"

# Prefer the monorepo-proven Verilator 5.008 (Debian 5.020 hit internal faults
# on this design). Override with VERILATOR_BIN / VERILATOR_ROOT if needed.
if [[ -z "${VERILATOR_ROOT:-}" && -d /root/tools/verilator-v5.008/share/verilator ]]; then
  export PATH="/root/tools/verilator-v5.008/bin:${PATH}"
  export VERILATOR_ROOT=/root/tools/verilator-v5.008/share/verilator
fi

log() { echo "[ai-matrix-veri] $*"; }
log "target=${DV_TARGET} rebuild=${REBUILD} ver-library=${VER_LIBRARY} dram-timing=${TIMING} class1=${CLASS1} chans2=${CHANS2} chans4=${CHANS4} chans8=${CHANS8} sim-chans-2=${SIMCH2}"
log "verilator: $(command -v verilator) ($(verilator --version 2>/dev/null | head -1))"

command -v verilator >/dev/null || { log "need verilator"; exit 1; }
command -v g++ >/dev/null || { log "need g++"; exit 1; }

# Prefer xpack / none-elf when available (same as mc-mini-veri)
if [[ -x "${HOME}/tools/riscv/bin/riscv-none-elf-gcc" ]]; then
  export PATH="${HOME}/tools/riscv/bin:${PATH}"
  export CROSS_COMPILE=riscv-none-elf-
fi
RISCV_CC="${RISCV_CC:-${CROSS_COMPILE:-riscv-none-elf-}gcc}"
if ! command -v "$RISCV_CC" >/dev/null 2>&1; then
  for p in riscv-none-elf-gcc riscv64-unknown-elf-gcc; do
    if command -v "$p" >/dev/null 2>&1; then RISCV_CC="$p"; break; fi
  done
fi
command -v "$RISCV_CC" >/dev/null || { log "need riscv gcc"; exit 1; }
CROSS_NM="${CROSS_COMPILE:-riscv-none-elf-}nm"
command -v "$CROSS_NM" >/dev/null 2>&1 || CROSS_NM="${RISCV_CC%gcc}nm"

if [[ "$REBUILD" == "1" || ! -x "$ROOT/$VER_LIBRARY/Variane_testharness" ]]; then
  log "verilate target=$DV_TARGET library=$VER_LIBRARY ..."
  rm -rf "$ROOT/$VER_LIBRARY"
  make -C "$ROOT" verilate \
    verilator="verilator --no-timing" \
    target="$DV_TARGET" ver-library="$VER_LIBRARY" \
    ${TIMING_DEFINES} \
    XLEN=64 \
    CVA6_REPO_DIR="$CVA6_REPO_DIR" \
    SPIKE_INSTALL_DIR="${SPIKE_INSTALL_DIR:-}" \
    RISCV="$RISCV" \
    VERILATOR_INSTALL_DIR="$VERILATOR_INSTALL_DIR" \
    CXX="$CXX" CC="$CC"
else
  log "reuse $VER_LIBRARY/Variane_testharness"
fi
test -x "$ROOT/$VER_LIBRARY/Variane_testharness" || {
  log "missing harness (set AI_MATRIX_VERI_REBUILD=1)"; exit 1
}

COMMON="$ROOT/verif/tests/custom/common"
LD="$COMMON/link_verilator.ld"
OUT="$ROOT/$VER_LIBRARY/ai_elfs"
mkdir -p "$OUT"
HARNESS="$ROOT/$VER_LIBRARY/Variane_testharness"
PASS=0
FAIL=0

# Bench mode (AI_MATRIX_BENCH=1): the [op x format x shape x path x residency] matrix.
#   T2 GEMM  : verif/tests/custom/ai/ai_bench_gemm.S assembled per point with -D flags, run with
#              +ai_pmu_trace; the island's AI_JOB records (one per tile job, both passes when a
#              residency flag is benched) are harvested into $OUT/ai_bench.log under a BENCH header.
#   T0/T1 ops: verif/tests/custom/ai/ai_bench_t0.S (dot4 / dot4a / mma / mvta+mvacc) reports
#              cycles for ITER issues through tohost = (cycles << 1) | 1.
# verif/regress/remote/ai_bench_report.py --soc reduces both to cycles per operation.
#   AI_MATRIX_BENCH_FMTS="0 1 3 4 5 6 7"        numeric formats (needs the bench SKU model for
#                                               anything but 0/1: AI_MATRIX_BENCH_SKU=1)
#   AI_MATRIX_BENCH_SHAPES="1x512x512 1x256x1024 64x512x512 64x256x1024"   MxNxK
#   AI_MATRIX_BENCH_KBOX=512   K per job (1024 on the flat-panel island: 1x256x1024 = one job)
#   AI_MATRIX_BENCH_PATHS="0 1"                 0 MMIO doorbell (low level), 1 ai.enq/ai.poll (high level)
#   AI_MATRIX_BENCH_REUSE="0 1 2"               0 cold, 1 FLAG_REUSE_A, 2 FLAG_REUSE_B (second pass)
#   AI_MATRIX_BENCH_T0="0 1 2 3"                T0 ops (dot4, dot4a, mma, mvta+mvacc); "" skips
#   AI_MATRIX_BENCH_ITER=256
if [[ "${AI_MATRIX_BENCH:-0}" == "1" ]]; then
  bench_log="$OUT/ai_bench.log"; : > "$bench_log"
  bench_one() {  # name, defines..., -> PASS/FAIL, appends the records
    local t="$1"; shift
    local elf="$OUT/${t}.elf" src="$1"; shift
    log "=== $t ==="
    "$RISCV_CC" -march=rv64imafdc_zicsr -mabi=lp64d -nostdlib -nostartfiles "$@" \
      -T "$LD" -I"$COMMON" -o "$elf" "$src"
    local th; th=$("$CROSS_NM" "$elf" | awk '$3=="tohost"{print $1; exit}')
    local log_file="/tmp/ai-matrix-veri_${t}.log"
    set +e
    "$HARNESS" +time_out="$TIME_OUT" +debug_disable +ai_pmu_trace ${th:+ +tohost_addr=0x$th} "$elf" >"$log_file" 2>&1
    set -e
    BENCH_LOG_FILE="$log_file"
  }
  for fmt in ${AI_MATRIX_BENCH_FMTS:-0 1 3 4 5 6 7}; do
    for shape in ${AI_MATRIX_BENCH_SHAPES:-1x512x512 1x256x1024 64x512x512 64x256x1024}; do
      IFS=x read -r bm bn bk <<< "$shape"
      for path in ${AI_MATRIX_BENCH_PATHS:-0 1}; do
        for reuse in ${AI_MATRIX_BENCH_REUSE:-0 1 2}; do
          kbox="${AI_MATRIX_BENCH_KBOX:-512}"
          t="ai_bench_gemm_f${fmt}_${shape}_p${path}_r${reuse}"
          [[ "$kbox" == 512 ]] || t="${t}_kb${kbox}"
          bench_one "$t" verif/tests/custom/ai/ai_bench_gemm.S \
            -DFMT="$fmt" -DM="$bm" -DN="$bn" -DK="$bk" -DPATH="$path" -DREUSE="$reuse" -DKBOX="$kbox"
          if grep -q '\*\*\* SUCCESS \*\*\*' "$BENCH_LOG_FILE"; then
            log "PASS $t"; PASS=$((PASS+1))
            { echo "BENCH op=gemm fmt=$fmt m=$bm n=$bn k=$bk path=$path reuse=$reuse kbox=$kbox elf=$t"
              grep '^AI_JOB ' "$BENCH_LOG_FILE"; } >> "$bench_log"
          else
            log "FAIL $t"; FAIL=$((FAIL+1)); grep -E "tohost|FAILED|ILLEGAL" "$BENCH_LOG_FILE" | head -3 || true
          fi
        done
      done
    done
  done
  t0_names=(dot4.s8 dot4a.s8 mma.s8 mvta+mvacc)
  for op in ${AI_MATRIX_BENCH_T0-0 1 2 3}; do
    iter="${AI_MATRIX_BENCH_ITER:-256}"
    t="ai_bench_t0_op${op}"
    bench_one "$t" verif/tests/custom/ai/ai_bench_t0.S -DOP="$op" -DITER="$iter"
    code=$(grep -oE 'tohost = [0-9]+' "$BENCH_LOG_FILE" | head -1 | awk '{print $3}')
    if [[ -n "$code" && "$code" != "1" && $((code & 1)) == 1 && $((code >> 1)) -gt 20 ]]; then
      log "PASS $t cycles=$((code >> 1)) iter=$iter"; PASS=$((PASS+1))
      echo "BENCH_T0 op=${t0_names[$op]} iter=$iter cycles=$((code >> 1))" >> "$bench_log"
    else
      log "FAIL $t (tohost=${code:-none})"; FAIL=$((FAIL+1))
    fi
  done
  log "bench records -> $bench_log ($(grep -c '^AI_JOB' "$bench_log") jobs, $(grep -c '^BENCH_T0' "$bench_log") T0 points)"
  python3 "$ROOT/verif/regress/remote/ai_bench_report.py" "$OUT" --soc --json "$OUT/ai_bench.json" || true
  log "SUMMARY pass=${PASS} fail=${FAIL} total=$((PASS+FAIL))"
  [[ "$FAIL" -eq 0 ]]
  exit $?
fi

for t in "${tests[@]}"; do
  src="verif/tests/custom/ai/${t}.S"
  elf="$OUT/${t}.elf"
  log "=== $t ==="
  if [[ ! -f "$src" ]]; then
    log "FAIL $t (missing $src)"; FAIL=$((FAIL+1)); continue
  fi
  # g6lc64_ai has F/D/C — allow imafdc; fall back if needed
  if ! "$RISCV_CC" -march=rv64imafdc_zicsr -mabi=lp64d -nostdlib -nostartfiles \
      -T "$LD" -I"$COMMON" -o "$elf" "$src" 2>/dev/null; then
    "$RISCV_CC" -march=rv64imafdc -mabi=lp64d -nostdlib -nostartfiles \
      -T "$LD" -I"$COMMON" -o "$elf" "$src"
  fi
  th=$("$CROSS_NM" "$elf" | awk '$3=="tohost"{print $1; exit}')
  log_file="/tmp/ai-matrix-veri_${t}.log"
  set +e
  "$HARNESS" \
    +time_out="$TIME_OUT" \
    +debug_disable \
    ${th:+ +tohost_addr=0x$th} \
    "$elf" >"$log_file" 2>&1
  set -e
  tail -8 "$log_file"
  # Mini AI tests: tohost=1 pass, tohost=2 fail (bit0 still 1 → SUCCESS tracer)
  if grep -q '\*\*\* SUCCESS \*\*\*' "$log_file"; then
    if grep -qE 'tohost = 2\b|tohost = 0x0*2\b' "$log_file"; then
      log "FAIL $t (tohost fail code 2)"
      FAIL=$((FAIL+1))
    else
      log "PASS $t"
      PASS=$((PASS+1))
    fi
  else
    log "FAIL $t"
    FAIL=$((FAIL+1))
    grep -E "ILLEGAL|exception|FAILED|DIDNOTCONVERGE|tohost" "$log_file" | head -12 || true
  fi
done

log "SUMMARY pass=${PASS} fail=${FAIL} total=${#tests[@]}"
[[ "$FAIL" -eq 0 ]]
