#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# Isolated Zimop / Zcmop / Zihintntl decode leaves (tools/verilator g6lc PGO).
set -euo pipefail
if [ -f /opt/testharness/env.sh ]; then
  # shellcheck disable=SC1091
  . /opt/testharness/env.sh
  for cand in \
      /opt/testharness/toolchains/verilator-v5.008-g6lc-6fa24f6f-pgo \
      /opt/testharness/toolchains/verilator-v5.008-g6lc; do
    if [ -x "$cand/bin/verilator" ]; then
      export VLT_HOME="$cand"
      if [ -d "$cand/runtime" ]; then
        export VERILATOR_ROOT="$cand/runtime"
      elif [ -d "$cand/share/verilator" ]; then
        export VERILATOR_ROOT="$cand/share/verilator"
      fi
      export PATH="$cand/bin:$PATH"
      break
    fi
  done
fi
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
if ! command -v verilator >/dev/null 2>&1; then echo "SKIP no verilator"; exit 0; fi
echo "verilator=$(command -v verilator) VERILATOR_ROOT=${VERILATOR_ROOT:-}"
OUT="${ZIMOP_NTL_OUT:-/tmp/g6lc-zimop-ntl}"
mkdir -p "$OUT"
VFLAGS=(--binary --timing --assert -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED
  -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-PINCONNECTEMPTY -Wno-CASEINCOMPLETE
  -Wno-UNOPTFLAT -I"$ROOT/core/include" -I"$ROOT/core" -I"$ROOT/core/include/fetch_B")

build_zcmop() {
  verilator "${VFLAGS[@]}" \
    "$ROOT/core/include/config_pkg.sv" \
    "$ROOT/core/include/g6lc64_smt2_config_pkg.sv" \
    "$ROOT/core/include/riscv_pkg.sv" \
    "$ROOT/core/g6lc_rvc_enc.sv" \
    "$ROOT/core/compressed_decoder.sv" \
    "$ROOT/verif/tb/core/tb_g6lc_zcmop.sv" \
    --top-module tb_g6lc_zcmop -Mdir "$OUT/$1" -o tb ${2:-} \
    > "$OUT/$1.build.log" 2>&1
}
build_zimop() {
  verilator "${VFLAGS[@]}" \
    "$ROOT/core/include/config_pkg.sv" \
    "$ROOT/core/include/g6lc64_smt2_config_pkg.sv" \
    "$ROOT/core/include/riscv_pkg.sv" \
    "$ROOT/core/include/ariane_pkg.sv" \
    "$ROOT/core/decoder.sv" \
    "$ROOT/verif/tb/core/tb_g6lc_zimop.sv" \
    --top-module tb_g6lc_zimop -Mdir "$OUT/$1" -o tb ${2:-} \
    > "$OUT/$1.build.log" 2>&1
}

build_zcmop zcmop_pos
"$OUT/zcmop_pos/tb" | tee "$OUT/zcmop_pos.log" | grep -q "^PASS tb_g6lc_zcmop" \
  || { echo "FAIL zcmop positive"; tail -20 "$OUT/zcmop_pos.build.log"; exit 1; }
build_zcmop zcmop_mut "+define+G6LC_MUT_ZCMOP_OFF"
set +e
"$OUT/zcmop_mut/tb" > "$OUT/zcmop_mut.log" 2>&1
grep -q "ZCMOP_ON" "$OUT/zcmop_mut.log" || { echo "FAIL mutation G6LC_MUT_ZCMOP_OFF not caught"; cat "$OUT/zcmop_mut.log"; exit 1; }
set -e

build_zimop zimop_pos
"$OUT/zimop_pos/tb" | tee "$OUT/zimop_pos.log" | grep -q "^PASS tb_g6lc_zimop" \
  || { echo "FAIL zimop positive"; tail -40 "$OUT/zimop_pos.build.log"; exit 1; }
build_zimop zimop_mut "+define+G6LC_MUT_ZIMOP_OFF"
set +e
"$OUT/zimop_mut/tb" > "$OUT/zimop_mut.log" 2>&1
grep -q "ZIMOP_ON" "$OUT/zimop_mut.log" || { echo "FAIL mutation G6LC_MUT_ZIMOP_OFF not caught"; cat "$OUT/zimop_mut.log"; exit 1; }
set -e

