#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Strict-qualification entry for the stream8-class multicore minis.
#
# Compiles the self-checking dual-core minis (AMOCAS W/D/Q + stream plane),
# runs each through the remote testharness bound to a build manifest produced
# by `proxy build B --target g6lc64_stream8 --verlib work-ver-stream8
# --manifest-out <path>`, classifies the PULLED logs, and prints exactly one
# terminal `G6LC_EVIDENCE <json>` record.
#
# Unlike the OpenSBI soak, `*** SUCCESS ***` is meaningful here: each mini only
# writes its pass code to tohost after checking its own results (CAS return
# value, per-worker stream checksums), so SUCCESS is the checked-work verdict —
# and run-id + exe-sha binding still prove it came from this build and run.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
PROXY="verif/regress/remote/testharness_proxy.py"

fail() { echo "[qual-stream8] $*" >&2; exit 2; }

IDENT="${G6LC_QUALIFICATION_IDENTITY:-}"
MANIFEST_REL="${G6LC_BUILD_MANIFEST:-}"
[[ -n "$IDENT" ]] || fail "G6LC_QUALIFICATION_IDENTITY missing — run via 'verify --sim --qualification'"
[[ -n "$MANIFEST_REL" ]] || fail "G6LC_BUILD_MANIFEST missing"
[[ "${G6LC_REQUIRE_EVIDENCE:-rtl-cluster}" == "rtl-cluster" ]] || \
  fail "G6LC_REQUIRE_EVIDENCE=${G6LC_REQUIRE_EVIDENCE:-unset} — this wrapper only produces rtl-cluster evidence"
[[ -f "$MANIFEST_REL" ]] || fail "build manifest $MANIFEST_REL not found — build first: proxy build B --target g6lc64_stream8 --verlib work-ver-stream8 --manifest-out $MANIFEST_REL"

eval "$(python3 - "$IDENT" "$MANIFEST_REL" <<'PY'
import json, sys
ident = json.loads(sys.argv[1])
man = json.load(open(sys.argv[2]))
cfg = man.get("configuration", {})
for k in ("suite", "target", "top", "kind", "runId",
          "sourceSha256", "configSha256", "executableSha256"):
    print(f'Q_{k}={json.dumps(str(ident[k]))}')
print(f"Q_verlib={json.dumps(str(cfg.get('verlib', 'work-ver-stream8')))}")
print(f"Q_manifestExe={man['executableSha256']}")
PY
)"

[[ "$Q_target" == "g6lc64_stream8" ]] || fail "identity target is $Q_target, expected g6lc64_stream8"

# --- compile the minis (same recipe as stream8-smoke.sh) ---------------------
RISCV_CC="${RISCV_CC:-riscv-none-elf-gcc}"
if ! command -v "$RISCV_CC" >/dev/null 2>&1; then
  for p in /opt/xpack/xpack-riscv-none-elf-gcc-*/bin; do
    [[ -x "$p/riscv-none-elf-gcc" ]] && export PATH="$p:${PATH}" || true
  done
fi
command -v "$RISCV_CC" >/dev/null || \
  fail "no riscv-none-elf-gcc on PATH (WSL wrapper exports RISCV)"
COMMON="$ROOT/verif/tests/custom/common"
OUT="/tmp/qual-stream8-$Q_runId"
mkdir -p "$OUT"

# name -> per-test max cycles (mini_stream_plane streams more data)
declare -A TESTS=(
  [mini_amocas_w]=500000
  [mini_amocas_d]=500000
  [mini_amocas_q]=500000
  [mini_stream_plane]=2000000
)
for name in "${!TESTS[@]}"; do
  src="verif/tests/custom/multicore/${name}.S"
  [[ -f "$src" ]] || fail "missing $src"
  "$RISCV_CC" -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
    -I"$ROOT/verif/tests/custom/env" -I"$COMMON" \
    "$src" -T "$COMMON/link_verilator.ld" -o "$OUT/$name.elf" \
    -march=rv64imafdc_zicsr_zifencei -mabi=lp64d || fail "compile $name failed"
done
echo "[qual-stream8] run_id=$Q_runId verlib=$Q_verlib tests=${!TESTS[*]}"

# --- run each mini through the bound remote harness --------------------------
checks=0
verdict=pass
for name in "${!TESTS[@]}"; do
  TAG="qs8-${Q_runId:0:8}-$name"
  VLOG="$ROOT/remote-runs/$TAG/run-B.log"
  set +e
  python3 "$PROXY" ${TH_PROXY_ARGS:-} run "$OUT/$name.elf" \
    --flavour B --verlib "$Q_verlib" \
    --tag "$TAG" --run-id "$Q_runId" \
    --expect-exe-sha256 "$Q_manifestExe" \
    --time-out "${TESTS[$name]}" --pull --tail 20
  rc=$?
  set -e
  ok=1
  # Predicate 1: this specific run-id produced the pulled artifacts.
  [[ -f "$ROOT/remote-runs/$TAG/run-id" ]] && \
    [[ "$(cat "$ROOT/remote-runs/$TAG/run-id")" == "$Q_runId" ]] && checks=$((checks+1)) || ok=0
  # Predicate 2: the mini's self-check wrote its pass code to tohost.
  [[ -f "$VLOG" ]] && grep -q 'SUCCESS' "$VLOG" && checks=$((checks+1)) || ok=0
  # Predicate 3: no trap/fail/timeout markers in the pulled log.
  [[ -f "$VLOG" ]] && ! grep -qE 'FAIL|trapdump|timeout|Error' "$VLOG" && checks=$((checks+1)) || ok=0
  if [[ $ok -eq 1 && $rc -eq 0 ]]; then
    echo "[qual-stream8] PASS $name"
  else
    verdict=fail
    echo "[qual-stream8] FAIL $name (rc=$rc log=${VLOG:-none})"
    [[ -f "$VLOG" ]] && tail -8 "$VLOG" || true
  fi
done
# 4 tests x 3 predicates = 12 checks for a pass.
echo "[qual-stream8] CLASSIFY=${verdict^^} run_id=$Q_runId checks=$checks/12"

python3 - "$IDENT" "$verdict" "$checks" <<'PY'
import json, sys
ident = json.loads(sys.argv[1])
record = {
    "schemaVersion": 1,
    **ident,
    "execution": "remote-proxy",
    "status": sys.argv[2],
    "checks": int(sys.argv[3]),
}
print("G6LC_EVIDENCE " + json.dumps(record, separators=(",", ":"), sort_keys=True))
PY
[[ "$verdict" == "pass" ]]
