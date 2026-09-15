// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Mailbox offsets and ops. Must match corev_apu/apu/include/g6lc_apu_pkg.sv.

#ifndef G6LC_APU_MBOX_H
#define G6LC_APU_MBOX_H

#include <stdint.h>

#define APU_CONTROL_BASE      0x40002000u
#define APU_CONTROL_MAGIC     0x47364143u
#define APU_FW_RAM_BASE       0x90000000u
#define APU_FW_COOKIE_OFF     0x0003FF00u
#define APU_FW_COOKIE_OK      0x600D000Au
#define APU_FW_COOKIE_TGSI    0x600D000Bu
#define APU_FW_COOKIE_BAD     0x0BADu

#define ACTRL_MAGIC           0x000u
#define ACTRL_MAIL_IDX        0x080u
#define ACTRL_MAIL_DATA       0x084u
#define ACTRL_MAIL_GO         0x088u
#define ACTRL_MAIL_STAT       0x08cu
#define ACTRL_MAIL_CPL0       0x090u
#define ACTRL_MAIL_BUSY       0x80000000u

#define APU_DMA_OK            0u
#define APU_DMA_PERMISSION    2u
#define APU_DMA_PROTOCOL      7u

#define APU_MEM_EXEC_IMEM     9u
#define APU_MEM_EXEC_POKE     10u
#define APU_MEM_EXEC_PEEK     11u
#define APU_MEM_EXEC_RUN      12u
#define APU_MEM_EXEC_DPEEK    13u

static inline volatile uint32_t *apu_ctrl(uint32_t off)
{
  return (volatile uint32_t *)(uintptr_t)(APU_CONTROL_BASE + off);
}

static inline uint32_t apu_ctrl_rd(uint32_t off)
{
  return *apu_ctrl(off);
}

static inline void apu_ctrl_wr(uint32_t off, uint32_t val)
{
  volatile uint32_t *p = apu_ctrl(off);
#ifdef __riscv
  /* gcc -O2 merges adjacent IDX+DATA into sd; mailbox is 32-bit MMIO. */
  __asm__ volatile ("sw %0, 0(%1)" : : "r"(val), "r"(p) : "memory");
#else
  *p = val;
#endif
}

static inline void apu_mail_word(uint32_t idx, uint32_t data)
{
  apu_ctrl_wr(ACTRL_MAIL_IDX, idx);
  apu_ctrl_wr(ACTRL_MAIL_DATA, data);
}

static inline uint32_t apu_mail_go(uint32_t op)
{
  uint32_t stat;
  apu_ctrl_wr(ACTRL_MAIL_GO, op);
  do {
    stat = apu_ctrl_rd(ACTRL_MAIL_STAT);
  } while (stat & ACTRL_MAIL_BUSY);
  return stat & 0xfu;
}

#endif
