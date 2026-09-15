// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Resident APU firmware for hart 1. Programs the native exec cluster through
// the protected mailbox. Does not run shaders on this hart and does not
// implement EGL/GLES.

#include "g6lc_apu_mbox.h"
#include "g6lc_apu_exec.h"

#define IMEM_WORDS 16

static void imem_store(uint32_t idx, uint32_t inst)
{
  apu_mail_word(0, idx);
  apu_mail_word(1, inst);
  (void)apu_mail_go(APU_MEM_EXEC_IMEM);
}

static uint32_t peek(uint32_t thread, uint32_t regno)
{
  apu_mail_word(0, thread);
  apu_mail_word(1, regno);
  (void)apu_mail_go(APU_MEM_EXEC_PEEK);
  return apu_ctrl_rd(ACTRL_MAIL_CPL0);
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

  imem_store(0, APU_EX_TID_R1);
  imem_store(1, APU_EX_LDI_R2_10);
  imem_store(2, APU_EX_IADD_R3);
  imem_store(3, APU_EX_HALT_I);

  apu_mail_word(0, 0);
  if (apu_mail_go(APU_MEM_EXEC_RUN) != APU_DMA_OK) {
    *cookie = APU_FW_COOKIE_BAD;
    return 1;
  }
  if (peek(0, 3) != 10u || peek(1, 3) != 11u) {
    *cookie = APU_FW_COOKIE_BAD;
    return 1;
  }
  *cookie = APU_FW_COOKIE_OK;
  return 0;
}
