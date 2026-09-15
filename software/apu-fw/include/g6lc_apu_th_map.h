// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Testharness G6LC_APU address map, including the DRAM hole around firmware
// RAM at 0x90000000. Decode matches pulp addr_decode: last matching rule wins.
// Not a CVA6 boot and not TGSI.

#ifndef G6LC_APU_TH_MAP_H
#define G6LC_APU_TH_MAP_H

#include <stdint.h>

#define APU_TH_DRAM_BASE 0x80000000ull
#define APU_TH_DRAM_BYTES_1G 0x40000000ull
#define APU_TH_DRAM_BYTES_512M 0x20000000ull
#define APU_TH_RAM_BASE 0x90000000ull
#define APU_TH_RAM_BYTES 0x40000ull
#define APU_TH_GUEST_BASE 0x40001000ull
#define APU_TH_GUEST_BYTES 0x1000ull
#define APU_TH_CTRL_BASE 0x40002000ull
#define APU_TH_CTRL_BYTES 0x1000ull
#define APU_TH_GPIO_BASE 0x40000000ull
#define APU_TH_GPIO_BYTES 0x1000ull

#define APU_TH_DRAM_IDX 0
#define APU_TH_GPIO_IDX 1
#define APU_TH_ETH_IDX 2
#define APU_TH_SPI_IDX 3
#define APU_TH_TIMER_IDX 4
#define APU_TH_UART_IDX 5
#define APU_TH_PLIC_IDX 6
#define APU_TH_CLINT_IDX 7
#define APU_TH_ROM_IDX 8
#define APU_TH_DEBUG_IDX 9
#define APU_TH_NB_PERIPH 10
#define APU_TH_GUEST_IDX 10
#define APU_TH_CTRL_IDX 11
#define APU_TH_RAM_IDX 12

#define APU_TH_DEBUG_BASE 0x00000000ull
#define APU_TH_DEBUG_BYTES 0x1000ull
#define APU_TH_ROM_BASE 0x00010000ull
#define APU_TH_ROM_BYTES 0x10000ull
#define APU_TH_CLINT_BASE 0x02000000ull
#define APU_TH_CLINT_BYTES 0xC0000ull
#define APU_TH_PLIC_BASE 0x0C000000ull
#define APU_TH_PLIC_BYTES 0x3FFFFFFull
#define APU_TH_UART_BASE 0x10000000ull
#define APU_TH_UART_BYTES 0x1000ull
#define APU_TH_TIMER_BASE 0x18000000ull
#define APU_TH_TIMER_BYTES 0x1000ull
#define APU_TH_SPI_BASE 0x20000000ull
#define APU_TH_SPI_BYTES 0x800000ull
#define APU_TH_ETH_BASE 0x30000000ull
#define APU_TH_ETH_BYTES 0x10000ull

#define APU_TH_APP_BOOT 0x10000ull
#define APU_TH_FW_HART 1
#define APU_TH_RESET_AUIPC 0x0003f117u
#define APU_TH_RESET_SPIN 0x0000006fu
#define APU_TH_SPIN_OFF 12u
#define APU_TH_COOKIE_OFF 0x3FF00ull
#define APU_TH_STACK_TOP 0x9003F000ull

#define APU_TH_DEC_MISS (-1)
#define APU_TH_PUNCHED_RULES 6
#define APU_TH_LOAD_RULES 5
#define APU_TH_OSBI_RULES 14
#define APU_TH_NB_RULES_EXTRA 1

typedef struct {
  int idx;
  uint64_t start;
  uint64_t end;
} apu_th_rule_t;

static int apu_th_decode(const apu_th_rule_t *rules, int n, uint64_t addr)
{
  int idx = APU_TH_DEC_MISS;
  int i;
  for (i = 0; i < n; i++) {
    if (addr >= rules[i].start && addr < rules[i].end)
      idx = rules[i].idx;
  }
  return idx;
}

