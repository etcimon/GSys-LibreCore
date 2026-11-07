#!/usr/bin/env bash
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
# Mechanism sample, not a replacement for the full regression or CTS.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
source "$ROOT/verif/tb/apu/local-verilator.sh"
export APU_VGTOP_OUT="${APU_VGTOP_OUT:-$APU_BUILD_CACHE/vgtop}"
sessions=(ue_gpos_tri_1 ue_gpos_fsubo_1 ue_gpos_fsubocopy_1
          ue_cpos_dcopy_descarr_1)
jitter=0
cohort="${APU_DEV_COHORT:-baseline}"
check_only=0
while (($#)); do
  case "$1" in
    --session)
      [[ $# -ge 2 ]] || { echo "--session requires a vector name" >&2; exit 2; }
      sessions=("$2")
      cohort=custom
      shift 2 ;;
    --jitter) jitter=1; shift ;;
    --immutable) cohort=immutable; shift ;;
    --layout) cohort=layout; shift ;;
    --check) check_only=1; shift ;;
    *) echo "Usage: $0 [--session NAME | --immutable | --layout] [--jitter] [--check]" >&2; exit 2 ;;
  esac
done
case "$cohort" in
  baseline|custom) ;;
  immutable) sessions=(ue_cpos_imm_texlod_1 ue_cpos_imm_copy_1 ue_cpos_imm_array_1) ;;
  layout) sessions=(ue_cpos_emptylayout_1 ue_cpos_dslcompat_1 ue_cneg_layoutmix_1) ;;
  *) echo "Unknown APU_DEV_COHORT: $cohort" >&2; exit 2 ;;
esac
for budget in APU_DEV_BUILD_TIMEOUT APU_DEV_TEST_TIMEOUT APU_TOOL_SETUP_TIMEOUT; do
  value="${!budget:-}"
  [[ -z "$value" || "$value" =~ ^[1-9][0-9]*$ ]] || {
    echo "$budget must be positive seconds" >&2; exit 2;
  }
done
for dependency in python3 timeout flock make g++; do
  command -v "$dependency" >/dev/null || {
    echo "BLOCKED: missing $dependency" >&2; exit 3;
  }
done
for session in "${sessions[@]}"; do
  [[ "$session" =~ ^[a-zA-Z0-9_]+$ ]] || exit 2
done
python3 -B "$ROOT/verif/tb/apu/apu_dev_preflight.py" "$ROOT" "${sessions[@]}" || exit $?
if ((check_only)); then
  APU_AUTO_INSTALL=0 apu_ensure_verilator || exit 3
  echo "DEV PREFLIGHT OK (no installation, build or tests)"
  exit 0
fi
apu_ensure_verilator || exit $?
mkdir -p "$APU_VGTOP_OUT"
exec 8>"$APU_VGTOP_OUT/dev.lock"
flock --timeout "${APU_DEV_BUILD_TIMEOUT:-600}" 8 || exit 4
build_wait="${APU_DEV_BUILD_TIMEOUT:-600}"
if [[ "${APU_SIM_PGO:-1}" == 1 ]]; then
  build_wait="${APU_SIM_PGO_TIMEOUT:-1800}"
fi
timeout --kill-after=10 "$build_wait" \
  bash "$ROOT/verif/tb/apu/build-apu-vgtop.sh" || exit $?
logs="${APU_DEV_LOG_DIR:-$APU_VGTOP_OUT/dev}"
mkdir -p "$logs"
printf '%s\n' "${sessions[@]}" > "$logs/selected.txt"
cp "$APU_VGTOP_OUT/toolchain.txt" "$logs/toolchain.txt"
image="$APU_VGTOP_OUT/sim/tb_g6lc_apu_vgtop"
if [[ "${APU_SIM_PGO:-1}" == 1 ]]; then
  cp "$APU_VGTOP_OUT/sim/simulator-pgo.json" "$logs/simulator-pgo.json" || exit 4
  image="$(PYTHONPATH="$ROOT/verif/tb/apu${PYTHONPATH:+:$PYTHONPATH}" python3 -B - "$logs/simulator-pgo.json" <<'PY'
import json, sys
from apu_sim_pgo import receipt_valid
report = json.load(open(sys.argv[1]))
if not receipt_valid(report, report['requestSha256']):
    raise SystemExit(4)
print(report['binary'])
PY
  )" || exit 4
fi
printf 'cohort=%s\nbuild_timeout=%s\ntest_timeout=%s\nsetup_timeout=%s\n' \
  "$cohort" "${APU_DEV_BUILD_TIMEOUT:-600}" "${APU_DEV_TEST_TIMEOUT:-60}" \
  "${APU_TOOL_SETUP_TIMEOUT:-1200}" > "$logs/budgets.txt"
args=(+xf_ok)
if ((jitter)); then
  args+=(+mp_lat_min=1 +mp_lat_max=20 +mp_ready_pct=60)
fi
cd "$ROOT/verif/tb/apu"
for session in "${sessions[@]}"; do
  log="$logs/$session-jitter$jitter.log"
  rc=0
  timeout --kill-after=5 "${APU_DEV_TEST_TIMEOUT:-60}" \
      "$image" "+vec=$session" \
      "${args[@]}" > "$log" 2>&1 || rc=$?
  if ((rc)); then
    tail -n 40 "$log"
    exit "$rc"
  fi
  if grep -Eq '^(FAIL\b|%Error|%Fatal)' "$log"; then
    tail -n 40 "$log"
    exit 1
  fi
  if grep -Eq '^(BLOCKED\b|INCOMPLETE\b)' "$log"; then
    tail -n 40 "$log"
    exit 4
  fi
  grep '^PASS tb_g6lc_apu_vgtop .*checks=[1-9][0-9]*' "$log" || exit 4
done