build_zfhmin() {
  verilator "${VFLAGS[@]}" \
    "$ROOT/core/include/config_pkg.sv" \
    "$ROOT/core/include/g6lc64_smt2_config_pkg.sv" \
    "$ROOT/core/include/riscv_pkg.sv" \
    "$ROOT/core/include/ariane_pkg.sv" \
    "$ROOT/core/decoder.sv" \
    "$ROOT/verif/tb/core/tb_g6lc_zfhmin.sv" \
    --top-module tb_g6lc_zfhmin -Mdir "$OUT/$1" -o tb ${2:-} \
    > "$OUT/$1.build.log" 2>&1
}
build_zfhmin zfhmin_pos
"$OUT/zfhmin_pos/tb" | tee "$OUT/zfhmin_pos.log" | grep -q "^PASS tb_g6lc_zfhmin" \
  || { echo "FAIL zfhmin positive"; tail -40 "$OUT/zfhmin_pos.build.log"; exit 1; }
build_zfhmin zfhmin_mut "+define+G6LC_MUT_ZFHMIN_OFF"
set +e
"$OUT/zfhmin_mut/tb" > "$OUT/zfhmin_mut.log" 2>&1
grep -q "ZFHMIN_ON" "$OUT/zfhmin_mut.log" || { echo "FAIL mutation G6LC_MUT_ZFHMIN_OFF not caught"; cat "$OUT/zfhmin_mut.log"; exit 1; }
set -e

build_zfa() {
  verilator "${VFLAGS[@]}" \
    "$ROOT/core/include/config_pkg.sv" \
    "$ROOT/core/include/g6lc64_smt2_config_pkg.sv" \
    "$ROOT/core/include/riscv_pkg.sv" \
    "$ROOT/core/include/ariane_pkg.sv" \
    "$ROOT/core/decoder.sv" \
    "$ROOT/verif/tb/core/tb_g6lc_zfa.sv" \
    --top-module tb_g6lc_zfa -Mdir "$OUT/$1" -o tb ${2:-} \
    > "$OUT/$1.build.log" 2>&1
}
build_zfa zfa_pos
"$OUT/zfa_pos/tb" | tee "$OUT/zfa_pos.log" | grep -q "^PASS tb_g6lc_zfa" \
  || { echo "FAIL zfa positive"; tail -40 "$OUT/zfa_pos.build.log"; exit 1; }
build_zfa zfa_mut "+define+G6LC_MUT_ZFA_OFF"
set +e
"$OUT/zfa_mut/tb" > "$OUT/zfa_mut.log" 2>&1
grep -q "ZFA_ON" "$OUT/zfa_mut.log" || { echo "FAIL mutation G6LC_MUT_ZFA_OFF not caught"; cat "$OUT/zfa_mut.log"; exit 1; }
set -e

build_fp_zfa() {
  verilator "${VFLAGS[@]}" \
    "$ROOT/core/include/config_pkg.sv" \
    "$ROOT/core/include/g6lc64_smt2_config_pkg.sv" \
    "$ROOT/core/include/riscv_pkg.sv" \
    "$ROOT/core/include/ariane_pkg.sv" \
    "$ROOT/core/g6lc_fp_zfa.sv" \
    "$ROOT/verif/tb/core/tb_g6lc_fp_zfa.sv" \
    --top-module tb_g6lc_fp_zfa -Mdir "$OUT/$1" -o tb ${2:-} \
    > "$OUT/$1.build.log" 2>&1
}
build_fp_zfa fp_zfa_pos
"$OUT/fp_zfa_pos/tb" | tee "$OUT/fp_zfa_pos.log" | grep -q "^PASS tb_g6lc_fp_zfa" \
  || { echo "FAIL fp_zfa positive"; tail -80 "$OUT/fp_zfa_pos.build.log"; exit 1; }

build_zicclsm() {
  verilator "${VFLAGS[@]}" \
    "$ROOT/core/include/config_pkg.sv" \
    "$ROOT/core/include/g6lc64_smt2_config_pkg.sv" \
    "$ROOT/core/include/riscv_pkg.sv" \
    "$ROOT/core/include/ariane_pkg.sv" \
    "$ROOT/core/g6lc_zicclsm.sv" \
    "$ROOT/verif/tb/core/tb_g6lc_zicclsm.sv" \
    --top-module tb_g6lc_zicclsm -Mdir "$OUT/$1" -o tb ${2:-} \
    > "$OUT/$1.build.log" 2>&1
}
build_zicclsm zicclsm_pos
"$OUT/zicclsm_pos/tb" | tee "$OUT/zicclsm_pos.log" | grep -q "^PASS tb_g6lc_zicclsm" \
  || { echo "FAIL zicclsm positive"; tail -80 "$OUT/zicclsm_pos.build.log"; exit 1; }
