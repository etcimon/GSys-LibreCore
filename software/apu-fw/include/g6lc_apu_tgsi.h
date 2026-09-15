// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Host-testable TGSI text → native APU exec. Frozen gles2-min subset:
// VERT/FRAG, DCL IN/OUT/TEMP/CONST, IMM[n] FLT32 splat/{.xxxx..wwww} of
// {0,0.5,1,2} and their negatives, MOV/ADD/SUB/MUL/MAD, source-1 negate
// on ADD/SUB/MOV, scalar swizzle .xyzw/.xxxx/.yyyy/.zzzz/.wwww, END.
// Fail closed on TEX, control flow, src0 negate, unknown tokens, and
// other immediate values. Not a virgl decoder.

#ifndef G6LC_APU_TGSI_H
#define G6LC_APU_TGSI_H

#include <stddef.h>
#include <stdint.h>

#define APU_TGSI_MAX_INST 16
#define APU_TGSI_MAX_REGS 8
#define APU_TGSI_TEXT_CAP 512

#ifdef __cplusplus
extern "C" {
#endif

// Compile NUL-terminated TGSI text into native words. Returns 0 on success
// and writes *n_out (includes trailing HALT). Negative on reject.
int g6lc_apu_tgsi_compile(const char *text, uint32_t *out, unsigned max,
                          unsigned *n_out, char *err, unsigned err_len);

#ifdef __cplusplus
}
#endif

#endif
