// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// C++ driver for tb_g6lc_ai_island_dma.
//
// Two modes:
//   * Default single smoke: one DMA-fetched 8x8x8 GEMM, check ST_OK and
//     non-zero policy PMU words.
//   * Walk mode: +num_jobs=N +job_stride=0x800 +walk_file=walk.hex replays a
//     batch of descriptors from the AXI stub memory and prints per-job and
//     aggregate policy statistics. This is a scheduling-model calibration,
//     not a measured speedup.

#include "Vtb_g6lc_ai_island_dma.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

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
  for (int i = 0; i < 5000; i++) {
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

static std::string plus_value(const char *name) {
  const char *p = Verilated::commandArgsPlusMatch(name);
  if (!p || p[0] == '\0')
    return "";
  // Verilator returns the whole +arg string (e.g. "+num_jobs=18").
  // Skip leading '+', the name, and any '='.
  ++p;  // skip '+'
  size_t n = std::strlen(name);
  if (std::strncmp(p, name, n) != 0)
    return "";
  p += n;
  if (*p == '=')
    ++p;
  if (*p == '\0')
    return "";
  return std::string(p);
}

static void do_reset() {
  dut->rst_ni = 0;
  dut->req = 0;
  dut->we = 0;
  for (int i = 0; i < 10; i++)
    tick();
  dut->rst_ni = 1;
  for (int i = 0; i < 4; i++)
    tick();
}

static void print_snapshot(uint32_t p_code, uint32_t p_word, uint32_t p_topo, uint32_t p_ev) {
  std::printf("  code=0x%08x word=0x%08x topo=0x%08x event=0x%08x\n",
              p_code, p_word, p_topo, p_ev);
}

struct JobResult {
  uint32_t ticket;
  uint16_t status;
  uint32_t code;
  uint32_t word;
  uint32_t topo;
  uint32_t ev;
};

static uint8_t policy_code_from_word(uint32_t p_code) {
  return (uint8_t)((p_code >> 5) & 0x7);
}

static uint8_t next_code_from_word(uint32_t p_code) {
  return (uint8_t)((p_code >> 8) & 0x7);
}

static bool topo_apply(uint32_t p_topo) { return (p_topo >> 22) & 1; }
static bool topo_valid(uint32_t p_topo) { return (p_topo >> 21) & 1; }
static uint8_t topo_gain(uint32_t p_topo) { return (uint8_t)(p_topo & 0xF); }

static void run_walk(int num_jobs, uint32_t job_stride, const char *walk_file) {
  std::vector<JobResult> results;
  results.reserve(num_jobs);

  // Region: full 64 KiB AXI stub memory.
  program_region(0, 0x80010000ULL, 0x80020000ULL, 3);

  for (int i = 0; i < num_jobs; i++) {
    uint64_t desc_ptr = 0x80010000ULL + (uint64_t)i * (uint64_t)job_stride;
    reg_write(0x0118, (uint32_t)desc_ptr);
    reg_write(0x011C, (uint32_t)(desc_ptr >> 32));

    // Doorbell: [31]=fetch, [30:8]=ticket (10+i), [7:0]=qid
    uint32_t ticket = (uint32_t)(10 + i);
    uint32_t doorbell = 0x80000000u | (ticket << 8);
    reg_write(0x0108, doorbell);

    JobResult r;
    wait_done(r.status, r.ticket);

    r.code = reg_read(0x0190);
    r.word = reg_read(0x0194);
    r.topo = reg_read(0x0198);
    r.ev   = reg_read(0x019C);

    std::printf("job[%2d] ticket=%u status=%u", i, r.ticket, r.status);
    print_snapshot(r.code, r.word, r.topo, r.ev);

    if (r.status != 0) {
      std::fprintf(stderr, "job[%d] failed status=%u\n", i, r.status);
      errors++;
    } else if (r.code == 0 && r.word == 0 && r.topo == 0) {
      std::fprintf(stderr, "job[%d] policy snapshots are zero\n", i);
      errors++;
    }

    results.push_back(r);
  }

  // Aggregate usage and modeled scheduling gain.
  unsigned code_count[8] = {};
  unsigned fmt_count[8] = {};
  unsigned ok_jobs = 0;
  unsigned apply_jobs = 0;
  unsigned total_gain = 0;
  for (const auto &r : results) {
    if (r.status != 0)
      continue;
    ok_jobs++;
    code_count[policy_code_from_word(r.code)]++;
    uint8_t fmt = (uint8_t)((r.word >> 0) & 0xFF);
    fmt_count[fmt & 0x7]++;
    if (topo_valid(r.topo) && topo_apply(r.topo)) {
      apply_jobs++;
      total_gain += topo_gain(r.topo);
    }
  }

  std::printf("\n[ai-island-policy-walk] aggregate over %d/%d OK jobs\n", ok_jobs, num_jobs);
  std::printf("policy code usage: ");
  for (int c = 0; c < 8; c++)
    std::printf("code %d: %u (%.1f%%) ", c, code_count[c],
                ok_jobs ? 100.0 * code_count[c] / ok_jobs : 0.0);
  std::printf("\n");
  std::printf("numfmt usage: ");
  for (int f = 0; f < 8; f++)
    std::printf("fmt %d: %u (%.1f%%) ", f, fmt_count[f],
                ok_jobs ? 100.0 * fmt_count[f] / ok_jobs : 0.0);
  std::printf("\n");
  if (apply_jobs) {
    double avg_gain_16ths = (double)total_gain / apply_jobs;
    std::printf("topology applied in %u/%u jobs; average gain_16ths=%.2f\n",
                apply_jobs, ok_jobs, avg_gain_16ths);
    std::printf("modeled improvement (gain/16) = %.2f%%\n", 100.0 * avg_gain_16ths / 16.0);
  } else {
    std::printf("topology never applied\n");
  }
}

static void run_single_smoke() {
  // Region: [0x80010000, 0x80020000), RW
  program_region(0, 0x80010000ULL, 0x80020000ULL, 3);

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
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  dut = new Vtb_g6lc_ai_island_dma;

  do_reset();

  // Capability sanity
  uint32_t cap = reg_read(0x0000);
  if ((cap & 0xFFFF) != 1) {
    std::fprintf(stderr, "cap version mismatch: %u\n", cap & 0xFFFF);
    errors++;
  }

  // Enable
  reg_write(0x0100, 1);

  std::string num_jobs_s = plus_value("num_jobs");
  std::string job_stride_s = plus_value("job_stride");
  std::string walk_file_s = plus_value("walk_file");

  if (!num_jobs_s.empty() && !job_stride_s.empty() && !walk_file_s.empty()) {
    int num_jobs = std::atoi(num_jobs_s.c_str());
    uint32_t job_stride = (uint32_t)std::strtoul(job_stride_s.c_str(), nullptr, 0);
    std::printf("[ai-island-dma] walk mode: num_jobs=%d stride=0x%x file=%s\n",
                num_jobs, job_stride, walk_file_s.c_str());
    run_walk(num_jobs, job_stride, walk_file_s.c_str());
  } else {
    run_single_smoke();
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
  std::printf("*** SUCCESS *** ai-island DMA (%lu cycles)\n", cycles);
  return 0;
}