static int apu_dram_contains_ram(uint64_t ram_base, uint64_t ram_bytes,
                                 uint64_t dram_base, uint64_t dram_bytes)
{
  if (ram_bytes == 0 || dram_bytes == 0)
    return 0;
  if (ram_base < dram_base)
    return 0;
  return (ram_base - dram_base) + ram_bytes <= dram_bytes;
}

static int apu_dram_hole_legal(uint64_t ram_base, uint64_t ram_bytes,
                               uint64_t dram_base, uint64_t dram_bytes)
{
  uint64_t ram_end;
  uint64_t dram_end;
  if (!apu_dram_contains_ram(ram_base, ram_bytes, dram_base, dram_bytes))
    return 0;
  ram_end = ram_base + ram_bytes;
  dram_end = dram_base + dram_bytes;
  return dram_base < ram_base && ram_end < dram_end;
}

static void apu_th_rule(apu_th_rule_t *r, int idx, uint64_t start, uint64_t end)
{
  r->idx = idx;
  r->start = start;
  r->end = end;
}

/* Non-overlapping punched map. Order is not load-bearing. */
static int apu_th_punched_map(apu_th_rule_t *out, uint64_t dram_bytes)
{
  uint64_t dram_end = APU_TH_DRAM_BASE + dram_bytes;
  uint64_t ram_end = APU_TH_RAM_BASE + APU_TH_RAM_BYTES;
  apu_th_rule(&out[0], APU_TH_GPIO_IDX, APU_TH_GPIO_BASE,
              APU_TH_GPIO_BASE + APU_TH_GPIO_BYTES);
  apu_th_rule(&out[1], APU_TH_GUEST_IDX, APU_TH_GUEST_BASE,
              APU_TH_GUEST_BASE + APU_TH_GUEST_BYTES);
  apu_th_rule(&out[2], APU_TH_CTRL_IDX, APU_TH_CTRL_BASE,
              APU_TH_CTRL_BASE + APU_TH_CTRL_BYTES);
  apu_th_rule(&out[3], APU_TH_DRAM_IDX, APU_TH_DRAM_BASE, APU_TH_RAM_BASE);
  apu_th_rule(&out[4], APU_TH_RAM_IDX, APU_TH_RAM_BASE, ram_end);
  apu_th_rule(&out[5], APU_TH_DRAM_IDX, ram_end, dram_end);
  return APU_TH_PUNCHED_RULES;
}

static uint64_t apu_core_boot_addr(unsigned core, uint64_t app_boot,
                                   unsigned fw_hart, uint64_t ram_base)
{
  if (core == fw_hart)
    return ram_base;
  return app_boot;
}

static int apu_boot_split_legal(unsigned fw_hart, unsigned ncores,
                                uint64_t app_boot, uint64_t ram_base,
                                uint64_t ram_bytes)
{
  unsigned i;
  int found_app = 0;
  if (ncores < 2 || fw_hart == 0 || fw_hart >= ncores)
    return 0;
  if (app_boot == ram_base)
    return 0;
  if (app_boot >= ram_base && app_boot - ram_base < ram_bytes)
    return 0;
  if (apu_core_boot_addr(fw_hart, app_boot, fw_hart, ram_base) != ram_base)
    return 0;
  for (i = 0; i < ncores; i++) {
    if (i != fw_hart &&
        apu_core_boot_addr(i, app_boot, fw_hart, ram_base) == app_boot)
      found_app = 1;
  }
  return found_app;
}

/* Testharness compositor rules: DRAM lo, guest, control, RAM, DRAM hi. */
static int apu_th_load_rules(apu_th_rule_t *out, uint64_t dram_bytes)
{
  uint64_t dram_end = APU_TH_DRAM_BASE + dram_bytes;
  uint64_t ram_end = APU_TH_RAM_BASE + APU_TH_RAM_BYTES;
  apu_th_rule(&out[0], APU_TH_DRAM_IDX, APU_TH_DRAM_BASE, APU_TH_RAM_BASE);
  apu_th_rule(&out[1], APU_TH_GUEST_IDX, APU_TH_GUEST_BASE,
              APU_TH_GUEST_BASE + APU_TH_GUEST_BYTES);
  apu_th_rule(&out[2], APU_TH_CTRL_IDX, APU_TH_CTRL_BASE,
              APU_TH_CTRL_BASE + APU_TH_CTRL_BYTES);
  apu_th_rule(&out[3], APU_TH_RAM_IDX, APU_TH_RAM_BASE, ram_end);
  apu_th_rule(&out[4], APU_TH_DRAM_IDX, ram_end, dram_end);
  return APU_TH_LOAD_RULES;
}

