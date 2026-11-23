// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

// Dual-active multi-hart / multi-core native checkpoint firmware (W2).
//
// Both hart 0 and hart 1 run concurrently from _start (no secondary park):
//   1. Hart 0 writes pattern A into cdata[] and peer_data[]; hart 1 checks
//      peer_data[] and peer_probe() (CODE_A), then signals peer_ready.
//   2. Hart 0 issues SAVE.
//   3. Hart 0 mutates cdata[] -> B and ckpt_probe -> CODE_B (warming hart 0's
//      L1 D$/I$); hart 1 mutates peer_data[] -> B and peer_probe -> CODE_B
//      (warming hart 1's own L1 D$/I$), signals peer_mutated, and spins on
//      go_check (which was 0 at SAVE and stays 0 across RESTORE).
//   4. Hart 0 issues RESTORE while hart 1 is live.
//   5. Without any software flush, hart 0 checks cdata[] == A and ckpt_probe
//      == CODE_A, then sets go_check = 1. Hart 1 wakes and checks peer_data[]
//      == A and peer_probe() == CODE_A (proving hart 1's own L1 D$ and I$
//      were resynchronized too).
//
// Built standalone (no crt.S/syscalls.c) with link_verilator.ld.
#include <stdint.h>

#define CTRL          0x50000000UL
#define R_SAVE        0x00UL
#define R_RESTORE     0x04UL
#define R_CONSUME     0x08UL
#define R_STATUS      0x10UL
#define R_RES_COOKIE  0x14UL
#define R_RES_CODE    0x18UL
#define R_GEN_LO      0x20UL

#define ST_CMD_READY  0x01U
#define ST_RESULT     0x02U
#define ST_BUSY       0x04U
#define ST_LOCKED     0x08U
#define ST_INIT       0x10U
#define ST_META_OK    0x20U
#define ST_PROT_OK    0x40U
#define ST_CP_VALID   0x80U

#define NDATA 32
#define PROBE_WORD(imm) (0x00000513U | ((uint32_t)(imm) << 20))
#define CODE_A 0x11U
#define CODE_B 0x22U

enum {
  FAIL_BOOT_STATUS = 2,
  FAIL_SAVE_TIMEOUT = 4,
  FAIL_SAVE_CODE = 6,
  FAIL_MUTATE_DATA = 10,
  FAIL_MUTATE_CODE = 11,
  FAIL_RESTORE_TIMEOUT = 13,
  FAIL_RESTORE_CODE = 15,
  FAIL_DATA_RESTORED = 16,
  FAIL_CODE_RESTORED = 17,
  FAIL_PEER_READY_TIMEOUT = 24,
  FAIL_PEER_DATA = 25,
  FAIL_PEER_CODE = 26,
  FAIL_PEER_PRE = 27,
  FAIL_PEER_MUT_TIMEOUT = 28,
  FAIL_PEER_DONE_TIMEOUT = 29,
};

volatile uint64_t tohost __attribute__((section(".tohost"), aligned(64))) = 0;
volatile uint64_t fromhost __attribute__((section(".tohost"), aligned(64))) = 0;

static uint8_t stack0[4096] __attribute__((aligned(64)));
static uint8_t stack1[4096] __attribute__((aligned(64)));

static volatile uint64_t cdata[NDATA] __attribute__((aligned(64)));
static volatile uint64_t peer_data[NDATA] __attribute__((aligned(64)));
static volatile uint32_t g_stage __attribute__((aligned(64)));
static volatile uint32_t g_peer_ready __attribute__((aligned(64)));
static volatile uint32_t g_peer_mutated __attribute__((aligned(64)));
static volatile uint32_t g_go_check __attribute__((aligned(64)));
static volatile uint32_t g_peer_result __attribute__((aligned(64)));

__asm__(".section .text.init\n"
        ".globl _start\n"
        "_start:\n"
        "  la t0, trap_halt\n"
        "  csrw mtvec, t0\n"
        "  csrr a0, mhartid\n"
        "  bnez a0, 1f\n"
        "  la sp, stack0 + 4096\n"
        "  j hart0_main\n"
        "1:\n"
        "  li t1, 1\n"
        "  bne a0, t1, 2f\n"
        "  la sp, stack1 + 4096\n"
        "  j hart1_main\n"
        "2:\n"
        "  wfi\n"
        "  j 2b\n"
        ".balign 4\n"
        "trap_halt:\n"
        "  li t0, 0x3f\n"
        "  la t1, tohost\n"
        "  sd t0, 0(t1)\n"
        "3: j 3b\n");

__asm__(".section .text\n"
        ".option push\n"
        ".option norvc\n"
        ".balign 64\n"
        ".globl ckpt_probe\n"
        "ckpt_probe:\n"
        "  addi a0, zero, 0x11\n"
        "  ret\n"
        ".balign 64\n"
        ".globl peer_probe\n"
        "peer_probe:\n"
        "  addi a0, zero, 0x11\n"
        "  ret\n"
        ".balign 64\n"
        ".option pop\n");

extern unsigned long ckpt_probe(void);
extern unsigned long peer_probe(void);

