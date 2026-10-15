#!/usr/bin/env bash
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
# run-apu-regress — unified APU/Venus regression launcher.
#
#   run-apu-regress.sh [--stages LIST] [--out NEW_DIR]
#
# Stages (default: unit,top,soc,bridge):
#   unit   objtab vgpages(8192+65536) vgctl vnfront cmdexec xfer rast gcs
#          vndec vnrep vnpump shmod shwave shcore
#   top    vgtop(2 gate steps) vgsys(+negative arms) sys-venus
#   soc    cva6-venus (incl. venusoff)
#   bridge RTL bridge socket self-test (build-bridge + bridge_selftest)
#   guest  stock Ubuntu riscv64 Venus gate (run-guest.sh; heavy — the
#          image download is ~1.2 GiB the first time)
#   synth  Enable=0/1 yosys screens for vgpages(2 geoms) objtab vnfront
#          vnpump cmdexec vgctl (re-runs each suite with its *_SYNTH=1
#          flag; full enabled/disabled screens are required, with no
#          pre-synthesis fallback). Run the entire launcher on an isolated
#          remote snapshot; the old partial --remote routing is refused.
#   profile bounded static Vulkan audit (no RTL build; not conformance).
#
# Suites remain serial; aggregate remote job budgets are owned by the caller.
# Logs persist under a NEW --out (default .cache/apu-regress/<ts>-<pid>).
# APU_SOURCE_FILES (optional) restricts the source-identity inventory to a
# pushed file list — set by the remote leaf snapshot path; unset walks the tree.
# Selected-stage verdicts: exit 0 PASS, 1 FAIL, 2 usage, 3 tools, 4 INCOMPLETE.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
export CVA6_REPO_DIR="$ROOT"
TB="$ROOT/verif/tb/apu"
STAGES="unit,top,soc,bridge"
OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --stages|--out)
      [ $# -ge 2 ] && [ -n "$2" ] && [[ "$2" != --* ]] || {
        echo "missing value for $1" >&2; exit 2;
      }
      if [ "$1" = --stages ]; then STAGES="$2"; else OUT="$2"; fi
      shift 2;;
    --remote)
      echo "BLOCKED: partial remote routing is unsafe; run this entire launcher through the build-platform remote gateway on an isolated source snapshot." >&2
      exit 4;;
    --help)
      printf '%s\n' 'Usage: run-apu-regress.sh [--stages unit,top,soc,bridge,guest,synth,profile] [--out NEW_DIR]' \
        'Run RTL stages through the remote proxy. PASS covers selected stages only, not device qualification.'
      exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[[ "$STAGES" != ,* && "$STAGES" != *, && "$STAGES" != *,,* ]] || {
  echo "invalid stages: $STAGES" >&2; exit 2;
}
IFS=, read -r -a selected <<< "$STAGES"
seen=,
for stage in "${selected[@]}"; do
  case "$stage" in unit|top|soc|bridge|guest|synth|profile) ;; *) echo "unknown stage: $stage" >&2; exit 2;; esac
  [[ "$seen" != *",$stage,"* ]] || { echo "duplicate stage: $stage" >&2; exit 2; }
  seen+="$stage,"
done
[ "${#selected[@]}" -gt 0 ] || { echo "no stages selected" >&2; exit 2; }
WAIT="${APU_REGRESS_TIMEOUT:-7200}"
[[ "$WAIT" =~ ^[1-9][0-9]*$ ]] || { echo "APU_REGRESS_TIMEOUT must be positive seconds" >&2; exit 2; }
command -v python3 >/dev/null && command -v timeout >/dev/null || exit 3
OUT="${OUT:-$ROOT/.cache/apu-regress/$(date +%Y%m%d-%H%M%S)-$$}"
[ ! -e "$OUT" ] && [ ! -L "$OUT" ] || { echo "refusing existing output: $OUT" >&2; exit 2; }
mkdir -p "$(dirname "$OUT")" && mkdir "$OUT" || exit 2
# the per-suite scripts cd to verif/tb/apu to run — OUT must be absolute
OUT="$(cd "$OUT" && pwd)"

