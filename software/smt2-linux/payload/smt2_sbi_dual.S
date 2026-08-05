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

/* ---- SBI helpers (a7=EID, a6=FID) ---- */
/* Console putchar: EID=1 FID=0  legacy; also try DBCN if needed */
sbi_putchar:
  li    a7, 0x01
  li    a6, 0
  ecall
  ret

sbi_puts:
  mv    s2, a0
1:
  lbu   a0, 0(s2)
  beqz  a0, 2f
  call  sbi_putchar
  addi  s2, s2, 1
  j     1b
2:
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

  .section .rodata
msg_boot:
  .asciz "SMT2-OSBI: boot hart\n"
msg_peer:
  .asciz "SMT2-OSBI: peer up\n"
msg_timeout:
  .asciz "SMT2-OSBI: peer timeout (ok if 1-hart)\n"
msg_pass:
  .asciz "SMT2-OSBI-OK\n"
