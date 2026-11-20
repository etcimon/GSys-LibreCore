#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Build a host GCC (C/C++ only) for the testharness builder into a toolchain
# prefix — a newer cc1/cc1plus than the distro gcc-13 generic build, compiled
# for the host uarch and (by default) profile-guided, so every cold model
# build gets a faster compiler.
#
# Runs ON the builder (no root needed; everything lives under TH_ROOT).
# Sibling of install-verilator-g6lc.sh. The result is selected per build —
# never globally, because a different compiler is a different instrument and
# a model built with it needs re-qualification before it carries evidence.
#
#   bash build-platform/scripts/install-gcc.sh        # on the builder, repo synced
#
# Env:
#   GCC_VER=16.2.0            upstream release (default: current stable;
#                             15.3.0 is the mature fallback)
#   GCC_WITH_ARCH=x86-64-v3   --with-arch: the -march this gcc defaults to for
#                             programs it compiles. Matches the harness recipe
#                             floor; the harnesses still pass -march explicitly,
#                             so this only covers TUs compiled without one.
#   GCC_WITH_TUNE=znver4       --with-tune (EPYC 4244P = Zen 4; set generic or
#                             the right uarch on other hosts)
#   GCC_CFLAGS="-O2 -march=native -pipe"  flags for building GCC itself
#   GCC_PROFILED=1             make profiledbootstrap (slowest install path,
#                             fastest resulting compiler); 0 = --disable-bootstrap
#                             + plain make (fastest install)
#   GCC_JOBS=$(nproc)          build parallelism
#   GCC_MIRRORS="..."          space-separated GNU mirror bases to try
#   GCC_PREFIX=...             install prefix (default derived below)
#
# Select it per build — env.sh pins the distro gcc, but a bare gcc/g++ counts
# as unset and an explicit CC/CXX path still wins:
#   testharness_proxy.py build B \
#     --env SOFT_LADDER_BUILD_TOOLCHAIN=/opt/testharness/toolchains/gcc-16.2.0-znver4
# or on the builder directly:
#   SOFT_LADDER_BUILD_TOOLCHAIN=<prefix> bash verif/regress/soft-ladder-build-harness.sh B

set -euo pipefail
TH_ROOT="${TH_ROOT:-/opt/testharness}"
GCC_VER="${GCC_VER:-16.2.0}"
GCC_WITH_ARCH="${GCC_WITH_ARCH:-x86-64-v3}"
GCC_WITH_TUNE="${GCC_WITH_TUNE:-znver4}"
GCC_CFLAGS="${GCC_CFLAGS:--O2 -march=native -pipe}"
GCC_PROFILED="${GCC_PROFILED:-1}"
GCC_JOBS="${GCC_JOBS:-$(nproc)}"
GCC_MIRRORS="${GCC_MIRRORS:-https://ftpmirror.gnu.org/gcc https://mirrors.kernel.org/gnu/gcc https://ftp.gnu.org/gnu/gcc}"
PREFIX="${GCC_PREFIX:-$TH_ROOT/toolchains/gcc-$GCC_VER-$GCC_WITH_TUNE}"
SRC_DIR="$TH_ROOT/src/gcc-$GCC_VER"
BUILD_DIR="$TH_ROOT/build/gcc-$GCC_VER-$GCC_WITH_TUNE"
CACHE_DIR="$TH_ROOT/cache"
MARKER="$PREFIX/.install-ok"

log() { echo "[install-gcc] $*"; }

# sudo shim (same rule as provision.sh): passwordless sudo only when needed.
if [ "$(id -u)" -eq 0 ]; then SUDO=""
elif command -v sudo >/dev/null 2>&1; then SUDO="sudo -n"
else SUDO=""; fi

# Idempotent: the same version + configure surface already installed is a no-op.
EXPECTED="gcc-$GCC_VER arch=$GCC_WITH_ARCH tune=$GCC_WITH_TUNE profiled=$GCC_PROFILED cflags=[$GCC_CFLAGS]"
if [[ -x "$PREFIX/bin/gcc" && -x "$PREFIX/bin/g++" && -f "$MARKER" ]] \
   && [[ "$(cat "$MARKER")" == "$EXPECTED" ]]; then
  log "already installed ($EXPECTED); skipping"
  "$PREFIX/bin/g++" --version | head -1
  exit 0
fi

# --- toolchain prerequisites -------------------------------------------------
missing=()
for t in gcc g++ make tar curl xz; do
  command -v "$t" >/dev/null 2>&1 || missing+=("tool:$t")
done
# The -dev headers must resolve through the real preprocessor (multiarch dirs
# like /usr/include/x86_64-linux-gnu count).
for hdr in gmp.h mpfr.h mpc.h isl/ctx.h zlib.h; do
  printf '#include <%s>\n' "$hdr" | gcc -E -x c - >/dev/null 2>&1 || missing+=("header:$hdr")
done
for t in makeinfo bison flex gawk; do
  command -v "$t" >/dev/null 2>&1 || missing+=("tool:$t")
