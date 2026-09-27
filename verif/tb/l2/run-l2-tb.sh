#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Standalone leaf testbench for the memory-side L2 (g6lc_l2_top).
# Not part of default verify — run directly:
#   bash verif/tb/l2/run-l2-tb.sh
#
# Knobs (env):
#   L2TB_OUT=<dir>          output dir (default /tmp/g6lc-l2-tb)
#   L2TB_BYTE_SIZE=4096     cache size
#   L2TB_SET_ASSOC=4        ways
#   L2TB_MEM_LATENCY=6      memory first-beat delay (cycles)
#   L2TB_STALL_EVERY=0      drop 1-in-N memory beats
#   L2TB_SEED=0x600df00d    data-model + lfsr seed
#   L2TB_EXTRA=-Gname=val   extra -G overrides
#   L2TB_MODE=sim|config|synth|equiv|units
#   L2TB_EQ_MEM=map|collect|bbox
#     auto: map if BYTE_SIZE<=512 else collect
#     bbox: blackbox tag/data/mshr — controller/port proof, geometry-independent
#   L2TB_EQ_LADDER=1        512B mapped + 4KiB/16KiB bbox + 4KiB collect
#   L2TB_EQ_PROD=1          also 256 KiB/8-way bbox (opt-in)
#   L2TB_EQ_TIMEOUT=seconds per-proof budget (map 120, collect 300, bbox 60)
#   L2TB_EQ_TAGS=1          flop-vs-SRAM cycle-exactness: dual sim builds
#     (TAG_SRAM=0/1), byte-identical per-cycle EQSIG streams = PASS;
#     back-inval stimulus suppressed (+eq_run). L2TB_EQ_NEGATIVE=1 must
#     produce a divergence (mutation control).
#   L2TB_WRITE_UPDATE=1     enable the resident-line write merge (T8f);
#     0 must fold to the invalidate-only netlist.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LIVE_ROOT="$ROOT"
OUT_BASE="${L2TB_OUT:-/tmp/g6lc-l2-tb}"
mkdir -p "$OUT_BASE"
OUT="$(mktemp -d "$OUT_BASE/run-XXXXXXXX")"
echo "[l2-tb] isolated run: $OUT"

VERILATOR="${VERILATOR:-verilator}"
if ! command -v "$VERILATOR" >/dev/null 2>&1; then
  for c in /root/tools/verilator-v5.008/bin/verilator \
           /opt/testharness/toolchains/verilator-v5.008/bin/verilator \
           "$ROOT/build-platform/workspace/tooling/linux-eda-suite/bin/verilator_bin"; do
    [ -x "$c" ] && VERILATOR="$c" && break
  done
fi
command -v "$VERILATOR" >/dev/null 2>&1 || { echo "[l2-tb] no verilator" >&2; exit 2; }
"$VERILATOR" --version
ulimit -c 0
warning_args=()
if "$VERILATOR" -Wno-GENUNNAMED --version >/dev/null 2>&1; then warning_args+=(-DL2TB_GENUNNAMED); fi
if "$VERILATOR" -Wno-WIDTHEXPAND --version >/dev/null 2>&1; then warning_args+=(-Wno-WIDTHEXPAND); fi

sources=(
  "$ROOT/vendor/pulp-platform/axi/src/axi_pkg.sv"
  "$ROOT/vendor/pulp-platform/tech_cells_generic/src/rtl/tc_sram.sv"
  "$ROOT/corev_apu/l2_cache/g6lc_l2_pkg.sv"
  "$ROOT/corev_apu/l2_cache/g6lc_l2_tag.sv"
  "$ROOT/corev_apu/l2_cache/g6lc_l2_data.sv"
  "$ROOT/corev_apu/l2_cache/g6lc_l2_mshr.sv"
  "$ROOT/corev_apu/l2_cache/g6lc_l2_top.sv"
  "$ROOT/verif/tb/l2/tb_g6lc_l2.sv"
)
target="${TARGET_CFG:-g6lc64_smt2}"
[[ "$target" =~ ^[a-zA-Z0-9_]+$ ]] || exit 2
inputs=("${sources[@]}" "$ROOT/verif/tb/l2/tb_g6lc_l2.vlt" "$ROOT/verif/tb/l2/run-l2-tb.sh")
if [[ "${L2TB_MODE:-sim}" == units ]]; then
  inputs+=("$ROOT/verif/tb/l2/tb_g6lc_l2_units.sv")
