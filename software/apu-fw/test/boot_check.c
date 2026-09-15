// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Host-side lock that hart 1 resets at firmware RAM, hart 0 at ROM,
// and the checked-in hex/DTSI match. Not a CVA6 fetch.

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "g6lc_apu_th_map.h"

#define FAIL(msg)                                                              \
  do {                                                                         \
    printf("FAIL %s\n", msg);                                                  \
    return 1;                                                                  \
  } while (0)

static int read_hex_word(FILE *f, uint32_t *word)
{
  char line[128];
  char *s;
  unsigned long v;
  while (fgets(line, sizeof(line), f)) {
    s = line;
    while (*s == ' ' || *s == '\t')
      s++;
    if (*s == '\0' || *s == '\n' || *s == '/' || *s == '#')
      continue;
    v = strtoul(s, NULL, 16);
    *word = (uint32_t)v;
    return 0;
  }
  return 1;
}

static int check_hex(const char *path)
{
  FILE *f;
  uint32_t w;
  unsigned i;
  f = fopen(path, "r");
  if (!f) {
    printf("FAIL open hex %s\n", path);
    return 1;
  }
  if (read_hex_word(f, &w) || w != APU_TH_RESET_AUIPC) {
    fclose(f);
    FAIL("hex reset auipc");
  }
  for (i = 1; i <= APU_TH_SPIN_OFF / 4u; i++) {
    if (read_hex_word(f, &w)) {
      fclose(f);
      FAIL("hex short");
    }
  }
  fclose(f);
  if (w != APU_TH_RESET_SPIN)
    FAIL("hex crt0 spin");
  return 0;
}

static int check_dtsi(const char *path)
{
  FILE *f;
  char *buf;
  long n;
  f = fopen(path, "r");
  if (!f) {
    printf("FAIL open dtsi %s\n", path);
    return 1;
  }
  if (fseek(f, 0, SEEK_END) != 0) {
    fclose(f);
    FAIL("dtsi seek");
  }
  n = ftell(f);
  if (n < 0 || n > 1 << 20) {
    fclose(f);
    FAIL("dtsi size");
  }
  rewind(f);
  buf = (char *)malloc((size_t)n + 1);
  if (!buf) {
    fclose(f);
    FAIL("dtsi alloc");
  }
  if (fread(buf, 1, (size_t)n, f) != (size_t)n) {
    free(buf);
    fclose(f);
    FAIL("dtsi read");
  }
  fclose(f);
  buf[n] = '\0';
  if (!strstr(buf, "next-addr = <0x0 0x90000000>")) {
    free(buf);
    FAIL("dtsi next-addr");
  }
  if (!strstr(buf, "base = <0x0 0x90000000>")) {
    free(buf);
    FAIL("dtsi ram base");
  }
  if (!strstr(buf, "base = <0x0 0x40002000>")) {
    free(buf);
    FAIL("dtsi control base");
  }
  if (!strstr(buf, "Not included")) {
    free(buf);
    FAIL("dtsi must stay out of default DTBs");
  }
  if (strstr(buf, "ariane-smt2")) {
    /* comment is required: overlay must not be applied to SMT2 */
  } else {
    free(buf);
    FAIL("dtsi smt2 warning");
  }
  free(buf);
  return 0;
}

static int check_elf(const char *path)
{
  FILE *f;
  unsigned char hdr[64];
  uint64_t entry;
  int i;
  f = fopen(path, "rb");
  if (!f)
    return 0;
  if (fread(hdr, 1, 64, f) != 64) {
    fclose(f);
    FAIL("elf header");
  }
  fclose(f);
  if (hdr[0] != 0x7f || hdr[1] != 'E' || hdr[2] != 'L' || hdr[3] != 'F')
    FAIL("elf magic");
  if (hdr[4] != 2 || hdr[5] != 1)
    FAIL("elf class/data");
  if (hdr[16] != 2 || hdr[17] != 0)
    FAIL("elf type");
  if (hdr[18] != 0xf3 || hdr[19] != 0)
    FAIL("elf machine");
  entry = 0;
  for (i = 0; i < 8; i++)
    entry |= (uint64_t)hdr[24 + i] << (8 * i);
  if (entry != APU_TH_RAM_BASE) {
    printf("FAIL elf entry 0x%llx\n", (unsigned long long)entry);
    return 1;
  }
  return 0;
}

int main(int argc, char **argv)
{
  const char *hex = argc > 1 ? argv[1] : "../../verif/tb/apu/apu_fw.hex";
  const char *elf = argc > 2 ? argv[2] : "apu_fw.elf";
  const char *dtsi =
      argc > 3 ? argv[3] : "../../corev_apu/bootrom/g6lc-apu-domain.dtsi";

  if (APU_TH_APP_BOOT == APU_TH_RAM_BASE)
    FAIL("app boot aliases RAM");
  if (apu_core_boot_addr(0, APU_TH_APP_BOOT, APU_TH_FW_HART, APU_TH_RAM_BASE) !=
      APU_TH_APP_BOOT)
    FAIL("hart 0 boot");
  if (apu_core_boot_addr(1, APU_TH_APP_BOOT, APU_TH_FW_HART, APU_TH_RAM_BASE) !=
      APU_TH_RAM_BASE)
    FAIL("hart 1 boot");
  if (!apu_boot_split_legal(APU_TH_FW_HART, 2, APU_TH_APP_BOOT, APU_TH_RAM_BASE,
                            APU_TH_RAM_BYTES))
    FAIL("boot split");
  if (apu_boot_split_legal(APU_TH_FW_HART, 2, APU_TH_RAM_BASE, APU_TH_RAM_BASE,
                           APU_TH_RAM_BYTES))
    FAIL("same boot is split");
  if (apu_boot_split_legal(APU_TH_FW_HART, 1, APU_TH_APP_BOOT, APU_TH_RAM_BASE,
                           APU_TH_RAM_BYTES))
    FAIL("single core is split");
  if (APU_TH_STACK_TOP <= APU_TH_RAM_BASE ||
      APU_TH_STACK_TOP >= APU_TH_RAM_BASE + APU_TH_RAM_BYTES)
    FAIL("stack top");
  if (APU_TH_COOKIE_OFF >= APU_TH_RAM_BYTES)
    FAIL("cookie off");
  if (APU_TH_RAM_BASE + APU_TH_COOKIE_OFF == APU_TH_STACK_TOP)
    FAIL("cookie aliases stack");

  if (check_hex(hex))
    return 1;
  if (check_dtsi(dtsi))
    return 1;
  if (check_elf(elf))
    return 1;

  puts("PASS boot_check");
  return 0;
}
