// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at

//   http://www.apache.org/licenses/LICENSE-2.0

// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

#include "verilator.h"
#include "verilated.h"
#include "Variane_testharness.h"
#if (VERILATOR_VERSION_INTEGER >= 5000000)
  // Verilator v5 adds $root wrapper that provides rootp pointer.
  #include "Variane_testharness___024root.h"
#endif
#if VM_TRACE_FST
#include "verilated_fst_c.h"
#else
#include "verilated_vcd_c.h"
#endif
#include "Variane_testharness__Dpi.h"

// Define CVA6_PROBE_NO_L2=1 without gen_l2; CVA6_PROBE_NO_CORE1 without core1.
#include <stdio.h>
#include <iostream>
#include <iomanip>
#include <string>
#include <getopt.h>
#include <chrono>
#include <ctime>
#include <signal.h>
#include <unistd.h>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <vector>

#include <fesvr/dtm.h>
#include <fesvr/htif_hexwriter.h>
#include <fesvr/elfloader.h>
#include "remote_bitbang.h"

// This software is heavily based on Rocket Chip
// Checkout this awesome project:
// https://github.com/freechipsproject/rocket-chip/


// This is a 64-bit integer to reduce wrap over issues and
// allow modulus.  You can also use a double, if you wish.
static vluint64_t main_time = 0;

// Plusargs consumed by RTL/SV ($value$plusargs) — must be allowlisted so HTIF
// does not reject them. Use +permissive…+permissive-off if you need more.
static const char *verilog_plusargs[] = {
    "jtag_rbb_enable", "time_out", "debug_disable", "tohost_addr", "elf_file", nullptr};

extern dtm_t* dtm;
extern remote_bitbang_t * jtag;

void handle_sigterm(int sig) {
  dtm->stop();
}


extern "C" void read_elf(const char* filename);
extern "C" char get_section (long long* address, long long* len);
extern "C" void read_section_void(long long address, void * buffer, uint64_t size = 0);

// Called by $time in Verilog converts to double, to match what SystemC does
double sc_time_stamp () {
    return main_time;
}

static void usage(const char * program_name) {
  printf("Usage: %s [EMULATOR OPTION]... [VERILOG PLUSARG]... [HOST OPTION]... BINARY [TARGET OPTION]...\n",
         program_name);
  fputs("\
Run a BINARY on the Ariane emulator.\n\
\n\
Mandatory arguments to long options are mandatory for short options too.\n\
\n\
EMULATOR OPTIONS\n\
  -r, --rbb-port=PORT      Use PORT for remote bit bang (with OpenOCD and GDB) \n\
                           If not specified, a random port will be chosen\n\
                           automatically.\n\
", stdout);
#if VM_TRACE == 0
  fputs("\
\n\
EMULATOR DEBUG OPTIONS (only supported in debug build -- try `make debug`)\n",
        stdout);
#endif
  fputs("\
  -v, --vcd=FILE,          Write vcd trace to FILE (or '-' for stdout)\n\
  -f, --fst=FILE,          Write fst trace to FILE\n\
  -p,                      Print performance statistic at end of test\n\
", stdout);
  // fputs("\n" PLUSARG_USAGE_OPTIONS, stdout);
  fputs("\n" HTIF_USAGE_OPTIONS, stdout);
  printf("\n"
"EXAMPLES\n"
"  - run a bare metal test:\n"
"    %s $RISCV/riscv64-unknown-elf/share/riscv-tests/isa/rv64ui-p-add\n"
"  - run a bare metal test showing cycle-by-cycle information:\n"
"    %s spike-dasm < trace_core_00_0.dasm > trace.out\n"
#if VM_TRACE
"  - run a bare metal test to generate a VCD waveform:\n"
"    %s -v rv64ui-p-add.vcd $RISCV/riscv64-unknown-elf/share/riscv-tests/isa/rv64ui-p-add\n"
"  - run a bare metal test to generate an FST waveform:\n"
"    %s -f rv64ui-p-add.fst $RISCV/riscv64-unknown-elf/share/riscv-tests/isa/rv64ui-p-add\n"
#endif
  , program_name, program_name);
}

// In case we use the DTM we do not want to use the JTAG
// to preload the data but only use the DTM to host fesvr functionality.
class preload_aware_dtm_t : public dtm_t {
  public:
    preload_aware_dtm_t(int argc, char **argv) : dtm_t(argc, argv) {}
    bool is_address_preloaded(addr_t taddr, size_t len) override { return true; }
    // We do not want to reset the hart here as the reset function in `dtm_t` seems to disregard
    // the privilege level and in general does not perform proper reset (despite the name).
    // As all our binaries in preloading will always start at the base of DRAM this should not
    // be such a big problem.
    void reset() {}
};