fi
if [[ "${L2TB_MODE:-sim}" == config ]]; then
  inputs+=("$ROOT/core/include/config_pkg.sv" "$ROOT/core/include/${target}_config_pkg.sv" "$ROOT/core/include/build_config_pkg.sv")
fi
sha256sum "${inputs[@]}" > "$OUT/live-sources.sha256"
for source in "${inputs[@]}"; do
  dest="$OUT/source/${source#"$ROOT/"}"
  mkdir -p "$(dirname "$dest")"
  cp -- "$source" "$dest"
  cmp -- "$source" "$dest"
done
sha256sum --check --status "$OUT/live-sources.sha256"
for i in "${!sources[@]}"; do sources[i]="$OUT/source/${sources[i]#"$ROOT/"}"; done
for i in "${!inputs[@]}"; do inputs[i]="$OUT/source/${inputs[i]#"$ROOT/"}"; done
ROOT="$OUT/source"
sha256sum "${inputs[@]}" > "$OUT/sources.sha256"
printf '%q ' "$@" > "$OUT/run.args"
printf '\n' >> "$OUT/run.args"
if [[ "${L2TB_MODE:-sim}" == config ]]; then
  config_action=--binary
  [[ "${L2TB_CONFIG_LINT:-0}" != 1 ]] || config_action=--lint-only
  "$VERILATOR" "$config_action" --assert -Wno-WIDTH -Wno-UNSIGNED \
    -Wno-TIMESCALEMOD -DL2TB_STATIC -DL2TB_CONFIG_TEST \
    "$ROOT/core/include/config_pkg.sv" "$ROOT/core/include/${target}_config_pkg.sv" \
    "$ROOT/core/include/build_config_pkg.sv" "$ROOT/verif/tb/l2/tb_g6lc_l2.sv" \
    --top-module tb_g6lc_l2_config -Mdir "$OUT" -o tb_g6lc_l2_config 2>&1 | tee "$OUT/build.log"
  [[ "$config_action" != --lint-only ]] || exit 0
  "$OUT/tb_g6lc_l2_config" "$@" 2>&1 | tee "$OUT/sim.log"
  exit 0