has() { case ",$STAGES," in *",$1,"*) return 0;; esac; return 1; }

source_manifest() {
  python3 -B "$TB/apu_source_manifest.py" "$ROOT" "$STAGES"
}
source_manifest > "$OUT/source-before.json" || exit 4

run_suite() { # name command...
  local name="$1"; shift
  local log="$OUT/$name.log" started=$SECONDS
  echo "=== [$name] $(date +%H:%M:%S) -> $log"
  timeout --kill-after=30 "$WAIT" "$@" > "$log" 2>&1
  local rc=$?
  printf '%s\t%s\t%s\t' "$name" "$rc" "$((SECONDS-started))" >> "$OUT/results.tsv"
  printf '%q ' "$@" >> "$OUT/results.tsv"
  printf '\n' >> "$OUT/results.tsv"
  tail -3 "$log" | sed 's/^/    /'
  echo "=== [$name] done rc=$rc (verdict pending evidence checks)"
  return "$rc"
}

if has profile; then
  run_suite profile python3 -B "$ROOT/corev_apu/apu/tools/gen_vn_tables.py" --audit-profile
fi

if has unit; then
  run_suite objtab   env APU_OBJTAB_OUT="$OUT/objtab"   "$TB/run-apu-objtab.sh"
  run_suite vgpages  env APU_VGPAGES_OUT="$OUT/vgpages" "$TB/run-apu-vgpages.sh"
  run_suite vgctl    env APU_VGCTL_OUT="$OUT/vgctl"     "$TB/run-apu-vgctl.sh"
  run_suite vnfront  env APU_VNFRONT_OUT="$OUT/vnfront" "$TB/run-apu-vnfront.sh"
  run_suite cmdexec  env APU_CMDEXEC_OUT="$OUT/cmdexec" "$TB/run-apu-cmdexec.sh"
  run_suite xfer     env APU_XFER_OUT="$OUT/xfer"       "$TB/run-apu-xfer.sh"
  run_suite rast     env APU_RAST_OUT="$OUT/rast"       "$TB/run-apu-rast.sh"
  run_suite gcs      env APU_GCS_OUT="$OUT/gcs"         "$TB/run-apu-gcs.sh"
  run_suite vndec    env APU_VNDEC_OUT="$OUT/vndec"     "$TB/run-apu-vndec.sh"
  run_suite vnrep    env APU_VNREP_OUT="$OUT/vnrep"     "$TB/run-apu-vnrep.sh"
  run_suite vnpump   env APU_VNPUMP_OUT="$OUT/vnpump"   "$TB/run-apu-vnpump.sh"
  run_suite shmod    env APU_SHMOD_OUT="$OUT/shmod"     "$TB/run-apu-shmod.sh"
  run_suite dmprog   python3 -B \
    "$ROOT/corev_apu/apu/tools/shader/gen_dmprog.py" --check
  run_suite shwave-sfu python3 -B \
    "$ROOT/corev_apu/apu/tools/shader/gen_sfu_tables.py" --check
  run_suite shwave   env APU_SHWAVE_OUT="$OUT/shwave"   "$TB/run-apu-shwave.sh"
  run_suite shcore   env APU_SHCORE_OUT="$OUT/shcore"   "$TB/run-apu-shcore.sh"
fi
if has top; then
  run_suite vgtop     env APU_VGTOP_OUT="$OUT/vgtop"        "$TB/run-apu-vgtop.sh"
  run_suite vgsys     env APU_VGSYS_OUT="$OUT/vgsys"        "$TB/run-apu-vgsys.sh"
  run_suite sys-venus env APU_SYSVENUS_OUT="$OUT/sys-venus" "$TB/run-apu-sys-venus.sh"
