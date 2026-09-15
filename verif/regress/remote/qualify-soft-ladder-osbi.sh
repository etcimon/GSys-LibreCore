#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Strict-qualification entry for the SMT2 OpenSBI cookie soak.
#
# Unlike the developer-facing soak (verif/regress/soft-ladder-opensbi-soak.sh
# via `testharness_proxy.py soak`), this wrapper exists ONLY for the
# build-platform qualification path: it requires the injected identity env,
# binds the run to a build manifest produced by `proxy build --manifest-out`,
# classifies the PULLED remote log (never the ssh rc), and prints exactly one
# terminal `G6LC_EVIDENCE <json>` record as its last stdout line.
#
# Typical use:
#   python3 verif/regress/remote/testharness_proxy.py build B \
#     --manifest-out remote-runs/builds/work-ver-smt2-fw64-B.manifest.json
#   cva6-build verify --sim --qualification smt2-cookie --target g6lc64_smt2

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
PROXY="verif/regress/remote/testharness_proxy.py"

fail() { echo "[qual-osbi] $*" >&2; exit 2; }

IDENT="${G6LC_QUALIFICATION_IDENTITY:-}"
MANIFEST_REL="${G6LC_BUILD_MANIFEST:-}"
[[ -n "$IDENT" ]] || fail "G6LC_QUALIFICATION_IDENTITY missing — run via 'verify --sim --qualification'"
[[ -n "$MANIFEST_REL" ]] || fail "G6LC_BUILD_MANIFEST missing"
[[ "${G6LC_REQUIRE_EVIDENCE:-rtl-core}" == "rtl-core" ]] || \
  fail "G6LC_REQUIRE_EVIDENCE=${G6LC_REQUIRE_EVIDENCE:-unset} — this wrapper only produces rtl-core evidence"
[[ -f "$MANIFEST_REL" ]] || fail "build manifest $MANIFEST_REL not found — build first: proxy build <flavour> --manifest-out $MANIFEST_REL"

# Pull the expected identity + manifest digests with python3 (guaranteed by the
# WSL wrapper preflight and by cmd_doctor on Linux).
eval "$(python3 - "$IDENT" "$MANIFEST_REL" <<'PY'
import json, sys
ident = json.loads(sys.argv[1])
man = json.load(open(sys.argv[2]))
flavour = man.get("configuration", {}).get("flavour", "B")
for k in ("suite", "target", "top", "kind", "runId",
          "sourceSha256", "configSha256", "executableSha256"):
    print(f'Q_{k}={json.dumps(str(ident[k]))}')
print(f"Q_flavour={json.dumps(str(flavour))}")
print(f"Q_manifestExe={man['executableSha256']}")
PY
)"

TAG="qsl-${Q_runId:0:8}"
echo "[qual-osbi] run_id=$Q_runId flavour=$Q_flavour target=$Q_target manifest=$MANIFEST_REL"

# Forward the operator's peel/hold/ELF knobs so qualified runs can reproduce a
# specific payload; they become part of the run, not the build identity.
proxy_env=()
for k in "${!SOFT_LADDER_@}" "${!PEEL_@}" "${!SOFT_@}" CVA6_TRAP_DUMP CVA6_COOKIE_EXIT CVA6_SOAK_EXIT; do
  [[ -n "${!k:-}" ]] || continue
  case "$k" in
    # Harness/flavour/out-dir are bound by the manifest + proxy args; identity
    # vars belong to the wrapper. Never let env overrides break that binding.
    SOFT_LADDER_HARNESS|SOFT_LADDER_FETCH|SOFT_LADDER_OSBI_OUT|G6LC_*) continue ;;
  esac
  proxy_env+=(--env "$k=${!k}")
done

set +e
python3 "$PROXY" ${TH_PROXY_ARGS:-} soak \
  --flavour "$Q_flavour" \
  --tag "$TAG" \
  --run-id "$Q_runId" \
  --expect-exe-sha256 "$Q_manifestExe" \
  --pull "${proxy_env[@]}"
rc=$?
set -e

DEST="$ROOT/remote-runs/$TAG"
echo "[qual-osbi] proxy rc=$rc pulled=$DEST"

# --- classify the pulled log (never the ssh rc) -----------------------------
checks=0
verdict=fail
RUNID_FILE="$DEST/run-id"
LOG="$(ls -t "$DEST"/veri_*_*.log 2>/dev/null | head -1 || true)"

[[ -f "$RUNID_FILE" ]] && [[ "$(cat "$RUNID_FILE")" == "$Q_runId" ]] && checks=$((checks+1))
[[ -n "$LOG" && -f "$LOG" ]] || { echo "[qual-osbi] CLASSIFY=FAIL no pulled harness log in $DEST"; }
if [[ -n "$LOG" && -f "$LOG" ]]; then
  grep -q '\[trapdump\]' "$LOG" && checks=$((checks+1))
  grep -qE '\[cookie-exit\]|\[1000\]=(0x)?[0-9a-fA-F]*51b1babe' "$LOG" && checks=$((checks+1))
  ! grep -qE '\[1000\]=0*51b1dead\b' "$LOG" && checks=$((checks+1))
fi
# All four predicates must hold for a pass: run-id binding, trapdump present,
# success cookie, and no fail cookie.
if [[ $checks -eq 4 && $rc -eq 0 ]]; then
  verdict=pass
  echo "[qual-osbi] CLASSIFY=SUCCESS run_id=$Q_runId cookie=51b1babe log=$(basename "$LOG")"
else
  echo "[qual-osbi] CLASSIFY=FAIL run_id=$Q_runId checks=$checks rc=$rc log=${LOG:-none}"
fi

# Terminal evidence record — MUST be the last stdout line (one record only).
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
