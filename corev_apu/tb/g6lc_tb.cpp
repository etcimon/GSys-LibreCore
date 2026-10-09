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
//
// Modified 2026 Etienne Cimon — GSys LibreCore soak-exit fork of
// ariane_tb.cpp. Apache-2.0 terms of the original file are retained.
// Extra: CVA6_SOAK_EXIT (cookie 51b1babe + pin mepc + dual-WFI).
// Do not stop on 51b1c001 — that is the cave lui before addi.

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

// Hierarchical MC hang probes (OpenSBI bring-up only). Default bare-metal /
// Zacas mini builds must NOT compile them — paths assume multi-core + HPDCACHE + L2
// and fail to build for WT single-core packages (cv64a6_imafdc_sv39).
// Enable with: -DCVA6_MC_PC_PROBE_COMPILE and optional CVA6_PROBE_NO_{L2,CORE1,HPD}.
// Runtime still requires env CVA6_MC_PC_PROBE=1.
// Define CVA6_PROBE_NO_L2 without gen_l2; CVA6_PROBE_NO_CORE1 without core1.
// G6LC_CVA6_C0/C1 select the Verilator core-wrapper path via token pasting:
// Ara/RVV builds use gen_acc, non-RVV builds use gen_std. See ariane.sv.
#if defined(G6LC_CVA6_GEN_ACC)
#define G6LC_CVA6_C0(path) ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__0__KET____DOT__i_ariane__DOT__gen_acc__DOT__i_cva6##__DOT__##path
#define G6LC_CVA6_C1(path) ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__1__KET____DOT__i_ariane__DOT__gen_acc__DOT__i_cva6##__DOT__##path
#else
#define G6LC_CVA6_C0(path) ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__0__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6##__DOT__##path
#define G6LC_CVA6_C1(path) ariane_testharness__DOT__i_cluster__DOT__gen_core__BRA__1__KET____DOT__i_ariane__DOT__gen_std__DOT__i_cva6##__DOT__##path
#endif
// SMT hierarchy flavor: NrHarts>1 builds the banked CSR/RF wrappers and the
// g6lc_thread_select gen_smt block; NrHarts==1 collapses to the gen_single*
// paths. The Makefile defines G6LC_TB_BANKED when the target config package
// has NrHarts>1. G6LC_TB_CSR/RF take the core path macro (G6LC_CVA6_C0/C1) so
// the pasted member name is produced on rescan. G6LC_TB_H1(expr) evaluates
// expr only on banked builds — hart-1 / gen_smt state does not exist in
// non-banked models, where it compiles to 0. Always wrap hart-1 and
// i_smt_thread_select reads in G6LC_TB_H1: a bare G6LC_TB_CSR(core,1,·)
// silently aliases hart-0 state when non-banked.
#if defined(G6LC_TB_BANKED)
#  define G6LC_TB_CSR(core, h, sig) \
     core(csr_regfile_i__DOT__gen_banked__DOT__gen_csr__BRA__##h##__KET____DOT__i_csr__DOT__##sig)
#  define G6LC_TB_RF(core, h) \
     core(issue_stage_i__DOT__i_issue_read_operands__DOT__gen_asic_regfile__DOT__i_ariane_regfile__DOT__gen_banked__DOT__gen_hart_bank__BRA__##h##__KET____DOT__i_rf_bank__DOT__mem)
#  define G6LC_TB_H1(expr) (expr)
#else
#  define G6LC_TB_CSR(core, h, sig) \
     core(csr_regfile_i__DOT__gen_single__DOT__i_csr__DOT__##sig)
#  define G6LC_TB_RF(core, h) \
     core(issue_stage_i__DOT__i_issue_read_operands__DOT__gen_asic_regfile__DOT__i_ariane_regfile__DOT__gen_single_bank__DOT__i_rf__DOT__mem)
#  define G6LC_TB_H1(expr) 0u
#endif
#if defined(G6LC_TB_OOO)
#  define G6LC_TB_LEGACY_HOLD(expr) 0u
#else
#  define G6LC_TB_LEGACY_HOLD(expr) G6LC_TB_H1(expr)
#endif
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
#include "g6lc_tb_trace.h"

// This software is heavily based on Rocket Chip
// Checkout this awesome project:
// https://github.com/freechipsproject/rocket-chip/


// This is a 64-bit integer to reduce wrap over issues and
// allow modulus.  You can also use a double, if you wish.
static vluint64_t main_time = 0;

// Plusargs consumed by RTL/SV ($value$plusargs) — must be allowlisted so HTIF
// does not reject them. Use +permissive…+permissive-off if you need more.
static const char *verilog_plusargs[] = {
    "jtag_rbb_enable", "time_out", "debug_disable", "tohost_addr", "elf_file",
    "quiet_axi", "fetch_snap", "fetch_snap_lo", "fetch_snap_hi",
    // I1-at-supply oracle (core/id_stage.sv). Must be allowlisted or the arg
    // parser hands it to HTIF, which rejects it and the run dies before the
    // checker ever arms -- a silent-oracle failure mode, since a rejected plusarg
    // looks exactly like a check that found nothing.
    "fetch_i1_check", "smt_flow_trace", "smt_progress", "smt_mem_watch",
    // Service/handoff attribution (core/smt/g6lc_thread_select.sv) and load
    // round-trip observation (core/cva6.sv). Same allowlist rule as above.
    "smt_sched_trace", "smt_rtt_trace",
    // Early decode-supply trace (core/id_stage.sv), opt-in: ungated it floods
    // the run log and hides everything else.
    "id_dbg_trace",
    // Window lifecycle probe (core/fetch_B/frontend.sv). Same allowlist rule as
    // above: an unlisted plusarg is handed to HTIF, rejected, and the run dies
    // before the probe arms.
    "fetch_win_trace",
    // Kill-persistence check (core/fetch_B/frontend.sv): reports a response
    // accepted for a fetch whose request was already killed. Same allowlist
    // rule as above.
    "fetch_kill_check",
    // instr_queue order probe (core/fetch_B/instr_queue.sv).
    "iq_trace",
    // Fetch-supply observer (core/fetch_B/g6lc_fetch_dbg.sv). Same allowlist
    // rule: an unlisted plusarg is handed to HTIF, rejected, and the run dies
    // before the observer arms.
    "fetch_supply", "fetch_supply_lo", "fetch_supply_hi", "fetch_supply_limit",
    // Injected-error control for the MULTI-CORE VERDICT
    // (corev_apu/tb/ariane_testharness.sv): makes the secondary cores appear
    // silent, so a normally-passing test must come out as a multi-core failure.
    // Allowlisted for the same reason as the probes above -- and the reason bites
    // harder here: an unlisted plusarg is rejected by HTIF and the run dies, which
    // looks exactly like the control "working", when in fact the verdict was never
    // exercised at all.
    "mc_verdict_fault",
    // Injected-error control for the HANG bound: freezes the secondary cores'
    // observed liveness once they have started, so a normally-passing test must
    // come out as exit 126. Same allowlist rule -- unlisted means HTIF kills the
    // run, which would look like the control working.
    "mc_hang_fault",
    // Mixed-residency statistics probe (core/cva6.sv): prints residency and
    // per-hart commit counters at $finish. Same allowlist rule as above.
    "smt_mixed_stats",
    // Duplicate-commit diagnostics probe (core/cva6.sv): per-cycle dump of the
    // commit/eret/flush/redirect chain over a fixed window. Same allowlist
    // rule as above. The _lo/_hi pair overrides the probe's compiled-in window.
    "smt_dup_trace", "smt_dup_lo", "smt_dup_hi",
    // L2/L3 tag/FSM event observer (corev_apu/tb/ariane_testharness.sv): writes
    // l2_trace.log for flop-vs-SRAM tag-path equivalence review. Same allowlist
    // rule as above: unlisted, HTIF rejects it and the observer never arms.
    "l2_trace", "l2_trace_file",
    // +mem_poke=<hexaddr>:<hexval64>:<cycle> — backdoor DRAM write at a cycle,
    // consumed here in C++ (writes the same MEM the cookie-exit poll reads);
    // mc_cbo_ewt.S uses it to inject a non-coherent mutation behind the caches.
    "mem_poke",
    // M3b mispredict-recovery statistics probe (core/scoreboard.sv): prints
    // recovery-cycle mean/max/histogram at final. Same allowlist rule as
    // above: unlisted, HTIF rejects it and the probe never arms.
    "misp_stats",
    // N1/T10a drained-handoff observer (core/cva6.sv): prints drain requests,
    // duration histogram, not-ready causes, per-hart retired and commit_drop
    // every 1M cycles and at final. Same allowlist rule as above.
    "smt_stats",
    // T16 load round-trip anatomy probe (core/cva6.sv, translate_off): per-cycle
    // load-unit / LSQ / scoreboard-head / HPDCACHE miss-path dump over the
    // [ld_lo, ld_hi] window plus always-on handshake events. Same allowlist
    // rule as above.
    "ld_trace", "ld_lo", "ld_hi",
    // T20 HPDCACHE replay-table anatomy probe (core/cva6.sv gen_hpd_trace,
    // translate_off): rtab entries/deps/pipeline dump on every [smt-stall]
    // ticket, on every rtab alloc/pop/commit/rollback inside [hpd_lo, hpd_hi],
    // and once per leak episode (parked entries with nothing left to release
    // them). Same allowlist rule as above.
    "hpd_trace", "hpd_lo", "hpd_hi",
    // T20b aliases / filters of the same probe: +hpd_rtab_trace == +hpd_trace,
    // +hpd_core=N keeps only core N (default 0, -1 = all).
    "hpd_rtab_trace", "hpd_core",
    // T20 fetch-window lifecycle probe (core/cva6.sv gen_win_trace,
    // translate_off): I$ request/response/take, loop-buffer inject, IQ push
    // per slot, FTQ push/pop/flush, kills/redirects, IQ->ID and ID->issue
    // handoffs inside [win_lo, win_hi], optionally for one global hart
    // (+win_hart=N). Same allowlist rule as above.
    "win_trace", "win_lo", "win_hi", "win_hart",
    // T20b aliases / filters: +fe_trace/+fe_lo/+fe_hi == +win_trace/_lo/_hi,
    // +fe_core=N keeps only core N (default -1 = all); PC-bank writes added.
    "fe_trace", "fe_lo", "fe_hi", "fe_core",
    // T20b windows for the two pre-existing SMT observers (whole run when
    // absent): core/smt/g6lc_thread_select.sv [smt-sched] and core/cva6.sv
    // [smt-flow]/[smt-probe] (+smt_handoff_trace == +smt_flow_trace).
    "smt_sched_lo", "smt_sched_hi", "smt_handoff_trace", "smt_flow_lo", "smt_flow_hi",
    // AI island per-job PMU record (corev_apu/ai_island/g6lc_ai_island_top.sv,
    // translate_off): one AI_JOB line per completed descriptor, harvested by
    // verif/regress/ai-matrix-veri.sh AI_MATRIX_BENCH=1.
    "ai_pmu_trace",
    nullptr};

// +mem_poke entries, applied inside the sim loop once main_time reaches cycle.
struct MemPoke { uint64_t addr, val, cycle; bool applied; };
static std::vector<MemPoke> mem_pokes;

extern dtm_t* dtm;
extern remote_bitbang_t * jtag;

// A wall-clock kill must not print SUCCESS: record it so the verdict line
// reads TERMINATED (exit 124, the `timeout` convention) instead of a pass.
static volatile sig_atomic_t sigterm_seen = 0;
// Set when the main loop leaves on -m / +max-cycles rather than on a tohost
// or exit handshake; the final verdict line must not call that a success.
static bool budget_exit = false;

void handle_sigterm(int sig) {
  sigterm_seen = 1;
  dtm->stop();
}


extern "C" void read_elf(const char* filename);
extern "C" char get_section (long long* address, long long* len);
extern "C" void read_section_void(long long address, void * buffer, uint64_t size = 0);

// ---------------------------------------------------------------------------
// I1-at-supply oracle (see core/fetch_B/g6lc_fetch_dbg.sv, `+fetch_i1_check`).
//
// The fetch formal contracts all take the I$ response `data_i` as a FREE input:
// they prove the realigner and queue are faithful to whatever bytes they are
// handed, which is the right contract for those modules and exactly why they
// cannot see a supply that hands over the WRONG bytes. Nothing in the repo owned
// the promise "the bytes returned for a fetch of address A are the bytes at A",
// and a core that executes instructions offset from its own PC passed an 11/11
// formal gate as a result.
//
// This exposes the post-preload DRAM image so the promise can be checked in
// simulation at the point it is made. Deliberately a plain byte peek with no
// side effects: the oracle must not be able to perturb what it observes.
// ---------------------------------------------------------------------------
static const uint8_t *g6lc_dram_ptr   = nullptr;
static uint64_t       g6lc_dram_bytes = 0;
static uint64_t       g6lc_dram_base  = 0x80000000ULL;

extern "C" int g6lc_dram_peek64(long long addr, long long *data) {
  if (!g6lc_dram_ptr || !data) return 0;
  const uint64_t a = (uint64_t)addr;
  if (a < g6lc_dram_base) return 0;                     // bootrom/CLINT: not our image
  const uint64_t off = a - g6lc_dram_base;
  if (off + 8 > g6lc_dram_bytes) return 0;              // outside the preloaded window
  uint64_t v = 0;
  for (int i = 0; i < 8; i++) v |= (uint64_t)g6lc_dram_ptr[off + i] << (8 * i);
  *data = (long long)v;
  return 1;
}

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

  for (int i = 1; i < argc; i++) {
    if (strncmp(argv[i], "+mem_poke=", 10) == 0) {
      uint64_t pa = 0, pv = 0, pc = 0;
      if (sscanf(argv[i] + 10, "%llx:%llx:%llu", (unsigned long long *)&pa,
                 (unsigned long long *)&pv, (unsigned long long *)&pc) == 3)
        mem_pokes.push_back({pa, pv, pc, false});
      else
        std::cerr << "[mem_poke] malformed plusarg: " << argv[i] << "\n";
    }
  }

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
    if ((vcdfile || fst_fname) && main_time >= start)
      tfp->dump(static_cast<vluint64_t>(main_time * 2));
#endif
    top->clk_i = 1;
    top->eval();
#if VM_TRACE
    if ((vcdfile || fst_fname) && main_time >= start)
      tfp->dump(static_cast<vluint64_t>(main_time * 2 + 1));
#endif
    main_time++;
  }
  top->rst_ni = 1;
  const char *metrics_sidecar = std::getenv("G6LC_METRICS_SIDECAR");
  uint64_t metrics_retired[2] = {0, 0};
  uint64_t metrics_dropped[2] = {0, 0};

  // Preload memory.
  //
  // The DRAM SRAM moved: `ariane_testharness` no longer instantiates
  // `axi2mem`/`sram` inline, it instantiates `g6lc_ai_dram_backend`, and that
  // change is NOT behind an ifdef -- so the old `ariane_testharness.i_sram`
  // path stopped existing for every flavour. `ariane_tb.cpp` was updated for
  // the AI flavours; this file, which flavour B and legacy use, was not, so B
  // has failed to compile since the backend landed (`has no member named
  // ...i_sram...`). That silently blocked the OpenSBI / soft-ladder line, whose
  // evidence all comes from flavour B.
  //
  // Only the prefix changes. The suffix, `gen_mem_user` included, is the same
  // `sram` module as before and `AXI_USER_EN` is still forwarded
  // (ariane_testharness.sv `i_dram_backend`), so MEM_USER stays a genuinely
  // separate user-bit memory rather than an alias of MEM -- aliasing it would
  // overwrite data with user bits.
  //
  // `gen_sim_axi` is the class-0, single-channel generate arm. B and legacy pass
  // no `G6LC_AI_DRAM_*` define, so they select `AiIslandLatencyDefault`
  // (DramClass=0, DramChannels=1) and this is the right arm. The stripe
  // (`gen_sim_stripe.gen_ch[i]`) and class-1 LiteDRAM paths are AI-only and live
  // in ariane_tb.cpp.
#if (VERILATOR_VERSION_INTEGER >= 5000000)
  // Verilator v5: Use rootp pointer and .data() accessor.
#define MEM top->rootp->ariane_testharness__DOT__i_dram_backend__DOT__gen_sim_axi__DOT__i_sram__DOT__gen_cut__BRA__0__KET____DOT__i_tc_sram_wrapper__DOT__i_tc_sram__DOT__sram.m_storage
#define MEM_USER top->rootp->ariane_testharness__DOT__i_dram_backend__DOT__gen_sim_axi__DOT__i_sram__DOT__gen_cut__BRA__0__KET____DOT__gen_mem_user__DOT__i_tc_sram_wrapper_user__DOT__i_tc_sram__DOT__sram.m_storage
#else
  // Verilator v4
#define MEM top->ariane_testharness__DOT__i_dram_backend__DOT__gen_sim_axi__DOT__i_sram__DOT__gen_cut__BRA__0__KET____DOT__i_tc_sram_wrapper__DOT__i_tc_sram__DOT__sram
#define MEM_USER top->ariane_testharness__DOT__i_dram_backend__DOT__gen_sim_axi__DOT__i_sram__DOT__gen_cut__BRA__0__KET____DOT__gen_mem_user__DOT__i_tc_sram_wrapper_user__DOT__i_tc_sram__DOT__sram
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

  // Publish the preloaded DRAM image to the I1-at-supply oracle. Done after all
  // preload paths above have run, so the checker compares against the same bytes
  // the core will fetch rather than against a partially-populated image.
  g6lc_dram_ptr   = reinterpret_cast<const uint8_t *>(MEM);
  g6lc_dram_bytes = (uint64_t)mem_size;
  g6lc_dram_base  = dram_base;

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
    if ((vcdfile || fst_fname) && main_time >= start)
      tfp->dump(static_cast<vluint64_t>(main_time * 2));
#endif

    top->clk_i = 1;
    top->eval();
#if VM_TRACE
    if ((vcdfile || fst_fname) && main_time >= start)
      tfp->dump(static_cast<vluint64_t>(main_time * 2 + 1));
#endif
    // toggle RTC
    if (main_time % 2 == 0) {
      top->rtc_i ^= 1;
    }
    main_time++;
#ifdef MEM
    // +mem_poke: backdoor 64-bit write straight into the DRAM array behind
    // every cache level — the non-coherent mutation a cbo.inval must expose.
    if (!mem_pokes.empty()) {
      for (auto &p : mem_pokes) {
        if (!p.applied && main_time >= p.cycle &&
            p.addr >= dram_base && p.addr + 8 <= dram_base + mem_size) {
          auto *bytes = reinterpret_cast<uint8_t *>(MEM);
          const uint64_t off = p.addr - dram_base;
          for (int i = 0; i < 8; i++)
            bytes[off + i] = (uint8_t)(p.val >> (8 * i));
          p.applied = true;
          std::cerr << "[mem_poke] t=" << std::dec << main_time << " addr=0x"
                    << std::hex << p.addr << " val=0x" << p.val << std::dec << "\n";
        }
      }
    }
#endif
    if (metrics_sidecar) {
#if (VERILATOR_VERSION_INTEGER >= 5000000)
      unsigned cack0 = (unsigned)top->rootp->G6LC_CVA6_C0(commit_ack);
      unsigned cdrop0 = (unsigned)top->rootp->G6LC_CVA6_C0(commit_drop_id_commit);
      metrics_retired[0] += (uint64_t)__builtin_popcount(cack0 & ~cdrop0);
      metrics_dropped[0] += (uint64_t)__builtin_popcount(cack0 & cdrop0);
#if defined(G6LC_TB_CLUSTER)
      unsigned cack1 = (unsigned)top->rootp->G6LC_CVA6_C1(commit_ack);
      unsigned cdrop1 = (unsigned)top->rootp->G6LC_CVA6_C1(commit_drop_id_commit);
      metrics_retired[1] += (uint64_t)__builtin_popcount(cack1 & ~cdrop1);
      metrics_dropped[1] += (uint64_t)__builtin_popcount(cack1 & cdrop1);
#endif
#endif
    }
    // I4q: first time frontend NPC is 0 after leaving boot (smt2 hart0 illegal).
    if (std::getenv("CVA6_TRAP_DUMP") != nullptr) {
      static int saw_nonzero_npc = 0;
      static int logged_zero_npc = 0;
#if (VERILATOR_VERSION_INTEGER >= 5000000)
      uint64_t npc_now = (uint64_t)top->rootp->G6LC_CVA6_C0(i_frontend__DOT__npc_q);
      unsigned act_now = (unsigned)G6LC_TB_H1(top->rootp->G6LC_CVA6_C0(i_smt_thread_select__DOT__gen_smt__DOT__active_q));
      if (npc_now != 0) saw_nonzero_npc = 1;
      if (saw_nonzero_npc && npc_now == 0 && !logged_zero_npc) {
        logged_zero_npc = 1;
        std::cerr << "[first0] t=" << main_time << " act=" << act_now << "\n";
      }
#endif
    }
    // Hart-1 on-trap instrumentation (CVA6_H1_TRAP=1) is currently disabled
    // because the extra SMT tracking probes (icache_hart_q, killed_response,
    // etc.) were reverted with the frontend investigation.  The CVA6_H1_TRAP
    // environment variable still stops the simulation at t=200900 below.

    if (std::getenv("CVA6_H1_TRAP") != nullptr && main_time >= 200900) {
      break;
    }

    // Honor -m / +max-cycles= (parsed above). Without this the TB never times
    // out on bare-metal/OpenSBI images that lack a tohost handshake.
    if (main_time >= max_cycles) {
      budget_exit = true;
      break;
    }
    // Soft-ladder soak-exit + optional parameterized trace (g6lc_tb_trace.h).
    // Default exits: cookie 51b1babe, pin mepc/mcause, dual-WFI.
    // CVA6_TRACE / CVA6_TRACE_SPEC / CVA6_TRACE_FILE add log/exit rules.
    // Do not stop on 51b1c001 (cave lui before addi).
    {
      static int spec_ready = 0;
      static int soak_on = 0;
      static int cookie_on = 0;
      static int wfi_on = 1;
      static int trace_on = 0;
      static int have_log = 0;
      static int have_commit = 0;
      static int have_hold = 0;
      static int have_wrack = 0;
      static unsigned poll_mask = 2047;
      static int wfi_hits = 0;
      static std::vector<G6lcTraceRule> rules;
      if (!spec_ready) {
        // G1de: "0" disables (soak_common contract). Presence-only
        // treated CVA6_COOKIE_EXIT=0 as on and hid post-cookie HSM.
        auto env_on = [](const char *n) -> int {
          const char *p = std::getenv(n);
          return (p && p[0] && p[0] != '0') ? 1 : 0;
        };
        cookie_on = env_on("CVA6_COOKIE_EXIT");
        wfi_on = 1;
        if (const char *p = std::getenv("CVA6_WFI_EXIT"))
          wfi_on = (p[0] && p[0] != '0') ? 1 : 0;
        soak_on = env_on("CVA6_SOAK_EXIT");
        trace_on = std::getenv("CVA6_TRACE") != nullptr ||
                   std::getenv("CVA6_TRACE_SPEC") != nullptr ||
                   std::getenv("CVA6_TRACE_FILE") != nullptr;
        uint64_t pin_mepc = 0x800129f8ULL, pin_mcause = 4;
        if (const char *p = std::getenv("CVA6_PIN_MEPC"))
          pin_mepc = std::strtoull(p, nullptr, 0);
        if (const char *p = std::getenv("CVA6_PIN_MCAUSE"))
          pin_mcause = std::strtoull(p, nullptr, 0);
        if (const char *p = std::getenv("CVA6_SOAK_POLL")) {
          unsigned per = (unsigned)std::strtoul(p, nullptr, 0);
          if (per >= 64 && per <= 65536)
            poll_mask = per - 1;
        }
        if (cookie_on || soak_on)
          g6lc_default_exits(&rules, pin_mepc, pin_mcause, cookie_on, wfi_on);
        if (const char *p = std::getenv("CVA6_TRACE_SPEC"))
          g6lc_parse_text(p, &rules);
        if (const char *p = std::getenv("CVA6_TRACE_FILE"))
          g6lc_parse_file(p, &rules);
        for (const auto &r : rules) {
          if (r.kind >= G6LC_LOG_NPC) have_log = 1;
          if (r.kind == G6LC_LOG_COMMIT || r.kind == G6LC_LOG_HOLD)
            have_commit = 1;
          if (r.kind == G6LC_LOG_HOLD) have_hold = 1;
          if (r.kind == G6LC_LOG_WRACK) have_wrack = 1;
        }
        spec_ready = 1;
      }
      bool poll = (main_time > 10000) && ((main_time & poll_mask) == 0);
      bool tick = poll || (trace_on && have_log);
#if (VERILATOR_VERSION_INTEGER >= 5000000)
      if (main_time < 64) {
        auto gpr0 = [&](int n) -> uint64_t {
          const auto &rf = top->rootp->G6LC_TB_RF(G6LC_CVA6_C0, 0);
          return (uint64_t)rf[2 * n] | ((uint64_t)rf[2 * n + 1] << 32);
        };
        uint64_t npc = (uint64_t)top->rootp->G6LC_CVA6_C0(i_frontend__DOT__npc_q);
        uint64_t mepc0 = (uint64_t)top->rootp->G6LC_TB_CSR(G6LC_CVA6_C0, 0, mepc_q);
        uint64_t mcause0 = (uint64_t)top->rootp->G6LC_TB_CSR(G6LC_CVA6_C0, 0, mcause_q);
        std::cerr << std::hex << "[boot] t=" << main_time << " npc=0x" << npc
                  << " mepc=0x" << mepc0 << " mcause=" << mcause0
                  << " s0=0x" << gpr0(8) << " a5=0x" << gpr0(15)
                  << std::dec << "\n";
      }
#endif
      if (tick && !rules.empty()) {
        auto *cbytes = reinterpret_cast<const uint8_t *>(MEM);
        auto rd64 = [&](size_t off) -> uint64_t {
          uint64_t v = 0;
          for (int i = 0; i < 8; i++)
            v |= (uint64_t)cbytes[off + i] << (8 * i);
          return v;
        };
#if (VERILATOR_VERSION_INTEGER >= 5000000)
        uint64_t npc = (uint64_t)top->rootp->G6LC_CVA6_C0(i_frontend__DOT__npc_q);
        uint64_t mepc0 = (uint64_t)top->rootp->G6LC_TB_CSR(G6LC_CVA6_C0, 0, mepc_q);
        uint64_t mcause0 = (uint64_t)top->rootp->G6LC_TB_CSR(G6LC_CVA6_C0, 0, mcause_q);
        uint64_t mepc1 = (uint64_t)G6LC_TB_H1(top->rootp->G6LC_TB_CSR(G6LC_CVA6_C0, 1, mepc_q));
        uint64_t mcause1 = (uint64_t)G6LC_TB_H1(top->rootp->G6LC_TB_CSR(G6LC_CVA6_C0, 1, mcause_q));
        unsigned wfi0 = (unsigned)top->rootp->G6LC_TB_CSR(G6LC_CVA6_C0, 0, wfi_q);
        unsigned wfi1 = (unsigned)G6LC_TB_H1(top->rootp->G6LC_TB_CSR(G6LC_CVA6_C0, 1, wfi_q));
        uint64_t cpc = 0;
        uint64_t cpc1 = 0;
        unsigned cack = 0;
        unsigned cdrop = 0;
        if (have_commit) {
          // G1fg: commit_instr_o is [NrCommitPorts-1:0] scoreboard_entry_t,
          // packed from bit 0. sbe.pc is the struct MSB (VLEN=64).
          // Verilator VlWide pads to 32-bit words (2×465 sits in 960 bits),
          // so (words*32)/2 is NOT sbe width — W=480 overshoots into the
          // next port and the MSB-64 is not a DRAM PC. Scanning that
          // padded slice from lo then hits bp.predict_address (shared
          // address-FIFO head, e.g. 0x80012888) before sbe.pc (0x80012990).
          // Derive sbe_w from mem_q: 16 × {issued,cancelled,fpr,sbe}.
          const auto &ci = top->rootp->G6LC_CVA6_C0(issue_stage_i__DOT____Vcellout__i_scoreboard__commit_instr_o);
          const auto &mq_w = top->rootp->G6LC_CVA6_C0(
              issue_stage_i__DOT__i_scoreboard__DOT__mem_q);
          int mwords_w = (int)(sizeof(mq_w) / sizeof(mq_w[0]));
          int sbe_w = (mwords_w * 32) / 16 - 3;
          auto bits64 = [&](int base) -> uint64_t {
            uint64_t v = 0;
            for (int i = 0; i < 64; i++)
              if ((ci[(base + i) / 32] >> ((base + i) % 32)) & 1u)
                v |= (uint64_t)1 << i;
            return v;
          };
          auto port_pc = [&](int port) -> uint64_t {
            if (sbe_w < 64) return 0;
            return bits64((port + 1) * sbe_w - 64);
          };
          cpc = port_pc(0);
          cpc1 = port_pc(1);
          cack = (unsigned)top->rootp->G6LC_CVA6_C0(commit_ack);
          cdrop = (unsigned)top->rootp->G6LC_CVA6_C0(commit_drop_id_commit);
        }
        auto gpr = [&](unsigned hart, int n) -> uint64_t {
          if (hart == 0) {
            const auto &rf = top->rootp->G6LC_TB_RF(G6LC_CVA6_C0, 0);
            return (uint64_t)rf[2 * n] | ((uint64_t)rf[2 * n + 1] << 32);
          }
#if defined(G6LC_TB_BANKED)
          const auto &rf = top->rootp->G6LC_TB_RF(G6LC_CVA6_C0, 1);
          return (uint64_t)rf[2 * n] | ((uint64_t)rf[2 * n + 1] << 32);
#else
          return 0;
#endif
        };
        static int boot_wait_logs0 = 0;
        static int boot_wait_logs1 = 0;
        if (have_commit && (cack & 1u) && cpc >= 0x800002e8ULL && cpc <= 0x800002f6ULL && boot_wait_logs0 < 40) {
          std::cerr << std::hex << "[boot_wait0] @" << main_time << " cpc=0x" << cpc
                    << " t0=0x" << gpr(0, 5) << " t1=0x" << gpr(0, 6) << " t2=0x" << gpr(0, 7)
                    << std::dec << "\n";
          boot_wait_logs0++;
        }
        if (have_commit && (cack & 2u) && cpc >= 0x800002e8ULL && cpc <= 0x800002f6ULL && boot_wait_logs1 < 40) {
          std::cerr << std::hex << "[boot_wait1] @" << main_time << " cpc=0x" << cpc
                    << " t0=0x" << gpr(1, 5) << " t1=0x" << gpr(1, 6) << " t2=0x" << gpr(1, 7)
                    << std::dec << "\n";
          boot_wait_logs1++;
        }
        // Trapping visit: dump ID/SB handshake. id_pc uses the same
        // sbe_w as commit (do not scan from lo — bp tgt leak).
        // SMT/SS debug only: issue_entry_*_id_issue are DCE'd when the
        // target has SuperscalarEn=0 or NrHarts==1.
#if defined(G6LC_TB_BANKED) && defined(G6LC_TRACE_LEGACY_IDSB)
        static int idsb_logs = 0;
        if (trace_on && main_time >= 103000 && main_time <= 180000 &&
            idsb_logs < 250) {
          unsigned flu = (unsigned)top->rootp->G6LC_CVA6_C0(flush_unissued_instr_ctrl_id);
          unsigned fif = (unsigned)top->rootp->G6LC_CVA6_C0(flush_ctrl_if);
          unsigned fid = (unsigned)top->rootp->G6LC_CVA6_C0(flush_ctrl_id);
          unsigned fex = (unsigned)top->rootp->G6LC_CVA6_C0(flush_ctrl_ex);
          unsigned dv = (unsigned)top->rootp->G6LC_CVA6_C0(issue_entry_valid_id_issue);
          unsigned dack = (unsigned)top->rootp->G6LC_CVA6_C0(issue_instr_issue_id);
          const auto &ie = top->rootp->G6LC_CVA6_C0(issue_entry_id_issue);
          const auto &mq_id = top->rootp->G6LC_CVA6_C0(
              issue_stage_i__DOT__i_scoreboard__DOT__mem_q);
          int sbe_id = (int)(sizeof(mq_id) / sizeof(mq_id[0])) * 32 / 16 - 3;
          auto ibits64 = [&](int base) -> uint64_t {
            uint64_t v = 0;
            for (int i = 0; i < 64; i++)
              if ((ie[(base + i) / 32] >> ((base + i) % 32)) & 1u)
                v |= (uint64_t)1 << i;
            return v;
          };
          auto id_pc = [&](int port) -> uint64_t {
            if (sbe_id < 64) return 0;
            return ibits64((port + 1) * sbe_id - 64);
          };
          uint64_t ipc0 = id_pc(0);
          uint64_t ipc1 = id_pc(1);
          uint64_t pcex = (uint64_t)top->rootp->G6LC_CVA6_C0(pc_id_ex);
          unsigned iptr = (unsigned)top->rootp->G6LC_CVA6_C0(
              issue_stage_i__DOT__i_scoreboard__DOT__issue_pointer_q);
          unsigned cptr = (unsigned)top->rootp->G6LC_CVA6_C0(
              issue_stage_i__DOT__i_scoreboard__DOT__commit_pointer_q);
          auto in_tail_pc = [](uint64_t pc) -> bool {
            uint64_t p = pc & 0xffffffffULL;
            return (p >= 0x80012c00ULL && p <= 0x80012c70ULL)
                || (p >= 0x80012b10ULL && p <= 0x80012b20ULL)
                || (p >= 0x80017fd0ULL && p <= 0x80018010ULL)
                || (p >= 0x80013940ULL && p <= 0x80013990ULL);
          };
          if ((dv || dack || flu || fif || fex) &&
              (in_tail_pc(ipc0) || in_tail_pc(ipc1) || in_tail_pc(pcex))) {
            unsigned alloc = dv & dack & (flu ? 0u : 3u);
            std::cerr << std::hex << "[id_sb] t=" << std::dec << main_time
                      << std::hex << " pc0=0x" << ipc0 << " pc1=0x" << ipc1
                      << " pcex=0x" << pcex
                      << " dv=" << dv << " ack=" << dack << " alloc=" << alloc
                      << " flu=" << flu << " fif=" << fif << " fid=" << fid
                      << " fex=" << fex
                      << " ip=" << iptr << " cp=" << cptr
                      << std::dec << "\n";
            idsb_logs++;
          }
          // Per-slot sbe.pc: sb_mem_t is {issued,cancelled,fpr,sbe} with
          // sbe.pc at the sbe MSB. Slot index is the trans_id. Do not scan
          // the whole entry (jal bp.predict_address is 12888 too).
          const auto &mq = top->rootp->G6LC_CVA6_C0(
              issue_stage_i__DOT__i_scoreboard__DOT__mem_q);
          int mwords = (int)(sizeof(mq) / sizeof(mq[0]));
          int nent = 16;
          int EW = (mwords * 32) / nent;
          auto mbit = [&](int b) -> unsigned {
            if (b < 0 || b >= mwords * 32) return 0;
            return (mq[b / 32] >> (b % 32)) & 1u;
          };
          auto mbits64 = [&](int lo) -> uint64_t {
            uint64_t v = 0;
            for (int i = 0; i < 64; i++)
              if (mbit(lo + i)) v |= (uint64_t)1 << i;
            return v;
          };
          bool snap = (main_time == 103624 || main_time == 103628 ||
                       main_time == 103632 || main_time == 103636 ||
                       main_time == 103640 || main_time == 103644);
          if ((cack || cdrop) &&
              ((main_time >= 103620 && main_time <= 103650) ||
               (main_time >= 157900 && main_time <= 157930))) {
            std::cerr << "[sb_iss] t=" << main_time
                      << " ip=" << iptr << " cp=" << cptr
                      << " ack=" << cack << " drop=" << cdrop
                      << std::hex << " c0=0x" << cpc << " c1=0x" << cpc1
                      << " iss=";
            for (int e = 0; e < nent; e++) {
              int ehi = (e + 1) * EW;
              if (mbit(ehi - 1))
                std::cerr << e << ":0x" << mbits64(ehi - 67) << ",";
            }
            std::cerr << std::dec << "\n";
            idsb_logs++;
          }
          if (snap) {
            std::cerr << "[sb_pc] t=" << main_time
                      << " ip=" << iptr << " cp=" << cptr
                      << " EW=" << EW << "\n";
            for (int e = 0; e < nent; e++) {
              int elo = e * EW;
              int ehi = elo + EW;
              unsigned iss = mbit(ehi - 1);
              unsigned can = mbit(ehi - 2);
              uint64_t pc3 = mbits64(ehi - 67);
              uint64_t pcm = mbits64(ehi - 64);
              std::cerr << std::dec << "[sb_pc] t=" << main_time
                        << " e=" << e << " iss=" << iss << " can=" << can
                        << std::hex << " pc=0x" << pc3 << " msb=0x" << pcm
                        << std::dec << "\n";
            }
          }
        }
#endif // G6LC_TB_BANKED (idsb issue-entry debug)
        // Leftover-complete 12958 vs sequential 12960. replay_addr /
        // serving_unaligned / is_mispredict DCE; k1 = misp|flush|replay.
        // npc_q and icache_vaddr_q are flops (not DCE).
        // These signals only exist in the fetch_B (G6LC_FETCH_B) frontend.
#if 0  // G6LC_FETCH_B debug signals are not in the verilated public interface; re-enable after adding /* verilator public */ to the wires.
        if (trace_on && ((main_time >= 103000 && main_time <= 180000) ||
                         (main_time >= 2448000 && main_time <= 2453000))) {
          unsigned fifk = (unsigned)top->rootp->G6LC_CVA6_C0(flush_ctrl_if);
          unsigned repl = (unsigned)top->rootp->G6LC_CVA6_C0(
              i_frontend__DOT__replay);
          unsigned k1 = (unsigned)top->rootp->G6LC_CVA6_C0(
              i_frontend__DOT__kill_s1);
          unsigned k2 = (unsigned)top->rootp->G6LC_CVA6_C0(
              i_frontend__DOT__kill_s2);
          unsigned bpf = (unsigned)top->rootp->G6LC_CVA6_C0(
              i_frontend__DOT__bp_fire);
          unsigned pend = (unsigned)top->rootp->G6LC_CVA6_C0(
              i_frontend__DOT__leftover_pending);
          unsigned lov = (unsigned)top->rootp->G6LC_CVA6_C0(
              i_frontend__DOT__leftover_valid);
          unsigned qfull = (unsigned)top->rootp->G6LC_CVA6_C0(
              i_frontend__DOT__i_instr_queue__DOT__instr_queue_full);
          uint64_t knpc = (uint64_t)top->rootp->G6LC_CVA6_C0(
              i_frontend__DOT__npc_q);
          uint64_t kvaddr = (uint64_t)top->rootp->G6LC_CVA6_C0(
              i_frontend__DOT__icache_vaddr_q);
          uint64_t btgt = (uint64_t)top->rootp->G6LC_CVA6_C0(
              i_frontend__DOT__bp_tgt_q);
          uint64_t lpc = (uint64_t)top->rootp->G6LC_CVA6_C0(
              i_frontend__DOT__leftover_pc);
          unsigned misp = k1 && !repl && !fifk;
          uint64_t knpc32 = knpc & 0xffffffffULL;
          bool in_tail = (knpc32 >= 0x80012c00ULL && knpc32 <= 0x80012c70ULL)
              || (knpc32 >= 0x80012b10ULL && knpc32 <= 0x80012b20ULL)
              || (knpc32 >= 0x80012950ULL && knpc32 <= 0x80012972ULL)
              || (knpc32 >= 0x80017fd0ULL && knpc32 <= 0x80018010ULL)
              || (knpc32 >= 0x80013940ULL && knpc32 <= 0x80013990ULL)
              || (knpc32 >= 0x80017f10ULL && knpc32 <= 0x80017f90ULL)
              || (knpc32 >= 0x80005d6eULL && knpc32 <= 0x80006320ULL)
              || (knpc32 >= 0x8000eeecULL && knpc32 <= 0x8000eeffULL);
          if ((misp || repl || k1 || k2 || bpf || pend || lov) && in_tail) {
            std::cerr << "[kill] t=" << main_time
                      << " misp=" << misp << " replay=" << repl
                      << " fif=" << fifk << " bp=" << bpf
                      << " k1=" << k1 << " k2=" << k2
                      << " pend=" << pend << " lov=" << lov
                      << " full=" << qfull
                      << std::hex << " npc=0x" << knpc
                      << " vq=0x" << kvaddr
                      << " tgt=0x" << btgt
                      << " lpc=0x" << lpc << std::dec
                      << "\n";
          }
        }
#endif
        bool do_exit = false;
        for (auto &r : rules) {
          if (r.kind == G6LC_EXIT_COOKIE && poll) {
            uint64_t cw = rd64((size_t)r.off);
            uint32_t want = (uint32_t)r.val;
            if ((uint32_t)cw == want || (uint32_t)(cw >> 32) == want) {
              std::cerr << std::hex << "[cookie-exit] t=" << std::dec << main_time
                        << " [1000]=0x" << std::hex << cw << std::dec << "\n";
              do_exit = true;
              break;
            }
          } else if (r.kind == G6LC_EXIT_PIN && poll && soak_on) {
            bool hit0 = (mepc0 & 0xffffffffULL) == (r.lo & 0xffffffffULL) &&
                        (mcause0 & 0xffULL) == (r.val & 0xffULL);
            bool hit1 = (mepc1 & 0xffffffffULL) == (r.lo & 0xffffffffULL) &&
                        (mcause1 & 0xffULL) == (r.val & 0xffULL);
            if (hit0 || hit1) {
              std::cerr << std::hex << "[pin-exit] t=" << std::dec << main_time
                        << " mepc0=0x" << std::hex << mepc0
                        << " mcause0=0x" << mcause0
                        << " mepc1=0x" << mepc1
                        << " mcause1=0x" << mcause1 << std::dec << "\n";
              do_exit = true;
              break;
            }
          } else if (r.kind == G6LC_EXIT_WFI && poll && soak_on) {
            if (main_time > r.after && wfi0 && wfi1)
              wfi_hits++;
            else
              wfi_hits = 0;
            if (wfi_hits >= (int)(r.hits ? r.hits : 8)) {
              std::cerr << "[wfi-exit] t=" << main_time << "\n";
              do_exit = true;
              break;
            }
          } else if (r.kind == G6LC_EXIT_NPC && poll && soak_on) {
            if (main_time > r.after && g6lc_in_win(npc, r.lo, r.hi)) {
              std::cerr << std::hex << "[npc-exit] t=" << std::dec << main_time
                        << " tag=" << r.tag << " npc=0x" << std::hex << npc
                        << std::dec << "\n";
              do_exit = true;
              break;
            }
          } else if (trace_on && r.seen < r.maxn) {
            if (r.after != 0 && main_time < r.after)
              continue;
            bool hit = false;
            uint64_t loc = npc;
            if (r.kind == G6LC_LOG_NPC && g6lc_in_win(npc, r.lo, r.hi)) {
              // Poll as well so a stuck npc still samples after= hang window.
              hit = r.last_npc != (npc & 0xffffffffULL) || poll;
              loc = npc;
            } else if (r.kind == G6LC_LOG_COMMIT && (cack || cdrop)) {
              // Both commit ports. Architectural ack hides I13 drop
              // (commit_ack = macro_ack & ~drop) so 12976–12992 vanished.
              uint64_t pcs[2] = {cpc, cpc1};
              for (int p = 0; p < 2; p++) {
                unsigned ack_p = (cack >> p) & 1u;
                unsigned drop_p = (cdrop >> p) & 1u;
                if ((ack_p || drop_p) && g6lc_in_win(pcs[p], r.lo, r.hi) &&
                    r.seen < r.maxn) {
                  std::cerr << std::hex << "[trace] t=" << std::dec << main_time
                            << " tag=" << r.tag << std::hex << " loc=0x" << pcs[p]
                            << " p=" << p << " ack=" << cack << " drop=" << cdrop;
                  if (r.gpr_mask) {
                    for (int n = 1; n < 32; n++)
                      if (r.gpr_mask & (1u << n))
                        std::cerr << " x" << std::dec << n << std::hex << "=0x"
                                  << gpr(r.hart, n);
                  }
                  std::cerr << std::dec << "\n";
                  r.seen++;
                }
              }
              continue;
            } else if (r.kind == G6LC_LOG_MEM && poll) {
              hit = true;
              loc = rd64((size_t)r.off);
            } else if (r.kind == G6LC_LOG_HOLD && have_hold) {
              // Ports (load_paddr_i, st_fwd_*) are not public in the
              // Verilator v5.008 model. Internals g1ao_hold_* are.
              // g1ao_hold_* only survive DCE when SuperscalarEn && NrHarts>1.
              unsigned hv = (unsigned)G6LC_TB_LEGACY_HOLD(top->rootp->G6LC_CVA6_C0(
                  ex_stage_i__DOT__lsu_i__DOT__i_store_unit__DOT__store_buffer_i__DOT__g1ao_hold_v_q));
              unsigned hh = (unsigned)G6LC_TB_LEGACY_HOLD(top->rootp->G6LC_CVA6_C0(
                  ex_stage_i__DOT__lsu_i__DOT__i_store_unit__DOT__store_buffer_i__DOT__g1ao_hold_hit));
              unsigned hbe = (unsigned)G6LC_TB_LEGACY_HOLD(top->rootp->G6LC_CVA6_C0(
                  ex_stage_i__DOT__lsu_i__DOT__i_store_unit__DOT__store_buffer_i__DOT__g1ao_hold_be_q));
              uint64_t hpa = (uint64_t)G6LC_TB_LEGACY_HOLD(top->rootp->G6LC_CVA6_C0(
                  ex_stage_i__DOT__lsu_i__DOT__i_store_unit__DOT__store_buffer_i__DOT__g1ao_hold_pa_q));
              uint64_t hdata = (uint64_t)G6LC_TB_LEGACY_HOLD(top->rootp->G6LC_CVA6_C0(
                  ex_stage_i__DOT__lsu_i__DOT__i_store_unit__DOT__store_buffer_i__DOT__g1ao_hold_data_q));
              bool in_win = (cack & 1u) && g6lc_in_win(cpc, r.lo, r.hi);
              uint64_t filt = r.off;
              bool pa_hit = (filt == 0) ||
                            ((hpa & 0xffffffffULL) == (filt & 0xffffffffULL));
              bool live = hv || hh;
              bool chg = hv != r.last_hold_v || hh != r.last_hold_hit ||
                         hpa != r.last_hold_pa || hdata != r.last_hold_data;
              bool fall = r.last_hold_v && !hv;
              if (in_win || ((live || fall) && pa_hit && chg) ||
                  (live && pa_hit && poll)) {
                loc = in_win ? cpc : hpa;
                std::cerr << std::hex << "[trace] t=" << std::dec << main_time
                          << " tag=" << r.tag << std::hex << " loc=0x" << loc
                          << " v=" << hv << " hit=" << hh << " be=0x" << hbe
                          << " pa=0x" << hpa << " data=0x" << hdata
                          << std::dec << "\n";
                r.seen++;
                r.last_npc = npc & 0xffffffffULL;
                r.last_hold_v = hv;
                r.last_hold_hit = hh;
                r.last_hold_pa = hpa;
                r.last_hold_data = hdata;
                continue;
              }
              r.last_hold_v = hv;
              r.last_hold_hit = hh;
              r.last_hold_pa = hpa;
              r.last_hold_data = hdata;
#ifdef G6LC_TRACE_WT_WBUFFER
            } else if (r.kind == G6LC_LOG_WRACK && have_wrack) {
              unsigned wreq = (unsigned)top->rootp->G6LC_CVA6_C0(
                  gen_cache_wt__DOT__i_cache_subsystem__DOT__i_wt_dcache__DOT__wr_req);
              unsigned wack = (unsigned)top->rootp->G6LC_CVA6_C0(
                  gen_cache_wt__DOT__i_cache_subsystem__DOT__i_wt_dcache__DOT__wr_ack);
              unsigned wbe = (unsigned)top->rootp->G6LC_CVA6_C0(
                  gen_cache_wt__DOT__i_cache_subsystem__DOT__i_wt_dcache__DOT__wr_data_be);
              uint64_t wdata = (uint64_t)top->rootp->G6LC_CVA6_C0(
                  gen_cache_wt__DOT__i_cache_subsystem__DOT__i_wt_dcache__DOT__wr_data);
              bool live = wreq != 0;
              bool chg = wreq != r.last_wr_req || wack != r.last_wr_ack ||
                         wdata != r.last_wr_data;
              if ((live && chg) || (live && poll)) {
                loc = wdata;
                std::cerr << std::hex << "[trace] t=" << std::dec << main_time
                          << " tag=" << r.tag << std::hex << " loc=0x" << loc
                          << " req=0x" << wreq << " ack=" << wack
                          << " be=0x" << wbe << " data=0x" << wdata
                          << std::dec << "\n";
                r.seen++;
                r.last_wr_req = wreq;
                r.last_wr_ack = wack;
                r.last_wr_data = wdata;
                continue;
              }
              r.last_wr_req = wreq;
              r.last_wr_ack = wack;
              r.last_wr_data = wdata;
#endif
            } else if (r.kind == G6LC_LOG_GPR) {
              bool any_pc = (r.lo == 0 && r.hi == ~0ULL);
              if (any_pc && r.gpr_mask) {
                // Edge: any watched GPR changed. Mini-wide ra/t2
                // writes without a commit-PC bit extract.
                for (int n = 1; n < 32; n++) {
                  if (!(r.gpr_mask & (1u << n))) continue;
                  uint64_t now = gpr(r.hart, n);
                  if (r.last_gpr_valid && r.last_gpr[n] != now) hit = true;
                  r.last_gpr[n] = now;
                }
                r.last_gpr_valid = 1;
                loc = npc;
              } else if (any_pc)
                hit = poll;
              else
                hit = g6lc_in_win(npc, r.lo, r.hi) &&
                      (r.last_npc != (npc & 0xffffffffULL));
              loc = npc;
            }
            if (hit) {
              std::cerr << std::hex << "[trace] t=" << std::dec << main_time
                        << " tag=" << r.tag << std::hex << " loc=0x" << loc;
              if (r.gpr_mask) {
                for (int n = 1; n < 32; n++)
                  if (r.gpr_mask & (1u << n))
                    std::cerr << " x" << std::dec << n << std::hex << "=0x"
                              << gpr(r.hart, n);
              }
              std::cerr << std::dec << "\n";
              r.seen++;
              r.last_npc = npc & 0xffffffffULL;
            }
          }
        }
        if (do_exit) break;
#else
        (void)cbytes;
        (void)rd64;
#endif
      }
    }
    if (probe && main_time == 500) {
      std::cerr << std::hex << "[preload] @500"
                << " MEM[0]=0x" << mem_half(0)
                << " MEM[0x884]=0x" << mem_half(0x884)
                << " MEM[0x886]=0x" << mem_half(0x886)
                << std::dec << "\n";
    }
    // Hang-7 event probe (every cycle, capped): use COMMIT PC (not npc) so RF
    // matches retired state. Also filter mentry to alias-shaped calls.
    // Compile-time gated: see CVA6_MC_PC_PROBE_COMPILE at file head.
#if defined(CVA6_MC_PC_PROBE_COMPILE) && (VERILATOR_VERSION_INTEGER >= 5000000)
    // Window extended: smt2 dual often dies 100k–2M (not only <400k).
    if (std::getenv("CVA6_MC_PC_PROBE") != nullptr && main_time >= 10000 && main_time <= 2500000) {
      static int path0_logs = 0;
      static int mentry_logs = 0;
      static int alias_logs = 0;
      const auto &ci_ev = top->rootp->G6LC_CVA6_C0(issue_stage_i__DOT____Vcellout__i_scoreboard__commit_instr_o);
      int words_ev = (int)(sizeof(ci_ev) / sizeof(ci_ev[0]));
      int W_ev = (words_ev * 32) / 2;
      int pc0_ev = W_ev - 64;
      uint64_t cpc_ev = 0;
      for (int i = 0; i < 64; i++)
        if ((ci_ev[(pc0_ev + i) / 32] >> ((pc0_ev + i) % 32)) & 1u)
          cpc_ev |= (uint64_t)1 << i;
      auto cack_ev = top->rootp->G6LC_CVA6_C0(commit_ack);
      // SMT banked RF: hart0 bank (gen_single_bank removed)
      const auto &rf_ev = top->rootp
          ->G6LC_TB_RF(G6LC_CVA6_C0, 0);
      auto ge = [&](int n) -> uint64_t {
        return (uint64_t)rf_ev[2 * n] | ((uint64_t)rf_ev[2 * n + 1] << 32);
      };
      // Only log when something is actually committing
      bool committing = ((unsigned)cack_ev) != 0;
      // fw_payload 2026-08: fdt_path_offset_namelen @0x80013778
      // lbu path[0]@0x8001379a, li a1@0x8001379e, bne@0x800137a8
      if (committing && cpc_ev >= 0x8001379aULL && cpc_ev <= 0x800137b0ULL && path0_logs < 80) {
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
      // sbi_memchr @0x80004c4a; alias jal ret = 0x80013818
      uint64_t ra_ev = ge(1), a0_ev = ge(10), a1_ev = ge(11), a2_ev = ge(12);
      bool alias_shaped = (ra_ev == 0x80013818ULL) || (a0_ev < 0x10000ULL && main_time > 100000) ||
                          (a0_ev == 0xfffffffffffffffcULL);
      if (committing && cpc_ev >= 0x80004c4aULL && cpc_ev <= 0x80004c6aULL &&
          (alias_shaped || main_time > 120000) && mentry_logs < 80) {
        std::cerr << std::hex << "[mentryc] @" << main_time << " cpc=0x" << cpc_ev
                  << " a0=0x" << a0_ev << " a1=0x" << a1_ev << " a2=0x" << a2_ev
                  << " ra=0x" << ra_ev << " s1=0x" << ge(9) << " s3=0x" << ge(19)
                  << std::dec << "\n";
        mentry_logs++;
      }
      // One-shot when we first see alias memchr active (npc in loop + ra)
      auto npc_ev = top->rootp->G6LC_CVA6_C0(i_frontend__DOT__npc_q);
      uint64_t np = (uint64_t)npc_ev;
      if (alias_logs < 5 && ra_ev == 0x80013818ULL &&
          np >= 0x80004c4aULL && np < 0x80004c80ULL &&
          (a0_ev < 0x10000ULL || a0_ev >= 0xffffffffffffff00ULL)) {
        std::cerr << std::hex << "[alias_hang] @" << main_time << " npc=0x" << np
                  << " cpc=0x" << cpc_ev << " a0=0x" << a0_ev << " a1=0x" << a1_ev
                  << " a2=0x" << a2_ev << " a5=0x" << ge(15) << " s1=0x" << ge(9)
                  << " s2=0x" << ge(18) << " s3=0x" << ge(19) << " ra=0x" << ra_ev
                  << std::dec << "\n";
        alias_logs++;
      }
      // Alias setup: 0x8001380e ret … 0x80013814 jal memchr; also error ret 0x8001380e
      static int aset_logs = 0;
      if (committing && cpc_ev >= 0x800137f0ULL && cpc_ev <= 0x80013830ULL &&
          aset_logs < 80) {
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
      // Hang-7: EX resolve of path_offset ret (0x8001377e) / nearby CF —
      // compare predict vs architectural target and whether bmiss fires.
      // bp_resolve packing (MSB first): valid[135], pc[134:71], target[70:7],
      // misp[6], taken[5], cf[4:2], hart[1], ckpt_restore[0].
      // branchpredict_sbe: cf[66:64], predict_address[63:0].
      static int retex_logs = 0;
      auto &rb = top->rootp
          ->G6LC_CVA6_C0(ex_stage_i__DOT____Vcellout__branch_unit_i__resolved_branch_o);
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
          ->G6LC_CVA6_C0(issue_stage_i__DOT__i_issue_read_operands__DOT__branch_valid_q);
      auto pc_ex = (uint64_t)top->rootp
          ->G6LC_CVA6_C0(pc_id_ex);
      auto &bpv = top->rootp
          ->G6LC_CVA6_C0(issue_stage_i__DOT____Vcellout__i_issue_read_operands__branch_predict_o);
      // predict_address is low 64 of 67-bit sbe
      uint64_t bp_pred = (uint64_t)bpv[0] | (((uint64_t)bpv[1] & 0xffffffffULL) << 32);
      // cf in bits 66:64 → bit 2 of bpv[2]
      unsigned bp_cf = (bpv[2] >> 0) & 0x7u;
      // path_offset_namelen ret @0x8001380e; alias block @0x80013810+
      bool ret_window =
          (pc_ex == 0x8001380eULL) || (rb_valid && rb_pc == 0x8001380eULL) ||
          (pc_ex >= 0x800137f8ULL && pc_ex <= 0x80013820ULL && (unsigned)bv_q);
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
    // Multi-core hang probe: PC + I$/L2/hub/ROM/DRAM.
    // Compile: -DCVA6_MC_PC_PROBE_COMPILE  Runtime: CVA6_MC_PC_PROBE=1
    // Dense early samples catch L2/AMO hangs; late samples track OpenSBI progress
    // (historical SUCCESS ~6.5M cycles on smt2; server_math still soaking).
#if defined(CVA6_MC_PC_PROBE_COMPILE)
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
      auto npc0 = top->rootp->G6LC_CVA6_C0(i_frontend__DOT__npc_q);
#if !defined(CVA6_PROBE_NO_CORE1)
      auto npc1 = top->rootp->G6LC_CVA6_C1(i_frontend__DOT__npc_q);
#else
      uint64_t npc1 = 0;
#endif
      // Hang-4: instr_queue stores realign PC per FIFO word; sequential pc_q is
      // no longer on the output path (Verilator DCE). Probe issue-port0 address
      // from packed fetch_entry_o (see fetch_entry_t: address near head).
      const auto &fe0 = top->rootp->G6LC_CVA6_C0(i_frontend__DOT____Vcellout__i_instr_queue__fetch_entry_o);
      // Dual-issue pack: port0 in low bits. address is VLEN at a stable offset;
      // fall back to npc if layout shifts. Bits [63:0] commonly hold address
      // when address is the first wide field after instruction in some packs —
      // use commit-adjacent npc as reliable IQ progress proxy.
      uint64_t pc_iq0 = (uint64_t)npc0;
      auto ic0 = top->rootp->G6LC_CVA6_C0(gen_cache_hpd__DOT__i_cache_subsystem__DOT__i_g6lc_icache__DOT__state_q);
#if !defined(CVA6_PROBE_NO_CORE1)
      auto ic1 = top->rootp->G6LC_CVA6_C1(gen_cache_hpd__DOT__i_cache_subsystem__DOT__i_g6lc_icache__DOT__state_q);
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
      auto pend0 = top->rootp->G6LC_CVA6_C0(gen_cache_hpd__DOT__i_cache_subsystem__DOT__genblk1__DOT__i_axi_arbiter__DOT__icache_miss_pending_q);
      auto ar0 = top->rootp->G6LC_CVA6_C0(gen_cache_hpd__DOT__i_cache_subsystem__DOT__genblk1__DOT__i_axi_arbiter__DOT____Vcellout__i_hpdcache_mem_to_axi_read__axi_ar_valid_o);
#if !defined(CVA6_PROBE_NO_CORE1)
      auto pend1 = top->rootp->G6LC_CVA6_C1(gen_cache_hpd__DOT__i_cache_subsystem__DOT__genblk1__DOT__i_axi_arbiter__DOT__icache_miss_pending_q);
      auto ar1 = top->rootp->G6LC_CVA6_C1(gen_cache_hpd__DOT__i_cache_subsystem__DOT__genblk1__DOT__i_axi_arbiter__DOT____Vcellout__i_hpdcache_mem_to_axi_read__axi_ar_valid_o);
#else
      unsigned pend1 = 0, ar1 = 0;
#endif
      // DRAM path: axi2mem IDLE=0 READ=1 WRITE=2 SEND_B=3 WAIT_WVALID=4
      // Same relocation as MEM above: axi2mem now lives inside
      // g6lc_ai_dram_backend's class-0 single-channel arm, keeping its instance
      // name. This block is behind CVA6_MC_PC_PROBE_COMPILE so it was not part
      // of the compile failure, but it had rotted the same way; fixed here so
      // enabling the probe does not rediscover it. Untested (needs that macro).
      auto a2m = top->rootp->ariane_testharness__DOT__i_dram_backend__DOT__gen_sim_axi__DOT__i_axi2mem__DOT__state_q;
      auto a2m_cnt = top->rootp->ariane_testharness__DOT__i_dram_backend__DOT__gen_sim_axi__DOT__i_axi2mem__DOT__cnt_q;
      auto demux_lock = top->rootp->ariane_testharness__DOT__i_axi_xbar__DOT__i_xbar__DOT__gen_slv_port_demux__BRA__0__KET____DOT__i_axi_demux__DOT__gen_demux__DOT__lock_ar_valid_q;
      auto demux_ar = top->rootp->ariane_testharness__DOT__i_axi_xbar__DOT__i_xbar__DOT__gen_slv_port_demux__BRA__0__KET____DOT__i_axi_demux__DOT__gen_demux__DOT__ar_valid;
      auto atom_ar = top->rootp->ariane_testharness__DOT__i_axi_riscv_atomics__DOT____Vcellout__i_atomics__mst_ar_valid_o;
      auto atom_rr = top->rootp->ariane_testharness__DOT__i_axi_riscv_atomics__DOT____Vcellout__i_atomics__mst_r_ready_o;
      auto amos_r = top->rootp->ariane_testharness__DOT__i_axi_riscv_atomics__DOT__i_atomics__DOT__i_amos__DOT__r_state_q;
      auto lrsc_r = top->rootp->ariane_testharness__DOT__i_axi_riscv_atomics__DOT__i_atomics__DOT__i_lrsc__DOT__r_state_q;
      // Hang-3: post-fence.i _reset_regs stall (I$ idle/hit, a2m IDLE)
      auto fence_ia = top->rootp->G6LC_CVA6_C0(controller_i__DOT__fence_i_active_q);
      auto no_st = top->rootp->G6LC_CVA6_C0(no_st_pending_commit);
      auto wbuf_e = top->rootp->G6LC_CVA6_C0(dcache_commit_wbuffer_empty);
      auto cack = top->rootp->G6LC_CVA6_C0(commit_ack);
      auto iss_ptr = top->rootp->G6LC_CVA6_C0(issue_stage_i__DOT__i_scoreboard__DOT__issue_pointer_q);
      auto cmt_ptr = top->rootp->G6LC_CVA6_C0(issue_stage_i__DOT__i_scoreboard__DOT__commit_pointer_q);
      auto epc = top->rootp->G6LC_CVA6_C0(epc_commit_pcgen);
      auto mepc = top->rootp->G6LC_TB_CSR(G6LC_CVA6_C0, 0, mepc_q);
      auto mcause = top->rootp->G6LC_TB_CSR(G6LC_CVA6_C0, 0, mcause_q);
      auto mtval = top->rootp->G6LC_TB_CSR(G6LC_CVA6_C0, 0, mtval_q);
      auto wfi = top->rootp->G6LC_TB_CSR(G6LC_CVA6_C0, 0, wfi_q);
      auto flush_if = top->rootp->G6LC_CVA6_C0(flush_ctrl_if);
      auto iq_full = top->rootp->G6LC_CVA6_C0(i_frontend__DOT__i_instr_queue__DOT__instr_queue_full);
      auto iq_rdy = top->rootp->G6LC_CVA6_C0(i_frontend__DOT__instr_queue_ready);
      const auto &ci = top->rootp->G6LC_CVA6_C0(issue_stage_i__DOT____Vcellout__i_scoreboard__commit_instr_o);
      int words_c = (int)(sizeof(ci) / sizeof(ci[0]));
      int W_c = (words_c * 32) / 2;
      int pc0_c = W_c - 64;
      uint64_t cmt_pc = 0;
      for (int i = 0; i < 64; i++)
        if ((ci[(pc0_c + i) / 32] >> ((pc0_c + i) % 32)) & 1u)
          cmt_pc |= (uint64_t)1 << i;
      // MMU / I$ miss path (second hang: ic=READ + a2m=READ orphan)
      auto en_tr = top->rootp->G6LC_CVA6_C0(enable_translation_csr_ex);
      auto en_gtr = top->rootp->G6LC_CVA6_C0(enable_g_translation_csr_ex);
      auto itlb_hit = top->rootp->G6LC_CVA6_C0(ex_stage_i__DOT__lsu_i__DOT__gen_mmu__DOT__i_cva6_mmu__DOT__itlb_lu_hit);
      auto stlb_miss = top->rootp->G6LC_CVA6_C0(ex_stage_i__DOT__lsu_i__DOT__gen_mmu__DOT__i_cva6_mmu__DOT__shared_tlb_miss);
      auto ptw_st = top->rootp->G6LC_CVA6_C0(ex_stage_i__DOT__lsu_i__DOT__gen_mmu__DOT__i_cva6_mmu__DOT__i_ptw__DOT__state_q);
      auto ic_hit = top->rootp->G6LC_CVA6_C0(gen_cache_hpd__DOT__i_cache_subsystem__DOT__i_g6lc_icache__DOT__cl_hit);
      auto ic_inv = top->rootp->G6LC_CVA6_C0(gen_cache_hpd__DOT__i_cache_subsystem__DOT__i_g6lc_icache__DOT__inv_q);
      auto ic_en = top->rootp->G6LC_CVA6_C0(gen_cache_hpd__DOT__i_cache_subsystem__DOT__i_g6lc_icache__DOT__cache_en_q);
      auto a2m_addr = top->rootp->ariane_testharness__DOT__i_dram_backend__DOT__gen_sim_axi__DOT__i_axi2mem__DOT__req_addr_q;
      // ax_req_q: packed {id, addr, len, size, burst}
      const auto &a2m_ax = top->rootp->ariane_testharness__DOT__i_dram_backend__DOT__gen_sim_axi__DOT__i_axi2mem__DOT__ax_req_q;
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
            ->G6LC_TB_RF(G6LC_CVA6_C0, 0);
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

  // Optional post-run DRAM dump for OpenSBI hang diagnostics (CVA6_TRAP_DUMP=1)
  if (std::getenv("CVA6_TRAP_DUMP") != nullptr) {
    auto *bytes = reinterpret_cast<const uint8_t *>(MEM);
    auto rd64 = [&](size_t off) -> uint64_t {
      uint64_t v = 0;
      for (int i = 0; i < 8; i++) v |= (uint64_t)bytes[off + i] << (8 * i);
      return v;
    };
    // R3a phase cookies (0x51b1xxxx) at DRAM+0x1000..; also platform/scratch BSS.
    std::cerr << std::hex << "[trapdump]";
    for (int s = 0; s < 16; s++) {
      uint64_t v = rd64(0x1000 + 8 * s);
      // only print non-zero / cookie-like slots to keep the line short
      if (v != 0)
        std::cerr << " [" << (0x1000 + 8 * s) << "]=" << v;
    }
    std::cerr << " plat_hc=" << (rd64(0x40438) & 0xffffffffULL)
              << " last_hartidx=" << (rd64(0x42064) & 0xffffffffULL)
              << " coldboot_done=" << rd64(0x42018) << std::dec << "\n";
    // R3a cont.9: runtime FDT header + root/cpus tags from DRAM model (host view).
    // Confirms whether path_offset/-4 is software-walk vs corrupted blob.
    {
      auto be32 = [&](size_t off) -> uint32_t {
        return ((uint32_t)bytes[off] << 24) | ((uint32_t)bytes[off + 1] << 16) |
               ((uint32_t)bytes[off + 2] << 8) | (uint32_t)bytes[off + 3];
      };
      const size_t fdt_off = 0x1e000;
      uint32_t mag = be32(fdt_off);
      uint32_t tsz = be32(fdt_off + 4);
      uint32_t off_struct = be32(fdt_off + 8);
      uint32_t off_strings = be32(fdt_off + 12);
      uint32_t ver = be32(fdt_off + 20);
      uint32_t sz_struct = be32(fdt_off + 36);
      uint32_t tag_root = be32(fdt_off + 0x38);
      uint32_t tag_cpus = be32(fdt_off + 0x13c);
      // LE words as CPU `ld` would see at fdt base / +8
      uint64_t le0 = rd64(fdt_off);
      uint64_t le8 = rd64(fdt_off + 8);
      std::cerr << std::hex << "[fdtmem] mag=0x" << mag << " tsz=0x" << tsz
                << " off_struct=0x" << off_struct << " off_strings=0x" << off_strings
                << " ver=0x" << ver << " sz_struct=0x" << sz_struct
                << " tag_root=0x" << tag_root << " tag_cpus=0x" << tag_cpus
                << " le0=0x" << le0 << " le8=0x" << le8 << std::dec << "\n";
      // R3a cont.9 walk probe log @ DRAM+0x42e00 (VA 0x80042e00)
      std::cerr << std::hex << "[walk]";
      for (int i = 0; i < 12; i++) {
        uint64_t v = rd64(0x42e00 + 8 * i);
        if (v != 0)
          std::cerr << " [+" << (8 * i) << "]=" << v;
      }
      std::cerr << std::dec << "\n";
      // R3a cont.10: walk log in first PT_LOAD @ DRAM+0x22c00 (VA 0x80022c00)
      std::cerr << std::hex << "[walk22]";
      for (int i = 0; i < 16; i++) {
        uint64_t v = rd64(0x22c00 + 8 * i);
        if (v != 0)
          std::cerr << " [+" << (8 * i) << "]=" << v;
      }
      std::cerr << std::dec << "\n";
    }
    // R3a hang state: live NPC + per-hart CSR/RF (smt2 = 1 core × 2 banks).
    // I4o: npc0=0x32e is _start_warm hart-id scan; mepc=0 is a separate illegal.
    {
      auto npc0 = top->rootp->G6LC_CVA6_C0(i_frontend__DOT__npc_q);
      auto mepc0 = top->rootp->G6LC_TB_CSR(G6LC_CVA6_C0, 0, mepc_q);
      auto mtvec = top->rootp->G6LC_TB_CSR(G6LC_CVA6_C0, 0, mtvec_q);
      auto mcause0 = top->rootp->G6LC_TB_CSR(G6LC_CVA6_C0, 0, mcause_q);
      auto wfi0 = top->rootp->G6LC_TB_CSR(G6LC_CVA6_C0, 0, wfi_q);
      auto mepc1 = G6LC_TB_H1(top->rootp->G6LC_TB_CSR(G6LC_CVA6_C0, 1, mepc_q));
      auto mcause1 = G6LC_TB_H1(top->rootp->G6LC_TB_CSR(G6LC_CVA6_C0, 1, mcause_q));
      auto wfi1 = G6LC_TB_H1(top->rootp->G6LC_TB_CSR(G6LC_CVA6_C0, 1, wfi_q));
      auto active = G6LC_TB_H1(top->rootp->G6LC_CVA6_C0(i_smt_thread_select__DOT__gen_smt__DOT__active_q));
      const auto &rf0 = top->rootp->G6LC_TB_RF(G6LC_CVA6_C0, 0);
#if defined(G6LC_TB_BANKED)
      const auto &rf1 = top->rootp->G6LC_TB_RF(G6LC_CVA6_C0, 1);
#endif
      auto gpr64 = [](const auto &rf, int n) -> uint64_t {
        return (uint64_t)rf[2 * n] | ((uint64_t)rf[2 * n + 1] << 32);
      };
      uint64_t ra0 = gpr64(rf0, 1), ra1 = G6LC_TB_H1(gpr64(rf1, 1));
      uint64_t sp0 = gpr64(rf0, 2), sp1 = G6LC_TB_H1(gpr64(rf1, 2));
      uint64_t s00 = gpr64(rf0, 8), s01 = G6LC_TB_H1(gpr64(rf1, 8));
      auto mtval0 = top->rootp->G6LC_TB_CSR(G6LC_CVA6_C0, 0, mtval_q);
      uint64_t t00 = gpr64(rf0, 5), t01 = G6LC_TB_H1(gpr64(rf1, 5));
      uint64_t t10 = gpr64(rf0, 6), t11 = G6LC_TB_H1(gpr64(rf1, 6));
      uint64_t t20 = gpr64(rf0, 7), t21 = G6LC_TB_H1(gpr64(rf1, 7));
      uint64_t a00 = gpr64(rf0, 10), a01 = G6LC_TB_H1(gpr64(rf1, 10));
      uint64_t a30 = gpr64(rf0, 13), a31 = G6LC_TB_H1(gpr64(rf1, 13));
      uint64_t a40 = gpr64(rf0, 14), a41 = G6LC_TB_H1(gpr64(rf1, 14));
      uint64_t a50 = gpr64(rf0, 15), a51 = G6LC_TB_H1(gpr64(rf1, 15));
      std::cerr << std::hex << "[hangpc] npc0=0x" << (uint64_t)npc0
                << " act=" << (unsigned)active
                << " mepc0=0x" << (uint64_t)mepc0
                << " mcause0=0x" << (uint64_t)mcause0
                << " mtval0=0x" << (uint64_t)mtval0
                << " wfi0=" << (unsigned)wfi0
                << " mepc1=0x" << (uint64_t)mepc1
                << " mcause1=0x" << (uint64_t)mcause1
                << " wfi1=" << (unsigned)wfi1
                << " t00=0x" << t00 << " t01=0x" << t01
                << " t10=0x" << t10 << " t11=0x" << t11
                << " t20=0x" << t20 << " t21=0x" << t21
                << " a00=0x" << a00 << " a01=0x" << a01
                << " a30=0x" << a30 << " a31=0x" << a31
                << " a40=0x" << a40 << " a41=0x" << a41
                << " a50=0x" << a50 << " a51=0x" << a51
                << " ra0=0x" << ra0 << " ra1=0x" << ra1
                << " sp0=0x" << sp0 << " sp1=0x" << sp1
                << " s00=0x" << s00 << " s01=0x" << s01
                << " mtvec=0x" << (uint64_t)mtvec
                << std::dec << "\n";
    }
    // S4: _v / Ara is NrCores=2; C0 hangpc can be the lottery loser.
    // G6LC_CVA6_GEN_ACC is Makefile-only for server_math_v (smt2 stays C0).
#if defined(G6LC_CVA6_GEN_ACC)
    {
      auto npc0 = top->rootp->G6LC_CVA6_C1(i_frontend__DOT__npc_q);
      auto mepc0 = top->rootp->G6LC_TB_CSR(G6LC_CVA6_C1, 0, mepc_q);
      auto mcause0 = top->rootp->G6LC_TB_CSR(G6LC_CVA6_C1, 0, mcause_q);
      auto wfi0 = top->rootp->G6LC_TB_CSR(G6LC_CVA6_C1, 0, wfi_q);
      auto mepc1 = G6LC_TB_H1(top->rootp->G6LC_TB_CSR(G6LC_CVA6_C1, 1, mepc_q));
      auto mcause1 = G6LC_TB_H1(top->rootp->G6LC_TB_CSR(G6LC_CVA6_C1, 1, mcause_q));
      auto wfi1 = G6LC_TB_H1(top->rootp->G6LC_TB_CSR(G6LC_CVA6_C1, 1, wfi_q));
      auto active = G6LC_TB_H1(top->rootp->G6LC_CVA6_C1(i_smt_thread_select__DOT__gen_smt__DOT__active_q));
      const auto &rf0 = top->rootp->G6LC_TB_RF(G6LC_CVA6_C1, 0);
#if defined(G6LC_TB_BANKED)
      const auto &rf1 = top->rootp->G6LC_TB_RF(G6LC_CVA6_C1, 1);
#endif
      auto gpr64 = [](const auto &rf, int n) -> uint64_t {
        return (uint64_t)rf[2 * n] | ((uint64_t)rf[2 * n + 1] << 32);
      };
      std::cerr << std::hex << "[hangpc1] npc0=0x" << (uint64_t)npc0
                << " act=" << (unsigned)active
                << " mepc0=0x" << (uint64_t)mepc0
                << " mcause0=0x" << (uint64_t)mcause0
                << " wfi0=" << (unsigned)wfi0
                << " mepc1=0x" << (uint64_t)mepc1
                << " mcause1=0x" << (uint64_t)mcause1
                << " wfi1=" << (unsigned)wfi1
                << " ra0=0x" << gpr64(rf0, 1) << " ra1=0x" << G6LC_TB_H1(gpr64(rf1, 1))
                << " sp0=0x" << gpr64(rf0, 2) << " sp1=0x" << G6LC_TB_H1(gpr64(rf1, 2))
                << " s00=0x" << gpr64(rf0, 8) << " s01=0x" << G6LC_TB_H1(gpr64(rf1, 8))
                << std::dec << "\n";
    }
#endif
    // R3a fdtcnt probe BSS log @ DRAM+0x42e00 (VA 0x80042e00):
    //   +0x00 next_tag entry count
    //   +0x08 last structure offset (a1 into fdt_next_tag)
    //   +0x10 last fdt base (a0)
    //   +0x18 path_offset entry count
    //   +0x20 last path pointer
    //   +0x28 fail-WFI cookie (0x51b1dead)
    //   +0x30 next_tag return count
    //   +0x38 last returned tag
    //   +0x40 last nextoffset (*a2)
    //   +0x48 max structure offset seen
    //   +0x50 last path_offset fdt
    {
      uint64_t nt = rd64(0x42e00), off = rd64(0x42e08), fdt = rd64(0x42e10);
      uint64_t pc = rd64(0x42e18), path = rd64(0x42e20), fail = rd64(0x42e28);
      uint64_t nret = rd64(0x42e30), tag = rd64(0x42e38), nxoff = rd64(0x42e40);
      uint64_t maxoff = rd64(0x42e48), pfdt = rd64(0x42e50);
      if (nt | off | fdt | pc | path | fail | nret | tag | nxoff | maxoff | pfdt) {
        std::cerr << std::hex << "[fdtcnt]"
                  << " next_tag=" << nt
                  << " last_off=" << off
                  << " last_fdt=" << fdt
                  << " path_cnt=" << pc
                  << " last_path=" << path
                  << " fail=" << fail
                  << " ret_cnt=" << nret
                  << " last_tag=" << tag
                  << " last_nxoff=" << nxoff
                  << " max_off=" << maxoff
                  << " path_fdt=" << pfdt
                  << " a2_entry=" << rd64(0x42e68)
                  << " path_ret=" << rd64(0x42e70)
                  << " force_nx=" << rd64(0x42e78)
                  << " nx_slot=" << (rd64(0x42f80) & 0xffffffffULL)
                  << std::dec << "\n";
        // offset ring: 8 x u64 at DRAM+0x42e80 (LOG+0x80)
        std::cerr << std::hex << "[fdtcnt-ring]";
        for (int i = 0; i < 8; i++)
          std::cerr << " [" << i << "]=" << rd64(0x42e80 + 8 * i);
        std::cerr << std::dec << "\n";
        // a0/fdt entry ring (fdtcnt5): LOG+0x140
        if (nt) {
          std::cerr << std::hex << "[fdtcnt-a0]";
          for (int i = 0; i < 8; i++)
            std::cerr << " [" << i << "]=" << rd64(0x42f40 + 8 * i);
          std::cerr << std::dec << "\n";
          // fdtcnt6: ra ring LOG+0x180, s2 ring LOG+0x1c0, last ra/s2
          std::cerr << std::hex << "[fdtcnt-ra]";
          for (int i = 0; i < 8; i++)
            std::cerr << " [" << i << "]=" << rd64(0x42f80 + 8 * i);
          std::cerr << "\n[fdtcnt-s2]";
          for (int i = 0; i < 8; i++)
            std::cerr << " [" << i << "]=" << rd64(0x42fc0 + 8 * i);
          std::cerr << " last_ra=" << rd64(0x43000) << " last_s2=" << rd64(0x43008)
                    << std::dec << "\n";
        }
        // return tag / nextoff rings (fdtcnt3): LOG+0xC0 / LOG+0x100
        if (nret) {
          std::cerr << std::hex << "[fdtcnt-rettag]";
          for (int i = 0; i < 8; i++)
            std::cerr << " [" << i << "]=" << rd64(0x42ec0 + 8 * i);
          std::cerr << "\n[fdtcnt-retnx]";
          for (int i = 0; i < 8; i++)
            std::cerr << " [" << i << "]=" << rd64(0x42f00 + 8 * i);
          std::cerr << std::dec << "\n";
        }
      }
    }
    // R3a DRAM console ring (cursor @0x10f0, bytes @0x1100..) when firmware
    // putc is stubbed off UART MMIO (which can hang the AXI fabric).
    // Cursor may be a DRAM offset or a full VA (0x8000xxxx).
    uint64_t cur = rd64(0x10f0);
    if (cur >= 0x80000000ULL && cur < 0x80010000ULL)
      cur -= 0x80000000ULL;
    if (cur >= 0x1100 && cur < 0x10000) {
      size_t n = (size_t)(cur - 0x1100);
      if (n > 512) n = 512;
      std::cerr << "[dram-console] (" << std::dec << n << " bytes) ";
      for (size_t i = 0; i < n; i++) {
        char c = (char)bytes[0x1100 + i];
        if (c == '\n') std::cerr << "\\n";
        else if (c >= 32 && c < 127) std::cerr << c;
        else std::cerr << ".";
      }
      std::cerr << "\n";
    }
  }

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
  } else if (sigterm_seen) {
    fprintf(stderr, "%s *** TERMINATED (SIGTERM) *** after %ld cycles\n", htif_argv[1], main_time);
    ret = 124;
  } else if (budget_exit) {
    // T20: a cycle-budget exit is not a verdict. Three server boots were read
    // as passes from a bare "SUCCESS (tohost = 0) after <cap> cycles" line
    // (plan T16/T17). The banner grammar is kept (the review runners parse
    // `*** SUCCESS|FAILED *** (tohost = N) after M cycles` and classify
    // M >= cap as a timeout themselves); the suffix makes the raw line honest.
    fprintf(stderr, "%s *** SUCCESS *** (tohost = 0) after %ld cycles [cycle budget reached: no tohost verdict]\n",
            htif_argv[1], main_time);
  } else {
    // Ended on a tohost/exit handshake reporting success (HTIF exit code 0,
    // i.e. the guest wrote tohost = 1); the banner reports the exit code.
    fprintf(stderr, "%s *** SUCCESS *** (tohost = 0) after %ld cycles\n", htif_argv[1], main_time);
  }

  top->final();
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

  if (metrics_sidecar) {
    fprintf(stderr,
            "[G6LC_METRICS] cycles=%ld retired0=%llu dropped0=%llu retired1=%llu dropped1=%llu\n",
            (long)main_time,
            (unsigned long long)metrics_retired[0], (unsigned long long)metrics_dropped[0],
            (unsigned long long)metrics_retired[1], (unsigned long long)metrics_dropped[1]);
    FILE *mf = fopen(metrics_sidecar, "w");
    if (mf) {
      fprintf(mf,
              "{\"cycles\":%ld,\"retired\":[%llu,%llu],\"dropped\":[%llu,%llu],"
              "\"kind\":\"tb-sidecar\",\"instrumented\":true}\n",
              (long)main_time,
              (unsigned long long)metrics_retired[0], (unsigned long long)metrics_retired[1],
              (unsigned long long)metrics_dropped[0], (unsigned long long)metrics_dropped[1]);
      fclose(mf);
    }
  }

  return ret;
}
