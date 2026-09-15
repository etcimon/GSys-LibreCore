// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Native exec instruction pack. Must match apu_exec_inst_t in g6lc_apu_pkg.sv:
// {op[4:0], rd[3:0], rs1[3:0], rs2[3:0], rs3[3:0], pred, priv, imm[8:0]}.

#ifndef G6LC_APU_EXEC_H
#define G6LC_APU_EXEC_H

#include <stdint.h>

#define APU_EX_NOP      0u
#define APU_EX_HALT     1u
#define APU_EX_LDI      2u
#define APU_EX_MOV      3u
#define APU_EX_TID      4u
#define APU_EX_IADD     5u
#define APU_EX_FADD     10u
#define APU_EX_FMUL     11u
#define APU_EX_FMADD    12u
#define APU_EX_FSUB     19u
#define APU_EX_FNEG     20u
#define APU_EX_LD       17u
#define APU_EX_ST       18u
#define APU_EX_LDC      21u

#define APU_EX_ENC(op, rd, rs1, rs2, rs3, pred, priv, imm) \
  (((((uint32_t)(op))   & 31u) << 27) | \
   ((((uint32_t)(rd))   & 15u) << 23) | \
   ((((uint32_t)(rs1))  & 15u) << 19) | \
   ((((uint32_t)(rs2))  & 15u) << 15) | \
   ((((uint32_t)(rs3))  & 15u) << 11) | \
   ((((uint32_t)(pred)) &  1u) << 10) | \
   ((((uint32_t)(priv)) &  1u) <<  9) | \
   (((uint32_t)(imm))   & 511u))

#define APU_EX_TID_R1     APU_EX_ENC(APU_EX_TID, 1, 0, 0, 0, 0, 0, 0)
#define APU_EX_LDI_R2_10  APU_EX_ENC(APU_EX_LDI, 2, 0, 0, 0, 0, 0, 10)
#define APU_EX_IADD_R3    APU_EX_ENC(APU_EX_IADD, 3, 1, 2, 0, 0, 0, 0)
#define APU_EX_HALT_I     APU_EX_ENC(APU_EX_HALT, 0, 0, 0, 0, 0, 0, 0)
#define APU_EX_MOV_R0_R0  APU_EX_ENC(APU_EX_MOV, 0, 0, 0, 0, 0, 0, 0)
#define APU_EX_FMADD_R4   APU_EX_ENC(APU_EX_FMADD, 4, 1, 2, 3, 0, 0, 0)
#define APU_EX_FSUB_R3    APU_EX_ENC(APU_EX_FSUB, 3, 1, 2, 0, 0, 0, 0)
#define APU_EX_FNEG_R1    APU_EX_ENC(APU_EX_FNEG, 1, 2, 0, 0, 0, 0, 0)
#define APU_EX_LDC_R4     APU_EX_ENC(APU_EX_LDC, 4, 0, 0, 0, 0, 0, 0)

#define APU_EX_TID_R1_WORD     0x20800000u
#define APU_EX_LDI_R2_10_WORD  0x1100000Au
#define APU_EX_IADD_R3_WORD    0x29890000u
#define APU_EX_HALT_WORD       0x08000000u
#define APU_EX_MOV_R0_R0_WORD  0x18000000u
#define APU_EX_FMADD_R4_WORD   0x62091800u
#define APU_EX_FSUB_R3_WORD    0x99890000u
#define APU_EX_FNEG_R1_WORD    0xA0900000u
#define APU_EX_LDC_R4_WORD     0xAA000000u
#define APU_EX_F32_ONE         0x3f800000u
#define APU_EX_F32_NEG_ONE     0xbf800000u

#endif
