#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Dry-run seed EDK2 patches against official tianocore/edk2 @ pin (two files).
# Does not use github.com/etcimon/edk2.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIN="${EDK2_REF:-edk2-stable202511}"
URL="https://raw.githubusercontent.com/tianocore/edk2/${PIN}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p \
  "$TMP/MdePkg/Library/BaseLib/RiscV64" \
  "$TMP/UefiCpuPkg/Library/CpuExceptionHandlerLib/RiscV"
: > "$TMP/edksetup.sh"
curl -fsSL "$URL/MdePkg/Library/BaseLib/RiscV64/RiscVInterrupt.S" \
  -o "$TMP/MdePkg/Library/BaseLib/RiscV64/RiscVInterrupt.S"
curl -fsSL "$URL/UefiCpuPkg/Library/CpuExceptionHandlerLib/RiscV/ExceptionHandler.h" \
  -o "$TMP/UefiCpuPkg/Library/CpuExceptionHandlerLib/RiscV/ExceptionHandler.h"
export EDK2_SRC="$TMP"
bash "$HERE/apply-patches.sh"
grep -q "csrc  CSR_SSTATUS, t0" \
  "$TMP/MdePkg/Library/BaseLib/RiscV64/RiscVInterrupt.S"
grep -q "SMODE_TRAP_REGS_##x) \* 8" \
  "$TMP/UefiCpuPkg/Library/CpuExceptionHandlerLib/RiscV/ExceptionHandler.h"
echo CHECK_EDK2_PATCHES_OK pin="$PIN"
