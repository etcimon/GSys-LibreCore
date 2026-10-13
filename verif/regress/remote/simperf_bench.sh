#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Simulation-speed benchmark battery for a Verilated testharness model (runs ON the
# builder). Produces one table per model so compiler / recipe / runtime changes can be
# compared on numbers that do not depend on builder load:
#
#   ir_per_cycle   callgrind instructions per simulated cycle, collection restricted to
#                  the model evaluation (--toggle-collect='*eval_step*'); deterministic.
#   i1_miss/cyc    callgrind I1 (32 KB) instruction-cache misses per cycle (code volume).
#   cycles/s       wall-clock steady state over a long spin segment (startup subtracted).
#   stats          Verilator --stats counters that describe the code structure the model
#                  was generated from (expand limited, hybrid class size, concat lowering).
#
# Workloads (all retirement-exact against Spike in the regression; the first two are the
# frozen probes, the third is any payload the model can boot):
#   s11      ooo_fp_ooo.elf stage 11 (FP + integer OoO mix, 10.9 k cycles)   [callgrind]
#   wprp     ooo_wrongpath_replay.elf (recovery-heavy, ~1 k cycles)          [callgrind]
#   spin     s11 with a non-matching tohost -> runs to the cap (steady state) [timing]
#   boot     optional: OpenSBI fw_payload.elf + tohost for this model's shape [timing]
#
# usage: simperf_bench.sh MODEL_DIR OUT_DIR [BOOT_ELF BOOT_TOHOST BOOT_CYCLES]
#   MODEL_DIR  directory holding Variane_testharness (and optionally *__stats.txt)
#   OUT_DIR    results directory (callgrind.out.*, *.log, bench.json, bench.txt)
# env: S11_ELF, WPRP_ELF (defaults: the t21i probe runs), VALGRIND (default toolchains/valgrind)
# Not 'set -e': every measurement is optional and guarded; a missing workload or counter
# must not abort the rest of the battery.
set -u
MODEL_DIR="$1"; OUT="$2"; BOOT_ELF="${3:-}"; BOOT_TOHOST="${4:-}"; BOOT_CYCLES="${5:-2000000}"
MODEL="$MODEL_DIR/Variane_testharness"
VG="${VALGRIND:-/opt/testharness/toolchains/valgrind/bin}"
S11_ELF="${S11_ELF:-/opt/testharness/runs/ooocoh-t21i-ooo-s11/output/ooo_fp_ooo.elf}"
WPRP_ELF="${WPRP_ELF:-/opt/testharness/runs/ooocoh-t21i-ooo-wprp/output/negative0/directed.elf}"
S11_TOHOST=0x0000000080002000
# tohost of the directed ELF from its symbol table (the directed route does the same).
NM="${RISCV:-/opt/testharness/toolchains/xpack-riscv-none-elf-gcc-14.2.0-3}/bin/riscv-none-elf-nm"
if [[ -z "${WPRP_TOHOST:-}" && -f "$WPRP_ELF" && -x "$NM" ]]; then
  WPRP_TOHOST=$("$NM" "$WPRP_ELF" 2>/dev/null | awk '$3=="tohost"{print "0x"$1; exit}')
fi
WPRP_TOHOST="${WPRP_TOHOST:-$S11_TOHOST}"
mkdir -p "$OUT"
[[ -x "$MODEL" ]] || { echo "no model at $MODEL" >&2; exit 2; }

common=(--seed=1 +debug_disable +quiet_axi)
cycles_of() { grep -o "terminated after *[0-9]*" "$1" | grep -o "[0-9]*$" | tail -1; }

