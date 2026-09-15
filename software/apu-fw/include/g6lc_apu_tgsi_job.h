// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Frozen resident TGSI job: compile MOV, reject TEX. Separate from the
// TID+IADD bring-up image. Not a virgl decoder and not EGL.

#ifndef G6LC_APU_TGSI_JOB_H
#define G6LC_APU_TGSI_JOB_H

#include "g6lc_apu_tgsi.h"
#include "g6lc_apu_exec.h"
#include "g6lc_apu_mbox.h"

#define APU_TGSI_JOB_MOV                                                   \
  "FRAG\n"                                                                 \
  "DCL TEMP[0]\n"                                                          \
  "DCL TEMP[1]\n"                                                          \
  "MOV TEMP[0], TEMP[1]\n"                                                 \
  "END\n"

#define APU_TGSI_JOB_TEX                                                   \
  "FRAG\n"                                                                 \
  "DCL SAMP[0]\n"                                                          \
  "TEX OUT[0], IN[0], SAMP[0], 2D\n"                                       \
  "END\n"

/* TEMP[0]←TEMP[1] → r4, r5. Mini-hart firmware stores this word; it does
 * not run the compiler (ld/sd). Host tgsi_fw_check proves compile matches. */
#define APU_TGSI_JOB_MOV_WORD APU_EX_ENC(APU_EX_MOV, 4, 5, 0, 0, 0, 0, 0)

#ifdef __cplusplus
extern "C" {
#endif

// auipc of 0x9000xxxx sign-extends to 0xffffffff9000xxxx and misses
// firmware RAM (C7: lbu 0). lui/slli of the same PA loads. Drop the
// high 32 bits so the pointer is a 32-bit zero-extended PA.
static inline const char *g6lc_apu_live_str(char *s)
{
  uintptr_t p;
  uint32_t c;
#ifdef __riscv
  p = (uintptr_t)(uint32_t)(uintptr_t)s;
#else
  p = (uintptr_t)s;
#endif
  c = *(volatile uint8_t *)p;
#ifdef __riscv
  __asm__ volatile (
      "andi %1, %1, 0\n\t"
      "add %0, %0, %1"
      : "+r"(p), "+r"(c));
#else
  (void)c;
#endif
  return (const char *)p;
}

// TEX must fail closed, then MOV is compiled. Returns 0 on success.
// tex/mov are caller buffers (stack): D$ miss refill of fwram .rodata
// returned 0 (C7) even with slli-formed PAs.
int g6lc_apu_tgsi_job_compile(const char *tex, const char *mov, uint32_t *out,
                              unsigned max, unsigned *n_out, char *err,
                              unsigned err_len);

#ifdef __cplusplus
}
#endif

#endif
