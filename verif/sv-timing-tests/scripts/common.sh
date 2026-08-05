# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# Shared helpers for verif/regress/sv-timing-*.sh

svt_verif_root() {
  ROOT="$(cd "$(dirname "${BASH_SOURCE[1]}")/../.." && pwd 2>/dev/null || cd "$(dirname "$0")/../.." && pwd)"
  echo "$ROOT"
}

svt_out_base() {
  local root="${1:-.}"
  echo "${SVT_VERIF_OUT:-$root/build-platform/workspace/build/sv-timing/verif-tests}"
}

svt_need_bun() {
  command -v bun >/dev/null 2>&1 || {
    echo "[sv-timing-tests] bun not on PATH (required for build-platform timings)"
    exit 1
  }
}

svt_timings() {
  local root="$1"
  shift
  (cd "$root/build-platform" && bun run src/cli/index.ts timings "$@")
}

svt_ensure_dir() {
  mkdir -p "$1"
}

# If CVA6_FROM_TIMING / FROM_TIMING is set, validate the package and use it as OUT.
# Returns 0 and sets SVT_FROM_TIMING_DIR when consuming a precompiled out-dir.
# Optional: SVT_STA_HANDOFF=1 runs timings sta-handoff S0 after validate.
svt_maybe_from_timing() {
  local root="$1"
  local dir="${CVA6_FROM_TIMING:-${FROM_TIMING:-}}"
  if [[ -z "$dir" ]]; then
    return 1
  fi
  echo "[sv-timing-tests] --from-timing consume: $dir"
  set +e
  svt_timings "$root" validate --from-timing "$dir"
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    echo "[sv-timing-tests] from-timing validate failed"
    exit 1
  fi
  SVT_FROM_TIMING_DIR="$dir"
  if [[ "${SVT_STA_HANDOFF:-0}" == "1" ]]; then
    echo "[sv-timing-tests] sta-handoff S0 (review-only SDC)"
    set +e
    svt_timings "$root" sta-handoff --from-timing "$dir" --try-tools
    set -e
  fi
  return 0
}
