// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Resident TGSI job policy. Linked into apu_tgsi_cc (CVA6). Mini-hart
// apu_tgsi_fw stays pre-encoded. Job text is caller .rodata (main auipc).

#include "g6lc_apu_tgsi_job.h"
#include "g6lc_apu_exec.h"

/* Tail-j to compile after live_str; no stores between a0 and the jump. */
static __attribute__((noinline)) int
do_compile(const char *text, uint32_t *out, unsigned max, unsigned *n_out,
           char *err, unsigned err_len)
{
  return g6lc_apu_tgsi_compile(g6lc_apu_live_str((char *)(uintptr_t)text), out,
                               max, n_out, err, err_len);
}

int g6lc_apu_tgsi_job_compile(const char *tex, const char *mov, uint32_t *out,
                              unsigned max, unsigned *n_out, char *err,
                              unsigned err_len)
{
  unsigned n = 0;
  tex = g6lc_apu_live_str((char *)(uintptr_t)tex);
  mov = g6lc_apu_live_str((char *)(uintptr_t)mov);
  if ((uint8_t)tex[0] != 'F') {
    *n_out = (unsigned)(uint8_t)tex[0];
    return -7;
  }
  if ((uint8_t)mov[0] != 'F')
    return -6;
  if (do_compile(tex, out, max, &n, err, err_len) == 0)
    return -2;
  if ((uint8_t)mov[0] != 'F')
    return -5;
  n = (unsigned)do_compile(mov, out, max, n_out, err, err_len);
  if ((int)n == -13)
    return -11;
  if ((int)n == -14)
    return -12;
  if ((int)n == -15)
    return -15;
  if ((int)n == -16)
    return -16;
  if ((int)n == -17)
    return -17;
  if ((int)n == -18)
    return -18;
  if ((int)n == -20)
    return -20;
  if ((int)n == -24)
    return -24;
  if ((int)n == -25)
    return -25;
  if ((int)n == -26)
    return -26;
  if ((int)n == -27)
    return -27;
  if (n != 0)
    return ((uint8_t)mov[0] == 'F') ? -3 : -4;
  return 0;
}
