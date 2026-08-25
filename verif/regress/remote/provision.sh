#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Remote provisioner for the testharness proxy. Runs ON the remote host.
# Idempotent: every step is stamped, so re-running costs one `test -f`.
#
# Installs only what is missing:
#   * base build deps           (apt, or skipped if already present)
#   * verilator $TH_VERILATOR_VERSION  (source build, pinned)
#   * riscv-none-elf-gcc xpack  (tarball, pinned)
#   * spike                     (rsync'd from the client, or source build)
#
# Env (exported by the proxy):
#   TH_ROOT                 install root, e.g. /opt/testharness
#   TH_VERILATOR_VERSION    e.g. v5.008
#   TH_XPACK_GCC_VERSION    e.g. 14.2.0-3
#   TH_XPACK_URL            full tarball URL

set -euo pipefail

TH_ROOT="${TH_ROOT:-/opt/testharness}"
TOOLS="$TH_ROOT/toolchains"
CACHE="$TH_ROOT/cache"
STAMPS="$TH_ROOT/.stamps"

log() { echo "[provision] $*"; }

# --- sudo shim: use sudo only when not root and only if available -----------
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
elif command -v sudo >/dev/null 2>&1; then
  SUDO="sudo -n"
else
  SUDO=""
fi

ensure_dirs() {
  for d in "$TH_ROOT" "$TOOLS" "$CACHE" "$STAMPS" "$TH_ROOT/repo" "$TH_ROOT/work" "$TH_ROOT/runs"; do
    if [ ! -d "$d" ]; then
      if ! mkdir -p "$d" 2>/dev/null; then
        $SUDO mkdir -p "$d"
        $SUDO chown -R "$(id -u):$(id -g)" "$TH_ROOT"
      fi
    fi
  done
  # Make sure we own the tree even if it pre-existed as root.
  [ -w "$TH_ROOT" ] || $SUDO chown -R "$(id -u):$(id -g)" "$TH_ROOT"
}

stamped() { [ -f "$STAMPS/$1" ]; }
stamp()   { touch "$STAMPS/$1"; }

