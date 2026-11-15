#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Standalone leaf testbench for the cluster coherence hub
# (g6lc_coherence_hub) + CMO engine + L1/L2/L3 invalidation path
# (tb_g6lc_coherence_l2). Until now this bench only ran through the remote
# run_inval_review.py harness; this script makes it runnable locally/CI.
#
#   bash verif/tb/l2/run-coherence-hub.sh            # scenarios 0..9, USE_L3=0
#   COH_L3=1 bash verif/tb/l2/run-coherence-hub.sh   # same, L3 stacked
#   COH_SCENARIOS="6 7" bash ...                     # subset
#   COH_NEGATIVE=1 bash ...                          # +oracle_negative arms
#
# Knobs (env):
#   COH_OUT=<dir>        output dir (default /tmp/g6lc-coh-hub)
#   COH_L3=0|1           stack axi_cut + g6lc_l3_top (default 0)
#   COH_SCENARIOS="..."  space-separated scenario ids (default 0..9)
#   COH_NEGATIVE=0|1     also run each scenario with +oracle_negative (default 0)
#   COH_RTL=<repo-rel>   RTL root holding coherence/l2_cache/l3_cache
#                        (default corev_apu; hyp8 redesign is
#                        build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu)
#   COH_EXTRA_G=-Gname=v extra -G overrides for the bench top
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
COH_RTL="${COH_RTL:-corev_apu}"
[[ "$COH_RTL" =~ ^[A-Za-z0-9_./-]+$ && "$COH_RTL" != *..* ]] || { echo "[coh-hub] bad COH_RTL" >&2; exit 2; }
OUT="${COH_OUT:-/tmp/g6lc-coh-hub}"
mkdir -p "$OUT"

VERILATOR="${VERILATOR:-verilator}"
if ! command -v "$VERILATOR" >/dev/null 2>&1; then
  for c in /root/tools/verilator-v5.008/bin/verilator \
           /opt/testharness/toolchains/verilator-v5.008/bin/verilator \
           "$ROOT/build-platform/workspace/tooling/linux-eda-suite/bin/verilator_bin"; do
    [ -x "$c" ] && VERILATOR="$c" && break
  done
fi
command -v "$VERILATOR" >/dev/null 2>&1 || { echo "[coh-hub] no verilator" >&2; exit 2; }
"$VERILATOR" --version
ulimit -c 0

R="$ROOT/$COH_RTL"
T="$OUT/types.sv"
# g6lc_l2_tb_pkg (AXI channel/transaction types) lives at the top of the L2
# leaf bench; extract just the package like run_inval_review.py does.
sed -n '/^package g6lc_l2_tb_pkg;/,/^endpackage/p' \
  "$ROOT/verif/tb/l2/tb_g6lc_l2.sv" > "$T"
grep -q 'endpackage' "$T" || { echo "[coh-hub] g6lc_l2_tb_pkg extraction failed" >&2; exit 2; }

sources=(
  "$T"
  "$ROOT/core/include/config_pkg.sv"
  "$ROOT/core/include/cva6_config_pkg.sv"
  "$ROOT/core/include/riscv_pkg.sv"
  "$ROOT/core/include/ariane_pkg.sv"
  "$ROOT/core/include/g6lc_pkg.sv"
  "$ROOT/vendor/pulp-platform/axi/src/axi_pkg.sv"
  "$ROOT/vendor/pulp-platform/axi/src/axi_cut.sv"
  "$ROOT/vendor/pulp-platform/common_cells/src/spill_register.sv"
  "$ROOT/vendor/pulp-platform/common_cells/src/spill_register_flushable.sv"
  "$ROOT/vendor/pulp-platform/tech_cells_generic/src/rtl/tc_sram.sv"
  "$ROOT/vendor/pulp-platform/tech_cells_generic/src/rtl/tc_clk.sv"
  "$R/coherence/g6lc_coherence_pkg.sv"
  "$R/coherence/g6lc_inval_bus.sv"
  "$R/coherence/g6lc_snoop_filter.sv"
  "$R/coherence/g6lc_ooo_snoop_filter.sv"
  "$R/coherence/g6lc_lr_sc_tracker.sv"
  "$R/coherence/g6lc_l1_inv_adapter.sv"
  "$R/coherence/g6lc_coherence_hub.sv"
  "$R/coherence/g6lc_cmo_engine.sv"
  "$R/l2_cache/g6lc_l2_pkg.sv"
  "$R/l2_cache/g6lc_l2_tag.sv"
  "$R/l2_cache/g6lc_l2_data.sv"
  "$R/l2_cache/g6lc_l2_mshr.sv"
  "$R/l2_cache/g6lc_l2_wtrk.sv"
  "$R/l2_cache/g6lc_l2_pf.sv"
  "$R/l2_cache/g6lc_l2_top.sv"
  "$R/l3_cache/g6lc_l3_pkg.sv"
  "$R/l3_cache/g6lc_l3_inclusive_inv.sv"
  "$R/l3_cache/g6lc_server_prefetcher.sv"
  "$R/l3_cache/g6lc_l3_top.sv"
  "$ROOT/verif/tb/l2/tb_g6lc_coherence_hub.sv"
)

GFLAGS=(-GUSE_L3="${COH_L3:-0}")
read -r -a EXTRA <<< "${COH_EXTRA_G:-}"
GFLAGS+=("${EXTRA[@]}")

SIM="$OUT/sim"
"$VERILATOR" --binary --timing -Wno-fatal \
  -Wno-DECLFILENAME -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSED \
  -Wno-PINCONNECTEMPTY "${GFLAGS[@]}" \
  +incdir+"$ROOT/core/include" +incdir+"$ROOT/corev_apu/include" \
  +incdir+"$ROOT/vendor/pulp-platform/axi/include" \
  "${sources[@]}" \
  --top-module tb_g6lc_coherence_l2 \
  -Mdir "$SIM" -o tb_g6lc_coherence_l2 \
  > "$OUT/build.log" 2>&1 || {
    echo "VERILATOR BUILD FAILED"; tail -n 60 "$OUT/build.log"; exit 1; }
echo "VERILATOR BUILD OK"

SCENARIOS="${COH_SCENARIOS:-0 1 2 3 4 5 6 7 8 9}"
rc_all=0
for s in $SCENARIOS; do
  for neg in 0 1; do
    [ "$neg" = 1 ] && [ "${COH_NEGATIVE:-0}" != 1 ] && continue
    args=(+scenario="$s")
    [ "$neg" = 1 ] && args+=(+oracle_negative)
    log="$OUT/scenario-$s-neg$neg.log"
    set +e
    "$SIM/tb_g6lc_coherence_l2" "${args[@]}" > "$log" 2>&1
    rc=$?
    set -e
    if grep -q "PASS scenario=$s" "$log"; then
      echo "PASS scenario=$s neg=$neg"
    else
      echo "FAIL scenario=$s neg=$neg rc=$rc"
      grep -iE "fatal|assert|error" "$log" | head -3
      rc_all=1
    fi
  done
done
exit $rc_all
