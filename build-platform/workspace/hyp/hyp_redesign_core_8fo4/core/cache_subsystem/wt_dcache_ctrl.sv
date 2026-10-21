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
// Description: DCache controller for read port


module wt_dcache_ctrl
  import g6lc_core_pkg::*;
  import wt_cache_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    // hyp8: DcacheHitExtra=2 readout staging (accepted rank-5 cut) — the
    // FSM gains READ_WAIT/READ_V so the verdict runs on the +2 response.
    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg = g6lc_hyp_pkg::Hyp8,
    parameter DCACHE_CL_IDX_WIDTH = 0,
    parameter type dcache_req_i_t = logic,
    parameter type dcache_req_o_t = logic,
    parameter logic [G6LCCfg.MEM_TID_WIDTH-1:0] RdTxId = 1
) (
    input logic clk_i,  // Clock
    input logic rst_ni,  // Asynchronous reset active low
    input logic cache_en_i,
    // core request ports
    input dcache_req_i_t req_port_i,
    output dcache_req_o_t req_port_o,
    // interface to miss handler
    output logic miss_req_o,
    input logic miss_ack_i,
    output logic miss_we_o,  // unused (set to 0)
    output logic [G6LCCfg.XLEN-1:0] miss_wdata_o,  // unused (set to 0)
    output logic [G6LCCfg.DCACHE_USER_WIDTH-1:0] miss_wuser_o,  // unused (set to 0)
    output logic [G6LCCfg.DCACHE_SET_ASSOC-1:0] miss_vld_bits_o,  // valid bits at the missed index
    output logic [G6LCCfg.PLEN-1:0] miss_paddr_o,
    output logic miss_nc_o,  // request to I/O space
    output logic [2:0] miss_size_o,  // 00: 1byte, 01: 2byte, 10: 4byte, 11: 8byte, 111: cacheline
    output logic [G6LCCfg.MEM_TID_WIDTH-1:0] miss_id_o,  // set to constant ID
    input logic miss_replay_i,  // request collided with pending miss - have to replay the request
    input  logic                            miss_rtrn_vld_i, // signals that the miss has been served, asserted in the same cycle as when the data returns from memory
    // used to detect readout mux collisions
    input logic wr_cl_vld_i,
    // cache memory interface
    output logic [G6LCCfg.DCACHE_TAG_WIDTH-1:0] rd_tag_o,  // tag in - comes one cycle later
    output logic [DCACHE_CL_IDX_WIDTH-1:0] rd_idx_o,
    output logic [G6LCCfg.DCACHE_OFFSET_WIDTH-1:0] rd_off_o,
    output logic rd_req_o,  // read the word at offset off_i[:3] in all ways
    output logic rd_tag_only_o,  // set to zero here
    input logic rd_ack_i,
    input logic [G6LCCfg.XLEN-1:0] rd_data_i,
    input logic [G6LCCfg.DCACHE_USER_WIDTH-1:0] rd_user_i,
    input logic [G6LCCfg.DCACHE_SET_ASSOC-1:0] rd_vld_bits_i,
    input logic [G6LCCfg.DCACHE_SET_ASSOC-1:0] rd_hit_oh_i,
    // Write-buffer/fixup holds the full XLEN word (see wt_dcache_mem).
    input logic wbuffer_fwd_hit_i
);

  // controller FSM
  typedef enum logic [3:0] {
    IDLE,
    READ,
    READ_WAIT,   // hyp8: mem T1/T2 staging in flight
    READ_V,      // hyp8: verdict on the +2 registered response
    MISS_REQ,
    MISS_WAIT,
    KILL_MISS,
    KILL_MISS_ACK,
    REPLAY_REQ,
    REPLAY_READ
  } state_e;
  state_e state_d, state_q;

  logic [G6LCCfg.DCACHE_TAG_WIDTH-1:0] address_tag_d, address_tag_q;
  logic [DCACHE_CL_IDX_WIDTH-1:0] address_idx_d, address_idx_q;
  logic [G6LCCfg.DCACHE_OFFSET_WIDTH-1:0] address_off_d, address_off_q;
  logic [G6LCCfg.DcacheIdWidth-1:0] id_d, id_q;
  logic [G6LCCfg.DCACHE_SET_ASSOC-1:0] vld_data_d, vld_data_q;
  logic save_tag, rd_req_d, rd_req_q, rd_ack_d, rd_ack_q;
  logic [1:0] data_size_d, data_size_q;
  // hyp8: verdict-window bookkeeping for the +2 readout. wr_cl_seen_q is
  // sticky across the lookup window so a refill landing in any T stage
  // still forces the same REPLAY_REQ re-lookup the single-cycle version
  // forced for its own lookup cycle; rd_ok_q records that the lookup's
  // array read was accepted (the emit's !rd_ack_q replay criterion).
  logic wr_cl_seen_d, wr_cl_seen_q;
  logic rd_ok_d, rd_ok_q;

  ///////////////////////////////////////////////////////
  // misc
  ///////////////////////////////////////////////////////

  // map address to tag/idx/offset and save
  

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=wt_dcache_ctrl  region=4076  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: address_idx_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to address_idx_q
// order expect: address_off_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to address_off_q
// order expect: address_tag_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to address_tag_q
// order expect: data_size_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to data_size_q
// order expect: id_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to id_q
// order expect: rd_ack_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to rd_ack_q
// order expect: rd_req_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to rd_req_q
// order expect: state_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to state_q
// order expect: vld_data_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to vld_data_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     address_idx_q <= …; // sv-timing: cycle 1/1 on clk_i
//     address_off_q <= …; // sv-timing: cycle 1/1 on clk_i
//     address_tag_q <= …; // sv-timing: cycle 1/1 on clk_i
//     data_size_q <= …; // sv-timing: cycle 1/1 on clk_i
//     id_q <= …; // sv-timing: cycle 1/1 on clk_i
//     rd_ack_q <= …; // sv-timing: cycle 1/1 on clk_i
//     rd_req_q <= …; // sv-timing: cycle 1/1 on clk_i
//     state_q <= …; // sv-timing: cycle 1/1 on clk_i
//     vld_data_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node14207 c=3.50 slack=0.00 */
//     /* node14208 c=3.50 slack=0.00 */
//     /* node14209 c=3.50 slack=0.00 */
//     /* node14210 c=3.50 slack=0.00 */
//     /* node14211 c=3.50 slack=0.00 */
//     /* node14212 c=3.50 slack=0.00 */
//     /* node14213 c=3.50 slack=0.00 */
//     /* node14214 c=3.50 slack=0.00 */
//     /* node14215 c=3.50 slack=0.00 */
//     /* node14216 c=3.50 slack=0.00 */
//     /* node14217 c=3.50 slack=0.00 */
//     /* node14218 c=3.50 slack=0.00 */
//     /* node14219 c=3.50 slack=0.00 */
//     /* node14220 c=3.50 slack=0.00 */
//     /* node14221 c=3.50 slack=0.00 */
//     /* node14222 c=3.50 slack=0.00 */
//     /* node14223 c=3.50 slack=0.00 */
//     /* node14224 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
  // hyp8: under the +2 readout the valid bits at the missed index arrive
  // with the verdict (READ_V), not with rd_req_q.
  // hyp8 DcacheHitExtra is 2. The other arm does not fold (struct compare)
  // and was timed as a second wide mux. Valid bits update on the verdict.
  assign vld_data_d = (state_q == READ_V) ? rd_vld_bits_i : vld_data_q;
  assign address_tag_d = (save_tag) ? req_port_i.address_tag : address_tag_q;
  assign address_idx_d = (req_port_o.data_gnt) ? req_port_i.address_index[G6LCCfg.DCACHE_INDEX_WIDTH-1:G6LCCfg.DCACHE_OFFSET_WIDTH] : address_idx_q;
  assign address_off_d = (req_port_o.data_gnt) ? req_port_i.address_index[G6LCCfg.DCACHE_OFFSET_WIDTH-1:0]                  : address_off_q;
  assign id_d = (req_port_o.data_gnt) ? req_port_i.data_id : id_q;
  assign data_size_d = (req_port_o.data_gnt) ? req_port_i.data_size : data_size_q;
  assign rd_tag_o = address_tag_d;
  assign rd_idx_o = address_idx_d;
  assign rd_off_o = address_off_d;

  assign req_port_o.data_rdata = rd_data_i;

  // 8-way hyp8 set. A reduction of the struct-width port does not fold.
  logic hit_any;
  logic [1:0] rv_sel;
  assign hit_any = |rd_hit_oh_i[7:0];
  // READ_V priority, narrow, so the state case is a unique mux rather than
  // a compound-guard chain: kill, replay, hit, else miss.
  always_comb begin
    if (req_port_i.kill_req) rv_sel = 2'd0;
    else if (wr_cl_seen_q || !rd_ok_q) rv_sel = 2'd1;
    else if ((hit_any || wbuffer_fwd_hit_i) && cache_en_i) rv_sel = 2'd2;
    else rv_sel = 2'd3;
  end
  assign req_port_o.data_ruser = rd_user_i;
  assign req_port_o.data_rid = id_q;

  // to miss unit
  assign miss_vld_bits_o = vld_data_q;
  assign miss_paddr_o = {address_tag_q, address_idx_q, address_off_q};
  assign miss_size_o = (miss_nc_o) ? {1'b0, data_size_q} : 3'b111;

  // noncacheable if request goes to I/O space, or if cache is disabled
  assign miss_nc_o = (~cache_en_i) | (~config_pkg::is_inside_cacheable_regions(
      G6LCCfg,
      {{{64-G6LCCfg.DCACHE_TAG_WIDTH-G6LCCfg.DCACHE_INDEX_WIDTH}{1'b0}}, address_tag_q, {G6LCCfg.DCACHE_INDEX_WIDTH{1'b0}}}
  ));


  assign miss_we_o = '0;
  assign miss_wdata_o = '0;
  assign miss_wuser_o = '0;
  assign miss_id_o = RdTxId;
  assign rd_req_d = rd_req_o;
  assign rd_ack_d = rd_ack_i;
  assign rd_tag_only_o = '0;

  ///////////////////////////////////////////////////////
  // main control logic
  ///////////////////////////////////////////////////////

  always_comb begin : p_fsm
    // default assignment
    state_d                = state_q;
    save_tag               = 1'b0;
    rd_req_o               = 1'b0;
    miss_req_o             = 1'b0;
    req_port_o.data_rvalid = 1'b0;
    req_port_o.data_gnt    = 1'b0;
    wr_cl_seen_d           = wr_cl_seen_q;
    rd_ok_d                = rd_ok_q;

    // hyp8: the +2 lookup window opens on an accepted request and closes
    // at the verdict; a refill anywhere in the window replays the lookup.
    if (req_port_o.data_gnt || req_port_i.kill_req) begin
      wr_cl_seen_d = 1'b0;
    end else if (wr_cl_vld_i && (state_q inside {READ, READ_WAIT, REPLAY_READ})) begin
      wr_cl_seen_d = 1'b1;
    end

    // interfaces
    unique case (state_q)
      //////////////////////////////////
      // wait for an incoming request
      IDLE: begin
        if (req_port_i.data_req) begin
          rd_req_o = 1'b1;
          // if read ack then ack the `req_port_o`, and goto `READ` state
          if (rd_ack_i) begin
            state_d = READ;
            req_port_o.data_gnt = 1'b1;
          end
        end
      end
      //////////////////////////////////
      // check whether we have a hit
      // in case the cache is disabled,
      // or in case the address is NC, we
      // reuse the miss mechanism to handle
      // the request
      READ, REPLAY_READ: begin
        // hyp8 DcacheHitExtra is 2: the tag-presenting state only records
        // the lookup and steps into READ_WAIT. The single-cycle re-issue
        // arm is not in this core (the struct compare does not fold, so
        // leaving it in source timed that cone).
        if (req_port_i.kill_req) begin
          state_d = IDLE;
          req_port_o.data_rvalid = 1'b1;
        end else if (req_port_i.tag_valid | state_q == REPLAY_READ) begin
          save_tag = (state_q != REPLAY_READ);
          rd_ok_d  = rd_ack_q;
          state_d  = READ_WAIT;
        end
      end
      //////////////////////////////////
      // hyp8: one wait state — the mem T1 (tag compare) register captures
      // during READ; this cycle covers T2 (way/data merge).
      READ_WAIT: begin
        if (req_port_i.kill_req) begin
          state_d = IDLE;
          req_port_o.data_rvalid = 1'b1;
        end else begin
          state_d = READ_V;
        end
      end
      //////////////////////////////////
      // hyp8: verdict on the +2 registered response (rd_hit_oh_i,
      // rd_data_i, wbuffer_fwd_hit_i). Hit/miss/replay criteria identical
      // to the single-cycle READ evaluation.
      READ_V: begin
        // keep the read port offered so a back-to-back request can be
        // accepted in the verdict cycle (the emit did this in READ).
        rd_req_o = 1'b1;
        unique case (rv_sel)
          2'd0: begin
            state_d = IDLE;
            req_port_o.data_rvalid = 1'b1;
          end
          2'd1: state_d = REPLAY_REQ;
          2'd2: begin
            state_d = IDLE;
            req_port_o.data_rvalid = 1'b1;
            if (rd_ack_i && req_port_i.data_req) begin
              state_d = READ;
              req_port_o.data_gnt = 1'b1;
            end
          end
          default: state_d = MISS_REQ;
        endcase
      end
      //////////////////////////////////
      // issue request
      MISS_REQ: begin
        miss_req_o = 1'b1;

        if (req_port_i.kill_req) begin
          req_port_o.data_rvalid = 1'b1;
          if (miss_ack_i) begin
            state_d = KILL_MISS;
          end else begin
            state_d = KILL_MISS_ACK;
          end
        end else if (miss_replay_i) begin
          state_d = REPLAY_REQ;
        end else if (miss_ack_i) begin
          state_d = MISS_WAIT;
        end
      end
      //////////////////////////////////
      // wait until the memory transaction
      // returns.
      MISS_WAIT: begin
        if (req_port_i.kill_req) begin
          req_port_o.data_rvalid = 1'b1;
          if (miss_rtrn_vld_i) begin
            state_d = IDLE;
          end else begin
            state_d = KILL_MISS;
          end
        end else if (miss_rtrn_vld_i) begin
          state_d = IDLE;
          req_port_o.data_rvalid = 1'b1;
        end
      end
      //////////////////////////////////
      // replay read request
      REPLAY_REQ: begin
        rd_req_o = 1'b1;
        if (req_port_i.kill_req) begin
          req_port_o.data_rvalid = 1'b1;
          state_d = IDLE;
        end else if (rd_ack_i) begin
          state_d = REPLAY_READ;
          // hyp8: the replayed lookup opens its own clean window
          wr_cl_seen_d = 1'b0;
        end
      end
      //////////////////////////////////
      KILL_MISS_ACK: begin
        miss_req_o = 1'b1;
        // in this case the miss handler did not issue
        // a transaction and we can safely go to idle
        if (miss_replay_i) begin
          state_d = IDLE;
        end else if (miss_ack_i) begin
          state_d = KILL_MISS;
        end
      end
      //////////////////////////////////
      // killed miss,
      // wait until miss unit responds and
      // go back to idle
      KILL_MISS: begin
        if (miss_rtrn_vld_i) begin
          state_d = IDLE;
        end
      end
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
      state_q       <= IDLE;
      address_tag_q <= '0;
      address_idx_q <= '0;
      address_off_q <= '0;
      id_q          <= '0;
      vld_data_q    <= '0;
      data_size_q   <= '0;
      rd_req_q      <= '0;
      rd_ack_q      <= '0;
      wr_cl_seen_q  <= 1'b0;
      rd_ok_q       <= 1'b0;
    end else begin
      state_q       <= state_d;
      address_tag_q <= address_tag_d;
      address_idx_q <= address_idx_d;
      address_off_q <= address_off_d;
      id_q          <= id_d;
      vld_data_q    <= vld_data_d;
      data_size_q   <= data_size_d;
      rd_req_q      <= rd_req_d;
      rd_ack_q      <= rd_ack_d;
      wr_cl_seen_q  <= wr_cl_seen_d;
      rd_ok_q       <= rd_ok_d;
    end
  end

  ///////////////////////////////////////////////////////
  // assertions
  ///////////////////////////////////////////////////////

  //pragma translate_off
`ifndef VERILATOR

  hot1 :
  assert property (@(posedge clk_i) disable iff (!rst_ni) (!rd_ack_i) |=> cache_en_i |-> $onehot0(
      rd_hit_oh_i
  ))
  else $fatal(1, "[l1 dcache ctrl] rd_hit_oh_i signal must be hot1");

  initial begin
    // assert wrong parameterizations
    assert (G6LCCfg.DCACHE_INDEX_WIDTH <= 12)
    else
      $fatal(1, "[l1 dcache ctrl] cache index width can be maximum 12bit since VM uses 4kB pages");
  end
`endif
  //pragma translate_on

endmodule  // wt_dcache_ctrl