# --- base packages ----------------------------------------------------------
install_base() {
  if stamped base; then log "base: ok (stamped)"; return; fi
  local missing=()
  for t in g++ make git python3 perl autoconf flex bison ccache mold; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  # header-only checks
  [ -e /usr/include/zlib.h ] || missing+=("zlib1g-dev")
  if [ ${#missing[@]} -eq 0 ]; then
    log "base: all present"; stamp base; return
  fi
  log "base: missing -> ${missing[*]}"
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq \
      build-essential git python3 python3-pip perl \
      autoconf flex bison ccache mold \
      libgoogle-perftools-dev numactl \
      zlib1g-dev libfl2 libfl-dev \
      help2man device-tree-compiler || true
  elif command -v dnf >/dev/null 2>&1; then
    $SUDO dnf install -y gcc-c++ make git python3 perl autoconf flex bison ccache mold zlib-devel dtc || true
  else
    log "base: no known package manager; continuing and hoping for the best"
  fi
  stamp base
}

# --- verilator (pinned, source build) ---------------------------------------
install_verilator() {
  local ver="${TH_VERILATOR_VERSION:-v5.008}"
  local dst="$TOOLS/verilator-$ver"
  if [ -x "$dst/bin/verilator" ]; then
    log "verilator $ver: ok"
    return
  fi
  log "verilator $ver: building from source (one time; this takes several minutes)"
  local src="$CACHE/verilator-src"
  rm -rf "$src"
  git clone --depth 1 --branch "$ver" https://github.com/verilator/verilator "$src"
  (
    cd "$src"
    log "verilator $ver: autoconf"
    autoconf
    log "verilator $ver: configure -> $dst"
    ./configure --prefix="$dst"
    local jobs="${TH_BUILD_JOBS:-$(nproc)}"
    # Cap jobs to avoid memory exhaustion on small remote hosts.
    if [ "$jobs" -gt 8 ] 2>/dev/null; then
      jobs=8
    fi
    log "verilator $ver: make -j$jobs"
    make -j"$jobs"
    log "verilator $ver: make install"
    make install
  )
  rm -rf "$src"
  log "verilator $ver: installed at $dst"
}

# --- riscv gcc (xpack tarball, pinned) --------------------------------------
install_riscv_gcc() {
  local ver="${TH_XPACK_GCC_VERSION:-14.2.0-3}"
  local dst="$TOOLS/xpack-riscv-none-elf-gcc-$ver"
  if [ -x "$dst/bin/riscv-none-elf-gcc" ]; then
    log "riscv gcc $ver: ok"
    return
  fi
  local url="${TH_XPACK_URL:?TH_XPACK_URL not set}"
  local tgz="$CACHE/xpack-riscv-$ver.tar.gz"
  log "riscv gcc $ver: downloading"
  [ -f "$tgz" ] || curl -fsSL "$url" -o "$tgz"
  mkdir -p "$TOOLS"
  tar -xzf "$tgz" -C "$TOOLS"
  [ -x "$dst/bin/riscv-none-elf-gcc" ] || {
    log "riscv gcc: unexpected tarball layout under $TOOLS"; ls -1 "$TOOLS"; exit 1;
  }
  log "riscv gcc $ver: installed at $dst"
}

# --- spike ------------------------------------------------------------------
# Preferred path: the client rsyncs its prebuilt spike into $TOOLS/spike.
# Fall back to a source build only if that is absent.
install_spike() {
  local dst="$TOOLS/spike"
  if [ -e "$dst/lib/libfesvr.so" ] || [ -e "$dst/lib/libfesvr.a" ]; then
    log "spike: ok (client-provided or previously built)"
    return
  fi
  log "spike: building from source (one time; this takes several minutes)"
  local src="$CACHE/riscv-isa-sim"
  rm -rf "$src"
  git clone --depth 1 https://github.com/riscv-software-src/riscv-isa-sim "$src"
  (
    mkdir -p "$src/build" && cd "$src/build"
    log "spike: configure -> $dst"
    ../configure --prefix="$dst"
    local jobs="${TH_BUILD_JOBS:-$(nproc)}"
    if [ "$jobs" -gt 8 ] 2>/dev/null; then
      jobs=8
    fi
    log "spike: make -j$jobs"
    make -j"$jobs"
    log "spike: make install"
    make install
  )
  rm -rf "$src"
}

# --- env file consumed by every later remote step ---------------------------
write_env() {
  cat >"$TH_ROOT/env.sh" <<EOF
# generated by provision.sh — source before any build/run
export TH_ROOT="$TH_ROOT"
export CVA6_REPO_DIR="$TH_ROOT/repo"
export RISCV="$TOOLS/xpack-riscv-none-elf-gcc-${TH_XPACK_GCC_VERSION:-14.2.0-3}"
export SPIKE_INSTALL_DIR="$TOOLS/spike"
export VLT_HOME="$TOOLS/verilator-${TH_VERILATOR_VERSION:-v5.008}"
export VERILATOR_ROOT="\$VLT_HOME/share/verilator"
export LD_LIBRARY_PATH="\$SPIKE_INSTALL_DIR/lib:\${LD_LIBRARY_PATH:-}"
export PATH="\$VLT_HOME/bin:\$RISCV/bin:\$SPIKE_INSTALL_DIR/bin:\$PATH"
export CXX=g++ CC=gcc
EOF
  log "wrote $TH_ROOT/env.sh"
}

main() {
  ensure_dirs
  write_env  # skeleton env.sh first so builds can fail clearly if interrupted
  install_base
  install_verilator
  install_riscv_gcc
  install_spike
  write_env  # final env.sh with actual discovered versions
  log "provision complete"
  log "  verilator: $("$TOOLS/verilator-${TH_VERILATOR_VERSION:-v5.008}/bin/verilator" --version 2>&1 | head -1)"
  log "  riscv gcc: $("$TOOLS/xpack-riscv-none-elf-gcc-${TH_XPACK_GCC_VERSION:-14.2.0-3}/bin/riscv-none-elf-gcc" --version 2>&1 | head -1)"
}

main "$@"
