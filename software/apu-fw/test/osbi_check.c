// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Host-side lock for the testharness G6LC_APU OpenSBI-visible map and
// opt-in domain DTS. Not an OpenSBI firmware boot and not SMT2.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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

static char *read_file(const char *path, long *n_out)
{
  FILE *f;
  long n;
  char *buf;
  f = fopen(path, "rb");
  if (!f)
    return NULL;
  if (fseek(f, 0, SEEK_END) != 0) {
    fclose(f);
    return NULL;
  }
  n = ftell(f);
  if (n < 0 || n > 8 << 20) {
    fclose(f);
    return NULL;
  }
  rewind(f);
  buf = (char *)malloc((size_t)n + 1);
  if (!buf) {
    fclose(f);
    return NULL;
  }
  if (fread(buf, 1, (size_t)n, f) != (size_t)n) {
    free(buf);
    fclose(f);
    return NULL;
  }
  fclose(f);
  buf[n] = '\0';
  if (n_out)
    *n_out = n;
  return buf;
}

static int contains(const char *buf, const char *needle)
{
  return buf && needle && strstr(buf, needle) != NULL;
}

static int ordered(const char *buf, const char *a, const char *b,
                   const char *name)
{
  const char *pa;
  const char *pb;
  if (!buf)
    FAIL(name);
  pa = strstr(buf, a);
  pb = strstr(buf, b);
  if (!pa || !pb || pa > pb) {
    printf("FAIL order %s\n", name);
    return 1;
  }
  return 0;
}

static int ordered_after(const char *buf, const char *anchor, const char *a,
                         const char *b, const char *name)
{
  const char *base;
  if (!buf)
    FAIL(name);
  base = strstr(buf, anchor);
  if (!base) {
    printf("FAIL missing anchor %s\n", name);
    return 1;
  }
  return ordered(base, a, b, name);
}

static int must_have(const char *buf, const char *needle, const char *name)
{
  if (!contains(buf, needle)) {
    printf("FAIL missing %s\n", name);
    return 1;
  }
  return 0;
}

static int must_not(const char *buf, const char *needle, const char *name)
{
  if (contains(buf, needle)) {
    printf("FAIL forbidden %s\n", name);
    return 1;
  }
  return 0;
}

static int check_default_dts(const char *path)
{
  char *buf;
  buf = read_file(path, NULL);
  if (!buf) {
    printf("FAIL open default dts %s\n", path);
    return 1;
  }
  if (contains(buf, "/include/ \"g6lc-apu-domain.dtsi\"") ||
      contains(buf, "#include \"g6lc-apu-domain.dtsi\"") ||
      contains(buf, "opensbi-domains")) {
    free(buf);
    printf("FAIL default dts includes overlay %s\n", path);
    return 1;
  }
  free(buf);
  return 0;
}

