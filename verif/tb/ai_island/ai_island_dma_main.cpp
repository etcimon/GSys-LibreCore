// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// C++ driver for tb_g6lc_ai_island_dma.
// Runs one DMA-fetched GEMM job and reads the sticky policy PMU words.

#include "Vtb_g6lc_ai_island_dma.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>

static Vtb_g6lc_ai_island_dma *dut;
static uint64_t cycles;
static int errors;

static void tick() {
  dut->clk = 0;
  dut->eval();
  dut->clk = 1;
  dut->eval();
  cycles++;
  dut->req = 0;
  dut->we = 0;
}

static void reg_write(uint16_t a, uint32_t d) {
  dut->req = 1;
  dut->we = 1;
  dut->addr = a;
  dut->wdata = d;
  tick();
}

static uint32_t reg_read(uint16_t a) {
  dut->req = 1;
  dut->we = 0;
  dut->addr = a;
  tick();
  for (int i = 0; i < 4; i++) {
    if (dut->rvalid)
      return dut->rdata;
    tick();
  }
  return dut->rdata;
}

static void program_region(int q, uint64_t base, uint64_t limit, uint32_t perm) {
  uint16_t b = (uint16_t)(0x0120 + q * 0x20);
  reg_write(b + 0x0, (uint32_t)base);
  reg_write(b + 0x4, (uint32_t)(base >> 32));
  reg_write(b + 0x8, (uint32_t)limit);
  reg_write(b + 0xC, (uint32_t)(limit >> 32));
  reg_write(b + 0x10, perm & 3);
}

static void wait_done(uint16_t &status, uint32_t &ticket) {
  for (int i = 0; i < 1000; i++) {
    uint32_t sticky = reg_read(0x010C);
    if (sticky & 1) {
      ticket = reg_read(0x0110);
      status = (uint16_t)(reg_read(0x0114) & 0xFFFF);
      reg_write(0x010C, 1);  // claim
      return;
    }
  }
  std::fprintf(stderr, "timeout waiting for done\n");
  errors++;
  status = 0xFFFF;
  ticket = 0;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  dut = new Vtb_g6lc_ai_island_dma;

  // Drive reset
  dut->rst_ni = 0;
  dut->req = 0;
  dut->we = 0;
  for (int i = 0; i < 10; i++)
    tick();
  dut->rst_ni = 1;
  for (int i = 0; i < 4; i++)
    tick();

  // Capability sanity
  uint32_t cap = reg_read(0x0000);
  if ((cap & 0xFFFF) != 1) {
    std::fprintf(stderr, "cap version mismatch: %u\n", cap & 0xFFFF);
    errors++;
  }

  // Enable
  reg_write(0x0100, 1);

  // Region: [0x80010000, 0x80011000), RW
  program_region(0, 0x80010000ULL, 0x80011000ULL, 3);

  // Descriptor pointer in AXI memory
  reg_write(0x0118, 0x80010000U);
  reg_write(0x011C, 0x0);

  // Doorbell: bit31 = fetch from desc_ptr, ticket = 10
  reg_write(0x0108, 0x80000A00U);

  uint16_t status;
  uint32_t ticket;
  wait_done(status, ticket);


  if (status != 0) {  // ST_OK = 0
    std::fprintf(stderr, "GEMM failed status=%u ticket=%u\n", status, ticket);
    errors++;
  } else {
    std::printf("PASS GEMM status=OK ticket=%u\n", ticket);
  }

  // Read sticky policy PMU
  uint32_t p_code = reg_read(0x0190);
  uint32_t p_word = reg_read(0x0194);
  uint32_t p_topo = reg_read(0x0198);
  uint32_t p_ev   = reg_read(0x019C);

  std::printf("policy code = 0x%08x\n", p_code);
  std::printf("policy word = 0x%08x\n", p_word);
  std::printf("policy topo = 0x%08x\n", p_topo);
  std::printf("policy event= 0x%08x\n", p_ev);

  if (p_code == 0 && p_word == 0 && p_topo == 0) {
    std::fprintf(stderr, "FAIL policy snapshots are all zero\n");
    errors++;
  } else {
    std::printf("PASS policy snapshots are non-zero\n");
  }

  // Run a few more cycles to drain any final response.
  for (int i = 0; i < 10; i++)
    tick();

  dut->final();
  delete dut;

  if (errors) {
    std::printf("*** FAILED *** %d errors\n", errors);
    return 1;
  }
  std::printf("*** SUCCESS *** ai-island DMA policy smoke (%lu cycles)\n", cycles);
  return 0;
}