int main(int argc, char **argv) {
  std::clock_t c_start = std::clock();
  auto t_start = std::chrono::high_resolution_clock::now();
  bool verbose;
  bool perf;
  unsigned random_seed = (unsigned)time(NULL) ^ (unsigned)getpid();
  uint64_t max_cycles = -1;
  int ret = 0;
  bool print_cycles = false;
  // Port numbers are 16 bit unsigned integers.
  uint16_t rbb_port = 0;
#if VM_TRACE
  FILE * vcdfile = NULL;
  char * fst_fname = NULL;
  uint64_t start = 0;
#endif
  char ** htif_argv = NULL;
  int verilog_plusargs_legal = 1;

  while (1) {
    static struct option long_options[] = {
      {"cycle-count", no_argument,       0, 'c' },
      {"help",        no_argument,       0, 'h' },
      {"max-cycles",  required_argument, 0, 'm' },
      {"seed",        required_argument, 0, 's' },
      {"rbb-port",    required_argument, 0, 'r' },
      {"verbose",     no_argument,       0, 'V' },
#if VM_TRACE
      {"vcd",         required_argument, 0, 'v' },
      {"dump-start",  required_argument, 0, 'x' },
      {"fst",         required_argument, 0, 'f' },
#endif
      HTIF_LONG_OPTIONS
    };
    int option_index = 0;
#if VM_TRACE
    int c = getopt_long(argc, argv, "-chpm:s:r:v:f:Vx:", long_options, &option_index);
#else
    int c = getopt_long(argc, argv, "-chpm:s:r:V", long_options, &option_index);
#endif
    if (c == -1) break;
 retry:
    switch (c) {
      // Process long and short EMULATOR options
      case '?': usage(argv[0]);             return 1;
      case 'c': print_cycles = true;        break;
      case 'h': usage(argv[0]);             return 0;
      case 'm': max_cycles = atoll(optarg); break;
      case 's': random_seed = atoi(optarg); break;
      case 'r': rbb_port = atoi(optarg);    break;
      case 'V': verbose = true;             break;
      case 'p': perf = true;                break;
#if VM_TRACE
      case 'v': {
        vcdfile = strcmp(optarg, "-") == 0 ? stdout : fopen(optarg, "w");
        if (!vcdfile) {
          std::cerr << "Unable to open " << optarg << " for VCD write\n";
          return 1;
        }
        break;
      }
      case 'f': {
        fst_fname = optarg;
        break;
      }
      case 'x': start = atoll(optarg);      break;
#endif
      // Process legacy '+' EMULATOR arguments by replacing them with
      // their getopt equivalents
      case 1: {
        std::string arg = optarg;
        if (arg.substr(0, 1) != "+") {
          optind--;
          goto done_processing;
        }
        if (arg == "+verbose")
          c = 'V';
        else if (arg.substr(0, 12) == "+max-cycles=") {
          c = 'm';
          optarg = optarg+12;
        }
#if VM_TRACE
        else if (arg.substr(0, 12) == "+dump-start=") {
          c = 'x';
          optarg = optarg+12;
        }
#endif
        else if (arg.substr(0, 12) == "+cycle-count")
          c = 'c';
        // If we don't find a legacy '+' EMULATOR argument, it still could be
        // a VERILOG_PLUSARG and not an error.
        else if (verilog_plusargs_legal) {
          const char ** plusarg = &verilog_plusargs[0];
          int legal_verilog_plusarg = 0;
          while (*plusarg && (legal_verilog_plusarg == 0)){
            if (arg.substr(1, strlen(*plusarg)) == *plusarg) {
              legal_verilog_plusarg = 1;
            }
            plusarg ++;
          }
          if (!legal_verilog_plusarg) {
            verilog_plusargs_legal = 0;
          } else {
            c = 'P';
          }
          goto retry;
        }
        // If we STILL don't find a legacy '+' argument, it still could be
        // an HTIF (HOST) argument and not an error. If this is the case, then
        // we're done processing EMULATOR and VERILOG arguments.
        else {
          static struct option htif_long_options [] = { HTIF_LONG_OPTIONS };
          struct option * htif_option = &htif_long_options[0];
          while (htif_option->name) {
            if (arg.substr(1, strlen(htif_option->name)) == htif_option->name) {
              optind--;
              goto done_processing;
            }
            htif_option++;
          }
          std::cerr << argv[0] << ": invalid plus-arg (Verilog or HTIF) \""
                    << arg << "\"\n";
          c = '?';
        }
        goto retry;
      }
      case 'P': break; // Nothing to do here, Verilog PlusArg
      // Realize that we've hit HTIF (HOST) arguments or error out
      default:
        if (c >= HTIF_LONG_OPTIONS_OPTIND) {
          optind--;
          goto done_processing;
        }
        c = '?';
        goto retry;
    }
  }

done_processing:
  if (optind == argc) {
    std::cerr << "No binary specified for emulator\n";
    usage(argv[0]);
    return 1;
  }
  int htif_argc = 1 + argc - optind;
  htif_argv = (char **) malloc((htif_argc) * sizeof (char *));
  htif_argv[0] = argv[0];
  for (int i = 1; optind < argc;) htif_argv[i++] = argv[optind++];

  const char *vcd_file = NULL;
  Verilated::commandArgs(argc, argv);

  jtag = new remote_bitbang_t(rbb_port);
  dtm = new preload_aware_dtm_t(htif_argc, htif_argv);
  signal(SIGTERM, handle_sigterm);

  std::unique_ptr<Variane_testharness> top(new Variane_testharness);

  read_elf(htif_argv[1]);

#if VM_TRACE
  Verilated::traceEverOn(true); // Verilator must compute traced signals
#if VM_TRACE_FST
  std::unique_ptr<VerilatedFstC> tfp(new VerilatedFstC());
  if (fst_fname) {
    std::cerr << "Starting FST waveform dump into file '" << fst_fname << "'...\n";
    top->trace(tfp.get(), 99);  // Trace 99 levels of hierarchy
    tfp->open(fst_fname);
  }
  else
    std::cerr << "No explicit FST file name supplied, using RTL defaults.\n";
#else
  std::unique_ptr<VerilatedVcdFILE> vcdfd(new VerilatedVcdFILE(vcdfile));
  std::unique_ptr<VerilatedVcdC> tfp(new VerilatedVcdC(vcdfd.get()));
  if (vcdfile) {
    std::cerr << "Starting VCD waveform dump ...\n";
    top->trace(tfp.get(), 99);  // Trace 99 levels of hierarchy
    tfp->open("");
  }
  else
    std::cerr << "No explicit VCD file name supplied, using RTL defaults.\n";
#endif
#endif

  for (int i = 0; i < 10; i++) {
    top->rst_ni = 0;
    top->clk_i = 0;
    top->rtc_i = 0;
    top->eval();
#if VM_TRACE
    if (vcdfile || fst_fname)
      tfp->dump(static_cast<vluint64_t>(main_time * 2));
#endif
    top->clk_i = 1;
    top->eval();
#if VM_TRACE
    if (vcdfile || fst_fname)
      tfp->dump(static_cast<vluint64_t>(main_time * 2 + 1));
#endif
    main_time++;
  }
  top->rst_ni = 1;

  // Preload memory.
#if (VERILATOR_VERSION_INTEGER >= 5000000)
  // Verilator v5: Use rootp pointer and .data() accessor.
#define MEM top->rootp->ariane_testharness__DOT__i_sram__DOT__gen_cut__BRA__0__KET____DOT__i_tc_sram_wrapper__DOT__i_tc_sram__DOT__sram.m_storage
#define MEM_USER top->rootp->ariane_testharness__DOT__i_sram__DOT__gen_cut__BRA__0__KET____DOT__gen_mem_user__DOT__i_tc_sram_wrapper_user__DOT__i_tc_sram__DOT__sram.m_storage
#else
  // Verilator v4
#define MEM top->ariane_testharness__DOT__i_sram__DOT__gen_cut__BRA__0__KET____DOT__i_tc_sram_wrapper__DOT__i_tc_sram__DOT__sram
#define MEM_USER top->ariane_testharness__DOT__i_sram__DOT__gen_cut__BRA__0__KET____DOT__gen_mem_user__DOT__i_tc_sram_wrapper_user__DOT__i_tc_sram__DOT__sram
#endif
  long long addr;
  long long len;

  // DRAM preload into the Verilator SRAM model.
  // 1) Bulk memif read from DRAM base (covers the full load_elf image when the
  //    first program header is at 0x8000_0000).
  // 2) Per-section copies for PHDRs inside DRAM (crt vs .text/.tohost split).
  // 3) PHDRs that *start below* DRAM but overlap it (mini_tohost links .text at
  //    0x80000000 inside a LOAD that begins at 0x7ffff000). fesvr only accepts
  //    exact PHDR addresses for read_section_void — read whole section then copy.
  const uint64_t dram_base = 0x80000000ULL;
  const uint64_t dram_user = 0x84000000ULL;
  size_t mem_size = 0xFFFFFF;
  bool bulk_done = false;
  while (get_section(&addr, &len)) {
    if (!bulk_done && addr == (long long)dram_base) {
      read_section_void(addr, (void *)MEM, mem_size);
      bulk_done = true;
    } else if (len > 0) {
      const uint64_t a = (uint64_t)addr;
      const uint64_t e = a + (uint64_t)len;
      const uint64_t d0 = dram_base;
      const uint64_t d1 = dram_base + (uint64_t)mem_size;
      if (a < d1 && e > d0) {
        const uint64_t start = (a > d0) ? a : d0;
        const uint64_t end = (e < d1) ? e : d1;
        const size_t n = (size_t)(end - start);
        if (n > 0) {
          if (a >= d0 && a < d1) {
            // PHDR base is inside DRAM — direct copy (historical path).
            const size_t off = (size_t)(a - d0);
            size_t ncopy = (size_t)len;
            if (off + ncopy > mem_size) ncopy = mem_size - off;
            read_section_void(addr, (void *)((uint8_t *)MEM + off), ncopy);
          } else {
            // PHDR starts below DRAM — stage then slice the overlap.
            std::vector<uint8_t> tmp((size_t)len);
            read_section_void(addr, tmp.data(), (uint64_t)len);
            const size_t src_off = (size_t)(start - a);
            const size_t dst_off = (size_t)(start - d0);
            std::memcpy((uint8_t *)MEM + dst_off, tmp.data() + src_off, n);
            std::cerr << std::hex << "[preload] PHDR@0x" << a
                      << " overlap DRAM +0x" << dst_off << " n=0x" << n
                      << std::dec << "\n";
          }
        }
      }
    }
    if (addr == (long long)dram_user) {
      try {
        read_section_void(addr, (void *)MEM_USER, mem_size);
      } catch (...) {
        std::cerr << "No user memory instantiated ...\n";
      }
    }
  }

  // Optional mid-run MEM probe (set env CVA6_PRELOAD_PROBE=1)
  const bool probe = (std::getenv("CVA6_PRELOAD_PROBE") != nullptr);
  auto mem_half = [&](size_t off) -> uint16_t {
    auto *bytes = reinterpret_cast<const uint8_t *>(MEM);
    return (uint16_t)bytes[off] | ((uint16_t)bytes[off + 1] << 8);
  };
  // Always report FDT magic after preload (hang-6: fw_fdt_bin @ 0x8001e000).
  {
    auto *bytes = reinterpret_cast<const uint8_t *>(MEM);
    const size_t fdt_off = 0x1e000;
    uint32_t b0 = bytes[fdt_off], b1 = bytes[fdt_off + 1], b2 = bytes[fdt_off + 2],
             b3 = bytes[fdt_off + 3];
    uint32_t mag_be = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3;
    std::cerr << std::hex << "[preload] FDT@0x1e000 magic_be=0x" << mag_be
              << " bytes=" << b0 << " " << b1 << " " << b2 << " " << b3
              << std::dec << "\n";
  }
  if (probe) {
    // Handy CRT offsets in mc_spo_* images (DRAM-relative)
    std::cerr << std::hex << "[preload] pre-run"
              << " [0]=0x" << mem_half(0)
              << " [0x3f40]=0x" << mem_half(0x3f40)
              << " [0x403c]=0x" << mem_half(0x403c)
              << " [0x3000]=0x" << mem_half(0x3000)
              << " [0x1000]=0x" << mem_half(0x1000)
              << std::dec << "\n";
  }

  while (!dtm->done() && !jtag->done() && !(top->exit_o & 0x1)) {
    top->clk_i = 0;
    top->eval();
#if VM_TRACE
    if (vcdfile || fst_fname)
      tfp->dump(static_cast<vluint64_t>(main_time * 2));
#endif

    top->clk_i = 1;
    top->eval();
#if VM_TRACE
    if (vcdfile || fst_fname)
      tfp->dump(static_cast<vluint64_t>(main_time * 2 + 1));
#endif
    // toggle RTC
    if (main_time % 2 == 0) {
      top->rtc_i ^= 1;
    }
    main_time++;
    if (probe && main_time == 500) {
      std::cerr << std::hex << "[preload] @500"
                << " MEM[0]=0x" << mem_half(0)
                << " MEM[0x884]=0x" << mem_half(0x884)
                << " MEM[0x886]=0x" << mem_half(0x886)
                << std::dec << "\n";
    }
    // Hang-7 event probe (every cycle, capped): use COMMIT PC (not npc) so RF
    // matches retired state. Also filter mentry to alias-shaped calls.
    // Compile-time gated: hierarchical paths depend on multi-core/L2/HPD layout
    // and break default cv64a6_imafdc_sv39 smoke (g6lc_icache, NrCores=1).
    // Enable with: make verilate CFLAGS+="-DCVA6_MC_PC_PROBE_COMPILE=1"
#if defined(CVA6_MC_PC_PROBE_COMPILE) && (VERILATOR_VERSION_INTEGER >= 5000000)
    if (std::getenv("CVA6_MC_PC_PROBE") != nullptr && main_time >= 10000 && main_time <= 400000) {
      static int path0_logs = 0;
      static int mentry_logs = 0;
      static int alias_logs = 0;
      // Commit-head PC from scoreboard (same bit extract as mc_pc cpc)
      const auto &ci_ev = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__0__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__issue_stage_i__DOT____Vcellout__i_scoreboard__commit_instr_o;
      auto bit_ev = [&](int b) -> unsigned {
        return (ci_ev[b / 32] >> (b % 32)) & 1u;
      };
      uint64_t cpc_ev = 0;
      for (int i = 0; i < 64; i++) {
        if (bit_ev(401 + i)) cpc_ev |= (uint64_t)1 << i;
      }
      auto cack_ev = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__0__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__commit_ack;
      const auto &rf_ev = top->rootp
          ->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__0__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__issue_stage_i__DOT__i_issue_read_operands__DOT__gen_asic_regfile__DOT__i_ariane_regfile__DOT__gen_single_bank__DOT__i_rf__DOT__mem;
      auto ge = [&](int n) -> uint64_t {
        return (uint64_t)rf_ev[2 * n] | ((uint64_t)rf_ev[2 * n + 1] << 32);
      };
      // Only log when something is actually committing
      bool committing = ((unsigned)cack_ev) != 0;
      // fdt_path_offset_namelen: lbu@0x8001370a, li a1@0x8001370e, bne@0x80013718
      if (committing && cpc_ev >= 0x8001370aULL && cpc_ev <= 0x80013720ULL && path0_logs < 60) {
        auto *b = reinterpret_cast<const uint8_t *>(MEM);
        uint64_t s1 = ge(9);
        uint8_t dram_b = (s1 >= 0x80000000ULL && s1 < 0x80200000ULL)
                             ? b[(size_t)(s1 - 0x80000000ULL)]
                             : 0xff;
        std::cerr << std::hex << "[path0c] @" << main_time << " cpc=0x" << cpc_ev
                  << " a5=0x" << ge(15) << " a1=0x" << ge(11) << " s1=0x" << s1
                  << " s3=0x" << ge(19) << " dram_b=0x" << (unsigned)dram_b
                  << " slash_ok=" << (((ge(15) & 0xff) == 0x2f) ? 1 : 0)
                  << " a1_slash=" << (((ge(11) & 0xff) == 0x2f) ? 1 : 0)
                  << std::dec << "\n";
        path0_logs++;
      }
      // Alias memchr entry only (ra will be 0x80013788 after jal; at entry of
      // memchr ra is already the return). Also late window / small a0.
      uint64_t ra_ev = ge(1), a0_ev = ge(10), a1_ev = ge(11), a2_ev = ge(12);
      bool alias_shaped = (ra_ev == 0x80013788ULL) || (a0_ev < 0x10000ULL && main_time > 100000);
      if (committing && cpc_ev >= 0x80004be4ULL && cpc_ev <= 0x80004bf6ULL &&
          (alias_shaped || main_time > 120000) && mentry_logs < 80) {
        std::cerr << std::hex << "[mentryc] @" << main_time << " cpc=0x" << cpc_ev
                  << " a0=0x" << a0_ev << " a1=0x" << a1_ev << " a2=0x" << a2_ev
                  << " ra=0x" << ra_ev << " s1=0x" << ge(9) << " s3=0x" << ge(19)
                  << std::dec << "\n";
        mentry_logs++;
      }
      // One-shot when we first see alias memchr active (npc in loop + ra)
      auto npc_ev = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__0__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__i_frontend__DOT__npc_q;
      uint64_t np = (uint64_t)npc_ev;
      if (alias_logs < 5 && ra_ev == 0x80013788ULL &&
          np >= 0x80004be4ULL && np < 0x80004c1aULL &&
          (a0_ev < 0x10000ULL || a0_ev >= 0xffffffffffffff00ULL)) {
        std::cerr << std::hex << "[alias_hang] @" << main_time << " npc=0x" << np
                  << " cpc=0x" << cpc_ev << " a0=0x" << a0_ev << " a1=0x" << a1_ev
                  << " a2=0x" << a2_ev << " a5=0x" << ge(15) << " s1=0x" << ge(9)
                  << " s2=0x" << ge(18) << " s3=0x" << ge(19) << " ra=0x" << ra_ev
                  << std::dec << "\n";
        alias_logs++;
      }
      // Alias setup + post-subnode bltz: 0x8001375e–0x80013790
      static int aset_logs = 0;
      if (committing && cpc_ev >= 0x8001375eULL && cpc_ev <= 0x80013790ULL &&
          aset_logs < 60) {
        std::cerr << std::hex << "[alias_setup] @" << main_time << " cpc=0x" << cpc_ev
                  << " a0=0x" << a0_ev << " a1=0x" << a1_ev << " a2=0x" << a2_ev
                  << " a5=0x" << ge(15) << " s1=0x" << ge(9) << " s3=0x" << ge(19)
                  << " s4=0x" << ge(20) << " s5=0x" << ge(21) << " s6=0x" << ge(22)
                  << " ra=0x" << ra_ev
                  << std::dec << "\n";
        aset_logs++;
      }
      // fdt_next_node / next_tag body when producing errors or late walk
      static int ntag_logs = 0;
      if (committing && ntag_logs < 40 &&
          cpc_ev >= 0x80012ae6ULL && cpc_ev <= 0x80012b80ULL &&
          main_time >= 130000) {
        std::cerr << std::hex << "[next_node] @" << main_time << " cpc=0x" << cpc_ev
                  << " a0=0x" << a0_ev << " a1=0x" << a1_ev << " a2=0x" << a2_ev
                  << " a5=0x" << ge(15) << " s1=0x" << ge(9) << " ra=0x" << ra_ev
                  << std::dec << "\n";
        ntag_logs++;
      }
      // Hang-6 residual: next_node/next_tag path around /cpus walk.
      // Prior run: all tag loads match DRAM; failing next_node(0x64) returns
      // -4 in ~49 cycles with no next_tag probe — check entry args + BAD path.
      static int ntag_ent = 0;
      static int ntag_ret = 0;
      static int ntag_ld = 0;
      static int optr_null = 0;
      static int nn_ent = 0;
      static int nn_bad = 0;
      static int nn_chk = 0;
      auto *dram = reinterpret_cast<const uint8_t *>(MEM);
      auto be32_at = [&](uint64_t abs) -> uint32_t {
        if (abs < 0x80000000ULL || abs + 4 > 0x80200000ULL) return 0xffffffffu;
        size_t o = (size_t)(abs - 0x80000000ULL);
        return ((uint32_t)dram[o] << 24) | ((uint32_t)dram[o + 1] << 16) |
               ((uint32_t)dram[o + 2] << 8) | (uint32_t)dram[o + 3];
      };
      const uint64_t fdt_base = 0x8001e000ULL;
      const uint32_t off_struct = 0x38;
      if (committing && main_time >= 130000 && main_time <= 160000) {
        // next_node entry @0x80012ae6: a0=fdt a1=offset a2=&depth
        if (cpc_ev == 0x80012ae6ULL && nn_ent < 40) {
          int32_t depth = -999;
          if (a2_ev >= 0x80000000ULL && a2_ev + 4 <= 0x80200000ULL) {
            // depth is stack (often near 0x80046e00) — still in DRAM window
            size_t o = (size_t)(a2_ev - 0x80000000ULL);
            depth = (int32_t)(dram[o] | (dram[o + 1] << 8) | (dram[o + 2] << 16) |
                              (dram[o + 3] << 24));
          } else if (a2_ev >= 0x80040000ULL && a2_ev < 0x80050000ULL) {
            size_t o = (size_t)(a2_ev - 0x80000000ULL);
            depth = (int32_t)(dram[o] | (dram[o + 1] << 8) | (dram[o + 2] << 16) |
                              (dram[o + 3] << 24));
          }
          uint32_t golden = be32_at(fdt_base + off_struct + (uint32_t)a1_ev);
          std::cerr << std::hex << "[nn_e] @" << main_time
                    << " off=0x" << a1_ev << " fdt=0x" << a0_ev
                    << " depth_p=0x" << a2_ev << " depth=" << std::dec << depth
                    << std::hex << " dram_tag=0x" << golden
                    << " ra=0x" << ra_ev << std::dec << "\n";
          nn_ent++;
        }
        // next_node after first next_tag: @0x80012b0e li a5,1 — a0 should be tag
        if (cpc_ev == 0x80012b0eULL && nn_chk < 40) {
          std::cerr << std::hex << "[nn_chk] @" << main_time
                    << " tag_a0=0x" << a0_ev << " a1=0x" << a1_ev
                    << " s1=0x" << ge(9) << " ra=0x" << ra_ev
                    << std::dec << "\n";
          nn_chk++;
        }
        // BADOFFSET path @0x80012bc8: li s1,-4
        if (cpc_ev == 0x80012bc8ULL && nn_bad < 20) {
          std::cerr << std::hex << "[nn_bad] @" << main_time
                    << " a0=0x" << a0_ev << " a1=0x" << a1_ev
                    << " a5=0x" << ge(15) << " s1=0x" << ge(9)
                    << " s3=0x" << ge(19) << " ra=0x" << ra_ev
                    << std::dec << "\n";
          nn_bad++;
        }
        // Range catch: any commit in next_node during late fail window
        static int nn_body = 0;
        if (nn_body < 60 && main_time >= 140000 &&
            cpc_ev >= 0x80012ae6ULL && cpc_ev <= 0x80012bcaULL) {
          std::cerr << std::hex << "[nn_b] @" << main_time << " cpc=0x" << cpc_ev
                    << " a0=0x" << a0_ev << " a1=0x" << a1_ev << " a2=0x" << a2_ev
                    << " a5=0x" << ge(15) << " s1=0x" << ge(9) << " s2=0x" << ge(18)
                    << " ra=0x" << ra_ev << std::dec << "\n";
          nn_body++;
        }
        // next_tag entry: a0=fdt a1=offset a2=&nextoffset
        if (cpc_ev == 0x80012944ULL && ntag_ent < 80) {
          uint32_t golden = be32_at(fdt_base + off_struct + (uint32_t)a1_ev);
          std::cerr << std::hex << "[ntag_e] @" << main_time
                    << " off=0x" << a1_ev << " fdt=0x" << a0_ev
                    << " dram_tag=0x" << golden << " ra=0x" << ra_ev
                    << std::dec << "\n";
          ntag_ent++;
        }
        // After BE-tag assembly @0x8001299e (li a5,9): s2 holds BE tag
        if (cpc_ev == 0x8001299eULL && ntag_ld < 100) {
          uint32_t be = (uint32_t)ge(18); // s2
          uint32_t off = (uint32_t)ge(21); // s5
          uint32_t golden = be32_at(fdt_base + off_struct + off);
          std::cerr << std::hex << "[ntag_ld] @" << main_time
                    << " off=0x" << off << " cpu_tag=0x" << be
                    << " dram_tag=0x" << golden
                    << " match=" << (be == golden ? 1 : 0)
                    << " a0_ptr=0x" << a0_ev << " ra=0x" << ra_ev
                    << std::dec << "\n";
          ntag_ld++;
        }
        // next_tag return: mv a0,s2 @0x800129dc
        if (cpc_ev == 0x800129dcULL && ntag_ret < 100) {
          std::cerr << std::hex << "[ntag_r] @" << main_time
                    << " tag=0x" << a0_ev << " s2=0x" << ge(18)
                    << " s5_off=0x" << ge(21)
                    << " s1_nex=0x" << ge(9) << " ra=0x" << ra_ev
                    << std::dec << "\n";
          ntag_ret++;
        }
        // offset_ptr returning NULL (a0==0 at ret 0x80012942)
        if (cpc_ev == 0x80012942ULL && a0_ev == 0 && optr_null < 40) {
          std::cerr << std::hex << "[optr_null] @" << main_time
                    << " a0=0 a1=0x" << a1_ev << " a2=0x" << a2_ev
                    << " ra=0x" << ra_ev << " s4=0x" << ge(20)
                    << " s5=0x" << ge(21)
                    << std::dec << "\n";
          optr_null++;
        }
      }
      // Any commit that produces a0 = FDT_ERR_BADOFFSET (-4) in fdt / platform code
      static int bad4_logs = 0;
      static uint64_t last_a0 = 0;
      if (committing && bad4_logs < 30 && a0_ev == 0xfffffffffffffffcULL &&
          last_a0 != a0_ev &&
          ((cpc_ev >= 0x80012000ULL && cpc_ev < 0x80014000ULL) ||
           (cpc_ev >= 0x80007200ULL && cpc_ev < 0x80007600ULL) ||
           (cpc_ev >= 0x80004b00ULL && cpc_ev < 0x80004c40ULL))) {
        std::cerr << std::hex << "[a0_bad4] @" << main_time << " cpc=0x" << cpc_ev
                  << " a0=0x" << a0_ev << " a1=0x" << a1_ev << " a2=0x" << a2_ev
                  << " s1=0x" << ge(9) << " s3=0x" << ge(19) << " ra=0x" << ra_ev
                  << std::dec << "\n";
        bad4_logs++;
      }
      last_a0 = a0_ev;
      // fdt_subnode / get_name / next_node returns (negative a0)
      static int fdtret_logs = 0;
      if (committing && fdtret_logs < 40 &&
          (int64_t)a0_ev < 0 && (int64_t)a0_ev > -32 &&
          cpc_ev >= 0x80013200ULL && cpc_ev < 0x80013600ULL) {
        std::cerr << std::hex << "[fdt_ret] @" << main_time << " cpc=0x" << cpc_ev
                  << " a0=0x" << a0_ev << " a1=0x" << a1_ev << " s1=0x" << ge(9)
                  << " ra=0x" << ra_ev << std::dec << "\n";
        fdtret_logs++;
      }
      // Hang-6: EX resolve of jal fdt_next_tag @0x80012b0a — did is_mispredict fire?
      static int jal_ex_logs = 0;
      if (jal_ex_logs < 20 && main_time >= 130000 && main_time <= 160000) {
        auto &rbj = top->rootp
            ->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__0__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__ex_stage_i__DOT____Vcellout__branch_unit_i__resolved_branch_o;
        auto rbj_bit = [&](int b) -> unsigned {
          return (rbj[b / 32] >> (b % 32)) & 1u;
        };
        auto rbj_bits = [&](int lo, int n) -> uint64_t {
          uint64_t v = 0;
          for (int i = 0; i < n; i++)
            if (rbj_bit(lo + i)) v |= (uint64_t)1 << i;
          return v;
        };
        uint64_t jpc = rbj_bits(71, 64);
        unsigned jv = rbj_bit(135);
        if (jv && jpc == 0x80012b0aULL) {
          std::cerr << std::hex << "[jal_ex] @" << main_time
                    << " pc=0x" << jpc << " tgt=0x" << rbj_bits(7, 64)
                    << " misp=" << rbj_bit(6) << " taken=" << rbj_bit(5)
                    << " cf=" << rbj_bits(2, 3) << " ckpt=" << rbj_bit(0)
                    << std::dec << "\n";
          jal_ex_logs++;
        }
      }
      // Hang-7: EX resolve of path_offset ret (0x8001377e) / nearby CF —
      // compare predict vs architectural target and whether bmiss fires.
      // bp_resolve packing (MSB first): valid[135], pc[134:71], target[70:7],
      // misp[6], taken[5], cf[4:2], hart[1], ckpt_restore[0].
      // branchpredict_sbe: cf[66:64], predict_address[63:0].
      static int retex_logs = 0;
      auto &rb = top->rootp
          ->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__0__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__ex_stage_i__DOT____Vcellout__branch_unit_i__resolved_branch_o;
      auto rb_bit = [&](int b) -> unsigned {
        return (rb[b / 32] >> (b % 32)) & 1u;
      };
      auto rb_bits = [&](int lo, int n) -> uint64_t {
        uint64_t v = 0;
        for (int i = 0; i < n; i++)
          if (rb_bit(lo + i)) v |= (uint64_t)1 << i;
        return v;
      };
      uint64_t rb_pc = rb_bits(71, 64);
      uint64_t rb_tgt = rb_bits(7, 64);
      unsigned rb_valid = rb_bit(135);
      unsigned rb_misp = rb_bit(6);
      unsigned rb_taken = rb_bit(5);
      unsigned rb_cf = (unsigned)rb_bits(2, 3);
      unsigned rb_ckpt = rb_bit(0);
      auto bv_q = top->rootp
          ->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__0__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__issue_stage_i__DOT__i_issue_read_operands__DOT__branch_valid_q;
      auto pc_ex = (uint64_t)top->rootp
          ->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__0__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__pc_id_ex;
      auto &bpv = top->rootp
          ->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__0__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__issue_stage_i__DOT____Vcellout__i_issue_read_operands__branch_predict_o;
      // predict_address is low 64 of 67-bit sbe
      uint64_t bp_pred = (uint64_t)bpv[0] | (((uint64_t)bpv[1] & 0xffffffffULL) << 32);
      // cf in bits 66:64 → bit 2 of bpv[2]
      unsigned bp_cf = (bpv[2] >> 0) & 0x7u;
      bool ret_window =
          (pc_ex == 0x8001377eULL) || (rb_valid && rb_pc == 0x8001377eULL) ||
          (pc_ex >= 0x8001376eULL && pc_ex <= 0x80013790ULL && (unsigned)bv_q);
      if (retex_logs < 40 && ret_window &&
          (rb_valid || (unsigned)bv_q) && main_time >= 100000) {
        std::cerr << std::hex << "[ret_ex] @" << main_time
                  << " pc_ex=0x" << pc_ex << " bv=" << (unsigned)bv_q
                  << " rb_v=" << rb_valid << " rb_pc=0x" << rb_pc
                  << " tgt=0x" << rb_tgt << " misp=" << rb_misp
                  << " taken=" << rb_taken << " cf=" << rb_cf
                  << " ckpt=" << rb_ckpt << " bp_pred=0x" << bp_pred
                  << " bp_cf=" << bp_cf << " ra=0x" << ra_ev
                  << " match_ra=" << ((rb_tgt == ra_ev) ? 1 : 0)
                  << " match_pred=" << ((rb_tgt == bp_pred) ? 1 : 0)
                  << std::dec << "\n";
        retex_logs++;
      }
    }
#endif
    // Multi-core hang probe: PC + I$/L2/hub/ROM/DRAM (set CVA6_MC_PC_PROBE=1).
    // Dense early samples catch L2/AMO hangs; late samples track OpenSBI progress
    // (historical SUCCESS ~6.5M cycles on smt2; server_math still soaking).
    // Default off at compile time — see CVA6_MC_PC_PROBE_COMPILE above.
#if defined(CVA6_MC_PC_PROBE_COMPILE) && (VERILATOR_VERSION_INTEGER >= 5000000)
    if (std::getenv("CVA6_MC_PC_PROBE") != nullptr &&
        ((main_time >= 100 && main_time <= 800 && (main_time % 50) == 0) ||
         (main_time >= 400 && main_time <= 520 && (main_time % 5) == 0) ||
         main_time == 2000 || main_time == 10000 || main_time == 20000 ||
         main_time == 50000 || main_time == 100000 || main_time == 250000 ||
         main_time == 500000 || main_time == 1000000 || main_time == 2000000 ||
         main_time == 4000000 || main_time == 6500000 ||
         // Hang-5 window: dual-issue dies ~20-25k with mepc in fw_fdt_bin
         (main_time >= 15000 && main_time <= 35000 && (main_time % 200) == 0) ||
         // Hang-6: fw_platform_init ~100k–300k (dense for path_offset)
         (main_time >= 100000 && main_time <= 140000 && (main_time % 500) == 0) ||
         (main_time >= 80000 && main_time <= 300000 && (main_time % 2000) == 0) ||
         // Hang-7: FDT walk / memchr residual (single never finishes platform_init)
         (main_time >= 100000 && main_time <= 250000 && (main_time % 1000) == 0) ||
         (main_time >= 15000 && main_time <= 80000 && (main_time % 2000) == 0) ||
         (main_time >= 20000 && main_time <= 100000 && (main_time % 10000) == 0) ||
         // Dense FDT-walk window: capture offset advance / tag at next_tag entry
         (main_time >= 20000 && main_time <= 160000 && (main_time % 500) == 0) ||
         // Hang-7: gap between path0 success (~130k) and alias memchr (~136k)
         (main_time >= 130000 && main_time <= 140000 && (main_time % 200) == 0))) {
#if (VERILATOR_VERSION_INTEGER >= 5000000)
      auto npc0 = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__0__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__i_frontend__DOT__npc_q;
#if !defined(CVA6_PROBE_NO_CORE1)
      auto npc1 = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__1__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__i_frontend__DOT__npc_q;
#else
      uint64_t npc1 = 0;
#endif
      // Hang-4: instr_queue stores realign PC per FIFO word; sequential pc_q is
      // no longer on the output path (Verilator DCE). Probe issue-port0 address
      // from packed fetch_entry_o (see fetch_entry_t: address near head).
      const auto &fe0 = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__0__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__i_frontend__DOT____Vcellout__i_instr_queue__fetch_entry_o;
      // Dual-issue pack: port0 in low bits. address is VLEN at a stable offset;
      // fall back to npc if layout shifts. Bits [63:0] commonly hold address
      // when address is the first wide field after instruction in some packs —
      // use commit-adjacent npc as reliable IQ progress proxy.
      uint64_t pc_iq0 = (uint64_t)npc0;
      auto ic0 = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__0__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__gen_cache_hpd__DOT__i_cache_subsystem__DOT__i_cva6_icache__DOT__state_q;
#if !defined(CVA6_PROBE_NO_CORE1)
      auto ic1 = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__1__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__gen_cache_hpd__DOT__i_cache_subsystem__DOT__i_cva6_icache__DOT__state_q;
#else
      unsigned ic1 = 0;
#endif
#if !defined(CVA6_PROBE_NO_L2)
      auto l2st = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_l2__DOT__i_l2__DOT__gen_l2__DOT__state_q;
      auto l2addr = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_l2__DOT__i_l2__DOT__gen_l2__DOT__addr_q;
      auto l2len = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_l2__DOT__i_l2__DOT__gen_l2__DOT__len_q;
      auto l2cache = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_l2__DOT__i_l2__DOT__gen_l2__DOT__cache_q;
      auto l2id = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_l2__DOT__i_l2__DOT__gen_l2__DOT__id_q;
      auto l2_rot = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_l2__DOT__i_l2__DOT__gen_l2__DOT__mst_r_ot_q;
#else
      unsigned l2st = 0, l2len = 0, l2cache = 0, l2id = 0, l2_rot = 0;
      uint64_t l2addr = 0;
#endif
#if !defined(CVA6_PROBE_NO_CORE1)
      auto ar_ot = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_hub__DOT__i_hub__DOT__gen_cluster__DOT__ar_ot_cnt_q;
#else
      unsigned ar_ot = 0;  // gen_single: no hub
#endif
      auto rom_req = top->rootp->ariane_testharness__DOT__rom_req;
      auto rom_axi_st = top->rootp->ariane_testharness__DOT__i_axi2rom__DOT__state_q;
      auto pend0 = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__0__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__gen_cache_hpd__DOT__i_cache_subsystem__DOT__genblk1__DOT__i_axi_arbiter__DOT__icache_miss_pending_q;
      auto ar0 = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__0__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__gen_cache_hpd__DOT__i_cache_subsystem__DOT__genblk1__DOT__i_axi_arbiter__DOT____Vcellout__i_hpdcache_mem_to_axi_read__axi_ar_valid_o;
#if !defined(CVA6_PROBE_NO_CORE1)
      auto pend1 = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__1__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__gen_cache_hpd__DOT__i_cache_subsystem__DOT__genblk1__DOT__i_axi_arbiter__DOT__icache_miss_pending_q;
      auto ar1 = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__1__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__gen_cache_hpd__DOT__i_cache_subsystem__DOT__genblk1__DOT__i_axi_arbiter__DOT____Vcellout__i_hpdcache_mem_to_axi_read__axi_ar_valid_o;
#else
      unsigned pend1 = 0, ar1 = 0;
#endif
      // DRAM path: axi2mem IDLE=0 READ=1 WRITE=2 SEND_B=3 WAIT_WVALID=4
      auto a2m = top->rootp->ariane_testharness__DOT__i_axi2mem__DOT__state_q;
      auto a2m_cnt = top->rootp->ariane_testharness__DOT__i_axi2mem__DOT__cnt_q;
      auto demux_lock = top->rootp->ariane_testharness__DOT__i_axi_xbar__DOT__i_xbar__DOT__gen_slv_port_demux__BRA__0__KET____DOT__i_axi_demux__DOT__gen_demux__DOT__lock_ar_valid_q;
      auto demux_ar = top->rootp->ariane_testharness__DOT__i_axi_xbar__DOT__i_xbar__DOT__gen_slv_port_demux__BRA__0__KET____DOT__i_axi_demux__DOT__gen_demux__DOT__ar_valid;
      auto atom_ar = top->rootp->ariane_testharness__DOT__i_axi_riscv_atomics__DOT____Vcellout__i_atomics__mst_ar_valid_o;
      auto atom_rr = top->rootp->ariane_testharness__DOT__i_axi_riscv_atomics__DOT____Vcellout__i_atomics__mst_r_ready_o;
      auto amos_r = top->rootp->ariane_testharness__DOT__i_axi_riscv_atomics__DOT__i_atomics__DOT__i_amos__DOT__r_state_q;
      auto lrsc_r = top->rootp->ariane_testharness__DOT__i_axi_riscv_atomics__DOT__i_atomics__DOT__i_lrsc__DOT__r_state_q;
      // Hang-3: post-fence.i _reset_regs stall (I$ idle/hit, a2m IDLE)
      auto fence_ia = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__0__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__controller_i__DOT__fence_i_active_q;
      auto no_st = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__0__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__no_st_pending_commit;
      auto wbuf_e = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__0__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__dcache_commit_wbuffer_empty;
      auto cack = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__0__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__commit_ack;
      auto iss_ptr = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__0__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__issue_stage_i__DOT__i_scoreboard__DOT__issue_pointer_q;
      auto cmt_ptr = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__0__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__issue_stage_i__DOT__i_scoreboard__DOT__commit_pointer_q;
      auto epc = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__0__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__epc_commit_pcgen;
      auto mepc = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__0__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__csr_regfile_i__DOT__gen_single__DOT__i_csr__DOT__mepc_q;
      auto mcause = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__0__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__csr_regfile_i__DOT__gen_single__DOT__i_csr__DOT__mcause_q;
      auto mtval = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__0__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__csr_regfile_i__DOT__gen_single__DOT__i_csr__DOT__mtval_q;
      auto wfi = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__0__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__csr_regfile_i__DOT__gen_single__DOT__i_csr__DOT__wfi_q;
      auto flush_if = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__0__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__flush_ctrl_if;
      auto iq_full = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__0__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__i_frontend__DOT__i_instr_queue__DOT__instr_queue_full;
      auto iq_rdy = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__0__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__i_frontend__DOT__instr_queue_ready;
      // Commit-head PC + valid (packed scoreboard_entry: pc is MSB [W-1 -: VLEN])
      const auto &ci = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__0__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__issue_stage_i__DOT____Vcellout__i_scoreboard__commit_instr_o;
      // 465-bit entry: pc = bits [464:401] (VLEN=64). Extract little-endian bit order.
      auto bit_at = [&](int b) -> unsigned {
        return (ci[b / 32] >> (b % 32)) & 1u;
      };
      uint64_t cmt_pc = 0;
      for (int i = 0; i < 64; i++) {
        if (bit_at(401 + i)) cmt_pc |= (uint64_t)1 << i;
      }
      // MMU / I$ miss path (second hang: ic=READ + a2m=READ orphan)
      auto en_tr = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__0__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__enable_translation_csr_ex;
      auto en_gtr = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__0__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__enable_g_translation_csr_ex;
      auto itlb_hit = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__0__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__ex_stage_i__DOT__lsu_i__DOT__gen_mmu__DOT__i_cva6_mmu__DOT__itlb_lu_hit;
      auto stlb_miss = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__0__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__ex_stage_i__DOT__lsu_i__DOT__gen_mmu__DOT__i_cva6_mmu__DOT__shared_tlb_miss;
      auto ptw_st = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__0__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__ex_stage_i__DOT__lsu_i__DOT__gen_mmu__DOT__i_cva6_mmu__DOT__i_ptw__DOT__state_q;
      auto ic_hit = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__0__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__gen_cache_hpd__DOT__i_cache_subsystem__DOT__i_cva6_icache__DOT__cl_hit;
      auto ic_inv = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__0__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__gen_cache_hpd__DOT__i_cache_subsystem__DOT__i_cva6_icache__DOT__inv_q;
      auto ic_en = top->rootp->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__0__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__gen_cache_hpd__DOT__i_cache_subsystem__DOT__i_cva6_icache__DOT__cache_en_q;
      auto a2m_addr = top->rootp->ariane_testharness__DOT__i_axi2mem__DOT__req_addr_q;
      // ax_req_q: packed {id, addr, len, size, burst}
      const auto &a2m_ax = top->rootp->ariane_testharness__DOT__i_axi2mem__DOT__ax_req_q;
      std::cerr << std::hex << "[mc_pc] @" << main_time
                << " c0.npc=0x" << (unsigned long long)npc0
                << " c0.iq_pc=0x" << (unsigned long long)pc_iq0
                << " c1.npc=0x" << (unsigned long long)npc1
                << " ic0=" << (unsigned)ic0 << " ic1=" << (unsigned)ic1
                << " l2st=" << (unsigned)l2st
                << " l2a=0x" << (unsigned long long)l2addr
                << " l2len=" << (unsigned)l2len
                << " l2c=" << (unsigned)l2cache
                << " l2id=" << (unsigned)l2id
                << " l2_rot=" << (unsigned)l2_rot
                << " ar_ot=" << (unsigned)ar_ot
                << " rom_req=" << (unsigned)rom_req
                << " rom_axi=" << (unsigned)rom_axi_st
                << " pend0=" << (unsigned)pend0 << " pend1=" << (unsigned)pend1
                << " ar0=" << (unsigned)ar0 << " ar1=" << (unsigned)ar1
                << " a2m=" << (unsigned)a2m << " a2m_cnt=" << (unsigned)a2m_cnt
                << " a2m_a=0x" << (unsigned long long)a2m_addr
                << " dmx_lk=" << (unsigned)demux_lock << " dmx_ar=" << (unsigned)demux_ar
                << " atom_ar=" << (unsigned)atom_ar
                << " atom_rr=" << (unsigned)atom_rr
                << " amos_r=" << (unsigned)amos_r
                << " lrsc_r=" << (unsigned)lrsc_r
                << " fia=" << (unsigned)fence_ia
                << " nost=" << (unsigned)no_st
                << " wbe=" << (unsigned)wbuf_e
                << " cack=" << (unsigned)cack
                << " iss=" << (unsigned)iss_ptr
                << " cmt=" << (unsigned)cmt_ptr
                << " epc=0x" << (unsigned long long)epc
                << " mepc=0x" << (unsigned long long)mepc
                << " mcause=0x" << (unsigned long long)mcause
                << " mtval=0x" << (unsigned long long)mtval
                << " wfi=" << (unsigned)wfi
                << " flif=" << (unsigned)flush_if
                << " iqf=" << (unsigned)iq_full
                << " iqr=" << (unsigned)iq_rdy
                << " cpc=0x" << cmt_pc
                << " en_tr=" << (unsigned)en_tr << " en_gtr=" << (unsigned)en_gtr
                << " itlb=" << (unsigned)itlb_hit << " stlb_m=" << (unsigned)stlb_miss
                << " ptw=" << (unsigned)ptw_st
                << " ic_hit=" << (unsigned)ic_hit << " ic_inv=" << (unsigned)ic_inv
                << " ic_en=" << (unsigned)ic_en
                << " ax[0]=0x" << (unsigned long long)a2m_ax[0]
                << " ax[1]=0x" << (unsigned long long)a2m_ax[1]
                << " ax[2]=0x" << (unsigned long long)a2m_ax[2];
      // Hang-6/7: FDT header + structure tags from DRAM model + walk helpers.
      // Symbols (fw_payload): fdt_offset_ptr=0x80012858, fdt_next_tag=0x80012944,
      // fdt_path_offset=0x800137f4, sbi_memchr=0x80004be4, fw_platform_init=0x80007264.
      {
        auto *bytes = reinterpret_cast<const uint8_t *>(MEM);
        const size_t fdt_off = 0x1e000;
        auto be32 = [&](size_t off) -> uint32_t {
          return ((uint32_t)bytes[off] << 24) | ((uint32_t)bytes[off + 1] << 16) |
                 ((uint32_t)bytes[off + 2] << 8) | (uint32_t)bytes[off + 3];
        };
        uint32_t mag_be = be32(fdt_off);
        uint32_t tsz_be = be32(fdt_off + 4);
        uint32_t off_struct = be32(fdt_off + 8);
        // Structure tags (BE): root@0x38=1, cpus@0x13c=1 if image intact
        uint32_t tag_root = be32(fdt_off + 0x38);
        uint32_t tag_cpus = be32(fdt_off + 0x13c);
        // Path string "/cpus" at fw_fdt_bin+0x16c0
        uint32_t path4 = be32(fdt_off + 0x16c0);
        // Hang-7: platform @0x800403e8, hart_count @+0x50; hart ids @0x80042868
        const size_t plat_off = 0x403e8;
        uint32_t hart_cnt = (uint32_t)bytes[plat_off + 0x50] |
                            ((uint32_t)bytes[plat_off + 0x51] << 8) |
                            ((uint32_t)bytes[plat_off + 0x52] << 16) |
                            ((uint32_t)bytes[plat_off + 0x53] << 24);
        uint32_t hid0 = (uint32_t)bytes[0x42868] | ((uint32_t)bytes[0x42869] << 8) |
                        ((uint32_t)bytes[0x4286a] << 16) | ((uint32_t)bytes[0x4286b] << 24);
        uint32_t hid1 = (uint32_t)bytes[0x4286c] | ((uint32_t)bytes[0x4286d] << 8) |
                        ((uint32_t)bytes[0x4286e] << 16) | ((uint32_t)bytes[0x4286f] << 24);
        std::cerr << " fdt_mag=0x" << mag_be << " fdt_tsz=0x" << tsz_be
                  << " tag_root=0x" << tag_root << " tag_cpus=0x" << tag_cpus
                  << " path4=0x" << path4
                  << " hart_cnt=0x" << hart_cnt << " hid0=0x" << hid0 << " hid1=0x" << hid1;

        // GPR snapshot: RF mem is [32][64] packed → VlWide word n = bit/32.
        // xN lives at bits [64*N +: 64] → words 2*N, 2*N+1 (LE).
        const auto &rf = top->rootp
            ->ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__0__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6__DOT__issue_stage_i__DOT__i_issue_read_operands__DOT__gen_asic_regfile__DOT__i_ariane_regfile__DOT__gen_single_bank__DOT__i_rf__DOT__mem;
        auto gpr = [&](int n) -> uint64_t {
          return (uint64_t)rf[2 * n] | ((uint64_t)rf[2 * n + 1] << 32);
        };
        // a0=x10..a5=x15; s0=x8 s1=x9 s2=x18 s3=x19 (namelen in path_offset);
        // ra=x1. FDT ptr saved in s2 by fw_platform_init.
        uint64_t a0v = gpr(10), a1v = gpr(11), a2v = gpr(12), a3v = gpr(13);
        uint64_t a4v = gpr(14), a5v = gpr(15), s0v = gpr(8), s1v = gpr(9);
        uint64_t s2v = gpr(18), s3v = gpr(19), rav = gpr(1);
        uint64_t npc_u = (uint64_t)npc0;
        std::cerr << " a0=0x" << a0v << " a1=0x" << a1v << " a2=0x" << a2v
                  << " a3=0x" << a3v << " a4=0x" << a4v << " a5=0x" << a5v
                  << " s0=0x" << s0v << " s1=0x" << s1v << " s2=0x" << s2v
                  << " s3=0x" << s3v << " ra=0x" << rav;
        // path_offset first-byte check @ 0x8001370a..18: a5=path[0], a1='/'
        if (npc_u >= 0x8001370aULL && npc_u <= 0x80013720ULL) {
          uint8_t dram_b = 0;
          if (s1v >= 0x80000000ULL && s1v < 0x80200000ULL)
            dram_b = bytes[(size_t)(s1v - 0x80000000ULL)];
          std::cerr << " PATH0_CHK a5=0x" << a5v << " dram_b=0x" << (unsigned)dram_b
                    << " expect_slash=" << ((a5v & 0xff) == 0x2f ? 1 : 0);
        }

        // If PC is in fdt_next_tag / fdt_offset_ptr, a1 is often structure offset.
        // Dump DRAM tag at off_dt_struct + offset for comparison with CPU view.
        bool in_fdt_walk = (npc_u >= 0x80012858ULL && npc_u < 0x80012b00ULL) ||
                           (npc_u >= 0x80012e2aULL && npc_u < 0x80013200ULL) ||
                           (npc_u >= 0x80013380ULL && npc_u < 0x80013920ULL);
        if (in_fdt_walk && a1v < 0x1000) {
          size_t tag_off = fdt_off + (size_t)off_struct + (size_t)a1v;
          if (tag_off + 4 <= 0x200000) {
            uint32_t dram_tag = be32(tag_off);
            // Also LE word as CPU lw would see before fdt32_to_cpu
            uint32_t le_word = (uint32_t)bytes[tag_off] |
                               ((uint32_t)bytes[tag_off + 1] << 8) |
                               ((uint32_t)bytes[tag_off + 2] << 16) |
                               ((uint32_t)bytes[tag_off + 3] << 24);
            std::cerr << " off=0x" << a1v << " dram_tag=0x" << dram_tag
                      << " le_w=0x" << le_word;
          }
        }
        // Flag control-flow glitch: PC in low mem (dual hang-6 saw 0x830/0x850)
        if (npc_u > 0 && npc_u < 0x10000ULL)
          std::cerr << " CTRL_LOW_PC";
        // Flag memchr walking unmapped: a0 small while PC in sbi_memchr
        if (npc_u >= 0x80004be4ULL && npc_u < 0x80004c1aULL && a0v < 0x10000ULL)
          std::cerr << " MEMCHR_LO_PTR";
      }
      std::cerr << std::dec << "\n";
#else
      std::cerr << "[mc_pc] need Verilator >=5\n";
#endif
    }
#endif // CVA6_MC_PC_PROBE_COMPILE
  }

#if VM_TRACE
  if (tfp)
    tfp->close();
  if (vcdfile)
    fclose(vcdfile);
#endif

  if (dtm->exit_code()) {
    fprintf(stderr, "%s *** FAILED *** (tohost = %d) after %ld cycles\n", htif_argv[1], dtm->exit_code(), main_time);
    ret = dtm->exit_code();
  } else if (jtag->exit_code()) {
    fprintf(stderr, "%s *** FAILED *** (tohost = %d, seed %d) after %ld cycles\n", htif_argv[1], jtag->exit_code(), random_seed, main_time);
    ret = jtag->exit_code();
  } else if (top->exit_o & 0xFFFFFFFE) {
    int exitcode = ((unsigned int) top->exit_o) >> 1;
    fprintf(stderr, "%s *** FAILED *** (tohost = %d) after %ld cycles\n", htif_argv[1], exitcode, main_time);
    ret = exitcode;
  } else {
    fprintf(stderr, "%s *** SUCCESS *** (tohost = 0) after %ld cycles\n", htif_argv[1], main_time);
  }

  if (dtm) delete dtm;
  if (jtag) delete jtag;

  std::clock_t c_end = std::clock();
  auto t_end = std::chrono::high_resolution_clock::now();

  if (perf) {
    std::cout << std::fixed << std::setprecision(2) << "CPU time used: "
              << 1000.0 * (c_end-c_start) / CLOCKS_PER_SEC << " ms\n"
              << "Wall clock time passed: "
              << std::chrono::duration<double, std::milli>(t_end-t_start).count()
              << " ms\n";
  }

  return ret;
}