build_zicclsm zicclsm_mut "+define+G6LC_MUT_ZICCLSM_OFF"
set +e
"$OUT/zicclsm_mut/tb" > "$OUT/zicclsm_mut.log" 2>&1
grep -q "ZICCLSM_ON" "$OUT/zicclsm_mut.log" || { echo "FAIL mutation G6LC_MUT_ZICCLSM_OFF not caught"; cat "$OUT/zicclsm_mut.log"; exit 1; }
set -e
build_zicclsm zicclsm_tid_mut "+define+G6LC_MUT_ZICCLSM_TID_SWALLOW"
set +e
"$OUT/zicclsm_tid_mut/tb" > "$OUT/zicclsm_tid_mut.log" 2>&1
grep -q "ZICCLSM_OOO_TID_SWALLOW" "$OUT/zicclsm_tid_mut.log" || { echo "FAIL mutation G6LC_MUT_ZICCLSM_TID_SWALLOW not caught"; cat "$OUT/zicclsm_tid_mut.log"; exit 1; }
set -e

build_za64rs() {
  verilator "${VFLAGS[@]}" \
    "$ROOT/core/include/config_pkg.sv" \
    "$ROOT/core/include/g6lc64_smt2_config_pkg.sv" \
    "$ROOT/core/include/riscv_pkg.sv" \
    "$ROOT/core/g6lc_za64rs.sv" \
    "$ROOT/verif/tb/core/tb_g6lc_za64rs.sv" \
    --top-module tb_g6lc_za64rs -Mdir "$OUT/$1" -o tb ${2:-} \
    > "$OUT/$1.build.log" 2>&1
}
build_za64rs za64rs_pos
"$OUT/za64rs_pos/tb" | tee "$OUT/za64rs_pos.log" | grep -q "^PASS tb_g6lc_za64rs" \
  || { echo "FAIL za64rs positive"; tail -80 "$OUT/za64rs_pos.build.log"; exit 1; }
build_za64rs za64rs_mut "+define+G6LC_MUT_ZA64RS_OFF"
set +e
"$OUT/za64rs_mut/tb" > "$OUT/za64rs_mut.log" 2>&1
grep -q "ZA64RS_ON" "$OUT/za64rs_mut.log" || { echo "FAIL mutation G6LC_MUT_ZA64RS_OFF not caught"; cat "$OUT/za64rs_mut.log"; exit 1; }
set -e

build_zawrs() {
  verilator "${VFLAGS[@]}" \
    "$ROOT/core/include/config_pkg.sv" \
    "$ROOT/core/include/g6lc64_smt2_config_pkg.sv" \
    "$ROOT/core/include/riscv_pkg.sv" \
    "$ROOT/core/include/ariane_pkg.sv" \
    "$ROOT/core/decoder.sv" \
    "$ROOT/verif/tb/core/tb_g6lc_zawrs.sv" \
    --top-module tb_g6lc_zawrs -Mdir "$OUT/$1" -o tb ${2:-} \
    > "$OUT/$1.build.log" 2>&1
}
build_zawrs zawrs_pos
"$OUT/zawrs_pos/tb" | tee "$OUT/zawrs_pos.log" | grep -q "^PASS tb_g6lc_zawrs" \
  || { echo "FAIL zawrs positive"; tail -80 "$OUT/zawrs_pos.build.log"; exit 1; }
build_zawrs zawrs_mut "+define+G6LC_MUT_ZAWRS_OFF"
set +e
"$OUT/zawrs_mut/tb" > "$OUT/zawrs_mut.log" 2>&1
grep -q "ZAWRS_ON" "$OUT/zawrs_mut.log" || { echo "FAIL mutation G6LC_MUT_ZAWRS_OFF not caught"; cat "$OUT/zawrs_mut.log"; exit 1; }
set -e

build_zawrs_wait() {
  verilator "${VFLAGS[@]}" \
    "$ROOT/core/include/config_pkg.sv" \
    "$ROOT/core/include/g6lc64_smt2_config_pkg.sv" \
    "$ROOT/core/include/riscv_pkg.sv" \
    "$ROOT/core/g6lc_zawrs.sv" \
    "$ROOT/verif/tb/core/tb_g6lc_zawrs_wait.sv" \
    --top-module tb_g6lc_zawrs_wait -Mdir "$OUT/$1" -o tb ${2:-} \
    > "$OUT/$1.build.log" 2>&1
}
build_zawrs_wait zawrs_wait_pos
"$OUT/zawrs_wait_pos/tb" | tee "$OUT/zawrs_wait_pos.log" | grep -q "^PASS tb_g6lc_zawrs_wait" \
  || { echo "FAIL zawrs_wait positive"; tail -80 "$OUT/zawrs_wait_pos.build.log"; exit 1; }
