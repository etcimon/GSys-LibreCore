// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Host-side TGSI subset compiler checks. Not RTL and not Mesa.

#include <stdio.h>
#include <string.h>
#include "g6lc_apu_exec.h"
#include "g6lc_apu_tgsi.h"

#define FAIL(msg)                                                              \
  do {                                                                         \
    printf("FAIL %s\n", msg);                                                  \
    return 1;                                                                  \
  } while (0)

static int expect_ok(const char *text, const uint32_t *want, unsigned nw)
{
  uint32_t got[APU_TGSI_MAX_INST];
  unsigned n = 0;
  char err[80];
  unsigned i;
  if (g6lc_apu_tgsi_compile(text, got, APU_TGSI_MAX_INST, &n, err, sizeof(err)) !=
      0)
    FAIL(err);
  if (n != nw) {
    printf("FAIL n=%u want=%u\n", n, nw);
    return 1;
  }
  for (i = 0; i < nw; i++) {
    if (got[i] != want[i]) {
      printf("FAIL inst %u got 0x%08x want 0x%08x\n", i, got[i], want[i]);
      return 1;
    }
  }
  return 0;
}

static int expect_fail(const char *text)
{
  uint32_t got[APU_TGSI_MAX_INST];
  unsigned n = 0;
  char err[80];
  if (g6lc_apu_tgsi_compile(text, got, APU_TGSI_MAX_INST, &n, err, sizeof(err)) ==
      0)
    FAIL("expected reject");
  return 0;
}

int main(void)
{
  static const char pass[] =
      "FRAG\n"
      "DCL IN[0], COLOR, LINEAR\n"
      "DCL OUT[0], COLOR\n"
      "  0: MOV OUT[0], IN[0]\n"
      "  1: END\n";
  static const uint32_t pass_w[] = {APU_EX_MOV_R0_R0_WORD, APU_EX_HALT_WORD};

  static const char mad[] =
      "FRAG\n"
      "DCL TEMP[0]\n"
      "DCL TEMP[1]\n"
      "DCL TEMP[2]\n"
      "DCL TEMP[3]\n"
      "MAD TEMP[0], TEMP[1], TEMP[2], TEMP[3]\n"
      "END\n";
  /* TEMP[n] → r[4+n]: FMADD r4, r5, r6, r7 */
  static const uint32_t mad_w[] = {
      APU_EX_ENC(APU_EX_FMADD, 4, 5, 6, 7, 0, 0, 0), APU_EX_HALT_WORD};

  static const char addmul[] =
      "VERT\n"
      "DCL IN[0]\n"
      "DCL IN[1]\n"
      "DCL OUT[0], POSITION\n"
      "ADD OUT[0], IN[0], IN[1]\n"
      "MUL OUT[0], OUT[0], IN[0]\n"
      "END\n";
  static const uint32_t addmul_w[] = {
      APU_EX_ENC(APU_EX_FADD, 0, 0, 1, 0, 0, 0, 0),
      APU_EX_ENC(APU_EX_FMUL, 0, 0, 0, 0, 0, 0, 0), APU_EX_HALT_WORD};

  if (expect_ok(pass, pass_w, 2) != 0)
    return 1;
  if (expect_ok(mad, mad_w, 2) != 0)
    return 1;
  if (expect_ok(addmul, addmul_w, 3) != 0)
    return 1;

  static const char subneg[] =
      "FRAG\n"
      "DCL IN[0]\n"
      "DCL IN[1]\n"
      "DCL CONST[2]\n"
      "DCL OUT[0], COLOR\n"
      "SUB OUT[0], IN[0], IN[1]\n"
      "ADD OUT[0], OUT[0], -CONST[2]\n"
      "MOV OUT[0], -OUT[0].xxxx\n"
      "END\n";
  static const uint32_t subneg_w[] = {
      APU_EX_ENC(APU_EX_FSUB, 0, 0, 1, 0, 0, 0, 0),
      APU_EX_ENC(APU_EX_FSUB, 0, 0, 2, 0, 0, 0, 0),
      APU_EX_ENC(APU_EX_FNEG, 0, 0, 0, 0, 0, 0, 0), APU_EX_HALT_WORD};

  if (expect_ok(subneg, subneg_w, 4) != 0)
    return 1;

  static const char movtemp[] =
      "FRAG\n"
      "DCL TEMP[0]\n"
      "DCL TEMP[1]\n"
      "MOV TEMP[0], TEMP[1]\n"
      "END\n";
  static const uint32_t movtemp_w[] = {
      APU_EX_ENC(APU_EX_MOV, 4, 5, 0, 0, 0, 0, 0), APU_EX_HALT_WORD};
  if (expect_ok(movtemp, movtemp_w, 2) != 0)
    return 1;

  static const char imm_mov[] =
      "FRAG\n"
      "DCL TEMP[0]\n"
      "IMM[0] FLT32 {1.0000, 1.0000, 1.0000, 1.0000}\n"
      "MOV TEMP[0], IMM[0]\n"
      "END\n";
  static const uint32_t imm_mov_w[] = {APU_EX_LDC_R4_WORD, APU_EX_F32_ONE,
                                       APU_EX_HALT_WORD};
  if (expect_ok(imm_mov, imm_mov_w, 3) != 0)
    return 1;

  static const char imm_add[] =
      "FRAG\n"
      "DCL IN[0]\n"
      "DCL TEMP[0]\n"
      "IMM[0] FLT32 {1.0, 0.0, 0.0, 1.0}\n"
      "ADD TEMP[0], IN[0], IMM[0].xxxx\n"
      "END\n";
  static const uint32_t imm_add_w[] = {
      APU_EX_ENC(APU_EX_LDC, 7, 0, 0, 0, 0, 0, 0), APU_EX_F32_ONE,
      APU_EX_ENC(APU_EX_FADD, 4, 0, 7, 0, 0, 0, 0), APU_EX_HALT_WORD};
  if (expect_ok(imm_add, imm_add_w, 4) != 0)
    return 1;

  static const char imm_neg[] =
      "FRAG\n"
      "DCL TEMP[0]\n"
      "MOV TEMP[0], -1.0\n"
      "END\n";
  static const uint32_t imm_neg_w[] = {APU_EX_LDC_R4_WORD, APU_EX_F32_NEG_ONE,
                                       APU_EX_HALT_WORD};
  if (expect_ok(imm_neg, imm_neg_w, 3) != 0)
    return 1;

  if (expect_fail("FRAG\nDCL SAMP[0]\nTEX OUT[0], IN[0], SAMP[0], 2D\nEND\n") !=
      0)
    return 1;
  if (expect_fail("FRAG\nIF TEMP[0]\nEND\n") != 0)
    return 1;
  if (expect_fail("FRAG\nADD OUT[0], -IN[0], IN[1]\nEND\n") != 0)
    return 1;
  if (expect_fail("FRAG\nMOV TEMP[0], 0.3\nEND\n") != 0)
    return 1;
  if (expect_fail("FRAG\nMOV TEMP[0], IMM[0]\nEND\n") != 0)
    return 1;
  if (expect_fail("FRAG\nIMM[0] FLT32 {1.0, 0.0, 0.0, 1.0}\n"
                  "MOV TEMP[0], IMM[0]\nEND\n") != 0)
    return 1;
  if (expect_fail("") != 0)
    return 1;
  puts("PASS tgsi_check");
  return 0;
}