done
if [ ${#missing[@]} -gt 0 ]; then
  log "missing deps: ${missing[*]}"
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq build-essential \
      libgmp-dev libmpfr-dev libmpc-dev libisl-dev zlib1g-dev \
      texinfo bison flex gawk xz-utils
  else
    log "no apt-get; install the -dev packages for gmp/mpfr/mpc/isl/zlib plus texinfo/bison/flex/gawk manually"
  fi
else
  log "deps: ok"
fi

# --- source ------------------------------------------------------------------
TGZ="$CACHE_DIR/gcc-$GCC_VER.tar.xz"
mkdir -p "$CACHE_DIR" "$TH_ROOT/src"
if [ ! -f "$TGZ" ]; then
  ok=0
  for m in $GCC_MIRRORS; do
    url="$m/gcc-$GCC_VER/gcc-$GCC_VER.tar.xz"
    log "download: $url"
    if curl -fsSL --retry 2 -o "$TGZ" "$url" 2>/dev/null; then ok=1; break; fi
    rm -f "$TGZ"
  done
  [ "$ok" = 1 ] || { log "all mirrors failed for gcc-$GCC_VER.tar.xz"; exit 1; }
fi
if [ ! -f "$SRC_DIR/gcc/BASE-VER" ]; then
  log "extract: $TGZ -> $TH_ROOT/src"
  tar -xJf "$TGZ" -C "$TH_ROOT/src"
fi
[ -f "$SRC_DIR/configure" ] || { log "missing $SRC_DIR/configure"; exit 1; }

# --- configure / build / install ---------------------------------------------
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
make distclean >/dev/null 2>&1 || true
CONF_EXTRA=()
if [ "$GCC_PROFILED" != "1" ]; then CONF_EXTRA+=(--disable-bootstrap); fi
log "configure -> $PREFIX (arch=$GCC_WITH_ARCH tune=$GCC_WITH_TUNE profiled=$GCC_PROFILED)"
"$SRC_DIR/configure" \
  --prefix="$PREFIX" \
  --enable-languages=c,c++ \
  --with-arch="$GCC_WITH_ARCH" \
  --with-tune="$GCC_WITH_TUNE" \
  --disable-multilib \
  --disable-libstdcxx-debug \
  ${CONF_EXTRA[@]+"${CONF_EXTRA[@]}"} \
  CFLAGS="$GCC_CFLAGS" CXXFLAGS="$GCC_CFLAGS" \
  > configure.log 2>&1 || {
    log "configure FAILED; tail of $BUILD_DIR/configure.log:"
    tail -30 configure.log; exit 1; }

if [ "$GCC_PROFILED" = "1" ]; then
  log "make -j$GCC_JOBS profiledbootstrap (bootstrap with profile feedback; the long path)"
  make -j"$GCC_JOBS" profiledbootstrap > make.log 2>&1 || {
    log "profiledbootstrap FAILED; tail of $BUILD_DIR/make.log:"
    tail -30 make.log; exit 1; }
else
  log "make -j$GCC_JOBS (single stage; --disable-bootstrap)"
  make -j"$GCC_JOBS" > make.log 2>&1 || {
    log "make FAILED; tail of $BUILD_DIR/make.log:"
    tail -30 make.log; exit 1; }
fi
log "make install -> $PREFIX"
make install > install.log 2>&1 || {
  log "install FAILED; tail of $BUILD_DIR/install.log:"
  tail -30 install.log; exit 1; }

# --- verify -------------------------------------------------------------------
"$PREFIX/bin/gcc" --version | head -1 | sed 's/^/[install-gcc] /'
"$PREFIX/bin/g++" --version | head -1 | sed 's/^/[install-gcc] /'
# Smoke: compile AND run a host C and a C++ binary — catches an install whose
# libstdc++/libc pieces did not land cleanly.
printf 'int main(void){return 0;}\n' > "$BUILD_DIR/smoke.c"
printf '#include <vector>\nint main(){return sizeof(std::vector<int>)>0?0:1;}\n' > "$BUILD_DIR/smoke.cc"
"$PREFIX/bin/gcc" "$BUILD_DIR/smoke.c" -o "$BUILD_DIR/smoke-c" && "$BUILD_DIR/smoke-c"
"$PREFIX/bin/g++" "$BUILD_DIR/smoke.cc" -o "$BUILD_DIR/smoke-cpp" && "$BUILD_DIR/smoke-cpp"
rm -f "$BUILD_DIR/smoke.c" "$BUILD_DIR/smoke.cc" "$BUILD_DIR/smoke-c" "$BUILD_DIR/smoke-cpp"

mkdir -p "$PREFIX"
printf '%s\n' "$EXPECTED" > "$MARKER"
log "installed at $PREFIX"
log "select per build: SOFT_LADDER_BUILD_TOOLCHAIN=$PREFIX"
log "  proxy: testharness_proxy.py build <flavour> --env SOFT_LADDER_BUILD_TOOLCHAIN=$PREFIX"
