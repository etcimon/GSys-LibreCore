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
// Date: 08.08.2018
// Modified by: Etienne Cimon
// Description: adapter module to connect the L1D$ and L1I$ to a 64bit AXI bus.
//


module wt_axi_adapter
  import g6lc_core_pkg::*;
  import wt_cache_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter int unsigned ReqFifoDepth = 2,
    parameter int unsigned MetaFifoDepth = G6LCCfg.DCACHE_MAX_TX,
    parameter type axi_req_t = logic,
    parameter type axi_rsp_t = logic,
    parameter type dcache_req_t = logic,
    parameter type dcache_rtrn_t = logic,
    parameter type dcache_inval_t = logic,
    parameter type icache_req_t = logic,
    parameter type icache_rtrn_t = logic
) (
    input logic clk_i,
    input logic rst_ni,

    // icache
    input  logic         icache_data_req_i,
    output logic         icache_data_ack_o,
    input  icache_req_t  icache_data_i,
    // returning packets must be consumed immediately
    output logic         icache_rtrn_vld_o,
    output icache_rtrn_t icache_rtrn_o,

    // dcache
    input  logic         dcache_data_req_i,
    output logic         dcache_data_ack_o,
    input  dcache_req_t  dcache_data_i,
    // returning packets must be consumed immediately
    output logic         dcache_rtrn_vld_o,
    output dcache_rtrn_t dcache_rtrn_o,

    // AXI port
    output axi_req_t axi_req_o,
    input  axi_rsp_t axi_resp_i,

    // Endianness Control Signal from CSR
    input logic mbe_i,

    // Invalidations
    input  logic [63:0] inval_addr_i,
    input  logic        inval_valid_i,
    output logic        inval_ready_o,
    output logic        inval_apply_valid_o,
    output logic [63:0] inval_apply_addr_o
);

  // A139 design proposal; vocabulary: architecture/RTL-PIPELINE-PLANS.md.
  // svt-plan: begin wt_axi_adapter status=proposal target=10-adjusted-FO4
  // svt-plan: cone AXI return classification and invalidate/response
  // arbitration feed self-invalidation pending state and cache return outputs.
  // svt-plan: boundary accepted bus response -> decoded held return event;
  // distinguish transport completion from cache invalidation visibility.
  // svt-plan: carry source channel, ID, data/user, response/error/last,
  // cache transaction identity and associated invalidation address/order.
  // svt-plan: capacity assert AXI ready only with actual return storage;
  // retain self-invalidation until apply handshake, not merely bus acceptance.
  // svt-plan: effect separates external return mux/decode from coherence
  // action selection; use bounded local arbitration for each response class.
  // svt-plan: cost return slots and completion latency; preserve read/write
  // ordering and drain pending events before fence/empty completion.
  // svt-plan: limit bus buffering cannot reorder an invalidate behind a
  // response that would expose stale data; queues must have an explicit order.
  // svt-plan: end
  // Re-pipelining contract (sv-timing A128; 29.8 adjusted FO4 on the
  // Nangate45 board): AXI adapter: request / response FSMs.
  // svt-pipe: require-contract
  // svt-pipe: protocol ax valid=inval_valid_i
  // svt-pipe: no-cut on=self_inval_pend_q
  // svt-pipe: cycle ax q=self_inval_pend_q d=inval_apply_valid_o hold=inval_valid_i steps=1

  // support up to 512bit cache lines
  localparam AxiNumWords = (G6LCCfg.ICACHE_LINE_WIDTH/G6LCCfg.AxiDataWidth) * (G6LCCfg.ICACHE_LINE_WIDTH > G6LCCfg.DCACHE_LINE_WIDTH)  +
                           (G6LCCfg.DCACHE_LINE_WIDTH/G6LCCfg.AxiDataWidth) * (G6LCCfg.ICACHE_LINE_WIDTH <= G6LCCfg.DCACHE_LINE_WIDTH) ;
  localparam MaxNumWords = $clog2(G6LCCfg.AxiDataWidth / 8);
  localparam AxiRdBlenIcache = G6LCCfg.ICACHE_LINE_WIDTH / G6LCCfg.AxiDataWidth - 1;
  localparam AxiRdBlenDcache = G6LCCfg.DCACHE_LINE_WIDTH / G6LCCfg.AxiDataWidth - 1;
  localparam AxiBlenWidth = AxiNumWords > 1 ? $clog2(AxiNumWords) : AxiNumWords;

  ///////////////////////////////////////////////////////
  // request path
  ///////////////////////////////////////////////////////

  icache_req_t icache_data;
  logic icache_data_full, icache_data_empty;
  dcache_req_t dcache_data;
  logic dcache_data_full, dcache_data_empty;

  logic [1:0] arb_req, arb_ack;
  logic arb_idx, arb_gnt;

  logic axi_rd_req, axi_rd_gnt;
  logic axi_wr_req, axi_wr_gnt;
  logic axi_wr_valid, axi_rd_valid, axi_rd_rdy, axi_wr_rdy;
  logic axi_rd_lock, axi_wr_lock, axi_rd_exokay, axi_wr_exokay, wr_exokay;
  logic [G6LCCfg.AxiAddrWidth-1:0] axi_rd_addr, axi_wr_addr;
  logic [AxiBlenWidth-1:0] axi_rd_blen, axi_wr_blen;
  logic [2:0] axi_rd_size, axi_wr_size;
  logic [G6LCCfg.AxiIdWidth-1:0]
      axi_rd_id_in, axi_wr_id_in, axi_rd_id_out, axi_wr_id_out, wr_id_out;
  logic [AxiNumWords-1:0][G6LCCfg.AxiDataWidth-1:0] axi_wr_data;
  logic [AxiNumWords-1:0][G6LCCfg.AxiUserWidth-1:0] axi_wr_user;
  logic [G6LCCfg.AxiDataWidth-1:0] axi_rd_data;
  logic [G6LCCfg.AxiUserWidth-1:0] axi_rd_user;
  logic [AxiNumWords-1:0][(G6LCCfg.AxiDataWidth/8)-1:0] axi_wr_be;
  logic [5:0] axi_wr_atop;
  logic invalidate;
  logic [$clog2(G6LCCfg.AxiDataWidth/8)-1:0] amo_off_d, amo_off_q;
  // AMO generates r beat
  logic amo_gen_r_d, amo_gen_r_q;

  logic [G6LCCfg.MEM_TID_WIDTH-1:0] icache_rtrn_tid_d, icache_rtrn_tid_q;
  logic [G6LCCfg.MEM_TID_WIDTH-1:0] dcache_rtrn_tid_d, dcache_rtrn_tid_q;
  logic [G6LCCfg.MEM_TID_WIDTH-1:0] dcache_rtrn_rd_tid, dcache_rtrn_wr_tid;
  logic dcache_rd_pop, dcache_wr_pop;
  logic icache_rd_full, icache_rd_empty;
  logic dcache_rd_full, dcache_rd_empty;
  logic dcache_wr_full, dcache_wr_empty;

  

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=wt_axi_adapter  region=4362  makespan=28.500 FO4  cycle_count=4  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: inval_apply_addr_o  ready_cycle=4  ready_fo4=28.500  OpenSTA: report_timing -from clk_i -to inval_apply_addr_o
// order expect: inval_apply_valid_o  ready_cycle=1  ready_fo4=4.768  OpenSTA: report_timing -from clk_i -to inval_apply_valid_o
// --- factor stage 1/4  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     inval_apply_valid_o <= …; // sv-timing: cycle 1/4 on clk_i
//     /* node15147 c=3.50 slack=25.00 */
//     /* node15148 c=3.50 slack=25.00 */
//     /* node15149 c=4.77 slack=23.73 */
//   end
// end
// --- factor stage 2/4  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 2: no capture on this edge (slack) */
//   end
// end
// --- factor stage 3/4  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 3: no capture on this edge (slack) */
//   end
// end
// --- factor stage 4/4  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     inval_apply_addr_o <= …; // sv-timing: cycle 4/4 on clk_i
//     /* node15150 c=28.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=wt_axi_adapter  region=4365  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: amo_gen_r_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to amo_gen_r_q
// order expect: amo_off_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to amo_off_q
// order expect: dcache_first_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to dcache_first_q
// order expect: dcache_rd_shift_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to dcache_rd_shift_q
// order expect: dcache_rd_shift_user_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to dcache_rd_shift_user_q
// order expect: dcache_rtrn_inv_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to dcache_rtrn_inv_q
// order expect: dcache_rtrn_tid_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to dcache_rtrn_tid_q
// order expect: dcache_rtrn_type_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to dcache_rtrn_type_q
// order expect: dcache_rtrn_vld_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to dcache_rtrn_vld_q
// order expect: icache_first_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to icache_first_q
// order expect: icache_rd_shift_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to icache_rd_shift_q
// order expect: icache_rd_shift_user_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to icache_rd_shift_user_q
// order expect: icache_rtrn_tid_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to icache_rtrn_tid_q
// order expect: icache_rtrn_vld_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to icache_rtrn_vld_q
// order expect: self_inval_addr_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to self_inval_addr_q
// order expect: self_inval_pend_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to self_inval_pend_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     amo_gen_r_q <= …; // sv-timing: cycle 1/1 on clk_i
//     amo_off_q <= …; // sv-timing: cycle 1/1 on clk_i
//     dcache_first_q <= …; // sv-timing: cycle 1/1 on clk_i
//     dcache_rd_shift_q <= …; // sv-timing: cycle 1/1 on clk_i
//     dcache_rd_shift_user_q <= …; // sv-timing: cycle 1/1 on clk_i
//     dcache_rtrn_inv_q <= …; // sv-timing: cycle 1/1 on clk_i
//     dcache_rtrn_tid_q <= …; // sv-timing: cycle 1/1 on clk_i
//     dcache_rtrn_type_q <= …; // sv-timing: cycle 1/1 on clk_i
//     dcache_rtrn_vld_q <= …; // sv-timing: cycle 1/1 on clk_i
//     icache_first_q <= …; // sv-timing: cycle 1/1 on clk_i
//     icache_rd_shift_q <= …; // sv-timing: cycle 1/1 on clk_i
//     icache_rd_shift_user_q <= …; // sv-timing: cycle 1/1 on clk_i
//     icache_rtrn_tid_q <= …; // sv-timing: cycle 1/1 on clk_i
//     icache_rtrn_vld_q <= …; // sv-timing: cycle 1/1 on clk_i
//     self_inval_addr_q <= …; // sv-timing: cycle 1/1 on clk_i
//     self_inval_pend_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node15153 c=3.50 slack=0.00 */
//     /* node15154 c=3.50 slack=0.00 */
//     /* node15155 c=3.50 slack=0.00 */
//     /* node15156 c=3.50 slack=0.00 */
//     /* node15157 c=3.50 slack=0.00 */
//     /* node15158 c=3.50 slack=0.00 */
//     /* node15159 c=3.50 slack=0.00 */
//     /* node15160 c=3.50 slack=0.00 */
//     /* node15161 c=3.50 slack=0.00 */
//     /* node15162 c=3.50 slack=0.00 */
//     /* node15163 c=3.50 slack=0.00 */
//     /* node15164 c=3.50 slack=0.00 */
//     /* node15165 c=3.50 slack=0.00 */
//     /* node15166 c=3.50 slack=0.00 */
//     /* node15167 c=3.50 slack=0.00 */
//     /* node15168 c=3.50 slack=0.00 */
//     /* node15169 c=3.50 slack=0.00 */
//     /* node15170 c=3.50 slack=0.00 */
//     /* node15171 c=3.50 slack=0.00 */
//     /* node15172 c=3.50 slack=0.00 */
//     /* node15173 c=3.50 slack=0.00 */
//     /* node15174 c=3.50 slack=0.00 */
//     /* node15175 c=3.50 slack=0.00 */
//     /* node15176 c=3.50 slack=0.00 */
//     /* node15177 c=3.50 slack=0.00 */
//     /* node15178 c=3.50 slack=0.00 */
//     /* node15179 c=3.50 slack=0.00 */
//     /* node15180 c=3.50 slack=0.00 */
//     /* node15181 c=3.50 slack=0.00 */
//     /* node15182 c=3.50 slack=0.00 */
//     /* node15183 c=3.50 slack=0.00 */
//     /* node15184 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
assign icache_data_ack_o = icache_data_req_i & ~icache_data_full;
  assign dcache_data_ack_o = dcache_data_req_i & ~dcache_data_full;

  // arbiter
  assign arb_req = {
    ~(dcache_data_empty | dcache_wr_full | dcache_rd_full), ~(icache_data_empty | icache_rd_full)
  };

  assign arb_gnt = axi_rd_gnt | axi_wr_gnt;

  // This site requires the vendor hold-until-grant contract: gnt_o stays
  // asserted while the head is presented and retires on gnt_i. The
  // adapter's request pops (`pop_i = arb_ack[i]`) and the meta-fifo pushes
  // (`arb_ack[i] & axi_rd_gnt`) pair capture with the downstream grant, and
  // `|arb_req` must stay asserted through the grant cycle so p_axi_req can
  // decode the still-present fifo head. g6lc_hyp_rr_arb_tree (capture-pulse
  // gnt_o, +1 latency) breaks all three — observed in M3 bring-up as an AR
  // issued with the tid meta-fifo never pushed (bringup-log H40).
  rr_arb_tree #(
      .NumIn    (2),
      .DataWidth(1),
      .AxiVldRdy(1'b1),
      .LockIn   (1'b1)
  ) i_rr_arb_tree (
      .clk_i  (clk_i),
      .rst_ni (rst_ni),
      .flush_i('0),
      .rr_i   ('0),
      .req_i  (arb_req),
      .gnt_o  (arb_ack),
      .data_i ('0),
      .gnt_i  (arb_gnt),
      .req_o  (),
      .data_o (),
      .idx_o  (arb_idx)
  );

  // request side
  always_comb begin : p_axi_req
    // write channel
    axi_wr_id_in = {{G6LCCfg.AxiIdWidth-1{1'b0}}, arb_idx};
    axi_wr_data[0]  = {(G6LCCfg.AxiDataWidth/G6LCCfg.XLEN){dcache_data.data}};
    axi_wr_user[0]  = dcache_data.user;
    // Cast to AXI address width
    axi_wr_addr  = G6LCCfg.AxiAddrWidth'(dcache_data.paddr);
    axi_wr_size  = dcache_data.size;
    axi_wr_req   = 1'b0;
    axi_wr_blen  = '0;// single word writes
    axi_wr_be    = '0;
    axi_wr_lock  = '0;
    axi_wr_atop  = '0;
    amo_off_d    = amo_off_q;
    amo_gen_r_d  = amo_gen_r_q;

    // read channel
    axi_rd_id_in = {{G6LCCfg.AxiIdWidth-1{1'b0}}, arb_idx};
    axi_rd_req   = 1'b0;
    axi_rd_lock  = '0;
    axi_rd_blen  = '0;

    if (dcache_data.paddr[2] == 1'b0) begin
      axi_wr_user = {{$bits(axi_wr_user) - G6LCCfg.AxiUserWidth{1'b0}}, dcache_data.user};
    end else begin
      axi_wr_user = {dcache_data.user, {$bits(axi_wr_user) - G6LCCfg.AxiUserWidth{1'b0}}};
    end

    // arbiter mux
    if (arb_idx) begin
      // Cast to AXI address width
      axi_rd_addr = G6LCCfg.AxiAddrWidth'(dcache_data.paddr);
      // If dcache_data.size MSB is set, we want to read as much as possible
      axi_rd_size = dcache_data.size[2] ? MaxNumWords[2:0] : dcache_data.size;
      if (dcache_data.size[2]) begin
        axi_rd_blen = AxiRdBlenDcache[AxiBlenWidth-1:0];
      end
    end else begin
      // Cast to AXI address width
      axi_rd_addr = G6LCCfg.AxiAddrWidth'(icache_data.paddr);
      axi_rd_size = MaxNumWords[2:0];  // always request max number of words in case of ifill
      if (!icache_data.nc) begin
        axi_rd_blen = AxiRdBlenIcache[AxiBlenWidth-1:0];
      end
    end

    // decode message type
    if (|arb_req) begin
      if (arb_idx == 0) begin
        //////////////////////////////////////
        // IMISS
        axi_rd_req = 1'b1;
        //////////////////////////////////////
      end else begin
        unique case (dcache_data.rtype)
          //////////////////////////////////////
          wt_cache_pkg::DCACHE_LOAD_REQ: begin
            axi_rd_req = 1'b1;
          end
          //////////////////////////////////////
          wt_cache_pkg::DCACHE_STORE_REQ: begin
            axi_wr_req = 1'b1;
            axi_wr_be  = '0;
            unique case (dcache_data.size[1:0])
              2'b00:
              axi_wr_be[0][dcache_data.paddr[$clog2(G6LCCfg.AxiDataWidth/8)-1:0]] = '1;  // byte
              2'b01:
              axi_wr_be[0][dcache_data.paddr[$clog2(G6LCCfg.AxiDataWidth/8)-1:0]+:2] = '1;  // hword
              2'b10:
              axi_wr_be[0][dcache_data.paddr[$clog2(G6LCCfg.AxiDataWidth/8)-1:0]+:4] = '1;  // word
              default:
              if (G6LCCfg.IS_XLEN64)
                axi_wr_be[0][dcache_data.paddr[$clog2(
                    G6LCCfg.AxiDataWidth/8
                )-1:0]+:8] = '1;  // dword
            endcase
          end
          //////////////////////////////////////
          wt_cache_pkg::DCACHE_ATOMIC_REQ: begin
            if (G6LCCfg.RVA) begin
              // default
              // The invalidate pulse is the continuous assign below
              // (arb_gnt on this atomic arm). One read is in flight and
              // the dcache drains before an atomic, so this is safe.
              axi_wr_req = 1'b1;
              axi_wr_be  = '0;
              unique case (dcache_data.size[1:0])
                2'b00:
                axi_wr_be[0][dcache_data.paddr[$clog2(G6LCCfg.AxiDataWidth/8)-1:0]] = '1;  // byte
                2'b01:
                axi_wr_be[0][dcache_data.paddr[$clog2(G6LCCfg.AxiDataWidth/8)-1:0]+:2] =
                    '1;  // hword
                2'b10:
                axi_wr_be[0][dcache_data.paddr[$clog2(G6LCCfg.AxiDataWidth/8)-1:0]+:4] =
                    '1;  // word
                default:
                axi_wr_be[0][dcache_data.paddr[$clog2(G6LCCfg.AxiDataWidth/8)-1:0]+:8] =
                    '1;  // dword
              endcase
              amo_gen_r_d = 1'b1;
              // need to use a separate ID here, so concat an additional bit
              axi_wr_id_in[1] = 1'b1;

              unique case (dcache_data.amo_op)
                AMO_LR: begin
                  axi_rd_lock     = 1'b1;
                  axi_rd_req      = 1'b1;
                  axi_rd_id_in[1] = 1'b1;
                  // tie to zero in this special case
                  axi_wr_req      = 1'b0;
                  axi_wr_be       = '0;
                end
                AMO_SC: begin
                  axi_wr_lock = 1'b1;
                  amo_gen_r_d = 1'b0;
                  // needed to properly encode success. store the result at offset within the returned
                  // AXI data word aligned with the requested word size.
                  amo_off_d = dcache_data.paddr[$clog2(G6LCCfg.AxiDataWidth/8)-
                                                1:0] & ~((1 << dcache_data.size[1:0]) - 1);
                end
                // RISC-V atops have a load semantic
                AMO_SWAP: axi_wr_atop = axi_pkg::ATOP_ATOMICSWAP;
                AMO_ADD: begin
                  if (mbe_i) begin
                    axi_wr_atop = {
                      axi_pkg::ATOP_ATOMICLOAD, axi_pkg::ATOP_BIG_END, axi_pkg::ATOP_ADD
                    };
                  end else begin
                    axi_wr_atop = {
                      axi_pkg::ATOP_ATOMICLOAD, axi_pkg::ATOP_LITTLE_END, axi_pkg::ATOP_ADD
                    };
                  end
                end
                AMO_AND: begin
                  // in this case we need to invert the data to get a "CLR"
                  axi_wr_data[0] = ~{(G6LCCfg.AxiDataWidth / G6LCCfg.XLEN) {dcache_data.data}};
                  axi_wr_user = ~{AxiNumWords{dcache_data.user}};
                  if (mbe_i) begin
                    axi_wr_atop = {
                      axi_pkg::ATOP_ATOMICLOAD, axi_pkg::ATOP_BIG_END, axi_pkg::ATOP_CLR
                    };
                  end else begin
                    axi_wr_atop = {
                      axi_pkg::ATOP_ATOMICLOAD, axi_pkg::ATOP_LITTLE_END, axi_pkg::ATOP_CLR
                    };
                  end
                end
                AMO_OR: begin
                  if (mbe_i) begin
                    axi_wr_atop = {
                      axi_pkg::ATOP_ATOMICLOAD, axi_pkg::ATOP_BIG_END, axi_pkg::ATOP_SET
                    };
                  end else begin
                    axi_wr_atop = {
                      axi_pkg::ATOP_ATOMICLOAD, axi_pkg::ATOP_LITTLE_END, axi_pkg::ATOP_SET
                    };
                  end
                end
                AMO_XOR: begin
                  if (mbe_i) begin
                    axi_wr_atop = {
                      axi_pkg::ATOP_ATOMICLOAD, axi_pkg::ATOP_BIG_END, axi_pkg::ATOP_EOR
                    };
                  end else begin
                    axi_wr_atop = {
                      axi_pkg::ATOP_ATOMICLOAD, axi_pkg::ATOP_LITTLE_END, axi_pkg::ATOP_EOR
                    };
                  end
                end
                AMO_MAX: begin
                  if (mbe_i) begin
                    axi_wr_atop = {
                      axi_pkg::ATOP_ATOMICLOAD, axi_pkg::ATOP_BIG_END, axi_pkg::ATOP_SMAX
                    };
                  end else begin
                    axi_wr_atop = {
                      axi_pkg::ATOP_ATOMICLOAD, axi_pkg::ATOP_LITTLE_END, axi_pkg::ATOP_SMAX
                    };
                  end
                end
                AMO_MAXU: begin
                  if (mbe_i) begin
                    axi_wr_atop = {
                      axi_pkg::ATOP_ATOMICLOAD, axi_pkg::ATOP_BIG_END, axi_pkg::ATOP_UMAX
                    };
                  end else begin
                    axi_wr_atop = {
                      axi_pkg::ATOP_ATOMICLOAD, axi_pkg::ATOP_LITTLE_END, axi_pkg::ATOP_UMAX
                    };
                  end
                end
                AMO_MIN: begin
                  if (mbe_i) begin
                    axi_wr_atop = {
                      axi_pkg::ATOP_ATOMICLOAD, axi_pkg::ATOP_BIG_END, axi_pkg::ATOP_SMIN
                    };
                  end else begin
                    axi_wr_atop = {
                      axi_pkg::ATOP_ATOMICLOAD, axi_pkg::ATOP_LITTLE_END, axi_pkg::ATOP_SMIN
                    };
                  end
                end
                AMO_MINU: begin
                  if (mbe_i) begin
                    axi_wr_atop = {
                      axi_pkg::ATOP_ATOMICLOAD, axi_pkg::ATOP_BIG_END, axi_pkg::ATOP_UMIN
                    };
                  end else begin
                    axi_wr_atop = {
                      axi_pkg::ATOP_ATOMICLOAD, axi_pkg::ATOP_LITTLE_END, axi_pkg::ATOP_UMIN
                    };
                  end
                end
                // Zacas AMOCAS: AtomicCompare; W data is {cmp,swap} from missunit
                AMO_CAS1: begin
                  axi_wr_atop = axi_pkg::ATOP_ATOMICCMP;
                  // Deliver full 64-bit pack so ALU sees both halves.
                  // On 64-bit AXI, $clog2(AxiDataWidth/8)=3 → paddr[2:3] would be
                  // reversed (slang -Wrange-select-reversed). Full beat BE is fine.
                  // Wider AXI: enable the 8-byte lane selected by paddr[msb:3].
                  if (G6LCCfg.AxiDataWidth >= 64 && dcache_data.size[1:0] == 2'b10) begin
                    axi_wr_be[0][7:0] = '1;
                  end
                end
                default:  ;  // Do nothing
              endcase
            end
          end
          default: ;  // Do nothing
          //////////////////////////////////////
        endcase
      end
    end
  end

  g6lc_fifo_v3 #(
      .FPGA_ALTERA(G6LCCfg.FpgaAlteraEn),
      .dtype(icache_req_t),
      .DEPTH(ReqFifoDepth),
      .FPGA_EN(G6LCCfg.FpgaEn)
  ) i_icache_data_fifo (
      .clk_i     (clk_i),
      .rst_ni    (rst_ni),
      .flush_i   (1'b0),
      .testmode_i(1'b0),
      .full_o    (icache_data_full),
      .empty_o   (icache_data_empty),
      .usage_o   (),
      .data_i    (icache_data_i),
      .push_i    (icache_data_ack_o),
      .data_o    (icache_data),
      .pop_i     (arb_ack[0])
  );

  g6lc_fifo_v3 #(
      .FPGA_ALTERA(G6LCCfg.FpgaAlteraEn),
      .dtype(dcache_req_t),
      .DEPTH(ReqFifoDepth),
      .FPGA_EN(G6LCCfg.FpgaEn)
  ) i_dcache_data_fifo (
      .clk_i     (clk_i),
      .rst_ni    (rst_ni),
      .flush_i   (1'b0),
      .testmode_i(1'b0),
      .full_o    (dcache_data_full),
      .empty_o   (dcache_data_empty),
      .usage_o   (),
      .data_i    (dcache_data_i),
      .push_i    (dcache_data_ack_o),
      .data_o    (dcache_data),
      .pop_i     (arb_ack[1])
  );

  ///////////////////////////////////////////////////////
  // meta info feedback fifos
  ///////////////////////////////////////////////////////

  logic icache_rtrn_rd_en, dcache_rtrn_rd_en;
  logic icache_rtrn_vld_d, icache_rtrn_vld_q, dcache_rtrn_vld_d, dcache_rtrn_vld_q;

  g6lc_fifo_v3 #(
      .DATA_WIDTH(G6LCCfg.MEM_TID_WIDTH),
      .DEPTH     (MetaFifoDepth),
      .FPGA_EN   (G6LCCfg.FpgaEn)
  ) i_rd_icache_id (
      .clk_i     (clk_i),
      .rst_ni    (rst_ni),
      .flush_i   (1'b0),
      .testmode_i(1'b0),
      .full_o    (icache_rd_full),
      .empty_o   (icache_rd_empty),
      .usage_o   (),
      .data_i    (icache_data.tid),
      .push_i    (arb_ack[0] & axi_rd_gnt),
      .data_o    (icache_rtrn_tid_d),
      .pop_i     (icache_rtrn_vld_d)
  );

  g6lc_fifo_v3 #(
      .DATA_WIDTH(G6LCCfg.MEM_TID_WIDTH),
      .DEPTH     (MetaFifoDepth),
      .FPGA_EN   (G6LCCfg.FpgaEn)
  ) i_rd_dcache_id (
      .clk_i     (clk_i),
      .rst_ni    (rst_ni),
      .flush_i   (1'b0),
      .testmode_i(1'b0),
      .full_o    (dcache_rd_full),
      .empty_o   (dcache_rd_empty),
      .usage_o   (),
      .data_i    (dcache_data.tid),
      .push_i    (arb_ack[1] & axi_rd_gnt),
      .data_o    (dcache_rtrn_rd_tid),
      .pop_i     (dcache_rd_pop)
  );

  g6lc_fifo_v3 #(
      .DATA_WIDTH(G6LCCfg.MEM_TID_WIDTH),
      .DEPTH     (MetaFifoDepth),
      .FPGA_EN   (G6LCCfg.FpgaEn)
  ) i_wr_dcache_id (
      .clk_i     (clk_i),
      .rst_ni    (rst_ni),
      .flush_i   (1'b0),
      .testmode_i(1'b0),
      .full_o    (dcache_wr_full),
      .empty_o   (dcache_wr_empty),
      .usage_o   (),
      .data_i    (dcache_data.tid),
      .push_i    (arb_ack[1] & axi_wr_gnt),
      .data_o    (dcache_rtrn_wr_tid),
      .pop_i     (dcache_wr_pop)
  );

  // select correct tid to return
  assign dcache_rtrn_tid_d = (dcache_wr_pop) ? dcache_rtrn_wr_tid : dcache_rtrn_rd_tid;

  ///////////////////////////////////////////////////////
  // return path
  ///////////////////////////////////////////////////////

  // buffer write responses
  logic b_full, b_empty, b_push, b_pop;
  assign axi_wr_rdy = ~b_full;
  assign b_push     = axi_wr_valid & axi_wr_rdy;

  g6lc_fifo_v3 #(
      .DATA_WIDTH  (G6LCCfg.AxiIdWidth + 1),
      .DEPTH       (MetaFifoDepth),
      .FALL_THROUGH(1'b1),
      .FPGA_EN     (G6LCCfg.FpgaEn)
  ) i_b_fifo (
      .clk_i     (clk_i),
      .rst_ni    (rst_ni),
      .flush_i   (1'b0),
      .testmode_i(1'b0),
      .full_o    (b_full),
      .empty_o   (b_empty),
      .usage_o   (),
      .data_i    ({axi_wr_exokay, axi_wr_id_out}),
      .push_i    (b_push),
      .data_o    ({wr_exokay, wr_id_out}),
      .pop_i     (b_pop)
  );

  // buffer read responses in shift regs
  logic icache_first_d, icache_first_q, dcache_first_d, dcache_first_q;
  logic [G6LCCfg.ICACHE_USER_LINE_WIDTH/G6LCCfg.AxiUserWidth-1:0][G6LCCfg.AxiUserWidth-1:0]
      icache_rd_shift_user_d, icache_rd_shift_user_q;
  logic [G6LCCfg.DCACHE_USER_LINE_WIDTH/G6LCCfg.AxiUserWidth-1:0][G6LCCfg.AxiUserWidth-1:0]
      dcache_rd_shift_user_d, dcache_rd_shift_user_q;
  logic [G6LCCfg.ICACHE_LINE_WIDTH/G6LCCfg.AxiDataWidth-1:0][G6LCCfg.AxiDataWidth-1:0]
      icache_rd_shift_d, icache_rd_shift_q;
  logic [G6LCCfg.DCACHE_LINE_WIDTH/G6LCCfg.AxiDataWidth-1:0][G6LCCfg.AxiDataWidth-1:0]
      dcache_rd_shift_d, dcache_rd_shift_q;
  wt_cache_pkg::dcache_in_t dcache_rtrn_type_d, dcache_rtrn_type_q;
  dcache_inval_t dcache_rtrn_inv_d, dcache_rtrn_inv_q;
  logic dcache_sc_rtrn, axi_rd_last;
  // Retained self-invalidation: the AMO invalidate pulse (arb_gnt) is a single
  // cycle, so an external invalidation or an already pending one displaces the
  // AMO's own DCACHE_INV_REQ. It is captured here and re-issued on the return
  // path before any other return traffic.
  logic self_inval_pend_q, self_inval_pend_d;
  logic [G6LCCfg.PLEN-1:0] self_inval_addr_q, self_inval_addr_d;

  always_comb begin : p_axi_rtrn_shift
    // output directly from regs
    icache_rtrn_o          = '0;
    icache_rtrn_o.rtype    = wt_cache_pkg::ICACHE_IFILL_ACK;
    icache_rtrn_o.tid      = icache_rtrn_tid_q;
    icache_rtrn_o.data     = icache_rd_shift_q;
    icache_rtrn_o.user     = icache_rd_shift_user_q;
    icache_rtrn_vld_o      = icache_rtrn_vld_q;

    dcache_rtrn_o          = '0;
    dcache_rtrn_o.rtype    = dcache_rtrn_type_q;
    dcache_rtrn_o.inv      = dcache_rtrn_inv_q;
    dcache_rtrn_o.tid      = dcache_rtrn_tid_q;
    dcache_rtrn_o.data     = dcache_rd_shift_q;
    dcache_rtrn_o.user     = dcache_rd_shift_user_q;
    dcache_rtrn_vld_o      = dcache_rtrn_vld_q;

    // read shift registers
    icache_rd_shift_d      = icache_rd_shift_q;
    icache_rd_shift_user_d = icache_rd_shift_user_q;
    dcache_rd_shift_d      = dcache_rd_shift_q;
    dcache_rd_shift_user_d = dcache_rd_shift_user_q;
    icache_first_d         = icache_first_q;
    dcache_first_d         = dcache_first_q;

    if (icache_rtrn_rd_en) begin
      icache_first_d = axi_rd_last;
      if (G6LCCfg.ICACHE_LINE_WIDTH == G6LCCfg.AxiDataWidth) begin
        icache_rd_shift_d[0] = axi_rd_data;
      end else begin
        icache_rd_shift_d = {
          axi_rd_data, icache_rd_shift_q[G6LCCfg.ICACHE_LINE_WIDTH/G6LCCfg.AxiDataWidth-1:1]
        };
      end
      icache_rd_shift_user_d = {
        axi_rd_user, icache_rd_shift_user_q[G6LCCfg.ICACHE_USER_LINE_WIDTH/G6LCCfg.AxiUserWidth-1:1]
      };
      // if this is a single word transaction, we need to make sure that word is placed at offset 0
      if (icache_first_q) begin
        icache_rd_shift_d[0] = axi_rd_data;
        icache_rd_shift_user_d[0] = axi_rd_user;
      end
    end

    if (dcache_rtrn_rd_en) begin
      dcache_first_d = axi_rd_last;
      if (G6LCCfg.DCACHE_LINE_WIDTH == G6LCCfg.AxiDataWidth) begin
        dcache_rd_shift_d[0] = axi_rd_data;
      end else begin
        dcache_rd_shift_d = {
          axi_rd_data, dcache_rd_shift_q[G6LCCfg.DCACHE_LINE_WIDTH/G6LCCfg.AxiDataWidth-1:1]
        };
      end
      dcache_rd_shift_user_d = {
        axi_rd_user, dcache_rd_shift_user_q[G6LCCfg.DCACHE_USER_LINE_WIDTH/G6LCCfg.AxiUserWidth-1:1]
      };
      // if this is a single word transaction, we need to make sure that word is placed at offset 0
      if (dcache_first_q) begin
        dcache_rd_shift_d[0] = axi_rd_data;
        dcache_rd_shift_user_d[0] = axi_rd_user;
      end
    end else if (G6LCCfg.RVA && dcache_sc_rtrn) begin
      // encode lr/sc success
      dcache_rd_shift_d[0] = '0;
      dcache_rd_shift_user_d[0] = '0;
      dcache_rd_shift_d[0][amo_off_q*8] = (wr_exokay) ? '0 : 1'b1;
      dcache_rd_shift_user_d[0][amo_off_q*8] = (wr_exokay) ? '0 : 1'b1;
    end
  end

  // One-bit priority for the return decoder. Bare idents below, so a
  // later arm does not pay every earlier predicate at the wide fields.
  logic rtrn_self, rtrn_ext, rtrn_inv, rtrn_rd, rtrn_b;
  assign axi_rd_rdy = ~invalidate && !self_inval_pend_q &&
                      !(inval_valid_i && axi_rd_id_out[0]);
  assign rtrn_self = G6LCCfg.RVA && self_inval_pend_q;
  assign rtrn_ext  = inval_valid_i && !rtrn_self;
  assign rtrn_inv  = G6LCCfg.RVA && invalidate && !rtrn_self && !rtrn_ext;
  assign rtrn_rd   = axi_rd_valid && axi_rd_id_out[0] && axi_rd_rdy &&
                     !rtrn_self && !rtrn_ext && !rtrn_inv;
  assign rtrn_b    = !b_empty && !rtrn_rd && !rtrn_inv && !rtrn_ext && !rtrn_self;
  // AMO arm of p_axi_req: grant pulse, dcache selected, atomic opcode.
  assign invalidate = G6LCCfg.RVA && arb_gnt && (|arb_req) && arb_idx &&
                      (dcache_data.rtype == wt_cache_pkg::DCACHE_ATOMIC_REQ);
  // Displaced AMO invalidate. Same condition as the capture below.
  // The address mux is 14-bit groups so the select does not fan out
  // across PLEN.
  logic self_inval_take;
  logic sia0, sia1, sia2, sia3;
  logic [55:0] self_inval_addr_bits;
  assign self_inval_take = G6LCCfg.RVA && invalidate &&
                           (self_inval_pend_q || inval_valid_i);
  assign sia0 = self_inval_take;
  assign sia1 = self_inval_take;
  assign sia2 = self_inval_take;
  assign sia3 = self_inval_take;
  for (genvar b = 0; b < 56; b++) begin : gen_sia
    if (b < 14) begin : gen_b0
      assign self_inval_addr_bits[b] = sia0 ? dcache_data.paddr[b] : self_inval_addr_q[b];
    end else if (b < 28) begin : gen_b1
      assign self_inval_addr_bits[b] = sia1 ? dcache_data.paddr[b] : self_inval_addr_q[b];
    end else if (b < 42) begin : gen_b2
      assign self_inval_addr_bits[b] = sia2 ? dcache_data.paddr[b] : self_inval_addr_q[b];
    end else begin : gen_b3
      assign self_inval_addr_bits[b] = sia3 ? dcache_data.paddr[b] : self_inval_addr_q[b];
    end
  end
  assign self_inval_addr_d = self_inval_addr_bits;
  // pragma translate_off
  initial assert (G6LCCfg.PLEN == 56);
  // pragma translate_on

  // Icache return is independent of the dcache decode below. Its own
  // process keeps that 1-bit result off the dcache return chain.
  logic ic_rtrn_go;
  assign ic_rtrn_go = axi_rd_valid && (axi_rd_id_out == '0) && axi_rd_rdy;
  always_comb begin : p_icache_rtrn
    icache_rtrn_rd_en = ic_rtrn_go;
    icache_rtrn_vld_d = ic_rtrn_go && axi_rd_last;
  end

  // decode virtual read channels of dcache
  always_comb begin : p_axi_rtrn_decode
    dcache_rtrn_rd_en  = 1'b0;
    dcache_rtrn_vld_d  = 1'b0;
    dcache_rd_pop      = 1'b0;
    dcache_wr_pop      = 1'b0;
    dcache_rtrn_inv_d  = '0;
    dcache_rtrn_type_d = wt_cache_pkg::DCACHE_LOAD_ACK;
    b_pop              = 1'b0;
    dcache_sc_rtrn     = 1'b0;
    self_inval_pend_d  = self_inval_pend_q;

    // External invalidation requests (from coprocessor). This is safe as
    // there are no other transactions when a coprocessor has pending stores.
    inval_ready_o      = 1'b0;
    // Priority is the 1-bit selects above. Each arm is a bare ident so the
    // wide return fields do not accumulate the earlier predicates.
    if (rtrn_self) begin
      // Retained self-invalidation: emit the displaced DCACHE_INV_REQ now.
      // Ordinary read/write response consumption stays blocked this cycle.
      dcache_rtrn_type_d    = wt_cache_pkg::DCACHE_INV_REQ;
      dcache_rtrn_vld_d     = 1'b1;
      dcache_rtrn_inv_d.all = 1'b1;
      dcache_rtrn_inv_d.idx = self_inval_addr_q[G6LCCfg.DCACHE_INDEX_WIDTH-1:0];
      self_inval_pend_d     = 1'b0;
    end
    if (rtrn_ext) begin
      inval_ready_o         = 1'b1;
      dcache_rtrn_type_d    = wt_cache_pkg::DCACHE_INV_REQ;
      dcache_rtrn_vld_d     = 1'b1;
      dcache_rtrn_inv_d.all = 1'b1;
      dcache_rtrn_inv_d.idx = inval_addr_i[G6LCCfg.DCACHE_INDEX_WIDTH-1:0];
      //////////////////////////////////////
      // dcache needs some special treatment
      // for arbitration and decoding of atomics
      //////////////////////////////////////
      // this is safe, there is no other read tx in flight than this atomic.
      // note that this self invalidation is handled in this way due to the
      // write-through cache architecture, which is aligned with the openpiton
      // cache subsystem.
    end
    if (rtrn_inv) begin
      dcache_rtrn_type_d = wt_cache_pkg::DCACHE_INV_REQ;
      dcache_rtrn_vld_d = 1'b1;

      dcache_rtrn_inv_d.all = 1'b1;
      dcache_rtrn_inv_d.idx = dcache_data.paddr[G6LCCfg.DCACHE_INDEX_WIDTH-1:0];
      //////////////////////////////////////
      // read responses
      // note that in case of atomics, the dcache sequentializes requests and
      // guarantees that there are no other pending transactions in flight
    end
    if (rtrn_rd) begin
      dcache_rtrn_rd_en = 1'b1;
      dcache_rtrn_vld_d = axi_rd_last;

      // if this was an atomic op
      if (G6LCCfg.RVA && axi_rd_id_out[1]) begin
        dcache_rtrn_type_d = wt_cache_pkg::DCACHE_ATOMIC_ACK;

        // check if transaction was issued over write channel and pop that ID
        if (!dcache_wr_empty) begin
          dcache_wr_pop = axi_rd_last;
          // if this is not the case, there MUST be an id in the read channel (LR)
        end else begin
          dcache_rd_pop = axi_rd_last;
        end
      end else begin
        dcache_rd_pop = axi_rd_last;
      end
      //////////////////////////////////////
      // write responses, check b fifo
    end
    if (rtrn_b) begin
      b_pop = 1'b1;

      // this was an atomic
      if (G6LCCfg.RVA && wr_id_out[1]) begin
        dcache_rtrn_type_d = wt_cache_pkg::DCACHE_ATOMIC_ACK;

        // silently discard b response if we already popped the fifo
        // with a R beat (iff the amo transaction generated an R beat)
        if (!amo_gen_r_q) begin
          dcache_rtrn_vld_d = 1'b1;
          dcache_wr_pop     = 1'b1;
          dcache_sc_rtrn    = 1'b1;
        end
      end else begin
        // regular response
        dcache_rtrn_type_d = wt_cache_pkg::DCACHE_STORE_ACK;
        dcache_rtrn_vld_d  = 1'b1;
        dcache_wr_pop      = 1'b1;
      end
    end
    //////////////////////////////////////
    // An AMO invalidate pulse displaced by a pending self-invalidation or an
    // external request is not lost: it is retained and emitted on a later
    // cycle by the first branch above.
    if (self_inval_take) begin
      self_inval_pend_d = 1'b1;
    end
  end

  // Same-cycle invalidate pulse. The address mux is four 16-bit unique
  // cases; the valid bit is the type compare, not a wide ternary.
  logic        inv_apply_vld;
  logic [1:0]  inv_asrc;
  logic [63:0] inv_apply_addr;
  logic [63:0] inv_self_addr, inv_ext_addr, inv_dc_addr;
  assign inv_apply_vld = dcache_rtrn_vld_d &&
                         (dcache_rtrn_type_d == wt_cache_pkg::DCACHE_INV_REQ);
  assign inv_self_addr = 64'(self_inval_addr_q);
  assign inv_ext_addr  = inval_addr_i;
  assign inv_dc_addr   = 64'(dcache_data.paddr);
  always_comb begin
    if (self_inval_pend_q) inv_asrc = 2'd0;
    else if (inval_valid_i) inv_asrc = 2'd1;
    else inv_asrc = 2'd2;
  end
  for (genvar s = 0; s < 4; s++) begin : gen_inv_slice
    always_comb begin
      unique case (inv_asrc)
        2'd0:    inv_apply_addr[s*16 +: 16] = inv_self_addr[s*16 +: 16];
        2'd1:    inv_apply_addr[s*16 +: 16] = inv_ext_addr[s*16 +: 16];
        default: inv_apply_addr[s*16 +: 16] = inv_dc_addr[s*16 +: 16];
      endcase
    end
  end

  if (G6LCCfg.CohPolicy == config_pkg::COH_OOO) begin : gen_inval_apply
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        inval_apply_valid_o <= 1'b0;
        inval_apply_addr_o <= '0;
      end else begin
        inval_apply_valid_o <= inv_apply_vld;
        inval_apply_addr_o   <= inv_apply_addr;
      end
    end
  end else begin : gen_no_inval_apply
    assign inval_apply_valid_o = 1'b0;
    assign inval_apply_addr_o = '0;
  end

  // remote invalidations are not supported yet (this needs a cache coherence protocol)
  // note that the atomic transactions would also need a "master exclusive monitor" in that case
  // assign icache_rtrn_o.inv.idx  = '0;
  // assign icache_rtrn_o.inv.way  = '0;
  // assign icache_rtrn_o.inv.vld  = '0;
  // assign icache_rtrn_o.inv.all  = '0;

  // assign dcache_rtrn_o.inv.idx  = '0;
  // assign dcache_rtrn_o.inv.way  = '0;
  // assign dcache_rtrn_o.inv.vld  = '0;
  // assign dcache_rtrn_o.inv.all  = '0;

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_rd_buf
    if (!rst_ni) begin
      icache_first_q         <= 1'b1;
      dcache_first_q         <= 1'b1;
      icache_rd_shift_q      <= '0;
      icache_rd_shift_user_q <= '0;
      dcache_rd_shift_q      <= '0;
      dcache_rd_shift_user_q <= '0;
      icache_rtrn_vld_q      <= '0;
      dcache_rtrn_vld_q      <= '0;
      icache_rtrn_tid_q      <= '0;
      dcache_rtrn_tid_q      <= '0;
      dcache_rtrn_type_q     <= wt_cache_pkg::DCACHE_LOAD_ACK;
      dcache_rtrn_inv_q      <= '0;
      amo_off_q              <= '0;
      amo_gen_r_q            <= 1'b0;
      self_inval_pend_q      <= 1'b0;
      self_inval_addr_q      <= '0;
    end else begin
      icache_first_q         <= icache_first_d;
      dcache_first_q         <= dcache_first_d;
      icache_rd_shift_q      <= icache_rd_shift_d;
      icache_rd_shift_user_q <= icache_rd_shift_user_d;
      dcache_rd_shift_q      <= dcache_rd_shift_d;
      dcache_rd_shift_user_q <= dcache_rd_shift_user_d;
      icache_rtrn_vld_q      <= icache_rtrn_vld_d;
      dcache_rtrn_vld_q      <= dcache_rtrn_vld_d;
      icache_rtrn_tid_q      <= icache_rtrn_tid_d;
      dcache_rtrn_tid_q      <= dcache_rtrn_tid_d;
      dcache_rtrn_type_q     <= dcache_rtrn_type_d;
      dcache_rtrn_inv_q      <= dcache_rtrn_inv_d;
      amo_off_q              <= amo_off_d;
      amo_gen_r_q            <= amo_gen_r_d;
      self_inval_pend_q      <= self_inval_pend_d;
      self_inval_addr_q      <= self_inval_addr_d;
    end
  end


  ///////////////////////////////////////////////////////
  // axi protocol shim
  ///////////////////////////////////////////////////////

  // Phase 1 (WtAxiAllocEn): the shim sees the plain request stream; the module
  // output below swaps in the full allocate attribute for cacheable requests.
  // BUFFERABLE|MODIFIABLE|RD_ALLOC|WR_ALLOC = 4'b1111.
  localparam logic [3:0] WT_ALLOC_CACHE = axi_pkg::CACHE_BUFFERABLE |
      axi_pkg::CACHE_MODIFIABLE | axi_pkg::CACHE_RD_ALLOC | axi_pkg::CACHE_WR_ALLOC;
  axi_req_t axi_req_shim;
  logic axi_rd_alloc, axi_wr_alloc;
  // Taken from the same request word that feeds rd_addr/wr_addr (p_axi_req).
  // hyp8: the shim now captures its AR/AW descriptors, so the allocate
  // attribute must be snapshotted on the same capture edges — the first
  // presentation cycle of each request — and held until the channel grant.
  // AMO/LR/SC requests arrive with nc=1 (miss unit: mem_data_o.nc), so
  // lock/ATOP keep the modifiable-only stream without a special case.
  assign axi_rd_alloc = G6LCCfg.WtAxiAllocEn &&
                        !(arb_idx ? dcache_data.nc : icache_data.nc);
  assign axi_wr_alloc = G6LCCfg.WtAxiAllocEn && !dcache_data.nc;

  logic       rd_pend_q, wr_hold_q;
  logic [3:0] ar_cache_q, aw_cache_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_axi_alloc_track
    if (!rst_ni) begin
      rd_pend_q  <= 1'b0;
      wr_hold_q  <= 1'b0;
      ar_cache_q <= '0;
      aw_cache_q <= '0;
    end else begin
      // Mirrors the shim's elastic AR slot: set on first presentation,
      // cleared by the channel grant.
      if (!rd_pend_q && axi_rd_req) begin
        rd_pend_q  <= 1'b1;
        ar_cache_q <= axi_rd_alloc ? WT_ALLOC_CACHE : axi_pkg::CACHE_MODIFIABLE;
      end
      if (axi_rd_gnt) rd_pend_q <= 1'b0;
      // Mirrors the shim's write payload capture: the descriptor is
      // consumed by the IDLE state and held until the write grant.
      if (!wr_hold_q && axi_wr_req) begin
        wr_hold_q  <= 1'b1;
        aw_cache_q <= axi_wr_alloc ? WT_ALLOC_CACHE : axi_pkg::CACHE_MODIFIABLE;
      end
      if (axi_wr_gnt) wr_hold_q <= 1'b0;
    end
  end

  // Timing: a 4-bit sideband select off registered attribute slots — no
  // new clock, reset or DFT change; with WtAxiAllocEn=0 the output is
  // bit-identical to the shim's own assignment.
  always_comb begin : p_axi_alloc_attr
    axi_req_o = axi_req_shim;
    axi_req_o.ar.cache = rd_pend_q ? ar_cache_q
                       : (axi_rd_alloc ? WT_ALLOC_CACHE : axi_pkg::CACHE_MODIFIABLE);
    axi_req_o.aw.cache = wr_hold_q ? aw_cache_q
                       : (axi_wr_alloc ? WT_ALLOC_CACHE : axi_pkg::CACHE_MODIFIABLE);
  end

  axi_shim #(
      .G6LCCfg    (G6LCCfg),
      .AxiNumWords(AxiNumWords),
      .axi_req_t  (axi_req_t),
      .axi_rsp_t  (axi_rsp_t)
  ) i_axi_shim (
      .clk_i      (clk_i),
      .rst_ni     (rst_ni),
      .rd_req_i   (axi_rd_req),
      .rd_gnt_o   (axi_rd_gnt),
      .rd_addr_i  (axi_rd_addr),
      .rd_blen_i  (axi_rd_blen),
      .rd_size_i  (axi_rd_size),
      .rd_id_i    (axi_rd_id_in),
      .rd_rdy_i   (axi_rd_rdy),
      .rd_lock_i  (axi_rd_lock),
      .rd_last_o  (axi_rd_last),
      .rd_valid_o (axi_rd_valid),
      .rd_data_o  (axi_rd_data),
      .rd_user_o  (axi_rd_user),
      .rd_id_o    (axi_rd_id_out),
      .rd_exokay_o(axi_rd_exokay),
      .wr_req_i   (axi_wr_req),
      .wr_gnt_o   (axi_wr_gnt),
      .wr_addr_i  (axi_wr_addr),
      .wr_data_i  (axi_wr_data),
      .wr_user_i  (axi_wr_user),
      .wr_be_i    (axi_wr_be),
      .wr_blen_i  (axi_wr_blen),
      .wr_size_i  (axi_wr_size),
      .wr_id_i    (axi_wr_id_in),
      .wr_lock_i  (axi_wr_lock),
      .wr_atop_i  (axi_wr_atop),
      .wr_rdy_i   (axi_wr_rdy),
      .wr_valid_o (axi_wr_valid),
      .wr_id_o    (axi_wr_id_out),
      .wr_exokay_o(axi_wr_exokay),
      .axi_req_o  (axi_req_shim),
      .axi_resp_i (axi_resp_i)
  );

  ///////////////////////////////////////////////////////
  // assertions
  ///////////////////////////////////////////////////////

  //pragma translate_off
`ifndef VERILATOR

`endif

  // M3 bring-up probe (+icf_trace): shared-miss-adapter AR/R dump.
  // +trace_from/+trace_to bound the cycle window (default 0..3000).
  logic wta_trace;
  int unsigned wta_lo, wta_hi;
  int unsigned wta_cyc = 0;
  initial begin
    wta_trace = $test$plusargs("icf_trace");
    wta_lo = 0;
    wta_hi = 3000;
    void'($value$plusargs("trace_from=%d", wta_lo));
    void'($value$plusargs("trace_to=%d", wta_hi));
  end
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      wta_cyc = 0;
    end else begin
      wta_cyc++;
      if (wta_trace && wta_cyc >= wta_lo && wta_cyc <= wta_hi &&
          (icache_data_req_i || !icache_data_empty || !icache_rd_empty ||
           axi_req_o.ar_valid || axi_resp_i.r_valid)) begin
        $display("[wta] t=%0t icreq=%b icack=%b icempty=%b icrdfull=%b icrdempty=%b dc=%b | arb_req=%b idx=%b rdreq=%b rdgnt=%b | arv=%b arr=%b addr=%h | rv=%b rr=%b rlast=%b rid=%h rdata=%h",
          $time, icache_data_req_i, icache_data_ack_o, icache_data_empty,
          icache_rd_full, icache_rd_empty, !dcache_data_empty,
          arb_req, arb_idx, axi_rd_req, axi_rd_gnt,
          axi_req_o.ar_valid, axi_resp_i.ar_ready, axi_req_o.ar.addr,
          axi_resp_i.r_valid, axi_rd_rdy, axi_resp_i.r.last, axi_resp_i.r.id, axi_resp_i.r.data);
      end
      // [wta2] event records for the I$ fill path (request fifo head, AR
      // issue, R return, meta-fifo pop). Request-side vs return-side
      // mis-association discrimination for hyp8-osbi-fe-diag-r1.
      if (wta_trace && wta_cyc >= wta_lo && wta_cyc <= wta_hi) begin
        if (icache_data_ack_o) begin
          $display("[wta2] t=%0t ICREC push paddr=%h tid=%0d nc=%b",
            $time, icache_data_i.paddr, icache_data_i.tid, icache_data_i.nc);
        end
        if (arb_ack[0] && axi_rd_gnt) begin
          $display("[wta2] t=%0t AR head=%h araddr=%h arid=%h tid=%0d metapush=%b",
            $time, icache_data.paddr, axi_rd_addr, axi_rd_id_in,
            icache_data.tid, (arb_ack[0] & axi_rd_gnt));
        end
        if (ic_rtrn_go) begin
          $display("[wta2] t=%0t R rid=%h last=%b rdata=%h metahead=%0d metaempty=%b",
            $time, axi_rd_id_out, axi_rd_last, axi_rd_data,
            icache_rtrn_tid_d, icache_rd_empty);
        end
        if (icache_rtrn_vld_q) begin
          $display("[wta2] t=%0t RTRN tid=%0d data=%h",
            $time, icache_rtrn_o.tid,
            icache_rtrn_o.data[G6LCCfg.ICACHE_LINE_WIDTH-1:0]);
        end
      end
    end
  end

  // Request-record integrity: the AR issued for an icache head must carry
  // that head's paddr, and an id-0 read return must have a live meta entry
  // (a return with no request record is exactly the mis-association class
  // that installed pa-0x80012000 bytes under a va-0x80013000 miss).
  ifill_ar_addr :
  assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    (arb_ack[0] && axi_rd_gnt)
    |-> (axi_req_o.ar.addr == G6LCCfg.AxiAddrWidth'(icache_data.paddr)))
  else $fatal(1, "[wt axi adapter] ifill AR addr %h != request head %h",
              axi_req_o.ar.addr, icache_data.paddr);

  ifill_rtrn_meta :
  assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    ic_rtrn_go |-> !icache_rd_empty)
  else $fatal(1, "[wt axi adapter] id-0 read return with empty ifill meta fifo");
  //pragma translate_on

endmodule  // wt_l15_adapter