fi
if [[ "${L2TB_MODE:-sim}" == equiv ]]; then
  if [[ "${L2TB_EQ_TAGS:-0}" == 1 ]]; then
    # Flop-vs-SRAM cycle-exactness check, run as a deterministic dual
    # simulation rather than an equiv_make miter: the two tag stores are
    # unpaired state with different reset/init behaviour (the flop array
    # resets to '0; the tc_sram row contents are don't-care), so the
    # equivalence induction frame admits unreachable states where a valid
    # way's stored tags diverge — the proof cannot close (observed: 503
    # unproven $equiv cells at -seq 2; a miter+sat instance at -seq 16
    # builds ~62M vars / ~170M clauses and does not converge). The claim is
    # therefore discharged by dual run: the same bench is built at
    # TAG_SRAM=0 (gold) and TAG_SRAM=1 (gate), both emit a per-cycle EQSIG
    # line folding every DUT output, and the streams are compared
    # byte-for-byte. +eq_run suppresses the two back-inval injections
    # because the SRAM path's deferred inval-match commit is a permitted
    # timing difference (directed-tested in tb_g6lc_l2_hum). With
    # L2TB_EQ_NEGATIVE=1 the gate build flips its signature hit tap and the
    # diff MUST differ — the mutation control.
    byte_size="${L2TB_BYTE_SIZE:-512}"
    eq_neg="${L2TB_EQ_NEGATIVE:-0}"
    eq_sim_args=(+eq_run +bypass-backpressure +atop-drain +amo-arith "$@")
    for variant in gold gate; do
      if [[ "$variant" == gold ]]; then eq_ts=0; eq_n=0; else eq_ts=1; eq_n="$eq_neg"; fi
      "$VERILATOR" --binary --timing --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
        "${warning_args[@]}" -Wno-BLKSEQ -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-VARHIDDEN \
        -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
        "$ROOT/verif/tb/l2/tb_g6lc_l2.vlt" "${sources[@]}" \
        --top-module tb_g6lc_l2 \
        -GBYTE_SIZE="$byte_size" -GSET_ASSOC="${L2TB_SET_ASSOC:-4}" \
        -GMEM_LATENCY="${L2TB_MEM_LATENCY:-6}" -GSTALL_EVERY="${L2TB_STALL_EVERY:-0}" \
        -GRR_EN="${L2TB_RR_EN:-0}" -GSEED="${L2TB_SEED:-$((0x600df00d))}" \
        -GTAG_SRAM="$eq_ts" -GEQ_NEGATIVE="$eq_n" \
        -GWRITE_UPDATE="${L2TB_WRITE_UPDATE:-0}" \
        -Mdir "$OUT/$variant" -o tb_g6lc_l2 2>&1 | tee "$OUT/build-$variant.log"
      "$OUT/$variant/tb_g6lc_l2" "${eq_sim_args[@]}" 2>&1 | tee "$OUT/sim-$variant.log" || true
      grep -qFx '[L2TB] RESULT pass' "$OUT/sim-$variant.log" || { echo "[l2-tb] TAG-EQUIV sim FAIL variant=$variant — $OUT/sim-$variant.log"; exit 1; }
      grep -cE '^EQSIG [0-9]+ ' "$OUT/sim-$variant.log" > "$OUT/eqsig-$variant.count" || true
      grep -E '^EQSIG [0-9]+ ' "$OUT/sim-$variant.log" > "$OUT/eqsig-$variant.txt"
      [[ -s "$OUT/eqsig-$variant.txt" ]] || { echo "[l2-tb] TAG-EQUIV no signatures variant=$variant"; exit 1; }
    done
    sha256sum --check --status "$OUT/sources.sha256"
    if [[ "$eq_neg" == 1 ]]; then
      if cmp -s "$OUT/eqsig-gold.txt" "$OUT/eqsig-gate.txt"; then
        echo "[l2-tb] TAG-EQUIV NEGATIVE did not diverge — mutation control broken" >&2
        exit 1
      fi
      echo "[l2-tb] TAG-EQUIV NEGATIVE PASS (expected divergence observed) bytes=$byte_size"
      exit 0
    fi
    if ! cmp -s "$OUT/eqsig-gold.txt" "$OUT/eqsig-gate.txt"; then
      diff -u "$OUT/eqsig-gold.txt" "$OUT/eqsig-gate.txt" | head -30 >&2
      echo "[l2-tb] TAG-EQUIV FAIL bytes=$byte_size ways=${L2TB_SET_ASSOC:-4} — $OUT" >&2
      exit 1
    fi
    echo "[l2-tb] TAG-EQUIV PASS bytes=$byte_size ways=${L2TB_SET_ASSOC:-4} cycles=$(cat "$OUT/eqsig-gold.count") — $OUT"
    exit 0
  fi
  if [[ "${L2TB_EQ_LADDER:-0}" == 1 ]]; then
    ladder_fail=0
    while IFS=: read -r spec_size spec_ways spec_mem spec_timeout; do
      [[ -n "$spec_size" ]] || continue
      echo "[l2-tb] ladder $spec_size B ways=$spec_ways mem=$spec_mem timeout=${spec_timeout}s"
      if ! L2TB_MODE=equiv L2TB_EQ_LADDER=0 L2TB_BYTE_SIZE="$spec_size" \
           L2TB_SET_ASSOC="$spec_ways" L2TB_EQ_MEM="$spec_mem" \
           L2TB_EQ_TIMEOUT="$spec_timeout" L2TB_OUT="$OUT_BASE" \
           L2TB_EQ_NEGATIVE="${L2TB_EQ_NEGATIVE:-0}" \
           bash "$LIVE_ROOT/verif/tb/l2/run-l2-tb.sh"; then
        echo "[l2-tb] LADDER FAIL geometry=${spec_size}B/${spec_ways}way mem=$spec_mem" >&2
        ladder_fail=1
      fi
    done <<'LADDER'
