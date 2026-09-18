#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Soft-ladder harness builder — one Verilator library per fetch flavour.
#
#   B      = core/fetch_B      (stock core/Flist.cva6 default; +define+G6LC_FETCH_B)
#   legacy = core/smt_legacy   (g1* oracle; derived flist, define dropped)
#
# The two flavours differ by ONE module (the frontend supply). Every non-fetch
# file — including the shared core/smt_legacy/g6lc_* SMT and pipeline helpers —
# is identical, which is what makes the A/B blame table decisive.
# See architecture/multi-threading/soft-ladder/firmware-boot-principles.md (F-P2, §4).
#
# Usage:
#   bash verif/regress/soft-ladder-build-harness.sh legacy
#   bash verif/regress/soft-ladder-build-harness.sh B
#   SOFT_LADDER_VERLIB=work-ver-smt2-fw64-legacy bash ... legacy
#   SOFT_LADDER_BUILD_TARGET=g6lc64_smt2 bash ... legacy
#   SOFT_LADDER_BUILD_CLEAN=1 bash ... legacy     # wipe Mdir first (slow, full rebuild)
#   SOFT_LADDER_BUILD_SEED=work-ver-smt2-fw64 bash ... legacy  # warm-start from a
#                                                 # previous Mdir so C++ objects
#                                                 # that did not change are reused
#
# Cache control:
#   SOFT_LADDER_BUILD_OBJCACHE=ccache            # front C++ compile with ccache
#   SOFT_LADDER_BUILD_CCACHE_DIR=/path/to/cache  # persistent ccache directory
#   SOFT_LADDER_BUILD_CCACHE_MAXSIZE=5G          # default 5 GiB
#   SOFT_LADDER_BUILD_LINKER=mold                # use mold (default: system ld)
#   SOFT_LADDER_BUILD_CXXFLAGS=...               # extra C++ compile flags
#   SOFT_LADDER_BUILD_LDFLAGS=...                # extra C/C++ link flags

# FAST RESUME: the Verilator --Mdir is reused by default, so a re-run only
# re-verilates changed SV and only re-compiles changed C++ objects. Do NOT pass
# SOFT_LADDER_BUILD_CLEAN unless the flavour of an existing Mdir is in doubt.
# Each Mdir records its flavour in .soft-ladder-flavour and the script refuses to
# build a different flavour into it (that is how a stale A/B mix would happen).

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

FETCH="${1:-${SOFT_LADDER_FETCH:-B}}"
case "$FETCH" in
  B|b|fetch_b|fetchb) FETCH=B; DEF_VERLIB=work-ver-smt2-fw64 ;;
  # RETIRED. core/fetch_A/smt_legacy is no longer a buildable supply: selecting it
  # fails elaboration with %Error-PINMISSING at
  # core/fetch_A/smt_legacy/frontend.sv:4003 (missing push_cf_i / cf_resolve_i).
  # Refusing here rather than letting the build fail 30 s later with an error that
  # looks like the caller's fault. Set SOFT_LADDER_ALLOW_RETIRED_FETCH_A=1 only to
  # work on repairing that supply itself.
  legacy|a|A|oracle)
    # echo, not log(): the flavour case runs before log() is defined.
    if [[ "${SOFT_LADDER_ALLOW_RETIRED_FETCH_A:-0}" != 1 ]]; then
      echo "[soft-ladder-build] REFUSING flavour '$FETCH': core/fetch_A/smt_legacy is retired" >&2
      echo "[soft-ladder-build]   and does not elaborate (PINMISSING push_cf_i / cf_resolve_i" >&2
      echo "[soft-ladder-build]   at core/fetch_A/smt_legacy/frontend.sv:4003)." >&2
      echo "[soft-ladder-build]   Use flavour B (fetch_B)." >&2
      echo "[soft-ladder-build]   Override only to repair that supply: SOFT_LADDER_ALLOW_RETIRED_FETCH_A=1" >&2
      exit 2
    fi
    FETCH=legacy; DEF_VERLIB=work-ver-smt2-fw64-legacy ;;
  *) echo "usage: $0 <B|legacy>" >&2; exit 2 ;;
esac

VERLIB="${SOFT_LADDER_VERLIB:-$DEF_VERLIB}"
TARGET="${SOFT_LADDER_BUILD_TARGET:-g6lc64_smt2}"
JOBS="${SOFT_LADDER_BUILD_JOBS:-$( (command -v nproc >/dev/null && nproc) || echo 8)}"
# The proxy may pass the literal '$(nproc)' so it is evaluated on the remote.
if [[ "$JOBS" == "$(nproc)" ]] || [[ "$JOBS" == "\$(nproc)" ]]; then
  JOBS=$( (command -v nproc >/dev/null && nproc) || echo 8)
