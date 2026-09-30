#!/usr/bin/env bash
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# install-verilator.sh — Build/install the PATCHED pinned Verilator into a
# managed prefix for build-platform.
#
# Invoked by tooling/recipes.ts installVerilator on Linux/macOS natively and on
# Windows via WSL (`wsl -e bash ...`), mirroring install-spike.sh. CI
# (.github/workflows/ci.yml rtl-lint) reaches it through
# `./build.sh tools install verilator`, so there is exactly one build recipe.
#
# Why not verif/regress/install-verilator.sh (the upstream OpenHW script):
#   1. It runs `git apply $PATCH || true` — a patch that fails to apply builds a
#      STOCK Verilator without a word, and the gate then runs a different tool
#      than the one the fixes were written for. Here every
#      verif/regress/verilator-*.patch MUST apply, and the installed tree is
#      verified to carry every added header line before the script reports ok.
#   2. It runs Verilator's full `make test` (tens of minutes; not our gate).
#   The source, tag and patch set are otherwise identical, so the tool that
#   comes out is the same one the regress scripts expect (VERILATOR_INSTALL_DIR).
#
# Environment:
#   VERILATOR_INSTALL_DIR  install prefix (required for managed installs)
#   VERILATOR_TAG          git tag to build (default: v5.008 — the platform pin)
#   VERILATOR_REPO         git remote (default: https://github.com/verilator/verilator.git)
#   VERILATOR_BUILD_DIR    source/build dir (default: $HOME/.cache/g6lc-verilator/<tag>)
#   VERILATOR_PATCH_DIR    directory holding verilator-*.patch (default: <repo>/verif/regress)
#   NUM_JOBS               parallel make jobs (default: nproc)
#   VERILATOR_FORCE=1      rebuild even if the prefix already has a PATCHED tool
#   VERILATOR_SKIP_DEPS=1  do not attempt to apt-get the build prerequisites
#   VERILATOR_ADOPT_FROM   a prefix to copy instead of building — accepted ONLY
#                          if it passes the same patch verification
#   CVA6_REPO_DIR          repo root (used to locate the patch dir)
#
# Notes:
#   - Build under $HOME, never on /mnt/* (DrvFs is slow for the many small
#     objects Verilator compiles).
#   - `verilator --version` prints "(mod)" for a tree with local modifications;
#     that is expected here and is one of the two post-install checks.

set -euo pipefail

log() { echo "[install-verilator] $*"; }
die() { echo "[install-verilator] ERROR: $*" >&2; exit 1; }

NUM_JOBS="${NUM_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)}"
VERILATOR_FORCE="${VERILATOR_FORCE:-0}"
VERILATOR_SKIP_DEPS="${VERILATOR_SKIP_DEPS:-0}"
VERILATOR_TAG="${VERILATOR_TAG:-v5.008}"
VERILATOR_REPO="${VERILATOR_REPO:-https://github.com/verilator/verilator.git}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CVA6_REPO_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
PATCH_DIR="${VERILATOR_PATCH_DIR:-${REPO_ROOT}/verif/regress}"
[[ -n "${VERILATOR_INSTALL_DIR:-}" ]] || VERILATOR_INSTALL_DIR="${REPO_ROOT}/build-platform/workspace/tooling/verilator-${VERILATOR_TAG}"
BUILD_DIR="${VERILATOR_BUILD_DIR:-$HOME/.cache/g6lc-verilator/${VERILATOR_TAG}}"

# The upstream variable collides with Verilator's own build.
unset VERILATOR_ROOT || true

shopt -s nullglob
PATCHES=("${PATCH_DIR}"/verilator-*.patch)
log "tag=${VERILATOR_TAG} prefix=${VERILATOR_INSTALL_DIR} patches=${#PATCHES[@]}"
for p in "${PATCHES[@]}"; do log "  patch: ${p}"; done

