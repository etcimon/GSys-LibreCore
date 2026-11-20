#!/usr/bin/env bash
# Query leaf.  Raster, shader-wave, and executor are not built.
# Off the testharness this re-enters through testharness_proxy so the
# run uses tools/verilator's PGO build, the fixed unroll limits, and
# simulator PGO.  Training is not the result; the profile-use binary is.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
if [[ "${APU_QRY_ON_HARNESS:-}" != 1 ]]; then
  proxy="$ROOT/verif/regress/remote/testharness_proxy.py"
  python3 -B "$proxy" --timeout 1800 sync
  cmd="$(mktemp)"
  cat > "$cmd" <<'EOF'
set -euo pipefail
cd /opt/testharness/repo
if [[ ! -f tools/verilator/configure.ac ]]; then
  src="$(ls -1dt /opt/testharness/runs/apu-leaf-*/source 2>/dev/null | head -1 || true)"
  if [[ -n "${src}" && -d "${src}/tools/verilator" ]]; then
    mkdir -p tools
    cp -a "${src}/tools/verilator" tools/verilator
  fi
fi
[[ -f tools/verilator/configure.ac ]] || {
  echo "BLOCKED: tools/verilator is not on the testharness snapshot"
  exit 3
}
export APU_QRY_ON_HARNESS=1
export CVA6_REPO_DIR=/opt/testharness/repo
export APU_VERILATOR_PGO=1
export APU_SIM_PGO=1
export APU_TOOL_SETUP_TIMEOUT=3600
export APU_BUILD_JOBS="$(nproc)"
# The synced tree is not a git checkout. Give the PGO builder a
# stable snapshot id so it does not call git.
idfile="$(mktemp)"
sha256sum tools/verilator/configure.ac | cut -d' ' -f1 > "$idfile"
export APU_VERILATOR_SOURCE_ID_FILE="$idfile"
bash verif/tb/apu/run-apu-qrydelta.sh
rm -f "$idfile"
EOF
  python3 -B "$proxy" --timeout 7200 shell --no-hang --cmd-file "$cmd"
  rc=$?
  rm -f "$cmd"
  exit "$rc"
fi

# shellcheck source=local-verilator.sh
source "$ROOT/verif/tb/apu/local-verilator.sh"
export CVA6_REPO_DIR="$ROOT"
export APU_VERILATOR_PGO=1
export APU_SIM_PGO=1
apu_ensure_verilator
OUT="${APU_QRYDELTA_OUT:-/tmp/g6lc-apu-qrydelta}"
rm -rf "$OUT"
mkdir -p "$OUT"
{
  printf 'verilator=%s\nreal=%s\n' "$VERILATOR" "${APU_REAL_VERILATOR:-}"
  printf 'simulator_pgo=%s\nunroll_count=%s\nunroll_stmts=%s\n' \
    "${APU_SIM_PGO}" "${VERILATOR_UNROLL_COUNT:-}" "${VERILATOR_UNROLL_STMTS:-}"
} | tee "$OUT/toolchain.txt"

build_one() {
  local top="$1" mdir="$2" log="$3"
  shift 3
  if ! "$VERILATOR" --binary --timing -Wall \
    -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-DECLFILENAME -Wno-BLKSEQ \
    "$@" \
    --top-module "$top" \
    -Mdir "$mdir" -o "$top" \
    > "$log" 2>&1; then
    echo "VERILATOR BUILD FAILED ($top)"
    tail -n 40 "$log"
    exit 1
  fi
  if ! grep -q 'SIMULATOR PGO READY mode=profile-use' "$log"; then
    echo "BLOCKED: $top was not built with simulator PGO"
    tail -n 20 "$log"
    exit 3
  fi
}

build_one tb_g6lc_apu_qrydelta "$OUT/sim" "$OUT/build.log" \
  "$ROOT/corev_apu/apu/g6lc_apu_qrydelta.sv" \
  "$ROOT/verif/tb/apu/tb_g6lc_apu_qrydelta.sv"
echo "VERILATOR BUILD OK"
set +e
"$OUT/sim/tb_g6lc_apu_qrydelta" > "$OUT/sim.log" 2>&1
rc=$?
set -e
echo "SIM rc=$rc"
cat "$OUT/sim.log"
grep -q '^PASS tb_g6lc_apu_qrydelta ' "$OUT/sim.log"

build_one tb_g6lc_apu_qrypool "$OUT/pool" "$OUT/pool-build.log" \
  "$ROOT/corev_apu/apu/g6lc_apu_qrydelta.sv" \
  "$ROOT/corev_apu/apu/g6lc_apu_qrypool.sv" \
  "$ROOT/verif/tb/apu/tb_g6lc_apu_qrypool.sv"
echo "POOL BUILD OK"
set +e
"$OUT/pool/tb_g6lc_apu_qrypool" > "$OUT/pool.log" 2>&1
rc=$?
set -e
echo "POOL rc=$rc"
cat "$OUT/pool.log"
grep -q '^PASS tb_g6lc_apu_qrypool ' "$OUT/pool.log"