fi
# Respect an explicit upper bound, otherwise saturate the host.
MAX_JOBS="${SOFT_LADDER_BUILD_MAX_JOBS:-$( (command -v nproc >/dev/null && nproc) || echo 8)}"
if [[ "$MAX_JOBS" == "$(nproc)" ]] || [[ "$MAX_JOBS" == "\$(nproc)" ]]; then
  MAX_JOBS=$( (command -v nproc >/dev/null && nproc) || echo 8)
fi
if [[ "$JOBS" =~ ^[0-9]+$ ]] && [[ "$MAX_JOBS" =~ ^[0-9]+$ ]] && [[ "$JOBS" -gt "$MAX_JOBS" ]]; then
  JOBS="$MAX_JOBS"
fi
STOCK_FLIST="core/Flist.cva6"

# VERLIB may be absolute (remote /opt/testharness/work/...) or relative.
# Keep a clean path for Make and stamp/flist references.
if [[ "$VERLIB" = /* ]]; then
  VERLIB_DIR="$VERLIB"
else
  VERLIB_DIR="$ROOT/$VERLIB"
fi
STAMP="$VERLIB_DIR/.soft-ladder-flavour"

log() { echo "[soft-ladder-build] $*"; }

[[ -f "$STOCK_FLIST" ]] || { log "missing $STOCK_FLIST"; exit 1; }

# --- build environment (same recipe as monorepo-soak/rebuild-baseline.sh) ----
# Every value is overridable so this works on other machines.
export SPIKE_INSTALL_DIR="${SPIKE_INSTALL_DIR:-$ROOT/build-platform/workspace/tooling/spike}"
export RISCV="${RISCV:-/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3}"
export LD_LIBRARY_PATH="$SPIKE_INSTALL_DIR/lib:${LD_LIBRARY_PATH:-}"
export CVA6_REPO_DIR="${CVA6_REPO_DIR:-$ROOT}"
export CXX="${CXX:-g++}" CC="${CC:-gcc}"

# Compiler/linker cache controls. ccache fronts the C++ compile step; mold
# (or lld) can be selected for the final link. Everything is optional.
OBJCACHE="${SOFT_LADDER_BUILD_OBJCACHE:-}"
LINK="${SOFT_LADDER_BUILD_LINK:-$CXX}"
BUILD_LDFLAGS="${SOFT_LADDER_BUILD_LDFLAGS:-}"
# wrack TRACE (`log wrack`) pokes i_wt_dcache.wr_ack, which Verilator
# inlines unless public. Do not force -DG6LC_TRACE_WT_WBUFFER here:
# nackinv-d1 / wrprio-all incremental rebuilds fail with "no member wr_ack".
# Opt-in: SOFT_LADDER_BUILD_CXXFLAGS=-DG6LC_TRACE_WT_WBUFFER (needs public).
BUILD_CXXFLAGS="${SOFT_LADDER_BUILD_CXXFLAGS:-}"
# fetch_B (G6LC_FETCH_B) testbench debug probes only exist in the B frontend.
if [[ "$FETCH" == "B" ]]; then
  BUILD_CXXFLAGS="-DG6LC_FETCH_B ${BUILD_CXXFLAGS}"
fi
LINKER="${SOFT_LADDER_BUILD_LINKER:-}"

if [[ -n "$LINKER" ]]; then
  case "$LINKER" in
    mold)
      if command -v mold >/dev/null 2>&1; then
        BUILD_LDFLAGS="$BUILD_LDFLAGS -fuse-ld=mold"
      else
        log "warn: mold not on PATH; using system linker"
      fi
      ;;
    lld)
      if command -v ld.lld >/dev/null 2>&1; then
        BUILD_LDFLAGS="$BUILD_LDFLAGS -fuse-ld=lld"
      else
        log "warn: ld.lld not on PATH; using system linker"
      fi
      ;;
    *)
      log "warn: unknown linker '$LINKER'; using system linker"
      ;;
  esac
fi

if [[ -n "$OBJCACHE" ]]; then
  if ! command -v "$OBJCACHE" >/dev/null 2>&1; then
    log "warn: '$OBJCACHE' not on PATH; disabling object cache"
    OBJCACHE=""
  else
    CCACHE_DIR="${SOFT_LADDER_BUILD_CCACHE_DIR:-/tmp/.soft-ladder-ccache}"
    CCACHE_MAXSIZE="${SOFT_LADDER_BUILD_CCACHE_MAXSIZE:-5G}"
    export CCACHE_DIR CCACHE_MAXSIZE
    mkdir -p "$CCACHE_DIR"
    log "objcache: $OBJCACHE dir=$CCACHE_DIR max=$CCACHE_MAXSIZE"
  fi
fi

[[ -n "$BUILD_LDFLAGS" ]] && log "extra LDFLAGS: $BUILD_LDFLAGS"
[[ -n "$BUILD_CXXFLAGS" ]] && log "extra CXXFLAGS: $BUILD_CXXFLAGS"

VLT_HOME="${VLT_HOME:-/root/tools/verilator-v5.008}"

for p in "$RISCV/bin" "$SPIKE_INSTALL_DIR/lib" "$VLT_HOME/bin/verilator"; do
  [[ -e "$p" ]] || { log "missing build dependency: $p"; exit 1; }
done

# Verilator 5.008 does not know -Wno-SIDEEFFECT; the Makefile passes it on some
# targets. Wrap the binary to strip it (same shim as rebuild-baseline.sh).
export VERILATOR_ROOT="${VERILATOR_ROOT:-$VLT_HOME/share/verilator}"
[[ -e "$VERILATOR_ROOT/verilator_bin" ]] || ln -sfn "$VLT_HOME/bin/verilator_bin" "$VERILATOR_ROOT/verilator_bin"
VLT_WRAP=/tmp/soft-ladder-vlt-wrap
mkdir -p "$VLT_WRAP"
cat >"$VLT_WRAP/verilator" <<EOF
#!/usr/bin/env bash
args=()
for a in "\$@"; do
  [[ "\$a" == "-Wno-SIDEEFFECT" ]] && continue
  args+=("\$a")
done
export VERILATOR_ROOT=$VERILATOR_ROOT
exec $VLT_HOME/bin/verilator "\${args[@]}"
EOF
chmod +x "$VLT_WRAP/verilator"
export PATH="$VLT_WRAP:$VLT_HOME/bin:/usr/bin:$RISCV/bin:$SPIKE_INSTALL_DIR/bin:${PATH}"
log "verilator: $(verilator -V 2>&1 | head -1)"

# --- flavour/Mdir consistency (never mix A and B objects in one Mdir) --------
if [[ "${SOFT_LADDER_BUILD_CLEAN:-0}" == "1" ]]; then
  log "clean: removing $VERLIB_DIR"
  rm -rf "$VERLIB_DIR"
elif [[ -f "$STAMP" ]]; then
  prev="$(cat "$STAMP")"
  if [[ "$prev" != "$FETCH" ]]; then
    log "REFUSING: $VERLIB_DIR was built as flavour '$prev', requested '$FETCH'"
    log "pick another SOFT_LADDER_VERLIB, or re-run with SOFT_LADDER_BUILD_CLEAN=1"
    exit 3
  fi
  log "resume: $VERLIB_DIR already flavour '$FETCH' (incremental)"
elif [[ -d "$VERLIB_DIR" ]]; then
  # Pre-existing dir from before flavour stamping. Stock builds are fetch_B by
  # construction (Flist.cva6 defaults to it), so only 'legacy' is ambiguous.
  if [[ "$FETCH" == "legacy" ]]; then
    log "REFUSING: $VERLIB_DIR exists with no flavour stamp; assume it is a stock (B) build"
    log "use SOFT_LADDER_VERLIB=<new dir> or SOFT_LADDER_BUILD_CLEAN=1"
    exit 3
  fi
  log "adopting unstamped $VERLIB_DIR as flavour B (stock Flist.cva6 default)"
fi

mkdir -p "$VERLIB_DIR"

# --- warm start from a previous work-ver (optional) -------------------------
# Copies only Verilator/C++ build products so unchanged objects are reused.
SEED="${SOFT_LADDER_BUILD_SEED:-}"
if [[ -n "$SEED" && ! -f "$VERLIB_DIR/Variane_testharness.mk" ]]; then
  # SEED may be absolute or relative to repo root.
  if [[ "$SEED" = /* ]] && [[ -d "$SEED" ]]; then
    log "warm start: seeding $VERLIB_DIR from $SEED (object reuse)"
    cp -a "$SEED/." "$VERLIB_DIR/" 2>/dev/null || true
    rm -f "$VERLIB_DIR/.soft-ladder-flavour"
  elif [[ -d "$ROOT/$SEED" ]]; then
    log "warm start: seeding $VERLIB_DIR from $ROOT/$SEED (object reuse)"
    cp -a "$ROOT/$SEED/." "$VERLIB_DIR/" 2>/dev/null || true
    rm -f "$VERLIB_DIR/.soft-ladder-flavour"
  else
    log "warn: SOFT_LADDER_BUILD_SEED=$SEED not found; cold build"
  fi
fi

# Isolated candidate builds must not reuse the named production Mdirs.
# Match the basename: SOFT_LADDER_VERLIB is often an absolute remote path.
if [[ "${SOFT_LADDER_ISOLATED:-0}" == 1 ]]; then
  verlib_base="$(basename "$VERLIB_DIR")"
  case "$verlib_base" in
    work-ver-smt2-fw64|work-ver-smt2-fw64-B|work-ver-stream8|work-ver-smt2)
      log "REFUSING: isolated candidate must not reuse production Mdir $verlib_base"
      exit 2
      ;;
  esac
  log "isolated Mdir $VERLIB_DIR (experimental overlay; not a Linux SKU)"
fi

# --- flist selection -------------------------------------------------------
if [[ "$FETCH" == "B" ]]; then
  FLIST="$STOCK_FLIST"
  log "flavour=B flist=$STOCK_FLIST (stock default)"
else
  # Derive the oracle flist. Never edit core/Flist.cva6 in place: that would
  # change the default build for every other suite in the tree.
  FLIST="$VERLIB_DIR/Flist.cva6.legacy"
  sed -e '/^+define+G6LC_FETCH_B[[:space:]]*$/d' \
      -e 's#^-f \(.*\)/Flist\.fetch_B[[:space:]]*$#-f \1/Flist.smt_legacy#' \
      "$STOCK_FLIST" >"$FLIST"

  # Fail loudly rather than silently building a second fetch_B.
  if grep -qE '^\+define\+G6LC_FETCH_B[[:space:]]*$' "$FLIST"; then
    log "ERROR: G6LC_FETCH_B still defined in $FLIST"; exit 1
  fi
  if grep -qE '^-f .*Flist\.fetch_B[[:space:]]*$' "$FLIST"; then
    log "ERROR: Flist.fetch_B still included in $FLIST"; exit 1
  fi
  if ! grep -qE '^-f .*Flist\.smt_legacy[[:space:]]*$' "$FLIST"; then
    log "ERROR: Flist.smt_legacy not included in $FLIST"; exit 1
  fi
  log "flavour=legacy flist=$FLIST (derived: define dropped, smt_legacy supply)"
fi

if [[ -n "${SOFT_LADDER_OVERLAY:-}" ]]; then
  [[ "${SOFT_LADDER_ISOLATED:-0}" == 1 ]] || {
    log "REFUSING: SOFT_LADDER_OVERLAY requires SOFT_LADDER_ISOLATED=1"
    exit 2
  }
  OVERLAY_DIR="${SOFT_LADDER_OVERLAY_DIR:-$VERLIB_DIR/overlay}"
  OVERLAY_ARGS=()
  # Entries are NAME=VALUE config fields, or a bare NAME which becomes a
  # +define+NAME in the derived flist. The define form exists so an investigation
  # gated on a `ifdef seam can build both arms from ONE source state; the
  # alternative is editing RTL between builds, which leaves the two arms
  # unattributable to any recorded source. Isolated builds only, as before.
  IFS=',' read -ra _overlay_fields <<<"$SOFT_LADDER_OVERLAY"
  for _f in "${_overlay_fields[@]}"; do
    [[ -z "$_f" ]] && continue
    if [[ "$_f" == *=* ]]; then
      OVERLAY_ARGS+=(--field "$_f")
    else
      OVERLAY_ARGS+=(--define "$_f")
    fi
  done
  python3 "$ROOT/verif/regress/isolated-config-overlay.py" \
    --root "$ROOT" --target "$TARGET" --out "$OVERLAY_DIR" \
    "${OVERLAY_ARGS[@]}"
  FLIST="$OVERLAY_DIR/Flist.cva6.overlay"
  log "overlay flist=$FLIST fields=$SOFT_LADDER_OVERLAY"
fi

VTHREADS="${SOFT_LADDER_VERILATOR_THREADS:-$( (command -v nproc >/dev/null && nproc) || echo 4)}"
if [[ "$VTHREADS" == "$(nproc)" ]] || [[ "$VTHREADS" == "\$(nproc)" ]]; then
  VTHREADS=$( (command -v nproc >/dev/null && nproc) || echo 4)
fi

log "target=$TARGET ver-library=$VERLIB_DIR jobs=$JOBS vthreads=$VTHREADS"
echo "$FETCH" >"$STAMP"

# Regenerate corev_apu/bootrom/bootrom.sv and bootrom.h from the current
# bootrom.S / linker.ld / ariane.dts. Verilator consumes the .sv directly,
# but the top-level Makefile does not rebuild it, so a stale bootrom.sv would
# silently boot from an old binary or from DTB strings.
log "regenerating bootrom"
make -C "$ROOT/corev_apu/bootrom" \
  RISCV_GCC="$RISCV/bin/riscv-none-elf-gcc" \
  RISCV_OBJCOPY="$RISCV/bin/riscv-none-elf-objcopy" \
  PYTHON=python3 \
  all

# When the Mdir is outside the repo (e.g. remote /opt/testharness/work/...),
# the generated Variane_testharness.mk's VPATH (.. and VM_USER_DIR) does not
# point to the C++ sources. Seed VPATH with the repo root so the compile step
# finds corev_apu/tb/dpi/*.cc and corev_apu/tb/*.cpp wherever the Mdir lives.
export VPATH="$CVA6_REPO_DIR"

BUILD_LOG="${SOFT_LADDER_BUILD_LOG:-$VERLIB_DIR/build.log}"
rm -f "$BUILD_LOG"
log "building; full log -> $BUILD_LOG"

set +e
make -s verilate \
  verilator="verilator --no-timing -Wno-MODDUP -j $JOBS" \
  target="$TARGET" \
  ver-library="$VERLIB_DIR" \
  flist="$FLIST" \
  verilator_threads="$VTHREADS" \
  TRACE_COMPACT="${SOFT_LADDER_BUILD_TRACE_COMPACT:-}" \
  TRACE_FAST="${SOFT_LADDER_BUILD_TRACE_FAST:-}" \
  VERILATOR_INSTALL_DIR="${VERILATOR_INSTALL_DIR:-$VLT_HOME}" \
  XLEN=64 \
  CVA6_REPO_DIR="$CVA6_REPO_DIR" \
  SPIKE_INSTALL_DIR="$SPIKE_INSTALL_DIR" \
  RISCV="$RISCV" \
  CXX="$CXX" CC="$CC" \
  NUM_JOBS="$JOBS" \
  OBJCACHE="$OBJCACHE" \
  LINK="$LINK" \
  LDFLAGS="$BUILD_LDFLAGS" \
  CXXFLAGS="$BUILD_CXXFLAGS" \
  >"$BUILD_LOG" 2>&1
rc=$?
set -e

warnings=$(grep -cE "%Warning|Warning" "$BUILD_LOG" 2>/dev/null || true)
errors=$(grep -cE "%Error|Error" "$BUILD_LOG" 2>/dev/null || true)

if [[ $rc -ne 0 ]]; then
  log "BUILD FAIL rc=$rc (flavour=$FETCH verlib=$VERLIB warnings=$warnings errors=$errors)"
  log "--- last 100 log lines ---"
  tail -n 100 "$BUILD_LOG"
  # Leave the stamp: the Mdir really does hold this flavour's partial objects,
  # so a resume must stay on the same flavour.
  exit $rc
fi

if [[ ! -x "$VERLIB_DIR/Variane_testharness" ]]; then
  log "BUILD FAIL: no $VERLIB_DIR/Variane_testharness"
  exit 1
fi

log "BUILD OK flavour=$FETCH harness=$VERLIB_DIR/Variane_testharness warnings=$warnings errors=$errors"
if [[ $warnings -gt 0 ]]; then
  log "--- warning summary (total $warnings) ---"
  grep -hE "%Warning|Warning" "$BUILD_LOG" | sed -E 's#^%Warning-##' >"$BUILD_LOG.warnings"
  sort "$BUILD_LOG.warnings" | uniq -c | sort -rn >"$BUILD_LOG.wsummary"
  head -20 "$BUILD_LOG.wsummary"
  log "--- first 5 distinct warnings ---"
  sort -u "$BUILD_LOG.warnings" >"$BUILD_LOG.wdistinct"
  head -5 "$BUILD_LOG.wdistinct"
fi
log "next: SOFT_LADDER_FETCH=$FETCH bash verif/regress/soft-ladder-opensbi-soak.sh"
