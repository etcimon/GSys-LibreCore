#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Xg6lcai directed-test gate (optional; not default verify).
# Stages:
#   1. contract files present (RTL + tests + package)
#   2. package envelope (CvxifEn, COPRO_G6LC_AI, MatrixEn)
#   3. mini ELF compile of directed .S (soft-skip without toolchain)
#   4. optional LIVE_RTL smoke if AI_MATRIX_LIVE_RTL=1 and harness exists
#
# Env:
#   AI_MATRIX_REQUIRE_COMPILE=1  hard-fail without riscv gcc
#   AI_MATRIX_LIVE_RTL=1         attempt Variane run (lab)
#   AI_MATRIX_OUT=<dir>
#
# Priors: architecture/ai-matrix/ · AGENTS-todo AI-1
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

REQUIRE_COMPILE="${AI_MATRIX_REQUIRE_COMPILE:-0}"
LIVE_RTL="${AI_MATRIX_LIVE_RTL:-0}"
OUT="${AI_MATRIX_OUT:-/tmp/cva6-ai-matrix-directed}"
mkdir -p "$OUT"

PASS=0; FAIL=0; SKIP=0
log() { echo "[ai-matrix-directed] $*"; }
ok()  { PASS=$((PASS+1)); log "PASS $*"; }
bad() { FAIL=$((FAIL+1)); log "FAIL $*"; }
skip(){ SKIP=$((SKIP+1)); log "SKIP $*"; }

log "OPTIONAL — Xg6lcai directed gate"
log "  package: core/include/g6lc64_ai_config_pkg.sv"

need=(
  core/include/g6lc64_ai_config_pkg.sv
  core/cvxif_g6lc_ai/include/g6lc_ai_instr_pkg.sv
  core/cvxif_g6lc_ai/g6lc_ai_coprocessor.sv
  core/cvxif_g6lc_ai/g6lc_ai_exec.sv
  verif/tests/custom/ai/ai_csr_aistatus_xs.S
  verif/tests/custom/ai/ai_setcfg_readback.S
  verif/tests/custom/ai/ai_illegal_when_off.S
  verif/tests/custom/ai/ai_dot4_s8_smoke.S
  verif/tests/custom/ai/ai_mma_s8_golden.S
  verif/tests/custom/ai/ai_requant_rhe_golden.S
  verif/tests/custom/ai/ai_pmu_group4_smoke.S
  verif/tests/custom/ai/ai_queue_doorbell.S
  verif/tests/custom/ai/ai_aiperm_umode.S
  verif/tests/custom/ai/ai_island_mmio_smoke.S
  core/cvxif_g6lc_ai/g6lc_ai_acc_bank.sv
  corev_apu/include/g6lc_ai_island_cfg_pkg.sv
  corev_apu/src/g6lc_ai_dram_backend.sv
  corev_apu/src/g6lc_ai_litedram_wrap.sv
  corev_apu/src/g6lc_ai_dram_channels.sv
  corev_apu/src/g6lc_axi_lrsc.sv
  corev_apu/src/g6lc_axi_atomics_wrap.sv
  verif/tb/ai_island/tb_g6lc_axi_lrsc.sv
  verif/tb/ai_island/tb_g6lc_ai_atomics_aw.sv
  verif/tb/ai_island/run-dram-atomics.sh
  corev_apu/ai_island/g6lc_ai_dram_timing.sv
  corev_apu/ai_island/g6lc_ai_island_apb.sv
  agents/vendor/AGENTS-vendor-litedram.md
  architecture/uncore/litedram-testharness.yml
  architecture/uncore/dram-channel-scaling.md
  verif/tb/ai_island/tb_g6lc_ai_dram_stripe.sv
  verif/tb/ai_island/run-dram-stripe.sh
  verif/tb/ai_island/tb_g6lc_ai_litedram_wrap.sv
  verif/tb/ai_island/run-litedram-wrap.sh
  verif/tb/ai_island/tb_g6lc_ai_dram_bw.sv
  verif/tb/ai_island/run-dram-bw.sh
  verif/tb/ai_island/tb_g6lc_ai_dram_join.sv
  verif/tb/ai_island/run-dram-join.sh
  verif/tb/ai_island/tb_g6lc_ai_dram_join_wide.sv
  verif/tb/ai_island/run-dram-join-wide.sh
  verif/tb/ai_island/tb_g6lc_ai_cluster_dispatch.sv
  verif/tb/ai_island/run-cluster-dispatch.sh
  verif/tb/ai_island/lint_g6lc_ai_island_clusters.sv
  verif/tb/ai_island/run-island-clusters-lint.sh
  verif/tb/ai_island/tb_g6lc_ai_dram_class2.sv
  verif/tb/ai_island/run-dram-class2.sh
  verif/tb/ai_island/tb_g6lc_ai_gemm_wide.sv
  verif/tb/ai_island/run-gemm-wide.sh
  verif/tb/ai_island/tb_g6lc_ai_island_wide.sv
  verif/tb/ai_island/run-island-wide.sh
  verif/tb/ai_island/tb_g6lc_ai_desc_stripe.sv
  verif/tb/ai_island/run-desc-stripe.sh
  verif/tb/ai_island/tb_g6lc_ai_desc_island.sv
  verif/tb/ai_island/run-desc-island.sh
  verif/tb/ai_island/tb_g6lc_ai_store_align.sv
  verif/tb/ai_island/run-store-align.sh
  verif/tb/ai_island/tb_g6lc_ai_dram_backend_stripe.sv
  verif/tb/ai_island/run-dram-backend-stripe.sh
  verif/tb/ai_island/tb_g6lc_ai_dram_channels.sv
  verif/tb/ai_island/run-dram-channels.sh
  verif/tb/ai_island/tb_g6lc_ai_gemm_stripe.sv
  verif/tb/ai_island/run-gemm-stripe.sh
  verif/tb/ai_island/tb_g6lc_ai_gemm_backend.sv
  verif/tb/ai_island/run-gemm-backend.sh
  verif/tb/ai_island/run-gemm-panel-reuse.sh
  verif/tb/ai_island/tb_g6lc_ai_desc_reuse.sv
  verif/tb/ai_island/run-desc-reuse.sh
  verif/tb/ai_island/run-gemm-backend-class1.sh
  verif/tb/ai_island/tb_g6lc_ai_gemm_channels.sv
  verif/tb/ai_island/run-gemm-channels.sh
  verif/tb/ai_island/tb_g6lc_ai_cap_occupancy.sv
  verif/tb/ai_island/run-cap-occupancy.sh
  verif/tests/testlist_ai_matrix.yaml
  verif/tests/custom/ai/ai_gemm_tile_2x2_smoke.S
  verif/tests/custom/ai/ai_dual_core_stripe_smoke.S
  verif/regress/remote/ai-dual-core-stripe.sh
  verif/tests/custom/ai/ai_nch_occupancy_smoke.S
  verif/regress/remote/ai-nch-occupancy.sh
  verif/tests/custom/ai/ai_class1_amo_lrsc_smoke.S
  verif/regress/remote/ai-class1-amo-lrsc.sh
  verif/tests/custom/ai/ai_dual_core_excl_smoke.S
  verif/regress/remote/ai-dual-core-excl.sh
  verif/tests/custom/ai/ai_dual_core_lrsc_disjoint_smoke.S
  verif/regress/remote/ai-dual-core-lrsc-disjoint.sh
  verif/tests/custom/ai/ai_numfmt_grant_smoke.S
  verif/regress/remote/ai-numfmt-grant.sh
  verif/tb/ai_island/tb_g6lc_ai_dram_timing.sv
  verif/tb/ai_island/run-dram-timing.sh
  corev_apu/ai_island/generated/README.md
  architecture/ai-matrix/isa-encoding.md
)
for f in "${need[@]}"; do
  if [[ -f "$f" ]]; then ok "present $f"
  else bad "missing $f"; fi
