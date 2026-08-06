#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SMT2="$ROOT/software/smt2-linux"
OUT="${SMT2_LINUX_OUT:-$ROOT/build-platform/workspace/smt2-linux}"
SRC="${OPENSBI_SRC:-$OUT/opensbi}"
mkdir -p "$OUT"

if [[ "${1:-}" != "--skip-fetch" ]]; then
  "$SMT2/scripts/fetch-opensbi.sh"
fi

# Detect cross compiler
if [[ -z "${CROSS_COMPILE:-}" ]]; then
  for p in riscv64-unknown-elf- riscv-none-elf- riscv64-unknown-linux-gnu- riscv64-linux-gnu-; do
    if command -v "${p}gcc" >/dev/null 2>&1; then
      CROSS_COMPILE=$p
      break
    fi
  done
fi
if [[ -z "${CROSS_COMPILE:-}" ]]; then
  echo "No RISC-V CROSS_COMPILE found" >&2
  exit 2
fi
export CROSS_COMPILE
echo "[build-opensbi-smt2] CROSS_COMPILE=$CROSS_COMPILE"

DTB="$OUT/ariane-smt2.dtb"
python3 "$SMT2/scripts/dts_to_dtb.py" -i "$ROOT/corev_apu/bootrom/ariane-smt2.dts" -o "$DTB"

make -C "$SMT2/payload" clean || true
make -C "$SMT2/payload" CROSS_COMPILE="$CROSS_COMPILE"
cp -f "$SMT2/payload/smt2_sbi_dual.elf" "$OUT/"
cp -f "$SMT2/payload/smt2_sbi_dual.bin" "$OUT/"
PAYLOAD="$OUT/smt2_sbi_dual.bin"

USE_LINUX=0
for a in "$@"; do [[ "$a" == "--linux" ]] && USE_LINUX=1; done
if [[ $USE_LINUX -eq 1 || -n "${LINUX_IMAGE:-}" ]]; then
  IMG="${LINUX_IMAGE:-$OUT/Image}"
  test -f "$IMG"
  PAYLOAD="$IMG"
  echo "[build-opensbi-smt2] Linux payload $PAYLOAD"
fi

BUILD="$OUT/opensbi-build"
# Bare-metal toolchains without -pie (optional)
python3 "$SMT2/scripts/patch_opensbi_nopie.py" "$SRC/Makefile" || true
python3 "$SMT2/scripts/wrap_pie_flags.py" "$SRC/Makefile" || true
# Dual-hart CLINT/PLIC bring-up (ROOT_REGION_MAX, mtime_size, mswi single-init).
# Idempotent; required for ariane-smt2.dts (NrHarts=2, 0xc0000 CLINT, 64 MiB PLIC).
python3 "$SMT2/scripts/patch_opensbi_g6lc_clint.py" "$SRC"
# Prefer full ISA string when the toolchain supports zifencei (fence.i in OpenSBI).
PLATFORM_RISCV_ISA="${PLATFORM_RISCV_ISA:-rv64imafdc_zicsr_zifencei}"
make -C "$SRC" O="$BUILD" PLATFORM=generic distclean || true
make -C "$SRC" O="$BUILD" PLATFORM=generic \
  FW_TEXT_START=0x80000000 \
  FW_PAYLOAD_PATH="$PAYLOAD" \
  FW_FDT_PATH="$DTB" \
  CROSS_COMPILE="$CROSS_COMPILE" \
  OPENSBI_ALLOW_NO_PIE=y \
  PLATFORM_RISCV_ISA="$PLATFORM_RISCV_ISA" \
  -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"

FWDIR="$BUILD/platform/generic/firmware"
for p in fw_payload.elf fw_payload.bin fw_jump.elf fw_jump.bin; do
  [[ -f "$FWDIR/$p" ]] && cp -f "$FWDIR/$p" "$OUT/"
done
test -f "$OUT/fw_payload.elf"
export CVA6_LINUX_PAYLOAD="$OUT/fw_payload.elf"
echo "[build-opensbi-smt2] PASS -> $OUT/fw_payload.elf"
