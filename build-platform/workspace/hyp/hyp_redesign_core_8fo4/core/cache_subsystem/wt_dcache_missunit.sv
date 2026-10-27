// hyp8 provenance: ADAPTED (sv-timing emit at the 8-FO4 budget)
// SPDX-FileCopyrightText: machine-generated
// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Michael Schaffner <schaffner@iis.ee.ethz.ch>, ETH Zurich
// Date: 13.09.2018
// Description: miss controller for WT dcache. Note that the current assumption
// is that the port with the highest index issues writes instead of reads.
// Modified by: Etienne Cimon (Verilator width)


module wt_dcache_missunit
  import g6lc_core_pkg::*;
  import wt_cache_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter DCACHE_CL_IDX_WIDTH = 0,
    parameter type dcache_req_t = logic,
    parameter type dcache_rtrn_t = logic,
    parameter logic [G6LCCfg.MEM_TID_WIDTH-1:0] AmoTxId = 1,  // TX id to be used for AMOs
    parameter int unsigned NumPorts = 4  // number of miss ports
) (
    input logic clk_i,  // Clock
    input logic rst_ni,  // Asynchronous reset active low
    // cache management, signals from/to core
    input logic enable_i,  // from CSR
    input  logic                                       flush_i,     // flush request, this waits for pending tx (write, read) to finish and will clear the cache
    output logic flush_ack_o,  // send a single cycle acknowledge signal when the cache is flushed
    output logic miss_o,  // we missed on a ld/st
    // local cache management signals
    input logic wbuffer_empty_i,
    output logic cache_en_o,  // local cache enable signal
    // AMO interface
    input amo_req_t amo_req_i,
    output amo_resp_t amo_resp_o,
    input logic mbe_i,
    // miss handling interface (ld, ptw, wbuffer)
    input logic [NumPorts-1:0] miss_req_i,
    output logic [NumPorts-1:0] miss_ack_o,
    input logic [NumPorts-1:0] miss_nc_i,
    input logic [NumPorts-1:0] miss_we_i,
    input logic [NumPorts-1:0][G6LCCfg.XLEN-1:0] miss_wdata_i,
    input logic [NumPorts-1:0][G6LCCfg.DCACHE_USER_WIDTH-1:0] miss_wuser_i,
    input logic [NumPorts-1:0][G6LCCfg.PLEN-1:0] miss_paddr_i,
    input logic [NumPorts-1:0][G6LCCfg.DCACHE_SET_ASSOC-1:0] miss_vld_bits_i,
    input logic [NumPorts-1:0][2:0] miss_size_i,
    input logic [NumPorts-1:0][G6LCCfg.MEM_TID_WIDTH-1:0] miss_id_i,  // used as transaction ID
    // signals that the request collided with a pending read
    output logic [NumPorts-1:0] miss_replay_o,
    // signals response from memory
    output logic [NumPorts-1:0] miss_rtrn_vld_o,
    output logic [G6LCCfg.MEM_TID_WIDTH-1:0]                  miss_rtrn_id_o,     // only used for writes, set to zero for reads
    // from writebuffer
    input  logic [G6LCCfg.DCACHE_MAX_TX-1:0][G6LCCfg.PLEN-1:0]  tx_paddr_i,         // used to check for address collisions with read operations
    input  logic [G6LCCfg.DCACHE_MAX_TX-1:0]                   tx_vld_i,           // used to check for address collisions with read operations
    // write interface to cache memory
    output logic wr_cl_vld_o,  // writes a full cacheline
    output logic wr_cl_nc_o,  // writes a full cacheline
    output logic [G6LCCfg.DCACHE_SET_ASSOC-1:0] wr_cl_we_o,  // writes a full cacheline
    output logic [G6LCCfg.DCACHE_TAG_WIDTH-1:0] wr_cl_tag_o,
    output logic [DCACHE_CL_IDX_WIDTH-1:0] wr_cl_idx_o,
    output logic [G6LCCfg.DCACHE_OFFSET_WIDTH-1:0] wr_cl_off_o,
    output logic [G6LCCfg.DCACHE_LINE_WIDTH-1:0] wr_cl_data_o,
    output logic [G6LCCfg.DCACHE_USER_LINE_WIDTH-1:0] wr_cl_user_o,
    output logic [G6LCCfg.DCACHE_LINE_WIDTH/8-1:0] wr_cl_data_be_o,
    output logic [G6LCCfg.DCACHE_SET_ASSOC-1:0] wr_vld_bits_o,
    // MSHR occupancy for the wbuffer's fixup tag-miss contract: a fixup
    // entry whose tag check misses must retry only while a refill for the
    // same index could still be in flight (see wt_dcache_wbuffer).
    output logic mshr_vld_o,
    output logic [DCACHE_CL_IDX_WIDTH-1:0] mshr_cl_idx_o,
    // memory interface
    input logic mem_rtrn_vld_i,
    input dcache_rtrn_t mem_rtrn_i,
    output logic mem_data_req_o,
    input logic mem_data_ack_i,
    output dcache_req_t mem_data_o
);

  // A139 design proposal; vocabulary: architecture/RTL-PIPELINE-PLANS.md.
  // svt-plan: begin wt_dcache_missunit status=proposal target=10-adjusted-FO4
  // svt-plan: cone miss arbitration/MSHR selection and refill/control
  // decode feed cache writes, invalidations and completion acknowledgements.
  // svt-plan: boundary accepted refill -> cache-install descriptor -> grant;
  // prepare way/index/tag/data enables together outside the array-write cycle.
  // svt-plan: carry MSHR identity, PA, way, data/user, NC/size, refill
  // epoch and killed status; hold the descriptor until all required writes finish.
  // svt-plan: conflict invalidation/fill_killed prevents publishing stale
  // lines; a later invalidate cannot be overtaken by a buffered refill.
  // svt-plan: visibility do not free the MSHR or report completion before
  // installation is visible; align wr_cl_inv with fixup byte-supersession rules.
  // svt-plan: effect separates MSHR/refill decode from array arbitration;
  // registered descriptor fields shorten cross-module control propagation.
  // svt-plan: cost refill holding space and miss latency; preserve fairness
  // among demand, flush and invalidation, including simultaneous events.
  // svt-plan: limit array grant and coherence ordering remain; merely
  // registering wr_cl_tag_o would misalign its data and write enables.
  // svt-plan: end
  // Re-pipelining contract (sv-timing A128; 60.0 adjusted FO4 on the
  // Nangate45 board): miss unit: FSM with AXI handshakes; miss_req_i / miss_id_i are its protocol.
  // svt-pipe: require-contract
  // svt-pipe: protocol mu valid=miss_req_i
  // svt-pipe: no-cut on=wr_cl_tag_o
  // svt-pipe: cycle mu q=wr_cl_tag_o d=wr_cl_data_o hold=miss_req_i steps=1

  // Outgoing memory request packet and its valid, assembled below and
  // published through one assign each (A149 M12; see the `mem` contract).
  dcache_req_t mem_req_c;
  logic        mem_req_valid_c;

  // functions
  function automatic logic [G6LCCfg.DCACHE_SET_ASSOC-1:0] dcache_way_bin2oh(
      input logic [G6LCCfg.DCACHE_SET_ASSOC_WIDTH-1:0] in);
    logic [G6LCCfg.DCACHE_SET_ASSOC-1:0] out;
    out     = '0;
    out[in] = 1'b1;
    return out;
  endfunction

  // align the physical address to the specified size:
  // 000: bytes
  // 001: hword
  // 010: word
  // 011: dword
  // 111: DCACHE line
  function automatic logic [G6LCCfg.PLEN-1:0] paddrSizeAlign(input logic [G6LCCfg.PLEN-1:0] paddr,
                                                             input logic [2:0] size);
    logic [G6LCCfg.PLEN-1:0] out;
    out = paddr;
    unique case (size)
      3'b001:  out[0:0] = '0;
      3'b010:  out[1:0] = '0;
      3'b011:  out[2:0] = '0;
      3'b111:  out[G6LCCfg.DCACHE_OFFSET_WIDTH-1:0] = '0;
      default: ;
    endcase
    return out;
  endfunction : paddrSizeAlign

  // controller FSM
  // AMO_CAS_* : local load-compare-store for AMOCAS.D (64b cmp||swap is 128b
  // on AXI AtomicCompare; axi_riscv_amos rejects multi-beat atomics).
  typedef enum logic [3:0] {
    IDLE,
    DRAIN,
    AMO,
    FLUSH,
    STORE_WAIT,
    LOAD_WAIT,
    AMO_WAIT,
    AMO_RESULT,
    AMO_RESULT_FORM,  // r75: formed word registers here; AMO_RESULT presents it
    AMO_CAS_LD,
    AMO_CAS_LD_WAIT,
    AMO_CAS_ST,
    AMO_CAS_ST_WAIT
  } state_e;
  state_e state_d, state_q;

  // Zacas local RMW (dword CAS)
  logic        cas_local_en;  // size==dword && AMO_CAS1
  logic [63:0] cas_old_d, cas_old_q;
  logic [63:0] cas_new_d, cas_new_q;
  logic        cas_ld_ack, cas_st_ack;
  logic        cas_amo_sel;  // drive AMO paddr/size/tid without ATOP
  // Uncached CAS store updates DRAM only; drop any stale L1 line so later
  // cached loads see the new value (CRT stack lines are often hot).
  logic        cas_inv;

  // MSHR for reads
  typedef struct packed {
    logic [G6LCCfg.PLEN-1:0]                     paddr;
    logic [2:0]                                  size;
    logic [G6LCCfg.DCACHE_SET_ASSOC-1:0]         vld_bits;
    logic [G6LCCfg.MEM_TID_WIDTH-1:0]            id;
    logic                                        nc;
    logic [$clog2(G6LCCfg.DCACHE_SET_ASSOC)-1:0] repl_way;
    logic [$clog2(NumPorts)-1:0]                 miss_port_idx;
  } mshr_t;

  mshr_t mshr_d, mshr_q;
  logic [$clog2(G6LCCfg.DCACHE_SET_ASSOC)-1:0] repl_way, inv_way, rnd_way;
  logic mshr_vld_d, mshr_vld_q, mshr_vld_q1;
  logic mshr_allocate;
  logic update_lfsr, all_ways_valid;

  logic enable_d, enable_q;
  logic flush_ack_d, flush_ack_q;
  logic flush_en, flush_done;
  logic mask_reads, lock_reqs;
  logic amo_sel, miss_is_write;
  logic amo_req_d, amo_req_q;
  logic [63:0] amo_rtrn_mux;
  logic [63:0] amo_raw_q;  // r74: registered raw return word (formation reads it)
  logic [G6LCCfg.XLEN-1:0] amo_data, amo_data_a, amo_data_b;
  logic [G6LCCfg.XLEN-1:0] amo_user;  //DCACHE USER ? G6LCCfg.DCACHE_USER_WIDTH
  logic [G6LCCfg.PLEN-1:0] tmp_paddr;
  logic [$clog2(NumPorts)-1:0] miss_port_idx;
  logic [DCACHE_CL_IDX_WIDTH-1:0] cnt_d, cnt_q;
  logic [NumPorts-1:0] miss_req_masked_d, miss_req_masked_q;

  localparam bit COH_VALIDATE = G6LCCfg.NrCores > 1 || G6LCCfg.CohPolicy == config_pkg::COH_OOO;
  logic inv_vld, inv_vld_all, cl_write_en;
  logic fill_killed_q, load_ack, store_ack, amo_ack;
  if (COH_VALIDATE) begin : gen_fill_kill
    

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=wt_dcache_missunit  region=4119  makespan=6.900 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: fill_killed_q  ready_cycle=1  ready_fo4=6.900  OpenSTA: report_timing -from clk_i -to fill_killed_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     fill_killed_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node14296 c=3.50 slack=3.40 */
//     /* node14297 c=4.50 slack=2.40 */
//     /* node14298 c=6.90 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=wt_dcache_missunit  region=4185  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: amo_req_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to amo_req_q
// order expect: cas_new_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to cas_new_q
// order expect: cas_old_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to cas_old_q
// order expect: cnt_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to cnt_q
// order expect: enable_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to enable_q
// order expect: flush_ack_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to flush_ack_q
// order expect: miss_req_masked_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to miss_req_masked_q
// order expect: mshr_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to mshr_q
// order expect: mshr_rdrd_collision_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to mshr_rdrd_collision_q
// order expect: mshr_vld_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to mshr_vld_q
// order expect: mshr_vld_q1  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to mshr_vld_q1
// order expect: state_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to state_q
// order expect: stores_inflight_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to stores_inflight_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     amo_req_q <= …; // sv-timing: cycle 1/1 on clk_i
//     cas_new_q <= …; // sv-timing: cycle 1/1 on clk_i
//     cas_old_q <= …; // sv-timing: cycle 1/1 on clk_i
//     cnt_q <= …; // sv-timing: cycle 1/1 on clk_i
//     enable_q <= …; // sv-timing: cycle 1/1 on clk_i
//     flush_ack_q <= …; // sv-timing: cycle 1/1 on clk_i
//     miss_req_masked_q <= …; // sv-timing: cycle 1/1 on clk_i
//     mshr_q <= …; // sv-timing: cycle 1/1 on clk_i
//     mshr_rdrd_collision_q <= …; // sv-timing: cycle 1/1 on clk_i
//     mshr_vld_q <= …; // sv-timing: cycle 1/1 on clk_i
//     mshr_vld_q1 <= …; // sv-timing: cycle 1/1 on clk_i
//     state_q <= …; // sv-timing: cycle 1/1 on clk_i
//     stores_inflight_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node14471 c=3.50 slack=0.00 */
//     /* node14472 c=3.50 slack=0.00 */
//     /* node14473 c=3.50 slack=0.00 */
//     /* node14474 c=3.50 slack=0.00 */
//     /* node14475 c=3.50 slack=0.00 */
//     /* node14476 c=3.50 slack=0.00 */
//     /* node14477 c=3.50 slack=0.00 */
//     /* node14478 c=3.50 slack=0.00 */
//     /* node14479 c=3.50 slack=0.00 */
//     /* node14480 c=3.50 slack=0.00 */
//     /* node14481 c=3.50 slack=0.00 */
//     /* node14482 c=3.50 slack=0.00 */
//     /* node14483 c=3.50 slack=0.00 */
//     /* node14484 c=3.50 slack=0.00 */
//     /* node14485 c=3.50 slack=0.00 */
//     /* node14486 c=3.50 slack=0.00 */
//     /* node14487 c=3.50 slack=0.00 */
//     /* node14488 c=3.50 slack=0.00 */
//     /* node14489 c=3.50 slack=0.00 */
//     /* node14490 c=3.50 slack=0.00 */
//     /* node14491 c=3.50 slack=0.00 */
//     /* node14492 c=3.50 slack=0.00 */
//     /* node14493 c=3.50 slack=0.00 */
//     /* node14494 c=3.50 slack=0.00 */
//     /* node14495 c=3.50 slack=0.00 */
//     /* node14496 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) fill_killed_q <= 1'b0;
      else begin
        if (mshr_allocate || load_ack) fill_killed_q <= 1'b0;
        if (inv_vld && (mshr_allocate || mshr_vld_q) &&
            mshr_d.paddr[G6LCCfg.DCACHE_INDEX_WIDTH-1:G6LCCfg.DCACHE_OFFSET_WIDTH] ==
            mem_rtrn_i.inv.idx[G6LCCfg.DCACHE_INDEX_WIDTH-1:G6LCCfg.DCACHE_OFFSET_WIDTH])
          fill_killed_q <= 1'b1;
      end
    end
  end else begin : gen_no_fill_kill
    assign fill_killed_q = 1'b0;
  end

  logic [NumPorts-1:0] mshr_rdrd_collision_d, mshr_rdrd_collision_q;
  logic [NumPorts-1:0] mshr_rdrd_collision;
  logic tx_rdwr_collision, mshr_rdwr_collision;

  ///////////////////////////////////////////////////////
  // input arbitration and general control sigs
  ///////////////////////////////////////////////////////

  assign cache_en_o = enable_q;
  assign cnt_d = flush_en ? ((COH_VALIDATE && inv_vld) ? cnt_q : cnt_q + 1'b1) : '0;
  assign flush_done = (cnt_q == $bits(cnt_q)'(G6LCCfg.DCACHE_NUM_WORDS - 1));

  // Per-port load vs in-flight store-TX collision. LZC always prefers lower
  // indices (load ports) over the write-buffer port (NumPorts-1). If a load is
  // stalled on tx_rdwr_collision but still wins arbitration, pending store
  // misses never issue → write buffer cannot drain → TX never frees → deadlock
  // on dense ST→LD streams (fill ≥ ~160 B on imafdc). When a store is pending,
  // mask colliding loads so the store port can be selected and TX can retire.
  logic [NumPorts-1:0] load_tx_collision;
  logic                store_pending;
  logic [NumPorts-1:0] miss_req_base;

  always_comb begin : p_load_tx_coll
    load_tx_collision = '0;
    for (int p = 0; p < NumPorts; p++) begin
      if (miss_req_i[p] && !miss_we_i[p]) begin
        for (int k = 0; k < G6LCCfg.DCACHE_MAX_TX; k++) begin
          load_tx_collision[p] |=
              (miss_paddr_i[p][G6LCCfg.PLEN-1:G6LCCfg.DCACHE_OFFSET_WIDTH]
               == tx_paddr_i[k][G6LCCfg.PLEN-1:G6LCCfg.DCACHE_OFFSET_WIDTH])
              && tx_vld_i[k];
        end
      end
    end
  end

  assign store_pending = miss_req_i[NumPorts-1] & miss_we_i[NumPorts-1];

  assign miss_req_base = (lock_reqs)  ? miss_req_masked_q :
                         (mask_reads) ? (miss_we_i & miss_req_i) : miss_req_i;
  assign miss_req_masked_d = (store_pending && !lock_reqs)
                           ? (miss_req_base & ~load_tx_collision)
                           : miss_req_base;
  assign miss_is_write = miss_we_i[miss_port_idx];

  // read port arbiter
  g6lc_hyp_lzc #(
      .WIDTH(NumPorts)
  ) i_lzc_reqs (
      .in_i   (miss_req_masked_d),
      .cnt_o  (miss_port_idx),
      .empty_o()
  );

  always_comb begin : p_ack
    miss_ack_o = '0;
    if (!amo_sel) begin
      miss_ack_o[miss_port_idx] = mem_data_ack_i & mem_req_valid_c;
    end
  end

  ///////////////////////////////////////////////////////
  // MSHR and way replacement logic (only for read ops)
  ///////////////////////////////////////////////////////

  // find invalid cache line
  g6lc_hyp_lzc #(
      .WIDTH(G6LCCfg.DCACHE_SET_ASSOC)
  ) i_lzc_inv (
      .in_i   (~miss_vld_bits_i[miss_port_idx]),
      .cnt_o  (inv_way),
      .empty_o(all_ways_valid)
  );

  // generate random cacheline index
  g6lc_hyp_lfsr #(
      .LfsrWidth(8),
      .OutWidth (G6LCCfg.DCACHE_SET_ASSOC_WIDTH)
  ) i_lfsr_inv (
      .clk_i (clk_i),
      .rst_ni(rst_ni),
      .en_i  (update_lfsr),
      .out_o (rnd_way)
  );

  assign repl_way             = (all_ways_valid) ? rnd_way : inv_way;

  assign mshr_d.size          = (mshr_allocate) ? miss_size_i[miss_port_idx] : mshr_q.size;
  assign mshr_d.paddr         = (mshr_allocate) ? miss_paddr_i[miss_port_idx] : mshr_q.paddr;
  assign mshr_d.vld_bits      = (mshr_allocate) ? miss_vld_bits_i[miss_port_idx] : mshr_q.vld_bits;
  assign mshr_d.id            = (mshr_allocate) ? miss_id_i[miss_port_idx] : mshr_q.id;
  assign mshr_d.nc            = (mshr_allocate) ? miss_nc_i[miss_port_idx] : mshr_q.nc;
  assign mshr_d.repl_way      = (mshr_allocate) ? repl_way : mshr_q.repl_way;
  assign mshr_d.miss_port_idx = (mshr_allocate) ? miss_port_idx : mshr_q.miss_port_idx;

  // currently we only have one outstanding read TX, hence an incoming load clears the MSHR
  assign mshr_vld_d           = (mshr_allocate) ? 1'b1 : (load_ack) ? 1'b0 : mshr_vld_q;

  assign miss_o               = (mshr_allocate) ? ~miss_nc_i[miss_port_idx] : 1'b0;


  for (genvar k = 0; k < NumPorts; k++) begin : gen_rdrd_collision
    assign mshr_rdrd_collision[k]   = (mshr_q.paddr[G6LCCfg.PLEN-1:G6LCCfg.DCACHE_OFFSET_WIDTH] == miss_paddr_i[k][G6LCCfg.PLEN-1:G6LCCfg.DCACHE_OFFSET_WIDTH]) && (mshr_vld_q | mshr_vld_q1);
    assign mshr_rdrd_collision_d[k] = (!miss_req_i[k]) ? 1'b0 : mshr_rdrd_collision_q[k] | mshr_rdrd_collision[k];
  end

  // read/write collision, stalls the corresponding request
  // write port[NumPorts-1] collides with MSHR_Q
  assign mshr_rdwr_collision = (mshr_q.paddr[G6LCCfg.PLEN-1:G6LCCfg.DCACHE_OFFSET_WIDTH] == miss_paddr_i[NumPorts-1][G6LCCfg.PLEN-1:G6LCCfg.DCACHE_OFFSET_WIDTH]) && mshr_vld_q;

  // read collides with inflight TX
  always_comb begin : p_tx_coll
    tx_rdwr_collision = 1'b0;
    for (int k = 0; k < G6LCCfg.DCACHE_MAX_TX; k++) begin
      tx_rdwr_collision |= (miss_paddr_i[miss_port_idx][G6LCCfg.PLEN-1:G6LCCfg.DCACHE_OFFSET_WIDTH] == tx_paddr_i[k][G6LCCfg.PLEN-1:G6LCCfg.DCACHE_OFFSET_WIDTH]) && tx_vld_i[k];
    end
  end

  ///////////////////////////////////////////////////////
  // to memory
  ///////////////////////////////////////////////////////

  // if size = 32bit word, select appropriate offset, replicate for openpiton...

  if (G6LCCfg.RVA) begin
    if (G6LCCfg.IS_XLEN64) begin : gen_amo_64b_data
      assign amo_data_a = {amo_req_i.operand_b[0+:32], amo_req_i.operand_b[0+:32]};
      assign amo_data_b = amo_req_i.operand_b;
    end else begin : gen_amo_32b_data
      assign amo_data_a = amo_req_i.operand_b[0+:32];
    end
  end

  always_comb begin
    if (G6LCCfg.RVA) begin
      if (G6LCCfg.IS_XLEN64) begin
        // Zacas AMOCAS.W: pack {cmp[31:0], swap[31:0]} (matches hpdcache)
        // AMOCAS.D: operand_b is swap; cmp travels in operand_c (adapter/ALU)
        if (G6LCCfg.RVZacas && amo_req_i.amo_op == AMO_CAS1) begin
          if (amo_req_i.size == 2'b10) begin
            amo_data = {amo_req_i.operand_c[31:0], amo_req_i.operand_b[31:0]};
          end else begin
            // Double-word CAS: low=swap, high=cmp (ALU splits)
            amo_data = amo_req_i.operand_b;
          end
        end else if (amo_req_i.size == 2'b10) begin
          amo_data = amo_data_a;
        end else begin
          amo_data = amo_data_b;
        end
      end else begin
        amo_data = amo_data_a;
      end
      if (G6LCCfg.DATA_USER_EN != 0) begin
        amo_user = amo_data;
      end else begin
        amo_user = '0;
      end
    end
  end

  if (G6LCCfg.RVA) begin
    // note: openpiton returns a full cacheline!
    if (G6LCCfg.NOCType == config_pkg::NOC_TYPE_AXI4_ATOP) begin : gen_axi_rtrn_mux
      if (G6LCCfg.AxiDataWidth > 64) begin
        assign amo_rtrn_mux = mem_rtrn_i.data[amo_req_i.operand_a[$clog2(
            G6LCCfg.AxiDataWidth/8
        )-1:3]*64+:64];
      end else begin
        assign amo_rtrn_mux = mem_rtrn_i.data[0+:64];
      end
    end else begin : gen_piton_rtrn_mux
      assign amo_rtrn_mux = mem_rtrn_i.data[amo_req_i.operand_a[G6LCCfg.DCACHE_OFFSET_WIDTH-1:3]*64+:64];
    end

    // BIG ENDIAN CAPABLE logic for amo return value from memory
    logic [63:0] amoResult_LE;
    logic [63:0] amoResult_BE;

    // Little Endian Calculation of return value from memory (when 32bit, we need to sign extend)
    logic [63:0] amoResult_32bitLE;
    // r74 (A118 explicit select): the word half is a 2:1 mux on operand_a[2],
    // not an indexed part-select with a `*32` offset (billed as arithmetic).
    logic [31:0] amo_raw_half;
    assign amo_raw_half = amo_req_i.operand_a[2] ? amo_raw_q[63:32] : amo_raw_q[31:0];
    assign amoResult_32bitLE = {{32{amo_raw_half[31]}}, amo_raw_half};

    // Big Endian Calculations of return value from memory with AMO operations (Bytes need swapping and sign extension is different)
    logic [63:0] amoResult_64bitBE;
    logic [31:0] amoResult_32bitBE_NoSign;
    logic [63:0] amoResult_32bitBE;
    assign amoResult_64bitBE = {<<8{amo_raw_q}};
    assign amoResult_32bitBE_NoSign = {<<8{amo_raw_half}};
    assign amoResult_32bitBE = {
      {32{amo_raw_half[7]}}, amoResult_32bitBE_NoSign
    };  // +7 to the base address to find the sign bit, as in BE the Most Significant Byte is always at the lowest addressed byte.

    assign amoResult_BE = (amo_req_i.size == 2'b10) ? amoResult_32bitBE : amoResult_64bitBE;
    assign amoResult_LE = (amo_req_i.size == 2'b10) ? amoResult_32bitLE : amo_raw_q;

    // hyp8: registered formation step. The byte-order / sign-extend network is
    // a wide cone hanging off the return packet; it is captured every cycle
    // (free-running) and the AMO FSM presents the ack one state later in
    // AMO_RESULT, where the registered value is selected. The same-cycle
    // consumer inside p_rtrn_logic (AMO_SC pass/fail at the ATOMIC_ACK edge)
    // keeps the live formation `amo_result_form` — the verdict cycle is
    // unchanged, only the response presentation moves +1.
    logic [63:0] amo_result_form;
    logic [63:0] amo_result_q;
    assign amo_result_form = mbe_i ? amoResult_BE : amoResult_LE;
    // r74 (A106 snapshot / caller purpose): the only consumer of the formed
    // word is the AMO_RESULT presentation one cycle after ATOMIC_ACK (the CAS
    // compare and old-value capture read the raw word). Capture the raw
    // 64-bit return word every cycle and form byte order / sign extension
    // from the register in the presentation cycle: the 128->64 select and
    // the swap/sign network no longer share one into->reg cone.
    // r75 (T2 stage, program §4): the formed word is registered as well, so
    // the presentation cycle reads a flop (reg->out = one state mux). The ack
    // moves one state later (AMO_WAIT -> AMO_RESULT_FORM -> AMO_RESULT): AMO
    // result latency +1, depth-1 AMO acceptance unchanged (no new AMO until
    // IDLE). CAS keeps its own path (cas_old_q, ack in AMO_CAS_ST_WAIT).
    always_ff @(posedge clk_i or negedge rst_ni) begin : p_amo_result_ff
      if (!rst_ni) begin
        amo_raw_q    <= '0;
        amo_result_q <= '0;
      end else begin
        amo_raw_q    <= amo_rtrn_mux;
        amo_result_q <= amo_result_form;
      end
    end

    // Local dword CAS returns the saved old value; ATOP path uses mem rtrn mux.
    // r74 (caller purpose): amo_resp_o.ack is asserted only in AMO_RESULT
    // (registered formation) and AMO_CAS_ST_WAIT (cas_old_q); the consumer
    // samples result with ack, so the live formation never has to reach the
    // output. The live cone stays on the internal SC verdict only.
    assign amo_resp_o.result = (state_q inside {AMO_CAS_ST, AMO_CAS_ST_WAIT})
                                   ? cas_old_q
                                   : amo_result_q;
    // end BIG ENDIAN CAPABLE logic for amo return value from memory

    assign amo_req_d = amo_req_i.req;
  end

  // Local RMW for AMOCAS.D (size dword). Word CAS stays on AXI AtomicCompare.
  assign cas_local_en = G6LCCfg.RVA && G6LCCfg.RVZacas && G6LCCfg.IS_XLEN64
      && (amo_req_i.amo_op == AMO_CAS1) && (amo_req_i.size == 2'b11);

  // Outgoing memory request packet (A149 M12). Assembled once as
  // mem_req_c / mem_req_valid_c and published through one assign each, so a
  // stage may register the whole packet and its valid together. The adapter
  // obeys req/ack, so the handshake absorbs an added cycle; the FSM's acks are
  // then the stage's acceptance (the tool rewires them to the stage enable).
  // svt-pipe: protocol mem valid=mem_req_valid_c ready=mem_data_ack_i
  // svt-pipe: result mem valid=mem_data_req_o mem_data_o
  // svt-pipe: cut-ok mem
  assign mem_data_o     = mem_req_c;
  assign mem_data_req_o = mem_req_valid_c;

  // outgoing memory requests (AMOs are always uncached)
  // cas_amo_sel: CAS.D load/store uses AMO address/tid/nc but plain LD/ST rtype
  assign mem_req_c.tid = (G6LCCfg.RVA && (amo_sel || cas_amo_sel)) ? AmoTxId : miss_id_i[miss_port_idx];
  assign mem_req_c.nc = (G6LCCfg.RVA && (amo_sel || cas_amo_sel)) ? 1'b1 : miss_nc_i[miss_port_idx];
  assign mem_req_c.way = (G6LCCfg.RVA && (amo_sel || cas_amo_sel)) ? '0 : repl_way;
  assign mem_req_c.data = (G6LCCfg.RVA && cas_amo_sel && (state_q inside {AMO_CAS_ST, AMO_CAS_ST_WAIT}))
                               ? cas_new_q
                               : (G6LCCfg.RVA && amo_sel) ? amo_data : miss_wdata_i[miss_port_idx];
  assign mem_req_c.user = (G6LCCfg.RVA && amo_sel) ? amo_user : miss_wuser_i[miss_port_idx];
  assign mem_req_c.size   = (G6LCCfg.RVA && (amo_sel || cas_amo_sel)) ? {1'b0, amo_req_i.size}
                                                                         : miss_size_i[miss_port_idx];
  // Plain load/store for local CAS.D — no AXI ATOP
  assign mem_req_c.amo_op = (G6LCCfg.RVA && amo_sel && !cas_amo_sel) ? amo_req_i.amo_op : AMO_NONE;

  assign tmp_paddr         = (G6LCCfg.RVA && (amo_sel || cas_amo_sel))
                                 ? amo_req_i.operand_a[G6LCCfg.PLEN-1:0]
                                 : miss_paddr_i[miss_port_idx];
  assign mem_req_c.paddr = paddrSizeAlign(tmp_paddr, mem_req_c.size);

  ///////////////////////////////////////////////////////
  // back-off mechanism for LR/SC completion guarantee
  ///////////////////////////////////////////////////////

  logic sc_fail, sc_pass, sc_backoff_over;
  g6lc_hyp_exp_backoff #(
      .Seed  (3),
      .MaxExp(16)
  ) i_exp_backoff (
      .clk_i,
      .rst_ni,
      .set_i    (sc_fail),
      .clr_i    (sc_pass),
      .is_zero_o(sc_backoff_over)
  );

  ///////////////////////////////////////////////////////
  // responses from memory
  ///////////////////////////////////////////////////////

  // keep track of pending stores
  logic store_sent;
  logic [$clog2(G6LCCfg.DCACHE_MAX_TX + 1)-1:0] stores_inflight_d, stores_inflight_q;
  assign store_sent = mem_req_valid_c & mem_data_ack_i & (mem_req_c.rtype == DCACHE_STORE_REQ);

  // One mux on a 2-bit code. The nested ternary was a priority chain
  // on the in-flight count.
  logic [1:0] inf_sel;
  always_comb begin
    if (store_ack && store_sent) inf_sel = 2'd0;
    else if (store_ack)         inf_sel = 2'd1;
    else if (store_sent)        inf_sel = 2'd2;
    else                         inf_sel = 2'd3;
  end
  always_comb begin
    unique case (inf_sel)
      2'd1:    stores_inflight_d = stores_inflight_q - 1;
      2'd2:    stores_inflight_d = stores_inflight_q + 1;
      default: stores_inflight_d = stores_inflight_q;
    endcase
  end

  // incoming responses
  always_comb begin : p_rtrn_logic
    load_ack        = 1'b0;
    store_ack       = 1'b0;
    amo_ack         = 1'b0;
    cas_ld_ack      = 1'b0;
    cas_st_ack      = 1'b0;
    inv_vld         = 1'b0;
    inv_vld_all     = 1'b0;
    sc_fail         = 1'b0;
    sc_pass         = 1'b0;
    miss_rtrn_vld_o = '0;
    if (mem_rtrn_vld_i) begin
      unique case (mem_rtrn_i.rtype)
        DCACHE_LOAD_ACK: begin
          if (mshr_vld_q) begin
            load_ack = 1'b1;
            miss_rtrn_vld_o[mshr_q.miss_port_idx] = 1'b1;
          end else if (G6LCCfg.RVA && (state_q inside {AMO_CAS_LD, AMO_CAS_LD_WAIT})) begin
            // Local AMOCAS.D load completed (no MSHR)
            cas_ld_ack = 1'b1;
          end
        end
        DCACHE_STORE_ACK: begin
          if (G6LCCfg.RVA && (state_q inside {AMO_CAS_ST, AMO_CAS_ST_WAIT}) && stores_inflight_q > 0) begin
            store_ack  = 1'b1;
            cas_st_ack = 1'b1;
          end else if (stores_inflight_q > 0) begin
            store_ack = 1'b1;
            miss_rtrn_vld_o[NumPorts-1] = 1'b1;
          end
        end
        DCACHE_ATOMIC_ACK: begin
          if (G6LCCfg.RVA) begin
            if (amo_req_q) begin
              amo_ack = 1'b1;
              // need to set SC backoff counter if
              // this op failed
              if (amo_req_i.amo_op == AMO_SC) begin
                if (amo_resp_o.result > 0) begin
                  sc_fail = 1'b1;
                end else begin
                  sc_pass = 1'b1;
                end
              end
            end
          end
        end
        DCACHE_INV_REQ: begin
          inv_vld     = mem_rtrn_i.inv.vld | mem_rtrn_i.inv.all;
          inv_vld_all = mem_rtrn_i.inv.all;
        end
        // TODO:
        // DCACHE_INT_REQ: begin
        // end
        default: begin
        end
      endcase
    end
  end

  // to write buffer
  assign miss_rtrn_id_o = mem_rtrn_i.tid;

  ///////////////////////////////////////////////////////
  // writes to cache memory
  ///////////////////////////////////////////////////////

  // cacheline write port
  assign wr_cl_nc_o = mshr_q.nc;
  assign wr_cl_vld_o = load_ack | (|wr_cl_we_o);

  assign wr_cl_we_o = (flush_en || cas_inv || inv_vld_all) ? '1 :
                      (inv_vld) ? dcache_way_bin2oh(mem_rtrn_i.inv.way) :
                      (cl_write_en) ? dcache_way_bin2oh(mshr_q.repl_way) : '0;

  assign wr_vld_bits_o = (flush_en || cas_inv || inv_vld) ? '0 :
                         (cl_write_en) ? dcache_way_bin2oh(mshr_q.repl_way) : '0;

  assign wr_cl_idx_o =
      (COH_VALIDATE && inv_vld) ? mem_rtrn_i.inv.idx[G6LCCfg.DCACHE_INDEX_WIDTH-1:G6LCCfg.DCACHE_OFFSET_WIDTH] :
      (flush_en) ? cnt_q :
      (cas_inv)  ? amo_req_i.operand_a[G6LCCfg.DCACHE_INDEX_WIDTH-1:G6LCCfg.DCACHE_OFFSET_WIDTH] :
      (inv_vld)  ? mem_rtrn_i.inv.idx[G6LCCfg.DCACHE_INDEX_WIDTH-1:G6LCCfg.DCACHE_OFFSET_WIDTH] :
                   mshr_q.paddr[G6LCCfg.DCACHE_INDEX_WIDTH-1:G6LCCfg.DCACHE_OFFSET_WIDTH];

  assign wr_cl_tag_o = mshr_q.paddr[G6LCCfg.DCACHE_TAG_WIDTH+G6LCCfg.DCACHE_INDEX_WIDTH-1:G6LCCfg.DCACHE_INDEX_WIDTH];
  assign wr_cl_off_o = mshr_q.paddr[G6LCCfg.DCACHE_OFFSET_WIDTH-1:0];
  // In-flight refill export (same index slice as wr_cl_idx_o's MSHR arm).
  assign mshr_vld_o    = mshr_vld_q;
  assign mshr_cl_idx_o = mshr_q.paddr[G6LCCfg.DCACHE_INDEX_WIDTH-1:G6LCCfg.DCACHE_OFFSET_WIDTH];
  assign wr_cl_data_o = mem_rtrn_i.data;
  assign wr_cl_user_o = mem_rtrn_i.user;
  assign wr_cl_data_be_o = (cl_write_en) ? '1 : '0;// we only write complete cachelines into the memory

  // only non-NC responses write to the cache
  assign cl_write_en = load_ack & ~mshr_q.nc & ~fill_killed_q;

  ///////////////////////////////////////////////////////
  // main control logic for generating tx
  ///////////////////////////////////////////////////////

  // Bare idents so the load-miss arm is not a compound guard.
  logic miss_can_take, miss_replay_hit;
  assign miss_replay_hit = mshr_rdrd_collision_d[miss_port_idx] || tx_rdwr_collision;
  assign miss_can_take   = !miss_is_write && (!mshr_vld_q || load_ack);
  // Load-miss memory request. Kept out of the IDLE priority nest so the
  // valid bit is not charged for every preceding guard.
  // CAS match is two half compares. They read the same return dword
  // and do not depend on each other.
  logic cas_eq_lo, cas_eq_hi, cas_eq;
  assign cas_eq_lo = amo_rtrn_mux[31:0] == amo_req_i.operand_c[31:0];
  assign cas_eq_hi = amo_rtrn_mux[63:32] == amo_req_i.operand_c[63:32];
  assign cas_eq    = cas_eq_lo && cas_eq_hi;
  logic load_miss_go;
  assign load_miss_go = (state_q == IDLE) && !(flush_i || (enable_i && !enable_q)) &&
                        !(G6LCCfg.RVA && amo_req_i.req) && (|miss_req_masked_d) &&
                        miss_can_take && !miss_replay_hit;
  // Replay is one bit per miss port. The old write was miss_replay_o[idx]
  // under the IDLE nest, and that index was the 18 FO4 field.
  logic miss_replay_take;
  assign miss_replay_take = (state_q == IDLE) && !(flush_i || (enable_i && !enable_q)) &&
                            !(G6LCCfg.RVA && amo_req_i.req) && (|miss_req_masked_d) &&
                            miss_can_take && miss_replay_hit;
  for (genvar p = 0; p < NumPorts; p++) begin : gen_replay
    assign miss_replay_o[p] = miss_replay_take &&
                              (miss_port_idx == $clog2(NumPorts)'(p));
  end

  always_comb begin : p_fsm
    // default assignment
    state_d          = state_q;

    flush_ack_o      = 1'b0;
    mem_req_c.rtype = DCACHE_LOAD_REQ;
    mem_req_valid_c   = 1'b0;
    amo_resp_o.ack   = 1'b0;
    amo_resp_o.result_hi = '0;
    amo_resp_o.dual_we = 1'b0;
    // miss_replay_o is the per-port assign below.

    // disabling cache is possible anytime, enabling goes via flush
    enable_d         = enable_q & enable_i;
    flush_ack_d      = flush_ack_q;
    flush_en         = 1'b0;
    amo_sel          = 1'b0;
    cas_amo_sel      = 1'b0;
    cas_inv          = 1'b0;
    cas_old_d        = cas_old_q;
    cas_new_d        = cas_new_q;
    update_lfsr      = 1'b0;
    mshr_allocate    = 1'b0;
    lock_reqs        = 1'b0;
    mask_reads       = mshr_vld_q;

    // interfaces
    unique case (state_q)
      //////////////////////////////////
      // wait for misses / amo ops
      IDLE: begin
        if (flush_i || (enable_i && !enable_q)) begin
          if (wbuffer_empty_i && !mshr_vld_q) begin
            flush_ack_d = flush_i;
            state_d     = FLUSH;
          end else begin
            state_d = DRAIN;
          end
        end else if (G6LCCfg.RVA && amo_req_i.req) begin
          if (wbuffer_empty_i && !mshr_vld_q) begin
            state_d = AMO;
          end else begin
            state_d = DRAIN;
          end
          // we've got a miss to handle
        end else if (|miss_req_masked_d) begin
          // this is a write miss, just pass through (but check whether write collides with MSHR)
          if (miss_is_write) begin
            // stall in case this write collides with the MSHR address
            if (!mshr_rdwr_collision) begin
              mem_req_valid_c   = 1'b1;
              mem_req_c.rtype = DCACHE_STORE_REQ;
              if (!mem_data_ack_i) begin
                state_d = STORE_WAIT;
              end
            end
            // this is a read miss, can only allocate 1 MSHR
            // in case of a load_ack we can accept a new miss, since the MSHR is being cleared
          end else if (miss_can_take) begin
            // replay the read request in case the address has collided with MSHR during the time the request was pending
            // i.e., the cache state may have been updated in the mean time due to a refill at the same CL address
            if (miss_replay_hit) begin
              // replay pulse is the per-port assign; this arm only holds the
              // load off the memory request.
              // Replay a load miss that collides with an in-flight store TX until
              // the write-through completes. The store can still retire because
              // the load is not issued, so the arbiter can select the store port
              // in the next cycle.
            end
          end
        end
        if (load_miss_go) begin
          mem_req_valid_c = 1'b1;
          mem_req_c.rtype = DCACHE_LOAD_REQ;
          update_lfsr     = all_ways_valid & mem_data_ack_i;
          mshr_allocate   = mem_data_ack_i;
          if (!mem_data_ack_i) state_d = LOAD_WAIT;
        end
      end
      //////////////////////////////////
      // wait until this request is acked
      STORE_WAIT: begin
        lock_reqs        = 1'b1;
        mem_req_valid_c   = 1'b1;
        mem_req_c.rtype = DCACHE_STORE_REQ;
        if (mem_data_ack_i) begin
          state_d = IDLE;
        end
      end
      //////////////////////////////////
      // wait until this request is acked
      LOAD_WAIT: begin
        lock_reqs        = 1'b1;
        mem_req_valid_c   = 1'b1;
        mem_req_c.rtype = DCACHE_LOAD_REQ;
        if (mem_data_ack_i) begin
          update_lfsr   = all_ways_valid;  // need to evict a random way
          mshr_allocate = 1'b1;
          state_d       = IDLE;
        end
      end
      //////////////////////////////////
      // only handle stores, do not accept new read requests
      // wait until MSHR is cleared and wbuffer is empty
      DRAIN: begin
        mask_reads = 1'b1;
        // these are writes, check whether they collide with MSHR
        if (|miss_req_masked_d && !mshr_rdwr_collision) begin
          mem_req_valid_c   = 1'b1;
          mem_req_c.rtype = DCACHE_STORE_REQ;
        end

        if (wbuffer_empty_i && !mshr_vld_q) begin
          state_d = IDLE;
        end
      end
      //////////////////////////////////
      // flush the cache
      FLUSH: begin
        // internal flush signal
        flush_en = 1'b1;
        if (flush_done && !(COH_VALIDATE && inv_vld)) begin
          state_d     = IDLE;
          flush_ack_o = flush_ack_q;
          flush_ack_d = 1'b0;
          enable_d    = enable_i;
        end
      end
      //////////////////////////////////
      // send out amo op request
      AMO: begin
        if (G6LCCfg.RVA) begin
          if (cas_local_en) begin
            // AMOCAS.D: local uncached load → compare → store
            state_d = AMO_CAS_LD;
          end else begin
            mem_req_c.rtype = DCACHE_ATOMIC_REQ;
            amo_sel          = 1'b1;
            // if this is an LR, we need to consult the backoff counter
            if ((amo_req_i.amo_op != AMO_LR) || sc_backoff_over) begin
              mem_req_valid_c = 1'b1;
              if (mem_data_ack_i) begin
                state_d = AMO_WAIT;
              end
            end
          end
        end
      end
      //////////////////////////////////
      // block and wait until AMO OP returns
      AMO_WAIT: begin
        if (G6LCCfg.RVA) begin
          amo_sel = 1'b1;
          if (amo_ack) begin
            // hyp8: the result formation registers at this edge; the ack is
            // presented in AMO_RESULT (+1 cycle). AMO depth-1 is preserved —
            // the unit accepts no new AMO until IDLE.
            state_d        = AMO_RESULT_FORM;
          end
        end
      end
      //////////////////////////////////
      // r75: raw word captured at the ATOMIC_ACK edge, formed word captured
      // at this edge, presented in AMO_RESULT.
      AMO_RESULT_FORM: begin
        if (G6LCCfg.RVA) state_d = AMO_RESULT;
      end
      //////////////////////////////////
      // hyp8: registered AMO result step — amo_resp_o.ack + result two cycles
      // after the ATOMIC_ACK (the consumer sees a registered formation).
      AMO_RESULT: begin
        if (G6LCCfg.RVA) begin
          amo_resp_o.ack = 1'b1;
          state_d        = IDLE;
        end
      end
      //////////////////////////////////
      // AMOCAS.D local RMW: issue uncached load of the CAS address
      AMO_CAS_LD: begin
        if (G6LCCfg.RVA) begin
          cas_amo_sel      = 1'b1;
          mem_req_c.rtype = DCACHE_LOAD_REQ;
          mem_req_valid_c   = 1'b1;
          if (mem_data_ack_i) begin
            state_d = AMO_CAS_LD_WAIT;
          end
        end
      end
      AMO_CAS_LD_WAIT: begin
        if (G6LCCfg.RVA) begin
          cas_amo_sel = 1'b1;
          if (cas_ld_ack) begin
            // Full 64-bit lane (dword CAS is naturally aligned)
            cas_old_d = amo_rtrn_mux;
            cas_new_d = cas_eq ? amo_req_i.operand_b : amo_rtrn_mux;
            state_d   = AMO_CAS_ST;
          end
        end
      end
      AMO_CAS_ST: begin
        if (G6LCCfg.RVA) begin
          cas_amo_sel      = 1'b1;
          mem_req_c.rtype = DCACHE_STORE_REQ;
          mem_req_valid_c   = 1'b1;
          if (mem_data_ack_i) begin
            state_d = AMO_CAS_ST_WAIT;
          end
        end
      end
      AMO_CAS_ST_WAIT: begin
        if (G6LCCfg.RVA) begin
          cas_amo_sel = 1'b1;
          if (cas_st_ack) begin
            // Drop L1 line for CAS paddr (uncached store does not update D$).
            cas_inv        = 1'b1;
            amo_resp_o.ack = 1'b1;
            state_d        = IDLE;
          end
        end
      end
      //////////////////////////////////
      default: begin
        // we should never get here
        state_d = IDLE;
      end
    endcase  // state_q
  end

  ///////////////////////////////////////////////////////
  // ff's
  ///////////////////////////////////////////////////////

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_regs
    if (!rst_ni) begin
      state_q               <= FLUSH;
      cnt_q                 <= '0;
      enable_q              <= '0;
      flush_ack_q           <= '0;
      mshr_vld_q            <= '0;
      mshr_vld_q1           <= '0;
      mshr_q                <= '0;
      mshr_rdrd_collision_q <= '0;
      miss_req_masked_q     <= '0;
      amo_req_q             <= '0;
      stores_inflight_q     <= '0;
      cas_old_q             <= '0;
      cas_new_q             <= '0;
    end else begin
      state_q               <= state_d;
      cnt_q                 <= cnt_d;
      enable_q              <= enable_d;
      flush_ack_q           <= flush_ack_d;
      mshr_vld_q            <= mshr_vld_d;
      mshr_vld_q1           <= mshr_vld_q;
      mshr_q                <= mshr_d;
      mshr_rdrd_collision_q <= mshr_rdrd_collision_d;
      miss_req_masked_q     <= miss_req_masked_d;
      amo_req_q             <= amo_req_d;
      stores_inflight_q     <= stores_inflight_d;
      cas_old_q             <= cas_old_d;
      cas_new_q             <= cas_new_d;
    end
  end

  ///////////////////////////////////////////////////////
  // assertions
  ///////////////////////////////////////////////////////

  //pragma translate_off
  // +smt_mem_watch=<PA>: the AMO / invalidation / refill side of the watched
  // dword's line (the STQ, wbuffer and mem lookups print in their own units)
  bit smt_mu_trace, smt_mu_watch;
  logic [G6LCCfg.PLEN-1:0] smt_mu_address;
  int unsigned smt_mu_cycle = 0;
  logic [G6LCCfg.DCACHE_MAX_TX-1:0] smt_txv_q = '0;
  initial begin
    smt_mu_watch = $value$plusargs("smt_mem_watch=%h", smt_mu_address);
    smt_mu_trace = $test$plusargs("smt_flow_trace") || smt_mu_watch;
  end
  always @(posedge clk_i) begin
    if (!rst_ni) smt_mu_cycle = 0;
    else if (smt_mu_trace) begin
      smt_mu_cycle++;
      if (G6LCCfg.RVA && mem_req_valid_c && (mem_req_c.rtype == DCACHE_ATOMIC_REQ) && (!smt_mu_watch ||
          (amo_req_i.operand_a[G6LCCfg.PLEN-1:3] == smt_mu_address[G6LCCfg.PLEN-1:3])))
        $display("[smt-flow] wt_amo_req cycle=%0d op=%0d pa=%h data=%h size=%0d ack=%b state=%0d",
                 smt_mu_cycle, amo_req_i.amo_op, amo_req_i.operand_a, amo_req_i.operand_b, amo_req_i.size,
                 mem_data_ack_i, state_q);
      if (G6LCCfg.RVA && amo_ack && (!smt_mu_watch ||
          (amo_req_i.operand_a[G6LCCfg.PLEN-1:3] == smt_mu_address[G6LCCfg.PLEN-1:3])))
        $display("[smt-flow] wt_amo_ack cycle=%0d op=%0d pa=%h result=%h",
                 smt_mu_cycle, amo_req_i.amo_op, amo_req_i.operand_a, amo_resp_o.result);
      if (inv_vld && (!smt_mu_watch ||
          mem_rtrn_i.inv.idx[G6LCCfg.DCACHE_INDEX_WIDTH-1:G6LCCfg.DCACHE_OFFSET_WIDTH] ==
          smt_mu_address[G6LCCfg.DCACHE_INDEX_WIDTH-1:G6LCCfg.DCACHE_OFFSET_WIDTH]))
        $display("[smt-flow] wt_inv cycle=%0d idx=%h all=%b way=%0d ways=%h state=%0d",
                 smt_mu_cycle, wr_cl_idx_o, inv_vld_all, mem_rtrn_i.inv.way, wr_cl_we_o, state_q);
      if (cl_write_en && (!smt_mu_watch ||
          mshr_q.paddr[G6LCCfg.DCACHE_INDEX_WIDTH-1:G6LCCfg.DCACHE_OFFSET_WIDTH] ==
          smt_mu_address[G6LCCfg.DCACHE_INDEX_WIDTH-1:G6LCCfg.DCACHE_OFFSET_WIDTH]))
        $display("[smt-flow] wt_refill cycle=%0d idx=%h tag=%h way=%0d nc=%b data=%h",
                 smt_mu_cycle, wr_cl_idx_o, wr_cl_tag_o, mshr_q.repl_way, mshr_q.nc, wr_cl_data_o);
      // Return-channel ledger: every memory return the adapter presents, the
      // demux verdict, and the in-flight store count that gates the write
      // port's miss_rtrn_vld. Unfiltered — returns are rare.
      if (mem_rtrn_vld_i)
        $display("[smt-flow] wt_rtrn cycle=%0d rtype=%0d tid=%0d sinf=%0d mshrv=%b mpi=%0d st=%0d sack=%b lack=%b",
                 smt_mu_cycle, mem_rtrn_i.rtype, mem_rtrn_i.tid, stores_inflight_q,
                 mshr_vld_q, mshr_q.miss_port_idx, state_q, store_ack, load_ack);
      if (store_sent)
        $display("[smt-flow] wt_ssent cycle=%0d tid=%0d pa=%h sinf=%0d",
                 smt_mu_cycle, mem_req_c.tid, mem_req_c.paddr, stores_inflight_q);
      if (|miss_replay_o)
        $display("[smt-flow] wt_replay cycle=%0d idx=%0d paddr=%h txcol=%b rdcol=%b mreq=%b mreqm=%b can=%b st=%0d txv=%h",
                 smt_mu_cycle, miss_port_idx, miss_paddr_i[miss_port_idx],
                 tx_rdwr_collision, mshr_rdrd_collision_d[miss_port_idx],
                 miss_req_i, miss_req_masked_d, miss_can_take, state_q, tx_vld_i);
      if (tx_vld_i != smt_txv_q) begin
        for (int t = 0; t < G6LCCfg.DCACHE_MAX_TX; t++)
          if (tx_vld_i[t] != smt_txv_q[t])
            $display("[smt-flow] wt_txv cycle=%0d slot=%0d vld=%b pa=%h",
                     smt_mu_cycle, t, tx_vld_i[t], tx_paddr_i[t]);
        smt_txv_q <= tx_vld_i;
      end
    end
  end
`ifndef VERILATOR

  read_tid :
  assert property (
    @(posedge clk_i) disable iff (!rst_ni) mshr_vld_q |-> mem_rtrn_vld_i |-> load_ack |-> mem_rtrn_i.tid == mshr_q.id)
  else $fatal(1, "[l1 dcache missunit] TID of load response doesn't match");

  read_ports :
  assert property (
    @(posedge clk_i) disable iff (!rst_ni) |miss_req_i[NumPorts-2:0] |-> miss_we_i[NumPorts-2:0] == 0)
  else $fatal(1, "[l1 dcache missunit] only last port can issue write requests");

  write_port :
  assert property (
    @(posedge clk_i) disable iff (!rst_ni) miss_req_i[NumPorts-1] |-> miss_we_i[NumPorts-1])
  else $fatal(1, "[l1 dcache missunit] last port can only issue write requests");

  initial begin
    // assert wrong parameterizations
    assert (NumPorts >= 2)
    else
      $fatal(
          1, "[l1 dcache missunit] at least two ports are required (one read port, one write port)"
      );
  end
`endif
  //pragma translate_on

endmodule  // wt_dcache_missunit
