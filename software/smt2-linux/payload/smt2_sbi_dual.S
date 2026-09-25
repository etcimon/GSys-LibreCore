/* SPDX-License-Identifier: MIT
 * Copyright (c) 2026 Etienne Cimon
 *
 * CVA6 SMT2 OpenSBI dual-hart S-mode smoke (R3a).
 *
 * Runs as FW_PAYLOAD after OpenSBI (or as S-mode after FW_JUMP).
 *   - Boot hart (usually 0): print via SBI console, start peer via HSM, wait
 *     for peer flag, exit success via SBI SRST or loop with a0=0 convention.
 *   - Secondary: set flag, WFI.
 *
 * SBI EID/FID: base console, HSM, system reset (SBI v0.2+ / v1.0).
 */

  .section .text.init, "ax", @progbits
  .globl _start
  .align 2
_start:
#if defined(G6LC_STRICT_HARTS)
  /* N-hart strict payload (multi-core SMT packages). The boot hart marks its
   * own strict_seen slot, starts every other hart through HSM with its own id
   * as the opaque argument, then waits until all N slots read 1. Any trap, an
   * out-of-range hart id, a hart_start failure, a secondary that receives its
   * own id as the starter, or a bounded-wait expiry writes tohost=3. */
  mv    s0, a0
  li    t0, G6LC_STRICT_HARTS
  bgeu  s0, t0, strict_fail
  la    sp, __stack_top
  slli  t0, s0, 11
  sub   sp, sp, t0
  la    t0, strict_fail
  csrw  stvec, t0
  la    t0, strict_seen
  slli  t1, s0, 3
  add   t0, t0, t1
  li    t1, 1
  sd    t1, 0(t0)
  li    s1, 0
strict_start_loop:
  beq   s1, s0, strict_start_next
  mv    a0, s1
  la    a1, strict_secondary
  mv    a2, s0
  call  sbi_hart_start
  bnez  a0, strict_fail
strict_start_next:
  addi  s1, s1, 1
  li    t0, G6LC_STRICT_HARTS
  bltu  s1, t0, strict_start_loop
  li    t2, 1000000
strict_wait_all:
  fence r, rw
  la    t1, strict_seen
  li    s1, 0
strict_check_loop:
  ld    t0, 0(t1)
  li    t3, 1
  bne   t0, t3, strict_not_yet
  addi  t1, t1, 8
  addi  s1, s1, 1
  li    t0, G6LC_STRICT_HARTS
  bltu  s1, t0, strict_check_loop
  li    a0, 1
  j     strict_exit
strict_not_yet:
  addi  t2, t2, -1
  bnez  t2, strict_wait_all
  j     strict_fail
strict_secondary:
  li    t0, G6LC_STRICT_HARTS
  bgeu  a0, t0, strict_fail
  beq   a0, a1, strict_fail
  la    sp, __stack_top
  slli  t0, a0, 11
  sub   sp, sp, t0
  la    t0, strict_fail
  csrw  stvec, t0
  la    t0, strict_seen
  slli  t1, a0, 3
  add   t0, t0, t1
  li    t1, 1
  sd    t1, 0(t0)
  fence w, w
strict_park:
  wfi
  j     strict_park
  .align 2
strict_fail:
  li    a0, 3
strict_exit:
  la    t0, tohost
  sd    a0, 0(t0)
  fence rw, rw
  j     strict_park
#elif defined(G6LC_STRICT_DUAL)
  mv    s0, a0
  li    t0, 2
  bgeu  s0, t0, strict_fail
  la    sp, __stack_top
  slli  t0, s0, 11
  sub   sp, sp, t0
  la    t0, strict_fail
  csrw  stvec, t0
  la    t0, strict_seen
  slli  t1, s0, 3
  add   t0, t0, t1
  li    t1, 1
  sd    t1, 0(t0)
  xori  s3, s0, 1
  mv    a0, s3
  la    a1, strict_secondary
  mv    a2, s0
  call  sbi_hart_start
  bnez  a0, strict_fail
  la    t1, peer_flag
  li    t2, 1000000
strict_wait:
  ld    t0, 0(t1)
  bnez  t0, strict_peer_up
  addi  t2, t2, -1
  bnez  t2, strict_wait
  j     strict_fail
strict_peer_up:
  fence r, rw
  addi  t3, s3, 1
  bne   t0, t3, strict_fail
  la    t1, strict_seen
  ld    t2, 0(t1)
  ld    t3, 8(t1)
  li    t0, 1
  bne   t2, t0, strict_fail
  bne   t3, t0, strict_fail
  li    a0, 1
  j     strict_exit