build_zawrs_wait zawrs_wait_mut "+define+G6LC_MUT_ZAWRS_WAIT_OFF"
set +e
"$OUT/zawrs_wait_mut/tb" > "$OUT/zawrs_wait_mut.log" 2>&1
grep -q "ZAWRS_WAIT_ON" "$OUT/zawrs_wait_mut.log" || { echo "FAIL mutation G6LC_MUT_ZAWRS_WAIT_OFF not caught"; cat "$OUT/zawrs_wait_mut.log"; exit 1; }
set -e
build_pma_zi() {
  verilator "${VFLAGS[@]}" \
    "$ROOT/core/include/config_pkg.sv" \
    "$ROOT/core/include/g6lc64_smt2_config_pkg.sv" \
    "$ROOT/core/include/riscv_pkg.sv" \
    "$ROOT/core/g6lc_pma_zi.sv" \
    "$ROOT/verif/tb/core/tb_g6lc_pma_zi.sv" \
    --top-module tb_g6lc_pma_zi -Mdir "$OUT/$1" -o tb ${2:-} \
    > "$OUT/$1.build.log" 2>&1
}
build_pma_zi pma_zi_pos
"$OUT/pma_zi_pos/tb" | tee "$OUT/pma_zi_pos.log" | grep -q "^PASS tb_g6lc_pma_zi" \
  || { echo "FAIL pma_zi positive"; tail -80 "$OUT/pma_zi_pos.build.log"; exit 1; }
build_pma_zi pma_zi_mut "+define+G6LC_MUT_PMA_ZI_OFF"
set +e
"$OUT/pma_zi_mut/tb" > "$OUT/pma_zi_mut.log" 2>&1
grep -q "PMA_ZI_ON" "$OUT/pma_zi_mut.log" || { echo "FAIL mutation G6LC_MUT_PMA_ZI_OFF not caught"; cat "$OUT/pma_zi_mut.log"; exit 1; }
set -e
build_zawrs_peer() {
  verilator "${VFLAGS[@]}" \
    "$ROOT/core/include/config_pkg.sv" \
    "$ROOT/core/g6lc_zawrs_peer.sv" \
    "$ROOT/verif/tb/core/tb_g6lc_zawrs_peer.sv" \
    --top-module tb_g6lc_zawrs_peer -Mdir "$OUT/$1" -o tb ${2:-} \
    > "$OUT/$1.build.log" 2>&1
}
build_zawrs_peer zawrs_peer_pos
"$OUT/zawrs_peer_pos/tb" | tee "$OUT/zawrs_peer_pos.log" | grep -q "^PASS tb_g6lc_zawrs_peer" \
  || { echo "FAIL zawrs_peer positive"; tail -80 "$OUT/zawrs_peer_pos.build.log"; exit 1; }
build_zawrs_peer zawrs_peer_mut "+define+G6LC_MUT_ZAWRS_PEER_OFF"
set +e
"$OUT/zawrs_peer_mut/tb" > "$OUT/zawrs_peer_mut.log" 2>&1
grep -q "ZAWRS_PEER_ON" "$OUT/zawrs_peer_mut.log" || { echo "FAIL mutation G6LC_MUT_ZAWRS_PEER_OFF not caught"; cat "$OUT/zawrs_peer_mut.log"; exit 1; }
set -e
build_zabha() {
  verilator "${VFLAGS[@]}" \
    "$ROOT/core/include/config_pkg.sv" \
    "$ROOT/core/include/g6lc64_smt2_config_pkg.sv" \
    "$ROOT/core/include/riscv_pkg.sv" \
    "$ROOT/core/include/ariane_pkg.sv" \
    "$ROOT/core/decoder.sv" \
    "$ROOT/core/cache_subsystem/amo_alu.sv" \
    "$ROOT/core/g6lc_zabha.sv" \
    "$ROOT/verif/tb/core/tb_g6lc_zabha.sv" \
    --top-module tb_g6lc_zabha -Mdir "$OUT/$1" -o tb ${2:-} \
    > "$OUT/$1.build.log" 2>&1
}
build_zabha zabha_pos
"$OUT/zabha_pos/tb" | tee "$OUT/zabha_pos.log" | grep -q "^PASS tb_g6lc_zabha" \
  || { echo "FAIL zabha positive"; tail -80 "$OUT/zabha_pos.build.log"; exit 1; }
build_zabha zabha_mut "+define+G6LC_MUT_ZABHA_OFF"
set +e
"$OUT/zabha_mut/tb" > "$OUT/zabha_mut.log" 2>&1
grep -q "ZABHA_ON" "$OUT/zabha_mut.log" || { echo "FAIL mutation G6LC_MUT_ZABHA_OFF not caught"; cat "$OUT/zabha_mut.log"; exit 1; }
set -e
echo "PASS run-zimop-ntl (zcmop/zimop/ntl/zfhmin/zfa/zicclsm/za64rs/zawrs/zawrs_wait/zawrs_peer/pma_zi/zabha positive + off-knob mutations)"
