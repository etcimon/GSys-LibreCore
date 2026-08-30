# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# S4 directed mini: fdt_offset_ptr pointer-liveness after a 32-bit RVI leftover +
# c.jr a0 path. Confirms the ra=0x80012994 class; on the fetch_B/IQ leftover bug
# the returned pointer loses its high bits and c.jr a0 lands in the low 20-bit
# address space (mepc lower 32 = 0x1E030 from the FDT stub at 0x8001E030).
#
# Layout (B-flavour FETCH_WIDTH=64):
#   _start at 0x80000000 loads fdt/offset/len and jumps to test.
#   A 32-bit addi a1,a1,0 is placed at 0x80012986 so it straddles the
#   64-bit fetch boundary at 0x80012988.
#   jal offset_ptr at 0x80012990 sets ra=0x80012994.
#   c.jr a0 at 0x80012994 jumps to the offset_ptr result.
#   Real libfdt fdt_offset_ptr is loaded from osbi_nt/offset_ptr.bin at
#   0x80013000 (its 32-bit lbu a3,36(a0) at 0x800130A6 straddles a 64-bit
#   fetch boundary, mirroring the original S4 pin).
#   A minimal FDT + stub is at 0x8001E000.
#
# tohost encoding (the TB prints the 32-bit exit code = tohost>>1):
#   mepc!=0 -> tohost = (mepc << 1) | 1  (prints lower 32 bits of mepc)
#   mepc==0 -> tohost = (ra    << 1) | 1  (prints lower 32 bits of ra)
#   Current S4 pointer-liveness: mepc = 0x...1E030 (FDT stub low), ra = 0x80012994
#   -> tohost lower 32 = 0x1E030 = 122928.

  .option rvc
  .section .text.init
  .globl _start
_start:
  li   sp, 0x80008000
  la   t0, trap
  csrw mtvec, t0

  la   a0, fdt_blob
  li   a1, 0                # offset within dt_struct
  li   a2, 4                # len
  j    test_code

pass:
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j    1b

# Unreachable catch for the post-c.jr fall-through path.
fail:
  li   a0, 3
  la   t0, tohost
  sw   a0, 0(t0)
2: j    2b

trap:
  csrr t0, mepc
  bnez t0, 1f
  # mepc == 0: report ra (S4 class is ra == 0x80012994)
  mv   t0, ra
  j    2f
1:
  # mepc != 0: report mepc directly
2:
  # Encode value as (addr << 1) | 1 so the HTIF exit code equals the address.
  slli t0, t0, 1
  ori  t0, t0, 1
  la   a0, tohost
  sd   t0, 0(a0)
3: j    3b

# ---------------------------------------------------------------------------
# Test wrapper at fixed VA. The 32-bit RVI at 0x80012986 straddles the
# 64-bit fetch boundary; the following jal sets ra=0x80012994.
# ---------------------------------------------------------------------------
  .section .text.ptr0, "ax"
  .align 1
  .globl test_code
test_code:
  c.nop                     # 0x80012980
  c.nop                     # 0x80012982
  c.nop                     # 0x80012984
  .4byte 0x00058593         # 0x80012986: addi a1,a1,0 (32-bit, straddle)
  c.nop                     # 0x8001298A
  c.nop                     # 0x8001298C
  c.nop                     # 0x8001298E
  jal  offset_ptr           # 0x80012990, ra=0x80012994

  # S4: c.jr a0 at 0x80012994.  On a correct core a0 = 0x8001E030 and the
  # stub (j pass) runs.  On the fetch_B/IQ leftover bug the returned address
  # or the target fetch is corrupted and the control-flow transfer fails.
  c.jr a0                   # 0x80012994, ra already 0x80012994
  c.nop                     # 0x80012996 (alignment/late-exit safety)
  j    fail                 # 0x80012998

# ---------------------------------------------------------------------------
# Real libfdt fdt_offset_ptr, relocated to 0x80013000.
# ---------------------------------------------------------------------------
  .section .text.offset, "ax"
  .align 3
  .globl offset_ptr
offset_ptr:
  .incbin "verif/tests/custom/multicore/osbi_nt/offset_ptr.bin"

# ---------------------------------------------------------------------------
# Minimal FDT with a stub at dt_struct offset 0x30.
# Correct offset_ptr(fdt, 0, 4) returns fdt + 0x30 (0x8001E030).
# On the fetch_B/IQ leftover bug the returned pointer (or the target fetch)
# is corrupted; the c.jr a0 traps with mepc lower 32 = 0x1E030 while
# ra = 0x80012994 (the S4 pointer-liveness class).
# ---------------------------------------------------------------------------
  .section .text.fdt, "ax"
  .align 3
  .globl fdt_blob
fdt_blob:
  .byte 0xd0, 0x0d, 0xfe, 0xed   # 0x00: magic (BE)
  .byte 0x00, 0x00, 0x01, 0x00   # 0x04: totalsize = 0x100
  .byte 0x00, 0x00, 0x00, 0x30   # 0x08: off_dt_struct = 0x30
  .byte 0x00, 0x00, 0x00, 0x00   # 0x0c: off_dt_strings
  .byte 0x00, 0x00, 0x00, 0x00   # 0x10: off_mem_rsvmap
  .byte 0x00, 0x00, 0x00, 0x11   # 0x14: version = 17
  .byte 0x00, 0x00, 0x00, 0x10   # 0x18: last_comp_version = 16
  .byte 0x00, 0x00, 0x00, 0x00   # 0x1c: boot_cpuid_phys
  .byte 0x00, 0x00, 0x00, 0x00   # 0x20: size_dt_strings
  .byte 0x00, 0x00, 0x00, 0x80   # 0x24: size_dt_struct = 0x80
  .byte 0x00, 0x00, 0x00, 0x00   # 0x28
  .byte 0x00, 0x00, 0x00, 0x00   # 0x2c
fdt_stub:
  j    pass                      # 0x30: stub reached by c.jr a0

# ---------------------------------------------------------------------------
# HTIF tohost
# ---------------------------------------------------------------------------
  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
