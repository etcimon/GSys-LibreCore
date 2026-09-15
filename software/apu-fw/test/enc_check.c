// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Host-side lock that C encodings match the packed SV layout.

#include <stdio.h>
#include "g6lc_apu_exec.h"

#define EQ(a, b)                                                               \
  do {                                                                         \
    if ((a) != (b)) {                                                          \
      printf("FAIL %s got 0x%08x want 0x%08x\n", #a, (unsigned)(a),            \
             (unsigned)(b));                                                   \
      return 1;                                                                \
    }                                                                          \
  } while (0)

int main(void)
{
  EQ(APU_EX_TID_R1, APU_EX_TID_R1_WORD);
  EQ(APU_EX_LDI_R2_10, APU_EX_LDI_R2_10_WORD);
  EQ(APU_EX_IADD_R3, APU_EX_IADD_R3_WORD);
  EQ(APU_EX_HALT_I, APU_EX_HALT_WORD);
  EQ(APU_EX_MOV_R0_R0, APU_EX_MOV_R0_R0_WORD);
  EQ(APU_EX_FMADD_R4, APU_EX_FMADD_R4_WORD);
  EQ(APU_EX_FSUB_R3, APU_EX_FSUB_R3_WORD);
  EQ(APU_EX_FNEG_R1, APU_EX_FNEG_R1_WORD);
  EQ(APU_EX_LDC_R4, APU_EX_LDC_R4_WORD);
  puts("PASS enc_check");
  return 0;
}
