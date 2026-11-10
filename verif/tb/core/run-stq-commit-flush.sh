#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# store_buffer commit+flush leaf (CPU49b): positive, +oracle_negative (must
# fail), a deterministic reconstruction of the pre-fix store_buffer whose
# `commit_and_flush` assertion must fire on the coincident case (it is what
# aborted the CPU49 step runs), and G6LC_MUT_STQ_COMMIT_DROPPED_ON_FLUSH —
# rejected by the new commit_and_flush_keeps_head assertion under --assert
# and by the bench checks without it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
OUT="${STQ_COMMIT_FLUSH_OUT:-/tmp/g6lc-stq-commit-flush}"
mkdir -p "$OUT"
if ! command -v verilator >/dev/null 2>&1; then
  echo "INCOMPLETE: no verilator on PATH" >&2
  exit 4
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "INCOMPLETE: no python3 on PATH" >&2
  exit 4
fi
# Pre-fix reconstruction: swap the CPU49b assertion pair back to the original
# commit_and_flush text — deterministic, no .git required, exactly once.
PREFIX_SB="$OUT/store_buffer_prefix.sv"
python3 - "$ROOT/core/store_buffer.sv" "$PREFIX_SB" <<'PYEOF'
import sys
src, dest = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
begin_marker = "  // The commit stage can retire a store"
end_marker = ('else $error("[Speculative Queue] speculative stores survived '
              'a full flush");')
old = """\
  // assert that commit is never set when we are flushing this would be counter intuitive
  // as flush and commit is decided in the same stage
  commit_and_flush :
  assert property (@(posedge clk_i) rst_ni && flush_i |-> !commit_i)
  else $error("[Commit Queue] You are trying to commit and flush in the same cycle");"""
if text.count(begin_marker) != 1 or text.count(end_marker) != 1:
    sys.exit("INCOMPLETE: prefix assertion inventory "
             f"{text.count(begin_marker)}/{text.count(end_marker)}")
i = text.index(begin_marker)
j = text.index(end_marker) + len(end_marker)
open(dest, "w", encoding="utf-8").write(text[:i] + old + text[j:])
PYEOF
COMMON=(
  --binary --timing -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND
  -Wno-PINCONNECTEMPTY -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -Wno-DECLFILENAME
  -I"$ROOT/core/include" -I"$ROOT/core/ooo"
  "$ROOT/core/include/config_pkg.sv"
  "$ROOT/core/include/g6lc64_ooo_config_pkg.sv"
  "$ROOT/core/include/riscv_pkg.sv"
  "$ROOT/core/include/ariane_pkg.sv"
  "$ROOT/core/ooo/g6lc_ooo_pkg.sv"
  "$ROOT/verif/tb/core/tb_g6lc_stq_commit_flush.sv"
)
build() {
  # $1 output name, $2 store_buffer source, $3 assert flag ("--assert" or ""),
  # rest: extra verilator flags
  local name="$1" sb="$2" assert_flag="$3"; shift 3
  verilator "${COMMON[@]}" "$sb" $assert_flag "$@" \
    --top-module tb_g6lc_stq_commit_flush -Mdir "$OUT/$name" -o tb \
    > "$OUT/$name.build.log" 2>&1
}
build pos "$ROOT/core/store_buffer.sv" --assert
"$OUT/pos/tb" | tee "$OUT/pos.log" | grep -q "^PASS tb_g6lc_stq_commit_flush" || { echo "FAIL positive"; exit 1; }
if grep -q "a store retired with a flush did not reach the commit queue\|commit and flush in the same cycle\|STQ_HEAD_RETIRED_WITH_FLUSH\|ORACLE_NEGATIVE\|survived a full flush" "$OUT/pos.log"; then
  echo "FAIL positive log carries a failure marker"; exit 1
fi
set +e
"$OUT/pos/tb" +oracle_negative > "$OUT/neg.log" 2>&1
grep -q "ORACLE_NEGATIVE\|STQ_" "$OUT/neg.log" || { echo "FAIL oracle negative did not fire"; exit 1; }
set -e
# The pre-fix assertion must fire on the coincident commit+flush cycle.
build prefix "$PREFIX_SB" --assert
set +e
"$OUT/prefix/tb" > "$OUT/prefix.log" 2>&1
set -e
grep -q "commit and flush in the same cycle" "$OUT/prefix.log" || { echo "FAIL prefix assertion did not fire"; cat "$OUT/prefix.log"; exit 1; }
# Mutant: the new assertion rejects it when assertions are enabled ...
build mut "$ROOT/core/store_buffer.sv" --assert "+define+G6LC_MUT_STQ_COMMIT_DROPPED_ON_FLUSH"
set +e
"$OUT/mut/tb" > "$OUT/mut.log" 2>&1
set -e
grep -q "a store retired with a flush did not reach the commit queue\|STQ_HEAD_RETIRED_WITH_FLUSH" "$OUT/mut.log" || { echo "FAIL mutation not caught under --assert"; cat "$OUT/mut.log"; exit 1; }
# ... and the bench checks reject it without assertions.
build mutna "$ROOT/core/store_buffer.sv" "" "+define+G6LC_MUT_STQ_COMMIT_DROPPED_ON_FLUSH"
set +e
"$OUT/mutna/tb" > "$OUT/mutna.log" 2>&1
set -e
grep -q "STQ_HEAD_RETIRED_WITH_FLUSH" "$OUT/mutna.log" || { echo "FAIL mutation not caught without --assert"; cat "$OUT/mutna.log"; exit 1; }
echo "PASS run-stq-commit-flush (positive, oracle negative, prefix assertion fires, mutant rejected by assertion and bench)"