fi
if has soc; then
  run_suite cva6-venus env APU_VENUS_OUT="$OUT/cva6-venus"  "$TB/run-cva6-venus.sh"
fi
if has bridge || has guest; then
  export APU_BRIDGE_OUT="$OUT/bridge"
  export G6LC_SOCKDIR
  G6LC_SOCKDIR="$(mktemp -d "${TMPDIR:-/tmp}/g6lc-apu-sock.XXXXXXXX")" || exit 4
  if run_suite bridge-build "$TB/bridge/build-bridge.sh"; then
    if has bridge; then
      run_suite bridge-selftest \
        python3 "$TB/bridge/bridge_selftest.py" \
          --map "$APU_BRIDGE_OUT/bridge_map.h" \
          --server "$APU_BRIDGE_OUT/obj_venus/apu_bridge" \
          --server-off "$APU_BRIDGE_OUT/obj_venusoff/apu_bridge" \
          --sock "$G6LC_SOCKDIR/selftest.sock" --out "$OUT/bridge"
    fi
    if has guest; then
      export GUEST_CACHE="$OUT/guest-cache"
      run_suite guest "$TB/bridge/run-guest.sh" --out "$OUT/guest"
    fi
  else
    if has bridge; then run_suite bridge-selftest bash -c 'echo "BLOCKED: bridge build failed"; exit 4'; fi
    if has guest; then run_suite guest bash -c 'echo "BLOCKED: bridge build failed"; exit 4'; fi
  fi
fi
if has synth; then
  run_suite synth-vgpages env VGPAGES_SYNTH=1 \
    APU_VGPAGES_OUT="$OUT/synth/vgpages" "$TB/run-apu-vgpages.sh"
  run_suite synth-objtab env OBJTAB_SYNTH=1 \
    APU_OBJTAB_OUT="$OUT/synth/objtab" "$TB/run-apu-objtab.sh"
  run_suite synth-vnpump env VNPUMP_SYNTH=1 \
    APU_VNPUMP_OUT="$OUT/synth/vnpump" "$TB/run-apu-vnpump.sh"
  run_suite synth-cmdexec env CMDEXEC_SYNTH=1 \
    APU_CMDEXEC_OUT="$OUT/synth/cmdexec" "$TB/run-apu-cmdexec.sh"
  run_suite synth-vgctl env VGCTL_SYNTH=1 \
    APU_VGCTL_OUT="$OUT/synth/vgctl" "$TB/run-apu-vgctl.sh"
  run_suite synth-rast env RAST_SYNTH=1 \
    APU_RAST_OUT="$OUT/synth/rast" "$TB/run-apu-rast.sh"
  run_suite synth-vnfront env VNFRONT_SYNTH=1 VNFRONT_SYNTH_PREONLY=0 \
    APU_VNFRONT_OUT="$OUT/synth/vnfront" "$TB/run-apu-vnfront.sh"
fi

