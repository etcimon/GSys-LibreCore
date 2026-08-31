#!/usr/bin/env bash
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# install-formal.sh - Build/install the bounded-formal toolchain (Yosys with the
# integrated sv-elab/slang frontend, plus SymbiYosys and a solver) into a managed
# prefix for build-platform.
#
# Invoked by tooling/recipes.ts installFormal on Linux/macOS natively and on
# Windows via WSL (`wsl -e bash ...`), mirroring install-spike.sh.
#
# Why from source rather than a distro package:
#   Ubuntu 24.04 ships Yosys 0.33, whose classic Verilog frontend cannot parse
#   `core/include/config_pkg.sv` -- it rejects the user-defined-type cast
#   `ai_cfg_t'(0)` with "unexpected TOK_USER_TYPE", and it also rejects
#   package-to-package `import` inside a package body. Every formal task in this
#   repo that touches a config package therefore needs a real SystemVerilog
#   frontend. That frontend is sv-elab (formerly yosys-slang), which is
#   INTEGRATED INTO YOSYS FROM v0.67 -- no plugin, no separate .so, no
#   `plugin -i slang` line. Distro packages are years behind that, so a source
#   build is the only way to get a working `read_slang` on a stock host.
#
# Environment:
#   FORMAL_INSTALL_DIR  install prefix (required for managed installs)
#   FORMAL_BUILD_DIR    build/source dir (default: $HOME/.cache/g6lc-formal)
#   FORMAL_YOSYS_REF    yosys git ref to build (default: main)
#   FORMAL_SBY_REF      SymbiYosys git ref (default: main)
#   NUM_JOBS            parallel build jobs (default: nproc)
#   FORMAL_FORCE=1      rebuild even if $FORMAL_INSTALL_DIR/bin/yosys exists
#   FORMAL_SKIP_DEPS=1  do not attempt to install OS prerequisites
#   FORMAL_WITH_SOLVERS distro solver packages to add (default: "z3")
#   FORMAL_ADOPT_FROM   if it holds bin/yosys with read_slang, copy that tree
#                       instead of building (same idea as SPIKE_ADOPT_FROM)
#
# Notes:
#   - Build under $HOME, never on /mnt/* : DrvFs is slow and, with an 8-core
#     ninja plus a solver, was observed to destabilise the WSL VM outright.
#   - The build needs C++20 (GCC >= 11) and CMake >= 3.28; Yosys main is
#     CMake+Ninja, not the old plain Makefile.
#   - Engines: abc ships inside Yosys, so `abc pdr` needs no external solver and
#     is the fast path for bit-level combinational contracts. z3 is installed as
#     the word-level fallback; the .sby files race both.

set -euo pipefail

log() { echo "[install-formal] $*"; }
die() { echo "[install-formal] ERROR: $*" >&2; exit 1; }

NUM_JOBS="${NUM_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)}"
FORMAL_FORCE="${FORMAL_FORCE:-0}"
FORMAL_SKIP_DEPS="${FORMAL_SKIP_DEPS:-0}"
FORMAL_YOSYS_REF="${FORMAL_YOSYS_REF:-main}"
FORMAL_SBY_REF="${FORMAL_SBY_REF:-main}"
FORMAL_WITH_SOLVERS="${FORMAL_WITH_SOLVERS:-z3}"

[[ -n "${FORMAL_INSTALL_DIR:-}" ]] || die "FORMAL_INSTALL_DIR must be set"
BUILD_ROOT="${FORMAL_BUILD_DIR:-$HOME/.cache/g6lc-formal}"

if [[ "$FORMAL_FORCE" != "1" && -x "$FORMAL_INSTALL_DIR/bin/yosys" && -x "$FORMAL_INSTALL_DIR/bin/sby" ]]; then
  log "already installed: $FORMAL_INSTALL_DIR/bin/{yosys,sby}"
  "$FORMAL_INSTALL_DIR/bin/yosys" -V || true
  exit 0
fi