done

pkg=core/include/g6lc64_ai_config_pkg.sv
grep -q "CVA6ConfigCvxifEn = 1" "$pkg" && ok "CvxifEn=1" || bad "CvxifEn"
grep -q "COPRO_G6LC_AI" "$pkg" && ok "COPRO_G6LC_AI" || bad "CoproType"
grep -q "MatrixEn: bit'(1)" "$pkg" && ok "MatrixEn=1" || bad "MatrixEn"
grep -q "CVA6ConfigVExtEn = 0" "$pkg" && ok "VExtEn=0 (seam B)" || bad "VExtEn must be 0"

# CSR address constants must avoid FTRAN
grep -q "CSR_AICFG.*=.*12'h801" core/cvxif_g6lc_ai/include/g6lc_ai_instr_pkg.sv \
  && ok "aicfg @ 0x801 (not FTRAN 0x800)" || bad "aicfg address"

cfg=corev_apu/include/g6lc_ai_island_cfg_pkg.sv
grep -q "AI_DRAM_DDR4" "$cfg" && ok "DramClass DDR4 named" || bad "AI_DRAM_DDR4"
grep -q "AiIslandDdr4Bringup" "$cfg" && ok "DDR4 bringup package (not live)" || bad "AiIslandDdr4Bringup"
grep -q "AiIslandDdr4x2Bringup" "$cfg" && ok "DDR4 2-channel bringup (38 GB/s)" || bad "AiIslandDdr4x2Bringup"
grep -q "AiIslandDdr4x4Bringup" "$cfg" && ok "DDR4 4-channel bringup (76 GB/s)" || bad "AiIslandDdr4x4Bringup"
grep -q "AiIslandDdr4x8Bringup" "$cfg" && ok "DDR4 8-channel bringup (152 GB/s)" || bad "AiIslandDdr4x8Bringup"
grep -q "G6LC_AI_DRAM_CHANS_8" corev_apu/tb/ariane_testharness.sv \
  && ok "testharness class-1 8ch LiteDRAM (default off)" || bad "G6LC_AI_DRAM_CHANS_8"
