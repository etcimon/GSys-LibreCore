// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// Clocked C++ driver for g6lc_ai_island_top P3 spine smoke (AI-3 + cap + engine).

#include "Vg6lc_ai_island_top.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>

static Vg6lc_ai_island_top *dut;
static uint64_t cycles;
static int errors;

static void tick() {
  dut->clk_i = 0;
  dut->eval();
  dut->clk_i = 1;
  dut->eval();
  cycles++;
  dut->req_i = 0;
  dut->we_i = 0;
}

static void reg_write(uint16_t addr, uint32_t data) {
  dut->req_i = 1;
  dut->we_i = 1;
  dut->addr_i = addr;
  dut->wdata_i = data;
  tick();
}

static uint32_t reg_read(uint16_t addr) {
  dut->req_i = 1;
  dut->we_i = 0;
  dut->addr_i = addr;
  tick(); // request accepted
  // Response is registered (cap window has +1); wait for rvalid
  for (int i = 0; i < 4; i++) {
    if (dut->rvalid_o)
      return dut->rdata_o;
    tick();
  }
  return dut->rdata_o;
}

static void wait_done(uint16_t &status, uint32_t &ticket) {
  for (int i = 0; i < 200; i++) {
    uint32_t sticky = reg_read(0x010C);
    if (sticky & 1) {
      ticket = reg_read(0x0110);
      status = (uint16_t)(reg_read(0x0114) & 0xFFFF);
      reg_write(0x010C, 1);
      return;
    }
  }
  std::fprintf(stderr, "timeout waiting for done\n");
  errors++;
  status = 0xFFFF;
  ticket = 0;
}

static void program_region(int q, uint64_t base, uint64_t limit, uint32_t perm) {
  uint16_t b = (uint16_t)(0x0120 + q * 0x20);
  reg_write(b + 0x0, (uint32_t)base);
  reg_write(b + 0x4, (uint32_t)(base >> 32));
  reg_write(b + 0x8, (uint32_t)limit);
  reg_write(b + 0xC, (uint32_t)(limit >> 32));
  reg_write(b + 0x10, perm & 3);
}

// Build little-endian descriptor words matching g6lc_ai_desc_pkg layout
static void load_desc_words(const uint32_t words[16]) {
  for (int i = 0; i < 16; i++)
    reg_write((uint16_t)(0x0140 + i * 4), words[i]);
}

static void make_ok_desc(uint32_t w[16]) {
  for (int i = 0; i < 16; i++)
    w[i] = 0;
  // version=1, op=1 (GEMM)
  w[0] = (1u << 16) | 1u;
  // flags=0
  w[1] = 0;
  // m,n
  w[2] = 8;
  w[3] = 8;
  // k, ld_ab
  w[4] = 8;
  w[5] = 0x00080008u;
  // ptr_a = 0x80010000
  w[6] = 0x80010000u;
  w[7] = 0;
  // ptr_b = 0x80011000
  w[8] = 0x80011000u;
  w[9] = 0;
  // ptr_c = 0x80012000
  w[10] = 0x80012000u;
  w[11] = 0;
  // ptr_scale = 0
  w[12] = 0;
  w[13] = 0;
  // ptr_done = 0x80013000
  w[14] = 0x80013000u;
  w[15] = 0;
}

// Status codes from g6lc_ai_desc_pkg
enum {
  ST_OK = 0,
  ST_BAD_VER = 2,
  ST_BAD_PTR = 4,
  ST_DISABLED = 6
};

static void expect(const char *name, bool ok) {
  if (ok) {
    std::printf("PASS %s\n", name);
  } else {
    std::printf("FAIL %s\n", name);
    errors++;
  }
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  dut = new Vg6lc_ai_island_top;
  cycles = 0;
  errors = 0;

  dut->rst_ni = 0;
  dut->testmode_i = 0;
  dut->req_i = 0;
  dut->we_i = 0;
  dut->addr_i = 0;
  dut->wdata_i = 0;
  dut->sb_enq_valid_i = 0;
  dut->sb_qid_i = 0;
  dut->sb_ticket_i = 0;
  dut->sb_desc_ptr_i = 0;
  // EnableDmaFetch=0 (standalone): AXI ports are 1-bit logic stubs
  dut->axi_dma_resp_i = 0;
  for (int i = 0; i < 5; i++)
    tick();
  dut->rst_ni = 1;
  tick();
  tick();

  // Cap version
  uint32_t r = reg_read(0x0000);
  expect("cap version", (r & 0xFFFF) == 1);

  r = reg_read(0x0004);
  expect("cap clusters non-zero", r != 0);

  // Enable
  reg_write(0x0100, 1);

  // Region q0 [0x80010000, 0x80014000) RW
  program_region(0, 0x80010000ull, 0x80014000ull, 0x3);

  uint32_t desc[16];
  uint16_t st;
  uint32_t ticket;

  // Good descriptor
  make_ok_desc(desc);
  load_desc_words(desc);
  reg_write(0x0108, (10u << 8) | 0); // ticket=10, qid=0
  wait_done(st, ticket);
  expect("good desc", st == ST_OK && ticket == 10);

  // Bad pointer
  make_ok_desc(desc);
  desc[6] = 0x90000000u; // ptr_a outside
  load_desc_words(desc);
  reg_write(0x0108, (11u << 8) | 0);
  wait_done(st, ticket);
  expect("AI-3 bad ptr", st == ST_BAD_PTR);

  // Bad version
  make_ok_desc(desc);
  desc[0] = (1u << 16) | 99u; // version 99, op 1
  // wait - layout is version in [15:0], op in [31:16]
  desc[0] = (1u << 16) | 99u; // op=1, version=99
  load_desc_words(desc);
  reg_write(0x0108, (12u << 8) | 0);
  wait_done(st, ticket);
  expect("bad version", st == ST_BAD_VER);

  // W-only region rejects A read
  program_region(0, 0x80010000ull, 0x80014000ull, 0x2);
  make_ok_desc(desc);
  load_desc_words(desc);
  reg_write(0x0108, (13u << 8) | 0);
  wait_done(st, ticket);
  expect("AI-3 perm reject", st == ST_BAD_PTR);

  // Disabled
  reg_write(0x0100, 0);
  program_region(0, 0x80010000ull, 0x80014000ull, 0x3);
  make_ok_desc(desc);
  load_desc_words(desc);
  reg_write(0x0108, (14u << 8) | 0);
  wait_done(st, ticket);
  expect("disabled", st == ST_DISABLED);

  if (errors == 0) {
    std::printf("*** SUCCESS *** ai-island P3 spine (%llu cycles)\n",
                (unsigned long long)cycles);
    delete dut;
    return 0;
  }
  std::printf("*** FAILED *** %d errors\n", errors);
  delete dut;
  return 1;
}