512:4:map:120
1024:4:map:120
2048:4:map:180
4096:4:bbox:60
16384:4:bbox:60
LADDER
    if [[ "${L2TB_EQ_PROD:-0}" == 1 ]]; then
      echo "[l2-tb] ladder production-geometry 262144 B bbox"
      L2TB_MODE=equiv L2TB_EQ_LADDER=0 L2TB_BYTE_SIZE=262144 L2TB_SET_ASSOC=8 \
        L2TB_EQ_MEM=bbox L2TB_EQ_TIMEOUT="${L2TB_EQ_PROD_TIMEOUT:-120}" \
        L2TB_OUT="$OUT_BASE" bash "$LIVE_ROOT/verif/tb/l2/run-l2-tb.sh" || ladder_fail=1
    fi
    [[ "$ladder_fail" == 0 ]] || { echo "[l2-tb] LADDER FAIL — $OUT"; exit 1; }
    echo "[l2-tb] LADDER PASS — $OUT"
    exit 0
  fi
  base="${L2TB_EQ_BASE_BLOB:-5be075b1a01ff754da384c3dd129fd58c33733fa}"
  [[ "$base" =~ ^[0-9a-f]{40}$ ]] || exit 2
  [[ "${L2TB_EQ_NEGATIVE:-0}" =~ ^[01]$ ]] || exit 2
  byte_size="${L2TB_BYTE_SIZE:-512}"
  eq_mem="${L2TB_EQ_MEM:-}"
  if [[ -z "$eq_mem" ]]; then
    if [[ "$byte_size" -le 512 ]]; then eq_mem=map; else eq_mem=collect; fi
  fi
  [[ "$eq_mem" == map || "$eq_mem" == collect || "$eq_mem" == bbox ]] || exit 2
  if [[ -n "${L2TB_EQ_BASE_FILE:-}" ]]; then
    cp -- "$L2TB_EQ_BASE_FILE" "$OUT/legacy.original.sv"
  else
    git -C "$LIVE_ROOT" cat-file blob "$base" > "$OUT/legacy.original.sv"
  fi
  printf '%s\n' "$base" > "$OUT/legacy.blob"
  printf '%s\n' "$eq_mem" > "$OUT/equiv.mem"
  python3 - "$OUT/legacy.original.sv" "$OUT/legacy.corrected.sv" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
old = "      mst_req_o.r_ready = 1'b1;\n      if (mst_resp_i.r_valid && mst_resp_i.r.last) begin"
new = "      if (state_q != S_BYPASS_R) mst_req_o.r_ready = 1'b1;\n      if (mst_resp_i.r_valid && mst_req_o.r_ready && mst_resp_i.r.last) begin"
if text.count(old) != 1 or "RR_EN" in text:
    raise SystemExit("legacy reference is not the expected pre-RR engine")
text = text.replace(old, new)
# Fixture repair, not a waiver: g6lc_l2_mshr grew alloc_meta_i/merge_block_i
# after the reference engine was cut; tie them off so the gold netlist
# elaborates with no undriven ports. The equivalence criterion itself
# (equiv_status -assert) is unchanged.
old2 = "      .alloc_is_write_i  (1'b0),"
new2 = ("      .alloc_meta_i       ('0),\n"
        "      .merge_block_i     ('0),\n"
        "      .alloc_is_write_i  (1'b0),")
if text.count(old2) != 1:
    raise SystemExit("legacy mshr tie-off anchor missing")