grep -q "G6LC_AI_DRAM_CHANS_4" corev_apu/tb/ariane_testharness.sv \
  && ok "testharness class-1 4ch LiteDRAM (default off)" || bad "G6LC_AI_DRAM_CHANS_4"
grep -q "AiIslandSimChans2" "$cfg" && ok "class-0 2-channel SRAM stripe" || bad "AiIslandSimChans2"
grep -q "AiIslandSimChans4" "$cfg" && ok "class-0 4-channel SRAM stripe" || bad "AiIslandSimChans4"
grep -q "AiIslandSimChans8" "$cfg" && ok "class-0 8-channel SRAM stripe" || bad "AiIslandSimChans8"
grep -q "G6LC_AI_DRAM_SIM_CHANS_4" corev_apu/tb/ariane_testharness.sv \
  && ok "testharness class-0 4ch SRAM (default off)" || bad "G6LC_AI_DRAM_SIM_CHANS_4"
grep -q "G6LC_AI_DRAM_SIM_CHANS_8" corev_apu/tb/ariane_testharness.sv \
  && ok "testharness class-0 8ch SRAM (default off)" || bad "G6LC_AI_DRAM_SIM_CHANS_8"
grep -q "ch_r_beats_o" corev_apu/src/g6lc_ai_dram_backend.sv \
  && ok "SoC DRAM occupancy ports" || bad "ch_r_beats_o"
grep -q "dram_burst_fits_stripe" "$cfg" && ok "stripe burst helper" || bad "dram_burst_fits_stripe"
grep -q "class 0 must refuse 400" verif/tb/ai_island/tb_g6lc_ai_dram_stripe.sv \
  && ok "nameplate guard refuses 400 on class 0/1" || bad "stripe 400 guard"
grep -q "ddr4_nameplate_gbps" "$cfg" && ok "nameplate scales with channels" || bad "ddr4_nameplate_gbps"
grep -q "AI_DRAM_MAX_CHANNELS" "$cfg" && ok "max DRAM channels named" || bad "AI_DRAM_MAX_CHANNELS"
grep -q "CAP_OFF_MAX_AR_OUT" "$cfg" && ok "CAP MaxAROut" || bad "CAP_OFF_MAX_AR_OUT"
grep -q "DramClass:    unsigned'(AI_DRAM_SIM_AXI)" "$cfg" \
  && ok "live DramClass=0" || bad "live must stay class 0"
grep -q "DramCas:      unsigned'(0)" "$cfg" && ok "live DramCas=0 bypass" || bad "live Cas must be 0"
grep -q "CAP_OFF_DRAM_TIMING" "$cfg" && ok "CAP DRAM timing" || bad "CAP_OFF_DRAM_TIMING"
grep -q "AiIslandDdr4TimingSim" "$cfg" && ok "class-0 DDR4 timing sim SKU" || bad "AiIslandDdr4TimingSim"
grep -q "G6LC_AI_DRAM_TIMING" corev_apu/tb/ariane_testharness.sv \
  && ok "testharness timing define (default off)" || bad "G6LC_AI_DRAM_TIMING"

# AI-X1: the exclusive monitor must hold one reservation PER HART. A single
# global reservation livelocks two harts on disjoint addresses, and the
# same-address snoop gate cannot see it. Both the table and the bisection seam
# that proves the gate can fail are load-bearing.
grep -q "NRes" corev_apu/src/g6lc_axi_lrsc.sv \
  && ok "lrsc reservation table (not one global)" || bad "g6lc_axi_lrsc NRes"
grep -q "NRes" corev_apu/src/g6lc_axi_atomics_wrap.sv \
  && ok "atomics wrap forwards NRes" || bad "g6lc_axi_atomics_wrap NRes"
grep -q "G6LC_AI_LRSC_SINGLE_RES" corev_apu/tb/ariane_testharness.sv \
  && ok "single-reservation negative control seam kept" || bad "G6LC_AI_LRSC_SINGLE_RES"
grep -q "NR_HARTS" corev_apu/tb/ariane_testharness.sv \
  && ok "NRes sized from hart count" || bad "NRes must come from NR_HARTS"

# AI-X2: numeric formats are ONE bitmap over ONE enumeration, and an ungranted
# format must fail closed rather than be demoted to INT8.
grep -q "AI_FMT_BF16" core/include/config_pkg.sv \
  && ok "numeric format enumeration in config_pkg" || bad "config_pkg AI_FMT_*"