# --- callgrind: instructions per cycle, eval only ----------------------------------------
cg_run() {  # name elf tohost cap
  local name=$1 elf=$2 tohost=$3 cap=$4
  [[ -f "$elf" ]] || { echo "$name: elf missing ($elf)" >&2; return 0; }
  "$VG/valgrind" --tool=callgrind --callgrind-out-file="$OUT/callgrind.out.$name" \
      --collect-atstart=no "--toggle-collect=*eval_step*" --cache-sim=yes --branch-sim=no \
      "$MODEL" "${common[@]}" +max-cycles=$cap +time_out=$cap +tohost_addr=$tohost "$elf" \
      > "$OUT/cg-$name.log" 2>&1 || true
  local ir i1 cyc
  ir=$(grep -a "I *refs:" "$OUT/cg-$name.log" | head -1 | tr -d ',' | awk '{print $NF}')
  i1=$(grep -a "I1 *misses:" "$OUT/cg-$name.log" | head -1 | tr -d ',' | awk '{print $NF}')
  cyc=$(cycles_of "$OUT/cg-$name.log"); ir=${ir:-0}; i1=${i1:-0}
  echo "$name ir=$ir i1=$i1 cycles=$cyc"
  if [[ -n "$cyc" && "$cyc" -gt 0 ]]; then
    echo "{\"workload\":\"$name\",\"ir_per_cycle\":$((ir / cyc)),\"i1_miss_per_cycle\":$((i1 / cyc)),\"cycles\":$cyc}" >> "$OUT/bench.jsonl"
  fi
}
: > "$OUT/bench.jsonl"
cg_run s11 "$S11_ELF" $S11_TOHOST 40000
cg_run wprp "$WPRP_ELF" $WPRP_TOHOST 40000

# --- wall clock: steady state on a spin segment (startup subtracted) ---------------------
t_run() {  # cap -> seconds
  local cap=$1
  /usr/bin/time -f "%e" "$MODEL" "${common[@]}" +max-cycles=$cap +time_out=$cap \
      +tohost_addr=0x0000000080002008 "$S11_ELF" > "$OUT/spin-$cap.log" 2> "$OUT/spin-$cap.time" || true
  tail -1 "$OUT/spin-$cap.time"
}
t_short=$(t_run 20000); t_long=$(t_run 220000)
cps=$(awk -v a="$t_short" -v b="$t_long" 'BEGIN{ if (b>a) printf "%.0f", 200000/(b-a); else print 0 }')
echo "spin cycles/s=$cps (startup ${t_short}s)"
echo "{\"workload\":\"spin\",\"cycles_per_s\":$cps,\"startup_s\":$t_short}" >> "$OUT/bench.jsonl"

# --- optional boot segment -----------------------------------------------------------------
if [[ -n "$BOOT_ELF" && -f "$BOOT_ELF" ]]; then
  /usr/bin/time -f "%e" "$MODEL" "${common[@]}" +smt_progress +max-cycles=$BOOT_CYCLES +time_out=$BOOT_CYCLES \
      +tohost_addr=$BOOT_TOHOST "$BOOT_ELF" > "$OUT/boot.log" 2> "$OUT/boot.time" || true
  tb=$(tail -1 "$OUT/boot.time"); bc=$(cycles_of "$OUT/boot.log"); bc=${bc:-$BOOT_CYCLES}
  bcps=$(awk -v t="$tb" -v s="$t_short" -v c="$bc" 'BEGIN{ if (t>s) printf "%.0f", c/(t-s); else print 0 }')
  echo "boot cycles/s=$bcps over $bc cycles"
  echo "{\"workload\":\"boot\",\"cycles_per_s\":$bcps,\"cycles\":$bc}" >> "$OUT/bench.jsonl"
fi

# --- Verilator structure counters -----------------------------------------------------------
S=$(ls "$MODEL_DIR"/*__stats.txt 2>/dev/null | head -1)
if [[ -n "$S" ]]; then
  grep -E "expand limited|expand wides|size of class: hybrid|Suppressed UNOPTFLAT|concat assigns lowered|concat leaves lowered|Split packed variables|Trigger word tests|Trigger bits merged|Clock skip" "$S" \
    | sed 's/  */ /g' | tee "$OUT/stats.txt"
fi
sha=$(sha256sum "$MODEL" | cut -c1-16)
{ echo "model $sha  $(date -u +%FT%TZ)"; cat "$OUT/bench.jsonl"; } > "$OUT/bench.txt"
cat "$OUT/bench.txt"
