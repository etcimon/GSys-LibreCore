#!/usr/bin/env bash
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
# Source this file from an APU build script; execute it to build the local tool.
APU_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
APU_BUILD_CACHE="${APU_BUILD_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/librecore/apu}"
export APU_SIM_PGO="${APU_SIM_PGO:-1}"
if [[ -z "${APU_VERILATOR_HOME:-}" ]]; then
  APU_VERILATOR_HOME="${XDG_CACHE_HOME:-$HOME/.cache}/librecore/apu-verilator"
  [[ "${APU_VERILATOR_PGO:-1}" == 0 ]] || APU_VERILATOR_HOME+="-pgo-v1"
fi

apu_verilator_flags() {
  local flags
  flags="$(python3 "$APU_ROOT/verif/tb/apu/apu_vlt_policy.py" --flags)" || return 2
  mapfile -t APU_VERILATOR_FLAGS <<< "$flags"
  export VERILATOR_UNROLL_COUNT=256 VERILATOR_UNROLL_STMTS=131072
  export VERILATOR_UNROLL_ROLL_NARROW=0
}

apu_verilator_source_id() (
  set -euo pipefail
  # Isolated testharness snapshots have no .git directory. The proxy supplies
  # the digest of the compiler files it checksum-verified with the snapshot.
  if [[ -n "${APU_VERILATOR_SOURCE_ID_FILE:-}" ]]; then
    [[ -f "$APU_VERILATOR_SOURCE_ID_FILE" ]] || return 2
    local digest
    digest="$(cat "$APU_VERILATOR_SOURCE_ID_FILE")"
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 2
    printf 'snapshot-sha256=%s\n' "$digest"
    return
  fi
  git -C "$APU_ROOT/tools/verilator" rev-parse HEAD
  git -C "$APU_ROOT/tools/verilator" diff --no-ext-diff --binary HEAD -- \
    src include bin m4 configure.ac '*.in' install-sh | sha256sum | cut -d' ' -f1
)

apu_repo_verilator_ready() {
  [[ "${APU_VERILATOR_PGO:-1}" == 0 || "${APU_VERILATOR_PGO:-1}" == 1 ]] || return 1
  local home="$APU_VERILATOR_HOME"
  [[ -x "$home/bin/verilator_bin" && -x "$home/bin/verilator" &&
     -f "$home/bin/verilator_includer" && -f "$home/include/verilated.h" &&
     -s "$home/source.id" ]] || return 1
  local source_id
  source_id="$(apu_verilator_source_id)" || return 1
  [[ -n "$source_id" && "$source_id" == "$(cat "$home/source.id")" ]] || return 1
  if [[ "${APU_VERILATOR_PGO:-1}" == 1 ]]; then
    python3 "$APU_ROOT/verif/tb/apu/apu_vlt_policy.py" --check "$home" || return 1
  fi
}

apu_ensure_verilator() {
  if [[ "${VERILATOR:-}" == "$APU_ROOT/verif/tb/apu/apu-verilator.sh" ]]; then
    [[ -n "${APU_REAL_VERILATOR:-}" ]] || return 3
    VERILATOR="$APU_REAL_VERILATOR"
  fi
  if [[ -z "${VERILATOR:-}" ||
        "$VERILATOR" == "$APU_VERILATOR_HOME/bin/verilator" ]]; then
    if ! apu_repo_verilator_ready; then
      [[ "${APU_AUTO_INSTALL:-1}" == 1 ]] || {
        echo "BLOCKED: repository Verilator missing/stale; APU_AUTO_INSTALL=0" >&2
        return 3
      }
      local wait="${APU_TOOL_SETUP_TIMEOUT:-1200}" dependency
      [[ "$wait" =~ ^[1-9][0-9]*$ ]] || return 2
      for dependency in timeout flock git autoconf make g++ flex bison perl python3 sha256sum; do
        command -v "$dependency" >/dev/null || {
          echo "BLOCKED: missing build prerequisite: $dependency (no system install attempted)" >&2
          return 3
        }
      done
      for dependency in configure.ac Makefile.in src/Makefile.in include/verilated.h bin/verilator; do
        [[ -f "$APU_ROOT/tools/verilator/$dependency" ]] || {
          echo "BLOCKED: missing tools/verilator/$dependency" >&2
          return 3
        }
      done
      echo "Provisioning repository Verilator (offline, setup budget ${wait}s)"
      timeout --kill-after=5 "$wait" bash "$APU_ROOT/verif/tb/apu/local-verilator.sh" || return $?
    fi
  elif ! command -v "$VERILATOR" >/dev/null; then
    echo "BLOCKED: explicit Verilator is not executable: $VERILATOR" >&2
    return 3
  fi
  apu_select_verilator
}