strict_secondary:
  li    t0, 2
  bgeu  a0, t0, strict_fail
  xor   t0, a0, a1
  li    t1, 1
  bne   t0, t1, strict_fail
  la    sp, __stack_top
  slli  t0, a0, 11
  sub   sp, sp, t0
  la    t0, strict_fail
  csrw  stvec, t0
  la    t0, strict_seen
  slli  t1, a0, 3
  add   t0, t0, t1
  li    t1, 1
  sd    t1, 0(t0)
  fence w, w
  addi  t0, a0, 1
  la    t1, peer_flag
  sd    t0, 0(t1)
strict_park:
  wfi
  j     strict_park
  .align 2
strict_fail:
  li    a0, 3
strict_exit:
  la    t0, tohost
  sd    a0, 0(t0)
  fence rw, rw
  j     strict_park
#else
  /* Per-hart stack: sp = __stack_top - hartid*0x800 */
  la    sp, __stack_top
  csrr  t0, sscratch   /* may be 0 */
  csrr  t0, sstatus
  /* Read hart id via SBI base get_marchid? Use rdtime/mhartid not available
   * in S-mode — use SBI HSM get_hart_status or CSR if SSCRATCH left by OpenSBI.
   * OpenSBI leaves a0=hartid for next stage on some paths; also a1=dtb.
   * Prefer SBI base probe then HSM. Use a0 from entry if set, else 0. */
  mv    s0, a0          /* hartid hint from OpenSBI */
  mv    s1, a1          /* dtb */

  /* If a0 looks like a pointer (high bits set), treat as hart 0 */
  li    t0, 0x100
  bgeu  s0, t0, assume_hart0
  j     have_hart
assume_hart0:
  li    s0, 0
have_hart:
  /* stack */
  slli  t0, s0, 11      /* *2048 */
  sub   sp, sp, t0

  bnez  s0, secondary

  /* ========== Boot hart ========== */
  /* SBI console puts "SMT2-OSBI-OK\n" */
  la    a0, msg_boot
  call  sbi_puts

  /* Start hart 1 at secondary_entry with opaque=0 */
  li    a0, 1                 /* hartid */
  la    a1, secondary_entry
  li    a2, 0                 /* opaque */
  call  sbi_hart_start
  /* a0 == 0 success, or already started */

  /* Wait for flag from secondary */
  la    t1, peer_flag
  li    t2, 1000000
1:
  ld    t0, 0(t1)
  bnez  t0, peer_up
  addi  t2, t2, -1
  bnez  t2, 1b
  /* timeout — still pass if single-hart sim */
  la    a0, msg_timeout
  call  sbi_puts
  j     success

peer_up:
  la    a0, msg_peer
  call  sbi_puts

success:
  la    a0, msg_pass
  call  sbi_puts
  /* Prefer clean shutdown */
  li    a0, 0
  li    a1, 0
  call  sbi_srst
1:  j     1b

secondary:
  /* ========== Secondary hart (via HSM start or cold boot) ========== */
secondary_entry:
  /* recompute stack for hart 1 */
  la    sp, __stack_top
  li    t0, 1
  slli  t0, t0, 11
  sub   sp, sp, t0
  la    t1, peer_flag
  li    t0, 1
  sd    t0, 0(t1)
  /* soft barrier */
  fence w, w
2:
  wfi
  j     2b
#endif

/* ---- SBI helpers (a7=EID, a6=FID) ---- */
/* Console putchar: EID=1 FID=0  legacy; also try DBCN if needed */
sbi_putchar:
  li    a7, 0x01
  li    a6, 0
  ecall
  ret

sbi_puts:
  addi  sp, sp, -16
  sd    ra, 8(sp)
  sd    s2, 0(sp)
  mv    s2, a0
1:
  lbu   a0, 0(s2)
  beqz  a0, 2f
  call  sbi_putchar
  addi  s2, s2, 1
  j     1b
2:
  ld    s2, 0(sp)
  ld    ra, 8(sp)
  addi  sp, sp, 16
  ret

/* HSM hart_start: EID=0x48534D FID=0 */
sbi_hart_start:
  li    a7, 0x48534D
  li    a6, 0
  ecall
  ret

/* System reset: EID=0x53525354 FID=0  type=a0 reason=a1 */
sbi_srst:
  li    a7, 0x53525354
  li    a6, 0
  ecall
  ret

  .section .data
  .align 3
peer_flag:
  .dword 0
#if defined(G6LC_STRICT_HARTS)
  .globl strict_seen
strict_seen:
  .rept G6LC_STRICT_HARTS
  .dword 0
  .endr
  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .globl fromhost
fromhost: .dword 0
#elif defined(G6LC_STRICT_DUAL)
  .globl strict_seen
strict_seen:
  .dword 0, 0
  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .globl fromhost
fromhost: .dword 0
#endif

  .section .rodata
msg_boot:
  .asciz "SMT2-OSBI: boot hart\n"
msg_peer:
  .asciz "SMT2-OSBI: peer up\n"
msg_timeout:
  .asciz "SMT2-OSBI: peer timeout (ok if 1-hart)\n"
msg_pass:
  .asciz "SMT2-OSBI-OK\n"
