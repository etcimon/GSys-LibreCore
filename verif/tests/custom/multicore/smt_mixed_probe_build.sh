#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Build recipe for the smt_mixed_probe two-hart soak (T6b-3 exit / T6b-4a
# measurement vehicle). Produces three ELF flavours from ONE .text image —
# the solo/mixed split is a runtime branch on `probe_solo` in .data, so all
# three share identical code (only .data differs):
#
#   smt_mixed_probe.elf         mixed/drained probe run
#   smt_mixed_probe_solo.elf    +solo reference (hart 0 parks at WFI)
#   smt_mixed_probe_noalias.elf non-aliasing TLB-witness VA — for the
#                               drained/anchor models (shared untagged TLB
#                               is a documented pre-existing limitation there)
#
# EXPECT_CSUM: hart-1 kernel checksum reference = 3287142068561700632
#   (0x2d9e464b9adce718). Provenance: recorded by the +solo run on the
#   mixed-residency model (t6b4-solo-mixed-v1) and independently reproduced
#   by the protected in-order anchor model (t6b4-probe-anchor-v1).
#   Baked into every flavour — same immediate, .text stays byte-identical.
#
# Usage:  ./smt_mixed_probe_build.sh <out_dir>
# Env:    RISCV_GCC   gcc prefix dir containing riscv-none-elf-gcc
#         (default: /opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin)
set -e
OUT="${1:?usage: smt_mixed_probe_build.sh <out_dir>}"
GCC="${RISCV_GCC:-/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin}"
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$OUT"
cd "$HERE/.."
FLAGS="-march=rv64imafdc_zicsr_zifencei -mabi=lp64d -mcmodel=medany -O2 -nostdlib -nostartfiles -T common/link_verilator.ld"
SRC="multicore/smt_mixed_probe.S multicore/smt_mixed_probe_c.c"
CSUM=3287142068561700632
"$GCC/riscv-none-elf-gcc" -DEXPECT_CSUM=$CSUM $FLAGS -o "$OUT/smt_mixed_probe.elf" $SRC
"$GCC/riscv-none-elf-gcc" -DSOLO -DEXPECT_CSUM=$CSUM $FLAGS -o "$OUT/smt_mixed_probe_solo.elf" $SRC
"$GCC/riscv-none-elf-gcc" -DNOALIAS -DEXPECT_CSUM=$CSUM $FLAGS -o "$OUT/smt_mixed_probe_noalias.elf" $SRC
"$GCC/riscv-none-elf-objdump" -d "$OUT/smt_mixed_probe.elf" > "$OUT/probe.dasm"
"$GCC/riscv-none-elf-objdump" -d "$OUT/smt_mixed_probe_solo.elf" > "$OUT/probe_solo.dasm"
"$GCC/riscv-none-elf-nm" -n "$OUT/smt_mixed_probe.elf" > "$OUT/probe.syms"
"$GCC/riscv-none-elf-nm" -n "$OUT/smt_mixed_probe_solo.elf" > "$OUT/probe_solo.syms"
echo BUILT
grep -E ' tohost$| RES$' "$OUT/probe.syms" "$OUT/probe_solo.syms"
