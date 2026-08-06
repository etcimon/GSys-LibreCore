#!/bin/bash
# Bare (no CRT) fill-verify like mini_tohost — isolates CRT/stack vs pure mem hang
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
export PATH="/root/tools/verilator-v5.008/bin:/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin:/root/tools/spike/bin:${PATH}"
export LD_LIBRARY_PATH="/root/tools/spike/lib:${LD_LIBRARY_PATH:-}"
H=work-ver/Variane_testharness

# Use mini-style linker from multicore mini tests
LD=$(ls verif/tests/custom/multicore/*.ld 2>/dev/null | head -1)
# fall back
if [[ -z "${LD:-}" ]]; then
  # mini uses inline in assemble from mc-mini - check
  LD=verif/tests/custom/common/link_verilator.ld
fi

mkbare() {
  local n=$1
  cat > /tmp/bare_${n}.S << EOF
  .section .text.init
  .globl _start
_start:
  # minimal M-mode bring-up
  li sp, 0x80010000
  # fill ${n} bytes at sp-area 0x80008000
  li s0, 0x80008000
  mv t0, s0
  li t1, ${n}
1:
  sub t2, t0, s0
  xor t3, t0, t2
  sd t3, 0(t0)
  addi t0, t0, 8
  addi t1, t1, -8
  bnez t1, 1b
  mv t0, s0
  li t1, ${n}
2:
  sub t2, t0, s0
  xor t3, t0, t2
  ld t4, 0(t0)
  bne t3, t4, fail
  addi t0, t0, 8
  addi t1, t1, -8
  bnez t1, 2b
  li a0, 0
  j tohost_exit
fail:
  li a0, 1
tohost_exit:
  # tohost at 0x80001000 style — use linker symbol
  la t0, tohost
  slli a0, a0, 1
  ori a0, a0, 1
  sd a0, 0(t0)
1: j 1b
  .section .tohost
  .align 6
  .globl tohost
tohost: .dword 0
  .globl fromhost
fromhost: .dword 0
EOF
  riscv-none-elf-gcc -nostdlib -nostartfiles -T verif/tests/custom/common/link_verilator.ld \
    -o /tmp/bare_${n}.elf /tmp/bare_${n}.S -march=rv64ima_zicsr -mabi=lp64
  th=$(riscv-none-elf-nm /tmp/bare_${n}.elf | awk '$3=="tohost"{print $1; exit}')
  echo -n "bare${n} "
  timeout 60 $H +max-cycles=200000 +time_out=200000 +debug_disable +tohost_addr=0x$th /tmp/bare_${n}.elf 2>&1 | grep -E 'SUCCESS|FAILED' | tail -1
}

for n in 64 128 160 256 512; do
  mkbare $n
done

# Also: CRT but only 144, 152 to find exact threshold
COMMON=verif/tests/custom/common
for n in 136 144 152 160; do
  cat > /tmp/c${n}.S << EOF
  .globl main
main:
  li t0, ${n}
  sub sp, sp, t0
  mv s0, sp
  mv t0, s0
  li t1, ${n}
1: sub t2, t0, s0
  xor t3, t0, t2
  sd t3, 0(t0)
  addi t0, t0, 8
  addi t1, t1, -8
  bnez t1, 1b
  mv t0, s0
  li t1, ${n}
2: sub t2, t0, s0
  xor t3, t0, t2
  ld t4, 0(t0)
  bne t3, t4, fail
  addi t0, t0, 8
  addi t1, t1, -8
  bnez t1, 2b
  li t0, ${n}
  add sp, sp, t0
  li a0, 0
  jal exit
fail:
  li t0, ${n}
  add sp, sp, t0
  li a0, 1
  jal exit
EOF
  riscv-none-elf-gcc -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
    -Iverif/tests/custom/env -I$COMMON $COMMON/syscalls.c $COMMON/crt.S /tmp/c${n}.S \
    -T $COMMON/link_verilator.ld -o /tmp/c${n}.o -march=rv64imafdc_zicsr_zifencei -mabi=lp64d
  th=$(riscv-none-elf-nm /tmp/c${n}.o | awk '$3=="tohost"{print $1; exit}')
  echo -n "crt${n} "
  timeout 60 $H +max-cycles=200000 +time_out=200000 +debug_disable +tohost_addr=0x$th /tmp/c${n}.o 2>&1 | grep -E 'SUCCESS|FAILED' | tail -1
done