/* Full DRAM range listed after RAM: last-match-wins aliases firmware RAM. */
static int apu_th_aliased_map(apu_th_rule_t *out, uint64_t dram_bytes)
{
  apu_th_rule(&out[0], APU_TH_RAM_IDX, APU_TH_RAM_BASE,
              APU_TH_RAM_BASE + APU_TH_RAM_BYTES);
  apu_th_rule(&out[1], APU_TH_DRAM_IDX, APU_TH_DRAM_BASE,
              APU_TH_DRAM_BASE + dram_bytes);
  return 2;
}

/* Testharness +define+G6LC_APU addr_map order in ariane_testharness.sv.
 * First nine peripherals, then compositor DRAM lo/guest/ctrl/RAM/DRAM hi.
 * This is the OpenSBI-visible decode; not an OpenSBI firmware boot. */
static int apu_th_osbi_rules(apu_th_rule_t *out, uint64_t dram_bytes)
{
  uint64_t dram_end = APU_TH_DRAM_BASE + dram_bytes;
  uint64_t ram_end = APU_TH_RAM_BASE + APU_TH_RAM_BYTES;
  apu_th_rule(&out[0], APU_TH_DEBUG_IDX, APU_TH_DEBUG_BASE,
              APU_TH_DEBUG_BASE + APU_TH_DEBUG_BYTES);
  apu_th_rule(&out[1], APU_TH_ROM_IDX, APU_TH_ROM_BASE,
              APU_TH_ROM_BASE + APU_TH_ROM_BYTES);
  apu_th_rule(&out[2], APU_TH_CLINT_IDX, APU_TH_CLINT_BASE,
              APU_TH_CLINT_BASE + APU_TH_CLINT_BYTES);
  apu_th_rule(&out[3], APU_TH_PLIC_IDX, APU_TH_PLIC_BASE,
              APU_TH_PLIC_BASE + APU_TH_PLIC_BYTES);
  apu_th_rule(&out[4], APU_TH_UART_IDX, APU_TH_UART_BASE,
              APU_TH_UART_BASE + APU_TH_UART_BYTES);
  apu_th_rule(&out[5], APU_TH_TIMER_IDX, APU_TH_TIMER_BASE,
              APU_TH_TIMER_BASE + APU_TH_TIMER_BYTES);
  apu_th_rule(&out[6], APU_TH_SPI_IDX, APU_TH_SPI_BASE,
              APU_TH_SPI_BASE + APU_TH_SPI_BYTES);
  apu_th_rule(&out[7], APU_TH_ETH_IDX, APU_TH_ETH_BASE,
              APU_TH_ETH_BASE + APU_TH_ETH_BYTES);
  apu_th_rule(&out[8], APU_TH_GPIO_IDX, APU_TH_GPIO_BASE,
              APU_TH_GPIO_BASE + APU_TH_GPIO_BYTES);
  apu_th_rule(&out[9], APU_TH_DRAM_IDX, APU_TH_DRAM_BASE, APU_TH_RAM_BASE);
  apu_th_rule(&out[10], APU_TH_GUEST_IDX, APU_TH_GUEST_BASE,
              APU_TH_GUEST_BASE + APU_TH_GUEST_BYTES);
  apu_th_rule(&out[11], APU_TH_CTRL_IDX, APU_TH_CTRL_BASE,
              APU_TH_CTRL_BASE + APU_TH_CTRL_BYTES);
  apu_th_rule(&out[12], APU_TH_RAM_IDX, APU_TH_RAM_BASE, ram_end);
  apu_th_rule(&out[13], APU_TH_DRAM_IDX, ram_end, dram_end);
  return APU_TH_OSBI_RULES;
}

#endif