case "$BUILD_ROOT" in
  /mnt/*) log "WARNING: build dir is on a mounted host filesystem ($BUILD_ROOT)."
          log "         This is slow and has been observed to destabilise WSL." ;;
esac

# --- adopt an existing usable install ---------------------------------------
# A host may already carry a suitable Yosys (a previous source build, or a
# distro that has caught up). Adopting it is minutes cheaper than rebuilding,
# but only if it actually has the integrated frontend -- the capability is the
# criterion, never the version string alone.
FORMAL_ADOPT_FROM="${FORMAL_ADOPT_FROM:-/usr/local}"
if [[ "$FORMAL_FORCE" != "1" && -x "$FORMAL_ADOPT_FROM/bin/yosys" && -x "$FORMAL_ADOPT_FROM/bin/sby" ]]; then
  if "$FORMAL_ADOPT_FROM/bin/yosys" -p "help read_slang" >/dev/null 2>&1; then
    log "adopting existing install at $FORMAL_ADOPT_FROM (has read_slang)"
    mkdir -p "$FORMAL_INSTALL_DIR"
    # yosys needs its share/ tree (techlibs, and sby's python3 modules) next to
    # the binary, so copy both rather than symlinking bin/ alone.
    cp -a "$FORMAL_ADOPT_FROM/bin/." "$FORMAL_INSTALL_DIR/bin/" 2>/dev/null || {
      mkdir -p "$FORMAL_INSTALL_DIR/bin"
      for b in yosys yosys-abc yosys-smtbmc yosys-witness sby yosys-config; do
        [[ -e "$FORMAL_ADOPT_FROM/bin/$b" ]] && cp -a "$FORMAL_ADOPT_FROM/bin/$b" "$FORMAL_INSTALL_DIR/bin/"
      done
    }
    mkdir -p "$FORMAL_INSTALL_DIR/share"
    cp -a "$FORMAL_ADOPT_FROM/share/yosys" "$FORMAL_INSTALL_DIR/share/" 2>/dev/null || true
    log "adopted: $("$FORMAL_INSTALL_DIR/bin/yosys" -V)"
    exit 0
  fi
  log "not adopting $FORMAL_ADOPT_FROM: its yosys has no read_slang"
fi

# --- prerequisites ----------------------------------------------------------
install_deps() {
  [[ "$FORMAL_SKIP_DEPS" == "1" ]] && { log "skipping OS prerequisites"; return 0; }
  if command -v apt-get >/dev/null 2>&1; then
    local pkgs=(build-essential cmake ninja-build bison flex libreadline-dev
                gawk tcl-dev libffi-dev git pkg-config zlib1g-dev
                libboost-system-dev libboost-filesystem-dev python3 python3-click)
    # shellcheck disable=SC2206
    pkgs+=(${FORMAL_WITH_SOLVERS})

    # Pick the privilege escalation once. `sudo -n` so a host without
    # passwordless sudo fails fast instead of blocking on a prompt.
    local SUDO=""
    if [[ "$(id -u)" != "0" ]]; then
      if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        SUDO="sudo -n"
      else
        log "WARNING: not root and no passwordless sudo; install prerequisites manually:"
        log "         ${pkgs[*]}"
        return 0
      fi
    fi

    # A stale package index makes every install fail with "Unable to locate
    # package". Refresh best-effort; a failure here is not fatal because the
    # index may already be current.
    log "apt-get update (best effort)"
    DEBIAN_FRONTEND=noninteractive $SUDO apt-get update -qq >/dev/null 2>&1 || \
      log "WARNING: apt-get update failed; continuing with the existing index"

    # One package at a time. A single unavailable or held package aborts a whole
    # apt transaction, which would silently drop every other prerequisite and
    # leave the real failure to surface later as "cmake not found".
    local missing=()
    for p in "${pkgs[@]}"; do
      if DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -q "$p" >/dev/null 2>&1; then
        continue
      fi
      missing+=("$p")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
      log "WARNING: could not install: ${missing[*]}"
      log "         (continuing; the toolchain check below reports what is fatal)"
    else
      log "prerequisites present"
    fi
  elif command -v brew >/dev/null 2>&1; then
    log "brew install: cmake ninja bison flex readline tcl-tk libffi z3"
    brew install cmake ninja bison flex readline tcl-tk libffi z3 || \
      log "WARNING: some brew formulae failed; continuing"
  else
    log "WARNING: no apt-get or brew; assuming prerequisites are present"
  fi
}

check_toolchain() {
  local cmake_ver gxx_ver
  command -v cmake >/dev/null 2>&1 || die \
    "cmake not found (need >= 3.28). Install it, or re-run with FORMAL_SKIP_DEPS=0 on a host with passwordless sudo."
  command -v ninja >/dev/null 2>&1 || command -v ninja-build >/dev/null 2>&1 || die \
    "ninja not found (Yosys main is a CMake+Ninja build)"
  cmake_ver="$(cmake --version | head -1 | awk '{print $3}')"
  log "cmake $cmake_ver"
  if command -v g++ >/dev/null 2>&1; then
    gxx_ver="$(g++ -dumpversion | cut -d. -f1)"
    log "g++ $gxx_ver"
    [[ "$gxx_ver" -ge 11 ]] || die "g++ >= 11 required for C++20 (slang); found $gxx_ver"
  fi
}

# --- yosys (with integrated sv-elab/slang) ----------------------------------
build_yosys() {
  local src="$BUILD_ROOT/yosys"
  mkdir -p "$BUILD_ROOT"
  if [[ -d "$src/.git" ]]; then
    log "updating yosys source ($FORMAL_YOSYS_REF)"
    git -C "$src" fetch --depth 1 origin "$FORMAL_YOSYS_REF"
    git -C "$src" checkout --force FETCH_HEAD
  else
    log "cloning yosys ($FORMAL_YOSYS_REF)"
    rm -rf "$src"
    git clone --depth 1 --branch "$FORMAL_YOSYS_REF" \
      https://github.com/YosysHQ/yosys.git "$src" 2>/dev/null || \
      git clone --depth 1 https://github.com/YosysHQ/yosys.git "$src"
  fi

  # abc, slang, sv-elab, fmt, cxxopts, tomlplusplus, boost_regex, symfpu.
  log "fetching submodules (includes libs/slang and frontends/slang/lib)"
  git -C "$src" submodule update --init --depth 1 --recursive

  [[ -d "$src/frontends/slang" ]] || die \
    "this yosys has no frontends/slang; need >= v0.67 for integrated sv-elab"

  log "configuring yosys (Release, Ninja, prefix=$FORMAL_INSTALL_DIR)"
  cmake -S "$src" -B "$src/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DYOSYS_ENABLE_UNIT_TESTS=OFF \
    -DCMAKE_INSTALL_PREFIX="$FORMAL_INSTALL_DIR"

  log "building yosys with $NUM_JOBS jobs"
  cmake --build "$src/build" -j "$NUM_JOBS"
  cmake --install "$src/build"
}

# --- SymbiYosys -------------------------------------------------------------
build_sby() {
  local src="$BUILD_ROOT/sby"
  if [[ -d "$src/.git" ]]; then
    log "updating sby source"
    git -C "$src" fetch --depth 1 origin "$FORMAL_SBY_REF"
    git -C "$src" checkout --force FETCH_HEAD
  else
    log "cloning SymbiYosys"
    rm -rf "$src"
    git clone --depth 1 --branch "$FORMAL_SBY_REF" \
      https://github.com/YosysHQ/sby.git "$src" 2>/dev/null || \
      git clone --depth 1 https://github.com/YosysHQ/sby.git "$src"
  fi
  # sby is a Python program; its Makefile installs the driver plus the
  # share/yosys/python3 support modules next to the yosys it will drive.
  log "installing sby into $FORMAL_INSTALL_DIR"
  make -C "$src" install PREFIX="$FORMAL_INSTALL_DIR"
}

install_deps
check_toolchain
build_yosys
build_sby

# --- verify the capability, not just the file -------------------------------
YOSYS="$FORMAL_INSTALL_DIR/bin/yosys"
SBY="$FORMAL_INSTALL_DIR/bin/sby"
[[ -x "$YOSYS" ]] || die "yosys did not install to $YOSYS"
[[ -x "$SBY" ]] || die "sby did not install to $SBY"

log "installed: $("$YOSYS" -V)"
log "installed: $("$SBY" --version 2>&1 | head -1)"

# read_slang must exist, or every config_pkg-touching task will fail at parse.
if "$YOSYS" -p "help read_slang" >/dev/null 2>&1; then
  log "read_slang: available (integrated sv-elab frontend)"
else
  die "read_slang missing: this yosys lacks the integrated slang frontend"
fi

# abc is the fast engine for bit-level contracts; report whether z3 is present.
if command -v z3 >/dev/null 2>&1; then
  log "solver: $(z3 --version)"
else
  log "solver: z3 not on PATH (abc engines still work; z3 is the fallback)"
fi

log "done. Prefix: $FORMAL_INSTALL_DIR"
