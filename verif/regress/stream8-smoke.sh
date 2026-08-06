#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Stream8-class package smoke (optional; not default verify).
# Stages: config/DTS contract → dual-core topology → mini ELF compile →
# optional lint of g6lc64_stream8 (soft when host-skewed Verilator).
#
# Env:
#   STREAM8_REQUIRE_LINT=1  hard-fail if lint unavailable/fails
#   STREAM8_LIVE_RTL=1      attempt mini_amocas_w on existing Variane (lab)
#
# Priors: architecture/stream8-class.md · AGENTS-todo §11
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
export PATH="${HOME}/.bun/bin:${PATH:-}"

REQUIRE_LINT="${STREAM8_REQUIRE_LINT:-0}"
LIVE_RTL="${STREAM8_LIVE_RTL:-0}"
OUT="${STREAM8_OUT:-/tmp/cva6-stream8-smoke}"
mkdir -p "$OUT"

PASS=0
FAIL=0
SKIP=0
log() { echo "[stream8-smoke] $*"; }

log "OPTIONAL — stream8-class package smoke"
log "  package: core/include/g6lc64_stream8_config_pkg.sv"
log "  notes:   architecture/stream8-class.md"

need=(
  core/include/g6lc64_stream8_config_pkg.sv
  corev_apu/bootrom/ariane-stream8.dts
  verif/tests/testlist_stream8.yaml
  architecture/stream8-class.md
  verif/tests/custom/multicore/mini_amocas_w.S
  verif/tests/custom/multicore/mini_amocas_d.S
  verif/tests/custom/multicore/mini_amocas_q.S
  verif/tests/custom/multicore/mini_stream_plane.S
  verif/tests/custom/kvm_h/h_edge_diag.S
)
for f in "${need[@]}"; do
  test -f "$f" || { log "MISSING $f"; exit 1; }
  log "  ok $f"
done
PASS=$((PASS + 1))

pkg=core/include/g6lc64_stream8_config_pkg.sv
grep -q "NrCores: *unsigned'(2)" "$pkg" || { log "FAIL: NrCores must be 2"; exit 1; }
grep -q "RVZacas: *bit'(1)" "$pkg" || { log "FAIL: RVZacas must be 1"; exit 1; }
grep -q "DeepSpecEn: *bit'(1)" "$pkg" || { log "FAIL: DeepSpecEn must be 1"; exit 1; }
grep -q "L2En: *bit'(1)" "$pkg" || { log "FAIL: L2En must be 1"; exit 1; }
grep -qE "CVA6ConfigHExtEn = 1|RVH: *bit'\(1\)" "$pkg" || { log "FAIL: RVH/HExtEn must be 1"; exit 1; }
grep -q "NrHarts: *unsigned'(1)" "$pkg" || { log "FAIL: bare CRT NrHarts must be 1"; exit 1; }
log "  ok stream8 cfg envelope (N=2, Zacas, DeepSpec, L2, H, NrHarts=1)"
PASS=$((PASS + 1))

dts=corev_apu/bootrom/ariane-stream8.dts
grep -q 'cpu@0' "$dts" && grep -q 'cpu@1' "$dts" || { log "FAIL: DTS needs cpu@0 and cpu@1"; exit 1; }
grep -q 'zacas' "$dts" || { log "FAIL: DTS missing zacas"; exit 1; }
grep -q 'core1' "$dts" || { log "FAIL: DTS cpu-map needs core1 (dual physical cores)"; exit 1; }
grep -q 'next-level-cache' "$dts" || { log "FAIL: DTS needs next-level-cache"; exit 1; }
log "  ok ariane-stream8.dts dual-core + zacas + L2"
if command -v dtc >/dev/null 2>&1; then
  dtc -I dts -O dtb -o "$OUT/ariane-stream8.dtb" "$dts" >/dev/null
  log "  ok dtc → $OUT/ariane-stream8.dtb"
  PASS=$((PASS + 1))
else
  log "  WARN: dtc missing — skip DTB compile"
  SKIP=$((SKIP + 1))
fi

# Mini golden compile (host residual; RTL live optional)
COMMON="$ROOT/verif/tests/custom/common"
LD="$COMMON/link_verilator.ld"
RISCV_CC="${RISCV_CC:-}"
if [[ -z "$RISCV_CC" ]]; then
  for p in riscv-none-elf-gcc riscv64-unknown-elf-gcc; do
    if command -v "$p" >/dev/null 2>&1; then RISCV_CC="$p"; break; fi
  done
fi
if [[ "${RISCV_CC:-}" == *.exe ]] || ! command -v "${RISCV_CC:-false}" >/dev/null 2>&1; then
  if [[ -x /opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin/riscv-none-elf-gcc ]]; then
    export PATH="/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin:${PATH}"
    RISCV_CC=riscv-none-elf-gcc
  fi
fi

compile_mini() {
  local name="$1" src="$2"
  local elf="$OUT/${name}.elf"
  "$RISCV_CC" -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
    -I"$ROOT/verif/tests/custom/env" -I"$COMMON" \
    "$src" -T "$LD" -o "$elf" -march=rv64imafdc_zicsr_zifencei -mabi=lp64d
  test -f "$elf"
  log "  ok $elf"
}

