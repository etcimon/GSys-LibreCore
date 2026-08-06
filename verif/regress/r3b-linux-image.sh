#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# R3b Linux Image gate (AGENTS-todo §6).
#
# Phases:
#   A. Contract gate (always) — scripts/docs/DTS/OpenSBI --linux path present
#   B. Image present? — soft-skip unless CVA6_REQUIRE_R3B=1
#   C. Optional: rebuild OpenSBI with LINUX_IMAGE as FW_PAYLOAD (R3b firmware)
#   D. Optional: cosim if CVA6_R3B_COSIM=1 (heavy; needs smt2 TB)
#
# How to obtain Image (external; not in git):
#   See software/smt2-linux/scripts/fetch-linux-image-hint.sh
#   and architecture/multi-threading/smt-linux-rootfs.md (R3b).
#
# Usage:
#   bash verif/regress/r3b-linux-image.sh
#   LINUX_IMAGE=/path/to/Image bash verif/regress/r3b-linux-image.sh
#   CVA6_REQUIRE_R3B=1 LINUX_IMAGE=... bash verif/regress/r3b-linux-image.sh
#   CVA6_R3B_BUILD=1 LINUX_IMAGE=... bash verif/regress/r3b-linux-image.sh

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

OUT="${SMT2_LINUX_OUT:-$ROOT/build-platform/workspace/smt2-linux}"
mkdir -p "$OUT"
REQUIRE="${CVA6_REQUIRE_R3B:-0}"
DO_BUILD="${CVA6_R3B_BUILD:-0}"
DO_COSIM="${CVA6_R3B_COSIM:-0}"
IMG="${LINUX_IMAGE:-}"
if [[ -z "$IMG" && -f "$OUT/Image" ]]; then
  IMG="$OUT/Image"
fi

log() { echo "[r3b-linux-image] $*"; }
fail() { log "FAIL: $*"; exit 1; }
skip() { log "SKIP: $*"; exit 0; }

log "=== R3b Linux Image gate ==="
log "OUT=$OUT REQUIRE=$REQUIRE BUILD=$DO_BUILD COSIM=$DO_COSIM"

# ---------------- A. contract gate ----------------
log "--- A. contract"
required=(
  architecture/multi-threading/smt-linux-rootfs.md
  software/smt2-linux/README.md
  software/smt2-linux/Makefile
  software/smt2-linux/scripts/build-opensbi-smt2.sh
  software/smt2-linux/scripts/fetch-opensbi.sh
  software/smt2-linux/payload/smt2_sbi_dual.S
  corev_apu/bootrom/ariane-smt2.dts
  verif/regress/smt-linux-rootfs.sh
  verif/regress/smt-linux-r3-cosim.sh
  verif/regress/opensbi-linux-boot.sh
)
for f in "${required[@]}"; do
  test -f "$f" || fail "missing $f"
  log "  ok $f"
done

grep -q "R3b" architecture/multi-threading/smt-linux-rootfs.md || \
  fail "smt-linux-rootfs.md must document R3b"
grep -q "LINUX_IMAGE" software/smt2-linux/scripts/build-opensbi-smt2.sh || \
  fail "build-opensbi-smt2.sh must honor LINUX_IMAGE"
grep -q -- "--linux" software/smt2-linux/scripts/build-opensbi-smt2.sh || \
  fail "build-opensbi-smt2.sh must support --linux"
grep -q "opensbi-linux" software/smt2-linux/Makefile || \
  fail "Makefile missing opensbi-linux target"
grep -q "maxcpus=2" corev_apu/bootrom/ariane-smt2.dts || \
  fail "ariane-smt2.dts must keep maxcpus=2 for dual-hart Linux"
grep -q "bootargs" corev_apu/bootrom/ariane-smt2.dts || \
  fail "ariane-smt2.dts must provide bootargs"
log "  ok R3b contract markers"

# dual-hart package still primary for R3b sim
if [[ -f core/include/g6lc64_smt2_config_pkg.sv ]]; then
  grep -q "NrHarts: *unsigned'(2)" core/include/g6lc64_smt2_config_pkg.sv || \
    fail "g6lc64_smt2 NrHarts!=2"
  log "  ok g6lc64_smt2 NrHarts=2"
