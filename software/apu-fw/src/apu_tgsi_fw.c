// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Mini-hart TGSI job image. Stores APU_TGSI_JOB_MOV_WORD (host-locked).
// Does not link g6lc_apu_tgsi.c (gcc RV64I ld/sd exceeds the mini-hart).
// Host job policy stays in g6lc_apu_tgsi_job.c. Not TID+IADD, not EGL.

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
   * buffer. `fence iorw` hangs that path. Mini-hart implements addw/ld/sd. */
  __asm__ volatile (
      "andi %1, %1, 0\n\t"
      "add %0, %0, %1"
      : "+r"(off), "+r"(st));
  return apu_ctrl_rd(off);
}

int main(void)
{
  uint32_t i;
  volatile uint32_t *cookie =
      (volatile uint32_t *)(uintptr_t)(APU_FW_RAM_BASE + APU_FW_COOKIE_OFF);

  if (apu_ctrl_rd(ACTRL_MAGIC) != APU_CONTROL_MAGIC) {
    *cookie = APU_FW_COOKIE_BAD;
    return 1;
  }

  for (i = 0; i < IMEM_WORDS; i++)
    imem_store(i, APU_EX_HALT_I);
  imem_store(0, APU_TGSI_JOB_MOV_WORD);
  imem_store(1, APU_EX_HALT_I);

  for (i = 0; i < 4u; i++)
    poke(i, 5u, 0x3f800000u);

  apu_mail_word(0, 1);
  if (apu_mail_go(APU_MEM_EXEC_RUN) != APU_DMA_OK) {
    *cookie = APU_FW_COOKIE_BAD;
    return 1;
  }
  if (peek(0, 4) != 0x3f800000u || peek(1, 4) != 0x3f800000u) {
    *cookie = APU_FW_COOKIE_BAD;
    return 1;
  }
  *cookie = APU_FW_COOKIE_TGSI;
  return 0;
}
