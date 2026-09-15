// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Host-side lock that firmware RAM at 0x90000000 is a DRAM hole, not an alias.

#include <stdio.h>
#include "g6lc_apu_th_map.h"

#define FAIL(msg)                                                              \
  do {                                                                         \
    printf("FAIL %s\n", msg);                                                  \
    return 1;                                                                  \
  } while (0)

static int expect_idx(const apu_th_rule_t *rules, int n, uint64_t addr,
                      int want, const char *name)
{
  int got = apu_th_decode(rules, n, addr);
  if (got != want) {
    printf("FAIL %s addr=0x%llx got=%d want=%d\n", name,
           (unsigned long long)addr, got, want);
    return 1;
  }
  return 0;
}

static int check_punched(uint64_t dram_bytes, uint64_t last_dram,
                         const char *tag)
{
  apu_th_rule_t rules[APU_TH_PUNCHED_RULES];
  int n = apu_th_punched_map(rules, dram_bytes);
  if (n != APU_TH_PUNCHED_RULES)
    FAIL("punched rule count");
  if (!apu_dram_hole_legal(APU_TH_RAM_BASE, APU_TH_RAM_BYTES, APU_TH_DRAM_BASE,
                           dram_bytes)) {
    printf("FAIL %s hole illegal\n", tag);
    return 1;
  }
  if (expect_idx(rules, n, APU_TH_DRAM_BASE, APU_TH_DRAM_IDX, tag) ||
      expect_idx(rules, n, APU_TH_RAM_BASE - 1ull, APU_TH_DRAM_IDX, tag) ||
      expect_idx(rules, n, APU_TH_RAM_BASE, APU_TH_RAM_IDX, tag) ||
      expect_idx(rules, n, APU_TH_RAM_BASE + APU_TH_RAM_BYTES - 4ull,
                 APU_TH_RAM_IDX, tag) ||
      expect_idx(rules, n, APU_TH_RAM_BASE + APU_TH_RAM_BYTES, APU_TH_DRAM_IDX,
                 tag) ||
      expect_idx(rules, n, last_dram, APU_TH_DRAM_IDX, tag) ||
      expect_idx(rules, n, APU_TH_GUEST_BASE, APU_TH_GUEST_IDX, tag) ||
      expect_idx(rules, n, APU_TH_CTRL_BASE, APU_TH_CTRL_IDX, tag) ||
      expect_idx(rules, n, APU_TH_GPIO_BASE, APU_TH_GPIO_IDX, tag) ||
      expect_idx(rules, n, APU_TH_DRAM_BASE + dram_bytes, APU_TH_DEC_MISS,
                 tag))
    return 1;
  return 0;
}

int main(void)
{
  apu_th_rule_t aliased[2];

  if (APU_TH_GUEST_IDX != APU_TH_NB_PERIPH)
    FAIL("guest idx");
  if (APU_TH_CTRL_IDX != APU_TH_NB_PERIPH + 1)
    FAIL("ctrl idx");
  if (APU_TH_RAM_IDX != APU_TH_NB_PERIPH + 2)
    FAIL("ram idx");

  if (check_punched(APU_TH_DRAM_BYTES_1G, 0xBFFFFFFFull, "1GiB"))
    return 1;
  if (check_punched(APU_TH_DRAM_BYTES_512M, 0x9FFFFFFFull, "512MiB"))
    return 1;

  if (apu_dram_hole_legal(APU_TH_DRAM_BASE, APU_TH_RAM_BYTES, APU_TH_DRAM_BASE,
                          APU_TH_DRAM_BYTES_1G))
    FAIL("RAM at DRAM base is a hole");
  if (apu_dram_hole_legal(0xC0000000ull, APU_TH_RAM_BYTES, APU_TH_DRAM_BASE,
                          APU_TH_DRAM_BYTES_1G))
    FAIL("RAM past DRAM is a hole");
  if (apu_dram_contains_ram(0x7F000000ull, APU_TH_RAM_BYTES, APU_TH_DRAM_BASE,
                            APU_TH_DRAM_BYTES_1G))
    FAIL("RAM below DRAM is contained");

  apu_th_aliased_map(aliased, APU_TH_DRAM_BYTES_1G);
  if (expect_idx(aliased, 2, APU_TH_RAM_BASE, APU_TH_DRAM_IDX, "aliased RAM") ||
      expect_idx(aliased, 2, APU_TH_RAM_BASE + 0x3FF00ull, APU_TH_DRAM_IDX,
                 "aliased cookie"))
    return 1;

  puts("PASS map_check");
  return 0;
}