fi

# ---------------- B. Image present? ----------------
log "--- B. LINUX_IMAGE"
if [[ -z "$IMG" ]]; then
  log "  no LINUX_IMAGE and no $OUT/Image"
  log "  obtain via cva6-sdk Buildroot (see software/smt2-linux/scripts/fetch-linux-image-hint.sh)"
  if [[ "$REQUIRE" == "1" ]]; then
    fail "CVA6_REQUIRE_R3B=1 but no Image (set LINUX_IMAGE=...)"
  fi
  skip "R3b Image external — contract gate only (soft-skip)"
fi

test -f "$IMG" || fail "LINUX_IMAGE not a file: $IMG"
sz=$(stat -c%s "$IMG" 2>/dev/null || stat -f%z "$IMG" 2>/dev/null || echo 0)
# Kernel Images are typically multi-MB; reject empty/tiny placeholders
if [[ "$sz" -lt 100000 ]]; then
  fail "Image too small (${sz} bytes) — not a real Linux Image"
fi
log "  ok Image $IMG (${sz} bytes)"

# crude magic: ARM/RISC-V Image often starts with MZ or has "ARM" / binary header;
# RISC-V Image is raw binary — just require non-ELF or accept ELF too.
if file "$IMG" 2>/dev/null | grep -qiE "ASCII text|empty"; then
  fail "Image looks like text/empty — need kernel binary"
fi
log "  ok Image not plain text"

# ---------------- C. optional OpenSBI rebuild ----------------
log "--- C. OpenSBI + Linux payload"
if [[ "$DO_BUILD" != "1" ]]; then
  log "  skip firmware rebuild (set CVA6_R3B_BUILD=1 to build)"
  log "  manual: LINUX_IMAGE=$IMG ./software/smt2-linux/scripts/build-opensbi-smt2.sh --linux"
else
  export LINUX_IMAGE="$IMG"
  if ! command -v make >/dev/null 2>&1; then
    fail "make required for CVA6_R3B_BUILD=1"
  fi
  # Prefer linux-gnu cross for OpenSBI when available
  if [[ -z "${CROSS_COMPILE:-}" ]]; then
    for p in riscv64-unknown-linux-gnu- riscv64-linux-gnu- riscv-none-elf- riscv64-unknown-elf-; do
      if command -v "${p}gcc" >/dev/null 2>&1; then
        export CROSS_COMPILE=$p
        break
      fi
    done
  fi
  [[ -n "${CROSS_COMPILE:-}" ]] || fail "no CROSS_COMPILE for OpenSBI build"
  log "  CROSS_COMPILE=$CROSS_COMPILE"
  bash software/smt2-linux/scripts/build-opensbi-smt2.sh --linux
  test -f "$OUT/fw_payload.elf" || fail "fw_payload.elf missing after build"
  fsz=$(stat -c%s "$OUT/fw_payload.elf" 2>/dev/null || stat -f%z "$OUT/fw_payload.elf")
  log "  ok fw_payload.elf (${fsz} bytes)"
  # R3b firmware should be larger than R3a dual-SBI smoke (~few hundred KB–few MB)
  if [[ "$fsz" -lt 200000 ]]; then
    log "  WARN: fw_payload.elf small — check Image was embedded"
  fi
fi

# ---------------- D. optional cosim ----------------
log "--- D. cosim"
if [[ "$DO_COSIM" == "1" ]]; then
  export CVA6_LINUX_PAYLOAD="${CVA6_LINUX_PAYLOAD:-$OUT/fw_payload.elf}"
  test -f "$CVA6_LINUX_PAYLOAD" || fail "no CVA6_LINUX_PAYLOAD for cosim"
  export DV_TARGET="${DV_TARGET:-g6lc64_smt2}"
  log "  invoking smt-linux-r3-cosim.sh (payload=$CVA6_LINUX_PAYLOAD)"
  bash verif/regress/smt-linux-r3-cosim.sh
else
  log "  skip cosim (set CVA6_R3B_COSIM=1 to run RTL/ISS)"
fi

log "PASS R3b gate (Image present; build/cosim as configured)"
exit 0
