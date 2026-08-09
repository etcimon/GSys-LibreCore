#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Xg6lcai AI matrix plane — config-surface smoke (optional; not default verify).
#
# This gate exists because the AI plane's config surface is deliberately OPEN
# (tier R/T) while its implementation is withheld (tier P case 2). A party
# without the implementation must still be able to elaborate, discover and
# verify the seam — this script is what proves that stays true.
#
# Stages:
#   1. contract   — the open interface files exist
#   2. defaults   — every non-AI package still elaborates with AiCfg all-zero,
#                   i.e. the new struct member changed nothing for them
#   3. normalise  — g6lc64_ai resolves to the intended geometry via build_config
#   4. legality   — each illegal AiCfg actually trips a check_cfg assertion
#
# Stages 2-4 need Verilator; without it they SKIP (soft) unless AI_CFG_REQUIRE_LINT=1.
#
# Env:
#   AI_CFG_REQUIRE_LINT=1  hard-fail if Verilator is unavailable
#   AI_CFG_OUT=<dir>       scratch dir (default /tmp/cva6-ai-config-smoke)
#
# Priors: architecture/ai-matrix/README.md · architecture/ai-matrix/isa-encoding.md
#         AGENTS-todo.md AI-1 · AGENTS-licensing.md (tier P case 2)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

REQUIRE_LINT="${AI_CFG_REQUIRE_LINT:-0}"
OUT="${AI_CFG_OUT:-/tmp/cva6-ai-config-smoke}"
rm -rf "$OUT"; mkdir -p "$OUT"

PASS=0
FAIL=0
SKIP=0
log() { echo "[ai-config-smoke] $*"; }
ok()   { PASS=$((PASS+1)); log "PASS $*"; }
bad()  { FAIL=$((FAIL+1)); log "FAIL $*"; }
skip() { SKIP=$((SKIP+1)); log "SKIP $*"; }

log "OPTIONAL — Xg6lcai config-surface smoke"
log "  package: core/include/g6lc64_ai_config_pkg.sv"
log "  contract: architecture/ai-matrix/isa-encoding.md"

# ---------------------------------------------------------------- 1. contract
need=(
  core/include/config_pkg.sv
  core/include/build_config_pkg.sv
  core/include/g6lc64_ai_config_pkg.sv
  architecture/ai-matrix/README.md
  architecture/ai-matrix/isa-encoding.md
)
for f in "${need[@]}"; do
  test -f "$f" || { log "MISSING $f"; exit 1; }
done
ok "contract files present"

# The interface must not drift into the withheld tier. If these globs ever match
# the config package or the tests, the "withhold the implementation, never the
# interface" rule in AGENTS-licensing.md has been broken.
if grep -qE '^P\s+core/include/g6lc64_ai_config_pkg\.sv' .licensing-tiers 2>/dev/null; then
  bad "g6lc64_ai_config_pkg.sv is classified tier P — the interface must stay open"
else
  ok "config surface is not tier P (interface stays open)"
fi

VERILATOR="$(command -v verilator || true)"
if [ -z "$VERILATOR" ]; then
  if [ "$REQUIRE_LINT" = "1" ]; then
    log "Verilator required (AI_CFG_REQUIRE_LINT=1) but not found"; exit 1
  fi
  skip "Verilator unavailable — stages 2-4 skipped"
  log "RESULT pass=$PASS fail=$FAIL skip=$SKIP"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
fi

VLT_ARGS=(--binary -j 4 -Wno-fatal -Wno-style --assert)

# Build with one retry. Unbounded -j after a dozen back-to-back builds has been
# observed to fail in the C++ link stage with no %Error in the log; that is a
# host artefact, and reporting it as a config failure would make this gate flaky.
vlt_build() { # $1 = Mdir, $2.. = sources
  local d="$1"; shift
  local try
  for try in 1 2; do
    rm -rf "$d"
    if verilator "${VLT_ARGS[@]}" --Mdir "$d" -o sim --top-module ai_cfg_harness \
         "$@" > "$d.log" 2>&1; then
      return 0
    fi
    grep -q '%Error' "$d.log" && return 1   # a real elaboration error: do not retry
  done
  return 1
}

