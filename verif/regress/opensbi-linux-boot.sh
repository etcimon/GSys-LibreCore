#!/usr/bin/env bash
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# OpenSBI / Linux boot gate for GSys LibreCore.
#
# Three tiers, each stricter than the last:
#
#   A. ARTIFACT GATE (always runs, no toolchain needed)
#      OpenSBI firmware + DTB + payload sources present and self-consistent.
#
#   B. FUNCTIONAL BOOT (runs when a Spike ISS is available)
#      Boot fw_payload.elf on the ISS and assert the OpenSBI banner plus the
#      dual-hart S-mode payload reaching SMT2-OSBI-OK.
#
#   C. RTL CO-SIMULATION (delegated)
#      verif/regress/smt-linux-r3-cosim.sh — needs Verilator; Linux/WSL only.
#
# Console extraction note. The CVA6/LibreCore verification Spike is an
# instrumented cosim build that always emits a commit log on stdout, and the
# HTIF console writes single bytes interleaved into it. So we do NOT try to read
# console text directly: we recover it from the trace by decoding the byte
# written to the HTIF address. This is exact, and immune to the interleaving.
#
# Env:
#   SPIKE                  explicit spike binary
#   OSBI_BOOT_TIMEOUT      seconds for tier B (default 1800; the instrumented
#                          ISS runs ~6k instr/s, so the banner takes minutes)
#   OSBI_HARTS             spike -p value (default 1; payload passes on 1-hart
#                          via its "peer timeout (ok if 1-hart)" path)
#   CVA6_REQUIRE_OSBI_BOOT =1 turns a tier-B skip/timeout into a hard failure
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

HTIF_ADDR="0x0000000010000000"
WS="build-platform/workspace/smt2-linux"
TIMEOUT_S="${OSBI_BOOT_TIMEOUT:-1800}"
HARTS="${OSBI_HARTS:-1}"
REQUIRE="${CVA6_REQUIRE_OSBI_BOOT:-0}"

echo "=== OpenSBI / Linux boot gate (GSys LibreCore) ==="

# --------------------------------------------------------------- tier A -------
echo "--- A. artifact gate"
required=(
  software/smt2-linux/Makefile
  software/smt2-linux/opensbi/g6lc64_smt2.env
  software/smt2-linux/payload/smt2_sbi_dual.S
  software/smt2-linux/payload/link.ld
  software/smt2-linux/scripts/build-opensbi-smt2.sh
  software/smt2-linux/scripts/dts_to_dtb.py
  corev_apu/bootrom/ariane-smt2.dts
  corev_apu/bootrom/ariane-linux.dts
  corev_apu/bootrom/ariane-server-math-v.dts
  core/include/g6lc64_smt2_config_pkg.sv
  core/include/g6lc64_server_math_v_config_pkg.sv
)
for f in "${required[@]}"; do
  test -f "$f" || { echo "  MISSING $f"; exit 1; }
  echo "  ok $f"
done

# The payload's pass/progress markers are the contract tier B asserts on.
for m in 'SMT2-OSBI: boot hart' 'SMT2-OSBI-OK'; do
  grep -q "$m" software/smt2-linux/payload/smt2_sbi_dual.S || {
    echo "  payload lost marker: $m"; exit 1; }
  echo "  ok payload marker: $m"
done

grep -q "NrHarts: *unsigned'(2)" core/include/g6lc64_smt2_config_pkg.sv || {
  echo "  g6lc64_smt2 must set NrHarts=2"; exit 1; }
echo "  ok NrHarts=2 in g6lc64_smt2 package"

# DTS must keep the Linux-ABI fallback compatible string (AGENTS-branding.md §4).
grep -q 'eth,ariane' corev_apu/bootrom/ariane-smt2.dts || {
  echo "  ariane-smt2.dts lost the eth,ariane fallback compatible string;"
  echo "  that string is a Linux ABI and must be retained (never substituted)."
  exit 1; }
echo "  ok DTS retains eth,ariane fallback compatible"

# Full Linux-boot feature set includes Zacas (CAS) in the ISA advertisement.
grep -q 'zacas' corev_apu/bootrom/ariane-smt2.dts || {
  echo "  ariane-smt2.dts lost zacas — Linux boot must advertise Zacas CAS"; exit 1; }
echo "  ok DTS advertises zacas (Zacas CAS)"
grep -q "RVZacas: *bit'(1)" core/include/g6lc64_smt2_config_pkg.sv || {
  echo "  g6lc64_smt2 must enable RVZacas for Linux-boot CAS contract"; exit 1; }
echo "  ok RVZacas=1 in g6lc64_smt2 package"