if [[ -n "${RISCV_CC:-}" ]] && command -v "$RISCV_CC" >/dev/null 2>&1; then
  log "compiling stream8 mini goldens with $RISCV_CC..."
  compile_mini mini_amocas_w verif/tests/custom/multicore/mini_amocas_w.S
  compile_mini mini_amocas_d verif/tests/custom/multicore/mini_amocas_d.S
  compile_mini mini_amocas_q verif/tests/custom/multicore/mini_amocas_q.S
  compile_mini mini_stream_plane verif/tests/custom/multicore/mini_stream_plane.S
  PASS=$((PASS + 1))
else
  log "  WARN: no riscv-*-gcc — skip mini ELF compile"
  SKIP=$((SKIP + 1))
fi

native_verilator_ok() {
  # Prefer Linux ELF suite overlay (WSL) then managed home install, then OSS CAD.
  local candidates=(
    "$ROOT/build-platform/workspace/tooling/linux-eda-suite/bin/verilator_bin"
    "${VERILATOR_INSTALL_DIR:-$HOME/tools/verilator-v5.008}/bin/verilator_bin"
    "$ROOT/build-platform/workspace/tooling/oss-cad-suite/bin/verilator_bin"
  )
  local c
  for c in "${candidates[@]}"; do
    if [[ -x "$c" ]] && file "$c" 2>/dev/null | grep -qiE 'ELF|executable'; then
      return 0
    fi
  done
  return 1
}

if command -v bun >/dev/null 2>&1 || [[ -x "$HOME/.bun/bin/bun" ]]; then
  export PATH="${HOME}/.bun/bin:${PATH}"
  if native_verilator_ok; then
    log "lint g6lc64_stream8..."
    set +e
    bun build-platform/src/cli/index.ts verify --lint --target g6lc64_stream8
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
      log "  ok g6lc64_stream8 lint"
      PASS=$((PASS + 1))
    else
      log "  FAIL lint rc=$rc"
      FAIL=$((FAIL + 1))
    fi
  else
    msg="native verilator_bin missing (Windows OSS CAD PE under WSL is not enough)"
    if [[ "$REQUIRE_LINT" == "1" ]]; then
      log "FAIL: $msg (STREAM8_REQUIRE_LINT=1)"
      exit 1
    fi
    log "WARN: soft-skip stream8 lint — $msg"
    SKIP=$((SKIP + 1))
  fi
else
  log "WARN: bun not on PATH — skip lint"
  SKIP=$((SKIP + 1))
fi

if [[ "$LIVE_RTL" == "1" ]]; then
  # Prefer dedicated stream8 TB; fall back to work-ver.
  harness="${STREAM8_HARNESS:-}"
  if [[ -z "$harness" ]]; then
    if [[ -x "$ROOT/work-ver-stream8/Variane_testharness" ]]; then
      harness="$ROOT/work-ver-stream8/Variane_testharness"
    else
      harness="$ROOT/work-ver/Variane_testharness"
    fi
  fi
  export LD_LIBRARY_PATH="${ROOT}/tools/spike/lib:${ROOT}/build-platform/workspace/tooling/spike/lib:${LD_LIBRARY_PATH:-}"
  if [[ ! -x "$harness" ]]; then
    log "  WARN: STREAM8_LIVE_RTL=1 but no Variane harness (build: make verilate target=g6lc64_stream8 ver-library=work-ver-stream8)"
    SKIP=$((SKIP + 1))
  else
    log "live RTL via $harness"
    live_pass=0
    live_fail=0
    for name in mini_amocas_w mini_amocas_d mini_amocas_q mini_stream_plane; do
      elf="$OUT/${name}.elf"
      if [[ ! -f "$elf" ]]; then
        log "  SKIP $name (no elf)"
        SKIP=$((SKIP + 1))
        continue
      fi
      th="$(riscv-none-elf-nm "$elf" 2>/dev/null | awk '$3=="tohost"{print $1; exit}')"
      if [[ -z "$th" ]]; then
        log "  FAIL $name (no tohost)"
        live_fail=$((live_fail + 1))
        continue
      fi
      maxc=500000
      [[ "$name" == "mini_stream_plane" ]] && maxc=2000000
      vlog="$OUT/veri_${name}.log"
      set +e
      "$harness" +max-cycles="$maxc" +time_out="$maxc" +debug_disable \
        +tohost_addr="0x${th}" "$elf" >"$vlog" 2>&1
      set -e
      if grep -q SUCCESS "$vlog"; then
        log "  PASS live RTL $name"
        live_pass=$((live_pass + 1))
      else
        log "  FAIL live RTL $name (see $vlog)"
        tail -12 "$vlog" || true
        live_fail=$((live_fail + 1))
      fi
    done
    PASS=$((PASS + live_pass))
    FAIL=$((FAIL + live_fail))
  fi
fi

if [[ $FAIL -gt 0 ]]; then
  log "FAIL pass=$PASS skip=$SKIP fail=$FAIL"
  exit 1
fi

cat <<'EOF'
[stream8-smoke] live RTL / lint (Linux Verilator 5.008):
  export VERILATOR_INSTALL_DIR=$HOME/tools/verilator-v5.008
  export PATH=$VERILATOR_INSTALL_DIR/bin:$PATH
  # optional: build-platform/.config.local.ts suite.root=linux-eda-suite
  make verilate target=g6lc64_stream8 ver-library=work-ver-stream8
  STREAM8_LIVE_RTL=1 STREAM8_REQUIRE_LINT=1 bash verif/regress/stream8-smoke.sh
  Full CRT: DV_TARGET=g6lc64_stream8 bash verif/regress/mc-spo-veri.sh
EOF
log "PASS (pass=$PASS skip=$SKIP fail=$FAIL)"
exit 0