grep -q "FormatMask" core/include/config_pkg.sv \
  && ok "ai_cfg_t.FormatMask grant bitmap" || bad "ai_cfg_t.FormatMask"
grep -q "FormatMask: config_pkg::AiFmtMaskInt8" core/include/g6lc64_ai_config_pkg.sv \
  && ok "live grant stays dense INT8 (PE is s8xs8->s32)" || bad "live FormatMask"
grep -q "ST_BAD_FMT" corev_apu/ai_island/include/g6lc_ai_desc_pkg.sv \
  && ok "ST_BAD_FMT distinct from ST_BAD_OP" || bad "ST_BAD_FMT"
grep -q "FLAG_NUMFMT_SHIFT" corev_apu/ai_island/include/g6lc_ai_desc_pkg.sv \
  && ok "descriptor numfmt field" || bad "FLAG_NUMFMT_SHIFT"
grep -q "desc_numfmt_granted" corev_apu/ai_island/g6lc_ai_desc_engine.sv \
  && ok "engine refuses ungranted format in PARSE" || bad "engine must check numfmt"
grep -q "G6LC_AI_DRAM_SIM_CHANS_2" corev_apu/tb/ariane_testharness.sv \
  && ok "testharness class-0 2ch SRAM stripe (default off)" || bad "G6LC_AI_DRAM_SIM_CHANS_2"
grep -B1 'G6LC_AI_EXCL_MULTI' corev_apu/tb/ariane_testharness.sv | grep -q 'G6LC_AI_DRAM_SIM_CHANS_2' \
  && ok "SIM_CHANS uses g6lc exclusive wrap (not pulp 1-OT)" || bad "SIM_CHANS EXCL_MULTI"
grep -q "DRAM_EXCL_AW" corev_apu/tb/ariane_testharness.sv \
  && ok "g6lc wrap AW slots not cookie dram_aw_out=1" || bad "DRAM_EXCL_AW"
grep -q "cap_beats_to_stripe" corev_apu/ai_island/g6lc_ai_gemm_seq.sv \
  && ok "GEMM burst capped to stripe when N>1" || bad "cap_beats_to_stripe"
grep -q "SplitArId" corev_apu/ai_island/g6lc_ai_gemm_seq.sv \
  && ok "GEMM N>1 split outstanding AR IDs" || bad "SplitArId"
grep -q "phy2_addr" verif/tb/ai_island/tb_g6lc_ai_dram_channels.sv \
  && ok "class-1 two IDs per PHY (N=2/4)" || bad "phy2_addr"
grep -q 'build_nch 1' verif/tb/ai_island/run-dram-channels.sh \
  && ok "class-1 PHY N=1 identity" || bad "dram_channels n1"
grep -q "g6lc_ai_cap_window" verif/tb/ai_island/tb_g6lc_ai_gemm_channels.sv \
  && ok "class-1 GEMM CAP occupancy window" || bad "gemm_channels cap_window"
grep -q "GATE_MILLI" verif/tb/ai_island/tb_g6lc_ai_dram_bw.sv \
  && ok "class-1 --sim stream BW TB" || bad "dram_bw GATE_MILLI"
grep -q 'build_nch 1' verif/tb/ai_island/run-gemm-channels.sh \
  && ok "class-1 GEMM N=1 LiteDRAM identity" || bad "gemm_channels n1"
# The N sweep is a DEFAULT_NCHS loop (nch-from-env.inc.sh), not unrolled
# `build_nch <n>` calls, so assert the list that actually drives it.
grep -Eq 'DEFAULT_NCHS=\(1 2 4 8\)' verif/tb/ai_island/run-gemm-channels.sh \
  && ok "class-1 GEMM N=4 LiteDRAM" || bad "gemm_channels n4"
grep -Eq 'DEFAULT_NCHS=\(1 2 4 8\)' verif/tb/ai_island/run-gemm-channels.sh \
  && ok "class-1 GEMM N=8 LiteDRAM" || bad "gemm_channels n8"
grep -q 'run_wide' verif/tb/ai_island/tb_g6lc_ai_gemm_backend.sv \
  && ok "class-0 GEMM wide lda=64 occupancy" || bad "gemm_backend run_wide"
grep -q 'DRAM_CLASS' verif/tb/ai_island/tb_g6lc_ai_gemm_backend.sv \
  && ok "GEMM backend DramClass parameter (CLASS1 slave)" || bad "gemm_backend DRAM_CLASS"
grep -q 'GDRAM_CLASS=1' verif/tb/ai_island/run-gemm-backend-class1.sh \
  && ok "class-1 GEMM via dram_backend (testharness CLASS1)" || bad "gemm_backend class1"