int main(int argc, char **argv)
{
  const char *root = argc > 1 ? argv[1] : "../..";
  char path[512];
  char *buf;
  apu_th_rule_t rules[APU_TH_OSBI_RULES];
  apu_th_rule_t aliased[2];
  int n;

  if (APU_TH_APP_BOOT != APU_TH_ROM_BASE)
    FAIL("app boot is ROM");
  if (APU_TH_DRAM_BASE != 0x80000000ull)
    FAIL("OpenSBI load address");
  if (APU_TH_OSBI_RULES != APU_TH_NB_PERIPH + 3 + APU_TH_NB_RULES_EXTRA)
    FAIL("testharness rule count");

  n = apu_th_osbi_rules(rules, APU_TH_DRAM_BYTES_1G);
  if (n != APU_TH_OSBI_RULES)
    FAIL("osbi rule count");
  if (rules[0].idx != APU_TH_DEBUG_IDX)
    FAIL("debug first");
  if (rules[8].idx != APU_TH_GPIO_IDX)
    FAIL("gpio before DRAM hole");
  if (rules[9].idx != APU_TH_DRAM_IDX || rules[9].end != APU_TH_RAM_BASE)
    FAIL("dram lo");
  if (rules[10].idx != APU_TH_GUEST_IDX)
    FAIL("guest");
  if (rules[11].idx != APU_TH_CTRL_IDX)
    FAIL("ctrl");
  if (rules[12].idx != APU_TH_RAM_IDX)
    FAIL("ram");
  if (rules[13].idx != APU_TH_DRAM_IDX || rules[13].start !=
                                              APU_TH_RAM_BASE + APU_TH_RAM_BYTES)
    FAIL("dram hi");

  if (expect_idx(rules, n, APU_TH_DEBUG_BASE, APU_TH_DEBUG_IDX, "debug") ||
      expect_idx(rules, n, APU_TH_ROM_BASE, APU_TH_ROM_IDX, "rom") ||
      expect_idx(rules, n, APU_TH_CLINT_BASE, APU_TH_CLINT_IDX, "clint") ||
      expect_idx(rules, n, APU_TH_PLIC_BASE, APU_TH_PLIC_IDX, "plic") ||
      expect_idx(rules, n, APU_TH_UART_BASE, APU_TH_UART_IDX, "uart") ||
      expect_idx(rules, n, APU_TH_GPIO_BASE, APU_TH_GPIO_IDX, "gpio") ||
      expect_idx(rules, n, APU_TH_GUEST_BASE, APU_TH_GUEST_IDX, "guest") ||
      expect_idx(rules, n, APU_TH_CTRL_BASE, APU_TH_CTRL_IDX, "ctrl") ||
      expect_idx(rules, n, APU_TH_DRAM_BASE, APU_TH_DRAM_IDX, "dram lo") ||
      expect_idx(rules, n, APU_TH_RAM_BASE, APU_TH_RAM_IDX, "fw ram") ||
      expect_idx(rules, n, APU_TH_RAM_BASE + APU_TH_COOKIE_OFF, APU_TH_RAM_IDX,
                 "cookie") ||
      expect_idx(rules, n, APU_TH_RAM_BASE + APU_TH_RAM_BYTES, APU_TH_DRAM_IDX,
                 "dram hi"))
    return 1;

  apu_th_aliased_map(aliased, APU_TH_DRAM_BYTES_1G);
  if (apu_th_decode(aliased, 2, APU_TH_RAM_BASE) != APU_TH_DRAM_IDX)
    FAIL("aliased steal");

  snprintf(path, sizeof(path), "%s/corev_apu/tb/ariane_testharness.sv", root);
  buf = read_file(path, NULL);
  if (!buf)
    FAIL("open testharness");
  if (must_have(buf, "`ifdef G6LC_APU", "G6LC_APU") ||
      must_have(buf, "PerCoreBoot", "PerCoreBoot") ||
      must_have(buf, ".dma_rsp_i('0)", "idle DMA") ||
      must_have(buf, "OpenSBI-visible testharness map", "osbi map comment") ||
      ordered_after(buf, "OpenSBI-visible testharness map",
                    "ariane_soc::Debug", "ariane_soc::ROM", "debug-rom") ||
      ordered_after(buf, "OpenSBI-visible testharness map",
                    "ariane_soc::GPIO", "apu_dram_lo_rule", "gpio-dramlo") ||
      ordered_after(buf, "OpenSBI-visible testharness map",
                    "apu_dram_lo_rule", "apu_guest_rule", "lo-guest") ||
      ordered_after(buf, "OpenSBI-visible testharness map",
                    "apu_guest_rule", "apu_ctrl_rule", "guest-ctrl") ||
      ordered_after(buf, "OpenSBI-visible testharness map",
                    "apu_ctrl_rule", "apu_ram_rule", "ctrl-ram") ||
      ordered_after(buf, "OpenSBI-visible testharness map",
                    "apu_ram_rule", "apu_dram_hi_rule", "ram-hi")) {
    free(buf);
    return 1;
  }
  free(buf);

  snprintf(path, sizeof(path), "%s/corev_apu/fpga/src/ariane_xilinx.sv", root);
  buf = read_file(path, NULL);
  if (!buf)
    FAIL("open fpga");
  if (must_not(buf, "G6LC_APU", "fpga G6LC_APU")) {
    free(buf);
    return 1;
  }
  free(buf);

  snprintf(path, sizeof(path), "%s/corev_apu/altera/src/cva6_altera.sv", root);
  buf = read_file(path, NULL);
  if (!buf)
    FAIL("open altera");
  if (must_not(buf, "G6LC_APU", "altera G6LC_APU")) {
    free(buf);
    return 1;
  }
  free(buf);

  snprintf(path, sizeof(path),
           "%s/software/smt2-linux/scripts/build-opensbi-smt2.sh", root);
  buf = read_file(path, NULL);
  if (!buf)
    FAIL("open smt2 opensbi");
  if (must_not(buf, "g6lc-apu-domain", "smt2 overlay") ||
      must_not(buf, "G6LC_APU", "smt2 G6LC_APU") ||
      must_not(buf, "ariane-g6lc-apu", "smt2 opt-in dts")) {
    free(buf);
    return 1;
  }
  free(buf);

  snprintf(path, sizeof(path), "%s/corev_apu/bootrom/ariane-g6lc-apu.dts", root);
  buf = read_file(path, NULL);
  if (!buf)
    FAIL("open opt-in dts");
  if (must_have(buf, "/include/ \"ariane-stream8.dts\"", "stream8 include") ||
      must_have(buf, "/include/ \"g6lc-apu-domain.dtsi\"", "overlay include") ||
      must_have(buf, "possible-harts = <&CPU1>", "possible-harts") ||
      must_have(buf, "boot-hart = <&CPU1>", "boot-hart") ||
      must_have(buf, "Not a default DTB", "opt-in warning") ||
      must_have(buf, "ariane-smt2", "smt2 warning")) {
    free(buf);
    return 1;
  }
  free(buf);

  snprintf(path, sizeof(path), "%s/corev_apu/bootrom/g6lc-apu-domain.dtsi",
           root);
  buf = read_file(path, NULL);
  if (!buf)
    FAIL("open overlay");
  if (must_have(buf, "next-addr = <0x0 0x90000000>", "overlay next-addr") ||
      must_have(buf, "base = <0x0 0x90000000>", "overlay ram") ||
      must_have(buf, "base = <0x0 0x40002000>", "overlay ctrl") ||
      must_have(buf, "Not included", "overlay default-off") ||
      must_have(buf, "ariane-g6lc-apu.dts", "opt-in pointer")) {
    free(buf);
    return 1;
  }
  free(buf);

  snprintf(path, sizeof(path), "%s/corev_apu/bootrom/ariane.dts", root);
  if (check_default_dts(path))
    return 1;
  snprintf(path, sizeof(path), "%s/corev_apu/bootrom/ariane-linux.dts", root);
  if (check_default_dts(path))
    return 1;
  snprintf(path, sizeof(path), "%s/corev_apu/bootrom/ariane-smt2.dts", root);
  if (check_default_dts(path))
    return 1;
  snprintf(path, sizeof(path), "%s/corev_apu/bootrom/ariane-stream8.dts", root);
  if (check_default_dts(path))
    return 1;
  snprintf(path, sizeof(path), "%s/corev_apu/bootrom/ariane-ai.dts", root);
  if (check_default_dts(path))
    return 1;
  snprintf(path, sizeof(path), "%s/corev_apu/bootrom/ariane-ooo-server.dts",
           root);
  if (check_default_dts(path))
    return 1;
  snprintf(path, sizeof(path), "%s/corev_apu/bootrom/ariane-server-math-v.dts",
           root);
  if (check_default_dts(path))
    return 1;

  snprintf(path, sizeof(path), "%s/corev_apu/bootrom/Makefile", root);
  buf = read_file(path, NULL);
  if (!buf)
    FAIL("open bootrom makefile");
  if (must_not(buf, "ariane-g6lc-apu", "default dtb list")) {
    free(buf);
    return 1;
  }
  free(buf);

  puts("PASS osbi_check");
  return 0;
}
