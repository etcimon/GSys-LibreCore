// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Native Storamic checkpoint composition test (bare metal, M-mode).
// Design: g6lc_storamic/architecture/native-composition.md.
//
// The program runs from the checkpointed RAM. SAVE captures the whole RAM
// image, including this program's stack and globals; RESTORE writes that
// image back underneath the running hart. Rules that follow from that:
//   * SAVE and RESTORE are issued from the same stack frame (main), so the
//     restored frame is the live frame.
//   * State that must survive RESTORE lives in registers: the fail code and
//     the phase marker are global register variables.
//   * After RESTORE nothing is flushed by software: data and code must read
//     the saved contents because the platform resynchronized the hart.
//
// Build variants:
//   -DCKPT_BOOT_ONLY      status check only (no commands)
//   -DCKPT_ORACLE_EXPECT_B negative oracle: expects the post-SAVE contents
//                         after RESTORE, so a correct platform must fail it
//                         with FAIL_DATA_RESTORED.
//   -DCKPT_DELAY_EARLY    spin before the first access (debug SBA probe runs)
//   -DCKPT_TRIGGER=<off>  write the bench trigger at CTRL+<off> before SAVE
//   -DCKPT_COLD           cold recovery: SAVE image A, mutate to B, bench power
//                         cycle (CTRL+0x3078). The platform boot recovery agent
//                         must restore A before the hart runs again; the second
//                         boot (checkpoint valid at entry) checks it. Honors
//                         -DCKPT_ORACLE_EXPECT_B as the negative oracle.
//                         (provider negatives; the command must not complete
//                         with CP_OK).

#include <stdint.h>

#define CTRL          0x50000000UL
#define R_SAVE        0x00UL
#define R_RESTORE     0x04UL
#define R_CONSUME     0x08UL
#define R_STATUS      0x10UL
#define R_RES_COOKIE  0x14UL
#define R_RES_CODE    0x18UL
#define R_GEN_LO      0x20UL
#define R_GEN_HI      0x24UL

#define ST_CMD_READY  0x01U
#define ST_RESULT     0x02U
#define ST_BUSY       0x04U
#define ST_LOCKED     0x08U
#define ST_INIT       0x10U
#define ST_META_OK    0x20U
#define ST_PROT_OK    0x40U
#define ST_CP_VALID   0x80U

#define CP_OK         0U

enum {
  FAIL_BOOT_STATUS = 2,
  FAIL_BOOT_HAS_CP = 3,
  FAIL_SAVE_TIMEOUT = 4,
  FAIL_SAVE_COOKIE = 5,
  FAIL_SAVE_CODE = 6,
  FAIL_SAVE_GEN = 7,
  FAIL_SAVE_STATUS = 8,
  FAIL_SAVE_DATA = 9,       // SAVE must not disturb live RAM
  FAIL_MUTATE_DATA = 10,    // post-SAVE contents must be observable (caches warm)
  FAIL_MUTATE_CODE = 11,
  FAIL_LRSC_CONTROL = 12,   // control LR/SC without a checkpoint must succeed
  FAIL_RESTORE_TIMEOUT = 13,
  FAIL_RESTORE_COOKIE = 14,
  FAIL_RESTORE_CODE = 15,
  FAIL_DATA_RESTORED = 16,  // data not equal to the saved image after RESTORE
  FAIL_CODE_RESTORED = 17,  // code not equal to the saved image after RESTORE
  FAIL_SC_SUCCEEDED = 18,   // reservation survived the RAM replacement
  FAIL_GEN_AFTER = 19,
  FAIL_STATUS_AFTER = 20,
  FAIL_PHASE = 21,          // phase register lost across RESTORE
  FAIL_TRIGGER_OK = 22,     // provider negative: command completed CP_OK
  FAIL_STACK_RESTORED = 23  // stack word not rolled back to its saved value
};

// Survive RESTORE: callee-saved registers reserved for the test.
register unsigned long g_fail __asm__("s10");
register unsigned long g_phase __asm__("s11");

#define NDATA 64
static volatile uint64_t cdata[NDATA] __attribute__((aligned(64)));
static volatile uint64_t rsv_word __attribute__((aligned(64)));

// Patchable code word: `addi a0, zero, imm ; ret`, uncompressed, alone on its
// cache line.
__asm__(".section .text\n"
        ".option push\n"
        ".option norvc\n"
        ".balign 64\n"
        ".globl ckpt_probe\n"
        ".type ckpt_probe, @function\n"
        "ckpt_probe:\n"
        "  addi a0, zero, 0x11\n"
        "  ret\n"
        ".balign 64\n"
        ".option pop\n");
extern unsigned long ckpt_probe(void);
#define PROBE_WORD(imm) (0x00000513U | ((uint32_t)(imm) << 20))
#define CODE_A 0x11U
#define CODE_B 0x22U