apu_build_verilator() (
  set -euo pipefail
  local src="$APU_ROOT/tools/verilator"
  local home="$APU_VERILATOR_HOME"
  [[ "${APU_VERILATOR_PGO:-1}" == 0 || "${APU_VERILATOR_PGO:-1}" == 1 ]] || return 2
  [[ "${APU_BUILD_JOBS:-4}" =~ ^[1-9][0-9]*$ ]] || {
    echo "APU_BUILD_JOBS must be a positive integer" >&2
    return 2
  }
  mkdir -p "$home"
  # The lock also protects the runtime include overlay and completion receipt.
  exec 9>"$home/build.lock"
  flock 9
  apu_verilator_source_id > "$home/source.pending"
  if apu_repo_verilator_ready; then
    echo "Repository Verilator already built: $home"
    return
  fi
  # Out-of-tree only: no system install, downloads, distclean or source edits.
  if [[ "${APU_VERILATOR_PGO:-1}" == 1 ]]; then
    python3 "$APU_ROOT/verif/tb/apu/apu_verilator_pgo.py" \
      --src "$src" --home "$home" --jobs "${APU_BUILD_JOBS:-4}"
  else
    (cd "$src" && autoconf -o "$home/configure")
    (cd "$home" && env -u VERILATOR_ROOT ./configure --srcdir="$src" \
      --prefix="$home/install" > configure.log 2>&1)
    env -u VERILATOR_ROOT make -C "$home/src" -j "${APU_BUILD_JOBS:-4}" opt \
      > "$home/build.log" 2>&1
    cp -a "$src/include/." "$home/include/"
    cp "$src/bin/verilator" "$src/bin/verilator_includer" "$home/bin/"
    chmod u+x "$home/bin/verilator" "$home/bin/verilator_includer"
  fi
  VERILATOR_ROOT="$home" "$home/bin/verilator" --version
  apu_verilator_source_id > "$home/source.after"
  cmp "$home/source.pending" "$home/source.after"
  mv "$home/source.pending" "$home/source.id"
)

apu_select_verilator() {
  [[ "${APU_VERILATOR_PGO:-1}" == 0 || "${APU_VERILATOR_PGO:-1}" == 1 ]] || {
    echo "APU_VERILATOR_PGO must be 0 or 1" >&2
    return 2
  }
  APU_REPO_VERILATOR=0
  if [[ "${VERILATOR:-}" == "$APU_ROOT/verif/tb/apu/apu-verilator.sh" ]]; then
    [[ -n "${APU_REAL_VERILATOR:-}" ]] || return 2
    VERILATOR="$APU_REAL_VERILATOR"
  fi
  # A child runner may inherit the repository launcher selected by its parent.
  # Revalidate it rather than mislabelling it as an external override.
  if [[ -z "${VERILATOR:-}" ||
        "${VERILATOR:-}" == "$APU_VERILATOR_HOME/bin/verilator" ]]; then
    if ! apu_repo_verilator_ready; then
      echo "Build tools/verilator first: bash $APU_ROOT/verif/tb/apu/local-verilator.sh" >&2
      return 2
    fi
    export VERILATOR_ROOT="$APU_VERILATOR_HOME"
    VERILATOR="$APU_VERILATOR_HOME/bin/verilator"
    APU_REPO_VERILATOR=1
  fi
  export VERILATOR
  APU_BUILD_JOBS="${APU_BUILD_JOBS:-4}"
  [[ "$APU_BUILD_JOBS" =~ ^[1-9][0-9]*$ ]] || {
    echo "APU_BUILD_JOBS must be a positive integer" >&2
    return 2
  }
  export APU_BUILD_JOBS APU_BUILD_CACHE
  apu_verilator_flags || return $?
  [[ "${APU_SIM_PGO:-1}" == 0 || "${APU_SIM_PGO:-1}" == 1 ]] || return 2
  export APU_REAL_VERILATOR="$VERILATOR"
  if [[ "${APU_SIM_PGO:-1}" == 1 ]]; then
    local input
    for input in apu-verilator.sh apu_sim_pgo.py apu_sim_training.py \
                 apu_source_manifest.py apu_verilator_pgo.py apu_vlt_policy.py \
                 verilator-pgo-cxx.sh; do
      [[ -f "$APU_ROOT/verif/tb/apu/$input" ]] || {
        echo "BLOCKED: missing simulator PGO driver: $input" >&2
        return 3
      }
    done
    VERILATOR="$APU_ROOT/verif/tb/apu/apu-verilator.sh"
    export VERILATOR
  fi
}

apu_record_verilator() {
  {
    printf 'verilator=%s\nroot=%s\njobs=%s\n' \
      "$VERILATOR" "${VERILATOR_ROOT:-}" "$APU_BUILD_JOBS"
    "$VERILATOR" --version
    printf 'unroll_count=256\nunroll_stmts=131072\nroll_narrow=0\n'
    printf 'simulator_pgo_required=%s\nreal_verilator=%s\n' \
      "${APU_SIM_PGO:-1}" "${APU_REAL_VERILATOR:-$VERILATOR}"
    if [[ "$APU_REPO_VERILATOR" == 1 ]]; then
      cat "$APU_VERILATOR_HOME/source.id"
      sha256sum "$APU_VERILATOR_HOME/bin/verilator_bin"
      if python3 "$APU_ROOT/verif/tb/apu/apu_vlt_policy.py" --check "$APU_VERILATOR_HOME"; then
        # The old compiler-only report's simulatorPgo=false describes its
        # training scope, not the independently provisioned simulator image.
        python3 - "$APU_VERILATOR_HOME/pgo.json" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
report.pop('simulatorPgo', None)
print(json.dumps({'compilerPgo': report}, indent=2))
PY
      else
        printf 'compiler_pgo=unverified\n'
      fi
    else
      printf 'compiler_pgo=external-unverified\n'
    fi
  } > "$OUT/toolchain.txt"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  apu_build_verilator
  exit "$?"
fi
