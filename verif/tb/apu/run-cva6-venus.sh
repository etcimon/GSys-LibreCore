#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# 3d-a: CVA6 hart runs software/apu-venus-probe (bare-metal virtio_mmio +
# virtio_gpu probe + vn_golden tape player) against g6lc_apu_th_load with
# ApuCfg=ApuVenus; a second +venusoff arm runs the ApuP1Transport fixture.
# Not a kernel boot, not SMT2, not TEX.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
export TARGET_CFG="${TARGET_CFG:-g6lc64_stream8}"
OUT="${APU_VENUS_OUT:-/tmp/g6lc-apu-cva6-venus}/${TARGET_CFG}"
VERILATOR="${VERILATOR:-verilator}"
export CVA6_REPO_DIR="$ROOT"
# System verilator (5.020+) internal-faults on the cluster tree; prefer
# the repo-pinned 5.008 build.
if [ "$("$VERILATOR" --version 2>/dev/null | cut -d" " -f2)" != "5.008" ]; then
  for c in /opt/testharness/toolchains/verilator-v5.008/bin/verilator \
           /root/verilator-build/bin/verilator; do
    [ -x "$c" ] && { VERILATOR="$c"; break; }
  done
fi
case "$VERILATOR" in /root/verilator-build/*) export VERILATOR_ROOT=/root/verilator-build ;; esac
export HPDCACHE_DIR="${HPDCACHE_DIR:-$ROOT/core/cache_subsystem/hpdcache}"
mkdir -p "$OUT"

# ---- software ---------------------------------------------------------------
# RISCV may point at a stale xpack prefix; probe for a real compiler.
if [ -n "${RISCV:-}" ] && command -v "${RISCV}gcc" >/dev/null 2>&1; then :;
elif command -v riscv64-unknown-elf-gcc >/dev/null 2>&1; then RISCV=riscv64-unknown-elf-;
elif command -v riscv-none-elf-gcc >/dev/null 2>&1; then RISCV=riscv-none-elf-;
fi
if ! command -v "${RISCV}gcc" >/dev/null 2>&1; then
  echo "FATAL: ${RISCV}gcc not on PATH (bare-metal RISC-V toolchain needed)" >&2
  exit 1
fi
t0=$SECONDS
( cd "$ROOT/software/apu-venus-probe" && \
  make RISCV="$RISCV" TARGET_CFG="$TARGET_CFG" ) 2>&1 | tee "$OUT/sw.log"
cp "$ROOT/software/apu-venus-probe/venus_probe.hex" "$OUT/venus_probe.hex"
cp "$ROOT/software/apu-venus-probe/vn_map.svh" "$OUT/vn_map.svh"
# image size accounting for the report
( cd "$ROOT/software/apu-venus-probe" && \
  "${RISCV}size" venus_probe.elf ) 2>&1 | tee -a "$OUT/sw.log"
SW_SECS=$((SECONDS - t0))

# ---- verilate ----------------------------------------------------------------
# Flist.apu_soc overlaps Flist.cva6 (config_pkg, axi_pkg, fpnew, common
# cells): flist_union merges them once, in Flist.cva6-first order.
python3 "$ROOT/verif/tb/apu/flist_union.py" "$OUT/cva6_venus.f" \
  "$ROOT/core/Flist.cva6" "$ROOT/corev_apu/apu/Flist.apu_soc" \
  2>&1 | tee -a "$OUT/build.log"
t0=$SECONDS
"$VERILATOR" --binary --timing --assert --unroll-count 256 -Wno-fatal \
  -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-BLKSEQ -Wno-SYNCASYNCNET \
  -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY -Wno-UNOPTFLAT -Wno-BLKANDNBLK \
  -Wno-CMPCONST -Wno-IMPLICIT -Wno-VARHIDDEN -Wno-LITENDIAN \
  -Wno-PINMISSING -Wno-CASEINCOMPLETE -Wno-UNSIGNED -Wno-style \
  "$ROOT/verif/tb/apu/apu_axi.vlt" "$ROOT/verilator_config.vlt" \
  -f "$OUT/cva6_venus.f" \
  +incdir+"$ROOT/corev_apu/include" \
  +incdir+"$ROOT/corev_apu/src" \
  +incdir+"$ROOT/corev_apu/apu/include" \
  +incdir+"$ROOT/corev_apu/register_interface/include" \
  +incdir+"$ROOT/vendor/pulp-platform/register_interface/include" \
  +incdir+"$OUT" \
  "$ROOT/corev_apu/tb/ariane_axi_pkg.sv" \
  "$ROOT/corev_apu/coherence/g6lc_coherence_pkg.sv" \
  "$ROOT/corev_apu/coherence/g6lc_inval_bus.sv" \
  "$ROOT/corev_apu/coherence/g6lc_snoop_filter.sv" \
  "$ROOT/corev_apu/coherence/g6lc_lr_sc_tracker.sv" \
  "$ROOT/corev_apu/coherence/g6lc_l1_inv_adapter.sv" \
  "$ROOT/corev_apu/coherence/g6lc_coherence_hub.sv" \
  "$ROOT/corev_apu/coherence/g6lc_cmo_engine.sv" \
  "$ROOT/corev_apu/l3_cache/g6lc_server_prefetcher.sv" \
  "$ROOT/corev_apu/l3_cache/g6lc_l3_inclusive_inv.sv" \
  "$ROOT/corev_apu/src/ariane.sv" \
  "$ROOT/corev_apu/src/g6lc_cluster.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_enq_arb.sv" \
  "$ROOT/verif/tb/apu/tb_g6lc_apu_cva6_venus.sv" \
  "$ROOT/verif/tb/apu/g6lc_dram_peek64_stub.cpp" \
  --top-module tb_g6lc_apu_cva6_venus \
  -Mdir "$OUT" -o tb_g6lc_apu_cva6_venus \
  2>&1 | tee -a "$OUT/build.log"
BUILD_SECS=$((SECONDS - t0))
echo "verilator build ${BUILD_SECS}s (software ${SW_SECS}s)" | tee "$OUT/times.log"

# ---- arms ---------------------------------------------------------------------
( cd "$OUT" && ./tb_g6lc_apu_cva6_venus ) 2>&1 | tee "$OUT/sim-venus.log"
( cd "$OUT" && ./tb_g6lc_apu_cva6_venus +venusoff ) \
  2>&1 | tee "$OUT/sim-venusoff.log"
grep -h "PASS" "$OUT/sim-venus.log" "$OUT/sim-venusoff.log"

# ---- lint ----------------------------------------------------------------------
"$VERILATOR" --lint-only --timing --assert -Wno-fatal -Wall -Wno-TIMESCALEMOD \
  -Wno-UNUSED -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-BLKSEQ -Wno-UNOPTFLAT \
  -Wno-BLKANDNBLK -Wno-LITENDIAN -Wno-CMPCONST -Wno-UNSIGNED \
  "$ROOT/verif/tb/apu/apu_axi.vlt" "$ROOT/verilator_config.vlt" \
  -f "$OUT/cva6_venus.f" \
  +incdir+"$ROOT/corev_apu/include" \
  +incdir+"$ROOT/corev_apu/src" \
  +incdir+"$ROOT/corev_apu/apu/include" \
  +incdir+"$ROOT/corev_apu/register_interface/include" \
  +incdir+"$ROOT/vendor/pulp-platform/register_interface/include" \
  +incdir+"$OUT" \
  "$ROOT/corev_apu/tb/ariane_axi_pkg.sv" \
  "$ROOT/corev_apu/coherence/g6lc_coherence_pkg.sv" \
  "$ROOT/corev_apu/coherence/g6lc_inval_bus.sv" \
  "$ROOT/corev_apu/coherence/g6lc_snoop_filter.sv" \
  "$ROOT/corev_apu/coherence/g6lc_lr_sc_tracker.sv" \
  "$ROOT/corev_apu/coherence/g6lc_l1_inv_adapter.sv" \
  "$ROOT/corev_apu/coherence/g6lc_coherence_hub.sv" \
  "$ROOT/corev_apu/coherence/g6lc_cmo_engine.sv" \
  "$ROOT/corev_apu/l3_cache/g6lc_server_prefetcher.sv" \
  "$ROOT/corev_apu/l3_cache/g6lc_l3_inclusive_inv.sv" \
  "$ROOT/corev_apu/src/ariane.sv" \
  "$ROOT/corev_apu/src/g6lc_cluster.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_enq_arb.sv" \
  "$ROOT/verif/tb/apu/tb_g6lc_apu_cva6_venus.sv" \
  --top-module tb_g6lc_apu_cva6_venus \
  2>&1 | tee "$OUT/lint.log"