static inline __attribute__((always_inline)) uint32_t rd32(unsigned long off) {
  uint32_t v;
  __asm__ volatile("lw %0, 0(%1)" : "=r"(v) : "r"(CTRL + off));
  return v;
}
static inline __attribute__((always_inline)) void wr32(unsigned long off, uint32_t v) {
  __asm__ volatile("sw %0, 0(%1)" :: "r"(v), "r"(CTRL + off));
}
static inline __attribute__((always_inline)) void fence(void) {
  __asm__ volatile("fence rw, rw" ::: "memory");
}
static inline __attribute__((always_inline)) uint64_t pat_a(unsigned i) {
  return 0xA5A50000A5A50000ULL ^ ((uint64_t)i * 0x0101010101010101ULL);
}
static inline __attribute__((always_inline)) uint64_t pat_b(unsigned i) {
  return 0x5B5B11115B5B1111ULL ^ ((uint64_t)i * 0x1001100110011001ULL);
}
static inline __attribute__((always_inline)) int wait_result(void) {
  for (unsigned long n = 0; n < 4000000UL; n++)
    if (rd32(R_STATUS) & ST_RESULT) return 1;
  return 0;
}
static void finish(unsigned code) {
  fence();
  tohost = (code == 0) ? 1ULL : (((uint64_t)code << 1) | 1ULL);
  for (;;) { }
}

void hart1_main(void) {
  while (g_stage < 1U) { }
  fence();
  for (unsigned i = 0; i < NDATA; i++)
    if (peer_data[i] != pat_a(i + 100U)) { g_peer_result = FAIL_PEER_PRE; for (;;) {} }
  if (peer_probe() != CODE_A) { g_peer_result = FAIL_PEER_PRE; for (;;) {} }
  fence();
  g_peer_ready = 1U;

  while (g_stage < 2U) { }
  fence();
  for (unsigned i = 0; i < NDATA; i++) peer_data[i] = pat_b(i + 100U);
  for (unsigned i = 0; i < NDATA; i++)
    if (peer_data[i] != pat_b(i + 100U)) { g_peer_result = FAIL_MUTATE_DATA; for (;;) {} }
  *(volatile uint32_t *)(unsigned long)&peer_probe = PROBE_WORD(CODE_B);
  __asm__ volatile(".word 0x0000100f");   // fence.i
  if (peer_probe() != CODE_B) { g_peer_result = FAIL_MUTATE_CODE; for (;;) {} }
  fence();
  g_peer_mutated = 1U;

  // Spin on g_go_check (0 at SAVE, 0 across RESTORE, set to 1 by hart 0 after
  // RESTORE). No flush on hart 1: resync must have invalidated hart 1's L1s.
  while (g_go_check == 0U) { }
  fence();
  for (unsigned i = 0; i < NDATA; i++) {
#ifdef CKPT_ORACLE_EXPECT_B
    if (peer_data[i] != pat_b(i + 100U)) { g_peer_result = FAIL_PEER_DATA; for (;;) {} }
#else
    if (peer_data[i] != pat_a(i + 100U)) { g_peer_result = FAIL_PEER_DATA; for (;;) {} }
#endif
  }
  if (peer_probe() != CODE_A) { g_peer_result = FAIL_PEER_CODE; for (;;) {} }
  fence();
  g_peer_result = 0x5AU;
  for (;;) { }
}

void hart0_main(void) {
  uint32_t st = rd32(R_STATUS);
  if ((st & (ST_INIT | ST_META_OK | ST_PROT_OK | ST_CMD_READY)) !=
      (ST_INIT | ST_META_OK | ST_PROT_OK | ST_CMD_READY) ||
      (st & (ST_BUSY | ST_LOCKED | ST_RESULT | ST_CP_VALID)))
    finish(FAIL_BOOT_STATUS);

  for (unsigned i = 0; i < NDATA; i++) {
    cdata[i] = pat_a(i);
    peer_data[i] = pat_a(i + 100U);
  }
  g_peer_ready = 0;
  g_peer_mutated = 0;
  g_go_check = 0;
  g_peer_result = 0;
  fence();
  g_stage = 1U;

  for (unsigned long n = 0; n < 2000000UL && !g_peer_ready; n++) { }
  if (!g_peer_ready) finish(FAIL_PEER_READY_TIMEOUT);

  // SAVE
  wr32(R_SAVE, 0xC0DE0101U);
  if (!wait_result()) finish(FAIL_SAVE_TIMEOUT);
  if (rd32(R_RES_CODE) != 0U) finish(FAIL_SAVE_CODE);
  wr32(R_CONSUME, 0xC0DE0101U);

  // Mutate hart 0's lines and release hart 1 to mutate its lines.
  for (unsigned i = 0; i < NDATA; i++) cdata[i] = pat_b(i);
  for (unsigned i = 0; i < NDATA; i++)
    if (cdata[i] != pat_b(i)) finish(FAIL_MUTATE_DATA);
  *(volatile uint32_t *)(unsigned long)&ckpt_probe = PROBE_WORD(CODE_B);
  __asm__ volatile(".word 0x0000100f");
  if (ckpt_probe() != CODE_B) finish(FAIL_MUTATE_CODE);
  fence();
  g_stage = 2U;

  for (unsigned long n = 0; n < 2000000UL && !g_peer_mutated; n++) { }
  if (!g_peer_mutated) finish(FAIL_PEER_MUT_TIMEOUT);

  // RESTORE (registers only across the RAM replacement).
  wr32(R_RESTORE, 0xC0DE0102U);
  if (!wait_result()) finish(FAIL_RESTORE_TIMEOUT);
  if (rd32(R_RES_CODE) != 0U) finish(FAIL_RESTORE_CODE);
  wr32(R_CONSUME, 0xC0DE0102U);

  for (unsigned i = 0; i < NDATA; i++)
    if (cdata[i] != pat_a(i)) finish(FAIL_DATA_RESTORED);
  if (ckpt_probe() != CODE_A) finish(FAIL_CODE_RESTORED);

  fence();
  g_go_check = 1U;
  for (unsigned long n = 0; n < 2000000UL && g_peer_result == 0U; n++) { }
  if (g_peer_result == 0U) finish(FAIL_PEER_DONE_TIMEOUT);
  if (g_peer_result != 0x5AU) finish(g_peer_result);
  finish(0);
}
