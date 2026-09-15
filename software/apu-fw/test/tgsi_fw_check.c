// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Host lock for the separate TGSI firmware job. Not apu_fw.elf and not Mesa.

#include <stdio.h>
#include "g6lc_apu_exec.h"
#include "g6lc_apu_tgsi_job.h"

#define FAIL(msg)                                                              \
  do {                                                                         \
    printf("FAIL %s\n", msg);                                                  \
    return 1;                                                                  \
  } while (0)

int main(void)
{
  uint32_t got[APU_TGSI_MAX_INST];
  unsigned n = 0;
  char err[80];
  if (g6lc_apu_tgsi_compile(APU_TGSI_JOB_TEX, got, APU_TGSI_MAX_INST, &n, err,
                            sizeof(err)) == 0)
    FAIL("TEX must fail closed");
  if (g6lc_apu_tgsi_job_compile(APU_TGSI_JOB_TEX, APU_TGSI_JOB_MOV, got,
                                APU_TGSI_MAX_INST, &n, err, sizeof(err)) != 0)
    FAIL(err);
  if (n != 2)
    FAIL("job n");
  if (got[0] != APU_TGSI_JOB_MOV_WORD)
    FAIL("MOV TEMP[0], TEMP[1]");
  if (got[1] != APU_EX_HALT_WORD)
    FAIL("END");
  if (APU_FW_COOKIE_TGSI == APU_FW_COOKIE_OK)
    FAIL("cookie alias");
  if (APU_FW_COOKIE_TGSI != 0x600D000Bu)
    FAIL("tgsi cookie");
  puts("PASS tgsi_fw_check");
  return 0;
}
