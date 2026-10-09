#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# run-apu-regress — unified APU/Venus regression launcher.
#
#   run-apu-regress.sh [--stages LIST] [--out DIR] [--remote]
#
# Stages (default: unit,top,soc,bridge):
#   unit   objtab vgpages(8192+65536) vgctl vnfront cmdexec xfer gcs
#          vndec vnrep vnpump shmod shwave shcore
#   top    vgtop(2 gate steps) vgsys(+negative arms) sys-venus
#   soc    cva6-venus (incl. venusoff)
#   bridge RTL bridge socket self-test (build-bridge + bridge_selftest)
#   guest  stock Ubuntu riscv64 Venus gate (run-guest.sh; heavy — the
#          image download is ~1.2 GiB the first time)
#   synth  Enable=0/1 yosys screens for vgpages(2 geoms) objtab vnfront
#          vnpump cmdexec vgctl (re-runs each suite with its *_SYNTH=1
#          flag; vnfront goes through the remote proxy with --remote,
#          else falls back to the pre-synthesis stat —
#          VNFRONT_SYNTH_PREONLY — since full `synth` OOMs on a 15 GiB
#          WSL VM)
#
# Everything is serial (WSL + yosys do not survive parallel OOM).
# Logs persist under --out (default .cache/apu-regress/<ts>).
# Prints a summary table and exits non-zero on any suite failure.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
export CVA6_REPO_DIR="$ROOT"
TB="$ROOT/verif/tb/apu"
STAGES="unit,top,soc,bridge"
OUT=""
REMOTE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --stages) STAGES="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --remote) REMOTE=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
OUT="${OUT:-$ROOT/.cache/apu-regress/$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"
# the per-suite scripts cd to verif/tb/apu to run — OUT must be absolute
OUT="$(cd "$OUT" && pwd)"

has() { case ",$STAGES," in *",$1,"*) return 0;; esac; return 1; }

declare -a NAMES RCS NOTES
run_suite() { # name command...
  local name="$1"; shift
  local log="$OUT/$name.log"
  echo "=== [$name] $(date +%H:%M:%S) -> $log"
  "$@" > "$log" 2>&1
  local rc=$?
  NAMES+=("$name"); RCS+=("$rc")
  if [ "$rc" -eq 0 ]; then NOTES+=("PASS"); else NOTES+=("FAIL rc=$rc"); fi
  tail -3 "$log" | sed 's/^/    /'
  echo "=== [$name] done rc=$rc"
}

if has unit; then
  run_suite objtab   env APU_OBJTAB_OUT="$OUT/objtab"   "$TB/run-apu-objtab.sh"
  run_suite vgpages  env APU_VGPAGES_OUT="$OUT/vgpages" "$TB/run-apu-vgpages.sh"
  run_suite vgctl    env APU_VGCTL_OUT="$OUT/vgctl"     "$TB/run-apu-vgctl.sh"
  run_suite vnfront  env APU_VNFRONT_OUT="$OUT/vnfront" "$TB/run-apu-vnfront.sh"
  run_suite cmdexec  env APU_CMDEXEC_OUT="$OUT/cmdexec" "$TB/run-apu-cmdexec.sh"
  run_suite xfer     env APU_XFER_OUT="$OUT/xfer"       "$TB/run-apu-xfer.sh"
  run_suite gcs      env APU_GCS_OUT="$OUT/gcs"         "$TB/run-apu-gcs.sh"
  run_suite vndec    env APU_VNDEC_OUT="$OUT/vndec"     "$TB/run-apu-vndec.sh"
  run_suite vnrep    env APU_VNREP_OUT="$OUT/vnrep"     "$TB/run-apu-vnrep.sh"
  run_suite vnpump   env APU_VNPUMP_OUT="$OUT/vnpump"   "$TB/run-apu-vnpump.sh"
  run_suite shmod    env APU_SHMOD_OUT="$OUT/shmod"     "$TB/run-apu-shmod.sh"
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
if has bridge; then
  export APU_BRIDGE_OUT="${APU_BRIDGE_OUT:-$OUT/bridge}"
  if [ ! -x "$APU_BRIDGE_OUT/obj_venus/apu_bridge" ] || \
     [ ! -x "$APU_BRIDGE_OUT/obj_venusoff/apu_bridge" ]; then
    run_suite bridge-build "$TB/bridge/build-bridge.sh"
  fi
  run_suite bridge-selftest \
    python3 "$TB/bridge/bridge_selftest.py" \
      --map "$APU_BRIDGE_OUT/bridge_map.h" \
      --server "$APU_BRIDGE_OUT/obj_venus/apu_bridge" \
      --server-off "$APU_BRIDGE_OUT/obj_venusoff/apu_bridge" \
      --sock /tmp/g6lc-apu-rtl.sock --out "$OUT/bridge"
fi
if has guest; then
  run_suite guest "$TB/bridge/run-guest.sh" --out "$OUT/guest"
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
  if [ "$REMOTE" = 1 ] && \
     ssh -o BatchMode=yes -o ConnectTimeout=5 \
         "${G6LC_REMOTE:-ovh_calltorch}" true 2>/dev/null; then
    run_suite synth-vnfront \
      python3 "$ROOT/verif/regress/remote/testharness_proxy.py" shell -- \
        "cd repo && command -v yosys >/dev/null && \
         yosys -Q -T /dev/stdin <<'YS' || exit 9
read_slang -f corev_apu/apu/Flist.apu_vnfront --top g6lc_apu_vnfront_fixture -GEnable=1
hierarchy -top g6lc_apu_vnfront_fixture
flatten; proc; opt; memory_collect; check -assert; stat
synth -top g6lc_apu_vnfront_fixture -noabc; check -assert; stat
select -assert-none t:\$dlatch t:\$_DLATCH_*
YS"
  else
    [ "$REMOTE" = 1 ] && echo "[synth] remote proxy unreachable —" \
      "vnfront gets the pre-synthesis stat fallback"
    run_suite synth-vnfront env VNFRONT_SYNTH=1 VNFRONT_SYNTH_PREONLY=1 \
      APU_VNFRONT_OUT="$OUT/synth/vnfront" "$TB/run-apu-vnfront.sh"
  fi
fi

# ----------------------------------------------------------- summary
echo
echo "=================== APU REGRESSION SUMMARY ==================="
fail=0
for i in "${!NAMES[@]}"; do
  log="$OUT/${NAMES[$i]}.log"
  cases=$(grep -oE 'cases=[0-9]+' "$log" | awk -F= '{s+=$2} END{print s+0}')
  checks=$(grep -oE 'checks=[0-9]+' "$log" | awk -F= '{s+=$2} END{print s+0}')
  cyc=$(grep -oE 'cycles=[0-9]+' "$log" | awk -F= '{s+=$2} END{print s+0}')
  printf '%-18s %-10s cases=%-6s checks=%-8s cycles=%s\n' \
    "${NAMES[$i]}" "${NOTES[$i]}" "$cases" "$checks" "$cyc"
  [ "${RCS[$i]}" -eq 0 ] || fail=1
done
echo "logs: $OUT"
[ "$fail" = 0 ] && echo "APU-REGRESS PASS" || echo "APU-REGRESS FAIL"
exit $fail
