// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// CVA6-resident TGSI job: TEX fail closed, then compile MOV and run it.
// Not linked into apu_fw.elf (TID+IADD) or the mini-hart pre-encoded image.
// Not EGL. TEX still rejected.

#include "g6lc_apu_mbox.h"
#include "g6lc_apu_tgsi_job.h"

#define IMEM_WORDS 16

static void imem_store(uint32_t idx, uint32_t inst)
{
  apu_mail_word(0, idx);
  apu_mail_word(1, inst);
  (void)apu_mail_go(APU_MEM_EXEC_IMEM);
}

static void poke(uint32_t thread, uint32_t regno, uint32_t data)
{
  apu_mail_word(0, thread);
  apu_mail_word(1, regno);
  apu_mail_word(2, data);
  (void)apu_mail_go(APU_MEM_EXEC_POKE);
}

static __attribute__((noinline)) uint32_t peek(uint32_t thread, uint32_t regno)
{
  uint32_t st, off;
  apu_mail_word(0, thread);
  apu_mail_word(1, regno);
  st = apu_mail_go(APU_MEM_EXEC_PEEK);
  off = ACTRL_MAIL_CPL0;
  /* 32-bit `off` plus a live STAT-dependent add so CVA6 cannot issue
   * this uncached load while an earlier mailbox store is in the write
   * buffer. `fence iorw` hangs that path. */
  __asm__ volatile (
      "andi %1, %1, 0\n\t"
      "add %0, %0, %1"
      : "+r"(off), "+r"(st));
  return apu_ctrl_rd(off);
}

/* 32-bit address + STAT-style dep so CVA6 cannot issue this load while a
 * callee store to the same stack slot is still in the write buffer. */
static __attribute__((noinline)) uint32_t live_u32(uint32_t *slot, uint32_t dep)
{
  uint32_t off = (uint32_t)(uintptr_t)slot;
#ifdef __riscv
  __asm__ volatile (
      "andi %1, %1, 0\n\t"
      "add %0, %0, %1"
      : "+r"(off), "+r"(dep));
#else
  (void)dep;
#endif
  return *(volatile uint32_t *)(uintptr_t)off;
}

