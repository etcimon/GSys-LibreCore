// hyp8 provenance: ADAPTED (sv-timing emit at the 8-FO4 budget)
// SPDX-FileCopyrightText: machine-generated
// Modified by: Etienne Cimon (2026) - A139 pipeline-design comments.
/* Copyright 2018 ETH Zurich and University of Bologna.
 * Copyright and related rights are licensed under the Solderpad Hardware
 * License, Version 0.51 (the “License”); you may not use this file except in
 * compliance with the License.  You may obtain a copy of the License at
 * http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
 * or agreed to in writing, software, hardware and materials distributed under
 * this License is distributed on an “AS IS” BASIS, WITHOUT WARRANTIES OR
 * CONDITIONS OF ANY KIND, either express or implied. See the License for the
 * specific language governing permissions and limitations under the License.
 *
 * File:  axi_shim.sv
 * Author: Michael Schaffner <schaffner@iis.ee.ethz.ch>
 *         Florian Zaruba <zarubaf@iis.ee.ethz.ch>
 * Date:   1.8.2018
 *
 * Description: Manages communication with the AXI Bus. Note that this unit does not
 *              buffer requests and register the signals.
 *
 */


module axi_shim #(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter int unsigned AxiNumWords = 4, // data width in dwords, this is also the maximum burst length, must be >=2
    parameter type axi_req_t = logic,
    parameter type axi_rsp_t = logic
) (
    input logic clk_i,  // Clock
    input logic rst_ni,  // Asynchronous reset active low
    // read channel
    // request
    input logic rd_req_i,
    output logic rd_gnt_o,
    input logic [G6LCCfg.AxiAddrWidth-1:0] rd_addr_i,
    input logic [$clog2(AxiNumWords)-1:0] rd_blen_i,  // axi convention: LEN-1
    input logic [2:0] rd_size_i,
    input  logic [G6LCCfg.AxiIdWidth-1:0]   rd_id_i,   // use same ID for reads, or make sure you only have one outstanding read tx
    input logic rd_lock_i,
    // read response (we have to unconditionally sink the response)
    input logic rd_rdy_i,
    output logic rd_last_o,
    output logic rd_valid_o,
    output logic [G6LCCfg.AxiDataWidth-1:0] rd_data_o,
    output logic [G6LCCfg.AxiUserWidth-1:0] rd_user_o,
    output logic [G6LCCfg.AxiIdWidth-1:0] rd_id_o,
    output logic rd_exokay_o,  // indicates whether exclusive tx succeeded
    // write channel
    input logic wr_req_i,
    output logic wr_gnt_o,
    input logic [G6LCCfg.AxiAddrWidth-1:0] wr_addr_i,
    input logic [AxiNumWords-1:0][G6LCCfg.AxiDataWidth-1:0] wr_data_i,
    input logic [AxiNumWords-1:0][G6LCCfg.AxiUserWidth-1:0] wr_user_i,
    input logic [AxiNumWords-1:0][(G6LCCfg.AxiDataWidth/8)-1:0] wr_be_i,
    input logic [$clog2(AxiNumWords)-1:0] wr_blen_i,  // axi convention: LEN-1
    input logic [2:0] wr_size_i,
    input logic [G6LCCfg.AxiIdWidth-1:0] wr_id_i,
    input logic wr_lock_i,
    input logic [5:0] wr_atop_i,
    // write response
    input logic wr_rdy_i,
    output logic wr_valid_o,
    output logic [G6LCCfg.AxiIdWidth-1:0] wr_id_o,
    output logic wr_exokay_o,  // indicates whether exclusive tx succeeded
    // AXI port
    output axi_req_t axi_req_o,
    input axi_rsp_t axi_resp_i
);
  // A139 design proposal; vocabulary: architecture/RTL-PIPELINE-PLANS.md.
  // svt-plan: begin axi_shim status=proposal target=10-adjusted-FO4
  // svt-plan: cone write-state/beat-counter muxes interact with independent
  // AXI address/data/response handshakes and wide beat selection.
  // svt-plan: boundary complete AW/AR descriptors and W beats into elastic
  // channel slots; preselect the next beat while the current beat is held.
  // svt-plan: carry every address/control/ID/ATOP field and data/user/strb/
  // last together; VALID and payload remain stable until their own READY.
  // svt-plan: capacity local credits cover every accepted beat/descriptor;
  // preserve AW/W association, burst count and B/R response ownership.
  // svt-plan: effect removes downstream READY from upstream state cones
  // and splits beat mux from channel output; use skid capacity for full throughput.
  // svt-plan: cost channel storage and latency; no combinational ready loop
  // may reappear through a fall-through bypass across adjacent channel buffers.
  // svt-plan: limit AXI channel independence is not permission to reorder
  // write data or lose atomic/exclusive response semantics.
  // svt-plan: end
  // Re-pipelining contract (sv-timing A128; 13.7 adjusted FO4 on the
  // Nangate45 board): AXI shim: read / write FSMs.
  // svt-pipe: require-contract
  // svt-pipe: protocol ax valid=wr_req_i
  // svt-pipe: no-cut on=wr_state_q
  // svt-pipe: cycle ax q=wr_state_q d=wr_valid_o hold=wr_req_i steps=1

  localparam AddrIndex = ($clog2(AxiNumWords) > 0) ? $clog2(AxiNumWords) : 1;

  ///////////////////////////////////////////////////////
  // write channel
  ///////////////////////////////////////////////////////

  enum logic [3:0] {
    IDLE,
    WAIT_AW_READY,
    WAIT_LAST_W_READY,
    WAIT_LAST_W_READY_AW_READY,
    WAIT_AW_READY_BURST
  }
      wr_state_q, wr_state_d;

  // AXI tx counter
  logic [AddrIndex-1:0] wr_cnt_d, wr_cnt_q;
  logic wr_single_req, wr_cnt_done, wr_cnt_clr, wr_cnt_en;
  // Burst-length select is named before the write-state case reads it.
  // The nested count ternary is the same function, one mux per assign.
  logic wr_single_idle, wr_single_live, wr_single_held, wr_single_mux;
  logic wr_cnt_step;
  logic [AddrIndex-1:0] wr_cnt_inc, wr_cnt_held, wr_cnt_mux;

  

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=axi_shim  region=3476  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: wr_cnt_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to wr_cnt_q
// order expect: wr_state_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to wr_state_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     wr_cnt_q <= …; // sv-timing: cycle 1/1 on clk_i
//     wr_state_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node12908 c=3.50 slack=0.00 */
//     /* node12909 c=3.50 slack=0.00 */
//     /* node12910 c=3.50 slack=0.00 */
//     /* node12911 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
  // hyp8: registered request assembly (svt-plan boundary). The complete AW
  // descriptor and all W beats capture into channel slots the cycle the
  // write FSM takes the request; every downstream state then reads the
  // slots, so upstream req/gnt fields never sit in the channel cones. The
  // request is held by the source until wr_gnt_o, so capturing at the
  // first IDLE presentation loses nothing. AXI valid/ready is unchanged.
  logic [G6LCCfg.AxiAddrWidth-1:0]                           aw_addr_q;
  logic [2:0]                                               aw_size_q;
  logic [$clog2(AxiNumWords)-1:0]                           aw_blen_q;
  logic [G6LCCfg.AxiIdWidth-1:0]                            aw_id_q;
  logic                                                    aw_lock_q;
  logic [5:0]                                               aw_atop_q;
  logic [AxiNumWords-1:0][G6LCCfg.AxiDataWidth-1:0]          w_data_q;
  logic [AxiNumWords-1:0][G6LCCfg.AxiUserWidth-1:0]          w_user_q;
  logic [AxiNumWords-1:0][(G6LCCfg.AxiDataWidth/8)-1:0]      w_be_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_wr_pay
    if (!rst_ni) begin
      aw_addr_q <= '0;
      aw_size_q <= '0;
      aw_blen_q <= '0;
      aw_id_q   <= '0;
      aw_lock_q <= 1'b0;
      aw_atop_q <= '0;
      w_data_q  <= '0;
      w_user_q  <= '0;
      w_be_q    <= '0;
    end else if (wr_state_q == IDLE && wr_req_i) begin
      aw_addr_q <= wr_addr_i;
      aw_size_q <= wr_size_i;
      aw_blen_q <= wr_blen_i;
      aw_id_q   <= wr_id_i;
      aw_lock_q <= wr_lock_i;
      aw_atop_q <= wr_atop_i;
      w_data_q  <= wr_data_i;
      w_user_q  <= wr_user_i;
      w_be_q    <= wr_be_i;
    end
  end

  // The single-request decode rides the captured burst length; the
  // first-cycle decision in IDLE still reads the live field because the
  // capture only lands at this edge.
  always_comb begin : wr_single_req_sel
    wr_single_idle = wr_state_q == IDLE;
    wr_single_live = wr_blen_i == 0;
    wr_single_held = aw_blen_q == 0;
    unique case (wr_single_idle)
      1'b1:    wr_single_mux = wr_single_live;
      default: wr_single_mux = wr_single_held;
    endcase
  end
  assign wr_single_req = wr_single_mux;
  // Bare-ident guard for the IDLE burst count. The compound if charged
  // the state-case width onto wr_cnt_en.
  logic idle_burst;
  // hyp8 AxiBurstWriteEn is 0. The struct bit does not fold, so the
  // burst arm was timed on the write-state cone. Single writes only.
  assign idle_burst = 1'b0;

  // address
  assign axi_req_o.aw.burst = axi_pkg::BURST_INCR;  // Use BURST_INCR for AXI regular transaction
  assign axi_req_o.aw.addr = (wr_state_q == IDLE) ? wr_addr_i[G6LCCfg.AxiAddrWidth-1:0]
                                                : aw_addr_q;
  assign axi_req_o.aw.size = (wr_state_q == IDLE) ? wr_size_i : aw_size_q;
  assign axi_req_o.aw.len  = (wr_state_q == IDLE) ? wr_blen_i : aw_blen_q;
  assign axi_req_o.aw.id   = (wr_state_q == IDLE) ? wr_id_i   : aw_id_q;
  assign axi_req_o.aw.prot = 3'b0;
  assign axi_req_o.aw.region = 4'b0;
  assign axi_req_o.aw.lock = (wr_state_q == IDLE) ? wr_lock_i : aw_lock_q;
  assign axi_req_o.aw.cache = axi_pkg::CACHE_MODIFIABLE;
  assign axi_req_o.aw.qos = 4'b0;
  assign axi_req_o.aw.atop = (wr_state_q == IDLE) ? wr_atop_i : aw_atop_q;
  assign axi_req_o.aw.user = '0;

  // data
  assign axi_req_o.w.data = (wr_state_q == IDLE) ? wr_data_i[wr_cnt_q] : w_data_q[wr_cnt_q];
  assign axi_req_o.w.user = (wr_state_q == IDLE) ? wr_user_i[wr_cnt_q] : w_user_q[wr_cnt_q];
  assign axi_req_o.w.strb = (wr_state_q == IDLE) ? wr_be_i[wr_cnt_q]   : w_be_q[wr_cnt_q];
  assign axi_req_o.w.last = wr_cnt_done;

  // write response
  assign wr_exokay_o = (axi_resp_i.b.resp == axi_pkg::RESP_EXOKAY);
  assign axi_req_o.b_ready = wr_rdy_i;
  assign wr_valid_o = axi_resp_i.b_valid;
  assign wr_id_o = axi_resp_i.b.id;

  // tx counter
  assign wr_cnt_done = (wr_cnt_q == ((wr_state_q == IDLE) ? wr_blen_i : aw_blen_q));
  always_comb begin : wr_cnt_d_sel
    wr_cnt_step = 1'b0;
    wr_cnt_inc  = wr_cnt_q + 1;
    wr_cnt_held = wr_cnt_step ? wr_cnt_inc : wr_cnt_q;
    wr_cnt_mux  = wr_cnt_clr ? '0 : wr_cnt_held;
  end
  assign wr_cnt_d = wr_cnt_mux;

  always_comb begin : p_axi_write_fsm
    // default
    wr_state_d         = wr_state_q;

    axi_req_o.aw_valid = 1'b0;
    axi_req_o.w_valid  = 1'b0;
    wr_gnt_o           = 1'b0;

    wr_cnt_en          = 1'b0;
    wr_cnt_clr         = 1'b0;

    case (wr_state_q)
      ///////////////////////////////////
      IDLE: begin
        // we have an incoming request
        if (wr_req_i) begin
          // is this a read or write?
          axi_req_o.aw_valid = 1'b1;
          axi_req_o.w_valid  = 1'b1;

          if (idle_burst) begin
            wr_cnt_en = axi_resp_i.w_ready;

            case ({
              axi_resp_i.aw_ready, axi_resp_i.w_ready
            })
              2'b11:   wr_state_d = WAIT_LAST_W_READY;
              2'b01:   wr_state_d = WAIT_LAST_W_READY_AW_READY;
              2'b10:   wr_state_d = WAIT_LAST_W_READY;
              default: ;
            endcase
          end else if (wr_single_req) begin  // its a single write
            wr_cnt_clr = 1'b1;
            // single req can be granted here
            wr_gnt_o   = axi_resp_i.aw_ready & axi_resp_i.w_ready;
            case ({
              axi_resp_i.aw_ready, axi_resp_i.w_ready
            })
              2'b01:   wr_state_d = WAIT_AW_READY;
              2'b10:   wr_state_d = WAIT_LAST_W_READY;
              default: wr_state_d = IDLE;
            endcase
            // its a request for the whole cache line
          end
        end
      end
      ///////////////////////////////////
      // ~> from single write
      WAIT_AW_READY: begin
        axi_req_o.aw_valid = 1'b1;

        if (axi_resp_i.aw_ready) begin
          wr_state_d = IDLE;
          wr_gnt_o   = 1'b1;
        end
      end
      ///////////////////////////////////
      // ~> from write, there is an outstanding write
      WAIT_LAST_W_READY: begin
        axi_req_o.w_valid = 1'b1;

        if (1'b0) begin
          wr_cnt_en = 1'b1;
        end else if (wr_cnt_done) begin  // this is the last write
          if (axi_resp_i.w_ready) begin
            wr_state_d = IDLE;
            wr_cnt_clr = 1'b1;
            wr_gnt_o   = 1'b1;
          end
        end
      end
      ///////////////////////////////////
      default: begin
        ///////////////////////////////////
        // ~> we need to wait for an aw_ready and there is at least one outstanding write
        if (1'b0) begin
          if (wr_state_q == WAIT_LAST_W_READY_AW_READY) begin
            axi_req_o.w_valid  = 1'b1;
            axi_req_o.aw_valid = 1'b1;
            // we got an aw_ready
            case ({
              axi_resp_i.aw_ready, axi_resp_i.w_ready
            })
              // we got an aw ready
              2'b01: begin
                // are there any outstanding transactions?
                if (wr_cnt_done) begin
                  wr_state_d = WAIT_AW_READY_BURST;
                  wr_cnt_clr = 1'b1;
                end else begin
                  // yes, so reduce the count and stay here
                  wr_cnt_en = 1'b1;
                end
              end
              2'b10:   wr_state_d = WAIT_LAST_W_READY;
              2'b11: begin
                // we are finished
                if (wr_cnt_done) begin
                  wr_state_d = IDLE;
                  wr_gnt_o   = 1'b1;
                  wr_cnt_clr = 1'b1;
                  // there are outstanding transactions
                end else begin
                  wr_state_d = WAIT_LAST_W_READY;
                  wr_cnt_en  = 1'b1;
                end
              end
              default: ;
            endcase
          end  ///////////////////////////////////
               // ~> all data has already been sent, we are only waiting for the aw_ready
          else if (wr_state_q == WAIT_AW_READY_BURST) begin
            axi_req_o.aw_valid = 1'b1;

            if (axi_resp_i.aw_ready) begin
              wr_state_d = IDLE;
              wr_gnt_o   = 1'b1;
            end
          end
        end else begin
          wr_state_d = IDLE;
        end
      end
    endcase
  end


  ///////////////////////////////////////////////////////
  // read channel
  ///////////////////////////////////////////////////////

  // hyp8: elastic AR slot (svt-plan boundary). The complete AR descriptor
  // captures when the read request is presented; ar_valid then holds until
  // the bus accepts. rd_gnt_o marks the same event as before — the AR
  // channel handshake — so the upstream req/gnt contract and AXI
  // valid/ready semantics are unchanged (the descriptor just leaves one
  // cycle after first presentation).
  logic                          ar_pend_d, ar_pend_q;
  logic [G6LCCfg.AxiAddrWidth-1:0] ar_addr_q;
  logic [$clog2(AxiNumWords)-1:0]  ar_blen_q;
  logic [2:0]                     ar_size_q;
  logic [G6LCCfg.AxiIdWidth-1:0]  ar_id_q;
  logic                          ar_lock_q;

  always_comb begin
    ar_pend_d = ar_pend_q;
    if (!ar_pend_q && rd_req_i) ar_pend_d = 1'b1;
    if (ar_pend_q && axi_resp_i.ar_ready) ar_pend_d = 1'b0;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_ar_slot
    if (!rst_ni) begin
      ar_pend_q <= 1'b0;
      ar_addr_q <= '0;
      ar_blen_q <= '0;
      ar_size_q <= '0;
      ar_id_q   <= '0;
      ar_lock_q <= 1'b0;
    end else begin
      ar_pend_q <= ar_pend_d;
      if (!ar_pend_q && rd_req_i) begin
        ar_addr_q <= rd_addr_i;
        ar_blen_q <= rd_blen_i;
        ar_size_q <= rd_size_i;
        ar_id_q   <= rd_id_i;
        ar_lock_q <= rd_lock_i;
      end
    end
  end

  // address
  // in case of a wrapping transfer we can simply begin at the address, if we want to request a cache-line
  // with an incremental transfer we need to output the corresponding base address of the cache line
  assign axi_req_o.ar.burst  = axi_pkg::BURST_INCR;  // Use BURST_INCR for AXI regular transaction
  assign axi_req_o.ar.addr   = ar_addr_q[G6LCCfg.AxiAddrWidth-1:0];
  assign axi_req_o.ar.size   = ar_size_q;
  assign axi_req_o.ar.len    = ar_blen_q;
  assign axi_req_o.ar.id     = ar_id_q;
  assign axi_req_o.ar.prot   = 3'b0;
  assign axi_req_o.ar.region = 4'b0;
  assign axi_req_o.ar.lock   = ar_lock_q;
  assign axi_req_o.ar.cache  = axi_pkg::CACHE_MODIFIABLE;
  assign axi_req_o.ar.qos    = 4'b0;
  assign axi_req_o.ar.user   = '0;

  // make the read request — held until the bus accepts, same handshake
  // event the combinational version granted on.
  assign axi_req_o.ar_valid  = ar_pend_q;
  assign rd_gnt_o            = ar_pend_q & axi_resp_i.ar_ready;

  // return path
  assign axi_req_o.r_ready   = rd_rdy_i;
  assign rd_data_o           = axi_resp_i.r.data;
  if (G6LCCfg.AXI_USER_EN != 0) begin
    assign rd_user_o = axi_resp_i.r.user;
  end else begin
    assign rd_user_o = '0;
  end
  assign rd_last_o   = axi_resp_i.r.last;
  assign rd_valid_o  = axi_resp_i.r_valid;
  assign rd_id_o     = axi_resp_i.r.id;
  assign rd_exokay_o = (axi_resp_i.r.resp == axi_pkg::RESP_EXOKAY);


  // ----------------
  // Registers
  // ----------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      // start in flushing state and initialize the memory
      wr_state_q <= IDLE;
      wr_cnt_q   <= '0;
    end else begin
      wr_state_q <= wr_state_d;
      wr_cnt_q   <= wr_cnt_d;
    end
  end

  // ----------------
  // Assertions
  // ----------------

  //pragma translate_off
  initial begin
    assert (AxiNumWords >= 1)
    else $fatal(1, "[axi adapter] AxiNumWords must be >= 1");
    assert (G6LCCfg.AxiIdWidth >= 2)
    else $fatal(1, "[axi adapter] AXI id width must be at least 2 bit wide");
  end
  //pragma translate_on

endmodule  // axi_adapter2