static inline __attribute__((always_inline)) uint32_t rd32(unsigned long off) {
  uint32_t v;
  __asm__ volatile("lw %0, 0(%1)" : "=r"(v) : "r"(CTRL + off));
  return v;
}
static inline __attribute__((always_inline)) void wr32(unsigned long off, uint32_t v) {
  __asm__ volatile("sw %0, 0(%1)" :: "r"(v), "r"(CTRL + off));
}
static inline __attribute__((always_inline)) uint64_t pat_a(unsigned i) {
  return 0xA5A50000A5A50000ULL ^ ((uint64_t)i * 0x0101010101010101ULL);
}
static inline __attribute__((always_inline)) uint64_t pat_b(unsigned i) {
  return 0x5B5B11115B5B1111ULL ^ ((uint64_t)i * 0x1001100110011001ULL);
}

// Poll for a result; registers only. Returns 0 on timeout.
static inline __attribute__((always_inline)) int wait_result(void) {
  for (unsigned long n = 0; n < 4000000UL; n++)
    if (rd32(R_STATUS) & ST_RESULT) return 1;
  return 0;
}

#ifdef CKPT_COLD
// In .data (not .bss): the C runtime must not clear it on the second boot.
static volatile uint64_t cold[NDATA] __attribute__((aligned(64), section(".data"))) = {1};
#endif