# ----------------------------------------------------------- summary
source_manifest > "$OUT/source-after.json" || exit 4
python3 - "$OUT" "$STAGES" <<'PY'
import hashlib, json, re, sys
from pathlib import Path
out = Path(sys.argv[1])
before = json.loads((out / 'source-before.json').read_text())
after = json.loads((out / 'source-after.json').read_text())
results = []
print('\n=================== APU REGRESSION SUMMARY ===================')
for line in (out / 'results.tsv').read_text().splitlines():
    name, rc, duration, command = line.split('\t', 3)
    rc = int(rc)
    log = out / (name + '.log')
    data = log.read_bytes()
    text = data.decode(errors='replace')
    passes = re.findall(r'^(?:\[[^\]\n]+\] )?PASS tb_.*$', text, re.M)
    checks = sum(int(n) for row in passes for n in re.findall(r'\bchecks=(\d+)\b', row))
    audit = None
    if name == 'profile':
        try:
            audit = json.loads(text)
            if isinstance(audit, dict) and type(audit.get('checkedRules')) is int:
                checks = audit['checkedRules']
        except ValueError:
            pass
    status, reason = 'pass', ''
    if re.search(r'^(?:\[[^\]\n]+\] )?(?:FAIL\b|GUEST-FAIL\b|%Error|SYNTH FAILED|VERILATOR BUILD FAILED)|^RETAINED_MEM_ASSERT FAIL', text, re.M):
        status, reason = 'fail', 'failure diagnostic'
    elif rc in (4, 124, 137):
        status, reason = 'incomplete', 'blocked, interrupted or timed out'
    elif rc:
        status, reason = 'fail', f'exit {rc}'
    elif re.search(r'^(?:SYNTH )?(?:SKIPPED|INCOMPLETE|BLOCKED|PREONLY)\b', text, re.M):
        status, reason = 'incomplete', 'selected work did not finish'
    elif name == 'bridge-build':
        if not all(re.search(r'^BUILD OK \(' + arm + r'\)', text, re.M) for arm in ('venus', 'venusoff')):
            status, reason = 'incomplete', 'both bridge builds must complete'
    elif name == 'bridge-selftest':
        match = re.search(r'^\[selftest\] total checks=([1-9]\d*) -> PASS$', text, re.M)
        checks = int(match[1]) if match else 0
        if not checks:
            status, reason = 'incomplete', 'missing checked bridge verdict'
    elif name == 'guest':
        arms = [out / 'guest' / f'drive-{arm}.log' for arm in ('venus', 'venusoff')]
        if any(not p.is_file() or p.read_text(errors='replace').strip().splitlines()[-1:] != ['GUEST-PASS'] for p in arms):
            status, reason = 'incomplete', 'both guest arms need terminal GUEST-PASS'
    elif name == 'profile':
        if not isinstance(audit, dict) or audit.get('status') != 'pass' or checks <= 0:
            status, reason = 'incomplete', 'missing profile audit verdict'
    elif not checks:
        status, reason = 'incomplete', 'no positive checked simulation verdict'
    if status == 'pass' and name.startswith('synth-'):
        geometries = (8192, 65536) if name == 'synth-vgpages' else (None,)
        for geometry in geometries:
            for enabled in (0, 1):
                suffix = f' Pages={geometry}' if geometry is not None else ''
                if not re.search(r'^SYNTH OK Enable=' + str(enabled) + suffix + r'$', text, re.M):
                    status, reason = 'incomplete', 'missing full enabled/disabled synthesis'
    results.append({'name': name, 'status': status, 'rc': rc, 'durationSeconds': int(duration),
                    'checks': checks, 'reason': reason, 'command': command,
                    'log': log.name, 'logSha256': hashlib.sha256(data).hexdigest()})
    if isinstance(audit, dict):
        results[-1]['profileAudit'] = audit
    print(f'{name:18} {status.upper():10} checks={checks:<8} {reason}')
drift = before['sourceSha256'] != after['sourceSha256']
status = ('fail' if any(r['status'] == 'fail' for r in results) else
          'incomplete' if not results or drift or any(r['status'] != 'pass' for r in results) else 'pass')
if drift:
    print('INCOMPLETE: source changed during the run')
report = {'schemaVersion': 1, 'status': status, 'qualification': False,
          'scope': 'selected stages only; not Vulkan conformance, full-SoC or physical qualification',
          'stages': sys.argv[2].split(','), 'results': results,
          'sourceSha256Before': before['sourceSha256'], 'sourceSha256After': after['sourceSha256'],
          'proxyTag': before['proxyTag']}
(out / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
print(f'logs: {out}')
print(f'APU-REGRESS {status.upper()} (selected stages only: {sys.argv[2]})')
sys.exit({'pass': 0, 'fail': 1, 'incomplete': 4}[status])
PY