# ------------------------------------------------- 2./3. defaults + normalise
cat > "$OUT/report.sv" <<'EOF'
module ai_cfg_harness;
  localparam config_pkg::cva6_cfg_t Cfg =
      build_config_pkg::build_config(cva6_config_pkg::cva6_cfg);
  initial begin
    config_pkg::check_cfg(Cfg);
    $display("AICFG %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
             Cfg.AiCfg.MatrixEn, Cfg.AiCfg.AccelEn, Cfg.AiCfg.TileLdEn,
             Cfg.AiCfg.TileM, Cfg.AiCfg.TileN, Cfg.AiCfg.TileK,
             Cfg.AiCfg.TileCount, Cfg.AiCfg.AccBanks, Cfg.AiCfg.AccDepth,
             Cfg.AiCfg.Queues, Cfg.AiCfg.QueueDepth, Cfg.AiCfg.QosClasses,
             Cfg.AiCfg.Int4En, Cfg.AiCfg.Sparse24En);
    $finish;
  end
endmodule
EOF

report_for() { # $1 = target -> echoes the AICFG line
  local t="$1" d="$OUT/obj_$1"
  if ! vlt_build "$d" core/include/config_pkg.sv "core/include/${t}_config_pkg.sv" \
        core/include/build_config_pkg.sv "$OUT/report.sv"; then
    return 1
  fi
  "$d/sim" 2>&1 | grep '^AICFG ' || return 1
}

# Packages that already fail check_cfg at HEAD, for reasons unrelated to the AI
# plane. Verified by linting the HEAD blobs: the same assertion fires with and
# without AiCfg, at the same source line modulo the added lines.
#   g6lc64_ooo_server -- config_pkg.sv "DeepSpecEn && MaxOutstandingStores > 16"
#                        (STQ CAM cap v1). Tracked as AI-4 in AGENTS-todo.md.
# Listed rather than dropped so the defect stays visible; remove an entry as
# soon as its package is fixed.
KNOWN_BAD=" g6lc64_ooo_server "

# Non-AI packages: the AiCfg group must be entirely zero, proving the added
# struct member is behaviourally inert for every existing target.
for t in g6lc64_stream8 g6lc64_smt2 g6lc64_server_math g6lc64_server_math_v \
         g6lc64_ooo g6lc64_ooo_server cv64a6_imafdc_sv39 cv32a65x \
         cv32a60x cv64a6_spec_deep; do
  if ! line="$(report_for "$t")"; then
    case "$KNOWN_BAD" in
      *" $t "*) skip "$t — known pre-existing check_cfg failure (AI-4), not AiCfg"; continue ;;
    esac
    bad "$t did not elaborate (see $OUT/obj_$t.log)"; continue
  fi
  if [ "$line" = "AICFG 0 0 0 0 0 0 0 0 0 0 0 0 0 0" ]; then
    ok "$t — AiCfg inert (all zero)"
  else
    bad "$t — expected all-zero AiCfg, got: $line"
  fi
done

# The AI package: build_config must normalise to the documented geometry.
if ! line="$(report_for g6lc64_ai)"; then
  bad "g6lc64_ai did not elaborate (see $OUT/obj_g6lc64_ai.log)"
else
  # MatrixEn=1 AccelEn=0 (seam B) TileLd=0 (forced by seam) 8x8x8
  # tiles=8 banks=1 depth=4 queues=2 qdepth=64 qos=2 int4=0 sp24=0
  want="AICFG 1 0 0 8 8 8 8 1 4 2 64 2 0 0"
  if [ "$line" = "$want" ]; then
    ok "g6lc64_ai — normalised geometry matches the documented package"
  else
    bad "g6lc64_ai — expected '$want', got '$line'"
  fi