pathlib.Path(sys.argv[2]).write_text(text.replace(old2, new2))
PY
  sha256sum "$OUT/legacy.original.sv" "$OUT/legacy.corrected.sv" >> "$OUT/sources.sha256"
  gold_sources=()
  for source in "${sources[@]}"; do
    if [[ "${source##*/}" == g6lc_l2_top.sv ]]; then gold_sources+=("$OUT/legacy.corrected.sv")
    else gold_sources+=("$source"); fi
  done
  geometry="-GBYTE_SIZE=${byte_size} -GSET_ASSOC=${L2TB_SET_ASSOC:-4}"
  slang_flags="--ignore-initial --ignore-assertions --top g6lc_l2_fixture $geometry"
  if [[ "$eq_mem" == map ]]; then
    prepare="hierarchy -check -top g6lc_l2_fixture; flatten; proc; opt; memory_map; opt; async2sync; opt; check -assert"
    if [[ -n "${L2TB_EQ_TIMEOUT:-}" ]]; then eq_timeout="$L2TB_EQ_TIMEOUT"
    elif [[ "$byte_size" -ge 8192 ]]; then eq_timeout=600
    elif [[ "$byte_size" -ge 4096 ]]; then eq_timeout=300
    else eq_timeout=120
    fi
  elif [[ "$eq_mem" == bbox ]]; then
    # Slang flattens by default, which deletes the tag/data/mshr modules
    # before blackbox can match them. Keep hierarchy, then box those
    # arrays so geometry does not explode SAT. This proves controller/port
    # wiring of RR_EN=0 vs the bypass-corrected pre-RR engine, not the tag
    # flop netlist.
    slang_flags="--keep-hierarchy --unroll-limit=16384 $slang_flags"
    prepare="hierarchy -check -top g6lc_l2_fixture; blackbox g6lc_l2_tag*; blackbox g6lc_l2_data*; blackbox g6lc_l2_mshr*; blackbox tc_sram*; hierarchy -top g6lc_l2_fixture; flatten; proc; opt; async2sync; opt; memory -nomap; opt; check -assert"
    eq_timeout="${L2TB_EQ_TIMEOUT:-60}"
  else
    prepare="hierarchy -check -top g6lc_l2_fixture; flatten; proc; opt; memory_collect; opt; async2sync; opt; check -assert"
    eq_timeout="${L2TB_EQ_TIMEOUT:-300}"
  fi
  cat > "$OUT/equiv.ys" <<EOF
read_slang ${gold_sources[*]} -DL2TB_STATIC -DL2TB_SYNTH -DL2TB_LEGACY $slang_flags
$prepare
design -stash gold
read_slang ${sources[*]} -DL2TB_STATIC -DL2TB_SYNTH $slang_flags -GRR_EN=0 -GEQ_NEGATIVE=${L2TB_EQ_NEGATIVE:-0}
$prepare
design -stash gate
design -copy-from gold -as gold g6lc_l2_fixture
design -copy-from gate -as gate g6lc_l2_fixture
equiv_make gold gate equiv
hierarchy -top equiv
select -assert-min 1 t:\$equiv
opt_merge -share_all
equiv_simple -short -undef -seq 2
equiv_status -assert
EOF
  timeout "${eq_timeout}s" "${YOSYS:-yosys}" -Q -T -s "$OUT/equiv.ys" 2>&1 | tee "$OUT/equiv.log"
  sha256sum --check --status "$OUT/sources.sha256"
  echo "[l2-tb] EQUIVALENCE PASS mem=$eq_mem bytes=$byte_size — $OUT/equiv.log"
  exit 0
fi
if [[ "${L2TB_MODE:-sim}" == synth ]]; then
  # Under TAG_SRAM the tag words live in the tc_sram instance, so the fixture
  # has one extra memory on that path (data array + optional RR pointer +
  # tag row store).
  tag_sram="${L2TB_TAG_SRAM:-0}"
  "${YOSYS:-yosys}" -Q -T -p "read_slang ${sources[*]} -DL2TB_STATIC -DL2TB_SYNTH --ignore-initial --ignore-assertions --top g6lc_l2_fixture -GRR_EN=${L2TB_RR_EN:-0} -GBYTE_SIZE=${L2TB_BYTE_SIZE:-4096} -GSET_ASSOC=${L2TB_SET_ASSOC:-4} -GTAG_SRAM=${tag_sram} -GWRITE_UPDATE=${L2TB_WRITE_UPDATE:-0}; hierarchy -top g6lc_l2_fixture; flatten; proc; opt; memory_collect; check -assert; stat; select -assert-count $((2 + ${L2TB_RR_EN:-0} + tag_sram)) t:\$mem_v2; synth -top g6lc_l2_fixture -noabc; check -assert; stat; select -assert-none t:\$dlatch t:\$_DLATCH_*" \
    2>&1 | tee "$OUT/synth.log"
  echo "[l2-tb] SYNTH PASS rr=${L2TB_RR_EN:-0} tagsram=${tag_sram} wu=${L2TB_WRITE_UPDATE:-0} mem=$((2 + ${L2TB_RR_EN:-0} + tag_sram)) — $OUT/synth.log"
  exit 0