grep -Eq 'DEFAULT_NCHS=\(1 2 4 8\)' verif/tb/ai_island/run-gemm-backend-class1.sh \
  && ok "class-1 backend GEMM N=4 (CHANS_4 slave)" || bad "gemm_backend class1 n4"
grep -Eq 'DEFAULT_NCHS=\(1 2 4 8\)' verif/tb/ai_island/run-gemm-backend-class1.sh \
  && ok "class-1 backend GEMM N=8 (CHANS_8 slave)" || bad "gemm_backend class1 n8"
grep -q 'user_port_native_0' corev_apu/src/g6lc_ai_litedram_wrap.sv \
  && ok "wrap native user port" || bad "user_port_native_0"
grep -q "aw_size <= 3'd3" corev_apu/src/g6lc_ai_litedram_wrap.sv \
  && ok "wrap accepts core WT size 0-3" || bad "wrap aw_size"
grep -q 'w0err' corev_apu/src/g6lc_ai_litedram_wrap.sv \
  && ok "wrap SLVERR illegal burst (no aw_ready stall)" || bad "wrap w0err"
grep -q '3344_2211' verif/tb/ai_island/tb_g6lc_ai_litedram_wrap.sv \
  && ok "wrap ST.H +2 merge" || bad "wrap ST.H"
grep -q 'wr_bad_burst' verif/tb/ai_island/tb_g6lc_ai_litedram_wrap.sv \
  && ok "wrap multi-beat WRAP SLVERR" || bad "wrap WRAP SLVERR"
grep -q 'wr_nbeats' verif/tb/ai_island/tb_g6lc_ai_litedram_wrap.sv \
  && ok "wrap L1 16 B INCR fill" || bad "wrap wr_nbeats"
grep -q '9988_7766_EEFF_0011' verif/tb/ai_island/tb_g6lc_ai_litedram_wrap.sv \
  && ok "wrap ST.W +4 merge" || bad "wrap ST.W +4"
grep -q 'rd_sz' verif/tb/ai_island/tb_g6lc_ai_litedram_wrap.sv \
  && ok "wrap NC AR size 0/1/2" || bad "wrap rd_sz"
grep -q 'R-while-B' verif/tb/ai_island/tb_g6lc_ai_litedram_wrap.sv \
  && ok "wrap AR while B outstanding" || bad "wrap R-while-B"
grep -q 'collect_r_nbeats_pair' verif/tb/ai_island/tb_g6lc_ai_litedram_wrap.sv \
  && ok "wrap two outstanding AR (I$+D$ / L2 MSHR)" || bad "wrap dual AR"
grep -q "8'd7" verif/tb/ai_island/tb_g6lc_ai_litedram_wrap.sv \
  && ok "wrap two 64 B AR (L2 two-MSHR)" || bad "wrap 64B dual AR"
grep -q '3rd AR ready with both slots live' verif/tb/ai_island/tb_g6lc_ai_litedram_wrap.sv \
  && ok "wrap 3rd AR backpressure" || bad "wrap 3rd AR"
grep -q 'timeout mixed AR' verif/tb/ai_island/tb_g6lc_ai_litedram_wrap.sv \
  && ok "wrap mixed AW+AR two IDs" || bad "wrap mixed AW AR"
grep -q 'ai-dt' verif/regress/remote/testharness_proxy.py \
  && ok "proxy AI flavour ai-dt (MaxAROut=8)" || bad "proxy ai-dt"
grep -q 'ai-d4' verif/regress/remote/testharness_proxy.py \
  && ok "proxy AI flavour ai-d4 (CLASS1 N=4)" || bad "proxy ai-d4"
grep -q '"ai"' build-platform/src/config/schema.ts \
  && ok "diag compartment ai in schema" || bad "schema DiagnosticCompartment ai"
grep -q -- '--ai-remote' build-platform/src/cli/commands/test.ts \
  && ok "test --ai-remote CLI" || bad "test --ai-remote"
grep -q -- '--ai-qemu' build-platform/src/cli/commands/test.ts \
  && ok "test --ai-qemu CLI" || bad "test --ai-qemu"
grep -q 'ai-dram-stripe' build-platform/src/config/defaults.ts \
  && ok "suite ai-dram-stripe (class-0 N>1)" || bad "ai-dram-stripe suite"
grep -q 'nch-from-env.inc.sh' verif/tb/ai_island/run-dram-channels.sh \
  && ok "channels TB honors AI_ISLAND_DRAM_CHANNELS" || bad "nch-from-env channels"
grep -q 'g6lc_dram_peek64' corev_apu/tb/ariane_tb.cpp \
  && ok "ariane_tb.cpp DPI stub g6lc_dram_peek64 (AI testharness link)" || bad "peek64 stub"
grep -q 'ai_s4_mshr_xbar_smoke' verif/regress/remote/s4-mshr-xbar.sh \
  && ok "S4 remote testharness xbar×MSHR×MaxAROut" || bad "s4-mshr-xbar.sh"
