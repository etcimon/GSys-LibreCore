#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Isolated checked-work wrapper. Creates an allowlisted config overlay in a
# fresh directory, compiles mini_checked_work.S, and (when invoked through
# verify --qualification) binds a remote run to an isolated Mdir. Production
# work-ver-stream8 / work-ver-smt2-fw64-B names are refused.
#
# This is a control/workload envelope, not a performance promotion.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"

fail() { echo "[qual-checked-work] $*" >&2; exit 2; }

TARGET="${G6LC_CHECKED_TARGET:-g6lc64_stream8}"
[[ "$TARGET" =~ ^[A-Za-z0-9_]+$ ]] || fail "illegal target"
OVERLAY_DIR="${G6LC_ISOLATED_DIR:-}"
RR="${G6LC_L2_RR:-0}"
[[ "$RR" == 0 || "$RR" == 1 ]] || fail "G6LC_L2_RR must be 0 or 1"
NWORKERS="${G6LC_NWORKERS:-1}"
[[ "$NWORKERS" == 1 || "$NWORKERS" == 2 ]] || fail "NWORKERS must be 1 or 2"

if [[ -z "$OVERLAY_DIR" ]]; then
  OVERLAY_DIR="$(mktemp -d /tmp/g6lc-isolated-XXXXXX)"
fi
python3 "$ROOT/verif/regress/isolated-config-overlay.py" \
  --root "$ROOT" --target "$TARGET" --out "$OVERLAY_DIR" \
  --field "L2RoundRobinEn=$RR"

python3 - "$OVERLAY_DIR/overlay.json" "$RR" <<'PY' || fail "overlay metadata mismatch"
import json, sys
meta = json.load(open(sys.argv[1]))
assert meta["isolated"] and meta["experimental"] and meta["notALinuxSku"]
assert meta["fields"]["L2RoundRobinEn"]["to"] == sys.argv[2]
print("[qual-checked-work] overlay ok", meta["overlaySha25612"])
PY

RISCV_CC="${RISCV_CC:-riscv-none-elf-gcc}"
if ! command -v "$RISCV_CC" >/dev/null 2>&1; then
  for p in /opt/xpack/xpack-riscv-none-elf-gcc-*/bin; do
    [[ -x "$p/riscv-none-elf-gcc" ]] && export PATH="$p:${PATH}" || true
  done
fi
ELF=""
if command -v "$RISCV_CC" >/dev/null 2>&1; then
  COMMON="$ROOT/verif/tests/custom/common"
  ELF="$OVERLAY_DIR/mini_checked_work.elf"
  "$RISCV_CC" -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
    -I"$ROOT/verif/tests/custom/env" -I"$COMMON" \
    -DNBYTES=49152 -DNWORKERS="$NWORKERS" \
    "$ROOT/verif/tests/custom/multicore/mini_checked_work.S" \
    -T "$COMMON/link_verilator.ld" -o "$ELF" \
    -march=rv64imafdc_zicsr_zifencei -mabi=lp64d \
    || fail "compile mini_checked_work failed"
  echo "[qual-checked-work] elf=$ELF nworkers=$NWORKERS"
else
  echo "[qual-checked-work] no riscv-none-elf-gcc; overlay-only"
fi

ROLE="${G6LC_CHECKED_ROLE:-overlay}"
if [[ "$ROLE" == control ]]; then
  LOG="${G6LC_CHECKED_LOG:-}"
  [[ -n "$LOG" && -f "$LOG" ]] || fail "control role needs G6LC_CHECKED_LOG"
  if grep -qE 'tohost = 1\)' "$LOG" && ! grep -qE 'tohost = 3\)' "$LOG"; then
    echo "[qual-checked-work] CONTROL PASS kernel tohost=1 (harness may print FAILED for non-zero HTIF)"
    exit 0
  fi
  fail "control log is not kernel tohost=1"
fi

IDENT="${G6LC_QUALIFICATION_IDENTITY:-}"
if [[ -z "$IDENT" ]]; then
  echo "[qual-checked-work] overlay/compile complete; not a qualification run (no identity)"
  exit 0
fi

MANIFEST_REL="${G6LC_BUILD_MANIFEST:-}"
[[ -n "$MANIFEST_REL" ]] || fail "G6LC_BUILD_MANIFEST missing"
[[ -f "$MANIFEST_REL" ]] || fail "missing manifest $MANIFEST_REL"
manifest_base="$(basename "$MANIFEST_REL")"
case "$manifest_base" in
  work-ver-stream8.manifest.json|work-ver-smt2-fw64-B.manifest.json|work-ver-smt2-fw64.manifest.json)
    fail "isolated checked-work must not bind a production Mdir manifest"
    ;;
esac
[[ -n "$ELF" ]] || fail "qualification run requires a compiled ELF"
echo "[qual-checked-work] identity present; isolated control is compiled. Bind/run remains the caller's isolated Mdir."
echo "[qual-checked-work] RESULT overlay-ready target=$TARGET rr=$RR nworkers=$NWORKERS"
exit 0