fi

# ---------------------------------------------------------------- 4. legality
neg_case() { # $1 = name, $2 = mutation, $3 = expected (none|assert)
  local name="$1" mut="$2" expect="$3" d="$OUT/neg_$RANDOM"
  cat > "$OUT/neg.sv" <<EOF
module ai_cfg_harness;
  function automatic config_pkg::cva6_user_cfg_t mutate();
    config_pkg::cva6_user_cfg_t u = cva6_config_pkg::cva6_cfg;
    ${mut}
    return u;
  endfunction
  initial begin
    config_pkg::check_cfg(build_config_pkg::build_config(mutate()));
    \$display("NO_ASSERT");
    \$finish;
  end
endmodule
EOF
  if ! vlt_build "$d" core/include/config_pkg.sv core/include/g6lc64_ai_config_pkg.sv \
        core/include/build_config_pkg.sv "$OUT/neg.sv"; then
    bad "legality/$name — build failed (see $d.log)"; return
  fi
  local got=assert
  "$d/sim" 2>&1 | grep -q 'NO_ASSERT' && got=none
  rm -rf "$d"
  if [ "$got" = "$expect" ]; then
    ok "legality/$name (expected $expect)"
  else
    bad "legality/$name — expected $expect, got $got"
  fi
}

neg_case "baseline-legal"      "u.AiCfg.MatrixEn = 1'b1;"                          none
neg_case "no-seam"             "u.CvxifEn = 1'b0;"                                 assert
neg_case "both-seams"          "u.AiCfg.AccelEn = 1'b1;"                           assert
neg_case "accel-with-rvv"      "u.AiCfg.AccelEn = 1'b1; u.CvxifEn = 1'b0; u.RVV = 1'b1;" assert
neg_case "tile-not-pow2"       "u.AiCfg.TileM = 32'd3;"                            assert
neg_case "group-without-master" "u.AiCfg.MatrixEn = 1'b0; u.AiCfg.SparseEn = 1'b0; u.AiCfg.UmodeEn = 1'b0; u.AiCfg.Queues = 32'd0;" assert
# Not an error: build_config raises AccBanks to NrHarts rather than trapping.
neg_case "banks-normalised"    "u.NrHarts = 32'd2; u.AiCfg.AccBanks = 32'd1;"      none
# The CVXIF seam must select the AI coprocessor, and must not claim it when the
# plane is off -- otherwise a package can look legal while nothing is attached.
neg_case "copro-mismatch"      "u.CoproType = config_pkg::COPRO_EXAMPLE;"          assert
neg_case "copro-without-plane" "u.AiCfg.MatrixEn = 1'b0; u.AiCfg.RequantEn = 1'b0; u.AiCfg.SparseEn = 1'b0; u.AiCfg.UmodeEn = 1'b0; u.AiCfg.Queues = 32'd0; u.AiCfg.QosClasses = 32'd0;" assert
# Datatype grant gates imply the master enable.
neg_case "int4-without-plane"  "u.AiCfg.MatrixEn = 1'b0; u.AiCfg.RequantEn = 1'b0; u.AiCfg.SparseEn = 1'b0; u.AiCfg.UmodeEn = 1'b0; u.AiCfg.Queues = 32'd0; u.AiCfg.QosClasses = 32'd0; u.CoproType = config_pkg::COPRO_NONE; u.AiCfg.Int4En = 1'b1;" assert
# QoS classes are normalised up to 1 alongside rings, and down to 0 without them.
neg_case "qos-normalised"      "u.AiCfg.QosClasses = 32'd0;"                       none
neg_case "qos-without-queues"  "u.AiCfg.Queues = 32'd0;"                           none

log "RESULT pass=$PASS fail=$FAIL skip=$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
log "ai-config-smoke OK"
