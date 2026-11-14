// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

// Load-after-store ordering through the load unit's page-offset interlock
// (core/load_unit.sv WAIT_PAGE_OFFSET). A long divide ahead of the pair holds
// commit, so the store is still speculative when the load is issued.
//
//  1. Non-cacheable: 64-bit store to CLINT mtimecmp[0], then a 64-bit load of
//     it. Non-cacheable loads are never forwarded from the store buffer, so
//     the load must wait for the store to reach the device. A load that is
//     re-issued early returns the previous value -> FAIL_MMIO.
//  2. Cacheable, partial coverage: byte store into a 64-bit word, then a
//     64-bit load. The forward cannot cover the load -> it must wait and read
//     the merged word. An early re-issue returns the old byte -> FAIL_PARTIAL.
//
// No Storamic device is touched: the same image runs on any testharness
// build, which is what makes it usable as the isolation witness.
#include <stdint.h>

#define MTIMECMP0 0x02004000UL
#define ROUNDS 12

enum { FAIL_MMIO = 33, FAIL_PARTIAL = 34 };

static volatile uint64_t word __attribute__((aligned(64)));

static inline __attribute__((always_inline)) void settle(void) {
  for (volatile int i = 0; i < 48; i++) { }
}

int main(void) {
  volatile uint64_t *cmp = (volatile uint64_t *)MTIMECMP0;
  for (unsigned r = 0; r < ROUNDS; r++) {
    // Dividend width varies the divide length, i.e. how long commit is held.
    uint64_t num = ~0UL >> (r * 5), den = 7, got;
    uint64_t old_v = 0x7000000011110000UL + r;
    uint64_t new_v = 0x7fff0000a5a50000UL + (r << 8);

    *cmp = old_v;
    settle();
    __asm__ volatile("divu t0, %[n], %[d]\n"
                     "sd   %[v], 0(%[p])\n"
                     "ld   %[g], 0(%[p])\n"
                     : [g] "=&r"(got)
                     : [n] "r"(num), [d] "r"(den), [v] "r"(new_v), [p] "r"(cmp)
                     : "t0", "memory");
    if (got != new_v) return FAIL_MMIO;

    word = 0x1122334455667700UL + r;
    settle();
    __asm__ volatile("divu t0, %[n], %[d]\n"
                     "sb   %[v], 3(%[p])\n"
                     "ld   %[g], 0(%[p])\n"
                     : [g] "=&r"(got)
                     : [n] "r"(num), [d] "r"(den), [v] "r"(0xC0UL + r), [p] "r"(&word)
                     : "t0", "memory");
    if (got != ((0x1122334455667700UL + r) & ~0xFF000000UL) + ((0xC0UL + r) << 24))
      return FAIL_PARTIAL;
  }
  // Leave the timer compare far away again.
  *cmp = ~0UL;
  return 0;
}