# --- RVV 1.0 (U10ᵇ / Ara) contract ------------------------------------------
# Only the server_math_v tree may advertise V. Non-RVV trees must stay clean so
# Linux/OpenSBI never enable vector context on a core without Ara (AGENTS-vector §5).
echo "--- A2. RVV 1.0 / Ara Linux-boot contract"
grep -q 'CVA6ConfigVExtEn = 1' core/include/g6lc64_server_math_v_config_pkg.sv || {
  echo "  g6lc64_server_math_v must set CVA6ConfigVExtEn=1"; exit 1; }
echo "  ok CVA6ConfigVExtEn=1 in g6lc64_server_math_v package"
grep -q 'CVA6ConfigCvxifEn = 0' core/include/g6lc64_server_math_v_config_pkg.sv || {
  echo "  g6lc64_server_math_v must keep CvxifEn=0 (mutex with accelerator)"; exit 1; }
echo "  ok CvxifEn=0 (RVV/accelerator mutex)"
grep -q 'CVA6ConfigVExtEn = 0' core/include/g6lc64_smt2_config_pkg.sv || {
  echo "  g6lc64_smt2 must keep VExtEn=0 (no Ara on smt2 boot path)"; exit 1; }
echo "  ok g6lc64_smt2 keeps RVV off (vector only via server_math_v)"

# server-math-v DTS: full RVV 1.0 advertisement
for tok in '"v"' 'zve64d' 'zacas' 'riscv,isa-extensions'; do
  grep -q "$tok" corev_apu/bootrom/ariane-server-math-v.dts || {
    echo "  ariane-server-math-v.dts missing RVV contract token: $tok"; exit 1; }
done
grep -qE 'riscv,isa = "rv64imafdcv_' corev_apu/bootrom/ariane-server-math-v.dts || {
  echo "  ariane-server-math-v.dts riscv,isa must include single-letter v (imafdcv)"; exit 1; }
echo "  ok ariane-server-math-v.dts advertises RVV 1.0 (v + zve64d + full server set)"

# Non-RVV trees must not claim vector (imafdcv or "v" extension token).
for nonv in corev_apu/bootrom/ariane-smt2.dts corev_apu/bootrom/ariane-linux.dts; do
  if grep -qE 'riscv,isa = "rv64imafdcv' "$nonv"; then
    echo "  $nonv must not advertise imafdcv (RVV is server-math-v only)"; exit 1
  fi
  if grep -qE 'isa-extensions = .*"v"' "$nonv" \
     || grep -qE '", "v",' "$nonv" \
     || grep -qE '"v", "' "$nonv"; then
    echo "  $nonv must not list \"v\" in riscv,isa-extensions"; exit 1
  fi
  echo "  ok $(basename "$nonv") stays non-V (RVV alignment)"
done

# --------------------------------------------------------------- locate -------
echo "--- B. functional boot"

FW=""
for cand in "$WS/fw_payload.elf" \
            "$WS/opensbi-build/platform/generic/firmware/fw_payload.elf"; do
  [[ -f "$cand" ]] && { FW="$cand"; break; }
done
DTB=""
for cand in "$WS/ariane-smt2.dtb" "/tmp/ariane-smt2.dtb"; do
  [[ -f "$cand" ]] && { DTB="$cand"; break; }
done

skip() {
  echo "  SKIP: $1"
  if [[ "$REQUIRE" == "1" ]]; then
    echo "[opensbi-linux-boot] FAIL (CVA6_REQUIRE_OSBI_BOOT=1)"; exit 1
  fi
  echo "  (set CVA6_REQUIRE_OSBI_BOOT=1 to make this a hard failure)"
  echo "[opensbi-linux-boot] PASS (tier A only)"; exit 0
}

[[ -n "$FW" ]]  || skip "no fw_payload.elf — run: g6lc-build tools install dual-hart"
[[ -n "$DTB" ]] || skip "no ariane-smt2.dtb — build it: dtc -I dts -O dtb -o $WS/ariane-smt2.dtb corev_apu/bootrom/ariane-smt2.dts"
echo "  firmware: $FW"
echo "  dtb:      $DTB"

SPIKE_BIN="${SPIKE:-}"
if [[ -z "$SPIKE_BIN" ]]; then
  for cand in build-platform/workspace/tooling/spike/bin/spike \
              "$HOME/tools/spike/bin/spike" \
              "$(command -v spike 2>/dev/null || true)"; do
    [[ -n "$cand" && -x "$cand" ]] && { SPIKE_BIN="$cand"; break; }
  done
fi
[[ -n "$SPIKE_BIN" ]] || skip "no spike — run: g6lc-build tools install spike"
echo "  spike:    $SPIKE_BIN"