grep -q 'S4_LINE_BASE' verif/tests/custom/ai/ai_s4_mshr_xbar_smoke.S \
  && ok "S4 ELF 8 L2-line loads + 8x8 GEMM" || bad "ai_s4_mshr_xbar_smoke"
grep -q 'LINE1' verif/tests/custom/ai/ai_dual_core_stripe_smoke.S \
  && ok "dual-core stripe ELF (NrCores=2, CAP 0x38 N>=2)" || bad "ai_dual_core_stripe_smoke"
grep -q 'CAP_CH1_W' verif/tests/custom/ai/ai_dual_core_stripe_smoke.S \
  && ok "dual-core S5 occupancy CAP 0x70/0x74" || bad "dual-core occupancy"
grep -q 'G6LC_CHSRAM' corev_apu/tb/ariane_tb.cpp \
  && ok "class-0 N>1 stripe SRAM preload (ai-sc*)" || bad "sim-stripe preload"
grep -q 's4_park' verif/tests/custom/ai/ai_s4_mshr_xbar_smoke.S \
  && ok "S4 parks hart 1 (dual-core is separate ELF)" || bad "S4 hart1 park"
grep -q 'nch_park' verif/tests/custom/ai/ai_nch_occupancy_smoke.S \
  && ok "all-N occupancy ELF (CAP 0x38 N, 0x70+4*i)" || bad "ai_nch_occupancy_smoke"
grep -q 'ai_nch_occupancy_smoke' verif/regress/remote/ai-nch-occupancy.sh \
  && ok "all-N occupancy remote (default ai-d8)" || bad "ai-nch-occupancy.sh"
grep -q 'amoadd.d' verif/tests/custom/ai/ai_class1_amo_lrsc_smoke.S \
  && ok "CLASS1 exclusive ELF (amoadd.d + lr.d/sc.d)" || bad "ai_class1_amo_lrsc_smoke"
grep -q 'ai_class1_amo_lrsc_smoke' verif/regress/remote/ai-class1-amo-lrsc.sh \
  && ok "CLASS1 exclusive remote (default ai-dt)" || bad "ai-class1-amo-lrsc.sh"
grep -q 'COOKIE1' verif/tests/custom/ai/ai_dual_core_excl_smoke.S \
  && ok "dual-core exclusive snoop ELF (hart1 store kills sc.d)" || bad "ai_dual_core_excl_smoke"
grep -q 'ai_dual_core_excl_smoke' verif/regress/remote/ai-dual-core-excl.sh \
  && ok "dual-core exclusive remote (default ai-dt)" || bad "ai-dual-core-excl.sh"
grep -q 'AI_ISLAND_DRAM_CHANS_2' verif/regress/ai-matrix-veri.sh \
  && ok "Variane opt-in CHANS_2 → work-ver-ai-d2" || bad "veri CHANS_2"
grep -q 'AI_ISLAND_DRAM_CHANS_8' verif/regress/ai-matrix-veri.sh \
  && ok "Variane opt-in CHANS_8 → work-ver-ai-d8" || bad "veri CHANS_8"
grep -q 'g6lc_ai_dram_channels.sv' Makefile \
  && ok "testharness flist has dram_channels" || bad "Makefile dram_channels"
grep -q 'run_wide' verif/tb/ai_island/tb_g6lc_ai_gemm_channels.sv \
  && ok "class-1 GEMM wide lda=64 occupancy" || bad "gemm_channels run_wide"
grep -q "64'h8000_0038" verif/tb/ai_island/tb_g6lc_ai_gemm_stripe.sv \
  && ok "GEMM stripe TB starts A on a stripe edge" || bad "gemm stripe A ptr"
grep -q "CAP_OFF_DRAM_CH_R" corev_apu/include/g6lc_ai_island_cfg_pkg.sv \
  && ok "CAP occupancy offsets 0x50/0x70" || bad "CAP_OFF_DRAM_CH_R"
grep -q "CAP_OFF_DRAM_CHANS" verif/tb/ai_island/tb_g6lc_ai_cap_occupancy.sv \
  && ok "CAP 0x38 DTS channels/shift decode" || bad "cap occupancy 0x38"
grep -q "g6lc,dram-channels" corev_apu/bootrom/ariane-ai.dts \
  && ok "DTS one memory@ + dram-channels" || bad "ariane-ai dram-channels"
grep -q "ch_r_beats_i" corev_apu/tb/ariane_testharness.sv \
  && ok "testharness occupancy wired into island CAP" || bad "testharness ch_r_beats_i"
grep -q "gen_sim_stripe" corev_apu/src/g6lc_ai_dram_backend.sv \
  && ok "class-0 N>1 striped SRAM" || bad "gen_sim_stripe"