int main(void)
{
  volatile uint32_t texw[16];
  volatile uint32_t movw[16];
  uint32_t words[APU_TGSI_MAX_INST];
  uint32_t i;
  unsigned n = 0;
  int rc;
  char err[16];
  volatile uint32_t *cookie =
      (volatile uint32_t *)(uintptr_t)(APU_FW_RAM_BASE + APU_FW_COOKIE_OFF);

  if (apu_ctrl_rd(ACTRL_MAGIC) != APU_CONTROL_MAGIC) {
    *cookie = APU_FW_COOKIE_BAD;
    return 1;
  }
  texw[0] = 0x47415246u;
  texw[1] = 0x4c43440au;
  texw[2] = 0x4d415320u;
  texw[3] = 0x5d305b50u;
  texw[4] = 0x5845540au;
  texw[5] = 0x54554f20u;
  texw[6] = 0x2c5d305bu;
  texw[7] = 0x5b4e4920u;
  texw[8] = 0x202c5d30u;
  texw[9] = 0x504d4153u;
  texw[10] = 0x2c5d305bu;
  texw[11] = 0x0a443220u;
  texw[12] = 0x0a444e45u;
  texw[13] = 0;
  movw[0] = 0x47415246u;
  movw[1] = 0x4c43440au;
  movw[2] = 0x4d455420u;
  movw[3] = 0x5d305b50u;
  movw[4] = 0x4c43440au;
  movw[5] = 0x4d455420u;
  movw[6] = 0x5d315b50u;
  movw[7] = 0x564f4d0au;
  movw[8] = 0x4d455420u;
  movw[9] = 0x5d305b50u;
  movw[10] = 0x4554202cu;
  movw[11] = 0x315b504du;
  movw[12] = 0x4e450a5du;
  movw[13] = 0x00000a44u;
  if ((uint8_t)texw[0] != 'F') {
    *cookie = 0xC7000000u | (uint32_t)(uint8_t)texw[0];
    return 1;
  }
  if ((uint8_t)movw[0] != 'F') {
    *cookie = 0xC6000000u | (uint32_t)(uint8_t)movw[0];
    return 1;
  }
  rc = g6lc_apu_tgsi_job_compile(
      g6lc_apu_live_str((char *)(uintptr_t)texw),
      g6lc_apu_live_str((char *)(uintptr_t)movw), words, APU_TGSI_MAX_INST, &n,
      err, sizeof(err));
  if (rc == -2) {
    *cookie = 0xCE000000u | (n & 0xffu);
    return 1;
  }
  if (rc == -3) {
    *cookie = 0xC3000000u;
    return 1;
  }
  if (rc == -4) {
    *cookie = 0xC4000000u;
    return 1;
  }
  if (rc == -5) {
    *cookie = 0xC5000000u;
    return 1;
  }
  if (rc == -6) {
    *cookie = 0xC6000000u;
    return 1;
  }
  if (rc == -7) {
    *cookie = 0xC7000000u | (n & 0xffu);
    return 1;
  }
  if (rc == -8) {
    *cookie = 0xC8000000u;
    return 1;
  }
  if (rc == -9) {
    *cookie = 0xC9000000u;
    return 1;
  }
  if (rc == -10) {
    *cookie = 0xCA000000u;
    return 1;
  }
  if (rc == -11) {
    *cookie = 0xCB000000u;
    return 1;
  }
  if (rc == -12) {
    *cookie = 0xC1200000u;
    return 1;
  }
  if (rc == -15) {
    *cookie = 0xC1500000u;
    return 1;
  }
  if (rc == -16) {
    *cookie = 0xC1600000u;
    return 1;
  }
  if (rc == -17) {
    *cookie = 0xC1700000u;
    return 1;
  }
  if (rc == -18) {
    *cookie = 0xC1800000u;
    return 1;
  }
  if (rc == -20) {
    *cookie = 0xC2000000u;
    return 1;
  }
  if (rc == -24) {
    *cookie = 0xC2400000u;
    return 1;
  }
  if (rc == -25) {
    *cookie = 0xC2500000u;
    return 1;
  }
  if (rc == -26) {
    *cookie = 0xC2600000u;
    return 1;
  }
  if (rc == -27) {
    *cookie = 0xC2700000u;
    return 1;
  }
  if (rc != 0) {
    *cookie = 0xCC000000u | ((n & 0xffu) << 16) |
              ((uint32_t)(uint8_t)err[0] << 8) | (uint32_t)(uint8_t)err[1];
    return 1;
  }
  n = live_u32((uint32_t *)&n, (uint32_t)rc);
  words[0] = live_u32(&words[0], n);
  words[1] = live_u32(&words[1], words[0]);
  if (n == 0 || n > IMEM_WORDS || words[0] != APU_TGSI_JOB_MOV_WORD ||
      words[1] != APU_EX_HALT_WORD) {
    *cookie = 0xCD000000u | ((n & 0xffu) << 16) | (words[0] & 0xffffu);
    return 1;
  }

  for (i = 0; i < IMEM_WORDS; i++)
    imem_store(i, APU_EX_HALT_I);
#ifdef __riscv
  {
    uintptr_t p = (uintptr_t)(uint32_t)(uintptr_t)words;
    uint32_t w0, w1;
    __asm__ volatile ("lw %0, 0(%1)" : "=r"(w0) : "r"(p) : "memory");
    __asm__ volatile ("lw %0, 4(%1)" : "=r"(w1) : "r"(p) : "memory");
    imem_store(0, w0);
    imem_store(1, w1);
  }
#else
  for (i = 0; i < n; i++)
    imem_store(i, words[i]);
#endif

  for (i = 0; i < 4u; i++)
    poke(i, 5u, 0x3f800000u);

  apu_mail_word(0, 1);
  {
    uint32_t st = apu_mail_go(APU_MEM_EXEC_RUN);
    if (st != APU_DMA_OK) {
      *cookie = 0xB1000000u | (st & 0xffffu);
      return 1;
    }
  }
  {
    uint32_t p0 = peek(0, 4);
    uint32_t p1 = peek(1, 4);
    uint32_t r5 = peek(0, 5);
    if (p0 != 0x3f800000u || p1 != 0x3f800000u) {
      *cookie = 0xB2000000u | ((r5 == 0x3f800000u) ? 0x10000u : 0) |
                (p0 & 0xffffu);
      return 1;
    }
  }
  *cookie = APU_FW_COOKIE_TGSI;
  return 0;
}
