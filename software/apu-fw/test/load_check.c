// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Host-side lock for the testharness load compositor rules + boot PCs.
// Not RTL and not a CVA6 fetch.

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

int main(void)
{
  apu_th_rule_t rules[APU_TH_LOAD_RULES];
  int n = apu_th_load_rules(rules, APU_TH_DRAM_BYTES_1G);

  if (n != APU_TH_LOAD_RULES)
    FAIL("load rule count");
  if (APU_TH_NB_RULES_EXTRA != 1)
    FAIL("extra DRAM fragment");
  if (rules[0].idx != APU_TH_DRAM_IDX || rules[0].end != APU_TH_RAM_BASE)
    FAIL("dram lo");
  if (rules[1].idx != APU_TH_GUEST_IDX)
    FAIL("guest");
  if (rules[2].idx != APU_TH_CTRL_IDX)
    FAIL("ctrl");
  if (rules[3].idx != APU_TH_RAM_IDX || rules[3].start != APU_TH_RAM_BASE)
    FAIL("ram");
  if (rules[4].idx != APU_TH_DRAM_IDX || rules[4].start != APU_TH_RAM_BASE +
                                                              APU_TH_RAM_BYTES)
    FAIL("dram hi");

  if (expect_idx(rules, n, APU_TH_DRAM_BASE, APU_TH_DRAM_IDX, "DRAM base") ||
      expect_idx(rules, n, APU_TH_RAM_BASE, APU_TH_RAM_IDX, "fw ram") ||
      expect_idx(rules, n, APU_TH_RAM_BASE + APU_TH_COOKIE_OFF, APU_TH_RAM_IDX,
                 "cookie") ||
      expect_idx(rules, n, APU_TH_RAM_BASE + APU_TH_RAM_BYTES, APU_TH_DRAM_IDX,
                 "after ram") ||
      expect_idx(rules, n, APU_TH_GUEST_BASE, APU_TH_GUEST_IDX, "guest") ||
      expect_idx(rules, n, APU_TH_CTRL_BASE, APU_TH_CTRL_IDX, "ctrl") ||
      expect_idx(rules, n, APU_TH_GPIO_BASE, APU_TH_DEC_MISS, "gpio miss"))
    return 1;

  if (apu_core_boot_addr(0, APU_TH_APP_BOOT, APU_TH_FW_HART, APU_TH_RAM_BASE) !=
      APU_TH_APP_BOOT)
    FAIL("load hart 0");
  if (apu_core_boot_addr(1, APU_TH_APP_BOOT, APU_TH_FW_HART, APU_TH_RAM_BASE) !=
      APU_TH_RAM_BASE)
    FAIL("load hart 1");

  puts("PASS load_check");
  return 0;
}