grep -q "n_r_ready   = 1'b1" corev_apu/src/g6lc_ai_litedram_wrap.sv \
  && ok "wrap always accepts native rdata (no ID; --sim pulse)" || bad "n_r_ready"
grep -q "UNIQUE_IDS" corev_apu/src/g6lc_ai_dram_backend.sv \
  && ok "stripe demux UNIQUE_IDS (same-ID may retarget channel)" || bad "UNIQUE_IDS"
grep -q "CAP_OFF_DRAM_STATUS" "$cfg" && ok "CAP DRAM status" || bad "CAP_OFF_DRAM_STATUS"
grep -q 'id: "litedram"' build-platform/src/config/defaults.ts \
  && grep -q "enabled: false" build-platform/src/config/defaults.ts \
  && ok "litedram catalog enabled:false" || bad "do not auto-fetch litedram"
if [[ -d vendor/litex/litedram/litedram ]]; then
  ok "litedram submodule checkout"
else
  skip "litedram checkout absent"
fi
if [[ -f corev_apu/ai_island/generated/gateware/litedram_core.v ]]; then
  grep -q "module litedram_core" corev_apu/ai_island/generated/gateware/litedram_core.v \
    && ok "generated litedram_core.v" || bad "litedram_core.v missing module"
else
  skip "litedram_core.v not generated"
fi

COMMON="$ROOT/verif/tests/custom/common"
LD="$COMMON/link_verilator.ld"
RISCV_CC="${RISCV_CC:-}"
if [[ -z "$RISCV_CC" ]]; then
  for p in riscv-none-elf-gcc riscv64-unknown-elf-gcc; do
    if command -v "$p" >/dev/null 2>&1; then RISCV_CC="$p"; break; fi
  done
fi

if [[ -z "$RISCV_CC" ]]; then
  if [[ "$REQUIRE_COMPILE" = "1" ]]; then
    bad "no RISC-V gcc (AI_MATRIX_REQUIRE_COMPILE=1)"
  else
    skip "no RISC-V gcc — ELF compile skipped"
  fi
else
  for t in ai_csr_aistatus_xs ai_dot4_s8_smoke ai_mma_s8_golden ai_requant_rhe_golden; do
    src="verif/tests/custom/ai/${t}.S"
    elf="$OUT/${t}.elf"
    if "$RISCV_CC" -march=rv64imafdc -mabi=lp64d -static -mcmodel=medany \
        -fvisibility=hidden -nostdlib -nostartfiles \
        -T"$LD" -I"$COMMON" -o "$elf" "$src" 2>"$OUT/${t}.cc.err"; then
      ok "compile $t → $elf"
    else
      bad "compile $t (see $OUT/${t}.cc.err)"
    fi
  done
fi