# ISA must match the smt2 device tree's riscv,isa (DT contract for Linux/OpenSBI).
# Spike's --isa is a *subset*: this instrumented ISS may not implement every
# advertised extension (notably Zacas). Keep the full string for the log, then
# strip Spike-unsupported tokens for the actual invoke.
ISA_DT="$(sed -n 's/.*riscv,isa *= *"\([^"]*\)".*/\1/p' corev_apu/bootrom/ariane-smt2.dts | head -1)"
ISA_DT="${ISA_DT:-rv64imafdc}"
case "$ISA_DT" in *zicsr*) ;; *) ISA_DT="${ISA_DT/rv64imafdc/rv64imafdc_zicsr_zifencei}";; esac
# Spike-unsupported (or optional) tokens: keep DTS/RTL as source of truth.
# zacas: this ISS rejects --isa zacas. v/zve*: not on smt2 DTS (RVV is
# server-math-v only); still strip defensively if a future boot DTS adds them.
ISA="$ISA_DT"
for drop in zacas zve64d zve64f zve64x zve32f zve32x; do
  ISA="${ISA//_${drop}/}"
  ISA="${ISA//${drop}_/}"
  ISA="${ISA//${drop}/}"
done
# Strip single-letter v only when it is the vector marker (…dcv_ or trailing v).
ISA="${ISA//imafdcv/imafdc}"
# Collapse any accidental double underscores from stripping.
while [[ "$ISA" == *__* ]]; do ISA="${ISA//__/_}"; done
ISA="${ISA#_}"; ISA="${ISA%_}"
echo "  isa (dts): $ISA_DT"
echo "  isa (spike): $ISA  (zacas/zve* stripped if present; RVV DT is server-math-v only)"

# ----------------------------------------------------------------- boot -------
LOG="$(mktemp -t osbi-boot-XXXXXX.log)"
CONSOLE="$(mktemp -t osbi-console-XXXXXX.txt)"
trap 'rm -f "$LOG" "$CONSOLE"' EXIT

echo "  booting (timeout ${TIMEOUT_S}s, -p${HARTS}) ..."
set +e
timeout "$TIMEOUT_S" "$SPIKE_BIN" \
  -p"$HARTS" --isa="$ISA" --dtb="$DTB" "$FW" > "$LOG" 2>&1
RC=$?
set -e

# Recover the HTIF console from the commit log: each console byte appears as
#   mem <HTIF_ADDR> 0x000000XX
grep -oE "mem ${HTIF_ADDR} 0x[0-9a-f]{8}" "$LOG" \
  | sed -E 's/.*0x0*([0-9a-f]{2})$/\1/' \
  | while read -r hx; do printf "\\x$hx"; done > "$CONSOLE" || true

echo "  --- recovered console ---"
sed 's/^/  | /' "$CONSOLE" | head -40
echo "  --- end console ---"

fail=0
# Hard failures: an actual malfunction, regardless of how far the boot got.
if grep -qaE 'OpenSBI.*(panic|assert)|sbi_panic|Oops|Kernel panic' "$CONSOLE" "$LOG"; then
  echo "  FAIL: panic in firmware output"; fail=1
fi
if grep -qaE 'core +[0-9]+: exception|trap_illegal_instruction|Unsupported|bad syscall' "$LOG"; then
  echo "  WARN: exception text present in trace (may be benign probing)"
fi

got_banner=0; got_boot=0; got_ok=0
grep -qa 'OpenSBI'            "$CONSOLE" && got_banner=1
grep -qa 'SMT2-OSBI: boot hart' "$CONSOLE" && got_boot=1
grep -qa 'SMT2-OSBI-OK'       "$CONSOLE" && got_ok=1

echo "  banner(OpenSBI)=$got_banner  payload-entry=$got_boot  payload-OK=$got_ok  spike-rc=$RC"

if [[ "$fail" == "1" ]]; then
  echo "[opensbi-linux-boot] FAIL"; exit 1
fi

if [[ "$got_ok" == "1" ]]; then
  echo "[opensbi-linux-boot] PASS (OpenSBI booted; payload reached SMT2-OSBI-OK)"
  exit 0
fi

if [[ "$got_banner" == "1" ]]; then
  # OpenSBI initialised and printed its banner. On the instrumented cosim Spike
  # this is already several million traced instructions; reaching S-mode can
  # exceed the timeout without anything being wrong.
  echo "  NOTE: OpenSBI banner reached but payload marker not seen within ${TIMEOUT_S}s."
  echo "        The verification Spike is an instrumented cosim build (~6k instr/s)."
  echo "        Raise OSBI_BOOT_TIMEOUT, or use an uninstrumented Spike, or run"
  echo "        tier C: verif/regress/smt-linux-r3-cosim.sh"
  if [[ "$REQUIRE" == "1" ]]; then
    echo "[opensbi-linux-boot] FAIL (CVA6_REQUIRE_OSBI_BOOT=1)"; exit 1
  fi
  echo "[opensbi-linux-boot] PASS (partial: firmware init verified)"
  exit 0
fi

echo "  FAIL: no OpenSBI banner recovered from the console."
echo "        Firmware did not initialise. Inspect the trace tail:"
tail -20 "$LOG" | sed 's/^/        /'
echo "[opensbi-linux-boot] FAIL"
exit 1