fi
if [[ "${L2TB_MODE:-sim}" == units ]]; then
  "$VERILATOR" --binary --timing --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
    "${warning_args[@]}" -Wno-BLKSEQ -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-VARHIDDEN \
    -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
    "$ROOT/verif/tb/l2/tb_g6lc_l2.vlt" \
    "$ROOT/vendor/pulp-platform/tech_cells_generic/src/rtl/tc_sram.sv" \
    "$ROOT/corev_apu/l2_cache/g6lc_l2_data.sv" \
    "$ROOT/corev_apu/l2_cache/g6lc_l2_mshr.sv" \
    "$ROOT/verif/tb/l2/tb_g6lc_l2_units.sv" \
    --top-module tb_g6lc_l2_units \
    -Mdir "$OUT" -o tb_g6lc_l2_units 2>&1 | tee "$OUT/build.log"
  sha256sum --check --status "$OUT/sources.sha256"
  sha256sum "$OUT/tb_g6lc_l2_units" > "$OUT/executable.sha256"
  "$OUT/tb_g6lc_l2_units" 2>&1 | tee "$OUT/sim.log"
  [[ $(grep -cFx '[L2UNIT] RESULT pass' "$OUT/sim.log") == 1 ]] &&
    grep -qFx '[L2UNIT] mshr_full=1 merge=1 merge_full=1 waiter=1 bank_conflict=1 bank_ok=1' "$OUT/sim.log" &&
    ! grep -qE 'FAIL|RESULT fail|%Error|%Fatal' "$OUT/sim.log" || { echo "[l2-tb] UNITS FAIL — $OUT/sim.log"; exit 1; }
  echo "[l2-tb] UNITS PASS — $OUT/sim.log"
  exit 0
fi
[[ "${L2TB_MODE:-sim}" == sim ]] || exit 2
"$VERILATOR" --binary --timing --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
  "${warning_args[@]}" -Wno-BLKSEQ -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-VARHIDDEN \
  -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
  "$ROOT/verif/tb/l2/tb_g6lc_l2.vlt" "${sources[@]}" \
  --top-module tb_g6lc_l2 \
  -GBYTE_SIZE="${L2TB_BYTE_SIZE:-4096}" \
  -GSET_ASSOC="${L2TB_SET_ASSOC:-4}" \
  -GMEM_LATENCY="${L2TB_MEM_LATENCY:-6}" \
  -GSTALL_EVERY="${L2TB_STALL_EVERY:-0}" \
  -GRR_EN="${L2TB_RR_EN:-0}" \
  -GSEED="${L2TB_SEED:-$((0x600df00d))}" \
  -GWRITE_UPDATE="${L2TB_WRITE_UPDATE:-0}" \
  ${L2TB_EXTRA:-} \
  -Mdir "$OUT" -o tb_g6lc_l2 2>&1 | tee "$OUT/build.log"

sha256sum --check --status "$OUT/sources.sha256"
sha256sum "$OUT/tb_g6lc_l2" > "$OUT/executable.sha256"
sim_args=(+bypass-backpressure +atop-drain +amo-arith "$@")
printf '%q ' "${sim_args[@]}" > "$OUT/run.args"
printf '\n' >> "$OUT/run.args"
"$OUT/tb_g6lc_l2" "${sim_args[@]}" 2>&1 | tee "$OUT/sim.log"
[[ $(grep -cFx '[L2TB] RESULT pass' "$OUT/sim.log") == 1 ]] &&
  ! grep -qE 'FAIL|RESULT fail|%Error|%Fatal' "$OUT/sim.log" || { echo "[l2-tb] FAIL — see $OUT/sim.log"; exit 1; }
echo "[l2-tb] PASS — $OUT/sim.log"