if command -v verilator >/dev/null 2>&1; then
  if bash verif/tb/ai_island/run-dram-timing.sh; then
    ok "tb_g6lc_ai_dram_timing (page hit/miss)"
  else
    bad "tb_g6lc_ai_dram_timing"
  fi
  if bash verif/tb/ai_island/run-dram-stripe.sh; then
    ok "tb_g6lc_ai_dram_stripe (core/L2 vs GEMM stripe)"
  else
    bad "tb_g6lc_ai_dram_stripe"
  fi
  if bash verif/tb/ai_island/run-litedram-wrap.sh; then
    ok "tb_g6lc_ai_litedram_wrap (class-1 id6 cluster+island+L2 line)"
  else
    bad "tb_g6lc_ai_litedram_wrap"
  fi
  if bash verif/tb/ai_island/run-dram-join.sh; then
    ok "tb_g6lc_ai_dram_join (second ingress, define unset on the SoC path)"
  else
    bad "tb_g6lc_ai_dram_join"
  fi
  # V1 wide channel: 512-bit channel + island port, 64-bit cluster port upsized
  # (cluster and island round-trips, fetch-shaped lane read, island narrow write
  # landing at its lane without clobbering the word).
  if bash verif/tb/ai_island/run-dram-join-wide.sh; then
    ok "tb_g6lc_ai_dram_join_wide (V1 wide channel: join + 512-bit class-0 slave)"
  else
    bad "tb_g6lc_ai_dram_join_wide"
  fi
  # V3/V4: N engines behind one job interface and one AXI master, N-split of the C
  # panel (per-slice ldc); 2- and 4-cluster C equals the single engine's, faster.
  if bash verif/tb/ai_island/run-cluster-dispatch.sh; then
    ok "tb_g6lc_ai_cluster_dispatch (V3/V4 N-split dispatch, golden = single engine)"
  else
    bad "tb_g6lc_ai_cluster_dispatch"
  fi
  # The island top elaborates Clusters = 1 / 2 / 4 (dispatch inside the island).
  if bash verif/tb/ai_island/run-island-clusters-lint.sh; then
    ok "g6lc_ai_island_top Clusters 1/2/4 elaborate (reduced geometry)"
  else
    bad "run-island-clusters-lint"
  fi
  if bash verif/tb/ai_island/run-dram-class2.sh; then
    ok "tb_g6lc_ai_dram_class2 (LPDDR5 refuses elaboration)"
  else
    bad "tb_g6lc_ai_dram_class2"
  fi
  if bash verif/tb/ai_island/run-gemm-wide.sh; then
    ok "tb_g6lc_ai_gemm_wide (128/512 GEMM through the join)"
  else
    bad "tb_g6lc_ai_gemm_wide"
  fi
  if bash verif/tb/ai_island/run-island-wide.sh; then
    ok "tb_g6lc_ai_island_wide (256-MAC island, 512-bit DMA)"
  else
    bad "tb_g6lc_ai_island_wide"
  fi
  if bash verif/tb/ai_island/run-desc-stripe.sh; then
    ok "tb_g6lc_ai_desc_stripe (64 B descriptor refuses a stripe cross)"
  else
    bad "tb_g6lc_ai_desc_stripe"
  fi
  if bash verif/tb/ai_island/run-desc-island.sh; then
    ok "tb_g6lc_ai_desc_island (N=2 completion for a stripe-crossing descriptor)"
  else
    bad "tb_g6lc_ai_desc_island"
  fi
  if bash verif/tb/ai_island/run-store-align.sh; then
    ok "tb_g6lc_ai_store_align (completion word alignment)"
  else
    bad "tb_g6lc_ai_store_align"
  fi
  if bash verif/tb/ai_island/run-dram-bw.sh; then
    ok "tb_g6lc_ai_dram_bw (class-1 --sim stream measure; 80% still Variane)"
  else
    bad "tb_g6lc_ai_dram_bw"
  fi
  if bash verif/tb/ai_island/run-dram-backend-stripe.sh; then
    ok "tb_g6lc_ai_dram_backend_stripe (class-0 N=2/4/8 SRAM image)"
  else
    bad "tb_g6lc_ai_dram_backend_stripe"
  fi
  if bash verif/tb/ai_island/run-dram-channels.sh; then
    ok "tb_g6lc_ai_dram_channels (class-1 N=1/2/4/8 LiteDRAM stripe)"
  else
    bad "tb_g6lc_ai_dram_channels"
  fi
  if bash verif/tb/ai_island/run-gemm-stripe.sh; then
    ok "tb_g6lc_ai_gemm_stripe (N=1 identity + N=2 stripe)"
  else
    bad "tb_g6lc_ai_gemm_stripe"
  fi
  if bash verif/tb/ai_island/run-gemm-backend.sh; then
    ok "tb_g6lc_ai_gemm_backend (N=1/2/4/8 golden C + CAP + wide occupancy)"
  else
    bad "tb_g6lc_ai_gemm_backend"
  fi
  if bash verif/tb/ai_island/run-gemm-panel-reuse.sh; then
    ok "tb_g6lc_ai_gemm_backend panel keys (reuse, epoch, and C overlap; not the live package)"
  else
    bad "tb_g6lc_ai_gemm_backend panel keys"
  fi
  if bash verif/tb/ai_island/run-desc-reuse.sh; then
    ok "tb_g6lc_ai_desc_reuse (flags, pointers, stride, format, SLVERR, odd n; VaTurboEn on that instance only)"
  else
    bad "tb_g6lc_ai_desc_reuse"
  fi
  if bash verif/tb/ai_island/run-gemm-backend-class1.sh; then
    ok "tb_g6lc_ai_gemm_backend class1 (testharness CLASS1/CHANS N=1/2/4 native wrap)"
  else
    bad "tb_g6lc_ai_gemm_backend class1"
  fi
  if bash verif/tb/ai_island/run-gemm-channels.sh; then
    ok "tb_g6lc_ai_gemm_channels (golden C vs class-1 N=1/2/4/8 LiteDRAM + CAP + wide)"
  else
    bad "tb_g6lc_ai_gemm_channels"
  fi
  if bash verif/tb/ai_island/run-cap-occupancy.sh; then
    ok "tb_g6lc_ai_cap_occupancy (S5 CAP 0x50/0x70)"
  else
    bad "tb_g6lc_ai_cap_occupancy"
  fi
else
  skip "no verilator — dram-timing/stripe/wrap TB skipped"
fi

if [[ "$LIVE_RTL" = "1" ]]; then
  skip "LIVE_RTL path not automated yet — run manually under g6lc64_ai Variane"
else
  skip "LIVE_RTL=0 (set AI_MATRIX_LIVE_RTL=1 for lab sim)"
fi

log "RESULT pass=$PASS fail=$FAIL skip=$SKIP"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