int main(void) {
  uint32_t st;
  g_fail = 0;
  g_phase = 0x100;

#ifdef CKPT_COLD
  st = rd32(R_STATUS);
  if ((st & (ST_INIT | ST_META_OK | ST_PROT_OK | ST_CMD_READY)) !=
      (ST_INIT | ST_META_OK | ST_PROT_OK | ST_CMD_READY) ||
      (st & (ST_BUSY | ST_LOCKED | ST_RESULT)))
    return FAIL_BOOT_STATUS;
  if (st & ST_CP_VALID) {
    // Second boot: the image must be the saved one, not B and not cleared RAM.
    if (rd32(R_GEN_LO) != 1U || rd32(R_GEN_HI) != 0U) return FAIL_GEN_AFTER;
    for (unsigned i = 0; i < NDATA; i++) {
#ifdef CKPT_ORACLE_EXPECT_B
      if (cold[i] != pat_b(i)) return FAIL_DATA_RESTORED;
#else
      if (cold[i] != pat_a(i)) return FAIL_DATA_RESTORED;
#endif
    }
    if (ckpt_probe() != CODE_A) return FAIL_CODE_RESTORED;
    return 0;
  }
  for (unsigned i = 0; i < NDATA; i++) cold[i] = pat_a(i);
  if (ckpt_probe() != CODE_A) return FAIL_MUTATE_CODE;
  wr32(R_SAVE, 0xC0DE0001U);
  if (!wait_result()) return FAIL_SAVE_TIMEOUT;
  if (rd32(R_RES_COOKIE) != 0xC0DE0001U) return FAIL_SAVE_COOKIE;
  if (rd32(R_RES_CODE) != CP_OK) return FAIL_SAVE_CODE;
  wr32(R_CONSUME, 0xC0DE0001U);
  if (rd32(R_GEN_LO) != 1U || rd32(R_GEN_HI) != 0U) return FAIL_SAVE_GEN;
  for (unsigned i = 0; i < NDATA; i++) cold[i] = pat_b(i);
  for (unsigned i = 0; i < NDATA; i++)
    if (cold[i] != pat_b(i)) return FAIL_MUTATE_DATA;
  *(volatile uint32_t *)(unsigned long)&ckpt_probe = PROBE_WORD(CODE_B);
  __asm__ volatile(".word 0x0000100f");   // fence.i
  if (ckpt_probe() != CODE_B) return FAIL_MUTATE_CODE;
  wr32(0x3078UL, 1);                       // bench power cycle
  for (;;) { }
#else

#ifdef CKPT_DELAY_EARLY
  // Give the debugger thread time to run its System Bus Access sequence.
  for (unsigned long d = 0; d < 200000UL; d++) __asm__ volatile("" : "+r"(d));
#endif
  st = rd32(R_STATUS);
  if ((st & (ST_INIT | ST_META_OK | ST_PROT_OK | ST_CMD_READY)) !=
      (ST_INIT | ST_META_OK | ST_PROT_OK | ST_CMD_READY) ||
      (st & (ST_BUSY | ST_LOCKED | ST_RESULT)))
    return FAIL_BOOT_STATUS;
  if (st & ST_CP_VALID) return FAIL_BOOT_HAS_CP;
#ifdef CKPT_BOOT_ONLY
  return 0;
#else

  // ---- image A -------------------------------------------------------------
  for (unsigned i = 0; i < NDATA; i++) cdata[i] = pat_a(i);
  if (ckpt_probe() != CODE_A) return FAIL_MUTATE_CODE;
  volatile uint64_t stack_word = 0x1111222233334444ULL;

#ifdef CKPT_TRIGGER
  wr32(CKPT_TRIGGER, 1);
  for (volatile int d = 0; d < 2000; d++) { }
#endif

  // ---- SAVE ----------------------------------------------------------------
  g_phase = 0x200;
  wr32(R_SAVE, 0xC0DE0001U);
#ifdef CKPT_TRIGGER
  // A provider was withdrawn: the command must never complete with CP_OK.
  // (The hart may also simply stall on sealed RAM; the runner judges that
  // from the final platform state.)
  if (wait_result() && rd32(R_RES_CODE) == CP_OK) return FAIL_TRIGGER_OK;
  return 0;
#else
  if (!wait_result()) return FAIL_SAVE_TIMEOUT;
  if (rd32(R_RES_COOKIE) != 0xC0DE0001U) return FAIL_SAVE_COOKIE;
  if (rd32(R_RES_CODE) != CP_OK) return FAIL_SAVE_CODE;
  wr32(R_CONSUME, 0xC0DE0001U);
  if (rd32(R_GEN_LO) != 1U || rd32(R_GEN_HI) != 0U) return FAIL_SAVE_GEN;
  st = rd32(R_STATUS);
  if (!(st & ST_CP_VALID) || (st & (ST_BUSY | ST_LOCKED | ST_RESULT)))
    return FAIL_SAVE_STATUS;
  for (unsigned i = 0; i < NDATA; i++)
    if (cdata[i] != pat_a(i)) return FAIL_SAVE_DATA;

  // ---- mutate to B (after SAVE): data, code, stack --------------------------
  g_phase = 0x300;
  for (unsigned i = 0; i < NDATA; i++) cdata[i] = pat_b(i);
  for (unsigned i = 0; i < NDATA; i++)
    if (cdata[i] != pat_b(i)) return FAIL_MUTATE_DATA;
  *(volatile uint32_t *)(unsigned long)&ckpt_probe = PROBE_WORD(CODE_B);
  __asm__ volatile(".word 0x0000100f");   // fence.i (no zifencei in -march)
  if (ckpt_probe() != CODE_B) return FAIL_MUTATE_CODE;
  stack_word = 0x9999AAAABBBBCCCCULL;

  // ---- control LR/SC: no checkpoint in between -> must succeed --------------
  {
    unsigned long tmp, sc;
    rsv_word = 7;
    __asm__ volatile("lr.d %0, (%1)" : "=&r"(tmp) : "r"(&rsv_word));
    wr32(0x1030UL, 0);                  // benign MMIO store (VirtIO QueueSel), like a command
    (void)rd32(R_STATUS);
    __asm__ volatile("sc.d %0, %2, (%1)" : "=&r"(sc) : "r"(&rsv_word), "r"(tmp + 1));
    if (sc != 0) return FAIL_LRSC_CONTROL;
  }

  // ---- LR, RESTORE, SC ------------------------------------------------------
  g_phase = 0x400;
  {
    register unsigned long tmp __asm__("s9");
    unsigned long sc;
    __asm__ volatile("lr.d %0, (%1)" : "=&r"(tmp) : "r"(&rsv_word));
    wr32(R_RESTORE, 0xC0DE0002U);
    if (!wait_result()) { g_fail = FAIL_RESTORE_TIMEOUT; goto out; }
    __asm__ volatile("sc.d %0, %2, (%1)" : "=&r"(sc) : "r"(&rsv_word), "r"(tmp + 1));
    if (sc == 0) { g_fail = FAIL_SC_SUCCEEDED; goto out; }
  }
  if (g_phase != 0x400) { g_fail = FAIL_PHASE; goto out; }
  if (rd32(R_RES_COOKIE) != 0xC0DE0002U) { g_fail = FAIL_RESTORE_COOKIE; goto out; }
  if (rd32(R_RES_CODE) != CP_OK) { g_fail = FAIL_RESTORE_CODE; goto out; }
  wr32(R_CONSUME, 0xC0DE0002U);

  // ---- no software flush: the platform must have resynchronized -------------
  for (unsigned i = 0; i < NDATA; i++) {
#ifdef CKPT_ORACLE_EXPECT_B
    if (cdata[i] != pat_b(i)) { g_fail = FAIL_DATA_RESTORED; goto out; }
#else
    if (cdata[i] != pat_a(i)) { g_fail = FAIL_DATA_RESTORED; goto out; }
#endif
  }
  if (ckpt_probe() != CODE_A) { g_fail = FAIL_CODE_RESTORED; goto out; }
  if (stack_word != 0x1111222233334444ULL) { g_fail = FAIL_STACK_RESTORED; goto out; }
  if (rd32(R_GEN_LO) != 1U) { g_fail = FAIL_GEN_AFTER; goto out; }
  st = rd32(R_STATUS);
  if (!(st & ST_CP_VALID) || !(st & ST_INIT) ||
      (st & (ST_BUSY | ST_LOCKED | ST_RESULT))) {
    g_fail = FAIL_STATUS_AFTER;
    goto out;
  }
out:
  return (int)g_fail;
#endif
#endif
#endif  // CKPT_COLD
}