# --- verification: does an installed prefix carry every patch? --------------
# For every file a patch touches under include/, each added line must be
# present verbatim in <prefix>/share/verilator/include/<file>. Patches to
# src/ cannot be checked against the binary; `--version` "(mod)" covers those
# when the tree was built here.
verify_prefix() {
  local prefix="$1" bin="$1/bin/verilator_bin" inc="$1/share/verilator/include"
  [[ -x "${bin}" ]] || { log "verify: ${bin} missing"; return 1; }
  local ver
  ver="$("${bin}" --version 2>/dev/null || true)"
  log "verify: ${ver}"
  local failed=0 checked=0
  for p in "${PATCHES[@]}"; do
    local file="" line
    while IFS= read -r line; do
      case "${line}" in
        "+++ b/include/"*) file="${inc}/${line#+++ b/include/}" ;;
        "+++ "*) file="" ;;
        "+++"*) ;;
        "+"*)
          [[ -n "${file}" ]] || continue
          local added="${line#+}"
          [[ -n "${added// /}" ]] || continue
          checked=$((checked + 1))
          if ! grep -qF -- "${added}" "${file}" 2>/dev/null; then
            log "verify: MISSING in ${file}: ${added}"
            failed=1
          fi
          ;;
      esac
    done < "${p}"
  done
  if [[ ${#PATCHES[@]} -gt 0 && "${ver}" != *"(mod)"* ]]; then
    log "verify: --version lacks '(mod)': tree was built without local modifications"
    failed=1
  fi
  if [[ "${failed}" == "0" ]]; then
    log "verify: ok (${checked} patched header line(s) present, ${#PATCHES[@]} patch(es))"
    return 0
  fi
  return 1
}

# --- already installed (and patched)? ---------------------------------------
if [[ "${VERILATOR_FORCE}" != "1" && -x "${VERILATOR_INSTALL_DIR}/bin/verilator_bin" ]]; then
  if verify_prefix "${VERILATOR_INSTALL_DIR}"; then
    log "already installed: ${VERILATOR_INSTALL_DIR}"
    exit 0
  fi
  die "existing prefix ${VERILATOR_INSTALL_DIR} is NOT the patched Verilator; remove it or re-run with VERILATOR_FORCE=1"
fi

# --- adopt an existing prefix, only if it is the patched tool -----------------
if [[ -n "${VERILATOR_ADOPT_FROM:-}" && -x "${VERILATOR_ADOPT_FROM}/bin/verilator_bin" ]]; then
  if verify_prefix "${VERILATOR_ADOPT_FROM}"; then
    log "adopting patched Verilator from ${VERILATOR_ADOPT_FROM} → ${VERILATOR_INSTALL_DIR}"
    mkdir -p "${VERILATOR_INSTALL_DIR}"
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --delete "${VERILATOR_ADOPT_FROM}/" "${VERILATOR_INSTALL_DIR}/"
    else
      cp -a "${VERILATOR_ADOPT_FROM}/." "${VERILATOR_INSTALL_DIR}/"
    fi
    verify_prefix "${VERILATOR_INSTALL_DIR}" || die "adopt failed verification"
    exit 0
  fi
  log "not adopting ${VERILATOR_ADOPT_FROM}: it is not the patched tool; building from source"
fi

# --- prerequisites ------------------------------------------------------------
if [[ "${VERILATOR_SKIP_DEPS}" != "1" ]] && command -v apt-get >/dev/null 2>&1; then
  missing=()
  for c in git autoconf flex bison make g++ help2man; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  # libfl-dev has no command to probe; verilator_bin links -lfl.
  [[ -e /usr/lib/x86_64-linux-gnu/libfl.so || -e /usr/lib/libfl.so || -e /usr/lib/aarch64-linux-gnu/libfl.so ]] || missing+=("libfl-dev")
  if [[ ${#missing[@]} -gt 0 ]]; then
    SUDO=""
    [[ "$(id -u)" == "0" ]] || SUDO="sudo -n"
    log "installing prerequisites: ${missing[*]} (autoconf bison flex help2man libfl-dev libfl2 zlib1g-dev)"
    ${SUDO} apt-get update -qq || log "apt-get update failed (continuing)"
    ${SUDO} apt-get install -y --no-install-recommends autoconf bison flex help2man libfl-dev libfl2 zlib1g-dev g++ make git \
      || log "apt-get install failed; continuing with what is on the host"
  fi
fi
for c in git autoconf flex bison make g++; do
  command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
done

# --- source at the pinned tag -------------------------------------------------
mkdir -p "$(dirname "${BUILD_DIR}")"
if [[ -d "${BUILD_DIR}/.git" ]]; then
  log "reusing source in ${BUILD_DIR}"
  git -C "${BUILD_DIR}" fetch --depth 1 origin "refs/tags/${VERILATOR_TAG}:refs/tags/${VERILATOR_TAG}" 2>/dev/null || true
  git -C "${BUILD_DIR}" reset -q --hard "${VERILATOR_TAG}"
  git -C "${BUILD_DIR}" clean -qfdx
else
  rm -rf "${BUILD_DIR}"
  log "clone ${VERILATOR_REPO} @ ${VERILATOR_TAG} → ${BUILD_DIR}"
  git clone --quiet --branch "${VERILATOR_TAG}" --depth 1 "${VERILATOR_REPO}" "${BUILD_DIR}"
fi
cd "${BUILD_DIR}"

# --- custom fixes: every patch must apply --------------------------------------
for p in "${PATCHES[@]}"; do
  log "apply $(basename "${p}")"
  git apply --check --verbose "${p}" || die "patch does not apply cleanly to ${VERILATOR_TAG}: ${p}"
  git apply --verbose "${p}"
done
if [[ ${#PATCHES[@]} -gt 0 ]]; then
  log "modified files after patching:"
  git status --short | sed 's/^/  /'
fi

# --- build + install ------------------------------------------------------------
log "autoconf + configure --prefix=${VERILATOR_INSTALL_DIR}"
autoconf
./configure --prefix="${VERILATOR_INSTALL_DIR}"
log "make -j${NUM_JOBS}"
make -j"${NUM_JOBS}"
rm -rf "${VERILATOR_INSTALL_DIR:?}"
make install

verify_prefix "${VERILATOR_INSTALL_DIR}" || die "installed Verilator failed patch verification"
log "installed: ${VERILATOR_INSTALL_DIR}/bin/verilator_bin"
